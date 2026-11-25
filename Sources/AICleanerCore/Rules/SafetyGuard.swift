import Darwin
import Foundation

/// 安全策略判定结果
public enum SafetyDecision: Equatable, Sendable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var blockReason: String? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }
}

/// 路径与内容安全护栏：
/// 1. 阻止系统关键目录、用户主目录及客户端根目录被整体扫描或删除；
/// 2. 明确排除登录态、凭据、API Key、核心配置、用户知识库及主数据库文件；
/// 3. 在扫描与移入废纸篓前双重校验，并拦截指向受保护路径的符号链接。
public struct SafetyGuard: Sendable {
    public let homeDirectory: URL

    private let homePathVariants: Set<String>
    private let lowerHomePathVariants: Set<String>
    private let cachesPathPrefixes: [String]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let standardized = homeDirectory.standardizedFileURL
        self.homeDirectory = standardized

        let rawHome = Self.normalizePath(standardized.path)
        let resolvedHome = Self.normalizePath(standardized.resolvingSymlinksInPath().standardizedFileURL.path)
        self.homePathVariants = Set([rawHome, resolvedHome])
        self.lowerHomePathVariants = Set(self.homePathVariants.map { $0.lowercased() })
        self.cachesPathPrefixes = Array(self.homePathVariants).map { "\($0)/Library/Caches/" }
    }

    /// 校验内置规则在展开子会话或子项时的容器目录本身是否安全（严禁进入系统核心目录或隐私敏感子树，
    /// 同时允许内置规则深入 `~/.claude/projects`、`~/.codex/sessions` 等会话根容器去逐条扫描，
    /// 而这些根容器本身依然被禁止整体删除或添加为整体清理项）。
    public func validateBuiltInContainer(_ url: URL) -> SafetyDecision {
        validateBasePath(url, allowHomeSubdirectoryRoots: true)
    }

    /// 校验用户尝试添加的「自定义扫描目录」根路径是否安全
    public func validateCustomDirectoryRoot(_ url: URL) -> SafetyDecision {
        let pathCheck = validateBasePath(url, allowHomeSubdirectoryRoots: false)
        if !pathCheck.isAllowed {
            return pathCheck
        }

        let nameCheck = validateEntry(url: url, isDirectory: true)
        if !nameCheck.isAllowed {
            return nameCheck
        }

        return .allowed
    }

    /// 校验单条待展示或待移入废纸篓的目标路径，不遍历目录内容。
    public func validateTarget(_ url: URL, fileManager: FileManager = .default) -> SafetyDecision {
        validateTarget(url, allowUserOverride: false)
    }

    /// 校验单条显式覆盖的目标路径。执行清理时仍须复核目录后代。
    public func validateUserOverrideTarget(_ url: URL, fileManager: FileManager = .default) -> SafetyDecision {
        validateTarget(url, allowUserOverride: true)
    }

    /// 规范化 `/tmp` 符号链接路径（将 `/tmp/...` 及直接符号链接父目录解析为真实父路径，同时保留末级符号链接身份不穿透）。
    public static func normalizeTempPath(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        if path == "/tmp" {
            return URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        }
        if path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path).standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent()
        let parentIsSymlink = (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        if parentIsSymlink {
            let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
            return resolvedParent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
        }
        return standardized
    }

    private func validateTarget(_ url: URL, allowUserOverride: Bool) -> SafetyDecision {
        let pathCheck = validateBasePath(url, allowHomeSubdirectoryRoots: false)
        guard pathCheck.isAllowed else { return pathCheck }

        let specialNodeCheck = Self.validateSpecialNode(atPath: url.path)
        guard specialNodeCheck.isAllowed else { return specialNodeCheck }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let parentPath = Self.normalizePath(url.deletingLastPathComponent().resolvingSymlinksInPath().path)
            let resolvedPath = Self.normalizePath(resolved.path)
            guard resolvedPath.hasPrefix(parentPath + "/") || resolvedPath == parentPath else {
                return .blocked(reason: "跳过指向扫描目录外部的符号链接")
            }

            let resolvedSpecialCheck = Self.validateSpecialNode(atPath: resolved.path)
            guard resolvedSpecialCheck.isAllowed else { return resolvedSpecialCheck }

            if !allowUserOverride {
                let resolvedIsDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let check = validateEntry(url: resolved, isDirectory: resolvedIsDir)
                if let reason = check.blockReason {
                    return .blocked(reason: "符号链接指向受保护条目：\(reason)")
                }
            }
        }

        return allowUserOverride ? .allowed : validateSoftProtection(url: url, isDirectory: values?.isDirectory ?? false)
    }

    /// 校验单个文件或子目录的名称与扩展名是否属于受保护资产
    public func validateEntry(url: URL, isDirectory: Bool) -> SafetyDecision {
        let hardCheck = validateHardProtection(path: url.path)
        guard hardCheck.isAllowed else { return hardCheck }
        return validateSoftProtection(url: url, isDirectory: isDirectory)
    }

    private func validateSoftProtection(url: URL, isDirectory: Bool) -> SafetyDecision {
        let fileName = url.lastPathComponent
        let lowerName = fileName.lowercased()

        if lowerName.isEmpty || lowerName == "." || lowerName == ".." {
            return .blocked(reason: "无效的文件名")
        }

        if isDirectory {
            if lowerName == ".git" {
                return .blocked(reason: "受保护的应用状态或敏感目录：\(fileName)")
            }
            if Self.userDataProtectedDirectoryNames.contains(lowerName) && !isInsideMacOSCachesDirectory(url: url) {
                return .blocked(reason: "受保护的应用状态/用户数据目录：\(fileName)")
            }
        } else {
            if Self.protectedFileNames.contains(lowerName) {
                return .blocked(reason: "受保护的核心配置文件：\(fileName)")
            }

            if Self.protectedFilePrefixes.contains(where: { lowerName.hasPrefix($0) }) {
                return .blocked(reason: "受保护的核心配置文件：\(fileName)")
            }

            let ext = (Self.databaseBaseName(lowerName) as NSString).pathExtension
            if Self.protectedDatabaseExtensions.contains(ext) {
                // 仅允许 macOS ~/Library/Caches/ 下由 URLCache 生成的临时 Cache.db* 文件
                if isMacOSURLCacheFile(url: url, lowerFileName: lowerName) {
                    return .allowed
                }
                return .blocked(reason: "受保护的数据库文件：\(fileName)")
            }
        }

        return .allowed
    }

    /// 清理前复核目标与目录后代。显式覆盖只跳过可覆盖的名称与扩展名规则。
    public func validateTargetRecursively(
        _ url: URL,
        fileManager: FileManager = .default,
        allowUserOverride: Bool = false
    ) -> SafetyDecision {
        let baseDecision = validateTarget(url, allowUserOverride: allowUserOverride)
        guard baseDecision.isAllowed else { return baseDecision }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .allowed
        }

        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            return .blocked(reason: "无法检查目录内容")
        }

        for case let childURL as URL in enumerator {
            guard let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey]) else {
                return .blocked(reason: "无法检查目录内的条目：\(childURL.lastPathComponent)")
            }
            if let resourceType = values.fileResourceType,
               Self.isSpecialResourceType(resourceType) {
                return .blocked(reason: "目录内包含特殊系统节点（Socket/FIFO/设备文件）：\(childURL.lastPathComponent)")
            }
            if let reason = Self.validateSpecialNode(atPath: childURL.path).blockReason {
                return .blocked(reason: "目录内包含受保护内容：\(reason)")
            }
            let isSymlink = values.isSymbolicLink == true
            let decision = allowUserOverride
                ? validateHardProtection(path: childURL.path)
                : validateEntry(url: childURL, isDirectory: values.isDirectory == true && !isSymlink)
            if let reason = decision.blockReason {
                return .blocked(reason: "目录内包含受保护内容：\(reason)")
            }
            if isSymlink {
                let resolved = childURL.resolvingSymlinksInPath()
                if let reason = validateHardProtection(path: resolved.path).blockReason {
                    return .blocked(reason: "目录内的符号链接指向受保护内容：\(reason)")
                }
                if let reason = Self.validateSpecialNode(atPath: resolved.path).blockReason {
                    return .blocked(reason: "目录内的符号链接指向特殊系统节点：\(reason)")
                }
            }
        }

        return enumerationFailed ? .blocked(reason: "无法完整检查目录内容") : .allowed
    }

    // MARK: - Private Helpers

    private func validateHardProtection(path: String) -> SafetyDecision {
        let lowerPath = path.lowercased()
        let components = lowerPath.split(separator: "/")
        let fileName = (path as NSString).lastPathComponent
        let baseName = Self.databaseBaseName(fileName.lowercased())

        if let component = components.first(where: { Self.hardProtectedStorageNames.contains(String($0)) }) {
            return .blocked(reason: "已锁定登录态或客户端数据：\(component)")
        }
        if let subtree = Self.hardProtectedUserSubtrees.first(where: { subtree in
            lowerHomePathVariants.contains { home in
                let root = "\(home)/\(subtree)"
                return lowerPath == root || lowerPath.hasPrefix(root + "/")
            }
        }) {
            return .blocked(reason: "已锁定凭据或客户端存储：~/\(subtree)")
        }
        if fileName.lowercased().hasSuffix(".sock") {
            return .blocked(reason: "Unix Domain Socket 文件不允许清理：\(fileName)")
        }
        if Self.mainDatabaseNames.contains(baseName) {
            return .blocked(reason: "已锁定客户端主数据库及附属文件：\(fileName)")
        }
        if Self.credentialFileNames.contains(baseName)
            || Self.credentialFilePrefixes.contains(where: { baseName.hasPrefix($0) })
            || Self.credentialKeywords.contains(where: { baseName.contains($0) })
            || Self.credentialExtensions.contains((baseName as NSString).pathExtension) {
            return .blocked(reason: "已锁定登录凭据或密钥：\(fileName)")
        }

        return .allowed
    }

    private static func isSpecialResourceType(_ type: URLFileResourceType) -> Bool {
        type == .socket || type == .namedPipe || type == .characterSpecial || type == .blockSpecial
    }

    private static func validateSpecialNode(atPath path: String) -> SafetyDecision {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .allowed
        }
        let modeType = st.st_mode & S_IFMT
        if modeType == S_IFSOCK || modeType == S_IFIFO || modeType == S_IFCHR || modeType == S_IFBLK {
            let name = (path as NSString).lastPathComponent
            return .blocked(reason: "特殊系统节点（Socket/FIFO/设备文件）不允许清理：\(name)")
        }
        return .allowed
    }

    private static func databaseBaseName(_ name: String) -> String {
        guard let suffix = databaseSidecarSuffixes.first(where: { name.hasSuffix($0) }) else { return name }
        return String(name.dropLast(suffix.count))
    }

    private func validateBasePath(_ url: URL, allowHomeSubdirectoryRoots: Bool) -> SafetyDecision {
        guard url.isFileURL else {
            return .blocked(reason: "仅支持本地文件路径")
        }

        let candidates = pathCandidates(for: url)
        for path in candidates {
            let hardCheck = validateHardProtection(path: path)
            guard hardCheck.isAllowed else { return hardCheck }

            if path.isEmpty || Self.blockedExactSystemPaths.contains(path) {
                return .blocked(reason: "系统根目录或核心路径不允许操作：\(path)")
            }

            for prefix in Self.blockedSystemPrefixes where path.hasPrefix(prefix) {
                return .blocked(reason: "系统受保护目录不允许操作：\(path)")
            }

            if homePathVariants.contains(path) {
                return .blocked(reason: "用户主目录不允许作为清理目标")
            }

            for home in homePathVariants {
                for relativeSensitive in Self.blockedSensitiveUserSubtrees {
                    let full = "\(home)/\(relativeSensitive)"
                    if path == full || path.hasPrefix(full + "/") {
                        return .blocked(reason: "系统或隐私敏感目录受保护，禁止扫描与清理：~/\(relativeSensitive)")
                    }
                }

                if !allowHomeSubdirectoryRoots {
                    for relativeRoot in Self.blockedExactUserRoots {
                        let full = "\(home)/\(relativeRoot)"
                        if path == full {
                            return .blocked(reason: "不能直接清理整个目录，请仅选择其缓存或日志子目录：~/\(relativeRoot)")
                        }
                    }
                }
            }
        }

        return .allowed
    }

    private func pathCandidates(for url: URL) -> [String] {
        let raw = Self.normalizePath(url.standardizedFileURL.path)
        let resolved = Self.normalizePath(url.resolvingSymlinksInPath().standardizedFileURL.path)
        if raw == resolved {
            return [raw]
        }
        return [raw, resolved]
    }

    private func isInsideMacOSCachesDirectory(url: URL) -> Bool {
        let candidates = pathCandidates(for: url)
        return candidates.contains { candidate in
            cachesPathPrefixes.contains { candidate.hasPrefix($0) }
        }
    }

    private func isMacOSURLCacheFile(url: URL, lowerFileName: String) -> Bool {
        guard Self.databaseBaseName(lowerFileName) == "cache.db" else {
            return false
        }
        let resolvedPath = Self.normalizePath(url.resolvingSymlinksInPath().standardizedFileURL.path)
        return cachesPathPrefixes.contains { resolvedPath.hasPrefix($0) }
    }

    private static func normalizePath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    // MARK: - Policy Constants

    private static let blockedExactSystemPaths: Set<String> = [
        "/",
        "/System",
        "/Library",
        "/Applications",
        "/Users",
        "/Volumes",
        "/bin",
        "/sbin",
        "/usr",
        "/etc",
        "/private",
        "/private/etc",
        "/private/var",
        "/var",
        "/dev",
        "/cores",
        "/opt",
        "/tmp",
        "/private/tmp",
        "/var/folders",
        "/private/var/folders"
    ]

    private static let blockedSystemPrefixes: [String] = [
        "/System/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/etc/",
        "/private/etc/",
        "/dev/",
        "/cores/",
        "/Library/Keychains/",
        "/Library/Preferences/",
        "/private/var/db/",
        "/var/db/",
        "/private/var/root/",
        "/var/root/"
    ]

    /// 这些敏感目录及其下所有子项永不允许扫描或清理
    private static let blockedSensitiveUserSubtrees: [String] = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".docker",
        "Library/Keychains",
        "Library/Preferences",
        "Library/Cookies",
        "Library/HTTPStorages",
        "Library/Accounts",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Application Support/AddressBook"
    ]

    /// 这些顶层目录、AI 客户端根目录及会话总目录本身不能被整体勾选/清理
    private static let blockedExactUserRoots: [String] = [
        "Desktop",
        "Documents",
        "Downloads",
        "Pictures",
        "Movies",
        "Music",
        "Public",
        "Applications",
        "Library",
        "Library/Application Support",
        "Library/Caches",
        "Library/Logs",
        ".config",
        ".local",
        ".local/share",
        ".cache",
        ".claude",
        ".claude/projects",
        ".claude/sessions",
        ".codex",
        ".codex/sessions",
        ".codex/archived_sessions",
        ".codex/multica-sessions",
        ".cursor",
        ".cursor/chats",
        ".cursor/projects",
        ".codeium",
        ".codeium/windsurf",
        ".codeium/windsurf/cascade",
        ".opencode",
        ".local/share/opencode",
        ".local/share/opencode/storage",
        ".local/share/opencode/storage/session",
        ".pi",
        ".pi/agent",
        ".pi/agent/sessions",
        ".gemini",
        ".gemini/antigravity",
        ".gemini/antigravity-cli",
        ".gemini/antigravity/brain",
        ".gemini/antigravity-cli/brain",
        ".workbuddy",
        ".workbuddy/projects",
        ".workbuddy/workspace",
        ".workbuddy/workspace/sessions",
        ".workbuddy-ai",
        ".workbuddy-ai/projects",
        "WorkBuddy",
        ".codebuddy",
        "Doubao",
        "DoubaoWork",
        ".doubao",
        ".doubao/lark-chats",
        ".dsh",
        ".dsh/sessions",
        ".trae",
        ".trae-cn",
        ".qoder",
        ".lingma",
        ".kiro",
        ".zcode",
        ".zcode/projects",
        ".copilot",
        ".copilot/session-state",
        ".cherrystudio",
        ".ollama",
        ".lmstudio",
        ".t3",
        ".multica",
        ".multica/pi-sessions",
        "Library/Application Support/Claude",
        "Library/Application Support/Claude/local-agent-mode-sessions",
        "Library/Application Support/Claude/claude-code-sessions",
        "Library/Application Support/Cursor",
        "Library/Application Support/Codex",
        "Library/Application Support/Windsurf",
        "Library/Application Support/com.openai.chat",
        "Library/Application Support/OpenAI",
        "Library/Application Support/WorkBuddy",
        "Library/Application Support/WorkDaddy",
        "Library/Application Support/Doubao",
        "Library/Application Support/jianyin_agent",
        "Library/Application Support/@deepseek-ai",
        "Library/Application Support/@deepseek-ai/dsh-desktop",
        "Library/Application Support/Trae",
        "Library/Application Support/Trae CN",
        "Library/Application Support/Qoder",
        "Library/Application Support/Kiro",
        "Library/Application Support/ZCode",
        "Library/Application Support/ai.z.zcode",
        "Library/Application Support/chatglm",
        "Library/Application Support/Antigravity",
        "Library/Application Support/Multica",
        "Library/Application Support/CherryStudio",
        "Library/Application Support/anythingllm-desktop",
        "Library/Application Support/LM Studio",
        "Library/Application Support/stepfun-desktop",
        "Library/Application Support/t3code-v2",
        "Library/Application Support/Kimi",
        "Library/Application Support/Tencent Yuanbao",
        "Library/Application Support/xyz.chatboxapp.app",
        "Library/Application Support/Jan"
    ]

    private static let hardProtectedStorageNames: Set<String> = [
        "local storage", "session storage", "indexeddb", "webstorage", "globalstorage",
        "workspacestorage", "keychains", "httpstorages", "cookies", ".ssh", ".gnupg"
    ]

    private static let hardProtectedUserSubtrees: [String] = [
        ".codeium/database",
        ".workbuddy/security",
        ".multica/profiles",
        "library/application support/workdaddy/accounts",
        "library/application support/ai.z.zcode",
        "library/application support/anythingllm-desktop/storage"
    ]

    /// 用户知识库、配置与扩展数据目录名（在 ~/Library/Caches/ 系统缓存目录之外严格受保护，
    /// 避免误伤用户配置与项目记忆，同时允许清理 ~/Library/Caches 下 Sparkle 等自动更新器遗留的临时安装包缓存）
    private static let userDataProtectedDirectoryNames: Set<String> = [
        "databases",
        "database",
        "memory",
        "memories",
        "memories_v2",
        "projects",
        "skills",
        "commands",
        "hooks",
        "plugins",
        "extensions"
    ]

    private static let credentialFileNames: Set<String> = [
        "auth.json",
        "auth.lock",
        "credentials.json",
        "credentials",
        ".credentials.yaml",
        "oauth_creds.json",
        "google_accounts.json",
        "trae-jwt-token",
        "zcode-auth-store.dat",
        "inner-provider-api-keys.dat",
        ".env",
        ".netrc",
        ".npmrc",
        ".pypirc",
        "id_rsa",
        "id_rsa.pub",
        "id_ed25519",
        "id_ed25519.pub",
        "known_hosts",
        "authorized_keys",
        "token.json",
        "tokens.json",
        "secrets.json",
        "cookies",
        "singletoncookie",
        "local state",
        "login data",
        "login data for account"
    ]

    /// 普通清理保护的配置与核心状态文件名。
    private static let protectedFileNames: Set<String> = [
        "daemon.id",
        "preferences",
        "settings.json",
        "setting.json",
        "settings.yaml",
        "public_config.json",
        "automations.json",
        "config.json",
        "config.toml",
        "config.yaml",
        "config.yml",
        "models.json",
        "models-store.json",
        "claude_desktop_config.json",
        "mcp.json",
        "mcp-config.json",
        "lingma_mcp.json",
        "argv.json",
        "keybindings.json",
        "claude.md",
        "agents.md",
        "memory.md",
        ".claude.json",
        ".claude.json.backup",
        "history.jsonl",
        "sessions-index.json",
        "installation_id"
    ]

    private static let credentialFilePrefixes = [".env.", "auth.json."]
    private static let protectedFilePrefixes = ["config.toml.", "settings.json."]

    private static let credentialKeywords: [String] = [
        "api_key",
        "apikey",
        "api-key",
        "secret",
        "credential",
        "private_key",
        "private-key",
        "oauth",
        "access_token",
        "refresh_token",
        "id_token",
        "keychain",
        "passwd",
        "password"
    ]

    private static let mainDatabaseNames: Set<String> = [
        "opencode.db", "thread_history_1.sqlite", "memories_1.sqlite", "workbuddy.db",
        "credit-usage.db", "conversation_summaries.db", "state.vscdb", "state.vscdb.backup"
    ]

    private static let databaseSidecarSuffixes = ["-wal", "-shm", "-journal"]
    private static let protectedDatabaseExtensions: Set<String> = ["sqlite", "sqlite3", "vscdb", "db", "realm"]

    private static let credentialExtensions: Set<String> = [
        "keychain", "keychain-db", "pem", "p12", "pfx", "key", "jks", "keystore", "kdbx"
    ]
}
