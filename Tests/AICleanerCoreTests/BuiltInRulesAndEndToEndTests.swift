import AICleanerCore
import Foundation
import XCTest

private final class IsolatedTrashPerformer: TrashPerforming, @unchecked Sendable {
    let trashDir: URL

    init(trashDir: URL) throws {
        self.trashDir = trashDir
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    func trashItem(at url: URL) throws -> URL? {
        let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

final class BuiltInRulesAndEndToEndTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "BuiltInRulesAndEndToEndTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testBuiltInClientProfilesIntegrityAndSafetyCompliance() {
        let profiles = BuiltInClientRules.allProfiles
        let expectedCoreIDs: Set<String> = [
            "claude-code",
            "codex",
            "workbuddy",
            "doubao",
            "workdaddy",
            "cursor",
            "deepseek",
            "trae",
            "qoder",
            "lingma",
            "kiro",
            "zcode",
            "windsurf",
            "claude-desktop",
            "chatgpt-desktop",
            "opencode",
            "pi",
            "gemini-antigravity",
            "multica",
            "copilot",
            "cherry-studio",
            "anythingllm",
            "t3-code",
            "stepfun",
            "kimi",
            "yuanbao",
            "ollama",
            "lm-studio",
            "chatbox",
            "jan",
            "zed"
        ]
        XCTAssertEqual(profiles.count, expectedCoreIDs.count)
        XCTAssertEqual(Set(profiles.map(\.id)), expectedCoreIDs)

        let safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
        var seenRuleIDs: Set<String> = []

        for profile in profiles {
            XCTAssertFalse(profile.name.isEmpty)
            XCTAssertFalse(profile.description.isEmpty)
            XCTAssertFalse(profile.protectedSummary.isEmpty)
            XCTAssertFalse(profile.rules.isEmpty, "客户端 \(profile.name) 至少应包含一条扫描规则")

            for rule in profile.rules {
                XCTAssertTrue(seenRuleIDs.insert(rule.id).inserted, "规则 ID 不应重复：\(rule.id)")
                XCTAssertFalse(rule.explanation.isEmpty)

                // 「不建议清理」仅做只读体积透明展示，绝不进入可清理链路
                if rule.recommendation == .notRecommended {
                    XCTAssertEqual(rule.category, .protectedData)
                    continue
                }

                let resolvedURL = rule.resolveURL(homeDirectory: sandbox.homeURL)
                switch rule.mode {
                case .directory:
                    let decision = safetyGuard.validateTarget(resolvedURL)
                    XCTAssertTrue(
                        decision.isAllowed,
                        "整目录内置规则 [\(rule.id)] 路径不应与安全护栏冲突：\(resolvedURL.path) -> \(decision.blockReason ?? "")"
                    )
                case .children, .projectSessions, .recursiveFiles:
                    let containerDecision = safetyGuard.validateBuiltInContainer(resolvedURL)
                    XCTAssertTrue(
                        containerDecision.isAllowed,
                        "展开式内置规则 [\(rule.id)] 容器路径应允许进入逐项扫描：\(resolvedURL.path) -> \(containerDecision.blockReason ?? "")"
                    )
                }
            }
        }
    }

    func testCachesAllowsSparkleStagedResourcesWhileStillBlockingCredentials() throws {
        let sparkleSkillDir = try sandbox.createDirectory(
            relativeToHome: "Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Staged/App.app/Contents/Resources/skills"
        )
        let userSkillDir = try sandbox.createDirectory(relativeToHome: ".claude/skills")
        let cacheCredentialFile = try sandbox.createFile(
            relativeToHome: "Library/Caches/com.openai.codex/auth.json",
            byteCount: 64
        )
        let cacheKeyFile = try sandbox.createFile(
            relativeToHome: "Library/Caches/com.openai.codex/private.pem",
            byteCount: 64
        )

        let safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
        XCTAssertTrue(safetyGuard.validateEntry(url: sparkleSkillDir, isDirectory: true).isAllowed)
        XCTAssertFalse(safetyGuard.validateEntry(url: userSkillDir, isDirectory: true).isAllowed)
        XCTAssertFalse(safetyGuard.validateEntry(url: cacheCredentialFile, isDirectory: false).isAllowed)
        XCTAssertFalse(safetyGuard.validateEntry(url: cacheKeyFile, isDirectory: false).isAllowed)
    }

    func testMacOSBuiltInRulesPreserveScanSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let files = [
            (".claude/debug/example.log", 101),
            (".claude/settings.json", 102),
            (".codex/archived_sessions/archive.jsonl", 103),
            (".codex/archived_sessions/ignored.txt", 104),
            ("Library/Application Support/Windsurf/GPUCache/cache.bin", 105),
            ("Library/Application Support/Trae/CachedData/cache.bin", 106),
            ("Library/Application Support/Doubao/Crashpad/report.bin", 107),
            ("Library/Application Support/Codex/Cache/cache.bin", 108),
            ("Library/Application Support/Codex/Cache/auth.json", 109)
        ]
        for (path, size) in files {
            try sandbox.createFile(relativeToHome: path, byteCount: size, modifiedAt: now)
        }

        let report = ScanEngine(homeDirectory: sandbox.homeURL, builtInProfiles: BuiltInClientRules.allProfiles).scan(now: now)
        let snapshot = report.allDisplayedItems.map { item in
            let path = item.url.path.replacingOccurrences(of: sandbox.homeURL.path + "/", with: "")
            return "\(item.ruleID)|\(path)|\(item.category.rawValue)|\(item.recommendation.rawValue)|\(item.sizeBytes)|\(item.isBulkSelectable)"
        }.sorted()

        XCTAssertEqual(report.totalBuiltInProfilesCount, 31)
        XCTAssertEqual(report.detectedBuiltInClientsCount, 5)
        XCTAssertEqual(snapshot, [
            "claude-code-debug|.claude/debug/example.log|logs|recommended|101|true",
            "claude-code-protected-settings|.claude/settings.json|protectedData|notRecommended|102|false",
            "codex-archived-sessions|.codex/archived_sessions/archive.jsonl|sessions|reviewSuggested|103|true",
            "codex-archived-sessions|.codex/archived_sessions/ignored.txt|sessions|reviewSuggested|104|true",
            "doubao-app-crashpad|Library/Application Support/Doubao/Crashpad|logs|recommended|107|true",
            "trae-cached-data|Library/Application Support/Trae/CachedData|cache|recommended|106|true",
            "windsurf-gpu-cache|Library/Application Support/Windsurf/GPUCache|cache|recommended|105|true"
        ])
    }

