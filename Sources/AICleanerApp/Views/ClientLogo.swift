import AppKit
import SwiftUI

@MainActor
final class ClientLogoResolver {
    private struct DesktopApp {
        let bundleID: String
        var executable: String? = nil
        var bundleName: String? = nil

        func matches(_ bundle: Bundle) -> Bool {
            guard bundle.bundleIdentifier == bundleID,
                  let info = bundle.infoDictionary,
                  info["CFBundlePackageType"] as? String == "APPL" else { return false }
            return (executable == nil || info["CFBundleExecutable"] as? String == executable)
                && (bundleName == nil || info["CFBundleName"] as? String == bundleName)
        }
    }

    private struct Source {
        var apps: [DesktopApp] = []
        var bundledMark: String? = nil
    }

    /// 内置客户端 ID 与真实图标来源映射：
    /// 1. 桌面端优先按已验证 bundle ID / 应用包身份读取本机 `.app` 真实图标。
    /// 2. 仅对 CLI、未安装桌面端或同产品别名的场景，使用来源与授权条款核验过的本地随包资源（见 `Resources/ClientLogos/SOURCES.md`）。
    /// 3. 混合多产品条目（`gemini-antigravity`、`zcode`、`doubao`）、无独立可核验来源条目（`claude-code`、`lingma`、`stepfun`）保持缺省，显示层仅呈现名称。
    private static let sources: [String: Source] = [
        "codex": Source(apps: [.init(bundleID: "com.openai.codex", executable: "Codex")]),
        "workbuddy": Source(apps: [
            .init(bundleID: "com.tencent.workbuddy.mac"),
            .init(bundleID: "com.workbuddy.workbuddy-ai")
        ]),
        "workdaddy": Source(apps: [.init(bundleID: "com.workdaddy.launcher")]),
        "cursor": Source(
            apps: [.init(bundleID: "com.todesktop.230313mzl4w4u92")],
            bundledMark: "cursor"
        ),
        "deepseek": Source(apps: [.init(bundleID: "com.deepseek.dsh")]),
        "trae": Source(apps: [
            .init(bundleID: "com.trae.app"),
            .init(bundleID: "cn.trae.app")
        ]),
        "qoder": Source(apps: [.init(bundleID: "com.qoder.app")]),
        "kiro": Source(apps: [.init(bundleID: "dev.kiro.desktop")]),
        "windsurf": Source(apps: [.init(bundleID: "com.exafunction.windsurf", bundleName: "Windsurf")]),
        "claude-desktop": Source(apps: [.init(bundleID: "com.anthropic.claudefordesktop")]),
        "chatgpt-desktop": Source(apps: [
            .init(bundleID: "com.openai.codex", executable: "ChatGPT"),
            .init(bundleID: "com.openai.chat")
        ]),
        "opencode": Source(
            apps: [.init(bundleID: "ai.opencode.desktop")],
            bundledMark: "opencode"
        ),
        "pi": Source(bundledMark: "pi"),
        "multica": Source(apps: [.init(bundleID: "ai.multica.desktop")]),
        "copilot": Source(apps: [.init(bundleID: "com.github.githubapp")]),
        "cherry-studio": Source(apps: [.init(bundleID: "com.kangfenmao.CherryStudio")]),
        "anythingllm": Source(apps: [.init(bundleID: "com.anythingllm")]),
        "t3-code": Source(apps: [.init(bundleID: "com.t3tools.t3code")]),
        "kimi": Source(apps: [.init(bundleID: "com.moonshot.kimichat")]),
        "yuanbao": Source(apps: [.init(bundleID: "com.tencent.yuanbao")]),
        "ollama": Source(apps: [.init(bundleID: "com.electron.ollama")]),
        "lm-studio": Source(apps: [.init(bundleID: "ai.elementlabs.lmstudio")]),
        "chatbox": Source(apps: [.init(bundleID: "xyz.chatboxapp.app")]),
        "jan": Source(apps: [.init(bundleID: "jan.ai.app")]),
        "zed": Source(
            apps: [
                .init(bundleID: "dev.zed.Zed"),
                .init(bundleID: "dev.zed.Zed-Preview"),
                .init(bundleID: "dev.zed.Zed-Nightly")
            ],
            bundledMark: "zed"
        )
    ]

