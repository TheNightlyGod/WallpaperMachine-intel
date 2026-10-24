// Clean-room implementation from the WallpaperMachine spec r1a-core-engine.md; written without access to the original source.
mod actor;
mod audio_requirement;
mod config;
mod messages;
mod runtime;
mod snapshot;
mod state;
mod surface_recovery;
#[cfg(feature = "bridge-contract-tests")]
#[doc(hidden)]
pub mod contract_testing;

pub use audio_requirement::AudioRequirementCallback;
pub use surface_recovery::{RecoveryOutcome, RecoveryReason, RecoveryStep};
use std::sync::{Arc, Mutex};

use serde_json::Value;

use actor::{EngineActor, EngineActorHandle};
use state::EngineState;
pub use config::{DisplayConfig, DisplaySelector, WallpaperAssignment, WallpaperEngineConfig};
use objc2_foundation::NSPoint;
pub use snapshot::EngineSnapshotPublisher;

use crate::{
    DisplayDesc, DisplayIdentity, EngineError,
    display::{
        callback::{DisplayChangeRegistration, DisplayRefreshTarget},
        state::DisplayStateModel,
    },
    render::RendererSurfaceCounters,
    media::audio::{
        AudioCaptureError, AudioFrameConsumer, AudioResponseBlock, AudioResponseResampler,
        AudioVolume, InterleavedStereoF32, MonoPcmF32,
    },
    owe::backend::{AudioSpectrum128, OweBackend},
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult, SerdeValudeExt},
    window::{MouseButtonEdges, MouseButtonTracker, MouseButtons, NormalizedMousePosition},
};

#[derive(Clone, Debug, PartialEq)]
pub struct DisplaySnapshotEntry {
    pub identity: DisplayIdentity,
    pub desc: DisplayDesc,
    pub handle: Option<SceneHandle>,
    /// Capability committed by the currently live native renderer.
    pub accepts_pointer_input: bool,
    /// Whether the live scene on this display is paused, for any reason: the
    /// user's choice, power policy, or this display being covered. A paused
    /// scene does not consume pointer input. False without a live scene.
    pub paused: bool,
    pub window_active: bool,
    pub assignment: Option<WallpaperAssignment>,
}

/// One open scene and its window: the live scene of a display, or one kept
/// loaded and paused for a desktop the person left, which runs again when its
/// wallpaper comes back to that display ([`WallpaperEngine::set_parked_scenes`]).
#[derive(Clone, Debug, PartialEq)]
pub struct SceneWindowEntry {
    pub display_id: u32,
    pub handle: SceneHandle,
    /// The descriptor the scene runs.
    pub desc: SceneDesc,
    /// The window server's number for the scene's window; `None` without one.
    pub window_number: Option<isize>,
    /// Kept paused rather than shown as the display's live scene.
    pub parked: bool,
}

impl SceneWindowEntry {
    fn of(runtime: &runtime::SceneRuntime, handle: SceneHandle, parked: bool) -> Self {
        Self {
            display_id: runtime.display_id(),
            handle,
            desc: runtime.desc.clone(),
            window_number: runtime.window_number(),
            parked,
        }
    }
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

/// The first-frame callback the host installed last. Shared by the engine
/// handle and by every renderer the engine thread opens, so installing a new
/// callback also applies to scenes that are already running.
#[derive(Clone)]
struct FirstFrameCallbackCell {
    installed: Arc<arc_swap::ArcSwap<FirstFrameCallback>>,
}

impl Default for FirstFrameCallbackCell {
    fn default() -> Self {
        let nothing: FirstFrameCallback = Arc::new(|_handle| {});
        Self { installed: Arc::new(arc_swap::ArcSwap::from_pointee(nothing)) }
    }
}

impl FirstFrameCallbackCell {
    fn set(&self, callback: FirstFrameCallback) {
        self.installed.store(Arc::new(callback));
    }

    /// The closure a renderer is given. It stays the same for the renderer's
    /// life and looks up whatever is installed each time a frame is presented.
    fn callback(&self) -> FirstFrameCallback {
        let cell = self.clone();
        Arc::new(move |handle| {
            let installed = cell.installed.load_full();
            (*installed)(handle);
        })
    }
}

/// What a display reconfiguration event asks of the engine: a refresh, on the
/// short-lived thread the registration starts for it.
struct RefreshOnDisplayChange {
    actor: kameo::actor::ActorRef<EngineActor>,
}

impl DisplayRefreshTarget for RefreshOnDisplayChange {
    /// Blocks until the engine thread has handled the refresh, which is why the
    /// registration keeps later events absorbed while it waits.
    fn schedule(&self) {
        match self.actor.ask(messages::RefreshDisplays).blocking_send() {
            Ok(()) => {}
            Err(kameo::error::SendError::HandlerError(error)) => {
                log::warn!("[wallpaper-core display] display refresh failed: {error}");
            }
            Err(error) => log::warn!(
                "[wallpaper-core display] skipped display refresh because actor mailbox failed: {error}"
            ),
        }
    }
}

/// What lives as long as the engine handle: the object display events call
/// and the registration that makes them call it. Both are held for their drop.
#[allow(dead_code)]
struct EngineLifecycle {
    on_change: Arc<RefreshOnDisplayChange>,
    subscription: Option<DisplayChangeRegistration<RefreshOnDisplayChange>>,
}

impl EngineLifecycle {
    fn new(actor: &EngineActorHandle) -> Result<Self, EngineError> {
        let on_change = Arc::new(RefreshOnDisplayChange { actor: actor.actor().clone() });
        // The refresh thread waits for the engine's reply, which a single
        // thread running the engine as a task could never give.
        let single_thread = tokio::runtime::Handle::try_current().is_ok_and(|handle| {
            handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::CurrentThread
        });
        let subscription = if cfg!(test) && single_thread {
            None
        } else {
            Some(DisplayChangeRegistration::register(&on_change)?)
        };
        Ok(Self { on_change, subscription })
    }

    /// A lifecycle that listens to nothing, for engines a test builds around
    /// an actor it controls itself.
    #[cfg(test)]
    fn unsubscribed(actor: &EngineActorHandle) -> Self {
        Self {
            on_change: Arc::new(RefreshOnDisplayChange { actor: actor.actor().clone() }),
            subscription: None,
        }
    }
}

impl WallpaperEngine {
    pub fn new() -> Result<Self, EngineError> {
        Self::with_config(WallpaperEngineConfig::default())
    }

