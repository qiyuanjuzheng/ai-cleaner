import AICleanerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.sidebarSelection) {
                Section("总览") {
                    SidebarSummaryRow(
                        title: "全部 AI 客户端",
                        subtitle: allOverviewSubtitle,
                        cleanableBytes: viewModel.report?.totalSizeBytes ?? 0,
                        protectedBytes: viewModel.report?.protectedSizeBytes ?? 0,
                        hasRecommended: (viewModel.report?.totalRecommendedCount ?? 0) > 0,
                        symbolName: "tray.full.fill",
                        tint: .accentColor
                    )
                    .tag(SidebarSelection.allClients)
                }

                Section {
                    if viewModel.builtInSummaries.isEmpty && !viewModel.isScanning {
                        Text("本机暂未检测到已安装的 AI 客户端目录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(viewModel.builtInSummaries) { summary in
                            SidebarSummaryRow(
                                title: summary.profile.name,
                                subtitle: subtitleText(for: summary),
                                cleanableBytes: summary.totalSizeBytes,
                                protectedBytes: summary.protectedSizeBytes,
                                hasRecommended: !summary.recommendedItems.isEmpty,
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
                            Text("已识别 \(report.detectedBuiltInClientsCount)/\(report.totalBuiltInProfilesCount)")
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
                                    cleanableBytes: summary.totalSizeBytes,
                                    protectedBytes: 0,
                                    hasRecommended: false,
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
                        Text("只读扫描 · \(CleanerFormatting.formatTime(scannedAt)) · 仅入废纸篓")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("只读扫描 · 仅移入系统废纸篓")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }

    private var allOverviewSubtitle: String {
        guard let report = viewModel.report else { return "等待扫描" }
        var parts: [String] = []
        if report.totalRecommendedCount > 0 {
            parts.append("建议清 \(CleanerFormatting.formatBytes(report.recommendedSizeBytes))")
        }
        if viewModel.totalSessionCount > 0 {
            parts.append("\(viewModel.totalSessionCount) 条会话")
        }
        if parts.isEmpty {
            return "\(report.totalItemCount) 项可清"
        }
        return parts.joined(separator: " · ")
    }

    private func subtitleText(for summary: ClientScanSummary) -> String {
        if summary.itemCount == 0 && summary.protectedItemCount > 0 {
            return "已保护 \(CleanerFormatting.formatBytes(summary.protectedSizeBytes))"
        }
        let sessions = viewModel.sessionCount(for: summary)
        if summary.recommendedSizeBytes > 0 && sessions > 0 {
            return "建议清 \(CleanerFormatting.formatBytes(summary.recommendedSizeBytes)) · \(sessions) 会话"
        }
        if summary.recommendedSizeBytes > 0 {
            return "建议清 \(CleanerFormatting.formatBytes(summary.recommendedSizeBytes))"
        }
        if sessions > 0 {
            return "\(sessions) 条会话"
        }
        return "\(summary.itemCount) 项"
    }
}

private struct SidebarSummaryRow: View {
    let title: String
    let subtitle: String
    let cleanableBytes: Int64
    let protectedBytes: Int64
    let hasRecommended: Bool
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
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                    if hasRecommended {
                        Circle()
                            .fill(AppTheme.color(for: .recommended))
                            .frame(width: 6, height: 6)
                            .help("包含建议清理项")
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if cleanableBytes > 0 {
                Text(CleanerFormatting.formatBytes(cleanableBytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            } else if protectedBytes > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("受保护")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            } else {
                Text("0 KB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
