import Foundation
import XCTest
@testable import AICleanerCore

final class ExcludedItemsTests: XCTestCase {
    func testPersistenceCrossInstanceLoadingAndIdempotentDeduplication() throws {
        let sandbox = try TestSandbox(prefix: "ExcludedStorePersistence")
        defer { sandbox.cleanup() }

        let logURL = try sandbox.createFile(relativeToHome: ".claude/debug/session.log", byteCount: 2_048)
        let storageURL = sandbox.rootURL.appendingPathComponent("config/excluded-items.json")

        let storeA = ExcludedItemStore(storageURL: storageURL)
        XCTAssertTrue(storeA.load().isEmpty)

        let t1 = Date(timeIntervalSince1970: 1_760_000_000)
        let t2 = Date(timeIntervalSince1970: 1_760_001_200)

        let item = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "claude-debug",
            displayName: "session.log",
            fileName: "session.log",
            url: logURL,
            category: .logs,
            safetyNote: "调试日志",
            sizeBytes: 2_048,
            fileCount: 1,
            modifiedAt: t1,
            isDirectory: false,
            isCustom: false
        )

        let afterFirst = try storeA.exclude(item: item, at: t1)
        XCTAssertEqual(afterFirst.count, 1)
        XCTAssertEqual(afterFirst[0].normalizedPath, ExcludedItemMatcher.normalizePath(logURL))
        XCTAssertEqual(afterFirst[0].displayName, "session.log")
        XCTAssertEqual(afterFirst[0].clientID, "claude-code")
        XCTAssertEqual(afterFirst[0].clientName, "Claude Code")
        XCTAssertEqual(afterFirst[0].category, .logs)
        XCTAssertEqual(afterFirst[0].excludedAt, t1)

        // 重复排除同一路径、带尾部斜杠或未规范化 /./ 路径应严格保持幂等
        let afterDuplicateItem = try storeA.exclude(item: item, at: t2)
        XCTAssertEqual(afterDuplicateItem.count, 1)

        let trailingSlashRecord = ExcludedItemRecord(
            path: logURL.path + "/",
            displayName: "duplicate",
            clientID: "claude-code",
            clientName: "Claude Code",
            category: .logs,
            isDirectory: false,
            excludedAt: t2
        )
        let afterTrailingSlash = try storeA.add(trailingSlashRecord)
        XCTAssertEqual(afterTrailingSlash.count, 1)

        let unnormalizedPath = logURL.deletingLastPathComponent().path + "/./" + logURL.lastPathComponent
        let unnormalizedRecord = ExcludedItemRecord(
            path: unnormalizedPath,
            displayName: "duplicate-dot",
            clientID: "claude-code",
            clientName: "Claude Code",
            category: .logs,
            isDirectory: false,
            excludedAt: t2
        )
        let afterUnnormalized = try storeA.add(unnormalizedRecord)
        XCTAssertEqual(afterUnnormalized.count, 1)

