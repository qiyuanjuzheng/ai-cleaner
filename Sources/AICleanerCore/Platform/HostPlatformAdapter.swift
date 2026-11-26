#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CPlatformSupport

/// Native filesystem and operating-system services for the current process.
public struct HostPlatformAdapter: PlatformAdapter {
    public static let shared = Self()

    #if os(Windows)
    private static let pathCapacity = 131_072
    #else
    private static let pathCapacity = 4096
    #endif

    public var platform: PlatformKind {
        #if os(macOS)
        .macos
        #elseif os(Windows)
        .windows
        #else
        .linux
        #endif
    }

    public var homeDirectory: URL {
        Self.knownPath(AICL_KNOWN_PATH_HOME) ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public var currentPrincipal: Principal {
        var uid: UInt32 = 0
        var sid = [CChar](repeating: 0, count: 128)
        let result = sid.withUnsafeMutableBufferPointer {
            aicl_current_principal(&uid, $0.baseAddress, $0.count)
        }
        switch result {
        case 1: return .uid(uid)
        case 2: return .sid(Self.decode(sid))
        default: return .sid("")  // No file owner can match an unresolved principal.
        }
    }

    public var selfIdentifiers: [String] {
        var identifiers = ["com.qiyuanjuzheng.ai-cleaner", "ai-cleaner", "aicleaner"]
        #if os(macOS)
        if let bundleIdentifier = Bundle.main.bundleIdentifier { identifiers.append(bundleIdentifier) }
        #endif
        return identifiers
    }
    public var pathsAreCaseInsensitive: Bool { platform != .linux }

    public var currentExecutableURL: URL? { Self.knownPath(AICL_KNOWN_PATH_EXECUTABLE) }

    public var startupVolumeURL: URL {
        #if os(macOS)
        URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        #elseif os(Windows)
        URL(fileURLWithPath: (environmentVariable("SystemDrive") ?? "C:") + "\\", isDirectory: true)
        #else
        URL(fileURLWithPath: "/", isDirectory: true)
        #endif
    }

    public func resolve(_ placeholder: PathPlaceholder) -> URL? {
        switch (platform, placeholder) {
        case (_, .home): return homeDirectory
        case (_, .tmp): return temporaryRoots().user
        case (.macos, .appSupport): return homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        case (.macos, .caches): return homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        case (.macos, .logs): return homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)
        case (.windows, .appData): return Self.knownPath(AICL_KNOWN_PATH_WIN_ROAMING_APPDATA)
        case (.windows, .localAppData): return Self.knownPath(AICL_KNOWN_PATH_WIN_LOCAL_APPDATA)
        case (.linux, .xdgConfig): return xdgPath("XDG_CONFIG_HOME", fallback: ".config")
        case (.linux, .xdgCache): return xdgPath("XDG_CACHE_HOME", fallback: ".cache")
        case (.linux, .xdgData): return xdgPath("XDG_DATA_HOME", fallback: ".local/share")
        default: return nil
        }
    }

    public func userDataDirectory() -> URL {
        switch platform {
        case .macos:
            (resolve(.appSupport) ?? homeDirectory).appendingPathComponent("AICleaner", isDirectory: true)
        case .windows:
            (resolve(.localAppData) ?? homeDirectory.appendingPathComponent("AppData/Local"))
                .appendingPathComponent("AICleaner", isDirectory: true)
        case .linux:
            xdgPath("XDG_DATA_HOME", fallback: ".local/share").appendingPathComponent("aicleaner", isDirectory: true)
        }
    }

    public func temporaryRoots() -> TemporaryRoots {
        let shared: URL?
        switch platform {
        case .macos: shared = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        case .linux: shared = URL(fileURLWithPath: "/tmp", isDirectory: true)
        case .windows: shared = nil
        }
        return TemporaryRoots(shared: shared,
                              user: Self.knownPath(AICL_KNOWN_PATH_USER_TEMP) ?? FileManager.default.temporaryDirectory)
    }

