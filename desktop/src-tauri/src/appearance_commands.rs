use super::{Result, Runtime};
use base64::Engine;
use serde::Serialize;
use skylight_runtime::appearance::{self, AppearanceHistory, AppearanceSettings, TerminalTheme};
use std::{io::Read, path::PathBuf, sync::Arc};
use tauri::State;
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub async fn get_appearance(runtime: State<'_, Arc<Runtime>>) -> Result<AppearanceHistory> {
    let runtime = runtime.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _lock = runtime.appearance_lock.lock().map_err(|e| e.to_string())?;
        AppearanceHistory::load(&runtime.path.with_file_name("appearance.json"))
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn save_appearance(
    runtime: State<'_, Arc<Runtime>>,
    settings: AppearanceSettings,
) -> Result<AppearanceHistory> {
    let runtime = runtime.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _lock = runtime.appearance_lock.lock().map_err(|e| e.to_string())?;
        let path = runtime.path.with_file_name("appearance.json");
        let mut history = AppearanceHistory::load(&path).map_err(|e| e.to_string())?;
        history.commit(settings, &path).map_err(|e| e.to_string())?;
        Ok(history)
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn revert_appearance(runtime: State<'_, Arc<Runtime>>) -> Result<AppearanceHistory> {
    let runtime = runtime.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _lock = runtime.appearance_lock.lock().map_err(|e| e.to_string())?;
        let path = runtime.path.with_file_name("appearance.json");
        let mut history = AppearanceHistory::load(&path).map_err(|e| e.to_string())?;
        history.revert(&path).map_err(|e| e.to_string())?;
        Ok(history)
    })
    .await
    .map_err(|e| e.to_string())?
}
#[derive(Serialize)]
pub struct DetectedTheme {
    id: String,
    name: String,
}
fn sources() -> Vec<(String, String, PathBuf)> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_default();
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    let mut paths = vec![
        ("ghostty", "Ghostty", config.join("ghostty/config.ghostty")),
        (
            "ghostty-legacy",
            "Ghostty (legacy config)",
            config.join("ghostty/config"),
        ),
        ("vscode", "VS Code", config.join("Code/User/settings.json")),
    ];
    if cfg!(target_os = "macos") {
        paths.push((
            "ghostty-macos",
            "Ghostty (macOS)",
            home.join("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
        ));
        paths.push((
            "ghostty-macos-legacy",
            "Ghostty (macOS legacy)",
            home.join("Library/Application Support/com.mitchellh.ghostty/config"),
        ));
        paths.push((
            "vscode-macos",
            "VS Code (macOS)",
            home.join("Library/Application Support/Code/User/settings.json"),
        ));
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let local = PathBuf::from(local);
        paths.push((
            "windows-terminal",
            "Windows Terminal",
            local.join("Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"),
        ));
        paths.push((
            "windows-terminal-preview",
            "Windows Terminal Preview",
            local.join(
                "Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json",
            ),
        ));
        paths.push((
            "windows-terminal-unpackaged",
            "Windows Terminal (unpackaged)",
            local.join("Microsoft/Windows Terminal/settings.json"),
        ));
    }
    if let Some(roaming) = std::env::var_os("APPDATA") {
        paths.push((
            "vscode-windows",
            "VS Code (Windows)",
            PathBuf::from(roaming).join("Code/User/settings.json"),
        ));
    }
    paths
        .into_iter()
        .filter(|(_, _, path)| path.is_absolute())
        .map(|(id, name, path)| (id.into(), name.into(), path))
        .collect()
}
#[tauri::command]
pub async fn discover_themes() -> Result<Vec<DetectedTheme>> {
    tauri::async_runtime::spawn_blocking(|| {
        Ok(sources()
            .into_iter()
            .filter(|(_, _, path)| path.is_file())
            .map(|(id, name, _)| DetectedTheme { id, name })
            .collect())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn import_detected_theme(id: String) -> Result<Vec<TerminalTheme>> {
    tauri::async_runtime::spawn_blocking(move || {
        let (_, _, path) = sources()
            .into_iter()
            .find(|(key, _, _)| key == &id)
            .ok_or("Theme source is no longer available")?;
        let bytes = appearance::read_theme_document(&path).map_err(|e| e.to_string())?;
        appearance::parse_theme(
            &bytes,
            path.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("config"),
        )
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn import_theme_file(app: tauri::AppHandle) -> Result<Option<Vec<TerminalTheme>>> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .set_title("Import terminal theme")
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        let bytes = appearance::read_theme_document(&path).map_err(|e| e.to_string())?;
        appearance::parse_theme(
            &bytes,
            path.file_name().and_then(|s| s.to_str()).unwrap_or("theme"),
        )
        .map(Some)
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn choose_background(app: tauri::AppHandle) -> Result<Option<String>> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .set_title("Choose background image")
            .add_filter("Image", &["png", "jpg", "jpeg"])
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err("Choose a PNG or JPEG file".into());
        }
        let mut bytes = Vec::new();
        file.take(8 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 8 * 1024 * 1024 {
            return Err("Background image exceeds 8 MiB".into());
        }
        let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            "image/png"
        } else if bytes.starts_with(b"\xff\xd8\xff") {
            "image/jpeg"
        } else {
            return Err("Choose a PNG or JPEG image".into());
        };
        let data = format!(
            "data:{mime};base64,{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        );
        let settings = AppearanceSettings {
            background_image: Some(data.clone()),
            ..Default::default()
        };
        settings.validate().map_err(|e| e.to_string())?;
        Ok(Some(data))
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn bundled_themes() -> Result<Vec<TerminalTheme>> {
    tauri::async_runtime::spawn_blocking(appearance::bundled_themes)
        .await
        .map_err(|e| e.to_string())
}
