import Foundation

/// 聊天会话元数据轻量预览（严格只读，仅读取文件头尾的有限字节）
public struct SessionPreview: Equatable, Sendable {
    public let projectName: String?
    public let promptSnippet: String?
    public let title: String?
    public let summary: String?

    public init(
        projectName: String? = nil,
        promptSnippet: String? = nil,
        title: String? = nil,
        summary: String? = nil
    ) {
        self.projectName = projectName
        self.promptSnippet = promptSnippet
        self.title = title
        self.summary = summary
    }
}

struct SessionItemMetadata {
    let displayName: String
    var title: String? = nil
    var projectName: String? = nil
}

/// 面向各 AI 客户端本地聊天会话的轻量只读摘要解析器：
/// - 从 Claude Code、Pi 的会话记录或 Codex 的本地索引读取会话标题。
/// - 会话记录头尾各读取最多 64 KB，每次扫描仅加载一次 Codex 标题索引。
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
        projectSessionMetadata(
            itemURL: itemURL,
            projectFolderName: projectFolderName,
            isDirectory: isDirectory,
            fileManager: fileManager
        ).displayName
    }

    func projectSessionMetadata(
        itemURL: URL,
        projectFolderName: String,
        isDirectory: Bool,
        fileManager: FileManager
    ) -> SessionItemMetadata {
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
        let title = isDirectory ? nil : preview.title
        let shortID = Self.extractShortIdentifier(from: itemURL.deletingPathExtension().lastPathComponent)

        if let snippet = preview.summary ?? preview.promptSnippet {
            let suffix = isDirectory ? "（子代理/产物）" : ""
            let displayName = [projectLabel, snippet + suffix].compactMap { $0 }.joined(separator: " · ")
            return SessionItemMetadata(displayName: displayName, title: title, projectName: projectLabel)
        }

        let fallbackKind = isDirectory ? "会话子代理/产物" : "会话记录"
        let displayName = [projectLabel, "\(fallbackKind) (\(shortID))"].compactMap { $0 }.joined(separator: " · ")
        return SessionItemMetadata(displayName: displayName, title: title, projectName: projectLabel)
    }

    /// 为 Codex `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl[.zst]` 构造可读展示名称
    public func buildRolloutSessionDisplayName(fileURL: URL) -> String {
        rolloutSessionMetadata(fileURL: fileURL, codexTitles: [:]).displayName
    }

    private func rolloutSessionMetadata(fileURL: URL, codexTitles: [UUID: String]) -> SessionItemMetadata {
        let fileName = fileURL.lastPathComponent
        let parsed = Self.parseCodexRolloutName(fileName)
        let isCompressed = fileName.lowercased().hasSuffix(".zst")
        let indexedTitle = parsed.id.flatMap { codexTitles[$0] }

        let preview: SessionPreview
        if !isCompressed && fileName.lowercased().hasSuffix(".jsonl") {
            preview = readJSONLPreview(from: fileURL)
        } else {
            preview = SessionPreview()
        }

        let name: String
        if let snippet = preview.summary ?? preview.promptSnippet {
            name = [preview.projectName ?? parsed.dateText, snippet].compactMap { $0 }.joined(separator: " · ")
        } else if let project = preview.projectName {
            name = "\(project) · \(parsed.dateText ?? "会话记录") (\(parsed.shortID))"
        } else if let date = parsed.dateText {
            let kind = isCompressed ? "压缩会话归档" : "会话记录"
            name = "\(date) · \(kind) (\(parsed.shortID))"
        } else {
            name = fileName
        }
        return SessionItemMetadata(displayName: name, title: indexedTitle ?? preview.title, projectName: preview.projectName)
    }

    /// 为扁平会话目录（一级子项）构造友好名称
    public func buildFlatSessionDisplayName(itemURL: URL, isDirectory: Bool) -> String {
        flatSessionMetadata(itemURL: itemURL, isDirectory: isDirectory).displayName
    }

    func flatSessionMetadata(
        itemURL: URL,
        isDirectory: Bool,
        codexTitles: [UUID: String] = [:]
    ) -> SessionItemMetadata {
        let name = itemURL.lastPathComponent
        if !isDirectory && name.hasPrefix("rollout-") {
            return rolloutSessionMetadata(fileURL: itemURL, codexTitles: codexTitles)
        }
        if !isDirectory && name.lowercased().hasSuffix(".jsonl") {
            let preview = readJSONLPreview(from: itemURL)
            var displayName = name
            if let snippet = preview.summary ?? preview.promptSnippet {
                displayName = [preview.projectName, snippet].compactMap { $0 }.joined(separator: " · ")
            }
            return SessionItemMetadata(displayName: displayName, title: preview.title, projectName: preview.projectName)
        }
        if isDirectory && (name.hasPrefix("Users-") || name.hasPrefix("-Users-")) {
            if let decoded = Self.decodeEncodedProjectName(name), !decoded.isEmpty {
                return SessionItemMetadata(displayName: "\(decoded)（项目会话/缓存）")
            }
        }
        return SessionItemMetadata(displayName: name)
    }

    /// 只读提取非压缩会话的标题、项目和首条提问。重命名记录通常追加在文件末尾。
    public func readJSONLPreview(from url: URL) -> SessionPreview {
        guard let handle = Self.openRegularFile(url) else {
            return SessionPreview()
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: Self.maxHeadBytes), !data.isEmpty else {
            return SessionPreview()
        }

        let headLines = String(decoding: data, as: UTF8.self).split { $0 == "\n" || $0 == "\r\n" }

        var foundProjectName: String?
        var foundSnippet: String?

        for rawLine in headLines.prefix(Self.maxLinesToScan) {
            guard let json = Self.parseJSON(Data(rawLine.utf8)) else { continue }

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

        var titleLines = headLines
        if data.count == Self.maxHeadBytes,
           let end = try? handle.seekToEnd(), end > UInt64(Self.maxHeadBytes),
           (try? handle.seek(toOffset: end - UInt64(Self.maxHeadBytes) - 1)) != nil,
           let tail = try? handle.read(upToCount: Self.maxHeadBytes + 1),
           let firstNewline = tail.firstIndex(of: 0x0A) {
            // 从边界前一字节开始读取，以区分恰好在行首和截断了首行的情况。
            titleLines += String(decoding: tail.suffix(from: firstNewline + 1), as: UTF8.self)
                .split { $0 == "\n" || $0 == "\r\n" }
        }

        var customTitle: String?
        var generatedTitle: String?
        var summary: String?
        for line in titleLines.reversed() {
            guard line.contains("\"customTitle\"") || line.contains("\"aiTitle\"")
                || line.contains("\"session_info\"") || line.contains("\"summary\""),
                let json = Self.parseJSON(Data(line.utf8)) else { continue }
            switch json["type"] as? String {
            case "custom-title":
                customTitle = customTitle ?? Self.nonBlank(json["customTitle"])
            case "session_info":
                customTitle = customTitle ?? Self.nonBlank(json["name"])
            case "ai-title":
                generatedTitle = generatedTitle ?? Self.nonBlank(json["aiTitle"])
            case "summary":
                summary = summary ?? Self.nonBlank(json["summary"])
            default:
                break
            }
        }
        return SessionPreview(
            projectName: foundProjectName,
            promptSnippet: foundSnippet,
            title: customTitle ?? generatedTitle,
            summary: summary
        )
    }

    // MARK: - Helpers

    func readCodexTitles(from url: URL) -> [UUID: String] {
        guard let handle = Self.openRegularFile(url) else { return [:] }
        defer { try? handle.close() }

        var titles: [UUID: String] = [:]
        var pendingLine = Data()
        func consumeLine() {
            guard pendingLine.count <= Self.maxHeadBytes, !pendingLine.isEmpty,
                  let entry = Self.parseJSON(pendingLine),
                  let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = entry["thread_name"] as? String else { return }
            titles[id] = Self.nonBlank(name)
        }

        // 索引为追加写入格式。按行读完整索引即可匹配较早的归档，同一 ID 以最后一条为准。
        while !Task.isCancelled,
              let chunk = try? handle.read(upToCount: Self.maxHeadBytes), !chunk.isEmpty {
            for (index, part) in chunk.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
                if index > 0 {
                    consumeLine()
                    pendingLine.removeAll(keepingCapacity: true)
                }
                if pendingLine.count <= Self.maxHeadBytes {
                    pendingLine.append(contentsOf: part)
                }
            }
        }
        consumeLine()
        return titles
    }

    private static func openRegularFile(_ url: URL) -> FileHandle? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return try? FileHandle(forReadingFrom: url)
    }

    private static func parseJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

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

    private static func parseCodexRolloutName(_ fileName: String) -> (dateText: String?, shortID: String, id: UUID?) {
        // rollout-2026-11-02T08-42-37-01a199b5-4a6f-7591-af48-46874459a62c.jsonl(.zst)
        var stem = fileName
        if stem.hasSuffix(".jsonl.zst") {
            stem = String(stem.dropLast(".jsonl.zst".count))
        } else if stem.hasSuffix(".jsonl") {
            stem = String(stem.dropLast(".jsonl".count))
        }

        guard stem.hasPrefix("rollout-") else {
            return (nil, extractShortIdentifier(from: stem), nil)
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
                return (dateText, shortID, UUID(uuidString: String(idTail)))
            }
        }

        return (nil, extractShortIdentifier(from: remainder), nil)
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
