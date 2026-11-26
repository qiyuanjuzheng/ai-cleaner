import Foundation
import XCTest
@testable import AICleanerCore
#if os(Windows)
import CPlatformSupport
#endif

final class PlatformSafetyGuardTests: XCTestCase {
    func testWindowsProtectsBrowserCredentialsAndRedirectedFoldersRegardlessOfCase() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let home = try XCTUnwrap(HostPlatformAdapter.canonicalURL(at: fixture.homeURL))
        let redirected = home.deletingLastPathComponent().appendingPathComponent("Company files", isDirectory: true)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .windows,
            homeDirectory: home,
            environmentOverrides: ["OneDriveCommercial": redirected.path]
        )
        let guardrail = SafetyGuard(platform: platform)
        let protected = [
            home.appendingPathComponent("appdata/roaming/miCroSOFt/desktop.log"),
            home.appendingPathComponent("AppData/Local/Microsoft/Credentials/blob"),
            home.appendingPathComponent("AppData/Local/Packages/OpenAI.ChatGPT-Desktop_123/LocalCache/cache.bin"),
            home.appendingPathComponent("AppData/Local/Google/Chrome/User Data/readme"),
            home.appendingPathComponent("AppData/Roaming/Mozilla/Firefox/readme"),
            home.appendingPathComponent("AppData/Roaming/KeePassXC/config.ini"),
            home.appendingPathComponent("AppData/Roaming/gnupg/pubring.kbx"),
            home.appendingPathComponent("AppData/Roaming/Cursor"),
            home.appendingPathComponent("AppData/Roaming/Cursor/User/snippets/swift.json"),
            home.appendingPathComponent("AppData/Roaming/WorkDaddy/accounts/active.json"),
            home.appendingPathComponent("AppData/Roaming/anythingllm-desktop/storage/vector.bin"),
            home.appendingPathComponent("AppData/Local/Ollama"),
            home.appendingPathComponent("AppData/Local/Zed/db/threads.bin"),
            home.appendingPathComponent(".ollama/id_ed25519"),
            home.appendingPathComponent("OneDrive/notes.txt"),
            home.appendingPathComponent("OneDrive - Contoso/deck.pptx"),
            home.appendingPathComponent("NTUSER.DAT"),
            redirected.appendingPathComponent("Project/report.txt")
        ]
        for item in protected {
            XCTAssertFalse(guardrail.validateTarget(item).isAllowed, item.path)
            XCTAssertFalse(guardrail.validateUserOverrideTarget(item).isAllowed, item.path)
        }

        // Container-only root is allowed for built-in expansion (e.g., scanning .log files inside Ollama),
        // while still blocked as a whole-directory cleanup target above.
        XCTAssertTrue(guardrail.validateBuiltInContainer(home.appendingPathComponent("AppData/Local/Ollama")).isAllowed)

        let allowed = [
            home.appendingPathComponent("AppData/Local/Ollama/app.log"),
            home.appendingPathComponent("AppData/Roaming/Cursor/Cache"),
            home.appendingPathComponent("AppData/Local/Zed/logs/Zed.log")
        ]
        for item in allowed {
            let decision = guardrail.validateTarget(item)
            XCTAssertTrue(decision.isAllowed, "\(item.path) -> \(decision)")
        }
    }

    func testWindowsRejectsReparseAncestorsAndBusyFilesDuringScanAndCleanup() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        _ = try fixture.createFile(relativeToHome: "agent-logs/busy.log", byteCount: 12)
        _ = try fixture.createFile(relativeToHome: "reparse-root/child/payload.log", byteCount: 6)
        let home = try XCTUnwrap(HostPlatformAdapter.canonicalURL(at: fixture.homeURL))
        let busy = home.appendingPathComponent("agent-logs/busy.log")
        let underLink = home.appendingPathComponent("reparse-root/child/payload.log")
        let linkName = "reparse-root"
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .windows,
            homeDirectory: home,
            identityOverride: { url in
                guard url.lastPathComponent == linkName else { return nil }
                return FileIdentity(
                    kind: .reparsePoint(tag: 0xA0000003),
                    owner: nil,
                    volumeID: 1,
                    fileID: 2,
                    size: 0,
                    modifiedAt: Date()
                )
            },
            activeLockOverride: { $0.lastPathComponent == "busy.log" }
        )
        let guardrail = SafetyGuard(platform: platform)
        XCTAssertFalse(guardrail.validateBuiltInContainer(underLink.deletingLastPathComponent()).isAllowed)
        XCTAssertFalse(guardrail.validateUserOverrideTarget(underLink).isAllowed)
        XCTAssertFalse(guardrail.validateTarget(busy).isAllowed)
        XCTAssertFalse(guardrail.validateTargetRecursively(busy.deletingLastPathComponent(), allowUserOverride: true).isAllowed)
        let inspection = DirectorySizer(platform: platform).inspect(url: busy.deletingLastPathComponent(), safetyGuard: guardrail)
        XCTAssertNotNil(inspection?.protectedDescendantReason)
    }

    func testWindowsBlocksDevicePathsOtherUsersAndPreservesLongValidPaths() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .windows,
            homeDirectory: fixture.homeURL
        )
        let policy = PlatformSafetyPolicy(platform: platform, home: fixture.homeURL)
        XCTAssertNotNil(policy.violation(for: "C:/Windows/System32/keep.log"))
        XCTAssertNotNil(policy.violation(for: "C:/ProgramData/Vendor/data.bin"))
        XCTAssertNotNil(policy.violation(for: "C:/Users/OtherUser/AppData/Local/Ollama/server.log"))
        XCTAssertNotNil(policy.violation(for: "C:/Cache/AUX.txt"))
        XCTAssertNotNil(policy.violation(for: "C:/Cache/COM1/out.log"))
        XCTAssertNotNil(policy.violation(for: "C:/Cache/log.txt:stream"))
        XCTAssertNotNil(policy.violation(for: "C:/Cache/folder./output.log"))
        XCTAssertNotNil(policy.violation(for: "//server/share/Cache/output.log"))
        let longDirectory = Array(repeating: String(repeating: "a", count: 60), count: 6).joined(separator: "/")
        XCTAssertNil(policy.violation(for: "C:/Cache/\(longDirectory)/output.log"))
    }

    #if os(Windows)
    func testNativeWindowsLockJunctionAndLongPathHandling() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let file = try fixture.createFile(relativeToHome: "cache/payload.log", byteCount: 12)
        let target = try fixture.createDirectory(relativeToHome: "target")
        _ = try fixture.createFile(relativeToHome: "target/keep.log", byteCount: 3)
        let junction = fixture.homeURL.appendingPathComponent("junction", isDirectory: true)
        XCTAssertTrue(aicl_windows_create_junction(
            PlatformPath.fileSystemPath(for: junction),
            PlatformPath.fileSystemPath(for: target)
        ))
        let guardrail = SafetyGuard(homeDirectory: fixture.homeURL)
        XCTAssertFalse(guardrail.validateBuiltInContainer(junction).isAllowed)
        XCTAssertFalse(guardrail.validateTarget(junction.appendingPathComponent("keep.log")).isAllowed)

        var handle: UnsafeMutableRawPointer?
        XCTAssertEqual(aicl_windows_lock_file_exclusive(PlatformPath.fileSystemPath(for: file), &handle), 0)
        defer { if let handle { aicl_windows_unlock_file(handle) } }
        XCTAssertFalse(guardrail.validateTarget(file).isAllowed)
        XCTAssertFalse(guardrail.validateTargetRecursively(file.deletingLastPathComponent()).isAllowed)
        aicl_windows_unlock_file(try XCTUnwrap(handle))
        handle = nil
        XCTAssertTrue(guardrail.validateTarget(file).isAllowed)

        // Long path (> 260 characters) must be inspectable and allowed through SafetyGuard + HostPlatformAdapter.
        let deep = Array(repeating: String(repeating: "d", count: 48), count: 6).joined(separator: "/")
        let longFile = try fixture.createFile(relativeToHome: "long/\(deep)/deep.log", byteCount: 18)
        XCTAssertGreaterThan(PlatformPath.fileSystemPath(for: longFile).count, 260)
        XCTAssertTrue(guardrail.validateTarget(longFile).isAllowed)
        let identity = try HostPlatformAdapter.shared.identity(at: longFile)
        XCTAssertEqual(identity.kind, .regular)
        XCTAssertEqual(identity.size, 18)
    }
    #endif

    func testLinuxProtectsXDGKeyringsBrowserProfilesAndPackageRoots() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let sandboxData = fixture.rootURL.appendingPathComponent("redirected-data", isDirectory: true)
        let sandboxConfig = fixture.rootURL.appendingPathComponent("redirected-config", isDirectory: true)
        let sandboxGpg = fixture.rootURL.appendingPathComponent("custom-gnupg", isDirectory: true)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL,
            environmentOverrides: [
                "XDG_DATA_HOME": sandboxData.path,
                "XDG_CONFIG_HOME": sandboxConfig.path,
                "GNUPGHOME": sandboxGpg.path
            ]
        )
        let guardrail = SafetyGuard(platform: platform)
        let protected = [
            sandboxData.appendingPathComponent("keyrings/default.keyring"),
            sandboxData.appendingPathComponent("kwalletd/kdewallet.kwl"),
            sandboxData.appendingPathComponent("Trash/files/retained.txt"),
            sandboxData.appendingPathComponent("zed/db/threads.bin"),
            sandboxConfig.appendingPathComponent("chromium/Default/cache"),
            sandboxConfig.appendingPathComponent("google-chrome/Default/Cache"),
            sandboxConfig.appendingPathComponent("zed/settings.json"),
            sandboxConfig.appendingPathComponent("Cursor"),
            sandboxConfig.appendingPathComponent("Cursor/User/snippets/main.json"),
            sandboxConfig.appendingPathComponent("anythingllm-desktop/storage/vectors.bin"),
            sandboxGpg.appendingPathComponent("private-keys-v1.d/key.key"),
            fixture.homeURL.appendingPathComponent(".var/app/org.mozilla.firefox/cache"),
            fixture.homeURL.appendingPathComponent(".var/app/org.keepassxc.KeePassXC/data/db"),
            fixture.homeURL.appendingPathComponent(".var/app/dev.zed.Zed/data"),
            fixture.homeURL.appendingPathComponent(".var/app/dev.zed.Zed/config/zed/settings.json"),
            fixture.homeURL.appendingPathComponent("snap/zed"),
            fixture.homeURL.appendingPathComponent("snap/zed/current/.config"),
            fixture.homeURL.appendingPathComponent("snap/firefox/common/.cache/mozilla"),
            fixture.homeURL.appendingPathComponent(".ollama/id_ed25519")
        ]
        for item in protected {
            XCTAssertFalse(guardrail.validateTarget(item).isAllowed, item.path)
            XCTAssertFalse(guardrail.validateUserOverrideTarget(item).isAllowed, item.path)
        }

        let allowed = [
            sandboxData.appendingPathComponent("zed/logs/Zed.log"),
            fixture.homeURL.appendingPathComponent(".var/app/dev.zed.Zed/data/zed/logs/Zed.log"),
            fixture.homeURL.appendingPathComponent(".var/app/com.cherry_ai.CherryStudio/config/CherryStudio/Cache"),
            fixture.homeURL.appendingPathComponent("snap/zed/current/.cache/zed")
        ]
        for item in allowed {
            let decision = guardrail.validateTarget(item)
            XCTAssertTrue(decision.isAllowed, "\(item.path) -> \(decision)")
        }
    }

    func testLinuxBlocksCrossMountDirectoriesDuringRecursiveValidation() throws {
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let cacheDir = try fixture.createDirectory(relativeToHome: "cache-dir")
        _ = try fixture.createFile(relativeToHome: "cache-dir/mounted/file.log", byteCount: 16)
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL,
            identityOverride: { url in
                guard url.lastPathComponent == "mounted" else { return nil }
                return FileIdentity(
                    kind: .directory,
                    owner: HostPlatformAdapter.shared.currentPrincipal,
                    volumeID: 999_999,
                    fileID: 42,
                    size: 0,
                    modifiedAt: Date()
                )
            }
        )
        let guardrail = SafetyGuard(platform: platform)
        XCTAssertFalse(guardrail.validateTargetRecursively(cacheDir).isAllowed)
        let inspection = DirectorySizer(platform: platform).inspect(url: cacheDir, safetyGuard: guardrail)
        XCTAssertNotNil(inspection?.protectedDescendantReason)
    }

    func testLinuxKeepsSharedTempRootOtherHomesAndSystemVirtualFilesOutsideCleanup() throws {
        #if !os(Windows)
        let fixture = try TestSandbox()
        defer { fixture.cleanup() }
        let platform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL
        )
        let guardrail = SafetyGuard(platform: platform)
        XCTAssertFalse(guardrail.validateUserOverrideTarget(URL(fileURLWithPath: "/proc/1/fd/1")).isAllowed)
        XCTAssertFalse(guardrail.validateUserOverrideTarget(URL(fileURLWithPath: "/sys/kernel/notes")).isAllowed)
        XCTAssertFalse(guardrail.validateUserOverrideTarget(URL(fileURLWithPath: "/run/user/example.txt")).isAllowed)
        XCTAssertFalse(guardrail.validateUserOverrideTarget(URL(fileURLWithPath: "/home/other-user/.cache/zed")).isAllowed)
        XCTAssertFalse(guardrail.validateTarget(URL(fileURLWithPath: "/tmp", isDirectory: true)).isAllowed)

        // Verify Linux /tmp scanning reuses Core ownership & unattributed manual-only boundary.
        let fakeTmp = try fixture.createDirectory(relativeToHome: "fake-tmp")
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        _ = try fixture.createFile(relativeToHome: "fake-tmp/opencode/run.log", byteCount: 32, modifiedAt: oldDate)
        _ = try fixture.createFile(relativeToHome: "fake-tmp/root-owned.log", byteCount: 64, modifiedAt: oldDate)
        _ = try fixture.createFile(relativeToHome: "fake-tmp/user-scratch.txt", byteCount: 48, modifiedAt: oldDate)
        let otherPrincipal: Principal = HostPlatformAdapter.shared.currentPrincipal == .uid(0) ? .uid(65_534) : .uid(0)
        let scopedPlatform = SandboxPlatformAdapter(
            wrapping: HostPlatformAdapter.shared,
            platform: .linux,
            homeDirectory: fixture.homeURL,
            ownerOverride: { url in
                url.lastPathComponent == "root-owned.log" ? otherPrincipal : nil
            }
        )
        let scanner = TempDirectoryScanner(
            safetyGuard: SafetyGuard(platform: scopedPlatform),
            useDefaultActiveTempPath: false
        )
        let result = scanner.scan(
            systemTempRoot: fakeTmp,
            userTempRoot: fakeTmp,
            builtInProfiles: BuiltInClientRules.profiles(for: scopedPlatform),
            referenceNow: Date()
        )
        XCTAssertEqual(result.builtInClientItems["opencode"]?.map(\.fileName), ["opencode"])
        XCTAssertEqual(result.unattributedTempSummary?.items.map(\.fileName), ["user-scratch.txt"])
        XCTAssertEqual(result.unattributedTempSummary?.items.first?.requiresIndividualSelection, true)
        XCTAssertGreaterThanOrEqual(result.skippedProtectedCount, 1)
        #endif
    }
}
