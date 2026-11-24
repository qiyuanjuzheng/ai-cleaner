import AICleanerCore
import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarSelection: Hashable, Sendable {
    case allClients
    case history
    case client(String)
}

enum ItemAgeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部时间"
    case olderThan7Days = "7 天前"
    case olderThan30Days = "30 天前"
    case olderThan90Days = "90 天前"

    var id: String { rawValue }

    func cutoffDate(relativeTo now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .all:
            return nil
        case .olderThan7Days:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .olderThan30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .olderThan90Days:
            return calendar.date(byAdding: .day, value: -90, to: now)
        }
    }
}

enum ItemSortOrder: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending = "按体积从大到小"
    case sizeAscending = "按体积从小到大"
    case modifiedDescending = "按修改时间最新"
    case modifiedAscending = "按修改时间最早"
    case nameAscending = "按名称排序"

    var id: String { rawValue }
}

/// 单条扫描结果的预格式化展示数据（在后台线程一次性生成，杜绝列表渲染期加锁格式化或拼接字符串）
struct PreparedItemPresentation: Sendable {
    let sizeText: String
    let dateText: String
    let abbreviatedPath: String
    let rowTooltip: String
    let searchableLowercased: String

    static func make(for item: CleanableItem, homeDirectory: URL) -> PreparedItemPresentation {
        let sizeText = CleanerFormatting.formatBytes(item.sizeBytes)
        let dateText = CleanerFormatting.formatDate(item.modifiedAt)
        let abbreviatedPath = CleanerFormatting.abbreviatePath(item.url, homeDirectory: homeDirectory)
        let rowTooltip = "\(item.safetyNote)\n路径：\(abbreviatedPath)"
        let searchable = [
            item.displayName,
            item.fileName,
            item.url.path,
            item.clientName,
            item.category.displayName,
            item.recommendation.displayName,
            item.safetyNote
        ]
        .joined(separator: "\u{1F}")
        .lowercased()

        return PreparedItemPresentation(
            sizeText: sizeText,
            dateText: dateText,
            abbreviatedPath: abbreviatedPath,
            rowTooltip: rowTooltip,
            searchableLowercased: searchable
        )
    }
}

/// 侧边栏客户端行预计算模型（切换选中态时 O(1) 读取，不重复格式化或遍历条目）
struct SidebarClientEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let cleanableBytes: Int64
    let cleanableBytesText: String
    let protectedBytes: Int64
    let symbolName: String
    let accentToken: String
    let customDirectoryID: UUID?
}

/// 扁平虚拟化列表中的分组头行模型
struct SectionHeaderRow: Equatable, Sendable {
    let recommendation: CleanupRecommendation
    let itemCount: Int
    let totalBytes: Int64
    let totalBytesText: String
    let isCollapsed: Bool
    let isFirstSection: Bool
}

/// 扁平虚拟化列表中的单条文件行模型（纯值类型，供 `ItemRowContent: Equatable` 跳过无变化行重绘）
struct ItemDisplayRow: Equatable, Sendable {
    let id: String
    let item: CleanableItem
    let sizeText: String
    let dateText: String
    let abbreviatedPath: String
    let rowTooltip: String
    let showClientBadge: Bool
    let relativeSizeFraction: Double
    let position: RowCardPosition
}

/// 单层扁平 LazyVStack 行元素（彻底消除嵌套 ForEach 导致的跨标签大规模 diff）
enum FlatListRow: Identifiable, Equatable, Sendable {
    case sectionHeader(SectionHeaderRow)
    case item(ItemDisplayRow)

    var id: String {
        switch self {
        case let .sectionHeader(header):
            return "header::\(header.recommendation.rawValue)"
        case let .item(row):
            return "item::\(row.id)"
        }
    }
}

@MainActor
@Observable
final class CleanerViewModel {
    // MARK: - Core Services
    private let scanEngine: ScanEngine
    private let trashCleaner: TrashCleaner
    private let customDirectoryStore: CustomDirectoryStore
    private let historyStore: CleanupHistoryStore
    private let safetyGuard: SafetyGuard

    // MARK: - Nested Display & Cache Types

    struct RecommendationSection: Identifiable, Sendable {
        let recommendation: CleanupRecommendation
        let items: [CleanableItem]
        let totalBytes: Int64

        var id: CleanupRecommendation { recommendation }
    }

    struct SelectedClientGroup: Identifiable {
        let id: String
        let clientName: String
        let items: [CleanableItem]
        let totalBytes: Int64
    }

    private struct CachedScopeData: Sendable {
        let activeSummary: ClientScanSummary?
        let headerTitle: String
        let headerSubtitle: String
        let scopedCleanableItems: [CleanableItem]
        let scopedProtectedItems: [CleanableItem]
        let scopedItems: [CleanableItem]
        let scopedRecommendedItems: [CleanableItem]
        let scopedReviewSuggestedItems: [CleanableItem]
        let scopedRecommendedBytes: Int64
        let scopedReviewSuggestedBytes: Int64
        let scopedProtectedBytes: Int64
        let scopedTotalFootprintBytes: Int64
        let categoryCounts: [ScanCategory: Int]
        let defaultSortedItems: [CleanableItem]
        let defaultCleanableItems: [CleanableItem]
        let defaultSections: [RecommendationSection]
        let defaultMaxBytes: Int64
        let defaultFlatRows: [FlatListRow]
    }

