use std::{
    collections::BTreeMap,
    sync::PoisonError,
    time::{Duration, Instant},
};

use super::projection_values::directory_size;

use wallpaper_core::{DisplaySnapshotEntry, SceneBackend, SceneUpdateMode};

use crate::{
    actor::state::BridgeActorState,
    api::{
        BridgeComboOption, BridgeDirectoryMode, BridgeError, BridgeFileFilter,
        BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgePropertyValue,
        BridgeSceneBackendReport,
        BridgeSceneUpdateModeReport, BridgeSettingsSnapshot, BridgeSliderMetadata,
        BridgeStorageStatus, BridgeVideoBackendReport, BridgeWallpaperOptionsSnapshot,
        bridge_log_status,
    },
    config::{AppConfig, SceneResolutionCfg},
    engine::{ActivationInputs, SceneRuntimeReport},
    display::DisplayLabelExt,
    logging::{ApplicationLogger, LogStatus},
    login::LaunchAtLoginStatus,
    paths::BridgePaths,
    project::{Condition, DirectoryMode, FileFilter, FileMedia, PropertyMetadata, PropertyValue},
    user_assets::UserAssetManifest,
};

const UNKNOWN_GIT_SHA: &str = "Unknown";
const SHADER_PIPELINE_VERSION: &str = "0.1.0";
const RUNNING_BACKEND_NATIVE: &str = "native";
const SCENE_RESOLUTION_CANVAS: &str = "canvas";
const SCENE_RESOLUTION_DISPLAY: &str = "display";
const SCENE_BACKEND_NATIVE_METAL: &str = "native_metal";
/// A scene that is running and whose backend the renderer could not name.
/// Distinct from the real backend on purpose.
const SCENE_BACKEND_UNKNOWN: &str = "unknown";
const SCENE_MODE_CONTINUOUS: &str = "continuous";
const SCENE_MODE_WAITING_FOR_EVENT: &str = "waiting_for_event";
const SCENE_MODE_WAITING_FOR_DEADLINE: &str = "waiting_for_deadline";
const SCENE_MODE_USER_PAUSED: &str = "user_paused";
const SCENE_MODE_POLICY_SUSPENDED: &str = "policy_suspended";
/// A scene whose renderer stopped drawing after a failure nobody asked for. Not
/// a pause: nothing the user or the app chose is holding it still.
const SCENE_MODE_STOPPED_AFTER_FAILURE: &str = "stopped_after_failure";
const SCENE_MODE_NOT_APPLICABLE: &str = "not_applicable";
/// A scene that is running and could not be read. Never `continuous`.
const SCENE_MODE_UNKNOWN: &str = "unknown";

/// How one running scene is named in the panel. A display with no wallpaper
/// recorded against it keeps empty strings rather than a placeholder: the
/// scene's state is still worth reporting even when the host cannot name it.
struct SceneReportLabels {
    display_name: String,
    wallpaper_id: String,
    wallpaper_title: String,
}

/// The filter a file or directory property declared, or `None` when the
/// project declared none: an editor showing "image" there would be inventing a
/// restriction the author never wrote.
fn bridge_file_filter(filter: &FileFilter) -> Option<BridgeFileFilter> {
    filter.raw.as_ref()?;
    Some(match filter.media {
        FileMedia::Image => BridgeFileFilter::Image,
        FileMedia::Video => BridgeFileFilter::Video,
    })
}


impl BridgeActorState {
    pub(crate) fn invalidate_shader_cache_size(&self) {
        *self.shader_cache_size.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }

    // Snapshot bursts (including property edits) must not walk the shader tree each time.
    // Explicit settings reads and cache clearing invalidate this bounded-age measurement.
    fn shader_cache_size_at(&self, now: Instant, measure: impl FnOnce() -> u64) -> u64 {
        let mut cached = self
            .shader_cache_size
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some((read_at, bytes)) = *cached
            && now.saturating_duration_since(read_at) < Duration::from_secs(2)
        {
            return bytes;
        }
        let bytes = measure();
        *cached = Some((now, bytes));
        bytes
    }

