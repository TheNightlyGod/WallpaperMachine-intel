// Clean-room implementation from the WallpaperMachine spec r1a-core-engine.md; written without access to the original source.
use std::{sync::Arc, time::Instant};

use kameo::{
    actor::{ActorRef, Spawn, WeakActorRef},
    message::{Context, Message},
};

#[cfg(test)]
use crate::engine::messages::{DisplayRecordCountForTest, SequenceForTest};
use crate::{
    DisplaySelector, EngineError, WallpaperAssignment,
    display::{
        RefreshPlan, RefreshReportLog, plan_refresh,
        state::{DisplayKey, DisplayStateModel},
    },
    engine::{
        EngineSnapshotPublisher, FirstFrameCallback, PropertyPreview,
        messages::{self, Ping},
        runtime::{RuntimeRefreshJob, RuntimeRefreshMode, SceneRuntime},
        state::{EngineState, ParkedRuntime},
        surface_recovery::{
            Decision, LADDER, RecoveryOutcome, RecoveryReason, RecoveryStep, SETTLE_INTERVAL,
            SETTLE_LIMIT, Settled, WINDOW, is_healthy, settle,
        },
    },
    log_context::LoadScope,
    owe::backend::OweBackend,
    render::RendererSurfaceCounters,
    project::{SceneDesc, SceneDescSliceExt, SceneHandle},
};

#[derive(kameo::Actor)]
pub struct EngineActor {
    #[allow(dead_code)]
    backend: OweBackend,
    first_frame_callback: FirstFrameCallback,
    pub state: EngineState,
    snapshots: Arc<EngineSnapshotPublisher>,
    weak_self: WeakActorRef<EngineActor>,
    #[allow(dead_code)]
    display_callback: Option<()>,
    #[allow(dead_code)]
    refresh_running: bool,
    #[allow(dead_code)]
    refresh_pending: bool,
    refresh_report_log: RefreshReportLog,
    #[cfg(test)]
    pub test_sequence: u64,
    #[cfg(test)]
    fail_next_refresh_displays: bool,
    #[cfg(test)]
    pointer_notifications: Vec<(Arc<()>, bool)>,
    #[cfg(test)]
    render_failure_notifications: Vec<Arc<()>>,
}

/// The private runtime of an engine started with no executor around it. Dropped
/// without waiting, because the last clone of the engine may go away inside
/// someone else's async context, where dropping a runtime would panic.
struct RuntimeOwner(Option<tokio::runtime::Runtime>);

impl Drop for RuntimeOwner {
    fn drop(&mut self) {
        if let Some(runtime) = self.0.take() {
            runtime.shutdown_background();
        }
    }
}

#[derive(Clone)]
pub struct EngineActorHandle {
    #[allow(dead_code)]
    actor: ActorRef<EngineActor>,
    #[allow(dead_code)]
    _runtime: Option<Arc<RuntimeOwner>>,
}

impl EngineActorHandle {
    #[allow(clippy::single_call_fn)]
    pub fn spawn(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        state: EngineState,
        snapshots: Arc<EngineSnapshotPublisher>,
    ) -> Result<Self, EngineError> {
        let prepared = EngineActor::prepare();
        let actor = EngineActor::new(
            backend,
            first_frame_callback,
            state,
            snapshots,
            prepared.actor_ref().downgrade(),
        );
        let actor_ref = prepared.actor_ref().clone();
        // Timers and relay tasks are spawned from the engine thread, so it has
        // to run inside a runtime context.
        match tokio::runtime::Handle::try_current() {
            Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::CurrentThread => {
                // One thread serves everything: the engine is a task on it.
                drop(prepared.spawn(actor));
                Ok(Self { actor: actor_ref, _runtime: None })
            }
            Ok(_) => {
                drop(prepared.spawn_in_thread(actor));
                Ok(Self { actor: actor_ref, _runtime: None })
            }
            Err(_) => {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .thread_name("wallpaper-engine-actor-runtime")
                    .enable_time()
                    .build()
                    .map_err(|error| {
                        EngineError::Platform(format!(
                            "failed to start engine actor runtime: {error}"
                        ))
                    })?;
                {
                    let _entered = runtime.enter();
                    drop(prepared.spawn_in_thread(actor));
                }
                Ok(Self {
                    actor: actor_ref,
                    _runtime: Some(Arc::new(RuntimeOwner(Some(runtime)))),
                })
            }
        }
    }

    pub fn actor(&self) -> &ActorRef<EngineActor> {
        &self.actor
    }
}

#[allow(clippy::single_call_fn)]
impl EngineActor {
    pub fn new(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        state: EngineState,
        snapshots: Arc<EngineSnapshotPublisher>,
        weak_self: WeakActorRef<EngineActor>,
    ) -> Self {
        Self {
            backend,
            first_frame_callback,
            state,
            snapshots,
            weak_self,
            display_callback: None,
            refresh_running: false,
            refresh_pending: false,
            refresh_report_log: RefreshReportLog::default(),
            #[cfg(test)]
            test_sequence: 0,
            #[cfg(test)]
            fail_next_refresh_displays: false,
            #[cfg(test)]
            pointer_notifications: Vec::new(),
            #[cfg(test)]
            render_failure_notifications: Vec::new(),
        }
    }

    pub fn publish_snapshot(&self) {
        self.snapshots.publish(self.state.snapshot());
        // Every state change passes here, so a rebuilt or closed renderer
        // drops out of the set without a path of its own.
        self.snapshots.audio_requirement().publish(self.state.audio_requiring_handles());
        self.signal_pending_pointer_sample();
    }

    /// The sampler waits for input, so a scene whose pointer delivery was
    /// reset without the cursor moving asks for one sample here.
    fn signal_pending_pointer_sample(&self) {
        if self.state.pointer_sample_pending() {
            self.snapshots.signal_pointer_input();
        }
    }

    fn with_snapshot_update<T>(
        &mut self,
        update: impl FnOnce(&mut Self) -> Result<T, EngineError>,
    ) -> Result<T, EngineError> {
        let result = update(self);
        self.publish_snapshot();
        result
    }

    pub fn refresh_displays_now(&mut self) -> Result<(), EngineError> {
        let primary = crate::DisplayDesc::primary()?;
        let all = crate::DisplayDesc::all()?;
        self.apply_display_report(primary, all)
    }

    /// The display model as the slots hold it now.
    fn display_model(&self) -> DisplayStateModel {
        DisplayStateModel {
            records: self.state.display_records.iter().map(|record| record.model.clone()).collect(),
        }
    }

    /// The descriptor a slot's scene would run, with a mirror resolved to the
    /// template its source ends up with. None while the window is neither
    /// active nor open, with no live display, or with nothing assigned.
    fn slot_scene_desc(
        model: &DisplayStateModel,
        record: &crate::engine::state::DisplayRuntimeRecord,
    ) -> Result<Option<SceneDesc>, EngineError> {
        if !record.should_have_runtime() {
            return Ok(None);
        }
        let Some(WallpaperAssignment::Mirror(_)) = &record.model.assignment else {
            return record.scene_desc();
        };
        let Some(display) = record.model.live_display.clone() else {
            return Ok(None);
        };
        match model.resolved_assignment(&record.model.key)? {
            Some(WallpaperAssignment::Direct(template)) => {
                template.validate()?;
                Ok(Some(template.for_display(display)))
            }
            _ => Ok(None),
        }
    }

    /// Applies one platform display report. A display that reports no pixels
    /// yet is left out (see [`plan_refresh`]) instead of failing the refresh
    /// for the others; the display watcher refreshes again when it settles.
    pub(crate) fn apply_display_report(
        &mut self,
        primary: crate::DisplayDesc,
        all: Vec<crate::DisplayDesc>,
    ) -> Result<(), EngineError> {
        let plan = plan_refresh(primary, all);
        if let Some(message) = self.refresh_report_log.message_for(&plan) {
            log::warn!("{message}");
        }
        match plan {
            RefreshPlan::Skip { .. } => Ok(()),
            RefreshPlan::Apply {
                primary,
                displays,
                transitional,
            } => self.reconcile_display_descriptors_keeping(primary, displays, &transitional),
        }
    }

    pub fn reconcile_display_descriptors(
        &mut self,
        primary: crate::DisplayDesc,
        displays: Vec<crate::DisplayDesc>,
    ) -> Result<(), EngineError> {
        self.reconcile_display_descriptors_keeping(primary, displays, &[])
    }

