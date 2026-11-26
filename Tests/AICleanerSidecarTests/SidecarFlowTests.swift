import AICleanerCore
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
}

private struct Fixture {
    let root: URL
    let file: URL
    let trash: URL
    let platform: SandboxPlatformAdapter
    let client: TestClient

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICleanerSidecar-\(UUID())")
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        let file = directory.appendingPathComponent("sample.bin")
        let trash = root.appendingPathComponent("recycle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: file)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            homeDirectory: root,
            userDataDirectory: root.appendingPathComponent("data"),
            mockTrashDirectory: trash
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

    init(platform: any PlatformAdapter, scanner: any ScanPerforming) {
        let messages = self.messages
        server = SidecarServer(platform: platform, scanner: scanner) { message in
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
