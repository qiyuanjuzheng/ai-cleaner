# Implementation Plan: 主题系统与动效重设计

## Overview

本计划按依赖顺序把设计拆成增量的编码步骤：先做边车设置（Swift）与前端协议、纯逻辑，再建立令牌系统并迁移硬编码颜色，然后依次接入主题控制器、主题面板与原生菜单、过渡引擎、动效体系、Kiroween 装饰、季节邀请、布局优化，最后补充端到端验证与文档。实现语言：Swift（边车）、TypeScript / React（前端）、Rust（Tauri 宿主）、CSS。每个一级任务完成后，仓库的现有测试都应保持通过；会被改动破坏的现有测试在引入改动的同一任务中一并更新。不修改 `Sources/AICleanerApp`。

## Tasks

- [ ] 1. 边车设置：主题字段、部分补丁与协议
  - [-] 1.1 扩展 SidecarSettings 模型并实现宽松解码
    - 在 `Sources/AICleanerSidecar` 中新增 `ThemeID`（`default` / `kiroween`），为 `SidecarSettings` 增加 `themeId`（默认 `.default`）与可选 `seasonalPromptYear`
    - 自定义 `init(from:)`：`themeId` 先按可选 `String` 解码，缺失或未知值映射为 `.default`；`seasonalPromptYear` 缺失为 `nil`；两种情况都不抛错、不报告存储损坏
    - `encode(to:)` 写出全部三个字段
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

  - [~] 1.2 改造 SettingsStore：默认 `system`、部分更新、原子写入
    - `load()` 顺序：已保存的 Settings_File → 旧版应用外观偏好 → `.system`；前两者存在时保留其 `appearanceMode`
    - 新增 `update(appearanceMode:themeId:seasonalPromptYear:)`，参数均可选，先 `load()` 再只覆盖传入字段，沿用现有 `.atomic` 写入
    - 更新现有依赖旧默认值（非 `system`）或旧 `save` 签名的 XCTest（含 `testSettingsMigrationPersistenceAndCorruptBackup` 与旧版存储迁移测试），使其保持通过
    - _Requirements: 5.6, 5.8, 5.11, 12.5_

  - [~] 1.3 改造 `settings.get` / `settings.set` 的 RPC 处理
    - 在 `SidecarServer.swift` 中把 `settings.set` 改为部分补丁：不含已知字段、`themeId` 非法、`seasonalPromptYear` 不是 2000…9999 的整数、`appearanceMode` 非法时返回 `-32602`
    - 旧版仅发送 `{ appearanceMode }` 时接受并保留已存储的 `themeId` 与 `seasonalPromptYear`；合法补丁返回合并后的完整设置
    - `settings.get` 返回三个字段，`seasonalPromptYear` 可为 `null`；已有的损坏文件（`-32021`）行为保持不变
    - _Requirements: 5.1, 5.2, 5.9, 5.10, 12.3_

  - [~] 1.4 更新协议 schema 与样例 fixtures
    - 在 `protocol/rpc-v1.schema.json` 中新增 `$defs/settingsSetParams`（`minProperties: 1`、`additionalProperties: false`、`seasonalPromptYear` 为 2000–9999 整数）与 `$defs/settingsDTO`，并在 `request.allOf` 中为 `settings.set` 增加 `if/then` 分支
    - 方法名保持不变，新字段均为可选
    - 更新 `protocol/fixtures/rpc-v1-samples.json`：加入部分补丁、旧版 `{ appearanceMode }` 调用与带新字段的 `settings.get` 响应；确保现有 schema/fixture 校验测试仍通过
    - _Requirements: 5.12, 12.3_

  - [~] 1.5 补充边车自动化测试
    - 在 `SidecarFlowTests.swift` 中新增：无文件默认 `system`；旧版外观偏好被保留；未知 `themeId` 解码为 `default`；文件缺少新字段；部分补丁保留其他字段；非法参数返回 `-32602`；`seasonalPromptYear` 范围校验；`settings.set` 后 `settings.get` 往返一致
    - _Requirements: 5.3, 5.4, 5.5, 5.6, 5.8, 5.9, 5.10, 12.5_

  - [~] 1.6 编写属性测试：设置读写往返与部分补丁
    - **Property 3: 设置读写往返与部分补丁**
    - 使用带种子的 `RandomNumberGenerator`，迭代 200 次；标签 `Feature: theme-system-and-motion-redesign, Property 3`
    - **Validates: Requirements 5.9, 5.10, 5.13**

  - [~] 1.7 编写属性测试：宽松解码设置文件
    - **Property 4: 宽松解码设置文件**
    - 随机生成缺失/任意字符串 `themeId` 与缺失 `seasonalPromptYear` 的 JSON，断言解码成功且不报告损坏；迭代 200 次
    - **Validates: Requirements 5.3, 5.4, 5.5**

- [~] 2. Checkpoint - 边车设置完成
  - 运行 `swift test --filter AICleanerSidecarTests`，确保全部通过；如有疑问请询问用户。
