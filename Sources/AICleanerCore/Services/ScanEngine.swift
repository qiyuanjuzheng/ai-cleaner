import Darwin
import Foundation
import os

/// 多客户端只读扫描引擎：
/// - 严格只读，不修改任何目标目录内容；
/// - 并发扫描所有内置 AI 客户端规则，仅展示本机实际存在的客户端；
/// - 分层扫描 `/private/tmp` 与系统用户临时目录，将高置信度 AI 临时项归属到对应客户端，并为未归属项提供仅手选区；
/// - 自动区分「建议清理」「按需清理」与「不建议清理」三类条目，让用户一眼辨别清理价值与风险；
/// - 结合 SafetyGuard 自动拦截可清理列表中混入的登录态、凭据、核心配置、项目记忆与主数据库。
public struct ScanEngine: Sendable {
    public let homeDirectory: URL
    public let builtInProfiles: [AIClientProfile]
    public let safetyGuard: SafetyGuard
    public let sizer: DirectorySizer
    public let sessionReader: SessionMetadataReader
    /// 聊天会话超过该天数未活跃时，归入「按需清理」并要求逐条勾选（默认 14 天）
    public let staleSessionDays: Int
    /// `/tmp` 与系统用户临时目录中 AI 临时项的安全冷却时间（默认 24 小时）
    public let tempCooldownHours: Int
    /// 系统临时目录根路径（生产默认 `/private/tmp`，测试环境可注入隔离目录或传 `nil` 禁用）
    public let systemTempRoot: URL?
    /// 当前用户系统临时目录根路径（生产默认 `DARWIN_USER_TEMP_DIR` / `NSTemporaryDirectory()`，测试环境可注入隔离目录或传 `nil` 禁用）
    public let userTempRoot: URL?
    /// 当前用户 UID（默认 `getuid()`，测试可注入模拟 UID 验证多用户过滤）
    public let currentUID: uid_t
    /// 当前运行环境 `TMPDIR`（用于活跃目录保护，测试可注入模拟路径）
    public let activeTempDirectoryPath: String?
    /// 可选固定参考时间（便于单元测试确定性验证冷却期与旧会话阈值）
    public let fixedNow: Date?
    /// 可选文件属主 UID 解析器（默认使用 `lstat` 读取真实 `st_uid`，测试可注入模拟多用户属主）
    public let ownerUIDResolver: (@Sendable (URL) -> uid_t?)?

