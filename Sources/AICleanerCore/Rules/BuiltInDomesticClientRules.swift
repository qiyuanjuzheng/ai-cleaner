import Foundation

/// 国内主流 AI 客户端与工作伙伴规则扩展：
/// 覆盖 WorkBuddy / CodeBuddy、豆包工作伙伴 / 豆包、WorkDaddy、DeepSeek Harness、
/// Trae / Trae CN、Qoder、通义灵码、ZCode / 智谱清言、阶跃星辰、Kimi、腾讯元宝。
extension BuiltInClientRules {
    // MARK: - WorkBuddy（腾讯 WorkBuddy / CodeBuddy）

    public static let workBuddy = AIClientProfile(
        id: "workbuddy",
        name: "WorkBuddy",
        symbolName: "person.2.badge.gearshape.fill",
        accentToken: "workbuddy",
        description: "腾讯 WorkBuddy / CodeBuddy 的聊天会话、一次性任务工作目录、追踪日志与缓存",
        protectedSummary: "已锁定保护 binaries 运行时、plugins 插件、skills 技能库、security 凭据与 workbuddy.db",
        rules: [
            // 聊天会话 & 一次性任务目录
            ScanRule(
                id: "workbuddy-project-sessions",
                displayName: "项目聊天会话",
                path: ".workbuddy/projects",
                category: .sessions,
                mode: .projectSessions,
                recommendation: .reviewSuggested,
                explanation: "按单条对话展开 WorkBuddy 各项目的 .jsonl 会话与伴随产物。"
            ),
            ScanRule(
                id: "workbuddy-ai-project-sessions",
                displayName: "WorkBuddy AI 聊天会话",
                path: ".workbuddy-ai/projects",
                category: .sessions,
                mode: .projectSessions,
                recommendation: .reviewSuggested,
                explanation: "按单条展开 WorkBuddy AI 会话记录。"
            ),
            ScanRule(
                id: "workbuddy-task-folders",
                displayName: "一次性任务工作目录 (~/WorkBuddy)",
                path: "WorkBuddy",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "每次新建任务生成的时间戳工作目录（如 2026-11-...），会跳过含 .git 或敏感凭据的目录。"
            ),
            ScanRule(
                id: "workbuddy-workspace-sessions",
                displayName: "会话文件回滚快照 (workspace/sessions)",
                path: ".workbuddy/workspace/sessions",
                category: .temporary,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "会话修改文件时创建的备份。确认无需恢复后可勾选。"
            ),
            // 建议清理：缓存/追踪/日志/临时
            ScanRule(
                id: "workbuddy-traces",
                displayName: "执行追踪记录 (traces)",
                path: ".workbuddy/traces",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "历史任务执行链路追踪日志，体积增长很快，建议定期清理。"
            ),
            ScanRule(
                id: "workbuddy-blobs",
                displayName: "临时对象缓存 (blobs)",
                path: ".workbuddy/blobs",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "会话缓存的临时文件。"
            ),
            ScanRule(
                id: "workbuddy-logs",
                displayName: "运行日志 (logs)",
                path: ".workbuddy/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "WorkBuddy 客户端运行日志，建议清理。"
            ),
            ScanRule(
                id: "workbuddy-cache",
                displayName: "本地缓存 (cache)",
                path: ".workbuddy/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "客户端运行缓存，清理后按需自动重建。"
            ),
            ScanRule(
                id: "workbuddy-file-tree-manifests",
                displayName: "文件树索引缓存 (file-tree-manifests)",
                path: ".workbuddy/file-tree-manifests",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "项目目录结构快照缓存，建议清理，下次打开项目自动刷新。"
            ),
            ScanRule(
                id: "workbuddy-pending-telemetry",
                displayName: "待上报遥测缓存",
                path: "Library/Application Support/WorkBuddy/pending-telemetry",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "临时统计日志队列，建议清理。"
            ),
            ScanRule(
                id: "workbuddy-ai-logs",
                displayName: "WorkBuddy AI 日志",
                path: ".workbuddy-ai/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "WorkBuddy AI 模块运行日志，建议清理。"
            ),
            ScanRule(
                id: "workbuddy-ai-traces",
                displayName: "WorkBuddy AI 追踪日志",
                path: ".workbuddy-ai/traces",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "执行追踪日志文件，建议清理。"
            ),
            ScanRule(
                id: "workbuddy-ai-blobs",
                displayName: "WorkBuddy AI 临时对象缓存",
                path: ".workbuddy-ai/blobs",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "临时二进制缓存，建议清理。"
            ),
            ScanRule(
                id: "workbuddy-ai-cache",
                displayName: "WorkBuddy AI 本地缓存",
                path: ".workbuddy-ai/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "运行缓存，清理后自动重建。"
            ),
            ScanRule(
                id: "workbuddy-ai-audit-log",
                displayName: "WorkBuddy AI 审计日志",
                path: ".workbuddy-ai/audit-log",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "历史审计日志文件，建议清理。"
            ),
            ScanRule(
                id: "codebuddy-logs",
                displayName: "CodeBuddy 运行日志",
                path: ".codebuddy/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "CodeBuddy 扩展日志，建议清理。"
            ),
            ScanRule(
                id: "codebuddy-diagnostics",
                displayName: "CodeBuddy 诊断报告",
                path: ".codebuddy/diagnostics",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "一次性诊断报告文件，建议清理。"
            ),
            // 不建议清理（透明展示 + 锁定保护）
            protectedRule(
                id: "workbuddy-protected-binaries",
                displayName: "内置运行时组件 (binaries)",
                path: ".workbuddy/binaries",
                reason: "WorkBuddy 内置的运行环境与核心可执行组件，删除后客户端将无法正常执行任务并需重新下载数百 MB，不建议清理。"
            ),
            protectedRule(
                id: "workbuddy-protected-plugins",
                displayName: "已安装插件 (plugins)",
                path: ".workbuddy/plugins",
                reason: "包含已安装插件与扩展包，删除后需全部重装，不建议清理。"
            ),
            protectedRule(
                id: "workbuddy-protected-skills",
                displayName: "技能库 (skills)",
                path: ".workbuddy/skills",
                reason: "保存自定义与已导入的 Skills 工作流，不建议清理。"
            ),
            protectedRule(
                id: "workbuddy-protected-security",
                displayName: "安全与凭据目录 (security)",
                path: ".workbuddy/security",
                reason: "包含本地认证与安全校验数据，已锁定保护。"
            ),
            protectedRule(
                id: "workbuddy-ai-protected-binaries",
                displayName: "WorkBuddy AI 运行时 (binaries)",
                path: ".workbuddy-ai/binaries",
                reason: "核心运行时组件，删除后需重新下载，不建议清理。"
            ),
            protectedRule(
                id: "workbuddy-ai-protected-plugins",
                displayName: "WorkBuddy AI 插件 (plugins)",
                path: ".workbuddy-ai/plugins",
                reason: "已安装的扩展插件，不建议清理。"
            ),
            protectedRule(
                id: "workbuddy-ai-protected-db",
                displayName: "WorkBuddy 主数据库 (workbuddy.db)",
                path: ".workbuddy-ai/workbuddy.db",
                reason: "核心结构化数据库，已锁定保护。"
            )
        ]
    )

