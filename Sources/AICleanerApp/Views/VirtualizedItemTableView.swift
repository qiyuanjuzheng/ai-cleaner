import AICleanerCore
import AppKit
import CoreText
import SwiftUI

// MARK: - Layout & Visual Constants

enum VirtualizedItemTableMetrics {
    static let horizontalMargin: CGFloat = 20
    static let bottomScrollInset: CGFloat = 88
    static let itemRowHeight: CGFloat = 54
    static let firstSectionHeaderHeight: CGFloat = 36
    static let subsequentSectionHeaderHeight: CGFloat = 48
    static let sectionHeaderContentHeight: CGFloat = 28
    static let sectionHeaderFirstTopPadding: CGFloat = 2
    static let sectionHeaderSubsequentTopPadding: CGFloat = 14
    static let sectionHeaderBottomPadding: CGFloat = 6
    static let sectionHeaderExtraHorizontalPadding: CGFloat = 4
    static let cardCornerRadius: CGFloat = 13
    static let cardHorizontalPadding: CGFloat = 14
    static let checkboxSize: CGFloat = 17
    static let iconBadgeSize: CGFloat = 28
    static let actionButtonSize = NSSize(width: 26, height: 24)
    static let ratioBarSize = NSSize(width: 44, height: 2.5)
    static let minimumTrailingColumnWidth: CGFloat = 112
    static let popoverContentSize = NSSize(width: 340, height: 132)
}

// MARK: - Cached Fonts & SF Symbols (Zero Per-Row Allocation During Scroll)

@MainActor
private enum ItemTableResources {
    private struct SymbolCacheKey: Hashable {
        let name: String
        let pointSizeTenths: Int
        let weightRaw: CGFloat
    }

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let badgeSemiboldFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    static let badgeMediumFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
    static let clientNameFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let sectionTitleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let sectionSummaryFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let sectionActionFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let popoverBodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    static let sizeFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let monospaced = rounded.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]
            ]
        ])
        return NSFont(descriptor: monospaced, size: 12)
            ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }()

    private static var symbolCache: [SymbolCacheKey: NSImage] = [:]

    static func symbolImage(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSImage? {
        let key = SymbolCacheKey(
            name: name,
            pointSizeTenths: Int((pointSize * 10).rounded()),
            weightRaw: weight.rawValue
        )
        if let cached = symbolCache[key] {
            return cached
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let configured = base.withSymbolConfiguration(config) ?? base
        configured.isTemplate = true
        symbolCache[key] = configured
        return configured
    }
}

private extension NSView {
    var isDarkEffectiveAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private func resolvedCGColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
    var result: CGColor = NSColor.clear.cgColor
    appearance.performAsCurrentDrawingAppearance {
        result = color.cgColor
    }
    return result
}

@MainActor
private final class PassthroughLabel: NSTextField {
    static func makeLabel(
        string: String = "",
        font: NSFont,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> PassthroughLabel {
        let field = PassthroughLabel(labelWithString: string)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = lineBreakMode
        field.maximumNumberOfLines = 1
        return field
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Scoped Notification Observer Bag (Swift 6 Safe Cleanup)

private final class TableNotificationObserverBag {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    var count: Int {
        tokens.count
    }

    func add(
        name: Notification.Name,
        object: Any?,
        queue: OperationQueue? = .main,
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

// MARK: - Lightweight Reusable Row View (Disables Default System Highlights)

@MainActor
private final class PlainTableRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PlainTableRowView")

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // 保持完全透明，让卡片背景与环境极光自然透出
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // 选中高亮由 ItemRowTableCellView 的语义填充色负责
    }
}

// MARK: - Pure AppKit Card Background (Rounded Corners + Seamless Border + 0.5pt Hairline)

@MainActor
final class ItemCardBackgroundView: NSView {
    private(set) var position: RowCardPosition = .single
    private(set) var recommendation: CleanupRecommendation = .recommended
    private(set) var isSelectedState: Bool = false
    private(set) var isHoveredState: Bool = false
    private var lastRenderedDark: Bool?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        position: RowCardPosition,
        recommendation: CleanupRecommendation,
        isSelected: Bool,
        isHovered: Bool
    ) {
        let isDark = isDarkEffectiveAppearance
        guard self.position != position
            || self.recommendation != recommendation
            || self.isSelectedState != isSelected
            || self.isHoveredState != isHovered
            || self.lastRenderedDark != isDark else {
            return
        }
        self.position = position
        self.recommendation = recommendation
        self.isSelectedState = isSelected
        self.isHoveredState = isHovered
        self.lastRenderedDark = isDark
        needsDisplay = true
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              bounds.width > 1,
              bounds.height > 1 else {
            return
        }

        let isDark = isDarkEffectiveAppearance
        lastRenderedDark = isDark

        let rect = bounds
        let r = min(VirtualizedItemTableMetrics.cardCornerRadius, rect.height / 2, rect.width / 2)

        // 1. 卡片背景填充
        let fillColor = AppTheme.rowFillNSColor(
            recommendation: recommendation,
            isSelected: isSelectedState,
            isHovered: isHoveredState,
            isDark: isDark
        )
        let fillPath = Self.makeFillPath(in: rect, position: position, radius: r)
        ctx.saveGState()
        ctx.setFillColor(resolvedCGColor(fillColor, in: effectiveAppearance))
        ctx.addPath(fillPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. 分组内部 0.5pt 细分隔线（对齐正文起始位置 56pt，避免行间割裂）
        if position.showsBottomDivider {
            let dividerColor = AppTheme.hairlineDividerNSColor(isDark: isDark)
            let dividerWidth = max(0, rect.width - 56 - 14)
            if dividerWidth > 0 {
                ctx.saveGState()
                ctx.setFillColor(resolvedCGColor(dividerColor, in: effectiveAppearance))
                ctx.fill(CGRect(x: 56, y: rect.maxY - 0.5, width: dividerWidth, height: 0.5))
                ctx.restoreGState()
            }
        }

        // 3. 无缝卡片外轮廓边线（仅画外侧边缘，相邻行绝不出现双层横线）
        let borderColor = AppTheme.rowBorderNSColor(isDark: isDark)
        let borderPath = Self.makeSeamlessBorderPath(in: rect, position: position, radius: r)
        ctx.saveGState()
        ctx.setStrokeColor(resolvedCGColor(borderColor, in: effectiveAppearance))
        ctx.setLineWidth(0.75)
        ctx.addPath(borderPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func makeFillPath(in rect: CGRect, position: RowCardPosition, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch position {
        case .single:
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        case .first:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        case .middle:
            path.addRect(rect)
        case .last:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
        return path
    }

    private static func makeSeamlessBorderPath(in rect: CGRect, position: RowCardPosition, radius r: CGFloat) -> CGPath {
        let inset = rect.insetBy(dx: 0.375, dy: 0.375)
        let path = CGMutablePath()
        switch position {
        case .single:
            path.move(to: CGPoint(x: inset.minX + r, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.minY))
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.minY + r), control: CGPoint(x: inset.maxX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY - r))
            path.addQuadCurve(to: CGPoint(x: inset.maxX - r, y: inset.maxY), control: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX + r, y: inset.maxY))
            path.addQuadCurve(to: CGPoint(x: inset.minX, y: inset.maxY - r), control: CGPoint(x: inset.minX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + r))
            path.addQuadCurve(to: CGPoint(x: inset.minX + r, y: inset.minY), control: CGPoint(x: inset.minX, y: inset.minY))
            path.closeSubpath()
        case .first:
            path.move(to: CGPoint(x: inset.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + r))
            path.addQuadCurve(to: CGPoint(x: inset.minX + r, y: inset.minY), control: CGPoint(x: inset.minX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.minY))
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.minY + r), control: CGPoint(x: inset.maxX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        case .middle:
            path.move(to: CGPoint(x: inset.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.minX, y: rect.maxY))
            path.move(to: CGPoint(x: inset.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        case .last:
            path.move(to: CGPoint(x: inset.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY - r))
            path.addQuadCurve(to: CGPoint(x: inset.minX + r, y: inset.maxY), control: CGPoint(x: inset.minX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.maxY))
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.maxY - r), control: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.minY))
        }
        return path
    }
}

// MARK: - Pure AppKit Leading Checkbox / Risk Lock / Hard-Protection Control

@MainActor
final class RowCheckboxControl: NSControl {
    enum Mode: Equatable {
        case hardProtected
        case cleanable(isChecked: Bool)
        case riskOverridable(isChecked: Bool, isHovered: Bool)

        var isInteractive: Bool {
            switch self {
            case .hardProtected: return false
            case .cleanable, .riskOverridable: return true
            }
        }

        var isChecked: Bool {
            switch self {
            case .hardProtected: return false
            case let .cleanable(isChecked), let .riskOverridable(isChecked, _): return isChecked
            }
        }
    }

    private(set) var mode: Mode = .cleanable(isChecked: false)
    private(set) var recommendation: CleanupRecommendation = .recommended
    private var isPressedState: Bool = false
    private var lastRenderedDark: Bool?

    var onToggle: (@MainActor () -> Void)?

    private let symbolView: PassthroughImageView = {
        let view = PassthroughImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        return view
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(symbolView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        symbolView.frame = bounds
    }

    func update(
        mode: Mode,
        recommendation: CleanupRecommendation,
        hardProtectionTooltip: String?
    ) {
        let isDark = isDarkEffectiveAppearance
        let needsRedraw = self.mode != mode
            || self.recommendation != recommendation
            || self.lastRenderedDark != isDark

        self.mode = mode
        self.recommendation = recommendation
        self.lastRenderedDark = isDark
        self.isEnabled = mode.isInteractive

        if self.toolTip != hardProtectionTooltip {
            self.toolTip = hardProtectionTooltip
        }

        if needsRedraw {
            applySymbolAndAccessibility()
            needsDisplay = true
        }
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            applySymbolAndAccessibility()
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        guard mode.isInteractive else { return }
        isPressedState = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseUp(with: event)
            return
        }
        guard mode.isInteractive else { return }
        let wasPressed = isPressedState
        isPressedState = false
        needsDisplay = true
        guard wasPressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -4, dy: -4).contains(point) {
            onToggle?()
        }
    }

    override func performClick(_ sender: Any?) {
        guard mode.isInteractive else { return }
        onToggle?()
    }

    private func applySymbolAndAccessibility() {
        let tint = AppTheme.nsColor(for: recommendation)
        switch mode {
        case .hardProtected:
            symbolView.image = ItemTableResources.symbolImage(named: "lock.fill", pointSize: 9, weight: .bold)
            symbolView.contentTintColor = tint
            symbolView.isHidden = false
            layer?.shadowOpacity = 0
            setAccessibilityRole(.image)
            setAccessibilityLabel("已锁定")
            setAccessibilityValue(nil)

        case let .cleanable(isChecked):
            if isChecked {
                symbolView.image = ItemTableResources.symbolImage(named: "checkmark", pointSize: 9.5, weight: .bold)
                symbolView.contentTintColor = .white
                symbolView.isHidden = false
                layer?.shadowColor = resolvedCGColor(tint, in: effectiveAppearance)
                layer?.shadowRadius = 3.5
                layer?.shadowOffset = CGSize(width: 0, height: -1)
                layer?.shadowOpacity = 0.36
            } else {
                symbolView.isHidden = true
                layer?.shadowOpacity = 0
            }
            setAccessibilityRole(.checkBox)
            setAccessibilityLabel(isChecked ? "取消勾选" : "勾选此项")
            setAccessibilityValue(isChecked ? 1 : 0)

        case let .riskOverridable(isChecked, isHovered):
            if isChecked {
                symbolView.image = ItemTableResources.symbolImage(named: "checkmark", pointSize: 9.5, weight: .bold)
                symbolView.contentTintColor = .white
                layer?.shadowColor = resolvedCGColor(tint, in: effectiveAppearance)
                layer?.shadowRadius = 3.0
                layer?.shadowOffset = CGSize(width: 0, height: -1)
                layer?.shadowOpacity = 0.30
            } else {
                symbolView.image = ItemTableResources.symbolImage(named: "lock.fill", pointSize: 8.5, weight: .bold)
                symbolView.contentTintColor = tint.withAlphaComponent(isHovered ? 0.95 : 0.72)
                layer?.shadowOpacity = 0
            }
            symbolView.isHidden = false
            setAccessibilityRole(.checkBox)
            setAccessibilityLabel(isChecked ? "取消勾选" : "勾选并确认风险")
            setAccessibilityValue(isChecked ? 1 : 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard case .hardProtected = mode else {
            drawCheckboxBox()
            return
        }
    }

    private func drawCheckboxBox() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = isDarkEffectiveAppearance
        let tint = AppTheme.nsColor(for: recommendation)
        let boxRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: boxRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)

        ctx.saveGState()
        if isPressedState {
            ctx.setAlpha(0.84)
        }

        let topColor: NSColor
        let bottomColor: NSColor
        let borderColor: NSColor

        switch mode {
        case .hardProtected:
            ctx.restoreGState()
            return
        case let .cleanable(isChecked):
            if isChecked {
                topColor = tint
                bottomColor = tint.withAlphaComponent(0.84)
                borderColor = NSColor.white.withAlphaComponent(0.32)
            } else {
                topColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.06 : 0.03)
                bottomColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.04 : 0.02)
                borderColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.22 : 0.20)
            }
        case let .riskOverridable(isChecked, isHovered):
            if isChecked {
                topColor = tint
                bottomColor = tint.withAlphaComponent(0.84)
                borderColor = NSColor.white.withAlphaComponent(0.32)
            } else {
                topColor = tint.withAlphaComponent(isHovered ? 0.16 : 0.08)
                bottomColor = tint.withAlphaComponent(0.04)
                borderColor = tint.withAlphaComponent(isHovered ? 0.65 : 0.35)
            }
        }

        let colors = [
            resolvedCGColor(topColor, in: effectiveAppearance),
            resolvedCGColor(bottomColor, in: effectiveAppearance)
        ] as CFArray

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: boxRect.minX, y: boxRect.minY),
                end: CGPoint(x: boxRect.maxX, y: boxRect.maxY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(resolvedCGColor(borderColor, in: effectiveAppearance))
        ctx.setLineWidth(1.0)
        ctx.strokePath()

        ctx.restoreGState()
    }
}

