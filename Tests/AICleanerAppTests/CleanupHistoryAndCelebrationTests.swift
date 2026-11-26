@testable import AICleanerApp
import AICleanerCore
import AppKit
import Charts
import Foundation
import SwiftUI
import XCTest

private struct CelebrationFixtureTrashPerformer: TrashPerforming {
    let directory: URL

    func trashItem(at url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class CleanupHistoryAndCelebrationTests: XCTestCase {
    // MARK: - 1. 庆祝粒子 triggerID 一次性消费与切页不重播

    @MainActor
    func testCleanupCelebrationConsumesTriggerOnceAndNeverReplaysAfterPageSwitches() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        try write(String(repeating: "A", count: 4_096), at: ".workbuddy/cache/first.bin", in: home)
        try write(String(repeating: "B", count: 8_192), at: ".workbuddy/logs/second.log", in: home)
        try write(String(repeating: "C", count: 2_048), at: ".claude/debug/keep.log", in: home)

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        // 尚未发生清理时不应触发庆祝动画
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: model.cleanupCelebrationID))
        XCTAssertFalse(model.consumeCleanupCelebration(for: model.cleanupCelebrationID))

        let firstItem = try XCTUnwrap(model.filteredItems.first(where: { $0.ruleID == "workbuddy-cache" }))
        let secondItem = try XCTUnwrap(model.filteredItems.first(where: { $0.clientID == "workbuddy" && $0.id != firstItem.id }))