    pub fn reconcile_display_descriptors_keeping(
        &mut self,
        primary: crate::DisplayDesc,
        displays: Vec<crate::DisplayDesc>,
        transitional: &[crate::DisplayDesc],
    ) -> Result<(), EngineError> {
        self.update_display_state(|model| {
            model
                .refresh_connected_keeping(primary, displays, transitional)
                .map(|_actions| ())
        })
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn set_wallpaper_for(
        &mut self,
        selector: DisplaySelector,
        wallpaper: WallpaperAssignment,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.update_display_state(|model| model.set_assignment(&selector, wallpaper))?;
        self.handle_for_key(&DisplayKey::from_selector(&selector)?)
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn create_window_for(
        &mut self,
        selector: DisplaySelector,
    ) -> Result<Option<SceneHandle>, EngineError> {
        self.update_display_state(|model| model.set_window_active(&selector, true).map(|_| ()))?;
        self.handle_for_key(&DisplayKey::from_selector(&selector)?)
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn destroy_window_for(&mut self, selector: DisplaySelector) -> Result<(), EngineError> {
        self.update_display_state(|model| model.destroy_window(&selector).map(|_| ()))
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn reconcile_scenes(
        &mut self,
        scenes: Vec<crate::project::SceneDesc>,
    ) -> Result<Vec<crate::project::SceneResult>, EngineError> {
        self.update_display_state(|model| model.apply_reconcile(&scenes))?;
        scenes.reconcile_results(&self.display_model(), &self.state.handles_by_display)
    }

    pub fn close_all_scenes(&mut self) -> Result<(), EngineError> {
        self.state.close_all()
    }

    pub fn set_scaling_mode(
        &mut self,
        handle: SceneHandle,
        mode: crate::project::ScalingMode,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_scaling_mode(mode))
    }

    pub fn set_scaling_factor(
        &mut self,
        handle: SceneHandle,
        factor: f64,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_scaling_factor(factor))
    }

    pub fn set_framing(
        &mut self,
        handle: SceneHandle,
        framing: crate::project::SceneFraming,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_framing(framing))
    }

    /// Moves the picture for a drag in progress. Nothing about the scene's
    /// state changes, so unlike [`Self::set_framing`] there is no runtime state
    /// to record and no snapshot to publish.
    pub fn preview_framing(
        &mut self,
        handle: SceneHandle,
        framing: crate::project::SceneFraming,
    ) -> Result<(), EngineError> {
        let runtime = self.state.scene_mut(handle)?;
        let result = runtime.preview_framing(framing);
        self.signal_pending_pointer_sample();
        result
    }

    pub fn set_fps(&mut self, handle: SceneHandle, fps: u32) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_fps(fps))
    }

    pub fn set_render_scale(
        &mut self,
        handle: SceneHandle,
        scale: f64,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_render_scale(scale))
    }

    pub fn set_paused(&mut self, handle: SceneHandle, paused: bool) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_paused(paused))
    }

    pub fn set_mouse_position(
        &mut self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_position(x, y)
    }

    pub fn set_mouse_button(
        &mut self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_button(button, pressed)
    }

    pub fn set_mouse_entered(
        &mut self,
        handle: SceneHandle,
        entered: bool,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_entered(entered)
    }

    /// Applies the global pause target to every open scene in one pass. A scene
    /// on a display in `suspended_displays` stays paused on a global resume,
    /// so it never runs between the resume and its own re-suspension.
    pub fn set_all_paused(&mut self, paused: bool, suspended_displays: &[u32]) -> Result<(), EngineError> {
        let targets: Vec<(SceneHandle, bool)> = self
            .state
            .display_records
            .iter()
            .filter(|record| record.runtime.is_some())
            .filter_map(|record| {
                let suspended = record
                    .model
                    .live_display
                    .as_ref()
                    .is_some_and(|display| suspended_displays.contains(&display.display_id));
                Some((record.handle?, paused || suspended))
            })
            .collect();

        for (handle, paused) in targets {
            self.set_paused(handle, paused)?;
        }

        Ok(())
    }

    pub fn set_render_resolution(
        &mut self,
        handle: SceneHandle,
        width: u32,
        height: u32,
    ) -> Result<(), EngineError> {
        let backend = self.backend;
        self.with_scene_mut(handle, |scene| scene.set_render_resolution(backend, width, height))
    }

    pub fn set_audio_response_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_response_enabled(enabled))
    }

    pub fn set_media_integration_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_media_integration_enabled(enabled))
    }

    pub fn submit_media_event_json(
        &mut self,
        handle: SceneHandle,
        json: String,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.submit_media_event_json(&json))
    }

    pub fn apply_system_media_artwork(
        &mut self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.apply_system_media_artwork(width, height, rgba))
    }

    pub fn set_audio_volume(
        &mut self,
        handle: SceneHandle,
        volume: crate::media::audio::AudioVolume,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_volume(volume))
    }

    pub fn set_audio_muted(&mut self, handle: SceneHandle, muted: bool) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_muted(muted))
    }

    pub fn set_property_override(
        &mut self,
        handle: SceneHandle,
        flat_json: String,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_property_override_json(Some(flat_json)))
    }

    pub fn reset_property_override(&mut self, handle: SceneHandle) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_property_override_json(None))
    }

    /// Shows a property document while an edit is under way. Nothing about the
    /// scene's state changes, so unlike [`Self::set_property_override`] there
    /// is no runtime state to record and no snapshot to publish.
    ///
    /// The scene is looked at now, in this actor's turn, so a reconcile that was
    /// handled first has already put its wallpaper on the handle.
    pub fn preview_property_override(
        &mut self,
        handle: SceneHandle,
        expected_scene_path: &str,
        flat_json: &str,
    ) -> Result<PropertyPreview, EngineError> {
        self.state
            .scene_mut(handle)?
            .preview_property_override_json(expected_scene_path, flat_json)
    }

    pub fn update_display_state(
        &mut self,
        update: impl FnOnce(&mut DisplayStateModel) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        self.update_display_state_with(update, SceneRuntime::close, Self::open_or_rebuild_required_runtimes)
    }

    fn update_display_state_with(
        &mut self,
        update: impl FnOnce(&mut DisplayStateModel) -> Result<(), EngineError>,
        close: impl FnMut(&mut SceneRuntime) -> Result<(), EngineError>,
        open: impl FnOnce(&mut Self) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        // The model is changed on a copy and committed only when the change
        // succeeded, so a refused update leaves every slot as it was.
        let mut model = self.display_model();
        update(&mut model)?;
        self.state.apply_display_model(&model)?;
        // A failure to close one scene must not keep the others from being
        // retired or the opening pass from running; the first error wins.
        let mut close = close;
        let retired = self.retire_scenes_not_needed(&mut close);
        self.release_parked_not_kept(&mut close);
        let opened = open(self);
        retired.and(opened)
    }

    /// Closes the scene of every slot that no longer should have one, and
    /// every scene it keeps parked. The slot remembers the live scene's state
    /// and keeps its handle reservation.
    fn retire_scenes_not_needed(
        &mut self,
        mut close: impl FnMut(&mut SceneRuntime) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        let model = self.display_model();
        let mut first_error = None;
        for record in &mut self.state.display_records {
            match Self::slot_scene_desc(&model, record) {
                Ok(Some(_)) => continue,
                Ok(None) => {}
                // Unreachable for a validated model; leave such a slot alone.
                Err(error) => {
                    first_error.get_or_insert(error);
                    continue;
                }
            }
            record.store_runtime_snapshot();
            record.model.runtime_open = false;
            let parked = std::mem::take(&mut record.parked).into_iter().map(|parked| parked.runtime);
            for mut runtime in record.runtime.take().into_iter().chain(parked) {
                if let Err(error) = close(&mut runtime) {
                    first_error.get_or_insert(error);
                }
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    /// Closes every parked scene its display may no longer keep: the display's
    /// list no longer names its wallpaper, or the display it was parked on is
    /// gone or changed size or scale. A display that only moved takes its
    /// parked windows along, as it does its live one, and one that cannot be
    /// moved is closed. A parked scene is only ever a shortcut, so nothing
    /// here fails the change that called it; failures are logged.
    fn release_parked_not_kept(&mut self, mut close: impl FnMut(&mut SceneRuntime) -> Result<(), EngineError>) {
        for index in 0..self.state.display_records.len() {
            let parked = std::mem::take(&mut self.state.display_records[index].parked);
            let live_display = self.state.display_records[index].model.live_display.clone();
            let mut kept = Vec::with_capacity(parked.len());
            for mut parked in parked {
                let desc = &parked.runtime.desc;
                let fits = live_display.as_ref().is_some_and(|live| {
                    live.display_id == desc.display.display_id
                        && (live == &desc.display || live.has_same_render_surface(&desc.display))
                });
                let wanted = fits && self.state.may_park(desc.display.display_id, &desc.scene_path);
                let moved = match live_display.as_ref() {
                    Some(live) if wanted && live != &parked.runtime.desc.display => {
                        parked.runtime.update_window_display(live.clone())
                    }
                    _ => Ok(()),
                };
                if wanted && moved.is_ok() {
                    kept.push(parked);
                    continue;
                }
                if let Err(error) = moved {
                    log::warn!(
                        "[wallpaper-core display] the paused scene kept for {} could not follow its \
                         display: {error}",
                        parked.runtime.desc.scene_path
                    );
                }
                log::info!(
                    "[wallpaper-core display] closing the paused scene kept for {} on display {}",
                    parked.runtime.desc.scene_path,
                    parked.runtime.desc.display.display_id
                );
                if let Err(error) = close(&mut parked.runtime) {
                    log::warn!("[wallpaper-core display] failed to close a paused scene: {error}");
                }
            }
            self.state.display_records[index].parked = kept;
        }
    }

    /// Sets the scenes `display_id` may keep parked and closes the parked
    /// scenes the new list leaves out.
    pub fn set_parked_scenes(&mut self, display_id: u32, scene_paths: Vec<String>) -> Result<(), EngineError> {
        if scene_paths.is_empty() {
            self.state.parking.remove(&display_id);
        } else {
            self.state.parking.insert(display_id, scene_paths);
        }
        self.release_parked_not_kept(SceneRuntime::close);
        Ok(())
    }

    /// Before a slot's job is planned for `desc`: when the live scene leaves
    /// for another wallpaper the display may keep, it is paused and parked with
    /// its handle and window, and when `desc` is the wallpaper of a parked
    /// scene, that scene becomes the live one again with its handle and with
    /// the descriptor's pause. The job then finds the slot as if the scene had
    /// never left, and only what `desc` changes beyond the wallpaper is done.
    /// A live scene the display may not keep is replaced as it always was,
    /// unless a parked one comes back, which closes it instead.
    fn park_or_promote(&mut self, index: usize, desc: &SceneDesc) {
        let display_id = desc.display.display_id;
        let record = &self.state.display_records[index];
        let key = record.model.key.clone();
        let leaving = record
            .runtime
            .as_ref()
            .is_some_and(|live| live.desc.scene_path != desc.scene_path);
        let returning = record
            .parked
            .iter()
            .position(|parked| parked.runtime.desc.scene_path == desc.scene_path);
        if leaving {
            let keep = record.runtime.as_ref().is_some_and(|live| {
                self.state.may_park(display_id, &live.desc.scene_path) && live.has_presented()
            });
            if keep || returning.is_some() {
                let record = &mut self.state.display_records[index];
                record.store_runtime_snapshot();
                record.model.runtime_open = false;
                let handle = record.handle.take();
                let runtime = record.runtime.take();
                self.state.sync_handle_reservation(key.clone(), None);
                if let Some(runtime) = runtime {
                    self.park_or_close(index, handle.filter(|_| keep), runtime);
                }
            }
        }
        let Some(position) = returning else {
            return;
        };
        let record = &mut self.state.display_records[index];
        let ParkedRuntime { handle, mut runtime } = record.parked.remove(position);
        if record.runtime.is_some() {
            // The live scene already runs this wallpaper; a parked copy of it
            // can only be left over, and two would cost twice the memory.
            if let Err(error) = runtime.close() {
                log::warn!("[wallpaper-core display] failed to close a duplicate paused scene: {error}");
            }
            return;
        }
        if let Err(error) = Self::catch_up_parked(&mut runtime, desc) {
            log::warn!(
                "[wallpaper-core display] the paused scene kept for {} could not run again, \
                 loading it afresh: {error}",
                desc.scene_path
            );
            if let Err(error) = runtime.close() {
                log::warn!("[wallpaper-core display] failed to close a paused scene: {error}");
            }
            return;
        }
        log::info!(
            "[wallpaper-core display] {} runs again on display {display_id} without a load",
            desc.scene_path
        );
        record.runtime = Some(runtime);
        record.handle = Some(handle);
        self.state.sync_handle_reservation(key, Some(handle));
        if let Err(error) = self.state.record_runtime_state(handle) {
            log::warn!("[wallpaper-core display] failed to record a scene that runs again: {error}");
        }
    }

    /// Gives a scene that comes back from being parked what a live scene takes without a
    /// rebuild and it missed while it waited: the frame-rate ceiling and the sound the bridge set
    /// on the live scenes meanwhile, then the descriptor's pause. Anything else that differs is
    /// for the job to rebuild, as on a live scene.
    fn catch_up_parked(runtime: &mut SceneRuntime, desc: &SceneDesc) -> Result<(), EngineError> {
        if runtime.desc.fps != desc.fps {
            runtime.set_fps(desc.fps)?;
        }
        if runtime.desc.audio_volume != desc.audio_volume {
            runtime.set_audio_volume(desc.audio_volume)?;
        }
        if runtime.desc.audio_muted != desc.audio_muted {
            runtime.set_audio_muted(desc.audio_muted)?;
        }
        runtime.set_paused(desc.paused)
    }

    /// Parks a live scene that left its slot (`handle` set) or closes it.
    fn park_or_close(&mut self, index: usize, handle: Option<SceneHandle>, mut runtime: SceneRuntime) {
        if let Some(handle) = handle {
            match runtime.set_paused(true) {
                Ok(()) => {
                    log::info!(
                        "[wallpaper-core display] keeping {} paused on display {}",
                        runtime.desc.scene_path,
                        runtime.desc.display.display_id
                    );
                    self.state.display_records[index].parked.push(ParkedRuntime { handle, runtime });
                    return;
                }
                Err(error) => log::warn!(
                    "[wallpaper-core display] could not pause {} to keep it, closing it: {error}",
                    runtime.desc.scene_path
                ),
            }
        }
        if let Err(error) = runtime.close() {
            log::warn!("[wallpaper-core display] failed to close a replaced scene: {error}");
        }
    }

    /// The handle of the scene alive on the slot with this key, if any.
    #[allow(clippy::unnecessary_wraps)]
    pub fn handle_for_key(&self, key: &DisplayKey) -> Result<Option<SceneHandle>, EngineError> {
        Ok(self.state.record_index(key).and_then(|index| {
            let record = &self.state.display_records[index];
            record.runtime.as_ref().and(record.handle)
        }))
    }

    pub fn with_scene_mut(
        &mut self,
        handle: SceneHandle,
        operation: impl FnOnce(&mut SceneRuntime) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        operation(self.state.scene_mut(handle)?)?;
        // Only reached once the renderer accepted the change.
        self.state.record_runtime_state(handle)
    }

    /// Makes every slot that should have a scene run the descriptor it is
    /// assigned. A slot that needs work gets its handle reserved first (also
    /// when the open will fail), its carried state computed and its running
    /// scene taken out for the duration of its job. Every job runs; the first
    /// error is returned afterwards.
    pub fn open_or_rebuild_required_runtimes(&mut self) -> Result<(), EngineError> {
        self.open_required_with(Self::run_runtime_refresh_job)
    }

    // Monomorphized at the call site; production and device-free execution use
    // exactly the same preparation, reservation, queue and error-selection pass.
    fn open_required_with(
        &mut self,
        mut run: impl FnMut(&mut Self, RuntimeRefreshJob) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        let model = self.display_model();
        let mut first_error: Option<(usize, EngineError)> = None;
        let mut jobs = Vec::new();
        for index in 0..self.state.display_records.len() {
            let record = &self.state.display_records[index];
            if !record.model.window_active {
                continue;
            }
            let desc = match Self::slot_scene_desc(&model, record) {
                Ok(Some(desc)) => desc,
                Ok(None) => continue,
                Err(error) => {
                    first_error.get_or_insert((index, error));
                    continue;
                }
            };
            self.park_or_promote(index, &desc);
            let record = &self.state.display_records[index];
            let mode =
                RuntimeRefreshMode::from_transition(record.runtime.as_ref().map(|r| &r.desc), &desc);
            if !mode.is_required() && record.handle.is_some() {
                self.state.display_records[index].model.runtime_open = true;
                continue;
            }
            // Even descriptor flattening can fail. Reserve before selecting
            // carried/initial state, not merely before renderer execution.
            let key = record.model.key.clone();
            let handle = self.state.reserve_handle_for_key(key.clone());
            let record = &mut self.state.display_records[index];
            record.handle = Some(handle);
            let runtime_state = match record.runtime_state_for_desc(&desc) {
                Ok(state) => state,
                Err(error) => {
                    record.model.runtime_open = record.runtime.is_some();
                    first_error.get_or_insert((index, error));
                    continue;
                }
            };
            record.model.runtime_open = false;
            jobs.push((index, RuntimeRefreshJob {
                key,
                handle,
                desc,
                runtime_state,
                existing_runtime: record.runtime.take(),
                first_frame_callback: Arc::clone(&self.first_frame_callback),
            }));
        }
        for (index, job) in jobs {
            if let Err(error) = run(self, job)
                && first_error.as_ref().is_none_or(|(earlier, _)| index < *earlier)
            {
                first_error = Some((index, error));
            }
        }
        first_error.map_or(Ok(()), |(_, error)| Err(error))
    }

    #[allow(clippy::too_many_lines)]
    pub fn run_runtime_refresh_job(&mut self, job: RuntimeRefreshJob) -> Result<(), EngineError> {
        let RuntimeRefreshJob {
            key,
            handle,
            desc,
            runtime_state,
            existing_runtime,
            first_frame_callback,
        } = job;
        let backend = self.backend;
        let mode =
            RuntimeRefreshMode::from_transition(existing_runtime.as_ref().map(|r| &r.desc), &desc);
        let Some(mut runtime) = existing_runtime else {
            return match SceneRuntime::open(
                backend,
                first_frame_callback,
                handle,
                &desc,
                runtime_state,
                self.weak_self.clone(),
            ) {
                Ok(runtime) => self.store_runtime(&key, handle, runtime),
                Err(error) => {
                    self.restore_failed_runtime_refresh(&key, handle, None)?;
                    Err(error)
                }
            };
        };
        let _scope = LoadScope::enter(runtime.load_id());
        let display = desc.display.clone();
        let result = match mode {
            // Nothing to do to the scene: it only gets its slot back, with the
            // handle the slot was missing.
            RuntimeRefreshMode::Unchanged | RuntimeRefreshMode::OpenRuntime => {
                return self.restore_failed_runtime_refresh(&key, handle, Some(runtime));
            }
            RuntimeRefreshMode::UpdateWindowOnly => runtime.update_window_display(display),
            RuntimeRefreshMode::RebuildExistingRuntime => runtime.replace_wallpaper(backend, &desc),
            RuntimeRefreshMode::ReopenRuntime => {
                match runtime.reconfigure_for_display(backend, display) {
                    Ok(()) => Ok(()),
                    Err(error) => {
                        log::warn!(
                            "[wallpaper-core display] in-place reconfigure of {} failed, opening \
                             a new scene instead: {error}",
                            key.key_label()
                        );
                        return self.reopen_as_new_scene(
                            key,
                            handle,
                            &desc,
                            runtime_state,
                            first_frame_callback,
                            runtime,
                        );
                    }
                }
            }
        };
        match result {
            Ok(()) => self.store_runtime(&key, handle, runtime),
            Err(error) => {
                self.restore_failed_runtime_refresh(&key, handle, Some(runtime))?;
                Err(error)
            }
        }
    }

    /// The fallback of a failed in-place reconfigure: a complete new scene,
    /// window and renderer, with the carried state; the old scene is closed
    /// only after the new one exists. If the new one cannot be had, the old
    /// scene goes back to its slot.
    fn reopen_as_new_scene(
        &mut self,
        key: DisplayKey,
        handle: SceneHandle,
        desc: &SceneDesc,
        runtime_state: crate::engine::runtime::SceneRuntimeState,
        first_frame_callback: FirstFrameCallback,
        mut old: SceneRuntime,
    ) -> Result<(), EngineError> {
        let opened = SceneRuntime::open_replacement(
            self.backend,
            first_frame_callback,
            handle,
            desc,
            runtime_state,
            self.weak_self.clone(),
            &mut old,
        );
        match opened {
            Ok(new) => {
                self.store_runtime(&key, handle, new)?;
                if let Err(error) = old.close() {
                    log::warn!(
                        "[wallpaper-core display] failed to close replaced display runtime: {error}"
                    );
                }
                Ok(())
            }
            Err(error) => {
                self.restore_failed_runtime_refresh(&key, handle, Some(old))?;
                Err(error)
            }
        }
    }

    /// Puts a scene a job produced in its slot. A slot that vanished meanwhile
    /// gets nothing: the scene is closed instead.
    fn store_runtime(
        &mut self,
        key: &DisplayKey,
        handle: SceneHandle,
        mut runtime: SceneRuntime,
    ) -> Result<(), EngineError> {
        let Some(index) = self.state.record_index(key) else {
            if let Err(error) = runtime.close() {
                log::warn!("[wallpaper-core display] failed to close an orphaned scene: {error}");
            }
            return Ok(());
        };
        let record = &mut self.state.display_records[index];
        record.runtime = Some(runtime);
        record.handle = Some(handle);
        self.state.sync_handle_reservation(key.clone(), Some(handle));
        self.state.record_runtime_state(handle)
    }

    /// A renderer reported that its scene, which had drawn, failed a frame and
    /// stopped. Spends one rung of that renderer's budget and schedules it; a
    /// report from a renderer that has since been replaced is ignored.
    fn handle_render_failure(&mut self, handle: SceneHandle, instance: &Arc<()>) {
        let Ok(runtime) = self.state.scene_mut(handle) else {
            return;
        };
        if !runtime.owns_renderer(instance) {
            return;
        }
        let (display, load) = (runtime.display_id(), runtime.load_id());
        let recovery = runtime.surface_recovery_mut();
        let was_exhausted = recovery.exhausted();
        let decision = recovery.on_failure(Instant::now());
        let _scope = LoadScope::enter(load);
        self.apply_recovery_decision(
            handle,
            instance,
            display,
            was_exhausted,
            decision,
            "stopped drawing after a failed frame",
        );
    }

    /// Does what the ladder decided: schedules the next attempt, leaves it to
    /// the one already on its way, or says once that the budget is spent.
    fn apply_recovery_decision(
        &self,
        handle: SceneHandle,
        instance: &Arc<()>,
        display: u32,
        was_exhausted: bool,
        decision: Decision,
        cause: &str,
    ) {
        match decision {
            Decision::Attempt { step, delay, number } => {
                log::warn!(
                    "[wallpaper-core engine] display {display} {cause}; trying {} in {delay:?} \
                     (attempt {number}/{})",
                    step.describe(),
                    LADDER.len()
                );
                self.schedule_recovery(handle, instance.clone(), step, delay, number);
            }
            Decision::Pending => log::debug!(
                "[wallpaper-core engine] display {display} {cause}; an attempt is already on its way"
            ),
            Decision::GiveUp => {
                if !was_exhausted {
                    log::error!(
                        "[wallpaper-core engine] display {display} stopped drawing; recovery gave \
                         up after {} attempts in {} s",
                        LADDER.len(),
                        WINDOW.as_secs()
                    );
                }
            }
        }
    }

    /// Delivers one attempt to this actor after `delay`. Holds only a weak
    /// reference while it waits, so a pending attempt never keeps a stopped
    /// engine alive.
    fn schedule_recovery(
        &self,
        handle: SceneHandle,
        renderer_instance: Arc<()>,
        step: RecoveryStep,
        delay: std::time::Duration,
        number: usize,
    ) {
        let actor = self.weak_self.clone();
        tokio::spawn(async move {
            if !delay.is_zero() {
                tokio::time::sleep(delay).await;
            }
            let Some(actor) = actor.upgrade() else {
                return;
            };
            let attempt = messages::RecoverSurfaceAttempt { handle, renderer_instance, step, number };
            let _ = actor.tell(attempt).send().await;
        });
    }

    /// Recovery asked for from outside the renderer's own report. The next
    /// rung of the display's ladder runs now rather than after its delay.
    fn recover_requested(
        &mut self,
        display_id: u32,
        reason: RecoveryReason,
    ) -> Result<RecoveryOutcome, EngineError> {
        let found = self.state.display_records.iter().find_map(|record| {
            let runtime = record.runtime.as_ref()?;
            (runtime.display_id() == display_id).then_some(record.handle).flatten()
        });
        let Some(handle) = found else {
            return Ok(RecoveryOutcome::NoScene);
        };
        let Ok(runtime) = self.state.scene_mut(handle) else {
            return Ok(RecoveryOutcome::NoScene);
        };
        let load = runtime.load_id();
        let recovery = runtime.surface_recovery_mut();
        let was_exhausted = recovery.exhausted();
        match recovery.on_forced(Instant::now()) {
            Decision::Pending => Ok(RecoveryOutcome::InProgress),
            Decision::GiveUp => {
                if !was_exhausted {
                    let _scope = LoadScope::enter(load);
                    log::error!(
                        "[wallpaper-core engine] display {display_id} stopped drawing; recovery \
                         gave up after {} attempts in {} s",
                        LADDER.len(),
                        WINDOW.as_secs()
                    );
                }
                Ok(RecoveryOutcome::GaveUp)
            }
            Decision::Attempt { step, number, .. } => {
                self.attempt_recovery(handle, None, step, number, reason)
            }
        }
    }

    /// Runs one recovery attempt on the scene at `handle` and says what came of
    /// it. `expected` is the renderer the attempt was scheduled for, when it was
    /// scheduled: a scene that has been replaced since is left alone.
    ///
    /// A failed attempt leaves the surface stopped with nothing left to report
    /// it, since a stopped surface fails no more frames, so the next rung is
    /// scheduled from here.
    fn attempt_recovery(
        &mut self,
        handle: SceneHandle,
        expected: Option<&Arc<()>>,
        step: RecoveryStep,
        number: usize,
        reason: RecoveryReason,
    ) -> Result<RecoveryOutcome, EngineError> {
        let backend = self.backend;
        let Ok(runtime) = self.state.scene_mut(handle) else {
            return Ok(RecoveryOutcome::NoScene);
        };
        if expected.is_some_and(|instance| !runtime.owns_renderer(instance)) {
            return Ok(RecoveryOutcome::NoScene);
        }
        let display = runtime.display_id();
        // Something else (a display change that rebuilt the surface) may have
        // started it drawing again while this waited; rebuilding it now would
        // only interrupt it. Only a failure the renderer reported can be
        // answered that way: a stall check is called because the surface looks
        // fine to the renderer.
        if reason == RecoveryReason::RenderFailure && is_healthy(runtime.surface_health()) {
            runtime.surface_recovery_mut().mark_done();
            let _scope = LoadScope::enter(runtime.load_id());
            log::info!(
                "[wallpaper-core engine] display {display} is drawing again; skipping {}",
                step.describe()
            );
            return Ok(RecoveryOutcome::AlreadyHealthy);
        }
        let result = runtime.recover_surface(backend, step);
        // A rebuild is a new renderer, with its own number in the log.
        let (load, instance) = (runtime.load_id(), runtime.renderer_instance());
        let recovery = runtime.surface_recovery_mut();
        let _scope = LoadScope::enter(load);
        match result {
            Ok(RecoveryStep::Rebuild) => {
                // The new renderer is a new scene with no first frame yet, and
                // a scene reports a failed frame only once it has presented
                // one. If this rebuild fails its first draw nothing calls
                // back, so the attempt stays pending and the engine looks at
                // the renderer itself until it has drawn or stopped.
                log::info!(
                    "[wallpaper-core engine] display {display} renderer rebuilt (attempt \
                     {number}/{}); waiting for it to draw",
                    LADDER.len()
                );
                self.schedule_settle(handle, instance, number, Instant::now());
                self.publish_snapshot();
                Ok(RecoveryOutcome::Recovered { step: RecoveryStep::Rebuild, attempt: number })
            }
            Ok(used) => {
                // The compiled scene is the one that had drawn, so a repeat of
                // the failure is reported by the renderer as usual.
                recovery.mark_done();
                log::info!(
                    "[wallpaper-core engine] display {display} renderer recovered by {} \
                     (attempt {number}/{})",
                    used.describe(),
                    LADDER.len()
                );
                self.publish_snapshot();
                Ok(RecoveryOutcome::Recovered { step: used, attempt: number })
            }
            Err(error) => {
                recovery.mark_done();
                log::warn!(
                    "[wallpaper-core engine] display {display} recovery by {} failed \
                     (attempt {number}/{}): {error}",
                    step.describe(),
                    LADDER.len()
                );
                let was_exhausted = recovery.exhausted();
                let decision = recovery.on_failure(Instant::now());
                self.apply_recovery_decision(
                    handle,
                    &instance,
                    display,
                    was_exhausted,
                    decision,
                    "is still stopped",
                );
                self.publish_snapshot();
                Err(error)
            }
        }
    }

    /// Looks again, after [`SETTLE_INTERVAL`], at the renderer a rebuild
    /// attempt opened. Holds only a weak reference while it waits, like
    /// [`Self::schedule_recovery`].
    fn schedule_settle(
        &self,
        handle: SceneHandle,
        renderer_instance: Arc<()>,
        number: usize,
        rebuilt_at: Instant,
    ) {
        let actor = self.weak_self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(SETTLE_INTERVAL).await;
            let Some(actor) = actor.upgrade() else {
                return;
            };
            let look = messages::SettleRecoveredSurface {
                handle,
                renderer_instance,
                number,
                rebuilt_at,
            };
            let _ = actor.tell(look).send().await;
        });
    }

    /// One look at a renderer that recovery rebuilt, until it has drawn.
    ///
    /// The attempt that built it is still pending, so nothing else starts a
    /// second one beside it. Drawing ends the attempt as a success. A renderer
    /// that stopped before it drew ends it as a failure and feeds the ladder
    /// the failure it never reported, which schedules the next rung or gives
    /// up. One that has done neither is looked at again, until
    /// [`SETTLE_LIMIT`]; then nothing says it failed, so it is left alone and
    /// the attempt ends.
    fn settle_recovered_surface(
        &mut self,
        handle: SceneHandle,
        instance: &Arc<()>,
        number: usize,
        rebuilt_at: Instant,
    ) {
        let Ok(runtime) = self.state.scene_mut(handle) else {
            return;
        };
        if !runtime.owns_renderer(instance) {
            return;
        }
        let (display, load) = (runtime.display_id(), runtime.load_id());
        let waited = rebuilt_at.elapsed();
        let settled = settle(runtime.surface_health(), waited);
        let recovery = runtime.surface_recovery_mut();
        let _scope = LoadScope::enter(load);
        match settled {
            Settled::Waiting => self.schedule_settle(handle, instance.clone(), number, rebuilt_at),
            Settled::Drawing => {
                recovery.mark_done();
                log::info!(
                    "[wallpaper-core engine] display {display} renderer recovered by {} \
                     (attempt {number}/{})",
                    RecoveryStep::Rebuild.describe(),
                    LADDER.len()
                );
            }
            Settled::Unconfirmed => {
                recovery.mark_done();
                log::warn!(
                    "[wallpaper-core engine] display {display} renderer rebuilt (attempt \
                     {number}/{}) has not drawn after {} s and has not failed; leaving it as it is",
                    LADDER.len(),
                    SETTLE_LIMIT.as_secs()
                );
            }
            Settled::Stopped(reason) => {
                recovery.mark_done();
                let was_exhausted = recovery.exhausted();
                let decision = recovery.on_failure(Instant::now());
                log::warn!(
                    "[wallpaper-core engine] display {display} renderer rebuilt (attempt \
                     {number}/{}) stopped before it drew ({})",
                    LADDER.len(),
                    reason.as_str()
                );
                self.apply_recovery_decision(
                    handle,
                    instance,
                    display,
                    was_exhausted,
                    decision,
                    "is still stopped",
                );
            }
        }
    }

    pub fn restore_failed_runtime_refresh(
        &mut self,
        key: &DisplayKey,
        handle: SceneHandle,
        runtime: Option<SceneRuntime>,
    ) -> Result<(), EngineError> {
        let Some(index) = self.state.record_index(key) else {
            if let Some(mut runtime) = runtime
                && let Err(error) = runtime.close()
            {
                log::warn!("[wallpaper-core display] failed to close an orphaned scene: {error}");
            }
            return Ok(());
        };
        let record = &mut self.state.display_records[index];
        match runtime {
            Some(runtime) => {
                record.model.runtime_open = true;
                record.handle = Some(handle);
                record.runtime = Some(runtime);
                record.store_runtime_snapshot();
                self.state.sync_handle_reservation(key.clone(), Some(handle));
            }
            // The first open failed: the reservation stays, the mark does not.
            None => record.model.runtime_open = false,
        }
        Ok(())
    }
}

