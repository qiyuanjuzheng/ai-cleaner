import Foundation

/// 内置常见 macOS AI 客户端扫描规则清单（可扩展架构）。
/// 每条规则均严格限定于缓存、日志与临时/一次性目录，明确排除登录态、凭据、核心配置及主数据库。
public enum BuiltInClientRules {
    public static let allProfiles: [AIClientProfile] = [
        claudeCode,
        cursor,
        codex,
        windsurf,
        claudeDesktop,
        chatGPTDesktop,
        openCode
    ]

    public static let claudeCode = AIClientProfile(
        id: "claude-code",
        name: "Claude Code",
        symbolName: "terminal",
        accentToken: "claude",
        description: "Anthropic 命令行编程助手的调试日志、快照与运行缓存",
        protectedSummary: "已排除 ~/.claude.json、settings.json、CLAUDE.md、projects、skills、hooks、plugins 与 history.jsonl",
        rules: [
            ScanRule(
                id: "claude-code-cli-cache",
                displayName: "CLI 与 MCP 运行缓存",
                path: "Library/Caches/claude-cli-nodejs",
                category: .cache,
                mode: .directory,
                explanation: "Claude Code 及 MCP 服务器产生的运行日志与缓存，清理后自动重建。"
            ),
            ScanRule(
                id: "claude-code-debug",
                displayName: "调试日志",
                path: ".claude/debug",
                category: .logs,
                mode: .children,
                explanation: "会话调试输出日志，移入废纸篓不影响历史会话与配置。"
            ),
            ScanRule(
                id: "claude-code-paste-cache",
                displayName: "剪贴板粘贴缓存",
                path: ".claude/paste-cache",
                category: .cache,
                mode: .directory,
                explanation: "终端大段文本粘贴时生成的临时缓存文件。"
            ),
            ScanRule(
                id: "claude-code-shell-snapshots",
                displayName: "Shell 环境快照",
                path: ".claude/shell-snapshots",
                category: .temporary,
                mode: .directory,
                explanation: "会话期间保存的一次性终端环境快照，下次启动自动重新捕获。"
            ),
            ScanRule(
                id: "claude-code-file-history",
                displayName: "会话文件编辑快照",
                path: ".claude/file-history",
                category: .temporary,
                mode: .directory,
                explanation: "用于会话内撤销的历史文件副本，随使用时间持续增长，可安全清理。"
            ),
            ScanRule(
                id: "claude-code-downloads",
                displayName: "临时下载目录",
                path: ".claude/downloads",
                category: .temporary,
                mode: .directory,
                explanation: "客户端运行期间产生的临时下载文件。"
            ),
            ScanRule(
                id: "claude-code-session-env",
                displayName: "会话临时环境",
                path: ".claude/session-env",
                category: .temporary,
                mode: .directory,
                explanation: "单次会话的临时环境变量文件。"
            ),
            ScanRule(
                id: "claude-code-backups",
                displayName: "自动备份临时目录",
                path: ".claude/backups",
                category: .temporary,
                mode: .directory,
                explanation: "配置更新时留存的历史备份副本，不影响当前生效的 settings.json。"
            )
        ]
    )

