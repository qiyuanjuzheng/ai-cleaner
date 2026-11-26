@testable import AICleanerCore
import XCTest

final class ProjectSessionTests: XCTestCase {
    func testScanUsesExactPathsAndKeepsDisplayHintsOutOfProjectIdentity() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let claude = ".claude/projects/-Users-test-demo"
        let codexID = "11111111-1111-4111-8111-111111111111"
        let indexedID = "22222222-2222-4222-8222-222222222222"
        let conflictingID = "33333333-3333-4333-8333-333333333333"
        let codex = try write("""
            {"type":"session_meta","payload":{"id":"\(codexID)","cwd":"/work/products/./demo/"}}
            """, ".codex/sessions/2026/01/rollout-2026-01-01T00-00-00-\(codexID).jsonl", in: sandbox)
        let primary = try write(#"{"type":"user","cwd":"/work/products/demo","message":{"role":"user","content":"Demo"}}"#, "\(claude)/one.jsonl", in: sandbox)
        let sameName = try write(#"{"type":"user","cwd":"/other/demo"}"#, "\(claude)/two.jsonl", in: sandbox)
        let worktree = try write(#"{"type":"user","cwd":"/work/products/demo/.worktrees/release"}"#, "\(claude)/three.jsonl", in: sandbox)
        let differentCase = try write(#"{"type":"user","cwd":"/work/products/Demo"}"#, "\(claude)/four.jsonl", in: sandbox)
        let hintOnly = try write(#"{"type":"custom-title","customTitle":"Name only"}"#, "\(claude)/five.jsonl", in: sandbox)
        let indexed = try write(#"{"type":"assistant"}"#, "\(claude)/\(indexedID).jsonl", in: sandbox)
        let conflicting = try write(#"{"type":"user","cwd":"/other/demo"}"#, "\(claude)/\(conflictingID).jsonl", in: sandbox)
        let fuzzy = try write(#"{"type":"assistant"}"#, "\(claude)/notes-\(indexedID).jsonl", in: sandbox)
        _ = try write("""
            {"entries":[{"sessionId":"\(indexedID)","projectPath":"/work/products/demo"},{"sessionId":"\(conflictingID)","projectPath":"/work/products/demo"}]}
            """, "\(claude)/sessions-index.json", in: sandbox)
        let image = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(codexID)/image.png", byteCount: 15)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/shared-\(codexID)/image.png", byteCount: 15)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(indexedID)/image.png", byteCount: 15)

        let report = ScanEngine(homeDirectory: sandbox.homeURL).scan()
        let catalog = ProjectSessionCatalog(items: report.projectItems)
        let projects = Dictionary(uniqueKeysWithValues: catalog.projects.map { ($0.id, Set($0.sessions.map(\.url.path))) })
        XCTAssertEqual(projects[.workspace("/work/products/demo")], [codex.path, primary.path, indexed.path])
        XCTAssertEqual(projects[.workspace("/other/demo")], [sameName.path])
        XCTAssertEqual(projects[.workspace("/work/products/demo/.worktrees/release")], [worktree.path])
        XCTAssertEqual(projects[.workspace("/work/products/Demo")], [differentCase.path])
        XCTAssertEqual(projects[.unidentified], [hintOnly.path, conflicting.path, fuzzy.path])

        let codexSession = try XCTUnwrap(report.allItems.first { $0.url.path == codex.path })
        XCTAssertEqual(catalog.artifacts(for: codexSession).map(\.url.path), [image.deletingLastPathComponent().path])
        XCTAssertEqual(report.allItems.first { $0.url.path == indexed.path }?.projectEvidence, .exactIndex("/work/products/demo"))
    }

    func testScannedClaudeFileHistoryAssociatesOnlyExactSessionDirectories() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let sessionID = "11111111-1111-4111-8111-111111111111"
        let path = "/work/demo"
        let session = try write(#"{"type":"user","cwd":"/work/demo"}"#,
                                ".claude/projects/-work-demo/\(sessionID).jsonl", in: sandbox)
        let backup = try sandbox.createFile(relativeToHome: ".claude/file-history/\(sessionID)/snapshot", byteCount: 10)
        _ = try sandbox.createFile(relativeToHome: ".claude/file-history/shared-\(sessionID)/snapshot", byteCount: 10)

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let report = engine.scan()
        let catalog = ProjectSessionCatalog(items: report.projectItems)
        let item = try XCTUnwrap(report.allItems.first { $0.url.path == session.path })
        XCTAssertEqual(catalog.artifacts(for: item).map(\.url.path), [backup.deletingLastPathComponent().path])

        let parent = candidate(backup.deletingLastPathComponent().deletingLastPathComponent(), directory: true)
        XCTAssertTrue(catalog.protection(for: [path]).blocks(parent))
    }

    func testCleanupChecksCurrentProtectionForParentAndOverrideEvenWhenSessionIsExcluded() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let session = try write(#"{"type":"session_meta","payload":{"cwd":"/work/demo"}}"#,
                                ".codex/sessions/2026/01/session.jsonl", in: sandbox)
        let store = ProjectProtectionStore(storageURL: sandbox.rootURL.appendingPathComponent("projects.json"))
        try store.save(["/work/demo"])

        let engine = ScanEngine(homeDirectory: sandbox.homeURL)
        let original = engine.scan()
        let sessionItem = try XCTUnwrap(original.allItems.first { $0.url.path == session.path })
        let report = engine.scan(excludedItems: [.from(item: sessionItem)])
        XCTAssertFalse(report.allDisplayedItems.contains { $0.id == sessionItem.id })
        let catalog = ProjectSessionCatalog(items: report.projectItems)
        let parentURL = session.deletingLastPathComponent()
        let parent = candidate(parentURL, directory: true, recommendation: .notRecommended)
        let cleaner = TrashCleaner(safetyGuard: engine.safetyGuard, performer: FixtureTrash(destination: sandbox.rootURL))

        let blocked = cleaner.trash(items: [parent], allowNotRecommendedOverride: true,
                                    projectCatalog: catalog, projectProtectionStore: store)
        XCTAssertEqual(blocked.skippedProtectedItems.map(\.item.id), [parent.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))

        try ProjectProtectionStore(storageURL: store.storageURL).save([])
        let stillRequiresOverride = cleaner.trash(items: [parent], projectCatalog: catalog, projectProtectionStore: store)
        XCTAssertEqual(stillRequiresOverride.skippedProtectedItems.map(\.item.id), [parent.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))

        let allowed = cleaner.trash(items: [parent], allowNotRecommendedOverride: true,
                                    projectCatalog: catalog, projectProtectionStore: store)
        XCTAssertEqual(allowed.trashedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }

    func testCleanupSkipsUpdatedAndReplacedFilesAndChangedDirectoryChildren() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanup() }
        let frozenTime = Date(timeIntervalSince1970: 1_700_000_000)
        let replaced = try sandbox.createFile(relativeToHome: "replaced.jsonl", byteCount: 4, modifiedAt: frozenTime)
        let updated = try sandbox.createFile(relativeToHome: "updated.jsonl", byteCount: 4, modifiedAt: frozenTime)
        let child = try sandbox.createFile(relativeToHome: "tree/events.jsonl", byteCount: 4, modifiedAt: frozenTime)
        let unchanged = try sandbox.createFile(relativeToHome: "unchanged.jsonl", byteCount: 4, modifiedAt: frozenTime)
        let missing = sandbox.homeURL.appendingPathComponent("missing.jsonl")
        let items = [candidate(replaced), candidate(updated), candidate(child.deletingLastPathComponent(), directory: true),
                     candidate(unchanged), candidate(missing)]

        try Data("same".utf8).write(to: replaced, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: frozenTime], ofItemAtPath: replaced.path)
        try Data("updated".utf8).write(to: updated)
        try Data("updated child".utf8).write(to: child)

        let cleaner = TrashCleaner(safetyGuard: SafetyGuard(homeDirectory: sandbox.homeURL),
                                   performer: FixtureTrash(destination: sandbox.rootURL))
        let result = cleaner.trash(items: items, verifyProjectSelection: true)
        XCTAssertEqual(result.trashedItems.map(\.item.url.path), [unchanged.path])
        XCTAssertEqual(Set(result.failedItems.map(\.item.id)), Set([items[0].id, items[1].id, items[2].id, items[4].id]))
    }

    private func candidate(
        _ url: URL, directory: Bool = false, recommendation: CleanupRecommendation = .reviewSuggested
    ) -> CleanableItem {
        CleanableItem(clientID: "fixture", clientName: "Fixture", ruleID: "fixture", displayName: url.lastPathComponent,
                      fileName: url.lastPathComponent, url: url, category: .sessions, recommendation: recommendation,
                      safetyNote: "", sizeBytes: 4, fileCount: 1, modifiedAt: .now, isDirectory: directory,
                      isCustom: false, cleanupSnapshot: FileCleanupSnapshot.capture(at: url))
    }

    private func write(_ content: String, _ path: String, in sandbox: TestSandbox) throws -> URL {
        let url = try sandbox.createFile(relativeToHome: path, byteCount: 0)
        try Data((content + "\n").utf8).write(to: url)
        return url
    }

    private struct FixtureTrash: TrashPerforming {
        let destination: URL

        func trashItem(at url: URL) throws -> URL? {
            let moved = destination.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
    }
}
