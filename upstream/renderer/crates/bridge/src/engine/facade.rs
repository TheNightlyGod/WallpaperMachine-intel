#[cfg(test)]
use std::sync::mpsc::Receiver;
use std::{
    sync::{
        Arc,
        mpsc::{self, Sender},
    },
    thread,
    time::Duration,
};

#[cfg(test)]
use arc_swap::ArcSwap;
#[cfg(test)]
use crossbeam_queue::SegQueue;
use futures_util::future::{BoxFuture, FutureExt};
#[cfg(test)]
use wallpaper_core::project::SceneTemplate;
use wallpaper_core::{
    AudioSpectrum128, DisplaySelector, DisplaySnapshotEntry, EngineError, FirstFrameCallback,
    PropertyPreview, RecoveryOutcome, RecoveryReason, SceneBackend, SceneDemandReasons,
    SceneRendererPreference, SceneResolution, SceneUpdateMode, WallpaperAssignment, WallpaperEngine,
    media::audio::{
        AudioCaptureBackend, AudioCaptureController, AudioVolume, PlatformAudioCaptureBackend,
        RESTART_RETRY_DELAYS, RestartOutcome, device_watch::OutputDeviceWatcher,
    },
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult},
    render::RendererSurfaceCounters,
};

pub type EngineFuture<T> = BoxFuture<'static, Result<T, EngineError>>;

/// Presentation gate and live consumers that do not own renderer scene handles.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioCaptureDemand {
    pub suspended: bool,
    pub external_consumers: bool,
}

/// What the renderer process actually has switched on, and what its video
/// decode is actually doing, right now.
///
/// Read back from the renderer rather than inferred from the config: a
/// persisted preference is what the user asked for, this is what is running.
/// A session is one live decoder instance, not one file; sharing shows up as
/// consumers exceeding sessions and is never implied by the setting alone.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RendererVideoPipelineState {
    pub content_pacing_enabled: bool,
    pub shared_video_decode_enabled: bool,
    pub shared_video_decode_sessions: u32,
    pub shared_video_decode_consumers: u32,
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
    fn poll_mouse_position(&self) -> EngineFuture<()>;
    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()>;
    fn set_mouse_button(&self, handle: SceneHandle, button: u32, pressed: bool)
    -> EngineFuture<()>;
    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()>;
    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>>;
    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>>;
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
    /// Turns content pacing on or off for the whole process. Off by default.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_content_pacing_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
    }
    /// Turns shared video decoding on or off for the whole process. Off by
    /// default.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_shared_video_decode_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let _ = enabled;
        Ok(())
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
    /// Chooses which renderer draws scene wallpapers, process-wide.
    /// `Compatibility` by default.
    ///
    /// A preference, not a guarantee: a scene the native backend cannot draw
    /// in full falls back as a whole scene.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    fn set_scene_renderer_preference(
        &self,
        preference: SceneRendererPreference,
    ) -> Result<(), EngineError> {
        let _ = preference;
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
    /// What the renderer has switched on and what its decode is doing now.
    fn video_pipeline_state(&self) -> RendererVideoPipelineState {
        RendererVideoPipelineState::default()
    }
}

#[derive(Clone)]
pub struct RealEngineFacade {
    engine: WallpaperEngine,
    audio_capture: AudioCaptureWorker,
    audio_mutation: Arc<tokio::sync::Mutex<()>>,
    ready_frames: Arc<std::sync::Mutex<std::collections::HashMap<SceneHandle, u64>>>,
    /// One reconcile at a time, so each waits only on the frames it caused.
    reconcile_turn: Arc<tokio::sync::Mutex<()>>,
}

