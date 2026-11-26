import AICleanerCore
import Observation

@MainActor
@Observable
final class DiskUsageRefreshCoordinator {
    enum State: Equatable {
        case loading
        case available(DiskUsageSnapshot)
        case stale(DiskUsageSnapshot)
        case unavailable

        var snapshot: DiskUsageSnapshot? {
            switch self {
            case let .available(snapshot), let .stale(snapshot): snapshot
            case .loading, .unavailable: nil
            }
        }
    }

    private(set) var state: State = .loading

    private let read: @Sendable () async -> DiskUsageSnapshot?
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var isApplicationActive = false
    @ObservationIgnored private var isWindowVisible = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var needsCleanupRead = false

    init(
        read: @escaping @Sendable () async -> DiskUsageSnapshot? = {
            await Task.detached(priority: .utility) { StartupDiskCapacityReader().read() }.value
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.read = read
        self.sleep = sleep
    }

    deinit {
        pollTask?.cancel()
    }

    func setWindowActivity(isApplicationActive: Bool, isWindowVisible: Bool) {
        let becameActive = isApplicationActive && !self.isApplicationActive
        let becameVisible = isWindowVisible && !self.isWindowVisible
        self.isApplicationActive = isApplicationActive
        self.isWindowVisible = isWindowVisible

        if becameActive || becameVisible {
            requestRead()
        }
        if isApplicationActive && isWindowVisible {
            startPollingIfNeeded()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refreshAfterCleanup() {
        if isReading {
            needsCleanupRead = true
        } else {
            requestRead()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(.seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.requestRead()
            }
        }
    }

    private func requestRead() {
        guard !isReading else { return }
        isReading = true
        Task { [weak self, read] in
            let snapshot = await read()
            self?.finishRead(snapshot)
        }
    }

    private func finishRead(_ snapshot: DiskUsageSnapshot?) {
        if let snapshot {
            state = .available(snapshot)
        } else if let previous = state.snapshot {
            state = .stale(previous)
        } else {
            state = .unavailable
        }

        isReading = false
        if needsCleanupRead {
            needsCleanupRead = false
            requestRead()
        }
    }
}