impl Message<Ping> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(&mut self, _msg: Ping, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(())
    }
}

impl Message<messages::RefreshDisplays> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::RefreshDisplays,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| {
            #[cfg(test)]
            if actor.fail_next_refresh_displays {
                actor.fail_next_refresh_displays = false;
                return Err(EngineError::Platform("test display refresh failure".to_string()));
            }
            actor.refresh_displays_now()
        })
    }
}

impl Message<messages::RefreshDisplayDescriptors> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::RefreshDisplayDescriptors,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reconcile_display_descriptors(msg.primary, msg.displays))
    }
}

impl Message<messages::ReconcileScenes> for EngineActor {
    type Reply = messages::ReconcileReply;

    async fn handle(
        &mut self,
        msg: messages::ReconcileScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reconcile_scenes(msg.scenes))
    }
}

impl Message<messages::CreateWindowForDisplay> for EngineActor {
    type Reply = messages::SceneHandleReply;

    async fn handle(
        &mut self,
        msg: messages::CreateWindowForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.create_window_for(msg.selector))
    }
}

impl Message<messages::DestroyWindowForDisplay> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::DestroyWindowForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.destroy_window_for(msg.selector))
    }
}

impl Message<messages::SetWallpaperForDisplay> for EngineActor {
    type Reply = messages::SceneHandleReply;