    private struct PreparedReportBundle: Sendable {
        let report: ScanReport
        let builtInSummaries: [ClientScanSummary]
        let customSummaries: [ClientScanSummary]
        let builtInSidebarEntries: [SidebarClientEntry]
        let customSidebarEntries: [SidebarClientEntry]
        let reportTotalBytesText: String
        let reportScannedTimeText: String
        let clientSummaryByID: [String: ClientScanSummary]
        let allDisplayedItemsByID: [String: CleanableItem]
        let presentationByID: [String: PreparedItemPresentation]
        let scopeCache: [SidebarSelection: CachedScopeData]
    }

    // MARK: - Published Source State
    var report: ScanReport? {
        didSet {
            guard !suppressCacheRebuild else { return }
            if let report {
                let bundle = Self.buildPreparedReportBundle(
                    from: report,
                    homeDirectory: scanEngine.homeDirectory
                )
                applyPreparedReportBundle(bundle)
            } else {
                clearReportCaches()
            }
        }
    }
    var customDirectories: [CustomScanDirectory] = []
    var historyRecords: [CleanupHistoryRecord] = [] {
        didSet {
            guard !suppressCacheRebuild else { return }
            rebuildHistoryCache()
        }
    }
    var historyRange: CleanupTrendRange = .days30 {
        didSet {
            guard !suppressCacheRebuild else { return }
            rebuildHistoryCache()
        }
    }
    var historyMetricMode: CleanupTrendMetricMode = .cumulative

    var sidebarSelection: SidebarSelection = .allClients {
        didSet {
            guard !suppressCacheRebuild, oldValue != sidebarSelection else { return }
            if sidebarSelection == .history {
                return
            }
            // 从历史趋势页返回刚才浏览的同一个客户端标签时，零重建直接瞬时恢复
            if sidebarSelection == activeListScopeSelection && hasAppliedCurrentScope {
                return
            }
            activeListScopeSelection = sidebarSelection
            applyScope(for: sidebarSelection, resetViewport: true)
        }
    }

