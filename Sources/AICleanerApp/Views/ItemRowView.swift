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
                // 「不建议清理」项：未勾选时展示克制风险锁框，点击可弹出风险提醒强制勾选；已勾选则高亮警示勾选态
                Button(action: onToggle) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(
                                isSelected
                                    ? LinearGradient(
                                        colors: [recColor, recColor.opacity(0.84)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [recColor.opacity(isHovered ? 0.16 : 0.08), recColor.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                            )
                            .frame(width: 17, height: 17)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.white.opacity(0.32) : recColor.opacity(isHovered ? 0.65 : 0.35),
                                        lineWidth: 1.0
                                    )
                            )
                            .shadow(color: isSelected ? recColor.opacity(0.45) : .clear, radius: 4, y: 1)

                        Image(systemName: isSelected ? "checkmark" : "lock.fill")
                            .font(.system(size: isSelected ? 9.5 : 8.5, weight: .bold))
                            .foregroundStyle(isSelected ? Color.white : recColor.opacity(isHovered ? 0.95 : 0.72))
                    }
                    .scaleEffect(isSelected ? 1.0 : 0.96)
                    .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.66), value: isSelected)
                }
                .buttonStyle(.plain)
                .help(
                    isSelected
                        ? "取消勾选此「不建议清理」项"
                        : "不建议清理：点击可弹出风险提醒并强制勾选"
                )
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
                            .foregroundStyle(item.isCleanable || isSelected ? .primary : .secondary)
                            .lineLimit(1)

                        if !item.isCleanable && isSelected {
                            Text("高风险已选")
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(recColor.opacity(0.18)))
                                .foregroundStyle(recColor)
                        }

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
                onToggle()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(rowBackground)
        .help("\(item.safetyNote)\n路径：\(CleanerFormatting.abbreviatePath(item.url))")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                onToggle()
            } label: {
                if item.isCleanable {
                    Label(isSelected ? "取消勾选" : "勾选此项", systemImage: isSelected ? "checkmark.square" : "square")
                } else {
                    Label(
                        isSelected ? "取消勾选（不建议清理）" : "强制勾选（需风险确认）…",
                        systemImage: isSelected ? "checkmark.square" : "exclamationmark.shield"
                    )
                }
            }

            Divider()

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
