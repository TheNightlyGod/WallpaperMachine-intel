use std::sync::Arc;
use kameo::actor::WeakActorRef;

use serde_json::Value;

use crate::{
    DisplayDesc, EngineError, WallpaperWindow,
    display::state::DisplayKey,
    engine::{
        FirstFrameCallback, PropertyPreview, actor::EngineActor,
        messages::{
            NativeAudioRequirementChanged, NativePointerInputChanged, NativeRenderFailed,
            NativeUserShortcutRequested,
        },
        surface_recovery::{RecoveryStep, SurfaceRecovery},
    },
    media::audio::AudioVolume,
    owe::{
        backend::{
            AudioRequirementCallback, OweBackend, OweScene, PointerInputCallback,
            RenderFailureCallback, UserShortcutCallback,
        },
        scene_demand::SurfaceHealth,
    },
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SerdeValudeExt},
    render::RendererSurfaceCounters,
    window::{LayerInstall, LayerSwap, MouseButtonEdges, NormalizedMousePosition},
};

/// The native looper only writes watch state; this task owns bounded delivery.
struct PointerInputRelay {
    renderer_instance: Arc<()>,
    task: tokio::task::JoinHandle<()>,
}

impl PointerInputRelay {
    fn new(actor: WeakActorRef<EngineActor>, handle: SceneHandle) -> Result<(Self, PointerInputCallback), EngineError> {
        let runtime = tokio::runtime::Handle::try_current().map_err(|error| {
            EngineError::Platform(format!("pointer input relay requires actor runtime: {error}"))
        })?;
        let renderer_instance = Arc::new(());
        let instance = renderer_instance.clone();
        let (sender, mut receiver) = tokio::sync::watch::channel(None);
        let callback: PointerInputCallback = Arc::new(move |value| { sender.send_replace(Some(value)); });
        let task = runtime.spawn(async move {
            while receiver.changed().await.is_ok() {
                let value = *receiver.borrow_and_update();
                let Some(accepts_pointer_input) = value else { continue; };
                let Some(actor) = actor.upgrade() else { break; };
                let result = actor.tell(NativePointerInputChanged {
                    handle,
                    renderer_instance: instance.clone(),
                    accepts_pointer_input,
                }).send().await;
                drop(actor);
                if result.is_err() { break; }
            }
        });
        Ok((Self { renderer_instance, task }, callback))
    }

    fn stop(&self) { self.task.abort(); }
}

impl Drop for PointerInputRelay {
    fn drop(&mut self) { self.stop(); }
}

/// Carries the renderer's "this scene reads system audio" report off the
/// native main looper, the same way as pointer capability: the looper only
/// writes the latest value, and this task delivers it to the engine actor.
/// The instance token ties a report to the renderer object that made it, so a
/// late report from a renderer that was since rebuilt is ignored.
struct AudioRequirementRelay {
    renderer_instance: Arc<()>,
    task: tokio::task::JoinHandle<()>,
}

impl AudioRequirementRelay {
    fn new(
        actor: WeakActorRef<EngineActor>,
        handle: SceneHandle,
    ) -> Result<(Self, AudioRequirementCallback), EngineError> {
        let runtime = tokio::runtime::Handle::try_current().map_err(|error| {
            EngineError::Platform(format!("audio requirement relay requires actor runtime: {error}"))
        })?;
        let renderer_instance = Arc::new(());
        let instance = renderer_instance.clone();
        let (sender, mut receiver) = tokio::sync::watch::channel(None);
        let callback: AudioRequirementCallback =
            Arc::new(move |value| { sender.send_replace(Some(value)); });
        let task = runtime.spawn(async move {
            while receiver.changed().await.is_ok() {
                let value = *receiver.borrow_and_update();
                let Some(requires_audio) = value else { continue };
                let Some(actor) = actor.upgrade() else { break };
                let result = actor
                    .tell(NativeAudioRequirementChanged {
                        handle,
                        renderer_instance: instance.clone(),
                        requires_audio,
                    })
                    .send()
                    .await;
                drop(actor);
                if result.is_err() {
                    break;
                }
            }
        });
        Ok((Self { renderer_instance, task }, callback))
    }

    fn stop(&self) { self.task.abort(); }
}

impl Drop for AudioRequirementRelay {
    fn drop(&mut self) { self.stop(); }
}

/// Carries the renderer's "this scene had drawn and has now stopped after a
/// failed frame" report off the native main looper, the same way as the audio
/// requirement: the looper only signals, and this task delivers to the engine
/// actor. A burst coalesces into one delivery, which is right: the renderer
/// stays stopped until it is rebuilt, so one report says everything a second
/// would. The instance token ties a report to the renderer object that made
/// it, so a late report from a renderer that was since rebuilt is ignored.
struct RenderFailureRelay {
    renderer_instance: Arc<()>,
    task: tokio::task::JoinHandle<()>,
}

impl RenderFailureRelay {
    fn new(
        actor: WeakActorRef<EngineActor>,
        handle: SceneHandle,
    ) -> Result<(Self, RenderFailureCallback), EngineError> {
        let runtime = tokio::runtime::Handle::try_current().map_err(|error| {
            EngineError::Platform(format!("render failure relay requires actor runtime: {error}"))
        })?;
        let renderer_instance = Arc::new(());
        let instance = renderer_instance.clone();
        let (sender, mut receiver) = tokio::sync::watch::channel(());
        let callback: RenderFailureCallback = Arc::new(move || { sender.send_replace(()); });
        let task = runtime.spawn(async move {
            while receiver.changed().await.is_ok() {
                receiver.borrow_and_update();
                let Some(actor) = actor.upgrade() else { break };
                let result = actor
                    .tell(NativeRenderFailed { handle, renderer_instance: instance.clone() })
                    .send()
                    .await;
                drop(actor);
                if result.is_err() {
                    break;
                }
            }
        });
        Ok((Self { renderer_instance, task }, callback))
    }

    fn stop(&self) { self.task.abort(); }
}

impl Drop for RenderFailureRelay {
    fn drop(&mut self) { self.stop(); }
}

/// Carries `engine.openUserShortcut` requests off the native main looper.
///
/// Bounded rather than latest-value: these are presses, and a play/pause
/// followed quickly by a next must deliver both. A full queue drops the new
/// request with a log instead of blocking the looper that reported it, because
/// a press nobody can take is not worth stalling a frame for.
struct UserShortcutRelay {
    task: tokio::task::JoinHandle<()>,
}

impl UserShortcutRelay {
    fn new(
        actor: WeakActorRef<EngineActor>,
        handle: SceneHandle,
    ) -> Result<(Self, UserShortcutCallback), EngineError> {
        let runtime = tokio::runtime::Handle::try_current().map_err(|error| {
            EngineError::Platform(format!("user shortcut relay requires actor runtime: {error}"))
        })?;
        let (sender, mut receiver) = tokio::sync::mpsc::channel::<(String, String)>(16);
        let callback: UserShortcutCallback = Arc::new(move |name, value| {
            if let Err(error) = sender.try_send((name, value)) {
                log::warn!("dropped a user shortcut request nobody could take: {error}");
            }
        });
        let task = runtime.spawn(async move {
            while let Some((property_name, property_value)) = receiver.recv().await {
                let Some(actor) = actor.upgrade() else { break };
                let result = actor
                    .tell(NativeUserShortcutRequested { handle, property_name, property_value })
                    .send()
                    .await;
                drop(actor);
                if result.is_err() {
                    break;
                }
            }
        });
        Ok((Self { task }, callback))
    }

    fn stop(&self) {
        self.task.abort();
    }
}

impl Drop for UserShortcutRelay {
    fn drop(&mut self) {
        self.stop();
    }
}

#[derive(Default)]
struct MouseDeliveryState {
    position: Option<NormalizedMousePosition>,
    entered: Option<bool>,
}

