import AppKit
import SwiftUI

// MARK: - 1. 宿主窗口真实屏幕可见性快照（与是否获焦解耦）

struct WindowVisibilitySnapshot: Equatable, Sendable {
    let isWindowVisible: Bool
    let isMiniaturized: Bool
    let isApplicationHidden: Bool
    let isOcclusionVisible: Bool

    /// 综合判定窗口当前是否在屏幕上真实可见：
    /// `window.isVisible && !window.isMiniaturized && !NSApp.isHidden && window.occlusionState.contains(.visible)`
    /// 刻意不包含焦点/活跃状态，确保窗口可见但失焦时保持播放。
    var isVisibleOnScreen: Bool {
        isWindowVisible
            && !isMiniaturized
            && !isApplicationHidden
            && isOcclusionVisible
    }

    @MainActor
    static func capture(
        from window: NSWindow,
        isApplicationHidden: Bool? = nil,
        isClosing: Bool = false
    ) -> WindowVisibilitySnapshot {
        WindowVisibilitySnapshot(
            isWindowVisible: !isClosing && window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isApplicationHidden: isApplicationHidden ?? (NSApp?.isHidden ?? false),
            isOcclusionVisible: window.occlusionState.contains(.visible)
        )
    }
}

// MARK: - 2. 统一的动效播放/暂停判定策略（纯值类型，可直接单元测试）

struct AnimationPlaybackPolicy: Equatable, Sendable {
    let isWindowVisibleOnScreen: Bool
    let isPageVisible: Bool
    let isFeatureActive: Bool
    let reduceMotion: Bool

    init(
        isWindowVisibleOnScreen: Bool,
        isPageVisible: Bool = true,
        isFeatureActive: Bool = true,
        reduceMotion: Bool
    ) {
        self.isWindowVisibleOnScreen = isWindowVisibleOnScreen
        self.isPageVisible = isPageVisible
        self.isFeatureActive = isFeatureActive
        self.reduceMotion = reduceMotion
    }

    init(
        windowVisibility: WindowVisibilitySnapshot,
        isPageVisible: Bool = true,
        isFeatureActive: Bool = true,
        reduceMotion: Bool
    ) {
        self.init(
            isWindowVisibleOnScreen: windowVisibility.isVisibleOnScreen,
            isPageVisible: isPageVisible,
            isFeatureActive: isFeatureActive,
            reduceMotion: reduceMotion
        )
    }

    init(
        windowVisibility: WindowVisibilitySnapshot,
        sidebarSelection: SidebarSelection,
        isFeatureActive: Bool = true,
        reduceMotion: Bool
    ) {
        self.init(
            isWindowVisibleOnScreen: windowVisibility.isVisibleOnScreen,
            isPageVisible: sidebarSelection.isListScope,
            isFeatureActive: isFeatureActive,
            reduceMotion: reduceMotion
        )
    }

    /// 是否应当持续驱动动效。
    /// 明确不以窗口是否获焦（`controlActiveState`）作为暂停依据。
    var shouldAnimate: Bool {
        isWindowVisibleOnScreen && isPageVisible && isFeatureActive && !reduceMotion
    }

    /// 供 `TimelineView(.animation(paused:))` 直接使用的暂停标志。
    var isPaused: Bool {
        !shouldAnimate
    }
}

// MARK: - 3. 无跳变暂停/恢复动画时钟

struct PausableAnimationClock: Equatable, Sendable {
    private let origin: TimeInterval
    private(set) var isPaused: Bool
    private var pausedAt: TimeInterval?
    private var totalPausedDuration: TimeInterval

    init(
        isPaused: Bool = false,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.origin = now
        self.isPaused = isPaused
        self.pausedAt = isPaused ? now : nil
        self.totalPausedDuration = 0
    }

    mutating func setPaused(
        _ paused: Bool,
        at now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard paused != isPaused else { return }
        if paused {
            isPaused = true
            pausedAt = now
        } else {
            if let pausedAt {
                totalPausedDuration += max(0, now - pausedAt)
            }
            isPaused = false
            pausedAt = nil
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        elapsed(at: date.timeIntervalSinceReferenceDate)
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        let effectiveNow = isPaused ? (pausedAt ?? now) : now
        return max(0, (effectiveNow - origin) - totalPausedDuration)
    }
}

// MARK: - 4. SwiftUI Environment 透传（未挂窗/单测场景安全默认 true）

private struct WindowVisibleOnScreenKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    /// 宿主窗口当前是否在屏幕上真实可见（未挂载宿主窗口或单元测试场景下默认 true）。
    var isWindowVisibleOnScreen: Bool {
        get { self[WindowVisibleOnScreenKey.self] }
        set { self[WindowVisibleOnScreenKey.self] = newValue }
    }
}

