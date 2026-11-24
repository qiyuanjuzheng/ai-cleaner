# AI Cleaner

面向 macOS 的原生 SwiftUI 可视化 AI 客户端临时文件与缓存清理工具。

在日常同时使用 Claude Code、Cursor、Codex、Windsurf、Claude Desktop、ChatGPT Desktop、OpenCode 等多个 AI 客户端时，会话日志、渲染着色器缓存、自动更新包与一次性快照会持续增长。AI Cleaner 以**严格只读扫描 + 系统废纸篓可恢复清理**为安全原则，帮助你在原生桌面界面中一眼看清各客户端占用空间，安全勾选并释放磁盘空间。

---

## 核心特性

- **多客户端自动识别**：内置 7 款常见 macOS AI 客户端的可扩展规则清单，仅展示本机实际存在的条目，不制造空白噪音。
- **自定义扫描目录**：支持在界面中新增或移除自定义缓存/临时文件夹（支持「展开一级子项」与「作为整体目录」两种扫描粒度），移除仅修改配置清单，绝不删除磁盘目录。
- **原生 SwiftUI 桌面体验**：
  - **左侧栏**：按 AI 客户端与自定义目录分组显示可清理条目数和总占用体积，提供「重新扫描」（`⌘R`）与「添加目录」（`⌘⇧A`）入口。
  - **右侧列表**：展示条目名称、类别标签（缓存 / 临时文件 / 日志 / 自定义）、安全说明气泡、路径、文件数量、占用体积与最后修改时间；支持搜索过滤、类别筛选、按体积/时间/名称排序、单选/全选/反选，以及「在 Finder 中显示」和「复制完整路径」。
  - **底部操作栏与二次确认**：实时汇总已选条目数与预计释放空间；点击「移入废纸篓…」后展示按客户端分组的确认清单；清理后自动刷新列表并反馈实际释放空间。
- **纵深安全防护**：
  - 扫描阶段严格只读，绝不改动任何目录或文件。
  - 清理动作统一调用 macOS 原生 `FileManager.trashItem(at:resultingItemURL:)`，所有删除均进入系统「废纸篓」且可随时「放回原处」，默认不提供不可逆永久删除。
  - 扫描与清理前双重校验路径及目录内容，自动拦截高风险系统目录、登录态、凭据、API Key、核心配置及主数据库文件。

---

## 默认支持的 AI 客户端规则

仅扫描以下明确可重建的缓存、日志与临时目录，未安装的客户端不会在列表中出现：

| 客户端 | 覆盖扫描路径（均相对于 `~/`） | 类别 | 明确排除的受保护项 |
| --- | --- | --- | --- |
| **Claude Code** | `Library/Caches/claude-cli-nodejs`<br>`.claude/debug`（按子项展开）<br>`.claude/paste-cache`<br>`.claude/shell-snapshots`<br>`.claude/file-history`<br>`.claude/downloads`<br>`.claude/session-env`<br>`.claude/backups` | 缓存 / 日志 / 临时文件 | `~/.claude.json`、`settings.json`、`CLAUDE.md`、`projects`、`skills`、`hooks`、`plugins`、`history.jsonl` |
| **Cursor** | `Library/Application Support/Cursor/Cache`<br>`Library/Application Support/Cursor/CachedData`<br>`Library/Application Support/Cursor/CachedExtensionVSIXs`<br>`Library/Application Support/Cursor/Code Cache`<br>`Library/Application Support/Cursor/GPUCache`<br>`Library/Application Support/Cursor/DawnGraphiteCache`<br>`Library/Application Support/Cursor/DawnWebGPUCache`<br>`Library/Application Support/Cursor/Crashpad`<br>`Library/Application Support/Cursor/logs`<br>`Library/Application Support/cursor-updater`<br>`Library/Caches/Cursor`<br>`Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt`<br>`Library/Logs/Cursor` | 缓存 / 临时文件 / 日志 | `User/settings.json`、`globalStorage`、`workspaceStorage`、`Cookies`、`Local Storage`、`~/.cursor/mcp.json` |
| **Codex** | `.codex/cache`<br>`.codex/log`（按子项展开）<br>`.codex/tmp`<br>`Library/Application Support/Codex/{Cache, Code Cache, GPUCache, GPUPersistentCache, GrShaderCache, GraphiteDawnCache, DawnGraphiteCache, DawnWebGPUCache, Crashpad}`<br>`Library/Caches/Codex`<br>`Library/Caches/com.openai.codex`<br>`Library/Logs/Codex` | 缓存 / 临时文件 / 日志 | `auth.json`、`config.toml`、`AGENTS.md`、`memories` 等 SQLite 主数据库及桌面端登录态 |
| **Windsurf** | `Library/Application Support/Windsurf/{Cache, CachedData, CachedExtensionVSIXs, Code Cache, GPUCache, Crashpad, logs}`<br>`Library/Caches/Windsurf`<br>`Library/Caches/com.exafunction.windsurf.ShipIt`<br>`Library/Logs/Windsurf`<br>`.codeium/windsurf/{logs, cache}` | 缓存 / 临时文件 / 日志 | `~/.codeium/database`、`memories`、`User/settings.json`、`Cookies`、`Local Storage` |
| **Claude Desktop** | `Library/Application Support/Claude/{Cache, Code Cache, GPUCache, DawnGraphiteCache, DawnWebGPUCache, Crashpad}`<br>`Library/Caches/com.anthropic.claudefordesktop`<br>`Library/Caches/com.anthropic.claudefordesktop.ShipIt`<br>`Library/Logs/Claude` | 缓存 / 临时文件 / 日志 | `claude_desktop_config.json`、`config.json`、`Cookies`、`Local Storage`、`Session Storage` |
| **ChatGPT Desktop** | `Library/Caches/com.openai.chat`<br>`Library/Caches/com.openai.chat.ShipIt`<br>`Library/Caches/ChatGPTHelper`<br>`Library/Application Support/com.openai.chat/{Cache, Logs}`<br>`Library/Logs/com.openai.chat`<br>`Library/Logs/ChatGPT` | 缓存 / 临时文件 / 日志 | Keychain 凭据、`HTTPStorages`、`Cookies`、`Preferences` 及配对扩展配置 |
| **OpenCode** | `.local/share/opencode/log`（按子项展开）<br>`.cache/opencode`<br>`Library/Caches/opencode`<br>`.opencode/tmp` | 日志 / 缓存 / 临时文件 | `~/.local/share/opencode/opencode.db` 主数据库、`~/.config/opencode` 与认证凭据 |

