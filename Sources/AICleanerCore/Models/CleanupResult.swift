#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 成功移入废纸篓的条目记录
public struct TrashedItemRecord: Identifiable, Hashable, Sendable {
    public var id: String { item.id }
    public let item: CleanableItem
    public let resultingTrashURL: URL?
    public let trashedBytes: Int64

    public init(item: CleanableItem, resultingTrashURL: URL?, trashedBytes: Int64? = nil) {
        self.item = item
        self.resultingTrashURL = resultingTrashURL
        self.trashedBytes = max(0, trashedBytes ?? item.sizeBytes)
    }
}

/// 清理失败或被安全策略拦截的条目记录
public struct CleanupFailure: Identifiable, Hashable, Sendable {
    public var id: String { item.id }
    public let item: CleanableItem
    public let reason: String

    public init(item: CleanableItem, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// 单次「移入废纸篓」操作的执行反馈
public struct CleanupResult: Sendable {
    public let trashedItems: [TrashedItemRecord]
    public let skippedProtectedItems: [CleanupFailure]
    public let failedItems: [CleanupFailure]
    public let freedBytes: Int64
    public let completedAt: Date

    public var trashedCount: Int { trashedItems.count }
    public var hasFailures: Bool { !failedItems.isEmpty || !skippedProtectedItems.isEmpty }

    public init(
        trashedItems: [TrashedItemRecord],
        skippedProtectedItems: [CleanupFailure],
        failedItems: [CleanupFailure],
        freedBytes: Int64,
        completedAt: Date = Date()
    ) {
        self.trashedItems = trashedItems
        self.skippedProtectedItems = skippedProtectedItems
        self.failedItems = failedItems
        self.freedBytes = freedBytes
        self.completedAt = completedAt
    }
}
