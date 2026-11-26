#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Host-specific paths that stay outside scanning and cleanup, even after risk confirmation.
struct PlatformSafetyPolicy: Sendable {
    private let kind: PlatformKind
    private let homes: Set<String>
    private let protectedSubtrees: [String]
    private let alwaysBlockedExactRoots: Set<String>
    private let containerOnlyExactRoots: Set<String>

    init(platform: any PlatformAdapter, home: URL) {
        let kind = platform.platform
        let caseInsensitive = kind == .windows
        func keys(_ url: URL) -> [String] {
            let ancestorResolved = PlatformPath.resolveExistingAncestors(for: url, platform: platform)
            var results = [url, ancestorResolved, platform.resolveSymlinks(at: url)].map {
                PlatformPath.comparisonKey(PlatformPath.normalize($0), caseInsensitive: caseInsensitive)
            }
            #if os(macOS)
            // Apple Foundation's standardizedFileURL strips /private from existing /private/var
            // paths but leaves it on non-existent child URLs; include both forms when simulating
            // non-macOS platforms on a macOS host.
            for key in results {
                if key.hasPrefix("/var/") {
                    results.append("/private" + key)
                } else if key.hasPrefix("/private/var/") {
                    results.append(String(key.dropFirst("/private".count)))
                }
            }
            #endif
            return results
        }
        func directories(_ names: [String], under root: URL) -> [URL] {
            names.map { root.appendingPathComponent($0, isDirectory: true) }
        }
        func environmentURLs(_ names: [String]) -> [URL] {
            names.compactMap { name in
                guard let path = platform.environmentVariable(name), PlatformPath.isAbsolute(path) else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        var sensitive: [URL] = []
        var exact: [URL] = []
        var containerRoots: [URL] = []
        switch kind {
        case .macos:
            break
        case .windows:
            sensitive = directories(Self.windowsUserFolders, under: home)
            sensitive += platform.protectedUserDirectories
            sensitive += environmentURLs([
                "SystemRoot", "ProgramData", "ProgramFiles", "ProgramFiles(x86)",
                "ProgramW6432", "OneDrive", "OneDriveConsumer", "OneDriveCommercial", "GNUPGHOME"
            ])
            sensitive.append(platform.userDataDirectory())
            exact.append(home.appendingPathComponent("AppData", isDirectory: true))
            exact.append(home.appendingPathComponent("AppData/LocalLow", isDirectory: true))
            sensitive.append(home.appendingPathComponent("AppData/LocalLow/Microsoft", isDirectory: true))
            if let roaming = platform.resolve(.appData) {
                exact.append(roaming)
                exact += directories(Self.windowsRoamingClientRoots, under: roaming)
                containerRoots += directories(Self.windowsRoamingContainerRoots, under: roaming)
                sensitive += directories(Self.windowsAppDataSubtrees + Self.windowsRoamingSensitiveSubtrees, under: roaming)
            }
            if let local = platform.resolve(.localAppData) {
                exact.append(local)
                exact += directories(Self.windowsLocalClientRoots, under: local)
                containerRoots += directories(Self.windowsLocalContainerRoots, under: local)
                sensitive += directories(Self.windowsAppDataSubtrees + Self.windowsLocalSensitiveSubtrees, under: local)
            }
        case .linux:
            sensitive = directories(Self.linuxHomeSubtrees, under: home)
            sensitive += environmentURLs(["GNUPGHOME"])
            sensitive.append(platform.userDataDirectory())
            exact += directories(Self.linuxHomeExactRoots, under: home)
            containerRoots += directories(Self.linuxHomeContainerRoots, under: home)
            if let config = platform.resolve(.xdgConfig) {
                exact.append(config)
                exact += directories(Self.linuxConfigClientRoots, under: config)
                containerRoots += directories(Self.linuxConfigContainerRoots, under: config)
                sensitive += directories(Self.linuxBrowserProfiles + Self.linuxConfigSensitiveSubtrees, under: config)
            }
            if let data = platform.resolve(.xdgData) {
                exact.append(data)
                exact += directories(Self.linuxDataClientRoots, under: data)
                containerRoots += directories(Self.linuxDataContainerRoots, under: data)
                sensitive += directories(Self.linuxDataSensitiveSubtrees, under: data)
            }
            if let cache = platform.resolve(.xdgCache) {
                exact.append(cache)
            }
            sensitive += directories(Self.linuxFlatpakSensitiveSubtrees, under: home)
        }
        self.kind = kind
        self.homes = Set(keys(home))
        self.protectedSubtrees = Array(Set(sensitive.flatMap(keys)))
        self.alwaysBlockedExactRoots = Set(exact.flatMap(keys))
        self.containerOnlyExactRoots = Set(containerRoots.flatMap(keys))
    }

    func violation(for path: String, allowContainerRoots: Bool = false) -> String? {
        if kind == .macos { return nil }
        let key = kind == .windows ? path.lowercased() : path
        if alwaysBlockedExactRoots.contains(key) || protectedSubtrees.contains(where: { isWithin(key, root: $0) }) {
            return "系统、同步目录或用户数据受保护：\(path)"
        }
        if !allowContainerRoots && containerOnlyExactRoots.contains(key) {
            return "不能直接清理整个目录，请仅清理其中的具体日志或会话条目：\(path)"
        }
        switch kind {
        case .windows: return windowsViolation(key)
        case .linux: return linuxViolation(key)
        case .macos: return nil
        }
    }

    private func windowsViolation(_ key: String) -> String? {
        if key.hasPrefix("//") { return "网络共享和设备路径不支持安全清理" }
        let hasDrive = PlatformPath.hasWindowsDrivePrefix(key)
        let components = (hasDrive ? key.dropFirst(3) : key[...]).split(separator: "/")
        if components.contains(where: Self.invalidWindowsComponent) { return "无效或保留的 Windows 路径" }
        if let last = components.last, Self.windowsRegistryHives.contains(String(last)) {
            return "Windows 用户注册表配置单元受保护"
        }
        if hasDrive, let first = components.first, Self.windowsVolumeDirectories.contains(String(first)) {
            return "Windows 系统目录受保护"
        }
        if hasDrive, components.first == "users", !isWithinAnyHome(key) {
            return "其他 Windows 用户配置受保护"
        }
        if let relative = relativeToHome(key),
           let first = relative.split(separator: "/").first,
           first == "onedrive" || first.hasPrefix("onedrive - ") {
            return "OneDrive 同步目录受保护"
        }
        return nil
    }

    private func linuxViolation(_ key: String) -> String? {
        if Self.linuxExactSystemRoots.contains(key)
            || Self.linuxSystemRoots.contains(where: { isWithin(key, root: $0) }) {
            return "Linux 系统目录受保护"
        }
        if key.hasPrefix("/home/"), !isWithinAnyHome(key) {
            return "其他 Linux 用户主目录受保护"
        }
        guard let relative = relativeToHome(key) else { return nil }
        let components = relative.split(separator: "/")
        if components.first == "snap" {
            let isRootBoundary = components.count <= 3
                || (components.count == 4 && [".config", ".cache", ".local"].contains(String(components[3])))
                || (components.count == 5 && components[3] == ".local" && components[4] == "share")
            let isProtectedSnap = components.count >= 2 && Self.snapProtectedApps.contains(String(components[1]))
            if isRootBoundary || isProtectedSnap {
                return "Snap 应用数据或浏览器配置受保护"
            }
        }
        if components.prefix(2).elementsEqual([".var", "app"]), components.count >= 3 {
            if components.count <= 4 || Self.flatpakProtectedApps.contains(String(components[2])) {
                return "Flatpak 应用数据或浏览器配置受保护"
            }
        }
        return nil
    }

    private func isWithinAnyHome(_ key: String) -> Bool {
        homes.contains { isWithin(key, root: $0) }
    }

    private func relativeToHome(_ key: String) -> Substring? {
        for home in homes {
            let prefix = home.hasSuffix("/") ? home : home + "/"
            if key.hasPrefix(prefix) {
                return key.dropFirst(prefix.count)
            }
        }
        return nil
    }

    private func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func invalidWindowsComponent(_ component: Substring) -> Bool {
        if component.last == "." || component.last == " " || component.contains(where: { ":*?<>|\"".contains($0) }) {
            return true
        }
        let name = component.prefix { $0 != "." }.trimmingWindowsDeviceSpaces()
        let devices: Set<String> = ["con", "prn", "aux", "nul", "conin$", "conout$"]
        if devices.contains(name) { return true }
        if name.hasPrefix("com") || name.hasPrefix("lpt") {
            let suffix = name.dropFirst(3)
            return suffix.count == 1 && suffix.first.map { "123456789¹²³".contains($0) } == true
        }
        return false
    }

    private static let windowsVolumeDirectories: Set<String> = [
        "windows", "program files", "program files (x86)", "programdata", "recovery", "boot",
        "$recycle.bin", "system volume information", "config.msi", "$winreagent", "perflogs", "msocache"
    ]
    private static let windowsRegistryHives: Set<String> = [
        "ntuser.dat", "ntuser.dat.log1", "ntuser.dat.log2",
        "usrclass.dat", "usrclass.dat.log1", "usrclass.dat.log2"
    ]
    private static let windowsUserFolders = [
        "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos",
        "Contacts", "Favorites", "Saved Games", "Searches", "Links"
    ]
    private static let windowsAppDataSubtrees = [
        "Microsoft", "Packages", "gnupg", "Google/Chrome", "Google/Chrome Beta", "Google/Chrome SxS",
        "Chromium", "Mozilla", "BraveSoftware", "Opera Software", "Vivaldi", "Yandex", "Tor Browser",
        "Arc", "zen", "1Password", "KeePass", "KeePassXC"
    ]
    private static let windowsRoamingClientRoots = [
        "Claude", "Cursor", "Codex", "Windsurf", "WorkBuddy", "WorkDaddy", "Doubao", "jianyin_agent",
        "@deepseek-ai", "@deepseek-ai/dsh-desktop", "Trae", "Trae CN", "Qoder", "Kiro",
        "ZCode", "ZCode/session", "chatglm", "Antigravity", "Multica", "CherryStudio",
        "anythingllm-desktop", "LM Studio", "stepfun-desktop", "t3code-v2", "T3 Code (Beta)",
        "Kimi", "Tencent Yuanbao", "xyz.chatboxapp.app", "xyz.chatboxapp.ce", "Jan", "Jan/data", "Zed"
    ]
    private static let windowsRoamingContainerRoots = [
        "Claude/local-agent-mode-sessions",
        "Claude/claude-code-sessions",
        "Jan/data/threads"
    ]
    private static let windowsRoamingSensitiveSubtrees = [
        "WorkDaddy/accounts", "ai.z.zcode", "anythingllm-desktop/storage", "Zed",
        "Cursor/User", "Windsurf/User", "Trae/User", "Trae CN/User", "Qoder/User", "Kiro/User"
    ]
    private static let windowsLocalClientRoots = [
        "Zed", "AnthropicClaude", "Programs"
    ]
    private static let windowsLocalContainerRoots = [
        "Ollama"
    ]
    private static let windowsLocalSensitiveSubtrees = [
        "Zed/db"
    ]

    private static let linuxHomeSubtrees = [
        ".mozilla", ".pki", ".password-store", ".cert", ".local/state/keyrings"
    ]
    private static let linuxHomeExactRoots = [
        ".local", ".var", ".var/app", "snap",
        ".var/app/com.cherry_ai.CherryStudio/config/CherryStudio",
        ".var/app/ai.jan.Jan/config/Jan",
        ".var/app/ai.jan.Jan/data/Jan",
        ".var/app/ai.jan.Jan/data/Jan/data",
        ".var/app/dev.zed.Zed/data/zed"
    ]
    private static let linuxHomeContainerRoots = [
        ".var/app/ai.jan.Jan/data/Jan/data/threads"
    ]
    private static let linuxBrowserProfiles = [
        "chromium", "google-chrome", "google-chrome-beta", "google-chrome-unstable",
        "microsoft-edge", "microsoft-edge-beta", "BraveSoftware", "mozilla", "firefox",
        "vivaldi", "opera", "opera-beta", "torbrowser", "yandex-browser", "zen", "keepassxc", "1Password"
    ]
    private static let linuxConfigClientRoots = [
        "Claude", "Cursor", "Windsurf", "WorkBuddy", "WorkDaddy", "@deepseek-ai", "@deepseek-ai/dsh-desktop",
        "Kiro", "ZCode", "ZCode/session", "Antigravity", "Multica", "CherryStudio", "anythingllm-desktop",
        "LM Studio", "t3code-v2", "T3 Code (Beta)", "xyz.chatboxapp.app", "xyz.chatboxapp.ce", "Jan"
    ]
    private static let linuxConfigContainerRoots = [
        "Claude/local-agent-mode-sessions",
        "Claude/claude-code-sessions"
    ]
    private static let linuxConfigSensitiveSubtrees = [
        "keyring", "keyrings", "GnuPG", "systemd", "autostart", "dconf", "pulse", "pipewire",
        "WorkDaddy/accounts", "ai.z.zcode", "anythingllm-desktop/storage", "zed",
        "Cursor/User", "Windsurf/User", "Kiro/User"
    ]
    private static let linuxDataClientRoots = [
        "Jan", "Jan/data", "opencode", "zed"
    ]
    private static let linuxDataContainerRoots = [
        "opencode/storage", "opencode/storage/session", "Jan/data/threads"
    ]
    private static let linuxDataSensitiveSubtrees = [
        "keyrings", "Trash", "kwalletd", "gnome-keyring", "flatpak", "applications",
        "gnupg", "systemd", "gvfs-metadata", "zed/db"
    ]
    private static let linuxFlatpakSensitiveSubtrees = [
        ".var/app/dev.zed.Zed/config/zed",
        ".var/app/dev.zed.Zed/data/zed/db"
    ]
    private static let flatpakProtectedApps: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.chromium.Chromium", "com.google.Chrome",
        "com.brave.Browser", "com.microsoft.Edge", "com.opera.Opera", "com.vivaldi.Vivaldi",
        "app.zen_browser.zen", "io.gitlab.librewolf-community",
        "org.keepassxc.KeePassXC", "com.onepassword.OnePassword"
    ]
    private static let snapProtectedApps: Set<String> = [
        "firefox", "chromium", "brave", "opera", "vivaldi", "keepassxc", "1password"
    ]
    private static let linuxExactSystemRoots: Set<String> = [
        "/home", "/mnt", "/media"
    ]
    private static let linuxSystemRoots = [
        "/proc", "/sys", "/run", "/boot", "/lib", "/lib32", "/lib64", "/root", "/snap",
        "/srv", "/lost+found", "/var/lib", "/var/cache", "/var/log", "/var/spool", "/var/run"
    ]
}

private extension Substring {
    func trimmingWindowsDeviceSpaces() -> String {
        String(reversed().drop(while: { $0 == " " }).reversed())
    }
}