    async fn handle(
        &mut self,
        msg: messages::SetWallpaperForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_wallpaper_for(msg.selector, msg.wallpaper))
    }
}

impl Message<messages::SetScalingMode> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetScalingMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_scaling_mode(msg.handle, msg.mode))
    }
}

impl Message<messages::SetScalingFactor> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetScalingFactor,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_scaling_factor(msg.handle, msg.factor))
    }
}

impl Message<messages::SetFraming> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetFraming,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_framing(msg.handle, msg.framing))
    }
}

impl Message<messages::PreviewFraming> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::PreviewFraming,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.preview_framing(msg.handle, msg.framing)
    }
}

impl Message<messages::SetFps> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetFps,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_fps(msg.handle, msg.fps))
    }
}

impl Message<messages::SetRenderScale> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetRenderScale,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_render_scale(msg.handle, msg.scale))
    }
}

impl Message<messages::SetPaused> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetPaused,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_paused(msg.handle, msg.paused))
    }
}

impl Message<messages::SetAllPaused> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAllPaused,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_all_paused(msg.paused, &msg.suspended_displays))
    }
}

impl Message<messages::SetParkedScenes> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetParkedScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_parked_scenes(msg.display_id, msg.scene_paths))
    }
}

impl Message<messages::RendererCounters> for EngineActor {
    type Reply = Result<Vec<RendererSurfaceCounters>, EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::RendererCounters,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        // Reading counters must never disturb the scenes it reads: no snapshot
        // update, no pause transition, no renderer mutation.
        self.state
            .display_records
            .iter()
            .filter_map(|record| record.runtime.as_ref())
            .map(SceneRuntime::counters)
            .collect()
    }
}

