import AICleanerCore
import AppKit
import SwiftUI

// MARK: - 1. 零主线程开销的柔和极光氛围背景（纯 GPU 径向渐变，取消高频离屏 blur 避免切换掉帧）

struct AmbientAuroraBackdrop: View {
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let primaryAlpha = isDark ? 0.14 : 0.08
        let secondaryAlpha = isDark ? 0.095 : 0.06

        ZStack {
            AppTheme.canvasBackground(for: colorScheme)

            RadialGradient(
                colors: [accentColor.opacity(primaryAlpha), .clear],
                center: UnitPoint(x: 0.22, y: 0.04),
                startRadius: 20,
                endRadius: 520
            )

            RadialGradient(
                colors: [Color(red: 0.14, green: 0.82, blue: 0.64).opacity(secondaryAlpha), .clear],
                center: UnitPoint(x: 0.82, y: 0.08),
                startRadius: 20,
                endRadius: 460
            )
        }
        .drawingGroup(opaque: true)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 2A. 初始待扫描欢迎核心视图（中心 Logo 直接触发扫描，与扫描中雷达零抖动衔接）

struct ScanReadyHeroMotion: Equatable, Sendable {
    let glowScale: CGFloat
    let glowOpacityMultiplier: Double
    let coreBreathScale: CGFloat
    let outerRingDegrees: Double
    let primaryRippleScale: CGFloat
    let primaryRippleOpacity: Double
    let secondaryRippleScale: CGFloat
    let secondaryRippleOpacity: Double

    static let staticRest = ScanReadyHeroMotion(
        glowScale: 1.0,
        glowOpacityMultiplier: 1.0,
        coreBreathScale: 1.0,
        outerRingDegrees: 0,
        primaryRippleScale: 1.0,
        primaryRippleOpacity: 0,
        secondaryRippleScale: 1.0,
        secondaryRippleOpacity: 0
    )

    static func evaluate(elapsed: TimeInterval, isAnimating: Bool) -> ScanReadyHeroMotion {
        guard isAnimating else { return .staticRest }

        let breathWave = sin(elapsed * 1.65)
        let glowScale = 1.0 + 0.045 * CGFloat(breathWave)
        let glowOpacityMultiplier = 0.90 + 0.10 * (0.5 + 0.5 * breathWave)
        let coreBreathScale = 1.0 + 0.018 * CGFloat(breathWave)
        let rawDegrees = (elapsed * 9.0).truncatingRemainder(dividingBy: 360.0)
        let outerRingDegrees = rawDegrees < 0 ? rawDegrees + 360.0 : rawDegrees

        // 柔和双相脉冲波纹（3.6s 慢节奏循环，末段留白呼吸，不喧宾夺主）
        let cycleDuration = 3.6
        let primaryPhase = (elapsed / cycleDuration).truncatingRemainder(dividingBy: 1.0)
        let secondaryPhase = ((elapsed / cycleDuration) + 0.5).truncatingRemainder(dividingBy: 1.0)

        let primary = rippleValues(phase: primaryPhase)
        let secondary = rippleValues(phase: secondaryPhase)

        return ScanReadyHeroMotion(
            glowScale: glowScale,
            glowOpacityMultiplier: glowOpacityMultiplier,
            coreBreathScale: coreBreathScale,
            outerRingDegrees: outerRingDegrees,
            primaryRippleScale: primary.scale,
            primaryRippleOpacity: primary.opacity,
            secondaryRippleScale: secondary.scale,
            secondaryRippleOpacity: secondary.opacity
        )
    }

    private static func rippleValues(phase rawPhase: Double) -> (scale: CGFloat, opacity: Double) {
        let phase = rawPhase < 0 ? rawPhase + 1.0 : rawPhase
        let activeFraction = 0.82
        guard phase < activeFraction else {
            return (1.0, 0.0)
        }
        let t = phase / activeFraction
        let eased = 1.0 - pow(1.0 - t, 2.2)
        let scale = 1.0 + CGFloat(eased) * 0.98
        let fadeIn = min(1.0, t / 0.14)
        let fadeOut = pow(1.0 - t, 1.85)
        return (scale, fadeIn * fadeOut)
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isActive: Bool
    @State private var isPushed: Bool = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateCursor(active: isActive)
            }
            .onChange(of: isActive) { _, newValue in
                updateCursor(active: newValue)
            }
            .onDisappear {
                updateCursor(active: false)
            }
    }

