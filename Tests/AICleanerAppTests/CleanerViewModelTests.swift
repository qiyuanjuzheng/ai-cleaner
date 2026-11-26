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
        XCTAssertEqual(rows["archived.jsonl"]?.item.requiresIndividualSelection, false)
        XCTAssertEqual(rows["archived.jsonl"]?.item.isBulkSelectable, true)

        model.searchText = "标题 结尾"
        XCTAssertEqual(model.filteredItems.map(\.id), [titled.id])
    }

    @MainActor
    func testOldAndArchivedSessionsSupportSectionBulkToggleAndFilterLinkage() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let oldDate = Date().addingTimeInterval(-40 * 86_400)
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
        XCTAssertTrue(sessions.allSatisfy {
            $0.recommendation == .reviewSuggested && !$0.requiresIndividualSelection && $0.isBulkSelectable
        })
        let old = try XCTUnwrap(sessions.first { $0.fileName == "old.jsonl" })
        let oldAgent = try XCTUnwrap(sessions.first { $0.fileName == "old-agent.jsonl" })
        let archive = try XCTUnwrap(sessions.first { $0.fileName == "rollout-archive.jsonl" })
        let cache = try XCTUnwrap(model.filteredItems.first { $0.ruleID == "workbuddy-cache" })
        let allSessionIDs = Set(sessions.map(\.id))
        let allBulkIDs = allSessionIDs.union([cache.id])
        XCTAssertTrue(old.displayName.contains("demo"))
        XCTAssertTrue(old.displayName.contains("Review the fixture branch"))

        // 验证分组头支持一键全选本组，且不含仅手选项
        let reviewHeader = try XCTUnwrap(model.displayedRows.compactMap { row -> SectionHeaderRow? in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested { return header }
            return nil
        }.first)
        XCTAssertTrue(reviewHeader.supportsBulkSelection)
        XCTAssertEqual(reviewHeader.bulkSelectableCount, 4)
        XCTAssertEqual(reviewHeader.individualOnlyCount, 0)

        // 「勾选建议清理项」仍只勾选 .recommended，不波及按需清理旧会话
        model.selectRecommendedInScope()
        XCTAssertEqual(model.selectedItemIDs, [cache.id])
        XCTAssertTrue(model.isSectionAllBulkSelected(.recommended))
        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))

        // 按需清理分组头「全选本组」→ 全选全部旧会话与归档；再次点击「取消本组」→ 仅取消本组，保留建议清理项
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, allBulkIDs)
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))
        XCTAssertTrue(model.isSectionAllBulkSelected(.recommended))

        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, [cache.id])
        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))
        XCTAssertTrue(model.isSectionAllBulkSelected(.recommended))

        // 建议清理分组头同样支持一键「取消本组」与重新「全选本组」
        model.toggleSectionSelection(.recommended)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertFalse(model.isSectionAllBulkSelected(.recommended))

        // 与时间范围筛选（超过 30 天）联动：仅勾选当前可见的 2 条旧会话
        model.selectedAgeFilter = .olderThan30Days
        XCTAssertEqual(Set(model.filteredItems.map(\.fileName)), ["old.jsonl", "old-agent.jsonl"])
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, [old.id, oldAgent.id])
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))

        // 清空筛选后可见条目增多，按钮状态自动回退为「全选本组」
        model.selectedAgeFilter = .all
        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))
        // 再次切回 30 天前筛选，按钮恢复为「取消本组」，点击即可一键取消这 2 条可见项
        model.selectedAgeFilter = .olderThan30Days
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))

        // 与搜索框联动：仅全选 / 取消匹配条目
        model.selectedAgeFilter = .all
        model.searchText = "Review the fixture branch"
        XCTAssertEqual(model.filteredItems.map(\.id), [old.id])
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, [old.id])
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.clearAllFilters()

        // 控制栏「全选」「反选」自动覆盖放开后的按需清理旧会话与归档
        model.selectAllVisible()
        XCTAssertEqual(model.selectedItemIDs, allBulkIDs)
        XCTAssertTrue(model.allVisibleSelected)
        model.invertVisibleSelection()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, allBulkIDs)

        model.clearAllSelection()
        model.toggleSelection(for: old)
        model.toggleSelection(for: archive)
        let targetIDs: Set<String> = [old.id, archive.id]
        model.requestTrashConfirmation()
        XCTAssertTrue(model.showingTrashConfirmation)
        XCTAssertEqual(Set(model.selectedItems.map(\.id)), targetIDs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))

        model.confirmAndTrashSelectedItems()
        try await waitUntil { model.lastCleanupResult != nil && !model.isCleaning && !model.isScanning }
        let result = try XCTUnwrap(model.lastCleanupResult)
        XCTAssertEqual(Set(result.trashedItems.map(\.id)), targetIDs)
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

        // 单条恢复旧会话：重新回到待清理列表，不自动勾选，且支持在「按需清理」分组中批量勾选（建议清理不波及它）
        model.restoreExcludedItem(sessionRecord)
        try await waitUntil { !model.isScanning }
        model.sidebarSelection = .allClients

        let restoredSession = try XCTUnwrap(model.filteredItems.first(where: { $0.url.path == oldSession.url.path }))
        XCTAssertEqual(restoredSession.preferredDisplayTitle, "重要历史排查会话")
        XCTAssertFalse(model.isSelected(restoredSession))
        XCTAssertFalse(restoredSession.requiresIndividualSelection)
        XCTAssertTrue(restoredSession.isBulkSelectable)
        model.selectRecommendedInScope()
        XCTAssertFalse(model.isSelected(restoredSession))
        model.selectAllVisible()
        XCTAssertTrue(model.isSelected(restoredSession))
        model.clearAllSelection()

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
    func testMixedReviewSectionBulkToggleIncludesSessionsAndSkipsTmpAndNotRecommended() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICleanerMixedReviewTest-\(UUID().uuidString)")
        let home = root.appendingPathComponent("FakeHome", isDirectory: true)
        let privateTmp = root.appendingPathComponent("private/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let staleDate = fixedNow.addingTimeInterval(-35 * 86_400)
        let recentDate = fixedNow.addingTimeInterval(-2 * 3600)

        // 1. 建议清理项
        try write(String(repeating: "L", count: 1_200), at: ".claude/debug/home.log", in: home, modifiedAt: staleDate)
        // 2. 可批量勾选的「按需清理」项（旧会话、.zst 压缩归档、archived_sessions、近期普通会话）
        try write(
            #"{"type":"user","cwd":"/Users/fixture/demo","message":{"role":"user","content":"35天前旧会话"}}"#,
            at: ".claude/projects/-Users-fixture-demo/stale-session.jsonl",
            in: home,
            modifiedAt: staleDate
        )
        try write(
            #"{"type":"user","cwd":"/Users/fixture/demo","message":{"role":"user","content":"近期普通会话"}}"#,
            at: ".claude/projects/-Users-fixture-demo/recent-session.jsonl",
            in: home,
            modifiedAt: recentDate
        )
        try write(
            "compressed",
            at: ".codex/sessions/2026/11/01/rollout-compressed.jsonl.zst",
            in: home,
            modifiedAt: recentDate
        )
        try write(
            "archived",
            at: ".codex/archived_sessions/rollout-archived.jsonl",
            in: home,
            modifiedAt: recentDate
        )
        // 3. 强制仅手选的 /tmp 安全边界项（24h 内 AI 临时项 + /tmp 未归属项）
        try write(String(repeating: "T", count: 900), at: "codex-recent-active.log", in: privateTmp, modifiedAt: recentDate)
        try write(String(repeating: "U", count: 1_800), at: "manual-unattributed.tar", in: privateTmp, modifiedAt: staleDate)
        // 4. 不建议清理项（硬保护凭据 + 可覆盖插件）
        try write("secret", at: ".codex/auth.json", in: home, modifiedAt: staleDate)
        try write("plugin", at: ".workbuddy/plugins/demo/plugin.js", in: home, modifiedAt: staleDate)

        let guardInstance = SafetyGuard(homeDirectory: home)
        let engine = ScanEngine(
            homeDirectory: home,
            safetyGuard: guardInstance,
            systemTempRoot: privateTmp,
            userTempRoot: nil,
            currentUID: getuid(),
            activeTempDirectoryPath: nil,
            now: fixedNow
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

        let byName = Dictionary(uniqueKeysWithValues: model.filteredItems.map { ($0.fileName, $0) })
        let homeLog = try XCTUnwrap(byName["home.log"])
        let staleSession = try XCTUnwrap(byName["stale-session.jsonl"])
        let recentSession = try XCTUnwrap(byName["recent-session.jsonl"])
        let compressed = try XCTUnwrap(byName["rollout-compressed.jsonl.zst"])
        let archived = try XCTUnwrap(byName["rollout-archived.jsonl"])
        let codexRecent = try XCTUnwrap(byName["codex-recent-active.log"])
        let manualUnattributed = try XCTUnwrap(byName["manual-unattributed.tar"])
        let authItem = try XCTUnwrap(byName["auth.json"])
        let pluginItem = try XCTUnwrap(byName["plugins"])

        let expectedReviewBulkIDs: Set<String> = [staleSession.id, recentSession.id, compressed.id, archived.id]
        let expectedAllBulkIDs: Set<String> = expectedReviewBulkIDs.union([homeLog.id])

        // 核对安全边界标志
        XCTAssertTrue(codexRecent.requiresIndividualSelection && !codexRecent.isBulkSelectable)
        XCTAssertTrue(manualUnattributed.requiresIndividualSelection && !manualUnattributed.isBulkSelectable)
        XCTAssertFalse(authItem.isBulkSelectable)
        XCTAssertFalse(pluginItem.isBulkSelectable)

        // 空间总览中「按需清理」分组混合了 4 条可批量项 + 2 条仅手选项
        let overviewReviewHeader = try XCTUnwrap(model.displayedRows.compactMap { row -> SectionHeaderRow? in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested { return header }
            return nil
        }.first)
        XCTAssertTrue(overviewReviewHeader.supportsBulkSelection)
        XCTAssertEqual(overviewReviewHeader.bulkSelectableCount, 4)
        XCTAssertEqual(overviewReviewHeader.individualOnlyCount, 2)

        // 分组头「全选本组」仅选中 4 条 AI 按需项，跳过 /tmp 近期项、/tmp 未归属项与不建议清理项
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, expectedReviewBulkIDs)
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))

        // 验证两种勾选态在 Light / Dark 模式下渲染无异常
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ItemListView(viewModel: model, isVisible: true))
            host.appearance = NSAppearance(named: appearanceName)
            host.frame = NSRect(x: 0, y: 0, width: 928, height: 760)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }

        // 再次点击「取消本组」一键取消
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))

        // 控制栏「全选」覆盖建议清理 + AI 按需项，依然严格跳过 /tmp 近期、/tmp 未归属和 .notRecommended
        model.selectAllVisible()
        XCTAssertEqual(model.selectedItemIDs, expectedAllBulkIDs)
        XCTAssertTrue(model.isSectionAllBulkSelected(.recommended))
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))

        // 手动勾选 /tmp 近期与未归属项后执行反选：手动勾选项保留，其余仅在可批量项内反选
        model.clearAllSelection()
        model.toggleSelection(for: codexRecent)
        model.toggleSelection(for: manualUnattributed)
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, expectedAllBulkIDs.union([codexRecent.id, manualUnattributed.id]))
        model.invertVisibleSelection()
        XCTAssertEqual(model.selectedItemIDs, [codexRecent.id, manualUnattributed.id])

        // 切换到 Codex 客户端（混合 2 条归档 + 1 条 /tmp 近期项）
        model.clearAllSelection()
        model.sidebarSelection = .client("codex")
        let codexReviewHeader = try XCTUnwrap(model.displayedRows.compactMap { row -> SectionHeaderRow? in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested { return header }
            return nil
        }.first)
        XCTAssertTrue(codexReviewHeader.supportsBulkSelection)
        XCTAssertEqual(codexReviewHeader.bulkSelectableCount, 2)
        XCTAssertEqual(codexReviewHeader.individualOnlyCount, 1)

        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertEqual(model.selectedItemIDs, [compressed.id, archived.id])
        XCTAssertFalse(model.isSelected(codexRecent))
        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))

        // 搜索仅命中 /tmp 近期项时，分组头自动退回「仅逐条手选」
        model.searchText = "codex-recent-active.log"
        let recentOnlyHeader = try XCTUnwrap(model.displayedRows.compactMap { row -> SectionHeaderRow? in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested { return header }
            return nil
        }.first)
        XCTAssertFalse(recentOnlyHeader.supportsBulkSelection)
        XCTAssertEqual(recentOnlyHeader.bulkSelectableCount, 0)
        XCTAssertEqual(recentOnlyHeader.individualOnlyCount, 1)
        model.searchText = ""

        // 切换到「/tmp 未归属临时项」：全组均为不可批量项，保持仅手选与安全提示条
        model.clearAllSelection()
        model.sidebarSelection = .client(TempDirectoryScanner.unattributedTempClientID)
        XCTAssertNotNil(model.scopeNoticeBanner)
        let unattributedHeader = try XCTUnwrap(model.displayedRows.compactMap { row -> SectionHeaderRow? in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested { return header }
            return nil
        }.first)
        XCTAssertFalse(unattributedHeader.supportsBulkSelection)
        XCTAssertEqual(unattributedHeader.bulkSelectableCount, 0)
        XCTAssertEqual(unattributedHeader.individualOnlyCount, 1)
        model.toggleSectionSelection(.reviewSuggested)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    @MainActor
    func testSearchAndExcludeSupportLinkedSessionArtifactsAndCompressedArchives() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        // 真实 zstd 压缩的 Codex rollout（项目 brand-studio，首条提问「帮我生成一组极简科技感应用图标草图」）
        let codexZstBytes: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x7D, 0x0C, 0x00, 0x66, 0x96, 0x55, 0x3E, 0x40, 0x89, 0xB6,
            0x0D, 0xCF, 0xDF, 0x76, 0x37, 0xBB, 0x8A, 0xA2, 0x76, 0xD4, 0x23, 0xAF, 0x29, 0x14, 0xFC, 0xD8,
            0x44, 0x70, 0x58, 0xD8, 0x39, 0xEE, 0x8D, 0x30, 0x89, 0xCB, 0xE2, 0x46, 0x9F, 0x4B, 0x09, 0xD0,
            0xEA, 0xB5, 0xDA, 0x22, 0x5D, 0x76, 0x91, 0x65, 0x89, 0x68, 0xCD, 0x30, 0x8E, 0x59, 0xE1, 0x61,
            0xCE, 0x3D, 0x62, 0xD7, 0x23, 0x66, 0x2C, 0x03, 0x04, 0x3B, 0x17, 0x42, 0x00, 0x3D, 0x00, 0x47,
            0x00, 0x7F, 0x05, 0x48, 0x14, 0x97, 0x47, 0xC8, 0x1B, 0x2E, 0xAA, 0x61, 0x42, 0x51, 0x13, 0x35,
            0x91, 0x53, 0xE4, 0x70, 0x61, 0x12, 0x11, 0x03, 0x00, 0x49, 0x45, 0x93, 0xE9, 0x1D, 0xA2, 0x7F,
            0x90, 0xD7, 0x3F, 0x30, 0x4C, 0x1E, 0x2B, 0xC7, 0xA6, 0x5F, 0xC4, 0xCA, 0x31, 0x59, 0x29, 0x16,
            0x52, 0xF3, 0x08, 0xB9, 0xC4, 0x9F, 0x59, 0xB4, 0xCE, 0x7B, 0xFF, 0x7A, 0xAC, 0xFC, 0x35, 0x0B,
            0xEC, 0x17, 0x01, 0x1E, 0x21, 0xC7, 0x15, 0x8F, 0x2D, 0xBC, 0x69, 0x74, 0x0E, 0x88, 0x95, 0x63,
            0xFA, 0x98, 0x56, 0xFB, 0x77, 0xA3, 0x54, 0xEB, 0x11, 0xF2, 0x9F, 0x90, 0xF7, 0x7E, 0x96, 0x3D,
            0x9E, 0xD6, 0x5F, 0x5A, 0xB5, 0xFB, 0x56, 0xC2, 0x71, 0x5E, 0x27, 0xB6, 0xE1, 0x1B, 0x61, 0x54,
            0x5A, 0x09, 0xE9, 0x2F, 0xA9, 0x5D, 0x02, 0xB6, 0x52, 0x48, 0x7F, 0x4D, 0x8A, 0x94, 0xAE, 0x0D,
            0x54, 0xE2, 0x3B, 0xEF, 0x95, 0x22, 0x1A, 0xF9, 0xC3, 0x78, 0x10, 0x70, 0x68, 0x11, 0x8D, 0xEC,
            0xB1, 0xD9, 0x9B, 0x90, 0xBC, 0x61, 0xD1, 0x5D, 0x02, 0xAD, 0x71, 0xB0, 0xBB, 0x8F, 0x6D, 0x80,
            0x81, 0xB6, 0x54, 0xD8, 0x5D, 0xD8, 0xC9, 0x78, 0x7A, 0x63, 0xB3, 0x35, 0x9E, 0xFE, 0x08, 0x73,
            0x04, 0xE7, 0x12, 0x04, 0xF6, 0xB6, 0xD2, 0x89, 0x19, 0x00, 0x57, 0x58, 0x98, 0x7E, 0x46, 0xAB,
            0x9D, 0x05, 0xE8, 0x43, 0x78, 0xAC, 0x02, 0x12, 0x8E, 0x8B, 0xE0, 0xBC, 0xD2, 0x5D, 0x80, 0xB0,
            0x40, 0x7B, 0xDF, 0xC6, 0x5C, 0x3E, 0x95, 0xEE, 0x03, 0xF2, 0x79, 0x2E, 0x13, 0x34, 0x46, 0xD8,
            0x01, 0xF9, 0x3C, 0x12, 0x28, 0xE8, 0x07, 0x99, 0x7C, 0x01, 0x33, 0xC8, 0x19, 0xC9, 0xD8, 0x1C,
            0x0E, 0x8D, 0xD1, 0xE0, 0x03, 0x66, 0x32, 0x26, 0xEC, 0x28, 0xE8, 0xC8, 0x9F, 0x47, 0x45, 0x87,
            0x84, 0x9D, 0x03, 0x11, 0xB2, 0xC6, 0xD3, 0x20, 0x67, 0xC4, 0x92, 0xB1, 0x2D, 0x74, 0x64, 0xBC,
            0x55, 0x1C, 0x12, 0x00, 0xCF, 0xB1, 0x8E, 0xFF, 0x4F, 0x8B, 0x81, 0xAA, 0xCD, 0xD0, 0x68, 0xEF,
            0x25, 0x5B, 0xDA, 0x8D, 0xED, 0x22, 0xA7, 0x62, 0x86, 0xEE, 0x0A, 0x33, 0xA9, 0x03, 0x8A, 0x52,
            0x5B, 0x09, 0xB8, 0x72, 0xD5, 0xD4, 0x45, 0x7B, 0x34, 0xA2, 0x67, 0x84, 0x22, 0x25, 0x00, 0x83,
            0xA1, 0xFF, 0x82, 0xD9, 0xB7, 0x64, 0xAB, 0xCC, 0x40, 0x04, 0x62, 0xCC
        ]

        let titledUUID = "11111111-aaaa-7bbb-8ccc-000000000011"
        let zstUUID = "019eca9e-5e0f-7a41-bdc5-0af7077f27c2"
        let orphanUUID = "22222222-aaaa-7bbb-8ccc-000000000022"

        try write(
            #"{"id":"\#(titledUUID)","thread_name":"设计品牌视觉图标"}"# + "\n",
            at: ".codex/session_index.jsonl",
            in: home
        )
        let titledRolloutURL = home.appendingPathComponent(
            ".codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-\(titledUUID).jsonl"
        )
        try write(
            #"{"type":"session_meta","payload":{"id":"\#(titledUUID)","cwd":"/Users/alice/workspace/brand-studio"}}"# + "\n"
                + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"讨论品牌配色与版式规范"}]}}"# + "\n",
            at: ".codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-\(titledUUID).jsonl",
            in: home
        )

        let zstRolloutURL = home.appendingPathComponent(
            ".codex/sessions/2026/11/02/rollout-2026-11-02T10-00-00-\(zstUUID).jsonl.zst"
        )
        try FileManager.default.createDirectory(at: zstRolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(codexZstBytes).write(to: zstRolloutURL)

        try write("img1", at: ".codex/generated_images/\(titledUUID)/cover.png", in: home)
        try write("img2", at: ".codex/generated_images/\(zstUUID)/draft.png", in: home)
        try write("img3", at: ".codex/generated_images/\(orphanUUID)/orphan.png", in: home)

        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { model.hasScanResults && !model.isScanning }

        let rowsByFileName = Dictionary(uniqueKeysWithValues: model.displayedRows.compactMap { entry -> (String, ItemDisplayRow)? in
            if case let .item(row) = entry { return (row.item.fileName, row) }
            return nil
        })

        let titledImageRow = try XCTUnwrap(rowsByFileName[titledUUID])
        XCTAssertEqual(titledImageRow.title, "对话图片缓存 · 设计品牌视觉图标")
        XCTAssertTrue(titledImageRow.detailText.contains("brand-studio"))
        XCTAssertTrue(titledImageRow.detailText.contains("共 1 张图片"))

        let orphanImageRow = try XCTUnwrap(rowsByFileName[orphanUUID])
        XCTAssertEqual(orphanImageRow.title, "对话图片缓存 · 1 张图片 (22222222)")
        XCTAssertTrue(orphanImageRow.detailText.contains("未找到关联会话"))

        // 1. 按会话标题搜索：同时命中对应压缩归档会话与图片缓存目录
        model.searchText = "设计品牌视觉图标"
        XCTAssertEqual(
            Set(model.filteredItems.map(\.fileName)),
            [titledRolloutURL.lastPathComponent, titledUUID]
        )

        // 2. 按压缩归档提取出的首条提问关键词搜索：同时命中压缩会话与对应图片缓存目录
        model.searchText = "极简科技感应用图标草图"
        XCTAssertEqual(
            Set(model.filteredItems.map(\.fileName)),
            [zstRolloutURL.lastPathComponent, zstUUID]
        )

        // 3. 验证与 AICL-13 右键排除/恢复兼容：排除关联图片缓存后记录可读标题并支持恢复
        model.searchText = ""
        model.excludeItem(titledImageRow.item)
        XCTAssertFalse(model.filteredItems.contains { $0.id == titledImageRow.id })
        let excludedRecord = try XCTUnwrap(model.excludedItems.first(where: { $0.normalizedPath == ExcludedItemMatcher.normalizePath(titledImageRow.item.url) }))
        XCTAssertEqual(excludedRecord.displayName, "对话图片缓存 · 设计品牌视觉图标")

        model.restoreExcludedItem(excludedRecord)
        try await waitUntil { !model.isScanning && model.filteredItems.contains { $0.fileName == titledUUID } }
        XCTAssertTrue(model.excludedItems.isEmpty)
    }

    @MainActor
    func testClientProjectTabScopesListsAndCanShowSharedProjectSessions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let shared: SessionProjectID = .workspace("/work/shared")
        try write(#"{"type":"user","cwd":"/work/shared"}"#, at: ".codex/sessions/day/codex-shared.jsonl", in: home)
        try write(#"{"type":"user","cwd":"/work/shared"}"#,
                  at: ".claude/projects/-work-shared/claude-shared.jsonl", in: home)
        try write(#"{"type":"user","cwd":"/work/claude-only"}"#,
                  at: ".claude/projects/-work-claude-only/claude-only.jsonl", in: home)

        let model = makeViewModel(home: home)
        model.report = ScanEngine(homeDirectory: home).scan()
        model.selectBuiltInClient("codex")
        XCTAssertEqual(model.clientPageTab, .cleanup)
        XCTAssertEqual(model.scopedItems.map(\.clientID), ["codex"])
        model.clientPageTab = .projects
        XCTAssertEqual(model.sidebarSelection, .clientProjects("codex"))
        XCTAssertEqual(model.projectGroups.map(\.id), [shared])
        XCTAssertEqual(model.projectGroups.first?.sessions.count, 1)
        XCTAssertEqual(model.visibleProjectSessions.map(\.fileName), ["codex-shared.jsonl"])
        XCTAssertTrue(model.canShowAllProjectClients)

        let outsideClient = try XCTUnwrap(model.report?.allItems.first { $0.fileName == "claude-shared.jsonl" })
        model.toggleSelection(for: outsideClient)
        model.selectAllVisible()
        XCTAssertEqual(model.selectedItems.map(\.fileName), ["codex-shared.jsonl"])
        model.setShowsAllProjectClients(true)
        model.selectAllVisible()
        XCTAssertEqual(Set(model.selectedItems.map(\.fileName)), ["codex-shared.jsonl", "claude-shared.jsonl"])
        model.setShowsAllProjectClients(false)
        XCTAssertEqual(model.selectedItems.map(\.fileName), ["codex-shared.jsonl"])

        model.selectBuiltInClient("claude-code")
        XCTAssertEqual(model.sidebarSelection, .clientProjects("claude-code"))
        XCTAssertEqual(Set(model.projectGroups.map(\.id)), [shared, .workspace("/work/claude-only")])
        XCTAssertEqual(model.selectedProjectID, shared)
        XCTAssertEqual(model.visibleProjectSessions.map(\.fileName), ["claude-shared.jsonl"])
        XCTAssertTrue(model.selectedItems.isEmpty)

        model.setProjectProtection(true, for: shared)
        model.setShowsAllProjectClients(true)
        XCTAssertEqual(model.visibleProjectSessions.count, 2)
        XCTAssertTrue(model.visibleProjectSessions.allSatisfy { $0.hardProtectionReason != nil })

        model.clientPageTab = .cleanup
        XCTAssertEqual(model.sidebarSelection, .client("claude-code"))
        XCTAssertEqual(Set(model.scopedItems.map(\.clientID)), ["claude-code"])
    }

    @MainActor
    func testProjectAgeFilterAndSelectionsStayInTheCurrentProject() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -90, to: now))
        let key = "11111111-1111-4111-8111-111111111111"
        let oldName = "\(key).jsonl"
        try write(#"{"type":"session_meta","payload":{"cwd":"/work/demo"}}"#,
                  at: ".codex/sessions/day/\(oldName)", in: home, modifiedAt: cutoff.addingTimeInterval(-1))
        try write(#"{"type":"user","cwd":"/work/demo"}"#,
                  at: ".codex/sessions/day/edge.jsonl", in: home, modifiedAt: cutoff)
        try write(#"{"type":"user","cwd":"/work/demo"}"#,
                  at: ".codex/sessions/day/newer.jsonl", in: home, modifiedAt: cutoff.addingTimeInterval(1))
        try write(#"{"type":"user","cwd":"/other/demo"}"#,
                  at: ".codex/sessions/day/other.jsonl", in: home, modifiedAt: cutoff.addingTimeInterval(-1))
        try write("image", at: ".codex/generated_images/\(key)/image.png", in: home)
        let engine = ScanEngine(homeDirectory: home, systemTempRoot: nil, now: now)
        let model = makeViewModel(home: home, scanEngine: engine, now: { now })
        let report = engine.scan()
        let summary = try XCTUnwrap(report.clientSummaries.first)
        let unknown = CleanableItem(
            clientID: summary.id, clientName: summary.profile.name, ruleID: "fixture", displayName: "Unknown time",
            fileName: "unknown.jsonl", url: home.appendingPathComponent("unknown.jsonl"), category: .sessions,
            safetyNote: "", sizeBytes: 1, fileCount: 1, modifiedAt: cutoff.addingTimeInterval(-60),
            isDirectory: false, isCustom: false, projectEvidence: .reported("/work/demo")
        )
        model.report = ScanReport(
            scannedAt: now,
            clientSummaries: [ClientScanSummary(profile: summary.profile, items: summary.items + [unknown])],
            totalBuiltInProfilesCount: 1, detectedBuiltInClientsCount: 1
        )
        let overviewSelection = try XCTUnwrap(model.filteredItems.first { $0.fileName == "other.jsonl" })
        model.toggleSelection(for: overviewSelection)
        model.sidebarSelection = .clientProjects("codex")
        model.selectedProjectID = .workspace("/work/demo")
        XCTAssertEqual(Set(model.visibleProjectSessions.map(\.fileName)), [oldName, "edge.jsonl", "newer.jsonl", "unknown.jsonl"])

        model.selectAllVisible()
        XCTAssertEqual(Set(model.selectedItems.map(\.fileName)), [oldName, "edge.jsonl", "newer.jsonl", "unknown.jsonl"])
        let old = try XCTUnwrap(model.visibleProjectSessions.first { $0.fileName == oldName })
        let artifact = try XCTUnwrap(model.projectArtifacts(for: old).first)
        model.toggleSelection(for: artifact)
        model.projectAgeFilter = .olderThan90Days
        XCTAssertEqual(model.projectAgeCutoff, cutoff)
        XCTAssertEqual(model.visibleProjectSessions.map(\.fileName), [oldName])
        XCTAssertEqual(Set(model.selectedItems.map(\.fileName)), [oldName, key])

        model.selectedProjectID = .workspace("/other/demo")
        XCTAssertTrue(model.selectedItems.isEmpty)
        model.sidebarSelection = .allClients
        XCTAssertEqual(model.selectedItems.map(\.id), [overviewSelection.id])
    }

    @MainActor
    func testProjectProtectionLocksAllViewsAndNewSessionsAfterRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "11111111-1111-4111-8111-111111111111"
        let old = Date().addingTimeInterval(-100 * 86_400)
        try write(#"{"type":"user","cwd":"/work/demo"}"#,
                  at: ".codex/sessions/day/\(key).jsonl", in: home, modifiedAt: old)
        try write("image", at: ".codex/generated_images/\(key)/image.png", in: home)
        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { !model.isScanning && model.hasScanResults }
        model.sidebarSelection = .client("codex")
        model.selectAllVisible()
        XCTAssertEqual(Set(model.selectedItems.map(\.fileName)), [key, "\(key).jsonl"])

        model.sidebarSelection = .clientProjects("codex")
        model.selectedProjectID = .workspace("/work/demo")
        model.selectAllVisible()
        XCTAssertEqual(model.selectedItems.count, 1)
        model.setProjectProtection(true, for: .workspace("/work/demo"))
        XCTAssertTrue(model.selectedItems.isEmpty)
        model.projectAgeFilter = .olderThan90Days
        let lockedSession = try XCTUnwrap(model.visibleProjectSessions.first)
        XCTAssertNotNil(lockedSession.hardProtectionReason)
        XCTAssertNotNil(model.projectArtifacts(for: lockedSession).first?.hardProtectionReason)

        for scope in [SidebarSelection.allClients, .client("codex")] {
            model.sidebarSelection = scope
            XCTAssertTrue(model.selectedItems.isEmpty)
            XCTAssertTrue(model.filteredBulkSelectableItems.isEmpty)
            let artifact = try XCTUnwrap(model.scopedItems.first { $0.fileName == key })
            model.toggleSelection(for: artifact)
            model.confirmRiskItemSelection(artifact)
            XCTAssertTrue(model.selectedItems.isEmpty)
        }

        try write(#"{"type":"user","cwd":"/work/demo"}"#,
                  at: ".codex/sessions/day/discovered.jsonl", in: home, modifiedAt: old)
        let restarted = makeViewModel(home: home)
        restarted.rescan()
        try await waitUntil { !restarted.isScanning && restarted.hasScanResults }
        XCTAssertEqual(Set(restarted.scopedProtectedItems.map(\.fileName)), [key, "\(key).jsonl", "discovered.jsonl"])
        restarted.setProjectProtection(false, for: .workspace("/work/demo"))
        XCTAssertEqual(Set(restarted.filteredBulkSelectableItems.map(\.fileName)), [key, "\(key).jsonl", "discovered.jsonl"])
    }

    @MainActor
    func testProjectCleanupVerifiesScannedFilesAndKeepsHistoryAndOtherSelections() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let projectSession = #"{"type":"user","cwd":"/work/demo"}"#
        let old = Date().addingTimeInterval(-100 * 86_400)
        try write(projectSession, at: ".codex/sessions/day/updated.jsonl", in: home, modifiedAt: old)
        try write(projectSession, at: ".codex/sessions/day/unchanged.jsonl", in: home, modifiedAt: old)
        try write(#"{"type":"user","cwd":"/other/demo"}"#, at: ".codex/sessions/day/other.jsonl", in: home, modifiedAt: old)
        let model = makeViewModel(home: home)
        model.rescan()
        try await waitUntil { !model.isScanning && model.hasScanResults }
        let other = try XCTUnwrap(model.filteredItems.first { $0.fileName == "other.jsonl" })
        model.toggleSelection(for: other)

        model.sidebarSelection = .clientProjects("codex")
        model.selectedProjectID = .workspace("/work/demo")
        model.projectAgeFilter = .olderThan90Days
        model.selectAllVisible()
        model.requestTrashConfirmation()
        XCTAssertTrue(model.showingTrashConfirmation)
        XCTAssertEqual(model.selectedItems.count, 2)

        try write(projectSession + "\n{}", at: ".codex/sessions/day/updated.jsonl", in: home, modifiedAt: old)
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }
        let result = try XCTUnwrap(model.lastCleanupResult)
        XCTAssertEqual(result.trashedItems.map(\.item.fileName), ["unchanged.jsonl"])
        XCTAssertEqual(result.failedItems.map(\.item.fileName), ["updated.jsonl"])
        XCTAssertEqual(model.historyRecords.count, 1)
        XCTAssertEqual(model.visibleProjectSessions.map(\.fileName), ["updated.jsonl"])

        model.rescan()
        try await waitUntil { !model.isScanning }
        XCTAssertEqual(model.visibleProjectSessions.map(\.fileName), ["updated.jsonl"])
        XCTAssertTrue(model.selectedItems.isEmpty, "Rescanning must require a new selection for changed content")
        model.sidebarSelection = .allClients
        XCTAssertEqual(model.selectedItems.map(\.id), [other.id])
    }

    @MainActor
    private func makeViewModel(
        home: URL,
        scanEngine: (any ScanPerforming)? = nil,
        trashPerformer: (any TrashPerforming)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
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
            scanEngine: scanEngine,
            now: now
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
