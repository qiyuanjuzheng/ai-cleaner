import Foundation

/// 单次清理中按客户端维度的释放明细
public struct ClientCleanupDelta: Identifiable, Codable, Hashable, Sendable {
    public var id: String { clientID }
    public let clientID: String
    public let clientName: String
    public let freedBytes: Int64
    public let itemCount: Int

    public init(
        clientID: String,
        clientName: String,
        freedBytes: Int64,
        itemCount: Int
    ) {
        self.clientID = clientID
        self.clientName = clientName
        self.freedBytes = freedBytes
        self.itemCount = itemCount
    }
}

/// 单次清理中按类别维度的释放明细
public struct CategoryCleanupDelta: Identifiable, Codable, Hashable, Sendable {
    public var id: String { category.rawValue }
    public let category: ScanCategory
    public let freedBytes: Int64
    public let itemCount: Int

    public init(
        category: ScanCategory,
        freedBytes: Int64,
        itemCount: Int
    ) {
        self.category = category
        self.freedBytes = freedBytes
        self.itemCount = itemCount
    }
}

/// 单次成功移入系统废纸篓的历史清理记录
public struct CleanupHistoryRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let freedBytes: Int64
    public let trashedCount: Int
    public let clientBreakdown: [ClientCleanupDelta]
    public let categoryBreakdown: [CategoryCleanupDelta]
    public let sampleItemNames: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        freedBytes: Int64,
        trashedCount: Int,
        clientBreakdown: [ClientCleanupDelta] = [],
        categoryBreakdown: [CategoryCleanupDelta] = [],
        sampleItemNames: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.freedBytes = max(0, freedBytes)
        self.trashedCount = max(0, trashedCount)
        self.clientBreakdown = clientBreakdown
        self.categoryBreakdown = categoryBreakdown
        self.sampleItemNames = sampleItemNames
    }

    /// 从单次 `CleanupResult` 构造可持久化记录；若本次未成功移入任何条目则返回 `nil`
    public static func from(result: CleanupResult, at timestamp: Date? = nil) -> CleanupHistoryRecord? {
        guard !result.trashedItems.isEmpty else { return nil }

        let items = result.trashedItems.map(\.item)

        let byClient = Dictionary(grouping: items, by: \.clientID)
        let clientBreakdown: [ClientCleanupDelta] = byClient.compactMap { clientID, grouped in
            guard let first = grouped.first else { return nil }
            let sum = grouped.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return ClientCleanupDelta(
                clientID: clientID,
                clientName: first.clientName,
                freedBytes: sum,
                itemCount: grouped.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.freedBytes != rhs.freedBytes {
                return lhs.freedBytes > rhs.freedBytes
            }
            return lhs.clientName.localizedCaseInsensitiveCompare(rhs.clientName) == .orderedAscending
        }

        let byCategory = Dictionary(grouping: items, by: \.category)
        let categoryBreakdown: [CategoryCleanupDelta] = byCategory.map { category, grouped in
            let sum = grouped.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return CategoryCleanupDelta(
                category: category,
                freedBytes: sum,
                itemCount: grouped.count
            )
        }
        .sorted { $0.freedBytes > $1.freedBytes }

        let topItemNames = items
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(3)
            .map(\.displayName)

        return CleanupHistoryRecord(
            timestamp: timestamp ?? result.completedAt,
            freedBytes: result.freedBytes,
            trashedCount: result.trashedCount,
            clientBreakdown: clientBreakdown,
            categoryBreakdown: categoryBreakdown,
            sampleItemNames: Array(topItemNames)
        )
    }
}

/// 趋势图时间窗口
public enum CleanupTrendRange: String, CaseIterable, Identifiable, Sendable {
    case days7 = "近 7 天"
    case days30 = "近 30 天"
    case days90 = "近 90 天"
    case allTime = "全部"

    public var id: String { rawValue }

    public var daySpan: Int? {
        switch self {
        case .days7: return 7
        case .days30: return 30
        case .days90: return 90
        case .allTime: return nil
        }
    }
}

/// 趋势图指标展示模式
public enum CleanupTrendMetricMode: String, CaseIterable, Identifiable, Sendable {
    case cumulative = "累计释放"
    case daily = "单日释放"

