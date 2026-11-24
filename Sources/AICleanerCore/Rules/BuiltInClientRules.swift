import Foundation

/// 内置 macOS AI 客户端扫描规则清单（可扩展架构，默认覆盖 31 款国内外主流 AI 客户端）。
/// 每款客户端均清晰区分「建议清理」「按需清理」与「不建议清理（锁定保护）」，
/// 既帮用户放心释放缓存与一次性聊天会话，也透明展示核心配置、记忆、插件与主数据库的体积占用。
public enum BuiltInClientRules {
    public static let allProfiles: [AIClientProfile] = [
        // 常用高频编程助手与工作伙伴
        claudeCode,
        codex,
        workBuddy,
        doubao,
        workDaddy,
        cursor,
        deepseekHarness,
        trae,
        qoder,
        lingma,
        kiro,
        zcode,
        windsurf,
        claudeDesktop,
        chatGPTDesktop,
        openCode,
        piAgent,
        geminiAntigravity,
        multica,
        githubCopilot,
        cherryStudio,
        anythingLLM,
        t3Code,
        stepFun,
        kimi,
        yuanbao,
        ollama,
        lmStudio,
        chatbox,
        janAI,
        zedAI
    ]

    // MARK: - Helper Builders

    static func protectedRule(
        id: String,
        displayName: String,
        path: String,
        reason: String
    ) -> ScanRule {
        ScanRule(
            id: id,
            displayName: displayName,
            path: path,
            category: .protectedData,
            mode: .directory,
            recommendation: .notRecommended,
            explanation: reason
        )
    }

    static func standardElectronCacheRules(
        prefix: String,
        appSupportRelativePath: String,
        includeCachedData: Bool = false
    ) -> [ScanRule] {
        var rules: [ScanRule] = [
            ScanRule(
                id: "\(prefix)-cache",
                displayName: "应用网络缓存 (Cache)",
                path: "\(appSupportRelativePath)/Cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "应用静态资源与网络缓存，清理后按需自动重建，不影响登录。"
            ),
            ScanRule(
                id: "\(prefix)-code-cache",
                displayName: "脚本编译缓存 (Code Cache)",
                path: "\(appSupportRelativePath)/Code Cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "JS/WASM 编译缓存，可安全移入废纸篓并在启动时重建。"
            ),
            ScanRule(
                id: "\(prefix)-gpu-cache",
                displayName: "GPU 渲染缓存",
                path: "\(appSupportRelativePath)/GPUCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "图形渲染管线缓存，重启自动重建。"
            ),
            ScanRule(
                id: "\(prefix)-gpu-persistent-cache",
                displayName: "GPU 持久缓存",
                path: "\(appSupportRelativePath)/GPUPersistentCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "持久化图形渲染缓存，建议清理。"
            ),
            ScanRule(
                id: "\(prefix)-shader-cache",
                displayName: "着色器缓存 (GrShaderCache)",
                path: "\(appSupportRelativePath)/GrShaderCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Skia/图形着色器编译缓存，建议清理。"
            ),
            ScanRule(
                id: "\(prefix)-graphite-dawn-cache",
                displayName: "Graphite Dawn 缓存",
                path: "\(appSupportRelativePath)/GraphiteDawnCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "图形引擎着色器缓存，可安全清理。"
            ),
            ScanRule(
                id: "\(prefix)-dawn-graphite",
                displayName: "Dawn Graphite 缓存",
                path: "\(appSupportRelativePath)/DawnGraphiteCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "图形后端着色器缓存，可安全清理。"
            ),
            ScanRule(
                id: "\(prefix)-dawn-webgpu",
                displayName: "Dawn WebGPU 缓存",
                path: "\(appSupportRelativePath)/DawnWebGPUCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "WebGPU 图形缓存，可安全清理。"
            ),
            ScanRule(
                id: "\(prefix)-crashpad",
                displayName: "崩溃转储日志 (Crashpad)",
                path: "\(appSupportRelativePath)/Crashpad",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "应用异常退出时收集的崩溃诊断文件，建议定期清理。"
            ),
            ScanRule(
                id: "\(prefix)-app-logs",
                displayName: "应用运行日志",
                path: "\(appSupportRelativePath)/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "按日期归档的客户端运行日志，清理不影响业务数据。"
            )
        ]

        if includeCachedData {
            rules.append(contentsOf: [
                ScanRule(
                    id: "\(prefix)-cached-data",
                    displayName: "字节码缓存 (CachedData)",
                    path: "\(appSupportRelativePath)/CachedData",
                    category: .cache,
                    mode: .directory,
                    recommendation: .recommended,
                    explanation: "V8 字节码与内置脚本缓存，体积常较大，启动后自动重建。"
                ),
                ScanRule(
                    id: "\(prefix)-cached-vsix",
                    displayName: "扩展安装包缓存 (CachedExtensionVSIXs)",
                    path: "\(appSupportRelativePath)/CachedExtensionVSIXs",
                    category: .temporary,
                    mode: .directory,
                    recommendation: .recommended,
                    explanation: "插件安装/更新后遗留的 VSIX 压缩包，不影响已安装扩展。"
                )
            ])
        }

        return rules
    }

    // MARK: - 国际主流 AI 客户端与本地模型工具

