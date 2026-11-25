import AICleanerCore
import SwiftUI

struct ExcludedItemsView: View {
    @Bindable var viewModel: CleanerViewModel
    @State private var searchText: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredRows: [ExcludedItemDisplayRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.excludedItemRows }
        return viewModel.excludedItemRows.filter { row in
            let record = row.record
            return record.displayName.lowercased().contains(query)
                || record.clientName.lowercased().contains(query)
                || record.category.displayName.lowercased().contains(query)
                || record.normalizedPath.lowercased().contains(query)
                || (record.sessionProjectName?.lowercased().contains(query) ?? false)
        }
    }

    private var subtitleText: String {
        let total = viewModel.excludedItemRows.count
        guard total > 0 else {
            return "右键任意扫描条目即可将其排除，后续扫描将自动跳过"
        }
        if viewModel.missingExcludedItemCount > 0 {
            return "共 \(total) 项在扫描时自动跳过 · \(viewModel.missingExcludedItemCount) 项路径已不存在"
        }
        return "共 \(total) 项在扫描时自动跳过"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if viewModel.excludedItemRows.isEmpty {
                emptyStateCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRows.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的已排除条目", systemImage: "magnifyingglass")
                } description: {
                    Text("调整搜索关键词后重试。")
                } actions: {
                    Button("清空搜索") {
                        searchText = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredRows.enumerated()), id: \.element.id) { index, row in
                            ExcludedItemRowView(
                                row: row,
                                showBottomDivider: index < filteredRows.count - 1,
                                onRestore: {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                        viewModel.restoreExcludedItem(row.record)
                                    }
                                },
                                onRevealInFinder: {
                                    viewModel.revealExcludedItemInFinder(row.record)
                                },
                                onCopyPath: {
                                    viewModel.copyExcludedItemPath(row.record)
                                }
                            )
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(AppTheme.glassCardFill(for: colorScheme))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04), radius: 10, y: 3)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            viewModel.refreshExcludedItemStatuses()
        }
    }

    // MARK: - 1. 顶栏标题、搜索框与全部恢复

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已排除")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text(subtitleText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !viewModel.excludedItemRows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("搜索已排除条目或路径…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 215, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(AppTheme.glassCardFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
                )
            }

            if viewModel.excludedItemRows.count > 1 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                        viewModel.restoreAllExcludedItems()
                        searchText = ""
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text("全部恢复")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.excludedAccentColor)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.excludedAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.11))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AppTheme.excludedAccentColor.opacity(0.32), lineWidth: 0.75)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
                .help("将全部已排除条目恢复回待清理列表")
            }
        }
        .frame(minHeight: 40)
    }

    // MARK: - 2. 空状态引导卡片

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.excludedAccentColor.opacity(colorScheme == .dark ? 0.18 : 0.13))
                    .frame(width: 52, height: 52)
                Image(systemName: "eye.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.excludedAccentColor)
            }

            Text("暂无已排除条目")
                .font(.headline)

            Text("在待清理列表中右键点击任意条目并选择「排除此条目（不再显示）」，即可将其从扫描结果与统计中隐藏。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                viewModel.sidebarSelection = .allClients
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text(viewModel.hasScanResults ? "查看扫描结果" : "返回扫描")
                }
            }
            .buttonStyle(
                GlowingPillButtonStyle(
                    gradient: AppTheme.gradient(for: .recommended),
                    glowColor: AppTheme.color(for: .recommended),
                    compact: true
                )
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.glassHeroCardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04), radius: 10, y: 3)
    }
}

// MARK: - 单条已排除条目行

private struct ExcludedItemRowView: View {
    let row: ExcludedItemDisplayRow
    let showBottomDivider: Bool
    let onRestore: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let record = row.record
        let categoryColor = AppTheme.color(for: record.category)
        let missingTint = Color(red: 0.90, green: 0.56, blue: 0.22)

        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(categoryColor.opacity(colorScheme == .dark ? 0.15 : 0.11))
                    .frame(width: 30, height: 30)
                Image(systemName: leadingSymbolName)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(row.existsOnDisk ? categoryColor : categoryColor.opacity(0.55))
            }

            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 6) {
                    Text(record.displayName)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(row.existsOnDisk ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(record.clientName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(record.category.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(categoryColor)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(categoryColor.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if !row.existsOnDisk {
                        HStack(spacing: 3) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("路径已不存在")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(missingTint)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(missingTint.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Text(record.normalizedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.normalizedPath)
            }

            Spacer(minLength: 10)

            Text("排除于 \(row.excludedAtText)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                Group {
                    if row.existsOnDisk {
                        Button(action: onRevealInFinder) {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .fill(Color.primary.opacity(isHovered ? (colorScheme == .dark ? 0.10 : 0.075) : (colorScheme == .dark ? 0.055 : 0.04)))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("在 Finder 中显示")
                        .help("在 Finder 中显示：\(record.normalizedPath)")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 28, height: 26)

                Button(action: onRestore) {
                    HStack(spacing: 4) {
                        Image(systemName: row.existsOnDisk ? "arrow.uturn.backward" : "xmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text(row.existsOnDisk ? "恢复" : "移除")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(row.existsOnDisk ? AppTheme.excludedAccentColor : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                row.existsOnDisk
                                    ? AppTheme.excludedAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.11)
                                    : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                row.existsOnDisk
                                    ? AppTheme.excludedAccentColor.opacity(0.30)
                                    : Color.primary.opacity(0.10),
                                lineWidth: 0.7
                            )
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.96))
                .help(row.existsOnDisk ? "恢复该条目并重新显示在待清理列表中" : "路径已不存在，从排除清单中移除记录")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.028) : Color.clear)
        .overlay(alignment: .bottom) {
            if showBottomDivider {
                Rectangle()
                    .fill(AppTheme.hairlineDivider(for: colorScheme))
                    .frame(height: 0.5)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: onRestore) {
                Label(
                    row.existsOnDisk ? "恢复到待清理列表" : "从排除清单移除",
                    systemImage: row.existsOnDisk ? "arrow.uturn.backward" : "trash"
                )
            }

            Divider()

            if row.existsOnDisk {
                Button(action: onRevealInFinder) {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
            }

            Button(action: onCopyPath) {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
        }
    }

    private var leadingSymbolName: String {
        switch row.record.category {
        case .sessions:
            return row.record.isDirectory ? "bubble.left.and.bubble.right" : "text.bubble"
        case .cache:
            return "internaldrive"
        case .temporary:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text"
        case .custom:
            return row.record.isDirectory ? "folder" : "doc"
        case .protectedData:
            return "lock.shield"
        }
    }
}
