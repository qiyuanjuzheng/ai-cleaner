import AICleanerCore
import Foundation
import XCTest

final class CleanupHistoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AICleanerHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRecordPersistDeleteAndClearHistoryStore() throws {
        let storageURL = tempDir.appendingPathComponent("cleanup-history.json")
        let store = CleanupHistoryStore(storageURL: storageURL)

        XCTAssertTrue(store.load().isEmpty)

        // 空清理结果不应写入历史
        let emptyResult = CleanupResult(
            trashedItems: [],
            skippedProtectedItems: [],
            failedItems: [],
            freedBytes: 0
        )
        XCTAssertNil(try store.record(result: emptyResult))
        XCTAssertTrue(store.load().isEmpty)

        // 构造真实清理结果（跨 2 个客户端）
        let cursorItem = makeItem(
            clientID: "cursor",
            clientName: "Cursor",
            displayName: "应用网络缓存 (Cache)",
            category: .cache,
            bytes: 300_000_000
        )
        let workbuddyItem = makeItem(
            clientID: "workbuddy",
            clientName: "WorkBuddy",
            displayName: "执行追踪记录 (traces)",
            category: .logs,
            bytes: 120_000_000
        )

        let t1 = Date(timeIntervalSince1970: 1_760_000_000)
        let result = CleanupResult(
            trashedItems: [
                TrashedItemRecord(item: cursorItem, resultingTrashURL: nil),
                TrashedItemRecord(item: workbuddyItem, resultingTrashURL: nil)
            ],
            skippedProtectedItems: [],
            failedItems: [],
            freedBytes: 420_000_000,
            completedAt: t1
        )

        let saved = try XCTUnwrap(try store.record(result: result))
        XCTAssertEqual(saved.freedBytes, 420_000_000)
        XCTAssertEqual(saved.trashedCount, 2)
        XCTAssertEqual(saved.clientBreakdown.count, 2)
        XCTAssertEqual(saved.clientBreakdown.first?.clientID, "cursor")
        XCTAssertEqual(saved.sampleItemNames, ["应用网络缓存 (Cache)", "执行追踪记录 (traces)"])

