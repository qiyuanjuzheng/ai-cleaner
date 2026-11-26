import Foundation
import XCTest
@testable import AICleanerCore
#if os(Windows)
import CPlatformSupport
#endif

final class PlatformAdapterTests: XCTestCase {
    func testUnavailableTrashLeavesSourceAndContentsIntact() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let source = try sandbox.createFile(relativeToHome: "cache/ephemeral.bin", byteCount: 16)
        let original = try Data(contentsOf: source)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            homeDirectory: sandbox.homeURL,
            moveToTrashOverride: { _ in throw TrashError.unavailable("unavailable") }
        )
        let result = TrashCleaner(platform: platform).trash(items: [makeItem(source)])

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.failedItems.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    #if !os(Windows)
    func testCleanupPreservesLiteralBackslashInPOSIXFileName() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let source = try sandbox.createFile(relativeToHome: "cache/name\\part.bin", byteCount: 16)
        let neighbor = try sandbox.createFile(relativeToHome: "cache/name/part.bin", byteCount: 64)
        let trash = try sandbox.createDirectory(relativeToHome: "trash")
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared, homeDirectory: sandbox.homeURL, mockTrashDirectory: trash
        )

        let result = TrashCleaner(platform: platform).trash(items: [makeItem(source)])

        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: neighbor).count, 64)
        let destination = try XCTUnwrap(result.trashedItems.first?.resultingTrashURL)
        XCTAssertEqual(try Data(contentsOf: destination).count, 16)
    }
    #endif

    #if os(Windows)
    func testWindowsJunctionIsNotTraversedOrRecycled() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let payload = try sandbox.createFile(relativeToHome: "outside/payload.bin", byteCount: 16)
        let cache = try sandbox.createDirectory(relativeToHome: "cache")
        let junction = cache.appendingPathComponent("junction", isDirectory: true)
        let adapter = HostPlatformAdapter.shared
        XCTAssertTrue(aicl_windows_create_junction(
            PlatformPath.fileSystemPath(for: junction),
            PlatformPath.fileSystemPath(for: payload.deletingLastPathComponent())
        ))
        XCTAssertTrue(try adapter.identity(at: junction).kind.isLinkOrReparsePoint)
        XCTAssertThrowsError(try adapter.contentsOfDirectory(at: junction))
        XCTAssertThrowsError(try adapter.moveToTrash(junction))
        XCTAssertEqual(try Data(contentsOf: payload).count, 16)
    }
    #endif

    private func makeItem(_ source: URL) -> CleanableItem {
        CleanableItem(
            clientID: "test", clientName: "Test", ruleID: "cache", displayName: "Cache",
            fileName: source.lastPathComponent, url: source, category: .cache, safetyNote: "",
            sizeBytes: 16, fileCount: 1, modifiedAt: Date(), isDirectory: false, isCustom: false
        )
    }

    #if os(Linux)
    func testLinuxTrashMovesPayloadAndWritesRestorableMetadata() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let source = try sandbox.createFile(relativeToHome: "cache/a #汉.bin", byteCount: 16)
        let original = try Data(contentsOf: source)
        let dataHome = sandbox.homeURL.appendingPathComponent("data", isDirectory: true)

        let result = try LinuxTrash.move(source, dataHome: dataHome, platform: HostPlatformAdapter.shared)

        guard case let .trashed(destination?) = result else { return XCTFail("Missing trash destination") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let metadata = dataHome.appendingPathComponent("Trash/info/\(destination.lastPathComponent).trashinfo")
        let contents = try String(contentsOf: metadata, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("[Trash Info]\nPath="))
        XCTAssertTrue(contents.contains("/cache/a%20%23%E6%B1%89.bin\nDeletionDate="))
    }

    func testLinuxTrashRefusesSymlinkedFilesDirectory() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let source = try sandbox.createFile(relativeToHome: "cache/ephemeral.bin", byteCount: 16)
        let original = try Data(contentsOf: source)
        let trashRoot = try sandbox.createDirectory(relativeToHome: "data/Trash")
        let outside = try sandbox.createDirectory(relativeToHome: "outside")
        try FileManager.default.createSymbolicLink(
            at: trashRoot.appendingPathComponent("files"), withDestinationURL: outside
        )

        XCTAssertThrowsError(try LinuxTrash.move(
            source, dataHome: trashRoot.deletingLastPathComponent(), platform: HostPlatformAdapter.shared
        ))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    #endif
}
