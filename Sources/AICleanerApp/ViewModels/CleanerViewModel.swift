import AICleanerCore
import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarSelection: Hashable {
    case allClients
    case history
    case client(String)
}

enum ItemAgeFilter: String, CaseIterable, Identifiable {
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

enum ItemSortOrder: String, CaseIterable, Identifiable {
    case sizeDescending = "按体积从大到小"
    case sizeAscending = "按体积从小到大"
    case modifiedDescending = "按修改时间最新"
    case modifiedAscending = "按修改时间最早"
    case nameAscending = "按名称排序"

    var id: String { rawValue }
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

    // MARK: - Nested Display Types

    struct RecommendationSection: Identifiable {
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

    // MARK: - Published Source State
    var report: ScanReport? {
        didSet {
            guard !suppressCacheRebuild else { return }
            rebuildReportCaches()
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
            if sidebarSelection != .history {
                rebuildScopeCache()
            }
        }
    }

    var searchText: String = "" {
        didSet {
            guard !suppressCacheRebuild, oldValue != searchText else { return }
            rebuildFilterCache()
        }
    }
    var selectedCategory: ScanCategory? = nil {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedCategory else { return }
            rebuildFilterCache()
        }
    }
    var selectedRecommendation: CleanupRecommendation? = nil {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedRecommendation else { return }
            rebuildFilterCache()
        }
    }
    var selectedAgeFilter: ItemAgeFilter = .all {
        didSet {
            guard !suppressCacheRebuild, oldValue != selectedAgeFilter else { return }
            rebuildFilterCache()
        }
    }
    var sortOrder: ItemSortOrder = .sizeDescending {
        didSet {
            guard !suppressCacheRebuild, oldValue != sortOrder else { return }
            rebuildFilterCache()
        }
    }
    var selectedItemIDs: Set<String> = [] {
        didSet {
            guard !suppressCacheRebuild else { return }
            rebuildSelectionCache()
        }
    }
    var collapsedSections: Set<CleanupRecommendation> = [.notRecommended]

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
    private(set) var activeSummary: ClientScanSummary? = nil

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
    private(set) var maxDisplayedItemBytes: Int64 = 0

    private(set) var selectedItems: [CleanableItem] = []
    private(set) var selectedTotalBytes: Int64 = 0
    private(set) var selectedNotRecommendedItems: [CleanableItem] = []
    private(set) var selectedNotRecommendedTotalBytes: Int64 = 0
    private(set) var groupedSelectedItems: [SelectedClientGroup] = []

    private(set) var historySummary: CleanupHistorySummary = CleanupHistoryAnalytics.summarize(records: [], range: .days30)
    private(set) var totalHistoricalFreedBytes: Int64 = 0

    @ObservationIgnored private var allDisplayedItemsByID: [String: CleanableItem] = [:]
    @ObservationIgnored private var clientSummaryByID: [String: ClientScanSummary] = [:]
    @ObservationIgnored private var suppressCacheRebuild: Bool = false
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

    // MARK: - Cache Builders (Single-Pass, Strictly Scoped)

    private func rebuildReportCaches() {
        guard let report else {
            builtInSummaries = []
            customSummaries = []
            clientSummaryByID = [:]
            allDisplayedItemsByID = [:]
            rebuildScopeCache()
            rebuildSelectionCache()
            return
        }

        var builtIn: [ClientScanSummary] = []
        var custom: [ClientScanSummary] = []
        var summaryMap: [String: ClientScanSummary] = [:]
        summaryMap.reserveCapacity(report.clientSummaries.count)

        for summary in report.clientSummaries {
            summaryMap[summary.id] = summary
            if summary.profile.isCustom {
                custom.append(summary)
            } else {
                builtIn.append(summary)
            }
        }

        builtInSummaries = builtIn
        customSummaries = custom
        clientSummaryByID = summaryMap

        var itemMap: [String: CleanableItem] = [:]
        let allDisplayed = report.allDisplayedItems
        itemMap.reserveCapacity(allDisplayed.count)
        for item in allDisplayed where itemMap[item.id] == nil {
            itemMap[item.id] = item
        }
        allDisplayedItemsByID = itemMap

        rebuildScopeCache()
        rebuildSelectionCache()
    }

