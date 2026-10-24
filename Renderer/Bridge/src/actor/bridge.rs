#[cfg(test)]
pub(crate) mod lifecycle_test_support;
#[cfg(test)]
mod operation_test_access;
mod operation_access;
mod operations;

use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fs,
    sync::Arc,
};

use kameo::{
    actor::WeakActorRef,
    error::SendError,
    message::{Context, Message},
    reply::DelegatedReply,
};
use wallpaper_core::{
    DisplaySnapshotEntry, PropertyPreview,
    SceneResolution, WallpaperAssignment,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SerdeValudeExt},
    render::{
        RendererCounterKind, RendererSharedCounterKind, RendererSurfaceCounters, shared_value,
    },
};

use crate::{
    actor::{
        fixture_values,
        messages::{
            self, AudioRequirementChanged, Bootstrap,
            ClearShaderCache,
            CompleteAudioResponse, EditProperty,
            GetAllSnapshots, GetAppSnapshot, GetLibrarySnapshot, GetLockScreenScenes, GetWallpaperPreview,
            GetMonitorInformationSnapshot, GetSettingsSnapshot, GetWallpaperOptionsSnapshot,
            GetWebWallpapers,
            InitialFrameReady, InjectDisplayForTest, InjectSceneProjectForTest,
            InjectSceneWallpaperConfigForTest, InjectWallpaperForTest, PollMousePosition,
            GetNativeVideoWallpapers, RefreshDisplays, RefreshLibrary,
            PreviewDisplayPosition, PreviewWallpaperProperties, ReleaseHeldWallpaper,
            RendererCounters,
            ReplaceLibraryForTest,
            ReplaceWallpaperConfigForTest, RestoreAllPropertyDefaults, RestorePropertyDefault,
            SelectWallpaper,
            SetAudioResponseEnabled, SetBatteryQualityProfile,
            SetDisplayConfigEnabled, SetDisplayPosition,
            SetDisplayParkedWallpapers, SetDisplayPresentationSuspended,
            FanOutSystemMediaArtwork, FanOutSystemMediaEvent, GetSystemMediaConsentHandles,
            GetSystemMediaSceneHandles, SetFilter,
            SetFrameRateCap, SetGlobalPlayback, SetQualityThrottle,
            SetLaunchAtLogin, SetMediaIntegrationEnabled,
            SetMuted, SetAudioSuppressed, SetBatteryMode, SetLabelLanguages, SetPowerSource,
            SetPresentationSuspended, SetPresentationUnloaded, SetPropertyPath,
            SetRenderScale,
            SetRendererCountersEnabled, SetScalingFactor, SetScalingMode,
            SetSceneOnDemandEnabled, SetSceneOptimizationEnabled,
            SetSceneResolution, SetSceneVideoPlaneSamplingEnabled,
            SetTargetFps, SetVerboseLogging, SetVolume, SetWebAudioSubscribed,
            Shutdown,
        },
        state::BridgeActorState,
        transport::BridgeActorHandle,
    },
    api::{
        BridgeAppSnapshot, BridgeDisplayMutationBundle,
        BridgeError, BridgeLibrarySnapshot,
        BridgeLockScreenScene, BridgeNativeVideoWallpaper, BridgePlaybackState,
        BridgePropertyEdit, FirstFrameDelivery, FirstFrameTarget,
        BridgeRendererCountersReport, BridgeRendererSurfaceCounters, BridgeScalingMode,
        BridgeSnapshotBundle, BridgeWallpaperKind,
        BridgeWallpaperMutationBundle, BridgeWallpaperPreview, BridgeWebWallpaper, MousePollingControl,
    },
    config::{
        ConfigStore, FramingCfg, SceneResolutionCfg,
        SerializedSelector, WallpaperConfig,
    },
    display::{DisplaySelectorExt, DisplaySnapshotExt},
    engine::{
        ActivationInputs, AudioCaptureDemand, EngineFacade, LoadJournal,
    },
    library::scan,
    login::LaunchAtLoginController,
    paths::BridgePaths,
    project::{
        DirectoryMode, FileMedia, ProjectModel, ProjectProperty, PropertyKind, PropertyMetadata,
        PropertyValue,
    },
    state::drafts::{moved_framing, saved_framing},
};

const MIRROR_DISPLAY_MODE: &str = "mirror";

#[derive(kameo::Actor)]
pub struct BridgeActor<E: EngineFacade> {
    pub state: BridgeActorState,
    operation_state: operations::OperationState,
    pending_audio_changes: HashSet<String>,
    #[allow(dead_code)]
    pub engine: E,
    #[allow(dead_code)]
    pub config_store: Option<ConfigStore>,
    launch_at_login: LaunchAtLoginController,
    paths: BridgePaths,
    mouse_polling: Arc<MousePollingControl>,
    /// Which wallpapers were being opened, so one that killed the app twice
    /// in a row is held back. See [`LoadJournal`].
    load_journal: LoadJournal,
    /// Scenes a position drag has shown at a position nobody committed, so
    /// that finishing the drag back where it began still puts the renderer on
    /// the saved position instead of being skipped as already held.
    previewed_framing: HashSet<SceneHandle>,
    /// Wallpapers whose scenes may be showing pending property edits nobody
    /// saved, so that a cancelled edit still puts the saved look back. It says
    /// only that a scene may show something, never what: which scenes show which
    /// document is the engine's to know, because it owns the renderers and
    /// replaces them. A reconcile, a shader cache clear and a recovery after a
    /// wake or a failed frame all load scenes again without this actor being
    /// told, so a copy of the last document kept here goes stale; the engine
    /// skips a document a scene already shows and sends it to one that does not.
    /// A mark outlives a rebuild harmlessly: the saved look it then puts back
    /// is the one the scene shows. A wallpaper without a mark shows its saved
    /// look.
    previewed_properties: HashSet<String>,
}

enum PlaybackChangeOrigin {
    Manual,
    Power,
}


pub(crate) struct WeakFirstFrameTarget<E: EngineFacade + Clone> {
    actor: WeakActorRef<BridgeActor<E>>,
}

impl<E: EngineFacade + Clone> FirstFrameTarget for WeakFirstFrameTarget<E> {
    async fn deliver(&self, _handle: SceneHandle) -> FirstFrameDelivery {
        let Some(actor) = self.actor.upgrade() else {
            return FirstFrameDelivery::TargetGone;
        };
        match actor.ask(InitialFrameReady).await.map_err(map_send_error) {
            Ok(_) => FirstFrameDelivery::Delivered,
            Err(error) => FirstFrameDelivery::Failed(error),
        }
    }
}


pub(super) fn assemble_actor<E: EngineFacade>(
    state: BridgeActorState,
    engine: E,
    config_store: Option<ConfigStore>,
    launch_at_login: LaunchAtLoginController,
    paths: BridgePaths,
    mouse_polling: Arc<MousePollingControl>,
    load_journal: LoadJournal,
) -> BridgeActor<E> {
    let actor = BridgeActor {
        state,
        operation_state: operations::OperationState::default(),
        pending_audio_changes: HashSet::new(),
        engine,
        config_store,
        launch_at_login,
        paths,
        mouse_polling,
        load_journal,
        previewed_framing: HashSet::new(),
        previewed_properties: HashSet::new(),
    };
    actor.refresh_mouse_polling_policy();
    actor
}

impl<E: EngineFacade + Clone> BridgeActorHandle<E> {
    pub(crate) fn first_frame_handoff_inputs(
        &self,
    ) -> Result<(tokio::runtime::Handle, crate::actor::WeakFirstFrameTarget<E>), BridgeError> {
        Ok((
            self.runtime_handle()?,
            WeakFirstFrameTarget {
                actor: self.weak_actor(),
            },
        ))
    }

    /// The sink for the engine's audio-requirement changes. The engine calls
    /// it under a lock on its actor thread, so it only records the handle and
    /// wakes one task on this actor's runtime, which asks the actor to re-sync
    /// capture. Coalescing: a burst of reports is one delivery, and the
    /// pending set is bounded by the number of live scenes. Nothing polls.
    pub(crate) fn audio_requirement_relay(&self) -> Option<wallpaper_core::AudioRequirementCallback> {
        let runtime = self.runtime_handle().ok()?;
        let pending = Arc::new(std::sync::Mutex::new(HashSet::<SceneHandle>::new()));
        let notify = Arc::new(tokio::sync::Notify::new());
        // Weak, so the relay never keeps the actor (or its runtime) alive.
        let actor = self.weak_actor();
        let task_pending = Arc::clone(&pending);
        let task_notify = Arc::clone(&notify);
        let _task = runtime.spawn(async move {
            loop {
                task_notify.notified().await;
                let handles: Vec<SceneHandle> = std::mem::take(
                    &mut *task_pending.lock().unwrap_or_else(|error| error.into_inner()),
                )
                .into_iter()
                .collect();
                if handles.is_empty() {
                    continue;
                }
                let Some(actor) = actor.upgrade() else { break };
                if let Err(error) = actor.ask(AudioRequirementChanged { handles }).await {
                    log::warn!("could not re-sync system audio capture: {error}");
                }
            }
        });
        Some(Arc::new(move |handle, _requires_audio| {
            let _ = pending
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .insert(handle);
            notify.notify_one();
        }))
    }
}

/// Whether the scene shown on `scene`'s display reads system audio, as its
/// renderer reports. A display without a live renderer has nothing to read.
fn scene_reads_audio<E: EngineFacade>(
    engine: &E,
    displays: &[DisplaySnapshotEntry],
    scene: &SceneDesc,
) -> bool {
    displays
        .iter()
        .find(|display| display.desc.display_id == scene.display.display_id)
        .and_then(|display| display.handle)
        .is_some_and(|handle| engine.scene_requires_audio(handle))
}

/// Registers one scene as a system-audio consumer: the user's audio-response
/// setting AND the renderer's report that the loaded scene reads audio. Pause
/// is not part of this: it is the global `set_audio_capture_demand` gate,
/// which every pause and resume path already re-evaluates, whereas a paused
/// registration would have to be re-made on every resume.
///
/// The renderer reports on its own thread, and the actor re-registers the
/// scene when it does, possibly before this call lands with an older value.
/// Re-reading after each registration keeps a stale value from winning; it
/// settles because a scene's requirement only changes on its renderer's report.
///
/// Only the capture waits for the report. The scene's own audio-response
/// switch follows the setting: the renderer already feeds nothing to a scene
/// that reads no audio, and a switch that disagreed with the setting would
/// leave the scene's descriptor looking like a different wallpaper to every
/// later reconcile, which then reloads it.
async fn register_audio_capture<E: EngineFacade>(
    engine: &E,
    handle: SceneHandle,
    response_enabled: bool,
) -> Result<(), wallpaper_core::EngineError> {
    let mut capture = response_enabled && engine.scene_requires_audio(handle);
    loop {
        engine.set_audio_capture_enabled(handle, capture).await?;
        let current = response_enabled && engine.scene_requires_audio(handle);
        if current == capture {
            break;
        }
        capture = current;
    }
    // A scene that went away has had its capture released above and has no
    // switch left to set.
    if !capture
        && !engine
            .display_snapshot()
            .iter()
            .any(|display| display.handle == Some(handle))
    {
        return Ok(());
    }
    if let Err(error) = engine.set_audio_response_enabled(handle, response_enabled).await {
        if capture {
            let _ = engine.set_audio_capture_enabled(handle, false).await;
        }
        return Err(error);
    }
    Ok(())
}

/// The error a failed engine call reaches the caller as.
fn engine_failed(error: wallpaper_core::EngineError) -> BridgeError {
    BridgeError::engine(error.to_string())
}

fn map_send_error<M>(error: SendError<M, BridgeError>) -> BridgeError {
    match error {
        SendError::HandlerError(error) => error,
        other => BridgeError::engine(other.to_string()),
    }
}

/// Web pages that are registered audio listeners and are in a position to hear
/// anything: their wallpaper has audio response on and their own display is
/// not paused.
///
/// A page that never registered a listener is not a consumer no matter what
/// its wallpaper's settings say, which is what keeps the tap shut for the
/// common case of a web wallpaper that does not use audio at all.
fn web_audio_consumers(
    inputs: &ActivationInputs<'_>,
    subscribers: &BTreeMap<String, BTreeSet<u32>>,
) -> u32 {
    if subscribers.is_empty() {
        return 0;
    }
    let Ok(web) = inputs.build_web() else {
        return 0;
    };

    u32::try_from(
        web.iter()
            .filter(|desc| desc.audio_response_enabled && !desc.paused)
            .filter(|desc| {
                subscribers
                    .get(&desc.wallpaper_id)
                    .is_some_and(|displays| displays.contains(&desc.display.display_id))
            })
            .count(),
    )
    .unwrap_or(u32::MAX)
}