impl Message<messages::SetMousePosition> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMousePosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_position(msg.handle, msg.x, msg.y)
    }
}

impl Message<messages::SetMouseButton> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseButton,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_button(msg.handle, msg.button, msg.pressed)
    }
}

impl Message<messages::SetMouseEntered> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseEntered,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_entered(msg.handle, msg.entered)
    }
}

impl Message<messages::SetRenderResolution> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetRenderResolution,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_render_resolution(msg.handle, msg.width, msg.height))
    }
}

impl Message<messages::SetAudioResponseEnabled> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioResponseEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_response_enabled(msg.handle, msg.enabled))
    }
}

impl Message<messages::UpdateMedia> for EngineActor {
    type Reply = Result<(), EngineError>;
    async fn handle(&mut self, msg: messages::UpdateMedia,
        _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        self.with_scene_mut(msg.handle, |scene| scene.update_media(msg.enabled, &msg.state))
    }
}

impl Message<messages::SetMediaIntegrationEnabled> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMediaIntegrationEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| {
            actor.set_media_integration_enabled(msg.handle, msg.enabled)
        })
    }
}

impl Message<messages::SubmitMediaEventJson> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SubmitMediaEventJson,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.submit_media_event_json(msg.handle, msg.json))
    }
}

impl Message<messages::ApplySystemMediaArtwork> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::ApplySystemMediaArtwork,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| {
            actor.apply_system_media_artwork(msg.handle, msg.width, msg.height, msg.rgba)
        })
    }
}