    public static let claudeCode = AIClientProfile(
        id: "claude-code",
        name: "Claude Code",
        symbolName: "terminal",
        accentToken: "claude",
        description: "Anthropic 命令行编程助手的聊天会话、转录文件、调试日志与运行缓存",
        protectedSummary: "已锁定保护 ~/.claude.json、settings.json、CLAUDE.md、各项目 memory/、sessions-index.json、skills、plugins、hooks 与 history.jsonl",
        rules: [
            // 聊天会话
            ScanRule(
                id: "claude-code-project-sessions",
                displayName: "项目聊天会话",
                path: ".claude/projects",
                category: .sessions,
                mode: .projectSessions,
                recommendation: .reviewSuggested,
                explanation: "按单条对话展开各项目下的聊天会话（.jsonl 及子代理/产物目录），超过 14 天自动标为建议清理；已保护每个项目的 memory/ 与 sessions-index.json。"
            ),
            ScanRule(
                id: "claude-code-transcripts",
                displayName: "历史会话转录目录 (transcripts)",
                path: ".claude/transcripts",
                category: .sessions,
                mode: .directory,
                recommendation: .recommended,
                explanation: "自动留存的历史对话转录副本，长期累积体积较大，建议清理释放空间，不影响当前配置与记忆。"
            ),
            // 建议清理：缓存/日志/临时
            ScanRule(
                id: "claude-code-cli-cache",
                displayName: "CLI 与 MCP 运行缓存",
                path: "Library/Caches/claude-cli-nodejs",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Claude Code 及 MCP 服务器运行缓存与日志，建议清理，下次运行自动重建。"
            ),
            ScanRule(
                id: "claude-code-debug",
                displayName: "调试日志",
                path: ".claude/debug",
                category: .logs,
                mode: .children,
                recommendation: .recommended,
                explanation: "会话调试输出日志，移入废纸篓不影响历史会话与配置。"
            ),
            ScanRule(
                id: "claude-code-paste-cache",
                displayName: "剪贴板粘贴缓存",
                path: ".claude/paste-cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "终端大段文本粘贴生成的临时缓存，建议清理。"
            ),
            ScanRule(
                id: "claude-code-shell-snapshots",
                displayName: "Shell 环境快照",
                path: ".claude/shell-snapshots",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "一次性终端环境快照，下次启动自动重新捕获。"
            ),
            ScanRule(
                id: "claude-code-downloads",
                displayName: "临时下载目录",
                path: ".claude/downloads",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "客户端运行期间产生的临时下载包，建议清理。"
            ),
            ScanRule(
                id: "claude-code-session-env",
                displayName: "会话临时环境",
                path: ".claude/session-env",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "单次会话的临时环境变量文件，建议清理。"
            ),
            ScanRule(
                id: "claude-code-backups",
                displayName: "自动备份临时目录",
                path: ".claude/backups",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "配置更新时留存的历史备份副本，不影响当前生效的 settings.json。"
            ),
            // 按需清理
            ScanRule(
                id: "claude-code-file-history",
                displayName: "会话文件撤销快照 (file-history)",
                path: ".claude/file-history",
                category: .temporary,
                mode: .directory,
                recommendation: .reviewSuggested,
                explanation: "用于会话内撤销编辑的历史文件快照，确认无需回滚近期会话修改后可放心清理。"
            ),
            // 不建议清理（透明展示 + 锁定保护）
            protectedRule(
                id: "claude-code-protected-plugins",
                displayName: "已安装插件目录 (plugins)",
                path: ".claude/plugins",
                reason: "包含已安装的 Claude Code 插件与 MCP 市场组件，删除后需重新下载安装，不建议清理。"
            ),
            protectedRule(
                id: "claude-code-protected-skills",
                displayName: "自定义技能库 (skills)",
                path: ".claude/skills",
                reason: "包含个人或团队自定义的 Skills 提示词与脚本，不建议清理。"
            ),
            protectedRule(
                id: "claude-code-protected-history",
                displayName: "命令输入历史索引 (history.jsonl)",
                path: ".claude/history.jsonl",
                reason: "记录跨会话的快捷历史输入索引，不建议清理。"
            ),
            protectedRule(
                id: "claude-code-protected-settings",
                displayName: "核心配置文件 (settings.json)",
                path: ".claude/settings.json",
                reason: "包含权限、模型与 Hook 等核心配置，已锁定保护。"
            )
        ]
    )