    public static let cursor = AIClientProfile(
        id: "cursor",
        name: "Cursor",
        symbolName: "cursorarrow.rays",
        accentToken: "cursor",
        description: "Cursor AI 编辑器缓存、渲染着色器、更新包与运行日志",
        protectedSummary: "已排除 User/settings.json、globalStorage、workspaceStorage、Cookies、Local Storage 与 ~/.cursor/mcp.json",
        rules: [
            ScanRule(
                id: "cursor-cache",
                displayName: "应用网络缓存",
                path: "Library/Application Support/Cursor/Cache",
                category: .cache,
                mode: .directory,
                explanation: "Electron/Chromium 静态资源缓存，清理后按需自动重新下载。"
            ),
            ScanRule(
                id: "cursor-cached-data",
                displayName: "脚本编译缓存 (CachedData)",
                path: "Library/Application Support/Cursor/CachedData",
                category: .cache,
                mode: .directory,
                explanation: "V8 字节码与内置脚本缓存，体积常较大，删除后启动自动重建。"
            ),
            ScanRule(
                id: "cursor-cached-vsix",
                displayName: "扩展安装包缓存",
                path: "Library/Application Support/Cursor/CachedExtensionVSIXs",
                category: .temporary,
                mode: .directory,
                explanation: "已安装或更新插件遗留的 VSIX 安装包缓存，不影响已安装扩展。"
            ),
            ScanRule(
                id: "cursor-code-cache",
                displayName: "代码编译缓存 (Code Cache)",
                path: "Library/Application Support/Cursor/Code Cache",
                category: .cache,
                mode: .directory,
                explanation: "WebAssembly 与 JS 代码缓存，可安全清理。"
            ),
            ScanRule(
                id: "cursor-gpu-cache",
                displayName: "GPU 渲染缓存",
                path: "Library/Application Support/Cursor/GPUCache",
                category: .cache,
                mode: .directory,
                explanation: "图形渲染管线缓存，重启后自动重建。"
            ),
            ScanRule(
                id: "cursor-dawn-graphite",
                displayName: "Dawn Graphite 着色器缓存",
                path: "Library/Application Support/Cursor/DawnGraphiteCache",
                category: .cache,
                mode: .directory,
                explanation: "图形后端着色器缓存。"
            ),
            ScanRule(
                id: "cursor-dawn-webgpu",
                displayName: "Dawn WebGPU 缓存",
                path: "Library/Application Support/Cursor/DawnWebGPUCache",
                category: .cache,
                mode: .directory,
                explanation: "WebGPU 图形缓存。"
            ),
            ScanRule(
                id: "cursor-crashpad",
                displayName: "崩溃转储日志 (Crashpad)",
                path: "Library/Application Support/Cursor/Crashpad",
                category: .logs,
                mode: .directory,
                explanation: "应用异常退出时收集的崩溃转储与诊断文件。"
            ),
            ScanRule(
                id: "cursor-app-logs",
                displayName: "编辑器运行日志",
                path: "Library/Application Support/Cursor/logs",
                category: .logs,
                mode: .directory,
                explanation: "扩展宿主与编辑器窗口产生的按日期归档日志。"
            ),
            ScanRule(
                id: "cursor-updater",
                displayName: "客户端更新包缓存",
                path: "Library/Application Support/cursor-updater",
                category: .temporary,
                mode: .directory,
                explanation: "自动更新下载的待安装/已安装更新包。"
            ),
            ScanRule(
                id: "cursor-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/Cursor",
                category: .cache,
                mode: .directory,
                explanation: "macOS 系统 Caches 目录下的 Cursor 临时缓存。"
            ),
            ScanRule(
                id: "cursor-shipit-cache",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
                category: .temporary,
                mode: .directory,
                explanation: "桌面端自动更新器下载的增量更新缓存。"
            ),
            ScanRule(
                id: "cursor-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Cursor",
                category: .logs,
                mode: .directory,
                explanation: "macOS Logs 目录下的 Cursor 日志文件。"
            )
        ]
    )

