//! Appearance imports are data, never configuration to execute or include.
//! Values are normalized before they reach a renderer; persistence is atomic.
use anyhow::{bail, Context, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{Read, Write},
    path::Path,
    sync::OnceLock,
};

pub const MAX_THEME_BYTES: usize = 512 * 1024;
pub const MAX_APPEARANCE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_APPEARANCE_HISTORY_BYTES: usize = 32 * 1024 * 1024;
const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_THEMES: usize = 128;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalTheme {
    pub name: String,
    pub source: String,
    pub background: String,
    pub foreground: String,
    pub cursor: Option<String>,
    pub selection_background: Option<String>,
    #[serde(default)]
    pub palette: BTreeMap<String, String>,
    pub font_family: Option<String>,
    pub font_size: Option<f64>,
    pub background_opacity: Option<f64>,
    pub cursor_style: Option<String>,
    pub cursor_blink: Option<bool>,
    pub padding_x: Option<u16>,
    pub padding_y: Option<u16>,
    #[serde(default)]
    pub skipped: Vec<String>,
}

impl TerminalTheme {
    fn new(name: &str, source: &str, background: Color, foreground: Color) -> Self {
        Self {
            name: name.into(),
            source: source.into(),
            background: background.rgb,
            foreground: foreground.rgb,
            cursor: None,
            selection_background: None,
            palette: BTreeMap::new(),
            font_family: None,
            font_size: None,
            background_opacity: background.alpha,
            cursor_style: None,
            cursor_blink: None,
            padding_x: None,
            padding_y: None,
            skipped: vec![],
        }
    }

