import Foundation

/// 多客户端只读扫描引擎：
/// - 严格只读，不修改任何目标目录内容；
/// - 仅返回本机实际存在的条目（内置客户端仅展示有实际可清理条目的客户端，自定义目录始终保留以便用户管理）；
/// - 结合 SafetyGuard 自动跳过登录态、凭据、核心配置及主数据库。
public struct ScanEngine: Sendable {
    public let homeDirectory: URL
    public let builtInProfiles: [AIClientProfile]
    public let safetyGuard: SafetyGuard
    public let sizer: DirectorySizer
    public let sessionReader: SessionMetadataReader

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        builtInProfiles: [AIClientProfile] = BuiltInClientRules.allProfiles,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer = DirectorySizer(),
        sessionReader: SessionMetadataReader = SessionMetadataReader()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.builtInProfiles = builtInProfiles
        self.safetyGuard = safetyGuard ?? SafetyGuard(homeDirectory: self.homeDirectory)
        self.sizer = sizer
        self.sessionReader = sessionReader
    }

    /// 执行全量只读扫描
    public func scan(customDirectories: [CustomScanDirectory] = []) -> ScanReport {
        let fileManager = FileManager.default
        var summaries: [ClientScanSummary] = []
        var detectedBuiltInCount = 0
        var totalSkippedProtected = 0

        // 1. 扫描内置 AI 客户端规则，仅展示本机实际存在且可清理的条目
        for profile in builtInProfiles {
            if Task.isCancelled { break }
            let result = scanProfile(profile, fileManager: fileManager)
            totalSkippedProtected += result.skippedProtectedCount

            if !result.items.isEmpty {
                detectedBuiltInCount += 1
                summaries.append(result)
            }
        }

        // 内置客户端按占用空间降序排列，方便用户优先看到空间大户
        summaries.sort { lhs, rhs in
            if lhs.totalSizeBytes != rhs.totalSizeBytes {
                return lhs.totalSizeBytes > rhs.totalSizeBytes
            }
            return lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
        }

        // 2. 扫描用户自定义目录（即便当前为空也保留分组，便于在侧栏查看或移除）
        for customDirectory in customDirectories {
            if Task.isCancelled { break }
            let profile = customDirectory.toClientProfile()
            let result = scanProfile(profile, fileManager: fileManager)
            totalSkippedProtected += result.skippedProtectedCount
            summaries.append(result)
        }

        return ScanReport(
            scannedAt: Date(),
            clientSummaries: summaries,
            totalBuiltInProfilesCount: builtInProfiles.count,
            detectedBuiltInClientsCount: detectedBuiltInCount,
            skippedProtectedCount: totalSkippedProtected
        )
    }

    // MARK: - Private

    private func scanProfile(
        _ profile: AIClientProfile,
        fileManager: FileManager
    ) -> ClientScanSummary {
        var discoveredItems: [CleanableItem] = []
        var seenPaths: Set<String> = []
        var skippedProtectedCount = 0

        for rule in profile.rules {
            if Task.isCancelled { break }
            let targetURL = rule.resolveURL(homeDirectory: homeDirectory)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
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
                guard seenPaths.insert(canonicalPath).inserted else { continue }

                discoveredItems.append(
                    CleanableItem(
                        clientID: profile.id,
                        clientName: profile.name,
                        ruleID: rule.id,
                        displayName: rule.displayName,
                        fileName: targetURL.lastPathComponent,
                        url: targetURL,
                        category: rule.category,
                        safetyNote: rule.explanation,
                        sizeBytes: inspection.sizeBytes,
                        fileCount: inspection.fileCount,
                        modifiedAt: inspection.modifiedAt,
                        isDirectory: inspection.isDirectory,
                        isCustom: profile.isCustom
                    )
                )

            case .children:
                // 内置规则允许进入会话根容器逐项扫描，自定义目录仍须通过完整自定义根目录校验
                let rootCheck = profile.isCustom
                    ? safetyGuard.validateCustomDirectoryRoot(targetURL)
                    : safetyGuard.validateBuiltInContainer(targetURL)
                guard rootCheck.isAllowed else {
                    skippedProtectedCount += 1
                    continue
                }

                guard isDir.boolValue else {
                    // 若规则指向的是单个文件而非目录，回退按单文件检查
                    let fileCheck = safetyGuard.validateTarget(targetURL, fileManager: fileManager)
                    guard fileCheck.isAllowed,
                          let inspection = sizer.inspect(url: targetURL, safetyGuard: safetyGuard, fileManager: fileManager) else {
                        skippedProtectedCount += 1
                        continue
                    }
                    let canonicalPath = targetURL.standardizedFileURL.path
                    guard seenPaths.insert(canonicalPath).inserted else { continue }
                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: targetURL.lastPathComponent,
                            fileName: targetURL.lastPathComponent,
                            url: targetURL,
                            category: rule.category,
                            safetyNote: rule.explanation,
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

                    // 跳过 macOS Finder 元数据文件
                    if childURL.lastPathComponent == ".DS_Store" {
                        continue
                    }

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

                    // 内置规则跳过空子目录，减少界面干扰
                    if !profile.isCustom && inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                        continue
                    }

                    let canonicalPath = childURL.standardizedFileURL.path
                    guard seenPaths.insert(canonicalPath).inserted else { continue }

                    let displayName: String
                    if rule.category == .sessions {
                        displayName = sessionReader.buildFlatSessionDisplayName(
                            itemURL: childURL,
                            isDirectory: inspection.isDirectory
                        )
                    } else {
                        displayName = childURL.lastPathComponent
                    }

                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: displayName,
                            fileName: childURL.lastPathComponent,
                            url: childURL,
                            category: rule.category,
                            safetyNote: rule.explanation,
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
                        guard seenPaths.insert(canonicalPath).inserted else { continue }

                        let displayName = sessionReader.buildProjectSessionDisplayName(
                            itemURL: sessionURL,
                            projectFolderName: projectFolderName,
                            isDirectory: inspection.isDirectory,
                            fileManager: fileManager
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
                                safetyNote: rule.explanation,
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
                    guard seenPaths.insert(canonicalPath).inserted else { continue }

                    let displayName = sessionReader.buildFlatSessionDisplayName(
                        itemURL: fileURL,
                        isDirectory: false
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
                            safetyNote: rule.explanation,
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

        return ClientScanSummary(
            profile: profile,
            items: discoveredItems,
            skippedProtectedCount: skippedProtectedCount
        )
    }
}