    public static let codex = AIClientProfile(
        id: "codex",
        name: "Codex",
        symbolName: "cpu",
        accentToken: "codex",
        description: "OpenAI Codex CLI 与桌面端缓存、着色器、崩溃转储与日志",
        protectedSummary: "已排除 auth.json、config.toml、AGENTS.md、memories/goals 等 SQLite 主数据库及桌面端登录态",
        rules: [
            ScanRule(
                id: "codex-cli-cache",
                displayName: "Codex CLI 缓存",
                path: ".codex/cache",
                category: .cache,
                mode: .directory,
                explanation: "Codex 命令行运行缓存，清理后按需重新生成。"
            ),
            ScanRule(
                id: "codex-cli-log",
                displayName: "Codex 运行日志",
                path: ".codex/log",
                category: .logs,
                mode: .children,
                explanation: "Codex CLI 输出的文本日志文件。"
            ),
            ScanRule(
                id: "codex-cli-tmp",
                displayName: "Codex 临时文件",
                path: ".codex/tmp",
                category: .temporary,
                mode: .directory,
                explanation: "会话执行期间产生的临时目录。"
            ),
            ScanRule(
                id: "codex-app-cache",
                displayName: "桌面端网络缓存",
                path: "Library/Application Support/Codex/Cache",
                category: .cache,
                mode: .directory,
                explanation: "Codex 桌面端 Chromium 资源缓存。"
            ),
            ScanRule(
                id: "codex-code-cache",
                displayName: "桌面端代码缓存",
                path: "Library/Application Support/Codex/Code Cache",
                category: .cache,
                mode: .directory,
                explanation: "JS/WASM 编译缓存，可安全清理。"
            ),
            ScanRule(
                id: "codex-gpu-cache",
                displayName: "GPU 缓存",
                path: "Library/Application Support/Codex/GPUCache",
                category: .cache,
                mode: .directory,
                explanation: "图形渲染缓存，重启自动重建。"
            ),
            ScanRule(
                id: "codex-gpu-persistent-cache",
                displayName: "GPU 持久缓存",
                path: "Library/Application Support/Codex/GPUPersistentCache",
                category: .cache,
                mode: .directory,
                explanation: "桌面端持久化图形缓存。"
            ),
            ScanRule(
                id: "codex-shader-cache",
                displayName: "着色器缓存 (GrShaderCache)",
                path: "Library/Application Support/Codex/GrShaderCache",
                category: .cache,
                mode: .directory,
                explanation: "Skia/图形着色器编译缓存。"
            ),
            ScanRule(
                id: "codex-graphite-dawn-cache",
                displayName: "Graphite Dawn 缓存",
                path: "Library/Application Support/Codex/GraphiteDawnCache",
                category: .cache,
                mode: .directory,
                explanation: "图形引擎着色器缓存。"
            ),
            ScanRule(
                id: "codex-dawn-graphite",
                displayName: "Dawn Graphite 缓存",
                path: "Library/Application Support/Codex/DawnGraphiteCache",
                category: .cache,
                mode: .directory,
                explanation: "Dawn Graphite 渲染缓存。"
            ),
            ScanRule(
                id: "codex-dawn-webgpu",
                displayName: "Dawn WebGPU 缓存",
                path: "Library/Application Support/Codex/DawnWebGPUCache",
                category: .cache,
                mode: .directory,
                explanation: "WebGPU 着色器缓存。"
            ),
            ScanRule(
                id: "codex-crashpad",
                displayName: "崩溃转储日志 (Crashpad)",
                path: "Library/Application Support/Codex/Crashpad",
                category: .logs,
                mode: .directory,
                explanation: "桌面端崩溃诊断文件与 dump 包。"
            ),
            ScanRule(
                id: "codex-sys-cache",
                displayName: "系统级应用缓存 (Codex)",
                path: "Library/Caches/Codex",
                category: .cache,
                mode: .directory,
                explanation: "macOS Caches 目录下的 Codex 浏览器与代码缓存。"
            ),
            ScanRule(
                id: "codex-bundle-cache",
                displayName: "系统级网络与更新缓存",
                path: "Library/Caches/com.openai.codex",
                category: .cache,
                mode: .directory,
                explanation: "包含 URLCache 缓存与 Sparkle 更新下载缓存，清理后可自动重建。"
            ),
            ScanRule(
                id: "codex-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Codex",
                category: .logs,
                mode: .directory,
                explanation: "macOS Logs 目录下的 Codex 日志。"
            )
        ]
    )

