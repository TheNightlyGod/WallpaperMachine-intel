use std::{
    future::Future,
    sync::Arc,
    thread,
    time::Duration,
};

#[cfg(test)]
use arc_swap::ArcSwap;
#[cfg(test)]
use super::controlled_support::{
    self, Callable, Completion, Control, FailurePolicy, Failures, Fault, FaultCategory, Hold,
    Observation, Reading, ReleaseFailure,
};
use futures_util::future::{BoxFuture, FutureExt};
#[cfg(test)]
use wallpaper_core::project::SceneTemplate;
use wallpaper_core::{
    AudioSpectrum128, DisplaySelector, DisplaySnapshotEntry, EngineError, FirstFrameCallback,
    PropertyPreview, RecoveryOutcome, RecoveryReason, SceneBackend, SceneDemandReasons, SceneWindowEntry,
    SceneResolution, SceneUpdateMode, WallpaperAssignment, WallpaperEngine,
    media::audio::{
        AudioCaptureBackend, AudioCaptureController, AudioVolume, PlatformAudioCaptureBackend,
        RESTART_RETRY_DELAYS, RestartOutcome, device_watch::OutputDeviceWatcher,
    },
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult},
    render::RendererSurfaceCounters,
};

use super::facade_readiness::FirstFrameReadiness;
use super::audio_requests::{CaptureAssembly, CaptureEvents, CaptureMailbox, start_capture_lane};

#[cfg(test)]
mod mount_tests;

pub type EngineFuture<T> = BoxFuture<'static, Result<T, EngineError>>;

/// Presentation gate and live consumers that do not own renderer scene handles.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioCaptureDemand {
    pub suspended: bool,
    pub external_consumers: bool,
}

/// What one open scene is actually doing right now: whether its clock is
/// running and which backend drew it.
///
/// Defined in the core crate and re-exported here so the bridge and the
/// renderer describe a scene with one type rather than two that need
/// converting. `update_mode` and `backend` are `Option` on purpose: `None` is
/// "the renderer could not answer", which is a different fact from any of the
/// real modes. A running scene that cannot be read must never be reported as
/// `Continuous`, and it is emitted as a row rather than omitted, so "running
/// but unreadable" does not collapse into "nothing running".
///
/// Pulled on the existing snapshot rebuild; nothing here polls, and reading it
/// does not switch renderer counting on.
pub use wallpaper_core::SceneRuntimeReport;

pub trait EngineFacade: Send + Sync + 'static {
    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> EngineFuture<()>;
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>>;
    fn refresh_displays(&self) -> EngineFuture<()>;
    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry>;
    /// Every open scene with its window, the parked ones included. A facade
    /// that keeps nothing parked lists none.
    fn scene_windows(&self) -> Vec<SceneWindowEntry> {
        Vec::new()
    }
    /// Sets the scenes, by scene path, that `display_id` keeps loaded and
    /// paused when it moves on to another wallpaper (see
    /// [`wallpaper_core::WallpaperEngine::set_parked_scenes`]). A facade that
    /// keeps nothing parked ignores it.
    fn set_parked_scenes(&self, display_id: u32, scene_paths: Vec<String>) -> EngineFuture<()> {
        let _ = (display_id, scene_paths);
        async move { Ok(()) }.boxed()
    }
    fn close_all_scenes(&self) -> EngineFuture<()>;
    /// Applies a global pause target to every open scene in one pass: a scene
    /// is paused when `paused` is set (the user's Play/Pause choice, power
    /// policy, display sleep, session lock) or when its display is in
    /// `suspended_displays`. A global resume therefore never restarts a
    /// display that is still covered, not even briefly.
    fn set_all_paused(&self, paused: bool, suspended_displays: Vec<u32>) -> EngineFuture<()>;
    /// Pauses or resumes the scene on one display. One display being hidden
    /// must not stop a visible one, so occlusion is applied here rather than
    /// through `set_all_paused`.
    fn set_display_paused(&self, display_id: u32, paused: bool) -> EngineFuture<()>;
    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()>;
    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()>;
    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()>;
    fn set_media_integration_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()>;
    fn submit_media_event_json(&self, handle: SceneHandle, json: String) -> EngineFuture<()> {
        let _ = (handle, json);
        async move { Ok(()) }.boxed()
    }
    fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> EngineFuture<()> {
        let _ = (handle, width, height, rgba);
        async move { Ok(()) }.boxed()
    }
    /// Registers or releases one scene as a system-audio capture consumer.
    /// The scene's own audio-response switch is `set_audio_response_enabled`.
    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()>;
    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()>;
    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()>;
    /// Live-moves the presented wallpaper inside the room its display leaves
    /// around it. Nothing is rebuilt, and the engine refuses a position that
    /// is not a fraction between 0 and 1.
    fn set_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()>;
    /// Shows a scene at a position while a drag is under way, without making it
    /// the scene's position: the renderer follows, the engine's stored state
    /// does not, and a later `set_framing` commits it. The engine refuses a
    /// position that is not a fraction between 0 and 1.
    fn preview_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()>;
    /// Shows a scene a whole property document while an edit is under way,
    /// without making it the scene's look: the renderer follows, the engine's
    /// stored state does not, so the next time the scene is loaded it shows
    /// what is saved. The document is the complete state to show (`{}` is the
    /// project's authored defaults), and the engine refuses one that is not a
    /// JSON object.
    ///
    /// `scene_path` is the project file of the wallpaper the document was made
    /// for. A handle names a display's scene, which a reconcile still under way
    /// can have given to another wallpaper; the engine checks what the scene
    /// draws when it handles the request and answers
    /// [`PropertyPreview::OtherWallpaper`], sending nothing, when it is not that
    /// wallpaper. The engine also knows what each scene was last shown, so a
    /// scene that already shows the document is not told again and one that was
    /// loaded again is.
    fn preview_property_override(
        &self,
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
    ) -> EngineFuture<PropertyPreview>;
    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()>;
    /// Live-updates one scene's internal rasterization scale. Resizes render
    /// targets in place; it must not reparse the project or reopen video.
    fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> EngineFuture<()>;
    /// Samples the system pointer once and hands the result to the scenes.
    /// The bridge's mouse poller calls it repeatedly while
    /// polling is enabled.
    fn poll_mouse_position(&self) -> EngineFuture<()>;
    /// Tells one scene where the pointer is.
    /// The position is relative to the scene, not to the screen,
    /// so a caller that reads a global point converts it first.
    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()>;
    /// Delivers a button edge to one scene: `pressed` is true when the button
    /// goes down and false when it is released.
    /// `button` is the system's number for the button.
    fn set_mouse_button(&self, handle: SceneHandle, button: u32, pressed: bool) -> EngineFuture<()>;
    /// Reports that the pointer entered or left the scene's display.
    /// It is separate from the position updates so that a scene is told when
    /// the pointer has gone, not only where it was last seen.
    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()>;
    /// Opens a window on the display the selector names and returns its
    /// scene handle, or `None` when no connected display matches.
    /// What the window shows is decided by the assignment of its display.
    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>>;
    /// Gives a display its wallpaper: a template for a scene of its own, or
    /// the choice to mirror another display. The handle is the display's
    /// scene afterwards, or `None` when there is no scene to name.
    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>>;
    /// Registers the callback that hears about first frames.
    /// A later call replaces the earlier registration.
    /// Unlike the members above, it returns at once and is not a future.
    fn set_first_frame_callback(&self, callback: FirstFrameCallback);
    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    );
    /// Installs the sink the pointer sampler waits on; replays the current
    /// monitor gap synchronously. The callback runs on the AppKit main thread
    /// for OS input and must only record the signal.
    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    );
    /// Cursor state for change detection while the event monitors have a gap.
    /// Called on the sampler thread; must not touch the main thread.
    fn probe_pointer(&self) -> wallpaper_core::PointerProbe;
    /// Installs the sink for `engine.openUserShortcut` requests. Pushed rather
    /// than polled: a press is rare and must not cost an idle wakeup to notice.
    ///
    /// Required, with no default: the caller hands over the only thing keeping
    /// its channel open, and a forwarder that quietly dropped it closed that
    /// channel before the first press, which looks exactly like a wallpaper
    /// whose buttons are unbound.
    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    );
    /// Whether the scene behind `handle` reads system audio, as its renderer
    /// last reported: an audio-processing material or particle, an audio
    /// spectrum uniform, or a script that asked for audio buffers. A newly
    /// opened or rebuilt scene reads `false` until its renderer says otherwise.
    fn scene_requires_audio(&self, handle: SceneHandle) -> bool;
    /// Installs the observer told when a live scene starts or stops reading
    /// system audio, replaying the scenes that currently do. Pushed, never
    /// polled. Runs on the engine's thread under a lock, so it must only hand
    /// the event on.
    ///
    /// Required, with no default: a forwarder that dropped it would keep the
    /// system-audio tap shut for every scene that reads audio.
    fn set_audio_requirement_callback(
        &self,
        callback: Option<wallpaper_core::AudioRequirementCallback>,
    );
    /// Atomically updates the capture gate and non-scene demand. Scene ownership
    /// is preserved; resuming alone must not create a capture consumer.
    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()>;
    /// Turns renderer counting on or off for the whole process. Off by
    /// default; enabling starts no thread, timer or output stream.
    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
    }
    /// Reads per-surface renderer counters plus the process-wide counters that
    /// belong to no single surface.
    fn renderer_counters(&self) -> EngineFuture<(Vec<RendererSurfaceCounters>, Vec<u64>)> {
        async move { Ok((Vec::new(), Vec::new())) }.boxed()
    }
    /// Turns the scene renderer's static-subgraph caching and redundant
    /// copy-pass elimination on or off for the whole process. On by default.
    ///
    /// Applied live to running scenes: it changes how a frame is built, not
    /// what the scene is, so it must never force a rebuild.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
    }
    /// Turns whole-scene on-demand updating on or off for the whole process.
    /// Off by default.
    ///
    /// A scene with no continuing reason to redraw stops its periodic tick and
    /// wakes on events instead. It is not a frame-rate cap and it does not
    /// stop scripts, sound or event handling.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
    }
    /// Turns direct NV12 plane sampling on or off inside native Metal scenes,
    /// process-wide. Off by default.
    ///
    /// A material with no usable plane variant, and any frame that is not
    /// 8-bit NV12, keeps the existing colour conversion whatever this says.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
    }
    /// Chooses how many pixels a 2D scene is rasterized with, process-wide.
    /// `Canvas` by default.
    ///
    /// A scene opened afterwards takes it when its graph is built; one already
    /// running takes it when its render scale is next applied, which resizes
    /// its targets in place without reparsing the project or reopening a video.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_scene_resolution(&self, resolution: SceneResolution) -> Result<(), EngineError> {
        let _ = resolution;
        Ok(())
    }
    /// One row per open scene. An empty vector means nothing was observed,
    /// never that every scene is idle.
    fn scene_runtime_reports(&self) -> Vec<SceneRuntimeReport> {
        Vec::new()
    }
    /// Asks the engine to bring back the surface of the scene on `display_id`
    /// by the next rung of that scene's recovery ladder, without waiting for the
    /// rung's delay.
    ///
    /// Required to be forwarded by every wrapper: the default answers that no
    /// scene was found, so a wrapper that drops this call turns every repair it
    /// is asked for into a quiet no-op.
    ///
    /// # Errors
    ///
    /// Returns the error of the attempt when the engine tried and failed.
    fn recover_surface(
        &self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> EngineFuture<RecoveryOutcome> {
        let _ = (display_id, reason);
        async move { Ok(RecoveryOutcome::NoScene) }.boxed()
    }
    /// The most recent process-wide audio analysis, or `None` when no analysis
    /// has been produced yet.
    ///
    /// One analysis serves the whole process: it is not per scene and not per
    /// display, so a web page reads the same bins a scene does.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        Ok(None)
    }
}