impl Message<messages::SetAudioVolume> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioVolume,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_volume(msg.handle, msg.volume))
    }
}

impl Message<messages::SetAudioMuted> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioMuted,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_muted(msg.handle, msg.muted))
    }
}

impl Message<messages::SetPropertyOverride> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetPropertyOverride,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_property_override(msg.handle, msg.flat_json))
    }
}

impl Message<messages::ResetPropertyOverride> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::ResetPropertyOverride,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reset_property_override(msg.handle))
    }
}

impl Message<messages::PreviewPropertyOverride> for EngineActor {
    type Reply = Result<PropertyPreview, EngineError>;

    async fn handle(
        &mut self,
        msg: messages::PreviewPropertyOverride,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.preview_property_override(msg.handle, &msg.expected_scene_path, &msg.flat_json)
    }
}

impl Message<messages::CloseAllScenes> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::CloseAllScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.close_all_scenes())
    }
}

impl Message<messages::NativePointerInputChanged> for EngineActor {
    type Reply = ();

    async fn handle(&mut self, msg: messages::NativePointerInputChanged, _ctx: &mut Context<Self, Self::Reply>) {
        #[cfg(test)]
        self.pointer_notifications.push((msg.renderer_instance.clone(), msg.accepts_pointer_input));
        let changed = self.state.scene_mut(msg.handle).is_ok_and(|runtime| {
            runtime.apply_pointer_input_capability(&msg.renderer_instance, msg.accepts_pointer_input)
        });
        if changed { self.publish_snapshot(); } else { self.signal_pending_pointer_sample(); }
    }
}

impl Message<messages::NativeAudioRequirementChanged> for EngineActor {
    type Reply = ();

    async fn handle(
        &mut self,
        msg: messages::NativeAudioRequirementChanged,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        let changed = self.state.scene_mut(msg.handle).is_ok_and(|runtime| {
            runtime.apply_audio_requirement(&msg.renderer_instance, msg.requires_audio)
        });
        if changed {
            self.publish_snapshot();
        }
    }
}

impl Message<messages::NativeRenderFailed> for EngineActor {
    type Reply = ();

    async fn handle(
        &mut self,
        msg: messages::NativeRenderFailed,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        #[cfg(test)]
        self.render_failure_notifications.push(msg.renderer_instance.clone());
        self.handle_render_failure(msg.handle, &msg.renderer_instance);
    }
}

/// Sent to ourselves by the failure ladder, so it replies with nothing: an
/// error reply to a `tell` would be treated as a panic and stop the engine.
impl Message<messages::RecoverSurfaceAttempt> for EngineActor {
    type Reply = ();

    async fn handle(
        &mut self,
        msg: messages::RecoverSurfaceAttempt,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        // Everything worth saying about the outcome was logged where it
        // happened, and a failed attempt has already scheduled the next one.
        let _ = self.attempt_recovery(
            msg.handle,
            Some(&msg.renderer_instance),
            msg.step,
            msg.number,
            RecoveryReason::RenderFailure,
        );
    }
}

