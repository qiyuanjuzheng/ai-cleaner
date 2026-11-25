import Foundation

/// 抽象「移入废纸篓」动作，生产环境固定由 macOS `FileManager.trashItem(at:resultingItemURL:)` 实现，
/// 单元测试可注入隔离替身以验证完整清理链路。
public protocol TrashPerforming: Sendable {
    func trashItem(at url: URL) throws -> URL?
}

/// 默认系统废纸篓实现：严格仅调用 `FileManager.trashItem(at:resultingItemURL:)`，绝不执行永久删除。
public struct SystemTrashPerformer: TrashPerforming {
    public init() {}

    public func trashItem(at url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}

/// 安全清理服务：
/// - 每次移入废纸篓前再次执行 SafetyGuard 深度校验；
/// - 统一通过 `TrashPerforming`（默认 macOS 系统废纸篓）执行可恢复移除；
/// - 统计已移入废纸篓的大小与异常项。
public struct TrashCleaner: Sendable {
    public let safetyGuard: SafetyGuard
    public let performer: any TrashPerforming
    public let sizer: DirectorySizer

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        performer: any TrashPerforming = SystemTrashPerformer(),
        sizer: DirectorySizer = DirectorySizer()
    ) {
        self.safetyGuard = safetyGuard
        self.performer = performer
        self.sizer = sizer
    }

    /// 将选中的条目批量安全移入系统废纸篓。
    /// - Parameter allowNotRecommendedOverride: 默认 `false`（严格拦截任何「不建议清理」项）；
    ///   仅在用户通过双重风险提醒并显式确认覆盖后才应传入 `true`，此时仍会校验目标及其后代的硬保护规则。
    public func trash(
        items: [CleanableItem],
        allowNotRecommendedOverride: Bool = false,
        projectCatalog: ProjectSessionCatalog? = nil,
        projectProtectionStore: ProjectProtectionStore? = nil,
        verifyProjectSelection: Bool = false
    ) -> CleanupResult {
        let fileManager = FileManager.default
        var trashed: [TrashedItemRecord] = []
        var skippedProtected: [CleanupFailure] = []
        var failed: [CleanupFailure] = []
        var trashedBytes: Int64 = 0

        let catalog = projectCatalog ?? ProjectSessionCatalog(items: items)
        var checkedProjectPaths: Set<String> = []
        var projectProtection = catalog.protection(for: checkedProjectPaths)
        let sorted = items.sorted {
            SafetyGuard.normalizeTempPath($0.url).path.count < SafetyGuard.normalizeTempPath($1.url).path.count
        }
        var trashedPaths: Set<String> = []

        for item in sorted {
            let url = SafetyGuard.normalizeTempPath(URL(fileURLWithPath: item.url.path))
            if trashedPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                continue
            }
            let isOverride = !item.isCleanable && allowNotRecommendedOverride
            if let reason = item.hardProtectionReason {
                skippedProtected.append(CleanupFailure(item: item, reason: reason))
                continue
            }
            guard item.isCleanable || isOverride else {
                skippedProtected.append(CleanupFailure(
                    item: item, reason: "该条目已标记为「不建议清理」，未确认风险覆盖前不可移入废纸篓"
                ))
                continue
            }

            let targetCheck = isOverride
                ? safetyGuard.validateUserOverrideTarget(url, fileManager: fileManager)
                : safetyGuard.validateTarget(url, fileManager: fileManager)
            if let reason = targetCheck.blockReason {
                skippedProtected.append(CleanupFailure(item: item, reason: reason))
                continue
            }

            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !fileManager.fileExists(atPath: url.path) && !isSymlink {
                failed.append(CleanupFailure(item: item, reason: "条目不存在或已被外部移除"))
                continue
            }

            // 在最后一次安全校验前计算大小，缩短校验与移动之间的间隔。
            let liveSize = sizer.inspect(url: url, safetyGuard: nil, fileManager: fileManager)?.sizeBytes ?? item.sizeBytes

            // 使用新的 URL 读取当前类型，避免复用体积扫描缓存的文件属性。
            let safetyDecision = safetyGuard.validateTargetRecursively(
                URL(fileURLWithPath: url.path), fileManager: fileManager, allowUserOverride: isOverride
            )
            if let reason = safetyDecision.blockReason {
                skippedProtected.append(CleanupFailure(item: item, reason: reason))
                continue
            }

            do {
                let currentProjectPaths = try projectProtectionStore?.load() ?? []
                if currentProjectPaths != checkedProjectPaths {
                    projectProtection = catalog.protection(for: currentProjectPaths)
                    checkedProjectPaths = currentProjectPaths
                }
            } catch {
                failed.append(CleanupFailure(item: item, reason: "无法读取项目保护设置，请检查设置后重试"))
                continue
            }
            if projectProtection.blocks(item) {
                skippedProtected.append(CleanupFailure(item: item, reason: "此条目属于受保护的项目，或包含该项目的数据"))
                continue
            }
            if verifyProjectSelection && catalog.wouldRemoveWorkspace(item) {
                skippedProtected.append(CleanupFailure(item: item, reason: "此条目是项目工作区，或包含项目工作区"))
                continue
            }

            if verifyProjectSelection {
                guard let snapshot = item.cleanupSnapshot, snapshot.modifiedAt != nil else {
                    failed.append(CleanupFailure(item: item, reason: "扫描时无法验证条目的文件身份或修改时间，请重新扫描"))
                    continue
                }
                if let reason = snapshot.changeReason(at: url) {
                    failed.append(CleanupFailure(item: item, reason: reason))
                    continue
                }
            }

            do {
                let resultingURL = try performer.trashItem(at: url)
                trashedPaths.insert(url.path)
                let record = TrashedItemRecord(item: item, resultingTrashURL: resultingURL, trashedBytes: liveSize)
                trashed.append(record)
                trashedBytes += record.trashedBytes
            } catch {
                failed.append(
                    CleanupFailure(
                        item: item,
                        reason: "移入废纸篓失败：\(error.localizedDescription)"
                    )
                )
            }
        }

        return CleanupResult(
            trashedItems: trashed,
            skippedProtectedItems: skippedProtected,
            failedItems: failed,
            freedBytes: trashedBytes,
            completedAt: Date()
        )
    }
}
