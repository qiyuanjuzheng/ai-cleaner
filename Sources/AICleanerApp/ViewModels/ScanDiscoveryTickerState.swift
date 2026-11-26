import Foundation

/// 扫描进度页「客户端发现」单行跑马灯的呈现队列（纯值类型，便于单测）：
/// - 只接收已量出真实体积的客户端 id（「检测中」占位与 0 字节客户端在 `ScanProgressModel` 已过滤）；
/// - 新发现的客户端先进入待展示队列，按节奏逐个放入可见行，从右侧滑入；
/// - 可见行只保留最近 `visibleCapacity` 张，最早的一张从左侧滚出消失；
/// - 待展示积压越多，放出节奏越快，避免扫描结束时还有大量卡片没露面。
struct ScanDiscoveryTickerState: Equatable {
    static let defaultVisibleCapacity = 4

    let visibleCapacity: Int
    /// 当前行内可见的卡片（从左到右，最右为最新）
    private(set) var visibleIDs: [String] = []
    /// 已发现、尚未放入可见行的卡片（按发现顺序）
    private(set) var pendingIDs: [String] = []
    private var seenIDs: Set<String> = []

    init(visibleCapacity: Int = Self.defaultVisibleCapacity) {
        self.visibleCapacity = max(1, visibleCapacity)
    }

    var hasPending: Bool { !pendingIDs.isEmpty }

    /// 与模型中的客户端列表同步：只把首次出现的 id 追加到待展示队列；
    /// 列表被清空（新一轮扫描开始）时整体复位，避免上一轮残留。
    mutating func sync(with ids: [String]) {
        guard !ids.isEmpty else {
            reset()
            return
        }
        for id in ids where seenIDs.insert(id).inserted {
            pendingIDs.append(id)
        }
    }

    /// 放出下一张卡片；超出容量时丢弃最早的可见卡片。无待展示卡片时返回 false。
    @discardableResult
    mutating func advance() -> Bool {
        guard !pendingIDs.isEmpty else { return false }
        visibleIDs.append(pendingIDs.removeFirst())
        let overflow = visibleIDs.count - visibleCapacity
        if overflow > 0 {
            visibleIDs.removeFirst(overflow)
        }
        return true
    }

    /// 下一次放出卡片前的间隔（秒）：积压少时慢慢滚动，积压多时加快追上扫描进度
    var releaseInterval: TimeInterval {
        switch pendingIDs.count {
        case 0...1: return 0.75
        case 2...3: return 0.5
        default: return 0.28
        }
    }

    mutating func reset() {
        visibleIDs = []
        pendingIDs = []
        seenIDs = []
    }
}
