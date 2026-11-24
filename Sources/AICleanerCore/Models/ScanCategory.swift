import Foundation

/// 清理条目分类，附带面向用户的安全说明，降低误删风险。
public enum ScanCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cache
    case temporary
    case logs
    case custom

    public var id: String { rawValue }

    /// 界面展示的简体中文标签
    public var displayName: String {
        switch self {
        case .cache:
            return "缓存"
        case .temporary:
            return "临时文件"
        case .logs:
            return "日志"
        case .custom:
            return "自定义"
        }
    }

    /// 对应 SF Symbols 图标名
    public var symbolName: String {
        switch self {
        case .cache:
            return "internaldrive"
        case .temporary:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text"
        case .custom:
            return "folder.badge.gearshape"
        }
    }

    /// 面向用户的默认安全说明
    public var safetyDescription: String {
        switch self {
        case .cache:
            return "应用运行或渲染缓存，移入废纸篓后下次启动会自动重建，不影响登录与配置。"
        case .temporary:
            return "会话快照、临时下载或更新包等一次性文件，可安全移入废纸篓并在需要时恢复。"
        case .logs:
            return "调试输出与崩溃转储日志，移入废纸篓不会影响客户端数据与设置。"
        case .custom:
            return "用户手动添加的自定义扫描目录，扫描与清理时仍会自动跳过凭据、配置与数据库文件。"
        }
    }
}
