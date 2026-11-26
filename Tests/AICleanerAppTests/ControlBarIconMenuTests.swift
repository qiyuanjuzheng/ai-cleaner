@testable import AICleanerApp
import AICleanerCore
import AppKit
import Foundation
import SwiftUI
import XCTest

final class ControlBarIconMenuTests: XCTestCase {
    // MARK: - 1. 筛选/排序/批量勾选菜单构建、选中态、禁用态与动作回调

    @MainActor
    func testFilterMenuBuildsAllSectionsAndExecutesAgeSortAndBulkActions() throws {
        _ = NSApplication.shared
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSampleReport(home: home)

        let initialMenu = ItemControlBarMenuFactory.makeMenu(for: model)
        XCTAssertFalse(initialMenu.autoenablesItems, "NSMenu 必须禁用 autoenablesItems 才能准确反映批量勾选禁用状态")

        // 验证分组标题顺序与分割线
        let sectionTitles = initialMenu.items.compactMap { item -> String? in
            item.isSectionHeader ? item.title : nil
        }
        XCTAssertEqual(sectionTitles, ["时间范围", "排序方式", "批量勾选"])
        XCTAssertEqual(initialMenu.items.filter(\.isSeparatorItem).count, 2)

        // 验证「时间范围」全部项存在，且默认仅 `.all` 打勾
        for filter in ItemAgeFilter.allCases {
            let item = try XCTUnwrap(menuItem(titled: filter.menuTitle, in: initialMenu))
            XCTAssertTrue(item.isEnabled)
            XCTAssertEqual(item.state, filter == .all ? .on : .off)
        }

        // 验证「排序方式」全部项存在，且默认仅 `.sizeDescending` 打勾
        for order in ItemSortOrder.allCases {
            let item = try XCTUnwrap(menuItem(titled: order.menuTitle, in: initialMenu))
            XCTAssertTrue(item.isEnabled)
            XCTAssertEqual(item.state, order == .sizeDescending ? .on : .off)
        }

        // 触发每个时间范围筛选并验证回调与打勾同步
        for filter in ItemAgeFilter.allCases {
            let menu = ItemControlBarMenuFactory.makeMenu(for: model)
            let index = try XCTUnwrap(menuItemIndex(titled: filter.menuTitle, in: menu))
            menu.performActionForItem(at: index)
            XCTAssertEqual(model.selectedAgeFilter, filter)

            let refreshed = ItemControlBarMenuFactory.makeMenu(for: model)
            for candidate in ItemAgeFilter.allCases {
                let candidateItem = try XCTUnwrap(menuItem(titled: candidate.menuTitle, in: refreshed))
                XCTAssertEqual(candidateItem.state, candidate == filter ? .on : .off)
            }
        }
        // 恢复 `.all` 以保留全部样例条目用于后续测试
        model.selectedAgeFilter = .all

        // 触发每个排序方式并验证回调与打勾同步
        for order in ItemSortOrder.allCases {
            let menu = ItemControlBarMenuFactory.makeMenu(for: model)
            let index = try XCTUnwrap(menuItemIndex(titled: order.menuTitle, in: menu))
            menu.performActionForItem(at: index)
            XCTAssertEqual(model.sortOrder, order)

            let refreshed = ItemControlBarMenuFactory.makeMenu(for: model)
            for candidate in ItemSortOrder.allCases {
                let candidateItem = try XCTUnwrap(menuItem(titled: candidate.menuTitle, in: refreshed))
                XCTAssertEqual(candidateItem.state, candidate == order ? .on : .off)
            }
        }
        model.sortOrder = .sizeDescending

        // 验证批量勾选动作与禁用状态流转
        let bulkCount = model.filteredBulkSelectableItems.count
        XCTAssertEqual(bulkCount, 2, "应包含 2 条可批量勾选（建议清理 + 需确认）条目，不包含不建议清理项")

        // 1) 未勾选任何条目：全选启用、反选启用、清空列表选择禁用
        let menuNoneSelected = ItemControlBarMenuFactory.makeMenu(for: model)
        let selectAllTitle = "全选可批量勾选项（\(bulkCount)）"
        let selectAllItem = try XCTUnwrap(menuItem(titled: selectAllTitle, in: menuNoneSelected))
        let invertItem = try XCTUnwrap(menuItem(titled: "反选可批量勾选项", in: menuNoneSelected))
        let clearItem = try XCTUnwrap(menuItem(titled: "清空列表选择", in: menuNoneSelected))
        XCTAssertTrue(selectAllItem.isEnabled)
        XCTAssertTrue(invertItem.isEnabled)
        XCTAssertFalse(clearItem.isEnabled)

        // 2) 点击「全选可批量勾选项（N）」-> 全部可批量勾选项被选中；全选变禁用、清空变启用
        let selectAllIndex = try XCTUnwrap(menuItemIndex(titled: selectAllTitle, in: menuNoneSelected))
        menuNoneSelected.performActionForItem(at: selectAllIndex)
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertEqual(model.visibleSelectedCount, bulkCount)

        let menuAllSelected = ItemControlBarMenuFactory.makeMenu(for: model)
        XCTAssertFalse(try XCTUnwrap(menuItem(titled: selectAllTitle, in: menuAllSelected)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menuItem(titled: "反选可批量勾选项", in: menuAllSelected)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menuItem(titled: "清空列表选择", in: menuAllSelected)).isEnabled)

        // 3) 仅勾选第 1 条后点击「反选可批量勾选项」-> 切换为仅勾选第 2 条
        let firstBulkItem = try XCTUnwrap(model.filteredBulkSelectableItems.first)
        let secondBulkItem = try XCTUnwrap(model.filteredBulkSelectableItems.last)
        model.clearVisibleSelection()
        model.toggleSelection(for: firstBulkItem)
        XCTAssertTrue(model.isSelected(itemID: firstBulkItem.id))
        XCTAssertFalse(model.isSelected(itemID: secondBulkItem.id))

        let menuPartialSelected = ItemControlBarMenuFactory.makeMenu(for: model)
        XCTAssertTrue(try XCTUnwrap(menuItem(titled: selectAllTitle, in: menuPartialSelected)).isEnabled)
        let invertIndex = try XCTUnwrap(menuItemIndex(titled: "反选可批量勾选项", in: menuPartialSelected))
        menuPartialSelected.performActionForItem(at: invertIndex)
        XCTAssertFalse(model.isSelected(itemID: firstBulkItem.id))
        XCTAssertTrue(model.isSelected(itemID: secondBulkItem.id))

        // 4) 点击「清空列表选择」-> 可见选择归零，清空菜单项再次禁用
        let menuBeforeClear = ItemControlBarMenuFactory.makeMenu(for: model)
        let clearIndex = try XCTUnwrap(menuItemIndex(titled: "清空列表选择", in: menuBeforeClear))
        menuBeforeClear.performActionForItem(at: clearIndex)
        XCTAssertEqual(model.visibleSelectedCount, 0)

        let menuAfterClear = ItemControlBarMenuFactory.makeMenu(for: model)
        XCTAssertFalse(try XCTUnwrap(menuItem(titled: "清空列表选择", in: menuAfterClear)).isEnabled)

        // 5) 搜索过滤至无匹配项时，全选/反选/清空全部禁用且数量显示 0
        model.searchText = "__no_matching_item_keyword__"
        let emptyMenu = ItemControlBarMenuFactory.makeMenu(for: model)
        XCTAssertFalse(try XCTUnwrap(menuItem(titled: "全选可批量勾选项（0）", in: emptyMenu)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menuItem(titled: "反选可批量勾选项", in: emptyMenu)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menuItem(titled: "清空列表选择", in: emptyMenu)).isEnabled)
    }

