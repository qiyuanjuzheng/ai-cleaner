# Requirements Document

## Introduction

本特性面向 AI Cleaner 的 Tauri 桌面版（`apps/desktop`，React 19 + Vite + TypeScript，Rust 宿主位于 `src-tauri`，Swift 边车 `aicleaner-core` 位于 `Sources/AICleanerSidecar`）。旧版 SwiftUI 应用（`Sources/AICleanerApp`）不在范围内，不做任何修改。

目前的主题实现只有 `:root[data-theme='light'|'dark']` 两组 CSS 变量，外观状态为 `light | dark | system`，通过 `settings.get` / `settings.set { appearanceMode }` 持久化到 `settings.json`。现状存在以下问题：

- 约 50 处硬编码的 hex/rgba 颜色，以及 `lib/theme.ts` 中与明暗无关的推荐等级色、分类色、客户端强调色，颜色无法随主题变化。
- 实测对比度不达标：浅色 `--text-tertiary`（#8492a6，背景 #f3f5fa）为 2.90:1；绿色 #29d18a 与琥珀色 #faa838 在白底上作为文字约 2:1；主按钮白字叠加 #1fdb94 渐变为 1.81:1；深色三级文字在卡片上为 3.62:1。
- 切换主题时颜色瞬间跳变，没有任何过渡；全应用缺少统一的动效规范；没有任何 `:focus-visible` 样式；`prefers-reduced-motion` 只处理了部分动画。
- 在 1200×780 与最小窗口 1020×660 下实测发现若干布局问题（见需求 11）。

本特性包含四个目标：

1. 建立真正的主题系统（分层令牌 + 主题注册表），并优化现有两个默认主题“浅色磨砂”和“深色极光”。
2. 新增万圣节主题 “Kiroween”（仅深色），可在运行时切换。
3. 为主题切换设计流畅、醒目的过渡动画，并重新设计全应用的交互动效体系。
4. 审视并优化现有布局。

本文档只定义需求，不包含设计与实现方案。

## Glossary

- **Desktop_App**: AI Cleaner 的 Tauri 桌面应用整体，包含前端界面、Rust 宿主与 Swift 边车。
- **Frontend**: Desktop_App 中运行在 WebView 内的 React 前端。
- **Sidecar**: Swift 边车进程 `aicleaner-core`，负责 RPC 与 `settings.json` 的读写。
- **Native_Menu**: 由 Rust 宿主构建的原生应用菜单。
- **Theme_System**: 管理主题定义、令牌、切换、持久化与过渡的整体能力。
- **Theme**: 一个完整的视觉主题，由 Theme_Registry 中的一条记录描述。
- **Theme_Registry**: 所有 Theme 的注册表。每条记录包含 id、显示名称、色彩方案（浅色/深色）、调色板（含图表色与分类色）、客户端 Logo 变体、装饰层与专属切换过渡。
- **Light_Theme**: 显示名称为“浅色磨砂”的主题（色彩方案为浅色）。
- **Dark_Theme**: 显示名称为“深色极光”的主题（色彩方案为深色）。
- **Kiroween_Theme**: 显示名称为 “Kiroween” 的万圣节主题，仅有深色方案，品牌紫为 #9046ff。
- **Appearance_Mode**: 用户选择的外观模式，取值为 `light`、`dark`、`system`。
- **Theme_Id**: 标识一个 Theme 的字符串，作为可选字段与 Appearance_Mode 一同持久化。
- **Effective_Scheme**: 当前实际生效的色彩方案，取值为 `light` 或 `dark`。
- **Base_Palette**: 令牌第一层，原始色板。
- **Semantic_Token**: 令牌第二层，语义变量（例如文字、表面、边框、推荐等级、聚焦环）。
- **Component_Usage**: 令牌第三层，组件对 Semantic_Token 的引用。
- **Theme_Panel**: 取代原循环按钮的主题选择面板，以迷你窗口预览卡片展示可选主题。
- **Preview_Card**: Theme_Panel 中的迷你窗口预览卡片。
- **Theme_Transition**: 切换主题时播放的过渡动画。
- **View_Transitions_API**: 浏览器提供的 View Transitions API。
- **Fallback_Transition**: View_Transitions_API 不可用时使用的 220–420 ms 交叉淡入淡出。
- **Seasonal_Invitation**: 每个季节一次的 Kiroween 试用邀请，以模态对话框呈现。
- **Return_To_Scan_Control**: 带有 `data-testid="return-to-idle-btn"` 的“返回扫描”控件，用于清除当前扫描结果并回到扫描就绪状态。
- **Halloween_Season**: 本地时间每年 10 月 25 日至 12 月 15 日（含首尾两日）。
- **Decoration_Layer**: 主题的装饰层，例如幽灵、蛛网、薄雾、蝙蝠。
- **Aurora_Backdrop**: 详情区背景的极光光斑层。
- **Motion_System**: 全应用统一的动效规范，包含时长与缓动令牌、进入/退出模式、共享模式与降级规则。
- **Reduced_Motion**: 操作系统层面的 `prefers-reduced-motion: reduce` 偏好。
- **Virtualized_List**: 以虚拟滚动渲染扫描结果条目的列表，实际数据可超过 5,200 行。
- **Control_Bar**: 列表上方的控制栏，包含分类分段筛选、“项目会话”按钮、搜索框与选项按钮。
- **Disk_Footer**: 侧边栏底部的磁盘用量区域。
- **Item_Row**: 列表中的单个条目行。
- **Bottom_Dock**: 悬浮在详情区底部的操作条。
- **Dashboard_Card**: 详情区顶部的概览卡片，含环形仪表、三档建议分段与细条。
- **Minimum_Window**: 最小窗口尺寸，宽 1020 px、高 660 px。
- **Contrast_Ratio**: WCAG 定义的前景色与背景色对比度。
- **Settings_File**: 由 Sidecar 维护的 `settings.json`。

