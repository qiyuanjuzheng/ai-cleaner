#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct ProjectProtectionStore: Sendable {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public init(platform: any PlatformAdapter) {
        self.storageURL = platform.userDataDirectory()
            .appendingPathComponent("protected-projects.json")
    }

    /// 严格失败关闭（fail-closed）：文件不存在时返回空集合；若文件存在但无法解析则抛错，防止清理流程误放行受保护项目。
    public func load() throws -> Set<String> {
        let fsPath = PlatformPath.fileSystemPath(for: storageURL)
        guard FileManager.default.fileExists(atPath: fsPath) else {
            return []
        }
        let data = try Data(contentsOf: storageURL)
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    public func save(_ projects: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(projects.sorted()).write(to: storageURL, options: .atomic)
    }
}
