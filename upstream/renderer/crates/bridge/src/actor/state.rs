pub mod drafts {
    pub use crate::state::drafts::*;
}

use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
    time::Instant,
};

use drafts::WallpaperOptionsDraft;
use wallpaper_core::project::{SceneDesc, WallpaperProjectType};

use crate::{
    api::{
        BridgeDisplaySettingsRow, BridgeError, BridgePlaybackState, BridgePropertyEdit,
        BridgeQualityThrottleCause,
        BridgeWallpaperEntry, BridgeWallpaperKind,
    },
    config::{AppConfig, QualityInForce, SerializedSelector, WallpaperConfig},
    engine::NativeVideoRejections,
    project::{ProjectModel, localization::FALLBACK_LOCALE},
};

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug)]
pub struct BridgeActorState {
    pub(crate) shader_cache_size: Arc<Mutex<Option<(Instant, u64)>>>,
    pub playback_state: BridgePlaybackState,
    /// Global presentation suspension: display sleep or session lock, where no
    /// display can show a wallpaper pixel at all.
    pub presentation_suspended: bool,
    /// Presentation is unloaded: scene runtimes and host wallpaper windows are
    /// closed to free memory, while config and assignments stay put. Distinct
    /// from suspension, which keeps the runtimes and only stops them drawing.
    pub presentation_unloaded: bool,
    /// Transient mute applied on top of each wallpaper's saved mute. Never
    /// persisted. A user unmute while this is set stays muted until it clears.
    pub audio_suppressed: bool,
    /// Why the host currently asks for the reduced-quality profile, beyond the
    /// battery mode the user saved. Empty by default and never persisted, like
    /// `audio_suppressed`: the host reports the conditions again at every
    /// start.
    pub quality_throttle: BTreeSet<BridgeQualityThrottleCause>,
    /// Languages a wallpaper's own label tables are read in, most preferred
    /// first, as Wallpaper Engine locale codes. Supplied by the host from the
    /// app's language and never persisted, like `audio_suppressed`. English is
    /// always in the list as the fallback.
    pub label_locales: Vec<String>,
    /// Displays suspended on their own, by occlusion for example. Kept apart
    /// from the global flag so one hidden screen cannot pause a visible one,
    /// and from `playback_state` so resuming visibility never clears the user's
    /// own pause.
    pub suspended_displays: BTreeSet<u32>,
    /// Whether a diagnostic session asked the renderer to count its work. Off
    /// by default; nothing counts and nothing is reported until it is on.
    pub renderer_counters_enabled: bool,
    /// Refusals the native video player recorded, per wallpaper id and then
    /// per admission key — one key per display slot, so two displays showing
    /// the same clip at different target rates are refused independently and
    /// neither refusal erases the other. A refusal excludes only the
    /// configuration it describes: raise the target frame rate, restore an
    /// unsupported setting or replace the media file and that slot is offered
    /// natively again. Within one configuration it holds for the session, so a
    /// wallpaper cannot oscillate between the two backends, and the scene
    /// engine — which supports everything — takes it back.
    pub native_video_rejected: NativeVideoRejections,
    /// A refusal was dropped because the configuration it described is gone
    /// (the frame-rate ceiling moved), and the scene list has not been rebuilt
    /// since, so the engine may still hold a scene for a clip the native player
    /// is offered again. Set when the refusal goes and cleared only by the
    /// rebuild that hands the clip back: a rebuild that failed leaves it set, so
    /// the next change of quality, or the host's next ask for the native list,
    /// owes the same rebuild instead of finding nothing left to drop.
    pub native_video_release_owed: bool,
    /// Wallpapers the load journal holds back: the app died while opening
    /// them in consecutive sessions. Activation plans skip them until the
    /// user applies one again. Nothing here is persisted; the journal is.
    pub held_wallpapers: BTreeSet<String>,
    pub selected_wallpaper_id: Option<String>,
    pub active_wallpaper_ids: Vec<String>,
    pub errors: Vec<String>,
    pub library: Vec<BridgeWallpaperEntry>,
    /// Whether `library` came from a successful scan of the workshop root.
    /// Only then does a wallpaper missing from it mean the files are gone.
    pub library_scanned: bool,
    pub app_config: AppConfig,
    pub wallpaper_configs: BTreeMap<String, WallpaperConfig>,
    pub wallpaper_drafts: BTreeMap<String, WallpaperOptionsDraft>,
    pub project_models: BTreeMap<String, ProjectModel>,
    pub display_settings: BTreeMap<String, BridgeDisplaySettingsRow>,
    pub power_source: crate::power::PowerSource,
    pub auto_paused_for_battery: bool,
    pub battery_pause_suppressed: bool,
    pub startup_power_sample_received: bool,
    pub initial_frame_ready: bool,
    pub pending_battery_pause_after_initial_frame: bool,
    pub filter_scene: bool,
    pub filter_video: bool,
    pub filter_webpage: bool,
    pub filter_unknown: bool,
    /// Web pages that have registered an audio listener, keyed by wallpaper id
    /// and then by the display their web view renders on.
    ///
    /// A web wallpaper has no scene handle, so it is invisible to the
    /// handle-based audio accounting. Without this the system capture tap
    /// would stay shut for a display showing nothing but web wallpapers.
    pub web_audio_subscribers: BTreeMap<String, BTreeSet<u32>>,
}

