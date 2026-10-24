// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    collections::BTreeMap,
    fmt::{Display, Formatter},
};

use serde_json::Value;

pub type FlatScenePropertyOverride = BTreeMap<String, Value>;

#[derive(Debug)]
pub enum ScenePropertyOverrideError {
    InvalidJson(serde_json::Error),
    RootMustBeObject,
    EmptyPath,
    UnsupportedLeafType(String),
}

impl Display for ScenePropertyOverrideError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidJson(error) => Display::fmt(error, f),
            Self::RootMustBeObject => f.write_str("override root must be a JSON object"),
            Self::EmptyPath => f.write_str("override path must not be empty"),
            Self::UnsupportedLeafType(path) => {
                write!(
                    f,
                    "override leaf must be bool, number, string, or null: {path}"
                )
            }
        }
    }
}

impl std::error::Error for ScenePropertyOverrideError {}

impl From<ScenePropertyOverrideError> for crate::EngineError {
    fn from(value: ScenePropertyOverrideError) -> Self {
        crate::EngineError::InvalidInput(value.to_string())
    }
}

pub trait SerdeValudeExt {
    /// # Errors
    ///
    /// Returns an error when the root value is not an object, a generated path
    /// is empty, or a leaf value uses an unsupported JSON type.
    fn flatten(self) -> Result<BTreeMap<String, Value>, ScenePropertyOverrideError>;
}

impl SerdeValudeExt for Value {
    fn flatten(self) -> Result<BTreeMap<String, Value>, ScenePropertyOverrideError> {
        let Value::Object(root) = self else {
            return Err(ScenePropertyOverrideError::RootMustBeObject);
        };
        let mut flat = BTreeMap::new();
        flatten_object(root, None, &mut flat)?;
        Ok(flat)
    }
}

/// Walks one object level. Keys are visited in sorted order so that two paths
/// reaching the same flat key always resolve the same way (the later key wins),
/// whatever order the JSON map keeps.
fn flatten_object(
    object: serde_json::Map<String, Value>,
    prefix: Option<&str>,
    out: &mut BTreeMap<String, Value>,
) -> Result<(), ScenePropertyOverrideError> {
    let mut entries: Vec<(String, Value)> = object.into_iter().collect();
    entries.sort_by(|left, right| left.0.cmp(&right.0));

    for (key, value) in entries {
        // A parent key that is itself empty still counts as a path segment.
        let path = match prefix {
            None => key,
            Some(parent) => format!("{parent}_{key}"),
        };
        match value {
            Value::Object(inner) => flatten_object(inner, Some(&path), out)?,
            Value::Array(_) => return Err(ScenePropertyOverrideError::UnsupportedLeafType(path)),
            leaf => {
                if path.is_empty() {
                    return Err(ScenePropertyOverrideError::EmptyPath);
                }
                let leaf = if leaf.is_null() {
                    Value::String(String::new())
                } else {
                    leaf
                };
                out.insert(path, leaf);
            }
        }
    }
    Ok(())
}
