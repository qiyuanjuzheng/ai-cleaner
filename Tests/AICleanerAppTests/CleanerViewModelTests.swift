@testable import AICleanerApp
import AICleanerCore
import AppKit
import Foundation
import SwiftUI
import XCTest

private struct FixtureTrashPerformer: TrashPerforming {
    let directory: URL

    func trashItem(at url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class CleanerViewModelTests: XCTestCase {
    @MainActor
    func testSessionRowsShowSavedTitlesAndKeepReadableFallbacks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = ".claude/projects/-Users-fixture-demo"
        let longTitle = String(repeating: "合成会话标题 ", count: 32) + "结尾"
        let longRecord = #"{"type":"custom-title","customTitle":""# + longTitle + #""}"#
        try write(
            [
                #"{"type":"user","cwd":"/Users/fixture/demo","message":{"role":"user","content":"原始提问"}}"#,
                #"{"type":"custom-title","customTitle":"旧标题"}"#,
                String(repeating: #"{"type":"assistant"}"# + "\n", count: 4_000),
                longRecord,
                #"{"type":"ai-title","aiTitle":"自动生成标题"}"#
            ].joined(separator: "\n"),
            at: "\(project)/titled.jsonl", in: home, modifiedAt: Date().addingTimeInterval(-20 * 86_400)
        )
        try write(
            """
            {"type":"user","message":{"role":"user","content":"回退到首条提问"}}
            {"type":"custom-title","customTitle":"   "}
            """,
            at: "\(project)/fallback.jsonl", in: home
        )
        try write(
            """
            {"type":"user","message":{"role":"user","content":"旧版首条提问"}}
            {"type":"summary","summary":"客户端保存的展示名称"}
            """,
            at: "\(project)/summary.jsonl", in: home
        )
        try write(
            #"{"type":"session","cwd":"/Users/fixture/pi-project"}"# + "\n"
                + #"{"type":"session_info","name":"Pi 保存的名称"}"#,
            at: ".pi/agent/sessions/--Users-fixture-pi-project--/named.jsonl", in: home
        )
        let unnamed = "7a0760df-cdb2-46b9-b6fd-ba88bdd62303.jsonl"
        try write("invalid record", at: ".claude/transcripts/\(unnamed)", in: home)
        try write(
            #"{"type":"ai-title","aiTitle":"转录归档的标题"}"#,
            at: ".claude/transcripts/archived.jsonl", in: home
        )

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        let rows = Dictionary(uniqueKeysWithValues: model.displayedRows.compactMap { entry -> (String, ItemDisplayRow)? in
            if case let .item(row) = entry { return (row.item.fileName, row) }
            return nil
        })
        let titled = try XCTUnwrap(rows["titled.jsonl"])
        XCTAssertEqual(titled.title, longTitle)
        XCTAssertTrue(titled.detailText.contains("demo"))
        XCTAssertTrue(titled.detailText.contains(titled.item.safetyNote))
        XCTAssertFalse(titled.dateText.isEmpty)
        XCTAssertFalse(titled.sizeText.isEmpty)
        XCTAssertEqual(rows["fallback.jsonl"]?.title, "demo · 回退到首条提问")
        XCTAssertEqual(rows["summary.jsonl"]?.title, "demo · 客户端保存的展示名称")
        XCTAssertEqual(rows["named.jsonl"]?.title, "Pi 保存的名称")
        XCTAssertEqual(rows[unnamed]?.title, "未命名会话")
        XCTAssertEqual(rows["archived.jsonl"]?.title, "转录归档的标题")
        XCTAssertEqual(rows["archived.jsonl"]?.item.isBulkSelectable, false)

        model.searchText = "标题 结尾"
        XCTAssertEqual(model.filteredItems.map(\.id), [titled.id])
    }

    @MainActor
    func testOldAndArchivedSessionsRequireIndividualSelection() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let oldDate = Date().addingTimeInterval(-20 * 86_400)
        try write(
            #"{"type":"user","message":{"role":"user","content":"Review the fixture branch"}}"#,
            at: ".claude/projects/-Users-fixture-demo/old.jsonl", in: home, modifiedAt: oldDate
        )
        try write("compressed fixture", at: ".codex/sessions/2026/11/01/rollout-recent.jsonl.zst", in: home)
        try write("archive fixture", at: ".codex/archived_sessions/rollout-archive.jsonl", in: home)
        try write("old fixture", at: ".codex/multica-sessions/old-agent.jsonl", in: home, modifiedAt: oldDate)
        try write("cache", at: ".workbuddy/cache/file.bin", in: home)

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        let sessions = model.filteredItems.filter { $0.category == .sessions }
        XCTAssertEqual(Set(sessions.map(\.fileName)), [
            "old.jsonl", "rollout-recent.jsonl.zst", "rollout-archive.jsonl", "old-agent.jsonl"
        ])
        XCTAssertTrue(sessions.allSatisfy { $0.recommendation == .reviewSuggested })
        let old = try XCTUnwrap(sessions.first { $0.fileName == "old.jsonl" })
        let cache = try XCTUnwrap(model.filteredItems.first { $0.ruleID == "workbuddy-cache" })
        XCTAssertTrue(old.displayName.contains("demo"))
        XCTAssertTrue(old.displayName.contains("Review the fixture branch"))

        model.selectedAgeFilter = .olderThan7Days
        XCTAssertEqual(Set(model.filteredItems.map(\.fileName)), ["old.jsonl", "old-agent.jsonl"])
        model.selectedAgeFilter = .all
        model.searchText = "Review the fixture branch"
        XCTAssertEqual(model.filteredItems.map(\.id), [old.id])
        model.clearAllFilters()

        model.selectRecommendedInScope()
        XCTAssertEqual(model.selectedItemIDs, [cache.id])
        model.clearAllSelection()
        model.selectSection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.selectSection(.recommended)
        XCTAssertEqual(model.selectedItemIDs, [cache.id])
        model.clearAllSelection()
        model.selectAllVisible()
        XCTAssertEqual(model.selectedItemIDs, [cache.id])
        model.invertVisibleSelection()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, [cache.id])

        let archive = try XCTUnwrap(sessions.first { $0.fileName == "rollout-archive.jsonl" })
        model.toggleSelection(for: old)
        model.toggleSelection(for: archive)
        let manualIDs: Set<String> = [old.id, archive.id]
        XCTAssertEqual(model.selectedItemIDs, manualIDs.union([cache.id]))
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, manualIDs)
        model.requestTrashConfirmation()
        XCTAssertTrue(model.showingTrashConfirmation)
        XCTAssertEqual(Set(model.selectedItems.map(\.id)), manualIDs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))

        model.confirmAndTrashSelectedItems()
        try await waitUntil { model.lastCleanupResult != nil && !model.isCleaning && !model.isScanning }
        let result = try XCTUnwrap(model.lastCleanupResult)
        XCTAssertEqual(Set(result.trashedItems.map(\.id)), manualIDs)
        XCTAssertFalse(model.showingTrashConfirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))

        model.sidebarSelection = .history
        let expectedBytes = old.sizeBytes + archive.sizeBytes
        XCTAssertEqual(model.historySummary.totalFreedBytes, expectedBytes)
        let point = try XCTUnwrap(model.historySummary.points.last)
        model.historyMetricMode = .cumulative
        XCTAssertEqual(model.historyMetricMode.bytes(for: point), expectedBytes)
        model.historyMetricMode = .daily
        XCTAssertEqual(model.historyMetricMode.bytes(for: point), expectedBytes)
        XCTAssertEqual(model.historySummary.totalTrashedItems, 2)
    }

    @MainActor
    func testHardProtectedRowsStayLockedAndPluginsRequireBothConfirmations() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try write("credential fixture", at: ".codex/auth.json", in: home)
        try write("plugin fixture", at: ".workbuddy/plugins/demo/plugin.js", in: home)

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        let locked = try XCTUnwrap(model.filteredItems.first { $0.ruleID == "codex-protected-auth" })
        let plugin = try XCTUnwrap(model.filteredItems.first { $0.ruleID == "workbuddy-protected-plugins" })

        model.toggleSelection(for: locked)
        XCTAssertNil(model.pendingRiskItemToSelect)
        XCTAssertTrue(model.selectedItems.isEmpty)

        model.toggleSelection(for: plugin)
        XCTAssertEqual(model.pendingRiskItemToSelect, plugin)
        XCTAssertTrue(model.selectedItems.isEmpty)
        model.confirmRiskItemSelection(plugin)
        XCTAssertEqual(model.selectedItems, [plugin])
        model.requestTrashConfirmation()
        XCTAssertTrue(model.showingTrashConfirmation)
        model.confirmAndTrashSelectedItems()
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.url.path))

        model.confirmAndTrashSelectedItems(acknowledgedNotRecommendedRisk: true)
        try await waitUntil { model.lastCleanupResult != nil && !model.isCleaning && !model.isScanning }
        XCTAssertEqual(model.lastCleanupResult?.trashedItems.map(\.id), [plugin.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.url.path))
    }

    @MainActor
    func testScanReadyReturnToIdleAndHistoryStartScanLifecycle() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try write("cache fixture", at: ".workbuddy/cache/data.bin", in: home)

        let model = makeViewModel(home: home)
        XCTAssertFalse(model.hasScanResults)
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.report)

        model.startScan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertFalse(model.filteredItems.isEmpty)

        model.selectRecommendedInScope()
        XCTAssertFalse(model.selectedItemIDs.isEmpty)

        model.returnToIdleState()
        XCTAssertNil(model.report)
        XCTAssertFalse(model.hasScanResults)
        XCTAssertFalse(model.isScanning)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertEqual(model.sidebarSelection, .allClients)

        // Starting a scan from history view switches back to space overview and scans cleanly
        model.sidebarSelection = .history
        model.startScan()
        XCTAssertEqual(model.sidebarSelection, .allClients)
        try await waitUntil { model.hasScanResults && !model.isScanning }

        model.returnToIdleState()
        model.startScan()
        model.cancelScan()
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.report)
    }

    func testScanReadyHeroMotionRespectsReduceMotionAndBounds() {
        let reduced = ScanReadyHeroMotion.evaluate(elapsed: 12.34, isAnimating: false)
        XCTAssertEqual(reduced, .staticRest)
        XCTAssertEqual(reduced.glowScale, 1.0)
        XCTAssertEqual(reduced.coreBreathScale, 1.0)
        XCTAssertEqual(reduced.outerRingDegrees, 0.0)
        XCTAssertEqual(reduced.primaryRippleOpacity, 0.0)
        XCTAssertEqual(reduced.secondaryRippleOpacity, 0.0)

        var maxPrimaryOpacity = 0.0
        var maxPrimaryScale: CGFloat = 0
        for step in 0..<100 {
            let t = Double(step) * 0.05
            let sample = ScanReadyHeroMotion.evaluate(elapsed: t, isAnimating: true)
            XCTAssertGreaterThanOrEqual(sample.coreBreathScale, 0.98)
            XCTAssertLessThanOrEqual(sample.coreBreathScale, 1.02)
            XCTAssertGreaterThanOrEqual(sample.glowScale, 0.95)
            XCTAssertLessThanOrEqual(sample.glowScale, 1.05)
            XCTAssertGreaterThanOrEqual(sample.outerRingDegrees, 0.0)
            XCTAssertLessThan(sample.outerRingDegrees, 360.0)
            XCTAssertGreaterThanOrEqual(sample.primaryRippleOpacity, 0.0)
            XCTAssertLessThanOrEqual(sample.primaryRippleOpacity, 1.0)
            XCTAssertGreaterThanOrEqual(sample.secondaryRippleOpacity, 0.0)
            XCTAssertLessThanOrEqual(sample.secondaryRippleOpacity, 1.0)
            maxPrimaryOpacity = max(maxPrimaryOpacity, sample.primaryRippleOpacity)
            maxPrimaryScale = max(maxPrimaryScale, sample.primaryRippleScale)
        }
        XCTAssertGreaterThan(maxPrimaryOpacity, 0.5)
        XCTAssertGreaterThan(maxPrimaryScale, 1.8)

        // Quiet breathing tail at end of cycle (phase >= 0.82)
        let tail = ScanReadyHeroMotion.evaluate(elapsed: 3.6 * 0.90, isAnimating: true)
        XCTAssertEqual(tail.primaryRippleOpacity, 0.0)
    }

    @MainActor
    func testScanReadyAndOrbitalHeroViewsLayoutInLightAndDarkModes() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let readyHost = NSHostingView(
                rootView: ScanReadyHeroView(
                    historicalFreedBytes: 8_703_180,
                    isVisible: true,
                    onStartScan: {},
                    onOpenHistory: {}
                )
            )
            readyHost.appearance = NSAppearance(named: appearanceName)
            readyHost.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
            readyHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(readyHost.fittingSize.width, 0)
            XCTAssertGreaterThan(readyHost.fittingSize.height, 0)

            let scanningHost = NSHostingView(
                rootView: OrbitalScannerHero(isVisible: true, onCancel: {})
            )
            scanningHost.appearance = NSAppearance(named: appearanceName)
            scanningHost.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
            scanningHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scanningHost.fittingSize.width, 0)
            XCTAssertGreaterThan(scanningHost.fittingSize.height, 0)
        }
    }

    @MainActor
    private func makeViewModel(home: URL) -> CleanerViewModel {
        CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: CustomDirectoryStore(
                storageURL: home.appendingPathComponent("custom.json"),
                safetyGuard: SafetyGuard(homeDirectory: home)
            ),
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            trashPerformer: FixtureTrashPerformer(directory: home.appendingPathComponent(".fixture-trash"))
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

    private func write(_ text: String, at path: String, in home: URL, modifiedAt: Date? = nil) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }
}
