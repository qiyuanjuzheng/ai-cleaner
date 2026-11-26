public struct DiskUsageSnapshot: Equatable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public var usedBytes: Int64 { totalBytes - availableBytes }
    public var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    public init?(totalBytes: Int64, availableBytes: Int64) {
        guard totalBytes > 0, (0...totalBytes).contains(availableBytes) else { return nil }
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}