// MARK: - Pure AppKit Category Icon Badge (28×28)

@MainActor
private final class CategoryIconBadgeView: NSView {
    private var symbolName: String = ""
    private var tintColor: NSColor = .secondaryLabelColor
    private var lastRenderedDark: Bool?

    private let imageView: PassthroughImageView = {
        let view = PassthroughImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        return view
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    func update(symbolName: String, tintColor: NSColor) {
        let isDark = isDarkEffectiveAppearance
        let symbolChanged = self.symbolName != symbolName
        let colorChanged = self.tintColor != tintColor
        let darkChanged = self.lastRenderedDark != isDark

        guard symbolChanged || colorChanged || darkChanged else { return }

        self.symbolName = symbolName
        self.tintColor = tintColor
        self.lastRenderedDark = isDark

        if symbolChanged {
            imageView.image = ItemTableResources.symbolImage(named: symbolName, pointSize: 13, weight: .medium)
        }
        imageView.contentTintColor = tintColor
        needsDisplay = true
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            imageView.contentTintColor = tintColor
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = isDarkEffectiveAppearance
        lastRenderedDark = isDark
        let bgColor = tintColor.withAlphaComponent(isDark ? 0.14 : 0.10)
        let path = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.setFillColor(resolvedCGColor(bgColor, in: effectiveAppearance))
        ctx.addPath(path)
        ctx.fillPath()
    }
}

// MARK: - Pure AppKit Capsule Pill Badge

@MainActor
private final class PillBadgeView: NSView {
    enum Style {
        case tinted(color: NSColor, darkAlpha: CGFloat, lightAlpha: CGFloat)
        case neutral(darkAlpha: CGFloat, lightAlpha: CGFloat)
    }

    private let label: PassthroughLabel
    private let horizontalPadding: CGFloat
    private let fixedHeight: CGFloat
    private let allowsHitTesting: Bool
    private var style: Style
    private var lastRenderedDark: Bool?
    private(set) var cachedWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsHitTesting ? super.hitTest(point) : nil
    }

