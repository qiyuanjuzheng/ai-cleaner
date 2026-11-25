import AICleanerCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: CleanerViewModel
    @State private var hasVisitedHistory: Bool = false
    @State private var hasVisitedExcluded: Bool = false
    @State private var isWindowVisibleOnScreen: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isHistory = viewModel.sidebarSelection == .history
        let isExcluded = viewModel.sidebarSelection == .excluded
        let isListPage = viewModel.sidebarSelection.isListScope

        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 230, ideal: 252, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                WindowVisibilityObserver { isVisible in
                    if isWindowVisibleOnScreen != isVisible {
                        isWindowVisibleOnScreen = isVisible
                    }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

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

                    // 列表页、清理记录页与已排除页使用 ZStack 保活切换，彻底消除切页时重建 ScrollView 与 Swift Charts 的卡顿
                    ZStack {
                        ItemListView(viewModel: viewModel, isVisible: isListPage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(isListPage ? 1 : 0)
                            .allowsHitTesting(isListPage)
                            .accessibilityHidden(!isListPage)

                        if hasVisitedHistory || isHistory {
                            CleanupHistoryView(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(isHistory ? 1 : 0)
                                .allowsHitTesting(isHistory)
                                .accessibilityHidden(!isHistory)
                        }

                        if hasVisitedExcluded || isExcluded {
                            ExcludedItemsView(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(isExcluded ? 1 : 0)
                                .allowsHitTesting(isExcluded)
                                .accessibilityHidden(!isExcluded)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // 智能悬浮操作岛（与列表页一同保活，切去清理记录/已排除再返回时不重建、不重播旧提示动效）
                BottomActionBar(viewModel: viewModel, isVisible: isListPage)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .opacity(isListPage ? 1 : 0)
                    .allowsHitTesting(isListPage)
                    .accessibilityHidden(!isListPage)
            }
        }
        .environment(\.isWindowVisibleOnScreen, isWindowVisibleOnScreen)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.appearanceMode = viewModel.appearanceMode.next
                } label: {
                    Label(viewModel.appearanceMode.displayName, systemImage: viewModel.appearanceMode.symbolName)
                }
                .help("切换外观（当前：\(viewModel.appearanceMode.displayName)）")

                Button {
                    viewModel.showingAddCustomSheet = true
                } label: {
                    Label("添加自定义目录", systemImage: "folder.badge.plus")
                }
                .help("添加自定义目录 (⌘⇧A)")

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
                .accessibilityLabel(viewModel.hasScanResults ? "重新扫描" : "开始扫描")
                .help(viewModel.hasScanResults ? "重新扫描 (⌘R)" : "开始扫描 (⌘R)")
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
            "这项不建议清理，仍要勾选吗？",
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
            Button("仍要勾选", role: .destructive) {
                viewModel.confirmRiskItemSelection(item)
            }
        } message: { item in
            Text(
                "\(item.clientName) · \(item.displayName)（\(CleanerFormatting.formatBytes(item.sizeBytes))）\n\n\(item.safetyNote)\n\n移入废纸篓前还需再次确认。"
            )
        }
        .onAppear {
            if viewModel.sidebarSelection == .history {
                hasVisitedHistory = true
            }
            if viewModel.sidebarSelection == .excluded {
                hasVisitedExcluded = true
            }
            applyWindowAppearance(viewModel.appearanceMode)
        }
        .onChange(of: viewModel.sidebarSelection) { _, newValue in
            if newValue == .history && !hasVisitedHistory {
                hasVisitedHistory = true
            }
            if newValue == .excluded && !hasVisitedExcluded {
                hasVisitedExcluded = true
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
