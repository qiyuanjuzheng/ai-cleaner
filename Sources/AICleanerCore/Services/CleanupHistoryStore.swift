#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 持久化管理历史清理空间统计记录（存储于独立 JSON 文件，支持平台适配器与沙箱路径注入）。
public struct CleanupHistoryStore: Sendable {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public init(platform: any PlatformAdapter = HostPlatformAdapter.shared) {
        self.storageURL = platform.userDataDirectory()
            .appendingPathComponent("cleanup-history.json")
    }

    /// 读取全部历史清理记录（按时间正序）。若文件损坏则先备份保留再返回空数组（ADR 0001 第 7.3 节）。
    public func load() -> [CleanupHistoryRecord] {
        (try? loadChecked()) ?? []
    }

    public func loadChecked() throws -> [CleanupHistoryRecord] {
        try (CoreStorageIO.readJSON([CleanupHistoryRecord].self, at: storageURL) ?? [])
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 将一次成功的 `CleanupResult` 追加写入历史统计（若本次无实际移入条目则不写入）
    @discardableResult
    public func record(result: CleanupResult, at timestamp: Date? = nil) throws -> CleanupHistoryRecord? {
        guard let entry = CleanupHistoryRecord.from(result: result, at: timestamp) else {
            return nil
        }
        try append(entry)
        return entry
    }

    /// 追加单条历史记录并原子保存
    @discardableResult
    public func append(_ record: CleanupHistoryRecord) throws -> [CleanupHistoryRecord] {
        var existing = try loadChecked()
        existing.append(record)
        existing.sort { $0.timestamp < $1.timestamp }
        try save(existing)
        return existing
    }

    /// 删除单条统计记录（仅移除统计日志，绝不触碰任何磁盘或废纸篓文件）
    @discardableResult
    public func delete(id: UUID) throws -> [CleanupHistoryRecord] {
        var existing = try loadChecked()
        existing.removeAll { $0.id == id }
        try save(existing)
        return existing
    }

    /// 清空全部统计记录（仅清空统计日志，绝不触碰任何磁盘或废纸篓文件）
    public func clearAll() throws {
        _ = try loadChecked()
        try save([])
    }

    /// 原子保存全部记录到 JSON 文件
    public func save(_ records: [CleanupHistoryRecord]) throws {
        let parent = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(records)
        try data.write(to: storageURL, options: .atomic)
    }
}
