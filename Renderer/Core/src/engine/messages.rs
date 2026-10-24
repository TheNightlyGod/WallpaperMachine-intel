#![allow(dead_code)]

use crate::{
    DisplayDesc, DisplaySelector, WallpaperAssignment,
    engine::surface_recovery::{RecoveryReason, RecoveryStep},
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult},
};

pub(super) struct NativePointerInputChanged {
    pub handle: SceneHandle,
    pub renderer_instance: std::sync::Arc<()>,
    pub accepts_pointer_input: bool,
}

/// A renderer's report of whether its committed scene reads system audio.
pub(super) struct NativeAudioRequirementChanged {
    pub handle: SceneHandle,
    pub renderer_instance: std::sync::Arc<()>,
    pub requires_audio: bool,
}

/// A renderer's report that its scene, which had drawn, failed a frame and
/// stopped.
pub(super) struct NativeRenderFailed {
    pub handle: SceneHandle,
    pub renderer_instance: std::sync::Arc<()>,
}

/// A recovery attempt the failure ladder scheduled for itself, delivered after
/// its delay. Carries the renderer it was scheduled for, so an attempt that
/// outlives its renderer (the wallpaper was replaced meanwhile) does nothing.
pub(super) struct RecoverSurfaceAttempt {
    pub handle: SceneHandle,
    pub renderer_instance: std::sync::Arc<()>,
    pub step: RecoveryStep,
    pub number: usize,
}

/// A look at a renderer that recovery rebuilt, which the engine schedules for
/// itself because that renderer reports no failure until it has drawn. Carries
/// the renderer it was scheduled for, like [`RecoverSurfaceAttempt`], and when
/// the rebuild finished.
pub(super) struct SettleRecoveredSurface {
    pub handle: SceneHandle,
    pub renderer_instance: std::sync::Arc<()>,
    pub number: usize,
    pub rebuilt_at: std::time::Instant,
}

/// A recovery asked for from outside the renderer's own report.
pub struct RecoverSurface {
    pub display_id: u32,
    pub reason: RecoveryReason,
}

/// One `engine.openUserShortcut` request from a wallpaper.
///
/// Carries the handle so the wallpaper it came from can be identified, and the
/// property plus the value its user chose. Nothing here decides what the value
/// means.
pub(super) struct NativeUserShortcutRequested {
    pub handle: SceneHandle,
    pub property_name: String,
    pub property_value: String,
}

pub(super) struct PollMouseState {
    pub state: super::MousePollState,
}

#[cfg(test)]
pub(super) struct TakePointerNotificationsForTest;

#[cfg(test)]
pub(super) struct TakeRenderFailuresForTest;

pub struct Ping;

pub struct UpdateMedia {
    pub handle: SceneHandle,
    pub enabled: bool,
    pub state: crate::media::MediaPollResult,
}

#[cfg(test)]
pub struct DisplayRecordCountForTest;

#[cfg(test)]
pub struct SequenceForTest {
    pub expected: u64,
}

#[cfg(test)]
pub struct FailNextRefreshDisplaysForTest;

/// Asks the engine to read the attached displays again and bring its
/// windows and scenes in line with what it finds.
/// The bridge sends it on demand and after a display change.
pub struct RefreshDisplays;

/// Refreshes the engine's display model from descriptors the sender already
/// has, instead of querying the system again.
/// `primary` is the main display and `displays` lists every attached display.
pub struct RefreshDisplayDescriptors {
    pub primary: DisplayDesc,
    pub displays: Vec<DisplayDesc>,
}

/// Makes the engine run exactly this set of scenes: it opens the ones that
/// are new, rebuilds the ones whose descriptor changed, and closes the rest.
/// The reply names the handle of every requested scene.
pub struct ReconcileScenes {
    pub scenes: Vec<SceneDesc>,
}

