#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 平台感知的纯 Swift 路径处理工具（不依赖 `NSString` 或 ICU，统一兼容 POSIX 与 Windows 路径语义）。
public enum PlatformPath {
    /// 判断原始路径是否为绝对路径（支持 POSIX `/...`、Windows `C:\...` / `C:/...` / `/C:/...`、UNC `\\server\share` 与长路径 `\\?\...`）。
    public static func isAbsolute(_ raw: String) -> Bool {
        if raw.isEmpty { return false }
        if raw.hasPrefix("/") || raw.hasPrefix("\\") {
            return true
        }
        return hasWindowsDrivePrefix(raw)
    }

    /// 提取 URL 对应的本地文件系统路径（Windows 上会返回标准 `C:\...` 形式而非 `/C:/...`，POSIX 上返回 `/...`）。
    public static func fileSystemPath(for url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return url.standardizedFileURL.path }
            return String(cString: ptr)
        }
    }

    /// 将 URL 规范化为统一比较路径（分隔符统一为 `/`，去除 `\\?\` 与尾部斜杠，解析 `.` 与 `..`）。
    public static func normalize(_ url: URL) -> String {
        normalize(fileSystemPath(for: url))
    }

    /// 将任意路径字符串规范化为统一比较路径。
    public static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        let windowsPath = raw.hasPrefix("\\") || hasWindowsDrivePrefix(raw)
            || (raw.hasPrefix("/") && hasWindowsDrivePrefix(String(raw.dropFirst())))
            || raw.hasPrefix("//?/")
        var s = windowsPath ? String(raw.map { $0 == "\\" ? "/" : $0 }) : raw

        // 剥离 Windows 扩展长度前缀 `\\?\` / `\\?\UNC\`
        if s.hasPrefix("//?/") {
            let afterPrefix = s.dropFirst(4)
            if afterPrefix.count >= 4 && afterPrefix.prefix(4).lowercased() == "unc/" {
                s = "//" + afterPrefix.dropFirst(4)
            } else {
                s = String(afterPrefix)
            }
        }

        // 处理 Swift URL.path 在 Windows 上常见的 `/C:/...` 形式
        if s.count >= 3, s.first == "/" {
            let withoutLeadingSlash = String(s.dropFirst())
            if hasWindowsDrivePrefix(withoutLeadingSlash) {
                s = withoutLeadingSlash
            }
        }

        // 识别根前缀
        let root: String
        let remainder: Substring
        if hasWindowsDrivePrefix(s) {
            let drive = s.prefix(1).uppercased()
            root = "\(drive):/"
            let afterColon = s.dropFirst(2)
            remainder = afterColon.first == "/" ? afterColon.dropFirst() : afterColon
        } else if s.hasPrefix("//") {
            let body = s.dropFirst(2)
            let parts = body.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                root = "//\(parts[0])/\(parts[1])"
                remainder = parts.dropFirst(2).joined(separator: "/")[...]
            } else {
                root = "//" + parts.joined(separator: "/")
                remainder = ""
            }
        } else if s.hasPrefix("/") {
            root = "/"
            remainder = s.dropFirst()
        } else {
            root = ""
            remainder = s[...]
        }

        var stack: [Substring] = []
        for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if root.isEmpty {
                    stack.append("..")
                }
                continue
            }
            stack.append(component)
        }

        if root.isEmpty {
            return stack.isEmpty ? "." : stack.joined(separator: "/")
        }
        if stack.isEmpty {
            return root
        }
        let joined = stack.joined(separator: "/")
        if root.hasSuffix("/") {
            return root + joined
        }
        return root + "/" + joined
    }

    /// 判断已规范化路径是否为根目录（`/`、`C:/` 或 UNC 共享根 `//server/share`）。
    public static func isRoot(_ normalizedPath: String) -> Bool {
        if normalizedPath.isEmpty || normalizedPath == "/" {
            return true
        }
        if normalizedPath.count == 3, hasWindowsDrivePrefix(normalizedPath), normalizedPath.hasSuffix(":/") {
            return true
        }
        if normalizedPath.hasPrefix("//") {
            let parts = normalizedPath.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
            return parts.count <= 2
        }
        return false
    }

    /// 返回已规范化路径的父目录；若已达根目录则返回 `nil`。
    public static func parent(of normalizedPath: String) -> String? {
        guard !isRoot(normalizedPath) else { return nil }
        guard let lastSlash = normalizedPath.lastIndex(of: "/") else { return nil }

        if normalizedPath.hasPrefix("/") && !normalizedPath.hasPrefix("//") {
            if lastSlash == normalizedPath.startIndex {
                return "/"
            }
            return String(normalizedPath[..<lastSlash])
        }

        if hasWindowsDrivePrefix(normalizedPath) {
            let rootEnd = normalizedPath.index(normalizedPath.startIndex, offsetBy: 2)
            if lastSlash == rootEnd {
                return String(normalizedPath.prefix(3))
            }
            return String(normalizedPath[..<lastSlash])
        }

        if normalizedPath.hasPrefix("//") {
            let candidate = String(normalizedPath[..<lastSlash])
            return candidate
        }

        return String(normalizedPath[..<lastSlash])
    }

    /// 自底向上遍历所有非根祖先目录（不含自身，也不含根 `/` 或 `C:/`）。
    public static func forEachAncestor(of normalizedPath: String, _ visit: (String) -> Void) {
        var current = normalizedPath
        while let parentPath = parent(of: current), !isRoot(parentPath) {
            visit(parentPath)
            current = parentPath
        }
    }

    /// 生成遵循平台大小写语义的比较键。
    public static func comparisonKey(_ path: String, caseInsensitive: Bool) -> String {
        let normalized = normalize(path)
        return caseInsensitive ? normalized.lowercased() : normalized
    }

    /// 判断 `path` 是否等于 `root` 或位于 `root` 子树下（严格按路径段边界匹配，不误匹配 `/a/dir2`）。
    public static func isEqualOrDescendant(_ path: String, of root: String, caseInsensitive: Bool) -> Bool {
        let p = comparisonKey(path, caseInsensitive: caseInsensitive)
        let r = comparisonKey(root, caseInsensitive: caseInsensitive)
        guard !p.isEmpty, !r.isEmpty else { return false }
        if p == r { return true }
        if r.hasSuffix("/") {
            return p.hasPrefix(r)
        }
        return p.hasPrefix(r + "/")
    }

    /// 提取末级文件名或目录名（不依赖 `NSString`）。
    public static func lastPathComponent(_ raw: String) -> String {
        let normalized = normalize(raw)
        if isRoot(normalized) { return normalized }
        guard let idx = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: idx)...])
    }

    /// 提取扩展名（不含 `.`，语义与 `(fileName as NSString).pathExtension` 一致）。
    public static func pathExtension(_ fileName: String) -> String {
        let name = lastPathComponent(fileName)
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return ""
        }
        let extStart = name.index(after: dotIndex)
        guard extStart < name.endIndex else { return "" }
        return String(name[extStart...])
    }

    /// 去除最后一个扩展名（语义与 `(fileName as NSString).deletingPathExtension` 一致）。
    public static func deletingPathExtension(_ fileName: String) -> String {
        let ext = pathExtension(fileName)
        guard !ext.isEmpty else { return fileName }
        return String(fileName.dropLast(ext.count + 1))
    }

    /// 将规范化路径字符串还原为本地文件 `URL`。
    public static func fileURL(fromNormalized normalizedPath: String, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: normalizedPath, isDirectory: isDirectory).standardizedFileURL
    }

    /// 规范化会话元数据中的工作区绝对路径（支持 POSIX `/...` 与 Windows `C:\...`）。
    /// 仅当路径在当前文件系统真实存在时解析符号链接，避免把非本机平台的路径错误改写。
    public static func normalizeWorkspacePath(
        _ raw: String?,
        platform: (any PlatformAdapter)? = nil
    ) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains("\0"), isAbsolute(raw) else {
            return nil
        }

        let lexicallyNormalized = normalize(raw)
        guard !isRoot(lexicallyNormalized) else {
            return nil
        }

        if let platform {
            let candidateURL = URL(fileURLWithPath: raw, isDirectory: true)
            if (try? platform.identity(at: candidateURL)) != nil {
                let resolved = platform.resolveSymlinks(at: candidateURL)
                let normalizedResolved = normalize(resolved)
                return isRoot(normalizedResolved) ? nil : normalizedResolved
            }
        } else {
            let candidateURL = URL(fileURLWithPath: raw, isDirectory: true)
            let fsPath = fileSystemPath(for: candidateURL)
            if FileManager.default.fileExists(atPath: fsPath) {
                let resolved = resolveSymlinksFallback(candidateURL)
                let normalizedResolved = normalize(resolved)
                return isRoot(normalizedResolved) ? nil : normalizedResolved
            }
        }

        return lexicallyNormalized
    }

    /// 跨平台符号链接解析：优先委托 `platform.resolveSymlinks(at:)`，未注入时通过 `FileManager.destinationOfSymbolicLink` 逐段解析（兼容 `FoundationEssentials`）。
    public static func resolveSymlinks(
        _ url: URL,
        platform: (any PlatformAdapter)? = nil
    ) -> URL {
        if let platform {
            return platform.resolveSymlinks(at: url)
        }
        return resolveSymlinksFallback(url)
    }

    /// 仅解析已存在的祖先目录符号链接，严格保留末级节点身份（不穿透末级符号链接）。
    public static func resolveExistingAncestors(
        for url: URL,
        platform: (any PlatformAdapter)? = nil
    ) -> URL {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let leaf = standardized.lastPathComponent
        guard !leaf.isEmpty, fileSystemPath(for: parent) != fileSystemPath(for: standardized) else {
            return standardized
        }
        var existing = parent
        var trailingComponents = [leaf]

        while !isRoot(normalize(existing)) {
            let exists = platform.map { (try? $0.identity(at: existing)) != nil }
                ?? FileManager.default.fileExists(atPath: fileSystemPath(for: existing))
            if exists { break }
            let ancestor = existing.deletingLastPathComponent()
            guard fileSystemPath(for: ancestor) != fileSystemPath(for: existing) else { return standardized }
            trailingComponents.append(existing.lastPathComponent)
            existing = ancestor
        }

        return trailingComponents.reversed().reduce(resolveSymlinks(existing, platform: platform)) {
            $0.appendingPathComponent($1)
        }
    }

    /// 逐段解析符号链接的纯 `FoundationEssentials` 实现（最多展开 40 层防止环路）。
    public static func resolveSymlinksFallback(_ url: URL) -> URL {
        #if !canImport(FoundationEssentials)
        return url.resolvingSymlinksInPath().standardizedFileURL
        #else
        let fm = FileManager.default
        var current = normalize(url)
        var hops = 0

        while hops < 40 {
            var expanded = false
            // 收集从根向下的路径段逐段检查符号链接
            let (root, components) = splitRootAndComponents(current)
            var prefix = root
            for (idx, component) in components.enumerated() {
                let nextPath = prefix.hasSuffix("/") ? "\(prefix)\(component)" : (prefix.isEmpty ? component : "\(prefix)/\(component)")
                if let target = try? fm.destinationOfSymbolicLink(atPath: nextPath) {
                    let resolvedTarget: String
                    if isAbsolute(target) {
                        resolvedTarget = normalize(target)
                    } else {
                        let base = prefix.isEmpty ? "." : prefix
                        resolvedTarget = normalize(base.hasSuffix("/") ? "\(base)\(target)" : "\(base)/\(target)")
                    }
                    let rest = components[(idx + 1)...]
                    if rest.isEmpty {
                        current = resolvedTarget
                    } else {
                        let tail = rest.joined(separator: "/")
                        current = normalize(resolvedTarget.hasSuffix("/") ? "\(resolvedTarget)\(tail)" : "\(resolvedTarget)/\(tail)")
                    }
                    hops += 1
                    expanded = true
                    break
                }
                prefix = nextPath
            }
            if !expanded {
                break
            }
        }
        return URL(fileURLWithPath: current).standardizedFileURL
        #endif
    }

    private static func splitRootAndComponents(_ normalized: String) -> (String, [String]) {
        if hasWindowsDrivePrefix(normalized) {
            let root = String(normalized.prefix(3))
            let tail = normalized.dropFirst(3).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return (root, tail)
        }
        if normalized.hasPrefix("//") {
            let parts = normalized.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2 {
                return ("//\(parts[0])/\(parts[1])", Array(parts.dropFirst(2)))
            }
            return (normalized, [])
        }
        if normalized.hasPrefix("/") {
            let tail = normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return ("/", tail)
        }
        return ("", normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    /// 判断路径是否为 Windows 盘符前缀（如 `C:/...`、`C:\...` 或 `C:`）。
    public static func hasWindowsDrivePrefix(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count >= 2 else { return false }
        let first = bytes[0]
        let isAlpha = (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
        guard isAlpha, bytes[1] == 58 /* ':' */ else { return false }
        if bytes.count == 2 { return true }
        return bytes[2] == 47 /* '/' */ || bytes[2] == 92 /* '\\' */
    }
}
