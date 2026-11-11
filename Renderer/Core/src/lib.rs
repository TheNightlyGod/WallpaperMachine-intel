#![deny(clippy::correctness)]
#![deny(clippy::single_call_fn)]
#![deny(clippy::complexity)]
#![warn(clippy::pedantic)]

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
extern crate self as wallpaper_core;

pub mod owe;

mod display;
mod engine;
mod error;
pub mod log_context;
pub mod media;
pub mod project;
pub mod render;
mod window;

pub use display::{
    DisplayDesc, DisplayIdentity,
    watcher::{DisplayEvent, DisplayWatcher},
};
pub use engine::{
    AudioRequirementCallback, DisplayConfig, DisplaySelector, DisplaySnapshotEntry,
    FirstFrameCallback, PointerActivity,
    PointerActivityCallback, PointerConsumerCallback, PointerProbe, PropertyPreview, RecoveryOutcome,
    RecoveryReason, RecoveryStep, SceneWindowEntry, UserShortcutObserverCallback, WallpaperAssignment,
    WallpaperEngine, WallpaperEngineConfig,
};
pub use error::EngineError;
pub use owe::backend::{AudioSpectrum128, SceneTraits, read_scene_traits};
pub use owe::capability::{SceneCapabilityProbe, SceneMissingFile, probe_scene_capability};
pub use owe::scene_demand::{
    SceneBackend, SceneDemandReasons, SceneFailure, SceneFailureStage,
    SceneResolution, SceneRuntimeReport, SceneUpdateMode, SceneVideoPath, SurfaceHealth,
    SurfaceStopReason,
};
pub use owe::scene_registry::SceneRegistry;
pub use window::{PlaceholderStyle, WallpaperWindow, WallpaperWindowBuilder};

#[cfg(feature = "bridge-contract-tests")]
#[doc(hidden)]
pub use engine::contract_testing;

#[cfg(test)]
mod tests;