    private func updateCursor(active: Bool) {
        if active && !isPushed {
            NSCursor.pointingHand.push()
            isPushed = true
        } else if !active && isPushed {
            NSCursor.pop()
            isPushed = false
        }
    }
}

private extension View {
    func pointingHandCursor(_ isActive: Bool) -> some View {
        modifier(PointingHandCursorModifier(isActive: isActive))
    }
}

private struct ScanHeroOrbButtonStyle: ButtonStyle {
    let isHovered: Bool
    let motion: ScanReadyHeroMotion
    let sheenProgress: CGFloat
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let isDark = colorScheme == .dark

        let coreScale: CGFloat = {
            if reduceMotion { return 1.0 }
            if pressed { return 0.91 }
            if isHovered { return 1.065 }
            return motion.coreBreathScale
        }()

        let collarScale: CGFloat = {
            if reduceMotion { return 1.0 }
            if pressed { return 0.955 }
            if isHovered { return 1.035 }
            return 1.0
        }()

        let iconScale: CGFloat = {
            if reduceMotion { return 1.0 }
            if pressed { return 0.95 }
            if isHovered { return 1.06 }
            return 1.0
        }()

        let orbShadowColor = Color(red: 0.14, green: 0.78, blue: 0.64)
            .opacity(
                pressed
                    ? (isDark ? 0.30 : 0.24)
                    : (isHovered ? (isDark ? 0.64 : 0.52) : (isDark ? 0.46 : 0.38))
            )
        let orbShadowRadius: CGFloat = pressed ? 8 : (isHovered ? 22 : 16)
        let orbShadowY: CGFloat = pressed ? 2 : (isHovered ? 8 : 5)

        ZStack {
            // 可点击边界光环（116pt，与圆形点击热区严格对齐）
            Circle()
                .fill(
                    Color(red: 0.14, green: 0.80, blue: 0.64)
                        .opacity(
                            pressed
                                ? (isDark ? 0.15 : 0.10)
                                : (isHovered ? (isDark ? 0.11 : 0.075) : 0.0)
                        )
                )
                .frame(width: 116, height: 116)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isHovered || pressed
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.14, green: 0.86, blue: 0.64)
                                                .opacity(isDark ? 0.80 : 0.68),
                                            Color(red: 0.24, green: 0.62, blue: 1.00)
                                                .opacity(isDark ? 0.58 : 0.48)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.14, green: 0.82, blue: 0.64)
                                                .opacity(isDark ? 0.26 : 0.20),
                                            Color.primary.opacity(isDark ? 0.11 : 0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                ),
                            lineWidth: isHovered || pressed ? 1.5 : 1.0
                        )
                }
                .scaleEffect(collarScale)

            // 中心品牌渐变圆球（主触发入口）
            ZStack {
                Circle()
                    .fill(AppTheme.brandGradient)

                // 左上镜面柔光，强化实体按钮质感
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(pressed ? 0.14 : (isHovered ? 0.36 : 0.22)),
                                Color.white.opacity(0.04),
                                .clear
                            ],
                            center: UnitPoint(x: 0.30, y: 0.22),
                            startRadius: 2,
                            endRadius: 46
                        )
                    )

                // 悬停斜扫高光（减弱动态效果下自动关闭）
                if isHovered && !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.36),
                            Color.white.opacity(0.10),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 34, height: 110)
                    .rotationEffect(.degrees(22))
                    .offset(x: sheenProgress * 92)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
                }

                // 按压瞬态压暗反馈（确保减弱动态效果下同样清晰）
                if pressed {
                    Circle()
                        .fill(Color.black.opacity(reduceMotion ? 0.14 : 0.07))
                }

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.82 : 0.60),
                                Color.white.opacity(isHovered ? 0.24 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovered ? 1.25 : 1.05
                    )

                configuration.label
                    .scaleEffect(iconScale)
            }
            .frame(width: 76, height: 76)
            .shadow(color: orbShadowColor, radius: orbShadowRadius, y: orbShadowY)
            .shadow(
                color: Color.black.opacity(pressed ? 0.08 : (isDark ? 0.28 : 0.10)),
                radius: pressed ? 2 : 4,
                y: pressed ? 1 : 2
            )
            .scaleEffect(coreScale)
        }
        .frame(width: 118, height: 118)
        .contentShape(Circle())
        .animation(
            reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.72),
            value: pressed
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.74),
            value: isHovered
        )
        .onChange(of: pressed) { _, newValue in
            isPressed = newValue
        }
        .onDisappear {
            isPressed = false
        }
    }
}

