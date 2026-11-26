#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 单条实际存在于本机的扫描条目（含可清理项与透明展示的「不建议清理」受保护项）
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let clientID: String
    public let clientName: String
    public let ruleID: String
    /// 面向用户的友好名称（如「GPU 缓存」或「项目名 · 首条对话摘要」）
    public let displayName: String
    public let sessionTitle: String?
    public let sessionProjectName: String?
    public let exactSessionID: String?
    public let projectEvidence: SessionProjectEvidence?
    public let isSessionArtifact: Bool
    public let cleanupSnapshot: FileCleanupSnapshot?
    /// 磁盘上的实际文件或目录名
    public let fileName: String
    public let url: URL
    public let category: ScanCategory
    public let recommendation: CleanupRecommendation
    public let safetyNote: String
    public let hardProtectionReason: String?
    public let requiresIndividualSelection: Bool
    /// 来源类别标识（例如「临时文件（/tmp）」），为空时不额外显示来源标签
    public let sourceBadge: String?
    /// 是否为冷却期内（默认 24 小时内）近期修改项，用于在界面展示「近期修改」提示
    public let isRecentlyModified: Bool
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool
    public let isCustom: Bool

    /// 是否属于常规可清理条目（`notRecommended` 不参与一键全选或批量选择，仅支持用户显式风险确认后手动移入废纸篓）
    public var isCleanable: Bool {
        recommendation.isCleanable
    }

    public var isBulkSelectable: Bool {
        isCleanable && !requiresIndividualSelection
    }

    /// 面向界面与排除记录的统一首选标题：会话条目优先使用保存的会话标题，避免退化为裸 UUID 文件名
    public var preferredDisplayTitle: String {
        guard category == .sessions else { return displayName }
        if let sessionTitle, !sessionTitle.trimmedWhitespaceAndNewlines().isEmpty {
            return sessionTitle
        }
        let name = displayName.trimmedWhitespaceAndNewlines()
        let fileStem = isDirectory ? fileName : url.deletingPathExtension().lastPathComponent
        if name.isEmpty || (name == fileName && UUID(uuidString: fileStem) != nil) {
            return "未命名会话"
        }
        return name
    }

    public init(
        clientID: String,
        clientName: String,
        ruleID: String,
        displayName: String,
        fileName: String,
        url: URL,
        category: ScanCategory,
        recommendation: CleanupRecommendation? = nil,
        safetyNote: String,
        sizeBytes: Int64,
        fileCount: Int,
        modifiedAt: Date,
        isDirectory: Bool,
        isCustom: Bool,
        hardProtectionReason: String? = nil,
        requiresIndividualSelection: Bool = false,
        sessionTitle: String? = nil,
        sessionProjectName: String? = nil,
        sourceBadge: String? = nil,
        isRecentlyModified: Bool = false,
        exactSessionID: String? = nil,
        projectEvidence: SessionProjectEvidence? = nil,
        isSessionArtifact: Bool = false,
        cleanupSnapshot: FileCleanupSnapshot? = nil
    ) {
        let standardized = url.standardizedFileURL
        self.id = "\(clientID)::\(standardized.path)"
        self.clientID = clientID
        self.clientName = clientName
        self.ruleID = ruleID
        self.displayName = displayName
        self.sessionTitle = sessionTitle
        self.sessionProjectName = sessionProjectName
        self.exactSessionID = exactSessionID
        self.projectEvidence = projectEvidence
        self.isSessionArtifact = isSessionArtifact
        self.cleanupSnapshot = cleanupSnapshot
        self.fileName = fileName
        self.url = standardized
        self.category = category
        if hardProtectionReason != nil {
            self.recommendation = .notRecommended
        } else if let recommendation {
            self.recommendation = recommendation
        } else {
            switch category {
            case .cache, .temporary, .logs:
                self.recommendation = .recommended
            case .sessions, .custom:
                self.recommendation = .reviewSuggested
            case .protectedData:
                self.recommendation = .notRecommended
            }
        }
        self.safetyNote = hardProtectionReason ?? safetyNote
        self.hardProtectionReason = hardProtectionReason
        self.requiresIndividualSelection = requiresIndividualSelection
        self.sourceBadge = sourceBadge
        self.isRecentlyModified = isRecentlyModified
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isCustom = isCustom
    }

    func applyingProjectProtection() -> Self {
        let reason = "此条目属于受保护的项目，或包含该项目的数据"
        return CleanableItem(
            clientID: clientID, clientName: clientName, ruleID: ruleID, displayName: displayName,
            fileName: fileName, url: url, category: category, recommendation: recommendation, safetyNote: reason,
            sizeBytes: sizeBytes, fileCount: fileCount, modifiedAt: modifiedAt, isDirectory: isDirectory,
            isCustom: isCustom, hardProtectionReason: reason, requiresIndividualSelection: requiresIndividualSelection,
            sessionTitle: sessionTitle, sessionProjectName: sessionProjectName, sourceBadge: sourceBadge,
            isRecentlyModified: isRecentlyModified, exactSessionID: exactSessionID, projectEvidence: projectEvidence,
            isSessionArtifact: isSessionArtifact, cleanupSnapshot: cleanupSnapshot
        )
    }
}

