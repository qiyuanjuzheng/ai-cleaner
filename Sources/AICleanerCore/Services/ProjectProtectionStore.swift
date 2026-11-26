import Foundation

public struct ProjectProtectionStore: Sendable {
    public let storageURL: URL

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? ExcludedItemStore().storageURL
            .deletingLastPathComponent().appendingPathComponent("protected-projects.json")
    }

    public func load() throws -> Set<String> {
        do {
            let data = try Data(contentsOf: storageURL)
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    public func save(_ projects: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(projects.sorted()).write(to: storageURL, options: .atomic)
    }
}
