import AppKit
import SwiftUI

@MainActor
final class ClientLogoResolver {
    enum BundledMark: Hashable {
        case themed(String)
        case single(String)

        func fileName(for colorScheme: ColorScheme) -> String {
            switch self {
            case let .themed(base):
                return base + (colorScheme == .dark ? "-dark" : "-light")
            case let .single(base):
                return base
            }
        }
    }

    private struct DesktopApp {
        let bundleID: String
        var executable: String? = nil
        var bundleName: String? = nil
        /// 当同一厂商整合包内置了独立产品图标资源（例如统一版 `ChatGPT.app` 内置 `icon-codex-*.png`）时，仅读取该专用资源。
        var lightResourceName: String? = nil
        var darkResourceName: String? = nil

        func matches(_ bundle: Bundle) -> Bool {
            guard bundle.bundleIdentifier == bundleID,
                  let info = bundle.infoDictionary,
                  info["CFBundlePackageType"] as? String == "APPL" else { return false }
            return (executable == nil || info["CFBundleExecutable"] as? String == executable)
                && (bundleName == nil || info["CFBundleName"] as? String == bundleName)
        }

        func icon(in bundle: Bundle, colorScheme: ColorScheme) -> NSImage? {
            if lightResourceName != nil || darkResourceName != nil {
                let preferred = colorScheme == .dark
                    ? (darkResourceName ?? lightResourceName)
                    : (lightResourceName ?? darkResourceName)
                guard let resource = preferred else { return nil }
                return Self.loadResourceImage(named: resource, in: bundle)
            }
            return Self.loadMainAppIcon(in: bundle)
        }

        private static func loadResourceImage(named file: String, in bundle: Bundle) -> NSImage? {
            let extensionName = (file as NSString).pathExtension
            let name = extensionName.isEmpty ? file : (file as NSString).deletingPathExtension
            guard let url = bundle.url(
                forResource: name,
                withExtension: extensionName.isEmpty ? nil : extensionName
            ),
            let image = NSImage(contentsOf: url), image.isValid else {
                return nil
            }
            return image
        }