#[derive(Clone)]
pub struct RealEngineFacade {
    engine: WallpaperEngine,
    audio_capture: OwnedCaptureLane,
    audio_mutation: Arc<tokio::sync::Mutex<()>>,
    readiness: FirstFrameReadiness,
    /// One reconcile at a time, so each waits only on the frames it caused.
    reconcile_turn: Arc<tokio::sync::Mutex<()>>,
}

impl RealEngineFacade {
    #[must_use]
    pub fn new(engine: WallpaperEngine) -> Self {
        Self {
            audio_capture: OwnedCaptureLane::new(engine.clone()),
            audio_mutation: Arc::default(),
            readiness: FirstFrameReadiness::new(),
            reconcile_turn: Arc::default(),
            engine,
        }
    }
}

/// The displays on which `scenes` open or replace a scene: the only ones
/// that announce a first frame again.
///
/// The baseline is the engine's live state, not what this facade last asked
/// for. A display refresh moves and resizes scenes in place without passing
/// through here, and a scene that only gets new geometry keeps its renderer,
/// which reports its first frame once. Waiting on such a display could only
/// end in the 90-second timeout, which then rolled back a wallpaper that was
/// playing. A scene the display keeps parked (`windows`) for the same
/// wallpaper runs again instead of loading, and it drew long ago, so it is
/// not waited on either.
pub(crate) fn displays_awaiting_first_frame(
    live: &[DisplaySnapshotEntry],
    windows: &[SceneWindowEntry],
    scenes: &[SceneDesc],
) -> Vec<u32> {
    scenes
        .iter()
        .filter(|scene| {
            !windows.iter().any(|window| {
                window.parked
                    && window.display_id == scene.display.display_id
                    && {
                        let mut kept = window.desc.clone();
                        // Opening a scene consumes its shader refresh, and a parked scene takes
                        // the frame rate and the sound it missed without a rebuild when it
                        // runs again.
                        kept.force_shader_refresh = false;
                        kept.fps = scene.fps;
                        kept.audio_volume = scene.audio_volume;
                        kept.audio_muted = scene.audio_muted;
                        kept.same_wallpaper(scene)
                    }
            })
        })
        .filter(|scene| {
            !live.iter().any(|entry| {
                entry.desc.display_id == scene.display.display_id
                    && entry.handle.is_some()
                    && matches!(&entry.assignment, Some(WallpaperAssignment::Direct(template)) if {
                        let mut running = template.for_display(scene.display.clone());
                        // Opening a scene consumes its shader refresh.
                        running.force_shader_refresh = false;
                        running.same_wallpaper(scene)
                    })
            })
        })
        .map(|scene| scene.display.display_id)
        .collect()
}

// The real facade and device-free controls execute this same sequencing. Closures
// supply only the core and capture boundaries; no engine/policy is duplicated.
pub(crate) async fn mutate_scenes_and_prune<T, C, CF, P, PF>(
    audio_mutation: &tokio::sync::Mutex<()>,
    core: C,
    prune: P,
) -> Result<T, EngineError>
where
    C: FnOnce() -> CF,
    CF: Future<Output = Result<T, EngineError>>,
    P: FnOnce() -> PF,
    PF: Future<Output = Result<(), String>>,
{
    let _audio_guard = audio_mutation.lock().await;
    let result = core().await;
    prune().await.map_err(EngineError::Platform)?;
    result
}

pub(crate) async fn mutate_audio<T, C, CF>(
    audio_mutation: &tokio::sync::Mutex<()>,
    capture: C,
) -> Result<T, EngineError>
where
    C: FnOnce() -> CF,
    CF: Future<Output = Result<T, String>>,
{
    let _audio_guard = audio_mutation.lock().await;
    capture().await.map_err(EngineError::Platform)
}

pub(crate) async fn reconcile_with_readiness<S, C, CF, P, PF>(
    reconcile_turn: &tokio::sync::Mutex<()>,
    audio_mutation: &tokio::sync::Mutex<()>,
    readiness: &FirstFrameReadiness,
    scenes: Vec<SceneDesc>,
    snapshot: S,
    core: C,
    prune: P,
) -> Result<Vec<SceneResult>, EngineError>
where
    S: FnOnce() -> (Vec<DisplaySnapshotEntry>, Vec<SceneWindowEntry>),
    C: FnOnce(Vec<SceneDesc>) -> CF,
    CF: Future<Output = Result<Vec<SceneResult>, EngineError>>,
    P: FnOnce() -> PF,
    PF: Future<Output = Result<(), String>>,
{
    let _turn = reconcile_turn.lock().await;
    let checkpoint = readiness.checkpoint();
    let (live, windows) = snapshot();
    let changed = displays_awaiting_first_frame(&live, &windows, &scenes);
    let results = mutate_scenes_and_prune(audio_mutation, || core(scenes), prune).await?;
    readiness
        .await_results(checkpoint, &changed, results, first_frame_timeout)
        .await
}

pub(crate) fn register_first_frame_callback(
    readiness: &FirstFrameReadiness,
    callback: FirstFrameCallback,
    install: impl FnOnce(FirstFrameCallback),
) {
    install(readiness.wrap_callback(callback));
}

fn first_frame_timeout() -> EngineError {
    EngineError::Render("The wallpaper did not render a first frame within 90 seconds. Check the project files and shared scene assets; this wallpaper may use unsupported effects. Your previous configuration will be restored.".into())
}

impl EngineFacade for RealEngineFacade {
    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.update_media(handle, enabled, state).await }.boxed()
    }
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let engine = self.engine.clone();
        let readiness = self.readiness.clone();
        let reconcile_turn = self.reconcile_turn.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            reconcile_with_readiness(
                &reconcile_turn,
                &audio_mutation,
                &readiness,
                scenes,
                || (engine.display_snapshot(), engine.scene_windows()),
                |scenes| engine.reconcile_scenes(scenes),
                || audio_capture.mailbox().prune_scenes(),
            ).await
        }.boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            mutate_scenes_and_prune(
                &audio_mutation,
                || engine.refresh_displays(),
                || audio_capture.mailbox().prune_scenes(),
            ).await
        }.boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.engine.display_snapshot()
    }

    fn scene_windows(&self) -> Vec<SceneWindowEntry> {
        self.engine.scene_windows()
    }

    fn set_parked_scenes(&self, display_id: u32, scene_paths: Vec<String>) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            // Closing a parked scene drops its renderer like any other close.
            mutate_scenes_and_prune(
                &audio_mutation,
                || engine.set_parked_scenes(display_id, scene_paths),
                || audio_capture.mailbox().prune_scenes(),
            ).await
        }.boxed()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            mutate_scenes_and_prune(
                &audio_mutation,
                || engine.close_all_scenes(),
                || audio_capture.mailbox().prune_scenes(),
            ).await
        }.boxed()
    }

    fn set_all_paused(&self, paused: bool, suspended_displays: Vec<u32>) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_all_paused(paused, suspended_displays).await }.boxed()
    }

    fn set_display_paused(&self, display_id: u32, paused: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move {
            let Some(handle) = engine
                .display_snapshot()
                .iter()
                .find(|entry| entry.desc.display_id == display_id)
                .and_then(|entry| entry.handle)
            else {
                // A display with no open scene has nothing to pause; the state
                // is carried by the descriptor the next reconcile builds.
                return Ok(());
            };
            engine.set_paused(handle, paused).await
        }
        .boxed()
    }

    fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_scene_optimization_enabled(enabled)
    }

    fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_scene_on_demand_enabled(enabled)
    }

    fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_scene_video_plane_sampling_enabled(enabled)
    }

    fn set_scene_resolution(&self, resolution: SceneResolution) -> Result<(), EngineError> {
        self.engine.set_scene_resolution(resolution)
    }

    fn scene_runtime_reports(&self) -> Vec<SceneRuntimeReport> {
        // Four pointer reads per open scene on the existing snapshot path: no
        // counters, no thread, no I/O. A scene the renderer cannot answer for
        // still produces a row, with `None` where the answer would be, because
        // dropping it would make an unreadable scene indistinguishable from an
        // absent one.
        self.engine.scene_runtime_reports()
    }

    fn recover_surface(
        &self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> EngineFuture<RecoveryOutcome> {
        let engine = self.engine.clone();
        async move { engine.recover_surface(display_id, reason).await }.boxed()
    }

    fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        self.engine.current_audio_spectrum()
    }

    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_renderer_counters_enabled(enabled)
    }

    fn renderer_counters(&self) -> EngineFuture<(Vec<RendererSurfaceCounters>, Vec<u64>)> {
        let engine = self.engine.clone();
        async move { engine.renderer_counters().await }.boxed()
    }

    // Volume, mute and audio response are passed to the engine unchanged. None
    // of them takes the audio-mutation lock or touches system capture, which
    // `set_audio_capture_enabled` switches separately.
    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_volume(handle, volume).await }.boxed()
    }

    // Mute is forwarded exactly like volume.
    // The engine keeps the two apart; nothing here combines them.
    // The bridge passes the already-combined mute when it needs one.
    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_muted(handle, muted).await }.boxed()
    }

    // Whether the scene reacts to audio. Only the scene's own switch is
    // changed here; capture registration is a separate request that the
    // bridge issues next to this one.
    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_response_enabled(handle, enabled).await }.boxed()
    }

    fn set_media_integration_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_media_integration_enabled(handle, enabled).await }.boxed()
    }

    fn submit_media_event_json(&self, handle: SceneHandle, json: String) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.submit_media_event_json(handle, json).await }.boxed()
    }

    fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move {
            engine
                .apply_system_media_artwork(handle, width, height, rgba)
                .await
        }
        .boxed()
    }

    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            mutate_audio(&audio_mutation, || audio_capture.mailbox().enable_scene(handle, enabled)).await
        }.boxed()
    }

    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()> {
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            mutate_audio(&audio_mutation, || audio_capture.mailbox().update_demand(demand)).await
        }.boxed()
    }

    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_scaling_mode(handle, mode).await }.boxed()
    }

    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_scaling_factor(handle, factor).await }.boxed()
    }

    fn set_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_framing(handle, framing).await }.boxed()
    }

    fn preview_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.preview_framing(handle, framing).await }.boxed()
    }

    fn preview_property_override(
        &self,
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
    ) -> EngineFuture<PropertyPreview> {
        let engine = self.engine.clone();
        async move {
            engine
                .preview_property_override(handle, scene_path, flat_json)
                .await
        }
        .boxed()
    }

    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_fps(handle, fps).await }.boxed()
    }

    fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_render_scale(handle, scale).await }.boxed()
    }

    fn poll_mouse_position(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.poll_mouse_position().await }.boxed()
    }

    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_position(handle, x, y).await }.boxed()
    }

    // Pointer buttons and hover reach the engine as they are; the engine
    // decides which scene and display they belong to.
    fn set_mouse_button(&self, handle: SceneHandle, button: u32, pressed: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_button(handle, button, pressed).await }.boxed()
    }

    // Entering and leaving reach the engine the same way as buttons.
    // Nothing is filtered or coalesced on the way.
    // The engine owns what a scene does with them.
    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_entered(handle, entered).await }.boxed()
    }

    // The window call is forwarded as it is and the engine's answer returned
    // untouched. Only an assignment can close scenes, so only
    // `set_wallpaper_for_display` prunes capture ownership.
    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        let engine = self.engine.clone();
        async move {
            let opened = engine.create_window_for_display(selector).await;
            opened
        }
        .boxed()
    }

    // A new assignment can close scenes, so capture ownership is pruned under
    // the same lock that serialised the change.
    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        let (engine, capture, lock) = (
            self.engine.clone(),
            self.audio_capture.clone(),
            self.audio_mutation.clone(),
        );
        async move {
            mutate_scenes_and_prune(
                &lock,
                || engine.set_wallpaper_for_display(selector, assignment),
                || capture.mailbox().prune_scenes(),
            )
            .await
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        register_first_frame_callback(&self.readiness, callback, |wrapped| {
            self.engine.set_first_frame_callback(wrapped);
        });
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.engine.set_pointer_consumer_callback(callback);
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        self.engine.set_pointer_activity_callback(callback);
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        self.engine.probe_pointer()
    }

    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        self.engine.set_user_shortcut_callback(callback);
    }

    fn scene_requires_audio(&self, handle: SceneHandle) -> bool {
        self.engine.scene_requires_audio(handle)
    }

    fn set_audio_requirement_callback(
        &self,
        callback: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
        self.engine.set_audio_requirement_callback(callback);
    }
}

