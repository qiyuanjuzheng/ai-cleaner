import AICleanerCore
import Foundation
import XCTest

final class SafetyGuardTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var safetyGuard: SafetyGuard!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "SafetyGuardTests")
        safetyGuard = SafetyGuard(homeDirectory: sandbox.homeURL)
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
        safetyGuard = nil
    }

    func testBlocksSystemAndHomeRootPaths() {
        let blockedURLs: [URL] = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/System/Library"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/etc/hosts"),
            sandbox.homeURL,
            sandbox.homeURL.appendingPathComponent("Desktop"),
            sandbox.homeURL.appendingPathComponent("Documents"),
            sandbox.homeURL.appendingPathComponent("Downloads"),
            sandbox.homeURL.appendingPathComponent(".ssh/id_rsa"),
            sandbox.homeURL.appendingPathComponent("Library/Keychains/login.keychain-db"),
            sandbox.homeURL.appendingPathComponent("Library/Preferences/com.example.plist"),
            sandbox.homeURL.appendingPathComponent("Library/HTTPStorages/com.openai.chat")
        ]

        for url in blockedURLs {
            let decision = safetyGuard.validateTarget(url)
            XCTAssertFalse(decision.isAllowed, "预期应拦截高风险路径：\(url.path)")
        }
    }

    func testBlocksAIClientRootDirectories() throws {
        let clientRoots = [
            try sandbox.createDirectory(relativeToHome: ".claude"),
            try sandbox.createDirectory(relativeToHome: ".codex"),
            try sandbox.createDirectory(relativeToHome: ".cursor"),
            try sandbox.createDirectory(relativeToHome: "Library/Application Support/Cursor"),
            try sandbox.createDirectory(relativeToHome: "Library/Application Support/Claude"),
            try sandbox.createDirectory(relativeToHome: "Library/Application Support/Codex")
        ]

        for root in clientRoots {
            XCTAssertFalse(
                safetyGuard.validateTarget(root).isAllowed,
                "客户端根目录不应允许整体清理：\(root.path)"
            )
            XCTAssertFalse(
                safetyGuard.validateCustomDirectoryRoot(root).isAllowed,
                "客户端根目录不应允许直接作为自定义扫描根目录：\(root.path)"
            )
        }
    }

    func testBlocksCredentialsConfigsAndDatabases() throws {
        let protectedFiles = [
            ".claude/settings.json",
            ".claude/CLAUDE.md",
            ".codex/auth.json",
            ".codex/auth.json.backup-20260101",
            ".codex/config.toml",
            ".codex/memories_1.sqlite",
            ".local/share/opencode/opencode.db",
            ".local/share/opencode/opencode.db-wal",
            "custom-temp/.env",
            "custom-temp/.env.production",
            "custom-temp/my_openai_api_key.txt",
            "custom-temp/oauth_token.json",
            "custom-temp/client_secret.yaml",
            "custom-temp/private.pem",
            "Library/Application Support/Claude/claude_desktop_config.json",
            "Library/Application Support/Cursor/Cookies",
            "Library/Application Support/Cursor/state.vscdb"
        ]

        for relative in protectedFiles {
            let url = try sandbox.createFile(relativeToHome: relative, byteCount: 64)
            let decision = safetyGuard.validateTarget(url)
            XCTAssertFalse(decision.isAllowed, "预期应保护敏感文件：\(relative)")
        }

        let protectedDirs = [
            "Library/Application Support/Cursor/Local Storage",
            "Library/Application Support/Cursor/Session Storage",
            "Library/Application Support/Cursor/IndexedDB",
            "Library/Application Support/Cursor/globalStorage",
            ".claude/projects",
            ".claude/skills",
            ".codex/memories"
        ]

        for relative in protectedDirs {
            let url = try sandbox.createDirectory(relativeToHome: relative)
            let decision = safetyGuard.validateTarget(url)
            XCTAssertFalse(decision.isAllowed, "预期应保护关键数据目录：\(relative)")
        }
    }

    func testAllowsSafeCacheLogAndTempDirectoriesAndURLCacheException() throws {
        let safeDirs = [
            try sandbox.createDirectory(relativeToHome: ".claude/paste-cache"),
            try sandbox.createDirectory(relativeToHome: ".claude/debug"),
            try sandbox.createDirectory(relativeToHome: "Library/Application Support/Cursor/GPUCache"),
            try sandbox.createDirectory(relativeToHome: "Library/Application Support/Codex/Crashpad"),
            try sandbox.createDirectory(relativeToHome: "Library/Caches/com.openai.codex")
        ]

        for dir in safeDirs {
            XCTAssertTrue(
                safetyGuard.validateTarget(dir).isAllowed,
                "合法缓存/日志目录应允许扫描：\(dir.path)"
            )
        }

        // ~/Library/Caches 内的 macOS URLCache Cache.db 应允许，但其他目录的 Cache.db 仍须拦截
        let urlCacheDB = try sandbox.createFile(
            relativeToHome: "Library/Caches/com.openai.codex/Cache.db",
            byteCount: 256
        )
        XCTAssertTrue(safetyGuard.validateEntry(url: urlCacheDB, isDirectory: false).isAllowed)

        let customDB = try sandbox.createFile(relativeToHome: "custom-dir/Cache.db", byteCount: 256)
        XCTAssertFalse(safetyGuard.validateEntry(url: customDB, isDirectory: false).isAllowed)
    }

    func testBlocksSymlinkPointingOutsideOrToProtectedFile() throws {
        let secretFile = try sandbox.createFile(relativeToHome: "vault/auth.json", byteCount: 64)
        let benignOutside = try sandbox.createFile(relativeToHome: "outside/normal.log", byteCount: 64)

        let linkToSecret = try sandbox.createSymlink(
            relativeToHome: ".claude/debug/sneaky.log",
            destination: secretFile
        )
        let linkOutside = try sandbox.createSymlink(
            relativeToHome: ".claude/debug/escape.log",
            destination: benignOutside
        )

        XCTAssertFalse(safetyGuard.validateTarget(linkToSecret).isAllowed)
        XCTAssertFalse(safetyGuard.validateTarget(linkOutside).isAllowed)
    }
}
