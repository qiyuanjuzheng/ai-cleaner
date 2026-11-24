import Foundation
import os

/// 多客户端只读扫描引擎：
/// - 严格只读，不修改任何目标目录内容；
/// - 并发扫描所有内置 AI 客户端规则，仅展示本机实际存在的客户端；
/// - 自动区分「建议清理」「按需清理」与「不建议清理（锁定保护）」三类条目，让用户一眼辨别清理价值与风险；
/// - 结合 SafetyGuard 自动拦截可清理列表中混入的登录态、凭据、核心配置、项目记忆与主数据库。
public struct ScanEngine: Sendable {
    public let homeDirectory: URL
    public let builtInProfiles: [AIClientProfile]
    public let safetyGuard: SafetyGuard
    public let sizer: DirectorySizer
    public let sessionReader: SessionMetadataReader
    /// 聊天会话超过该天数未活跃时，自动标记为「建议清理」（默认 14 天）
    public let staleSessionDays: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        builtInProfiles: [AIClientProfile] = BuiltInClientRules.allProfiles,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer = DirectorySizer(),
        sessionReader: SessionMetadataReader = SessionMetadataReader(),
        staleSessionDays: Int = 14
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.builtInProfiles = builtInProfiles
        self.safetyGuard = safetyGuard ?? SafetyGuard(homeDirectory: self.homeDirectory)
        self.sizer = sizer
        self.sessionReader = sessionReader
        self.staleSessionDays = staleSessionDays
    }

    /// 执行全量只读扫描
    public func scan(customDirectories: [CustomScanDirectory] = []) -> ScanReport {
        let referenceNow = Date()
        let resultsLock = OSAllocatedUnfairLock(
            initialState: [ClientScanSummary?](repeating: nil, count: builtInProfiles.count)
        )

        // 1. 并发扫描所有内置 AI 客户端（每线程使用独立 FileManager 实例保证线程安全）
        let profiles = builtInProfiles
        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            if Task.isCancelled { return }
            let localFM = FileManager()
            let summary = scanProfile(profiles[index], referenceNow: referenceNow, fileManager: localFM)
            resultsLock.withLock { state in
                state[index] = summary
            }
        }

        let builtInResults = resultsLock.withLock { $0 }.compactMap { $0 }
        var summaries: [ClientScanSummary] = []
        var detectedBuiltInCount = 0
        var totalSkippedProtected = 0

        for result in builtInResults {
            totalSkippedProtected += result.skippedProtectedCount
            if !result.items.isEmpty || !result.protectedItems.isEmpty {
                detectedBuiltInCount += 1
                summaries.append(result)
            }
        }

        // 内置客户端优先按「可清理空间」降序排列，其次按受保护空间降序，确保高收益清理项始终排在最前面
        summaries.sort { lhs, rhs in
            if lhs.totalSizeBytes != rhs.totalSizeBytes {
                return lhs.totalSizeBytes > rhs.totalSizeBytes
            }
            if lhs.protectedSizeBytes != rhs.protectedSizeBytes {
                return lhs.protectedSizeBytes > rhs.protectedSizeBytes
            }
            return lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
        }

        // 2. 扫描用户自定义目录（即便当前为空也保留分组，便于在侧栏查看或移除）
        let customFM = FileManager()
        for customDirectory in customDirectories {
            if Task.isCancelled { break }
            let profile = customDirectory.toClientProfile()
            let result = scanProfile(profile, referenceNow: referenceNow, fileManager: customFM)
            totalSkippedProtected += result.skippedProtectedCount
            summaries.append(result)
        }

        return ScanReport(
            scannedAt: referenceNow,
            clientSummaries: summaries,
            totalBuiltInProfilesCount: builtInProfiles.count,
            detectedBuiltInClientsCount: detectedBuiltInCount,
            skippedProtectedCount: totalSkippedProtected
        )
    }

    // MARK: - Private

    private func scanProfile(
        _ profile: AIClientProfile,
        referenceNow: Date,
        fileManager: FileManager
    ) -> ClientScanSummary {
        var discoveredItems: [CleanableItem] = []
        var protectedItems: [CleanableItem] = []
        var seenCleanablePaths: Set<String> = []
        var seenProtectedPaths: Set<String> = []
        var skippedProtectedCount = 0

        for rule in profile.rules {
            if Task.isCancelled { break }
            let targetURL = rule.resolveURL(homeDirectory: homeDirectory)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
                continue
            }

            // 透明展示的「不建议清理（已锁定保护）」规则：严格只读统计体积，放入 protectedItems，永不进入可清理 items
            if rule.recommendation == .notRecommended {
                guard let inspection = sizer.inspect(
                    url: targetURL,
                    safetyGuard: nil,
                    fileManager: fileManager
                ) else {
                    continue
                }

                // 跳过完全空的受保护目录（如新建尚未使用的空 skills 目录），避免视觉噪音
                if inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                    continue
                }

                let canonicalPath = targetURL.standardizedFileURL.path
                guard seenProtectedPaths.insert(canonicalPath).inserted else { continue }

                protectedItems.append(
                    CleanableItem(
                        clientID: profile.id,
                        clientName: profile.name,
                        ruleID: rule.id,
                        displayName: rule.displayName,
                        fileName: targetURL.lastPathComponent,
                        url: targetURL,
                        category: .protectedData,
                        recommendation: .notRecommended,
                        safetyNote: rule.explanation,
                        sizeBytes: inspection.sizeBytes,
                        fileCount: inspection.fileCount,
                        modifiedAt: inspection.modifiedAt,
                        isDirectory: inspection.isDirectory,
                        isCustom: false
                    )
                )
                continue
            }

            switch rule.mode {
            case .directory:
                let baseCheck = safetyGuard.validateTarget(targetURL, fileManager: fileManager)
                guard baseCheck.isAllowed else {
                    skippedProtectedCount += 1
                    continue
                }

                guard let inspection = sizer.inspect(
                    url: targetURL,
                    safetyGuard: safetyGuard,
                    fileManager: fileManager
                ) else {
                    continue
                }

                // 若目录内包含受保护凭据/配置/数据库，则出于安全原则整目录跳过
                if inspection.protectedDescendantReason != nil {
                    skippedProtectedCount += 1
                    continue
                }

                // 内置规则跳过完全空目录（0 字节且 0 文件），避免界面噪音
                if !profile.isCustom && inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                    continue
                }

                let canonicalPath = targetURL.standardizedFileURL.path
                guard seenCleanablePaths.insert(canonicalPath).inserted else { continue }

                let (recommendation, note) = resolveRecommendation(
                    rule: rule,
                    url: targetURL,
                    modifiedAt: inspection.modifiedAt,
                    referenceNow: referenceNow
                )

                discoveredItems.append(
                    CleanableItem(
                        clientID: profile.id,
                        clientName: profile.name,
                        ruleID: rule.id,
                        displayName: rule.displayName,
                        fileName: targetURL.lastPathComponent,
                        url: targetURL,
                        category: rule.category,
                        recommendation: recommendation,
                        safetyNote: note,
                        sizeBytes: inspection.sizeBytes,
                        fileCount: inspection.fileCount,
                        modifiedAt: inspection.modifiedAt,
                        isDirectory: inspection.isDirectory,
                        isCustom: profile.isCustom
                    )
                )

            case .children:
                let rootCheck = profile.isCustom
                    ? safetyGuard.validateCustomDirectoryRoot(targetURL)
                    : safetyGuard.validateBuiltInContainer(targetURL)
                guard rootCheck.isAllowed else {
                    skippedProtectedCount += 1
                    continue
                }

                guard isDir.boolValue else {
                    let fileCheck = safetyGuard.validateTarget(targetURL, fileManager: fileManager)
                    guard fileCheck.isAllowed,
                          let inspection = sizer.inspect(url: targetURL, safetyGuard: safetyGuard, fileManager: fileManager) else {
                        skippedProtectedCount += 1
                        continue
                    }
                    let canonicalPath = targetURL.standardizedFileURL.path
                    guard seenCleanablePaths.insert(canonicalPath).inserted else { continue }

                    let (recommendation, note) = resolveRecommendation(
                        rule: rule,
                        url: targetURL,
                        modifiedAt: inspection.modifiedAt,
                        referenceNow: referenceNow
                    )

                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: rule.displayName.isEmpty ? targetURL.lastPathComponent : rule.displayName,
                            fileName: targetURL.lastPathComponent,
                            url: targetURL,
                            category: rule.category,
                            recommendation: recommendation,
                            safetyNote: note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: inspection.fileCount,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: false,
                            isCustom: profile.isCustom
                        )
                    )
                    continue
                }

                guard let children = try? fileManager.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ) else {
                    continue
                }

                for childURL in children {
                    if Task.isCancelled { break }
                    if childURL.lastPathComponent == ".DS_Store" { continue }

                    let childCheck = safetyGuard.validateTarget(childURL, fileManager: fileManager)
                    guard childCheck.isAllowed else {
                        skippedProtectedCount += 1
                        continue
                    }

                    guard let inspection = sizer.inspect(
                        url: childURL,
                        safetyGuard: safetyGuard,
                        fileManager: fileManager
                    ) else {
                        continue
                    }

                    if inspection.protectedDescendantReason != nil {
                        skippedProtectedCount += 1
                        continue
                    }

                    if !profile.isCustom && inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                        continue
                    }

                    let canonicalPath = childURL.standardizedFileURL.path
                    guard seenCleanablePaths.insert(canonicalPath).inserted else { continue }

                    let displayName: String
                    if rule.category == .sessions {
                        displayName = sessionReader.buildFlatSessionDisplayName(
                            itemURL: childURL,
                            isDirectory: inspection.isDirectory
                        )
                    } else {
                        displayName = childURL.lastPathComponent
                    }

                    let (recommendation, note) = resolveRecommendation(
                        rule: rule,
                        url: childURL,
                        modifiedAt: inspection.modifiedAt,
                        referenceNow: referenceNow
                    )

                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: displayName,
                            fileName: childURL.lastPathComponent,
                            url: childURL,
                            category: rule.category,
                            recommendation: recommendation,
                            safetyNote: note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: inspection.fileCount,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: inspection.isDirectory,
                            isCustom: profile.isCustom
                        )
                    )
                }

            case .projectSessions:
                let containerCheck = safetyGuard.validateBuiltInContainer(targetURL)
                guard containerCheck.isAllowed, isDir.boolValue else {
                    skippedProtectedCount += 1
                    continue
                }

                guard let projectDirs = try? fileManager.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ) else {
                    continue
                }

                for projectDirURL in projectDirs {
                    if Task.isCancelled { break }
                    let values = try? projectDirURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard (values?.isDirectory ?? false) && !(values?.isSymbolicLink ?? false) else {
                        continue
                    }

                    guard let sessionEntries = try? fileManager.contentsOfDirectory(
                        at: projectDirURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: []
                    ) else {
                        continue
                    }

                    let projectFolderName = projectDirURL.lastPathComponent
                    for sessionURL in sessionEntries {
                        if Task.isCancelled { break }
                        let entryName = sessionURL.lastPathComponent
                        if entryName == ".DS_Store" { continue }

                        let entryCheck = safetyGuard.validateTarget(sessionURL, fileManager: fileManager)
                        guard entryCheck.isAllowed else {
                            skippedProtectedCount += 1
                            continue
                        }

                        guard let inspection = sizer.inspect(
                            url: sessionURL,
                            safetyGuard: safetyGuard,
                            fileManager: fileManager
                        ) else {
                            continue
                        }

                        if inspection.protectedDescendantReason != nil {
                            skippedProtectedCount += 1
                            continue
                        }

                        if inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                            continue
                        }

                        let canonicalPath = sessionURL.standardizedFileURL.path
                        guard seenCleanablePaths.insert(canonicalPath).inserted else { continue }

                        let displayName = sessionReader.buildProjectSessionDisplayName(
                            itemURL: sessionURL,
                            projectFolderName: projectFolderName,
                            isDirectory: inspection.isDirectory,
                            fileManager: fileManager
                        )

                        let (recommendation, note) = resolveRecommendation(
                            rule: rule,
                            url: sessionURL,
                            modifiedAt: inspection.modifiedAt,
                            referenceNow: referenceNow
                        )

                        discoveredItems.append(
                            CleanableItem(
                                clientID: profile.id,
                                clientName: profile.name,
                                ruleID: rule.id,
                                displayName: displayName,
                                fileName: entryName,
                                url: sessionURL,
                                category: rule.category,
                                recommendation: recommendation,
                                safetyNote: note,
                                sizeBytes: inspection.sizeBytes,
                                fileCount: inspection.fileCount,
                                modifiedAt: inspection.modifiedAt,
                                isDirectory: inspection.isDirectory,
                                isCustom: profile.isCustom
                            )
                        )
                    }
                }

            case .recursiveFiles:
                let containerCheck = safetyGuard.validateBuiltInContainer(targetURL)
                guard containerCheck.isAllowed, isDir.boolValue else {
                    skippedProtectedCount += 1
                    continue
                }

                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
                guard let enumerator = fileManager.enumerator(
                    at: targetURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                let loweredSuffixes = rule.allowedFileSuffixes.map { $0.lowercased() }

                while let fileURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                    if Task.isCancelled { break }

                    let values = try? fileURL.resourceValues(forKeys: Set(keys))
                    if (values?.isSymbolicLink ?? false) || (values?.isDirectory ?? false) {
                        continue
                    }
                    guard values?.isRegularFile == true else { continue }

                    let fileName = fileURL.lastPathComponent
                    if fileName == ".DS_Store" { continue }

                    if !loweredSuffixes.isEmpty {
                        let lowerName = fileName.lowercased()
                        guard loweredSuffixes.contains(where: { lowerName.hasSuffix($0) }) else {
                            continue
                        }
                    }

                    let fileCheck = safetyGuard.validateTarget(fileURL, fileManager: fileManager)
                    guard fileCheck.isAllowed else {
                        skippedProtectedCount += 1
                        continue
                    }

                    guard let inspection = sizer.inspect(
                        url: fileURL,
                        safetyGuard: nil,
                        fileManager: fileManager
                    ) else {
                        continue
                    }

                    let canonicalPath = fileURL.standardizedFileURL.path
                    guard seenCleanablePaths.insert(canonicalPath).inserted else { continue }

                    let displayName = sessionReader.buildFlatSessionDisplayName(
                        itemURL: fileURL,
                        isDirectory: false
                    )

                    let (recommendation, note) = resolveRecommendation(
                        rule: rule,
                        url: fileURL,
                        modifiedAt: inspection.modifiedAt,
                        referenceNow: referenceNow
                    )

                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: displayName,
                            fileName: fileName,
                            url: fileURL,
                            category: rule.category,
                            recommendation: recommendation,
                            safetyNote: note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: 1,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: false,
                            isCustom: profile.isCustom
                        )
                    )
                }
            }
        }

        // 条目默认按体积降序排列
        discoveredItems.sort { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        protectedItems.sort { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return ClientScanSummary(
            profile: profile,
            items: discoveredItems,
            protectedItems: protectedItems,
            skippedProtectedCount: skippedProtectedCount
        )
    }

    /// 针对聊天会话结合活跃时间与归档状态动态细化「建议清理」/「按需清理」提示
    private func resolveRecommendation(
        rule: ScanRule,
        url: URL,
        modifiedAt: Date,
        referenceNow: Date
    ) -> (CleanupRecommendation, String) {
        guard rule.category == .sessions && rule.recommendation == .reviewSuggested else {
            return (rule.recommendation, rule.explanation)
        }

        let isCompressedArchive = url.lastPathComponent.lowercased().hasSuffix(".zst")
        let staleCutoff = Calendar.current.date(byAdding: .day, value: -staleSessionDays, to: referenceNow) ?? referenceNow

        if isCompressedArchive {
            return (
                .recommended,
                "已压缩归档的历史会话，通常是已完成的一次性对话，建议清理释放空间（移入废纸篓可随时恢复）。"
            )
        }

        if modifiedAt < staleCutoff {
            return (
                .recommended,
                "超过 \(staleSessionDays) 天未活跃的历史会话，通常为已完成的一次性对话，建议清理（移入废纸篓不影响配置与记忆库）。"
            )
        }

        return (
            .reviewSuggested,
            "近期活跃会话（\(staleSessionDays) 天内更新），若确认是一次性对话可直接勾选清理，仍需续聊建议保留。"
        )
    }
}