    public static let codex = AIClientProfile(
        id: "codex",
        name: "Codex",
        symbolName: "cpu",
        accentToken: "codex",
        description: "OpenAI Codex CLI 与桌面端的聊天会话、临时产物、渲染缓存与日志",
        protectedSummary: "已锁定保护 auth.json、config.toml、AGENTS.md、memories、worktrees、plugins 与 SQLite 主数据库",
        rules: [
            // 聊天会话
            ScanRule(
                id: "codex-sessions",
                displayName: "聊天会话记录",
                path: ".codex/sessions",
                category: .sessions,
                mode: .recursiveFiles,
                recommendation: .reviewSuggested,
                explanation: "按单条对话展示本地会话（.jsonl 与 .jsonl.zst），超过 14 天或压缩归档自动标为建议清理。",
                allowedFileSuffixes: [".jsonl", ".jsonl.zst"]
            ),
            ScanRule(
                id: "codex-archived-sessions",
                displayName: "已归档聊天会话",
                path: ".codex/archived_sessions",
                category: .sessions,
                mode: .children,
                recommendation: .recommended,
                explanation: "已归档的历史压缩会话文件，建议清理释放空间。"
            ),
            ScanRule(
                id: "codex-multica-sessions",
                displayName: "工作区代理会话",
                path: ".codex/multica-sessions",
                category: .sessions,
                mode: .children,
                recommendation: .recommended,
                explanation: "自动化代理任务产生的一次性会话目录，任务完成后建议清理。"
            ),
            // 建议清理
            ScanRule(
                id: "codex-cli-tmp",
                displayName: "Codex 临时目录 (tmp)",
                path: ".codex/tmp",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "会话执行期间产生的大体积临时目录，建议优先清理。"
            ),
            ScanRule(
                id: "codex-cli-hidden-tmp",
                displayName: "Codex 隐藏临时目录 (.tmp)",
                path: ".codex/.tmp",
                category: .temporary,
                mode: .children,
                recommendation: .recommended,
                explanation: "运行过程产生的临时工作子项，已自动过滤敏感文件，建议清理。"
            ),
            ScanRule(
                id: "codex-cli-cache",
                displayName: "Codex CLI 缓存",
                path: ".codex/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "命令行运行缓存，清理后按需自动重新生成。"
            ),
            ScanRule(
                id: "codex-cli-log",
                displayName: "Codex 运行日志",
                path: ".codex/log",
                category: .logs,
                mode: .children,
                recommendation: .recommended,
                explanation: "Codex CLI 输出的文本日志文件，建议清理。"
            ),
            ScanRule(
                id: "codex-shell-snapshots",
                displayName: "Shell 环境快照",
                path: ".codex/shell_snapshots",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "一次性终端环境快照，下次启动自动重新采集。"
            ),
            ScanRule(
                id: "codex-generated-images",
                displayName: "一次性生成图片产物",
                path: ".codex/generated_images",
                category: .temporary,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "对话期间生成的本地图片缓存产物，如已导出或不再需要可勾选清理。"
            ),
            ScanRule(
                id: "codex-sys-cache",
                displayName: "系统级应用缓存 (Codex)",
                path: "Library/Caches/Codex",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 下的 Codex 浏览器与代码缓存，建议清理。"
            ),
            ScanRule(
                id: "codex-bundle-cache",
                displayName: "系统级网络与更新缓存",
                path: "Library/Caches/com.openai.codex",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "包含 URLCache 与 Sparkle 自动更新安装包缓存，建议清理。"
            ),
            ScanRule(
                id: "codex-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Codex",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 Codex 日志。"
            )
        ]
        + standardElectronCacheRules(prefix: "codex-desktop", appSupportRelativePath: "Library/Application Support/Codex")
        + [
            // 不建议清理（透明展示 + 锁定保护）
            protectedRule(
                id: "codex-protected-thread-db",
                displayName: "主对话索引库 (thread_history_1.sqlite)",
                path: ".codex/thread_history_1.sqlite",
                reason: "Codex 桌面端/CLI 的主会话索引 SQLite 数据库，删除会导致全部线程列表丢失，不建议清理。"
            ),
            protectedRule(
                id: "codex-protected-plugins",
                displayName: "已安装插件与技能组件 (plugins)",
                path: ".codex/plugins",
                reason: "包含已安装插件与扩展运行环境，删除后需重新安装，不建议清理。"
            ),
            protectedRule(
                id: "codex-protected-worktrees",
                displayName: "Git 代码工作树 (worktrees)",
                path: ".codex/worktrees",
                reason: "包含各任务的 Git Worktree 代码分支副本，可能存在未合并/未提交代码，不建议直接清理。"
            ),
            protectedRule(
                id: "codex-protected-memories",
                displayName: "长期记忆目录 (memories)",
                path: ".codex/memories",
                reason: "保存跨会话积累的长期偏好与项目记忆，不建议清理。"
            ),
            protectedRule(
                id: "codex-protected-auth",
                displayName: "登录凭据 (auth.json)",
                path: ".codex/auth.json",
                reason: "包含账号认证令牌，删除后需要重新登录，已锁定保护。"
            )
        ]
    )

    public static let cursor = AIClientProfile(
        id: "cursor",
        name: "Cursor",
        symbolName: "cursorarrow.rays",
        accentToken: "cursor",
        description: "Cursor AI 编辑器聊天会话、渲染缓存、更新包与运行日志",
        protectedSummary: "已锁定保护 User/settings.json、globalStorage、workspaceStorage、Cookies、Local Storage、extensions 与 ~/.cursor/mcp.json",
        rules: [
            ScanRule(
                id: "cursor-chats",
                displayName: "CLI 聊天会话",
                path: ".cursor/chats",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Cursor CLI 保存的单条本地聊天会话，确认一次性即可勾选移入废纸篓。"
            ),
            ScanRule(
                id: "cursor-projects",
                displayName: "项目会话与 MCP 缓存",
                path: ".cursor/projects",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "按项目存放的 Cursor 会话记录与 MCP 缓存目录，移入废纸篓不影响项目源码与编辑器设置。"
            ),
            ScanRule(
                id: "cursor-updater",
                displayName: "客户端更新包缓存",
                path: "Library/Application Support/cursor-updater",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "自动更新下载的安装包缓存，建议清理。"
            ),
            ScanRule(
                id: "cursor-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/Cursor",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS 系统 Caches 下的 Cursor 临时缓存，建议清理。"
            ),
            ScanRule(
                id: "cursor-shipit-cache",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "桌面端自动更新器下载的增量更新缓存，建议清理。"
            ),
            ScanRule(
                id: "cursor-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Cursor",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 Cursor 日志文件。"
            )
        ]
        + standardElectronCacheRules(prefix: "cursor", appSupportRelativePath: "Library/Application Support/Cursor", includeCachedData: true)
        + [
            protectedRule(
                id: "cursor-protected-extensions",
                displayName: "已安装编辑器扩展 (extensions)",
                path: ".cursor/extensions",
                reason: "包含已安装的所有 VSCode/Cursor 插件，删除后编辑器需重新安装全部扩展，不建议清理。"
            ),
            protectedRule(
                id: "cursor-protected-skills",
                displayName: "自定义技能库 (skills)",
                path: ".cursor/skills",
                reason: "保存自定义 AI 技能与工作流规则，不建议清理。"
            ),
            protectedRule(
                id: "cursor-protected-mcp",
                displayName: "MCP 配置 (mcp.json)",
                path: ".cursor/mcp.json",
                reason: "包含 MCP 服务器连接与密钥配置，已锁定保护。"
            ),
            protectedRule(
                id: "cursor-protected-cookies",
                displayName: "登录态与 Cookie (Cookies)",
                path: "Library/Application Support/Cursor/Cookies",
                reason: "包含账号登录态，删除将导致重新登录，已锁定保护。"
            )
        ]
    )

