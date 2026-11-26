#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 基于规范化路径的排除条目匹配器：
/// - 支持精确路径匹配与目录子树边界匹配（`/a/dir` 匹配 `/a/dir` 及 `/a/dir/...`，绝不误匹配 `/a/dir2` 或 `/a/dir.jsonl`）；
/// - 平台感知：兼容 macOS `/var` ↔ `/private/var`、Windows 盘符与大小写不敏感、Linux 大小写敏感。
public struct ExcludedItemMatcher: Sendable, Hashable {
    private let exactPaths: Set<String>
    private let directoryPrefixes: [String]
    private let caseInsensitive: Bool

    public var isEmpty: Bool {
        exactPaths.isEmpty
    }

    public init(records: [ExcludedItemRecord] = [], caseInsensitive: Bool? = nil) {
        self.init(paths: records.map(\.normalizedPath), caseInsensitive: caseInsensitive)
    }

    public init(paths: [String], caseInsensitive: Bool? = nil) {
        let ci = caseInsensitive ?? Self.defaultCaseInsensitive
        self.caseInsensitive = ci

        var exact: Set<String> = []
        var prefixes: Set<String> = []

        for raw in paths {
            for variant in Self.pathVariants(for: raw, caseInsensitive: ci) {
                exact.insert(variant)
                if !PlatformPath.isRoot(variant) {
                    prefixes.insert(variant + "/")
                }
            }
        }

        self.exactPaths = exact
        self.directoryPrefixes = Array(prefixes)
    }

    public func isExcluded(_ url: URL) -> Bool {
        guard !exactPaths.isEmpty else { return false }
        return isExcluded(path: PlatformPath.fileSystemPath(for: url))
    }

    public func isExcluded(path: String) -> Bool {
        guard !exactPaths.isEmpty else { return false }

        let normalized = Self.normalizePath(path)
        let directKey = caseInsensitive ? normalized.lowercased() : normalized
        if matchesDirect(directKey) {
            return true
        }

        let resolved = Self.canonicalMatchPath(normalized)
        let resolvedKey = caseInsensitive ? resolved.lowercased() : resolved
        if resolvedKey != directKey && matchesDirect(resolvedKey) {
            return true
        }

        return false
    }

    private func matchesDirect(_ candidate: String) -> Bool {
        if exactPaths.contains(candidate) {
            return true
        }
        for prefix in directoryPrefixes where candidate.hasPrefix(prefix) {
            return true
        }
        return false
    }

    public static func normalizePath(_ url: URL) -> String {
        PlatformPath.normalize(url)
    }

    public static func normalizePath(_ path: String) -> String {
        PlatformPath.normalize(path)
    }

    public static func canonicalMatchPath(_ path: String) -> String {
        let normalized = PlatformPath.normalize(path)
        let resolved = PlatformPath.resolveSymlinks(URL(fileURLWithPath: normalized))
        return PlatformPath.normalize(resolved)
    }

    private static var defaultCaseInsensitive: Bool {
        #if os(Linux)
        return false
        #else
        return true
        #endif
    }

    private static func pathVariants(for path: String, caseInsensitive: Bool) -> [String] {
        let normalized = normalizePath(path)
        let resolved = canonicalMatchPath(normalized)
        let nKey = caseInsensitive ? normalized.lowercased() : normalized
        let rKey = caseInsensitive ? resolved.lowercased() : resolved
        if nKey == rKey {
            return [nKey]
        }
        return [nKey, rKey]
    }
}

/// 持久化管理用户排除的清理条目清单（存储于独立 JSON 文件，支持平台适配器与测试路径注入）。
public struct ExcludedItemStore: Sendable {
    public let storageURL: URL
    private let caseInsensitive: Bool

    public init(storageURL: URL, caseInsensitive: Bool? = nil) {
        self.storageURL = storageURL
        #if os(Linux)
        self.caseInsensitive = caseInsensitive ?? false
        #else
        self.caseInsensitive = caseInsensitive ?? true
        #endif
    }

    public init(platform: any PlatformAdapter = HostPlatformAdapter.shared) {
        self.storageURL = platform.userDataDirectory()
            .appendingPathComponent("excluded-items.json")
        self.caseInsensitive = platform.pathsAreCaseInsensitive
    }

    /// 读取全部已排除记录（按规范化路径去重，最近排除排在前面）。若文件损坏则先备份保留再返回空数组（ADR 0001 第 7.3 节）。
    public func load() -> [ExcludedItemRecord] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ExcludedItemRecord].self, from: data) else {
            CoreStorageIO.quarantineCorruptFile(at: storageURL)
            return []
        }
        return deduplicateAndSort(decoded)
    }

    /// 新增排除记录（按规范化后的完整路径匹配，重复排除保持幂等）
    @discardableResult
    public func add(_ record: ExcludedItemRecord) throws -> [ExcludedItemRecord] {
        var existing = load()
        let candidateCanonical = canonicalKey(record.normalizedPath)
        if existing.contains(where: {
            canonicalKey($0.normalizedPath) == candidateCanonical
        }) {
            return existing
        }

        existing.append(record)
        let sorted = deduplicateAndSort(existing)
        try save(sorted)
        return sorted
    }

    /// 将单条扫描结果加入本地排除清单（幂等）
    @discardableResult
    public func exclude(item: CleanableItem, at date: Date = Date()) throws -> [ExcludedItemRecord] {
        try add(ExcludedItemRecord.from(item: item, excludedAt: date))
    }

    /// 按记录 ID 从排除清单移除（恢复展示）
    @discardableResult
    public func remove(id: UUID) throws -> [ExcludedItemRecord] {
        var existing = load()
        let beforeCount = existing.count
        existing.removeAll { $0.id == id }
        if existing.count != beforeCount {
            try save(existing)
        }
        return existing
    }

    /// 按路径从排除清单移除（按规范化路径匹配）
    @discardableResult
    public func remove(path: String) throws -> [ExcludedItemRecord] {
        var existing = load()
        let targetCanonical = canonicalKey(path)
        let beforeCount = existing.count
        existing.removeAll {
            canonicalKey($0.normalizedPath) == targetCanonical
        }
        if existing.count != beforeCount {
            try save(existing)
        }
        return existing
    }

    /// 清空全部排除记录（全部恢复）
    @discardableResult
    public func removeAll() throws -> [ExcludedItemRecord] {
        try save([])
        return []
    }

    /// 原子保存全部排除记录至 JSON 文件
    public func save(_ records: [ExcludedItemRecord]) throws {
        let parent = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let sorted = deduplicateAndSort(records)
        let data = try encoder.encode(sorted)
        try data.write(to: storageURL, options: .atomic)
    }

    private func canonicalKey(_ path: String) -> String {
        let canonical = ExcludedItemMatcher.canonicalMatchPath(path)
        return caseInsensitive ? canonical.lowercased() : canonical
    }

    private func deduplicateAndSort(_ records: [ExcludedItemRecord]) -> [ExcludedItemRecord] {
        let sorted = records.sorted { lhs, rhs in
            if lhs.excludedAt != rhs.excludedAt {
                return lhs.excludedAt > rhs.excludedAt
            }
            return lhs.normalizedPath < rhs.normalizedPath
        }
        var seen: Set<String> = []
        var unique: [ExcludedItemRecord] = []
        unique.reserveCapacity(sorted.count)
        for record in sorted {
            let key = canonicalKey(record.normalizedPath)
            if seen.insert(key).inserted {
                unique.append(record)
            }
        }
        return unique
    }
}
