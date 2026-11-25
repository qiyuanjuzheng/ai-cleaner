import Combine
import Foundation
import OSLog
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false

    private var updater: SPUUpdater?
    private weak var viewModel: CleanerViewModel?
    private var deferredInstall: (() -> Void)?

    func start(viewModel: CleanerViewModel) {
        let bundle = Bundle.main
        guard updater == nil,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") is String,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }

        self.viewModel = viewModel
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: AppUpdateUserDriver(hostBundle: bundle, delegate: nil),
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            Logger(subsystem: bundle.bundleIdentifier ?? "AICleaner", category: "AppUpdater")
                .error("启动更新服务失败。\(error.localizedDescription, privacy: .public)")
            return
        }

        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard viewModel?.isCleaning == true else { return false }
        deferredInstall = installHandler
        return true
    }

    func resumeInstallationAfterCleanup() {
        let install = deferredInstall
        deferredInstall = nil
        install?()
    }
}

/// 用户在发现新版时确认一次，下载与验证完成后继续安装。
private final class AppUpdateUserDriver: SPUStandardUserDriver {
    private var installWhenReady = false

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.installWhenReady = choice == .install
            reply(choice)
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installWhenReady else {
            super.showReady(toInstallAndRelaunch: reply)
            return
        }
        installWhenReady = false
        reply(.install)
    }

    override func dismissUpdateInstallation() {
        installWhenReady = false
        super.dismissUpdateInstallation()
    }
}
