#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Dispatch

/// 抽象只读扫描引擎执行器，生产环境默认由 `ScanEngine` 实现，
/// 单元测试可注入计数或桩对象以验证扫描触发次数与边界行为。
public protocol ScanPerforming: Sendable {
    var homeDirectory: URL { get }
    var safetyGuard: SafetyGuard { get }
    func scan(
        customDirectories: [CustomScanDirectory],
        excludedItems: [ExcludedItemRecord],
        now: Date?
    ) -> ScanReport
    /// 带进度上报的只读扫描：`onProgress` 在后台线程收到整包快照事件
    /// （阶段切换、客户端发现 / 量出体积、统计增量），不依赖 UI 侧定时器。
    func scan(
        customDirectories: [CustomScanDirectory],
        excludedItems: [ExcludedItemRecord],
        now: Date?,
        onProgress: ScanProgressHandler?
    ) -> ScanReport
}

extension ScanPerforming {
    /// 默认实现：未支持进度上报的执行器退化为普通扫描（事件流为空）
    public func scan(
        customDirectories: [CustomScanDirectory],
        excludedItems: [ExcludedItemRecord],
        now: Date?,
        onProgress: ScanProgressHandler?
    ) -> ScanReport {
        scan(
            customDirectories: customDirectories,
            excludedItems: excludedItems,
            now: now
        )
    }
}

/// 多客户端只读扫描引擎：
/// - 严格只读，不修改任何目标目录内容；
/// - 并发扫描所有内置 AI 客户端规则，仅展示本机实际存在的客户端；
/// - 分层扫描 `/private/tmp` 与系统用户临时目录，将高置信度 AI 临时项归属到对应客户端，并为未归属项提供仅手选区；
/// - 自动区分「建议清理」「按需清理」与「不建议清理」三类条目，让用户一眼辨别清理价值与风险；
/// - 结合 SafetyGuard 自动拦截可清理列表中混入的登录态、凭据、核心配置、项目记忆与主数据库。
public struct ScanEngine: ScanPerforming, Sendable {
    public let homeDirectory: URL
    public let builtInProfiles: [AIClientProfile]
    public let safetyGuard: SafetyGuard
    public let sizer: DirectorySizer
    public let sessionReader: SessionMetadataReader
    /// 聊天会话超过该天数未活跃时，归入「按需清理」并标注历史未活跃提示（默认 14 天）
    public let staleSessionDays: Int
    /// `/tmp` 与系统用户临时目录中 AI 临时项的安全冷却时间（默认 24 小时）
    public let tempCooldownHours: Int
    /// 系统临时目录根路径（生产默认 `/private/tmp`，测试环境可注入隔离目录或传 `nil` 禁用）
    public let systemTempRoot: URL?
    /// 当前用户系统临时目录根路径（生产默认 `DARWIN_USER_TEMP_DIR` / `NSTemporaryDirectory()`，测试环境可注入隔离目录或传 `nil` 禁用）
    public let userTempRoot: URL?
    public let platform: any PlatformAdapter
    public let currentPrincipal: Principal
    /// 当前运行环境 `TMPDIR`（用于活跃目录保护，测试可注入模拟路径）
    public let activeTempDirectoryPath: String?
    /// 可选固定参考时间（便于单元测试确定性验证冷却期与旧会话阈值）
    public let fixedNow: Date?
    private let ownerResolver: (@Sendable (URL) -> Principal?)?

