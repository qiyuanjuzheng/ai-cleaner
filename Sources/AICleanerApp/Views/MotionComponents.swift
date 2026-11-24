import AICleanerCore
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

// MARK: - 2A. 初始待扫描欢迎核心视图（与扫描中雷达等尺寸，切换零抖动）

struct ScanReadyHeroView: View {
    let historicalFreedBytes: Int64
    var isVisible: Bool = true
    let onStartScan: () -> Void
    let onOpenHistory: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private var shouldAnimate: Bool {
        isVisible && !reduceMotion && controlActiveState != .inactive
    }

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !shouldAnimate)) { timeline in
                let elapsed = shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0.0
                let breathe = shouldAnimate ? (0.97 + 0.03 * sin(elapsed * 1.6)) : 1.0
                let slowRotation = Angle.degrees((elapsed * 9).truncatingRemainder(dividingBy: 360))

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(colorScheme == .dark ? 0.22 : 0.15),
                                    Color(red: 0.24, green: 0.58, blue: 1.00).opacity(colorScheme == .dark ? 0.08 : 0.06),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 18,
                                endRadius: 96
                            )
                        )
                        .frame(width: 192, height: 192)
                        .scaleEffect(breathe)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.45),
                                    Color(red: 0.24, green: 0.60, blue: 1.00).opacity(0.28),
                                    Color.primary.opacity(0.06),
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.45)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [8, 8])
                        )
                        .frame(width: 152, height: 152)
                        .rotationEffect(slowRotation)

                    Circle()
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 1)
                        .frame(width: 112, height: 112)

                    ZStack {
                        Circle()
                            .fill(AppTheme.brandGradient)
                            .frame(width: 60, height: 60)
                            .shadow(color: Color(red: 0.14, green: 0.80, blue: 0.64).opacity(0.40), radius: 14, y: 4)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.0
                                    )
                            )

                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(breathe)
                }
                .frame(width: 210, height: 210)
            }

            Text("扫描 AI 客户端")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .frame(height: 50)

            HStack(spacing: 12) {
                Button(action: onStartScan) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13.5, weight: .bold))
                        Text("开始扫描")
                    }
                    .padding(.horizontal, 12)
                }
                .buttonStyle(
                    GlowingPillButtonStyle(
                        gradient: AppTheme.gradient(for: .recommended),
                        glowColor: AppTheme.color(for: .recommended),
                        isEnabled: true
                    )
                )
            }
            .frame(height: 44)

            HStack {
                if historicalFreedBytes > 0 {
                    Button(action: onOpenHistory) {
                        HStack(spacing: 5) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.color(for: .recommended))
                            Text("累计已移入废纸篓 \(CleanerFormatting.formatBytes(historicalFreedBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("查看移入废纸篓趋势")
                }
            }
            .frame(height: 18)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 2B. 轨道雷达扫描核心动效（全盘只读扫描中 Hero）

struct OrbitalScannerHero: View {
    var isVisible: Bool = true
    var onCancel: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    private var shouldAnimate: Bool {
        isVisible && !reduceMotion && controlActiveState != .inactive
    }

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation(paused: !shouldAnimate)) { timeline in
                let elapsed = shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0.0
                let sweepAngle = Angle.degrees((elapsed * 120).truncatingRemainder(dividingBy: 360))
                let outerRotation = Angle.degrees((elapsed * 24).truncatingRemainder(dividingBy: 360))
                let innerRotation = Angle.degrees((-elapsed * 40).truncatingRemainder(dividingBy: 360))
                let pulse = shouldAnimate ? (0.95 + 0.06 * sin(elapsed * 2.8)) : 1.0

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.24),
                                    Color(red: 0.24, green: 0.56, blue: 1.00).opacity(0.06),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 14,
                                endRadius: 94
                            )
                        )
                        .frame(width: 188, height: 188)
                        .scaleEffect(pulse)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.65),
                                    Color(red: 0.24, green: 0.58, blue: 1.00).opacity(0.30),
                                    Color.white.opacity(0.06),
                                    Color(red: 0.14, green: 0.84, blue: 0.62).opacity(0.65)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [9, 8])
                        )
                        .frame(width: 152, height: 152)
                        .rotationEffect(outerRotation)

                    Circle()
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 1)
                        .frame(width: 112, height: 112)

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
                            .frame(width: 150, height: 150)
                            .rotationEffect(sweepAngle)
                    }

                    Circle()
                        .stroke(
                            Color(red: 0.36, green: 0.64, blue: 1.00).opacity(0.42),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 10])
                        )
                        .frame(width: 78, height: 78)
                        .rotationEffect(innerRotation)

                    ZStack {
                        Circle()
                            .fill(AppTheme.brandGradient)
                            .frame(width: 50, height: 50)
                            .shadow(color: Color(red: 0.14, green: 0.80, blue: 0.64).opacity(0.48), radius: 12)

                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(pulse)
                }
                .frame(width: 210, height: 210)
            }

            Text("正在扫描 AI 客户端…")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .frame(height: 50)

            HStack {
                if let onCancel {
                    Button("取消扫描", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .frame(height: 44)

            Color.clear
                .frame(height: 18)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 3. 极简精致多段环形空间仪表盘（StorageRingGauge）

struct StorageRingGauge: View {
    let recommendedBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64
    let highlightedTier: CleanupRecommendation?
    var isScanning: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var appeared: Bool = false

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

            if isScanning && !reduceMotion && controlActiveState != .inactive {
                TimelineView(.animation) { timeline in
                    let angle = (timeline.date.timeIntervalSinceReferenceDate * 220).truncatingRemainder(dividingBy: 360)
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
                Text(CleanerFormatting.formatBytes(centerBytes))
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(centerColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date = Date()
    @State private var isBurstActive: Bool = true

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
        Group {
            if !reduceMotion && isBurstActive {
                TimelineView(.animation(paused: !isBurstActive)) { timeline in
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
        .task(id: triggerID) {
            startDate = Date()
            isBurstActive = true
            try? await Task.sleep(for: .milliseconds(1400))
            isBurstActive = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            if isScanning && !reduceMotion && controlActiveState != .inactive {
                TimelineView(.animation) { timeline in
                    let angle = (timeline.date.timeIntervalSinceReferenceDate * 180).truncatingRemainder(dividingBy: 360)
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
    }
}

// MARK: - 7. 顶边极光扫描光束（Canvas 严格裁剪，绝不溢出卡片边界）

struct AuroraScanSweepBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Group {
            if reduceMotion {
                Rectangle()
                    .fill(AppTheme.brandGradient)
                    .opacity(0.70)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: controlActiveState == .inactive)) { timeline in
                    let phase = (timeline.date.timeIntervalSinceReferenceDate * 0.78)
                        .truncatingRemainder(dividingBy: 1.0)
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
