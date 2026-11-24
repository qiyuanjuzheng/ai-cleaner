import Foundation

/// 自定义扫描目录管理错误
public enum CustomDirectoryError: LocalizedError, Equatable, Sendable {
    case directoryNotFound(String)
    case notADirectory(String)
    case protectedPath(String)
    case duplicatePath(String)

    public var errorDescription: String? {
        switch self {
        case let .directoryNotFound(path):
            return "目录不存在：\(path)"
        case let .notADirectory(path):
            return "所选路径不是文件夹：\(path)"
        case let .protectedPath(reason):
            return "出于安全限制，无法添加该目录：\(reason)"
        case let .duplicatePath(path):
            return "该目录已在自定义扫描列表中：\(path)"
        }
    }
}

/// 持久化管理用户新增与移除的自定义扫描目录（存储于独立 JSON 文件，支持测试注入路径）。
public struct CustomDirectoryStore: Sendable {
    public let storageURL: URL
    public let safetyGuard: SafetyGuard

    public init(
        storageURL: URL? = nil,
        safetyGuard: SafetyGuard = SafetyGuard()
    ) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storageURL = appSupport
                .appendingPathComponent("AICleaner", isDirectory: true)
                .appendingPathComponent("custom-directories.json")
        }
        self.safetyGuard = safetyGuard
    }

    /// 读取当前保存的所有自定义目录
    public func load() -> [CustomScanDirectory] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CustomScanDirectory].self, from: data)) ?? []
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
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDir) else {
            throw CustomDirectoryError.directoryNotFound(standardized.path)
        }
        guard isDir.boolValue else {
            throw CustomDirectoryError.notADirectory(standardized.path)
        }

        let decision = safetyGuard.validateCustomDirectoryRoot(standardized)
        if let reason = decision.blockReason {
            throw CustomDirectoryError.protectedPath(reason)
        }

        var existing = load()
        let resolvedCandidate = standardized.resolvingSymlinksInPath().standardizedFileURL.path
        if existing.contains(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == resolvedCandidate
        }) {
            throw CustomDirectoryError.duplicatePath(standardized.path)
        }

        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmedName.isEmpty ? standardized.lastPathComponent : trimmedName
        let entry = CustomScanDirectory(
            displayName: resolvedName,
            path: standardized.path,
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
        var existing = load()
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