    /// 可注入平台及扫描根目录，便于在隔离目录中测试。
    public init(
        homeDirectory: URL? = nil,
        builtInProfiles: [AIClientProfile]? = nil,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer? = nil,
        sessionReader: SessionMetadataReader? = nil,
        staleSessionDays: Int = 14,
        tempCooldownHours: Int = 24,
        systemTempRoot: URL?,
        userTempRoot: URL? = nil,
        currentUID: UInt32? = nil,
        activeTempDirectoryPath: String? = nil,
        now: Date? = nil,
        ownerUIDResolver: (@Sendable (URL) -> UInt32?)? = nil,
        platform: any PlatformAdapter = HostPlatformAdapter.shared
    ) {
        let base = safetyGuard?.platform ?? platform
        self.platform = base
        self.homeDirectory = (homeDirectory ?? base.homeDirectory).standardizedFileURL
        let guardToUse = safetyGuard ?? SafetyGuard(platform: base, homeDirectory: self.homeDirectory)
        self.safetyGuard = guardToUse
        self.builtInProfiles = builtInProfiles ?? (base.platform == .macos
            ? BuiltInClientRules.allProfiles
            : BuiltInClientRules.profiles(for: base, safetyGuard: guardToUse))
        self.sizer = sizer ?? DirectorySizer(platform: base)
        self.sessionReader = sessionReader ?? SessionMetadataReader(platform: base)
        self.staleSessionDays = staleSessionDays
        self.tempCooldownHours = max(1, tempCooldownHours)
        self.systemTempRoot = systemTempRoot?.standardizedFileURL
        self.userTempRoot = userTempRoot?.standardizedFileURL
        self.currentPrincipal = currentUID.map(Principal.uid) ?? base.currentPrincipal
        self.activeTempDirectoryPath = activeTempDirectoryPath
        self.fixedNow = now
        if let ownerUIDResolver {
            self.ownerResolver = { url in ownerUIDResolver(url).map(Principal.uid) }
        } else {
            self.ownerResolver = nil
        }
    }

    /// 使用真实用户主目录时启用本机临时目录扫描。
    public init(
        homeDirectory: URL? = nil,
        builtInProfiles: [AIClientProfile]? = nil,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer? = nil,
        sessionReader: SessionMetadataReader? = nil,
        staleSessionDays: Int = 14,
        tempCooldownHours: Int = 24,
        platform: any PlatformAdapter = HostPlatformAdapter.shared
    ) {
        let base = safetyGuard?.platform ?? platform
        let home = homeDirectory ?? base.homeDirectory
        let isRealUserHome = PlatformPath.normalize(base.resolveSymlinks(at: home))
            == PlatformPath.normalize(base.resolveSymlinks(at: base.homeDirectory))
        let roots = isRealUserHome ? base.temporaryRoots() : nil
        self.init(
            homeDirectory: home,
            builtInProfiles: builtInProfiles,
            safetyGuard: safetyGuard,
            sizer: sizer,
            sessionReader: sessionReader,
            staleSessionDays: staleSessionDays,
            tempCooldownHours: tempCooldownHours,
            systemTempRoot: roots?.shared,
            userTempRoot: roots?.user,
            activeTempDirectoryPath: base.environmentVariable("TMPDIR"),
            platform: base
        )
    }

    /// 执行全量只读扫描（自动跳过用户已排除条目及其目录子树）
    public func scan(
        customDirectories: [CustomScanDirectory] = [],
        excludedItems: [ExcludedItemRecord] = [],
        now: Date? = nil
    ) -> ScanReport {
        scan(
            customDirectories: customDirectories,
            excludedItems: excludedItems,
            now: now,
            onProgress: nil
        )
    }

    /// 执行全量只读扫描并按需上报进度快照（阶段切换 / 客户端发现 / 统计增量）
    public func scan(
        customDirectories: [CustomScanDirectory] = [],
        excludedItems: [ExcludedItemRecord] = [],
        now: Date? = nil,
        onProgress: ScanProgressHandler? = nil
    ) -> ScanReport {
        let referenceNow = now ?? fixedNow ?? Date()
        let excludedMatcher = ExcludedItemMatcher(records: excludedItems, caseInsensitive: platform.pathsAreCaseInsensitive)
        let progress = onProgress.map { ScanProgressEmitter(handler: $0) }
        let resultsLock = CoreLock(
            initialState: [ClientScanSummary?](repeating: nil, count: builtInProfiles.count)
        )

        // 1. 并发扫描所有内置 AI 客户端（每线程使用独立 FileManager 实例保证线程安全）
        progress?.update(stage: .scanningClients)
        let profiles = builtInProfiles
        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            if Task.isCancelled { return }
            let localFM = FileManager()
            let summary = scanProfile(
                profiles[index],
                referenceNow: referenceNow,
                excludedMatcher: excludedMatcher,
                fileManager: localFM,
                progress: progress
            )
            resultsLock.withLock { state in
                state[index] = summary
            }
        }

