use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    path::Path,
};
use uuid::Uuid;

pub const MAX_WORKSPACE_BYTES: u64 = 4 * 1024 * 1024;
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSpec {
    pub shell_path: Option<String>,
    pub harness: Option<String>,
    #[serde(default)]
    pub arguments: Vec<String>,
    pub working_directory: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Instance {
    pub id: Uuid,
    pub name: String,
    pub spec: TerminalSpec,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tile {
    pub id: Uuid,
    #[serde(rename = "itemID")]
    pub item_id: Uuid,
    pub origin: [f64; 2],
    pub size: [f64; 2],
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Canvas {
    pub id: Uuid,
    pub name: String,
    pub tiles: Vec<Tile>,
    #[serde(default)]
    pub pan: [f64; 2],
    #[serde(default = "one")]
    pub zoom: f64,
    #[serde(default)]
    pub docks: Map<String, Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
fn one() -> f64 {
    1.0
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    #[serde(default)]
    pub launch_presets: Vec<Instance>,
    pub version: u32,
    pub instances: Vec<Instance>,
    pub canvases: Vec<Canvas>,
    pub selected_instance: Option<Uuid>,
    pub selected_canvas: Option<Uuid>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl Default for Workspace {
    fn default() -> Self {
        Self {
            launch_presets: vec![],
            version: 2,
            instances: vec![],
            canvases: vec![],
            selected_instance: None,
            selected_canvas: None,
            extra: Map::new(),
        }
    }
}
impl Workspace {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() as u64 > MAX_WORKSPACE_BYTES {
            bail!("Workspace file exceeds 4 MiB");
        }
        let value: Self =
            serde_json::from_slice(bytes).context("Workspace is not valid Skylight JSON")?;
        value.validate()?;
        Ok(value)
    }
    pub fn validate(&self) -> Result<()> {
        if self.version != 2 {
            bail!(
                "Unsupported workspace version {}; this preview reads version 2",
                self.version
            );
        }
        let mut preset_ids = HashSet::new();
        for preset in &self.launch_presets {
            if !preset_ids.insert(preset.id) {
                bail!("Duplicate preset identifier");
            }
        }
        let mut ids = HashSet::new();
        for item in &self.instances {
            if !ids.insert(item.id) {
                bail!("Duplicate terminal identifier");
            }
            if item.name.len() > 4096 || item.spec.arguments.len() > 4096 {
                bail!("Invalid terminal metadata");
            }
        }
        let mut boards = HashSet::new();
        let mut residents = HashSet::new();
        for board in &self.canvases {
            if !boards.insert(board.id) {
                bail!("Duplicate canvas identifier");
            }
            if !board.zoom.is_finite()
                || board.zoom <= 0.0
                || !board.pan.iter().all(|v| v.is_finite())
            {
                bail!("Invalid canvas geometry");
            }
            for tile in &board.tiles {
                if !ids.contains(&tile.item_id) || !residents.insert(tile.item_id) {
                    bail!("A terminal has invalid or duplicate canvas residency");
                }
                if !tile.origin.iter().chain(&tile.size).all(|v| v.is_finite())
                    || tile.size.iter().any(|v| *v <= 0.0)
                {
                    bail!("Invalid tile geometry");
                }
            }
            // Keep the macOS dock payload intact even before the portable UI
            // implements edge rails. Validate references without flattening it.
            for rail in board.docks.values() {
                let slots = rail
                    .get("slots")
                    .and_then(Value::as_array)
                    .context("Invalid dock rail")?;
                for slot in slots {
                    let id: Uuid = serde_json::from_value(
                        slot.get("itemID").context("Missing dock resident")?.clone(),
                    )?;
                    if !ids.contains(&id) || !residents.insert(id) {
                        bail!("Invalid dock residency");
                    }
                }
            }
        }
        if self.selected_instance.is_some_and(|id| !ids.contains(&id))
            || self.selected_canvas.is_some_and(|id| !boards.contains(&id))
        {
            bail!("Workspace selection points to a missing item");
        }
        Ok(())
    }
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        if fs::metadata(path)?.len() > MAX_WORKSPACE_BYTES {
            bail!("Workspace file exceeds 4 MiB");
        }
        Self::decode(&read_document(path)?)
    }
    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let bytes = serde_json::to_vec_pretty(self)?;
        if bytes.len() as u64 > MAX_WORKSPACE_BYTES {
            bail!("Workspace file exceeds 4 MiB");
        }
        let parent = path.parent().context("Missing workspace directory")?;
        fs::create_dir_all(parent)?;
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        temp.write_all(&bytes)?;
        temp.as_file().sync_all()?;
        temp.persist(path).map_err(|e| e.error)?;
        Ok(())
    }
}

/// The read itself is bounded, including if a selected file changes size.
pub fn read_document(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(MAX_WORKSPACE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_WORKSPACE_BYTES {
        bail!("Workspace file exceeds 4 MiB");
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn macos_fixture_preserves_docks_geometry_arguments_and_unknown_fields() {
        let original: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/workspace-v2.json"
        ))
        .unwrap();
        let workspace = Workspace::decode(original.to_string().as_bytes()).unwrap();
        let encoded = serde_json::to_value(&workspace).unwrap();
        assert_eq!(
            encoded["canvases"][0]["docks"],
            original["canvases"][0]["docks"]
        );
        assert_eq!(
            encoded["canvases"][0]["tiles"][0]["origin"],
            original["canvases"][0]["tiles"][0]["origin"]
        );
        assert_eq!(
            encoded["instances"][0]["spec"]["arguments"],
            original["instances"][0]["spec"]["arguments"]
        );
        assert_eq!(encoded["futureMetadata"], original["futureMetadata"]);
    }
    #[test]
    fn future_versions_and_duplicate_residency_are_not_silently_rewritten() {
        let mut value: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/workspace-v2.json"
        ))
        .unwrap();
        value["version"] = 3.into();
        assert!(Workspace::decode(value.to_string().as_bytes()).is_err());
        value["version"] = 2.into();
        value["canvases"][0]["tiles"][0]["itemID"] = value["instances"][1]["id"].clone();
        assert!(Workspace::decode(value.to_string().as_bytes()).is_err());
    }
    #[test]
    fn failed_save_preserves_previous_workspace() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("workspace.json");
        let mut workspace = Workspace::default();
        workspace.save(&file).unwrap();
        let before = fs::read(&file).unwrap();
        workspace.version = 99;
        assert!(workspace.save(&file).is_err());
        assert_eq!(fs::read(file).unwrap(), before);
    }
    #[test]
    fn corrupt_existing_file_is_reported_without_replacing_it() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("workspace.json");
        fs::write(&file, b"broken").unwrap();
        assert!(Workspace::load(&file).is_err());
        assert_eq!(fs::read(file).unwrap(), b"broken");
    }
}
