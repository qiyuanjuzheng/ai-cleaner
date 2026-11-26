@testable import AICleanerApp
import AICleanerCore
import Foundation
import XCTest

@MainActor
final class ScanProgressModelTests: XCTestCase {
    private func makeEvent(
        stage: ScanStage,
        clients: [ScanProgressClient],
        scannedFileCount: Int = 0,
        cleanableBytes: Int64 = 0,
        isFinal: Bool = false
    ) -> ScanProgressEvent {
        ScanProgressEvent(
            stage: stage,
            clients: clients,
            scannedFileCount: scannedFileCount,
            cleanableBytes: cleanableBytes,
            isFinal: isFinal
        )
    }

    private func detectingClient(_ id: String) -> ScanProgressClient {
        ScanProgressClient(
            id: id,
            name: id,
            symbolName: "sparkles",
            accentToken: "codex",
            kind: .builtInClient,
            state: .detecting,
            cleanableBytes: 0,
            itemCount: 0
        )
    }

    func testBeginSessionResetsResidueAndEntersFirstStage() {
        let model = ScanProgressModel()
        model.beginSession()
        model.apply(makeEvent(
            stage: .analyzingCacheFiles,
            clients: [detectingClient("cursor")],
            scannedFileCount: 120,
            cleanableBytes: 3_000
        ))

        // 取消后 endSession，再开始新一轮扫描应完全无上一轮残留
        model.endSession()
        model.beginSession()

        XCTAssertEqual(model.currentStage, .scanningClients)
        XCTAssertFalse(model.isCompleted)
        XCTAssertTrue(model.detectedClients.isEmpty)
        XCTAssertEqual(model.scannedFileCount, 0)
        XCTAssertEqual(model.cleanableBytes, 0)
    }

    func testEndSessionDiscardsInFlightEvents() {
        let model = ScanProgressModel()
        model.beginSession()
        model.endSession()

        model.apply(makeEvent(
            stage: .analyzingCacheFiles,
            clients: [detectingClient("cursor")],
            scannedFileCount: 99,
            cleanableBytes: 1_234
        ))

        XCTAssertEqual(model.currentStage, .scanningClients)
        XCTAssertTrue(model.detectedClients.isEmpty)
        XCTAssertEqual(model.scannedFileCount, 0)
    }

    func testApplyUpdatesSnapshotAndFinalMarksCompleted() {
        let model = ScanProgressModel()
        model.beginSession()

        let measured = ScanProgressClient(
            id: "cursor", name: "Cursor", symbolName: "sparkles", accentToken: "cursor",
            kind: .builtInClient, state: .measured, cleanableBytes: 8_000, itemCount: 2
        )
        model.apply(makeEvent(
            stage: .analyzingCacheFiles,
            clients: [detectingClient("claude-code"), measured],
            scannedFileCount: 42,
            cleanableBytes: 8_000
        ))

        XCTAssertEqual(model.currentStage, .analyzingCacheFiles)
        XCTAssertEqual(model.detectedClients.map(\.id), ["claude-code", "cursor"])
        XCTAssertEqual(model.scannedFileCount, 42)
        XCTAssertFalse(model.isCompleted)
        XCTAssertEqual(model.displayState(for: .scanningClients), .done)
        XCTAssertEqual(model.displayState(for: .analyzingCacheFiles), .active)
        XCTAssertEqual(model.displayState(for: .tallyingCleanableSpace), .pending)

        model.apply(makeEvent(
            stage: .tallyingCleanableSpace,
            clients: [measured, ScanProgressClient(
                id: "claude-code", name: "Claude Code", symbolName: "sparkles", accentToken: "claude",
                kind: .builtInClient, state: .measured, cleanableBytes: 2_500, itemCount: 2
            )],
            scannedFileCount: 57,
            cleanableBytes: 10_500,
            isFinal: true
        ))

        XCTAssertTrue(model.isCompleted)
        for stage in ScanStage.allCases {
            XCTAssertEqual(model.displayState(for: stage), .done, "扫描结束时三步应全部完成")
        }
    }

    func testFinishSessionWithoutEventsStillMarksCompleted() {
        let model = ScanProgressModel()
        model.beginSession()
        // 无进度事件的扫描执行器（协议默认实现 / 测试桩）也必须呈现完成态
        model.finishSession()

        XCTAssertTrue(model.isCompleted)
        XCTAssertEqual(model.displayState(for: .scanningClients), .done)
    }

    func testAccessibilityLabelsCoverStageAndStats() {
        let model = ScanProgressModel()
        model.beginSession()
        model.apply(makeEvent(
            stage: .analyzingCacheFiles,
            clients: [detectingClient("cursor")],
            scannedFileCount: 12_847,
            cleanableBytes: 2_411_748_010
        ))

        let stageLabel = model.stageAccessibilityLabel
        XCTAssertTrue(stageLabel.contains("第 2 步"))
        XCTAssertTrue(stageLabel.contains("分析缓存文件"))

        let statsLabel = model.statsAccessibilityLabel
        // 分组分隔符随运行环境 locale 变化，这里对数字做 locale 无关断言
        XCTAssertTrue(statsLabel.filter(\.isNumber).contains("12847"))
        XCTAssertTrue(statsLabel.contains("可清理空间"))

        model.finishSession()
        XCTAssertTrue(model.stageAccessibilityLabel.contains("全部完成"))
    }
}