- [ ] 3. 前端协议类型与纯逻辑（注册表、解析、季节）
  - [~] 3.1 更新 RPC 类型与 CoreClient 的部分补丁
    - 在 `rpc/types.ts` 新增 `ThemeId`、`SettingsDTO`（`themeId?`、`seasonalPromptYear?`）与 `SettingsPatch`
    - `rpc/client.ts` 的 `setSettings(patch)` 发送部分补丁；读取设置时把缺失或未知的 `themeId` 规范化为 `'default'`
    - 调整 `App.tsx` 等现有调用点与测试 mock 以适配新签名，行为保持不变，vitest 保持通过
    - _Requirements: 5.4, 5.10, 12.3_

  - [~] 3.2 添加 fast-check 开发依赖
    - 在 `apps/desktop/package.json` 增加 `fast-check` devDependency 并更新锁文件，确认 vitest 可导入
    - _Requirements: 12.6_

  - [~] 3.3 实现 Theme_Registry
    - 新增 `lib/themes.ts`：`ThemeKey`、`ThemeChoice`、`ThemeDefinition`（含 id、key、label、scheme、preview 配色、可选 decoration、transitionIn/Out、seasonal）与由注册表派生的 `THEME_OPTIONS`
    - 注册“浅色磨砂”、“深色极光”、“跟随系统”、Kiroween 四项；Kiroween 的 `scheme` 仅为 `dark`
    - _Requirements: 1.9, 1.10, 2.1, 2.2, 6.1_

  - [~] 3.4 实现主题解析与选择的纯函数
    - 在 `lib/themeState.ts` 实现 `resolveTheme`、`choiceOf`、`transitionKindBetween` 与选择归约函数 `applyChoice`（选 Kiroween 只改 `themeId`；选其他项设置 `themeId='default'` 与 `appearanceMode`）
    - 实现未知 `themeId` 回退到默认主题的规范化函数
    - 这些函数在任务 4（`applyThemeToRoot`）与任务 5（控制器）中接入
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 5.4_

  - [~] 3.5 实现季节判定
    - 新增 `lib/season.ts`：`isHalloweenSeason(date)`（本地时间，10 月 25 日至 12 月 15 日含两端）与 `shouldOfferInvitation({ date, themeId, seasonalPromptYear, suppressedThisRun })`
    - _Requirements: 7.1, 7.2, 7.3, 7.7, 7.8_

  - [~] 3.6 编写纯逻辑单元测试
    - 覆盖 `resolveTheme` / `choiceOf` 真值表、`applyChoice` 的外观恢复、未知 `themeId` 回退、注册表驱动 `THEME_OPTIONS`
    - 覆盖季节边界日期 10 月 24 日、10 月 25 日、12 月 15 日、12 月 16 日，以及跨年与已显示年份
    - _Requirements: 1.10, 4.2, 4.4, 4.5, 5.4, 7.2, 12.6_

  - [~] 3.7 编写属性测试：resolveTheme 全定义且 Kiroween 恒为深色
    - **Property 1: resolveTheme 全定义且 Kiroween 恒为深色**
    - 使用 fast-check，至少 200 次；标签 `Feature: theme-system-and-motion-redesign, Property 1`
    - **Validates: Requirements 4.2, 6.1, 1.3**

  - [~] 3.8 编写属性测试：离开 Kiroween 恢复原外观
    - **Property 2: 离开 Kiroween 恢复原外观，Kiroween 期间忽略系统明暗**
    - 随机生成选择与系统明暗变化序列，至少 200 次
    - **Validates: Requirements 4.4, 4.5, 4.7**

  - [~] 3.9 编写属性测试：季节判定与每年最多一次邀请
    - **Property 5: 季节判定与每年最多一次邀请**
    - 随机日期与跨年启动序列，至少 200 次
    - **Validates: Requirements 7.1, 7.2, 7.3, 7.7, 7.8**
- [ ] 4. 令牌系统、对比度与硬编码颜色迁移
  - [~] 4.1 创建分层令牌样式表
    - 新增 `styles/tokens.css`：为 `:root[data-theme-key='light'|'dark'|'kiroween']` 各定义 Base_Palette（`--p-*`）与全套 Semantic_Token（表面三级以上、文本、边框、推荐等级填充/文字两套、分类色、客户端强调色、图表色、聚焦环、滚动条、选区、品牌/危险渐变与 `-on` 色、背景氛围、阴影），取值采用设计文档中已验证的调色板
    - 在入口样式中引入；保留现有 `app.css` 使用的旧变量名，作为指向新 Semantic_Token 的别名，替换原有两组 `:root[data-theme]` 变量块，使现有界面外观正常、测试保持通过
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 1.6, 2.3, 2.4, 2.5, 2.6, 2.12, 6.2, 6.3, 6.4, 6.5_

  - [~] 4.2 实现 applyThemeToRoot 并接入现有主题应用点
    - 新增 `lib/themeRoot.ts`：在同一次同步调用内依次写入 `data-theme-key` 与 `data-theme`，其间没有 `await`
    - 把 `App.tsx` 中现有设置 `data-theme` 的逻辑改为通过 `resolveTheme` + `applyThemeToRoot`，现有 light/dark/system 行为不变
    - 在样式中加入 `:focus-visible` 聚焦环、`:focus:not(:focus-visible)`、`::selection` 与滚动条颜色，全部引用令牌
    - _Requirements: 1.3, 2.7, 2.8, 2.11_

  - [~] 4.3 让 JS/SVG 颜色映射引用令牌
    - 修改 `lib/theme.ts`：推荐等级、分类色返回 `var(--token)`；`clientAccentById` 返回 `var(--client-accent-<token>)`；需要文字色处使用 `--text-*` 变体
    - 同步更新依赖这些返回值（如 hex 字符串）的现有测试
    - _Requirements: 1.5, 1.7, 2.6_

  - [~] 4.4 迁移 App.tsx、Sidebar.tsx、ClientLogo.tsx 的硬编码颜色
    - 把 `activeAccent` 的字面量、侧边栏图块底色、`ClientLogo` 的 `#14b8a6` 换为 `--cat-*` / `--client-accent-*` / 品牌令牌
    - _Requirements: 1.7, 1.8_

  - [~] 4.5 迁移 BottomActionBar、TrashConfirmationModal、AddCustomDirectoryModal
    - 把 rgba 边框、徽标色及弹窗中的 hex/rgba 换为 `--surface-*`、`--border-*`、`--fill-*`、`--danger-*`、`--text-*`
    - _Requirements: 1.8, 2.5_

  - [~] 4.6 迁移 OrbitalScannerHero、VirtualizedItemList、ItemListView、StorageRingGauge
    - 渐变与 `#ffffff` 改用 `--brand-gradient`、`--brand-on`；列表徽标 rgba 改用 `--fill-*`、`--text-*`；环形仪表的描边与填充改用令牌
    - _Requirements: 1.7, 1.8, 2.6_

  - [~] 4.7 迁移 CleanupHistoryView、ExcludedItemsView、ProjectSessionsView
    - 图表色改为 `--chart-1..3`；已排除条目与项目会话中的 rgba 分别改为 `--fill-excluded`、`--fill-link`；使 SVG 图表随根元素令牌自动变色
    - _Requirements: 1.7, 1.8_

  - [~] 4.8 迁移 app.css 并重做 Aurora_Backdrop
    - 将 `app.css` 中剩余的硬编码 hex/rgba（装饰性纯黑/纯白遮罩与阴影透明度除外）替换为令牌
    - Aurora_Backdrop 改为两到三个光斑，仅用 `transform` 与 `opacity` 缓慢漂移，色调取自 `--aurora-a/b/c` 并随当前强调色调整
    - _Requirements: 1.8, 2.9, 2.10_

  - [~] 4.9 添加令牌完整性与硬编码颜色防回归测试
    - 新增 `no-raw-colors.test.ts`：扫描 `src/components/**`、`src/views/**`、`src/App.tsx`，出现 `#[0-9a-fA-F]{3,8}` 或 `rgba?(` 字面量即失败，白名单仅含 `#fff`、`#000`、`transparent` 与黑色阴影 rgba
    - 新增令牌完整性单元测试：各主题块声明的 Semantic_Token 名称集合一致
    - _Requirements: 1.2, 1.4, 1.8_

  - [~] 4.10 编写对比度验证测试
    - 新增 `lib/contrast.ts`（WCAG 相对亮度与对比度计算）与 `lib/contrast.test.ts`，把设计文档中各主题的前景/背景/阈值组合写为测试数据，解析 `styles/tokens.css` 逐项断言达标（含按钮文字、`--text-*`、`--focus-ring`、Kiroween 品牌紫仅作填充）
    - _Requirements: 2.3, 2.4, 2.5, 2.6, 2.7, 2.12, 6.4, 13.1_

  - [~] 4.11 编写属性测试：令牌完整性
    - **Property 6: 令牌完整性**
    - 以主题块对为输入的 fast-check 测试，至少 200 次
    - **Validates: Requirements 1.2, 1.4**

  - [~] 4.12 编写属性测试：对比度达标
    - **Property 7: 对比度达标**
    - 对每个主题中声明的 (前景, 背景, 阈值) 组合断言 WCAG 对比度 ≥ 阈值
    - **Validates: Requirements 2.3, 2.4, 2.5, 2.6, 2.12, 6.4, 13.1**
