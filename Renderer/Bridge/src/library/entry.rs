use std::path::Path;
use std::time::SystemTime;

use wallpaper_core::project::WallpaperProjectType;

use crate::project::ProjectModel;

#[derive(Clone, Debug, PartialEq)]
pub struct WallpaperEntry {
    pub workshop_id: String,
    pub title: String,
    pub project_type: WallpaperProjectType,
    pub preview_path: Option<std::path::PathBuf>,
    pub preview_mtime: Option<SystemTime>,
    pub project_json_mtime: Option<SystemTime>,
    pub supported: bool,
}

impl WallpaperEntry {
    #[must_use]
    pub fn from_model(model: &ProjectModel) -> Self {
        Self {
            workshop_id: model.workshop_id.clone(),
            title: model.title.clone(),
            project_type: model.project_type,
            preview_path: model.preview_file.clone(),
            preview_mtime: model.preview_file.as_deref().and_then(modified_time),
            project_json_mtime: None,
            supported: matches!(
                model.project_type,
                WallpaperProjectType::Scene
                    | WallpaperProjectType::Video
                    | WallpaperProjectType::Web
            ),
        }
    }
}

pub(super) fn modified_time(path: &Path) -> Option<SystemTime> {
    let metadata = std::fs::metadata(path);
    #[cfg(test)]
    let metadata = super::scanner::test_controls::metadata(path, metadata);
    let modified = metadata.ok()?.modified();
    #[cfg(test)]
    let modified = super::scanner::test_controls::modified(path, modified);
    modified.ok()
}
