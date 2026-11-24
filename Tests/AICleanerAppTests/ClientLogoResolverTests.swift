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
        XCTAssertEqual(ClientLogoResolver.configuredClientIDs, builtInIDs)
    }

    @MainActor
    func testEveryBundledMarkLoadsValidAssetsAndThemedMarksDifferBetweenLightAndDark() throws {
        let resolver = ClientLogoResolver(applicationURLs: { _ in [] })
        let marks = ClientLogoResolver.configuredBundledMarks
        XCTAssertEqual(marks.count, 30)

        for (clientID, mark) in marks {
            let light = try XCTUnwrap(
                resolver.bundledImage(for: mark, colorScheme: .light),
                "Missing light asset for \(clientID)"
            )
            let dark = try XCTUnwrap(
                resolver.bundledImage(for: mark, colorScheme: .dark),
                "Missing dark asset for \(clientID)"
            )
            XCTAssertTrue(light.isValid, "Invalid light asset for \(clientID)")
            XCTAssertTrue(dark.isValid, "Invalid dark asset for \(clientID)")

            if case .themed = mark {
                XCTAssertNotEqual(
                    light.tiffRepresentation,
                    dark.tiffRepresentation,
                    "Expected distinct light/dark assets for themed client \(clientID)"
                )
            }
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
    func testUnifiedChatGPTBundleUsesDedicatedCodexResourcesWithoutLeakingChatGPTIcon() async throws {
        // Unified ChatGPT.app WITHOUT embedded icon-codex-*.png must NOT leak ChatGPT's icon into Codex.
        let chatGPTOnly = try FixtureApp(
            name: "ChatGPT",
            bundleID: "com.openai.codex",
            executable: "ChatGPT",
            iconColor: .systemRed
        )
        let resolverWithoutCodexIcon = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.openai.codex" ? [chatGPTOnly.url] : []
        })
        let chatGPTIcon = try XCTUnwrap(resolverWithoutCodexIcon.image(for: "chatgpt-desktop", colorScheme: .light))
        let codexFallback = try XCTUnwrap(resolverWithoutCodexIcon.image(for: "codex", colorScheme: .light))
        XCTAssertNotEqual(chatGPTIcon.tiffRepresentation, codexFallback.tiffRepresentation)

        // Unified ChatGPT.app WITH embedded icon-codex-light.png / icon-codex-dark-color.png resolves real local Codex icons.
        let unifiedWithCodex = try FixtureApp(
            name: "ChatGPT",
            bundleID: "com.openai.codex",
            executable: "ChatGPT",
            iconColor: .systemRed,
            extraImages: [
                "icon-codex-light.png": .systemBlue,
                "icon-codex-dark-color.png": .systemIndigo
            ]
        )
        let resolverWithCodexIcon = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.openai.codex" ? [unifiedWithCodex.url] : []
        })
        let codexLight = try XCTUnwrap(resolverWithCodexIcon.image(for: "codex", colorScheme: .light))
        let codexDark = try XCTUnwrap(resolverWithCodexIcon.image(for: "codex", colorScheme: .dark))
        XCTAssertNotEqual(codexLight.tiffRepresentation, chatGPTIcon.tiffRepresentation)
        XCTAssertNotEqual(codexLight.tiffRepresentation, codexFallback.tiffRepresentation)
        XCTAssertNotEqual(codexLight.tiffRepresentation, codexDark.tiffRepresentation)

        // Standalone Codex.app resolves Codex directly without affecting ChatGPT Desktop.
        let standaloneCodex = try FixtureApp(
            name: "Codex",
            bundleID: "com.openai.codex",
            executable: "Codex",
            iconColor: .systemTeal
        )
        let codexOnlyResolver = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.openai.codex" ? [standaloneCodex.url] : []
        })
        let standaloneIcon = try XCTUnwrap(codexOnlyResolver.image(for: "codex", colorScheme: .light))
        let chatGPTFallback = try XCTUnwrap(codexOnlyResolver.image(for: "chatgpt-desktop", colorScheme: .light))
        XCTAssertNotEqual(standaloneIcon.tiffRepresentation, codexFallback.tiffRepresentation)
        XCTAssertNotEqual(standaloneIcon.tiffRepresentation, chatGPTFallback.tiffRepresentation)
    }

    @MainActor
    func testWindsurfExcludesRebrandedDevinBundleAndClaudeDesktopExcludesClaudeCode() async throws {
        let devin = try FixtureApp(
            name: "Devin",
            bundleID: "com.exafunction.windsurf",
            iconColor: .systemPurple
        )
        let claudeDesktop = try FixtureApp(
            name: "Claude",
            bundleID: "com.anthropic.claudefordesktop",
            iconColor: .systemOrange
        )
        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            switch bundleID {
            case "com.exafunction.windsurf": return [devin.url]
            case "com.anthropic.claudefordesktop": return [claudeDesktop.url]
            default: return []
            }
        })
        let fallbackOnly = ClientLogoResolver(applicationURLs: { _ in [] })

        // Devin.app must NOT override Windsurf's bundled mark.
        let windsurfResolved = try XCTUnwrap(resolver.image(for: "windsurf", colorScheme: .light))
        let windsurfFallback = try XCTUnwrap(fallbackOnly.image(for: "windsurf", colorScheme: .light))
        XCTAssertEqual(windsurfResolved.tiffRepresentation, windsurfFallback.tiffRepresentation)

        // Claude.app supplies claude-desktop only; claude-code keeps its dedicated CLI mark.
        let desktopClaude = try XCTUnwrap(resolver.image(for: "claude-desktop", colorScheme: .light))
        let cliClaude = try XCTUnwrap(resolver.image(for: "claude-code", colorScheme: .light))
        XCTAssertNotEqual(desktopClaude.tiffRepresentation, cliClaude.tiffRepresentation)

        // Real Windsurf.app overrides bundled fallback.
        let windsurf = try FixtureApp(
            name: "Windsurf",
            bundleID: "com.exafunction.windsurf",
            iconColor: .systemCyan
        )
        let windsurfResolver = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.exafunction.windsurf" ? [windsurf.url] : []
        })
        let windsurfDesktop = try XCTUnwrap(windsurfResolver.image(for: "windsurf", colorScheme: .light))
        XCTAssertNotEqual(windsurfDesktop.tiffRepresentation, windsurfFallback.tiffRepresentation)
    }

    @MainActor
    func testRegionalAndChannelAliasesMatchWithoutCrossProductMisattribution() async throws {
        let traeCN = try FixtureApp(name: "Trae CN", bundleID: "cn.trae.app", iconColor: .systemGreen)
        let workBuddyAI = try FixtureApp(name: "WorkBuddy AI", bundleID: "com.workbuddy.workbuddy-ai", iconColor: .systemMint)
        let codeBuddy = try FixtureApp(name: "CodeBuddy", bundleID: "com.tencent.codebuddy", iconColor: .systemYellow)
        let qoderIDE = try FixtureApp(name: "Qoder", bundleID: "com.qoder.ide", iconColor: .systemPink)
        let zedPreview = try FixtureApp(name: "Zed Preview", bundleID: "dev.zed.Zed-Preview", iconColor: .systemBlue)

        let resolver = ClientLogoResolver(applicationURLs: { bundleID in
            switch bundleID {
            case "cn.trae.app": return [traeCN.url]
            case "com.workbuddy.workbuddy-ai": return [workBuddyAI.url]
            case "com.tencent.codebuddy": return [codeBuddy.url]
            case "com.qoder.ide": return [qoderIDE.url]
            case "dev.zed.Zed-Preview": return [zedPreview.url]
            default: return []
            }
        })
        let fallbackOnly = ClientLogoResolver(applicationURLs: { _ in [] })

        for (cid, scheme) in [("trae", ColorScheme.dark), ("workbuddy", .light), ("qoder", .light), ("zed", .light)] {
            let resolved = try XCTUnwrap(resolver.image(for: cid, colorScheme: scheme))
            let bundled = try XCTUnwrap(fallbackOnly.image(for: cid, colorScheme: scheme))
            XCTAssertNotEqual(resolved.tiffRepresentation, bundled.tiffRepresentation, "\(cid) should use local alias app icon")
        }

        // CodeBuddy alone must not override WorkBuddy.
        let codeBuddyOnly = ClientLogoResolver(applicationURLs: { bundleID in
            bundleID == "com.tencent.codebuddy" ? [codeBuddy.url] : []
        })
        let wbWithCodeBuddy = try XCTUnwrap(codeBuddyOnly.image(for: "workbuddy", colorScheme: .light))
        let wbFallback = try XCTUnwrap(fallbackOnly.image(for: "workbuddy", colorScheme: .light))
        XCTAssertEqual(wbWithCodeBuddy.tiffRepresentation, wbFallback.tiffRepresentation)
    }

    @MainActor
    func testCLIClientsResolveDistinctVerifiedMarks() async throws {
        let resolver = ClientLogoResolver(applicationURLs: { _ in [] })

        for themedCLI in ["opencode", "pi", "copilot"] {
            let light = try XCTUnwrap(resolver.image(for: themedCLI, colorScheme: .light))
            let dark = try XCTUnwrap(resolver.image(for: themedCLI, colorScheme: .dark))
            XCTAssertNotEqual(light.tiffRepresentation, dark.tiffRepresentation)
        }

        for singleCLI in ["claude-code", "lingma", "stepfun"] {
            XCTAssertNotNil(resolver.image(for: singleCLI, colorScheme: .light))
            XCTAssertNotNil(resolver.image(for: singleCLI, colorScheme: .dark))
        }
    }

    @MainActor
    func testWrongBundleIDMissingIconNonAPPLTrashedAndUnbundledClientsFallBackToText() async throws {
        let wrongBundle = try FixtureApp(name: "WorkDaddy", bundleID: "example.workdaddy")
        let noIcon = try FixtureApp(name: "WorkDaddy", bundleID: "com.workdaddy.launcher", includeIcon: false)
        let nonAPPL = try FixtureApp(name: "WorkDaddy", bundleID: "com.workdaddy.launcher", packageType: "BNDL")
        let trashed = try FixtureApp(
            name: "WorkDaddy",
            bundleID: "com.workdaddy.launcher",
            subpath: ".Trash"
        )
        let resolver = ClientLogoResolver(applicationURLs: { _ in
            [wrongBundle.url, noIcon.url, nonAPPL.url, trashed.url]
        })

        XCTAssertNil(resolver.image(for: "workdaddy", colorScheme: .light))
        XCTAssertNil(resolver.image(for: "workdaddy", colorScheme: .dark))
        XCTAssertNil(resolver.image(for: "unknown-client", colorScheme: .light))
    }

    @MainActor
    func testMissingLogosKeepScanningFilteringAndHistoryUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cleaner-logo-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workDaddyLog = root.appendingPathComponent("Library/Application Support/WorkDaddy/daemon.log")
        try FileManager.default.createDirectory(
            at: workDaddyLog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 2048).write(to: workDaddyLog)

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
        XCTAssertTrue(ids.contains("workdaddy"))
        XCTAssertTrue(ids.contains("pi"))

        viewModel.sidebarSelection = .client("workdaddy")
        XCTAssertEqual(viewModel.headerTitleText, "WorkDaddy")
        XCTAssertFalse(viewModel.filteredItems.isEmpty)

        // Ensure history ranking still lists unmapped / missing-logo clients cleanly.
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
        XCTAssertEqual(reloaded.historySummary.topClients.first?.clientID, "workdaddy")
        XCTAssertEqual(reloaded.historySummary.topClients.first?.clientName, "WorkDaddy")
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
        extraImages: [String: NSColor] = [:],
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
            try Self.writeSolidIcon(color: iconColor, to: resources.appendingPathComponent("AppIcon.png"))
        }
        for (fileName, color) in extraImages {
            try Self.writeSolidIcon(color: color, to: resources.appendingPathComponent(fileName))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private static func writeSolidIcon(color: NSColor, to url: URL) throws {
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
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