    /// 完整依赖注入初始化器：支持显式传入模拟的 `systemTempRoot`、`userTempRoot`、`currentUID` 与参考时间 `now`。
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        builtInProfiles: [AIClientProfile] = BuiltInClientRules.allProfiles,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer = DirectorySizer(),
        sessionReader: SessionMetadataReader = SessionMetadataReader(),
        staleSessionDays: Int = 14,
        tempCooldownHours: Int = 24,
        systemTempRoot: URL?,
        userTempRoot: URL? = nil,
        currentUID: uid_t = getuid(),
        activeTempDirectoryPath: String? = ProcessInfo.processInfo.environment["TMPDIR"],
        now: Date? = nil,
        ownerUIDResolver: (@Sendable (URL) -> uid_t?)? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.builtInProfiles = builtInProfiles
        self.safetyGuard = safetyGuard ?? SafetyGuard(homeDirectory: self.homeDirectory)
        self.sizer = sizer
        self.sessionReader = sessionReader
        self.staleSessionDays = staleSessionDays
        self.tempCooldownHours = max(1, tempCooldownHours)
        self.systemTempRoot = systemTempRoot?.standardizedFileURL
        self.userTempRoot = userTempRoot?.standardizedFileURL
        self.currentUID = currentUID
        self.activeTempDirectoryPath = activeTempDirectoryPath
        self.fixedNow = now
        self.ownerUIDResolver = ownerUIDResolver
    }

    /// 默认初始化器：仅当使用真实宿主用户主目录时自动启用 `/private/tmp` 与 `DARWIN_USER_TEMP_DIR` 扫描；
    /// 当传入沙箱 `homeDirectory` 且未显式注入临时目录时默认禁用真实临时目录，防止测试或预览误触宿主机 `/tmp`。
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        builtInProfiles: [AIClientProfile] = BuiltInClientRules.allProfiles,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer = DirectorySizer(),
        sessionReader: SessionMetadataReader = SessionMetadataReader(),
        staleSessionDays: Int = 14,
        tempCooldownHours: Int = 24
    ) {
        let normalizedHome = homeDirectory.standardizedFileURL
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let isRealUserHome = normalizedHome.resolvingSymlinksInPath().path == realHome.resolvingSymlinksInPath().path
        self.init(
            homeDirectory: normalizedHome,
            builtInProfiles: builtInProfiles,
            safetyGuard: safetyGuard,
            sizer: sizer,
            sessionReader: sessionReader,
            staleSessionDays: staleSessionDays,
            tempCooldownHours: tempCooldownHours,
            systemTempRoot: isRealUserHome ? TempDirectoryScanner.defaultSystemTempRoot : nil,
            userTempRoot: isRealUserHome ? TempDirectoryScanner.defaultUserTempRoot : nil
        )
    }

    /// 执行全量只读扫描（自动跳过用户已排除条目及其目录子树）
    public func scan(
        customDirectories: [CustomScanDirectory] = [],
        excludedItems: [ExcludedItemRecord] = [],
        now: Date? = nil
    ) -> ScanReport {
        let referenceNow = now ?? fixedNow ?? Date()
        let excludedMatcher = ExcludedItemMatcher(records: excludedItems)
        let resultsLock = OSAllocatedUnfairLock(
            initialState: [ClientScanSummary?](repeating: nil, count: builtInProfiles.count)
        )

        // 1. 并发扫描所有内置 AI 客户端（每线程使用独立 FileManager 实例保证线程安全）
        let profiles = builtInProfiles
        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            if Task.isCancelled { return }
            let localFM = FileManager()
            let summary = scanProfile(
                profiles[index],
                referenceNow: referenceNow,
                excludedMatcher: excludedMatcher,
                fileManager: localFM
            )
            resultsLock.withLock { state in
                state[index] = summary
            }
        }

        let builtInResults = resultsLock.withLock { $0 }.compactMap { $0 }

        // 2. 分层扫描 `/private/tmp` 与系统用户临时目录（若已配置）
        let tempScanResult: TempDirectoryScanResult
        if !Task.isCancelled && (systemTempRoot != nil || userTempRoot != nil) {
            let tempScanner = TempDirectoryScanner(
                safetyGuard: safetyGuard,
                sizer: sizer,
                cooldownHours: tempCooldownHours,
                currentUID: currentUID,
                activeTempDirectoryPath: activeTempDirectoryPath,
                ownerUIDResolver: ownerUIDResolver
            )
            tempScanResult = tempScanner.scan(
                systemTempRoot: systemTempRoot,
                userTempRoot: userTempRoot,
                builtInProfiles: builtInProfiles,
                referenceNow: referenceNow,
                excludedMatcher: excludedMatcher,
                fileManager: FileManager()
            )
        } else {
            tempScanResult = TempDirectoryScanResult()
        }

        var summaries: [ClientScanSummary] = []
        var detectedBuiltInCount = 0
        var totalSkippedProtected = tempScanResult.skippedProtectedCount

        for result in builtInResults {
            totalSkippedProtected += result.skippedProtectedCount
            let extraTempItems = tempScanResult.builtInClientItems[result.profile.id] ?? []
            let mergedSummary: ClientScanSummary
            if extraTempItems.isEmpty {
                mergedSummary = result
            } else {
                var seenPaths = Set(result.items.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
                var mergedItems = result.items
                for item in extraTempItems {
                    let canonical = item.url.resolvingSymlinksInPath().standardizedFileURL.path
                    if seenPaths.insert(canonical).inserted {
                        mergedItems.append(item)
                    }
                }
                mergedItems.sort { lhs, rhs in
                    if lhs.sizeBytes != rhs.sizeBytes {
                        return lhs.sizeBytes > rhs.sizeBytes
                    }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                mergedSummary = ClientScanSummary(
                    profile: result.profile,
                    items: mergedItems,
                    protectedItems: result.protectedItems,
                    skippedProtectedCount: result.skippedProtectedCount
                )
            }

            if !mergedSummary.items.isEmpty || !mergedSummary.protectedItems.isEmpty {
                detectedBuiltInCount += 1
                summaries.append(mergedSummary)
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

        // 3. 追加系统临时目录独立分组（「其他 AI 临时文件（/tmp）」与「/tmp 未归属临时项」）
        if let otherAITempSummary = tempScanResult.otherAITempSummary {
            summaries.append(otherAITempSummary)
        }
        if let unattributedTempSummary = tempScanResult.unattributedTempSummary {
            summaries.append(unattributedTempSummary)
        }

        // 4. 扫描用户自定义目录（即便当前为空也保留分组，便于在侧栏查看或移除）
        let customFM = FileManager()
        for customDirectory in customDirectories {
            if Task.isCancelled { break }
            let profile = customDirectory.toClientProfile()
            let result = scanProfile(
                profile,
                referenceNow: referenceNow,
                excludedMatcher: excludedMatcher,
                fileManager: customFM
            )
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
        excludedMatcher: ExcludedItemMatcher,
        fileManager: FileManager
    ) -> ClientScanSummary {
        var discoveredItems: [CleanableItem] = []
        var protectedItems: [CleanableItem] = []
        var seenCleanablePaths: Set<String> = []
        var seenProtectedPaths: Set<String> = []
        var skippedProtectedCount = 0
        var codexTitles: [UUID: String] = [:]
        if profile.id == "codex" {
            let indexURL = homeDirectory.appendingPathComponent(".codex/session_index.jsonl")
            if safetyGuard.validateBuiltInContainer(indexURL).isAllowed {
                codexTitles = sessionReader.readCodexTitles(from: indexURL)
            }
        }

        for rule in profile.rules {
            if Task.isCancelled { break }
            let targetURL = rule.resolveURL(homeDirectory: homeDirectory)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
                continue
            }

            if excludedMatcher.isExcluded(targetURL) {
                continue
            }

            // 统计「不建议清理」条目的占用，并判断是否允许风险覆盖。
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

                let hardProtectionReason = safetyGuard.validateTargetRecursively(
                    targetURL, fileManager: fileManager, allowUserOverride: true
                ).blockReason
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
                        isCustom: false,
                        hardProtectionReason: hardProtectionReason
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

                let (recommendation, note, requiresIndividualSelection) = resolveRecommendation(
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
                        isCustom: profile.isCustom,
                        requiresIndividualSelection: requiresIndividualSelection
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

                    let (recommendation, note, requiresIndividualSelection) = resolveRecommendation(
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
                            isCustom: profile.isCustom,
                            requiresIndividualSelection: requiresIndividualSelection
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
                    if excludedMatcher.isExcluded(childURL) { continue }

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

                    let metadata: SessionItemMetadata
                    if rule.category == .sessions {
                        metadata = sessionReader.flatSessionMetadata(
                            itemURL: childURL,
                            isDirectory: inspection.isDirectory,
                            codexTitles: codexTitles
                        )
                    } else {
                        metadata = SessionItemMetadata(displayName: childURL.lastPathComponent)
                    }

                    let (recommendation, note, requiresIndividualSelection) = resolveRecommendation(
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
                            displayName: metadata.displayName,
                            fileName: childURL.lastPathComponent,
                            url: childURL,
                            category: rule.category,
                            recommendation: recommendation,
                            safetyNote: note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: inspection.fileCount,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: inspection.isDirectory,
                            isCustom: profile.isCustom,
                            requiresIndividualSelection: requiresIndividualSelection,
                            sessionTitle: metadata.title,
                            sessionProjectName: metadata.projectName
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
                    if excludedMatcher.isExcluded(projectDirURL) { continue }
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
                        if excludedMatcher.isExcluded(sessionURL) { continue }

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

                        let metadata = sessionReader.projectSessionMetadata(
                            itemURL: sessionURL,
                            projectFolderName: projectFolderName,
                            isDirectory: inspection.isDirectory,
                            fileManager: fileManager
                        )

                        let (recommendation, note, requiresIndividualSelection) = resolveRecommendation(
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
                                displayName: metadata.displayName,
                                fileName: entryName,
                                url: sessionURL,
                                category: rule.category,
                                recommendation: recommendation,
                                safetyNote: note,
                                sizeBytes: inspection.sizeBytes,
                                fileCount: inspection.fileCount,
                                modifiedAt: inspection.modifiedAt,
                                isDirectory: inspection.isDirectory,
                                isCustom: profile.isCustom,
                                requiresIndividualSelection: requiresIndividualSelection,
                                sessionTitle: metadata.title,
                                sessionProjectName: metadata.projectName
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
                    if values?.isSymbolicLink ?? false {
                        continue
                    }
                    if values?.isDirectory ?? false {
                        if excludedMatcher.isExcluded(fileURL) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    guard values?.isRegularFile == true else { continue }
                    if excludedMatcher.isExcluded(fileURL) { continue }

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

                    let metadata = sessionReader.flatSessionMetadata(
                        itemURL: fileURL,
                        isDirectory: false,
                        codexTitles: codexTitles
                    )

                    let (recommendation, note, requiresIndividualSelection) = resolveRecommendation(
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
                            displayName: metadata.displayName,
                            fileName: fileName,
                            url: fileURL,
                            category: rule.category,
                            recommendation: recommendation,
                            safetyNote: note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: 1,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: false,
                            isCustom: profile.isCustom,
                            requiresIndividualSelection: requiresIndividualSelection,
                            sessionTitle: metadata.title,
                            sessionProjectName: metadata.projectName
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

    /// 旧会话和归档会话需由用户逐条确认。
    private func resolveRecommendation(
        rule: ScanRule,
        url: URL,
        modifiedAt: Date,
        referenceNow: Date
    ) -> (CleanupRecommendation, String, Bool) {
        guard rule.category == .sessions else {
            return (rule.recommendation, rule.explanation, false)
        }

        if rule.isSessionArchive == true || url.pathExtension.lowercased() == "zst" {
            return (.reviewSuggested, "已归档的历史会话，确认无需保留后可逐条勾选。", true)
        }

        let staleCutoff = Calendar.current.date(byAdding: .day, value: -staleSessionDays, to: referenceNow) ?? referenceNow
        if modifiedAt < staleCutoff {
            return (.reviewSuggested, "超过 \(staleSessionDays) 天未活跃，确认无需保留后可逐条勾选。", true)
        }

        return (rule.recommendation, rule.explanation, false)
    }
}
