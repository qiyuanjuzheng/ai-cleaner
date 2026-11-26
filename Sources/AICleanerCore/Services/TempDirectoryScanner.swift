#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `/tmp`（`/private/tmp`）与 macOS 系统用户临时目录（`DARWIN_USER_TEMP_DIR` / `NSTemporaryDirectory()`）
/// 的分层扫描结果：
/// - 第一层（高置信度 AI 特征）精准归入对应内置 AI 客户端，未单独建组的归入「其他 AI 临时文件（/tmp）」；
/// - 第二层（仅 `/private/tmp` 中未被第一层命中的当前用户普通条目）归入「/tmp 未归属临时项」，强制仅手选。
public struct TempDirectoryScanResult: Sendable {
    public let builtInClientItems: [String: [CleanableItem]]
    public let otherAITempSummary: ClientScanSummary?
    public let unattributedTempSummary: ClientScanSummary?
    public let skippedProtectedCount: Int

    public init(
        builtInClientItems: [String: [CleanableItem]] = [:],
        otherAITempSummary: ClientScanSummary? = nil,
        unattributedTempSummary: ClientScanSummary? = nil,
        skippedProtectedCount: Int = 0
    ) {
        self.builtInClientItems = builtInClientItems
        self.otherAITempSummary = otherAITempSummary
        self.unattributedTempSummary = unattributedTempSummary
        self.skippedProtectedCount = skippedProtectedCount
    }
}

/// 分层系统临时目录扫描器（方案 B）：
/// 1. 仅扫描当前用户拥有的普通文件与目录，严格跳过其他用户、root、Socket、FIFO、设备节点与符号链接；
/// 2. 跳过当前应用自身、当前运行环境 `TMPDIR` 以及包含 `.task_lock` 或活跃锁文件的目录；
/// 3. 第一层按高置信度 AI 命名特征精准归属，并按 24 小时冷却期区分「建议清理」与「按需清理（仅手选）」；
/// 4. 第二层仅扫描 `/private/tmp` 顶层未归属非空条目，全部强制归为「按需清理（仅手选）」。
public struct TempDirectoryScanner: Sendable {
    public static let otherAITempClientID = "other-ai-temp"
    public static let unattributedTempClientID = "system-tmp-unattributed"

    public static func otherAITempProfile() -> AIClientProfile {
        AIClientProfile(
            id: otherAITempClientID,
            name: "其他 AI 临时文件（/tmp）",
            symbolName: "clock.arrow.circlepath",
            accentToken: "tempAI",
            description: "位于系统临时目录、具备明确 AI 工具或 Agent 特征但未单独建组的临时文件与目录",
            protectedSummary: "已跳过其他用户条目、Socket/FIFO/符号链接、活跃锁文件与当前运行环境 TMPDIR。",
            rules: [],
            isCustom: false,
            customDirectoryID: nil,
            kind: .otherAITemp
        )
    }

    public static func unattributedTempProfile() -> AIClientProfile {
        AIClientProfile(
            id: unattributedTempClientID,
            name: "/tmp 未归属临时项",
            symbolName: "folder.badge.questionmark",
            accentToken: "tempUnattributed",
            description: "位于 /private/tmp 且归属当前用户、无法自动确认是否由 AI 工具生成的临时文件与目录（仅支持逐条手动勾选）",
            protectedSummary: "仅展示当前用户非空普通文件/目录，已跳过隐藏缓存、Socket/FIFO/符号链接、活跃锁与凭据；所有批量勾选操作均跳过本组。",
            rules: [],
            isCustom: false,
            customDirectoryID: nil,
            kind: .unattributedTemp
        )
    }

    private enum PatternMatcher: Sendable {
        case exact(String)
        case prefix(String)
        case prefixAndSuffix(String, String)

        func matches(_ lowerName: String) -> Bool {
            switch self {
            case let .exact(expected):
                return lowerName == expected
            case let .prefix(prefix):
                return lowerName.hasPrefix(prefix)
            case let .prefixAndSuffix(prefix, suffix):
                return lowerName.hasPrefix(prefix) && lowerName.hasSuffix(suffix)
            }
        }
    }

