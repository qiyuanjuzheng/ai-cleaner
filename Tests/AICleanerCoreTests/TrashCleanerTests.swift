import AICleanerCore
import Foundation
import XCTest

/// 测试隔离替身：将目标移动到沙箱内部的模拟废纸篓目录，验证完整清理链路而不影响系统环境。
private final class SandboxTrashPerformer: TrashPerforming, @unchecked Sendable {
    let mockTrashDir: URL
    var failingPaths: Set<String> = []
    private(set) var trashedInputPaths: [String] = []

    init(mockTrashDir: URL) throws {
        self.mockTrashDir = mockTrashDir
        try FileManager.default.createDirectory(at: mockTrashDir, withIntermediateDirectories: true)
    }

    func trashItem(at url: URL) throws -> URL? {
        trashedInputPaths.append(url.standardizedFileURL.path)
        if failingPaths.contains(url.standardizedFileURL.path) {
            throw NSError(domain: "SandboxTrashPerformer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "模拟磁盘权限或文件占用错误"
            ])
        }
        let destination = mockTrashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class TrashCleanerTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "TrashCleanerTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testTrashCleanerMovesSafeItemsAndCalculatesActualFreedBytes() throws {
        let logA = try sandbox.createFile(relativeToHome: ".claude/debug/a.log", byteCount: 1_500)
        let logB = try sandbox.createFile(relativeToHome: ".claude/debug/b.log", byteCount: 2_500)

        let performer = try SandboxTrashPerformer(
            mockTrashDir: sandbox.rootURL.appendingPathComponent("MockTrash", isDirectory: true)
        )
        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: performer
        )

        let items = [
            makeItem(url: logA, sizeBytes: 1_500, isDirectory: false),
            makeItem(url: logB, sizeBytes: 2_500, isDirectory: false)
        ]

        let result = cleaner.trash(items: items)

        XCTAssertEqual(result.trashedCount, 2)
        XCTAssertEqual(result.freedBytes, 4_000)
        XCTAssertTrue(result.skippedProtectedItems.isEmpty)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logB.path))
        for record in result.trashedItems {
            let trashURL = try XCTUnwrap(record.resultingTrashURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
        }
    }

    func testTrashCleanerBlocksProtectedItemBeforeCallingPerformer() throws {
        let secret = try sandbox.createFile(relativeToHome: ".codex/auth.json", byteCount: 256)
        let contaminatedDir = try sandbox.createDirectory(relativeToHome: "custom-cache")
        try sandbox.createFile(relativeToHome: "custom-cache/ok.tmp", byteCount: 512)
        try sandbox.createFile(relativeToHome: "custom-cache/user.sqlite", byteCount: 1024)

        let performer = try SandboxTrashPerformer(
            mockTrashDir: sandbox.rootURL.appendingPathComponent("MockTrash", isDirectory: true)
        )
        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: performer
        )

        let result = cleaner.trash(items: [
            makeItem(url: secret, sizeBytes: 256, isDirectory: false),
            makeItem(url: contaminatedDir, sizeBytes: 1536, isDirectory: true)
        ])

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(result.skippedProtectedItems.count, 2)
        XCTAssertTrue(performer.trashedInputPaths.isEmpty, "安全策略拦截后绝不应调用 trashItem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contaminatedDir.path))
    }

    func testTrashCleanerDeduplicatesNestedItemsAndIsolatesFailures() throws {
        let parentDir = try sandbox.createDirectory(relativeToHome: "cache-group")
        let childFile = try sandbox.createFile(relativeToHome: "cache-group/inner.tmp", byteCount: 1_000)
        let lockedFile = try sandbox.createFile(relativeToHome: "other-logs/locked.log", byteCount: 700)

        let performer = try SandboxTrashPerformer(
            mockTrashDir: sandbox.rootURL.appendingPathComponent("MockTrash", isDirectory: true)
        )
        performer.failingPaths.insert(lockedFile.standardizedFileURL.path)

        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: performer
        )

        let result = cleaner.trash(items: [
            makeItem(url: childFile, sizeBytes: 1_000, isDirectory: false),
            makeItem(url: parentDir, sizeBytes: 1_000, isDirectory: true),
            makeItem(url: lockedFile, sizeBytes: 700, isDirectory: false)
        ])

        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.freedBytes, 1_000)
        XCTAssertEqual(result.failedItems.count, 1)
        XCTAssertEqual(result.failedItems.first?.item.url.path, lockedFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedFile.path))
    }

    func testSystemTrashPerformerUsesRealMacOSTrashOnIsolatedTempFile() throws {
        // 仅针对本次测试在临时目录新建的一次性文件验证真实 FileManager.trashItem，
        // 并在 defer 中精确清理测试产物，绝不触碰任何宿主真实数据或残留废纸篓垃圾。
        let tempFile = try sandbox.createFile(relativeToHome: "real-trash-smoke/ephemeral.tmp", byteCount: 2_048)
        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: SystemTrashPerformer()
        )

        let result = cleaner.trash(items: [
            makeItem(url: tempFile, sizeBytes: 2_048, isDirectory: false)
        ])

        defer {
            if let trashedURL = result.trashedItems.first?.resultingTrashURL {
                try? FileManager.default.removeItem(at: trashedURL)
            }
        }

        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.freedBytes, 2_048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))

        let trashURL = try XCTUnwrap(result.trashedItems.first?.resultingTrashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    private func makeItem(url: URL, sizeBytes: Int64, isDirectory: Bool) -> CleanableItem {
        CleanableItem(
            clientID: "test-client",
            clientName: "Test Client",
            ruleID: "test-rule",
            displayName: url.lastPathComponent,
            fileName: url.lastPathComponent,
            url: url,
            category: .temporary,
            safetyNote: "测试用临时条目",
            sizeBytes: sizeBytes,
            fileCount: 1,
            modifiedAt: Date(),
            isDirectory: isDirectory,
            isCustom: false
        )
    }
}