/// Shared by the production worker and device-free capture regressions.
/// A web-only session must take the same authorization path as a scene.
pub(crate) fn apply_audio_capture_demand<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    demand: AudioCaptureDemand,
) -> Result<(), String> {
    if demand.external_consumers && !demand.suspended
        && !controller.has_permission().map_err(|error| error.to_string())?
        && !controller.request_permission().map_err(|error| error.to_string())?
    {
        return Err("System audio capture permission was not granted.".to_string());
    }
    controller.set_demand(demand.suspended, demand.external_consumers)
        .map_err(|error| format!("Audio response could not update: {error}. Check WallpaperMachine in System Settings > Privacy & Security > Screen & System Audio Recording."))
}

/// What the audio worker does next about a changed output device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RestartAction {
    /// Nothing more to do: the tap was rebuilt, was not running, or the
    /// request was superseded.
    Done,
    /// The tap could not be started; try again after `delay`.
    RetryIn {
        delay: Duration,
        generation: u64,
        attempt: usize,
    },
    /// Every retry failed. The next scene or demand change starts the tap.
    GaveUp,
}

/// Which output-device change a scheduled retry belongs to. A newer change
/// starts a new generation, so a retry left over from an older one is ignored
/// instead of tearing down a tap the newer change has since rebuilt.
#[derive(Debug, Default)]
pub(crate) struct AudioRestartState {
    generation: u64,
}

impl AudioRestartState {
    fn begin(&mut self) -> u64 {
        self.generation += 1;
        self.generation
    }

    fn is_current(&self, generation: u64) -> bool {
        self.generation == generation
    }
}

/// The default output device changed: rebuild the tap if one is running.
///
/// Shared by the production worker and device-free regressions, like
/// [`apply_audio_capture_demand`].
pub(crate) fn handle_output_device_change<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    state: &mut AudioRestartState,
) -> RestartAction {
    let generation = state.begin();
    if controller.is_capturing() {
        log::info!(
            "[wallpaper-core audio] default output device changed; rebuilding the system audio tap"
        );
    } else {
        log::info!(
            "[wallpaper-core audio] default output device changed; no system audio tap is running"
        );
    }
    attempt_audio_restart(controller, generation, 0)
}

/// A retry scheduled by an earlier [`RestartAction::RetryIn`] came due.
///
/// It does nothing when a newer device change has started, or when capture is
/// running again because a scene or demand change started it in the meantime.
pub(crate) fn handle_audio_restart_retry<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    state: &AudioRestartState,
    generation: u64,
    attempt: usize,
) -> RestartAction {
    if !state.is_current(generation) || controller.is_capturing() {
        return RestartAction::Done;
    }
    attempt_audio_restart(controller, generation, attempt)
}

fn attempt_audio_restart<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    generation: u64,
    attempt: usize,
) -> RestartAction {
    match controller.restart_capture() {
        Ok(RestartOutcome::Restarted | RestartOutcome::NotRunning) => RestartAction::Done,
        Err(error) => match RESTART_RETRY_DELAYS.get(attempt) {
            Some(&delay) => {
                log::warn!(
                    "[wallpaper-core audio] system audio tap rebuild attempt {} failed: {error}; retrying in {} ms",
                    attempt + 1,
                    delay.as_millis()
                );
                RestartAction::RetryIn { delay, generation, attempt: attempt + 1 }
            }
            None => {
                log::warn!(
                    "[wallpaper-core audio] system audio tap could not be rebuilt after {} attempts: {error}; it restarts at the next scene or demand change",
                    attempt + 1
                );
                RestartAction::GaveUp
            }
        },
    }
}

/// Asks the worker to try again after `delay`, from a short-lived thread so the
/// worker itself never sleeps.
pub(super) fn schedule_audio_restart(action: RestartAction, events: &CaptureEvents) {
    let RestartAction::RetryIn { delay, generation, attempt } = action else {
        return;
    };
    let events = events.clone();
    let spawned = thread::Builder::new()
        .name("wallpaper-bridge-audio-retry".to_string())
        .spawn(move || {
            thread::sleep(delay);
            events.retry_restart(generation, attempt);
        });
    if let Err(error) = spawned {
        log::warn!("[wallpaper-core audio] could not schedule a system audio tap retry: {error}");
    }
}

/// Starts an output-device watcher for the worker. Without one the tap is
/// still started and stopped as before; only the rebuild on a device change is
/// lost.
fn watch_output_device(events: CaptureEvents) -> Option<OutputDeviceWatcher> {
    let on_change = Arc::new(move || {
        events.output_changed();
    });
    match OutputDeviceWatcher::start(on_change) {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            log::warn!(
                "[wallpaper-core audio] could not watch the default output device: {error}; the system audio tap is not rebuilt when it changes"
            );
            None
        }
    }
}

/// Holds the output-device watcher exactly while capture is wanted.
///
/// A watcher is a subscriber and a parked thread, and every default-output
/// change wakes it and writes a log line. A process whose wallpapers never read
/// audio has no tap to rebuild, so it carries none: one starts when capture
/// becomes wanted and is dropped when it no longer is, which also keeps the
/// HAL listener unregistered until audio is first used.
///
/// It acts only when "wanted" changes. A start that failed (already logged) is
/// therefore not attempted again on every command, only the next time capture
/// is wanted after it was not.
pub(crate) struct OutputWatchGate<W> {
    watcher: Option<W>,
    wanted: bool,
}

impl<W> Default for OutputWatchGate<W> {
    fn default() -> Self {
        Self { watcher: None, wanted: false }
    }
}

impl<W> OutputWatchGate<W> {
    /// Brings the watcher in line with whether capture is wanted now. `start`
    /// runs only on the change to wanted.
    pub(crate) fn sync(&mut self, wanted: bool, start: impl FnOnce() -> Option<W>) {
        if wanted == self.wanted {
            return;
        }
        self.wanted = wanted;
        self.watcher = if wanted { start() } else { None };
    }

    /// Whether a watcher is running.
    #[cfg(test)]
    pub(crate) fn is_watching(&self) -> bool {
        self.watcher.is_some()
    }
}

/// Ends the worker thread when the last handle to it goes away. The worker
/// holds a sender of its own for the device watcher and retries, so the
/// channel closing is no longer the signal.
struct AudioWorkerLifetime(CaptureEvents);

impl Drop for AudioWorkerLifetime {
    fn drop(&mut self) {
        self.0.finish();
    }
}

#[derive(Clone)]
pub(super) struct OwnedCaptureLane {
    mailbox: CaptureMailbox,
    _lifetime: Arc<AudioWorkerLifetime>,
}

impl OwnedCaptureLane {
    fn new(engine: WallpaperEngine) -> Self {
        Self::from_mailbox(start_capture_lane(PlatformCaptureAssembly {
            engine,
            output_watch: OutputWatchGate::default(),
            restart: AudioRestartState::default(),
        }))
    }