- [ ] 5. ThemeController 与启动序列
  - [~] 5.1 实现 ThemeProvider 与 useThemeController
    - 新增 `lib/themeController.ts`：持有 `ThemeState`（`themeId`、`appearanceMode`、`systemDark`），暴露 `selectTheme(choice, { origin?, source })`，经 `resolveTheme` 得到目标主题后，用 `flushSync` 加 `applyThemeToRoot` 同步提交（本阶段为瞬时提交，任务 8 替换为过渡引擎）
    - `source` 为 `panel | menu | invitation | system | boot`；除 `boot` 外乐观调用 `settings.set({ themeId, appearanceMode })`，持久化失败时记录日志并保留已应用主题
    - _Requirements: 3.6, 3.13, 4.1, 4.4, 4.5_

  - [~] 5.2 实现系统明暗监听
    - 订阅 `matchMedia('(prefers-color-scheme: dark)')` 的 `change`：`themeId='default'` 且 `appearanceMode='system'` 时立即重新解析并提交（来源 `system`，从不触发 Kiroween 编排）；Kiroween 或固定 light/dark 时仅更新 `systemDark`
    - 不支持 `matchMedia` 时视为浅色
    - _Requirements: 4.6, 4.7, 4.8_

  - [~] 5.3 实现启动序列 bootTheme 与首帧中性背景
    - 在 `index.html` 加入内联中性背景（跟随 `prefers-color-scheme`）与 `#root { visibility: hidden }`；`main.tsx` 渲染前执行 `bootTheme(core)`：握手后用 `core.getSettings()` 与 1000 ms 计时器竞速，成功则无过渡直接应用，超时或失败则应用默认主题与 `system` 并标记 `bootFallback`，随后渲染并取消隐藏
    - 设置在回退之后才到达时，经 `selectTheme(choice, { source: 'boot' })` 应用，且不发送 `settings.set`
    - 其余启动加载保持现有 `Promise.allSettled`，握手失败横幅路径不变
    - _Requirements: 5.6, 5.7, 5.8, 5.14, 5.15, 5.16_

  - [~] 5.4 用控制器替换循环按钮并更新现有测试
    - 在 `App.tsx` 接入 ThemeProvider，移除 `nextAppearanceMode` 与循环切换逻辑；`appearanceDisplayName` 改用注册表 label；`Toolbar` 外观入口保留 `data-testid="toolbar-appearance"`，暂以按注册表依次选择的最小交互替代（任务 7 换为 ThemePanel）
    - 更新 `App.test.tsx`（mock transport 返回 `themeId`，断言 `settings.set` 收到 `{ themeId: 'default', appearanceMode: ... }`）与 `Toolbar.test.tsx`，使 vitest 保持通过
    - _Requirements: 3.6, 3.12, 12.4_

  - [~] 5.5 编写控制器与启动序列单元测试
    - 使用假计时器与 mock transport：设置在 10 ms 返回、永不返回（1000 ms 回退）、1500 ms 才返回（先回退再走切换路径且不回写）、读取被拒绝；持久化失败仍应用主题；系统明暗在 Kiroween / 固定模式下不改变显示
    - _Requirements: 3.13, 4.6, 4.7, 5.14, 5.15, 5.16, 12.6_

  - [~] 5.6 编写属性测试：启动时序
    - **Property 12: 启动时序**
    - 对任意设置到达时间（含永不到达与读取失败）断言：t ≤ 1000 ms 时首次应用已保存主题且无过渡，否则先回退，到达后应用已保存主题且不发送 `settings.set`
    - **Validates: Requirements 5.14, 5.15, 5.16**