impl MouseDeliveryState {
    fn set_position(&mut self, x: f64, y: f64, send: impl FnOnce(f64, f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        let next = NormalizedMousePosition { x, y };
        if self.position == Some(next) { return Ok(()); }
        self.position = None;
        send(x, y)?;
        self.position = Some(next);
        Ok(())
    }

    fn set_entered(&mut self, entered: bool, send: impl FnOnce(bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !entered { self.position = None; }
        if self.entered == Some(entered) { return Ok(()); }
        self.entered = None;
        send(entered)?;
        self.entered = Some(entered);
        Ok(())
    }

    fn invalidate(&mut self) { self.position = None; self.entered = None; }
}

struct NativePointerInputState {
    renderer_instance: Arc<()>,
    accepts_pointer_input: bool,
    button_baseline_pending: bool,
    delivery: MouseDeliveryState,
}

impl NativePointerInputState {
    fn new(renderer_instance: Arc<()>) -> Self {
        Self {
            renderer_instance,
            accepts_pointer_input: true,
            button_baseline_pending: true,
            delivery: MouseDeliveryState::default(),
        }
    }

    fn apply(&mut self, instance: &Arc<()>, accepts: bool) -> bool {
        if !Arc::ptr_eq(&self.renderer_instance, instance) { return false; }
        self.delivery.invalidate();
        self.button_baseline_pending = true;
        let changed = self.accepts_pointer_input != accepts;
        self.accepts_pointer_input = accepts;
        changed
    }

    fn sample_pending(&self) -> bool {
        self.accepts_pointer_input && (self.delivery.entered.is_none() || self.button_baseline_pending)
    }

    fn set_position(&mut self, x: f64, y: f64, send: impl FnOnce(f64, f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        if !self.accepts_pointer_input { return Ok(()); }
        self.delivery.set_position(x, y, send)
    }

    fn set_button(&mut self, button: u32, pressed: bool, send: impl FnOnce(u32, bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if button > 31 {
            return Err(EngineError::InvalidInput("mouse button must be in range 0..31".to_string()));
        }
        if !self.accepts_pointer_input { return Ok(()); }
        send(button, pressed)
    }

    fn reconcile_button_baseline(&mut self, buttons: MouseButtonEdges, send: impl FnOnce(u32) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !self.accepts_pointer_input || !self.button_baseline_pending { return Ok(()); }
        send(buttons.pre_transition_down_mask())?;
        self.button_baseline_pending = false;
        Ok(())
    }

    fn set_entered(&mut self, entered: bool, send: impl FnOnce(bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !self.accepts_pointer_input { return Ok(()); }
        self.delivery.set_entered(entered, send)
    }
}

/// The internal rasterization scale a runtime last set on its renderer.
///
/// A live renderer property that nothing else stores: not the descriptor, not
/// [`SceneRuntimeState`]. A renderer object the engine opens by itself (a
/// recovery rebuild, a wallpaper switch, a resolution change) therefore starts
/// at native size, and unless it is told the scale again the wallpaper comes
/// back drawing at full resolution while the panel still reports the reduced
/// one. Kept apart from [`SceneRuntimeState`] on purpose: that state outlives
/// the runtime and seeds the next one, so a scale remembered across a close
/// would override whatever the bridge holds by then.
#[derive(Clone, Copy, Debug)]
struct RenderScale(f64);

impl RenderScale {
    /// What a renderer rasterizes at before anyone sets a scale.
    const NATIVE: f64 = 1.0;

    /// Sends `scale` and, once the renderer took it, remembers it. A refused
    /// scale leaves the one in force untouched.
    fn set(&mut self, scale: f64, send: impl FnOnce(f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        send(scale)?;
        self.0 = scale;
        Ok(())
    }

    /// Hands the scale in force to a renderer that was just opened. A scale at
    /// native size is what a new renderer already has, so nothing is sent.
    fn restore(self, send: impl FnOnce(f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if (self.0 - Self::NATIVE).abs() <= f64::EPSILON { return Ok(()); }
        send(self.0)
    }
}

pub struct SceneRuntime {
    last_media: Option<crate::media::MediaPollResult>,
    /// Last descriptor used to configure the renderer scene.
    pub desc: SceneDesc,
    /// Stable handle used when reporting renderer lifecycle events.
    handle: SceneHandle,
    /// Engine-level callback invoked after OWE renders the first frame.
    first_frame_callback: FirstFrameCallback,
    /// Opaque Open Wallpaper Engine renderer object.
    renderer: OweScene,
    actor: WeakActorRef<EngineActor>,
    pointer_relay: PointerInputRelay,
    shortcut_relay: UserShortcutRelay,
    audio_relay: AudioRequirementRelay,
    failure_relay: RenderFailureRelay,
    /// What has been tried to bring this renderer's surface back, and what is
    /// left of the budget. Belongs to the renderer's wallpaper: a different
    /// wallpaper starts with a fresh one, a rebuild done by recovery itself
    /// keeps it.
    surface_recovery: SurfaceRecovery,
    /// Whether the renderer's committed scene reads system audio, as it last
    /// reported. Starts `false` for every renderer object: a rebuilt renderer
    /// has a new scene that has not said anything yet.
    requires_audio: bool,
    pointer_input: NativePointerInputState,
    /// Runtime override applied after descriptor defaults.
    scaling_mode: ScalingMode,
    /// Runtime override applied after descriptor defaults.
    scaling_factor: f64,
    /// Runtime override applied after descriptor defaults.
    framing: SceneFraming,
    /// Renderer-surface override. Changing this rebuilds the renderer object.
    render_resolution: Option<(u32, u32)>,
    /// Internal rasterization scale, handed again to every renderer this
    /// runtime opens, whoever asked for the rebuild.
    render_scale: RenderScale,
    /// Runtime audio-response state, preserved across scene reconciliation.
    audio_response_enabled: bool,
    /// Runtime media-integration state, preserved across scene reconciliation.
    media_integration_enabled: bool,
    /// Runtime playback state, preserved across scene reconciliation.
    paused: bool,
    /// Runtime scene-global audio volume, preserved across scene
    /// reconciliation.
    audio_volume: AudioVolume,
    /// Runtime scene-global audio mute state, preserved across scene
    /// reconciliation.
    audio_muted: bool,
    /// Flattened runtime property override, preserved across reconciliation.
    property_override_json: Option<String>,
    /// `AppKit` window that owns the `CAMetalLayer` passed to OWE.
    window: Option<WallpaperWindow>,
    /// Increments every time the renderer object is rebuilt. The renderer's
    /// counters live and die with that object, so two wallpapers that reused
    /// one display and one handle must not have their counts merged.
    generation: u64,
}

#[derive(Clone)]
pub struct SceneRuntimeState {
    /// Mutable state that should survive replacing the scene descriptor.
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
    pub framing: SceneFraming,
    pub render_resolution: Option<(u32, u32)>,
    pub audio_response_enabled: bool,
    pub media_integration_enabled: bool,
    pub paused: bool,
    pub audio_volume: AudioVolume,
    pub audio_muted: bool,
    pub property_override_json: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DescriptorInheritance {
    PreserveRuntimeOverrides,
    UseDescriptorDefaults,
}

#[derive(Debug, PartialEq, Eq)]
enum PropertyOverrideUpdate<'a> {
    Unchanged,
    Apply(&'a str),
    Reset,
}

pub struct RuntimeRefreshJob {
    pub key: DisplayKey,
    pub handle: SceneHandle,
    pub desc: SceneDesc,
    pub runtime_state: SceneRuntimeState,
    pub existing_runtime: Option<SceneRuntime>,
    pub first_frame_callback: FirstFrameCallback,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeRefreshMode {
    Unchanged,
    OpenRuntime,
    UpdateWindowOnly,
    RebuildExistingRuntime,
    ReopenRuntime,
}

impl RuntimeRefreshMode {
    /// Classifies the transition between two scene descriptors.
    pub fn from_transition(current: Option<&SceneDesc>, desired: &SceneDesc) -> Self {
        let Some(current) = current else {
            return RuntimeRefreshMode::OpenRuntime;
        };
        if current.same_wallpaper(desired) && current.display == desired.display {
            return RuntimeRefreshMode::Unchanged;
        }
        if current.same_wallpaper(desired) {
            if current.display.has_same_render_surface(&desired.display) {
                return RuntimeRefreshMode::UpdateWindowOnly;
            }
            return RuntimeRefreshMode::ReopenRuntime;
        }
        RuntimeRefreshMode::RebuildExistingRuntime
    }

    /// Returns true if the transition requires a runtime refresh.
    pub fn is_required(self) -> bool {
        self != RuntimeRefreshMode::Unchanged
    }
}

/// Undoes the layer swap of a scene replacement that failed, so the renderer
/// still running keeps its picture instead of the empty layer meant for the
/// replacement.
fn restore_previous_layer(window: &mut WallpaperWindow, swap: LayerSwap, cause: &EngineError) {
    match window.revert_layer_swap(swap) {
        Ok(()) => log::warn!(
            "[wallpaper-core engine] scene replacement failed, previous layer restored: {cause}"
        ),
        Err(error) => log::warn!(
            "[wallpaper-core engine] scene replacement failed and the previous layer could not \
             be restored ({error}): {cause}"
        ),
    }
}

impl SceneRuntime {
    pub fn open(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: SceneRuntimeState,
        actor: WeakActorRef<EngineActor>,
    ) -> Result<Self, EngineError> {
        let mut stored_desc = desc.clone();
        stored_desc.mark_shader_refresh_complete();
        let window = WallpaperWindow::builder(desc.display.clone()).open()?;
        let (pointer_relay, pointer_callback) = PointerInputRelay::new(actor.clone(), handle)?;
        let (shortcut_relay, shortcut_callback) = UserShortcutRelay::new(actor.clone(), handle)?;
        let (audio_relay, audio_callback) = AudioRequirementRelay::new(actor.clone(), handle)?;
        let (failure_relay, failure_callback) = RenderFailureRelay::new(actor.clone(), handle)?;
        let renderer = backend.open_scene(
            desc,
            window.metal_layer_ptr(),
            state.scaling_mode,
            state.scaling_factor,
            state.framing,
            state.render_resolution,
            Some(Arc::new({
                let callback = first_frame_callback.clone();
                move || callback(handle)
            })),
            Some(pointer_callback),
            Some(shortcut_callback),
            Some(audio_callback),
            Some(failure_callback),
        )?;
        let descriptor_state = SceneRuntimeState::try_from(desc)?;
        let mut runtime = Self {
            last_media: None,
            desc: desc.clone(),
            handle,
            first_frame_callback,
            renderer,
            pointer_input: NativePointerInputState::new(pointer_relay.renderer_instance.clone()),
            pointer_relay,
            shortcut_relay,
            audio_relay,
            failure_relay,
            surface_recovery: SurfaceRecovery::default(),
            requires_audio: false,
            actor,
            scaling_mode: state.scaling_mode,
            scaling_factor: state.scaling_factor,
            framing: state.framing,
            render_resolution: state.render_resolution,
            render_scale: RenderScale(RenderScale::NATIVE),
            audio_response_enabled: state.audio_response_enabled,
            media_integration_enabled: state.media_integration_enabled,
            paused: state.paused,
            audio_volume: state.audio_volume,
            audio_muted: state.audio_muted,
            property_override_json: state.property_override_json,
            window: Some(window),
            generation: 1,
        };
        runtime.desc = stored_desc;
        runtime.apply_runtime_properties(&descriptor_state)?;
        // Published last, so a reader never sees a scene whose properties have
        // not been applied yet. Withdrawal is the scene's own responsibility
        // and happens on close and on drop.
        runtime.renderer.publish_runtime_state(
            &crate::SceneRegistry::shared(),
            handle.raw(),
            desc.display.display_id,
        );
        Ok(runtime)
    }

    /// Renderer work counters for this surface, with the identity needed to
    /// tell one surface's exclusive work from the source work it shares.
    pub fn counters(&self) -> Result<RendererSurfaceCounters, EngineError> {
        Ok(RendererSurfaceCounters {
            display_id: self.desc.display.display_id,
            handle: self.handle,
            generation: self.generation,
            source_path: self.desc.scene_path.clone(),
            paused: self.paused,
            values: self.renderer.counters()?,
        })
    }

    pub fn set_scaling_mode(&mut self, mode: ScalingMode) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_scaling_mode(mode)?;
        self.scaling_mode = mode;
        self.desc.scaling_mode = mode;
        Ok(())
    }

    pub fn set_scaling_factor(&mut self, factor: f64) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_scaling_factor(factor)?;
        self.scaling_factor = factor;
        self.desc.scaling_factor = factor;
        Ok(())
    }

    /// Live-updates where the presented wallpaper sits inside the room its
    /// display leaves around it.
    ///
    /// Like the scaling setters, and unlike [`Self::rebuild_for_desc`], nothing
    /// is reparsed or reopened: the renderer moves the picture in place. The
    /// pointer mapping changes with it, so queued pointer delivery restarts.
    /// The runtime and its descriptor change only once the renderer accepted
    /// the value, so a rejection leaves both as they were.
    pub fn set_framing(&mut self, framing: SceneFraming) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_framing(framing)?;
        self.framing = framing;
        self.desc.framing = framing;
        Ok(())
    }

    /// Shows the presented wallpaper at `framing` without making that its
    /// position: the renderer moves, the runtime and its descriptor do not.
    ///
    /// A drag editor calls this for every step of a drag and ends it with
    /// [`Self::set_framing`]. Keeping the committed value out of it means a
    /// drag that is abandoned halfway leaves the live descriptor equal to the
    /// saved configuration, so the next reconcile finds nothing to rebuild and
    /// a renderer rebuild goes back to the committed position instead of
    /// keeping a half-finished one.
    pub fn preview_framing(&mut self, framing: SceneFraming) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_framing(framing)
    }

    pub fn set_fps(&mut self, fps: u32) -> Result<(), EngineError> {
        self.renderer.set_target_fps(fps)?;
        self.desc.fps = fps;
        Ok(())
    }

    /// Live-updates this surface's internal rasterization scale.
    ///
    /// Deliberately not routed through [`Self::rebuild_for_desc`]: that
    /// reparses the project and reopens any video, which a quality control the
    /// user drags must never do. The renderer resizes its own targets in
    /// place.
    ///
    /// The scale is remembered, so a renderer this runtime opens later (a
    /// recovery rebuild included) is handed it again.
    pub fn set_render_scale(&mut self, scale: f64) -> Result<(), EngineError> {
        self.render_scale.set(scale, |scale| self.renderer.set_render_scale(scale))
    }

    pub fn set_paused(&mut self, paused: bool) -> Result<(), EngineError> {
        if self.paused != paused {
            self.pointer_input.delivery.invalidate();
        }
        self.renderer.set_paused(paused)?;
        self.paused = paused;
        Ok(())
    }

    pub fn set_mouse_position(&mut self, x: f64, y: f64) -> Result<(), EngineError> {
        self.pointer_input.set_position(x, y, |x, y| self.renderer.set_mouse_position(x, y))
    }

    pub fn set_mouse_button(&mut self, button: u32, pressed: bool) -> Result<(), EngineError> {
        self.pointer_input.set_button(button, pressed, |button, pressed| self.renderer.set_mouse_button(button, pressed))
    }

    pub fn reconcile_mouse_button_baseline(&mut self, buttons: MouseButtonEdges) -> Result<(), EngineError> {
        self.pointer_input.reconcile_button_baseline(buttons, |down| self.renderer.set_mouse_button_baseline(down))
    }

    pub fn set_mouse_entered(&mut self, entered: bool) -> Result<(), EngineError> {
        self.pointer_input.set_entered(entered, |entered| self.renderer.set_mouse_entered(entered))
    }

    pub fn accepts_pointer_input(&self) -> bool { self.pointer_input.accepts_pointer_input }

    /// Whether the scene this renderer is showing reads system audio.
    pub fn requires_audio(&self) -> bool { self.requires_audio }

    /// Applies a renderer's audio-requirement report. Returns whether it
    /// changed anything; a report from a renderer object this runtime no
    /// longer holds changes nothing.
    pub fn apply_audio_requirement(&mut self, instance: &Arc<()>, requires_audio: bool) -> bool {
        if self.window.is_none() || !Arc::ptr_eq(&self.audio_relay.renderer_instance, instance) {
            return false;
        }
        let changed = self.requires_audio != requires_audio;
        self.requires_audio = requires_audio;
        changed
    }

    pub fn paused(&self) -> bool { self.paused }

    /// A presenting, interactive scene has lost its last delivered pointer
    /// state (new runtime, resume, capability or layout change) and needs a
    /// sample even though the cursor may not have moved.
    pub fn pointer_sample_pending(&self) -> bool {
        !self.paused && self.pointer_input.sample_pending()
    }

    pub fn apply_pointer_input_capability(&mut self, instance: &Arc<()>, accepts: bool) -> bool {
        if self.window.is_none() { return false; }
        self.pointer_input.apply(instance, accepts)
    }

    pub fn set_render_resolution(
        &mut self,
        backend: OweBackend,
        width: u32,
        height: u32,
    ) -> Result<(), EngineError> {
        self.rebuild_for_desc(backend, &self.desc.clone(), Some((width, height)))
    }

    fn rebuild_for_desc(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
        render_resolution: Option<(u32, u32)>,
    ) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let mut state = self.runtime_state();
        let current_descriptor_state = SceneRuntimeState::try_from(&self.desc)?;
        let descriptor_state = SceneRuntimeState::try_from(desc)?;
        let mut stored_desc = desc.clone();
        stored_desc.mark_shader_refresh_complete();
        let inheritance = if self.desc.same_wallpaper(desc) {
            DescriptorInheritance::PreserveRuntimeOverrides
        } else {
            DescriptorInheritance::UseDescriptorDefaults
        };
        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &descriptor_state,
            inheritance,
        );
        let render_scale = self.render_scale;
        let first_frame_callback = self.renderer_first_frame_callback();
        let (pointer_relay, pointer_callback) = PointerInputRelay::new(self.actor.clone(), self.handle)?;
        // Both open paths, or a wallpaper switch on this display would
        // silently un-wire the buttons the user just used.
        let (shortcut_relay, shortcut_callback) =
            UserShortcutRelay::new(self.actor.clone(), self.handle)?;
        let (audio_relay, audio_callback) = AudioRequirementRelay::new(self.actor.clone(), self.handle)?;
        let (failure_relay, failure_callback) =
            RenderFailureRelay::new(self.actor.clone(), self.handle)?;
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("wallpaper window is already closed".to_string())
        })?;

        // Swap the CAMetalLayer BEFORE creating the new OWE scene so that
        // each SceneWallpaper's VkSurface references its own CAMetalLayer.
        // If we reused the old layer via `update_display`, the new VkSurface
        // would be created on the same CAMetalLayer that the old VkSurface
        // still references (it's destroyed only in `old_renderer.close()`
        // below), violating the VK_EXT_metal_surface invariant that only
        // one VkSurfaceKHR can be associated with a CAMetalLayer at a time.
        //
        // The old CAMetalLayer remains alive via MoltenVK's retain through
        // the old VkSurface, and is deallocated when `old_renderer.close()`
        // destroys that surface.
        //
        // The swap is a transaction. The window keeps the old layer until the
        // new renderer exists, because a replacement that fails leaves the old
        // renderer in place, drawing on that layer: it has to be back under
        // the view then, or the display stays on the empty new layer.
        let swap = window.begin_layer_swap(desc.display.clone(), LayerInstall::Replace)?;

        let mut renderer = match backend.open_scene(
            desc,
            swap.layer_ptr(),
            state.scaling_mode,
            state.scaling_factor,
            state.framing,
            render_resolution,
            Some(first_frame_callback),
            Some(pointer_callback),
            Some(shortcut_callback),
            Some(audio_callback),
            Some(failure_callback),
        ) {
            Ok(renderer) => renderer,
            Err(error) => {
                restore_previous_layer(window, swap, &error);
                return Err(error);
            }
        };
        // A new renderer rasterizes at native size whichever wallpaper it
        // opens, so the scale in force is handed over with the rest of the
        // runtime state rather than left for the next quality change.
        if let Err(error) = state
            .apply_to(&mut renderer, &descriptor_state)
            .and_then(|()| render_scale.restore(|scale| renderer.set_render_scale(scale)))
        {
            // Closed first, so nothing but the window holds the new layer
            // when it is taken out of the view.
            let _ = renderer.close();
            restore_previous_layer(window, swap, &error);
            return Err(error);
        }
        swap.finish();
        let mut old_renderer = std::mem::replace(&mut self.renderer, renderer);
        self.renderer.inherit_runtime_registration(&mut old_renderer, desc.display.display_id);
        self.last_media = None;
        self.generation = self.generation.saturating_add(1);
        let old_relay = std::mem::replace(&mut self.pointer_relay, pointer_relay);
        drop(std::mem::replace(&mut self.shortcut_relay, shortcut_relay));
        // The new renderer's scene has not reported yet; the old one's
        // requirement must not keep the system-audio tap open for it.
        drop(std::mem::replace(&mut self.audio_relay, audio_relay));
        // A report from the renderer being replaced must not be taken for the
        // new one's, and the new one has failed nothing yet.
        drop(std::mem::replace(&mut self.failure_relay, failure_relay));
        self.surface_recovery = SurfaceRecovery::default();
        self.requires_audio = false;
        self.pointer_input = NativePointerInputState::new(self.pointer_relay.renderer_instance.clone());
        old_relay.stop();
        self.desc = stored_desc;
        self.scaling_mode = state.scaling_mode;
        self.scaling_factor = state.scaling_factor;
        self.framing = state.framing;
        self.render_resolution = render_resolution;
        self.audio_response_enabled = state.audio_response_enabled;
        self.media_integration_enabled = state.media_integration_enabled;
        self.audio_volume = state.audio_volume;
        self.audio_muted = state.audio_muted;
        self.property_override_json = state.property_override_json;
        old_renderer.close()
    }

    pub fn replace_wallpaper(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        self.rebuild_for_desc(backend, desc, self.render_resolution)
    }

    pub fn resize_or_rebuild(
        &mut self,
        backend: OweBackend,
        display: DisplayDesc,
    ) -> Result<(), EngineError> {
        if self.desc.display == display {
            return Ok(());
        }
        // Note: the fast surface-reconfigure transaction lives in
        // `run_runtime_refresh_job`'s `ReopenRuntime` branch, not here. This
        // method is reached only from `RebuildExistingRuntime`, which by
        // construction means wallpaper-defining fields have changed and a
        // full scene rebuild is required.
        let mut desc = self.desc.clone();
        desc.display = display;
        self.rebuild_for_desc(backend, &desc, self.render_resolution)
    }

    pub fn update_window_display(&mut self, display: DisplayDesc) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("scene runtime has no window during display update".to_string())
        })?;
        window.update_display(display.clone())?;
        self.renderer.update_runtime_display(display.display_id);
        self.desc.display = display;
        Ok(())
    }

    /// Fast-path display reconfiguration. Preserves scene, shaders, render
    /// graph, audio, and runtime state; only the Vulkan surface, swapchain,
    /// and presentation passes are rebuilt.
    ///
    /// On any failure, returns `Err`; the caller should fall back to
    /// `rebuild_for_desc`.
    pub fn reconfigure_for_display(
        &mut self,
        backend: OweBackend,
        display: DisplayDesc,
    ) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let _ = backend; // retained in signature for symmetry with rebuild_for_desc
        let start = std::time::Instant::now();
        let runtime_state = self.runtime_state();

        // 1. Pause rendering and release the renderer-side surface.
        self.renderer.begin_surface_reconfigure()?;

        // 2. Swap the CAMetalLayer under the existing NSWindow.
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("scene runtime has no window during reconfigure".to_string())
        })?;
        let metal_layer = window.update_layer(display.clone())?;

        // 3. Compute render resolution from the new display, or keep explicit override
        //    if one was set.
        let (render_width, render_height) = self
            .render_resolution
            .unwrap_or((display.width, display.height));

        // 4. Rebuild the Vulkan surface + swapchain + presentation passes from the new
        //    layer, and resume rendering.
        self.renderer.finish_surface_reconfigure(
            metal_layer,
            display.width,
            display.height,
            render_width,
            render_height,
            display.scale_factor,
        )?;

        // 5. OWE resumes after finishing the surface transaction. Preserve an
        //    already-paused runtime by restoring that state before returning.
        if runtime_state.paused {
            self.renderer.set_paused(true)?;
        }

        // 6. Commit the new descriptor.
        self.renderer.update_runtime_display(display.display_id);
        self.desc.display = display;
        log::debug!(
            "[wallpaper-core engine] display reconfigure completed in {:?}",
            start.elapsed()
        );
        Ok(())
    }

    /// Brings a surface that stopped drawing back, by `step`. Returns the step
    /// that actually did it: a reconfigure that fails (the device is gone, the
    /// layer cannot be swapped) falls straight through to a rebuild rather than
    /// leaving the scene stopped until the next rung is due.
    ///
    /// Either way the wallpaper keeps its runtime state, including a pause, so
    /// recovering never plays what the user paused, and the render scale in
    /// force, so it never comes back at a resolution the user turned down. A
    /// rebuild gives the scene a new renderer and therefore a new instance, but
    /// not a new budget.
    ///
    /// # Errors
    ///
    /// Returns the error of the last thing tried.
    pub fn recover_surface(
        &mut self,
        backend: OweBackend,
        step: RecoveryStep,
    ) -> Result<RecoveryStep, EngineError> {
        if step == RecoveryStep::Reconfigure {
            match self.reconfigure_for_display(backend, self.desc.display.clone()) {
                Ok(()) => return Ok(RecoveryStep::Reconfigure),
                Err(error) => log::warn!(
                    "[wallpaper-core engine] display {} surface reconfigure failed, \
                     rebuilding the renderer instead: {error}",
                    self.desc.display.display_id
                ),
            }
        }
        // The budget belongs to the wallpaper, not to the renderer object this
        // is about to replace.
        let budget = std::mem::take(&mut self.surface_recovery);
        let result = self.replace_wallpaper(backend, &self.desc.clone());
        self.surface_recovery = budget;
        result.map(|()| RecoveryStep::Rebuild)
    }

    /// Whether `instance` names the renderer this runtime holds now.
    pub fn owns_renderer(&self, instance: &Arc<()>) -> bool {
        self.window.is_some() && Arc::ptr_eq(&self.failure_relay.renderer_instance, instance)
    }

    /// The token that names this runtime's current renderer object, for work
    /// scheduled against it.
    pub fn renderer_instance(&self) -> Arc<()> { self.failure_relay.renderer_instance.clone() }

    /// The number of the load that opened the current renderer, for log lines.
    pub fn load_id(&self) -> u64 { self.renderer.load_id() }

    pub fn display_id(&self) -> u32 { self.desc.display.display_id }

    pub fn surface_recovery_mut(&mut self) -> &mut SurfaceRecovery { &mut self.surface_recovery }

    /// The surface's frame-loop health right now; `None` when the renderer
    /// returned no reading.
    pub fn surface_health(&self) -> Option<SurfaceHealth> { self.renderer.surface_health() }

    pub fn set_audio_response_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.renderer.set_audio_response_enabled(enabled)?;
        self.audio_response_enabled = enabled;
        self.desc.audio_response_enabled = enabled;
        Ok(())
    }

    pub fn update_media(&mut self, enabled: bool, state: &crate::media::MediaPollResult) -> Result<(), EngineError> {
        self.renderer.set_media_integration_enabled(true)?;
        if let Some(artwork) = &state.artwork
            && self.last_media.as_ref().and_then(|previous| previous.artwork.as_ref()) != Some(artwork) {
            self.renderer.apply_system_media_artwork(artwork)?;
        }
        for event in state.changed_events(self.last_media.as_ref()) {
            self.renderer.submit_media_event(event)?;
        }
        self.renderer.set_media_integration_enabled(enabled)?;
        self.last_media = Some(state.clone());
        Ok(())
    }

    pub fn set_media_integration_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.renderer.set_media_integration_enabled(enabled)?;
        self.media_integration_enabled = enabled;
        self.desc.media_integration_enabled = enabled;
        Ok(())
    }

    pub fn submit_media_event_json(&mut self, json: &str) -> Result<(), EngineError> {
        if !self.media_integration_enabled {
            return Ok(());
        }
        self.renderer.submit_media_event_json(json)
    }

    pub fn apply_system_media_artwork(
        &mut self,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), EngineError> {
        if !self.media_integration_enabled {
            return Ok(());
        }
        let artwork = crate::media::MediaThumbnailRgba::new(width, height, rgba)
            .map_err(|error| EngineError::InvalidInput(error.to_string()))?;
        self.renderer.apply_system_media_artwork(&artwork)?;
        self.last_media.get_or_insert_with(Default::default).artwork = Some(artwork);
        Ok(())
    }

    pub fn set_audio_volume(&mut self, volume: AudioVolume) -> Result<(), EngineError> {
        self.renderer.set_audio_volume(volume)?;
        self.audio_volume = volume;
        self.desc.audio_volume = volume;
        Ok(())
    }

    pub fn set_audio_muted(&mut self, muted: bool) -> Result<(), EngineError> {
        self.renderer.set_audio_muted(muted)?;
        self.audio_muted = muted;
        self.desc.audio_muted = muted;
        Ok(())
    }

    pub fn set_property_override_json(
        &mut self,
        flat_json: Option<String>,
    ) -> Result<(), EngineError> {
        if let Some(json) = flat_json.as_deref() {
            self.renderer.set_property_override(json)?;
        } else {
            self.renderer.reset_property_override()?;
        }
        self.property_override_json = flat_json;
        Ok(())
    }

    /// Shows a property document on the running scene without making it the
    /// scene's: the renderer follows, the runtime and its descriptor do not.
    ///
    /// An editor calls this for every step of an edit that is not yet saved.
    /// Keeping it out of [`Self::property_override_json`], the descriptor and
    /// the pointer state means an edit that is abandoned leaves the live
    /// descriptor equal to the saved configuration, so the next reconcile finds
    /// nothing to rebuild and a rebuilt renderer shows the saved look. It is
    /// the opposite of [`Self::set_property_override_json`], which loads the
    /// scene again with the override and remembers it.
    ///
    /// The document is for the wallpaper at `expected_scene_path`; a scene that
    /// draws another is left alone.
    pub fn preview_property_override_json(
        &mut self,
        expected_scene_path: &str,
        flat_json: &str,
    ) -> Result<PropertyPreview, EngineError> {
        preview_on_scene_of(&self.desc.scene_path, &mut self.renderer, expected_scene_path, flat_json)
    }

    pub fn close(&mut self) -> Result<(), EngineError> {
        self.pointer_relay.stop();
        self.shortcut_relay.stop();
        self.audio_relay.stop();
        self.failure_relay.stop();
        self.requires_audio = false;
        let backend_result = self.renderer.close();
        if let Some(mut window) = self.window.take() {
            window.close();
        }
        backend_result
    }

    pub fn runtime_state(&self) -> SceneRuntimeState {
        SceneRuntimeState {
            scaling_mode: self.scaling_mode,
            scaling_factor: self.scaling_factor,
            framing: self.framing,
            render_resolution: self.render_resolution,
            audio_response_enabled: self.audio_response_enabled,
            media_integration_enabled: self.media_integration_enabled,
            paused: self.paused,
            audio_volume: self.audio_volume,
            audio_muted: self.audio_muted,
            property_override_json: self.property_override_json.clone(),
        }
    }

    pub(crate) fn runtime_state_for_desc(
        &self,
        desc: &SceneDesc,
    ) -> Result<SceneRuntimeState, EngineError> {
        let mut state = self.runtime_state();
        state.inherit_descriptor_transition(&self.desc, desc)?;
        Ok(state)
    }

    fn apply_runtime_properties(
        &mut self,
        descriptor_state: &SceneRuntimeState,
    ) -> Result<(), EngineError> {
        let state = self.runtime_state();
        state.apply_to(&mut self.renderer, descriptor_state)
    }

    fn renderer_first_frame_callback(&self) -> crate::owe::backend::FirstFrameCallback {
        Arc::new({
            let callback = self.first_frame_callback.clone();
            let handle = self.handle;
            move || callback(handle)
        })
    }
}

