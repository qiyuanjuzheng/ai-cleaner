use std::time::Duration;

use tauri::{Config, Manager, Window};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_updater::UpdaterExt;

fn parse_plugin_config(config: &Config) -> Option<tauri_plugin_updater::Config> {
    let raw = config.plugins.0.get("updater")?;
    let parsed: tauri_plugin_updater::Config = serde_json::from_value(raw.clone()).ok()?;
    if parsed.pubkey.trim().is_empty() {
        return None;
    }
    Some(parsed)
}

pub(crate) fn is_plugin_configured(config: &Config) -> bool {
    parse_plugin_config(config).is_some()
}

pub(crate) fn has_update_endpoints(config: &Config) -> bool {
    parse_plugin_config(config).is_some_and(|updater| !updater.endpoints.is_empty())
}

#[tauri::command]
pub async fn check_for_updates(window: Window) -> Result<(), String> {
    let app = window.app_handle();
    if !has_update_endpoints(app.config()) {
        show_status(&window, "当前构建未配置更新源。");
        return Ok(());
    }

    let builder = app.updater_builder();
    #[cfg(windows)]
    let builder = {
        let app = app.clone();
        builder.on_before_exit(move || {
            app.state::<crate::HostState>().sidecar.shutdown_blocking();
            app.cleanup_before_exit();
        })
    };
    let updater = builder
        .build()
        .map_err(|error| format!("无法启动更新检查：{error}"))?;
    let update = tokio::time::timeout(Duration::from_secs(30), updater.check())
        .await
        .map_err(|_| "检查更新超时，请稍后重试。".to_string())?
        .map_err(|error| format!("检查更新失败：{error}"))?;
    let Some(update) = update else {
        show_status(&window, "当前已是最新版本。");
        return Ok(());
    };

    #[cfg(target_os = "linux")]
    if app.env().appimage.is_none() {
        let prompt = format!(
            "发现新版本 {}。请前往 GitHub Releases 下载 DEB 或 RPM 安装包。",
            update.version
        );
        if confirm(&window, prompt, "打开下载页").await {
            std::process::Command::new("xdg-open")
                .arg("https://github.com/qiyuanjuzheng/ai-cleaner/releases/latest")
                .spawn()
                .map_err(|error| format!("无法打开下载页：{error}"))?;
        }
        return Ok(());
    }

    let prompt = format!(
        "发现新版本 {}。安装更新后将重新启动 AI Cleaner。",
        update.version
    );
    if !confirm(&window, prompt, "下载并安装").await {
        return Ok(());
    }
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|error| format!("安装更新失败：{error}"))?;
    #[cfg(not(windows))]
    app.request_restart();
    Ok(())
}

fn show_status(window: &Window, message: &str) {
    window
        .dialog()
        .message(message)
        .title("检查更新")
        .parent(window)
        .show(|_| {});
}

async fn confirm(window: &Window, message: String, action: &str) -> bool {
    let (send, receive) = tokio::sync::oneshot::channel();
    window
        .dialog()
        .message(message)
        .title("检查更新")
        .parent(window)
        .buttons(MessageDialogButtons::OkCancelCustom(
            action.into(),
            "取消".into(),
        ))
        .show(move |confirmed| {
            let _ = send.send(confirmed);
        });
    receive.await.unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};
    use tauri::Config;

    use super::{has_update_endpoints, is_plugin_configured};

    fn config_with_updater(updater: Option<Value>) -> Config {
        let mut config: Config =
            serde_json::from_str(include_str!("../tauri.conf.json")).expect("valid tauri.conf.json");
        config.plugins.0.clear();
        if let Some(value) = updater {
            config.plugins.0.insert("updater".to_string(), value);
        }
        config
    }

    #[test]
    fn default_tauri_conf_skips_updater_plugin_registration() {
        let config: Config =
            serde_json::from_str(include_str!("../tauri.conf.json")).expect("valid tauri.conf.json");
        assert!(!is_plugin_configured(&config));
        assert!(!has_update_endpoints(&config));
    }

    #[test]
    fn missing_or_invalid_updater_config_is_not_configured() {
        let cases = [
            None,
            Some(Value::Null),
            Some(json!({})),
            Some(json!({ "pubkey": "" })),
            Some(json!({ "pubkey": "   " })),
            Some(json!({
                "endpoints": ["https://github.com/qiyuanjuzheng/ai-cleaner/releases/latest/download/latest.json"]
            })),
            Some(json!({
                "pubkey": "test-updater-public-key",
                "endpoints": ["not a valid url"]
            })),
        ];

        for updater in cases {
            let config = config_with_updater(updater);
            assert!(!is_plugin_configured(&config));
            assert!(!has_update_endpoints(&config));
        }
    }

    #[test]
    fn pubkey_without_endpoints_enables_plugin_but_reports_no_endpoints() {
        let config = config_with_updater(Some(json!({
            "pubkey": "test-updater-public-key",
            "requireSignedVersion": true
        })));

        assert!(is_plugin_configured(&config));
        assert!(!has_update_endpoints(&config));
    }

    #[test]
    fn pubkey_with_https_endpoints_enables_plugin_and_update_checks() {
        let config = config_with_updater(Some(json!({
            "pubkey": "test-updater-public-key",
            "requireSignedVersion": true,
            "endpoints": [
                "https://github.com/qiyuanjuzheng/ai-cleaner/releases/latest/download/latest.json"
            ]
        })));

        assert!(is_plugin_configured(&config));
        assert!(has_update_endpoints(&config));
    }
}
