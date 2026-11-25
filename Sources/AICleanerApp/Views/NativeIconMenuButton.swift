import AICleanerCore
import AppKit
import SwiftUI

@MainActor
private final class MenuActionTarget: NSObject {
    let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ item: NSMenuItem) {
        guard item.isEnabled else { return }
        handler()
    }
}

@MainActor
private extension NSMenu {
    @discardableResult
    func addAction(
        _ title: String,
        checked: Bool = false,
        enabled: Bool = true,
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = MenuActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke(_:)), keyEquivalent: "")
        item.target = target
        // AppKit's target is weak, so keep the action alive with its item.
        item.representedObject = target
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        addItem(item)
        return item
    }
}

@MainActor
enum ItemControlBarMenuFactory {
    static let accessibilityLabel = "时间范围、排序与批量勾选"

    static func makeMenu(for viewModel: CleanerViewModel) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: "时间范围"))
        for filter in ItemAgeFilter.allCases {
            menu.addAction(filter.rawValue, checked: viewModel.selectedAgeFilter == filter) {
                viewModel.selectedAgeFilter = filter
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "排序方式"))
        for order in ItemSortOrder.allCases {
            menu.addAction(order.rawValue, checked: viewModel.sortOrder == order) {
                viewModel.sortOrder = order
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "批量勾选"))
        let bulkCount = viewModel.filteredBulkSelectableItems.count
        menu.addAction(
            "全选可批量勾选项（\(bulkCount)）",
            enabled: bulkCount > 0 && !viewModel.allVisibleSelected
        ) {
            viewModel.selectAllVisible()
        }
        menu.addAction("反选可批量勾选项", enabled: bulkCount > 0) {
            viewModel.invertVisibleSelection()
        }
        menu.addAction("清空列表选择", enabled: viewModel.visibleSelectedCount > 0) {
            viewModel.clearVisibleSelection()
        }
        return menu
    }
}

@MainActor
enum CleanupHistoryMenuFactory {
    static func makeMenu(onRequestClear: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let item = menu.addAction(CleanupHistoryCopy.clearRecordsMenuTitle, handler: onRequestClear)
        let style = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(style)
        return menu
    }
}

enum ControlBarIconMenuMetrics {
    static let buttonSize = CGSize(width: 30, height: 30)
    static let cornerRadius: CGFloat = 8.5
    static let pressedScale: CGFloat = 0.94
    static let menuVerticalOffset: CGFloat = 6
}

struct ControlBarIconMenuButton: NSViewRepresentable {
    let symbolName: String
    var symbolWeight: NSFont.Weight = .medium
    let accessibilityLabel: String
    var showsIndicatorBadge = false
    let menuBuilder: @MainActor () -> NSMenu

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ControlBarIconMenuControl {
        let control = ControlBarIconMenuControl(frame: CGRect(origin: .zero, size: ControlBarIconMenuMetrics.buttonSize))
        configure(control)
        return control
    }

    func updateNSView(_ control: ControlBarIconMenuControl, context: Context) {
        configure(control)
    }

    private func configure(_ control: ControlBarIconMenuControl) {
        control.configure(
            symbolName: symbolName,
            symbolWeight: symbolWeight,
            accessibilityLabel: accessibilityLabel,
            showsIndicatorBadge: showsIndicatorBadge,
            isDarkMode: colorScheme == .dark,
            reduceMotion: reduceMotion,
            menuBuilder: menuBuilder
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: ControlBarIconMenuControl, context: Context
    ) -> CGSize? {
        ControlBarIconMenuMetrics.buttonSize
    }
}

@MainActor
final class ControlBarIconMenuControl: NSButton {
    enum VisualState: Equatable {
        case normal, hovered, pressed, menuOpen
    }

    private let surface = NSView()
    private let fillLayer = CALayer()
    private let rimLayer = CAGradientLayer()
    private let rimMask = CALayer()
    private var trackingArea: NSTrackingArea?
    private var symbolName: String?
    private var symbolWeight: NSFont.Weight?
    private var isDarkMode = false
    private var reduceMotion = false
    private var isHovered = false
    private var isPressed = false
    private var isMenuOpen = false
    private var menuBuilder: (@MainActor () -> NSMenu)?

    let iconImageView = NSImageView()
    let indicatorBadgeLayer = CALayer()

    var popupMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, anchor, view in
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { ControlBarIconMenuMetrics.buttonSize }
    var currentSurfaceTransform: CATransform3D { surface.layer?.transform ?? CATransform3DIdentity }