/// Adds the authored kind, and the file/directory options, beside a property's
/// value in an `applyUserProperties` payload.
///
/// Wallpaper Engine passes the property type through to the page, and a page
/// cannot act on a file or directory property without it: the value alone says
/// nothing about whether to screen extensions, nor whether the directory is
/// pulled from on demand or pushed wholesale.
fn describe_property_kind(
    property: &ProjectProperty,
    entry: &mut serde_json::Map<String, serde_json::Value>,
) {
    let kind = match &property.kind {
        PropertyKind::Slider => "slider",
        PropertyKind::Combo => "combo",
        PropertyKind::Bool => "bool",
        PropertyKind::Color => "color",
        PropertyKind::TextInput => "textinput",
        PropertyKind::Text => "text",
        PropertyKind::Group => "group",
        PropertyKind::File => "file",
        PropertyKind::Directory => "directory",
        PropertyKind::Texture => "texture",
        PropertyKind::Unknown(raw) => raw.as_str(),
    };
    let _ = entry.insert(
        "type".to_string(),
        serde_json::Value::String(kind.to_string()),
    );

    let (filter, mode) = match &property.metadata {
        PropertyMetadata::File { filter } => (Some(filter), None),
        PropertyMetadata::Directory { filter, mode } => (Some(filter), Some(*mode)),
        _ => return,
    };
    // Absent when the project declared nothing, so a page can tell "any file"
    // from a filter this build happened to fall back to.
    if filter.is_some_and(|filter| filter.raw.is_some()) {
        let media = match filter.map(|filter| filter.media) {
            Some(FileMedia::Video) => "video",
            _ => "image",
        };
        let _ = entry.insert(
            "fileFilter".to_string(),
            serde_json::Value::String(media.to_string()),
        );
    }
    if let Some(mode) = mode {
        let mode = match mode {
            DirectoryMode::FetchAll => "fetchall",
            DirectoryMode::OnDemand => "ondemand",
        };
        let _ = entry.insert(
            "mode".to_string(),
            serde_json::Value::String(mode.to_string()),
        );
    }
}

impl<E: EngineFacade> BridgeActor<E> {
    /// Conditions that stop every display at once. Per-display occlusion is in
    /// `state.suspended_displays` and is composed on top of this.
    fn playback_paused(&self) -> bool {
        self.state.presentation_suspended
            || self.state.playback_state == crate::api::BridgePlaybackState::Paused
    }

    /// True when no connected display can present: either a global reason, or
    /// every connected display suspended on its own.
    fn every_display_paused(&self) -> bool {
        if self.playback_paused() {
            return true;
        }
        if self.state.suspended_displays.is_empty() {
            return false;
        }
        let displays = self.engine.display_snapshot();
        !displays.is_empty()
            && displays.iter().all(|entry| {
                self.state
                    .suspended_displays
                    .contains(&entry.desc.display_id)
            })
    }

