import AICleanerCore
import Charts
import SwiftUI

struct CleanupHistoryView: View {
    @Bindable var viewModel: CleanerViewModel
    @Namespace private var rangeNamespace
    @Namespace private var modeNamespace

    @State private var hoveredDate: Date? = nil
    @State private var chartRevealed: Bool = false
    @State private var showingClearAlert: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: CleanupHistorySummary {
        viewModel.historySummary
    }

    private var hoveredPoint: CleanupTrendPoint? {
        guard let hoveredDate else { return nil }
        return summary.points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(hoveredDate)) < abs(rhs.date.timeIntervalSince(hoveredDate))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                kpiStripCard
                trendChartCard

                if !summary.isEmpty {
                    bottomDetailGrid
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.84)) {
                chartRevealed = true
            }
        }
        .alert("清空全部历史清理统计？", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空统计记录", role: .destructive) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    viewModel.clearAllHistoryRecords()
                }
            }
        } message: {
            Text("该操作仅清空本应用保存的释放空间趋势日志，不会触碰磁盘或系统废纸篓中的任何文件。")
        }
    }

    // MARK: - 1. 顶栏标题与时间窗口切换

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("历史清理趋势")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("统计每次安全移入系统废纸篓所释放的磁盘空间变化")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // 时间窗口滑动胶囊
            HStack(spacing: 2) {
                ForEach(CleanupTrendRange.allCases) { range in
                    let isSelected = viewModel.historyRange == range
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80)) {
                            viewModel.historyRange = range
                            hoveredDate = nil
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 3, y: 1)
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

            if !summary.isEmpty {
                Menu {
                    Button("清空全部历史统计…", role: .destructive) {
                        showingClearAlert = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(AppTheme.glassCardFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.7)
                )
                .fixedSize()
                .help("更多统计操作")
            }
        }
    }

    // MARK: - 2. 统一三列玻璃指标条（克制零割裂）

    private var kpiStripCard: some View {
        HStack(spacing: 0) {
            kpiMetricCell(
                title: "累计已释放空间",
                value: formatKPIBytes(summary.totalFreedBytes),
                subtitle: summary.totalRuns > 0
                    ? "共 \(summary.totalRuns) 次清理 · \(summary.totalTrashedItems) 个条目"
                    : "尚未产生清理记录",
                accent: AppTheme.color(for: .recommended)
            )

            verticalDivider

            kpiMetricCell(
                title: "\(viewModel.historyRange.rawValue)释放",
                value: formatKPIBytes(summary.rangeFreedBytes),
                subtitle: summary.rangeRuns > 0
                    ? "周期内 \(summary.rangeRuns) 次清理 · \(summary.rangeTrashedItems) 项"
                    : "当前时间窗口内无记录",
                accent: Color(red: 0.24, green: 0.72, blue: 0.98)
            )

            verticalDivider

            kpiMetricCell(
                title: "单次最高释放",
                value: formatKPIBytes(summary.largestSingleRunBytes),
                subtitle: summary.totalRuns > 0
                    ? "平均每次 \(CleanerFormatting.formatBytes(summary.averagePerRunBytes))"
                    : "按单次移入废纸篓统计",
                accent: Color(red: 0.60, green: 0.50, blue: 0.98)
            )
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AppTheme.glassCardFill(for: colorScheme))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.05), radius: 10, y: 4)
    }

    private func kpiMetricCell(title: String, value: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: accent.opacity(0.65), radius: 3)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(summary.isEmpty ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
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

    // MARK: - 3. 主趋势图玻璃卡片（Swift Charts 累计面积曲线 / 单日渐变柱状图）

    private var trendChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let point = hoveredPoint, !summary.isEmpty {
                    HStack(spacing: 10) {
                        Text(CleanerFormatting.formatDay(point.date))
                            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)

                        Text("当日 +\(CleanerFormatting.formatBytes(point.dailyFreedBytes))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AppTheme.color(for: .recommended))
                            .contentTransition(.numericText())

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text("累计 \(CleanerFormatting.formatBytes(point.cumulativeFreedBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())

                        if point.cleanupRuns > 0 {
                            Text("（\(point.cleanupRuns) 次 · \(point.trashedCount) 项）")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.historyMetricMode == .cumulative ? "累计释放空间趋势" : "单日释放空间分布")
                            .font(.subheadline.weight(.semibold))
                        Text(summary.isEmpty ? "完成首次安全清理后将自动绘制空间趋势曲线" : "鼠标悬停图表可实时查看每日释放与累计体积")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                // 曲线模式切换（累计释放 / 单日释放）
                HStack(spacing: 2) {
                    ForEach(CleanupTrendMetricMode.allCases) { mode in
                        let isSelected = viewModel.historyMetricMode == mode
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.80)) {
                                viewModel.historyMetricMode = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .background {
                                    if isSelected {
                                        Capsule(style: .continuous)
                                            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 2.5, y: 1)
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
            }

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
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AppTheme.glassCardFill(for: colorScheme))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppTheme.specularRimGradient(for: colorScheme), lineWidth: 0.85)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 12, y: 4)
    }

    private var interactiveTrendChart: some View {
        let points = summary.points
        let isCumulative = viewModel.historyMetricMode == .cumulative
        let emerald = AppTheme.color(for: .recommended)
        let cyan = Color(red: 0.20, green: 0.74, blue: 0.96)
        let maxRaw = points.map { isCumulative ? $0.cumulativeFreedBytes : $0.dailyFreedBytes }.max() ?? 0
        let yUpper = max(Int64(1024), Int64(Double(maxRaw) * 1.15))

        return Chart {
            if isCumulative {
                ForEach(points) { point in
                    let yVal = chartRevealed ? point.cumulativeFreedBytes : 0
                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value("累计释放", yVal)
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
                        y: .value("累计释放", yVal)
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
                            y: .value("累计释放", yVal)
                        )
                        .symbolSize(34)
                        .foregroundStyle(emerald)
                    }
                }
            } else {
                ForEach(points) { point in
                    let yVal = chartRevealed ? point.dailyFreedBytes : 0
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("当日释放", yVal)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [emerald, cyan.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(hoveredPoint == nil || hoveredPoint?.id == point.id ? 0.92 : 0.38)
                }
            }

            if let active = hoveredPoint {
                let activeY = isCumulative ? active.cumulativeFreedBytes : active.dailyFreedBytes
                RuleMark(x: .value("日期", active.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.30 : 0.22))

                PointMark(
                    x: .value("日期", active.date),
                    y: .value("数值", activeY)
                )
                .symbolSize(90)
                .foregroundStyle(emerald.opacity(0.28))

                PointMark(
                    x: .value("日期", active.date),
                    y: .value("数值", activeY)
                )
                .symbolSize(38)
                .foregroundStyle(colorScheme == .dark ? Color.white : emerald)
            }
        }
        .chartYScale(domain: 0...yUpper)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(AppTheme.hairlineDivider(for: colorScheme))
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes == 0 ? "0" : CleanerFormatting.formatBytes(bytes))
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
                               let date: Date = proxy.value(atX: xPos) {
                                hoveredDate = date
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.84), value: viewModel.historyRange)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.84), value: viewModel.historyMetricMode)
    }

    private var emptyChartPlaceholder: some View {
        ZStack {
            // 极淡背景趋势参考虚线，让空态也具备精致视觉平衡
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

                Text("暂无历史清理统计")
                    .font(.headline)

                Text("执行一次移入废纸篓操作后，这里将自动记录每次释放的磁盘体积与客户端分布。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80)) {
                        viewModel.sidebarSelection = .allClients
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("前往查看可清理项")
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

    // MARK: - 4. 底部双栏：客户端累计释放排行 + 最近清理记录

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
                Text("客户端释放排行")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(viewModel.historyRange.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if summary.topClients.isEmpty {
                    Text("暂无客户端维度数据")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                } else {
                    let topList = Array(summary.topClients.prefix(8))
                    ForEach(Array(topList.enumerated()), id: \.element.id) { index, client in
                        let visual = viewModel.clientVisualMeta(for: client.clientID)
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: visual.symbolName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(visual.tint)
                                    .frame(width: 18)

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

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.06))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [visual.tint, visual.tint.opacity(0.65)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(5, proxy.size.width * CGFloat(chartRevealed ? client.share : 0)))
                                }
                            }
                            .frame(height: 3.5)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

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
                Text("最近清理记录")
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

// MARK: - 单条历史清理明细行（悬停显露删除单条记录图标）

private struct HistoryLogRow: View {
    let record: CleanupHistoryRecord
    let onDelete: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
            .help("移除此条统计记录（不影响废纸篓文件）")

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
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03) : Color.clear)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var clientHeadline: String {
        let names = record.clientBreakdown.map(\.clientName)
        if names.isEmpty {
            return "清理任务"
        }
        if names.count <= 2 {
            return names.joined(separator: "、")
        }
        return "\(names[0])、\(names[1]) 等 \(names.count) 个客户端"
    }

    private var detailLine: String {
        if record.sampleItemNames.isEmpty {
            return "已安全移入系统废纸篓"
        }
        return record.sampleItemNames.joined(separator: " / ")
    }
}
