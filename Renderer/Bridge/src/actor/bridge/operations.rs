use std::collections::{BTreeMap, BTreeSet};

use kameo::actor::ActorRef;
use kameo::error::SendError;
use kameo::message::{Context, Message};
use kameo::reply::DelegatedReply;
use wallpaper_core::project::{ScalingMode, SceneDesc, SceneHandle};
use wallpaper_core::{DisplaySnapshotEntry, EngineError};

use crate::actor::messages::{
    ApplyWallpaperOptions, CancelWallpaperOptions, EjectWallpaperFromDisplay, SetDisplayEnabled,
    SetDisplayMode, SetMirrorMuted, SetMirrorScalingFactor, SetMirrorScalingMode, SetMirrorTarget,
    SetMirrorTargetFps, SetMirrorVolume,
};
use crate::actor::state_values::PreparedApply;
use crate::api::{
    BridgeDisplayMode, BridgeDisplayMutationBundle, BridgeDisplaySettingsRow, BridgeError,
    BridgeScalingMode, BridgeWallpaperEntry, BridgeWallpaperMutationBundle,
};
use crate::config::{
    AppConfig, MonitorRender, MonitorSettingsCfg, SerializedSelector, WallpaperConfig,
    stored_frame_rate,
};
use crate::display::{DisplaySelectorExt, DisplaySnapshotExt};
use crate::engine::{ActivationInputs, EngineFacade, LoadJournal, displays_awaiting_first_frame};
use crate::paths::BridgePaths;
use crate::project::ProjectModel;

use super::BridgeActor;

type WallpaperReply = Result<BridgeWallpaperMutationBundle, BridgeError>;
type DisplayReply = Result<BridgeDisplayMutationBundle, BridgeError>;

#[derive(Default)]
pub(super) struct OperationState {
    edit_revision: u64,
    reserved_revision: u64,
    latest_pending: bool,
    repair_active: Option<u64>,
    repair_follow_up: bool,
    deferred_repair: bool,
}

#[derive(Clone, Copy)]
pub(super) struct Ticket {
    reserved_revision: u64,
    edit_revision: u64,
}

struct ReconcileWork<E> {
    engine: E,
    app: AppConfig,
    wallpapers: BTreeMap<String, WallpaperConfig>,
    models: BTreeMap<String, ProjectModel>,
    library: Option<Vec<BridgeWallpaperEntry>>,
    suspended: BTreeSet<u32>,
    held: BTreeSet<String>,
    paths: BridgePaths,
    journal: LoadJournal,
    paused: bool,
    unloaded: bool,
    audio_suppressed: bool,
    frame_rate_cap: Option<u32>,
    render_scale: f32,
    force_shader_refresh: bool,
}

impl<E: EngineFacade> ReconcileWork<E> {
    fn activation_inputs<'a>(
        &'a self,
        displays: &'a [DisplaySnapshotEntry],
    ) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config: &self.app,
            wallpapers: &self.wallpapers,
            library: self.library.as_deref(),
            displays,
            paused: self.paused,
            suspended_displays: &self.suspended,
            paths: &self.paths,
            force_shader_refresh: self.force_shader_refresh,
            project_models: &self.models,
            frame_rate_cap: self.frame_rate_cap,
            audio_suppressed: self.audio_suppressed,
            held: &self.held,
        }
    }

    fn predict(&self, displays: &[DisplaySnapshotEntry]) -> Result<(), BridgeError> {
        self.activation_inputs(displays).build().map(|_| ())
    }

    async fn run(self) -> Result<Vec<SceneDesc>, BridgeError> {
        // Inventory and the authoritative plan belong to actual worker entry,
        // independently from Apply's earlier, always-required prediction.
        let displays = self.engine.display_snapshot();
        let owned = if self.unloaded {
            Vec::new()
        } else {
            self.activation_inputs(&displays).build_owned()?
        };
        let (scenes, owners): (Vec<_>, Vec<_>) = owned
            .into_iter()
            .map(|(scene, owner)| {
                (
                    super::live_scene(scene, self.frame_rate_cap, self.audio_suppressed),
                    owner,
                )
            })
            .unzip();
        let awaiting = displays_awaiting_first_frame(&displays, &self.engine.scene_windows(), &scenes);
        let openings = owners
            .into_iter()
            .zip(&scenes)
            .filter(|(_, scene)| awaiting.contains(&scene.display.display_id))
            .map(|(owner, scene)| (owner, scene.display.display_id))
            .collect();
        let ticket = self.journal.begin(openings);
        // The facade owns core/prune/readiness ordering. Keep the journal ticket
        // alive until every subsequent operation-layer poststep has succeeded.
        let results = self
            .engine
            .reconcile_scenes(scenes.clone())
            .await
            .map_err(engine_error)?;
        for scene in &scenes {
            let Some(result) = results
                .iter()
                .find(|result| result.display_id == scene.display.display_id)
            else {
                continue;
            };
            self.engine
                .set_audio_volume(result.handle, scene.audio_volume)
                .await
                .map_err(engine_error)?;
            self.engine
                .set_audio_muted(result.handle, scene.audio_muted)
                .await
                .map_err(engine_error)?;
            super::register_audio_capture(
                &self.engine,
                result.handle,
                scene.audio_response_enabled,
            )
            .await
            .map_err(engine_error)?;
            if self.render_scale < 1.0 {
                self.engine
                    .set_render_scale(result.handle, self.render_scale)
                    .await
                    .map_err(engine_error)?;
            }
        }
        ticket.succeed();
        Ok(scenes)
    }
}

