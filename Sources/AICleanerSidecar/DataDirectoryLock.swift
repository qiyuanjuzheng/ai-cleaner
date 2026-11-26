import AICleanerCore
import CPlatformSupport
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class DataDirectoryLock {
    private let handle: UnsafeMutableRawPointer

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("core.lock")
        guard let handle = aicl_data_directory_lock(PlatformPath.fileSystemPath(for: url)) else {
            throw RPCError(-32020, "Cannot lock user data", name: "STORAGE_IO_ERROR")
        }
        self.handle = handle
    }

    deinit { aicl_data_directory_unlock(handle) }
}
