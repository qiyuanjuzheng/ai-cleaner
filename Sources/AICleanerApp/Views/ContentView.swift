import AICleanerCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: CleanerViewModel
    @State private var hasVisitedHistory: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isHistory = viewModel.sidebarSelection == .history

        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 230, ideal: 252, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                AmbientAuroraBackdrop(accentColor: viewModel.activeAccentColor)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.20),
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
                        .background(AppTheme.glassElevatedFill(for: colorScheme))
                        .overlay(alignment: .bottom) { Divider() }
                    }

                    // 列表页与历史趋势页使用 ZStack 保活切换，彻底消除切页时重建 ScrollView 与 Swift Charts 的卡顿
                    ZStack {
                        ItemListView(viewModel: viewModel, isVisible: !isHistory)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(isHistory ? 0 : 1)
                            .allowsHitTesting(!isHistory)
                            .accessibilityHidden(isHistory)

                        if hasVisitedHistory || isHistory {
                            CleanupHistoryView(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(isHistory ? 1 : 0)
                                .allowsHitTesting(isHistory)
                                .accessibilityHidden(!isHistory)
                        }
                    }
                }

                // 智能悬浮操作岛（仅在清理列表视图、勾选或清理完成时轻盈浮现）
                if !isHistory {
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
                    viewModel.appearanceMode = viewModel.appearanceMode.next
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
            if viewModel.sidebarSelection == .history {
                hasVisitedHistory = true
            }
            applyWindowAppearance(viewModel.appearanceMode)
        }
        .onChange(of: viewModel.sidebarSelection) { _, newValue in
            if newValue == .history && !hasVisitedHistory {
                hasVisitedHistory = true
            }
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
