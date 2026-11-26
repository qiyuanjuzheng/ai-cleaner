import Foundation
import XCTest
@testable import AICleanerCore

final class PortableRulePackTests: XCTestCase {
    func testWindowsRulePackIntegrityAndSafetyCompliance() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let home = try XCTUnwrap(HostPlatformAdapter.canonicalURL(at: fixture.homeURL))
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .windows,
            homeDirectory: home
        )
        let safetyGuard = SafetyGuard(platform: platform)
        let profiles = BuiltInClientRules.profiles(for: platform, safetyGuard: safetyGuard)

        // 30 of 31 macOS clients apply to Windows (chatgpt-desktop is MSIX-only under locked Packages).
        XCTAssertEqual(profiles.count, 30)
        XCTAssertFalse(profiles.contains { $0.id == "chatgpt-desktop" })

        var seenRuleIDs: Set<String> = []
        var rulesByID: [String: ScanRule] = [:]
        var protectedRuleIDs: Set<String> = []

        for profile in profiles {
            XCTAssertFalse(profile.name.isEmpty)
            XCTAssertFalse(profile.description.isEmpty)
            XCTAssertFalse(profile.protectedSummary.isEmpty)
            XCTAssertFalse(profile.rules.isEmpty, "Windows profile \(profile.id) should have rules")

            for rule in profile.rules {
                XCTAssertTrue(seenRuleIDs.insert(rule.id).inserted, "Duplicate Windows rule ID: \(rule.id)")
                rulesByID[rule.id] = rule
                XCTAssertFalse(rule.explanation.isEmpty)

                if rule.recommendation == .notRecommended {
                    XCTAssertEqual(rule.category, .protectedData, "Only protectedData may be notRecommended: \(rule.id)")
                    protectedRuleIDs.insert(rule.id)
                    continue
                }

                let resolvedURL = rule.resolveURL(homeDirectory: safetyGuard.homeDirectory)
                switch rule.mode {
                case .directory:
                    let decision = safetyGuard.validateTarget(resolvedURL)
                    XCTAssertTrue(
                        decision.isAllowed,
                        "Windows directory rule [\(rule.id)] conflicts with SafetyGuard: \(resolvedURL.path) -> \(decision.blockReason ?? "")"
                    )
                case .children, .projectSessions, .recursiveFiles:
                    let decision = safetyGuard.validateBuiltInContainer(resolvedURL)
                    XCTAssertTrue(
                        decision.isAllowed,
                        "Windows container rule [\(rule.id)] conflicts with SafetyGuard: \(resolvedURL.path) -> \(decision.blockReason ?? "")"
                    )
                }
            }
        }

        // Protected rules must remain visible (not dropped by BuiltInRuleCatalog).
        for expectedProtected in [
            "ollama-protected-models",
            "claude-desktop-protected-storage",
            "anythingllm-protected-storage",
            "zed-protected-db",
            "opencode-protected-db"
        ] {
            XCTAssertTrue(protectedRuleIDs.contains(expectedProtected), "Missing protected rule: \(expectedProtected)")
        }

        // Verification safety gate: source-verified caches/logs may be .recommended; docs-verified rules stay .reviewSuggested.
        XCTAssertEqual(rulesByID["ollama-windows-logs"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["zed-logs"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["cherry-cache"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["cursor-cache"]?.recommendation, .reviewSuggested)
        XCTAssertEqual(rulesByID["claude-desktop-cache"]?.recommendation, .reviewSuggested)
        XCTAssertEqual(rulesByID["doubao-app-cache"]?.recommendation, .reviewSuggested)
    }

    func testLinuxRulePackIntegrityAndSafetyCompliance() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL
        )
        let safetyGuard = SafetyGuard(platform: platform)
        let profiles = BuiltInClientRules.profiles(for: platform, safetyGuard: safetyGuard)

        // 24 of 31 macOS clients apply to Linux (7 domestic/MSIX Windows/macOS-only clients excluded).
        XCTAssertEqual(profiles.count, 24)

        var seenRuleIDs: Set<String> = []
        var rulesByID: [String: ScanRule] = [:]
        var protectedRuleIDs: Set<String> = []

        for profile in profiles {
            XCTAssertFalse(profile.name.isEmpty)
            XCTAssertFalse(profile.rules.isEmpty, "Linux profile \(profile.id) should have rules")

            for rule in profile.rules {
                XCTAssertTrue(seenRuleIDs.insert(rule.id).inserted, "Duplicate Linux rule ID: \(rule.id)")
                rulesByID[rule.id] = rule
                XCTAssertFalse(rule.explanation.isEmpty)

                if rule.recommendation == .notRecommended {
                    XCTAssertEqual(rule.category, .protectedData, "Only protectedData may be notRecommended: \(rule.id)")
                    protectedRuleIDs.insert(rule.id)
                    continue
                }

                let resolvedURL = rule.resolveURL(homeDirectory: safetyGuard.homeDirectory)
                switch rule.mode {
                case .directory:
                    let decision = safetyGuard.validateTarget(resolvedURL)
                    XCTAssertTrue(
                        decision.isAllowed,
                        "Linux directory rule [\(rule.id)] conflicts with SafetyGuard: \(resolvedURL.path) -> \(decision.blockReason ?? "")"
                    )
                case .children, .projectSessions, .recursiveFiles:
                    let decision = safetyGuard.validateBuiltInContainer(resolvedURL)
                    XCTAssertTrue(
                        decision.isAllowed,
                        "Linux container rule [\(rule.id)] conflicts with SafetyGuard: \(resolvedURL.path) -> \(decision.blockReason ?? "")"
                    )
                }
            }
        }

        for expectedProtected in [
            "opencode-protected-db",
            "zed-protected-config",
            "zed-flatpak-protected-config",
            "cherry-flatpak-protected-indexeddb",
            "jan-flatpak-protected-models"
        ] {
            XCTAssertTrue(protectedRuleIDs.contains(expectedProtected), "Missing protected rule: \(expectedProtected)")
        }

        // Verification safety gate: ci/source rules may be .recommended; docs/community stay .reviewSuggested.
        XCTAssertEqual(rulesByID["opencode-logs"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["zed-logs"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["zed-flatpak-cache"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["cherry-flatpak-cache"]?.recommendation, .recommended)
        XCTAssertEqual(rulesByID["zed-snap-cache"]?.recommendation, .reviewSuggested)
        XCTAssertEqual(rulesByID["ollama-snap-logs"]?.recommendation, .reviewSuggested)
        XCTAssertEqual(rulesByID["claude-desktop-cache"]?.recommendation, .reviewSuggested)
        XCTAssertEqual(rulesByID["cursor-cache"]?.recommendation, .reviewSuggested)
    }

    func testWindowsRulePackScansOllamaLogsAndRespectsProtectedData() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        _ = try fixture.createFile(relativeToHome: "AppData/Local/Ollama/server.log", byteCount: 19)
        _ = try fixture.createFile(relativeToHome: "AppData/Local/Ollama/server-1.log", byteCount: 11)
        let adjacent = try fixture.createFile(relativeToHome: "AppData/Local/Ollama/account.json", byteCount: 27)
        _ = try fixture.createFile(relativeToHome: ".ollama/models/blobs/sha256-model", byteCount: 512)
        _ = try fixture.createFile(relativeToHome: ".ollama/id_ed25519", byteCount: 128)
        _ = try fixture.createFile(relativeToHome: "AppData/Roaming/Cursor/Cache/entry.bin", byteCount: 40)
        _ = try fixture.createFile(relativeToHome: "AppData/Roaming/Cursor/Cookies", byteCount: 64)
        let home = try XCTUnwrap(HostPlatformAdapter.canonicalURL(at: fixture.homeURL))
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .windows,
            homeDirectory: home
        )
        let report = ScanEngine(builtInProfiles: nil, systemTempRoot: nil, platform: platform).scan()

        XCTAssertEqual(report.detectedBuiltInClientsCount, 2)
        let ollama = try XCTUnwrap(report.clientSummaries.first { $0.id == "ollama" })
        XCTAssertEqual(Set(ollama.items.map(\.fileName)), ["server.log", "server-1.log"])
        XCTAssertEqual(ollama.items.map(\.sizeBytes).reduce(0, +), 30)
        let ollamaProtected = Dictionary(uniqueKeysWithValues: ollama.protectedItems.map { ($0.ruleID, $0) })
        XCTAssertNotNil(ollamaProtected["ollama-protected-models"])
        XCTAssertNil(ollamaProtected["ollama-protected-models"]?.hardProtectionReason)
        XCTAssertNotNil(ollamaProtected["ollama-protected-key"]?.hardProtectionReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: adjacent.path))

        let cursor = try XCTUnwrap(report.clientSummaries.first { $0.id == "cursor" })
        XCTAssertEqual(cursor.items.map(\.ruleID), ["cursor-cache"])
        XCTAssertEqual(cursor.items.first?.recommendation, .reviewSuggested)
        XCTAssertEqual(cursor.protectedItems.map(\.ruleID), ["cursor-protected-cookies"])
        XCTAssertNotNil(cursor.protectedItems.first?.hardProtectionReason)
    }

    func testLinuxRulePackHonorsXDGAndFindsNativeFlatpakAndSnapEntries() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let xdg = try fixture.createDirectory(relativeToHome: "redirected-data")
        _ = try fixture.createFile(relativeToHome: "redirected-data/opencode/log/active.log", byteCount: 21)
        _ = try fixture.createFile(relativeToHome: "redirected-data/opencode/log/diagnostic.heapsnapshot", byteCount: 120)
        _ = try fixture.createFile(relativeToHome: "redirected-data/opencode/opencode.db", byteCount: 140)
        _ = try fixture.createFile(relativeToHome: "redirected-data/zed/logs/Zed.log", byteCount: 12)
        _ = try fixture.createFile(relativeToHome: ".var/app/dev.zed.Zed/data/zed/logs/Zed.log", byteCount: 14)
        _ = try fixture.createFile(relativeToHome: "snap/zed/current/.local/share/zed/logs/Zed.log", byteCount: 16)
        _ = try fixture.createFile(relativeToHome: ".var/app/com.cherry_ai.CherryStudio/config/CherryStudio/Cache/chunk", byteCount: 24)
        _ = try fixture.createFile(relativeToHome: ".var/app/com.cherry_ai.CherryStudio/config/CherryStudio/IndexedDB/data.ldb", byteCount: 88)

        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL,
            environmentOverrides: ["XDG_DATA_HOME": xdg.path]
        )
        let report = ScanEngine(systemTempRoot: nil, platform: platform).scan()

        XCTAssertEqual(report.detectedBuiltInClientsCount, 3)
        let opencode = try XCTUnwrap(report.clientSummaries.first { $0.id == "opencode" })
        XCTAssertEqual(opencode.items.map(\.fileName), ["active.log"])
        XCTAssertEqual(opencode.protectedItems.map(\.ruleID), ["opencode-protected-db"])
        XCTAssertNotNil(opencode.protectedItems.first?.hardProtectionReason)

        let zed = try XCTUnwrap(report.clientSummaries.first { $0.id == "zed" })
        XCTAssertEqual(zed.items.map(\.sizeBytes).sorted(), [12, 14, 16])

        let cherry = try XCTUnwrap(report.clientSummaries.first { $0.id == "cherry-studio" })
        XCTAssertEqual(cherry.items.map(\.ruleID), ["cherry-flatpak-cache"])
        XCTAssertEqual(cherry.items.first?.recommendation, .recommended)
        XCTAssertEqual(cherry.protectedItems.map(\.ruleID), ["cherry-flatpak-protected-indexeddb"])
        XCTAssertNotNil(cherry.protectedItems.first?.hardProtectionReason)
    }
}
