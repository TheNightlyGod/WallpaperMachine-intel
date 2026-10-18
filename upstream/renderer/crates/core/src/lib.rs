//! Core wallpaper engine APIs shared by the macOS app and tests.
//!
//! This crate owns the Rust-facing API for scene reconciliation, display
//! discovery, audio response, media decoding, shader cache decisions, and the
//! macOS wallpaper window/rendering bridge.
//!
//! ## Runtime Boundary
//!
//! `wallpaper-core` is the runtime state machine. It owns scene handles,
//! display reconciliation, wallpaper windows, mutable per-scene state, audio
//! response state, project property overrides, and shader cache decisions.
//!
//! Open Wallpaper Engine remains a statically linked renderer backend. The
//! private `owe` module contains only bindgen-generated calls and safe
//! ownership wrappers around renderer objects; it must not own scene
//! registries, display maps, or duplicate Rust descriptors.
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
    RecoveryReason, RecoveryStep, UserShortcutObserverCallback, WallpaperAssignment,
    WallpaperEngine, WallpaperEngineConfig,
};
pub use error::EngineError;
pub use owe::backend::AudioSpectrum128;
pub use owe::scene_demand::{
    SceneBackend, SceneDemandReasons, SceneRendererPreference, SceneResolution, SceneRuntimeReport,
    SceneUpdateMode, SceneVideoPath, SurfaceHealth, SurfaceStopReason,
};
pub use owe::scene_registry::SceneRegistry;
pub use window::{PlaceholderStyle, WallpaperWindow, WallpaperWindowBuilder};

#[cfg(test)]
mod tests;
