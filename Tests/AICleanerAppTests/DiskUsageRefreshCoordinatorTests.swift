@testable import AICleanerApp
import AICleanerCore
import XCTest

@MainActor
final class DiskUsageRefreshCoordinatorTests: XCTestCase {
    func testPollsEveryThirtySecondsOnlyWhileForegroundAndVisible() async throws {
        let reads = ControlledDiskReads()
        let clock = ControlledPollClock()
        let coordinator = DiskUsageRefreshCoordinator(read: { await reads.read() }, sleep: { try await clock.sleep(for: $0) })
        defer { coordinator.setWindowActivity(isApplicationActive: false, isWindowVisible: false) }

        XCTAssertEqual(coordinator.state, .loading)

        let first = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 400))
        let second = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 450))
        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: true)
        try await completeRead(1, reads: reads, with: first)
        try await waitUntil { coordinator.state == .available(first) }
        try await waitUntil { await clock.requestedIntervals == [.seconds(30)] }
        await clock.advance()
        try await completeRead(2, reads: reads, with: second)
        try await waitUntil { coordinator.state == .available(second) }
        try await waitUntil { await clock.requestedIntervals.count == 2 }

        coordinator.setWindowActivity(isApplicationActive: false, isWindowVisible: true)
        try await waitUntil { await clock.pendingCount == 0 }
        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: true)
        try await completeRead(3, reads: reads, with: first)
        try await waitUntil { coordinator.state == .available(first) }
        try await waitUntil { await clock.requestedIntervals.count == 3 }

        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: false)
        try await waitUntil { await clock.pendingCount == 0 }
        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: true)
        try await completeRead(4, reads: reads, with: second)
        try await waitUntil { coordinator.state == .available(second) }
        try await waitUntil { await clock.requestedIntervals == Array(repeating: .seconds(30), count: 4) }
    }

    func testVisibilityAndActivationEachRefreshEvenWhenPollingIsPaused() async throws {
        let reads = ControlledDiskReads()
        let clock = ControlledPollClock()
        let coordinator = DiskUsageRefreshCoordinator(read: { await reads.read() }, sleep: { try await clock.sleep(for: $0) })
        let snapshot = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 400))

        coordinator.setWindowActivity(isApplicationActive: false, isWindowVisible: true)
        try await completeRead(1, reads: reads, with: snapshot)
        try await waitUntil { coordinator.state == .available(snapshot) }

        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: false)
        try await completeRead(2, reads: reads, with: nil)
        try await waitUntil { coordinator.state == .stale(snapshot) }
        let intervals = await clock.requestedIntervals
        XCTAssertTrue(intervals.isEmpty)
    }

    func testOverlappingPollsCoalesceAndCleanupQueuesOneFollowUpRead() async throws {
        let reads = ControlledDiskReads()
        let clock = ControlledPollClock()
        let coordinator = DiskUsageRefreshCoordinator(read: { await reads.read() }, sleep: { try await clock.sleep(for: $0) })
        defer { coordinator.setWindowActivity(isApplicationActive: false, isWindowVisible: false) }

        coordinator.setWindowActivity(isApplicationActive: true, isWindowVisible: true)
        try await waitUntil { await reads.started == 1 }
        try await waitUntil { await clock.pendingCount == 1 }
        await clock.advance()
        try await waitUntil { await clock.requestedIntervals.count == 2 }

        coordinator.refreshAfterCleanup()
        coordinator.refreshAfterCleanup()
        try await waitUntil { await reads.pendingCount == 1 }
        let first = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 400))
        let second = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 500))
        try await completeRead(1, reads: reads, with: first)
        try await waitUntil { coordinator.state == .available(first) }
        try await completeRead(2, reads: reads, with: second)
        try await waitUntil { coordinator.state == .available(second) }

        await clock.advance()
        try await completeRead(3, reads: reads, with: first)
        try await waitUntil { coordinator.state == .available(first) }
    }

    func testFailurePreservesLastSuccessfulReadingAndCanRecover() async throws {
        let reads = ControlledDiskReads()
        let coordinator = DiskUsageRefreshCoordinator(read: { await reads.read() })
        let first = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 400))
        let second = try XCTUnwrap(DiskUsageSnapshot(totalBytes: 1_000, availableBytes: 450))

        coordinator.refreshAfterCleanup()
        try await completeRead(1, reads: reads, with: nil)
        try await waitUntil { coordinator.state == .unavailable }

        coordinator.refreshAfterCleanup()
        try await completeRead(2, reads: reads, with: first)
        try await waitUntil { coordinator.state == .available(first) }

        coordinator.refreshAfterCleanup()
        try await completeRead(3, reads: reads, with: nil)
        try await waitUntil { coordinator.state == .stale(first) }

        coordinator.refreshAfterCleanup()
        try await completeRead(4, reads: reads, with: second)
        try await waitUntil { coordinator.state == .available(second) }
    }

    private func completeRead(_ number: Int, reads: ControlledDiskReads, with snapshot: DiskUsageSnapshot?) async throws {
        try await waitUntil { await reads.started == number }
        await reads.complete(with: snapshot)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the disk refresh")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor ControlledDiskReads {
    private(set) var started = 0
    private var pending: [CheckedContinuation<DiskUsageSnapshot?, Never>] = []
    var pendingCount: Int { pending.count }

    func read() async -> DiskUsageSnapshot? {
        started += 1
        return await withCheckedContinuation { pending.append($0) }
    }

    func complete(with snapshot: DiskUsageSnapshot?) {
        pending.removeFirst().resume(returning: snapshot)
    }
}

private actor ControlledPollClock {
    private(set) var requestedIntervals: [Duration] = []
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var pendingCount: Int { pending.count }

    func sleep(for interval: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            requestedIntervals.append(interval)
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        guard let id = pending.keys.first else { return }
        pending.removeValue(forKey: id)?.resume()
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