## Requirements

### Requirement 1: 主题令牌分层架构

**User Story:** 作为开发者，我希望颜色统一来自分层令牌，以便新增或调整主题时无需逐个修改组件。

#### Acceptance Criteria

1. THE Theme_System SHALL 将颜色令牌分为 Base_Palette、Semantic_Token、Component_Usage 三层，且 Component_Usage 仅引用 Semantic_Token。
2. THE Theme_System SHALL 为每个 Theme 提供同一套 Semantic_Token 名称，使组件无需判断当前主题即可渲染。
3. WHEN 一个 Theme 被激活, THE Theme_System SHALL 在同一次同步操作中于文档根元素上同时标记该 Theme 的 Theme_Id 与 Effective_Scheme，使任何时刻都不存在仅其中一个标记存在或已更新的可观察中间状态（仅设置其中一个标记属于违反本条）。
4. THE Theme_System SHALL 为文字、表面、边框、推荐等级（建议清理、建议复核、不建议清理）、扫描分类、客户端强调色、图表系列、聚焦环、滚动条与文本选区提供 Semantic_Token。
5. THE Theme_System SHALL 将每种强调色分为“填充色”与“文字色”两个 Semantic_Token。
6. THE Theme_System SHALL 为深色主题提供至少三级表面层次的 Semantic_Token。
7. WHEN Frontend 的 JavaScript 或 SVG 代码需要颜色（环形仪表、历史图表、分类色、推荐等级色、客户端强调色）, THE Frontend SHALL 从当前激活 Theme 的令牌取值。
8. THE Frontend SHALL 不在组件与视图中保留与主题无关的硬编码 hex/rgba 颜色，但装饰性的纯黑/纯白遮罩与阴影透明度除外。
9. THE Theme_Registry SHALL 为每个 Theme 记录 Theme_Id、显示名称、色彩方案、调色板、客户端 Logo 变体、Decoration_Layer 与专属 Theme_Transition。
10. WHEN 新增一个 Theme 的注册记录, THE Theme_System SHALL 使该 Theme 出现在 Theme_Panel 中，无需修改 Theme_Panel 的组件代码。

### Requirement 2: 默认主题优化与可访问性

**User Story:** 作为用户，我希望浅色与深色主题清晰易读，以便长时间使用也不吃力。

#### Acceptance Criteria

1. THE Light_Theme SHALL 保持显示名称“浅色磨砂”。
2. THE Dark_Theme SHALL 保持显示名称“深色极光”。
3. THE Theme_System SHALL 使 Light_Theme 与 Dark_Theme 中所有正常字号文字与其所在背景的 Contrast_Ratio 不低于 4.5:1。
4. THE Theme_System SHALL 使 Light_Theme 与 Dark_Theme 中大字号文字（不小于 18.66 px 粗体或 24 px）、图标与控件边界的 Contrast_Ratio 不低于 3:1。
5. THE Theme_System SHALL 使主按钮的文字与按钮填充色的 Contrast_Ratio 不低于 4.5:1。
6. THE Theme_System SHALL 在白底及浅色卡片上使用“文字色”变体显示推荐等级与强调色文字，使其 Contrast_Ratio 不低于 4.5:1。
7. THE Frontend SHALL 为所有可聚焦控件提供 `:focus-visible` 样式，聚焦环与相邻背景的 Contrast_Ratio 不低于 3:1。
8. WHEN 用户使用鼠标点击一个控件, THE Frontend SHALL 不显示该控件的键盘聚焦环。
9. THE Aurora_Backdrop SHALL 由两到三个光斑组成，光斑缓慢漂移，且仅通过 `transform` 与 `opacity` 实现动画。
10. THE Aurora_Backdrop SHALL 根据当前激活的强调色调整光斑色调。
11. WHEN 一个 Theme 切换完成, THE Theme_System SHALL 使文本选区颜色与滚动条颜色符合该 Theme 的令牌。
12. THE Theme_System SHALL 将 Light_Theme 与 Dark_Theme 的调色板作为一对共同重新设计的调色板进行推导，并针对两个主题中的每一组前景/背景令牌组合（而不仅是当前未达标的组合）重新验证其满足第 2.3 至 2.6 条规定的阈值。