/// 单个 AI 客户端（或自定义目录）的扫描汇总结果
public struct ClientScanSummary: Identifiable, Hashable, Sendable {
    public let profile: AIClientProfile
    /// 允许清理的条目（「建议清理」+「按需清理」）
    public let items: [CleanableItem]
    /// 透明展示的「不建议清理」条目，包括硬保护和可手动覆盖的条目。
    public let protectedItems: [CleanableItem]
    public let skippedProtectedCount: Int

    /// 预计算的可清理空间合计（建议清理 + 按需清理），确保侧边栏与头部渲染 O(1) 读取
    public let totalSizeBytes: Int64
    public let recommendedSizeBytes: Int64
    public let reviewSuggestedSizeBytes: Int64
    public let protectedSizeBytes: Int64
    public let totalDiskFootprintBytes: Int64
    public let recommendedItemCount: Int
    public let reviewSuggestedItemCount: Int

    public var id: String { profile.id }

    /// 本客户端所有展示条目（可清理 + 受保护）
    public var allDisplayedItems: [CleanableItem] {
        items + protectedItems
    }

    public var recommendedItems: [CleanableItem] {
        items.filter { $0.recommendation == .recommended }
    }

    public var reviewSuggestedItems: [CleanableItem] {
        items.filter { $0.recommendation == .reviewSuggested }
    }

    public var itemCount: Int {
        items.count
    }

    public var protectedItemCount: Int {
        protectedItems.count
    }

    public init(
        profile: AIClientProfile,
        items: [CleanableItem],
        protectedItems: [CleanableItem] = [],
        skippedProtectedCount: Int = 0
    ) {
        self.profile = profile
        self.items = items
        self.protectedItems = protectedItems
        self.skippedProtectedCount = skippedProtectedCount

        var recBytes: Int64 = 0
        var revBytes: Int64 = 0
        var recCount = 0
        var revCount = 0
        for item in items {
            if item.recommendation == .recommended {
                recBytes += item.sizeBytes
                recCount += 1
            } else {
                revBytes += item.sizeBytes
                revCount += 1
            }
        }
        var proBytes: Int64 = 0
        for item in protectedItems {
            proBytes += item.sizeBytes
        }

        self.recommendedSizeBytes = recBytes
        self.reviewSuggestedSizeBytes = revBytes
        self.totalSizeBytes = recBytes + revBytes
        self.protectedSizeBytes = proBytes
        self.totalDiskFootprintBytes = recBytes + revBytes + proBytes
        self.recommendedItemCount = recCount
        self.reviewSuggestedItemCount = revCount
    }
}

/// 一次全量扫描的汇总报告
public struct ScanReport: Sendable {
    public let scannedAt: Date
    public let clientSummaries: [ClientScanSummary]
    /// Includes project candidates hidden by the exclusion list, for parent-directory protection.
    public let projectItems: [CleanableItem]
    public let totalBuiltInProfilesCount: Int
    public let detectedBuiltInClientsCount: Int
    public let skippedProtectedCount: Int

    /// 预计算全局体积与条目计数（O(1) 读取，避免切换视图时重复遍历数千条目）
    public let totalSizeBytes: Int64
    public let recommendedSizeBytes: Int64
    public let reviewSuggestedSizeBytes: Int64
    public let protectedSizeBytes: Int64
    public let totalDiskFootprintBytes: Int64
    public let totalItemCount: Int
    public let totalRecommendedCount: Int
    public let totalReviewSuggestedCount: Int
    public let totalProtectedItemCount: Int

