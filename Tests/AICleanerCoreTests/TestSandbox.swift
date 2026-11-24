import Foundation

/// 测试专用隔离沙箱：在系统临时目录下构造独立假 Home 目录，严禁触碰宿主机真实用户目录。
final class TestSandbox {
    let rootURL: URL
    let homeURL: URL
    private let fileManager = FileManager.default

    init(prefix: String = "AICleanerCoreTests") throws {
        let base = fileManager.temporaryDirectory
        let unique = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let home = unique.appendingPathComponent("FakeHome", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        self.rootURL = unique.standardizedFileURL
        self.homeURL = home.standardizedFileURL
    }

    func cleanup() {
        try? fileManager.removeItem(at: rootURL)
    }

    @discardableResult
    func createDirectory(relativeToHome relativePath: String) throws -> URL {
        let dirURL = homeURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL.standardizedFileURL
    }

    @discardableResult
    func createFile(
        relativeToHome relativePath: String,
        byteCount: Int,
        modifiedAt: Date? = nil
    ) throws -> URL {
        let fileURL = homeURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: max(0, byteCount))
        try data.write(to: fileURL)
        if let modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
        }
        return fileURL.standardizedFileURL
    }

    @discardableResult
    func createSymlink(
        relativeToHome relativePath: String,
        destination: URL
    ) throws -> URL {
        let linkURL = homeURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: destination)
        return linkURL.standardizedFileURL
    }
}
