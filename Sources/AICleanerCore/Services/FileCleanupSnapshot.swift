import Darwin
import Foundation

/// Captures the scanned entry and, for a directory, its contents without following symlinks.
public struct FileCleanupSnapshot: Hashable, Sendable {
    private struct Entry: Hashable {
        struct Time: Hashable, Comparable {
            let seconds: Int
            let nanoseconds: Int

            init(_ value: timespec) {
                seconds = value.tv_sec
                nanoseconds = value.tv_nsec
            }

            static func < (lhs: Self, rhs: Self) -> Bool {
                (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
            }

            var date: Date {
                Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
            }
        }

        let identity: Identity
        let mode: mode_t
        let size: off_t
        let changed: Time
        let modified: Time

        struct Identity: Hashable {
            let device: dev_t
            let inode: ino_t
            let created: Time
        }

        init?(at url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in
                path.map { lstat($0, &info) } == 0
            }), info.st_ino != 0 else { return nil }

            identity = Identity(device: info.st_dev, inode: info.st_ino, created: Time(info.st_birthtimespec))
            mode = info.st_mode
            size = info.st_size
            changed = Time(info.st_ctimespec)
            modified = Time(info.st_mtimespec)
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    }

    private let root: Entry
    private let descendants: [String: Entry]
    /// Directory-backed sessions use the latest modification time of their regular files.
    public let modifiedAt: Date?

    public static func capture(at rawURL: URL, fileManager: FileManager = .default) -> Self? {
        let url = SafetyGuard.normalizeTempPath(rawURL).standardizedFileURL
        guard let root = Entry(at: url) else { return nil }
        var latest: Entry.Time? = root.isRegularFile ? root.modified : nil
        var descendants: [String: Entry] = [:]
        if root.isDirectory {
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [], errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else { return nil }

            for case let child as URL in enumerator {
                guard !Task.isCancelled, let entry = Entry(at: child) else { return nil }
                if entry.isRegularFile {
                    latest = max(latest ?? entry.modified, entry.modified)
                }
                descendants[child.path] = entry
            }
            guard !enumerationFailed, Entry(at: url) == root else { return nil }
        }
        return Self(root: root, descendants: descendants, modifiedAt: latest?.date)
    }

    func changeReason(at url: URL) -> String? {
        guard let current = Self.capture(at: url) else { return "无法重新验证条目的文件身份或修改时间，请重新扫描" }
        if current.root.identity != root.identity {
            return "条目已被替换，请重新扫描"
        }
        if current != self {
            return "条目或其内容已更新，请重新扫描"
        }
        return nil
    }
}
