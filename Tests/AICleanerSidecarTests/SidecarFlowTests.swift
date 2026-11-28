@testable import AICleanerCore
import Foundation
import XCTest
@testable import AICleanerSidecar

final class SidecarFlowTests: XCTestCase {
    func testScansSelectsPreviewsAndMovesAnIsolatedFileToTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = fixture.client

        let handshake = try await client.call("core.handshake", ["protocolVersion": .string("1.0")])
        XCTAssertEqual(handshake["protocolVersion"], .string("1.0"))
        let scan = try await client.call("scan.start")
        let scanID = try XCTUnwrap(scan["scanId"])
        let completed = try await client.completedScan(scanID)
        XCTAssertEqual(completed["status"], .string("completed"))
        XCTAssertTrue(client.messages.withLock { $0.contains { $0["method"] == .string("scan.progress") } })

        let query = try await client.call("items.query", ["scanId": scanID, "offset": .integer(0), "limit": .integer(1)])
        let item = try XCTUnwrap(query["items"]?.array?.first)
        let id = try XCTUnwrap(item["id"])
        XCTAssertEqual(item["fileName"], .string("sample.bin"))
        XCTAssertEqual(item["sizeBytes"], .integer(7))
        try await client.expectError(-32602, from: "selection.apply", [
            "scanId": scanID, "op": .string("toggle"), "itemIds": .array([.string(fixture.file.path)])
        ])

        let selection = try await client.call("selection.apply", [
            "scanId": scanID, "op": .string("toggle"), "itemIds": .array([id])
        ])
        XCTAssertEqual(selection["selectedCount"], .integer(1))
        let preview = try await client.call("trash.preview", ["scanId": scanID])
        let token = try XCTUnwrap(preview["confirmationToken"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        let params: [String: RPCValue] = ["scanId": scanID, "confirmationToken": token,
                                           "acknowledgedNotRecommendedRisk": .bool(false)]
        let result = try await client.call("trash.execute", params)
        XCTAssertEqual(result["result"]?["trashedCount"], .integer(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let trashContents = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        XCTAssertEqual(trashContents.count, 1)
        let trashedFile = fixture.trash.appendingPathComponent(try XCTUnwrap(trashContents.first))
        XCTAssertEqual(try Data(contentsOf: trashedFile), Data("payload".utf8))
        let history = try await client.call("history.list")
        XCTAssertEqual(history["records"]?.array?.first?["freedBytes"], .integer(7))
        try await client.expectError(-32006, from: "trash.execute", params)
    }

    func testInvalidatesPreviewOnSelectionChangeAndRejectsChangedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = fixture.client
        _ = try await client.call("core.handshake", ["protocolVersion": .string("1.0")])
        let scan = try await client.call("scan.start")
        let scanID = try XCTUnwrap(scan["scanId"])
        _ = try await client.completedScan(scanID)
        let select: [String: RPCValue] = ["scanId": scanID, "op": .string("selectAllVisible")]
        _ = try await client.call("selection.apply", select)
        let preview = try await client.call("trash.preview", ["scanId": scanID])
        let stale = try XCTUnwrap(preview["confirmationToken"])
        _ = try await client.call("selection.apply", ["scanId": scanID, "op": .string("clearAll")])
        _ = try await client.call("selection.apply", select)
        try await client.expectError(-32006, from: "trash.execute", ["scanId": scanID, "confirmationToken": stale])

        let fresh = try await client.call("trash.preview", ["scanId": scanID])
        try Data("updated after scan".utf8).write(to: fixture.file)
        let result = try await client.call("trash.execute", [
            "scanId": scanID, "confirmationToken": try XCTUnwrap(fresh["confirmationToken"])
        ])
        XCTAssertEqual(result["result"]?["trashedCount"], .integer(0))
        XCTAssertEqual(result["result"]?["failedItems"]?.array?.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("updated after scan".utf8))
    }

    func testPreservesCompletedScanAndSelectionPastIdleTimeout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = fixture.client
        let scanID = try await client.scan()
        _ = try await client.call("selection.apply", ["scanId": scanID, "op": .string("selectAllVisible")])

        let idle = await client.server.isIdle(now: ContinuousClock.now + .seconds(601))
        XCTAssertFalse(idle, "Exiting here would discard the completed scan and selection")
        let item = try await client.firstItem(scanID)
        XCTAssertEqual(item["selected"], .bool(true))
    }

    func testCancelsAStartedScanAndCannotStartAnotherUntilItFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = TestClient(platform: fixture.platform, scanner: WaitingScanner(platform: fixture.platform))
        _ = try await client.call("core.handshake", ["protocolVersion": .string("1.0")])
        let scan = try await client.call("scan.start")
        let scanID = try XCTUnwrap(scan["scanId"])
        try await client.expectError(-32001, from: "scan.start")
        let idleWhileScanning = await client.server.isIdle(now: ContinuousClock.now + .seconds(601))
        XCTAssertFalse(idleWhileScanning)
        _ = try await client.call("scan.cancel", ["scanId": scanID])
        let completed = try await client.completedScan(scanID)
        XCTAssertEqual(completed["status"], .string("cancelled"))
        try await client.expectError(-32002, from: "items.query", ["scanId": scanID])
        let idleAfterScan = await client.server.isIdle(now: ContinuousClock.now + .seconds(601))
        XCTAssertTrue(idleAfterScan)
    }

