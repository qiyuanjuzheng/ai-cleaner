import Foundation
import os

/// 高性能体积、日期与路径格式化工具（避免在 SwiftUI 列表渲染期间反复分配 `Formatter` 实例造成主线程卡顿）
public enum CleanerFormatting {
    private static let cachedHomePath: String = {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }()

    private final class DateFormattersBox: @unchecked Sendable {
        let fullDate: DateFormatter
        let timeOnly: DateFormatter
        let shortMonthDay: DateFormatter
        let dayOnly: DateFormatter

        init() {
            let locale = Locale(identifier: "zh_CN")

            let full = DateFormatter()
            full.locale = locale
            full.dateFormat = "yyyy-MM-dd HH:mm"
            self.fullDate = full

            let time = DateFormatter()
            time.locale = locale
            time.dateFormat = "HH:mm:ss"
            self.timeOnly = time

            let short = DateFormatter()
            short.locale = locale
            short.dateFormat = "MM-dd"
            self.shortMonthDay = short

            let day = DateFormatter()
            day.locale = locale
            day.dateFormat = "yyyy-MM-dd"
            self.dayOnly = day
        }
    }

    private static let dateFormatters = OSAllocatedUnfairLock(initialState: DateFormattersBox())

    /// 将字节数格式化为符合 macOS（十进制 1000 进制）习惯的可读大小（纯算术零 Formatter 分配，微秒级完成）
    public static func formatBytes(_ bytes: Int64) -> String {
        let clamped = max(0, bytes)
        if clamped == 0 {
            return "0 B"
        }
        if clamped < 1_000 {
            return "\(clamped) B"
        }

        let value = Double(clamped)
        if clamped < 1_000_000 {
            let kb = value / 1_000.0
            return kb >= 100 ? String(format: "%.0f KB", kb) : String(format: "%.1f KB", kb)
        }
        if clamped < 1_000_000_000 {
            let mb = value / 1_000_000.0
            return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        }
        if clamped < 1_000_000_000_000 {
            let gb = value / 1_000_000_000.0
            return String(format: "%.2f GB", gb)
        }
        let tb = value / 1_000_000_000_000.0
        return String(format: "%.2f TB", tb)
    }

    /// 将路径中的用户主目录缩写为 `~`，便于在界面中清晰浏览
    public static func abbreviatePath(
        _ url: URL,
        homeDirectory: URL? = nil
    ) -> String {
        let fullPath = url.path
        let homePath = homeDirectory?.standardizedFileURL.path ?? cachedHomePath
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
        dateFormatters.withLock { $0.fullDate.string(from: date) }
    }

    /// 格式化扫描时间戳（时:分:秒）
    public static func formatTime(_ date: Date) -> String {
        dateFormatters.withLock { $0.timeOnly.string(from: date) }
    }

    /// 格式化趋势图坐标轴日期（月-日）
    public static func formatShortMonthDay(_ date: Date) -> String {
        dateFormatters.withLock { $0.shortMonthDay.string(from: date) }
    }

    /// 格式化趋势图完整日期（年-月-日）
    public static func formatDay(_ date: Date) -> String {
        dateFormatters.withLock { $0.dayOnly.string(from: date) }
    }
}
