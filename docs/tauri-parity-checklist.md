# Tauri 2 三端前端功能对照验收表（AICL-39）

对照基线：[v0.4.0 SwiftUI macOS 版](https://github.com/qiyuanjuzheng/ai-cleaner/tree/v0.4.0/Sources/AICleanerApp)与 ADR 0001（`docs/adr/0001-cross-platform-architecture.md`）。

## 1. 功能对齐清单

| 分类 | 功能项 | 对齐状态 | 实现位置 | 验证覆盖 |
| --- | --- | :---: | --- | --- |
| 首页与扫描页 | 空闲启动 Hero（开始扫描、累计已清理快捷入口、安全只读声明） | ✅ | `apps/desktop/src/components/ScanReadyHero.tsx` | Vitest (`App.test.tsx`) + 三端 Playwright E2E |
| 首页与扫描页 | 扫描进度页（轨道扫描动画、3 阶段胶囊进度条、实时文件数/体积、客户端发现跑马灯、取消扫描） | ✅ | `apps/desktop/src/components/OrbitalScannerHero.tsx` | Vitest (`App.test.tsx`) + `scan.progress` 契约夹具 |
| 总览与侧栏 | 空间总览仪表头（多段空间环 `StorageRingGauge`、3.5pt 极细比例条、返回扫描、勾选建议清理项、三档交互指标条） | ✅ | `apps/desktop/src/views/ItemListView.tsx`, `StorageRingGauge.tsx` | Vitest + 三端 Playwright E2E |
| 总览与侧栏 | 客户端侧栏（空间总览、清理记录、已排除、AI 客户端 + 深浅色品牌图标、系统临时目录、自定义目录及移除按钮） | ✅ | `apps/desktop/src/components/Sidebar.tsx`, `ClientLogo.tsx` | Vitest + 三端 Playwright E2E |
| 虚拟滚动列表 | 5,000+ 条目流畅虚拟滚动（`@tanstack/react-virtual` + 200 条分页懒加载与邻页预取，DOM 常驻 < 80 行） | ✅ | `apps/desktop/src/components/VirtualizedItemList.tsx`, `src/lib/virtualRows.ts` | Vitest (`virtualRows.test.ts` 5,500 条) + 三端 E2E（实扫 5,200+ 真实文件） |
| 筛选与检索 | 分类胶囊筛选、建议级别筛选、修改时间筛选（全部/7/30/90 天前）、排序（体积/时间/名称）、防抖搜索、重置筛选 | ✅ | `apps/desktop/src/views/ItemListView.tsx` | Vitest + 三端 Playwright E2E |
| 列表分组与标题 | 按 `recommended` / `reviewSuggested` / `notRecommended` 分组、分组全选、受保护项硬锁标识、完整会话标题与元数据查看（`items.get`） | ✅ | `VirtualizedItemList.tsx`, `FullTitleModal.tsx` | Vitest + 三端 Playwright E2E |
| 项目会话与保护 | 客户端项目会话分栏视图、跨客户端/单客户端切换、90 天前筛选、会话展开及关联文件、项目保护锁定/解除（`projects.setProtection`） | ✅ | `apps/desktop/src/views/ProjectSessionsView.tsx` | Vitest (`App.test.tsx`) + 三端 Playwright E2E |
| 移入回收站安全流 | 悬浮勾选操作岛、高风险项单选二次确认（`selection.confirmRisk`）、`trash.preview` 确认清单（绑定 `confirmationToken`）、高风险必勾确认、`-32006` 过期刷新提示、清理完成微光粒子庆祝胶囊与失败详情 | ✅ | `BottomActionBar.tsx`, `TrashConfirmationModal.tsx`, `RiskConfirmDialog.tsx` | Vitest + 三端真实回收站 E2E |
| 清理记录与图表 | 累计 / 单日（>180 天自动按周汇总）趋势图（悬停准星与浮窗）、3 列 KPI、客户端清理排行、最近记录分页（5 条/页）、单条删除与清空确认 | ✅ | `apps/desktop/src/views/CleanupHistoryView.tsx`, `src/lib/historyAnalytics.ts` | Vitest (`historyAnalytics.test.ts` 含 >180 天周聚合) + 三端 E2E |
| 排除项管理 | 右键/操作菜单排除条目、已排除页搜索、缺失路径标识（`statuses`）、单条恢复与全部恢复、文件管理器定位与复制路径 | ✅ | `apps/desktop/src/views/ExcludedItemsView.tsx` | 三端 Playwright E2E |
| 自定义目录 | 添加自定义目录弹窗、原生文件夹选择器（`plugin-dialog`）、Core `customDirs.validate` 实时安全校验、添加并扫描、侧栏移除 | ✅ | `apps/desktop/src/components/AddCustomDirectoryModal.tsx` | Vitest + 三端 Playwright E2E |
| 磁盘容量底栏 | 展示启动/系统磁盘总容量、已用/剩余比例条、上次扫描时间、60s 可见心跳刷新 | ✅ | `apps/desktop/src/components/DiskUsageFooter.tsx` | Vitest + Rust 集成测试 + 三端 E2E |
| 菜单、快捷键与外观 | 原生应用菜单（macOS App 菜单 + 扫描与清理/编辑/窗口）、三端快捷键（macOS `⌘R` / Win·Linux `Ctrl+R` 等）、浅色/深色/跟随系统（`settings.get`/`set` 持久化）、`prefers-reduced-motion` | ✅ | `apps/desktop/src-tauri/src/menu.rs`, `src/lib/shortcuts.ts`, `src/styles/app.css` | Vitest (`shortcuts.test.ts`) + Rust 编译验证 + 三端 E2E |
| macOS 原生质感 | 原生菜单栏 + 窗口透明叠加标题栏 + `Effect::Sidebar` vibrancy 半透明侧栏 | ✅ | `apps/desktop/src-tauri/tauri.conf.json`, `src-tauri/src/lib.rs`, `src/styles/app.css` | macOS Cargo 编译与 Tauri 构建验证 |
| 架构与安全约束 | Rust 宿主严格方法白名单（与 `rpc-v1.schema.json` 31 方法完全一致）、`reveal` 仅接受 Core `items.resolvePath` 返回路径、Swift & TS 双向校验 `protocol/fixtures/rpc-v1-samples.json` | ✅ | `apps/desktop/src-tauri/src/sidecar.rs`, `src-tauri/src/lib.rs`, `protocol/fixtures/rpc-v1-samples.json` | Rust `cargo test` + Swift `SidecarFlowTests` + Vitest `protocol.test.ts` |
