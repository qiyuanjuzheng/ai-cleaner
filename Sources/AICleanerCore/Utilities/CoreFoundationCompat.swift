#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Logging
#if canImport(Synchronization)
import Synchronization
#endif

/// Core 统一结构化日志入口（使用 `swift-log` 替代 Apple 专属 `os.Logger`）。
enum CoreLogger {
    static let shared = Logger(label: "com.qiyuanjuzheng.ai-cleaner.core")
}

/// 跨平台线程安全状态锁：
/// - Linux / Windows 与 macOS 15+ 直接使用标准库 `Synchronization.Mutex`；
/// - macOS 14 回退到 `NSLock` 以保持 `macOS(.v14)` 最低系统版本要求，彻底去除 `import os`。
public final class CoreLock<State: Sendable>: @unchecked Sendable {
    #if os(macOS)
    private let storage: AnyObject

    @available(macOS 15.0, *)
    private final class MutexBox: Sendable {
        let mutex: Mutex<State>
        init(_ initialState: State) {
            self.mutex = Mutex(initialState)
        }
    }

    private final class LegacyLockBox: @unchecked Sendable {
        let lock = NSLock()
        var state: State
        init(_ initialState: State) {
            self.state = initialState
        }
    }

    public init(initialState: State) {
        if #available(macOS 15.0, *) {
            self.storage = MutexBox(initialState)
        } else {
            self.storage = LegacyLockBox(initialState)
        }
    }

    public func withLock<R: Sendable>(_ body: (inout State) throws -> R) rethrows -> R {
        if #available(macOS 15.0, *), let box = storage as? MutexBox {
            return try box.mutex.withLock { value in
                try body(&value)
            }
        }
        let box = storage as! LegacyLockBox
        box.lock.lock()
        defer { box.lock.unlock() }
        return try body(&box.state)
    }
    #else
    private let mutex: Mutex<State>

    public init(initialState: State) {
        self.mutex = Mutex(initialState)
    }

    public func withLock<R: Sendable>(_ body: (inout State) throws -> R) rethrows -> R {
        try mutex.withLock { value in
            try body(&value)
        }
    }
    #endif
}

/// Objective-C 自动释放池的跨平台包装：仅在 macOS 上生效，Linux / Windows 直接执行。
@inline(__always)
func withCoreAutoreleasePool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if os(macOS)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

/// 不依赖 ICU 的确定性字符串排序（替代 `localizedCaseInsensitiveCompare` 与 `localizedStandardCompare`）。
public enum CoreTextCompare {
    /// 大小写无关字典序升序（不依赖 ICU / Locale，三端结果一致）。
    public static func caseInsensitiveAscending(_ lhs: String, _ rhs: String) -> Bool {
        let l = lhs.lowercased()
        let r = rhs.lowercased()
        if l != r {
            return l < r
        }
        return lhs < rhs
    }

