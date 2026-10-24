use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::{AppConfig, WallpaperConfig, app, wallpaper, writer};
use crate::paths::BridgePaths;
use crate::{BridgeError, BridgeErrorKind};

impl From<io::Error> for BridgeError {
    fn from(error: io::Error) -> Self {
        Self::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        }
    }
}

fn config_error(message: impl Into<String>) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Config,
        message: message.into(),
    }
}

fn supported(
    version: u32,
    current: u32,
    context: impl std::fmt::Display,
) -> Result<(), BridgeError> {
    if version > current {
        Err(config_error(format!(
            "unsupported {context} schema {version}; latest supported schema is {current}"
        )))
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct ConfigStore {
    root: PathBuf,
}

#[derive(Debug)]
pub struct ConfigLoad {
    pub config: AppConfig,
    pub backup_reported: Vec<PathBuf>,
}

impl ConfigStore {
    pub fn default_root() -> PathBuf {
        BridgePaths::new().app_support_root()
    }

    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn validate_app_config_text(raw: &str) -> Result<(), BridgeError> {
        let config: AppConfig = toml::from_str(raw)
            .map_err(|error| config_error(format!("invalid app configuration: {error}")))?;
        supported(
            config.schema_version,
            app::SCHEMA_VERSION,
            "app configuration",
        )
    }

    pub fn validate_wallpaper_config_text(raw: &str) -> Result<(), BridgeError> {
        let config: WallpaperConfig = serde_json::from_str(raw)
            .map_err(|error| config_error(format!("invalid wallpaper configuration: {error}")))?;
        supported(
            config.schema_version,
            wallpaper::SCHEMA_VERSION,
            "wallpaper configuration",
        )
    }

    pub fn load(&self) -> Result<ConfigLoad, BridgeError> {
        let path = self.root.join("config.toml");
        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(ConfigLoad {
                    config: AppConfig::default(),
                    backup_reported: Vec::new(),
                });
            }
            Err(error) => return self.recover_app(&path, &error.to_string()),
        };
        let mut config: AppConfig = match toml::from_str(&raw) {
            Ok(config) => config,
            Err(error) => return self.recover_app(&path, &error.to_string()),
        };
        supported(config.schema_version, app::SCHEMA_VERSION, path.display())?;
        config.migrate_legacy_keys();
        Ok(ConfigLoad {
            config,
            backup_reported: Vec::new(),
        })
    }

    fn recover_app(&self, path: &Path, reason: &str) -> Result<ConfigLoad, BridgeError> {
        let backup = backup_corrupted(path)?;
        log::warn!(
            "App configuration {} could not be read or parsed ({reason}); moved to {}",
            path.display(),
            backup.display()
        );
        Ok(ConfigLoad {
            config: AppConfig::default(),
            backup_reported: vec![backup],
        })
    }

    pub fn load_wallpaper(&self, id: &str) -> Result<WallpaperConfig, BridgeError> {
        let path = self.wallpaper_path(id);
        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(WallpaperConfig::new_for(id, "scene"));
            }
            Err(error) => return self.recover_wallpaper(&path, id, &error.to_string()),
        };
        let config: WallpaperConfig = match serde_json::from_str(&raw) {
            Ok(config) => config,
            Err(error) => return self.recover_wallpaper(&path, id, &error.to_string()),
        };
        supported(
            config.schema_version,
            wallpaper::SCHEMA_VERSION,
            path.display(),
        )?;
        Ok(config)
    }

    fn recover_wallpaper(
        &self,
        path: &Path,
        id: &str,
        reason: &str,
    ) -> Result<WallpaperConfig, BridgeError> {
        let backup = backup_corrupted(path)?;
        Err(config_error(format!(
            "wallpaper {id} configuration {} could not be read or parsed ({reason}); moved to {}",
            path.display(),
            backup.display()
        )))
    }

    pub fn save_app_config(&self, config: &AppConfig) -> Result<(), BridgeError> {
        let raw = toml::to_string_pretty(config).map_err(|error| {
            config_error(format!("cannot serialize app configuration: {error}"))
        })?;
        writer::atomic_write(&self.root.join("config.toml"), raw.as_bytes())?;
        Ok(())
    }

    pub fn save_wallpaper(&self, config: &WallpaperConfig) -> Result<(), BridgeError> {
        let raw = serde_json::to_vec_pretty(config).map_err(|error| {
            config_error(format!(
                "cannot serialize wallpaper {} configuration: {error}",
                config.workshop_id
            ))
        })?;
        writer::atomic_write(&self.wallpaper_path(&config.workshop_id), &raw)?;
        Ok(())
    }

    pub fn flush(&self) -> Result<usize, BridgeError> {
        Ok(0)
    }

    fn wallpaper_path(&self, id: &str) -> PathBuf {
        self.root.join("wallpapers").join(format!("{id}.json"))
    }
}

fn backup_corrupted(path: &Path) -> Result<PathBuf, BridgeError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    #[cfg(test)]
    let timestamp = backup_clock::override_timestamp(timestamp);
    let mut filename = path
        .file_name()
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "configuration path has no filename",
            )
        })?
        .to_os_string();
    filename.push(format!(".corrupted-{timestamp}"));
    let backup = path.with_file_name(filename);
    fs::rename(path, &backup).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "cannot move corrupt configuration {} to {}: {error}",
                path.display(),
                backup.display()
            ),
        )
    })?;
    Ok(backup)
}

#[cfg(test)]
pub(super) mod backup_clock {
    use std::cell::Cell;

    thread_local! {
        static FIXED: Cell<Option<u128>> = const { Cell::new(None) };
    }

    pub(super) fn override_timestamp(actual: u128) -> u128 {
        FIXED.with(|fixed| fixed.get().unwrap_or(actual))
    }

    pub(crate) fn during<T>(timestamp: u128, action: impl FnOnce() -> T) -> T {
        struct Restore(Option<u128>);
        impl Drop for Restore {
            fn drop(&mut self) {
                FIXED.with(|fixed| fixed.set(self.0));
            }
        }
        let _restore = Restore(FIXED.with(|fixed| fixed.replace(Some(timestamp))));
        action()
    }
}
