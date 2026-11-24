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
    private let cachesPathPrefixes: [String]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let standardized = homeDirectory.standardizedFileURL
        self.homeDirectory = standardized

        let rawHome = Self.normalizePath(standardized.path)
        let resolvedHome = Self.normalizePath(standardized.resolvingSymlinksInPath().standardizedFileURL.path)
        self.homePathVariants = Set([rawHome, resolvedHome])
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

    /// 校验单条待展示或待移入废纸篓的目标路径是否安全（不含内部遍历）
    public func validateTarget(_ url: URL, fileManager: FileManager = .default) -> SafetyDecision {
        let pathCheck = validateBasePath(url, allowHomeSubdirectoryRoots: false)
        if !pathCheck.isAllowed {
            return pathCheck
        }

        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDirectory = resourceValues?.isDirectory ?? false
        let isSymlink = resourceValues?.isSymbolicLink ?? false

        if isSymlink {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let resolvedPathCheck = validateBasePath(resolved, allowHomeSubdirectoryRoots: false)
            if !resolvedPathCheck.isAllowed {
                return .blocked(reason: "符号链接指向受保护路径：\(resolved.path)")
            }
            let resolvedIsDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let resolvedEntryCheck = validateEntry(url: resolved, isDirectory: resolvedIsDir)
            if !resolvedEntryCheck.isAllowed {
                return .blocked(reason: "符号链接指向受保护条目：\(resolved.lastPathComponent)")
            }
            // 阻止指向目标父目录之外的符号链接，避免误操作跨目录数据
            let parentPath = Self.normalizePath(url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path)
            let resolvedPath = Self.normalizePath(resolved.path)
            if !resolvedPath.hasPrefix(parentPath + "/") && resolvedPath != parentPath {
                return .blocked(reason: "跳过指向扫描目录外部的符号链接")
            }
        }

        let entryCheck = validateEntry(url: url, isDirectory: isDirectory)
        if !entryCheck.isAllowed {
            return entryCheck
        }

        // 若目标存在且是目录，额外保护空字符串/异常路径
        if fileManager.fileExists(atPath: url.path) == false && !isSymlink {
            return .allowed
        }

        return .allowed
    }

    /// 校验单个文件或子目录的名称与扩展名是否属于受保护资产
    public func validateEntry(url: URL, isDirectory: Bool) -> SafetyDecision {
        let fileName = url.lastPathComponent
        let lowerName = fileName.lowercased()

        if lowerName.isEmpty || lowerName == "." || lowerName == ".." {
            return .blocked(reason: "无效的文件名")
        }

        if isDirectory {
            if Self.alwaysProtectedDirectoryNames.contains(lowerName) {
                return .blocked(reason: "受保护的应用状态或敏感目录：\(fileName)")
            }
            if Self.userDataProtectedDirectoryNames.contains(lowerName) && !isInsideMacOSCachesDirectory(url: url) {
                return .blocked(reason: "受保护的应用状态/用户数据目录：\(fileName)")
            }
        } else {
            if Self.protectedFileNames.contains(lowerName) {
                return .blocked(reason: "受保护的凭据或核心配置文件：\(fileName)")
            }

            for prefix in Self.protectedFilePrefixes where lowerName.hasPrefix(prefix) {
                return .blocked(reason: "受保护的环境或认证文件：\(fileName)")
            }

            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty && Self.protectedExtensions.contains(ext) {
                // 仅允许 macOS ~/Library/Caches/ 下由 URLCache 生成的临时 Cache.db* 文件
                if isMacOSURLCacheFile(url: url, lowerFileName: lowerName) {
                    return .allowed
                }
                return .blocked(reason: "受保护的数据库或密钥文件：\(fileName)")
            }
        }

        for keyword in Self.protectedKeywords where lowerName.contains(keyword) {
            return .blocked(reason: "包含敏感凭据关键词，已自动保护：\(fileName)")
        }

        return .allowed
    }

    /// 深度校验整个目录（包括内部所有子项）在移入废纸篓前是否完全安全
    public func validateTargetRecursively(_ url: URL, fileManager: FileManager = .default) -> SafetyDecision {
        let baseDecision = validateTarget(url, fileManager: fileManager)
        guard baseDecision.isAllowed else { return baseDecision }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .allowed
        }

        // 若目标本身是符号链接则不递归跟踪
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return baseDecision
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return .allowed
        }

        for case let childURL as URL in enumerator {
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let childIsSymlink = values?.isSymbolicLink ?? false
            let childIsDir = (values?.isDirectory ?? false) && !childIsSymlink
            let entryDecision = validateEntry(url: childURL, isDirectory: childIsDir)
            if !entryDecision.isAllowed {
                return .blocked(reason: "目录内包含受保护内容（\(childURL.lastPathComponent)）：\(entryDecision.blockReason ?? "受保护")")
            }
        }

        return .allowed
    }

    // MARK: - Private Helpers

    private func validateBasePath(_ url: URL, allowHomeSubdirectoryRoots: Bool) -> SafetyDecision {
        guard url.isFileURL else {
            return .blocked(reason: "仅支持本地文件路径")
        }

        let candidates = pathCandidates(for: url)
        for path in candidates {
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
        guard lowerFileName == "cache.db" || lowerFileName == "cache.db-wal" || lowerFileName == "cache.db-shm" else {
            return false
        }
        return isInsideMacOSCachesDirectory(url: url)
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
        "Library/Application Support/Claude",
        "Library/Application Support/Claude/local-agent-mode-sessions",
        "Library/Application Support/Claude/claude-code-sessions",
        "Library/Application Support/Cursor",
        "Library/Application Support/Codex",
        "Library/Application Support/Windsurf",
        "Library/Application Support/com.openai.chat",
        "Library/Application Support/OpenAI"
    ]

    /// 任何位置均严格受保护的登录态、存储与版本控制目录名（大小写不敏感）
    private static let alwaysProtectedDirectoryNames: Set<String> = [
        "local storage",
        "session storage",
        "indexeddb",
        "webstorage",
        "globalstorage",
        "workspacestorage",
        "keychains",
        "httpstorages",
        "cookies",
        ".git",
        ".ssh",
        ".gnupg"
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

    /// 明确受保护的凭据、配置与核心状态文件名（大小写不敏感）
    private static let protectedFileNames: Set<String> = [
        "auth.json",
        "auth.lock",
        "credentials.json",
        "credentials",
        "oauth_creds.json",
        "google_accounts.json",
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
        "cookies-journal",
        "singletoncookie",
        "local state",
        "preferences",
        "settings.json",
        "config.json",
        "config.toml",
        "config.yaml",
        "config.yml",
        "models.json",
        "models-store.json",
        "claude_desktop_config.json",
        "mcp.json",
        "argv.json",
        "keybindings.json",
        "claude.md",
        "agents.md",
        "memory.md",
        ".claude.json",
        ".claude.json.backup",
        "history.jsonl",
        "sessions-index.json",
        "installation_id",
        "state.vscdb",
        "state.vscdb.backup",
        "login.keychain-db"
    ]

    private static let protectedFilePrefixes: [String] = [
        ".env.",
        "auth.json.",
        "config.toml.",
        "settings.json."
    ]

    private static let protectedKeywords: [String] = [
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

    private static let protectedExtensions: Set<String> = [
        "sqlite",
        "sqlite3",
        "sqlite-wal",
        "sqlite-shm",
        "vscdb",
        "db",
        "db-wal",
        "db-shm",
        "realm",
        "keychain",
        "keychain-db",
        "pem",
        "p12",
        "pfx",
        "key",
        "jks",
        "keystore",
        "kdbx"
    ]
}
