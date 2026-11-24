import Foundation

/// 聊天会话元数据轻量预览（严格只读，单文件仅读取前部有限字节，不修改任何文件）
public struct SessionPreview: Equatable, Sendable {
    public let projectName: String?
    public let promptSnippet: String?

    public init(projectName: String? = nil, promptSnippet: String? = nil) {
        self.projectName = projectName
        self.promptSnippet = promptSnippet
    }
}

/// 面向各 AI 客户端本地聊天会话的轻量只读摘要解析器：
/// - 支持 Claude Code、Codex（2025/2026 JSONL 与 `.jsonl.zst`）、Pi、Cursor 等会话命名与摘要；
/// - 单文件仅读取头部最多 64 KB，保证上千条会话扫描依然快速且零副作用。
public struct SessionMetadataReader: Sendable {
    private static let maxHeadBytes = 65_536
    private static let maxLinesToScan = 45
    private static let maxSnippetCharacters = 42

    public init() {}

    /// 为两层结构「项目目录 → 单条会话文件/伴随子目录」构造直观展示名称
    public func buildProjectSessionDisplayName(
        itemURL: URL,
        projectFolderName: String,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) -> String {
        let preview: SessionPreview
        if !isDirectory && itemURL.pathExtension.lowercased() == "jsonl" {
            preview = readJSONLPreview(from: itemURL)
        } else if isDirectory {
            let siblingJSONL = itemURL
                .deletingLastPathComponent()
                .appendingPathComponent(itemURL.lastPathComponent + ".jsonl")
            if fileManager.fileExists(atPath: siblingJSONL.path) {
                preview = readJSONLPreview(from: siblingJSONL)
            } else {
                preview = SessionPreview()
            }
        } else {
            preview = SessionPreview()
        }

        let projectLabel = preview.projectName ?? Self.decodeEncodedProjectName(projectFolderName)
        let shortID = Self.extractShortIdentifier(from: itemURL.deletingPathExtension().lastPathComponent)

        if let snippet = preview.promptSnippet {
            let suffix = isDirectory ? "（子代理/产物）" : ""
            if let projectLabel, !projectLabel.isEmpty {
                return "\(projectLabel) · \(snippet)\(suffix)"
            }
            return "\(snippet)\(suffix)"
        }

        let fallbackKind = isDirectory ? "会话子代理/产物" : "会话记录"
        if let projectLabel, !projectLabel.isEmpty {
            return "\(projectLabel) · \(fallbackKind) (\(shortID))"
        }
        return "\(fallbackKind) (\(shortID))"
    }

    /// 为 Codex `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl[.zst]` 构造可读展示名称
    public func buildRolloutSessionDisplayName(fileURL: URL) -> String {
        let fileName = fileURL.lastPathComponent
        let parsed = Self.parseCodexRolloutName(fileName)
        let isCompressed = fileName.lowercased().hasSuffix(".zst")

        if !isCompressed && fileName.lowercased().hasSuffix(".jsonl") {
            let preview = readJSONLPreview(from: fileURL)
            if let snippet = preview.promptSnippet {
                if let project = preview.projectName, !project.isEmpty {
                    return "\(project) · \(snippet)"
                }
                if let dateText = parsed.dateText {
                    return "\(dateText) · \(snippet)"
                }
                return snippet
            }
            if let project = preview.projectName, !project.isEmpty {
                if let dateText = parsed.dateText {
                    return "\(project) · \(dateText) (\(parsed.shortID))"
                }
                return "\(project) · 会话记录 (\(parsed.shortID))"
            }
        }

        let kindLabel = isCompressed ? "压缩会话归档" : "会话记录"
        if let dateText = parsed.dateText {
            return "\(dateText) · \(kindLabel) (\(parsed.shortID))"
        }
        return fileName
    }

