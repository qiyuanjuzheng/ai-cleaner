import Foundation

/// 单条实际存在于本机的扫描条目（含可清理项与透明展示的「不建议清理」受保护项）
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let clientID: String
    public let clientName: String
    public let ruleID: String
    /// 面向用户的友好名称（如「GPU 缓存」或「项目名 · 首条对话摘要」）
    public let displayName: String
    /// 磁盘上的实际文件或目录名
    public let fileName: String
    public let url: URL
    public let category: ScanCategory
    public let recommendation: CleanupRecommendation
    public let safetyNote: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool
    public let isCustom: Bool

    /// 是否属于常规/批量可清理条目（`notRecommended` 不参与一键全选或批量选择，仅支持用户显式风险确认后手动移入废纸篓）
    public var isCleanable: Bool {
        recommendation.isCleanable
    }

    public init(
        clientID: String,
        clientName: String,
        ruleID: String,
        displayName: String,
        fileName: String,
        url: URL,
        category: ScanCategory,
        recommendation: CleanupRecommendation? = nil,
        safetyNote: String,
        sizeBytes: Int64,
        fileCount: Int,
        modifiedAt: Date,
        isDirectory: Bool,
        isCustom: Bool
    ) {
        let standardized = url.standardizedFileURL
        self.id = "\(clientID)::\(standardized.path)"
        self.clientID = clientID
        self.clientName = clientName
        self.ruleID = ruleID
        self.displayName = displayName
        self.fileName = fileName
        self.url = standardized
        self.category = category
        if let recommendation {
            self.recommendation = recommendation
        } else {
            switch category {
            case .cache, .temporary, .logs:
                self.recommendation = .recommended
            case .sessions, .custom:
                self.recommendation = .reviewSuggested
            case .protectedData:
                self.recommendation = .notRecommended
            }
        }
        self.safetyNote = safetyNote
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isCustom = isCustom
    }
}

/// 单个 AI 客户端（或自定义目录）的扫描汇总结果
public struct ClientScanSummary: Identifiable, Hashable, Sendable {
    public let profile: AIClientProfile
    /// 允许清理的条目（「建议清理」+「按需清理」）
    public let items: [CleanableItem]
    /// 透明展示但锁定保护的「不建议清理」条目（绝不允许勾选或移入废纸篓）
    public let protectedItems: [CleanableItem]
    public let skippedProtectedCount: Int

    public var id: String { profile.id }

    /// 本客户端所有展示条目（可清理 + 受保护）
    public var allDisplayedItems: [CleanableItem] {
        items + protectedItems
    }

    /// 可清理空间合计（建议清理 + 按需清理）
    public var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    public var recommendedItems: [CleanableItem] {
        items.filter { $0.recommendation == .recommended }
    }

    public var reviewSuggestedItems: [CleanableItem] {
        items.filter { $0.recommendation == .reviewSuggested }
    }

    public var recommendedSizeBytes: Int64 {
        recommendedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var reviewSuggestedSizeBytes: Int64 {
        reviewSuggestedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var protectedSizeBytes: Int64 {
        protectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var totalDiskFootprintBytes: Int64 {
        totalSizeBytes + protectedSizeBytes
    }

    public var itemCount: Int {
        items.count
    }

    public var protectedItemCount: Int {
        protectedItems.count
    }

    public init(
        profile: AIClientProfile,
        items: [CleanableItem],
        protectedItems: [CleanableItem] = [],
        skippedProtectedCount: Int = 0
    ) {
        self.profile = profile
        self.items = items
        self.protectedItems = protectedItems
        self.skippedProtectedCount = skippedProtectedCount
    }
}

/// 一次全量扫描的汇总报告
public struct ScanReport: Sendable {
    public let scannedAt: Date
    public let clientSummaries: [ClientScanSummary]
    public let totalBuiltInProfilesCount: Int
    public let detectedBuiltInClientsCount: Int
    public let skippedProtectedCount: Int

    /// 所有可清理条目（建议清理 + 按需清理）
    public var allItems: [CleanableItem] {
        clientSummaries.flatMap(\.items)
    }

    /// 所有透明展示的「不建议清理」锁定条目
    public var allProtectedItems: [CleanableItem] {
        clientSummaries.flatMap(\.protectedItems)
    }

    /// 所有展示条目（含可清理与不建议清理）
    public var allDisplayedItems: [CleanableItem] {
        clientSummaries.flatMap(\.allDisplayedItems)
    }

    public var totalSizeBytes: Int64 {
        clientSummaries.reduce(0) { $0 + $1.totalSizeBytes }
    }

    public var recommendedSizeBytes: Int64 {
        clientSummaries.reduce(0) { $0 + $1.recommendedSizeBytes }
    }

    public var reviewSuggestedSizeBytes: Int64 {
        clientSummaries.reduce(0) { $0 + $1.reviewSuggestedSizeBytes }
    }

    public var protectedSizeBytes: Int64 {
        clientSummaries.reduce(0) { $0 + $1.protectedSizeBytes }
    }

    public var totalDiskFootprintBytes: Int64 {
        totalSizeBytes + protectedSizeBytes
    }

    public var totalItemCount: Int {
        clientSummaries.reduce(0) { $0 + $1.itemCount }
    }

    public var totalRecommendedCount: Int {
        clientSummaries.reduce(0) { $0 + $1.recommendedItems.count }
    }

    public var totalReviewSuggestedCount: Int {
        clientSummaries.reduce(0) { $0 + $1.reviewSuggestedItems.count }
    }

    public var totalProtectedItemCount: Int {
        clientSummaries.reduce(0) { $0 + $1.protectedItemCount }
    }

    public init(
        scannedAt: Date = Date(),
        clientSummaries: [ClientScanSummary],
        totalBuiltInProfilesCount: Int,
        detectedBuiltInClientsCount: Int,
        skippedProtectedCount: Int = 0
    ) {
        self.scannedAt = scannedAt
        self.clientSummaries = clientSummaries
        self.totalBuiltInProfilesCount = totalBuiltInProfilesCount
        self.detectedBuiltInClientsCount = detectedBuiltInClientsCount
        self.skippedProtectedCount = skippedProtectedCount
    }
}
