# Windows / Linux 31 款 AI 客户端规则核验清单（AICL-37 / AICL-38）

本文档记录 `rules/macos.json` 中全部 31 款 AI 客户端在 **Windows** 与 **Linux** 上的适配状态、路径核验层级、安全护栏边界与依据来源。

## 核验分级与安全降级策略

根据 AICL-37 / AICL-38 的无真机分级核验方案，每条 Windows / Linux 可清理规则均在 JSON 规则包中声明 `verification`（验证层级）与 `evidence`（来源依据），并由 `scripts/generate-built-in-rules.py` 在构建时强制校验：

| 层级 | 含义 | 首版默认推荐等级 |
| --- | --- | --- |
| `ci` | 在真实 OS 环境（Docker / GitHub Actions `ubuntu-latest` / `windows-latest`）安装运行客户端，并用 `aicleaner-core` 实扫验证 | 允许 `recommended`（会话类仍默认 `reviewSuggested`） |
| `source` | 直接核对上游开源仓库源码、Flathub 官方 Manifest 或已安装 npm 包代码 | 允许 `recommended`（会话类仍默认 `reviewSuggested`） |
| `docs` | 依据官方文档、Winget 官方清单与 Electron `app.getPath('userData')` 约定推导 | **强制降级为 `reviewSuggested`（按需清理）** |
| `community` | 社区打包（如第三方 Snap / Linux 社区封装版 Claude Desktop） | **强制降级为 `reviewSuggested`（按需清理）** |

所有受保护数据条目（`protected: true` / `protectedData`）均固定为 `notRecommended`，仅展示体积并受 `SafetyGuard` / `PlatformSafetyPolicy` 锁定保护。

---

## 31 款客户端跨平台覆盖矩阵

- **Windows 规则包（`rules/windows.json`）**：覆盖 **30 / 31** 款客户端（`chatgpt-desktop` 为纯 MSIX 包，数据位于已锁定的 `%LOCALAPPDATA%\Packages`，首版不直接触碰）。
- **Linux 规则包（`rules/linux.json`）**：覆盖 **24 / 31** 款客户端（覆盖原生 XDG、Flatpak `~/.var/app` 与 Snap `~/snap`；7 款无官方 Linux 桌面端的产品显式标注为不适用）。