    // MARK: - 2. 清理记录右上角选项菜单（全仓同类坑一并修复）

    @MainActor
    func testCleanupHistoryMenuBuildsDestructiveClearActionAndInvokesCallback() throws {
        _ = NSApplication.shared
        var clearRequested = false
        let menu = CleanupHistoryMenuFactory.makeMenu {
            clearRequested = true
        }

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, 1)
        let clearItem = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(clearItem.title, CleanupHistoryCopy.clearRecordsMenuTitle)
        XCTAssertTrue(clearItem.isEnabled)
        XCTAssertNotNil(clearItem.image)

        menu.performActionForItem(at: 0)
        XCTAssertTrue(clearRequested)
    }

    // MARK: - 3. 30×30 几何尺寸、图标像素居中、整块命中与悬停/按压/展开状态

    @MainActor
    func testControlBarIconMenuControlGeometryPixelCenteringHitTestingAndStates() throws {
        let control = ControlBarIconMenuControl(frame: .zero)
        let window = attachToOffscreenWindow(control, size: ControlBarIconMenuMetrics.buttonSize)
        defer { window.orderOut(nil) }

        for (symbol, weight, label) in [
            ("slider.horizontal.3", NSFont.Weight.medium, ItemControlBarMenuFactory.accessibilityLabel),
            ("ellipsis", NSFont.Weight.semibold, CleanupHistoryCopy.clearOptionsHelp)
        ] {
            control.configure(
                symbolName: symbol,
                symbolWeight: weight,
                accessibilityLabel: label,
                showsIndicatorBadge: true,
                isDarkMode: false,
                reduceMotion: false,
                menuBuilder: {
                    let menu = NSMenu(title: "")
                    menu.autoenablesItems = false
                    menu.addItem(NSMenuItem(title: "测试项", action: nil, keyEquivalent: ""))
                    return menu
                }
            )
            layoutWindow(window)

            // 1) 严格 30 × 30 尺寸
            XCTAssertEqual(control.intrinsicContentSize, CGSize(width: 30, height: 30))
            XCTAssertEqual(control.frame.size.width, 30, accuracy: 0.01)
            XCTAssertEqual(control.frame.size.height, 30, accuracy: 0.01)
            XCTAssertEqual(control.bounds.size.width, 30, accuracy: 0.01)
            XCTAssertEqual(control.bounds.size.height, 30, accuracy: 0.01)

            // 2) 图标 Frame 严格水平垂直居中（0pt 偏移）
            let iconFrame = control.iconImageView.frame
            XCTAssertGreaterThan(iconFrame.width, 0)
            XCTAssertGreaterThan(iconFrame.height, 0)
            XCTAssertEqual(iconFrame.midX, control.bounds.midX, accuracy: 0.01, "\(symbol) 图标水平中心应与 30×30 按钮严格对齐")
            XCTAssertEqual(iconFrame.midY, control.bounds.midY, accuracy: 0.01, "\(symbol) 图标垂直中心应与 30×30 按钮严格对齐")

            // 3) 2x Retina 实际渲染墨迹中心几何断言（允许 <= 0.5pt 像素量化误差，实测 0.0pt）
            let renderedInkCenter = try measureRenderedIconInkCenter(of: control.iconImageView, inContainerSize: control.bounds.size)
            XCTAssertEqual(renderedInkCenter.x, 15.0, accuracy: 0.5, "\(symbol) 实际渲染像素中心 X 偏移")
            XCTAssertEqual(renderedInkCenter.y, 15.0, accuracy: 0.5, "\(symbol) 实际渲染像素中心 Y 偏移")

            // 4) 无障碍标签与提示文案
            XCTAssertEqual(control.accessibilityLabel(), label)
            XCTAssertEqual(control.toolTip, label)

            // 5) 顶部激活绿点位于右上角，且绝不拦截点击
            XCTAssertFalse(control.indicatorBadgeLayer.isHidden)
            XCTAssertEqual(control.indicatorBadgeLayer.frame.origin.x, 21, accuracy: 0.01)
            XCTAssertEqual(control.indicatorBadgeLayer.frame.origin.y, 21, accuracy: 0.01)
            XCTAssertEqual(control.indicatorBadgeLayer.frame.size.width, 6, accuracy: 0.01)
            XCTAssertEqual(control.indicatorBadgeLayer.frame.size.height, 6, accuracy: 0.01)

            // 整块 30×30 区域（含四角、正中及绿点上方）全部命中按钮自身
            let hitPoints: [NSPoint] = [
                NSPoint(x: 1, y: 1),
                NSPoint(x: 29, y: 1),
                NSPoint(x: 1, y: 29),
                NSPoint(x: 29, y: 29),
                NSPoint(x: 15, y: 15),
                NSPoint(x: 24, y: 6) // 激活指示绿点中心
            ]
            for pt in hitPoints {
                XCTAssertTrue(control.hitTest(pt) === control, "点 \(pt) 必须命中 30×30 按钮本身")
            }
            XCTAssertNil(control.hitTest(NSPoint(x: -1, y: 15)))
            XCTAssertNil(control.hitTest(NSPoint(x: 31, y: 15)))
        }

        // 6) 视觉状态流转：normal -> hovered -> pressed(缩放) -> menuOpen -> normal
        XCTAssertEqual(control.visualState, .normal)
        control.setHovered(true)
        XCTAssertEqual(control.visualState, .hovered)

        control.setPressed(true)
        XCTAssertEqual(control.visualState, .pressed)
        XCTAssertEqual(control.currentSurfaceTransform.m11, ControlBarIconMenuMetrics.pressedScale, accuracy: 0.001)
        XCTAssertEqual(control.currentSurfaceTransform.m22, ControlBarIconMenuMetrics.pressedScale, accuracy: 0.001)
        XCTAssertEqual(control.currentSurfaceTransform.m41, 0, accuracy: 0.001)
        XCTAssertEqual(control.currentSurfaceTransform.m42, 0, accuracy: 0.001)

        control.setPressed(false)
        control.setHovered(false)
        XCTAssertEqual(control.visualState, .normal)
        XCTAssertEqual(control.currentSurfaceTransform.m11, 1.0, accuracy: 0.001)

        // reduceMotion 开启时按压不做缩放
        control.configure(
            symbolName: "slider.horizontal.3",
            accessibilityLabel: ItemControlBarMenuFactory.accessibilityLabel,
            showsIndicatorBadge: false,
            isDarkMode: true,
            reduceMotion: true,
            menuBuilder: {
                let menu = NSMenu(title: "")
                menu.autoenablesItems = false
                menu.addItem(NSMenuItem(title: "测试项", action: nil, keyEquivalent: ""))
                return menu
            }
        )
        XCTAssertTrue(control.indicatorBadgeLayer.isHidden)
        control.setPressed(true)
        XCTAssertEqual(control.currentSurfaceTransform.m11, 1.0, accuracy: 0.001)
        control.setPressed(false)

        // 7) performClick 触发菜单弹出，期间 visualState 为 .menuOpen，关闭后恢复 .normal
        var presentedMenu: NSMenu?
        var presentedAnchor: NSPoint?
        var stateDuringPresentation: ControlBarIconMenuControl.VisualState?

        control.popupMenu = { menu, anchor, view in
            presentedMenu = menu
            presentedAnchor = anchor
            stateDuringPresentation = (view as? ControlBarIconMenuControl)?.visualState
        }

        control.performClick(nil)
        XCTAssertNotNil(presentedMenu)
        XCTAssertEqual(stateDuringPresentation, .menuOpen)
        XCTAssertEqual(control.visualState, .normal)
        let anchor = try XCTUnwrap(presentedAnchor)
        XCTAssertEqual(anchor.y, 30 + ControlBarIconMenuMetrics.menuVerticalOffset, accuracy: 0.01)
    }

    // MARK: - 4. SwiftUI 真实宿主布局测试（ItemControlBarView 与 CleanupHistoryView 浅色/深色均严格 30×30）

    @MainActor
    func testHostedItemControlBarAndCleanupHistoryLayoutStrictly30x30InLightAndDarkModes() throws {
        let home = makeTempSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeViewModel(home: home)
        model.report = makeSampleReport(home: home)

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let hostingView = NSHostingView(
                rootView: ItemControlBarView(viewModel: model)
                    .padding(.horizontal, 20)
                    .frame(width: 820)
                    .environment(\.colorScheme, scheme)
            )
            let window = attachToOffscreenWindow(hostingView, size: NSSize(width: 820, height: 60))
            defer { window.orderOut(nil) }

            layoutWindow(window)

            let control = try XCTUnwrap(
                findFirstSubview(ofType: ControlBarIconMenuControl.self, in: hostingView),
                "ItemControlBarView 应渲染原生 ControlBarIconMenuControl（\(scheme)）"
            )
            XCTAssertEqual(control.frame.width, 30, accuracy: 0.01, "筛选按钮宽度必须严格为 30pt（\(scheme)）")
            XCTAssertEqual(control.frame.height, 30, accuracy: 0.01, "筛选按钮高度必须严格为 30pt（\(scheme)）")
            XCTAssertEqual(control.iconImageView.frame.midX, 15, accuracy: 0.01)
            XCTAssertEqual(control.iconImageView.frame.midY, 15, accuracy: 0.01)
            XCTAssertEqual(control.accessibilityLabel(), ItemControlBarMenuFactory.accessibilityLabel)
            XCTAssertTrue(control.indicatorBadgeLayer.isHidden)

            // 真实通过宿主按钮触发菜单并选择「7 天前」
            var invokedCount = 0
            control.popupMenu = { menu, _, _ in
                invokedCount += 1
                if let idx = menu.items.firstIndex(where: { $0.title == ItemAgeFilter.olderThan7Days.menuTitle }) {
                    menu.performActionForItem(at: idx)
                }
            }
            control.performClick(nil)
            XCTAssertEqual(invokedCount, 1)
            XCTAssertEqual(model.selectedAgeFilter, .olderThan7Days)

            // 更新宿主后激活指示绿点应显示
            hostingView.rootView = ItemControlBarView(viewModel: model)
                .padding(.horizontal, 20)
                .frame(width: 820)
                .environment(\.colorScheme, scheme)
            layoutWindow(window)
            XCTAssertFalse(control.indicatorBadgeLayer.isHidden)

            model.selectedAgeFilter = .all
        }

        // 验证 CleanupHistoryView 右上角更多选项按钮同样严格 30×30 且居中
        let historyRecord = CleanupHistoryRecord(
            id: UUID(),
            timestamp: Date(),
            freedBytes: 4_096,
            trashedCount: 1,
            clientBreakdown: [
                ClientCleanupDelta(
                    clientID: "claude-code",
                    clientName: "Claude Code",
                    freedBytes: 4_096,
                    itemCount: 1
                )
            ],
            categoryBreakdown: [
                CategoryCleanupDelta(
                    category: .cache,
                    freedBytes: 4_096,
                    itemCount: 1
                )
            ]
        )
        let historyModel = makeViewModel(home: home, initialHistory: [historyRecord])
        let historyHost = NSHostingView(
            rootView: CleanupHistoryView(viewModel: historyModel)
                .frame(width: 920, height: 680)
                .environment(\.colorScheme, .light)
        )
        let historyWindow = attachToOffscreenWindow(historyHost, size: NSSize(width: 920, height: 680))
        defer { historyWindow.orderOut(nil) }

        layoutWindow(historyWindow)

        let historyControl = try XCTUnwrap(
            findFirstSubview(ofType: ControlBarIconMenuControl.self, in: historyHost),
            "CleanupHistoryView 应渲染原生 ControlBarIconMenuControl"
        )
        XCTAssertEqual(historyControl.frame.width, 30, accuracy: 0.01)
        XCTAssertEqual(historyControl.frame.height, 30, accuracy: 0.01)
        XCTAssertEqual(historyControl.iconImageView.frame.midX, 15, accuracy: 0.01)
        XCTAssertEqual(historyControl.iconImageView.frame.midY, 15, accuracy: 0.01)
        XCTAssertEqual(historyControl.accessibilityLabel(), CleanupHistoryCopy.clearOptionsHelp)
    }

    // MARK: - Helpers

    private func makeTempSandbox() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aicleaner-menu-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeViewModel(
        home: URL,
        initialHistory: [CleanupHistoryRecord] = []
    ) -> CleanerViewModel {
        let configDir = home.appendingPathComponent(".config", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let safetyGuard = SafetyGuard(homeDirectory: home)
        let customStore = CustomDirectoryStore(
            storageURL: configDir.appendingPathComponent("custom.json"),
            safetyGuard: safetyGuard
        )
        let historyStore = CleanupHistoryStore(
            storageURL: configDir.appendingPathComponent("history.json")
        )
        for record in initialHistory {
            _ = try? historyStore.append(record)
        }
        let excludedStore = ExcludedItemStore(
            storageURL: configDir.appendingPathComponent("excluded.json")
        )
        let engine = ScanEngine(
            homeDirectory: home,
            safetyGuard: safetyGuard,
            systemTempRoot: home.appendingPathComponent("sys-tmp", isDirectory: true),
            userTempRoot: home.appendingPathComponent("user-tmp", isDirectory: true)
        )
        return CleanerViewModel(
            homeDirectory: home,
            customDirectoryStore: customStore,
            historyStore: historyStore,
            excludedItemStore: excludedStore,
            scanEngine: engine
        )
    }

    private func makeSampleReport(home: URL) -> ScanReport {
        let now = Date()
        let profile = AIClientProfile(
            id: "claude-code",
            name: "Claude Code",
            symbolName: "terminal",
            accentToken: "claude",
            description: "Anthropic CLI",
            protectedSummary: "保留配置与凭据",
            rules: [],
            kind: .builtInClient
        )

        let item1 = CleanableItem(
            clientID: profile.id,
            clientName: profile.name,
            ruleID: "cache-1",
            displayName: "旧缓存文件",
            fileName: "old-cache.bin",
            url: home.appendingPathComponent(".claude/cache/old-cache.bin"),
            category: .cache,
            recommendation: .recommended,
            safetyNote: "缓存可安全清理",
            sizeBytes: 2_048_000,
            fileCount: 1,
            modifiedAt: now.addingTimeInterval(-15 * 86_400),
            isDirectory: false,
            isCustom: false
        )
        let item2 = CleanableItem(
            clientID: profile.id,
            clientName: profile.name,
            ruleID: "session-1",
            displayName: "历史会话",
            fileName: "session-old.jsonl",
            url: home.appendingPathComponent(".claude/projects/demo/session-old.jsonl"),
            category: .sessions,
            recommendation: .reviewSuggested,
            safetyNote: "历史会话，建议确认后清理",
            sizeBytes: 512_000,
            fileCount: 1,
            modifiedAt: now.addingTimeInterval(-45 * 86_400),
            isDirectory: false,
            isCustom: false
        )
        let item3 = CleanableItem(
            clientID: profile.id,
            clientName: profile.name,
            ruleID: "protected-1",
            displayName: "配置文件",
            fileName: "settings.json",
            url: home.appendingPathComponent(".claude/settings.json"),
            category: .protectedData,
            recommendation: .notRecommended,
            safetyNote: "配置文件，不建议清理",
            sizeBytes: 4_096,
            fileCount: 1,
            modifiedAt: now.addingTimeInterval(-120 * 86_400),
            isDirectory: false,
            isCustom: false
        )

        let summary = ClientScanSummary(
            profile: profile,
            items: [item1, item2],
            protectedItems: [item3]
        )
        return ScanReport(
            scannedAt: now,
            clientSummaries: [summary],
            totalBuiltInProfilesCount: 1,
            detectedBuiltInClientsCount: 1
        )
    }

    private func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func menuItemIndex(titled title: String, in menu: NSMenu) -> Int? {
        menu.items.firstIndex { $0.title == title }
    }

    @MainActor
    private func attachToOffscreenWindow(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderBack(nil)
        return window
    }

    @MainActor
    private func layoutWindow(_ window: NSWindow) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func findFirstSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = findFirstSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func measureRenderedIconInkCenter(
        of iconImageView: NSImageView,
        inContainerSize size: CGSize
    ) throws -> CGPoint {
        let scale = 2
        let pxWidth = Int(size.width) * scale
        let pxHeight = Int(size.height) * scale

        let isolatedContainer = NSView(frame: CGRect(origin: .zero, size: size))
        let clonedIcon = NSImageView(frame: iconImageView.frame)
        clonedIcon.image = iconImageView.image
        clonedIcon.imageScaling = iconImageView.imageScaling
        clonedIcon.imageAlignment = iconImageView.imageAlignment
        clonedIcon.contentTintColor = .black
        isolatedContainer.addSubview(clonedIcon)

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pxWidth,
                pixelsHigh: pxHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = size
        isolatedContainer.cacheDisplay(in: isolatedContainer.bounds, to: rep)

        var minX = pxWidth
        var maxX = -1
        var minY = pxHeight
        var maxY = -1
        for y in 0..<pxHeight {
            for x in 0..<pxWidth {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        XCTAssertLessThanOrEqual(minX, maxX, "应能渲染出非空图标像素")
        let inkCenterX = (Double(minX) + Double(maxX) + 1.0) * 0.5 / Double(scale)
        let inkCenterY = (Double(minY) + Double(maxY) + 1.0) * 0.5 / Double(scale)
        return CGPoint(x: inkCenterX, y: inkCenterY)
    }
}