fn engine_error(error: EngineError) -> BridgeError {
    BridgeError::engine(error.to_string())
}

fn copy_error(error: &BridgeError) -> BridgeError {
    BridgeError::Error {
        kind: error.kind(),
        message: error.message().to_owned(),
    }
}

fn receiving_error<M>(error: SendError<M, BridgeError>) -> BridgeError {
    match error {
        SendError::HandlerError(error) => error,
        other => BridgeError::engine(other.to_string()),
    }
}

struct ApplyFinished {
    ticket: Ticket,
    id: String,
    candidate: PreparedApply,
    scenes: Vec<SceneDesc>,
}

struct DisplayFinished {
    ticket: Ticket,
    candidate: AppConfig,
    wallpapers: BTreeMap<String, WallpaperConfig>,
    rows: BTreeMap<String, BridgeDisplaySettingsRow>,
    scenes: Vec<SceneDesc>,
}

struct OperationFailed {
    ticket: Ticket,
    error: BridgeError,
    lifted_hold: Option<String>,
}

struct RepairFinished {
    ticket: Ticket,
    result: Result<Vec<SceneDesc>, BridgeError>,
}

async fn coordinate_failure<E: EngineFacade + Clone>(
    actor: &ActorRef<BridgeActor<E>>,
    ticket: Ticket,
    error: &BridgeError,
    lifted_hold: Option<String>,
) {
    if let Err(delivery) = actor
        .ask(OperationFailed {
            ticket,
            error: copy_error(error),
            lifted_hold,
        })
        .await
    {
        // The original engine/activation boundary error remains the caller's
        // result even when the actor can no longer receive its coordination.
        log::warn!(
            "operation failure coordination could not be delivered: {}",
            receiving_error(delivery)
        );
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    pub(super) fn invalidate_operations(&mut self) {
        let owner = self.operation_owner_mut();
        owner.edit_revision = owner.edit_revision.wrapping_add(1);
        self.refresh_mouse_polling_policy();
    }

    pub(super) fn reserve_operation(&mut self) -> Ticket {
        let owner = self.operation_owner_mut();
        owner.reserved_revision = owner.reserved_revision.wrapping_add(1);
        owner.latest_pending = true;
        owner.deferred_repair = false;
        let ticket = Ticket {
            reserved_revision: owner.reserved_revision,
            edit_revision: owner.edit_revision,
        };
        self.refresh_mouse_polling_policy();
        ticket
    }

    pub(super) fn reserved_startup_revision(&self) -> u64 {
        self.operation_owner().reserved_revision
    }

    fn operation_is_current(&self, ticket: Ticket) -> bool {
        let owner = self.operation_owner();
        ticket.reserved_revision == owner.reserved_revision
            && ticket.edit_revision == owner.edit_revision
    }

    fn finish_operation(&mut self, ticket: Ticket) {
        let owner = self.operation_owner_mut();
        if ticket.reserved_revision == owner.reserved_revision {
            owner.latest_pending = false;
        }
        self.refresh_mouse_polling_policy();
    }

    fn publish_operation_scenes(&mut self, scenes: &[SceneDesc]) {
        self.operation_values_mut()
            .set_active_ids_from_scenes(scenes);
        self.refresh_mouse_polling_policy();
    }

    pub(super) fn complete_inline_operation(&mut self, ticket: Ticket, actor: ActorRef<Self>) {
        self.finish_operation(ticket);
        if self.operation_owner().deferred_repair {
            self.request_operation_repair(actor);
        }
    }

    pub(super) fn fail_inline_operation(
        &mut self,
        ticket: Ticket,
        error: &BridgeError,
        actor: ActorRef<Self>,
    ) {
        self.operation_append_error(error.message().to_owned());
        self.finish_operation(ticket);
        self.request_operation_repair(actor);
    }

    fn stale_operation(&mut self, ticket: Ticket, actor: ActorRef<Self>) {
        let owner = self.operation_owner();
        let repair_now = ticket.reserved_revision == owner.reserved_revision
            || !owner.latest_pending
            || owner.repair_active.is_some();
        self.finish_operation(ticket);
        if repair_now {
            self.request_operation_repair(actor);
        } else {
            self.operation_owner_mut().deferred_repair = true;
            self.refresh_mouse_polling_policy();
        }
    }

    fn request_operation_repair(&mut self, actor: ActorRef<Self>) {
        if self.operation_owner().repair_active.is_some() {
            let owner = self.operation_owner_mut();
            owner.repair_follow_up = true;
            owner.deferred_repair = false;
            self.refresh_mouse_polling_policy();
            return;
        }
        let ticket = self.reserve_operation();
        self.operation_owner_mut().repair_active = Some(ticket.reserved_revision);
        let work = self.capture_reconcile_work(
            self.operation_app().clone(),
            self.operation_wallpapers().clone(),
            false,
        );
        tokio::spawn(async move {
            let result = work.run().await;
            if let Err(delivery) = actor.ask(RepairFinished { ticket, result }).await {
                log::warn!(
                    "operation repair completion could not be delivered: {}",
                    receiving_error(delivery)
                );
            }
        });
    }

    #[cfg(test)]
    pub(crate) fn operation_repairs_idle(&self) -> bool {
        let owner = self.operation_owner();
        owner.repair_active.is_none() && !owner.repair_follow_up && !owner.deferred_repair
    }

    #[cfg(test)]
    pub(crate) fn operation_repair_active(&self) -> bool {
        self.operation_owner().repair_active.is_some()
    }

    fn capture_reconcile_work(
        &self,
        app: AppConfig,
        wallpapers: BTreeMap<String, WallpaperConfig>,
        force_shader_refresh: bool,
    ) -> ReconcileWork<E> {
        let models = self.operation_values().configured_project_models(&app);
        ReconcileWork {
            engine: self.operation_engine().clone(),
            app,
            wallpapers,
            models,
            library: self
                .operation_values()
                .scanned_library()
                .map(|library| library.to_vec()),
            suspended: self.operation_suspended_displays().clone(),
            held: self.operation_holds().clone(),
            paths: self.operation_paths().clone(),
            journal: self.operation_journal().clone(),
            paused: self.playback_paused(),
            unloaded: self.operation_unloaded(),
            audio_suppressed: self.operation_audio_suppressed(),
            frame_rate_cap: self.active_target_fps_cap(),
            render_scale: self.effective_render_scale(),
            force_shader_refresh,
        }
    }

    pub(super) async fn reconcile_snapshot_operation(
        &mut self,
        app_config: AppConfig,
        wallpaper_configs: BTreeMap<String, WallpaperConfig>,
        force_shader_refresh: bool,
    ) -> Result<Vec<SceneDesc>, BridgeError> {
        let scenes = self
            .capture_reconcile_work(app_config, wallpaper_configs, force_shader_refresh)
            .run()
            .await?;
        self.align_live_pause_with_policy().await;
        Ok(scenes)
    }

    pub(super) async fn reconcile_configured_operation(&mut self) -> Result<(), BridgeError> {
        self.load_wallpapers()?;
        if self.operation_unloaded() {
            let displays = self.operation_engine().display_snapshot();
            if displays.iter().any(|display| display.handle.is_some()) {
                self.reconcile_snapshot_operation(
                    self.operation_app().clone(),
                    self.operation_wallpapers().clone(),
                    false,
                )
                .await?;
            }
            self.refresh_mouse_polling_policy();
            return Ok(());
        }
        let configured = !self.operation_values().configured_ids().is_empty();
        let displays = self.operation_engine().display_snapshot();
        if !configured || displays.is_empty() {
            self.refresh_mouse_polling_policy();
            return Ok(());
        }
        if let Some(scenes) = self.unchanged_configured_scenes(&displays)? {
            self.publish_operation_scenes(&scenes);
            // Nothing was rebuilt, but a scene's pause may still be one the
            // policy no longer asks for.
            self.align_live_pause_with_policy().await;
            return Ok(());
        }
        let result = self
            .reconcile_snapshot_operation(
                self.operation_app().clone(),
                self.operation_wallpapers().clone(),
                false,
            )
            .await;
        self.refresh_mouse_polling_policy();
        let scenes = result?;
        self.publish_operation_scenes(&scenes);
        Ok(())
    }

    pub(super) async fn reconcile_inline_operation(&mut self) -> Result<(), BridgeError> {
        if self.operation_unloaded() {
            self.reconcile_snapshot_operation(
                self.operation_app().clone(),
                self.operation_wallpapers().clone(),
                false,
            )
            .await?;
            Ok(())
        } else {
            self.reconcile_configured_operation().await
        }
    }

    fn save_operation_app(&self, candidate: &AppConfig) -> Result<(), BridgeError> {
        if let Some(store) = self.operation_store() {
            store.save_app_config(candidate)?;
        }
        Ok(())
    }

    fn save_operation_apply(&self, candidate: &PreparedApply) -> Result<(), BridgeError> {
        if let Some(store) = self.operation_store() {
            store.save_app_config(candidate.app_config())?;
            store.save_wallpaper(candidate.wallpaper_config())?;
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<ApplyWallpaperOptions> for BridgeActor<E> {
    type Reply = DelegatedReply<WallpaperReply>;

    fn name() -> &'static str {
        std::any::type_name::<ApplyWallpaperOptions>()
    }

    async fn handle(
        &mut self,
        msg: ApplyWallpaperOptions,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.operation_engine().display_snapshot();
        let primary = displays
            .first()
            .and_then(|display| display.stable_identity_selector());
        let candidate = match self
            .operation_values()
            .prepare_apply(&msg.wallpaper_id, primary.as_ref())
        {
            Ok(candidate) => candidate,
            Err(error) => return ctx.reply(Err(error)),
        };
        let lifted = msg.user_initiated && self.operation_holds_slot().remove(&msg.wallpaper_id);
        if !candidate.requires_reconcile() && !lifted {
            let result = (|| {
                self.save_operation_apply(&candidate)?;
                self.operation_values_mut().publish_apply(
                    msg.wallpaper_id.clone(),
                    candidate,
                    false,
                )?;
                if msg.user_initiated {
                    let _ = self.operation_journal().forgive(&msg.wallpaper_id);
                }
                self.operation_values_mut().refresh_active_ids();
                self.invalidate_operations();
                self.wallpaper_bundle(msg.wallpaper_id)
            })();
            return ctx.reply(result);
        }
        let work = self.capture_reconcile_work(
            candidate.app_config().clone(),
            candidate.wallpaper_configs().clone(),
            false,
        );
        if let Err(error) = work.predict(&displays) {
            if lifted {
                self.operation_holds_slot().insert(msg.wallpaper_id);
            }
            return ctx.reply(Err(error));
        }
        let ticket = self.reserve_operation();
        let actor = ctx.actor_ref().clone();
        let journal = self.operation_journal().clone();
        ctx.spawn(async move {
            match work.run().await {
                Ok(scenes) => {
                    if msg.user_initiated {
                        let _ = journal.forgive(&msg.wallpaper_id);
                    }
                    actor
                        .ask(ApplyFinished {
                            ticket,
                            id: msg.wallpaper_id,
                            candidate,
                            scenes,
                        })
                        .await
                        .map_err(receiving_error)
                }
                Err(error) => {
                    coordinate_failure(&actor, ticket, &error, lifted.then_some(msg.wallpaper_id))
                        .await;
                    Err(error)
                }
            }
        })
    }
}

impl<E: EngineFacade + Clone> Message<ApplyFinished> for BridgeActor<E> {
    type Reply = WallpaperReply;

    fn name() -> &'static str {
        std::any::type_name::<ApplyFinished>()
    }

    async fn handle(
        &mut self,
        msg: ApplyFinished,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.operation_is_current(msg.ticket) {
            self.stale_operation(msg.ticket, ctx.actor_ref().clone());
            return self.wallpaper_bundle(msg.id);
        }
        self.refresh_mouse_polling_policy();
        self.align_live_pause_with_policy().await;
        self.operation_forget_property_preview(&msg.id);
        if let Err(error) = self.save_operation_apply(&msg.candidate) {
            *self.operation_app_slot() = msg.candidate.into_app_config();
            self.publish_operation_scenes(&msg.scenes);
            self.complete_inline_operation(msg.ticket, ctx.actor_ref().clone());
            return Err(error);
        }
        self.operation_values_mut()
            .publish_apply(msg.id.clone(), msg.candidate, false)?;
        self.publish_operation_scenes(&msg.scenes);
        self.complete_inline_operation(msg.ticket, ctx.actor_ref().clone());
        self.wallpaper_bundle(msg.id)
    }
}

impl<E: EngineFacade + Clone> Message<DisplayFinished> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<DisplayFinished>()
    }

    async fn handle(
        &mut self,
        msg: DisplayFinished,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.operation_is_current(msg.ticket) || self.operation_wallpapers() != &msg.wallpapers
        {
            self.stale_operation(msg.ticket, ctx.actor_ref().clone());
            return Ok(self.display_bundle());
        }
        self.refresh_mouse_polling_policy();
        self.align_live_pause_with_policy().await;
        self.save_operation_app(&msg.candidate)?;
        *self.operation_app_slot() = msg.candidate;
        *self.operation_rows_slot() = msg.rows;
        self.publish_operation_scenes(&msg.scenes);
        self.operation_values_mut().rebase_drafts();
        self.complete_inline_operation(msg.ticket, ctx.actor_ref().clone());
        Ok(self.display_bundle())
    }
}

