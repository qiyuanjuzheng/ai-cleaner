@testable import AICleanerApp
import AICleanerCore
import AppKit
import SwiftUI
import XCTest

@MainActor
private final class VisibilityTestState {
    var snapshot: WindowVisibilitySnapshot
    var events: [Bool] = []

    init(snapshot: WindowVisibilitySnapshot) {
        self.snapshot = snapshot
    }
}

final class WindowVisibilityMotionTests: XCTestCase {
    // MARK: - 1. 动效播放/暂停核心判定矩阵

    func testPlaybackPolicyMatrixCoversAllVisibilityPageAndAccessibilityStates() {
        let visibleWindow = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        XCTAssertTrue(visibleWindow.isVisibleOnScreen)

        // 1) 窗口可见 + 获焦 → 播放
        let focusedVisible = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertTrue(focusedVisible.shouldAnimate)
        XCTAssertFalse(focusedVisible.isPaused)

        // 2) 窗口可见 + 失焦（关键回归场景：不以 controlActiveState 作为暂停依据）→ 继续播放
        // 即使窗口失去焦点（非 key/main），只要仍在屏幕上可见且停留在列表/首页，仍应保持播放。
        let unfocusedVisible = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertTrue(unfocusedVisible.shouldAnimate)
        XCTAssertFalse(unfocusedVisible.isPaused)
        // 对应 AICL-6：失焦时仅关闭手型光标，不影响动效播放
        XCTAssertTrue(
            ScanReadyHeroView.allowsPointerCursor(
                isPageVisible: true,
                isWindowVisibleOnScreen: visibleWindow.isVisibleOnScreen,
                isWindowActive: true
            )
        )
        XCTAssertFalse(
            ScanReadyHeroView.allowsPointerCursor(
                isPageVisible: true,
                isWindowVisibleOnScreen: visibleWindow.isVisibleOnScreen,
                isWindowActive: false
            )
        )

        // 3) 切到历史页 / 已排除页 → 暂停
        let historyPage = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .history,
            reduceMotion: false
        )
        XCTAssertFalse(historyPage.shouldAnimate)
        XCTAssertTrue(historyPage.isPaused)

