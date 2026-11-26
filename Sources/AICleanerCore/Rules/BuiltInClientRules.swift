/// macOS 内置客户端规则。规则清单由 rules/ 中的 JSON 在构建前生成。
public enum BuiltInClientRules {
    public static let allProfiles: [AIClientProfile] = {
        do {
            return try BuiltInRuleCatalog.load(platform: .macos) { root, relativePath in
                switch root {
                case "home": return relativePath
                case "appSupport": return "Library/Application Support/" + relativePath
                case "caches": return "Library/Caches/" + relativePath
                case "logs": return "Library/Logs/" + relativePath
                default: return nil
                }
            }
        } catch {
            preconditionFailure("Invalid embedded macOS rules: \(error)")
        }
    }()

    /// 按目标平台的 `PlatformAdapter` 解析内置规则包并执行 `SafetyGuard.validateBuiltInContainer` 校验。
    public static func profiles(
        for platform: any PlatformAdapter,
        safetyGuard: SafetyGuard? = nil
    ) -> [AIClientProfile] {
        do {
            let guardToUse = safetyGuard ?? SafetyGuard(platform: platform)
            return try BuiltInRuleCatalog.load(
                platform: BuiltInRuleCatalog.Platform(platform.platform),
                resolving: { root, relativePath in
                    guard let placeholder = PathPlaceholder(rawValue: root),
                          let baseURL = platform.resolve(placeholder) else {
                        return nil
                    }
                    return PlatformPath.normalize(baseURL.appendingPathComponent(relativePath))
                },
                safetyGuard: guardToUse
            )
        } catch {
            CoreLogger.shared.error(
                "内置规则清单解码失败",
                metadata: [
                    "platform": .string(platform.platform.rawValue),
                    "error": .string(String(describing: error))
                ]
            )
            return []
        }
    }

    private static let byID = Dictionary(uniqueKeysWithValues: allProfiles.map { ($0.id, $0) })

    public static let claudeCode = profile(withID: "claude-code")
    public static let codex = profile(withID: "codex")
    public static let workBuddy = profile(withID: "workbuddy")
    public static let doubao = profile(withID: "doubao")
    public static let workDaddy = profile(withID: "workdaddy")
    public static let cursor = profile(withID: "cursor")
    public static let deepseekHarness = profile(withID: "deepseek")
    public static let trae = profile(withID: "trae")
    public static let qoder = profile(withID: "qoder")
    public static let lingma = profile(withID: "lingma")
    public static let kiro = profile(withID: "kiro")
    public static let zcode = profile(withID: "zcode")
    public static let windsurf = profile(withID: "windsurf")
    public static let claudeDesktop = profile(withID: "claude-desktop")
    public static let chatGPTDesktop = profile(withID: "chatgpt-desktop")
    public static let openCode = profile(withID: "opencode")
    public static let piAgent = profile(withID: "pi")
    public static let geminiAntigravity = profile(withID: "gemini-antigravity")
    public static let multica = profile(withID: "multica")
    public static let githubCopilot = profile(withID: "copilot")
    public static let cherryStudio = profile(withID: "cherry-studio")
    public static let anythingLLM = profile(withID: "anythingllm")
    public static let t3Code = profile(withID: "t3-code")
    public static let stepFun = profile(withID: "stepfun")
    public static let kimi = profile(withID: "kimi")
    public static let yuanbao = profile(withID: "yuanbao")
    public static let ollama = profile(withID: "ollama")
    public static let lmStudio = profile(withID: "lm-studio")
    public static let chatbox = profile(withID: "chatbox")
    public static let janAI = profile(withID: "jan")
    public static let zedAI = profile(withID: "zed")

    private static func profile(withID id: String) -> AIClientProfile {
        guard let profile = byID[id] else {
            preconditionFailure("Missing embedded macOS profile: \(id)")
        }
        return profile
    }
}
