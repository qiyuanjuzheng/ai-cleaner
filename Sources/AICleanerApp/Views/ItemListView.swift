import AICleanerCore
import SwiftUI

struct ItemListView: View {
    @Bindable var viewModel: CleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            filterControlBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            listContent
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            if let summary = viewModel.activeSummary {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.color(forAccentToken: summary.profile.accentToken).opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: summary.profile.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.color(forAccentToken: summary.profile.accentToken))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(summary.profile.name)
                            .font(.title2.weight(.semibold))
                        Text("\(summary.itemCount) 个条目")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(summary.profile.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(summary.profile.protectedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("当前分组可清理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CleanerFormatting.formatBytes(summary.totalSizeBytes))
                        .font(.title2.monospacedDigit().weight(.bold))
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("全部可清理项")
                            .font(.title2.weight(.semibold))
                        if let report = viewModel.report {
                            Text("检测到 \(report.detectedBuiltInClientsCount) 个 AI 客户端，共 \(report.totalItemCount) 项")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("覆盖各客户端聊天会话（支持按单条清理一次性对话）、缓存、日志与临时目录，自动排除登录态、API Key、核心配置、memory 与主数据库。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("合计可清理空间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CleanerFormatting.formatBytes(viewModel.report?.totalSizeBytes ?? 0))
                        .font(.title2.monospacedDigit().weight(.bold))
                }
            }
        }
    }

    // MARK: - Filter & Selection Controls

    private var filterControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索会话摘要、项目名、路径、客户端或类别…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.8)
                )
                .frame(minWidth: 240, maxWidth: .infinity)

                Picker("时间范围", selection: $viewModel.selectedAgeFilter) {
                    ForEach(ItemAgeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
                .help("按最后修改时间筛选较早的一次性会话或临时文件")

                Picker("排序", selection: $viewModel.sortOrder) {
                    ForEach(ItemSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 152)
            }

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    categoryFilterButton(
                        title: "全部",
                        count: viewModel.scopedItems.count,
                        category: nil
                    )
                    ForEach(ScanCategory.allCases) { category in
                        categoryFilterButton(
                            title: category.displayName,
                            count: viewModel.categoryCounts[category] ?? 0,
                            category: category
                        )
                    }
                }

                Spacer(minLength: 8)

                Text("显示 \(viewModel.filteredItems.count) 项（已选 \(viewModel.visibleSelectedCount)）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("全选") {
                    viewModel.selectAllVisible()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.filteredItems.isEmpty || viewModel.allVisibleSelected)

                Button("反选") {
                    viewModel.invertVisibleSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.filteredItems.isEmpty)

                Button("清空本页") {
                    viewModel.clearVisibleSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.visibleSelectedCount == 0)
            }
        }
    }

    private func categoryFilterButton(title: String, count: Int, category: ScanCategory?) -> some View {
        let isSelected = viewModel.selectedCategory == category
        let pillColor: Color = category.map { AppTheme.color(for: $0) } ?? .accentColor
        return Button {
            viewModel.selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .opacity(isSelected ? 0.9 : 0.7)
                }
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? pillColor.opacity(0.16) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? pillColor.opacity(0.55) : Color(nsColor: .separatorColor),
                        lineWidth: 0.8
                    )
            )
            .foregroundStyle(isSelected ? pillColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List Body

    @ViewBuilder
    private var listContent: some View {
        if viewModel.isScanning && viewModel.report == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在以只读模式扫描本机 AI 客户端目录…")
                    .font(.headline)
                Text("扫描过程绝不修改任何文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            if !viewModel.searchText.isEmpty || viewModel.selectedCategory != nil || viewModel.selectedAgeFilter != .all {
                ContentUnavailableView {
                    Label("未找到匹配的条目", systemImage: "magnifyingglass")
                } description: {
                    Text("请调整搜索关键词、时间范围或分类筛选条件。")
                } actions: {
                    Button("清除筛选条件") {
                        viewModel.searchText = ""
                        viewModel.selectedCategory = nil
                        viewModel.selectedAgeFilter = .all
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("当前目录很干净", systemImage: "checkmark.circle")
                } description: {
                    Text("该分组下暂无可清理的缓存、临时文件或日志。你也可以点击「添加目录」扫描其他自定义路径。")
                } actions: {
                    Button("重新扫描") {
                        viewModel.rescan()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredItems) { item in
                        ItemRowView(
                            item: item,
                            showClientBadge: viewModel.sidebarSelection == .allClients,
                            isSelected: viewModel.isSelected(item),
                            onToggle: { viewModel.toggleSelection(for: item) },
                            onRevealInFinder: { viewModel.revealInFinder(item) },
                            onCopyPath: { viewModel.copyPath(item) }
                        )
                        Divider()
                            .padding(.leading, 48)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
