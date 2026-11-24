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
/// - 精确统计实际释放空间与异常项。
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
    ///   仅在用户通过双重风险提醒并显式确认覆盖后才应传入 `true`，此时仍会强制执行操作系统与敏感根目录底线校验。
    public func trash(
        items: [CleanableItem],
        allowNotRecommendedOverride: Bool = false
    ) -> CleanupResult {
        let fileManager = FileManager.default
        var trashed: [TrashedItemRecord] = []
        var skippedProtected: [CleanupFailure] = []
        var failed: [CleanupFailure] = []
        var actualFreedBytes: Int64 = 0

        // 按路径去重，若同时包含父目录与子项则按父目录优先避免重复处理
        let deduplicated = deduplicateNestedItems(items)

        for item in deduplicated {
            let url = item.url.standardizedFileURL

            // 0. 检查「不建议清理」条目的风险覆盖授权
            if !item.isCleanable {
                guard allowNotRecommendedOverride else {
                    skippedProtected.append(
                        CleanupFailure(item: item, reason: "该条目已标记为「不建议清理」，未确认风险覆盖前不可移入废纸篓")
                    )
                    continue
                }

                // 即使显式覆盖，仍强制死守系统目录、隐私敏感子树、客户端顶层根目录与越界符号链接底线
                let overrideDecision = safetyGuard.validateUserOverrideTarget(url, fileManager: fileManager)
                if let blockReason = overrideDecision.blockReason {
                    skippedProtected.append(CleanupFailure(item: item, reason: blockReason))
                    continue
                }
            } else {
                // 1. 普通条目执行完整二次安全校验（含子目录内容检查）
                let safetyDecision = safetyGuard.validateTargetRecursively(url, fileManager: fileManager)
                if let blockReason = safetyDecision.blockReason {
                    skippedProtected.append(CleanupFailure(item: item, reason: blockReason))
                    continue
                }
            }

            // 2. 检查文件当前是否仍存在
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !fileManager.fileExists(atPath: url.path) && !isSymlink {
                failed.append(CleanupFailure(item: item, reason: "条目不存在或已被外部移除"))
                continue
            }

            // 3. 实时计算移入前的真实字节数，确保「实际释放空间」反馈准确
            let liveSize = sizer.inspect(url: url, safetyGuard: nil, fileManager: fileManager)?.sizeBytes ?? item.sizeBytes

            // 4. 调用 macOS 系统废纸篓 API
            do {
                let resultingURL = try performer.trashItem(at: url)
                trashed.append(TrashedItemRecord(item: item, resultingTrashURL: resultingURL))
                actualFreedBytes += max(0, liveSize)
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
            freedBytes: actualFreedBytes,
            completedAt: Date()
        )
    }

    private func deduplicateNestedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        // 路径更短的排在前，若后续路径位于已选父目录之下则跳过，避免二次 trashing 报错
        let sorted = items.sorted { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
        var kept: [CleanableItem] = []
        var keptPaths: [String] = []

        for item in sorted {
            let path = item.url.standardizedFileURL.path
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
