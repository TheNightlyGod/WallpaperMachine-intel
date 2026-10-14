use std::{
    collections::BTreeMap,
    fs,
    path::Path,
    sync::PoisonError,
    time::{Duration, Instant},
};

use wallpaper_core::{
    DisplaySnapshotEntry, SceneBackend, SceneUpdateMode, WallpaperAssignment, project::ScalingMode,
};

use crate::{
    actor::state::BridgeActorState,
    api::{
        BridgeComboOption, BridgeDirectoryMode, BridgeDisplayConfigRow, BridgeDisplayMode,
        BridgeDisplaySettingsRow, BridgeError, BridgeFileFilter, BridgeMonitorInfoRow,
        BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgePropertyDescriptor,
        BridgePropertyKind, BridgePropertyValue, BridgeScalingMode, BridgeSceneBackendReport,
        BridgeSceneUpdateModeReport, BridgeSettingsSnapshot, BridgeSliderMetadata,
        BridgeStorageStatus, BridgeVideoBackendReport, BridgeWallpaperOptionsSnapshot,
        bridge_log_status,
    },
    config::{SceneRendererModeCfg, SerializedSelector, VideoBackendModeCfg},
    engine::{ActivationInputs, RendererVideoPipelineState, SceneRuntimeReport},
    display::{DisplayLabelExt, DisplaySelectorExt, DisplaySnapshotExt},
    logging::{ApplicationLogger, LogStatus},
    login::LaunchAtLoginStatus,
    paths::BridgePaths,
    project::{Condition, DirectoryMode, FileFilter, FileMedia, PropertyMetadata, PropertyValue},
    user_assets::UserAssetManifest,
};

const MIRROR_DISPLAY_MODE: &str = "mirror";
const UNKNOWN_GIT_SHA: &str = "Unknown";
const SHADER_PIPELINE_VERSION: &str = "0.1.0";
const VIDEO_BACKEND_COMPATIBILITY: &str = "compatibility";
const VIDEO_BACKEND_NATIVE_PREFERRED: &str = "native_preferred";
const RUNNING_BACKEND_NATIVE: &str = "native";
const RUNNING_BACKEND_LEGACY: &str = "legacy";
const SCENE_RENDERER_COMPATIBILITY: &str = "compatibility";
const SCENE_RENDERER_NATIVE_METAL_PREFERRED: &str = "native_metal_preferred";
const SCENE_BACKEND_LEGACY_VULKAN: &str = "legacy_vulkan";
const SCENE_BACKEND_NATIVE_METAL: &str = "native_metal";
/// A scene that is running and whose backend the renderer could not name.
/// Distinct from both real backends on purpose.
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

