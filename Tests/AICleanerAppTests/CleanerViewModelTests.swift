@testable import AICleanerApp
import AICleanerCore
import AppKit
import Foundation
import os
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

private final class ConfigurableTrashPerformer: TrashPerforming, @unchecked Sendable {
    let directory: URL
    private let failingPathsLock: OSAllocatedUnfairLock<Set<String>>

    init(directory: URL, failingPaths: Set<String> = []) {
        self.directory = directory
        self.failingPathsLock = OSAllocatedUnfairLock(initialState: failingPaths)
    }

    func setFailingPaths(_ paths: Set<String>) {
        failingPathsLock.withLock { $0 = paths }
    }

    func trashItem(at url: URL) throws -> URL? {
        let normalized = ExcludedItemMatcher.normalizePath(url)
        let canonical = ExcludedItemMatcher.canonicalMatchPath(url.path)
        let shouldFail = failingPathsLock.withLock { paths in
            paths.contains(normalized) || paths.contains(canonical)
        }
        if shouldFail {
            throw NSError(
                domain: "ConfigurableTrashPerformer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "模拟文件占用或权限不足"]
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

private final class CountingScanEngine: ScanPerforming, @unchecked Sendable {
    private let wrapped: ScanEngine
    private let countLock = OSAllocatedUnfairLock(initialState: 0)

    var homeDirectory: URL { wrapped.homeDirectory }
    var safetyGuard: SafetyGuard { wrapped.safetyGuard }

    var scanCount: Int {
        countLock.withLock { $0 }
    }

    init(wrapping wrapped: ScanEngine) {
        self.wrapped = wrapped
    }

    func scan(
        customDirectories: [CustomScanDirectory],
        excludedItems: [ExcludedItemRecord],
        now: Date?
    ) -> ScanReport {
        countLock.withLock { $0 += 1 }
        return wrapped.scan(
            customDirectories: customDirectories,
            excludedItems: excludedItems,
            now: now
        )
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
    func testExcludeSelectedItemUpdatesListStatsSelectionAndPersistsAcrossRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        try write(String(repeating: "A", count: 4_000), at: ".claude/debug/alpha.log", in: home)
        try write(String(repeating: "B", count: 6_000), at: ".claude/debug/beta.log", in: home)
        try write(
            String(repeating: "C", count: 9_000),
            at: "Library/Application Support/Cursor/GPUCache/data_0",
            in: home
        )

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        let initialTotalBytes = try XCTUnwrap(model.report?.totalSizeBytes)
        let alphaItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "alpha.log" }))
        let betaItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "beta.log" }))
        let gpuCacheItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "GPUCache" }))

        // 先勾选 alpha 与 beta，再排除 alpha
        model.toggleSelection(for: alphaItem)
        model.toggleSelection(for: betaItem)
        XCTAssertEqual(model.selectedItems.count, 2)
        XCTAssertEqual(model.selectedTotalBytes, alphaItem.sizeBytes + betaItem.sizeBytes)

        model.excludeItem(alphaItem)

        // 立即同步生效（无需等待重新扫描）
        XCTAssertFalse(model.filteredItems.contains(where: { $0.id == alphaItem.id }))
        XCTAssertFalse(model.isSelected(alphaItem))
        XCTAssertEqual(model.selectedItems.map(\.id), [betaItem.id])
        XCTAssertEqual(model.selectedTotalBytes, betaItem.sizeBytes)
        XCTAssertEqual(model.report?.totalSizeBytes, initialTotalBytes - alphaItem.sizeBytes)
        XCTAssertEqual(model.scopedRecommendedBytes, initialTotalBytes - alphaItem.sizeBytes)
        XCTAssertEqual(model.excludedItems.count, 1)
        XCTAssertEqual(model.excludedItemCountText, "1 项")
        XCTAssertEqual(model.excludedItemRows.first?.existsOnDisk, true)

        let claudeSidebarEntry = try XCTUnwrap(model.builtInSidebarEntries.first(where: { $0.id == "claude-code" }))
        XCTAssertEqual(claudeSidebarEntry.cleanableBytes, betaItem.sizeBytes)

        // 各种批量勾选均不会选中已排除条目
        model.clearAllSelection()
        model.selectRecommendedInScope()
        XCTAssertFalse(model.selectedItemIDs.contains(alphaItem.id))
        model.selectAllVisible()
        XCTAssertFalse(model.selectedItemIDs.contains(alphaItem.id))
        model.selectSection(.recommended)
        XCTAssertFalse(model.selectedItemIDs.contains(alphaItem.id))
        model.clearAllSelection()
        model.invertVisibleSelection()
        XCTAssertFalse(model.selectedItemIDs.contains(alphaItem.id))

        // 切换到单个客户端 Cursor，排除它唯一的目录项 GPUCache -> 侧栏自动切回空间总览且客户端计数减少
        model.sidebarSelection = .client("cursor")
        model.excludeItem(gpuCacheItem)
        XCTAssertEqual(model.sidebarSelection, .allClients)
        XCTAssertNil(model.builtInSidebarEntries.first(where: { $0.id == "cursor" }))
        XCTAssertEqual(model.report?.detectedBuiltInClientsCount, 1)
        XCTAssertEqual(model.excludedItems.count, 2)
        XCTAssertEqual(model.excludedItemCountText, "2 项")

        // 重新扫描后仍然保持排除
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertFalse(model.filteredItems.contains(where: { $0.url.path == alphaItem.url.path }))
        XCTAssertFalse(model.filteredItems.contains(where: { $0.url.path == gpuCacheItem.url.path }))
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["beta.log"])

        // 模拟应用重启：新建 ViewModel 指向相同隔离存储
        let restarted = makeViewModel(home: home)
        XCTAssertEqual(restarted.excludedItems.count, 2)
        XCTAssertEqual(restarted.excludedItemCountText, "2 项")
        restarted.rescan()
        try await waitUntil { restarted.hasScanResults && !restarted.isScanning }
        XCTAssertEqual(restarted.filteredItems.map(\.fileName), ["beta.log"])
        restarted.selectRecommendedInScope()
        XCTAssertEqual(restarted.selectedItems.map(\.fileName), ["beta.log"])
    }

    @MainActor
    func testRestoreSingleAndAllItemsPreservesRiskRulesAndHandlesMissingPaths() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let oldDate = Date().addingTimeInterval(-20 * 86_400)
        try write(String(repeating: "L", count: 3_000), at: ".claude/debug/keep.log", in: home)
        try write(String(repeating: "D", count: 2_500), at: ".claude/debug/vanished.log", in: home)
        try write(
            [
                #"{"type":"user","cwd":"/Users/fixture/demo","message":{"role":"user","content":"原始提问"}}"#,
                #"{"type":"custom-title","customTitle":"重要历史排查会话"}"#
            ].joined(separator: "\n"),
            at: ".claude/projects/-Users-fixture-demo/old-session.jsonl",
            in: home,
            modifiedAt: oldDate
        )
        try write("plugin fixture", at: ".claude/plugins/demo-plugin.js", in: home)

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        let keepLog = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "keep.log" }))
        let vanishedLog = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "vanished.log" }))
        let oldSession = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "old-session.jsonl" }))
        let pluginItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "plugins" }))

        model.excludeItem(keepLog)
        model.excludeItem(vanishedLog)
        model.excludeItem(oldSession)
        model.excludeItem(pluginItem)
        XCTAssertEqual(model.excludedItems.count, 4)

        // 核对会话条目在排除记录中保留可读标题
        let sessionRecord = try XCTUnwrap(model.excludedItems.first(where: { $0.normalizedPath == oldSession.url.path }))
        XCTAssertEqual(sessionRecord.displayName, "重要历史排查会话")
        XCTAssertEqual(sessionRecord.category, .sessions)

        // 外部删除 vanished.log 后刷新状态 -> 标记路径已不存在，但仍允许从排除清单移除
        try FileManager.default.removeItem(at: vanishedLog.url)
        model.sidebarSelection = .excluded
        XCTAssertEqual(model.missingExcludedItemCount, 1)
        let vanishedRow = try XCTUnwrap(model.excludedItemRows.first(where: { $0.record.normalizedPath == vanishedLog.url.path }))
        XCTAssertFalse(vanishedRow.existsOnDisk)

        model.restoreExcludedItem(vanishedRow.record)
        XCTAssertEqual(model.excludedItems.count, 3)
        XCTAssertEqual(model.missingExcludedItemCount, 0)
        XCTAssertNil(model.errorBannerMessage)
        XCTAssertFalse(model.filteredItems.contains(where: { $0.url.path == vanishedLog.url.path }))

        // 单条恢复旧会话：重新回到待清理列表，不自动勾选且仍要求逐条勾选
        model.restoreExcludedItem(sessionRecord)
        try await waitUntil { !model.isScanning }
        model.sidebarSelection = .allClients

        let restoredSession = try XCTUnwrap(model.filteredItems.first(where: { $0.url.path == oldSession.url.path }))
        XCTAssertEqual(restoredSession.preferredDisplayTitle, "重要历史排查会话")
        XCTAssertFalse(model.isSelected(restoredSession))
        XCTAssertFalse(restoredSession.isBulkSelectable)
        model.selectAllVisible()
        XCTAssertFalse(model.isSelected(restoredSession))

        // 跨重启后「全部恢复」：剩余 keep.log 与高风险 plugins 均回到待清理列表且均不自动勾选
        let restarted = makeViewModel(home: home)
        restarted.rescan()
        try await waitUntil { restarted.hasScanResults && !restarted.isScanning }
        XCTAssertEqual(restarted.excludedItems.count, 2)
        XCTAssertFalse(restarted.filteredItems.contains(where: { $0.fileName == "keep.log" }))
        XCTAssertFalse(restarted.filteredItems.contains(where: { $0.fileName == "plugins" }))

        restarted.sidebarSelection = .excluded
        restarted.restoreAllExcludedItems()
        try await waitUntil { !restarted.isScanning }

        XCTAssertTrue(restarted.excludedItems.isEmpty)
        XCTAssertEqual(restarted.excludedItemCountText, "")
        XCTAssertTrue(restarted.selectedItemIDs.isEmpty)

        restarted.sidebarSelection = .allClients
        let restoredKeep = try XCTUnwrap(restarted.filteredItems.first(where: { $0.fileName == "keep.log" }))
        let restoredPlugin = try XCTUnwrap(restarted.filteredItems.first(where: { $0.fileName == "plugins" }))
        XCTAssertFalse(restarted.isSelected(restoredKeep))
        XCTAssertFalse(restarted.isSelected(restoredPlugin))
        XCTAssertEqual(restoredPlugin.recommendation, .notRecommended)

        // 高风险项恢复后仍需风险确认弹窗，不会静默勾选
        restarted.toggleSelection(for: restoredPlugin)
        XCTAssertEqual(restarted.pendingRiskItemToSelect?.id, restoredPlugin.id)
        XCTAssertFalse(restarted.isSelected(restoredPlugin))
    }

    @MainActor
    func testExcludedItemsViewLayoutsInLightAndDarkModes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let existingFile = home.appendingPathComponent(".claude/debug/existing.log")
        try write("existing", at: ".claude/debug/existing.log", in: home)

        let model = makeViewModel(home: home)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let emptyHost = NSHostingView(rootView: ExcludedItemsView(viewModel: model))
            emptyHost.appearance = NSAppearance(named: appearanceName)
            emptyHost.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
            emptyHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(emptyHost.fittingSize.width, 0)
            XCTAssertGreaterThan(emptyHost.fittingSize.height, 0)
        }

        let item1 = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "r1",
            displayName: "existing.log",
            fileName: "existing.log",
            url: existingFile,
            category: .logs,
            safetyNote: "日志",
            sizeBytes: 128,
            fileCount: 1,
            modifiedAt: Date(),
            isDirectory: false,
            isCustom: false
        )
        let item2 = CleanableItem(
            clientID: "cursor",
            clientName: "Cursor",
            ruleID: "r2",
            displayName: "GPU 缓存",
            fileName: "GPUCache",
            url: home.appendingPathComponent("Library/Application Support/Cursor/GPUCache"),
            category: .cache,
            safetyNote: "缓存",
            sizeBytes: 1_024,
            fileCount: 3,
            modifiedAt: Date(),
            isDirectory: true,
            isCustom: false
        )
        model.excludeItem(item1)
        model.excludeItem(item2)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let populatedHost = NSHostingView(rootView: ExcludedItemsView(viewModel: model))
            populatedHost.appearance = NSAppearance(named: appearanceName)
            populatedHost.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
            populatedHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(populatedHost.fittingSize.width, 0)
            XCTAssertGreaterThan(populatedHost.fittingSize.height, 0)
        }
    }

    @MainActor
    func testLayeredTmpBulkSkipManualSelectionSortingAndSwiftUILayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICleanerTmpUITest-\(UUID().uuidString)")
        let home = root.appendingPathComponent("FakeHome", isDirectory: true)
        let privateTmp = root.appendingPathComponent("private/tmp", isDirectory: true)
        let tmpLink = root.appendingPathComponent("tmp", isDirectory: true)
        let userTmp = root.appendingPathComponent("user-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateTmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userTmp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tmpLink, withDestinationURL: privateTmp)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = fixedNow.addingTimeInterval(-72 * 3600)
        let midDate = fixedNow.addingTimeInterval(-36 * 3600)
        let recentDate = fixedNow.addingTimeInterval(-2 * 3600)

        // Home 缓存 + Layer 1 AI /tmp（冷却期外 & 近期修改）+ 其他 AI /tmp + Layer 2 未归属（旧 & 近期）
        try write(String(repeating: "a", count: 600), at: ".claude/debug/home.log", in: home, modifiedAt: oldDate)
        try write(String(repeating: "b", count: 4_000), at: "codex-clipboard-old.png", in: privateTmp, modifiedAt: oldDate)
        try write(String(repeating: "c", count: 1_200), at: "codex-active-recent.log", in: privateTmp, modifiedAt: recentDate)
        try write(String(repeating: "d", count: 2_500), at: "magpie-bridge-old.log", in: privateTmp, modifiedAt: oldDate)
        try write(String(repeating: "e", count: 5_000), at: "manual-archive-old.tar", in: privateTmp, modifiedAt: oldDate)
        try write(String(repeating: "f", count: 1_500), at: "manual-scratch-recent.tmp", in: privateTmp, modifiedAt: recentDate)
        try write(String(repeating: "g", count: 2_000), at: "claude-user-tmp.log", in: userTmp, modifiedAt: midDate)
        // 不应出现在未归属区的 userTmp 普通文件 & /tmp 隐藏缓存
        try write(String(repeating: "h", count: 9_000), at: "unrelated-browser-cache.bin", in: userTmp, modifiedAt: oldDate)
        try write(String(repeating: "i", count: 9_000), at: ".sboxcache_hidden", in: privateTmp, modifiedAt: oldDate)

        let guardInstance = SafetyGuard(homeDirectory: home)
        let engine = CountingScanEngine(
            wrapping: ScanEngine(
                homeDirectory: home,
                safetyGuard: guardInstance,
                systemTempRoot: tmpLink,
                userTempRoot: userTmp,
                currentUID: getuid(),
                activeTempDirectoryPath: nil,
                now: fixedNow
            )
        )
        let model = CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: CustomDirectoryStore(
                storageURL: root.appendingPathComponent("custom.json"),
                safetyGuard: guardInstance
            ),
            historyStore: CleanupHistoryStore(storageURL: root.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: root.appendingPathComponent("excluded.json")),
            trashPerformer: FixtureTrashPerformer(directory: root.appendingPathComponent(".fixture-trash")),
            scanEngine: engine
        )

        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(engine.scanCount, 1)

        // 1. 侧边栏分组验证
        XCTAssertEqual(Set(model.builtInSidebarEntries.map(\.id)), ["claude-code", "codex"])
        XCTAssertEqual(
            model.tempSidebarEntries.map(\.id),
            [TempDirectoryScanner.otherAITempClientID, TempDirectoryScanner.unattributedTempClientID]
        )

        let byName = Dictionary(uniqueKeysWithValues: model.filteredItems.map { ($0.fileName, $0) })
        let codexOld = try XCTUnwrap(byName["codex-clipboard-old.png"])
        let codexRecent = try XCTUnwrap(byName["codex-active-recent.log"])
        let magpieOld = try XCTUnwrap(byName["magpie-bridge-old.log"])
        let manualOld = try XCTUnwrap(byName["manual-archive-old.tar"])
        let manualRecent = try XCTUnwrap(byName["manual-scratch-recent.tmp"])
        let claudeHome = try XCTUnwrap(byName["home.log"])
        let claudeUserTmp = try XCTUnwrap(byName["claude-user-tmp.log"])
        XCTAssertNil(byName["unrelated-browser-cache.bin"])
        XCTAssertNil(byName[".sboxcache_hidden"])

        // 2. 空间总览中全部 4 个批量入口均跳过未归属项与 24h 内近期修改项
        let expectedBulkIDs: Set<String> = [claudeHome.id, claudeUserTmp.id, codexOld.id, magpieOld.id]
        model.selectRecommendedInScope()
        XCTAssertEqual(model.selectedItemIDs, expectedBulkIDs)

        model.clearAllSelection()
        model.selectSection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty, "勾选本组应跳过未归属与近期修改项")

        model.selectAllVisible()
        XCTAssertEqual(model.selectedItemIDs, expectedBulkIDs)

        // 先手动勾选一条未归属项，再执行反选：手动勾选项保留，其余仅在可批量项中反选
        model.clearAllSelection()
        model.toggleSelection(for: manualOld)
        XCTAssertEqual(model.selectedItemIDs, [manualOld.id])
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, expectedBulkIDs.union([manualOld.id]))
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, [manualOld.id])

        // 3. 切换到「/tmp 未归属临时项」分组：顶部提示条、排序、搜索与批量全跳过
        model.clearAllSelection()
        model.sidebarSelection = .client(TempDirectoryScanner.unattributedTempClientID)
        XCTAssertNotNil(model.scopeNoticeBanner)
        XCTAssertTrue(model.scopeNoticeBanner?.message.contains("/tmp") == true)
        XCTAssertTrue(model.filteredBulkSelectableItems.isEmpty)

        // 验证大小降序与修改时间最新排序
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["manual-archive-old.tar", "manual-scratch-recent.tmp"])
        model.sortOrder = .modifiedDescending
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["manual-scratch-recent.tmp", "manual-archive-old.tar"])
        model.sortOrder = .sizeDescending

        // 验证搜索过滤（含「近期修改」与路径搜索）
        model.searchText = "近期修改"
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["manual-scratch-recent.tmp"])
        model.searchText = ""

        // 在未归属分组内所有批量勾选均不生效
        model.selectRecommendedInScope()
        model.selectSection(.reviewSuggested)
        model.selectAllVisible()
        model.invertVisibleSelection()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)

        // 4. 在 Light / Dark 模式下验证侧栏「系统临时目录」分组与列表页（含未归属提示条、仅逐条手选徽标、来源与近期修改标签）布局
        // 注：直接挂载纯 SwiftUI 子视图而非无窗口 NavigationSplitView（ContentView），避免 macOS 15 离屏 NSHostingView 返回 (0, 0) fittingSize
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let sidebarHost = NSHostingView(rootView: SidebarView(viewModel: model))
            sidebarHost.appearance = NSAppearance(named: appearanceName)
            sidebarHost.frame = NSRect(x: 0, y: 0, width: 252, height: 760)
            sidebarHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(sidebarHost.fittingSize.width, 0)
            XCTAssertGreaterThan(sidebarHost.fittingSize.height, 0)

            let listHost = NSHostingView(rootView: ItemListView(viewModel: model, isVisible: true))
            listHost.appearance = NSAppearance(named: appearanceName)
            listHost.frame = NSRect(x: 0, y: 0, width: 928, height: 760)
            listHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(listHost.fittingSize.width, 0)
            XCTAssertGreaterThan(listHost.fittingSize.height, 0)
        }

        // 5. 逐条手动勾选未归属项 + 近期修改 AI 项，执行移入废纸篓闭环并验证原位扣减（不再自动重扫）
        model.toggleSelection(for: manualOld)
        model.toggleSelection(for: codexRecent)
        XCTAssertEqual(model.selectedItemIDs, [manualOld.id, codexRecent.id])

        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(engine.scanCount, 1, "清理完成后不应再触发 ScanEngine 全量重扫")
        XCTAssertEqual(model.lastCleanupResult?.trashedCount, 2)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manualOld.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexRecent.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manualRecent.url.path))
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["manual-scratch-recent.tmp"])

        // 6. 验证与 AICL-13 排除条目兼容：右键排除剩余未归属项 -> 手动重扫仍隐藏 -> 恢复后重现且仍为仅手选
        model.excludeItem(manualRecent)
        XCTAssertEqual(model.excludedItems.count, 1)
        XCTAssertTrue(model.tempSidebarEntries.allSatisfy { $0.id != TempDirectoryScanner.unattributedTempClientID })

        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertFalse(model.report?.allItems.contains(where: { $0.fileName == "manual-scratch-recent.tmp" }) == true)

        let excludedRecord = try XCTUnwrap(model.excludedItems.first)
        model.restoreExcludedItem(excludedRecord)
        try await waitUntil { !model.isScanning && model.report?.allItems.contains(where: { $0.fileName == "manual-scratch-recent.tmp" }) == true }
        XCTAssertTrue(model.excludedItems.isEmpty)
        let restored = try XCTUnwrap(model.report?.allItems.first(where: { $0.fileName == "manual-scratch-recent.tmp" }))
        XCTAssertTrue(restored.requiresIndividualSelection)
        XCTAssertFalse(restored.isBulkSelectable)
        XCTAssertFalse(model.isSelected(restored))
    }

    @MainActor
    func testCleanupUpdatesInPlaceWithoutTriggeringRescanAndManualRefreshStillWorks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        try write(String(repeating: "A", count: 4_000), at: ".claude/debug/alpha.log", in: home)
        try write(String(repeating: "B", count: 6_000), at: ".claude/debug/beta.log", in: home)
        try write(
            String(repeating: "C", count: 9_000),
            at: "Library/Application Support/Cursor/GPUCache/data_0",
            in: home
        )

        let countingEngine = CountingScanEngine(wrapping: ScanEngine(homeDirectory: home))
        let model = makeViewModel(home: home, scanEngine: countingEngine)

        model.startScan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(countingEngine.scanCount, 1)

        let initialTotalBytes = try XCTUnwrap(model.report?.totalSizeBytes)
        let initialCelebrationID = model.cleanupCelebrationID
        let alpha = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "alpha.log" }))
        let beta = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "beta.log" }))
        let gpuCache = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "GPUCache" }))

        // 在首次扫描完成后、清理前于磁盘新增一个文件：若未重扫，则清理后不应出现该文件
        try write(String(repeating: "N", count: 2_000), at: ".claude/debug/late-arrival.log", in: home)

        model.toggleSelection(for: alpha)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(countingEngine.scanCount, 1, "部分清理后不得再次调用 ScanEngine")
        XCTAssertNotEqual(model.cleanupCelebrationID, initialCelebrationID)
        XCTAssertEqual(model.lastCleanupResult?.trashedCount, 1)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertEqual(model.historyRecords.count, 1)

        // 原位扣减列表、侧栏计数与空间仪表盘读数
        let remainingBytes = initialTotalBytes - alpha.sizeBytes
        XCTAssertEqual(model.report?.totalSizeBytes, remainingBytes)
        XCTAssertEqual(model.scopedRecommendedBytes, remainingBytes)
        XCTAssertEqual(model.scopedCleanableBytes, remainingBytes)
        XCTAssertEqual(model.reportTotalBytesText, CleanerFormatting.formatBytes(remainingBytes))
        XCTAssertFalse(model.filteredItems.contains(where: { $0.id == alpha.id }))
        XCTAssertTrue(model.filteredItems.contains(where: { $0.id == beta.id }))
        XCTAssertTrue(model.filteredItems.contains(where: { $0.id == gpuCache.id }))
        XCTAssertFalse(model.filteredItems.contains(where: { $0.fileName == "late-arrival.log" }))

        let claudeSidebar = try XCTUnwrap(model.builtInSidebarEntries.first(where: { $0.id == "claude-code" }))
        XCTAssertEqual(claudeSidebar.cleanableBytes, beta.sizeBytes)

        // 手动触发 rescan() 与 startScan() 仍正常执行全量扫描并发现新文件
        model.rescan()
        try await waitUntil { !model.isScanning && model.filteredItems.contains(where: { $0.fileName == "late-arrival.log" }) }
        XCTAssertEqual(countingEngine.scanCount, 2)

        model.sidebarSelection = .history
        model.startScan()
        XCTAssertEqual(model.sidebarSelection, .allClients)
        try await waitUntil { !model.isScanning && countingEngine.scanCount == 3 }
        XCTAssertEqual(countingEngine.scanCount, 3)
    }

    @MainActor
    func testCleanupPreservesFiltersSearchAndViewportInSameScopeAndFallsBackWhenClientEmptied() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let oldDate = Date().addingTimeInterval(-15 * 86_400)
        try write(String(repeating: "1", count: 3_000), at: ".claude/debug/match-alpha.log", in: home, modifiedAt: oldDate)
        try write(String(repeating: "2", count: 5_000), at: ".claude/debug/match-beta.log", in: home, modifiedAt: oldDate)
        try write(String(repeating: "3", count: 2_000), at: ".claude/debug/other.log", in: home, modifiedAt: oldDate)
        try write(
            String(repeating: "G", count: 8_000),
            at: "Library/Application Support/Cursor/GPUCache/data_0",
            in: home
        )
        let customRoot = home.appendingPathComponent("custom-scratch", isDirectory: true)
        try write(String(repeating: "X", count: 1_500), at: "custom-scratch/only.tmp", in: home)

        let guardInstance = SafetyGuard(homeDirectory: home)
        let customStore = CustomDirectoryStore(
            storageURL: home.appendingPathComponent("custom.json"),
            safetyGuard: guardInstance
        )
        let addedCustom = try customStore.add(
            url: customRoot,
            displayName: "自定义临时区",
            category: .custom,
            mode: .children
        )
        let customClientID = addedCustom.toClientProfile().id

        let countingEngine = CountingScanEngine(wrapping: ScanEngine(homeDirectory: home, safetyGuard: guardInstance))
        let model = CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: customStore,
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: home.appendingPathComponent("excluded-items.json")),
            trashPerformer: FixtureTrashPerformer(directory: home.appendingPathComponent(".fixture-trash")),
            scanEngine: countingEngine
        )

        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(countingEngine.scanCount, 1)

        // 1. 停留在 Claude Code 客户端且未清空时：保留搜索词、筛选条件、排序与视口位置（不重置 listViewportID）
        model.sidebarSelection = .client("claude-code")
        model.searchText = "match"
        model.selectedCategory = .logs
        model.selectedAgeFilter = .olderThan7Days
        model.sortOrder = .nameAscending
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["match-alpha.log", "match-beta.log"])

        let viewportBeforePartialClean = model.listViewportID
        let matchAlpha = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "match-alpha.log" }))
        model.toggleSelection(for: matchAlpha)

        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.sidebarSelection, .client("claude-code"))
        XCTAssertEqual(model.searchText, "match")
        XCTAssertEqual(model.selectedCategory, .logs)
        XCTAssertEqual(model.selectedAgeFilter, .olderThan7Days)
        XCTAssertEqual(model.sortOrder, .nameAscending)
        XCTAssertEqual(model.listViewportID, viewportBeforePartialClean, "同分组未清空时不应重置列表视口")
        XCTAssertEqual(model.filteredItems.map(\.fileName), ["match-beta.log"])
        XCTAssertEqual(model.scopedRecommendedBytes, 7_000)

        // 2. 清理 Cursor 最后一条：当前选中的客户端分组平滑回退到「空间总览」且计数准确
        model.clearAllFilters()
        model.sidebarSelection = .client("cursor")
        let viewportBeforeFallback = model.listViewportID
        let cursorCache = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "GPUCache" }))
        model.dismissCleanupBanner()
        model.toggleSelection(for: cursorCache)

        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertEqual(model.sidebarSelection, .allClients)
        XCTAssertEqual(model.headerTitleText, "空间总览")
        XCTAssertNotEqual(model.listViewportID, viewportBeforeFallback)
        XCTAssertNil(model.builtInSidebarEntries.first(where: { $0.id == "cursor" }))
        XCTAssertEqual(model.report?.detectedBuiltInClientsCount, 1)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)

        // 3. 清理自定义目录最后一条：按既有规则保留自定义目录分组，不切走、不崩溃
        model.sidebarSelection = .client(customClientID)
        let customOnly = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "only.tmp" }))
        model.dismissCleanupBanner()
        model.toggleSelection(for: customOnly)

        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertEqual(model.sidebarSelection, .client(customClientID))
        XCTAssertTrue(model.filteredItems.isEmpty)
        let customEntry = try XCTUnwrap(model.customSidebarEntries.first(where: { $0.id == customClientID }))
        XCTAssertEqual(customEntry.cleanableBytes, 0)
    }

    @MainActor
    func testCleanupRetainsFailedAndBlockedItemsAndAllFailureLeavesReportUnchanged() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        try write(String(repeating: "O", count: 3_000), at: ".claude/debug/ok.log", in: home)
        try write(String(repeating: "F", count: 4_000), at: ".claude/debug/fail.log", in: home)
        let customRoot = home.appendingPathComponent("custom-guard-test", isDirectory: true)
        try write(String(repeating: "D", count: 2_000), at: "custom-guard-test/protected-dir/safe.tmp", in: home)

        let guardInstance = SafetyGuard(homeDirectory: home)
        let customStore = CustomDirectoryStore(
            storageURL: home.appendingPathComponent("custom.json"),
            safetyGuard: guardInstance
        )
        _ = try customStore.add(
            url: customRoot,
            displayName: "护栏验证目录",
            category: .custom,
            mode: .children
        )

        let failURL = home.appendingPathComponent(".claude/debug/fail.log")
        let performer = ConfigurableTrashPerformer(
            directory: home.appendingPathComponent(".fixture-trash"),
            failingPaths: [ExcludedItemMatcher.normalizePath(failURL)]
        )
        let countingEngine = CountingScanEngine(wrapping: ScanEngine(homeDirectory: home, safetyGuard: guardInstance))
        let model = CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: customStore,
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: home.appendingPathComponent("excluded-items.json")),
            trashPerformer: performer,
            scanEngine: countingEngine
        )

        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(countingEngine.scanCount, 1)

        let okItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "ok.log" }))
        let failItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "fail.log" }))
        let protectedDirItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "protected-dir" }))

        // 清理前向目录内写入硬保护凭据文件，触发 TrashCleaner 实时拦截
        try write("token=secret", at: "custom-guard-test/protected-dir/auth.json", in: home)

        // 1. 全部失败 / 被保护拦截：不修改报告、不重置视口、不触发重扫、不触发庆祝动效
        let beforeIDs = model.report?.allItems.map(\.id)
        let beforeBytes = model.report?.totalSizeBytes
        let beforeViewport = model.listViewportID
        let beforeCelebration = model.cleanupCelebrationID

        model.toggleSelection(for: failItem)
        model.toggleSelection(for: protectedDirItem)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.lastCleanupResult?.trashedCount, 0)
        XCTAssertEqual(model.lastCleanupResult?.failedItems.map(\.id), [failItem.id])
        XCTAssertEqual(model.lastCleanupResult?.skippedProtectedItems.map(\.id), [protectedDirItem.id])
        XCTAssertEqual(model.cleanupCelebrationID, beforeCelebration)
        XCTAssertEqual(model.report?.allItems.map(\.id), beforeIDs)
        XCTAssertEqual(model.report?.totalSizeBytes, beforeBytes)
        XCTAssertEqual(model.listViewportID, beforeViewport)
        XCTAssertTrue(model.historyRecords.isEmpty)

        // 2. 部分成功 + 部分失败：仅移除成功项，失败与拦截项继续保留在列表中
        model.dismissCleanupBanner()
        model.toggleSelection(for: okItem)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertEqual(model.lastCleanupResult?.trashedItems.map(\.id), [okItem.id])
        XCTAssertEqual(model.lastCleanupResult?.failedItems.map(\.id), [failItem.id])
        XCTAssertEqual(model.lastCleanupResult?.skippedProtectedItems.map(\.id), [protectedDirItem.id])
        XCTAssertFalse(model.filteredItems.contains(where: { $0.id == okItem.id }))
        XCTAssertTrue(model.filteredItems.contains(where: { $0.id == failItem.id }))
        XCTAssertTrue(model.filteredItems.contains(where: { $0.id == protectedDirItem.id }))
        XCTAssertFalse(model.selectedItemIDs.contains(okItem.id))
        XCTAssertEqual(model.report?.totalSizeBytes, (beforeBytes ?? 0) - okItem.sizeBytes)
    }

    @MainActor
    func testCleanupRemovesNestedChildEntriesAndPrunesExcludedSessionSnapshots() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let parentCustomRoot = home.appendingPathComponent("nested-workspace", isDirectory: true)
        let bundleDir = parentCustomRoot.appendingPathComponent("bundle", isDirectory: true)
        try write(String(repeating: "A", count: 2_500), at: "nested-workspace/bundle/child-active.tmp", in: home)
        try write(String(repeating: "B", count: 1_500), at: "nested-workspace/bundle/child-excluded.tmp", in: home)

        let guardInstance = SafetyGuard(homeDirectory: home)
        let customStore = CustomDirectoryStore(
            storageURL: home.appendingPathComponent("custom.json"),
            safetyGuard: guardInstance
        )
        _ = try customStore.add(
            url: parentCustomRoot,
            displayName: "父自定义目录",
            category: .custom,
            mode: .children
        )
        _ = try customStore.add(
            url: bundleDir,
            displayName: "子自定义目录",
            category: .custom,
            mode: .children
        )

        let countingEngine = CountingScanEngine(wrapping: ScanEngine(homeDirectory: home, safetyGuard: guardInstance))
        let model = CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: customStore,
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: home.appendingPathComponent("excluded-items.json")),
            trashPerformer: FixtureTrashPerformer(directory: home.appendingPathComponent(".fixture-trash")),
            scanEngine: countingEngine
        )

        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }
        XCTAssertEqual(countingEngine.scanCount, 1)

        let bundleItem = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "bundle" }))
        let activeChild = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "child-active.tmp" }))
        let excludedChild = try XCTUnwrap(model.filteredItems.first(where: { $0.fileName == "child-excluded.tmp" }))

        // 先排除目录内的一条子项（会在 sessionExcludedSnapshots 中缓存快照）
        model.excludeItem(excludedChild)
        XCTAssertEqual(model.excludedItems.count, 1)
        XCTAssertEqual(model.missingExcludedItemCount, 0)
        XCTAssertEqual(model.excludedItemRows.first?.existsOnDisk, true)

        // 清理父目录 bundle -> 残留子项 child-active.tmp 同步移除，且已排除项磁盘状态刷新为已不存在
        model.toggleSelection(for: bundleItem)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertFalse(model.filteredItems.contains(where: { $0.id == bundleItem.id }))
        XCTAssertFalse(model.filteredItems.contains(where: { $0.id == activeChild.id }))
        XCTAssertEqual(model.report?.totalItemCount, 0)
        XCTAssertEqual(model.report?.totalSizeBytes, 0)
        XCTAssertEqual(model.missingExcludedItemCount, 1)
        XCTAssertEqual(model.excludedItemRows.first?.existsOnDisk, false)

        // 恢复该已排除记录时，因磁盘不存在且快照已清理，不会把幽灵条目合回报告，也不触发重扫
        let record = try XCTUnwrap(model.excludedItems.first)
        model.restoreExcludedItem(record)
        XCTAssertTrue(model.excludedItems.isEmpty)
        XCTAssertEqual(countingEngine.scanCount, 1)
        XCTAssertEqual(model.report?.totalItemCount, 0)
    }

    @MainActor
    private func makeViewModel(
        home: URL,
        scanEngine: (any ScanPerforming)? = nil,
        trashPerformer: (any TrashPerforming)? = nil
    ) -> CleanerViewModel {
        CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: CustomDirectoryStore(
                storageURL: home.appendingPathComponent("custom.json"),
                safetyGuard: SafetyGuard(homeDirectory: home)
            ),
            historyStore: CleanupHistoryStore(storageURL: home.appendingPathComponent("history.json")),
            excludedItemStore: ExcludedItemStore(storageURL: home.appendingPathComponent("excluded-items.json")),
            trashPerformer: trashPerformer ?? FixtureTrashPerformer(directory: home.appendingPathComponent(".fixture-trash")),
            scanEngine: scanEngine
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