### Requirement 3: 主题选择界面与原生菜单

**User Story:** 作为用户，我希望直观地预览并选择主题，以便一眼知道选择后的效果。

#### Acceptance Criteria

1. THE Frontend SHALL 以 Theme_Panel 取代原“浅色 → 跟随系统 → 深色”的循环按钮。
2. THE Theme_Panel SHALL 提供四个选项：“浅色磨砂”、“深色极光”、“跟随系统”与 “Kiroween”，每个选项以 Preview_Card 展示。
3. THE Preview_Card SHALL 以迷你窗口形式呈现对应 Theme 的主要配色（侧边栏、卡片、强调色）。
4. THE Preview_Card for “跟随系统” SHALL 以对角分割的方式同时呈现浅色与深色两种预览。
5. THE Theme_Panel SHALL 标记当前选中的选项，并为该标记提供不依赖颜色的视觉提示（例如对勾）。
6. WHEN 用户在 Theme_Panel 中选择一个选项, THE Frontend SHALL 应用该选项、播放对应的 Theme_Transition 并持久化选择。
7. WHEN 用户通过键盘操作 Theme_Panel, THE Theme_Panel SHALL 支持方向键移动选择、Enter 或空格确认、Esc 关闭。
8. THE Theme_Panel SHALL 为每个选项提供可被屏幕阅读器读取的名称与选中状态。
9. THE Native_Menu SHALL 以单选项列表取代“切换浅色 / 深色外观”的循环菜单项，选项与 Theme_Panel 一致。
10. WHEN 用户在 Native_Menu 中选择一个主题选项, THE Desktop_App SHALL 与在 Theme_Panel 中选择产生相同的应用结果。
11. WHEN 主题选择发生变化, THE Native_Menu SHALL 将单选标记同步到当前选中项。
12. THE Toolbar SHALL 保留带有 `data-testid="toolbar-appearance"` 的入口，用于打开 Theme_Panel。
13. IF 持久化主题选择失败（例如 Settings_File 不可写或 Sidecar 写入返回错误）, THEN THE Frontend SHALL 仍立即应用所选主题并播放对应的 Theme_Transition，且在下一次启动时恢复先前已持久化的主题。

### Requirement 4: 外观模式、Kiroween 与系统外观的关系

**User Story:** 作为用户，我希望 Kiroween 与浅色/深色/跟随系统的选择互不混淆，以便退出 Kiroween 后回到原来的外观。

#### Acceptance Criteria

1. THE Theme_System SHALL 将 Kiroween_Theme 视为独立于 Appearance_Mode 的主题选项。
2. WHILE Kiroween_Theme 处于激活状态, THE Theme_System SHALL 使 Effective_Scheme 为 `dark`。
3. WHILE Kiroween_Theme 处于激活状态, THE Theme_Panel SHALL 不将“浅色磨砂”、“深色极光”、“跟随系统”中的任何一项标记为选中。
4. WHEN 用户从 Kiroween_Theme 切换到“浅色磨砂”、“深色极光”或“跟随系统”, THE Theme_System SHALL 应用用户所选项。
5. WHEN 用户在 Kiroween_Theme 激活期间退出并重新启动 Desktop_App 后又离开 Kiroween_Theme, THE Theme_System SHALL 恢复用户进入 Kiroween_Theme 之前的 Appearance_Mode。
6. WHILE Appearance_Mode 为 `system` 且 Kiroween_Theme 未激活, THE Theme_System SHALL 跟随操作系统外观的变化更新 Effective_Scheme。
7. WHILE Kiroween_Theme 处于激活状态, THE Theme_System SHALL 不因操作系统外观变化而改变显示。
8. WHEN 操作系统外观发生变化且 Appearance_Mode 为 `system`, THE Theme_System SHALL 在 500 ms 内更新界面，且不触发 Kiroween 专属的 Theme_Transition。