    func testFullLifecycleScanSelectTrashAndRescanInSandbox() throws {
        // 准备模拟的多个 AI 客户端缓存与受保护文件
        let keepSettings = try sandbox.createFile(relativeToHome: ".claude/settings.json", byteCount: 256)
        let debugLogA = try sandbox.createFile(relativeToHome: ".claude/debug/a.log", byteCount: 1_200)
        let debugLogB = try sandbox.createFile(relativeToHome: ".claude/debug/b.log", byteCount: 3_400)
        try sandbox.createFile(relativeToHome: "Library/Application Support/Windsurf/GPUCache/shader.bin", byteCount: 5_000)

        let safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
        let engine = ScanEngine(homeDirectory: sandbox.homeURL, builtInProfiles: BuiltInClientRules.allProfiles, safetyGuard: safetyGuard)
        let trashPerformer = try IsolatedTrashPerformer(
            trashDir: sandbox.rootURL.appendingPathComponent("IsolatedTrash", isDirectory: true)
        )
        let cleaner = TrashCleaner(safetyGuard: safetyGuard, performer: trashPerformer)

        // 1. 首次扫描
        let firstReport = engine.scan()
        XCTAssertEqual(firstReport.detectedBuiltInClientsCount, 2)
        XCTAssertEqual(firstReport.totalItemCount, 3)
        XCTAssertEqual(firstReport.totalSizeBytes, 9_600)

        // 2. 选中其中 2 项移入废纸篓（Windsurf GPUCache + Claude b.log），保留 a.log
        let selected = firstReport.allItems.filter {
            $0.url.path == debugLogB.path || $0.clientID == "windsurf"
        }
        XCTAssertEqual(selected.count, 2)

        let cleanupResult = cleaner.trash(items: selected)
        XCTAssertEqual(cleanupResult.trashedCount, 2)
        XCTAssertEqual(cleanupResult.freedBytes, 8_400)
        XCTAssertFalse(cleanupResult.hasFailures)

        // 3. 清理后重新扫描：已清理项消失，未选项与受保护文件完整保留
        let secondReport = engine.scan()
        XCTAssertEqual(secondReport.detectedBuiltInClientsCount, 1)
        XCTAssertEqual(secondReport.totalItemCount, 1)
        XCTAssertEqual(secondReport.totalSizeBytes, 1_200)
        XCTAssertEqual(secondReport.allItems.first?.url.path, debugLogA.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepSettings.path))
    }
}
