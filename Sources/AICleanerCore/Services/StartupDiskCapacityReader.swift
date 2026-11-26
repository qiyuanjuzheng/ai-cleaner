#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct StartupDiskCapacityReader: Sendable {
    public typealias CapacityQuery = @Sendable (URL) throws -> (total: Int64?, available: Int64?)

    private let volumeURL: URL
    private let readCapacities: CapacityQuery

    public init(platform: any PlatformAdapter = HostPlatformAdapter.shared) {
        self.volumeURL = platform.startupVolumeURL
        self.readCapacities = { url in
            guard let cap = platform.diskCapacity(for: url) else {
                return (nil, nil)
            }
            return (cap.total, cap.available)
        }
    }

    public init(
        volumeURL: URL = HostPlatformAdapter.shared.startupVolumeURL,
        readCapacities: @escaping CapacityQuery
    ) {
        self.volumeURL = volumeURL
        self.readCapacities = readCapacities
    }

    public func read() -> DiskUsageSnapshot? {
        // 每次新建 URL，避免重复读取时复用缓存的卷属性。
        let targetVolume = URL(fileURLWithPath: PlatformPath.fileSystemPath(for: volumeURL), isDirectory: true)
        guard let capacities = try? readCapacities(targetVolume),
              let total = capacities.total,
              let available = capacities.available else { return nil }
        return DiskUsageSnapshot(totalBytes: total, availableBytes: available)
    }
}
