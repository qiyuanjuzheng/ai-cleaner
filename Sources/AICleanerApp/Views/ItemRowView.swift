import AICleanerCore
import SwiftUI

enum RowCardPosition: Equatable, Hashable, Sendable {
    case single
    case first
    case middle
    case last

    var topRadius: CGFloat {
        (self == .single || self == .first) ? 13 : 0
    }

    var bottomRadius: CGFloat {
        (self == .single || self == .last) ? 13 : 0
    }

    var showsBottomDivider: Bool {
        self == .first || self == .middle
    }
}

/// 轻量容器：仅订阅自身 `isSelected`，将纯值快照传递给 `Equatable` 渲染视图，避免勾选单行导致邻近行重绘
struct ItemRowContainer: View {
    let row: ItemDisplayRow
    let viewModel: CleanerViewModel

    var body: some View {
        ItemRowView(
            row: row,
            isSelected: viewModel.isSelected(itemID: row.id),
            viewModel: viewModel
        )
        .equatable()
    }
}

struct ItemRowView: View, Equatable {
    let row: ItemDisplayRow
    let isSelected: Bool
    let viewModel: CleanerViewModel

    @State private var isHovered: Bool = false
    @State private var showsFullTitle = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: ItemRowView, rhs: ItemRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        let item = row.item
        let recColor = AppTheme.color(for: item.recommendation)
        let barWidth = max(2.5, min(44.0, 44.0 * CGFloat(row.relativeSizeFraction)))
        let position = row.position
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position.topRadius,
            bottomLeadingRadius: position.bottomRadius,
            bottomTrailingRadius: position.bottomRadius,
            topTrailingRadius: position.topRadius,
            style: .continuous
        )

        HStack(alignment: .center, spacing: 11) {
            if let reason = item.hardProtectionReason {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(recColor)
                    .frame(width: 17, height: 17)
                    .help(reason)
                    .accessibilityLabel("已锁定")
            } else if item.isCleanable {
                AnimatedCheckbox(
                    isChecked: isSelected,
                    tint: recColor
                ) {
                    viewModel.toggleSelection(for: item)
                }
            } else {
                // 「不建议清理」项：未勾选时展示克制风险锁框，点击弹出风险提醒确认；已勾选则高亮警示勾选态
                Button {
                    viewModel.toggleSelection(for: item)
                } label: {
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

                        Image(systemName: isSelected ? "checkmark" : "lock.fill")
                            .font(.system(size: isSelected ? 9.5 : 8.5, weight: .bold))
                            .foregroundStyle(isSelected ? Color.white : recColor.opacity(isHovered ? 0.95 : 0.72))
                    }
                    .scaleEffect(isSelected ? 1.0 : 0.96)
                    .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.66), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消勾选" : "勾选并确认风险")
            }

            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(leadingSymbolColor.opacity(colorScheme == .dark ? 0.14 : 0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: leadingSymbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(leadingSymbolColor)
                }

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 7) {
                        Text(row.title)
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

                        if row.showClientBadge {
                            Text(item.clientName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Text(row.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 10)

                if item.category == .sessions {
                    fullTitleButton
                }

                // 悬停才挂载 Finder 定位按钮（固定 26×24 占位，零隐藏按钮/tooltip 开销且数字列永不抖动）
                Group {
                    if isHovered {
                        Button {
                            viewModel.revealInFinder(item)
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示：\(row.abbreviatedPath)")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 26, height: 24)

                // 右侧对齐体积列 + 预格式化文本（零 Formatter 锁、零 GeometryReader）
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row.sizeText)
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.isCleanable ? .primary : .secondary)

                    HStack(spacing: 6) {
                        Text(row.dateText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)

                        ZStack(alignment: .trailing) {
                            Capsule()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.07))
                                .frame(width: 44, height: 2.5)
                            if item.sizeBytes > 0 {
                                Capsule()
                                    .fill(recColor.opacity(item.isCleanable ? 0.78 : 0.38))
                                    .frame(width: barWidth, height: 2.5)
                            }
                        }
                        .frame(width: 44, height: 2.5)
                    }
                }
                .frame(minWidth: 112, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.hardProtectionReason == nil {
                    viewModel.toggleSelection(for: item)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background {
            shape.fill(effectiveRowFill)
        }
        .overlay(alignment: .bottom) {
            if position.showsBottomDivider {
                Rectangle()
                    .fill(AppTheme.hairlineDivider(for: colorScheme))
                    .frame(height: 0.5)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
            }
        }
        .overlay {
            if position == .single {
                shape.strokeBorder(borderColor, lineWidth: 0.75)
            } else {
                // 仅绘制卡片外轮廓边线，相邻行之间绝不出现双层横线，且免除每行离屏 clipShape 遮罩开销
                SeamlessGroupBorder(position: position, cornerRadius: 13)
                    .stroke(borderColor, lineWidth: 0.75)
            }
        }
        .help(row.rowTooltip)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if item.hardProtectionReason == nil {
                Button {
                    viewModel.toggleSelection(for: item)
                } label: {
                    if item.isCleanable {
                        Label(isSelected ? "取消勾选" : "勾选此项", systemImage: isSelected ? "checkmark.square" : "square")
                    } else {
                        Label(
                            isSelected ? "取消勾选" : "勾选并确认风险…",
                            systemImage: isSelected ? "checkmark.square" : "exclamationmark.shield"
                        )
                    }
                }

                Divider()
            }

            Button {
                viewModel.excludeItem(item)
            } label: {
                Label("排除此条目（不再显示）", systemImage: "eye.slash")
            }

            Divider()

            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Button {
                viewModel.copyPath(item)
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
        }
    }

    private var fullTitleButton: some View {
        Button {
            showsFullTitle = true
        } label: {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看完整会话标题")
        .help("查看完整会话标题")
        .popover(isPresented: $showsFullTitle, arrowEdge: .bottom) {
            ScrollView {
                Text(row.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 340, height: 132)
            .padding(14)
        }
    }

    private var leadingSymbolName: String {
        let item = row.item
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
        if !row.item.isCleanable {
            return .secondary
        }
        return AppTheme.color(for: row.item.category)
    }

    private var effectiveRowFill: Color {
        if isSelected {
            switch row.item.recommendation {
            case .recommended:
                return colorScheme == .dark
                    ? Color(red: 0.085, green: 0.165, blue: 0.145)
                    : Color(red: 0.945, green: 0.988, blue: 0.968)
            case .reviewSuggested:
                return colorScheme == .dark
                    ? Color(red: 0.175, green: 0.135, blue: 0.095)
                    : Color(red: 0.996, green: 0.968, blue: 0.925)
            case .notRecommended:
                return colorScheme == .dark
                    ? Color(red: 0.175, green: 0.105, blue: 0.125)
                    : Color(red: 0.995, green: 0.945, blue: 0.952)
            }
        }
        if isHovered {
            return colorScheme == .dark
                ? Color(red: 0.135, green: 0.148, blue: 0.190).opacity(0.84)
                : Color(red: 0.965, green: 0.972, blue: 0.984)
        }
        return AppTheme.glassCardFill(for: colorScheme)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.075)
    }
}

/// 扁平虚拟化分组卡片的无缝外框路径：仅画外侧边缘，行与行交界处保持通透无双线
private struct SeamlessGroupBorder: Shape {
    let position: RowCardPosition
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        let inset = rect.insetBy(dx: 0.375, dy: 0.375)
        var path = Path()

        switch position {
        case .single:
            path.addRoundedRect(in: inset, cornerSize: CGSize(width: r, height: r), style: .continuous)
        case .first:
            path.move(to: CGPoint(x: inset.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: inset.minX + r, y: inset.minY),
                control: CGPoint(x: inset.minX, y: inset.minY)
            )
            path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.minY))
            path.addQuadCurve(
                to: CGPoint(x: inset.maxX, y: inset.minY + r),
                control: CGPoint(x: inset.maxX, y: inset.minY)
            )
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        case .middle:
            path.move(to: CGPoint(x: inset.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.minX, y: rect.maxY))
            path.move(to: CGPoint(x: inset.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        case .last:
            path.move(to: CGPoint(x: inset.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: inset.minX + r, y: inset.maxY),
                control: CGPoint(x: inset.minX, y: inset.maxY)
            )
            path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.maxY))
            path.addQuadCurve(
                to: CGPoint(x: inset.maxX, y: inset.maxY - r),
                control: CGPoint(x: inset.maxX, y: inset.maxY)
            )
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.minY))
        }
        return path
    }
}
