import Foundation

/// 单条实际存在于本机的可清理文件或目录条目
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let clientID: String
    public let clientName: String
    public let ruleID: String
    /// 面向用户的友好名称（如「GPU 缓存」或子文件名）
    public let displayName: String
    /// 磁盘上的实际文件或目录名
    public let fileName: String
    public let url: URL
    public let category: ScanCategory
    public let safetyNote: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool
    public let isCustom: Bool

    public init(
        clientID: String,
        clientName: String,
        ruleID: String,
        displayName: String,
        fileName: String,
        url: URL,
        category: ScanCategory,
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
    public let items: [CleanableItem]
    public let skippedProtectedCount: Int

    public var id: String { profile.id }

    public var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    public var itemCount: Int {
        items.count
    }

    public init(
        profile: AIClientProfile,
        items: [CleanableItem],
        skippedProtectedCount: Int = 0
    ) {
        self.profile = profile
        self.items = items
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

    public var allItems: [CleanableItem] {
        clientSummaries.flatMap(\.items)
    }

    public var totalSizeBytes: Int64 {
        clientSummaries.reduce(0) { $0 + $1.totalSizeBytes }
    }

    public var totalItemCount: Int {
        clientSummaries.reduce(0) { $0 + $1.itemCount }
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