    #[allow(clippy::needless_pass_by_value, clippy::too_many_lines)]
    pub fn options(
        &self,
        displays: &[DisplaySnapshotEntry],
        wallpaper_id: String,
        paths: &BridgePaths,
    ) -> Result<BridgeWallpaperOptionsSnapshot, BridgeError> {
        let entry = self
            .library
            .iter()
            .find(|entry| entry.id == wallpaper_id)
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown wallpaper id {wallpaper_id}"))
            })?;

        let draft = self.wallpaper_draft(&wallpaper_id)?;
        let config = draft.current();
        // One read per snapshot, shared by every file and directory property: the
        // manifest is the app's record of what it copied, and the panel needs it to
        // tell an imported asset from one that has gone missing.
        let user_assets_root = paths.user_assets_root();
        let user_assets = UserAssetManifest::load(&user_assets_root, &wallpaper_id);
        let model = self.project_models.get(&wallpaper_id);
        let overrides = model
            .map(|model| model.override_values(&config.property_overrides))
            .unwrap_or_default();
        let active_enabled_displays = self.enabled_selectors(&wallpaper_id);
        Ok(super::snapshot_projection::project_options(
            entry,
            &draft,
            &active_enabled_displays,
            model,
            &overrides,
            &self.app_config,
            displays,
            |property, value| {
                // Projection only annotates properties from this actual model.
                let model = model.expect("property annotation requires its model");
                // A label that is exactly one of the project's own tokens becomes
                // its text in the app's language; anything else is left as written.
                let localized = |raw: &str| {
                    model
                        .localization
                        .resolve(raw, &self.label_locales)
                        .map_or_else(|| raw.to_owned(), str::to_owned)
                };
                let lookup = |id: &str| {
                    overrides.get(id).cloned().or_else(|| {
                        model
                            .properties
                            .iter()
                            .find(|property| property.id == id)
                            .map(crate::project::ProjectProperty::default_value)
                    })
                };
                // A rule that hides a property keeps its row, not enabled: the
                // host still sees what the project defines and what its hidden
                // overrides hold, and decides what to list. A rule that cannot be
                // read leaves the property enabled.
                let enabled = property
                    .condition
                    .as_deref()
                    .and_then(|condition| Condition::parse(condition).ok())
                    .is_none_or(|condition| condition.eval(&lookup));
                let slider = match &property.metadata {
                    PropertyMetadata::Slider {
                        min,
                        max,
                        step,
                        precision,
                        ..
                    } => Some(BridgeSliderMetadata {
                        min: *min,
                        max: *max,
                        step: *step,
                        precision: *precision,
                    }),
                    _ => None,
                };
                let combo_options = match &property.metadata {
                    PropertyMetadata::Combo { options } => options
                        .iter()
                        .map(|option| BridgeComboOption {
                            label: localized(&option.label),
                            value: BridgePropertyValue::from(PropertyValue::String(
                                option.value.clone(),
                            )),
                        })
                        .collect(),
                    _ => Vec::new(),
                };
                let (file_filter, directory_mode) = match &property.metadata {
                    PropertyMetadata::File { filter } => (bridge_file_filter(filter), None),
                    PropertyMetadata::Directory { filter, mode } => (
                        bridge_file_filter(filter),
                        Some(match mode {
                            DirectoryMode::OnDemand => BridgeDirectoryMode::OnDemand,
                            DirectoryMode::FetchAll => BridgeDirectoryMode::FetchAll,
                        }),
                    ),
                    _ => (None, None),
                };
                // Only file and directory properties have a user asset behind
                // them; a texture picker names a path inside the package, which
                // the app never imports and must never report as missing.
                let is_asset_property = matches!(
                    property.metadata,
                    PropertyMetadata::File { .. } | PropertyMetadata::Directory { .. }
                );
                let picked = if is_asset_property {
                    value.to_property_string()
                } else {
                    String::new()
                };
                let asset = if !is_asset_property {
                    crate::user_assets::UserAssetStatus::default()
                } else if let Some(manifest) = user_assets.as_ref() {
                    manifest.status(
                        &user_assets_root,
                        &wallpaper_id,
                        &property.id,
                        &picked,
                    )
                } else {
                    crate::user_assets::unmanaged_status(&picked)
                };
                let asset_source_path = user_assets
                    .as_ref()
                    .and_then(|manifest| manifest.source_path(&property.id))
                    .map(ToString::to_string)
                    .or_else(|| (!picked.is_empty()).then(|| picked.clone()));

                super::snapshot_projection::PropertyAnnotation {
                    label_html: localized(&property.label_html),
                    slider,
                    combo_options,
                    file_filter,
                    directory_mode,
                    enabled,
                    asset_managed: asset.managed,
                    asset_missing: asset.missing,
                    asset_source_path,
                }
            },
        ))
    }

    pub fn monitor_info(
        &self,
        displays: &[DisplaySnapshotEntry],
    ) -> BridgeMonitorInformationSnapshot {
        self.monitor_info_for_app(&self.app_config, displays)
    }

    fn monitor_info_for_app(
        &self,
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> BridgeMonitorInformationSnapshot {
        super::snapshot_projection::project_monitors(
            app_config,
            displays,
            |id| self.wallpaper_configs.get(id),
            |id| self.library.iter().find(|entry| entry.id == id).map(|entry| entry.title.as_str()),
        )
    }

    /// Composes one running scene's renderer read-back with the host's own
    /// pause state into the mode the panel shows.
    ///
    /// Precedence is deliberate and is not the renderer's to decide. A
    /// wallpaper the user paused reads `user_paused` however the renderer has
    /// classified it; a display whose presentation the host suspended reads
    /// `policy_suspended`; a surface that stopped drawing after a failure reads
    /// `stopped_after_failure`; only then does the renderer's own answer show
    /// through. Those are separate states, so an event wake must never look
    /// like the user un-pausing, and a failure must never look like either
    /// kind of pause. The pauses outrank the failure because they are what the
    /// user chose and can undo; the stop is still latched underneath and shows
    /// the moment they are lifted.
    ///
    /// `None` from the renderer means it could not answer, which becomes
    /// `unknown`. It never becomes `continuous`: "we could not tell" is not
    /// evidence that a scene is ticking.
    fn scene_update_mode(&self, report: &SceneRuntimeReport) -> &'static str {
        if self.playback_state == BridgePlaybackState::Paused {
            // Battery policy pauses through the same flag the user does, so
            // the two are told apart by who asked, not by the flag.
            return if self.auto_paused_for_battery {
                SCENE_MODE_POLICY_SUSPENDED
            } else {
                SCENE_MODE_USER_PAUSED
            };
        }
        if self.presentation_suspended || self.suspended_displays.contains(&report.display_id) {
            return SCENE_MODE_POLICY_SUSPENDED;
        }
        if report.surface.is_some_and(|surface| surface.stop.is_some()) {
            return SCENE_MODE_STOPPED_AFTER_FAILURE;
        }
        match report.update_mode {
            Some(SceneUpdateMode::Continuous) => SCENE_MODE_CONTINUOUS,
            Some(SceneUpdateMode::WaitingForEvent) => SCENE_MODE_WAITING_FOR_EVENT,
            Some(SceneUpdateMode::WaitingForDeadline) => SCENE_MODE_WAITING_FOR_DEADLINE,
            Some(SceneUpdateMode::NotApplicable) => SCENE_MODE_NOT_APPLICABLE,
            // A stopped clock the host did not ask for is not a state the user
            // can act on, and `Unknown` is the renderer saying so itself.
            Some(SceneUpdateMode::ClockStopped | SceneUpdateMode::Unknown) | None => {
                SCENE_MODE_UNKNOWN
            }
        }
    }

    /// Display title and wallpaper for every display a runtime report names.
    ///
    /// Built once per snapshot rather than per report: the two scene lists
    /// describe the same displays, and `monitor_rows` walks and allocates the
    /// whole display configuration each time it is called.
    ///
    /// A display the snapshot no longer lists falls back to its numeric id
    /// rather than being dropped: a scene the host cannot name is still a
    /// scene that is running.
    fn scene_report_labels(
        &self,
        displays: &[DisplaySnapshotEntry],
        app_config: &AppConfig,
        candidate: &AppConfig,
        scene_reports: &[SceneRuntimeReport],
    ) -> BTreeMap<u32, SceneReportLabels> {
        let primary = displays.first().map(|first| first.desc.display_id);
        let rows = app_config.monitor_rows(displays);
        let monitor_info = self.monitor_info_for_app(candidate, displays);
        scene_reports
            .iter()
            .map(|report| report.display_id)
            .map(|display_id| {
                let entry = displays
                    .iter()
                    .find(|entry| entry.desc.display_id == display_id);
                let display_name = entry.map_or_else(
                    || display_id.to_string(),
                    |entry| entry.title_with_role(primary == Some(entry.desc.display_id)),
                );
                let wallpaper_id = rows
                    .iter()
                    .find(|row| {
                        row.display_index
                            .and_then(|index| displays.get(index))
                            .is_some_and(|entry| entry.desc.display_id == display_id)
                    })
                    .and_then(|row| monitor_info.rows.iter()
                        .find(|info| info.display_id == row.selector.id())
                        .map(|info| info.wallpaper_id.clone()))
                    .unwrap_or_default();
                let wallpaper_title = self
                    .library
                    .iter()
                    .find(|entry| entry.id == wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default();
                (
                    display_id,
                    SceneReportLabels {
                        display_name,
                        wallpaper_id,
                        wallpaper_title,
                    },
                )
            })
            .collect()
    }

    pub fn settings(
        &self,
        displays: &[DisplaySnapshotEntry],
        launch_at_login: LaunchAtLoginStatus,
        paths: &BridgePaths,
        scene_reports: &[SceneRuntimeReport],
    ) -> BridgeSettingsSnapshot {
        self.operation_candidate_settings(
            &self.app_config,
            displays,
            launch_at_login,
            paths,
            scene_reports,
        )
    }

    #[allow(clippy::too_many_lines)]
    pub(crate) fn operation_candidate_settings(
        &self,
        candidate: &AppConfig,
        displays: &[DisplaySnapshotEntry],
        launch_at_login: LaunchAtLoginStatus,
        paths: &BridgePaths,
        scene_reports: &[SceneRuntimeReport],
    ) -> BridgeSettingsSnapshot {
        let app_config = candidate.normalized(displays);
        let rows = super::snapshot_projection::project_settings_rows(
            &app_config,
            displays,
            || self.display_settings.values(),
        );
        let on_battery = self.power_source == crate::power::PowerSource::Battery;
        let backends = ActivationInputs {
            app_config: candidate,
            wallpapers: &self.wallpaper_configs,
            library: self.scanned_library(),
            displays,
            paused: self.playback_state == BridgePlaybackState::Paused,
            suspended_displays: &self.suspended_displays,
            paths,
            force_shader_refresh: false,
            project_models: &self.project_models,
            frame_rate_cap: self.active_target_fps_cap_for_app(candidate),
            audio_suppressed: self.audio_suppressed,
            held: &self.held_wallpapers,
        }
        .render_backends();
        let video_backends = backends
            .videos
            .into_iter()
            .map(|routed| BridgeVideoBackendReport {
                display_name: displays
                    .iter()
                    .find(|entry| entry.desc.display_id == routed.display.display_id)
                    .map_or_else(
                        || routed.display.display_id.to_string(),
                        |entry| {
                            entry.title_with_role(
                                displays.first().map(|first| first.desc.display_id)
                                    == Some(entry.desc.display_id),
                            )
                        },
                    ),
                display_id: routed.display.display_id,
                wallpaper_title: self
                    .library
                    .iter()
                    .find(|entry| entry.id == routed.wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default(),
                wallpaper_id: routed.wallpaper_id,
                backend: RUNNING_BACKEND_NATIVE.to_string(),
                fallback_reason: routed.problem,
            })
            .collect();
        let scene_labels = self.scene_report_labels(displays, &app_config, candidate, scene_reports);
        let scene_update_modes = scene_reports
            .iter()
            .map(|report| {
                let labels = scene_labels.get(&report.display_id);
                BridgeSceneUpdateModeReport {
                    display_id: report.display_id,
                    display_name: labels.map(|l| l.display_name.clone()).unwrap_or_default(),
                    wallpaper_id: labels.map(|l| l.wallpaper_id.clone()).unwrap_or_default(),
                    wallpaper_title: labels.map(|l| l.wallpaper_title.clone()).unwrap_or_default(),
                    mode: self.scene_update_mode(report).to_string(),
                    reasons: report
                        .demand_reasons
                        .names()
                        .into_iter()
                        .map(str::to_string)
                        .collect(),
                }
            })
            .collect();
        let scene_renderers = scene_reports
            .iter()
            .map(|report| {
                let labels = scene_labels.get(&report.display_id);
                BridgeSceneBackendReport {
                    display_id: report.display_id,
                    display_name: labels.map(|l| l.display_name.clone()).unwrap_or_default(),
                    wallpaper_id: labels.map(|l| l.wallpaper_id.clone()).unwrap_or_default(),
                    wallpaper_title: labels.map(|l| l.wallpaper_title.clone()).unwrap_or_default(),
                    // A backend the renderer could not name (a scene still
                    // being read, or one held in a failure) is reported as
                    // unknown rather than assumed to be drawing.
                    backend: match report.backend {
                        Some(SceneBackend::NativeMetal) => SCENE_BACKEND_NATIVE_METAL,
                        None => SCENE_BACKEND_UNKNOWN,
                    }
                    .to_string(),
                    failure_stage: report.failure.as_ref().map(|failure| failure.stage.as_str().to_string()),
                    failure_reason: report.failure.as_ref().map(|failure| failure.reason.clone()),
                    video_path: report.video_path.name().to_string(),
                    optimization_applied: report.optimization_applied,
                }
            })
            .collect();
        BridgeSettingsSnapshot {
            displays: rows,
            launch_at_login_available: !matches!(launch_at_login, LaunchAtLoginStatus::Unavailable),
            launch_at_login_enabled: matches!(
                launch_at_login,
                LaunchAtLoginStatus::Available { enabled: true }
            ),
            launch_at_login_needs_approval: launch_at_login == LaunchAtLoginStatus::RequiresApproval,
            battery_mode: candidate.power.on_battery.into(),
            verbose_logging: candidate.diagnostics.verbose_logging,
            git_sha: match option_env!("GIT_SHORT_COMMIT").unwrap_or(env!("WM_FALLBACK_GIT_SHORT_COMMIT")) {
                value if value.trim().is_empty() => UNKNOWN_GIT_SHA.to_string(),
                value => value.to_string(),
            },
            bridge_version: env!("CARGO_PKG_VERSION").to_string(),
            core_version: wallpaper_core::VERSION.to_string(),
            shader_pipeline_version: SHADER_PIPELINE_VERSION.to_string(),
            storage: BridgeStorageStatus {
                shader_cache_size_bytes: self.shader_cache_size_at(Instant::now(), || {
                    directory_size(&paths.shader_cache_root())
                }),
                logs: ApplicationLogger::status().map_or_else(
                    || {
                        bridge_log_status(LogStatus {
                            logs_root: paths.logs_root(),
                            active_session: String::new(),
                            active_file: paths.logs_root().join("0.log"),
                            active_file_size_bytes: 0,
                        })
                    },
                    bridge_log_status,
                ),
            },
            video_backends,
            scene_optimization_enabled: candidate.quality.scene_optimization_enabled,
            scene_on_demand_enabled: candidate.quality.scene_on_demand_enabled,
            scene_video_plane_sampling_enabled: candidate
                .experimental
                .scene_video_plane_sampling,
            scene_resolution: match candidate.quality.scene_resolution {
                SceneResolutionCfg::Canvas => SCENE_RESOLUTION_CANVAS.to_string(),
                SceneResolutionCfg::Display => SCENE_RESOLUTION_DISPLAY.to_string(),
            },
            scene_update_modes,
            scene_renderers,
            user_assets_path: paths.user_assets_root().to_string_lossy().into_owned(),
            render_scale: candidate
                .effective_render_scale(self.quality_in_force_for_app(candidate)),
            preferred_render_scale: candidate.quality.render_scale,
            frame_rate_cap: candidate.quality.frame_rate_cap,
            battery_render_scale: candidate.quality.battery.render_scale,
            battery_target_fps: candidate.quality.battery.target_fps,
            on_battery_power: on_battery,
            quality_throttle: self.quality_throttle.iter().copied().collect(),
            effective_frame_rate_cap: self.active_target_fps_cap_for_app(candidate),
            render_scale_supported: backends.render_scale_supported,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::directory_size;
    use crate::{login::LaunchAtLoginStatus, paths::BridgePaths};

    #[test]
    fn shader_cache_size_reuses_bursts_and_refreshes_after_expiry_or_invalidation() {
        use std::{cell::Cell, time::{Duration, Instant}};
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("shader.bin");
        fs::write(&file, [1, 2, 3]).unwrap();
        let state = crate::actor::state::BridgeActorState::default();
        let reads = Cell::new(0);
        let measure = || {
            reads.set(reads.get() + 1);
            directory_size(root.path())
        };
        let now = Instant::now();
        assert_eq!(state.shader_cache_size_at(now, measure), 3);
        fs::write(&file, [1, 2, 3, 4]).unwrap();
        for _ in 0..1000 {
            assert_eq!(state.shader_cache_size_at(now + Duration::from_secs(1), measure), 3);
        }
        assert_eq!(reads.get(), 1, "a snapshot burst walks the directory only once");
        assert_eq!(state.shader_cache_size_at(now + Duration::from_secs(2), measure), 4);
        assert_eq!(reads.get(), 2);
        fs::remove_file(file).unwrap();
        state.invalidate_shader_cache_size();
        assert_eq!(state.shader_cache_size_at(now + Duration::from_secs(2), measure), 0);
        assert_eq!(reads.get(), 3);
    }

    #[test]
    fn settings_snapshot_asks_for_approval_only_when_the_login_item_awaits_it() {
        let root = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(root.path());
        let state = crate::actor::state::BridgeActorState::default();
        // (status, available, enabled, needs approval)
        for (status, expected) in [
            (LaunchAtLoginStatus::Unavailable, (false, false, false)),
            (LaunchAtLoginStatus::Available { enabled: false }, (true, false, false)),
            (LaunchAtLoginStatus::Available { enabled: true }, (true, true, false)),
            (LaunchAtLoginStatus::RequiresApproval, (true, false, true)),
        ] {
            let snapshot = state.settings(
                &[],
                status,
                &paths,
                &[],
            );
            assert_eq!(
                (
                    snapshot.launch_at_login_available,
                    snapshot.launch_at_login_enabled,
                    snapshot.launch_at_login_needs_approval,
                ),
                expected,
                "{status:?}"
            );
        }
    }


    #[test]
    fn settings_snapshot_reports_storage_status() {
        let root = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(root.path());
        fs::create_dir_all(paths.shader_cache_root()).unwrap();
        fs::write(paths.shader_cache_root().join("shader.bin"), [1, 2, 3, 4]).unwrap();

        let snapshot = crate::actor::state::BridgeActorState::default().settings(
            &[],
            LaunchAtLoginStatus::Unavailable,
            &paths,
            &[],
        );

        assert_eq!(snapshot.storage.shader_cache_size_bytes, 4);
        assert_eq!(
            snapshot.storage.logs.logs_root,
            paths.logs_root().to_string_lossy()
        );
        assert_eq!(
            snapshot.user_assets_path,
            paths.user_assets_root().to_string_lossy(),
            "the panel must show the directory the app actually imports into"
        );
        assert!(
            !snapshot
                .user_assets_path
                .starts_with(&*paths.shader_cache_root().to_string_lossy()),
            "user-imported originals must not live under a directory a cache clean wipes"
        );
        assert!(
            snapshot.scene_update_modes.is_empty() && snapshot.scene_renderers.is_empty(),
            "nothing was observed, so nothing may be reported as running"
        );
    }
}