struct ScanReadyHeroView: View {
    let historicalFreedBytes: Int64
    var isVisible: Bool = true
    let onStartScan: () -> Void
    let onOpenHistory: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen

    @State private var isOrbHovered: Bool = false
    @State private var isOrbPressed: Bool = false
    @State private var isHistoryHovered: Bool = false
    @State private var sheenProgress: CGFloat = -1.25
    @State private var motionClock = PausableAnimationClock()

    private var playbackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            reduceMotion: reduceMotion
        )
    }

    nonisolated static func allowsPointerCursor(
        isPageVisible: Bool,
        isWindowVisibleOnScreen: Bool,
        isWindowActive: Bool
    ) -> Bool {
        isPageVisible && isWindowVisibleOnScreen && isWindowActive
    }

    private var allowsPointerCursor: Bool {
        Self.allowsPointerCursor(
            isPageVisible: isVisible,
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isWindowActive: controlActiveState != .inactive
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: playbackPolicy.isPaused)) { timeline in
                let elapsed = reduceMotion ? 0.0 : motionClock.elapsed(at: timeline.date)
                let motion = ScanReadyHeroMotion.evaluate(elapsed: elapsed, isAnimating: !reduceMotion)
                let isDark = colorScheme == .dark
                let rippleFactor = isOrbHovered ? 0.55 : 1.0
                let rippleBaseAlpha = (isDark ? 0.44 : 0.34) * rippleFactor

                ZStack {
                    // 1. 柔和呼吸环境光晕
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62)
                                        .opacity((isDark ? (isOrbHovered ? 0.34 : 0.25) : (isOrbHovered ? 0.24 : 0.17)) * motion.glowOpacityMultiplier),
                                    Color(red: 0.24, green: 0.58, blue: 1.00)
                                        .opacity((isDark ? (isOrbHovered ? 0.15 : 0.10) : (isOrbHovered ? 0.11 : 0.07)) * motion.glowOpacityMultiplier),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 18,
                                endRadius: 102
                            )
                        )
                        .frame(width: 204, height: 204)
                        .scaleEffect(
                            reduceMotion
                                ? 1.0
                                : motion.glowScale * (isOrbPressed ? 0.95 : (isOrbHovered ? 1.06 : 1.0))
                        )
                        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.78), value: isOrbHovered)
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.76), value: isOrbPressed)
                        .allowsHitTesting(false)

                    // 2. 克制的脉冲波纹提示（减弱动态效果时关闭；窗口不可见或切页时由 TimelineView 暂停定格）
                    if !reduceMotion {
                        pulseRippleCircle(
                            scale: motion.primaryRippleScale,
                            opacity: motion.primaryRippleOpacity * rippleBaseAlpha
                        )
                        pulseRippleCircle(
                            scale: motion.secondaryRippleScale,
                            opacity: motion.secondaryRippleOpacity * rippleBaseAlpha * 0.82
                        )
                    }

                    // 3. 外圈慢速旋转虚线轨道
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62)
                                        .opacity(isOrbHovered ? (isDark ? 0.78 : 0.66) : (isDark ? 0.50 : 0.46)),
                                    Color(red: 0.24, green: 0.60, blue: 1.00)
                                        .opacity(isOrbHovered ? (isDark ? 0.54 : 0.46) : (isDark ? 0.34 : 0.30)),
                                    Color.primary.opacity(isOrbHovered ? 0.12 : 0.06),
                                    Color(red: 0.14, green: 0.84, blue: 0.62)
                                        .opacity(isOrbHovered ? (isDark ? 0.78 : 0.66) : (isDark ? 0.50 : 0.46))
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(
                                lineWidth: isOrbHovered ? 1.55 : 1.3,
                                lineCap: .round,
                                dash: [7, 8]
                            )
                        )
                        .frame(width: 164, height: 164)
                        .rotationEffect(.degrees(motion.outerRingDegrees))
                        .scaleEffect(
                            reduceMotion
                                ? 1.0
                                : (isOrbPressed ? 0.975 : (isOrbHovered ? 1.028 : 1.0))
                        )
                        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.78), value: isOrbHovered)
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.76), value: isOrbPressed)
                        .allowsHitTesting(false)

                    // 4. 居中可点击 Logo 入口（严格圆形 118pt 交互热区）
                    Button {
                        isOrbHovered = false
                        isOrbPressed = false
                        onStartScan()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: Color.black.opacity(0.14), radius: 2, y: 1)
                    }
                    .buttonStyle(
                        ScanHeroOrbButtonStyle(
                            isHovered: isOrbHovered,
                            motion: motion,
                            sheenProgress: sheenProgress,
                            colorScheme: colorScheme,
                            reduceMotion: reduceMotion,
                            isPressed: $isOrbPressed
                        )
                    )
                    .onHover { hovering in
                        isOrbHovered = hovering
                        guard !reduceMotion else { return }
                        if hovering {
                            sheenProgress = -1.25
                            withAnimation(.easeInOut(duration: 0.54)) {
                                sheenProgress = 1.35
                            }
                        } else {
                            sheenProgress = -1.25
                        }
                    }
                    .pointingHandCursor(isOrbHovered && allowsPointerCursor)
                    .accessibilityLabel("开始扫描")
                    .accessibilityHint("扫描本地 AI 客户端的会话、缓存与日志")
                    .help("开始扫描 (⌘R)")
                }
                .frame(width: 220, height: 220)
            }

            VStack(spacing: 6) {
                Text("扫描 AI 客户端")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text("点击图标开始扫描")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(isOrbHovered ? Color.primary.opacity(0.86) : Color.secondary.opacity(0.80))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOrbHovered)
            }
            .frame(height: 52, alignment: .top)

            HStack {
                if historicalFreedBytes > 0 {
                    Button {
                        isHistoryHovered = false
                        onOpenHistory()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.color(for: .recommended))
                            Text("\(CleanupHistoryCopy.cumulativeCleanedTitle) \(CleanerFormatting.formatBytes(historicalFreedBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isHistoryHovered ? .primary : .secondary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isHistoryHovered
                                        ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055)
                                        : Color.clear
                                )
                        )
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHistoryHovered = hovering
                    }
                    .pointingHandCursor(isHistoryHovered && allowsPointerCursor)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHistoryHovered)
                    .help(CleanupHistoryCopy.openActionTitle)
                }
            }
            .padding(.top, 6)
            .frame(height: 36)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            motionClock.setPaused(playbackPolicy.isPaused)
        }
        .onChange(of: playbackPolicy.isPaused) { _, isPaused in
            motionClock.setPaused(isPaused)
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                isOrbHovered = false
                isOrbPressed = false
                isHistoryHovered = false
            }
        }
    }

    private func pulseRippleCircle(scale: CGFloat, opacity: Double) -> some View {
        let diameter = 76 * scale
        let progress = max(0, min(1, (scale - 1.0) / 0.98))
        let lineWidth = 1.35 - 0.55 * progress

        return Circle()
            .stroke(
                LinearGradient(
                    colors: [
                        Color(red: 0.14, green: 0.84, blue: 0.62),
                        Color(red: 0.24, green: 0.64, blue: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: lineWidth
            )
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

// MARK: - 2B. 轨道雷达扫描核心动效（全盘只读扫描中 Hero，与待扫描首页同尺寸对齐）

struct OrbitalScannerHero: View {
    var isVisible: Bool = true
    /// 扫描进度状态源（步骤条 / 客户端发现卡片 / 实时统计）；为 nil 时保持旧的纯动画布局
    var progress: ScanProgressModel? = nil
    var onCancel: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var hasAppeared: Bool = false
    @State private var motionClock = PausableAnimationClock()

    private var playbackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                TimelineView(.animation(paused: playbackPolicy.isPaused)) { timeline in
                    let elapsed = reduceMotion ? 0.0 : motionClock.elapsed(at: timeline.date)
                    let sweepAngle = Angle.degrees((elapsed * 120).truncatingRemainder(dividingBy: 360))
                    let outerRotation = Angle.degrees((elapsed * 24).truncatingRemainder(dividingBy: 360))
                    let innerRotation = Angle.degrees((-elapsed * 40).truncatingRemainder(dividingBy: 360))
                    let pulse = reduceMotion ? 1.0 : (0.95 + 0.06 * sin(elapsed * 2.8))

                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(red: 0.14, green: 0.84, blue: 0.62).opacity(colorScheme == .dark ? 0.26 : 0.20),
                                        Color(red: 0.24, green: 0.56, blue: 1.00).opacity(colorScheme == .dark ? 0.10 : 0.07),
                                        .clear
                                    ],
                                    center: .center,
                                    startRadius: 16,
                                    endRadius: 102
                                )
                            )
                            .frame(width: 204, height: 204)
                            .scaleEffect(pulse)

                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.65),
                                        Color(red: 0.24, green: 0.58, blue: 1.00).opacity(0.34),
                                        Color.primary.opacity(0.06),
                                        Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.65)
                                    ],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 1.45, lineCap: .round, dash: [7, 8])
                            )
                            .frame(width: 164, height: 164)
                            .rotationEffect(outerRotation)

                        Circle()
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.08), lineWidth: 1)
                            .frame(width: 116, height: 116)

                        if !reduceMotion {
                            Circle()
                                .fill(
                                    AngularGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: .clear, location: 0.74),
                                            .init(color: Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.16), location: 0.90),
                                            .init(color: Color(red: 0.22, green: 0.92, blue: 0.72).opacity(0.46), location: 1.0)
                                        ]),
                                        center: .center
                                    )
                                )
                                .frame(width: 162, height: 162)
                                .rotationEffect(sweepAngle)
                        }

                        Circle()
                            .stroke(
                                Color(red: 0.36, green: 0.64, blue: 1.00).opacity(0.44),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 10])
                            )
                            .frame(width: 84, height: 84)
                            .rotationEffect(innerRotation)

                        ZStack {
                            Circle()
                                .fill(AppTheme.brandGradient)
                                .frame(width: 58, height: 58)
                                .shadow(color: Color(red: 0.14, green: 0.80, blue: 0.64).opacity(0.48), radius: 14)

                            Image(systemName: "sparkles")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .scaleEffect(pulse)
                    }
                    .scaleEffect(hasAppeared || reduceMotion ? 1.0 : 0.95)
                    .frame(width: 220, height: 220)
                }

                VStack(spacing: 6) {
                    Text("正在扫描 AI 客户端…")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                }
                .frame(height: 52, alignment: .top)

                // 进度反馈区：步骤条 + 客户端发现单行跑马灯 + 实时统计（全部由引擎进度事件驱动）
                if let progress {
                    VStack(spacing: 14) {
                        ScanStageProgressBar(progress: progress)
                        ScanDiscoveryTickerRow(progress: progress)
                        ScanLiveStatsRow(progress: progress)
                    }
                    .padding(.top, 2)
                }

                HStack {
                    if let onCancel {
                        Button("取消扫描", action: onCancel)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
                .padding(.top, 6)
                .frame(height: 36)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            motionClock.setPaused(playbackPolicy.isPaused)
            guard !reduceMotion else {
                hasAppeared = true
                return
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                hasAppeared = true
            }
        }
        .onChange(of: playbackPolicy.isPaused) { _, isPaused in
            motionClock.setPaused(isPaused)
        }
    }
}

