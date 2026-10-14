use std::path::PathBuf;

pub const BUNDLE_IDENTIFIER: &str = "app.wallpapermachine";

#[derive(Clone, Debug)]
pub struct BridgePaths {
    home: Option<PathBuf>,
}

impl Default for BridgePaths {
    fn default() -> Self {
        Self {
            home: dirs::home_dir(),
        }
    }
}

impl BridgePaths {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        Self {
            home: Some(home.into()),
        }
    }

    #[must_use]
    pub fn app_support_root(&self) -> PathBuf {
        if let Some(root) = std::env::var_os("WALLPAPER_MACHINE_SUPPORT_ROOT") {
            return PathBuf::from(root);
        }
        self.home.as_deref().map_or_else(
            || PathBuf::from(".").join(BUNDLE_IDENTIFIER),
            |home| {
                home.join("Library")
                    .join("Application Support")
                    .join(BUNDLE_IDENTIFIER)
            },
        )
    }

    #[must_use]
    pub fn steam_workshop_root(&self) -> PathBuf {
        if let Some(root) = std::env::var_os("WALLPAPER_MACHINE_LIBRARY_ROOT") {
            return PathBuf::from(root);
        }
        self.home.as_deref().map_or_else(
            || PathBuf::from("/missing/workshop"),
            |home| home.join("Library/Application Support/Steam/steamapps/workshop/content/431960"),
        )
    }

    /// The project file of a Workshop wallpaper: the `scene_path` its scene
    /// descriptor carries, and so what a running scene reports it draws.
    #[must_use]
    pub fn project_json(&self, wallpaper_id: &str) -> PathBuf {
        self.steam_workshop_root()
            .join(wallpaper_id)
            .join("project.json")
    }

    #[must_use]
    pub fn assets_root(&self) -> PathBuf {
        if let Some(root) = std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT") {
            return PathBuf::from(root);
        }
        self.home.as_deref().map_or_else(
            || PathBuf::from("/missing/assets"),
            |home| {
                home.join(
                    "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets",
                )
            },
        )
    }

    /// Where the app keeps its copies of the files a user picked for a
    /// wallpaper's file or directory properties.
    ///
    /// Under the support root but deliberately not under `shader-cache`: these
    /// are user-imported originals that nothing regenerates, so an ordinary
    /// cache clean must never reach them.
    #[must_use]
    pub fn user_assets_root(&self) -> PathBuf {
        if let Some(root) = std::env::var_os("WALLPAPER_MACHINE_USER_ASSETS_ROOT") {
            return PathBuf::from(root);
        }
        self.app_support_root().join("UserAssets")
    }

    #[must_use]
    pub fn shader_cache_root(&self) -> PathBuf {
        self.app_support_root().join("shader-cache")
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

#[cfg(test)]
mod tests {
    use super::{BUNDLE_IDENTIFIER, BridgePaths};

    #[test]
    fn logs_root_lives_under_app_support() {
        let paths = BridgePaths::for_home("/Users/example");

        assert_eq!(
            paths.logs_root(),
            std::path::PathBuf::from("/Users/example")
                .join("Library")
                .join("Application Support")
                .join(BUNDLE_IDENTIFIER)
                .join("Logs")
        );
    }

    #[test]
    fn log_session_root_appends_session_name() {
        let paths = BridgePaths::for_home("/Users/example");

        assert_eq!(
            paths.log_session_root("20260520-120000"),
            paths.logs_root().join("20260520-120000")
        );
    }
}
