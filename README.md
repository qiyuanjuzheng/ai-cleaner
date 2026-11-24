# AI Cleaner

面向 macOS 的原生 SwiftUI 可视化 AI 客户端聊天会话与临时文件清理工具。

在日常同时使用 Claude Code、Codex、Cursor、Windsurf、Claude Desktop、ChatGPT Desktop、OpenCode、Pi、Gemini / Antigravity 等多个 AI 客户端时，不仅运行缓存、渲染着色器和更新包会持续占用磁盘，大量**用完即弃的一次性聊天会话记录**也会悄无声息地堆积到数 GB。AI Cleaner 以**严格只读扫描 + 系统废纸篓可恢复清理**为安全原则，帮助你在原生桌面界面中一眼看清各客户端的会话与缓存占用，精准勾选不再需要的一次性会话并安全释放空间。

---

## 核心特性

- **聊天会话 + 缓存/临时/日志全覆盖**：内置 9 款常见 macOS AI 客户端的可扩展规则清单，既覆盖应用缓存、临时文件与运行日志，也深入扫描各客户端的本地聊天会话目录（按单条会话展开，并自动只读解析项目名与首条对话摘要，便于快速辨认一次性对话）。
- **自定义扫描目录**：支持在界面中新增或移除自定义文件夹（支持「展开一级子项」与「作为整体目录」两种扫描粒度），移除仅修改配置清单，绝不删除磁盘目录。
- **原生 SwiftUI 桌面体验**：
  - **左侧栏**：按 AI 客户端与自定义目录分组显示总占用空间、总条目数与聊天会话数，提供「重新扫描」（`⌘R`）与「添加目录」（`⌘⇧A`）入口。
  - **右侧列表**：展示会话摘要/条目名称、类别标签（**聊天会话** / 缓存 / 临时文件 / 日志 / 自定义）、安全说明气泡、路径、文件数量、占用体积与最后修改时间；支持**关键词搜索（支持搜项目名与会话首句摘要）**、**按时间范围筛选（全部时间 / 7 天前 / 30 天前 / 90 天前）**、类别数量筛选、按体积/时间/名称排序、单选/全选/反选，以及「在 Finder 中显示」和「复制完整路径」。
  - **底部操作栏与二次确认**：实时汇总已选条目数与预计释放空间；点击「移入废纸篓…」后展示按客户端分组的确认清单；清理后自动刷新列表并反馈实际释放空间。
- **纵深安全防护**：
  - 扫描阶段严格只读（会话摘要仅只读读取非压缩 JSONL 头部前 64 KB），绝不改动任何目录或文件。
  - 清理动作统一调用 macOS 原生 `FileManager.trashItem(at:resultingItemURL:)`，所有删除均进入系统「废纸篓」且可随时「放回原处」，默认不提供不可逆永久删除。
  - 扫描与清理前双重校验路径及目录内容：禁止整体删除会话根容器，并自动拦截高风险系统目录、登录态、凭据、API Key、核心配置、项目记忆（`memory/`、`memories/`）、`sessions-index.json` 及主数据库文件。

---

## 默认支持的 AI 客户端规则

仅扫描以下明确可清理或可按单条移入废纸篓的会话、缓存、日志与临时目录，未安装的客户端不会在列表中出现：

