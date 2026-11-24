import AICleanerCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 230, ideal: 252, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                AmbientAuroraBackdrop(accentColor: viewModel.activeAccentColor)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.65),
                        value: viewModel.sidebarSelection
                    )

                VStack(spacing: 0) {
                    if let errorMessage = viewModel.errorBannerMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.callout)
                            Spacer()
                            Button {
                                viewModel.dismissErrorBanner()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .bottom) { Divider() }
                    }

                    ItemListView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 智能悬浮操作岛（仅勾选或清理完成时轻盈浮现）
                BottomActionBar(viewModel: viewModel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                        viewModel.appearanceMode = viewModel.appearanceMode.next
                    }
                } label: {
                    Label(viewModel.appearanceMode.rawValue, systemImage: viewModel.appearanceMode.symbolName)
                }
                .help("切换外观：深色极光 / 浅色磨砂 / 跟随系统（当前：\(viewModel.appearanceMode.rawValue)）")

                Button {
                    viewModel.showingAddCustomSheet = true
                } label: {
                    Label("添加自定义目录", systemImage: "folder.badge.plus")
                }
                .help("添加自定义扫描目录 (⌘⇧A)")

                Button {
                    viewModel.rescan()
                } label: {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isScanning || viewModel.isCleaning)
                .help("重新执行只读扫描 (⌘R)")
            }
        }
        .sheet(isPresented: $viewModel.showingTrashConfirmation) {
            TrashConfirmationSheet(viewModel: viewModel)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
        }
        .sheet(isPresented: $viewModel.showingAddCustomSheet) {
            AddCustomDirectorySheet(viewModel: viewModel)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
        }
        .onAppear {
            applyWindowAppearance(viewModel.appearanceMode)
        }
        .onChange(of: viewModel.appearanceMode) { _, newMode in
            applyWindowAppearance(newMode)
        }
        .task {
            viewModel.initialScanIfNeeded()
        }
    }

    private func applyWindowAppearance(_ mode: AppAppearanceMode) {
        let appearance = mode.nsAppearance
        NSApplication.shared.appearance = appearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance
        }
    }
}
