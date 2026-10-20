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
        state::{DisplayRuntimeRecord, EngineState},
        surface_recovery::{
            Decision, LADDER, RecoveryOutcome, RecoveryReason, RecoveryStep, SETTLE_INTERVAL,
            SETTLE_LIMIT, Settled, WINDOW, is_healthy, settle,
        },
    },
    log_context::LoadScope,
    owe::backend::OweBackend,
    render::RendererSurfaceCounters,
    project::{SceneDescSliceExt, SceneHandle},
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

#[derive(Clone)]
pub struct EngineActorHandle {
    #[allow(dead_code)]
    actor: ActorRef<EngineActor>,
    #[allow(dead_code)]
    _runtime: Option<Arc<tokio::runtime::Runtime>>,
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
        let actor_ref = prepared.actor_ref().clone();
        let actor = EngineActor::new(backend, first_frame_callback, state, snapshots, actor_ref.downgrade());

        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            if matches!(
                handle.runtime_flavor(),
                tokio::runtime::RuntimeFlavor::CurrentThread
            ) {
                prepared.spawn(actor);
                return Ok(Self {
                    actor: actor_ref,
                    _runtime: None,
                });
            }

            let _guard = handle.enter();
            prepared.spawn_in_thread(actor);
            return Ok(Self {
                actor: actor_ref,
                _runtime: None,
            });
        }

        let runtime = Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .thread_name("wallpaper-engine-actor-runtime")
                .build()
                .map_err(|error| {
                    EngineError::Platform(format!("failed to start engine actor runtime: {error}"))
                })?,
        );
        {
            let _guard = runtime.enter();
            prepared.spawn_in_thread(actor);
        }

        Ok(Self {
            actor: actor_ref,
            _runtime: Some(runtime),
        })
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
        let displays = crate::DisplayDesc::all()?;
        self.apply_display_report(primary, displays)
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
            model.refresh_connected_keeping(primary, displays, transitional)?;
            Ok(())
        })
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn set_wallpaper_for(
        &mut self,
        selector: DisplaySelector,
        wallpaper: WallpaperAssignment,
    ) -> Result<Option<SceneHandle>, EngineError> {
        let key = DisplayKey::from_selector(&selector)?;
        self.update_display_state(|model| model.set_assignment(&selector, wallpaper))?;
        self.handle_for_key(&key)
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn create_window_for(
        &mut self,
        selector: DisplaySelector,
    ) -> Result<Option<SceneHandle>, EngineError> {
        let key = DisplayKey::from_selector(&selector)?;
        self.update_display_state(|model| model.set_window_active(&selector, true).map(|_| ()))?;
        self.handle_for_key(&key)
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

        let model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        scenes.reconcile_results(&model, &self.state.handles_by_display)
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
        self.with_scene_mut(handle, |scene| {
            scene.set_render_resolution(backend, width, height)
        })
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
        self.with_scene_mut(handle, |scene| {
            scene.apply_system_media_artwork(width, height, rgba)
        })
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
        self.with_scene_mut(handle, |scene| {
            scene.set_property_override_json(Some(flat_json))
        })
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
        let mut runtimes_to_close = Vec::new();
        let mut model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        update(&mut model)?;

        self.state.apply_display_model(&model)?;

        for index in 0..self.state.display_records.len() {
            let mut resolved_model = self.state.display_records[index].model.clone();
            resolved_model.assignment = model.resolved_assignment(&resolved_model.key)?;
            if !resolved_model.should_have_runtime() {
                let record = &mut self.state.display_records[index];
                record.store_runtime_snapshot();
                record.model.runtime_open = false;
                let key = record.model.key.clone();
                let runtime = record.runtime.take();
                let handle = record.handle;
                self.state.sync_handle_reservation(key, handle);
                if let Some(runtime) = runtime {
                    runtimes_to_close.push(runtime);
                }
            }
        }
        for mut runtime in runtimes_to_close {
            runtime.close()?;
        }

        self.open_or_rebuild_required_runtimes()
    }

    #[allow(clippy::unnecessary_wraps)]
    pub fn handle_for_key(&self, key: &DisplayKey) -> Result<Option<SceneHandle>, EngineError> {
        Ok(self.state.handles_by_display.get(key).copied())
    }

    pub fn with_scene_mut(
        &mut self,
        handle: SceneHandle,
        operation: impl FnOnce(&mut SceneRuntime) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        let runtime = self.state.scene_mut(handle)?;
        let result = operation(runtime);
        self.signal_pending_pointer_sample();
        result?;
        self.state.record_runtime_state(handle)
    }

    pub fn open_or_rebuild_required_runtimes(&mut self) -> Result<(), EngineError> {
        let mut jobs = Vec::new();
        let model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };

        for index in 0..self.state.display_records.len() {
            let mut runtime_model = self.state.display_records[index].model.clone();
            runtime_model.assignment = model.resolved_assignment(&runtime_model.key)?;
            let runtime_record = DisplayRuntimeRecord {
                model: runtime_model,
                handle: None,
                runtime: None,
                last_runtime_state: None,
            };
            if !runtime_record.should_have_runtime() {
                continue;
            }
            let Some(desc) = runtime_record.scene_desc()? else {
                continue;
            };
            let current_desc = self.state.display_records[index]
                .runtime
                .as_ref()
                .map(|runtime| &runtime.desc);
            if !RuntimeRefreshMode::from_transition(current_desc, &desc).is_required()
                && self.state.display_records[index].handle.is_some()
            {
                self.state.display_records[index].model.runtime_open = true;
                continue;
            }
            let key = self.state.display_records[index].model.key.clone();
            let handle = self.state.reserve_handle_for_key(key.clone());
            let runtime_state = self.state.display_records[index].runtime_state_for_desc(&desc)?;
            let existing_runtime = self.state.display_records[index].runtime.take();
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].model.runtime_open = false;
            jobs.push(RuntimeRefreshJob {
                key,
                handle,
                desc,
                runtime_state,
                existing_runtime,
                first_frame_callback: self.first_frame_callback.clone(),
            });
        }

        let mut first_error = None;
        for job in jobs {
            if let Err(error) = self.run_runtime_refresh_job(job) {
                first_error.get_or_insert(error);
            }
        }

        if let Some(error) = first_error {
            return Err(error);
        }

        Ok(())
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

        let mut runtime = match existing_runtime {
            Some(mut runtime) => {
                match RuntimeRefreshMode::from_transition(Some(&runtime.desc), &desc) {
                    RuntimeRefreshMode::Unchanged => runtime,
                    RuntimeRefreshMode::OpenRuntime => {
                        unreachable!("existing runtime cannot require initial open")
                    }
                    RuntimeRefreshMode::UpdateWindowOnly => {
                        let before_display = runtime.desc.display.clone();
                        match runtime.update_window_display(desc.display.clone()) {
                            Ok(()) => {
                                log::debug!(
                                    "[wallpaper-core display] updated runtime window in place: \
                                     key={key:?} before_display={before_display:?} \
                                     after_display={:?}",
                                    desc.display
                                );
                                runtime
                            }
                            Err(error) => {
                                self.restore_failed_runtime_refresh(&key, handle, Some(runtime))?;
                                return Err(error);
                            }
                        }
                    }
                    RuntimeRefreshMode::ReopenRuntime => {
                        let before_display = runtime.desc.display.clone();
                        let reconfigure_result =
                            runtime.reconfigure_for_display(self.backend, desc.display.clone());
                        match reconfigure_result {
                            Ok(()) => {
                                log::debug!(
                                    "[wallpaper-core display] reconfigured runtime surface in \
                                     place: key={key:?} before_display={before_display:?} \
                                     after_display={:?}",
                                    desc.display
                                );
                                runtime
                            }
                            Err(reconfigure_error) => {
                                log::warn!(
                                    "[wallpaper-core display] fast surface reconfigure failed, \
                                     falling back to full rebuild: key={key:?} \
                                     before_display={before_display:?} after_display={:?} \
                                     error={reconfigure_error}",
                                    desc.display
                                );
                                match SceneRuntime::open(
                                    self.backend,
                                    first_frame_callback.clone(),
                                    handle,
                                    &desc,
                                    runtime_state,
                                    self.weak_self.clone(),
                                ) {
                                    Ok(replacement) => {
                                        if let Err(error) = runtime.close() {
                                            log::warn!(
                                                "[wallpaper-core display] failed to close \
                                                 replaced display runtime: {error}"
                                            );
                                        }
                                        replacement
                                    }
                                    Err(error) => {
                                        self.restore_failed_runtime_refresh(
                                            &key,
                                            handle,
                                            Some(runtime),
                                        )?;
                                        return Err(error);
                                    }
                                }
                            }
                        }
                    }
                    RuntimeRefreshMode::RebuildExistingRuntime => {
                        let rebuild_result = if runtime.desc.same_wallpaper(&desc) {
                            runtime.resize_or_rebuild(self.backend, desc.display.clone())
                        } else {
                            runtime.replace_wallpaper(self.backend, &desc)
                        };
                        if let Err(error) = rebuild_result {
                            self.restore_failed_runtime_refresh(&key, handle, Some(runtime))?;
                            return Err(error);
                        }
                        runtime
                    }
                }
            }
            None => match SceneRuntime::open(
                self.backend,
                first_frame_callback,
                handle,
                &desc,
                runtime_state,
                self.weak_self.clone(),
            ) {
                Ok(runtime) => runtime,
                Err(error) => {
                    self.restore_failed_runtime_refresh(&key, handle, None)?;
                    return Err(error);
                }
            },
        };

        if let Some(index) = self.state.record_index(&key) {
            self.state.display_records[index].model.runtime_open = true;
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].runtime = Some(runtime);
            self.state.display_records[index].store_runtime_snapshot();
            self.state.handles_by_display.insert(key.clone(), handle);
            self.state.displays_by_handle.insert(handle, key);
        } else {
            runtime.close()?;
        }

        Ok(())
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
        let Some(mut runtime) = runtime else {
            if let Some(index) = self.state.record_index(key) {
                self.state.display_records[index].model.runtime_open = false;
            }
            return Ok(());
        };

        if let Some(index) = self.state.record_index(key) {
            self.state.display_records[index].model.runtime_open = true;
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].runtime = Some(runtime);
            self.state.display_records[index].store_runtime_snapshot();
            self.state.handles_by_display.insert(key.clone(), handle);
            self.state.displays_by_handle.insert(handle, key.clone());
        } else {
            runtime.close()?;
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
        self.set_mouse_position(msg.handle, msg.x, msg.y)?;
        Ok(())
    }
}

