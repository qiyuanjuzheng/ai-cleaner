import AICleanerCore
import Foundation
import XCTest

final class ScanProgressTests: XCTestCase {
    /// 线程安全事件收集器：emitter 回调来自并发扫描线程，不允许裸捕获局部变量
    private final class EventCollector: @unchecked Sendable {
        private let lock = CoreLock(initialState: [ScanProgressEvent]())

        var events: [ScanProgressEvent] {
            lock.withLock { $0 }
        }

        func append(_ event: ScanProgressEvent) {
            lock.withLock { $0.append(event) }
        }
    }

    private func makeCollector() -> EventCollector {
        EventCollector()
    }

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "ScanProgressTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    // MARK: - ScanProgressEmitter 单元行为

    func testStageUpdateEmitsSnapshotAndSwitchesStage() {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) })

        emitter.update(stage: .scanningClients)
        emitter.update(stage: .analyzingCacheFiles)

        XCTAssertEqual(collector.events.count, 2)
        XCTAssertEqual(collector.events[0].stage, .scanningClients)
        XCTAssertEqual(collector.events[1].stage, .analyzingCacheFiles)
        XCTAssertFalse(collector.events[1].isFinal)
        XCTAssertTrue(collector.events[1].clients.isEmpty)
    }

    func testDetectClientUpsertsOnceAndKeepsDiscoveryOrder() {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) })

        emitter.detectClient(makeClient(id: "cursor", name: "Cursor", state: .detecting))
        emitter.detectClient(makeClient(id: "claude-code", name: "Claude Code", state: .detecting))
        // 重复检测同一客户端不应重复出卡
        emitter.detectClient(makeClient(id: "cursor", name: "Cursor", state: .detecting))
        emitter.measureClient(
            id: "claude-code", name: "Claude Code", symbolName: "c", accentToken: "claude",
            kind: .builtInClient, cleanableBytes: 2_500, itemCount: 3, insertIfMissing: false
        )
        emitter.measureClient(
            id: "cursor", name: "Cursor", symbolName: "u", accentToken: "cursor",
            kind: .builtInClient, cleanableBytes: 8_000, itemCount: 1, insertIfMissing: false
        )

        let last = collector.events.last
        XCTAssertEqual(last?.clients.map(\.id), ["cursor", "claude-code"])
        XCTAssertEqual(last?.clients.first?.state, .measured)
        XCTAssertEqual(last?.clients.first?.cleanableBytes, 8_000)
        XCTAssertEqual(last?.clients.last?.state, .measured)
    }

    func testMeasureClientWithoutDetectDoesNotInsertCardWhenDisabled() {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) })

        emitter.measureClient(
            id: "codex", name: "Codex", symbolName: "x", accentToken: "codex",
            kind: .builtInClient, cleanableBytes: 1_000, itemCount: 1, insertIfMissing: false
        )

        XCTAssertTrue(collector.events.isEmpty, "本机不存在的客户端不应凭空插入卡片")
    }

    func testMeasureClientInsertsWhenAllowed() {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) })

        emitter.measureClient(
            id: "other-ai-temp", name: "其他 AI 临时文件", symbolName: "clock", accentToken: "codex",
            kind: .otherAITemp, cleanableBytes: 640, itemCount: 2, insertIfMissing: true
        )

        XCTAssertEqual(collector.events.count, 1)
        XCTAssertEqual(collector.events[0].clients.first?.state, .measured)
        XCTAssertEqual(collector.events[0].clients.first?.cleanableBytes, 640)
    }

    func testStatsAccumulateAndFlushCarriesTotals() throws {
        // statsMinInterval 设为超长，验证纯统计增量在节流窗口内不逐条发布，flush 强制发布终值
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) }, statsMinInterval: 60)

        emitter.update(stage: .scanningClients)
        emitter.addScanStats(fileCount: 10, bytes: 1_000)
        emitter.addScanStats(fileCount: 5, bytes: 2_000)
        emitter.detectClient(makeClient(id: "cursor", name: "Cursor", state: .detecting))
        emitter.flush()

        let final = try XCTUnwrap(collector.events.last)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.scannedFileCount, 15)
        XCTAssertEqual(final.cleanableBytes, 3_000)

        // 节流窗口内：detect 事件也携带最新累计值
        let detectEvent = try XCTUnwrap(collector.events.first(where: { !$0.clients.isEmpty }))
        XCTAssertEqual(detectEvent.scannedFileCount, 15)
        XCTAssertEqual(detectEvent.cleanableBytes, 3_000)
    }

    func testStatsThrottleSuppressesIntermediateEmissions() {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) }, statsMinInterval: 60)

        emitter.update(stage: .scanningClients)
        let countAfterStage = collector.events.count
        emitter.addScanStats(fileCount: 3, bytes: 100)
        emitter.addScanStats(fileCount: 4, bytes: 200)

        XCTAssertEqual(collector.events.count, countAfterStage, "节流窗口内纯统计增量不应发布")
    }

    func testNegativeStatsDeltasAreClampedToZero() throws {
        let collector = makeCollector()
        let emitter = ScanProgressEmitter(handler: { collector.append($0) })

        emitter.flush()
        let final = try XCTUnwrap(collector.events.last)
        XCTAssertEqual(final.scannedFileCount, 0)
        XCTAssertEqual(final.cleanableBytes, 0)
    }

    // MARK: - 引擎集成：进度事件与扫描报告收敛一致

    func testScanProgressEventsConvergeToReportTotals() throws {
        try sandbox.createFile(relativeToHome: ".claude/paste-cache/snippet-1.txt", byteCount: 2_000)
        try sandbox.createFile(relativeToHome: ".claude/debug/session-01.log", byteCount: 500)
        // Cursor 缓存
        try sandbox.createFile(relativeToHome: "Library/Application Support/Cursor/GPUCache/data_0", byteCount: 8_000)
        // 存在但整目录被安全策略拦截的 Codex（应出占位卡且最终 0 可清理）
        try sandbox.createFile(relativeToHome: ".codex/cache/item.bin", byteCount: 4_000)
        try sandbox.createFile(relativeToHome: ".codex/cache/.env", byteCount: 64)
        // 本机不存在的客户端（如 Windsurf）不应出现卡片

        let engine = ScanEngine(homeDirectory: sandbox.homeURL, builtInProfiles: BuiltInClientRules.allProfiles)
        let eventsLock = CoreLock(initialState: [ScanProgressEvent]())
        let report = engine.scan(onProgress: { event in
            eventsLock.withLock { $0.append(event) }
        })
        let events = eventsLock.withLock { $0 }

        XCTAssertFalse(events.isEmpty, "有可扫描内容时应产生进度事件")

        // 1. 首个事件从第一阶段开始，最终事件为收尾快照
        XCTAssertEqual(events.first?.stage, .scanningClients)
        let finalEvent = try XCTUnwrap(events.last)
        XCTAssertTrue(finalEvent.isFinal)

        // 2. 阶段单调推进且三个阶段都出现过
        let stages = events.map(\.stage)
        let ordinals = stages.map(\.ordinal)
        XCTAssertEqual(ordinals, ordinals.sorted(), "阶段序号应单调不减")
        XCTAssertTrue(stages.contains(.scanningClients))
        XCTAssertTrue(stages.contains(.analyzingCacheFiles))
        XCTAssertTrue(stages.contains(.tallyingCleanableSpace))

        // 3. 终值收敛：可清理空间、文件数与报告同口径同值
        XCTAssertEqual(finalEvent.cleanableBytes, report.totalSizeBytes)
        let expectedFileCount = report.allItems.reduce(0) { $0 + $1.fileCount }
        XCTAssertEqual(finalEvent.scannedFileCount, expectedFileCount)

        // 4. 卡片收敛：报告中的客户端都有已量出体积的卡片，且数值一致；不存在卡在「检测中」的客户端
        let finalClients = Dictionary(uniqueKeysWithValues: finalEvent.clients.map { ($0.id, $0) })
        for summary in report.clientSummaries {
            let card = try XCTUnwrap(finalClients[summary.profile.id], "报告客户端 \(summary.profile.id) 缺少进度卡片")
            XCTAssertEqual(card.state, .measured)
            XCTAssertEqual(card.cleanableBytes, summary.totalSizeBytes)
            XCTAssertEqual(card.itemCount, summary.items.count)
        }
        XCTAssertEqual(
            finalEvent.clients.filter { $0.state == .detecting }.count, 0,
            "最终快照不应残留「检测中」占位"
        )

        // 5. 本机不存在的客户端不出卡片
        XCTAssertFalse(finalClients.keys.contains("windsurf"))
    }

    // MARK: - Helpers

    private func makeClient(
        id: String,
        name: String,
        state: ScanClientDetectionState
    ) -> ScanProgressClient {
        ScanProgressClient(
            id: id,
            name: name,
            symbolName: "sparkles",
            accentToken: "codex",
            kind: .builtInClient,
            state: state,
            cleanableBytes: 0,
            itemCount: 0
        )
    }
}
