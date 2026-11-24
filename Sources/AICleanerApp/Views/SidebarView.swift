import AICleanerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: CleanerViewModel
    @Namespace private var sidebarNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 极简品牌顶栏（固定高度，扫描态切换绝不引起侧边栏上下跳动）
            HStack(spacing: 9) {
                BrandLogoEmblem(isScanning: viewModel.isScanning)

                Text("AI Cleaner")
                    .font(.system(.headline, design: .rounded).weight(.bold))

                Spacer()

                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(viewModel.isScanning ? 1.0 : 0.0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader(title: "空间总览")

                    SidebarClientTile(
                        title: "全部 AI 客户端",
                        cleanableBytes: viewModel.report?.totalSizeBytes ?? 0,
                        protectedBytes: viewModel.report?.protectedSizeBytes ?? 0,
                        symbolName: "sparkles.rectangle.stack.fill",
                        tint: Color(red: 0.16, green: 0.80, blue: 0.60),
                        isSelected: viewModel.sidebarSelection == .allClients,
                        namespace: sidebarNamespace
                    ) {
                        select(.allClients)
                    }

                    SidebarClientTile(
                        title: "历史清理趋势",
                        cleanableBytes: viewModel.totalHistoricalFreedBytes,
                        protectedBytes: 0,
                        symbolName: "chart.line.uptrend.xyaxis",
                        tint: Color(red: 0.24, green: 0.72, blue: 0.98),
                        isSelected: viewModel.sidebarSelection == .history,
                        namespace: sidebarNamespace,
                        emphasizeBytesTint: viewModel.totalHistoricalFreedBytes > 0
                            ? AppTheme.color(for: .recommended)
                            : nil
                    ) {
                        select(.history)
                    }

                    sectionHeader(
                        title: "AI 客户端",
                        trailing: viewModel.report.map { "\($0.detectedBuiltInClientsCount)" } ?? (viewModel.isScanning ? "扫描中" : "待扫描")
                    )
                    .padding(.top, 14)

                    if viewModel.isIdleReadyToScan {
                        Text("点击「开始扫描」识别本机客户端")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else if viewModel.isScanning && viewModel.builtInSummaries.isEmpty {
                        Text("正在检索本机 AI 客户端…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else if viewModel.builtInSummaries.isEmpty {
                        Text("暂未检测到已安装的 AI 客户端")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(viewModel.builtInSummaries) { summary in
                            SidebarClientTile(
                                title: summary.profile.name,
                                cleanableBytes: summary.totalSizeBytes,
                                protectedBytes: summary.protectedSizeBytes,
                                symbolName: summary.profile.symbolName,
                                tint: AppTheme.color(forAccentToken: summary.profile.accentToken),
                                isSelected: viewModel.sidebarSelection == .client(summary.id),
                                namespace: sidebarNamespace
                            ) {
                                select(.client(summary.id))
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Text("自定义目录")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if !viewModel.customDirectories.isEmpty {
                            Button {
                                viewModel.showingAddCustomSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("添加自定义扫描目录 (⌘⇧A)")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .padding(.top, 14)

                    if viewModel.customDirectories.isEmpty {
                        Button {
                            viewModel.showingAddCustomSheet = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 20)
                                Text("添加目录…")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if viewModel.customSummaries.isEmpty {
                        ForEach(viewModel.customDirectories) { dir in
                            HStack(spacing: 2) {
                                HStack(spacing: 9) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(Color.teal.opacity(0.82))
                                        .frame(width: 20, alignment: .center)
                                    Text(dir.displayName)
                                        .font(.callout)
                                        .foregroundStyle(Color.primary.opacity(0.85))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("待扫描")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.leading, 11)
                                .padding(.trailing, 6)
                                .frame(height: 34)

                                Button {
                                    viewModel.removeCustomDirectory(id: dir.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .help("从扫描列表中移除（不删除磁盘文件）")
                            }
                        }
                    } else {
                        ForEach(viewModel.customSummaries) { summary in
                            HStack(spacing: 2) {
                                SidebarClientTile(
                                    title: summary.profile.name,
                                    cleanableBytes: summary.totalSizeBytes,
                                    protectedBytes: 0,
                                    symbolName: summary.profile.symbolName,
                                    tint: .teal,
                                    isSelected: viewModel.sidebarSelection == .client(summary.id),
                                    namespace: sidebarNamespace
                                ) {
                                    select(.client(summary.id))
                                }

                                if let customID = summary.profile.customDirectoryID {
                                    Button {
                                        viewModel.removeCustomDirectory(id: customID)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 20, height: 20)
                                    }
                                    .buttonStyle(.plain)
                                    .help("从扫描列表中移除（不删除磁盘文件）")
                                }
                            }
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84), value: viewModel.sidebarSelection)
            }

            // 极简底部安全状态行（固定高度）
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.color(for: .recommended))
                if let scannedAt = viewModel.report?.scannedAt {
                    Text("只读扫描 \(CleanerFormatting.formatTime(scannedAt))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if viewModel.isScanning {
                    Text("正在只读扫描本机目录…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("待扫描 · 仅执行只读检索")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
    }

    private func select(_ selection: SidebarSelection) {
        // 仅由侧边栏局部动画驱动荧光指示条滑行，不对主内容区施加全局弹簧 diff 动画，确保切换瞬时顺滑
        viewModel.sidebarSelection = selection
    }

    private func sectionHeader(title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
    }
}

private struct SidebarClientTile: View {
    let title: String
    let cleanableBytes: Int64
    let protectedBytes: Int64
    let symbolName: String
    let tint: Color
    let isSelected: Bool
    let namespace: Namespace.ID
    var emphasizeBytesTint: Color? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? tint : tint.opacity(0.82))
                    .frame(width: 20, alignment: .center)

                Text(title)
                    .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if cleanableBytes > 0 {
                    Text(CleanerFormatting.formatBytes(cleanableBytes))
                        .font(.caption.monospacedDigit().weight(isSelected || emphasizeBytesTint != nil ? .semibold : .regular))
                        .foregroundStyle(emphasizeBytesTint ?? (isSelected ? Color.primary : Color.secondary))
                        .contentTransition(.numericText())
                } else if protectedBytes > 0 {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.quaternary)
                        .help("仅含受保护资产")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .frame(height: 34)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(tileBackground)

                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(tint)
                            .frame(width: 3, height: 16)
                            .shadow(color: tint.opacity(0.75), radius: 4)
                            .padding(.leading, 2.5)
                            .matchedGeometryEffect(id: "sidebarActiveBar", in: namespace)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        }
        .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.985))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var tileBackground: Color {
        if isSelected {
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
        }
        if isHovered {
            return Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04)
        }
        return Color.clear
    }
}