        // 会话条目排除时优先保留可读会话标题
        let sessionURL = try sandbox.createFile(
            relativeToHome: ".claude/projects/-Users-demo-app/abc12345.jsonl",
            byteCount: 1_024
        )
        let sessionItem = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "claude-project-sessions",
            displayName: "app · 原始首条提问",
            fileName: "abc12345.jsonl",
            url: sessionURL,
            category: .sessions,
            recommendation: .reviewSuggested,
            safetyNote: "聊天会话",
            sizeBytes: 1_024,
            fileCount: 1,
            modifiedAt: t1,
            isDirectory: false,
            isCustom: false,
            sessionTitle: "发布前回归排查会话",
            sessionProjectName: "app"
        )
        let afterSecond = try storeA.exclude(item: sessionItem, at: t2)
        XCTAssertEqual(afterSecond.count, 2)

        // 跨实例加载应完整恢复元数据并按排除时间倒序排列
        let storeB = ExcludedItemStore(storageURL: storageURL)
        let reloaded = storeB.load()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded[0].displayName, "发布前回归排查会话")
        XCTAssertEqual(reloaded[0].sessionProjectName, "app")
        XCTAssertEqual(reloaded[0].category, .sessions)
        XCTAssertEqual(reloaded[0].excludedAt, t2)
        XCTAssertEqual(reloaded[1].displayName, "session.log")
        XCTAssertEqual(reloaded[1].excludedAt, t1)

        // 按 ID 与按路径移除均持久化
        let afterRemoveOne = try storeB.remove(id: reloaded[0].id)
        XCTAssertEqual(afterRemoveOne.count, 1)
        XCTAssertEqual(ExcludedItemStore(storageURL: storageURL).load().count, 1)

        let afterClear = try storeB.removeAll()
        XCTAssertTrue(afterClear.isEmpty)
        XCTAssertTrue(ExcludedItemStore(storageURL: storageURL).load().isEmpty)
    }

    func testMatcherEnforcesDirectoryAndSiblingBoundaries() throws {
        let sandbox = try TestSandbox(prefix: "ExcludedMatcherBoundary")
        defer { sandbox.cleanup() }

        let dirURL = try sandbox.createDirectory(relativeToHome: "work/cache-dir")
        let nestedFileURL = try sandbox.createFile(relativeToHome: "work/cache-dir/sub/a.log", byteCount: 128)
        let siblingSimilarDirURL = try sandbox.createDirectory(relativeToHome: "work/cache-dir2")
        let siblingSimilarFileURL = try sandbox.createFile(relativeToHome: "work/cache-dir.jsonl", byteCount: 128)

        let sessionFileURL = try sandbox.createFile(relativeToHome: "work/sessions/sess-1.jsonl", byteCount: 128)
        let sessionSubdirURL = try sandbox.createDirectory(relativeToHome: "work/sessions/sess-1")
        let sessionSubdirChildURL = try sandbox.createFile(
            relativeToHome: "work/sessions/sess-1/subagent.jsonl",
            byteCount: 128
        )

        let dirMatcher = ExcludedItemMatcher(paths: [dirURL.path + "/"])
        XCTAssertTrue(dirMatcher.isExcluded(dirURL))
        XCTAssertTrue(dirMatcher.isExcluded(nestedFileURL))
        XCTAssertFalse(dirMatcher.isExcluded(siblingSimilarDirURL))
        XCTAssertFalse(dirMatcher.isExcluded(siblingSimilarFileURL))

        // 排除会话文件不应误匹配同名伴随目录，反之亦然
        let fileOnlyMatcher = ExcludedItemMatcher(paths: [sessionFileURL.path])
        XCTAssertTrue(fileOnlyMatcher.isExcluded(sessionFileURL))
        XCTAssertFalse(fileOnlyMatcher.isExcluded(sessionSubdirURL))
        XCTAssertFalse(fileOnlyMatcher.isExcluded(sessionSubdirChildURL))

        let subdirOnlyMatcher = ExcludedItemMatcher(paths: [sessionSubdirURL.path])
        XCTAssertTrue(subdirOnlyMatcher.isExcluded(sessionSubdirURL))
        XCTAssertTrue(subdirOnlyMatcher.isExcluded(sessionSubdirChildURL))
        XCTAssertFalse(subdirOnlyMatcher.isExcluded(sessionFileURL))
    }

    func testScanEngineFiltersExcludedItemsDirectorySubtreesAndRecalculatesTotals() throws {
        let sandbox = try TestSandbox(prefix: "ExcludedScanEngine")
        defer { sandbox.cleanup() }

        // 1. 内置客户端 Claude Code（单文件 + 目录条目 + 会话条目）
        let debugA = try sandbox.createFile(relativeToHome: ".claude/debug/a.log", byteCount: 4_000)
        let debugB = try sandbox.createFile(relativeToHome: ".claude/debug/b.log", byteCount: 6_000)
        let sessionKeep = try sandbox.createFile(
            relativeToHome: ".claude/projects/-Users-demo-proj/keep.jsonl",
            byteCount: 2_000
        )
        let sessionExclude = try sandbox.createFile(
            relativeToHome: ".claude/projects/-Users-demo-proj/skip.jsonl",
            byteCount: 3_000
        )
        // 硬保护凭据文件：必须继续由 SafetyGuard 拦截
        let credURL = try sandbox.createFile(relativeToHome: ".claude/debug/auth.json", byteCount: 512)

        // 2. 内置客户端 Codex（recursiveFiles 嵌套日期目录）
        let codexOldDayFile = try sandbox.createFile(
            relativeToHome: ".codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl",
            byteCount: 5_000
        )
        let codexKeepDayFile = try sandbox.createFile(
            relativeToHome: ".codex/sessions/2026/11/02/rollout-2026-11-02T10-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl",
            byteCount: 7_000
        )
        let codexExcludedDir = codexOldDayFile.deletingLastPathComponent()

        // 3. 自定义目录（包含被排除子目录及其嵌套文件，以及应保留的兄弟文件）
        let customRoot = try sandbox.createDirectory(relativeToHome: "MyScratch")
        let customSubDir = try sandbox.createDirectory(relativeToHome: "MyScratch/keep-me-forever")
        _ = try sandbox.createFile(relativeToHome: "MyScratch/keep-me-forever/nested.tmp", byteCount: 8_000)
        let customSiblingFile = try sandbox.createFile(relativeToHome: "MyScratch/cleanable.tmp", byteCount: 1_500)
        let customEntry = CustomScanDirectory(
            displayName: "临时工作区",
            path: customRoot.path,
            category: .custom,
            mode: .children
        )
        // 再加一条直接指向被排除子目录的自定义目录，验证子路径也一并被过滤
        let customNestedEntry = CustomScanDirectory(
            displayName: "子目录扫描",
            path: customSubDir.path,
            category: .custom,
            mode: .children
        )

        let engine = ScanEngine(homeDirectory: sandbox.homeURL, builtInProfiles: BuiltInClientRules.allProfiles)
        let baseline = engine.scan(customDirectories: [customEntry, customNestedEntry])

        let baselinePaths = Set(baseline.allItems.map(\.url.path))
        XCTAssertTrue(baselinePaths.contains(debugA.path))
        XCTAssertTrue(baselinePaths.contains(debugB.path))
        XCTAssertTrue(baselinePaths.contains(sessionKeep.path))
        XCTAssertTrue(baselinePaths.contains(sessionExclude.path))
        XCTAssertTrue(baselinePaths.contains(codexOldDayFile.path))
        XCTAssertTrue(baselinePaths.contains(codexKeepDayFile.path))
        XCTAssertTrue(baselinePaths.contains(customSubDir.path))
        XCTAssertTrue(baselinePaths.contains(customSiblingFile.path))
        XCTAssertFalse(baselinePaths.contains(credURL.path))

        // 排除：单个日志、单个会话、Codex 整个日期子目录、自定义目录下的子目录
        let exclusions: [ExcludedItemRecord] = [
            ExcludedItemRecord(
                path: debugA.path,
                displayName: "a.log",
                clientID: "claude-code",
                clientName: "Claude Code",
                category: .logs,
                isDirectory: false
            ),
            ExcludedItemRecord(
                path: sessionExclude.path,
                displayName: "保留会话",
                clientID: "claude-code",
                clientName: "Claude Code",
                category: .sessions,
                isDirectory: false
            ),
            ExcludedItemRecord(
                path: codexExcludedDir.path,
                displayName: "2026-11-01",
                clientID: "codex",
                clientName: "Codex",
                category: .sessions,
                isDirectory: true
            ),
            ExcludedItemRecord(
                path: customSubDir.path,
                displayName: "keep-me-forever",
                clientID: customEntry.toClientProfile().id,
                clientName: customEntry.displayName,
                category: .custom,
                isDirectory: true
            )
        ]

        let rescanned = engine.scan(
            customDirectories: [customEntry, customNestedEntry],
            excludedItems: exclusions
        )
        let rescannedPaths = Set(rescanned.allItems.map(\.url.path))

        XCTAssertFalse(rescannedPaths.contains(debugA.path))
        XCTAssertTrue(rescannedPaths.contains(debugB.path))
        XCTAssertFalse(rescannedPaths.contains(sessionExclude.path))
        XCTAssertTrue(rescannedPaths.contains(sessionKeep.path))
        XCTAssertFalse(rescannedPaths.contains(codexOldDayFile.path))
        XCTAssertTrue(rescannedPaths.contains(codexKeepDayFile.path))
        XCTAssertFalse(rescannedPaths.contains(customSubDir.path))
        XCTAssertFalse(rescannedPaths.contains(customSubDir.appendingPathComponent("nested.tmp").path))
        XCTAssertTrue(rescannedPaths.contains(customSiblingFile.path))
        XCTAssertFalse(rescannedPaths.contains(credURL.path))

        // 验证汇总统计重算精确一致（与内存中过滤 baseline 完全一致）
        let inMemoryFiltered = baseline.filtering(excludedItems: exclusions)
        XCTAssertEqual(rescanned.totalSizeBytes, inMemoryFiltered.totalSizeBytes)
        XCTAssertEqual(rescanned.recommendedSizeBytes, inMemoryFiltered.recommendedSizeBytes)
        XCTAssertEqual(rescanned.reviewSuggestedSizeBytes, inMemoryFiltered.reviewSuggestedSizeBytes)
        XCTAssertEqual(rescanned.totalItemCount, inMemoryFiltered.totalItemCount)
        XCTAssertEqual(rescanned.detectedBuiltInClientsCount, inMemoryFiltered.detectedBuiltInClientsCount)

        // 核对排除掉整个客户端所有条目后，该内置客户端不再计入 detectedBuiltInClientsCount
        let excludeAllCodex = exclusions + [
            ExcludedItemRecord(
                path: codexKeepDayFile.path,
                displayName: "keep",
                clientID: "codex",
                clientName: "Codex",
                category: .sessions,
                isDirectory: false
            )
        ]
        let withoutCodex = engine.scan(
            customDirectories: [customEntry, customNestedEntry],
            excludedItems: excludeAllCodex
        )
        XCTAssertNil(withoutCodex.clientSummaries.first(where: { $0.id == "codex" }))
        XCTAssertEqual(withoutCodex.detectedBuiltInClientsCount, 1)
    }

    func testHardProtectionRemainsIntactWhenExclusionsAreConfigured() throws {
        let sandbox = try TestSandbox(prefix: "ExcludedHardProtection")
        defer { sandbox.cleanup() }

        let authURL = try sandbox.createFile(relativeToHome: ".codex/auth.json", byteCount: 256)
        let dbURL = try sandbox.createFile(relativeToHome: ".codex/state_5.sqlite", byteCount: 1_024)
        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        let cleaner = TrashCleaner(safetyGuard: guardInstance)

        let fakeProtectedItem = CleanableItem(
            clientID: "codex",
            clientName: "Codex",
            ruleID: "codex-auth",
            displayName: "登录凭据",
            fileName: "auth.json",
            url: authURL,
            category: .protectedData,
            recommendation: .notRecommended,
            safetyNote: "硬保护",
            sizeBytes: 256,
            fileCount: 1,
            modifiedAt: Date(),
            isDirectory: false,
            isCustom: false,
            hardProtectionReason: "凭据文件受硬保护"
        )

        let result = cleaner.trash(items: [fakeProtectedItem], allowNotRecommendedOverride: true)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.skippedProtectedItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }
}