---

## 安全边界与防护策略

`SafetyGuard` 在**添加自定义目录**、**目录扫描**与**执行移入废纸篓前**均会执行校验，核心保护规则如下：

1. **禁止高风险系统与用户根路径**：拦截 `/`、`/System`、`/usr`、`/etc`、`/Library/Keychains`、`~`、`~/Desktop`、`~/Documents`、`~/Downloads`、`~/.ssh`、`~/.gnupg`、`~/.aws`、`~/Library/Keychains`、`~/Library/Preferences`、`~/Library/Cookies`、`~/Library/HTTPStorages` 以及各 AI 客户端根目录本身（如 `~/.claude`、`~/.codex`、`~/Library/Application Support/Cursor`）。
2. **自动排除登录态、凭据、配置与主数据库**：
   - 文件名保护：`auth.json`、`credentials.json`、`.env` / `.env.*`、`settings.json`、`config.toml`、`config.json`、`claude_desktop_config.json`、`mcp.json`、`CLAUDE.md`、`AGENTS.md`、`history.jsonl`、`Cookies`、`state.vscdb` 等。
   - 关键词保护：文件名包含 `api_key`、`apikey`、`secret`、`credential`、`private_key`、`oauth`、`access_token`、`refresh_token`、`keychain`、`password` 等敏感词时自动跳过。
   - 扩展名保护：`.sqlite`、`.sqlite3`、`.vscdb`、`.db`、`.realm`、`.pem`、`.p12`、`.key`、`.kdbx` 等（仅对 macOS `~/Library/Caches/` 下由系统 `URLCache` 生成的 `Cache.db*` 缓存文件放行）。
   - 目录保护：自动保护 `Local Storage`、`Session Storage`、`IndexedDB`、`globalStorage`、`workspaceStorage`、`.git`，以及 `~/Library/Caches/` 之外的 `projects`、`skills`、`memories`、`plugins`、`extensions`、`database` 等用户数据目录。若目标目录内混入受保护文件，则整目录自动跳过。
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
│   │   ├── Models/                             # 规则、扫描条目、报告与清理结果模型
│   │   ├── Rules/
│   │   │   ├── BuiltInClientRules.swift        # 内置 7 款 AI 客户端可扩展规则清单
│   │   │   └── SafetyGuard.swift               # 路径/文件名/数据库/符号链接安全护栏
│   │   ├── Services/
│   │   │   ├── DirectorySizer.swift            # 严格只读目录体积与元数据统计
│   │   │   ├── ScanEngine.swift                # 多客户端与自定义目录扫描引擎
│   │   │   ├── CustomDirectoryStore.swift      # 自定义目录 JSON 持久化管理
│   │   │   └── TrashCleaner.swift              # 系统废纸篓安全清理服务
│   │   └── Utilities/Formatting.swift          # 体积、路径与时间格式化
│   └── AICleanerApp/                           # SwiftUI 原生 macOS 桌面端
│       ├── AICleanerApp.swift                  # 应用入口、窗口与菜单栏快捷键
│       ├── ViewModels/CleanerViewModel.swift   # 扫描、过滤、勾选与清理状态管理
│       └── Views/                              # 侧边栏、条目列表、底栏及弹窗视图
└── Tests/
    └── AICleanerCoreTests/                     # 全隔离临时沙箱单元测试
```

---

## 扩展新的 AI 客户端规则

在 `Sources/AICleanerCore/Rules/BuiltInClientRules.swift` 中新增一个 `AIClientProfile` 并加入 `BuiltInClientRules.allProfiles` 即可自动接入扫描引擎与界面分组。建议同步运行 `swift test`，内置规则合规测试会自动校验新规则 ID 的唯一性以及路径是否符合 `SafetyGuard` 策略。
