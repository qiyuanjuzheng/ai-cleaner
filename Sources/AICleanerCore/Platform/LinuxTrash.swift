#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CPlatformSupport

/// freedesktop Trash 1.0. Payloads move within their filesystem and are recoverable via `.trashinfo`.
enum LinuxTrash {
    static func move(_ url: URL, dataHome: URL, platform: HostPlatformAdapter) throws -> TrashOutcome {
        let original = PlatformPath.fileSystemPath(for: url)
        let parent = platform.resolveSymlinks(at: url.deletingLastPathComponent())
        let source = parent.appendingPathComponent(url.lastPathComponent)
        let sourcePath = PlatformPath.fileSystemPath(for: source)
        guard sourcePath.hasPrefix("/"), sourcePath != "/",
              case let .uid(uid) = platform.currentPrincipal,
              let identity = try? platform.identity(at: source),
              [.regular, .directory, .symlink].contains(identity.kind) else {
            throw TrashError.unavailable("无法确认回收目标：\(original)")
        }

        try? FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let resolvedDataHome = platform.resolveSymlinks(at: dataHome)
        if (try? platform.identity(at: resolvedDataHome))?.volumeID == identity.volumeID {
            let root = resolvedDataHome.appendingPathComponent("Trash", isDirectory: true)
            return try movePayload(from: source, to: root, restorePath: sourcePath)
        }

        var top = parent
        guard (try? platform.identity(at: top))?.volumeID == identity.volumeID else {
            throw TrashError.unavailable("无法安全回收挂载点")
        }
        while top.path != "/" {
            let ancestor = top.deletingLastPathComponent()
            guard ancestor.path != top.path, (try? platform.identity(at: ancestor))?.volumeID == identity.volumeID else { break }
            top = ancestor
        }
        let topPath = PlatformPath.fileSystemPath(for: top)
        let prefix = topPath.hasSuffix("/") ? topPath : topPath + "/"
        guard sourcePath.hasPrefix(prefix) else { throw TrashError.unavailable("无法确定卷内还原路径") }
        let relative = String(sourcePath.dropFirst(prefix.count))
        let shared = top.appendingPathComponent(".Trash", isDirectory: true)
        if aicl_posix_is_sticky_trash_dir(PlatformPath.fileSystemPath(for: shared)),
           let moved = try? movePayload(from: source, to: shared.appendingPathComponent(String(uid)), restorePath: relative) {
            return moved
        }
        return try movePayload(from: source, to: top.appendingPathComponent(".Trash-\(uid)"), restorePath: relative)
    }

    private static func movePayload(from source: URL, to root: URL, restorePath: String) throws -> TrashOutcome {
        let sourcePath = PlatformPath.fileSystemPath(for: source)
        let rootPath = PlatformPath.fileSystemPath(for: root)
        guard !sourcePath.hasPrefix(rootPath + "/"), !rootPath.hasPrefix(sourcePath + "/"), sourcePath != rootPath else {
            throw TrashError.unavailable("回收站目录及其祖先不可回收")
        }
        let name = UUID().uuidString
        let metadata = Data("[Trash Info]\nPath=\(encodePath(restorePath))\nDeletionDate=\(localTimestamp())\n".utf8)
        let error = metadata.withUnsafeBytes { bytes in
            aicl_linux_trash_move(sourcePath, rootPath, name, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard error == 0 else { throw TrashError.unavailable("无法安全移入回收站（错误码 \(error)）") }
        return .trashed(location: root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(name))
    }

    private static func encodePath(_ path: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        for byte in path.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 47, 95, 126:
                encoded.append(byte)
            default:
                encoded.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func localTimestamp() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = CoreStorageIO.zeroPad(parts.year ?? 1970, width: 4)
        let month = CoreStorageIO.zeroPad(parts.month ?? 1, width: 2)
        let day = CoreStorageIO.zeroPad(parts.day ?? 1, width: 2)
        let hour = CoreStorageIO.zeroPad(parts.hour ?? 0, width: 2)
        let minute = CoreStorageIO.zeroPad(parts.minute ?? 0, width: 2)
        let second = CoreStorageIO.zeroPad(parts.second ?? 0, width: 2)
        return "\(year)-\(month)-\(day)T\(hour):\(minute):\(second)"
    }
}
#endif
