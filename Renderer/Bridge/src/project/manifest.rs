use super::{
    ComboOption, Condition, DirectoryMode, FileFilter, FileMedia, ProjectLocalization,
    PropertyKind, PropertyMetadata, PropertyValue,
};
use crate::{BridgeError, BridgeErrorKind};
use serde_json::{Map, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
};
use wallpaper_core::project::WallpaperProjectType;

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectModel {
    pub workshop_id: String,
    pub title: String,
    pub description_html: String,
    pub project_type: WallpaperProjectType,
    pub preview_file: Option<PathBuf>,
    pub entry_file: Option<String>,
    pub properties: Vec<ProjectProperty>,
    pub localization: Arc<ProjectLocalization>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectProperty {
    pub id: String,
    pub kind: PropertyKind,
    pub default_value: PropertyValue,
    pub default_is_host_supplied: bool,
    pub label_html: String,
    pub order: f64,
    pub index: i64,
    pub condition: Option<String>,
    pub metadata: PropertyMetadata,
}

fn project_error(message: String) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Project,
        message,
    }
}

impl ProjectModel {
    pub fn parse(workshop_id: &str, json: &str) -> Result<Self, BridgeError> {
        let root: Value = serde_json::from_str(json)
            .map_err(|error| project_error(format!("invalid project JSON: {error}")))?;
        let root = root
            .as_object()
            .ok_or_else(|| project_error("project root must be an object".to_owned()))?;
        let project_type = match root.get("type").and_then(Value::as_str) {
            Some(value) if value.eq_ignore_ascii_case("scene") => WallpaperProjectType::Scene,
            Some(value) if value.eq_ignore_ascii_case("video") => WallpaperProjectType::Video,
            Some(value) if value.eq_ignore_ascii_case("web") => WallpaperProjectType::Web,
            _ => WallpaperProjectType::Unknown,
        };
        let general = root.get("general").and_then(Value::as_object);
        let mut properties = Vec::new();
        if let Some(entries) = general
            .and_then(|general| general.get("properties"))
            .and_then(Value::as_object)
        {
            properties.reserve(entries.len());
            for (id, entry) in entries {
                if let Some(entry) = entry.as_object() {
                    properties.push(parse_property(id, entry));
                }
            }
        }
        properties.sort_by(|left, right| {
            left.order
                .total_cmp(&right.order)
                .then_with(|| left.index.cmp(&right.index))
        });
        Ok(Self {
            workshop_id: workshop_id.to_owned(),
            title: root
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            description_html: root
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            project_type,
            preview_file: root
                .get("preview")
                .and_then(Value::as_str)
                .map(PathBuf::from),
            entry_file: root
                .get("file")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            properties,
            localization: Arc::new(
                general
                    .map(ProjectLocalization::from_general)
                    .unwrap_or_default(),
            ),
        })
    }

    pub fn load<P: AsRef<Path>>(workshop_id: &str, project_json: P) -> Result<Self, BridgeError> {
        let path = project_json.as_ref();
        let json = std::fs::read_to_string(path).map_err(|error| {
            project_error(format!("cannot read project {}: {error}", path.display()))
        })?;
        let mut model = Self::parse(workshop_id, &json).map_err(|error| {
            project_error(format!("project {}: {}", path.display(), error.message()))
        })?;
        if let Some(preview) = model.preview_file.as_mut() {
            let parent = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
                .unwrap_or_else(|| Path::new("."));
            *preview = parent.join(&*preview);
        }
        Ok(model)
    }

    pub fn unreadable_condition_count(&self) -> usize {
        self.properties
            .iter()
            .filter(|property| {
                property.condition.as_deref().is_some_and(|condition| {
                    !condition.trim().is_empty() && Condition::parse(condition).is_err()
                })
            })
            .count()
    }
}

impl ProjectProperty {
    pub fn default_value(&self) -> PropertyValue {
        match self.kind {
            PropertyKind::Combo
            | PropertyKind::TextInput
            | PropertyKind::File
            | PropertyKind::Directory
            | PropertyKind::Texture => {
                PropertyValue::String(self.default_value.to_property_string())
            }
            _ => self.default_value.clone(),
        }
    }

