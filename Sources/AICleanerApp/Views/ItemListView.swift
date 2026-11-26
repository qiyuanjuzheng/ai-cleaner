import AICleanerCore
import SwiftUI

enum ItemListLayoutRegion: Hashable {
    case dashboard
    case controls
    case scopeNotice
}

extension EnvironmentValues {
    // An optional background that exposes each region's rendered frame in hosted window tests.
    @Entry var itemListLayoutProbe: ((ItemListLayoutRegion) -> AnyView)? = nil
}

struct ItemListView: View {
    @Bindable var viewModel: CleanerViewModel
    var isVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.itemListLayoutProbe) private var layoutProbe

    var body: some View {
        if viewModel.report == nil {
            ZStack {
                if viewModel.isScanning {
                    OrbitalScannerHero(isVisible: isVisible) {
                        viewModel.cancelScan()
                    }
                    .transition(.opacity)
                } else {
                    ScanReadyHeroView(
                        historicalFreedBytes: viewModel.totalHistoricalFreedBytes,
                        isVisible: isVisible && !viewModel.isScanning,
                        onStartScan: {
                            viewModel.startScan()
                        },
                        onOpenHistory: {
                            viewModel.sidebarSelection = .history
                        }
                    )
                    .allowsHitTesting(!viewModel.isScanning)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: viewModel.isScanning)
        } else {
            VStack(spacing: 0) {
                HeroDashboardHeaderView(viewModel: viewModel, isVisible: isVisible)
                    .background { layoutProbe?(.dashboard) }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                ItemControlBarView(viewModel: viewModel)
                    .background { layoutProbe?(.controls) }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                if let banner = viewModel.scopeNoticeBanner {
                    ScopeNoticeBannerView(banner: banner)
                        .background { layoutProbe?(.scopeNotice) }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .layoutPriority(1)
                }

                VirtualizedItemListView(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - 1. 隔离的空间仪表头（悬停三档卡片仅局部更新，绝不触发下方列表重绘）

private struct HeroDashboardHeaderView: View {
    @Bindable var viewModel: CleanerViewModel
    var isVisible: Bool = true
    @Namespace private var tierNamespace
    @State private var hoveredRecommendation: CleanupRecommendation? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlightedRingTier: CleanupRecommendation? {
        hoveredRecommendation ?? viewModel.selectedRecommendation
    }

    private var recommendedActionTooltip: String {
        guard let summary = viewModel.activeSummary else {
            return "勾选全部客户端、系统临时目录及自定义目录中的「建议清理」项"
        }
        switch summary.profile.kind {
        case .customDirectory:
            return "勾选当前自定义目录中的「建议清理」项"
        case .otherAITemp, .unattributedTemp:
            return "勾选当前分组中的「建议清理」项"
        case .builtInClient:
            return "勾选当前客户端中的「建议清理」项"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                // 标志性多段空间环（去除逐帧离屏 shadow 模糊，120fps 顺滑切换）
                StorageRingGauge(
                    recommendedBytes: viewModel.scopedRecommendedBytes,
                    reviewBytes: viewModel.scopedReviewSuggestedBytes,
                    protectedBytes: viewModel.scopedProtectedBytes,
                    highlightedTier: highlightedRingTier,
                    isScanning: viewModel.isScanning,
                    isVisible: isVisible
                )

                VStack(alignment: .leading, spacing: 11) {
                    // 标题行 + 唯一主行动按钮（锁定 44pt 固定高度，切换客户端绝不上下抖动）
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.headerTitleText)
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .lineLimit(1)

                            Text(viewModel.headerSubtitleText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        // 返回扫描状态按钮（固定高度 30pt，清爽克制不抢主按钮焦点）
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                                viewModel.returnToIdleState()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("返回扫描")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.045))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
                        .disabled(viewModel.isCleaning)
                        .help("返回扫描并清空本次结果")

                        if !viewModel.scopedRecommendedItems.isEmpty {
                            Button {
                                viewModel.selectRecommendedInScope()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                    Text("勾选建议清理项 · \(CleanerFormatting.formatBytes(viewModel.scopedRecommendedBytes))")
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
                            .help(recommendedActionTooltip)
                        }
                    }
                    .frame(height: 44)

                    // 统一三档交互式指标条（固定 52pt 高度，悬停/点击零跳动）
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
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.selectedRecommendation)
                }
            }

            // 纯 Canvas 零 GeometryReader 的 3.5pt 极细比例条（切换客户端时卡片高度 100% 恒定）
            HairlineStorageBar(
                recommendedBytes: viewModel.scopedRecommendedBytes,
                reviewBytes: viewModel.scopedReviewSuggestedBytes,
                protectedBytes: viewModel.scopedProtectedBytes,
                highlightedTier: highlightedRingTier
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppTheme.glassHeroCardFill(for: colorScheme))
        )
        .overlay(alignment: .top) {
            if viewModel.isScanning {
                AuroraScanSweepBar(isVisible: isVisible)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.045), radius: 10, y: 3)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: viewModel.isScanning)
    }

    private func tierMetricSegment(tier: CleanupRecommendation, bytes: Int64, count: Int) -> some View {
        let isSelected = viewModel.selectedRecommendation == tier
        let isHovered = hoveredRecommendation == tier
        let tint = AppTheme.color(for: tier)

        return Button {
            viewModel.toggleRecommendationFilter(tier)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)

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
            if hovering {
                hoveredRecommendation = tier
            } else if hoveredRecommendation == tier {
                hoveredRecommendation = nil
            }
        }
    }
}