// MARK: - 5. NSWindow 可见性监听桥接（异步更新防视图求值警告，卸载自动清理防泄漏）

private final class NotificationObserverBag {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    var count: Int {
        tokens.count
    }

    func add(
        name: Notification.Name,
        object: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: queue, using: block)
        tokens.append(token)
    }

    func removeAll() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}

@MainActor
final class WindowVisibilityMonitor {
    typealias SnapshotProvider = @MainActor (_ window: NSWindow, _ isClosing: Bool) -> WindowVisibilitySnapshot

    private let observerBag: NotificationObserverBag
    private let snapshotProvider: SnapshotProvider

    private(set) weak var observedWindow: NSWindow?
    private var isWindowClosing: Bool = false
    private var lastDeliveredVisibility: Bool?
    private var pendingDeliveryTask: Task<Void, Never>?

    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    init(
        notificationCenter: NotificationCenter = .default,
        snapshotProvider: @escaping SnapshotProvider = { window, isClosing in
            WindowVisibilitySnapshot.capture(from: window, isClosing: isClosing)
        }
    ) {
        self.observerBag = NotificationObserverBag(center: notificationCenter)
        self.snapshotProvider = snapshotProvider
    }

    var activeObserverCount: Int {
        observerBag.count
    }

    func attach(to newWindow: NSWindow?) {
        guard newWindow !== observedWindow else { return }

        observerBag.removeAll()
        observedWindow = newWindow

        guard let newWindow else {
            if !isWindowClosing {
                pendingDeliveryTask?.cancel()
                pendingDeliveryTask = nil
            }
            return
        }

        isWindowClosing = false
        registerObservers(for: newWindow)
        scheduleSync()
    }

    func invalidate() {
        pendingDeliveryTask?.cancel()
        pendingDeliveryTask = nil
        observerBag.removeAll()
        observedWindow = nil
        isWindowClosing = false
        onVisibilityChange = nil
    }

    private func registerObservers(for window: NSWindow) {
        let windowNotifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]

        for name in windowNotifications {
            observerBag.add(name: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSync()
                }
            }
        }

        observerBag.add(name: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isWindowClosing = true
                self.scheduleSync(forcedVisibility: false)
            }
        }

        let applicationNotifications: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]

        for name in applicationNotifications {
            observerBag.add(name: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSync()
                }
            }
        }
    }

    private func scheduleSync(forcedVisibility: Bool? = nil) {
        pendingDeliveryTask?.cancel()
        pendingDeliveryTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pendingDeliveryTask = nil
            if let forcedVisibility {
                self.deliverVisibilityIfNeeded(forcedVisibility)
            } else {
                self.deliverCurrentVisibilityIfNeeded()
            }
        }
    }

    private func deliverCurrentVisibilityIfNeeded() {
        guard let window = observedWindow else { return }
        let snapshot = snapshotProvider(window, isWindowClosing)
        deliverVisibilityIfNeeded(snapshot.isVisibleOnScreen)
    }

    private func deliverVisibilityIfNeeded(_ isVisible: Bool) {
        guard lastDeliveredVisibility != isVisible else { return }
        lastDeliveredVisibility = isVisible
        onVisibilityChange?(isVisible)
    }
}

@MainActor
final class WindowVisibilityBridgeView: NSView {
    let monitor: WindowVisibilityMonitor

    init(monitor: WindowVisibilityMonitor = WindowVisibilityMonitor()) {
        self.monitor = monitor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor.attach(to: window)
    }

    func syncWindowAttachmentIfNeeded() {
        monitor.attach(to: window)
    }

    func teardown() {
        monitor.invalidate()
    }
}

struct WindowVisibilityObserver: NSViewRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityBridgeView {
        let view = WindowVisibilityBridgeView()
        view.monitor.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityBridgeView, context: Context) {
        nsView.monitor.onVisibilityChange = onVisibilityChange
        nsView.syncWindowAttachmentIfNeeded()
    }

    static func dismantleNSView(_ nsView: WindowVisibilityBridgeView, coordinator: ()) {
        nsView.teardown()
    }
}
