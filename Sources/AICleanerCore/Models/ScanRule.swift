import Foundation

/// 规则的扫描粒度
public enum ScanTargetMode: String, Codable, Hashable, Sendable {
    /// 将目标目录作为一个整体条目展示与移入废纸篓（适合应用缓存、GPUCache、Crashpad 等）
    case directory
    /// 展开目标目录的一级子项逐条展示与勾选（适合离散日志目录与用户自定义目录）
    case children
}

/// 单条可扫描目录规则
public struct ScanRule: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// 相对于用户主目录的路径（如 `.claude/debug`），或绝对路径（自定义目录）
    public let path: String
    public let category: ScanCategory
    public let mode: ScanTargetMode
    /// 针对此条规则的中文用途与安全说明
    public let explanation: String

    public init(
        id: String,
        displayName: String,
        path: String,
        category: ScanCategory,
        mode: ScanTargetMode = .directory,
        explanation: String
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.category = category
        self.mode = mode
        self.explanation = explanation
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
