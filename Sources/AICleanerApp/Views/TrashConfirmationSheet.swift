import AICleanerCore
import SwiftUI

struct TrashConfirmationSheet: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var acknowledgedNotRecommendedRisk: Bool = false

    private var hasHighRiskItems: Bool {
        viewModel.hasSelectedNotRecommendedItems
    }

    private var canConfirmTrash: Bool {
        guard !viewModel.isCleaning && !viewModel.selectedItems.isEmpty else { return false }
        if hasHighRiskItems && !acknowledgedNotRecommendedRisk {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.dangerGradient.opacity(0.22))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(red: 0.96, green: 0.34, blue: 0.42).opacity(0.45), lineWidth: 1)
                        )
                    Image(systemName: hasHighRiskItems ? "exclamationmark.triangle.fill" : "trash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.44))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(hasHighRiskItems ? "确认移入废纸篓（含高风险项）" : "确认移入废纸篓")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    HStack(spacing: 5) {
                        Text("拟移入 \(viewModel.selectedItems.count) 项，共")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(CleanerFormatting.formatBytes(viewModel.selectedTotalBytes))
                            .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(AppTheme.color(for: .recommended))
                    }
                }
            }

            if hasHighRiskItems {
                let riskColor = AppTheme.color(for: .notRecommended)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(riskColor)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("包含 \(viewModel.selectedNotRecommendedItems.count) 项「不建议清理」条目（\(CleanerFormatting.formatBytes(viewModel.selectedNotRecommendedTotalBytes))）")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(riskColor)
                        Text("移入这些条目可能导致配置、登录或历史状态丢失，也可能需要重新下载插件或模型。如需恢复，请在废纸篓中选择「放回原处」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(riskColor.opacity(colorScheme == .dark ? 0.16 : 0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(riskColor.opacity(0.45), lineWidth: 0.9)
                )
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(AppTheme.color(for: .recommended))
                        .padding(.top, 1)
                    Text("如需恢复，请在废纸篓中选择「放回原处」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.color(for: .recommended).opacity(colorScheme == .dark ? 0.13 : 0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.color(for: .recommended).opacity(0.28), lineWidth: 0.7)
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.groupedSelectedItems) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.clientName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(group.items.count) 项 · \(CleanerFormatting.formatBytes(group.totalBytes))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    let isRisk = item.recommendation == .notRecommended
                                    let riskColor = AppTheme.color(for: .notRecommended)

                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: isRisk ? "exclamationmark.shield.fill" : (item.isDirectory ? "folder.fill" : "doc.fill"))
                                            .font(.caption)
                                            .foregroundStyle(isRisk ? riskColor : .secondary)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(item.preferredDisplayTitle)
                                                    .font(.callout.weight(isRisk ? .semibold : .regular))
                                                    .foregroundStyle(isRisk ? riskColor : .primary)
                                                    .lineLimit(1)

                                                if isRisk {
                                                    Text("不建议清理")
                                                        .font(.system(size: 9.5, weight: .bold))
                                                        .padding(.horizontal, 5.5)
                                                        .padding(.vertical, 1.5)
                                                        .background(Capsule().fill(riskColor.opacity(0.18)))
                                                        .foregroundStyle(riskColor)
                                                }
                                            }

                                            if isRisk {
                                                Text(item.safetyNote)
                                                    .font(.caption2)
                                                    .foregroundStyle(riskColor.opacity(0.92))
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }

                                            Text(viewModel.abbreviatedPath(for: item))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer(minLength: 8)

                                        Text(CleanerFormatting.formatBytes(item.sizeBytes))
                                            .font(.caption.monospacedDigit().weight(isRisk ? .semibold : .regular))
                                            .foregroundStyle(isRisk ? riskColor : .secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(isRisk ? riskColor.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear)

                                    if item.id != group.items.last?.id {
                                        Divider()
                                            .padding(.leading, 28)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.glassCardFill(for: colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.75)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 290)

            if hasHighRiskItems {
                let riskColor = AppTheme.color(for: .notRecommended)
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72)) {
                        acknowledgedNotRecommendedRisk.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 9) {
                        AnimatedCheckbox(
                            isChecked: acknowledgedNotRecommendedRisk,
                            tint: riskColor
                        ) {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72)) {
                                acknowledgedNotRecommendedRisk.toggle()
                            }
                        }

                        Text("我了解风险，仍要移入废纸篓。")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                acknowledgedNotRecommendedRisk ? riskColor.opacity(0.45) : AppTheme.hairlineDivider(for: colorScheme),
                                lineWidth: 0.8
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isCleaning)

                Button {
                    viewModel.confirmAndTrashSelectedItems(
                        acknowledgedNotRecommendedRisk: acknowledgedNotRecommendedRisk
                    )
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(viewModel.isCleaning ? "正在移入…" : "移入废纸篓")
                    }
                }
                .buttonStyle(
                    GlowingPillButtonStyle(
                        gradient: AppTheme.dangerGradient,
                        glowColor: Color(red: 0.94, green: 0.28, blue: 0.36),
                        isEnabled: canConfirmTrash
                    )
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirmTrash)
            }
        }
        .padding(22)
        .frame(width: 580)
        .background(AppTheme.canvasBackground(for: colorScheme))
        .onAppear {
            acknowledgedNotRecommendedRisk = false
        }
    }
}