    pub(super) fn from_mailbox(mailbox: CaptureMailbox) -> Self {
        let lifetime = Arc::new(AudioWorkerLifetime(mailbox.events()));
        Self { mailbox, _lifetime: lifetime }
    }

    pub(super) fn mailbox(&self) -> &CaptureMailbox {
        // Borrow the whole owner in async closures. Direct field capture could
        // otherwise leave the lifetime guard outside an unpolled request future.
        &self.mailbox
    }
}

pub(super) fn retain_capture_live<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    live: &[DisplaySnapshotEntry],
) -> Result<Vec<SceneHandle>, String> {
    let handles: Vec<_> = live.iter().filter_map(|display| display.handle).collect();
    controller.retain_scenes(&handles).map_err(|error| error.to_string())?;
    Ok(handles)
}

struct PlatformCaptureAssembly {
    engine: WallpaperEngine,
    output_watch: OutputWatchGate<OutputDeviceWatcher>,
    restart: AudioRestartState,
}

impl CaptureAssembly for PlatformCaptureAssembly {
    type Backend = PlatformAudioCaptureBackend;

    fn make_controller(&mut self) -> Result<AudioCaptureController<Self::Backend>, String> {
        PlatformAudioCaptureBackend::new()
            .map(|backend| AudioCaptureController::new(Arc::new(self.engine.clone()), backend))
            .map_err(|error| error.to_string())
    }

    fn retain_live(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
    ) -> Result<Vec<SceneHandle>, String> {
        retain_capture_live(controller, &self.engine.display_snapshot())
    }

    fn apply_demand(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        demand: AudioCaptureDemand,
    ) -> Result<(), String> {
        apply_audio_capture_demand(controller, demand)
    }

    fn output_changed(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        events: &CaptureEvents,
    ) {
        let action = handle_output_device_change(controller, &mut self.restart);
        schedule_audio_restart(action, events);
    }

    fn retry_restart(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        generation: u64,
        attempt: usize,
        events: &CaptureEvents,
    ) {
        let action = handle_audio_restart_retry(controller, &self.restart, generation, attempt);
        schedule_audio_restart(action, events);
    }

    fn sync_watch(&mut self, wanted: bool, events: &CaptureEvents) {
        self.output_watch.sync(wanted, || watch_output_device(events.clone()));
    }

    fn stop_watch(&mut self) {
        self.output_watch.sync(false, || None);
    }
}

#[cfg(test)]
#[derive(Clone)]
pub struct FakeEngineFacade {
    audio_capture_demands: Observation<AudioCaptureDemand>,
    media_calls: Observation<(SceneHandle, bool, wallpaper_core::media::MediaPollResult)>,
    calls: Observation<Vec<SceneDesc>>,
    rendered_scenes: Arc<ArcSwap<Vec<SceneDesc>>>,
    snapshot: Arc<ArcSwap<Vec<DisplaySnapshotEntry>>>,
    /// Serializes the port's read/mutate/publish transaction with other row updates.
    snapshot_mutation: Arc<std::sync::Mutex<()>>,
    pointer_consumer: Arc<std::sync::Mutex<PointerConsumerObserver>>,
    /// Held, so a test can report a press the way the engine would. Keeping
    /// it also keeps whatever the caller handed over alive, which is the whole
    /// point of installing it.
    user_shortcut: Callable<wallpaper_core::UserShortcutObserverCallback>,
    /// What the fake renderers report about reading system audio.
    audio_requirement: Arc<std::sync::Mutex<FakeAudioRequirement>>,
    snapshot_after_refresh: Arc<ArcSwap<Option<Vec<DisplaySnapshotEntry>>>>,
    paused_calls: Observation<bool>,
    display_paused_calls: Observation<(u32, bool)>,
    /// Every parking list the bridge handed over, by display.
    parked_scene_calls: Observation<(u32, Vec<String>)>,
    /// What `scene_windows` reports; a test scripts it.
    scene_windows: Arc<ArcSwap<Vec<SceneWindowEntry>>>,
    /// Every pause value applied to a rendered scene, by its display, in the
    /// order the fake applied them. A global resume that briefly restarts a
    /// still-hidden display shows up here as a `false` for that display.
    scene_pause_log: Observation<(u32, bool)>,
    audio_volume_calls: Observation<(SceneHandle, f32)>,
    audio_muted_calls: Observation<(SceneHandle, bool)>,
    audio_response_calls: Observation<(SceneHandle, bool)>,
    media_integration_calls: Observation<(SceneHandle, bool)>,
    media_event_calls: Observation<(SceneHandle, String)>,
    media_artwork_calls: Observation<(SceneHandle, u32, u32, usize)>,
    audio_capture_calls: Observation<(SceneHandle, bool)>,
    audio_capture_suspend_calls: Observation<bool>,
    audio_capture_suspended: Reading<bool>,
    scaling_mode_calls: Observation<(SceneHandle, ScalingMode)>,
    scaling_factor_calls: Observation<(SceneHandle, f64)>,
    framing_calls: Observation<(SceneHandle, SceneFraming)>,
    preview_framing_calls: Observation<(SceneHandle, SceneFraming)>,
    preview_property_calls: Observation<(SceneHandle, String)>,
    /// Property previews the fake engine declined because the scene on the
    /// handle draws another wallpaper: the handle and the project file the
    /// document was made for.
    declined_property_previews: Observation<(SceneHandle, String)>,
    /// What each fake renderer was last shown by a property preview, by its
    /// display, like the real renderer's own record: gone when a reconcile opens
    /// the display's scene afresh or loads it again.
    shown_property_documents: Arc<std::sync::Mutex<std::collections::HashMap<u32, String>>>,
    fps_calls: Observation<(SceneHandle, u32)>,
    render_scale_calls: Observation<(SceneHandle, f32)>,
    scene_optimization_calls: Observation<bool>,
    scene_on_demand_calls: Observation<bool>,
    scene_video_plane_sampling_calls: Observation<bool>,
    scene_resolution_calls: Observation<SceneResolution>,
    scene_runtime_reports: Reading<Vec<SceneRuntimeReport>>,
    /// Scripted snapshots retain the final sample; `None` reads the live state.
    display_snapshot_script: Reading<Option<Vec<DisplaySnapshotEntry>>>,
    recover_calls: Observation<(u32, RecoveryReason)>,
    recover_result: Reading<Option<Result<RecoveryOutcome, String>>>,
    audio_spectrum: Reading<Option<AudioSpectrum128>>,
    mouse_poll_calls: Observation<()>,
    mouse_polls_seen: Arc<std::sync::atomic::AtomicUsize>,
    mouse_poll_count: Arc<std::sync::atomic::AtomicUsize>,
    pointer_activity: Arc<std::sync::Mutex<PointerActivityObserver>>,
    pointer_probe: Reading<wallpaper_core::PointerProbe>,
    pointer_probe_count: Arc<std::sync::atomic::AtomicUsize>,
    mouse_input: Reading<(f64, f64)>,
    mouse_samples: Observation<(f64, f64)>,
    mouse_position_calls: Observation<(SceneHandle, f64, f64)>,
    mouse_button_calls: Observation<(SceneHandle, u32, bool)>,
    mouse_entered_calls: Observation<(SceneHandle, bool)>,
    window_create_calls: Observation<DisplaySelector>,
    wallpaper_calls: Observation<(DisplaySelector, WallpaperAssignment)>,
    first_frame_callback: Callable<FirstFrameCallback>,
    counters_enabled: Reading<bool>,
    /// Values the fake renderer reports. The real increments live in the
    /// renderer; this only lets a bridge test drive the reporting path.
    surface_counters: Reading<Vec<RendererSurfaceCounters>>,
    shared_counters: Reading<Vec<u64>>,
    control: Control<ControlledOperation>,
    failures: Failures<ControlledOperation>,
}

#[cfg(test)]
struct PointerActivityObserver {
    callback: Callable<wallpaper_core::PointerActivityCallback>,
    monitor_gap: bool,
}

/// The fake renderers' audio reports. Unless a test says otherwise, every
/// scene reads audio, which is what the audio-response tests are about; a test
/// of the requirement itself starts from the real engine's `false`.
#[cfg(test)]
struct FakeAudioRequirement {
    scenes_start_without_audio: bool,
    reported: std::collections::HashMap<SceneHandle, bool>,
    callback: Callable<wallpaper_core::AudioRequirementCallback>,
}

#[cfg(test)]
impl FakeAudioRequirement {
    fn requires_audio(&self, handle: SceneHandle) -> bool {
        self.reported.get(&handle).copied().unwrap_or(!self.scenes_start_without_audio)
    }
}

/// The engine's rule: a presenting, interactive scene.
#[cfg(test)]
fn is_pointer_consumer(display: &DisplaySnapshotEntry) -> bool {
    display.handle.is_some() && display.accepts_pointer_input && !display.paused
}

#[cfg(test)]
struct PointerConsumerObserver {
    callback: Callable<wallpaper_core::PointerConsumerCallback>,
    has_consumers: bool,
}

#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum ControlledOperation {
    Reconcile,
    Capture,
    Mouse,
    Refresh,
    Pause,
    DisplayPause,
    Suspend,
    DisableCapture,
    Close,
    Framing,
    PropertyPreview,
    RenderScale,
}

#[cfg(test)]
fn engine_fault(fault: Fault) -> EngineError {
    match fault.category {
        FaultCategory::InvalidInput => EngineError::InvalidInput(fault.message),
        FaultCategory::Platform => EngineError::Platform(fault.message),
        FaultCategory::Render => EngineError::Render(fault.message),
    }
}

#[cfg(test)]
pub struct ReconcileBlock {
    hold: Hold,
}

#[cfg(test)]
pub struct ReconcileDone {
    completion: Completion,
}

#[cfg(test)]
struct FakeDirectAccess;

#[cfg(test)]
impl controlled_support::DirectAccess<DisplaySnapshotEntry, SceneHandle, SceneTemplate> for FakeDirectAccess {
    fn handle(&self, row: &DisplaySnapshotEntry) -> Option<SceneHandle> {
        row.handle
    }

    fn direct_mut<'a>(&self, row: &'a mut DisplaySnapshotEntry) -> Option<&'a mut SceneTemplate> {
        match row.assignment.as_mut() {
            Some(WallpaperAssignment::Direct(template)) => Some(template),
            _ => None,
        }
    }
}

#[cfg(test)]
impl controlled_support::ScenePort<SceneDesc, DisplaySnapshotEntry, SceneResult> for FakeEngineFacade {
    fn rendered(&self) -> Vec<SceneDesc> {
        self.rendered_scenes()
    }

