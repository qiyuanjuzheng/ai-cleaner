use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::oneshot;

/// Strict method whitelist matching `protocol/rpc-v1.schema.json`.
/// Rust host refuses any method outside this set before writing to sidecar stdin.
pub const ALLOWED_METHODS: &[&str] = &[
    "core.handshake",
    "core.ping",
    "core.shutdown",
    "scan.start",
    "scan.cancel",
    "report.summary",
    "clients.list",
    "items.query",
    "items.get",
    "items.resolvePath",
    "selection.apply",
    "selection.confirmRisk",
    "trash.preview",
    "trash.execute",
    "history.list",
    "history.delete",
    "history.clear",
    "excluded.list",
    "excluded.add",
    "excluded.restore",
    "excluded.restoreAll",
    "customDirs.list",
    "customDirs.validate",
    "customDirs.add",
    "customDirs.remove",
    "projects.list",
    "projects.sessions",
    "projects.setProtection",
    "disk.capacity",
    "settings.get",
    "settings.set",
];

pub fn is_allowed_method(method: &str) -> bool {
    ALLOWED_METHODS.contains(&method)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcErrorPayload {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl std::fmt::Display for RpcErrorPayload {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RPC error {}: {}", self.code, self.message)
    }
}

pub type NotificationSink = Arc<dyn Fn(Value) + Send + Sync + 'static>;

struct RunningSidecar {
    child: Child,
    stdin: ChildStdin,
}

pub struct SidecarManager {
    binary_override: Option<PathBuf>,
    env_overrides: Vec<(String, String)>,
    process: Arc<Mutex<Option<RunningSidecar>>>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, RpcErrorPayload>>>>>,
    next_id: AtomicU64,
    notification_sink: Arc<Mutex<Option<NotificationSink>>>,
    last_handshake_params: Arc<Mutex<Option<Value>>>,
}

impl SidecarManager {
    pub fn new(binary_override: Option<PathBuf>) -> Self {
        Self {
            binary_override,
            env_overrides: Vec::new(),
            process: Arc::new(Mutex::new(None)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicU64::new(1),
            notification_sink: Arc::new(Mutex::new(None)),
            last_handshake_params: Arc::new(Mutex::new(None)),
        }
    }

    #[cfg(test)]
    pub fn with_env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env_overrides.push((key.into(), value.into()));
        self
    }

    pub fn set_notification_sink(&self, sink: NotificationSink) {
        if let Ok(mut guard) = self.notification_sink.lock() {
            *guard = Some(sink);
        }
    }

    pub fn resolve_sidecar_path(&self) -> Result<PathBuf, RpcErrorPayload> {
        if let Some(ref custom) = self.binary_override {
            if custom.exists() {
                return Ok(custom.clone());
            }
        }
        if let Ok(env_path) = std::env::var("AI_CLEANER_SIDECAR_PATH") {
            let candidate = PathBuf::from(env_path);
            if candidate.exists() {
                return Ok(candidate);
            }
        }

        let exe_name = if cfg!(windows) {
            "aicleaner-core.exe"
        } else {
            "aicleaner-core"
        };

        // Production bundle: sidecar sits next to the main Tauri executable.
        if let Ok(current_exe) = std::env::current_exe() {
            if let Some(dir) = current_exe.parent() {
                let sibling = dir.join(exe_name);
                if sibling.exists() {
                    return Ok(sibling);
                }
            }
        }

        // Development fallback: locate repo root `.build/{debug,release}/aicleaner-core`.
        let search_roots: Vec<PathBuf> = [
            std::env::current_dir().ok(),
            option_env!("CARGO_MANIFEST_DIR").map(PathBuf::from),
        ]
        .into_iter()
        .flatten()
        .collect();

        for root in search_roots {
            for ancestor in root.ancestors().take(5) {
                for config in ["debug", "release"] {
                    let candidate = ancestor.join(".build").join(config).join(exe_name);
                    if candidate.exists() {
                        return Ok(candidate);
                    }
                }
            }
        }

        Err(RpcErrorPayload {
            code: -32090,
            message: format!("无法定位核心服务进程 ({exe_name})，请先构建 aicleaner-core 或重新安装应用。"),
            data: Some(json!({ "name": "SIDECAR_NOT_FOUND" })),
        })
    }

    fn ensure_started(&self) -> Result<bool, RpcErrorPayload> {
        let mut guard = self.process.lock().map_err(|_| RpcErrorPayload {
            code: -32091,
            message: "sidecar lock poisoned".into(),
            data: None,
        })?;

        if let Some(ref mut running) = *guard {
            match running.child.try_wait() {
                Ok(None) => return Ok(false),
                _ => {
                    *guard = None;
                }
            }
        }

        let bin_path = self.resolve_sidecar_path()?;
        let mut command = Command::new(&bin_path);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        for (k, v) in &self.env_overrides {
            command.env(k, v);
        }

        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }

        let mut child = command.spawn().map_err(|err| RpcErrorPayload {
            code: -32092,
            message: format!("启动核心服务失败: {err}"),
            data: Some(json!({ "name": "SIDECAR_SPAWN_FAILED" })),
        })?;

        let stdin = child.stdin.take().ok_or_else(|| RpcErrorPayload {
            code: -32092,
            message: "核心服务 stdin 管道不可用".into(),
            data: None,
        })?;
        let stdout = child.stdout.take().ok_or_else(|| RpcErrorPayload {
            code: -32092,
            message: "核心服务 stdout 管道不可用".into(),
            data: None,
        })?;

        let pending_ref = Arc::clone(&self.pending);
        let process_ref = Arc::clone(&self.process);
        let sink_ref = Arc::clone(&self.notification_sink);

        std::thread::Builder::new()
            .name("aicleaner-sidecar-stdout".into())
            .spawn(move || {
                let reader = BufReader::new(stdout);
                for line in reader.lines() {
                    let Ok(raw) = line else { break };
                    let trimmed = raw.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    let Ok(msg) = serde_json::from_str::<Value>(trimmed) else {
                        continue;
                    };

                    if let Some(id_val) = msg.get("id").and_then(Value::as_u64) {
                        let sender = pending_ref
                            .lock()
                            .ok()
                            .and_then(|mut map| map.remove(&id_val));
                        if let Some(tx) = sender {
                            if let Some(err_val) = msg.get("error") {
                                let parsed = serde_json::from_value::<RpcErrorPayload>(err_val.clone())
                                    .unwrap_or_else(|_| RpcErrorPayload {
                                        code: -32603,
                                        message: err_val.to_string(),
                                        data: None,
                                    });
                                let _ = tx.send(Err(parsed));
                            } else {
                                let result = msg.get("result").cloned().unwrap_or(Value::Null);
                                let _ = tx.send(Ok(result));
                            }
                        }
                    } else if msg.get("method").and_then(Value::as_str).is_some() {
                        if let Ok(guard) = sink_ref.lock() {
                            if let Some(ref sink) = *guard {
                                sink(msg);
                            }
                        }
                    }
                }

                // Sidecar stdout closed: fail all in-flight callers cleanly.
                if let Ok(mut map) = pending_ref.lock() {
                    for (_, tx) in map.drain() {
                        let _ = tx.send(Err(RpcErrorPayload {
                            code: -32093,
                            message: "核心服务进程已退出，请重试或重新扫描。".into(),
                            data: Some(json!({ "name": "SIDECAR_EXITED" })),
                        }));
                    }
                }
                if let Ok(mut guard) = process_ref.lock() {
                    *guard = None;
                }
            })
            .map_err(|err| RpcErrorPayload {
                code: -32092,
                message: format!("启动读取线程失败: {err}"),
                data: None,
            })?;

        *guard = Some(RunningSidecar { child, stdin });
        Ok(true)
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcErrorPayload> {
        if !is_allowed_method(method) {
            return Err(RpcErrorPayload {
                code: -32601,
                message: format!("Method not allowed by host whitelist: {method}"),
                data: Some(json!({ "name": "METHOD_NOT_ALLOWED" })),
            });
        }

        let freshly_spawned = self.ensure_started()?;
        if method == "core.handshake" {
            if let Ok(mut guard) = self.last_handshake_params.lock() {
                *guard = Some(params.clone());
            }
        } else if freshly_spawned {
            let saved_handshake = self
                .last_handshake_params
                .lock()
                .ok()
                .and_then(|guard| guard.clone());
            if let Some(handshake_params) = saved_handshake {
                self.send_rpc_request("core.handshake", handshake_params).await?;
            }
        }

        self.send_rpc_request(method, params).await
    }

    async fn send_rpc_request(&self, method: &str, params: Value) -> Result<Value, RpcErrorPayload> {

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        {
            let mut map = self.pending.lock().map_err(|_| RpcErrorPayload {
                code: -32091,
                message: "pending map lock poisoned".into(),
                data: None,
            })?;
            map.insert(id, tx);
        }

        let payload = if params.is_null() {
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": {} })
        } else {
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
        };
        let encoded = format!("{payload}\n");

        let write_result = {
            let mut guard = self.process.lock().map_err(|_| RpcErrorPayload {
                code: -32091,
                message: "sidecar lock poisoned".into(),
                data: None,
            })?;
            match guard.as_mut() {
                Some(running) => running
                    .stdin
                    .write_all(encoded.as_bytes())
                    .and_then(|_| running.stdin.flush()),
                None => Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "sidecar not running",
                )),
            }
        };

        if let Err(err) = write_result {
            if let Ok(mut map) = self.pending.lock() {
                map.remove(&id);
            }
            return Err(RpcErrorPayload {
                code: -32094,
                message: format!("写入核心服务失败: {err}"),
                data: Some(json!({ "name": "SIDECAR_WRITE_FAILED" })),
            });
        }

        // Long operations like `trash.execute` or large queries get a generous timeout.
        let timeout = if method == "trash.execute" {
            Duration::from_secs(180)
        } else {
            Duration::from_secs(45)
        };

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(res)) => res,
            Ok(Err(_)) => Err(RpcErrorPayload {
                code: -32093,
                message: "核心服务响应通道已关闭".into(),
                data: Some(json!({ "name": "SIDECAR_CHANNEL_CLOSED" })),
            }),
            Err(_) => {
                if let Ok(mut map) = self.pending.lock() {
                    map.remove(&id);
                }
                Err(RpcErrorPayload {
                    code: -32095,
                    message: format!("核心服务请求超时: {method}"),
                    data: Some(json!({ "name": "SIDECAR_TIMEOUT" })),
                })
            }
        }
    }

    pub fn shutdown_blocking(&self) {
        let mut guard = match self.process.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if let Some(mut running) = guard.take() {
            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            let msg = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"core.shutdown\",\"params\":{{}}}}\n");
            let _ = running.stdin.write_all(msg.as_bytes());
            let _ = running.stdin.flush();
            drop(running.stdin);
            for _ in 0..20 {
                if let Ok(Some(_)) = running.child.try_wait() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let _ = running.child.kill();
            let _ = running.child.wait();
        }
    }
}

