#![deny(clippy::correctness)]
#![deny(clippy::single_call_fn)]
#![deny(clippy::complexity)]
#![warn(clippy::pedantic)]

mod actor;
mod api;
pub mod config;
pub mod display;
pub mod engine;
pub mod library;
pub mod logging;
pub mod login;
pub mod media;
pub mod paths;
mod power;
pub mod project;
pub mod state;
pub mod user_assets;

#[doc(hidden)]
pub use power::handle_power_change;

#[cfg(test)]
mod tests;

pub use api::{
    validate_backup_renderer_configuration,
    BridgeAppSnapshot, BridgeAudioSpectrum, BridgeComboOption, BridgeDirectoryMode,
    BridgeDisplayConfigRow, BridgeDisplayMode, BridgeDisplayMutationBundle,
    BridgeDisplaySettingsRow, BridgeError, BridgeErrorKind, BridgeFileFilter, BridgeFraming,
    BridgeLibraryScanStatus,
    BridgeLibrarySnapshot, BridgeLockScreenScene, BridgeLogLevel, BridgeLogStatus,
    BridgeMonitorInfoRow, BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgeBatteryMode,
    BridgePropertyDescriptor, BridgePropertyEdit, BridgePropertyKind, BridgePropertyValue,
    BridgeQualityThrottleCause,
    BridgeScalingMode,
    BridgeSceneBackendReport, BridgeSceneUpdateModeReport, BridgeSettingsSnapshot,
    BridgeSliderMetadata, BridgeSnapshotBundle, BridgeStorageStatus, BridgeSurfaceCheck,
    BridgeVideoBackendReport, BridgeWallpaperEntry, BridgeWallpaperKind,
    BridgeWallpaperMutationBundle,
    BridgeWallpaperOptionsSnapshot, WallpaperBridge,
};

mod build {
    include!(concat!(env!("OUT_DIR"), "/shadow.rs"));
}

uniffi::setup_scaffolding!();
