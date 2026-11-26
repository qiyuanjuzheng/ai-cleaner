import AICleanerCore
import SwiftUI

// MARK: - 扫描进度页组件（步骤条 + 客户端发现卡片 + 实时统计）
// 数据全部来自 `ScanProgressModel`（扫描引擎进度事件驱动），视图只负责呈现。

/// 步骤条：三阶段胶囊（扫描客户端 → 分析缓存文件 → 统计可释放空间）
struct ScanStageProgressBar: View {
    let progress: ScanProgressModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ScanStage.allCases, id: \.self) { stage in
                stageCapsule(stage)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: stageSignature)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.stageAccessibilityLabel)
    }

    /// 用等值签名驱动整体过渡：阶段切换或完成态变化时才触发动画
    private var stageSignature: StageSignature {
        StageSignature(
            currentStage: progress.currentStage,
            isCompleted: progress.isCompleted
        )
    }

    @ViewBuilder
    private func stageCapsule(_ stage: ScanStage) -> some View {
        let state = progress.displayState(for: stage)
        let tint = stageTint(state)

        HStack(spacing: 6) {
            stageDot(state)
            Text(stage.displayName)
                .font(.caption.weight(state == .pending ? .regular : .semibold))
                .foregroundStyle(state == .pending ? Color.secondary.opacity(0.75) : tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(capsuleFill(state, tint: tint))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    state == .active ? tint.opacity(0.32) : .clear,
                    lineWidth: 0.8
                )
        )
    }

    @ViewBuilder
    private func stageDot(_ state: ScanProgressModel.StageDisplayState) -> some View {
        let tint = stageTint(state)
        ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                Circle()
                    .fill(tint)
                Text("\(stageDotNumber)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            case .pending:
                Circle()
                    .fill(Color.primary.opacity(0.07))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            }
        }
        .frame(width: 15, height: 15)
    }

    /// 进行中步骤的序号（完成态步骤由对勾替代，不再显示数字）
    private var stageDotNumber: Int {
        guard let current = progress.currentStage else { return 1 }
        return current.ordinal + 1
    }

    private func stageTint(_ state: ScanProgressModel.StageDisplayState) -> Color {
        switch state {
        case .done:
            return Color(red: 0.14, green: 0.84, blue: 0.62)
        case .active:
            return Color(red: 0.24, green: 0.56, blue: 1.00)
        case .pending:
            return Color.secondary
        }
    }

    private func capsuleFill(_ state: ScanProgressModel.StageDisplayState, tint: Color) -> Color {
        switch state {
        case .done:
            return tint.opacity(0.10)
        case .active:
            return tint.opacity(0.14)
        case .pending:
            return Color.primary.opacity(0.045)
        }
    }
}

/// 步骤条动画签名（Equatable，避免逐帧比较视图状态）
private struct StageSignature: Equatable {
    let currentStage: ScanStage?
    let isCompleted: Bool
}

/// 客户端发现卡片栅格：每扫描到一个客户端弹入一张卡片，检测中的客户端显示占位卡片
struct ScanDiscoveryCardGrid: View {
    let progress: ScanProgressModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardMinimumWidth: CGFloat = 118

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: cardMinimumWidth, maximum: 150), spacing: 10)],
            alignment: .center,
            spacing: 10
        ) {
            ForEach(progress.detectedClients) { client in
                ScanDiscoveryCard(client: client)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82),
            value: clientIDs
        )
    }

    private var clientIDs: [String] {
        progress.detectedClients.map(\.id)
    }
}

/// 单张客户端发现卡片
private struct ScanDiscoveryCard: View {
    let client: ScanProgressClient
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowVisibleOnScreen) private var isWindowVisibleOnScreen
    @State private var shimmerClock = PausableAnimationClock()

    private var isDetecting: Bool { client.state == .detecting }
    private var accent: Color { AppTheme.color(forAccentToken: client.accentToken) }
    private var isShimmerPaused: Bool { reduceMotion || !isWindowVisibleOnScreen }

    var body: some View {
        VStack(spacing: 6) {
            iconTile
                .frame(width: 36, height: 36)

            Text(isDetecting ? "检测中…" : client.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isDetecting ? Color.secondary.opacity(0.8) : Color.primary)
                .lineLimit(1)

            Text(isDetecting ? "—" : CleanerFormatting.formatBytes(client.cleanableBytes))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(isDetecting ? Color.secondary.opacity(0.55) : Color(red: 0.11, green: 0.72, blue: 0.55))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppTheme.glassCardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    private var cardAccessibilityLabel: String {
        if isDetecting {
            return "\(client.name)，检测中"
        }
        return "\(client.name)，可清理 \(CleanerFormatting.formatBytes(client.cleanableBytes))"
    }

    @ViewBuilder
    private var iconTile: some View {
        let cornerRadius: CGFloat = 10

        if isDetecting {
            shimmerTile
                .overlay(
                    Image(systemName: client.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.18))
                )
                .frame(width: 36, height: 36)
                .onAppear {
                    shimmerClock.setPaused(isShimmerPaused)
                }
                .onChange(of: isShimmerPaused) { _, paused in
                    shimmerClock.setPaused(paused)
                }
        } else if let image = ClientLogoResolver.shared.image(for: client.id, colorScheme: colorScheme) {
            // 本机可解析到真实应用 / 品牌图标时直接展示（与侧栏同源）
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }
            .frame(width: 36, height: 36)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.82), accent.opacity(0.60)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: client.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        }
    }

    /// 「检测中」占位光泽：轻微呼吸的高光（减弱动态效果或窗口不可见时静止）
    @ViewBuilder
    private var shimmerTile: some View {
        let cornerRadius: CGFloat = 10
        let baseOpacity: Double = colorScheme == .dark ? 0.09 : 0.07

        if isShimmerPaused {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(baseOpacity))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let phase = (sin(shimmerClock.elapsed(at: timeline.date) * 2.2) + 1) / 2
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(baseOpacity + 0.05 * phase),
                                Color.primary.opacity(baseOpacity + 0.11 * phase),
                                Color.primary.opacity(baseOpacity + 0.05 * phase)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
    }
}

/// 实时统计：已扫描文件数 + 已发现可清理空间（等宽数字防抖动）
struct ScanLiveStatsRow: View {
    let progress: ScanProgressModel

    var body: some View {
        HStack(spacing: 40) {
            statItem(
                value: formatCount(progress.scannedFileCount),
                label: "已扫描文件数",
                valueTint: .primary
            )
            statItem(
                value: CleanerFormatting.formatBytes(progress.cleanableBytes),
                label: "已发现可清理空间",
                valueTint: Color(red: 0.14, green: 0.72, blue: 0.55)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.statsAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func formatCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    private func statItem(value: String, label: String, valueTint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
