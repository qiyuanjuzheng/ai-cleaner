import AICleanerCore
import SwiftUI

struct ItemListView: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerDashboard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            Divider()

            filterControlBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            listContent
        }
    }

    // MARK: - Visual Space Dashboard

    private var headerDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if let summary = viewModel.activeSummary {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.color(forAccentToken: summary.profile.accentToken).opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: summary.profile.symbolName)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(AppTheme.color(forAccentToken: summary.profile.accentToken))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(summary.profile.name)
                                .font(.title2.weight(.semibold))
                            Text("总占用 \(CleanerFormatting.formatBytes(summary.totalDiskFootprintBytes))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(summary.profile.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("全部 AI 客户端空间总览")
                                .font(.title2.weight(.semibold))
                            if let report = viewModel.report {
                                Text("已识别 \(report.detectedBuiltInClientsCount) 款客户端 · 总占用 \(CleanerFormatting.formatBytes(report.totalDiskFootprintBytes))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("已自动区分「建议清理」「按需清理」与「不建议清理（锁定保护）」，点击下方卡片可快速筛选。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if !viewModel.scopedRecommendedItems.isEmpty {
                    Button {
                        viewModel.selectRecommendedInScope()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("一键勾选建议清理 (\(CleanerFormatting.formatBytes(viewModel.scopedRecommendedBytes)))")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.color(for: .recommended))
                    .controlSize(.regular)
                    .help("自动勾选当前视图下所有标记为「建议清理」的条目，绝不勾选「按需清理」与「不建议清理」项")
                }
            }

            // 三档建议概览卡片（同时可点击筛选）
            HStack(spacing: 10) {
                RecommendationSummaryCard(
                    recommendation: .recommended,
                    sizeBytes: viewModel.scopedRecommendedBytes,
                    itemCount: viewModel.scopedRecommendedItems.count,
                    subtitle: "缓存、日志、临时与旧会话",
                    isSelected: viewModel.selectedRecommendation == .recommended
                ) {
                    viewModel.toggleRecommendationFilter(.recommended)
                }

                RecommendationSummaryCard(
                    recommendation: .reviewSuggested,
                    sizeBytes: viewModel.scopedReviewSuggestedBytes,
                    itemCount: viewModel.scopedReviewSuggestedItems.count,
                    subtitle: "近期聊天会话与任务目录",
                    isSelected: viewModel.selectedRecommendation == .reviewSuggested
                ) {
                    viewModel.toggleRecommendationFilter(.reviewSuggested)
                }

                RecommendationSummaryCard(
                    recommendation: .notRecommended,
                    sizeBytes: viewModel.scopedProtectedBytes,
                    itemCount: viewModel.scopedProtectedItems.count,
                    subtitle: "配置、插件、记忆与主库（已锁定）",
                    isSelected: viewModel.selectedRecommendation == .notRecommended
                ) {
                    viewModel.toggleRecommendationFilter(.notRecommended)
                }
            }

            // 类 macOS 系统存储风格的直观比例分布条
            if viewModel.scopedTotalFootprintBytes > 0 {
                StorageDistributionBar(
                    recommendedBytes: viewModel.scopedRecommendedBytes,
                    reviewBytes: viewModel.scopedReviewSuggestedBytes,
                    protectedBytes: viewModel.scopedProtectedBytes
                )
            }
        }
    }

    // MARK: - Filter & Selection Controls

    private var filterControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索会话摘要、项目名、路径、客户端或建议说明…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.8)
                )
                .frame(minWidth: 240, maxWidth: .infinity)

                Picker("时间范围", selection: $viewModel.selectedAgeFilter) {
                    ForEach(ItemAgeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
                .help("按最后修改时间筛选较早的一次性会话或临时文件")

                Picker("排序", selection: $viewModel.sortOrder) {
                    ForEach(ItemSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    categoryFilterButton(
                        title: "全部",
                        count: viewModel.scopedItems.count,
                        category: nil
                    )
                    ForEach(visibleCategories) { category in
                        categoryFilterButton(
                            title: category.displayName,
                            count: viewModel.categoryCounts[category] ?? 0,
                            category: category
                        )
                    }
                }

                Spacer(minLength: 8)

                if viewModel.hasActiveFilters {
                    Button("重置筛选") {
                        viewModel.clearAllFilters()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Text("可清 \(viewModel.filteredCleanableItems.count) 项（已选 \(viewModel.visibleSelectedCount)）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("全选可清") {
                    viewModel.selectAllVisible()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.filteredCleanableItems.isEmpty || viewModel.allVisibleSelected)

                Button("反选") {
                    viewModel.invertVisibleSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.filteredCleanableItems.isEmpty)

                Button("清空本页") {
                    viewModel.clearVisibleSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.visibleSelectedCount == 0)
            }
        }
    }

    private var visibleCategories: [ScanCategory] {
        let counts = viewModel.categoryCounts
        return ScanCategory.allCases.filter { category in
            if viewModel.selectedCategory == category { return true }
            if category == .sessions || category == .cache || category == .temporary || category == .logs {
                return true
            }
            return (counts[category] ?? 0) > 0
        }
    }

    private func categoryFilterButton(title: String, count: Int, category: ScanCategory?) -> some View {
        let isSelected = viewModel.selectedCategory == category
        let pillColor: Color = category.map { AppTheme.color(for: $0) } ?? .accentColor
        return Button {
            viewModel.selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .opacity(isSelected ? 0.92 : 0.72)
                }
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? pillColor.opacity(0.16) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? pillColor.opacity(0.55) : Color(nsColor: .separatorColor),
                        lineWidth: 0.8
                    )
            )
            .foregroundStyle(isSelected ? pillColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grouped List Body

    @ViewBuilder
    private var listContent: some View {
        if viewModel.isScanning && viewModel.report == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在以只读模式扫描本机 AI 客户端目录…")
                    .font(.headline)
                Text("支持 31 款国内外常见 AI 客户端，扫描过程绝不修改任何文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.displayedSections.isEmpty {
            if viewModel.hasActiveFilters {
                ContentUnavailableView {
                    Label("未找到匹配的条目", systemImage: "magnifyingglass")
                } description: {
                    Text("请调整搜索关键词、清理建议卡片、时间范围或分类筛选条件。")
                } actions: {
                    Button("清除筛选条件") {
                        viewModel.clearAllFilters()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("当前目录很干净", systemImage: "checkmark.circle")
                } description: {
                    Text("该分组下暂无可清理条目。你也可以点击「添加目录」扫描其他自定义路径。")
                } actions: {
                    Button("重新扫描") {
                        viewModel.rescan()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let maxBytes = max(1, viewModel.maxDisplayedItemBytes)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.displayedSections) { section in
                        let isCollapsed = viewModel.collapsedSections.contains(section.recommendation)
                        RecommendationSectionHeader(
                            section: section,
                            isCollapsed: isCollapsed,
                            onToggleCollapse: {
                                viewModel.toggleSectionCollapsed(section.recommendation)
                            },
                            onSelectSection: {
                                viewModel.selectSection(section.recommendation)
                            }
                        )

                        if !isCollapsed {
                            ForEach(section.items) { item in
                                ItemRowView(
                                    item: item,
                                    showClientBadge: viewModel.sidebarSelection == .allClients,
                                    relativeSizeFraction: Double(item.sizeBytes) / Double(maxBytes),
                                    isSelected: viewModel.isSelected(item),
                                    onToggle: { viewModel.toggleSelection(for: item) },
                                    onRevealInFinder: { viewModel.revealInFinder(item) },
                                    onCopyPath: { viewModel.copyPath(item) }
                                )
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Visual Dashboard Subcomponents

private struct RecommendationSummaryCard: View {
    let recommendation: CleanupRecommendation
    let sizeBytes: Int64
    let itemCount: Int
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let tint = AppTheme.color(for: recommendation)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: recommendation.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(recommendation.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(itemCount) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(CleanerFormatting.formatBytes(sizeBytes))
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(sizeBytes > 0 ? tint : .secondary)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint.opacity(0.85) : tint.opacity(0.22),
                        lineWidth: isSelected ? 1.5 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StorageDistributionBar: View {
    let recommendedBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64

    var body: some View {
        let total = max(1, recommendedBytes + reviewBytes + protectedBytes)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let recW = width * CGFloat(recommendedBytes) / CGFloat(total)
                let revW = width * CGFloat(reviewBytes) / CGFloat(total)
                let proW = width * CGFloat(protectedBytes) / CGFloat(total)

                HStack(spacing: 1.5) {
                    if recommendedBytes > 0 {
                        Rectangle()
                            .fill(AppTheme.color(for: .recommended))
                            .frame(width: max(3, recW))
                    }
                    if reviewBytes > 0 {
                        Rectangle()
                            .fill(AppTheme.color(for: .reviewSuggested))
                            .frame(width: max(3, revW))
                    }
                    if protectedBytes > 0 {
                        Rectangle()
                            .fill(AppTheme.color(for: .notRecommended).opacity(0.55))
                            .frame(width: max(3, proW))
                    }
                }
                .clipShape(Capsule())
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .frame(height: 8)

            HStack(spacing: 14) {
                legendDot(color: AppTheme.color(for: .recommended), text: "建议清理 \(percentage(recommendedBytes, of: total))")
                legendDot(color: AppTheme.color(for: .reviewSuggested), text: "按需清理 \(percentage(reviewBytes, of: total))")
                legendDot(color: AppTheme.color(for: .notRecommended).opacity(0.75), text: "不建议清理（已保护） \(percentage(protectedBytes, of: total))")
                Spacer()
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
        }
    }

    private func percentage(_ value: Int64, of total: Int64) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let pct = Double(value) * 100.0 / Double(total)
        if pct < 1 {
            return "<1%"
        }
        return "\(Int(pct.rounded()))%"
    }
}

private struct RecommendationSectionHeader: View {
    let section: CleanerViewModel.RecommendationSection
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onSelectSection: () -> Void

    var body: some View {
        let tint = AppTheme.color(for: section.recommendation)
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: section.recommendation.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)

                    Text(section.recommendation.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("· \(section.recommendation.shortGuidance)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text("\(section.items.count) 项 · \(CleanerFormatting.formatBytes(section.totalBytes))")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)

            if section.recommendation.isCleanable {
                Button("勾选本组") {
                    onSelectSection()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Text("已锁定保护")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.12)))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(tint.opacity(0.06))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