    pub fn validate(&self) -> Result<()> {
        if !safe_text(&self.name, 256) || !safe_text(&self.source, 64) {
            bail!("Invalid theme name or source");
        }
        for color in [&self.background, &self.foreground]
            .into_iter()
            .chain(self.cursor.iter())
            .chain(self.selection_background.iter())
            .chain(self.palette.values())
        {
            if !canonical_color(color) {
                bail!("Theme colors must be six-digit hexadecimal values");
            }
        }
        if self.palette.keys().any(|key| {
            key.parse::<u8>()
                .map_or(true, |index| index > 15 || index.to_string() != *key)
        }) {
            bail!("Theme palette indices must be 0 through 15");
        }
        if self
            .font_family
            .as_ref()
            .is_some_and(|font| !safe_text(font, 256))
        {
            bail!("Invalid font family");
        }
        if self.font_size.is_some_and(|n| !in_range(n, 6.0, 72.0)) {
            bail!("Font size must be between 6 and 72");
        }
        if self
            .background_opacity
            .is_some_and(|n| !in_range(n, 0.0, 1.0))
        {
            bail!("Background opacity must be between 0 and 1");
        }
        if self
            .cursor_style
            .as_ref()
            .is_some_and(|style| !matches!(style.as_str(), "block" | "bar" | "underline"))
        {
            bail!("Unsupported cursor style");
        }
        if self.padding_x.is_some_and(|n| n > 64) || self.padding_y.is_some_and(|n| n > 64) {
            bail!("Terminal padding must be between 0 and 64");
        }
        if self.skipped.len() > 256 || self.skipped.iter().any(|n| !safe_text(n, 256)) {
            bail!("Invalid theme import notes");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppearanceSettings {
    #[serde(default = "version_one")]
    pub version: u32,
    pub theme: Option<TerminalTheme>,
    pub background_image: Option<String>,
    #[serde(default = "default_font_size")]
    pub font_size: f64,
    #[serde(default = "opaque")]
    pub opacity: f64,
    #[serde(default = "default_padding_x")]
    pub padding_x: u16,
    #[serde(default = "default_padding_y")]
    pub padding_y: u16,
}

fn version_one() -> u32 {
    1
}
fn default_font_size() -> f64 {
    14.0
}
fn opaque() -> f64 {
    1.0
}
fn default_padding_x() -> u16 {
    11
}
fn default_padding_y() -> u16 {
    12
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        Self {
            version: 1,
            theme: None,
            background_image: None,
            font_size: 14.0,
            opacity: 1.0,
            padding_x: 11,
            padding_y: 12,
        }
    }
}

impl AppearanceSettings {
    pub fn validate(&self) -> Result<()> {
        if self.version != 1 {
            bail!("Unsupported appearance settings version {}", self.version);
        }
        if !in_range(self.font_size, 6.0, 72.0) {
            bail!("Font size must be between 6 and 72");
        }
        if !in_range(self.opacity, 0.0, 1.0) {
            bail!("Background opacity must be between 0 and 1");
        }
        if self.padding_x > 64 || self.padding_y > 64 {
            bail!("Terminal padding must be between 0 and 64");
        }
        if let Some(theme) = &self.theme {
            theme.validate()?;
        }
        if let Some(image) = &self.background_image {
            validate_image(image)?;
        }
        Ok(())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        check_document_size(bytes, MAX_APPEARANCE_BYTES)?;
        let settings: Self =
            serde_json::from_slice(bytes).context("Appearance settings are not valid JSON")?;
        settings.validate()?;
        Ok(settings)
    }

    pub fn load(path: &Path) -> Result<Self> {
        match read_bounded(path, MAX_APPEARANCE_BYTES) {
            Ok(bytes) => Self::decode(&bytes),
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                Ok(Self::default())
            }
            Err(error) => Err(error),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let bytes = serde_json::to_vec_pretty(self)?;
        check_document_size(&bytes, MAX_APPEARANCE_BYTES)?;
        write_atomic(&bytes, path)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppearanceHistory {
    pub current: AppearanceSettings,
    pub previous: Option<AppearanceSettings>,
}

impl AppearanceHistory {
    pub fn load(path: &Path) -> Result<Self> {
        let bytes = match read_bounded(path, MAX_APPEARANCE_HISTORY_BYTES) {
            Ok(bytes) => bytes,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(Self::default())
            }
            Err(error) => return Err(error),
        };
        let history: Self =
            serde_json::from_slice(&bytes).context("Appearance history is not valid JSON")?;
        history.validate()?;
        Ok(history)
    }

    pub fn validate(&self) -> Result<()> {
        self.current.validate()?;
        if let Some(previous) = &self.previous {
            previous.validate()?;
        }
        Ok(())
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let bytes = serde_json::to_vec_pretty(self)?;
        check_document_size(&bytes, MAX_APPEARANCE_HISTORY_BYTES)?;
        write_atomic(&bytes, path)
    }

    pub fn commit(&mut self, new: AppearanceSettings, path: &Path) -> Result<()> {
        new.validate()?;
        if new == self.current {
            return Ok(());
        }
        let next = Self {
            current: new,
            previous: Some(self.current.clone()),
        };
        next.save(path)?;
        *self = next;
        Ok(())
    }

    /// Undo remains available after restart. A second undo restores the look
    /// that was just replaced, instead of destroying either saved choice.
    pub fn revert(&mut self, path: &Path) -> Result<bool> {
        let Some(previous) = &self.previous else {
            return Ok(false);
        };
        let next = Self {
            current: previous.clone(),
            previous: Some(self.current.clone()),
        };
        next.save(path)?;
        *self = next;
        Ok(true)
    }
}

fn write_atomic(bytes: &[u8], path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let mut temp = tempfile::NamedTempFile::new_in(parent)?;
    temp.write_all(bytes)?;
    temp.as_file().sync_all()?;
    temp.persist(path).map_err(|error| error.error)?;
    Ok(())
}

pub fn read_theme_document(path: &Path) -> Result<Vec<u8>> {
    read_bounded(path, MAX_THEME_BYTES)
}

fn read_bounded(path: &Path, max_bytes: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(max_bytes as u64 + 1)
        .read_to_end(&mut bytes)?;
    check_document_size(&bytes, max_bytes)?;
    Ok(bytes)
}

fn check_size(bytes: &[u8]) -> Result<()> {
    check_document_size(bytes, MAX_THEME_BYTES)
}

fn check_document_size(bytes: &[u8], max_bytes: usize) -> Result<()> {
    if bytes.len() > max_bytes {
        bail!("Appearance document exceeds {} KiB", max_bytes / 1024);
    }
    Ok(())
}

fn validate_image(value: &str) -> Result<()> {
    let (body, png) = if let Some(body) = value.strip_prefix("data:image/png;base64,") {
        (body, true)
    } else if let Some(body) = value.strip_prefix("data:image/jpeg;base64,") {
        (body, false)
    } else {
        bail!("Background images must be embedded PNG or JPEG data");
    };
    if body.len() > MAX_IMAGE_BYTES.div_ceil(3) * 4 {
        bail!("Background image exceeds 8 MiB");
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(body)
        .context("Background image has invalid base64 data")?;
    if bytes.len() > MAX_IMAGE_BYTES {
        bail!("Background image exceeds 8 MiB");
    }
    let dimensions = if png {
        if !bytes.starts_with(b"\x89PNG\r\n\x1a\n")
            || bytes.len() < 33
            || &bytes[8..16] != b"\0\0\0\rIHDR"
        {
            bail!("Background image content does not match its PNG type");
        }
        (
            u32::from_be_bytes(bytes[16..20].try_into().unwrap()),
            u32::from_be_bytes(bytes[20..24].try_into().unwrap()),
        )
    } else {
        jpeg_dimensions(&bytes)?
    };
    if dimensions.0 == 0
        || dimensions.1 == 0
        || dimensions.0 > 8192
        || dimensions.1 > 8192
        || u64::from(dimensions.0) * u64::from(dimensions.1) > 33_000_000
    {
        bail!("Background image must be at most 8192 pixels per side and 33 megapixels");
    }
    Ok(())
}

/// Read only bounded JPEG marker headers, without decompressing image data.
fn jpeg_dimensions(bytes: &[u8]) -> Result<(u32, u32)> {
    if !bytes.starts_with(b"\xff\xd8\xff") || !bytes.ends_with(b"\xff\xd9") {
        bail!("Background image content does not match its JPEG type");
    }
    let mut index = 2;
    while index < bytes.len() {
        if bytes[index] != 0xff {
            bail!("Invalid JPEG marker header");
        }
        while bytes.get(index) == Some(&0xff) {
            index += 1;
        }
        let marker = *bytes.get(index).context("Incomplete JPEG marker")?;
        index += 1;
        if matches!(marker, 0xd9 | 0xda) {
            break;
        }
        if matches!(marker, 0xd8 | 0x01 | 0xd0..=0xd7) {
            continue;
        }
        let length_bytes = bytes
            .get(index..index + 2)
            .context("Incomplete JPEG segment length")?;
        let length = u16::from_be_bytes(length_bytes.try_into().unwrap()) as usize;
        if length < 2 || index + length > bytes.len() {
            bail!("Invalid JPEG segment length");
        }
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) {
            if length < 8 {
                bail!("Incomplete JPEG frame header");
            }
            let height = u16::from_be_bytes(bytes[index + 3..index + 5].try_into().unwrap());
            let width = u16::from_be_bytes(bytes[index + 5..index + 7].try_into().unwrap());
            return Ok((u32::from(width), u32::from(height)));
        }
        index += length;
    }
    bail!("JPEG image has no supported frame dimensions")
}

/// Import colors and supported appearance values only. Includes, commands,
/// profiles and keybindings are never executed, expanded or activated.
pub fn parse_theme(bytes: &[u8], filename: &str) -> Result<Vec<TerminalTheme>> {
    check_size(bytes)?;
    let text = std::str::from_utf8(bytes)
        .context("Theme file must use UTF-8 text")?
        .trim_start_matches('\u{feff}')
        .trim();
    if text.is_empty() {
        bail!("Theme file is empty");
    }
    let name = Path::new(filename)
        .file_stem()
        .and_then(|name| name.to_str())
        .filter(|name| safe_text(name, 256))
        .unwrap_or("Imported theme");
    let extension = Path::new(filename)
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("");
    let themes = if extension.eq_ignore_ascii_case("json")
        || extension.eq_ignore_ascii_case("jsonc")
        || text.starts_with(['{', '['])
        || text.starts_with("//")
        || text.starts_with("/*")
    {
        let root: Value = serde_json::from_slice(&normalize_jsonc(text)?)
            .context("Theme file is not valid JSON or JSONC")?;
        let root = root.as_object().context("A theme must be a JSON object")?;
        if root.contains_key("schemes")
            || (root.contains_key("background") && root.contains_key("foreground"))
        {
            parse_windows(root, name)?
        } else {
            vec![parse_vscode(root, name)?]
        }
    } else {
        parse_ghostty_variants(text, name)?
    };
    if themes.is_empty() {
        bail!("No usable themes found in this file");
    }
    for theme in &themes {
        theme.validate()?;
    }
    Ok(themes)
}

/// The same checked-in color definitions used by the native macOS app.
pub fn bundled_themes() -> Vec<TerminalTheme> {
    bundled_catalog().clone()
}

fn bundled_catalog() -> &'static Vec<TerminalTheme> {
    static THEMES: OnceLock<Vec<TerminalTheme>> = OnceLock::new();
    THEMES.get_or_init(|| {
        serde_json::from_str(include_str!("../../../../shared/terminal-themes.json"))
            .expect("The checked-in native theme catalog must be valid")
    })
}

fn resolve_bundled(name: &str) -> Option<TerminalTheme> {
    bundled_catalog()
        .iter()
        .find(|theme| theme.name.eq_ignore_ascii_case(name.trim()))
        .cloned()
}

#[derive(Clone)]
struct Color {
    rgb: String,
    alpha: Option<f64>,
}

fn color(value: &str) -> Option<Color> {
    let literal = value.trim();
    let lower = literal.to_ascii_lowercase();
    let named = match lower.as_str() {
        "black" => "000000",
        "white" => "ffffff",
        "red" => "ff0000",
        "green" => "008000",
        "lime" => "00ff00",
        "blue" => "0000ff",
        "yellow" => "ffff00",
        "cyan" | "aqua" => "00ffff",
        "magenta" | "fuchsia" => "ff00ff",
        "gray" | "grey" => "808080",
        "silver" => "c0c0c0",
        "maroon" => "800000",
        "olive" => "808000",
        "navy" => "000080",
        "teal" => "008080",
        "purple" => "800080",
        "orange" => "ffa500",
        _ => "",
    };
    if !named.is_empty() {
        return Some(Color {
            rgb: format!("#{named}"),
            alpha: None,
        });
    }
    if lower.starts_with("rgb(") || lower.starts_with("rgba(") {
        let has_alpha = lower.starts_with("rgba(");
        let values = lower
            .strip_suffix(')')?
            .get(if has_alpha { 5.. } else { 4.. })?
            .split(',')
            .map(str::trim)
            .collect::<Vec<_>>();
        if values.len() != if has_alpha { 4 } else { 3 } {
            return None;
        }
        let red = values[0].parse::<u8>().ok()?;
        let green = values[1].parse::<u8>().ok()?;
        let blue = values[2].parse::<u8>().ok()?;
        let alpha = if has_alpha {
            let raw = values[3].parse::<f64>().ok()?;
            if !in_range(raw, 0.0, 255.0) {
                return None;
            }
            Some((if raw <= 1.0 { raw * 255.0 } else { raw }).round() / 255.0)
        } else {
            None
        };
        return Some(Color {
            rgb: format!("#{red:02x}{green:02x}{blue:02x}"),
            alpha,
        });
    }
    let body = lower
        .strip_prefix('#')
        .or_else(|| lower.strip_prefix("0x"))
        .unwrap_or(&lower);
    if !body.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let expanded = match body.len() {
        3 | 4 => body.chars().flat_map(|ch| [ch, ch]).collect::<String>(),
        6 | 8 => body.into(),
        _ => return None,
    };
    Some(Color {
        rgb: format!("#{}", &expanded[..6]),
        alpha: if expanded.len() == 8 {
            Some(u8::from_str_radix(&expanded[6..], 16).ok()? as f64 / 255.0)
        } else {
            None
        },
    })
}

fn canonical_color(value: &str) -> bool {
    value.len() == 7
        && value.starts_with('#')
        && value.as_bytes()[1..]
            .iter()
            .all(|byte| byte.is_ascii_hexdigit())
}

fn safe_text(value: &str, max_bytes: usize) -> bool {
    !value.trim().is_empty()
        && value.len() <= max_bytes
        && !value
            .chars()
            .any(|ch| ch.is_control() || matches!(ch, '\u{2028}' | '\u{2029}'))
}

fn in_range(value: f64, min: f64, max: f64) -> bool {
    value.is_finite() && value >= min && value <= max
}

/// Keep notes bounded and free of config values (which may be private).
#[derive(Default)]
struct Notes(BTreeSet<String>);
impl Notes {
    fn add(&mut self, key: &str) {
        if self.0.len() < 255 {
            let key: String = key
                .chars()
                .filter(|ch| !ch.is_control() && !matches!(ch, '\u{2028}' | '\u{2029}'))
                .take(60)
                .collect();
            if !key.trim().is_empty() {
                self.0.insert(key);
            }
        } else {
            self.0.insert("Additional unsupported settings".into());
        }
    }
    fn finish(self) -> Vec<String> {
        self.0.into_iter().collect()
    }
}

fn ghostty_assignment(raw: &str) -> Option<(String, &str)> {
    let line = raw.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (key, value) = line.split_once('=')?;
    let key = key.trim().to_ascii_lowercase();
    let value = value.trim();
    let value = value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .unwrap_or(value);
    Some((key, value))
}

fn parse_ghostty_variants(text: &str, name: &str) -> Result<Vec<TerminalTheme>> {
    let reference = text
        .lines()
        .rev()
        .filter_map(ghostty_assignment)
        .find_map(|(key, value)| (key == "theme").then_some(value));
    let references = if let Some(reference) = reference {
        let pieces = reference.split(',').map(str::trim).collect::<Vec<_>>();
        if pieces
            .iter()
            .any(|part| part.starts_with("light:") || part.starts_with("dark:"))
        {
            if pieces.len() != 2
                || !pieces.iter().any(|part| part.starts_with("light:"))
                || !pieces.iter().any(|part| part.starts_with("dark:"))
            {
                bail!("A dual theme reference must contain one light and one dark theme name");
            }
            pieces
                .iter()
                .filter_map(|part| {
                    part.strip_prefix("light:")
                        .or_else(|| part.strip_prefix("dark:"))
                })
                .collect()
        } else {
            vec![reference]
        }
    } else {
        vec![]
    };
    if references.is_empty() {
        return Ok(vec![parse_ghostty(text, name, None, false)?]);
    }
    references
        .into_iter()
        .map(|reference| parse_ghostty(text, name, resolve_bundled(reference), true))
        .collect()
}

fn parse_ghostty(
    text: &str,
    name: &str,
    base: Option<TerminalTheme>,
    has_reference: bool,
) -> Result<TerminalTheme> {
    let resolved_reference = base.is_some();
    let mut theme = base.unwrap_or_else(|| {
        TerminalTheme::new(
            name,
            "ghostty",
            color("#000000").unwrap(),
            color("#ffffff").unwrap(),
        )
    });
    theme.source = "ghostty".into();
    let mut notes = Notes::default();
    if has_reference && !resolved_reference {
        notes.add("theme (name not found in bundled catalog)");
    }
    let mut background = false;
    let mut foreground = false;
    let mut explicit_opacity = None;
    for (key, value) in text.lines().filter_map(ghostty_assignment) {
        match key.as_str() {
            "background" | "foreground" | "cursor-color" | "selection-background" => {
                if let Some(parsed) = color(value) {
                    match key.as_str() {
                        "background" => {
                            theme.background = parsed.rgb;
                            theme.background_opacity = parsed.alpha;
                            background = true;
                        }
                        "foreground" => {
                            theme.foreground = parsed.rgb;
                            foreground = true;
                        }
                        "cursor-color" => theme.cursor = Some(parsed.rgb),
                        _ => theme.selection_background = Some(parsed.rgb),
                    }
                } else {
                    notes.add(&format!("{key} (invalid color)"));
                }
            }
            "palette" => {
                if let Some((index, value)) = value.split_once('=') {
                    if let (Ok(index), Some(parsed)) = (index.trim().parse::<u8>(), color(value)) {
                        if index <= 15 {
                            theme.palette.insert(index.to_string(), parsed.rgb);
                            continue;
                        }
                    }
                }
                notes.add("palette (invalid color or unsupported index)");
            }
            "font-family" => {
                if !safe_text(value, 256) {
                    notes.add("font-family (invalid value)");
                } else if theme.font_family.is_none() {
                    theme.font_family = Some(value.into());
                } else {
                    notes.add("font-family (additional fallback)");
                }
            }
            "font-size" | "background-opacity" => {
                let (min, max) = if key == "font-size" {
                    (6.0, 72.0)
                } else {
                    (0.0, 1.0)
                };
                match value.parse::<f64>().ok().filter(|n| in_range(*n, min, max)) {
                    Some(n) if key == "font-size" => theme.font_size = Some(n),
                    Some(n) => explicit_opacity = Some(n),
                    None => notes.add(&format!("{key} (out of range or invalid)")),
                }
            }
            "cursor-style" => match value {
                "block" | "bar" | "underline" => theme.cursor_style = Some(value.into()),
                _ => notes.add("cursor-style (unsupported value)"),
            },
            "cursor-style-blink" => match value {
                "true" => theme.cursor_blink = Some(true),
                "false" => theme.cursor_blink = Some(false),
                _ => notes.add("cursor-style-blink (invalid value)"),
            },
            "window-padding-x" | "window-padding-y" => {
                match value.parse::<u16>().ok().filter(|n| *n <= 64) {
                    Some(n) if key == "window-padding-x" => theme.padding_x = Some(n),
                    Some(n) => theme.padding_y = Some(n),
                    None => notes.add(&format!("{key} (out of range or invalid)")),
                }
            }
            "theme" => {}
            _ => notes.add(&key),
        }
    }
    if !background && !foreground && !resolved_reference {
        if has_reference {
            bail!("The named theme was not found in the bundled catalog and no usable literal colors were provided");
        }
        bail!("No usable literal background or foreground color found; choose a theme file with explicit colors");
    }
    if !background && !resolved_reference {
        notes.add("background (not stated; using black)");
    }
    if !foreground && !resolved_reference {
        notes.add("foreground (not stated; using white)");
    }
    if explicit_opacity.is_some() {
        theme.background_opacity = explicit_opacity;
    }
    theme.skipped = notes.finish();
    Ok(theme)
}

const ANSI: [&str; 8] = [
    "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
];

fn json_color(object: &Map<String, Value>, key: &str, notes: &mut Notes) -> Option<Color> {
    let value = object.get(key)?;
    let parsed = value.as_str().and_then(color);
    if parsed.is_none() {
        notes.add(&format!("{key} (invalid color)"));
    }
    parsed
}

fn json_name(object: &Map<String, Value>, fallback: &str, notes: &mut Notes) -> String {
    match object.get("name") {
        Some(Value::String(name)) if safe_text(name, 256) => name.clone(),
        Some(_) => {
            notes.add("name (invalid value; using filename)");
            fallback.into()
        }
        None => fallback.into(),
    }
}

fn parse_windows(root: &Map<String, Value>, name: &str) -> Result<Vec<TerminalTheme>> {
    let defaults = root
        .get("profiles")
        .and_then(|v| v.get("defaults"))
        .and_then(Value::as_object);
    let standalone = Value::Object(root.clone());
    let schemes = if let Some(value) = root.get("schemes") {
        value
            .as_array()
            .context("Windows Terminal schemes must be an array")?
            .as_slice()
    } else {
        std::slice::from_ref(&standalone)
    };
    if schemes.len() > MAX_THEMES {
        bail!("A theme file may contain at most 128 schemes");
    }
    let mut themes = vec![];
    let mut incomplete = 0;
    for scheme in schemes {
        let Some(scheme) = scheme.as_object() else {
            incomplete += 1;
            continue;
        };
        let mut notes = Notes::default();
        let (Some(background), Some(foreground)) = (
            json_color(scheme, "background", &mut notes),
            json_color(scheme, "foreground", &mut notes),
        ) else {
            incomplete += 1;
            continue;
        };
        let mut theme = TerminalTheme::new(
            &json_name(scheme, name, &mut notes),
            "windowsTerminal",
            background,
            foreground,
        );
        theme.cursor = json_color(scheme, "cursorColor", &mut notes).map(|c| c.rgb);
        theme.selection_background =
            json_color(scheme, "selectionBackground", &mut notes).map(|c| c.rgb);
        for (index, key) in ANSI.iter().enumerate() {
            if let Some(parsed) = json_color(scheme, key, &mut notes) {
                theme.palette.insert(index.to_string(), parsed.rgb);
            }
            let bright = format!("bright{}{}", key[..1].to_ascii_uppercase(), &key[1..]);
            if let Some(parsed) = json_color(scheme, &bright, &mut notes) {
                theme.palette.insert((index + 8).to_string(), parsed.rgb);
            }
        }
        for key in scheme.keys() {
            if !matches!(
                key.as_str(),
                "name" | "background" | "foreground" | "cursorColor" | "selectionBackground"
            ) && !ANSI.contains(&key.as_str())
                && !ANSI.iter().any(|ansi| {
                    key == &format!("bright{}{}", ansi[..1].to_ascii_uppercase(), &ansi[1..])
                })
            {
                notes.add(key);
            }
        }
        if let Some(defaults) = defaults {
            import_windows_defaults(defaults, &mut theme, &mut notes);
        }
        if root.contains_key("schemes") {
            for key in root
                .keys()
                .filter(|key| !matches!(key.as_str(), "schemes" | "profiles" | "$schema"))
            {
                notes.add(key);
            }
            if root
                .get("profiles")
                .and_then(|p| p.get("list"))
                .is_some_and(|p| p.as_array().is_some_and(|p| !p.is_empty()))
            {
                notes.add("profiles.list (profile-specific settings)");
            }
        }
        theme.skipped = notes.finish();
        themes.push(theme);
    }
    if incomplete > 0 {
        for theme in &mut themes {
            theme.skipped.truncate(255);
            theme
                .skipped
                .push(format!("{incomplete} incomplete schemes were not imported"));
        }
    }
    Ok(themes)
}

fn import_windows_defaults(
    defaults: &Map<String, Value>,
    theme: &mut TerminalTheme,
    notes: &mut Notes,
) {
    if let Some(value) = defaults.get("opacity") {
        // Current Windows Terminal opacity is a percentage, including 1 = 1%.
        if let Some(value) = value.as_f64().filter(|n| in_range(*n, 0.0, 100.0)) {
            theme.background_opacity = Some(value / 100.0);
            notes.add("opacity joined from profiles.defaults");
        } else {
            notes.add("profiles.defaults.opacity (invalid value)");
        }
    } else if let Some(value) = defaults.get("acrylicOpacity") {
        if let Some(value) = value.as_f64().filter(|n| in_range(*n, 0.0, 1.0)) {
            theme.background_opacity = Some(value);
            notes.add("acrylicOpacity joined from profiles.defaults");
        } else {
            notes.add("profiles.defaults.acrylicOpacity (invalid value)");
        }
    }
    if let Some(font) = defaults.get("font") {
        if let Some(font) = font.as_object() {
            if let Some(face) = font.get("face") {
                if let Some(face) = face.as_str().filter(|font| safe_text(font, 256)) {
                    theme.font_family = Some(face.into());
                    notes.add("font joined from profiles.defaults");
                } else {
                    notes.add("profiles.defaults.font.face (invalid value)");
                }
            }
            if let Some(size) = font.get("size") {
                if let Some(size) = size.as_f64().filter(|n| in_range(*n, 6.0, 72.0)) {
                    theme.font_size = Some(size);
                    notes.add("font joined from profiles.defaults");
                } else {
                    notes.add("profiles.defaults.font.size (invalid value)");
                }
            }
            for key in font
                .keys()
                .filter(|key| !matches!(key.as_str(), "face" | "size"))
            {
                notes.add(&format!("profiles.defaults.font.{key}"));
            }
        } else {
            notes.add("profiles.defaults.font (invalid value)");
        }
    }
    if let Some(value) = defaults.get("cursorShape") {
        theme.cursor_style = match value.as_str() {
            Some("bar") => Some("bar".into()),
            Some("vintage") | Some("underscore") => Some("underline".into()),
            Some("filledBox") => Some("block".into()),
            _ => {
                notes.add("profiles.defaults.cursorShape (unsupported value)");
                None
            }
        };
    }
    for key in defaults.keys().filter(|key| {
        !matches!(
            key.as_str(),
            "opacity" | "acrylicOpacity" | "font" | "cursorShape" | "colorScheme"
        )
    }) {
        notes.add(&format!("profiles.defaults.{key}"));
    }
}

fn parse_vscode(root: &Map<String, Value>, name: &str) -> Result<TerminalTheme> {
    let colors = root
        .get("colors")
        .or_else(|| root.get("workbench.colorCustomizations"));
    let colors = match colors {
        Some(colors) => colors
            .as_object()
            .context("VS Code colors must be an object")?,
        None => root,
    };
    let mut notes = Notes::default();
    let background = json_color(colors, "terminal.background", &mut notes)
        .or_else(|| {
            let value = json_color(colors, "editor.background", &mut notes);
            if value.is_some() {
                notes.add("background inferred from editor.background");
            }
            value
        })
        .context("No usable terminal or editor background found")?;
    let foreground = json_color(colors, "terminal.foreground", &mut notes)
        .or_else(|| {
            let value = json_color(colors, "editor.foreground", &mut notes);
            if value.is_some() {
                notes.add("foreground inferred from editor.foreground");
            }
            value
        })
        .context("No usable terminal or editor foreground found")?;
    let mut theme = TerminalTheme::new(
        &json_name(root, name, &mut notes),
        "vscode",
        background,
        foreground,
    );
    theme.cursor = json_color(colors, "terminalCursor.foreground", &mut notes).map(|c| c.rgb);
    theme.selection_background =
        json_color(colors, "terminal.selectionBackground", &mut notes).map(|c| c.rgb);
    let names = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
    ];
    for (index, name) in names.iter().enumerate() {
        for (prefix, offset) in [("terminal.ansi", 0), ("terminal.ansiBright", 8)] {
            if let Some(parsed) = json_color(colors, &format!("{prefix}{name}"), &mut notes) {
                theme
                    .palette
                    .insert((index + offset).to_string(), parsed.rgb);
            }
        }
    }
    if let Some(font) = root.get("terminal.integrated.fontFamily") {
        if let Some(font) = font.as_str().filter(|font| safe_text(font, 256)) {
            theme.font_family = Some(font.into());
        } else {
            notes.add("terminal.integrated.fontFamily (invalid value)");
        }
    }
    if let Some(size) = root.get("terminal.integrated.fontSize") {
        if let Some(size) = size.as_f64().filter(|n| in_range(*n, 6.0, 72.0)) {
            theme.font_size = Some(size);
        } else {
            notes.add("terminal.integrated.fontSize (invalid value)");
        }
    }
    if let Some(style) = root.get("terminal.integrated.cursorStyle") {
        if let Some(style) = style
            .as_str()
            .filter(|style| matches!(*style, "block" | "line" | "underline"))
        {
            theme.cursor_style = Some(if style == "line" { "bar" } else { style }.into());
        } else {
            notes.add("terminal.integrated.cursorStyle (unsupported value)");
        }
    }
    if let Some(blink) = root.get("terminal.integrated.cursorBlinking") {
        theme.cursor_blink = blink.as_bool();
        if theme.cursor_blink.is_none() {
            notes.add("terminal.integrated.cursorBlinking (invalid value)");
        }
    }
    for key in colors.keys() {
        if !matches!(
            key.as_str(),
            "terminal.background"
                | "terminal.foreground"
                | "editor.background"
                | "editor.foreground"
                | "terminalCursor.foreground"
                | "terminal.selectionBackground"
                | "name"
                | "$schema"
                | "terminal.integrated.fontFamily"
                | "terminal.integrated.fontSize"
                | "terminal.integrated.cursorStyle"
                | "terminal.integrated.cursorBlinking"
        ) && !names.iter().any(|name| {
            key == &format!("terminal.ansi{name}") || key == &format!("terminal.ansiBright{name}")
        }) {
            notes.add(key);
        }
    }
    if !std::ptr::eq(colors, root) {
        for key in root.keys().filter(|key| {
            !matches!(
                key.as_str(),
                "name"
                    | "$schema"
                    | "colors"
                    | "workbench.colorCustomizations"
                    | "terminal.integrated.fontFamily"
                    | "terminal.integrated.fontSize"
                    | "terminal.integrated.cursorStyle"
                    | "terminal.integrated.cursorBlinking"
            )
        }) {
            notes.add(key);
        }
    }
    theme.skipped = notes.finish();
    Ok(theme)
}

/// Remove comments and trailing commas outside strings. Replacing comments
/// with spaces preserves token boundaries and keeps diagnostics useful.
fn normalize_jsonc(text: &str) -> Result<Vec<u8>> {
    let source = text.as_bytes();
    let mut result = source.to_vec();
    let mut index = 0;
    let mut in_string = false;
    let mut escaped = false;
    while index < source.len() {
        let byte = source[index];
        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if byte == b'"' {
            in_string = true;
            index += 1;
        } else if byte == b'/' && source.get(index + 1) == Some(&b'/') {
            while index < source.len() && !matches!(source[index], b'\n' | b'\r') {
                result[index] = b' ';
                index += 1;
            }
        } else if byte == b'/' && source.get(index + 1) == Some(&b'*') {
            result[index] = b' ';
            result[index + 1] = b' ';
            index += 2;
            loop {
                if index + 1 >= source.len() {
                    bail!("Unterminated JSONC block comment");
                }
                if source[index] == b'*' && source[index + 1] == b'/' {
                    result[index] = b' ';
                    result[index + 1] = b' ';
                    index += 2;
                    break;
                }
                if !matches!(source[index], b'\n' | b'\r') {
                    result[index] = b' ';
                }
                index += 1;
            }
        } else {
            index += 1;
        }
    }
    in_string = false;
    escaped = false;
    for index in 0..result.len() {
        let byte = result[index];
        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
        } else if byte == b'"' {
            in_string = true;
        } else if byte == b','
            && result[index + 1..]
                .iter()
                .find(|byte| !byte.is_ascii_whitespace())
                .is_some_and(|byte| matches!(byte, b'}' | b']'))
        {
            result[index] = b' ';
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const GHOSTTY: &[u8] = include_bytes!("../../../../shared/fixtures/theme-ghostty.conf");
    const WINDOWS: &[u8] = include_bytes!("../../../../shared/fixtures/theme-windows.jsonc");
    const VSCODE: &[u8] = include_bytes!("../../../../shared/fixtures/theme-vscode.jsonc");

    #[test]
    fn native_catalog_resolves_names_before_literal_overrides_in_any_order() {
        let catalog = bundled_themes();
        assert!(catalog.len() >= 485);
        for theme in &catalog {
            theme.validate().unwrap();
        }
        let mocha = catalog
            .iter()
            .find(|theme| theme.name == "Catppuccin Mocha")
            .unwrap();
        assert_eq!(mocha.background, "#1e1e2e");
        assert_eq!(mocha.foreground, "#cdd6f4");
        assert_eq!(mocha.palette["13"], "#f2aede");
        let named = parse_theme(b"theme = catppuccin mocha", "config")
            .unwrap()
            .remove(0);
        assert_eq!(named.name, "Catppuccin Mocha");
        assert_eq!(named.palette, mocha.palette);
        for input in [
            "background=#112233\ntheme=Catppuccin Mocha\npalette=13=#aabbcc",
            "theme=Catppuccin Mocha\nbackground=#112233\npalette=13=#aabbcc",
        ] {
            let theme = parse_theme(input.as_bytes(), "config").unwrap().remove(0);
            assert_eq!(theme.background, "#112233");
            assert_eq!(theme.foreground, mocha.foreground);
            assert_eq!(theme.palette["13"], "#aabbcc");
            assert_eq!(theme.palette["5"], mocha.palette["5"]);
            assert!(theme.skipped.is_empty());
        }
        let dual = parse_theme(
            b"theme=light:Catppuccin Latte,dark:Catppuccin Mocha\nfont-size=16",
            "config",
        )
        .unwrap();
        assert_eq!(dual.len(), 2);
        assert_eq!(dual[0].background, "#eff1f5");
        assert_eq!(dual[1].background, "#1e1e2e");
        assert!(dual.iter().all(|theme| theme.font_size == Some(16.0)));
    }

    #[test]
    fn unresolved_theme_paths_are_never_read_and_literal_anchors_remain_usable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outside.conf");
        fs::write(&path, b"background=#112233\nforeground=#aabbcc").unwrap();
        let input = format!("theme={}\n", path.display());
        assert!(parse_theme(input.as_bytes(), "config").is_err());
        let input = format!("{input}background=#102030\nforeground=#e0e1e2");
        let theme = parse_theme(input.as_bytes(), "config").unwrap().remove(0);
        assert_eq!(theme.background, "#102030");
        assert!(theme
            .skipped
            .iter()
            .any(|note| note.contains("name not found")));
    }

    #[test]
    fn flat_vscode_settings_do_not_report_applied_typography_as_skipped() {
        let input = json!({"terminal.background":"#102030","terminal.foreground":"#e0e1e2","terminal.integrated.fontFamily":"Mono","terminal.integrated.cursorStyle":"line","terminal.integrated.cursorBlinking":true});
        let theme = parse_theme(input.to_string().as_bytes(), "settings.json")
            .unwrap()
            .remove(0);
        assert_eq!(theme.font_family.as_deref(), Some("Mono"));
        assert_eq!(theme.cursor_style.as_deref(), Some("bar"));
        assert_eq!(theme.cursor_blink, Some(true));
        assert!(theme.skipped.is_empty());
    }

    #[test]
    fn shared_formats_preserve_sparse_ansi_indices_and_supported_appearance() {
        for (bytes, file) in [
            (GHOSTTY, "config"),
            (WINDOWS, "settings.json"),
            (VSCODE, "theme.jsonc"),
        ] {
            let themes = parse_theme(bytes, file).unwrap();
            let theme = &themes[0];
            assert_eq!(theme.background, "#102030");
            assert_eq!(theme.foreground, "#e0e1e2");
            assert_eq!(theme.cursor.as_deref(), Some("#abcdef"));
            assert_eq!(theme.selection_background.as_deref(), Some("#304050"));
            assert_eq!(theme.palette.len(), 3);
            assert_eq!(theme.palette["1"], "#cc3322");
            assert_eq!(theme.palette["5"], "#aa44bb");
            assert_eq!(theme.palette["13"], "#ff88ee");
            assert_eq!(theme.font_family.as_deref(), Some("JetBrains Mono"));
            assert_eq!(theme.font_size, Some(15.0));
            assert_eq!(
                theme.background_opacity,
                Some(if file == "theme.jsonc" { 0.8 } else { 0.9 })
            );
            theme.validate().unwrap();
        }
        let theme = &parse_theme(GHOSTTY, "config").unwrap()[0];
        assert_eq!(theme.cursor_style.as_deref(), Some("bar"));
        assert_eq!(theme.cursor_blink, Some(false));
        assert_eq!(theme.padding_x, Some(16));
        assert_eq!(theme.padding_y, Some(10));
        for key in ["command", "config-file", "keybind"] {
            assert!(theme.skipped.contains(&key.into()));
        }
        assert_eq!(parse_theme(WINDOWS, "settings.json").unwrap().len(), 2);
    }

    #[test]
    fn windows_standalone_schemes_and_percentage_opacity_are_unambiguous() {
        let scheme =
            json!({"name":"Sample","background":"#123","foreground":"#def","purple":"#a0b0c0"});
        let parsed = parse_theme(scheme.to_string().as_bytes(), "scheme.json").unwrap();
        assert_eq!(parsed[0].palette["5"], "#a0b0c0");
        for (key, value, expected) in [
            ("opacity", 1.0, 0.01),
            ("opacity", 0.5, 0.005),
            ("acrylicOpacity", 0.5, 0.5),
        ] {
            let mut settings = json!({"schemes":[scheme.clone()],"profiles":{"defaults":{}}});
            settings["profiles"]["defaults"][key] = value.into();
            assert_eq!(
                parse_theme(settings.to_string().as_bytes(), "settings.json").unwrap()[0]
                    .background_opacity,
                Some(expected)
            );
        }
        let settings =
            json!({"schemes":[scheme],"profiles":{"defaults":{"opacity":80,"acrylicOpacity":0.2}}});
        assert_eq!(
            parse_theme(settings.to_string().as_bytes(), "settings.json").unwrap()[0]
                .background_opacity,
            Some(0.8)
        );
    }

    #[test]
    fn jsonc_preserves_strings_and_rejects_incomplete_comments_and_merged_tokens() {
        let source = r##"{
            // comment before strings with escaped quotes and comment markers
            "name":"Night // /* \" */ , }", "background":"#102030",
            "foreground":"#e0e1e2", /* multiline
            comment */ "red":"#cc3322", }"##;
        let theme = parse_theme(source.as_bytes(), "theme.json")
            .unwrap()
            .remove(0);
        assert_eq!(theme.name, "Night // /* \" */ , }");
        assert_eq!(theme.palette["1"], "#cc3322");
        assert!(parse_theme(b"{/* unfinished", "theme.jsonc").is_err());
        assert!(parse_theme(
            br##"{"background":"#123","foreground":"#456","value":1/*x*/2}"##,
            "theme.json"
        )
        .is_err());
        assert!(parse_theme(
            br##"{"background":"#123","foreground":"#456",,}"##,
            "theme.json"
        )
        .is_err());
    }