impl RealEngineFacade {
    #[must_use]
    pub fn new(engine: WallpaperEngine) -> Self {
        Self {
            audio_capture: AudioCaptureWorker::spawn(engine.clone()),
            audio_mutation: Arc::default(),
            ready_frames: Arc::default(),
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
/// playing.
pub(crate) fn displays_awaiting_first_frame(live: &[DisplaySnapshotEntry], scenes: &[SceneDesc]) -> Vec<u32> {
    scenes
        .iter()
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

impl EngineFacade for RealEngineFacade {
    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.update_media(handle, enabled, state).await }.boxed()
    }
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let engine = self.engine.clone();
        let ready_frames = self.ready_frames.clone();
        let reconcile_turn = self.reconcile_turn.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _turn = reconcile_turn.lock().await;
            let before = ready_frames.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let changed = displays_awaiting_first_frame(&engine.display_snapshot(), &scenes);
            let results = {
                let _audio_guard = audio_mutation.lock().await;
                let results = engine.reconcile_scenes(scenes).await;
                audio_capture.retain_scenes().await.map_err(EngineError::Platform)?;
                results?
            };
            // A cold MoltenVK pipeline compile for a large 3D or puppet scene
            // runs past 20s. The driver's cache makes the next launch short;
            // the first one still has to be allowed to finish.
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(90);
            loop {
                let ready = {
                    let frames = ready_frames.lock().unwrap_or_else(|e| e.into_inner());
                    results.iter().filter(|r| changed.contains(&r.display_id)).all(|r| {
                        frames.get(&r.handle).copied().unwrap_or(0) > before.get(&r.handle).copied().unwrap_or(0)
                    })
                };
                if ready { break; }
                if std::time::Instant::now() >= deadline {
                    return Err(EngineError::Render("The wallpaper did not render a first frame within 90 seconds. Check the project files and shared scene assets; this wallpaper may use unsupported effects. Your previous configuration will be restored.".into()));
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            Ok(results)
        }.boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.refresh_displays().await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.engine.display_snapshot()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.close_all_scenes().await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
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

    fn set_content_pacing_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_content_pacing_enabled(enabled)
    }

    fn set_shared_video_decode_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_shared_video_decode_enabled(enabled)
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

    fn set_scene_renderer_preference(
        &self,
        preference: SceneRendererPreference,
    ) -> Result<(), EngineError> {
        self.engine.set_scene_renderer_preference(preference)
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

    fn video_pipeline_state(&self) -> RendererVideoPipelineState {
        // A renderer that cannot answer is reported as off with nothing
        // running, which is what "not observed" has to look like here: the
        // alternative is showing the persisted preference as if it were live.
        let (sessions, consumers) = self.engine.shared_video_decode_counts().unwrap_or((0, 0));
        RendererVideoPipelineState {
            content_pacing_enabled: self.engine.content_pacing_enabled().unwrap_or(false),
            shared_video_decode_enabled: self
                .engine
                .shared_video_decode_enabled()
                .unwrap_or(false),
            shared_video_decode_sessions: sessions,
            shared_video_decode_consumers: consumers,
        }
    }

    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.engine.set_renderer_counters_enabled(enabled)
    }

    fn renderer_counters(&self) -> EngineFuture<(Vec<RendererSurfaceCounters>, Vec<u64>)> {
        let engine = self.engine.clone();
        async move { engine.renderer_counters().await }.boxed()
    }

    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_volume(handle, volume).await }.boxed()
    }

    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_muted(handle, muted).await }.boxed()
    }

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
            let _audio_guard = audio_mutation.lock().await;
            audio_capture
                .set_enabled(handle, enabled)
                .await
                .map_err(EngineError::Platform)
        }
        .boxed()
    }

    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()> {
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            audio_capture
                .set_demand(demand)
                .await
                .map_err(EngineError::Platform)
        }
        .boxed()
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

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_button(handle, button, pressed).await }.boxed()
    }

    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_entered(handle, entered).await }.boxed()
    }

    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        let engine = self.engine.clone();
        async move { engine.create_window_for_display(selector).await }.boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.set_wallpaper_for_display(selector, assignment).await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        let frames = self.ready_frames.clone();
        self.engine
            .set_first_frame_callback(Arc::new(move |handle| {
                *frames
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .entry(handle)
                    .or_default() += 1;
                callback(handle);
            }));
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
fn schedule_audio_restart(action: RestartAction, events: &Sender<AudioCaptureCommand>) {
    let RestartAction::RetryIn { delay, generation, attempt } = action else {
        return;
    };
    let events = events.clone();
    let spawned = thread::Builder::new()
        .name("wallpaper-bridge-audio-retry".to_string())
        .spawn(move || {
            thread::sleep(delay);
            let _ = events.send(AudioCaptureCommand::RetryRestart { generation, attempt });
        });
    if let Err(error) = spawned {
        log::warn!("[wallpaper-core audio] could not schedule a system audio tap retry: {error}");
    }
}

/// Starts an output-device watcher for the worker. Without one the tap is
/// still started and stopped as before; only the rebuild on a device change is
/// lost.
fn watch_output_device(events: Sender<AudioCaptureCommand>) -> Option<OutputDeviceWatcher> {
    let on_change = Arc::new(move || {
        let _ = events.send(AudioCaptureCommand::OutputDeviceChanged);
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
struct AudioWorkerLifetime(Sender<AudioCaptureCommand>);

impl Drop for AudioWorkerLifetime {
    fn drop(&mut self) {
        let _ = self.0.send(AudioCaptureCommand::Shutdown);
    }
}

#[derive(Clone)]
struct AudioCaptureWorker {
    sender: Sender<AudioCaptureCommand>,
    _lifetime: Arc<AudioWorkerLifetime>,
}

enum AudioCaptureCommand {
    SetEnabled {
        handle: SceneHandle,
        enabled: bool,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    SetDemand {
        demand: AudioCaptureDemand,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    RetainScenes {
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    /// The default output device changed (debounced).
    OutputDeviceChanged,
    /// A scheduled attempt to bring the tap back after a failed rebuild.
    RetryRestart { generation: u64, attempt: usize },
    Shutdown,
}

enum AudioCaptureRequest {
    Scene { handle: SceneHandle, enabled: bool },
    Demand(AudioCaptureDemand),
}

impl AudioCaptureWorker {
    fn spawn(engine: WallpaperEngine) -> Self {
        let (sender, receiver) = mpsc::channel::<AudioCaptureCommand>();
        let events = sender.clone();
        let lifetime = Arc::new(AudioWorkerLifetime(sender.clone()));
        thread::Builder::new()
            .name("wallpaper-bridge-audio-capture".to_string())
            .spawn(move || {
                let mut controller = PlatformAudioCaptureBackend::new()
                    .map(|backend| AudioCaptureController::new(Arc::new(engine.clone()), backend))
                    .map_err(|error| error.to_string());
                // Declared after the controller, so it is dropped first and no
                // device change can arrive while the tap is being released. It
                // holds a watcher only while capture is wanted.
                let mut output_watch = OutputWatchGate::<OutputDeviceWatcher>::default();
                let mut restart = AudioRestartState::default();
                while let Ok(command) = receiver.recv() {
                    let (request, reply) = match command {
                        AudioCaptureCommand::SetEnabled { handle, enabled, reply } =>
                            (Some(AudioCaptureRequest::Scene { handle, enabled }), reply),
                        AudioCaptureCommand::SetDemand { demand, reply } =>
                            (Some(AudioCaptureRequest::Demand(demand)), reply),
                        AudioCaptureCommand::RetainScenes { reply } => (None, reply),
                        AudioCaptureCommand::OutputDeviceChanged => {
                            if let Ok(controller) = controller.as_mut() {
                                let action = handle_output_device_change(controller, &mut restart);
                                schedule_audio_restart(action, &events);
                            }
                            continue;
                        }
                        AudioCaptureCommand::RetryRestart { generation, attempt } => {
                            if let Ok(controller) = controller.as_mut() {
                                let action = handle_audio_restart_retry(
                                    controller, &restart, generation, attempt,
                                );
                                schedule_audio_restart(action, &events);
                            }
                            continue;
                        }
                        AudioCaptureCommand::Shutdown => break,
                    };
                    let result = (|| {
                        let controller = controller.as_mut().map_err(|error| error.clone())?;
                        let handles: Vec<_> = engine.display_snapshot().iter()
                            .filter_map(|display| display.handle).collect();
                        controller.retain_scenes(&handles).map_err(|error| error.to_string())?;
                        match request {
                            Some(AudioCaptureRequest::Demand(demand)) => {
                                apply_audio_capture_demand(controller, demand)?;
                            }
                            Some(AudioCaptureRequest::Scene { handle, enabled }) => {
                                if enabled {
                                    if !handles.contains(&handle) {
                                        return Err("The wallpaper is no longer active.".to_string());
                                    }
                                    // Core Audio performs the system authorization at capture startup.
                                    if !controller.has_permission().map_err(|error| error.to_string())?
                                        && !controller.request_permission().map_err(|error| error.to_string())? {
                                        return Err("System audio capture permission was not granted.".to_string());
                                    }
                                }
                                controller.set_scene_capturing(handle, enabled)
                                    .map_err(|error| format!("Audio response could not {}: {error}. Check WallpaperMachine in System Settings > Privacy & Security > Screen & System Audio Recording.", if enabled { "start" } else { "stop" }))?;
                            }
                            None => {}
                        }
                        Ok(())
                    })();
                    if let Ok(controller) = controller.as_ref() {
                        output_watch.sync(controller.wants_capture(), || {
                            watch_output_device(events.clone())
                        });
                    }
                    let _ = reply.send(result);
                }
            })
            .expect("audio capture worker thread should start");
        Self { sender, _lifetime: lifetime }
    }

    async fn set_enabled(&self, handle: SceneHandle, enabled: bool) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::SetEnabled {
                handle,
                enabled,
                reply,
            })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }

    async fn retain_scenes(&self) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::RetainScenes { reply })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }

    async fn set_demand(&self, demand: AudioCaptureDemand) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::SetDemand { demand, reply })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }
}

