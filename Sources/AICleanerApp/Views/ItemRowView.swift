import AICleanerCore
import SwiftUI

struct ItemRowView: View {
    let item: CleanableItem
    let showClientBadge: Bool
    let relativeSizeFraction: Double
    let isSelected: Bool
    let onToggle: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if item.isCleanable {
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
                .frame(width: 18)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.color(for: .notRecommended).opacity(0.75))
                    .frame(width: 18)
                    .help("该条目被标记为「不建议清理」，已锁定保护不可勾选")
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(leadingSymbolColor.opacity(0.13))
                        .frame(width: 30, height: 30)
                    Image(systemName: leadingSymbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(leadingSymbolColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(item.isCleanable ? .primary : .secondary)
                            .lineLimit(1)

                        RecommendationPillView(recommendation: item.recommendation)
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
                    }

                    // 直接展示一目了然的中文原因（为什么建议清理 / 按需清理 / 不建议清理）
                    Text(item.safetyNote)
                        .font(.caption)
                        .foregroundStyle(item.isCleanable ? .secondary : AppTheme.color(for: .notRecommended).opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.safetyNote)

                    Text(CleanerFormatting.abbreviatePath(item.url))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.path)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(CleanerFormatting.formatBytes(item.sizeBytes))
                        .font(.system(.body, weight: .semibold).monospacedDigit())
                        .foregroundStyle(item.isCleanable ? .primary : .secondary)

                    // 直观迷你体积占比条
                    GeometryReader { proxy in
                        let clamped = max(0.03, min(1.0, relativeSizeFraction))
                        ZStack(alignment: .trailing) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(AppTheme.color(for: item.recommendation).opacity(item.isCleanable ? 0.78 : 0.45))
                                .frame(width: item.sizeBytes > 0 ? proxy.size.width * clamped : 0)
                        }
                    }
                    .frame(width: 92, height: 4)

                    HStack(spacing: 6) {
                        if item.isDirectory && item.fileCount > 0 {
                            Text("\(item.fileCount) 文件")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(CleanerFormatting.formatDate(item.modifiedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 146, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.isCleanable {
                    onToggle()
                }
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
        .padding(.vertical, 9)
        .background(rowBackground)
        .opacity(item.isCleanable ? 1.0 : 0.88)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if item.isCleanable {
                Button {
                    onToggle()
                } label: {
                    Label(isSelected ? "取消勾选" : "勾选此项", systemImage: isSelected ? "checkmark.square" : "square")
                }

                Divider()
            }

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

    private var leadingSymbolName: String {
        if !item.isCleanable {
            return "lock.shield.fill"
        }
        switch item.category {
        case .sessions:
            return item.isDirectory ? "bubble.left.and.bubble.right.fill" : "text.bubble.fill"
        case .cache:
            return "internaldrive.fill"
        case .temporary:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text.fill"
        case .custom:
            return item.isDirectory ? "folder.fill" : "doc.fill"
        case .protectedData:
            return "lock.shield.fill"
        }
    }

    private var leadingSymbolColor: Color {
        if !item.isCleanable {
            return AppTheme.color(for: .notRecommended)
        }
        return AppTheme.color(for: item.category)
    }

    private var rowBackground: Color {
        if !item.isCleanable {
            return isHovered ? Color.primary.opacity(0.025) : Color.secondary.opacity(0.02)
        }
        if isSelected {
            return Color.accentColor.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.035)
        }
        return Color.clear
    }
}

private struct RecommendationPillView: View {
    let recommendation: CleanupRecommendation

    var body: some View {
        let color = AppTheme.color(for: recommendation)
        HStack(spacing: 3) {
            Image(systemName: recommendation.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text(recommendation.displayName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.14))
        )
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.32), lineWidth: 0.6)
        )
        .foregroundStyle(color)
    }
}

private struct CategoryTagView: View {
    let category: ScanCategory

    var body: some View {
        let color = AppTheme.color(for: category)
        Text(category.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.10))
            )
            .foregroundStyle(color)
    }
}
