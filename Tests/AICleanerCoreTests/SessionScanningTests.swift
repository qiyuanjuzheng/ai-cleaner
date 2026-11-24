import AICleanerCore
import Foundation
import XCTest

private final class SessionSandboxTrashPerformer: TrashPerforming, @unchecked Sendable {
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

final class SessionScanningTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "SessionScanningTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testClaudeCodeProjectSessionsScanPreservesMemoryAndIndexAndExtractsPromptPreview() throws {
        let projectRel = ".claude/projects/-Users-alice-workspace-demo-app"
        let sessionA = sandbox.homeURL.appendingPathComponent("\(projectRel)/11111111-aaaa-bbbb-cccc-000000000001.jsonl")
        try writeUTF8(
            """
            {"type":"queue-operation","operation":"start"}
            {"type":"user","cwd":"/Users/alice/workspace/demo-app","isSidechain":false,"message":{"role":"user","content":"帮我排查登录按钮点击无响应的问题"}}
            """,
            to: sessionA
        )

        // 伴随子代理/工具产物目录
        try sandbox.createFile(
            relativeToHome: "\(projectRel)/11111111-aaaa-bbbb-cccc-000000000001/tool-results/out.txt",
            byteCount: 2_048
        )

        // 必须严格保护的 memory 目录与 sessions-index.json
        let memoryFile = try sandbox.createFile(relativeToHome: "\(projectRel)/memory/MEMORY.md", byteCount: 256)
        let indexFile = try sandbox.createFile(relativeToHome: "\(projectRel)/sessions-index.json", byteCount: 128)
        // 活跃 sessions/*.key 也绝不可扫描
        try sandbox.createFile(relativeToHome: ".claude/sessions/12345.abc.key", byteCount: 64)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        let claude = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "claude-code" }))
        let sessionItems = claude.items.filter { $0.category == .sessions }

        XCTAssertEqual(sessionItems.count, 2)
        XCTAssertTrue(sessionItems.contains { $0.url.path == sessionA.path })
        XCTAssertTrue(sessionItems.contains { $0.displayName.contains("demo-app") && $0.displayName.contains("帮我排查登录按钮点击无响应的问题") })
        XCTAssertTrue(sessionItems.contains { $0.isDirectory && $0.displayName.contains("子代理/产物") })
        XCTAssertFalse(claude.items.contains { $0.url.path == memoryFile.path || $0.fileName == "memory" })
        XCTAssertFalse(claude.items.contains { $0.url.path == indexFile.path })

        // 安全护栏依然阻止将 ~/.claude/projects 整体加入清理或删除
        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        XCTAssertFalse(guardInstance.validateTarget(sandbox.homeURL.appendingPathComponent(".claude/projects")).isAllowed)
        XCTAssertFalse(guardInstance.validateTarget(sandbox.homeURL.appendingPathComponent("\(projectRel)/memory")).isAllowed)
        XCTAssertFalse(guardInstance.validateTarget(indexFile).isAllowed)
    }

    func testCodexNestedDateSessionsAndPiSessionsScanCorrectly() throws {
        // 1. Codex 2026 JSONL（包含应跳过的 <environment_context> 模板与真实用户提问）
        let codexJSONL = sandbox.homeURL.appendingPathComponent(
            ".codex/sessions/2026/11/02/rollout-2026-11-02T08-42-37-01a199b5-4a6f-7591-af48-46874459a62c.jsonl"
        )
        try writeUTF8(
            """
            {"type":"session_meta","payload":{"cwd":"/Users/alice/workspace/ai-cleaner","id":"01a199b5"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>ignored</environment_context>"}]}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"增加按天筛选一次性聊天会话功能"}]}}
            """,
            to: codexJSONL
        )

        // 2. Codex 压缩归档 .jsonl.zst
        try sandbox.createFile(
            relativeToHome: ".codex/sessions/2026/04/29/rollout-2026-04-29T16-42-16-019dd867-38a5-73e3-b3c5-4a0bdfbf2a95.jsonl.zst",
            byteCount: 4_096
        )

        // 3. Codex 不应触碰的核心文件
        try sandbox.createFile(relativeToHome: ".codex/auth.json", byteCount: 64)
        try sandbox.createFile(relativeToHome: ".codex/thread_history_1.sqlite", byteCount: 1024)

        // 4. Pi 会话文件
        let piSession = sandbox.homeURL.appendingPathComponent(
            ".pi/agent/sessions/--Users-alice-workspace-slider-3d--/2026-10-23T00-23-05-234Z_01a16623-cf12-77f1-9b83-0da4654db826.jsonl"
        )
        try writeUTF8(
            """
            {"type":"session","cwd":"/Users/alice/workspace/slider-3d","id":"01a16623"}
            {"type":"message","message":{"role":"user","content":[{"type":"text","text":"写一个轻量级 3D 卡片轮播组件"}]}}
            """,
            to: piSession
        )
        try sandbox.createFile(relativeToHome: ".pi/agent/auth.json", byteCount: 64)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()

        let codex = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "codex" }))
        let codexSessions = codex.items.filter { $0.category == .sessions }
        XCTAssertEqual(codexSessions.count, 2)
        XCTAssertTrue(codexSessions.contains { $0.displayName.contains("ai-cleaner") && $0.displayName.contains("增加按天筛选一次性聊天会话功能") })
        XCTAssertTrue(codexSessions.contains { $0.displayName.contains("2026-04-29 16:42") && $0.displayName.contains("压缩会话归档") })

        let pi = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "pi" }))
        XCTAssertEqual(pi.items.count, 1)
        XCTAssertEqual(pi.items.first?.category, .sessions)
        XCTAssertTrue(pi.items.first?.displayName.contains("slider-3d") == true)
        XCTAssertTrue(pi.items.first?.displayName.contains("写一个轻量级 3D 卡片轮播组件") == true)

        // 会话根容器仍被 SafetyGuard 保护，禁止整体删除
        let safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
        XCTAssertFalse(safetyGuard.validateTarget(sandbox.homeURL.appendingPathComponent(".codex/sessions")).isAllowed)
        XCTAssertFalse(safetyGuard.validateTarget(sandbox.homeURL.appendingPathComponent(".pi/agent/sessions")).isAllowed)
    }

    func testTrashingSingleOneOffSessionLeavesSiblingSessionAndMemoryIntact() throws {
        let projectRel = ".claude/projects/-Users-alice-workspace-keep-me"
        let oneOff = sandbox.homeURL.appendingPathComponent("\(projectRel)/aaaaaaaa-1111-2222-3333-444444444444.jsonl")
        let keepSession = sandbox.homeURL.appendingPathComponent("\(projectRel)/bbbbbbbb-1111-2222-3333-444444444444.jsonl")
        try writeUTF8("{\"type\":\"user\",\"cwd\":\"/Users/alice/workspace/keep-me\",\"message\":{\"role\":\"user\",\"content\":\"一次性临时提问\"}}\n", to: oneOff)
        try writeUTF8("{\"type\":\"user\",\"cwd\":\"/Users/alice/workspace/keep-me\",\"message\":{\"role\":\"user\",\"content\":\"长期项目主会话\"}}\n", to: keepSession)
        let memoryFile = try sandbox.createFile(relativeToHome: "\(projectRel)/memory/MEMORY.md", byteCount: 512)

        let safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
        let engine = ScanEngine(homeDirectory: sandbox.homeURL, safetyGuard: safetyGuard)
        let cleaner = TrashCleaner(
            safetyGuard: safetyGuard,
            performer: try SessionSandboxTrashPerformer(trashDir: sandbox.rootURL.appendingPathComponent("Trash", isDirectory: true))
        )

        let before = engine.scan()
        let targetItem = try XCTUnwrap(before.allItems.first(where: { $0.url.path == oneOff.path }))
        let result = cleaner.trash(items: [targetItem])

        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oneOff.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryFile.path))

        let after = engine.scan()
        XCTAssertEqual(after.allItems.count, 1)
        XCTAssertEqual(after.allItems.first?.url.path, keepSession.path)
    }

    private func writeUTF8(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}