    #[test]
    fn invalid_optional_values_are_reported_without_discarding_valid_colors() {
        let source = "background = #112233\nforeground = #aabbcc\nfont-size = NaN\nbackground-opacity = 5\nwindow-padding-x = 900\ncursor-style-blink = maybe\npalette = 99=#ffffff\nfont-family = Bad\u{2028}Font\nbackground-image = /not/read.png\n";
        let theme = parse_theme(source.as_bytes(), "config").unwrap().remove(0);
        assert!(theme.font_size.is_none());
        assert!(theme.background_opacity.is_none());
        assert!(theme.padding_x.is_none());
        assert!(theme.font_family.is_none());
        assert!(theme.cursor_blink.is_none());
        assert!(theme.palette.is_empty());
        assert!(theme.skipped.iter().any(|key| key == "background-image"));
        assert!(theme.skipped.iter().any(|key| key.starts_with("font-size")));
        let windows = json!({"schemes":[{"background":"#123","foreground":"#def"}],"profiles":{"defaults":{"font":{"face":"Font\ncommand=ignored","size":900}}}});
        let theme = parse_theme(windows.to_string().as_bytes(), "settings.json")
            .unwrap()
            .remove(0);
        assert!(theme.font_family.is_none());
        assert!(theme.font_size.is_none());
        assert!(theme.skipped.iter().all(|key| !key.contains("ignored")));
    }