        // 第一次清理成功
        model.toggleSelection(for: firstItem)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        let firstCelebrationID = model.cleanupCelebrationID
        XCTAssertTrue(model.shouldPlayCleanupCelebration(for: firstCelebrationID))
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: UUID()))
        XCTAssertFalse(model.consumeCleanupCelebration(for: UUID()))

        // 首次消费返回 true，随后同一 ID 永久不再重播
        XCTAssertTrue(model.consumeCleanupCelebration(for: firstCelebrationID))
        XCTAssertEqual(model.playedCleanupCelebrationID, firstCelebrationID)
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: firstCelebrationID))
        XCTAssertFalse(model.consumeCleanupCelebration(for: firstCelebrationID))

        // 在列表页 / 清理记录 / 已排除 / 单个客户端间反复切换后，同一清理结果绝不重播
        model.sidebarSelection = .history
        model.sidebarSelection = .allClients
        model.sidebarSelection = .excluded
        model.sidebarSelection = .client("workbuddy")
        model.sidebarSelection = .allClients

        XCTAssertNotNil(model.lastCleanupResult)
        XCTAssertEqual(model.cleanupCelebrationID, firstCelebrationID)
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: firstCelebrationID))
        XCTAssertFalse(model.consumeCleanupCelebration(for: firstCelebrationID))

        // 触发第二次全新清理后，新 triggerID 允许播放一次，随后同样锁定不重播
        model.toggleSelection(for: secondItem)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.cleanupCelebrationID != firstCelebrationID }

        let secondCelebrationID = model.cleanupCelebrationID
        XCTAssertNotEqual(secondCelebrationID, firstCelebrationID)
        XCTAssertTrue(model.shouldPlayCleanupCelebration(for: secondCelebrationID))
        XCTAssertTrue(model.consumeCleanupCelebration(for: secondCelebrationID))
        XCTAssertFalse(model.consumeCleanupCelebration(for: secondCelebrationID))

        // 含失败或受保护跳过项的非纯成功结果不应触发庆祝粒子
        let failedResult = CleanupResult(
            trashedItems: [TrashedItemRecord(item: firstItem, resultingTrashURL: nil)],
            skippedProtectedItems: [],
            failedItems: [CleanupFailure(item: secondItem, reason: "权限不足")],
            freedBytes: firstItem.sizeBytes
        )
        let partialCelebrationID = UUID()
        model.cleanupCelebrationID = partialCelebrationID
        model.lastCleanupResult = failedResult
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: partialCelebrationID))
        XCTAssertFalse(model.consumeCleanupCelebration(for: partialCelebrationID))
    }

    // MARK: - 2. 清理完成胶囊在粒子激活态与结束态下布局尺寸一致（不撑高父容器）

    @MainActor
    func testCleanupCelebrationPillKeepsCompactSizeDuringAndAfterSparkleBurst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let sampleItem = CleanableItem(
            clientID: "cursor",
            clientName: "Cursor",
            ruleID: "cursor-cache",
            displayName: "Cache",
            fileName: "Cache",
            url: home.appendingPathComponent("Cache"),
            category: .cache,
            recommendation: .recommended,
            safetyNote: "缓存文件",
            sizeBytes: 45_717_913,
            fileCount: 13,
            modifiedAt: Date(),
            isDirectory: true,
            isCustom: false
        )

        let model = makeViewModel(home: home)
        model.cleanupCelebrationID = UUID()
        model.lastCleanupResult = CleanupResult(
            trashedItems: [TrashedItemRecord(item: sampleItem, resultingTrashURL: nil)],
            skippedProtectedItems: [],
            failedItems: [],
            freedBytes: sampleItem.sizeBytes
        )

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let activeHost = NSHostingView(
                rootView: BottomActionBar(
                    viewModel: model,
                    isVisible: true,
                    initialCelebrationBurstActive: true
                )
            )
            activeHost.appearance = NSAppearance(named: appearanceName)
            activeHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            activeHost.layoutSubtreeIfNeeded()
            let activeSize = activeHost.fittingSize

            let finishedHost = NSHostingView(
                rootView: BottomActionBar(
                    viewModel: model,
                    isVisible: true,
                    initialCelebrationBurstActive: false
                )
            )
            finishedHost.appearance = NSAppearance(named: appearanceName)
            finishedHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            finishedHost.layoutSubtreeIfNeeded()
            let finishedSize = finishedHost.fittingSize

            // 粒子激活时绝不可像旧 ZStack 那样被 Canvas 撑满整窗高度（~700pt）
            XCTAssertGreaterThan(activeSize.width, 180)
            XCTAssertGreaterThan(activeSize.height, 28)
            XCTAssertLessThan(activeSize.height, 90, "SparkleBurstOverlay must remain constrained to pill bounds")
            XCTAssertEqual(activeSize.width, finishedSize.width, accuracy: 0.5)
            XCTAssertEqual(activeSize.height, finishedSize.height, accuracy: 0.5)
        }
    }

    @MainActor
    func testSparkleBurstOverlayTaskConsumesOnceAndSkipsReplayOnRemount() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let sampleItem = CleanableItem(
            clientID: "cursor",
            clientName: "Cursor",
            ruleID: "cursor-cache",
            displayName: "Cache",
            fileName: "Cache",
            url: home.appendingPathComponent("Cache"),
            category: .cache,
            recommendation: .recommended,
            safetyNote: "缓存文件",
            sizeBytes: 12_345_678,
            fileCount: 3,
            modifiedAt: Date(),
            isDirectory: true,
            isCustom: false
        )

        let model = makeViewModel(home: home)
        let eventID = UUID()
        model.cleanupCelebrationID = eventID
        model.lastCleanupResult = CleanupResult(
            trashedItems: [TrashedItemRecord(item: sampleItem, resultingTrashURL: nil)],
            skippedProtectedItems: [],
            failedItems: [],
            freedBytes: sampleItem.sizeBytes
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        // 验证真实 BottomActionBar.overlay 中的 SparkleBurstOverlay 会自动消费 triggerID 一次
        let barHost = NSHostingView(rootView: BottomActionBar(viewModel: model, isVisible: true))
        barHost.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = barHost
        barHost.layoutSubtreeIfNeeded()
        try await waitUntil { model.playedCleanupCelebrationID == eventID }
        XCTAssertFalse(model.shouldPlayCleanupCelebration(for: eventID))

        // 模拟切页后视图重建：同一个 triggerID 绝不再消费/重播
        var replayConsumedCount = 0
        let secondOverlay = SparkleBurstOverlay(triggerID: eventID, isVisible: true) { id in
            let allowed = model.consumeCleanupCelebration(for: id)
            if allowed { replayConsumedCount += 1 }
            return allowed
        }
        let secondHost = NSHostingView(rootView: secondOverlay.frame(width: 300, height: 44))
        window.contentView = secondHost
        secondHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(replayConsumedCount, 0)
    }

    // MARK: - 3. 单日柱状图中心坐标与悬停命中吸附计算

    func testDailyBarChartAnchorDateAndHoverSnappingAcrossBarEdgesAndDayBoundaries() throws {
        var gmt8 = Calendar(identifier: .gregorian)
        gmt8.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))

        let baseDay = try XCTUnwrap(gmt8.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 0, minute: 0)))
        let points: [CleanupTrendPoint] = (0..<7).map { offset in
            let day = gmt8.date(byAdding: .day, value: offset, to: baseDay)!
            return CleanupTrendPoint(
                date: day,
                dailyFreedBytes: Int64((offset + 1) * 10_000_000),
                cumulativeFreedBytes: Int64((offset + 1) * 10_000_000),
                cleanupRuns: 1,
                trashedCount: 2
            )
        }

        // 1) anchorDate：cumulative 在 00:00，daily 在自然日水平正中心 12:00
        let nov22 = points[3].date
        XCTAssertEqual(
            CleanupHistoryChartGeometry.anchorDate(for: nov22, mode: .cumulative, calendar: gmt8),
            nov22
        )
        let expectedCenter = try XCTUnwrap(
            gmt8.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12, minute: 0))
        )
        XCTAssertEqual(
            CleanupHistoryChartGeometry.anchorDate(for: nov22, mode: .daily, calendar: gmt8),
            expectedCenter
        )

        // 2) 夏令时 23 小时与 25 小时日期仍严格取 [dayStart, nextDayStart) 中点
        var laCal = Calendar(identifier: .gregorian)
        laCal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let springForwardDay = try XCTUnwrap(laCal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        let springNext = try XCTUnwrap(laCal.date(byAdding: .day, value: 1, to: springForwardDay))
        let springCenter = CleanupHistoryChartGeometry.anchorDate(for: springForwardDay, mode: .daily, calendar: laCal)
        XCTAssertEqual(
            springCenter.timeIntervalSince(springForwardDay),
            springNext.timeIntervalSince(springForwardDay) * 0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(springNext.timeIntervalSince(springForwardDay), 23 * 3600, accuracy: 0.001)

        let fallBackDay = try XCTUnwrap(laCal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0)))
        let fallNext = try XCTUnwrap(laCal.date(byAdding: .day, value: 1, to: fallBackDay))
        let fallCenter = CleanupHistoryChartGeometry.anchorDate(for: fallBackDay, mode: .daily, calendar: laCal)
        XCTAssertEqual(
            fallCenter.timeIntervalSince(fallBackDay),
            fallNext.timeIntervalSince(fallBackDay) * 0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(fallNext.timeIntervalSince(fallBackDay), 25 * 3600, accuracy: 0.001)

        // 3) 单日模式悬停吸附：覆盖柱子左边缘、主体左侧、正中心、主体右侧、右边缘
        let nov22Samples: [Date] = [
            nov22, // 00:00:00（当天左边界）
            nov22.addingTimeInterval(1), // 00:00:01（柱子左边缘外侧）
            nov22.addingTimeInterval(3 * 3600), // 03:00（柱子左边缘内侧）
            nov22.addingTimeInterval(12 * 3600), // 12:00（柱子正中心）
            nov22.addingTimeInterval(18 * 3600), // 18:00（柱子右半区，旧算法此处会错漂到次日）
            nov22.addingTimeInterval(23 * 3600 + 59 * 60 + 59) // 23:59:59（右边缘）
        ]
        for sample in nov22Samples {
            let hit = CleanupHistoryChartGeometry.nearestPoint(
                to: sample,
                in: points,
                mode: .daily,
                usesWeeklyBuckets: false,
                calendar: gmt8
            )
            XCTAssertEqual(hit?.date, nov22, "Sample \(sample) should snap to 11-22")
        }

        // 4) 跨日 00:00 边界应精准切到次日
        let nov23 = points[4].date
        let crossDayHit = CleanupHistoryChartGeometry.nearestPoint(
            to: nov23,
            in: points,
            mode: .daily,
            usesWeeklyBuckets: false,
            calendar: gmt8
        )
        XCTAssertEqual(crossDayHit?.date, nov23)

        // 5) 首尾柱越界钳制（左端之前钳制至首日，末日 24:00 处钳制至末日）
        let beforeFirst = points[0].date.addingTimeInterval(-60)
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(to: beforeFirst, in: points, mode: .daily, calendar: gmt8)?.date,
            points.first?.date
        )
        let afterLastEnd = try XCTUnwrap(gmt8.date(byAdding: .day, value: 1, to: points[6].date))
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(to: afterLastEnd, in: points, mode: .daily, calendar: gmt8)?.date,
            points.last?.date
        )

        // 6) 按周分桶柱状图悬停吸附仍居中对齐各周柱子
        let weeklyPoints: [CleanupTrendPoint] = (0..<4).map { idx in
            let date = gmt8.date(byAdding: .day, value: idx * 7, to: baseDay)!
            return CleanupTrendPoint(
                date: date,
                dailyFreedBytes: Int64((idx + 1) * 5_000_000),
                cumulativeFreedBytes: Int64((idx + 1) * 5_000_000),
                cleanupRuns: 1,
                trashedCount: 1
            )
        }
        let week1RightEdge = weeklyPoints[1].date.addingTimeInterval(22 * 3600)
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(
                to: week1RightEdge,
                in: weeklyPoints,
                mode: .daily,
                usesWeeklyBuckets: true,
                calendar: gmt8
            )?.date,
            weeklyPoints[1].date
        )

        // 7) 累计折线/面积图模式无回归：按 00:00 点位就近吸附，正中 12:00 优先较新一天
        let cumulativeBeforeMid = nov22.addingTimeInterval(11 * 3600 + 59 * 60)
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(to: cumulativeBeforeMid, in: points, mode: .cumulative, calendar: gmt8)?.date,
            nov22
        )
        let cumulativeExactMid = nov22.addingTimeInterval(12 * 3600)
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(to: cumulativeExactMid, in: points, mode: .cumulative, calendar: gmt8)?.date,
            nov23
        )
        let cumulativeAfterMid = nov22.addingTimeInterval(12 * 3600 + 60)
        XCTAssertEqual(
            CleanupHistoryChartGeometry.nearestPoint(to: cumulativeAfterMid, in: points, mode: .cumulative, calendar: gmt8)?.date,
            nov23
        )
    }

    // MARK: - 4. 单日柱状图实际渲染像素居中核验（左端、中间、右端柱子）

    @MainActor
    func testRenderedDailyBarRuleAndPointMarksCenterExactlyOnBar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let baseDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 0)))
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: baseDay)! }

        for targetIndex in [0, 3, 6] {
            let target = days[targetIndex]
            let activeX = CleanupHistoryChartGeometry.anchorDate(for: target, mode: .daily, calendar: calendar)

            let chart = Chart {
                ForEach(days, id: \.self) { day in
                    BarMark(
                        x: .value("日期", day, unit: .day, calendar: calendar),
                        y: .value("已移入废纸篓", day == target ? 100 : 0)
                    )
                    .foregroundStyle(Color.blue)
                }

                RuleMark(x: .value("日期", activeX))
                    .foregroundStyle(Color.red)

                PointMark(
                    x: .value("日期", activeX),
                    y: .value("已移入废纸篓", 100)
                )
                .symbolSize(60)
                .foregroundStyle(Color.green)
            }
            .chartYScale(domain: 0...120)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 700, height: 200)
            .background(Color.white)

            let host = NSHostingView(rootView: chart)
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)

            var barXs: [Int] = []
            var ruleXs: [Int] = []
            var pointXs: [Int] = []

            for x in 0..<rep.pixelsWide {
                if let barPixel = rep.colorAt(x: x, y: rep.pixelsHigh * 3 / 4),
                   barPixel.blueComponent > 0.7 && barPixel.redComponent < 0.3 {
                    barXs.append(x)
                }
                if let rulePixel = rep.colorAt(x: x, y: 5),
                   rulePixel.redComponent > 0.7 && rulePixel.blueComponent < 0.3 {
                    ruleXs.append(x)
                }
                for y in 0..<rep.pixelsHigh {
                    if let dotPixel = rep.colorAt(x: x, y: y),
                       dotPixel.greenComponent > 0.6 && dotPixel.redComponent < 0.3 && dotPixel.blueComponent < 0.4 {
                        pointXs.append(x)
                        break
                    }
                }
            }

            let barMin = try XCTUnwrap(barXs.min())
            let barMax = try XCTUnwrap(barXs.max())
            let ruleMin = try XCTUnwrap(ruleXs.min())
            let ruleMax = try XCTUnwrap(ruleXs.max())
            let pointMin = try XCTUnwrap(pointXs.min())
            let pointMax = try XCTUnwrap(pointXs.max())

            let barCenter = Double(barMin + barMax) * 0.5
            let ruleCenter = Double(ruleMin + ruleMax) * 0.5
            let pointCenter = Double(pointMin + pointMax) * 0.5

            XCTAssertEqual(ruleCenter, barCenter, accuracy: 1.5, "RuleMark must center on bar \(targetIndex)")
            XCTAssertEqual(pointCenter, barCenter, accuracy: 1.5, "PointMark must center on bar \(targetIndex)")
        }
    }

    @MainActor
    func testHistoryTrendChartCardLayoutsCleanlyInDailyAndCumulativeModes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date()
        let record = CleanupHistoryRecord(
            timestamp: now,
            freedBytes: 64_000_000,
            trashedCount: 4,
            clientBreakdown: [
                ClientCleanupDelta(clientID: "cursor", clientName: "Cursor", freedBytes: 64_000_000, itemCount: 4)
            ],
            sampleItemNames: ["Cache"]
        )
        let model = makeViewModel(home: home)
        model.historyRecords = [record]
        let hoveredDate = model.historySummary.points.last?.date

        for mode in CleanupTrendMetricMode.allCases {
            model.historyMetricMode = mode
            let host = NSHostingView(
                rootView: HistoryTrendChartCard(
                    viewModel: model,
                    summary: model.historySummary,
                    chartRevealed: true,
                    initialHoveredPointDate: hoveredDate
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 320)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
            XCTAssertGreaterThan(host.fittingSize.height, 240)
        }
    }

    // MARK: - 5. 「清理记录」统一文案校验

    func testCleanupHistoryCopyUsesUnifiedCleanupRecordsTerminology() {
        XCTAssertEqual(CleanupHistoryCopy.title, "清理记录")
        XCTAssertEqual(CleanupHistoryCopy.openActionTitle, "查看清理记录")
        XCTAssertEqual(CleanupHistoryCopy.clearRecordsMenuTitle, "清空清理记录…")
        XCTAssertEqual(CleanupHistoryCopy.clearRecordsAlertTitle, "清空清理记录？")
        XCTAssertEqual(CleanupHistoryCopy.clearRecordsConfirmTitle, "清空清理记录")
        XCTAssertEqual(CleanupHistoryCopy.clearOptionsHelp, "清理记录选项")
        XCTAssertEqual(CleanupHistoryCopy.deleteSingleRecordHelp, "删除这条清理记录（保留废纸篓文件）")
        XCTAssertEqual(CleanupHistoryCopy.emptyStateTitle, "暂无清理记录")
        XCTAssertEqual(CleanupHistoryCopy.cumulativeCleanedTitle, "累计已清理")
        XCTAssertEqual(CleanupHistoryCopy.clientRankingTitle, "客户端清理排行")
        XCTAssertEqual(CleanupHistoryCopy.recentRecordsTitle, "最近清理记录")
        XCTAssertTrue(CleanupHistoryCopy.clearRecordsAlertMessage.contains("清理记录"))
        XCTAssertTrue(CleanupHistoryCopy.clearRecordsAlertMessage.contains("废纸篓中的文件会保留"))

        let allCopy = [
            CleanupHistoryCopy.title,
            CleanupHistoryCopy.openActionTitle,
            CleanupHistoryCopy.clearRecordsMenuTitle,
            CleanupHistoryCopy.clearRecordsAlertTitle,
            CleanupHistoryCopy.clearRecordsConfirmTitle,
            CleanupHistoryCopy.clearRecordsAlertMessage,
            CleanupHistoryCopy.clearOptionsHelp,
            CleanupHistoryCopy.deleteSingleRecordHelp,
            CleanupHistoryCopy.emptyStateTitle
        ]
        for text in allCopy {
            XCTAssertFalse(text.contains("趋势"), "Copy should not retain legacy '趋势' wording: \(text)")
        }
    }

    func testRecentHistoryFitsOnOnePageWithFiveOrFewerRecords() {
        let records = historyRecords(count: 5)
        for count in [0, 4, 5] {
            let expected = Array(records.prefix(count))
            let page = CleanupHistoryRecentRecordsPage(records: expected, requestedNumber: 1)

            XCTAssertEqual(page.count, 1)
            XCTAssertEqual(Array(page.records), expected)
        }
    }

    func testRecentHistoryPagesKeepAllFourteenRecordsInOrder() {
        let records = historyRecords(count: 14)
        let pages = (1...3).map { CleanupHistoryRecentRecordsPage(records: records, requestedNumber: $0) }

        XCTAssertEqual(pages.map(\.count), [3, 3, 3])
        XCTAssertEqual(pages.map { $0.records.count }, [5, 5, 4])
        XCTAssertEqual(pages.flatMap(\.records), records)
    }

    func testRecentHistoryPageClampsAfterDeletingOnlyRecordOnLastPage() {
        var records = historyRecords(count: 21)
        let lastPage = CleanupHistoryRecentRecordsPage(records: records, requestedNumber: 5)
        XCTAssertEqual(lastPage.records.map(\.id), [records[20].id])

        records.removeLast()
        let currentPage = CleanupHistoryRecentRecordsPage(records: records, requestedNumber: lastPage.number)
        XCTAssertEqual(currentPage.number, 4)
        XCTAssertEqual(currentPage.count, 4)
        XCTAssertEqual(Array(currentPage.records), Array(records[15...19]))
    }

    // MARK: - Helpers

    private func historyRecords(count: Int) -> [CleanupHistoryRecord] {
        (0..<count).map { index in
            CleanupHistoryRecord(
                timestamp: Date(timeIntervalSince1970: -Double(index)),
                freedBytes: 1_000,
                trashedCount: 1
            )
        }
    }

    @MainActor
    private func makeViewModel(home: URL) -> CleanerViewModel {
        let guardInstance = SafetyGuard(homeDirectory: home)
        return CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: CustomDirectoryStore(
                storageURL: home.appendingPathComponent("custom.json"),
                safetyGuard: guardInstance
            ),
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: home.appendingPathComponent("excluded-items.json")),
            trashPerformer: CelebrationFixtureTrashPerformer(directory: home.appendingPathComponent(".fixture-trash")),
            scanEngine: ScanEngine(homeDirectory: home, safetyGuard: guardInstance)
        )
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func write(_ text: String, at path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