- [~] 6. Checkpoint - 控制器与启动序列完成
  - 运行 `npm run typecheck` 与 `npm test`，确保全部通过；如有疑问请询问用户。
- [ ] 7. 主题面板与原生菜单
  - [~] 7.1 实现 ThemePanel 与 Preview_Card
    - 新增 `components/ThemePanel.tsx`：弹出层 `role="radiogroup"`，遍历 `THEME_OPTIONS` 渲染 4 张 `role="radio"` 卡片；每张卡片以 CSS 绘制迷你窗口（侧边栏条、两张卡片、强调色圆点与进度条），“跟随系统”沿对角线拼接浅/深预览
    - 选中项由 `choiceOf(state)` 决定，带勾选图标与描边；Kiroween 生效时三张外观卡片都不选中
    - 悬停/聚焦在 ≤ 160 ms 内上浮并加阴影；面板暂用基础 CSS 进入动画（任务 9 迁移到统一 Presence 模式）
    - _Requirements: 1.10, 3.1, 3.2, 3.3, 3.4, 3.5, 4.3, 10.1_

  - [~] 7.2 实现 ThemePanel 键盘操作与无障碍
    - roving tabindex：方向键移动、Enter/空格确认、Esc 关闭并把焦点还给工具栏按钮；每个选项带 `aria-checked` 与由 label + caption 组成的可访问名称；点击/按键立即响应，不等待预览动画
    - _Requirements: 3.7, 3.8, 10.4_

  - [~] 7.3 把 ThemePanel 接入 Toolbar 并更新测试
    - `Toolbar` 的 `data-testid="toolbar-appearance"` 按钮改为打开 ThemePanel（`aria-haspopup="dialog"`、`aria-expanded`，标签显示当前选择）；选择时调用 `selectTheme(choice, { origin: 卡片中心, source: 'panel' })` 并立即关闭面板；移除任务 5.4 的临时交互
    - 更新 `Toolbar.test.tsx`、`App.test.tsx` 与 `e2e/desktop.e2e.spec.ts` 第 10 步：打开面板选择“深色极光”，断言 `html[data-theme-key='dark']` 且 `data-theme='dark'`；选择 Kiroween 断言 `data-theme-key='kiroween'`；重新加载后通过真实边车验证持久化
    - _Requirements: 3.6, 3.12, 12.4_

  - [~] 7.4 实现 Rust 原生菜单主题单选项与菜单状态命令
    - `src-tauri/src/menu.rs`：用“外观”子菜单替换 `appearance.cycle`，含 4 个 `CheckMenuItem`（`theme.light`、`theme.dark`、`theme.system`、`theme.kiroween`），经现有 `menu://action` 发出；点击后处理函数立即重设唯一勾选项
    - `lib.rs` 注册命令 `set_theme_menu_state(choice)`，菜单项句柄存入 managed state；在 `capabilities/default.json` 加入权限
    - _Requirements: 3.9, 3.11_

  - [~] 7.5 前端接入菜单动作与菜单状态同步
    - `MenuActionId` 用 4 个主题 id 替换 `'appearance.cycle'`；控制器把它们映射为 `selectTheme(choice, { origin: 工具栏按钮中心, source: 'menu' })`，应用结果与面板一致
    - 每次选择应用后（含启动时）调用 `set_theme_menu_state(choice)`；非 Tauri 环境（HTTP 桥、vitest）对应 transport 方法为空操作，失败时忽略；更新受影响的现有测试
    - 对 `src-tauri` 运行 `cargo check`
    - _Requirements: 3.9, 3.10, 3.11, 12.4_

  - [~] 7.6 编写 ThemePanel 单元测试
    - 键盘导航与 aria 属性、选中标记不依赖颜色、选择触发 `selectTheme`、Kiroween 生效时三张外观卡片均未选中
    - _Requirements: 3.5, 3.7, 3.8, 4.3_

  - [~] 7.7 编写属性测试：面板由注册表驱动
    - **Property 8: 面板由注册表驱动**
    - 任意注册表内容与 ThemeState 下，面板按顺序为每个选项渲染且只渲染一个 radio，恰有一个选中且等于 `choiceOf(state)`
    - **Validates: Requirements 1.10, 3.2, 3.5, 4.3**