    pub fn with_config(config: WallpaperEngineConfig) -> Result<Self, EngineError> {
        let backend = OweBackend::initialize()?;
        // An invalid configuration fails here, before anything starts.
        let state = EngineState::with_display_model(DisplayStateModel::from_config(config)?);
        let snapshot = state.snapshot();
        let mouse_buttons = Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(
            crate::window::press_lands_on_desktop,
        ))));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(snapshot, Arc::clone(&mouse_buttons)));
        let first_frame_callback = FirstFrameCallbackCell::default();
        let actor = EngineActorHandle::spawn(
            backend,
            first_frame_callback.callback(),
            state,
            Arc::clone(&snapshots),
        )?;
        let mouse_event_monitor = Arc::new(Mutex::new(None));
        Self::install_pointer_monitor_hook(&mouse_event_monitor, &mouse_buttons, &snapshots);
        let lifecycle = Arc::new(EngineLifecycle::new(&actor)?);
        Ok(Self {
            backend,
            first_frame_callback,
            snapshots,
            audio_response_resampler: Arc::new(Mutex::new(AudioResponseResampler::new())),
            mouse_buttons,
            mouse_event_monitor,
            actor,
            lifecycle,
        })
    }

    /// Installs the callback told when a scene presents its first frame. It
    /// replaces the earlier one, also for scenes that are already open.
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
        // A handler's own error comes back unchanged; a dead channel becomes
        // the mailbox error of `From`.
        self.actor.actor().ask(message).send().await.map_err(EngineError::from)
    }

    pub async fn refresh_displays(&self) -> Result<(), EngineError> {
        self.ask_actor(messages::RefreshDisplays).await
    }

    /// One entry per display slot that has a live display, as of the last
    /// publication. Read without waiting for the engine thread.
    #[must_use]
    pub fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.snapshots.load().displays.clone()
    }

    /// Every open scene with its window, live and parked, as of the last
    /// publication. Read without waiting for the engine thread.
    #[must_use]
    pub fn scene_windows(&self) -> Vec<SceneWindowEntry> {
        self.snapshots.load().scenes.clone()
    }

    /// Sets which scenes the display `display_id` keeps loaded and paused
    /// when its live scene changes to another wallpaper, by scene path.
    ///
    /// A scene whose path is listed is parked instead of replaced when its
    /// display moves on, and it is the one that runs again when a reconcile
    /// brings its wallpaper back: no load, no new window, the same handle. A
    /// parked scene whose path is no longer listed is closed now. An empty
    /// list keeps nothing and closes every parked scene of the display. The
    /// list is runtime state, never saved.
    pub async fn set_parked_scenes(
        &self,
        display_id: u32,
        scene_paths: Vec<String>,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetParkedScenes { display_id, scene_paths }).await
    }

    #[cfg(test)]
    pub async fn actor_ping_for_test(&self) -> Result<(), EngineError> {
        self.ask_actor(messages::Ping).await
    }

    #[cfg(test)]
    pub async fn actor_display_record_count_for_test(&self) -> Result<usize, EngineError> {
        self.ask_actor(messages::DisplayRecordCountForTest).await
    }

    #[cfg(test)]
    pub async fn actor_sequence_for_test(&self, expected: u64) -> Result<u64, EngineError> {
        self.ask_actor(messages::SequenceForTest { expected }).await
    }

    /// Starts an engine shell with the default state, stops it and sends it one
    /// message, returning the error that gives.
    #[cfg(test)]
    pub async fn actor_closed_error_for_test() -> EngineError {
        let state = EngineState::default();
        let mouse_buttons = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let snapshots =
            Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::clone(&mouse_buttons)));
        let first_frame_callback = FirstFrameCallbackCell::default();
        let actor = EngineActorHandle::spawn(
            OweBackend,
            first_frame_callback.callback(),
            state,
            Arc::clone(&snapshots),
        )
        .expect("test actor shell should start");
        let stopped = actor.actor().stop_gracefully().await;
        assert!(stopped.is_ok(), "the test actor shell should accept a stop");
        actor.actor().wait_for_shutdown().await;
        let lifecycle = Arc::new(EngineLifecycle::unsubscribed(&actor));
        let engine = WallpaperEngine {
            backend: OweBackend,
            first_frame_callback,
            snapshots,
            audio_response_resampler: Arc::new(Mutex::new(AudioResponseResampler::new())),
            mouse_buttons,
            mouse_event_monitor: Arc::new(Mutex::new(None)),
            actor,
            lifecycle,
        };
        engine
            .actor_ping_for_test()
            .await
            .expect_err("a stopped engine must refuse every message")
    }

    pub async fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        wallpaper: WallpaperAssignment,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.ask_actor(messages::SetWallpaperForDisplay { selector, wallpaper }).await
    }

    pub async fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.ask_actor(messages::CreateWindowForDisplay { selector }).await
    }

    pub async fn destroy_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::DestroyWindowForDisplay { selector }).await
    }

    pub async fn reconcile_scenes(
        &self,
        scenes: Vec<SceneDesc>,
    ) -> Result<Vec<SceneResult>, EngineError> {
        self.ask_actor(messages::ReconcileScenes { scenes }).await
    }

    pub async fn close_all_scenes(&self) -> Result<(), EngineError> {
        self.ask_actor(messages::CloseAllScenes).await
    }

    pub async fn set_scaling_mode(
        &self,
        handle: SceneHandle,
        mode: ScalingMode,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetScalingMode { handle, mode }).await
    }

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
        self.ask_actor(messages::SetScalingFactor { handle, factor }).await
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

    pub async fn set_fps(&self, handle: SceneHandle, fps: u32) -> Result<(), EngineError> {
        if fps == 0 {
            return Err(EngineError::InvalidInput("fps must be greater than zero".to_string()));
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

    pub async fn set_paused(&self, handle: SceneHandle, paused: bool) -> Result<(), EngineError> {
        self.ask_actor(messages::SetPaused { handle, paused }).await
    }

    /// Live-updates the paused state for all open scenes in one pass: each
    /// scene is paused when `paused` is set or its display is in
    /// `suspended_displays`, and resumed otherwise. A covered display therefore
    /// never runs during a global resume.
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

    /// Reads renderer work counters for every open scene, plus the process-wide
    /// counters that belong to no single surface.
    pub async fn renderer_counters(
        &self,
    ) -> Result<(Vec<RendererSurfaceCounters>, Vec<u64>), EngineError> {
        let surfaces = self.ask_actor(messages::RendererCounters).await?;
        Ok((surfaces, self.backend.shared_counters()?))
    }

    pub async fn set_mouse_position(
        &self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        self.ask_actor(messages::SetMousePosition { handle, x, y }).await
    }

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
        self.ask_actor(messages::SetMouseButton { handle, button, pressed }).await
    }

    pub async fn set_mouse_entered(
        &self,
        handle: SceneHandle,
        entered: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetMouseEntered { handle, entered }).await
    }

    /// Samples the pointer once and delivers it to every scene that reads it.
    ///
    /// With no scene reading the pointer this is success without a message, also
    /// when the engine thread is gone. Otherwise the cursor and the buttons are
    /// read on the main thread, under the tracker's lock, and one message
    /// carries them to the engine thread.
    pub async fn poll_mouse_position(&self) -> Result<(), EngineError> {
        if !self.snapshots.load().has_pointer_consumers() {
            return Ok(());
        }
        let tracker = Arc::clone(&self.mouse_buttons);
        let snapshots = Arc::clone(&self.snapshots);
        let sample = crate::window::MainThread::dispatch(move || {
            let mut tracker = tracker.lock().unwrap_or_else(|error| error.into_inner());
            // The last consumer may have left since the check above.
            if !snapshots.load().has_pointer_consumers() {
                return None;
            }
            let point = objc2_app_kit::NSEvent::mouseLocation();
            let pressed = objc2_app_kit::NSEvent::pressedMouseButtons() as u64;
            tracker.sync_down_mask(pressed);
            Some(MousePollState { point, buttons: tracker.consume_edges() })
        });
        match sample {
            Some(state) => self.poll_mouse_state(state).await,
            None => Ok(()),
        }
    }

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
        self.ask_actor(messages::SetRenderResolution { handle, width, height }).await
    }

    pub async fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioResponseEnabled { handle, enabled }).await
    }

    /// Delivers the host's current player state to one scene.
    pub async fn update_media(&self, handle: SceneHandle, enabled: bool,
        state: crate::media::MediaPollResult) -> Result<(), EngineError> {
        self.ask_actor(messages::UpdateMedia { handle, enabled, state }).await
    }

    /// Enables or disables now-playing events for one scene.
    pub async fn set_media_integration_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetMediaIntegrationEnabled { handle, enabled })
            .await
    }

    /// Delivers one SceneScript media event as already-serialized JSON.
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

    pub async fn set_audio_volume(
        &self,
        handle: SceneHandle,
        volume: AudioVolume,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioVolume { handle, volume }).await
    }

    pub async fn set_audio_muted(
        &self,
        handle: SceneHandle,
        muted: bool,
    ) -> Result<(), EngineError> {
        self.ask_actor(messages::SetAudioMuted { handle, muted }).await
    }

    pub async fn set_property_override<T: Into<String> + Send>(
        &self,
        handle: SceneHandle,
        json: T,
    ) -> Result<(), EngineError> {
        let flat_json = flat_property_document(&json.into())?;
        self.ask_actor(messages::SetPropertyOverride { handle, flat_json }).await
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

    pub async fn reset_property_override(&self, handle: SceneHandle) -> Result<(), EngineError> {
        self.ask_actor(messages::ResetPropertyOverride { handle }).await
    }

    async fn poll_mouse_state(&self, state: MousePollState) -> Result<(), EngineError> {
        self.ask_actor(messages::PollMouseState { state }).await
    }
}