    init(
        text: String = "",
        font: NSFont,
        style: Style,
        horizontalPadding: CGFloat = 6,
        fixedHeight: CGFloat = 15,
        allowsHitTesting: Bool = false
    ) {
        self.style = style
        self.horizontalPadding = horizontalPadding
        self.fixedHeight = fixedHeight
        self.allowsHitTesting = allowsHitTesting
        self.label = PassthroughLabel.makeLabel(
            string: text,
            font: font,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        recomputeWidth()
        applyTextColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: Style) {
        let textChanged = label.stringValue != text
        self.style = style
        if textChanged {
            label.stringValue = text
            recomputeWidth()
        }
        applyTextColor()
        lastRenderedDark = isDarkEffectiveAppearance
        needsDisplay = true
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            applyTextColor()
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func layout() {
        super.layout()
        let textHeight = ceil(label.fittingSize.height)
        let y = floor((bounds.height - textHeight) / 2)
        label.frame = CGRect(
            x: horizontalPadding,
            y: y,
            width: max(0, bounds.width - horizontalPadding * 2),
            height: textHeight
        )
    }

    private func recomputeWidth() {
        if label.stringValue.isEmpty {
            cachedWidth = 0
        } else {
            cachedWidth = ceil(label.fittingSize.width) + horizontalPadding * 2
        }
    }

    private func applyTextColor() {
        switch style {
        case let .tinted(color, _, _):
            label.textColor = color
        case .neutral:
            label.textColor = .secondaryLabelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.height > 0 else { return }
        let isDark = isDarkEffectiveAppearance
        lastRenderedDark = isDark
        let fill: NSColor
        switch style {
        case let .tinted(color, darkAlpha, lightAlpha):
            fill = color.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        case let .neutral(darkAlpha, lightAlpha):
            fill = NSColor.labelColor.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
        let radius = bounds.height / 2
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(resolvedCGColor(fill, in: effectiveAppearance))
        ctx.addPath(path)
        ctx.fillPath()
    }
}

// MARK: - Pure AppKit Relative Size Ratio Bar (44×2.5)

@MainActor
private final class RatioBarView: NSView {
    private var fraction: CGFloat = 0
    private var recommendation: CleanupRecommendation = .recommended
    private var isCleanable: Bool = true
    private var hasPositiveSize: Bool = false
    private var lastRenderedDark: Bool?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        fraction: Double,
        recommendation: CleanupRecommendation,
        isCleanable: Bool,
        hasPositiveSize: Bool
    ) {
        let clamped = max(0, min(1, CGFloat(fraction)))
        let isDark = isDarkEffectiveAppearance
        guard abs(self.fraction - clamped) > 0.0005
            || self.recommendation != recommendation
            || self.isCleanable != isCleanable
            || self.hasPositiveSize != hasPositiveSize
            || self.lastRenderedDark != isDark else {
            return
        }
        self.fraction = clamped
        self.recommendation = recommendation
        self.isCleanable = isCleanable
        self.hasPositiveSize = hasPositiveSize
        self.lastRenderedDark = isDark
        needsDisplay = true
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let isDark = isDarkEffectiveAppearance
        lastRenderedDark = isDark
        let radius = bounds.height / 2

        let trackColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.07)
        let trackPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(resolvedCGColor(trackColor, in: effectiveAppearance))
        ctx.addPath(trackPath)
        ctx.fillPath()

        guard hasPositiveSize else { return }
        let barWidth = max(2.5, min(bounds.width, bounds.width * fraction))
        let fillRect = CGRect(x: bounds.width - barWidth, y: 0, width: barWidth, height: bounds.height)
        let barColor = AppTheme.nsColor(for: recommendation).withAlphaComponent(isCleanable ? 0.78 : 0.38)
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(resolvedCGColor(barColor, in: effectiveAppearance))
        ctx.addPath(fillPath)
        ctx.fillPath()
    }
}

// MARK: - Pure AppKit Icon Action Button (Full Title & Hover Finder)

@MainActor
final class RowIconActionButton: NSButton {
    private let drawsRoundedBackdrop: Bool
    private var lastRenderedDark: Bool?

    override var isFlipped: Bool { true }

    init(
        symbolName: String,
        accessibilityLabel: String,
        drawsRoundedBackdrop: Bool
    ) {
        self.drawsRoundedBackdrop = drawsRoundedBackdrop
        super.init(frame: CGRect(origin: .zero, size: VirtualizedItemTableMetrics.actionButtonSize))
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        (cell as? NSButtonCell)?.highlightsBy = []
        title = ""
        imagePosition = .imageOnly
        image = ItemTableResources.symbolImage(named: symbolName, pointSize: 12, weight: .medium)
        contentTintColor = .secondaryLabelColor
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsRoundedBackdrop, let ctx = NSGraphicsContext.current?.cgContext {
            let isDark = isDarkEffectiveAppearance
            lastRenderedDark = isDark
            let alpha: CGFloat = isHighlighted
                ? (isDark ? 0.15 : 0.11)
                : (isDark ? 0.08 : 0.06)
            let fill = NSColor.labelColor.withAlphaComponent(alpha)
            let path = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(resolvedCGColor(fill, in: effectiveAppearance))
            ctx.addPath(path)
            ctx.fillPath()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Pure AppKit Section Bulk Selection Pill Button

@MainActor
final class SectionBulkPillButton: NSButton {
    private var recommendation: CleanupRecommendation = .recommended
    private var isAllBulkSelected: Bool = false
    private var lastRenderedDark: Bool?

    private let titleField = PassthroughLabel.makeLabel(
        font: ItemTableResources.sectionActionFont,
        alignment: .center,
        lineBreakMode: .byClipping
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        (cell as? NSButtonCell)?.highlightsBy = []
        title = ""
        focusRingType = .none
        wantsLayer = true
        addSubview(titleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        recommendation: CleanupRecommendation,
        isAllBulkSelected: Bool,
        selectTooltip: String,
        accessibilitySubject: String? = nil
    ) {
        self.recommendation = recommendation
        self.isAllBulkSelected = isAllBulkSelected

        let actionTitle = isAllBulkSelected ? "取消本组" : "全选本组"
        if titleField.stringValue != actionTitle {
            titleField.stringValue = actionTitle
        }

        let desiredTooltip = isAllBulkSelected ? "取消勾选本组当前可见条目" : selectTooltip
        if self.toolTip != desiredTooltip {
            self.toolTip = desiredTooltip
        }

        setAccessibilityLabel("\(actionTitle)：\(accessibilitySubject ?? recommendation.displayName)")
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    func refreshAppearance() {
        let isDark = isDarkEffectiveAppearance
        if lastRenderedDark != isDark {
            lastRenderedDark = isDark
            applyColors()
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    var preferredWidth: CGFloat {
        max(66, ceil(titleField.fittingSize.width) + 18)
    }

    override func layout() {
        super.layout()
        let textH = ceil(titleField.fittingSize.height)
        titleField.frame = CGRect(
            x: 9,
            y: floor((bounds.height - textH) / 2),
            width: max(0, bounds.width - 18),
            height: textH
        )
    }

    private func applyColors() {
        let tint = AppTheme.nsColor(for: recommendation)
        titleField.textColor = isAllBulkSelected ? .secondaryLabelColor : tint
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.height > 0 else { return }
        let isDark = isDarkEffectiveAppearance
        lastRenderedDark = isDark
        let tint = AppTheme.nsColor(for: recommendation)

        let bgColor: NSColor
        let borderColor: NSColor
        if isAllBulkSelected {
            bgColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.11 : 0.065)
            borderColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.18 : 0.12)
        } else {
            bgColor = tint.withAlphaComponent(isDark ? 0.16 : 0.11)
            borderColor = tint.withAlphaComponent(isDark ? 0.28 : 0.18)
        }

        ctx.saveGState()
        if isHighlighted {
            ctx.setAlpha(0.86)
        }

        let fillRect = bounds
        let fillRadius = fillRect.height / 2
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: fillRadius, cornerHeight: fillRadius, transform: nil)
        ctx.setFillColor(resolvedCGColor(bgColor, in: effectiveAppearance))
        ctx.addPath(fillPath)
        ctx.fillPath()

        let strokeRect = bounds.insetBy(dx: 0.35, dy: 0.35)
        let strokeRadius = strokeRect.height / 2
        let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil)
        ctx.setStrokeColor(resolvedCGColor(borderColor, in: effectiveAppearance))
        ctx.setLineWidth(0.7)
        ctx.addPath(strokePath)
        ctx.strokePath()

        ctx.restoreGState()
    }
}

// MARK: - Pure AppKit Reusable Cell 1: Item Row Cell (54pt)

@MainActor
final class ItemRowTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ItemRowCell")

    private(set) var currentRow: ItemDisplayRow?
    private(set) var isCurrentlySelected: Bool = false
    private(set) var isCurrentlyHovered: Bool = false
    private var isTrackingCardClick: Bool = false

    let cardBackgroundView = ItemCardBackgroundView()
    let checkboxControl = RowCheckboxControl()
    private let iconBadgeView = CategoryIconBadgeView()

    private let titleLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.titleFont,
        color: .labelColor,
        lineBreakMode: .byTruncatingTail
    )

    private let detailLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.detailFont,
        color: .secondaryLabelColor,
        lineBreakMode: .byTruncatingTail
    )

    private let riskSelectedBadge = PillBadgeView(
        text: "高风险已选",
        font: ItemTableResources.badgeSemiboldFont,
        style: .tinted(color: AppTheme.nsColor(for: .notRecommended), darkAlpha: 0.18, lightAlpha: 0.18),
        horizontalPadding: 6,
        fixedHeight: 15
    )

    private let sourceBadgeView = PillBadgeView(
        text: "",
        font: ItemTableResources.badgeMediumFont,
        style: .neutral(darkAlpha: 0.10, lightAlpha: 0.065),
        horizontalPadding: 6,
        fixedHeight: 15
    )

    private let recentBadgeView = PillBadgeView(
        text: "近期修改",
        font: ItemTableResources.badgeSemiboldFont,
        style: .tinted(color: AppTheme.nsColor(for: .reviewSuggested), darkAlpha: 0.18, lightAlpha: 0.13),
        horizontalPadding: 6,
        fixedHeight: 15
    )

    private let clientNameLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.clientNameFont,
        color: .tertiaryLabelColor,
        lineBreakMode: .byTruncatingTail
    )

    let fullTitleButton = RowIconActionButton(
        symbolName: "text.alignleft",
        accessibilityLabel: "查看完整会话标题",
        drawsRoundedBackdrop: false
    )

    let finderButton = RowIconActionButton(
        symbolName: "folder",
        accessibilityLabel: "在 Finder 中显示",
        drawsRoundedBackdrop: true
    )

    private let sizeLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.sizeFont,
        color: .labelColor,
        alignment: .right,
        lineBreakMode: .byClipping
    )