    /// 所有可清理条目（建议清理 + 按需清理）
    public var allItems: [CleanableItem] {
        clientSummaries.flatMap(\.items)
    }

    /// 所有透明展示的「不建议清理」锁定条目
    public var allProtectedItems: [CleanableItem] {
        clientSummaries.flatMap(\.protectedItems)
    }

    /// 所有展示条目（含可清理与不建议清理）
    public var allDisplayedItems: [CleanableItem] {
        clientSummaries.flatMap(\.allDisplayedItems)
    }

    public init(
        scannedAt: Date = Date(),
        clientSummaries: [ClientScanSummary],
        totalBuiltInProfilesCount: Int,
        detectedBuiltInClientsCount: Int,
        skippedProtectedCount: Int = 0,
        projectItems: [CleanableItem]? = nil
    ) {
        self.scannedAt = scannedAt
        self.clientSummaries = clientSummaries
        self.projectItems = projectItems ?? clientSummaries.flatMap(\.allDisplayedItems)
            .filter { $0.category == .sessions || $0.isSessionArtifact }
        self.totalBuiltInProfilesCount = totalBuiltInProfilesCount
        self.detectedBuiltInClientsCount = detectedBuiltInClientsCount
        self.skippedProtectedCount = skippedProtectedCount

        var totalBytes: Int64 = 0
        var recBytes: Int64 = 0
        var revBytes: Int64 = 0
        var proBytes: Int64 = 0
        var itemCount = 0
        var recCount = 0
        var revCount = 0
        var proCount = 0

        for summary in clientSummaries {
            totalBytes += summary.totalSizeBytes
            recBytes += summary.recommendedSizeBytes
            revBytes += summary.reviewSuggestedSizeBytes
            proBytes += summary.protectedSizeBytes
            itemCount += summary.itemCount
            recCount += summary.recommendedItemCount
            revCount += summary.reviewSuggestedItemCount
            proCount += summary.protectedItemCount
        }

        self.totalSizeBytes = totalBytes
        self.recommendedSizeBytes = recBytes
        self.reviewSuggestedSizeBytes = revBytes
        self.protectedSizeBytes = proBytes
        self.totalDiskFootprintBytes = totalBytes + proBytes
        self.totalItemCount = itemCount
        self.totalRecommendedCount = recCount
        self.totalReviewSuggestedCount = revCount
        self.totalProtectedItemCount = proCount
    }

    /// 返回按排除清单过滤后的新扫描报告，并实时重算所有客户端分组与全局统计汇总。
    /// 与 `ScanEngine` 约定保持一致：内置客户端与系统临时目录分组若已无任何展示条目则从列表移除，自定义目录分组保留。
    public func filtering(excluding matcher: ExcludedItemMatcher) -> ScanReport {
        guard !matcher.isEmpty else { return self }
        return rebuilding { !matcher.isExcluded($0.url) }
    }

    /// 便捷重载：直接传入已排除记录数组过滤扫描报告
    public func filtering(excludedItems: [ExcludedItemRecord]) -> ScanReport {
        filtering(excluding: ExcludedItemMatcher(records: excludedItems))
    }

    /// 原位移除已成功移入废纸篓的条目（含按规范化路径前缀归属已清理目录内部的残留子条目），
    /// 并实时重算各客户端分组摘要与全局 `O(1)` 统计字段。
    /// 与 `filtering(excluding:)` 保持一致：内置客户端与系统临时目录分组清空后自动移除，自定义目录分组保留。
    public func removing(trashedItems: [CleanableItem]) -> ScanReport {
        guard !trashedItems.isEmpty else { return self }
        let matcher = TrashedItemMatcher(items: trashedItems)
        var resolvedDirCache: [String: String] = [:]
        let remainingProjectItems = projectItems.filter { !matcher.matches($0, resolvedDirCache: &resolvedDirCache) }
        return rebuilding(projectItems: remainingProjectItems) { !matcher.matches($0, resolvedDirCache: &resolvedDirCache) }
    }

    /// 便捷重载：直接传入已移入废纸篓记录数组原位扣减扫描报告
    public func removing(trashedRecords: [TrashedItemRecord]) -> ScanReport {
        removing(trashedItems: trashedRecords.map(\.item))
    }

