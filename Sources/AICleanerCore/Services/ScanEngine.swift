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

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        builtInProfiles: [AIClientProfile] = BuiltInClientRules.allProfiles,
        safetyGuard: SafetyGuard? = nil,
        sizer: DirectorySizer = DirectorySizer()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.builtInProfiles = builtInProfiles
        self.safetyGuard = safetyGuard ?? SafetyGuard(homeDirectory: self.homeDirectory)
        self.sizer = sizer
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
                // 校验容器目录本身是否为禁止访问的敏感目录
                let rootCheck = safetyGuard.validateCustomDirectoryRoot(targetURL)
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

                    let canonicalPath = childURL.standardizedFileURL.path
                    guard seenPaths.insert(canonicalPath).inserted else { continue }

                    discoveredItems.append(
                        CleanableItem(
                            clientID: profile.id,
                            clientName: profile.name,
                            ruleID: rule.id,
                            displayName: childURL.lastPathComponent,
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
