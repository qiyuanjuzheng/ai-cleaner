#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 目标运行平台类型（与 ADR 0001 第 5 节及规则 schema v1 对齐）。
public enum PlatformKind: String, Codable, Hashable, Sendable {
    case macos
    case windows
    case linux
}

/// 跨平台路径占位符（与 ADR 0001 第 5 / 8.2 节对齐）。
public enum PathPlaceholder: String, CaseIterable, Hashable, Sendable {
    case home, tmp                                   // 三端
    case appSupport, caches, logs                    // macOS
    case appData, localAppData                       // Windows
    case xdgConfig, xdgCache, xdgData                // Linux
}

/// 跨平台用户主体身份（POSIX UID / Windows SID）。
public enum Principal: Hashable, Sendable {
    case uid(UInt32)        // macOS / Linux
    case sid(String)        // Windows，例如 "S-1-5-21-…"
}

/// 跨平台文件系统节点类型（不穿透符号链接与 Windows 重解析点）。
public enum FileKind: Hashable, Sendable {
    case regular
    case directory
    case symlink                          // POSIX 符号链接 / Windows 符号链接
    case reparsePoint(tag: UInt32)        // Windows junction、挂载点、云文件占位符等
    case fifo
    case socket
    case device
    case other

    /// 是否为特殊系统节点（FIFO / Socket / 设备文件）。
    public var isSpecialNode: Bool {
        switch self {
        case .fifo, .socket, .device:
            return true
        default:
            return false
        }
    }

    /// 是否为符号链接或 Windows 重解析点（junction / 挂载点 / 云占位符等）。
    public var isLinkOrReparsePoint: Bool {
        switch self {
        case .symlink, .reparsePoint:
            return true
        default:
            return false
        }
    }
}

/// 纳秒精度文件时间戳，供 `FileCleanupSnapshot` 跨平台精确比对文件身份与变更。
public struct FileTimestamp: Hashable, Comparable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32 = 0) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public init(date: Date) {
        let interval = date.timeIntervalSince1970
        let whole = interval.rounded(.down)
        let frac = interval - whole
        self.seconds = Int64(whole)
        self.nanoseconds = Int32(max(0, min(999_999_999, (frac * 1_000_000_000.0).rounded())))
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000.0)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// 单条文件系统节点的只读身份快照（绝不穿透符号链接或 Windows 重解析点）。
public struct FileIdentity: Hashable, Sendable {
    public let kind: FileKind
    public let owner: Principal?
    public let volumeID: UInt64           // st_dev / VolumeSerialNumber
    public let fileID: UInt64             // st_ino / FileIndex 低 64 位
    public let fileIDHigh: UInt64         // Windows 128 位 FileId 高 64 位（POSIX 恒为 0）
    public let size: Int64
    public let modifiedAt: Date
    public let changedAt: Date?           // ctime；Windows 用 ChangeTime
    public let createdAt: Date?           // birthtime；Linux 用 statx 读，读不到为 nil
    public let modifiedTimestamp: FileTimestamp
    public let changedTimestamp: FileTimestamp?
    public let createdTimestamp: FileTimestamp?
    public let isHiddenOrSystem: Bool     // Windows FILE_ATTRIBUTE_HIDDEN|SYSTEM；POSIX 恒为 false

    public init(
        kind: FileKind,
        owner: Principal?,
        volumeID: UInt64,
        fileID: UInt64,
        fileIDHigh: UInt64 = 0,
        size: Int64,
        modifiedTimestamp: FileTimestamp,
        changedTimestamp: FileTimestamp? = nil,
        createdTimestamp: FileTimestamp? = nil,
        isHiddenOrSystem: Bool = false
    ) {
        self.kind = kind
        self.owner = owner
        self.volumeID = volumeID
        self.fileID = fileID
        self.fileIDHigh = fileIDHigh
        self.size = size
        self.modifiedTimestamp = modifiedTimestamp
        self.changedTimestamp = changedTimestamp
        self.createdTimestamp = createdTimestamp
        self.modifiedAt = modifiedTimestamp.date
        self.changedAt = changedTimestamp?.date
        self.createdAt = createdTimestamp?.date
        self.isHiddenOrSystem = isHiddenOrSystem
    }

    public init(
        kind: FileKind,
        owner: Principal?,
        volumeID: UInt64,
        fileID: UInt64,
        fileIDHigh: UInt64 = 0,
        size: Int64,
        modifiedAt: Date,
        changedAt: Date? = nil,
        createdAt: Date? = nil,
        isHiddenOrSystem: Bool = false
    ) {
        self.init(
            kind: kind,
            owner: owner,
            volumeID: volumeID,
            fileID: fileID,
            fileIDHigh: fileIDHigh,
            size: size,
            modifiedTimestamp: FileTimestamp(date: modifiedAt),
            changedTimestamp: changedAt.map(FileTimestamp.init(date:)),
            createdTimestamp: createdAt.map(FileTimestamp.init(date:)),
            isHiddenOrSystem: isHiddenOrSystem
        )
    }
}