    var searchText: String = "" {
        didSet {
            guard !suppressCacheRebuild, oldValue != searchText else { return }
            rebuildFilterCache(resetViewport: true)
        }
    }
    var selectedCategory: ScanCategory? = nil {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedCategory else { return }
            rebuildFilterCache(resetViewport: true)
        }
    }
    var selectedRecommendation: CleanupRecommendation? = nil {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedRecommendation else { return }
            rebuildFilterCache(resetViewport: true)
        }
    }
    var selectedAgeFilter: ItemAgeFilter = .all {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedAgeFilter else { return }
            rebuildFilterCache(resetViewport: true)
        }
    }
    var sortOrder: ItemSortOrder = .sizeDescending {
        didSet {
            guard !suppressCacheRebuild, oldValue != sortOrder else { return }
            rebuildFilterCache(resetViewport: true)
        }
    }
    var selectedItemIDs: Set<String> = [] {
        didSet {
            guard !suppressCacheRebuild else { return }
            rebuildSelectionCache()
        }
    }
    var collapsedSections: Set<CleanupRecommendation> = CleanerViewModel.defaultCollapsedSections {
        didSet {
            guard !suppressCacheRebuild, oldValue != collapsedSections else { return }
            rebuildDisplayedRows(resetViewport: false)
        }
    }

    var isScanning: Bool = false
    var isCleaning: Bool = false
    var showingTrashConfirmation: Bool = false
    var showingAddCustomSheet: Bool = false
    /// 当用户尝试手动勾选一条「不建议清理」项时，先暂存到此触发风险确认弹窗
    var pendingRiskItemToSelect: CleanableItem? = nil

    var appearanceMode: AppAppearanceMode = .light {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceStorageKey)
        }
    }
    var cleanupCelebrationID: UUID = UUID()

    var lastCleanupResult: CleanupResult?
    var errorBannerMessage: String?

    // MARK: - Memoized Derived Caches (O(1) Reads During SwiftUI Body Evaluation)

    private(set) var builtInSummaries: [ClientScanSummary] = []
    private(set) var customSummaries: [ClientScanSummary] = []
    private(set) var builtInSidebarEntries: [SidebarClientEntry] = []
    private(set) var customSidebarEntries: [SidebarClientEntry] = []
    private(set) var reportTotalBytesText: String = "0 B"
    private(set) var reportScannedTimeText: String = ""

    private(set) var activeSummary: ClientScanSummary? = nil
    private(set) var headerTitleText: String = "全部 AI 客户端"
    private(set) var headerSubtitleText: String = "只读扫描本机 AI 客户端空间占用"

    private(set) var scopedCleanableItems: [CleanableItem] = []
    private(set) var scopedProtectedItems: [CleanableItem] = []
    private(set) var scopedItems: [CleanableItem] = []

    private(set) var scopedRecommendedItems: [CleanableItem] = []
    private(set) var scopedReviewSuggestedItems: [CleanableItem] = []
    private(set) var scopedRecommendedBytes: Int64 = 0
    private(set) var scopedReviewSuggestedBytes: Int64 = 0
    private(set) var scopedProtectedBytes: Int64 = 0
    private(set) var scopedTotalFootprintBytes: Int64 = 0
    private(set) var categoryCounts: [ScanCategory: Int] = [:]

    private(set) var filteredItems: [CleanableItem] = []
    private(set) var filteredCleanableItems: [CleanableItem] = []
    private(set) var displayedSections: [RecommendationSection] = []
    private(set) var displayedRows: [FlatListRow] = []
    private(set) var maxDisplayedItemBytes: Int64 = 0
    /// 仅在切换标签 / 筛选 / 排序时递增，让 ScrollView 瞬时重置顶部并彻底跳过千级条目 Collection Diff
    private(set) var listViewportID: Int = 0

    private(set) var selectedItems: [CleanableItem] = []
    private(set) var selectedTotalBytes: Int64 = 0
    private(set) var selectedNotRecommendedItems: [CleanableItem] = []
    private(set) var selectedNotRecommendedTotalBytes: Int64 = 0
    private(set) var groupedSelectedItems: [SelectedClientGroup] = []

    private(set) var historySummary: CleanupHistorySummary = CleanupHistoryAnalytics.summarize(records: [], range: .days30)
    private(set) var totalHistoricalFreedBytes: Int64 = 0
    private(set) var totalHistoricalFreedBytesText: String = "0 B"

    // MARK: - Internal Non-Observed Indexes

    @ObservationIgnored private var allDisplayedItemsByID: [String: CleanableItem] = [:]
    @ObservationIgnored private var clientSummaryByID: [String: ClientScanSummary] = [:]
    @ObservationIgnored private var presentationByID: [String: PreparedItemPresentation] = [:]
    @ObservationIgnored private var scopeCache: [SidebarSelection: CachedScopeData] = [:]
    @ObservationIgnored private var activeListScopeSelection: SidebarSelection = .allClients
    @ObservationIgnored private var hasAppliedCurrentScope: Bool = false
    @ObservationIgnored private var suppressCacheRebuild: Bool = false
    @ObservationIgnored nonisolated private static let defaultCollapsedSections: Set<CleanupRecommendation> = [.notRecommended]
    @ObservationIgnored private static let appearanceStorageKey = "aiCleaner.appearanceMode.v2"
    @ObservationIgnored private static let builtInVisualLookup: [String: (symbolName: String, tint: Color)] = {
        Dictionary(
            uniqueKeysWithValues: BuiltInClientRules.allProfiles.map { profile in
                (profile.id, (profile.symbolName, AppTheme.color(forAccentToken: profile.accentToken)))
            }
        )
    }()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        customDirectoryStore: CustomDirectoryStore? = nil,
        historyStore: CleanupHistoryStore? = nil
    ) {
        let guardInstance = SafetyGuard(homeDirectory: homeDirectory)
        self.safetyGuard = guardInstance
        self.scanEngine = ScanEngine(homeDirectory: homeDirectory, safetyGuard: guardInstance)
        self.trashCleaner = TrashCleaner(safetyGuard: guardInstance)
        self.customDirectoryStore = customDirectoryStore ?? CustomDirectoryStore(safetyGuard: guardInstance)
        self.historyStore = historyStore ?? CleanupHistoryStore()

        self.suppressCacheRebuild = true
        self.customDirectories = self.customDirectoryStore.load()
        self.historyRecords = self.historyStore.load()
        if let savedRaw = UserDefaults.standard.string(forKey: Self.appearanceStorageKey),
           let savedMode = AppAppearanceMode(rawValue: savedRaw) {
            self.appearanceMode = savedMode
        } else {
            self.appearanceMode = .light
        }
        self.suppressCacheRebuild = false

        rebuildHistoryCache()
    }

    // MARK: - Lightweight Derived Accessors

    var activeAccentColor: Color {
        if sidebarSelection == .history {
            return Color(red: 0.14, green: 0.80, blue: 0.66)
        }
        if let summary = activeSummary {
            return AppTheme.color(forAccentToken: summary.profile.accentToken)
        }
        return Color(red: 0.16, green: 0.78, blue: 0.64)
    }

    var scopedCleanableBytes: Int64 {
        scopedRecommendedBytes + scopedReviewSuggestedBytes
    }

    var hasSelectedNotRecommendedItems: Bool {
        !selectedNotRecommendedItems.isEmpty
    }

    var allVisibleSelected: Bool {
        guard !filteredCleanableItems.isEmpty else { return false }
        return filteredCleanableItems.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    var visibleSelectedCount: Int {
        filteredItems.reduce(0) { $0 + (selectedItemIDs.contains($1.id) ? 1 : 0) }
    }

    var hasScanResults: Bool {
        report != nil
    }

    var isIdleReadyToScan: Bool {
        report == nil && !isScanning
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || selectedCategory != nil || selectedRecommendation != nil || selectedAgeFilter != .all
    }

    // MARK: - Off-Main-Thread Report & Scope Precomputation

    private nonisolated static func buildPreparedReportBundle(
        from report: ScanReport,
        homeDirectory: URL
    ) -> PreparedReportBundle {
        var builtIn: [ClientScanSummary] = []
        var custom: [ClientScanSummary] = []
        var builtInEntries: [SidebarClientEntry] = []
        var customEntries: [SidebarClientEntry] = []
        var summaryMap: [String: ClientScanSummary] = [:]
        summaryMap.reserveCapacity(report.clientSummaries.count)

        for summary in report.clientSummaries {
            summaryMap[summary.id] = summary
            let entry = SidebarClientEntry(
                id: summary.id,
                title: summary.profile.name,
                cleanableBytes: summary.totalSizeBytes,
                cleanableBytesText: summary.totalSizeBytes > 0 ? CleanerFormatting.formatBytes(summary.totalSizeBytes) : "",
                protectedBytes: summary.protectedSizeBytes,
                symbolName: summary.profile.symbolName,
                accentToken: summary.profile.accentToken,
                customDirectoryID: summary.profile.customDirectoryID
            )
            if summary.profile.isCustom {
                custom.append(summary)
                customEntries.append(entry)
            } else {
                builtIn.append(summary)
                builtInEntries.append(entry)
            }
        }

        let allCleanable = report.allItems
        let allProtected = report.allProtectedItems
        var itemMap: [String: CleanableItem] = [:]
        var presentationMap: [String: PreparedItemPresentation] = [:]
        let estimatedTotal = allCleanable.count + allProtected.count
        itemMap.reserveCapacity(estimatedTotal)
        presentationMap.reserveCapacity(estimatedTotal)

        for item in allCleanable where itemMap[item.id] == nil {
            itemMap[item.id] = item
            presentationMap[item.id] = PreparedItemPresentation.make(for: item, homeDirectory: homeDirectory)
        }
        for item in allProtected where itemMap[item.id] == nil {
            itemMap[item.id] = item
            presentationMap[item.id] = PreparedItemPresentation.make(for: item, homeDirectory: homeDirectory)
        }

        // 一次性预构建「全部 AI 客户端」与每个客户端的默认作用域快照（含预排序分组与扁平展示行）
        var scopeCache: [SidebarSelection: CachedScopeData] = [:]
        scopeCache.reserveCapacity(report.clientSummaries.count + 1)

        scopeCache[.allClients] = buildScopeData(
            selection: .allClients,
            report: report,
            summary: nil,
            cleanable: allCleanable,
            protected: allProtected,
            presentations: presentationMap,
            homeDirectory: homeDirectory
        )

        for summary in report.clientSummaries {
            scopeCache[.client(summary.id)] = buildScopeData(
                selection: .client(summary.id),
                report: report,
                summary: summary,
                cleanable: summary.items,
                protected: summary.protectedItems,
                presentations: presentationMap,
                homeDirectory: homeDirectory
            )
        }

        return PreparedReportBundle(
            report: report,
            builtInSummaries: builtIn,
            customSummaries: custom,
            builtInSidebarEntries: builtInEntries,
            customSidebarEntries: customEntries,
            reportTotalBytesText: report.totalSizeBytes > 0 ? CleanerFormatting.formatBytes(report.totalSizeBytes) : "",
            reportScannedTimeText: CleanerFormatting.formatTime(report.scannedAt),
            clientSummaryByID: summaryMap,
            allDisplayedItemsByID: itemMap,
            presentationByID: presentationMap,
            scopeCache: scopeCache
        )
    }

    private nonisolated static func buildScopeData(
        selection: SidebarSelection,
        report: ScanReport,
        summary: ClientScanSummary?,
        cleanable: [CleanableItem],
        protected: [CleanableItem],
        presentations: [String: PreparedItemPresentation],
        homeDirectory: URL
    ) -> CachedScopeData {
        var combined: [CleanableItem] = []
        combined.reserveCapacity(cleanable.count + protected.count)
        combined.append(contentsOf: cleanable)
        combined.append(contentsOf: protected)

        var recItems: [CleanableItem] = []
        var revItems: [CleanableItem] = []
        var recBytes: Int64 = 0
        var revBytes: Int64 = 0
        var proBytes: Int64 = 0
        var counts: [ScanCategory: Int] = [:]

        for item in cleanable {
            counts[item.category, default: 0] += 1
            if item.recommendation == .recommended {
                recItems.append(item)
                recBytes += item.sizeBytes
            } else {
                revItems.append(item)
                revBytes += item.sizeBytes
            }
        }
        for item in protected {
            counts[item.category, default: 0] += 1
            proBytes += item.sizeBytes
        }

        let sorted = sortItems(combined, by: .sizeDescending)
        let (defaultCleanable, defaultSections, defaultMaxBytes) = bucketItems(sorted)
        let showClientBadge = (selection == .allClients)
        let defaultFlatRows = buildFlatRows(
            from: defaultSections,
            maxBytes: defaultMaxBytes,
            showClientBadge: showClientBadge,
            selectedRecommendation: nil,
            collapsedSections: defaultCollapsedSections,
            presentations: presentations,
            homeDirectory: homeDirectory
        )

        let headerTitle = summary?.profile.name ?? "全部 AI 客户端"
        let headerSubtitle: String
        if let summary {
            headerSubtitle = "\(summary.profile.description) · 总占用 \(CleanerFormatting.formatBytes(summary.totalDiskFootprintBytes))"
        } else {
            headerSubtitle = "已识别 \(report.detectedBuiltInClientsCount) 款 AI 客户端 · 总占用 \(CleanerFormatting.formatBytes(report.totalDiskFootprintBytes))"
        }

        return CachedScopeData(
            activeSummary: summary,
            headerTitle: headerTitle,
            headerSubtitle: headerSubtitle,
            scopedCleanableItems: cleanable,
            scopedProtectedItems: protected,
            scopedItems: combined,
            scopedRecommendedItems: recItems,
            scopedReviewSuggestedItems: revItems,
            scopedRecommendedBytes: recBytes,
            scopedReviewSuggestedBytes: revBytes,
            scopedProtectedBytes: proBytes,
            scopedTotalFootprintBytes: recBytes + revBytes + proBytes,
            categoryCounts: counts,
            defaultSortedItems: sorted,
            defaultCleanableItems: defaultCleanable,
            defaultSections: defaultSections,
            defaultMaxBytes: defaultMaxBytes,
            defaultFlatRows: defaultFlatRows
        )
    }

    private nonisolated static func sortItems(_ items: [CleanableItem], by order: ItemSortOrder) -> [CleanableItem] {
        items.sorted { lhs, rhs in
            switch order {
            case .sizeDescending:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.modifiedAt > rhs.modifiedAt
            case .sizeAscending:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
                return lhs.modifiedAt < rhs.modifiedAt
            case .modifiedDescending:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.sizeBytes > rhs.sizeBytes
            case .modifiedAscending:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
                return lhs.sizeBytes > rhs.sizeBytes
            case .nameAscending:
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private nonisolated static func bucketItems(
        _ sorted: [CleanableItem]
    ) -> (cleanable: [CleanableItem], sections: [RecommendationSection], maxBytes: Int64) {
        var cleanable: [CleanableItem] = []
        cleanable.reserveCapacity(sorted.count)
        var maxBytes: Int64 = 0
        var recBucket: [CleanableItem] = []
        var revBucket: [CleanableItem] = []
        var proBucket: [CleanableItem] = []
        var recTotal: Int64 = 0
        var revTotal: Int64 = 0
        var proTotal: Int64 = 0

        for item in sorted {
            if item.sizeBytes > maxBytes {
                maxBytes = item.sizeBytes
            }
            if item.isCleanable {
                cleanable.append(item)
            }
            switch item.recommendation {
            case .recommended:
                recBucket.append(item)
                recTotal += item.sizeBytes
            case .reviewSuggested:
                revBucket.append(item)
                revTotal += item.sizeBytes
            case .notRecommended:
                proBucket.append(item)
                proTotal += item.sizeBytes
            }
        }

        var sections: [RecommendationSection] = []
        sections.reserveCapacity(3)
        if !recBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .recommended, items: recBucket, totalBytes: recTotal))
        }
        if !revBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .reviewSuggested, items: revBucket, totalBytes: revTotal))
        }
        if !proBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .notRecommended, items: proBucket, totalBytes: proTotal))
        }
        return (cleanable, sections, maxBytes)
    }

    private nonisolated static func buildFlatRows(
        from sections: [RecommendationSection],
        maxBytes: Int64,
        showClientBadge: Bool,
        selectedRecommendation: CleanupRecommendation?,
        collapsedSections: Set<CleanupRecommendation>,
        presentations: [String: PreparedItemPresentation],
        homeDirectory: URL
    ) -> [FlatListRow] {
        guard !sections.isEmpty else { return [] }
        let safeMaxBytes = Double(max(1, maxBytes))
        let totalVisibleEstimate = sections.reduce(sections.count) { partial, section in
            let collapsed = (sections.count > 1 && selectedRecommendation != section.recommendation)
                && collapsedSections.contains(section.recommendation)
            return partial + (collapsed ? 0 : section.items.count)
        }

        var rows: [FlatListRow] = []
        rows.reserveCapacity(totalVisibleEstimate)

        for (sectionIndex, section) in sections.enumerated() {
            let isCollapsed = (sections.count > 1 && selectedRecommendation != section.recommendation)
                && collapsedSections.contains(section.recommendation)

            rows.append(
                .sectionHeader(
                    SectionHeaderRow(
                        recommendation: section.recommendation,
                        itemCount: section.items.count,
                        totalBytes: section.totalBytes,
                        totalBytesText: CleanerFormatting.formatBytes(section.totalBytes),
                        isCollapsed: isCollapsed,
                        isFirstSection: sectionIndex == 0
                    )
                )
            )

            guard !isCollapsed else { continue }

            let count = section.items.count
            for (index, item) in section.items.enumerated() {
                let position: RowCardPosition
                if count == 1 {
                    position = .single
                } else if index == 0 {
                    position = .first
                } else if index == count - 1 {
                    position = .last
                } else {
                    position = .middle
                }

                let presentation = presentations[item.id]
                    ?? PreparedItemPresentation.make(for: item, homeDirectory: homeDirectory)

                rows.append(
                    .item(
                        ItemDisplayRow(
                            id: item.id,
                            item: item,
                            sizeText: presentation.sizeText,
                            dateText: presentation.dateText,
                            abbreviatedPath: presentation.abbreviatedPath,
                            rowTooltip: presentation.rowTooltip,
                            showClientBadge: showClientBadge,
                            relativeSizeFraction: Double(item.sizeBytes) / safeMaxBytes,
                            position: position
                        )
                    )
                )
            }
        }
        return rows
    }

    // MARK: - Main-Thread Cache Application (O(1) Scope Switch)

    private func applyPreparedReportBundle(_ bundle: PreparedReportBundle) {
        builtInSummaries = bundle.builtInSummaries
        customSummaries = bundle.customSummaries
        builtInSidebarEntries = bundle.builtInSidebarEntries
        customSidebarEntries = bundle.customSidebarEntries
        reportTotalBytesText = bundle.reportTotalBytesText
        reportScannedTimeText = bundle.reportScannedTimeText
        clientSummaryByID = bundle.clientSummaryByID
        allDisplayedItemsByID = bundle.allDisplayedItemsByID
        presentationByID = bundle.presentationByID
        scopeCache = bundle.scopeCache

        let targetScope: SidebarSelection = (sidebarSelection == .history) ? activeListScopeSelection : sidebarSelection
        activeListScopeSelection = targetScope
        applyScope(for: targetScope, resetViewport: true)
        rebuildSelectionCache()
    }

    private func clearReportCaches() {
        builtInSummaries = []
        customSummaries = []
        builtInSidebarEntries = []
        customSidebarEntries = []
        reportTotalBytesText = "0 B"
        reportScannedTimeText = ""
        clientSummaryByID = [:]
        allDisplayedItemsByID = [:]
        presentationByID = [:]
        scopeCache = [:]
        activeListScopeSelection = .allClients
        hasAppliedCurrentScope = false

        activeSummary = nil
        headerTitleText = "全部 AI 客户端"
        headerSubtitleText = "只读扫描本机 AI 客户端空间占用"
        scopedCleanableItems = []
        scopedProtectedItems = []
        scopedItems = []
        scopedRecommendedItems = []
        scopedReviewSuggestedItems = []
        scopedRecommendedBytes = 0
        scopedReviewSuggestedBytes = 0
        scopedProtectedBytes = 0
        scopedTotalFootprintBytes = 0
        categoryCounts = [:]
        filteredItems = []
        filteredCleanableItems = []
        displayedSections = []
        displayedRows = []
        maxDisplayedItemBytes = 0
        listViewportID &+= 1
        rebuildSelectionCache()
    }

    private func applyScope(for selection: SidebarSelection, resetViewport: Bool) {
        guard let cached = scopeCache[selection] ?? scopeCache[.allClients] else {
            hasAppliedCurrentScope = false
            activeSummary = nil
            headerTitleText = "全部 AI 客户端"
            headerSubtitleText = "只读扫描本机 AI 客户端空间占用"
            scopedCleanableItems = []
            scopedProtectedItems = []
            scopedItems = []
            scopedRecommendedItems = []
            scopedReviewSuggestedItems = []
            scopedRecommendedBytes = 0
            scopedReviewSuggestedBytes = 0
            scopedProtectedBytes = 0
            scopedTotalFootprintBytes = 0
            categoryCounts = [:]
            filteredItems = []
            filteredCleanableItems = []
            displayedSections = []
            displayedRows = []
            maxDisplayedItemBytes = 0
            if resetViewport { listViewportID &+= 1 }
            return
        }

        hasAppliedCurrentScope = true
        activeSummary = cached.activeSummary
        headerTitleText = cached.headerTitle
        headerSubtitleText = cached.headerSubtitle
        scopedCleanableItems = cached.scopedCleanableItems
        scopedProtectedItems = cached.scopedProtectedItems
        scopedItems = cached.scopedItems
        scopedRecommendedItems = cached.scopedRecommendedItems
        scopedReviewSuggestedItems = cached.scopedReviewSuggestedItems
        scopedRecommendedBytes = cached.scopedRecommendedBytes
        scopedReviewSuggestedBytes = cached.scopedReviewSuggestedBytes
        scopedProtectedBytes = cached.scopedProtectedBytes
        scopedTotalFootprintBytes = cached.scopedTotalFootprintBytes
        categoryCounts = cached.categoryCounts

        // O(1) 零排序快速通道：默认筛选与默认排序下直接复用预构建快照
        if !hasActiveFilters && sortOrder == .sizeDescending {
            filteredItems = cached.defaultSortedItems
            filteredCleanableItems = cached.defaultCleanableItems
            displayedSections = cached.defaultSections
            maxDisplayedItemBytes = cached.defaultMaxBytes

            if collapsedSections == Self.defaultCollapsedSections {
                displayedRows = cached.defaultFlatRows
                if resetViewport { listViewportID &+= 1 }
            } else {
                rebuildDisplayedRows(resetViewport: resetViewport)
            }
            return
        }

        rebuildFilterCache(resetViewport: resetViewport)
    }

    private func rebuildFilterCache(resetViewport: Bool) {
        let currentScope = scopeCache[activeListScopeSelection] ?? scopeCache[.allClients]

        // 若筛选已清空且为默认排序，直接走 O(1) 缓存命中
        if !hasActiveFilters && sortOrder == .sizeDescending, let currentScope {
            filteredItems = currentScope.defaultSortedItems
            filteredCleanableItems = currentScope.defaultCleanableItems
            displayedSections = currentScope.defaultSections
            maxDisplayedItemBytes = currentScope.defaultMaxBytes
            if collapsedSections == Self.defaultCollapsedSections {
                displayedRows = currentScope.defaultFlatRows
                if resetViewport { listViewportID &+= 1 }
            } else {
                rebuildDisplayedRows(resetViewport: resetViewport)
            }
            return
        }

        let lowerQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ageCutoff = selectedAgeFilter.cutoffDate()

        // 当排序为默认「体积降序」时，直接遍历已排好序的 `defaultSortedItems`，过滤即有序，彻底跳过 O(N log N) 排序
        let sourceItems = (sortOrder == .sizeDescending)
            ? (currentScope?.defaultSortedItems ?? scopedItems)
            : scopedItems

        let filtered: [CleanableItem]
        if lowerQuery.isEmpty && selectedRecommendation == nil && selectedCategory == nil && ageCutoff == nil {
            filtered = sourceItems
        } else {
            filtered = sourceItems.filter { item in
                if let selectedRecommendation, item.recommendation != selectedRecommendation {
                    return false
                }
                if let selectedCategory, item.category != selectedCategory {
                    return false
                }
                if let ageCutoff {
                    if !item.isCleanable || item.modifiedAt >= ageCutoff {
                        return false
                    }
                }
                if lowerQuery.isEmpty {
                    return true
                }
                if let presentation = presentationByID[item.id] {
                    return presentation.searchableLowercased.contains(lowerQuery)
                }
                return item.displayName.localizedCaseInsensitiveContains(lowerQuery)
                    || item.fileName.localizedCaseInsensitiveContains(lowerQuery)
                    || item.url.path.localizedCaseInsensitiveContains(lowerQuery)
            }
        }

        let sorted: [CleanableItem]
        if sortOrder == .sizeDescending && currentScope != nil {
            sorted = filtered
        } else {
            sorted = Self.sortItems(filtered, by: sortOrder)
        }

        let (cleanable, sections, maxBytes) = Self.bucketItems(sorted)
        filteredItems = sorted
        filteredCleanableItems = cleanable
        displayedSections = sections
        maxDisplayedItemBytes = maxBytes

        rebuildDisplayedRows(resetViewport: resetViewport)
    }

    private func rebuildDisplayedRows(resetViewport: Bool) {
        let showClientBadge = (activeListScopeSelection == .allClients)
        displayedRows = Self.buildFlatRows(
            from: displayedSections,
            maxBytes: maxDisplayedItemBytes,
            showClientBadge: showClientBadge,
            selectedRecommendation: selectedRecommendation,
            collapsedSections: collapsedSections,
            presentations: presentationByID,
            homeDirectory: scanEngine.homeDirectory
        )
        if resetViewport {
            listViewportID &+= 1
        }
    }

    private func rebuildSelectionCache() {
        guard !selectedItemIDs.isEmpty else {
            selectedItems = []
            selectedTotalBytes = 0
            selectedNotRecommendedItems = []
            selectedNotRecommendedTotalBytes = 0
            groupedSelectedItems = []
            return
        }

        let resolved = selectedItemIDs.compactMap { allDisplayedItemsByID[$0] }
            .sorted { lhs, rhs in
                if lhs.recommendation == .notRecommended && rhs.recommendation != .notRecommended {
                    return true
                }
                if lhs.recommendation != .notRecommended && rhs.recommendation == .notRecommended {
                    return false
                }
                if lhs.clientName != rhs.clientName {
                    return lhs.clientName.localizedCaseInsensitiveCompare(rhs.clientName) == .orderedAscending
                }
                return lhs.sizeBytes > rhs.sizeBytes
            }

        var totalBytes: Int64 = 0
        var riskItems: [CleanableItem] = []
        var riskBytes: Int64 = 0
        var byClient: [String: (name: String, items: [CleanableItem], bytes: Int64)] = [:]

        for item in resolved {
            totalBytes += item.sizeBytes
            if item.recommendation == .notRecommended {
                riskItems.append(item)
                riskBytes += item.sizeBytes
            }
            var entry = byClient[item.clientID] ?? (item.clientName, [], 0)
            entry.items.append(item)
            entry.bytes += item.sizeBytes
            byClient[item.clientID] = entry
        }

        selectedItems = resolved
        selectedTotalBytes = totalBytes
        selectedNotRecommendedItems = riskItems
        selectedNotRecommendedTotalBytes = riskBytes
        groupedSelectedItems = byClient.map { clientID, val in
            SelectedClientGroup(id: clientID, clientName: val.name, items: val.items, totalBytes: val.bytes)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    private func rebuildHistoryCache() {
        let total = historyRecords.reduce(0) { $0 + $1.freedBytes }
        totalHistoricalFreedBytes = total
        totalHistoricalFreedBytesText = total > 0 ? CleanerFormatting.formatBytes(total) : ""
        historySummary = CleanupHistoryAnalytics.summarize(records: historyRecords, range: historyRange)
    }

    // MARK: - Actions

    /// 由用户主动触发扫描（从待扫描首页、工具栏或菜单启动）
    func startScan() {
        if sidebarSelection == .history {
            sidebarSelection = .allClients
        }
        rescan()
    }

    /// 取消当前正在进行的扫描任务
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// 从扫描结果页返回初始「待扫描」状态（保留历史清理统计与自定义目录配置）
    func returnToIdleState() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false

        suppressCacheRebuild = true
        report = nil
        selectedItemIDs.removeAll()
        lastCleanupResult = nil
        errorBannerMessage = nil
        pendingRiskItemToSelect = nil
        searchText = ""
        selectedCategory = nil
        selectedRecommendation = nil
        selectedAgeFilter = .all
        collapsedSections = Self.defaultCollapsedSections
        sidebarSelection = .allClients
        suppressCacheRebuild = false

        clearReportCaches()
    }

    func rescan() {
        scanTask?.cancel()
        isScanning = true
        errorBannerMessage = nil

        let engine = scanEngine
        let customDirs = customDirectories
        let homeDir = scanEngine.homeDirectory

        scanTask = Task {
            let bundle = await Task.detached(priority: .userInitiated) {
                let newReport = engine.scan(customDirectories: customDirs)
                return Self.buildPreparedReportBundle(from: newReport, homeDirectory: homeDir)
            }.value

            guard !Task.isCancelled else { return }

            let validIDs = Set(bundle.allDisplayedItemsByID.keys)
            self.suppressCacheRebuild = true
            self.report = bundle.report
            self.isScanning = false
            self.selectedItemIDs.formIntersection(validIDs)

            if case let .client(clientID) = self.sidebarSelection,
               bundle.clientSummaryByID[clientID] == nil {
                self.sidebarSelection = .allClients
            }
            if case let .client(clientID) = self.activeListScopeSelection,
               bundle.clientSummaryByID[clientID] == nil {
                self.activeListScopeSelection = .allClients
            }
            self.suppressCacheRebuild = false

            self.applyPreparedReportBundle(bundle)
        }
    }

    func toggleRecommendationFilter(_ recommendation: CleanupRecommendation) {
        suppressCacheRebuild = true
        if selectedRecommendation == recommendation {
            selectedRecommendation = nil
        } else {
            selectedRecommendation = recommendation
            collapsedSections.remove(recommendation)
        }
        suppressCacheRebuild = false
        rebuildFilterCache(resetViewport: true)
    }

    func isSectionCollapsed(_ recommendation: CleanupRecommendation) -> Bool {
        if displayedSections.count <= 1 || selectedRecommendation == recommendation {
            return false
        }
        return collapsedSections.contains(recommendation)
    }

    func toggleSectionCollapsed(_ recommendation: CleanupRecommendation) {
        if collapsedSections.contains(recommendation) {
            collapsedSections.remove(recommendation)
        } else {
            collapsedSections.insert(recommendation)
        }
    }

    func clearAllFilters() {
        suppressCacheRebuild = true
        searchText = ""
        selectedCategory = nil
        selectedRecommendation = nil
        selectedAgeFilter = .all
        suppressCacheRebuild = false
        rebuildFilterCache(resetViewport: true)
    }

    func toggleSelection(for item: CleanableItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
            return
        }
        if item.isCleanable {
            selectedItemIDs.insert(item.id)
        } else {
            // 「不建议清理」项绝不静默勾选，弹出单条风险提醒确认后再允许加入清单
            pendingRiskItemToSelect = item
        }
    }

    func confirmRiskItemSelection(_ item: CleanableItem) {
        selectedItemIDs.insert(item.id)
        pendingRiskItemToSelect = nil
    }

    func cancelRiskItemSelection() {
        pendingRiskItemToSelect = nil
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func isSelected(itemID: String) -> Bool {
        selectedItemIDs.contains(itemID)
    }

    /// 一键勾选当前视图下的全部「建议清理」项
    func selectRecommendedInScope() {
        var next = selectedItemIDs
        for item in scopedRecommendedItems where item.isCleanable {
            next.insert(item.id)
        }
        selectedItemIDs = next
    }

    func selectSection(_ recommendation: CleanupRecommendation) {
        guard recommendation.isCleanable else { return }
        var next = selectedItemIDs
        for item in filteredCleanableItems where item.recommendation == recommendation {
            next.insert(item.id)
        }
        selectedItemIDs = next
    }

    func selectAllVisible() {
        var next = selectedItemIDs
        for item in filteredCleanableItems {
            next.insert(item.id)
        }
        selectedItemIDs = next
    }

    func invertVisibleSelection() {
        var next = selectedItemIDs
        for item in filteredCleanableItems {
            if next.contains(item.id) {
                next.remove(item.id)
            } else {
                next.insert(item.id)
            }
        }
        selectedItemIDs = next
    }

    func clearVisibleSelection() {
        var next = selectedItemIDs
        for item in filteredItems {
            next.remove(item.id)
        }
        selectedItemIDs = next
    }

    func clearAllSelection() {
        selectedItemIDs.removeAll()
    }

    func revealInFinder(_ item: CleanableItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: CleanableItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    func validateCustomDirectory(_ url: URL) -> SafetyDecision {
        safetyGuard.validateCustomDirectoryRoot(url)
    }

    func addCustomDirectory(
        url: URL,
        displayName: String,
        category: ScanCategory,
        mode: ScanTargetMode
    ) throws {
        let added = try customDirectoryStore.add(
            url: url,
            displayName: displayName,
            category: category,
            mode: mode
        )
        customDirectories = customDirectoryStore.load()
        sidebarSelection = .client(added.toClientProfile().id)
        rescan()
    }

    func removeCustomDirectory(id: UUID) {
        do {
            customDirectories = try customDirectoryStore.remove(id: id)
            let removedProfileID = "custom-\(id.uuidString)"
            if case let .client(currentID) = sidebarSelection, currentID == removedProfileID {
                sidebarSelection = .allClients
            }
            if hasScanResults {
                rescan()
            }
        } catch {
            errorBannerMessage = "移除自定义目录失败：\(error.localizedDescription)"
        }
    }

    func requestTrashConfirmation() {
        guard !selectedItems.isEmpty, !isCleaning, !isScanning else { return }
        showingTrashConfirmation = true
    }

    func confirmAndTrashSelectedItems(acknowledgedNotRecommendedRisk: Bool = false) {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }
        if hasSelectedNotRecommendedItems && !acknowledgedNotRecommendedRisk {
            return
        }

        isCleaning = true
        errorBannerMessage = nil
        let cleaner = trashCleaner
        let allowOverride = acknowledgedNotRecommendedRisk && hasSelectedNotRecommendedItems

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.trash(items: targets, allowNotRecommendedOverride: allowOverride)
            }.value

            self.lastCleanupResult = result
            if result.trashedCount > 0 {
                self.cleanupCelebrationID = UUID()
                do {
                    _ = try self.historyStore.record(result: result)
                    self.historyRecords = self.historyStore.load()
                } catch {
                    self.errorBannerMessage = "清理已完成，但记录历史统计失败：\(error.localizedDescription)"
                }
            }
            self.isCleaning = false
            self.showingTrashConfirmation = false

            let trashedIDs = Set(result.trashedItems.map(\.id))
            self.selectedItemIDs.subtract(trashedIDs)

            // 清理完成后立即刷新列表，反馈真实剩余空间
            self.rescan()
        }
    }

    func deleteHistoryRecord(id: UUID) {
        do {
            historyRecords = try historyStore.delete(id: id)
        } catch {
            errorBannerMessage = "删除历史统计记录失败：\(error.localizedDescription)"
        }
    }

    func clearAllHistoryRecords() {
        do {
            try historyStore.clearAll()
            historyRecords = []
        } catch {
            errorBannerMessage = "清空历史统计记录失败：\(error.localizedDescription)"
        }
    }

    func clientVisualMeta(for clientID: String) -> (symbolName: String, tint: Color) {
        Self.builtInVisualLookup[clientID] ?? ("folder.fill", Color(red: 0.18, green: 0.78, blue: 0.74))
    }

    func dismissCleanupBanner() {
        lastCleanupResult = nil
    }

    func dismissErrorBanner() {
        errorBannerMessage = nil
    }
}