    private let dateLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.dateFont,
        color: .tertiaryLabelColor,
        alignment: .right,
        lineBreakMode: .byClipping
    )

    private let ratioBarView = RatioBarView()

    // 预缓存局部度量，减少 layout 期间文本测量开销
    private var cachedTitleWidth: CGFloat = 0
    private var cachedClientNameWidth: CGFloat = 0
    private var cachedSizeWidth: CGFloat = 0
    private var cachedDateWidth: CGFloat = 0

    var onToggleSelection: (@MainActor (CleanableItem) -> Void)?
    var onRevealInFinder: (@MainActor (CleanableItem) -> Void)?
    var onShowFullTitle: (@MainActor (ItemDisplayRow, NSView) -> Void)?

    var currentRowID: String? { currentRow?.id }
    var isFinderButtonVisible: Bool { !finderButton.isHidden }
    var isFullTitleButtonVisible: Bool { !fullTitleButton.isHidden }
    var isRiskSelectedBadgeVisible: Bool { !riskSelectedBadge.isHidden }
    var isSourceBadgeVisible: Bool { !sourceBadgeView.isHidden }
    var isRecentBadgeVisible: Bool { !recentBadgeView.isHidden }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        addSubview(cardBackgroundView)
        addSubview(checkboxControl)
        addSubview(iconBadgeView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(riskSelectedBadge)
        addSubview(sourceBadgeView)
        addSubview(recentBadgeView)
        addSubview(clientNameLabel)
        addSubview(fullTitleButton)
        addSubview(finderButton)
        addSubview(sizeLabel)
        addSubview(dateLabel)
        addSubview(ratioBarView)

        riskSelectedBadge.isHidden = true
        sourceBadgeView.isHidden = true
        recentBadgeView.isHidden = true
        clientNameLabel.isHidden = true
        fullTitleButton.isHidden = true
        finderButton.isHidden = true

        fullTitleButton.toolTip = "查看完整会话标题"

        checkboxControl.onToggle = { [weak self] in
            guard let self, let item = self.currentRow?.item else { return }
            self.onToggleSelection?(item)
        }

        fullTitleButton.target = self
        fullTitleButton.action = #selector(handleFullTitleButtonClick)

        finderButton.target = self
        finderButton.action = #selector(handleFinderButtonClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isTrackingCardClick = false
        isCurrentlyHovered = false
        finderButton.isHidden = true
    }

    func configure(
        row: ItemDisplayRow,
        isSelected: Bool,
        isHovered: Bool,
        onToggleSelection: @escaping @MainActor (CleanableItem) -> Void,
        onRevealInFinder: @escaping @MainActor (CleanableItem) -> Void,
        onShowFullTitle: @escaping @MainActor (ItemDisplayRow, NSView) -> Void
    ) {
        let previousRow = currentRow
        let previousSelected = isCurrentlySelected
        let previousHovered = isCurrentlyHovered

        self.currentRow = row
        self.isCurrentlySelected = isSelected
        self.isCurrentlyHovered = isHovered
        self.onToggleSelection = onToggleSelection
        self.onRevealInFinder = onRevealInFinder
        self.onShowFullTitle = onShowFullTitle

        let item = row.item
        var layoutDirty = (previousRow == nil)

        // 1. 卡片背景与边框（含脏检查）
        cardBackgroundView.update(
            position: row.position,
            recommendation: item.recommendation,
            isSelected: isSelected,
            isHovered: isHovered
        )

        // 2. 复选框 / 风险锁 / 硬保护锁
        checkboxControl.update(
            mode: checkboxMode(for: item, isSelected: isSelected, isHovered: isHovered),
            recommendation: item.recommendation,
            hardProtectionTooltip: item.hardProtectionReason
        )

        // 3. 类别图标徽章
        iconBadgeView.update(
            symbolName: ItemRowVisuals.leadingSymbolName(for: item),
            tintColor: ItemRowVisuals.leadingSymbolColor(for: item)
        )

        // 4. 主副标题
        if titleLabel.stringValue != row.title {
            titleLabel.stringValue = row.title
            cachedTitleWidth = ceil(titleLabel.fittingSize.width)
            layoutDirty = true
        }
        titleLabel.textColor = (item.isCleanable || isSelected) ? .labelColor : .secondaryLabelColor

        if detailLabel.stringValue != row.detailText {
            detailLabel.stringValue = row.detailText
        }

        // 5. 标题行徽标（高风险已选 / sourceBadge / 近期修改 / 客户端名称）
        let showRiskBadge = !item.isCleanable && isSelected
        if riskSelectedBadge.isHidden == showRiskBadge {
            riskSelectedBadge.isHidden = !showRiskBadge
            layoutDirty = true
        }
        if showRiskBadge {
            riskSelectedBadge.configure(
                text: "高风险已选",
                style: .tinted(color: AppTheme.nsColor(for: item.recommendation), darkAlpha: 0.18, lightAlpha: 0.18)
            )
        }

        if let sourceBadge = item.sourceBadge {
            if sourceBadgeView.isHidden {
                sourceBadgeView.isHidden = false
                layoutDirty = true
            }
            if previousRow?.item.sourceBadge != sourceBadge {
                sourceBadgeView.configure(
                    text: sourceBadge,
                    style: .neutral(darkAlpha: 0.10, lightAlpha: 0.065)
                )
                layoutDirty = true
            }
        } else if !sourceBadgeView.isHidden {
            sourceBadgeView.isHidden = true
            layoutDirty = true
        }

        let showRecent = item.isRecentlyModified
        if recentBadgeView.isHidden == showRecent {
            recentBadgeView.isHidden = !showRecent
            layoutDirty = true
        }

        let showClient = row.showClientBadge
        if clientNameLabel.isHidden == showClient {
            clientNameLabel.isHidden = !showClient
            layoutDirty = true
        }
        if showClient && clientNameLabel.stringValue != item.clientName {
            clientNameLabel.stringValue = item.clientName
            cachedClientNameWidth = ceil(clientNameLabel.fittingSize.width)
            layoutDirty = true
        }

        // 6. 会话完整标题图标按钮
        let showFullTitle = item.category == .sessions || item.sessionTitle != nil
        if fullTitleButton.isHidden == showFullTitle {
            fullTitleButton.isHidden = !showFullTitle
            layoutDirty = true
        }

        // 7. 悬停 Finder 定位按钮（不触发布局重排，占位固定 26×24）
        if finderButton.isHidden == isHovered {
            finderButton.isHidden = !isHovered
        }
        if isHovered && (previousHovered != isHovered || previousRow?.id != row.id) {
            if finderButton.toolTip != row.finderTooltip {
                finderButton.toolTip = row.finderTooltip
            }
        }

        // 8. 右侧体积 / 日期 / 比例条
        if sizeLabel.stringValue != row.sizeText {
            sizeLabel.stringValue = row.sizeText
            cachedSizeWidth = ceil(sizeLabel.fittingSize.width)
            layoutDirty = true
        }
        sizeLabel.textColor = item.isCleanable ? .labelColor : .secondaryLabelColor

        if dateLabel.stringValue != row.dateText {
            dateLabel.stringValue = row.dateText
            cachedDateWidth = ceil(dateLabel.fittingSize.width)
            layoutDirty = true
        }

        ratioBarView.update(
            fraction: row.relativeSizeFraction,
            recommendation: item.recommendation,
            isCleanable: item.isCleanable,
            hasPositiveSize: item.sizeBytes > 0
        )

        // 9. 轻量 Tooltip（直接复用预计算字符串，仅内容变化时更新以避免多余追踪区重建）
        if self.toolTip != row.rowTooltip {
            self.toolTip = row.rowTooltip
        }

        if layoutDirty || previousSelected != isSelected && !item.isCleanable {
            needsLayout = true
        }
    }

    /// 局部刷新选中态（仅 O(1) 更新可见 Cell 内部属性，绝不触发整表 reloadData）
    func setSelected(_ isSelected: Bool) {
        guard isCurrentlySelected != isSelected, let row = currentRow else { return }
        isCurrentlySelected = isSelected
        let item = row.item

        cardBackgroundView.update(
            position: row.position,
            recommendation: item.recommendation,
            isSelected: isSelected,
            isHovered: isCurrentlyHovered
        )
        checkboxControl.update(
            mode: checkboxMode(for: item, isSelected: isSelected, isHovered: isCurrentlyHovered),
            recommendation: item.recommendation,
            hardProtectionTooltip: item.hardProtectionReason
        )
        titleLabel.textColor = (item.isCleanable || isSelected) ? .labelColor : .secondaryLabelColor

        let showRiskBadge = !item.isCleanable && isSelected
        if riskSelectedBadge.isHidden == showRiskBadge {
            riskSelectedBadge.isHidden = !showRiskBadge
            if showRiskBadge {
                riskSelectedBadge.configure(
                    text: "高风险已选",
                    style: .tinted(color: AppTheme.nsColor(for: item.recommendation), darkAlpha: 0.18, lightAlpha: 0.18)
                )
            }
            needsLayout = true
        }
    }

    /// 局部刷新悬停态（仅更新当前行背景、风险锁悬停色与 Finder 按钮显隐，零重排、零 reloadData）
    func setHovered(_ isHovered: Bool) {
        guard isCurrentlyHovered != isHovered, let row = currentRow else { return }
        isCurrentlyHovered = isHovered
        let item = row.item

        cardBackgroundView.update(
            position: row.position,
            recommendation: item.recommendation,
            isSelected: isCurrentlySelected,
            isHovered: isHovered
        )
        if item.hardProtectionReason == nil && !item.isCleanable {
            checkboxControl.update(
                mode: checkboxMode(for: item, isSelected: isCurrentlySelected, isHovered: isHovered),
                recommendation: item.recommendation,
                hardProtectionTooltip: nil
            )
        }
        finderButton.isHidden = !isHovered
        if isHovered && finderButton.toolTip != row.finderTooltip {
            finderButton.toolTip = row.finderTooltip
        }
    }

    func refreshAppearance() {
        cardBackgroundView.refreshAppearance()
        checkboxControl.refreshAppearance()
        iconBadgeView.refreshAppearance()
        riskSelectedBadge.refreshAppearance()
        sourceBadgeView.refreshAppearance()
        recentBadgeView.refreshAppearance()
        fullTitleButton.refreshAppearance()
        finderButton.refreshAppearance()
        ratioBarView.refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func layout() {
        super.layout()

        let w = bounds.width
        let h = bounds.height
        let margin = VirtualizedItemTableMetrics.horizontalMargin
        let cardWidth = max(0, w - margin * 2)
        let cardFrame = CGRect(x: margin, y: 0, width: cardWidth, height: h)
        cardBackgroundView.frame = cardFrame

        let innerPad = VirtualizedItemTableMetrics.cardHorizontalPadding
        let contentMinX = cardFrame.minX + innerPad
        let contentMaxX = cardFrame.maxX - innerPad

        // 1. 左侧复选框 (17×17) 与类别图标 (28×28)
        let cbSize = VirtualizedItemTableMetrics.checkboxSize
        checkboxControl.frame = CGRect(
            x: contentMinX,
            y: round((h - cbSize) / 2),
            width: cbSize,
            height: cbSize
        )

        let iconSize = VirtualizedItemTableMetrics.iconBadgeSize
        let iconX = checkboxControl.frame.maxX + 11
        iconBadgeView.frame = CGRect(
            x: iconX,
            y: round((h - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )

        // 2. 右侧固定对齐区（体积/日期/比例条 + 悬停 Finder 按钮 + 可选会话完整标题按钮）
        var cursorRight = contentMaxX

        let ratioW = VirtualizedItemTableMetrics.ratioBarSize.width
        let ratioH = VirtualizedItemTableMetrics.ratioBarSize.height
        let dateRowWidth = cachedDateWidth + 6 + ratioW
        let trailingColWidth = max(
            VirtualizedItemTableMetrics.minimumTrailingColumnWidth,
            max(cachedSizeWidth, dateRowWidth)
        )
        let trailingColX = cursorRight - trailingColWidth

        let sizeH: CGFloat = 15
        let dateH: CGFloat = 13
        let rightStackH = sizeH + 3 + dateH
        let rightTopY = round((h - rightStackH) / 2)

        sizeLabel.frame = CGRect(
            x: trailingColX,
            y: rightTopY,
            width: trailingColWidth,
            height: sizeH
        )

        let dateY = rightTopY + sizeH + 3
        let ratioX = cursorRight - ratioW
        ratioBarView.frame = CGRect(
            x: ratioX,
            y: dateY + (dateH - ratioH) / 2,
            width: ratioW,
            height: ratioH
        )
        dateLabel.frame = CGRect(
            x: max(trailingColX, ratioX - 6 - cachedDateWidth),
            y: dateY,
            width: cachedDateWidth,
            height: dateH
        )

        cursorRight = trailingColX - 11

        let btnSize = VirtualizedItemTableMetrics.actionButtonSize
        let btnY = round((h - btnSize.height) / 2)
        finderButton.frame = CGRect(
            x: cursorRight - btnSize.width,
            y: btnY,
            width: btnSize.width,
            height: btnSize.height
        )
        cursorRight -= btnSize.width + 11

        if !fullTitleButton.isHidden {
            fullTitleButton.frame = CGRect(
                x: cursorRight - btnSize.width,
                y: btnY,
                width: btnSize.width,
                height: btnSize.height
            )
            cursorRight -= btnSize.width + 11
        }

        // 3. 中间文本区（主标题 + 徽标 / 副标题）
        let textStartX = iconBadgeView.frame.maxX + 11
        let textMaxX = max(textStartX, cursorRight + 1)
        let textAvailableW = max(0, textMaxX - textStartX)

        let titleH: CGFloat = 16
        let detailH: CGFloat = 13
        let textStackH = titleH + 2.5 + detailH
        let textTopY = round((h - textStackH) / 2)

        detailLabel.frame = CGRect(
            x: textStartX,
            y: textTopY + titleH + 2.5,
            width: textAvailableW,
            height: detailH
        )

        // 计算固定徽标总宽度，确保徽标不截断、主标题优雅截断
        var pillWidths: CGFloat = 0
        if !riskSelectedBadge.isHidden {
            pillWidths += 7 + riskSelectedBadge.cachedWidth
        }
        if !sourceBadgeView.isHidden {
            pillWidths += 7 + sourceBadgeView.cachedWidth
        }
        if !recentBadgeView.isHidden {
            pillWidths += 7 + recentBadgeView.cachedWidth
        }

        let remainingAfterPills = max(0, textAvailableW - pillWidths)
        let titleWidth: CGFloat
        let clientWidth: CGFloat
        if !clientNameLabel.isHidden && cachedClientNameWidth > 0 {
            let preferredForTitle = max(min(remainingAfterPills, 60), remainingAfterPills - cachedClientNameWidth - 7)
            titleWidth = min(cachedTitleWidth, min(remainingAfterPills, preferredForTitle))
            clientWidth = min(cachedClientNameWidth, max(0, remainingAfterPills - titleWidth - 7))
        } else {
            titleWidth = min(cachedTitleWidth, remainingAfterPills)
            clientWidth = 0
        }

        titleLabel.frame = CGRect(
            x: textStartX,
            y: textTopY,
            width: titleWidth,
            height: titleH
        )

        var cursorX = textStartX + titleWidth
        let badgeH: CGFloat = 15
        let badgeY = textTopY + round((titleH - badgeH) / 2)

        if !riskSelectedBadge.isHidden {
            cursorX += 7
            let bw = riskSelectedBadge.cachedWidth
            riskSelectedBadge.frame = CGRect(x: cursorX, y: badgeY, width: bw, height: badgeH)
            cursorX += bw
        }
        if !sourceBadgeView.isHidden {
            cursorX += 7
            let bw = sourceBadgeView.cachedWidth
            sourceBadgeView.frame = CGRect(x: cursorX, y: badgeY, width: bw, height: badgeH)
            cursorX += bw
        }
        if !recentBadgeView.isHidden {
            cursorX += 7
            let bw = recentBadgeView.cachedWidth
            recentBadgeView.frame = CGRect(x: cursorX, y: badgeY, width: bw, height: badgeH)
            cursorX += bw
        }
        if !clientNameLabel.isHidden && clientWidth > 0 {
            cursorX += 7
            clientNameLabel.frame = CGRect(
                x: cursorX,
                y: textTopY + round((titleH - 13) / 2) + 0.5,
                width: clientWidth,
                height: 13
            )
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var ancestor = superview
        while let current = ancestor {
            if let tableView = current as? ItemTableView {
                return tableView.menu(for: event)
            }
            ancestor = current.superview
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        isTrackingCardClick = cardBackgroundView.frame.contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseUp(with: event)
            return
        }
        let wasTracking = isTrackingCardClick
        isTrackingCardClick = false
        guard wasTracking, let item = currentRow?.item else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard cardBackgroundView.frame.contains(point) else { return }
        if item.hardProtectionReason == nil {
            onToggleSelection?(item)
        }
    }

    private func checkboxMode(
        for item: CleanableItem,
        isSelected: Bool,
        isHovered: Bool
    ) -> RowCheckboxControl.Mode {
        if item.hardProtectionReason != nil {
            return .hardProtected
        }
        if item.isCleanable {
            return .cleanable(isChecked: isSelected)
        }
        return .riskOverridable(isChecked: isSelected, isHovered: isHovered)
    }

    @objc private func handleFullTitleButtonClick() {
        guard let row = currentRow else { return }
        onShowFullTitle?(row, fullTitleButton)
    }

    @objc private func handleFinderButtonClick() {
        guard let item = currentRow?.item else { return }
        onRevealInFinder?(item)
    }
}

// MARK: - Pure AppKit Reusable Cell 2: Section Header Cell (36pt / 48pt)

@MainActor
final class SectionHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SectionHeaderCell")

    private(set) var currentHeader: SectionHeaderRow?
    private(set) var isCurrentlyAllBulkSelected: Bool = false

    let collapseButton: NSButton = {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.title = ""
        button.focusRingType = .none
        return button
    }()

    private let chevronView: PassthroughImageView = {
        let view = PassthroughImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.contentTintColor = .tertiaryLabelColor
        return view
    }()

    private let statusDotView: PassthroughView = {
        let view = PassthroughView()
        view.wantsLayer = true
        return view
    }()

    private let titleLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.sectionTitleFont,
        color: .labelColor,
        lineBreakMode: .byClipping
    )

    private let summaryLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.sectionSummaryFont,
        color: .secondaryLabelColor,
        lineBreakMode: .byTruncatingTail
    )

    let bulkActionButton = SectionBulkPillButton()

    private let manualOnlyPill = PillBadgeView(
        text: "仅逐条手选",
        font: ItemTableResources.sectionActionFont,
        style: .tinted(color: AppTheme.nsColor(for: .reviewSuggested), darkAlpha: 0.11, lightAlpha: 0.11),
        horizontalPadding: 8,
        fixedHeight: 22,
        allowsHitTesting: true
    )

    var onToggleCollapse: (@MainActor (CleanupRecommendation) -> Void)?
    var onToggleBulkSelection: (@MainActor (CleanupRecommendation) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        addSubview(chevronView)
        addSubview(statusDotView)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(collapseButton)
        addSubview(bulkActionButton)
        addSubview(manualOnlyPill)

        manualOnlyPill.toolTip = "本组条目需逐条手动确认勾选，所有批量勾选操作均会自动跳过"
        manualOnlyPill.isHidden = true
        bulkActionButton.isHidden = true

        collapseButton.target = self
        collapseButton.action = #selector(handleCollapseClick)

        bulkActionButton.target = self
        bulkActionButton.action = #selector(handleBulkSelectionClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        header: SectionHeaderRow,
        isAllBulkSelected: Bool,
        onToggleCollapse: @escaping @MainActor (CleanupRecommendation) -> Void,
        onToggleBulkSelection: @escaping @MainActor (CleanupRecommendation) -> Void
    ) {
        self.currentHeader = header
        self.isCurrentlyAllBulkSelected = isAllBulkSelected
        self.onToggleCollapse = onToggleCollapse
        self.onToggleBulkSelection = onToggleBulkSelection

        let chevronSymbol = header.isCollapsed ? "chevron.right" : "chevron.down"
        chevronView.image = ItemTableResources.symbolImage(named: chevronSymbol, pointSize: 10, weight: .bold)

        let tint = AppTheme.nsColor(for: header.recommendation)
        statusDotView.layer?.backgroundColor = resolvedCGColor(tint, in: effectiveAppearance)
        statusDotView.layer?.cornerRadius = 3.5

        titleLabel.stringValue = header.recommendation.displayName
        summaryLabel.stringValue = header.summaryText

        collapseButton.setAccessibilityLabel(
            "\(header.isCollapsed ? "展开" : "折叠")\(header.recommendation.displayName)"
        )

        if header.supportsBulkSelection {
            bulkActionButton.isHidden = false
            manualOnlyPill.isHidden = true
            bulkActionButton.configure(
                recommendation: header.recommendation,
                isAllBulkSelected: isAllBulkSelected,
                selectTooltip: header.selectBulkTooltip
            )
        } else if header.recommendation == .reviewSuggested {
            bulkActionButton.isHidden = true
            manualOnlyPill.isHidden = false
        } else {
            bulkActionButton.isHidden = true
            manualOnlyPill.isHidden = true
        }

        needsLayout = true
    }

    func setAllBulkSelected(_ isAllBulkSelected: Bool) {
        guard isCurrentlyAllBulkSelected != isAllBulkSelected, let header = currentHeader else { return }
        isCurrentlyAllBulkSelected = isAllBulkSelected
        if header.supportsBulkSelection {
            bulkActionButton.configure(
                recommendation: header.recommendation,
                isAllBulkSelected: isAllBulkSelected,
                selectTooltip: header.selectBulkTooltip
            )
            needsLayout = true
        }
    }

    func refreshAppearance() {
        if let header = currentHeader {
            let tint = AppTheme.nsColor(for: header.recommendation)
            statusDotView.layer?.backgroundColor = resolvedCGColor(tint, in: effectiveAppearance)
        }
        bulkActionButton.refreshAppearance()
        manualOnlyPill.refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func layout() {
        super.layout()
        guard let header = currentHeader else { return }

        let leftX = VirtualizedItemTableMetrics.horizontalMargin + VirtualizedItemTableMetrics.sectionHeaderExtraHorizontalPadding
        let rightX = bounds.width - leftX
        let topPad = header.isFirstSection
            ? VirtualizedItemTableMetrics.sectionHeaderFirstTopPadding
            : VirtualizedItemTableMetrics.sectionHeaderSubsequentTopPadding
        let contentH = VirtualizedItemTableMetrics.sectionHeaderContentHeight
        let midY = topPad + contentH / 2

        // 右侧按钮 / 仅手选标签
        var trailingLimitX = rightX
        if !bulkActionButton.isHidden {
            let btnW = bulkActionButton.preferredWidth
            bulkActionButton.frame = CGRect(
                x: rightX - btnW,
                y: round(midY - 11),
                width: btnW,
                height: 22
            )
            trailingLimitX = bulkActionButton.frame.minX - 8
        } else if !manualOnlyPill.isHidden {
            let pillW = manualOnlyPill.cachedWidth
            manualOnlyPill.frame = CGRect(
                x: rightX - pillW,
                y: round(midY - 11),
                width: pillW,
                height: 22
            )
            trailingLimitX = manualOnlyPill.frame.minX - 8
        }

        // 左侧折叠触发组
        var cursorX = leftX
        chevronView.frame = CGRect(x: cursorX, y: round(midY - 6), width: 11, height: 12)
        cursorX += 11 + 7

        statusDotView.frame = CGRect(x: cursorX, y: round(midY - 3.5), width: 7, height: 7)
        cursorX += 7 + 7

        let titleFit = titleLabel.fittingSize
        let titleW = min(ceil(titleFit.width), max(0, trailingLimitX - cursorX))
        titleLabel.frame = CGRect(x: cursorX, y: round(midY - titleFit.height / 2), width: titleW, height: ceil(titleFit.height))
        cursorX += titleW + 7

        let summaryFit = summaryLabel.fittingSize
        let summaryW = min(ceil(summaryFit.width), max(0, trailingLimitX - cursorX))
        summaryLabel.frame = CGRect(x: cursorX, y: round(midY - summaryFit.height / 2), width: summaryW, height: ceil(summaryFit.height))

        let collapseRightX = min(trailingLimitX, cursorX + summaryW)
        collapseButton.frame = CGRect(
            x: leftX,
            y: topPad,
            width: max(0, collapseRightX - leftX),
            height: contentH
        )
    }

    @objc private func handleCollapseClick() {
        guard let recommendation = currentHeader?.recommendation else { return }
        onToggleCollapse?(recommendation)
    }

    @objc private func handleBulkSelectionClick() {
        guard let recommendation = currentHeader?.recommendation else { return }
        onToggleBulkSelection?(recommendation)
    }
}

/// 「按项目会话分组」模式下的项目分组头：展示项目名与汇总，右侧提供「全选本组 / 取消本组」，沿用现有批量勾选规则
@MainActor
final class ProjectHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ProjectHeaderCell")

    private(set) var currentHeader: ProjectHeaderRow?
    private(set) var isCurrentlyAllBulkSelected: Bool = false

    let bulkActionButton = SectionBulkPillButton()
    var onToggleBulkSelection: (@MainActor (SessionProjectID) -> Void)?

    private let folderIconView: PassthroughImageView = {
        let view = PassthroughImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.contentTintColor = .secondaryLabelColor
        return view
    }()

    private let titleLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.sectionTitleFont,
        color: .labelColor,
        lineBreakMode: .byTruncatingTail
    )

    private let summaryLabel = PassthroughLabel.makeLabel(
        font: ItemTableResources.sectionSummaryFont,
        color: .secondaryLabelColor,
        lineBreakMode: .byTruncatingTail
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        addSubview(folderIconView)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(bulkActionButton)

        bulkActionButton.isHidden = true
        bulkActionButton.target = self
        bulkActionButton.action = #selector(handleBulkSelectionClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        header: ProjectHeaderRow,
        isAllBulkSelected: Bool = false,
        onToggleBulkSelection: (@MainActor (SessionProjectID) -> Void)? = nil
    ) {
        currentHeader = header
        isCurrentlyAllBulkSelected = isAllBulkSelected
        self.onToggleBulkSelection = onToggleBulkSelection
        titleLabel.stringValue = header.title
        summaryLabel.stringValue = header.summaryText
        folderIconView.image = ItemTableResources.symbolImage(named: "folder", pointSize: 10, weight: .regular)
        titleLabel.toolTip = header.project.workspacePath ?? header.title
        bulkActionButton.isHidden = !header.supportsBulkSelection
        if header.supportsBulkSelection {
            configureBulkButton()
        }
        needsLayout = true
    }

    func setAllBulkSelected(_ isAllBulkSelected: Bool) {
        guard isCurrentlyAllBulkSelected != isAllBulkSelected, let header = currentHeader else { return }
        isCurrentlyAllBulkSelected = isAllBulkSelected
        if header.supportsBulkSelection {
            configureBulkButton()
            needsLayout = true
        }
    }

    private func configureBulkButton() {
        guard let header = currentHeader else { return }
        bulkActionButton.configure(
            recommendation: .recommended,
            isAllBulkSelected: isCurrentlyAllBulkSelected,
            selectTooltip: header.selectBulkTooltip,
            accessibilitySubject: header.title
        )
    }

    @objc private func handleBulkSelectionClick() {
        guard let project = currentHeader?.project else { return }
        onToggleBulkSelection?(project)
    }

    func refreshAppearance() {
        folderIconView.contentTintColor = .secondaryLabelColor
        bulkActionButton.refreshAppearance()
    }

    override func layout() {
        super.layout()
        guard let header = currentHeader else { return }

        let leftX = VirtualizedItemTableMetrics.horizontalMargin + VirtualizedItemTableMetrics.sectionHeaderExtraHorizontalPadding
        let rightX = bounds.width - leftX
        let topPad = header.isFirstSection
            ? VirtualizedItemTableMetrics.sectionHeaderFirstTopPadding
            : VirtualizedItemTableMetrics.sectionHeaderSubsequentTopPadding
        let contentH = VirtualizedItemTableMetrics.sectionHeaderContentHeight
        let midY = topPad + contentH / 2

        var trailingLimitX = rightX
        if !bulkActionButton.isHidden {
            let btnW = bulkActionButton.preferredWidth
            bulkActionButton.frame = CGRect(x: rightX - btnW, y: round(midY - 11), width: btnW, height: 22)
            trailingLimitX = bulkActionButton.frame.minX - 8
        }

        var cursorX = leftX
        folderIconView.frame = CGRect(x: cursorX, y: round(midY - 6), width: 12, height: 12)
        cursorX += 12 + 7

        let titleFit = titleLabel.fittingSize
        let summaryFit = summaryLabel.fittingSize
        let availableW = max(0, trailingLimitX - cursorX)
        let summaryW = min(ceil(summaryFit.width), max(0, availableW / 2))
        let titleW = min(ceil(titleFit.width), max(0, availableW - summaryW - 7))
        titleLabel.frame = CGRect(x: cursorX, y: round(midY - titleFit.height / 2), width: titleW, height: ceil(titleFit.height))
        summaryLabel.frame = CGRect(
            x: cursorX + titleW + 7,
            y: round(midY - summaryFit.height / 2),
            width: summaryW,
            height: ceil(summaryFit.height)
        )
    }
}

