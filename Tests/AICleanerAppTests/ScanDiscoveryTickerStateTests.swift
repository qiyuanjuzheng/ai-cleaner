@testable import AICleanerApp
import AICleanerCore
import XCTest

final class ScanDiscoveryTickerStateTests: XCTestCase {
    func testCardsAreReleasedOneByOneInDiscoveryOrder() {
        var ticker = ScanDiscoveryTickerState(visibleCapacity: 3)
        ticker.sync(with: ["a", "b"])

        XCTAssertTrue(ticker.visibleIDs.isEmpty, "新发现的卡片先排队，不一次性全部铺开")
        XCTAssertTrue(ticker.advance())
        XCTAssertEqual(ticker.visibleIDs, ["a"])
        XCTAssertTrue(ticker.advance())
        XCTAssertEqual(ticker.visibleIDs, ["a", "b"])
        XCTAssertFalse(ticker.advance())
    }

    func testRowKeepsSingleLineAndOldestCardScrollsOut() {
        var ticker = ScanDiscoveryTickerState(visibleCapacity: 3)
        ticker.sync(with: ["a", "b", "c", "d", "e"])
        while ticker.advance() {}

        XCTAssertEqual(ticker.visibleIDs, ["c", "d", "e"], "只保留一行，最早的卡片滚出消失")
    }

    func testSyncIgnoresAlreadySeenClients() {
        var ticker = ScanDiscoveryTickerState(visibleCapacity: 3)
        ticker.sync(with: ["a"])
        ticker.advance()
        ticker.sync(with: ["a", "b"])
        ticker.sync(with: ["a", "b"])

        XCTAssertEqual(ticker.pendingIDs, ["b"])
    }

    func testEmptySyncResetsForNextScan() {
        var ticker = ScanDiscoveryTickerState(visibleCapacity: 3)
        ticker.sync(with: ["a", "b"])
        ticker.advance()
        ticker.sync(with: [])

        XCTAssertTrue(ticker.visibleIDs.isEmpty)
        XCTAssertFalse(ticker.hasPending)
        ticker.sync(with: ["a"])
        XCTAssertEqual(ticker.pendingIDs, ["a"], "新一轮扫描同一客户端应重新出卡")
    }

    func testReleaseSpeedsUpWhenBacklogGrows() {
        var ticker = ScanDiscoveryTickerState()
        ticker.sync(with: ["a"])
        let slow = ticker.releaseInterval
        ticker.sync(with: ["a", "b", "c", "d", "e", "f"])
        XCTAssertLessThan(ticker.releaseInterval, slow)
    }
}

@MainActor
final class ScanProgressRevealedClientsTests: XCTestCase {
    private func client(_ id: String, state: ScanClientDetectionState, bytes: Int64) -> ScanProgressClient {
        ScanProgressClient(
            id: id, name: id, symbolName: "sparkles", accentToken: "codex",
            kind: .builtInClient, state: state, cleanableBytes: bytes, itemCount: bytes > 0 ? 1 : 0
        )
    }

    func testOnlyMeasuredClientsWithRealDataAreRevealed() {
        let model = ScanProgressModel()
        model.beginSession()
        model.apply(ScanProgressEvent(
            stage: .scanningClients,
            clients: [
                client("detecting", state: .detecting, bytes: 0),
                client("cursor", state: .measured, bytes: 0),
                client("claude-code", state: .measured, bytes: 1_320_000_000),
                client("kiro", state: .measured, bytes: 23_700_000)
            ],
            scannedFileCount: 10,
            cleanableBytes: 1_343_700_000,
            isFinal: false
        ))

        XCTAssertEqual(
            model.revealedClients.map(\.id), ["claude-code", "kiro"],
            "不展示「检测中」占位卡与 0 字节卡，只出真实数据卡片"
        )
    }
}