    func testDataDirectoryLockRejectsConcurrentWritersAndReleasesWhenClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.platform.userDataDirectory()
        do {
            let lock = try DataDirectoryLock(directory: directory)
            XCTAssertThrowsError(try DataDirectoryLock(directory: directory))
            withExtendedLifetime(lock) {}
        }
        XCTAssertNoThrow(try DataDirectoryLock(directory: directory))
    }

    func testExclusionUpdatesReportAndInvalidatesPendingTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = fixture.client
        let scanID = try await client.scan()
        let item = try await client.firstItem(scanID)
        let id = try XCTUnwrap(item["id"])
        _ = try await client.call("selection.apply", ["scanId": scanID, "op": .string("selectAllVisible")])
        let preview = try await client.call("trash.preview", ["scanId": scanID])
        let excluded = try await client.call("excluded.add", ["scanId": scanID, "itemId": id])
        let recordID = try XCTUnwrap(excluded["record"]?["id"])
        let listing = try await client.call("excluded.list")
        XCTAssertEqual(listing["records"]?.array?.count, 1)
        XCTAssertEqual(listing["statuses"]?[try XCTUnwrap(recordID.string)], .bool(true))
        let emptyQuery = try await client.call("items.query", ["scanId": scanID])
        XCTAssertEqual(emptyQuery["total"], .integer(0))
        try await client.expectError(-32006, from: "trash.execute", [
            "scanId": scanID, "confirmationToken": try XCTUnwrap(preview["confirmationToken"])
        ])
        _ = try await client.call("excluded.restore", ["id": recordID])
        let restored = try await client.firstItem(scanID)
        XCTAssertEqual(restored["id"], id)
        XCTAssertEqual(restored["selected"], .bool(false))
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("payload".utf8))
    }

    func testProjectProtectionPersistsAndInvalidatesPendingTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sessionID = "76cfd10c-14aa-4769-a102-075663169ac4"
        let sessionURL = fixture.root.appendingPathComponent(".claude/projects/fixture/\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "user", "cwd": workspace.path, "sessionId": sessionID,
            "message": ["role": "user", "content": "Project protection fixture"]
        ])
        try (json + Data([10])).write(to: sessionURL)
        let scanner = ScanEngine(builtInProfiles: [BuiltInClientRules.claudeCode], systemTempRoot: nil, platform: fixture.platform)
        let client = TestClient(platform: fixture.platform, scanner: scanner)
        let scanID = try await client.scan()
        let projects = try await client.call("projects.list", ["scanId": scanID, "clientId": .string("claude-code")])
        let project = try XCTUnwrap(projects["projects"]?.array?.first)
        let projectID = try XCTUnwrap(project["projectId"])
        let scope: RPCValue = .object(["kind": .string("clientProjects"), "clientId": .string("claude-code"), "projectId": projectID])
        let select: [String: RPCValue] = ["scanId": scanID, "scope": scope, "op": .string("selectAllVisible")]
        let selection = try await client.call("selection.apply", select)
        XCTAssertEqual(selection["selectedCount"], .integer(1))
        let preview = try await client.call("trash.preview", ["scanId": scanID])
        _ = try await client.call("projects.setProtection", ["projectId": projectID, "enabled": .bool(true)])
        try await client.expectError(-32006, from: "trash.execute", [
            "scanId": scanID, "confirmationToken": try XCTUnwrap(preview["confirmationToken"])
        ])
        let sessions = try await client.call("projects.sessions", ["scanId": scanID, "projectId": projectID])
        let row = try XCTUnwrap(sessions["items"]?.array?.first)
        XCTAssertNotNil(row["hardProtectionReason"]?.string)
        XCTAssertEqual(row["selected"], .bool(false))
        XCTAssertEqual(try ProjectProtectionStore(platform: fixture.platform).load().count, 1)
        XCTAssertEqual(try Data(contentsOf: sessionURL), json + Data([10]))
        _ = try await client.call("projects.setProtection", ["projectId": projectID, "enabled": .bool(false)])
        let unlocked = try await client.call("projects.sessions", ["scanId": scanID, "projectId": projectID])
        XCTAssertNil(unlocked["items"]?.array?.first?["hardProtectionReason"])
    }

    func testSettingsMigrationPersistenceAndCorruptBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dataDirectory = fixture.platform.userDataDirectory()
        let client = TestClient(platform: fixture.platform,
                                scanner: ScanEngine(builtInProfiles: [], systemTempRoot: nil, platform: fixture.platform),
                                legacyAppearance: { .dark })
        _ = try await client.call("core.handshake", ["protocolVersion": .string("1.0")])
        let initial = try await client.call("settings.get")
        XCTAssertEqual(initial["appearanceMode"], .string("dark"))
        _ = try await client.call("settings.set", ["appearanceMode": .string("system")])
        let persisted = try SettingsStore(directory: dataDirectory).load()
        XCTAssertEqual(persisted.appearanceMode, .system)
        let corrupted = Data("test corrupt settings".utf8)
        try corrupted.write(to: dataDirectory.appendingPathComponent("settings.json"))
        try await client.expectError(-32021, from: "settings.get")
        let names = try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("settings.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: dataDirectory.appendingPathComponent(backup)), corrupted)
    }

    #if os(macOS)
    func testReadsSwiftUIStorageWithoutRewritingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacyRelativePath = "Library/Application Support/AICleaner"
        let host = HostPlatformAdapter.shared
        XCTAssertEqual(
            host.userDataDirectory().standardizedFileURL.path,
            host.homeDirectory.appendingPathComponent(legacyRelativePath).standardizedFileURL.path
        )
        let directory = fixture.root.appendingPathComponent(legacyRelativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let platform = SandboxPlatformAdapter(wrapping: host, homeDirectory: fixture.root, userDataDirectory: directory)
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspacePath = workspace.resolvingSymlinksInPath().path
        let sessionID = "a44f25f8-e76d-4bda-ab69-55dce71da00a"
        let session = fixture.root.appendingPathComponent(".claude/projects/fixture/\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sessionEntry = try JSONSerialization.data(withJSONObject: [
            "type": "user", "cwd": workspacePath, "sessionId": sessionID,
            "message": ["role": "user", "content": "Existing protected project"]
        ])
        try (sessionEntry + Data([10])).write(to: session)

        // The v0.4.0 SwiftUI stores write JSON arrays and encode dates in ISO 8601.
        let historicalDate = "2026-11-24T05:10:00Z"
        let recordID = "B5CEB96C-D2F2-4653-BD87-7F8A61F27FE8"
        let data: [String: Any] = [
            "cleanup-history.json": [[
                "id": recordID, "timestamp": historicalDate, "freedBytes": 8192, "trashedCount": 1,
                "clientBreakdown": [], "categoryBreakdown": [], "sampleItemNames": ["removed.log"]
            ]],
            "excluded-items.json": [[
                "id": recordID, "normalizedPath": fixture.file.path, "displayName": "Existing exclusion",
                "clientID": "custom", "clientName": "Custom", "category": "cache",
                "isDirectory": false, "excludedAt": historicalDate
            ]],
            "custom-directories.json": [[
                "id": recordID, "displayName": "Existing custom directory", "path": fixture.file.deletingLastPathComponent().path,
                "category": "cache", "mode": "children", "createdAt": historicalDate
            ]],
            "protected-projects.json": [workspacePath]
        ]
        let original = try data.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
        for (name, bytes) in original {
            try bytes.write(to: directory.appendingPathComponent(name))
        }

        let scanner = ScanEngine(builtInProfiles: [BuiltInClientRules.claudeCode], systemTempRoot: nil, platform: platform)
        let client = TestClient(platform: platform, scanner: scanner, legacyAppearance: { .dark })
        let scanID = try await client.scan()
        let history = try await client.call("history.list")
        let exclusions = try await client.call("excluded.list")
        let directories = try await client.call("customDirs.list")
        let projects = try await client.call("projects.list", ["scanId": scanID, "clientId": .string("claude-code")])
        let settings = try await client.call("settings.get")
        XCTAssertEqual(history["records"]?.array?.first?["freedBytes"], .integer(8192))
        XCTAssertEqual(exclusions["records"]?.array?.first?["displayName"], .string("Existing exclusion"))
        XCTAssertEqual(directories["directories"]?.array?.first?["displayName"], .string("Existing custom directory"))
        let protectedProject = try XCTUnwrap(projects["projects"]?.array?.first)
        XCTAssertEqual(protectedProject["isProtected"], .bool(true))
        let sessions = try await client.call("projects.sessions", [
            "scanId": scanID, "projectId": try XCTUnwrap(protectedProject["projectId"])
        ])
        let protectedSession = try XCTUnwrap(sessions["items"]?.array?.first)
        XCTAssertNotNil(protectedSession["hardProtectionReason"]?.string)
        XCTAssertEqual(protectedSession["selected"], .bool(false))
        XCTAssertEqual(settings["appearanceMode"], .string("dark"))

        for (name, bytes) in original {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), bytes, name)
        }
    }
    #endif

    func testReportsCorruptProtectionAndPreservesFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = ProjectProtectionStore(platform: fixture.platform).storageURL
        let original = Data("corrupt project protection".utf8)
        try original.write(to: path)
        let client = fixture.client
        _ = try await client.call("core.handshake", ["protocolVersion": .string("1.0")])
        let scan = try await client.call("scan.start")
        let result = try await client.completedScan(XCTUnwrap(scan["scanId"]))
        XCTAssertEqual(result["status"], .string("failed"))
        XCTAssertEqual(result["error"]?["code"], .integer(-32021))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("payload".utf8))
    }

    func testSidecarRecyclesThroughTheNativeAdapter() async throws {
        let fixture = try Fixture(nativeTrash: true)
        defer { fixture.remove() }
        let client = fixture.client
        let scanID = try await client.scan()
        let item = try await client.firstItem(scanID)
        _ = try await client.call("selection.apply", [
            "scanId": scanID, "op": .string("toggle"), "itemIds": .array([try XCTUnwrap(item["id"])])
        ])
        let preview = try await client.call("trash.preview", ["scanId": scanID])
        let execution = try await client.call("trash.execute", [
            "scanId": scanID, "confirmationToken": try XCTUnwrap(preview["confirmationToken"])
        ])
        let result = try XCTUnwrap(execution["result"])
        XCTAssertEqual(result["trashedCount"], .integer(1), "\(result)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        if let path = result["trashedItems"]?.array?.first?["resultingTrashPath"]?.string {
            let trashed = URL(fileURLWithPath: path)
            XCTAssertEqual(try Data(contentsOf: trashed), Data("payload".utf8))
            try FileManager.default.moveItem(at: trashed, to: fixture.file)
            XCTAssertEqual(try Data(contentsOf: fixture.file), Data("payload".utf8))
        }
    }

    func testHandshakeAndMalformedRequestsReturnProtocolErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = fixture.client
        try await client.expectError(-32000, from: "scan.start")
        try await client.expectError(-32000, from: "core.handshake", ["protocolVersion": .string("2.0")])
        _ = try await client.call("core.handshake", ["protocolVersion": .string("1.1")])
        try await client.expectError(-32601, from: "unknown.method")
        _ = await client.server.receive("{bad json")
        let error = client.messages.withLock { $0.last?["error"]?["code"] }
        XCTAssertEqual(error, .integer(-32700))
    }

    func testSharedProtocolFixturesDecodeAndHandshakeThroughSidecar() async throws {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/rpc-v1-samples.json")
        let data = try Data(contentsOf: fixturesURL)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        let requests = try XCTUnwrap(decoded["requests"]?.array)
        let notifications = try XCTUnwrap(decoded["notifications"]?.array)
        let errors = try XCTUnwrap(decoded["errors"]?.array)
        XCTAssertFalse(requests.isEmpty)
        XCTAssertFalse(notifications.isEmpty)
        XCTAssertFalse(errors.isEmpty)

        // Round-trip every fixture entry through RPCValue encoder/decoder
        for group in [requests, notifications, errors] {
            for entry in group {
                let reencoded = try JSONEncoder().encode(entry)
                let reparsed = try JSONDecoder().decode(RPCValue.self, from: reencoded)
                XCTAssertEqual(reparsed, entry)
            }
        }

        // Dispatch the shared handshake request fixture directly into SidecarServer
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handshakeLine = try String(decoding: JSONEncoder().encode(requests[0]), as: UTF8.self)
        let keepRunning = await fixture.client.server.receive(handshakeLine)
        XCTAssertTrue(keepRunning)
        let reply = fixture.client.messages.withLock { $0.last }
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("1.0"))
    }
}