    fn result(&self, index: usize, scene: &SceneDesc) -> SceneResult {
        SceneResult::new(scene.display.display_id, SceneHandle::new(index as u64 + 1), 0)
    }

    fn retain_preview_memory(&self, before: &[SceneDesc], after: &[SceneDesc]) {
        self.keep_previewed_documents(before, after);
    }

    fn replace_rendered(&self, scenes: Vec<SceneDesc>) {
        self.rendered_scenes.store(Arc::new(scenes));
    }

    fn prepared_refresh(&self) -> Option<Vec<DisplaySnapshotEntry>> {
        self.snapshot_after_refresh.load_full().as_ref().clone()
    }

    fn current_rows(&self) -> Vec<DisplaySnapshotEntry> {
        self.snapshot.load_full().as_ref().clone()
    }

    fn publish_rows(&self, rows: Vec<DisplaySnapshotEntry>) {
        // Refresh and close own the row transaction while the helper runs.
        self.publish_snapshot_locked(|_| rows);
    }

    fn clear_preview_memory(&self) {
        self.shown_property_documents.lock().unwrap_or_else(|error| error.into_inner()).clear();
    }

    fn remove_live_assignment(&self, row: &mut DisplaySnapshotEntry) {
        row.handle = None;
        row.accepts_pointer_input = false;
        row.assignment = None;
    }
}

#[cfg(test)]
impl Default for FakeEngineFacade {
    fn default() -> Self {
        Self {
            audio_capture_demands: Observation::new(),
            media_calls: Observation::new(),
            calls: Observation::new(),
            rendered_scenes: Default::default(),
            snapshot: Default::default(),
            pointer_consumer: Default::default(),
            user_shortcut: Callable::new(),
            audio_requirement: Default::default(),
            snapshot_after_refresh: Default::default(),
            paused_calls: Observation::new(),
            display_paused_calls: Observation::new(),
            parked_scene_calls: Observation::new(),
            scene_windows: Default::default(),
            scene_pause_log: Observation::new(),
            audio_volume_calls: Observation::new(),
            audio_muted_calls: Observation::new(),
            audio_response_calls: Observation::new(),
            media_integration_calls: Observation::new(),
            media_event_calls: Observation::new(),
            media_artwork_calls: Observation::new(),
            audio_capture_calls: Observation::new(),
            audio_capture_suspend_calls: Observation::new(),
            audio_capture_suspended: Reading::new(Default::default()),
            scaling_mode_calls: Observation::new(),
            scaling_factor_calls: Observation::new(),
            framing_calls: Observation::new(),
            preview_framing_calls: Observation::new(),
            preview_property_calls: Observation::new(),
            declined_property_previews: Observation::new(),
            shown_property_documents: Default::default(),
            fps_calls: Observation::new(),
            render_scale_calls: Observation::new(),
            scene_optimization_calls: Observation::new(),
            scene_on_demand_calls: Observation::new(),
            scene_video_plane_sampling_calls: Observation::new(),
            scene_resolution_calls: Observation::new(),
            scene_runtime_reports: Reading::new(Default::default()),
            display_snapshot_script: Reading::new(Default::default()),
            recover_calls: Observation::new(),
            recover_result: Reading::new(Default::default()),
            audio_spectrum: Reading::new(Default::default()),
            mouse_poll_calls: Observation::new(),
            mouse_polls_seen: Default::default(),
            pointer_activity: Default::default(),
            pointer_probe: Reading::new(Default::default()),
            pointer_probe_count: Default::default(),
            mouse_input: Reading::new(Default::default()),
            mouse_samples: Observation::new(),
            mouse_position_calls: Observation::new(),
            mouse_button_calls: Observation::new(),
            mouse_entered_calls: Observation::new(),
            window_create_calls: Observation::new(),
            wallpaper_calls: Observation::new(),
            first_frame_callback: Callable::new(),
            counters_enabled: Reading::new(Default::default()),
            surface_counters: Reading::new(Default::default()),
            shared_counters: Reading::new(Default::default()),
            control: Control::new(),
            failures: Failures::new(),
            snapshot_mutation: Default::default(),
            mouse_poll_count: Default::default(),
        }
    }
}

#[cfg(test)]
impl Default for PointerActivityObserver {
    fn default() -> Self {
        Self { callback: Callable::new(), monitor_gap: false }
    }
}

#[cfg(test)]
impl Default for PointerConsumerObserver {
    fn default() -> Self {
        Self { callback: Callable::new(), has_consumers: false }
    }
}

#[cfg(test)]
impl Default for FakeAudioRequirement {
    fn default() -> Self {
        Self {
            scenes_start_without_audio: false,
            reported: Default::default(),
            callback: Callable::new(),
        }
    }
}

#[cfg(test)]
impl ReconcileBlock {
    #[must_use]
    pub fn wait_until_blocked(&self, timeout: Duration) -> bool {
        self.hold.wait_entered(timeout)
    }

    pub fn release(&self) {
        self.hold.release();
    }
}

#[cfg(test)]
impl ReconcileDone {
    #[must_use]
    pub fn wait(self, timeout: Duration) -> bool {
        self.completion.wait(timeout)
    }
}

#[cfg(test)]
impl FakeEngineFacade {
    /// What the scene on `handle` draws now: the descriptor the last reconcile
    /// gave the display the snapshot puts the handle on. Like the real engine's
    /// handle, it stays with the display when the wallpaper on it changes.
    fn scene_behind(&self, handle: SceneHandle) -> Option<SceneDesc> {
        let display_id = self
            .snapshot
            .load()
            .iter()
            .find(|entry| entry.handle == Some(handle))?
            .desc
            .display_id;
        self.rendered_scenes
            .load()
            .iter()
            .find(|scene| scene.display.display_id == display_id)
            .cloned()
    }