| 客户端 | 聊天会话目录（均相对于 `~/`） | 缓存 / 临时 / 日志目录（均相对于 `~/`） | 明确排除的受保护项 |
| --- | --- | --- | --- |
| **Claude Code** | `.claude/projects`（按单条 `.jsonl` 会话与伴随子代理/产物目录展开，自动解析项目名与首条提问）<br>`.claude/transcripts`（历史会话转录目录） | `Library/Caches/claude-cli-nodejs`<br>`.claude/debug`（按子项）<br>`.claude/{paste-cache, shell-snapshots, file-history, downloads, session-env, backups}` | `~/.claude.json`、`settings.json`、`CLAUDE.md`、各项目 `memory/`、`sessions-index.json`、`skills`、`hooks`、`plugins`、活跃 `sessions/*.key`、`history.jsonl` |
| **Codex** | `.codex/sessions`（递归展开单条 `rollout-*.jsonl` 与 `.jsonl.zst` 会话，自动提取项目与提问摘要）<br>`.codex/archived_sessions`（按单条）<br>`.codex/multica-sessions`（按单条） | `.codex/{cache, log, tmp, .tmp, shell_snapshots, generated_images}`<br>`Library/Application Support/Codex/{Cache, Code Cache, GPUCache, GPUPersistentCache, GrShaderCache, GraphiteDawnCache, DawnGraphiteCache, DawnWebGPUCache, Crashpad}`<br>`Library/Caches/{Codex, com.openai.codex}`<br>`Library/Logs/Codex` | `auth.json`、`config.toml`、`AGENTS.md`、`memories`、`worktrees`、`thread_history/state` SQLite 主数据库及桌面端登录态 |
| **Cursor** | `.cursor/chats`（按单条会话展开）<br>`.cursor/projects`（按项目会话/MCP 缓存展开） | `Library/Application Support/Cursor/{Cache, CachedData, CachedExtensionVSIXs, Code Cache, GPUCache, DawnGraphiteCache, DawnWebGPUCache, Crashpad, logs}`<br>`Library/Application Support/cursor-updater`<br>`Library/Caches/{Cursor, com.todesktop.230313mzl4w4u92.ShipIt}`<br>`Library/Logs/Cursor` | `User/settings.json`、`globalStorage`、`workspaceStorage`、`Cookies`、`Local Storage`、`~/.cursor/mcp.json` |
| **Windsurf** | `.codeium/windsurf/cascade`（按单条 Cascade 会话展开） | `Library/Application Support/Windsurf/{Cache, CachedData, CachedExtensionVSIXs, Code Cache, GPUCache, Crashpad, logs}`<br>`Library/Caches/{Windsurf, com.exafunction.windsurf.ShipIt}`<br>`Library/Logs/Windsurf`<br>`.codeium/windsurf/{logs, cache}` | `~/.codeium/database`、`memories`、`User/settings.json`、`Cookies`、`Local Storage` |
| **Claude Desktop** | `Library/Application Support/Claude/local-agent-mode-sessions`（按单条）<br>`Library/Application Support/Claude/claude-code-sessions`（按单条） | `Library/Application Support/Claude/{Cache, Code Cache, GPUCache, DawnGraphiteCache, DawnWebGPUCache, Crashpad}`<br>`Library/Caches/{com.anthropic.claudefordesktop, com.anthropic.claudefordesktop.ShipIt}`<br>`Library/Logs/Claude` | `claude_desktop_config.json`、`config.json`、`Cookies`、`Local Storage`、`Session Storage` |
| **ChatGPT Desktop** | （会话托管于云端与受保护存储，保持排除） | `Library/Caches/{com.openai.chat, com.openai.chat.ShipIt, ChatGPTHelper}`<br>`Library/Application Support/com.openai.chat/{Cache, Logs}`<br>`Library/Logs/{com.openai.chat, ChatGPT}` | Keychain 凭据、`HTTPStorages`、`Cookies`、`Preferences` 及配对扩展配置 |
| **OpenCode** | `.local/share/opencode/storage/session`（按单条） | `.local/share/opencode/log`（按子项）<br>`.cache/opencode`<br>`Library/Caches/opencode`<br>`.opencode/tmp` | `~/.local/share/opencode/opencode.db` 主数据库、`~/.config/opencode` 与认证凭据 |
| **Pi** | `.pi/agent/sessions`（按工作区展开单条 `.jsonl` 会话，自动提取项目名与首条提问摘要） | — | `~/.pi/agent/{auth.json, settings.json, models.json, mcp.json, skills, extensions}` |
| **Gemini / Antigravity** | `.gemini/antigravity/brain`（按单条工作区展开）<br>`.gemini/antigravity-cli/brain`（按单条工作区展开） | `.gemini/antigravity/cache`<br>`.gemini/tmp`（按子项） | `oauth_creds.json`、`google_accounts.json`、`settings.json`、`skills`、`conversation_summaries.db` 主数据库 |

---

## 安全边界与防护策略

`SafetyGuard` 在**添加自定义目录**、**目录扫描**与**执行移入废纸篓前**均会执行校验，核心保护规则如下：

1. **禁止高风险系统、用户根目录及会话根容器整体删除**：拦截 `/`、`/System`、`/usr`、`/etc`、`/Library/Keychains`、`~`、`~/Desktop`、`~/Documents`、`~/Downloads`、`~/.ssh`、`~/.gnupg`、`~/.aws`、`~/Library/Keychains`、`~/Library/Preferences`、`~/Library/Cookies`、`~/Library/HTTPStorages`，以及各 AI 客户端根目录与会话总容器（如 `~/.claude`、`~/.claude/projects`、`~/.codex/sessions`、`~/.pi/agent/sessions`），避免误把全部历史一键删空。
2. **自动排除登录态、凭据、记忆库、配置与主数据库**：
   - 文件名保护：`auth.json`、`credentials.json`、`oauth_creds.json`、`google_accounts.json`、`.env` / `.env.*`、`settings.json`、`config.toml`、`config.json`、`models.json`、`claude_desktop_config.json`、`mcp.json`、`CLAUDE.md`、`AGENTS.md`、`MEMORY.md`、`history.jsonl`、`sessions-index.json`、`Cookies`、`state.vscdb` 等。
   - 关键词保护：文件名包含 `api_key`、`apikey`、`secret`、`credential`、`private_key`、`oauth`、`access_token`、`refresh_token`、`keychain`、`password` 等敏感词时自动跳过。
   - 扩展名保护：`.sqlite`、`.sqlite3`、`.vscdb`、`.db`、`.realm`、`.pem`、`.p12`、`.key`、`.kdbx` 等（仅对 macOS `~/Library/Caches/` 下由系统 `URLCache` 生成的 `Cache.db*` 缓存文件放行）。
   - 目录保护：自动保护 `Local Storage`、`Session Storage`、`IndexedDB`、`globalStorage`、`workspaceStorage`、`.git`，以及 `~/Library/Caches/` 之外的 `memory`、`memories`、`projects`、`skills`、`plugins`、`extensions`、`database` 等用户数据目录。
