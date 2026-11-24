import AICleanerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.sidebarSelection) {
                Section("总览") {
                    SidebarSummaryRow(
                        title: "全部可清理项",
                        subtitle: "\(viewModel.report?.totalItemCount ?? 0) 项",
                        sizeBytes: viewModel.report?.totalSizeBytes ?? 0,
                        symbolName: "tray.full.fill",
                        tint: .accentColor
                    )
                    .tag(SidebarSelection.allClients)
                }

                Section {
                    if viewModel.builtInSummaries.isEmpty && !viewModel.isScanning {
                        Text("本机暂未检测到可清理的 AI 客户端缓存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(viewModel.builtInSummaries) { summary in
                            SidebarSummaryRow(
                                title: summary.profile.name,
                                subtitle: "\(summary.itemCount) 项",
                                sizeBytes: summary.totalSizeBytes,
                                symbolName: summary.profile.symbolName,
                                tint: AppTheme.color(forAccentToken: summary.profile.accentToken)
                            )
                            .tag(SidebarSelection.client(summary.id))
                        }
                    }
                } header: {
                    HStack {
                        Text("AI 客户端")
                        Spacer()
                        if let report = viewModel.report {
                            Text("\(report.detectedBuiltInClientsCount)/\(report.totalBuiltInProfilesCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("自定义目录") {
                    if viewModel.customSummaries.isEmpty {
                        Text("可添加自定义临时或缓存文件夹")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(viewModel.customSummaries) { summary in
                            HStack(spacing: 6) {
                                SidebarSummaryRow(
                                    title: summary.profile.name,
                                    subtitle: "\(summary.itemCount) 项",
                                    sizeBytes: summary.totalSizeBytes,
                                    symbolName: summary.profile.symbolName,
                                    tint: .teal
                                )

                                if let customID = summary.profile.customDirectoryID {
                                    Button {
                                        viewModel.removeCustomDirectory(id: customID)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("从扫描列表中移除该目录（不删除磁盘文件）")
                                }
                            }
                            .tag(SidebarSelection.client(summary.id))
                            .contextMenu {
                                if let customID = summary.profile.customDirectoryID {
                                    Button("从列表移除（不删磁盘文件）", role: .destructive) {
                                        viewModel.removeCustomDirectory(id: customID)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.rescan()
                    } label: {
                        HStack(spacing: 5) {
                            if viewModel.isScanning {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(viewModel.isScanning ? "扫描中…" : "重新扫描")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .disabled(viewModel.isScanning || viewModel.isCleaning)

                    Button {
                        viewModel.showingAddCustomSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                            Text("添加目录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if let scannedAt = viewModel.report?.scannedAt {
                        Text("只读扫描 · \(CleanerFormatting.formatTime(scannedAt))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("只读扫描 · 仅移入废纸篓")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }
}

private struct SidebarSummaryRow: View {
    let title: String
    let subtitle: String
    let sizeBytes: Int64
    let symbolName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(CleanerFormatting.formatBytes(sizeBytes))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(sizeBytes > 0 ? .primary : .tertiary)
        }
        .padding(.vertical, 2)
    }
}