#[cfg(test)]
#[derive(Clone, Default)]
pub struct FakeEngineFacade {
    audio_capture_demands: Arc<ArcSwap<Vec<AudioCaptureDemand>>>,
    media_calls: Arc<ArcSwap<Vec<(SceneHandle, bool, wallpaper_core::media::MediaPollResult)>>>,
    calls: Arc<ArcSwap<Vec<Vec<SceneDesc>>>>,
    rendered_scenes: Arc<ArcSwap<Vec<SceneDesc>>>,
    snapshot: Arc<ArcSwap<Vec<DisplaySnapshotEntry>>>,
    pointer_consumer: Arc<std::sync::Mutex<PointerConsumerObserver>>,
    /// Held, so a test can report a press the way the engine would. Keeping
    /// it also keeps whatever the caller handed over alive, which is the whole
    /// point of installing it.
    user_shortcut:
        Arc<std::sync::Mutex<Option<wallpaper_core::UserShortcutObserverCallback>>>,
    /// What the fake renderers report about reading system audio.
    audio_requirement: Arc<std::sync::Mutex<FakeAudioRequirement>>,
    snapshot_after_refresh: Arc<ArcSwap<Option<Vec<DisplaySnapshotEntry>>>>,
    refresh_failure: Arc<ArcSwap<Option<String>>>,
    paused_calls: Arc<ArcSwap<Vec<bool>>>,
    pause_failure: Arc<ArcSwap<Option<String>>>,
    display_paused_calls: Arc<ArcSwap<Vec<(u32, bool)>>>,
    /// Every pause value applied to a rendered scene, by its display, in the
    /// order the fake applied them. A global resume that briefly restarts a
    /// still-hidden display shows up here as a `false` for that display.
    scene_pause_log: Arc<ArcSwap<Vec<(u32, bool)>>>,
    display_pause_failure: Arc<ArcSwap<Option<String>>>,
    suspend_failure: Arc<ArcSwap<Option<String>>>,
    disable_capture_failure: Arc<ArcSwap<Option<String>>>,
    close_failure: Arc<ArcSwap<Option<String>>>,
    audio_volume_calls: Arc<ArcSwap<Vec<(SceneHandle, f32)>>>,
    audio_muted_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    audio_response_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    media_integration_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    media_event_calls: Arc<ArcSwap<Vec<(SceneHandle, String)>>>,
    media_artwork_calls: Arc<ArcSwap<Vec<(SceneHandle, u32, u32, usize)>>>,
    audio_capture_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    audio_capture_suspend_calls: Arc<ArcSwap<Vec<bool>>>,
    audio_capture_suspended: Arc<ArcSwap<bool>>,
    audio_capture_block: Arc<SegQueue<ReconcileBlockGate>>,
    audio_capture_failure: Arc<ArcSwap<Option<String>>>,
    scaling_mode_calls: Arc<ArcSwap<Vec<(SceneHandle, ScalingMode)>>>,
    scaling_factor_calls: Arc<ArcSwap<Vec<(SceneHandle, f64)>>>,
    framing_calls: Arc<ArcSwap<Vec<(SceneHandle, SceneFraming)>>>,
    preview_framing_calls: Arc<ArcSwap<Vec<(SceneHandle, SceneFraming)>>>,
    preview_property_calls: Arc<ArcSwap<Vec<(SceneHandle, String)>>>,
    /// Property previews the fake engine declined because the scene on the
    /// handle draws another wallpaper: the handle and the project file the
    /// document was made for.
    declined_property_previews: Arc<ArcSwap<Vec<(SceneHandle, String)>>>,
    /// What each fake renderer was last shown by a property preview, by its
    /// display, like the real renderer's own record: gone when a reconcile opens
    /// the display's scene afresh or loads it again.
    shown_property_documents: Arc<std::sync::Mutex<std::collections::HashMap<u32, String>>>,
    framing_failure: Arc<ArcSwap<Option<String>>>,
    property_preview_failure: Arc<ArcSwap<Option<String>>>,
    fps_calls: Arc<ArcSwap<Vec<(SceneHandle, u32)>>>,
    render_scale_calls: Arc<ArcSwap<Vec<(SceneHandle, f32)>>>,
    render_scale_failure: Arc<ArcSwap<Option<String>>>,
    content_pacing_enabled: Arc<ArcSwap<bool>>,
    shared_video_decode_enabled: Arc<ArcSwap<bool>>,
    shared_video_decode_counts: Arc<ArcSwap<(u32, u32)>>,
    scene_optimization_calls: Arc<ArcSwap<Vec<bool>>>,
    scene_on_demand_calls: Arc<ArcSwap<Vec<bool>>>,
    scene_video_plane_sampling_calls: Arc<ArcSwap<Vec<bool>>>,
    scene_renderer_calls: Arc<ArcSwap<Vec<SceneRendererPreference>>>,
    scene_resolution_calls: Arc<ArcSwap<Vec<SceneResolution>>>,
    scene_runtime_reports: Arc<ArcSwap<Vec<SceneRuntimeReport>>>,
    /// Readings handed out one per read before the stored value is used again,
    /// so a test can say how a scene changes between two looks without a clock.
    scene_runtime_report_script: Arc<std::sync::Mutex<std::collections::VecDeque<Vec<SceneRuntimeReport>>>>,
    display_snapshot_script: Arc<std::sync::Mutex<std::collections::VecDeque<Vec<DisplaySnapshotEntry>>>>,
    recover_calls: Arc<ArcSwap<Vec<(u32, RecoveryReason)>>>,
    recover_result: Arc<ArcSwap<Option<Result<RecoveryOutcome, String>>>>,
    audio_spectrum: Arc<ArcSwap<Option<AudioSpectrum128>>>,
    mouse_poll_calls: Arc<ArcSwap<Vec<()>>>,
    mouse_poll_block: Arc<SegQueue<ReconcileBlockGate>>,
    mouse_polls_seen: Arc<std::sync::atomic::AtomicUsize>,
    pointer_activity: Arc<std::sync::Mutex<PointerActivityObserver>>,
    pointer_probe: Arc<ArcSwap<wallpaper_core::PointerProbe>>,
    pointer_probe_count: Arc<std::sync::atomic::AtomicUsize>,
    mouse_input: Arc<ArcSwap<(f64, f64)>>,
    mouse_samples: Arc<ArcSwap<Vec<(f64, f64)>>>,
    mouse_position_calls: Arc<ArcSwap<Vec<(SceneHandle, f64, f64)>>>,
    mouse_button_calls: Arc<ArcSwap<Vec<(SceneHandle, u32, bool)>>>,
    mouse_entered_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    window_create_calls: Arc<ArcSwap<Vec<DisplaySelector>>>,
    wallpaper_calls: Arc<ArcSwap<Vec<(DisplaySelector, WallpaperAssignment)>>>,
    reconcile_failure: Arc<ArcSwap<Option<String>>>,
    reconcile_block: Arc<SegQueue<ReconcileBlockGate>>,
    reconcile_done: Arc<SegQueue<Sender<()>>>,
    first_frame_callback: Arc<ArcSwap<Option<FirstFrameCallback>>>,
    counters_enabled: Arc<ArcSwap<bool>>,
    /// Values the fake renderer reports. The real increments live in the
    /// renderer; this only lets a bridge test drive the reporting path.
    surface_counters: Arc<ArcSwap<Vec<RendererSurfaceCounters>>>,
    shared_counters: Arc<ArcSwap<Vec<u64>>>,
}