/// Opens a window for the display the selector names. The reply is the
/// window's scene handle, or nothing when no attached display matches.
/// The assignment of the display decides what the window shows.
pub struct CreateWindowForDisplay {
    pub selector: DisplaySelector,
}

/// Closes the display's window and its scene, but keeps the slot with its
/// assignment, so the display comes back the same way when it is opened
/// again.
pub struct DestroyWindowForDisplay {
    pub selector: DisplaySelector,
}

/// Assigns a wallpaper to one display: either a scene of its own, or a
/// mirror of another display. A mirror that would loop back on itself is
/// refused and leaves the model untouched.
pub struct SetWallpaperForDisplay {
    pub selector: DisplaySelector,
    pub wallpaper: WallpaperAssignment,
}

pub struct SetScalingMode {
    pub handle: SceneHandle,
    pub mode: ScalingMode,
}

pub struct SetScalingFactor {
    pub handle: SceneHandle,
    pub factor: f64,
}

pub struct SetFraming {
    pub handle: SceneHandle,
    pub framing: SceneFraming,
}

/// Shows a position without making it the scene's: the renderer follows, the
/// stored runtime state does not.
pub struct PreviewFraming {
    pub handle: SceneHandle,
    pub framing: SceneFraming,
}

pub struct SetFps {
    pub handle: SceneHandle,
    pub fps: u32,
}

pub struct SetRenderScale {
    pub handle: SceneHandle,
    pub scale: f64,
}

pub struct SetPaused {
    pub handle: SceneHandle,
    pub paused: bool,
}

pub struct SetAllPaused {
    pub paused: bool,
    /// Displays whose scene stays paused regardless of `paused`.
    pub suspended_displays: Vec<u32>,
}

/// Sets the scenes a display keeps loaded and paused when it moves on.
pub struct SetParkedScenes {
    pub display_id: u32,
    pub scene_paths: Vec<String>,
}

/// Reads renderer work counters from every open scene.
pub struct RendererCounters;

pub struct SetMousePosition {
    pub handle: SceneHandle,
    pub x: f64,
    pub y: f64,
}

pub struct SetMouseButton {
    pub handle: SceneHandle,
    pub button: u32,
    pub pressed: bool,
}

pub struct SetMouseEntered {
    pub handle: SceneHandle,
    pub entered: bool,
}

pub struct SetRenderResolution {
    pub handle: SceneHandle,
    pub width: u32,
    pub height: u32,
}

pub struct SetAudioResponseEnabled {
    pub handle: SceneHandle,
    pub enabled: bool,
}

pub struct SetMediaIntegrationEnabled {
    pub handle: SceneHandle,
    pub enabled: bool,
}

pub struct SubmitMediaEventJson {
    pub handle: SceneHandle,
    pub json: String,
}

pub struct ApplySystemMediaArtwork {
    pub handle: SceneHandle,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub struct SetAudioVolume {
    pub handle: SceneHandle,
    pub volume: AudioVolume,
}

pub struct SetAudioMuted {
    pub handle: SceneHandle,
    pub muted: bool,
}

pub struct SetPropertyOverride {
    pub handle: SceneHandle,
    pub flat_json: String,
}

pub struct ResetPropertyOverride {
    pub handle: SceneHandle,
}

/// Shows a property document on the running scene without keeping it: the
/// renderer follows, the stored runtime state does not, and the scene is not
/// loaded again.
///
/// `expected_scene_path` names the wallpaper the document was made for. The
/// handle names a display's scene, not a wallpaper: a reconcile queued ahead of
/// this message can have put another wallpaper on the same handle, and the
/// engine is the only place that can tell, because it handles this message
/// after that reconcile, not before.
pub struct PreviewPropertyOverride {
    pub handle: SceneHandle,
    pub expected_scene_path: String,
    pub flat_json: String,
}

pub struct CloseAllScenes;

pub type ReconcileReply = Result<Vec<SceneResult>, crate::EngineError>;
pub type SceneHandleReply = Result<Option<SceneHandle>, crate::EngineError>;
