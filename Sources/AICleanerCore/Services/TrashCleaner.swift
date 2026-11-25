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
        allowNotRecommendedOverride: Bool = false
    ) -> CleanupResult {
        let fileManager = FileManager.default
        var trashed: [TrashedItemRecord] = []
        var skippedProtected: [CleanupFailure] = []
        var failed: [CleanupFailure] = []
        var trashedBytes: Int64 = 0

        // 按路径去重，若同时包含父目录与子项则按父目录优先避免重复处理
        let deduplicated = deduplicateNestedItems(items)

        for item in deduplicated {
            let url = SafetyGuard.normalizeTempPath(URL(fileURLWithPath: item.url.path))
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
                let resultingURL = try performer.trashItem(at: url)
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

    private func deduplicateNestedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        // 路径更短的排在前，若后续路径位于已选父目录之下则跳过，避免二次 trashing 报错
        let sorted = items.sorted {
            SafetyGuard.normalizeTempPath($0.url).path.count < SafetyGuard.normalizeTempPath($1.url).path.count
        }
        var kept: [CleanableItem] = []
        var keptPaths: [String] = []

        for item in sorted {
            let path = SafetyGuard.normalizeTempPath(item.url).path
            let isNested = keptPaths.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            if !isNested {
                kept.append(item)
                keptPaths.append(path)
            }
        }
        return kept
    }
}
