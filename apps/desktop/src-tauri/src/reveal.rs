use std::path::Path;
use std::process::Command;

/// Reveals a Core-verified path in the native file manager (Finder / Explorer / Linux FM).
/// Never invoked with raw user input — callers must first resolve paths via `aicleaner-core`.
pub fn reveal_in_file_manager(path: &Path) -> Result<(), String> {
    let target = if path.exists() {
        path
    } else if let Some(parent) = path.parent() {
        if parent.exists() {
            parent
        } else {
            return Err(format!("路径不存在：{}", path.display()));
        }
    } else {
        return Err(format!("路径不存在：{}", path.display()));
    };

    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .arg("-R")
            .arg(target)
            .spawn()
            .map_err(|e| format!("无法在 Finder 中打开：{e}"))?;
        Ok(())
    }

    #[cfg(target_os = "windows")]
    {
        let arg = format!("/select,{}", target.display());
        Command::new("explorer.exe")
            .arg(arg)
            .spawn()
            .map_err(|e| format!("无法在文件资源管理器中打开：{e}"))?;
        Ok(())
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let dir_to_open = if target.is_dir() {
            target
        } else {
            target.parent().unwrap_or(target)
        };
        Command::new("xdg-open")
            .arg(dir_to_open)
            .spawn()
            .map_err(|e| format!("无法在文件管理器中打开：{e}"))?;
        Ok(())
    }
}
