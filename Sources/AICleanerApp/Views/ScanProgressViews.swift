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

/// 客户端发现单行跑马灯：只展示已量出真实体积的客户端卡片，
/// 新卡片从右侧滑入，超出一行容量时最早的卡片从左侧滚出消失（不出「检测中」占位卡）。
struct ScanDiscoveryTickerRow: View {
    let progress: ScanProgressModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ticker = ScanDiscoveryTickerState()
    @State private var drainTask: Task<Void, Never>?

    static let cardWidth: CGFloat = 132
    static let cardSpacing: CGFloat = 10
    static let rowHeight: CGFloat = 92

    private var revealed: [ScanProgressClient] { progress.revealedClients }
    private var revealedIDs: [String] { revealed.map(\.id) }

    private var rowWidth: CGFloat {
        let count = CGFloat(ticker.visibleCapacity)
        return count * Self.cardWidth + (count - 1) * Self.cardSpacing
    }

    var body: some View {
        HStack(spacing: Self.cardSpacing) {
            ForEach(ticker.visibleIDs, id: \.self) { id in
                if let client = revealed.first(where: { $0.id == id }) {
                    ScanDiscoveryCard(client: client)
                        .frame(width: Self.cardWidth)
                        .transition(cardTransition)
                }
            }
        }
        .frame(width: rowWidth, height: Self.rowHeight)
        .clipped()
        .mask(edgeFadeMask)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { syncTicker(with: revealedIDs) }
        .onChange(of: revealedIDs) { _, ids in syncTicker(with: ids) }
        .onDisappear {
            drainTask?.cancel()
            drainTask = nil
        }
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    /// 两侧渐隐，让滚入 / 滚出更柔和
    private var edgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var accessibilityLabel: String {
        guard let latest = revealed.last else { return "正在发现 AI 客户端" }
        return "已发现 \(revealed.count) 个客户端，最新：\(latest.name)，可清理 \(CleanerFormatting.formatBytes(latest.cleanableBytes))"
    }

    private func syncTicker(with ids: [String]) {
        ticker.sync(with: ids)
        if ids.isEmpty {
            drainTask?.cancel()
            drainTask = nil
            return
        }
        scheduleDrain()
    }

    /// 按节奏逐张放出卡片（纯呈现节奏，数据仍完全来自引擎事件）
    private func scheduleDrain() {
        guard drainTask == nil, ticker.hasPending else { return }
        drainTask = Task { @MainActor in
            while ticker.hasPending, !Task.isCancelled {
                if reduceMotion {
                    ticker.advance()
                } else {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        _ = ticker.advance()
                    }
                }
                try? await Task.sleep(for: .seconds(ticker.releaseInterval))
            }
            drainTask = nil
        }
    }
}

/// 单张客户端发现卡片：图标 + 名称 + 可清理体积（只用于已量出真实数据的客户端）
private struct ScanDiscoveryCard: View {
    let client: ScanProgressClient
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { AppTheme.color(forAccentToken: client.accentToken) }

    var body: some View {
        VStack(spacing: 6) {
            iconTile
                .frame(width: 36, height: 36)

            Text(client.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(CleanerFormatting.formatBytes(client.cleanableBytes))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(red: 0.11, green: 0.72, blue: 0.55))
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
    }

    @ViewBuilder
    private var iconTile: some View {
        let cornerRadius: CGFloat = 10

        if let image = ClientLogoResolver.shared.image(for: client.id, colorScheme: colorScheme) {
            // 本机可解析到真实应用 / 品牌图标时直接展示（与侧栏同源）
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }
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
