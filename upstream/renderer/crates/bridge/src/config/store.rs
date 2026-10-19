use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use super::{
    app::{self, AppConfig},
    wallpaper::{self, WallpaperConfig},
};
use crate::{BridgeError, BridgeErrorKind, paths::BridgePaths};

#[derive(Debug)]
pub struct ConfigLoad {
    pub config: AppConfig,
    pub backup_reported: Vec<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct ConfigStore {
    root: PathBuf,
}

impl ConfigStore {
    #[must_use]
    pub fn default_root() -> PathBuf {
        BridgePaths::new().app_support_root()
    }

    #[must_use]
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The directory every file of this store lives under. Other state that
    /// has to survive a restart (the load journal) is kept beside it.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Parses backup bytes without reading, repairing, or replacing live configuration files.
    pub fn validate_app_config_text(raw: &str) -> Result<(), BridgeError> {
        let config = toml::from_str::<AppConfig>(raw)
            .map_err(|error| config_error(format!("invalid app configuration: {error}")))?;
        check_schema_version(config.schema_version, app::SCHEMA_VERSION, "config")
    }

    pub fn validate_wallpaper_config_text(raw: &str) -> Result<(), BridgeError> {
        let config = serde_json::from_str::<WallpaperConfig>(raw)
            .map_err(|error| config_error(format!("invalid wallpaper configuration: {error}")))?;
        check_schema_version(config.schema_version, wallpaper::SCHEMA_VERSION, "wallpaper config")
    }

    /// # Errors
    ///
    /// Returns an error when the config file is from a newer schema or a
    /// corrupt file cannot be backed up.
    pub fn load(&self) -> Result<ConfigLoad, BridgeError> {
        let path = self.config_path();
        if !path.exists() {
            let config = AppConfig::default();
            return Ok(ConfigLoad {
                config,
                backup_reported: Vec::new(),
            });
        }

        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) => {
                let backup = backup_corrupted(&path)?;
                let config = AppConfig::default();
                log::warn!(
                    "backed up unreadable app config path={} backup={} error={error}",
                    path.display(),
                    backup.display()
                );
                return Ok(ConfigLoad {
                    config,
                    backup_reported: vec![backup],
                });
            }
        };

        match toml::from_str::<AppConfig>(&raw) {
            Ok(mut config) => {
                check_schema_version(config.schema_version, app::SCHEMA_VERSION, "config")?;
                config.migrate_legacy_keys();

                Ok(ConfigLoad {
                    config,
                    backup_reported: Vec::new(),
                })
            }
            Err(error) => {
                let backup = backup_corrupted(&path)?;
                let config = AppConfig::default();
                log::warn!(
                    "backed up corrupted app config path={} backup={} error={error}",
                    path.display(),
                    backup.display()
                );
                Ok(ConfigLoad {
                    config,
                    backup_reported: vec![backup],
                })
            }
        }
    }

    /// # Errors
    ///
    /// Returns an error when the config cannot be serialized or written
    /// atomically.
    pub fn save_app_config(&self, config: &AppConfig) -> Result<(), BridgeError> {
        let bytes = toml::to_string_pretty(config)
            .map_err(|error| config_error(error.to_string()))?
            .into_bytes();
        super::writer::atomic_write(&self.config_path(), &bytes)?;
        Ok(())
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper config cannot be read, parsed, or
    /// backed up.
    pub fn load_wallpaper(&self, id: &str) -> Result<WallpaperConfig, BridgeError> {
        let path = self.wallpaper_path(id);
        if !path.exists() {
            return Ok(WallpaperConfig::new_for(id, "scene"));
        }

        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) => {
                let _backup = backup_corrupted(&path)?;
                return Err(config_error(format!(
                    "failed to read wallpaper config {id}: {error}"
                )));
            }
        };
        let config = match serde_json::from_str::<WallpaperConfig>(&raw) {
            Ok(config) => config,
            Err(error) => {
                let _backup = backup_corrupted(&path)?;
                return Err(config_error(format!(
                    "corrupted wallpaper config {id}: {error}"
                )));
            }
        };

        check_schema_version(config.schema_version, wallpaper::SCHEMA_VERSION, "wallpaper config")?;

        Ok(config)
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper config cannot be serialized or
    /// written atomically.
    pub fn save_wallpaper(&self, config: &WallpaperConfig) -> Result<(), BridgeError> {
        let bytes = serde_json::to_string_pretty(config)
            .map_err(|error| config_error(error.to_string()))?
            .into_bytes();
        super::writer::atomic_write(&self.wallpaper_path(&config.workshop_id), &bytes)?;
        Ok(())
    }

    /// # Errors
    ///
    /// This compatibility shim currently does not fail.
    pub fn flush(&self) -> Result<usize, BridgeError> {
        // Temporary compatibility shim: config writes are immediate.
        Ok(0)
    }

    fn config_path(&self) -> PathBuf {
        self.root.join("config.toml")
    }

    fn wallpaper_path(&self, id: &str) -> PathBuf {
        self.root.join("wallpapers").join(format!("{id}.json"))
    }
}