// MARK: - 2. 隔离的单行极简筛选与搜索栏

struct ItemControlBarView: View {
    @Bindable var viewModel: CleanerViewModel
    @Namespace private var categoryNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            // 紧凑自适应宽度的滑动胶囊分类切换（局部微动画，绝不拖慢下方列表刷新）
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.selectedCategory)

            Spacer(minLength: 8)

            if viewModel.hasActiveFilters {
                Button("重置筛选") {
                    viewModel.clearAllFilters()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // 项目会话入口（与当前选中客户端绑定，替代原侧栏子项）
            if case .client(let clientID) = viewModel.sidebarSelection {
                Button {
                    viewModel.sidebarSelection = .clientProjects(clientID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("项目会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                            .fill(AppTheme.glassCardFill(for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                            .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("查看当前客户端的项目会话")
            }

            // 紧凑透明搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("搜索条目、项目或路径…", text: $viewModel.searchText)
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
                    .accessibilityLabel("清空搜索")
                    .help("清空搜索")
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

            ControlBarIconMenuButton(
                symbolName: "slider.horizontal.3",
                accessibilityLabel: ItemControlBarMenuFactory.accessibilityLabel,
                showsIndicatorBadge: viewModel.selectedAgeFilter != .all || viewModel.sortOrder != .sizeDescending,
                menuBuilder: {
                    ItemControlBarMenuFactory.makeMenu(for: viewModel)
                }
            )
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
            viewModel.selectedCategory = category
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
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "activeCategoryPill", in: categoryNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3. 原生 AppKit NSTableView 虚拟化列表（真正 Cell 对象池复用、零每行重型修饰符）

private struct VirtualizedItemListView: View {
    let viewModel: CleanerViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if viewModel.displayedRows.isEmpty {
            if viewModel.hasActiveFilters {
                ContentUnavailableView {
                    Label("没有匹配的条目", systemImage: "magnifyingglass")
                } description: {
                    Text("调整搜索词或筛选条件。")
                } actions: {
                    Button("重置筛选") {
                        viewModel.clearAllFilters()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("未找到可清理条目", systemImage: "checkmark.seal.fill")
                } description: {
                    if !viewModel.excludedItems.isEmpty {
                        Text("当前有 \(viewModel.excludedItems.count) 项在已排除列表中被自动跳过。")
                    }
                } actions: {
                    HStack(spacing: 10) {
                        Button("重新扫描") {
                            viewModel.rescan()
                        }
                        .buttonStyle(.bordered)

                        if !viewModel.excludedItems.isEmpty {
                            Button("查看已排除（\(viewModel.excludedItems.count)）") {
                                viewModel.sidebarSelection = .excluded
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VirtualizedItemTableView(
                rows: viewModel.displayedRows,
                rowsRevision: viewModel.displayedRowsRevision,
                selectionRevision: viewModel.selectionRevision,
                viewportID: viewModel.listViewportID,
                colorScheme: colorScheme,
                viewModel: viewModel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 纯 Canvas 零 GeometryReader 的 3.5pt 比例条

private struct HairlineStorageBar: View {
    let recommendedBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64
    let highlightedTier: CleanupRecommendation?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = Double(max(0, recommendedBytes) + max(0, reviewBytes) + max(0, protectedBytes))
        let recFrac = total > 0 ? Double(max(0, recommendedBytes)) / total : 0
        let revFrac = total > 0 ? Double(max(0, reviewBytes)) / total : 0
        let proFrac = total > 0 ? Double(max(0, protectedBytes)) / total : 0

        AnimatableHairlineCanvas(
            recFrac: recFrac,
            revFrac: revFrac,
            proFrac: proFrac,
            highlightedTier: highlightedTier,
            isDark: colorScheme == .dark
        )
        .frame(height: 3.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: recFrac)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: revFrac)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: proFrac)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlightedTier)
    }
}

private struct AnimatableHairlineCanvas: View, Animatable {
    var recFrac: Double
    var revFrac: Double
    var proFrac: Double
    let highlightedTier: CleanupRecommendation?
    let isDark: Bool

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(recFrac, AnimatablePair(revFrac, proFrac)) }
        set {
            recFrac = newValue.first
            revFrac = newValue.second.first
            proFrac = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 0 else { return }
            let radius = size.height / 2
            let trackRect = CGRect(origin: .zero, size: size)
            let trackColor = isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
            context.fill(Path(roundedRect: trackRect, cornerRadius: radius), with: .color(trackColor))

            let rawSegments: [(CleanupRecommendation, Double)] = [
                (.recommended, recFrac),
                (.reviewSuggested, revFrac),
                (.notRecommended, proFrac)
            ].filter { $0.1 > 0.0005 }

            guard !rawSegments.isEmpty else { return }

            let spacing: CGFloat = 3
            let gapTotal = CGFloat(max(0, rawSegments.count - 1)) * spacing
            let usableWidth = max(0, size.width - gapTotal)
            let sumFrac = max(0.0001, rawSegments.reduce(0) { $0 + $1.1 })
            let minSegWidth = min(5, usableWidth / CGFloat(rawSegments.count))

            var widths = rawSegments.map { max(minSegWidth, usableWidth * CGFloat($0.1 / sumFrac)) }
            let widthSum = widths.reduce(0, +)
            if widthSum > usableWidth {
                let scale = usableWidth / widthSum
                widths = widths.map { $0 * scale }
            }

            var cursorX: CGFloat = 0
            for (idx, segment) in rawSegments.enumerated() {
                let tier = segment.0
                let segW = widths[idx]
                let segRect = CGRect(x: cursorX, y: 0, width: segW, height: size.height)
                let opacity = highlightedTier == nil ? 0.90 : (highlightedTier == tier ? 1.0 : 0.25)

                let fillStyle: GraphicsContext.Shading
                switch tier {
                case .recommended:
                    fillStyle = .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.12, green: 0.86, blue: 0.58).opacity(opacity),
                            Color(red: 0.10, green: 0.68, blue: 0.78).opacity(opacity)
                        ]),
                        startPoint: CGPoint(x: segRect.minX, y: segRect.midY),
                        endPoint: CGPoint(x: segRect.maxX, y: segRect.midY)
                    )
                case .reviewSuggested:
                    fillStyle = .linearGradient(
                        Gradient(colors: [
                            Color(red: 1.00, green: 0.74, blue: 0.26).opacity(opacity),
                            Color(red: 0.96, green: 0.48, blue: 0.18).opacity(opacity)
                        ]),
                        startPoint: CGPoint(x: segRect.minX, y: segRect.midY),
                        endPoint: CGPoint(x: segRect.maxX, y: segRect.midY)
                    )
                case .notRecommended:
                    fillStyle = .color(AppTheme.color(for: .notRecommended).opacity(0.55 * opacity))
                }

                context.fill(Path(roundedRect: segRect, cornerRadius: radius), with: fillStyle)
                cursorX += segW + spacing
            }
        }
    }
}

private struct ScopeNoticeBannerView: View {
    let banner: ScopeNoticeBanner
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = AppTheme.color(for: .reviewSuggested)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.symbolName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.13))
                )
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2.5) {
                Text(banner.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.28), lineWidth: 0.8)
        )
    }
}