impl Default for BridgeActorState {
    fn default() -> Self {
        Self {
            shader_cache_size: Arc::default(),
            playback_state: BridgePlaybackState::Playing,
            presentation_suspended: false,
            presentation_unloaded: false,
            audio_suppressed: false,
            quality_throttle: BTreeSet::new(),
            label_locales: vec![FALLBACK_LOCALE.to_owned()],
            suspended_displays: BTreeSet::new(),
            renderer_counters_enabled: false,
            native_video_rejected: BTreeMap::new(),
            native_video_release_owed: false,
            held_wallpapers: BTreeSet::new(),
            selected_wallpaper_id: None,
            active_wallpaper_ids: Vec::new(),
            errors: Vec::new(),
            library: Vec::new(),
            library_scanned: false,
            app_config: AppConfig::default(),
            wallpaper_configs: BTreeMap::new(),
            wallpaper_drafts: BTreeMap::new(),
            project_models: BTreeMap::new(),
            display_settings: BTreeMap::new(),
            power_source: crate::power::PowerSource::External,
            auto_paused_for_battery: false,
            battery_pause_suppressed: false,
            startup_power_sample_received: false,
            initial_frame_ready: false,
            pending_battery_pause_after_initial_frame: false,
            filter_scene: true,
            filter_video: true,
            filter_webpage: true,
            filter_unknown: true,
            web_audio_subscribers: BTreeMap::new(),
        }
    }
}

pub struct ApplyCandidates {
    pub app_config: AppConfig,
    pub wallpaper_config: WallpaperConfig,
    pub wallpaper_configs: BTreeMap<String, WallpaperConfig>,
    pub enabled_displays: Vec<SerializedSelector>,
    pub requires_reconcile: bool,
}

impl BridgeActorState {
    #[allow(clippy::single_call_fn)]
    pub fn from_app_config(app_config: AppConfig) -> Self {
        let active_wallpaper_ids = Self::active_ids(&app_config);
        Self {
            filter_scene: app_config.ui.filter.scene,
            filter_video: app_config.ui.filter.video,
            filter_webpage: app_config.ui.filter.web,
            filter_unknown: app_config.ui.filter.unknown,
            selected_wallpaper_id: app_config.general.last_selected_wallpaper.clone(),
            active_wallpaper_ids,
            app_config,
            ..Self::default()
        }
    }

    pub fn apply_startup_power_source(&mut self, source: crate::power::PowerSource) {
        self.power_source = source;
        self.startup_power_sample_received = true;
        self.pending_battery_pause_after_initial_frame = source
            == crate::power::PowerSource::Battery
            && self.app_config.power.on_battery == crate::config::BatteryModeCfg::Pause
            && !self.initial_frame_ready;
    }

    pub fn filter_enabled(&self, kind: BridgeWallpaperKind) -> bool {
        match kind {
            BridgeWallpaperKind::ProjectScene => self.filter_scene,
            BridgeWallpaperKind::Video => self.filter_video,
            BridgeWallpaperKind::Webpage => self.filter_webpage,
            BridgeWallpaperKind::Unknown => self.filter_unknown,
        }
    }