/// Parses a property document and flattens it into the one-level JSON object
/// the renderer reads, the same way for every call that hands the renderer one.
fn flat_property_document(json: &str) -> Result<String, EngineError> {
    let document: Value = serde_json::from_str(json)
        .map_err(|error| EngineError::InvalidInput(error.to_string()))?;
    // The flat form is a sorted map, so the text is compact with keys in
    // ascending order whatever the caller wrote.
    let flat = document.flatten()?;
    serde_json::to_string(&flat).map_err(|error| EngineError::InvalidInput(error.to_string()))
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
        DisplayPlane::of(self.display_reacting_to(state, entry)).read(state)
    }

    /// The display whose geometry decides what a scene sees of the cursor. A
    /// mirror follows the cursor on its own display, else on the display of
    /// the slot it ultimately mirrors; with no resolvable source its own
    /// display applies.
    fn display_reacting_to(&self, state: MousePollState, entry: &'a DisplaySnapshotEntry) -> &'a DisplayDesc {
        if !matches!(entry.assignment, Some(WallpaperAssignment::Mirror(_)))
            || DisplayPlane::of(&entry.desc).contains(state.point)
        {
            return &entry.desc;
        }
        self.mirror_source(entry).map_or(&entry.desc, |source| &source.desc)
    }

    /// The entry a chain of mirrors ends at. A cycle or a selector naming no
    /// entry leaves no source.
    fn mirror_source(&self, entry: &'a DisplaySnapshotEntry) -> Option<&'a DisplaySnapshotEntry> {
        let mut visited = vec![std::ptr::from_ref(entry)];
        let mut current = entry;
        while let Some(WallpaperAssignment::Mirror(selector)) = &current.assignment {
            let next = self.entry_for_selector(selector)?;
            let address = std::ptr::from_ref(next);
            if visited.contains(&address) {
                return None;
            }
            visited.push(address);
            current = next;
        }
        Some(current)
    }

    /// The entry a selector names. The primary slot is the first entry: the
    /// snapshot lists slots in order and the primary comes first.
    fn entry_for_selector(&self, selector: &DisplaySelector) -> Option<&'a DisplaySnapshotEntry> {
        let entries = self.entries;
        match selector {
            DisplaySelector::Primary => entries.first(),
            DisplaySelector::Identity(identity) => entries
                .iter()
                .find(|candidate| identity.match_score(&candidate.identity).is_some()),
            DisplaySelector::LiveDisplayId(display_id) => {
                entries.iter().find(|candidate| candidate.desc.display_id == *display_id)
            }
        }
    }
}

/// A display as a rectangle of AppKit global points: its origin in the lower
/// left and its pixel size over its scale (a scale of zero or less is read as
/// the smallest positive number).
struct DisplayPlane {
    left: f64,
    bottom: f64,
    width: f64,
    height: f64,
}

impl DisplayPlane {
    fn of(display: &DisplayDesc) -> Self {
        let scale =
            if display.scale_factor > 0.0 { display.scale_factor } else { f64::MIN_POSITIVE };
        Self {
            left: f64::from(display.x),
            bottom: f64::from(display.y),
            width: f64::from(display.width) / scale,
            height: f64::from(display.height) / scale,
        }
    }

    /// The point measured from the plane's origin, or none outside the plane
    /// (the far edges are outside).
    fn offset_of(&self, point: NSPoint) -> Option<(f64, f64)> {
        let (dx, dy) = (point.x - self.left, point.y - self.bottom);
        ((0.0..self.width).contains(&dx) && (0.0..self.height).contains(&dy)).then_some((dx, dy))
    }

    fn contains(&self, point: NSPoint) -> bool {
        self.offset_of(point).is_some()
    }

    /// Where the point lies as a scene reads it: x from the left edge, y from
    /// the top (AppKit's grows upward). None outside the plane or for
    /// geometry that cannot be normalised.
    fn scene_position(&self, point: NSPoint) -> Option<NormalizedMousePosition> {
        let (dx, dy) = self.offset_of(point)?;
        NormalizedMousePosition::from_window_point(dx, dy, self.width, self.height)
    }

    /// What one sample means for a scene on this plane: inside, the position
    /// and the sample's edges; outside, not entered and every button released.
    fn read(&self, sample: MousePollState) -> MouseDisplayUpdate {
        match self.offset_of(sample.point) {
            Some(_) => MouseDisplayUpdate {
                entered: true,
                position: self.scene_position(sample.point),
                buttons: sample.buttons,
            },
            None => MouseDisplayUpdate {
                entered: false,
                position: None,
                buttons: MouseButtonEdges::from_level_state(MouseButtons::default()),
            },
        }
    }
}

/// One sample of the system pointer: where it is and which buttons changed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct MousePollState {
    point: NSPoint,
    buttons: MouseButtonEdges,
}

/// What a single display's scene is told about the pointer after a sample.
#[derive(Clone, Copy, Debug, PartialEq)]
struct MouseDisplayUpdate {
    entered: bool,
    position: Option<NormalizedMousePosition>,
    buttons: MouseButtonEdges,
}

impl<M> From<kameo::error::SendError<M, EngineError>> for EngineError {
    fn from(error: kameo::error::SendError<M, EngineError>) -> Self {
        match error {
            kameo::error::SendError::HandlerError(inner) => inner,
            other => EngineError::Platform(format!("engine actor mailbox failed: {other}")),
        }
    }
}