#[cfg(test)]
#[derive(Default)]
struct PointerActivityObserver {
    callback: Option<wallpaper_core::PointerActivityCallback>,
    monitor_gap: bool,
}

/// The fake renderers' audio reports. Unless a test says otherwise, every
/// scene reads audio, which is what the audio-response tests are about; a test
/// of the requirement itself starts from the real engine's `false`.
#[cfg(test)]
#[derive(Default)]
struct FakeAudioRequirement {
    scenes_start_without_audio: bool,
    reported: std::collections::HashMap<SceneHandle, bool>,
    callback: Option<wallpaper_core::AudioRequirementCallback>,
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
#[derive(Default)]
struct PointerConsumerObserver {
    callback: Option<wallpaper_core::PointerConsumerCallback>,
    has_consumers: bool,
}

#[cfg(test)]
pub struct ReconcileBlock {
    blocked_rx: Receiver<()>,
    release_tx: Sender<()>,
}

#[cfg(test)]
pub struct ReconcileDone {
    done_rx: Receiver<()>,
}

#[cfg(test)]
struct ReconcileBlockGate {
    blocked_tx: Sender<()>,
    release_rx: Receiver<()>,
}

/// The next scripted reading: each is handed out once, in order, and the last
/// stays. `None` when nothing is scripted.
#[cfg(test)]
fn next_scripted<T: Clone>(script: &std::sync::Mutex<std::collections::VecDeque<T>>) -> Option<T> {
    let mut script = script.lock().unwrap_or_else(|error| error.into_inner());
    if script.len() > 1 {
        script.pop_front()
    } else {
        script.front().cloned()
    }
}

#[cfg(test)]
fn load_log<T: Clone>(log: &ArcSwap<Vec<T>>) -> Vec<T> {
    log.load_full().as_ref().clone()
}

#[cfg(test)]
fn push_log<T: Clone>(log: &ArcSwap<Vec<T>>, value: T) {
    log.rcu(|current| {
        let mut next = current.as_ref().clone();
        next.push(value.clone());
        next
    });
}

#[cfg(test)]
fn complete_reconcile_waiters(waiters: &SegQueue<Sender<()>>) {
    while let Some(waiter) = waiters.pop() {
        let _ = waiter.send(());
    }
}

#[cfg(test)]
impl ReconcileBlock {
    #[must_use]
    pub fn wait_until_blocked(&self, timeout: Duration) -> bool {
        self.blocked_rx.recv_timeout(timeout).is_ok()
    }

    pub fn release(&self) {
        let _ = self.release_tx.send(());
    }
}

#[cfg(test)]
impl ReconcileDone {
    #[must_use]
    pub fn wait(self, timeout: Duration) -> bool {
        self.done_rx.recv_timeout(timeout).is_ok()
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
        let sink = self.user_shortcut.lock().unwrap_or_else(|error| error.into_inner());
        let Some(callback) = sink.as_ref() else { return false };
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
            if let Some(callback) = &state.callback {
                callback(handle, requires_audio);
            }
        }
    }

