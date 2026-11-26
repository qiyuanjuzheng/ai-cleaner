#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 清理条目分类，附带面向用户的安全说明，降低误删风险。
public enum ScanCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case sessions
    case cache
    case temporary
    case logs
    case custom
    case protectedData

    public var id: String { rawValue }

    /// 可供用户新建自定义目录时选择的类别（排除仅供受保护展示用的 protectedData）
    public static var userSelectableCases: [ScanCategory] {
        [.sessions, .cache, .temporary, .logs, .custom]
    }

    /// 界面展示的简体中文标签
    public var displayName: String {
        switch self {
        case .sessions:
            return "聊天会话"
        case .cache:
            return "缓存"
        case .temporary:
            return "临时文件"
        case .logs:
            return "日志"
        case .custom:
            return "自定义"
        case .protectedData:
            return "核心保护项"
        }
    }

    /// 对应 SF Symbols 图标名
    public var symbolName: String {
        switch self {
        case .sessions:
            return "bubble.left.and.bubble.right.fill"
        case .cache:
            return "internaldrive"
        case .temporary:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text"
        case .custom:
            return "folder.badge.gearshape"
        case .protectedData:
            return "lock.shield.fill"
        }
    }

    /// 面向用户的默认安全说明
    public var safetyDescription: String {
        switch self {
        case .sessions:
            return "AI 客户端保存的本地聊天会话记录（含一次性对话与任务会话）。移入废纸篓仅移除所选会话记录，不影响账号登录、配置与项目记忆（memory），随时可在废纸篓放回原处。"
        case .cache:
            return "应用运行或渲染缓存，移入废纸篓后下次启动会自动重建，不影响登录与配置。"
        case .temporary:
            return "会话快照、临时下载或更新包等一次性文件，可安全移入废纸篓并在需要时恢复。"
        case .logs:
            return "调试输出与崩溃转储日志，移入废纸篓不会影响客户端数据与设置。"
        case .custom:
            return "用户手动添加的自定义扫描目录，扫描与清理时仍会自动跳过凭据、配置与数据库文件。"
        case .protectedData:
            return "展示账号凭据、核心配置、已装插件、运行时组件、项目记忆或主数据库的占用大小及保护原因。"
        }
    }
}