        let builtInResults = resultsLock.withLock { $0 }.compactMap { $0 }

        // 2. 分层扫描 `/private/tmp` 与系统用户临时目录（若已配置），并合并归属到对应客户端
        progress?.update(stage: .analyzingCacheFiles)
        let tempScanResult: TempDirectoryScanResult
        if !Task.isCancelled && (systemTempRoot != nil || userTempRoot != nil) {
            let tempScanner = TempDirectoryScanner(
                safetyGuard: safetyGuard,
                sizer: sizer,
                cooldownHours: tempCooldownHours,
                currentPrincipal: currentPrincipal,
                activeTempDirectoryPath: activeTempDirectoryPath,
                useDefaultActiveTempPath: false,
                ownerResolver: ownerResolver
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
                var seenPaths = Set(result.items.map { PlatformPath.normalize(platform.resolveSymlinks(at: $0.url)) })
                var mergedItems = result.items
                for item in extraTempItems {
                    let canonical = PlatformPath.normalize(platform.resolveSymlinks(at: item.url))
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

                // /tmp 归属新增条目计入统计增量，并把客户端卡片体积刷新为合并后的最终值
                let extraFileCount = extraTempItems.reduce(0) { $0 + $1.fileCount }
                let extraBytes = extraTempItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
                progress?.addScanStats(fileCount: extraFileCount, bytes: extraBytes)
            }

            if !mergedSummary.items.isEmpty || !mergedSummary.protectedItems.isEmpty {
                detectedBuiltInCount += 1
                summaries.append(mergedSummary)
            }
            // 仅更新本机真实检测到（scanProfile 期间已发出占位卡片）的客户端体积，不为本机不存在的客戶端补插卡片
            if let progress {
                progress.measureClient(
                    id: mergedSummary.profile.id,
                    name: mergedSummary.profile.name,
                    symbolName: mergedSummary.profile.symbolName,
                    accentToken: mergedSummary.profile.accentToken,
                    kind: mergedSummary.profile.kind,
                    cleanableBytes: mergedSummary.totalSizeBytes,
                    itemCount: mergedSummary.items.count,
                    insertIfMissing: false
                )
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
            return CoreTextCompare.caseInsensitiveAscending(lhs.profile.name, rhs.profile.name)
        }

        // 3. 追加系统临时目录独立分组（「其他 AI 临时文件（/tmp）」与「/tmp 未归属临时项」）
        if let otherAITempSummary = tempScanResult.otherAITempSummary {
            let groupFiles = otherAITempSummary.items.reduce(0) { $0 + $1.fileCount }
            let groupBytes = otherAITempSummary.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            progress?.addScanStats(fileCount: groupFiles, bytes: groupBytes)
            progress?.measureClient(
                id: otherAITempSummary.profile.id,
                name: otherAITempSummary.profile.name,
                symbolName: otherAITempSummary.profile.symbolName,
                accentToken: otherAITempSummary.profile.accentToken,
                kind: otherAITempSummary.profile.kind,
                cleanableBytes: otherAITempSummary.totalSizeBytes,
                itemCount: otherAITempSummary.items.count,
                insertIfMissing: true
            )
            summaries.append(otherAITempSummary)
        }
        if let unattributedTempSummary = tempScanResult.unattributedTempSummary {
            let groupFiles = unattributedTempSummary.items.reduce(0) { $0 + $1.fileCount }
            let groupBytes = unattributedTempSummary.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            progress?.addScanStats(fileCount: groupFiles, bytes: groupBytes)
            progress?.measureClient(
                id: unattributedTempSummary.profile.id,
                name: unattributedTempSummary.profile.name,
                symbolName: unattributedTempSummary.profile.symbolName,
                accentToken: unattributedTempSummary.profile.accentToken,
                kind: unattributedTempSummary.profile.kind,
                cleanableBytes: unattributedTempSummary.totalSizeBytes,
                itemCount: unattributedTempSummary.items.count,
                insertIfMissing: true
            )
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
                fileManager: customFM,
                progress: progress
            )
            totalSkippedProtected += result.skippedProtectedCount
            summaries.append(result)
        }

        // 5. 汇总各客户端条目、过滤排除项并生成最终报告
        progress?.update(stage: .tallyingCleanableSpace)
        let report = ScanReport(
            scannedAt: referenceNow,
            clientSummaries: summaries,
            totalBuiltInProfilesCount: builtInProfiles.count,
            detectedBuiltInClientsCount: detectedBuiltInCount,
            skippedProtectedCount: totalSkippedProtected
        ).filtering(excluding: excludedMatcher)
        progress?.flush()

        return report
    }