    public func applyingProjectProtection(_ protection: ProjectLocationMatcher) -> ScanReport {
        let summaries = clientSummaries.map { summary in
            var cleanable: [CleanableItem] = []
            var locked = summary.protectedItems.map { protection.blocks($0) ? $0.applyingProjectProtection() : $0 }
            for item in summary.items {
                if protection.blocks(item) {
                    locked.append(item.applyingProjectProtection())
                } else {
                    cleanable.append(item)
                }
            }
            return ClientScanSummary(
                profile: summary.profile, items: cleanable, protectedItems: locked,
                skippedProtectedCount: summary.skippedProtectedCount
            )
        }
        return ScanReport(
            scannedAt: scannedAt, clientSummaries: summaries, totalBuiltInProfilesCount: totalBuiltInProfilesCount,
            detectedBuiltInClientsCount: detectedBuiltInClientsCount, skippedProtectedCount: skippedProtectedCount,
            projectItems: projectItems
        )
    }

    private func rebuilding(
        projectItems remainingProjectItems: [CleanableItem]? = nil, keeping shouldKeep: (CleanableItem) -> Bool
    ) -> ScanReport {
        var builtIn: [ClientScanSummary] = []
        var tempGroups: [ClientScanSummary] = []
        var custom: [ClientScanSummary] = []

        for summary in clientSummaries {
            let filteredItems = summary.items.filter(shouldKeep)
            let filteredProtected = summary.protectedItems.filter(shouldKeep)

            switch summary.profile.kind {
            case .customDirectory:
                custom.append(
                    ClientScanSummary(
                        profile: summary.profile,
                        items: filteredItems,
                        protectedItems: filteredProtected,
                        skippedProtectedCount: summary.skippedProtectedCount
                    )
                )
            case .otherAITemp, .unattributedTemp:
                if !filteredItems.isEmpty || !filteredProtected.isEmpty {
                    tempGroups.append(
                        ClientScanSummary(
                            profile: summary.profile,
                            items: filteredItems,
                            protectedItems: filteredProtected,
                            skippedProtectedCount: summary.skippedProtectedCount
                        )
                    )
                }
            case .builtInClient:
                if !filteredItems.isEmpty || !filteredProtected.isEmpty {
                    builtIn.append(
                        ClientScanSummary(
                            profile: summary.profile,
                            items: filteredItems,
                            protectedItems: filteredProtected,
                            skippedProtectedCount: summary.skippedProtectedCount
                        )
                    )
                }
            }
        }

        builtIn.sort(by: Self.compareBuiltInSummaries)
        tempGroups.sort(by: Self.compareTempSummaries)

        return ScanReport(
            scannedAt: scannedAt,
            clientSummaries: builtIn + tempGroups + custom,
            totalBuiltInProfilesCount: totalBuiltInProfilesCount,
            detectedBuiltInClientsCount: builtIn.count,
            skippedProtectedCount: skippedProtectedCount,
            projectItems: remainingProjectItems ?? projectItems
        )
    }