    fn refresh_mouse_polling_policy(&self) {
        self.mouse_polling
            .set_policy_enabled(!self.every_display_paused());
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    fn app_snapshot(&self) -> BridgeAppSnapshot {
        BridgeAppSnapshot {
            playback_state: self.state.playback_state,
            selected_wallpaper_id: self.state.selected_wallpaper_id.clone(),
            active_wallpaper_ids: self.state.active_wallpaper_ids.clone(),
            errors: self.state.errors.clone(),
            held_wallpaper_ids: self.state.held_assigned_ids(),
        }
    }

    fn library_snapshot(&self) -> BridgeLibrarySnapshot {
        crate::actor::projection_values::library_snapshot(
            &self.state.library,
            self.state.selected_wallpaper_id.as_deref(),
            &self.state.active_wallpaper_ids,
            |kind| self.state.filter_enabled(kind),
        )
    }

    fn all_snapshots(&self) -> BridgeSnapshotBundle {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        BridgeSnapshotBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: self
                .state
                .selected_wallpaper_id
                .as_ref()
                .and_then(|id| self.state.options(&displays, id.clone(), &self.paths).ok()),
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, &self.engine.scene_runtime_reports()),
        }
    }

    /// Everything the panel shows, with the options of `wallpaper_id`. Unlike
    /// `all_snapshots`, a wallpaper whose options cannot be built fails the call.
    fn snapshots_with_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        // The engine and the login item are each read once for the whole bundle.
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        let options = self.state.options(&displays, wallpaper_id, &self.paths)?;
        let reports = self.engine.scene_runtime_reports();
        let settings = self.state.settings(&displays, launch_at_login, &self.paths, &reports);
        Ok(BridgeSnapshotBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: Some(options),
            monitor_information: self.state.monitor_info(&displays),
            settings,
        })
    }

    fn wallpaper_bundle(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        Ok(BridgeWallpaperMutationBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: self.state.options(&displays, wallpaper_id, &self.paths)?,
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, &self.engine.scene_runtime_reports()),
        })
    }

    fn display_bundle(&self) -> BridgeDisplayMutationBundle {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        BridgeDisplayMutationBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, &self.engine.scene_runtime_reports()),
        }
    }

    /// Shows a scene wallpaper's pending property edits on every scene that
    /// draws it, or with `show` false puts the saved look back on them.
    ///
    /// Only the renderers change. Nothing is saved, the draft and the
    /// generation stay as they are and the lock-screen export, which follows
    /// the saved configuration, does not move, so an editor can call this after
    /// every edit. A wallpaper that is not being previewed and whose document is
    /// the saved one is left alone, because its scenes show it already.
    ///
    /// Everything else is asked of the engine, which answers for each scene.
    /// The bridge keeps no copy of what a scene shows: that goes stale the
    /// moment anything loads the scene again, and most things that do never pass
    /// through here. The engine skips a scene that already shows the document,
    /// sends it to one that does not, and declines one that draws another
    /// wallpaper. That last answer is what keeps a document from reaching the
    /// wrong scene. The handles come from the committed configuration, and a
    /// reconcile that moves a display to another wallpaper commits it only after
    /// it has finished, so for that long a handle still found for this wallpaper
    /// can be running the next one.
    ///
    /// A scene that takes the update and a scene that refuses it can both be
    /// among the wallpaper's scenes, so a refusal leaves the wallpaper marked as
    /// possibly previewed, which makes the next call ask again.
    async fn show_wallpaper_properties(
        &mut self,
        wallpaper_id: &str,
        show: bool,
        pending: Vec<BridgePropertyEdit>,
    ) -> Result<(), BridgeError> {
        let Some(documents) = self
            .state
            .pending_property_documents(wallpaper_id, pending)?
        else {
            return Ok(());
        };
        let shown = if show {
            documents.shown
        } else {
            documents.saved.clone()
        };
        if shown == documents.saved && !self.previewed_properties.contains(wallpaper_id) {
            return Ok(());
        }
        let handles = self.wallpaper_handles(wallpaper_id, true);
        if handles.is_empty() {
            // Nothing draws it, and a scene opened later is loaded from what
            // is saved.
            self.previewed_properties.remove(wallpaper_id);
            return Ok(());
        }
        self.previewed_properties.insert(wallpaper_id.to_string());
        let scene_path = self
            .paths
            .project_json(wallpaper_id)
            .to_string_lossy()
            .into_owned();
        let mut drawn = false;
        for handle in handles {
            let outcome = self
                .engine
                .preview_property_override(handle, scene_path.clone(), shown.clone())
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
            drawn |= outcome == PropertyPreview::Shown;
        }
        // A scene the engine declined no longer draws this wallpaper, so there
        // is nothing on it to show or to put back; with none left, no scene
        // shows an edit of it.
        if shown == documents.saved || !drawn {
            self.previewed_properties.remove(wallpaper_id);
        }
        Ok(())
    }

    fn wallpaper_handles(&self, wallpaper_id: &str, include_mirrors: bool) -> Vec<SceneHandle> {
        let displays = self.engine.display_snapshot();
        let mut handles = Vec::new();
        let mut used_display_ids = Vec::new();

        for monitor in self.state.app_config.monitors.iter().filter(|monitor| {
            monitor.enabled
                && (if monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE) {
                    include_mirrors && monitor
                            .mirror_target
                            .as_ref()
                            .is_some_and(|target| self.target_has_wallpaper(target, wallpaper_id))
                } else {
                    monitor.wallpaper.as_deref() == Some(wallpaper_id)
                })
        }) {
            let Some(snapshot) = monitor.selector.to_selector().resolve_display(&displays) else {
                continue;
            };
            let Some(handle) = snapshot.handle else {
                continue;
            };
            if used_display_ids.contains(&snapshot.desc.display_id) {
                continue;
            }

            handles.push(handle);
            used_display_ids.push(snapshot.desc.display_id);
        }

        handles
    }

    fn target_has_wallpaper(&self, selector: &SerializedSelector, wallpaper_id: &str) -> bool {
        self.state.app_config.monitors.iter().any(|monitor| {
            monitor.enabled
                && !monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE)
                && monitor.wallpaper.as_deref() == Some(wallpaper_id)
                && monitor.selector == *selector
        })
    }

    async fn set_playback(
        &mut self,
        playback_state: BridgePlaybackState,
        origin: PlaybackChangeOrigin,
    ) -> Result<(), BridgeError> {
        let previous = self.state.playback_state;
        let previous_paused = self.playback_paused();
        self.state.playback_state = playback_state;
        if let Err(error) = self.apply_engine_pause(previous_paused).await {
            self.state.playback_state = previous;
            return Err(error);
        }
        match origin {
            PlaybackChangeOrigin::Manual => {
                if playback_state == BridgePlaybackState::Playing
                    && self.state.power_source == crate::power::PowerSource::Battery
                {
                    self.state.auto_paused_for_battery = false;
                    self.state.battery_pause_suppressed = true;
                } else if playback_state == BridgePlaybackState::Paused {
                    self.state.auto_paused_for_battery = false;
                }
            }
            PlaybackChangeOrigin::Power => {}
        }
        self.invalidate_operations();
        Ok(())
    }


    /// Every open scene handle, once each.
    #[allow(clippy::single_call_fn)]
    fn open_scene_handles(&self) -> Vec<SceneHandle> {
        let mut handles = Vec::new();
        for entry in self.engine.display_snapshot() {
            let Some(handle) = entry.handle else {
                continue;
            };
            if !handles.contains(&handle) {
                handles.push(handle);
            }
        }
        handles
    }

    /// Pushes the render scale that is in force to every open scene.
    ///
    /// Set as a live renderer property, one open scene at a time. Going
    /// through a reconcile instead would reparse every project and reopen
    /// every video for what is a quality control the user drags.
    async fn apply_effective_render_scale(&self) -> Result<(), BridgeError> {
        let scale = self.effective_render_scale();
        for handle in self.open_scene_handles() {
            self.engine
                .set_render_scale(handle, scale)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }

    fn effective_render_scale(&self) -> f32 {
        self.state
            .app_config
            .effective_render_scale(self.state.quality_in_force())
    }

    /// The frame-rate ceiling in force: the global cap, the reduced-quality
    /// profile's rate while the battery mode or a quality throttle holds it, or
    /// the stricter of the two.
    fn active_target_fps_cap(&self) -> Option<u32> {
        self.state.active_target_fps_cap()
    }

    /// Saved rate, never above the ceiling currently in force.
    fn live_target_fps(&self, rate: u32) -> u32 {
        capped_frame_rate(rate, self.active_target_fps_cap())
    }

    /// Puts the quality settings the current power source and any quality
    /// throttle call for into effect on everything already running.
    ///
    /// Restoring hands back the user's own saved per-display target rate, read
    /// from the live configuration rather than from a remembered constant.
    /// It never touches playback, so a pause the user asked for survives.
    ///
    /// Every change that moves the frame-rate ceiling ends here (the cap, the
    /// profile, the battery mode, the power source, a throttle), so this is
    /// where a native video whose refusal described the old ceiling is handed
    /// back, not in each of them.
    async fn apply_quality_profile(&mut self) -> Result<(), BridgeError> {
        self.apply_effective_render_scale().await?;
        let cap = self.active_target_fps_cap();
        let throttle = self
            .state
            .quality_throttle
            .iter()
            .map(|cause| format!("{cause:?}"))
            .collect::<Vec<_>>();
        log::info!(
            "quality profile in force: frame-rate ceiling {}, render scale {}, throttle {}",
            cap.map_or_else(|| "none".to_string(), |cap| format!("{cap} fps")),
            self.effective_render_scale(),
            if throttle.is_empty() {
                "none".to_string()
            } else {
                throttle.join(", ")
            }
        );
        let displays = self.engine.display_snapshot();
        let rates = self
            .activation_inputs(&displays, self.playback_paused())
            .target_frame_rates();
        for entry in &displays {
            let Some(handle) = entry.handle else {
                continue;
            };
            let Some(configured) = rates.get(&entry.desc.display_id).copied() else {
                continue;
            };
            let fps = cap.map_or(configured, |cap| configured.min(cap)).max(1);
            self.engine
                .set_fps(handle, fps)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }

    async fn apply_power_policy(&mut self) -> Result<(), BridgeError> {
        let mode = self.state.app_config.power.on_battery;
        // Reduced quality is the only mode whose running scale and rate follow
        // the power source. Keep running and pause must not restate a rate the
        // user did not ask to change. A global frame-rate cap is independent
        // of the power source and is applied when it is set.
        if mode == crate::config::BatteryModeCfg::ReducedQuality {
            self.apply_quality_profile().await?;
        }
        if mode != crate::config::BatteryModeCfg::Pause {
            self.state.battery_pause_suppressed = false;
            self.state.pending_battery_pause_after_initial_frame = false;
            // Leaving pause, or a power sample that arrives after it was left,
            // has to resume a pause this policy asked for. Clearing the flag
            // first is what used to leave playback paused.
            if self.state.auto_paused_for_battery {
                log::info!("resuming wallpaper playback; pause on battery is no longer in force");
                self.set_playback(BridgePlaybackState::Playing, PlaybackChangeOrigin::Power)
                    .await?;
                self.state.auto_paused_for_battery = false;
            }
            return Ok(());
        }

        use crate::power::PowerSource;
        match self.state.power_source {
            PowerSource::Unknown => return Ok(()),
            PowerSource::External => {
                self.state.battery_pause_suppressed = false;
                self.state.pending_battery_pause_after_initial_frame = false;
                if self.state.auto_paused_for_battery {
                    log::info!("back on external power: resuming wallpaper playback");
                    self.set_playback(BridgePlaybackState::Playing, PlaybackChangeOrigin::Power)
                        .await?;
                    self.state.auto_paused_for_battery = false;
                }
                return Ok(());
            }
            PowerSource::Battery => {}
        }
        let already_paused = self.state.playback_state != BridgePlaybackState::Playing;
        if already_paused || self.state.battery_pause_suppressed {
            return Ok(());
        }
        if self.state.pending_battery_pause_after_initial_frame {
            // The pause waits for the first frame; the pending flag says so.
            return Ok(());
        }
        log::info!("on battery power: pausing wallpaper playback");
        self.set_playback(BridgePlaybackState::Paused, PlaybackChangeOrigin::Power)
            .await?;
        self.state.auto_paused_for_battery = true;
        Ok(())
    }

    /// The scene a saved independent monitor shows `wallpaper_id` on, if the
    /// display is connected and has one.
    fn display_handle(
        &self,
        wallpaper_id: &str,
        selector: &SerializedSelector,
    ) -> Option<SceneHandle> {
        let displays = self.engine.display_snapshot();
        let monitor = self.state.app_config.monitors.iter().find(|monitor| {
            monitor.enabled
                && !monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE)
                && monitor.wallpaper.as_deref() == Some(wallpaper_id)
                && monitor.selector == *selector
        })?;
        monitor
            .selector
            .to_selector()
            .resolve_display(&displays)
            .and_then(|display| display.handle)
    }

    /// The scene of the mirror monitor saved for `selector`, looked up in
    /// `displays`.
    fn mirror_display_handle(
        &self,
        selector: &SerializedSelector,
        displays: &[DisplaySnapshotEntry],
    ) -> Option<SceneHandle> {
        let monitor = self.state.app_config.monitors.iter().find(|monitor| {
            monitor.enabled
                && monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE)
                && monitor.selector == *selector
        })?;
        monitor
            .selector
            .to_selector()
            .resolve_display(displays)
            .and_then(|display| display.handle)
    }

    fn save_wallpaper(
        &mut self,
        wallpaper_id: String,
        config: WallpaperConfig,
    ) -> Result<(), BridgeError> {
        if let Some(store) = &self.config_store {
            store.save_wallpaper(&config)?;
        }
        self.state.wallpaper_configs.insert(wallpaper_id, config);
        Ok(())
    }

    fn refresh_library(&mut self) -> Result<(), BridgeError> {
        let workshop_root = self.paths.steam_workshop_root();
        let entries = scan(&workshop_root)?;
        let project_models = entries
            .iter()
            .filter_map(|entry| {
                let project_json = workshop_root.join(&entry.workshop_id).join("project.json");
                ProjectModel::load(&entry.workshop_id, project_json)
                    .ok()
                    .map(|model| (entry.workshop_id.clone(), model))
            })
            .inspect(|(id, model)| {
                let unreadable = model.unreadable_condition_count();
                if unreadable > 0 {
                    log::info!(
                        "wallpaper {id}: {unreadable} property visibility rule(s) could not be read; those properties stay visible"
                    );
                }
            })
            .collect();
        self.state.replace_library(
            entries
                .iter()
                .map(crate::api::BridgeWallpaperEntry::from)
                .collect(),
        );
        self.state.project_models = project_models;
        self.state.library_scanned = true;
        Ok(())
    }

    fn load_wallpapers(&mut self) -> Result<(), BridgeError> {
        let Some(store) = &self.config_store else {
            return Ok(());
        };
        let missing_ids = self
            .state
            .configured_ids()
            .iter()
            .filter(|id| !self.state.wallpaper_configs.contains_key(*id))
            .cloned()
            .collect::<Vec<_>>();
        let loaded = missing_ids
            .iter()
            .map(|id| store.load_wallpaper(id).map(|config| (id.clone(), config)))
            .collect::<Result<Vec<_>, _>>()?;

        for (id, config) in loaded {
            self.state.wallpaper_configs.insert(id, config);
        }
        Ok(())
    }

    async fn refresh_displays(&mut self) -> Result<(), BridgeError> {
        self.engine
            .refresh_displays()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.refresh_mouse_polling_policy();
        self.sync_displays()
    }

    fn sync_displays(&mut self) -> Result<(), BridgeError> {
        let displays = self.engine.display_snapshot();
        let mut next = self.state.app_config.clone();
        if !next.sync_known_monitors(&displays) {
            return Ok(());
        }

        if let Some(store) = &self.config_store {
            store.save_app_config(&next)?;
        }
        self.state.app_config = next;
        self.state.rebase_drafts();
        Ok(())
    }

    /// Learns which wallpapers the previous sessions died while opening and
    /// leaves them out of every plan from here on.
    ///
    /// Runs once per launch, after the library is known and before anything is
    /// opened. The panel learns about a held wallpaper that is assigned to a
    /// display from [`BridgeAppSnapshot::held_wallpaper_ids`], since that
    /// display will not show it until the user retries it.
    fn hold_back_crashing_wallpapers(&mut self) {
        if let Some(library) = self.state.scanned_library() {
            // A hold must not outlive the files it is about.
            let installed = library.iter().map(|entry| entry.id.clone()).collect();
            self.load_journal.prune(&installed);
        }
        self.state.held_wallpapers = self.load_journal.held();
        for id in &self.state.held_wallpapers {
            log::warn!("load journal: holding {id}");
        }
    }

    fn activation_inputs<'a>(
        &'a self,
        displays: &'a [DisplaySnapshotEntry],
        paused: bool,
    ) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config: &self.state.app_config,
            wallpapers: &self.state.wallpaper_configs,
            library: self.state.scanned_library(),
            displays,
            paused,
            suspended_displays: &self.state.suspended_displays,
            paths: &self.paths,
            force_shader_refresh: false,
            project_models: &self.state.project_models,
            frame_rate_cap: self.active_target_fps_cap(),
            audio_suppressed: self.state.audio_suppressed,
            held: &self.state.held_wallpapers,
        }
    }

    /// Committed plain-video wallpapers, played by the host's own player. Empty only while
    /// presentation is unloaded.
    fn native_video_wallpapers(&self) -> Result<Vec<BridgeNativeVideoWallpaper>, BridgeError> {
        if self.state.presentation_unloaded {
            return Ok(Vec::new());
        }
        let displays = self.engine.display_snapshot();
        self.activation_inputs(&displays, self.playback_paused())
            .build_native_video()?
            .into_iter()
            .map(|desc| {
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == desc.wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default();
                let media_path = desc
                    .media_path
                    .into_os_string()
                    .into_string()
                    .map_err(|_| {
                        BridgeError::invalid_input("video wallpaper path is not UTF-8")
                    })?;
                Ok(BridgeNativeVideoWallpaper {
                    display_id: desc.display.display_id,
                    startup_revision: self.reserved_startup_revision(),
                    wallpaper_id: desc.wallpaper_id,
                    title,
                    media_path,
                    admission_key: desc.admission_key,
                    framing: desc.framing.into(),
                    paused: desc.paused,
                    volume: desc.volume,
                    muted: desc.muted,
                    scaling_mode: BridgeScalingMode::from(desc.scaling_mode),
                    scaling_factor: desc.scaling_factor,
                })
            })
            .collect()
    }

    fn web_properties_json(
        &self,
        wallpaper_id: &str,
        properties: &BTreeMap<String, PropertyValue>,
    ) -> String {
        let model = self.state.project_models.get(wallpaper_id);
        let properties = properties
            .iter()
            .map(|(id, value)| {
                let mut entry = serde_json::Map::new();
                if let Some(property) = model.and_then(|model| {
                    model.properties.iter().find(|property| property.id == *id)
                }) {
                    let _ = entry.insert("value".to_string(), property.web_value(value));
                    describe_property_kind(property, &mut entry);
                } else {
                    let _ = entry.insert("value".to_string(), value.to_json());
                }
                (id.clone(), serde_json::Value::Object(entry))
            })
            .collect::<serde_json::Map<_, _>>();
        serde_json::Value::Object(properties).to_string()
    }

    fn web_wallpapers(&self) -> Result<Vec<BridgeWebWallpaper>, BridgeError> {
        if self.state.presentation_unloaded {
            return Ok(Vec::new());
        }
        let displays = self.engine.display_snapshot();
        self.activation_inputs(&displays, self.playback_paused())
            .build_web()?
            .into_iter()
            .map(|desc| {
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == desc.wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default();
                let project_path = std::path::absolute(&desc.project_dir)
                    .map_err(|error| BridgeError::Error {
                        kind: crate::api::BridgeErrorKind::Io,
                        message: error.to_string(),
                    })?
                    .into_os_string()
                    .into_string()
                    .map_err(|_| BridgeError::invalid_input("web wallpaper path is not UTF-8"))?;
                let properties_json =
                    self.web_properties_json(&desc.wallpaper_id, &desc.properties);
                let media_integration_enabled = self
                    .state
                    .wallpaper_configs
                    .get(&desc.wallpaper_id)
                    .map_or(crate::config::MEDIA_INTEGRATION_DEFAULT, |config| {
                        config.media_integration_enabled
                    });
                Ok(BridgeWebWallpaper {
                    display_id: desc.display.display_id,
                    startup_revision: self.reserved_startup_revision(),
                    display_key: desc.display_key,
                    audio_source_display_id: desc.audio_source_display_id,
                    wallpaper_id: desc.wallpaper_id,
                    title,
                    project_path,
                    entry_file: desc.entry_file,
                    fps: desc.fps,
                    render_scale: self.effective_render_scale(),
                    paused: desc.paused,
                    volume: desc.volume,
                    muted: desc.muted,
                    audio_response_enabled: desc.audio_response_enabled,
                    media_integration_enabled,
                    properties_json,
                })
            })
            .collect()
    }

    fn wallpaper_preview(
        &self, wallpaper_id: &str, display_id: &str, pending: Vec<BridgePropertyEdit>,
    ) -> Result<BridgeWallpaperPreview, BridgeError> {
        use std::path::{Component, Path, PathBuf};
        let mut components = Path::new(wallpaper_id).components();
        if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
            return Err(BridgeError::invalid_input("invalid preview wallpaper identifier"));
        }
        let model = self.state.project_model(wallpaper_id)?;
        let entry = self.state.library.iter().find(|entry| entry.id == wallpaper_id)
            .ok_or_else(|| BridgeError::invalid_input("preview wallpaper is not installed"))?;
        if !entry.supported || entry.kind == BridgeWallpaperKind::Unknown {
            return Err(BridgeError::invalid_input("this wallpaper type cannot be previewed"));
        }
        let edits = model.checked_edits(pending)?;
        let draft = self.state.wallpaper_draft(wallpaper_id)?.with_edits(model, &edits);
        let config = draft.current();
        let render = config.monitors.iter().find(|render| render.selector.id() == display_id);
        let overrides = model.override_values(&config.property_overrides);
        let properties = model.properties.iter()
            .filter(|property| !matches!(property.kind, PropertyKind::Group | PropertyKind::Text))
            .map(|property| (property.id.clone(), property.effective_value(&overrides)))
            .collect::<BTreeMap<_, _>>();
        let properties_json = if entry.kind == BridgeWallpaperKind::Webpage {
            self.web_properties_json(wallpaper_id, &properties)
        } else {
            let values = properties.iter().map(|(id, value)| (id.clone(), value.to_json()))
                .collect::<serde_json::Map<_, _>>();
            let flat = serde_json::Value::Object(values).flatten()
                .map_err(|error| BridgeError::engine(error.to_string()))?;
            serde_json::to_string(&flat).map_err(|error| BridgeError::engine(error.to_string()))?
        };
        let path = |value: PathBuf| -> Result<String, BridgeError> {
            std::path::absolute(value).map_err(|error| BridgeError::engine(error.to_string()))?
                .into_os_string().into_string()
                .map_err(|_| BridgeError::invalid_input("preview path is not UTF-8"))
        };
        Ok(BridgeWallpaperPreview {
            wallpaper_id: wallpaper_id.to_string(), title: entry.title.clone(), kind: entry.kind,
            project_path: path(self.paths.steam_workshop_root().join(wallpaper_id))?,
            entry_file: model.entry_file.clone().unwrap_or_default(),
            assets_path: path(self.paths.assets_root())?, properties_json,
            fps: self.live_target_fps(render.and_then(|render| render.frame_rate).unwrap_or(30)).clamp(1, 30),
            scaling_mode: render.map(|render| render.parse_scaling_mode().into()).unwrap_or(BridgeScalingMode::Fill),
            scaling_factor: render.map_or(1.0, |render| render.scaling_factor),
            volume: config.audio.volume,
        })
    }

    fn lock_screen_scenes(&self) -> Result<Vec<BridgeLockScreenScene>, BridgeError> {
        let displays = self.engine.display_snapshot();
        // The native presentations own visibility and sleep. Export committed
        // user/power policy without transient desktop suspension or backend
        // admission, including videos currently played by the native host.
        let no_suspended_displays = BTreeSet::new();
        let inputs = ActivationInputs {
            suspended_displays: &no_suspended_displays,
            frame_rate_cap: self.active_target_fps_cap(),
            ..self.activation_inputs(&displays, self.state.playback_state == BridgePlaybackState::Paused)
        };

        // Plain videos included: the extension plays each with its own players, and holds the
        // clip with the failure when they cannot.
        let mut scenes = inputs
            .build_lock_screen()?
            .into_iter()
            .map(|mut scene| {
                let wallpaper_id = std::path::Path::new(&scene.scene_path)
                    .parent()
                    .and_then(std::path::Path::file_name)
                    .and_then(std::ffi::OsStr::to_str)
                    .ok_or_else(|| {
                        BridgeError::engine(format!(
                            "cannot identify lock-screen wallpaper from {}",
                            scene.scene_path
                        ))
                    })?
                    // Owned before the paths below are rewritten in place: the id has to
                    // outlive that mutable borrow to reach the record.
                    .to_string();
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == wallpaper_id)
                    .ok_or_else(|| BridgeError::Error {
                        kind: crate::api::BridgeErrorKind::Library,
                        message: format!(
                            "lock-screen wallpaper {wallpaper_id} is not in the library"
                        ),
                    })?
                    .title
                    .clone();
                scene.media_integration_enabled = false;
                for path in [&mut scene.scene_path, &mut scene.assets_path] {
                    if !std::path::Path::new(path.as_str()).is_absolute() {
                        *path = std::path::absolute(&*path)
                            .map_err(|error| BridgeError::Error {
                                kind: crate::api::BridgeErrorKind::Io,
                                message: error.to_string(),
                            })?
                            .into_os_string()
                            .into_string()
                            .map_err(|_| {
                                BridgeError::invalid_input("lock-screen source path is not UTF-8")
                            })?;
                    }
                }
                let properties_json = scene
                    .property_override_json
                    .as_deref()
                    .map(|json| {
                        let flat = serde_json::from_str::<serde_json::Value>(json)
                            .map_err(|error| BridgeError::engine(error.to_string()))?
                            .flatten()
                            .map_err(|error| BridgeError::engine(error.to_string()))?;
                        serde_json::to_string(&flat)
                            .map_err(|error| BridgeError::engine(error.to_string()))
                    })
                    .transpose()?;
                Ok(BridgeLockScreenScene {
                    display_id: scene.display.display_id,
                    wallpaper_id,
                    title,
                    project_path: scene.scene_path,
                    assets_path: scene.assets_path,
                    fps: self.live_target_fps(scene.fps),
                    scaling_mode: scene.scaling_mode.into(),
                    scaling_factor: scene.scaling_factor,
                    framing: scene.framing.into(),
                    properties_json,
                    paused: scene.paused,
                })
            })
            .collect::<Result<Vec<_>, BridgeError>>()?;

        for desc in inputs.build_web()? {
            let project_dir = std::path::absolute(&desc.project_dir)
                .map_err(|error| BridgeError::Error {
                    kind: crate::api::BridgeErrorKind::Io,
                    message: error.to_string(),
                })?;
            let project_path = project_dir
                .join("project.json")
                .into_os_string()
                .into_string()
                .map_err(|_| {
                    BridgeError::invalid_input("lock-screen source path is not UTF-8")
                })?;
            let assets_path = project_dir
                .into_os_string()
                .into_string()
                .map_err(|_| {
                    BridgeError::invalid_input("lock-screen source path is not UTF-8")
                })?;
            let title = self
                .state
                .library
                .iter()
                .find(|entry| entry.id == desc.wallpaper_id)
                .ok_or_else(|| BridgeError::Error {
                    kind: crate::api::BridgeErrorKind::Library,
                    message: format!(
                        "lock-screen wallpaper {} is not in the library",
                        desc.wallpaper_id
                    ),
                })?
                .title
                .clone();
            let properties_json =
                self.web_properties_json(&desc.wallpaper_id, &desc.properties);
            scenes.push(BridgeLockScreenScene {
                display_id: desc.display.display_id,
                wallpaper_id: desc.wallpaper_id,
                title,
                project_path,
                assets_path,
                fps: self.live_target_fps(desc.fps),
                scaling_mode: BridgeScalingMode::Fill,
                scaling_factor: 1.0,
                // A web page fills its window and has nothing to move.
                framing: SceneFraming::default().into(),
                properties_json: Some(properties_json),
                paused: desc.paused,
            });
        }
        Ok(scenes)
    }

    fn unchanged_configured_scenes(
        &self,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<Option<Vec<SceneDesc>>, BridgeError> {
        // Configured scenes are not what should be open while unloaded, and
        // they are not already applied on the way back in. Returning Some
        // here is what would skip both the close and the reopen.
        if self.state.presentation_unloaded {
            return Ok(None);
        }
        let scenes = self.activation_inputs(displays, self.playback_paused()).build()?;
        let snapshot = self.engine.display_snapshot();
        let has_direct_runtime = |entry: &&DisplaySnapshotEntry| {
            entry.handle.is_some()
                && matches!(entry.assignment, Some(WallpaperAssignment::Direct(_)))
        };

        if scenes.len() != snapshot.iter().filter(has_direct_runtime).count() {
            return Ok(None);
        }

        if scenes.iter().all(|scene| {
            let live = live_scene(
                scene.clone(),
                self.active_target_fps_cap(),
                self.state.audio_suppressed,
            );
            snapshot.iter().any(|entry| {
                entry.handle.is_some()
                    && entry
                        .assignment
                        .as_ref()
                        .is_some_and(|assignment| match assignment {
                            WallpaperAssignment::Direct(template) => {
                                let mut running = template.for_display(scene.display.clone());
                                // Pause is applied live and never reopens a scene.
                                running.paused = live.paused;
                                running == live
                            }
                            WallpaperAssignment::Mirror(_) => false,
                        })
            })
        }) {
            Ok(Some(scenes))
        } else {
            Ok(None)
        }
    }

    /// System audio capture only needs to run while something that is actually
    /// presenting consumes it. Volume and mute are separate controls: silencing
    /// a wallpaper does not switch off its audio response, and an
    /// audio-response wallpaper on a hidden display is not a consumer.
    ///
    /// Both kinds of consumer count. A scene consumes through its renderer
    /// handle. A web page has no handle at all and consumes only once it has
    /// registered an audio listener, so leaving it out would keep the tap shut
    /// on a display showing nothing but web wallpapers.
    fn audio_capture_demand(&self, paused: bool) -> AudioCaptureDemand {
        let displays = self.engine.display_snapshot();
        let inputs = self.activation_inputs(&displays, paused);
        let external_consumers = web_audio_consumers(&inputs, &self.state.web_audio_subscribers) > 0;
        let Ok(scenes) = inputs.build() else {
            // Without a resolvable scene list, fall back to the coarse global
            // condition rather than guessing that nothing consumes audio.
            return AudioCaptureDemand { suspended: paused, external_consumers };
        };

        let scene_consumers = scenes.iter().any(|scene| {
            scene.audio_response_enabled
                && !scene.paused
                && scene_reads_audio(&self.engine, &displays, scene)
        });
        AudioCaptureDemand {
            suspended: !scene_consumers && !external_consumers,
            external_consumers,
        }
    }

    /// Wallpapers that enable audio response, whose scene reads audio and that
    /// are not paused for their own display, counting subscribed web pages
    /// alongside scenes. This is the same rule the capture tap follows,
    /// reported as a number so a diagnostic session can see why the tap is
    /// open or closed.
    fn audio_consumer_count(&self) -> u32 {
        let displays = self.engine.display_snapshot();
        let inputs = self.activation_inputs(&displays, self.playback_paused());
        let Ok(scenes) = inputs.build() else {
            return 0;
        };
        let scene_consumers = scenes
            .iter()
            .filter(|scene| {
                scene.audio_response_enabled
                    && !scene.paused
                    && scene_reads_audio(&self.engine, &displays, scene)
            })
            .count();

        u32::try_from(scene_consumers)
            .unwrap_or(u32::MAX)
            .saturating_add(web_audio_consumers(&inputs, &self.state.web_audio_subscribers))
    }

    async fn apply_engine_pause(&self, previous_paused: bool) -> Result<(), BridgeError> {
        let paused = self.playback_paused();
        let audio_demand = self.audio_capture_demand(paused);
        // Each scene takes `paused || its display is covered` in one pass, so a
        // global resume never runs a display that is still hidden on its own.
        let suspended_displays: Vec<u32> = self.state.suspended_displays.iter().copied().collect();
        let result = async {
            self.engine
                .set_all_paused(paused, suspended_displays.clone())
                .await?;
            self.engine.set_audio_capture_demand(audio_demand).await
        }
        .await;
        if let Err(error) = result {
            let mut message = error.to_string();
            // Either operation may have changed live state before failing.
            // Restore both sides before the caller rolls back its actor state.
            if let Err(rollback) = self
                .engine
                .set_all_paused(previous_paused, suspended_displays)
                .await
            {
                message.push_str(&format!("; renderer pause rollback failed: {rollback}"));
            }
            if let Err(rollback) = self
                .engine
                .set_audio_capture_demand(self.audio_capture_demand(previous_paused))
                .await
            {
                message.push_str(&format!("; audio capture rollback failed: {rollback}"));
            }
            return Err(BridgeError::engine(message));
        }
        self.refresh_mouse_polling_policy();
        Ok(())
    }

    /// Puts every live scene whose pause differs from the playback policy in
    /// force now back on it: paused while every display is (the user's Pause
    /// included) or while its own display is suspended, playing otherwise.
    ///
    /// Runs on this actor after a successful reconcile. The engine keeps a
    /// scene's pause across a rebuild, so a renderer can come back holding a
    /// pause its display no longer has, or running where its display should
    /// not. Only a scene that differs gets a command, one display at a time,
    /// so a covered display cannot stop a visible one. A command that fails is
    /// logged and leaves the reconcile's result standing.
    async fn align_live_pause_with_policy(&self) {
        let paused = self.playback_paused();
        for entry in self.engine.display_snapshot() {
            if entry.handle.is_none() {
                continue;
            }
            let display_id = entry.desc.display_id;
            let target = paused || self.state.suspended_displays.contains(&display_id);
            if entry.paused == target {
                continue;
            }
            if let Err(error) = self.engine.set_display_paused(display_id, target).await {
                log::warn!(
                    "display {display_id}: could not {} its scene after a reconcile: {error}",
                    if target { "pause" } else { "resume" }
                );
            }
        }
    }
}