    private struct SignatureRule: Sendable {
        let clientID: String
        let matchers: [PatternMatcher]
    }

    /// 第一层高置信度 AI 特征规则（按特异性从高到低排列，如 `claude-desktop*` 优先于 `claude-*`）
    private static let aiSignatureRules: [SignatureRule] = [
        SignatureRule(
            clientID: "claude-desktop",
            matchers: [
                .prefix("claude-desktop"),
                .prefix("com.anthropic.claudefordesktop")
            ]
        ),
        SignatureRule(
            clientID: "claude-code",
            matchers: [
                .prefix("claude-")
            ]
        ),
        SignatureRule(
            clientID: "codex",
            matchers: [
                .prefix("codex-"),
                .exact(".com.openai.codex"),
                .prefix(".com.openai.codex."),
                .exact("com.openai.codex"),
                .prefix("com.openai.codex."),
                .exact("com.openai.sky.cuaservice"),
                .prefix("com.openai.sky.cuaservice."),
                .prefix("com.openai.sky.cuaservice-")
            ]
        ),
        SignatureRule(
            clientID: "chatgpt-desktop",
            matchers: [
                .prefix("chatgpt-"),
                .prefix("com.openai.chat")
            ]
        ),
        SignatureRule(
            clientID: "opencode",
            matchers: [
                .exact("opencode"),
                .prefix("opencode-")
            ]
        ),
        SignatureRule(
            clientID: "cursor",
            matchers: [
                .prefix("cursor-"),
                .prefix("com.todesktop.230313mzl4w4u92")
            ]
        ),
        SignatureRule(
            clientID: "windsurf",
            matchers: [
                .prefix("windsurf-"),
                .prefix("codeium-")
            ]
        ),
        SignatureRule(
            clientID: "gemini-antigravity",
            matchers: [
                .exact("com.lbjlaq.antigravity-tools"),
                .prefix("com.lbjlaq.antigravity-tools"),
                .prefix("antigravity-"),
                .prefix("gemini-cli-")
            ]
        ),
        SignatureRule(
            clientID: "workbuddy",
            matchers: [
                .prefix("workbuddy-"),
                .prefix("codebuddy-")
            ]
        ),
        SignatureRule(
            clientID: "doubao",
            matchers: [
                .prefix("doubao-"),
                .prefix("doubaowork-")
            ]
        ),
        SignatureRule(
            clientID: "workdaddy",
            matchers: [
                .prefix("workdaddy-")
            ]
        ),
        SignatureRule(
            clientID: "deepseek",
            matchers: [
                .prefix("deepseek-")
            ]
        ),
        SignatureRule(
            clientID: "trae",
            matchers: [
                .prefix("trae-")
            ]
        ),
        SignatureRule(
            clientID: "qoder",
            matchers: [
                .prefix("qoder-")
            ]
        ),
        SignatureRule(
            clientID: "lingma",
            matchers: [
                .prefix("lingma-")
            ]
        ),
        SignatureRule(
            clientID: "kiro",
            matchers: [
                .prefix("kiro-")
            ]
        ),
        SignatureRule(
            clientID: "zcode",
            matchers: [
                .prefix("zcode-"),
                .prefix("chatglm-")
            ]
        ),
        SignatureRule(
            clientID: "multica",
            matchers: [
                .prefix("multica-task-"),
                .prefix("multica-")
            ]
        ),
        SignatureRule(
            clientID: "pi",
            matchers: [
                .prefixAndSuffix("pi-bash-", ".log"),
                .prefix("pi-agent-"),
                .prefix("pi-coding-agent-")
            ]
        ),
        SignatureRule(
            clientID: "t3-code",
            matchers: [
                .prefix("t3code"),
                .prefix("t3-code")
            ]
        ),
        SignatureRule(
            clientID: "copilot",
            matchers: [
                .prefix("copilot-"),
                .prefix("github-copilot-")
            ]
        ),
        SignatureRule(
            clientID: "cherry-studio",
            matchers: [
                .prefix("cherry-studio-"),
                .prefix("cherrystudio-")
            ]
        ),
        SignatureRule(
            clientID: "anythingllm",
            matchers: [
                .prefix("anythingllm-")
            ]
        ),
        SignatureRule(
            clientID: "stepfun",
            matchers: [
                .prefix("stepfun-")
            ]
        ),
        SignatureRule(
            clientID: "kimi",
            matchers: [
                .prefix("kimi-"),
                .prefix("com.moonshot.kimi")
            ]
        ),
        SignatureRule(
            clientID: "yuanbao",
            matchers: [
                .prefix("yuanbao-"),
                .prefix("com.tencent.yuanbao")
            ]
        ),
        SignatureRule(
            clientID: "ollama",
            matchers: [
                .exact("ollama"),
                .prefix("ollama-")
            ]
        ),
        SignatureRule(
            clientID: "lm-studio",
            matchers: [
                .prefix("lm-studio-"),
                .prefix("lmstudio-")
            ]
        ),
        SignatureRule(
            clientID: "chatbox",
            matchers: [
                .prefix("chatbox-"),
                .prefix("xyz.chatboxapp.app")
            ]
        ),
        SignatureRule(
            clientID: "jan",
            matchers: [
                .prefix("jan-ai-"),
                .prefix("jan.ai.app")
            ]
        ),
        SignatureRule(
            clientID: "zed",
            matchers: [
                .prefix("zed-"),
                .prefix("dev.zed.zed")
            ]
        ),
        // 未在 31 款内置客户端中单独建组的其他 AI / Agent 运行时临时项
        SignatureRule(
            clientID: otherAITempClientID,
            matchers: [
                .prefix("magpie-"),
                .prefix("aider-"),
                .prefix("cline-"),
                .prefix("roo-code-"),
                .prefix("openclaw-"),
                .prefix("continue-dev-"),
                .prefix("ampcode-"),
                .prefix("goose-ai-")
            ]
        )
    ]