    // MARK: - 豆包工作伙伴 / 豆包（Doubao / DoubaoWork）

    public static let doubao = AIClientProfile(
        id: "doubao",
        name: "豆包工作伙伴 / 豆包",
        symbolName: "bubble.left.and.exclamationmark.bubble.right.fill",
        accentToken: "doubao",
        description: "豆包工作伙伴、豆包客户端与豆包代理的会话任务目录、飞书对话归档与渲染缓存",
        protectedSummary: "已锁定保护 ~/Doubao/skills、~/DoubaoWork/skills、public_config.json、Cookies 与 Local Storage",
        rules: [
            ScanRule(
                id: "doubao-workspace-tasks",
                displayName: "豆包任务工作目录 (~/Doubao)",
                path: "Doubao",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "豆包生成的单次任务与文档产物目录（已自动排除 skills/），确认无需保留即可移入废纸篓。"
            ),
            ScanRule(
                id: "doubao-work-tasks",
                displayName: "豆包工作伙伴任务目录 (~/DoubaoWork)",
                path: "DoubaoWork",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "豆包工作伙伴生成的任务产出目录（已自动排除 skills/），确认一次性任务完成后可清理。"
            ),
            ScanRule(
                id: "doubao-lark-chats",
                displayName: "飞书协同对话记录 (lark-chats)",
                path: ".doubao/lark-chats",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "按日期保存的豆包协同聊天归档。",
                isSessionArchive: true
            ),
            ScanRule(
                id: "doubao-sys-cache",
                displayName: "豆包系统缓存",
                path: "Library/Caches/com.bytedance.doubao",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的豆包缓存，建议清理。"
            ),
            ScanRule(
                id: "doubao-named-cache",
                displayName: "Doubao 系统缓存",
                path: "Library/Caches/Doubao",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "系统缓存目录，清理后自动重建。"
            ),
            ScanRule(
                id: "doubao-sys-logs",
                displayName: "豆包运行日志",
                path: "Library/Logs/Doubao",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "客户端运行日志文件，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "doubao-app", appSupportRelativePath: "Library/Application Support/Doubao")
        + standardElectronCacheRules(prefix: "jianyin-agent", appSupportRelativePath: "Library/Application Support/jianyin_agent")
        + [
            protectedRule(
                id: "doubao-protected-skills",
                displayName: "豆包技能目录 (~/Doubao/skills)",
                path: "Doubao/skills",
                reason: "保存自定义豆包技能，已锁定保护。"
            ),
            protectedRule(
                id: "doubao-work-protected-skills",
                displayName: "豆包工作伙伴技能 (~/DoubaoWork/skills)",
                path: "DoubaoWork/skills",
                reason: "保存豆包工作伙伴自定义技能，已锁定保护。"
            ),
            protectedRule(
                id: "doubao-protected-config",
                displayName: "豆包基础配置 (public_config.json)",
                path: "Library/Application Support/Doubao/public_config.json",
                reason: "客户端运行配置文件，已锁定保护。"
            ),
            protectedRule(
                id: "jianyin-agent-protected-storage",
                displayName: "代理本地存储与登录态 (Local Storage)",
                path: "Library/Application Support/jianyin_agent/Local Storage",
                reason: "保存登录状态与本地偏好，删除将退出登录，已锁定保护。"
            )
        ]
    )

    // MARK: - WorkDaddy

    public static let workDaddy = AIClientProfile(
        id: "workdaddy",
        name: "WorkDaddy",
        symbolName: "briefcase.fill",
        accentToken: "workdaddy",
        description: "WorkDaddy 桌面助手的运行日志、更新包与状态缓存",
        protectedSummary: "已锁定保护 accounts 账号凭据、credit-usage.db 与 automations.json",
        rules: [
            ScanRule(
                id: "workdaddy-daemon-log",
                displayName: "后台守护日志 (daemon.log)",
                path: "Library/Application Support/WorkDaddy/daemon.log",
                category: .logs,
                mode: .children,
                recommendation: .recommended,
                explanation: "WorkDaddy 守护进程运行日志，建议定期清理。"
            ),
            ScanRule(
                id: "workdaddy-launcher-log",
                displayName: "启动器日志 (launcher.log)",
                path: "Library/Application Support/WorkDaddy/launcher.log",
                category: .logs,
                mode: .children,
                recommendation: .recommended,
                explanation: "启动器诊断日志，建议清理。"
            ),
            ScanRule(
                id: "workdaddy-update",
                displayName: "自动更新缓存 (update)",
                path: "Library/Application Support/WorkDaddy/update",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "更新检查与安装包临时缓存，建议清理。"
            ),
            ScanRule(
                id: "workdaddy-discovery-cache",
                displayName: "自动化发现缓存",
                path: "Library/Application Support/WorkDaddy/automation-discovery-cache.json",
                category: .cache,
                mode: .children,
                recommendation: .recommended,
                explanation: "可自动重建的缓存索引文件，建议清理。"
            ),
            protectedRule(
                id: "workdaddy-protected-accounts",
                displayName: "账号与凭据目录 (accounts)",
                path: "Library/Application Support/WorkDaddy/accounts",
                reason: "保存登录账号与授权信息，已锁定保护。"
            ),
            protectedRule(
                id: "workdaddy-protected-db",
                displayName: "用量数据库 (credit-usage.db)",
                path: "Library/Application Support/WorkDaddy/credit-usage.db",
                reason: "本地用量记录数据库，不建议清理。"
            ),
            protectedRule(
                id: "workdaddy-protected-automations",
                displayName: "自动化配置 (automations.json)",
                path: "Library/Application Support/WorkDaddy/automations.json",
                reason: "保存用户配置的自动化任务，已锁定保护。"
            )
        ]
    )

    // MARK: - DeepSeek Harness

    public static let deepseekHarness = AIClientProfile(
        id: "deepseek",
        name: "DeepSeek Harness",
        symbolName: "flame.fill",
        accentToken: "deepseek",
        description: "DeepSeek Harness 桌面端与 CLI 的聊天会话、渲染缓存与日志",
        protectedSummary: "已锁定保护 ~/.dsh/electron 运行时、profiles 环境、settings.yaml、.credentials.yaml 与 .env",
        rules: [
            ScanRule(
                id: "deepseek-sessions",
                displayName: "聊天会话记录",
                path: ".dsh/sessions",
                category: .sessions,
                mode: .projectSessions,
                recommendation: .reviewSuggested,
                explanation: "按工作区展开单条 DeepSeek Harness 聊天会话记录。"
            ),
            ScanRule(
                id: "deepseek-sys-logs",
                displayName: "系统运行日志",
                path: "Library/Logs/DeepSeek Harness",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "DeepSeek Harness 运行诊断日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "deepseek-desktop", appSupportRelativePath: "Library/Application Support/@deepseek-ai/dsh-desktop")
        + [
            protectedRule(
                id: "deepseek-protected-electron",
                displayName: "内置 Electron 运行时 (electron)",
                path: ".dsh/electron",
                reason: "客户端运行依赖的内置运行时框架，删除将导致应用无法启动，不建议清理。"
            ),
            protectedRule(
                id: "deepseek-protected-profiles",
                displayName: "运行环境配置 (profiles)",
                path: ".dsh/profiles",
                reason: "保存模型与沙箱运行配置，不建议清理。"
            ),
            protectedRule(
                id: "deepseek-protected-creds",
                displayName: "认证凭据 (.credentials.yaml)",
                path: ".dsh/.credentials.yaml",
                reason: "保存账号或 API 凭据，已锁定保护。"
            )
        ]
    )

    // MARK: - Trae / Trae CN（字节跳动）

    public static let trae = AIClientProfile(
        id: "trae",
        name: "Trae / Trae CN",
        symbolName: "chevron.left.forwardslash.chevron.right",
        accentToken: "trae",
        description: "字节跳动 Trae 国际版与国内版编辑器缓存、更新包与运行日志",
        protectedSummary: "已锁定保护 ~/.trae & ~/.trae-cn 的 extensions 扩展、plugins、memory、user_rules、skills 与 trae-jwt-token",
        rules: [
            ScanRule(
                id: "trae-sys-cache",
                displayName: "Trae 系统缓存",
                path: "Library/Caches/Trae",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Trae 缓存，建议清理。"
            ),
            ScanRule(
                id: "trae-cn-sys-cache",
                displayName: "Trae CN 系统缓存",
                path: "Library/Caches/Trae CN",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Trae CN 缓存，建议清理。"
            ),
            ScanRule(
                id: "trae-sys-logs",
                displayName: "Trae 运行日志",
                path: "Library/Logs/Trae",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Trae 运行日志，建议清理。"
            ),
            ScanRule(
                id: "trae-cn-sys-logs",
                displayName: "Trae CN 运行日志",
                path: "Library/Logs/Trae CN",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Trae CN 运行日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "trae", appSupportRelativePath: "Library/Application Support/Trae", includeCachedData: true)
        + standardElectronCacheRules(prefix: "trae-cn", appSupportRelativePath: "Library/Application Support/Trae CN", includeCachedData: true)
        + [
            protectedRule(
                id: "trae-protected-extensions",
                displayName: "Trae 已安装扩展 (extensions)",
                path: ".trae/extensions",
                reason: "包含已安装的全部编辑器插件，删除后需逐一重装，不建议清理。"
            ),
            protectedRule(
                id: "trae-cn-protected-extensions",
                displayName: "Trae CN 已安装扩展 (extensions)",
                path: ".trae-cn/extensions",
                reason: "包含 Trae CN 已安装的全部扩展插件，体积常超过 2 GB，删除需重装，不建议直接清理。"
            ),
            protectedRule(
                id: "trae-protected-plugins",
                displayName: "Trae 插件目录 (plugins)",
                path: ".trae/plugins",
                reason: "包含已安装的内置与扩展插件，不建议清理。"
            ),
            protectedRule(
                id: "trae-protected-memory",
                displayName: "Trae 长期记忆 (memory)",
                path: ".trae/memory",
                reason: "保存跨会话项目记忆与偏好，不建议清理。"
            ),
            protectedRule(
                id: "trae-protected-token",
                displayName: "登录令牌 (trae-jwt-token)",
                path: ".trae/trae-jwt-token",
                reason: "包含账号登录态令牌，已锁定保护。"
            ),
            protectedRule(
                id: "trae-cn-protected-token",
                displayName: "Trae CN 登录令牌 (trae-jwt-token)",
                path: ".trae-cn/trae-jwt-token",
                reason: "包含账号登录态令牌，已锁定保护。"
            )
        ]
    )

    // MARK: - Qoder（阿里）

    public static let qoder = AIClientProfile(
        id: "qoder",
        name: "Qoder",
        symbolName: "curlybraces.square.fill",
        accentToken: "qoder",
        description: "阿里 Qoder AI IDE 缓存、更新包与运行日志",
        protectedSummary: "已锁定保护 ~/.qoder/extensions 扩展插件与 skills 技能库",
        rules: [
            ScanRule(
                id: "qoder-sys-cache",
                displayName: "Qoder 系统缓存",
                path: "Library/Caches/Qoder",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 下的 Qoder 缓存，建议清理。"
            ),
            ScanRule(
                id: "qoder-sys-logs",
                displayName: "Qoder 运行日志",
                path: "Library/Logs/Qoder",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Qoder 运行日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "qoder", appSupportRelativePath: "Library/Application Support/Qoder", includeCachedData: true)
        + [
            protectedRule(
                id: "qoder-protected-extensions",
                displayName: "已安装扩展目录 (extensions)",
                path: ".qoder/extensions",
                reason: "包含 Qoder 已安装的全部编辑器插件，删除后需重新下载安装，不建议清理。"
            ),
            protectedRule(
                id: "qoder-protected-skills",
                displayName: "自定义技能库 (skills)",
                path: ".qoder/skills",
                reason: "保存自定义技能与规则，不建议清理。"
            )
        ]
    )

    // MARK: - 通义灵码（Lingma）

    public static let lingma = AIClientProfile(
        id: "lingma",
        name: "通义灵码",
        symbolName: "text.badge.star",
        accentToken: "lingma",
        description: "阿里云通义灵码插件缓存、运行日志与本地代码检索索引",
        protectedSummary: "已锁定保护 ~/.lingma/bin 语言服务、model 模型、lingma_mcp.json 与 skills",
        rules: [
            ScanRule(
                id: "lingma-cache",
                displayName: "运行缓存 (cache)",
                path: ".lingma/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "通义灵码本地缓存，清理后按需自动重建，建议清理。"
            ),
            ScanRule(
                id: "lingma-logs",
                displayName: "运行日志 (logs)",
                path: ".lingma/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "通义灵码插件诊断日志，建议清理。"
            ),
            ScanRule(
                id: "lingma-tmp",
                displayName: "临时文件 (tmp)",
                path: ".lingma/tmp",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "运行过程产生的临时目录，建议清理。"
            ),
            ScanRule(
                id: "lingma-index",
                displayName: "本地代码检索索引 (index)",
                path: ".lingma/index",
                category: .cache,
                mode: .directory,
                recommendation: .reviewSuggested,
                explanation: "本地工程搜索索引，下次打开项目时会重新生成。"
            ),
            protectedRule(
                id: "lingma-protected-bin",
                displayName: "语言服务二进制 (bin)",
                path: ".lingma/bin",
                reason: "通义灵码核心语言服务可执行文件，删除后插件需重新下载，不建议清理。"
            ),
            protectedRule(
                id: "lingma-protected-model",
                displayName: "本地补全模型 (model)",
                path: ".lingma/model",
                reason: "代码补全依赖的轻量模型文件，不建议清理。"
            ),
            protectedRule(
                id: "lingma-protected-mcp",
                displayName: "MCP 配置文件 (lingma_mcp.json)",
                path: ".lingma/lingma_mcp.json",
                reason: "保存已配置的 MCP 服务连接，已锁定保护。"
            )
        ]
    )

    // MARK: - ZCode / 智谱清言（ZCode / ChatGLM）

    public static let zcode = AIClientProfile(
        id: "zcode",
        name: "ZCode / 智谱清言",
        symbolName: "z.square.fill",
        accentToken: "zcode",
        description: "智谱 ZCode 与智谱清言桌面端的会话工作区、操作产物、缓存与日志",
        protectedSummary: "已锁定保护 ~/.zcode/{agents, cli, bundled-agents} 与 ai.z.zcode 密钥存储",
        rules: [
            ScanRule(
                id: "zcode-workspace",
                displayName: "ZCode 会话工作区 (workspace)",
                path: ".zcode/workspace",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "按任务/会话保存的 ZCode 工作产物，确认一次性任务完成后可清理。"
            ),
            ScanRule(
                id: "zcode-projects",
                displayName: "ZCode 项目会话 (projects)",
                path: ".zcode/projects",
                category: .sessions,
                mode: .children,
                recommendation: .reviewSuggested,
                explanation: "项目维度保存的会话目录，按需勾选清理。"
            ),
            ScanRule(
                id: "zcode-computer-use",
                displayName: "电脑操作临时产物 (computer-use)",
                path: ".zcode/computer-use",
                category: .temporary,
                mode: .directory,
                recommendation: .reviewSuggested,
                explanation: "Computer Use 运行时保存的截图和产物。确认无需回看后可勾选。"
            ),
            ScanRule(
                id: "zcode-logs",
                displayName: "ZCode 运行日志 (logs)",
                path: ".zcode/logs",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "ZCode 运行日志文件，建议清理。"
            ),
            ScanRule(
                id: "zcode-cache",
                displayName: "ZCode 本地缓存 (cache)",
                path: ".zcode/cache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "运行缓存，建议清理。"
            ),
            ScanRule(
                id: "zcode-backup",
                displayName: "ZCode 历史备份 (backup)",
                path: ".zcode/backup",
                category: .temporary,
                mode: .directory,
                recommendation: .recommended,
                explanation: "历史自动备份临时目录，建议清理。"
            ),
            ScanRule(
                id: "chatglm-dawn-cache",
                displayName: "智谱清言 Dawn 缓存",
                path: "Library/Application Support/chatglm/DawnCache",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "图形着色器缓存，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "zcode-session", appSupportRelativePath: "Library/Application Support/ZCode/session")
        + standardElectronCacheRules(prefix: "chatglm", appSupportRelativePath: "Library/Application Support/chatglm")
        + [
            protectedRule(
                id: "zcode-protected-agents",
                displayName: "内置代理引擎 (agents)",
                path: ".zcode/agents",
                reason: "ZCode 核心代理运行环境，删除后需重新下载数百 MB，不建议清理。"
            ),
            protectedRule(
                id: "zcode-protected-cli",
                displayName: "内置 CLI 运行时 (cli)",
                path: ".zcode/cli",
                reason: "内置命令行工具链，删除会影响运行，不建议清理。"
            ),
            protectedRule(
                id: "zcode-protected-bundled",
                displayName: "预置代理组件 (bundled-agents)",
                path: ".zcode/bundled-agents",
                reason: "客户端自带核心组件，不建议清理。"
            ),
            protectedRule(
                id: "zcode-protected-auth",
                displayName: "认证与密钥库 (ai.z.zcode)",
                path: "Library/Application Support/ai.z.zcode",
                reason: "包含 API Key 与登录凭据存储，已锁定保护。"
            )
        ]
    )

    // MARK: - 阶跃星辰 / Kimi / 腾讯元宝

    public static let stepFun = AIClientProfile(
        id: "stepfun",
        name: "阶跃星辰",
        symbolName: "star.leadinghalf.filled",
        accentToken: "stepfun",
        description: "阶跃星辰桌面客户端渲染缓存与日志",
        protectedSummary: "已锁定保护 Cookies、Local Storage、Session Storage 与 setting.json",
        rules: standardElectronCacheRules(prefix: "stepfun", appSupportRelativePath: "Library/Application Support/stepfun-desktop")
        + [
            protectedRule(
                id: "stepfun-protected-storage",
                displayName: "登录态与本地存储 (Local Storage)",
                path: "Library/Application Support/stepfun-desktop/Local Storage",
                reason: "包含桌面端登录状态与个人设置，不建议清理。"
            ),
            protectedRule(
                id: "stepfun-protected-cookies",
                displayName: "Cookie 凭据 (Cookies)",
                path: "Library/Application Support/stepfun-desktop/Cookies",
                reason: "包含账号登录态，已锁定保护。"
            )
        ]
    )

    public static let kimi = AIClientProfile(
        id: "kimi",
        name: "Kimi",
        symbolName: "moon.stars.fill",
        accentToken: "kimi",
        description: "月之暗面 Kimi 桌面客户端缓存与运行日志",
        protectedSummary: "已锁定保护 Cookies、Local Storage、Session Storage 与用户配置",
        rules: [
            ScanRule(
                id: "kimi-sys-cache",
                displayName: "Kimi 系统缓存",
                path: "Library/Caches/com.moonshot.kimi",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 目录下的 Kimi 缓存，建议清理。"
            ),
            ScanRule(
                id: "kimi-sys-logs",
                displayName: "Kimi 运行日志",
                path: "Library/Logs/Kimi",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "Kimi 客户端诊断日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "kimi", appSupportRelativePath: "Library/Application Support/Kimi")
        + [
            protectedRule(
                id: "kimi-protected-storage",
                displayName: "登录态与本地存储 (Local Storage)",
                path: "Library/Application Support/Kimi/Local Storage",
                reason: "包含账号登录与本地状态，已锁定保护。"
            )
        ]
    )

    public static let yuanbao = AIClientProfile(
        id: "yuanbao",
        name: "腾讯元宝",
        symbolName: "sparkles.tv.fill",
        accentToken: "yuanbao",
        description: "腾讯元宝 macOS 桌面客户端缓存与运行日志",
        protectedSummary: "已锁定保护 Cookies、Local Storage、Session Storage 与账号配置",
        rules: [
            ScanRule(
                id: "yuanbao-sys-cache",
                displayName: "腾讯元宝系统缓存",
                path: "Library/Caches/com.tencent.yuanbao",
                category: .cache,
                mode: .directory,
                recommendation: .recommended,
                explanation: "macOS Caches 下的元宝缓存，建议清理。"
            ),
            ScanRule(
                id: "yuanbao-sys-logs",
                displayName: "腾讯元宝运行日志",
                path: "Library/Logs/Tencent Yuanbao",
                category: .logs,
                mode: .directory,
                recommendation: .recommended,
                explanation: "元宝运行日志，建议清理。"
            )
        ]
        + standardElectronCacheRules(prefix: "yuanbao", appSupportRelativePath: "Library/Application Support/Tencent Yuanbao")
        + [
            protectedRule(
                id: "yuanbao-protected-storage",
                displayName: "登录态与本地存储 (Local Storage)",
                path: "Library/Application Support/Tencent Yuanbao/Local Storage",
                reason: "包含账号登录态，已锁定保护。"
            )
        ]
    )
}