    /// The engine replaces a display's renderer on its own, as a surface
    /// recovery after a wake or a failed frame does: nothing is reconciled and
    /// nobody is told, and the new renderer shows what the scene was loaded with.
    pub fn rebuild_renderer_of(&self, display_id: u32) {
        self.shown_property_documents
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&display_id);
    }

    /// Forgets what a display's renderer was shown when a reconcile gives it a
    /// scene the engine opens afresh or loads again, which is what a descriptor
    /// that is not the same wallpaper means. A scene the engine keeps keeps it.
    fn keep_previewed_documents(&self, before: &[SceneDesc], after: &[SceneDesc]) {
        self.shown_property_documents
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .retain(|display_id, _| {
                let find = |scenes: &'_ [SceneDesc]| {
                    scenes
                        .iter()
                        .find(|scene| scene.display.display_id == *display_id)
                        .cloned()
                };
                match (find(before), find(after)) {
                    (Some(before), Some(after)) => before.same_wallpaper(&after),
                    _ => false,
                }
            });
    }

    /// Reports a press the way the engine does when a wallpaper calls
    /// `engine.openUserShortcut`. Returns false when nothing is installed,
    /// which is the failure this exists to catch.
    #[must_use]
    pub fn report_user_shortcut(&self, handle: SceneHandle, property: &str, value: &str) -> bool {
        let Some(callback) = self.user_shortcut.capture() else { return false };
        callback(handle, property.to_owned(), value.to_owned());
        true
    }

    /// Makes an unreported scene read `false`, as a real renderer does until
    /// its scene reports that it reads audio.
    pub fn scenes_start_without_audio(&self) {
        self.audio_requirement
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .scenes_start_without_audio = true;
    }

    /// Reports a scene's audio requirement the way the engine does when its
    /// renderer reports: the observer hears it only when it changed.
    pub fn report_requires_audio(&self, handle: SceneHandle, requires_audio: bool) {
        let mut state = self.audio_requirement.lock().unwrap_or_else(|error| error.into_inner());
        let changed = state.requires_audio(handle) != requires_audio;
        let _ = state.reported.insert(handle, requires_audio);
        if changed {
            if let Some(callback) = state.callback.capture() {
                callback(handle, requires_audio);
            }
        }
    }

    pub fn media_calls(&self) -> Vec<(SceneHandle, bool, wallpaper_core::media::MediaPollResult)> {
        self.media_calls.snapshot()
    }
    #[must_use]
    pub fn calls(&self) -> Vec<Vec<SceneDesc>> {
        self.calls.snapshot()
    }

    #[must_use]
    pub fn reconcile_call_count(&self) -> usize {
        self.calls.len()
    }

    #[must_use]
    pub fn rendered_scenes(&self) -> Vec<SceneDesc> {
        self.rendered_scenes.load_full().as_ref().clone()
    }

    #[must_use]
    pub fn audio_capture_demands(&self) -> Vec<AudioCaptureDemand> {
        self.audio_capture_demands.snapshot()
    }

    #[must_use]
    pub fn audio_capture_suspended(&self) -> bool {
        self.audio_capture_suspended.read()
    }

    pub fn set_snapshot(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        self.publish_snapshot(|_| snapshot);
    }

    fn publish_snapshot(&self, update: impl FnOnce(&[DisplaySnapshotEntry]) -> Vec<DisplaySnapshotEntry>) {
        let _mutation = self.snapshot_mutation.lock().unwrap_or_else(|error| error.into_inner());
        self.publish_snapshot_locked(update);
    }

    fn publish_snapshot_locked(&self, update: impl FnOnce(&[DisplaySnapshotEntry]) -> Vec<DisplaySnapshotEntry>) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        let previous = self.snapshot.load_full();
        let snapshot = Arc::new(update(previous.as_ref()));
        let has_consumers = snapshot.iter().any(is_pointer_consumer);
        // The engine asks for a sample when a presenting scene is new or
        // resumed, since its pointer delivery starts empty.
        let consumer_joined = snapshot.iter().filter(|display| is_pointer_consumer(display)).any(|display| {
            !previous.iter().any(|old| is_pointer_consumer(old) && old.handle == display.handle)
        });
        self.snapshot.store(snapshot);
        if observer.has_consumers != has_consumers {
            observer.has_consumers = has_consumers;
            if let Some(callback) = observer.callback.capture() {
                callback(has_consumers);
            }
        }
        drop(observer);
        if consumer_joined {
            self.report_pointer_activity(wallpaper_core::PointerActivity::Input);
        }
    }

    /// Reports pointer input the way the engine's OS event monitor does.
    pub fn simulate_pointer_input(&self) {
        self.report_pointer_activity(wallpaper_core::PointerActivity::Input);
    }

    /// Opens or closes the event-monitor gap, as app activation would.
    pub fn set_pointer_monitor_gap(&self, gap: bool) {
        let mut observer = self.pointer_activity.lock().unwrap_or_else(|error| error.into_inner());
        observer.monitor_gap = gap;
        if let Some(callback) = observer.callback.capture() {
            callback(wallpaper_core::PointerActivity::MonitorGap(gap));
        }
    }

    fn report_pointer_activity(&self, activity: wallpaper_core::PointerActivity) {
        let observer = self.pointer_activity.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(callback) = observer.callback.capture() {
            callback(activity);
        }
    }

    /// What the next cursor probe reads.
    pub fn set_pointer_probe(&self, probe: wallpaper_core::PointerProbe) {
        self.pointer_probe.set(probe);
    }

    #[must_use]
    pub fn pointer_probe_count(&self) -> usize {
        self.pointer_probe_count.load(std::sync::atomic::Ordering::Acquire)
    }

    #[must_use]
    pub fn wait_for_pointer_probes(&self, count: usize, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if self.pointer_probe_count() >= count {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// Mirrors the engine: a scene's pause state is published with the
    /// snapshot, which is what stops or starts pointer sampling for it.
    fn publish_display_pause(&self, paused_for: impl Fn(u32) -> Option<bool>) {
        self.publish_snapshot(|current| {
            let mut next = current.to_vec();
            for display in &mut next {
                if display.handle.is_some() {
                    if let Some(paused) = paused_for(display.desc.display_id) {
                        display.paused = paused;
                    }
                }
            }
            next
        });
    }

    pub fn set_snapshot_after_refresh(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        let _mutation = self.snapshot_mutation.lock().unwrap_or_else(|error| error.into_inner());
        self.snapshot_after_refresh.store(Arc::new(Some(snapshot)));
    }

    #[must_use]
    pub fn paused_calls(&self) -> Vec<bool> {
        self.paused_calls.snapshot()
    }

    pub async fn wait_for_pause_trace(
        &self,
        expected: &[bool],
        bound: std::time::Duration,
    ) -> bool {
        const INTERVAL: std::time::Duration = std::time::Duration::from_millis(2);
        let started = tokio::time::Instant::now();
        if self.paused_calls().as_slice() == expected {
            return true;
        }
        while started.elapsed() < bound {
            let remaining = bound.saturating_sub(started.elapsed());
            tokio::time::sleep(remaining.min(INTERVAL)).await;
            if started.elapsed() >= bound {
                break;
            }
            if self.paused_calls().as_slice() == expected {
                return true;
            }
        }
        false
    }

    #[must_use]
    pub fn display_paused_calls(&self) -> Vec<(u32, bool)> {
        self.display_paused_calls.snapshot()
    }

    #[must_use]
    pub fn parked_scene_calls(&self) -> Vec<(u32, Vec<String>)> {
        self.parked_scene_calls.snapshot()
    }

    /// Makes `scene_windows` report `windows` from now on.
    pub fn set_scene_windows(&self, windows: Vec<SceneWindowEntry>) {
        self.scene_windows.store(Arc::new(windows));
    }

    #[must_use]
    pub fn scene_pause_log(&self) -> Vec<(u32, bool)> {
        self.scene_pause_log.snapshot()
    }

    pub fn set_renderer_counters(
        &self,
        surfaces: Vec<RendererSurfaceCounters>,
        shared: Vec<u64>,
    ) {
        self.surface_counters.set(surfaces);
        self.shared_counters.set(shared);
    }

    #[must_use]
    pub fn renderer_counters_enabled(&self) -> bool {
        self.counters_enabled.read()
    }

    #[must_use]
    pub fn audio_volume_calls(&self) -> Vec<(SceneHandle, f32)> {
        self.audio_volume_calls.snapshot()
    }

    #[must_use]
    pub fn audio_muted_calls(&self) -> Vec<(SceneHandle, bool)> {
        self.audio_muted_calls.snapshot()
    }

    #[must_use]
    pub fn audio_response_calls(&self) -> Vec<(SceneHandle, bool)> {
        self.audio_response_calls.snapshot()
    }

    #[must_use]
    pub fn media_integration_calls(&self) -> Vec<(SceneHandle, bool)> {
        self.media_integration_calls.snapshot()
    }

    #[must_use]
    pub fn media_event_calls(&self) -> Vec<(SceneHandle, String)> {
        self.media_event_calls.snapshot()
    }

    #[must_use]
    pub fn media_artwork_calls(&self) -> Vec<(SceneHandle, u32, u32, usize)> {
        self.media_artwork_calls.snapshot()
    }

    #[must_use]
    pub fn audio_capture_calls(&self) -> Vec<(SceneHandle, bool)> {
        self.audio_capture_calls.snapshot()
    }

    #[must_use]
    pub fn audio_capture_suspend_calls(&self) -> Vec<bool> {
        self.audio_capture_suspend_calls.snapshot()
    }

    /// Every scene-optimization change the bridge pushed, in order.
    #[must_use]
    pub fn scene_optimization_calls(&self) -> Vec<bool> {
        self.scene_optimization_calls.snapshot()
    }

    /// Every scene on-demand change the bridge pushed, in order. A forward
    /// that never reaches the engine leaves this empty, which is what makes a
    /// missing facade delegation a test failure rather than a silent no-op.
    #[must_use]
    pub fn scene_on_demand_calls(&self) -> Vec<bool> {
        self.scene_on_demand_calls.snapshot()
    }

    /// Every direct-plane-sampling change the bridge pushed, in order.
    #[must_use]
    pub fn scene_video_plane_sampling_calls(&self) -> Vec<bool> {
        self.scene_video_plane_sampling_calls.snapshot()
    }

    /// Every 2D scene resolution the bridge pushed, in order.
    #[must_use]
    pub fn scene_resolution_calls(&self) -> Vec<SceneResolution> {
        self.scene_resolution_calls.snapshot()
    }

    /// What the next [`EngineFacade::scene_runtime_reports`] read returns.
    /// Left empty the fake reports nothing observed, so a test has to opt in
    /// to a live state rather than getting one by default.
    pub fn set_scene_runtime_reports(&self, reports: Vec<SceneRuntimeReport>) {
        self.scene_runtime_reports.set(reports);
    }

    /// Makes the next reads of the scene reports return `readings` in order,
    /// one per read, and then the last of them for every read after. The
    /// stored value is used again only once the script is empty.
    pub fn script_scene_runtime_reports(&self, readings: Vec<Vec<SceneRuntimeReport>>) {
        self.scene_runtime_reports.script(readings);
    }

    /// As [`Self::script_scene_runtime_reports`], for the display snapshot.
    pub fn script_display_snapshots(&self, readings: Vec<Vec<DisplaySnapshotEntry>>) {
        self.display_snapshot_script.script(readings.into_iter().map(Some).collect());
    }

    /// Every surface repair the engine was asked for, in order.
    #[must_use]
    pub fn recover_calls(&self) -> Vec<(u32, RecoveryReason)> {
        self.recover_calls.snapshot()
    }

    /// What every later [`EngineFacade::recover_surface`] call answers. Left
    /// unset the fake reports a repair by a surface reconfigure.
    pub fn set_recover_result(&self, result: Result<RecoveryOutcome, String>) {
        self.recover_result.set(Some(result));
    }

    /// Sets what the next spectrum read returns. `None` is "no analysis yet".
    pub fn set_audio_spectrum(&self, spectrum: Option<AudioSpectrum128>) {
        self.audio_spectrum.set(spectrum);
    }

    #[must_use]
    pub fn scaling_mode_calls(&self) -> Vec<(SceneHandle, ScalingMode)> {
        self.scaling_mode_calls.snapshot()
    }

    #[must_use]
    pub fn scaling_factor_calls(&self) -> Vec<(SceneHandle, f64)> {
        self.scaling_factor_calls.snapshot()
    }

    /// Every position the fake was asked to apply live, in order. A call that
    /// was refused is in here too: it is what the bridge asked for.
    #[must_use]
    pub fn framing_calls(&self) -> Vec<(SceneHandle, SceneFraming)> {
        self.framing_calls.snapshot()
    }

    /// Every position the fake was asked to show for a drag in progress, in
    /// order. A preview moves nothing the fake stores, which is the point: it
    /// is a call the bridge makes, not a change of the scene's position.
    #[must_use]
    pub fn preview_framing_calls(&self) -> Vec<(SceneHandle, SceneFraming)> {
        self.preview_framing_calls.snapshot()
    }

    /// Every property document the fake renderers were told to show while an
    /// edit is under way, in order, as the flat JSON the renderer would
    /// receive. A document the renderer refused is in here too: it was sent. One
    /// the engine declined because the scene draws another wallpaper
    /// ([`Self::declined_property_previews`]) and one the scene already shows
    /// are not, because the real engine does not send them either. Showing a
    /// document moves nothing the fake stores.
    #[must_use]
    pub fn preview_property_calls(&self) -> Vec<(SceneHandle, String)> {
        self.preview_property_calls.snapshot()
    }

    /// Every property preview the fake engine declined because the scene on the
    /// handle draws another wallpaper than the one the document was made for, in
    /// order, with the project file it was made for.
    #[must_use]
    pub fn declined_property_previews(&self) -> Vec<(SceneHandle, String)> {
        self.declined_property_previews.snapshot()
    }

    #[must_use]
    pub fn fps_calls(&self) -> Vec<(SceneHandle, u32)> {
        self.fps_calls.snapshot()
    }

    #[must_use]
    pub fn render_scale_calls(&self) -> Vec<(SceneHandle, f32)> {
        self.render_scale_calls.snapshot()
    }

    #[must_use]
    pub fn mouse_poll_calls(&self) -> Vec<()> {
        self.mouse_poll_calls.snapshot()
    }

    /// Waits for an engine poll the caller has not seen yet. A sample armed by
    /// an event may run before a test could install a block, so this counts
    /// polls instead of intercepting the next one.
    #[must_use]
    pub fn wait_for_unseen_mouse_poll(&self, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let seen = self.mouse_polls_seen.load(std::sync::atomic::Ordering::Acquire);
        loop {
            let count = self.mouse_poll_count.load(std::sync::atomic::Ordering::Acquire);
            if count > seen {
                self.mouse_polls_seen.store(count, std::sync::atomic::Ordering::Release);
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    pub fn set_mouse_input(&self, x: f64, y: f64) {
        self.mouse_input.set((x, y));
    }

    pub fn mouse_samples(&self) -> Vec<(f64, f64)> {
        self.mouse_samples.snapshot()
    }

    pub fn fail_next_pause(&self) {
        self.failures.set(ControlledOperation::Pause, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "pause failed".into(),
        }));
    }

    pub fn fail_next_display_pause(&self) {
        self.failures.set(ControlledOperation::DisplayPause, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "display pause failed".into(),
        }));
    }

    pub fn fail_next_suspend(&self) {
        self.failures.set(ControlledOperation::Suspend, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "audio suspend failed".into(),
        }));
    }

    pub fn fail_next_disable_capture(&self) {
        self.failures.set(ControlledOperation::DisableCapture, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "audio disable failed".into(),
        }));
    }

    /// The next live position change is refused by the renderer and leaves the
    /// running scene where it was.
    pub fn fail_next_framing(&self) {
        self.failures.set(ControlledOperation::Framing, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "framing failed".into(),
        }));
    }

    /// The next live render-scale change is refused by the renderer.
    pub fn fail_next_render_scale(&self) {
        self.failures.set(ControlledOperation::RenderScale, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "render scale failed".into(),
        }));
    }

    /// The next property document shown on a scene is refused by the
    /// renderer, which leaves the scene as it was.
    pub fn fail_next_property_preview(&self) {
        self.failures.set(ControlledOperation::PropertyPreview, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "property preview failed".into(),
        }));
    }

    pub fn fail_next_close(&self) {
        self.failures.set(ControlledOperation::Close, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "close failed".into(),
        }));
    }

    pub fn fail_next_refresh(&self) {
        self.failures.set(ControlledOperation::Refresh, FailurePolicy::Next(Fault {
            category: FaultCategory::Platform,
            message: "refresh failed after partial commit".into(),
        }));
    }

    #[must_use]
    pub fn mouse_position_calls(&self) -> Vec<(SceneHandle, f64, f64)> {
        self.mouse_position_calls.snapshot()
    }

    #[must_use]
    pub fn mouse_button_calls(&self) -> Vec<(SceneHandle, u32, bool)> {
        self.mouse_button_calls.snapshot()
    }

    #[must_use]
    pub fn mouse_entered_calls(&self) -> Vec<(SceneHandle, bool)> {
        self.mouse_entered_calls.snapshot()
    }

    #[must_use]
    pub fn window_create_calls(&self) -> Vec<DisplaySelector> {
        self.window_create_calls.snapshot()
    }

    #[must_use]
    pub fn wallpaper_calls(&self) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        self.wallpaper_calls.snapshot()
    }

    pub fn fail_reconcile_with(&self, message: impl Into<String>) {
        self.failures.set(ControlledOperation::Reconcile, FailurePolicy::Persistent(Fault {
            category: FaultCategory::Render,
            message: message.into(),
        }));
    }

    pub fn clear_reconcile_failure(&self) {
        self.failures.clear(ControlledOperation::Reconcile);
    }

    pub fn fail_audio_capture_with(&self, message: Option<String>) {
        match message {
            Some(message) => self.failures.set(ControlledOperation::Capture, FailurePolicy::Persistent(Fault {
                category: FaultCategory::Platform,
                message,
            })),
            None => self.failures.clear(ControlledOperation::Capture),
        }
    }

    #[must_use]
    pub fn block_next_reconcile(&self) -> ReconcileBlock {
        ReconcileBlock { hold: self.control.hold_next(ControlledOperation::Reconcile) }
    }

    #[must_use]
    pub fn block_next_audio_capture(&self) -> ReconcileBlock {
        ReconcileBlock { hold: self.control.hold_next(ControlledOperation::Capture) }
    }

    #[must_use]
    pub fn block_next_mouse_poll(&self) -> ReconcileBlock {
        ReconcileBlock { hold: self.control.hold_next(ControlledOperation::Mouse) }
    }

    #[must_use]
    pub fn wait_for_next_reconcile(&self) -> ReconcileDone {
        ReconcileDone {
            completion: self.control.observe_next_completion(ControlledOperation::Reconcile),
        }
    }

    fn update_direct_assignment(&self, handle: SceneHandle, update: impl Fn(&mut SceneTemplate)) {
        let _mutation = self.snapshot_mutation.lock().unwrap_or_else(|error| error.into_inner());
        let mut current = self.snapshot.load_full().as_ref().clone();
        let mut prepared = self.snapshot_after_refresh.load_full().as_ref().clone();
        controlled_support::update_direct(
            &mut current, prepared.as_mut().map(Vec::as_mut_slice), handle, &FakeDirectAccess, update,
        );
        self.snapshot.store(Arc::new(current));
        self.snapshot_after_refresh.store(Arc::new(prepared));
    }


    pub fn trigger_first_frame(&self, handle: SceneHandle) {
        if let Some(callback) = self.first_frame_callback.capture() {
            callback(handle);
        }
    }

    /// Retains the currently installed callable for an intentional late arrival.
    pub fn capture_first_frame_callback(&self) -> Option<FirstFrameCallback> {
        self.first_frame_callback.capture()
    }
}

