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

        // 聊天会话：超过 14 天的任务目录自动升级为「建议清理」，近期任务目录保持「按需清理」
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
        XCTAssertEqual(workBuddy.recommendedItems.count, 3) // traces + cache + old WorkBuddy task
        XCTAssertEqual(workBuddy.reviewSuggestedItems.count, 1) // recent WorkBuddy task
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

    func testTrashCleanerAllowsExplicitNotRecommendedOverrideWhileStillBlockingSystemAndRootPaths() throws {
        // 1. 具体受保护子项（含 skills/binaries/auth.json/db 等）在用户显式覆盖时允许移入废纸篓
        let skillsDir = try sandbox.createFile(relativeToHome: ".workbuddy/skills/demo/SKILL.md", byteCount: 600)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authFile = try sandbox.createFile(relativeToHome: ".codex/auth.json", byteCount: 128)
        let dbFile = try sandbox.createFile(relativeToHome: ".local/share/opencode/opencode.db", byteCount: 4_096)

        // 2. 即便开启覆盖，客户端根目录（~/.claude）与敏感隐私目录（~/.ssh）依然必须死守拦住
        let clientRoot = try sandbox.createFile(relativeToHome: ".claude/settings.json", byteCount: 64)
            .deletingLastPathComponent()
        let sshKey = try sandbox.createFile(relativeToHome: ".ssh/id_ed25519", byteCount: 256)

        let items: [CleanableItem] = [
            CleanableItem(
                clientID: "workbuddy",
                clientName: "WorkBuddy",
                ruleID: "workbuddy-protected-skills",
                displayName: "技能库 (skills)",
                fileName: "skills",
                url: skillsDir,
                category: .protectedData,
                recommendation: .notRecommended,
                safetyNote: "保存自定义技能库，不建议清理",
                sizeBytes: 600,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: true,
                isCustom: false
            ),
            CleanableItem(
                clientID: "codex",
                clientName: "Codex",
                ruleID: "codex-protected-auth",
                displayName: "登录凭据 (auth.json)",
                fileName: "auth.json",
                url: authFile,
                category: .protectedData,
                recommendation: .notRecommended,
                safetyNote: "删除后需重新登录",
                sizeBytes: 128,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: false,
                isCustom: false
            ),
            CleanableItem(
                clientID: "opencode",
                clientName: "OpenCode",
                ruleID: "opencode-protected-db",
                displayName: "主数据库 (opencode.db)",
                fileName: "opencode.db",
                url: dbFile,
                category: .protectedData,
                recommendation: .notRecommended,
                safetyNote: "删除后丢失会话索引",
                sizeBytes: 4_096,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: false,
                isCustom: false
            ),
            CleanableItem(
                clientID: "claude-code",
                clientName: "Claude Code",
                ruleID: "forged-root",
                displayName: "客户端根目录",
                fileName: ".claude",
                url: clientRoot,
                category: .protectedData,
                recommendation: .notRecommended,
                safetyNote: "底线禁止",
                sizeBytes: 1_000,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: true,
                isCustom: false
            ),
            CleanableItem(
                clientID: "system",
                clientName: "System",
                ruleID: "forged-ssh",
                displayName: "SSH 密钥",
                fileName: "id_ed25519",
                url: sshKey,
                category: .protectedData,
                recommendation: .notRecommended,
                safetyNote: "底线禁止",
                sizeBytes: 256,
                fileCount: 1,
                modifiedAt: Date(),
                isDirectory: false,
                isCustom: false
            )
        ]

        let spy = GuardedPerformerSpy()
        let cleaner = TrashCleaner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
            performer: spy
        )

        let result = cleaner.trash(items: items, allowNotRecommendedOverride: true)
        XCTAssertEqual(result.trashedCount, 3)
        XCTAssertEqual(result.skippedProtectedItems.count, 2)
        XCTAssertTrue(spy.calledPaths.contains(skillsDir.standardizedFileURL.path))
        XCTAssertTrue(spy.calledPaths.contains(authFile.standardizedFileURL.path))
        XCTAssertTrue(spy.calledPaths.contains(dbFile.standardizedFileURL.path))
        XCTAssertFalse(spy.calledPaths.contains(clientRoot.standardizedFileURL.path))
        XCTAssertFalse(spy.calledPaths.contains(sshKey.standardizedFileURL.path))
    }
}