    /// 将同一次扫描会话中曾被临时排除的条目快照无闪烁合并回报告（自动跳过仍被排除或已重复存在的条目）
    public func mergingRestoredItems(
        _ entries: [(item: CleanableItem, profile: AIClientProfile, isProtected: Bool)],
        excluding matcher: ExcludedItemMatcher
    ) -> ScanReport {
        guard !entries.isEmpty else { return self }

        var byProfileID: [String: (profile: AIClientProfile, items: [CleanableItem], protectedItems: [CleanableItem], skipped: Int, order: Int)] = [:]
        var nextOrder = 0
        for summary in clientSummaries {
            byProfileID[summary.id] = (
                profile: summary.profile,
                items: summary.items,
                protectedItems: summary.protectedItems,
                skipped: summary.skippedProtectedCount,
                order: nextOrder
            )
            nextOrder += 1
        }

        var didInsert = false
        for entry in entries {
            guard !matcher.isExcluded(entry.item.url) else { continue }
            var bucket = byProfileID[entry.profile.id] ?? (
                profile: entry.profile,
                items: [],
                protectedItems: [],
                skipped: 0,
                order: nextOrder
            )
            if byProfileID[entry.profile.id] == nil {
                nextOrder += 1
            }

            if entry.isProtected {
                if !bucket.protectedItems.contains(where: { $0.id == entry.item.id }) {
                    bucket.protectedItems.append(entry.item)
                    didInsert = true
                }
            } else {
                if !bucket.items.contains(where: { $0.id == entry.item.id }) {
                    bucket.items.append(entry.item)
                    didInsert = true
                }
            }
            byProfileID[entry.profile.id] = bucket
        }

        guard didInsert else { return self }

        var builtIn: [ClientScanSummary] = []
        var tempGroups: [ClientScanSummary] = []
        var custom: [(order: Int, summary: ClientScanSummary)] = []

        for bucket in byProfileID.values {
            let sortedItems = bucket.items.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.modifiedAt > rhs.modifiedAt
            }
            let sortedProtected = bucket.protectedItems.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return CoreTextCompare.caseInsensitiveAscending(lhs.displayName, rhs.displayName)
            }
            let summary = ClientScanSummary(
                profile: bucket.profile,
                items: sortedItems,
                protectedItems: sortedProtected,
                skippedProtectedCount: bucket.skipped
            )
            switch bucket.profile.kind {
            case .customDirectory:
                custom.append((bucket.order, summary))
            case .otherAITemp, .unattributedTemp:
                if !summary.items.isEmpty || !summary.protectedItems.isEmpty {
                    tempGroups.append(summary)
                }
            case .builtInClient:
                if !summary.items.isEmpty || !summary.protectedItems.isEmpty {
                    builtIn.append(summary)
                }
            }
        }

        builtIn.sort(by: Self.compareBuiltInSummaries)
        tempGroups.sort(by: Self.compareTempSummaries)
        let sortedCustom = custom.sorted { $0.order < $1.order }.map(\.summary)

        return ScanReport(
            scannedAt: scannedAt,
            clientSummaries: builtIn + tempGroups + sortedCustom,
            totalBuiltInProfilesCount: totalBuiltInProfilesCount,
            detectedBuiltInClientsCount: builtIn.count,
            skippedProtectedCount: skippedProtectedCount,
            projectItems: projectItems
        )
    }

    private static func compareTempSummaries(_ lhs: ClientScanSummary, _ rhs: ClientScanSummary) -> Bool {
        let rank: (AIClientProfile.ProfileKind) -> Int = { kind in
            switch kind {
            case .otherAITemp: return 0
            case .unattributedTemp: return 1
            default: return 2
            }
        }
        let lhsRank = rank(lhs.profile.kind)
        let rhsRank = rank(rhs.profile.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return CoreTextCompare.caseInsensitiveAscending(lhs.profile.name, rhs.profile.name)
    }

    private static func compareBuiltInSummaries(_ lhs: ClientScanSummary, _ rhs: ClientScanSummary) -> Bool {
        if lhs.totalSizeBytes != rhs.totalSizeBytes {
            return lhs.totalSizeBytes > rhs.totalSizeBytes
        }
        if lhs.protectedSizeBytes != rhs.protectedSizeBytes {
            return lhs.protectedSizeBytes > rhs.protectedSizeBytes
        }
        return CoreTextCompare.caseInsensitiveAscending(lhs.profile.name, rhs.profile.name)
    }
}

/// 基于条目 ID 与规范化路径（含目录子树边界）的已清理条目匹配器：
/// - 精确匹配已成功移入废纸篓条目的 `id`；
/// - 按规范化路径与目录边界（`/a/dir` 匹配 `/a/dir` 及 `/a/dir/...`，绝不误匹配 `/a/dir2` 或 `/a/dir.log`）
///   匹配位于已清理目录内部的残留子条目；
/// - 复用 `SafetyGuard.normalizeTempPath` 与祖先目录符号链接解析，兼容 `/tmp` ↔ `/private/tmp`、`/var` ↔ `/private/var`
///   且在目录已被移入废纸篓后仍可正确归并，同时保留末级符号链接身份不穿透目标目录。
public struct TrashedItemMatcher: Sendable, Hashable {
    private let trashedIDs: Set<String>
    private let exactPaths: Set<String>

    public var isEmpty: Bool {
        trashedIDs.isEmpty && exactPaths.isEmpty
    }

    public init(items: [CleanableItem] = []) {
        var ids: Set<String> = []
        var exact: Set<String> = []
        var resolvedDirCache: [String: String] = [:]

        for item in items {
            ids.insert(item.id)
            for variant in Self.pathVariants(for: item.url, resolvedDirCache: &resolvedDirCache) {
                exact.insert(variant)
            }
        }

        self.trashedIDs = ids
        self.exactPaths = exact
    }

