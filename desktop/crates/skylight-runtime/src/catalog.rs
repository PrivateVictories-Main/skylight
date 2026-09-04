use serde::Serialize;
use std::{ffi::OsString, path::PathBuf};

#[derive(serde::Deserialize, Serialize)]
pub struct Provider {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub executable: Option<PathBuf>,
}

pub fn search_path() -> Option<OsString> {
    let mut paths: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" });
    if let Some(home) = home {
        let home = PathBuf::from(home);
        for suffix in [
            ".local/bin",
            ".cargo/bin",
            ".bun/bin",
            ".volta/bin",
            ".local/share/mise/shims",
            ".asdf/shims",
        ] {
            let path = home.join(suffix);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    #[cfg(windows)]
    if let Some(appdata) = std::env::var_os("APPDATA") {
        paths.push(PathBuf::from(appdata).join("npm"));
    }
    std::env::join_paths(paths).ok()
}
pub fn resolve(name: &str) -> Option<PathBuf> {
    which::which_in(name, search_path(), std::env::current_dir().ok()?).ok()
}
pub fn providers() -> Vec<Provider> {
    let mut entries: Vec<Provider> =
        serde_json::from_str(include_str!("../../../../shared/cli-catalog.json"))
            .expect("checked-in catalog");
    for item in &mut entries {
        item.executable = resolve(&item.id);
    }
    entries
}
pub fn default_shell() -> PathBuf {
    #[cfg(windows)]
    {
        resolve("pwsh.exe")
            .or_else(|| resolve("powershell.exe"))
            .unwrap_or_else(|| PathBuf::from("cmd.exe"))
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("SHELL")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute() && p.is_file())
            .unwrap_or_else(|| PathBuf::from("/bin/sh"))
    }
}