### Requirement 5: 持久化、迁移与默认值

**User Story:** 作为用户，我希望主题选择在重启后保留，已有用户的设置不被破坏，新用户默认跟随系统。

#### Acceptance Criteria

1. THE Sidecar SHALL 在 Settings_File 中保存可选的 Theme_Id 与 Appearance_Mode。
2. THE Sidecar SHALL 在 Settings_File 中保存记录“已在某一年显示过 Seasonal_Invitation”的信息。
3. WHEN Settings_File 不含 Theme_Id 字段, THE Sidecar SHALL 按原有 Appearance_Mode 读取设置，且不报告存储损坏。
4. IF Settings_File 中的 Theme_Id 不属于 Theme_Registry, THEN THE Frontend SHALL 回退到默认主题，且 THE Sidecar SHALL 不报告存储损坏。
5. IF 一个已有 Settings_File 因旧版本写入而缺少 Seasonal_Invitation 记录, THEN THE Sidecar SHALL 视为尚未显示过邀请，且不报告存储损坏。
6. WHERE 不存在 Settings_File 且无法读取旧版应用的外观偏好, THE Sidecar SHALL 将默认 Appearance_Mode 设为 `system`。
7. THE Frontend SHALL 将尚未从 Sidecar 读取到设置时的初始 Appearance_Mode 设为 `system`。
8. WHERE 已存在 Settings_File 或可读取旧版应用的外观偏好, THE Sidecar SHALL 保留其中的 Appearance_Mode，不改为 `system`。
9. WHEN `settings.set` 收到合法的 Theme_Id 与 Appearance_Mode, THE Sidecar SHALL 写入 Settings_File 并在随后的 `settings.get` 中返回相同的值（往返一致）。
10. WHEN 旧版 Frontend 仅发送 `{ appearanceMode }` 调用 `settings.set`, THE Sidecar SHALL 接受该调用并保留已存储的 Theme_Id 与 Seasonal_Invitation 记录。
11. THE Sidecar SHALL 以原子写入方式更新 Settings_File。
12. THE Desktop_App SHALL 保持 `protocol/rpc-v1.schema.json` 中现有 settings 方法名称不变，新增字段对旧客户端为可选。
13. FOR ALL 合法的设置值, 读取后写回再读取 SHALL 得到等价的设置对象（往返属性）。
14. WHEN Desktop_App 启动且 Settings_File 已有主题设置, THE Frontend SHALL 延迟首次绘制，直到通过 RPC 等待并获得 Sidecar 返回的已保存主题设置，再在首次绘制前应用该主题，避免出现错误主题的闪烁，且不依赖本地缓存或预先同步的副本。
15. IF 在 Frontend 延迟首次绘制期间，Sidecar 在 1 秒内未返回已保存的主题设置，或该读取失败, THEN THE Frontend SHALL 应用默认主题与 Appearance_Mode `system` 并继续首次绘制，不再等待。
16. WHEN 已保存的主题设置在第 5.15 条的回退已应用之后才从 Sidecar 到达, THE Frontend SHALL 通过与用户主动选择主题相同的主题切换路径应用这些设置（含该次切换对应的 Theme_Transition，并遵循 Reduced_Motion 与 Fallback_Transition 的规定），使已保存的 Theme_Id 与 Appearance_Mode 在本次运行中生效，且不重复写回 Settings_File。

### Requirement 6: Kiroween 主题

**User Story:** 作为用户，我希望有一个带 Kiro 风格的万圣节主题，以便在节日期间获得有趣但不影响使用的界面。

#### Acceptance Criteria

