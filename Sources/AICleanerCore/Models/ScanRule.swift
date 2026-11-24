import Foundation

/// 规则的扫描粒度
public enum ScanTargetMode: String, Codable, Hashable, Sendable {
    /// 将目标目录作为一个整体条目展示与移入废纸篓（适合应用缓存、GPUCache、Crashpad 等）
    case directory
    /// 展开目标目录的一级子项逐条展示与勾选（适合离散日志目录、扁平会话目录与用户自定义目录）
    case children
    /// 按「项目/工作区目录 → 单条会话文件或会话子目录」两层结构展开（如 Claude Code ~/.claude/projects、Pi ~/.pi/agent/sessions）
    case projectSessions
    /// 递归枚举嵌套日期/层级目录中的单条会话文件（如 Codex ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl）
    case recursiveFiles
}

/// 单条可扫描目录规则
public struct ScanRule: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// 相对于用户主目录的路径（如 `.claude/debug`），或绝对路径（自定义目录）
    public let path: String
    public let category: ScanCategory
    public let mode: ScanTargetMode
    /// 默认清理建议等级（聊天会话在扫描时会按活跃时间自动细分「建议清理」与「按需清理」）
    public let recommendation: CleanupRecommendation
    /// 针对此条规则的中文用途与安全说明
    public let explanation: String
    /// 仅在 `recursiveFiles` 等模式下生效的文件名后缀过滤（为空表示不过滤），例如 `[".jsonl", ".jsonl.zst"]`
    public let allowedFileSuffixes: [String]

    public init(
        id: String,
        displayName: String,
        path: String,
        category: ScanCategory,
        mode: ScanTargetMode = .directory,
        recommendation: CleanupRecommendation? = nil,
        explanation: String,
        allowedFileSuffixes: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.category = category
        self.mode = mode
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
        self.explanation = explanation
        self.allowedFileSuffixes = allowedFileSuffixes
    }

    /// 基于给定的用户主目录解析实际文件系统路径
    public func resolveURL(homeDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(path).standardizedFileURL
    }
}