    public static let windsurf = AIClientProfile(
        id: "windsurf",
        name: "Windsurf",
        symbolName: "wind",
        accentToken: "windsurf",
        description: "Windsurf / Codeium 聊天会话、编辑器缓存、扩展缓存与运行日志",
        protectedSummary: "已锁定保护 ~/.codeium/database、memories、User/settings.json、Cookies 与 Local Storage",
        rules: [
            ScanRule(
                id: "windsurf-cascade-sessions",
                displayName: "Cascade 聊天会话",
                path: ".codeium/windsurf/cascade",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Windsurf Cascade 单条对话记录文件，确认一次性后可移入废纸篓。"
            ),
            ScanRule(
                id: "windsurf-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/Windsurf",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Windsurf 缓存，建议清理。"
            ),
            ScanRule(
                id: "windsurf-shipit-cache",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.exafunction.windsurf.ShipIt",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "自动更新器留存的安装包缓存，建议清理。"
            ),
            ScanRule(
                id: "windsurf-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Windsurf",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 Windsurf 日志。"
            ),
            ScanRule(
                id: "windsurf-codeium-logs",
                displayName: "Codeium 引擎日志",
                path: ".codeium/windsurf/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Codeium 语言服务日志，建议清理。"
            ),
            ScanRule(
                id: "windsurf-codeium-cache",
                displayName: "Codeium 临时缓存",
                path: ".codeium/windsurf/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Codeium 本地临时缓存，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "windsurf", appSupportRelativePath: "Library/Application Support/Windsurf", includeCachedData: true)
        + [
            protectedRule(
                id: "windsurf-protected-database",
                displayName: "Codeium 本地索引数据库 (database)",
                path: ".codeium/database",
                reason: "包含代码库语义索引与上下文核心数据库，删除将导致重建全部索引，不建议清理。"
            ),
            protectedRule(
                id: "windsurf-protected-memories",
                displayName: "用户记忆库 (memories)",
                path: ".codeium/memories",
                reason: "包含跨会话保存的记忆与规则，不建议清理。"
            )
        ]
    )

    public static let claudeDesktop = AIClientProfile(
        id: "claude-desktop",
        name: "Claude Desktop",
        symbolName: "bubble.left.and.text.bubble.right",
        accentToken: "claudeDesktop",
        description: "Claude macOS 桌面应用本地会话、缓存、更新包与崩溃日志",
        protectedSummary: "已锁定保护 claude_desktop_config.json、config.json、Cookies、Local Storage 与 Session Storage",
        rules: [
            ScanRule(
                id: "claude-desktop-local-agent-sessions",
                displayName: "本地 Agent 会话",
                path: "Library/Application Support/Claude/local-agent-mode-sessions",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Claude Desktop 本地代理模式保存的单次会话目录，确认一次性后可清理。"
            ),
            ScanRule(
                id: "claude-desktop-code-sessions",
                displayName: "桌面端 Code 会话",
                path: "Library/Application Support/Claude/claude-code-sessions",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Claude Desktop 内置代码助手会话目录，移入废纸篓不影响应用配置。"
            ),
            ScanRule(
                id: "claude-desktop-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/com.anthropic.claudefordesktop",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 下的 Claude Desktop 缓存，建议清理。"
            ),
            ScanRule(
                id: "claude-desktop-shipit",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.anthropic.claudefordesktop.ShipIt",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "桌面端自动更新下载的临时更新包，建议清理。"
            ),
            ScanRule(
                id: "claude-desktop-logs",
                displayName: "应用运行日志",
                path: "Library/Logs/Claude",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "包含 MCP 与客户端主进程运行日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "claude-desktop", appSupportRelativePath: "Library/Application Support/Claude")
        + [
            protectedRule(
                id: "claude-desktop-protected-config",
                displayName: "MCP 与桌面端配置 (claude_desktop_config.json)",
                path: "Library/Application Support/Claude/claude_desktop_config.json",
                reason: "保存已接入的 MCP 服务器列表与环境变量，已锁定保护。"
            ),
            protectedRule(
                id: "claude-desktop-protected-storage",
                displayName: "本地存储与登录态 (Local Storage)",
                path: "Library/Application Support/Claude/Local Storage",
                reason: "包含桌面端登录与偏好状态，删除后需要重新登录，不建议清理。"
            )
        ]
    )

    public static let chatGPTDesktop = AIClientProfile(
        id: "chatgpt-desktop",
        name: "ChatGPT Desktop",
        symbolName: "sparkles",
        accentToken: "chatgpt",
        description: "ChatGPT macOS 桌面应用缓存、辅助进程日志与更新包",
        protectedSummary: "已锁定保护 Keychain 凭据、HTTPStorages、Cookies、Preferences 及配对扩展配置",
        rules: [
            ScanRule(
                id: "chatgpt-sys-cache",
                displayName: "应用系统缓存",
                path: "Library/Caches/com.openai.chat",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "ChatGPT macOS 客户端网络与资源缓存，建议清理，不影响登录状态。"
            ),
            ScanRule(
                id: "chatgpt-shipit",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.openai.chat.ShipIt",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "客户端更新器下载的临时更新文件，建议清理。"
            ),
            ScanRule(
                id: "chatgpt-helper-cache",
                displayName: "ChatGPTHelper 缓存与诊断",
                path: "Library/Caches/ChatGPTHelper",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "辅助进程产生的异步日志与诊断缓存，建议清理。"
            ),
            ScanRule(
                id: "chatgpt-app-cache",
                displayName: "本地应用缓存",
                path: "Library/Application Support/com.openai.chat/Cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "本地静态资源缓存目录，建议清理。"
            ),
            ScanRule(
                id: "chatgpt-app-logs",
                displayName: "本地运行日志",
                path: "Library/Application Support/com.openai.chat/Logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "桌面应用本地诊断日志，建议清理。"
            ),
            ScanRule(
                id: "chatgpt-sys-logs",
                displayName: "系统日志 (com.openai.chat)",
                path: "Library/Logs/com.openai.chat",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 ChatGPT 运行日志。"
            ),
            ScanRule(
                id: "chatgpt-named-logs",
                displayName: "系统日志 (ChatGPT)",
                path: "Library/Logs/ChatGPT",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 ChatGPT 辅助日志。"
            ),
            protectedRule(
                id: "chatgpt-protected-pairing",
                displayName: "应用配对扩展配置 (app_pairing_extensions)",
                path: "Library/Application Support/com.openai.chat/app_pairing_extensions",
                reason: "用于“与编辑器协同工作”的桌面扩展授权配置，不建议清理。"
            )
        ]
    )

    public static let openCode = AIClientProfile(
        id: "opencode",
        name: "OpenCode",
        symbolName: "chevron.left.forwardslash.chevron.right",
        accentToken: "opencode",
        description: "OpenCode CLI 的会话文件、运行日志与临时缓存目录",
        protectedSummary: "已锁定保护 ~/.local/share/opencode/opencode.db 主数据库、~/.opencode/bin 与认证配置",
        rules: [
            ScanRule(
                id: "opencode-file-sessions",
                displayName: "文件型聊天会话",
                path: ".local/share/opencode/storage/session",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "OpenCode 文件存储模式下的单条会话记录，清理不影响 opencode.db 主库。"
            ),
            ScanRule(
                id: "opencode-logs",
                displayName: "OpenCode 运行日志",
                path: ".local/share/opencode/log",
                category: .logs,
                mode: .children,
                recommendation: .recommended,
                explanation: "OpenCode CLI 会话与调试日志文件，建议清理，不影响历史主库。"
            ),
            ScanRule(
                id: "opencode-xdg-cache",
                displayName: "OpenCode 缓存目录",
                path: ".cache/opencode",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "XDG 缓存目录中的下载与构建缓存，建议清理。"
            ),
            ScanRule(
                id: "opencode-mac-cache",
                displayName: "系统级缓存",
                path: "Library/Caches/opencode",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 下的 OpenCode 缓存。"
            ),
            ScanRule(
                id: "opencode-tmp",
                displayName: "临时目录",
                path: ".opencode/tmp",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "OpenCode 运行产生的临时文件。"
            ),
            protectedRule(
                id: "opencode-protected-db",
                displayName: "OpenCode 主数据库 (opencode.db)",
                path: ".local/share/opencode/opencode.db",
                reason: "存储全部历史会话记录的 SQLite 主库，删除会清空全部对话，不建议清理。"
            ),
            protectedRule(
                id: "opencode-protected-bin",
                displayName: "OpenCode 运行时二进制 (bin)",
                path: ".opencode/bin",
                reason: "包含 CLI 核心二进制组件，删除后需重新下载，不建议清理。"
            )
        ]
    )

    public static let piAgent = AIClientProfile(
        id: "pi",
        name: "Pi",
        symbolName: "terminal.fill",
        accentToken: "pi",
        description: "Pi Coding Agent 各工作区的本地聊天会话记录",
        protectedSummary: "已锁定保护 ~/.pi/agent/auth.json、settings.json、models.json、mcp.json、skills 与 extensions",
        rules: [
            ScanRule(
                id: "pi-agent-sessions",
                displayName: "工作区聊天会话",
                path: ".pi/agent/sessions",
                category: .sessions,
                mode: .projectSessions,
                recommendation: .reviewSuggested,
                explanation: "按项目工作区展开单条 Pi 聊天会话（.jsonl），自动提取项目名与首条提问摘要；超过 14 天自动标为建议清理。"
            ),
            protectedRule(
                id: "pi-protected-auth",
                displayName: "认证凭据 (auth.json)",
                path: ".pi/agent/auth.json",
                reason: "包含模型接口认证凭据，已锁定保护。"
            ),
            protectedRule(
                id: "pi-protected-extensions",
                displayName: "自定义扩展 (extensions)",
                path: ".pi/agent/extensions",
                reason: "包含本地安装的 Pi 扩展脚本，不建议清理。"
            ),
            protectedRule(
                id: "pi-protected-skills",
                displayName: "技能库 (skills)",
                path: ".pi/agent/skills",
                reason: "包含自定义 Skills 提示词与工具，不建议清理。"
            )
        ]
    )

    public static let geminiAntigravity = AIClientProfile(
        id: "gemini-antigravity",
        name: "Gemini / Antigravity",
        symbolName: "sparkle",
        accentToken: "gemini",
        description: "Gemini CLI 与 Antigravity 桌面端/CLI 的会话工作区、缓存及临时目录",
        protectedSummary: "已锁定保护 oauth_creds.json、google_accounts.json、settings.json、skills 与 conversation_summaries.db 主数据库",
        rules: [
            ScanRule(
                id: "gemini-antigravity-brain",
                displayName: "Antigravity 会话工作区",
                path: ".gemini/antigravity/brain",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "单次对话产生的本地产物与草稿目录，超过 14 天自动标为建议清理。"
            ),
            ScanRule(
                id: "gemini-antigravity-cli-brain",
                displayName: "Antigravity CLI 会话工作区",
                path: ".gemini/antigravity-cli/brain",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "命令行会话产生的独立临时工作区目录，任务完成后可勾选清理。"
            ),
            ScanRule(
                id: "gemini-antigravity-cache",
                displayName: "Antigravity 运行缓存",
                path: ".gemini/antigravity/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Antigravity 运行缓存目录，建议清理，按需自动重建。"
            ),
            ScanRule(
                id: "gemini-cli-tmp",
                displayName: "Gemini CLI 临时会话目录",
                path: ".gemini/tmp",
                category: .temporary,
                mode: .children,
                recommendation: .recommended,
                explanation: "Gemini CLI 运行期间产生的临时目录与中间文件，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "antigravity-desktop", appSupportRelativePath: "Library/Application Support/Antigravity")
        + [
            protectedRule(
                id: "gemini-protected-summaries-db",
                displayName: "会话摘要主数据库 (conversation_summaries.db)",
                path: ".gemini/antigravity/conversation_summaries.db",
                reason: "存储对话历史索引与摘要的 SQLite 主数据库，不建议清理。"
            ),
            protectedRule(
                id: "gemini-protected-oauth",
                displayName: "Google 登录凭据 (oauth_creds.json)",
                path: ".gemini/oauth_creds.json",
                reason: "包含账号 OAuth 认证令牌，删除后需要重新授权登录，已锁定保护。"
            )
        ]
    )

    public static let kiro = AIClientProfile(
        id: "kiro",
        name: "Kiro",
        symbolName: "wand.and.stars",
        accentToken: "kiro",
        description: "AWS Kiro AI IDE 的应用缓存、更新包与运行日志",
        protectedSummary: "已锁定保护 ~/.kiro/extensions、skills、steering 与 settings",
        rules: [
            ScanRule(
                id: "kiro-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/Kiro",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Kiro 缓存，建议清理。"
            ),
            ScanRule(
                id: "kiro-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Kiro",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Logs 目录下的 Kiro 日志。"
            )
        ]
        + standardElectronCacheRules(prefix: "kiro", appSupportRelativePath: "Library/Application Support/Kiro", includeCachedData: true)
        + [
            protectedRule(
                id: "kiro-protected-extensions",
                displayName: "已安装扩展目录 (extensions)",
                path: ".kiro/extensions",
                reason: "包含 Kiro 已安装的编辑器扩展，体积较大但删除后需全部重装，不建议清理。"
            ),
            protectedRule(
                id: "kiro-protected-steering",
                displayName: "规则与技能目录 (steering)",
                path: ".kiro/steering",
                reason: "保存自定义项目引导规则，不建议清理。"
            )
        ]
    )

    public static let githubCopilot = AIClientProfile(
        id: "copilot",
        name: "GitHub Copilot",
        symbolName: "chevron.left.slash.chevron.right",
        accentToken: "copilot",
        description: "GitHub Copilot CLI 与本地代理的会话状态、缓存和运行日志",
        protectedSummary: "已锁定保护 ~/.copilot/mcp-config.json、skills 与 installed-plugins",
        rules: [
            ScanRule(
                id: "copilot-session-state",
                displayName: "Copilot 会话状态",
                path: ".copilot/session-state",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Copilot CLI 保存的单条本地会话状态，确认一次性即可移入废纸篓。"
            ),
            ScanRule(
                id: "copilot-logs",
                displayName: "Copilot 运行日志",
                path: ".copilot/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Copilot 运行诊断日志，建议清理。"
            ),
            ScanRule(
                id: "copilot-sys-cache",
                displayName: "系统级 Copilot 缓存",
                path: "Library/Caches/copilot",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Copilot 缓存，建议清理。"
            ),
            protectedRule(
                id: "copilot-protected-mcp",
                displayName: "MCP 配置 (mcp-config.json)",
                path: ".copilot/mcp-config.json",
                reason: "包含 MCP 服务配置，已锁定保护。"
            ),
            protectedRule(
                id: "copilot-protected-plugins",
                displayName: "已安装插件 (installed-plugins)",
                path: ".copilot/installed-plugins",
                reason: "包含已安装 Copilot 插件，不建议清理。"
            )
        ]
    )

    public static let multica = AIClientProfile(
        id: "multica",
        name: "Multica",
        symbolName: "square.stack.3d.up.fill",
        accentToken: "multica",
        description: "Multica 桌面端缓存、自动更新包与本地代理会话记录",
        protectedSummary: "已锁定保护 IndexedDB、Local Storage、Session Storage、~/.multica/profiles 与 daemon.id",
        rules: [
            ScanRule(
                id: "multica-pi-sessions",
                displayName: "本地代理会话 (pi-sessions)",
                path: ".multica/pi-sessions",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "本地代理执行产生的单次会话目录，历史任务完成后可按需移入废纸篓。"
            ),
            ScanRule(
                id: "multica-updater-cache",
                displayName: "桌面端更新包缓存",
                path: "Library/Caches/@multicadesktop-updater",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "自动更新器下载的临时安装包缓存，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "multica", appSupportRelativePath: "Library/Application Support/Multica")
        + [
            protectedRule(
                id: "multica-protected-profiles",
                displayName: "工作区配置与身份 (profiles)",
                path: ".multica/profiles",
                reason: "保存工作区运行配置与认证信息，删除后需重新配置守护进程，不建议清理。"
            ),
            protectedRule(
                id: "multica-protected-indexeddb",
                displayName: "本地应用状态 (IndexedDB)",
                path: "Library/Application Support/Multica/IndexedDB",
                reason: "保存桌面端登录与界面本地状态，不建议清理。"
            )
        ]
    )

    public static let cherryStudio = AIClientProfile(
        id: "cherry-studio",
        name: "Cherry Studio",
        symbolName: "heart.circle.fill",
        accentToken: "cherry",
        description: "Cherry Studio 多模型桌面客户端缓存与日志",
        protectedSummary: "已锁定保护 IndexedDB 对话库、Local Storage、~/.cherrystudio/bin 与 mcp 配置",
        rules: [
            ScanRule(
                id: "cherry-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/CherryStudio",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Cherry Studio 缓存，建议清理。"
            ),
            ScanRule(
                id: "cherry-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/CherryStudio",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Cherry Studio 运行日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "cherry", appSupportRelativePath: "Library/Application Support/CherryStudio")
        + [
            protectedRule(
                id: "cherry-protected-bin",
                displayName: "内置工具二进制 (bin)",
                path: ".cherrystudio/bin",
                reason: "包含 Cherry Studio 内置运行时工具（如 uv/bun），删除后需重新下载，不建议清理。"
            ),
            protectedRule(
                id: "cherry-protected-indexeddb",
                displayName: "本地聊天与知识库数据 (IndexedDB)",
                path: "Library/Application Support/CherryStudio/IndexedDB",
                reason: "保存本地全部聊天记录、API Key 配置与助手设置，已锁定保护。"
            )
        ]
    )

    public static let anythingLLM = AIClientProfile(
        id: "anythingllm",
        name: "AnythingLLM",
        symbolName: "books.vertical.fill",
        accentToken: "anythingllm",
        description: "AnythingLLM 本地知识库桌面端渲染缓存与日志",
        protectedSummary: "已锁定保护 storage 向量知识库、databases、Local Storage 与 Cookies",
        rules: [
            ScanRule(
                id: "anythingllm-dawn-cache",
                displayName: "Dawn 图形缓存",
                path: "Library/Application Support/anythingllm-desktop/DawnCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "图形渲染缓存，建议清理。"
            ),
            ScanRule(
                id: "anythingllm-sys-logs",
                displayName: "运行日志",
                path: "Library/Logs/anythingllm-desktop",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "桌面端诊断日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "anythingllm", appSupportRelativePath: "Library/Application Support/anythingllm-desktop")
        + [
            protectedRule(
                id: "anythingllm-protected-storage",
                displayName: "本地知识库与向量存储 (storage)",
                path: "Library/Application Support/anythingllm-desktop/storage",
                reason: "保存已上传文档、向量索引与对话数据库，删除将丢失全部知识库，已锁定保护。"
            )
        ]
    )

    public static let t3Code = AIClientProfile(
        id: "t3-code",
        name: "T3 Code",
        symbolName: "bolt.horizontal.circle.fill",
        accentToken: "t3",
        description: "T3 Code 编程助手桌面缓存与运行缓存",
        protectedSummary: "已锁定保护 ~/.t3/tools、userdata、worktrees 与桌面端登录态",
        rules: [
            ScanRule(
                id: "t3-cli-caches",
                displayName: "T3 本地缓存 (caches)",
                path: ".t3/caches",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "T3 运行缓存，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "t3code", appSupportRelativePath: "Library/Application Support/t3code-v2")
        + [
            protectedRule(
                id: "t3-protected-tools",
                displayName: "内置运行时工具 (tools)",
                path: ".t3/tools",
                reason: "包含内置 CLI 工具链，删除后需重新下载，不建议清理。"
            ),
            protectedRule(
                id: "t3-protected-userdata",
                displayName: "用户核心数据 (userdata)",
                path: ".t3/userdata",
                reason: "包含本地配置与项目元数据，不建议清理。"
            )
        ]
    )

    public static let ollama = AIClientProfile(
        id: "ollama",
        name: "Ollama",
        symbolName: "cube.transparent.fill",
        accentToken: "ollama",
        description: "Ollama 本地大模型运行时日志（自动保护已下载大模型权重与密钥）",
        protectedSummary: "已锁定保护 ~/.ollama/models 本地模型权重与 SSH 密钥对 (id_ed25519)",
        rules: [
            ScanRule(
                id: "ollama-logs",
                displayName: "Ollama 运行日志",
                path: ".ollama/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Ollama 推理服务运行日志，建议清理，不影响已下载模型。"
            ),
            protectedRule(
                id: "ollama-protected-models",
                displayName: "本地大模型权重库 (models)",
                path: ".ollama/models",
                reason: "包含已拉取的本地大模型权重文件，重新下载耗时极长，如需删除建议使用 `ollama rm`，不建议直接清理。"
            ),
            protectedRule(
                id: "ollama-protected-key",
                displayName: "节点身份私钥 (id_ed25519)",
                path: ".ollama/id_ed25519",
                reason: "Ollama 身份认证私钥，已锁定保护。"
            )
        ]
    )

    public static let lmStudio = AIClientProfile(
        id: "lm-studio",
        name: "LM Studio",
        symbolName: "cpu.fill",
        accentToken: "lmstudio",
        description: "LM Studio 本地大模型客户端缓存与运行日志",
        protectedSummary: "已锁定保护 ~/.lmstudio/models 与 ~/.cache/lm-studio/models 本地模型权重",
        rules: [
            ScanRule(
                id: "lmstudio-logs",
                displayName: "推理与服务日志",
                path: ".cache/lm-studio/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "LM Studio 本地服务日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "lmstudio", appSupportRelativePath: "Library/Application Support/LM Studio")
        + [
            protectedRule(
                id: "lmstudio-protected-models",
                displayName: "本地模型权重目录 (models)",
                path: ".lmstudio/models",
                reason: "存放已下载的 GGUF/MLX 模型文件，删除后需重新下载，不建议直接清理。"
            ),
            protectedRule(
                id: "lmstudio-protected-cache-models",
                displayName: "本地模型缓存目录 (cache/models)",
                path: ".cache/lm-studio/models",
                reason: "存放已下载的本地模型权重文件，不建议直接清理。"
            )
        ]
    )

    public static let chatbox = AIClientProfile(
        id: "chatbox",
        name: "Chatbox",
        symbolName: "ellipsis.bubble.fill",
        accentToken: "chatbox",
        description: "Chatbox 多模型桌面客户端缓存与日志",
        protectedSummary: "已锁定保护 Local Storage、IndexedDB 对话历史与 API Key 配置",
        rules: standardElectronCacheRules(prefix: "chatbox", appSupportRelativePath: "Library/Application Support/xyz.chatboxapp.app")
        + [
            protectedRule(
                id: "chatbox-protected-storage",
                displayName: "本地会话与密钥配置 (Local Storage)",
                path: "Library/Application Support/xyz.chatboxapp.app/Local Storage",
                reason: "保存聊天记录与各模型 API Key，已锁定保护。"
            )
        ]
    )

    public static let janAI = AIClientProfile(
        id: "jan",
        name: "Jan",
        symbolName: "brain.head.profile",
        accentToken: "jan",
        description: "Jan 离线 AI 客户端缓存、日志与历史会话线程",
        protectedSummary: "已锁定保护 ~/jan/models 本地模型权重与核心设置",
        rules: [
            ScanRule(
                id: "jan-threads",
                displayName: "Jan 聊天会话线程 (threads)",
                path: "jan/threads",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "Jan 保存的单条本地对话线程目录，确认一次性后可移入废纸篓。"
            ),
            ScanRule(
                id: "jan-logs",
                displayName: "Jan 运行日志",
                path: "jan/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Jan 运行日志文件，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "jan", appSupportRelativePath: "Library/Application Support/Jan")
        + [
            protectedRule(
                id: "jan-protected-models",
                displayName: "Jan 本地模型目录 (models)",
                path: "jan/models",
                reason: "包含本地大模型权重文件，不建议直接清理。"
            )
        ]
    )

    public static let zedAI = AIClientProfile(
        id: "zed",
        name: "Zed",
        symbolName: "chevron.forward.square.fill",
        accentToken: "zed",
        description: "Zed AI 编辑器系统缓存与运行日志",
        protectedSummary: "已锁定保护 ~/.config/zed 核心配置与已安装扩展",
        rules: [
            ScanRule(
                id: "zed-sys-cache",
                displayName: "Zed 系统缓存",
                path: "Library/Caches/dev.zed.Zed",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Zed 编辑器运行缓存，清理后按需自动重建。"
            ),
            ScanRule(
                id: "zed-sys-logs",
                displayName: "Zed 运行日志",
                path: "Library/Logs/Zed",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Zed 运行与诊断日志，建议清理。"
            ),
            protectedRule(
                id: "zed-protected-config",
                displayName: "Zed 核心配置 (~/.config/zed)",
                path: ".config/zed",
                reason: "保存编辑器设置、快捷键与 AI 模型配置，已锁定保护。"
            )
        ]
    )
}
