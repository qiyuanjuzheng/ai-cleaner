@testable import AICleanerApp
import AICleanerCore
import AppKit
import SwiftUI
import XCTest

final class ClientLogoResolverTests: XCTestCase {
    @MainActor
    func testEveryConfiguredClientIDBelongsToBuiltInRules() {
        let builtInIDs = Set(BuiltInClientRules.allProfiles.map(\.id))
        let unmapped = ClientLogoResolver.configuredClientIDs.subtracting(builtInIDs)
        XCTAssertTrue(unmapped.isEmpty, "Unexpected client IDs in ClientLogoResolver: \(unmapped)")
    }

    @MainActor
    func testEveryBundledMarkHasValidDistinctLightAndDarkAssets() throws {
        let resolver = ClientLogoResolver(applicationURLs: { _ in [] })
        XCTAssertFalse(ClientLogoResolver.bundledMarkNames.isEmpty)

        for mark in ClientLogoResolver.bundledMarkNames {
            let light = try XCTUnwrap(
                resolver.bundledImage(named: mark, colorScheme: .light),
                "Missing light asset for \(mark)"
            )
            let dark = try XCTUnwrap(
                resolver.bundledImage(named: mark, colorScheme: .dark),
                "Missing dark asset for \(mark)"
            )
            XCTAssertTrue(light.isValid)
            XCTAssertTrue(dark.isValid)
            XCTAssertNotEqual(
                light.tiffRepresentation,
                dark.tiffRepresentation,
                "Expected distinct light/dark assets for \(mark)"
            )
        }
    }