3. **符号链接防护**：体积计算与扫描均不穿透符号链接，自动拦截指向目录外部或受保护目标的符号链接。
4. **仅移入系统废纸篓**：核心清理服务 `TrashCleaner` 仅调用 `FileManager.trashItem(at:resultingItemURL:)`，不调用不可逆删除 API。

---

## 环境要求

- **操作系统**：macOS 14.0 (Sonoma) 或更高版本
- **工具链**：Swift 6.0+ / Xcode 16+（已在 Apple Silicon macOS + Swift 6.2 环境验证）

---

## 构建、测试与运行

### 1. 构建项目

```bash
swift build
```

### 2. 运行单元测试

所有单元测试均在系统临时目录创建的独立隔离沙箱（`TestSandbox`）内执行，**绝不触碰宿主机真实的 AI 客户端目录与用户数据**：

```bash
swift test
```

### 3. 直接运行 SwiftUI 桌面应用

```bash
swift run AICleanerApp
```

> 提示：如需在隔离测试目录中预览界面而不扫描真实主目录，可通过环境变量指定临时主目录：
> ```bash
> AI_CLEANER_HOME=/path/to/sandbox-home swift run AICleanerApp
> ```

### 4. 打包可双击运行的 `.app`

仓库内置轻量打包脚本，一键构建 Release 二进制并组装标准 macOS 应用包（输出至 `dist/AI Cleaner.app`）：

```bash
./scripts/package-app.sh
open "dist/AI Cleaner.app"
```

如需构建 Debug 包便于调试，可运行 `./scripts/package-app.sh --debug`。

---

## 项目结构

```text
ai-cleaner/
├── Package.swift
├── README.md
├── scripts/
│   └── package-app.sh                          # 轻量打包 dist/AI Cleaner.app 脚本
├── Sources/
│   ├── AICleanerCore/                          # 核心扫描与安全清理库（可独立测试）
│   │   ├── Models/                             # 规则、扫描类别、条目、报告与清理结果模型
│   │   ├── Rules/
│   │   │   ├── BuiltInClientRules.swift        # 内置 9 款 AI 客户端会话与缓存规则清单
│   │   │   └── SafetyGuard.swift               # 路径/文件名/记忆库/数据库/符号链接安全护栏
│   │   ├── Services/
│   │   │   ├── DirectorySizer.swift            # 严格只读目录体积与元数据统计
│   │   │   ├── SessionMetadataReader.swift     # 严格只读 JSONL 会话项目名与首条提问摘要解析
│   │   │   ├── ScanEngine.swift                # 多客户端会话、缓存与自定义目录扫描引擎
│   │   │   ├── CustomDirectoryStore.swift      # 自定义目录 JSON 持久化管理
│   │   │   └── TrashCleaner.swift              # 系统废纸篓安全清理服务
│   │   └── Utilities/Formatting.swift          # 体积、路径与时间格式化
│   └── AICleanerApp/                           # SwiftUI 原生 macOS 桌面端
│       ├── AICleanerApp.swift                  # 应用入口、窗口与菜单栏快捷键
│       ├── ViewModels/CleanerViewModel.swift   # 扫描、分类/时间过滤、勾选与清理状态管理
│       └── Views/                              # 侧边栏、条目列表、底栏及弹窗视图
└── Tests/
    └── AICleanerCoreTests/                     # 全隔离临时沙箱单元测试
```

---

## 扩展新的 AI 客户端规则

在 `Sources/AICleanerCore/Rules/BuiltInClientRules.swift` 中新增一个 `AIClientProfile` 并加入 `BuiltInClientRules.allProfiles` 即可自动接入扫描引擎与界面分组。建议同步运行 `swift test`，内置规则合规测试会自动校验新规则 ID 的唯一性以及路径是否符合 `SafetyGuard` 策略。
