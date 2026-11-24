import AICleanerCore
import SwiftUI

struct BottomActionBar: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let result = viewModel.lastCleanupResult {
                cleanupCelebrationPill(result)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94))
                    )
            }

            if !viewModel.selectedItems.isEmpty {
                floatingSelectionDock
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94))
                    )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: viewModel.selectedItems.isEmpty)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: viewModel.lastCleanupResult != nil)
    }

    // MARK: - 居中悬浮玻璃操作岛（勾选后丝滑升起，未勾选时零视觉干扰）

    private var floatingSelectionDock: some View {
        let hasRisk = viewModel.hasSelectedNotRecommendedItems
        let dotColor = hasRisk ? AppTheme.color(for: .notRecommended) : AppTheme.color(for: .recommended)

        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7.5, height: 7.5)
                    .shadow(color: dotColor.opacity(0.85), radius: 4)

                Text("已选 \(viewModel.selectedItems.count) 项")
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())

                if hasRisk {
                    Text("含 \(viewModel.selectedNotRecommendedItems.count) 项高风险")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.color(for: .notRecommended).opacity(0.18)))
                        .foregroundStyle(AppTheme.color(for: .notRecommended))
                }

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("预计释放 \(CleanerFormatting.formatBytes(viewModel.selectedTotalBytes))")
                    .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(hasRisk ? AppTheme.color(for: .reviewSuggested) : AppTheme.color(for: .recommended))
                    .contentTransition(.numericText())
            }

            Divider()
                .frame(height: 16)
                .opacity(0.45)

            Button("清空") {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    viewModel.clearAllSelection()
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            Button {
                viewModel.requestTrashConfirmation()
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isCleaning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text(viewModel.isCleaning ? "移入中…" : "移入废纸篓…")
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(
                GlowingPillButtonStyle(
                    gradient: AppTheme.dangerGradient,
                    glowColor: Color(red: 0.94, green: 0.28, blue: 0.36),
                    isEnabled: !viewModel.isCleaning && !viewModel.isScanning,
                    compact: true
                )
            )
            .disabled(viewModel.isCleaning || viewModel.isScanning)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(AppTheme.glassElevatedFill(for: colorScheme))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.95)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 20, y: 8)
    }

    // MARK: - 清理成功微光粒子庆祝胶囊

    private func cleanupCelebrationPill(_ result: CleanupResult) -> some View {
        let isPureSuccess = !result.hasFailures && result.trashedCount > 0
        let tint = isPureSuccess ? AppTheme.color(for: .recommended) : AppTheme.color(for: .reviewSuggested)

        return ZStack {
            HStack(spacing: 10) {
                Image(systemName: isPureSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 1.5) {
                    if result.trashedCount > 0 {
                        HStack(spacing: 5) {
                            Text("已释放")
                                .font(.callout.weight(.medium))
                            Text(CleanerFormatting.formatBytes(result.freedBytes))
                                .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                                .foregroundStyle(tint)
                            Text("（\(result.trashedCount) 项已移入废纸篓）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("查看趋势 →") {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80)) {
                                    viewModel.dismissCleanupBanner()
                                    viewModel.sidebarSelection = .history
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption.weight(.semibold))
                        }
                    } else {
                        Text("本次未移入任何条目")
                            .font(.callout.weight(.medium))
                    }

                    if !result.skippedProtectedItems.isEmpty {
                        Text("安全护栏自动拦截 \(result.skippedProtectedItems.count) 项受保护目标")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !result.failedItems.isEmpty {
                        Text("有 \(result.failedItems.count) 项未能移入废纸篓：\(result.failedItems.first?.reason ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        viewModel.dismissCleanupBanner()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(AppTheme.glassElevatedFill(for: colorScheme))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.specularRimGradient(for: colorScheme, accent: tint), lineWidth: 0.95)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.12), radius: 16, y: 6)

            if isPureSuccess {
                SparkleBurstOverlay(triggerID: viewModel.cleanupCelebrationID)
                    .clipShape(Capsule(style: .continuous))
            }
        }
    }
}
