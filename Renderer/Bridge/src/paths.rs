//! Path values only; callers are responsible for validation and filesystem access.

use std::ffi::OsString;
use std::path::PathBuf;

pub const BUNDLE_IDENTIFIER: &str = "app.wallpapermachine";

/// Captures a home basis while resolving environment overrides on each request.
#[derive(Clone, Debug)]
pub struct BridgePaths {
    home: Option<PathBuf>,
}

impl BridgePaths {
    #[must_use]
    pub fn new() -> Self {
        Self {
            home: discover_home(),
        }
    }

    #[must_use]
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        Self {
            home: Some(home.into()),
        }
    }

    #[must_use]
    pub fn app_support_root(&self) -> PathBuf {
        override_path("WALLPAPER_MACHINE_SUPPORT_ROOT").unwrap_or_else(|| {
            match &self.home {
                Some(home) => home
                    .join("Library/Application Support")
                    .join(BUNDLE_IDENTIFIER),
                None => PathBuf::from(".").join(BUNDLE_IDENTIFIER),
            }
        })
    }

    #[must_use]
    pub fn steam_workshop_root(&self) -> PathBuf {
        override_path("WALLPAPER_MACHINE_LIBRARY_ROOT").unwrap_or_else(|| {
            match &self.home {
                Some(home) => home.join(
                    "Library/Application Support/Steam/steamapps/workshop/content/431960",
                ),
                None => PathBuf::from("/missing/workshop"),
            }
        })
    }

    #[must_use]
    pub fn project_json(&self, wallpaper_id: &str) -> PathBuf {
        self.steam_workshop_root()
            .join(wallpaper_id)
            .join("project.json")
    }

    #[must_use]
    pub fn assets_root(&self) -> PathBuf {
        override_path("WALLPAPER_MACHINE_ASSETS_ROOT").unwrap_or_else(|| {
            match &self.home {
                Some(home) => home.join(
                    "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets",
                ),
                None => PathBuf::from("/missing/assets"),
            }
        })
    }

    #[must_use]
    pub fn user_assets_root(&self) -> PathBuf {
        override_path("WALLPAPER_MACHINE_USER_ASSETS_ROOT")
            .unwrap_or_else(|| self.app_support_root().join("UserAssets"))
    }

    #[must_use]
    pub fn shader_cache_root(&self) -> PathBuf {
        self.app_support_root().join("shader-cache")
    }

    /// Scene scripts' `localStorage` (plan decision I3): user data, never cleared with caches.
    #[must_use]
    pub fn scene_storage_root(&self) -> PathBuf {
        self.app_support_root().join("SceneStorage")
    }

    /// One wallpaper's `localStorage` folder: `global.json` and `screen-<key>.json`.
    #[must_use]
    pub fn scene_storage_dir(&self, wallpaper_id: &str) -> PathBuf {
        self.scene_storage_root().join(wallpaper_id)
    }

    #[must_use]
    pub fn logs_root(&self) -> PathBuf {
        self.app_support_root().join("Logs")
    }

    #[must_use]
    pub fn log_session_root(&self, start_time: &str) -> PathBuf {
        self.logs_root().join(start_time)
    }
}

impl Default for BridgePaths {
    fn default() -> Self {
        Self::new()
    }
}

fn discover_home() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(home) = contract_tests::home_input() {
        return home;
    }

    dirs::home_dir()
}

fn override_path(key: &str) -> Option<PathBuf> {
    override_value(key).map(PathBuf::from)
}

fn override_value(key: &str) -> Option<OsString> {
    #[cfg(test)]
    if let Some(value) = contract_tests::override_input(key) {
        return value;
    }

    std::env::var_os(key)
}

#[cfg(test)]
#[path = "paths_contract_tests.rs"]
mod contract_tests;
