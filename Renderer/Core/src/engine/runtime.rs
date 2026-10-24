// Clean-room implementation from the WallpaperMachine spec r1a-core-engine.md; written without access to the original source.
use std::{sync::Arc, time::Instant};
use kameo::actor::WeakActorRef;

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
    log_context::LoadScope,
    media::audio::AudioVolume,
    owe::{
        backend::{
            AudioRequirementCallback, OweBackend, OweScene, PointerInputCallback,
            RenderFailureCallback, UserShortcutCallback,
        },
        scene_demand::SurfaceHealth,
    },
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle},
    render::RendererSurfaceCounters,
    SceneRegistry,
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

/// One live scene: its window, its renderer object with the relays that carry
/// the renderer's reports, and the mutable state that outlives a renderer.
pub struct SceneRuntime {
    last_media: Option<crate::media::MediaPollResult>,
    pub desc: SceneDesc,
    handle: SceneHandle,
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
    framing: SceneFraming,
    scaling_mode: ScalingMode,
    scaling_factor: f64,
    /// Explicit rasterization size, used by every in-place reconfigure instead
    /// of the display's pixel size. Not part of the stored descriptor.
    render_resolution: Option<(u32, u32)>,
    audio_response_enabled: bool,
    audio_volume: AudioVolume,
    audio_muted: bool,
    /// The flattened property override in force, `None` when the authored
    /// defaults apply.
    property_override_json: Option<String>,
    /// Handed to every renderer this scene opens, so a callback installed
    /// later still reaches a scene that is already running.
    first_frame_callback: FirstFrameCallback,
    /// Internal rasterization scale, handed again to every renderer this
    /// runtime opens, whoever asked for the rebuild.
    render_scale: RenderScale,
    /// Runtime media-integration state, preserved across scene reconciliation.
    media_integration_enabled: bool,
    paused: bool,
    window: Option<WallpaperWindow>,
    /// Increments every time the renderer object is rebuilt. The renderer's
    /// counters live and die with that object, so two wallpapers that reused
    /// one display and one handle must not have their counts merged.
    generation: u64,
    /// Stands in for the renderer's own count of presented frames, which a
    /// test scene's uninitialized renderer cannot give.
    #[cfg(test)]
    pub(crate) presented_for_test: bool,
}

#[derive(Clone)]
pub struct SceneRuntimeState {
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
    /// What has to happen to the scene that runs now (`current`, its stored
    /// descriptor) for it to match `desired`. Only the wallpaper-defining
    /// fields and the display decide; the pause seed never does.
    pub fn from_transition(current: Option<&SceneDesc>, desired: &SceneDesc) -> Self {
        let Some(current) = current else {
            return Self::OpenRuntime;
        };
        if !current.same_wallpaper(desired) {
            return Self::RebuildExistingRuntime;
        }
        if current.display == desired.display {
            Self::Unchanged
        } else if current.display.has_same_render_surface(&desired.display) {
            Self::UpdateWindowOnly
        } else {
            Self::ReopenRuntime
        }
    }

    pub fn is_required(self) -> bool {
        self != Self::Unchanged
    }
}

/// The renderer object of a scene together with the four relays that carry its
/// reports to the engine thread. Everything in it is released by dropping it,
/// which is what undoes a half-finished open.
struct OpenedRenderer {
    renderer: OweScene,
    pointer_relay: PointerInputRelay,
    shortcut_relay: UserShortcutRelay,
    audio_relay: AudioRequirementRelay,
    failure_relay: RenderFailureRelay,
}

impl OpenedRenderer {
    /// Opens a renderer on `layer` and brings it to the state the scene has:
    /// the descriptor's values are applied by the open, then only what the
    /// state does differently, then the render scale in force. Pause, volume
    /// and mute are the state's from the open on: the scene's sounds play as
    /// soon as it loads, before a correction sent after the open is read.
    #[allow(clippy::too_many_arguments)]
    fn open(
        backend: OweBackend,
        first_frame_callback: &FirstFrameCallback,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: &SceneRuntimeState,
        render_scale: RenderScale,
        layer: *mut std::ffi::c_void,
        actor: &WeakActorRef<EngineActor>,
    ) -> Result<Self, EngineError> {
        let mut desc = desc.clone();
        desc.paused = state.paused;
        desc.audio_volume = state.audio_volume;
        desc.audio_muted = state.audio_muted;
        let desc = &desc;
        let (pointer_relay, on_pointer_input) = PointerInputRelay::new(actor.clone(), handle)?;
        let (shortcut_relay, on_user_shortcut) = UserShortcutRelay::new(actor.clone(), handle)?;
        let (audio_relay, on_audio_requirement) =
            AudioRequirementRelay::new(actor.clone(), handle)?;
        let (failure_relay, on_render_failure) = RenderFailureRelay::new(actor.clone(), handle)?;
        let on_first_frame: crate::owe::backend::FirstFrameCallback = {
            let callback = Arc::clone(first_frame_callback);
            Arc::new(move || callback(handle))
        };
        let mut renderer = backend.open_scene(
            desc,
            layer,
            state.scaling_mode,
            state.scaling_factor,
            state.framing,
            state.render_resolution,
            Some(on_first_frame),
            Some(on_pointer_input),
            Some(on_user_shortcut),
            Some(on_audio_requirement),
            Some(on_render_failure),
        )?;
        {
            let _scope = LoadScope::enter(renderer.load_id());
            catch_up_with_state(&mut renderer, desc, state)?;
            render_scale.restore(|scale| renderer.set_render_scale(scale))?;
        }
        Ok(Self { renderer, pointer_relay, shortcut_relay, audio_relay, failure_relay })
    }
}

/// Calls `send` with the live value when it is not the one the renderer was
/// opened with; equal values cost the renderer nothing.
fn send_if_changed<T: PartialEq + Copy>(
    live: T,
    opened_with: T,
    send: impl FnOnce(T) -> Result<(), EngineError>,
) -> Result<(), EngineError> {
    if live == opened_with { Ok(()) } else { send(live) }
}