/// 磁盘卷容量读数。
public struct DiskCapacity: Hashable, Sendable {
    public let total: Int64
    public let available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }
}

/// 系统与当前用户临时目录根路径。
public struct TemporaryRoots: Hashable, Sendable {
    public let shared: URL?   // macOS /private/tmp；Linux /tmp；Windows nil（%SystemRoot%\Temp 不扫描）
    public let user: URL      // macOS DARWIN_USER_TEMP_DIR；Windows GetTempPath2W；Linux $TMPDIR 或 /tmp

    public init(shared: URL?, user: URL) {
        self.shared = shared?.standardizedFileURL
        self.user = user.standardizedFileURL
    }
}

/// 移入系统回收站的成功结果。
public enum TrashOutcome: Equatable, Sendable {
    case trashed(location: URL?)
}

/// 移入系统回收站的错误分类：无法安全回收时必须返回 `.unavailable`，绝不降级为永久删除。
public enum TrashError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case let .unavailable(reason):
            return reason
        case let .failed(reason):
            return reason
        }
    }
}

#if !canImport(FoundationEssentials)
extension TrashError: LocalizedError {
    public var errorDescription: String? { description }
}
#endif

/// 文件身份读取错误。
public enum PlatformFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case accessDenied(String)
    case ioError(path: String, code: Int32)

    public var description: String {
        switch self {
        case let .notFound(path):
            return "路径不存在：\(path)"
        case let .accessDenied(path):
            return "无权访问路径：\(path)"
        case let .ioError(path, code):
            return "读取文件信息失败（错误码 \(code)）：\(path)"
        }
    }
}

/// 跨平台只读常规文件流（打开时不穿透符号链接或重解析点，替代 `FileHandle` 以兼容 `FoundationEssentials`）。
public protocol ReadOnlyFileReader {
    func read(upToCount count: Int) -> Data?
    func seekToEnd() -> UInt64?
    func seek(toOffset offset: UInt64) -> Bool
    func close()
}

/// 平台适配层契约（ADR 0001 第 5 节）。
/// Core 所有构造入口均通过注入此协议解耦平台差异，不直接访问 OS API 或全局宿主状态。
public protocol PlatformAdapter: Sendable {
    var platform: PlatformKind { get }
    var homeDirectory: URL { get }
    var currentPrincipal: Principal { get }
    /// AI Cleaner 自身的标识（Bundle ID / 进程名前缀），扫描临时目录时用来排除自己。
    var selfIdentifiers: [String] { get }

    func resolve(_ placeholder: PathPlaceholder) -> URL?
    func userDataDirectory() -> URL
    func temporaryRoots() -> TemporaryRoots

    /// 读取文件身份，绝不穿透符号链接 / reparse point。
    func identity(at url: URL) throws -> FileIdentity
    func diskCapacity(for url: URL) -> DiskCapacity?

    /// 移入系统回收站。无法回收时必须抛 `TrashError.unavailable`，绝不降级为永久删除。
    func moveToTrash(_ url: URL) throws -> TrashOutcome

    /// 路径比较语义：macOS 按 APFS 默认不区分大小写；Windows 不区分；Linux 区分。
    var pathsAreCaseInsensitive: Bool { get }

    // MARK: - 跨平台增量辅助能力（ADR 0001 第 13 节允许增量扩展）

    /// 启动/数据卷查询路径（macOS `/System/Volumes/Data`，Linux `/`，Windows 系统盘根目录）。
    var startupVolumeURL: URL { get }
    /// Known personal folders can be redirected outside the home directory.
    var protectedUserDirectories: [URL] { get }
    /// 当前进程可执行文件路径（用于临时目录自保护，替代 `Bundle.main.executableURL`）。
    var currentExecutableURL: URL? { get }
    /// 读取指定环境变量（替代 `ProcessInfo.processInfo.environment`）。
    func environmentVariable(_ name: String) -> String?
    /// 检测文件是否持有活跃 OS 级锁（POSIX fcntl/flock；Windows 共享违例探测）。
    func hasActiveFileLock(at url: URL) -> Bool
    /// 解析符号链接/重解析点对应的真实目标路径；若路径不存在则返回标准化路径。
    func resolveSymlinks(at url: URL) -> URL
    /// 检查路径所在卷是否区分大小写。
    func volumeIsCaseSensitive(at url: URL) -> Bool
    /// 列出目录的直接子项 URL（不递归、不跟随符号链接）。
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// 以只读且不穿透符号链接/重解析点的方式打开常规文件。
    func openReadOnlyRegularFile(at url: URL) -> (any ReadOnlyFileReader)?
}