/// Sent to ourselves while a rebuilt renderer has not yet drawn, so it replies
/// with nothing for the same reason.
impl Message<messages::SettleRecoveredSurface> for EngineActor {
    type Reply = ();

    async fn handle(
        &mut self,
        msg: messages::SettleRecoveredSurface,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        self.settle_recovered_surface(
            msg.handle,
            &msg.renderer_instance,
            msg.number,
            msg.rebuilt_at,
        );
    }
}

impl Message<messages::RecoverSurface> for EngineActor {
    type Reply = Result<RecoveryOutcome, EngineError>;

    async fn handle(
        &mut self,
        msg: messages::RecoverSurface,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.recover_requested(msg.display_id, msg.reason)
    }
}

impl Message<messages::NativeUserShortcutRequested> for EngineActor {
    type Reply = ();

    async fn handle(
        &mut self,
        msg: messages::NativeUserShortcutRequested,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        // A wallpaper the user has since replaced must not still be pressing
        // buttons, so the handle has to still name a live scene.
        if self.state.scene_mut(msg.handle).is_err() {
            return;
        }
        // Pushed straight to whoever is listening. Nothing is held here: a
        // request no host has taken is a press the user already stopped
        // waiting for, and keeping it would replay it at the next launch.
        self.snapshots.report_user_shortcut(msg.handle, &msg.property_name, &msg.property_value);
    }
}

impl Message<messages::PollMouseState> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(&mut self, msg: messages::PollMouseState, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        if !msg.state.point.x.is_finite() || !msg.state.point.y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        let current = self.snapshots.load();
        let snapshot = super::DisplaySnapshot { entries: &current.displays };
        for entry in snapshot.entries {
            let Some(handle) = entry.handle else { continue; };
            // Keep the complete snapshot available while resolving mirror geometry.
            let update = snapshot.mouse_update_for_entry(msg.state, entry);
            let Ok(runtime) = self.state.scene_mut(handle) else { continue; };
            if !runtime.accepts_pointer_input() { continue; }
            runtime.set_mouse_entered(update.entered)?;
            if let Some(position) = update.position {
                runtime.set_mouse_position(position.x, position.y)?;
            }
            runtime.reconcile_mouse_button_baseline(update.buttons)?;
            for button in update.buttons.transitions() {
                runtime.set_mouse_button(button.button, button.pressed)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
impl Message<DisplayRecordCountForTest> for EngineActor {
    type Reply = Result<usize, EngineError>;

    async fn handle(
        &mut self,
        _msg: DisplayRecordCountForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.state.display_records.len())
    }
}

#[cfg(test)]
impl Message<SequenceForTest> for EngineActor {
    type Reply = Result<u64, EngineError>;

    async fn handle(
        &mut self,
        msg: SequenceForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.test_sequence += 1;
        assert_eq!(self.test_sequence, msg.expected, "messages must be handled in mailbox order");
        Ok(self.test_sequence)
    }
}

#[cfg(test)]
impl Message<messages::FailNextRefreshDisplaysForTest> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::FailNextRefreshDisplaysForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.fail_next_refresh_displays = true;
        Ok(())
    }
}

#[cfg(test)]
pub(super) struct RefreshFailurePendingForTest;

#[cfg(test)]
impl Message<RefreshFailurePendingForTest> for EngineActor {
    type Reply = bool;
    async fn handle(&mut self, _: RefreshFailurePendingForTest, _: &mut Context<Self, Self::Reply>) -> bool {
        self.fail_next_refresh_displays
    }
}

#[cfg(test)]
impl Message<messages::TakePointerNotificationsForTest> for EngineActor {
    type Reply = Vec<(Arc<()>, bool)>;

    async fn handle(&mut self, _msg: messages::TakePointerNotificationsForTest, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        std::mem::take(&mut self.pointer_notifications)
    }
}

#[cfg(test)]
impl Message<messages::TakeRenderFailuresForTest> for EngineActor {
    type Reply = Vec<Arc<()>>;

    async fn handle(&mut self, _msg: messages::TakeRenderFailuresForTest, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        std::mem::take(&mut self.render_failure_notifications)
    }
}

#[cfg(test)]
mod main_display_tests;

