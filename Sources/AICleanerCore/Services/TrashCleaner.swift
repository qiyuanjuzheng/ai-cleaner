#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 抽象「移入系统回收站」动作：生产环境固定由各平台 `PlatformAdapter.moveToTrash(_:)` 实现，
/// 单元测试可注入隔离替身以验证完整清理链路。任何实现都绝不允许降级为永久删除。
public protocol TrashPerforming: Sendable {
    func trashItem(at url: URL) throws -> URL?
}

/// System trash for the current platform.
public struct SystemTrashPerformer: TrashPerforming {
    public init() {}

    public func trashItem(at url: URL) throws -> URL? {
        try PlatformTrashPerformer(platform: HostPlatformAdapter.shared).trashItem(at: url)
    }
}

/// 安全清理服务：
/// - 每次移入回收站前再次执行 SafetyGuard 深度校验；
/// - 统一通过 `TrashPerforming` 执行可恢复移除；
/// - 统计已移入回收站的大小与异常项。
public struct TrashCleaner: Sendable {
    public let safetyGuard: SafetyGuard
    public let performer: any TrashPerforming
    public let sizer: DirectorySizer

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        performer: (any TrashPerforming)? = nil,
        sizer: DirectorySizer? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.performer = performer ?? PlatformTrashPerformer(platform: safetyGuard.platform)
        self.sizer = sizer ?? DirectorySizer(platform: safetyGuard.platform)
    }

    public init(
        platform: any PlatformAdapter,
        safetyGuard: SafetyGuard? = nil,
        performer: (any TrashPerforming)? = nil,
        sizer: DirectorySizer? = nil
    ) {
        let resolvedGuard = safetyGuard ?? SafetyGuard(platform: platform)
        self.init(
            safetyGuard: resolvedGuard,
            performer: performer ?? PlatformTrashPerformer(platform: platform),
            sizer: sizer ?? DirectorySizer(platform: platform)
        )
    }

    /// 将选中的条目批量安全移入系统回收站。
    /// - Parameter allowNotRecommendedOverride: 默认 `false`（严格拦截任何「不建议清理」项）；
    ///   仅在用户通过双重风险提醒并显式确认覆盖后才应传入 `true`，此时仍会校验目标及其后代的硬保护规则。
    public func trash(
        items: [CleanableItem],
        allowNotRecommendedOverride: Bool = false,
        projectCatalog: ProjectSessionCatalog? = nil,
        projectProtectionStore: ProjectProtectionStore? = nil,
        verifyProjectSelection: Bool = false
    ) -> CleanupResult {
        let platform = safetyGuard.platform
        let fileManager = FileManager.default
        var trashed: [TrashedItemRecord] = []
        var skippedProtected: [CleanupFailure] = []
        var failed: [CleanupFailure] = []
        var trashedBytes: Int64 = 0

        let catalog = projectCatalog ?? ProjectSessionCatalog(items: items)
        var checkedProjectPaths: Set<String> = []
        var projectProtection = catalog.protection(for: checkedProjectPaths, platform: platform)
        let sorted = items.sorted {
            PlatformPath.normalize(SafetyGuard.normalizeTempPath($0.url, platform: platform)).count
                < PlatformPath.normalize(SafetyGuard.normalizeTempPath($1.url, platform: platform)).count
        }
        var trashedNormalizedPaths: [String] = []

        for item in sorted {
            let freshURL = URL(fileURLWithPath: PlatformPath.fileSystemPath(for: item.url))
            let url = SafetyGuard.normalizeTempPath(freshURL, platform: platform)
            let normalizedPath = PlatformPath.normalize(url)
            if trashedNormalizedPaths.contains(where: {
                PlatformPath.isEqualOrDescendant(
                    normalizedPath,
                    of: $0,
                    caseInsensitive: platform.pathsAreCaseInsensitive
                )
            }) {
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

            // 通过 platform.identity(at:) 原子检测存在性（含悬空符号链接与重解析点，绝不穿透）
            guard (try? platform.identity(at: url)) != nil else {
                failed.append(CleanupFailure(item: item, reason: "条目不存在或已被外部移除"))
                continue
            }

            // 在最后一次安全校验前计算大小，缩短校验与移动之间的间隔。
            let liveSize = sizer.inspect(url: url, safetyGuard: nil, fileManager: fileManager)?.sizeBytes ?? item.sizeBytes

            // 使用新的 URL 读取当前类型，避免复用体积扫描缓存的文件属性。
            let safetyDecision = safetyGuard.validateTargetRecursively(
                URL(fileURLWithPath: PlatformPath.fileSystemPath(for: url)),
                fileManager: fileManager,
                allowUserOverride: isOverride
            )
            if let reason = safetyDecision.blockReason {
                skippedProtected.append(CleanupFailure(item: item, reason: reason))
                continue
            }

            do {
                let currentProjectPaths = try projectProtectionStore?.load() ?? []
                if currentProjectPaths != checkedProjectPaths {
                    projectProtection = catalog.protection(for: currentProjectPaths, platform: platform)
                    checkedProjectPaths = currentProjectPaths
                }
            } catch {
                failed.append(CleanupFailure(item: item, reason: "无法读取项目保护设置，请检查设置后重试"))
                continue
            }
            if projectProtection.blocks(item, platform: platform) {
                skippedProtected.append(CleanupFailure(item: item, reason: "此条目属于受保护的项目，或包含该项目的数据"))
                continue
            }
            if verifyProjectSelection && catalog.wouldRemoveWorkspace(item, platform: platform) {
                skippedProtected.append(CleanupFailure(item: item, reason: "此条目是项目工作区，或包含项目工作区"))
                continue
            }

            if verifyProjectSelection {
                guard let snapshot = item.cleanupSnapshot, snapshot.modifiedAt != nil else {
                    failed.append(CleanupFailure(item: item, reason: "扫描时无法验证条目的文件身份或修改时间，请重新扫描"))
                    continue
                }
                if let reason = snapshot.changeReason(at: url, platform: platform) {
                    failed.append(CleanupFailure(item: item, reason: reason))
                    continue
                }
            }

            do {
                let resultingURL = try performer.trashItem(at: url)
                trashedNormalizedPaths.append(normalizedPath)
                let record = TrashedItemRecord(item: item, resultingTrashURL: resultingURL, trashedBytes: liveSize)
                trashed.append(record)
                trashedBytes += record.trashedBytes
            } catch let trashError as TrashError {
                failed.append(
                    CleanupFailure(
                        item: item,
                        reason: "移入废纸篓失败：\(trashError.description)"
                    )
                )
            } catch {
                failed.append(
                    CleanupFailure(
                        item: item,
                        reason: "移入废纸篓失败：\(String(describing: error))"
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
