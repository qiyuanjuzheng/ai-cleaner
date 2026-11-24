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

    func testPrecomputedSummaryAndReportTotalsMatchItemBreakdown() throws {
        // 混合建议清理（缓存）、按需清理（近期会话）与受保护数据（skills），验证 O(1) 预计算汇总与明细完全一致
        try sandbox.createFile(relativeToHome: ".claude/paste-cache/c1.txt", byteCount: 1_500)
        try sandbox.createFile(relativeToHome: ".claude/projects/demo/session-recent.jsonl", byteCount: 2_300)
        try sandbox.createFile(relativeToHome: ".claude/skills/my-skill/SKILL.md", byteCount: 4_100)
        try sandbox.createFile(relativeToHome: "Library/Application Support/Cursor/GPUCache/data_0", byteCount: 6_200)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        for summary in report.clientSummaries {
            XCTAssertEqual(summary.totalSizeBytes, summary.items.reduce(0) { $0 + $1.sizeBytes })
            XCTAssertEqual(summary.recommendedSizeBytes, summary.recommendedItems.reduce(0) { $0 + $1.sizeBytes })
            XCTAssertEqual(summary.reviewSuggestedSizeBytes, summary.reviewSuggestedItems.reduce(0) { $0 + $1.sizeBytes })
            XCTAssertEqual(summary.protectedSizeBytes, summary.protectedItems.reduce(0) { $0 + $1.sizeBytes })
            XCTAssertEqual(summary.totalDiskFootprintBytes, summary.totalSizeBytes + summary.protectedSizeBytes)
            XCTAssertEqual(summary.recommendedItemCount, summary.recommendedItems.count)
            XCTAssertEqual(summary.reviewSuggestedItemCount, summary.reviewSuggestedItems.count)
        }

        XCTAssertEqual(report.totalSizeBytes, 1_500 + 2_300 + 6_200)
        XCTAssertEqual(report.recommendedSizeBytes, 1_500 + 6_200)
        XCTAssertEqual(report.reviewSuggestedSizeBytes, 2_300)
        XCTAssertEqual(report.protectedSizeBytes, 4_100)
        XCTAssertEqual(report.totalDiskFootprintBytes, 1_500 + 2_300 + 6_200 + 4_100)
        XCTAssertEqual(report.totalItemCount, 3)
        XCTAssertEqual(report.totalRecommendedCount, 2)
        XCTAssertEqual(report.totalReviewSuggestedCount, 1)
        XCTAssertEqual(report.totalProtectedItemCount, 1)
    }
}