fn directory_size(path: &Path) -> u64 {
    let Ok(metadata) = fs::metadata(path) else {
        return 0;
    };
    if metadata.is_file() {
        return metadata.len();
    }
    if !metadata.is_dir() {
        return 0;
    }

    fs::read_dir(path)
        .ok()
        .into_iter()
        .flat_map(|entries| entries.filter_map(Result::ok))
        .map(|entry| directory_size(&entry.path()))
        .sum()
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
        let properties = self
            .project_models
            .get(&wallpaper_id)
            .map(|model| {
                // A label that is exactly one of the project's own tokens becomes
                // its text in the app's language; anything else is left as written.
                let localized = |raw: &str| {
                    model
                        .localization
                        .resolve(raw, &self.label_locales)
                        .map_or_else(|| raw.to_owned(), str::to_owned)
                };
                let overrides = model.override_values(&config.property_overrides);
                let lookup = |id: &str| {
                    overrides.get(id).cloned().or_else(|| {
                        model
                            .properties
                            .iter()
                            .find(|property| property.id == id)
                            .map(crate::project::ProjectProperty::default_value)
                    })
                };
                model
                    .properties
                    .iter()
                    .map(|property| {
                        // A rule that hides a property keeps its row, not enabled: the
                        // host still sees what the project defines and what its hidden
                        // overrides hold, and decides what to list. A rule that cannot be
                        // read leaves the property enabled.
                        let enabled = property
                            .condition
                            .as_deref()
                            .and_then(|condition| Condition::parse(condition).ok())
                            .is_none_or(|condition| condition.eval(&lookup));
                        let value = property.effective_value(&overrides);
                        let default_value = property.default_value();
                        let dirty = !property.value_is_default(&value);
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
                            PropertyMetadata::File { filter } => {
                                (bridge_file_filter(filter), None)
                            }
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

                        BridgePropertyDescriptor {
                            id: property.id.clone(),
                            kind: BridgePropertyKind::from(&property.kind),
                            label_html: localized(&property.label_html),
                            value: BridgePropertyValue::from(value),
                            default_value: BridgePropertyValue::from(default_value),
                            slider,
                            combo_options,
                            file_filter,
                            directory_mode,
                            dirty,
                            can_restore_defaults: dirty,
                            enabled,
                            asset_managed: asset.managed,
                            asset_missing: asset.missing,
                            asset_source_path,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        let app_config = self.app_config.normalized(displays);
        let active_enabled_displays = self.enabled_selectors(&wallpaper_id);
        let display_configurations = app_config
            .monitor_rows(displays)
            .into_iter()
            .filter(|row| {
                row.connected && row.config.enabled && row.config.mode != MIRROR_DISPLAY_MODE
            })
            .filter_map(|row| {
                let display = row.display_index.and_then(|index| displays.get(index))?;
                let selector = &row.selector;
                let primary = *selector == SerializedSelector::Primary;
                let render = config
                    .monitors
                    .iter()
                    .find(|render| render.selector == *selector);
                let default_render = crate::config::MonitorRender {
                    selector: selector.clone(),
                    ..crate::config::MonitorRender::default()
                };
                let render = render.unwrap_or(&default_render);
                let max_fps = display.desc.refresh_rate_hz.max(1);
                let render_dirty = config
                    .monitors
                    .iter()
                    .find(|candidate| candidate.selector == *selector)
                    .is_some_and(|candidate| candidate != &default_render);

                Some(BridgeDisplayConfigRow {
                    display_id: selector.id(),
                    title: display.title_with_role(primary),
                    enabled: draft.effective_display_enabled(selector, &active_enabled_displays),
                    scaling_mode: match render.parse_scaling_mode() {
                        ScalingMode::None => BridgeScalingMode::None,
                        ScalingMode::Stretch => BridgeScalingMode::Stretch,
                        ScalingMode::Fit => BridgeScalingMode::Match,
                        ScalingMode::Fill => BridgeScalingMode::Fill,
                    },
                    scaling_factor: render.scaling_factor,
                    framing: render.framing.into(),
                    target_fps: render.fps_on(max_fps),
                    max_fps,
                    muted: config.audio.muted,
                    volume: config.audio.volume,
                    dirty: render_dirty || draft.display_dirty(selector, &active_enabled_displays),
                    can_restore_defaults: render != &default_render
                        || draft.display_dirty(selector, &active_enabled_displays),
                })
            })
            .collect();

        Ok(BridgeWallpaperOptionsSnapshot {
            wallpaper_id: entry.id.clone(),
            title: entry.title.clone(),
            kind: entry.kind,
            supported: entry.supported,
            dirty: draft.is_dirty(&active_enabled_displays),
            properties,
            display_configurations,
            audio_response_enabled: config.audio.response_enabled,
            media_integration_enabled: config.media_integration_enabled,
            muted: config.audio.muted,
            volume: config.audio.volume,
        })
    }

    pub fn monitor_info(
        &self,
        displays: &[DisplaySnapshotEntry],
    ) -> BridgeMonitorInformationSnapshot {
        let app_config = self.app_config.normalized(displays);
        let rows = app_config
            .monitor_rows(displays)
            .into_iter()
            .filter(|row| {
                row.connected
                    && row.config.enabled
                    && (row.config.wallpaper.is_some()
                        || row.config.mode == MIRROR_DISPLAY_MODE
                            && row.config.mirror_target.is_some())
            })
            .filter_map(|row| {
                let display = row.display_index.and_then(|index| displays.get(index))?;
                let mirror_target = if row.config.mode == MIRROR_DISPLAY_MODE {
                    row.config.mirror_target.as_ref()
                } else {
                    None
                };
                let target_display = mirror_target
                    .and_then(|selector| selector.to_selector().resolve_display(displays));
                let target_config_selector =
                    target_display.map(|display| display.config_selector(displays));
                let target_row = target_config_selector.as_ref().and_then(|selector| {
                    app_config
                        .monitor_rows(displays)
                        .into_iter()
                        .find(|candidate| candidate.selector == *selector)
                });
                let wallpaper_id = if mirror_target.is_some() {
                    target_row
                        .as_ref()
                        .and_then(|target| target.config.wallpaper.as_ref())
                } else {
                    row.config.wallpaper.as_ref()
                }?;
                let wallpaper_title = self
                    .library
                    .iter()
                    .find(|entry| entry.id == *wallpaper_id)
                    .map_or_else(|| wallpaper_id.clone(), |entry| entry.title.clone());
                let render_selector = target_config_selector.as_ref().unwrap_or(&row.selector);
                let render = self.wallpaper_configs.get(wallpaper_id).and_then(|config| {
                    config
                        .monitors
                        .iter()
                        .find(|render| render.selector == *render_selector)
                });
                let default_render = crate::config::MonitorRender {
                    selector: render_selector.clone(),
                    ..crate::config::MonitorRender::default()
                };
                let render = render.unwrap_or(&default_render);
                let primary = row.selector == SerializedSelector::Primary;
                let role = if primary { "Primary" } else { "Secondary" };
                let suffix = format!("({} - {role} - {wallpaper_id})", display.desc.display_id);
                let title = display.title_with_suffix(&suffix);
                let scaling_mode = match render.parse_scaling_mode() {
                    ScalingMode::None => "None",
                    ScalingMode::Stretch => "Stretch",
                    ScalingMode::Fit => "Match",
                    ScalingMode::Fill => "Fill",
                };

                Some(BridgeMonitorInfoRow {
                    display_id: row.selector.id(),
                    title,
                    wallpaper_id: wallpaper_id.clone(),
                    wallpaper_title,
                    mirror_target_display_id: target_config_selector
                        .as_ref()
                        .map(SerializedSelector::id),
                    mirror_target_title: target_display.map(|display| {
                        let primary =
                            target_config_selector.as_ref() == Some(&SerializedSelector::Primary);
                        display.title_with_role(primary)
                    }),
                    scaling_mode: scaling_mode.to_string(),
                    target_fps: render
                        .fps_on(display.desc.refresh_rate_hz)
                        .to_string(),
                    audio_response: self.wallpaper_configs.get(wallpaper_id).map_or_else(
                        || crate::config::AudioCfg::default().response_enabled,
                        |config| config.audio.response_enabled,
                    ),
                })
            })
            .collect();

        BridgeMonitorInformationSnapshot { rows }
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
        app_config: &crate::config::AppConfig,
        scene_reports: &[SceneRuntimeReport],
    ) -> BTreeMap<u32, SceneReportLabels> {
        let primary = displays.first().map(|first| first.desc.display_id);
        let rows = app_config.monitor_rows(displays);
        let monitor_info = self.monitor_info(displays);
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

    #[allow(clippy::too_many_lines)]
    pub fn settings(
        &self,
        displays: &[DisplaySnapshotEntry],
        launch_at_login: LaunchAtLoginStatus,
        paths: &BridgePaths,
        renderer: RendererVideoPipelineState,
        scene_reports: &[SceneRuntimeReport],
    ) -> BridgeSettingsSnapshot {
        let app_config = self.app_config.normalized(displays);
        let rows = if displays.is_empty() {
            self.display_settings.values().cloned().collect()
        } else {
            let rows = app_config.monitor_rows(displays);
            rows.iter()
                .filter_map(|row| {
                    let entry = row.display_index.and_then(|index| displays.get(index))?;
                    let configured = app_config
                        .monitors
                        .iter()
                        .any(|monitor| monitor.selector == row.selector);
                    let primary = row.selector == SerializedSelector::Primary;
                    let mode = if primary || !row.config.mode.eq_ignore_ascii_case("mirror") {
                        BridgeDisplayMode::Standalone
                    } else {
                        BridgeDisplayMode::Mirror
                    };
                    let mode = if configured {
                        mode
                    } else {
                        match entry.assignment.as_ref() {
                            Some(WallpaperAssignment::Mirror(_)) => BridgeDisplayMode::Mirror,
                            _ => BridgeDisplayMode::Standalone,
                        }
                    };
                    let selected_mirror_target = if mode == BridgeDisplayMode::Mirror && configured
                    {
                        row.config
                            .mirror_target
                            .as_ref()
                            .and_then(|selector| selector.mirror_target_id(entry, displays))
                    } else if mode == BridgeDisplayMode::Mirror {
                        match entry.assignment.as_ref()? {
                            WallpaperAssignment::Mirror(selector) => {
                                SerializedSelector::from_selector(selector)
                                    .mirror_target_id(entry, displays)
                            }
                            WallpaperAssignment::Direct(_) => None,
                        }
                    } else {
                        None
                    };
                    let settings = app_config
                        .monitor_settings
                        .iter()
                        .find(|settings| settings.selector == row.selector)
                        .cloned()
                        .unwrap_or_else(|| crate::config::MonitorSettingsCfg {
                            selector: row.selector.clone(),
                            ..crate::config::MonitorSettingsCfg::default()
                        });
                    let scaling_mode = BridgeScalingMode::from(settings.parse_scaling_mode());
                    let max_fps = entry.desc.refresh_rate_hz.max(1);

                    Some(BridgeDisplaySettingsRow {
                        display_id: row.selector.id(),
                        title: entry.title_with_role(primary),
                        enabled: primary || row.config.enabled,
                        mode,
                        mirror_targets: rows
                            .iter()
                            .filter(|candidate| {
                                candidate.connected
                                    && candidate.config.enabled
                                    && candidate.config.mode != MIRROR_DISPLAY_MODE
                                    && candidate.selector != row.selector
                            })
                            .filter_map(|candidate| {
                                candidate
                                    .display_index
                                    .and_then(|index| displays.get(index))
                            })
                            .map(|display| display.config_selector(displays).id())
                            .collect(),
                        selected_mirror_target,
                        scaling_mode,
                        scaling_factor: settings.scaling_factor,
                        target_fps: settings.fps_on(max_fps),
                        max_fps,
                        muted: settings.muted,
                        volume: settings.volume,
                    })
                })
                .collect()
        };
        let on_battery = self.power_source == crate::power::PowerSource::Battery;
        let backends = ActivationInputs {
            app_config: &self.app_config,
            wallpapers: &self.wallpaper_configs,
            library: self.scanned_library(),
            displays,
            paused: self.playback_state == BridgePlaybackState::Paused,
            suspended_displays: &self.suspended_displays,
            paths,
            force_shader_refresh: false,
            project_models: &self.project_models,
            native_video_enabled: self.app_config.video_backend
                == VideoBackendModeCfg::NativePreferred,
            native_video_rejected: &self.native_video_rejected,
            frame_rate_cap: self.active_target_fps_cap(),
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
                backend: if routed.native {
                    RUNNING_BACKEND_NATIVE.to_string()
                } else {
                    RUNNING_BACKEND_LEGACY.to_string()
                },
                fallback_reason: routed.fallback_reason,
            })
            .collect();
        let scene_labels = self.scene_report_labels(displays, &app_config, scene_reports);
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
                    // A backend the renderer could not name is reported as
                    // unknown rather than as the preference, which would make
                    // the preference look like evidence of what ran.
                    backend: match report.backend {
                        Some(SceneBackend::LegacyVulkan) => SCENE_BACKEND_LEGACY_VULKAN,
                        Some(SceneBackend::NativeMetal) => SCENE_BACKEND_NATIVE_METAL,
                        None => SCENE_BACKEND_UNKNOWN,
                    }
                    .to_string(),
                    fallback_reason: report.fallback_reason.clone(),
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
            battery_mode: self.app_config.power.on_battery.into(),
            verbose_logging: self.app_config.diagnostics.verbose_logging,
            git_sha: match option_env!("GIT_SHORT_COMMIT").unwrap_or(crate::build::SHORT_COMMIT) {
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
            video_backend: match self.app_config.video_backend {
                VideoBackendModeCfg::Compatibility => VIDEO_BACKEND_COMPATIBILITY.to_string(),
                VideoBackendModeCfg::NativePreferred => {
                    VIDEO_BACKEND_NATIVE_PREFERRED.to_string()
                }
            },
            video_backends,
            content_pacing_enabled: renderer.content_pacing_enabled,
            shared_video_decode_enabled: renderer.shared_video_decode_enabled,
            shared_video_decode_sessions: renderer.shared_video_decode_sessions,
            shared_video_decode_consumers: renderer.shared_video_decode_consumers,
            scene_optimization_enabled: self.app_config.quality.scene_optimization_enabled,
            scene_on_demand_enabled: self.app_config.quality.scene_on_demand_enabled,
            scene_video_plane_sampling_enabled: self
                .app_config
                .experimental
                .scene_video_plane_sampling,
            scene_renderer: match self.app_config.scene_renderer {
                SceneRendererModeCfg::Compatibility => SCENE_RENDERER_COMPATIBILITY.to_string(),
                SceneRendererModeCfg::NativeMetalPreferred => {
                    SCENE_RENDERER_NATIVE_METAL_PREFERRED.to_string()
                }
            },
            scene_update_modes,
            scene_renderers,
            user_assets_path: paths.user_assets_root().to_string_lossy().into_owned(),
            render_scale: self
                .app_config
                .effective_render_scale(self.quality_in_force()),
            preferred_render_scale: self.app_config.quality.render_scale,
            frame_rate_cap: self.app_config.quality.frame_rate_cap,
            battery_render_scale: self.app_config.quality.battery.render_scale,
            battery_target_fps: self.app_config.quality.battery.target_fps,
            on_battery_power: on_battery,
            quality_throttle: self.quality_throttle.iter().copied().collect(),
            effective_frame_rate_cap: self.active_target_fps_cap(),
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
                crate::engine::RendererVideoPipelineState::default(),
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
    fn directory_size_sums_nested_files() {
        let root = tempfile::tempdir().unwrap();
        let nested = root.path().join("nested");
        fs::create_dir_all(&nested).unwrap();
        fs::write(root.path().join("a.bin"), [1, 2, 3]).unwrap();
        fs::write(nested.join("b.bin"), [4, 5]).unwrap();

        assert_eq!(directory_size(root.path()), 5);
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
            crate::engine::RendererVideoPipelineState::default(),
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