    static var configuredClientIDs: Set<String> {
        Set(sources.keys)
    }

    static var bundledMarkNames: Set<String> {
        Set(sources.values.compactMap(\.bundledMark))
    }

    static let shared = ClientLogoResolver()

    private static let resourceBundle: Bundle = {
        if let appBundle = Bundle.main.url(forResource: "AICleaner_AICleanerApp", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) {
            return appBundle
        }
        return .module
    }()

    private let applicationURLs: (String) -> [URL]
    private var appImages: [String: NSImage?] = [:]
    private var bundledImages: [String: NSImage] = [:]

    init(applicationURLs: @escaping (String) -> [URL] = {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0)
    }) {
        self.applicationURLs = applicationURLs
    }

    func image(for clientID: String, colorScheme: ColorScheme) -> NSImage? {
        guard let source = Self.sources[clientID] else { return nil }
        if !source.apps.isEmpty, let icon = desktopImage(for: clientID, apps: source.apps) {
            return icon
        }
        guard let mark = source.bundledMark else { return nil }
        return bundledImage(named: mark, colorScheme: colorScheme)
    }

    func bundledImage(named mark: String, colorScheme: ColorScheme) -> NSImage? {
        let fileName = mark + (colorScheme == .dark ? "-dark" : "-light")
        if let cached = bundledImages[fileName] { return cached }
        guard let image = Self.resourceBundle.url(forResource: fileName, withExtension: "png", subdirectory: "ClientLogos")
            .flatMap(NSImage.init(contentsOf:)),
            image.isValid else {
            return nil
        }
        bundledImages[fileName] = image
        return image
    }

    private func desktopImage(for clientID: String, apps: [DesktopApp]) -> NSImage? {
        if let cached = appImages[clientID] { return cached }
        for app in apps {
            let candidates = prioritizedApplicationURLs(for: app.bundleID)
            for url in candidates {
                guard url.pathExtension.lowercased() == "app",
                      let bundle = Bundle(url: url),
                      app.matches(bundle),
                      let icon = appIcon(in: bundle) else { continue }
                appImages[clientID] = icon
                return icon
            }
        }

        appImages.updateValue(nil, forKey: clientID)
        return nil
    }

    private func prioritizedApplicationURLs(for bundleID: String) -> [URL] {
        let homeAppsPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return applicationURLs(bundleID)
            .filter { !$0.pathComponents.contains(".Trash") }
            .sorted { lhs, rhs in
                let lhsRank = applicationLocationRank(path: lhs.path, homeAppsPrefix: homeAppsPrefix)
                let rhsRank = applicationLocationRank(path: rhs.path, homeAppsPrefix: homeAppsPrefix)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.path < rhs.path
            }
    }

    private func applicationLocationRank(path: String, homeAppsPrefix: String) -> Int {
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix(homeAppsPrefix + "/") { return 1 }
        return 2
    }

    private func appIcon(in bundle: Bundle) -> NSImage? {
        if let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, !file.isEmpty {
            let extensionName = (file as NSString).pathExtension
            let name = extensionName.isEmpty ? file : (file as NSString).deletingPathExtension
            if let url = bundle.url(forResource: name, withExtension: extensionName.isEmpty ? "icns" : extensionName),
               let image = NSImage(contentsOf: url), image.isValid {
                return image
            }
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, !name.isEmpty,
           let image = bundle.image(forResource: NSImage.Name(name)), image.isValid {
            return image
        }
        return nil
    }
}

struct ClientLogo: View {
    let clientID: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let image = ClientLogoResolver.shared.image(for: clientID, colorScheme: colorScheme) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
