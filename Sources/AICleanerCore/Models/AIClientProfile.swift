import Foundation

/// AI 客户端（或自定义目录 / 系统临时目录分组）的规则配置画像
public struct AIClientProfile: Identifiable, Codable, Hashable, Sendable {
    public enum ProfileKind: String, Codable, Hashable, Sendable {
        case builtInClient
        case otherAITemp
        case unattributedTemp
        case customDirectory
    }

    public let id: String
    public let name: String
    public let symbolName: String
    public let accentToken: String
    public let description: String
    /// 明确告知用户该客户端哪些关键数据被保护排除
    public let protectedSummary: String
    public let rules: [ScanRule]
    public let isCustom: Bool
    public let customDirectoryID: UUID?
    public let kind: ProfileKind

    public init(
        id: String,
        name: String,
        symbolName: String,
        accentToken: String,
        description: String,
        protectedSummary: String,
        rules: [ScanRule],
        isCustom: Bool = false,
        customDirectoryID: UUID? = nil,
        kind: ProfileKind? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.accentToken = accentToken
        self.description = description
        self.protectedSummary = protectedSummary
        self.rules = rules
        self.isCustom = isCustom
        self.customDirectoryID = customDirectoryID
        self.kind = kind ?? (isCustom ? .customDirectory : .builtInClient)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, accentToken, description, protectedSummary, rules, isCustom, customDirectoryID, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.symbolName = try container.decode(String.self, forKey: .symbolName)
        self.accentToken = try container.decode(String.self, forKey: .accentToken)
        self.description = try container.decode(String.self, forKey: .description)
        self.protectedSummary = try container.decode(String.self, forKey: .protectedSummary)
        self.rules = try container.decode([ScanRule].self, forKey: .rules)
        let isCustom = try container.decode(Bool.self, forKey: .isCustom)
        self.isCustom = isCustom
        self.customDirectoryID = try container.decodeIfPresent(UUID.self, forKey: .customDirectoryID)
        self.kind = try container.decodeIfPresent(ProfileKind.self, forKey: .kind)
            ?? (isCustom ? .customDirectory : .builtInClient)
    }
}

/// 用户自定义的扫描目录配置
public struct CustomScanDirectory: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var path: String
    public var category: ScanCategory
    public var mode: ScanTargetMode
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        category: ScanCategory = .custom,
        mode: ScanTargetMode = .children,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.category = category
        self.mode = mode
        self.createdAt = createdAt
    }

    public func toClientProfile() -> AIClientProfile {
        let rule = ScanRule(
            id: "custom-rule-\(id.uuidString)",
            displayName: displayName,
            path: path,
            category: category,
            mode: mode,
            explanation: category.safetyDescription
        )
        return AIClientProfile(
            id: "custom-\(id.uuidString)",
            name: displayName,
            symbolName: "folder.badge.plus",
            accentToken: "custom",
            description: "用户自定义扫描目录：\(path)",
            protectedSummary: "已启用安全防护，自动跳过登录凭据、私钥、核心配置与主数据库文件。",
            rules: [rule],
            isCustom: true,
            customDirectoryID: id
        )
    }
}