// MARK: - 3. 极简精致多段环形空间仪表盘（StorageRingGauge）

struct StorageRingGauge: View {
    let recommendedBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64
    let highlightedTier: CleanupRecommendation?
    var isScanning: Bool = false
    var isVisible: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var appeared: Bool = false
    @State private var motionClock = PausableAnimationClock()

    private var scanRingPlaybackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            isFeatureActive: isScanning,
            reduceMotion: reduceMotion
        )
    }

    private struct RingMetrics: Equatable {
        let recommended: Int64
        let review: Int64
        let protected: Int64
    }

    private var metrics: RingMetrics {
        RingMetrics(recommended: recommendedBytes, review: reviewBytes, protected: protectedBytes)
    }

    private var totalBytes: Int64 {
        recommendedBytes + reviewBytes + protectedBytes
    }

    private var cleanableBytes: Int64 {
        recommendedBytes + reviewBytes
    }

    var body: some View {
        let centerValue = centerBytes
        let centerText = CleanerFormatting.formatBytes(centerValue)
        let total = max(1.0, Double(totalBytes))
        let recFrac = appeared ? Double(recommendedBytes) / total : 0
        let revFrac = appeared ? Double(reviewBytes) / total : 0
        let proFrac = appeared ? Double(protectedBytes) / total : 0

        let gap: Double = totalBytes > 0 ? 0.016 : 0
        let recEnd = max(0, recFrac - (recFrac > gap * 2 ? gap : 0))
        let revStart = recFrac
        let revEnd = max(revStart, recFrac + revFrac - (revFrac > gap * 2 ? gap : 0))
        let proStart = recFrac + revFrac
        let proEnd = max(proStart, min(1.0, proStart + proFrac - (proFrac > gap * 2 ? gap : 0)))

        ZStack {
            // 柔和环境光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            centerColor.opacity(colorScheme == .dark ? 0.18 : 0.11),
                            centerColor.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 52
                    )
                )
                .frame(width: 102, height: 102)

            // 轨道底环
            Circle()
                .stroke(
                    Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07),
                    lineWidth: 8.5
                )
                .frame(width: 90, height: 90)

            if totalBytes > 0 {
                if recommendedBytes > 0 {
                    Circle()
                        .trim(from: 0, to: recEnd)
                        .stroke(
                            AppTheme.gradient(for: .recommended),
                            style: StrokeStyle(lineWidth: ringWidth(for: .recommended), lineCap: .round)
                        )
                        .frame(width: 90, height: 90)
                        .rotationEffect(.degrees(-90))
                        .opacity(dimOpacity(for: .recommended))
                }

                if reviewBytes > 0 {
                    Circle()
                        .trim(from: revStart, to: revEnd)
                        .stroke(
                            AppTheme.gradient(for: .reviewSuggested),
                            style: StrokeStyle(lineWidth: ringWidth(for: .reviewSuggested), lineCap: .round)
                        )
                        .frame(width: 90, height: 90)
                        .rotationEffect(.degrees(-90))
                        .opacity(dimOpacity(for: .reviewSuggested))
                }

                if protectedBytes > 0 {
                    Circle()
                        .trim(from: proStart, to: proEnd)
                        .stroke(
                            AppTheme.color(for: .notRecommended).opacity(0.55),
                            style: StrokeStyle(lineWidth: ringWidth(for: .notRecommended), lineCap: .round)
                        )
                        .frame(width: 90, height: 90)
                        .rotationEffect(.degrees(-90))
                        .opacity(dimOpacity(for: .notRecommended))
                }
            }

            if isScanning && !reduceMotion {
                TimelineView(.animation(paused: scanRingPlaybackPolicy.isPaused)) { timeline in
                    let angle = (motionClock.elapsed(at: timeline.date) * 220).truncatingRemainder(dividingBy: 360)
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(
                            LinearGradient(
                                colors: [.clear, Color(red: 0.20, green: 0.94, blue: 0.72)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .frame(width: 102, height: 102)
                        .rotationEffect(.degrees(angle))
                }
            }

            VStack(spacing: 1) {
                Text(centerLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(centerText)
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(centerColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(centerValue)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: centerText)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 102, height: 102)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
            value: metrics
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84),
            value: appeared
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: highlightedTier
        )
        .onAppear {
            appeared = true
            motionClock.setPaused(scanRingPlaybackPolicy.isPaused)
        }
        .onChange(of: scanRingPlaybackPolicy.isPaused) { _, isPaused in
            motionClock.setPaused(isPaused)
        }
    }

    private func ringWidth(for tier: CleanupRecommendation) -> CGFloat {
        highlightedTier == tier ? 11.0 : 8.5
    }

    private func dimOpacity(for tier: CleanupRecommendation) -> Double {
        guard let highlightedTier else { return 1.0 }
        return highlightedTier == tier ? 1.0 : 0.24
    }

    private var centerLabel: String {
        switch highlightedTier {
        case .recommended: return "建议清理"
        case .reviewSuggested: return "按需清理"
        case .notRecommended: return "不建议清理"
        case nil: return "可清理"
        }
    }

    private var centerBytes: Int64 {
        switch highlightedTier {
        case .recommended: return recommendedBytes
        case .reviewSuggested: return reviewBytes
        case .notRecommended: return protectedBytes
        case nil: return cleanableBytes
        }
    }

    private var centerColor: Color {
        if let highlightedTier {
            return AppTheme.color(for: highlightedTier)
        }
        return cleanableBytes > 0 ? AppTheme.color(for: .recommended) : .secondary
    }
}

