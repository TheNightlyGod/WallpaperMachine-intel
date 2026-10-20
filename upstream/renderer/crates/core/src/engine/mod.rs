mod actor;
mod audio_requirement;
mod config;
mod messages;
mod runtime;
mod snapshot;
mod state;
mod surface_recovery;

pub use audio_requirement::AudioRequirementCallback;
pub use surface_recovery::{RecoveryOutcome, RecoveryReason, RecoveryStep};
use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

use actor::{EngineActor, EngineActorHandle};
use arc_swap::ArcSwap;
pub use config::{DisplayConfig, DisplaySelector, WallpaperAssignment, WallpaperEngineConfig};
use objc2_app_kit::NSEvent;
use objc2_foundation::NSPoint;
use serde_json::Value;
pub use snapshot::EngineSnapshotPublisher;

#[cfg(test)]
use crate::engine::runtime::{RuntimeRefreshMode, SceneRuntimeState};
#[cfg(test)]
use crate::engine::state::StoredSceneRuntimeState;
#[cfg(test)]
use crate::project::SceneDescSliceExt;
use crate::{
    DisplayDesc, DisplayIdentity, EngineError,
    render::RendererSurfaceCounters,
    display::{
        callback::{DisplayChangeRegistration, DisplayRefreshTarget},
        state::DisplayStateModel,
    },
    engine::state::EngineState,
    media::audio::{
        AudioCaptureError, AudioFrameConsumer, AudioResponseBlock, AudioResponseResampler,
        AudioVolume, InterleavedStereoF32, MonoPcmF32,
    },
    owe::backend::{AudioSpectrum128, OweBackend},
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult, SerdeValudeExt},
    window::{MouseButtonEdges, MouseButtonTracker, MouseButtons, NormalizedMousePosition},
};

/// Public snapshot of one display's engine-side state. Returned by
/// [`WallpaperEngine::display_snapshot`] for UI consumers that mirror the
/// engine's view of attached monitors.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplaySnapshotEntry {
    /// Stable identity metadata for matching this display across sessions.
    pub identity: DisplayIdentity,
    /// Physical display descriptor.
    pub desc: DisplayDesc,
    /// Live scene handle for this display, if the engine has opened one.
    pub handle: Option<SceneHandle>,
    /// Capability committed by the currently live native renderer.
    pub accepts_pointer_input: bool,
    /// Whether the live scene on this display is paused, for any reason: the
    /// user's choice, power policy, or this display being covered. A paused
    /// scene does not consume pointer input. False without a live scene.
    pub paused: bool,
    /// Whether this display currently has a wallpaper window.
    pub window_active: bool,
    /// The wallpaper assigned to this display, if any.
    pub assignment: Option<WallpaperAssignment>,
}

/// What came of showing a property document on a scene.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PropertyPreview {
    /// The scene shows the document: this call sent it, or an earlier one had
    /// and nothing has loaded the scene since.
    Shown,
    /// The scene draws a different wallpaper than the one the document was made
    /// for, so nothing was sent. The caller's idea of what the handle draws was
    /// out of date, which a reconcile that was still under way explains; there
    /// is nothing to show on that scene and nothing to retry.
    OtherWallpaper,
}

/// Rust entry point for controlling wallpaper scenes.
///
/// The type is cloneable so UI, audio, and smoke-test code can share the same
/// engine handle. On macOS it owns the Rust-managed scene/window state
/// directly; on unsupported platforms construction returns
/// [`EngineError::UnsupportedPlatform`].
#[derive(Clone)]
pub struct WallpaperEngine {
    backend: OweBackend,
    first_frame_callback: FirstFrameCallbackCell,
    snapshots: Arc<EngineSnapshotPublisher>,
    audio_response_resampler: Arc<std::sync::Mutex<AudioResponseResampler>>,
    mouse_buttons: Arc<Mutex<MouseButtonTracker>>,
    /// Installed only while a presenting scene reads the pointer, so no
    /// system-wide pointer event reaches this process for scenes that ignore it.
    #[allow(dead_code)]
    mouse_event_monitor: Arc<Mutex<Option<crate::window::MouseEventMonitor>>>,
    #[allow(dead_code)]
    actor: EngineActorHandle,
    /// Owns callback registration and its target for the engine lifetime.
    #[allow(dead_code)]
    lifecycle: Arc<EngineLifecycle>,
}

pub type FirstFrameCallback = Arc<dyn Fn(SceneHandle) + Send + Sync + 'static>;
pub type PointerConsumerCallback = Arc<dyn Fn(bool) + Send + Sync + 'static>;

/// What the engine tells the pointer sampler, so it samples on input rather
/// than on a timer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerActivity {
    /// The OS reported pointer motion or a button, or a presenting scene lost
    /// its last delivered pointer state and needs a fresh sample.
    Input,
    /// Whether the event monitors can currently miss motion, so the sampler
    /// has to check the cursor itself: true while this app is active (AppKit
    /// does not hand a global monitor events sent to this app, and a local
    /// monitor only sees motion a window of ours asked for), or when a monitor
    /// could not be installed.
    MonitorGap(bool),
}

/// Receives [`PointerActivity`]. Called on the thread that noticed it, the
/// AppKit main thread for OS input, so it must only record the signal: no
/// allocation, no blocking, no call back into the engine.
pub type PointerActivityCallback = Arc<dyn Fn(PointerActivity) + Send + Sync + 'static>;

/// Cursor state read without the main thread, used only to tell whether the
/// cursor changed since the last check. Not converted to AppKit coordinates
/// and never delivered to a scene: a changed probe triggers the ordinary
/// sample, which reads `NSEvent` on the main thread.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PointerProbe {
    pub x: f64,
    pub y: f64,
    pub buttons: u32,
}

/// Receives one `engine.openUserShortcut` request: which wallpaper asked,
/// the property it named, and the value its user chose for that property.
pub type UserShortcutObserverCallback =
    Arc<dyn Fn(crate::project::SceneHandle, String, String) + Send + Sync + 'static>;

#[derive(Clone)]
struct FirstFrameCallbackCell {
    callback: Arc<ArcSwap<FirstFrameCallback>>,
}

impl FirstFrameCallbackCell {
    fn set(&self, callback: FirstFrameCallback) {
        self.callback.store(Arc::new(callback));
    }

    fn callback(&self) -> FirstFrameCallback {
        let cell = self.clone();
        Arc::new(move |handle| {
            let callback = cell.callback.load_full();
            callback(handle);
        })
    }
}

impl Default for FirstFrameCallbackCell {
    fn default() -> Self {
        Self {
            callback: Arc::new(ArcSwap::from_pointee(Arc::new(|_handle| {}))),
        }
    }
}

struct EngineLifecycle {
    #[allow(dead_code)]
    refresh_target: Arc<EngineRefreshTarget>,
    #[allow(dead_code)]
    display_callback: Option<DisplayChangeRegistration<EngineRefreshTarget>>,
}

struct EngineRefreshTarget {
    actor: kameo::actor::ActorRef<EngineActor>,
}

impl DisplayRefreshTarget for EngineRefreshTarget {
    fn schedule(&self) {
        match self.actor.ask(messages::RefreshDisplays).blocking_send() {
            Ok(()) => {}
            Err(kameo::error::SendError::HandlerError(error)) => {
                log::warn!("[wallpaper-core display] display refresh failed: {error}");
            }
            Err(error) => {
                log::warn!(
                    "[wallpaper-core display] skipped display refresh because actor mailbox \
                     failed: {error}"
                );
            }
        }
    }
}

impl EngineLifecycle {
    #[allow(clippy::single_call_fn)]
    fn new(actor: &EngineActorHandle) -> Result<Self, EngineError> {
        let refresh_target = Arc::new(EngineRefreshTarget {
            actor: actor.actor().clone(),
        });
        #[cfg(not(test))]
        let display_callback = Some(DisplayChangeRegistration::register(&refresh_target)?);
        #[cfg(test)]
        let display_callback = match tokio::runtime::Handle::try_current() {
            Ok(handle)
                if matches!(
                    handle.runtime_flavor(),
                    tokio::runtime::RuntimeFlavor::CurrentThread
                ) =>
            {
                None
            }
            _ => Some(DisplayChangeRegistration::register(&refresh_target)?),
        };

        Ok(Self {
            refresh_target,
            display_callback,
        })
    }
}

impl WallpaperEngine {
    /// Creates a wallpaper engine instance for the current platform.
    ///
    /// # Errors
    ///
    /// Returns an error if the native renderer backend, display model, actor,
    /// or platform display callback cannot be initialized.
    pub fn new() -> Result<Self, EngineError> {
        Self::with_config(WallpaperEngineConfig::default())
    }