/// What a renderer opened with `opened_with` as its override must be given so
/// that it shows `live`: nothing when they agree, otherwise the live document
/// (`Some(Some(..))`) or the removal of the opened one (`Some(None)`).
fn override_correction<'a>(
    live: Option<&'a str>,
    opened_with: Option<&str>,
) -> Option<Option<&'a str>> {
    (live != opened_with).then_some(live)
}

/// Brings a freshly opened renderer from what its descriptor produced to the
/// carried state. Scaling mode, factor and framing are not handled here: the
/// open took them from the state already.
fn catch_up_with_state(
    renderer: &mut OweScene,
    desc: &SceneDesc,
    state: &SceneRuntimeState,
) -> Result<(), EngineError> {
    let base = SceneRuntimeState::try_from(desc)?;
    send_if_changed(state.paused, base.paused, |v| renderer.set_paused(v))?;
    send_if_changed(state.audio_response_enabled, base.audio_response_enabled, |v| {
        renderer.set_audio_response_enabled(v)
    })?;
    send_if_changed(state.media_integration_enabled, base.media_integration_enabled, |v| {
        renderer.set_media_integration_enabled(v)
    })?;
    send_if_changed(state.audio_volume, base.audio_volume, |v| renderer.set_audio_volume(v))?;
    send_if_changed(state.audio_muted, base.audio_muted, |v| renderer.set_audio_muted(v))?;
    match override_correction(
        state.property_override_json.as_deref(),
        base.property_override_json.as_deref(),
    ) {
        Some(Some(document)) => renderer.set_property_override(document),
        Some(None) => renderer.reset_property_override(),
        None => Ok(()),
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

// All surface stages are statically dispatched; no trait object, stored hook,
// allocation or per-frame work is introduced. Native release is destructive:
// a failed later stage promises metadata preservation, NOT surface rollback.
trait SurfaceReconfigure {
    type Layer;
    fn begin(&mut self) -> Result<(), EngineError>;
    fn layer(&mut self, display: &DisplayDesc) -> Result<Self::Layer, EngineError>;
    fn finish(&mut self, layer: Self::Layer, display: &DisplayDesc, render: (u32, u32)) -> Result<(), EngineError>;
    fn pause(&mut self) -> Result<(), EngineError>;
    fn commit(&mut self, display: DisplayDesc);
}

fn reconfigure_sequence(
    surface: &mut impl SurfaceReconfigure,
    display: DisplayDesc,
    resolution: Option<(u32, u32)>,
    paused: bool,
) -> Result<(), EngineError> {
    surface.begin()?;
    let layer = surface.layer(&display)?;
    surface.finish(layer, &display, resolution.unwrap_or((display.width, display.height)))?;
    if paused { surface.pause()?; }
    surface.commit(display);
    Ok(())
}

struct NativeSurfaceReconfigure<'a> {
    renderer: &'a mut OweScene,
    window: &'a mut WallpaperWindow,
    desc: &'a mut SceneDesc,
    started: Instant,
}

impl SurfaceReconfigure for NativeSurfaceReconfigure<'_> {
    type Layer = *mut std::ffi::c_void;
    fn begin(&mut self) -> Result<(), EngineError> { self.renderer.begin_surface_reconfigure() }
    fn layer(&mut self, display: &DisplayDesc) -> Result<Self::Layer, EngineError> {
        self.window.update_layer(display.clone())
    }
    fn finish(&mut self, layer: Self::Layer, display: &DisplayDesc, render: (u32, u32)) -> Result<(), EngineError> {
        self.renderer.finish_surface_reconfigure(layer, display.width, display.height, render.0, render.1, display.scale_factor)
    }
    fn pause(&mut self) -> Result<(), EngineError> { self.renderer.set_paused(true) }
    fn commit(&mut self, display: DisplayDesc) {
        self.renderer.update_runtime_display(display.display_id);
        log::debug!("[wallpaper-core display] reconfigured surface in place in {:?}: before=[{}] after=[{}]", self.started.elapsed(), self.desc.display.desc_label(), display.desc_label());
        self.desc.display = display;
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
        Self::open_in_registry_with(&SceneRegistry::shared(), || {
            Self::prepare_open(backend, first_frame_callback, handle, desc, state, actor)
        })
    }

    fn prepare_open(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: SceneRuntimeState,
        actor: WeakActorRef<EngineActor>,
    ) -> Result<Self, EngineError> {
        // The window comes first, then the relays and the renderer. Anything
        // that fails afterwards drops what was built, which closes the window,
        // stops the relays and shuts the half-built renderer down.
        let window = WallpaperWindow::builder(desc.display.clone()).open()?;
        let opened = OpenedRenderer::open(
            backend,
            &first_frame_callback,
            handle,
            desc,
            &state,
            RenderScale(RenderScale::NATIVE),
            window.metal_layer_ptr(),
            &actor,
        )?;
        Ok(Self::assemble(Some(window), opened, handle, desc, &state, first_frame_callback, actor, 1))
    }

    fn open_in_registry_with(
        registry: &SceneRegistry,
        prepare: impl FnOnce() -> Result<Self, EngineError>,
    ) -> Result<Self, EngineError> {
        let mut runtime = prepare()?;
        runtime.renderer.publish_runtime_state(registry, runtime.handle.raw(), runtime.desc.display.display_id);
        Ok(runtime)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_replacement(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: SceneRuntimeState,
        actor: WeakActorRef<EngineActor>,
        previous: &mut Self,
    ) -> Result<Self, EngineError> {
        Self::open_replacement_with(previous,
            || Self::prepare_open(backend, first_frame_callback, handle, desc, state, actor),
            |renderer, scale| renderer.set_render_scale(scale))
    }

    fn open_replacement_with(
        previous: &mut Self,
        prepare: impl FnOnce() -> Result<Self, EngineError>,
        restore_scale: impl FnOnce(&mut OweScene, f64) -> Result<(), EngineError>,
    ) -> Result<Self, EngineError> {
        // Readiness first. The candidate has no withdrawal ownership until
        // continue_from transfers the old registration under the same handle.
        // In particular, a failed scale restoration cannot touch the old row.
        let mut candidate = prepare()?;
        candidate.continue_from_with(previous, restore_scale)?;
        Ok(candidate)
    }

    /// Puts a scene together from an opened renderer. The stored descriptor is
    /// the one given, with the one-shot shader refresh used up.
    #[allow(clippy::too_many_arguments)]
    fn assemble(
        window: Option<WallpaperWindow>,
        opened: OpenedRenderer,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: &SceneRuntimeState,
        first_frame_callback: FirstFrameCallback,
        actor: WeakActorRef<EngineActor>,
        generation: u64,
    ) -> Self {
        let OpenedRenderer { renderer, pointer_relay, shortcut_relay, audio_relay, failure_relay } =
            opened;
        let mut stored = desc.clone();
        stored.mark_shader_refresh_complete();
        let pointer_input = NativePointerInputState::new(pointer_relay.renderer_instance.clone());
        Self {
            last_media: None,
            desc: stored,
            handle,
            renderer,
            actor,
            pointer_relay,
            shortcut_relay,
            audio_relay,
            failure_relay,
            surface_recovery: SurfaceRecovery::default(),
            requires_audio: false,
            pointer_input,
            framing: state.framing,
            scaling_mode: state.scaling_mode,
            scaling_factor: state.scaling_factor,
            render_resolution: state.render_resolution,
            audio_response_enabled: state.audio_response_enabled,
            audio_volume: state.audio_volume,
            audio_muted: state.audio_muted,
            property_override_json: state.property_override_json.clone(),
            first_frame_callback,
            render_scale: RenderScale(RenderScale::NATIVE),
            media_integration_enabled: state.media_integration_enabled,
            paused: state.paused,
            window,
            generation,
            #[cfg(test)]
            presented_for_test: false,
        }
    }

    /// Takes over the values a scene keeps beyond its renderer.
    fn apply_state(&mut self, state: SceneRuntimeState) {
        self.scaling_mode = state.scaling_mode;
        self.scaling_factor = state.scaling_factor;
        self.framing = state.framing;
        self.render_resolution = state.render_resolution;
        self.audio_response_enabled = state.audio_response_enabled;
        self.media_integration_enabled = state.media_integration_enabled;
        self.paused = state.paused;
        self.audio_volume = state.audio_volume;
        self.audio_muted = state.audio_muted;
        self.property_override_json = state.property_override_json;
    }

    /// For a scene opened in a new window to take the place of `previous`
    /// after an in-place reconfigure failed: it keeps counting renderer
    /// generations for the handle, is handed the render scale in force (which
    /// only the old scene object knew) and takes over the registry entry, so
    /// closing the old scene cannot withdraw it. Nothing is taken over when
    /// the scale is refused.
    #[allow(dead_code)]
    pub fn continue_from(&mut self, previous: &mut SceneRuntime) -> Result<(), EngineError> {
        self.continue_from_with(previous, |renderer, scale| renderer.set_render_scale(scale))
    }

    fn continue_from_with(
        &mut self,
        previous: &mut Self,
        restore_scale: impl FnOnce(&mut OweScene, f64) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        previous.render_scale.restore(|scale| restore_scale(&mut self.renderer, scale))?;
        self.render_scale = previous.render_scale;
        self.generation = previous.generation.saturating_add(1);
        self.renderer
            .inherit_runtime_registration(&mut previous.renderer, self.desc.display.display_id);
        Ok(())
    }

    /// Replaces the renderer by one opened for `desc`, in the same window.
    ///
    /// A fresh layer goes under the view first, because the renderer still
    /// drawing on the old one would contend for its drawables. The carried
    /// state is the one of R78 to R80, the render scale in force is handed to
    /// the new renderer, and the old renderer is closed only once the new one
    /// exists and has taken over the scene's registry entry. Any failure
    /// leaves this scene exactly as it was, previous layer back in view.
    fn rebuild_for_desc(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
        render_resolution: Option<(u32, u32)>,
    ) -> Result<(), EngineError> {
        let mut state = self.runtime_state();
        state.inherit_descriptor_transition(&self.desc, desc)?;
        state.render_resolution = render_resolution;
        let Some(window) = self.window.as_mut() else {
            return Err(EngineError::Platform("wallpaper window is already closed".to_string()));
        };
        let swap = window.begin_layer_swap(desc.display.clone(), LayerInstall::Replace)?;
        let opened = match OpenedRenderer::open(
            backend,
            &self.first_frame_callback,
            self.handle,
            desc,
            &state,
            self.render_scale,
            swap.layer_ptr(),
            &self.actor,
        ) {
            Ok(opened) => opened,
            Err(error) => {
                restore_previous_layer(window, swap, &error);
                return Err(error);
            }
        };

        let OpenedRenderer { renderer, pointer_relay, shortcut_relay, audio_relay, failure_relay } =
            opened;
        let mut replaced = std::mem::replace(&mut self.renderer, renderer);
        self.renderer.inherit_runtime_registration(&mut replaced, desc.display.display_id);
        swap.finish();
        self.pointer_input = NativePointerInputState::new(pointer_relay.renderer_instance.clone());
        self.pointer_relay = pointer_relay;
        self.shortcut_relay = shortcut_relay;
        self.audio_relay = audio_relay;
        self.failure_relay = failure_relay;
        self.requires_audio = false;
        self.last_media = None;
        self.surface_recovery = SurfaceRecovery::default();
        self.generation = self.generation.saturating_add(1);
        self.apply_state(state);
        self.desc = desc.clone();
        self.desc.mark_shader_refresh_complete();
        if let Err(error) = replaced.close() {
            log::warn!("[wallpaper-core display] failed to close replaced display runtime: {error}");
        }
        Ok(())
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

    /// The mapping from the cursor to the scene changes with the scaling, so
    /// pointer delivery restarts before the renderer is asked.
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

    /// Tells the renderer even when the value is unchanged. Pointer delivery
    /// restarts only when the pause actually changed, so a resumed scene is
    /// sampled afresh.
    pub fn set_paused(&mut self, paused: bool) -> Result<(), EngineError> {
        self.renderer.set_paused(paused)?;
        if self.paused != paused {
            self.pointer_input.delivery.invalidate();
        }
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
        let desc = self.desc.clone();
        self.rebuild_for_desc(backend, &desc, Some((width, height)))
    }

    pub fn replace_wallpaper(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        self.rebuild_for_desc(backend, desc, self.render_resolution)
    }

    /// Moves or re-fits the window for a display whose render surface is the
    /// same. The renderer, the layer and the drawable are left alone, so a
    /// wake does not expose the placeholder before the renderer can present.
    pub fn update_window_display(&mut self, display: DisplayDesc) -> Result<(), EngineError> {
        self.update_window_display_with(display, |window, display| {
            let Some(window) = window.as_mut() else {
                return Err(EngineError::Platform(
                    "scene runtime has no window during display update".to_string(),
                ));
            };
            window.update_display(display.clone())
        })
    }

    fn update_window_display_with(
        &mut self,
        display: DisplayDesc,
        move_window: impl FnOnce(&mut Option<WallpaperWindow>, &DisplayDesc) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        move_window(&mut self.window, &display)?;
        self.pointer_input.delivery.invalidate();
        self.renderer.update_runtime_display(display.display_id);
        log::debug!(
            "[wallpaper-core display] moved window in place: before=[{}] after=[{}]",
            self.desc.display.desc_label(),
            display.desc_label()
        );
        self.desc.display = display;
        Ok(())
    }

    pub fn reconfigure_for_display(
        &mut self,
        backend: OweBackend,
        display: DisplayDesc,
    ) -> Result<(), EngineError> {
        let _ = backend;
        let started = std::time::Instant::now();
        let Some(window) = self.window.as_mut() else {
            return Err(EngineError::Platform(
                "scene runtime has no window during reconfigure".to_string(),
            ));
        };
        self.pointer_input.delivery.invalidate();
        reconfigure_sequence(&mut NativeSurfaceReconfigure {
            renderer: &mut self.renderer,
            window,
            desc: &mut self.desc,
            started,
        }, display, self.render_resolution, self.paused)
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

    /// The window server's number for this scene's window; `None` without one.
    pub fn window_number(&self) -> Option<isize> {
        self.window.as_ref().and_then(WallpaperWindow::window_number)
    }

    /// Whether the scene's current renderer has put a frame on screen and has
    /// not stopped on a failure since: a scene kept paused for a desktop shows
    /// that frame until it runs again, and one that has none would show black.
    pub fn has_presented(&self) -> bool {
        #[cfg(test)]
        if self.presented_for_test {
            return true;
        }
        self.surface_health()
            .is_some_and(|health| health.frames_presented > 0 && health.stop.is_none())
    }

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
        // The renderer drops its record of a previewed document whatever comes
        // of the rest, and loads the scene again with the document merged over
        // the project's authored defaults (or with those alone).
        match flat_json.as_deref() {
            Some(json) => self.renderer.set_property_override(json)?,
            None => self.renderer.reset_property_override()?,
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

    /// Stops the relays, closes the renderer, then closes and releases the
    /// window. The renderer's own error is returned after the window is gone.
    /// Closing again is harmless.
    pub fn close(&mut self) -> Result<(), EngineError> {
        self.pointer_relay.stop();
        self.shortcut_relay.stop();
        self.audio_relay.stop();
        self.failure_relay.stop();
        self.requires_audio = false;
        let renderer = self.renderer.close();
        if let Some(mut window) = self.window.take() {
            window.close();
        }
        renderer
    }

    /// The live state a successor scene on the same slot inherits.
    #[must_use]
    pub fn runtime_state(&self) -> SceneRuntimeState {
        let Self {
            scaling_mode,
            scaling_factor,
            framing,
            render_resolution,
            audio_response_enabled,
            media_integration_enabled,
            paused,
            audio_volume,
            audio_muted,
            property_override_json,
            ..
        } = self;
        SceneRuntimeState {
            scaling_mode: *scaling_mode,
            scaling_factor: *scaling_factor,
            framing: *framing,
            render_resolution: *render_resolution,
            audio_response_enabled: *audio_response_enabled,
            media_integration_enabled: *media_integration_enabled,
            paused: *paused,
            audio_volume: *audio_volume,
            audio_muted: *audio_muted,
            property_override_json: property_override_json.clone(),
        }
    }

    /// The state a scene for `desc` takes over from this one.
    pub(crate) fn runtime_state_for_desc(
        &self,
        desc: &SceneDesc,
    ) -> Result<SceneRuntimeState, EngineError> {
        let mut state = self.runtime_state();
        state.inherit_descriptor_transition(&self.desc, desc)?;
        Ok(state)
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

#[cfg(test)]
impl SceneRuntime {
    /// A scene that owns no window and drives an uninitialized renderer, for
    /// tests that need a live scene on a slot. Must be called inside a tokio
    /// runtime, like every relay.
    pub(crate) fn windowless_for_test(
        handle: SceneHandle,
        desc: &SceneDesc,
        state: &SceneRuntimeState,
        actor: WeakActorRef<EngineActor>,
    ) -> Result<Self, EngineError> {
        let (pointer_relay, _) = PointerInputRelay::new(actor.clone(), handle)?;
        let (shortcut_relay, _) = UserShortcutRelay::new(actor.clone(), handle)?;
        let (audio_relay, _) = AudioRequirementRelay::new(actor.clone(), handle)?;
        let (failure_relay, _) = RenderFailureRelay::new(actor.clone(), handle)?;
        let opened = OpenedRenderer {
            renderer: OweScene::uninitialized_for_test(),
            pointer_relay,
            shortcut_relay,
            audio_relay,
            failure_relay,
        };
        Ok(Self::assemble(None, opened, handle, desc, state, Arc::new(|_| {}), actor, 1))
    }
}

impl Drop for SceneRuntime {
    fn drop(&mut self) {
        // A scene that is dropped still closes, and a drop never panics.
        let closed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = self.close();
        }));
        if closed.is_err() {
            log::warn!("[wallpaper-core display] closing a dropped scene panicked");
        }
    }
}

impl SceneRuntimeState {
    /// Carries this state, which belongs to a scene running `current_desc`,
    /// over to a scene for `next_desc`. The same wallpaper keeps every live
    /// value; another one takes the descriptor's scaling, framing and audio
    /// and media flags, while pause and the explicit render resolution stay.
    /// The property override follows one rule for both.
    pub(crate) fn inherit_descriptor_transition(
        &mut self,
        current_desc: &SceneDesc,
        next_desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        let before = Self::try_from(current_desc)?;
        let after = Self::try_from(next_desc)?;
        // An override nobody touched since the running descriptor made it
        // moves on with the descriptors; an explicit one (a reset too) stays.
        let live_override = self.property_override_json.take();
        let override_json = if live_override == before.property_override_json {
            after.property_override_json.clone()
        } else {
            live_override
        };
        if current_desc.same_wallpaper(next_desc) {
            self.property_override_json = override_json;
        } else {
            *self = Self {
                paused: self.paused,
                render_resolution: self.render_resolution,
                property_override_json: override_json,
                ..after
            };
        }
        Ok(())
    }
}

impl TryFrom<&SceneDesc> for SceneRuntimeState {
    type Error = EngineError;

    fn try_from(desc: &SceneDesc) -> Result<Self, Self::Error> {
        let property_override_json = desc
            .property_override_json
            .as_deref()
            .map(super::flat_property_document)
            .transpose()?;
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
            property_override_json,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::window::MouseButtonTracker;
    use kameo::actor::Spawn;

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
        // CLEANROOM ET48: the seed is used only for a fresh state.
        let mut desc = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        for paused in [true, false] {
            desc.paused = paused;
            assert_eq!(SceneRuntimeState::try_from(&desc).unwrap().paused, paused);
        }
    }

    #[test]
    fn override_correction_says_nothing_when_both_have_no_override() {
        assert_eq!(override_correction(None, None), None);
    }

    #[test]
    fn override_correction_says_nothing_when_the_documents_agree() {
        assert_eq!(override_correction(Some(r#"{"a":1}"#), Some(r#"{"a":1}"#)), None);
    }

    #[test]
    fn override_correction_removes_only_an_override_the_descriptor_supplied() {
        assert_eq!(override_correction(None, Some(r#"{"enabled":true}"#)), Some(None));
    }

    #[test]
    fn override_correction_applies_a_runtime_document_that_differs() {
        assert_eq!(
            override_correction(Some(r#"{"enabled":false}"#), Some(r#"{"enabled":true}"#)),
            Some(Some(r#"{"enabled":false}"#))
        );
        assert_eq!(
            override_correction(Some(r#"{"enabled":false}"#), None),
            Some(Some(r#"{"enabled":false}"#))
        );
    }

    #[test]
    fn a_value_is_sent_to_the_renderer_only_when_it_differs_from_the_opened_one() {
        let mut sent = Vec::new();
        send_if_changed(3, 3, |v| {
            sent.push(v);
            Ok(())
        })
        .expect("nothing to send");
        send_if_changed(4, 3, |v| {
            sent.push(v);
            Ok(())
        })
        .expect("sent");
        assert_eq!(sent, vec![4]);

        let failure = send_if_changed(true, false, |_| Err(EngineError::Platform("gone".into())));
        assert!(failure.is_err(), "a renderer error reaches the open");
    }

    fn scene_with_override(path: &str, document: Option<&str>) -> SceneDesc {
        let mut desc = framed_scene(path, SceneFraming::default());
        desc.property_override_json = document.map(ToOwned::to_owned);
        desc
    }

    #[test]
    fn descriptor_property_override_change_is_not_reset_when_runtime_matches_current_descriptor() {
        // CLEANROOM ET49
        let current = scene_with_override("/virtual/orchid/scene.json", Some(r#"{"tint":0.28}"#));
        let next = scene_with_override("/virtual/orchid/scene.json", Some(r#"{"lighting":{"gain":0.72},"caption":null}"#));
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.inherit_descriptor_transition(&current, &next).unwrap();
        let expected = super::super::flat_property_document(next.property_override_json.as_deref().unwrap()).unwrap();
        assert_eq!(state.property_override_json.as_deref(), Some(expected.as_str()));
        assert_eq!(override_correction(state.property_override_json.as_deref(), Some(&expected)), None);
    }

    #[test]
    fn explicit_runtime_property_reset_still_overrides_descriptor_refresh() {
        // CLEANROOM ET50
        let current = scene_with_override("/virtual/orchid/scene.json", Some(r#"{"tint":0.28}"#));
        for path in [current.scene_path.as_str(), "/virtual/cobalt/scene.json"] {
            let next = scene_with_override(path, Some(r#"{"tint":0.91}"#));
            let mut state = SceneRuntimeState::try_from(&current).unwrap();
            state.property_override_json = None;
            state.inherit_descriptor_transition(&current, &next).unwrap();
            assert_eq!(state.property_override_json, None);
            let base = SceneRuntimeState::try_from(&next).unwrap();
            assert_eq!(override_correction(state.property_override_json.as_deref(), base.property_override_json.as_deref()), Some(None));
        }
    }

    #[test]
    fn an_explicit_runtime_override_survives_a_wallpaper_change() {
        let current_desc = scene_with_override("/tmp/a/project.json", None);
        let next_desc = scene_with_override("/tmp/b/project.json", Some(r#"{"x":1}"#));
        let mut state = SceneRuntimeState::try_from(&current_desc).expect("state");
        state.property_override_json = Some(r#"{"x":9}"#.to_owned());

        state.inherit_descriptor_transition(&current_desc, &next_desc).expect("transition");

        assert_eq!(state.property_override_json.as_deref(), Some(r#"{"x":9}"#));
    }

    #[test]
    fn different_wallpaper_rebuild_uses_next_descriptor_render_defaults() {
        // CLEANROOM ET51
        let current = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        let mut next = framed_scene("/virtual/cobalt/scene.json", SceneFraming { pan_x: 0.82, pan_y: 0.19 });
        next.scaling_mode = ScalingMode::Stretch;
        next.scaling_factor = 0.85;
        next.audio_response_enabled = true;
        next.media_integration_enabled = true;
        next.audio_volume = AudioVolume::try_from(0.43).unwrap();
        next.audio_muted = true;
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.paused = true;
        state.render_resolution = Some((824, 472));
        state.inherit_descriptor_transition(&current, &next).unwrap();
        assert_eq!(state.scaling_mode, next.scaling_mode);
        assert_eq!(state.scaling_factor, next.scaling_factor);
        assert_eq!(state.framing, next.framing);
        assert_eq!(state.audio_response_enabled, next.audio_response_enabled);
        assert_eq!(state.media_integration_enabled, next.media_integration_enabled);
        assert_eq!(state.audio_volume, next.audio_volume);
        assert_eq!(state.audio_muted, next.audio_muted);
        assert!(state.paused);
        assert_eq!(state.render_resolution, Some((824, 472)));
    }

    #[test]
    fn live_runtime_transition_state_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        // CLEANROOM ET52: use the live-runtime route, not only seeding.
        tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap().block_on(async {
            let current = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
            let mut next = current.clone();
            next.scene_path = "/virtual/cobalt/scene.json".into();
            next.scaling_mode = ScalingMode::Fit;
            next.scaling_factor = 0.85;
            let mut state = SceneRuntimeState::try_from(&current).unwrap();
            state.scaling_mode = ScalingMode::Fill;
            state.scaling_factor = 1.7;
            let prepared = EngineActor::prepare();
            let live = SceneRuntime::windowless_for_test(SceneHandle::new(41), &current, &state, prepared.actor_ref().downgrade()).unwrap();
            let selected = live.runtime_state_for_desc(&next).unwrap();
            assert_eq!(selected.scaling_mode, ScalingMode::Fit);
            assert_eq!(selected.scaling_factor, 0.85);
        });
    }

    #[test]
    fn same_wallpaper_rebuild_preserves_explicit_runtime_render_overrides() {
        // CLEANROOM ET53: every carried field differs from its descriptor.
        let current = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.scaling_mode = ScalingMode::Stretch;
        state.scaling_factor = 1.65;
        state.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
        state.render_resolution = Some((824, 472));
        state.audio_response_enabled = !current.audio_response_enabled;
        state.media_integration_enabled = !current.media_integration_enabled;
        state.audio_volume = AudioVolume::try_from(0.43).unwrap();
        state.audio_muted = !current.audio_muted;
        state.paused = !current.paused;
        state.property_override_json = Some(r#"{"caption":"live"}"#.into());
        let saved = state.clone();
        let mut next = current.clone();
        next.display.width += 128;
        state.inherit_descriptor_transition(&current, &next).unwrap();
        assert_eq!(state.scaling_mode, saved.scaling_mode);
        assert_eq!(state.scaling_factor, saved.scaling_factor);
        assert_eq!(state.framing, saved.framing);
        assert_eq!(state.render_resolution, saved.render_resolution);
        assert_eq!(state.audio_response_enabled, saved.audio_response_enabled);
        assert_eq!(state.media_integration_enabled, saved.media_integration_enabled);
        assert_eq!(state.audio_volume, saved.audio_volume);
        assert_eq!(state.audio_muted, saved.audio_muted);
        assert_eq!(state.paused, saved.paused);
        assert_eq!(state.property_override_json, saved.property_override_json);
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
        // CLEANROOM ET54
        let current = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        let mut next = current.clone();
        next.display.display_id = 203;
        next.paused = !current.paused;
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
        state.inherit_descriptor_transition(&current, &next).unwrap();
        assert_eq!(state.framing, SceneFraming { pan_x: 0.37, pan_y: 0.64 });
        assert_eq!(state.paused, current.paused);
    }

    #[test]
    fn different_wallpaper_transition_takes_the_next_descriptors_framing() {
        // CLEANROOM ET55
        let current = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        let next = framed_scene("/virtual/cobalt/scene.json", SceneFraming { pan_x: 0.82, pan_y: 0.19 });
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
        state.inherit_descriptor_transition(&current, &next).unwrap();
        assert_eq!(state.framing, next.framing);
    }

    #[test]
    fn a_different_wallpaper_with_an_equal_framing_drops_the_dragged_position() {
        // CLEANROOM ET56
        let requested = SceneFraming { pan_x: 0.46, pan_y: 0.58 };
        let current = framed_scene("/virtual/orchid/scene.json", requested);
        let next = framed_scene("/virtual/cobalt/scene.json", requested);
        let mut state = SceneRuntimeState::try_from(&current).unwrap();
        state.framing = SceneFraming { pan_x: 0.73, pan_y: 0.24 };
        state.inherit_descriptor_transition(&current, &next).unwrap();
        assert_eq!(state.framing, requested);
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
        let mut state = cleanroom_et57(None);
        state.paused = true;

        assert!(state.paused);
    }

    #[test]
    fn running_runtime_does_not_require_pause_restore_after_surface_reconfigure() {
        let state = cleanroom_et57(None);

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

    fn cleanroom_et57(document: Option<&str>) -> SceneRuntimeState {
        // CLEANROOM ET57: independent descriptor seed for the retained tests.
        SceneRuntimeState::try_from(&scene_with_override("/virtual/orchid/scene.json", document)).unwrap()
    }

    fn candidate(display_id: u32, paused: bool) -> SceneRuntime {
        let (prepared, _) = prepared_empty_actor();
        let mut desc = framed_scene("/virtual/orchid/scene.json", SceneFraming::CENTERED);
        desc.display.display_id = display_id;
        desc.paused = paused;
        SceneRuntime::windowless_for_test(SceneHandle::new(73), &desc, &SceneRuntimeState::try_from(&desc).unwrap(), prepared.actor_ref().downgrade()).unwrap()
    }

    fn rows(registry: &SceneRegistry) -> Vec<(u64, u32)> {
        registry.reports().iter().map(|r| (r.handle, r.display_id)).collect()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn window_only_move_preserves_renderer_generation_and_first_frame_callback() {
        let registry = SceneRegistry::new();
        let mut scene = candidate(87, false);
        scene.renderer.publish_runtime_state(&registry, 73, 87);
        let original = scene.desc.clone();
        let token = scene.renderer_instance();
        let presentations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = presentations.clone();
        scene.first_frame_callback = Arc::new(move |_| { seen.fetch_add(1, std::sync::atomic::Ordering::Relaxed); });
        let mut display = original.display.clone();
        display.x = 101;
        display.y = -209;
        display.display_id = 203;
        let mut attempted = Vec::new();
        scene.update_window_display_with(display.clone(), |_, desired| {
            attempted.push(desired.clone());
            Ok(())
        }).unwrap();
        assert_eq!(attempted, vec![display.clone()]);
        assert_eq!(scene.desc.display, display);
        assert!(Arc::ptr_eq(&token, &scene.renderer_instance()));
        assert_eq!(scene.generation, 1);
        assert_eq!(presentations.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(rows(&registry), vec![(73, 203)]);
        let before_failure = scene.desc.clone();
        let error = scene.update_window_display_with(original.display, |_, _| Err(EngineError::Platform("move refused".into()))).unwrap_err();
        assert!(matches!(error, EngineError::Platform(text) if text == "move refused"));
        assert_eq!(scene.desc, before_failure);
        assert!(Arc::ptr_eq(&token, &scene.renderer_instance()));
        assert_eq!(rows(&registry), vec![(73, 203)]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn refused_fallback_scale_never_takes_or_withdraws_the_old_registration() {
        let registry = SceneRegistry::new();
        let mut old = candidate(87, true);
        old.renderer.publish_runtime_state(&registry, old.handle.raw(), 87);
        old.render_scale.set(0.43, |_| Ok(())).unwrap();
        old.generation = 8;
        let old_desc = old.desc.clone();
        let mut observed_during_restore = Vec::new();
        let result = SceneRuntime::open_replacement_with(&mut old, || Ok(candidate(203, true)), |_, scale| {
            assert_eq!(scale, 0.43);
            observed_during_restore = rows(&registry);
            Err(EngineError::Render("refused fallback scale".into()))
        });
        assert!(matches!(result, Err(EngineError::Render(text)) if text == "refused fallback scale"));
        assert_eq!(observed_during_restore, vec![(73, 87)], "candidate must remain unpublished through fallible restoration");
        assert_eq!(rows(&registry), vec![(73, 87)], "failed candidate drop must not withdraw the old row");
        assert_eq!(old.desc, old_desc);
        assert_eq!(old.generation, 8);
        assert_eq!(old.render_scale.0, 0.43);
        old.close().unwrap();
        assert!(rows(&registry).is_empty());
        old.close().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ready_fallback_hands_off_same_handle_before_old_close_and_drop() {
        let registry = SceneRegistry::new();
        let mut old = candidate(87, true);
        old.renderer.publish_runtime_state(&registry, 73, 87);
        old.render_scale.set(0.43, |_| Ok(())).unwrap();
        old.generation = 8;
        let mut received = None;
        let mut new = SceneRuntime::open_replacement_with(&mut old, || Ok(candidate(203, true)), |_, scale| {
            received = Some(scale);
            assert_eq!(rows(&registry), vec![(73, 87)]);
            Ok(())
        }).unwrap();
        assert_eq!(received, Some(0.43));
        assert_eq!(new.render_scale.0, 0.43);
        assert_eq!(new.generation, 9);
        assert!(new.paused);
        assert_eq!(rows(&registry), vec![(73, 203)]);
        old.close().unwrap();
        drop(old);
        assert_eq!(rows(&registry), vec![(73, 203)]);
        new.close().unwrap();
        assert!(rows(&registry).is_empty());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn failed_carried_state_candidate_preparation_keeps_the_old_registry_row() {
        let registry = SceneRegistry::new();
        let mut old = candidate(87, false);
        old.renderer.publish_runtime_state(&registry, 73, 87);
        let result = SceneRuntime::open_replacement_with(&mut old, || {
            let mut candidate = candidate(203, false);
            let mut invalid = candidate.desc.clone();
            invalid.property_override_json = Some(r#"{"not_a_leaf":[]}"#.into());
            let state = candidate.runtime_state();
            catch_up_with_state(&mut candidate.renderer, &invalid, &state)?;
            Ok(candidate)
        }, |_, _| panic!("preparation failed before scale"));
        assert!(matches!(result, Err(EngineError::InvalidInput(_))));
        assert_eq!(rows(&registry), vec![(73, 87)]);
    }

    struct RecordingSurface<'a> {
        scene: &'a mut SceneRuntime,
        fail: Option<&'static str>,
        events: Vec<&'static str>,
        finished: Option<(u32, u32, u32, u32, f64)>,
    }

    impl RecordingSurface<'_> {
        fn stage(&mut self, name: &'static str) -> Result<(), EngineError> {
            self.events.push(name);
            if self.fail == Some(name) { Err(EngineError::Render(format!("refused {name}"))) } else { Ok(()) }
        }
    }

    impl SurfaceReconfigure for RecordingSurface<'_> {
        type Layer = ();
        fn begin(&mut self) -> Result<(), EngineError> { self.stage("begin") }
        fn layer(&mut self, _: &DisplayDesc) -> Result<(), EngineError> { self.stage("layer") }
        fn finish(&mut self, _: (), display: &DisplayDesc, render: (u32, u32)) -> Result<(), EngineError> {
            self.stage("finish")?;
            self.finished = Some((display.width, display.height, render.0, render.1, display.scale_factor));
            Ok(())
        }
        fn pause(&mut self) -> Result<(), EngineError> { self.stage("pause") }
        fn commit(&mut self, display: DisplayDesc) {
            self.events.push("commit");
            self.scene.renderer.update_runtime_display(display.display_id);
            self.scene.desc.display = display;
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn production_surface_sequence_orders_running_and_paused_commits_and_sizes() {
        for paused in [false, true] {
            for explicit in [None, Some((824, 472))] {
                let registry = SceneRegistry::new();
                let mut scene = candidate(87, paused);
                scene.renderer.publish_runtime_state(&registry, 73, 87);
                let display = DisplayDesc::new(203, -613, 137, 2624, 1472, 1.5);
                let mut sequence = RecordingSurface { scene: &mut scene, fail: None, events: Vec::new(), finished: None };
                reconfigure_sequence(&mut sequence, display.clone(), explicit, paused).unwrap();
                assert_eq!(sequence.events, if paused { vec!["begin", "layer", "finish", "pause", "commit"] } else { vec!["begin", "layer", "finish", "commit"] });
                let render = explicit.unwrap_or((2624, 1472));
                assert_eq!(sequence.finished, Some((2624, 1472, render.0, render.1, 1.5)));
                assert_eq!(scene.desc.display, display);
                assert_eq!(scene.paused, paused);
                assert_eq!(rows(&registry), vec![(73, 203)]);
            }
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn every_failed_surface_stage_can_handoff_a_ready_fallback_with_carried_state() {
        for paused in [false, true] {
            for resolution in [None, Some((824, 472))] {
                for failure in ["begin", "layer", "finish", "pause"] {
                    if failure == "pause" && !paused { continue; }
                    let registry = SceneRegistry::new();
                    let mut old = candidate(87, paused);
                    old.render_resolution = resolution;
                    old.render_scale.set(0.43, |_| Ok(())).unwrap();
                    old.generation = 8;
                    old.renderer.publish_runtime_state(&registry, 73, 87);
                    let mut next = old.desc.clone();
                    next.display = DisplayDesc::new(203, 0, 0, 2624, 1472, 1.5);
                    let carried = old.runtime_state_for_desc(&next).unwrap();
                    let mut surface = RecordingSurface { scene: &mut old, fail: Some(failure), events: Vec::new(), finished: None };
                    reconfigure_sequence(&mut surface, next.display.clone(), resolution, paused).unwrap_err();
                    let actor = old.actor.clone();
                    let mut new = SceneRuntime::open_replacement_with(&mut old,
                        || SceneRuntime::windowless_for_test(SceneHandle::new(73), &next, &carried, actor),
                        |_, scale| {
                            assert_eq!(scale, 0.43);
                            assert_eq!(rows(&registry), vec![(73, 87)]);
                            Ok(())
                        }).unwrap();
                    assert_eq!(new.generation, 9);
                    assert_eq!(new.render_resolution, resolution);
                    assert_eq!(new.render_scale.0, 0.43);
                    assert_eq!(new.paused, paused);
                    assert_eq!(rows(&registry), vec![(73, 203)]);
                    old.close().unwrap();
                    drop(old);
                    assert_eq!(rows(&registry), vec![(73, 203)]);
                    new.close().unwrap();
                    assert!(rows(&registry).is_empty());
                }
            }
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn production_surface_failures_stop_before_commit_and_failed_fallback_keeps_ownership() {
        for paused in [false, true] {
            for explicit in [None, Some((824, 472))] {
                for failure in ["begin", "layer", "finish", "pause"] {
                    if failure == "pause" && !paused { continue; }
                    let registry = SceneRegistry::new();
                    let mut scene = candidate(87, paused);
                    scene.render_scale.set(0.43, |_| Ok(())).unwrap();
                    scene.renderer.publish_runtime_state(&registry, 73, 87);
                    let before = scene.desc.clone();
                    let mut surface = RecordingSurface { scene: &mut scene, fail: Some(failure), events: Vec::new(), finished: None };
                    let error = reconfigure_sequence(&mut surface, DisplayDesc::new(203, 0, 0, 2624, 1472, 1.5), explicit, paused).unwrap_err();
                    assert!(matches!(error, EngineError::Render(text) if text == format!("refused {failure}")));
                    let order = ["begin", "layer", "finish", "pause"];
                    let failed_index = order.iter().position(|s| *s == failure).unwrap();
                    assert_eq!(surface.events, order[..=failed_index]);
                    assert_eq!(scene.desc, before);
                    assert_eq!(rows(&registry), vec![(73, 87)]);
                    // The R76 fallback is the production replacement factory.
                    // This models refusal after a potentially destructive release;
                    // preservation asserted here is metadata/ownership, NOT pixels.
                    let result = SceneRuntime::open_replacement_with(&mut scene, || Ok(candidate(203, paused)), |_, _| Err(EngineError::Render("fallback scale refusal".into())));
                    assert!(result.is_err());
                    assert_eq!(scene.desc, before);
                    assert_eq!(rows(&registry), vec![(73, 87)]);
                }
            }
        }
    }
}