| # | Client ID | 客户端 | Windows 状态与核验层级 | Linux 状态与核验层级 | 关键受保护数据与安全备注 |
| --- | --- | --- | --- | --- | --- |
| 1 | `claude-code` | Claude Code | 支持（`docs`，CI 实测目标） | 支持（`docs`，CI 实测目标） | 锁定 `~/.claude/{plugins,skills,history.jsonl,settings.json}` |
| 2 | `codex` | Codex | 支持（`tmp` 已 `ci` 实扫，其余 CLI `source`，Desktop `docs`） | 支持（CLI `source`） | 依据 `openai/codex` `codex-rs` 与 Windows CI 实扫；锁定 `auth.json`、`thread_history_1.sqlite`、`worktrees`、`memories` |
| 3 | `workbuddy` | WorkBuddy | 支持（`docs`） | 支持（`docs`） | 锁定 `.workbuddy/security`、`binaries`、`plugins`、`skills`、`workbuddy.db` |
| 4 | `doubao` | 豆包工作伙伴 / 豆包 | 支持（`docs`，Winget `ByteDance.Doubao`） | 不适用（无官方 Linux 桌面端） | 锁定 `skills`、`public_config.json`、`Local Storage` |
| 5 | `workdaddy` | WorkDaddy | 支持（`docs`） | 支持（`docs`） | `PlatformSafetyPolicy` 硬锁定 `WorkDaddy/accounts`，锁定 `credit-usage.db`、`automations.json` |
| 6 | `cursor` | Cursor | 支持（`docs`，Winget `Anysphere.Cursor`） | 支持（`docs`，官方 Linux AppImage/deb/rpm） | `PlatformSafetyPolicy` 硬锁定 `Cursor/User`、`Cookies`、`Local Storage` 与 `Cursor` 根目录 |
| 7 | `deepseek` | DeepSeek Harness | 支持（`docs`） | 支持（`docs`） | 锁定 `~/.dsh/{electron,profiles,.credentials.yaml}` |
| 8 | `trae` | Trae / Trae CN | 支持（`docs`，Winget `ByteDance.Trae`） | 不适用（无官方 Linux 桌面端） | 硬锁定 `Trae/User`、`Trae CN/User`、`trae-jwt-token`、`extensions`、`memory` |
| 9 | `qoder` | Qoder | 支持（`docs`，Winget `Alibaba.Qoder`） | 不适用（无官方 Linux 桌面端） | 硬锁定 `Qoder/User`、`~/.qoder/{extensions,skills}` |
| 10 | `lingma` | 通义灵码 | 支持（`docs`） | 支持（`docs`） | 跨平台 `~/.lingma/{cache,logs,tmp,index}`，锁定 `bin`、`model`、`lingma_mcp.json` |
| 11 | `kiro` | Kiro | 支持（`docs`，Winget `Amazon.Kiro`） | 支持（`docs`，官方 Linux 发行包） | 硬锁定 `Kiro/User`、`~/.kiro/{extensions,steering}` |
| 12 | `zcode` | ZCode / 智谱清言 | 支持（`docs`，Winget `ZhipuAI.ZCode`） | 支持（`docs`） | `PlatformSafetyPolicy` 硬锁定 `ai.z.zcode` 与 `~/.zcode/{agents,cli,bundled-agents}` |
| 13 | `windsurf` | Windsurf | 支持（`docs`，Winget `Codeium.Windsurf`） | 支持（`docs`，官方 apt/rpm） | 硬锁定 `Windsurf/User`、`~/.codeium/{database,memories}` |
| 14 | `claude-desktop` | Claude Desktop | 支持标准 exe（`docs`，Winget `Anthropic.Claude`） | 支持社区版（`community`） | Windows MSIX（`Packages\Claude_pzs8sxrjxfjjc`）受 `Packages` 硬保护，仅扫描标准 `%APPDATA%\Claude`；锁定 `claude_desktop_config.json`、`Local Storage` |
| 15 | `chatgpt-desktop` | ChatGPT Desktop | MSIX-only（首版不纳入清理） | 不适用（无 Linux 版） | Winget `OpenAI.ChatGPT` 仅提供 MSIX 安装包，数据位于受保护的 `%LOCALAPPDATA%\Packages`，严禁直接清理 VFS 容器 |
| 16 | `opencode` | OpenCode | 支持（日志 `ci`，其余 `docs`） | 支持（日志 `ci`，会话 `source`） | Windows 与 Linux 均已用真实 `opencode 1.19.6` 验证 `debug paths` 与 `.local/share/opencode/log/opencode.log`；注意 `cache/opencode/bin` 存放运行时工具，故不整目录默认清理 cache；硬锁定 `opencode.db` |
| 17 | `pi` | Pi | 支持（`source`） | 支持（`source`） | 直接核对 `@earendil-works/pi-coding-agent` `dist/config.js`（`~/.pi/agent/sessions` 与 `pi-debug.log`）；锁定 `auth.json`、`extensions`、`skills` |
| 18 | `gemini-antigravity` | Gemini / Antigravity | 支持（CLI `source`，Desktop `docs`） | 支持（CLI `source`，Desktop `docs`） | 直接核对 `google-gemini/gemini-cli` `storage.ts`（`~/.gemini/tmp` 与沙箱 `~/.cache/.gemini/tmp`）；锁定 `oauth_creds.json`、`conversation_summaries.db` |
| 19 | `multica` | Multica | 支持（`source`） | 支持（`source`） | 直接核对 `multica-ai/multica` `apps/desktop/electron-builder.yml`（显式固定 `Multica`）；锁定 `~/.multica/profiles`、`IndexedDB` |
| 20 | `copilot` | GitHub Copilot | 支持（`docs`，CI 实测目标） | 支持（`docs`，CI 实测目标） | 锁定 `~/.copilot/{mcp-config.json,installed-plugins}` |
| 21 | `cherry-studio` | Cherry Studio | 支持（`source`） | 支持原生 + Flatpak（`source`） | 核对 `CherryHQ/cherry-studio` `package.json` 及 Flathub `com.cherry_ai.CherryStudio`；锁定 `~/.cherrystudio/bin`、`IndexedDB` |
| 22 | `anythingllm` | AnythingLLM | 支持（`docs`） | 支持（`docs`） | `PlatformSafetyPolicy` 硬锁定 `anythingllm-desktop/storage` 向量知识库 |
| 23 | `t3-code` | T3 Code | 支持（CLI `source`，Desktop `docs`） | 支持（CLI `source`，Desktop `docs`） | 核对 `pingdotgg/t3code` `apps/server/src/config.ts`（`~/.t3/caches`、`~/.t3/userdata/logs`）；锁定 `tools`、`userdata` |
| 24 | `stepfun` | 阶跃星辰 | 支持（`docs`） | 不适用（无官方 Linux 桌面端） | 锁定 `Local Storage`、`Cookies` |
| 25 | `kimi` | Kimi | 支持（`docs`，Winget `MoonshotAI.Kimi`） | 不适用（无官方 Linux 桌面端） | 锁定 `Local Storage` |
| 26 | `yuanbao` | 腾讯元宝 | 支持（`docs`，Winget `Tencent.Yuanbao`） | 不适用（无官方 Linux 桌面端） | 锁定 `Local Storage` |
| 27 | `ollama` | Ollama | 支持（`source`，Winget `Ollama.Ollama`） | 支持原生（`docs`）+ Snap（`community`） | 核对 `ollama/ollama` `docs/troubleshooting.mdx`；Windows 仅递归匹配 `%LOCALAPPDATA%\Ollama` 下的 `.log` 文件，硬锁定 `~/.ollama/models` 与 `id_ed25519` |
| 28 | `lm-studio` | LM Studio | 支持（`docs`，Winget `ElementLabs.LMStudio`） | 支持（`docs`，官方 Linux AppImage） | 硬锁定 `~/.lmstudio/models` 与 `~/.cache/lm-studio/models` 本地模型权重 |
| 29 | `chatbox` | Chatbox | 支持商业版（`docs`）+ CE（`source`） | 支持商业版（`docs`）+ CE（`source`） | 核对 Winget `Bin-Huang.Chatbox` 及 `chatboxai/chatbox` `package.json`（`xyz.chatboxapp.ce`）；锁定 `Local Storage` |
| 30 | `jan` | Jan | 支持 Tauri 数据目录（`source`）+ 旧版（`docs`） | 支持原生 + Flatpak `ai.jan.Jan`（`source`）+ 旧版（`docs`） | 核对 `menloresearch/jan` `src-tauri/src/core/app/commands.rs`（`dirs::data_dir()/Jan/data`）与 Flathub `ai.jan.Jan`；硬锁定 `models` |
| 31 | `zed` | Zed | 支持（`source`，Winget `ZedIndustries.Zed`） | 支持原生 + Flatpak `dev.zed.Zed`（`source`）+ Snap（`community`） | 核对 `zed-industries/zed` `crates/paths/src/paths.rs`；Windows `temp_dir == data_dir` 故严禁清理整个 `%LOCALAPPDATA%\Zed`，仅清理 `logs` 与 `hang_traces`；硬锁定配置与 `db` |