fn check_schema_version(version: u32, supported: u32, name: &str) -> Result<(), BridgeError> {
    if version > supported {
        return Err(config_error(format!(
            "{name} schema version {version} is newer than supported version {supported}"
        )));
    }
    Ok(())
}

fn backup_corrupted(path: &Path) -> Result<PathBuf, BridgeError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let file_name = path
        .file_name()
        .expect("config path has file name")
        .to_string_lossy();
    let backup = path.with_file_name(format!("{file_name}.corrupted-{timestamp}"));
    fs::rename(path, &backup)?;
    Ok(backup)
}

fn config_error(message: impl Into<String>) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Config,
        message: message.into(),
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(error: std::io::Error) -> Self {
        BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ConfigStore;
    use crate::config::{
        AppConfig, MonitorSettingsCfg, SceneRendererModeCfg, SceneResolutionCfg,
        VideoBackendModeCfg,
    };

    fn load_config(contents: &str) -> crate::config::AppConfig {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("config.toml"), contents).unwrap();
        ConfigStore::open(root.path().to_path_buf())
            .load()
            .expect("config load")
            .config
    }

    #[test]
    fn media_integration_choices_survive_saving_and_reopening_wallpaper_configs() {
        for stored in [None, Some(r#"{"workshop_id":"100","type":"scene"}"#)] {
            let root = tempfile::tempdir().unwrap();
            let store = ConfigStore::open(root.path().to_path_buf());
            let path = store.wallpaper_path("100");
            if let Some(json) = stored {
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(&path, json).unwrap();
            }
            let mut config = store.load_wallpaper("100").unwrap();
            store.save_wallpaper(&config).unwrap();
            let saved: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(saved["media_integration_enabled"], true);

            for enabled in [false, true, false] {
                config.media_integration_enabled = enabled;
                store.save_wallpaper(&config).unwrap();
                let reopened = ConfigStore::open(root.path().to_path_buf());
                config = reopened.load_wallpaper("100").unwrap();
                assert_eq!(config.media_integration_enabled, enabled);
            }
        }
    }

    #[test]
    fn legacy_native_video_opt_in_becomes_native_preferred() {
        let config = load_config("[experimental]\nnative_video_backend = true\n");

        assert_eq!(config.video_backend, VideoBackendModeCfg::NativePreferred);
    }

    #[test]
    fn config_without_the_legacy_opt_in_stays_on_compatibility() {
        let config = load_config("[experimental]\n");

        assert_eq!(config.video_backend, VideoBackendModeCfg::Compatibility);
    }

    #[test]
    fn migrated_config_no_longer_writes_the_legacy_key() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        std::fs::write(&path, "[experimental]\nnative_video_backend = true\n").unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());
        let config = store.load().expect("config load").config;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(&path).unwrap();
        assert!(!written.contains("native_video_backend"), "{written}");
        assert!(written.contains("video_backend = \"native_preferred\""), "{written}");
    }

    #[test]
    fn a_config_that_never_heard_of_the_scene_settings_reads_the_shipped_defaults() {
        let config = load_config("[general]\n");

        assert_eq!(config.scene_renderer, SceneRendererModeCfg::NativeMetalPreferred);
        assert!(
            !config.quality.scene_on_demand_enabled,
            "stopping a scene's tick is opted into; an older config must not arrive already on"
        );
    }

    #[test]
    fn the_scene_settings_survive_a_save_and_reload() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut config = crate::config::AppConfig::default();
        config.scene_renderer = SceneRendererModeCfg::NativeMetalPreferred;
        config.quality.scene_on_demand_enabled = true;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(&path).unwrap();
        assert!(
            written.contains("scene_renderer = \"native_metal_preferred\""),
            "the renderer choice is stored under its own key, in snake_case: {written}"
        );
        let reloaded = store.load().expect("config load").config;
        assert_eq!(
            reloaded.scene_renderer,
            SceneRendererModeCfg::NativeMetalPreferred
        );
        assert!(reloaded.quality.scene_on_demand_enabled);
    }

    /// A config written before the choice existed has no key for it, and the
    /// shipped default applies: a 2D scene is rasterized for the display.
    #[test]
    fn a_config_that_never_heard_of_the_scene_resolution_reads_the_display() {
        let config = load_config("[quality]\nrender_scale = 0.75\n");

        assert_eq!(config.quality.scene_resolution, SceneResolutionCfg::Display);
        assert_eq!(config.quality.render_scale, 0.75, "the neighbouring setting is untouched");
    }

    #[test]
    fn the_scene_resolution_survives_a_save_and_reload_under_its_own_key() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut config = AppConfig::default();
        config.quality.scene_resolution = SceneResolutionCfg::Canvas;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("scene_resolution = \"canvas\""), "{written}");
        let reloaded = store.load().expect("config load").config;
        assert_eq!(
            reloaded.quality.scene_resolution,
            SceneResolutionCfg::Canvas,
            "a return to the canvas is not moved back to the default"
        );
    }

    /// The scene renderer is decided by its own key and the one-time move to
    /// the new default, never by the video backend choice.
    #[test]
    fn the_scene_renderer_never_inherits_the_video_backend_choice() {
        let config = load_config(
            "video_backend = \"native_preferred\"\nnative_metal_default_applied = true\n\
             scene_renderer = \"compatibility\"\n",
        );

        assert_eq!(config.video_backend, VideoBackendModeCfg::NativePreferred);
        assert_eq!(config.scene_renderer, SceneRendererModeCfg::Compatibility);
    }

    /// A config saved before Native Metal became the default stores the old
    /// default, `compatibility`, whether or not anyone chose it. It moves to the
    /// new default once, and the marker it is saved with keeps a later choice.
    #[test]
    fn a_config_from_before_the_native_default_moves_to_it_once() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        std::fs::write(&path, "scene_renderer = \"compatibility\"\n").unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());

        let mut config = store.load().expect("config load").config;
        assert_eq!(config.scene_renderer, SceneRendererModeCfg::NativeMetalPreferred);
        assert!(config.native_metal_default_applied);

        config.scene_renderer = SceneRendererModeCfg::Compatibility;
        store.save_app_config(&config).expect("config save");
        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("native_metal_default_applied = true"), "{written}");
        let reloaded = store.load().expect("config load").config;
        assert_eq!(
            reloaded.scene_renderer,
            SceneRendererModeCfg::Compatibility,
            "a choice made after the move is kept"
        );
    }

    #[test]
    fn legacy_mirror_target_fps_follows_the_display_unless_it_was_an_explicit_cap() {
        let untouched = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 60\n");
        assert_eq!(untouched.monitor_settings[0].frame_rate, None);
        let missing = load_config("[[monitor_settings]]\nkind = \"primary\"\n");
        assert_eq!(missing.monitor_settings[0].frame_rate, None);

        let capped = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 30\n");
        assert_eq!(capped.monitor_settings[0].frame_rate, Some(30));
        let zero = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 0\n");
        assert_eq!(zero.monitor_settings[0].frame_rate, Some(1));

        let newer_wins = load_config(
            "[[monitor_settings]]\nkind = \"primary\"\nframe_rate = 24\ntarget_fps = 30\n",
        );
        assert_eq!(newer_wins.monitor_settings[0].frame_rate, Some(24));

        let root = tempfile::tempdir().unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut following = AppConfig::default();
        following.monitor_settings.push(MonitorSettingsCfg::default());
        store.save_app_config(&following).expect("config save");
        let written = std::fs::read_to_string(root.path().join("config.toml")).unwrap();
        let tables = monitor_settings_tables(&written);
        assert_eq!(tables.len(), 1, "{written}");
        assert!(tables[0].get("target_fps").is_none(), "{written}");
        assert!(tables[0].get("frame_rate").is_none(), "{written}");

        let mut capped = AppConfig::default();
        capped.monitor_settings.push(MonitorSettingsCfg {
            frame_rate: Some(30),
            ..MonitorSettingsCfg::default()
        });
        store.save_app_config(&capped).expect("config save");
        let written = std::fs::read_to_string(root.path().join("config.toml")).unwrap();
        let tables = monitor_settings_tables(&written);
        assert!(tables[0].get("target_fps").is_none(), "{written}");
        assert_eq!(tables[0].get("frame_rate").and_then(toml::Value::as_integer), Some(30));
        assert_eq!(
            store.load().expect("config load").config.monitor_settings[0].frame_rate,
            Some(30)
        );
    }

    fn monitor_settings_tables(written: &str) -> Vec<toml::Value> {
        let value: toml::Value = toml::from_str(written).unwrap();
        value
            .get("monitor_settings")
            .and_then(toml::Value::as_array)
            .cloned()
            .unwrap_or_default()
    }
}