    @MainActor
    func testDesktopAppTakesPriorityOverBundledFallback() async throws {
        let cursorApp = try FixtureApp(
            name: "Cursor",
            bundleID: "com.todesktop.230313mzl4w4u92",
            iconColor: .systemGreen
        )
        let withDesktop = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.todesktop.230313mzl4w4u92" ? [cursorApp.url] : []
        })
        let withoutDesktop = ClientLogoResolver(applicationURLs: { _ in [] })

        let desktopImage = try XCTUnwrap(withDesktop.image(for: "cursor", colorScheme: .light))
        let bundledImage = try XCTUnwrap(withoutDesktop.image(for: "cursor", colorScheme: .light))
        XCTAssertNotEqual(desktopImage.tiffRepresentation, bundledImage.tiffRepresentation)
    }

    @MainActor
    func testUnifiedChatGPTBundleIsNotShownAsStandaloneCodex() async throws {
        let chatGPT = try FixtureApp(
            name: "ChatGPT",
            bundleID: "com.openai.codex",
            executable: "ChatGPT"
        )
        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.openai.codex" ? [chatGPT.url] : []
        })

        XCTAssertNotNil(resolver.image(for: "chatgpt-desktop", colorScheme: .light))
        XCTAssertNil(resolver.image(for: "codex", colorScheme: .light))

        let standaloneCodex = try FixtureApp(
            name: "Codex",
            bundleID: "com.openai.codex",
            executable: "Codex"
        )
        let codexResolver = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.openai.codex" ? [standaloneCodex.url] : []
        })
        XCTAssertNotNil(codexResolver.image(for: "codex", colorScheme: .light))
        XCTAssertNil(codexResolver.image(for: "chatgpt-desktop", colorScheme: .light))
    }

    @MainActor
    func testWindsurfExcludesRebrandedDevinBundleAndClaudeDesktopExcludesClaudeCode() async throws {
        let devin = try FixtureApp(name: "Devin", bundleID: "com.exafunction.windsurf")
        let claudeDesktop = try FixtureApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop")
        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            switch bundleID {
            case "com.exafunction.windsurf": return [devin.url]
            case "com.anthropic.claudefordesktop": return [claudeDesktop.url]
            default: return []
            }
        })

        XCTAssertNil(resolver.image(for: "windsurf", colorScheme: .light))
        XCTAssertNotNil(resolver.image(for: "claude-desktop", colorScheme: .light))
        XCTAssertNil(resolver.image(for: "claude-code", colorScheme: .light))

        let windsurf = try FixtureApp(name: "Windsurf", bundleID: "com.exafunction.windsurf")
        let windsurfResolver = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.exafunction.windsurf" ? [windsurf.url] : []
        })
        XCTAssertNotNil(windsurfResolver.image(for: "windsurf", colorScheme: .light))
    }

    @MainActor
    func testRegionalAndChannelAliasesMatchWithoutCrossProductMisattribution() async throws {
        let traeCN = try FixtureApp(name: "Trae CN", bundleID: "cn.trae.app")
        let workBuddyAI = try FixtureApp(name: "WorkBuddy AI", bundleID: "com.workbuddy.workbuddy-ai")
        let codeBuddy = try FixtureApp(name: "CodeBuddy", bundleID: "com.tencent.codebuddy")
        let zedPreview = try FixtureApp(
            name: "Zed Preview",
            bundleID: "dev.zed.Zed-Preview",
            iconColor: .systemBlue
        )

        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            switch bundleID {
            case "cn.trae.app": return [traeCN.url]
            case "com.workbuddy.workbuddy-ai": return [workBuddyAI.url]
            case "com.tencent.codebuddy": return [codeBuddy.url]
            case "dev.zed.Zed-Preview": return [zedPreview.url]
            default: return []
            }
        })

        XCTAssertNotNil(resolver.image(for: "trae", colorScheme: .dark))
        XCTAssertNotNil(resolver.image(for: "workbuddy", colorScheme: .light))
        let zedPreviewImage = try XCTUnwrap(resolver.image(for: "zed", colorScheme: .light))
        let zedBundledImage = try XCTUnwrap(resolver.bundledImage(named: "zed", colorScheme: .light))
        XCTAssertNotEqual(zedPreviewImage.tiffRepresentation, zedBundledImage.tiffRepresentation)

        // CodeBuddy alone must not supply a logo for WorkBuddy.
        let codeBuddyOnly = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.tencent.codebuddy" ? [codeBuddy.url] : []
        })
        XCTAssertNil(codeBuddyOnly.image(for: "workbuddy", colorScheme: .light))
    }

    @MainActor
    func testCLIClientsUseVerifiedBundledMarksOrTextFallback() async throws {
        let resolver = ClientLogoResolver(applicationURLs: { _ in [] })

        for cliID in ["opencode", "pi"] {
            let light = try XCTUnwrap(resolver.image(for: cliID, colorScheme: .light))
            let dark = try XCTUnwrap(resolver.image(for: cliID, colorScheme: .dark))
            XCTAssertNotEqual(light.tiffRepresentation, dark.tiffRepresentation)
        }

        // Claude Code has no redistributable official logo and must stay text-only.
        XCTAssertNil(resolver.image(for: "claude-code", colorScheme: .light))
        XCTAssertNil(resolver.image(for: "claude-code", colorScheme: .dark))
    }

    @MainActor
    func testCombinedMultiProductAndUnverifiedClientsUseTextFallback() async throws {
        let antigravity = try FixtureApp(name: "Antigravity", bundleID: "com.google.antigravity")
        let zcode = try FixtureApp(name: "ZCode", bundleID: "dev.zcode.app")
        let doubao = try FixtureApp(name: "Doubao", bundleID: "com.bot.pc.doubao")
        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            switch bundleID {
            case "com.google.antigravity": return [antigravity.url]
            case "dev.zcode.app": return [zcode.url]
            case "com.bot.pc.doubao": return [doubao.url]
            default: return []
            }
        })

        for textOnlyID in ["gemini-antigravity", "zcode", "doubao", "lingma", "stepfun", "unknown-client"] {
            XCTAssertNil(resolver.image(for: textOnlyID, colorScheme: .light), "\(textOnlyID) should stay text-only")
            XCTAssertNil(resolver.image(for: textOnlyID, colorScheme: .dark), "\(textOnlyID) should stay text-only")
        }
    }

    @MainActor
    func testWrongBundleIDMissingIconNonAPPLAndTrashedAppsAreIgnored() async throws {
        let wrongBundle = try FixtureApp(name: "Kiro", bundleID: "example.kiro")
        let noIcon = try FixtureApp(name: "Kiro", bundleID: "dev.kiro.desktop", includeIcon: false)
        let nonAPPL = try FixtureApp(name: "Kiro", bundleID: "dev.kiro.desktop", packageType: "BNDL")
        let trashed = try FixtureApp(
            name: "Kiro",
            bundleID: "dev.kiro.desktop",
            subpath: ".Trash"
        )
        let resolver = ClientLogoResolver(applicationURLs: { _ in
            [wrongBundle.url, noIcon.url, nonAPPL.url, trashed.url]
        })

        XCTAssertNil(resolver.image(for: "kiro", colorScheme: .light))
    }

    @MainActor
    func testMissingLogosKeepScanningFilteringAndHistoryUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cleaner-logo-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeDebug = root.appendingPathComponent(".claude/debug/run.log")
        try FileManager.default.createDirectory(
            at: claudeDebug.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 2048).write(to: claudeDebug)

        let piSession = root.appendingPathComponent(".pi/agent/sessions/demo-workspace/session.jsonl")
        try FileManager.default.createDirectory(
            at: piSession.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"role\":\"user\",\"content\":\"hello\"}\n".utf8).write(to: piSession)

        let configDir = root.appendingPathComponent(".config-test", isDirectory: true)
        let guardInstance = SafetyGuard(homeDirectory: root)
        let historyStore = CleanupHistoryStore(
            storageURL: configDir.appendingPathComponent("history.json")
        )
        let customStore = CustomDirectoryStore(
            storageURL: configDir.appendingPathComponent("custom.json"),
            safetyGuard: guardInstance
        )

        let viewModel = CleanerViewModel(
            homeDirectory: root,
            customDirectoryStore: customStore,
            historyStore: historyStore
        )
        viewModel.startScan()
        for _ in 0..<80 where viewModel.isScanning || viewModel.report == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let ids = Set(viewModel.builtInSidebarEntries.map(\.id))
        XCTAssertTrue(ids.contains("claude-code"))
        XCTAssertTrue(ids.contains("pi"))

        viewModel.sidebarSelection = .client("claude-code")
        XCTAssertEqual(viewModel.headerTitleText, "Claude Code")
        XCTAssertFalse(viewModel.filteredItems.isEmpty)

        // Ensure history ranking still lists text-only clients cleanly.
        let sampleItem = try XCTUnwrap(viewModel.filteredItems.first)
        let result = CleanupResult(
            trashedItems: [
                TrashedItemRecord(item: sampleItem, resultingTrashURL: nil, trashedBytes: 4096)
            ],
            skippedProtectedItems: [],
            failedItems: [],
            freedBytes: 4096
        )
        _ = try historyStore.record(result: result)
        let reloaded = CleanerViewModel(
            homeDirectory: root,
            customDirectoryStore: customStore,
            historyStore: historyStore
        )
        XCTAssertEqual(reloaded.historySummary.topClients.first?.clientID, "claude-code")
        XCTAssertEqual(reloaded.historySummary.topClients.first?.clientName, "Claude Code")
    }
}

private final class FixtureApp {
    let root: URL
    let url: URL

    init(
        name: String,
        bundleID: String,
        executable: String? = nil,
        packageType: String = "APPL",
        includeIcon: Bool = true,
        iconColor: NSColor = .systemOrange,
        subpath: String? = nil
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = subpath.map { rootURL.appendingPathComponent($0, isDirectory: true) } ?? rootURL
        root = rootURL
        url = parent.appendingPathComponent(name + ".app")
        let contents = url.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        var plist = [
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": packageType,
            "CFBundleName": name,
            "CFBundleExecutable": executable ?? name
        ]
        if includeIcon {
            plist["CFBundleIconFile"] = "AppIcon.png"
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 64,
                    pixelsHigh: 64,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            )
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            iconColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 12, yRadius: 12).fill()
            NSGraphicsContext.restoreGraphicsState()
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: resources.appendingPathComponent("AppIcon.png"))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