/// The saved rate, never above the ceiling in force.
fn capped_frame_rate(rate: u32, cap: Option<u32>) -> u32 {
    cap.map_or(rate, |cap| rate.min(cap)).max(1)
}

/// `scene` as its renderer runs it: the saved rate under the frame-rate
/// ceiling in force, and the saved mute with the transient mute on top.
///
/// Both are applied live, and applying them rewrites the open scene's
/// descriptor. The engine reopens any scene whose descriptor differs from the
/// one it is handed, so every reconcile hands over, and every unchanged check
/// compares against, this form. The saved values would reload each capped or
/// muted scene on every Apply, display edit, backend switch or repair.
fn live_scene(mut scene: SceneDesc, fps_cap: Option<u32>, audio_suppressed: bool) -> SceneDesc {
    scene.fps = capped_frame_rate(scene.fps, fps_cap);
    scene.audio_muted = scene.audio_muted || audio_suppressed;
    scene
}

impl<E: EngineFacade + Clone> Message<Bootstrap> for BridgeActor<E> {
    type Reply = messages::BootstrapReply;

    async fn handle(
        &mut self,
        _msg: Bootstrap,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.errors.clear();

        // Process-wide renderer switches live in C, not in the config file, so
        // a persisted opt-in only survives a restart if it is pushed back in
        // before anything opens.
        let experimental = self.state.app_config.experimental;
        if let Err(error) = self
            .engine
            .set_scene_optimization_enabled(self.state.app_config.quality.scene_optimization_enabled)
        {
            self.state.errors.push(error.to_string());
        }
        if let Err(error) = self
            .engine
            .set_scene_on_demand_enabled(self.state.app_config.quality.scene_on_demand_enabled)
        {
            self.state.errors.push(error.to_string());
        }
        // Before any scene opens: a scene sizes its render targets from this
        // when its graph is built, and the engine's own default is the canvas.
        if let Err(error) = self
            .engine
            .set_scene_resolution(scene_resolution(self.state.app_config.quality.scene_resolution))
        {
            self.state.errors.push(error.to_string());
        }
        if let Err(error) = self
            .engine
            .set_scene_video_plane_sampling_enabled(experimental.scene_video_plane_sampling)
        {
            self.state.errors.push(error.to_string());
        }

        if let Err(error) = self.refresh_displays().await {
            self.state.errors.push(error.message().to_string());
        }
        if let Err(error) = self.refresh_library() {
            self.state.errors.push(error.message().to_string());
        }
        if let Err(error) = self.load_wallpapers() {
            self.state.errors.push(error.message().to_string());
        }
        self.hold_back_crashing_wallpapers();
        if let Err(error) = self.reconcile_configured_operation().await {
            self.state.errors.push(error.message().to_string());
            self.state.pending_battery_pause_after_initial_frame = false;
        }
        if self.state.configured_ids().is_empty() {
            self.state.pending_battery_pause_after_initial_frame = false;
        }
        if !self.state.pending_battery_pause_after_initial_frame {
            self.apply_power_policy().await?;
        }

        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<GetAllSnapshots> for BridgeActor<E> {
    type Reply = messages::AllSnapshotsReply;

    async fn handle(
        &mut self,
        _msg: GetAllSnapshots,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<GetAppSnapshot> for BridgeActor<E> {
    type Reply = messages::AppSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetAppSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.app_snapshot())
    }
}

impl<E: EngineFacade + Clone> Message<GetLibrarySnapshot> for BridgeActor<E> {
    type Reply = messages::LibrarySnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetLibrarySnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.library_snapshot())
    }
}

