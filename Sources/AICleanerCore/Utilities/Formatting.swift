import Foundation

/// 体积与路径格式化工具
public enum CleanerFormatting {
    /// 将字节数格式化为符合 macOS 习惯的可读大小（如 `128.4 MB`、`0 KB`）
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// 将路径中的用户主目录缩写为 `~`，便于在界面中清晰浏览
    public static func abbreviatePath(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let fullPath = url.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        if fullPath == homePath {
            return "~"
        }
        if fullPath.hasPrefix(homePath + "/") {
            return "~" + fullPath.dropFirst(homePath.count)
        }
        return fullPath
    }

    /// 格式化修改时间为简洁中文日期时间
    public static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 格式化扫描时间戳（时:分:秒）
    public static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 格式化趋势图坐标轴日期（月-日）
    public static func formatShortMonthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    /// 格式化趋势图完整日期（年-月-日）
    public static func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
