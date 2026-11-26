// AICL-33 spike: empty Tauri 2 window + `aicleaner-core` sidecar over stdio JSON-RPC.
// Only used to measure installer size, installed size and idle memory. No cleanup capability.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

use tauri::{Manager, RunEvent};

struct Sidecar {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl Sidecar {
    fn spawn() -> std::io::Result<Self> {
        // Tauri `bundle.externalBin` places the sidecar next to the main executable.
        let exe = std::env::current_exe()?;
        let dir = exe.parent().map(PathBuf::from).unwrap_or_default();
        let name = if cfg!(windows) { "aicleaner-core.exe" } else { "aicleaner-core" };
        let mut command = Command::new(dir.join(name));
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = command.spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = BufReader::new(child.stdout.take().expect("piped stdout"));
        Ok(Self { child, stdin, stdout, next_id: 1 })
    }

    fn call(&mut self, method: &str) -> Result<serde_json::Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let request = serde_json::json!({ "jsonrpc": "2.0", "id": id, "method": method });
        writeln!(self.stdin, "{request}").map_err(|e| e.to_string())?;
        self.stdin.flush().map_err(|e| e.to_string())?;
        let mut line = String::new();
        self.stdout.read_line(&mut line).map_err(|e| e.to_string())?;
        serde_json::from_str(&line).map_err(|e| e.to_string())
    }

    fn shutdown(&mut self) {
        let _ = self.call("shutdown");
        let _ = self.child.wait();
    }
}

struct SidecarState(Mutex<Option<Sidecar>>);

#[tauri::command]
fn hello(state: tauri::State<'_, SidecarState>) -> Result<serde_json::Value, String> {
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    let sidecar = guard.as_mut().ok_or("sidecar not running")?;
    let response = sidecar.call("hello")?;
    if let Some(path) = std::env::var_os("AICL33_HELLO_FILE") {
        std::fs::write(path, response.to_string()).map_err(|e| e.to_string())?;
    }
    Ok(response)
}

fn main() {
    let app = tauri::Builder::default()
        .manage(SidecarState(Mutex::new(None)))
        .setup(|app| {
            let sidecar = Sidecar::spawn().map_err(|e| format!("failed to start sidecar: {e}"))?;
            *app.state::<SidecarState>().0.lock().unwrap() = Some(sidecar);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![hello])
        .build(tauri::generate_context!())
        .expect("failed to build tauri app");

    app.run(|handle, event| {
        if let RunEvent::Exit = event {
            if let Some(mut sidecar) = handle.state::<SidecarState>().0.lock().unwrap().take() {
                sidecar.shutdown();
            }
        }
    });
}
