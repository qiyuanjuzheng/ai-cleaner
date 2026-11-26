import Foundation

public struct StartupDiskCapacityReader: Sendable {
    public typealias CapacityQuery = @Sendable (URL) throws -> (total: Int64?, available: Int64?)

    private let readCapacities: CapacityQuery

    public init() {
        self.init { url in
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            return (values.volumeTotalCapacity.map(Int64.init), values.volumeAvailableCapacity.map(Int64.init))
        }
    }

    public init(readCapacities: @escaping CapacityQuery) {
        self.readCapacities = readCapacities
    }

    public func read() -> DiskUsageSnapshot? {
        // 每次新建 URL，避免重复读取时复用 Foundation 缓存的卷属性。
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        guard let capacities = try? readCapacities(dataVolume),
              let total = capacities.total,
              let available = capacities.available else { return nil }
        return DiskUsageSnapshot(totalBytes: total, availableBytes: available)
    }
}