    public static let windsurf = AIClientProfile(
        id: "windsurf",
        name: "Windsurf",
        symbolName: "wind",
        accentToken: "windsurf",
        description: "Windsurf / Codeium 编辑器缓存、扩展缓存与运行日志",
        protectedSummary: "已排除 ~/.codeium/database、memories、User/settings.json、Cookies 与 Local Storage",
        rules: [
            ScanRule(
                id: "windsurf-cache",
                displayName: "应用网络缓存",
                path: "Library/Application Support/Windsurf/Cache",
                category: .cache,
                mode: .directory,
                explanation: "Windsurf 桌面端网络资源缓存。"
            ),
            ScanRule(
                id: "windsurf-cached-data",
                displayName: "脚本编译缓存 (CachedData)",
                path: "Library/Application Support/Windsurf/CachedData",
                category: .cache,
                mode: .directory,
                explanation: "V8 编译缓存，可安全清理并在下次启动重建。"
            ),
            ScanRule(
                id: "windsurf-cached-vsix",
                displayName: "扩展安装包缓存",
                path: "Library/Application Support/Windsurf/CachedExtensionVSIXs",
                category: .temporary,
                mode: .directory,
                explanation: "扩展更新后残留的 VSIX 安装包。"
            ),
            ScanRule(
                id: "windsurf-code-cache",
                displayName: "代码编译缓存 (Code Cache)",
                path: "Library/Application Support/Windsurf/Code Cache",
                category: .cache,
                mode: .directory,
                explanation: "JS/WASM 编译缓存。"
            ),
            ScanRule(
                id: "windsurf-gpu-cache",
                displayName: "GPU 渲染缓存",
                path: "Library/Application Support/Windsurf/GPUCache",
                category: .cache,
                mode: .directory,
                explanation: "GPU 渲染管线缓存。"
            ),
            ScanRule(
                id: "windsurf-crashpad",
                displayName: "崩溃转储日志 (Crashpad)",
                path: "Library/Application Support/Windsurf/Crashpad",
                category: .logs,
                mode: .directory,
                explanation: "应用崩溃转储文件。"
            ),
            ScanRule(
                id: "windsurf-app-logs",
                displayName: "编辑器运行日志",
                path: "Library/Application Support/Windsurf/logs",
                category: .logs,
                mode: .directory,
                explanation: "Windsurf 运行过程产生的日志文件。"
            ),
            ScanRule(
                id: "windsurf-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/Windsurf",
                category: .cache,
                mode: .directory,
                explanation: "macOS Caches 目录下的 Windsurf 缓存。"
            ),
            ScanRule(
                id: "windsurf-shipit-cache",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.exafunction.windsurf.ShipIt",
                category: .temporary,
                mode: .directory,
                explanation: "自动更新器留存的安装包缓存。"
            ),
            ScanRule(
                id: "windsurf-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/Windsurf",
                category: .logs,
                mode: .directory,
                explanation: "macOS Logs 目录下的 Windsurf 日志。"
            ),
            ScanRule(
                id: "windsurf-codeium-logs",
                displayName: "Codeium 引擎日志",
                path: ".codeium/windsurf/logs",
                category: .logs,
                mode: .directory,
                explanation: "Codeium 语言服务日志。"
            ),
            ScanRule(
                id: "windsurf-codeium-cache",
                displayName: "Codeium 临时缓存",
                path: ".codeium/windsurf/cache",
                category: .cache,
                mode: .directory,
                explanation: "Codeium 本地临时缓存。"
            )
        ]
    )

    public static let claudeDesktop = AIClientProfile(
        id: "claude-desktop",
        name: "Claude Desktop",
        symbolName: "bubble.left.and.text.bubble.right",
        accentToken: "claudeDesktop",
        description: "Claude macOS 桌面应用缓存、更新包与崩溃日志",
        protectedSummary: "已排除 claude_desktop_config.json、config.json、Cookies、Local Storage 与 Session Storage",
        rules: [
            ScanRule(
                id: "claude-desktop-cache",
                displayName: "应用网络缓存",
                path: "Library/Application Support/Claude/Cache",
                category: .cache,
                mode: .directory,
                explanation: "桌面客户端静态资源与图片缓存。"
            ),
            ScanRule(
                id: "claude-desktop-code-cache",
                displayName: "代码编译缓存 (Code Cache)",
                path: "Library/Application Support/Claude/Code Cache",
                category: .cache,
                mode: .directory,
                explanation: "前端脚本与 WASM 编译缓存。"
            ),
            ScanRule(
                id: "claude-desktop-gpu-cache",
                displayName: "GPU 渲染缓存",
                path: "Library/Application Support/Claude/GPUCache",
                category: .cache,
                mode: .directory,
                explanation: "图形渲染着色器缓存。"
            ),
            ScanRule(
                id: "claude-desktop-dawn-graphite",
                displayName: "Dawn Graphite 缓存",
                path: "Library/Application Support/Claude/DawnGraphiteCache",
                category: .cache,
                mode: .directory,
                explanation: "图形后端缓存。"
            ),
            ScanRule(
                id: "claude-desktop-dawn-webgpu",
                displayName: "Dawn WebGPU 缓存",
                path: "Library/Application Support/Claude/DawnWebGPUCache",
                category: .cache,
                mode: .directory,
                explanation: "WebGPU 图形缓存。"
            ),
            ScanRule(
                id: "claude-desktop-crashpad",
                displayName: "崩溃转储日志 (Crashpad)",
                path: "Library/Application Support/Claude/Crashpad",
                category: .logs,
                mode: .directory,
                explanation: "崩溃诊断与 dump 文件。"
            ),
            ScanRule(
                id: "claude-desktop-sys-cache",
                displayName: "系统级应用缓存",
                path: "Library/Caches/com.anthropic.claudefordesktop",
                category: .cache,
                mode: .directory,
                explanation: "macOS Caches 下的 Claude Desktop 缓存。"
            ),
            ScanRule(
                id: "claude-desktop-shipit",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.anthropic.claudefordesktop.ShipIt",
                category: .temporary,
                mode: .directory,
                explanation: "桌面端自动更新下载的临时更新包。"
            ),
            ScanRule(
                id: "claude-desktop-logs",
                displayName: "应用运行日志",
                path: "Library/Logs/Claude",
                category: .logs,
                mode: .directory,
                explanation: "包含 MCP 与客户端主进程运行日志。"
            )
        ]
    )

