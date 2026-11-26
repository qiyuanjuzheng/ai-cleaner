#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 自定义扫描目录管理错误
public enum CustomDirectoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case directoryNotFound(String)
    case notADirectory(String)
    case protectedPath(String)
    case duplicatePath(String)

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case let .directoryNotFound(path):
            return "目录不存在：\(path)"
        case let .notADirectory(path):
            return "所选路径不是文件夹：\(path)"
        case let .protectedPath(reason):
            return "出于安全限制，无法添加该目录：\(reason)"
        case let .duplicatePath(path):
            return "该目录已在扫描列表中：\(path)"
        }
    }
}

#if !canImport(FoundationEssentials)
extension CustomDirectoryError: LocalizedError {}
#endif

/// 持久化管理用户新增与移除的自定义扫描目录（存储于独立 JSON 文件，支持平台适配器与测试路径注入）。
public struct CustomDirectoryStore: Sendable {
    public let storageURL: URL
    public let safetyGuard: SafetyGuard

    public init(
        storageURL: URL,
        safetyGuard: SafetyGuard
    ) {
        self.storageURL = storageURL
        self.safetyGuard = safetyGuard
    }

    public init(
        platform: any PlatformAdapter = HostPlatformAdapter.shared,
        storageURL: URL? = nil,
        safetyGuard: SafetyGuard? = nil
    ) {
        let platform = safetyGuard?.platform ?? platform
        self.storageURL = storageURL ?? platform.userDataDirectory()
            .appendingPathComponent("custom-directories.json")
        self.safetyGuard = safetyGuard ?? SafetyGuard(platform: platform)
    }

    /// 读取当前保存的所有自定义目录。若文件损坏则先备份保留再返回空数组（ADR 0001 第 7.3 节）。
    public func load() -> [CustomScanDirectory] {
        (try? loadChecked()) ?? []
    }

    public func loadChecked() throws -> [CustomScanDirectory] {
        try CoreStorageIO.readJSON([CustomScanDirectory].self, at: storageURL) ?? []
    }

    /// 校验并新增一个自定义扫描目录
    @discardableResult
    public func add(
        url: URL,
        displayName: String? = nil,
        category: ScanCategory = .custom,
        mode: ScanTargetMode = .children,
        fileManager: FileManager = .default
    ) throws -> CustomScanDirectory {
        let platform = safetyGuard.platform
        let standardized = url.standardizedFileURL
        let normalizedPath = PlatformPath.normalize(standardized)

        let resolvedTarget = platform.resolveSymlinks(at: standardized)
        guard let targetIdentity = try? platform.identity(at: resolvedTarget) else {
            throw CustomDirectoryError.directoryNotFound(normalizedPath)
        }
        guard targetIdentity.kind == .directory else {
            throw CustomDirectoryError.notADirectory(normalizedPath)
        }

        let decision = safetyGuard.validateCustomDirectoryRoot(standardized)
        if let reason = decision.blockReason {
            throw CustomDirectoryError.protectedPath(reason)
        }

        var existing = try loadChecked()
        let candidateKey = PlatformPath.comparisonKey(
            PlatformPath.normalize(resolvedTarget),
            caseInsensitive: platform.pathsAreCaseInsensitive
        )
        if existing.contains(where: {
            let existingResolved = platform.resolveSymlinks(at: URL(fileURLWithPath: $0.path))
            let existingKey = PlatformPath.comparisonKey(
                PlatformPath.normalize(existingResolved),
                caseInsensitive: platform.pathsAreCaseInsensitive
            )
            return existingKey == candidateKey
        }) {
            throw CustomDirectoryError.duplicatePath(normalizedPath)
        }

        let trimmedName = displayName?.trimmedWhitespaceAndNewlines() ?? ""
        let resolvedName = trimmedName.isEmpty ? PlatformPath.lastPathComponent(normalizedPath) : trimmedName
        let entry = CustomScanDirectory(
            displayName: resolvedName,
            path: normalizedPath,
            category: category,
            mode: mode
        )
        existing.append(entry)
        try save(existing)
        return entry
    }

    /// 根据 ID 从扫描列表中移除自定义目录（仅移除配置记录，绝不删除磁盘目录）
    @discardableResult
    public func remove(id: UUID) throws -> [CustomScanDirectory] {
        var existing = try loadChecked()
        existing.removeAll { $0.id == id }
        try save(existing)
        return existing
    }

    /// 保存完整列表至 JSON 文件
    public func save(_ directories: [CustomScanDirectory]) throws {
        let parent = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(directories)
        try data.write(to: storageURL, options: .atomic)
    }
}