extension PlatformAdapter {
    public var startupVolumeURL: URL {
        switch platform {
        case .macos:
            return URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        case .linux:
            return URL(fileURLWithPath: "/", isDirectory: true)
        case .windows:
            let homeNormalized = PlatformPath.normalize(homeDirectory)
            if PlatformPath.hasWindowsDrivePrefix(homeNormalized) {
                return URL(fileURLWithPath: String(homeNormalized.prefix(3)), isDirectory: true)
            }
            return URL(fileURLWithPath: "C:\\", isDirectory: true)
        }
    }

    public var protectedUserDirectories: [URL] { [] }

    public var currentExecutableURL: URL? { nil }

    public func environmentVariable(_ name: String) -> String? { nil }

    public func hasActiveFileLock(at url: URL) -> Bool { false }

    public func resolveSymlinks(at url: URL) -> URL {
        url.standardizedFileURL
    }

    public func volumeIsCaseSensitive(at url: URL) -> Bool {
        !pathsAreCaseInsensitive
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        guard (try? identity(at: url))?.kind == .directory else {
            throw PlatformFileError.accessDenied(PlatformPath.fileSystemPath(for: url))
        }
        return try HostPlatformAdapter.shared.contentsOfDirectory(at: url)
    }

    public func openReadOnlyRegularFile(at url: URL) -> (any ReadOnlyFileReader)? {
        guard (try? identity(at: url))?.kind == .regular else { return nil }
        return HostPlatformAdapter.shared.openReadOnlyRegularFile(at: url)
    }
}

/// 将任意 `PlatformAdapter.moveToTrash(_:)` 包装为 `TrashPerforming`。
public struct PlatformTrashPerformer: TrashPerforming {
    public let platform: any PlatformAdapter

    public init(platform: any PlatformAdapter) {
        self.platform = platform
    }

    public func trashItem(at url: URL) throws -> URL? {
        switch try platform.moveToTrash(url) {
        case let .trashed(location):
            return location
        }
    }
}

/// 跨平台测试与沙箱适配器：包裹底层真实适配器并允许确定性覆写平台类型、主体身份、文件身份、锁状态、磁盘容量与回收站行为。
public struct SandboxPlatformAdapter: PlatformAdapter {
    public let base: any PlatformAdapter
    public let platform: PlatformKind
    public let homeDirectory: URL
    public let currentPrincipal: Principal
    public let selfIdentifiers: [String]
    public let pathsAreCaseInsensitive: Bool
    public let customUserDataDirectory: URL?
    public let customTemporaryRoots: TemporaryRoots?
    public let customStartupVolumeURL: URL?
    public let environmentOverrides: [String: String]
    public let identityOverride: (@Sendable (URL) throws -> FileIdentity?)?
    public let ownerOverride: (@Sendable (URL) -> Principal?)?
    public let diskCapacityOverride: (@Sendable (URL) -> DiskCapacity?)?
    public let activeLockOverride: (@Sendable (URL) -> Bool)?
    public let moveToTrashOverride: (@Sendable (URL) throws -> TrashOutcome)?
    public let mockTrashDirectory: URL?

    public init(
        wrapping base: any PlatformAdapter,
        platform: PlatformKind? = nil,
        homeDirectory: URL? = nil,
        currentPrincipal: Principal? = nil,
        selfIdentifiers: [String]? = nil,
        pathsAreCaseInsensitive: Bool? = nil,
        userDataDirectory: URL? = nil,
        temporaryRoots: TemporaryRoots? = nil,
        startupVolumeURL: URL? = nil,
        environmentOverrides: [String: String] = [:],
        identityOverride: (@Sendable (URL) throws -> FileIdentity?)? = nil,
        ownerOverride: (@Sendable (URL) -> Principal?)? = nil,
        diskCapacityOverride: (@Sendable (URL) -> DiskCapacity?)? = nil,
        activeLockOverride: (@Sendable (URL) -> Bool)? = nil,
        moveToTrashOverride: (@Sendable (URL) throws -> TrashOutcome)? = nil,
        mockTrashDirectory: URL? = nil
    ) {
        self.base = base
        let resolvedPlatform = platform ?? base.platform
        self.platform = resolvedPlatform
        self.homeDirectory = (homeDirectory ?? base.homeDirectory).standardizedFileURL
        self.currentPrincipal = currentPrincipal ?? base.currentPrincipal
        self.selfIdentifiers = selfIdentifiers ?? base.selfIdentifiers
        self.pathsAreCaseInsensitive = pathsAreCaseInsensitive ?? (resolvedPlatform != .linux)
        self.customUserDataDirectory = userDataDirectory?.standardizedFileURL
        self.customTemporaryRoots = temporaryRoots
        self.customStartupVolumeURL = startupVolumeURL?.standardizedFileURL
        self.environmentOverrides = environmentOverrides
        self.identityOverride = identityOverride
        self.ownerOverride = ownerOverride
        self.diskCapacityOverride = diskCapacityOverride
        self.activeLockOverride = activeLockOverride
        self.moveToTrashOverride = moveToTrashOverride
        self.mockTrashDirectory = mockTrashDirectory?.standardizedFileURL
    }