    public var id: String { rawValue }
}

/// 趋势图单个时间桶（按自然日聚合）
public struct CleanupTrendPoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let dailyFreedBytes: Int64
    public let cumulativeFreedBytes: Int64
    public let cleanupRuns: Int
    public let trashedCount: Int

    public init(
        date: Date,
        dailyFreedBytes: Int64,
        cumulativeFreedBytes: Int64,
        cleanupRuns: Int,
        trashedCount: Int
    ) {
        self.date = date
        self.dailyFreedBytes = dailyFreedBytes
        self.cumulativeFreedBytes = cumulativeFreedBytes
        self.cleanupRuns = cleanupRuns
        self.trashedCount = trashedCount
    }
}

/// 按客户端汇总的历史累计释放排行
public struct ClientSavingsSummary: Identifiable, Hashable, Sendable {
    public var id: String { clientID }
    public let clientID: String
    public let clientName: String
    public let totalFreedBytes: Int64
    public let itemCount: Int
    public let share: Double

    public init(
        clientID: String,
        clientName: String,
        totalFreedBytes: Int64,
        itemCount: Int,
        share: Double
    ) {
        self.clientID = clientID
        self.clientName = clientName
        self.totalFreedBytes = totalFreedBytes
        self.itemCount = itemCount
        self.share = share
    }
}

/// 历史清理空间统计汇总结果（供趋势图与排行榜渲染）
public struct CleanupHistorySummary: Equatable, Sendable {
    public let range: CleanupTrendRange
    public let totalFreedBytes: Int64
    public let rangeFreedBytes: Int64
    public let totalRuns: Int
    public let rangeRuns: Int
    public let totalTrashedItems: Int
    public let rangeTrashedItems: Int
    public let largestSingleRunBytes: Int64
    public let averagePerRunBytes: Int64
    public let points: [CleanupTrendPoint]
    public let topClients: [ClientSavingsSummary]
    public let recentRecords: [CleanupHistoryRecord]

    public var isEmpty: Bool { totalRuns == 0 }
}

