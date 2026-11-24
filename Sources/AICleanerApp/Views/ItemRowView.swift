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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recColor = AppTheme.color(for: item.recommendation)

        HStack(alignment: .center, spacing: 11) {
            if item.isCleanable {
                AnimatedCheckbox(
                    isChecked: isSelected,
                    tint: recColor,
                    onToggle: onToggle
                )
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 17, height: 17)
                    .help("该条目已标记为「不建议清理」并锁定保护")
            }

            HStack(alignment: .center, spacing: 11) {
                // 克制单色柔和图标（去掉刺眼边框）
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(leadingSymbolColor.opacity(colorScheme == .dark ? 0.14 : 0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: leadingSymbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(leadingSymbolColor)
                }

                // 清爽 2 行信息区：无重复胶囊堆砌
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 7) {
                        Text(item.displayName)
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(item.isCleanable ? .primary : .secondary)
                            .lineLimit(1)

                        if showClientBadge {
                            Text(item.clientName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Text(item.safetyNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 10)

                // 悬停才丝滑显露的 Finder 定位按钮（固定占位，数字列永不抖动）
                Button(action: onRevealInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        )
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.92))
                .opacity(isHovered ? 1.0 : 0.0)
                .allowsHitTesting(isHovered)
                .help("在 Finder 中显示：\(CleanerFormatting.abbreviatePath(item.url))")

                // 右侧对齐体积列 + 极细 2.5pt 占比线
                VStack(alignment: .trailing, spacing: 3) {
                    Text(CleanerFormatting.formatBytes(item.sizeBytes))
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.isCleanable ? .primary : .secondary)

                    HStack(spacing: 6) {
                        Text(CleanerFormatting.formatDate(item.modifiedAt))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)

                        GeometryReader { proxy in
                            let clamped = max(0.06, min(1.0, relativeSizeFraction))
                            ZStack(alignment: .trailing) {
                                Capsule()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.07))
                                if item.sizeBytes > 0 {
                                    Capsule()
                                        .fill(recColor.opacity(item.isCleanable ? 0.78 : 0.38))
                                        .frame(width: proxy.size.width * clamped)
                                }
                            }
                        }
                        .frame(width: 44, height: 2.5)
                    }
                }
                .frame(minWidth: 112, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.isCleanable {
                    onToggle()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
        .background(rowBackground)
        .help("\(item.safetyNote)\n路径：\(CleanerFormatting.abbreviatePath(item.url))")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
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

            Button(action: onRevealInFinder) {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Button(action: onCopyPath) {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
        }
    }

    private var leadingSymbolName: String {
        if !item.isCleanable {
            return "lock.shield"
        }
        switch item.category {
        case .sessions:
            return item.isDirectory ? "bubble.left.and.bubble.right" : "text.bubble"
        case .cache:
            return "internaldrive"
        case .temporary:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text"
        case .custom:
            return item.isDirectory ? "folder" : "doc"
        case .protectedData:
            return "lock.shield"
        }
    }

    private var leadingSymbolColor: Color {
        if !item.isCleanable {
            return .secondary
        }
        return AppTheme.color(for: item.category)
    }

    private var rowBackground: Color {
        let recColor = AppTheme.color(for: item.recommendation)
        if isSelected {
            return recColor.opacity(colorScheme == .dark ? 0.10 : 0.08)
        }
        if isHovered {
            return Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035)
        }
        return Color.clear
    }
}
