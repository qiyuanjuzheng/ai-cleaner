#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 高性能体积、日期与路径格式化工具（不依赖 `DateFormatter`、`String(format:)` 或 ICU，可在 `FoundationEssentials` 下全平台一致运行）。
public enum CleanerFormatting {
    /// 将字节数格式化为十进制 1000 进制可读大小（纯算术零 Formatter 分配，微秒级完成）。
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
            return kb >= 100 ? "\(formatFixed(kb, decimals: 0)) KB" : "\(formatFixed(kb, decimals: 1)) KB"
        }
        if clamped < 1_000_000_000 {
            let mb = value / 1_000_000.0
            return mb >= 100 ? "\(formatFixed(mb, decimals: 0)) MB" : "\(formatFixed(mb, decimals: 1)) MB"
        }
        if clamped < 1_000_000_000_000 {
            let gb = value / 1_000_000_000.0
            return "\(formatFixed(gb, decimals: 2)) GB"
        }
        let tb = value / 1_000_000_000_000.0
        return "\(formatFixed(tb, decimals: 2)) TB"
    }

    /// 将路径中的用户主目录缩写为 `~`，便于在界面中清晰浏览。
    public static func abbreviatePath(
        _ url: URL,
        homeDirectory: URL? = nil
    ) -> String {
        let fullPath = PlatformPath.normalize(url)
        guard let homeDirectory else {
            return fullPath
        }
        let homePath = PlatformPath.normalize(homeDirectory)
        if fullPath == homePath {
            return "~"
        }
        if fullPath.hasPrefix(homePath + "/") {
            return "~" + fullPath.dropFirst(homePath.count)
        }
        return fullPath
    }

    /// 格式化修改时间为简洁日期时间（`yyyy-MM-dd HH:mm`，本地时区，无 ICU 依赖）。
    public static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = localComponents(for: date, timeZone: timeZone)
        let y = CoreStorageIO.zeroPad(c.year ?? 1970, width: 4)
        let mo = CoreStorageIO.zeroPad(c.month ?? 1, width: 2)
        let d = CoreStorageIO.zeroPad(c.day ?? 1, width: 2)
        let h = CoreStorageIO.zeroPad(c.hour ?? 0, width: 2)
        let mi = CoreStorageIO.zeroPad(c.minute ?? 0, width: 2)
        return "\(y)-\(mo)-\(d) \(h):\(mi)"
    }

    /// 格式化扫描时间戳（`HH:mm:ss`，本地时区，无 ICU 依赖）。
    public static func formatTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = localComponents(for: date, timeZone: timeZone)
        let h = CoreStorageIO.zeroPad(c.hour ?? 0, width: 2)
        let mi = CoreStorageIO.zeroPad(c.minute ?? 0, width: 2)
        let s = CoreStorageIO.zeroPad(c.second ?? 0, width: 2)
        return "\(h):\(mi):\(s)"
    }

    /// 格式化趋势图坐标轴日期（`MM-dd`，本地时区，无 ICU 依赖）。
    public static func formatShortMonthDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = localComponents(for: date, timeZone: timeZone)
        let mo = CoreStorageIO.zeroPad(c.month ?? 1, width: 2)
        let d = CoreStorageIO.zeroPad(c.day ?? 1, width: 2)
        return "\(mo)-\(d)"
    }

    /// 格式化趋势图完整日期（`yyyy-MM-dd`，本地时区，无 ICU 依赖）。
    public static func formatDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = localComponents(for: date, timeZone: timeZone)
        let y = CoreStorageIO.zeroPad(c.year ?? 1970, width: 4)
        let mo = CoreStorageIO.zeroPad(c.month ?? 1, width: 2)
        let d = CoreStorageIO.zeroPad(c.day ?? 1, width: 2)
        return "\(y)-\(mo)-\(d)"
    }

    private static func localComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func formatFixed(_ value: Double, decimals: Int) -> String {
        let clamped = max(0, value)
        switch decimals {
        case 0:
            return String(Int64(clamped.rounded(.toNearestOrEven)))
        case 1:
            let scaled = Int64((clamped * 10.0).rounded(.toNearestOrEven))
            return "\(scaled / 10).\(scaled % 10)"
        default:
            let scaled = Int64((clamped * 100.0).rounded(.toNearestOrEven))
            return "\(scaled / 100).\(CoreStorageIO.zeroPad(Int(scaled % 100), width: 2))"
        }
    }
}
