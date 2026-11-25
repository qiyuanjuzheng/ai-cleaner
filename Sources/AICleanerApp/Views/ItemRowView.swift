import AICleanerCore
import AppKit

/// 分组无缝圆角卡片中的行位置，决定顶底圆角、外框边线与 0.5pt 内部分隔线
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

/// 清理列表单行的纯值视觉映射（图标名与语义色），供原生 AppKit 复用 Cell 直接调用
enum ItemRowVisuals {
    static func leadingSymbolName(for item: CleanableItem) -> String {
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

    static func leadingSymbolColor(for item: CleanableItem) -> NSColor {
        if !item.isCleanable {
            return .secondaryLabelColor
        }
        return AppTheme.nsColor(for: item.category)
    }
}