private struct Fixture {
    let root: URL
    let file: URL
    let trash: URL
    let platform: SandboxPlatformAdapter
    let client: TestClient

    init(nativeTrash: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICleanerSidecar-\(UUID())")
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        let filename = nativeTrash ? "AICleaner-CI-\(UUID().uuidString).bin" : "sample.bin"
        let file = directory.appendingPathComponent(filename)
        let trash = root.appendingPathComponent("recycle", isDirectory: true)
        let nativePerformer: (@Sendable (URL) throws -> TrashOutcome)?
        if nativeTrash {
            #if os(Linux)
            nativePerformer = { try LinuxTrash.move($0, dataHome: trash, platform: HostPlatformAdapter.shared) }
            #else
            nativePerformer = { try HostPlatformAdapter.shared.moveToTrash($0) }
            #endif
        } else {
            nativePerformer = nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: file)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            homeDirectory: root,
            userDataDirectory: root.appendingPathComponent("data"),
            moveToTrashOverride: nativePerformer,
            mockTrashDirectory: nativeTrash ? nil : trash
        )
        let scanner = ScanEngine(builtInProfiles: [], systemTempRoot: nil, platform: platform)
        let store = CustomDirectoryStore(platform: platform)
        try store.add(url: directory, category: .cache)
        self.root = root
        self.file = file
        self.trash = trash
        self.platform = platform
        self.client = TestClient(platform: platform, scanner: scanner)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct WaitingScanner: ScanPerforming {
    let homeDirectory: URL
    let safetyGuard: SafetyGuard

    init(platform: any PlatformAdapter) {
        homeDirectory = platform.homeDirectory
        safetyGuard = SafetyGuard(platform: platform)
    }

    func scan(customDirectories: [CustomScanDirectory], excludedItems: [ExcludedItemRecord], now: Date?) -> ScanReport {
        let deadline = ContinuousClock.now + .seconds(5)
        while !Task.isCancelled && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return ScanReport(scannedAt: Date(), clientSummaries: [], totalBuiltInProfilesCount: 0,
                          detectedBuiltInClientsCount: 0, skippedProtectedCount: 0)
    }
}

private final class TestClient {
    let server: SidecarServer
    let messages = CoreLock<[RPCValue]>(initialState: [])
    private var nextID: Int64 = 0