// MARK: - Single-Instance Full Session Title Popover Controller

@MainActor
final class FullTitlePopoverController: NSViewController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private(set) var currentTitleText: String = ""

    override func loadView() {
        let size = VirtualizedItemTableMetrics.popoverContentSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        scrollView.frame = container.bounds.insetBy(dx: 14, dy: 14)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = ItemTableResources.popoverBodyFont
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = currentTitleText

        scrollView.documentView = textView
        container.addSubview(scrollView)
        self.view = container
    }

    func setTitleText(_ text: String) {
        currentTitleText = text
        guard isViewLoaded else { return }
        textView.string = text
        textView.textColor = .labelColor
        textView.scrollToBeginningOfDocument(nil)
    }
}

// MARK: - Custom NSTableView (Single NSTrackingArea + Margin-Aware Hover & Context Menu)

@MainActor
final class ItemTableView: NSTableView {
    private var hoverTrackingArea: NSTrackingArea?
    var isLiveScrolling: Bool = false

    var onHoverPointChanged: (@MainActor (NSPoint?) -> Void)?
    var canShowContextMenuForRow: (@MainActor (Int) -> Bool)?
    var onWillShowContextMenuForRow: (@MainActor (Int) -> Void)?
    var onAppearanceChanged: (@MainActor () -> Void)?

