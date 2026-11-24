import AICleanerCore
import SwiftUI

enum AppTheme {
    static func color(for recommendation: CleanupRecommendation) -> Color {
        switch recommendation {
        case .recommended:
            return Color(red: 0.13, green: 0.65, blue: 0.36)
        case .reviewSuggested:
            return Color(red: 0.90, green: 0.52, blue: 0.10)
        case .notRecommended:
            return Color(red: 0.78, green: 0.28, blue: 0.28)
        }
    }

    static func color(for category: ScanCategory) -> Color {
        switch category {
        case .sessions:
            return .indigo
        case .cache:
            return .blue
        case .temporary:
            return .orange
        case .logs:
            return .purple
        case .custom:
            return .teal
        case .protectedData:
            return Color(red: 0.78, green: 0.28, blue: 0.28)
        }
    }

    static func color(forAccentToken token: String) -> Color {
        switch token {
        case "claude", "claudeDesktop":
            return Color(red: 0.85, green: 0.45, blue: 0.25)
        case "cursor":
            return .blue
        case "codex", "chatgpt":
            return Color(red: 0.08, green: 0.65, blue: 0.48)
        case "workbuddy":
            return Color(red: 0.12, green: 0.52, blue: 0.96)
        case "doubao":
            return Color(red: 0.24, green: 0.44, blue: 0.98)
        case "workdaddy":
            return Color(red: 0.44, green: 0.38, blue: 0.88)
        case "deepseek":
            return Color(red: 0.26, green: 0.42, blue: 0.92)
        case "trae":
            return Color(red: 0.10, green: 0.72, blue: 0.54)
        case "qoder":
            return Color(red: 0.95, green: 0.48, blue: 0.14)
        case "lingma":
            return Color(red: 0.38, green: 0.34, blue: 0.94)
        case "kiro":
            return Color(red: 0.56, green: 0.32, blue: 0.92)
        case "zcode":
            return Color(red: 0.22, green: 0.56, blue: 0.96)
        case "windsurf":
            return .cyan
        case "opencode":
            return .indigo
        case "pi":
            return Color(red: 0.78, green: 0.34, blue: 0.56)
        case "gemini":
            return Color(red: 0.28, green: 0.52, blue: 0.96)
        case "multica":
            return Color(red: 0.34, green: 0.40, blue: 0.92)
        case "copilot":
            return Color(red: 0.42, green: 0.46, blue: 0.56)
        case "cherry":
            return Color(red: 0.86, green: 0.24, blue: 0.36)
        case "anythingllm":
            return Color(red: 0.16, green: 0.58, blue: 0.74)
        case "t3":
            return Color(red: 0.86, green: 0.56, blue: 0.16)
        case "stepfun":
            return Color(red: 0.16, green: 0.62, blue: 0.88)
        case "kimi":
            return Color(red: 0.22, green: 0.32, blue: 0.78)
        case "yuanbao":
            return Color(red: 0.10, green: 0.66, blue: 0.58)
        case "ollama", "lmstudio":
            return Color(red: 0.46, green: 0.48, blue: 0.54)
        case "chatbox", "jan", "zed":
            return Color(red: 0.30, green: 0.54, blue: 0.86)
        case "custom":
            return .teal
        default:
            return .accentColor
        }
    }
}
