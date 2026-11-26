@testable import AICleanerApp
import AICleanerCore
import SwiftUI
import XCTest

@MainActor
final class DiskUsageFooterViewTests: XCTestCase {
    func testFooterHeightAtMinimumSidebarWidthForAllStatesAndAppearances() throws {
        let largeDisk = try XCTUnwrap(DiskUsageSnapshot(totalBytes: .max, availableBytes: .max / 2))
        let states: [DiskUsageRefreshCoordinator.State] = [
            .loading, .unavailable, .available(largeDisk), .stale(largeDisk)
        ]

        for colorScheme in [ColorScheme.light, .dark] {
            for state in states {
                let renderer = ImageRenderer(
                    content: DiskUsageFooterView(state: state, lastScanTime: "08:11:27")
                        .environment(\.colorScheme, colorScheme)
                )
                renderer.proposedSize = ProposedViewSize(width: 230, height: nil)
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 230)
                XCTAssertEqual(image.height, 80)
            }
        }
    }
}