    var activeHoverTrackingAreaCount: Int {
        hoverTrackingArea == nil ? 0 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isLiveScrolling else { return }
        let point = convert(event.locationInWindow, from: nil)
        onHoverPointChanged?(point)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isLiveScrolling else { return }
        let point = convert(event.locationInWindow, from: nil)
        onHoverPointChanged?(point)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverPointChanged?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let margin = VirtualizedItemTableMetrics.horizontalMargin
        guard point.x >= margin, point.x <= bounds.width - margin else {
            return nil
        }
        let hitRow = row(at: point)
        guard hitRow >= 0, canShowContextMenuForRow?(hitRow) == true else {
            return nil
        }
        onWillShowContextMenuForRow?(hitRow)
        return self.menu
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        syncPrimaryColumnWidth()
    }

    func syncPrimaryColumnWidth() {
        guard let column = tableColumns.first else { return }
        let targetWidth = max(200, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        if abs(column.width - targetWidth) > 0.5 {
            column.width = targetWidth
        }
    }
}

// MARK: - Virtualized Item Table Coordinator & Controller

@MainActor
final class VirtualizedItemTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSPopoverDelegate {
    weak var scrollView: NSScrollView?
    weak var tableView: ItemTableView?
    weak var viewModel: CleanerViewModel?

    private(set) var rows: [FlatListRow] = []
    private(set) var lastRowsRevision: Int = -1
    private(set) var lastSelectionRevision: Int = -1
    private(set) var lastViewportID: Int = -1
    private var lastColorScheme: ColorScheme?

    private(set) var hoveredRow: Int = -1
    private(set) var isLiveScrolling: Bool = false

    // 单实例右键菜单
    let sharedContextMenu: NSMenu = {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        return menu
    }()
    private var pendingContextMenuRow: Int = -1

    // 单实例「查看完整会话标题」弹窗
    let fullTitlePopover = NSPopover()
    let fullTitlePopoverController = FullTitlePopoverController()
    private(set) var activePopoverItemID: String?
    private var lastClosedPopoverItemID: String?
    private var lastPopoverCloseTime: CFTimeInterval = 0

    private let observerBag = TableNotificationObserverBag()

    // 复用与局部刷新指标（轻量整型计数，用于单元测试与实机验证观测）
    private(set) var createdItemCellCount: Int = 0
    private(set) var createdSectionHeaderCellCount: Int = 0
    private(set) var reusedItemCellCount: Int = 0
    private(set) var reusedSectionHeaderCellCount: Int = 0
    private(set) var reloadDataCount: Int = 0
    private(set) var selectionOnlyRefreshCount: Int = 0
    private(set) var hoverRefreshCount: Int = 0
    private let allocatedItemCells = NSHashTable<ItemRowTableCellView>.weakObjects()

    var liveItemCellCount: Int {
        allocatedItemCells.allObjects.count
    }

    var activeObserverCount: Int {
        observerBag.count
    }

    override init() {
        super.init()
        sharedContextMenu.delegate = self

        fullTitlePopover.contentViewController = fullTitlePopoverController
        fullTitlePopover.contentSize = VirtualizedItemTableMetrics.popoverContentSize
        fullTitlePopover.behavior = .transient
        fullTitlePopover.animates = true
        fullTitlePopover.delegate = self
    }