- [ ] 8. 主题切换过渡引擎
  - [~] 8.1 实现过渡阶段数据与 validatePhases
    - 新增 `lib/themeTransition.ts` 的阶段模型：`circle`（680 ms）、`summon`（flicker 0–120、flight 120–700、engulf 700–1400，蝙蝠 700–1300）、`dawn`（vanish 0–300、wipe 300–950）以阶段数据声明；`validatePhases()` 校验顺序、禁止重叠与总时长预算
    - 在 `ThemeDefinition.transitionIn/Out` 中引用对应规格
    - _Requirements: 8.2, 8.3, 8.4, 8.13_

  - [~] 8.2 实现 runThemeTransition 的降级、Reduced_Motion 与清理框架
    - 特性检测 `document.startViewTransition`；不可用或 summon/dawn 缺少 mask 支持时使用 `html.theme-xfade`（320 ms，`background-color`/`color`/`border-color`/`fill`/`stroke`）；`prefers-reduced-motion` 命中则瞬时 commit
    - commit 回调内同步 `applyThemeToRoot` 并 `flushSync` 更新 React 状态；常驻 FX 层容器，子节点每次运行时创建并在 `finally` 中移除，同时移除 `data-theme-transition`；任何错误回退为瞬时 commit；过渡不等待 RPC
    - _Requirements: 8.6, 8.7, 8.8, 8.10, 8.11, 8.14, 13.6_

  - [~] 8.3 实现 circle 圆形揭示过渡
    - View Transition 下用 `clip-path: circle()` 从点击位置展开到最远角，FX 光环沿边缘缩放并使用主题 `--fx-ring` 光晕；旧快照缩放至 0.985 并变暗；关闭 UA 默认动画的 CSS；macOS 透明窗口过渡期间临时使用不透明 `--canvas-bg`
    - `light ↔ dark` 与系统明暗变化（含 `source: 'system'`）使用该类型
    - _Requirements: 8.1, 8.2, 4.8, 8.12_

  - [~] 8.4 实现 summon 与 dawn 过渡
    - summon：旧快照亮度闪烁 120 ms → Kiro 幽灵（内联 SVG 精灵）从触发按钮飞向中心 → 幽灵形 `mask-image`（同时写 `-webkit-mask-*`）放大吞没屏幕，蝙蝠 SVG 从边缘散开
    - dawn：幽灵缩小消失后，新快照线性渐变遮罩自上而下擦除并带日光线；vanish 必须在 wipe 之前结束
    - 先落地幽灵 SVG 单一路径模块 `components/decorations/ghost.ts`，供过渡与任务 11 复用
    - _Requirements: 8.3, 8.4, 8.13, 13.7_

  - [~] 8.5 实现打断处理并接入控制器
    - 过渡进行中收到新选择时 `skipTransition()`，取消进行中的 Web Animations 并重置 FX 层，以最新选择为目标继续，只持久化最后一次选择
    - `selectTheme` 通过 `transitionKindBetween` 选择类型并调用 `runThemeTransition`，替换任务 5.1 的瞬时提交；`source: 'system'` 只产生 `circle`；晚到的启动设置（`source: 'boot'`）同样走该路径
    - _Requirements: 3.6, 5.16, 8.5, 8.8_

  - [~] 8.6 编写过渡引擎单元测试
    - 使用 mock 的 `startViewTransition`、假计时器与 `matchMedia`：Reduced_Motion 即时切换且无 FX 节点、降级路径、阶段错误回退、清理后无残留节点与 `data-theme-transition`、各过渡阶段顺序与时长预算、主题切换后令牌在 100 ms 内生效
    - _Requirements: 8.1, 8.6, 8.7, 8.10, 8.11, 8.13, 8.14, 13.2_

  - [~] 8.7 编写属性测试：过渡控制器最终状态一致
    - **Property 9: 过渡控制器最终状态一致**
    - 任意选择序列（含打断、Reduced_Motion 开关、是否支持 View Transitions），结束后根属性等于 `resolveTheme(最后一次选择)`，FX 层为空，`data-theme-transition` 不存在，最后持久化的是最后一次选择
    - **Validates: Requirements 8.5, 8.10, 8.11, 1.3**

  - [~] 8.8 编写属性测试：编排校验
    - **Property 10: 编排校验**
    - 任意阶段列表被接受当且仅当顺序、重叠与总时长均合法；内置三类合法，dawn 非原顺序排列被拒绝
    - **Validates: Requirements 8.2, 8.3, 8.4, 8.13**
- [ ] 9. 全应用动效体系
  - [~] 9.1 建立动效令牌与 Reduced_Motion 规则
    - 新增 `styles/motion.css`（`--dur-press/hover/enter/exit/view/emphasis/count`、`--ease-standard/enter/exit/spring`）与 `lib/motion.ts` 同名 TS 常量及 reduced-motion 查询
    - 把 `app.css` 中现有 140ms / 220ms 等字面量全部替换为令牌；添加单个 `@media (prefers-reduced-motion: reduce)` 块：位移/缩放/旋转/循环动画改为 ≤ 100 ms 淡入淡出或直接切换；应用内不提供动效设置
    - _Requirements: 9.1, 9.2, 9.3, 9.15, 9.19_

  - [~] 9.2 实现窗口可见性 hook 并暂停循环动画
    - 新增 `useWindowVisibility`，以 `document.hidden` 与 `visibilitychange` 为依据，窗口隐藏时在根元素设置 `data-window-hidden`；CSS 在该属性下把所有装饰与循环动画设为 `animation-play-state: paused`；在 `App.tsx` 中挂载
    - _Requirements: 6.14, 9.16_

  - [~] 9.3 实现 Presence 组件与共享进入/退出模式
    - 新增 `components/Presence.tsx`：子元素带 `data-state="open|closed"`，`animationend` 后卸载并设退出令牌 + 50 ms 兜底超时，动画中再次开关立即反转，不等待动画
    - 在 `motion.css` 定义模态框（遮罩淡入 + 面板缩放/位移）、弹出层/菜单、Dock/提示条三种共享模式
    - _Requirements: 9.5, 9.6, 9.17, 9.18_

  - [~] 9.4 把现有模态框、弹出层与 Bottom_Dock 迁移到 Presence
    - 为 `TrashConfirmationModal`、`AddCustomDirectoryModal`、ThemePanel 弹出层、其他菜单/弹出层以及 `BottomActionBar` 使用 Presence 与共享模式，先退出动画后移除节点；更新受影响的现有测试（如依赖节点立即消失的断言）
    - _Requirements: 9.5, 9.6, 9.12, 9.17, 10.2_

  - [~] 9.5 实现侧边栏视图过渡
    - 详情内容容器设置 `key={viewKey}`，进入时 260 ms 内 opacity 0→1、`translateY(6px)`→0，不做退出；保持列表滚动位置恢复行为不变
    - _Requirements: 9.4, 9.13_

  - [~] 9.6 实现列表行进入/退出动画
    - 虚拟列表维护 `listEpoch`（筛选、搜索、排除、清理时递增，滚动不递增）；epoch 变化时仅视口内已渲染的行获得 `data-enter`（错开 18 ms，最多 8 行，220 ms）；被移除的行在快照覆盖层上播放 160 ms 的 opacity + `translateX(8px)` 退出，不做高度动画；滚动挂载的行不播放动画
    - _Requirements: 9.7, 9.8, 9.13, 9.14_

  - [~] 9.7 实现 CountUp 并接入 Dashboard_Card 与 Bottom_Dock
    - 新增 `components/CountUp.tsx`：rAF 补间，每帧调用 `formatBytes`，`tabular-nums`，时长 ≤ 600 ms，ease-out，Reduced_Motion 直接跳到目标值
    - 用于环形仪表中心、三档分段数值与 Bottom_Dock 的已选数量/大小；更新相关现有测试以适配动画后的数值呈现
    - _Requirements: 9.9, 9.15_

  - [~] 9.8 实现扫描阶段与清理成功动画
    - 阶段胶囊状态切换做 220 ms 背景色与缩放脉冲；扫描完成后扫描器缩放至 0.96 并在 200 ms 内淡出，结果视图按视图过渡进入
    - 清理成功时提示按 Dock 模式进入并叠加默认粒子迸发（主题可替换，见任务 11）；Dock 与列表以动画反映条目移除，CountUp 显示减少后的数值
    - _Requirements: 9.10, 9.11, 9.12_

  - [~] 9.9 添加动效属性白名单防回归测试
    - vitest 解析 `app.css`、`motion.css`、`tokens.css` 中 `transition`、`animation` 与 keyframes，出现 `width`、`height`、`top`、`left`、`right`、`bottom`、`margin`、`padding` 即失败；白名单为 `transform`、`opacity`、`clip-path`、`mask`/`-webkit-mask`、`filter`（仅主题闪烁）、`color`/`background-color`（仅悬停与降级淡入淡出）
    - 为 Presence 卸载时机、CountUp 的 Reduced_Motion 行为编写单元测试
    - _Requirements: 9.6, 9.9, 9.13, 9.15_

  - [~] 9.10 编写属性测试：动效属性白名单
    - **Property 13: 动效属性白名单**
    - 对样式表中任意 `transition` / `animation` 声明与 keyframe，被动画的属性都在白名单内
    - **Validates: Requirements 9.13**