        let excludedPage = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .excluded,
            reduceMotion: false
        )
        XCTAssertFalse(excludedPage.shouldAnimate)
        XCTAssertTrue(excludedPage.isPaused)

        // 4) 窗口最小化 → 暂停
        let miniaturizedWindow = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: true,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        XCTAssertFalse(miniaturizedWindow.isVisibleOnScreen)
        let miniaturizedPolicy = AnimationPlaybackPolicy(
            windowVisibility: miniaturizedWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertFalse(miniaturizedPolicy.shouldAnimate)
        XCTAssertTrue(miniaturizedPolicy.isPaused)

        // 5) 应用隐藏 → 暂停
        let hiddenAppWindow = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: true,
            isOcclusionVisible: true
        )
        XCTAssertFalse(hiddenAppWindow.isVisibleOnScreen)
        let hiddenAppPolicy = AnimationPlaybackPolicy(
            windowVisibility: hiddenAppWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertFalse(hiddenAppPolicy.shouldAnimate)
        XCTAssertTrue(hiddenAppPolicy.isPaused)

        // 6) 窗口完全被遮挡（occlusionState 不含 .visible）→ 暂停
        let occludedWindow = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: false
        )
        XCTAssertFalse(occludedWindow.isVisibleOnScreen)
        let occludedPolicy = AnimationPlaybackPolicy(
            windowVisibility: occludedWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertFalse(occludedPolicy.shouldAnimate)
        XCTAssertTrue(occludedPolicy.isPaused)

        // 7) 窗口关闭 / 不可见 → 暂停
        let closedWindow = WindowVisibilitySnapshot(
            isWindowVisible: false,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        XCTAssertFalse(closedWindow.isVisibleOnScreen)
        let closedPolicy = AnimationPlaybackPolicy(
            windowVisibility: closedWindow,
            sidebarSelection: .allClients,
            reduceMotion: false
        )
        XCTAssertFalse(closedPolicy.shouldAnimate)
        XCTAssertTrue(closedPolicy.isPaused)

        // 8) 系统开启「减弱动态效果」→ 暂停
        let reducedMotionPolicy = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .allClients,
            reduceMotion: true
        )
        XCTAssertFalse(reducedMotionPolicy.shouldAnimate)
        XCTAssertTrue(reducedMotionPolicy.isPaused)

        // 9) 功能态未激活（如非扫描中时的扫描环/徽章）→ 暂停
        let inactiveFeaturePolicy = AnimationPlaybackPolicy(
            windowVisibility: visibleWindow,
            sidebarSelection: .allClients,
            isFeatureActive: false,
            reduceMotion: false
        )
        XCTAssertFalse(inactiveFeaturePolicy.shouldAnimate)
        XCTAssertTrue(inactiveFeaturePolicy.isPaused)
    }

    // MARK: - 2. 暂停/恢复无跳变连续时钟

    func testPausableAnimationClockFreezesWhilePausedAndResumesWithoutJump() {
        var clock = PausableAnimationClock(isPaused: false, now: 100.0)
        XCTAssertEqual(clock.elapsed(at: 100.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(at: 104.5), 4.5, accuracy: 0.0001)

        // 暂停 30 秒：期间相位冻结在 4.5s
        clock.setPaused(true, at: 104.5)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 104.5), 4.5, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(at: 120.0), 4.5, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(at: 134.5), 4.5, accuracy: 0.0001)

        // 恢复播放：从 4.5s 平滑续播，无突兀跳变
        clock.setPaused(false, at: 134.5)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 134.5), 4.5, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(at: 136.0), 6.0, accuracy: 0.0001)

        // 再次暂停并恢复
        clock.setPaused(true, at: 136.0)
        clock.setPaused(true, at: 140.0) // 重复暂停幂等
        XCTAssertEqual(clock.elapsed(at: 150.0), 6.0, accuracy: 0.0001)

        clock.setPaused(false, at: 150.0)
        XCTAssertEqual(clock.elapsed(at: 150.5), 6.5, accuracy: 0.0001)

        // 初始即暂停的场景
        var initiallyPaused = PausableAnimationClock(isPaused: true, now: 200.0)
        XCTAssertEqual(initiallyPaused.elapsed(at: 215.0), 0.0, accuracy: 0.0001)
        initiallyPaused.setPaused(false, at: 215.0)
        XCTAssertEqual(initiallyPaused.elapsed(at: 215.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(initiallyPaused.elapsed(at: 217.25), 2.25, accuracy: 0.0001)
    }

    // MARK: - 3. NSWindow 可见性监听桥接：通知响应、异步更新与观察者清理

    @MainActor
    func testWindowVisibilityMonitorReactsToWindowAndAppNotificationsAsynchronously() async throws {
        let center = NotificationCenter()
        let window1 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        let window2 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )

        let state = VisibilityTestState(
            snapshot: WindowVisibilitySnapshot(
                isWindowVisible: true,
                isMiniaturized: false,
                isApplicationHidden: false,
                isOcclusionVisible: true
            )
        )

        let monitor = WindowVisibilityMonitor(
            notificationCenter: center,
            snapshotProvider: { _, isClosing in
                WindowVisibilitySnapshot(
                    isWindowVisible: !isClosing && state.snapshot.isWindowVisible,
                    isMiniaturized: state.snapshot.isMiniaturized,
                    isApplicationHidden: state.snapshot.isApplicationHidden,
                    isOcclusionVisible: state.snapshot.isOcclusionVisible
                )
            }
        )
        monitor.onVisibilityChange = { isVisible in
            state.events.append(isVisible)
        }

        // 挂载到 window1：必须注册 6 个系统通知，且不得同步触发回调（避免 SwiftUI 视图求值期警告）
        monitor.attach(to: window1)
        XCTAssertEqual(monitor.activeObserverCount, 6)
        XCTAssertTrue(state.events.isEmpty, "attach(to:) must deliver visibility asynchronously")

        try await waitUntil { state.events.count == 1 }
        XCTAssertEqual(state.events, [true])

        // 1) 完全遮挡 -> false，恢复可见 -> true
        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: false
        )
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window1)
        XCTAssertEqual(state.events, [true], "notification delivery must remain asynchronous")
        try await waitUntil { state.events.count == 2 }
        XCTAssertEqual(state.events, [true, false])

        // 状态未变化时重复通知去重，不触发多余刷新
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window1)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.events, [true, false])

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window1)
        try await waitUntil { state.events.count == 3 }
        XCTAssertEqual(state.events, [true, false, true])

        // 2) 最小化 -> false，取消最小化 -> true
        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: true,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSWindow.didMiniaturizeNotification, object: window1)
        try await waitUntil { state.events.count == 4 }
        XCTAssertEqual(state.events, [true, false, true, false])

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSWindow.didDeminiaturizeNotification, object: window1)
        try await waitUntil { state.events.count == 5 }
        XCTAssertEqual(state.events, [true, false, true, false, true])

        // 3) 应用隐藏 -> false，取消隐藏 -> true
        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: true,
            isOcclusionVisible: true
        )
        center.post(name: NSApplication.didHideNotification, object: nil)
        try await waitUntil { state.events.count == 6 }
        XCTAssertEqual(state.events, [true, false, true, false, true, false])

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        try await waitUntil { state.events.count == 7 }
        XCTAssertEqual(state.events, [true, false, true, false, true, false, true])

        // 4) 窗口即将关闭：即使 window.isVisible 在 willClose 当下仍为 true，也必须立刻转为 false
        center.post(name: NSWindow.willCloseNotification, object: window1)
        try await waitUntil { state.events.count == 8 }
        XCTAssertEqual(state.events, [true, false, true, false, true, false, true, false])

        // 5) 切换窗口：旧窗口通知必须失效，新窗口恢复同步
        monitor.attach(to: window2)
        XCTAssertEqual(monitor.activeObserverCount, 6)
        try await waitUntil { state.events.count == 9 }
        XCTAssertEqual(state.events, [true, false, true, false, true, false, true, false, true])

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: false
        )
        // 旧窗口 window1 的通知不应再影响状态
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window1)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.events.count, 9)

        // 新窗口 window2 的通知生效
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window2)
        try await waitUntil { state.events.count == 10 }
        XCTAssertEqual(state.events.last, false)

        // 6) 卸载清理：所有观察者立即释放，不再响应后续通知
        monitor.invalidate()
        XCTAssertEqual(monitor.activeObserverCount, 0)
        XCTAssertNil(monitor.observedWindow)

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window2)
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.events.count, 10)
    }

    @MainActor
    func testWindowVisibilityMonitorCleansUpObserversOnDeinit() async throws {
        let center = NotificationCenter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        var callCount = 0
        do {
            let monitor = WindowVisibilityMonitor(
                notificationCenter: center,
                snapshotProvider: { _, _ in
                    WindowVisibilitySnapshot(
                        isWindowVisible: true,
                        isMiniaturized: false,
                        isApplicationHidden: false,
                        isOcclusionVisible: true
                    )
                }
            )
            monitor.onVisibilityChange = { _ in
                callCount += 1
            }
            monitor.attach(to: window)
            try await waitUntil { callCount == 1 }
        }

        // monitor 释放后通知不得再触发回调，亦不发生悬挂引用崩溃
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.post(name: NSApplication.didHideNotification, object: nil)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testWindowVisibilityBridgeViewAttachesAndCleansUpWithHostNSWindow() async throws {
        let center = NotificationCenter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = container

        // 验证 WindowVisibilitySnapshot.capture 在未显式展示与 isClosing=true 时的判定
        let offscreenSnapshot = WindowVisibilitySnapshot.capture(from: window, isApplicationHidden: false, isClosing: false)
        XCTAssertFalse(offscreenSnapshot.isWindowVisible)
        XCTAssertFalse(offscreenSnapshot.isVisibleOnScreen)
        let closingSnapshot = WindowVisibilitySnapshot.capture(from: window, isApplicationHidden: false, isClosing: true)
        XCTAssertFalse(closingSnapshot.isWindowVisible)
        XCTAssertFalse(closingSnapshot.isVisibleOnScreen)

        let state = VisibilityTestState(
            snapshot: WindowVisibilitySnapshot(
                isWindowVisible: true,
                isMiniaturized: false,
                isApplicationHidden: false,
                isOcclusionVisible: true
            )
        )
        let monitor = WindowVisibilityMonitor(
            notificationCenter: center,
            snapshotProvider: { _, isClosing in
                WindowVisibilitySnapshot(
                    isWindowVisible: !isClosing && state.snapshot.isWindowVisible,
                    isMiniaturized: state.snapshot.isMiniaturized,
                    isApplicationHidden: state.snapshot.isApplicationHidden,
                    isOcclusionVisible: state.snapshot.isOcclusionVisible
                )
            }
        )
        monitor.onVisibilityChange = { visible in
            state.events.append(visible)
        }

        let bridgeView = WindowVisibilityBridgeView(monitor: monitor)
        XCTAssertNil(bridgeView.hitTest(NSPoint(x: 5, y: 5)))
        XCTAssertEqual(bridgeView.monitor.activeObserverCount, 0)

        // 挂载到宿主 NSWindow 自动触发 viewDidMoveToWindow()
        container.addSubview(bridgeView)
        XCTAssertEqual(bridgeView.monitor.activeObserverCount, 6)
        XCTAssertTrue(bridgeView.monitor.observedWindow === window)
        try await waitUntil { state.events == [true] }

        // 宿主窗口完全被遮挡后转为 false
        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: false
        )
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { state.events == [true, false] }

        // 从窗口卸载自动移除所有观察者，不再泄漏
        bridgeView.removeFromSuperview()
        XCTAssertEqual(bridgeView.monitor.activeObserverCount, 0)
        XCTAssertNil(bridgeView.monitor.observedWindow)

        state.snapshot = WindowVisibilitySnapshot(
            isWindowVisible: true,
            isMiniaturized: false,
            isApplicationHidden: false,
            isOcclusionVisible: true
        )
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.events, [true, false])
    }

    // MARK: - 4. 环境默认值与无窗/离屏组件安全兼容

    @MainActor
    func testEnvironmentDefaultAndMotionViewsLayoutSafelyWithoutWindow() async throws {
        // 未挂载真实宿主窗口时，Environment 默认值安全为 true
        XCTAssertTrue(EnvironmentValues().isWindowVisibleOnScreen)

        // 未挂窗的 WindowVisibilityObserver 不触发异常或误报 false
        var observerEvents: [Bool] = []
        let observerHost = NSHostingView(
            rootView: WindowVisibilityObserver { visible in
                observerEvents.append(visible)
            }
        )
        observerHost.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        observerHost.layoutSubtreeIfNeeded()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(observerEvents.isEmpty)

        // 覆盖所有核心动效组件在 Light / Dark 及 窗口可见/不可见 下的安全布局
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for windowVisible in [true, false] {
                let composite = VStack(spacing: 12) {
                    BrandLogoEmblem(isScanning: true)
                    StorageRingGauge(
                        recommendedBytes: 120_000,
                        reviewBytes: 40_000,
                        protectedBytes: 10_000,
                        highlightedTier: nil,
                        isScanning: true,
                        isVisible: true
                    )
                    AuroraScanSweepBar(isVisible: true)
                    SparkleBurstOverlay(triggerID: UUID())
                        .frame(width: 240, height: 36)
                }
                .environment(\.isWindowVisibleOnScreen, windowVisible)

                let host = NSHostingView(rootView: composite)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for async visibility delivery")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