    private func rebuildScopeCache() {
        let cleanable: [CleanableItem]
        let protected: [CleanableItem]

        switch sidebarSelection {
        case .allClients, .history:
            activeSummary = nil
            cleanable = report?.allItems ?? []
            protected = report?.allProtectedItems ?? []
        case let .client(clientID):
            let summary = clientSummaryByID[clientID]
            activeSummary = summary
            cleanable = summary?.items ?? []
            protected = summary?.protectedItems ?? []
        }

        scopedCleanableItems = cleanable
        scopedProtectedItems = protected

        var combined: [CleanableItem] = []
        combined.reserveCapacity(cleanable.count + protected.count)
        combined.append(contentsOf: cleanable)
        combined.append(contentsOf: protected)
        scopedItems = combined

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

        scopedRecommendedItems = recItems
        scopedReviewSuggestedItems = revItems
        scopedRecommendedBytes = recBytes
        scopedReviewSuggestedBytes = revBytes
        scopedProtectedBytes = proBytes
        scopedTotalFootprintBytes = recBytes + revBytes + proBytes
        categoryCounts = counts

        rebuildFilterCache()
    }

    private func rebuildFilterCache() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ageCutoff = selectedAgeFilter.cutoffDate()

        let filtered = scopedItems.filter { item in
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
            if trimmedQuery.isEmpty {
                return true
            }
            return item.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || item.fileName.localizedCaseInsensitiveContains(trimmedQuery)
                || item.url.path.localizedCaseInsensitiveContains(trimmedQuery)
                || item.clientName.localizedCaseInsensitiveContains(trimmedQuery)
                || item.category.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || item.recommendation.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || item.safetyNote.localizedCaseInsensitiveContains(trimmedQuery)
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch sortOrder {
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

        filteredItems = sorted

        var cleanable: [CleanableItem] = []
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

        filteredCleanableItems = cleanable
        maxDisplayedItemBytes = maxBytes

        var sections: [RecommendationSection] = []
        if !recBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .recommended, items: recBucket, totalBytes: recTotal))
        }
        if !revBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .reviewSuggested, items: revBucket, totalBytes: revTotal))
        }
        if !proBucket.isEmpty {
            sections.append(RecommendationSection(recommendation: .notRecommended, items: proBucket, totalBytes: proTotal))
        }
        displayedSections = sections
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
        totalHistoricalFreedBytes = historyRecords.reduce(0) { $0 + $1.freedBytes }
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
        collapsedSections = [.notRecommended]
        sidebarSelection = .allClients
        suppressCacheRebuild = false

        rebuildReportCaches()
    }

    func rescan() {
        scanTask?.cancel()
        isScanning = true
        errorBannerMessage = nil

        let engine = scanEngine
        let customDirs = customDirectories

        scanTask = Task {
            let newReport = await Task.detached(priority: .userInitiated) {
                engine.scan(customDirectories: customDirs)
            }.value

            guard !Task.isCancelled else { return }

            let validIDs = Set(newReport.allDisplayedItems.map(\.id))
            self.suppressCacheRebuild = true
            self.report = newReport
            self.isScanning = false
            self.selectedItemIDs.formIntersection(validIDs)

            if case let .client(clientID) = self.sidebarSelection,
               !newReport.clientSummaries.contains(where: { $0.id == clientID }) {
                self.sidebarSelection = .allClients
            }
            self.suppressCacheRebuild = false

            self.rebuildReportCaches()
        }
    }

    func toggleRecommendationFilter(_ recommendation: CleanupRecommendation) {
        if selectedRecommendation == recommendation {
            selectedRecommendation = nil
        } else {
            selectedRecommendation = recommendation
            collapsedSections.remove(recommendation)
        }
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
        rebuildFilterCache()
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