    private static let alwaysActiveLockFileNames: Set<String> = [
        ".task_lock",
        "singletonlock",
        "singletonsocket"
    ]

    private static let lockExactFileNames: Set<String> = [
        "lock",
        ".lock",
        "lockfile",
        ".lockfile"
    ]

    private static let lockFileSuffixes: [String] = [
        ".lock",
        ".lck",
        ".pid"
    ]

    private static let ignoredSystemTempPrefixes: [String] = [
        "com.apple.launchd.",
        "powerlog"
    ]

    public let platform: any PlatformAdapter
    public let safetyGuard: SafetyGuard
    public let sizer: DirectorySizer
    public let cooldownHours: Int
    public let currentPrincipal: Principal
    public let activeTempDirectoryPath: String?
    public let ownerResolver: (@Sendable (URL) -> Principal?)?

    public init(
        safetyGuard: SafetyGuard,
        sizer: DirectorySizer? = nil,
        cooldownHours: Int = 24,
        currentPrincipal: Principal? = nil,
        activeTempDirectoryPath: String? = nil,
        useDefaultActiveTempPath: Bool = true,
        ownerResolver: (@Sendable (URL) -> Principal?)? = nil
    ) {
        let platform = safetyGuard.platform
        self.platform = platform
        self.safetyGuard = safetyGuard
        self.sizer = sizer ?? DirectorySizer(platform: platform)
        self.cooldownHours = max(1, cooldownHours)
        self.currentPrincipal = currentPrincipal ?? platform.currentPrincipal
        if let activeTempDirectoryPath {
            self.activeTempDirectoryPath = activeTempDirectoryPath
        } else if useDefaultActiveTempPath {
            self.activeTempDirectoryPath = platform.environmentVariable("TMPDIR")
        } else {
            self.activeTempDirectoryPath = nil
        }
        self.ownerResolver = ownerResolver
    }

    /// 判断顶层文件/目录名是否命中第一层高置信度 AI 特征规则，返回对应客户端 ID（含 `other-ai-temp`）。
    public static func classifyAIEntry(named fileName: String) -> String? {
        let lowerName = fileName.lowercased()
        for rule in aiSignatureRules {
            if rule.matchers.contains(where: { $0.matches(lowerName) }) {
                return rule.clientID
            }
        }
        return nil
    }

