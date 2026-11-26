import Foundation
import os

/// 扫描进度页的三个阶段，与扫描引擎的执行顺序一一对应：
/// 1. 扫描客户端 —— 并发扫描所有内置 AI 客户端规则；
/// 2. 分析缓存文件 —— 分层扫描系统临时目录并合并归属、扫描用户自定义目录；
/// 3. 统计可释放空间 —— 汇总各客户端条目、过滤排除项并生成最终报告。
public enum ScanStage: String, CaseIterable, Sendable {
    case scanningClients
    case analyzingCacheFiles
    case tallyingCleanableSpace

    public var displayName: String {
        switch self {
        case .scanningClients: return "扫描客户端"
        case .analyzingCacheFiles: return "分析缓存文件"
        case .tallyingCleanableSpace: return "统计可释放空间"
        }
    }

    /// 在全部阶段中的序号（从 0 开始），供步骤条判断「进行中 / 已完成 / 未开始」
    public var ordinal: Int {
        switch self {
        case .scanningClients: return 0
        case .analyzingCacheFiles: return 1
        case .tallyingCleanableSpace: return 2
        }
    }
}

/// 扫描进度页上单个客户端发现卡片的状态：
/// `detecting` 为「检测中」占位（仅知道客户端在本机存在，尚未量出缓存体积），
/// `measured` 为已量出可清理体积的完成态。
public enum ScanClientDetectionState: String, Sendable {
    case detecting
    case measured
}

/// 进度事件中单个客户端的快照（发现卡片数据源）
public struct ScanProgressClient: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let accentToken: String
    public let kind: AIClientProfile.ProfileKind
    public var state: ScanClientDetectionState
    /// 可清理空间合计（建议清理 + 按需清理），与结果页 `ClientScanSummary.totalSizeBytes` 同口径
    public var cleanableBytes: Int64
    /// 已发现的条目数
    public var itemCount: Int

    public init(
        id: String,
        name: String,
        symbolName: String,
        accentToken: String,
        kind: AIClientProfile.ProfileKind,
        state: ScanClientDetectionState,
        cleanableBytes: Int64,
        itemCount: Int
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.accentToken = accentToken
        self.kind = kind
        self.state = state
        self.cleanableBytes = cleanableBytes
        self.itemCount = itemCount
    }
}

/// 一次进度上报的完整快照：
/// 服务层在锁内累计增量后整体发布，UI 侧直接整包替换状态，
/// 避免多线程并发扫描下的事件乱序与丢失更新。
public struct ScanProgressEvent: Equatable, Sendable {
    public let stage: ScanStage
    /// 按发现顺序排列的客户端快照
    public let clients: [ScanProgressClient]
    /// 已扫描文件数（所有已发现可清理条目的文件合计）
    public let scannedFileCount: Int
    /// 已发现可清理空间合计，扫描结束时与 `ScanReport.totalSizeBytes` 一致
    public let cleanableBytes: Int64
    /// 是否为扫描收尾的最终快照
    public let isFinal: Bool

    public init(
        stage: ScanStage,
        clients: [ScanProgressClient],
        scannedFileCount: Int,
        cleanableBytes: Int64,
        isFinal: Bool = false
    ) {
        self.stage = stage
        self.clients = clients
        self.scannedFileCount = scannedFileCount
        self.cleanableBytes = cleanableBytes
        self.isFinal = isFinal
    }
}

/// 进度回调：引擎在后台线程发布快照，订阅方自行切换到主线程消费
public typealias ScanProgressHandler = @Sendable (ScanProgressEvent) -> Void

/// 扫描进度发布器：
/// - 锁内累计阶段、客户端与统计增量，整体发布不可变快照；
/// - 阶段切换与客户端发现 / 量出体积立即发布；
/// - 纯统计增量按最小间隔节流（默认 0.15s），避免逐文件事件淹没主线程。
public final class ScanProgressEmitter: @unchecked Sendable {
    private struct State {
        var stage: ScanStage = .scanningClients
        var clients: [String: ScanProgressClient] = [:]
        var order: [String] = []
        var scannedFileCount = 0
        var cleanableBytes: Int64 = 0
        var lastStatsEmitAt: TimeInterval = 0
        var hasEmitted = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let handler: ScanProgressHandler
    private let statsMinInterval: TimeInterval

