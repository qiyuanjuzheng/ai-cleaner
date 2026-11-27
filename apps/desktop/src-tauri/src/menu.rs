use serde_json::json;
use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{AppHandle, Emitter, Runtime};

pub const MENU_EVENT: &str = "menu://action";

pub fn build_app_menu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Menu<R>> {
    let scan_start = MenuItemBuilder::with_id("scan.start", "开始 / 重新扫描")
        .accelerator("CmdOrCtrl+R")
        .build(app)?;
    let scan_return = MenuItemBuilder::with_id("scan.return", "返回扫描").build(app)?;
    let custom_add = MenuItemBuilder::with_id("customDirs.openAdd", "添加自定义目录…")
        .accelerator("CmdOrCtrl+Shift+A")
        .build(app)?;
    let nav_history = MenuItemBuilder::with_id("nav.history", "查看清理记录")
        .accelerator("CmdOrCtrl+2")
        .build(app)?;
    let nav_excluded = MenuItemBuilder::with_id("nav.excluded", "查看已排除条目")
        .accelerator("CmdOrCtrl+3")
        .build(app)?;

    let select_recommended =
        MenuItemBuilder::with_id("selection.recommended", "勾选建议清理项").build(app)?;
    let select_all = MenuItemBuilder::with_id("selection.selectAll", "全选可批量勾选项")
        .accelerator("CmdOrCtrl+Alt+A")
        .build(app)?;
    let select_invert =
        MenuItemBuilder::with_id("selection.invert", "反选可批量勾选项").build(app)?;
    let select_clear = MenuItemBuilder::with_id("selection.clear", "清空全部选择").build(app)?;
    let toggle_appearance =
        MenuItemBuilder::with_id("appearance.cycle", "切换浅色 / 深色外观").build(app)?;

    let scan_menu = SubmenuBuilder::new(app, "扫描与清理")
        .item(&scan_start)
        .item(&scan_return)
        .item(&custom_add)
        .item(&nav_history)
        .item(&nav_excluded)
        .separator()
        .item(&select_recommended)
        .item(&select_all)
        .item(&select_invert)
        .item(&select_clear)
        .separator()
        .item(&toggle_appearance)
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "编辑")
        .item(&PredefinedMenuItem::undo(app, None)?)
        .item(&PredefinedMenuItem::redo(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .item(&PredefinedMenuItem::select_all(app, None)?)
        .build()?;

    let window_menu = SubmenuBuilder::new(app, "窗口")
        .item(&PredefinedMenuItem::minimize(app, None)?)
        .item(&PredefinedMenuItem::maximize(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::close_window(app, None)?)
        .build()?;

    let mut builder = MenuBuilder::new(app);

    #[cfg(target_os = "macos")]
    {
        let app_menu = SubmenuBuilder::new(app, "AI Cleaner")
            .item(&PredefinedMenuItem::about(app, Some("关于 AI Cleaner"), None)?)
            .separator()
            .item(&PredefinedMenuItem::services(app, None)?)
            .separator()
            .item(&PredefinedMenuItem::hide(app, None)?)
            .item(&PredefinedMenuItem::hide_others(app, None)?)
            .item(&PredefinedMenuItem::show_all(app, None)?)
            .separator()
            .item(&PredefinedMenuItem::quit(app, Some("退出 AI Cleaner"))?)
            .build()?;
        builder = builder.item(&app_menu);
    }

    builder
        .item(&scan_menu)
        .item(&edit_menu)
        .item(&window_menu)
        .build()
}

pub fn handle_menu_event<R: Runtime>(app: &AppHandle<R>, menu_id: &str) {
    let _ = app.emit(MENU_EVENT, json!({ "action": menu_id }));
}
