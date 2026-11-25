import Foundation

/// 单条被用户手动排除（不再在待清理列表中展示）的条目记录
public struct ExcludedItemRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// 规范化后的完整路径（不含尾部多余斜杠）
    public let normalizedPath: String
    /// 面向用户的展示名称或标题（会话条目保留可读会话标题）
    public let displayName: String
    /// 所属 AI 客户端或自定义目录分组 ID
    public let clientID: String
    /// 所属 AI 客户端或自定义目录分组名称
    public let clientName: String
    /// 所属类别
    public let category: ScanCategory
    /// 排除时该路径是否为目录
    public let isDirectory: Bool
    /// 加入排除列表的时间
    public let excludedAt: Date
    /// 若为项目会话条目，可选保留所属项目名便于辨认
    public let sessionProjectName: String?

    /// 对应的本地文件 URL
    public var url: URL {
        URL(fileURLWithPath: normalizedPath, isDirectory: isDirectory).standardizedFileURL
    }

    public init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        clientID: String,
        clientName: String,
        category: ScanCategory,
        isDirectory: Bool,
        excludedAt: Date = Date(),
        sessionProjectName: String? = nil
    ) {
        self.id = id
        self.normalizedPath = ExcludedItemMatcher.normalizePath(path)
        self.displayName = displayName
        self.clientID = clientID
        self.clientName = clientName
        self.category = category
        self.isDirectory = isDirectory
        self.excludedAt = excludedAt
        self.sessionProjectName = sessionProjectName
    }

    /// 从扫描条目构造排除记录，优先保留会话可读标题与所属分组信息
    public static func from(item: CleanableItem, excludedAt: Date = Date()) -> ExcludedItemRecord {
        ExcludedItemRecord(
            path: item.url.path,
            displayName: item.preferredDisplayTitle,
            clientID: item.clientID,
            clientName: item.clientName,
            category: item.category,
            isDirectory: item.isDirectory,
            excludedAt: excludedAt,
            sessionProjectName: item.sessionProjectName
        )
    }
}