- [~] 10. Checkpoint - 动效体系完成
  - 运行 `npm run typecheck` 与 `npm test`，确保全部通过；如有疑问请询问用户。
- [ ] 11. Kiroween 装饰层与主题专属效果
  - [~] 11.1 实现 KiroweenDecorations 装饰层
    - 新增 `components/decorations/KiroweenDecorations.tsx` 并注册为 Kiroween 的 `decoration`，仅在 `data-theme-key='kiroween'` 时挂载；固定定位全窗口层，`pointer-events: none`、`aria-hidden="true"`，层级高于画布、低于模态框与 Bottom_Dock
    - 元素：侧边栏品牌旁 18 px 小幽灵（3.2 s 漂浮）、详情区右上角蛛网（120 px、18% 不透明度、位于卡片之外）、底部两层薄雾（高度 ≤ 120 px、不透明度 ≤ 0.35、`translateX` 40 s/60 s 漂移）、每 25–40 s 飞过一次的蝙蝠；复用 `ghost.ts` 路径
    - 在 `App.tsx` 中通过注册表挂载；动画仅用 `transform`/`opacity`，窗口隐藏时暂停，Reduced_Motion 下静态显示
    - _Requirements: 6.7, 6.8, 6.12, 6.13, 6.14, 6.15, 13.6, 13.7_

  - [~] 11.2 实现南瓜灯扫描光球与蝙蝠轨道扫描器
    - 在 `OrbitalScannerHero` 中，Kiroween 下就绪光球显示为南瓜灯（橙到紫径向渐变、雕刻眼口 SVG、烛光闪烁）；扫描进行中两条轨道环替换为 3 只以不同半径与速度绕行的蝙蝠
    - 通过 `[data-theme-key='kiroween']` 选择器与条件渲染实现，不影响其他主题；Kiroween 下使用深色客户端 Logo 变体
    - _Requirements: 6.6, 6.9, 6.10_

  - [~] 11.3 实现小幽灵清理成功效果
    - 清理成功时 Kiroween 下以 5–7 只小幽灵在 1.2 s 内上浮淡出取代默认粒子迸发；Reduced_Motion 下改为单个幽灵图标 100 ms 淡入
    - _Requirements: 6.11, 6.15_

  - [~] 11.4 实现 Preview_Card 迷你装饰动画
    - 悬停或聚焦时按主题播放迷你装饰动画：深色为极光光斑漂移，浅色为光泽扫过，Kiroween 为幽灵漂浮加一只蝙蝠；Reduced_Motion 或窗口隐藏时暂停；选择仍立即响应
    - _Requirements: 10.3, 10.4, 9.15, 9.16_

  - [~] 11.5 编写 Kiroween 装饰与效果测试
    - 单元测试：装饰层仅在 Kiroween 下挂载、`pointer-events: none` 与 `aria-hidden`、窗口隐藏时 `data-window-hidden` 暂停、Reduced_Motion 静态；Kiroween 下 Logo 变体选择深色
    - _Requirements: 6.6, 6.12, 6.14, 6.15_

