import AICleanerCore
import Darwin
import Foundation
import XCTest

@_silgen_name("flock")
private func testBSDFlock(_ fd: Int32, _ operation: Int32) -> Int32

private final class TempMockTrashPerformer: TrashPerforming, @unchecked Sendable {
    let trashDir: URL
    private(set) var trashedURLs: [URL] = []

    init(trashDir: URL) throws {
        self.trashDir = trashDir
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    func trashItem(at url: URL) throws -> URL? {
        trashedURLs.append(url)
        let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

final class TempDirectoryScannerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var privateTmpDir: URL!
    private var tmpSymlinkDir: URL!
    private var userTmpDir: URL!

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var oldDate: Date { fixedNow.addingTimeInterval(-48 * 3600) }
    private var recentDate: Date { fixedNow.addingTimeInterval(-2 * 3600) }

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "TempDirectoryScannerTests")
        privateTmpDir = sandbox.rootURL.appendingPathComponent("private/tmp", isDirectory: true)
        tmpSymlinkDir = sandbox.rootURL.appendingPathComponent("tmp", isDirectory: true)
        userTmpDir = sandbox.rootURL.appendingPathComponent("var/folders/xx/T", isDirectory: true)

        try FileManager.default.createDirectory(at: privateTmpDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userTmpDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tmpSymlinkDir, withDestinationURL: privateTmpDir)
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
        privateTmpDir = nil
        tmpSymlinkDir = nil
        userTmpDir = nil
    }

    func testDefaultSandboxScanEngineDoesNotScanHostTempDirectories() {
        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        XCTAssertNil(engine.systemTempRoot)
        XCTAssertNil(engine.userTempRoot)
    }

    func testLayer1ClassifiesAITempEntriesAcrossSystemAndUserTempWith24HourCooldown() throws {
        // 既有 home 下的 Claude Code 调试日志（用于验证与 /tmp 条目合并到同一分组）
        try sandbox.createFile(relativeToHome: ".claude/debug/home.log", byteCount: 500, modifiedAt: oldDate)

        // 第一层：/tmp 下超过 24 小时的 AI 工具临时项（应归入对应客户端且为「建议清理」）
        try createDirectoryWithFile(in: privateTmpDir, dirName: "claude-501", fileName: "task.log", bytes: 2_000, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "claude-desktop-update", fileName: "pkg.zip", bytes: 3_000, modifiedAt: oldDate)
        try createFile(in: privateTmpDir, name: "codex-clipboard-01.png", bytes: 1_500, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "codex-artifact-session-9", fileName: "out.txt", bytes: 1_200, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: ".com.openai.codex.helper", fileName: "cache.bin", bytes: 1_100, modifiedAt: oldDate)
        try createFile(in: privateTmpDir, name: "com.openai.codex.trace", bytes: 900, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "com.openai.sky.CUAService", fileName: "frame.bin", bytes: 800, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "opencode", fileName: "tmp.log", bytes: 700, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "cursor-worker-1", fileName: "buf.bin", bytes: 650, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "windsurf-cache-1", fileName: "buf.bin", bytes: 600, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "com.lbjlaq.antigravity-tools", fileName: "tool.log", bytes: 550, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "workbuddy-export-1", fileName: "doc.tmp", bytes: 520, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "multica-task-old", fileName: "run.log", bytes: 510, modifiedAt: oldDate)
        try createFile(in: privateTmpDir, name: "pi-bash-1234.log", bytes: 480, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "t3code-session", fileName: "buf.tmp", bytes: 460, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "magpie-agy-bridge-old", fileName: "bridge.log", bytes: 440, modifiedAt: oldDate)

        // 第一层：userTempRoot（DARWIN_USER_TEMP_DIR）中的 AI 临时项
        try createFile(in: userTmpDir, name: "opencode-user-tmp.log", bytes: 750, modifiedAt: oldDate)
        // 第一层：24 小时内修改的 AI 临时项（单文件 + 父目录旧但子文件 2 小时前修改的目录）
        try createFile(in: privateTmpDir, name: "codex-recent.log", bytes: 1_000, modifiedAt: recentDate)
        let recentChildDir = try createDirectoryWithFile(
            in: userTmpDir,
            dirName: "claude-recent-dir",
            fileName: "active-output.log",
            bytes: 1_800,
            modifiedAt: recentDate
        )
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: recentChildDir.path)