    pub fn value_from_json(&self, raw: &Value) -> PropertyValue {
        match self.kind {
            PropertyKind::Slider => {
                let number = match raw {
                    Value::Number(number) => number.as_f64(),
                    Value::String(text) => text.parse::<f64>().ok(),
                    _ => None,
                };
                number
                    .filter(|number| number.is_finite())
                    .map(PropertyValue::Number)
                    .unwrap_or_else(|| self.default_value())
            }
            PropertyKind::Bool => {
                let value = match raw {
                    Value::Bool(value) => Some(*value),
                    Value::String(value) if value.eq_ignore_ascii_case("true") || value == "1" => {
                        Some(true)
                    }
                    Value::String(value) if value.eq_ignore_ascii_case("false") || value == "0" => {
                        Some(false)
                    }
                    _ => None,
                };
                value
                    .map(PropertyValue::Bool)
                    .unwrap_or_else(|| self.default_value())
            }
            PropertyKind::Combo
            | PropertyKind::TextInput
            | PropertyKind::File
            | PropertyKind::Directory
            | PropertyKind::Texture => {
                PropertyValue::String(PropertyValue::json_scalar_to_string(raw))
            }
            PropertyKind::Color => match PropertyValue::from_json(raw) {
                color @ PropertyValue::ColorRgb(..) => color,
                _ => self.default_value(),
            },
            _ => PropertyValue::from_json(raw),
        }
    }

    pub fn effective_value(&self, values: &BTreeMap<String, PropertyValue>) -> PropertyValue {
        values
            .get(&self.id)
            .cloned()
            .unwrap_or_else(|| self.default_value())
    }

    pub fn value_is_default(&self, value: &PropertyValue) -> bool {
        match self.kind {
            PropertyKind::Combo
            | PropertyKind::TextInput
            | PropertyKind::File
            | PropertyKind::Directory
            | PropertyKind::Texture => {
                let PropertyValue::String(value) = value else {
                    return false;
                };
                match &self.default_value {
                    PropertyValue::String(default) => value == default,
                    PropertyValue::Null => value.is_empty(),
                    PropertyValue::Bool(true) => value == "true",
                    PropertyValue::Bool(false) => value == "false",
                    default => *value == default.to_property_string(),
                }
            }
            _ => value.matches_with_override_semantics(&self.default_value),
        }
    }

    pub fn web_value(&self, value: &PropertyValue) -> Value {
        if let (PropertyMetadata::Combo { options }, PropertyValue::String(selection)) =
            (&self.metadata, value)
        {
            if let Some(option) = options.iter().find(|option| option.value == *selection) {
                return option.json_value.clone();
            }
            if self.value_is_default(value) {
                return self.default_value.to_json();
            }
        }
        value.to_json()
    }
}

