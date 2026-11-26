#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 通过 `PlatformAdapter` 捕获扫描条目及其目录后代的文件身份快照（绝不穿透符号链接或 Windows 重解析点）。
public struct FileCleanupSnapshot: Hashable, Sendable {
    private struct Entry: Hashable, Sendable {
        struct Identity: Hashable, Sendable {
            let volumeID: UInt64
            let fileID: UInt64
            let fileIDHigh: UInt64
            /// 有 birthtime 时优先比对创建时间戳；Linux 等读不到 birthtime 的平台回退比对 ctime（ADR 0001 第 5.2 节）。
            let creationAnchor: FileTimestamp?
        }

        let identity: Identity
        let kind: FileKind
        let size: Int64
        let changed: FileTimestamp?
        let modified: FileTimestamp

        init?(at url: URL, platform: any PlatformAdapter) {
            guard let info = try? platform.identity(at: url),
                  (info.fileID != 0 || info.fileIDHigh != 0) else {
                return nil
            }
            let anchor = info.createdTimestamp ?? info.changedTimestamp
            self.identity = Identity(
                volumeID: info.volumeID,
                fileID: info.fileID,
                fileIDHigh: info.fileIDHigh,
                creationAnchor: anchor
            )
            self.kind = info.kind
            self.size = info.size
            self.changed = info.changedTimestamp
            self.modified = info.modifiedTimestamp
        }

        var isDirectory: Bool { kind == .directory }
        var isRegularFile: Bool { kind == .regular }
    }

    private let root: Entry
    private let descendants: [String: Entry]
    /// Directory-backed sessions use the latest modification time of their regular files.
    public let modifiedAt: Date?

    public static func capture(at url: URL, fileManager: FileManager = .default) -> Self? {
        capture(at: url, platform: HostPlatformAdapter.shared)
    }

    public static func capture(
        at rawURL: URL,
        platform: any PlatformAdapter
    ) -> Self? {
        let url = SafetyGuard.normalizeTempPath(rawURL, platform: platform).standardizedFileURL
        guard let root = Entry(at: url, platform: platform) else { return nil }
        var latest: FileTimestamp? = root.isRegularFile ? root.modified : nil
        var descendants: [String: Entry] = [:]

        if root.isDirectory {
            var stack: [URL] = [url]
            while let currentDir = stack.popLast() {
                guard !Task.isCancelled,
                      let children = try? platform.contentsOfDirectory(at: currentDir) else {
                    return nil
                }
                for child in children {
                    guard !Task.isCancelled,
                          let entry = Entry(at: child, platform: platform) else {
                        return nil
                    }
                    if entry.isRegularFile {
                        latest = max(latest ?? entry.modified, entry.modified)
                    }
                    descendants[PlatformPath.normalize(child)] = entry
                    if entry.isDirectory {
                        stack.append(child)
                    }
                }
            }
            guard Entry(at: url, platform: platform) == root else { return nil }
        }

        return Self(root: root, descendants: descendants, modifiedAt: latest?.date)
    }

    func changeReason(at url: URL, platform: any PlatformAdapter) -> String? {
        guard let current = Self.capture(at: url, platform: platform) else {
            return "无法重新验证条目的文件身份或修改时间，请重新扫描"
        }
        if current.root.identity != root.identity {
            return "条目已被替换，请重新扫描"
        }
        if current != self {
            return "条目或其内容已更新，请重新扫描"
        }
        return nil
    }
}