---

## SafetyGuard 平台安全边界摘要

### Windows（AICL-37）
- **系统与用户敏感目录**：`Windows`、`Program Files*`、`ProgramData`、`Recovery`、`Boot`、`$Recycle.Bin`、`System Volume Information`、其他用户 `C:\Users\*`、注册表配置单元（`NTUSER.DAT*`、`UsrClass.dat*`）、个人文件夹（含 `SHGetKnownFolderPath` 重定向后的真实路径）、OneDrive（`OneDrive` / `OneDrive - *` / `%OneDrive*`）、`%APPDATA%\Microsoft`、`%LOCALAPPDATA%\Microsoft`、`%LOCALAPPDATA%\Packages`、`LocalLow\Microsoft`、GnuPG、浏览器配置（Chrome / Chromium / Edge / Firefox / Brave / Vivaldi / Opera / Tor / Arc / Zen）与密码管理器（1Password / KeePass / KeePassXC）。
- **文件系统边界**：大小写不敏感匹配；拒绝 UNC 共享路径、保留设备名（`CON`/`PRN`/`AUX`/`NUL`/`COM1-9`/`LPT1-9`）、NTFS ADS（`:`）、尾部空格/点；支持 `> 260` 字符长路径（Win32 `\\?\`）；逐段校验祖先重解析点 / junction（绝不穿透）；拦截隐藏/系统属性节点与正在被进程占用的活跃文件（共享违例探测）。

### Linux（AICL-38）
- **系统与用户敏感目录**：`/proc`、`/sys`、`/run`、`/boot`、`/lib*`、`/root`、`/snap`、`/srv`、`/lost+found`、`/var/{lib,cache,log,spool,run}`、`/home` 与其他用户 `/home/<other>`；支持自定义 `XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_CACHE_HOME` / `GNUPGHOME`；硬保护 keyrings（`keyrings`、`kwalletd`、`gnome-keyring`、`.password-store`、`.pki`、`.cert`、`.gnupg`）、`Trash`、系统桌面配置（`systemd`、`autostart`、`dconf`、`pulse`、`pipewire`）与主流浏览器及密码管理器（原生、Flatpak、Snap）。
- **Flatpak / Snap 与 `/tmp` 边界**：锁定 `~/.var/app/<id>/{config,data,cache}` 与 `~/snap/<name>/<rev>/{.config,.cache,.local,.local/share}` 根边界；递归校验拒绝跨挂载卷（`st_dev` / `volumeID` 不一致）；`/tmp` 沿用 Core `TempDirectoryScanner` 安全边界（不删 `/tmp` 根目录，仅限当前用户普通文件/目录，跳过符号链接、Socket/FIFO/设备文件、活跃锁与当前 `TMPDIR`，未归属条目强制仅手选）。

---

## 真实环境 CI 实装扫描记录

以下记录来自 GitHub Actions `rules-verify.yml`（Run `45848097381`，artifact：`rules-verify-windows`、`rules-verify-linux`）：

### Windows 真实环境（`Windows-2025Server-10.0.26100-SP0`）
- 实装并运行：`opencode 1.19.6`、`codex-cli 0.172.0`、`pi 1.6.1`、`gemini 0.71.1`、`claude 2.1.332`、`copilot 1.0.116`。
- `opencode debug paths` 实测路径：`data/log` 位于 `%USERPROFILE%\.local\share\opencode`，`cache` 位于 `%USERPROFILE%\.cache\opencode`（含 `bin`），`tmp` 位于 `%LOCALAPPDATA%\Temp\opencode`。
- `aicleaner-core.exe`（protocol v1.0，加载 30 个内置客户端）实扫结果：
  - `codex` · `codex-cli-tmp`（`recommended`，286 B，`C:\Users\runneradmin\.codex\tmp`）
  - `opencode` · `opencode-logs`（2015 B，`C:\Users\runneradmin\.local\share\opencode\log\opencode.log`，本轮据此由 `docs` 升级为 `ci`）
  - `opencode` · `opencode-protected-db`（`notRecommended` 硬锁定，249856 B，`opencode.db`）
  - `pi` · `pi-protected-auth`（`notRecommended` 硬锁定，2 B，`auth.json`）

### Linux 真实环境（`Linux-7.0.0-1020-azure-x86_64-with-glibc2.39`）
- 实装并运行：`opencode 1.19.6`、`codex-cli 0.172.0`、`claude 2.1.332`、`copilot 1.0.116`。
- `opencode debug paths` 实测路径：`data/log` 位于 `$XDG_DATA_HOME/opencode`，`cache` 位于 `$XDG_CACHE_HOME/opencode`（含 `bin`），`tmp` 位于 `/tmp/opencode`。
- `aicleaner-core`（protocol v1.0，加载 24 个内置客户端）实扫结果：
  - `opencode` · `opencode-logs`（`recommended`，2011 B，`$XDG_DATA_HOME/opencode/log/opencode.log`）
  - `opencode` · `opencode-protected-db`（`notRecommended` 硬锁定，249856 B，`$XDG_DATA_HOME/opencode/opencode.db`）