/// Shows `flat_json` on `renderer`, which draws the wallpaper at `drawn`, when
/// the document was made for that wallpaper.
///
/// A property document is the whole property state of one project, and the
/// renderer applies it by name, so a document for another wallpaper would not
/// be refused: it would replace this scene's saved values with the other
/// project's wherever the names collide and with authored defaults everywhere
/// else. Nothing in the document says which project it came from, so the caller
/// says, and the answer is compared here, with what the scene draws at the
/// moment the request is handled.
///
/// Apart from [`SceneRuntime`], which cannot exist without a window, so that the
/// rule can be tested against a renderer object alone.
#[allow(clippy::single_call_fn)]
fn preview_on_scene_of(
    drawn: &str,
    renderer: &mut OweScene,
    expected_scene_path: &str,
    flat_json: &str,
) -> Result<PropertyPreview, EngineError> {
    if drawn != expected_scene_path {
        return Ok(PropertyPreview::OtherWallpaper);
    }
    renderer.preview_property_override(flat_json)?;
    Ok(PropertyPreview::Shown)
}

impl Drop for SceneRuntime {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

impl SceneRuntimeState {
    pub(crate) fn inherit_descriptor_transition(
        &mut self,
        current_desc: &SceneDesc,
        next_desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        let current_descriptor_state = Self::try_from(current_desc)?;
        let next_descriptor_state = Self::try_from(next_desc)?;
        let inheritance = if current_desc.same_wallpaper(next_desc) {
            DescriptorInheritance::PreserveRuntimeOverrides
        } else {
            DescriptorInheritance::UseDescriptorDefaults
        };
        self.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            inheritance,
        );
        Ok(())
    }

