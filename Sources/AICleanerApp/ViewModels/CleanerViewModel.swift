import AICleanerCore
import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarSelection: Hashable {
    case allClients
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
    private let safetyGuard: SafetyGuard

    // MARK: - Published UI State
    var report: ScanReport?
    var customDirectories: [CustomScanDirectory] = []
    var sidebarSelection: SidebarSelection = .allClients

    var searchText: String = ""
    var selectedCategory: ScanCategory? = nil
    var selectedRecommendation: CleanupRecommendation? = nil
    var selectedAgeFilter: ItemAgeFilter = .all
    var sortOrder: ItemSortOrder = .sizeDescending
    var selectedItemIDs: Set<String> = []
    var collapsedSections: Set<CleanupRecommendation> = [.notRecommended]

    var isScanning: Bool = false
    var isCleaning: Bool = false
    var showingTrashConfirmation: Bool = false
    var showingAddCustomSheet: Bool = false

    var appearanceMode: AppAppearanceMode = .dark
    var hoveredRecommendation: CleanupRecommendation? = nil
    var cleanupCelebrationID: UUID = UUID()

    var lastCleanupResult: CleanupResult?
    var errorBannerMessage: String?

    private var scanTask: Task<Void, Never>?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        customDirectoryStore: CustomDirectoryStore? = nil
    ) {
        let guardInstance = SafetyGuard(homeDirectory: homeDirectory)
        self.safetyGuard = guardInstance
        self.scanEngine = ScanEngine(homeDirectory: homeDirectory, safetyGuard: guardInstance)
        self.trashCleaner = TrashCleaner(safetyGuard: guardInstance)
        self.customDirectoryStore = customDirectoryStore ?? CustomDirectoryStore(safetyGuard: guardInstance)
        self.customDirectories = self.customDirectoryStore.load()
    }

    // MARK: - Derived Data

    var builtInSummaries: [ClientScanSummary] {
        (report?.clientSummaries ?? []).filter { !$0.profile.isCustom }
    }

    var customSummaries: [ClientScanSummary] {
        (report?.clientSummaries ?? []).filter { $0.profile.isCustom }
    }

    var activeSummary: ClientScanSummary? {
        guard case let .client(clientID) = sidebarSelection else { return nil }
        return report?.clientSummaries.first(where: { $0.id == clientID })
    }

    /// 驱动背景极光随当前选中 AI 客户端实时平滑变色
    var activeAccentColor: Color {
        if let summary = activeSummary {
            return AppTheme.color(forAccentToken: summary.profile.accentToken)
        }
        return Color(red: 0.16, green: 0.78, blue: 0.64)
    }

    var highlightedRingTier: CleanupRecommendation? {
        hoveredRecommendation ?? selectedRecommendation
    }

    /// 当前侧边栏分组下的所有可清理条目（「建议清理」+「按需清理」）
    var scopedCleanableItems: [CleanableItem] {
        switch sidebarSelection {
        case .allClients:
            return report?.allItems ?? []
        case let .client(clientID):
            return report?.clientSummaries.first(where: { $0.id == clientID })?.items ?? []
        }
    }

    /// 当前侧边栏分组下所有透明展示的「不建议清理（锁定保护）」条目
    var scopedProtectedItems: [CleanableItem] {
        switch sidebarSelection {
        case .allClients:
            return report?.allProtectedItems ?? []
        case let .client(clientID):
            return report?.clientSummaries.first(where: { $0.id == clientID })?.protectedItems ?? []
        }
    }

    /// 当前侧边栏分组下展示的全部条目（含可清理与不建议清理）
    var scopedItems: [CleanableItem] {
        scopedCleanableItems + scopedProtectedItems
    }

    // MARK: - Scope Dashboard Metrics

    var scopedRecommendedItems: [CleanableItem] {
        scopedCleanableItems.filter { $0.recommendation == .recommended }
    }

    var scopedReviewSuggestedItems: [CleanableItem] {
        scopedCleanableItems.filter { $0.recommendation == .reviewSuggested }
    }

    var scopedRecommendedBytes: Int64 {
        scopedRecommendedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var scopedReviewSuggestedBytes: Int64 {
        scopedReviewSuggestedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var scopedProtectedBytes: Int64 {
        scopedProtectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var scopedCleanableBytes: Int64 {
        scopedRecommendedBytes + scopedReviewSuggestedBytes
    }

    var scopedTotalFootprintBytes: Int64 {
        scopedCleanableBytes + scopedProtectedBytes
    }

    var categoryCounts: [ScanCategory: Int] {
        var counts: [ScanCategory: Int] = [:]
        for item in scopedItems {
            counts[item.category, default: 0] += 1
        }
        return counts
    }

    func sessionCount(for summary: ClientScanSummary) -> Int {
        summary.items.reduce(0) { $0 + ($1.category == .sessions ? 1 : 0) }
    }

    var totalSessionCount: Int {
        (report?.allItems ?? []).reduce(0) { $0 + ($1.category == .sessions ? 1 : 0) }
    }

    /// 应用搜索、类别、建议等级与时间过滤后的全部展示条目
    var filteredItems: [CleanableItem] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ageCutoff = selectedAgeFilter.cutoffDate()
        let filtered = scopedItems.filter { item in
            if let selectedRecommendation, item.recommendation != selectedRecommendation {
                return false
            }
            if let selectedCategory, item.category != selectedCategory {
                return false
            }
            if let ageCutoff, item.isCleanable, item.modifiedAt >= ageCutoff {
                return false
            }
            if ageCutoff != nil && !item.isCleanable {
                // 按「N 天前」筛选待清理项时，仅聚焦符合时间条件的可清理条目
                return false
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

        return filtered.sorted { lhs, rhs in
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
    }

    var filteredCleanableItems: [CleanableItem] {
        filteredItems.filter(\.isCleanable)
    }

    var maxDisplayedItemBytes: Int64 {
        filteredItems.map(\.sizeBytes).max() ?? 0
    }

    struct RecommendationSection: Identifiable {
        let recommendation: CleanupRecommendation
        let items: [CleanableItem]
        let totalBytes: Int64

        var id: CleanupRecommendation { recommendation }
    }

    /// 按「建议清理 → 按需清理 → 不建议清理（已锁定保护）」清晰分组展示
    var displayedSections: [RecommendationSection] {
        let visible = filteredItems
        return CleanupRecommendation.allCases.compactMap { tier in
            let tierItems = visible.filter { $0.recommendation == tier }
            guard !tierItems.isEmpty else { return nil }
            let total = tierItems.reduce(0) { $0 + $1.sizeBytes }
            return RecommendationSection(recommendation: tier, items: tierItems, totalBytes: total)
        }
    }

    var allCleanableItemsByID: [String: CleanableItem] {
        Dictionary((report?.allItems ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var selectedItems: [CleanableItem] {
        let lookup = allCleanableItemsByID
        return selectedItemIDs.compactMap { lookup[$0] }
            .filter(\.isCleanable)
            .sorted { lhs, rhs in
                if lhs.clientName != rhs.clientName {
                    return lhs.clientName.localizedCaseInsensitiveCompare(rhs.clientName) == .orderedAscending
                }
                return lhs.sizeBytes > rhs.sizeBytes
            }
    }

    var selectedTotalBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    struct SelectedClientGroup: Identifiable {
        let id: String
        let clientName: String
        let items: [CleanableItem]
        let totalBytes: Int64
    }

    var groupedSelectedItems: [SelectedClientGroup] {
        let grouped = Dictionary(grouping: selectedItems, by: \.clientID)
        return grouped.compactMap { clientID, value in
            guard let first = value.first else { return nil }
            let total = value.reduce(0) { $0 + $1.sizeBytes }
            return SelectedClientGroup(
                id: clientID,
                clientName: first.clientName,
                items: value,
                totalBytes: total
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    var allVisibleSelected: Bool {
        let visibleCleanable = filteredCleanableItems
        guard !visibleCleanable.isEmpty else { return false }
        return visibleCleanable.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    var visibleSelectedCount: Int {
        filteredCleanableItems.filter { selectedItemIDs.contains($0.id) }.count
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || selectedCategory != nil || selectedRecommendation != nil || selectedAgeFilter != .all
    }

    // MARK: - Actions

    func initialScanIfNeeded() {
        if report == nil && !isScanning {
            rescan()
        }
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
            self.report = newReport
            self.isScanning = false

            // 仅保留本次扫描后仍存在且可清理的勾选状态
            let validIDs = Set(newReport.allItems.map(\.id))
            self.selectedItemIDs.formIntersection(validIDs)

            // 如果当前选中的客户端已无数据或已移除，则回退至「全部客户端」
            if case let .client(clientID) = self.sidebarSelection,
               !newReport.clientSummaries.contains(where: { $0.id == clientID }) {
                self.sidebarSelection = .allClients
            }
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
        searchText = ""
        selectedCategory = nil
        selectedRecommendation = nil
        selectedAgeFilter = .all
    }

    func toggleSelection(for item: CleanableItem) {
        guard item.isCleanable else { return }
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        item.isCleanable && selectedItemIDs.contains(item.id)
    }

    /// 一键勾选当前视图下的全部「建议清理」项
    func selectRecommendedInScope() {
        for item in scopedRecommendedItems where item.isCleanable {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectSection(_ recommendation: CleanupRecommendation) {
        guard recommendation.isCleanable else { return }
        for item in filteredCleanableItems where item.recommendation == recommendation {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectAllVisible() {
        for item in filteredCleanableItems {
            selectedItemIDs.insert(item.id)
        }
    }

    func invertVisibleSelection() {
        for item in filteredCleanableItems {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        }
    }

    func clearVisibleSelection() {
        for item in filteredCleanableItems {
            selectedItemIDs.remove(item.id)
        }
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
            rescan()
        } catch {
            errorBannerMessage = "移除自定义目录失败：\(error.localizedDescription)"
        }
    }

    func requestTrashConfirmation() {
        guard !selectedItems.isEmpty, !isCleaning, !isScanning else { return }
        showingTrashConfirmation = true
    }

    func confirmAndTrashSelectedItems() {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }

        isCleaning = true
        errorBannerMessage = nil
        let cleaner = trashCleaner

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.trash(items: targets)
            }.value

            self.lastCleanupResult = result
            if result.trashedCount > 0 {
                self.cleanupCelebrationID = UUID()
            }
            self.isCleaning = false
            self.showingTrashConfirmation = false

            let trashedIDs = Set(result.trashedItems.map(\.id))
            self.selectedItemIDs.subtract(trashedIDs)

            // 清理完成后立即刷新列表，反馈真实剩余空间
            self.rescan()
        }
    }

    func dismissCleanupBanner() {
        lastCleanupResult = nil
    }

    func dismissErrorBanner() {
        errorBannerMessage = nil
    }
}