        private static func loadMainAppIcon(in bundle: Bundle) -> NSImage? {
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

    private struct Source {
        var apps: [DesktopApp] = []
        var bundledMark: BundledMark? = nil
    }

    /// 内置客户端 ID 与真实图标来源映射：
    /// 1. 桌面端优先按已验证 bundle ID / 应用包身份读取本机 `.app` 真实图标（不猜名字，不跨产品误配）。
    /// 2. 对 CLI 客户端、IDE 扩展或未安装桌面端的场景，使用核验过的本地官方品牌资源（来源记录于 `Resources/ClientLogos/SOURCES.md`）。
    /// 3. 无公开可核验品牌资源且本机未安装对应应用的条目（如未安装时的 `workdaddy` 或未知客户端）保持缺省，仅显示客户端名称。
    private static let sources: [String: Source] = [
        "claude-code": Source(bundledMark: .single("claude-code")),
        "codex": Source(
            apps: [
                .init(bundleID: "com.openai.codex", executable: "Codex"),
                .init(
                    bundleID: "com.openai.codex",
                    executable: "ChatGPT",
                    lightResourceName: "icon-codex-light.png",
                    darkResourceName: "icon-codex-dark-color.png"
                )
            ],
            bundledMark: .single("codex")
        ),
        "workbuddy": Source(
            apps: [
                .init(bundleID: "com.tencent.workbuddy.mac"),
                .init(bundleID: "com.workbuddy.workbuddy-ai")
            ],
            bundledMark: .single("workbuddy")
        ),
        "doubao": Source(
            apps: [.init(bundleID: "com.bot.pc.doubao")],
            bundledMark: .single("doubao")
        ),
        "workdaddy": Source(apps: [.init(bundleID: "com.workdaddy.launcher")]),
        "cursor": Source(
            apps: [.init(bundleID: "com.todesktop.230313mzl4w4u92")],
            bundledMark: .themed("cursor")
        ),
        "deepseek": Source(
            apps: [.init(bundleID: "com.deepseek.dsh")],
            bundledMark: .single("deepseek")
        ),
        "trae": Source(
            apps: [
                .init(bundleID: "com.trae.app"),
                .init(bundleID: "cn.trae.app")
            ],
            bundledMark: .single("trae")
        ),
        "qoder": Source(
            apps: [
                .init(bundleID: "com.qoder.app"),
                .init(bundleID: "com.qoder.ide")
            ],
            bundledMark: .single("qoder")
        ),
        "lingma": Source(bundledMark: .single("lingma")),
        "kiro": Source(
            apps: [.init(bundleID: "dev.kiro.desktop")],
            bundledMark: .single("kiro")
        ),
        "zcode": Source(
            apps: [
                .init(bundleID: "dev.zcode.app"),
                .init(bundleID: "com.zhipu.chatglm")
            ],
            bundledMark: .single("zcode")
        ),
        "windsurf": Source(
            apps: [.init(bundleID: "com.exafunction.windsurf", bundleName: "Windsurf")],
            bundledMark: .themed("windsurf")
        ),
        "claude-desktop": Source(
            apps: [.init(bundleID: "com.anthropic.claudefordesktop")],
            bundledMark: .single("claude-desktop")
        ),
        "chatgpt-desktop": Source(
            apps: [
                .init(bundleID: "com.openai.codex", executable: "ChatGPT"),
                .init(bundleID: "com.openai.chat")
            ],
            bundledMark: .themed("chatgpt-desktop")
        ),
        "opencode": Source(
            apps: [.init(bundleID: "ai.opencode.desktop")],
            bundledMark: .themed("opencode")
        ),
        "pi": Source(bundledMark: .themed("pi")),
        "gemini-antigravity": Source(
            apps: [.init(bundleID: "com.google.antigravity")],
            bundledMark: .single("gemini-antigravity")
        ),
        "multica": Source(
            apps: [.init(bundleID: "ai.multica.desktop")],
            bundledMark: .themed("multica")
        ),
        "copilot": Source(
            apps: [.init(bundleID: "com.github.githubapp")],
            bundledMark: .themed("copilot")
        ),
        "cherry-studio": Source(
            apps: [.init(bundleID: "com.kangfenmao.CherryStudio")],
            bundledMark: .single("cherry-studio")
        ),
        "anythingllm": Source(
            apps: [.init(bundleID: "com.anythingllm")],
            bundledMark: .single("anythingllm")
        ),
        "t3-code": Source(
            apps: [.init(bundleID: "com.t3tools.t3code")],
            bundledMark: .single("t3-code")
        ),
        "stepfun": Source(bundledMark: .single("stepfun")),
        "kimi": Source(
            apps: [.init(bundleID: "com.moonshot.kimichat")],
            bundledMark: .themed("kimi")
        ),
        "yuanbao": Source(
            apps: [.init(bundleID: "com.tencent.yuanbao")],
            bundledMark: .single("yuanbao")
        ),
        "ollama": Source(
            apps: [.init(bundleID: "com.electron.ollama")],
            bundledMark: .themed("ollama")
        ),
        "lm-studio": Source(
            apps: [.init(bundleID: "ai.elementlabs.lmstudio")],
            bundledMark: .single("lm-studio")
        ),
        "chatbox": Source(
            apps: [.init(bundleID: "xyz.chatboxapp.app")],
            bundledMark: .single("chatbox")
        ),
        "jan": Source(
            apps: [.init(bundleID: "jan.ai.app")],
            bundledMark: .single("jan")
        ),
        "zed": Source(
            apps: [
                .init(bundleID: "dev.zed.Zed"),
                .init(bundleID: "dev.zed.Zed-Preview"),
                .init(bundleID: "dev.zed.Zed-Nightly")
            ],
            bundledMark: .themed("zed")
        )
    ]

    static var configuredClientIDs: Set<String> {
        Set(sources.keys)
    }

    static var configuredBundledMarks: [String: BundledMark] {
        sources.compactMapValues(\.bundledMark)
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
        if !source.apps.isEmpty, let icon = desktopImage(for: clientID, apps: source.apps, colorScheme: colorScheme) {
            return icon
        }
        guard let mark = source.bundledMark else { return nil }
        return bundledImage(for: mark, colorScheme: colorScheme)
    }

    func bundledImage(for mark: BundledMark, colorScheme: ColorScheme) -> NSImage? {
        let fileName = mark.fileName(for: colorScheme)
        if let cached = bundledImages[fileName] { return cached }
        guard let image = Self.resourceBundle.url(forResource: fileName, withExtension: "png", subdirectory: "ClientLogos")
            .flatMap(NSImage.init(contentsOf:)),
            image.isValid else {
            return nil
        }
        bundledImages[fileName] = image
        return image
    }

    private func desktopImage(for clientID: String, apps: [DesktopApp], colorScheme: ColorScheme) -> NSImage? {
        let cacheKey = "\(clientID)::\(colorScheme == .dark ? "dark" : "light")"
        if let cached = appImages[cacheKey] { return cached }
        for app in apps {
            let candidates = prioritizedApplicationURLs(for: app.bundleID)
            for url in candidates {
                guard url.pathExtension.lowercased() == "app",
                      let bundle = Bundle(url: url),
                      app.matches(bundle),
                      let icon = app.icon(in: bundle, colorScheme: colorScheme) else { continue }
                appImages[cacheKey] = icon
                return icon
            }
        }

        appImages.updateValue(nil, forKey: cacheKey)
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
