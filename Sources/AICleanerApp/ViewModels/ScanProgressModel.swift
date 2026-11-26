import AICleanerCore
import Foundation
import Observation

/// 扫描进度页的单一状态源（步骤条 / 客户端发现卡片 / 实时统计）：
/// - 视图只消费这里的快照，不在视图层累计业务状态；
/// - 数据完全由扫描引擎的进度事件驱动（服务层锁内累计 + 节流发布），UI 不自设定时器；
/// - 通过 `beginSession` / `endSession` 管理会话生命周期，取消扫描后不留状态残留，
///   也保证取消后仍在途的引擎事件不会污染下一次扫描。
@Observable
@MainActor
final class ScanProgressModel: @unchecked Sendable {
    /// 当前进行中的阶段；`nil` 表示本次扫描会话尚未真正开始
    private(set) var currentStage: ScanStage?
    /// 扫描已收尾，三个阶段全部呈现完成态
    private(set) var isCompleted = false
    /// 已发现的客户端卡片（按发现顺序，含「检测中」占位）
    private(set) var detectedClients: [ScanProgressClient] = []
    /// 已扫描文件数
    private(set) var scannedFileCount = 0
    /// 已发现可清理空间（字节），扫描结束时与结果页 `ScanReport.totalSizeBytes` 同口径同值
    private(set) var cleanableBytes: Int64 = 0

    /// 是否仍在接收本次扫描的进度事件（取消后置为 false，丢弃在途事件）
    private var isReceiving = false

    init() {}

    /// 开始一次新的扫描会话：清空上一轮残留并进入第一阶段
    func beginSession() {
        currentStage = .scanningClients
        isCompleted = false
        detectedClients = []
        scannedFileCount = 0
        cleanableBytes = 0
        isReceiving = true
    }

    /// 消费引擎发布的整包进度快照（仅当前会话接收中有效）
    func apply(_ event: ScanProgressEvent) {
        guard isReceiving else { return }
        currentStage = event.stage
        detectedClients = event.clients
        scannedFileCount = event.scannedFileCount
        cleanableBytes = event.cleanableBytes
        if event.isFinal {
            isCompleted = true
        }
    }

    /// 扫描正常收尾：三个阶段全部完成（无进度事件的扫描执行器也保证完成态）
    func finishSession() {
        isCompleted = true
    }

    /// 取消 / 离开扫描：停止接收事件，状态由下一次 `beginSession` 清空
    func endSession() {
        isReceiving = false
    }

    // MARK: - 派生视图数据

    /// 发现卡片只展示有真实数据的客户端：已量出体积且可清理空间大于 0；
    /// 「检测中」占位与 0 字节客户端不出卡（按发现顺序）
    var revealedClients: [ScanProgressClient] {
        detectedClients.filter { $0.state == .measured && $0.cleanableBytes > 0 }
    }

    /// 步骤条中各阶段的呈现状态
    enum StageDisplayState: Equatable {
        case pending
        case active
        case done
    }

    func displayState(for stage: ScanStage) -> StageDisplayState {
        if isCompleted { return .done }
        guard let currentOrdinal = currentStage?.ordinal else { return .pending }
        if stage.ordinal < currentOrdinal { return .done }
        if stage.ordinal == currentOrdinal { return .active }
        return .pending
    }

    /// VoiceOver 朗读文本：当前阶段与三步进度
    var stageAccessibilityLabel: String {
        let states = ScanStage.allCases.map { displayState(for: $0) }
        if isCompleted {
            return "扫描进度：三个阶段全部完成"
        }
        guard let currentStage else {
            return "扫描尚未开始"
        }
        let doneCount = states.filter { $0 == .done }.count
        return "扫描进度：第 \(doneCount + 1) 步，共 \(ScanStage.allCases.count) 步，\(currentStage.displayName)"
    }

    /// VoiceOver 朗读文本：两项实时统计
    var statsAccessibilityLabel: String {
        let bytesText = CleanerFormatting.formatBytes(cleanableBytes)
        return "已扫描文件 \(scannedFileCount) 个，已发现可清理空间 \(bytesText)"
    }
}