impl<E: EngineFacade + Clone> Message<OperationFailed> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;

    fn name() -> &'static str {
        std::any::type_name::<OperationFailed>()
    }

    async fn handle(
        &mut self,
        msg: OperationFailed,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if let Some(id) = msg.lifted_hold {
            self.operation_holds_slot().insert(id);
        }
        self.operation_append_error(msg.error.message().to_owned());
        self.finish_operation(msg.ticket);
        self.request_operation_repair(ctx.actor_ref().clone());
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<RepairFinished> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;

    fn name() -> &'static str {
        std::any::type_name::<RepairFinished>()
    }

    async fn handle(
        &mut self,
        msg: RepairFinished,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let current = self.operation_is_current(msg.ticket);
        if self.operation_owner().repair_active == Some(msg.ticket.reserved_revision) {
            self.operation_owner_mut().repair_active = None;
        }
        if !current {
            // Release stale ownership before the ordinary stale-completion
            // rule; staleness alone must not supersede newer pending work.
            if self.operation_owner().repair_follow_up {
                self.operation_owner_mut().repair_follow_up = false;
                self.finish_operation(msg.ticket);
                self.request_operation_repair(ctx.actor_ref().clone());
            } else {
                self.stale_operation(msg.ticket, ctx.actor_ref().clone());
            }
            return Ok(());
        }
        match msg.result {
            Ok(scenes) => {
                self.publish_operation_scenes(&scenes);
                self.align_live_pause_with_policy().await;
            }
            Err(error) => self.operation_append_error(error.message().to_owned()),
        }
        self.finish_operation(msg.ticket);
        let follow_up =
            self.operation_owner().repair_follow_up || self.operation_owner().deferred_repair;
        if follow_up {
            let owner = self.operation_owner_mut();
            owner.repair_follow_up = false;
            owner.deferred_repair = false;
            self.request_operation_repair(ctx.actor_ref().clone());
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<CancelWallpaperOptions> for BridgeActor<E> {
    type Reply = WallpaperReply;

    fn name() -> &'static str {
        std::any::type_name::<CancelWallpaperOptions>()
    }

    async fn handle(
        &mut self,
        msg: CancelWallpaperOptions,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let draft = self.operation_values().wallpaper_draft(&msg.wallpaper_id)?;
        self.show_wallpaper_properties(&msg.wallpaper_id, false, Vec::new())
            .await?;
        let mut cancelled = draft.clone();
        cancelled.cancel();
        let mut attempted: Vec<(SceneHandle, f64)> = Vec::new();
        for preview in &draft.current().monitors {
            let committed = cancelled
                .current()
                .monitors
                .iter()
                .find(|entry| entry.selector == preview.selector)
                .map_or_else(
                    || MonitorRender::default().scaling_factor,
                    |entry| entry.scaling_factor,
                );
            if committed == preview.scaling_factor {
                continue;
            }
            let Some(handle) = self.display_handle(&msg.wallpaper_id, &preview.selector) else {
                continue;
            };
            attempted.push((handle, preview.scaling_factor));
            if let Err(error) = self
                .operation_engine()
                .set_scaling_factor(handle, committed)
                .await
            {
                for (handle, factor) in attempted {
                    if let Err(rollback) = self
                        .operation_engine()
                        .set_scaling_factor(handle, factor)
                        .await
                    {
                        log::warn!(
                            "could not restore scaling preview after failed cancel: {rollback}"
                        );
                    }
                }
                return Err(engine_error(error));
            }
        }
        self.operation_values_mut()
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .cancel();
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    fn operation_candidate_rows(
        &self,
        candidate: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> BTreeMap<String, BridgeDisplaySettingsRow> {
        if !displays.is_empty() {
            let login = self.operation_login_status();
            let reports = self.operation_engine().scene_runtime_reports();
            return self
                .operation_values()
                .operation_candidate_settings(
                    candidate,
                    displays,
                    login,
                    self.operation_paths(),
                    &reports,
                )
                .displays
                .into_iter()
                .map(|row| (row.display_id.clone(), row))
                .collect();
        }
        self.operation_rows()
            .iter()
            .map(|(key, remembered)| {
                let mut row = remembered.clone();
                if let Ok(display_id) = row.display_id.parse::<u32>() {
                    if let Some(block) = candidate.monitors.iter().find(|block| {
                        block.selector == SerializedSelector::LiveDisplayId { display_id }
                    }) {
                        row.enabled = block.enabled;
                        row.mode = if block.mode.eq_ignore_ascii_case("mirror") {
                            BridgeDisplayMode::Mirror
                        } else {
                            BridgeDisplayMode::Standalone
                        };
                        row.selected_mirror_target =
                            block.mirror_target.as_ref().map(SerializedSelector::id);
                    }
                }
                if key == "primary" {
                    row.enabled = true;
                    row.mode = BridgeDisplayMode::Standalone;
                    row.selected_mirror_target = None;
                }
                (key.clone(), row)
            })
            .collect()
    }
}

enum DisplayChange {
    Enabled(bool),
    Eject(String),
}

#[derive(Clone, Copy)]
enum MirrorControl {
    ScalingMode(BridgeScalingMode),
    ScalingFactor(f64),
    TargetFps(u32),
    Volume(f32),
    Muted(bool),
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    fn delegate_prepared_display_operation(
        &mut self,
        candidate: AppConfig,
        rows: BTreeMap<String, BridgeDisplaySettingsRow>,
        ctx: &mut Context<Self, DelegatedReply<DisplayReply>>,
    ) -> DelegatedReply<DisplayReply> {
        let wallpapers = self.operation_wallpapers().clone();
        let work = self.capture_reconcile_work(candidate.clone(), wallpapers.clone(), false);
        let ticket = self.reserve_operation();
        let actor = ctx.actor_ref().clone();
        ctx.spawn(async move {
            match work.run().await {
                Ok(scenes) => actor
                    .ask(DisplayFinished {
                        ticket,
                        candidate,
                        wallpapers,
                        rows,
                        scenes,
                    })
                    .await
                    .map_err(receiving_error),
                Err(error) => {
                    coordinate_failure(&actor, ticket, &error, None).await;
                    Err(error)
                }
            }
        })
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayEnabled> for BridgeActor<E> {
    type Reply = DelegatedReply<DisplayReply>;

    fn name() -> &'static str {
        std::any::type_name::<SetDisplayEnabled>()
    }

    async fn handle(
        &mut self,
        msg: SetDisplayEnabled,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match self.prepare_display_operation(&msg.display_id, DisplayChange::Enabled(msg.enabled)) {
            Ok((candidate, rows)) => self.delegate_prepared_display_operation(candidate, rows, ctx),
            Err(error) => ctx.reply(Err(error)),
        }
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayMode> for BridgeActor<E> {
    type Reply = DelegatedReply<DisplayReply>;

    fn name() -> &'static str {
        std::any::type_name::<SetDisplayMode>()
    }

    async fn handle(
        &mut self,
        msg: SetDisplayMode,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match self.prepare_display_mode_operation(&msg.display_id, msg.mode) {
            Ok((candidate, rows)) => self.delegate_prepared_display_operation(candidate, rows, ctx),
            Err(error) => ctx.reply(Err(error)),
        }
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorTarget> for BridgeActor<E> {
    type Reply = DelegatedReply<DisplayReply>;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorTarget>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorTarget,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match self.prepare_display_target_operation(&msg.display_id, &msg.target_display_id) {
            Ok((candidate, rows)) => self.delegate_prepared_display_operation(candidate, rows, ctx),
            Err(error) => ctx.reply(Err(error)),
        }
    }
}

impl<E: EngineFacade + Clone> Message<EjectWallpaperFromDisplay> for BridgeActor<E> {
    type Reply = DelegatedReply<DisplayReply>;

    fn name() -> &'static str {
        std::any::type_name::<EjectWallpaperFromDisplay>()
    }

    async fn handle(
        &mut self,
        msg: EjectWallpaperFromDisplay,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match self
            .prepare_display_operation(&msg.display_id, DisplayChange::Eject(msg.wallpaper_id))
        {
            Ok((candidate, rows)) => self.delegate_prepared_display_operation(candidate, rows, ctx),
            Err(error) => ctx.reply(Err(error)),
        }
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorScalingMode> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorScalingMode>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorScalingMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mirror_control(msg.display_id, MirrorControl::ScalingMode(msg.mode))
            .await
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorScalingFactor> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorScalingFactor>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorScalingFactor,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mirror_control(msg.display_id, MirrorControl::ScalingFactor(msg.factor))
            .await
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorTargetFps> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorTargetFps>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorTargetFps,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mirror_control(msg.display_id, MirrorControl::TargetFps(msg.fps))
            .await
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorVolume> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorVolume>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorVolume,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mirror_control(msg.display_id, MirrorControl::Volume(msg.volume))
            .await
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorMuted> for BridgeActor<E> {
    type Reply = DisplayReply;

    fn name() -> &'static str {
        std::any::type_name::<SetMirrorMuted>()
    }

    async fn handle(
        &mut self,
        msg: SetMirrorMuted,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mirror_control(msg.display_id, MirrorControl::Muted(msg.muted))
            .await
    }
}

fn core_scaling_mode(mode: BridgeScalingMode) -> ScalingMode {
    match mode {
        BridgeScalingMode::None => ScalingMode::None,
        BridgeScalingMode::Stretch => ScalingMode::Stretch,
        BridgeScalingMode::Match => ScalingMode::Fit,
        BridgeScalingMode::Fill => ScalingMode::Fill,
        BridgeScalingMode::MatchBlurred => ScalingMode::FitBlurred,
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    async fn set_mirror_control(&mut self, id: String, control: MirrorControl) -> DisplayReply {
        let (candidate, selector, displays, live_fps) =
            self.prepare_mirror_control(&id, control)?;
        let handle = self.mirror_display_handle(&selector, &displays);
        self.save_operation_app(&candidate)?;
        *self.operation_app_slot() = candidate;
        self.refresh_mouse_polling_policy();
        if let Some(handle) = handle {
            let setter = match control {
                MirrorControl::ScalingMode(mode) => self
                    .operation_engine()
                    .set_scaling_mode(handle, core_scaling_mode(mode)),
                MirrorControl::ScalingFactor(factor) => {
                    self.operation_engine().set_scaling_factor(handle, factor)
                }
                MirrorControl::TargetFps(_) => self.operation_engine().set_fps(handle, live_fps),
                MirrorControl::Volume(volume) => self.operation_engine().set_audio_volume(
                    handle,
                    wallpaper_core::media::audio::AudioVolume::try_from(volume)
                        .map_err(|error| BridgeError::invalid_input(error.to_string()))?,
                ),
                MirrorControl::Muted(muted) => self
                    .operation_engine()
                    .set_audio_muted(handle, muted || self.operation_audio_suppressed()),
            };
            setter.await.map_err(engine_error)?;
        }
        self.invalidate_operations();
        Ok(self.display_bundle())
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    pub(super) fn resolve_operation_selector(
        &self,
        input: &str,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<SerializedSelector, BridgeError> {
        let unknown = || BridgeError::invalid_input(format!("unknown display id {input}"));
        if input == "primary" {
            if displays.is_empty() && !self.operation_rows().contains_key("primary") {
                return Err(unknown());
            }
            return Ok(SerializedSelector::Primary);
        }
        if let Some(json) = input.strip_prefix("identity:") {
            let identity =
                serde_json::from_str::<wallpaper_core::DisplayIdentity>(json).map_err(|error| {
                    BridgeError::invalid_input(format!(
                        "invalid display identity selector: {error}"
                    ))
                })?;
            let selector = wallpaper_core::DisplaySelector::Identity(identity);
            if displays.is_empty() {
                return Ok(SerializedSelector::from_selector(&selector));
            }
            return selector
                .resolve_display(displays)
                .map(DisplaySnapshotExt::connected_selector)
                .ok_or_else(unknown);
        }
        if displays.is_empty() && !self.operation_rows().contains_key(input) {
            return Err(unknown());
        }
        let display_id = input
            .parse::<u32>()
            .map_err(|_| BridgeError::invalid_input(format!("invalid display id {input}")))?;
        if displays.is_empty() {
            return Ok(SerializedSelector::LiveDisplayId { display_id });
        }
        let display = displays
            .iter()
            .find(|display| display.desc.display_id == display_id)
            .ok_or_else(unknown)?;
        if displays
            .first()
            .is_some_and(|primary| display.matches_primary(primary))
        {
            Ok(SerializedSelector::Primary)
        } else {
            Ok(display.connected_selector())
        }
    }

    /// The live display id a saved selector stands for.
    pub(super) fn operation_source_id(
        &self,
        selector: &SerializedSelector,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<u32, BridgeError> {
        match selector {
            SerializedSelector::LiveDisplayId { display_id } => Ok(*display_id),
            SerializedSelector::Identity { .. } => selector
                .to_selector()
                .resolve_display(displays)
                .map(|display| display.desc.display_id)
                .ok_or_else(|| BridgeError::invalid_input("unknown display identity")),
            SerializedSelector::Primary => {
                if let Some(first) = displays.first() {
                    return Ok(first.desc.display_id);
                }
                // With no live list, the cached row for the primary names it:
                // "<text> (<id> - Primary)<text>".
                self.operation_rows()
                    .get("primary")
                    .and_then(|row| {
                        let (before, _) = row.title.rsplit_once(" - Primary)")?;
                        let (_, id) = before.rsplit_once('(')?;
                        id.parse::<u32>().ok()
                    })
                    .ok_or_else(|| BridgeError::invalid_input("unknown display id primary"))
            }
        }
    }

    fn operation_selector_matches_live_primary(
        &self,
        selector: &SerializedSelector,
        displays: &[DisplaySnapshotEntry],
    ) -> bool {
        displays
            .first()
            .is_some_and(|primary| selector.to_selector().matches_primary(primary, displays))
    }

    fn operation_valid_display_ids(&self, displays: &[DisplaySnapshotEntry]) -> BTreeSet<u32> {
        if displays.is_empty() {
            self.operation_rows()
                .values()
                .filter_map(|row| row.display_id.parse::<u32>().ok())
                .collect()
        } else {
            displays
                .iter()
                .map(|display| display.desc.display_id)
                .collect()
        }
    }

    fn validate_operation_mirrors(
        &self,
        candidate: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<(), BridgeError> {
        let valid = self.operation_valid_display_ids(displays);
        for block in &candidate.monitors {
            if block.mode != "mirror" {
                continue;
            }
            let Ok(source_id) = self.operation_source_id(&block.selector, displays) else {
                continue;
            };
            if !valid.contains(&source_id) {
                continue;
            }
            let target = block.mirror_target.as_ref().ok_or_else(|| {
                BridgeError::invalid_input(format!(
                    "mirror mode for display {source_id} requires a target"
                ))
            })?;
            let target_id = self.operation_source_id(target, displays).ok();
            if !target_id
                .is_some_and(|target_id| target_id != source_id && valid.contains(&target_id))
            {
                return Err(BridgeError::invalid_input(format!(
                    "unknown mirror target for display {source_id}"
                )));
            }
            candidate.validate_mirror_change(&block.selector, target)?;
        }
        Ok(())
    }

    fn operation_mirror_target(
        &self,
        candidate: &AppConfig,
        selector: &SerializedSelector,
        source: u32,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<SerializedSelector, BridgeError> {
        let valid = self.operation_valid_display_ids(displays);
        let eligible = |target: &SerializedSelector| {
            self.operation_source_id(target, displays)
                .is_ok_and(|target_id| target_id != source && valid.contains(&target_id))
                && candidate.validate_mirror_change(selector, target).is_ok()
        };
        if let Some(target) = candidate
            .monitors
            .iter()
            .find(|block| block.selector == *selector)
            .and_then(|block| block.mirror_target.as_ref())
            .filter(|target| eligible(target))
        {
            return Ok(target.clone());
        }
        if displays.is_empty() {
            for row in self.operation_rows().values() {
                if let Ok(display_id) = row.display_id.parse::<u32>() {
                    let target = SerializedSelector::LiveDisplayId { display_id };
                    if eligible(&target) {
                        return Ok(target);
                    }
                }
            }
        } else {
            for display in displays {
                let target = if displays
                    .first()
                    .is_some_and(|primary| display.matches_primary(primary))
                {
                    SerializedSelector::Primary
                } else {
                    display.connected_selector()
                };
                if eligible(&target) {
                    return Ok(target);
                }
            }
        }
        Err(BridgeError::invalid_input(
            "mirror mode requires another display",
        ))
    }

    fn prepare_display_operation(
        &self,
        input: &str,
        change: DisplayChange,
    ) -> Result<(AppConfig, BTreeMap<String, BridgeDisplaySettingsRow>), BridgeError> {
        let displays = self.operation_engine().display_snapshot();
        let selector = self.resolve_operation_selector(input, &displays)?;
        let primary = selector == SerializedSelector::Primary;
        let mut candidate = self.operation_app().normalized(&displays);
        match change {
            DisplayChange::Enabled(enabled) => {
                let block = candidate.ensure_monitor(selector);
                block.enabled = enabled || primary;
                if primary {
                    block.mode = "independent".to_owned();
                    block.mirror_target = None;
                }
            }
            DisplayChange::Eject(id) => {
                let block = candidate
                    .monitors
                    .iter_mut()
                    .find(|block| block.selector == selector)
                    .ok_or_else(|| {
                        BridgeError::invalid_input(format!("unknown display id {input}"))
                    })?;
                if block.wallpaper.as_deref() != Some(id.as_str()) {
                    return Err(BridgeError::invalid_input(format!(
                        "wallpaper {id} is not active on display {input}"
                    )));
                }
                block.wallpaper = None;
                if primary {
                    block.enabled = true;
                    block.mode = "independent".to_owned();
                    block.mirror_target = None;
                    for alias in &mut candidate.monitors {
                        if alias.wallpaper.as_deref() == Some(id.as_str())
                            && self
                                .operation_selector_matches_live_primary(&alias.selector, &displays)
                        {
                            alias.wallpaper = None;
                        }
                    }
                }
                // Eject intentionally does not validate unrelated mirror blocks.
                let rows = self.operation_candidate_rows(&candidate, &displays);
                return Ok((candidate, rows));
            }
        }
        let rows = self.operation_candidate_rows(&candidate, &displays);
        self.validate_operation_mirrors(&candidate, &displays)?;
        Ok((candidate, rows))
    }

    fn prepare_display_mode_operation(
        &self,
        input: &str,
        mode: BridgeDisplayMode,
    ) -> Result<(AppConfig, BTreeMap<String, BridgeDisplaySettingsRow>), BridgeError> {
        let displays = self.operation_engine().display_snapshot();
        let selector = self.resolve_operation_selector(input, &displays)?;
        let primary = selector == SerializedSelector::Primary;
        if primary && mode == BridgeDisplayMode::Mirror {
            return Err(BridgeError::invalid_input(
                "primary display cannot use mirror mode",
            ));
        }
        let source = self.operation_source_id(&selector, &displays)?;
        let mut candidate = self.operation_app().normalized(&displays);
        match mode {
            BridgeDisplayMode::Standalone => {
                let block = candidate.ensure_monitor(selector);
                block.mode = "independent".to_owned();
                block.mirror_target = None;
                if primary {
                    block.enabled = true;
                }
            }
            BridgeDisplayMode::Mirror => {
                let target =
                    self.operation_mirror_target(&candidate, &selector, source, &displays)?;
                let block = candidate.ensure_monitor(selector);
                block.enabled = true;
                block.mode = "mirror".to_owned();
                block.mirror_target = Some(target);
            }
        }
        let rows = self.operation_candidate_rows(&candidate, &displays);
        self.validate_operation_mirrors(&candidate, &displays)?;
        Ok((candidate, rows))
    }

    fn prepare_display_target_operation(
        &self,
        input: &str,
        target: &str,
    ) -> Result<(AppConfig, BTreeMap<String, BridgeDisplaySettingsRow>), BridgeError> {
        let displays = self.operation_engine().display_snapshot();
        let selector = self.resolve_operation_selector(input, &displays)?;
        if selector == SerializedSelector::Primary {
            return Err(BridgeError::invalid_input(
                "primary display cannot use mirror mode",
            ));
        }
        let target = self.resolve_operation_selector(target, &displays)?;
        let mut candidate = self.operation_app().normalized(&displays);
        candidate.validate_mirror_change(&selector, &target)?;
        let block = candidate.ensure_monitor(selector);
        block.enabled = true;
        block.mode = "mirror".to_owned();
        block.mirror_target = Some(target);
        let rows = self.operation_candidate_rows(&candidate, &displays);
        self.validate_operation_mirrors(&candidate, &displays)?;
        Ok((candidate, rows))
    }

    fn prepare_mirror_control(
        &self,
        input: &str,
        control: MirrorControl,
    ) -> Result<
        (
            AppConfig,
            SerializedSelector,
            Vec<DisplaySnapshotEntry>,
            u32,
        ),
        BridgeError,
    > {
        match control {
            MirrorControl::ScalingFactor(factor) if !factor.is_finite() || factor <= 0.0 => {
                return Err(BridgeError::invalid_input(
                    "scaling factor must be greater than 0",
                ));
            }
            MirrorControl::Volume(volume) if !(0.0..=1.0).contains(&volume) => {
                return Err(BridgeError::invalid_input(
                    "mirror volume must be between 0 and 1",
                ));
            }
            _ => {}
        }
        let displays = self.operation_engine().display_snapshot();
        let selector = self.resolve_operation_selector(input, &displays)?;
        let mut candidate = self.operation_app().normalized(&displays);
        let block = candidate
            .monitors
            .iter()
            .find(|block| block.selector == selector)
            .ok_or_else(|| BridgeError::invalid_input("unknown mirror display"))?;
        if !block.enabled || !block.mode.eq_ignore_ascii_case("mirror") {
            return Err(BridgeError::invalid_input(
                "display is not configured for mirror mode",
            ));
        }
        let refresh = if matches!(control, MirrorControl::TargetFps(_)) {
            let source = self.operation_source_id(&selector, &displays)?;
            displays
                .iter()
                .find(|display| display.desc.display_id == source)
                .map(|display| display.desc.refresh_rate_hz.max(1))
                .ok_or_else(|| BridgeError::invalid_input(format!("unknown display id {source}")))?
        } else {
            1
        };
        let index = match candidate
            .monitor_settings
            .iter()
            .position(|settings| settings.selector == selector)
        {
            Some(index) => index,
            None => {
                let index = candidate.monitor_settings.len();
                candidate.monitor_settings.push(MonitorSettingsCfg {
                    selector: selector.clone(),
                    ..MonitorSettingsCfg::default()
                });
                index
            }
        };
        let settings = &mut candidate.monitor_settings[index];
        match control {
            MirrorControl::ScalingMode(mode) => {
                settings.scaling_mode = core_scaling_mode(mode).to_string();
            }
            MirrorControl::ScalingFactor(factor) => settings.scaling_factor = factor,
            MirrorControl::TargetFps(fps) => settings.frame_rate = stored_frame_rate(fps, refresh),
            MirrorControl::Volume(volume) => settings.volume = volume,
            MirrorControl::Muted(muted) => settings.muted = muted,
        }
        let live_fps = if matches!(control, MirrorControl::TargetFps(_)) {
            self.live_target_fps(settings.fps_on(refresh))
        } else {
            1
        };
        Ok((candidate, selector, displays, live_fps))
    }
}