    /// Creates a wallpaper engine instance using an explicit startup
    /// configuration.
    ///
    /// # Errors
    ///
    /// Returns an error if the native renderer backend, display model, actor,
    /// or platform display callback cannot be initialized.
    pub fn with_config(config: WallpaperEngineConfig) -> Result<Self, EngineError> {
        let backend = OweBackend::initialize()?;
        let first_frame_callback = FirstFrameCallbackCell::default();
        let model = DisplayStateModel::from_config(config)?;
        let actor_state = EngineState::with_display_model(model);
        let initial_snapshot = actor_state.snapshot();
        let mouse_buttons = Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(
            crate::window::press_lands_on_desktop,
        ))));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(initial_snapshot, mouse_buttons.clone()));
        let actor = EngineActorHandle::spawn(
            backend,
            first_frame_callback.callback(),
            actor_state,
            Arc::clone(&snapshots),
        )?;
        let mouse_event_monitor = Arc::new(Mutex::new(None));
        Self::install_pointer_monitor_hook(&mouse_event_monitor, &mouse_buttons, &snapshots);
        let lifecycle = Arc::new(EngineLifecycle::new(&actor)?);
        let engine = Self {
            backend,
            first_frame_callback,
            snapshots,
            audio_response_resampler: Arc::new(
                std::sync::Mutex::new(AudioResponseResampler::new()),
            ),
            mouse_buttons,
            mouse_event_monitor,
            actor,
            lifecycle,
        };
        Ok(engine)
    }

    pub fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.first_frame_callback.set(callback);
    }

    /// Installs an observer and synchronously replays current consumer presence.
    /// The callback must only update polling control and must not reenter the engine.
    pub fn set_pointer_consumer_callback(&self, callback: Option<PointerConsumerCallback>) {
        self.snapshots.set_pointer_consumer_callback(callback);
    }

    /// Installs the pointer activity sink and synchronously replays whether the
    /// event monitors currently have a gap. The callback runs on the AppKit
    /// main thread for OS input and must only record the signal.
    pub fn set_pointer_activity_callback(&self, callback: Option<PointerActivityCallback>) {
        self.snapshots.set_pointer_activity_callback(callback);
    }

    /// Reads the cursor without the main thread, for a sampler that has to
    /// check for motion the event monitors cannot see. Only compared with the
    /// previous probe; scenes still receive the `NSEvent` sample.
    #[must_use]
    pub fn probe_pointer(&self) -> PointerProbe {
        crate::window::probe_pointer()
    }

    /// Installs the sink for `engine.openUserShortcut` requests.
    ///
    /// Pushed rather than polled: a press is rare and must not cost an idle
    /// wakeup to notice.
    pub fn set_user_shortcut_callback(&self, callback: Option<UserShortcutObserverCallback>) {
        self.snapshots.set_user_shortcut_callback(callback);
    }

    /// Installs the observer told whenever a live scene starts or stops
    /// reading system audio, and replays the scenes that currently do. Runs
    /// on the engine actor's thread under a lock: it must only hand the event
    /// on and must not reenter the engine.
    pub fn set_audio_requirement_callback(&self, callback: Option<AudioRequirementCallback>) {
        self.snapshots.audio_requirement().set_callback(callback);
    }

    /// Whether the scene behind `handle` reads system audio, as its renderer
    /// last reported. Every newly opened or rebuilt scene starts at `false`.
    #[must_use]
    pub fn scene_requires_audio(&self, handle: SceneHandle) -> bool {
        self.snapshots.audio_requirement().requires_audio(handle)
    }

    #[cfg(test)]
    #[allow(clippy::single_call_fn)]
    fn install_pointer_monitor_hook(
        slot: &Arc<Mutex<Option<crate::window::MouseEventMonitor>>>,
        mouse_buttons: &Arc<Mutex<MouseButtonTracker>>,
        snapshots: &Arc<EngineSnapshotPublisher>,
    ) {
        let _ = (slot, mouse_buttons, snapshots);
    }

    /// Installs the OS pointer monitors while a presenting scene reads the
    /// pointer and removes them when none does.
    ///
    /// The hook runs on the engine actor under the publisher's lock, and the
    /// main thread may be waiting on that actor, so the change is scheduled
    /// asynchronously on the main queue, where it re-reads the current
    /// presence: a burst of changes settles on the last one. Until monitors
    /// exist the gap stays open and the pointer poller checks the cursor
    /// itself; the hook holds only weak references, so the monitors' own
    /// reference to the publisher cannot keep either alive.
    #[cfg(not(test))]
    #[allow(clippy::single_call_fn)]
    fn install_pointer_monitor_hook(
        slot: &Arc<Mutex<Option<crate::window::MouseEventMonitor>>>,
        mouse_buttons: &Arc<Mutex<MouseButtonTracker>>,
        snapshots: &Arc<EngineSnapshotPublisher>,
    ) {
        // No monitor watches the buttons until the first consumer appears.
        mouse_buttons.lock().unwrap_or_else(|error| error.into_inner()).mark_levels_unknown();
        let slot = Arc::downgrade(slot);
        let tracker = Arc::downgrade(mouse_buttons);
        let publisher = Arc::downgrade(snapshots);
        snapshots.set_pointer_monitor_hook(Some(Arc::new(move |_| {
            let (slot, tracker, publisher) = (slot.clone(), tracker.clone(), publisher.clone());
            dispatch2::DispatchQueue::main().exec_async(move || {
                let (Some(slot), Some(tracker), Some(snapshots)) =
                    (slot.upgrade(), tracker.upgrade(), publisher.upgrade())
                else {
                    return;
                };
                let wanted = snapshots.load().has_pointer_consumers();
                let mut monitor = slot.lock().unwrap_or_else(|error| error.into_inner());
                if wanted == monitor.is_some() {
                    return;
                }
                if wanted {
                    let installed = Self::new_mouse_event_monitor(tracker, Arc::clone(&snapshots));
                    snapshots.set_pointer_monitors_installed(installed.complete());
                    *monitor = Some(installed);
                } else {
                    // Dropping removes the monitors; this is already the main thread.
                    *monitor = None;
                    snapshots.set_pointer_monitors_installed(false);
                    // Buttons pressed or released from now on are not seen; the
                    // first sample after a consumer returns adopts them as levels.
                    tracker.lock().unwrap_or_else(|error| error.into_inner()).mark_levels_unknown();
                }
            });
        })));
    }

    #[cfg(not(test))]
    fn new_mouse_event_monitor(
        tracker: Arc<Mutex<MouseButtonTracker>>,
        snapshots: Arc<EngineSnapshotPublisher>,
    ) -> crate::window::MouseEventMonitor {
        use crate::window::MouseMonitorEvent;

        crate::window::MouseEventMonitor::new(move |event| match event {
            MouseMonitorEvent::Button(state) => {
                tracker.lock().unwrap_or_else(|error| error.into_inner())
                    .set_button(state.button, state.pressed);
                snapshots.signal_pointer_input();
            }
            MouseMonitorEvent::Motion => snapshots.signal_pointer_input(),
            MouseMonitorEvent::AppActive(active) => snapshots.set_pointer_app_active(active),
        })
    }

    /// Alias for [`WallpaperEngine::new`] retained for call sites that model an
    /// explicit startup phase.
    ///
    /// # Errors
    ///
    /// Returns an error if [`WallpaperEngine::new`] cannot initialize the
    /// engine.
    pub fn initialize() -> Result<Self, EngineError> {
        Self::new()
    }

    async fn ask_actor<M, T>(&self, message: M) -> Result<T, EngineError>
    where
        EngineActor: kameo::message::Message<M>,
        <EngineActor as kameo::message::Message<M>>::Reply:
            kameo::reply::Reply<Ok = T, Error = EngineError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.actor
            .actor()
            .ask(message)
            .await
            .map_err(EngineError::from)
    }

    /// Refreshes the platform display list.
    ///
    /// # Errors
    ///
    /// Returns an error if the platform display query or actor request fails.
    pub async fn refresh_displays(&self) -> Result<(), EngineError> {
        self.ask_actor(messages::RefreshDisplays).await
    }

    #[must_use]
    pub fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.snapshots.load().displays.clone()
    }

    #[cfg(test)]
    /// # Errors
    ///
    /// Returns an error if actor communication fails.
    pub async fn actor_ping_for_test(&self) -> Result<(), EngineError> {
        self.actor
            .actor()
            .ask(messages::Ping)
            .await
            .map_err(EngineError::from)?;
        Ok(())
    }

    #[cfg(test)]
    /// # Errors
    ///
    /// Returns an error if actor communication fails.
    pub async fn actor_display_record_count_for_test(&self) -> Result<usize, EngineError> {
        self.actor
            .actor()
            .ask(messages::DisplayRecordCountForTest)
            .await
            .map_err(EngineError::from)
    }

    #[cfg(test)]
    /// # Errors
    ///
    /// Returns an error if actor communication fails.
    pub async fn actor_sequence_for_test(&self, expected: u64) -> Result<u64, EngineError> {
        self.ask_actor(messages::SequenceForTest { expected }).await
    }

    #[cfg(test)]
    /// # Panics
    ///
    /// Panics if the test-only actor shell cannot be started.
    pub async fn actor_closed_error_for_test() -> EngineError {
        let snapshots = Arc::new(EngineSnapshotPublisher::new(
            EngineState::default().snapshot(),
            Arc::new(Mutex::new(MouseButtonTracker::new())),
        ));
        let actor_handle = EngineActorHandle::spawn(
            OweBackend,
            Arc::new(|_handle| {}),
            EngineState::default(),
            snapshots,
        )
        .expect("test actor shell should start");
        let actor = actor_handle.actor().clone();
        let _ = actor.stop_gracefully().await;
        actor.wait_for_shutdown().await;

        let error = actor
            .ask(messages::Ping)
            .await
            .expect_err("stopped actor ask should fail");
        EngineError::from(error)
    }

    /// Sets or clears the wallpaper assignment for one display selector.
    ///
    /// # Errors
    ///
    /// Returns an error if the selector is invalid, actor communication fails,
    /// or the renderer rejects the requested assignment.
    pub async fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        wallpaper: WallpaperAssignment,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.ask_actor(messages::SetWallpaperForDisplay {
            selector,
            wallpaper,
        })
        .await
    }

    /// Creates a window for one display selector.
    ///
    /// # Errors
    ///
    /// Returns an error if the selector is invalid, actor communication fails,
    /// or the platform window cannot be created.
    pub async fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.ask_actor(messages::CreateWindowForDisplay { selector })
            .await
    }

    /// Destroys the window for one display selector.
    ///
    /// # Errors
    ///
    /// Returns an error if the selector is invalid, actor communication fails,
    /// or the platform window cannot be closed.
    pub async fn destroy_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::DestroyWindowForDisplay { selector })
            .await
    }

    /// Makes the active renderer scene set match `scenes`.
    ///
    /// Each input item describes the desired wallpaper for one display. The
    /// returned handles are stable identifiers for later per-scene operations
    /// such as scaling or audio-response toggles.
    ///
    /// # Errors
    ///
    /// Returns an error if scene descriptors are invalid, actor communication
    /// fails, or the renderer cannot open/reconfigure the requested scenes.
    pub async fn reconcile_scenes(
        &self,
        scenes: Vec<SceneDesc>,
    ) -> Result<Vec<SceneResult>, EngineError> {
        self.ask_actor(messages::ReconcileScenes { scenes }).await
    }

    /// Closes all scenes currently owned by this engine instance.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer cannot
    /// close one of the open scenes.
    pub async fn close_all_scenes(&self) -> Result<(), EngineError> {
        self.ask_actor(messages::CloseAllScenes).await
    }

    /// Sets how a scene is fit into its display/output rectangle.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_scaling_mode(
        &self,
        handle: SceneHandle,
        mode: ScalingMode,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetScalingMode { handle, mode })
            .await
    }

    /// Sets an additional positive scale factor for a scene.
    ///
    /// # Errors
    ///
    /// Returns an error if `factor` is not finite/positive, actor communication
    /// fails, or the renderer rejects the update.
    pub async fn set_scaling_factor(
        &self,
        handle: SceneHandle,
        factor: f64,
    ) -> Result<(), EngineError> {
        if !factor.is_finite() || factor <= 0.0 {
            return Err(EngineError::InvalidInput(
                "scaling factor must be finite and greater than zero".to_string(),
            ));
        }

        self.ask_actor(messages::SetScalingFactor { handle, factor })
            .await
    }

    /// Sets where a scene's presented wallpaper sits inside the room its
    /// display leaves around it.
    ///
    /// Applied live: the project is not reparsed, the renderer is not rebuilt
    /// and video keeps playing. The scene keeps the position across a rebuild
    /// of the same wallpaper, and a different wallpaper takes the position of
    /// its own descriptor.
    ///
    /// # Errors
    ///
    /// Returns an error if either axis of `framing` is not a finite fraction
    /// between 0 and 1, actor communication fails, or the renderer rejects the
    /// update. Nothing is sent to the renderer for an invalid framing.
    pub async fn set_framing(
        &self,
        handle: SceneHandle,
        framing: SceneFraming,
    ) -> Result<(), EngineError> {
        framing.validate()?;

        self.ask_actor(messages::SetFraming { handle, framing })
            .await
    }

    /// Shows a scene at `framing` while a drag is under way, without making it
    /// the scene's position.
    ///
    /// The renderer follows live like [`Self::set_framing`], but the scene's
    /// stored state is left alone and no engine snapshot is published, so a
    /// caller can send one per step. The drag must end with
    /// [`Self::set_framing`] (the same value commits it); a drag that does not
    /// leaves the renderer on the shown position until the next commit, or
    /// until the renderer is rebuilt, which goes back to the committed one.
    ///
    /// # Errors
    ///
    /// Returns an error if either axis of `framing` is not a finite fraction
    /// between 0 and 1, actor communication fails, or the renderer rejects the
    /// update. Nothing is sent to the renderer for an invalid framing.
    pub async fn preview_framing(
        &self,
        handle: SceneHandle,
        framing: SceneFraming,
    ) -> Result<(), EngineError> {
        framing.validate()?;

        self.ask_actor(messages::PreviewFraming { handle, framing })
            .await
    }

    /// Live-updates the target FPS for one scene.
    ///
    /// # Errors
    ///
    /// Returns an error if `fps` is zero, actor communication fails, or the
    /// renderer rejects the update.
    pub async fn set_fps(&self, handle: SceneHandle, fps: u32) -> Result<(), EngineError> {
        if fps == 0 {
            return Err(EngineError::InvalidInput(
                "fps must be greater than zero".to_string(),
            ));
        }

        self.ask_actor(messages::SetFps { handle, fps }).await
    }

    /// Live-updates the internal rasterization scale for one scene.
    ///
    /// `scale` is the fraction of the surface's native pixel grid the scene is
    /// rasterized at, in `(0, 1]`; the renderer clamps it to the range it can
    /// honour. Unlike [`Self::set_render_resolution`] this resizes render
    /// targets in place: the project is not reparsed and video is not
    /// reopened.
    ///
    /// # Errors
    ///
    /// Returns an error if `scale` is not finite or not positive, actor
    /// communication fails, or the renderer cannot resize.
    pub async fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> Result<(), EngineError> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(EngineError::InvalidInput(
                "render scale must be finite and greater than zero".to_string(),
            ));
        }

        self.ask_actor(messages::SetRenderScale {
            handle,
            scale: f64::from(scale),
        })
        .await
    }

    /// Live-updates the paused state for one open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_paused(&self, handle: SceneHandle, paused: bool) -> Result<(), EngineError> {
        self.ask_actor(messages::SetPaused { handle, paused }).await
    }

    /// Live-updates the paused state for all open scenes in one pass: each
    /// scene is paused when `paused` is set or its display is in
    /// `suspended_displays`, and resumed otherwise. A covered display therefore
    /// never runs during a global resume.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_all_paused(
        &self,
        paused: bool,
        suspended_displays: Vec<u32>,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAllPaused { paused, suspended_displays }).await
    }

    /// Brings back the surface of the scene on `display_id` after it stopped
    /// drawing, by the next rung of that scene's recovery ladder (a surface
    /// reconfigure, then a renderer rebuild), without waiting.
    ///
    /// The engine heals a scene that reports a failed frame on its own; this is
    /// for the callers that know something it does not, such as the check
    /// after a wake ([`RecoveryReason::Stalled`]). A request spends the scene's
    /// current budget and is refused once it is spent, so a caller cannot loop;
    /// loading the wallpaper afresh gives the scene a new renderer and a new
    /// budget. Paused scenes stay paused.
    ///
    /// # Errors
    ///
    /// Returns the error of the attempt when it failed. The next rung is then
    /// already scheduled, unless the budget is spent.
    pub async fn recover_surface(
        &self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> Result<RecoveryOutcome, EngineError> {
        self.ask_actor(messages::RecoverSurface { display_id, reason }).await
    }

    /// Turns renderer counting on or off for the whole process.
    ///
    /// Off is the default: with it off no counted event performs any
    /// bookkeeping. Enabling starts no thread, no timer and no output stream;
    /// counters are only ever read by an explicit call.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_counters_enabled(enabled)
    }

    /// Turns content pacing on or off for the whole process.
    ///
    /// Off by default. With it on the renderer produces content at the target
    /// rate instead of once per display refresh.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_content_pacing_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_content_pacing_enabled(enabled)
    }

    /// Whether the renderer process currently has content pacing on.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn content_pacing_enabled(&self) -> Result<bool, EngineError> {
        self.backend.content_pacing_enabled()
    }

    /// Turns shared video decoding on or off for the whole process.
    ///
    /// Off by default. With it on, surfaces showing the same video source can
    /// consume one decoder instance instead of one each.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_shared_video_decode_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_shared_video_decode_enabled(enabled)
    }

    /// Whether the renderer process currently has shared video decoding on.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn shared_video_decode_enabled(&self) -> Result<bool, EngineError> {
        self.backend.shared_video_decode_enabled()
    }

    /// Turns scene render optimisation on or off for the renderer process.
    ///
    /// On by default. It reuses the previous frame's pixels for render targets
    /// whose inputs have not changed and removes copy passes proven redundant;
    /// it does not change resolution, frame rate or animation timing.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_scene_optimization_enabled(enabled)
    }

    /// Turns whole-scene on-demand updating on or off for every scene.
    ///
    /// A scene that can be shown to have nothing advancing on its own stops
    /// its frame clock entirely and waits for an event. This is not a frame
    /// rate setting: a scene that cannot be shown to be still keeps its
    /// existing cadence, at full quality.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_scene_on_demand_enabled(enabled)
    }

    /// Turns direct NV12 plane sampling on or off inside native Metal scenes.
    ///
    /// Off by default. A material whose shader could be translated to sample
    /// the decoder's planes then does so and produces no full-frame colour
    /// conversion. It is a selection between two programs that were both
    /// compiled with the scene's graph, never a reason to change backend.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.backend.set_scene_video_plane_sampling_enabled(enabled)
    }

    /// Chooses which renderer new and rebuilt scenes prefer.
    ///
    /// A preference, not a guarantee: a scene the native backend cannot draw
    /// runs on the compatibility backend and reports why.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_scene_renderer_preference(
        &self,
        preference: crate::SceneRendererPreference,
    ) -> Result<(), EngineError> {
        self.backend.set_scene_renderer_preference(preference)
    }

    /// Chooses how many pixels a 2D scene is rasterized with: the canvas it
    /// was authored at, or the size it is presented at on the display.
    ///
    /// Process-wide. A scene opened afterwards takes it when its graph is
    /// built; one already running takes it when its render scale is next
    /// applied (see [`Self::set_render_scale`]), which resizes its targets in
    /// place without reparsing the project or reopening a video.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn set_scene_resolution(
        &self,
        resolution: crate::SceneResolution,
    ) -> Result<(), EngineError> {
        self.backend.set_scene_resolution(resolution)
    }

    /// Live update state and active backend for every open scene.
    ///
    /// Synchronous and infallible so it composes with a synchronous settings
    /// snapshot, and pull-only so reading it never enables diagnostic
    /// counting. Each row is a handful of relaxed atomic loads inside the
    /// renderer, taken under the registry lock that also keeps the scene
    /// alive for the duration of the read.
    ///
    /// A scene that is open but cannot be described yields a row with `None`
    /// fields rather than being omitted: "running but unreadable" and
    /// "nothing running" are different facts and must not collapse into an
    /// empty result.
    #[must_use]
    pub fn scene_runtime_reports(&self) -> Vec<crate::SceneRuntimeReport> {
        crate::SceneRegistry::shared().reports()
    }

    /// Latest system-audio spectrum, or `None` when no analysis has run.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects the call.
    pub fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        self.backend.current_audio_spectrum()
    }

    /// Live decode sessions and the number of surfaces consuming them.
    ///
    /// A session is one running decoder instance, not one file: two decoders
    /// of the same clip count as two. Sharing is visible as consumers
    /// exceeding sessions, and is not implied by the setting being on.
    ///
    /// # Errors
    ///
    /// Returns an error if the renderer rejects either call.
    pub fn shared_video_decode_counts(&self) -> Result<(u32, u32), EngineError> {
        self.backend.shared_video_decode_counts()
    }

    /// Reads renderer work counters for every open scene, plus the process-wide
    /// counters that belong to no single surface.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the call.
    pub async fn renderer_counters(
        &self,
    ) -> Result<(Vec<RendererSurfaceCounters>, Vec<u64>), EngineError> {
        let surfaces = self.ask_actor(messages::RendererCounters).await?;
        Ok((surfaces, self.backend.shared_counters()?))
    }

    /// Sends normalized mouse coordinates to one open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if coordinates are non-finite, actor communication
    /// fails, or the renderer rejects the update.
    pub async fn set_mouse_position(
        &self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput(
                "mouse coordinates must be finite".to_string(),
            ));
        }

        self.ask_actor(messages::SetMousePosition { handle, x, y })
            .await
    }

    /// Sends a mouse button state transition to one open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if the button is out of range, actor communication
    /// fails, or the renderer rejects the update.
    pub async fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> Result<(), EngineError> {
        if button > 31 {
            return Err(EngineError::InvalidInput(
                "mouse button must be in range 0..31".to_string(),
            ));
        }

        self.ask_actor(messages::SetMouseButton {
            handle,
            button,
            pressed,
        })
        .await
    }

    /// Sends mouse enter/leave state to one open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_mouse_entered(
        &self,
        handle: SceneHandle,
        entered: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetMouseEntered { handle, entered })
            .await
    }

    /// Polls the global macOS mouse location and forwards normalized
    /// coordinates to every active scene under that point.
    ///
    /// Wallpaper windows ignore mouse events so they do not steal desktop
    /// clicks. Polling global coordinates keeps mouse-tracking wallpapers
    /// updated without changing the window hit-testing behavior.
    ///
    /// # Errors
    ///
    /// Returns an error if forwarding to the renderer fails.
    pub async fn poll_mouse_position(&self) -> Result<(), EngineError> {
        if !self.snapshots.load().has_pointer_consumers() {
            return Ok(());
        }
        let state = crate::window::run_on_main_thread(|| {
            let mut tracker = self.mouse_buttons.lock().unwrap_or_else(|error| error.into_inner());
            if !self.snapshots.load().has_pointer_consumers() {
                return None;
            }
            let point = NSEvent::mouseLocation();
            tracker.sync_down_mask(NSEvent::pressedMouseButtons() as u64);
            let buttons = tracker.consume_edges();
            Some(MousePollState { point, buttons })
        });
        if let Some(state) = state { self.poll_mouse_state(state).await?; }
        Ok(())
    }

    /// Overrides the scene render resolution.
    ///
    /// The dimensions must be non-zero. Use the scene/display default instead
    /// of calling this method when no explicit override is wanted.
    ///
    /// # Errors
    ///
    /// Returns an error if either dimension is zero, actor communication fails,
    /// or the renderer cannot apply the new resolution.
    pub async fn set_render_resolution(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
    ) -> Result<(), EngineError> {
        if width == 0 || height == 0 {
            return Err(EngineError::InvalidInput(
                "render resolution dimensions must be non-zero".to_string(),
            ));
        }

        self.ask_actor(messages::SetRenderResolution {
            handle,
            width,
            height,
        })
        .await
    }

    /// Enables or disables audio-responsive scene behavior.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioResponseEnabled { handle, enabled })
            .await
    }

    /// Delivers the host's current player state to one scene.
    pub async fn update_media(&self, handle: SceneHandle, enabled: bool,
        state: crate::media::MediaPollResult) -> Result<(), EngineError> {
        self.ask_actor(messages::UpdateMedia { handle, enabled, state }).await
    }

    /// Enables or disables now-playing events for one scene.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_media_integration_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetMediaIntegrationEnabled { handle, enabled })
            .await
    }

    /// Delivers one SceneScript media event as already-serialized JSON.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the event.
    pub async fn submit_media_event_json(
        &self,
        handle: SceneHandle,
        json: impl Into<String> + Send,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SubmitMediaEventJson {
            handle,
            json: json.into(),
        })
        .await
    }

    /// Uploads `$mediaThumbnail` RGBA for one scene.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the artwork.
    pub async fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::ApplySystemMediaArtwork {
            handle,
            width,
            height,
            rgba,
        })
        .await
    }

    /// Sets the scene-wide audio volume multiplier.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_audio_volume(
        &self,
        handle: SceneHandle,
        volume: AudioVolume,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioVolume { handle, volume })
            .await
    }

    /// Sets the scene-wide audio mute flag.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the update.
    pub async fn set_audio_muted(
        &self,
        handle: SceneHandle,
        muted: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioMuted { handle, muted })
            .await
    }

    /// Applies a project property override JSON document to an open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON cannot be parsed/flattened, actor
    /// communication fails, or the renderer rejects the override.
    pub async fn set_property_override<T: Into<String> + Send>(
        &self,
        handle: SceneHandle,
        json: T,
    ) -> Result<(), EngineError> {
        let flat_json = flat_property_document(&json.into())?;

        self.ask_actor(messages::SetPropertyOverride { handle, flat_json })
            .await
    }

    /// Shows a project property document on an open scene without keeping it.
    ///
    /// The document is the whole property state to show, like the one
    /// [`Self::set_property_override`] takes: the project's declared defaults
    /// with exactly these values over them, so a property it leaves out is back
    /// at its declared default. Unlike that call it does not load the scene
    /// again, saves nothing and publishes no snapshot: the scene's runtime state
    /// and stored template stay as they were, so a caller can send one document
    /// per step of an edit and an edit that is abandoned leaves nothing for the
    /// next reconcile to rebuild. The shown state is gone as soon as the scene
    /// is loaded again for any reason, and the scene then shows its saved
    /// look. A property the scene reads only while it loads stays at the
    /// value the scene loaded with.
    ///
    /// `scene_path` is the project file of the wallpaper the document was made
    /// for. A handle names a display's scene, and a reconcile that is still
    /// under way can put another wallpaper on it; this call is handled after
    /// that reconcile, so the scene is checked then, and one that draws another
    /// wallpaper is left alone and reported as
    /// [`PropertyPreview::OtherWallpaper`]. A document for one wallpaper never
    /// reaches another, whatever property names they share.
    ///
    /// The engine also knows what each scene was last shown, because it owns
    /// the renderer that shows it and replaces it: a scene that already shows
    /// the document is not told again, and a scene that was loaded again, for
    /// any reason, is, so a caller can ask after every edit without tracking
    /// which scenes were rebuilt.
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON cannot be parsed/flattened, actor
    /// communication fails, or the renderer rejects the document. The document
    /// is checked before the actor is asked, so a malformed one never reaches
    /// the renderer.
    pub async fn preview_property_override<S, T>(
        &self,
        handle: SceneHandle,
        scene_path: S,
        json: T,
    ) -> Result<PropertyPreview, EngineError>
    where
        S: Into<String> + Send,
        T: Into<String> + Send,
    {
        let flat_json = flat_property_document(&json.into())?;

        self.ask_actor(messages::PreviewPropertyOverride {
            handle,
            expected_scene_path: scene_path.into(),
            flat_json,
        })
        .await
    }

    /// Clears project property overrides for an open scene.
    ///
    /// # Errors
    ///
    /// Returns an error if actor communication fails or the renderer rejects
    /// the reset.
    pub async fn reset_property_override(&self, handle: SceneHandle) -> Result<(), EngineError> {
        self.ask_actor(messages::ResetPropertyOverride { handle })
            .await
    }

    async fn poll_mouse_state(&self, state: MousePollState) -> Result<(), EngineError> {
        self.ask_actor(messages::PollMouseState { state }).await
    }
}