// MARK: - 4. 清理完成微光粒子礼花（仅成功瞬间触发，1.4s 自动休眠）

struct SparkleBurstOverlay: View {
    let triggerID: UUID
    let isVisible: Bool
    let consumeTrigger: ((UUID) -> Bool)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var startDate: Date = Date()
    @State private var isBurstActive: Bool

    init(
        triggerID: UUID,
        isVisible: Bool = true,
        initialBurstActive: Bool = false,
        consumeTrigger: ((UUID) -> Bool)? = nil
    ) {
        self.triggerID = triggerID
        self.isVisible = isVisible
        self.consumeTrigger = consumeTrigger
        _isBurstActive = State(initialValue: initialBurstActive)
    }

    private var playbackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            isFeatureActive: isBurstActive,
            reduceMotion: reduceMotion
        )
    }

    private struct Particle {
        let angle: Double
        let speed: Double
        let size: CGFloat
        let color: Color
        let delay: Double
    }

    private static let palette: [Color] = [
        Color(red: 0.16, green: 0.88, blue: 0.58),
        Color(red: 0.26, green: 0.72, blue: 1.00),
        Color(red: 0.98, green: 0.76, blue: 0.26),
        Color(red: 0.62, green: 0.52, blue: 1.00)
    ]

    private let particles: [Particle] = (0..<20).map { idx in
        let angle = (Double(idx) / 20.0) * .pi * 2.0 + Double(idx % 3) * 0.12
        let speed = 50.0 + Double((idx * 27) % 68)
        let size = CGFloat(3.2 + Double(idx % 4) * 1.2)
        let color = palette[idx % palette.count]
        let delay = Double(idx % 5) * 0.024
        return Particle(angle: angle, speed: speed, size: size, color: color, delay: delay)
    }

    var body: some View {
        Color.clear
            .overlay {
                if !reduceMotion && isBurstActive {
                    TimelineView(.animation(paused: playbackPolicy.isPaused)) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        if elapsed < 1.35 {
                            Canvas { context, size in
                                drawParticles(in: &context, size: size, elapsed: elapsed)
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .onChange(of: isVisible) { _, visible in
                if !visible && isBurstActive {
                    isBurstActive = false
                }
            }
            .task(id: triggerID) {
                guard isVisible else {
                    isBurstActive = false
                    return
                }
                let shouldPlay = consumeTrigger?(triggerID) ?? true
                guard shouldPlay, !reduceMotion else {
                    isBurstActive = false
                    return
                }
                startDate = Date()
                isBurstActive = true
                defer { isBurstActive = false }
                try? await Task.sleep(for: .milliseconds(1400))
            }
    }

    private func drawParticles(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
        let origin = CGPoint(x: 28, y: size.height * 0.5)
        for p in particles {
            let localT = max(0, elapsed - p.delay)
            guard localT > 0 && localT < 1.15 else { continue }
            let progress = localT / 1.15
            let eased = 1.0 - pow(1.0 - progress, 3.0)
            let dist = p.speed * eased
            let x = origin.x + CGFloat(cos(p.angle) * dist)
            let y = origin.y + CGFloat(sin(p.angle) * dist * 0.65 - 10.0 * sin(progress * .pi))
            let alpha = max(0, 1.0 - pow(progress, 1.8))
            let radius = p.size * CGFloat(1.0 - 0.4 * progress)
            let rect = CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)
            context.fill(Path(ellipseIn: rect), with: .color(p.color.opacity(alpha)))
        }
    }
}

// MARK: - 5. 弹性勾选框（AnimatedCheckbox）

struct AnimatedCheckbox: View {
    let isChecked: Bool
    let tint: Color
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(
                        isChecked
                            ? LinearGradient(
                                colors: [tint, tint.opacity(0.84)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03),
                                    Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: 17, height: 17)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(
                                isChecked ? Color.white.opacity(0.32) : Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.20),
                                lineWidth: 1.0
                            )
                    )
                    .shadow(color: isChecked ? tint.opacity(0.38) : .clear, radius: 4, y: 1)

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .scaleEffect(isChecked ? 1.0 : 0.96)
            .animation(
                reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.66),
                value: isChecked
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isChecked ? "取消勾选" : "勾选此项")
    }
}

