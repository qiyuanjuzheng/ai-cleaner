import AICleanerCore
#if os(macOS)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum AppearanceMode: String, Codable, Sendable {
    case light, dark, system
}

struct SidecarSettings: Codable, Sendable {
    let appearanceMode: AppearanceMode
}

struct SettingsStore: Sendable {
    private let url: URL
    private let legacyAppearance: @Sendable () -> AppearanceMode?

    init(directory: URL, legacyAppearance: @escaping @Sendable () -> AppearanceMode? = { nil }) {
        self.url = directory.appendingPathComponent("settings.json")
        self.legacyAppearance = legacyAppearance
    }

    func load() throws -> SidecarSettings {
        if let saved = try CoreStorageIO.readJSON(SidecarSettings.self, at: url) { return saved }
        let legacy = legacyAppearance()
        let settings = SidecarSettings(appearanceMode: legacy ?? .light)
        if legacy != nil { try save(settings) }
        return settings
    }

    func setAppearance(_ mode: AppearanceMode) throws -> SidecarSettings {
        _ = try CoreStorageIO.readJSON(SidecarSettings.self, at: url)
        let settings = SidecarSettings(appearanceMode: mode)
        try save(settings)
        return settings
    }

    private func save(_ settings: SidecarSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }

    static func installedAppearance() -> AppearanceMode? {
        #if os(macOS)
        switch UserDefaults(suiteName: "com.qiyuanjuzheng.ai-cleaner")?.string(forKey: "aiCleaner.appearanceMode.v2") {
        case "浅色磨砂": return .light
        case "深色极光": return .dark
        case "跟随系统": return .system
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
