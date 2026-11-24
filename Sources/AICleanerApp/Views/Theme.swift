import AICleanerCore
import SwiftUI

enum AppTheme {
    static func color(for category: ScanCategory) -> Color {
        switch category {
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
        case "custom":
            return .teal
        default:
            return .accentColor
        }
    }
}