    /// 执行系统临时目录的分层只读扫描。
    public func scan(
        systemTempRoot: URL?,
        userTempRoot: URL?,
        builtInProfiles: [AIClientProfile],
        referenceNow: Date,
        excludedMatcher: ExcludedItemMatcher = ExcludedItemMatcher(),
        fileManager: FileManager = .default
    ) -> TempDirectoryScanResult {
        guard systemTempRoot != nil || userTempRoot != nil else {
            return TempDirectoryScanResult()
        }

        let profileByID = Dictionary(uniqueKeysWithValues: builtInProfiles.map { ($0.id, $0) })
        let cooldownCutoff = referenceNow.addingTimeInterval(-Double(cooldownHours) * 3600.0)
        let activeTempCanonicalPath = canonicalOptionalDirectoryPath(activeTempDirectoryPath, fileManager: fileManager)
        let selfProtectedPaths = currentProcessProtectedPaths()

        let canonicalSystemRoot = systemTempRoot.flatMap { canonicalExistingDirectory($0) }
        var canonicalUserRoot = userTempRoot.flatMap { canonicalExistingDirectory($0) }
        if let sys = canonicalSystemRoot, let usr = canonicalUserRoot,
           PlatformPath.comparisonKey(PlatformPath.normalize(sys), caseInsensitive: platform.pathsAreCaseInsensitive)
           == PlatformPath.comparisonKey(PlatformPath.normalize(usr), caseInsensitive: platform.pathsAreCaseInsensitive) {
            canonicalUserRoot = nil
        }

        var builtInItems: [String: [CleanableItem]] = [:]
        var otherAIItems: [CleanableItem] = []
        var unattributedItems: [CleanableItem] = []
        var claimedCanonicalPaths: Set<String> = []
        var skippedProtectedCount = 0

        let otherProfile = Self.otherAITempProfile()
        let unattributedProfile = Self.unattributedTempProfile()

        // MARK: 第一层扫描（systemTempRoot + userTempRoot 中的高置信度 AI 临时项）
        let layer1Roots: [(url: URL, isSystemTemp: Bool)] = [
            canonicalSystemRoot.map { ($0, true) },
            canonicalUserRoot.map { ($0, false) }
        ].compactMap { $0 }

        for root in layer1Roots {
            if Task.isCancelled { break }
            guard let entries = try? platform.contentsOfDirectory(at: root.url) else {
                continue
            }

            for rawEntryURL in entries {
                if Task.isCancelled { break }
                let entryURL = rawEntryURL.standardizedFileURL
                let fileName = entryURL.lastPathComponent
                guard let matchedClientID = Self.classifyAIEntry(named: fileName) else {
                    continue
                }

                let canonicalKey = PlatformPath.comparisonKey(
                    PlatformPath.normalize(entryURL),
                    caseInsensitive: platform.pathsAreCaseInsensitive
                )
                // 无论后续是否被排除、活跃锁或安全护栏跳过，已命中第一层命名特征的条目绝不落入第二层未归属区
                guard claimedCanonicalPaths.insert(canonicalKey).inserted else {
                    continue
                }

                if excludedMatcher.isExcluded(entryURL) {
                    continue
                }

                guard let inspection = inspectEligibleTopLevelEntry(
                    entryURL,
                    cooldownCutoff: cooldownCutoff,
                    activeTempCanonicalPath: activeTempCanonicalPath,
                    selfProtectedPaths: selfProtectedPaths,
                    fileManager: fileManager,
                    skippedProtectedCount: &skippedProtectedCount
                ) else {
                    continue
                }

                if inspection.isDirectory && inspection.fileCount == 0 && inspection.sizeBytes == 0 {
                    continue
                }

                let isRecentlyModified = inspection.modifiedAt > cooldownCutoff
                let recommendation: CleanupRecommendation = isRecentlyModified ? .reviewSuggested : .recommended
                let requiresIndividualSelection = isRecentlyModified
                let sourceBadge = root.isSystemTemp ? "临时文件（/tmp）" : "临时文件（系统临时目录）"
                let locationDesc = root.isSystemTemp ? "/tmp" : "系统用户临时目录"
                let safetyNote: String
                if isRecentlyModified {
                    safetyNote = "近期修改（\(cooldownHours) 小时内） · 位于 \(locationDesc)，疑似仍在使用，批量勾选已跳过，确认无需保留后可手动逐条勾选。"
                } else {
                    safetyNote = "位于 \(locationDesc) 的 AI 工具临时项，超过 \(cooldownHours) 小时未修改，可安全移入废纸篓。"
                }

                let targetProfile = profileByID[matchedClientID] ?? otherProfile
                let ruleID = root.isSystemTemp ? "system-tmp-ai-\(targetProfile.id)" : "user-tmp-ai-\(targetProfile.id)"

                let item = CleanableItem(
                    clientID: targetProfile.id,
                    clientName: targetProfile.name,
                    ruleID: ruleID,
                    displayName: fileName,
                    fileName: fileName,
                    url: entryURL,
                    category: .temporary,
                    recommendation: recommendation,
                    safetyNote: safetyNote,
                    sizeBytes: inspection.sizeBytes,
                    fileCount: inspection.fileCount,
                    modifiedAt: inspection.modifiedAt,
                    isDirectory: inspection.isDirectory,
                    isCustom: false,
                    requiresIndividualSelection: requiresIndividualSelection,
                    sourceBadge: sourceBadge,
                    isRecentlyModified: isRecentlyModified
                )

                if targetProfile.id == Self.otherAITempClientID {
                    otherAIItems.append(item)
                } else {
                    builtInItems[targetProfile.id, default: []].append(item)
                }
            }
        }

        // MARK: 第二层扫描（仅系统共享临时目录顶层未归属的当前用户非空普通项，严格仅手选）
        if let systemRoot = canonicalSystemRoot, !Task.isCancelled,
           let entries = try? platform.contentsOfDirectory(at: systemRoot) {
            for rawEntryURL in entries {
                if Task.isCancelled { break }
                let entryURL = rawEntryURL.standardizedFileURL
                let canonicalKey = PlatformPath.comparisonKey(
                    PlatformPath.normalize(entryURL),
                    caseInsensitive: platform.pathsAreCaseInsensitive
                )

                // 与第一层严格去重
                if claimedCanonicalPaths.contains(canonicalKey) {
                    continue
                }

                if excludedMatcher.isExcluded(entryURL) {
                    continue
                }

                let fileName = entryURL.lastPathComponent
                let lowerName = fileName.lowercased()

                // 忽略隐藏文件/目录（如 .sboxcache_*、.DS_Store、.X11-unix 等系统隐藏缓存）
                if fileName.hasPrefix(".") {
                    continue
                }
                if Self.ignoredSystemTempPrefixes.contains(where: { lowerName.hasPrefix($0) }) {
                    continue
                }

                guard let inspection = inspectEligibleTopLevelEntry(
                    entryURL,
                    cooldownCutoff: cooldownCutoff,
                    activeTempCanonicalPath: activeTempCanonicalPath,
                    selfProtectedPaths: selfProtectedPaths,
                    fileManager: fileManager,
                    skippedProtectedCount: &skippedProtectedCount
                ) else {
                    continue
                }

                // 第二层过滤 0 字节无效占位文件与空目录
                if inspection.sizeBytes <= 0 || (inspection.isDirectory && inspection.fileCount == 0) {
                    continue
                }

                guard claimedCanonicalPaths.insert(canonicalKey).inserted else {
                    continue
                }

                let isRecentlyModified = inspection.modifiedAt > cooldownCutoff
                let safetyNote: String
                if isRecentlyModified {
                    safetyNote = "近期修改（\(cooldownHours) 小时内） · 位于 /tmp，无法自动确认是否由 AI 工具生成，可能仍在使用，仅支持手动逐条勾选。"
                } else {
                    safetyNote = "位于 /tmp，无法自动确认是否由 AI 工具生成，确认无需保留后可手动逐条勾选。"
                }

                unattributedItems.append(
                    CleanableItem(
                        clientID: unattributedProfile.id,
                        clientName: unattributedProfile.name,
                        ruleID: "system-tmp-unattributed",
                        displayName: fileName,
                        fileName: fileName,
                        url: entryURL,
                        category: .temporary,
                        recommendation: .reviewSuggested,
                        safetyNote: safetyNote,
                        sizeBytes: inspection.sizeBytes,
                        fileCount: inspection.fileCount,
                        modifiedAt: inspection.modifiedAt,
                        isDirectory: inspection.isDirectory,
                        isCustom: false,
                        requiresIndividualSelection: true,
                        sourceBadge: "临时文件（/tmp）",
                        isRecentlyModified: isRecentlyModified
                    )
                )
            }
        }

        otherAIItems.sort(by: Self.defaultItemSort)
        unattributedItems.sort(by: Self.defaultItemSort)

        let otherSummary = otherAIItems.isEmpty
            ? nil
            : ClientScanSummary(profile: otherProfile, items: otherAIItems)
        let unattributedSummary = unattributedItems.isEmpty
            ? nil
            : ClientScanSummary(profile: unattributedProfile, items: unattributedItems)

        return TempDirectoryScanResult(
            builtInClientItems: builtInItems,
            otherAITempSummary: otherSummary,
            unattributedTempSummary: unattributedSummary,
            skippedProtectedCount: skippedProtectedCount
        )
    }

