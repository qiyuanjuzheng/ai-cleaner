import AICleanerCore
import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case light = "浅色磨砂"
    case dark = "深色极光"
    case system = "跟随系统"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var next: AppAppearanceMode {
        switch self {
        case .light: return .system
        case .system: return .dark
        case .dark: return .light
        }
    }
}

enum AppTheme {
    // MARK: - Semantic Palette (90% Neutral Canvas + 10% Intentional Accent)

    static func color(for recommendation: CleanupRecommendation) -> Color {
        switch recommendation {
        case .recommended:
            return Color(red: 0.16, green: 0.82, blue: 0.54)
        case .reviewSuggested:
            return Color(red: 0.98, green: 0.66, blue: 0.22)
        case .notRecommended:
            return Color(red: 0.88, green: 0.42, blue: 0.48)
        }
    }

    static func gradient(for recommendation: CleanupRecommendation) -> LinearGradient {
        switch recommendation {
        case .recommended:
            return LinearGradient(
                colors: [Color(red: 0.12, green: 0.86, blue: 0.58), Color(red: 0.10, green: 0.68, blue: 0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .reviewSuggested:
            return LinearGradient(
                colors: [Color(red: 1.00, green: 0.74, blue: 0.26), Color(red: 0.96, green: 0.48, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .notRecommended:
            return LinearGradient(
                colors: [Color(red: 0.86, green: 0.40, blue: 0.48), Color(red: 0.64, green: 0.30, blue: 0.44)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Category Palette

    static func color(for category: ScanCategory) -> Color {
        switch category {
        case .sessions:
            return Color(red: 0.52, green: 0.50, blue: 0.98)
        case .cache:
            return Color(red: 0.26, green: 0.68, blue: 1.00)
        case .temporary:
            return Color(red: 0.98, green: 0.64, blue: 0.24)
        case .logs:
            return Color(red: 0.74, green: 0.50, blue: 0.96)
        case .custom:
            return Color(red: 0.18, green: 0.78, blue: 0.74)
        case .protectedData:
            return Color(red: 0.84, green: 0.44, blue: 0.50)
        }
    }

    // MARK: - Client Accent Palette

    static func color(forAccentToken token: String) -> Color {
        switch token {
        case "claude", "claudeDesktop":
            return Color(red: 0.94, green: 0.54, blue: 0.34)
        case "cursor":
            return Color(red: 0.30, green: 0.64, blue: 1.00)
        case "codex", "chatgpt":
            return Color(red: 0.14, green: 0.82, blue: 0.60)
        case "workbuddy":
            return Color(red: 0.24, green: 0.62, blue: 1.00)
        case "doubao":
            return Color(red: 0.38, green: 0.56, blue: 1.00)
        case "workdaddy":
            return Color(red: 0.58, green: 0.48, blue: 0.98)
        case "deepseek":
            return Color(red: 0.36, green: 0.54, blue: 0.98)
        case "trae":
            return Color(red: 0.14, green: 0.82, blue: 0.64)
        case "qoder":
            return Color(red: 0.98, green: 0.56, blue: 0.24)
        case "lingma":
            return Color(red: 0.50, green: 0.46, blue: 1.00)
        case "kiro":
            return Color(red: 0.66, green: 0.44, blue: 0.98)
        case "zcode":
            return Color(red: 0.30, green: 0.66, blue: 1.00)
        case "windsurf":
            return Color(red: 0.16, green: 0.82, blue: 0.88)
        case "opencode":
            return Color(red: 0.48, green: 0.52, blue: 0.98)
        case "pi":
            return Color(red: 0.92, green: 0.44, blue: 0.68)
        case "gemini":
            return Color(red: 0.36, green: 0.62, blue: 1.00)
        case "multica":
            return Color(red: 0.46, green: 0.52, blue: 1.00)
        case "copilot":
            return Color(red: 0.60, green: 0.66, blue: 0.78)
        case "cherry":
            return Color(red: 0.94, green: 0.36, blue: 0.50)
        case "anythingllm":
            return Color(red: 0.20, green: 0.74, blue: 0.86)
        case "t3":
            return Color(red: 0.98, green: 0.68, blue: 0.26)
        case "stepfun":
            return Color(red: 0.24, green: 0.74, blue: 1.00)
        case "kimi":
            return Color(red: 0.34, green: 0.66, blue: 1.00)
        case "yuanbao":
            return Color(red: 0.14, green: 0.82, blue: 0.66)
        case "ollama":
            return Color(red: 0.76, green: 0.78, blue: 0.84)
        case "lmstudio":
            return Color(red: 0.60, green: 0.46, blue: 0.98)
        case "chatbox":
            return Color(red: 0.26, green: 0.68, blue: 0.98)
        case "jan":
            return Color(red: 0.96, green: 0.42, blue: 0.60)
        case "zed":
            return Color(red: 0.34, green: 0.74, blue: 0.98)
        default:
            return Color(red: 0.16, green: 0.80, blue: 0.62)
        }
    }

    // MARK: - Calm Glass Surface Tokens

    static func canvasBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.062, blue: 0.085)
            : Color(red: 0.952, green: 0.960, blue: 0.976)
    }

    static func glassCardFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.042)
            : Color.white.opacity(0.88)
    }

    static func glassElevatedFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.095, green: 0.108, blue: 0.145).opacity(0.92)
            : Color.white.opacity(0.96)
    }

    static func hairlineDivider(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.065)
            : Color.black.opacity(0.065)
    }

    static func specularRimGradient(for colorScheme: ColorScheme, accent: Color? = nil) -> LinearGradient {
        if let accent {
            return LinearGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.60 : 0.50),
                    accent.opacity(colorScheme == .dark ? 0.18 : 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.14), Color.white.opacity(0.03)]
                : [Color.black.opacity(0.06), Color.black.opacity(0.09)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0.12, green: 0.84, blue: 0.60),
            Color(red: 0.22, green: 0.62, blue: 1.00),
            Color(red: 0.54, green: 0.44, blue: 0.98)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let dangerGradient = LinearGradient(
        colors: [
            Color(red: 0.96, green: 0.34, blue: 0.40),
            Color(red: 0.84, green: 0.18, blue: 0.32)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Tactile Interactive Button Styles

struct TactileScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.74),
                value: configuration.isPressed
            )
    }
}

/// 带细腻斜扫流光的主行动胶囊按钮
struct GlowingPillButtonStyle: ButtonStyle {
    let gradient: LinearGradient
    let glowColor: Color
    var isEnabled: Bool = true
    var compact: Bool = false

    @State private var isHovered: Bool = false
    @State private var sheenProgress: CGFloat = -1.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(compact ? .caption : .callout, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 13 : 16)
            .padding(.vertical, compact ? 7 : 8.5)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(gradient)
                        .opacity(isEnabled ? 1.0 : 0.35)

                    if isHovered && isEnabled {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.20), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    if !reduceMotion && isEnabled {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(32, proxy.size.width * 0.38), height: proxy.size.height * 1.6)
                            .rotationEffect(.degrees(18))
                            .offset(
                                x: sheenProgress * (proxy.size.width + 60),
                                y: -proxy.size.height * 0.3
                            )
                        }
                        .clipped()
                        .clipShape(Capsule(style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(isEnabled ? 0.42 : 0.10), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(
                color: isEnabled ? glowColor.opacity(isHovered ? 0.45 : 0.24) : .clear,
                radius: isHovered ? 12 : 7,
                y: isHovered ? 3 : 2
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : (isHovered && !reduceMotion && isEnabled ? 1.018 : 1.0))
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.74),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: isHovered
            )
            .onHover { hovering in
                isHovered = hovering
                guard !reduceMotion && isEnabled else { return }
                if hovering {
                    sheenProgress = -1.2
                    withAnimation(.easeInOut(duration: 0.58)) {
                        sheenProgress = 1.4
                    }
                } else {
                    sheenProgress = -1.2
                }
            }
    }
}