    public func identity(at url: URL) throws -> FileIdentity {
        let path = PlatformPath.fileSystemPath(for: url)
        var info = aicl_file_identity_t()
        let code = aicl_file_identity(path, &info)
        guard code == 0 else {
            #if os(Windows)
            if code == 2 || code == 3 { throw PlatformFileError.notFound(path) }
            if code == 5 { throw PlatformFileError.accessDenied(path) }
            #else
            if code == 2 || code == 20 { throw PlatformFileError.notFound(path) }
            if code == 1 || code == 13 { throw PlatformFileError.accessDenied(path) }
            #endif
            throw PlatformFileError.ioError(path: path, code: code)
        }

        let kind: FileKind
        switch Int(info.kind) {
        case AICL_FILE_KIND_REGULAR: kind = .regular
        case AICL_FILE_KIND_DIRECTORY: kind = .directory
        case AICL_FILE_KIND_SYMLINK: kind = .symlink
        case AICL_FILE_KIND_REPARSE_POINT: kind = .reparsePoint(tag: info.reparse_tag)
        case AICL_FILE_KIND_FIFO: kind = .fifo
        case AICL_FILE_KIND_SOCKET: kind = .socket
        case AICL_FILE_KIND_DEVICE: kind = .device
        default: kind = .other
        }
        let owner: Principal?
        if info.has_uid {
            owner = .uid(info.uid)
        } else if info.has_sid {
            owner = withUnsafeBytes(of: info.sid) { bytes in
                .sid(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
            }
        } else {
            owner = nil
        }
        return FileIdentity(
            kind: kind, owner: owner, volumeID: info.volume_id, fileID: info.file_id_low,
            fileIDHigh: info.file_id_high, size: info.size,
            modifiedTimestamp: FileTimestamp(seconds: info.modified_sec, nanoseconds: info.modified_nsec),
            changedTimestamp: info.has_changed ? FileTimestamp(seconds: info.changed_sec, nanoseconds: info.changed_nsec) : nil,
            createdTimestamp: info.has_created ? FileTimestamp(seconds: info.created_sec, nanoseconds: info.created_nsec) : nil,
            isHiddenOrSystem: info.is_hidden_or_system
        )
    }

    public func diskCapacity(for url: URL) -> DiskCapacity? {
        let capacity = aicl_disk_capacity(PlatformPath.fileSystemPath(for: url))
        guard capacity.ok else { return nil }
        return DiskCapacity(total: capacity.total_bytes, available: capacity.available_bytes)
    }

    public func environmentVariable(_ name: String) -> String? {
        Self.readCString { aicl_get_env(name, $0, $1) }
    }

    public func hasActiveFileLock(at url: URL) -> Bool {
        aicl_has_active_file_lock(PlatformPath.fileSystemPath(for: url))
    }

    public func resolveSymlinks(at url: URL) -> URL {
        guard let resolved = Self.canonicalURL(at: url) else { return PlatformPath.resolveSymlinksFallback(url) }
        #if os(macOS)
        return resolved.standardizedFileURL
        #else
        return resolved
        #endif
    }

    static func canonicalURL(at url: URL) -> URL? {
        let path = PlatformPath.fileSystemPath(for: url)
        return readCString { aicl_resolve_real_path(path, $0, $1) }.map { URL(fileURLWithPath: $0) }
    }

    public func volumeIsCaseSensitive(at url: URL) -> Bool {
        switch aicl_volume_case_sensitive(PlatformPath.fileSystemPath(for: url)) {
        case 1: return true
        case 0: return false
        default: return !pathsAreCaseInsensitive
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let path = PlatformPath.fileSystemPath(for: url)
        var names: [String] = []
        let listed = withUnsafeMutablePointer(to: &names) { context in
            aicl_list_directory(path, { name, context in
                guard let name, let context, let component = String(validatingCString: name) else { return false }
                context.assumingMemoryBound(to: [String].self).pointee.append(component)
                return true
            }, context)
        }
        guard listed else { throw PlatformFileError.ioError(path: path, code: -1) }
        return names.map { url.appendingPathComponent($0) }
    }

    public func openReadOnlyRegularFile(at url: URL) -> (any ReadOnlyFileReader)? {
        guard let file = aicl_ro_file_open(PlatformPath.fileSystemPath(for: url)) else { return nil }
        return NativeFileReader(file: file)
    }

    public func moveToTrash(_ url: URL) throws -> TrashOutcome {
        #if os(macOS)
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return .trashed(location: destination as URL?)
        #elseif os(Windows)
        guard let kind = (try? identity(at: url))?.kind, kind == .regular || kind == .directory else {
            throw TrashError.unavailable("无法确认安全的 Windows 回收目标")
        }
        let path = PlatformPath.fileSystemPath(for: url)
        var destination = [CChar](repeating: 0, count: Self.pathCapacity)
        var error = [CChar](repeating: 0, count: 512)
        let status = destination.withUnsafeMutableBufferPointer { dest in
            error.withUnsafeMutableBufferPointer { message in
                aicl_windows_move_to_trash(path, dest.baseAddress, dest.count, message.baseAddress, message.count)
            }
        }
        switch Int(status) {
        case AICL_TRASH_OK:
            let path = Self.decode(destination)
            return .trashed(location: path.isEmpty ? nil : URL(fileURLWithPath: path))
        case AICL_TRASH_UNAVAILABLE: throw TrashError.unavailable(Self.decode(error))
        default: throw TrashError.failed(Self.decode(error))
        }
        #else
        return try LinuxTrash.move(url, dataHome: xdgPath("XDG_DATA_HOME", fallback: ".local/share"), platform: self)
        #endif
    }

    private func xdgPath(_ variable: String, fallback: String) -> URL {
        if let value = environmentVariable(variable), value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(fallback, isDirectory: true)
    }

    private static func knownPath(_ kind: Int) -> URL? {
        readCString { aicl_get_known_path(Int32(kind), $0, $1) }.map { URL(fileURLWithPath: $0) }
    }

    private static func readCString(_ read: (UnsafeMutablePointer<CChar>?, Int) -> Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pathCapacity)
        let count = buffer.withUnsafeMutableBufferPointer { read($0.baseAddress, $0.count) }
        return count > 0 ? decode(buffer) : nil
    }

    private static func decode(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            String(validatingCString: pointer.baseAddress!) ?? ""
        }
    }
}

private final class NativeFileReader: ReadOnlyFileReader {
    private var file: OpaquePointer?

    init(file: OpaquePointer) { self.file = file }
    deinit { close() }

    func read(upToCount count: Int) -> Data? {
        guard let file, count > 0 else { return nil }
        var bytes = Data(count: count)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            aicl_ro_file_read(file, buffer.bindMemory(to: UInt8.self).baseAddress, count)
        }
        guard readCount > 0 else { return nil }
        bytes.count = Int(readCount)
        return bytes
    }

    func seekToEnd() -> UInt64? {
        guard let file else { return nil }
        let length = aicl_ro_file_size(file)
        guard length >= 0, aicl_ro_file_seek(file, UInt64(length)) else { return nil }
        return UInt64(length)
    }

    func seek(toOffset offset: UInt64) -> Bool {
        guard let file, offset <= UInt64(Int64.max) else { return false }
        return aicl_ro_file_seek(file, offset)
    }

    func close() {
        guard let file else { return }
        self.file = nil
        aicl_ro_file_close(file)
    }
}
