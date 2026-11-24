import AICleanerCore
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 268, max: 320)
        } detail: {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
                    Divider()
                }

                ItemListView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                BottomActionBar(viewModel: viewModel)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        }
        .sheet(isPresented: $viewModel.showingAddCustomSheet) {
            AddCustomDirectorySheet(viewModel: viewModel)
        }
        .task {
            viewModel.initialScanIfNeeded()
        }
    }
}
