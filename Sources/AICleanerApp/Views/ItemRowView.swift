import AICleanerCore
import SwiftUI

struct ItemRowView: View {
    let item: CleanableItem
    let showClientBadge: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void

    @State private var isHovered: Bool = false
    @State private var showingSafetyInfo: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(
                isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggle() }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(item.isDirectory ? Color.accentColor.opacity(0.85) : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.system(.body, weight: .medium))
                            .lineLimit(1)

                        if item.displayName != item.fileName {
                            Text(item.fileName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        CategoryTagView(category: item.category)

                        if showClientBadge {
                            Text(item.clientName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingSafetyInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(item.safetyNote)
                        .popover(isPresented: $showingSafetyInfo, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundStyle(.green)
                                    Text("\(item.category.displayName) · 安全说明")
                                        .font(.headline)
                                }
                                Text(item.safetyNote)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(width: 300)
                        }
                    }

                    Text(CleanerFormatting.abbreviatePath(item.url))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.path)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(CleanerFormatting.formatBytes(item.sizeBytes))
                        .font(.system(.body, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        if item.isDirectory && item.fileCount > 0 {
                            Text("\(item.fileCount) 个文件")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(CleanerFormatting.formatDate(item.modifiedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 138, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggle()
            }

            Button {
                onRevealInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("在 Finder 中显示")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                onToggle()
            } label: {
                Label(isSelected ? "取消勾选" : "勾选此项", systemImage: isSelected ? "checkmark.square" : "square")
            }

            Divider()

            Button {
                onRevealInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Button {
                onCopyPath()
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.035)
        }
        return Color.clear
    }
}

private struct CategoryTagView: View {
    let category: ScanCategory

    var body: some View {
        let color = AppTheme.color(for: category)
        HStack(spacing: 3) {
            Image(systemName: category.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(category.displayName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.14))
        )
        .foregroundStyle(color)
    }
}