    fn apply_to(
        &self,
        renderer: &mut OweScene,
        descriptor_state: &SceneRuntimeState,
    ) -> Result<(), EngineError> {
        if self.paused != descriptor_state.paused {
            renderer.set_paused(self.paused)?;
        }
        if self.audio_response_enabled != descriptor_state.audio_response_enabled {
            renderer.set_audio_response_enabled(self.audio_response_enabled)?;
        }
        if self.media_integration_enabled != descriptor_state.media_integration_enabled {
            renderer.set_media_integration_enabled(self.media_integration_enabled)?;
        }
        if self.audio_volume != descriptor_state.audio_volume {
            renderer.set_audio_volume(self.audio_volume)?;
        }
        if self.audio_muted != descriptor_state.audio_muted {
            renderer.set_audio_muted(self.audio_muted)?;
        }
        match self.property_override_update(descriptor_state) {
            PropertyOverrideUpdate::Unchanged => {}
            PropertyOverrideUpdate::Apply(json) => renderer.set_property_override(json)?,
            PropertyOverrideUpdate::Reset => renderer.reset_property_override()?,
        }
        Ok(())
    }

    fn property_override_update<'a>(
        &'a self,
        descriptor_state: &SceneRuntimeState,
    ) -> PropertyOverrideUpdate<'a> {
        match (
            self.property_override_json.as_deref(),
            descriptor_state.property_override_json.as_deref(),
        ) {
            (runtime, descriptor) if runtime == descriptor => PropertyOverrideUpdate::Unchanged,
            (Some(json), _) => PropertyOverrideUpdate::Apply(json),
            (None, Some(_)) => PropertyOverrideUpdate::Reset,
            (None, None) => PropertyOverrideUpdate::Unchanged,
        }
    }

    fn inherit_descriptor_property_override(
        &mut self,
        current_descriptor_state: &SceneRuntimeState,
        next_descriptor_state: &SceneRuntimeState,
    ) {
        if self.property_override_json == current_descriptor_state.property_override_json {
            self.property_override_json
                .clone_from(&next_descriptor_state.property_override_json);
        }
    }

    fn inherit_descriptor_defaults(
        &mut self,
        current_descriptor_state: &SceneRuntimeState,
        next_descriptor_state: &SceneRuntimeState,
        inheritance: DescriptorInheritance,
    ) {
        self.inherit_descriptor_property_override(current_descriptor_state, next_descriptor_state);

        if inheritance == DescriptorInheritance::UseDescriptorDefaults {
            self.scaling_mode = next_descriptor_state.scaling_mode;
            self.scaling_factor = next_descriptor_state.scaling_factor;
            self.framing = next_descriptor_state.framing;
            self.audio_response_enabled = next_descriptor_state.audio_response_enabled;
            self.media_integration_enabled = next_descriptor_state.media_integration_enabled;
            self.audio_volume = next_descriptor_state.audio_volume;
            self.audio_muted = next_descriptor_state.audio_muted;
        }
    }
}