fn parse_property(id: &str, entry: &Map<String, Value>) -> ProjectProperty {
    let raw_type = entry
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let (kind, metadata) = match raw_type.to_ascii_lowercase().as_str() {
        "slider" => (
            PropertyKind::Slider,
            PropertyMetadata::Slider {
                min: number(entry, "min", 0.0),
                max: number(entry, "max", 1.0),
                step: number(entry, "step", 0.01),
                precision: entry
                    .get("precision")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .unwrap_or(2),
                fraction: entry
                    .get("fraction")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            },
        ),
        "combo" => {
            let options = entry
                .get("options")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|value| {
                            let value = value.as_object()?;
                            let json_value = value.get("value").cloned().unwrap_or(Value::Null);
                            Some(ComboOption {
                                label: value
                                    .get("label")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned(),
                                value: PropertyValue::json_scalar_to_string(&json_value),
                                json_value,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            (PropertyKind::Combo, PropertyMetadata::Combo { options })
        }
        "usershortcut" => (
            PropertyKind::Combo,
            PropertyMetadata::Combo {
                options: [
                    ("No action", ""),
                    ("Play / Pause", "media:playpause"),
                    ("Next Track", "media:next"),
                    ("Previous Track", "media:previous"),
                ]
                .into_iter()
                .map(|(label, value)| ComboOption {
                    label: label.to_owned(),
                    value: value.to_owned(),
                    json_value: Value::String(value.to_owned()),
                })
                .collect(),
            },
        ),
        "bool" => (PropertyKind::Bool, PropertyMetadata::Bool),
        "color" => (PropertyKind::Color, PropertyMetadata::Color),
        "textinput" => (PropertyKind::TextInput, PropertyMetadata::TextInput),
        "text" => (PropertyKind::Text, PropertyMetadata::Text),
        "group" => (PropertyKind::Group, PropertyMetadata::Group),
        "file" => (
            PropertyKind::File,
            PropertyMetadata::File {
                filter: file_filter(entry),
            },
        ),
        "directory" => (
            PropertyKind::Directory,
            PropertyMetadata::Directory {
                filter: file_filter(entry),
                mode: if entry
                    .get("mode")
                    .and_then(Value::as_str)
                    .is_some_and(|mode| mode.trim().eq_ignore_ascii_case("fetchall"))
                {
                    DirectoryMode::FetchAll
                } else {
                    DirectoryMode::OnDemand
                },
            },
        ),
        "texture" | "scenetexture" => (PropertyKind::Texture, PropertyMetadata::Texture),
        _ => (
            PropertyKind::Unknown(raw_type.to_owned()),
            PropertyMetadata::Unknown,
        ),
    };
    let mut host_supplied = false;
    let default = if raw_type.eq_ignore_ascii_case("usershortcut") {
        let authored = entry
            .get("value")
            .map(PropertyValue::json_scalar_to_string)
            .unwrap_or_default();
        if authored.is_empty() {
            let lower = id.to_ascii_lowercase();
            let suggestion = [
                ("playpause", "media:playpause"),
                ("previous", "media:previous"),
                ("prev", "media:previous"),
                ("next", "media:next"),
                ("pause", "media:playpause"),
                ("play", "media:playpause"),
            ]
            .into_iter()
            .find_map(|(pattern, action)| lower.contains(pattern).then_some(action))
            .unwrap_or_default();
            host_supplied = !suggestion.is_empty();
            PropertyValue::String(suggestion.to_owned())
        } else {
            PropertyValue::String(authored)
        }
    } else {
        match (&kind, entry.get("value")) {
            (PropertyKind::File | PropertyKind::Directory | PropertyKind::Texture, value) => {
                PropertyValue::String(
                    value
                        .map(PropertyValue::json_scalar_to_string)
                        .unwrap_or_default(),
                )
            }
            (PropertyKind::Combo, Some(Value::String(value))) => {
                PropertyValue::String(value.clone())
            }
            (_, Some(value)) => PropertyValue::from_json(value),
            (_, None) => PropertyValue::Null,
        }
    };
    ProjectProperty {
        id: id.to_owned(),
        kind,
        metadata,
        default_value: default,
        default_is_host_supplied: host_supplied,
        label_html: entry
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        order: number(entry, "order", 0.0),
        index: entry.get("index").and_then(Value::as_i64).unwrap_or(0),
        condition: entry
            .get("condition")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

fn number(entry: &Map<String, Value>, key: &str, fallback: f64) -> f64 {
    entry.get(key).and_then(Value::as_f64).unwrap_or(fallback)
}

fn file_filter(entry: &Map<String, Value>) -> FileFilter {
    let raw = entry
        .iter()
        .find(|(key, _)| {
            key.eq_ignore_ascii_case("fileType") || key.eq_ignore_ascii_case("file_type")
        })
        .and_then(|(_, value)| value.as_str());
    FileFilter {
        media: if raw.is_some_and(|raw| raw.trim().eq_ignore_ascii_case("video")) {
            FileMedia::Video
        } else {
            FileMedia::Image
        },
        raw: raw.map(str::to_owned),
    }
}
