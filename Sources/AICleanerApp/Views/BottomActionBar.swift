import AICleanerCore
import SwiftUI

struct BottomActionBar: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let result = viewModel.lastCleanupResult {
                cleanupResultBanner(result)
                Divider()
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if viewModel.selectedItems.isEmpty {
                        Text("勾选需要清理的条目，所有操作均移入 macOS 系统废纸篓")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text("已选 \(viewModel.selectedItems.count) 项")
                                .font(.headline.monospacedDigit())
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("预计释放 \(CleanerFormatting.formatBytes(viewModel.selectedTotalBytes))")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Color.accentColor)

                            Button("清空选择") {
                                viewModel.clearAllSelection()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

                        if viewModel.groupedSelectedItems.count > 1 {
                            Text("跨 \(viewModel.groupedSelectedItems.count) 个客户端/目录，点击「移入废纸篓」前可查看完整确认清单")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    viewModel.requestTrashConfirmation()
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(viewModel.isCleaning ? "正在移入废纸篓…" : "移入废纸篓…")
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(viewModel.selectedItems.isEmpty || viewModel.isCleaning || viewModel.isScanning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func cleanupResultBanner(_ result: CleanupResult) -> some View {
        let isPureSuccess = !result.hasFailures && result.trashedCount > 0
        let tint: Color = isPureSuccess ? .green : .orange

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: isPureSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                if result.trashedCount > 0 {
                    Text("已将 \(result.trashedCount) 项安全移入废纸篓，实际释放 \(CleanerFormatting.formatBytes(result.freedBytes))（如需恢复可在系统废纸篓中放回原处）。")
                        .font(.callout.weight(.medium))
                } else {
                    Text("本次未移入任何条目。")
                        .font(.callout.weight(.medium))
                }

                if !result.skippedProtectedItems.isEmpty {
                    Text("安全策略自动拦截 \(result.skippedProtectedItems.count) 项受保护目标：\(result.skippedProtectedItems.first?.reason ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !result.failedItems.isEmpty {
                    Text("有 \(result.failedItems.count) 项未能移入废纸篓：\(result.failedItems.first?.reason ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.dismissCleanupBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
    }
}