    public var startupVolumeURL: URL {
        customStartupVolumeURL ?? base.startupVolumeURL
    }

    public var currentExecutableURL: URL? {
        base.currentExecutableURL
    }

    public func resolve(_ placeholder: PathPlaceholder) -> URL? {
        switch (platform, placeholder) {
        case (_, .home):
            return homeDirectory
        case (_, .tmp):
            return temporaryRoots().user
        case (.macos, .appSupport):
            return homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        case (.macos, .caches):
            return homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        case (.macos, .logs):
            return homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)
        case (.windows, .appData):
            return homeDirectory.appendingPathComponent("AppData/Roaming", isDirectory: true)
        case (.windows, .localAppData):
            return homeDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
        case (.linux, .xdgConfig):
            return xdgPath("XDG_CONFIG_HOME", defaultPath: ".config")
        case (.linux, .xdgCache):
            return xdgPath("XDG_CACHE_HOME", defaultPath: ".cache")
        case (.linux, .xdgData):
            return xdgPath("XDG_DATA_HOME", defaultPath: ".local/share")
        default:
            return nil
        }
    }

    private func xdgPath(_ variable: String, defaultPath: String) -> URL {
        if let path = environmentOverrides[variable], PlatformPath.isAbsolute(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(defaultPath, isDirectory: true)
    }

    public func userDataDirectory() -> URL {
        if let customUserDataDirectory {
            return customUserDataDirectory
        }
        switch platform {
        case .macos:
            return homeDirectory.appendingPathComponent("Library/Application Support/AICleaner", isDirectory: true)
        case .windows:
            return homeDirectory.appendingPathComponent("AppData/Local/AICleaner", isDirectory: true)
        case .linux:
            return homeDirectory.appendingPathComponent(".local/share/aicleaner", isDirectory: true)
        }
    }

    public func temporaryRoots() -> TemporaryRoots {
        if let customTemporaryRoots {
            return customTemporaryRoots
        }
        return base.temporaryRoots()
    }

    public func identity(at url: URL) throws -> FileIdentity {
        if let identityOverride, let custom = try identityOverride(url) {
            return custom
        }
        let real = try base.identity(at: url)
        if let ownerOverride, let customOwner = ownerOverride(url) {
            return FileIdentity(
                kind: real.kind,
                owner: customOwner,
                volumeID: real.volumeID,
                fileID: real.fileID,
                fileIDHigh: real.fileIDHigh,
                size: real.size,
                modifiedTimestamp: real.modifiedTimestamp,
                changedTimestamp: real.changedTimestamp,
                createdTimestamp: real.createdTimestamp,
                isHiddenOrSystem: real.isHiddenOrSystem
            )
        }
        return real
    }

    public func diskCapacity(for url: URL) -> DiskCapacity? {
        if let diskCapacityOverride {
            return diskCapacityOverride(url)
        }
        return base.diskCapacity(for: url)
    }

    public func moveToTrash(_ url: URL) throws -> TrashOutcome {
        if let moveToTrashOverride {
            return try moveToTrashOverride(url)
        }
        if let mockTrashDirectory {
            try FileManager.default.createDirectory(at: mockTrashDirectory, withIntermediateDirectories: true)
            let dest = mockTrashDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            return .trashed(location: dest)
        }
        return try base.moveToTrash(url)
    }

    public func environmentVariable(_ name: String) -> String? {
        if let value = environmentOverrides[name] {
            return value
        }
        return base.environmentVariable(name)
    }

    public func hasActiveFileLock(at url: URL) -> Bool {
        if let activeLockOverride, activeLockOverride(url) {
            return true
        }
        return base.hasActiveFileLock(at: url)
    }

    public func resolveSymlinks(at url: URL) -> URL {
        base.resolveSymlinks(at: url)
    }

    public func volumeIsCaseSensitive(at url: URL) -> Bool {
        if platform == .linux {
            return true
        }
        if platform == .windows {
            return false
        }
        return base.volumeIsCaseSensitive(at: url)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    public func openReadOnlyRegularFile(at url: URL) -> (any ReadOnlyFileReader)? {
        base.openReadOnlyRegularFile(at: url)
    }
}