        let engine = ScanEngine(
            homeDirectory: sandbox.homeURL,
            systemTempRoot: tmpSymlinkDir,
            userTempRoot: userTmpDir,
            currentUID: getuid(),
            activeTempDirectoryPath: nil,
            now: fixedNow
        )

        let report = engine.scan()
        let byClient = Dictionary(uniqueKeysWithValues: report.clientSummaries.map { ($0.profile.id, $0) })

        // 验证 claude-desktop 与 claude-code 未混淆，且 claude-code 合并了 home + /tmp + userTmp
        let claudeDesktop = try XCTUnwrap(byClient["claude-desktop"])
        XCTAssertEqual(claudeDesktop.items.map(\.fileName), ["claude-desktop-update"])
        XCTAssertEqual(claudeDesktop.items.first?.recommendation, .recommended)
        XCTAssertEqual(claudeDesktop.items.first?.sourceBadge, "临时文件（/tmp）")

        let claudeCode = try XCTUnwrap(byClient["claude-code"])
        XCTAssertEqual(Set(claudeCode.items.map(\.fileName)), ["home.log", "claude-501", "claude-recent-dir"])
        let claudeOld = try XCTUnwrap(claudeCode.items.first(where: { $0.fileName == "claude-501" }))
        XCTAssertEqual(claudeOld.recommendation, .recommended)
        XCTAssertTrue(claudeOld.isBulkSelectable)
        XCTAssertFalse(claudeOld.isRecentlyModified)
        XCTAssertEqual(claudeOld.sourceBadge, "临时文件（/tmp）")
        XCTAssertTrue(claudeOld.url.path.contains("/private/tmp/claude-501"))

        let claudeRecent = try XCTUnwrap(claudeCode.items.first(where: { $0.fileName == "claude-recent-dir" }))
        XCTAssertEqual(claudeRecent.recommendation, .reviewSuggested)
        XCTAssertFalse(claudeRecent.isBulkSelectable)
        XCTAssertTrue(claudeRecent.requiresIndividualSelection)
        XCTAssertTrue(claudeRecent.isRecentlyModified)
        XCTAssertEqual(claudeRecent.sourceBadge, "临时文件（系统临时目录）")

        // 验证 Codex 规则全命中（含隐藏 .com.openai.codex.*、CUAService、近期修改降级）
        let codex = try XCTUnwrap(byClient["codex"])
        XCTAssertEqual(
            Set(codex.items.map(\.fileName)),
            [
                "codex-clipboard-01.png",
                "codex-artifact-session-9",
                ".com.openai.codex.helper",
                "com.openai.codex.trace",
                "com.openai.sky.CUAService",
                "codex-recent.log"
            ]
        )
        let codexRecent = try XCTUnwrap(codex.items.first(where: { $0.fileName == "codex-recent.log" }))
        XCTAssertEqual(codexRecent.recommendation, .reviewSuggested)
        XCTAssertTrue(codexRecent.requiresIndividualSelection)
        XCTAssertTrue(codexRecent.isRecentlyModified)
        for cooledName in ["codex-clipboard-01.png", ".com.openai.codex.helper", "com.openai.sky.CUAService"] {
            let item = try XCTUnwrap(codex.items.first(where: { $0.fileName == cooledName }))
            XCTAssertEqual(item.recommendation, .recommended, "\(cooledName) 超过 24 小时应为建议清理")
            XCTAssertTrue(item.isBulkSelectable)
        }

        // 验证其余内置客户端与「其他 AI 临时文件（/tmp）」归属
        XCTAssertEqual(Set(try XCTUnwrap(byClient["opencode"]).items.map(\.fileName)), ["opencode", "opencode-user-tmp.log"])
        XCTAssertEqual(try XCTUnwrap(byClient["cursor"]).items.map(\.fileName), ["cursor-worker-1"])
        XCTAssertEqual(try XCTUnwrap(byClient["windsurf"]).items.map(\.fileName), ["windsurf-cache-1"])
        XCTAssertEqual(try XCTUnwrap(byClient["gemini-antigravity"]).items.map(\.fileName), ["com.lbjlaq.antigravity-tools"])
        XCTAssertEqual(try XCTUnwrap(byClient["workbuddy"]).items.map(\.fileName), ["workbuddy-export-1"])
        XCTAssertEqual(try XCTUnwrap(byClient["multica"]).items.map(\.fileName), ["multica-task-old"])
        XCTAssertEqual(try XCTUnwrap(byClient["pi"]).items.map(\.fileName), ["pi-bash-1234.log"])
        XCTAssertEqual(try XCTUnwrap(byClient["t3-code"]).items.map(\.fileName), ["t3code-session"])

