use wallpaper_core::project::WallpaperProjectType;

use crate::config::FilterCfg;

use super::entry::WallpaperEntry;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TypeFilter {
    pub scene: bool,
    pub video: bool,
    pub web: bool,
    pub unknown: bool,
}

impl Default for TypeFilter {
    fn default() -> Self {
        Self {
            scene: true,
            video: true,
            web: true,
            unknown: true,
        }
    }
}

impl TypeFilter {
    #[must_use]
    pub fn from_config(c: &FilterCfg) -> Self {
        Self {
            scene: c.scene,
            video: c.video,
            web: c.web,
            unknown: c.unknown,
        }
    }

    #[must_use]
    pub fn to_config(&self) -> FilterCfg {
        FilterCfg {
            scene: self.scene,
            video: self.video,
            web: self.web,
            unknown: self.unknown,
        }
    }

    #[must_use]
    pub fn accepts(&self, entry: &WallpaperEntry) -> bool {
        match entry.project_type {
            WallpaperProjectType::Scene => self.scene,
            WallpaperProjectType::Video => self.video,
            WallpaperProjectType::Web => self.web,
            WallpaperProjectType::Unknown => self.unknown,
        }
    }
}
