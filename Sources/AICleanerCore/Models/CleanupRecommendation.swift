import Foundation

/// 条目清理建议等级：明确区分「建议清理」「按需清理」与「不建议清理（已锁定保护）」，让用户一眼辨别风险。
public enum CleanupRecommendation: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// 建议清理：缓存、日志、临时产物或较早的历史/归档会话，移入废纸篓可安全释放空间
    case recommended
    /// 按需清理：近期聊天会话、任务产物目录、自定义目录或可重建但耗时的索引，请确认无需保留后再清理
    case reviewSuggested
    /// 不建议清理：登录态、凭据、核心配置、项目记忆、主数据库、已装插件与运行时组件，仅透明展示体积并锁定保护
    case notRecommended

    public var id: String { rawValue }

    /// 界面展示的简体中文标签
    public var displayName: String {
        switch self {
        case .recommended:
            return "建议清理"
        case .reviewSuggested:
            return "按需清理"
        case .notRecommended:
            return "不建议清理"
        }
    }

    /// 简短行动提示
    public var shortGuidance: String {
        switch self {
        case .recommended:
            return "安全可重建或已过时，可放心移入废纸篓"
        case .reviewSuggested:
            return "确认是一次性会话或无用产物后再勾选"
        case .notRecommended:
            return "核心配置、记忆、插件或主库，已锁定保护不可删除"
        }
    }

    /// 对应 SF Symbols 图标名
    public var symbolName: String {
        switch self {
        case .recommended:
            return "checkmark.circle.fill"
        case .reviewSuggested:
            return "eye.circle.fill"
        case .notRecommended:
            return "lock.shield.fill"
        }
    }

    /// 是否允许被勾选并移入废纸篓
    public var isCleanable: Bool {
        self != .notRecommended
    }

    /// 分组展示排序优先级
    public var sortPriority: Int {
        switch self {
        case .recommended:
            return 0
        case .reviewSuggested:
            return 1
        case .notRecommended:
            return 2
        }
    }
}