impl<E: EngineFacade + Clone> Message<GetLockScreenScenes> for BridgeActor<E> {
    type Reply = messages::LockScreenScenesReply;

    async fn handle(
        &mut self,
        _msg: GetLockScreenScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.lock_screen_scenes()
    }
}

impl<E: EngineFacade + Clone> Message<GetWebWallpapers> for BridgeActor<E> {
    type Reply = messages::WebWallpapersReply;

    async fn handle(
        &mut self,
        _msg: GetWebWallpapers,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.web_wallpapers()
    }
}

impl<E: EngineFacade + Clone> Message<GetMonitorInformationSnapshot> for BridgeActor<E> {
    type Reply = messages::MonitorInformationSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetMonitorInformationSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        Ok(self.state.monitor_info(&displays))
    }
}

impl<E: EngineFacade + Clone> Message<GetSettingsSnapshot> for BridgeActor<E> {
    type Reply = messages::SettingsSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetSettingsSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.invalidate_shader_cache_size();
        let displays = self.engine.display_snapshot();
        Ok(self
            .state
            .settings(&displays, self.launch_at_login.status(), &self.paths, &self.engine.scene_runtime_reports()))
    }
}

impl<E: EngineFacade + Clone> Message<PollMousePosition> for BridgeActor<E> {
    type Reply = messages::PollMousePositionReply;

    async fn handle(
        &mut self,
        _msg: PollMousePosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.mouse_polling.is_enabled() {
            return Ok(());
        }
        self.engine
            .poll_mouse_position()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<ClearShaderCache> for BridgeActor<E> {
    type Reply = messages::ClearShaderCacheReply;

    async fn handle(
        &mut self,
        _msg: ClearShaderCache,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.invalidate_shader_cache_size();
        let cache_root = self.paths.shader_cache_root();
        match fs::remove_dir_all(&cache_root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(BridgeError::Error {
                    kind: crate::api::BridgeErrorKind::Io,
                    message: format!("failed to clear shader cache: {error}"),
                });
            }
        }
        fs::create_dir_all(&cache_root).map_err(|error| BridgeError::Error {
            kind: crate::api::BridgeErrorKind::Io,
            message: format!("failed to recreate shader cache: {error}"),
        })?;

        self.load_wallpapers()?;
        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let result = self
            .reconcile_snapshot_operation(app_config, wallpaper_configs, true)
            .await;
        self.refresh_mouse_polling_policy();
        let scenes = result?;
        self.state.set_active_ids_from_scenes(&scenes);
        self.invalidate_operations();

        let displays = self.engine.display_snapshot();
        Ok(self
            .state
            .settings(&displays, self.launch_at_login.status(), &self.paths, &self.engine.scene_runtime_reports()))
    }
}

impl<E: EngineFacade + Clone> Message<GetWallpaperPreview> for BridgeActor<E> {
    type Reply = Result<BridgeWallpaperPreview, BridgeError>;

    async fn handle(&mut self, msg: GetWallpaperPreview, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        self.wallpaper_preview(&msg.wallpaper_id, &msg.display_id, msg.pending)
    }
}

impl<E: EngineFacade + Clone> Message<GetWallpaperOptionsSnapshot> for BridgeActor<E> {
    type Reply = messages::WallpaperOptionsSnapshotReply;

    async fn handle(
        &mut self,
        msg: GetWallpaperOptionsSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        self.state.options(&displays, msg.wallpaper_id, &self.paths)
    }
}

impl<E: EngineFacade + Clone> Message<InjectWallpaperForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectWallpaperForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::add_entry(&mut self.state.library, msg.id, msg.title, msg.kind);
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectSceneWallpaperConfigForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectSceneWallpaperConfigForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::add_scene_configuration(
            &mut self.state.library,
            &mut self.state.wallpaper_configs,
            &mut self.state.wallpaper_drafts,
            msg.id,
            msg.title,
        );
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectSceneProjectForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectSceneProjectForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::add_project(
            &mut self.state.library,
            &mut self.state.project_models,
            &mut self.state.wallpaper_configs,
            &mut self.state.wallpaper_drafts,
            msg.id,
            msg.title,
            &msg.project_json,
        )?;
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectDisplayForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectDisplayForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::add_display(
            &mut self.state.app_config,
            &mut self.state.display_settings,
            msg.display_id,
            msg.title,
        )?;
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<ReplaceLibraryForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: ReplaceLibraryForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::replace_library(
            &mut self.state.library,
            &mut self.state.selected_wallpaper_id,
            &mut self.state.app_config,
            msg.entries,
        );
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<ReplaceWallpaperConfigForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: ReplaceWallpaperConfigForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        fixture_values::replace_configuration(
            &mut self.state.wallpaper_configs,
            &mut self.state.wallpaper_drafts,
            msg.id,
            msg.config,
        );
        self.invalidate_operations();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SelectWallpaper> for BridgeActor<E> {
    type Reply = messages::SelectWallpaperReply;

    async fn handle(
        &mut self,
        msg: SelectWallpaper,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.ensure_wallpaper_exists(&msg.id)?;
        let should_load_wallpaper = !self.state.wallpaper_configs.contains_key(&msg.id)
            && !self.state.wallpaper_drafts.contains_key(&msg.id);
        let loaded_wallpaper = if should_load_wallpaper {
            self.config_store
                .as_ref()
                .map(|store| store.load_wallpaper(&msg.id))
                .transpose()?
        } else {
            None
        };

        if let Some(config) = loaded_wallpaper {
            self.state
                .wallpaper_configs
                .entry(msg.id.clone())
                .or_insert(config);
        }
        self.state.app_config.general.last_selected_wallpaper = Some(msg.id.clone());
        self.state.selected_wallpaper_id = Some(msg.id.clone());
        self.invalidate_operations();
        self.snapshots_with_options(msg.id)
    }
}

impl<E: EngineFacade + Clone> Message<RefreshLibrary> for BridgeActor<E> {
    type Reply = messages::RefreshLibraryReply;

