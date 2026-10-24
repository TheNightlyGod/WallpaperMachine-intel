// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    collections::BTreeMap,
    fs,
    path::{Component, Path, PathBuf},
};

use serde_json::Value;

mod r#override;
mod resolver;
mod scene;

pub use r#override::{FlatScenePropertyOverride, ScenePropertyOverrideError, SerdeValudeExt};
pub use resolver::{SceneSourcePaths, SceneSourceResolution};
pub use scene::{
    ScalingMode, SceneDesc, SceneDescBuilder, SceneDescSliceExt, SceneFile, SceneFraming,
    SceneHandle, SceneIr, SceneRenderTargetIr, SceneResult, SceneTemplate,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum WallpaperProjectType {
    Scene,
    Video,
    Web,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectManifest {
    project_type: WallpaperProjectType,
    file: String,
    workshop_id: String,
    dependencies: Vec<String>,
}

fn invalid(message: impl Into<String>) -> crate::EngineError {
    crate::EngineError::InvalidInput(message.into())
}

fn parse_json_text(json: &str, what: &str) -> Result<Value, crate::EngineError> {
    serde_json::from_str(json).map_err(|error| invalid(format!("failed to parse {what}: {error}")))
}

impl ProjectManifest {
    /// # Errors
    ///
    /// Returns `InvalidInput` when the file cannot be read or is not a valid manifest.
    pub fn load<T: AsRef<Path>>(path: T) -> Result<Self, crate::EngineError> {
        let text = fs::read_to_string(path.as_ref())
            .map_err(|error| invalid(format!("failed to read project manifest: {error}")))?;
        Self::parse(text)
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for invalid JSON, a root that is not an object, or a
    /// `type` or `file` that is present and not a string.
    pub fn parse<T: AsRef<str>>(json: T) -> Result<Self, crate::EngineError> {
        let root = parse_json_text(json.as_ref(), "project manifest")?;
        let Some(object) = root.as_object() else {
            return Err(invalid("project manifest root must be an object"));
        };

        let project_type = match object.get("type") {
            None => WallpaperProjectType::Unknown,
            Some(Value::String(text)) => WallpaperProjectType::from(text.as_str()),
            Some(_) => return Err(invalid("project manifest `type` must be a string")),
        };
        let file = match object.get("file") {
            None => String::new(),
            Some(Value::String(text)) => text.clone(),
            Some(_) => return Err(invalid("project manifest `file` must be a string")),
        };
        let workshop_id = match object.get("workshopid") {
            Some(Value::String(text)) => text.clone(),
            Some(Value::Number(number)) => number.to_string(),
            _ => String::new(),
        };
        let dependencies = match object.get("dependencies") {
            Some(Value::Array(items)) => items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        };

        Ok(Self {
            project_type,
            file,
            workshop_id,
            dependencies,
        })
    }

    #[must_use]
    pub fn project_type(&self) -> WallpaperProjectType {
        self.project_type
    }

    #[must_use]
    pub fn file(&self) -> &str {
        &self.file
    }

    #[must_use]
    pub fn workshop_id(&self) -> &str {
        &self.workshop_id
    }

    #[must_use]
    pub fn dependency_paths<T: AsRef<Path>>(&self, project_root: T) -> Vec<PathBuf> {
        let root = project_root.as_ref();
        self.dependencies
            .iter()
            .map(|dependency| root.join(dependency))
            .collect()
    }

    pub(super) fn assign_project_type(&mut self, project_type: WallpaperProjectType) {
        self.project_type = project_type;
    }

    pub(super) fn assign_file(&mut self, file: String) {
        self.file = file;
    }

    pub(super) fn assign_workshop_id(&mut self, workshop_id: String) {
        self.workshop_id = workshop_id;
    }
}

impl From<&str> for WallpaperProjectType {
    fn from(value: &str) -> Self {
        if value.eq_ignore_ascii_case("scene") {
            Self::Scene
        } else if value.eq_ignore_ascii_case("video") {
            Self::Video
        } else if value.eq_ignore_ascii_case("web") {
            Self::Web
        } else {
            Self::Unknown
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectProperties {
    values: BTreeMap<String, RuntimeScalarValue>,
}

impl ProjectProperties {
    /// # Errors
    ///
    /// Returns `InvalidInput` when the file cannot be read or is not valid.
    pub fn load<T: AsRef<Path>>(path: T) -> Result<Self, crate::EngineError> {
        let text = fs::read_to_string(path.as_ref())
            .map_err(|error| invalid(format!("failed to read project properties: {error}")))?;
        Self::parse(text)
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for invalid JSON or a missing `general.properties` object.
    pub fn parse<T: AsRef<str>>(json: T) -> Result<Self, crate::EngineError> {
        let root = parse_json_text(json.as_ref(), "project properties")?;
        let declared = root
            .get("general")
            .and_then(Value::as_object)
            .and_then(|general| general.get("properties"))
            .and_then(Value::as_object)
            .ok_or_else(|| invalid("project properties must hold a `general.properties` object"))?;

        let values = declared
            .iter()
            .filter_map(|(name, entry)| {
                let value = entry.as_object()?.get("value")?;
                Some((name.clone(), RuntimeScalarValue::from_json(value)))
            })
            .collect();
        Ok(Self { values })
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for invalid JSON or a root that is not an object.
    pub fn apply_override<T: AsRef<str>>(&self, json: T) -> Result<Self, crate::EngineError> {
        let root = parse_json_text(json.as_ref(), "property override")?;
        let Some(replacements) = root.as_object() else {
            return Err(invalid("property override root must be an object"));
        };

        let mut values = self.values.clone();
        for (name, value) in replacements {
            values.insert(name.clone(), RuntimeScalarValue::from_json(value));
        }
        Ok(Self { values })
    }

    #[must_use]
    pub fn get(&self, name: &str) -> Option<&RuntimeScalarValue> {
        self.values.get(name)
    }
}

/// A property value kept together with its three readings.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeScalarValue {
    kind: RuntimeScalarKind,
    truth: bool,
    number: f64,
    text: String,
}

impl RuntimeScalarValue {
    #[must_use]
    pub fn bool(value: bool) -> Self {
        Self {
            kind: RuntimeScalarKind::Bool,
            truth: value,
            number: if value { 1.0 } else { 0.0 },
            text: if value { "true" } else { "false" }.to_owned(),
        }
    }

    #[must_use]
    pub fn float(value: f64) -> Self {
        Self {
            kind: RuntimeScalarKind::Float,
            truth: value != 0.0,
            number: value,
            text: value.to_string(),
        }
    }

    #[must_use]
    pub fn string(value: impl Into<String>) -> Self {
        let text: String = value.into();
        Self {
            kind: RuntimeScalarKind::String,
            truth: text.eq_ignore_ascii_case("true") || text == "1",
            number: text.parse::<f64>().unwrap_or(0.0),
            text,
        }
    }

    fn from_json(value: &Value) -> Self {
        match value {
            Value::Bool(flag) => Self::bool(*flag),
            Value::Number(number) => Self::float(number.as_f64().unwrap_or(0.0)),
            Value::String(text) => Self::string(text.as_str()),
            Value::Null => Self::string(String::new()),
            other => Self::string(other.to_string()),
        }
    }

    #[must_use]
    pub fn kind(&self) -> RuntimeScalarKind {
        self.kind
    }

    #[must_use]
    pub fn as_bool(&self) -> bool {
        self.truth
    }

    #[must_use]
    pub fn as_float(&self) -> f64 {
        self.number
    }

    #[must_use]
    pub fn as_string(&self) -> &str {
        &self.text
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RuntimeScalarKind {
    Bool,
    Float,
    String,
}

/// # Errors
///
/// Returns `InvalidInput` unless `path` is a non-empty relative path of ordinary components.
pub fn validate_relative_normal_path(path: &Path, label: &str) -> Result<(), crate::EngineError> {
    if path.as_os_str().is_empty() {
        return Err(invalid(format!("{label} must not be empty")));
    }
    let acceptable = path.components().all(|component| match component {
        Component::Normal(name) => !name.to_string_lossy().contains('\\'),
        _ => false,
    });
    if acceptable {
        Ok(())
    } else {
        Err(invalid(format!(
            "{label} must be a relative path with normal components"
        )))
    }
}