    public static let chatGPTDesktop = AIClientProfile(
        id: "chatgpt-desktop",
        name: "ChatGPT Desktop",
        symbolName: "sparkles",
        accentToken: "chatgpt",
        description: "ChatGPT macOS 桌面应用缓存、辅助进程日志与更新包",
        protectedSummary: "已排除 Keychain 凭据、HTTPStorages、Cookies、Preferences 及配对扩展配置",
        rules: [
            ScanRule(
                id: "chatgpt-sys-cache",
                displayName: "应用系统缓存",
                path: "Library/Caches/com.openai.chat",
                category: .cache,
                mode: .directory,
                explanation: "ChatGPT macOS 客户端网络与资源缓存，不影响登录状态。"
            ),
            ScanRule(
                id: "chatgpt-shipit",
                displayName: "ShipIt 更新缓存",
                path: "Library/Caches/com.openai.chat.ShipIt",
                category: .temporary,
                mode: .directory,
                explanation: "客户端更新器下载的临时更新文件。"
            ),
            ScanRule(
                id: "chatgpt-helper-cache",
                displayName: "ChatGPTHelper 缓存与诊断",
                path: "Library/Caches/ChatGPTHelper",
                category: .logs,
                mode: .directory,
                explanation: "辅助进程产生的异步日志与 Sentry 诊断缓存。"
            ),
            ScanRule(
                id: "chatgpt-app-cache",
                displayName: "本地应用缓存",
                path: "Library/Application Support/com.openai.chat/Cache",
                category: .cache,
                mode: .directory,
                explanation: "本地静态资源缓存目录。"
            ),
            ScanRule(
                id: "chatgpt-app-logs",
                displayName: "本地运行日志",
                path: "Library/Application Support/com.openai.chat/Logs",
                category: .logs,
                mode: .directory,
                explanation: "桌面应用本地诊断日志。"
            ),
            ScanRule(
                id: "chatgpt-sys-logs",
                displayName: "系统日志 (com.openai.chat)",
                path: "Library/Logs/com.openai.chat",
                category: .logs,
                mode: .directory,
                explanation: "macOS Logs 目录下的 ChatGPT 运行日志。"
            ),
            ScanRule(
                id: "chatgpt-named-logs",
                displayName: "系统日志 (ChatGPT)",
                path: "Library/Logs/ChatGPT",
                category: .logs,
                mode: .directory,
                explanation: "macOS Logs 目录下的 ChatGPT 辅助日志。"
            )
        ]
    )

    public static let openCode = AIClientProfile(
        id: "opencode",
        name: "OpenCode",
        symbolName: "chevron.left.forwardslash.chevron.right",
        accentToken: "opencode",
        description: "OpenCode CLI 的运行日志与临时缓存目录",
        protectedSummary: "已排除 ~/.local/share/opencode/opencode.db 主数据库、~/.config/opencode 与认证凭据",
        rules: [
            ScanRule(
                id: "opencode-logs",
                displayName: "OpenCode 运行日志",
                path: ".local/share/opencode/log",
                category: .logs,
                mode: .children,
                explanation: "OpenCode CLI 会话与调试日志文件，清理不影响 opencode.db 历史库。"
            ),
            ScanRule(
                id: "opencode-xdg-cache",
                displayName: "OpenCode 缓存目录",
                path: ".cache/opencode",
                category: .cache,
                mode: .directory,
                explanation: "XDG 缓存目录中的下载与构建缓存，清理后按需重新拉取。"
            ),
            ScanRule(
                id: "opencode-mac-cache",
                displayName: "系统级缓存",
                path: "Library/Caches/opencode",
                category: .cache,
                mode: .directory,
                explanation: "macOS Caches 下的 OpenCode 缓存。"
            ),
            ScanRule(
                id: "opencode-tmp",
                displayName: "临时目录",
                path: ".opencode/tmp",
                category: .temporary,
                mode: .directory,
                explanation: "OpenCode 运行产生的临时文件。"
            )
        ]
    )
}
