import AICleanerCore
import SwiftUI

struct ProjectSessionsView: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedSessionID: String?

    var body: some View {
        Group {
            if !viewModel.hasScanResults {
                if viewModel.isScanning {
                    ProgressView("正在扫描项目会话…")
                } else {
                    ContentUnavailableView {
                        Label("项目会话", systemImage: "folder.badge.clock")
                    } description: {
                        Text("扫描本机 AI 客户端后，即可按工作区浏览会话。")
                    } actions: {
                        Button("开始扫描", action: viewModel.startScan)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if viewModel.projectGroups.isEmpty {
                ContentUnavailableView("未找到项目会话", systemImage: "folder.badge.clock")
            } else {
                HStack(spacing: 0) {
                    projectList
                        .frame(width: 226)
                    Divider()
                    if let project = viewModel.selectedProjectID {
                        projectDetail(project)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedProjectID) { _, _ in expandedSessionID = nil }
        .onChange(of: viewModel.visibleProjectSessions.map(\.id)) { _, ids in
            if let expandedSessionID, !ids.contains(expandedSessionID) {
                self.expandedSessionID = nil
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("项目会话")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .padding(.horizontal, 14)
                .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(viewModel.projectGroups) { group in
                        projectRow(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 92)
            }
        }
        .background(AppTheme.glassCardFill(for: colorScheme))
    }

    private func projectRow(_ group: SessionProject) -> some View {
        let isSelected = viewModel.selectedProjectID == group.id
        let isProtected = viewModel.isProjectProtected(group.id)
        let path = group.id.workspacePath
        return Button {
            viewModel.selectedProjectID = group.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isProtected ? "lock.fill" : "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(group.id.name)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.sessions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isProtected ? "\(group.sessions.count) 个会话，已保护" : "\(group.sessions.count) 个会话")
        .help(path ?? group.id.name)
    }

    private func projectDetail(_ project: SessionProjectID) -> some View {
        let isProtected = viewModel.isProjectProtected(project)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        if let path = project.workspacePath {
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(path)
                        }
                    }
                    Spacer(minLength: 0)
                    if project.workspacePath != nil {
                        Button {
                            viewModel.setProjectProtection(!isProtected, for: project)
                        } label: {
                            Label(isProtected ? "解除保护" : "保护此项目",
                                  systemImage: isProtected ? "lock.open" : "lock")
                        }
                        .disabled(viewModel.isCleaning)
                    }
                }
                if isProtected {
                    Label("此项目的会话与专属关联文件已锁定", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Picker("会话时间", selection: $viewModel.projectAgeFilter) {
                        Text("全部").tag(ItemAgeFilter.all)
                        Text("90 天前").tag(ItemAgeFilter.olderThan90Days)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if let cutoff = viewModel.projectAgeCutoff {
                        Text("早于 \(cutoff.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(cutoff.formatted(date: .complete, time: .standard))
                    }
                    Spacer(minLength: 0)
                    Button("全选当前可清理会话", action: viewModel.selectAllVisible)
                        .disabled(viewModel.projectBulkSelectableSessions.isEmpty || viewModel.isCleaning || viewModel.isScanning)
                }
            }
            .padding(16)

            Divider()

            if viewModel.visibleProjectSessions.isEmpty {
                let title = viewModel.projectAgeCutoff == nil ? "此项目没有可显示的会话" : "此项目没有 90 天前的会话"
                ContentUnavailableView(title, systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.visibleProjectSessions) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 41)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 116)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionRow(_ session: CleanableItem) -> some View {
        let isExpanded = expandedSessionID == session.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                selectionControl(for: session)
                Button {
                    expandedSessionID = isExpanded ? nil : session.id
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .padding(.top, 4)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.preferredDisplayTitle)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(session.clientName)
                                Text(session.cleanupSnapshot?.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "修改时间未知")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(CleanerFormatting.formatBytes(session.sizeBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "收起会话详情" : "展开会话详情")
            }
            .padding(.horizontal, 6)

            if isExpanded {
                sessionDetails(session)
                    .padding(.leading, 43)
                    .padding(.trailing, 7)
                    .padding(.bottom, 12)
            }
        }
    }

    private func sessionDetails(_ session: CleanableItem) -> some View {
        let artifacts = viewModel.projectArtifacts(for: session)
        return VStack(alignment: .leading, spacing: 7) {
            Text(session.safetyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.abbreviatedPath(for: session))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !artifacts.isEmpty {
                Text("关联文件")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                ForEach(artifacts) { artifact in
                    HStack(alignment: .top, spacing: 8) {
                        selectionControl(for: artifact)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artifact.preferredDisplayTitle)
                                .font(.callout)
                            Text(artifact.safetyNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(CleanerFormatting.formatBytes(artifact.sizeBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionControl(for item: CleanableItem) -> some View {
        if let reason = item.hardProtectionReason {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .help(reason)
                .accessibilityLabel(reason)
        } else {
            Toggle(isOn: Binding(
                get: { viewModel.isSelected(item) },
                set: { _ in viewModel.toggleSelection(for: item) }
            )) {
                Text("勾选 \(item.preferredDisplayTitle)")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 18, height: 18)
            .disabled(viewModel.isCleaning || viewModel.isScanning)
            .help(item.safetyNote)
        }
    }
}