#[cfg(test)]
impl EngineFacade for FakeEngineFacade {
    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> EngineFuture<()> {
        let fake = self.clone();
        async move { fake.media_calls.record((handle, enabled, state)); Ok(()) }.boxed()
    }
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let fake = self.clone();
        async move {
            controlled_support::reconcile(
                scenes, &fake.calls, &fake.control, ControlledOperation::Reconcile,
                &fake.failures, ControlledOperation::Reconcile, &fake,
            ).await.map_err(engine_fault)
        }.boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let _mutation = fake.snapshot_mutation.lock().unwrap_or_else(|error| error.into_inner());
            controlled_support::refresh(&fake.failures, ControlledOperation::Refresh, &fake)
                .map_err(engine_fault)
        }.boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.display_snapshot_script.read().unwrap_or_else(|| self.snapshot.load_full().as_ref().clone())
    }

    fn scene_windows(&self) -> Vec<SceneWindowEntry> {
        self.scene_windows.load_full().as_ref().clone()
    }

    fn set_parked_scenes(&self, display_id: u32, scene_paths: Vec<String>) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.parked_scene_calls.record((display_id, scene_paths));
            Ok(())
        }.boxed()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let _mutation = fake.snapshot_mutation.lock().unwrap_or_else(|error| error.into_inner());
            controlled_support::close(&fake.failures, ControlledOperation::Close, &fake)
                .map_err(engine_fault)
        }.boxed()
    }

    fn set_all_paused(&self, paused: bool, suspended_displays: Vec<u32>) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.paused_calls.record(paused);
            if let Err(fault) = fake.failures.check(ControlledOperation::Pause) {
                return Err(engine_fault(fault));
            }
            let target = |display_id: u32| paused || suspended_displays.contains(&display_id);
            fake.rendered_scenes.rcu(|scenes| {
                let mut scenes = scenes.as_ref().clone();
                for scene in &mut scenes {
                    scene.paused = target(scene.display.display_id);
                }
                scenes
            });
            for scene in fake.rendered_scenes().iter() {
                fake.scene_pause_log.record((scene.display.display_id, scene.paused));
            }
            fake.publish_display_pause(|display_id| Some(target(display_id)));
            Ok(())
        }
        .boxed()
    }

    fn set_display_paused(&self, display_id: u32, paused: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.display_paused_calls.record((display_id, paused));
            if let Err(fault) = fake.failures.check(ControlledOperation::DisplayPause) {
                return Err(engine_fault(fault));
            }
            fake.rendered_scenes.rcu(|scenes| {
                let mut scenes = scenes.as_ref().clone();
                for scene in &mut scenes {
                    if scene.display.display_id == display_id {
                        scene.paused = paused;
                    }
                }
                scenes
            });
            if fake.rendered_scenes().iter().any(|scene| scene.display.display_id == display_id) {
                fake.scene_pause_log.record((display_id, paused));
            }
            fake.publish_display_pause(|id| (id == display_id).then_some(paused));
            Ok(())
        }
        .boxed()
    }

    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.counters_enabled.set(enabled);
        Ok(())
    }

    fn renderer_counters(&self) -> EngineFuture<(Vec<RendererSurfaceCounters>, Vec<u64>)> {
        let fake = self.clone();
        async move {
            Ok((
                fake.surface_counters.read(),
                fake.shared_counters.read(),
            ))
        }
        .boxed()
    }

    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.audio_volume_calls.record((handle, f32::from(volume)));
            fake.update_direct_assignment(handle, |template| {
                template.audio_volume = volume;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.audio_muted_calls.record((handle, muted));
            fake.update_direct_assignment(handle, |template| {
                template.audio_muted = muted;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.audio_response_calls.record((handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_media_integration_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.media_integration_calls.record((handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.media_integration_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn submit_media_event_json(&self, handle: SceneHandle, json: String) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.media_event_calls.record((handle, json));
            Ok(())
        }
        .boxed()
    }

    fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.media_artwork_calls.record((handle, width, height, rgba.len()));
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.control.enter(ControlledOperation::Capture).wait().await;
            let result = (|| {
                if !enabled {
                    fake.failures.check(ControlledOperation::DisableCapture).map_err(engine_fault)?;
                }
                if enabled {
                    fake.failures.check(ControlledOperation::Capture).map_err(engine_fault)?;
                }
                fake.audio_capture_calls.record((handle, enabled));
                Ok(())
            })();
            fake.control.finish(ControlledOperation::Capture);
            result
        }
        .boxed()
    }

    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let suspended = demand.suspended;
            fake.audio_capture_demands.record(demand);
            fake.audio_capture_suspend_calls.record(suspended);
            if let Err(fault) = fake.failures.check(ControlledOperation::Suspend) {
                return Err(engine_fault(fault));
            }
            if !suspended {
                if let Err(fault) = fake.failures.check(ControlledOperation::Capture) {
                    return Err(engine_fault(fault));
                }
            }
            fake.audio_capture_suspended.set(suspended);
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.scaling_mode_calls.record((handle, mode));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_mode = mode;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.scaling_factor_calls.record((handle, factor));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_factor = factor;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.framing_calls.record((handle, framing));
            if let Err(fault) = fake.failures.check(ControlledOperation::Framing) {
                return Err(engine_fault(fault));
            }
            fake.update_direct_assignment(handle, |template| {
                template.framing = framing;
            });
            Ok(())
        }
        .boxed()
    }

    fn preview_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.preview_framing_calls.record((handle, framing));
            Ok(())
        }
        .boxed()
    }

    fn preview_property_override(
        &self,
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
    ) -> EngineFuture<PropertyPreview> {
        let fake = self.clone();
        async move {
            // The real engine looks at the scene when it handles the request,
            // not when it was made.
            let drawn = fake.scene_behind(handle).ok_or_else(|| {
                EngineError::InvalidInput(format!("unknown scene handle {}", handle.raw()))
            })?;
            if drawn.scene_path != scene_path {
                fake.declined_property_previews.record((handle, scene_path));
                return Ok(PropertyPreview::OtherWallpaper);
            }
            let display_id = drawn.display.display_id;
            let already_shown = fake
                .shown_property_documents
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .get(&display_id)
                .is_some_and(|shown| *shown == flat_json);
            if already_shown {
                return Ok(PropertyPreview::Shown);
            }
            fake.preview_property_calls.record((handle, flat_json.clone()));
            let mut shown = fake
                .shown_property_documents
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if let Err(fault) = fake.failures.check(ControlledOperation::PropertyPreview) {
                // A refused update leaves the renderer's record empty, so
                // asking again sends the document.
                shown.remove(&display_id);
                return Err(engine_fault(fault));
            }
            shown.insert(display_id, flat_json);
            Ok(PropertyPreview::Shown)
        }
        .boxed()
    }

    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.fps_calls.record((handle, fps));
            fake.update_direct_assignment(handle, |template| {
                template.fps = fps;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.render_scale_calls.record((handle, scale));
            if let Err(fault) = fake.failures.check(ControlledOperation::RenderScale) {
                return Err(engine_fault(fault));
            }
            Ok(())
        }
        .boxed()
    }

    fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.scene_optimization_calls.record(enabled);
        Ok(())
    }

    fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.scene_on_demand_calls.record(enabled);
        Ok(())
    }

    fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.scene_video_plane_sampling_calls.record(enabled);
        Ok(())
    }

    fn set_scene_resolution(&self, resolution: SceneResolution) -> Result<(), EngineError> {
        self.scene_resolution_calls.record(resolution);
        Ok(())
    }

    fn scene_runtime_reports(&self) -> Vec<SceneRuntimeReport> {
        self.scene_runtime_reports.read()
    }

    fn recover_surface(
        &self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> EngineFuture<RecoveryOutcome> {
        self.recover_calls.record((display_id, reason));
        let result = self.recover_result.read().unwrap_or(Ok(
            RecoveryOutcome::Recovered {
                step: wallpaper_core::RecoveryStep::Reconfigure,
                attempt: 1,
            },
        ));
        async move { result.map_err(EngineError::Render) }.boxed()
    }

    fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        Ok(self.audio_spectrum.read())
    }

    fn poll_mouse_position(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.mouse_poll_calls.record(());
            fake.mouse_poll_count.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
            fake.mouse_samples.record(fake.mouse_input.read());
            let result = fake.control.enter(ControlledOperation::Mouse)
                .wait_bounded(Duration::from_secs(2)).await
                .map_err(|error| {
                    let error = match error {
                        ReleaseFailure::TimedOut => std::sync::mpsc::RecvTimeoutError::Timeout,
                        ReleaseFailure::Disconnected => std::sync::mpsc::RecvTimeoutError::Disconnected,
                    };
                    EngineError::Platform(format!("mouse poll release timed out: {error}"))
                });
            fake.control.finish(ControlledOperation::Mouse);
            result
        }.boxed()
    }

    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.mouse_position_calls.record((handle, x, y));
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.mouse_button_calls.record((handle, button, pressed));
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            fake.mouse_entered_calls.record((handle, entered));
            Ok(())
        }
        .boxed()
    }

    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        let fake = self.clone();
        async move {
            fake.window_create_calls.record(selector);
            if let Err(fault) = fake.failures.check(ControlledOperation::Reconcile) {
                return Err(engine_fault(fault));
            }
            Ok(Some(SceneHandle::new(98)))
        }
        .boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        let fake = self.clone();
        async move {
            fake.wallpaper_calls.record((selector, assignment));
            if let Err(fault) = fake.failures.check(ControlledOperation::Reconcile) {
                return Err(engine_fault(fault));
            }
            Ok(Some(SceneHandle::new(99)))
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.first_frame_callback.replace(Some(callback));
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        let observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback.replace(callback);
        if let Some(callback) = observer.callback.capture() {
            callback(observer.has_consumers);
        }
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        let observer = self.pointer_activity.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback.replace(callback);
        if let Some(callback) = observer.callback.capture() {
            callback(wallpaper_core::PointerActivity::MonitorGap(observer.monitor_gap));
        }
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        self.pointer_probe_count.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        self.pointer_probe.read()
    }

    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        self.user_shortcut.replace(callback);
    }

    fn scene_requires_audio(&self, handle: SceneHandle) -> bool {
        self.audio_requirement
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .requires_audio(handle)
    }

    fn set_audio_requirement_callback(
        &self,
        callback: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
        let state = self.audio_requirement.lock().unwrap_or_else(|error| error.into_inner());
        state.callback.replace(callback);
        if let Some(callback) = state.callback.capture() {
            for (handle, requires_audio) in &state.reported {
                if *requires_audio {
                    callback(*handle, true);
                }
            }
        }
    }
}

