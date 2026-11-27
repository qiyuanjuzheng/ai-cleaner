use std::time::Duration;

use tauri::{Manager, Window};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_updater::UpdaterExt;

#[tauri::command]
pub async fn check_for_updates(window: Window) -> Result<(), String> {
    let app = window.app_handle();
    let configured = app
        .config()
        .plugins
        .0
        .get("updater")
        .and_then(|plugin| plugin.get("endpoints"))
        .and_then(|endpoints| endpoints.as_array())
        .is_some_and(|endpoints| !endpoints.is_empty());
    if !configured {
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