// MARK: - 6. 应用发光矢量徽章（Sidebar Brand Emblem）

struct BrandLogoEmblem: View {
    var isScanning: Bool = false
    var isVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var motionClock = PausableAnimationClock()

    private var playbackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            isFeatureActive: isScanning,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        ZStack {
            if isScanning && !reduceMotion {
                TimelineView(.animation(paused: playbackPolicy.isPaused)) { timeline in
                    let angle = (motionClock.elapsed(at: timeline.date) * 180).truncatingRemainder(dividingBy: 360)
                    RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.90, blue: 0.66),
                                    Color(red: 0.28, green: 0.64, blue: 1.00),
                                    .clear,
                                    Color(red: 0.14, green: 0.90, blue: 0.66)
                                ],
                                center: .center
                            ),
                            lineWidth: 1.8
                        )
                        .frame(width: 32, height: 32)
                        .rotationEffect(.degrees(angle))
                }
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.brandGradient)
                .frame(width: 27, height: 27)
                .shadow(color: Color(red: 0.14, green: 0.80, blue: 0.64).opacity(0.40), radius: 6, y: 1.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.50), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )

            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .onAppear {
            motionClock.setPaused(playbackPolicy.isPaused)
        }
        .onChange(of: playbackPolicy.isPaused) { _, isPaused in
            motionClock.setPaused(isPaused)
        }
    }
}

