@testable import AICleanerApp
import AICleanerCore
import AppKit
import Foundation
import os
import SwiftUI
import XCTest

private struct VirtualizedTestTrashPerformer: TrashPerforming {
    let trashDirectory: URL

    func trashItem(at url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = trashDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class VirtualizedItemTableViewTests: XCTestCase {
    // MARK: - 1. 5,000+ 行真正 Cell 复用与全表滚动有界内存验证

    @MainActor
    func testFiveThousandRowsCellReuseAndBoundedAllocationsAcrossFullScrollSweep() throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSyntheticLargeReport(
            home: home,
            recommendedCount: 2_600,
            reviewCount: 2_500,
            notRecommendedCount: 120
        )
        // 展开「不建议清理」分组，确保超过 5,200 行全部纳入可滚动列表
        model.collapsedSections = []
        XCTAssertGreaterThan(model.displayedRows.count, 5_200)

        let controller = VirtualizedItemTableController()
        let window = attachToOffscreenWindow(controller.scrollView, size: NSSize(width: 920, height: 640))
        defer {
            controller.teardown()
            window.orderOut(nil)
        }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: controller.tableView)

        let tableView = controller.tableView
        let scrollView = controller.scrollView
        let coordinator = controller.coordinator

        // 验证原生 NSTableView 核心虚拟化配置
        XCTAssertFalse(tableView.usesAutomaticRowHeights)
        XCTAssertEqual(tableView.style, .plain)
        XCTAssertNil(tableView.headerView)
        XCTAssertEqual(tableView.backgroundColor, .clear)
        XCTAssertEqual(tableView.selectionHighlightStyle, .none)
        XCTAssertEqual(tableView.intercellSpacing, .zero)
        XCTAssertFalse(tableView.floatsGroupRows)
        XCTAssertEqual(scrollView.contentInsets.bottom, VirtualizedItemTableMetrics.bottomScrollInset, accuracy: 0.5)
        XCTAssertEqual(tableView.activeHoverTrackingAreaCount, 1)
        XCTAssertEqual(tableView.numberOfRows, model.displayedRows.count)

        // 验证 O(1) 固定行高：首组头 36pt、数据行 54pt、后续分组头 48pt
        XCTAssertEqual(coordinator.tableView(tableView, heightOfRow: 0), 36, accuracy: 0.1)
        XCTAssertEqual(coordinator.tableView(tableView, heightOfRow: 1), 54, accuracy: 0.1)
        let secondHeaderRow = try XCTUnwrap(model.displayedRows.enumerated().first { idx, row in
            if idx > 0, case .sectionHeader = row { return true }
            return false
        }?.offset)
        XCTAssertEqual(coordinator.tableView(tableView, heightOfRow: secondHeaderRow), 48, accuracy: 0.1)

        // 程序化滚动遍历：顶部 -> 多档中部 -> 底部 -> 中部 -> 顶部
        let maxY = coordinator.maxScrollOriginY()
        XCTAssertGreaterThan(maxY, 200_000)

        let stops: [CGFloat] = [0.0, 0.08, 0.22, 0.40, 0.55, 0.72, 0.88, 1.0, 0.50, 0.15, 0.0]
        for fraction in stops {
            let targetY = maxY * fraction
            coordinator.scrollToOffsetY(targetY)
            layoutWindow(window, tableView: tableView)
        }

        // 证明真正触发了 makeView(withIdentifier:) 对象池复用，且创建/活跃 Cell 实例数恒定有界
        XCTAssertGreaterThan(coordinator.createdItemCellCount, 0)
        XCTAssertGreaterThan(coordinator.reusedItemCellCount, 0)
        XCTAssertLessThan(
            coordinator.createdItemCellCount,
            160,
            "5,200+ 行滚动遍历不应线性创建 Cell，实际创建了 \(coordinator.createdItemCellCount) 个"
        )
        XCTAssertLessThan(
            coordinator.liveItemCellCount,
            160,
            "活跃 ItemRowTableCellView 实例数应维持在可视区常数级，实际为 \(coordinator.liveItemCellCount)"
        )

        // 确认纯 AppKit Cell 内部不包含任何 SwiftUI NSHostingView
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        for rowIndex in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) {
                XCTAssertFalse(containsHostingView(cell), "Cell 内部禁止嵌套重型 SwiftUI NSHostingView")
            }
        }
    }

    // MARK: - 2. 单项勾选与分组全选/取消全选绝不重置滚动偏移、绝不全表 reloadData

    @MainActor
    func testSingleAndSectionBulkSelectionPreserveScrollPositionWithoutReloadData() throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSyntheticLargeReport(
            home: home,
            recommendedCount: 2_600,
            reviewCount: 2_500,
            notRecommendedCount: 40
        )

        let controller = VirtualizedItemTableController()
        let window = attachToOffscreenWindow(controller.scrollView, size: NSSize(width: 920, height: 640))
        defer {
            controller.teardown()
            window.orderOut(nil)
        }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: controller.tableView)

        let tableView = controller.tableView
        let scrollView = controller.scrollView
        let coordinator = controller.coordinator

        // 先滚动到第二组分组头附近（约第 2,601 行，远离顶部）
        let reviewHeaderIndex = try XCTUnwrap(model.displayedRows.enumerated().first { _, row in
            if case let .sectionHeader(header) = row, header.recommendation == .reviewSuggested {
                return true
            }
            return false
        }?.offset)
        let targetOriginY = tableView.rect(ofRow: reviewHeaderIndex).minY
        XCTAssertGreaterThan(targetOriginY, 100_000)

        coordinator.scrollToOffsetY(targetOriginY)
        layoutWindow(window, tableView: tableView)

        let savedY = scrollView.contentView.bounds.origin.y
        XCTAssertEqual(savedY, targetOriginY, accuracy: 2.0)
        let reloadCountBefore = coordinator.reloadDataCount

        // 1) 通过可见行复选框勾选单条条目
        let firstReviewItemRowIndex = reviewHeaderIndex + 1
        let itemCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: firstReviewItemRowIndex, makeIfNecessary: false) as? ItemRowTableCellView
        )
        let targetRowID = try XCTUnwrap(itemCell.currentRowID)
        XCTAssertFalse(itemCell.isCurrentlySelected)

        itemCell.checkboxControl.performClick(nil)
        controller.apply(viewModel: model, colorScheme: .light)

        XCTAssertTrue(model.isSelected(itemID: targetRowID))
        XCTAssertTrue(itemCell.isCurrentlySelected)
        XCTAssertEqual(coordinator.reloadDataCount, reloadCountBefore, "单项勾选绝不可触发整表 reloadData")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, savedY, accuracy: 0.5, "单项勾选绝不可重置滚动偏移")

        // 2) 点击分组头「全选本组」与「取消本组」
        let headerCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: reviewHeaderIndex, makeIfNecessary: false) as? SectionHeaderTableCellView
        )
        XCTAssertFalse(headerCell.isCurrentlyAllBulkSelected)

        headerCell.bulkActionButton.performClick(nil)
        controller.apply(viewModel: model, colorScheme: .light)

        XCTAssertTrue(model.isSectionAllBulkSelected(.reviewSuggested))
        XCTAssertTrue(headerCell.isCurrentlyAllBulkSelected)
        XCTAssertTrue(itemCell.isCurrentlySelected)
        XCTAssertEqual(coordinator.reloadDataCount, reloadCountBefore, "全选本组绝不可触发整表 reloadData")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, savedY, accuracy: 0.5, "全选本组绝不可重置滚动偏移")

        headerCell.bulkActionButton.performClick(nil)
        controller.apply(viewModel: model, colorScheme: .light)

        XCTAssertFalse(model.isSectionAllBulkSelected(.reviewSuggested))
        XCTAssertFalse(headerCell.isCurrentlyAllBulkSelected)
        XCTAssertFalse(itemCell.isCurrentlySelected)
        XCTAssertEqual(coordinator.reloadDataCount, reloadCountBefore, "取消本组绝不可触发整表 reloadData")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, savedY, accuracy: 0.5, "取消本组绝不可重置滚动偏移")

        // 3) 全局反选 / 清空选择同样仅局部刷新且不丢滚动位置
        model.invertVisibleSelection()
        controller.apply(viewModel: model, colorScheme: .light)
        XCTAssertEqual(coordinator.reloadDataCount, reloadCountBefore)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, savedY, accuracy: 0.5)

        model.clearAllSelection()
        controller.apply(viewModel: model, colorScheme: .light)
        XCTAssertEqual(coordinator.reloadDataCount, reloadCountBefore)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, savedY, accuracy: 0.5)
    }

    // MARK: - 3. 单实例悬停追踪、滚动期间自动暂停与仅局部刷新最多 2 行

    @MainActor
    func testSingleHoverTrackingPausesDuringLiveScrollAndUpdatesVisiblyWithoutReload() throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSyntheticLargeReport(
            home: home,
            recommendedCount: 200,
            reviewCount: 50,
            notRecommendedCount: 0
        )

        let controller = VirtualizedItemTableController()
        let window = attachToOffscreenWindow(controller.scrollView, size: NSSize(width: 920, height: 640))
        defer {
            controller.teardown()
            window.orderOut(nil)
        }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: controller.tableView)

        let tableView = controller.tableView
        let scrollView = controller.scrollView
        let coordinator = controller.coordinator
        let reloadBefore = coordinator.reloadDataCount

        let row1Cell = try XCTUnwrap(tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? ItemRowTableCellView)
        let row2Cell = try XCTUnwrap(tableView.view(atColumn: 0, row: 2, makeIfNecessary: false) as? ItemRowTableCellView)
        XCTAssertFalse(row1Cell.isFinderButtonVisible)
        XCTAssertFalse(row2Cell.isFinderButtonVisible)

        // 悬停到第 1 行卡片内
        let row1Rect = tableView.rect(ofRow: 1)
        coordinator.handleHoverPoint(NSPoint(x: 120, y: row1Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, 1)
        XCTAssertTrue(row1Cell.isCurrentlyHovered)
        XCTAssertTrue(row1Cell.isFinderButtonVisible)
        XCTAssertFalse(row2Cell.isCurrentlyHovered)
        XCTAssertEqual(coordinator.reloadDataCount, reloadBefore)

        // 移至第 2 行：旧行熄灭、新行亮起
        let row2Rect = tableView.rect(ofRow: 2)
        coordinator.handleHoverPoint(NSPoint(x: 120, y: row2Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, 2)
        XCTAssertFalse(row1Cell.isCurrentlyHovered)
        XCTAssertFalse(row1Cell.isFinderButtonVisible)
        XCTAssertTrue(row2Cell.isCurrentlyHovered)
        XCTAssertTrue(row2Cell.isFinderButtonVisible)
        XCTAssertEqual(coordinator.reloadDataCount, reloadBefore)

        // 移入左右 20pt 留白区或分组头：清除悬停态
        coordinator.handleHoverPoint(NSPoint(x: 8, y: row2Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, -1)
        XCTAssertFalse(row2Cell.isCurrentlyHovered)

        coordinator.handleHoverPoint(NSPoint(x: 120, y: row2Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, 2)

        // 触发 live scroll：暂停 hover 并立即清除当前悬停行
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        XCTAssertTrue(coordinator.isLiveScrolling)
        XCTAssertEqual(coordinator.hoveredRow, -1)
        XCTAssertFalse(row2Cell.isCurrentlyHovered)

        let hoverRefreshWhileScrolling = coordinator.hoverRefreshCount
        coordinator.handleHoverPoint(NSPoint(x: 120, y: row1Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, -1, "滚动期间必须暂停悬停刷新")
        XCTAssertEqual(coordinator.hoverRefreshCount, hoverRefreshWhileScrolling)

        // 滚动结束：恢复悬停响应
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        XCTAssertFalse(coordinator.isLiveScrolling)

        coordinator.handleHoverPoint(NSPoint(x: 120, y: row1Rect.midY))
        XCTAssertEqual(coordinator.hoveredRow, 1)
        XCTAssertTrue(row1Cell.isCurrentlyHovered)
        XCTAssertEqual(coordinator.reloadDataCount, reloadBefore)
    }

    // MARK: - 4. 单实例右键菜单覆盖普通项 / 已选项 / 高风险项 / 硬保护项与完整回调

    @MainActor
    func testSharedContextMenuGeneratesDynamicItemsForAllRowCategoriesAndTriggersActions() throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let cleanableURL = home.appendingPathComponent(".claude/cache/normal.bin")
        let riskURL = home.appendingPathComponent(".claude/plugins/plugin.bundle")
        let hardProtectedURL = home.appendingPathComponent(".claude/credentials.json")
        try writeFixture("normal", to: cleanableURL)
        try writeFixture("plugin", to: riskURL)
        try writeFixture("secret", to: hardProtectedURL)

        let now = Date()
        let cleanableItem = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "claude-cache",
            displayName: "常规缓存文件",
            fileName: "normal.bin",
            url: cleanableURL,
            category: .cache,
            recommendation: .recommended,
            safetyNote: "缓存可安全清理",
            sizeBytes: 4096,
            fileCount: 1,
            modifiedAt: now,
            isDirectory: false,
            isCustom: false
        )
        let riskItem = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "claude-plugins",
            displayName: "已装插件包",
            fileName: "plugin.bundle",
            url: riskURL,
            category: .protectedData,
            recommendation: .notRecommended,
            safetyNote: "删除后需要重装插件",
            sizeBytes: 8192,
            fileCount: 1,
            modifiedAt: now,
            isDirectory: false,
            isCustom: false
        )
        let hardProtectedItem = CleanableItem(
            clientID: "claude-code",
            clientName: "Claude Code",
            ruleID: "claude-creds",
            displayName: "登录凭据",
            fileName: "credentials.json",
            url: hardProtectedURL,
            category: .protectedData,
            recommendation: .notRecommended,
            safetyNote: "凭据受硬保护",
            sizeBytes: 512,
            fileCount: 1,
            modifiedAt: now,
            isDirectory: false,
            isCustom: false,
            hardProtectionReason: "登录态与密钥受硬保护，不可勾选"
        )

        let model = makeViewModel(home: home)
        model.report = makeSingleClientReport(cleanable: [cleanableItem], protected: [riskItem, hardProtectedItem])
        model.collapsedSections = []

        let controller = VirtualizedItemTableController()
        let window = attachToOffscreenWindow(controller.scrollView, size: NSSize(width: 920, height: 640))
        defer {
            controller.teardown()
            window.orderOut(nil)
        }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: controller.tableView)

        let coordinator = controller.coordinator
        let menu = coordinator.sharedContextMenu
        XCTAssertTrue(controller.tableView.menu === menu)

        let cleanableRow = try rowIndex(forItemID: cleanableItem.id, in: model.displayedRows)
        let riskRow = try rowIndex(forItemID: riskItem.id, in: model.displayedRows)
        let hardRow = try rowIndex(forItemID: hardProtectedItem.id, in: model.displayedRows)

        // 1) 普通未选项
        coordinator.populateContextMenu(menu, forRow: cleanableRow)
        XCTAssertEqual(nonSeparatorTitles(in: menu), [
            "勾选此项",
            "排除此条目（不再显示）",
            "在 Finder 中显示",
            "复制完整路径"
        ])

        // 触发「勾选此项」回调
        triggerMenuItem(titled: "勾选此项", in: menu)
        XCTAssertTrue(model.isSelected(cleanableItem))

        // 2) 普通已选项 -> 标题变为「取消勾选」
        coordinator.populateContextMenu(menu, forRow: cleanableRow)
        XCTAssertEqual(nonSeparatorTitles(in: menu), [
            "取消勾选",
            "排除此条目（不再显示）",
            "在 Finder 中显示",
            "复制完整路径"
        ])

        // 3) 高风险可覆盖项 -> 「勾选并确认风险…」触发二次确认弹窗状态
        coordinator.populateContextMenu(menu, forRow: riskRow)
        XCTAssertEqual(nonSeparatorTitles(in: menu), [
            "勾选并确认风险…",
            "排除此条目（不再显示）",
            "在 Finder 中显示",
            "复制完整路径"
        ])
        triggerMenuItem(titled: "勾选并确认风险…", in: menu)
        XCTAssertEqual(model.pendingRiskItemToSelect?.id, riskItem.id)
        XCTAssertFalse(model.isSelected(riskItem))

        model.confirmRiskItemSelection(riskItem)
        controller.apply(viewModel: model, colorScheme: .light)
        XCTAssertTrue(model.isSelected(riskItem))
        let riskCell = try XCTUnwrap(
            controller.tableView.view(atColumn: 0, row: riskRow, makeIfNecessary: false) as? ItemRowTableCellView
        )
        XCTAssertTrue(riskCell.isRiskSelectedBadgeVisible)

        coordinator.populateContextMenu(menu, forRow: riskRow)
        XCTAssertEqual(nonSeparatorTitles(in: menu).first, "取消勾选")

        // 4) 硬保护项 -> 自动隐藏勾选操作
        coordinator.populateContextMenu(menu, forRow: hardRow)
        XCTAssertEqual(nonSeparatorTitles(in: menu), [
            "排除此条目（不再显示）",
            "在 Finder 中显示",
            "复制完整路径"
        ])

        // 5) 复制完整路径回调
        triggerMenuItem(titled: "复制完整路径", in: menu)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), hardProtectedItem.url.path)

        // 6) 排除此条目回调
        coordinator.populateContextMenu(menu, forRow: cleanableRow)
        triggerMenuItem(titled: "排除此条目（不再显示）", in: menu)
        controller.apply(viewModel: model, colorScheme: .light)
        XCTAssertFalse(model.displayedRows.contains { row in
            if case let .item(displayRow) = row { return displayRow.id == cleanableItem.id }
            return false
        })
        XCTAssertEqual(model.excludedItems.count, 1)
    }

    // MARK: - 5. 单实例完整会话标题弹窗、原位扣减、右键排除保位、视口重置与浅深色切换

    @MainActor
    func testSinglePopoverInPlaceCleanupExcludeScrollPreservationAndAppearanceSwitching() async throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let trashDir = home.appendingPathComponent(".mock-trash", isDirectory: true)
        let model = makeViewModel(home: home, trashPerformer: VirtualizedTestTrashPerformer(trashDirectory: trashDir))

        let now = Date()
        let longTitleA = "第一条超长会话标题：" + String(repeating: "原生 NSTableView 虚拟化验证 ", count: 16)
        let longTitleB = "第二条超长会话标题：" + String(repeating: "单实例 NSPopover 切换验证 ", count: 14)

        var items: [CleanableItem] = []
        items.reserveCapacity(140)

        let sessionAURL = home.appendingPathComponent(".claude/projects/demo/session-a.jsonl")
        let sessionBURL = home.appendingPathComponent(".claude/projects/demo/session-b.jsonl")
        let tmpRecentURL = home.appendingPathComponent(".tmp-fixture/recent-tmp.log")
        try writeFixture("session-a", to: sessionAURL)
        try writeFixture("session-b", to: sessionBURL)
        try writeFixture("tmp-recent", to: tmpRecentURL)

        items.append(
            CleanableItem(
                clientID: "claude-code",
                clientName: "Claude Code",
                ruleID: "claude-sessions",
                displayName: longTitleA,
                fileName: "session-a.jsonl",
                url: sessionAURL,
                category: .sessions,
                recommendation: .reviewSuggested,
                safetyNote: "对话会话文件",
                sizeBytes: 5_000_000,
                fileCount: 1,
                modifiedAt: now.addingTimeInterval(-40 * 86_400),
                isDirectory: false,
                isCustom: false,
                sessionTitle: longTitleA,
                sessionProjectName: "demo"
            )
        )
        items.append(
            CleanableItem(
                clientID: "claude-code",
                clientName: "Claude Code",
                ruleID: "claude-sessions",
                displayName: longTitleB,
                fileName: "session-b.jsonl",
                url: sessionBURL,
                category: .sessions,
                recommendation: .reviewSuggested,
                safetyNote: "对话会话文件",
                sizeBytes: 4_800_000,
                fileCount: 1,
                modifiedAt: now.addingTimeInterval(-35 * 86_400),
                isDirectory: false,
                isCustom: false,
                sessionTitle: longTitleB,
                sessionProjectName: "demo"
            )
        )
        items.append(
            CleanableItem(
                clientID: "claude-code",
                clientName: "Claude Code",
                ruleID: "claude-tmp",
                displayName: "近期修改临时项",
                fileName: "recent-tmp.log",
                url: tmpRecentURL,
                category: .temporary,
                recommendation: .recommended,
                safetyNote: "24 小时内修改的临时文件",
                sizeBytes: 9_000_000,
                fileCount: 1,
                modifiedAt: now,
                isDirectory: false,
                isCustom: false,
                requiresIndividualSelection: true,
                sourceBadge: "临时文件（/tmp）",
                isRecentlyModified: true
            )
        )

        for idx in 0..<120 {
            let fileURL = home.appendingPathComponent(".claude/cache/item-\(idx).bin")
            try writeFixture("cache-\(idx)", to: fileURL)
            items.append(
                CleanableItem(
                    clientID: "claude-code",
                    clientName: "Claude Code",
                    ruleID: "claude-cache",
                    displayName: "缓存分片 #\(idx)",
                    fileName: "item-\(idx).bin",
                    url: fileURL,
                    category: .cache,
                    recommendation: .recommended,
                    safetyNote: "缓存文件可重建",
                    sizeBytes: Int64(2_000_000 - idx * 1_000),
                    fileCount: 1,
                    modifiedAt: now.addingTimeInterval(-Double(idx) * 3600),
                    isDirectory: false,
                    isCustom: false
                )
            )
        }

        model.report = makeSingleClientReport(cleanable: items, protected: [])

        let controller = VirtualizedItemTableController()
        let window = attachToOffscreenWindow(controller.scrollView, size: NSSize(width: 920, height: 520))
        defer {
            controller.teardown()
            window.orderOut(nil)
        }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: controller.tableView)

        let tableView = controller.tableView
        let scrollView = controller.scrollView
        let coordinator = controller.coordinator

        // 1) 验证 /tmp 徽标与「近期修改」徽标渲染状态
        let tmpRowIndex = try rowIndex(forItemID: items[2].id, in: model.displayedRows)
        let tmpCell = try XCTUnwrap(tableView.view(atColumn: 0, row: tmpRowIndex, makeIfNecessary: false) as? ItemRowTableCellView)
        XCTAssertTrue(tmpCell.isSourceBadgeVisible)
        XCTAssertTrue(tmpCell.isRecentBadgeVisible)
        XCTAssertFalse(tmpCell.isFullTitleButtonVisible)

        // 2) 滚动到会话分组并验证单实例「查看完整会话标题」NSPopover 展示与切换
        let sessionARow = try rowIndex(forItemID: items[0].id, in: model.displayedRows)
        let sessionBRow = try rowIndex(forItemID: items[1].id, in: model.displayedRows)
        let sessionOffsetY = max(0, tableView.rect(ofRow: sessionARow).minY - 60)
        coordinator.scrollToOffsetY(sessionOffsetY)
        layoutWindow(window, tableView: tableView)

        let cellA = try XCTUnwrap(tableView.view(atColumn: 0, row: sessionARow, makeIfNecessary: false) as? ItemRowTableCellView)
        let cellB = try XCTUnwrap(tableView.view(atColumn: 0, row: sessionBRow, makeIfNecessary: false) as? ItemRowTableCellView)
        XCTAssertTrue(cellA.isFullTitleButtonVisible)
        XCTAssertTrue(cellB.isFullTitleButtonVisible)

        cellA.fullTitleButton.performClick(nil)
        XCTAssertEqual(coordinator.activePopoverItemID, items[0].id)
        XCTAssertEqual(coordinator.fullTitlePopoverController.currentTitleText, longTitleA)

        // 点击另一条会话行完整标题按钮 -> 复用同一单实例 NSPopover 切换文案
        cellB.fullTitleButton.performClick(nil)
        XCTAssertEqual(coordinator.activePopoverItemID, items[1].id)
        XCTAssertEqual(coordinator.fullTitlePopoverController.currentTitleText, longTitleB)

        // 切换浅/深色外观 -> 同步更新弹窗外观与可见 Cell 外观
        window.appearance = NSAppearance(named: .darkAqua)
        controller.apply(viewModel: model, colorScheme: .dark)
        XCTAssertEqual(
            coordinator.fullTitlePopover.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua
        )

        window.appearance = NSAppearance(named: .aqua)
        controller.apply(viewModel: model, colorScheme: .light)
        XCTAssertEqual(
            coordinator.fullTitlePopover.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            .aqua
        )

        // 滚动触发关闭弹窗（会话行位于列表底部，向上滚动确保 clipView 发生真实位移）
        let scrolledY = max(0, scrollView.contentView.bounds.origin.y - 240)
        coordinator.scrollToOffsetY(scrolledY)
        layoutWindow(window, tableView: tableView)
        XCTAssertNil(coordinator.activePopoverItemID)
        XCTAssertFalse(coordinator.fullTitlePopover.isShown)

        // 3) 右键排除条目（原位更新）保持当前滚动位置不跳回顶部
        let midScrollY: CGFloat = 1_800
        coordinator.scrollToOffsetY(midScrollY)
        layoutWindow(window, tableView: tableView)
        let offsetBeforeExclude = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(offsetBeforeExclude, 1_000)

        let excludeTarget = items[40]
        let viewportBeforeExclude = model.listViewportID
        model.excludeItem(excludeTarget)
        XCTAssertEqual(model.listViewportID, viewportBeforeExclude)
        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: tableView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, offsetBeforeExclude, accuracy: 2.0)

        // 4) 清理后原位扣减（AICL-18）同样保持当前滚动位置不跳回顶部
        let cleanupTarget = items[45]
        model.toggleSelection(for: cleanupTarget)
        controller.apply(viewModel: model, colorScheme: .light)

        let offsetBeforeCleanup = scrollView.contentView.bounds.origin.y
        model.confirmAndTrashSelectedItems()
        try await waitUntil { !model.isCleaning && model.lastCleanupResult != nil }

        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: tableView)
        XCTAssertEqual(model.lastCleanupResult?.trashedCount, 1)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, offsetBeforeCleanup, accuracy: 2.0)

        // 5) 切换筛选 / 搜索导致 listViewportID 变化 -> 瞬时滚回顶部
        model.searchText = "缓存分片"
        controller.apply(viewModel: model, colorScheme: .light)
        layoutWindow(window, tableView: tableView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)

        // 6) Teardown 彻底清理观察者防止泄漏
        XCTAssertGreaterThan(coordinator.activeObserverCount, 0)
        controller.teardown()
        XCTAssertEqual(coordinator.activeObserverCount, 0)
    }

    // MARK: - 6. SwiftUI ItemListView + VirtualizedItemTableView 浅/深色端到端布局验证

    @MainActor
    func testSwiftUIVirtualizedItemListViewLayoutsCleanlyInLightAndDarkModes() {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSyntheticLargeReport(
            home: home,
            recommendedCount: 2_600,
            reviewCount: 2_500,
            notRecommendedCount: 20
        )

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let hosting = NSHostingView(
                rootView: ItemListView(viewModel: model)
                    .frame(width: 960, height: 680)
                    .preferredColorScheme(scheme)
            )
            let window = attachToOffscreenWindow(hosting, size: NSSize(width: 960, height: 680))
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
            window.orderOut(nil)
        }
    }

    @MainActor
    func testPopulatedTableReportsViewportSizeForSwiftUIProposals() throws {
        _ = NSApplication.shared
        let home = makeTempSandbox()
        let model = makeViewModel(home: home)

        for count in [160, 5_100] {
            model.report = makeSyntheticLargeReport(
                home: home,
                recommendedCount: count,
                reviewCount: 0,
                notRecommendedCount: 0
            )
            let measurements = OSAllocatedUnfairLock(initialState: Optional<TableProposalSizes>.none)
            let hosting = NSHostingView(rootView: MeasureTableProposals(measurements: measurements) {
                VirtualizedItemTableView(
                    rows: model.displayedRows,
                    rowsRevision: model.displayedRowsRevision,
                    selectionRevision: model.selectionRevision,
                    viewportID: model.listViewportID,
                    colorScheme: .light,
                    viewModel: model
                )
            })
            let window = attachToOffscreenWindow(hosting, size: NSSize(width: 920, height: 640))
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()

            let table = try XCTUnwrap(descendants(of: hosting).compactMap { $0 as? ItemTableView }.first)
            XCTAssertGreaterThanOrEqual(table.numberOfRows, count)
            XCTAssertGreaterThan(table.rect(ofRow: table.numberOfRows - 1).maxY, 8_000)
            let viewport = try XCTUnwrap(table.enclosingScrollView)
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                XCTAssertEqual(viewport.contentHuggingPriority(for: axis), .defaultLow)
                XCTAssertEqual(viewport.contentCompressionResistancePriority(for: axis), .defaultLow)
            }

            let sizes = try XCTUnwrap(measurements.withLock { $0 })
            XCTAssertEqual(sizes.finite, CGSize(width: 752, height: 403))
            XCTAssertEqual(sizes.zero, .zero)
            XCTAssertEqual(sizes.mixed.width, 752)
            XCTAssertEqual(sizes.zeroHeight.height, 0)
            for size in [sizes.unspecified, sizes.infinity] {
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, 920)
                XCTAssertLessThanOrEqual(size.height, 640)
            }
            XCTAssertEqual(sizes.mixed.height, sizes.unspecified.height)
        }
    }

    @MainActor
    func testWindowKeepsBothColumnsInBoundsWhenSwitchingToUnattributedTemp() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }

        let home = makeTempSandbox()
        let model = makeViewModel(home: home)
        let builtIn = Array(BuiltInClientRules.allProfiles.prefix(24))
        let unattributed = TempDirectoryScanner.unattributedTempProfile()
        let otherTemp = TempDirectoryScanner.otherAITempProfile()
        let profiles = builtIn + [unattributed, otherTemp]
        model.report = ScanReport(
            clientSummaries: profiles.map { profile in
                let isUnattributed = profile.id == unattributed.id
                let items = (0..<(isUnattributed ? 130 : 1)).map { index in
                    let name = "layout-fixture-\(index).tmp"
                    return CleanableItem(
                        clientID: profile.id, clientName: profile.name,
                        ruleID: "layout-fixture", displayName: name, fileName: name,
                        url: home.appendingPathComponent(profile.id).appendingPathComponent(name),
                        category: .temporary, recommendation: isUnattributed ? .reviewSuggested : .recommended,
                        safetyNote: "布局测试", sizeBytes: 1_024, fileCount: 1,
                        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        isDirectory: false, isCustom: false, requiresIndividualSelection: isUnattributed
                    )
                }
                return ClientScanSummary(profile: profile, items: items)
            },
            totalBuiltInProfilesCount: builtIn.count,
            detectedBuiltInClientsCount: builtIn.count
        )
        XCTAssertGreaterThanOrEqual(model.builtInSidebarEntries.count, 20)

        let hosting = NSHostingView(rootView: ContentView(viewModel: model)
            .environment(\.itemListLayoutProbe) { region in AnyView(ItemListFrameProbe(region: region)) })
        let window = attachToOffscreenWindow(hosting, size: NSSize(width: 1180, height: 760))
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "LayoutRegressionToolbar")
        window.toolbarStyle = .unified
        window.orderBack(nil)

        var bannerHeights: [CGFloat] = []
        for size in [NSSize(width: 1020, height: 660), NSSize(width: 1180, height: 760)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            layoutHostedWindow(window)
            for selection in [
                SidebarSelection.allClients, .client(unattributed.id), .client(builtIn[0].id),
                .client(otherTemp.id), .history, .excluded, .allClients
            ] {
                model.sidebarSelection = selection
                layoutHostedWindow(window)
                let visibleBounds = window.contentLayoutRect.insetBy(dx: -1, dy: -1)
                XCTAssertEqual(window.frame.size, size, "\(selection)")

                let views = descendants(of: hosting)
                let scrollViews = views.compactMap { $0 as? NSScrollView }
                let sidebar = try XCTUnwrap(scrollViews.first { scroll in
                    scroll.bounds.width > 0 && scroll.bounds.width <= 300
                }, "侧栏缺少滚动视口")
                let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
                XCTAssertLessThanOrEqual(sidebarFrame.height, window.contentLayoutRect.height)
                XCTAssertTrue(visibleBounds.contains(sidebarFrame), "\(selection): \(sidebarFrame)")

                if selection.isListScope {
                    let table = try XCTUnwrap(scrollViews.first { $0.documentView is ItemTableView })
                    let tableFrame = table.convert(table.bounds, to: nil)
                    XCTAssertGreaterThan(tableFrame.height, 0)
                    XCTAssertTrue(visibleBounds.contains(tableFrame), "\(selection): \(tableFrame)")

                    let probes = views.compactMap { $0 as? ItemListFrameProbe.FrameView }
                    let regions: [ItemListLayoutRegion] = selection == .client(unattributed.id)
                        ? [.dashboard, .controls, .scopeNotice]
                        : [.dashboard, .controls]
                    var previousBottom = visibleBounds.maxY
                    for region in regions {
                        let probe = try XCTUnwrap(probes.first { $0.region == region }, "\(region)")
                        let frame = probe.convert(probe.bounds, to: nil)
                        XCTAssertFalse(frame.isEmpty, "\(region)")
                        XCTAssertTrue(visibleBounds.contains(frame), "\(region): \(frame)")
                        XCTAssertLessThanOrEqual(frame.maxY, previousBottom + 1, "\(region)")
                        previousBottom = frame.minY
                        if region == .scopeNotice { bannerHeights.append(frame.height) }
                    }
                    XCTAssertLessThanOrEqual(tableFrame.maxY, previousBottom + 1)
                }

                if selection == .client(unattributed.id) {
                    XCTAssertEqual(model.filteredItems.count, 130)
                    XCTAssertNotNil(model.scopeNoticeBanner)
                    let clip = sidebar.contentView
                    let top = clip.bounds.origin
                    let document = try XCTUnwrap(sidebar.documentView)
                    XCTAssertGreaterThan(document.bounds.height, clip.bounds.height)
                    let scrolledBounds = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: 200))
                    clip.scroll(to: scrolledBounds.origin)
                    sidebar.reflectScrolledClipView(clip)
                    layoutHostedWindow(window)
                    XCTAssertGreaterThan(clip.bounds.origin.y, top.y, "切到未归属分组后侧栏应当可滚动")
                    clip.scroll(to: top)
                    sidebar.reflectScrolledClipView(clip)
                }
            }
        }
        XCTAssertEqual(bannerHeights.count, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(bannerHeights.first), try XCTUnwrap(bannerHeights.last))
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func layoutHostedWindow(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
    }

    // MARK: - Test Helpers

    private func makeTempSandbox() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aicleaner-nstableview-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeFixture(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    @MainActor
    private func makeViewModel(
        home: URL,
        trashPerformer: any TrashPerforming = VirtualizedTestTrashPerformer(
            trashDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    ) -> CleanerViewModel {
        let guardInstance = SafetyGuard(homeDirectory: home)
        let configDir = home.appendingPathComponent(".config", isDirectory: true)
        let customStore = CustomDirectoryStore(
            storageURL: configDir.appendingPathComponent("custom.json"),
            safetyGuard: guardInstance
        )
        let historyStore = CleanupHistoryStore(
            storageURL: configDir.appendingPathComponent("history.json")
        )
        let excludedStore = ExcludedItemStore(
            storageURL: configDir.appendingPathComponent("excluded.json")
        )
        let engine = ScanEngine(
            homeDirectory: home,
            safetyGuard: guardInstance,
            systemTempRoot: home.appendingPathComponent("sys-tmp", isDirectory: true),
            userTempRoot: home.appendingPathComponent("user-tmp", isDirectory: true)
        )
        return CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: customStore,
            historyStore: historyStore,
            excludedItemStore: excludedStore,
            trashPerformer: trashPerformer,
            scanEngine: engine
        )
    }

    private func makeSyntheticLargeReport(
        home: URL,
        recommendedCount: Int,
        reviewCount: Int,
        notRecommendedCount: Int
    ) -> ScanReport {
        let now = Date()
        let claudeProfile = BuiltInClientRules.allProfiles.first { $0.id == "claude-code" }
            ?? AIClientProfile(
                id: "claude-code",
                name: "Claude Code",
                symbolName: "terminal",
                accentToken: "claude",
                description: "合成测试客户端",
                protectedSummary: "凭据受保护",
                rules: []
            )
        let codexProfile = BuiltInClientRules.allProfiles.first { $0.id == "codex" }
            ?? AIClientProfile(
                id: "codex",
                name: "Codex",
                symbolName: "cpu",
                accentToken: "codex",
                description: "合成测试客户端 2",
                protectedSummary: "凭据受保护",
                rules: []
            )

        var claudeCleanable: [CleanableItem] = []
        var codexCleanable: [CleanableItem] = []
        var claudeProtected: [CleanableItem] = []
        claudeCleanable.reserveCapacity((recommendedCount + reviewCount) / 2 + 10)
        codexCleanable.reserveCapacity((recommendedCount + reviewCount) / 2 + 10)
        claudeProtected.reserveCapacity(notRecommendedCount)

        for i in 0..<recommendedCount {
            let isClaude = (i % 2 == 0)
            let clientID = isClaude ? claudeProfile.id : codexProfile.id
            let clientName = isClaude ? claudeProfile.name : codexProfile.name
            let item = CleanableItem(
                clientID: clientID,
                clientName: clientName,
                ruleID: "\(clientID)-cache",
                displayName: "合成缓存条目 #\(i)",
                fileName: "cache-\(i).bin",
                url: home.appendingPathComponent(".\(clientID)/cache/cache-\(i).bin"),
                category: (i % 3 == 0) ? .logs : .cache,
                recommendation: .recommended,
                safetyNote: "合成缓存数据，可安全清理",
                sizeBytes: Int64(5_000_000 - (i % 2_000) * 1_024),
                fileCount: 1,
                modifiedAt: now.addingTimeInterval(-Double((i % 90) + 2) * 86_400),
                isDirectory: false,
                isCustom: false,
                sourceBadge: (i % 25 == 0) ? "临时文件（/tmp）" : nil,
                isRecentlyModified: (i % 40 == 0)
            )
            if isClaude {
                claudeCleanable.append(item)
            } else {
                codexCleanable.append(item)
            }
        }

        for i in 0..<reviewCount {
            let isClaude = (i % 2 == 0)
            let clientID = isClaude ? claudeProfile.id : codexProfile.id
            let clientName = isClaude ? claudeProfile.name : codexProfile.name
            let sessionTitle = "合成会话记录 #\(i) · NSTableView 虚拟化滚动压力测试标题"
            let item = CleanableItem(
                clientID: clientID,
                clientName: clientName,
                ruleID: "\(clientID)-sessions",
                displayName: sessionTitle,
                fileName: "session-\(i).jsonl",
                url: home.appendingPathComponent(".\(clientID)/sessions/session-\(i).jsonl"),
                category: .sessions,
                recommendation: .reviewSuggested,
                safetyNote: "历史会话记录，确认无需保留后可清理",
                sizeBytes: Int64(2_500_000 - (i % 1_500) * 512),
                fileCount: 1,
                modifiedAt: now.addingTimeInterval(-Double((i % 120) + 10) * 86_400),
                isDirectory: false,
                isCustom: false,
                sessionTitle: sessionTitle,
                sessionProjectName: "demo-workspace-\(i % 12)"
            )
            if isClaude {
                claudeCleanable.append(item)
            } else {
                codexCleanable.append(item)
            }
        }

        for i in 0..<notRecommendedCount {
            let isHard = (i % 3 == 0)
            claudeProtected.append(
                CleanableItem(
                    clientID: claudeProfile.id,
                    clientName: claudeProfile.name,
                    ruleID: isHard ? "claude-auth" : "claude-plugin",
                    displayName: isHard ? "受保护凭据 #\(i)" : "高风险插件 #\(i)",
                    fileName: "protected-\(i).dat",
                    url: home.appendingPathComponent(".claude/protected/protected-\(i).dat"),
                    category: .protectedData,
                    recommendation: .notRecommended,
                    safetyNote: "核心配置或插件，不建议清理",
                    sizeBytes: Int64(1_000_000 + i * 256),
                    fileCount: 1,
                    modifiedAt: now.addingTimeInterval(-Double(i) * 3600),
                    isDirectory: false,
                    isCustom: false,
                    hardProtectionReason: isHard ? "硬保护凭据不可勾选" : nil
                )
            )
        }

        let summary1 = ClientScanSummary(
            profile: claudeProfile,
            items: claudeCleanable,
            protectedItems: claudeProtected,
            skippedProtectedCount: 0
        )
        let summary2 = ClientScanSummary(
            profile: codexProfile,
            items: codexCleanable,
            protectedItems: [],
            skippedProtectedCount: 0
        )
        return ScanReport(
            scannedAt: now,
            clientSummaries: [summary1, summary2],
            totalBuiltInProfilesCount: BuiltInClientRules.allProfiles.count,
            detectedBuiltInClientsCount: 2,
            skippedProtectedCount: 0
        )
    }

    private func makeSingleClientReport(
        cleanable: [CleanableItem],
        protected: [CleanableItem]
    ) -> ScanReport {
        let profile = BuiltInClientRules.allProfiles.first { $0.id == "claude-code" }
            ?? AIClientProfile(
                id: "claude-code",
                name: "Claude Code",
                symbolName: "terminal",
                accentToken: "claude",
                description: "测试客户端",
                protectedSummary: "凭据受保护",
                rules: []
            )
        return ScanReport(
            scannedAt: Date(),
            clientSummaries: [
                ClientScanSummary(
                    profile: profile,
                    items: cleanable,
                    protectedItems: protected,
                    skippedProtectedCount: 0
                )
            ],
            totalBuiltInProfilesCount: BuiltInClientRules.allProfiles.count,
            detectedBuiltInClientsCount: 1,
            skippedProtectedCount: 0
        )
    }

    @MainActor
    private func attachToOffscreenWindow(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private func layoutWindow(_ window: NSWindow, tableView: NSTableView) {
        window.layoutIfNeeded()
        tableView.tile()
        tableView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }

    private func rowIndex(forItemID id: String, in rows: [FlatListRow]) throws -> Int {
        try XCTUnwrap(rows.enumerated().first { _, row in
            if case let .item(displayRow) = row, displayRow.id == id {
                return true
            }
            return false
        }?.offset)
    }

    @MainActor
    private func nonSeparatorTitles(in menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @MainActor
    private func triggerMenuItem(titled title: String, in menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            XCTFail("未在共享右键菜单中找到菜单项：\(title)")
            return
        }
        menu.performActionForItem(at: index)
    }

    @MainActor
    private func containsHostingView(_ view: NSView) -> Bool {
        let typeName = String(describing: type(of: view))
        if typeName.contains("NSHostingView") {
            return true
        }
        return view.subviews.contains { containsHostingView($0) }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("等待异步条件超时")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private typealias TableProposalSizes = (
    finite: CGSize, zero: CGSize, mixed: CGSize, zeroHeight: CGSize, unspecified: CGSize, infinity: CGSize
)

private struct ItemListFrameProbe: NSViewRepresentable {
    let region: ItemListLayoutRegion

    final class FrameView: NSView {
        var region: ItemListLayoutRegion?
    }

    func makeNSView(context: Context) -> FrameView {
        FrameView()
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.region = region
    }
}

private struct MeasureTableProposals: Layout {
    let measurements: OSAllocatedUnfairLock<TableProposalSizes?>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let table = subviews[0]
        let sizes = (
            table.sizeThatFits(ProposedViewSize(width: 752, height: 403)),
            table.sizeThatFits(.zero),
            table.sizeThatFits(ProposedViewSize(width: 752, height: nil)),
            table.sizeThatFits(ProposedViewSize(width: .infinity, height: 0)),
            table.sizeThatFits(.unspecified),
            table.sizeThatFits(.infinity)
        )
        measurements.withLock { $0 = sizes }
        return CGSize(width: 920, height: 640)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
