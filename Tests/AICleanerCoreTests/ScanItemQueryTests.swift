import Foundation
import XCTest
@testable import AICleanerCore

final class ScanItemQueryTests: XCTestCase {
    func testAgeFilterExcludesProtectedItemsAndTheCutoffItself() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let oldSession = makeItem("old", bytes: 30, date: cutoff.addingTimeInterval(-1), category: .sessions)
        let atCutoff = makeItem("boundary", bytes: 20, date: cutoff, category: .sessions)
        let protected = makeItem("protected", bytes: 100, date: oldSession.modifiedAt,
                                 category: .sessions, recommendation: .notRecommended)
        let filter = ScanItemFilter(category: .sessions, age: .olderThan7Days)

        XCTAssertEqual(filter.applying(to: [atCutoff, oldSession, protected], now: now, calendar: calendar).map(\.id),
                       [oldSession.id])
    }

    func testSearchMatchesSessionTitleAndProjectName() {
        let session = makeItem("5dc90fbb-5bea-4ad0-8362-24c8fa7c7276", bytes: 20, category: .sessions,
                               title: "Review Parser", project: "Desktop Core")
        let other = makeItem("unrelated", bytes: 10, category: .sessions)
        XCTAssertEqual(ScanItemFilter(search: "  review PARSER  ").applying(to: [other, session]).map(\.id), [session.id])
        XCTAssertEqual(ScanItemFilter(search: "desktop CORE").applying(to: [other, session]).map(\.id), [session.id])
    }

    func testSortAndGroupsPreserveNaturalOrderAndByteTotals() {
        let log10 = makeItem("log10", bytes: 30)
        let log2 = makeItem("Log2", bytes: 20)
        let risk = makeItem("protected", bytes: 90, recommendation: .notRecommended)
        let sorted = ScanItemSort.nameAscending.sorting([log10, risk, log2])
        let buckets = ScanItemBuckets(items: sorted)

        XCTAssertEqual(buckets.sections.map(\.recommendation), [.recommended, .notRecommended])
        XCTAssertEqual(buckets.sections[0].items.map(\.id), [log2.id, log10.id])
        XCTAssertEqual(buckets.sections.map(\.totalBytes), [50, 90])
        XCTAssertEqual(buckets.maximumBytes, 90)
    }

    func testBulkActionsSkipItemsThatRequireIndividualSelection() {
        let oldSession = makeItem("old session", bytes: 40, category: .sessions, recommendation: .reviewSuggested)
        let recentTemp = makeItem("recent temp", bytes: 30, category: .temporary,
                                  recommendation: .reviewSuggested, individual: true)
        let unattributed = makeItem("unknown temp", bytes: 20, category: .temporary,
                                     recommendation: .reviewSuggested, individual: true)
        let risk = makeItem("plugin", bytes: 60, recommendation: .notRecommended)
        let items = [oldSession, recentTemp, unattributed, risk]
        let selected = ScanItemSelection.selecting(items, from: [risk.id])

        XCTAssertEqual(selected, [oldSession.id, risk.id])
        XCTAssertEqual(ScanItemSelection.inverting(items, from: selected), [risk.id])
        XCTAssertEqual(ScanItemSelection.fullySelectedSections(in: items, selectedIDs: selected), [.reviewSuggested])
        XCTAssertEqual(ScanItemSelection.deselecting(items, from: selected, recommendation: .reviewSuggested), [risk.id])
    }

    func testManualSelectionAndSummaryRespectHardProtection() {
        let regular = makeItem("cache", bytes: 50)
        let plugin = makeItem("plugin", bytes: 20, recommendation: .notRecommended)
        let protected = makeItem("credentials", bytes: 200, protection: "locked")
        let items = [regular, plugin, protected]
        let summary = CleanupSelectionSummary(
            selectedIDs: [regular.id, plugin.id, protected.id, "stale"],
            itemsByID: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        )

        XCTAssertEqual(ScanItemSelection.toggle(regular, isSelected: false), .select)
        XCTAssertEqual(ScanItemSelection.toggle(plugin, isSelected: false), .confirmRisk)
        XCTAssertEqual(ScanItemSelection.toggle(plugin, isSelected: true), .deselect)
        XCTAssertEqual(ScanItemSelection.toggle(protected, isSelected: false), .blocked)
        XCTAssertEqual(summary.items.map(\.id), [plugin.id, regular.id])
        XCTAssertEqual(summary.totalBytes, 70)
        XCTAssertEqual(summary.riskBytes, 20)
        XCTAssertEqual(summary.clientGroups.map(\.totalBytes), [70])
    }

    private func makeItem(
        _ name: String,
        bytes: Int64,
        date: Date = Date(timeIntervalSince1970: 1_790_000_000),
        category: ScanCategory = .cache,
        recommendation: CleanupRecommendation = .recommended,
        individual: Bool = false,
        protection: String? = nil,
        title: String? = nil,
        project: String? = nil
    ) -> CleanableItem {
        CleanableItem(
            clientID: "codex", clientName: "Codex", ruleID: "fixtures", displayName: name,
            fileName: name, url: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            category: category, recommendation: recommendation, safetyNote: "", sizeBytes: bytes,
            fileCount: 1, modifiedAt: date, isDirectory: false, isCustom: false,
            hardProtectionReason: protection, requiresIndividualSelection: individual,
            sessionTitle: title, sessionProjectName: project
        )
    }
}