- [ ] 12. 季节性邀请
  - [~] 12.1 实现邀请状态机
    - 在 ThemeController 中增加 `InvitationState`（`none | pending | shown | suppressed`）：启动完成后用启动日期调用一次 `shouldOfferInvitation`，为 true 则记录启动年份并置 `pending`；扫描或清理进行中保持 `pending`，结束后显示（即使季节已结束）；季节外启动从不产生 pending；pending 期间进入 Kiroween 则丢弃
    - 显示时立即 `settings.set({ seasonalPromptYear })`；写入失败则本次运行内置 `suppressedThisRun`
    - _Requirements: 7.1, 7.3, 7.4, 7.7, 7.9, 7.10, 7.13_

  - [~] 12.2 实现 SeasonalInvitationDialog 并接入 App
    - 新增 `components/SeasonalInvitationDialog.tsx`：使用 Presence 的模态框模式，`role="dialog"`、`aria-modal`、`aria-labelledby`/`aria-describedby`，初始焦点在“试用 Kiroween”，焦点限制在对话框内，Esc 等同“关闭”，关闭后焦点还给此前元素；含 Kiro 幽灵插画、标题与说明
    - 试用时调用 `selectTheme('kiroween', { origin: 按钮中心, source: 'invitation' })` 播放召唤过渡；关闭时保持当前主题；在 `App.tsx` 接入扫描/清理状态
    - _Requirements: 7.5, 7.6, 7.11, 7.12, 7.14_

  - [~] 12.3 编写季节邀请测试
    - 使用假日期与 mock transport：边界日期 10 月 24 日/25 日、12 月 15 日/16 日；跨年再次显示；扫描中推迟且季节结束后仍显示；写入失败后本次运行不再弹出；Kiroween 生效时不弹出；季节外 Kiroween 仍可在面板与菜单中选择；对话框键盘与焦点行为
    - _Requirements: 7.1, 7.2, 7.3, 7.7, 7.8, 7.9, 7.10, 7.12, 7.13, 7.14, 12.6_