    init(platform: any PlatformAdapter, scanner: any ScanPerforming,
         legacyAppearance: @escaping @Sendable () -> AppearanceMode? = { nil }) {
        let messages = self.messages
        server = SidecarServer(platform: platform, scanner: scanner, legacyAppearance: legacyAppearance) { message in
            messages.withLock { $0.append(message) }
        }
    }

    func call(_ method: String, _ params: [String: RPCValue] = [:]) async throws -> RPCValue {
        let response = try await request(method, params)
        return try XCTUnwrap(response["result"], "Expected result for \(method), got \(response)")
    }

    func expectError(_ code: Int64, from method: String, _ params: [String: RPCValue] = [:]) async throws {
        let response = try await request(method, params)
        XCTAssertEqual(response["error"]?["code"], .integer(code), "Method: \(method)")
    }

    func scan() async throws -> RPCValue {
        _ = try await call("core.handshake", ["protocolVersion": .string("1.0")])
        let started = try await call("scan.start")
        let scanID = try XCTUnwrap(started["scanId"])
        let completed = try await completedScan(scanID)
        XCTAssertEqual(completed["status"], .string("completed"), "\(completed)")
        return scanID
    }

    func firstItem(_ scanID: RPCValue) async throws -> RPCValue {
        let result = try await call("items.query", ["scanId": scanID, "limit": .integer(1)])
        return try XCTUnwrap(result["items"]?.array?.first)
    }

    func completedScan(_ scanID: RPCValue) async throws -> RPCValue {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let completed = messages.withLock { messages in
                messages.first { $0["method"] == .string("scan.completed") && $0["params"]?["scanId"] == scanID }
            }
            if let params = completed?["params"] { return params }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil, "Timed out waiting for scan.completed")
    }

    private func request(_ method: String, _ params: [String: RPCValue]) async throws -> RPCValue {
        nextID += 1
        let id = RPCValue.integer(nextID)
        let request: RPCValue = .object(["jsonrpc": .string("2.0"), "id": id,
                                         "method": .string(method), "params": .object(params)])
        _ = await server.receive(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try XCTUnwrap(messages.withLock { $0.first { $0["id"] == id } })
    }
}
