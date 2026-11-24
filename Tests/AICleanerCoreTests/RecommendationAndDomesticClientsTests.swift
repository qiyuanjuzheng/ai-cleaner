import AICleanerCore
import Foundation
import XCTest

private final class GuardedPerformerSpy: TrashPerforming, @unchecked Sendable {
    private(set) var calledPaths: [String] = []

    func trashItem(at url: URL) throws -> URL? {
        calledPaths.append(url.path)
        return url
    }
}

final class RecommendationAndDomesticClientsTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "RecommendationAndDomesticClientsTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testWorkBuddySeparatesRecommendedReviewAndProtectedItems() throws {
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let recentDate = Date()

        // 建议清理：traces 与 cache
        try sandbox.createFile(relativeToHome: ".workbuddy/traces/1001.log", byteCount: 3_000)
        try sandbox.createFile(relativeToHome: ".workbuddy/cache/data.bin", byteCount: 1_500)

        // 聊天会话：超过 14 天的任务目录和近期任务目录均为「按需清理」
        try sandbox.createFile(
            relativeToHome: "WorkBuddy/2026-09-01-10-00-00/output.txt",
            byteCount: 2_000,
            modifiedAt: oldDate
        )
        let oldTaskDir = sandbox.homeURL.appendingPathComponent("WorkBuddy/2026-09-01-10-00-00")
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldTaskDir.path)

        try sandbox.createFile(
            relativeToHome: "WorkBuddy/2026-11-23-10-00-00/draft.txt",
            byteCount: 1_200,
            modifiedAt: recentDate
        )

        // 不建议清理：binaries 与 skills
        try sandbox.createFile(relativeToHome: ".workbuddy/binaries/runtime.bin", byteCount: 10_000)
        try sandbox.createFile(relativeToHome: ".workbuddy/skills/my-skill/SKILL.md", byteCount: 400)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        let workBuddy = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "workbuddy" }))
        XCTAssertEqual(workBuddy.recommendedItems.count, 2) // traces + cache
        XCTAssertEqual(workBuddy.reviewSuggestedItems.count, 2) // old and recent WorkBuddy tasks
        XCTAssertEqual(workBuddy.protectedItems.count, 2) // binaries + skills
        XCTAssertEqual(workBuddy.totalSizeBytes, 7_700)
        XCTAssertEqual(workBuddy.protectedSizeBytes, 10_400)
        XCTAssertTrue(workBuddy.protectedItems.allSatisfy { !$0.isCleanable && $0.recommendation == .notRecommended })
    }

    func testDoubaoWorkPartnerScansTasksAndProtectsSkills() throws {
        try sandbox.createFile(relativeToHome: "Doubao/ppt-demo/slides.pptx", byteCount: 4_000)
        try sandbox.createFile(relativeToHome: "Doubao/skills/custom/SKILL.md", byteCount: 300)
        try sandbox.createFile(relativeToHome: "DoubaoWork/weekly-report/draft.md", byteCount: 1_000)
        try sandbox.createFile(relativeToHome: "DoubaoWork/skills/work-skill/SKILL.md", byteCount: 200)
        try sandbox.createFile(relativeToHome: "Library/Application Support/jianyin_agent/GPUCache/data_0", byteCount: 2_500)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        let doubao = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "doubao" }))
        XCTAssertEqual(doubao.recommendedItems.count, 1) // jianyin_agent GPUCache
        XCTAssertEqual(doubao.reviewSuggestedItems.count, 2) // ppt-demo + weekly-report
        XCTAssertEqual(doubao.protectedItems.count, 2) // Doubao/skills + DoubaoWork/skills
        XCTAssertFalse(doubao.items.contains { $0.fileName == "skills" })
    }

    func testTrashCleanerRefusesNotRecommendedItemsEvenIfPassedDirectly() throws {
        let binFile = try sandbox.createFile(relativeToHome: ".workbuddy/binaries/core.bin", byteCount: 1_024)
        let lockedItem = CleanableItem(
            clientID: "workbuddy",
            clientName: "WorkBuddy",
            ruleID: "workbuddy-protected-binaries",
            displayName: "内置运行时组件 (binaries)",
            fileName: "core.bin",
            url: binFile,
            category: .protectedData,
            recommendation: .notRecommended,
            safetyNote: "核心组件，不建议清理",
            sizeBytes: 1_024,
            fileCount: 1,
            modifiedAt: Date(),
            isDirectory: false,
            isCustom: false
        )

        let spy = GuardedPerformerSpy()
        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: spy
        )

        let result = cleaner.trash(items: [lockedItem])
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.skippedProtectedItems.count, 1)
        XCTAssertTrue(spy.calledPaths.isEmpty, "未显式确认风险覆盖时，不建议清理项绝不应触发 trashItem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: binFile.path))
    }

    func testScanDistinguishesHardProtectionFromRiskOverrides() throws {
        let paths = [
            ".codex/auth.json",
            ".local/share/opencode/opencode.db",
            ".workbuddy/security/current.dat",
            ".workbuddy-ai/plugins/demo/auth.json",
            ".workbuddy/plugins/demo/plugin.js",
            ".ollama/models/example.gguf"
        ]
        for path in paths {
            try sandbox.createFile(relativeToHome: path, byteCount: 64)
        }
        let report = ScanEngine(homeDirectory: sandbox.homeURL).scan()
        let items = Dictionary(uniqueKeysWithValues: report.allProtectedItems.map { ($0.ruleID, $0) })

        let hardLocked: [String: String] = [
            "codex-protected-auth": "auth.json",
            "opencode-protected-db": "opencode.db",
            "workbuddy-protected-security": "security",
            "workbuddy-ai-protected-plugins": "auth.json"
        ]
        for (ruleID, protectedName) in hardLocked {
            let item = try XCTUnwrap(items[ruleID])
            let reason = try XCTUnwrap(item.hardProtectionReason)
            XCTAssertTrue(reason.contains(protectedName))
            XCTAssertEqual(item.safetyNote, reason)
        }

        let plugins = try XCTUnwrap(items["workbuddy-protected-plugins"])
        let models = try XCTUnwrap(items["ollama-protected-models"])
        let overridable = [plugins, models]
        XCTAssertTrue(overridable.allSatisfy { $0.hardProtectionReason == nil && !$0.isCleanable })

        let spy = GuardedPerformerSpy()
        let cleaner = TrashCleaner(safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL), performer: spy)
        let normal = cleaner.trash(items: overridable)
        XCTAssertEqual(normal.skippedProtectedItems.count, 2)
        XCTAssertTrue(spy.calledPaths.isEmpty)

        let override = cleaner.trash(items: overridable, allowNotRecommendedOverride: true)
        XCTAssertEqual(override.trashedCount, 2)
        XCTAssertEqual(Set(spy.calledPaths), Set(overridable.map { $0.url.path }))
    }

    func testRiskOverrideStillBlocksClientRootsAndSensitivePaths() throws {
        let clientRoot = try sandbox.createDirectory(relativeToHome: ".claude")
        let sensitiveFile = try sandbox.createFile(relativeToHome: ".ssh/other.dat", byteCount: 64)
        let items = [clientRoot, sensitiveFile].map { url in
            CleanableItem(
                clientID: "fixture",
                clientName: "Fixture",
                ruleID: "fixture-rule",
                displayName: url.lastPathComponent,
                fileName: url.lastPathComponent,
                url: url,
                category: .protectedData,
                safetyNote: "fixture",
                sizeBytes: 64,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: url == clientRoot,
                isCustom: false
            )
        }
        let spy = GuardedPerformerSpy()
        let cleaner = TrashCleaner(safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL), performer: spy)
        let result = cleaner.trash(items: items, allowNotRecommendedOverride: true)
        XCTAssertEqual(result.skippedProtectedItems.count, 2)
        XCTAssertTrue(spy.calledPaths.isEmpty)
    }
}