impl TryFrom<&SceneDesc> for SceneRuntimeState {
    type Error = EngineError;

    fn try_from(desc: &SceneDesc) -> Result<Self, Self::Error> {
        // Descriptor values seed runtime state only for first open. Later
        // reconciliations keep explicit API changes such as property overrides.
        Ok(Self {
            scaling_mode: desc.scaling_mode,
            scaling_factor: desc.scaling_factor,
            framing: desc.framing,
            render_resolution: None,
            audio_response_enabled: desc.audio_response_enabled,
            media_integration_enabled: desc.media_integration_enabled,
            paused: desc.paused,
            audio_volume: desc.audio_volume,
            audio_muted: desc.audio_muted,
            property_override_json: desc
                .property_override_json
                .as_deref()
                .map(|json| {
                    let flat_json = serde_json::from_str::<Value>(json)
                        .map_err(|e| EngineError::InvalidInput(e.to_string()))?
                        .flatten()?;
                    serde_json::to_string(&flat_json)
                        .map_err(|e| EngineError::InvalidInput(e.to_string()))
                })
                .transpose()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::window::MouseButtonTracker;

    #[derive(Debug, PartialEq, Eq)]
    enum ButtonDelivery {
        Baseline(u32),
        Transition(u32, bool),
    }

    fn deliver_sample_buttons(state: &mut NativePointerInputState, buttons: MouseButtonEdges) -> Vec<ButtonDelivery> {
        let mut sent = Vec::new();
        state.reconcile_button_baseline(buttons, |down| {
            sent.push(ButtonDelivery::Baseline(down));
            Ok(())
        }).unwrap();
        for edge in buttons.transitions() {
            state.set_button(edge.button, edge.pressed, |button, pressed| {
                sent.push(ButtonDelivery::Transition(button, pressed));
                Ok(())
            }).unwrap();
        }
        sent
    }

    #[test]
    fn released_during_video_reconciles_stale_native_down_without_replaying_release() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        tracker.set_button(0, true);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(0), ButtonDelivery::Transition(0, true),
        ]);
        assert!(state.apply(&token, false));
        tracker.set_button(0, false);
        // The publisher discards all-video edges, retaining only the level.
        let _ = tracker.consume_edges();
        assert!(state.apply(&token, true));
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(0),
        ]);
    }

    #[test]
    fn video_held_level_has_no_press_and_its_next_release_survives() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        assert!(state.apply(&token, false));
        tracker.set_button(31, true);
        let _ = tracker.consume_edges();
        state.reconcile_button_baseline(tracker.consume_edges(), |_| panic!("video baseline")).unwrap();
        assert!(state.apply(&token, true));
        let held = tracker.consume_edges();
        assert!(held.transitions().next().is_none());
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1 << 31)]);
        tracker.set_button(31, false);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Transition(31, false),
        ]);
    }

    #[test]
    fn activation_tap_and_first_sample_release_keep_their_transitions() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        assert!(state.apply(&token, false));
        tracker.set_button(1, true);
        let _ = tracker.consume_edges();
        assert!(state.apply(&token, true));
        // Both changes are after activation but before the first sample.
        tracker.set_button(1, false);
        tracker.set_button(0, true);
        tracker.set_button(0, false);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(2),
            ButtonDelivery::Transition(0, true),
            ButtonDelivery::Transition(0, false),
            ButtonDelivery::Transition(1, false),
        ]);
    }

    #[test]
    fn same_bool_commit_reconciles_once_and_old_token_or_delivery_reset_does_not() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let held = MouseButtonEdges::from_masks(1, 0, 0);
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1)]);
        assert!(!state.apply(&Arc::new(()), false));
        state.delivery.invalidate();
        assert!(deliver_sample_buttons(&mut state, held).is_empty());
        assert!(!state.apply(&token, true));
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1)]);
        // An already accepted press must not cause another same-scene baseline
        // before a later release; native retains both until its next draw.
        assert_eq!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(3, 2, 0)), vec![
            ButtonDelivery::Transition(1, true),
        ]);
        assert_eq!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(1, 0, 2)), vec![
            ButtonDelivery::Transition(1, false),
        ]);
        let mut replacement = NativePointerInputState::new(Arc::new(()));
        assert_eq!(deliver_sample_buttons(&mut replacement, held), vec![ButtonDelivery::Baseline(1)]);
    }

    #[test]
    fn failed_baseline_retries_using_latest_sample_and_preserves_direct_delivery() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token);
        let held = MouseButtonEdges::from_masks(1, 0, 0);
        assert!(state.reconcile_button_baseline(held, |_| Err(EngineError::Platform("baseline".into()))).is_err());
        // Direct setters remain direct even while sampled reconciliation is
        // pending. The later baseline must not clear this accepted native edge.
        let mut sent = Vec::new();
        state.set_button(2, true, |button, pressed| {
            sent.push(ButtonDelivery::Transition(button, pressed));
            Ok(())
        }).unwrap();
        sent.extend(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(4, 0, 1)));
        assert_eq!(sent, vec![
            ButtonDelivery::Transition(2, true),
            ButtonDelivery::Baseline(5),
            ButtonDelivery::Transition(0, false),
        ]);
        assert!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(4, 0, 0)).is_empty());
    }

    #[test]
    fn video_gate_validates_input_and_never_deduplicates_buttons() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        assert!(state.apply(&token, false));
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(matches!(state.set_position(invalid, 0.0, |_, _| panic!("video native call")), Err(EngineError::InvalidInput(_))));
        }
        for invalid in [32, u32::MAX] {
            assert!(matches!(state.set_button(invalid, true, |_, _| panic!("video native call")), Err(EngineError::InvalidInput(_))));
        }
        state.set_position(0.5, 0.5, |_, _| panic!("video native call")).unwrap();
        state.set_button(0, true, |_, _| panic!("video native call")).unwrap();
        state.set_entered(true, |_| panic!("video native call")).unwrap();
        assert!(state.apply(&token, true));
        let mut positions = Vec::new();
        state.set_position(0.5, 0.5, |x, y| { positions.push((x, y)); Ok(()) }).unwrap();
        state.set_position(0.5, 0.5, |_, _| panic!("duplicate position")).unwrap();
        assert_eq!(positions, vec![(0.5, 0.5)]);
        let mut buttons = Vec::new();
        for pressed in [true, true, false, false] {
            state.set_button(0, pressed, |button, pressed| { buttons.push((button, pressed)); Ok(()) }).unwrap();
        }
        assert_eq!(buttons, vec![(0, true), (0, true), (0, false), (0, false)]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn replacement_ignores_delayed_same_handle_instance() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let handle = SceneHandle::new(9);
        let (old_relay, old_callback) = PointerInputRelay::new(actor_ref.downgrade(), handle).unwrap();
        let (new_relay, new_callback) = PointerInputRelay::new(actor_ref.downgrade(), handle).unwrap();
        let mut state = NativePointerInputState::new(new_relay.renderer_instance.clone());
        let join = prepared.spawn(actor);
        new_callback(false);
        let token = wait_pointer_notification(&actor_ref, false).await;
        assert!(state.apply(&token, false));
        old_callback(true);
        let stale_token = wait_pointer_notification(&actor_ref, true).await;
        assert!(!state.apply(&stale_token, true));
        assert!(!state.accepts_pointer_input);
        new_callback(true);
        let token = wait_pointer_notification(&actor_ref, true).await;
        assert!(state.apply(&token, true));
        new_callback(false);
        let token = wait_pointer_notification(&actor_ref, false).await;
        assert!(state.apply(&token, false));
        drop(old_relay);
        drop(new_relay);
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[test]
    fn delivery_retries_failures_and_reentry_without_rounding() {
        let mut delivery = MouseDeliveryState::default();
        let mut received = Vec::new();
        delivery.set_position(0.5, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        delivery.set_position(0.5, 0.5, |_, _| panic!("duplicate delivery")).unwrap();
        let tiny = f64::from_bits(0.5f64.to_bits() + 1);
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        assert!(delivery.set_position(0.2, 0.5, |_, _| Err(EngineError::Platform("send".into()))).is_err());
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        delivery.set_entered(true, |_| Ok(())).unwrap();
        delivery.set_entered(true, |_| panic!("duplicate enter")).unwrap();
        assert!(delivery.set_entered(false, |_| Err(EngineError::Platform("leave".into()))).is_err());
        delivery.set_entered(true, |_| Ok(())).unwrap();
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        assert_eq!(received, vec![(0.5, 0.5), (tiny, 0.5), (tiny, 0.5), (tiny, 0.5)]);
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(delivery.set_position(invalid, 0.0, |_, _| panic!("invalid native input")).is_err());
        }
    }

    #[test]
    fn native_commit_identity_and_same_value_invalidate_delivery() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        state.delivery.set_position(0.2, 0.3, |_, _| Ok(())).unwrap();
        let old = Arc::new(());
        assert!(!state.apply(&old, false));
        state.delivery.set_position(0.2, 0.3, |_, _| panic!("stale commit changed cache")).unwrap();
        assert!(!state.apply(&token, true));
        let mut sent = false;
        state.delivery.set_position(0.2, 0.3, |_, _| { sent = true; Ok(()) }).unwrap();
        assert!(sent);
        assert!(state.apply(&token, false));
        assert!(!state.accepts_pointer_input);
        assert!(state.apply(&token, true));
        assert!(state.accepts_pointer_input);
        state.delivery.set_entered(true, |_| Ok(())).unwrap();
        state.delivery.invalidate();
        let mut entered_sent = false;
        state.delivery.set_entered(true, |_| { entered_sent = true; Ok(()) }).unwrap();
        assert!(entered_sent);
    }

    fn prepared_empty_actor() -> (kameo::actor::PreparedActor<EngineActor>, EngineActor) {
        use kameo::actor::Spawn;
        let prepared = EngineActor::prepare();
        let state = crate::engine::state::EngineState::default();
        let snapshots = Arc::new(crate::engine::EngineSnapshotPublisher::new(
            state.snapshot(),
            Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new())),
        ));
        let actor = EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots, prepared.actor_ref().downgrade());
        (prepared, actor)
    }

    async fn wait_pointer_notification(actor: &kameo::actor::ActorRef<EngineActor>, value: bool) -> Arc<()> {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let notifications = actor.ask(crate::engine::messages::TakePointerNotificationsForTest).await.unwrap();
                if let Some((instance, _)) = notifications.into_iter().find(|(_, accepts)| *accepts == value) {
                    return instance;
                }
                tokio::task::yield_now().await;
            }
        }).await.expect("relay should deliver without mailbox loss")
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_replays_before_commit_and_survives_full_bounded_mailbox() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let (relay, callback) = PointerInputRelay::new(actor_ref.downgrade(), SceneHandle::new(7)).unwrap();
        // Fill the real default mailbox before the actor has started.
        let mut count = 0;
        loop {
            match actor_ref.tell(crate::engine::messages::Ping).try_send() {
                Ok(()) => count += 1,
                Err(kameo::error::SendError::MailboxFull(_)) => break,
                Err(error) => panic!("unexpected mailbox error: {error}"),
            }
        }
        assert_eq!(count, 64);
        callback(true);
        tokio::task::yield_now().await;
        // The first notification is blocked; the native callback remains synchronous.
        callback(false);
        callback(true);
        callback(false);
        let join = prepared.spawn(actor);
        let delivered = wait_pointer_notification(&actor_ref, false).await;
        assert!(Arc::ptr_eq(&delivered, &relay.renderer_instance));
        callback(true);
        let delivered = wait_pointer_notification(&actor_ref, true).await;
        assert!(Arc::ptr_eq(&delivered, &relay.renderer_instance));
        relay.stop();
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_drop_aborts_full_mailbox_and_releases_actor_owner() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let weak = actor_ref.downgrade();
        let (relay, callback) = PointerInputRelay::new(weak.clone(), SceneHandle::new(1)).unwrap();
        while actor_ref.tell(crate::engine::messages::Ping).try_send().is_ok() {}
        callback(false);
        tokio::task::yield_now().await;
        let aborted = relay.task.abort_handle();
        drop(relay);
        callback(true);
        tokio::task::yield_now().await;
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !aborted.is_finished() { tokio::task::yield_now().await; }
        }).await.expect("aborted relay should release its pending mailbox send");
        drop(actor_ref);
        drop(actor);
        drop(prepared);
        assert!(weak.upgrade().is_none());
        // The native forwarder holds only the watch sender, not an engine owner.
        callback(false);
    }

    async fn wait_render_failures(
        actor: &kameo::actor::ActorRef<EngineActor>,
        count: usize,
    ) -> Vec<Arc<()>> {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            let mut seen = Vec::new();
            while seen.len() < count {
                seen.extend(
                    actor
                        .ask(crate::engine::messages::TakeRenderFailuresForTest)
                        .await
                        .unwrap(),
                );
                tokio::task::yield_now().await;
            }
            seen
        })
        .await
        .expect("the relay should deliver a render failure to the actor")
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_render_failure_reaches_the_actor_tagged_with_its_renderer_and_a_burst_is_one_report() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let (relay, callback) =
            RenderFailureRelay::new(actor_ref.downgrade(), SceneHandle::new(3)).unwrap();
        // The native callback is synchronous and never blocks, whatever the
        // actor is doing: a burst raised before the actor runs is one report.
        callback();
        callback();
        callback();
        let join = prepared.spawn(actor);

        let delivered = wait_render_failures(&actor_ref, 1).await;
        assert!(Arc::ptr_eq(&delivered[0], &relay.renderer_instance));
        // An actor that finds no scene behind the report does nothing with it
        // and stays up to serve the next one.
        callback();
        let again = wait_render_failures(&actor_ref, 1).await;
        assert!(Arc::ptr_eq(&again[0], &relay.renderer_instance));
        assert_eq!(
            actor_ref
                .ask(crate::engine::messages::TakeRenderFailuresForTest)
                .await
                .unwrap()
                .len(),
            0,
            "three calls before the actor ran must not become three reports"
        );

        relay.stop();
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn two_renderers_for_one_scene_report_under_different_instances() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let handle = SceneHandle::new(3);
        let (old, old_callback) = RenderFailureRelay::new(actor_ref.downgrade(), handle).unwrap();
        let (new, new_callback) = RenderFailureRelay::new(actor_ref.downgrade(), handle).unwrap();
        assert!(
            !Arc::ptr_eq(&old.renderer_instance, &new.renderer_instance),
            "a rebuilt renderer must not answer to its predecessor's token"
        );
        let join = prepared.spawn(actor);

        old_callback();
        let late = wait_render_failures(&actor_ref, 1).await;
        new_callback();
        let current = wait_render_failures(&actor_ref, 1).await;
        assert!(Arc::ptr_eq(&late[0], &old.renderer_instance));
        assert!(Arc::ptr_eq(&current[0], &new.renderer_instance));

        old.stop();
        new.stop();
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_stopped_relay_reports_nothing_more() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let (relay, callback) =
            RenderFailureRelay::new(actor_ref.downgrade(), SceneHandle::new(3)).unwrap();
        let join = prepared.spawn(actor);
        let aborted = relay.task.abort_handle();

        drop(relay);
        callback();
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !aborted.is_finished() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("a dropped relay should end its task");
        tokio::task::yield_now().await;
        assert!(
            actor_ref
                .ask(crate::engine::messages::TakeRenderFailuresForTest)
                .await
                .unwrap()
                .is_empty(),
            "a renderer that was closed must not report a failure"
        );

        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn recovery_asked_for_a_display_with_no_scene_finds_nothing_to_heal() {
        use crate::engine::surface_recovery::{RecoveryOutcome, RecoveryReason};
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let join = prepared.spawn(actor);

        for reason in [RecoveryReason::RenderFailure, RecoveryReason::Stalled] {
            let outcome = actor_ref
                .ask(crate::engine::messages::RecoverSurface { display_id: 9, reason })
                .await
                .unwrap();
            assert_eq!(outcome, RecoveryOutcome::NoScene);
        }
        // A scheduled attempt whose scene is gone ends quietly and leaves the
        // engine serving.
        actor_ref
            .tell(crate::engine::messages::RecoverSurfaceAttempt {
                handle: SceneHandle::new(9),
                renderer_instance: Arc::new(()),
                step: crate::engine::surface_recovery::RecoveryStep::Reconfigure,
                number: 1,
            })
            .send()
            .await
            .unwrap();
        actor_ref.ask(crate::engine::messages::Ping).await.unwrap();
        // So does the look at a rebuilt renderer whose scene is gone: it must
        // not schedule another look at nothing.
        actor_ref
            .tell(crate::engine::messages::SettleRecoveredSurface {
                handle: SceneHandle::new(9),
                renderer_instance: Arc::new(()),
                number: 2,
                rebuilt_at: std::time::Instant::now(),
            })
            .send()
            .await
            .unwrap();
        actor_ref.ask(crate::engine::messages::Ping).await.unwrap();

        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[test]
    fn relay_without_runtime_returns_error() {
        let (prepared, _actor) = prepared_empty_actor();
        assert!(PointerInputRelay::new(prepared.actor_ref().downgrade(), SceneHandle::new(1)).is_err());
    }

    #[test]
    fn a_document_for_another_wallpaper_never_reaches_the_renderer() {
        let mut renderer = OweScene::uninitialized_for_test();

        // The scene on the handle is the second wallpaper's now, and the first
        // one's document was made before the engine switched it.
        let outcome = preview_on_scene_of(
            "/library/200/project.json",
            &mut renderer,
            "/library/100/project.json",
            r#"{"alpha":0.5}"#,
        )
        .unwrap();

        assert_eq!(outcome, PropertyPreview::OtherWallpaper);
        assert_eq!(
            renderer.previewed_properties(),
            None,
            "the renderer was not told, so it does not show the document"
        );
    }

    #[test]
    fn a_document_for_the_wallpaper_a_scene_draws_is_shown_and_remembered() {
        let mut renderer = OweScene::uninitialized_for_test();

        let outcome = preview_on_scene_of(
            "/library/100/project.json",
            &mut renderer,
            "/library/100/project.json",
            r#"{"alpha":0.5}"#,
        )
        .unwrap();

        assert_eq!(outcome, PropertyPreview::Shown);
        assert_eq!(renderer.previewed_properties(), Some(r#"{"alpha":0.5}"#));
    }

    #[test]
    fn a_refused_document_for_another_wallpaper_does_not_disturb_what_a_scene_shows() {
        let mut renderer = OweScene::uninitialized_for_test();
        preview_on_scene_of("/library/100/project.json", &mut renderer, "/library/100/project.json", r#"{"alpha":0.5}"#)
            .unwrap();

        let outcome = preview_on_scene_of(
            "/library/100/project.json",
            &mut renderer,
            "/library/200/project.json",
            r#"{"alpha":0.25}"#,
        )
        .unwrap();

        assert_eq!(outcome, PropertyPreview::OtherWallpaper);
        assert_eq!(renderer.previewed_properties(), Some(r#"{"alpha":0.5}"#));
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_pause_state() {
        let desc = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .paused(true)
        .build()
        .expect("scene should build");

        let state = SceneRuntimeState::try_from(&desc).expect("state should build");

        assert!(state.paused);
    }

    #[test]
    fn property_override_delta_keeps_matching_empty_override_unchanged() {
        let state = runtime_state(None);
        let descriptor_state = runtime_state(None);

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Unchanged
        ));
    }

    #[test]
    fn property_override_delta_resets_only_when_descriptor_supplies_override() {
        let state = runtime_state(None);
        let descriptor_state = runtime_state(Some(r#"{"enabled":true}"#));

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Reset
        ));
    }

    #[test]
    fn property_override_delta_applies_runtime_override_when_different() {
        let state = runtime_state(Some(r#"{"enabled":false}"#));
        let descriptor_state = runtime_state(Some(r#"{"enabled":true}"#));

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Apply(r#"{"enabled":false}"#)
        ));
    }

    #[test]
    fn descriptor_property_override_change_is_not_reset_when_runtime_matches_current_descriptor() {
        let mut state = runtime_state(None);
        let current_descriptor_state = runtime_state(None);
        let next_descriptor_state = runtime_state(Some(r#"{"newproperty24":false}"#));

        state.inherit_descriptor_property_override(
            &current_descriptor_state,
            &next_descriptor_state,
        );

        assert_eq!(
            state.property_override_json.as_deref(),
            Some(r#"{"newproperty24":false}"#)
        );
        assert!(matches!(
            state.property_override_update(&next_descriptor_state),
            PropertyOverrideUpdate::Unchanged
        ));
    }

    #[test]
    fn explicit_runtime_property_reset_still_overrides_descriptor_refresh() {
        let mut state = runtime_state(None);
        let current_descriptor_state = runtime_state(Some(r#"{"newproperty24":true}"#));
        let next_descriptor_state = runtime_state(Some(r#"{"newproperty24":false}"#));

        state.inherit_descriptor_property_override(
            &current_descriptor_state,
            &next_descriptor_state,
        );

        assert_eq!(state.property_override_json, None);
        assert!(matches!(
            state.property_override_update(&next_descriptor_state),
            PropertyOverrideUpdate::Reset
        ));
    }

    #[test]
    fn different_wallpaper_rebuild_uses_next_descriptor_render_defaults() {
        let mut state = runtime_state(None);
        state.scaling_mode = ScalingMode::Fill;
        state.scaling_factor = 1.25;
        state.audio_response_enabled = true;
        let mut current_descriptor_state = runtime_state(None);
        current_descriptor_state.scaling_mode = ScalingMode::Fill;
        current_descriptor_state.scaling_factor = 1.25;
        current_descriptor_state.audio_response_enabled = true;
        let mut next_descriptor_state = runtime_state(None);
        next_descriptor_state.scaling_mode = ScalingMode::Stretch;
        next_descriptor_state.scaling_factor = 2.0;
        next_descriptor_state.audio_response_enabled = false;

        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            DescriptorInheritance::UseDescriptorDefaults,
        );

        assert_eq!(state.scaling_mode, ScalingMode::Stretch);
        assert!(
            (state.scaling_factor - 2.0).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 2.0",
            state.scaling_factor
        );
        assert!(!state.audio_response_enabled);
    }

    #[test]
    fn live_runtime_transition_state_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        let current_desc = SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/current/project.json",
        )
        .assets_path("/tmp/assets")
        .scaling_mode(ScalingMode::Fill)
        .scaling_factor(1.25)
        .build()
        .expect("current scene should build");
        let next_desc = SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/next/project.json",
        )
        .assets_path("/tmp/assets")
        .scaling_mode(ScalingMode::Fit)
        .scaling_factor(1.0)
        .build()
        .expect("next scene should build");
        let mut state =
            SceneRuntimeState::try_from(&current_desc).expect("current state should build");

        state
            .inherit_descriptor_transition(&current_desc, &next_desc)
            .expect("transition should build");

        assert_eq!(state.scaling_mode, ScalingMode::Fit);
        assert!(
            (state.scaling_factor - 1.0).abs() <= f64::EPSILON,
            "expected descriptor scaling factor 1.0, got {}",
            state.scaling_factor
        );
    }

    #[test]
    fn same_wallpaper_rebuild_preserves_explicit_runtime_render_overrides() {
        let mut state = runtime_state(None);
        state.scaling_mode = ScalingMode::Fill;
        state.scaling_factor = 1.25;
        state.audio_response_enabled = false;
        let current_descriptor_state = runtime_state(None);
        let mut next_descriptor_state = runtime_state(None);
        next_descriptor_state.scaling_mode = ScalingMode::Stretch;
        next_descriptor_state.scaling_factor = 2.0;
        next_descriptor_state.audio_response_enabled = true;

        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            DescriptorInheritance::PreserveRuntimeOverrides,
        );

        assert_eq!(state.scaling_mode, ScalingMode::Fill);
        assert!(
            (state.scaling_factor - 1.25).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 1.25",
            state.scaling_factor
        );
        assert!(!state.audio_response_enabled);
    }

    fn framed_scene(path: &str, framing: SceneFraming) -> SceneDesc {
        SceneDesc::builder(crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0), path)
            .assets_path("/tmp/assets")
            .framing(framing)
            .build()
            .expect("scene should build")
    }

    #[test]
    fn same_wallpaper_transition_keeps_the_live_framing() {
        let centred = SceneFraming::default();
        let dragged = SceneFraming {
            pan_x: 0.2,
            pan_y: 0.8,
        };
        let current_desc = framed_scene("/tmp/current/project.json", centred);
        let mut next_display = current_desc.clone();
        next_display.display = crate::DisplayDesc::new(2, 1920, 0, 2560, 1440, 2.0);
        next_display.paused = true;
        let mut state =
            SceneRuntimeState::try_from(&current_desc).expect("current state should build");
        state.framing = dragged;

        state
            .inherit_descriptor_transition(&current_desc, &next_display)
            .expect("transition should build");

        assert_eq!(state.framing, dragged);
    }

    #[test]
    fn different_wallpaper_transition_takes_the_next_descriptors_framing() {
        let dragged = SceneFraming {
            pan_x: 0.2,
            pan_y: 0.8,
        };
        let next_framing = SceneFraming {
            pan_x: 0.9,
            pan_y: 0.1,
        };
        let current_desc = framed_scene("/tmp/current/project.json", SceneFraming::default());
        let next_desc = framed_scene("/tmp/next/project.json", next_framing);
        let mut state =
            SceneRuntimeState::try_from(&current_desc).expect("current state should build");
        state.framing = dragged;

        state
            .inherit_descriptor_transition(&current_desc, &next_desc)
            .expect("transition should build");

        assert_eq!(state.framing, next_framing);
    }

    #[test]
    fn a_different_wallpaper_with_an_equal_framing_drops_the_dragged_position() {
        let framing = SceneFraming {
            pan_x: 0.3,
            pan_y: 0.3,
        };
        let current_desc = framed_scene("/tmp/current/project.json", framing);
        let next_desc = framed_scene("/tmp/next/project.json", framing);
        let mut state =
            SceneRuntimeState::try_from(&current_desc).expect("current state should build");
        state.framing = SceneFraming {
            pan_x: 0.9,
            pan_y: 0.9,
        };

        state
            .inherit_descriptor_transition(&current_desc, &next_desc)
            .expect("transition should build");

        assert_eq!(state.framing, framing);
    }

    #[test]
    fn descriptor_framing_seeds_the_first_runtime_state() {
        let framing = SceneFraming {
            pan_x: 0.0,
            pan_y: 1.0,
        };
        let state = SceneRuntimeState::try_from(&framed_scene("/tmp/p/project.json", framing))
            .expect("state should build");

        assert_eq!(state.framing, framing);
    }

    #[test]
    fn a_differing_framing_rebuilds_until_the_live_setter_has_updated_the_descriptor() {
        let live = framed_scene("/tmp/p/project.json", SceneFraming::default());
        let wanted = framed_scene(
            "/tmp/p/project.json",
            SceneFraming {
                pan_x: 0.25,
                pan_y: 0.5,
            },
        );

        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&live), &wanted),
            RuntimeRefreshMode::RebuildExistingRuntime
        );

        // `SceneRuntime::set_framing` stores the accepted value in `desc`.
        let mut after_setter = live.clone();
        after_setter.framing = wanted.framing;
        assert_eq!(
            RuntimeRefreshMode::from_transition(Some(&after_setter), &wanted),
            RuntimeRefreshMode::Unchanged
        );
    }

    #[test]
    fn paused_runtime_requires_pause_restore_after_surface_reconfigure() {
        let mut state = runtime_state(None);
        state.paused = true;

        assert!(state.paused);
    }

    #[test]
    fn running_runtime_does_not_require_pause_restore_after_surface_reconfigure() {
        let state = runtime_state(None);

        assert!(!state.paused);
    }

    /// What a renderer opened right now would be told.
    fn sent_to_new_renderer(scale: RenderScale) -> Option<f64> {
        let mut sent = None;
        scale
            .restore(|value| {
                sent = Some(value);
                Ok(())
            })
            .expect("a renderer that takes the scale reports no error");
        sent
    }

    fn set_accepted(scale: &mut RenderScale, value: f64) {
        scale.set(value, |_| Ok(())).expect("the renderer took the scale");
    }

    #[test]
    fn a_rebuilt_renderer_is_handed_the_reduced_scale_the_runtime_was_given() {
        // A recovery rebuild opens a renderer that starts at native size. The
        // user's reduced scale has to reach it, or the wallpaper comes back
        // drawing four times the pixels while the panel still says 50%.
        let mut scale = RenderScale(RenderScale::NATIVE);
        assert_eq!(sent_to_new_renderer(scale), None, "nothing was ever turned down");

        set_accepted(&mut scale, 0.5);

        assert_eq!(sent_to_new_renderer(scale), Some(0.5));
        assert_eq!(
            sent_to_new_renderer(scale),
            Some(0.5),
            "every rebuild needs it, not just the first one after the change"
        );
    }

    #[test]
    fn a_scale_turned_back_up_to_native_size_is_not_sent_again() {
        let mut scale = RenderScale(RenderScale::NATIVE);
        set_accepted(&mut scale, 0.5);
        set_accepted(&mut scale, RenderScale::NATIVE);

        assert_eq!(sent_to_new_renderer(scale), None, "a new renderer is already at native size");
    }

    #[test]
    fn a_scale_the_renderer_refused_does_not_replace_the_one_in_force() {
        let mut scale = RenderScale(RenderScale::NATIVE);
        set_accepted(&mut scale, 0.5);

        let refused = scale.set(0.25, |_| Err(EngineError::InvalidInput("refused".to_string())));

        assert!(refused.is_err());
        assert_eq!(
            sent_to_new_renderer(scale),
            Some(0.5),
            "the renderer is still drawing at the scale it accepted"
        );
    }

    #[test]
    fn a_new_renderer_that_cannot_take_the_scale_fails_the_rebuild() {
        let mut scale = RenderScale(RenderScale::NATIVE);
        set_accepted(&mut scale, 0.5);

        let result = scale.restore(|_| Err(EngineError::Platform("renderer closed".to_string())));

        assert!(result.is_err(), "the caller has to roll the rebuild back, not keep a wrong-sized renderer");
    }

    fn runtime_state(property_override_json: Option<&str>) -> SceneRuntimeState {
        SceneRuntimeState {
            scaling_mode: ScalingMode::Fit,
            scaling_factor: 1.0,
            framing: SceneFraming::default(),
            render_resolution: None,
            audio_response_enabled: true,
            media_integration_enabled: false,
            paused: false,
            audio_volume: AudioVolume::try_from(1.0).expect("volume should be valid"),
            audio_muted: false,
            property_override_json: property_override_json.map(ToOwned::to_owned),
        }
    }
}
