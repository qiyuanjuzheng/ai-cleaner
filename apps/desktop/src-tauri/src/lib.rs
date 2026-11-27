pub mod menu;
pub mod reveal;
pub mod sidecar;
mod updater;

use std::sync::Arc;

use serde_json::{json, Value};
use tauri::{Emitter, Manager, RunEvent};

use crate::sidecar::{
    host_platform_name, validate_existing_path_from_core, RpcErrorPayload, SidecarManager,
};

struct HostState {
    sidecar: Arc<SidecarManager>,
}

#[tauri::command]
async fn core_request(
    state: tauri::State<'_, HostState>,
    method: String,
    params: Option<Value>,
) -> Result<Value, RpcErrorPayload> {
    state
        .sidecar
        .request(&method, params.unwrap_or_else(|| json!({})))
        .await
}

#[tauri::command]
async fn reveal_scan_item(
    state: tauri::State<'_, HostState>,
    scan_id: String,
    item_id: String,
) -> Result<(), String> {
    let resolved = state
        .sidecar
        .request(
            "items.resolvePath",
            json!({ "scanId": scan_id, "itemId": item_id }),
        )
        .await
        .map_err(|e| e.message)?;
    let raw_path = resolved
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| "核心服务未返回有效路径".to_string())?;
    let safe_path = validate_existing_path_from_core(raw_path)?;
    reveal::reveal_in_file_manager(&safe_path)
}

#[tauri::command]
async fn reveal_excluded_item(
    state: tauri::State<'_, HostState>,
    record_id: String,
) -> Result<(), String> {
    let listed = state
        .sidecar
        .request("excluded.list", json!({}))
        .await
        .map_err(|e| e.message)?;
    let records = listed
        .get("records")
        .and_then(Value::as_array)
        .ok_or_else(|| "无法读取已排除列表".to_string())?;
    let target = records
        .iter()
        .find(|rec| {
            rec.get("id")
                .and_then(Value::as_str)
                .map(|id| id.eq_ignore_ascii_case(&record_id))
                .unwrap_or(false)
        })
        .and_then(|rec| rec.get("normalizedPath"))
        .and_then(Value::as_str)
        .ok_or_else(|| "未找到对应的已排除记录".to_string())?;
    let safe_path = validate_existing_path_from_core(target)?;
    reveal::reveal_in_file_manager(&safe_path)
}

#[tauri::command]
fn host_platform() -> &'static str {
    host_platform_name()
}

pub fn run() {
    let sidecar = Arc::new(SidecarManager::new(None));
    let sidecar_for_exit = Arc::clone(&sidecar);

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(HostState {
            sidecar: Arc::clone(&sidecar),
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            sidecar.set_notification_sink(Arc::new(move |payload| {
                let _ = handle.emit("core://notification", payload);
            }));

            let app_menu = menu::build_app_menu(app.handle())?;
            app.set_menu(app_menu)?;
            app.on_menu_event(|app_handle, event| {
                menu::handle_menu_event(app_handle, event.id().as_ref());
            });

            #[cfg(target_os = "macos")]
            if let Some(window) = app.get_webview_window("main") {
                use tauri::window::{Effect, EffectState, EffectsBuilder};
                let _ = window.set_effects(
                    EffectsBuilder::new()
                        .effect(Effect::Sidebar)
                        .state(EffectState::FollowsWindowActiveState)
                        .build(),
                );
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            core_request,
            reveal_scan_item,
            reveal_excluded_item,
            host_platform,
            updater::check_for_updates
        ])
        .build(tauri::generate_context!())
        .expect("error while building AI Cleaner Tauri application");

    app.run(move |_handle, event| {
        if let RunEvent::Exit = event {
            sidecar_for_exit.shutdown_blocking();
        }
    });
}