1. THE Kiroween_Theme SHALL 只提供深色方案，不提供浅色变体。
2. THE Kiroween_Theme SHALL 以 #9046ff 作为品牌紫，以近黑的茄紫色作为背景，以南瓜橙与幽灵绿作为强调色。
3. THE Kiroween_Theme SHALL 将推荐等级映射为：建议清理为幽灵绿，建议复核为南瓜橙，不建议清理为血红色。
4. THE Kiroween_Theme SHALL 使所有正常字号文字与其背景的 Contrast_Ratio 不低于 4.5:1。
5. THE Kiroween_Theme SHALL 为扫描分类、客户端强调色与历史图表提供与该主题协调的配色，且图表系列之间可区分。
6. WHILE Kiroween_Theme 处于激活状态, THE Frontend SHALL 使用适配深色背景的客户端 Logo 变体。
7. WHILE Kiroween_Theme 处于激活状态, THE Decoration_Layer SHALL 在侧边栏品牌标识旁显示一个小型 Kiro 幽灵并使其轻微漂浮。
8. WHILE Kiroween_Theme 处于激活状态, THE Decoration_Layer SHALL 在窗口角落显示蛛网，并在窗口底部显示一层缓慢移动的薄雾。
9. WHILE Kiroween_Theme 处于激活状态, THE Frontend SHALL 将扫描就绪的圆形按钮显示为南瓜灯或坩埚造型。
10. WHILE Kiroween_Theme 处于激活状态且扫描进行中, THE Frontend SHALL 将扫描环绕的轨道环显示为环绕的蝙蝠。
11. WHILE Kiroween_Theme 处于激活状态, WHEN 清理成功, THE Frontend SHALL 以向上飘起的小幽灵取代默认的粒子迸发效果。
12. THE Decoration_Layer SHALL 不遮挡 Item_Row、按钮与文字，且不拦截鼠标事件。
13. THE Decoration_Layer SHALL 不降低列表中任何文字的 Contrast_Ratio 到 4.5:1 以下。
14. WHEN Desktop_App 的窗口不可见, THE Decoration_Layer SHALL 暂停所有装饰动画。
15. WHILE Reduced_Motion 生效, THE Decoration_Layer SHALL 以静态方式显示装饰元素。

### Requirement 7: 季节性邀请

**User Story:** 作为用户，我希望在万圣节期间被邀请体验 Kiroween，以便发现这个彩蛋但不被反复打扰。

#### Acceptance Criteria

1. WHEN Desktop_App 在 Halloween_Season 内启动, THE Frontend SHALL 在本年度尚未显示过 Seasonal_Invitation 时显示一次邀请，说明可试用 Kiroween_Theme。
2. THE Frontend SHALL 使用本地时间判断 Halloween_Season，并将 10 月 25 日与 12 月 15 日均视为季节内。
3. WHILE Kiroween_Theme 处于激活状态, THE Frontend SHALL 不显示 Seasonal_Invitation。
4. WHEN Seasonal_Invitation 被显示, THE Frontend SHALL 立即通过 Sidecar 记录本年度已显示。
5. WHEN 用户在 Seasonal_Invitation 中选择试用, THE Frontend SHALL 应用 Kiroween_Theme 并播放进入 Kiroween 的 Theme_Transition。
6. WHEN 用户在 Seasonal_Invitation 中选择关闭, THE Frontend SHALL 保持当前主题不变。
7. WHEN Desktop_App 在 Halloween_Season 之外启动, THE Frontend SHALL 不显示 Seasonal_Invitation。
8. WHEN 日历年度发生变化后 Desktop_App 在新的 Halloween_Season 内启动, THE Frontend SHALL 再次显示一次 Seasonal_Invitation。
9. IF 记录“已显示”的写入失败, THEN THE Frontend SHALL 在本次运行内不再重复显示 Seasonal_Invitation。
10. WHILE 扫描或清理正在进行, THE Frontend SHALL 推迟显示 Seasonal_Invitation，直到该操作结束。
11. THE Seasonal_Invitation SHALL 可通过键盘操作并可被屏幕阅读器读取。
12. THE Kiroween_Theme SHALL 在 Halloween_Season 之外仍可通过 Theme_Panel 与 Native_Menu 选择。
13. WHEN 一个因第 7.10 条而被推迟的 Seasonal_Invitation 所对应的扫描或清理在 Halloween_Season 结束之后才结束, THE Frontend SHALL 仍然显示该 Seasonal_Invitation，其适用范围仅限于显示条件已在季节内满足的邀请（Desktop_App 在 Halloween_Season 内启动，且本年度尚未显示过邀请），并不改变第 7.7 条对季节外启动的规定。
14. THE Seasonal_Invitation SHALL 以带有“试用 Kiroween”与“关闭”两个操作的模态对话框呈现，使用与其他模态对话框相同的进入与退出动画模式（需求 9.5 与 9.6），在打开时将初始键盘焦点置于对话框内，在对话框打开期间将焦点保持在对话框内，将 Esc 视为“关闭”，并在对话框关闭时将焦点返回到此前获得焦点的元素。

### Requirement 8: 主题切换过渡编排

**User Story:** 作为用户，我希望切换主题时有流畅且醒目的动画，以便切换过程本身带来愉悦感。

#### Acceptance Criteria

