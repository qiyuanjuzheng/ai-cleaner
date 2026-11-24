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
    public let hardProtectionReason: String?
    public let requiresIndividualSelection: Bool
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool
    public let isCustom: Bool

    /// 是否属于常规可清理条目（`notRecommended` 不参与一键全选或批量选择，仅支持用户显式风险确认后手动移入废纸篓）
    public var isCleanable: Bool {
        recommendation.isCleanable
    }

    public var isBulkSelectable: Bool {
        isCleanable && !requiresIndividualSelection
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
        isCustom: Bool,
        hardProtectionReason: String? = nil,
        requiresIndividualSelection: Bool = false
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
        if hardProtectionReason != nil {
            self.recommendation = .notRecommended
        } else if let recommendation {
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
        self.safetyNote = hardProtectionReason ?? safetyNote
        self.hardProtectionReason = hardProtectionReason
        self.requiresIndividualSelection = requiresIndividualSelection
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
    /// 透明展示的「不建议清理」条目，包括硬保护和可手动覆盖的条目。
    public let protectedItems: [CleanableItem]
    public let skippedProtectedCount: Int

    /// 预计算的可清理空间合计（建议清理 + 按需清理），确保侧边栏与头部渲染 O(1) 读取
    public let totalSizeBytes: Int64
    public let recommendedSizeBytes: Int64
    public let reviewSuggestedSizeBytes: Int64
    public let protectedSizeBytes: Int64
    public let totalDiskFootprintBytes: Int64
    public let recommendedItemCount: Int
    public let reviewSuggestedItemCount: Int

    public var id: String { profile.id }

    /// 本客户端所有展示条目（可清理 + 受保护）
    public var allDisplayedItems: [CleanableItem] {
        items + protectedItems
    }

    public var recommendedItems: [CleanableItem] {
        items.filter { $0.recommendation == .recommended }
    }

    public var reviewSuggestedItems: [CleanableItem] {
        items.filter { $0.recommendation == .reviewSuggested }
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

        var recBytes: Int64 = 0
        var revBytes: Int64 = 0
        var recCount = 0
        var revCount = 0
        for item in items {
            if item.recommendation == .recommended {
                recBytes += item.sizeBytes
                recCount += 1
            } else {
                revBytes += item.sizeBytes
                revCount += 1
            }
        }
        var proBytes: Int64 = 0
        for item in protectedItems {
            proBytes += item.sizeBytes
        }

        self.recommendedSizeBytes = recBytes
        self.reviewSuggestedSizeBytes = revBytes
        self.totalSizeBytes = recBytes + revBytes
        self.protectedSizeBytes = proBytes
        self.totalDiskFootprintBytes = recBytes + revBytes + proBytes
        self.recommendedItemCount = recCount
        self.reviewSuggestedItemCount = revCount
    }
}

/// 一次全量扫描的汇总报告
public struct ScanReport: Sendable {
    public let scannedAt: Date
    public let clientSummaries: [ClientScanSummary]
    public let totalBuiltInProfilesCount: Int
    public let detectedBuiltInClientsCount: Int
    public let skippedProtectedCount: Int

    /// 预计算全局体积与条目计数（O(1) 读取，避免切换视图时重复遍历数千条目）
    public let totalSizeBytes: Int64
    public let recommendedSizeBytes: Int64
    public let reviewSuggestedSizeBytes: Int64
    public let protectedSizeBytes: Int64
    public let totalDiskFootprintBytes: Int64
    public let totalItemCount: Int
    public let totalRecommendedCount: Int
    public let totalReviewSuggestedCount: Int
    public let totalProtectedItemCount: Int

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

        var totalBytes: Int64 = 0
        var recBytes: Int64 = 0
        var revBytes: Int64 = 0
        var proBytes: Int64 = 0
        var itemCount = 0
        var recCount = 0
        var revCount = 0
        var proCount = 0

        for summary in clientSummaries {
            totalBytes += summary.totalSizeBytes
            recBytes += summary.recommendedSizeBytes
            revBytes += summary.reviewSuggestedSizeBytes
            proBytes += summary.protectedSizeBytes
            itemCount += summary.itemCount
            recCount += summary.recommendedItemCount
            revCount += summary.reviewSuggestedItemCount
            proCount += summary.protectedItemCount
        }

        self.totalSizeBytes = totalBytes
        self.recommendedSizeBytes = recBytes
        self.reviewSuggestedSizeBytes = revBytes
        self.protectedSizeBytes = proBytes
        self.totalDiskFootprintBytes = totalBytes + proBytes
        self.totalItemCount = itemCount
        self.totalRecommendedCount = recCount
        self.totalReviewSuggestedCount = revCount
        self.totalProtectedItemCount = proCount
    }
}