    pub fn media_calls(&self) -> Vec<(SceneHandle, bool, wallpaper_core::media::MediaPollResult)> {
        load_log(&self.media_calls)
    }
    #[must_use]
    pub fn calls(&self) -> Vec<Vec<SceneDesc>> {
        load_log(&self.calls)
    }

    #[must_use]
    pub fn rendered_scenes(&self) -> Vec<SceneDesc> {
        self.rendered_scenes.load_full().as_ref().clone()
    }

    #[must_use]
    pub fn audio_capture_demands(&self) -> Vec<AudioCaptureDemand> {
        load_log(&self.audio_capture_demands)
    }

    #[must_use]
    pub fn audio_capture_suspended(&self) -> bool {
        **self.audio_capture_suspended.load()
    }

    pub fn set_snapshot(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        self.publish_snapshot(|_| snapshot);
    }

    fn publish_snapshot(&self, update: impl FnOnce(&[DisplaySnapshotEntry]) -> Vec<DisplaySnapshotEntry>) {
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
            if let Some(callback) = &observer.callback {
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
        if let Some(callback) = &observer.callback {
            callback(wallpaper_core::PointerActivity::MonitorGap(gap));
        }
    }

    fn report_pointer_activity(&self, activity: wallpaper_core::PointerActivity) {
        let observer = self.pointer_activity.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(callback) = &observer.callback {
            callback(activity);
        }
    }

    /// What the next cursor probe reads.
    pub fn set_pointer_probe(&self, probe: wallpaper_core::PointerProbe) {
        self.pointer_probe.store(Arc::new(probe));
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
        self.snapshot_after_refresh.store(Arc::new(Some(snapshot)));
    }

    #[must_use]
    pub fn paused_calls(&self) -> Vec<bool> {
        load_log(&self.paused_calls)
    }

    #[must_use]
    pub fn display_paused_calls(&self) -> Vec<(u32, bool)> {
        load_log(&self.display_paused_calls)
    }

    #[must_use]
    pub fn scene_pause_log(&self) -> Vec<(u32, bool)> {
        load_log(&self.scene_pause_log)
    }

    pub fn set_renderer_counters(
        &self,
        surfaces: Vec<RendererSurfaceCounters>,
        shared: Vec<u64>,
    ) {
        self.surface_counters.store(Arc::new(surfaces));
        self.shared_counters.store(Arc::new(shared));
    }

    #[must_use]
    pub fn renderer_counters_enabled(&self) -> bool {
        **self.counters_enabled.load()
    }

    #[must_use]
    pub fn audio_volume_calls(&self) -> Vec<(SceneHandle, f32)> {
        load_log(&self.audio_volume_calls)
    }

    #[must_use]
    pub fn audio_muted_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_muted_calls)
    }

    #[must_use]
    pub fn audio_response_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_response_calls)
    }

    #[must_use]
    pub fn media_integration_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.media_integration_calls)
    }

    #[must_use]
    pub fn media_event_calls(&self) -> Vec<(SceneHandle, String)> {
        load_log(&self.media_event_calls)
    }

    #[must_use]
    pub fn media_artwork_calls(&self) -> Vec<(SceneHandle, u32, u32, usize)> {
        load_log(&self.media_artwork_calls)
    }

    #[must_use]
    pub fn audio_capture_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_capture_calls)
    }

    #[must_use]
    pub fn audio_capture_suspend_calls(&self) -> Vec<bool> {
        load_log(&self.audio_capture_suspend_calls)
    }

    /// Every scene-optimization change the bridge pushed, in order.
    #[must_use]
    pub fn scene_optimization_calls(&self) -> Vec<bool> {
        load_log(&self.scene_optimization_calls)
    }

    /// Every scene on-demand change the bridge pushed, in order. A forward
    /// that never reaches the engine leaves this empty, which is what makes a
    /// missing facade delegation a test failure rather than a silent no-op.
    #[must_use]
    pub fn scene_on_demand_calls(&self) -> Vec<bool> {
        load_log(&self.scene_on_demand_calls)
    }

    /// Every direct-plane-sampling change the bridge pushed, in order.
    #[must_use]
    pub fn scene_video_plane_sampling_calls(&self) -> Vec<bool> {
        load_log(&self.scene_video_plane_sampling_calls)
    }

    /// Every scene renderer preference the bridge pushed, in order.
    #[must_use]
    pub fn scene_renderer_calls(&self) -> Vec<SceneRendererPreference> {
        load_log(&self.scene_renderer_calls)
    }

    /// Every 2D scene resolution the bridge pushed, in order.
    #[must_use]
    pub fn scene_resolution_calls(&self) -> Vec<SceneResolution> {
        load_log(&self.scene_resolution_calls)
    }

    /// What the next [`EngineFacade::scene_runtime_reports`] read returns.
    /// Left empty the fake reports nothing observed, so a test has to opt in
    /// to a live state rather than getting one by default.
    pub fn set_scene_runtime_reports(&self, reports: Vec<SceneRuntimeReport>) {
        self.scene_runtime_reports.store(Arc::new(reports));
    }

    /// Makes the next reads of the scene reports return `readings` in order,
    /// one per read, and then the last of them for every read after. The
    /// stored value is used again only once the script is empty.
    pub fn script_scene_runtime_reports(&self, readings: Vec<Vec<SceneRuntimeReport>>) {
        *self
            .scene_runtime_report_script
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = readings.into();
    }

    /// As [`Self::script_scene_runtime_reports`], for the display snapshot.
    pub fn script_display_snapshots(&self, readings: Vec<Vec<DisplaySnapshotEntry>>) {
        *self
            .display_snapshot_script
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = readings.into();
    }

    /// Every surface repair the engine was asked for, in order.
    #[must_use]
    pub fn recover_calls(&self) -> Vec<(u32, RecoveryReason)> {
        load_log(&self.recover_calls)
    }

    /// What every later [`EngineFacade::recover_surface`] call answers. Left
    /// unset the fake reports a repair by a surface reconfigure.
    pub fn set_recover_result(&self, result: Result<RecoveryOutcome, String>) {
        self.recover_result.store(Arc::new(Some(result)));
    }

    /// Sets what the next spectrum read returns. `None` is "no analysis yet".
    pub fn set_audio_spectrum(&self, spectrum: Option<AudioSpectrum128>) {
        self.audio_spectrum.store(Arc::new(spectrum));
    }

    #[must_use]
    pub fn scaling_mode_calls(&self) -> Vec<(SceneHandle, ScalingMode)> {
        load_log(&self.scaling_mode_calls)
    }

    #[must_use]
    pub fn scaling_factor_calls(&self) -> Vec<(SceneHandle, f64)> {
        load_log(&self.scaling_factor_calls)
    }

    /// Every position the fake was asked to apply live, in order. A call that
    /// was refused is in here too: it is what the bridge asked for.
    #[must_use]
    pub fn framing_calls(&self) -> Vec<(SceneHandle, SceneFraming)> {
        load_log(&self.framing_calls)
    }

    /// Every position the fake was asked to show for a drag in progress, in
    /// order. A preview moves nothing the fake stores, which is the point: it
    /// is a call the bridge makes, not a change of the scene's position.
    #[must_use]
    pub fn preview_framing_calls(&self) -> Vec<(SceneHandle, SceneFraming)> {
        load_log(&self.preview_framing_calls)
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
        load_log(&self.preview_property_calls)
    }

    /// Every property preview the fake engine declined because the scene on the
    /// handle draws another wallpaper than the one the document was made for, in
    /// order, with the project file it was made for.
    #[must_use]
    pub fn declined_property_previews(&self) -> Vec<(SceneHandle, String)> {
        load_log(&self.declined_property_previews)
    }

    #[must_use]
    pub fn fps_calls(&self) -> Vec<(SceneHandle, u32)> {
        load_log(&self.fps_calls)
    }

    #[must_use]
    pub fn render_scale_calls(&self) -> Vec<(SceneHandle, f32)> {
        load_log(&self.render_scale_calls)
    }

    /// Decode counts the next [`EngineFacade::video_pipeline_state`] reports.
    pub fn set_shared_video_decode_counts(&self, sessions: u32, consumers: u32) {
        self.shared_video_decode_counts
            .store(Arc::new((sessions, consumers)));
    }

    #[must_use]
    pub fn mouse_poll_calls(&self) -> Vec<()> {
        load_log(&self.mouse_poll_calls)
    }

    /// Waits for an engine poll the caller has not seen yet. A sample armed by
    /// an event may run before a test could install a block, so this counts
    /// polls instead of intercepting the next one.
    #[must_use]
    pub fn wait_for_unseen_mouse_poll(&self, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let seen = self.mouse_polls_seen.load(std::sync::atomic::Ordering::Acquire);
        loop {
            let count = self.mouse_poll_calls.load().len();
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
        self.mouse_input.store(Arc::new((x, y)));
    }

    pub fn mouse_samples(&self) -> Vec<(f64, f64)> {
        load_log(&self.mouse_samples)
    }

    pub fn fail_next_pause(&self) {
        self.pause_failure
            .store(Arc::new(Some("pause failed".into())));
    }

    pub fn fail_next_display_pause(&self) {
        self.display_pause_failure
            .store(Arc::new(Some("display pause failed".into())));
    }

    pub fn fail_next_suspend(&self) {
        self.suspend_failure
            .store(Arc::new(Some("audio suspend failed".into())));
    }

    pub fn fail_next_disable_capture(&self) {
        self.disable_capture_failure
            .store(Arc::new(Some("audio disable failed".into())));
    }

    /// The next live position change is refused by the renderer and leaves the
    /// running scene where it was.
    pub fn fail_next_framing(&self) {
        self.framing_failure
            .store(Arc::new(Some("framing failed".into())));
    }

    /// The next live render-scale change is refused by the renderer.
    pub fn fail_next_render_scale(&self) {
        self.render_scale_failure
            .store(Arc::new(Some("render scale failed".into())));
    }

    /// The next property document shown on a scene is refused by the
    /// renderer, which leaves the scene as it was.
    pub fn fail_next_property_preview(&self) {
        self.property_preview_failure
            .store(Arc::new(Some("property preview failed".into())));
    }

    pub fn fail_next_close(&self) {
        self.close_failure
            .store(Arc::new(Some("close failed".into())));
    }

    pub fn fail_next_refresh(&self) {
        self.refresh_failure
            .store(Arc::new(Some("refresh failed after partial commit".into())));
    }

    #[must_use]
    pub fn mouse_position_calls(&self) -> Vec<(SceneHandle, f64, f64)> {
        load_log(&self.mouse_position_calls)
    }

    #[must_use]
    pub fn mouse_button_calls(&self) -> Vec<(SceneHandle, u32, bool)> {
        load_log(&self.mouse_button_calls)
    }

    #[must_use]
    pub fn mouse_entered_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.mouse_entered_calls)
    }

    #[must_use]
    pub fn window_create_calls(&self) -> Vec<DisplaySelector> {
        load_log(&self.window_create_calls)
    }

    #[must_use]
    pub fn wallpaper_calls(&self) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        load_log(&self.wallpaper_calls)
    }

    pub fn fail_reconcile_with(&self, message: impl Into<String>) {
        self.reconcile_failure.store(Arc::new(Some(message.into())));
    }

    pub fn clear_reconcile_failure(&self) {
        self.reconcile_failure.store(Arc::new(None));
    }

    pub fn fail_audio_capture_with(&self, message: Option<String>) {
        self.audio_capture_failure.store(Arc::new(message));
    }

    #[must_use]
    pub fn block_next_reconcile(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.reconcile_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn block_next_audio_capture(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.audio_capture_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn block_next_mouse_poll(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.mouse_poll_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn wait_for_next_reconcile(&self) -> ReconcileDone {
        let (done_tx, done_rx) = mpsc::channel();
        self.reconcile_done.push(done_tx);

        ReconcileDone { done_rx }
    }

    fn update_direct_assignment(&self, handle: SceneHandle, update: impl Fn(&mut SceneTemplate)) {
        self.snapshot.rcu(|current| {
            let mut next = current.as_ref().clone();
            if let Some(WallpaperAssignment::Direct(template)) = next
                .iter_mut()
                .find(|entry| entry.handle == Some(handle))
                .and_then(|entry| entry.assignment.as_mut())
            {
                update(template);
            }
            next
        });
    }

    fn update_direct_assignment_after_refresh(
        &self,
        handle: SceneHandle,
        update: impl Fn(&mut SceneTemplate),
    ) {
        self.snapshot_after_refresh.rcu(|current| {
            let Some(current) = current.as_ref() else {
                return None;
            };
            let mut next = current.clone();
            if let Some(WallpaperAssignment::Direct(template)) = next
                .iter_mut()
                .find(|entry| entry.handle == Some(handle))
                .and_then(|entry| entry.assignment.as_mut())
            {
                update(template);
            }
            Some(next)
        });
    }

    pub fn trigger_first_frame(&self, handle: SceneHandle) {
        let callback = self.first_frame_callback.load_full().as_ref().clone();
        if let Some(callback) = callback {
            callback(handle);
        }
    }
}

#[cfg(test)]
impl EngineFacade for FakeEngineFacade {
    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> EngineFuture<()> {
        let fake = self.clone();
        async move { push_log(&fake.media_calls, (handle, enabled, state)); Ok(()) }.boxed()
    }
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let fake = self.clone();
        async move {
            push_log(&fake.calls, scenes.clone());
            if let Some(block) = fake.reconcile_block.pop() {
                let _ = block.blocked_tx.send(());
                let _ = block.release_rx.recv();
            }
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                complete_reconcile_waiters(&fake.reconcile_done);
                return Err(EngineError::Render(message));
            }
            let results = scenes
                .iter()
                .enumerate()
                .map(|(index, scene)| {
                    SceneResult::new(
                        scene.display.display_id,
                        SceneHandle::new(index as u64 + 1),
                        0,
                    )
                })
                .collect();
            let before = fake.rendered_scenes.load_full();
            fake.keep_previewed_documents(&before, &scenes);
            fake.rendered_scenes.store(Arc::new(scenes));
            complete_reconcile_waiters(&fake.reconcile_done);
            Ok(results)
        }
        .boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let refresh_snapshot = fake.snapshot_after_refresh.load_full().as_ref().clone();
            if let Some(snapshot) = refresh_snapshot {
                fake.set_snapshot(snapshot);
            }
            if let Some(message) = fake.refresh_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            Ok(())
        }
        .boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        if let Some(scripted) = next_scripted(&self.display_snapshot_script) {
            return scripted;
        }
        self.snapshot.load_full().as_ref().clone()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            if let Some(message) = fake.close_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            fake.shown_property_documents
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .clear();
            fake.publish_snapshot(|current| {
                let mut next = current.to_vec();
                for display in &mut next {
                    display.handle = None;
                    display.accepts_pointer_input = false;
                    display.assignment = None;
                }
                next
            });
            Ok(())
        }
        .boxed()
    }

    fn set_all_paused(&self, paused: bool, suspended_displays: Vec<u32>) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.paused_calls, paused);
            if let Some(message) = fake.pause_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
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
                push_log(&fake.scene_pause_log, (scene.display.display_id, scene.paused));
            }
            fake.publish_display_pause(|display_id| Some(target(display_id)));
            Ok(())
        }
        .boxed()
    }

    fn set_display_paused(&self, display_id: u32, paused: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.display_paused_calls, (display_id, paused));
            if let Some(message) = fake.display_pause_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
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
                push_log(&fake.scene_pause_log, (display_id, paused));
            }
            fake.publish_display_pause(|id| (id == display_id).then_some(paused));
            Ok(())
        }
        .boxed()
    }

    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.counters_enabled.store(Arc::new(enabled));
        Ok(())
    }

    fn renderer_counters(&self) -> EngineFuture<(Vec<RendererSurfaceCounters>, Vec<u64>)> {
        let fake = self.clone();
        async move {
            Ok((
                fake.surface_counters.load().as_ref().clone(),
                fake.shared_counters.load().as_ref().clone(),
            ))
        }
        .boxed()
    }

    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_volume_calls, (handle, f32::from(volume)));
            fake.update_direct_assignment(handle, |template| {
                template.audio_volume = volume;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_volume = volume;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_muted_calls, (handle, muted));
            fake.update_direct_assignment(handle, |template| {
                template.audio_muted = muted;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_muted = muted;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_response_calls, (handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_media_integration_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.media_integration_calls, (handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.media_integration_enabled = enabled;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.media_integration_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn submit_media_event_json(&self, handle: SceneHandle, json: String) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.media_event_calls, (handle, json));
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
            push_log(
                &fake.media_artwork_calls,
                (handle, width, height, rgba.len()),
            );
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            if let Some(block) = fake.audio_capture_block.pop() {
                let _ = block.blocked_tx.send(());
                let _ = block.release_rx.recv();
            }
            if !enabled {
                if let Some(message) = fake.disable_capture_failure.swap(Arc::new(None)).as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            if enabled {
                if let Some(message) = fake.audio_capture_failure.load_full().as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            push_log(&fake.audio_capture_calls, (handle, enabled));
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let suspended = demand.suspended;
            push_log(&fake.audio_capture_demands, demand);
            push_log(&fake.audio_capture_suspend_calls, suspended);
            if let Some(message) = fake.suspend_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            if !suspended {
                if let Some(message) = fake.audio_capture_failure.load_full().as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            fake.audio_capture_suspended.store(Arc::new(suspended));
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.scaling_mode_calls, (handle, mode));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_mode = mode;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.scaling_mode = mode;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.scaling_factor_calls, (handle, factor));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_factor = factor;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.scaling_factor = factor;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.framing_calls, (handle, framing));
            if let Some(message) = fake.framing_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            fake.update_direct_assignment(handle, |template| {
                template.framing = framing;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.framing = framing;
            });
            Ok(())
        }
        .boxed()
    }

    fn preview_framing(&self, handle: SceneHandle, framing: SceneFraming) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.preview_framing_calls, (handle, framing));
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
                push_log(&fake.declined_property_previews, (handle, scene_path));
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
            push_log(&fake.preview_property_calls, (handle, flat_json.clone()));
            let mut shown = fake
                .shown_property_documents
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if let Some(message) = fake.property_preview_failure.swap(Arc::new(None)).as_ref() {
                // A refused update leaves the renderer's record empty, so
                // asking again sends the document.
                shown.remove(&display_id);
                return Err(EngineError::Platform(message.clone()));
            }
            shown.insert(display_id, flat_json);
            Ok(PropertyPreview::Shown)
        }
        .boxed()
    }

    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.fps_calls, (handle, fps));
            fake.update_direct_assignment(handle, |template| {
                template.fps = fps;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.fps = fps;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.render_scale_calls, (handle, scale));
            if let Some(message) = fake.render_scale_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            Ok(())
        }
        .boxed()
    }

    fn set_content_pacing_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.content_pacing_enabled.store(Arc::new(enabled));
        Ok(())
    }

    fn set_shared_video_decode_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.shared_video_decode_enabled.store(Arc::new(enabled));
        Ok(())
    }

    fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        push_log(&self.scene_optimization_calls, enabled);
        Ok(())
    }

    fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        push_log(&self.scene_on_demand_calls, enabled);
        Ok(())
    }

    fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        push_log(&self.scene_video_plane_sampling_calls, enabled);
        Ok(())
    }

    fn set_scene_renderer_preference(
        &self,
        preference: SceneRendererPreference,
    ) -> Result<(), EngineError> {
        push_log(&self.scene_renderer_calls, preference);
        Ok(())
    }

    fn set_scene_resolution(&self, resolution: SceneResolution) -> Result<(), EngineError> {
        push_log(&self.scene_resolution_calls, resolution);
        Ok(())
    }

    fn scene_runtime_reports(&self) -> Vec<SceneRuntimeReport> {
        if let Some(scripted) = next_scripted(&self.scene_runtime_report_script) {
            return scripted;
        }
        self.scene_runtime_reports.load().as_ref().clone()
    }

    fn recover_surface(
        &self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> EngineFuture<RecoveryOutcome> {
        push_log(&self.recover_calls, (display_id, reason));
        let result = self.recover_result.load_full().as_ref().clone().unwrap_or(Ok(
            RecoveryOutcome::Recovered {
                step: wallpaper_core::RecoveryStep::Reconfigure,
                attempt: 1,
            },
        ));
        async move { result.map_err(EngineError::Render) }.boxed()
    }

    fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        Ok(**self.audio_spectrum.load())
    }

    fn video_pipeline_state(&self) -> RendererVideoPipelineState {
        let (sessions, consumers) = **self.shared_video_decode_counts.load();
        RendererVideoPipelineState {
            content_pacing_enabled: **self.content_pacing_enabled.load(),
            shared_video_decode_enabled: **self.shared_video_decode_enabled.load(),
            shared_video_decode_sessions: sessions,
            shared_video_decode_consumers: consumers,
        }
    }

    fn poll_mouse_position(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_poll_calls, ());
            push_log(&fake.mouse_samples, **fake.mouse_input.load());
            if let Some(block) = fake.mouse_poll_block.pop() {
                let _ = block.blocked_tx.send(());
                block
                    .release_rx
                    .recv_timeout(Duration::from_secs(2))
                    .map_err(|error| {
                        EngineError::Platform(format!("mouse poll release timed out: {error}"))
                    })?;
            }
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_position_calls, (handle, x, y));
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
            push_log(&fake.mouse_button_calls, (handle, button, pressed));
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_entered_calls, (handle, entered));
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
            push_log(&fake.window_create_calls, selector);
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                return Err(EngineError::Render(message));
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
            push_log(&fake.wallpaper_calls, (selector, assignment));
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                return Err(EngineError::Render(message));
            }
            Ok(Some(SceneHandle::new(99)))
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.first_frame_callback.store(Arc::new(Some(callback)));
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback = callback;
        if let Some(callback) = &observer.callback {
            callback(observer.has_consumers);
        }
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        let mut observer = self.pointer_activity.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback = callback;
        if let Some(callback) = &observer.callback {
            callback(wallpaper_core::PointerActivity::MonitorGap(observer.monitor_gap));
        }
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        self.pointer_probe_count.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        **self.pointer_probe.load()
    }

    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        let mut sink = self.user_shortcut.lock().unwrap_or_else(|error| error.into_inner());
        *sink = callback;
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
        let mut state = self.audio_requirement.lock().unwrap_or_else(|error| error.into_inner());
        state.callback = callback;
        if let Some(callback) = &state.callback {
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
            assert!(displays_awaiting_first_frame(&live, &[scene]).is_empty());
        }
        // Pause is applied live and never reopens a scene.
        let mut paused = shown;
        paused.paused = true;
        assert!(displays_awaiting_first_frame(&live, &[paused]).is_empty());
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
            assert_eq!(displays_awaiting_first_frame(&live, &[scene]), vec![4]);
        }
        assert_eq!(displays_awaiting_first_frame(&live, &[elsewhere]), vec![5]);

        let mut closed = live[0].clone();
        closed.handle = None;
        assert_eq!(displays_awaiting_first_frame(&[closed], &[shown]), vec![4]);
    }

    #[test]
    fn a_shader_refresh_the_open_scene_consumed_is_not_a_change() {
        let mut requested = forest(DisplayDesc::new(6, 0, 0, 1920, 1080, 1.0));
        requested.force_shader_refresh = true;
        let mut settled = requested.clone();
        settled.force_shader_refresh = false;
        assert!(displays_awaiting_first_frame(&[live(&requested)], &[settled]).is_empty());
    }
}
