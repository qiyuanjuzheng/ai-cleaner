import AICleanerCore
import SwiftUI

struct TrashConfirmationSheet: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("确认移入系统废纸篓")
                        .font(.title3.weight(.semibold))
                    Text("即将清理 \(viewModel.selectedItems.count) 个条目，预计释放 \(CleanerFormatting.formatBytes(viewModel.selectedTotalBytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 1)
                Text("安全清理保证：本应用仅调用 macOS 系统废纸篓接口，不执行不可逆永久删除。清理后如发现需要还原，可在「废纸篓」中选择「放回原处」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.09))
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
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.6)
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
                        }
                        Text(viewModel.isCleaning ? "正在移入…" : "确认移入废纸篓")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isCleaning || viewModel.selectedItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