    /// 自然序升序（替代 `localizedStandardCompare`：连续 ASCII 数字按数值比较，文本段按大小写无关比较）。
    public static func naturalAscending(_ lhs: String, _ rhs: String) -> Bool {
        let lScalars = Array(lhs.lowercased().unicodeScalars)
        let rScalars = Array(rhs.lowercased().unicodeScalars)
        var i = 0
        var j = 0

        while i < lScalars.count && j < rScalars.count {
            let lIsDigit = isASCIIDigit(lScalars[i])
            let rIsDigit = isASCIIDigit(rScalars[j])

            if lIsDigit && rIsDigit {
                let lStart = i
                while i < lScalars.count && isASCIIDigit(lScalars[i]) { i += 1 }
                let rStart = j
                while j < rScalars.count && isASCIIDigit(rScalars[j]) { j += 1 }

                // 跳过前导零比较有效数字位数与各位值
                var lz = lStart
                while lz < i && lScalars[lz] == "0" { lz += 1 }
                var rz = rStart
                while rz < j && rScalars[rz] == "0" { rz += 1 }

                let lSigLen = i - lz
                let rSigLen = j - rz
                if lSigLen != rSigLen {
                    return lSigLen < rSigLen
                }
                for offset in 0..<lSigLen {
                    let lc = lScalars[lz + offset]
                    let rc = rScalars[rz + offset]
                    if lc != rc {
                        return lc < rc
                    }
                }
                // 数值相等时，前导零较少者靠前
                let lTotalLen = i - lStart
                let rTotalLen = j - rStart
                if lTotalLen != rTotalLen {
                    return lTotalLen < rTotalLen
                }
            } else {
                if lScalars[i] != rScalars[j] {
                    return lScalars[i] < rScalars[j]
                }
                i += 1
                j += 1
            }
        }

        if lScalars.count != rScalars.count {
            return lScalars.count < rScalars.count
        }
        return lhs < rhs
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}

/// 纯 Swift 字符串与字节切片辅助方法（替代 `CharacterSet`、`trimmingCharacters(in:)`、`Data.range(of:)`）。
extension String {
    func trimmedWhitespaceAndNewlines() -> String {
        var start = startIndex
        var end = endIndex
        while start < end && self[start].isWhitespace {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            if self[prev].isWhitespace {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }

    func trimmedHorizontalWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end && (self[start] == " " || self[start] == "\t") {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            if self[prev] == " " || self[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }

    func trimmed(character: Character) -> String {
        var start = startIndex
        var end = endIndex
        while start < end && self[start] == character {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            if self[prev] == character {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }
}

extension Data {
    /// 纯 Swift 字节子序列查找（替代仅存在于完整 Foundation 的 `Data.range(of:)`）。
    func containsSubsequence(_ needle: Data) -> Bool {
        let needleCount = needle.count
        guard needleCount > 0 else { return true }
        guard count >= needleCount else { return false }
        return withUnsafeBytes { hayBuf in
            needle.withUnsafeBytes { needleBuf in
                let hay = hayBuf.bindMemory(to: UInt8.self)
                let pat = needleBuf.bindMemory(to: UInt8.self)
                let first = pat[0]
                let limit = hay.count - needleCount
                var i = 0
                while i <= limit {
                    if hay[i] == first {
                        var match = true
                        var j = 1
                        while j < needleCount {
                            if hay[i + j] != pat[j] {
                                match = false
                                break
                            }
                            j += 1
                        }
                        if match { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}

/// 替代 `JSONSerialization` 的通用只读 JSON 解码器（完全运行于 `FoundationEssentials`）。
enum CoreJSONValue: Decodable, Sendable {
    case object([String: CoreJSONValue])
    case array([CoreJSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([CoreJSONValue].self) {
            self = .array(arrayVal)
        } else if let dictVal = try? container.decode([String: CoreJSONValue].self) {
            self = .object(dictVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var asAny: Any {
        switch self {
        case let .object(dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = v.asAny
            }
            return out
        case let .array(arr):
            return arr.map(\.asAny)
        case let .string(str):
            return str
        case let .int(val):
            return val
        case let .double(val):
            return val
        case let .bool(val):
            return val
        case .null:
            return Optional<Any>.none as Any
        }
    }

    static func decodeObject(from data: Data) -> [String: Any]? {
        guard let value = try? JSONDecoder().decode(CoreJSONValue.self, from: data),
              case let .object(dict) = value else {
            return nil
        }
        var out: [String: Any] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            out[k] = v.asAny
        }
        return out
    }
}

/// 用户数据存储损坏保护（ADR 0001 第 7.3 节）：
/// JSON 解析失败时将原文件重命名为 `<name>.corrupt-<UTC 时间戳>.json` 保留下来，防止后续保存覆盖用户历史数据。
public enum CoreStorageIO {
    @discardableResult
    public static func quarantineCorruptFile(at storageURL: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let sourcePath = PlatformPath.fileSystemPath(for: storageURL)
        guard fm.fileExists(atPath: sourcePath) else { return nil }

        let parent = storageURL.deletingLastPathComponent()
        let fileName = storageURL.lastPathComponent
        let stem = PlatformPath.deletingPathExtension(fileName)
        let ext = PlatformPath.pathExtension(fileName)
        let stamp = formatCompactUTCTimestamp(now)
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        var candidate = parent.appendingPathComponent("\(stem).corrupt-\(stamp)\(suffix)")
        if fm.fileExists(atPath: PlatformPath.fileSystemPath(for: candidate)) {
            candidate = parent.appendingPathComponent("\(stem).corrupt-\(stamp)-\(UUID().uuidString.prefix(8))\(suffix)")
        }

        do {
            try fm.moveItem(at: storageURL, to: candidate)
            CoreLogger.shared.warning(
                "STORAGE_CORRUPT: 检测到损坏的数据文件，已备份保留",
                metadata: [
                    "source": .string(sourcePath),
                    "backup": .string(PlatformPath.fileSystemPath(for: candidate))
                ]
            )
            return candidate
        } catch {
            CoreLogger.shared.error(
                "STORAGE_CORRUPT: 无法备份损坏的数据文件",
                metadata: [
                    "source": .string(sourcePath),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }

    static func formatCompactUTCTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = zeroPad(c.year ?? 1970, width: 4)
        let mo = zeroPad(c.month ?? 1, width: 2)
        let d = zeroPad(c.day ?? 1, width: 2)
        let h = zeroPad(c.hour ?? 0, width: 2)
        let mi = zeroPad(c.minute ?? 0, width: 2)
        let s = zeroPad(c.second ?? 0, width: 2)
        return "\(y)\(mo)\(d)T\(h)\(mi)\(s)Z"
    }

    static func zeroPad(_ value: Int, width: Int) -> String {
        let clamped = max(0, value)
        let raw = String(clamped)
        if raw.count >= width { return raw }
        return String(repeating: "0", count: width - raw.count) + raw
    }
}
