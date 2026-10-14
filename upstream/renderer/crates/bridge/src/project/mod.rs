//! Extended project.json parser.

pub mod condition;
pub mod localization;
pub mod manifest;
pub mod overrides;
pub mod property;

pub use condition::{CmpOp, Condition, Literal};
pub use localization::ProjectLocalization;
pub use manifest::{ProjectModel, ProjectProperty};
pub use overrides::{OverrideMapExt, scene_property_override_json};
pub use property::{
    ComboOption, DirectoryMode, FileFilter, FileMedia, PropertyKind, PropertyMetadata,
    PropertyValue,
};