    func attach(scrollView: NSScrollView, tableView: ItemTableView) {
        self.scrollView = scrollView
        self.tableView = tableView

        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = sharedContextMenu

        tableView.onHoverPointChanged = { [weak self] point in
            self?.handleHoverPoint(point)
        }
        tableView.canShowContextMenuForRow = { [weak self] row in
            self?.itemRow(at: row) != nil
        }
        tableView.onWillShowContextMenuForRow = { [weak self] row in
            self?.pendingContextMenuRow = row
        }
        tableView.onAppearanceChanged = { [weak self] in
            self?.syncAppearanceToVisibleCellsAndPopover()
        }

        observerBag.removeAll()

        observerBag.add(name: NSScrollView.willStartLiveScrollNotification, object: scrollView) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillStartLiveScroll()
            }
        }
        observerBag.add(name: NSScrollView.didEndLiveScrollNotification, object: scrollView) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidEndLiveScroll()
            }
        }

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true

        observerBag.add(name: NSView.boundsDidChangeNotification, object: clipView) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleClipViewBoundsChanged()
            }
        }
        observerBag.add(name: NSView.frameDidChangeNotification, object: clipView) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tableView?.syncPrimaryColumnWidth()
            }
        }
    }

    func teardown() {
        closeFullTitlePopover(animated: false)
        observerBag.removeAll()
        if let tableView {
            tableView.onHoverPointChanged = nil
            tableView.canShowContextMenuForRow = nil
            tableView.onWillShowContextMenuForRow = nil
            tableView.onAppearanceChanged = nil
            tableView.menu = nil
            tableView.dataSource = nil
            tableView.delegate = nil
        }
        sharedContextMenu.delegate = nil
        fullTitlePopover.delegate = nil
    }

    // MARK: - State Synchronization (O(1) Revision Checks)

    func applyState(
        rows: [FlatListRow],
        rowsRevision: Int,
        selectionRevision: Int,
        viewportID: Int,
        colorScheme: ColorScheme?,
        viewModel: CleanerViewModel
    ) {
        self.viewModel = viewModel
        guard let tableView, let scrollView else { return }

        let viewportChanged = (lastViewportID != viewportID)
        let rowsChanged = (lastRowsRevision != rowsRevision)

        if viewportChanged || rowsChanged {
            let savedOriginY = scrollView.contentView.bounds.origin.y
            closeFullTitlePopover(animated: false)
            hoveredRow = -1

            self.rows = rows
            self.lastRowsRevision = rowsRevision
            self.lastViewportID = viewportID
            self.lastSelectionRevision = selectionRevision

            reloadDataCount += 1
            tableView.syncPrimaryColumnWidth()
            tableView.reloadData()
            tableView.tile()

            if viewportChanged {
                scrollToOffsetY(0)
            } else {
                let maxOriginY = maxScrollOriginY()
                let clampedY = min(max(0, savedOriginY), maxOriginY)
                scrollToOffsetY(clampedY)
            }

            if !isLiveScrolling {
                updateHoverForCurrentPointerLocation()
            }
        } else if lastSelectionRevision != selectionRevision {
            lastSelectionRevision = selectionRevision
            refreshVisibleSelectionStates()
        }

        if let colorScheme, lastColorScheme != colorScheme {
            lastColorScheme = colorScheme
            syncAppearanceToVisibleCellsAndPopover()
        }
    }

    /// 仅局部刷新可视区内选中态发生变化的可见 Cell 与分组头，绝不触碰滚动位置或整表 reloadData
    func refreshVisibleSelectionStates() {
        guard let tableView, let viewModel else { return }
        selectionOnlyRefreshCount += 1

        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }

        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        guard lower < upper else { return }

        for rowIndex in lower..<upper {
            switch rows[rowIndex] {
            case let .item(itemRow):
                if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ItemRowTableCellView {
                    cell.setSelected(viewModel.isSelected(itemID: itemRow.id))
                }
            case let .sectionHeader(header):
                if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? SectionHeaderTableCellView {
                    let isAllSelected = header.supportsBulkSelection
                        && viewModel.isSectionAllBulkSelected(header.recommendation)
                    cell.setAllBulkSelected(isAllSelected)
                }
            case let .projectHeader(header):
                if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ProjectHeaderTableCellView {
                    let isAllSelected = header.supportsBulkSelection
                        && viewModel.isProjectGroupAllBulkSelected(header.project)
                    cell.setAllBulkSelected(isAllSelected)
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else {
            return VirtualizedItemTableMetrics.itemRowHeight
        }
        switch rows[row] {
        case let .sectionHeader(header):
            return header.isFirstSection
                ? VirtualizedItemTableMetrics.firstSectionHeaderHeight
                : VirtualizedItemTableMetrics.subsequentSectionHeaderHeight
        case let .projectHeader(header):
            return header.isFirstSection
                ? VirtualizedItemTableMetrics.firstSectionHeaderHeight
                : VirtualizedItemTableMetrics.subsequentSectionHeaderHeight
        case .item:
            return VirtualizedItemTableMetrics.itemRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(
            withIdentifier: PlainTableRowView.reuseIdentifier,
            owner: nil
        ) as? PlainTableRowView {
            return reused
        }
        let rowView = PlainTableRowView()
        rowView.identifier = PlainTableRowView.reuseIdentifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count, let viewModel else { return nil }

        switch rows[row] {
        case let .sectionHeader(header):
            let cell: SectionHeaderTableCellView
            if let reused = tableView.makeView(
                withIdentifier: SectionHeaderTableCellView.reuseIdentifier,
                owner: nil
            ) as? SectionHeaderTableCellView {
                cell = reused
                reusedSectionHeaderCellCount += 1
            } else {
                cell = SectionHeaderTableCellView()
                cell.identifier = SectionHeaderTableCellView.reuseIdentifier
                createdSectionHeaderCellCount += 1
            }
            let isAllBulkSelected = header.supportsBulkSelection
                && viewModel.isSectionAllBulkSelected(header.recommendation)
            cell.configure(
                header: header,
                isAllBulkSelected: isAllBulkSelected,
                onToggleCollapse: { [weak self] recommendation in
                    self?.handleToggleSectionCollapsed(recommendation)
                },
                onToggleBulkSelection: { [weak self] recommendation in
                    self?.handleToggleSectionSelection(recommendation)
                }
            )
            return cell

        case let .projectHeader(header):
            let cell: ProjectHeaderTableCellView
            if let reused = tableView.makeView(
                withIdentifier: ProjectHeaderTableCellView.reuseIdentifier,
                owner: nil
            ) as? ProjectHeaderTableCellView {
                cell = reused
            } else {
                cell = ProjectHeaderTableCellView()
                cell.identifier = ProjectHeaderTableCellView.reuseIdentifier
            }
            cell.configure(
                header: header,
                isAllBulkSelected: header.supportsBulkSelection
                    && viewModel.isProjectGroupAllBulkSelected(header.project),
                onToggleBulkSelection: { [weak self] project in
                    self?.handleToggleProjectGroupSelection(project)
                }
            )
            return cell

        case let .item(itemRow):
            let cell: ItemRowTableCellView
            if let reused = tableView.makeView(
                withIdentifier: ItemRowTableCellView.reuseIdentifier,
                owner: nil
            ) as? ItemRowTableCellView {
                cell = reused
                reusedItemCellCount += 1
            } else {
                cell = ItemRowTableCellView()
                cell.identifier = ItemRowTableCellView.reuseIdentifier
                createdItemCellCount += 1
                allocatedItemCells.add(cell)
            }
            let isSelected = viewModel.isSelected(itemID: itemRow.id)
            let isHovered = !isLiveScrolling && (row == hoveredRow)
            cell.configure(
                row: itemRow,
                isSelected: isSelected,
                isHovered: isHovered,
                onToggleSelection: { [weak self] item in
                    self?.handleToggleSelection(item)
                },
                onRevealInFinder: { [weak self] item in
                    self?.handleRevealInFinder(item)
                },
                onShowFullTitle: { [weak self] displayRow, anchorView in
                    self?.toggleFullTitlePopover(for: displayRow, anchorView: anchorView)
                }
            )
            return cell
        }
    }

    // MARK: - Single-Instance Hover Tracking & Live Scroll Pause

    func handleWillStartLiveScroll() {
        isLiveScrolling = true
        tableView?.isLiveScrolling = true
        setHoveredRow(-1)
        closeFullTitlePopover(animated: true)
    }

    func handleDidEndLiveScroll() {
        isLiveScrolling = false
        tableView?.isLiveScrolling = false
        updateHoverForCurrentPointerLocation()
    }

    private func handleClipViewBoundsChanged() {
        if fullTitlePopover.isShown || activePopoverItemID != nil {
            closeFullTitlePopover(animated: false)
        }
        if !isLiveScrolling && hoveredRow >= 0 {
            setHoveredRow(-1)
        }
    }

    func handleHoverPoint(_ pointInTable: NSPoint?) {
        guard !isLiveScrolling else { return }
        guard let pointInTable, let tableView else {
            setHoveredRow(-1)
            return
        }
        let margin = VirtualizedItemTableMetrics.horizontalMargin
        guard pointInTable.x >= margin,
              pointInTable.x <= tableView.bounds.width - margin,
              tableView.visibleRect.contains(pointInTable) else {
            setHoveredRow(-1)
            return
        }
        let row = tableView.row(at: pointInTable)
        guard itemRow(at: row) != nil else {
            setHoveredRow(-1)
            return
        }
        setHoveredRow(row)
    }

    func setHoveredRow(_ newRow: Int) {
        let sanitized = (newRow >= 0 && itemRow(at: newRow) != nil) ? newRow : -1
        guard sanitized != hoveredRow else { return }

        let oldRow = hoveredRow
        hoveredRow = sanitized
        hoverRefreshCount += 1

        guard let tableView else { return }
        if oldRow >= 0,
           let oldCell = tableView.view(atColumn: 0, row: oldRow, makeIfNecessary: false) as? ItemRowTableCellView {
            oldCell.setHovered(false)
        }
        if sanitized >= 0,
           let newCell = tableView.view(atColumn: 0, row: sanitized, makeIfNecessary: false) as? ItemRowTableCellView {
            newCell.setHovered(true)
        }
    }

    private func updateHoverForCurrentPointerLocation() {
        guard !isLiveScrolling, let tableView, let window = tableView.window else {
            setHoveredRow(-1)
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInTable = tableView.convert(pointInWindow, from: nil)
        handleHoverPoint(pointInTable)
    }

    // MARK: - Single-Instance Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sharedContextMenu, let tableView else { return }
        let targetRow = tableView.clickedRow >= 0 ? tableView.clickedRow : pendingContextMenuRow
        populateContextMenu(menu, forRow: targetRow)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === sharedContextMenu else { return }
        pendingContextMenuRow = -1
    }

    /// 供 AppKit `menuNeedsUpdate` 与自动化测试共同调用的单实例右键菜单填充逻辑
    func populateContextMenu(_ menu: NSMenu, forRow row: Int) {
        menu.removeAllItems()
        guard let itemRow = itemRow(at: row), let viewModel else { return }
        let item = itemRow.item

        if item.hardProtectionReason == nil {
            let isSelected = viewModel.isSelected(itemID: item.id)
            let toggleTitle: String
            let toggleSymbol: String
            if item.isCleanable {
                toggleTitle = isSelected ? "取消勾选" : "勾选此项"
                toggleSymbol = isSelected ? "checkmark.square" : "square"
            } else {
                toggleTitle = isSelected ? "取消勾选" : "勾选并确认风险…"
                toggleSymbol = isSelected ? "checkmark.square" : "exclamationmark.shield"
            }
            let toggleMenuItem = NSMenuItem(
                title: toggleTitle,
                action: #selector(handleContextMenuToggleSelection(_:)),
                keyEquivalent: ""
            )
            toggleMenuItem.target = self
            toggleMenuItem.image = ItemTableResources.symbolImage(named: toggleSymbol, pointSize: 13, weight: .regular)
            toggleMenuItem.representedObject = item
            menu.addItem(toggleMenuItem)
            menu.addItem(.separator())
        }

        let excludeItem = NSMenuItem(
            title: "排除此条目（不再显示）",
            action: #selector(handleContextMenuExclude(_:)),
            keyEquivalent: ""
        )
        excludeItem.target = self
        excludeItem.image = ItemTableResources.symbolImage(named: "eye.slash", pointSize: 13, weight: .regular)
        excludeItem.representedObject = item
        menu.addItem(excludeItem)

        menu.addItem(.separator())

        let revealItem = NSMenuItem(
            title: "在 Finder 中显示",
            action: #selector(handleContextMenuRevealInFinder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.image = ItemTableResources.symbolImage(named: "folder", pointSize: 13, weight: .regular)
        revealItem.representedObject = item
        menu.addItem(revealItem)

        let copyItem = NSMenuItem(
            title: "复制完整路径",
            action: #selector(handleContextMenuCopyPath(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.image = ItemTableResources.symbolImage(named: "doc.on.doc", pointSize: 13, weight: .regular)
        copyItem.representedObject = item
        menu.addItem(copyItem)
    }

    @objc private func handleContextMenuToggleSelection(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? CleanableItem else { return }
        handleToggleSelection(item)
    }

    @objc private func handleContextMenuExclude(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? CleanableItem else { return }
        closeFullTitlePopover(animated: false)
        viewModel?.excludeItem(item)
    }

    @objc private func handleContextMenuRevealInFinder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? CleanableItem else { return }
        handleRevealInFinder(item)
    }

    @objc private func handleContextMenuCopyPath(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? CleanableItem else { return }
        viewModel?.copyPath(item)
    }

    // MARK: - Single-Instance Full Session Title Popover

    func toggleFullTitlePopover(for displayRow: ItemDisplayRow, anchorView: NSView) {
        let itemID = displayRow.id

        // 若刚刚因 transient 行为在同一按钮 mouseDown 时关闭了同一条目的弹窗，则不再立刻重开
        if lastClosedPopoverItemID == itemID && (CACurrentMediaTime() - lastPopoverCloseTime) < 0.25 {
            lastClosedPopoverItemID = nil
            return
        }

        if fullTitlePopover.isShown && activePopoverItemID == itemID {
            closeFullTitlePopover(animated: true)
            return
        }

        if fullTitlePopover.isShown {
            fullTitlePopover.close()
        }

        fullTitlePopoverController.setTitleText(displayRow.title)
        syncPopoverAppearance()
        activePopoverItemID = itemID

        guard anchorView.window != nil else { return }
        fullTitlePopover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    func closeFullTitlePopover(animated: Bool) {
        guard fullTitlePopover.isShown else {
            activePopoverItemID = nil
            return
        }
        if animated {
            fullTitlePopover.performClose(nil)
        } else {
            fullTitlePopover.close()
        }
        activePopoverItemID = nil
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedPopoverItemID = activePopoverItemID
        lastPopoverCloseTime = CACurrentMediaTime()
        activePopoverItemID = nil
    }

    // MARK: - Row & Section Actions

    private func handleToggleSelection(_ item: CleanableItem) {
        closeFullTitlePopover(animated: true)
        guard let viewModel else { return }
        viewModel.toggleSelection(for: item)
        if lastSelectionRevision != viewModel.selectionRevision {
            lastSelectionRevision = viewModel.selectionRevision
            refreshVisibleSelectionStates()
        }
    }

    private func handleToggleSectionSelection(_ recommendation: CleanupRecommendation) {
        closeFullTitlePopover(animated: true)
        guard let viewModel else { return }
        viewModel.toggleSectionSelection(recommendation)
        if lastSelectionRevision != viewModel.selectionRevision {
            lastSelectionRevision = viewModel.selectionRevision
            refreshVisibleSelectionStates()
        }
    }

    private func handleToggleProjectGroupSelection(_ project: SessionProjectID) {
        closeFullTitlePopover(animated: true)
        guard let viewModel else { return }
        viewModel.toggleProjectGroupSelection(project)
        if lastSelectionRevision != viewModel.selectionRevision {
            lastSelectionRevision = viewModel.selectionRevision
            refreshVisibleSelectionStates()
        }
    }

    private func handleToggleSectionCollapsed(_ recommendation: CleanupRecommendation) {
        closeFullTitlePopover(animated: true)
        viewModel?.toggleSectionCollapsed(recommendation)
    }

    private func handleRevealInFinder(_ item: CleanableItem) {
        viewModel?.revealInFinder(item)
    }

    // MARK: - Helpers

    private func itemRow(at row: Int) -> ItemDisplayRow? {
        guard row >= 0, row < rows.count else { return nil }
        if case let .item(displayRow) = rows[row] {
            return displayRow
        }
        return nil
    }

    func maxScrollOriginY() -> CGFloat {
        guard let tableView, let scrollView else { return 0 }
        let docHeight = tableView.bounds.height
        let clipHeight = scrollView.contentView.bounds.height
        return max(0, docHeight + scrollView.contentInsets.bottom - clipHeight)
    }

    func scrollToOffsetY(_ offsetY: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let targetY = max(0, offsetY)
        if abs(clipView.bounds.origin.y - targetY) > 0.25 {
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func syncPopoverAppearance() {
        let appearance = tableView?.window?.effectiveAppearance ?? tableView?.effectiveAppearance
        fullTitlePopover.appearance = appearance
    }

    private func syncAppearanceToVisibleCellsAndPopover() {
        syncPopoverAppearance()
        guard let tableView else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        guard lower < upper else { return }

        for rowIndex in lower..<upper {
            let view = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
            if let itemCell = view as? ItemRowTableCellView {
                itemCell.refreshAppearance()
            } else if let headerCell = view as? SectionHeaderTableCellView {
                headerCell.refreshAppearance()
            } else if let projectCell = view as? ProjectHeaderTableCellView {
                projectCell.refreshAppearance()
            }
        }
    }
}

// MARK: - Standalone ScrollView + TableView Controller (Shared by SwiftUI Bridge & XCTest)

@MainActor
final class VirtualizedItemTableController {
    let scrollView: NSScrollView
    let tableView: ItemTableView
    let coordinator: VirtualizedItemTableCoordinator

    init() {
        let scrollView = NSScrollView()
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            scrollView.setContentHuggingPriority(.defaultLow, for: axis)
            scrollView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: VirtualizedItemTableMetrics.bottomScrollInset,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.contentView.drawsBackground = false

        let tableView = ItemTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.floatsGroupRows = false
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = VirtualizedItemTableMetrics.itemRowHeight
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.title = ""
        column.minWidth = 200
        column.maxWidth = 10_000
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        let coordinator = VirtualizedItemTableCoordinator()
        coordinator.attach(scrollView: scrollView, tableView: tableView)

        self.scrollView = scrollView
        self.tableView = tableView
        self.coordinator = coordinator
    }

    func apply(viewModel: CleanerViewModel, colorScheme: ColorScheme? = nil) {
        coordinator.applyState(
            rows: viewModel.displayedRows,
            rowsRevision: viewModel.displayedRowsRevision,
            selectionRevision: viewModel.selectionRevision,
            viewportID: viewModel.listViewportID,
            colorScheme: colorScheme,
            viewModel: viewModel
        )
    }

    func teardown() {
        coordinator.teardown()
    }
}

// MARK: - SwiftUI NSViewRepresentable Bridge

struct VirtualizedItemTableView: NSViewRepresentable {
    let rows: [FlatListRow]
    let rowsRevision: Int
    let selectionRevision: Int
    let viewportID: Int
    let colorScheme: ColorScheme
    let viewModel: CleanerViewModel

    func makeCoordinator() -> VirtualizedItemTableController {
        VirtualizedItemTableController()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // SwiftUI sizes the viewport. Only AppKit needs the full document height for scrolling.
        CGSize(
            width: viewportDimension(proposal.width, fallback: 320),
            height: viewportDimension(proposal.height, fallback: 240)
        )
    }

    private func viewportDimension(_ proposed: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let proposed, proposed.isFinite else { return fallback }
        return proposed
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        controller.coordinator.applyState(
            rows: rows,
            rowsRevision: rowsRevision,
            selectionRevision: selectionRevision,
            viewportID: viewportID,
            colorScheme: colorScheme,
            viewModel: viewModel
        )
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.coordinator.applyState(
            rows: rows,
            rowsRevision: rowsRevision,
            selectionRevision: selectionRevision,
            viewportID: viewportID,
            colorScheme: colorScheme,
            viewModel: viewModel
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: VirtualizedItemTableController) {
        coordinator.teardown()
    }
}