    async fn handle(
        &mut self,
        _msg: RefreshLibrary,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.refresh_library()?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<RefreshDisplays> for BridgeActor<E> {
    type Reply = messages::RefreshDisplaysReply;

    async fn handle(
        &mut self,
        _msg: RefreshDisplays,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.refresh_displays().await?;
        self.reconcile_configured_operation().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<ReleaseHeldWallpaper> for BridgeActor<E> {
    type Reply = messages::ReleaseHeldWallpaperReply;

    async fn handle(
        &mut self,
        msg: ReleaseHeldWallpaper,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.state.held_wallpapers.remove(&msg.wallpaper_id) {
            // Already released, by Apply or by an earlier click: nothing to open.
            return Ok(self.all_snapshots());
        }
        // The journal keeps its strikes until the wallpaper has been handed to
        // the engine, so a crash during this very attempt holds it again at
        // the next launch instead of counting as a first offence.
        if let Err(error) = self.reconcile_configured_operation().await {
            // Nothing was opened, so it is still held back.
            self.state.held_wallpapers.insert(msg.wallpaper_id);
            return Err(error);
        }
        let _ = self.load_journal.forgive(&msg.wallpaper_id);
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetFilter> for BridgeActor<E> {
    type Reply = messages::SetFilterReply;

    async fn handle(
        &mut self,
        msg: SetFilter,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match msg.kind {
            BridgeWallpaperKind::ProjectScene => self.state.filter_scene = msg.enabled,
            BridgeWallpaperKind::Video => self.state.filter_video = msg.enabled,
            BridgeWallpaperKind::Webpage => self.state.filter_webpage = msg.enabled,
            BridgeWallpaperKind::Unknown => self.state.filter_unknown = msg.enabled,
        }
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetLaunchAtLogin> for BridgeActor<E> {
    type Reply = messages::DisplayMutationReply;

    async fn handle(
        &mut self,
        msg: SetLaunchAtLogin,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.launch_at_login.set_enabled(msg.enabled)?;
        Ok(self.display_bundle())
    }
}

impl<E: EngineFacade + Clone> Message<SetBatteryMode> for BridgeActor<E> {
    type Reply = messages::SetBatteryModeReply;

    async fn handle(
        &mut self,
        msg: SetBatteryMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.power.on_battery = msg.mode;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // Leaving reduced quality has to hand the saved scale and rates back
        // in this step, not on the next power sample.
        self.apply_quality_profile().await?;
        self.apply_power_policy().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetFrameRateCap> for BridgeActor<E> {
    type Reply = messages::SetFrameRateCapReply;

    async fn handle(
        &mut self,
        msg: SetFrameRateCap,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.quality.frame_rate_cap = msg.cap.map(|cap| cap.max(1));
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        self.apply_quality_profile().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetQualityThrottle> for BridgeActor<E> {
    type Reply = messages::SetQualityThrottleReply;

    async fn handle(
        &mut self,
        msg: SetQualityThrottle,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.quality_throttle = msg.causes.into_iter().collect();
        // Asking again with the same causes still applies them: a caller whose
        // last request failed halfway retries by repeating it, and the state
        // is kept on error just as a frame-rate cap is. Re-asserting an
        // unchanged scale or rate is free in the renderer, and handing a clip
        // back to the native player is owed until it has been done.
        self.apply_quality_profile().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetPresentationUnloaded> for BridgeActor<E> {
    type Reply = messages::SetPresentationUnloadedReply;

    async fn handle(
        &mut self,
        msg: SetPresentationUnloaded,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.presentation_unloaded == msg.unloaded {
            return Ok(self.all_snapshots());
        }
        let previous = self.state.presentation_unloaded;
        self.state.presentation_unloaded = msg.unloaded;
        let ticket = self.reserve_operation();
        let reconciled = self.reconcile_inline_operation().await;
        match reconciled {
            Ok(()) => {
                self.complete_inline_operation(ticket, ctx.actor_ref().clone());
                Ok(self.all_snapshots())
            }
            Err(error) => {
                self.state.presentation_unloaded = previous;
                self.fail_inline_operation(ticket, &error, ctx.actor_ref().clone());
                Err(error)
            }
        }
    }
}

impl<E: EngineFacade + Clone> Message<SetAudioSuppressed> for BridgeActor<E> {
    type Reply = messages::SetAudioSuppressedReply;

    async fn handle(
        &mut self,
        msg: SetAudioSuppressed,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.audio_suppressed = msg.suppressed;
        let displays = self.engine.display_snapshot();
        let scenes = self
            .activation_inputs(&displays, self.playback_paused())
            .build()?;
        for scene in &scenes {
            let Some(handle) = displays
                .iter()
                .find(|entry| entry.desc.display_id == scene.display.display_id)
                .and_then(|entry| entry.handle)
            else {
                continue;
            };
            self.engine
                .set_audio_muted(handle, scene.audio_muted || msg.suppressed)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetVerboseLogging> for BridgeActor<E> {
    type Reply = messages::SetVerboseLoggingReply;

    async fn handle(
        &mut self,
        msg: SetVerboseLogging,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.diagnostics.verbose_logging = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        crate::logging::ApplicationLogger::set_verbose(msg.enabled);
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetLabelLanguages> for BridgeActor<E> {
    type Reply = messages::SetLabelLanguagesReply;

    async fn handle(
        &mut self,
        msg: SetLabelLanguages,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let locales = crate::project::localization::preferred_locales(&msg.locales);
        if self.state.label_locales != locales {
            log::info!("property label languages: {locales:?}");
            // Only what the options snapshot reads changes; no scene is
            // touched, so nothing here can make a running reconcile stale.
            self.state.label_locales = locales;
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetPresentationSuspended> for BridgeActor<E> {
    type Reply = messages::SetPresentationSuspendedReply;

    async fn handle(
        &mut self,
        msg: SetPresentationSuspended,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.presentation_suspended == msg.suspended {
            return Ok(());
        }
        let previous_paused = self.playback_paused();
        self.state.presentation_suspended = msg.suspended;
        if let Err(error) = self.apply_engine_pause(previous_paused).await {
            self.state.presentation_suspended = !msg.suspended;
            return Err(error);
        }
        self.invalidate_operations();
        log::info!(
            "presentation {}",
            if msg.suspended { "suspended" } else { "resumed" }
        );
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayPresentationSuspended> for BridgeActor<E> {
    type Reply = messages::SetDisplayPresentationSuspendedReply;

    async fn handle(
        &mut self,
        msg: SetDisplayPresentationSuspended,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let display_id: u32 = msg.display_id.parse().map_err(|_| {
            BridgeError::invalid_input(format!("unknown display id {}", msg.display_id))
        })?;
        let was_suspended = self.state.suspended_displays.contains(&display_id);
        if was_suspended == msg.suspended {
            return Ok(());
        }
        let previous_paused = self.playback_paused();
        if msg.suspended {
            self.state.suspended_displays.insert(display_id);
        } else {
            self.state.suspended_displays.remove(&display_id);
        }
        // The scene on this display takes the new state; the others keep
        // whatever they already had, so a hidden screen cannot stop a visible
        // one and a visible screen cannot restart a hidden one.
        let paused = self.playback_paused() || msg.suspended;
        let audio_demand = self.audio_capture_demand(self.playback_paused());
        let result = async {
            self.engine.set_display_paused(display_id, paused).await?;
            self.engine
                .set_audio_capture_demand(audio_demand)
                .await
        }
        .await;
        if let Err(error) = result {
            let mut message = error.to_string();
            if msg.suspended {
                self.state.suspended_displays.remove(&display_id);
            } else {
                self.state.suspended_displays.insert(display_id);
            }
            if let Err(rollback) = self
                .engine
                .set_display_paused(display_id, previous_paused || was_suspended)
                .await
            {
                message.push_str(&format!("; display pause rollback failed: {rollback}"));
            }
            if let Err(rollback) = self
                .engine
                .set_audio_capture_demand(self.audio_capture_demand(self.playback_paused()))
                .await
            {
                message.push_str(&format!("; audio capture rollback failed: {rollback}"));
            }
            return Err(BridgeError::engine(message));
        }
        self.refresh_mouse_polling_policy();
        self.invalidate_operations();
        log::info!(
            "display {display_id} presentation {}",
            if msg.suspended { "suspended" } else { "resumed" }
        );
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayParkedWallpapers> for BridgeActor<E> {
    type Reply = messages::SetDisplayParkedWallpapersReply;

    async fn handle(
        &mut self,
        msg: SetDisplayParkedWallpapers,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let display_id: u32 = msg.display_id.parse().map_err(|_| {
            BridgeError::invalid_input(format!("unknown display id {}", msg.display_id))
        })?;
        // The engine knows a scene by its project file, which is where every
        // wallpaper id leads; one that is not a scene matches nothing.
        let scene_paths = msg
            .wallpaper_ids
            .iter()
            .map(|id| self.paths.project_json(id).to_string_lossy().into_owned())
            .collect();
        self.engine
            .set_parked_scenes(display_id, scene_paths)
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        log::info!(
            "display {display_id} keeps {} wallpaper(s) paused when it moves on",
            msg.wallpaper_ids.len()
        );
        Ok(())
    }
}

fn scene_resolution(resolution: SceneResolutionCfg) -> SceneResolution {
    match resolution {
        SceneResolutionCfg::Canvas => SceneResolution::Canvas,
        SceneResolutionCfg::Display => SceneResolution::Display,
    }
}

impl<E: EngineFacade + Clone> Message<SetSceneResolution> for BridgeActor<E> {
    type Reply = messages::SetSceneResolutionReply;

    async fn handle(
        &mut self,
        msg: SetSceneResolution,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.app_config.quality.scene_resolution == msg.resolution {
            return Ok(self.all_snapshots());
        }
        self.state.app_config.quality.scene_resolution = msg.resolution;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // The size the canvas is rasterized at, not what a scene is: the
        // process switch is set, and every open scene is then handed the render
        // scale it already has, which is when a running scene reads the switch
        // and resizes its targets in place. Going through a reconcile instead
        // would reparse every project and reopen every video for a quality
        // choice.
        self.engine
            .set_scene_resolution(scene_resolution(msg.resolution))
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.apply_effective_render_scale().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetRenderScale> for BridgeActor<E> {
    type Reply = messages::SetRenderScaleReply;

    async fn handle(
        &mut self,
        msg: SetRenderScale,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let scale = crate::config::clamp_render_scale(msg.scale);
        self.state.app_config.quality.render_scale = scale;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // What the user saved is not necessarily what runs: a battery profile
        // already in force keeps its own scale until the machine leaves
        // battery power.
        self.apply_effective_render_scale().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetBatteryQualityProfile> for BridgeActor<E> {
    type Reply = messages::SetBatteryQualityProfileReply;

    async fn handle(
        &mut self,
        msg: SetBatteryQualityProfile,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let quality = &mut self.state.app_config.quality;
        quality.battery.render_scale = crate::config::clamp_render_scale(msg.render_scale);
        quality.battery.target_fps = msg.target_fps.max(1);
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // A machine already on reduced quality has to pick the new scale and
        // rate up now. Leaving that mode is `SetBatteryMode`'s restore.
        self.apply_quality_profile().await?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetSceneOptimizationEnabled> for BridgeActor<E> {
    type Reply = messages::SetSceneOptimizationEnabledReply;

    async fn handle(
        &mut self,
        msg: SetSceneOptimizationEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.quality.scene_optimization_enabled = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // Frame-building strategy, not scene content: running scenes pick it
        // up where they are, so nothing here rebuilds or reparses anything.
        self.engine
            .set_scene_optimization_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetSceneOnDemandEnabled> for BridgeActor<E> {
    type Reply = messages::SetSceneOnDemandEnabledReply;

    async fn handle(
        &mut self,
        msg: SetSceneOnDemandEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.quality.scene_on_demand_enabled = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // When a scene ticks, not what a scene is: running scenes re-decide
        // where they are, so nothing here rebuilds, reparses, or restarts a
        // wallpaper, and a pause the user asked for is untouched.
        self.engine
            .set_scene_on_demand_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetSceneVideoPlaneSamplingEnabled> for BridgeActor<E> {
    type Reply = messages::SetSceneVideoPlaneSamplingEnabledReply;

    async fn handle(
        &mut self,
        msg: SetSceneVideoPlaneSamplingEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state
            .app_config
            .experimental
            .scene_video_plane_sampling = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // Which of two already-compiled programs draws a video material, not
        // what a scene is: a running scene picks the change up at its next
        // frame boundary, so nothing here rebuilds, reparses or reopens
        // anything.
        self.engine
            .set_scene_video_plane_sampling_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.invalidate_operations();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetWebAudioSubscribed> for BridgeActor<E> {
    type Reply = messages::SetWebAudioSubscribedReply;

    async fn handle(
        &mut self,
        msg: SetWebAudioSubscribed,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let subscribers = &mut self.state.web_audio_subscribers;
        if msg.subscribed {
            let _ = subscribers
                .entry(msg.wallpaper_id)
                .or_default()
                .insert(msg.display_id);
        } else if let Some(displays) = subscribers.get_mut(&msg.wallpaper_id) {
            let _ = displays.remove(&msg.display_id);
            if displays.is_empty() {
                let _ = subscribers.remove(&msg.wallpaper_id);
            }
        }

        // The last consumer of either kind going away has to close the tap,
        // so this is re-evaluated rather than only ever opened.
        self.engine
            .set_audio_capture_demand(self.audio_capture_demand(self.playback_paused()))
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<AudioRequirementChanged> for BridgeActor<E> {
    type Reply = messages::AudioRequirementChangedReply;

    /// A scene started or stopped reading audio: re-register it, then
    /// re-evaluate the tap, so a scene that reads nothing never holds it open
    /// and one that starts reading late opens it without waiting for a
    /// reconcile.
    async fn handle(
        &mut self,
        msg: AudioRequirementChanged,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let scenes = self
            .activation_inputs(&displays, self.playback_paused())
            .build()
            .unwrap_or_default();
        for handle in msg.handles {
            // A handle no display shows any more was already released when
            // its scene went away.
            let Some(display_id) = displays
                .iter()
                .find(|display| display.handle == Some(handle))
                .map(|display| display.desc.display_id)
            else {
                continue;
            };
            let response_enabled = scenes
                .iter()
                .find(|scene| scene.display.display_id == display_id)
                .is_some_and(|scene| scene.audio_response_enabled);
            register_audio_capture(&self.engine, handle, response_enabled)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.engine
            .set_audio_capture_demand(self.audio_capture_demand(self.playback_paused()))
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMediaIntegrationEnabled> for BridgeActor<E> {
    type Reply = messages::SetMediaIntegrationEnabledReply;

    async fn handle(
        &mut self,
        msg: SetMediaIntegrationEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let previous_enabled = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .current()
            .media_integration_enabled;
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_media_integration_enabled_immediate(msg.enabled);
        if let Err(error) = self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config) {
            let _ = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)?
                .set_media_integration_enabled_immediate(previous_enabled);
            return Err(error);
        }
        if !msg.enabled {
            let mut state = crate::api::BridgeMediaSnapshot { playback_state: 2, ..Default::default() }.into_state()?;
            state.events[0] = wallpaper_core::media::MediaIntegrationEvent::StatusChanged { enabled: false };
            for handle in self.wallpaper_handles(&msg.wallpaper_id, true) {
                self.engine.update_media(handle, false, state.clone()).await
                    .map_err(|error| BridgeError::engine(error.to_string()))?;
            }
        }
        self.invalidate_operations();
        let handles = self.wallpaper_handles(&msg.wallpaper_id, true);
        for handle in handles {
            if let Err(error) = self
                .engine
                .set_media_integration_enabled(handle, msg.enabled)
                .await
            {
                let reverted = self
                    .state
                    .wallpaper_draft_mut(&msg.wallpaper_id)?
                    .set_media_integration_enabled_immediate(previous_enabled);
                let _ = self.save_wallpaper(msg.wallpaper_id.clone(), reverted);
                return Err(BridgeError::engine(error.to_string()));
            }
        }
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    /// Displays that cannot present right now, as scene handles.
    ///
    /// Per-display occlusion is not part of `playback_paused`, which is the
    /// set of reasons that stop every display at once; it has to be composed
    /// on top, and a handle is how the media paths name a surface.
    fn suspended_display_handles(&self) -> HashSet<SceneHandle> {
        if self.state.suspended_displays.is_empty() {
            return HashSet::new();
        }
        self.engine
            .display_snapshot()
            .iter()
            .filter(|entry| {
                self.state
                    .suspended_displays
                    .contains(&entry.desc.display_id)
            })
            .filter_map(|entry| entry.handle)
            .collect()
    }

    /// Scene handles whose user allowed this wallpaper near their media.
    ///
    /// Consent is a setting, not a state: it does not change because playback
    /// stopped. This answers "may this surface take part in media at all",
    /// which is the question an incoming user shortcut has to pass before it
    /// is allowed to reach a media player.
    fn media_consent_handles(&self) -> Vec<SceneHandle> {
        let mut handles = Vec::new();
        let mut seen = HashSet::new();
        for (id, config) in &self.state.wallpaper_configs {
            let enabled = self
                .state
                .wallpaper_drafts
                .get(id)
                .map(|draft| draft.current().media_integration_enabled)
                .unwrap_or(config.media_integration_enabled);
            if !enabled {
                continue;
            }
            for handle in self.wallpaper_handles(id, true) {
                if seen.insert(handle) {
                    handles.push(handle);
                }
            }
        }
        handles
    }

    /// Scene handles that should be fed system media *now*.
    ///
    /// Opting in is not consuming. A wallpaper the user paused, one the power
    /// policy suspended, one behind a global presentation suspend and one on an
    /// occluded display all still have a live handle and an enabled setting, so
    /// "there is still a handle" kept the adapter process, its timeline ticker
    /// and every conversion and fan-out alive to update surfaces nobody can
    /// see. The effective set is the consenting set minus every pause reason.
    ///
    /// This is the set the host asks for when it decides whether to consume at
    /// all, so it going empty is what releases the shared provider — while a
    /// web wallpaper that is still visible keeps its own vote.
    fn media_scene_handles(&self) -> Vec<SceneHandle> {
        if self.playback_paused() {
            return Vec::new();
        }
        let suspended = self.suspended_display_handles();
        let mut handles = self.media_consent_handles();
        handles.retain(|handle| !suspended.contains(handle));
        handles
    }
}

impl<E: EngineFacade + Clone> Message<messages::GetSceneMediaWallpapers> for BridgeActor<E> {
    type Reply = Result<Vec<String>, BridgeError>;
    async fn handle(&mut self, _msg: messages::GetSceneMediaWallpapers,
        _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        // The same effective set the fan-out uses. Answering from
        // `playback_paused` alone left a scene on an occluded display eligible
        // here while the fan-out had already dropped it, so the two entry
        // points disagreed about who was consuming.
        let effective: HashSet<SceneHandle> = self.media_scene_handles().into_iter().collect();
        if effective.is_empty() { return Ok(Vec::new()); }
        Ok(self.state.library.iter().filter(|entry| {
            entry.kind == crate::api::BridgeWallpaperKind::ProjectScene
                && self.state.wallpaper_configs.get(&entry.id).is_some_and(|c| c.media_integration_enabled)
                && self.wallpaper_handles(&entry.id, true).iter().any(|handle| effective.contains(handle))
        }).map(|entry| entry.id.clone()).collect())
    }
}

impl<E: EngineFacade + Clone> Message<messages::UpdateSceneMedia> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;
    async fn handle(&mut self, msg: messages::UpdateSceneMedia,
        _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        if !self.state.wallpaper_configs.get(&msg.wallpaper_id)
            .is_some_and(|c| c.media_integration_enabled) { return Ok(()); }
        let effective: HashSet<SceneHandle> = self.media_scene_handles().into_iter().collect();
        for handle in self.wallpaper_handles(&msg.wallpaper_id, true) {
            if !effective.contains(&handle) { continue; }
            self.engine.update_media(handle, true, msg.state.clone()).await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<FanOutSystemMediaEvent> for BridgeActor<E> {
    type Reply = messages::FanOutSystemMediaEventReply;

    async fn handle(
        &mut self,
        msg: FanOutSystemMediaEvent,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        for handle in self.media_scene_handles() {
            self.engine
                .submit_media_event_json(handle, msg.json.clone())
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<FanOutSystemMediaArtwork> for BridgeActor<E> {
    type Reply = messages::FanOutSystemMediaArtworkReply;

    async fn handle(
        &mut self,
        msg: FanOutSystemMediaArtwork,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let artwork = wallpaper_core::media::MediaThumbnailRgba::new(msg.width, msg.height, msg.rgba)
            .map_err(BridgeError::invalid_input)?;
        for handle in self.media_scene_handles() {
            self.engine
                .apply_system_media_artwork(handle, artwork.width, artwork.height, artwork.rgba.clone())
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<GetSystemMediaSceneHandles> for BridgeActor<E> {
    type Reply = messages::GetSystemMediaSceneHandlesReply;

    async fn handle(
        &mut self,
        _msg: GetSystemMediaSceneHandles,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self
            .media_scene_handles()
            .into_iter()
            .map(SceneHandle::raw)
            .collect())
    }
}

impl<E: EngineFacade + Clone> Message<GetSystemMediaConsentHandles> for BridgeActor<E> {
    type Reply = messages::GetSystemMediaConsentHandlesReply;

    async fn handle(
        &mut self,
        _msg: GetSystemMediaConsentHandles,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self
            .media_consent_handles()
            .into_iter()
            .map(SceneHandle::raw)
            .collect())
    }
}

impl<E: EngineFacade + Clone> Message<SetPropertyPath> for BridgeActor<E> {
    type Reply = messages::SetPropertyPathReply;

    async fn handle(
        &mut self,
        msg: SetPropertyPath,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let model = self.state.project_model(&msg.wallpaper_id)?.clone();
        let kind = model
            .properties
            .iter()
            .find(|property| property.id == msg.property_id)
            .map(|property| property.kind.clone())
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown property id {}", msg.property_id))
            })?;
        // A texture picker names a scene asset, not a path the host may stage,
        // so it is refused here rather than quietly accepting a path the scene
        // engine would then fail to resolve.
        if !matches!(kind, PropertyKind::File | PropertyKind::Directory) {
            return Err(BridgeError::invalid_input(format!(
                "property id {} is not a file or directory property",
                msg.property_id
            )));
        }

        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_property_path_immediate(&model, &msg.property_id, msg.path);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<GetNativeVideoWallpapers> for BridgeActor<E> {
    type Reply = messages::GetNativeVideoWallpapersReply;

    async fn handle(
        &mut self,
        _msg: GetNativeVideoWallpapers,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.native_video_wallpapers()
    }
}

impl<E: EngineFacade + Clone> Message<SetRendererCountersEnabled> for BridgeActor<E> {
    type Reply = messages::SetRendererCountersEnabledReply;

    async fn handle(
        &mut self,
        msg: SetRendererCountersEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.engine
            .set_renderer_counters_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.state.renderer_counters_enabled = msg.enabled;
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<RendererCounters> for BridgeActor<E> {
    type Reply = messages::RendererCountersReply;

    async fn handle(
        &mut self,
        _msg: RendererCounters,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let (surfaces, shared) = self
            .engine
            .renderer_counters()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        Ok(BridgeRendererCountersReport {
            recording: self.state.renderer_counters_enabled,
            surfaces: surfaces.iter().map(renderer_surface_row).collect(),
            audio_analysis_deliveries: shared_value(
                &shared,
                RendererSharedCounterKind::AudioAnalysisDeliveries,
            ),
            audio_accepted_frames: shared_value(
                &shared,
                RendererSharedCounterKind::AudioAcceptedFrames,
            ),
            audio_active_consumers: self.audio_consumer_count(),
            // The renderer presents through a CAMetalLayer and exposes no presentation
            // feedback here. Present requests are reported as requests; the
            // frames the compositor actually showed are not observable, and are
            // never approximated by the request count.
            presentation_feedback_available: false,
        })
    }
}

/// Maps one renderer surface's counters onto the reported row. Named fields
/// only: no caller outside this crate handles raw counter indices.
fn renderer_surface_row(counters: &RendererSurfaceCounters) -> BridgeRendererSurfaceCounters {
    use RendererCounterKind as K;
    BridgeRendererSurfaceCounters {
        display_id: counters.display_id.to_string(),
        surface_id: counters.handle.raw().to_string(),
        generation: counters.generation,
        source_id: match counters.value(K::VideoSourceInstance) {
            0 => "unknown".to_string(),
            instance => format!("instance:{instance}"),
        },
        source_path: counters.source_path.clone(),
        source_count: counters.value(K::VideoSourceCount),
        backend: "scene".to_string(),
        effective_pause_reasons: counters
            .pause_reasons()
            .into_iter()
            .map(|reason| reason.name().to_string())
            .collect(),
        paused: counters.paused,
        timer_wakeups: counters.value(K::TimerWakeups),
        draw_requests: counters.value(K::DrawRequests),
        draw_ticks_suppressed: counters.value(K::DrawTicksSuppressed),
        draws_executed: counters.value(K::DrawsExecuted),
        draws_dropped: counters.value(K::DrawsDropped),
        render_submissions: counters.value(K::RenderSubmissions),
        render_failures: counters.value(K::RenderFailures),
        present_requests: counters.value(K::PresentRequests),
        gpu_completions: counters.value(K::GpuCompletions),
        simulation_ticks: counters.value(K::SimulationTicks),
        presents_skipped_unchanged: counters.value(K::PresentsSkippedUnchanged),
        tick_interval_micros: counters.value(K::TickIntervalMicros),
        content_period_micros: counters.value(K::ContentPeriodMicros),
        video_decode_outputs: counters.value(K::VideoDecodeOutputs),
        video_seeks: counters.value(K::VideoSeeks),
        video_frames_selected: counters.value(K::VideoFramesSelected),
        video_frames_reused: counters.value(K::VideoFramesReused),
        video_frames_skipped: counters.value(K::VideoFramesSkipped),
        video_selected_generation: counters.value(K::VideoSelectedGeneration),
        video_conversions: counters.value(K::VideoConversions),
        video_imports: counters.value(K::VideoImports),
        video_conversion_live_bytes: counters.value(K::VideoConversionLiveBytes),
        video_conversion_peak_live_bytes: counters.value(K::VideoConversionPeakLiveBytes),
    }
}

impl<E: EngineFacade + Clone> Message<SetPowerSource> for BridgeActor<E> {
    type Reply = messages::SetPowerSourceReply;

    async fn handle(
        &mut self,
        msg: SetPowerSource,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if msg.initial_sample && self.state.startup_power_sample_received {
            return Ok(self.all_snapshots());
        }
        if self.state.power_source != msg.source {
            self.state.power_source = msg.source;
            if msg.source == crate::power::PowerSource::Battery {
                self.state.battery_pause_suppressed = false;
            }
        }
        if msg.initial_sample {
            self.state.apply_startup_power_source(msg.source);
        }
        self.apply_power_policy().await?;
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<InitialFrameReady> for BridgeActor<E> {
    type Reply = messages::InitialFrameReadyReply;

    async fn handle(
        &mut self,
        _msg: InitialFrameReady,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.initial_frame_ready = true;
        if self.state.pending_battery_pause_after_initial_frame {
            self.state.pending_battery_pause_after_initial_frame = false;
            self.apply_power_policy().await?;
        }
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<messages::ReportHostWallpaperStartup> for BridgeActor<E> {
    type Reply = messages::InitialFrameReadyReply;

    async fn handle(
        &mut self,
        msg: messages::ReportHostWallpaperStartup,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if msg.startup_revision != self.reserved_startup_revision() {
            return Ok(self.all_snapshots());
        }
        let current = if let Some(key) = msg.native_admission_key {
            self.native_video_wallpapers()?.iter().any(|wallpaper| {
                wallpaper.display_id == msg.display_id && wallpaper.wallpaper_id == msg.wallpaper_id
                    && wallpaper.admission_key == key
            })
        } else {
            self.web_wallpapers()?.iter().any(|wallpaper| {
                wallpaper.display_id == msg.display_id && wallpaper.wallpaper_id == msg.wallpaper_id
            })
        };
        if !current { return Ok(self.all_snapshots()); }
        self.state.initial_frame_ready |= msg.ready;
        if self.state.pending_battery_pause_after_initial_frame {
            self.state.pending_battery_pause_after_initial_frame = false;
            self.apply_power_policy().await?;
        }
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetGlobalPlayback> for BridgeActor<E> {
    type Reply = messages::SetGlobalPlaybackReply;

    async fn handle(
        &mut self,
        msg: SetGlobalPlayback,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_playback(msg.playback_state, PlaybackChangeOrigin::Manual)
            .await?;
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<Shutdown> for BridgeActor<E> {
    type Reply = messages::ShutdownReply;

    async fn handle(
        &mut self,
        _msg: Shutdown,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        // Quitting while a scene is still loading is not a crash.
        self.load_journal.clean_shutdown();
        self.mouse_polling.set_policy_enabled(false);
        let mut active_handles = Vec::new();
        for display in self.engine.display_snapshot() {
            let Some(handle) = display.handle else {
                continue;
            };
            if active_handles.contains(&handle) {
                continue;
            }
            active_handles.push(handle);
        }

        let result = async {
            self.engine.set_audio_capture_demand(AudioCaptureDemand {
                suspended: true,
                external_consumers: false,
            }).await?;
            for handle in active_handles {
                self.engine.set_audio_capture_enabled(handle, false).await?;
            }
            self.engine.close_all_scenes().await
        }
        .await;
        if result.is_err() {
            self.refresh_mouse_polling_policy();
        }
        result.map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<SetVolume> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetVolume,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let SetVolume { wallpaper_id, volume } = msg;
        let level = AudioVolume::try_from(volume)
            .map_err(|error| BridgeError::invalid_input(error.to_string()))?;
        let saved = self
            .state
            .wallpaper_draft_mut(&wallpaper_id)?
            .set_volume_immediate(volume)?;
        self.save_wallpaper(wallpaper_id.clone(), saved)?;
        // Mirrors follow their source, so only the scenes of their own are told.
        for handle in self.wallpaper_handles(&wallpaper_id, false) {
            self.engine
                .set_audio_volume(handle, level)
                .await
                .map_err(engine_failed)?;
        }
        self.invalidate_operations();
        self.wallpaper_bundle(wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetMuted> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetMuted,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_muted_immediate(msg.muted);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        for handle in self.wallpaper_handles(&msg.wallpaper_id, false) {
            self.engine
                .set_audio_muted(handle, msg.muted || self.state.audio_suppressed)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetAudioResponseEnabled> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::WallpaperMutationReply>;

    async fn handle(
        &mut self,
        msg: SetAudioResponseEnabled,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.pending_audio_changes.contains(&msg.wallpaper_id) {
            return ctx.reply(Err(BridgeError::invalid_input(
                "An audio response change is still in progress.",
            )));
        }
        let previous_enabled = match self.state.wallpaper_draft_mut(&msg.wallpaper_id) {
            Ok(draft) => draft.current().audio.response_enabled,
            Err(error) => return ctx.reply(Err(error)),
        };
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)
            .expect("wallpaper draft was validated")
            .set_audio_response_enabled_immediate(msg.enabled);
        if let Err(error) = self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config) {
            let _ = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)
                .expect("wallpaper draft was validated")
                .set_audio_response_enabled_immediate(previous_enabled);
            return ctx.reply(Err(error));
        }
        self.invalidate_operations();
        let handles = self.wallpaper_handles(&msg.wallpaper_id, true);
        self.pending_audio_changes.insert(msg.wallpaper_id.clone());
        let actor = ctx.actor_ref().clone();
        let engine = self.engine.clone();
        ctx.spawn(async move {
            let mut result = Ok(());
            for &handle in &handles {
                if let Err(error) = register_audio_capture(&engine, handle, msg.enabled).await {
                    result = Err(BridgeError::engine(error.to_string()));
                    break;
                }
            }
            if result.is_err() {
                for handle in handles {
                    if let Err(error) =
                        register_audio_capture(&engine, handle, previous_enabled).await
                    {
                        log::warn!("could not restore audio response after failed change: {error}");
                    }
                }
            }
            actor
                .ask(CompleteAudioResponse {
                    wallpaper_id: msg.wallpaper_id,
                    previous_enabled,
                    result,
                })
                .await
                .map_err(map_send_error)
        })
    }
}

impl<E: EngineFacade + Clone> Message<CompleteAudioResponse> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: CompleteAudioResponse,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.pending_audio_changes.remove(&msg.wallpaper_id);
        let demand_result = if msg.result.is_ok() {
            self.engine.set_audio_capture_demand(self.audio_capture_demand(self.playback_paused()))
                .await.map_err(|error| BridgeError::engine(error.to_string()))
        } else { Ok(()) };
        let demand_failed = demand_result.is_err();
        if let Err(error) = msg.result.and(demand_result) {
            let config = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)?
                .set_audio_response_enabled_immediate(msg.previous_enabled);
            self.save_wallpaper(msg.wallpaper_id.clone(), config)?;
            if demand_failed {
                for handle in self.wallpaper_handles(&msg.wallpaper_id, true) {
                    if let Err(rollback) = register_audio_capture(&self.engine, handle, msg.previous_enabled).await {
                        log::warn!("could not restore audio registration: {rollback}");
                    }
                }
            }
            if let Err(rollback) = self.engine
                .set_audio_capture_demand(self.audio_capture_demand(self.playback_paused())).await {
                log::warn!("could not restore audio demand: {rollback}");
            }
            self.invalidate_operations();
            return Err(error);
        }
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayConfigEnabled> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    /// Edits the draft only; Apply is what saves it and tells the engine.
    async fn handle(
        &mut self,
        msg: SetDisplayConfigEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.resolve_operation_selector(&msg.display_id, &displays)?;
        // Read before the edit: the draft seeds its assignment from what is saved.
        let enabled_displays = self.state.enabled_selectors(&msg.wallpaper_id);
        // The same display can be saved under several selectors, so the switch
        // has to reach every one a later primary change or reconnect may use.
        let mut aliases = vec![selector.clone()];
        if let Some(display) = selector.to_selector().resolve_display(&displays) {
            if displays
                .first()
                .is_some_and(|primary| display.matches_primary(primary))
            {
                aliases.push(SerializedSelector::Primary);
            }
            if let Some(identity) = display.stable_identity_selector() {
                aliases.push(identity);
            }
            aliases.dedup();
        }
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_display_aliases_enabled(&aliases, msg.enabled, &enabled_displays);
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetScalingMode> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    /// The mode is committed at once, saved and pushed to a running scene.
    async fn handle(
        &mut self,
        msg: SetScalingMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let SetScalingMode { wallpaper_id, display_id, mode } = msg;
        let displays = self.engine.display_snapshot();
        let selector = self.resolve_operation_selector(&display_id, &displays)?;
        let mode = ScalingMode::from(mode);
        let saved = self
            .state
            .wallpaper_draft_mut(&wallpaper_id)?
            .set_scaling_mode_immediate(selector.clone(), mode);
        self.save_wallpaper(wallpaper_id.clone(), saved)?;
        if let Some(handle) = self.display_handle(&wallpaper_id, &selector) {
            self.engine
                .set_scaling_mode(handle, mode)
                .await
                .map_err(engine_failed)?;
        }
        self.invalidate_operations();
        self.wallpaper_bundle(wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetScalingFactor> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    /// A draft edit held behind Apply; a running scene previews it live.
    async fn handle(
        &mut self,
        msg: SetScalingFactor,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let SetScalingFactor { wallpaper_id, display_id, factor } = msg;
        let displays = self.engine.display_snapshot();
        let selector = self.resolve_operation_selector(&display_id, &displays)?;
        // Validation happens in the draft, before the engine hears anything.
        self.state
            .wallpaper_draft_mut(&wallpaper_id)?
            .set_scaling_factor(selector.clone(), factor)?;
        if let Some(handle) = self.display_handle(&wallpaper_id, &selector) {
            self.engine
                .set_scaling_factor(handle, factor)
                .await
                .map_err(engine_failed)?;
        }
        self.invalidate_operations();
        self.wallpaper_bundle(wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayPosition> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    /// Moves a wallpaper on one display, live and for good.
    ///
    /// The position is saved before the engine hears of it, so a renderer that
    /// refuses the update leaves the choice kept and the next reconcile builds
    /// the scene at it. Repeating the saved position does neither, which keeps
    /// a drag editor that reports on every pointer event from writing the file
    /// again for a value it already holds.
    async fn handle(
        &mut self,
        msg: SetDisplayPosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.resolve_operation_selector(&msg.display_id, &displays)?;
        let update = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_position_immediate(selector.clone(), msg.pan_x, msg.pan_y)?;
        if !update.changed {
            // A drag that ended where it began saves nothing, yet the renderer
            // may still be showing the last position it was previewed at.
            if let Some(handle) = self
                .display_handle(&msg.wallpaper_id, &selector)
                .filter(|handle| self.previewed_framing.contains(handle))
            {
                self.engine
                    .set_framing(handle, update.framing.to_scene())
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))?;
                self.previewed_framing.remove(&handle);
            }
            return self.wallpaper_bundle(msg.wallpaper_id);
        }

        if let Err(error) = self.save_wallpaper(msg.wallpaper_id.clone(), update.config) {
            // Nothing reached the disk, so the draft must not claim it did:
            // the same position asked for again has to be saved, not skipped
            // as already held.
            let _ = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)?
                .set_position_immediate(
                    selector,
                    Some(update.previous.pan_x),
                    Some(update.previous.pan_y),
                );
            return Err(error);
        }
        log::debug!(
            "wallpaper {} display {}: position {:.3},{:.3}",
            msg.wallpaper_id,
            msg.display_id,
            update.framing.pan_x,
            update.framing.pan_y,
        );
        if let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) {
            self.engine
                .set_framing(handle, update.framing.to_scene())
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
            self.previewed_framing.remove(&handle);
        }
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<PreviewDisplayPosition> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;

    /// Shows a wallpaper at a position on one display while a drag toward it
    /// is under way, and keeps nothing.
    ///
    /// Only the renderer moves. The position is not saved, the generation does
    /// not advance, no snapshot is built and the lock-screen export, which
    /// comes from the saved configuration, does not change, so a drag editor
    /// can send one per step. The drag ends with [`SetDisplayPosition`] for the
    /// value the person settled on, which is what saves it. A display that is
    /// gone, or that no scene of the engine draws (a video the native player
    /// plays, a display turned off), has nothing to move and is not an error.
    async fn handle(
        &mut self,
        msg: PreviewDisplayPosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        // Checked before anything is looked up, so a value that cannot be a
        // position is refused whatever the display is doing.
        moved_framing(FramingCfg::default(), msg.pan_x, msg.pan_y)?;
        self.state.ensure_wallpaper_exists(&msg.wallpaper_id)?;
        let displays = self.engine.display_snapshot();
        let Ok(selector) = self.resolve_operation_selector(&msg.display_id, &displays) else {
            return Ok(());
        };
        let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) else {
            return Ok(());
        };
        let saved = self
            .state
            .wallpaper_configs
            .get(&msg.wallpaper_id)
            .map_or_else(FramingCfg::default, |config| {
                saved_framing(config, &selector)
            });
        let framing = moved_framing(saved, msg.pan_x, msg.pan_y)?;
        self.engine
            .preview_framing(handle, framing.to_scene())
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.previewed_framing.insert(handle);
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<PreviewWallpaperProperties> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;

    /// Shows a wallpaper's pending property edits on the scenes that draw it,
    /// or puts the saved look back, and keeps nothing. See
    /// [`BridgeActor::show_wallpaper_properties`].
    async fn handle(
        &mut self,
        msg: PreviewWallpaperProperties,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.show_wallpaper_properties(&msg.wallpaper_id, msg.show, msg.pending)
            .await
    }
}

impl<E: EngineFacade + Clone> Message<SetTargetFps> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetTargetFps,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.resolve_operation_selector(&msg.display_id, &displays)?;
        let source_display_id = self.operation_source_id(&selector, &displays)?;
        let max_fps = displays
            .iter()
            .find(|display| display.desc.display_id == source_display_id)
            .map(|display| display.desc.refresh_rate_hz.max(1))
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown display id {source_display_id}"))
            })?;
        let resolved = crate::config::resolve_frame_rate(
            crate::config::stored_frame_rate(msg.fps, max_fps),
            max_fps,
        );
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_target_fps_immediate(selector.clone(), msg.fps, max_fps);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        if let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) {
            self.engine
                .set_fps(handle, self.live_target_fps(resolved))
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<EditProperty> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: EditProperty,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let model = self.state.project_model(&msg.wallpaper_id)?.clone();
        model.check_edit(&msg.property_id, &msg.value)?;
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .edit_property(&model, &msg.property_id, PropertyValue::from(msg.value));
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<RestorePropertyDefault> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: RestorePropertyDefault,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let property_exists = self
            .state
            .project_model(&msg.wallpaper_id)?
            .properties
            .iter()
            .any(|property| property.id == msg.property_id);
        if !property_exists {
            return Err(BridgeError::invalid_input(format!(
                "unknown property id {}",
                msg.property_id
            )));
        }
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .restore_property_default(&msg.property_id);
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<RestoreAllPropertyDefaults> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: RestoreAllPropertyDefaults,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let keep = self
            .state
            .project_model(&msg.wallpaper_id)?
            .user_asset_property_ids();
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .restore_all_property_defaults(&keep);
        self.invalidate_operations();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}