    pub fn ensure_wallpaper_exists(&self, wallpaper_id: &str) -> Result<(), BridgeError> {
        self.library
            .iter()
            .any(|entry| entry.id == wallpaper_id)
            .then_some(())
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown wallpaper id {wallpaper_id}"))
            })
    }

    /// The documents of a scene wallpaper's pending property edits, or `None`
    /// for a wallpaper whose scenes take none: a video, a web page, and one
    /// whose project is not loaded, none of which a property document reaches.
    ///
    /// `pending` is made to the draft for these documents alone (see
    /// [`WallpaperOptionsDraft::with_edits`]), and is not looked at for a
    /// wallpaper with no documents.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or a pending value is
    /// not one its property accepts.
    pub fn pending_property_documents(
        &self,
        wallpaper_id: &str,
        pending: Vec<BridgePropertyEdit>,
    ) -> Result<Option<drafts::PropertyDocuments>, BridgeError> {
        self.ensure_wallpaper_exists(wallpaper_id)?;
        let Some(model) = self
            .project_models
            .get(wallpaper_id)
            .filter(|model| model.project_type == WallpaperProjectType::Scene)
        else {
            return Ok(None);
        };
        let edits = model.checked_edits(pending)?;
        Ok(Some(match self.wallpaper_drafts.get(wallpaper_id) {
            Some(draft) => draft.with_edits(model, &edits).property_documents(model),
            // Nothing was edited, so the draft that would be made is the saved
            // configuration twice.
            None => {
                let saved = self
                    .wallpaper_configs
                    .get(wallpaper_id)
                    .cloned()
                    .unwrap_or_else(|| WallpaperConfig::new_for(wallpaper_id, "scene"));
                WallpaperOptionsDraft::from_committed(saved)
                    .with_edits(model, &edits)
                    .property_documents(model)
            }
        }))
    }

    pub fn project_model(&self, wallpaper_id: &str) -> Result<&ProjectModel, BridgeError> {
        self.ensure_wallpaper_exists(wallpaper_id)?;
        self.project_models.get(wallpaper_id).ok_or_else(|| {
            BridgeError::invalid_input(format!(
                "no project model loaded for wallpaper id {wallpaper_id}"
            ))
        })
    }

    pub fn wallpaper_draft(
        &self,
        wallpaper_id: &str,
    ) -> Result<WallpaperOptionsDraft, BridgeError> {
        self.ensure_wallpaper_exists(wallpaper_id)?;
        Ok(self
            .wallpaper_drafts
            .get(wallpaper_id)
            .cloned()
            .or_else(|| {
                self.wallpaper_configs
                    .get(wallpaper_id)
                    .cloned()
                    .map(|config| {
                        WallpaperOptionsDraft::from_committed_with_enabled_displays(
                            config,
                            self.enabled_selectors(wallpaper_id),
                        )
                    })
            })
            .unwrap_or_else(|| {
                WallpaperOptionsDraft::from_committed_with_enabled_displays(
                    WallpaperConfig::new_for(wallpaper_id, "scene"),
                    self.enabled_selectors(wallpaper_id),
                )
            }))
    }

    pub fn apply_candidates(
        &self,
        wallpaper_id: &str,
        primary_identity_selector: Option<&SerializedSelector>,
    ) -> Result<ApplyCandidates, BridgeError> {
        let draft = self.wallpaper_draft(wallpaper_id)?;
        let active_enabled_displays = self.enabled_selectors(wallpaper_id);
        let requires_reconcile = draft.requires_reconcile(&active_enabled_displays);
        let wallpaper_config = draft.current().clone();
        let mut wallpaper_config = wallpaper_config;
        let enabled_displays = draft.effective_enabled_displays(&active_enabled_displays);
        let mut app_config = self.app_config.clone();

        for monitor in &mut app_config.monitors {
            if monitor.wallpaper.as_deref() == Some(wallpaper_id) {
                monitor.wallpaper = None;
            }
        }

        for selector in &enabled_displays {
            let monitor = app_config.ensure_monitor(selector.clone());
            monitor.enabled = true;
            monitor.mode = "independent".to_string();
            monitor.wallpaper = Some(wallpaper_id.to_string());
        }

        if let Some(identity_selector) = primary_identity_selector {
            if let Some(primary_index) = app_config
                .monitors
                .iter()
                .position(|monitor| monitor.selector == SerializedSelector::Primary)
            {
                let mut identity_monitor = app_config.monitors[primary_index].clone();
                identity_monitor.selector = identity_selector.clone();
                match app_config
                    .monitors
                    .iter()
                    .position(|monitor| &monitor.selector == identity_selector)
                {
                    Some(identity_index) => app_config.monitors[identity_index] = identity_monitor,
                    None => app_config.monitors.push(identity_monitor),
                }
            }

            if let Some(primary_index) = wallpaper_config
                .monitors
                .iter()
                .position(|render| render.selector == SerializedSelector::Primary)
            {
                let mut identity_render = wallpaper_config.monitors[primary_index].clone();
                identity_render.selector = identity_selector.clone();
                match wallpaper_config
                    .monitors
                    .iter()
                    .position(|render| &render.selector == identity_selector)
                {
                    Some(identity_index) => {
                        wallpaper_config.monitors[identity_index] = identity_render;
                    }
                    None => wallpaper_config.monitors.push(identity_render),
                }
            }
        }

        let mut wallpaper_configs = self.wallpaper_configs.clone();
        wallpaper_configs.insert(wallpaper_id.to_string(), wallpaper_config.clone());

        Ok(ApplyCandidates {
            app_config,
            wallpaper_config,
            wallpaper_configs,
            enabled_displays,
            requires_reconcile,
        })
    }

    pub fn commit_apply_candidates(
        &mut self,
        wallpaper_id: String,
        candidates: ApplyCandidates,
        active_from_config: bool,
    ) -> Result<(), BridgeError> {
        self.ensure_wallpaper_exists(&wallpaper_id)?;
        self.app_config = candidates.app_config;
        self.wallpaper_configs = candidates.wallpaper_configs;
        if active_from_config {
            self.refresh_active_ids();
        }
        self.wallpaper_drafts.insert(
            wallpaper_id,
            WallpaperOptionsDraft::from_committed_with_enabled_displays(
                candidates.wallpaper_config,
                candidates.enabled_displays,
            ),
        );
        Ok(())
    }

    pub fn refresh_active_ids(&mut self) {
        self.active_wallpaper_ids = Self::active_ids(&self.app_config);
    }

    /// Active ids are the engine-rendered scenes plus every configured web
    /// wallpaper, which the host renders outside the scene engine.
    pub fn set_active_ids_from_scenes(&mut self, scenes: &[SceneDesc]) {
        // An unload reconcile hands in an empty scene list so windows close.
        // That must not wipe the panel's active marks; the assignments are
        // still configured.
        if self.presentation_unloaded && scenes.is_empty() {
            return;
        }
        let mut ids = scenes
            .iter()
            .filter_map(|scene| {
                let path = std::path::Path::new(&scene.scene_path);
                path.parent()?
                    .file_name()?
                    .to_str()
                    .filter(|id| !id.is_empty())
                    .map(ToString::to_string)
            })
            .chain(
                Self::active_ids(&self.app_config)
                    .into_iter()
                    .filter(|id| self.is_web_wallpaper(id)),
            )
            .collect::<Vec<_>>();
        ids.sort();
        ids.dedup();
        self.active_wallpaper_ids = ids;
    }

    pub fn is_web_wallpaper(&self, wallpaper_id: &str) -> bool {
        self.project_models
            .get(wallpaper_id)
            .is_some_and(|model| model.project_type == WallpaperProjectType::Web)
    }

    /// Project models for the wallpapers `app_config` assigns to displays;
    /// the subset reconciliation needs to route web projects away from the
    /// scene engine.
    pub fn configured_project_models(
        &self,
        app_config: &AppConfig,
    ) -> BTreeMap<String, ProjectModel> {
        app_config
            .monitors
            .iter()
            .filter_map(|monitor| monitor.wallpaper.as_deref())
            .filter_map(|id| {
                self.project_models
                    .get(id)
                    .map(|model| (id.to_string(), model.clone()))
            })
            .collect()
    }

    pub fn wallpaper_draft_mut(
        &mut self,
        wallpaper_id: &str,
    ) -> Result<&mut WallpaperOptionsDraft, BridgeError> {
        self.ensure_wallpaper_exists(wallpaper_id)?;
        if !self.wallpaper_drafts.contains_key(wallpaper_id) {
            let committed = self
                .wallpaper_configs
                .get(wallpaper_id)
                .cloned()
                .unwrap_or_else(|| WallpaperConfig::new_for(wallpaper_id, "scene"));
            let enabled_displays = self.enabled_selectors(wallpaper_id);
            self.wallpaper_drafts.insert(
                wallpaper_id.to_string(),
                WallpaperOptionsDraft::from_committed_with_enabled_displays(
                    committed,
                    enabled_displays,
                ),
            );
        }

        Ok(self
            .wallpaper_drafts
            .get_mut(wallpaper_id)
            .expect("draft exists after insertion"))
    }

    /// Displays showing `wallpaper_id` as their own wallpaper. A mirror keeps
    /// whatever wallpaper it had before it started mirroring, but it shows its
    /// source instead; counting it here would let the next Apply of that
    /// wallpaper quietly turn the mirror back into an independent display.
    pub fn enabled_selectors(&self, wallpaper_id: &str) -> Vec<SerializedSelector> {
        self.app_config
            .monitors
            .iter()
            .filter(|monitor| {
                monitor.enabled
                    && monitor.mode != "mirror"
                    && monitor.wallpaper.as_deref() == Some(wallpaper_id)
            })
            .map(|monitor| monitor.selector.clone())
            .collect()
    }

    pub fn configured_ids(&self) -> Vec<String> {
        Self::active_ids(&self.app_config)
    }

    /// The held wallpapers a display is assigned to, sorted. A hold on a
    /// wallpaper nothing shows is not worth a notice; it comes back the moment
    /// the wallpaper is assigned again.
    #[must_use]
    pub fn held_assigned_ids(&self) -> Vec<String> {
        let assigned = self.configured_ids();
        self.held_wallpapers
            .iter()
            .filter(|id| assigned.contains(id))
            .cloned()
            .collect()
    }

    /// The installed wallpapers, once a scan has established them; `None`
    /// before that, when nothing is known to be missing.
    #[must_use]
    pub fn scanned_library(&self) -> Option<&[BridgeWallpaperEntry]> {
        self.library_scanned.then_some(self.library.as_slice())
    }

    pub fn replace_library(&mut self, library: Vec<BridgeWallpaperEntry>) {
        self.library = library;
        if let Some(selected_wallpaper_id) = &self.selected_wallpaper_id
            && !self
                .library
                .iter()
                .any(|entry| entry.id == *selected_wallpaper_id)
        {
            self.selected_wallpaper_id = None;
            self.app_config.general.last_selected_wallpaper = None;
        }
    }

    pub fn rebase_drafts(&mut self) {
        let enabled_by_wallpaper = self
            .wallpaper_drafts
            .keys()
            .map(|wallpaper_id| (wallpaper_id.clone(), self.enabled_selectors(wallpaper_id)))
            .collect::<Vec<_>>();

        for (wallpaper_id, enabled_displays) in enabled_by_wallpaper {
            if let Some(draft) = self.wallpaper_drafts.get_mut(&wallpaper_id) {
                draft.rebase_enabled_displays(enabled_displays);
            }
        }
    }

    fn active_ids(app_config: &AppConfig) -> Vec<String> {
        let mut ids = app_config
            .monitors
            .iter()
            .filter(|monitor| monitor.enabled && monitor.mode != "mirror")
            .filter_map(|monitor| monitor.wallpaper.clone())
            .collect::<Vec<_>>();
        ids.sort();
        ids.dedup();
        ids
    }
}

