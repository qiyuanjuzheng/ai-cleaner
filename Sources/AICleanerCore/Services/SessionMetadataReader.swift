import Foundation

/// 聊天会话元数据轻量预览（严格只读，仅读取文件头尾或压缩流头部的有限字节）
public struct SessionPreview: Equatable, Sendable {
    public let projectName: String?
    public let promptSnippet: String?
    public let title: String?
    public let summary: String?
    public let sessionID: String?
    public let workspacePath: String?
    public let parentSessionID: String?

    public init(
        projectName: String? = nil,
        promptSnippet: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        sessionID: String? = nil,
        workspacePath: String? = nil,
        parentSessionID: String? = nil
    ) {
        self.projectName = projectName
        self.promptSnippet = promptSnippet
        self.title = title
        self.summary = summary
        self.sessionID = sessionID
        self.workspacePath = workspacePath
        self.parentSessionID = parentSessionID
    }
}

/// 同一扫描周期内聚合的会话元数据条目，用于向压缩归档、图片缓存、回滚快照、调试日志等关联产物反查标题
struct SessionRecord: Equatable, Sendable {
    var title: String?
    var projectName: String?
    var promptSnippet: String?
    var summary: String?
    var workspacePath: String?

    var bestTitle: String? {
        title ?? summary ?? promptSnippet
    }

    var isEmpty: Bool {
        title == nil && projectName == nil && promptSnippet == nil && summary == nil && workspacePath == nil
    }

    mutating func merge(fallback other: SessionRecord) {
        if title == nil { title = other.title }
        if projectName == nil { projectName = other.projectName }
        if promptSnippet == nil { promptSnippet = other.promptSnippet }
        if summary == nil { summary = other.summary }
        if workspacePath == nil { workspacePath = other.workspacePath }
    }
}

/// 单款 AI 客户端在一次扫描周期内维护的会话元数据索引（合并只读索引文件、只读数据库与本轮扫描解析出的会话）
struct ClientSessionIndex: Sendable {
    private(set) var bySessionID: [String: SessionRecord] = [:]
    private(set) var byWorkspacePath: [String: SessionRecord] = [:]
    private(set) var byWorkspaceFolderName: [String: SessionRecord] = [:]

    mutating func register(
        sessionID: String? = nil,
        workspacePath: String? = nil,
        folderName: String? = nil,
        record: SessionRecord,
        preferExisting: Bool = true
    ) {
        guard !record.isEmpty else { return }

        if let rawID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty {
            let key = rawID.lowercased()
            mergeEntry(key: key, into: &bySessionID, record: record, preferExisting: preferExisting)
        }

        if let rawPath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path.lowercased()
            mergeEntry(key: normalized, into: &byWorkspacePath, record: record, preferExisting: preferExisting)

            let last = URL(fileURLWithPath: rawPath).lastPathComponent.lowercased()
            if !last.isEmpty && last != "/" {
                mergeEntry(key: last, into: &byWorkspaceFolderName, record: record, preferExisting: preferExisting)
            }
        }

        if let rawFolder = folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFolder.isEmpty {
            mergeEntry(key: rawFolder.lowercased(), into: &byWorkspaceFolderName, record: record, preferExisting: preferExisting)
        }
    }

    func lookup(sessionID: String) -> SessionRecord? {
        let key = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return bySessionID[key]
    }

    func lookup(workspaceURL: URL) -> SessionRecord? {
        let normalized = workspaceURL.standardizedFileURL.path.lowercased()
        if let exact = byWorkspacePath[normalized] {
            return exact
        }
        let folder = workspaceURL.lastPathComponent.lowercased()
        return byWorkspaceFolderName[folder]
    }

    private func mergeEntry(
        key: String,
        into dict: inout [String: SessionRecord],
        record: SessionRecord,
        preferExisting: Bool
    ) {
        if var existing = dict[key] {
            if preferExisting {
                existing.merge(fallback: record)
                dict[key] = existing
            } else {
                var incoming = record
                incoming.merge(fallback: existing)
                dict[key] = incoming
            }
        } else {
            dict[key] = record
        }
    }
}

struct SessionItemMetadata {
    let displayName: String
    var title: String? = nil
    var projectName: String? = nil
    var safetyNoteOverride: String? = nil
    var resolvedRecord: SessionRecord? = nil
    var resolvedSessionID: String? = nil
}

