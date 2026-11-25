import Foundation

/// 基于规范化路径的排除条目匹配器：
/// - 支持精确路径匹配与目录子树边界匹配（`/a/dir` 匹配 `/a/dir` 及 `/a/dir/...`，绝不误匹配 `/a/dir2` 或 `/a/dir.jsonl`）；
/// - 同时兼容 macOS `/var` ↔ `/private/var` 等符号链接路径标准化。
public struct ExcludedItemMatcher: Sendable, Hashable {
    private let exactPaths: Set<String>
    private let directoryPrefixes: [String]

    public var isEmpty: Bool {
        exactPaths.isEmpty
    }

    public init(records: [ExcludedItemRecord] = []) {
        var exact: Set<String> = []
        var prefixes: Set<String> = []

        for record in records {
            for variant in Self.pathVariants(for: record.normalizedPath) {
                exact.insert(variant)
                if variant != "/" {
                    prefixes.insert(variant + "/")
                }
            }
        }

        self.exactPaths = exact
        self.directoryPrefixes = Array(prefixes)
    }

    public init(paths: [String]) {
        var exact: Set<String> = []
        var prefixes: Set<String> = []

        for raw in paths {
            for variant in Self.pathVariants(for: raw) {
                exact.insert(variant)
                if variant != "/" {
                    prefixes.insert(variant + "/")
                }
            }
        }

        self.exactPaths = exact
        self.directoryPrefixes = Array(prefixes)
    }

    public func isExcluded(_ url: URL) -> Bool {
        guard !exactPaths.isEmpty else { return false }
        return isExcluded(path: url.standardizedFileURL.path)
    }

    public func isExcluded(path: String) -> Bool {
        guard !exactPaths.isEmpty else { return false }

        let normalized = Self.normalizePath(path)
        if matchesDirect(normalized) {
            return true
        }

        let resolved = Self.canonicalMatchPath(normalized)
        if resolved != normalized && matchesDirect(resolved) {
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
        normalizePath(url.standardizedFileURL.path)
    }

    public static func normalizePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.count > 1 else { return standardized }
        var trimmed = standardized
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public static func canonicalMatchPath(_ path: String) -> String {
        let normalized = normalizePath(path)
        let resolved = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
        return normalizePath(resolved)
    }

    private static func pathVariants(for path: String) -> [String] {
        let normalized = normalizePath(path)
        let resolved = canonicalMatchPath(normalized)
        if normalized == resolved {
            return [normalized]
        }
        return [normalized, resolved]
    }
}

/// 持久化管理用户排除的清理条目清单（存储于独立 JSON 文件，支持测试与沙箱路径注入）。
public struct ExcludedItemStore: Sendable {
    public let storageURL: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storageURL = appSupport
                .appendingPathComponent("AICleaner", isDirectory: true)
                .appendingPathComponent("excluded-items.json")
        }
    }

    /// 读取全部已排除记录（按规范化路径去重，最近排除排在前面）
    public func load() -> [ExcludedItemRecord] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ExcludedItemRecord].self, from: data) else {
            return []
        }
        return Self.deduplicateAndSort(decoded)
    }

    /// 新增排除记录（按规范化后的完整路径匹配，重复排除保持幂等）
    @discardableResult
    public func add(_ record: ExcludedItemRecord) throws -> [ExcludedItemRecord] {
        var existing = load()
        let candidateCanonical = ExcludedItemMatcher.canonicalMatchPath(record.normalizedPath)
        if existing.contains(where: {
            ExcludedItemMatcher.canonicalMatchPath($0.normalizedPath) == candidateCanonical
        }) {
            return existing
        }

        existing.append(record)
        let sorted = Self.deduplicateAndSort(existing)
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
        let targetCanonical = ExcludedItemMatcher.canonicalMatchPath(path)
        let beforeCount = existing.count
        existing.removeAll {
            ExcludedItemMatcher.canonicalMatchPath($0.normalizedPath) == targetCanonical
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

        let sorted = Self.deduplicateAndSort(records)
        let data = try encoder.encode(sorted)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func deduplicateAndSort(_ records: [ExcludedItemRecord]) -> [ExcludedItemRecord] {
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
            let key = ExcludedItemMatcher.canonicalMatchPath(record.normalizedPath)
            if seen.insert(key).inserted {
                unique.append(record)
            }
        }
        return unique
    }
}
