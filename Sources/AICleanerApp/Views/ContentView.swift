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
                        reduceMotion ? nil : .easeInOut(duration: 0.35),
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

                    if viewModel.sidebarSelection == .history {
                        CleanupHistoryView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else {
                        ItemListView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    }
                }

                // 智能悬浮操作岛（仅在清理列表视图、勾选或清理完成时轻盈浮现）
                if viewModel.sidebarSelection != .history {
                    BottomActionBar(viewModel: viewModel)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
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
                .help("切换外观：浅色磨砂 / 跟随系统 / 深色极光（当前：\(viewModel.appearanceMode.rawValue)）")

                Button {
                    viewModel.showingAddCustomSheet = true
                } label: {
                    Label("添加自定义目录", systemImage: "folder.badge.plus")
                }
                .help("添加自定义扫描目录 (⌘⇧A)")

                Button {
                    viewModel.startScan()
                } label: {
                    ZStack {
                        Image(systemName: viewModel.hasScanResults ? "arrow.clockwise" : "play.fill")
                            .opacity(viewModel.isScanning ? 0 : 1)
                        if viewModel.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .disabled(viewModel.isScanning || viewModel.isCleaning)
                .help(viewModel.hasScanResults ? "重新执行只读扫描 (⌘R)" : "开始只读扫描 (⌘R)")
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
        .alert(
            "确认强制勾选「不建议清理」项？",
            isPresented: Binding(
                get: { viewModel.pendingRiskItemToSelect != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelRiskItemSelection()
                    }
                }
            ),
            presenting: viewModel.pendingRiskItemToSelect
        ) { item in
            Button("取消", role: .cancel) {
                viewModel.cancelRiskItemSelection()
            }
            Button("了解风险，仍然勾选", role: .destructive) {
                viewModel.confirmRiskItemSelection(item)
            }
        } message: { item in
            Text(
                "\(item.clientName) · \(item.displayName)（\(CleanerFormatting.formatBytes(item.sizeBytes))）\n\n风险提示：\(item.safetyNote)\n\n勾选后将在移入废纸篓前再次要求确认；清理仅移入系统废纸篓，随时可放回原处。"
            )
        }
        .onAppear {
            applyWindowAppearance(viewModel.appearanceMode)
        }
        .onChange(of: viewModel.appearanceMode) { _, newMode in
            applyWindowAppearance(newMode)
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
