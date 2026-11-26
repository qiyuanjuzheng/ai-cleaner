import AICleanerCore
import Foundation
import XCTest

final class StartupDiskCapacityReaderTests: XCTestCase {
    func testDerivesUsageFromOneCapacityPair() throws {
        for (available, expectedUsed, expectedFraction) in [
            (Int64(250), Int64(750), 0.75),
            (1_000, 0, 0),
            (0, 1_000, 1)
        ] {
            let startupVolume = HostPlatformAdapter.shared.startupVolumeURL
            let reader = StartupDiskCapacityReader { url in
                XCTAssertEqual(PlatformPath.normalize(url), PlatformPath.normalize(startupVolume))
                return (total: 1_000, available: available)
            }
            let snapshot = try XCTUnwrap(reader.read())
            XCTAssertEqual(snapshot.totalBytes, 1_000)
            XCTAssertEqual(snapshot.availableBytes, available)
            XCTAssertEqual(snapshot.usedBytes, expectedUsed)
            XCTAssertEqual(snapshot.usedFraction, expectedFraction)
        }
    }

    func testRejectsUnreadableAndInvalidCapacities() {
        let unreadable = StartupDiskCapacityReader { _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertNil(unreadable.read())

        for (total, available): (Int64?, Int64?) in [
            (nil, 10), (10, nil), (0, 0), (-1, 0), (10, -1), (10, 11)
        ] {
            let reader = StartupDiskCapacityReader { _ in (total, available) }
            XCTAssertNil(reader.read())
        }
    }
}