    // MARK: - Private Safety & Active-Process Checks

    private func inspectEligibleTopLevelEntry(
        _ entryURL: URL,
        cooldownCutoff: Date,
        activeTempCanonicalPath: String?,
        selfProtectedPaths: [String],
        fileManager: FileManager,
        skippedProtectedCount: inout Int
    ) -> PathInspectionResult? {
        let normalizedPath = PlatformPath.normalize(entryURL)
        let fileName = PlatformPath.lastPathComponent(normalizedPath)
        let lowerName = fileName.lowercased()

        // 1. 经由 PlatformAdapter 原子校验文件类型与属主，绝不穿透符号链接或 Windows 重解析点/目录联接
        guard let identity = try? platform.identity(at: entryURL) else {
            return nil
        }

        // 绝对跳过符号链接、Windows 重解析点/junction、Socket、FIFO、字符/块设备等特殊节点
        guard identity.kind == .regular || identity.kind == .directory else {
            skippedProtectedCount += 1
            return nil
        }

        // 跳过 Windows 隐藏或系统属性标记的文件/目录
        if identity.isHiddenOrSystem {
            skippedProtectedCount += 1
            return nil
        }

        // 仅限当前用户主体拥有的条目（绝对跳过 root / SYSTEM 或其他用户）
        let owner = ownerResolver?(entryURL) ?? identity.owner
        guard owner == currentPrincipal else {
            skippedProtectedCount += 1
            return nil
        }

        // 绝对跳过 *.sock 文件/目录
        if lowerName.hasSuffix(".sock") {
            skippedProtectedCount += 1
            return nil
        }

        // 2. 活跃进程保护：跳过当前应用自身与当前运行环境 TMPDIR
        if isCurrentAppEntry(lowerName: lowerName, canonicalPath: normalizedPath, selfProtectedPaths: selfProtectedPaths) {
            skippedProtectedCount += 1
            return nil
        }

        if let activeTempCanonicalPath,
           PlatformPath.isEqualOrDescendant(
               activeTempCanonicalPath,
               of: normalizedPath,
               caseInsensitive: platform.pathsAreCaseInsensitive
           ) {
            skippedProtectedCount += 1
            return nil
        }

        // 3. 顶层锁文件或近期锁目录直接跳过
        if isActiveLockEntry(
            url: entryURL,
            lowerName: lowerName,
            isDirectory: identity.kind == .directory,
            modifiedAt: identity.modifiedAt,
            cooldownCutoff: cooldownCutoff
        ) {
            skippedProtectedCount += 1
            return nil
        }

        // 4. SafetyGuard 路径与凭据/主库硬保护校验
        guard safetyGuard.validateTarget(entryURL, fileManager: fileManager).isAllowed else {
            skippedProtectedCount += 1
            return nil
        }

        // 5. 单遍遍历体积、最新修改时间、后代安全与活跃锁检测
        guard let inspection = sizer.inspect(
            url: entryURL,
            safetyGuard: safetyGuard,
            fileManager: fileManager,
            descendantValidator: { childURL, childIdentity in
                let childName = childURL.lastPathComponent.lowercased()
                if childName.hasSuffix(".sock") {
                    return "\(childURL.lastPathComponent)：包含 Unix Domain Socket"
                }
                if childIdentity.kind.isLinkOrReparsePoint {
                    let resolved = platform.resolveSymlinks(at: childURL)
                    if !safetyGuard.validateTarget(resolved, fileManager: fileManager).isAllowed {
                        return "\(childURL.lastPathComponent)：符号链接或重解析点指向受保护路径"
                    }
                }
                let childIsDir = childIdentity.kind == .directory
                if isActiveLockEntry(
                    url: childURL,
                    lowerName: childName,
                    isDirectory: childIsDir,
                    modifiedAt: childIdentity.modifiedAt,
                    cooldownCutoff: cooldownCutoff
                ) {
                    return "\(childURL.lastPathComponent)：包含活跃锁文件"
                }
                return nil
            }
        ) else {
            return nil
        }

        if inspection.protectedDescendantReason != nil {
            skippedProtectedCount += 1
            return nil
        }

        return inspection
    }