    /// 为扁平会话目录（一级子项）构造友好名称
    public func buildFlatSessionDisplayName(itemURL: URL, isDirectory: Bool) -> String {
        let name = itemURL.lastPathComponent
        if name.hasPrefix("rollout-") {
            return buildRolloutSessionDisplayName(fileURL: itemURL)
        }
        if !isDirectory && name.lowercased().hasSuffix(".jsonl") {
            let preview = readJSONLPreview(from: itemURL)
            if let snippet = preview.promptSnippet {
                if let project = preview.projectName, !project.isEmpty {
                    return "\(project) · \(snippet)"
                }
                return snippet
            }
        }
        if isDirectory && (name.hasPrefix("Users-") || name.hasPrefix("-Users-")) {
            if let decoded = Self.decodeEncodedProjectName(name), !decoded.isEmpty {
                return "\(decoded)（项目会话/缓存）"
            }
        }
        return name
    }

    /// 严格只读：从非压缩 JSONL 会话文件头部提取 `cwd` 项目名与首条有意义的用户提问摘要
    public func readJSONLPreview(from url: URL) -> SessionPreview {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionPreview()
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: Self.maxHeadBytes), !data.isEmpty else {
            return SessionPreview()
        }

        guard let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self) as String?
        else {
            return SessionPreview()
        }

        var foundProjectName: String?
        var foundSnippet: String?
        var lineCount = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineCount += 1
            if lineCount > Self.maxLinesToScan { break }
            guard let lineData = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            // 1. 提取工作目录对应的项目名
            if foundProjectName == nil {
                let cwd = (json["cwd"] as? String)
                    ?? ((json["payload"] as? [String: Any])?["cwd"] as? String)
                if let cwd, !cwd.isEmpty {
                    let project = URL(fileURLWithPath: cwd).lastPathComponent
                    if !project.isEmpty && project != "/" {
                        foundProjectName = project
                    }
                }
            }

            // 2. 提取首条有意义的用户消息文本
            if foundSnippet == nil, let userText = Self.extractUserMessage(from: json) {
                if let cleaned = Self.sanitizePromptSnippet(userText) {
                    foundSnippet = cleaned
                }
            }

            if foundProjectName != nil && foundSnippet != nil {
                break
            }
        }

        return SessionPreview(projectName: foundProjectName, promptSnippet: foundSnippet)
    }

    // MARK: - Helpers

    /// 从常见编码后的项目目录名提取简短可读名称：
    /// 例如 `-Users-alice-workspace-my-app` / `--Users-alice-workspace-my-app--` -> `my-app`
    public static func decodeEncodedProjectName(_ encoded: String) -> String? {
        let trimmed = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return nil }

        // 常见路径编码前缀剥离：Users-<username>-(workspace|Documents|Projects|Desktop|github|multica-workspaces...)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }

        var tail = parts
        if tail.count >= 2 && tail[0] == "Users" {
            tail.removeFirst(2)
        }

        let leadingNoise: Set<String> = ["workspace", "workspaces", "projects", "Documents", "Desktop", "github", "side", "job", "temp"]
        while tail.count > 2, let first = tail.first, leadingNoise.contains(first) {
            tail.removeFirst()
        }

        // 针对 Multica 自动创建的 worktree/workdir 名称做友好提炼，突出项目与任务短号
        if let multicaIdx = tail.firstIndex(of: "multica"), multicaIdx + 1 < tail.count {
            let afterMultica = Array(tail.dropFirst(multicaIdx + 1))
            if let aiIdx = afterMultica.firstIndex(of: "ai"), aiIdx + 1 < afterMultica.count {
                tail = Array(afterMultica.dropFirst(aiIdx + 1))
            }
        }

        let joined = tail.isEmpty ? trimmed : tail.joined(separator: "-")
        if joined.count <= 34 {
            return joined
        }
        return String(joined.prefix(32)) + "…"
    }

    private static func extractShortIdentifier(from stem: String) -> String {
        if stem.count <= 8 {
            return stem
        }
        // 形如 `2026-10-23T00-23-05-234Z_01a16623-...` 取下划线后的短 UUID
        if let underscoreIdx = stem.lastIndex(of: "_") {
            let after = stem[stem.index(after: underscoreIdx)...]
            if after.count >= 8 {
                return String(after.prefix(8))
            }
        }
        return String(stem.prefix(8))
    }

    private static func parseCodexRolloutName(_ fileName: String) -> (dateText: String?, shortID: String) {
        // rollout-2026-11-02T08-42-37-01a199b5-4a6f-7591-af48-46874459a62c.jsonl(.zst)
        var stem = fileName
        if stem.hasSuffix(".jsonl.zst") {
            stem = String(stem.dropLast(".jsonl.zst".count))
        } else if stem.hasSuffix(".jsonl") {
            stem = String(stem.dropLast(".jsonl".count))
        }

        guard stem.hasPrefix("rollout-") else {
            return (nil, extractShortIdentifier(from: stem))
        }

        let remainder = String(stem.dropFirst("rollout-".count))
        // 前 19 位为 YYYY-MM-DDTHH-MM-SS
        if remainder.count >= 19 {
            let chars = Array(remainder)
            if chars[4] == "-" && chars[7] == "-" && chars[10] == "T" && chars[13] == "-" && chars[16] == "-" {
                let datePart = String(chars[0..<10])
                let hour = String(chars[11..<13])
                let minute = String(chars[14..<16])
                let dateText = "\(datePart) \(hour):\(minute)"

                let idStart = remainder.index(remainder.startIndex, offsetBy: min(20, remainder.count))
                let idTail = String(remainder[idStart...])
                let shortID = idTail.isEmpty ? extractShortIdentifier(from: stem) : String(idTail.prefix(8))
                return (dateText, shortID)
            }
        }

        return (nil, extractShortIdentifier(from: remainder))
    }

    private static func extractUserMessage(from json: [String: Any]) -> String? {
        let type = json["type"] as? String

        // 1. Claude Code: {"type":"user", "isSidechain":false, "message":{"role":"user","content":...}}
        if type == "user" {
            if (json["isSidechain"] as? Bool) == true { return nil }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] {
                return extractText(from: content)
            }
        }

        // 2. Pi: {"type":"message", "message":{"role":"user","content":...}}
        if type == "message" {
            if let message = json["message"] as? [String: Any],
               (message["role"] as? String) == "user",
               let content = message["content"] {
                return extractText(from: content)
            }
            // 3. Codex 2025: {"type":"message", "role":"user", "content":...}
            if (json["role"] as? String) == "user", let content = json["content"] {
                return extractText(from: content)
            }
        }

        // 4. Codex 2026: {"type":"response_item", "payload":{"type":"message","role":"user","content":...}}
        if type == "response_item",
           let payload = json["payload"] as? [String: Any],
           (payload["type"] as? String) == "message",
           (payload["role"] as? String) == "user",
           let content = payload["content"] {
            return extractText(from: content)
        }

        return nil
    }

    private static func extractText(from content: Any) -> String? {
        if let str = content as? String {
            return str
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                let blockType = (block["type"] as? String)?.lowercased() ?? "text"
                guard blockType == "text" || blockType == "input_text" else { continue }
                if let text = block["text"] as? String,
                   let candidate = sanitizePromptSnippet(text) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func sanitizePromptSnippet(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 跳过系统注入的上下文模板、指令块与本地命令包装
        let ignoredPrefixes = [
            "<environment_context>",
            "<INSTRUCTIONS>",
            "<system-reminder>",
            "<local-command-",
            "<command-name>",
            "# AGENTS.md",
            "<!-- BEGIN "
        ]
        for prefix in ignoredPrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }

        let collapsed = trimmed
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxSnippetCharacters {
            return collapsed
        }
        return String(collapsed.prefix(maxSnippetCharacters)) + "…"
    }
}
