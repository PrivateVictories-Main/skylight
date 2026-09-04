#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use fs2::FileExt;
use serde::Serialize;
use skylight_runtime::{
    catalog,
    session::{LaunchRequest, Session, SessionEvent, Sink},
    workspace::{Instance, Workspace},
};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tauri::{
    ipc::{Channel, InvokeResponseBody},
    Manager, State,
};
use tauri_plugin_dialog::DialogExt;
use uuid::Uuid;

type Result<T> = std::result::Result<T, String>;
struct Runtime {
    sessions: Mutex<HashMap<Uuid, Arc<Session>>>,
    path: PathBuf,
    _lock: File,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Bootstrap {
    workspace: Workspace,
    providers: Vec<catalog::Provider>,
    default_shell: String,
    home: String,
    platform: String,
}

#[tauri::command]
async fn bootstrap(runtime: State<'_, Arc<Runtime>>) -> Result<Bootstrap> {
    let path = runtime.path.clone();
    tauri::async_runtime::spawn_blocking(move || {
        Ok(Bootstrap {
            workspace: Workspace::load(&path).map_err(|e| e.to_string())?,
            providers: catalog::providers(),
            default_shell: catalog::default_shell().to_string_lossy().into_owned(),
            home: std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                .unwrap_or_default(),
            platform: std::env::consts::OS.into(),
        })
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
async fn refresh_providers() -> Result<Vec<catalog::Provider>> {
    tauri::async_runtime::spawn_blocking(catalog::providers)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn save_workspace(runtime: State<'_, Arc<Runtime>>, workspace: Workspace) -> Result<()> {
    let path = runtime.path.clone();
    tauri::async_runtime::spawn_blocking(move || workspace.save(&path).map_err(|e| e.to_string()))
        .await
        .map_err(|e| e.to_string())?
}
#[tauri::command]
async fn start_session(
    runtime: State<'_, Arc<Runtime>>,
    id: String,
    request: LaunchRequest,
    output: Channel<InvokeResponseBody>,
) -> Result<Option<u32>> {
    let id = Uuid::parse_str(&id).map_err(|_| "Invalid session identifier")?;
    let runtime = runtime.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut sessions = runtime.sessions.lock().map_err(|e| e.to_string())?;
        if sessions.get(&id).is_some_and(|s| s.is_alive()) {
            return Err("Session is already running".into());
        }
        // Register under the same lock consulted by acknowledge_output, before
        // an early channel callback can acknowledge the first PTY bytes.
        let sink: Sink = Arc::new(move |event| {
            let data = match event {
                SessionEvent::Output(bytes) => {
                    let mut data = Vec::with_capacity(bytes.len() + 1);
                    data.push(0);
                    data.extend(bytes);
                    data
                }
                SessionEvent::Exited(code) => {
                    let mut data = vec![1];
                    data.extend(code.unwrap_or(u32::MAX).to_le_bytes());
                    data
                }
                SessionEvent::Error(error) => {
                    let mut data = vec![2];
                    data.extend(error.as_bytes());
                    data
                }
            };
            output
                .send(InvokeResponseBody::Raw(data))
                .map_err(|e| e.to_string())
        });
        let session = Arc::new(Session::spawn(request, sink).map_err(|e| format!("{e:#}"))?);
        let pid = session.process_id;
        sessions.insert(id, session);
        Ok(pid)
    })
    .await
    .map_err(|e| e.to_string())?
}
fn lookup(runtime: &Runtime, id: &str) -> Result<Arc<Session>> {
    let id = Uuid::parse_str(id).map_err(|_| "Invalid session identifier")?;
    runtime
        .sessions
        .lock()
        .map_err(|e| e.to_string())?
        .get(&id)
        .cloned()
        .ok_or_else(|| "Session is closed".into())
}
#[tauri::command]
async fn terminal_input(runtime: State<'_, Arc<Runtime>>, id: String, data: Vec<u8>) -> Result<()> {
    lookup(&runtime, &id)?
        .write(data)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn resize_terminal(
    runtime: State<'_, Arc<Runtime>>,
    id: String,
    columns: u16,
    rows: u16,
) -> Result<()> {
    lookup(&runtime, &id)?
        .resize(columns, rows)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn acknowledge_output(
    runtime: State<'_, Arc<Runtime>>,
    id: String,
    through: u64,
) -> Result<()> {
    lookup(&runtime, &id)?
        .acknowledge(through)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn close_session(runtime: State<'_, Arc<Runtime>>, id: String) -> Result<()> {
    let id = Uuid::parse_str(&id).map_err(|_| "Invalid session identifier")?;
    if let Some(session) = runtime
        .sessions
        .lock()
        .map_err(|e| e.to_string())?
        .remove(&id)
    {
        session.close();
    }
    Ok(())
}
#[derive(Serialize)]
struct Imported {
    workspace: Option<Workspace>,
    presets: Vec<Instance>,
}
#[tauri::command]
async fn import_workspace(app: tauri::AppHandle) -> Result<Option<Imported>> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .add_filter("Skylight workspace", &["json"])
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        let bytes = skylight_runtime::workspace::read_document(&path).map_err(|e| e.to_string())?;
        if bytes.len() > 4 * 1024 * 1024 {
            return Err("Workspace exceeds 4 MiB".into());
        }
        let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if value.is_array() {
            let presets: Vec<Instance> =
                serde_json::from_value(value).map_err(|e| e.to_string())?;
            Ok(Some(Imported {
                workspace: None,
                presets,
            }))
        } else {
            let workspace = Workspace::decode(&bytes).map_err(|e| e.to_string())?;
            let presets = workspace.launch_presets.clone();
            Ok(Some(Imported {
                workspace: Some(workspace),
                presets,
            }))
        }
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
async fn export_workspace(app: tauri::AppHandle, workspace: Workspace) -> Result<bool> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .add_filter("Skylight workspace", &["json"])
            .set_file_name("skylight-workspace.json")
            .blocking_save_file()
        else {
            return Ok(false);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        workspace.save(&path).map_err(|e| e.to_string())?;
        Ok(true)
    })
    .await
    .map_err(|e| e.to_string())?
}
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let directory = std::env::var_os("SKYLIGHT_PORTABLE_SUPPORT_DIR")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .unwrap_or(app.path().app_data_dir()?);
            std::fs::create_dir_all(&directory)?;
            let lock = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(directory.join("workspace.lock"))?;
            lock.try_lock_exclusive()
                .map_err(|_| "This Skylight workspace is already open")?;
            app.manage(Arc::new(Runtime {
                sessions: Mutex::new(HashMap::new()),
                path: directory.join("workspace.json"),
                _lock: lock,
            }));
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                let runtime = window.state::<Arc<Runtime>>();
                if let Ok(mut sessions) = runtime.sessions.lock() {
                    sessions.clear();
                };
            }
        })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            refresh_providers,
            save_workspace,
            start_session,
            terminal_input,
            resize_terminal,
            acknowledge_output,
            close_session,
            import_workspace,
            export_workspace
        ])
        .run(tauri::generate_context!())
        .expect("Unable to start Skylight");
}