    private func canonicalExistingDirectory(_ url: URL) -> URL? {
        let resolved = platform.resolveSymlinks(at: url)
        guard let identity = try? platform.identity(at: resolved),
              identity.kind == .directory else {
            return nil
        }
        return resolved
    }

    private func canonicalOptionalDirectoryPath(_ rawPath: String?, fileManager: FileManager) -> String? {
        guard let rawPath = rawPath?.trimmedWhitespaceAndNewlines(), !rawPath.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: rawPath, isDirectory: true)
        if (try? platform.identity(at: url)) != nil {
            return PlatformPath.normalize(platform.resolveSymlinks(at: url))
        }
        return PlatformPath.normalize(SafetyGuard.normalizeTempPath(url, platform: platform))
    }

    private func currentProcessProtectedPaths() -> [String] {
        var paths: [String] = []
        if let executableURL = platform.currentExecutableURL {
            paths.append(PlatformPath.normalize(platform.resolveSymlinks(at: executableURL)))
        }
        let cwd = FileManager.default.currentDirectoryPath
        if !cwd.isEmpty {
            paths.append(PlatformPath.normalize(platform.resolveSymlinks(at: URL(fileURLWithPath: cwd))))
        }
        return paths
    }

    private func isCurrentAppEntry(lowerName: String, canonicalPath: String, selfProtectedPaths: [String]) -> Bool {
        for rawID in platform.selfIdentifiers {
            let id = rawID.lowercased()
            guard !id.isEmpty, !id.contains("xctest") else { continue }
            if lowerName == id || lowerName.hasPrefix(id + ".") || lowerName.hasPrefix(id + "-") || lowerName.hasPrefix(id) {
                return true
            }
        }
        for protectedPath in selfProtectedPaths {
            if PlatformPath.isEqualOrDescendant(
                protectedPath,
                of: canonicalPath,
                caseInsensitive: platform.pathsAreCaseInsensitive
            ) {
                return true
            }
        }
        return false
    }

    private func isActiveLockEntry(
        url: URL,
        lowerName: String,
        isDirectory: Bool,
        modifiedAt: Date,
        cooldownCutoff: Date
    ) -> Bool {
        if Self.alwaysActiveLockFileNames.contains(lowerName) {
            return true
        }
        let isLockLike = Self.lockExactFileNames.contains(lowerName)
            || lowerName.hasPrefix(".lock")
            || Self.lockFileSuffixes.contains(where: { lowerName.hasSuffix($0) })
        guard isLockLike else { return false }

        // 近期修改的锁文件或锁目录视为活跃锁
        if modifiedAt > cooldownCutoff {
            return true
        }

        guard !isDirectory else { return false }

        // 即使 mtime 较旧，若当前仍持有 OS 级文件锁（POSIX fcntl/flock 或 Windows 共享锁），仍视为活跃锁
        return platform.hasActiveFileLock(at: url)
    }

    private static func defaultItemSort(_ lhs: CleanableItem, _ rhs: CleanableItem) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes {
            return lhs.sizeBytes > rhs.sizeBytes
        }
        return lhs.modifiedAt > rhs.modifiedAt
    }
}
