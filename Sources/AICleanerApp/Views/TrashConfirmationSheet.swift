import AICleanerCore
import SwiftUI

struct TrashConfirmationSheet: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.dangerGradient.opacity(0.22))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(red: 0.96, green: 0.34, blue: 0.42).opacity(0.45), lineWidth: 1)
                        )
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.44))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("确认移入系统废纸篓")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    HStack(spacing: 5) {
                        Text("即将清理 \(viewModel.selectedItems.count) 个条目，预计释放")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(CleanerFormatting.formatBytes(viewModel.selectedTotalBytes))
                            .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(AppTheme.color(for: .recommended))
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppTheme.color(for: .recommended))
                    .padding(.top, 1)
                Text("安全清理保证：本应用仅调用 macOS 系统废纸篓接口，不执行不可逆永久删除。清理后如发现需要还原，可在「废纸篓」中选择「放回原处」。")
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
                                    HStack(spacing: 8) {
                                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.displayName)
                                                .font(.callout)
                                                .lineLimit(1)
                                            Text(CleanerFormatting.abbreviatePath(item.url))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(CleanerFormatting.formatBytes(item.sizeBytes))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)

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
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isCleaning)

                Button {
                    viewModel.confirmAndTrashSelectedItems()
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(viewModel.isCleaning ? "正在移入…" : "确认移入废纸篓")
                    }
                }
                .buttonStyle(
                    GlowingPillButtonStyle(
                        gradient: AppTheme.dangerGradient,
                        glowColor: Color(red: 0.94, green: 0.28, blue: 0.36),
                        isEnabled: !viewModel.isCleaning && !viewModel.selectedItems.isEmpty
                    )
                )
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isCleaning || viewModel.selectedItems.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(AppTheme.canvasBackground(for: colorScheme))
    }
}