impl BridgeActorState {
    /// Which reasons for the reduced-quality profile hold right now: the
    /// battery mode the user saved while the Mac is on battery, and the
    /// causes the host asked for.
    pub(super) fn quality_in_force(&self) -> QualityInForce {
        QualityInForce {
            battery_profile: self.app_config.power.on_battery
                == crate::config::BatteryModeCfg::ReducedQuality
                && self.power_source == crate::power::PowerSource::Battery,
            throttled: !self.quality_throttle.is_empty(),
        }
    }

    /// The frame-rate ceiling in force, shared by routing and snapshots so
    /// native admission keys use the same one: the global cap, the reduced
    /// quality profile's rate while the battery mode or a throttle holds it,
    /// or the stricter of the two. It only ever lowers what the user chose.
    pub(super) fn active_target_fps_cap(&self) -> Option<u32> {
        let quality = &self.app_config.quality;
        let global = quality.frame_rate_cap.map(|cap| cap.max(1));
        let in_force = self.quality_in_force();
        let profile = (in_force.battery_profile || in_force.throttled)
            .then(|| quality.battery.target_fps.max(1));
        match (global, profile) {
            (Some(global), Some(profile)) => Some(global.min(profile)),
            (Some(global), None) => Some(global),
            (None, Some(profile)) => Some(profile),
            (None, None) => None,
        }
    }
}
