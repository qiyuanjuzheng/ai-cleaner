# AI Cleaner

面向 macOS 的原生 SwiftUI 可视化 AI 客户端聊天会话与空间清理工具。

支持 **31 款国内外主流 macOS AI 客户端**，不仅扫描缓存、临时文件与日志，还深入识别各客户端的**聊天会话目录与一次性任务工作目录**，并以**「建议清理 / 按需清理 / 不建议清理（锁定保护）」三档直观标识 + 空间占比分布条**呈现，让你一眼分清哪些可以放心删、哪些需要确认、哪些绝不该动。

---

## 核心特性

- **三档清理建议，一目了然**：
  - 🟢 **建议清理**：缓存、日志、临时文件、自动更新包、压缩归档及超过 14 天未活跃的历史会话；提供**「一键勾选建议清理」**按钮，放心移入系统废纸篓。
  - 🟠 **按需清理**：14 天内活跃的聊天会话、一次性任务产出目录（如 `~/WorkBuddy`、`~/Doubao`、`~/DoubaoWork`）、会话回滚快照、可重建的代码索引及用户自定义目录；自动只读提取 JSONL 会话的**项目名 + 首条提问摘要**，便于一眼分辨一次性对话。
  - 🛡️ **不建议清理（已锁定保护）**：登录凭据、核心配置、项目记忆（`memory/`、`memories/`）、已装插件/扩展、内置运行时（`binaries`/`electron`）、Git Worktree、主数据库及本地大模型权重；**透明展示真实磁盘占用与原因，支持 Finder 定位，但默认锁定不可勾选，绝不误删**。
- **可视化空间仪表盘**：
  - 顶部三档交互卡片 + 类 macOS 系统存储比例条，点击卡片即可快速切换对应建议等级。
  - 每条列表项直接内联展示中文建议原因与迷你体积占比条，并按「建议清理 → 按需清理 → 不建议清理」自动分组折叠。
  - 支持关键词搜索（搜会话摘要/项目名/路径/建议说明）、时间范围筛选（全部 / 7 天前 / 30 天前 / 90 天前）、分类计数胶囊、按体积/时间/名称排序、在 Finder 中显示与自定义目录管理。
- **覆盖 31 款国内外主流 AI 客户端**（侧边栏仅展示本机实际存在的客户端，无多余噪音）：
  - **国内 AI 客户端与工作伙伴**：WorkBuddy（腾讯 WorkBuddy / CodeBuddy）、豆包工作伙伴 / 豆包（Doubao / DoubaoWork）、WorkDaddy、DeepSeek Harness、Trae / Trae CN、Qoder、通义灵码（Lingma）、ZCode / 智谱清言（ChatGLM）、阶跃星辰（StepFun）、Kimi、腾讯元宝。
  - **国际主流编程与桌面 AI 客户端**：Claude Code、Codex、Cursor、Windsurf、Claude Desktop、ChatGPT Desktop、OpenCode、Pi、Gemini / Antigravity、Kiro、GitHub Copilot、Multica、Cherry Studio、AnythingLLM、T3 Code、Ollama、LM Studio、Chatbox、Jan、Zed。
- **纵深安全防护**：
  - 扫描严格只读（JSONL 摘要仅读取头部前 64 KB），绝不修改任何文件。
  - 清理动作统一调用 macOS 原生 `FileManager.trashItem(at:resultingItemURL:)` 进入系统废纸篓，随时可「放回原处」；`TrashCleaner` 在核心层强制拒绝任何「不建议清理」条目。

---

## 安全边界与防护策略

1. **禁止高风险目录及会话总容器整体删除**：`SafetyGuard` 拦截系统目录、用户主目录、`~/.ssh`、`~/Library/Keychains`、`~/Library/Cookies`、`~/Library/HTTPStorages`，以及各客户端根目录与会话总目录（如 `~/.claude/projects`、`~/.codex/sessions`、`~/.workbuddy/projects`、`~/WorkBuddy`、`~/Doubao`），防止一键清空全部历史。
2. **明确排除敏感凭据、记忆库与主数据库**：自动保护 `auth.json`、`.credentials.yaml`、`oauth_creds.json`、`trae-jwt-token`、`.env`、`settings.json`、`config.toml`、`mcp.json`、`CLAUDE.md`、`AGENTS.md`、`memory/`、`memories/`、`sessions-index.json`、`Cookies`、`Local Storage`、`.git`、`.sqlite`/`.db` 主数据库及密钥文件（仅放行 `~/Library/Caches/` 下由 macOS `URLCache` 生成的 `Cache.db*`）。
3. **符号链接防护**：不穿透符号链接，自动拦截指向目录外部或受保护路径的符号链接。
4. **仅移入废纸篓**：默认不执行不可逆永久删除。

---

## 环境要求

- **操作系统**：macOS 14.0 (Sonoma) 或更高版本
- **工具链**：Swift 6.0+ / Xcode 16+

---

## 构建、测试与运行

```bash
# 1. 构建
swift build

# 2. 运行隔离沙箱单元测试（严禁触碰宿主机真实 AI 客户端数据）
swift test

# 3. 直接启动 SwiftUI 桌面应用
swift run AICleanerApp

# 4. 一键打包可双击运行的 macOS .app（输出至 dist/AI Cleaner.app）
./scripts/package-app.sh
open "dist/AI Cleaner.app"
```

> 如需在临时沙箱中预览界面而不扫描真实主目录，可运行：
> `AI_CLEANER_HOME=/path/to/sandbox-home swift run AICleanerApp`

---

## 项目结构

```text
ai-cleaner/
├── Package.swift
├── README.md
├── scripts/package-app.sh                        # 打包 dist/AI Cleaner.app 脚本
├── Sources/
│   ├── AICleanerCore/
│   │   ├── Models/                               # CleanupRecommendation / ScanCategory / ScanRule / CleanableItem
│   │   ├── Rules/
│   │   │   ├── BuiltInClientRules.swift          # 国际主流 & 本地大模型客户端规则（20 款）
│   │   │   ├── BuiltInDomesticClientRules.swift  # 国内 AI 客户端与工作伙伴规则（11 款）
│   │   │   └── SafetyGuard.swift                 # 路径/凭据/记忆库/数据库/符号链接安全护栏
│   │   └── Services/
│   │       ├── DirectorySizer.swift              # 严格只读目录体积统计
│   │       ├── SessionMetadataReader.swift       # 严格只读 JSONL 会话项目与首条提问摘要
│   │       ├── ScanEngine.swift                  # 并发扫描引擎与三档建议分类
│   │       ├── CustomDirectoryStore.swift        # 自定义目录 JSON 持久化
│   │       └── TrashCleaner.swift                # 系统废纸篓安全清理（强制拒绝锁定保护项）
│   └── AICleanerApp/
│       ├── AICleanerApp.swift                    # 应用入口与菜单快捷键
│       ├── ViewModels/CleanerViewModel.swift     # 仪表盘统计、分组筛选与清理状态管理
│       └── Views/                                # 侧边栏、三档概览仪表盘、比例条、分组列表与弹窗
└── Tests/AICleanerCoreTests/                     # 全隔离临时沙箱单元测试
```
