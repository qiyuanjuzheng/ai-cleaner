import AICleanerCore
import SwiftUI

enum AppTheme {
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
        case "windsurf":
            return .cyan
        case "opencode":
            return .indigo
        case "pi":
            return Color(red: 0.78, green: 0.34, blue: 0.56)
        case "gemini":
            return Color(red: 0.28, green: 0.52, blue: 0.96)
        case "custom":
            return .teal
        default:
            return .accentColor
        }
    }
}