/// 纯函数历史统计与趋势聚合引擎（便于独立单元测试）
public enum CleanupHistoryAnalytics {
    public static func summarize(
        records: [CleanupHistoryRecord],
        range: CleanupTrendRange,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> CleanupHistorySummary {
        let sortedAsc = records.sorted { $0.timestamp < $1.timestamp }
        let sortedDesc = Array(sortedAsc.reversed())

        let totalFreedBytes = sortedAsc.reduce(Int64(0)) { $0 + $1.freedBytes }
        let totalRuns = sortedAsc.count
        let totalTrashedItems = sortedAsc.reduce(0) { $0 + $1.trashedCount }
        let largestSingleRunBytes = sortedAsc.map(\.freedBytes).max() ?? 0
        let averagePerRunBytes = totalRuns > 0 ? totalFreedBytes / Int64(totalRuns) : 0

        let todayStart = calendar.startOfDay(for: referenceDate)

        // 计算趋势窗口起止日期
        let windowStart: Date
        if let span = range.daySpan {
            windowStart = calendar.date(byAdding: .day, value: -(span - 1), to: todayStart) ?? todayStart
        } else if let earliest = sortedAsc.first?.timestamp {
            let earliestDay = calendar.startOfDay(for: earliest)
            let minSpanStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            windowStart = min(earliestDay, minSpanStart)
        } else {
            windowStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        }

        // 统计窗口之前的基线累计释放量，确保累计曲线真实连续不归零
        var baselineCumulative: Int64 = 0
        var inRangeRecords: [CleanupHistoryRecord] = []
        for record in sortedAsc {
            let day = calendar.startOfDay(for: record.timestamp)
            if day < windowStart {
                baselineCumulative += record.freedBytes
            } else if day <= todayStart {
                inRangeRecords.append(record)
            } else {
                // 兼容时钟偏差导致的未来时间戳，纳入最新桶统计
                inRangeRecords.append(record)
            }
        }

        let rangeFreedBytes = inRangeRecords.reduce(Int64(0)) { $0 + $1.freedBytes }
        let rangeRuns = inRangeRecords.count
        let rangeTrashedItems = inRangeRecords.reduce(0) { $0 + $1.trashedCount }

        // 按自然日聚合窗口内的清理记录
        var dailyBuckets: [Date: (bytes: Int64, runs: Int, items: Int)] = [:]
        for record in inRangeRecords {
            let rawDay = calendar.startOfDay(for: record.timestamp)
            let day = min(rawDay, todayStart)
            var existing = dailyBuckets[day] ?? (0, 0, 0)
            existing.bytes += record.freedBytes
            existing.runs += 1
            existing.items += record.trashedCount
            dailyBuckets[day] = existing
        }

        // 生成连续日期序列（当「全部」跨度极大超过 180 天时自动按周聚合避免图表点过密）
        let dayDiff = max(0, calendar.dateComponents([.day], from: windowStart, to: todayStart).day ?? 0)
        var points: [CleanupTrendPoint] = []
        var runningCumulative = baselineCumulative

        if range == .allTime && dayDiff > 180 {
            var cursor = windowStart
            while cursor <= todayStart {
                let nextCursor = calendar.date(byAdding: .day, value: 7, to: cursor) ?? todayStart.addingTimeInterval(7 * 86400)
                var bucketBytes: Int64 = 0
                var bucketRuns = 0
                var bucketItems = 0
                for (day, val) in dailyBuckets where day >= cursor && day < nextCursor {
                    bucketBytes += val.bytes
                    bucketRuns += val.runs
                    bucketItems += val.items
                }
                runningCumulative += bucketBytes
                points.append(
                    CleanupTrendPoint(
                        date: cursor,
                        dailyFreedBytes: bucketBytes,
                        cumulativeFreedBytes: runningCumulative,
                        cleanupRuns: bucketRuns,
                        trashedCount: bucketItems
                    )
                )
                cursor = nextCursor
            }
        } else {
            for offset in 0...dayDiff {
                guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { continue }
                let entry = dailyBuckets[day] ?? (0, 0, 0)
                runningCumulative += entry.bytes
                points.append(
                    CleanupTrendPoint(
                        date: day,
                        dailyFreedBytes: entry.bytes,
                        cumulativeFreedBytes: runningCumulative,
                        cleanupRuns: entry.runs,
                        trashedCount: entry.items
                    )
                )
            }
        }

        // 按客户端汇总当前窗口内的释放排行（窗口内无数据时回退显示历史总排行）
        let rankingSource = inRangeRecords.isEmpty ? sortedAsc : inRangeRecords
        var clientTotals: [String: (name: String, bytes: Int64, items: Int)] = [:]
        for record in rankingSource {
            for delta in record.clientBreakdown {
                var current = clientTotals[delta.clientID] ?? (delta.clientName, 0, 0)
                current.bytes += delta.freedBytes
                current.items += delta.itemCount
                clientTotals[delta.clientID] = current
            }
        }
        let clientSum = max(Int64(1), clientTotals.values.reduce(Int64(0)) { $0 + $1.bytes })
        let topClients: [ClientSavingsSummary] = clientTotals
            .map { clientID, value in
                ClientSavingsSummary(
                    clientID: clientID,
                    clientName: value.name,
                    totalFreedBytes: value.bytes,
                    itemCount: value.items,
                    share: Double(value.bytes) / Double(clientSum)
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalFreedBytes != rhs.totalFreedBytes {
                    return lhs.totalFreedBytes > rhs.totalFreedBytes
                }
                return lhs.clientName.localizedCaseInsensitiveCompare(rhs.clientName) == .orderedAscending
            }

        return CleanupHistorySummary(
            range: range,
            totalFreedBytes: totalFreedBytes,
            rangeFreedBytes: rangeFreedBytes,
            totalRuns: totalRuns,
            rangeRuns: rangeRuns,
            totalTrashedItems: totalTrashedItems,
            rangeTrashedItems: rangeTrashedItems,
            largestSingleRunBytes: largestSingleRunBytes,
            averagePerRunBytes: averagePerRunBytes,
            points: points,
            topClients: topClients,
            recentRecords: sortedDesc
        )
    }
}