    var visualState: VisualState {
        if isMenuOpen { return .menuOpen }
        if isPressed { return .pressed }
        return isHovered ? .hovered : .normal
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(openMenu)

        wantsLayer = true
        surface.wantsLayer = true
        addSubview(surface)
        for layer in [fillLayer, rimMask] {
            layer.cornerRadius = ControlBarIconMenuMetrics.cornerRadius
            layer.cornerCurve = .continuous
        }
        rimMask.borderColor = NSColor.white.cgColor
        rimLayer.startPoint = CGPoint(x: 0, y: 0)
        rimLayer.endPoint = CGPoint(x: 1, y: 1)
        rimLayer.mask = rimMask
        surface.layer?.addSublayer(fillLayer)
        surface.layer?.addSublayer(rimLayer)

        iconImageView.imageScaling = .scaleNone
        iconImageView.imageAlignment = .alignCenter
        iconImageView.unregisterDraggedTypes()
        iconImageView.setAccessibilityElement(false)
        surface.addSubview(iconImageView)

        indicatorBadgeLayer.cornerRadius = 3
        indicatorBadgeLayer.backgroundColor = AppTheme.nsColor(for: .recommended).cgColor
        indicatorBadgeLayer.isHidden = true
        surface.layer?.addSublayer(indicatorBadgeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        symbolName: String,
        symbolWeight: NSFont.Weight = .medium,
        accessibilityLabel: String,
        showsIndicatorBadge: Bool,
        isDarkMode: Bool,
        reduceMotion: Bool,
        menuBuilder: @escaping @MainActor () -> NSMenu
    ) {
        if self.symbolName != symbolName || self.symbolWeight != symbolWeight {
            self.symbolName = symbolName
            self.symbolWeight = symbolWeight
            let style = NSImage.SymbolConfiguration(pointSize: 12.5, weight: symbolWeight)
            let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(style)
            icon?.isTemplate = true
            iconImageView.image = icon
            needsLayout = true
        }
        if toolTip != accessibilityLabel {
            setAccessibilityLabel(accessibilityLabel)
            toolTip = accessibilityLabel
        }
        indicatorBadgeLayer.isHidden = !showsIndicatorBadge
        self.isDarkMode = isDarkMode
        self.reduceMotion = reduceMotion
        self.menuBuilder = menuBuilder
        let appearanceName: NSAppearance.Name = isDarkMode ? .darkAqua : .aqua
        if appearance?.name != appearanceName {
            appearance = NSAppearance(named: appearanceName)
        }
        updateAppearance()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        surface.frame = bounds
        for layer in [fillLayer, rimLayer, rimMask] {
            layer.frame = surface.bounds
        }
        if let size = iconImageView.image?.size {
            iconImageView.frame = CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        indicatorBadgeLayer.frame = CGRect(x: bounds.maxX - 9, y: bounds.maxY - 9, width: 6, height: 6)
        CATransaction.commit()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = ControlBarIconMenuMetrics.cornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    // All artwork, including the active dot, is decorative.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        setPressed(true)
        CATransaction.flush()
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [self] event, stop in
            let isInside = event.map { bounds.contains(convert($0.locationInWindow, from: nil)) } ?? false
            if isInside != isPressed {
                setPressed(isInside)
                CATransaction.flush()
            }
            if event == nil || event?.type == .leftMouseUp {
                stop.pointee = true
            }
        }

        let shouldOpen = isPressed
        setPressed(false)
        refreshHover()
        if shouldOpen {
            // Start menu tracking after the button has consumed the mouse-up.
            DispatchQueue.main.async { [weak self] in
                self?.openMenu()
            }
        }
    }

    override func performClick(_ sender: Any?) { openMenu() }

    @objc private func openMenu() {
        guard isEnabled, window != nil, !isMenuOpen, let menu = menuBuilder?() else { return }
        isMenuOpen = true
        updateAppearance()
        CATransaction.flush()

        // Menus can extend past the window edge. AppKit constrains them to the screen.
        menu.appearance = appearance
        let anchor = NSPoint(
            x: bounds.maxX - menu.size.width,
            y: bounds.maxY + ControlBarIconMenuMetrics.menuVerticalOffset
        )
        popupMenu(menu, anchor, self)

        isMenuOpen = false
        refreshHover()
        updateAppearance()
        // Keep the menu and its action targets alive through AppKit's dispatch.
        DispatchQueue.main.async { withExtendedLifetime(menu) {} }
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateAppearance()
    }

    func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        updateAppearance()
    }

    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            setHovered(false)
            return
        }
        setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func updateAppearance() {
        let fill: NSColor
        let rim: [NSColor]
        let borderWidth: CGFloat
        let tint: NSColor
        switch visualState {
        case .normal:
            fill = AppTheme.glassCardFillNSColor(isDark: isDarkMode)
            rim = isDarkMode ? [.white.withAlphaComponent(0.14), .white.withAlphaComponent(0.03)]
                : [.black.withAlphaComponent(0.06), .black.withAlphaComponent(0.09)]
            borderWidth = 0.7
            tint = .secondaryLabelColor
        case .hovered, .pressed:
            let pressed = isPressed
            fill = isDarkMode
                ? NSColor(white: pressed ? 0.23 : 0.17, alpha: 0.96)
                : NSColor(white: pressed ? 0.91 : 0.97, alpha: 0.98)
            let edge: NSColor = isDarkMode ? .white : .black
            rim = [edge.withAlphaComponent(pressed ? 0.30 : 0.20), edge.withAlphaComponent(0.1)]
            borderWidth = 0.85
            tint = .labelColor
        case .menuOpen:
            let accent = AppTheme.nsColor(for: .recommended)
            fill = isDarkMode
                ? NSColor(srgbRed: 0.115, green: 0.210, blue: 0.185, alpha: 0.92)
                : NSColor(srgbRed: 0.915, green: 0.978, blue: 0.952, alpha: 0.96)
            rim = [accent.withAlphaComponent(0.60), accent.withAlphaComponent(0.30)]
            borderWidth = 1
            tint = isDarkMode ? accent : NSColor(srgbRed: 0.07, green: 0.54, blue: 0.36, alpha: 1)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = fill.cgColor
        rimLayer.colors = rim.map(\.cgColor)
        rimMask.borderWidth = borderWidth
        iconImageView.contentTintColor = tint
        let scale = isPressed && !reduceMotion ? ControlBarIconMenuMetrics.pressedScale : 1
        surface.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }
}