    // MARK: - Private

    private func scanProfile(
        _ profile: AIClientProfile,
        referenceNow: Date,
        excludedMatcher userExclusions: ExcludedItemMatcher,
        fileManager: FileManager,
        progress: ScanProgressEmitter? = nil
    ) -> ClientScanSummary {
        var discoveredItems: [CleanableItem] = []
        var protectedItems: [CleanableItem] = []
        var seenCleanablePaths: Set<String> = []
        var seenProtectedPaths: Set<String> = []
        var skippedProtectedCount = 0
        var hasDetectedClient = false
        var sessionIndex = profile.isCustom
            ? ClientSessionIndex()
            : sessionReader.loadClientSessionIndex(
                clientID: profile.id,
                homeDirectory: homeDirectory,
                safetyGuard: safetyGuard,
                fileManager: fileManager
            )

        // 优先扫描会话规则，使本轮扫描解析出的会话标题与项目名可立即反哺给图片缓存、回滚快照、调试日志等关联产物规则
        let orderedRules = Self.prioritizedRulesForSessionAssociation(profile.rules)

        for rule in orderedRules {
            if Task.isCancelled { break }
            // Keep project ownership available even when a session is hidden by an exclusion.
            let isProjectRule = !profile.isCustom && (rule.category == .sessions
                || SessionMetadataReader.exclusiveArtifactRuleIDs.contains(rule.id))
            let excludedMatcher = isProjectRule ? ExcludedItemMatcher() : userExclusions
            let targetURL = rule.resolveURL(homeDirectory: homeDirectory)
            guard let targetIdentity = try? platform.identity(at: targetURL) else {
                continue
            }
            let isDirectory = targetIdentity.kind == .directory

            // 首个真实存在的规则目标即认定客户端安装在本机：先弹「检测中」占位卡片
            if !hasDetectedClient {
                hasDetectedClient = true
                progress?.detectClient(
                    ScanProgressClient(
                        id: profile.id,
                        name: profile.name,
                        symbolName: profile.symbolName,
                        accentToken: profile.accentToken,
                        kind: profile.kind,
                        state: .detecting,
                        cleanableBytes: 0,
                        itemCount: 0
                    )
                )
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
                if !userExclusions.isExcluded(targetURL) {
                    progress?.addScanStats(fileCount: inspection.fileCount, bytes: inspection.sizeBytes)
                }

            case .children:
                let rootCheck = profile.isCustom
                    ? safetyGuard.validateCustomDirectoryRoot(targetURL)
                    : safetyGuard.validateBuiltInContainer(targetURL)
                guard rootCheck.isAllowed else {
                    skippedProtectedCount += 1
                    continue
                }

                guard isDirectory else {
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
                    if !userExclusions.isExcluded(targetURL) {
                        progress?.addScanStats(fileCount: 1, bytes: inspection.sizeBytes)
                    }
                    continue
                }

                guard let children = try? platform.contentsOfDirectory(at: targetURL) else {
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

                    let snapshot = isProjectRule ? FileCleanupSnapshot.capture(at: childURL, platform: platform) : nil
                    let metadata: SessionItemMetadata
                    if rule.category == .sessions {
                        metadata = sessionReader.flatSessionMetadata(
                            itemURL: childURL,
                            isDirectory: inspection.isDirectory,
                            clientID: profile.id,
                            ruleID: rule.id,
                            sessionIndex: sessionIndex,
                            fileManager: fileManager
                        )
                        sessionIndex.registerScannedSession(metadata)
                    } else if !profile.isCustom {
                        let display = sessionReader.sessionArtifactMetadata(
                            itemURL: childURL,
                            isDirectory: inspection.isDirectory,
                            clientID: profile.id,
                            rule: rule,
                            fileCount: inspection.fileCount,
                            sessionIndex: sessionIndex,
                            fileManager: fileManager
                        )
                        metadata = sessionReader.exactArtifactOwnership(
                            for: display, at: childURL, isDirectory: inspection.isDirectory, rule: rule, index: sessionIndex
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
                            safetyNote: metadata.safetyNoteOverride ?? note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: inspection.fileCount,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: inspection.isDirectory,
                            isCustom: profile.isCustom,
                            requiresIndividualSelection: requiresIndividualSelection,
                            sessionTitle: metadata.title,
                            sessionProjectName: metadata.projectName,
                            exactSessionID: metadata.exactSessionID,
                            projectEvidence: metadata.projectEvidence,
                            isSessionArtifact: metadata.isSessionArtifact,
                            cleanupSnapshot: snapshot
                        )
                    )
                    if !userExclusions.isExcluded(childURL) {
                        progress?.addScanStats(fileCount: inspection.fileCount, bytes: inspection.sizeBytes)
                    }
                }

            case .projectSessions:
                let containerCheck = safetyGuard.validateBuiltInContainer(targetURL)
                guard containerCheck.isAllowed, isDirectory else {
                    skippedProtectedCount += 1
                    continue
                }

                guard let projectDirs = try? platform.contentsOfDirectory(at: targetURL) else {
                    continue
                }

                for projectDirURL in projectDirs {
                    if Task.isCancelled { break }
                    if excludedMatcher.isExcluded(projectDirURL) { continue }
                    guard (try? platform.identity(at: projectDirURL))?.kind == .directory,
                          let rawSessionEntries = try? platform.contentsOfDirectory(at: projectDirURL) else {
                        continue
                    }

                    // 优先解析主会话文件（.jsonl/.zst），再解析同级子代理目录与 .file-rollback.ndjson，确保索引命中
                    let sessionEntries = rawSessionEntries.sorted { lhs, rhs in
                        let lhsPrimary = SessionMetadataReader.isJSONLOrCompressedJSONL(lhs.lastPathComponent.lowercased())
                        let rhsPrimary = SessionMetadataReader.isJSONLOrCompressedJSONL(rhs.lastPathComponent.lowercased())
                        if lhsPrimary != rhsPrimary { return lhsPrimary }
                        return lhs.lastPathComponent < rhs.lastPathComponent
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

                        let snapshot = FileCleanupSnapshot.capture(at: sessionURL, platform: platform)
                        let metadata = sessionReader.projectSessionMetadata(
                            itemURL: sessionURL,
                            projectFolderName: projectFolderName,
                            isDirectory: inspection.isDirectory,
                            sessionIndex: sessionIndex,
                            fileManager: fileManager
                        )
                        sessionIndex.registerScannedSession(metadata)

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
                                safetyNote: metadata.safetyNoteOverride ?? note,
                                sizeBytes: inspection.sizeBytes,
                                fileCount: inspection.fileCount,
                                modifiedAt: inspection.modifiedAt,
                                isDirectory: inspection.isDirectory,
                                isCustom: profile.isCustom,
                                requiresIndividualSelection: requiresIndividualSelection,
                                sessionTitle: metadata.title,
                                sessionProjectName: metadata.projectName,
                                exactSessionID: metadata.exactSessionID,
                                projectEvidence: metadata.projectEvidence,
                                isSessionArtifact: metadata.isSessionArtifact,
                                cleanupSnapshot: snapshot
                            )
                        )
                        if !userExclusions.isExcluded(sessionURL) {
                            progress?.addScanStats(fileCount: inspection.fileCount, bytes: inspection.sizeBytes)
                        }
                    }
                }

            case .recursiveFiles:
                let containerCheck = safetyGuard.validateBuiltInContainer(targetURL)
                guard containerCheck.isAllowed, isDirectory else {
                    skippedProtectedCount += 1
                    continue
                }

                let loweredSuffixes = rule.allowedFileSuffixes.map { $0.lowercased() }
                var pending = (try? platform.contentsOfDirectory(at: targetURL))?.reversed().map { $0 } ?? []

                while let fileURL = pending.popLast() {
                    if Task.isCancelled { break }
                    guard !fileURL.lastPathComponent.hasPrefix("."), !excludedMatcher.isExcluded(fileURL),
                          let identity = try? platform.identity(at: fileURL), !identity.isHiddenOrSystem else { continue }
                    if identity.kind == .directory {
                        if let children = try? platform.contentsOfDirectory(at: fileURL) {
                            pending.append(contentsOf: children.reversed())
                        }
                        continue
                    }
                    guard identity.kind == .regular else { continue }

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

                    let snapshot = isProjectRule ? FileCleanupSnapshot.capture(at: fileURL, platform: platform) : nil
                    let metadata = sessionReader.flatSessionMetadata(
                        itemURL: fileURL,
                        isDirectory: false,
                        clientID: profile.id,
                        ruleID: rule.id,
                        sessionIndex: sessionIndex,
                        fileManager: fileManager
                    )
                    if rule.category == .sessions {
                        sessionIndex.registerScannedSession(metadata)
                    }

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
                            safetyNote: metadata.safetyNoteOverride ?? note,
                            sizeBytes: inspection.sizeBytes,
                            fileCount: 1,
                            modifiedAt: inspection.modifiedAt,
                            isDirectory: false,
                            isCustom: profile.isCustom,
                            requiresIndividualSelection: requiresIndividualSelection,
                            sessionTitle: metadata.title,
                            sessionProjectName: metadata.projectName,
                            exactSessionID: metadata.exactSessionID,
                            projectEvidence: metadata.projectEvidence,
                            isSessionArtifact: metadata.isSessionArtifact,
                            cleanupSnapshot: snapshot
                        )
                    )
                    if !userExclusions.isExcluded(fileURL) {
                        progress?.addScanStats(fileCount: 1, bytes: inspection.sizeBytes)
                    }
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
            return CoreTextCompare.caseInsensitiveAscending(lhs.displayName, rhs.displayName)
        }

        // 本机检测到的客户端把卡片从「检测中」刷新为已量出的体积（与结果页 totalSizeBytes 同口径）
        if hasDetectedClient, let progress {
            let totalBytes = discoveredItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            progress.measureClient(
                id: profile.id,
                name: profile.name,
                symbolName: profile.symbolName,
                accentToken: profile.accentToken,
                kind: profile.kind,
                cleanableBytes: totalBytes,
                itemCount: discoveredItems.count,
                insertIfMissing: false
            )
        }

        return ClientScanSummary(
            profile: profile,
            items: discoveredItems,
            protectedItems: protectedItems,
            skippedProtectedCount: skippedProtectedCount
        )
    }

    /// 按依赖顺序排列扫描规则：主会话（projectSessions / recursiveFiles）-> 其他会话 -> 关联产物与常规规则
    private static func prioritizedRulesForSessionAssociation(_ rules: [ScanRule]) -> [ScanRule] {
        func priority(_ rule: ScanRule) -> Int {
            guard rule.recommendation != .notRecommended else { return 4 }
            if rule.category == .sessions {
                switch rule.mode {
                case .projectSessions, .recursiveFiles:
                    return 0
                case .children:
                    return 1
                case .directory:
                    return 2
                }
            }
            return 3
        }
        return rules.enumerated()
            .sorted { lhs, rhs in
                let lp = priority(lhs.element)
                let rp = priority(rhs.element)
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 旧会话和归档会话统一归入「按需清理」，支持在分组头一键全选/取消本组或逐条勾选。
    private func resolveRecommendation(
        rule: ScanRule,
        url: URL,
        modifiedAt: Date,
        referenceNow: Date
    ) -> (CleanupRecommendation, String, Bool) {
        guard rule.category == .sessions else {
            return (rule.recommendation, rule.explanation, false)
        }

        let ext = url.pathExtension.lowercased()
        if rule.isSessionArchive == true || ext == "zst" || ext == "zstd" {
            return (.reviewSuggested, "已归档的历史会话，确认无需保留后可勾选清理。", false)
        }

        let staleCutoff = Calendar.current.date(byAdding: .day, value: -staleSessionDays, to: referenceNow) ?? referenceNow
        if modifiedAt < staleCutoff {
            return (.reviewSuggested, "超过 \(staleSessionDays) 天未活跃的历史会话，确认无需保留后可勾选清理。", false)
        }

        return (rule.recommendation, rule.explanation, false)
    }
}