- [ ] 13. 布局优化
  - [~] 13.1 修复 Disk_Footer 与平台留白
    - `height: 82px` 改为 `min-height`，加内边距，`.disk-bar-track { flex-shrink: 0 }` 保证进度条 5 px 可见
    - macOS 覆盖式标题栏仅在 `:root[data-platform='macos']` 下为 `.sidebar-header` 预留 78 px 左内边距，Windows/Linux 使用 14 px；`.detail-pane`、列表行设置 `min-width: 0`，避免水平滚动条
    - _Requirements: 11.1, 11.13, 11.14, 11.15_

  - [~] 13.2 实现 Control_Bar 响应式布局
    - 所有按钮 `white-space: nowrap; flex-shrink: 0`；分类分段控件可收缩并横向滚动（隐藏滚动条、两端渐隐）；搜索框 `flex: 0 1 220px; min-width: 140px`
    - 在 `.detail-content` 设置 `container-type: inline-size`：≥ 760 px 单行完整；< 760 px “项目会话”收起为仅图标（保留 aria-label 与 tooltip）；< 640 px 分类分段控件移入选项菜单的“分类”分组；不支持容器查询时依靠可收缩搜索框与可滚动分段控件
    - _Requirements: 11.2, 11.3_

  - [~] 13.3 实现路径中间省略与 Item_Row 调整
    - 新增 `lib/pathEllipsis.ts`（按 `/` 或 `\` 切分，保留 `~` 前缀与最后一段，中间折叠为 `…`，使用 canvas `measureText` 与区间缓存）与 `components/MiddleEllipsisPath.tsx`（ResizeObserver 测宽，完整路径放入 `title` 与无障碍描述）
    - 在 Item_Row 中使用；安全说明改为路径之后可截断的独立 span，标题与锁定/风险徽标 `flex-shrink: 0`
    - _Requirements: 11.4, 11.5, 11.6_

  - [~] 13.4 实现行内操作的悬停/聚焦显示
    - `.row-actions` 默认 `opacity: 0`，在 `.item-row-card:hover`、`:focus-within` 与已选中行上显示；按钮始终保留在 DOM 与 Tab 顺序中；`@media (hover: none)` 下始终可见
    - _Requirements: 11.9, 11.10_

  - [~] 13.5 压缩 Dashboard_Card 并处理 Bottom_Dock 遮挡
    - 移除 `HairlineStorageBar` 及其间距，内边距改为 12px 14px，分档条高度 46 px，外层 padding 2/8，卡片高度约 128 px
    - Dock 用 ResizeObserver 测量自身高度并写入 `--dock-height`，虚拟列表底部内边距为 `calc(var(--dock-height, 0px) + 28px)`；在 1020×660 下可见区域至少容纳 5 行；更新依赖旧结构的现有测试
    - _Requirements: 11.7, 11.8, 11.12_

  - [~] 13.6 添加侧边栏空状态提示与调整 Return_To_Scan_Control
    - 首次扫描前“AI 客户端”分组以 tertiary 文本显示“扫描后将列出检测到的 AI 客户端”
    - `return-to-idle-btn` 从胶囊按钮改为低强调的文本幽灵按钮（`--text-secondary`、chevron 图标），位于主操作左侧并额外留 8 px 间距；标签、aria、`data-testid` 与行为不变；更新受影响的现有测试
    - _Requirements: 11.11, 11.16_

  - [~] 13.7 编写布局相关单元测试
    - 测试 `pathEllipsis` 与 `MiddleEllipsisPath`（保留末段、`title` 含完整路径）、行内操作始终保留在 DOM、空状态提示文案、`return-to-idle-btn` 的标签与可访问名称不变
    - _Requirements: 11.4, 11.5, 11.10, 11.11, 11.16_

  - [~] 13.8 编写属性测试：路径中间省略
    - **Property 11: 路径中间省略**
    - 任意 POSIX/Windows 路径与不小于“末段 + 省略号”宽度的预算，输出保留完整末段、仅在需要时含省略号、测得宽度 ≤ 预算、`title` 含完整路径
    - **Validates: Requirements 11.4, 11.5**

- [ ] 14. 端到端验证、截图脚本与文档
  - [~] 14.1 新增 Reduced_Motion 与主题持久化 e2e
    - 在 `e2e/desktop.e2e.spec.ts` 中：用 `page.emulateMedia({ reducedMotion: 'reduce' })` 断言主题属性一帧内切换且从未出现 `data-theme-transition`；通过真实边车验证主题与外观重载后保留
    - _Requirements: 12.7, 12.8, 5.9_

  - [~] 14.2 新增 1020×660 布局断言 e2e
    - 在 Minimum_Window 下断言：无水平滚动（`scrollWidth <= clientWidth`）、磁盘进度条高度 > 0、可见行数 ≥ 5、最后一行不被 Dock 遮挡、控件文字不竖向折行
    - _Requirements: 11.1, 11.2, 11.7, 11.12, 11.15_

  - [~] 14.3 新增 5,200 行场景帧时间采样
    - 在现有 5,200 行 e2e 场景中，滚动并切换主题期间用 rAF 采样帧时间；具备 CI 能力的运行器上断言平均 ≥ 50 fps，慢速运行器只报告不断言
    - _Requirements: 8.9, 9.14_

  - [~] 14.4 新增主题截图脚本
    - 新增 Playwright 截图脚本，覆盖 3 个主题 × 2 种尺寸（1020×660、1200×780）× 5 个页面（ready、overview、client、history、excluded），输出到约定目录
    - _Requirements: 11.15, 13.1_

  - [~] 14.5 更新文档与变更记录
    - 更新 `docs/tauri-parity-checklist.md`（主题面板、Kiroween、动效）与 `CHANGELOG.md`
    - _Requirements: 12.1, 12.3_

- [~] 15. Final checkpoint - 全量验证
  - 依次运行 `npm run typecheck`、`npm test`、`npm run build`（`apps/desktop`）、`cargo check`（`apps/desktop/src-tauri`）与 `swift test`，确保全部通过；如有疑问请询问用户。

## Notes

- 标记 `*` 的子任务为可选（属性测试等），可跳过以加快 MVP；需求明确要求的单元测试未标记为可选
- 每个任务引用具体需求编号以便追溯；检查点保证增量验证
- 属性测试验证设计文档中的通用正确性属性，单元测试验证具体示例与边界
- 会破坏现有测试的改动，在引入该改动的同一任务中同步更新测试
- 不修改 `Sources/AICleanerApp`；CPU 占用测量（需求 13.3、13.8）属于人工验收，不在编码任务内

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["1.3", "1.4"] },
    { "id": 3, "tasks": ["1.5"] },
    { "id": 4, "tasks": ["1.6"] },
    { "id": 5, "tasks": ["1.7"] },
    { "id": 6, "tasks": ["2"] },
    { "id": 7, "tasks": ["3.1", "3.2"] },
    { "id": 8, "tasks": ["3.3"] },
    { "id": 9, "tasks": ["3.4", "3.5"] },
    { "id": 10, "tasks": ["3.6"] },
    { "id": 11, "tasks": ["3.7", "3.9"] },
    { "id": 12, "tasks": ["3.8"] },
    { "id": 13, "tasks": ["4.1"] },
    { "id": 14, "tasks": ["4.2"] },
    { "id": 15, "tasks": ["4.3"] },
    { "id": 16, "tasks": ["4.4", "4.5", "4.6", "4.7"] },
    { "id": 17, "tasks": ["4.8"] },
    { "id": 18, "tasks": ["4.9", "4.10"] },
    { "id": 19, "tasks": ["4.11", "4.12"] },
    { "id": 20, "tasks": ["5.1"] },
    { "id": 21, "tasks": ["5.2"] },
    { "id": 22, "tasks": ["5.3"] },
    { "id": 23, "tasks": ["5.4"] },
    { "id": 24, "tasks": ["5.5"] },
    { "id": 25, "tasks": ["5.6"] },
    { "id": 26, "tasks": ["6"] },
    { "id": 27, "tasks": ["7.1", "7.4"] },
    { "id": 28, "tasks": ["7.2"] },
    { "id": 29, "tasks": ["7.3"] },
    { "id": 30, "tasks": ["7.5"] },
    { "id": 31, "tasks": ["7.6"] },
    { "id": 32, "tasks": ["7.7"] },
    { "id": 33, "tasks": ["8.1"] },
    { "id": 34, "tasks": ["8.2"] },
    { "id": 35, "tasks": ["8.3"] },
    { "id": 36, "tasks": ["8.4"] },
    { "id": 37, "tasks": ["8.5"] },
    { "id": 38, "tasks": ["8.6"] },
    { "id": 39, "tasks": ["8.7"] },
    { "id": 40, "tasks": ["8.8"] },
    { "id": 41, "tasks": ["9.1"] },
    { "id": 42, "tasks": ["9.2"] },
    { "id": 43, "tasks": ["9.3"] },
    { "id": 44, "tasks": ["9.4"] },
    { "id": 45, "tasks": ["9.5"] },
    { "id": 46, "tasks": ["9.6"] },
    { "id": 47, "tasks": ["9.7"] },
    { "id": 48, "tasks": ["9.8"] },
    { "id": 49, "tasks": ["9.9"] },
    { "id": 50, "tasks": ["9.10"] },
    { "id": 51, "tasks": ["10"] },
    { "id": 52, "tasks": ["11.1"] },
    { "id": 53, "tasks": ["11.2"] },
    { "id": 54, "tasks": ["11.3"] },
    { "id": 55, "tasks": ["11.4"] },
    { "id": 56, "tasks": ["11.5"] },
    { "id": 57, "tasks": ["12.1"] },
    { "id": 58, "tasks": ["12.2"] },
    { "id": 59, "tasks": ["12.3"] },
    { "id": 60, "tasks": ["13.1"] },
    { "id": 61, "tasks": ["13.2"] },
    { "id": 62, "tasks": ["13.3"] },
    { "id": 63, "tasks": ["13.4"] },
    { "id": 64, "tasks": ["13.5"] },
    { "id": 65, "tasks": ["13.6"] },
    { "id": 66, "tasks": ["13.7"] },
    { "id": 67, "tasks": ["13.8"] },
    { "id": 68, "tasks": ["14.1", "14.4", "14.5"] },
    { "id": 69, "tasks": ["14.2"] },
    { "id": 70, "tasks": ["14.3"] },
    { "id": 71, "tasks": ["15"] }
  ]
}
```