    #[test]
    fn no_usable_color_invalid_utf8_and_oversized_documents_fail_explicitly() {
        for source in [
            "",
            "font-size = 14",
            "theme = ImportedName",
            "background = #ＦＦ００ＡＡ",
            "command = ignored",
            "{\"schemes\":[]}",
        ] {
            assert!(
                parse_theme(source.as_bytes(), "config").is_err(),
                "{source}"
            );
        }
        assert!(parse_theme(&[0xff, 0xff], "theme").is_err());
        assert!(parse_theme(&vec![b'a'; MAX_THEME_BYTES + 1], "theme").is_err());
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("theme");
        fs::write(&file, vec![b'a'; MAX_THEME_BYTES + 1]).unwrap();
        assert!(read_theme_document(&file).is_err());
    }

    #[test]
    fn anchor_fallback_is_named_and_explicit_opacity_beats_alpha_in_any_order() {
        let theme = parse_theme(b"background-opacity=0.9\nbackground=#10203080", "config")
            .unwrap()
            .remove(0);
        assert_eq!(theme.background_opacity, Some(0.9));
        assert_eq!(theme.foreground, "#ffffff");
        assert!(theme
            .skipped
            .iter()
            .any(|key| key.starts_with("foreground (not stated")));
        let source =
            br##"{"colors":{"editor.background":"#10203080","editor.foreground":"#e0e1e2"}}"##;
        let theme = parse_theme(source, "theme.json").unwrap().remove(0);
        assert_eq!(theme.background_opacity, Some(128.0 / 255.0));
        assert!(theme
            .skipped
            .iter()
            .any(|key| key == "background inferred from editor.background"));
    }