impl Drop for SidecarManager {
    fn drop(&mut self) {
        self.shutdown_blocking();
    }
}

pub fn host_platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    }
}

pub fn validate_existing_path_from_core(raw: &str) -> Result<PathBuf, String> {
    if raw.is_empty() || raw.contains('\0') {
        return Err("无效路径".into());
    }
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("仅允许显示绝对路径".into());
    }
    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitelist_enforces_exact_rpc_v1_methods() {
        assert_eq!(ALLOWED_METHODS.len(), 31);
        assert!(is_allowed_method("core.handshake"));
        assert!(is_allowed_method("items.resolvePath"));
        assert!(is_allowed_method("trash.execute"));
        assert!(!is_allowed_method("fs.remove"));
        assert!(!is_allowed_method("shell.exec"));
        assert!(!is_allowed_method("core.unknown"));
    }

    #[tokio::test]
    async fn rejects_unlisted_methods_before_spawning_sidecar() {
        let manager = SidecarManager::new(Some(PathBuf::from("/nonexistent/aicleaner-core")));
        let err = manager
            .request("dangerous.delete", json!({ "path": "/" }))
            .await
            .expect_err("unlisted method must be rejected");
        assert_eq!(err.code, -32601);
    }

    #[tokio::test]
    async fn real_sidecar_handshake_ping_and_scan_when_binary_available() {
        let probe = SidecarManager::new(None);
        let Ok(binary) = probe.resolve_sidecar_path() else {
            return;
        };

        let temp_dir = std::env::temp_dir().join(format!(
            "aicl-rust-sidecar-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(temp_dir.join("data")).unwrap();
        std::fs::create_dir_all(temp_dir.join("local")).unwrap();
        std::fs::create_dir_all(temp_dir.join("roaming")).unwrap();
        std::fs::create_dir_all(temp_dir.join(".codex").join("tmp")).unwrap();
        std::fs::write(temp_dir.join(".codex").join("tmp").join("probe.tmp"), "hello world").unwrap();

        let manager = SidecarManager::new(Some(binary))
            .with_env("AI_CLEANER_HOME", temp_dir.to_string_lossy().to_string())
            .with_env("HOME", temp_dir.to_string_lossy().to_string())
            .with_env("USERPROFILE", temp_dir.to_string_lossy().to_string())
            .with_env(
                "LOCALAPPDATA",
                temp_dir.join("local").to_string_lossy().to_string(),
            )
            .with_env(
                "APPDATA",
                temp_dir.join("roaming").to_string_lossy().to_string(),
            )
            .with_env(
                "XDG_DATA_HOME",
                temp_dir.join("data").to_string_lossy().to_string(),
            );

        let notifications = Arc::new(Mutex::new(Vec::<Value>::new()));
        let notifications_copy = Arc::clone(&notifications);
        manager.set_notification_sink(Arc::new(move |msg| {
            notifications_copy.lock().unwrap().push(msg);
        }));

        let hello = manager
            .request(
                "core.handshake",
                json!({ "protocolVersion": "1.0", "clientVersion": "rust-test", "locale": "zh-Hans" }),
            )
            .await
            .expect("handshake succeeds");
        assert_eq!(hello["protocolVersion"], "1.0");
        assert_eq!(hello["platform"], host_platform_name());

        let ping = manager.request("core.ping", json!({})).await.expect("ping succeeds");
        assert!(ping.is_object());

        let cap = manager
            .request("disk.capacity", json!({}))
            .await
            .expect("disk capacity succeeds");
        assert!(cap.get("total").is_some());

        let started = manager
            .request("scan.start", json!({}))
            .await
            .expect("scan.start succeeds");
        let scan_id = started["scanId"].as_str().expect("scanId string").to_string();

        // Wait for scan.completed notification
        let mut completed = false;
        for _ in 0..100 {
            if notifications
                .lock()
                .unwrap()
                .iter()
                .any(|n| n["method"] == "scan.completed" && n["params"]["scanId"] == scan_id)
            {
                completed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(completed, "expected scan.completed notification");

        let query = manager
            .request("items.query", json!({ "scanId": scan_id, "offset": 0, "limit": 50 }))
            .await
            .expect("items.query succeeds");
        assert!(query["total"].as_u64().unwrap_or(0) >= 1);

        let first_id = query["items"][0]["id"].as_str().expect("first item id");
        let resolved = manager
            .request("items.resolvePath", json!({ "scanId": scan_id, "itemId": first_id }))
            .await
            .expect("items.resolvePath succeeds");
        assert!(validate_existing_path_from_core(resolved["path"].as_str().unwrap()).is_ok());

        manager.shutdown_blocking();
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