1. WHEN View_Transitions_API 可用且 Reduced_Motion 未生效, THE Theme_System SHALL 使用基于 clip-path 或 mask 的 Theme_Transition，而不触发整体重新布局。
2. WHEN 用户在 Light_Theme 与 Dark_Theme 之间切换（含经由跟随系统导致的方案变化）, THE Theme_Transition SHALL 以用户点击位置为圆心展开圆形揭示，边缘带有发光，总时长为 600–700 ms。
3. WHEN 用户切换到 Kiroween_Theme, THE Theme_Transition SHALL 依次呈现：界面灯光闪烁熄灭约 120 ms，一个 Kiro 幽灵从触发按钮飞向屏幕中心，幽灵轮廓作为遮罩扩大并吞没屏幕，蝙蝠从屏幕边缘散开，总时长约 1.4 s。
4. WHEN 用户离开 Kiroween_Theme, THE Theme_Transition SHALL 依次呈现：幽灵缩小消失，界面自上而下如破晓般擦除并恢复，总时长不超过 1.0 s。
5. WHEN Theme_Transition 正在播放且用户再次选择主题, THE Theme_System SHALL 结束当前过渡并以最新选择为目标继续，不出现中间态残留。
6. IF View_Transitions_API 不可用, THEN THE Theme_System SHALL 使用时长 220–420 ms 的 Fallback_Transition。
7. WHILE Reduced_Motion 生效, THE Theme_System SHALL 立即切换主题，不播放 Theme_Transition 与 Fallback_Transition。
8. WHILE Theme_Transition 播放, THE Frontend SHALL 保持输入响应，且不阻塞 Sidecar RPC 的请求与应答。
9. WHILE Theme_Transition 播放且 Virtualized_List 已加载超过 5,200 行, THE Frontend SHALL 保持平均不低于 50 帧每秒。
10. WHEN Theme_Transition 完成, THE Frontend SHALL 移除过渡期间添加的所有临时节点与样式。
11. IF Theme_Transition 执行中发生错误, THEN THE Theme_System SHALL 直接应用目标主题，并保持 Desktop_App 可用。
12. THE Theme_System SHALL 在 macOS（WKWebView）、Windows（WebView2）与 Linux（WebKitGTK）上均能完成主题切换。
13. IF 离开 Kiroween_Theme 的 Theme_Transition 未按第 8.4 条规定的先后顺序（先幽灵缩小消失，后界面自上而下擦除恢复）执行，或两个阶段出现重叠, THEN THE Theme_System SHALL 将其视为第 8.11 条所述的 Theme_Transition 执行错误并按该条处理，即使总时长仍在 1.0 s 以内。
14. IF WebView 不支持 View_Transitions_API（例如部分 WebKitGTK 版本）, THEN THE Theme_System SHALL 对每一次主题切换（包括切入与切出 Kiroween_Theme）使用 Fallback_Transition，此时不要求呈现第 8.3 条与第 8.4 条所述的完整编排，且 THE Theme_System SHALL 仍然正确应用 Kiroween_Theme 的调色板与 Decoration_Layer。

### Requirement 9: 全应用动效体系

**User Story:** 作为用户，我希望整个应用的动画统一、流畅、有目的，以便操作反馈清晰而不花哨。

#### Acceptance Criteria

1. THE Motion_System SHALL 定义时长令牌与缓动令牌，并由全应用的过渡与动画统一引用。
2. THE Motion_System SHALL 将悬停与按下反馈的时长限定在 80–160 ms 范围内。
3. THE Motion_System SHALL 将进入与退出动画的时长限定在 160–320 ms 范围内，Theme_Transition 与扫描等专属编排除外。
4. WHEN 用户在侧边栏切换视图（扫描结果、项目会话、清理记录、已排除条目）, THE Frontend SHALL 播放视图过渡，且过渡不改变列表滚动位置的恢复行为。
5. WHEN 模态对话框或弹出菜单打开, THE Frontend SHALL 播放包含遮罩淡入与面板缩放或位移的进入动画。
6. WHEN 模态对话框或弹出菜单关闭, THE Frontend SHALL 播放退出动画后再移除节点。
7. WHEN Item_Row 因筛选、搜索、排除或清理而进入或离开当前可见集合, THE Frontend SHALL 对可视区域内的行播放进入或退出动画。
8. WHILE Virtualized_List 滚动, THE Frontend SHALL 不对因滚动而挂载或卸载的行播放进入或退出动画。
9. WHEN Dashboard_Card 与 Bottom_Dock 中的体积与数量数值发生变化, THE Frontend SHALL 以数字过渡（计数）呈现，时长不超过 600 ms。
10. WHEN 扫描开始、扫描阶段推进或扫描完成, THE Frontend SHALL 通过动画表现阶段变化，包括阶段胶囊的状态切换与扫描动画到结果视图的过渡。
11. WHEN 清理成功, THE Frontend SHALL 播放成功反馈动画，并使 Bottom_Dock 与列表以动画方式反映条目的移除。
12. WHEN Bottom_Dock 出现或消失, THE Frontend SHALL 播放进入或退出动画。
13. THE Frontend SHALL 仅使用 `transform`、`opacity`、`clip-path` 或 `mask` 驱动动画，不以 `width`、`height`、`top`、`left` 等触发布局的属性驱动动画。
14. WHILE Virtualized_List 包含超过 5,200 行, THE Frontend SHALL 在滚动与动画并行时保持平均不低于 50 帧每秒。
15. WHILE Reduced_Motion 生效, THE Motion_System SHALL 将位移、缩放、旋转与持续循环类动画替换为不超过 100 ms 的淡入淡出或直接切换。
16. WHILE Desktop_App 的窗口不可见, THE Motion_System SHALL 暂停所有循环类动画。
17. THE Motion_System SHALL 对同类元素使用相同的动效模式，例如所有模态对话框使用同一进入与退出模式。
18. WHEN 用户在动画未结束时触发新的交互, THE Frontend SHALL 立即响应新的交互，不等待当前动画完成。
19. THE Desktop_App SHALL 不提供用于调节动效强度的应用内设置，动效为完整或精简仅由 Reduced_Motion 决定。