#[cfg(test)]
mod space_parking_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DisplayDesc, engine::{runtime::SceneRuntimeState, state::StoredSceneRuntimeState}, display::state::DisplayRecord, project::{ScalingMode, SceneFraming, SceneTemplate}, window::MouseButtonTracker};
    use std::sync::Mutex;

    fn desc(id: u32) -> SceneDesc {
        SceneDesc::builder(DisplayDesc::new(id, -613, 137, 2496, 1408, 2.0), "/virtual/orchid/scene.json").fps(53).build().unwrap()
    }

    fn actor_for(scenes: &[SceneDesc]) -> EngineActor {
        let records = scenes.iter().enumerate().map(|(i, scene)| DisplayRecord {
            key: if i == 0 { DisplayKey::Primary } else { DisplayKey::LiveDisplayId(scene.display.display_id) },
            live_display: Some(scene.display.clone()), assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(scene))),
            window_active: true, runtime_open: false, primary_inheritance_consumed: true,
            bound_to_display: false,
        }).collect();
        let state = EngineState::with_display_model(DisplayStateModel { records });
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(|| true))))));
        let prepared = EngineActor::prepare();
        EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots, prepared.actor_ref().downgrade())
    }

    fn succeed(actor: &mut EngineActor, job: RuntimeRefreshJob) -> Result<(), EngineError> {
        let runtime = SceneRuntime::windowless_for_test(job.handle, &job.desc, &job.runtime_state, actor.weak_self.clone())?;
        actor.store_runtime(&job.key, job.handle, runtime)
    }

    fn poison_preparation(actor: &mut EngineActor, index: usize, remembered: bool) {
        let record = &mut actor.state.display_records[index];
        if remembered {
            let mut prior = record.scene_desc().unwrap().unwrap();
            let state = SceneRuntimeState::try_from(&prior).unwrap();
            prior.property_override_json = Some(r#"{"invalid":[]}"#.into());
            record.last_runtime_state = Some(StoredSceneRuntimeState::new(prior, state));
        } else {
            let Some(WallpaperAssignment::Direct(template)) = &mut record.model.assignment else { panic!("direct") };
            template.property_override_json = Some(r#"{"invalid":[]}"#.into());
        }
    }

    #[test]
    fn failed_partial_update_still_publishes_committed_state() {
        // CLEANROOM ET45
        let mut actor = actor_for(&[desc(87), desc(126)]);
        let error = actor.with_snapshot_update(|actor| {
            actor.state.display_records[1].model.window_active = false;
            Err::<(), _>(EngineError::Platform("independent partial failure".into()))
        }).unwrap_err();
        assert!(matches!(error, EngineError::Platform(text) if text == "independent partial failure"));
        assert!(!actor.snapshots.load().displays[1].window_active);
        let before = actor.snapshots.load().displays.clone();
        actor.with_snapshot_update(|_| Err::<(), _>(EngineError::Render("no mutation".into()))).unwrap_err();
        assert_eq!(actor.snapshots.load().displays, before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn runtime_refresh_job_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        // CLEANROOM ET46: exercise job preparation from live AND remembered state.
        for remembered in [false, true] {
            let mut old = desc(87);
            old.scaling_mode = ScalingMode::Fill;
            old.scaling_factor = 1.7;
            let mut next = old.clone();
            next.scene_path = "/virtual/cobalt/scene.json".into();
            next.scaling_mode = ScalingMode::Stretch;
            next.scaling_factor = 0.85;
            let mut actor = actor_for(std::slice::from_ref(&next));
            let state = SceneRuntimeState::try_from(&old).unwrap();
            if remembered {
                actor.state.display_records[0].last_runtime_state = Some(StoredSceneRuntimeState::new(old, state));
            } else {
                let handle = actor.state.reserve_handle_for_key(DisplayKey::Primary);
                actor.state.display_records[0].handle = Some(handle);
                actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(handle, &old, &state, actor.weak_self.clone()).unwrap());
            }
            let mut count = 0;
            actor.open_required_with(|actor, job| {
                count += 1;
                assert_eq!(job.runtime_state.scaling_mode, ScalingMode::Stretch);
                assert_eq!(job.runtime_state.scaling_factor, 0.85);
                succeed(actor, job)
            }).unwrap();
            assert_eq!(count, 1);
            assert_eq!(actor.state.display_records[0].runtime.as_ref().unwrap().runtime_state().scaling_factor, 0.85);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn runtime_refresh_job_for_new_wallpaper_uses_descriptor_framing() {
        // CLEANROOM ET47
        for remembered in [false, true] {
            let old = desc(87);
            let mut state = SceneRuntimeState::try_from(&old).unwrap();
            state.framing = SceneFraming { pan_x: 0.37, pan_y: 0.64 };
            let mut next = old.clone();
            next.scene_path = "/virtual/cobalt/scene.json".into();
            next.framing = SceneFraming { pan_x: 0.82, pan_y: 0.19 };
            let mut actor = actor_for(std::slice::from_ref(&next));
            if remembered {
                actor.state.display_records[0].last_runtime_state = Some(StoredSceneRuntimeState::new(old, state));
            } else {
                let h = actor.state.reserve_handle_for_key(DisplayKey::Primary);
                actor.state.display_records[0].handle = Some(h);
                actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(h, &old, &state, actor.weak_self.clone()).unwrap());
            }
            actor.open_required_with(|actor, job| {
                assert_eq!(job.runtime_state.framing, next.framing);
                succeed(actor, job)
            }).unwrap();
            assert_eq!(actor.state.display_records[0].runtime.as_ref().unwrap().runtime_state().framing, next.framing);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn retirement_errors_keep_separate_precedence_without_skipping_the_opening_pass() {
        for open_fails in [false, true] {
            let scenes = [desc(87), desc(126), desc(203)];
            let mut actor = actor_for(&scenes);
            for scene in &scenes[..2] {
                let key = if scene.display.display_id == 87 { DisplayKey::Primary } else { DisplayKey::LiveDisplayId(126) };
                let handle = actor.state.reserve_handle_for_key(key.clone());
                let runtime = SceneRuntime::windowless_for_test(handle, scene, &SceneRuntimeState::try_from(scene).unwrap(), actor.weak_self.clone()).unwrap();
                actor.store_runtime(&key, handle, runtime).unwrap();
            }
            let mut retired = Vec::new();
            let mut opened = Vec::new();
            let error = actor.with_snapshot_update(|actor| actor.update_display_state_with(|model| {
                for record in &mut model.records[..2] {
                    record.window_active = false;
                    record.runtime_open = false;
                }
                Ok(())
            }, |runtime| {
                retired.push(runtime.display_id());
                runtime.close()?;
                Err(EngineError::Platform(format!("retired {}", runtime.display_id())))
            }, |actor| actor.open_required_with(|actor, job| {
                opened.push(job.desc.display.display_id);
                if open_fails {
                    actor.restore_failed_runtime_refresh(&job.key, job.handle, job.existing_runtime)?;
                    Err(EngineError::Render("opening failure must not outrank retirement".into()))
                } else { succeed(actor, job) }
            }))).unwrap_err();
            assert!(matches!(error, EngineError::Platform(text) if text == "retired 87"));
            assert_eq!(retired, vec![87, 126]);
            assert_eq!(opened, vec![203]);
            let snapshot = actor.snapshots.load();
            assert!(snapshot.displays[..2].iter().all(|e| e.handle.is_none() && !e.window_active));
            assert_eq!(snapshot.displays[2].handle.is_some(), !open_fails);
            assert!(actor.state.display_records[..2].iter().all(|r| r.handle.is_some() && r.last_runtime_state.is_some() && r.runtime.is_none()));
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preparation_failure_reserves_before_validation_and_retry_reuses_it() {
        for remembered in [false, true] {
            let mut actor = actor_for(&[desc(87)]);
            poison_preparation(&mut actor, 0, remembered);
            let error = actor.with_snapshot_update(|actor| actor.open_required_with(|_, _| panic!("invalid state must not reach execution"))).unwrap_err();
            assert!(matches!(error, EngineError::InvalidInput(_)));
            let key = DisplayKey::Primary;
            let handle = actor.state.display_records[0].handle.expect("preparation failure retains the reservation");
            assert_eq!(actor.state.handles_by_display.get(&key), Some(&handle));
            assert_eq!(actor.state.displays_by_handle.get(&handle), Some(&key));
            assert!(!actor.state.display_records[0].model.runtime_open);
            assert!(actor.snapshots.load().displays[0].handle.is_none());
            assert!(matches!(actor.state.scene_mut(handle), Err(EngineError::InvalidInput(text)) if text.contains("is not active")));
            actor.state.display_records[0].model.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc(87))));
            actor.state.display_records[0].last_runtime_state = None;
            actor.with_snapshot_update(|actor| actor.open_required_with(succeed)).unwrap();
            assert_eq!(actor.snapshots.load().displays[0].handle, Some(handle));
            assert_eq!(actor.state.next_handle, handle.raw() + 1);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn slot_order_is_independent_of_display_ids_and_reconcile_request_order() {
        let scenes = [desc(203), desc(87), desc(126)];
        let mut actor = actor_for(&scenes);
        let requested = [scenes[2].clone(), scenes[1].clone(), scenes[0].clone()];
        let mut model = actor.display_model();
        model.apply_reconcile(&requested).unwrap();
        actor.state.apply_display_model(&model).unwrap();
        let mut attempted = Vec::new();
        let error = actor.with_snapshot_update(|actor| actor.open_required_with(|actor, job| {
            let id = job.desc.display.display_id;
            attempted.push(id);
            if id == 126 { succeed(actor, job) } else {
                actor.restore_failed_runtime_refresh(&job.key, job.handle, job.existing_runtime)?;
                Err(EngineError::Render(format!("refused display {id}")))
            }
        })).unwrap_err();
        assert!(matches!(error, EngineError::Render(text) if text == "refused display 203"));
        assert_eq!(attempted, vec![203, 87, 126]);
        assert!(actor.snapshots.load().displays[2].handle.is_some());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn earliest_slot_error_beats_later_preparation_and_every_later_job_runs() {
        for existing in [false, true] {
            for preparation_first in [false, true] {
                let scenes = [desc(87), desc(126), desc(203), desc(279), desc(315)];
                let mut actor = actor_for(&scenes);
                let prep = usize::from(!preparation_first);
                let execute_fail = usize::from(preparation_first);
                if existing {
                    let h = actor.state.reserve_handle_for_key(DisplayKey::Primary);
                    let mut prior = scenes[0].clone();
                    prior.fps = 47;
                    actor.state.display_records[0].handle = Some(h);
                    actor.state.display_records[0].runtime = Some(SceneRuntime::windowless_for_test(h, &prior, &SceneRuntimeState::try_from(&prior).unwrap(), actor.weak_self.clone()).unwrap());
                }
                poison_preparation(&mut actor, prep, false);
                let mut attempted = Vec::new();
                let result = actor.with_snapshot_update(|actor| actor.open_required_with(|actor, job| {
                    let index = scenes.iter().position(|s| s.display.display_id == job.desc.display.display_id).unwrap();
                    attempted.push(index);
                    if index == execute_fail || index == 3 {
                        actor.restore_failed_runtime_refresh(&job.key, job.handle, job.existing_runtime)?;
                        Err(EngineError::Render(format!("execution slot {index}")))
                    } else { succeed(actor, job) }
                }));
                let error = result.unwrap_err();
                if preparation_first {
                    assert!(matches!(error, EngineError::InvalidInput(_)));
                } else {
                    assert!(matches!(error, EngineError::Render(text) if text == "execution slot 0"), "earlier execution must outrank later preparation");
                }
                assert_eq!(attempted, (0..5).filter(|i| *i != prep).collect::<Vec<_>>());
                let snapshot = actor.snapshots.load();
                assert!(snapshot.displays[2].handle.is_some());
                assert!(snapshot.displays[4].handle.is_some());
                assert!(snapshot.displays[3].handle.is_none());
                assert_eq!(snapshot.displays[0].handle.is_some(), existing);
                assert!(actor.state.display_records.iter().all(|r| r.handle.is_some()));
                for record in &actor.state.display_records {
                    let h = record.handle.unwrap();
                    assert_eq!(actor.state.displays_by_handle.get(&h), Some(&record.model.key));
                }
            }
        }
    }
}