    public func matches(_ item: CleanableItem) -> Bool {
        var cache: [String: String] = [:]
        return matches(item, resolvedDirCache: &cache)
    }

    public func matches(_ item: CleanableItem, resolvedDirCache: inout [String: String]) -> Bool {
        guard !isEmpty else { return false }
        if trashedIDs.contains(item.id) {
            return true
        }
        return matches(url: item.url, resolvedDirCache: &resolvedDirCache)
    }

    public func matches(url: URL, resolvedDirCache: inout [String: String]) -> Bool {
        guard !exactPaths.isEmpty else { return false }
        for variant in Self.pathVariants(for: url, resolvedDirCache: &resolvedDirCache) {
            if matchesPath(variant) {
                return true
            }
        }
        return false
    }

    private func matchesPath(_ candidate: String) -> Bool {
        if exactPaths.contains(candidate) {
            return true
        }
        var matched = false
        PlatformPath.forEachAncestor(of: candidate) { ancestor in
            if exactPaths.contains(ancestor) {
                matched = true
            }
        }
        return matched
    }

    private static func pathVariants(for url: URL, resolvedDirCache: inout [String: String]) -> [String] {
        let rawNormalized = ExcludedItemMatcher.normalizePath(url)
        let tempNormalized = ExcludedItemMatcher.normalizePath(SafetyGuard.normalizeTempPath(url))
        let ancestorResolved = resolveExistingAncestorPath(for: tempNormalized, cache: &resolvedDirCache)

        var variants: [String] = [rawNormalized]
        if !variants.contains(tempNormalized) {
            variants.append(tempNormalized)
        }
        if !variants.contains(ancestorResolved) {
            variants.append(ancestorResolved)
        }
        return variants
    }

    private static func resolveExistingAncestorPath(
        for normalizedPath: String,
        cache: inout [String: String]
    ) -> String {
        guard !normalizedPath.isEmpty, !PlatformPath.isRoot(normalizedPath),
              let parentPath = PlatformPath.parent(of: normalizedPath) else {
            return normalizedPath
        }
        // 仅解析祖先目录符号链接，保留末级节点身份不穿透末级符号链接
        let leafName = PlatformPath.lastPathComponent(normalizedPath)
        let resolvedParent = resolveExistingDirectoryPath(parentPath, cache: &cache)
        return resolvedParent.hasSuffix("/") ? "\(resolvedParent)\(leafName)" : "\(resolvedParent)/\(leafName)"
    }

    private static func resolveExistingDirectoryPath(
        _ dirPath: String,
        cache: inout [String: String]
    ) -> String {
        if let cached = cache[dirPath] {
            return cached
        }
        guard !dirPath.isEmpty, !PlatformPath.isRoot(dirPath) else {
            cache[dirPath] = dirPath
            return dirPath
        }

        let fileManager = FileManager.default
        var currentPath = dirPath
        var missingComponents: [String] = []

        while !PlatformPath.isRoot(currentPath) {
            if let cached = cache[currentPath] {
                var resolved = cached
                for component in missingComponents.reversed() {
                    resolved = resolved.hasSuffix("/") ? "\(resolved)\(component)" : "\(resolved)/\(component)"
                }
                cache[dirPath] = resolved
                return resolved
            }
            let currentURL = URL(fileURLWithPath: currentPath)
            if fileManager.fileExists(atPath: PlatformPath.fileSystemPath(for: currentURL)) {
                let resolvedExisting = PlatformPath.normalize(
                    PlatformPath.resolveSymlinks(currentURL)
                )
                cache[currentPath] = resolvedExisting
                var resolved = resolvedExisting
                for component in missingComponents.reversed() {
                    resolved = resolved.hasSuffix("/") ? "\(resolved)\(component)" : "\(resolved)/\(component)"
                }
                cache[dirPath] = resolved
                return resolved
            }
            missingComponents.append(PlatformPath.lastPathComponent(currentPath))
            guard let nextPath = PlatformPath.parent(of: currentPath), nextPath != currentPath else {
                break
            }
            currentPath = nextPath
        }

        cache[dirPath] = dirPath
        return dirPath
    }
}