    #[test]
    fn color_literals_are_normalized_without_accepting_non_ascii_or_non_finite_values() {
        for (input, expected) in [
            ("#abc", "#aabbcc"),
            ("0xAABBCC", "#aabbcc"),
            ("rgb(1,2,3)", "#010203"),
            ("purple", "#800080"),
        ] {
            assert_eq!(color(input).unwrap().rgb, expected);
        }
        assert_eq!(color("rgba(1,2,3,0.5)").unwrap().alpha, Some(128.0 / 255.0));
        for input in [
            "#ＦＦ００ＡＡ",
            "#12345",
            "#12zz34",
            "rgba(0,0,0,NaN)",
            "rgb(256,0,0)",
            "var(--background)",
        ] {
            assert!(color(input).is_none(), "{input}");
        }
    }

    #[test]
    fn malformed_or_future_settings_stay_on_disk_and_missing_settings_use_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("appearance.json");
        assert_eq!(
            AppearanceSettings::load(&path).unwrap(),
            AppearanceSettings::default()
        );
        for raw in [
            b"{broken".as_slice(),
            b"{\"version\":2}",
            b"{\"fontSize\":900}",
            b"{\"opacity\":-1}",
        ] {
            fs::write(&path, raw).unwrap();
            assert!(AppearanceSettings::load(&path).is_err());
            assert_eq!(fs::read(&path).unwrap(), raw);
        }
        assert_eq!(AppearanceSettings::decode(b"{}").unwrap().padding_x, 11);
    }

    #[test]
    fn appearance_round_trips_and_failed_saves_preserve_previous_settings() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("appearance.json");
        let settings = AppearanceSettings {
            theme: Some(parse_theme(GHOSTTY, "config").unwrap().remove(0)),
            font_size: 16.0,
            ..AppearanceSettings::default()
        };
        settings.save(&path).unwrap();
        assert_eq!(AppearanceSettings::load(&path).unwrap(), settings);
        let before = fs::read(&path).unwrap();
        let invalid = AppearanceSettings {
            font_size: f64::NAN,
            ..settings
        };
        assert!(invalid.save(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }

    #[test]
    fn history_undo_survives_restart_and_failed_commit_does_not_mutate_memory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.json");
        let mut history = AppearanceHistory::load(&path).unwrap();
        let initial = history.current.clone();
        let changed = AppearanceSettings {
            font_size: 18.0,
            ..initial.clone()
        };
        history.commit(changed.clone(), &path).unwrap();
        let mut restored = AppearanceHistory::load(&path).unwrap();
        assert_eq!(restored.current, changed);
        assert!(restored.revert(&path).unwrap());
        assert_eq!(AppearanceHistory::load(&path).unwrap().current, initial);
        assert!(restored.revert(&path).unwrap());
        assert_eq!(restored.current, changed);
        let old_history = restored.clone();
        let blocked = dir.path().join("file");
        fs::write(&blocked, b"not a directory").unwrap();
        assert!(restored
            .commit(initial.clone(), &blocked.join("appearance.json"))
            .is_err());
        assert_eq!(restored, old_history);
        assert!(restored.revert(&blocked.join("appearance.json")).is_err());
        assert_eq!(restored, old_history);
        restored.commit(changed, &path).unwrap();
        assert_eq!(restored.previous, Some(initial));
    }

    #[test]
    fn malformed_history_is_not_silently_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.json");
        for raw in [
            b"{}".as_slice(),
            b"{\"current\":{\"version\":2}}",
            b"{\"current\":{},\"previous\":{\"opacity\":5}}",
        ] {
            fs::write(&path, raw).unwrap();
            assert!(AppearanceHistory::load(&path).is_err());
            assert_eq!(fs::read(&path).unwrap(), raw);
        }
    }

    #[test]
    fn embedded_image_settings_reject_paths_urls_svg_and_mismatched_content() {
        for image in [
            "/tmp/photo.png",
            "https://example.invalid/image.png",
            "data:image/svg+xml;base64,PHN2Zz4=",
            "data:image/png;base64,YWJjZA==",
            "data:image/jpeg;base64,not base64",
        ] {
            let settings = AppearanceSettings {
                background_image: Some(image.into()),
                ..AppearanceSettings::default()
            };
            assert!(settings.validate().is_err());
        }
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXxkAAAAASUVORK5CYII=";
        let settings = AppearanceSettings {
            background_image: Some(png.into()),
            ..AppearanceSettings::default()
        };
        settings.validate().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("image.json");
        settings.save(&path).unwrap();
        assert_eq!(AppearanceSettings::load(&path).unwrap(), settings);
    }

    #[test]
    fn image_dimensions_are_bounded_before_a_renderer_decompresses_them() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&9000u32.to_be_bytes());
        png.extend_from_slice(&1u32.to_be_bytes());
        png.resize(33, 0);
        let data = format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(&png)
        );
        assert!(validate_image(&data).is_err());
        // SOF2 (progressive JPEG) carries dimensions in the same marker slots.
        let mut jpeg = vec![
            0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc2, 0, 8, 8, 0, 10, 0, 20, 0, 0xff, 0xd9,
        ];
        assert_eq!(jpeg_dimensions(&jpeg).unwrap(), (20, 10));
        let data = format!(
            "data:image/jpeg;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(&jpeg)
        );
        validate_image(&data).unwrap();
        jpeg[15] = 0xff;
        let data = format!(
            "data:image/jpeg;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(&jpeg)
        );
        assert!(validate_image(&data).is_err());
        for bad in [
            vec![0xff, 0xd8, 0xff, 0xe0, 0, 0, 0xff, 0xd9],
            vec![0xff, 0xd8, 0xff, 0xff, 0xd9],
            vec![0xff, 0xd8, 0xff, 0xc0, 0, 100, 0xff, 0xd9],
        ] {
            assert!(jpeg_dimensions(&bad).is_err());
        }
    }

    #[test]
    fn renderer_validation_rejects_uncanonical_palette_keys_and_unusable_values() {
        let theme = parse_theme(GHOSTTY, "config").unwrap().remove(0);
        for key in ["16", "01", "-1", "palette"] {
            let mut invalid = theme.clone();
            invalid.palette.insert(key.into(), "#ffffff".into());
            assert!(invalid.validate().is_err());
        }
        let mut invalid = theme.clone();
        invalid.background = "red".into();
        assert!(invalid.validate().is_err());
        let mut invalid = theme;
        invalid.cursor_style = Some("anything".into());
        assert!(invalid.validate().is_err());
    }
}
