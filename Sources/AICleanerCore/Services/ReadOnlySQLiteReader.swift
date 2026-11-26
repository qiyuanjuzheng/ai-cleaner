import CSQLite
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 严格只读、零锁写、零副作用的本地 SQLite 元数据读取器（基于内嵌 `CSQLite` amalgamation，三端一致）。
/// - 始终使用 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` + `?mode=ro&immutable=1` 打开；
/// - 绝不创建 `-wal` / `-shm` 文件、绝不修改主库、绝不与运行中的客户端竞争写锁；
/// - 仅在常规非符号链接/非重解析点文件上执行受行数上限约束的 `SELECT` 查询，异常或表结构不匹配时优雅返回空结果。
enum ReadOnlySQLiteReader {
    static let defaultRowLimit = 10_000

    /// 打开只读不可变 SQLite 连接，执行只读回调后立即关闭。
    static func withReadOnlyDatabase<T>(
        at url: URL,
        platform: (any PlatformAdapter)? = nil,
        _ body: (OpaquePointer) -> T
    ) -> T? {
        let platform = platform ?? HostPlatformAdapter.shared
        // SQLite's NOFOLLOW applies to ancestors as well. Resolve existing parent aliases
        // (such as macOS /var) while keeping the final component eligible for that check.
        guard let parent = HostPlatformAdapter.canonicalURL(at: url.deletingLastPathComponent()) else { return nil }
        let source = parent.appendingPathComponent(url.lastPathComponent)
        guard (try? platform.identity(at: source))?.kind == .regular else { return nil }

        let uri = makeImmutableReadOnlyURI(for: PlatformPath.fileSystemPath(for: source))
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        let openResult = sqlite3_open_v2(uri, &db, flags, nil)
        guard openResult == SQLITE_OK, let handle = db else {
            if let db {
                sqlite3_close_v2(db)
            }
            return nil
        }
        defer {
            sqlite3_close_v2(handle)
        }

        return body(handle)
    }

    /// 执行受行数上限保护的只读 SQL 查询，按列索引返回每行的字符串值（NULL 列对应 `nil`）。
    static func queryStringRows(
        db: OpaquePointer,
        sql: String,
        columnCount: Int,
        rowLimit: Int = defaultRowLimit
    ) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return []
        }
        defer {
            sqlite3_finalize(stmt)
        }

        var rows: [[String?]] = []
        rows.reserveCapacity(min(rowLimit, 256))

        while rows.count < rowLimit {
            if Task.isCancelled { break }
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                var row = [String?](repeating: nil, count: columnCount)
                for col in 0..<columnCount {
                    if let cString = sqlite3_column_text(stmt, Int32(col)) {
                        row[col] = String(cString: cString)
                    }
                }
                rows.append(row)
            } else {
                // SQLITE_DONE 或任意损坏/并发变更错误，优雅终止返回已读取数据
                break
            }
        }
        return rows
    }

    /// 按 SQLite URI 规范构造只读不可变 URI（同时兼容 POSIX `/...` 与 Windows `C:\...` -> `file:///C:/...`）。
    static func makeImmutableReadOnlyURI(for rawPath: String) -> String {
        let normalized = PlatformPath.normalize(rawPath)
        var escaped = ""
        escaped.reserveCapacity(normalized.count + 16)
        for scalar in normalized.unicodeScalars {
            switch scalar {
            case "%": escaped.append("%25")
            case "?": escaped.append("%3F")
            case "#": escaped.append("%23")
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        if PlatformPath.hasWindowsDrivePrefix(normalized) {
            return "file:///\(escaped)?mode=ro&immutable=1"
        }
        return "file:\(escaped)?mode=ro&immutable=1"
    }
}