        let otherAI = try XCTUnwrap(byClient[TempDirectoryScanner.otherAITempClientID])
        XCTAssertEqual(otherAI.profile.kind, .otherAITemp)
        XCTAssertEqual(otherAI.profile.name, "其他 AI 临时文件（/tmp）")
        XCTAssertEqual(otherAI.items.map(\.fileName), ["magpie-agy-bridge-old"])
        XCTAssertEqual(otherAI.items.first?.recommendation, .recommended)

        // 第一层全部已归属，第二层未归属区应为空（严格去重）
        XCTAssertNil(byClient[TempDirectoryScanner.unattributedTempClientID])
    }

    func testLayer2FiltersUnattributedTmpItemsDeduplicatesAndSkipsOtherUsersHiddenEmptyAndSpecialNodes() throws {
        // 第一层 AI 项（必须不重复进入第二层）
        try createFile(in: privateTmpDir, name: "claude-layer1.log", bytes: 1_000, modifiedAt: oldDate)

        // 第二层合法项：当前用户的普通非空文件与目录（含旧项与 24h 内近期项）
        try createFile(in: privateTmpDir, name: "scratch-old.tar", bytes: 4_000, modifiedAt: oldDate)
        try createDirectoryWithFile(in: privateTmpDir, dirName: "scratch-recent-dir", fileName: "note.txt", bytes: 2_500, modifiedAt: recentDate)

        // userTempRoot 中的未归属普通项（绝不能混入第二层未归属区！）
        try createFile(in: userTmpDir, name: "browser-random-cache.dat", bytes: 8_000, modifiedAt: oldDate)

        // 应被第二层跳过的隐藏项、0 字节文件、空目录
        try createFile(in: privateTmpDir, name: ".sboxcache_999", bytes: 3_000, modifiedAt: oldDate)
        try createFile(in: privateTmpDir, name: ".DS_Store", bytes: 512, modifiedAt: oldDate)
        try createFile(in: privateTmpDir, name: "zero-byte.tmp", bytes: 0, modifiedAt: oldDate)
        let emptyDir = privateTmpDir.appendingPathComponent("empty-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: emptyDir.path)

        // 应被跳过的其他用户/root 条目（通过注入 ownerUIDResolver 模拟）
        let rootOwnedFile = try createFile(in: privateTmpDir, name: "root-service.log", bytes: 2_000, modifiedAt: oldDate)
        let otherUserAI = try createFile(in: privateTmpDir, name: "claude-999-other-user", bytes: 2_000, modifiedAt: oldDate)

        // 应被跳过的特殊节点：真实 Unix Domain Socket、真实 FIFO、*.sock 文件、符号链接
        let realSocketURL = try createUnixDomainSocket(in: privateTmpDir, name: "live-ipc")
        let realFifoURL = try createFIFO(in: privateTmpDir, name: "named-pipe")
        try createFile(in: privateTmpDir, name: "daemon.sock", bytes: 128, modifiedAt: oldDate)
        let targetForLink = try sandbox.createFile(relativeToHome: "outside.txt", byteCount: 512, modifiedAt: oldDate)
        let symlinkURL = privateTmpDir.appendingPathComponent("sneaky-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetForLink)

        // 包含真实 Socket 的目录也必须整体跳过
        let dirWithSocket = privateTmpDir.appendingPathComponent("dir-with-socket", isDirectory: true)
        try FileManager.default.createDirectory(at: dirWithSocket, withIntermediateDirectories: true)
        try createFile(in: dirWithSocket, name: "payload.bin", bytes: 2_000, modifiedAt: oldDate)
        _ = try createUnixDomainSocket(in: dirWithSocket, name: "agent.sock")
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: dirWithSocket.path)

        let myUID: uid_t = 501
        let rootPath = rootOwnedFile.resolvingSymlinksInPath().standardizedFileURL.path
        let otherUserPath = otherUserAI.resolvingSymlinksInPath().standardizedFileURL.path

        let engine = ScanEngine(
            homeDirectory: sandbox.homeURL,
            systemTempRoot: tmpSymlinkDir,
            userTempRoot: userTmpDir,
            currentUID: myUID,
            activeTempDirectoryPath: nil,
            now: fixedNow,
            ownerUIDResolver: { url in
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if path == rootPath { return 0 }
                if path == otherUserPath { return 502 }
                return myUID
            }
        )

        let report = engine.scan()
        let byClient = Dictionary(uniqueKeysWithValues: report.clientSummaries.map { ($0.profile.id, $0) })

        // 验证第一层仅包含当前用户的 claude-layer1.log，跳过其他用户的 claude-999-other-user
        let claude = try XCTUnwrap(byClient["claude-code"])
        XCTAssertEqual(claude.items.map(\.fileName), ["claude-layer1.log"])

        // 验证第二层仅包含 scratch-old.tar 与 scratch-recent-dir
        let unattributed = try XCTUnwrap(byClient[TempDirectoryScanner.unattributedTempClientID])
        XCTAssertEqual(unattributed.profile.kind, .unattributedTemp)
        XCTAssertEqual(unattributed.profile.name, "/tmp 未归属临时项")
        XCTAssertEqual(Set(unattributed.items.map(\.fileName)), ["scratch-old.tar", "scratch-recent-dir"])

        for item in unattributed.items {
            XCTAssertEqual(item.recommendation, .reviewSuggested)
            XCTAssertTrue(item.requiresIndividualSelection, "未归属项必须强制逐条手选")
            XCTAssertFalse(item.isBulkSelectable, "未归属项不得参与任何批量勾选")
            XCTAssertEqual(item.sourceBadge, "临时文件（/tmp）")
        }

        let recentItem = try XCTUnwrap(unattributed.items.first(where: { $0.fileName == "scratch-recent-dir" }))
        XCTAssertTrue(recentItem.isRecentlyModified)
        let oldItem = try XCTUnwrap(unattributed.items.first(where: { $0.fileName == "scratch-old.tar" }))
        XCTAssertFalse(oldItem.isRecentlyModified)

        // 验证 SafetyGuard 也直接拦截真实 Socket 与 FIFO
        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        XCTAssertFalse(guardInstance.validateTarget(realSocketURL).isAllowed)
        XCTAssertFalse(guardInstance.validateTarget(realFifoURL).isAllowed)
        XCTAssertFalse(guardInstance.validateTargetRecursively(dirWithSocket).isAllowed)
        XCTAssertFalse(guardInstance.validateTarget(URL(fileURLWithPath: "/tmp")).isAllowed)
        XCTAssertFalse(guardInstance.validateTarget(URL(fileURLWithPath: "/private/tmp")).isAllowed)
    }

    func testActiveProcessLockAndTMPDIRProtectionSkipsInUseDirectories() throws {
        // 1. 与当前 TMPDIR 匹配的目录（即使传的是 /tmp 符号链接形式，也应与 /private/tmp 匹配跳过）
        let activeTmpDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "multica-task-active",
            fileName: "work.log",
            bytes: 3_000,
            modifiedAt: oldDate
        )
        let tmpdirAliasPath = tmpSymlinkDir.appendingPathComponent("multica-task-active/nested-sub").path

        // 2. 包含 .task_lock 的目录（即便超过 24 小时未修改也跳过）
        let taskLockDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "codex-task-locked",
            fileName: "data.bin",
            bytes: 3_000,
            modifiedAt: oldDate
        )
        try createFile(in: taskLockDir, name: ".task_lock", bytes: 16, modifiedAt: oldDate)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: taskLockDir.path)

        // 3. 包含近期锁文件（<24h）的目录
        let recentLockDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "cursor-recent-lock",
            fileName: "state.tmp",
            bytes: 2_000,
            modifiedAt: oldDate
        )
        try createFile(in: recentLockDir, name: "worker.lock", bytes: 8, modifiedAt: recentDate)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: recentLockDir.path)

        // 4. 包含持有活跃 BSD flock 排他锁的旧锁文件（>24h）的目录
        let flockDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "opencode-flocked",
            fileName: "cache.tmp",
            bytes: 2_000,
            modifiedAt: oldDate
        )
        let lockedFile = try createFile(in: flockDir, name: "runtime.lock", bytes: 8, modifiedAt: oldDate)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: flockDir.path)

        let lockFD = open(lockedFile.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        defer {
            if lockFD >= 0 {
                _ = testBSDFlock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        XCTAssertEqual(testBSDFlock(lockFD, LOCK_EX | LOCK_NB), 0)

        // 5. 当前应用自身命名目录
        try createDirectoryWithFile(in: privateTmpDir, dirName: "ai-cleaner-runtime", fileName: "cache.tmp", bytes: 1_000, modifiedAt: oldDate)

        // 6. 对照组：真正空闲且超过 24 小时的条目（应正常扫出）
        try createDirectoryWithFile(in: privateTmpDir, dirName: "codex-idle-old", fileName: "old.log", bytes: 2_200, modifiedAt: oldDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeTmpDir.path))

        let engine = ScanEngine(
            homeDirectory: sandbox.homeURL,
            systemTempRoot: tmpSymlinkDir,
            userTempRoot: nil,
            currentUID: getuid(),
            activeTempDirectoryPath: tmpdirAliasPath,
            now: fixedNow
        )

        let report = engine.scan()
        XCTAssertEqual(report.allItems.map(\.fileName), ["codex-idle-old"])
        XCTAssertNil(report.clientSummaries.first(where: { $0.profile.id == TempDirectoryScanner.unattributedTempClientID }))
        XCTAssertGreaterThanOrEqual(report.skippedProtectedCount, 5)
    }

    func testTmpSymlinkCanonicalizationAndTrashCleanerRespectHardProtection() throws {
        let safeDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "codex-trash-target",
            fileName: "output.log",
            bytes: 2_048,
            modifiedAt: oldDate
        )
        let contaminatedDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "codex-has-secret",
            fileName: "auth.json",
            bytes: 128,
            modifiedAt: oldDate
        )

        // 通过符号链接父目录路径构造条目（模拟 /tmp/... -> /private/tmp/...）
        let symlinkedSafeURL = tmpSymlinkDir.appendingPathComponent("codex-trash-target")
        let symlinkedSecretURL = tmpSymlinkDir.appendingPathComponent("codex-has-secret")

        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        let performer = try TempMockTrashPerformer(
            trashDir: sandbox.rootURL.appendingPathComponent("MockTrash", isDirectory: true)
        )
        let cleaner = TrashCleaner(safetyGuard: guardInstance, performer: performer)

        let safeItem = CleanableItem(
            clientID: "codex",
            clientName: "Codex",
            ruleID: "system-tmp-ai-codex",
            displayName: "codex-trash-target",
            fileName: "codex-trash-target",
            url: symlinkedSafeURL,
            category: .temporary,
            recommendation: .recommended,
            safetyNote: "测试临时目录",
            sizeBytes: 2_048,
            fileCount: 1,
            modifiedAt: oldDate,
            isDirectory: true,
            isCustom: false,
            sourceBadge: "临时文件（/tmp）"
        )
        let secretItem = CleanableItem(
            clientID: "codex",
            clientName: "Codex",
            ruleID: "system-tmp-ai-codex",
            displayName: "codex-has-secret",
            fileName: "codex-has-secret",
            url: symlinkedSecretURL,
            category: .temporary,
            recommendation: .recommended,
            safetyNote: "测试含凭据临时目录",
            sizeBytes: 128,
            fileCount: 1,
            modifiedAt: oldDate,
            isDirectory: true,
            isCustom: false,
            sourceBadge: "临时文件（/tmp）"
        )

        // 同时验证 SafetyGuard.normalizeTempPath 对 /tmp/... 字面路径的规范化
        XCTAssertEqual(
            SafetyGuard.normalizeTempPath(URL(fileURLWithPath: "/tmp/codex-demo")).path,
            "/private/tmp/codex-demo"
        )

        let result = cleaner.trash(items: [safeItem, secretItem], allowNotRecommendedOverride: true)
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.freedBytes, 2_048)
        XCTAssertEqual(result.skippedProtectedItems.count, 1)
        XCTAssertEqual(performer.trashedURLs.count, 1)
        XCTAssertEqual(
            performer.trashedURLs.first?.path,
            safeDir.resolvingSymlinksInPath().standardizedFileURL.path,
            "移入废纸篓前应将符号链接父目录规范化为真实路径"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: safeDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contaminatedDir.path), "含硬保护凭据的目录绝不能被移入废纸篓")
    }

    func testTrashCleanerBlocksDirectAndLateSpecialNodesAndDeduplicatesIdenticalTempRoots() throws {
        // 1. 直接与后代 Socket / FIFO 即使在强制覆盖模式下也绝不可移入废纸篓
        let directSocket = try createUnixDomainSocket(in: privateTmpDir, name: "direct-ipc")
        let directFifo = try createFIFO(in: privateTmpDir, name: "direct-pipe")
        let lateSocketDir = try createDirectoryWithFile(
            in: privateTmpDir,
            dirName: "codex-late-socket",
            fileName: "cache.bin",
            bytes: 512,
            modifiedAt: oldDate
        )

        // 先扫描（此时目录内还没有 socket，正常扫出）
        let engine = ScanEngine(
            homeDirectory: sandbox.homeURL,
            systemTempRoot: tmpSymlinkDir,
            userTempRoot: privateTmpDir, // 与 systemTempRoot 指向同一规范目录，验证不重复
            currentUID: getuid(),
            activeTempDirectoryPath: nil,
            now: fixedNow
        )
        let report = engine.scan()
        let codexItems = report.clientSummaries.first(where: { $0.profile.id == "codex" })?.items ?? []
        XCTAssertEqual(codexItems.count, 1, "systemTempRoot 与 userTempRoot 指向同一目录时不得重复产出条目")
        let scannedDirItem = try XCTUnwrap(codexItems.first)

        // 扫描后目录内新出现真实 Unix Domain Socket
        _ = try createUnixDomainSocket(in: lateSocketDir, name: "runtime-ipc")

        let performer = try TempMockTrashPerformer(
            trashDir: sandbox.rootURL.appendingPathComponent("MockTrashSpecial", isDirectory: true)
        )
        let cleaner = TrashCleaner(safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL), performer: performer)

        let directSocketItem = CleanableItem(
            clientID: "codex",
            clientName: "Codex",
            ruleID: "test",
            displayName: "direct-ipc",
            fileName: "direct-ipc",
            url: directSocket,
            category: .temporary,
            recommendation: .recommended,
            safetyNote: "test",
            sizeBytes: 0,
            fileCount: 1,
            modifiedAt: oldDate,
            isDirectory: false,
            isCustom: false
        )
        let directFifoItem = CleanableItem(
            clientID: "codex",
            clientName: "Codex",
            ruleID: "test",
            displayName: "direct-pipe",
            fileName: "direct-pipe",
            url: directFifo,
            category: .temporary,
            recommendation: .recommended,
            safetyNote: "test",
            sizeBytes: 0,
            fileCount: 1,
            modifiedAt: oldDate,
            isDirectory: false,
            isCustom: false
        )

        let result = cleaner.trash(items: [scannedDirItem, directSocketItem, directFifoItem], allowNotRecommendedOverride: true)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.skippedProtectedItems.count, 3)
        XCTAssertTrue(performer.trashedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateSocketDir.path))
    }

    func testAIClientProfileDecodesLegacyJSONWithoutKindField() throws {
        let legacyJSON = """
        {
            "id": "legacy-custom",
            "name": "Legacy",
            "symbolName": "folder",
            "accentToken": "custom",
            "description": "Legacy profile",
            "protectedSummary": "Protected",
            "rules": [],
            "isCustom": true,
            "customDirectoryID": null
        }
        """
        let decoded = try JSONDecoder().decode(AIClientProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.kind, .customDirectory)
    }

    // MARK: - Helpers

    @discardableResult
    private func createFile(in directory: URL, name: String, bytes: Int, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: max(0, bytes)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url.standardizedFileURL
    }

    @discardableResult
    private func createDirectoryWithFile(
        in directory: URL,
        dirName: String,
        fileName: String,
        bytes: Int,
        modifiedAt: Date
    ) throws -> URL {
        let dir = directory.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try createFile(in: dir, name: fileName, bytes: bytes, modifiedAt: modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: dir.path)
        return dir.standardizedFileURL
    }

    private func createUnixDomainSocket(in directory: URL, name: String) throws -> URL {
        let socketURL = directory.appendingPathComponent(name)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)

        let bindURL: URL
        if socketURL.path.utf8.count < maxLen - 1 {
            bindURL = socketURL
        } else {
            bindURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("s\(String(UUID().uuidString.prefix(8)))")
        }

        let pathBytes = Array(bindURL.path.utf8)
        XCTAssertLessThan(pathBytes.count, maxLen, "Unix socket 路径超过 sun_path 长度限制：\(bindURL.path)")
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
            rawBuffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "创建测试用 Unix Domain Socket 失败，errno=\(errno)")
        if bindURL != socketURL {
            try FileManager.default.moveItem(at: bindURL, to: socketURL)
        }
        return socketURL.standardizedFileURL
    }

    private func createFIFO(in directory: URL, name: String) throws -> URL {
        let fifoURL = directory.appendingPathComponent(name)
        let result = mkfifo(fifoURL.path, 0o600)
        XCTAssertEqual(result, 0, "创建测试用 FIFO 失败，errno=\(errno)")
        return fifoURL.standardizedFileURL
    }
}