    public init(handler: @escaping ScanProgressHandler, statsMinInterval: TimeInterval = 0.15) {
        self.handler = handler
        self.statsMinInterval = statsMinInterval
    }

    /// 切换扫描阶段并立即发布快照（任何发布都会开启统计增量的节流窗口）
    public func update(stage: ScanStage) {
        let event = lock.withLock { state -> ScanProgressEvent in
            state.stage = stage
            state.hasEmitted = true
            state.lastStatsEmitAt = CFAbsoluteTimeGetCurrent()
            return Self.makeEvent(from: state, isFinal: false)
        }
        handler(event)
    }

    /// 上报「检测到客户端」占位卡片（已存在则忽略，保持首次发现顺序）
    public func detectClient(_ client: ScanProgressClient) {
        let shouldEmit = lock.withLock { state -> Bool in
            guard state.clients[client.id] == nil else { return false }
            state.clients[client.id] = client
            state.order.append(client.id)
            return true
        }
        guard shouldEmit else { return }
        emitCurrentState()
    }

    /// 上报客户端已量出体积：
    /// - `insertIfMissing: false` 仅刷新已存在的占位卡片（本机不存在的客户端不会凭空出卡）；
    /// - `insertIfMissing: true` 时卡片不存在则按发现顺序补插（临时目录独立分组等直接量出体积的来源）。
    public func measureClient(
        id: String,
        name: String,
        symbolName: String,
        accentToken: String,
        kind: AIClientProfile.ProfileKind,
        cleanableBytes: Int64,
        itemCount: Int,
        insertIfMissing: Bool = true
    ) {
        let shouldEmit = lock.withLock { state -> Bool in
            if var existing = state.clients[id] {
                existing.state = .measured
                existing.cleanableBytes = cleanableBytes
                existing.itemCount = itemCount
                state.clients[id] = existing
                return true
            }
            guard insertIfMissing else { return false }
            state.clients[id] = ScanProgressClient(
                id: id,
                name: name,
                symbolName: symbolName,
                accentToken: accentToken,
                kind: kind,
                state: .measured,
                cleanableBytes: cleanableBytes,
                itemCount: itemCount
            )
            state.order.append(id)
            return true
        }
        guard shouldEmit else { return }
        emitCurrentState()
    }

    /// 累计统计增量（文件数 + 可清理字节），按最小间隔节流发布
    public func addScanStats(fileCount: Int, bytes: Int64) {
        let event = lock.withLock { state -> ScanProgressEvent? in
            state.scannedFileCount += max(0, fileCount)
            state.cleanableBytes += max(0, bytes)
            let now = CFAbsoluteTimeGetCurrent()
            guard state.hasEmitted, now - state.lastStatsEmitAt >= statsMinInterval else {
                return nil
            }
            state.lastStatsEmitAt = now
            return Self.makeEvent(from: state, isFinal: false)
        }
        if let event {
            handler(event)
        }
    }

    /// 扫描收尾：强制发布包含全部累计值的最终快照
    public func flush() {
        let event = lock.withLock { state in
            state.hasEmitted = true
            return Self.makeEvent(from: state, isFinal: true)
        }
        handler(event)
    }

    private func emitCurrentState() {
        let event = lock.withLock { state -> ScanProgressEvent in
            state.hasEmitted = true
            state.lastStatsEmitAt = CFAbsoluteTimeGetCurrent()
            return Self.makeEvent(from: state, isFinal: false)
        }
        handler(event)
    }

    private static func makeEvent(from state: State, isFinal: Bool) -> ScanProgressEvent {
        ScanProgressEvent(
            stage: state.stage,
            clients: state.order.compactMap { state.clients[$0] },
            scannedFileCount: state.scannedFileCount,
            cleanableBytes: state.cleanableBytes,
            isFinal: isFinal
        )
    }
}