### Requirement 10: 主题面板预览动画

**User Story:** 作为用户，我希望在选择主题前获得生动的预览，以便更有把握地做出选择。

#### Acceptance Criteria

1. WHEN 用户悬停或聚焦一个 Preview_Card, THE Preview_Card SHALL 以不超过 200 ms 的动画突出该卡片。
2. WHEN Theme_Panel 打开, THE Theme_Panel SHALL 使用与需求 9 一致的进入动画。
3. WHEN 用户悬停或聚焦一个 Preview_Card, THE Preview_Card SHALL 播放对应 Theme 的迷你装饰动画（例如幽灵漂浮、极光漂移）。
4. WHILE 迷你装饰动画正在播放, THE Theme_Panel SHALL 在用户点击、按下 Enter 或空格时立即响应选择，不等待该动画结束。

### Requirement 11: 布局优化

**User Story:** 作为用户，我希望界面在各种窗口尺寸下都布局合理，以便无需猜测被遮挡或被截断的信息。

#### Acceptance Criteria

1. THE Disk_Footer SHALL 完整显示其全部行与磁盘用量进度条，且进度条高度大于 0 并可见。
2. WHEN 窗口尺寸为 Minimum_Window 或更大, THE Control_Bar SHALL 在单行内显示全部控件，且任何控件文字不被竖向折行。
3. WHEN 窗口宽度小于 Control_Bar 单行所需宽度, THE Control_Bar SHALL 通过缩减搜索框宽度、将次要控件收入溢出菜单或换行为整控件级别来适配，且控件内文字不竖向折行。
4. THE Item_Row SHALL 对路径使用中间省略，保留路径末段（文件或目录名）与安全说明的可见性。
5. WHEN 用户悬停或聚焦 Item_Row 的路径, THE Frontend SHALL 提供完整路径的查看方式。
6. THE Item_Row SHALL 在窗口宽度变化时保持主标题与安全标记可见。
7. THE Virtualized_List SHALL 使用不小于 Bottom_Dock 占用高度的底部内边距，使最后一行不被 Bottom_Dock 遮挡。
8. THE Dashboard_Card SHALL 删除与环形仪表和三档分段重复的细条，并压缩内边距。
9. THE Item_Row SHALL 仅在悬停或聚焦该行时显示行内操作图标（定位与更多）。
10. THE Item_Row SHALL 使仅在悬停或聚焦时显示的行内操作图标对键盘聚焦、触控与屏幕阅读器仍可访问。
11. WHEN 扫描尚未执行, THE Sidebar SHALL 在“AI 客户端”区块显示引导提示，说明扫描后将列出检测到的客户端。
12. WHEN 窗口尺寸为 Minimum_Window, THE Frontend SHALL 使 Virtualized_List 可见区域至少容纳 5 个 Item_Row（与需求 11.8 一并实现）。
13. WHILE 运行于 macOS 且使用覆盖式标题栏, THE Frontend SHALL 为窗口控制按钮预留空间，且不遮挡侧边栏品牌标识与顶部工具栏控件。
14. WHILE 运行于 Windows 或 Linux, THE Frontend SHALL 使顶部工具栏与侧边栏头部不为不存在的覆盖式标题栏预留多余空间。
15. THE Frontend SHALL 在 Minimum_Window 下不出现水平滚动条与被裁切的主要内容。
16. THE Frontend SHALL 以低于紧邻主操作按钮的视觉强调度呈现 Return_To_Scan_Control（使用低强调的次级样式，而非与主按钮权重相当的胶囊按钮），并保持其文字标签、键盘可聚焦性、可访问名称与现有行为不变。

