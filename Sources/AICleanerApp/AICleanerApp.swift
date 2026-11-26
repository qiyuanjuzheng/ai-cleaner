import AICleanerCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认使用原生浅色磨砂外观，避免启动瞬间出现暗色闪烁或 Liquid Glass 明暗割裂
        let savedRaw = UserDefaults.standard.string(forKey: "aiCleaner.appearanceMode.v2")
        let initialMode = savedRaw.flatMap(AppAppearanceMode.init(rawValue:)) ?? .light
        NSApplication.shared.appearance = initialMode.nsAppearance
        // 确保无论是通过 `swift run` 启动还是作为 `.app` 双击启动，都能作为常规前台应用展示窗口并响应快捷键
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AICleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: CleanerViewModel
    @State private var diskUsage = DiskUsageRefreshCoordinator()
    @StateObject private var updater = AppUpdater()

    init() {
        // 允许开发与验证阶段通过环境变量 AI_CLEANER_HOME（及可选 AI_CLEANER_SYSTEM_TMP / AI_CLEANER_USER_TMP）
        // 指定隔离沙箱目录，默认使用当前 macOS 用户主目录与系统临时目录
        let env = ProcessInfo.processInfo.environment
        if let overridePath = env["AI_CLEANER_HOME"],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let homeURL = URL(fileURLWithPath: overridePath, isDirectory: true).standardizedFileURL
            let systemTmpURL = env["AI_CLEANER_SYSTEM_TMP"]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            let userTmpURL = env["AI_CLEANER_USER_TMP"]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            let guardInstance = SafetyGuard(homeDirectory: homeURL)
            let sandboxConfigDir = homeURL.appendingPathComponent(".aicleaner-sandbox-config", isDirectory: true)
            let store = CustomDirectoryStore(
                storageURL: sandboxConfigDir.appendingPathComponent("custom-directories.json"),
                safetyGuard: guardInstance
            )
            let historyStore = CleanupHistoryStore(
                storageURL: sandboxConfigDir.appendingPathComponent("cleanup-history.json")
            )
            let excludedItemStore = ExcludedItemStore(
                storageURL: sandboxConfigDir.appendingPathComponent("excluded-items.json")
            )
            let engine = ScanEngine(
                homeDirectory: homeURL,
                safetyGuard: guardInstance,
                systemTempRoot: systemTmpURL,
                userTempRoot: userTmpURL
            )
            _viewModel = State(
                initialValue: CleanerViewModel(
                    homeDirectory: homeURL,
                    customDirectoryStore: store,
                    historyStore: historyStore,
                    excludedItemStore: excludedItemStore,
                    scanEngine: engine
                )
            )
        } else {
            _viewModel = State(initialValue: CleanerViewModel())
        }
    }

    var body: some Scene {
        WindowGroup("AI Cleaner") {
            ContentView(viewModel: viewModel, diskUsage: diskUsage)
                .frame(minWidth: 1020, minHeight: 660)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
                .task { updater.start(viewModel: viewModel) }
                .onChange(of: viewModel.isCleaning) { _, isCleaning in
                    if !isCleaning {
                        updater.resumeInstallationAfterCleanup()
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates || viewModel.isCleaning)
            }

            CommandMenu("扫描与清理") {
                Button(viewModel.hasScanResults ? "重新扫描" : "开始扫描") {
                    viewModel.startScan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button("返回扫描") {
                    viewModel.returnToIdleState()
                }
                .disabled((!viewModel.hasScanResults && !viewModel.isScanning) || viewModel.isCleaning)

                Button("添加自定义目录…") {
                    viewModel.showingAddCustomSheet = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button(CleanupHistoryCopy.openActionTitle) {
                    viewModel.sidebarSelection = .history
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("查看已排除条目") {
                    viewModel.sidebarSelection = .excluded
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button("勾选建议清理项") {
                    viewModel.selectRecommendedInScope()
                }
                .disabled(viewModel.scopedRecommendedItems.isEmpty)

                Button("全选可批量勾选项") {
                    viewModel.selectAllVisible()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(viewModel.filteredBulkSelectableItems.isEmpty)

                Button("反选可批量勾选项") {
                    viewModel.invertVisibleSelection()
                }
                .disabled(viewModel.filteredBulkSelectableItems.isEmpty)

                Button("清空全部选择") {
                    viewModel.clearAllSelection()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)
            }
        }
    }
}
