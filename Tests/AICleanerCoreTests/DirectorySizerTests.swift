import AICleanerCore
import Foundation
import XCTest

final class DirectorySizerTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "DirectorySizerTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testInspectSingleFileReturnsExactSize() throws {
        let fileURL = try sandbox.createFile(relativeToHome: "work/sample.log", byteCount: 4096)
        let sizer = DirectorySizer()

        let result = try XCTUnwrap(sizer.inspect(url: fileURL))
        XCTAssertFalse(result.isDirectory)
        XCTAssertEqual(result.sizeBytes, 4096)
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertNil(result.protectedDescendantReason)
    }

    func testInspectNestedDirectoryComputesExactBytesAndFileCount() throws {
        let rootDir = try sandbox.createDirectory(relativeToHome: "cache-root")
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_750_000_000)

        try sandbox.createFile(relativeToHome: "cache-root/a.bin", byteCount: 1024, modifiedAt: olderDate)
        try sandbox.createFile(relativeToHome: "cache-root/sub/b.bin", byteCount: 2048, modifiedAt: newerDate)
        try sandbox.createFile(relativeToHome: "cache-root/sub/deep/c.bin", byteCount: 512, modifiedAt: olderDate)

        let sizer = DirectorySizer()
        let result = try XCTUnwrap(sizer.inspect(url: rootDir))

        XCTAssertTrue(result.isDirectory)
        XCTAssertEqual(result.sizeBytes, 3584)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertGreaterThanOrEqual(result.modifiedAt.timeIntervalSince1970, newerDate.timeIntervalSince1970 - 1)
    }

    func testInspectDoesNotFollowSymlinkedDirectory() throws {
        let externalDir = try sandbox.createDirectory(relativeToHome: "external-big")
        try sandbox.createFile(relativeToHome: "external-big/huge.bin", byteCount: 50_000)

        let cacheDir = try sandbox.createDirectory(relativeToHome: "cache-with-link")
        try sandbox.createFile(relativeToHome: "cache-with-link/small.tmp", byteCount: 300)
        try sandbox.createSymlink(relativeToHome: "cache-with-link/escape-link", destination: externalDir)

        let sizer = DirectorySizer()
        let result = try XCTUnwrap(sizer.inspect(url: cacheDir))

        // 不应把 external-big 的 50,000 字节计入 cache-with-link
        XCTAssertLessThan(result.sizeBytes, 5_000)
        XCTAssertEqual(result.fileCount, 2)
    }

    func testInspectDetectsProtectedDescendantInsideDirectory() throws {
        let cacheDir = try sandbox.createDirectory(relativeToHome: "mixed-cache")
        try sandbox.createFile(relativeToHome: "mixed-cache/chunk.tmp", byteCount: 1000)
        try sandbox.createFile(relativeToHome: "mixed-cache/nested/auth.json", byteCount: 128)

        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        let sizer = DirectorySizer()
        let result = try XCTUnwrap(sizer.inspect(url: cacheDir, safetyGuard: guardInstance))

        XCTAssertNotNil(result.protectedDescendantReason)
        XCTAssertTrue(result.protectedDescendantReason?.contains("auth.json") == true)
    }

    func testInspectMissingPathReturnsNil() {
        let missing = sandbox.homeURL.appendingPathComponent("does-not-exist")
        XCTAssertNil(DirectorySizer().inspect(url: missing))
    }
}
