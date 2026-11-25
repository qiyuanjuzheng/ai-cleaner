import AICleanerCore
import Charts
import SwiftUI

enum CleanupHistoryCopy {
    static let title = "清理记录"
    static let openActionTitle = "查看清理记录"
    static let clearRecordsMenuTitle = "清空清理记录…"
    static let clearRecordsAlertTitle = "清空清理记录？"
    static let clearRecordsConfirmTitle = "清空清理记录"
    static let clearRecordsAlertMessage = "此操作会清空清理记录和排行，废纸篓中的文件会保留。"
    static let clearOptionsHelp = "清理记录选项"
    static let deleteSingleRecordHelp = "删除这条清理记录（保留废纸篓文件）"
    static let emptyStateTitle = "暂无清理记录"
}

enum CleanupHistoryChartGeometry {
    /// 计算数据点在图表中对应的 X 轴视觉中心日期：
    /// - `.cumulative`（累计折线/面积图）：直接落在 `pointDate`（当日 `00:00`）
    /// - `.daily`（单日柱状图，`BarMark` 使用 `unit: .day`）：落在 `[startOfDay, nextDayStart)` 的水平正中心（通常为当日 `12:00`，自动兼容夏令时）
    static func anchorDate(
        for pointDate: Date,
        mode: CleanupTrendMetricMode,
        calendar: Calendar = .current
    ) -> Date {
        switch mode {
        case .cumulative:
            return pointDate
        case .daily:
            let dayStart = calendar.startOfDay(for: pointDate)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(86_400)
            return dayStart.addingTimeInterval(nextDayStart.timeIntervalSince(dayStart) * 0.5)
        }
    }

    /// 根据图表悬停反算出的 `rawDate` 吸附到目标数据点：
    /// - `.daily` 按自然日分桶：优先按 `[dayStart, nextDayStart)` 精准命中所在自然日（覆盖柱子左边缘、中心、右边缘及跨日 `00:00` 边界），越界时钳制至首/尾点；
    /// - `.daily` 按周分桶 或 `.cumulative`：按各点视觉中心 `anchorDate` 计算最近点，等距时吸附较新一天。
    static func nearestPoint(
        to rawDate: Date,
        in points: [CleanupTrendPoint],
        mode: CleanupTrendMetricMode,
        usesWeeklyBuckets: Bool = false,
        calendar: Calendar = .current
    ) -> CleanupTrendPoint? {
        guard !points.isEmpty else { return nil }

        if mode == .daily && !usesWeeklyBuckets {
            let hoveredDay = calendar.startOfDay(for: rawDate)
            if let exactMatch = points.first(where: { calendar.isDate($0.date, inSameDayAs: hoveredDay) }) {
                return exactMatch
            }
            if let first = points.first, hoveredDay < calendar.startOfDay(for: first.date) {
                return first
            }
            if let last = points.last, hoveredDay > calendar.startOfDay(for: last.date) {
                return last
            }
        }

        var bestPoint = points[0]
        var bestDistance = abs(
            anchorDate(for: bestPoint.date, mode: mode, calendar: calendar)
                .timeIntervalSince(rawDate)
        )

        for point in points.dropFirst() {
            let distance = abs(
                anchorDate(for: point.date, mode: mode, calendar: calendar)
                    .timeIntervalSince(rawDate)
            )
            if distance < bestDistance || (distance == bestDistance && point.date > bestPoint.date) {
                bestPoint = point
                bestDistance = distance
            }
        }
        return bestPoint
    }
}

struct CleanupHistoryView: View {
    @Bindable var viewModel: CleanerViewModel
    var initialHoveredPointDate: Date? = nil
    @Namespace private var rangeNamespace