/// 面向各 AI 客户端本地聊天会话与关联产物的轻量只读摘要解析器：
/// - 覆盖 JSONL（含 `.jsonl.zst` / `.jsonl.zstd` Zstandard 压缩归档）、JSON、YAML 以及严格只读不可变 SQLite 元数据索引；
/// - 每次扫描为客户端构建统一会话索引，使压缩会话归档、对话图片缓存、文件回滚快照、调试日志与子代理目录都能反查所属会话标题与项目名。
public struct SessionMetadataReader: Sendable {
    private static let headChunkBytes = 65_536
    private static let maxHeadBytes = 262_144
    private static let maxTailBytes = 65_536
    private static let maxCompressedReadBytes = 524_288
    private static let maxDecompressedBytes = 524_288
    private static let maxSmallJSONBytes = 131_072
    private static let maxLinesToScan = 80
    private static let maxSnippetCharacters = 42
    private static let maxSanitizedTitleCharacters = 120

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp", "tiff", "svg"
    ]

    public init() {}

    // MARK: - Client-Level Static Index Loading (Strictly Read-Only)

    /// 每次客户端扫描开始前加载一次只读元数据索引（JSONL / JSON / 只读不可变 SQLite），
    /// 绝不写入或锁写任何数据库，所有异常均静默降级。
    func loadClientSessionIndex(
        clientID: String,
        homeDirectory: URL,
        safetyGuard: SafetyGuard,
        fileManager: FileManager
    ) -> ClientSessionIndex {
        var index = ClientSessionIndex()

        switch clientID {
        case "codex":
            loadCodexIndex(into: &index, homeDirectory: homeDirectory, safetyGuard: safetyGuard, fileManager: fileManager)
        case "claude-code":
            loadClaudeCodeIndex(into: &index, homeDirectory: homeDirectory, safetyGuard: safetyGuard, fileManager: fileManager)
        case "workbuddy":
            loadWorkBuddyIndex(into: &index, homeDirectory: homeDirectory, fileManager: fileManager)
        case "gemini-antigravity":
            loadAntigravityIndex(into: &index, homeDirectory: homeDirectory)
        case "opencode":
            loadOpenCodeIndex(into: &index, homeDirectory: homeDirectory)
        case "zcode":
            loadZCodeIndex(into: &index, homeDirectory: homeDirectory)
        default:
            break
        }

        return index
    }

    // MARK: - Project Sessions (`projectSessions` mode)

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
        sessionIndex: ClientSessionIndex = ClientSessionIndex(),
        fileManager: FileManager
    ) -> SessionItemMetadata {
        let entryName = itemURL.lastPathComponent
        let lowerName = entryName.lowercased()
        let isRollbackLog = !isDirectory && lowerName.hasSuffix(".file-rollback.ndjson")
        let sessionID = Self.extractSessionIdentifier(from: entryName, isDirectory: isDirectory)

        var preview = SessionPreview()
        var isPrimarySessionDir = false

        if !isDirectory && Self.isJSONLOrCompressedJSONL(lowerName) {
            preview = readJSONLPreview(from: itemURL)
        } else if isRollbackLog {
            let siblingJSONL = itemURL
                .deletingLastPathComponent()
                .appendingPathComponent(String(entryName.dropLast(".file-rollback.ndjson".count)) + ".jsonl")
            if fileManager.fileExists(atPath: siblingJSONL.path) {
                preview = readJSONLPreview(from: siblingJSONL)
            }
        } else if isDirectory {
            // 1. 优先检查目录内部是否直接存放主会话归档（如 DeepSeek Harness 的 `session-<uuid>/session.v4.jsonl.zstd`）
            if let embeddedSessionFile = Self.findEmbeddedSessionFile(in: itemURL, fileManager: fileManager) {
                preview = readJSONLPreview(from: embeddedSessionFile)
                isPrimarySessionDir = true
            } else {
                // 2. 否则作为伴随子代理/工具产物目录，查找同级 `<uuid>.jsonl`
                let siblingJSONL = itemURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(entryName + ".jsonl")
                if fileManager.fileExists(atPath: siblingJSONL.path) {
                    preview = readJSONLPreview(from: siblingJSONL)
                }
            }
        }

        let effectiveSessionID = preview.sessionID ?? sessionID
        let indexed = effectiveSessionID.flatMap { sessionIndex.lookup(sessionID: $0) }

        let projectLabel = preview.projectName
            ?? indexed?.projectName
            ?? Self.decodeEncodedProjectName(projectFolderName)

        let rawTitle = preview.title ?? indexed?.title
        let rawSummary = preview.summary ?? indexed?.summary
        let rawPrompt = preview.promptSnippet ?? indexed?.promptSnippet
        let bestSnippet = rawSummary ?? rawPrompt

        var record = SessionRecord(
            title: rawTitle,
            projectName: projectLabel,
            promptSnippet: rawPrompt,
            summary: rawSummary,
            workspacePath: preview.workspacePath ?? indexed?.workspacePath
        )
        if let indexed {
            record.merge(fallback: indexed)
        }

        let shortID = Self.extractShortIdentifier(from: effectiveSessionID ?? itemURL.deletingPathExtension().lastPathComponent)

        if isRollbackLog {
            let suffix = "（文件回滚记录）"
            if let title = rawTitle {
                let displayName = [projectLabel, title + suffix].compactMap { $0 }.joined(separator: " · ")
                return SessionItemMetadata(
                    displayName: displayName,
                    title: title + suffix,
                    projectName: projectLabel,
                    resolvedRecord: record,
                    resolvedSessionID: effectiveSessionID
                )
            }
            if let snippet = bestSnippet {
                let displayName = [projectLabel, snippet + suffix].compactMap { $0 }.joined(separator: " · ")
                return SessionItemMetadata(
                    displayName: displayName,
                    title: nil,
                    projectName: projectLabel,
                    resolvedRecord: record,
                    resolvedSessionID: effectiveSessionID
                )
            }
            let displayName = [projectLabel, "文件回滚记录 (\(shortID))"].compactMap { $0 }.joined(separator: " · ")
            return SessionItemMetadata(
                displayName: displayName,
                title: nil,
                projectName: projectLabel,
                resolvedRecord: record,
                resolvedSessionID: effectiveSessionID
            )
        }

        let isCompanionDir = isDirectory && !isPrimarySessionDir
        if isCompanionDir {
            let suffix = "（子代理/产物）"
            if let title = rawTitle {
                let displayName = [projectLabel, title + suffix].compactMap { $0 }.joined(separator: " · ")
                return SessionItemMetadata(
                    displayName: displayName,
                    title: title + suffix,
                    projectName: projectLabel,
                    resolvedRecord: record,
                    resolvedSessionID: effectiveSessionID
                )
            }
            if let snippet = bestSnippet {
                let displayName = [projectLabel, snippet + suffix].compactMap { $0 }.joined(separator: " · ")
                return SessionItemMetadata(
                    displayName: displayName,
                    title: nil,
                    projectName: projectLabel,
                    resolvedRecord: record,
                    resolvedSessionID: effectiveSessionID
                )
            }
            let displayName = [projectLabel, "会话子代理/产物 (\(shortID))"].compactMap { $0 }.joined(separator: " · ")
            return SessionItemMetadata(
                displayName: displayName,
                title: nil,
                projectName: projectLabel,
                resolvedRecord: record,
                resolvedSessionID: effectiveSessionID
            )
        }

        // 主会话文件或主会话目录（如 DeepSeek Harness）
        if let snippet = bestSnippet {
            let displayName = [projectLabel, snippet].compactMap { $0 }.joined(separator: " · ")
            return SessionItemMetadata(
                displayName: displayName,
                title: rawTitle,
                projectName: projectLabel,
                resolvedRecord: record,
                resolvedSessionID: effectiveSessionID
            )
        }

        let displayName = [projectLabel, "会话记录 (\(shortID))"].compactMap { $0 }.joined(separator: " · ")
        return SessionItemMetadata(
            displayName: displayName,
            title: rawTitle,
            projectName: projectLabel,
            resolvedRecord: record,
            resolvedSessionID: effectiveSessionID
        )
    }

    // MARK: - Codex Rollout & Flat Sessions

    /// 为 Codex `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl[.zst]` 构造可读展示名称
    public func buildRolloutSessionDisplayName(fileURL: URL) -> String {
        rolloutSessionMetadata(fileURL: fileURL, sessionIndex: ClientSessionIndex()).displayName
    }

    private func rolloutSessionMetadata(
        fileURL: URL,
        sessionIndex: ClientSessionIndex
    ) -> SessionItemMetadata {
        let fileName = fileURL.lastPathComponent
        let lowerName = fileName.lowercased()
        let parsed = Self.parseCodexRolloutName(fileName)
        let isCompressed = lowerName.hasSuffix(".zst") || lowerName.hasSuffix(".zstd")
        let sessionIDString = parsed.id?.uuidString.lowercased()
        let indexed = sessionIDString.flatMap { sessionIndex.lookup(sessionID: $0) }

        let preview: SessionPreview
        if isCompressed && indexed?.title != nil && indexed?.projectName != nil {
            // 静态索引（session_index.jsonl / state_*.sqlite）已同时命中标题与项目名时跳过压缩块解压，避免扫描阻塞
            preview = SessionPreview()
        } else if Self.isJSONLOrCompressedJSONL(lowerName) {
            preview = readJSONLPreview(from: fileURL)
        } else {
            preview = SessionPreview()
        }

        let parentIndexed = preview.parentSessionID.flatMap { sessionIndex.lookup(sessionID: $0) }
        let inheritedSubagentTitle = parentIndexed?.bestTitle.map { Self.formatSubagentTitle($0) }

        let resolvedProject = preview.projectName ?? indexed?.projectName ?? parentIndexed?.projectName
        let resolvedTitle = indexed?.title ?? preview.title ?? inheritedSubagentTitle
        let resolvedSnippet = preview.summary ?? preview.promptSnippet ?? indexed?.summary ?? indexed?.promptSnippet

        let name: String
        if let snippet = resolvedSnippet {
            name = [resolvedProject ?? parsed.dateText, snippet].compactMap { $0 }.joined(separator: " · ")
        } else if let project = resolvedProject {
            name = "\(project) · \(parsed.dateText ?? "会话记录") (\(parsed.shortID))"
        } else if let date = parsed.dateText {
            let kind = isCompressed ? "压缩会话归档" : "会话记录"
            name = "\(date) · \(kind) (\(parsed.shortID))"
        } else {
            name = fileName
        }

        let record = SessionRecord(
            title: resolvedTitle,
            projectName: resolvedProject,
            promptSnippet: preview.promptSnippet ?? indexed?.promptSnippet,
            summary: preview.summary ?? indexed?.summary,
            workspacePath: preview.workspacePath ?? indexed?.workspacePath ?? parentIndexed?.workspacePath
        )

        return SessionItemMetadata(
            displayName: name,
            title: resolvedTitle,
            projectName: resolvedProject,
            resolvedRecord: record,
            resolvedSessionID: sessionIDString ?? preview.sessionID
        )
    }

    /// 为扁平会话目录（一级子项）构造友好名称
    public func buildFlatSessionDisplayName(itemURL: URL, isDirectory: Bool) -> String {
        flatSessionMetadata(itemURL: itemURL, isDirectory: isDirectory).displayName
    }

    func flatSessionMetadata(
        itemURL: URL,
        isDirectory: Bool,
        clientID: String = "",
        ruleID: String = "",
        sessionIndex: ClientSessionIndex = ClientSessionIndex(),
        fileManager: FileManager = .default
    ) -> SessionItemMetadata {
        let name = itemURL.lastPathComponent
        let lowerName = name.lowercased()

        // 1. Codex rollout 文件（含 .jsonl / .jsonl.zst / .jsonl.zstd）
        if !isDirectory && name.hasPrefix("rollout-") {
            return rolloutSessionMetadata(fileURL: itemURL, sessionIndex: sessionIndex)
        }

        // 2. 常规或压缩 JSONL 文件（Claude transcripts、Multica pi-sessions、Copilot 等）
        if !isDirectory && Self.isJSONLOrCompressedJSONL(lowerName) {
            let preview = readJSONLPreview(from: itemURL)
            let sessionID = preview.sessionID ?? Self.extractSessionIdentifier(from: name, isDirectory: false)
            let indexed = sessionID.flatMap { sessionIndex.lookup(sessionID: $0) }
            let projectName = preview.projectName ?? indexed?.projectName
            let title = preview.title ?? indexed?.title
            let snippet = preview.summary ?? preview.promptSnippet ?? indexed?.summary ?? indexed?.promptSnippet

            var displayName = name
            if let snippet {
                displayName = [projectName, snippet].compactMap { $0 }.joined(separator: " · ")
            } else if let title {
                displayName = [projectName, title].compactMap { $0 }.joined(separator: " · ")
            }

            let record = SessionRecord(
                title: title,
                projectName: projectName,
                promptSnippet: preview.promptSnippet ?? indexed?.promptSnippet,
                summary: preview.summary ?? indexed?.summary,
                workspacePath: preview.workspacePath ?? indexed?.workspacePath
            )
            return SessionItemMetadata(
                displayName: displayName,
                title: title,
                projectName: projectName,
                resolvedRecord: record,
                resolvedSessionID: sessionID
            )
        }

        // 3. OpenCode / Doubao 等单文件 JSON 会话
        if !isDirectory && lowerName.hasSuffix(".json") {
            let preview = readJSONSessionMetadata(from: itemURL)
            let sessionID = preview.sessionID ?? Self.extractSessionIdentifier(from: name, isDirectory: false)
            let indexed = sessionID.flatMap { sessionIndex.lookup(sessionID: $0) }
            let projectName = preview.projectName ?? indexed?.projectName
            let title = preview.title ?? indexed?.title
            let snippet = preview.summary ?? preview.promptSnippet ?? indexed?.summary ?? indexed?.promptSnippet

            if let title {
                let displayName = [projectName, title].compactMap { $0 }.joined(separator: " · ")
                let record = SessionRecord(title: title, projectName: projectName, promptSnippet: snippet, workspacePath: preview.workspacePath)
                return SessionItemMetadata(
                    displayName: displayName,
                    title: title,
                    projectName: projectName,
                    resolvedRecord: record,
                    resolvedSessionID: sessionID
                )
            }
            if let snippet {
                let displayName = [projectName, snippet].compactMap { $0 }.joined(separator: " · ")
                let record = SessionRecord(projectName: projectName, promptSnippet: snippet, workspacePath: preview.workspacePath)
                return SessionItemMetadata(
                    displayName: displayName,
                    title: nil,
                    projectName: projectName,
                    resolvedRecord: record,
                    resolvedSessionID: sessionID
                )
            }
            return SessionItemMetadata(displayName: name)
        }

        // 4. Windsurf Cascade 二进制会话（.pb）：避免仅显示裸 UUID
        if !isDirectory && clientID == "windsurf" && lowerName.hasSuffix(".pb") {
            let stem = itemURL.deletingPathExtension().lastPathComponent
            if let sessionID = Self.extractSessionIdentifier(from: stem, isDirectory: false),
               let indexed = sessionIndex.lookup(sessionID: sessionID),
               let title = indexed.bestTitle {
                return SessionItemMetadata(
                    displayName: [indexed.projectName, title].compactMap { $0 }.joined(separator: " · "),
                    title: title,
                    projectName: indexed.projectName,
                    resolvedRecord: indexed,
                    resolvedSessionID: sessionID
                )
            }
            if UUID(uuidString: stem) != nil {
                let shortID = Self.extractShortIdentifier(from: stem)
                return SessionItemMetadata(displayName: "Cascade 会话 (\(shortID))")
            }
        }

        // 5. 编码后的项目目录名（如 Cursor `.cursor/projects/Users-...`）
        if isDirectory && (name.hasPrefix("Users-") || name.hasPrefix("-Users-")) {
            if let decoded = Self.decodeEncodedProjectName(name), !decoded.isEmpty {
                return SessionItemMetadata(displayName: "\(decoded)（项目会话/缓存）", projectName: decoded)
            }
        }

        // 6. 目录型会话（Antigravity brain、WorkBuddy 任务目录、ZCode、OpenCode、Copilot、Jan、Claude Desktop、Cursor chats、Codex multica-sessions）
        if isDirectory {
            if let dirMeta = resolveDirectorySessionMetadata(
                dirURL: itemURL,
                clientID: clientID,
                ruleID: ruleID,
                sessionIndex: sessionIndex,
                fileManager: fileManager
            ) {
                return dirMeta
            }
        }

        return SessionItemMetadata(displayName: name)
    }

    // MARK: - Session-Associated Non-Session Artifacts (.temporary / .logs)

    /// 为以会话 UUID / ID 命名的关联产物（如 `.codex/generated_images/<uuid>`、`.workbuddy/workspace/sessions/<uuid>`、
    /// `.claude/debug/<uuid>.txt`、`.gemini/tmp/<dir>`、`.local/share/opencode/log/<file>` 等）反查所属会话标题与项目名。
    func sessionArtifactMetadata(
        itemURL: URL,
        isDirectory: Bool,
        clientID: String,
        rule: ScanRule,
        fileCount: Int,
        sessionIndex: ClientSessionIndex,
        fileManager: FileManager
    ) -> SessionItemMetadata {
        let name = itemURL.lastPathComponent
        let candidateID = Self.extractSessionIdentifier(from: name, isDirectory: isDirectory)
        let isUUIDLike = Self.isUUIDNamedEntry(name, isDirectory: isDirectory)

        switch rule.id {
        case "codex-generated-images":
            return buildLinkedArtifactMetadata(
                itemURL: itemURL,
                isDirectory: isDirectory,
                artifactLabel: "对话图片缓存",
                ruleExplanation: rule.explanation,
                candidateID: candidateID,
                isUUIDLike: isUUIDLike,
                countDescription: Self.describeImageDirectoryCount(at: itemURL, fallbackFileCount: fileCount, fileManager: fileManager),
                sessionIndex: sessionIndex
            )

        case "workbuddy-workspace-sessions":
            let countText = fileCount > 0 ? "\(fileCount) 个文件" : nil
            return buildLinkedArtifactMetadata(
                itemURL: itemURL,
                isDirectory: isDirectory,
                artifactLabel: "文件回滚快照",
                ruleExplanation: rule.explanation,
                candidateID: candidateID,
                isUUIDLike: isUUIDLike,
                countDescription: countText,
                sessionIndex: sessionIndex
            )

        case "claude-code-debug":
            return buildLinkedArtifactMetadata(
                itemURL: itemURL,
                isDirectory: isDirectory,
                artifactLabel: "调试日志",
                ruleExplanation: rule.explanation,
                candidateID: candidateID,
                isUUIDLike: isUUIDLike,
                countDescription: nil,
                sessionIndex: sessionIndex
            )

        case "gemini-cli-tmp":
            if isDirectory {
                if let geminiMeta = readGeminiTmpMetadata(in: itemURL, sessionIndex: sessionIndex, ruleExplanation: rule.explanation, fileManager: fileManager) {
                    return geminiMeta
                }
            }
            if isUUIDLike {
                return buildLinkedArtifactMetadata(
                    itemURL: itemURL,
                    isDirectory: isDirectory,
                    artifactLabel: "临时会话目录",
                    ruleExplanation: rule.explanation,
                    candidateID: candidateID,
                    isUUIDLike: true,
                    countDescription: fileCount > 0 ? "\(fileCount) 个文件" : nil,
                    sessionIndex: sessionIndex
                )
            }
            return SessionItemMetadata(displayName: name)

        case "opencode-logs", "codex-cli-log", "codex-cli-hidden-tmp":
            // 仅当文件名/目录名确实命中某个已知会话 ID 时才改写展示名，常规日志文件保持原名
            if let candidateID, let record = sessionIndex.lookup(sessionID: candidateID), let title = record.bestTitle {
                let label = rule.category == .logs ? "运行日志" : "临时产物"
                return SessionItemMetadata(
                    displayName: "\(label) · \(title)",
                    title: title,
                    projectName: record.projectName,
                    resolvedRecord: record,
                    resolvedSessionID: candidateID
                )
            }
            return SessionItemMetadata(displayName: name)

        default:
            // 其他客户端的通用 UUID 关联兜底（若规则不是 sessions 但条目名命中了该客户端的会话索引）
            if let candidateID, let record = sessionIndex.lookup(sessionID: candidateID), let title = record.bestTitle {
                let label = rule.category == .logs ? "会话日志" : "会话关联产物"
                return SessionItemMetadata(
                    displayName: "\(label) · \(title)",
                    title: title,
                    projectName: record.projectName,
                    resolvedRecord: record,
                    resolvedSessionID: candidateID
                )
            }
            return SessionItemMetadata(displayName: name)
        }
    }

    private func buildLinkedArtifactMetadata(
        itemURL: URL,
        isDirectory: Bool,
        artifactLabel: String,
        ruleExplanation: String,
        candidateID: String?,
        isUUIDLike: Bool,
        countDescription: String?,
        sessionIndex: ClientSessionIndex
    ) -> SessionItemMetadata {
        let name = itemURL.lastPathComponent
        let countPrefix = countDescription.map { "共 \($0) · " } ?? ""

        if let candidateID, let record = sessionIndex.lookup(sessionID: candidateID) {
            if let bestTitle = record.bestTitle {
                return SessionItemMetadata(
                    displayName: "\(artifactLabel) · \(bestTitle)",
                    title: bestTitle,
                    projectName: record.projectName,
                    safetyNoteOverride: "\(countPrefix)\(ruleExplanation)",
                    resolvedRecord: record,
                    resolvedSessionID: candidateID
                )
            }
            if let projectName = record.projectName {
                let shortID = Self.extractShortIdentifier(from: candidateID)
                return SessionItemMetadata(
                    displayName: "\(artifactLabel) · \(projectName) (\(shortID))",
                    title: nil,
                    projectName: projectName,
                    safetyNoteOverride: "\(countPrefix)\(ruleExplanation)",
                    resolvedRecord: record,
                    resolvedSessionID: candidateID
                )
            }
        }

        // 未命中任何本机现存会话，但条目本身是裸 UUID：给出清晰可读的兜底摘要，不再裸露一串 UUID
        if isUUIDLike {
            let shortID = Self.extractShortIdentifier(from: candidateID ?? itemURL.deletingPathExtension().lastPathComponent)
            let displayName: String
            if let countDescription {
                displayName = "\(artifactLabel) · \(countDescription) (\(shortID))"
            } else {
                displayName = "\(artifactLabel) (\(shortID))"
            }
            return SessionItemMetadata(
                displayName: displayName,
                title: nil,
                projectName: nil,
                safetyNoteOverride: "未找到关联会话（可能已删除或归档）· \(ruleExplanation)"
            )
        }

        return SessionItemMetadata(displayName: name)
    }

    // MARK: - JSONL / Compressed JSONL Preview Reader

    /// 只读提取会话（支持明文 `.jsonl` 与 Zstandard 压缩 `.jsonl.zst` / `.jsonl.zstd`）的标题、项目和首条提问。
    public func readJSONLPreview(from url: URL) -> SessionPreview {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.hasSuffix(".zst") || lowerName.hasSuffix(".zstd") {
            return readCompressedJSONLPreview(from: url)
        }

        guard let handle = Self.openRegularFile(url) else {
            return SessionPreview()
        }
        defer {
            try? handle.close()
        }

        // 逐块读取头部（每次 64 KB，最多 256 KB），一旦提取到项目名与首条用户提问即提前结束，兼顾大系统提示词与扫描性能
        var headData = Data()
        var foundProjectName: String?
        var foundWorkspacePath: String?
        var foundSnippet: String?
        var foundSessionID: String?
        var foundParentSessionID: String?
        var customTitle: String?
        var generatedTitle: String?
        var summary: String?
        var scannedLines = 0
        var leftoverLine = Data()
        var reachedEOF = false

        while headData.count < Self.maxHeadBytes {
            guard let chunk = try? handle.read(upToCount: Self.headChunkBytes), !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            headData.append(contentsOf: chunk)

            let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (idx, part) in parts.enumerated() {
                let isLastPart = (idx == parts.count - 1)
                if idx == 0 {
                    leftoverLine.append(contentsOf: part)
                    if !isLastPart {
                        processHeadLine(
                            leftoverLine,
                            scannedLines: &scannedLines,
                            projectName: &foundProjectName,
                            workspacePath: &foundWorkspacePath,
                            snippet: &foundSnippet,
                            sessionID: &foundSessionID,
                            parentSessionID: &foundParentSessionID,
                            customTitle: &customTitle,
                            generatedTitle: &generatedTitle,
                            summary: &summary
                        )
                        leftoverLine.removeAll(keepingCapacity: true)
                    }
                } else if isLastPart {
                    leftoverLine = Data(part)
                } else {
                    processHeadLine(
                        Data(part),
                        scannedLines: &scannedLines,
                        projectName: &foundProjectName,
                        workspacePath: &foundWorkspacePath,
                        snippet: &foundSnippet,
                        sessionID: &foundSessionID,
                        parentSessionID: &foundParentSessionID,
                        customTitle: &customTitle,
                        generatedTitle: &generatedTitle,
                        summary: &summary
                    )
                }
            }

            if chunk.count < Self.headChunkBytes {
                reachedEOF = true
                break
            }
            // 一旦已获得项目名和首条提问（或已扫描足够多行），提前停止头部扩展，避免无谓 I/O
            if (foundProjectName != nil && foundSnippet != nil) || scannedLines >= Self.maxLinesToScan {
                break
            }
        }

        if !leftoverLine.isEmpty && reachedEOF {
            processHeadLine(
                leftoverLine,
                scannedLines: &scannedLines,
                projectName: &foundProjectName,
                workspacePath: &foundWorkspacePath,
                snippet: &foundSnippet,
                sessionID: &foundSessionID,
                parentSessionID: &foundParentSessionID,
                customTitle: &customTitle,
                generatedTitle: &generatedTitle,
                summary: &summary
            )
        }

        guard !headData.isEmpty else {
            return SessionPreview()
        }

        // 重命名记录通常追加在文件末尾：仅在需要检查末尾或头部可能遗漏标题行时才按字节换行切片扫描
        var titleLineDatas: [Data] = []
        if !reachedEOF {
            if Self.mayContainTitleMarker(headData) {
                titleLineDatas = Self.splitLineSlices(headData)
            }
            if let end = try? handle.seekToEnd(),
               end > UInt64(headData.count),
               (try? handle.seek(toOffset: end - UInt64(min(UInt64(Self.maxTailBytes), end)) - (end > UInt64(Self.maxTailBytes) ? 1 : 0))) != nil,
               let tail = try? handle.read(upToCount: Self.maxTailBytes + 1),
               Self.mayContainTitleMarker(tail) {
                if end > UInt64(Self.maxTailBytes), let firstNewline = tail.firstIndex(of: 0x0A) {
                    // 从边界前一字节开始读取，以区分恰好在行首和截断了首行的情况
                    titleLineDatas += Self.splitLineSlices(Data(tail.suffix(from: firstNewline + 1)))
                } else {
                    titleLineDatas += Self.splitLineSlices(tail)
                }
            }
        } else if Self.mayContainTitleMarker(headData) {
            titleLineDatas = Self.splitLineSlices(headData)
        }

        let titles = titleLineDatas.isEmpty
            ? (customTitle: nil, generatedTitle: nil, summary: nil)
            : Self.extractTitles(from: titleLineDatas)
        return SessionPreview(
            projectName: foundProjectName,
            promptSnippet: foundSnippet,
            title: titles.customTitle ?? titles.generatedTitle ?? customTitle ?? generatedTitle,
            summary: titles.summary ?? summary,
            sessionID: foundSessionID,
            workspacePath: foundWorkspacePath,
            parentSessionID: foundParentSessionID
        )
    }

    /// 严格只读、有界解压 `.jsonl.zst` / `.jsonl.zstd` 压缩会话归档头部并复用既有 JSONL 解析逻辑
    func readCompressedJSONLPreview(from url: URL) -> SessionPreview {
        let expectsEmbeddedTitle = url.lastPathComponent.lowercased().hasSuffix(".zstd")
        var scannedOffset = 0
        var scannedLines = 0
        var foundProjectName: String?
        var foundWorkspacePath: String?
        var foundSnippet: String?
        var foundSessionID: String?
        var foundParentSessionID: String?
        var customTitle: String?
        var generatedTitle: String?
        var summary: String?

        func scanIncrementalLines(in buffer: [UInt8], includeTrailingIncomplete: Bool) {
            var lineStart = scannedOffset
            var idx = scannedOffset
            while idx < buffer.count && scannedLines < Self.maxLinesToScan {
                if buffer[idx] == 0x0A {
                    var lineEnd = idx
                    if lineEnd > lineStart && buffer[lineEnd - 1] == 0x0D {
                        lineEnd -= 1
                    }
                    if lineEnd > lineStart {
                        processHeadLine(
                            Data(buffer[lineStart..<lineEnd]),
                            scannedLines: &scannedLines,
                            projectName: &foundProjectName,
                            workspacePath: &foundWorkspacePath,
                            snippet: &foundSnippet,
                            sessionID: &foundSessionID,
                            parentSessionID: &foundParentSessionID,
                            customTitle: &customTitle,
                            generatedTitle: &generatedTitle,
                            summary: &summary
                        )
                    }
                    lineStart = idx + 1
                }
                idx += 1
            }
            scannedOffset = lineStart

            if includeTrailingIncomplete && lineStart < buffer.count && scannedLines < Self.maxLinesToScan {
                var lineEnd = buffer.count
                if lineEnd > lineStart && buffer[lineEnd - 1] == 0x0D {
                    lineEnd -= 1
                }
                if lineEnd > lineStart {
                    processHeadLine(
                        Data(buffer[lineStart..<lineEnd]),
                        scannedLines: &scannedLines,
                        projectName: &foundProjectName,
                        workspacePath: &foundWorkspacePath,
                        snippet: &foundSnippet,
                        sessionID: &foundSessionID,
                        parentSessionID: &foundParentSessionID,
                        customTitle: &customTitle,
                        generatedTitle: &generatedTitle,
                        summary: &summary
                    )
                }
            }
        }

        guard let decompressed = ZstandardDecoder.decompressFilePrefix(
            at: url,
            maxCompressedBytes: Self.maxCompressedReadBytes,
            maxOutputBytes: Self.maxDecompressedBytes,
            shouldStop: { partialBytes in
                scanIncrementalLines(in: partialBytes, includeTrailingIncomplete: false)
                if expectsEmbeddedTitle {
                    return foundProjectName != nil && (customTitle != nil || generatedTitle != nil)
                }
                return (foundProjectName != nil && (customTitle != nil || generatedTitle != nil || foundSnippet != nil))
                    || scannedLines >= Self.maxLinesToScan
            }
        ), !decompressed.isEmpty else {
            return SessionPreview()
        }

        let finalBytes = [UInt8](decompressed)
        scanIncrementalLines(in: finalBytes, includeTrailingIncomplete: true)

        if Self.mayContainTitleMarker(decompressed) {
            let titles = Self.extractTitles(from: Self.splitLineSlices(decompressed))
            return SessionPreview(
                projectName: foundProjectName,
                promptSnippet: foundSnippet,
                title: titles.customTitle ?? titles.generatedTitle ?? customTitle ?? generatedTitle,
                summary: titles.summary ?? summary,
                sessionID: foundSessionID,
                workspacePath: foundWorkspacePath,
                parentSessionID: foundParentSessionID
            )
        }

        return SessionPreview(
            projectName: foundProjectName,
            promptSnippet: foundSnippet,
            title: customTitle ?? generatedTitle,
            summary: summary,
            sessionID: foundSessionID,
            workspacePath: foundWorkspacePath,
            parentSessionID: foundParentSessionID
        )
    }

    /// 直接从内存中的 UTF-8 JSONL 字节流解析会话摘要（便于 `.zst` 解压流与单测复用）
    func parseJSONLPreview(from data: Data) -> SessionPreview {
        guard !data.isEmpty else { return SessionPreview() }
        let lines = Self.splitLineSlices(data)

        var foundProjectName: String?
        var foundWorkspacePath: String?
        var foundSnippet: String?
        var foundSessionID: String?
        var foundParentSessionID: String?
        var customTitle: String?
        var generatedTitle: String?
        var summary: String?
        var scannedLines = 0

        for lineData in lines.prefix(Self.maxLinesToScan) {
            processHeadLine(
                lineData,
                scannedLines: &scannedLines,
                projectName: &foundProjectName,
                workspacePath: &foundWorkspacePath,
                snippet: &foundSnippet,
                sessionID: &foundSessionID,
                parentSessionID: &foundParentSessionID,
                customTitle: &customTitle,
                generatedTitle: &generatedTitle,
                summary: &summary
            )
            if foundProjectName != nil && foundSnippet != nil && (customTitle != nil || generatedTitle != nil) {
                break
            }
        }

        let titles = Self.mayContainTitleMarker(data)
            ? Self.extractTitles(from: lines)
            : (customTitle: nil, generatedTitle: nil, summary: nil)
        return SessionPreview(
            projectName: foundProjectName,
            promptSnippet: foundSnippet,
            title: titles.customTitle ?? titles.generatedTitle ?? customTitle ?? generatedTitle,
            summary: titles.summary ?? summary,
            sessionID: foundSessionID,
            workspacePath: foundWorkspacePath,
            parentSessionID: foundParentSessionID
        )
    }

    private func processHeadLine(
        _ lineData: Data,
        scannedLines: inout Int,
        projectName: inout String?,
        workspacePath: inout String?,
        snippet: inout String?,
        sessionID: inout String?,
        parentSessionID: inout String?,
        customTitle: inout String?,
        generatedTitle: inout String?,
        summary: inout String?
    ) {
        guard !lineData.isEmpty, scannedLines < Self.maxLinesToScan else { return }
        scannedLines += 1
        // 跳过超长单行（如嵌入大图的工具调用），避免无谓的 JSON 反序列化开销
        guard lineData.count <= Self.maxHeadBytes,
              let json = Self.parseJSON(lineData) else {
            return
        }

        let payload = json["payload"] as? [String: Any]
        if sessionID == nil {
            let rawID = (json["sessionId"] as? String)
                ?? (json["session_id"] as? String)
                ?? (payload?["session_id"] as? String)
                ?? (payload?["id"] as? String)
                ?? ((json["type"] as? String) == "session" ? (json["id"] as? String) : nil)
            if let rawID = Self.nonBlank(rawID) {
                sessionID = rawID
            }
        }

        if parentSessionID == nil {
            let rawParent = Self.nonBlank(json["parent_thread_id"])
                ?? Self.nonBlank(json["parentSessionId"])
                ?? Self.nonBlank(payload?["parent_thread_id"])
                ?? Self.extractParentThreadID(fromSourceObject: payload?["source"])
            if let rawParent {
                parentSessionID = rawParent
            }
        }

        if projectName == nil {
            if let cwd = Self.extractCWD(from: json) {
                workspacePath = cwd
                projectName = Self.projectName(fromPath: cwd)
            }
        }

        if snippet == nil, let userText = Self.extractUserMessage(from: json) {
            if let cleaned = Self.sanitizePromptSnippet(userText) {
                snippet = cleaned
            }
        }

        if customTitle == nil || generatedTitle == nil || summary == nil {
            Self.accumulateTitle(from: json, customTitle: &customTitle, generatedTitle: &generatedTitle, summary: &summary)
        }
    }

    private static let titleMarkerNeedles: [Data] = [
        Data("\"customTitle\"".utf8),
        Data("\"aiTitle\"".utf8),
        Data("\"session_info\"".utf8),
        Data("\"summary\"".utf8),
        Data("\"session/title\"".utf8),
        Data("\"session.title_changed\"".utf8)
    ]

    private static func mayContainTitleMarker(_ data: Data) -> Bool {
        titleMarkerNeedles.contains { data.range(of: $0) != nil }
    }

    private static func splitLineSlices(_ data: Data) -> [Data] {
        var result: [Data] = []
        result.reserveCapacity(32)
        var start = data.startIndex
        for idx in data.indices where data[idx] == 0x0A {
            var end = idx
            if end > start && data[data.index(before: end)] == 0x0D {
                end = data.index(before: end)
            }
            if end > start {
                result.append(Data(data[start..<end]))
            }
            start = data.index(after: idx)
        }
        if start < data.endIndex {
            var end = data.endIndex
            if end > start && data[data.index(before: end)] == 0x0D {
                end = data.index(before: end)
            }
            if end > start {
                result.append(Data(data[start..<end]))
            }
        }
        return result
    }

    private static func extractTitles(from lines: [Data]) -> (customTitle: String?, generatedTitle: String?, summary: String?) {
        var customTitle: String?
        var generatedTitle: String?
        var summary: String?

        for line in lines.reversed() {
            guard mayContainTitleMarker(line),
                  let json = Self.parseJSON(line) else { continue }
            accumulateTitle(from: json, customTitle: &customTitle, generatedTitle: &generatedTitle, summary: &summary)
        }
        return (customTitle, generatedTitle, summary)
    }

    private static func accumulateTitle(
        from json: [String: Any],
        customTitle: inout String?,
        generatedTitle: inout String?,
        summary: inout String?
    ) {
        switch json["type"] as? String {
        case "custom-title":
            customTitle = customTitle ?? Self.nonBlank(json["customTitle"])
        case "session_info":
            customTitle = customTitle ?? Self.nonBlank(json["name"])
        case "ai-title":
            generatedTitle = generatedTitle ?? Self.nonBlank(json["aiTitle"])
        case "summary":
            summary = summary ?? Self.nonBlank(json["summary"])
        case "session/title":
            // DeepSeek Harness: {"type":"session/title","data":{"title":"..."}}
            if let data = json["data"] as? [String: Any] {
                generatedTitle = generatedTitle ?? Self.nonBlank(data["title"])
            }
        case "session.title_changed":
            // GitHub Copilot CLI: {"type":"session.title_changed","data":{"title":"..."}}
            if let data = json["data"] as? [String: Any] {
                generatedTitle = generatedTitle ?? Self.nonBlank(data["title"])
            }
        default:
            break
        }
    }

    // MARK: - Client-Specific Index Loaders

    private func loadCodexIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL,
        safetyGuard: SafetyGuard,
        fileManager: FileManager
    ) {
        // 1. 优先读取 `.codex/session_index.jsonl`（用户重命名/保存的 thread_name 拥有最高优先级）
        let indexURL = homeDirectory.appendingPathComponent(".codex/session_index.jsonl")
        if safetyGuard.validateBuiltInContainer(indexURL).isAllowed {
            let titles = readCodexTitles(from: indexURL)
            for (uuid, title) in titles {
                index.register(
                    sessionID: uuid.uuidString,
                    record: SessionRecord(title: title),
                    preferExisting: false
                )
            }
        }

        // 2. 严格只读回退读取 `.codex/state_*.sqlite`（优先最新版本号，仅作未命中 session_index 时的补充）
        let codexRoot = homeDirectory.appendingPathComponent(".codex")
        if let stateDB = Self.findLatestCodexStateDB(in: codexRoot, fileManager: fileManager) {
            ReadOnlySQLiteReader.withReadOnlyDatabase(at: stateDB) { db in
                var rows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT id, SUBSTR(title, 1, 512), cwd, SUBSTR(source, 1, 512), SUBSTR(first_user_message, 1, 256) FROM threads LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                    columnCount: 5
                )
                if rows.isEmpty {
                    // 兼容旧版 Codex state_*.sqlite（不含 source / first_user_message 列）
                    rows = ReadOnlySQLiteReader.queryStringRows(
                        db: db,
                        sql: "SELECT id, SUBSTR(title, 1, 512), cwd, NULL, NULL FROM threads LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                        columnCount: 5
                    )
                }

                var subagentLinks: [(childID: String, parentID: String, cwd: String?)] = []
                for row in rows {
                    guard let id = Self.nonBlank(row[0]) else { continue }
                    let cleanedTitle = row[1].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let cwd = Self.nonBlank(row[2])
                    let firstPrompt = row[4].flatMap { Self.sanitizePromptSnippet($0) }
                    let projectName = cwd.flatMap { Self.projectName(fromPath: $0) }
                    let record = SessionRecord(
                        title: cleanedTitle,
                        projectName: projectName,
                        promptSnippet: firstPrompt,
                        workspacePath: cwd
                    )
                    // preferExisting = true，确保绝不覆盖 session_index.jsonl 中的标题
                    index.register(sessionID: id, record: record, preferExisting: true)

                    if let sourceRaw = Self.nonBlank(row[3]),
                       let parentID = Self.extractParentThreadID(fromSourceJSON: sourceRaw) {
                        subagentLinks.append((childID: id, parentID: parentID, cwd: cwd))
                    }
                }

                // 为子代理会话回溯父会话标题（最多追溯 4 层防环），避免子代理会话与生成的图片缓存缺少可读标题
                let parentMap = Dictionary(
                    subagentLinks.map { ($0.childID.lowercased(), $0.parentID.lowercased()) },
                    uniquingKeysWith: { first, _ in first }
                )
                for link in subagentLinks {
                    if index.lookup(sessionID: link.childID)?.title != nil {
                        continue
                    }
                    var cursor = link.parentID.lowercased()
                    var visited: Set<String> = [link.childID.lowercased()]
                    var resolvedParent: SessionRecord?
                    for _ in 0..<4 {
                        if visited.contains(cursor) { break }
                        visited.insert(cursor)
                        if let parentRecord = index.lookup(sessionID: cursor), parentRecord.bestTitle != nil {
                            resolvedParent = parentRecord
                            break
                        }
                        if let nextParent = parentMap[cursor] {
                            cursor = nextParent
                        } else {
                            break
                        }
                    }
                    if let resolvedParent, let parentTitle = resolvedParent.bestTitle {
                        let projectName = link.cwd.flatMap { Self.projectName(fromPath: $0) } ?? resolvedParent.projectName
                        let record = SessionRecord(
                            title: Self.formatSubagentTitle(parentTitle),
                            projectName: projectName,
                            workspacePath: link.cwd ?? resolvedParent.workspacePath
                        )
                        index.register(sessionID: link.childID, record: record, preferExisting: true)
                    }
                }
            }
        }
    }

    private static func formatSubagentTitle(_ parentTitle: String) -> String {
        if parentTitle.hasSuffix("（子代理）") {
            return parentTitle
        }
        return "\(parentTitle)（子代理）"
    }

    private static func extractParentThreadID(fromSourceJSON raw: String) -> String? {
        guard raw.contains("parent_thread_id"),
              let data = raw.data(using: .utf8),
              let json = parseJSON(data) else {
            return nil
        }
        return extractParentThreadID(fromSourceObject: json)
    }

    private static func extractParentThreadID(fromSourceObject object: Any?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let direct = nonBlank(dict["parent_thread_id"]) {
            return direct
        }
        if let subagent = dict["subagent"] as? [String: Any] {
            if let direct = nonBlank(subagent["parent_thread_id"]) {
                return direct
            }
            if let spawn = subagent["thread_spawn"] as? [String: Any],
               let parent = nonBlank(spawn["parent_thread_id"]) {
                return parent
            }
        }
        return nil
    }

    private func loadClaudeCodeIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL,
        safetyGuard: SafetyGuard,
        fileManager: FileManager
    ) {
        let projectsRoot = homeDirectory.appendingPathComponent(".claude/projects")
        guard safetyGuard.validateBuiltInContainer(projectsRoot).isAllowed,
              let projectDirs = try? fileManager.contentsOfDirectory(
                  at: projectsRoot,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: []
              ) else {
            return
        }

        for dir in projectDirs {
            if Task.isCancelled { break }
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let idxFile = dir.appendingPathComponent("sessions-index.json")
            guard let data = Self.readBoundedRegularFile(idxFile, maxBytes: 1_048_576),
                  let root = Self.parseJSON(data),
                  let entries = root["entries"] as? [[String: Any]] else {
                continue
            }
            let fallbackProject = (root["originalPath"] as? String).flatMap { Self.projectName(fromPath: $0) }
                ?? Self.decodeEncodedProjectName(dir.lastPathComponent)

            for entry in entries {
                guard let sessionID = Self.nonBlank(entry["sessionId"]) else { continue }
                let summary = Self.nonBlank(entry["summary"])
                let firstPrompt = (entry["firstPrompt"] as? String).flatMap { Self.sanitizePromptSnippet($0) }
                let projectPath = Self.nonBlank(entry["projectPath"])
                let projectName = projectPath.flatMap { Self.projectName(fromPath: $0) } ?? fallbackProject
                let record = SessionRecord(
                    title: nil,
                    projectName: projectName,
                    promptSnippet: firstPrompt,
                    summary: summary,
                    workspacePath: projectPath
                )
                index.register(sessionID: sessionID, record: record, preferExisting: true)
            }
        }
    }

    private func loadWorkBuddyIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL,
        fileManager: FileManager
    ) {
        let candidates = [
            homeDirectory.appendingPathComponent(".workbuddy/workbuddy.db"),
            homeDirectory.appendingPathComponent(".workbuddy-ai/workbuddy.db")
        ]
        for dbURL in candidates where fileManager.fileExists(atPath: dbURL.path) {
            ReadOnlySQLiteReader.withReadOnlyDatabase(at: dbURL) { db in
                let rows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT id, cwd, SUBSTR(title, 1, 256), SUBSTR(custom_title, 1, 256) FROM sessions ORDER BY updated_at DESC LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                    columnCount: 4
                )
                for row in rows {
                    guard let id = Self.nonBlank(row[0]) else { continue }
                    let cwd = Self.nonBlank(row[1])
                    let customTitle = row[3].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let title = customTitle ?? row[2].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let projectName = cwd.flatMap { Self.projectName(fromPath: $0) }
                    let record = SessionRecord(
                        title: title,
                        projectName: projectName,
                        workspacePath: cwd
                    )
                    index.register(
                        sessionID: id,
                        workspacePath: cwd,
                        record: record,
                        preferExisting: true
                    )
                }
            }
        }
    }

    private func loadAntigravityIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL
    ) {
        let dbPaths = [
            homeDirectory.appendingPathComponent(".gemini/antigravity/conversation_summaries.db"),
            homeDirectory.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
        ]
        for dbURL in dbPaths {
            ReadOnlySQLiteReader.withReadOnlyDatabase(at: dbURL) { db in
                let summaryRows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT conversation_id, SUBSTR(title, 1, 256), SUBSTR(preview, 1, 256), SUBSTR(workspace_uris, 1, 1024), project_id FROM conversation_summaries LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                    columnCount: 5
                )
                for row in summaryRows {
                    guard let convID = Self.nonBlank(row[0]) else { continue }
                    let title = row[1].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let preview = row[2].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let workspaceInfo = Self.parseWorkspaceURIs(row[3])
                    let projectName = workspaceInfo.projectName ?? Self.nonBlank(row[4]).flatMap { Self.readableProjectToken($0) }
                    let record = SessionRecord(
                        title: title,
                        projectName: projectName,
                        promptSnippet: preview,
                        workspacePath: workspaceInfo.path
                    )
                    index.register(sessionID: convID, record: record, preferExisting: true)
                }

                // FTS 表作为标题/工作区/首条提问补充（尤其适用于 antigravity-cli）
                let ftsRows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT conversation_id, SUBSTR(title, 1, 256), SUBSTR(workspace, 1, 256), SUBSTR(project, 1, 256), SUBSTR(user_body, 1, 256) FROM conversations_fts LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                    columnCount: 5
                )
                for row in ftsRows {
                    guard let convID = Self.nonBlank(row[0]) else { continue }
                    let title = row[1].flatMap { Self.sanitizeDatabaseTitle($0) }
                    let project = Self.nonBlank(row[3]).flatMap { Self.projectName(fromPath: $0) }
                        ?? Self.nonBlank(row[2]).flatMap { Self.projectName(fromPath: $0) }
                    let userSnippet = row[4].flatMap { Self.sanitizePromptSnippet($0) }
                    let record = SessionRecord(
                        title: title,
                        projectName: project,
                        promptSnippet: userSnippet
                    )
                    index.register(sessionID: convID, record: record, preferExisting: true)
                }
            }
        }
    }

    private func loadOpenCodeIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL
    ) {
        let dbURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        ReadOnlySQLiteReader.withReadOnlyDatabase(at: dbURL) { db in
            var rows = ReadOnlySQLiteReader.queryStringRows(
                db: db,
                sql: "SELECT id, SUBSTR(title, 1, 256), directory, path, slug FROM session_v2 LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                columnCount: 5
            )
            if rows.isEmpty {
                // 兼容旧版 OpenCode `session` 表结构
                rows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT id, SUBSTR(title, 1, 256), directory, NULL, NULL FROM session LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                    columnCount: 5
                )
            }
            for row in rows {
                guard let id = Self.nonBlank(row[0]) else { continue }
                let title = row[1].flatMap { Self.sanitizeDatabaseTitle($0) }
                let dirPath = Self.nonBlank(row[2]) ?? Self.nonBlank(row[3])
                let projectName = dirPath.flatMap { Self.projectName(fromPath: $0) }
                let record = SessionRecord(
                    title: title,
                    projectName: projectName,
                    workspacePath: dirPath
                )
                index.register(sessionID: id, workspacePath: dirPath, record: record, preferExisting: true)
                if let slug = Self.nonBlank(row[4]) {
                    index.register(sessionID: slug, record: record, preferExisting: true)
                }
            }
        }
    }

    private func loadZCodeIndex(
        into index: inout ClientSessionIndex,
        homeDirectory: URL
    ) {
        let dbURL = homeDirectory.appendingPathComponent(".zcode/v2/tasks-index.sqlite")
        ReadOnlySQLiteReader.withReadOnlyDatabase(at: dbURL) { db in
            let taskRows = ReadOnlySQLiteReader.queryStringRows(
                db: db,
                sql: "SELECT task_id, SUBSTR(title, 1, 256), SUBSTR(cli_title, 1, 256), workspace_key, workspace_path, root_path FROM tasks ORDER BY updated_at DESC LIMIT \(ReadOnlySQLiteReader.defaultRowLimit)",
                columnCount: 6
            )
            for row in taskRows {
                let taskID = Self.nonBlank(row[0])
                let title = row[1].flatMap { Self.sanitizeDatabaseTitle($0) }
                    ?? row[2].flatMap { Self.sanitizeDatabaseTitle($0) }
                let workspaceKey = Self.nonBlank(row[3])
                let workspacePath = Self.nonBlank(row[4])
                let rootPath = Self.nonBlank(row[5])
                let projectName = (rootPath ?? workspacePath).flatMap { Self.projectName(fromPath: $0) }
                let record = SessionRecord(
                    title: title,
                    projectName: projectName,
                    workspacePath: workspacePath ?? rootPath
                )
                if let taskID {
                    index.register(sessionID: taskID, record: record, preferExisting: true)
                    if let uuid = Self.extractEmbeddedUUID(from: taskID) {
                        index.register(sessionID: uuid, record: record, preferExisting: true)
                    }
                }
                if let workspaceKey {
                    index.register(sessionID: workspaceKey, record: record, preferExisting: true)
                }
                if let workspacePath {
                    index.register(workspacePath: workspacePath, record: record, preferExisting: true)
                }
            }

            let projectRows = ReadOnlySQLiteReader.queryStringRows(
                db: db,
                sql: "SELECT project_id, SUBSTR(name, 1, 256) FROM projects LIMIT 5000",
                columnCount: 2
            )
            for row in projectRows {
                guard let projID = Self.nonBlank(row[0]),
                      let projName = row[1].flatMap({ Self.sanitizeDatabaseTitle($0) }) else { continue }
                index.register(
                    sessionID: projID,
                    record: SessionRecord(projectName: projName),
                    preferExisting: true
                )
            }
        }
    }

    // MARK: - Directory-Shaped Session Resolvers

    private func resolveDirectorySessionMetadata(
        dirURL: URL,
        clientID: String,
        ruleID: String,
        sessionIndex: ClientSessionIndex,
        fileManager: FileManager
    ) -> SessionItemMetadata? {
        let name = dirURL.lastPathComponent
        let candidateID = Self.extractSessionIdentifier(from: name, isDirectory: true)

        // 1. 优先命中客户端会话索引（Antigravity brain、WorkBuddy ~/WorkBuddy、ZCode、OpenCode 等）
        if let candidateID, let indexed = sessionIndex.lookup(sessionID: candidateID) {
            if let title = indexed.bestTitle {
                let displayName = [indexed.projectName, title].compactMap { $0 }.joined(separator: " · ")
                return SessionItemMetadata(
                    displayName: displayName,
                    title: indexed.title ?? title,
                    projectName: indexed.projectName,
                    resolvedRecord: indexed,
                    resolvedSessionID: candidateID
                )
            }
            if let projectName = indexed.projectName {
                let shortID = Self.extractShortIdentifier(from: candidateID)
                let label = (clientID == "gemini-antigravity") ? "会话工作区" : "会话目录"
                return SessionItemMetadata(
                    displayName: "\(projectName) · \(label) (\(shortID))",
                    title: nil,
                    projectName: projectName,
                    resolvedRecord: indexed,
                    resolvedSessionID: candidateID
                )
            }
        }

        // 2. 按工作区完整路径/目录名匹配（例如 ~/WorkBuddy/2026-11-18-11-20-11、~/.zcode/workspace/draft-...）
        if let indexed = sessionIndex.lookup(workspaceURL: dirURL) {
            if let title = indexed.bestTitle {
                return SessionItemMetadata(
                    displayName: "\(name) · \(title)",
                    title: indexed.title ?? title,
                    projectName: indexed.projectName ?? name,
                    resolvedRecord: indexed,
                    resolvedSessionID: candidateID
                )
            }
        }

        // 3. 按客户端检查目录内部结构化元数据（严格有界只读）
        switch clientID {
        case "copilot":
            if let meta = readCopilotSessionDirectory(dirURL, fileManager: fileManager) {
                return meta
            }
        case "jan":
            if let meta = readJanThreadDirectory(dirURL, fileManager: fileManager) {
                return meta
            }
        case "opencode":
            if let meta = readOpenCodeSessionDirectory(dirURL, sessionIndex: sessionIndex, fileManager: fileManager) {
                return meta
            }
        case "claude-desktop":
            if let meta = readClaudeDesktopSessionDirectory(dirURL, fileManager: fileManager) {
                return meta
            }
        case "cursor":
            if ruleID == "cursor-chats",
               let meta = readCursorChatDirectory(dirURL, fileManager: fileManager) {
                return meta
            }
        case "codex":
            if ruleID == "codex-multica-sessions",
               let meta = readCodexMulticaSessionDirectory(dirURL, sessionIndex: sessionIndex, fileManager: fileManager) {
                return meta
            }
        case "gemini-antigravity":
            if Self.isUUIDNamedEntry(name, isDirectory: true) {
                let shortID = Self.extractShortIdentifier(from: name)
                return SessionItemMetadata(
                    displayName: "会话工作区 (\(shortID))",
                    safetyNoteOverride: "未找到关联会话（可能已删除或归档）· 单次对话产生的本地产物与草稿目录。"
                )
            }
        default:
            break
        }

        return nil
    }

    private func readCopilotSessionDirectory(_ dirURL: URL, fileManager: FileManager) -> SessionItemMetadata? {
        var title: String?
        var projectName: String?
        var workspacePath: String?

        // 1. workspace.yaml（包含 summary: / cwd:）
        let yamlURL = dirURL.appendingPathComponent("workspace.yaml")
        if let data = Self.readBoundedRegularFile(yamlURL, maxBytes: 16_384) {
            let text = String(decoding: data, as: UTF8.self)
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if title == nil, line.hasPrefix("summary:") {
                    title = Self.cleanYAMLValue(String(line.dropFirst("summary:".count)))
                } else if projectName == nil, line.hasPrefix("cwd:") {
                    if let cwd = Self.cleanYAMLValue(String(line.dropFirst("cwd:".count))) {
                        workspacePath = cwd
                        projectName = Self.projectName(fromPath: cwd)
                    }
                }
            }
        }

        // 2. events.jsonl 回退
        let eventsURL = dirURL.appendingPathComponent("events.jsonl")
        var snippet: String?
        if (title == nil || projectName == nil), fileManager.fileExists(atPath: eventsURL.path) {
            let preview = readJSONLPreview(from: eventsURL)
            title = title ?? preview.title
            snippet = preview.summary ?? preview.promptSnippet
            projectName = projectName ?? preview.projectName
            workspacePath = workspacePath ?? preview.workspacePath
        }

        let best = title ?? snippet
        guard best != nil || projectName != nil else { return nil }
        let displayName = [projectName, best ?? "Copilot 会话 (\(Self.extractShortIdentifier(from: dirURL.lastPathComponent)))"]
            .compactMap { $0 }
            .joined(separator: " · ")
        let record = SessionRecord(title: title, projectName: projectName, promptSnippet: snippet, workspacePath: workspacePath)
        return SessionItemMetadata(
            displayName: displayName,
            title: title,
            projectName: projectName,
            resolvedRecord: record,
            resolvedSessionID: Self.extractSessionIdentifier(from: dirURL.lastPathComponent, isDirectory: true)
        )
    }

    private func readJanThreadDirectory(_ dirURL: URL, fileManager: FileManager) -> SessionItemMetadata? {
        let threadJSON = dirURL.appendingPathComponent("thread.json")
        var title: String?
        if let data = Self.readBoundedRegularFile(threadJSON, maxBytes: Self.maxSmallJSONBytes),
           let json = Self.parseJSON(data) {
            title = Self.nonBlank(json["title"])
                ?? ((json["metadata"] as? [String: Any]).flatMap { Self.nonBlank($0["title"]) })
        }

        var snippet: String?
        let messagesJSONL = dirURL.appendingPathComponent("messages.jsonl")
        if title == nil, fileManager.fileExists(atPath: messagesJSONL.path) {
            let preview = readJSONLPreview(from: messagesJSONL)
            title = preview.title
            snippet = preview.summary ?? preview.promptSnippet
        }

        guard let best = title ?? snippet else { return nil }
        let record = SessionRecord(title: title, promptSnippet: snippet)
        return SessionItemMetadata(
            displayName: best,
            title: title,
            resolvedRecord: record,
            resolvedSessionID: dirURL.lastPathComponent
        )
    }

    private func readOpenCodeSessionDirectory(
        _ dirURL: URL,
        sessionIndex: ClientSessionIndex,
        fileManager: FileManager
    ) -> SessionItemMetadata? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let jsonFiles = children.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonFiles.isEmpty else { return nil }

        var latestTitle: String?
        var projectName: String?
        for file in jsonFiles.prefix(8) {
            let preview = readJSONSessionMetadata(from: file)
            if projectName == nil { projectName = preview.projectName }
            if latestTitle == nil {
                latestTitle = preview.title
                    ?? preview.sessionID.flatMap { sessionIndex.lookup(sessionID: $0)?.bestTitle }
            }
            if projectName != nil && latestTitle != nil { break }
        }

        guard projectName != nil || latestTitle != nil else { return nil }
        if jsonFiles.count == 1, let latestTitle {
            return SessionItemMetadata(
                displayName: [projectName, latestTitle].compactMap { $0 }.joined(separator: " · "),
                title: latestTitle,
                projectName: projectName
            )
        }
        let summaryPart = latestTitle.map { "\($0) 等 \(jsonFiles.count) 条会话" } ?? "\(jsonFiles.count) 条会话"
        let displayName = [projectName, summaryPart].compactMap { $0 }.joined(separator: " · ")
        return SessionItemMetadata(displayName: displayName, title: latestTitle, projectName: projectName)
    }

    private func readClaudeDesktopSessionDirectory(_ dirURL: URL, fileManager: FileManager) -> SessionItemMetadata? {
        let candidates = Self.findBoundedMetadataFiles(
            in: dirURL,
            maxDepth: 3,
            maxFiles: 8,
            extensions: ["json", "jsonl"],
            fileManager: fileManager
        )
        for file in candidates {
            let ext = file.pathExtension.lowercased()
            if ext == "jsonl" {
                let preview = readJSONLPreview(from: file)
                if let best = preview.title ?? preview.summary ?? preview.promptSnippet {
                    return SessionItemMetadata(
                        displayName: [preview.projectName, best].compactMap { $0 }.joined(separator: " · "),
                        title: preview.title,
                        projectName: preview.projectName,
                        resolvedRecord: SessionRecord(title: preview.title, projectName: preview.projectName, promptSnippet: preview.promptSnippet),
                        resolvedSessionID: preview.sessionID ?? Self.extractSessionIdentifier(from: dirURL.lastPathComponent, isDirectory: true)
                    )
                }
            } else {
                let preview = readJSONSessionMetadata(from: file)
                if let best = preview.title ?? preview.summary ?? preview.promptSnippet {
                    return SessionItemMetadata(
                        displayName: [preview.projectName, best].compactMap { $0 }.joined(separator: " · "),
                        title: preview.title,
                        projectName: preview.projectName,
                        resolvedRecord: SessionRecord(title: preview.title, projectName: preview.projectName, promptSnippet: preview.promptSnippet),
                        resolvedSessionID: preview.sessionID ?? Self.extractSessionIdentifier(from: dirURL.lastPathComponent, isDirectory: true)
                    )
                }
            }
        }
        return nil
    }

    private func readCursorChatDirectory(_ dirURL: URL, fileManager: FileManager) -> SessionItemMetadata? {
        // Cursor CLI 会话目录中可能包含 store.db（meta 表 key='0' 为十六进制编码 JSON）
        let storeDBs = Self.findBoundedMetadataFiles(
            in: dirURL,
            maxDepth: 2,
            maxFiles: 4,
            extensions: ["db"],
            fileManager: fileManager
        ).filter { $0.lastPathComponent == "store.db" }

        for dbURL in storeDBs {
            if let record = ReadOnlySQLiteReader.withReadOnlyDatabase(at: dbURL, { db -> SessionRecord? in
                let rows = ReadOnlySQLiteReader.queryStringRows(
                    db: db,
                    sql: "SELECT value FROM meta WHERE key = '0' LIMIT 1",
                    columnCount: 1,
                    rowLimit: 1
                )
                guard let raw = rows.first?.first ?? nil else { return nil }
                let jsonData = Self.decodeHexData(raw) ?? Data(raw.utf8)
                guard let json = Self.parseJSON(jsonData) else { return nil }
                let name = (json["name"] as? String).flatMap { Self.sanitizeDatabaseTitle($0) }
                let cwd = Self.nonBlank(json["cwd"]) ?? Self.nonBlank(json["workspace"])
                let project = cwd.flatMap { Self.projectName(fromPath: $0) }
                guard name != nil || project != nil else { return nil }
                return SessionRecord(title: name, projectName: project, workspacePath: cwd)
            }) ?? nil {
                if let title = record.bestTitle {
                    return SessionItemMetadata(
                        displayName: [record.projectName, title].compactMap { $0 }.joined(separator: " · "),
                        title: title,
                        projectName: record.projectName,
                        resolvedRecord: record
                    )
                }
            }
        }
        return nil
    }

    private func readCodexMulticaSessionDirectory(
        _ dirURL: URL,
        sessionIndex: ClientSessionIndex,
        fileManager: FileManager
    ) -> SessionItemMetadata? {
        let rollouts = Self.findBoundedMetadataFiles(
            in: dirURL,
            maxDepth: 5,
            maxFiles: 8,
            extensions: ["jsonl", "zst"],
            fileManager: fileManager
        ).filter { $0.lastPathComponent.hasPrefix("rollout-") }

        guard !rollouts.isEmpty else { return nil }
        var projectName: String?
        var latestTitle: String?
        var latestSnippet: String?

        for file in rollouts {
            let meta = rolloutSessionMetadata(fileURL: file, sessionIndex: sessionIndex)
            if projectName == nil { projectName = meta.projectName }
            if latestTitle == nil { latestTitle = meta.title }
            if latestSnippet == nil {
                latestSnippet = meta.resolvedRecord?.bestTitle
            }
            if projectName != nil && (latestTitle != nil || latestSnippet != nil) {
                break
            }
        }

        let lead = latestTitle ?? latestSnippet
        guard projectName != nil || lead != nil else { return nil }
        let suffix = rollouts.count > 1 ? " 等 \(rollouts.count)+ 条代理会话" : ""
        let label = lead.map { "\($0)\(suffix)" } ?? "工作区代理会话"
        let displayName = [projectName, label].compactMap { $0 }.joined(separator: " · ")
        return SessionItemMetadata(displayName: displayName, title: latestTitle, projectName: projectName)
    }

    private func readGeminiTmpMetadata(
        in dirURL: URL,
        sessionIndex: ClientSessionIndex,
        ruleExplanation: String,
        fileManager: FileManager
    ) -> SessionItemMetadata? {
        var projectName: String?
        let projectRootFile = dirURL.appendingPathComponent(".project_root")
        if let data = Self.readBoundedRegularFile(projectRootFile, maxBytes: 4096),
           let rootPath = Self.nonBlank(String(decoding: data, as: UTF8.self)) {
            projectName = Self.projectName(fromPath: rootPath)
        }

        let chatsDir = dirURL.appendingPathComponent("chats")
        var sessionTitle: String?
        var sessionSnippet: String?
        if let chatFiles = try? fileManager.contentsOfDirectory(
            at: chatsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in chatFiles.filter({ $0.pathExtension.lowercased() == "json" }).prefix(4) {
                let preview = readJSONSessionMetadata(from: file)
                sessionTitle = sessionTitle ?? preview.title
                sessionSnippet = sessionSnippet ?? preview.promptSnippet ?? preview.summary
                if projectName == nil { projectName = preview.projectName }
                if sessionTitle != nil || sessionSnippet != nil { break }
            }
        }

        if let best = sessionTitle ?? sessionSnippet {
            return SessionItemMetadata(
                displayName: "临时会话 · \([projectName, best].compactMap { $0 }.joined(separator: " · "))",
                title: best,
                projectName: projectName,
                safetyNoteOverride: ruleExplanation
            )
        }
        if let projectName {
            return SessionItemMetadata(
                displayName: "临时会话 · \(projectName)",
                title: nil,
                projectName: projectName,
                safetyNoteOverride: ruleExplanation
            )
        }
        return nil
    }

    private func readJSONSessionMetadata(from url: URL) -> SessionPreview {
        guard let data = Self.readBoundedRegularFile(url, maxBytes: Self.maxSmallJSONBytes),
              let json = Self.parseJSON(data) else {
            return SessionPreview()
        }

        let sessionID = Self.nonBlank(json["id"])
            ?? Self.nonBlank(json["sessionId"])
            ?? Self.nonBlank(json["session_id"])
            ?? Self.nonBlank(json["cliSessionId"])

        let title = Self.nonBlank(json["customTitle"])
            ?? Self.nonBlank(json["title"])
            ?? Self.nonBlank(json["topic"])
            ?? Self.nonBlank(json["thread_name"])
            ?? ((json["metadata"] as? [String: Any]).flatMap { Self.nonBlank($0["title"]) })

        let summary = Self.nonBlank(json["summary"])
        var snippet = (json["initialMessage"] as? String).flatMap { Self.sanitizePromptSnippet($0) }
            ?? (json["firstPrompt"] as? String).flatMap { Self.sanitizePromptSnippet($0) }

        if snippet == nil, let messages = json["messages"] as? [[String: Any]] {
            for msg in messages.prefix(10) {
                let role = (msg["role"] as? String) ?? (msg["type"] as? String)
                if role == "user", let content = msg["content"],
                   let text = Self.extractText(from: content),
                   let cleaned = Self.sanitizePromptSnippet(text) {
                    snippet = cleaned
                    break
                }
            }
        }

        let cwd = Self.nonBlank(json["directory"])
            ?? Self.nonBlank(json["cwd"])
            ?? Self.nonBlank(json["projectPath"])
            ?? Self.nonBlank(json["path"])
        let projectName = cwd.flatMap { Self.projectName(fromPath: $0) }

        return SessionPreview(
            projectName: projectName,
            promptSnippet: snippet,
            title: title,
            summary: summary,
            sessionID: sessionID,
            workspacePath: cwd
        )
    }

    // MARK: - Codex Index Reader

    func readCodexTitles(from url: URL) -> [UUID: String] {
        guard let handle = Self.openRegularFile(url) else { return [:] }
        defer { try? handle.close() }

        var titles: [UUID: String] = [:]
        var pendingLine = Data()
        func consumeLine() {
            guard pendingLine.count <= Self.headChunkBytes, !pendingLine.isEmpty,
                  let entry = Self.parseJSON(pendingLine),
                  let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = entry["thread_name"] as? String else { return }
            titles[id] = Self.nonBlank(name)
        }

        // 索引为追加写入格式。按行读完整索引即可匹配较早的归档，同一 ID 以最后一条为准。
        while !Task.isCancelled,
              let chunk = try? handle.read(upToCount: Self.headChunkBytes), !chunk.isEmpty {
            for (index, part) in chunk.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
                if index > 0 {
                    consumeLine()
                    pendingLine.removeAll(keepingCapacity: true)
                }
                if pendingLine.count <= Self.headChunkBytes {
                    pendingLine.append(contentsOf: part)
                }
            }
        }
        consumeLine()
        return titles
    }

    // MARK: - Helpers

    private static func findLatestCodexStateDB(in codexRoot: URL, fileManager: FileManager) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var bestURL: URL?
        var bestVersion = -1
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("state"), name.hasSuffix(".sqlite") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let stem = String(name.dropLast(".sqlite".count))
            let version: Int
            if stem == "state" {
                version = 0
            } else if stem.hasPrefix("state_"), let v = Int(stem.dropFirst("state_".count)) {
                version = v
            } else {
                continue
            }
            if version > bestVersion {
                bestVersion = version
                bestURL = url
            }
        }
        return bestURL
    }

    private static func findEmbeddedSessionFile(in dirURL: URL, fileManager: FileManager) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        // DeepSeek Harness: `session.v4.jsonl.zstd` / `session.jsonl.zst` / `session.jsonl`
        let sorted = entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in sorted {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let lower = url.lastPathComponent.lowercased()
            if lower.hasPrefix("session") && isJSONLOrCompressedJSONL(lower) {
                return url
            }
        }
        return nil
    }

    private static func findBoundedMetadataFiles(
        in rootURL: URL,
        maxDepth: Int,
        maxFiles: Int,
        extensions: Set<String>,
        fileManager: FileManager
    ) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(rootURL, 0)]
        var visitedDirs = 0
        let maxDirsToVisit = 32

        while !queue.isEmpty && found.count < maxFiles && visitedDirs < maxDirsToVisit {
            let (dir, depth) = queue.removeFirst()
            visitedDirs += 1
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                if values?.isRegularFile == true {
                    let ext = child.pathExtension.lowercased()
                    if extensions.contains(ext) {
                        found.append(child)
                        if found.count >= maxFiles { break }
                    }
                } else if values?.isDirectory == true && depth < maxDepth {
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }

    private static func describeImageDirectoryCount(
        at dirURL: URL,
        fallbackFileCount: Int,
        fileManager: FileManager
    ) -> String? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fallbackFileCount > 0 ? "\(fallbackFileCount) 个文件" : nil
        }

        var imageCount = 0
        var totalRegular = 0
        for child in children {
            let isRegular = (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            totalRegular += 1
            if imageExtensions.contains(child.pathExtension.lowercased()) {
                imageCount += 1
            }
        }
        if imageCount > 0 {
            return "\(imageCount) 张图片"
        }
        let count = max(totalRegular, fallbackFileCount)
        return count > 0 ? "\(count) 个文件" : nil
    }

    static func isJSONLOrCompressedJSONL(_ lowerFileName: String) -> Bool {
        lowerFileName.hasSuffix(".jsonl")
            || lowerFileName.hasSuffix(".jsonl.zst")
            || lowerFileName.hasSuffix(".jsonl.zstd")
    }

    static func isUUIDNamedEntry(_ name: String, isDirectory: Bool) -> Bool {
        let stem = stripKnownSessionExtensions(from: name, isDirectory: isDirectory)
        return UUID(uuidString: stem) != nil
    }

    static func extractSessionIdentifier(from name: String, isDirectory: Bool) -> String? {
        let stem = stripKnownSessionExtensions(from: name, isDirectory: isDirectory)
        if UUID(uuidString: stem) != nil {
            return stem.lowercased()
        }
        if stem.hasPrefix("rollout-"), let uuid = parseCodexRolloutName(name).id {
            return uuid.uuidString.lowercased()
        }
        if stem.hasPrefix("session-") {
            let tail = String(stem.dropFirst("session-".count))
            if UUID(uuidString: tail) != nil {
                return tail.lowercased()
            }
        }
        if stem.hasPrefix("draft-") {
            let tail = String(stem.dropFirst("draft-".count))
            if UUID(uuidString: tail) != nil {
                return tail.lowercased()
            }
        }
        if let uuid = extractEmbeddedUUID(from: stem) {
            return uuid
        }
        if stem.hasPrefix("ses_") || stem.hasPrefix("sess_") {
            return stem.lowercased()
        }
        return nil
    }

    private static func stripKnownSessionExtensions(from name: String, isDirectory: Bool) -> String {
        if isDirectory { return name }
        let suffixes = [".file-rollback.ndjson", ".jsonl.zstd", ".jsonl.zst", ".jsonl", ".ndjson", ".json", ".txt", ".log", ".pb"]
        let lower = name.lowercased()
        for suffix in suffixes where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    private static func extractEmbeddedUUID(from text: String) -> String? {
        // 匹配 8-4-4-4-12 标准 UUID
        guard text.count >= 36 else { return nil }
        let chars = Array(text)
        let limit = chars.count - 36
        var idx = 0
        while idx <= limit {
            if chars[idx + 8] == "-"
                && chars[idx + 13] == "-"
                && chars[idx + 18] == "-"
                && chars[idx + 23] == "-" {
                let candidate = String(chars[idx..<(idx + 36)])
                if UUID(uuidString: candidate) != nil {
                    return candidate.lowercased()
                }
            }
            idx += 1
        }
        return nil
    }

    private static func openRegularFile(_ url: URL) -> FileHandle? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return try? FileHandle(forReadingFrom: url)
    }

    private static func readBoundedRegularFile(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = openRegularFile(url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        return data
    }

    private static func parseJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func cleanYAMLValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            if value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeHexData(_ hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let next = trimmed.index(idx, offsetBy: 2)
            guard let byte = UInt8(trimmed[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }

    private static func extractCWD(from json: [String: Any]) -> String? {
        if let direct = nonBlank(json["cwd"]) {
            return direct
        }
        if let payload = json["payload"] as? [String: Any], let cwd = nonBlank(payload["cwd"]) {
            return cwd
        }
        if let data = json["data"] as? [String: Any] {
            if let cwd = nonBlank(data["cwd"]) {
                return cwd
            }
            if let context = data["context"] as? [String: Any], let cwd = nonBlank(context["cwd"]) {
                return cwd
            }
        }
        return nil
    }

    private static func projectName(fromPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let last = url.lastPathComponent
        guard !last.isEmpty && last != "/" else { return nil }
        // 若末级目录为通用 workdir / worktree，补充上一级任务目录名以提高辨识度
        if last == "workdir" || last == "worktree" {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty && parent != "/" {
                return parent
            }
        }
        return last
    }

    private static func readableProjectToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { return nil }
        if trimmed.contains("/") {
            return projectName(fromPath: trimmed)
        }
        return trimmed
    }

    private static func parseWorkspaceURIs(_ raw: String?) -> (projectName: String?, path: String?) {
        guard let raw = nonBlank(raw) else { return (nil, nil) }
        var uriStrings: [String] = []
        if raw.hasPrefix("["),
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
            uriStrings = parsed
        } else {
            uriStrings = [raw]
        }

        let paths: [String] = uriStrings.compactMap { uri in
            if let url = URL(string: uri), url.isFileURL {
                return url.path
            }
            if uri.hasPrefix("/") {
                return uri
            }
            return nil
        }

        // 优先选择真实项目路径，跳过系统临时桥接目录
        let preferred = paths.first { path in
            !path.hasPrefix("/private/var/folders/")
                && !path.hasPrefix("/var/folders/")
                && !path.hasPrefix("/tmp/")
                && !path.hasPrefix("/private/tmp/")
        } ?? paths.first

        guard let preferred else { return (nil, nil) }
        return (projectName(fromPath: preferred), preferred)
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
        if stem.hasPrefix("session-"), stem.count > 8 {
            let after = stem.dropFirst("session-".count)
            if after.count >= 8 {
                return String(after.prefix(8))
            }
        }
        return String(stem.prefix(8))
    }

    private static func parseCodexRolloutName(_ fileName: String) -> (dateText: String?, shortID: String, id: UUID?) {
        // rollout-2026-11-02T08-42-37-01a199b5-4a6f-7591-af48-46874459a62c.jsonl(.zst/.zstd)
        var stem = fileName
        let lower = fileName.lowercased()
        if lower.hasSuffix(".jsonl.zstd") {
            stem = String(stem.dropLast(".jsonl.zstd".count))
        } else if lower.hasSuffix(".jsonl.zst") {
            stem = String(stem.dropLast(".jsonl.zst".count))
        } else if lower.hasSuffix(".jsonl") {
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
        //    以及 Claude transcripts: {"type":"user", "timestamp":..., "content":...}
        if type == "user" {
            if (json["isSidechain"] as? Bool) == true { return nil }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] {
                return extractText(from: content)
            }
            if let content = json["content"] {
                return extractText(from: content)
            }
        }

        // 2. Pi / Multica / WorkBuddy / Codex 2025
        if type == "message" {
            if let message = json["message"] as? [String: Any],
               (message["role"] as? String) == "user",
               let content = message["content"] {
                return extractText(from: content)
            }
            if (json["role"] as? String) == "user", let content = json["content"] {
                return extractText(from: content)
            }
        }

        // 3. Codex 2026: {"type":"response_item", "payload":{"type":"message","role":"user","content":...}}
        if type == "response_item",
           let payload = json["payload"] as? [String: Any],
           (payload["type"] as? String) == "message",
           (payload["role"] as? String) == "user",
           let content = payload["content"] {
            return extractText(from: content)
        }

        // 4. Codex event_msg: {"type":"event_msg", "payload":{"type":"user_message","message":"..."}}
        if type == "event_msg",
           let payload = json["payload"] as? [String: Any],
           (payload["type"] as? String) == "user_message",
           let message = payload["message"] {
            return extractText(from: message)
        }

        // 5. DeepSeek Harness: {"type":"user/message", "data":{"content":..., "role":"user"}}
        if type == "user/message",
           let data = json["data"] as? [String: Any],
           let content = data["content"] {
            return extractText(from: content)
        }

        // 6. GitHub Copilot CLI: {"type":"user.message", "data":{"content":"..."}}
        if type == "user.message",
           let data = json["data"] as? [String: Any] {
            if let content = data["content"], let text = extractText(from: content) {
                return text
            }
            if let transformed = data["transformedContent"], let text = extractText(from: transformed) {
                return text
            }
        }

        // 7. Jan messages.jsonl: {"role":"user","content":...}
        if type == nil, (json["role"] as? String) == "user", let content = json["content"] {
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
                if let textDict = block["text"] as? [String: Any],
                   let value = textDict["value"] as? String,
                   let candidate = sanitizePromptSnippet(value) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static let ignoredPromptPrefixes = [
        "<environment_context>",
        "<INSTRUCTIONS>",
        "<system-reminder",
        "<recommended_plugins>",
        "<app-context>",
        "<skills_instructions>",
        "<plugins_instructions>",
        "<apps_instructions>",
        "<permissions",
        "<multi_agent_mode>",
        "<collaboration_mode>",
        "<turn_aborted>",
        "<user_shell_command>",
        "<local-command-",
        "<command-name>",
        "<command-message>",
        "<command-args>",
        "<task-notification>",
        "<USER_REQUEST>",
        "<external_system_instructions>",
        "# AGENTS.md",
        "<!-- BEGIN "
    ]

    private static func sanitizePromptSnippet(_ raw: String) -> String? {
        collapseAndTruncateText(raw, maxCharacters: maxSnippetCharacters)
    }

    private static func sanitizeDatabaseTitle(_ raw: String) -> String? {
        collapseAndTruncateText(raw, maxCharacters: maxSanitizedTitleCharacters)
    }

    /// O(maxCharacters) 单遍空白折叠与截断：跳过系统模板块，避免对数十 KB 提示词运行正则替换
    private static func collapseAndTruncateText(_ raw: String, maxCharacters: Int) -> String? {
        let trimmedStart = raw.drop(while: \.isWhitespace)
        guard !trimmedStart.isEmpty else { return nil }

        for prefix in ignoredPromptPrefixes where trimmedStart.hasPrefix(prefix) {
            return nil
        }

        var result = ""
        result.reserveCapacity(maxCharacters + 1)
        var count = 0
        var pendingSpace = false
        var truncated = false

        for ch in trimmedStart {
            if ch.isWhitespace {
                if count > 0 {
                    pendingSpace = true
                }
                continue
            }
            if pendingSpace {
                if count >= maxCharacters {
                    truncated = true
                    break
                }
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            if count >= maxCharacters {
                truncated = true
                break
            }
            result.append(ch)
            count += 1
        }

        guard count > 0 else { return nil }
        return truncated ? result + "…" : result
    }
}