impl WallpaperEngine {
    /// The resampler if nobody else is using it; a lock a panic poisoned still
    /// holds a usable resampler.
    fn try_resampler(&self) -> Option<std::sync::MutexGuard<'_, AudioResponseResampler>> {
        match self.audio_response_resampler.try_lock() {
            Ok(guard) => Some(guard),
            Err(std::sync::TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }

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

impl WallpaperEngine {
    /// Runs one submission through the resampler. `feed` pushes the caller's
    /// frames into it and hands every block it yields to the function it is
    /// given; blocks reach the renderer in order and the first renderer error
    /// ends the delivery of the rest and is the result.
    fn deliver_through_resampler(
        &self,
        feed: impl FnOnce(&mut AudioResponseResampler, &mut dyn FnMut(AudioResponseBlock<'_>)),
    ) -> Result<(), AudioCaptureError> {
        // A real-time thread calls this: a resampler somebody else is inside
        // means this submission is dropped, never waited for.
        let Some(mut resampler) = self.try_resampler() else {
            return Ok(());
        };
        let mut first_error = None;
        feed(&mut resampler, &mut |block| {
            first_error = first_error.take().or_else(|| self.submit_audio_response_block(&block).err());
        });
        first_error.map_or(Ok(()), Err)
    }
}

impl AudioFrameConsumer for WallpaperEngine {
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError> {
        self.deliver_through_resampler(|resampler, deliver| {
            resampler.push_stereo(&frames, deliver);
        })
    }

    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
        self.deliver_through_resampler(|resampler, deliver| {
            resampler.push_mono(&frames, deliver);
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::display::state::{DisplayKey, DisplayRecord};
    use crate::engine::runtime::{RuntimeRefreshMode, SceneRuntime, SceneRuntimeState};
    use crate::project::{SceneDescSliceExt, SceneTemplate};

    fn fixture_desc() -> SceneDesc {
        SceneDesc::builder(DisplayDesc::new(87, -613, 137, 2496, 1408, 2.0), "/virtual/orchid/scene.json")
            .fps(53).build().unwrap()
    }

    fn fixture_record(desc: Option<&SceneDesc>, active: bool) -> DisplayRecord {
        DisplayRecord {
            key: DisplayKey::Primary,
            live_display: desc.map(|d| d.display.clone()),
            assignment: desc.map(|d| WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(d))),
            window_active: active,
            runtime_open: false,
            primary_inheritance_consumed: true,
            bound_to_display: false,
        }
    }

    fn run_async<T>(body: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap().block_on(body)
    }

    fn make_actor(state: EngineState) -> EngineActor {
        use kameo::actor::Spawn;
        let prepared = EngineActor::prepare();
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(|| true))));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), tracker));
        EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots, prepared.actor_ref().downgrade())
    }

    fn snapshot_entry(display: DisplayDesc, assignment: Option<WallpaperAssignment>) -> DisplaySnapshotEntry {
        DisplaySnapshotEntry { identity: display.identity.clone(), desc: display, handle: None, accepts_pointer_input: false, paused: false, window_active: true, assignment }
    }

    fn pointer_sample(x: f64, y: f64, down: u64, pressed: u64, released: u64) -> MousePollState {
        MousePollState { point: NSPoint::new(x, y), buttons: MouseButtonEdges::from_masks(down, pressed, released) }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn polling_without_consumers_never_asks_even_a_closed_actor() {
        let engine = cleanroom_et1(Vec::new());
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
        }], scenes: Vec::new() });
        engine.poll_mouse_position().await.unwrap();
        let edges = engine.mouse_buttons.lock().unwrap().consume_edges();
        assert_eq!(edges.transitions().map(|edge| (edge.button, edge.pressed)).collect::<Vec<_>>(), vec![(0, true)]);
    }

    fn cleanroom_et1(records: Vec<DisplayRecord>) -> WallpaperEngine {
        // CLEANROOM ET1: no display registration, monitors or native windows.
        let backend = OweBackend;
        let state = EngineState::with_display_model(DisplayStateModel { records });
        let mouse_buttons = Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(|| true))));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), mouse_buttons.clone()));
        let first_frame_callback = FirstFrameCallbackCell::default();
        let actor = EngineActorHandle::spawn(backend, first_frame_callback.callback(), state, snapshots.clone()).unwrap();
        let lifecycle = Arc::new(EngineLifecycle::unsubscribed(&actor));
        WallpaperEngine { backend, first_frame_callback, snapshots,
            audio_response_resampler: Arc::new(Mutex::new(AudioResponseResampler::new())),
            mouse_buttons, mouse_event_monitor: Arc::new(Mutex::new(None)), actor, lifecycle }
    }

    #[test]
    fn default_engine_state_has_active_primary_record() {
        // CLEANROOM ET2
        let state = EngineState::default();
        assert_eq!(state.display_records.len(), 1);
        let slot = &state.display_records[0];
        assert_eq!(slot.model.key, DisplayKey::Primary);
        assert!(slot.model.window_active);
        assert!(!slot.model.runtime_open);
        assert!(slot.model.assignment.is_none());
        assert!(slot.model.live_display.is_none());
        assert!(slot.handle.is_none());
        assert!(slot.runtime.is_none());
        assert!(slot.last_runtime_state.is_none());
        assert!(state.snapshot().displays.is_empty());
        assert!(state.handles_by_display.is_empty());
        assert!(state.displays_by_handle.is_empty());
        assert_eq!(state.next_handle, 1);
    }

    #[test]
    fn with_config_seeds_display_records() {
        // CLEANROOM ET3
        let identity = DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() };
        let assignment = WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&fixture_desc()));
        let config = WallpaperEngineConfig { displays: vec![
            DisplayConfig { selector: DisplaySelector::Primary, window_active: true, wallpaper: Some(assignment.clone()) },
            DisplayConfig { selector: DisplaySelector::Identity(identity.clone()), window_active: false, wallpaper: None },
            DisplayConfig { selector: DisplaySelector::LiveDisplayId(203), window_active: true, wallpaper: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)) },
        ] };
        let state = EngineState::with_display_model(DisplayStateModel::from_config(config).unwrap());
        assert_eq!(state.display_records.iter().map(|r| r.model.key.clone()).collect::<Vec<_>>(), vec![DisplayKey::Primary, DisplayKey::Identity(identity), DisplayKey::LiveDisplayId(203)]);
        assert_eq!(state.display_records[0].model.assignment, Some(assignment));
        assert!(!state.display_records[1].model.window_active);
        assert!(matches!(state.display_records[2].model.assignment, Some(WallpaperAssignment::Mirror(DisplaySelector::Primary))));
        for record in &state.display_records {
            assert!(record.runtime.is_none());
            assert!(record.handle.is_none());
            assert!(record.last_runtime_state.is_none());
        }
        assert!(state.handles_by_display.is_empty());
        assert!(state.snapshot().displays.is_empty());
    }

    #[test]
    fn display_callback_refresh_error_does_not_stop_actor() {
        // CLEANROOM ET4
        run_async(async {
            let engine = cleanroom_et1(vec![fixture_record(None, true)]);
            engine.actor.actor().ask(messages::FailNextRefreshDisplaysForTest).await.unwrap();
            assert!(engine.actor.actor().ask(actor::RefreshFailurePendingForTest).await.unwrap());
            let on_change = engine.lifecycle.on_change.clone();
            tokio::task::spawn_blocking(move || on_change.schedule()).await.unwrap();
            assert!(!engine.actor.actor().ask(actor::RefreshFailurePendingForTest).await.unwrap(), "the callback consumed the one-shot failure");
            engine.actor_ping_for_test().await.unwrap();
            // A later synthetic descriptor refresh uses the same handler/model
            // pipeline without querying the actual desktop.
            let display = fixture_desc().display;
            engine.actor.actor().ask(messages::RefreshDisplayDescriptors { primary: display.clone(), displays: vec![display] }).await.unwrap();
            assert_eq!(engine.display_snapshot().len(), 1);
            assert_eq!(engine.actor_sequence_for_test(1).await.unwrap(), 1);
        });
    }

    #[test]
    fn scene_runtime_state_survives_snapshot_round_trip() {
        // CLEANROOM ET5
        run_async(async {
            use kameo::actor::Spawn;
            let desc = fixture_desc();
            let mut state = EngineState::with_display_model(DisplayStateModel { records: vec![fixture_record(Some(&desc), true)] });
            let handle = state.reserve_handle_for_key(DisplayKey::Primary);
            let mut carried = SceneRuntimeState::try_from(&desc).unwrap();
            carried.scaling_mode = ScalingMode::Stretch;
            carried.scaling_factor = 1.65;
            carried.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
            carried.render_resolution = Some((824, 472));
            carried.audio_response_enabled = true;
            carried.media_integration_enabled = true;
            carried.audio_volume = AudioVolume::try_from(0.43).unwrap();
            carried.audio_muted = true;
            carried.paused = true;
            carried.property_override_json = Some(flat_property_document(r#"{"lighting":{"gain":0.72},"caption":null}"#).unwrap());
            let prepared = EngineActor::prepare();
            state.display_records[0].handle = Some(handle);
            state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &carried, prepared.actor_ref().downgrade()).unwrap());
            state.close_all().unwrap();
            assert!(state.display_records[0].runtime.is_none());
            let restored = state.display_records[0].runtime_state_for_desc(&desc).unwrap();
            assert_eq!(restored.scaling_mode, carried.scaling_mode);
            assert_eq!(restored.scaling_factor, carried.scaling_factor);
            assert_eq!(restored.framing, carried.framing);
            assert_eq!(restored.render_resolution, carried.render_resolution);
            assert_eq!(restored.audio_response_enabled, carried.audio_response_enabled);
            assert_eq!(restored.media_integration_enabled, carried.media_integration_enabled);
            assert_eq!(restored.audio_volume, carried.audio_volume);
            assert_eq!(restored.audio_muted, carried.audio_muted);
            assert_eq!(restored.paused, carried.paused);
            assert_eq!(restored.property_override_json, carried.property_override_json);
        });
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_scaling() {
        // CLEANROOM ET6
        let mut desc = fixture_desc();
        desc.scaling_mode = ScalingMode::Stretch;
        desc.scaling_factor = 1.65;
        let state = SceneRuntimeState::try_from(&desc).unwrap();
        assert_eq!(state.scaling_mode, ScalingMode::Stretch);
        assert_eq!(state.scaling_factor, 1.65);
        desc.scaling_factor = 0.85;
        assert_eq!(SceneRuntimeState::try_from(&desc).unwrap().scaling_factor, 0.85);
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_framing() {
        // CLEANROOM ET7
        let mut desc = fixture_desc();
        for framing in [SceneFraming { pan_x: 0.37, pan_y: 0.64 }, SceneFraming { pan_x: 0.0, pan_y: 1.0 }, SceneFraming { pan_x: 1.0, pan_y: 0.0 }] {
            desc.framing = framing;
            assert_eq!(SceneRuntimeState::try_from(&desc).unwrap().framing, framing);
        }
    }

    #[test]
    fn runtime_refresh_required_only_when_descriptor_changes() {
        // CLEANROOM ET8
        let desc = fixture_desc();
        assert_eq!(RuntimeRefreshMode::from_transition(None, &desc), RuntimeRefreshMode::OpenRuntime);
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&desc), &desc), RuntimeRefreshMode::Unchanged);
        assert!(!RuntimeRefreshMode::Unchanged.is_required());
        for mode in [RuntimeRefreshMode::OpenRuntime, RuntimeRefreshMode::RebuildExistingRuntime, RuntimeRefreshMode::UpdateWindowOnly, RuntimeRefreshMode::ReopenRuntime] { assert!(mode.is_required()); }
        let mut next = desc.clone();
        next.fps = 47;
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&desc), &next), RuntimeRefreshMode::RebuildExistingRuntime);
    }

    #[test]
    fn runtime_refresh_mode_reopens_runtime_when_display_descriptor_changes() {
        // CLEANROOM ET9
        let desc = fixture_desc();
        for surface in [DisplayDesc::new(87, -613, 137, 2624, 1472, 2.0), DisplayDesc::new(87, -613, 137, 2496, 1408, 1.5)] {
            let mut next = desc.clone();
            next.display = surface;
            assert_eq!(RuntimeRefreshMode::from_transition(Some(&desc), &next), RuntimeRefreshMode::ReopenRuntime);
        }
    }

    #[test]
    fn runtime_refresh_mode_rebuilds_when_shader_refresh_is_forced() {
        // CLEANROOM ET10
        let current = fixture_desc();
        let mut desired = current.clone();
        desired.force_shader_refresh = true;
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&current), &desired), RuntimeRefreshMode::RebuildExistingRuntime);
    }

    #[test]
    fn runtime_refresh_mode_treats_completed_shader_refresh_as_unchanged() {
        // CLEANROOM ET11
        let desired = fixture_desc();
        let mut completed = desired.clone();
        completed.force_shader_refresh = true;
        completed.mark_shader_refresh_complete();
        assert!(!completed.force_shader_refresh);
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&completed), &desired), RuntimeRefreshMode::Unchanged);
    }

    #[test]
    fn runtime_refresh_mode_updates_window_only_when_origin_changes() {
        // CLEANROOM ET12: classification promises no renderer work.
        let current = fixture_desc();
        let mut desired = current.clone();
        desired.display.x = 101;
        desired.display.y = -209;
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&current), &desired), RuntimeRefreshMode::UpdateWindowOnly);
    }

    #[test]
    fn runtime_refresh_mode_reopens_display_change_after_runtime_pause() {
        // CLEANROOM ET13
        let mut current = fixture_desc();
        current.paused = true;
        let mut desired = current.clone();
        desired.display.scale_factor = 1.5;
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&current), &desired), RuntimeRefreshMode::ReopenRuntime);
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.inherit_descriptor_transition(&current, &desired).unwrap();
        assert!(state.paused);
    }

    #[test]
    fn runtime_refresh_mode_ignores_initial_pause_change_after_open() {
        // CLEANROOM ET14
        let current = fixture_desc();
        let mut desired = current.clone();
        desired.paused = !current.paused;
        assert_eq!(RuntimeRefreshMode::from_transition(Some(&current), &desired), RuntimeRefreshMode::Unchanged);
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.inherit_descriptor_transition(&current, &desired).unwrap();
        assert_eq!(state.paused, current.paused);
    }

    #[test]
    fn runtime_refresh_mode_treats_live_audio_response_change_as_unchanged_after_snapshot_sync() {
        // CLEANROOM ET15
        run_async(async {
            use kameo::actor::Spawn;
            let mut desc = fixture_desc();
            desc.audio_response_enabled = true;
            let prepared = EngineActor::prepare();
            let mut live = SceneRuntime::windowless_for_test(SceneHandle::new(9), &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap();
            live.set_audio_response_enabled(false).unwrap();
            let mut desired = desc;
            desired.audio_response_enabled = false;
            assert!(!live.desc.audio_response_enabled);
            assert_eq!(RuntimeRefreshMode::from_transition(Some(&live.desc), &desired), RuntimeRefreshMode::Unchanged);
        });
    }

    #[test]
    fn close_all_preserves_display_model_records() {
        // CLEANROOM ET16
        run_async(async {
            use kameo::actor::Spawn;
            let desc = fixture_desc();
            let mut blank = fixture_record(None, false);
            blank.key = DisplayKey::LiveDisplayId(126);
            blank.live_display = Some(DisplayDesc::new(126, 1800, -71, 1872, 1248, 2.0));
            let mut future = fixture_record(None, true);
            future.key = DisplayKey::Identity(DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() });
            future.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc)));
            let models = vec![fixture_record(Some(&desc), true), blank, future];
            let mut state = EngineState::with_display_model(DisplayStateModel { records: models.clone() });
            let prepared = EngineActor::prepare();
            let handle = state.reserve_handle_for_key(DisplayKey::Primary);
            state.display_records[0].handle = Some(handle);
            state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap());
            for id in 301..307 { state.reserve_handle_for_key(DisplayKey::LiveDisplayId(id)); }
            assert_eq!(state.next_handle, 8);
            state.close_all().unwrap();
            assert!(state.handles_by_display.is_empty());
            assert!(state.displays_by_handle.is_empty());
            assert_eq!(state.display_records.len(), 3);
            for (record, original) in state.display_records.iter().zip(models) {
                assert_eq!(record.model.key, original.key);
                assert_eq!(record.model.assignment, original.assignment);
                assert_eq!(record.model.window_active, original.window_active);
                assert!(record.runtime.is_none());
                assert!(record.handle.is_none());
                assert!(!record.model.runtime_open);
            }
            assert!(state.display_records[0].last_runtime_state.is_some());
            assert_eq!(state.reserve_handle_for_key(DisplayKey::Primary).raw(), 8);
        });
    }

    #[test]
    fn reconcile_scene_configs_make_inputs_active_direct_assignments() {
        // CLEANROOM ET17
        let first = fixture_desc();
        let mut second = first.clone();
        second.display.display_id = 126;
        let mut model = DisplayStateModel { records: vec![fixture_record(Some(&first), false)] };
        model.records[0].assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(126)));
        let mut other = fixture_record(Some(&second), false);
        other.key = DisplayKey::LiveDisplayId(126);
        model.records.push(other);
        let desired = [second.clone(), first.clone()];
        desired.as_slice().assert_unique().unwrap();
        model.apply_reconcile(&desired).unwrap();
        assert!(model.records.iter().all(|r| r.window_active && matches!(r.assignment, Some(WallpaperAssignment::Direct(_)))));
        assert_eq!(model.records[0].scene_desc().unwrap().unwrap(), first);
        let handles = std::collections::HashMap::from([(DisplayKey::Primary, SceneHandle::new(4)), (DisplayKey::LiveDisplayId(126), SceneHandle::new(7))]);
        let results = desired.as_slice().reconcile_results(&model, &handles).unwrap();
        assert_eq!(results.iter().map(|r| (r.display_id, r.handle.raw(), r.status)).collect::<Vec<_>>(), vec![(126, 7, 0), (87, 4, 0)]);
    }

    #[test]
    fn empty_reconcile_deactivates_active_connected_records() {
        // CLEANROOM ET18
        let desc = fixture_desc();
        let mut future = fixture_record(None, true);
        future.key = DisplayKey::Identity(DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() });
        future.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc)));
        let mut model = DisplayStateModel { records: vec![fixture_record(Some(&desc), true), future.clone()] };
        let assignment = model.records[0].assignment.clone();
        model.apply_reconcile(&[]).unwrap();
        assert!(!model.records[0].window_active);
        assert_eq!(model.records[0].assignment, assignment);
        assert!(model.records[1].window_active);
        assert_eq!(model.records[1].assignment, future.assignment);
        assert!(model.records[1].live_display.is_none());
    }

    #[test]
    fn reconcile_scene_deactivates_existing_connected_alias_records() {
        // CLEANROOM ET19
        let desc = fixture_desc();
        let mut alias = fixture_record(Some(&desc), true);
        alias.key = DisplayKey::LiveDisplayId(desc.display.display_id);
        let assignment = alias.assignment.clone();
        let mut model = DisplayStateModel { records: vec![fixture_record(Some(&desc), true), alias] };
        model.apply_reconcile(std::slice::from_ref(&desc)).unwrap();
        assert!(model.records[0].window_active);
        assert!(!model.records[1].window_active);
        assert_eq!(model.records[1].assignment, assignment);
        assert_eq!(model.records.iter().filter(|r| r.window_active).count(), 1);
    }

    #[test]
    fn reconcile_scene_for_current_primary_follows_primary_after_display_switch() {
        // CLEANROOM ET20: reservations migrate by physical display, not key.
        let mut a = fixture_desc();
        a.display.identity.uuid = Some("physical-orchid".into());
        let mut b = a.clone();
        b.display.display_id = 126;
        b.display.identity.uuid = Some("physical-cobalt".into());
        let mut other = fixture_record(Some(&b), true);
        other.key = DisplayKey::LiveDisplayId(126);
        let mut state = EngineState::with_display_model(DisplayStateModel { records: vec![fixture_record(Some(&a), true), other] });
        let ha = state.reserve_handle_for_key(DisplayKey::Primary);
        let hb = state.reserve_handle_for_key(DisplayKey::LiveDisplayId(126));
        state.display_records[0].handle = Some(ha);
        state.display_records[1].handle = Some(hb);
        let mut swapped = state.display_records[1].model.clone();
        swapped.key = DisplayKey::Primary;
        let mut old_primary = state.display_records[0].model.clone();
        old_primary.key = DisplayKey::LiveDisplayId(87);
        let mut model = DisplayStateModel { records: vec![swapped, old_primary] };
        // A display refresh migrates both live selections before a later
        // reconcile deactivates the now-unrequested secondary.
        state.apply_display_model(&model).unwrap();
        model.apply_reconcile(std::slice::from_ref(&b)).unwrap();
        state.apply_display_model(&model).unwrap();
        assert_eq!(state.display_records[0].handle, Some(hb));
        assert_eq!(state.display_records[0].model.live_display.as_ref().unwrap().display_id, 126);
        assert!(state.display_records[0].model.window_active);
        assert!(!state.display_records[1].model.window_active);
        assert_eq!(state.display_records[1].handle, Some(ha));
        assert_eq!(state.displays_by_handle.get(&hb), Some(&DisplayKey::Primary));
    }

    #[test]
    fn reconcile_keeps_disconnected_future_identity_records_untouched() {
        // CLEANROOM ET21
        let desc = fixture_desc();
        let future = DisplayRecord { key: DisplayKey::Identity(DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() }), live_display: None, assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc))), window_active: true, runtime_open: false, primary_inheritance_consumed: true, bound_to_display: false };
        let mut model = DisplayStateModel { records: vec![fixture_record(Some(&desc), true), future.clone()] };
        let mut next = desc;
        next.fps = 47;
        model.apply_reconcile(&[next]).unwrap();
        let after = &model.records[1];
        assert_eq!(after.key, future.key);
        assert_eq!(after.live_display, future.live_display);
        assert_eq!(after.assignment, future.assignment);
        assert_eq!(after.window_active, future.window_active);
        assert_eq!(after.runtime_open, future.runtime_open);
        assert_eq!(after.primary_inheritance_consumed, future.primary_inheritance_consumed);
    }

    #[test]
    fn reconcile_results_error_when_requested_handle_is_missing() {
        // CLEANROOM ET22
        let mut desc = fixture_desc();
        desc.display.display_id = 203;
        let model = DisplayStateModel { records: vec![fixture_record(Some(&desc), true)] };
        let error = [desc].as_slice().reconcile_results(&model, &std::collections::HashMap::new()).unwrap_err();
        assert!(matches!(error, EngineError::Platform(text) if text.contains("missing scene handle for requested display 203")));
    }

    #[test]
    fn reconcile_preserves_handle_reservation_when_runtime_no_longer_needed() {
        // CLEANROOM ET23
        run_async(async {
            use kameo::actor::Spawn;
            let desc = fixture_desc();
            let mut actor = make_actor(EngineState::with_display_model(DisplayStateModel { records: vec![fixture_record(Some(&desc), true)] }));
            let handle = actor.state.reserve_handle_for_key(DisplayKey::Primary);
            let prepared = EngineActor::prepare();
            actor.state.display_records[0].handle = Some(handle);
            actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap());
            actor.destroy_window_for(DisplaySelector::Primary).unwrap();
            let slot = &actor.state.display_records[0];
            assert!(slot.runtime.is_none());
            assert_eq!(slot.handle, Some(handle));
            assert!(slot.last_runtime_state.is_some());
            assert_eq!(actor.state.snapshot().displays[0].handle, None);
            assert_eq!(actor.state.reserve_handle_for_key(DisplayKey::Primary), handle);
        });
    }



    #[test]
    fn a_display_report_where_the_primary_has_no_pixels_leaves_a_running_scene_alone() {
        // CLEANROOM ET24
        run_async(async {
            use kameo::actor::Spawn;
            let desc = fixture_desc();
            let mut actor = make_actor(EngineState::with_display_model(DisplayStateModel { records: vec![fixture_record(Some(&desc), true)] }));
            let prepared = EngineActor::prepare();
            let handle = actor.state.reserve_handle_for_key(DisplayKey::Primary);
            actor.state.display_records[0].handle = Some(handle);
            actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap());
            actor.state.record_runtime_state(handle).unwrap();
            let token = actor.state.display_records[0].runtime.as_ref().unwrap().renderer_instance();
            let mut unusable = desc.display.clone();
            unusable.width = 0;
            actor.apply_display_report(unusable.clone(), vec![unusable]).unwrap();
            assert_eq!(actor.state.display_records[0].model.live_display.as_ref(), Some(&desc.display));
            assert!(Arc::ptr_eq(&token, &actor.state.display_records[0].runtime.as_ref().unwrap().renderer_instance()));
            actor.apply_display_report(desc.display.clone(), vec![desc.display.clone()]).unwrap();
            assert_eq!(actor.state.display_records[0].handle, Some(handle));
            assert!(Arc::ptr_eq(&token, &actor.state.display_records[0].runtime.as_ref().unwrap().renderer_instance()));
        });
    }

    #[test]
    fn a_secondary_display_without_pixels_is_left_out_until_it_reports_a_size() {
        // CLEANROOM ET25
        let primary = fixture_desc().display;
        let mut secondary = DisplayDesc::new(203, 1800, -71, 2192, 0, 2.0);
        secondary.identity.uuid = Some("physical-secondary".into());
        let mut actor = make_actor(EngineState::default());
        actor.apply_display_report(primary.clone(), vec![primary.clone(), secondary.clone()]).unwrap();
        assert_eq!(actor.state.snapshot().displays.iter().map(|e| e.desc.display_id).collect::<Vec<_>>(), vec![87]);
        secondary.height = 1232;
        actor.apply_display_report(primary.clone(), vec![primary, secondary.clone()]).unwrap();
        let entries = actor.state.snapshot().displays;
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].desc, secondary);
        assert!(entries.iter().all(|e| e.handle.is_none()));
    }

    #[test]
    fn display_record_blank_when_active_without_assignment() {
        // CLEANROOM ET26
        let mut record = fixture_record(Some(&fixture_desc()), true);
        record.assignment = None;
        assert!(!record.should_have_runtime());
        assert!(record.scene_desc().unwrap().is_none());
        let state = EngineState::with_display_model(DisplayStateModel { records: vec![record] });
        assert_eq!(state.snapshot().displays.len(), 1);
        assert!(state.snapshot().displays[0].window_active);
        assert!(state.snapshot().displays[0].handle.is_none());
    }

    #[test]
    fn display_record_needs_runtime_when_active_connected_and_assigned() {
        // CLEANROOM ET27
        let record = fixture_record(Some(&fixture_desc()), true);
        assert!(record.should_have_runtime());
        for gate in 0..3 {
            let mut missing = record.clone();
            match gate { 0 => missing.assignment = None, 1 => missing.window_active = false, _ => missing.live_display = None }
            assert!(!missing.should_have_runtime(), "gate {gate}");
        }
        let mut already_open = record;
        already_open.window_active = false;
        already_open.runtime_open = true;
        assert!(already_open.should_have_runtime());
    }

    #[test]
    fn display_record_needs_runtime_for_connected_mirror_assignment() {
        // CLEANROOM ET28
        let source = fixture_record(Some(&fixture_desc()), true);
        let mut mirror = source.clone();
        mirror.key = DisplayKey::LiveDisplayId(126);
        mirror.live_display.as_mut().unwrap().display_id = 126;
        mirror.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Primary));
        assert!(mirror.should_have_runtime());
        let model = DisplayStateModel { records: vec![source, mirror.clone()] };
        let resolved = model.resolved_assignment(&mirror.key).unwrap();
        let Some(WallpaperAssignment::Direct(template)) = resolved else { panic!("resolvable mirror") };
        assert_eq!(template.for_display(mirror.live_display.unwrap()).display.display_id, 126);
    }

    #[test]
    fn mirror_mouse_update_uses_source_display_geometry() {
        // CLEANROOM ET29
        let source = snapshot_entry(fixture_desc().display, None);
        let mirror = snapshot_entry(DisplayDesc::new(126, 1800, -71, 1872, 1248, 2.0), Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)));
        let entries = [source, mirror];
        let result = DisplaySnapshot { entries: &entries }.mouse_update_for_entry(pointer_sample(-145.0, 577.0, 1 << 5, 1 << 5, 0), &entries[1]);
        assert!(result.entered);
        assert_eq!(result.position, Some(NormalizedMousePosition { x: 0.375, y: 0.375 }));
        assert_eq!(result.buttons.transitions().map(|b| (b.button, b.pressed)).collect::<Vec<_>>(), vec![(5, true)]);
    }

    #[test]
    fn mirror_mouse_update_uses_mirror_display_geometry_for_local_cursor() {
        // CLEANROOM ET30
        let entries = [snapshot_entry(fixture_desc().display, None), snapshot_entry(DisplayDesc::new(126, 1800, -71, 1872, 1248, 2.0), Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)))];
        let result = DisplaySnapshot { entries: &entries }.mouse_update_for_entry(pointer_sample(2034.0, 397.0, 0, 0, 0), &entries[1]);
        assert!(result.entered);
        assert_eq!(result.position, Some(NormalizedMousePosition { x: 0.25, y: 0.25 }));
    }

    #[test]
    fn mirror_mouse_update_resolves_source_display_through_mirror_chain() {
        // CLEANROOM ET31
        let mut source = fixture_desc().display;
        source.identity.uuid = Some("source-orchid".into());
        for selector in [DisplaySelector::Primary, DisplaySelector::LiveDisplayId(87), DisplaySelector::Identity(source.identity.clone())] {
            let mut entries = vec![snapshot_entry(source.clone(), None), snapshot_entry(DisplayDesc::new(126, 1800, 0, 1872, 1248, 2.0), Some(WallpaperAssignment::Mirror(selector))), snapshot_entry(DisplayDesc::new(203, 3000, 0, 1600, 900, 1.0), Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(126))))];
            let sample = pointer_sample(-145.0, 577.0, 0, 0, 0);
            let result = DisplaySnapshot { entries: &entries }.mouse_update_for_entry(sample, &entries[2]);
            assert_eq!(result.position, Some(NormalizedMousePosition { x: 0.375, y: 0.375 }));
            for bad in [DisplaySelector::LiveDisplayId(203), DisplaySelector::LiveDisplayId(900)] {
                entries[1].assignment = Some(WallpaperAssignment::Mirror(bad));
                let result = DisplaySnapshot { entries: &entries }.mouse_update_for_entry(sample, &entries[2]);
                assert!(!result.entered);
                assert!(result.position.is_none());
            }
        }
    }

    #[test]
    fn display_record_scene_desc_converts_direct_assignment() {
        // CLEANROOM ET32
        let mut desc = fixture_desc();
        desc.display.display_id = 126;
        desc.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
        desc.scaling_mode = ScalingMode::Stretch;
        desc.scaling_factor = 1.65;
        let record = fixture_record(Some(&desc), true);
        assert_eq!(record.scene_desc().unwrap(), Some(desc));
    }

    #[test]
    fn display_record_scene_desc_returns_none_when_disconnected() {
        // CLEANROOM ET33
        let mut record = fixture_record(Some(&fixture_desc()), true);
        record.live_display = None;
        record.key = DisplayKey::Identity(DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() });
        assert!(record.assignment.is_some());
        assert!(record.scene_desc().unwrap().is_none());
    }

    #[test]
    fn display_record_scene_desc_errors_for_unresolved_mirror() {
        // CLEANROOM ET34
        let mut record = fixture_record(Some(&fixture_desc()), true);
        record.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Identity(DisplayIdentity { uuid: Some("absent-orchid".into()), ..Default::default() })));
        assert!(matches!(record.scene_desc(), Err(EngineError::Platform(_))));
        record.live_display = None;
        assert!(record.scene_desc().unwrap().is_none());
    }

    #[test]
    fn display_snapshot_returns_entries_for_configured_displays() {
        // CLEANROOM ET35
        let desc = fixture_desc();
        let mut other = fixture_record(Some(&desc), false);
        other.key = DisplayKey::LiveDisplayId(126);
        other.live_display.as_mut().unwrap().display_id = 126;
        other.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Primary));
        let mut third = fixture_record(Some(&desc), true);
        third.key = DisplayKey::LiveDisplayId(203);
        third.live_display.as_mut().unwrap().display_id = 203;
        third.assignment = None;
        let mut future = fixture_record(None, true);
        future.key = DisplayKey::Identity(DisplayIdentity { uuid: Some("future-amber-57".into()), ..Default::default() });
        let records = vec![fixture_record(Some(&desc), true), other, third, future];
        let state = EngineState::with_display_model(DisplayStateModel { records: records.clone() });
        let entries = state.snapshot().displays;
        assert_eq!(entries.len(), 3);
        for (entry, record) in entries.iter().zip(&records) {
            assert_eq!(Some(&entry.desc), record.live_display.as_ref());
            assert_eq!(entry.identity, entry.desc.identity);
            assert_eq!(entry.window_active, record.window_active);
            assert_eq!(entry.assignment, record.assignment);
            assert!(entry.handle.is_none());
            assert!(!entry.paused && !entry.accepts_pointer_input);
        }
    }

    #[test]
    fn display_plane_maps_appkit_global_point_to_owe_coordinates() {
        // CLEANROOM ET36
        let plane = DisplayPlane::of(&fixture_desc().display);
        for (x, y, expected) in [(-145.0, 577.0, (0.375, 0.375)), (-613.0, 137.0, (0.0, 1.0)), (11.0, 489.0, (0.5, 0.5))] {
            assert_eq!(plane.scene_position(NSPoint::new(x, y)), Some(NormalizedMousePosition { x: expected.0, y: expected.1 }));
        }
    }

    #[test]
    fn display_plane_rejects_points_outside_display() {
        // CLEANROOM ET37
        let desc = fixture_desc().display;
        let plane = DisplayPlane::of(&desc);
        assert!(plane.contains(NSPoint::new(-613.0, 137.0)));
        for (x, y) in [(635.0, 577.0), (-145.0, 841.0), (-614.0, 577.0), (-145.0, 136.0), (f64::NAN, 577.0), (-145.0, f64::INFINITY)] {
            assert!(!plane.contains(NSPoint::new(x, y)));
            assert!(plane.scene_position(NSPoint::new(x, y)).is_none());
        }
        for (width, height, scale) in [(0, 1408, 2.0), (2496, 0, 2.0), (2496, 1408, f64::INFINITY)] {
            let mut invalid = desc.clone();
            invalid.width = width;
            invalid.height = height;
            invalid.scale_factor = scale;
            assert!(DisplayPlane::of(&invalid).scene_position(NSPoint::new(-145.0, 577.0)).is_none());
        }
    }

    #[test]
    fn display_plane_read_releases_buttons_after_cursor_leaves_display() {
        // CLEANROOM ET38
        let plane = DisplayPlane::of(&fixture_desc().display);
        assert_eq!(plane.read(pointer_sample(-145.0, 577.0, 1 << 5, 0, 0)).buttons.down().mask(), 1 << 5);
        for (down, pressed, released) in [(1 << 5, 0, 0), (1 << 5, 1 << 5, 0), (0, 1 << 5, 1 << 5)] {
            let outside = plane.read(pointer_sample(636.0, 577.0, down, pressed, released));
            assert!(!outside.entered);
            assert!(outside.position.is_none());
            assert_eq!(outside.buttons.down().mask(), 0);
            assert_eq!(outside.buttons.transitions().count(), 0);
        }
    }

    #[test]
    fn display_plane_read_preserves_tap_transitions_inside_display() {
        // CLEANROOM ET39
        let plane = DisplayPlane::of(&fixture_desc().display);
        let result = plane.read(pointer_sample(-145.0, 577.0, 0, (1 << 5) | (1 << 11), (1 << 5) | (1 << 11)));
        assert!(result.entered);
        assert_eq!(result.buttons.down().mask(), 0);
        assert_eq!(result.buttons.transitions().map(|b| (b.button, b.pressed)).collect::<Vec<_>>(), vec![(5, true), (5, false), (11, true), (11, false)]);
    }

    #[test]
    fn display_plane_read_does_not_forward_held_level_state_as_press() {
        // CLEANROOM ET40
        let plane = DisplayPlane::of(&fixture_desc().display);
        let held = plane.read(pointer_sample(-145.0, 577.0, 1 << 9, 0, 0));
        assert_eq!(held.buttons.pre_transition_down_mask(), 1 << 9);
        assert_eq!(held.buttons.transitions().count(), 0);
        let released = plane.read(pointer_sample(-145.0, 577.0, 0, 0, 1 << 9));
        assert_eq!(released.buttons.transitions().map(|b| (b.button, b.pressed)).collect::<Vec<_>>(), vec![(9, false)]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_fps_returns_err_for_unknown_handle() {
        // CLEANROOM ET41
        let engine = cleanroom_et1(Vec::new());
        let error = engine.set_fps(SceneHandle::new(7401), 53).await.unwrap_err();
        assert!(matches!(error, EngineError::InvalidInput(text) if text.contains("unknown scene handle") && text.contains("7401")));
        let error = engine.set_fps(SceneHandle::new(7401), 0).await.unwrap_err();
        assert!(matches!(error, EngineError::InvalidInput(text) if text == "fps must be greater than zero"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_framing_refuses_a_position_off_the_display_before_asking_the_actor() {
        let engine = cleanroom_et1(Vec::new());
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
        let engine = cleanroom_et1(Vec::new());

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
        let engine = cleanroom_et1(Vec::new());
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
        let engine = cleanroom_et1(Vec::new());

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
        let engine = cleanroom_et1(Vec::new());
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
        let engine = cleanroom_et1(Vec::new());

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
        // CLEANROOM ET42
        let engine = cleanroom_et1(Vec::new());
        let error = engine.set_paused(SceneHandle::new(7403), true).await.unwrap_err();
        assert!(matches!(error, EngineError::InvalidInput(text) if text.contains("unknown scene handle") && text.contains("7403")));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_all_paused_allows_empty_runtime_set() {
        // CLEANROOM ET43
        let mut actor = make_actor(EngineState::default());
        actor.set_all_paused(true, &[]).unwrap();
        use kameo::actor::Spawn;
        let desc = fixture_desc();
        actor.state.display_records[0].model = fixture_record(Some(&desc), true);
        let handle = actor.state.reserve_handle_for_key(DisplayKey::Primary);
        let prepared = EngineActor::prepare();
        actor.state.display_records[0].handle = Some(handle);
        actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap());
        actor.close_all_scenes().unwrap();
        actor.set_all_paused(false, &[]).unwrap();
        assert!(actor.state.handles_by_display.is_empty());
        assert!(actor.state.display_records.iter().all(|r| r.runtime.is_none() && r.handle.is_none()));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_all_paused_skips_preserved_handles_without_runtime() {
        // CLEANROOM ET44
        use kameo::actor::Spawn;
        let desc = fixture_desc();
        let mut actor = make_actor(EngineState::with_display_model(DisplayStateModel { records: vec![fixture_record(Some(&desc), true)] }));
        let handle = actor.state.reserve_handle_for_key(DisplayKey::Primary);
        let prepared = EngineActor::prepare();
        actor.state.display_records[0].handle = Some(handle);
        actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap());
        actor.destroy_window_for(DisplaySelector::Primary).unwrap();
        assert!(actor.state.display_records[0].last_runtime_state.is_some());
        actor.set_all_paused(true, &[]).unwrap();
        actor.set_all_paused(false, &[87]).unwrap();
        assert_eq!(actor.state.display_records[0].handle, Some(handle));
        let entry = &actor.state.snapshot().displays[0];
        assert!(entry.handle.is_none());
        assert!(!entry.paused && !entry.accepts_pointer_input);
        assert!(matches!(actor.state.scene_mut(handle), Err(EngineError::InvalidInput(text)) if text.contains("is not active")));
    }

    #[test]
    fn a_first_frame_callback_installed_later_reaches_the_closure_a_renderer_holds() {
        let cell = FirstFrameCallbackCell::default();
        let held = cell.callback();
        held(SceneHandle::new(1));

        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        cell.set(Arc::new(move |handle| sink.lock().unwrap().push(handle.raw())));
        held(SceneHandle::new(7));
        let sink = Arc::clone(&seen);
        cell.set(Arc::new(move |handle| sink.lock().unwrap().push(handle.raw() + 100)));
        held(SceneHandle::new(8));

        assert_eq!(*seen.lock().unwrap(), vec![7, 108]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_bad_argument_is_refused_before_the_engine_thread_is_reached() {
        let engine = cleanroom_et1(Vec::new());
        engine.actor.actor().stop_gracefully().await.unwrap();
        engine.actor.actor().wait_for_shutdown().await;
        let handle = SceneHandle::new(1);

        let refusals = [
            engine.set_scaling_factor(handle, 0.0).await,
            engine.set_scaling_factor(handle, f64::NAN).await,
            engine.set_scaling_factor(handle, f64::INFINITY).await,
            engine.set_fps(handle, 0).await,
            engine.set_render_scale(handle, 0.0).await,
            engine.set_render_scale(handle, f32::NAN).await,
            engine.set_render_resolution(handle, 0, 1080).await,
            engine.set_render_resolution(handle, 1920, 0).await,
            engine.set_mouse_position(handle, f64::NAN, 0.5).await,
            engine.set_mouse_position(handle, 0.5, f64::INFINITY).await,
            engine.set_mouse_button(handle, 32, true).await,
        ];
        for refusal in refusals {
            let error = refusal.expect_err("a bad argument must be refused");
            assert!(
                matches!(&error, EngineError::InvalidInput(text) if !text.contains("engine actor")),
                "{error:?}"
            );
        }

        let valid = engine.set_fps(handle, 30).await.expect_err("the engine is stopped");
        assert!(matches!(&valid, EngineError::Platform(text) if text.contains("engine actor")));
    }
}