// MARK: - 7. 顶边极光扫描光束（Canvas 严格裁剪，绝不溢出卡片边界）

struct AuroraScanSweepBar: View {
    var isVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var motionClock = PausableAnimationClock()

    private var playbackPolicy: AnimationPlaybackPolicy {
        AnimationPlaybackPolicy(
            isWindowVisibleOnScreen: isWindowVisibleOnScreen,
            isPageVisible: isVisible,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Group {
            if reduceMotion {
                Rectangle()
                    .fill(AppTheme.brandGradient)
                    .opacity(0.70)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: playbackPolicy.isPaused)) { timeline in
                    let rawPhase = (motionClock.elapsed(at: timeline.date) * 0.78)
                        .truncatingRemainder(dividingBy: 1.0)
                    let phase = rawPhase < 0 ? rawPhase + 1.0 : rawPhase
                    Canvas { context, size in
                        drawSweepBeam(in: &context, size: size, phase: phase)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 2.5)
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            motionClock.setPaused(playbackPolicy.isPaused)
        }
        .onChange(of: playbackPolicy.isPaused) { _, isPaused in
            motionClock.setPaused(isPaused)
        }
    }

    private func drawSweepBeam(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        guard size.width > 1, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        context.clip(to: Path(bounds))

        // 极淡底轨，明确标示加载条范围严格位于卡片内部
        context.fill(
            Path(bounds),
            with: .color(Color(red: 0.14, green: 0.82, blue: 0.62).opacity(0.14))
        )

        let beamWidth = min(max(96, size.width * 0.30), size.width * 0.55)
        let travel = size.width + beamWidth
        let startX = CGFloat(phase) * travel - beamWidth
        let beamRect = CGRect(x: startX, y: 0, width: beamWidth, height: size.height)

        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: Color(red: 0.14, green: 0.84, blue: 0.60).opacity(0.85), location: 0.35),
            .init(color: Color(red: 0.24, green: 0.68, blue: 1.00).opacity(0.95), location: 0.65),
            .init(color: .clear, location: 1.0)
        ])

        context.fill(
            Path(roundedRect: beamRect, cornerRadius: size.height / 2),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: beamRect.minX, y: size.height / 2),
                endPoint: CGPoint(x: beamRect.maxX, y: size.height / 2)
            )
        )
    }
}
