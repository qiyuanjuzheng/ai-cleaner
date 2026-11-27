import AICleanerCore
import Dispatch
import Foundation
#if os(Windows)
import CRT
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Optional E2E / test sandbox wrapper activated strictly when `AI_CLEANER_HOME` is set.
/// Delegates all filesystem inspection, locking, disk capacity, and native recycle operations
/// to `HostPlatformAdapter.shared` while confining home / app-data / temp roots to the sandbox.
private struct SandboxOverridePlatformAdapter: PlatformAdapter {
    private let base: HostPlatformAdapter
    let homeDirectory: URL
    private let userDataDir: URL
    private let userTmpDir: URL
    private let sharedTmpDir: URL?

    init(homeDirectory: URL, sharedTempDirectory: URL? = nil, base: HostPlatformAdapter = .shared) {
        self.base = base
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.userDataDir = self.homeDirectory.appendingPathComponent(".aicleaner-data", isDirectory: true)
        self.userTmpDir = self.homeDirectory.appendingPathComponent(".aicleaner-tmp", isDirectory: true)
        self.sharedTmpDir = sharedTempDirectory?.standardizedFileURL
    }

    var platform: PlatformKind { base.platform }
    var currentPrincipal: Principal { base.currentPrincipal }
    var selfIdentifiers: [String] { base.selfIdentifiers }
    var pathsAreCaseInsensitive: Bool { base.pathsAreCaseInsensitive }
    var protectedUserDirectories: [URL] { [] }
    var currentExecutableURL: URL? { base.currentExecutableURL }
    var startupVolumeURL: URL { base.startupVolumeURL }

    func resolve(_ placeholder: PathPlaceholder) -> URL? {
        switch (platform, placeholder) {
        case (_, .home): return homeDirectory
        case (_, .tmp): return userTmpDir
        case (.macos, .appSupport): return homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        case (.macos, .caches): return homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        case (.macos, .logs): return homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)
        case (.windows, .appData): return homeDirectory.appendingPathComponent("AppData/Roaming", isDirectory: true)
        case (.windows, .localAppData): return homeDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
        case (.linux, .xdgConfig): return homeDirectory.appendingPathComponent(".config", isDirectory: true)
        case (.linux, .xdgCache): return homeDirectory.appendingPathComponent(".cache", isDirectory: true)
        case (.linux, .xdgData): return homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        default: return nil
        }
    }

    func userDataDirectory() -> URL { userDataDir }

    func temporaryRoots() -> TemporaryRoots {
        TemporaryRoots(shared: sharedTmpDir, user: userTmpDir)
    }

    func identity(at url: URL) throws -> FileIdentity { try base.identity(at: url) }
    func diskCapacity(for url: URL) -> DiskCapacity? { base.diskCapacity(for: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func environmentVariable(_ name: String) -> String? { base.environmentVariable(name) }
    func hasActiveFileLock(at url: URL) -> Bool { base.hasActiveFileLock(at: url) }
    func resolveSymlinks(at url: URL) -> URL { base.resolveSymlinks(at: url) }
    func volumeIsCaseSensitive(at url: URL) -> Bool { base.volumeIsCaseSensitive(at: url) }

    func moveToTrash(_ url: URL) throws -> TrashOutcome {
        #if os(Linux)
        let dataHome = resolve(.xdgData) ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        return try LinuxTrash.move(url, dataHome: dataHome, platform: base)
        #else
        return try base.moveToTrash(url)
        #endif
    }
}

@main
struct SidecarMain {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let platform: any PlatformAdapter
        if let rawHome = env["AI_CLEANER_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHome.isEmpty {
            let homeURL = URL(fileURLWithPath: rawHome, isDirectory: true).standardizedFileURL
            let sharedTmp = env["AI_CLEANER_SYSTEM_TMP"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sharedTmpURL = (sharedTmp?.isEmpty == false)
                ? URL(fileURLWithPath: sharedTmp!, isDirectory: true).standardizedFileURL
                : nil
            platform = SandboxOverridePlatformAdapter(homeDirectory: homeURL, sharedTempDirectory: sharedTmpURL)
        } else {
            platform = HostPlatformAdapter.shared
        }

        let lock: DataDirectoryLock
        do {
            lock = try DataDirectoryLock(directory: platform.userDataDirectory())
        } catch {
            let message = "aicleaner-core: failed to acquire core.lock: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(1)
        }
        let server = SidecarServer(platform: platform) { message in
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0a)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        let input = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let consumed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                if case .terminated = input.continuation.yield(line) { break }
                consumed.wait()
            }
            input.continuation.finish()
        }
        let timeout = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if await server.isIdle() {
                    input.continuation.finish()
                    break
                }
            }
        }
        for await line in input.stream {
            let keepRunning = await server.receive(line)
            if !keepRunning { input.continuation.finish() }
            consumed.signal()
            if !keepRunning { break }
        }
        timeout.cancel()
        await server.stop()
        withExtendedLifetime(lock) {
            // A host may leave stdin open after shutdown or while idle. The reader can
            // still be blocked in readLine; bypass stdio finalization after writing the reply.
            _exit(0)
        }
    }
}
