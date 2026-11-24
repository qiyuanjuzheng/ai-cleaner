import AICleanerCore
import SwiftUI

struct ItemListView: View {
    @Bindable var viewModel: CleanerViewModel
    @Namespace private var categoryNamespace
    @Namespace private var tierNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.isScanning && viewModel.report == nil {
            OrbitalScannerHero()
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            VStack(spacing: 0) {
                heroDashboardCard
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                singleControlBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                listContent
            }
        }
    }

    // MARK: - 1. 紧凑高级单焦点空间仪表头

    private var heroDashboardCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                // 标志性多段发光空间环
                StorageRingGauge(
                    recommendedBytes: viewModel.scopedRecommendedBytes,
                    reviewBytes: viewModel.scopedReviewSuggestedBytes,
                    protectedBytes: viewModel.scopedProtectedBytes,
                    highlightedTier: viewModel.highlightedRingTier,
                    isScanning: viewModel.isScanning
                )

                VStack(alignment: .leading, spacing: 11) {
                    // 标题行 + 唯一主行动按钮（锁定固定高度，切换有无建议项的客户端绝不上下抖动）
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.activeSummary?.profile.name ?? "全部 AI 客户端")
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .lineLimit(1)

                            Text(headerSubtitle)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if !viewModel.scopedRecommendedItems.isEmpty {
                            Button {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                                    viewModel.selectRecommendedInScope()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                    Text("一键勾选建议清理 · \(CleanerFormatting.formatBytes(viewModel.scopedRecommendedBytes))")
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(
                                GlowingPillButtonStyle(
                                    gradient: AppTheme.gradient(for: .recommended),
                                    glowColor: AppTheme.color(for: .recommended),
                                    isEnabled: !viewModel.isCleaning && !viewModel.isScanning,
                                    compact: true
                                )
                            )
                            .layoutPriority(1)
                            .disabled(viewModel.isCleaning || viewModel.isScanning)
                            .help("自动勾选当前视图中所有「建议清理」项，绝不勾选「按需清理」或「不建议清理」项")
                        }
                    }
                    .frame(height: 44)

                    // 统一三档交互式指标条（固定高度，悬停/点击零跳动）
                    HStack(spacing: 4) {
                        tierMetricSegment(
                            tier: .recommended,
                            bytes: viewModel.scopedRecommendedBytes,
                            count: viewModel.scopedRecommendedItems.count
                        )
                        tierMetricSegment(
                            tier: .reviewSuggested,
                            bytes: viewModel.scopedReviewSuggestedBytes,
                            count: viewModel.scopedReviewSuggestedItems.count
                        )
                        tierMetricSegment(
                            tier: .notRecommended,
                            bytes: viewModel.scopedProtectedBytes,
                            count: viewModel.scopedProtectedItems.count
                        )
                    }
                    .padding(3)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035))
                    )
                }
            }

            // 始终占位渲染的 3.5pt 极细比例条（切换空目录或零空间客户端时卡片高度 100% 恒定）
            HairlineStorageBar(
                recommendedBytes: viewModel.scopedRecommendedBytes,
                reviewBytes: viewModel.scopedReviewSuggestedBytes,
                protectedBytes: viewModel.scopedProtectedBytes,
                highlightedTier: viewModel.highlightedRingTier
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AppTheme.glassCardFill(for: colorScheme))
                )
        )
        .overlay(alignment: .top) {
            if viewModel.isScanning {
                AuroraScanSweepBar()
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 12, y: 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: viewModel.isScanning)
    }

    private var headerSubtitle: String {
        if let summary = viewModel.activeSummary {
            return "\(summary.profile.description) · 总占用 \(CleanerFormatting.formatBytes(summary.totalDiskFootprintBytes))"
        }
        if let report = viewModel.report {
            return "已识别 \(report.detectedBuiltInClientsCount) 款 AI 客户端 · 总占用 \(CleanerFormatting.formatBytes(report.totalDiskFootprintBytes))"
        }
        return "只读扫描本机 AI 客户端空间占用"
    }

    private func tierMetricSegment(tier: CleanupRecommendation, bytes: Int64, count: Int) -> some View {
        let isSelected = viewModel.selectedRecommendation == tier
        let isHovered = viewModel.hoveredRecommendation == tier
        let tint = AppTheme.color(for: tier)

        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.80)) {
                viewModel.toggleRecommendationFilter(tier)
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: (isSelected || isHovered) ? tint.opacity(0.8) : .clear, radius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(tier.displayName)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        Text("\(count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(bytes <= 0 ? "0 B" : CleanerFormatting.formatBytes(bytes))
                        .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(bytes > 0 ? (isSelected || isHovered ? tint : Color.primary) : Color.secondary.opacity(0.55))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(0.38), lineWidth: 0.8)
                        )
                        .matchedGeometryEffect(id: "activeTierHighlight", in: tierNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                if hovering {
                    viewModel.hoveredRecommendation = tier
                } else if viewModel.hoveredRecommendation == tier {
                    viewModel.hoveredRecommendation = nil
                }
            }
        }
    }

    // MARK: - 2. 单行极简筛选与搜索栏

    private var singleControlBar: some View {
        HStack(spacing: 10) {
            // 紧凑自适应宽度的滑动胶囊分类切换（不再拉伸留白）
            HStack(spacing: 2) {
                categoryFilterButton(title: "全部", category: nil)
                ForEach(visibleCategories) { category in
                    categoryFilterButton(title: shortCategoryTitle(category), category: category)
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.045))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.65)
            )
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            if viewModel.hasActiveFilters {
                Button("重置") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                        viewModel.clearAllFilters()
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // 紧凑透明搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("搜索会话、项目或路径…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
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

            // 折叠收纳的「排序 / 时间筛选 / 批量勾选」高级菜单（平时保持界面极简）
            Menu {
                Section("时间范围") {
                    ForEach(ItemAgeFilter.allCases) { filter in
                        Button {
                            viewModel.selectedAgeFilter = filter
                        } label: {
                            if viewModel.selectedAgeFilter == filter {
                                Label(filter.rawValue, systemImage: "checkmark")
                            } else {
                                Text(filter.rawValue)
                            }
                        }
                    }
                }

                Section("排序方式") {
                    ForEach(ItemSortOrder.allCases) { order in
                        Button {
                            viewModel.sortOrder = order
                        } label: {
                            if viewModel.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                }

                Divider()

                Section("当前列表批量操作") {
                    Button("全选当前可清理项（\(viewModel.filteredCleanableItems.count)）") {
                        viewModel.selectAllVisible()
                    }
                    .disabled(viewModel.filteredCleanableItems.isEmpty || viewModel.allVisibleSelected)

                    Button("反选当前可清理项") {
                        viewModel.invertVisibleSelection()
                    }
                    .disabled(viewModel.filteredCleanableItems.isEmpty)

                    Button("清空本页选择") {
                        viewModel.clearVisibleSelection()
                    }
                    .disabled(viewModel.visibleSelectedCount == 0)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(AppTheme.glassCardFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
            )
            .overlay(alignment: .topTrailing) {
                if viewModel.selectedAgeFilter != .all || viewModel.sortOrder != .sizeDescending {
                    Circle()
                        .fill(AppTheme.color(for: .recommended))
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 3)
                }
            }
            .fixedSize()
            .help("时间范围、排序与批量勾选")
        }
        .frame(height: 32)
    }

    private func shortCategoryTitle(_ category: ScanCategory) -> String {
        switch category {
        case .sessions: return "会话"
        case .cache: return "缓存"
        case .temporary: return "临时"
        case .logs: return "日志"
        case .custom: return "自定义"
        case .protectedData: return "受保护"
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

    private func categoryFilterButton(title: String, category: ScanCategory?) -> some View {
        let isSelected = viewModel.selectedCategory == category

        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.80)) {
                viewModel.selectedCategory = category
            }
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "activeCategoryPill", in: categoryNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 统一磨砂分组容器列表（告别满屏散乱方框）

    @ViewBuilder
    private var listContent: some View {
        if viewModel.displayedSections.isEmpty {
            if viewModel.hasActiveFilters {
                ContentUnavailableView {
                    Label("未找到匹配的条目", systemImage: "magnifyingglass")
                } description: {
                    Text("可调整搜索词、建议档位或分类筛选条件。")
                } actions: {
                    Button("重置筛选") {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            viewModel.clearAllFilters()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("当前目录很干净", systemImage: "checkmark.seal.fill")
                } description: {
                    Text("该分组下暂无可清理条目。")
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.displayedSections) { section in
                        let isCollapsed = viewModel.isSectionCollapsed(section.recommendation)

                        VStack(alignment: .leading, spacing: 6) {
                            CleanSectionHeader(
                                section: section,
                                isCollapsed: isCollapsed,
                                onToggleCollapse: {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                                        viewModel.toggleSectionCollapsed(section.recommendation)
                                    }
                                },
                                onSelectSection: {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                        viewModel.selectSection(section.recommendation)
                                    }
                                }
                            )

                            if !isCollapsed {
                                // 同一分组所有行收敛在一张通透圆角玻璃卡片内，用极淡发丝线分隔
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                        ItemRowView(
                                            item: item,
                                            showClientBadge: viewModel.sidebarSelection == .allClients,
                                            relativeSizeFraction: Double(item.sizeBytes) / Double(maxBytes),
                                            isSelected: viewModel.isSelected(item),
                                            onToggle: { viewModel.toggleSelection(for: item) },
                                            onRevealInFinder: { viewModel.revealInFinder(item) },
                                            onCopyPath: { viewModel.copyPath(item) }
                                        )

                                        if index < section.items.count - 1 {
                                            Rectangle()
                                                .fill(AppTheme.hairlineDivider(for: colorScheme))
                                                .frame(height: 0.5)
                                                .padding(.leading, 56)
                                                .padding(.trailing, 14)
                                        }
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(AppTheme.glassCardFill(for: colorScheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.75)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 88)
            }
        }
    }
}

// MARK: - Hairline Proportional Bar (零溢出 + 悬停联动)

private struct HairlineStorageBar: View {
    let recommendedBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64
    let highlightedTier: CleanupRecommendation?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct BarMetrics: Equatable {
        let recommended: Int64
        let review: Int64
        let protected: Int64
    }

    var body: some View {
        let metrics = BarMetrics(recommended: recommendedBytes, review: reviewBytes, protected: protectedBytes)
        let segments: [(CleanupRecommendation, Int64)] = [
            (.recommended, recommendedBytes),
            (.reviewSuggested, reviewBytes),
            (.notRecommended, protectedBytes)
        ].filter { $0.1 > 0 }

        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let gapTotal = CGFloat(max(0, segments.count - 1)) * spacing
            let usableWidth = max(0, proxy.size.width - gapTotal)
            let widths = proportionalWidths(for: segments.map(\.1), usableWidth: usableWidth)

            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.element.0) { idx, segment in
                    let tier = segment.0
                    let isHighlighted = highlightedTier == tier
                    let opacity = highlightedTier == nil ? 0.90 : (isHighlighted ? 1.0 : 0.25)

                    Capsule()
                        .fill(segmentFill(for: tier))
                        .frame(width: widths[idx])
                        .shadow(
                            color: isHighlighted ? AppTheme.color(for: tier).opacity(0.65) : .clear,
                            radius: isHighlighted ? 5 : 0
                        )
                        .opacity(opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.84), value: metrics)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: highlightedTier)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .frame(height: 3.5)
    }

    private func proportionalWidths(for values: [Int64], usableWidth: CGFloat) -> [CGFloat] {
        guard !values.isEmpty, usableWidth > 0 else { return [] }
        let total = Double(values.reduce(0, +))
        guard total > 0 else { return Array(repeating: 0, count: values.count) }

        let minSegWidth: CGFloat = min(5, usableWidth / CGFloat(values.count))
        var raw = values.map { max(minSegWidth, usableWidth * CGFloat(Double($0) / total)) }
        let sum = raw.reduce(0, +)
        if sum > usableWidth {
            let scale = usableWidth / sum
            raw = raw.map { $0 * scale }
        }
        return raw
    }

    private func segmentFill(for tier: CleanupRecommendation) -> AnyShapeStyle {
        switch tier {
        case .recommended:
            return AnyShapeStyle(AppTheme.gradient(for: .recommended))
        case .reviewSuggested:
            return AnyShapeStyle(AppTheme.gradient(for: .reviewSuggested))
        case .notRecommended:
            return AnyShapeStyle(AppTheme.color(for: .notRecommended).opacity(0.55))
        }
    }
}

// MARK: - 无框极简分组标题

private struct CleanSectionHeader: View {
    let section: CleanerViewModel.RecommendationSection
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onSelectSection: () -> Void

    var body: some View {
        let tint = AppTheme.color(for: section.recommendation)

        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 11)

                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)

                    Text(section.recommendation.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("\(section.items.count) 项 · \(CleanerFormatting.formatBytes(section.totalBytes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if section.recommendation.isCleanable {
                Button("勾选本组") {
                    onSelectSection()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.11)))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 9.5))
                    Text("默认不选 · 手动勾选需二次确认")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }
}
