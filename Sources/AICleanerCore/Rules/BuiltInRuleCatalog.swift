import Foundation

/// Decodes only build-time validated data compiled into the Core module.
enum BuiltInRuleCatalog {
    enum Platform {
        case macos, windows, linux

        var payload: String {
            switch self {
            case .macos: EmbeddedBuiltInRules.macos
            case .windows: EmbeddedBuiltInRules.windows
            case .linux: EmbeddedBuiltInRules.linux
            }
        }
    }

    /// The caller supplies the platform's path mapping. macOS uses home-relative paths
    /// so scan engines with an injected home directory resolve against that directory.
    static func load(
        platform: Platform,
        resolving resolvePath: (String, String) -> String?
    ) throws -> [AIClientProfile] {
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(platform.payload.utf8))
        return profiles.compactMap { profile in
            let rules = profile.rules.compactMap { rule -> ScanRule? in
                guard let path = resolvePath(rule.root, rule.relativePath) else { return nil }
                return ScanRule(
                    id: rule.id,
                    displayName: rule.displayName,
                    path: path,
                    category: rule.category,
                    mode: rule.mode,
                    recommendation: rule.recommendation,
                    explanation: rule.explanation,
                    allowedFileSuffixes: rule.allowedFileSuffixes ?? [],
                    isSessionArchive: rule.isSessionArchive
                )
            }
            guard !rules.isEmpty else { return nil }
            return AIClientProfile(
                id: profile.id,
                name: profile.name,
                symbolName: profile.symbolName,
                accentToken: profile.accentToken,
                description: profile.description,
                protectedSummary: profile.protectedSummary,
                rules: rules
            )
        }
    }

    private struct Profile: Decodable {
        let id: String
        let name: String
        let symbolName: String
        let accentToken: String
        let description: String
        let protectedSummary: String
        let rules: [Rule]
    }

    private struct Rule: Decodable {
        let id: String
        let displayName: String
        let root: String
        let relativePath: String
        let category: ScanCategory
        let mode: ScanTargetMode
        let recommendation: CleanupRecommendation?
        let explanation: String
        let allowedFileSuffixes: [String]?
        let isSessionArchive: Bool?
    }
}