        // 重新从磁盘读取验证持久化一致
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, saved.id)
        XCTAssertEqual(loaded.first?.freedBytes, 420_000_000)

        // 删除单条与清空历史
        try store.delete(id: saved.id)
        XCTAssertTrue(store.load().isEmpty)

        try store.append(saved)
        XCTAssertEqual(store.load().count, 1)
        try store.clearAll()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAnalyticsPreservesPreWindowCumulativeBaselineAndComputesClientShare() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15, minute: 0))!
        let dayMinus20 = calendar.date(byAdding: .day, value: -20, to: now)!
        let dayMinus3 = calendar.date(byAdding: .day, value: -3, to: now)!
        let dayToday = now

        let rOld = CleanupHistoryRecord(
            timestamp: dayMinus20,
            freedBytes: 2_000_000_000,
            trashedCount: 10,
            clientBreakdown: [
                ClientCleanupDelta(clientID: "cursor", clientName: "Cursor", freedBytes: 2_000_000_000, itemCount: 10)
            ]
        )
        let rRecent1 = CleanupHistoryRecord(
            timestamp: dayMinus3,
            freedBytes: 300_000_000,
            trashedCount: 4,
            clientBreakdown: [
                ClientCleanupDelta(clientID: "workbuddy", clientName: "WorkBuddy", freedBytes: 300_000_000, itemCount: 4)
            ]
        )
        let rRecent2 = CleanupHistoryRecord(
            timestamp: dayToday,
            freedBytes: 700_000_000,
            trashedCount: 6,
            clientBreakdown: [
                ClientCleanupDelta(clientID: "cursor", clientName: "Cursor", freedBytes: 500_000_000, itemCount: 4),
                ClientCleanupDelta(clientID: "workbuddy", clientName: "WorkBuddy", freedBytes: 200_000_000, itemCount: 2)
            ]
        )

        // 近 7 天窗口应保留窗口前 2GB 基线，使累计曲线连续爬升至 3GB
        let summary7 = CleanupHistoryAnalytics.summarize(
            records: [rOld, rRecent1, rRecent2],
            range: .days7,
            referenceDate: now,
            calendar: calendar
        )

        XCTAssertEqual(summary7.totalFreedBytes, 3_000_000_000)
        XCTAssertEqual(summary7.rangeFreedBytes, 1_000_000_000)
        XCTAssertEqual(summary7.totalRuns, 3)
        XCTAssertEqual(summary7.rangeRuns, 2)
        XCTAssertEqual(summary7.largestSingleRunBytes, 2_000_000_000)
        XCTAssertEqual(summary7.averagePerRunBytes, 1_000_000_000)
        XCTAssertEqual(summary7.points.count, 7)

        // 第 1 天累计应包含窗口前 2GB 基线，最后一天累计为 3GB
        XCTAssertEqual(summary7.points.first?.cumulativeFreedBytes, 2_000_000_000)
        XCTAssertEqual(summary7.points.first?.dailyFreedBytes, 0)
        XCTAssertEqual(summary7.points.last?.dailyFreedBytes, 700_000_000)
        XCTAssertEqual(summary7.points.last?.cumulativeFreedBytes, 3_000_000_000)

        // 7 天窗口内 Cursor = 500MB, WorkBuddy = 500MB，各占 50%
        XCTAssertEqual(summary7.topClients.count, 2)
        let totalShare = summary7.topClients.reduce(0.0) { $0 + $1.share }
        XCTAssertEqual(totalShare, 1.0, accuracy: 0.001)

        // 全部时间窗口应覆盖全部 21 天且累计终点一致
        let summaryAll = CleanupHistoryAnalytics.summarize(
            records: [rOld, rRecent1, rRecent2],
            range: .allTime,
            referenceDate: now,
            calendar: calendar
        )
        XCTAssertEqual(summaryAll.points.count, 21)
        XCTAssertEqual(summaryAll.points.first?.dailyFreedBytes, 2_000_000_000)
        XCTAssertEqual(summaryAll.points.last?.cumulativeFreedBytes, 3_000_000_000)
        XCTAssertEqual(summaryAll.topClients.first?.clientID, "cursor")
        XCTAssertEqual(summaryAll.topClients.first?.totalFreedBytes, 2_500_000_000)
    }

    func testRecentRecordsMatchTheSelectedRangeInNewestFirstOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let newest = CleanupHistoryRecord(timestamp: today, freedBytes: 10, trashedCount: 1)
        let firstDayInRange = CleanupHistoryRecord(
            timestamp: today.addingTimeInterval(-6 * 86_400), freedBytes: 20, trashedCount: 1
        )
        let older = CleanupHistoryRecord(
            timestamp: firstDayInRange.timestamp.addingTimeInterval(-1), freedBytes: 30, trashedCount: 1
        )
        let records = [firstDayInRange, older, newest]

        let week = CleanupHistoryAnalytics.summarize(
            records: records, range: .days7, referenceDate: today, calendar: calendar
        )
        XCTAssertEqual(week.recentRecords, [newest, firstDayInRange])
        XCTAssertEqual(week.recentRecords.count, week.rangeRuns)

        let allTime = CleanupHistoryAnalytics.summarize(
            records: records, range: .allTime, referenceDate: today, calendar: calendar
        )
        XCTAssertEqual(allTime.recentRecords, [newest, firstDayInRange, older])
    }

    func testAnalyticsEmptyHistoryProducesCleanZeroBaselinePoints() {
        let now = Date()
        let summary = CleanupHistoryAnalytics.summarize(records: [], range: .days7, referenceDate: now)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.totalFreedBytes, 0)
        XCTAssertEqual(summary.points.count, 7)
        XCTAssertTrue(summary.points.allSatisfy { $0.dailyFreedBytes == 0 && $0.cumulativeFreedBytes == 0 })
    }

    // MARK: - Helper

    private func makeItem(
        clientID: String,
        clientName: String,
        displayName: String,
        category: ScanCategory,
        bytes: Int64
    ) -> CleanableItem {
        CleanableItem(
            clientID: clientID,
            clientName: clientName,
            ruleID: "test-rule-\(displayName)",
            displayName: displayName,
            fileName: displayName,
            url: tempDir.appendingPathComponent(displayName),
            category: category,
            recommendation: .recommended,
            safetyNote: "测试条目",
            sizeBytes: bytes,
            fileCount: 1,
            modifiedAt: Date(),
            isDirectory: false,
            isCustom: false
        )
    }
}
