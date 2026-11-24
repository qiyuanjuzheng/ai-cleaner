import AICleanerCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    init() {
        // 允许开发与验证阶段通过环境变量 AI_CLEANER_HOME 指定隔离主目录，默认使用当前 macOS 用户主目录
        if let overridePath = ProcessInfo.processInfo.environment["AI_CLEANER_HOME"],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let homeURL = URL(fileURLWithPath: overridePath, isDirectory: true).standardizedFileURL
            let guardInstance = SafetyGuard(homeDirectory: homeURL)
            let storageURL = homeURL
                .appendingPathComponent(".aicleaner-sandbox-config", isDirectory: true)
                .appendingPathComponent("custom-directories.json")
            let store = CustomDirectoryStore(storageURL: storageURL, safetyGuard: guardInstance)
            _viewModel = State(initialValue: CleanerViewModel(homeDirectory: homeURL, customDirectoryStore: store))
        } else {
            _viewModel = State(initialValue: CleanerViewModel())
        }
    }

    var body: some Scene {
        WindowGroup("AI Cleaner — AI 客户端空间清理") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("扫描与清理") {
                Button("重新扫描") {
                    viewModel.rescan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button("添加自定义目录…") {
                    viewModel.showingAddCustomSheet = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("一键勾选建议清理项") {
                    viewModel.selectRecommendedInScope()
                }
                .disabled(viewModel.scopedRecommendedItems.isEmpty)

                Button("全选当前可清理项") {
                    viewModel.selectAllVisible()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(viewModel.filteredCleanableItems.isEmpty)

                Button("反选当前可清理项") {
                    viewModel.invertVisibleSelection()
                }
                .disabled(viewModel.filteredCleanableItems.isEmpty)

                Button("清空全部选择") {
                    viewModel.clearAllSelection()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)
            }
        }
    }
}
