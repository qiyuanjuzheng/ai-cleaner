import AICleanerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: CleanerViewModel
    @Namespace private var sidebarNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 极简品牌顶栏（固定 48pt 高度，扫描态切换绝不引起侧边栏上下跳动）
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
                    sectionHeader(title: "总览")

                    SidebarClientTile(
                        title: "空间总览",
                        cleanableBytesText: viewModel.reportTotalBytesText,
                        hasProtectedOnly: (viewModel.report?.totalSizeBytes ?? 0) == 0 && (viewModel.report?.protectedSizeBytes ?? 0) > 0,
                        icon: .symbol("sparkles.rectangle.stack.fill"),
                        tint: Color(red: 0.16, green: 0.80, blue: 0.60),
                        isSelected: viewModel.sidebarSelection == .allClients,
                        namespace: sidebarNamespace
                    ) {
                        select(.allClients)
                    }

                    SidebarClientTile(
                        title: CleanupHistoryCopy.title,
                        cleanableBytesText: viewModel.totalHistoricalFreedBytesText,
                        hasProtectedOnly: false,
                        icon: .symbol("chart.line.uptrend.xyaxis"),
                        tint: Color(red: 0.24, green: 0.72, blue: 0.98),
                        isSelected: viewModel.sidebarSelection == .history,
                        namespace: sidebarNamespace,
                        emphasizeBytesTint: viewModel.totalHistoricalFreedBytes > 0
                            ? AppTheme.color(for: .recommended)
                            : nil
                    ) {
                        select(.history)
                    }
                    .help("累计已移入废纸篓 \(CleanerFormatting.formatBytes(viewModel.totalHistoricalFreedBytes))")

                    SidebarClientTile(
                        title: "已排除",
                        cleanableBytesText: viewModel.excludedItemCountText,
                        hasProtectedOnly: false,
                        icon: .symbol("eye.slash.fill"),
                        tint: AppTheme.excludedAccentColor,
                        isSelected: viewModel.sidebarSelection == .excluded,
                        namespace: sidebarNamespace,
                        emphasizeBytesTint: viewModel.excludedItems.isEmpty
                            ? nil
                            : AppTheme.excludedAccentColor
                    ) {
                        select(.excluded)
                    }
                    .help(
                        viewModel.excludedItems.isEmpty
                            ? "查看已排除的清理条目"
                            : "已排除 \(viewModel.excludedItems.count) 项，扫描时将自动跳过"
                    )

                    sectionHeader(
                        title: "AI 客户端",
                        trailing: viewModel.isScanning
                            ? "扫描中"
                            : viewModel.report.map { "\($0.detectedBuiltInClientsCount)" } ?? "待扫描"
                    )
                    .padding(.top, 14)

                    if viewModel.hasScanResults && !viewModel.isScanning && viewModel.builtInSidebarEntries.isEmpty {
                        Text("未检测到 AI 客户端")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(viewModel.builtInSidebarEntries) { entry in
                            SidebarClientTile(
                                title: entry.title,
                                cleanableBytesText: entry.cleanableBytesText,
                                hasProtectedOnly: entry.cleanableBytes == 0 && entry.protectedBytes > 0,
                                icon: .client(entry.id),
                                tint: AppTheme.color(forAccentToken: entry.accentToken),
                                isSelected: viewModel.sidebarSelection == .client(entry.id),
                                namespace: sidebarNamespace
                            ) {
                                select(.client(entry.id))
                            }
                        }
                    }

                    if !viewModel.tempSidebarEntries.isEmpty {
                        sectionHeader(
                            title: "系统临时目录",
                            trailing: "\(viewModel.tempSidebarEntries.count)"
                        )
                        .padding(.top, 14)

                        ForEach(viewModel.tempSidebarEntries) { entry in
                            SidebarClientTile(
                                title: entry.title,
                                cleanableBytesText: entry.cleanableBytesText,
                                hasProtectedOnly: false,
                                icon: .symbol(entry.symbolName),
                                tint: AppTheme.color(forAccentToken: entry.accentToken),
                                isSelected: viewModel.sidebarSelection == .client(entry.id),
                                namespace: sidebarNamespace
                            ) {
                                select(.client(entry.id))
                            }
                            .help(
                                entry.profileKind == .unattributedTemp
                                    ? "位于 /tmp 且无法自动确认来源的当前用户条目，仅支持逐条手动勾选"
                                    : "位于系统临时目录的其他 AI 工具与 Agent 临时文件"
                            )
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
                            .help("添加自定义目录 (⌘⇧A)")
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
                    } else if viewModel.customSidebarEntries.isEmpty {
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
                                .help("从扫描列表移除目录（保留文件）")
                            }
                        }
                    } else {
                        ForEach(viewModel.customSidebarEntries) { entry in
                            HStack(spacing: 2) {
                                SidebarClientTile(
                                    title: entry.title,
                                    cleanableBytesText: entry.cleanableBytesText,
                                    hasProtectedOnly: false,
                                    icon: .symbol("folder.badge.plus"),
                                    tint: .teal,
                                    isSelected: viewModel.sidebarSelection == .client(entry.id),
                                    namespace: sidebarNamespace
                                ) {
                                    select(.client(entry.id))
                                }

                                if let customID = entry.customDirectoryID {
                                    Button {
                                        viewModel.removeCustomDirectory(id: customID)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 20, height: 20)
                                    }
                                    .buttonStyle(.plain)
                                    .help("从扫描列表移除目录（保留文件）")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: viewModel.sidebarSelection)
            }

            // 固定底栏高度，扫描结果切换时保持侧边栏布局稳定。
            HStack(spacing: 6) {
                if !viewModel.reportScannedTimeText.isEmpty {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("上次扫描 \(viewModel.reportScannedTimeText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func select(_ selection: SidebarSelection) {
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

private enum SidebarTileIcon {
    case symbol(String)
    case client(String)
}

private struct SidebarClientTile: View {
    let title: String
    let cleanableBytesText: String
    let hasProtectedOnly: Bool
    let icon: SidebarTileIcon
    let tint: Color
    let isSelected: Bool
    let namespace: Namespace.ID
    var emphasizeBytesTint: Color? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                switch icon {
                case let .symbol(name):
                    Image(systemName: name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isSelected ? tint : tint.opacity(0.82))
                        .frame(width: 20, height: 20, alignment: .center)
                case let .client(id):
                    ClientLogo(clientID: id)
                }

                Text(title)
                    .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !cleanableBytesText.isEmpty {
                    Text(cleanableBytesText)
                        .font(.caption.monospacedDigit().weight(isSelected || emphasizeBytesTint != nil ? .semibold : .regular))
                        .foregroundStyle(emphasizeBytesTint ?? (isSelected ? Color.primary : Color.secondary))
                } else if hasProtectedOnly {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.quaternary)
                        .help("仅有不建议清理的条目")
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
                            .padding(.leading, 2.5)
                            .matchedGeometryEffect(id: "sidebarActiveBar", in: namespace)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
