import AICleanerCore
import Foundation
import XCTest

final class ScanEngineTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "ScanEngineTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testScanShowsOnlyExistingClientsAndExcludesProtectedFiles() throws {
        // 构造 Claude Code 缓存与调试日志（包含应被跳过的受保护文件）
        try sandbox.createFile(relativeToHome: ".claude/paste-cache/snippet-1.txt", byteCount: 2_000)
        try sandbox.createFile(relativeToHome: ".claude/debug/session-01.log", byteCount: 500)
        try sandbox.createFile(relativeToHome: ".claude/debug/auth.json", byteCount: 100)
        try sandbox.createFile(relativeToHome: ".claude/settings.json", byteCount: 300)

        // 构造 Cursor GPU 缓存（体积更大，应排在首位）
        try sandbox.createFile(relativeToHome: "Library/Application Support/Cursor/GPUCache/data_0", byteCount: 8_000)
        try sandbox.createFile(relativeToHome: "Library/Application Support/Cursor/Cookies", byteCount: 1_024)

        // 构造一个混入了 .env 的 Codex 缓存目录，整目录应因安全策略被跳过
        try sandbox.createFile(relativeToHome: ".codex/cache/item.bin", byteCount: 4_000)
        try sandbox.createFile(relativeToHome: ".codex/cache/.env", byteCount: 64)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        // 仅检测到实际存在且通过安全校验的 Cursor 与 Claude Code；未安装的 Windsurf/ChatGPT/OpenCode 及被拦截的 Codex 不展示
        XCTAssertEqual(report.detectedBuiltInClientsCount, 2)
        XCTAssertEqual(report.clientSummaries.map(\.profile.id), ["cursor", "claude-code"])
        XCTAssertGreaterThanOrEqual(report.skippedProtectedCount, 2)

        let cursorSummary = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "cursor" }))
        XCTAssertEqual(cursorSummary.totalSizeBytes, 8_000)
        XCTAssertEqual(cursorSummary.items.count, 1)
        XCTAssertEqual(cursorSummary.items.first?.fileName, "GPUCache")

        let claudeSummary = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "claude-code" }))
        XCTAssertEqual(claudeSummary.totalSizeBytes, 2_500)
        XCTAssertEqual(claudeSummary.items.count, 2)
        XCTAssertFalse(claudeSummary.items.contains(where: { $0.fileName == "auth.json" }))
        XCTAssertFalse(claudeSummary.items.contains(where: { $0.fileName == "settings.json" }))
    }

    func testScanIsStrictlyReadOnly() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_730_000_000)
        let fileURL = try sandbox.createFile(
            relativeToHome: ".claude/paste-cache/readonly-check.txt",
            byteCount: 1_234,
            modifiedAt: fixedDate
        )
        let originalData = try Data(contentsOf: fileURL)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        XCTAssertEqual(report.totalItemCount, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        let afterDate = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(afterDate?.timeIntervalSince1970 ?? 0, fixedDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testScanIncludesCustomDirectoriesAndFiltersSensitiveChildren() throws {
        let customDir = try sandbox.createDirectory(relativeToHome: "my-ai-exports")
        try sandbox.createFile(relativeToHome: "my-ai-exports/temp-preview.png", byteCount: 3_000)
        try sandbox.createFile(relativeToHome: "my-ai-exports/secret_api_key.txt", byteCount: 120)
        try sandbox.createFile(relativeToHome: "my-ai-exports/records.sqlite", byteCount: 4_000)

        let emptyCustomDir = try sandbox.createDirectory(relativeToHome: "my-empty-scratch")

        let customList = [
            CustomScanDirectory(displayName: "AI 临时导出", path: customDir.path, category: .temporary, mode: .children),
            CustomScanDirectory(displayName: "空草稿目录", path: emptyCustomDir.path, category: .custom, mode: .children)
        ]

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan(customDirectories: customList)

        XCTAssertEqual(report.clientSummaries.count, 2)

        let exportsSummary = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.name == "AI 临时导出" }))
        XCTAssertEqual(exportsSummary.items.count, 1)
        XCTAssertEqual(exportsSummary.items.first?.fileName, "temp-preview.png")
        XCTAssertEqual(exportsSummary.totalSizeBytes, 3_000)
        XCTAssertEqual(exportsSummary.skippedProtectedCount, 2)

        // 空自定义目录依然保留在侧边栏分组中以便用户查看与移除
        let emptySummary = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.name == "空草稿目录" }))
        XCTAssertTrue(emptySummary.items.isEmpty)
    }
}