### Requirement 12: 兼容性与回归

**User Story:** 作为维护者，我希望变更后现有功能与测试保持有效，以便放心发布。

#### Acceptance Criteria

1. THE Desktop_App SHALL 保持现有扫描、清理、排除、自定义目录与清理记录功能的行为不变。
2. THE Desktop_App SHALL 不修改 `Sources/AICleanerApp` 下的旧版 SwiftUI 应用。
3. THE Desktop_App SHALL 保持现有 RPC 方法名称与已有字段语义不变，仅新增可选字段。
4. WHEN 外观入口由循环按钮改为 Theme_Panel, THE Desktop_App SHALL 同步更新受影响的单元测试与端到端测试。
5. THE Sidecar SHALL 为 Theme_Id、Seasonal_Invitation 记录、默认 `system`、旧文件迁移与未知 Theme_Id 提供自动化测试。
6. THE Frontend SHALL 为季节判断（含 10 月 24 日、10 月 25 日、12 月 15 日、12 月 16 日四个边界日期）、主题回退与外观恢复提供自动化测试。
7. WHEN 全部自动化测试运行, THE Desktop_App SHALL 通过前端单元测试、端到端测试与 Sidecar 测试。
8. WHILE Reduced_Motion 生效, THE Desktop_App SHALL 通过端到端测试验证主题在不播放过渡的情况下立即切换。

### Requirement 13: 非功能要求

**User Story:** 作为用户，我希望主题与动效不拖慢应用，也不影响无障碍使用。

#### Acceptance Criteria

1. THE Frontend SHALL 使 Light_Theme、Dark_Theme 与 Kiroween_Theme 下所有正常字号文字满足 WCAG AA（Contrast_Ratio 不低于 4.5:1）。
2. WHEN 主题切换完成, THE Frontend SHALL 在 100 ms 内使所有令牌生效，且不产生未着色的中间帧。
3. WHILE 无扫描、清理或主题切换在进行, THE Decoration_Layer 与 Aurora_Backdrop SHALL 使应用的平均 CPU 占用增量不超过一个核心的 5%。
4. THE Frontend SHALL 使所有交互控件可通过键盘到达与操作。
5. THE Frontend SHALL 使主题名称、选中状态与季节邀请对屏幕阅读器可见。
6. IF 动画使用的 CSS 或 Web API 在当前 WebView 中不可用, THEN THE Frontend SHALL 降级为不使用该 API 的显示方式，且不抛出未处理异常。
7. THE Theme_System SHALL 不引入需要联网下载的字体、图片或脚本。
8. IF 实测得到的 Decoration_Layer 与 Aurora_Backdrop 的 CPU 占用增量超过一个核心的 5%（例如 6%）, THEN THE Frontend SHALL 仅记录该超出情况并继续渲染当前效果，不自动降级或关闭这些效果；第 13.3 条的 5% 为验收时测量的阈值，而非运行时强制执行的限制。


## 已确认的决定

1. “返回扫描”入口：仅降低视觉强调度，不增加确认、不移动位置（需求 11.16）。
2. 布局建议 e、f、g：全部采纳（需求 11.8、11.9、11.10、11.11、11.12）。
3. 主题面板预览动画：采纳，悬停或聚焦时播放迷你装饰动画；降级与窗口不可见时的暂停由需求 9.15 与 9.16 覆盖（需求 10.3、10.4）。
4. 动效强度：不提供应用内设置，仅由操作系统的 Reduced_Motion 决定（需求 9.19）。
5. Seasonal_Invitation 的呈现方式：模态对话框（术语表、需求 7.14）。
6. Linux WebKitGTK 不支持 View_Transitions_API：接受仅使用 Fallback_Transition（需求 8.14）。
7. 首次绘制等待 Sidecar 超时：超时或读取失败后回退到默认主题与 `system` 并继续绘制，超时值为 1 秒（需求 5.15）。
8. 首次绘制等待 Sidecar 的超时时长：确认为 1 秒（需求 5.15）。
9. 超时回退后才收到已保存的主题设置：通过与用户主动选择主题相同的主题切换路径应用（含常规 Theme_Transition，并遵循 Reduced_Motion 与回退规则），使用户已保存的主题生效，且不重复写回 Settings_File（需求 5.16）。
