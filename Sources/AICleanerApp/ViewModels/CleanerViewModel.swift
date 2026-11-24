import AICleanerCore
import AppKit
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case allClients
    case client(String)
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
    var sortOrder: ItemSortOrder = .sizeDescending
    var selectedItemIDs: Set<String> = []

    var isScanning: Bool = false
    var isCleaning: Bool = false
    var showingTrashConfirmation: Bool = false
    var showingAddCustomSheet: Bool = false

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

    var scopedItems: [CleanableItem] {
        switch sidebarSelection {
        case .allClients:
            return report?.allItems ?? []
        case let .client(clientID):
            return report?.clientSummaries.first(where: { $0.id == clientID })?.items ?? []
        }
    }

    var filteredItems: [CleanableItem] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = scopedItems.filter { item in
            if let selectedCategory, item.category != selectedCategory {
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

    var allItemsByID: [String: CleanableItem] {
        Dictionary((report?.allItems ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var selectedItems: [CleanableItem] {
        let lookup = allItemsByID
        return selectedItemIDs.compactMap { lookup[$0] }
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
        let visible = filteredItems
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    var visibleSelectedCount: Int {
        filteredItems.filter { selectedItemIDs.contains($0.id) }.count
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

            // 仅保留本次扫描后仍存在的勾选状态
            let validIDs = Set(newReport.allItems.map(\.id))
            self.selectedItemIDs.formIntersection(validIDs)

            // 如果当前选中的客户端已无数据或已移除，则回退至「全部客户端」
            if case let .client(clientID) = self.sidebarSelection,
               !newReport.clientSummaries.contains(where: { $0.id == clientID }) {
                self.sidebarSelection = .allClients
            }
        }
    }

    func toggleSelection(for item: CleanableItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func selectAllVisible() {
        for item in filteredItems {
            selectedItemIDs.insert(item.id)
        }
    }

    func invertVisibleSelection() {
        for item in filteredItems {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        }
    }

    func clearVisibleSelection() {
        for item in filteredItems {
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