impl Message<messages::SetMouseButton> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseButton,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_button(msg.handle, msg.button, msg.pressed)?;
        Ok(())
    }
}

impl Message<messages::SetMouseEntered> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseEntered,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_entered(msg.handle, msg.entered)?;
        Ok(())
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
        assert_eq!(self.test_sequence, msg.expected);
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
mod tests {
    use super::*;
    use crate::{
        DisplayDesc, WallpaperAssignment,
        display::state::{DisplayKey, DisplayRecord, DisplayStateModel},
        engine::{
            runtime::SceneRuntimeState,
            snapshot::EngineSnapshotPublisher,
            state::{EngineState, StoredSceneRuntimeState},
        },
        project::{ScalingMode, SceneDesc, SceneFraming, SceneTemplate},
    };

    #[test]
    fn failed_partial_update_still_publishes_committed_state() {
        let prepared = EngineActor::prepare();
        let state = EngineState::with_display_model(DisplayStateModel { records: vec![DisplayRecord {
            key: DisplayKey::Primary,
            live_display: Some(DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0)),
            assignment: None,
            window_active: true,
            runtime_open: false,
            primary_inheritance_consumed: false,
            bound_to_display: false,
        }] });
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new()))));
        let mut actor = EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots.clone(), prepared.actor_ref().downgrade());
        let result: Result<(), EngineError> = actor.with_snapshot_update(|actor| {
            actor.state.display_records[0].model.window_active = false;
            Err(EngineError::Platform("later operation failed".into()))
        });
        assert!(matches!(result, Err(EngineError::Platform(message)) if message == "later operation failed"));
        assert!(!snapshots.load().displays[0].window_active);
    }

    #[test]
    fn runtime_refresh_job_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let previous_desc = SceneDesc::builder(display.clone(), "/tmp/fill/project.json")
            .assets_path("/tmp/assets")
            .scaling_mode(ScalingMode::Fill)
            .build()
            .expect("previous scene should build");
        let next_template = SceneTemplate::builder("/tmp/fit/project.json")
            .assets_path("/tmp/assets")
            .scaling_mode(ScalingMode::Fit)
            .build()
            .expect("next scene should build");
        let mut state = EngineState::with_display_model(DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(display),
                assignment: Some(WallpaperAssignment::Direct(next_template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            }],
        });
        state.display_records[0].last_runtime_state = Some(StoredSceneRuntimeState::new(
            previous_desc.clone(),
            SceneRuntimeState::try_from(&previous_desc).expect("previous state should build"),
        ));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new()))));
        let prepared = EngineActor::prepare();
        let actor = EngineActor::new(OweBackend, Arc::new(|_handle| {}), state, snapshots, prepared.actor_ref().downgrade());
        let runtime_state = actor
            .state
            .display_records
            .first()
            .expect("primary record should exist")
            .runtime_state_for_desc(
                &actor
                    .state
                    .display_records
                    .first()
                    .expect("primary record should exist")
                    .scene_desc()
                    .expect("next scene should build")
                    .expect("assigned scene should exist"),
            )
            .expect("runtime state should build");

        assert_eq!(runtime_state.scaling_mode, ScalingMode::Fit);
        assert!(
            (runtime_state.scaling_factor - 1.0).abs() <= f64::EPSILON,
            "expected descriptor scaling factor 1.0, got {}",
            runtime_state.scaling_factor
        );
    }

    #[test]
    fn runtime_refresh_job_for_new_wallpaper_uses_descriptor_framing() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let previous_framing = SceneFraming {
            pan_x: 0.1,
            pan_y: 0.9,
        };
        let next_framing = SceneFraming {
            pan_x: 0.8,
            pan_y: 0.2,
        };
        let previous_desc = SceneDesc::builder(display.clone(), "/tmp/previous/project.json")
            .assets_path("/tmp/assets")
            .framing(previous_framing)
            .build()
            .expect("previous scene should build");
        let next_template = SceneTemplate::builder("/tmp/next/project.json")
            .assets_path("/tmp/assets")
            .framing(next_framing)
            .build()
            .expect("next scene should build");
        let mut state = EngineState::with_display_model(DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(display),
                assignment: Some(WallpaperAssignment::Direct(next_template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            }],
        });
        // The user had moved the previous wallpaper at runtime, away from both
        // descriptors' positions.
        let mut previous_state =
            SceneRuntimeState::try_from(&previous_desc).expect("previous state should build");
        previous_state.framing = SceneFraming {
            pan_x: 0.5,
            pan_y: 0.5,
        };
        state.display_records[0].last_runtime_state = Some(StoredSceneRuntimeState::new(
            previous_desc,
            previous_state,
        ));
        let record = &state.display_records[0];
        let next_desc = record
            .scene_desc()
            .expect("next scene should build")
            .expect("assigned scene should exist");

        let runtime_state = record
            .runtime_state_for_desc(&next_desc)
            .expect("runtime state should build");

        assert_eq!(runtime_state.framing, next_framing);
    }
}