/// Parses a property document and flattens it into the one-level JSON object
/// the renderer reads, the same way for every call that hands the renderer one.
fn flat_property_document(json: &str) -> Result<String, EngineError> {
    let flat = serde_json::from_str::<Value>(json)
        .map_err(|e| EngineError::InvalidInput(e.to_string()))?
        .flatten()?;
    serde_json::to_string(&flat).map_err(|e| EngineError::InvalidInput(e.to_string()))
}

struct DisplaySnapshot<'a> {
    entries: &'a [DisplaySnapshotEntry],
}

impl<'a> DisplaySnapshot<'a> {
    fn mouse_update_for_entry(
        &self,
        state: MousePollState,
        entry: &DisplaySnapshotEntry,
    ) -> MouseDisplayUpdate {
        match &entry.assignment {
            Some(WallpaperAssignment::Mirror(selector)) => {
                let mirror_update = mouse_update_for_display(state, &entry.desc);
                if mirror_update.entered {
                    return mirror_update;
                }
                self.source_display(selector)
                    .map_or(mirror_update, |source| {
                        mouse_update_for_display(state, &source.desc)
                    })
            }
            _ => mouse_update_for_display(state, &entry.desc),
        }
    }

    fn source_display(&self, selector: &DisplaySelector) -> Option<&'a DisplaySnapshotEntry> {
        let mut seen = HashSet::new();
        self.source_display_inner(selector, &mut seen)
    }

    fn source_display_inner(
        &self,
        selector: &DisplaySelector,
        seen: &mut HashSet<DisplaySelector>,
    ) -> Option<&'a DisplaySnapshotEntry> {
        if !seen.insert(selector.clone()) {
            return None;
        }

        let entry = self.selected_display(selector)?;
        match &entry.assignment {
            Some(WallpaperAssignment::Mirror(source_selector)) => {
                self.source_display_inner(source_selector, seen)
            }
            _ => Some(entry),
        }
    }

    fn selected_display(&self, selector: &DisplaySelector) -> Option<&'a DisplaySnapshotEntry> {
        match selector {
            DisplaySelector::Primary => self.entries.first(),
            DisplaySelector::Identity(identity) => self
                .entries
                .iter()
                .find(|entry| entry.identity.match_score(identity).is_some()),
            DisplaySelector::LiveDisplayId(display_id) => self
                .entries
                .iter()
                .find(|entry| entry.desc.display_id == *display_id),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct MousePollState {
    point: NSPoint,
    buttons: MouseButtonEdges,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct MouseDisplayUpdate {
    entered: bool,
    position: Option<NormalizedMousePosition>,
    buttons: MouseButtonEdges,
}

#[allow(clippy::single_call_fn)]
fn mouse_update_for_display(state: MousePollState, display: &DisplayDesc) -> MouseDisplayUpdate {
    let position = normalized_mouse_for_display(state.point, display);
    MouseDisplayUpdate {
        entered: position.is_some(),
        position,
        buttons: position.map_or_else(
            || MouseButtonEdges::from_level_state(MouseButtons::default()),
            |_| state.buttons,
        ),
    }
}

#[allow(clippy::cast_possible_truncation)]
#[allow(clippy::single_call_fn)]
fn normalized_mouse_for_display(
    point: NSPoint,
    display: &DisplayDesc,
) -> Option<NormalizedMousePosition> {
    let scale_factor = display.scale_factor.max(f64::MIN_POSITIVE);
    let display_x = f64::from(display.x);
    let display_y = f64::from(display.y);
    let width = f64::from(display.width) / scale_factor;
    let height = f64::from(display.height) / scale_factor;

    if point.x < display_x
        || point.y < display_y
        || point.x >= display_x + width
        || point.y >= display_y + height
    {
        return None;
    }

    NormalizedMousePosition::from_window_point(
        point.x - display_x,
        point.y - display_y,
        width,
        height,
    )
}

impl<M> From<kameo::error::SendError<M, EngineError>> for EngineError {
    fn from(error: kameo::error::SendError<M, EngineError>) -> Self {
        match error {
            kameo::error::SendError::HandlerError(error) => error,
            error => Self::Platform(format!("engine actor mailbox failed: {error}")),
        }
    }
}

impl WallpaperEngine {
    fn submit_audio_response_block(
        &self,
        block: &AudioResponseBlock<'_>,
    ) -> Result<(), AudioCaptureError> {
        match block {
            AudioResponseBlock::Mono(frames) => self.backend.submit_audio_mono_frames(frames),
            AudioResponseBlock::Stereo(frames) => self.backend.submit_audio_frames(*frames),
        }
        .map_err(|error| AudioCaptureError::Engine(error.to_string()))
    }
}

impl AudioFrameConsumer for WallpaperEngine {
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError> {
        let Ok(mut resampler) = self.audio_response_resampler.try_lock() else {
            return Ok(());
        };

        let mut result = Ok(());
        resampler.push_stereo(&frames, |block| {
            if result.is_ok() {
                result = self.submit_audio_response_block(&block);
            }
        });
        result
    }

    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
        let Ok(mut resampler) = self.audio_response_resampler.try_lock() else {
            return Ok(());
        };

        let mut result = Ok(());
        resampler.push_mono(&frames, |block| {
            if result.is_ok() {
                result = self.submit_audio_response_block(&block);
            }
        });
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        display::state::{DisplayKey, DisplayRecord},
        engine::state::DisplayRuntimeRecord,
        window::MouseButtonState,
    };

    #[tokio::test(flavor = "current_thread")]
    async fn polling_without_consumers_never_asks_even_a_closed_actor() {
        let engine = engine_with_display_records(Vec::new());
        engine.mouse_buttons.lock().unwrap().set_button(0, true);
        engine.actor.actor().stop_gracefully().await.unwrap();
        engine.actor.actor().wait_for_shutdown().await;
        engine.poll_mouse_position().await.unwrap();
        let desc = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        engine.snapshots.publish(snapshot::EngineSnapshot { displays: vec![DisplaySnapshotEntry {
            identity: desc.identity.clone(),
            desc,
            handle: Some(SceneHandle::new(1)),
            accepts_pointer_input: false,
            paused: false,
            window_active: true,
            assignment: None,
        }] });
        engine.poll_mouse_position().await.unwrap();
        let edges = engine.mouse_buttons.lock().unwrap().consume_edges();
        assert_eq!(edges.transitions().map(|edge| (edge.button, edge.pressed)).collect::<Vec<_>>(), vec![(0, true)]);
    }

    fn engine_with_display_records(records: Vec<DisplayRecord>) -> WallpaperEngine {
        let state = EngineState::with_display_model(DisplayStateModel { records });
        let snapshot = state.snapshot();
        let mouse_buttons = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(snapshot, mouse_buttons.clone()));
        let first_frame_callback = FirstFrameCallbackCell::default();
        let actor = EngineActorHandle::spawn(
            OweBackend,
            first_frame_callback.callback(),
            state,
            Arc::clone(&snapshots),
        )
        .expect("test actor shell should start");
        let refresh_target = Arc::new(EngineRefreshTarget {
            actor: actor.actor().clone(),
        });
        let lifecycle = Arc::new(EngineLifecycle {
            refresh_target,
            display_callback: None,
        });
        WallpaperEngine {
            backend: OweBackend,
            first_frame_callback,
            snapshots,
            audio_response_resampler: Arc::new(
                std::sync::Mutex::new(AudioResponseResampler::new()),
            ),
            mouse_buttons,
            mouse_event_monitor: Arc::new(Mutex::new(None)),
            actor,
            lifecycle,
        }
    }

    #[test]
    fn default_engine_state_has_active_primary_record() {
        let state = EngineState::with_display_model(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap(),
        );

        let primary = state
            .display_records
            .iter()
            .find(|record| record.model.key == DisplayKey::Primary)
            .expect("primary record should exist");
        assert!(primary.model.window_active);
        assert!(primary.runtime.is_none());
    }

    #[test]
    fn with_config_seeds_display_records() {
        let external = crate::DisplayIdentity {
            uuid: Some("external".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let model = DisplayStateModel::from_config(crate::WallpaperEngineConfig {
            displays: vec![crate::DisplayConfig {
                selector: crate::DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: None,
            }],
        })
        .unwrap();
        let state = EngineState::with_display_model(model);

        assert!(state.display_records.iter().any(|record| {
            record.model.key == DisplayKey::Identity(external.clone()) && record.model.window_active
        }));
    }

    #[test]
    fn display_callback_refresh_error_does_not_stop_actor() {
        let engine = engine_with_display_records(Vec::new());

        engine
            .actor
            .actor()
            .ask(messages::FailNextRefreshDisplaysForTest)
            .blocking_send()
            .expect("test refresh failure should be armed");

        engine.lifecycle.refresh_target.schedule();

        let sequence = engine
            .actor
            .actor()
            .ask(messages::SequenceForTest { expected: 1 })
            .blocking_send()
            .expect("actor should keep processing after callback refresh failure");
        assert_eq!(sequence, 1);
    }

    #[test]
    fn scene_runtime_state_survives_snapshot_round_trip() {
        let desc = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let state = SceneRuntimeState::try_from(&desc).expect("state should build");

        assert_eq!(state.scaling_mode, ScalingMode::default());
        assert!(
            (state.scaling_factor - 1.0).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 1.0",
            state.scaling_factor
        );
        assert_eq!(state.render_resolution, None);
        assert!(!state.paused);
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_scaling() {
        let desc = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .scaling_mode(ScalingMode::Fill)
        .scaling_factor(1.25)
        .build()
        .expect("scene should build");

        let state = SceneRuntimeState::try_from(&desc).expect("state should build");

        assert_eq!(state.scaling_mode, ScalingMode::Fill);
        assert!(
            (state.scaling_factor - 1.25).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 1.25",
            state.scaling_factor
        );
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_framing() {
        let default_state = SceneRuntimeState::try_from(&crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        ))
        .expect("state should build");
        assert_eq!(default_state.framing, SceneFraming::default());

        let framing = SceneFraming {
            pan_x: 0.1,
            pan_y: 0.9,
        };
        let desc = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .framing(framing)
        .build()
        .expect("scene should build");

        let state = SceneRuntimeState::try_from(&desc).expect("state should build");

        assert_eq!(state.framing, framing);
    }

    #[test]
    fn runtime_refresh_required_only_when_descriptor_changes() {
        let desc = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut resized = desc.clone();
        resized.display.width = 2560;
        let mut different_wallpaper = desc.clone();
        different_wallpaper.scene_path = "/tmp/other.json".to_string();

        assert!(!RuntimeRefreshMode::from_transition(Some(&desc), &desc).is_required());
        assert!(RuntimeRefreshMode::from_transition(Some(&desc), &resized).is_required());
        assert!(
            RuntimeRefreshMode::from_transition(Some(&desc), &different_wallpaper).is_required()
        );
        assert!(RuntimeRefreshMode::from_transition(None, &desc).is_required());
    }

    #[test]
    fn runtime_refresh_mode_reopens_runtime_when_display_descriptor_changes() {
        let desc = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut resized = desc.clone();
        resized.display.width = 2560;
        let mut different_wallpaper = desc.clone();
        different_wallpaper.scene_path = "/tmp/other.json".to_string();

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&desc), &desc),
            RuntimeRefreshMode::Unchanged
        );
        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&desc), &resized),
            RuntimeRefreshMode::ReopenRuntime
        );
        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&desc), &different_wallpaper),
            RuntimeRefreshMode::RebuildExistingRuntime
        );
        assert_eq!(
            RuntimeRefreshMode::from_transition(None, &desc),
            RuntimeRefreshMode::OpenRuntime
        );
    }

    #[test]
    fn runtime_refresh_mode_rebuilds_when_shader_refresh_is_forced() {
        let current = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .shader_cache_path("/tmp/cache")
        .build()
        .expect("scene should build");
        let mut desired = current.clone();
        desired.force_shader_refresh = true;

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&current), &desired),
            RuntimeRefreshMode::RebuildExistingRuntime
        );
    }

    #[test]
    fn runtime_refresh_mode_treats_completed_shader_refresh_as_unchanged() {
        let mut current = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .shader_cache_path("/tmp/cache")
        .force_shader_refresh(true)
        .build()
        .expect("scene should build");
        current.mark_shader_refresh_complete();
        let mut desired = current.clone();
        desired.force_shader_refresh = false;

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&current), &desired),
            RuntimeRefreshMode::Unchanged
        );
    }

    #[test]
    fn runtime_refresh_mode_updates_window_only_when_origin_changes() {
        let desc = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(3, 1920, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut moved = desc.clone();
        moved.display.x = -1920;

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&desc), &moved),
            RuntimeRefreshMode::UpdateWindowOnly
        );
    }

    #[test]
    fn runtime_refresh_mode_reopens_display_change_after_runtime_pause() {
        let mut current = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut desired = current.clone();
        current.paused = true;
        desired.display.width = 2560;

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&current), &desired),
            RuntimeRefreshMode::ReopenRuntime
        );
    }

    #[test]
    fn runtime_refresh_mode_ignores_initial_pause_change_after_open() {
        let current = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut desired = current.clone();
        desired.paused = true;

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&current), &desired),
            RuntimeRefreshMode::Unchanged
        );
    }

    #[test]
    fn runtime_refresh_mode_treats_live_audio_response_change_as_unchanged_after_snapshot_sync() {
        let mut current = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        current.audio_response_enabled = true;
        let desired = current.clone();

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&current), &desired),
            RuntimeRefreshMode::Unchanged
        );
    }

    #[test]
    fn close_all_preserves_display_model_records() {
        let identity = crate::DisplayIdentity {
            uuid: Some("external-display".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let mut state = EngineState::with_display_model(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig {
                displays: vec![crate::DisplayConfig {
                    selector: crate::DisplaySelector::Identity(identity.clone()),
                    window_active: true,
                    wallpaper: None,
                }],
            })
            .unwrap(),
        );
        let live_key = DisplayKey::LiveDisplayId(42);
        let handle = state.reserve_handle_for_key(live_key.clone());
        let desc = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(42, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let last_runtime_state = SceneRuntimeState::try_from(&desc).unwrap();
        let record = state.ensure_record(DisplayRecord {
            key: live_key.clone(),
            live_display: Some(desc.display.clone()),
            assignment: None,
            window_active: true,
            runtime_open: true,
            primary_inheritance_consumed: false,
            bound_to_display: false,
        });
        record.handle = Some(handle);
        record.last_runtime_state = Some(StoredSceneRuntimeState::new(
            desc.clone(),
            last_runtime_state.clone(),
        ));

        state.close_all().unwrap();

        assert_eq!(state.next_handle, 2);
        assert!(state.handles_by_display.is_empty());
        assert!(state.displays_by_handle.is_empty());
        assert!(state.display_records.iter().any(|record| {
            record.model.key == DisplayKey::Primary
                && record.model.window_active
                && !record.model.runtime_open
        }));
        assert!(state.display_records.iter().any(|record| {
            record.model.key == DisplayKey::Identity(identity.clone())
                && record.model.window_active
                && !record.model.runtime_open
        }));
        let live_record = state
            .display_records
            .iter()
            .find(|record| record.model.key == live_key)
            .expect("live display record should be preserved");
        assert!(live_record.handle.is_none());
        assert!(live_record.runtime.is_none());
        assert!(!live_record.model.runtime_open);
        assert!(live_record.last_runtime_state.is_some());
    }

    #[test]
    fn reconcile_scene_configs_make_inputs_active_direct_assignments() {
        let display = crate::DisplayDesc::new(9, 0, 0, 1920, 1080, 1.0);
        let scene = crate::project::SceneDesc::new(
            display.clone(),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut model =
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap();

        model.apply_reconcile(&[scene]).unwrap();

        let key = DisplayKey::LiveDisplayId(display.display_id);
        let record = model
            .records
            .iter()
            .find(|record| record.key == key)
            .expect("display record should exist");
        assert!(record.window_active);
        assert!(matches!(
            record.assignment,
            Some(crate::WallpaperAssignment::Direct(_))
        ));
    }

    #[test]
    fn empty_reconcile_deactivates_active_connected_records() {
        let identity = crate::DisplayIdentity {
            uuid: Some("external-display".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let primary = crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let external =
            crate::DisplayDesc::with_identity(2, identity.clone(), 1920, 0, 1920, 1080, 1.0);
        let live = crate::DisplayDesc::new(3, 3840, 0, 1920, 1080, 1.0);
        let template = crate::project::SceneTemplate::builder("/tmp/project.json")
            .build()
            .unwrap();
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(primary),
                    assignment: Some(crate::WallpaperAssignment::Direct(template.clone())),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                    bound_to_display: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(identity),
                    live_display: Some(external),
                    assignment: Some(crate::WallpaperAssignment::Direct(template.clone())),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                    bound_to_display: false,
                },
                DisplayRecord {
                    key: DisplayKey::LiveDisplayId(live.display_id),
                    live_display: Some(live),
                    assignment: Some(crate::WallpaperAssignment::Direct(template)),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                    bound_to_display: false,
                },
            ],
        };

        model.apply_reconcile(&[]).unwrap();

        assert!(model.records.iter().all(|record| !record.window_active));
        assert!(model.records.iter().all(|record| !record.runtime_open));
    }

    #[test]
    fn reconcile_scene_deactivates_existing_connected_alias_records() {
        let identity = crate::DisplayIdentity {
            uuid: Some("requested-display".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let display = crate::DisplayDesc::with_identity(7, identity.clone(), 0, 0, 1920, 1080, 1.0);
        let scene = crate::project::SceneDesc::new(
            display.clone(),
            "/tmp/requested.json",
            "/tmp/assets",
            60,
            false,
        );
        let template = crate::project::SceneTemplate::builder("/tmp/old.json")
            .build()
            .unwrap();
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(display.clone()),
                    assignment: Some(crate::WallpaperAssignment::Direct(template.clone())),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                    bound_to_display: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(identity),
                    live_display: Some(display.clone()),
                    assignment: Some(crate::WallpaperAssignment::Direct(template)),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                    bound_to_display: false,
                },
            ],
        };

        model.apply_reconcile(&[scene]).unwrap();

        let active_records: Vec<_> = model
            .records
            .iter()
            .filter(|record| record.window_active && record.live_display.as_ref() == Some(&display))
            .collect();
        assert_eq!(active_records.len(), 1);
        assert_eq!(active_records[0].key, DisplayKey::Primary);
        assert!(matches!(
            active_records[0].assignment,
            Some(crate::WallpaperAssignment::Direct(_))
        ));
    }

    #[test]
    fn main_display_change_keeps_a_reconciled_runtime_on_its_display() {
        let identity = |label: &str| crate::DisplayIdentity {
            uuid: Some(label.to_string()),
            ..crate::DisplayIdentity::default()
        };
        let built_in =
            crate::DisplayDesc::with_identity(1, identity("built-in"), 0, 0, 3420, 2214, 2.0);
        let built_in_shifted =
            crate::DisplayDesc::with_identity(1, identity("built-in"), -1710, 0, 3420, 2214, 2.0);
        let external =
            crate::DisplayDesc::with_identity(2, identity("external"), 0, 0, 1920, 1080, 1.0);
        let mut model =
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap();
        model
            .refresh_connected(built_in.clone(), vec![built_in.clone()])
            .unwrap();
        model
            .apply_reconcile(&[crate::project::SceneDesc::new(
                built_in.clone(),
                "/tmp/built-in.json",
                "/tmp/assets",
                60,
                false,
            )])
            .unwrap();
        let mut state = EngineState::with_display_model(model);
        let handle = state.reserve_handle_for_key(DisplayKey::Primary);
        let running = state
            .display_records
            .iter_mut()
            .find(|record| record.model.live_display.as_ref() == Some(&built_in))
            .expect("the reconciled scene should have a record");
        running.handle = Some(handle);
        running.model.runtime_open = true;

        let mut refreshed = DisplayStateModel {
            records: state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        refreshed
            .refresh_connected(
                external.clone(),
                vec![built_in_shifted.clone(), external.clone()],
            )
            .unwrap();
        state.apply_display_model(&refreshed).unwrap();

        let holder = state
            .display_records
            .iter()
            .find(|record| record.handle == Some(handle))
            .expect("the running scene keeps its handle");
        assert_eq!(holder.model.live_display, Some(built_in_shifted));
        assert!(holder.model.should_have_runtime());
        assert_eq!(state.displays_by_handle.get(&handle), Some(&holder.model.key));
        assert!(state.display_records.iter().all(|record| {
            record.model.live_display.as_ref() != Some(&external)
                || !record.model.should_have_runtime()
        }));
    }

    #[test]
    fn reconcile_keeps_disconnected_future_identity_records_untouched() {
        let identity = crate::DisplayIdentity {
            uuid: Some("future-display".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let template = crate::project::SceneTemplate::builder("/tmp/future.json")
            .build()
            .unwrap();
        let future_record = DisplayRecord {
            key: DisplayKey::Identity(identity),
            live_display: None,
            assignment: Some(crate::WallpaperAssignment::Direct(template)),
            window_active: true,
            runtime_open: false,
            primary_inheritance_consumed: false,
            bound_to_display: false,
        };
        let mut model = DisplayStateModel {
            records: vec![future_record.clone()],
        };

        model.apply_reconcile(&[]).unwrap();

        assert_eq!(model.records, vec![future_record]);
    }

    #[test]
    fn reconcile_results_error_when_requested_handle_is_missing() {
        let scene = crate::project::SceneDesc::new(
            crate::DisplayDesc::new(11, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
            "/tmp/assets",
            60,
            false,
        );
        let state = EngineState::with_display_model(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap(),
        );

        let scenes = [scene];
        let model = DisplayStateModel {
            records: state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        let error = scenes
            .reconcile_results(&model, &state.handles_by_display)
            .expect_err("missing requested handle should be an error");

        match error {
            EngineError::Platform(message) => {
                assert!(message.contains("missing scene handle for requested display 11"));
            }
            other => panic!("expected platform error, got {other:?}"),
        }
    }

    #[test]
    fn reconcile_preserves_handle_reservation_when_runtime_no_longer_needed() {
        let primary = crate::DisplayDesc::with_identity(
            1,
            crate::DisplayIdentity {
                uuid: Some("primary".to_string()),
                vendor_id: Some(1),
                model_id: Some(2),
                serial_number: Some(3),
                unit_number: Some(4),
                name: None,
            },
            0,
            0,
            1920,
            1080,
            1.0,
        );
        let mut state = EngineState::with_display_model(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap(),
        );
        let key = DisplayKey::Primary;
        let handle = {
            let handle = state.reserve_handle_for_key(key.clone());
            let record = state
                .display_records
                .iter_mut()
                .find(|record| record.model.key == key)
                .expect("primary record should exist");
            record.handle = Some(handle);
            record.model.live_display = Some(primary.clone());
            record.model.runtime_open = true;
            handle
        };

        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(Mutex::new(MouseButtonTracker::new()))));
        let prepared = <EngineActor as kameo::actor::Spawn>::prepare();
        let mut actor = EngineActor::new(OweBackend, Arc::new(|_handle| {}), state, snapshots, prepared.actor_ref().downgrade());

        actor
            .reconcile_display_descriptors(primary.clone(), vec![primary])
            .unwrap();

        let record = actor
            .state
            .display_records
            .iter()
            .find(|record| record.model.key == key)
            .expect("primary record should remain");
        assert_eq!(record.handle, Some(handle));
        assert!(!record.model.runtime_open);
        assert!(record.runtime.is_none());
        assert_eq!(actor.state.handles_by_display.get(&key), Some(&handle));
        assert_eq!(actor.state.displays_by_handle.get(&handle), Some(&key));
    }

    fn actor_for_display_reports(model: DisplayStateModel) -> EngineActor {
        let state = EngineState::with_display_model(model);
        let snapshots = Arc::new(EngineSnapshotPublisher::new(
            state.snapshot(),
            Arc::new(Mutex::new(MouseButtonTracker::new())),
        ));
        let prepared = <EngineActor as kameo::actor::Spawn>::prepare();
        EngineActor::new(
            OweBackend,
            Arc::new(|_handle| {}),
            state,
            snapshots,
            prepared.actor_ref().downgrade(),
        )
    }

    #[test]
    fn a_display_report_where_the_primary_has_no_pixels_leaves_a_running_scene_alone() {
        let template = crate::project::SceneTemplate::builder("/tmp/primary.json")
            .build()
            .unwrap();
        let mut model = DisplayStateModel::from_config(crate::WallpaperEngineConfig {
            displays: vec![crate::DisplayConfig {
                selector: crate::DisplaySelector::Primary,
                window_active: true,
                wallpaper: Some(crate::WallpaperAssignment::Direct(template)),
            }],
        })
        .unwrap();
        model.records[0].live_display = Some(crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0));
        model.records[0].runtime_open = true;
        let mut actor = actor_for_display_reports(model);
        let before = actor.state.display_records[0].model.clone();

        let in_flux = crate::DisplayDesc::new(1, 0, 0, 0, 0, 1.0);
        actor
            .apply_display_report(in_flux.clone(), vec![in_flux])
            .expect("a report in flux is not an error");

        assert_eq!(actor.state.display_records[0].model, before);
    }

    #[test]
    fn a_secondary_display_without_pixels_is_left_out_until_it_reports_a_size() {
        let mut actor = actor_for_display_reports(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap(),
        );
        let primary = crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let connecting = |width, height| {
            crate::DisplayDesc::with_identity(
                7,
                crate::DisplayIdentity {
                    uuid: Some("external".to_string()),
                    ..crate::DisplayIdentity::default()
                },
                1920,
                0,
                width,
                height,
                1.0,
            )
        };

        actor
            .apply_display_report(primary.clone(), vec![primary.clone(), connecting(0, 0)])
            .expect("a connecting display must not fail the refresh");
        assert_eq!(actor.state.display_records.len(), 1);
        assert_eq!(
            actor.state.display_records[0].model.live_display,
            Some(primary.clone())
        );

        actor
            .apply_display_report(primary.clone(), vec![primary, connecting(2560, 1440)])
            .unwrap();
        assert_eq!(actor.state.display_records.len(), 2);
        assert!(
            actor
                .state
                .display_records
                .iter()
                .any(|record| record.model.live_display == Some(connecting(2560, 1440)))
        );
    }

    #[test]
    fn display_record_blank_when_active_without_assignment() {
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0)),
                assignment: None,
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        assert!(!record.should_have_runtime());
    }

    #[test]
    fn display_record_needs_runtime_when_active_connected_and_assigned() {
        let template = crate::project::SceneTemplate::builder("/tmp/project.json")
            .build()
            .unwrap();
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0)),
                assignment: Some(crate::WallpaperAssignment::Direct(template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        assert!(record.should_have_runtime());
    }

    #[test]
    fn display_record_needs_runtime_for_connected_mirror_assignment() {
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::LiveDisplayId(2),
                live_display: Some(crate::DisplayDesc::new(2, 1920, 0, 1920, 1080, 1.0)),
                assignment: Some(crate::WallpaperAssignment::Mirror(
                    crate::DisplaySelector::Primary,
                )),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        assert!(record.should_have_runtime());
    }

    #[test]
    fn mirror_mouse_update_uses_source_display_geometry() {
        let source = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Direct(
                crate::project::SceneTemplate::builder("/tmp/project.json")
                    .build()
                    .expect("source template should build"),
            )),
        };
        let mirror = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(2, 1920, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(2)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Mirror(
                crate::DisplaySelector::Primary,
            )),
        };
        let state = MousePollState {
            point: NSPoint::new(960.0, 540.0),
            buttons: MouseButtonEdges::from_masks(1, 1, 0),
        };
        let snapshot = vec![source, mirror];
        let snapshot = DisplaySnapshot { entries: &snapshot };

        let update = snapshot.mouse_update_for_entry(state, &snapshot.entries[1]);

        assert!(update.entered);
        assert_eq!(
            update.position,
            Some(
                NormalizedMousePosition::from_window_point(960.0, 540.0, 1920.0, 1080.0)
                    .expect("source point should normalize")
            )
        );
        assert_eq!(
            update.buttons.transitions().collect::<Vec<_>>(),
            vec![MouseButtonState {
                button: 0,
                pressed: true,
            }]
        );
    }

    #[test]
    fn mirror_mouse_update_uses_mirror_display_geometry_for_local_cursor() {
        let source = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Direct(
                crate::project::SceneTemplate::builder("/tmp/project.json")
                    .build()
                    .expect("source template should build"),
            )),
        };
        let mirror = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(2, 1920, 0, 2560, 1440, 1.0),
            handle: Some(crate::project::SceneHandle::new(2)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Mirror(
                crate::DisplaySelector::Primary,
            )),
        };
        let state = MousePollState {
            point: NSPoint::new(2560.0, 360.0),
            buttons: MouseButtonEdges::from_masks(1, 1, 0),
        };
        let snapshot = vec![source, mirror];
        let snapshot = DisplaySnapshot { entries: &snapshot };

        let update = snapshot.mouse_update_for_entry(state, &snapshot.entries[1]);

        assert!(update.entered);
        assert_eq!(
            update.position,
            Some(
                NormalizedMousePosition::from_window_point(640.0, 360.0, 2560.0, 1440.0)
                    .expect("mirror point should normalize")
            )
        );
        assert_eq!(
            update.buttons.transitions().collect::<Vec<_>>(),
            vec![MouseButtonState {
                button: 0,
                pressed: true,
            }]
        );
    }

    #[test]
    fn mirror_mouse_update_resolves_source_display_through_mirror_chain() {
        let source = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Direct(
                crate::project::SceneTemplate::builder("/tmp/project.json")
                    .build()
                    .expect("source template should build"),
            )),
        };
        let intermediate = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(2, 1920, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(2)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Mirror(
                crate::DisplaySelector::Primary,
            )),
        };
        let final_mirror = DisplaySnapshotEntry {
            identity: crate::DisplayIdentity::default(),
            desc: crate::DisplayDesc::new(3, 3840, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(3)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(crate::WallpaperAssignment::Mirror(
                crate::DisplaySelector::LiveDisplayId(2),
            )),
        };
        let state = MousePollState {
            point: NSPoint::new(960.0, 540.0),
            buttons: MouseButtonEdges::from_masks(1, 1, 0),
        };
        let snapshot = vec![source, intermediate, final_mirror];
        let snapshot = DisplaySnapshot { entries: &snapshot };

        let update = snapshot.mouse_update_for_entry(state, &snapshot.entries[2]);

        assert!(update.entered);
        assert_eq!(
            update.position,
            Some(
                NormalizedMousePosition::from_window_point(960.0, 540.0, 1920.0, 1080.0)
                    .expect("source point should normalize")
            )
        );
        assert_eq!(
            update.buttons.transitions().collect::<Vec<_>>(),
            vec![MouseButtonState {
                button: 0,
                pressed: true,
            }]
        );
    }

    #[test]
    fn display_record_scene_desc_converts_direct_assignment() {
        let template = crate::project::SceneTemplate::builder("/tmp/project.json")
            .assets_path("/tmp/assets")
            .fps(30)
            .build()
            .unwrap();
        let display = crate::DisplayDesc::new(3, 0, 0, 1280, 720, 1.0);
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::LiveDisplayId(3),
                live_display: Some(display.clone()),
                assignment: Some(crate::WallpaperAssignment::Direct(template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        let desc = record
            .scene_desc()
            .expect("direct scene should convert")
            .expect("direct assignment should produce a scene");

        assert_eq!(desc.display, display);
        assert_eq!(desc.scene_path, "/tmp/project.json");
        assert_eq!(desc.assets_path, "/tmp/assets");
        assert_eq!(desc.fps, 30);
    }

    #[test]
    fn display_record_scene_desc_returns_none_when_disconnected() {
        let template = crate::project::SceneTemplate::builder("/tmp/project.json")
            .build()
            .unwrap();
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::LiveDisplayId(4),
                live_display: None,
                assignment: Some(crate::WallpaperAssignment::Direct(template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        assert!(record.scene_desc().unwrap().is_none());
    }

    #[test]
    fn display_record_scene_desc_errors_for_unresolved_mirror() {
        let record = DisplayRuntimeRecord {
            model: DisplayRecord {
                key: DisplayKey::LiveDisplayId(5),
                live_display: Some(crate::DisplayDesc::new(5, 0, 1080, 1920, 1080, 1.0)),
                assignment: Some(crate::WallpaperAssignment::Mirror(
                    crate::DisplaySelector::Primary,
                )),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            handle: None,
            runtime: None,
            last_runtime_state: None,
        };

        let error = record
            .scene_desc()
            .expect_err("unresolved mirror should error");
        match error {
            EngineError::Platform(message) => assert_eq!(
                message,
                "mirror assignments must be resolved before runtime creation"
            ),
            other => panic!("expected platform error, got {other:?}"),
        }
    }

    #[test]
    fn display_snapshot_returns_entries_for_configured_displays() {
        let primary_identity = crate::DisplayIdentity {
            uuid: Some("primary".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let external_identity = crate::DisplayIdentity {
            uuid: Some("external".to_string()),
            vendor_id: Some(5),
            model_id: Some(6),
            serial_number: Some(7),
            unit_number: Some(8),
            name: None,
        };
        let disconnected_identity = crate::DisplayIdentity {
            uuid: Some("disconnected".to_string()),
            vendor_id: Some(9),
            model_id: Some(10),
            serial_number: Some(11),
            unit_number: Some(12),
            name: None,
        };
        let primary_display =
            crate::DisplayDesc::with_identity(1, primary_identity.clone(), 0, 0, 1920, 1080, 1.0);
        let external_display = crate::DisplayDesc::with_identity(
            2,
            external_identity.clone(),
            1920,
            0,
            1920,
            1080,
            1.0,
        );
        let primary_assignment = WallpaperAssignment::Direct(
            crate::project::SceneTemplate::builder("/tmp/primary.json")
                .build()
                .unwrap(),
        );
        let engine = engine_with_display_records(vec![
            DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(primary_display.clone()),
                assignment: Some(primary_assignment.clone()),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            DisplayRecord {
                key: DisplayKey::Identity(external_identity.clone()),
                live_display: Some(external_display.clone()),
                assignment: None,
                window_active: false,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            DisplayRecord {
                key: DisplayKey::Identity(disconnected_identity),
                live_display: None,
                assignment: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
        ]);

        let snapshot = engine.display_snapshot();

        assert_eq!(snapshot.len(), 2);
        let primary_entry = snapshot
            .iter()
            .find(|entry| entry.identity == primary_identity)
            .expect("primary entry should be included");
        assert_eq!(primary_entry.desc, primary_display);
        assert_eq!(primary_entry.identity, primary_entry.desc.identity);
        assert!(primary_entry.handle.is_none());
        assert!(primary_entry.window_active);
        assert_eq!(primary_entry.assignment, Some(primary_assignment));

        let external_entry = snapshot
            .iter()
            .find(|entry| entry.identity == external_identity)
            .expect("external entry should be included");
        assert_eq!(external_entry.desc, external_display);
        assert_eq!(external_entry.identity, external_entry.desc.identity);
        assert!(external_entry.handle.is_none());
        assert!(!external_entry.window_active);
        assert!(external_entry.assignment.is_none());
        assert!(
            snapshot
                .iter()
                .all(|entry| entry.desc.display_id == 1 || entry.desc.display_id == 2)
        );
    }

    #[test]
    fn normalized_mouse_for_display_maps_appkit_global_point_to_owe_coordinates() {
        let display = crate::DisplayDesc::new(7, 1920, 120, 3840, 2160, 2.0);
        let lower_point = NSPoint::new(2160.0, 390.0);

        let lower_position = normalized_mouse_for_display(lower_point, &display)
            .expect("point should be inside display");

        assert_eq!(
            lower_position,
            NormalizedMousePosition { x: 0.125, y: 0.75 }
        );

        let higher_point = NSPoint::new(2160.0, 930.0);
        let higher_position = normalized_mouse_for_display(higher_point, &display)
            .expect("point should be inside display");

        assert_eq!(
            higher_position,
            NormalizedMousePosition { x: 0.125, y: 0.25 }
        );
    }

    #[test]
    fn normalized_mouse_for_display_rejects_points_outside_display() {
        let display = crate::DisplayDesc::new(7, 1920, 120, 3840, 2160, 2.0);

        assert_eq!(
            normalized_mouse_for_display(NSPoint::new(1919.0, 390.0), &display),
            None
        );
        assert_eq!(
            normalized_mouse_for_display(NSPoint::new(2160.0, 1200.0), &display),
            None
        );
    }

    #[test]
    fn mouse_update_for_display_releases_buttons_after_cursor_leaves_display() {
        let display = crate::DisplayDesc::new(7, 0, 0, 1920, 1080, 1.0);
        let state = MousePollState {
            point: NSPoint::new(1921.0, 540.0),
            buttons: MouseButtonEdges::from_level_state(MouseButtons::default()),
        };

        let update = mouse_update_for_display(state, &display);

        assert_eq!(
            update,
            MouseDisplayUpdate {
                entered: false,
                position: None,
                buttons: MouseButtonEdges::from_level_state(MouseButtons::default()),
            }
        );
    }

    #[test]
    fn mouse_update_for_display_preserves_tap_transitions_inside_display() {
        let display = crate::DisplayDesc::new(7, 0, 0, 1920, 1080, 1.0);
        let state = MousePollState {
            point: NSPoint::new(960.0, 540.0),
            buttons: MouseButtonEdges::from_masks(0, 1, 1),
        };

        let update = mouse_update_for_display(state, &display);
        let states = update.buttons.states();

        assert!(update.entered);
        assert_eq!(
            update.position,
            Some(NormalizedMousePosition { x: 0.5, y: 0.5 })
        );
        assert_eq!(states[0].button, 0);
        assert!(states[0].pressed);
        assert_eq!(states[1].button, 0);
        assert!(!states[1].pressed);
    }

    #[test]
    fn mouse_update_for_display_does_not_forward_held_level_state_as_press() {
        let display = crate::DisplayDesc::new(7, 0, 0, 1920, 1080, 1.0);
        let state = MousePollState {
            point: NSPoint::new(960.0, 540.0),
            buttons: MouseButtonEdges::from_masks(1, 0, 0),
        };

        let update = mouse_update_for_display(state, &display);

        assert!(update.entered);
        assert!(update.buttons.transitions().next().is_none());
        assert_eq!(
            update.buttons.states()[0],
            MouseButtonState {
                button: 0,
                pressed: true,
            }
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_fps_returns_err_for_unknown_handle() {
        let engine = engine_with_display_records(Vec::new());

        let err = engine
            .set_fps(SceneHandle::new(u64::MAX), 60)
            .await
            .expect_err("unknown handle should fail");
        assert!(matches!(
            err,
            EngineError::InvalidInput(_) | EngineError::Platform(_)
        ));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_framing_refuses_a_position_off_the_display_before_asking_the_actor() {
        let engine = engine_with_display_records(Vec::new());
        let handle = SceneHandle::new(u64::MAX);

        for (pan_x, pan_y) in [
            (f64::NAN, 0.5),
            (0.5, f64::NAN),
            (f64::INFINITY, 0.5),
            (0.5, f64::NEG_INFINITY),
            (-0.1, 0.5),
            (0.5, 1.5),
        ] {
            let err = engine
                .set_framing(handle, SceneFraming { pan_x, pan_y })
                .await
                .expect_err("an invalid framing should be refused");
            // The unknown handle would have produced a different message had the
            // request reached the actor.
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if message == "framing must be fractions between 0 and 1"),
                "{pan_x}/{pan_y} gave {err:?}"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_framing_forwards_a_valid_position_to_the_actor() {
        let engine = engine_with_display_records(Vec::new());

        for framing in [
            SceneFraming::default(),
            SceneFraming {
                pan_x: 0.0,
                pan_y: 1.0,
            },
        ] {
            let err = engine
                .set_framing(SceneHandle::new(u64::MAX), framing)
                .await
                .expect_err("unknown handle should fail");
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if message.contains("unknown scene handle")),
                "{framing:?} gave {err:?}"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preview_framing_refuses_a_position_off_the_display_before_asking_the_actor() {
        let engine = engine_with_display_records(Vec::new());
        let handle = SceneHandle::new(u64::MAX);

        for (pan_x, pan_y) in [
            (f64::NAN, 0.5),
            (0.5, f64::NAN),
            (f64::INFINITY, 0.5),
            (0.5, f64::NEG_INFINITY),
            (-0.1, 0.5),
            (0.5, 1.5),
        ] {
            let err = engine
                .preview_framing(handle, SceneFraming { pan_x, pan_y })
                .await
                .expect_err("an invalid framing should be refused");
            // The unknown handle would have produced a different message had the
            // request reached the actor.
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if message == "framing must be fractions between 0 and 1"),
                "{pan_x}/{pan_y} gave {err:?}"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preview_framing_forwards_a_valid_position_to_the_actor() {
        let engine = engine_with_display_records(Vec::new());

        for framing in [
            SceneFraming::default(),
            SceneFraming {
                pan_x: 0.0,
                pan_y: 1.0,
            },
        ] {
            let err = engine
                .preview_framing(SceneHandle::new(u64::MAX), framing)
                .await
                .expect_err("unknown handle should fail");
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if message.contains("unknown scene handle")),
                "{framing:?} gave {err:?}"
            );
        }
    }

    #[test]
    fn a_property_document_reaches_the_renderer_as_one_flat_object() {
        for (document, flat) in [
            ("{}", "{}"),
            (
                r#"{"example":{"inner":true},"count":1.5,"label":"demo"}"#,
                r#"{"count":1.5,"example_inner":true,"label":"demo"}"#,
            ),
            // A cleared text property is the empty string, not a missing one.
            (r#"{"text":null}"#, r#"{"text":""}"#),
            // Whitespace and key order are the caller's, the renderer's input is not.
            (
                "  { \"b\" : 2,\n \"a\" : { \"c\" : false } }  ",
                r#"{"a_c":false,"b":2}"#,
            ),
        ] {
            assert_eq!(
                flat_property_document(document).expect("a valid document"),
                flat,
                "{document}"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preview_property_override_refuses_a_document_that_is_not_an_object_before_asking_the_actor(
    ) {
        let engine = engine_with_display_records(Vec::new());
        let handle = SceneHandle::new(u64::MAX);

        for document in [
            "[]",
            "1",
            r#""text""#,
            "null",
            r#"{"broken":[1,2,3]}"#,
            "{",
            "",
        ] {
            let err = engine
                .preview_property_override(handle, "/library/1/project.json", document)
                .await
                .expect_err("a malformed document should be refused");
            // The unknown handle would have produced a different message had the
            // document reached the actor.
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if !message.contains("unknown scene handle")),
                "{document:?} gave {err:?}"
            );
            // The same refusal as the call that loads the scene again, so an
            // editor cannot show a document that Apply would then refuse.
            let loaded = engine
                .set_property_override(handle, document)
                .await
                .expect_err("the loading call refuses the same document");
            assert_eq!(err.to_string(), loaded.to_string(), "{document:?}");
        }

        let err = engine
            .preview_property_override(handle, "/library/1/project.json", "[]")
            .await
            .expect_err("an array root should be refused");
        assert!(
            matches!(&err, EngineError::InvalidInput(message)
                if message == "override root must be a JSON object"),
            "{err:?}"
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preview_property_override_flattens_nested_documents_and_forwards_a_valid_one_to_the_actor(
    ) {
        let engine = engine_with_display_records(Vec::new());

        for document in [
            "{}",
            r#"{"alpha":0.5}"#,
            r#"{"example":{"inner":true},"label":null}"#,
        ] {
            let err = engine
                .preview_property_override(
                    SceneHandle::new(u64::MAX),
                    "/library/1/project.json",
                    document,
                )
                .await
                .expect_err("unknown handle should fail");
            assert!(
                matches!(&err, EngineError::InvalidInput(message)
                    if message.contains("unknown scene handle")),
                "{document:?} gave {err:?}"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_paused_returns_err_for_unknown_handle() {
        let engine = engine_with_display_records(Vec::new());

        let err = engine
            .set_paused(SceneHandle::new(u64::MAX), true)
            .await
            .expect_err("unknown handle should fail");
        assert!(matches!(
            err,
            EngineError::InvalidInput(_) | EngineError::Platform(_)
        ));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_all_paused_allows_empty_runtime_set() {
        let engine = engine_with_display_records(Vec::new());

        engine
            .set_all_paused(true, Vec::new())
            .await
            .expect("empty runtime set should be a no-op");
    }

    #[test]
    fn set_all_paused_skips_preserved_handles_without_runtime() {
        let mut state = EngineState::with_display_model(
            DisplayStateModel::from_config(crate::WallpaperEngineConfig::default()).unwrap(),
        );
        let key = DisplayKey::Primary;
        let handle = state.reserve_handle_for_key(key.clone());
        let record = state
            .display_records
            .iter_mut()
            .find(|record| record.model.key == key)
            .expect("primary record should exist");
        record.handle = Some(handle);
        record.runtime = None;
        record.model.runtime_open = false;

        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(Mutex::new(MouseButtonTracker::new()))));
        let prepared = <EngineActor as kameo::actor::Spawn>::prepare();
        let mut actor = EngineActor::new(OweBackend, Arc::new(|_handle| {}), state, snapshots, prepared.actor_ref().downgrade());

        actor
            .set_all_paused(true, &[])
            .expect("inactive preserved handles should be ignored");
    }
}