    @State private var chartRevealed: Bool = false
    @State private var showingClearAlert: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: CleanupHistorySummary {
        viewModel.historySummary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                kpiStripCard
                HistoryTrendChartCard(
                    viewModel: viewModel,
                    summary: summary,
                    chartRevealed: chartRevealed,
                    initialHoveredPointDate: initialHoveredPointDate
                )

                if !summary.isEmpty {
                    bottomDetailGrid
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onAppear {
            if !chartRevealed {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.36)) {
                    chartRevealed = true
                }
            }
        }
        .alert(CleanupHistoryCopy.clearRecordsAlertTitle, isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button(CleanupHistoryCopy.clearRecordsConfirmTitle, role: .destructive) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                    viewModel.clearAllHistoryRecords()
                }
            }
        } message: {
            Text(CleanupHistoryCopy.clearRecordsAlertMessage)
        }
    }

    // MARK: - 1. 顶栏标题与时间窗口切换

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(CleanupHistoryCopy.title)
                .font(.system(.title2, design: .rounded).weight(.bold))

            Spacer(minLength: 8)

            // 时间窗口滑动胶囊（局部微动画，避免整页重排动画叠加）
            HStack(spacing: 2) {
                ForEach(CleanupTrendRange.allCases) { range in
                    let isSelected = viewModel.historyRange == range
                    Button {
                        viewModel.historyRange = range
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                                        .matchedGeometryEffect(id: "historyRangePill", in: rangeNamespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.historyRange)

            if !summary.isEmpty {
                ControlBarIconMenuButton(
                    symbolName: "ellipsis",
                    symbolWeight: .semibold,
                    accessibilityLabel: CleanupHistoryCopy.clearOptionsHelp,
                    menuBuilder: {
                        CleanupHistoryMenuFactory.makeMenu {
                            showingClearAlert = true
                        }
                    }
                )
            }
        }
        .frame(height: 44)
    }

    // MARK: - 2. 统一三列玻璃指标条（克制零割裂，取消实时 backdrop 模糊）

    private var kpiStripCard: some View {
        HStack(spacing: 0) {
            kpiMetricCell(
                title: "累计已移入废纸篓",
                value: formatKPIBytes(summary.totalFreedBytes),
                subtitle: summary.totalRuns > 0
                    ? "共 \(summary.totalRuns) 次清理 · \(summary.totalTrashedItems) 项"
                    : "暂无记录",
                accent: AppTheme.color(for: .recommended)
            )

            verticalDivider

            kpiMetricCell(
                title: viewModel.historyRange == .allTime
                    ? "全部时间已移入废纸篓"
                    : "\(viewModel.historyRange.rawValue)已移入废纸篓",
                value: formatKPIBytes(summary.rangeFreedBytes),
                subtitle: summary.rangeRuns > 0
                    ? "周期内 \(summary.rangeRuns) 次清理 · \(summary.rangeTrashedItems) 项"
                    : "此时间范围内暂无记录",
                accent: Color(red: 0.24, green: 0.72, blue: 0.98)
            )

            verticalDivider

            kpiMetricCell(
                title: "单次移入废纸篓最大值",
                value: formatKPIBytes(summary.largestSingleRunBytes),
                subtitle: summary.totalRuns > 0
                    ? "平均每次 \(CleanerFormatting.formatBytes(summary.averagePerRunBytes))"
                    : "按单次移入废纸篓统计",
                accent: Color(red: 0.60, green: 0.50, blue: 0.98)
            )
        }
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppTheme.glassHeroCardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045), radius: 10, y: 3)
    }

    private func kpiMetricCell(title: String, value: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6.5, height: 6.5)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(summary.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatKPIBytes(_ bytes: Int64) -> String {
        bytes <= 0 ? "0 B" : CleanerFormatting.formatBytes(bytes)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(AppTheme.hairlineDivider(for: colorScheme))
            .frame(width: 1, height: 48)
    }

    // MARK: - 4. 底部双栏：客户端移入废纸篓排行 + 最近移入废纸篓

    private var bottomDetailGrid: some View {
        HStack(alignment: .top, spacing: 14) {
            clientRankingCard
                .frame(minWidth: 260, maxWidth: 340)

            recentRecordsCard
                .frame(maxWidth: .infinity)
        }
    }

    private var clientRankingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("客户端移入废纸篓排行")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(viewModel.historyRange.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if summary.topClients.isEmpty {
                    Text("暂无客户端统计")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                } else {
                    let topList = Array(summary.topClients.prefix(8))
                    ForEach(Array(topList.enumerated()), id: \.element.id) { index, client in
                        let tint = viewModel.clientTint(for: client.clientID)
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                if client.clientID.hasPrefix("custom-") {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(tint)
                                        .frame(width: 20, height: 20)
                                } else if client.clientID == TempDirectoryScanner.otherAITempClientID {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(tint)
                                        .frame(width: 20, height: 20)
                                } else if client.clientID == TempDirectoryScanner.unattributedTempClientID {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(tint)
                                        .frame(width: 20, height: 20)
                                } else {
                                    ClientLogo(clientID: client.clientID)
                                }

                                Text(client.clientName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                Text(CleanerFormatting.formatBytes(client.totalFreedBytes))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)

                                Text("\(Int((client.share * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .trailing)
                            }

                            // 纯 Canvas 零 GeometryReader 占比进度条
                            Canvas { context, size in
                                let radius = size.height / 2
                                let trackColor = colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
                                context.fill(
                                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                                    with: .color(trackColor)
                                )
                                let fillW = chartRevealed ? max(5, size.width * CGFloat(client.share)) : 0
                                if fillW > 0 {
                                    let fillRect = CGRect(x: 0, y: 0, width: min(size.width, fillW), height: size.height)
                                    context.fill(
                                        Path(roundedRect: fillRect, cornerRadius: radius),
                                        with: .linearGradient(
                                            Gradient(colors: [tint, tint.opacity(0.65)]),
                                            startPoint: CGPoint(x: 0, y: size.height / 2),
                                            endPoint: CGPoint(x: fillRect.maxX, y: size.height / 2)
                                        )
                                    )
                                }
                            }
                            .frame(height: 3.5)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)

                        if index < topList.count - 1 {
                            Rectangle()
                                .fill(AppTheme.hairlineDivider(for: colorScheme))
                                .frame(height: 0.5)
                                .padding(.horizontal, 14)
                        }
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
        }
    }

    private var recentRecordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近移入废纸篓")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("共 \(summary.recentRecords.count) 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                let displayed = Array(summary.recentRecords.prefix(20))
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, record in
                    HistoryLogRow(record: record) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                            viewModel.deleteHistoryRecord(id: record.id)
                        }
                    }

                    if index < displayed.count - 1 {
                        Rectangle()
                            .fill(AppTheme.hairlineDivider(for: colorScheme))
                            .frame(height: 0.5)
                            .padding(.horizontal, 14)
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

// MARK: - 3. 隔离的图表玻璃卡片（悬停光标仅局部重绘图表区，且吸附同日不重复触发状态变更）

struct HistoryTrendChartCard: View {
    @Bindable var viewModel: CleanerViewModel
    let summary: CleanupHistorySummary
    let chartRevealed: Bool

    @Namespace private var modeNamespace
    @State private var hoveredPointDate: Date?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        viewModel: CleanerViewModel,
        summary: CleanupHistorySummary,
        chartRevealed: Bool,
        initialHoveredPointDate: Date? = nil
    ) {
        self.viewModel = viewModel
        self.summary = summary
        self.chartRevealed = chartRevealed
        _hoveredPointDate = State(initialValue: initialHoveredPointDate)
    }

    private var periodLabel: String {
        summary.usesWeeklyBuckets ? "当周" : "当日"
    }

    private var chartMetricLabel: String {
        if viewModel.historyMetricMode == .cumulative {
            return "累计已移入废纸篓"
        }
        return summary.usesWeeklyBuckets ? "每周已移入废纸篓" : "单日已移入废纸篓"
    }

    private var hoveredPoint: CleanupTrendPoint? {
        guard let hoveredPointDate else { return nil }
        return summary.points.first { $0.date == hoveredPointDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let point = hoveredPoint, !summary.isEmpty {
                        HStack(spacing: 8) {
                            Text(CleanerFormatting.formatDay(point.date))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text("\(periodLabel)已移入废纸篓 \(point.dailyFreedBytes <= 0 ? "0 B" : CleanerFormatting.formatBytes(point.dailyFreedBytes))")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(AppTheme.color(for: .recommended))
                        }

                        Text("累计已移入废纸篓 \(point.cumulativeFreedBytes <= 0 ? "0 B" : CleanerFormatting.formatBytes(point.cumulativeFreedBytes))\(point.cleanupRuns > 0 ? " · \(point.cleanupRuns) 次清理 · \(point.trashedCount) 项" : "")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(chartMetricLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !summary.isEmpty {
                            Text("悬停查看详情")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 36, alignment: .leading)

                Spacer(minLength: 8)

                // 曲线模式切换（累计 / 单日）
                HStack(spacing: 2) {
                    ForEach(CleanupTrendMetricMode.allCases) { mode in
                        let isSelected = viewModel.historyMetricMode == mode
                        Button {
                            viewModel.historyMetricMode = mode
                        } label: {
                            Text(mode == .daily && summary.usesWeeklyBuckets ? "每周" : mode.rawValue)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .background {
                                    if isSelected {
                                        Capsule(style: .continuous)
                                            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                                            .matchedGeometryEffect(id: "historyModePill", in: modeNamespace)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.045))
                )
                .fixedSize(horizontal: true, vertical: false)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.historyMetricMode)
            }
            .frame(height: 36)

            if summary.isEmpty {
                emptyChartPlaceholder
            } else {
                interactiveTrendChart
                    .frame(height: 224)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppTheme.glassHeroCardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045), radius: 10, y: 3)
        .onChange(of: viewModel.historyRange) { _, _ in
            hoveredPointDate = nil
        }
    }

    private var interactiveTrendChart: some View {
        let points = summary.points
        let mode = viewModel.historyMetricMode
        let metricLabel = chartMetricLabel
        let isCumulative = mode == .cumulative
        let calendar = Calendar.current
        let emerald = AppTheme.color(for: .recommended)
        let cyan = Color(red: 0.20, green: 0.74, blue: 0.96)
        let maxRaw = points.map { mode.bytes(for: $0) }.max() ?? 0
        let yUpper = max(Int64(1024), Int64(Double(maxRaw) * 1.15))

        return Chart {
            if isCumulative {
                ForEach(points) { point in
                    let yVal = chartRevealed ? mode.bytes(for: point) : 0
                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value(metricLabel, yVal)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                emerald.opacity(colorScheme == .dark ? 0.30 : 0.22),
                                cyan.opacity(colorScheme == .dark ? 0.08 : 0.06),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("日期", point.date),
                        y: .value(metricLabel, yVal)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [emerald, cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                    if point.dailyFreedBytes > 0 {
                        PointMark(
                            x: .value("日期", point.date),
                            y: .value(metricLabel, yVal)
                        )
                        .symbolSize(34)
                        .foregroundStyle(emerald)
                    }
                }
            } else {
                ForEach(points) { point in
                    let yVal = chartRevealed ? mode.bytes(for: point) : 0
                    BarMark(
                        x: .value("日期", point.date, unit: .day, calendar: calendar),
                        y: .value(metricLabel, yVal)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [emerald, cyan.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(hoveredPointDate == nil || hoveredPointDate == point.date ? 0.92 : 0.38)
                }
            }

            if let active = hoveredPoint {
                let activeY = mode.bytes(for: active)
                let activeX = CleanupHistoryChartGeometry.anchorDate(
                    for: active.date,
                    mode: mode,
                    calendar: calendar
                )
                RuleMark(x: .value("日期", activeX))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.30 : 0.22))

                PointMark(
                    x: .value("日期", activeX),
                    y: .value(metricLabel, activeY)
                )
                .symbolSize(90)
                .foregroundStyle(emerald.opacity(0.28))

                PointMark(
                    x: .value("日期", activeX),
                    y: .value(metricLabel, activeY)
                )
                .symbolSize(38)
                .foregroundStyle(colorScheme == .dark ? Color.white : emerald)
            }
        }
        .chartYScale(domain: 0...yUpper)
        .chartYAxisLabel("已移入废纸篓")
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(AppTheme.hairlineDivider(for: colorScheme))
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes == 0 ? "0 B" : CleanerFormatting.formatBytes(bytes))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Color.secondary.opacity(0.85))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(CleanerFormatting.formatShortMonthDay(date))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Color.secondary.opacity(0.85))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let plotOriginX = geometry[plotFrame].origin.x
                            let xPos = location.x - plotOriginX
                            if xPos >= 0 && xPos <= proxy.plotSize.width,
                               let rawDate: Date = proxy.value(atX: xPos),
                               let nearest = CleanupHistoryChartGeometry.nearestPoint(
                                   to: rawDate,
                                   in: points,
                                   mode: mode,
                                   usesWeeklyBuckets: summary.usesWeeklyBuckets,
                                   calendar: calendar
                               ) {
                                if hoveredPointDate != nearest.date {
                                    hoveredPointDate = nearest.date
                                }
                            } else if hoveredPointDate != nil {
                                hoveredPointDate = nil
                            }
                        case .ended:
                            if hoveredPointDate != nil {
                                hoveredPointDate = nil
                            }
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: viewModel.historyRange)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: viewModel.historyMetricMode)
    }

    private var emptyChartPlaceholder: some View {
        ZStack {
            Canvas { context, size in
                var path = Path()
                let pts: [CGPoint] = [
                    CGPoint(x: 0, y: size.height * 0.82),
                    CGPoint(x: size.width * 0.22, y: size.height * 0.76),
                    CGPoint(x: size.width * 0.45, y: size.height * 0.58),
                    CGPoint(x: size.width * 0.70, y: size.height * 0.42),
                    CGPoint(x: size.width, y: size.height * 0.24)
                ]
                path.move(to: pts[0])
                for i in 1..<pts.count {
                    let prev = pts[i - 1]
                    let curr = pts[i]
                    let midX = (prev.x + curr.x) * 0.5
                    path.addCurve(
                        to: curr,
                        control1: CGPoint(x: midX, y: prev.y),
                        control2: CGPoint(x: midX, y: curr.y)
                    )
                }
                context.stroke(
                    path,
                    with: .color(AppTheme.color(for: .recommended).opacity(colorScheme == .dark ? 0.16 : 0.14)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6])
                )
            }

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.color(for: .recommended).opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.color(for: .recommended))
                }

                Text(CleanupHistoryCopy.emptyStateTitle)
                    .font(.headline)

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
        }
        .frame(height: 224)
    }
}

// MARK: - 单条历史清理明细行（悬停显露删除单条记录图标）

private struct HistoryLogRow: View {
    let record: CleanupHistoryRecord
    let onDelete: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(clientHeadline)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text("· \(record.trashedCount) 项")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Group {
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(CleanupHistoryCopy.deleteSingleRecordHelp)
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(CleanerFormatting.formatBytes(record.freedBytes))")
                    .font(.system(.callout, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(AppTheme.color(for: .recommended))

                Text(CleanerFormatting.formatDate(record.timestamp))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 108, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var clientHeadline: String {
        let names = record.clientBreakdown.map(\.clientName)
        if names.isEmpty {
            return "清理记录"
        }
        if names.count <= 2 {
            return names.joined(separator: "、")
        }
        return "\(names[0])、\(names[1]) 等 \(names.count) 个客户端"
    }

    private var detailLine: String {
        if record.sampleItemNames.isEmpty {
            return "已移入废纸篓"
        }
        return record.sampleItemNames.joined(separator: " / ")
    }
}