#[cfg(test)]
mod first_frame_tests {
    use wallpaper_core::{
        DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
        project::{ScalingMode, SceneDesc, SceneHandle, SceneTemplate},
    };

    use super::displays_awaiting_first_frame;

    fn forest(display: DisplayDesc) -> SceneDesc {
        SceneDesc::new(display, "/library/forest/project.json", "/assets", 30, false)
    }

    fn live(scene: &SceneDesc) -> DisplaySnapshotEntry {
        DisplaySnapshotEntry {
            identity: DisplayIdentity::default(),
            desc: scene.display.clone(),
            handle: Some(SceneHandle::new(u64::from(scene.display.display_id))),
            accepts_pointer_input: false,
            paused: false,
            window_active: true,
            assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(scene))),
        }
    }

    // Issue #30: a display refresh had moved a scene in place, and the next apply waited the
    // full 90 seconds for a first frame its unchanged renderer never reports again.
    #[test]
    fn a_scene_that_only_gets_new_geometry_is_not_awaited() {
        let shown = forest(DisplayDesc::new(3, 0, 0, 3840, 2160, 2.0));
        let live = [live(&shown)];
        let moved = forest(DisplayDesc::new(3, 1920, 0, 3840, 2160, 2.0));
        let resized = forest(DisplayDesc::new(3, 0, 0, 2560, 1440, 1.0));
        let faster = forest(DisplayDesc::new(3, 0, 0, 3840, 2160, 2.0).with_refresh_rate(120));
        for scene in [shown.clone(), moved, resized, faster] {
            assert!(displays_awaiting_first_frame(&live, &[], &[scene]).is_empty());
        }
        // Pause is applied live and never reopens a scene.
        let mut paused = shown;
        paused.paused = true;
        assert!(displays_awaiting_first_frame(&live, &[], &[paused]).is_empty());
    }

    #[test]
    fn a_scene_that_opens_or_changes_its_wallpaper_is_awaited() {
        let shown = forest(DisplayDesc::new(4, 0, 0, 3840, 2160, 2.0));
        let live = [live(&shown)];
        let mut other = shown.clone();
        other.scene_path = "/library/city/project.json".into();
        let mut fitted = shown.clone();
        fitted.scaling_mode = ScalingMode::Fit;
        let mut refreshed = shown.clone();
        refreshed.force_shader_refresh = true;
        let elsewhere = forest(DisplayDesc::new(5, 3840, 0, 3840, 2160, 2.0));
        for scene in [other, fitted, refreshed] {
            assert_eq!(displays_awaiting_first_frame(&live, &[], &[scene]), vec![4]);
        }
        assert_eq!(displays_awaiting_first_frame(&live, &[], &[elsewhere]), vec![5]);

        let mut closed = live[0].clone();
        closed.handle = None;
        assert_eq!(displays_awaiting_first_frame(&[closed], &[], &[shown]), vec![4]);
    }

    fn kept(scene: &SceneDesc, parked: bool) -> wallpaper_core::SceneWindowEntry {
        wallpaper_core::SceneWindowEntry {
            display_id: scene.display.display_id,
            handle: SceneHandle::new(90),
            desc: scene.clone(),
            window_number: Some(4_242),
            parked,
        }
    }

    // A desktop the person comes back to runs its kept scene again; that scene drew long ago,
    // and waiting for a first frame it never reports again would end in the 90-second timeout.
    #[test]
    fn a_wallpaper_the_display_keeps_parked_is_not_awaited() {
        let shown = forest(DisplayDesc::new(8, 0, 0, 3840, 2160, 2.0));
        let mut city = shown.clone();
        city.scene_path = "/library/city/project.json".into();
        let live = [live(&shown)];
        assert!(displays_awaiting_first_frame(&live, &[kept(&city, true)], &[city.clone()]).is_empty());

        // Muted and capped while it waited: applied live, nothing reloads.
        let mut quieter = city.clone();
        quieter.audio_muted = true;
        quieter.fps = 15;
        assert!(displays_awaiting_first_frame(&live, &[kept(&city, true)], &[quieter]).is_empty());

        let mut fitted = city.clone();
        fitted.scaling_mode = ScalingMode::Fit;
        assert_eq!(
            displays_awaiting_first_frame(&live, &[kept(&city, true)], &[fitted]),
            vec![8],
            "a kept scene with other settings reloads and draws again"
        );
        assert_eq!(
            displays_awaiting_first_frame(&live, &[kept(&city, false)], &[city.clone()]),
            vec![8],
            "only a parked scene counts"
        );
        let elsewhere = forest(DisplayDesc::new(9, 3840, 0, 3840, 2160, 2.0));
        let mut elsewhere_city = elsewhere.clone();
        elsewhere_city.scene_path = city.scene_path.clone();
        assert_eq!(displays_awaiting_first_frame(&[], &[kept(&city, true)], &[elsewhere_city]), vec![9]);
    }

    #[test]
    fn a_shader_refresh_the_open_scene_consumed_is_not_a_change() {
        let mut requested = forest(DisplayDesc::new(6, 0, 0, 1920, 1080, 1.0));
        requested.force_shader_refresh = true;
        let mut settled = requested.clone();
        settled.force_shader_refresh = false;
        assert!(displays_awaiting_first_frame(&[live(&requested)], &[], &[settled]).is_empty());
    }
}
