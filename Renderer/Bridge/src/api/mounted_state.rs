//! Independently authored, source-only tests. Mount only as `crate::api::mounted_state`.
//! All actor observations ask the canonical read-only production-actor message.
use super::{BridgeBuilder, WallpaperBridge};
use crate::actor::lifecycle_test_support::{
    MountedStateObservation, active_target_fps_cap, quality_in_force,
};
use crate::actor::messages::*;
use crate::actor::state::BridgeActorState;
use crate::api::lifecycle_test_support::{actor, inert_login_controller};
use crate::api::mounted_lifecycle::{ControlledEngine, EngineObservation, OperationPhase};
use crate::api::*;
use crate::config::{
    AppConfig, BatteryModeCfg, ConfigStore, MonitorCfg, MonitorRender, MonitorSettingsCfg,
    QualityInForce, SerializedSelector, WallpaperConfig,
};
use crate::login::LaunchAtLoginStatus;
use crate::paths::BridgePaths;
use crate::power::PowerSource;
use crate::project::{ProjectModel, PropertyValue};
use crate::state::drafts::WallpaperOptionsDraft;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use wallpaper_core::project::{SceneDesc, SceneHandle, SceneResult, SceneTemplate};
use wallpaper_core::{DisplayDesc, DisplaySnapshotEntry, EngineError, WallpaperAssignment};

const A: &str = "687241503";
const B: &str = "687241509";
const WEB: &str = "687241521";
const WEB_DISABLED: &str = "687241563";
const WEB_MIRROR: &str = "687241571";
const SLIDER: &str = "aurora_drift";
const PENDING: f64 = 0.68;
const LIMIT: Duration = Duration::from_secs(15);
static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

macro_rules! ask {
    ($bridge:expr, $message:expr, $reply:ty) => {{
        let answer: Result<$reply, BridgeError> =
            tokio::time::timeout(LIMIT, actor($bridge).ask($message))
                .await
                .expect("real actor reply exceeded finite guard");
        answer
    }};
}

struct OwnedRoot(PathBuf);
impl OwnedRoot {
    fn new() -> Self {
        loop {
            let path = std::env::temp_dir().join(format!(
                "wallpaper-mounted-state-{}-{}",
                std::process::id(),
                NEXT_ROOT.fetch_add(1, Ordering::Relaxed),
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Self(fs::canonicalize(path).unwrap()),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("cannot allocate owned temporary root: {error}"),
            }
        }
    }
    fn store(&self) -> ConfigStore {
        ConfigStore::open(self.0.join("explicit-store"))
    }
    fn paths(&self) -> BridgePaths {
        let paths = BridgePaths::for_home(self.0.clone());
        for path in [
            paths.app_support_root(),
            paths.steam_workshop_root(),
            paths.assets_root(),
            paths.user_assets_root(),
            paths.shader_cache_root(),
        ] {
            assert!(
                path.starts_with(&self.0),
                "runner isolation prerequisite violated: {} is outside {}",
                path.display(),
                self.0.display()
            );
        }
        paths
    }
}
impl Drop for OwnedRoot {
    fn drop(&mut self) {
        // Keep failure artifacts while asynchronous actor work may still reference them.
        // Successful mounted cases acknowledge the consuming drain before this destructor.
        if std::thread::panicking() {
            return;
        }
        fs::remove_dir_all(&self.0).expect("test-owned tree cleanup failed");
    }
}

fn selector(display_id: u32) -> SerializedSelector {
    SerializedSelector::LiveDisplayId { display_id }
}
fn monitor(display_id: u32, id: &str, enabled: bool, mode: &str) -> MonitorCfg {
    let mut row = MonitorCfg::default();
    row.selector = selector(display_id);
    row.wallpaper = Some(id.into());
    row.enabled = enabled;
    row.mode = mode.into();
    row
}
fn entry(id: &str, kind: BridgeWallpaperKind) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry {
        id: id.into(),
        title: format!("Indigo {id}"),
        kind,
        supported: true,
        active: false,
        selected: false,
        preview_path: None,
    }
}
fn model(id: &str, kind: &str) -> ProjectModel {
    let value = serde_json::json!({"type":kind,"title":format!("Indigo {id}"),
    "file":if kind == "web" { "panel.html" } else { "backdrop.scene" },
    "general":{"properties":{
        "aurora_drift":{"type":"slider","value":0.24,"min":0.0,"max":1.0},
        "night_switch":{"type":"bool","value":false},
        "atlas_file":{"type":"file","value":"authored/atlas.png"},
        "orbit_directory":{"type":"directory","value":"authored/orbits","mode":" FetchAll "},
        "veil_texture":{"type":"texture","value":"authored/veil.png"},
        "hidden_file":{"type":"file","value":"authored/hidden","condition":"false"},
        "remote_next":{"type":"usershortcut","value":""}
    }}});
    ProjectModel::parse(id, &value.to_string()).unwrap()
}
fn wallpaper(id: &str, kind: &str) -> WallpaperConfig {
    let mut cfg = WallpaperConfig::new_for(id, kind);
    cfg.audio.volume = 0.73;
    cfg.property_overrides
        .insert(SLIDER.into(), serde_json::json!(0.35));
    cfg
}
fn seeded_state() -> BridgeActorState {
    let mut state = BridgeActorState::default();
    state.app_config.monitors = vec![
        monitor(41, A, true, "independent"),
        monitor(42, B, true, "independent"),
        monitor(43, WEB, true, "independent"),
        monitor(46, WEB_DISABLED, false, "independent"),
        monitor(47, WEB_MIRROR, true, "mirror"),
    ];
    state.app_config.ui.filter.video = false;
    state.app_config.diagnostics.verbose_logging = true;
    state.library = vec![
        entry(A, BridgeWallpaperKind::ProjectScene),
        entry(B, BridgeWallpaperKind::ProjectScene),
        entry(WEB, BridgeWallpaperKind::Webpage),
        entry(WEB_DISABLED, BridgeWallpaperKind::ProjectScene),
        entry(WEB_MIRROR, BridgeWallpaperKind::Unknown),
    ];
    for (id, kind) in [
        (A, "scene"),
        (B, "scene"),
        (WEB, "web"),
        (WEB_DISABLED, "web"),
        (WEB_MIRROR, "web"),
    ] {
        state.project_models.insert(id.into(), model(id, kind));
        state
            .wallpaper_configs
            .insert(id.into(), wallpaper(id, kind));
    }
    let mut other = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        state.wallpaper_configs[B].clone(),
        vec![selector(42)],
    );
    other.set_muted(true);
    other.edit_property(
        &state.project_models[B],
        "night_switch",
        PropertyValue::Bool(true),
    );
    state.wallpaper_drafts.insert(B.into(), other);
    state.selected_wallpaper_id = Some(B.into());
    state.app_config.general.last_selected_wallpaper = Some(B.into());
    state.active_wallpaper_ids = vec!["live-before-apply".into()];
    state.errors = vec!["independent retained diagnostic".into()];
    state.label_locales = vec!["is-IS".into(), "en-GB".into()];
    state.suspended_displays.insert(97);
    state
}
fn install_target_draft(state: &mut BridgeActorState, reconcile: bool) {
    let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        state.wallpaper_configs[A].clone(),
        vec![selector(41)],
    );
    if reconcile {
        draft.edit_property(
            &state.project_models[A],
            SLIDER,
            PropertyValue::Number(PENDING),
        );
        draft.set_display_enabled(selector(42), true, &[selector(41)]);
    } else {
        draft.set_volume(0.46).unwrap();
        draft.set_muted(true);
    }
    assert_eq!(
        draft.requires_reconcile(&state.enabled_selectors(A)),
        reconcile
    );
    state.wallpaper_drafts.insert(A.into(), draft);
}
fn json_document(text: &str) -> serde_json::Value {
    serde_json::from_str(text).unwrap()
}
fn scene(path: &str, display: u32) -> SceneDesc {
    SceneDesc::new(
        DisplayDesc::new(display, 0, 0, 1280, 800, 1.0),
        path,
        "isolated-assets",
        47,
        false,
    )
}
fn display_row(
    paths: &BridgePaths,
    display: u32,
    id: Option<&str>,
    handle: Option<u64>,
) -> DisplaySnapshotEntry {
    let desc = DisplayDesc::new(display, 0, 0, 1280, 800, 1.0);
    let assignment = id.map(|id| {
        let source = SceneDesc::new(
            desc.clone(),
            paths
                .project_json(id)
                .parent()
                .unwrap()
                .join("backdrop.scene")
                .to_string_lossy()
                .into_owned(),
            paths.assets_root().to_string_lossy().into_owned(),
            47,
            false,
        );
        WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&source))
    });
    DisplaySnapshotEntry {
        identity: desc.identity.clone(),
        desc,
        handle: handle.map(SceneHandle::new),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment,
    }
}
fn rows(paths: &BridgePaths) -> Vec<DisplaySnapshotEntry> {
    vec![
        display_row(paths, 41, Some(A), Some(4101)),
        display_row(paths, 42, Some(B), Some(4201)),
        display_row(paths, 43, None, None),
    ]
}
fn write_projects(paths: &BridgePaths) {
    fs::create_dir_all(paths.steam_workshop_root()).unwrap();
    for (id, kind) in [(A, "scene"), (B, "scene"), (WEB, "web")] {
        let project = paths.project_json(id);
        fs::create_dir_all(project.parent().unwrap()).unwrap();
        fs::write(&project,serde_json::json!({"type":kind,"title":format!("Indigo {id}"),
            "file":if kind=="web" {"panel.html"} else {"backdrop.scene"},
            "general":{"properties":{"aurora_drift":{"type":"slider","value":0.24,"min":0.0,"max":1.0}}}}).to_string()).unwrap();
        fs::write(project.parent().unwrap().join("backdrop.scene"), "{}").unwrap();
        fs::write(
            project.parent().unwrap().join("panel.html"),
            "<!doctype html><title>Indigo</title>",
        )
        .unwrap();
    }
}
macro_rules! builder {
    ($engine:expr,$store:expr,$paths:expr) => {
        BridgeBuilder::new($engine)
            .with_config_store($store)
            .with_paths($paths)
            .with_mouse_polling_enabled(false)
            .with_power_watching_enabled(false)
            .with_launch_at_login(inert_login_controller(LaunchAtLoginStatus::Unavailable))
    };
}
async fn observe(bridge: &WallpaperBridge) -> BridgeActorState {
    ask!(bridge, MountedStateObservation, BridgeActorState).unwrap()
}

#[test]
fn m01_initialization_preserves_complete_config_and_unscanned_selection() {
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some("not-yet-scanned-687241533".into());
    app.ui.filter.scene = false;
    app.ui.filter.video = true;
    app.ui.filter.web = false;
    app.ui.filter.unknown = true;
    app.ui.selector_window.x = -217;
    app.ui.selector_window.y = 93;
    app.ui.settings_window.width = 913;
    app.ui.settings_window.height = 707;
    app.power.on_battery = BatteryModeCfg::ReducedQuality;
    app.quality.render_scale = 0.82;
    app.quality.frame_rate_cap = Some(53);
    app.quality.battery.render_scale = 0.41;
    app.quality.battery.target_fps = 23;
    app.experimental.scene_video_plane_sampling = true;
    app.diagnostics.verbose_logging = true;
    let mut settings = MonitorSettingsCfg::default();
    settings.selector = selector(51);
    settings.volume = 0.39;
    settings.frame_rate = Some(37);
    app.monitor_settings.push(settings);
    app.monitors = vec![
        monitor(51, B, true, "independent"),
        monitor(52, A, true, "peculiar-mode"),
        monitor(53, B, true, "independent"),
        monitor(54, "disabled", false, "independent"),
        monitor(55, "excluded", true, "mirror"),
        monitor(56, "case-sensitive", true, "Mirror"),
    ];
    let state = BridgeActorState::from_app_config(app.clone());
    assert_eq!(state.app_config, app);
    for (kind, want) in [
        (BridgeWallpaperKind::ProjectScene, false),
        (BridgeWallpaperKind::Video, true),
        (BridgeWallpaperKind::Webpage, false),
        (BridgeWallpaperKind::Unknown, true),
    ] {
        assert_eq!(state.filter_enabled(kind), want);
    }
    assert_eq!(
        state.selected_wallpaper_id,
        app.general.last_selected_wallpaper
    );
    assert_eq!(state.active_wallpaper_ids, vec![A, B, "case-sensitive"]);
    assert_eq!(state.enabled_selectors(B), vec![selector(51), selector(53)]);
    assert!(state.library.is_empty());
    assert!(state.scanned_library().is_none());
    let defaults = BridgeActorState::default();
    assert_eq!(state.playback_state, defaults.playback_state);
    assert_eq!(state.power_source, defaults.power_source);
    assert_eq!(state.presentation_unloaded, defaults.presentation_unloaded);
    assert_eq!(
        state.startup_power_sample_received,
        defaults.startup_power_sample_received
    );
    assert_eq!(state.initial_frame_ready, defaults.initial_frame_ready);
    assert_eq!(
        state.pending_battery_pause_after_initial_frame,
        defaults.pending_battery_pause_after_initial_frame
    );
    assert_eq!(
        state.auto_paused_for_battery,
        defaults.auto_paused_for_battery
    );
    assert_eq!(
        state.battery_pause_suppressed,
        defaults.battery_pause_suppressed
    );
    assert!(state.held_wallpapers.is_empty());
    assert!(state.wallpaper_drafts.is_empty());
    assert!(state.wallpaper_configs.is_empty());
    assert!(state.project_models.is_empty());
}

#[test]
fn m02_startup_adapter_assigns_pending_for_every_source_mode_frame_and_prior_flag() {
    for source in [
        PowerSource::Battery,
        PowerSource::External,
        PowerSource::Unknown,
    ] {
        for mode in [
            BatteryModeCfg::Pause,
            BatteryModeCfg::KeepRunning,
            BatteryModeCfg::ReducedQuality,
        ] {
            for ready in [false, true] {
                for pending in [false, true] {
                    let mut state = seeded_state();
                    install_target_draft(&mut state, true);
                    state.app_config.power.on_battery = mode;
                    state.initial_frame_ready = ready;
                    state.pending_battery_pause_after_initial_frame = pending;
                    state.playback_state = BridgePlaybackState::Paused;
                    state.auto_paused_for_battery = true;
                    state.battery_pause_suppressed = true;
                    let before = state.clone();
                    state.apply_startup_power_source(source);
                    assert_eq!(state.power_source, source);
                    assert!(state.startup_power_sample_received);
                    assert_eq!(
                        state.pending_battery_pause_after_initial_frame,
                        source == PowerSource::Battery && mode == BatteryModeCfg::Pause && !ready
                    );
                    assert_eq!(state.playback_state, before.playback_state);
                    assert_eq!(
                        state.auto_paused_for_battery,
                        before.auto_paused_for_battery
                    );
                    assert_eq!(
                        state.battery_pause_suppressed,
                        before.battery_pause_suppressed
                    );
                    assert_eq!(state.app_config, before.app_config);
                    assert_eq!(state.wallpaper_configs, before.wallpaper_configs);
                    assert_eq!(
                        state.wallpaper_drafts[A].current(),
                        before.wallpaper_drafts[A].current()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[A].committed(),
                        before.wallpaper_drafts[A].committed()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[A].enabled_displays(),
                        before.wallpaper_drafts[A].enabled_displays()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[A]
                            .effective_enabled_displays(&state.enabled_selectors(A)),
                        before.wallpaper_drafts[A]
                            .effective_enabled_displays(&before.enabled_selectors(A))
                    );
                    assert_eq!(
                        state.wallpaper_drafts[A].is_dirty(&state.enabled_selectors(A)),
                        before.wallpaper_drafts[A].is_dirty(&before.enabled_selectors(A))
                    );
                }
            }
        }
    }
    let mut state = BridgeActorState::default();
    state.app_config.power.on_battery = BatteryModeCfg::Pause;
    for (source, want) in [
        (PowerSource::Battery, true),
        (PowerSource::External, false),
        (PowerSource::Battery, true),
        (PowerSource::Unknown, false),
    ] {
        state.apply_startup_power_source(source);
        assert_eq!(state.pending_battery_pause_after_initial_frame, want);
    }
    state.initial_frame_ready = true;
    state.apply_startup_power_source(PowerSource::Battery);
    assert!(!state.pending_battery_pause_after_initial_frame);
}

#[test]
fn m10_publication_owns_baseline_but_refresh_owns_live_ids_and_membership_is_rechecked() {
    let mut original = seeded_state();
    install_target_draft(&mut original, true);
    original.held_wallpapers.insert(B.into());
    original.library_scanned = true;
    let captured =
        original.wallpaper_drafts[A].effective_enabled_displays(&original.enabled_selectors(A));
    for active_from_config in [false, true] {
        let mut state = original.clone();
        let prepared = state.prepare_apply(A, None).unwrap();
        let app = prepared.app_config().clone();
        let map = prepared.wallpaper_configs().clone();
        state
            .publish_apply(A.into(), prepared, active_from_config)
            .unwrap();
        assert_eq!(state.app_config, app);
        assert_eq!(state.wallpaper_configs, map);
        assert_eq!(state.wallpaper_drafts[A].current(), &map[A]);
        assert_eq!(state.wallpaper_drafts[A].committed(), &map[A]);
        assert_eq!(state.wallpaper_drafts[A].enabled_displays(), captured);
        assert!(!state.wallpaper_drafts[A].is_dirty(&state.enabled_selectors(A)));
        if active_from_config {
            assert_eq!(state.active_wallpaper_ids, state.configured_ids());
        } else {
            assert_eq!(state.active_wallpaper_ids, original.active_wallpaper_ids);
        }
        assert_eq!(state.selected_wallpaper_id, original.selected_wallpaper_id);
        assert_eq!(state.library, original.library);
        assert_eq!(state.project_models, original.project_models);
        assert_eq!(state.held_wallpapers, original.held_wallpapers);
        assert_eq!(state.errors, original.errors);
        assert_eq!(state.label_locales, original.label_locales);
        assert_eq!(state.suspended_displays, original.suspended_displays);
        assert_eq!(state.filter_video, original.filter_video);
        assert_eq!(state.library_scanned, original.library_scanned);
        assert_eq!(
            state.wallpaper_drafts[B].current(),
            original.wallpaper_drafts[B].current()
        );
        assert_eq!(
            state.wallpaper_drafts[B].committed(),
            original.wallpaper_drafts[B].committed()
        );
        assert_eq!(
            state.wallpaper_drafts[B].enabled_displays(),
            original.wallpaper_drafts[B].enabled_displays()
        );
        state.presentation_unloaded = true;
        state.active_wallpaper_ids = vec!["unloaded-live".into()];
        state.refresh_active_ids();
        assert_eq!(state.active_wallpaper_ids, state.configured_ids());
    }
    let mut removed = original.clone();
    let prepared = removed.prepare_apply(A, None).unwrap();
    removed.replace_library(vec![entry(B, BridgeWallpaperKind::ProjectScene)]);
    let before = removed.clone();
    assert_eq!(
        removed
            .publish_apply(A.into(), prepared, true)
            .unwrap_err()
            .kind(),
        BridgeErrorKind::InvalidInput
    );
    assert_eq!(removed.app_config, before.app_config);
    assert_eq!(removed.wallpaper_configs, before.wallpaper_configs);
    assert_eq!(removed.active_wallpaper_ids, before.active_wallpaper_ids);
    assert_eq!(
        removed.wallpaper_drafts[A].current(),
        before.wallpaper_drafts[A].current()
    );
    assert_eq!(
        removed.wallpaper_drafts[A].committed(),
        before.wallpaper_drafts[A].committed()
    );
}

#[test]
fn m11_scene_parent_ids_loaded_web_classification_and_broader_model_routing() {
    let mut state = BridgeActorState::default();
    let enabled = "web-enabled";
    let disabled = "web-disabled";
    let mirrored = "web-mirror";
    let odd = "web-odd-mode";
    let unassigned = "web-unassigned";
    let masquerade = "scene-labelled-web";
    for id in [enabled, disabled, mirrored, odd, unassigned] {
        state.project_models.insert(id.into(), model(id, "web"));
    }
    state
        .project_models
        .insert(masquerade.into(), model(masquerade, "scene"));
    state.library = vec![
        entry(enabled, BridgeWallpaperKind::ProjectScene),
        entry(masquerade, BridgeWallpaperKind::Webpage),
    ];
    state.app_config.monitors = vec![
        monitor(1, enabled, true, "independent"),
        monitor(2, disabled, false, "independent"),
        monitor(3, mirrored, true, "mirror"),
        monitor(4, odd, true, "novel"),
        monitor(5, masquerade, true, "independent"),
        monitor(6, "missing-model", true, "independent"),
        monitor(7, enabled, true, "independent"),
    ];
    assert!(state.is_web_wallpaper(enabled));
    assert!(!state.is_web_wallpaper(masquerade));
    assert!(!state.is_web_wallpaper("missing-model"));
    let scenes = vec![
        scene("/owned/alpha-aurora/main.scene", 1),
        scene("/else/alpha-aurora/second.scene", 2),
        scene("/owned/nested/inner-id/main.scene", 3),
        scene("/owned/北極光/main.scene", 4),
        scene("bare.scene", 5),
        scene("/", 6),
    ];
    let expected = vec!["alpha-aurora", "inner-id", enabled, odd, "北極光"];
    state.set_active_ids_from_scenes(&scenes);
    assert_eq!(state.active_wallpaper_ids, expected);
    state.presentation_unloaded = true;
    state.active_wallpaper_ids = vec!["z-live".into(), "a-live".into(), "z-live".into()];
    state.set_active_ids_from_scenes(&[]);
    assert_eq!(
        state.active_wallpaper_ids,
        vec!["z-live", "a-live", "z-live"]
    );
    state.set_active_ids_from_scenes(&scenes);
    assert_eq!(state.active_wallpaper_ids, expected);
    state.presentation_unloaded = false;
    state.set_active_ids_from_scenes(&[]);
    assert_eq!(state.active_wallpaper_ids, vec![enabled, odd]);
    state.presentation_unloaded = true;
    state.refresh_active_ids();
    assert_eq!(state.active_wallpaper_ids, state.configured_ids());
    let mut different = AppConfig::default();
    different.monitors = vec![
        monitor(81, disabled, false, "independent"),
        monitor(82, mirrored, true, "mirror"),
        monitor(83, disabled, true, "mirror"),
        monitor(84, "missing-model", false, "mirror"),
    ];
    let actual = state.configured_project_models(&different);
    let expected_models = BTreeMap::from([
        (disabled.to_string(), state.project_models[disabled].clone()),
        (mirrored.to_string(), state.project_models[mirrored].clone()),
    ]);
    assert_eq!(actual, expected_models);
}

#[test]
fn m12_replacement_preserves_noninventory_state_and_has_precise_selection_rules() {
    for scanned in [false, true] {
        for choice in [0, 1, 2] {
            for empty in [false, true] {
                let mut state = seeded_state();
                install_target_draft(&mut state, true);
                state.library_scanned = scanned;
                state.held_wallpapers.insert(A.into());
                state.selected_wallpaper_id = match choice {
                    0 => Some(B.into()),
                    1 => Some(A.into()),
                    _ => None,
                };
                state.app_config.general.last_selected_wallpaper =
                    Some("different-persisted-selection".into());
                let before = state.clone();
                let mut first = entry(B, BridgeWallpaperKind::Video);
                first.active = true;
                first.selected = true;
                let replacement = if empty {
                    vec![]
                } else {
                    vec![first, entry("new-entry", BridgeWallpaperKind::Unknown)]
                };
                state.replace_library(replacement.clone());
                assert_eq!(state.library, replacement);
                let retained = choice == 0 && !empty;
                if before.selected_wallpaper_id.is_some() && !retained {
                    assert!(state.selected_wallpaper_id.is_none());
                    assert!(state.app_config.general.last_selected_wallpaper.is_none());
                } else {
                    assert_eq!(state.selected_wallpaper_id, before.selected_wallpaper_id);
                    assert_eq!(
                        state.app_config.general.last_selected_wallpaper,
                        before.app_config.general.last_selected_wallpaper
                    );
                }
                let mut expected_app = before.app_config.clone();
                expected_app.general.last_selected_wallpaper =
                    state.app_config.general.last_selected_wallpaper.clone();
                assert_eq!(state.app_config, expected_app);
                assert_eq!(state.wallpaper_configs, before.wallpaper_configs);
                assert_eq!(state.project_models, before.project_models);
                for id in [A, B] {
                    assert_eq!(
                        state.wallpaper_drafts[id].current(),
                        before.wallpaper_drafts[id].current()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[id].committed(),
                        before.wallpaper_drafts[id].committed()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[id].enabled_displays(),
                        before.wallpaper_drafts[id].enabled_displays()
                    );
                    assert_eq!(
                        state.wallpaper_drafts[id]
                            .effective_enabled_displays(&state.enabled_selectors(id)),
                        before.wallpaper_drafts[id]
                            .effective_enabled_displays(&before.enabled_selectors(id))
                    );
                }
                assert_eq!(state.active_wallpaper_ids, before.active_wallpaper_ids);
                assert_eq!(state.held_wallpapers, before.held_wallpapers);
                assert_eq!(state.errors, before.errors);
                assert_eq!(state.label_locales, before.label_locales);
                assert_eq!(state.suspended_displays, before.suspended_displays);
                assert_eq!(state.library_scanned, scanned);
            }
        }
    }
}

#[test]
fn m14_held_notices_are_assignment_intersections_not_hold_removal_or_scan_counters() {
    let mut state = BridgeActorState::default();
    state.held_wallpapers = BTreeSet::from([A.into(), B.into(), "held-unassigned".into()]);
    let holds = state.held_wallpapers.clone();
    assert!(state.scanned_library().is_none());
    state.replace_library(vec![]);
    assert!(state.scanned_library().is_none());
    for (rows, want) in [
        (vec![], vec![]),
        (
            vec![
                monitor(1, B, true, "independent"),
                monitor(2, A, true, "independent"),
                monitor(3, A, true, "independent"),
            ],
            vec![A, B],
        ),
        (
            vec![
                monitor(1, A, true, "mirror"),
                monitor(2, B, false, "independent"),
            ],
            vec![],
        ),
        (vec![monitor(1, A, false, "independent")], vec![]),
        (vec![monitor(1, A, true, "independent")], vec![A]),
    ] {
        state.app_config.monitors = rows;
        assert_eq!(state.held_assigned_ids(), want);
        assert_eq!(state.held_wallpapers, holds);
    }
    state.replace_library(vec![]);
    assert_eq!(state.held_assigned_ids(), vec![A]);
    assert_eq!(state.held_wallpapers, holds);
}

fn edit(id: &str, value: BridgePropertyValue) -> BridgePropertyEdit {
    BridgePropertyEdit {
        property_id: id.into(),
        value,
    }
}

#[test]
fn m16_pending_documents_validate_membership_and_order_without_inserting_or_mutating_drafts() {
    let mut state = BridgeActorState::default();
    state.library = vec![
        entry(A, BridgeWallpaperKind::ProjectScene),
        entry(B, BridgeWallpaperKind::Video),
        entry(WEB, BridgeWallpaperKind::Webpage),
        entry("unloaded-model", BridgeWallpaperKind::ProjectScene),
    ];
    state.project_models.insert(A.into(), model(A, "scene"));
    state.project_models.insert(B.into(), model(B, "video"));
    state.project_models.insert(WEB.into(), model(WEB, "web"));
    let mut saved = WallpaperConfig::new_for(A, "scene");
    saved
        .property_overrides
        .insert("atlas_file".into(), serde_json::json!("kept/atlas.png"));
    saved
        .property_overrides
        .insert("orbit_directory".into(), serde_json::json!("kept/orbits"));
    saved
        .property_overrides
        .insert("veil_texture".into(), serde_json::json!("kept/veil.png"));
    state.wallpaper_configs.insert(A.into(), saved.clone());
    let edits = vec![
        edit(SLIDER, BridgePropertyValue::Number { value: 0.49 }),
        edit(SLIDER, BridgePropertyValue::Number { value: 0.81 }),
        edit(
            "atlas_file",
            BridgePropertyValue::String {
                value: "pending/atlas.png".into(),
            },
        ),
        edit(
            "orbit_directory",
            BridgePropertyValue::String {
                value: "pending/orbits".into(),
            },
        ),
        edit(
            "veil_texture",
            BridgePropertyValue::String {
                value: "pending/veil.png".into(),
            },
        ),
    ];
    let baseline = serde_json::json!({"atlas_file":"kept/atlas.png","orbit_directory":"kept/orbits",
        "remote_next":"media:next","veil_texture":"kept/veil.png"});
    for with_draft in [false, true] {
        if with_draft {
            let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
                saved.clone(),
                vec![selector(81)],
            );
            draft.edit_property(
                &state.project_models[A],
                "night_switch",
                PropertyValue::Bool(true),
            );
            state.wallpaper_drafts.insert(A.into(), draft);
        }
        let before = state.clone();
        let docs = state
            .pending_property_documents(A, edits.clone())
            .unwrap()
            .unwrap();
        let mut shown = baseline.clone();
        shown[SLIDER] = serde_json::json!(0.81);
        if with_draft {
            shown["night_switch"] = serde_json::json!(true);
        }
        assert_eq!(json_document(&docs.shown), shown);
        assert_eq!(json_document(&docs.saved), baseline);
        assert_eq!(
            docs.shown,
            if with_draft {
                r#"{"atlas_file":"kept/atlas.png","aurora_drift":0.81,"night_switch":true,"orbit_directory":"kept/orbits","remote_next":"media:next","veil_texture":"kept/veil.png"}"#
            } else {
                r#"{"atlas_file":"kept/atlas.png","aurora_drift":0.81,"orbit_directory":"kept/orbits","remote_next":"media:next","veil_texture":"kept/veil.png"}"#
            }
        );
        assert_eq!(
            docs.saved,
            r#"{"atlas_file":"kept/atlas.png","orbit_directory":"kept/orbits","remote_next":"media:next","veil_texture":"kept/veil.png"}"#
        );
        let reverted = state
            .pending_property_documents(
                A,
                vec![
                    edit(SLIDER, BridgePropertyValue::Number { value: 0.6 }),
                    edit(SLIDER, BridgePropertyValue::Number { value: 0.24 }),
                ],
            )
            .unwrap()
            .unwrap();
        assert!(json_document(&reverted.shown).get(SLIDER).is_none());
        let empty = state
            .pending_property_documents(A, vec![])
            .unwrap()
            .unwrap();
        let direct = state
            .wallpaper_draft(A)
            .unwrap()
            .property_documents(&state.project_models[A]);
        assert_eq!(empty, direct);
        for bad in [
            edit(SLIDER, BridgePropertyValue::Number { value: 1.4 }),
            edit(SLIDER, BridgePropertyValue::Bool { value: true }),
            edit("not-authored", BridgePropertyValue::Number { value: 0.4 }),
        ] {
            assert_eq!(
                state
                    .pending_property_documents(A, vec![bad])
                    .unwrap_err()
                    .kind(),
                BridgeErrorKind::InvalidInput
            );
        }
        state.presentation_unloaded = true;
        assert!(
            state
                .pending_property_documents(A, vec![])
                .unwrap()
                .is_some()
        );
        state.presentation_unloaded = before.presentation_unloaded;
        assert_eq!(state.wallpaper_configs, before.wallpaper_configs);
        assert_eq!(state.wallpaper_drafts.len(), before.wallpaper_drafts.len());
        if with_draft {
            assert_eq!(
                state.wallpaper_drafts[A].current(),
                before.wallpaper_drafts[A].current()
            );
            assert_eq!(
                state.wallpaper_drafts[A].committed(),
                before.wallpaper_drafts[A].committed()
            );
            assert_eq!(
                state.wallpaper_drafts[A].enabled_displays(),
                before.wallpaper_drafts[A].enabled_displays()
            );
            assert_eq!(
                state.wallpaper_drafts[A].is_dirty(&[]),
                before.wallpaper_drafts[A].is_dirty(&[])
            );
        }
    }
    let unused = vec![edit(
        "not-authored",
        BridgePropertyValue::Number { value: f64::NAN },
    )];
    for id in [B, WEB, "unloaded-model"] {
        assert!(
            state
                .pending_property_documents(id, unused.clone())
                .unwrap()
                .is_none()
        );
    }
    assert_eq!(
        state
            .pending_property_documents("unknown-wallpaper", unused)
            .unwrap_err()
            .kind(),
        BridgeErrorKind::InvalidInput
    );
    let empty_model = ProjectModel::parse("empty-doc", "{\"type\":\"scene\"}").unwrap();
    let empty =
        WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("empty-doc", "scene"));
    let docs = empty.property_documents(&empty_model);
    assert_eq!(docs.shown, "{}");
    assert_eq!(docs.saved, "{}");
}

#[test]
fn m16_public_k_operations_and_immutable_overlay_preserve_independent_baselines() {
    let model = model(A, "scene");
    let mut cfg = WallpaperConfig::new_for(A, "scene");
    let mut render = MonitorRender::default();
    render.selector = selector(71);
    render.framing.pan_x = 0.19;
    render.framing.pan_y = 0.83;
    cfg.monitors = vec![render.clone(), render.clone()];
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(cfg, vec![selector(71)]);
    draft.edit_property(&model, SLIDER, PropertyValue::Number(0.62));
    draft.set_volume(0.31).unwrap();
    let before = draft.clone();
    let update = draft
        .set_position_immediate(selector(71), Some(0.0), None)
        .unwrap();
    assert!(update.changed);
    assert_eq!(update.previous.pan_x, 0.19);
    assert_eq!(update.previous.pan_y, 0.83);
    assert_eq!(update.framing.pan_x, 0.0);
    assert_eq!(update.framing.pan_y, 0.83);
    assert_eq!(&update.config, draft.committed());
    for view in [draft.current(), draft.committed()] {
        assert_eq!(view.monitors[0].framing, update.framing);
        assert_eq!(view.monitors[1].framing, render.framing);
    }
    assert_eq!(draft.current().audio.volume, before.current().audio.volume);
    assert_eq!(
        draft.committed().audio.volume,
        before.committed().audio.volume
    );
    assert_eq!(
        draft.current().property_overrides,
        before.current().property_overrides
    );
    let no_op = draft
        .set_position_immediate(selector(99), None, None)
        .unwrap();
    assert!(!no_op.changed);
    assert_eq!(draft.current().monitors.len(), 2);
    assert_eq!(draft.committed().monitors.len(), 2);
    let endpoint = draft
        .set_position_immediate(selector(71), Some(1.0), Some(0.0))
        .unwrap();
    assert_eq!(endpoint.framing.pan_x, 1.0);
    assert_eq!(endpoint.framing.pan_y, 0.0);
    for axis in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.1, 1.1] {
        let old = draft.clone();
        assert!(
            draft
                .set_position_immediate(selector(71), Some(axis), None)
                .is_err()
        );
        assert!(
            draft
                .set_position_immediate(selector(71), None, Some(axis))
                .is_err()
        );
        assert_eq!(draft.current(), old.current());
        assert_eq!(draft.committed(), old.committed());
    }
    for enabled in [true, false] {
        let returned = draft.set_media_integration_enabled_immediate(enabled);
        assert_eq!(returned.media_integration_enabled, enabled);
        assert_eq!(draft.current().media_integration_enabled, enabled);
        assert_eq!(draft.committed().media_integration_enabled, enabled);
        assert_eq!(returned.audio.volume, draft.committed().audio.volume);
        assert_eq!(draft.current().audio.volume, 0.31);
        assert_eq!(draft.committed().audio.volume, 1.0);
        assert_eq!(
            draft.current().property_overrides[SLIDER].as_f64(),
            Some(0.62)
        );
        assert!(!draft.committed().property_overrides.contains_key(SLIDER));
        assert_eq!(draft.enabled_displays(), &[selector(71)]);
    }
    for (property, path) in [
        ("atlas_file", "../literal/atlas.png"),
        ("orbit_directory", "~/literal/orbits"),
        ("veil_texture", "textures/not-opened.png"),
    ] {
        let returned = draft.set_property_path_immediate(&model, property, Some(path.into()));
        assert_eq!(
            returned.property_overrides[property],
            serde_json::json!(path)
        );
        assert_eq!(
            draft.current().property_overrides[property],
            serde_json::json!(path)
        );
        assert_eq!(
            draft.committed().property_overrides[property],
            serde_json::json!(path)
        );
        let mut isolated = returned;
        isolated
            .property_overrides
            .insert(property.into(), serde_json::json!("not-shared"));
        assert_ne!(
            draft.current().property_overrides[property],
            isolated.property_overrides[property]
        );
        draft.set_property_path_immediate(&model, property, None);
        // Clearing means no chosen path, not restoration of a nonempty authored default.
        assert_eq!(
            draft.current().property_overrides[property],
            serde_json::json!("")
        );
        assert_eq!(
            draft.committed().property_overrides[property],
            serde_json::json!("")
        );
        assert_eq!(draft.current().audio.volume, 0.31);
        assert_eq!(draft.committed().audio.volume, 1.0);
        assert_eq!(
            draft.current().property_overrides[SLIDER].as_f64(),
            Some(0.62)
        );
        assert!(!draft.committed().property_overrides.contains_key(SLIDER));
        assert_eq!(draft.enabled_displays(), &[selector(71)]);
    }
    draft.set_property_path_immediate(&model, "atlas_file", Some("authored/atlas.png".into()));
    assert!(
        !draft
            .current()
            .property_overrides
            .contains_key("atlas_file")
    );
    assert!(
        !draft
            .committed()
            .property_overrides
            .contains_key("atlas_file")
    );
    let source = draft.clone();
    let overlay = draft.with_edits(
        &model,
        &[
            (SLIDER.into(), PropertyValue::Number(0.52)),
            (SLIDER.into(), PropertyValue::Number(0.79)),
            (
                "veil_texture".into(),
                PropertyValue::String("pending/texture.png".into()),
            ),
        ],
    );
    assert_eq!(
        json_document(&overlay.property_documents(&model).shown)[SLIDER].as_f64(),
        Some(0.79)
    );
    assert_eq!(
        json_document(&overlay.property_documents(&model).shown)["veil_texture"],
        serde_json::json!("")
    );
    assert_eq!(overlay.committed(), source.committed());
    assert_eq!(draft.current(), source.current());
    assert_eq!(draft.committed(), source.committed());
    assert_eq!(draft.enabled_displays(), source.enabled_displays());
    assert_eq!(draft.is_dirty(&[]), source.is_dirty(&[]));
    let empty = draft.with_edits(&model, &[]);
    assert_eq!(empty.current(), draft.current());
    assert_eq!(empty.committed(), draft.committed());
    let mut applied = overlay;
    let committed = applied.apply();
    assert_eq!(&committed, applied.committed());
    assert_eq!(
        applied.property_documents(&model).shown,
        applied.property_documents(&model).saved
    );
    assert_eq!(
        json_document(&applied.property_documents(&model).saved)["veil_texture"],
        serde_json::json!("pending/texture.png")
    );
    applied.edit_property(&model, SLIDER, PropertyValue::Number(0.24));
    let docs = applied.property_documents(&model);
    assert!(json_document(&docs.shown).get(SLIDER).is_none());
    assert!(json_document(&docs.saved).get(SLIDER).is_some());
    assert_eq!(
        json_document(&docs.shown)["veil_texture"],
        serde_json::json!("pending/texture.png")
    );
    applied.cancel();
    assert_eq!(applied.current(), applied.committed());
    for keep in [
        BTreeSet::new(),
        BTreeSet::from([
            "atlas_file".into(),
            "orbit_directory".into(),
            "hidden_file".into(),
            "stale-kept".into(),
        ]),
        BTreeSet::from([
            "atlas_file".into(),
            "orbit_directory".into(),
            "veil_texture".into(),
            "hidden_file".into(),
            "stale-kept".into(),
            "absent".into(),
        ]),
    ] {
        let mut saved = WallpaperConfig::new_for(A, "scene");
        for id in [
            "atlas_file",
            "orbit_directory",
            "veil_texture",
            "hidden_file",
            "stale-kept",
            "stale-remove",
        ] {
            saved
                .property_overrides
                .insert(id.into(), serde_json::json!(format!("literal/{id}")));
        }
        saved
            .property_overrides
            .insert(SLIDER.into(), serde_json::json!(0.74));
        let mut reset = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            saved.clone(),
            vec![selector(71)],
        );
        reset.set_volume(0.41).unwrap();
        reset.restore_all_property_defaults(&keep);
        for id in [
            "atlas_file",
            "orbit_directory",
            "veil_texture",
            "hidden_file",
            "stale-kept",
            "stale-remove",
            SLIDER,
        ] {
            assert_eq!(
                reset.current().property_overrides.contains_key(id),
                keep.contains(id)
            );
        }
        assert_eq!(reset.committed(), &saved);
        assert_eq!(reset.enabled_displays(), &[selector(71)]);
        assert_eq!(reset.current().audio.volume, 0.41);
        reset.cancel();
        assert_eq!(reset.current(), &saved);
        reset.restore_property_default(SLIDER);
        assert!(!reset.current().property_overrides.contains_key(SLIDER));
        assert_eq!(
            reset.current().property_overrides["atlas_file"],
            saved.property_overrides["atlas_file"]
        );
        let accepted = reset.apply();
        assert_eq!(&accepted, reset.current());
        assert_eq!(&accepted, reset.committed());
    }
    let mut nan_cfg = WallpaperConfig::new_for(A, "scene");
    let mut nan_row = MonitorRender::default();
    nan_row.selector = selector(77);
    nan_row.framing.pan_x = f64::NAN;
    nan_cfg.monitors.push(nan_row);
    let mut nan = WallpaperOptionsDraft::from_committed(nan_cfg);
    let update = nan
        .set_position_immediate(selector(77), None, Some(0.5))
        .unwrap();
    assert!(update.previous.pan_x.is_nan());
    assert!(update.framing.pan_x.is_nan());
    assert!(update.changed);
}

#[test]
fn m16_quality_queries_use_actor_scoped_forwards_and_genuine_scale_clamps() {
    for source in [
        PowerSource::Battery,
        PowerSource::External,
        PowerSource::Unknown,
    ] {
        for mode in [
            BatteryModeCfg::Pause,
            BatteryModeCfg::KeepRunning,
            BatteryModeCfg::ReducedQuality,
        ] {
            for causes in [
                vec![],
                vec![BridgeQualityThrottleCause::Heat],
                vec![
                    BridgeQualityThrottleCause::Heat,
                    BridgeQualityThrottleCause::LowBattery,
                ],
            ] {
                let mut state = BridgeActorState::default();
                state.power_source = source;
                state.app_config.power.on_battery = mode;
                state.playback_state = BridgePlaybackState::Paused;
                state.quality_throttle = causes.iter().copied().collect();
                state.app_config.quality.render_scale = 0.79;
                state.app_config.quality.battery.render_scale = 0.43;
                state.app_config.quality.battery.target_fps = 27;
                let battery =
                    source == PowerSource::Battery && mode == BatteryModeCfg::ReducedQuality;
                let throttled = !causes.is_empty();
                let expected = QualityInForce {
                    battery_profile: battery,
                    throttled,
                };
                assert_eq!(quality_in_force(&state), expected);
                for (global, inactive, active) in [
                    (None, None, Some(27)),
                    (Some(0), Some(1), Some(1)),
                    (Some(61), Some(61), Some(27)),
                    (Some(13), Some(13), Some(13)),
                ] {
                    state.app_config.quality.frame_rate_cap = global;
                    assert_eq!(
                        active_target_fps_cap(&state),
                        if battery || throttled {
                            active
                        } else {
                            inactive
                        }
                    );
                }
                state.app_config.quality.frame_rate_cap = None;
                state.app_config.quality.battery.target_fps = 0;
                assert_eq!(
                    active_target_fps_cap(&state),
                    if battery || throttled { Some(1) } else { None }
                );
                assert_eq!(
                    state.app_config.effective_render_scale(expected),
                    if battery || throttled { 0.43 } else { 0.79 }
                );
                assert_eq!(state.playback_state, BridgePlaybackState::Paused);
            }
        }
    }
    let mut app = AppConfig::default();
    for (saved, profile, force, want) in [
        (
            0.12,
            0.7,
            QualityInForce {
                battery_profile: false,
                throttled: false,
            },
            0.25,
        ),
        (
            1.7,
            0.7,
            QualityInForce {
                battery_profile: false,
                throttled: false,
            },
            1.0,
        ),
        (
            f32::NAN,
            0.7,
            QualityInForce {
                battery_profile: false,
                throttled: false,
            },
            1.0,
        ),
        (
            f32::INFINITY,
            0.7,
            QualityInForce {
                battery_profile: false,
                throttled: false,
            },
            1.0,
        ),
        (
            0.31,
            0.86,
            QualityInForce {
                battery_profile: true,
                throttled: false,
            },
            0.86,
        ),
        (
            0.31,
            0.86,
            QualityInForce {
                battery_profile: false,
                throttled: true,
            },
            0.31,
        ),
        (
            0.82,
            0.02,
            QualityInForce {
                battery_profile: true,
                throttled: true,
            },
            0.25,
        ),
        (
            0.31,
            f32::NAN,
            QualityInForce {
                battery_profile: false,
                throttled: true,
            },
            0.31,
        ),
        (
            f32::NAN,
            f32::NAN,
            QualityInForce {
                battery_profile: true,
                throttled: true,
            },
            1.0,
        ),
        (
            0.82,
            f32::NEG_INFINITY,
            QualityInForce {
                battery_profile: true,
                throttled: false,
            },
            1.0,
        ),
    ] {
        app.quality.render_scale = saved;
        app.quality.battery.render_scale = profile;
        assert_eq!(app.effective_render_scale(force), want);
    }
}

// Lifecycle owns shutdown, joined dispatcher/actor termination and runtime-owner release.
async fn finish(bridge: WallpaperBridge) {
    tokio::time::timeout(
        LIMIT,
        crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
    )
    .await
    .expect("bounded lifecycle-owned drain timed out")
    .expect("real bridge drain failed");
}

async fn reconcile_apply(
    bridge: &WallpaperBridge,
    engine: &ControlledEngine,
) -> (
    Result<BridgeWallpaperMutationBundle, BridgeError>,
    Vec<SceneDesc>,
) {
    let control = engine.hold_next_reconcile(Ok(vec![
        SceneResult::new(41, SceneHandle::new(4101), 0),
        SceneResult::new(42, SceneHandle::new(4201), 0),
    ]));
    let operation = async {
        ask!(
            bridge,
            ApplyWallpaperOptions {
                wallpaper_id: A.into(),
                user_initiated: false
            },
            BridgeWallpaperMutationBundle
        )
    };
    let release = async {
        let scenes = tokio::time::timeout(LIMIT, control.entered)
            .await
            .expect("actual reconcile was not entered")
            .expect("reconcile entered sender dropped");
        assert_eq!(scenes.len(), 2);
        let displays: BTreeSet<_> = scenes.iter().map(|s| s.display.display_id).collect();
        assert_eq!(displays, BTreeSet::from([41, 42]));
        for descriptor in &scenes {
            assert_eq!(
                Path::new(&descriptor.scene_path)
                    .parent()
                    .unwrap()
                    .file_name()
                    .unwrap(),
                A
            );
            let payload = descriptor
                .property_override_json
                .as_ref()
                .expect("pending property document missing");
            assert_eq!(json_document(payload)[SLIDER].as_f64(), Some(PENDING));
        }
        control
            .release
            .send(())
            .expect("actual reconcile release receiver dropped");
        engine.emit_first_frame(SceneHandle::new(4101));
        engine.emit_first_frame(SceneHandle::new(4201));
        scenes
    };
    tokio::join!(operation, release)
}

#[derive(Clone, Copy)]
enum SaveFault {
    None,
    App,
    Wallpaper,
}

async fn apply_save_case(reconcile: bool, fault: SaveFault) {
    let root = OwnedRoot::new();
    let paths = root.paths();
    write_projects(&paths);
    let store = root.store();
    let mut state = seeded_state();
    // Real preparation normalizes these retained disabled/mirror target assignments.
    state
        .app_config
        .monitors
        .push(monitor(44, A, false, "independent"));
    state
        .app_config
        .monitors
        .push(monitor(45, A, true, "mirror"));
    if !reconcile {
        install_target_draft(&mut state, false);
    }
    store.save_app_config(&state.app_config).unwrap();
    for cfg in state.wallpaper_configs.values() {
        store.save_wallpaper(cfg).unwrap();
    }
    let engine = ControlledEngine::new(rows(&paths));
    let bridge = builder!(engine.clone(), store.clone(), paths.clone())
        .with_state(state)
        .build()
        .unwrap();
    if reconcile {
        // Prove actual handlers insert/edit the real pending draft, not just local setup.
        assert!(!observe(&bridge).await.wallpaper_drafts.contains_key(A));
        ask!(
            &bridge,
            EditProperty {
                wallpaper_id: A.into(),
                property_id: SLIDER.into(),
                value: BridgePropertyValue::Number { value: PENDING }
            },
            BridgeWallpaperMutationBundle
        )
        .unwrap();
        let key = selector(42).id();
        ask!(
            &bridge,
            SetDisplayConfigEnabled {
                wallpaper_id: A.into(),
                display_id: key,
                enabled: true
            },
            BridgeWallpaperMutationBundle
        )
        .unwrap();
    }
    let before = observe(&bridge).await;
    assert!(before.held_wallpapers.is_empty());
    assert_eq!(
        before.wallpaper_drafts[A].requires_reconcile(&before.enabled_selectors(A)),
        reconcile
    );
    if reconcile {
        assert_eq!(
            before.wallpaper_drafts[A].committed().property_overrides[SLIDER].as_f64(),
            Some(0.35)
        );
        assert_eq!(
            before.wallpaper_drafts[A].current().property_overrides[SLIDER].as_f64(),
            Some(PENDING)
        );
    }
    let captured =
        before.wallpaper_drafts[A].effective_enabled_displays(&before.enabled_selectors(A));
    let prepared = before.prepare_apply(A, None).unwrap();
    assert_eq!(prepared.requires_reconcile(), reconcile);
    let candidate_app = prepared.app_config().clone();
    let candidate_map = prepared.wallpaper_configs().clone();
    assert_ne!(candidate_app, before.app_config);
    let app_target = store.root().join("config.toml");
    let target = store.root().join("wallpapers").join(format!("{A}.json"));
    let baseline_bytes = fs::read(&target).unwrap();
    let relocated = store.root().join("wallpaper-before-obstruction.json");
    let obstruction = match fault {
        SaveFault::None => None,
        SaveFault::App => {
            fs::remove_file(&app_target).unwrap();
            fs::create_dir(&app_target).unwrap();
            fs::write(
                app_target.join("owned-sentinel"),
                b"app obstruction remains",
            )
            .unwrap();
            Some(app_target.clone())
        }
        SaveFault::Wallpaper => {
            // This is a setup relocation, NOT an old JSON surviving at the now-directory target.
            fs::rename(&target, &relocated).unwrap();
            fs::create_dir(&target).unwrap();
            fs::write(
                target.join("owned-sentinel"),
                b"wallpaper obstruction remains",
            )
            .unwrap();
            Some(target.clone())
        }
    };
    let mark = engine.observations().len();
    let reply = if reconcile {
        let (reply, scenes) = reconcile_apply(&bridge, &engine).await;
        assert!(engine.observations()[mark..].iter().any(|observation|matches!(observation,
            EngineObservation::Reconcile{scenes:actual,phase:OperationPhase::Applied} if actual==&scenes)));
        let live = engine.display_rows();
        for (display, raw) in [(41, 4101), (42, 4201)] {
            assert_eq!(
                live.iter()
                    .find(|row| row.desc.display_id == display)
                    .unwrap()
                    .handle
                    .unwrap()
                    .raw(),
                raw
            );
        }
        reply
    } else {
        let result = ask!(
            &bridge,
            ApplyWallpaperOptions {
                wallpaper_id: A.into(),
                user_initiated: false
            },
            BridgeWallpaperMutationBundle
        );
        assert!(
            !engine.observations()[mark..]
                .iter()
                .any(|observation| matches!(observation, EngineObservation::Reconcile { .. }))
        );
        result
    };
    let after = observe(&bridge).await; // A genuine subsequent ask also proves responsiveness.
    let success = matches!(fault, SaveFault::None);
    if success {
        let bundle = reply.unwrap();
        assert_eq!(bundle.app.active_wallpaper_ids, after.active_wallpaper_ids);
        assert_eq!(after.app_config, candidate_app);
        assert_eq!(after.wallpaper_configs, candidate_map);
        assert_eq!(after.wallpaper_drafts[A].current(), &candidate_map[A]);
        assert_eq!(after.wallpaper_drafts[A].committed(), &candidate_map[A]);
        assert_eq!(after.wallpaper_drafts[A].enabled_displays(), captured);
        assert!(!after.wallpaper_drafts[A].is_dirty(&after.enabled_selectors(A)));
        assert_eq!(store.load().unwrap().config, candidate_app);
        assert_eq!(store.load_wallpaper(A).unwrap(), candidate_map[A]);
    } else {
        assert_eq!(reply.unwrap_err().kind(), BridgeErrorKind::Io);
        assert_eq!(
            after.app_config,
            if reconcile {
                candidate_app.clone()
            } else {
                before.app_config.clone()
            }
        );
        assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
        assert_eq!(
            after.wallpaper_drafts[A].current(),
            before.wallpaper_drafts[A].current()
        );
        assert_eq!(
            after.wallpaper_drafts[A].committed(),
            before.wallpaper_drafts[A].committed()
        );
        assert_eq!(
            after.wallpaper_drafts[A].enabled_displays(),
            before.wallpaper_drafts[A].enabled_displays()
        );
        assert_eq!(
            after.wallpaper_drafts[A].effective_enabled_displays(&before.enabled_selectors(A)),
            captured
        );
        assert!(after.wallpaper_drafts[A].is_dirty(&after.enabled_selectors(A)));
        match fault {
            SaveFault::App => {
                assert!(app_target.is_dir());
                assert_eq!(
                    fs::read(app_target.join("owned-sentinel")).unwrap(),
                    b"app obstruction remains"
                );
                assert_eq!(fs::read(&target).unwrap(), baseline_bytes);
            }
            SaveFault::Wallpaper => {
                assert_eq!(store.load().unwrap().config, candidate_app); // app saved FIRST; no transaction rollback
                assert!(target.is_dir());
                assert_eq!(
                    fs::read(target.join("owned-sentinel")).unwrap(),
                    b"wallpaper obstruction remains"
                );
                assert_eq!(fs::read(&relocated).unwrap(), baseline_bytes);
            }
            SaveFault::None => unreachable!(),
        }
    }
    if reconcile {
        assert_eq!(after.active_wallpaper_ids, vec![A, WEB]);
    } else if success {
        assert_eq!(after.active_wallpaper_ids, after.configured_ids());
    } else {
        assert_eq!(after.active_wallpaper_ids, before.active_wallpaper_ids);
    }
    assert_eq!(after.wallpaper_configs[B], before.wallpaper_configs[B]);
    assert_eq!(
        after.wallpaper_drafts[B].current(),
        before.wallpaper_drafts[B].current()
    );
    assert_eq!(
        after.wallpaper_drafts[B].committed(),
        before.wallpaper_drafts[B].committed()
    );
    assert_eq!(
        after.wallpaper_drafts[B].enabled_displays(),
        before.wallpaper_drafts[B].enabled_displays()
    );
    assert_eq!(after.project_models, before.project_models);
    assert_eq!(after.library, before.library);
    assert_eq!(after.selected_wallpaper_id, before.selected_wallpaper_id);
    assert_eq!(after.errors, before.errors);
    assert_eq!(after.held_wallpapers, before.held_wallpapers);
    assert_eq!(after.label_locales, before.label_locales);
    assert_eq!(after.suspended_displays, before.suspended_displays);
    assert_eq!(after.library_scanned, before.library_scanned);
    assert_eq!(after.filter_video, before.filter_video);
    if let Some(path) = obstruction {
        fs::remove_dir_all(path).unwrap();
        // Retry enters real Apply again using the SAME actor-owned retained pending draft.
        let retry = if reconcile {
            reconcile_apply(&bridge, &engine).await.0
        } else {
            ask!(
                &bridge,
                ApplyWallpaperOptions {
                    wallpaper_id: A.into(),
                    user_initiated: false
                },
                BridgeWallpaperMutationBundle
            )
        };
        retry.unwrap();
        let recovered = observe(&bridge).await;
        assert_eq!(recovered.app_config, candidate_app);
        assert_eq!(recovered.wallpaper_configs, candidate_map);
        assert_eq!(recovered.wallpaper_drafts[A].committed(), &candidate_map[A]);
        assert_eq!(recovered.wallpaper_drafts[A].current(), &candidate_map[A]);
        assert!(!recovered.wallpaper_drafts[A].is_dirty(&recovered.enabled_selectors(A)));
        if reconcile {
            assert_eq!(
                recovered.wallpaper_configs[A].property_overrides[SLIDER].as_f64(),
                Some(PENDING)
            );
        }
        assert_eq!(store.load().unwrap().config, candidate_app);
        assert_eq!(store.load_wallpaper(A).unwrap(), candidate_map[A]);
        if matches!(fault, SaveFault::Wallpaper) {
            assert_eq!(fs::read(relocated).unwrap(), baseline_bytes);
        }
    }
    finish(bridge).await;
}

#[tokio::test]
async fn m15a_no_reconcile_both_saves_publish_full_state() {
    apply_save_case(false, SaveFault::None).await;
}
#[tokio::test]
async fn m15b_no_reconcile_app_failure_preserves_every_pending_view() {
    apply_save_case(false, SaveFault::App).await;
}
#[tokio::test]
async fn m15c_no_reconcile_wallpaper_failure_leaves_new_app_on_disk_only() {
    apply_save_case(false, SaveFault::Wallpaper).await;
}
#[tokio::test]
async fn m15d_real_reconcile_and_both_saves_publish_full_scene_web_result() {
    apply_save_case(true, SaveFault::None).await;
}
#[tokio::test]
async fn m15e_real_reconcile_app_failure_publishes_app_only_and_retains_pending_scalar() {
    apply_save_case(true, SaveFault::App).await;
}
#[tokio::test]
async fn m15f_real_reconcile_wallpaper_failure_is_explicitly_nontransactional() {
    apply_save_case(true, SaveFault::Wallpaper).await;
}

#[tokio::test]
async fn m01_builder_loads_store_before_state_and_applies_optional_startup_sample_without_bootstrap()
 {
    for startup in [None, Some(PowerSource::Battery)] {
        let root = OwnedRoot::new();
        let store = root.store();
        let paths = root.paths();
        let mut app = AppConfig::default();
        app.general.last_selected_wallpaper = Some("unscanned-saved-choice".into());
        app.ui.filter.scene = false;
        app.ui.filter.video = true;
        app.ui.filter.web = false;
        app.ui.filter.unknown = true;
        app.ui.selector_window.x = -143;
        app.ui.settings_window.width = 1031;
        app.diagnostics.verbose_logging = true;
        app.quality.render_scale = 0.77;
        app.power.on_battery = BatteryModeCfg::Pause;
        app.monitors = vec![
            monitor(41, B, true, "independent"),
            monitor(42, A, true, "unrecognized"),
            monitor(43, B, true, "independent"),
            monitor(44, "disabled", false, "independent"),
            monitor(45, "mirror", true, "mirror"),
        ];
        store.save_app_config(&app).unwrap();
        let engine = ControlledEngine::new(vec![]);
        let base = builder!(engine.clone(), store, paths);
        let bridge = match startup {
            Some(source) => base.with_startup_power_source(source).build(),
            None => base.build(),
        }
        .unwrap();
        let state = observe(&bridge).await;
        assert_eq!(state.app_config, app);
        assert_eq!(
            state.selected_wallpaper_id,
            app.general.last_selected_wallpaper
        );
        assert_eq!(state.active_wallpaper_ids, vec![A, B]);
        assert_eq!(state.enabled_selectors(B), vec![selector(41), selector(43)]);
        assert!(state.library.is_empty());
        assert!(state.scanned_library().is_none());
        for (kind, want) in [
            (BridgeWallpaperKind::ProjectScene, false),
            (BridgeWallpaperKind::Video, true),
            (BridgeWallpaperKind::Webpage, false),
            (BridgeWallpaperKind::Unknown, true),
        ] {
            assert_eq!(state.filter_enabled(kind), want);
        }
        assert_eq!(state.startup_power_sample_received, startup.is_some());
        if let Some(source) = startup {
            assert_eq!(state.power_source, source);
            assert!(state.pending_battery_pause_after_initial_frame);
        }
        assert!(
            !engine
                .observations()
                .iter()
                .any(|o| matches!(o, EngineObservation::Reconcile { .. }))
        );
        finish(bridge).await;
    }
}

#[tokio::test]
async fn m01_builder_rejects_real_future_schema_instead_of_defaulting() {
    let root = OwnedRoot::new();
    let store = root.store();
    let paths = root.paths();
    let mut app = AppConfig::default();
    app.schema_version = 871;
    app.general.last_selected_wallpaper = Some(A.into());
    store.save_app_config(&app).unwrap();
    match builder!(ControlledEngine::new(vec![]), store, paths).build() {
        Err(error) => assert_eq!(error.kind(), BridgeErrorKind::Config),
        Ok(bridge) => {
            finish(bridge).await;
            panic!("future schema unexpectedly built actor");
        }
    }
}

#[tokio::test]
async fn m02_actual_initial_sample_frame_and_external_resume_keep_user_pause_distinct() {
    for user_paused in [false, true] {
        let root = OwnedRoot::new();
        let paths = root.paths();
        let store = root.store();
        let mut state = BridgeActorState::default();
        state.app_config.power.on_battery = BatteryModeCfg::Pause;
        state.playback_state = if user_paused {
            BridgePlaybackState::Paused
        } else {
            BridgePlaybackState::Playing
        };
        let engine = ControlledEngine::new(vec![]);
        let bridge = builder!(engine.clone(), store, paths)
            .with_state(state)
            .build()
            .unwrap();
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::Battery,
                initial_sample: true
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let sampled = observe(&bridge).await;
        assert!(sampled.startup_power_sample_received);
        assert!(sampled.pending_battery_pause_after_initial_frame);
        assert!(!sampled.auto_paused_for_battery);
        assert_eq!(
            sampled.playback_state,
            if user_paused {
                BridgePlaybackState::Paused
            } else {
                BridgePlaybackState::Playing
            }
        );
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::External,
                initial_sample: true
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let duplicate = observe(&bridge).await;
        assert_eq!(duplicate.power_source, PowerSource::Battery);
        assert_eq!(
            duplicate.pending_battery_pause_after_initial_frame,
            sampled.pending_battery_pause_after_initial_frame
        );
        ask!(&bridge, InitialFrameReady, BridgeSnapshotBundle).unwrap();
        let framed = observe(&bridge).await;
        assert!(framed.initial_frame_ready);
        assert!(!framed.pending_battery_pause_after_initial_frame);
        assert_eq!(framed.playback_state, BridgePlaybackState::Paused);
        assert_eq!(framed.auto_paused_for_battery, !user_paused);
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::Unknown,
                initial_sample: false
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        assert_eq!(
            observe(&bridge).await.playback_state,
            BridgePlaybackState::Paused
        );
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::External,
                initial_sample: false
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let external = observe(&bridge).await;
        assert!(!external.auto_paused_for_battery);
        assert!(!external.battery_pause_suppressed);
        assert!(!external.pending_battery_pause_after_initial_frame);
        assert_eq!(
            external.playback_state,
            if user_paused {
                BridgePlaybackState::Paused
            } else {
                BridgePlaybackState::Playing
            }
        );
        if !user_paused {
            assert!(engine.observations().iter().any(|o| matches!(
                o,
                EngineObservation::PauseAll {
                    paused: true,
                    phase: OperationPhase::Applied,
                    ..
                }
            )));
            assert!(engine.observations().iter().any(|o| matches!(
                o,
                EngineObservation::PauseAll {
                    paused: false,
                    phase: OperationPhase::Applied,
                    ..
                }
            )));
        }
        finish(bridge).await;
    }
    let root = OwnedRoot::new();
    let paths = root.paths();
    let store = root.store();
    let mut state = BridgeActorState::default();
    state.app_config.power.on_battery = BatteryModeCfg::Pause;
    let bridge = builder!(ControlledEngine::new(vec![]), store, paths)
        .with_state(state)
        .with_startup_power_source(PowerSource::Battery)
        .build()
        .unwrap();
    ask!(
        &bridge,
        SetPowerSource {
            source: PowerSource::External,
            initial_sample: true
        },
        BridgeSnapshotBundle
    )
    .unwrap();
    let state = observe(&bridge).await;
    assert_eq!(state.power_source, PowerSource::Battery);
    assert!(state.pending_battery_pause_after_initial_frame);
    finish(bridge).await;
}

#[tokio::test]
async fn m12_refresh_library_replaces_models_and_scans_empty_but_preserves_on_real_root_errors() {
    // Each root error runs with both scan-knowledge states, not an invalid child's skip path.
    for scanned in [false, true] {
        for root_kind in [0, 1] {
            let root = OwnedRoot::new();
            let paths = root.paths();
            let store = root.store();
            if root_kind == 1 {
                fs::create_dir_all(paths.steam_workshop_root().parent().unwrap()).unwrap();
                fs::write(paths.steam_workshop_root(), b"not a directory").unwrap();
            }
            let mut state = seeded_state();
            install_target_draft(&mut state, true);
            state.library_scanned = scanned;
            let before = state.clone();
            let bridge = builder!(ControlledEngine::new(vec![]), store, paths)
                .with_state(state)
                .build()
                .unwrap();
            let error = ask!(&bridge, RefreshLibrary, BridgeSnapshotBundle).unwrap_err();
            assert_eq!(
                error.kind(),
                if root_kind == 0 {
                    BridgeErrorKind::Library
                } else {
                    BridgeErrorKind::Io
                }
            );
            let after = observe(&bridge).await;
            assert_eq!(after.library, before.library);
            assert_eq!(after.project_models, before.project_models);
            assert_eq!(after.selected_wallpaper_id, before.selected_wallpaper_id);
            assert_eq!(after.app_config, before.app_config);
            assert_eq!(after.library_scanned, scanned);
            assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
            assert_eq!(
                after.wallpaper_drafts[A].current(),
                before.wallpaper_drafts[A].current()
            );
            assert_eq!(
                after.wallpaper_drafts[A].committed(),
                before.wallpaper_drafts[A].committed()
            );
            assert_eq!(
                after.wallpaper_drafts[A].enabled_displays(),
                before.wallpaper_drafts[A].enabled_displays()
            );
            finish(bridge).await;
        }
    }
    for empty in [false, true] {
        let root = OwnedRoot::new();
        let paths = root.paths();
        let store = root.store();
        fs::create_dir_all(paths.steam_workshop_root()).unwrap();
        if !empty {
            for (id, kind) in [(A, "web"), ("687241547", "scene")] {
                let file = paths.project_json(id);
                fs::create_dir_all(file.parent().unwrap()).unwrap();
                fs::write(file,serde_json::json!({"type":kind,"title":format!("Juniper {id}"),"file":"fresh.scene"}).to_string()).unwrap();
            }
            let invalid = paths.project_json("687241551");
            fs::create_dir_all(invalid.parent().unwrap()).unwrap();
            fs::write(invalid, b"not json").unwrap();
        }
        let mut state = seeded_state();
        install_target_draft(&mut state, true);
        state.held_wallpapers.insert(A.into());
        let before = state.clone();
        let engine = ControlledEngine::new(vec![]);
        let bridge = builder!(engine, store, paths.clone())
            .with_state(state)
            .build()
            .unwrap();
        ask!(&bridge, RefreshLibrary, BridgeSnapshotBundle).unwrap();
        let after = observe(&bridge).await;
        assert!(after.library_scanned);
        assert!(after.scanned_library().is_some());
        assert!(after.selected_wallpaper_id.is_none());
        assert!(after.app_config.general.last_selected_wallpaper.is_none());
        if empty {
            assert!(after.library.is_empty());
            assert!(after.project_models.is_empty());
            assert!(after.scanned_library().unwrap().is_empty());
        } else {
            assert_eq!(
                after
                    .library
                    .iter()
                    .map(|entry| entry.id.as_str())
                    .collect::<Vec<_>>(),
                vec![A, "687241547"]
            );
            assert_eq!(after.project_models.len(), 2);
            assert!(after.is_web_wallpaper(A));
            assert_ne!(after.project_models[A], before.project_models[A]);
            assert!(!after.project_models.contains_key("687241551"));
        }
        assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
        assert_eq!(after.active_wallpaper_ids, before.active_wallpaper_ids);
        assert_eq!(after.held_wallpapers, before.held_wallpapers);
        assert_eq!(after.errors, before.errors);
        assert_eq!(after.label_locales, before.label_locales);
        for id in [A, B] {
            assert_eq!(
                after.wallpaper_drafts[id].current(),
                before.wallpaper_drafts[id].current()
            );
            assert_eq!(
                after.wallpaper_drafts[id].committed(),
                before.wallpaper_drafts[id].committed()
            );
            assert_eq!(
                after.wallpaper_drafts[id].enabled_displays(),
                before.wallpaper_drafts[id].enabled_displays()
            );
        }
        // A later genuine whole-root failure does not erase knowledge of the successful scan.
        fs::remove_dir_all(paths.steam_workshop_root()).unwrap();
        assert_eq!(
            ask!(&bridge, RefreshLibrary, BridgeSnapshotBundle)
                .unwrap_err()
                .kind(),
            BridgeErrorKind::Library
        );
        let failed = observe(&bridge).await;
        assert!(failed.library_scanned);
        assert_eq!(failed.library, after.library);
        assert_eq!(failed.project_models, after.project_models);
        finish(bridge).await;
    }
}

#[tokio::test]
async fn m12_select_wallpaper_checks_membership_load_precedence_and_both_disk_bypass_paths() {
    for scenario in 0..5 {
        let root = OwnedRoot::new();
        let paths = root.paths();
        let store = root.store();
        let mut state = seeded_state();
        let mut disk = wallpaper(A, "scene");
        disk.audio.volume = 0.58;
        disk.schema_version = if scenario == 4 { 1 } else { 923 };
        store.save_wallpaper(&disk).unwrap();
        store.save_app_config(&state.app_config).unwrap();
        let app_bytes = fs::read(store.root().join("config.toml")).unwrap();
        let wallpaper_bytes =
            fs::read(store.root().join("wallpapers").join(format!("{A}.json"))).unwrap();
        state.wallpaper_configs.remove(A);
        state.wallpaper_drafts.remove(A);
        if scenario == 0 {
            state.library.retain(|entry| entry.id != A);
        }
        if scenario == 2 {
            state
                .wallpaper_configs
                .insert(A.into(), wallpaper(A, "scene"));
        }
        if scenario == 3 {
            let mut draft = WallpaperOptionsDraft::from_committed(wallpaper(A, "scene"));
            draft.set_volume(0.29).unwrap();
            state.wallpaper_drafts.insert(A.into(), draft);
        }
        let before = state.clone();
        let bridge = builder!(ControlledEngine::new(vec![]), store.clone(), paths)
            .with_state(state)
            .build()
            .unwrap();
        let reply = ask!(
            &bridge,
            SelectWallpaper { id: A.into() },
            BridgeSnapshotBundle
        );
        let after = observe(&bridge).await;
        if scenario <= 1 {
            assert_eq!(
                reply.unwrap_err().kind(),
                if scenario == 0 {
                    BridgeErrorKind::InvalidInput
                } else {
                    BridgeErrorKind::Config
                }
            );
            assert_eq!(after.selected_wallpaper_id, before.selected_wallpaper_id);
            assert_eq!(after.app_config, before.app_config);
            assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
            assert!(!after.wallpaper_drafts.contains_key(A));
        } else {
            let snapshot = reply.unwrap();
            assert_eq!(snapshot.app.selected_wallpaper_id, Some(A.into()));
            assert_eq!(after.selected_wallpaper_id, Some(A.into()));
            assert_eq!(
                after.app_config.general.last_selected_wallpaper,
                Some(A.into())
            );
            if scenario == 2 || scenario == 3 {
                assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
            }
            if scenario == 2 {
                assert_eq!(after.wallpaper_configs[A], before.wallpaper_configs[A]);
            }
            if scenario == 3 {
                assert_eq!(
                    after.wallpaper_drafts[A].current(),
                    before.wallpaper_drafts[A].current()
                );
                assert_eq!(
                    after.wallpaper_drafts[A].committed(),
                    before.wallpaper_drafts[A].committed()
                );
                assert_eq!(
                    after.wallpaper_drafts[A].enabled_displays(),
                    before.wallpaper_drafts[A].enabled_displays()
                );
            }
            if scenario == 4 {
                assert_eq!(after.wallpaper_configs[A], disk);
            }
        }
        assert_eq!(
            fs::read(store.root().join("config.toml")).unwrap(),
            app_bytes
        );
        assert_eq!(
            fs::read(store.root().join("wallpapers").join(format!("{A}.json"))).unwrap(),
            wallpaper_bytes
        );
        assert_eq!(after.project_models, before.project_models);
        assert_eq!(after.wallpaper_configs[B], before.wallpaper_configs[B]);
        finish(bridge).await;
    }
}

#[tokio::test]
async fn m14_real_assignment_apply_publishes_held_notice_without_forgiving_hold() {
    let root = OwnedRoot::new();
    let paths = root.paths();
    write_projects(&paths);
    let store = root.store();
    let mut state = seeded_state();
    let mut primary = monitor(41, A, true, "independent");
    primary.selector = SerializedSelector::Primary;
    state.app_config.monitors = vec![primary];
    state.held_wallpapers.insert(A.into());
    state.active_wallpaper_ids = vec![A.into()];
    let engine = ControlledEngine::new(vec![display_row(&paths, 41, None, None)]);
    let bridge = builder!(engine.clone(), store, paths)
        .with_state(state)
        .build()
        .unwrap();
    let snapshot = ask!(
        &bridge,
        SelectWallpaper { id: A.into() },
        BridgeSnapshotBundle
    )
    .unwrap();
    assert_eq!(snapshot.app.held_wallpaper_ids, vec![A]);
    ask!(
        &bridge,
        SetDisplayConfigEnabled {
            wallpaper_id: A.into(),
            display_id: selector(41).id(),
            enabled: false
        },
        BridgeWallpaperMutationBundle
    )
    .unwrap();
    let control = engine.hold_next_reconcile(Ok(vec![]));
    let operation = async {
        ask!(
            &bridge,
            ApplyWallpaperOptions {
                wallpaper_id: A.into(),
                user_initiated: false
            },
            BridgeWallpaperMutationBundle
        )
        .expect("held Apply failed before its controlled reconcile completed")
    };
    let release = async {
        let scenes = tokio::time::timeout(LIMIT, control.entered)
            .await
            .expect("held apply not entered")
            .expect("entered sender lost");
        assert!(scenes.is_empty());
        control.release.send(()).expect("release receiver lost");
    };
    let (snapshot, ()) = tokio::join!(operation, release);
    assert!(snapshot.app.held_wallpaper_ids.is_empty());
    let after = observe(&bridge).await;
    assert_eq!(after.held_wallpapers, BTreeSet::from([A.into()]));
    assert!(after.held_assigned_ids().is_empty());
    finish(bridge).await;
}

#[tokio::test]
async fn m16_quality_handlers_preserve_user_pause_and_retry_equal_throttle_after_real_dependency_error()
 {
    for fail_fps in [false, true] {
        let root = OwnedRoot::new();
        let paths = root.paths();
        let store = root.store();
        let mut state = seeded_state();
        state.app_config.monitors = vec![monitor(41, A, true, "independent")];
        state.active_wallpaper_ids = vec![A.into()];
        state.playback_state = BridgePlaybackState::Paused;
        state.power_source = PowerSource::External;
        state.initial_frame_ready = true;
        state.app_config.quality.render_scale = 0.81;
        state.app_config.quality.frame_rate_cap = Some(59);
        state.app_config.quality.battery.render_scale = 0.44;
        state.app_config.quality.battery.target_fps = 23;
        let mut row = display_row(&paths, 41, Some(A), Some(4101));
        row.paused = true;
        let engine = ControlledEngine::new(vec![row]);
        let bridge = builder!(engine.clone(), store, paths)
            .with_state(state)
            .build()
            .unwrap();
        ask!(
            &bridge,
            SetRenderScale { scale: 0.81 },
            BridgeSnapshotBundle
        )
        .unwrap();
        ask!(
            &bridge,
            SetFrameRateCap { cap: Some(37) },
            BridgeSnapshotBundle
        )
        .unwrap();
        ask!(
            &bridge,
            SetBatteryQualityProfile {
                render_scale: 0.43,
                target_fps: 19
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        ask!(
            &bridge,
            SetBatteryMode {
                mode: BatteryModeCfg::ReducedQuality
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::Battery,
                initial_sample: false
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let battery = observe(&bridge).await;
        assert_eq!(battery.playback_state, BridgePlaybackState::Paused);
        assert!(!battery.auto_paused_for_battery);
        assert_eq!(
            quality_in_force(&battery),
            QualityInForce {
                battery_profile: true,
                throttled: false
            }
        );
        assert!(engine.observations().iter().any(|o|matches!(o,EngineObservation::Fps{handle,fps:19,phase:OperationPhase::Applied} if handle.raw()==4101)));
        assert!(engine.observations().iter().any(|o|matches!(o,EngineObservation::RenderScale{handle,scale,phase:OperationPhase::Applied} if handle.raw()==4101 && *scale==0.43)));
        ask!(
            &bridge,
            SetPowerSource {
                source: PowerSource::External,
                initial_sample: false
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        ask!(
            &bridge,
            SetBatteryQualityProfile {
                render_scale: 0.25,
                target_fps: 1
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let before = observe(&bridge).await;
        let mark = engine.observations().len();
        if fail_fps {
            engine.fail_next_fps(EngineError::Render("independent fps rejection".into()));
        } else {
            engine
                .fail_next_render_scale(EngineError::Render("independent scale rejection".into()));
        }
        let causes = vec![
            BridgeQualityThrottleCause::Heat,
            BridgeQualityThrottleCause::LowBattery,
        ];
        assert_eq!(
            ask!(
                &bridge,
                SetQualityThrottle {
                    causes: causes.clone()
                },
                BridgeSnapshotBundle
            )
            .unwrap_err()
            .kind(),
            BridgeErrorKind::Engine
        );
        let failed = observe(&bridge).await;
        assert_eq!(failed.quality_throttle, causes.iter().copied().collect());
        assert_eq!(failed.app_config, before.app_config);
        assert_eq!(failed.playback_state, BridgePlaybackState::Paused);
        assert_eq!(failed.active_wallpaper_ids, before.active_wallpaper_ids);
        assert_eq!(failed.wallpaper_configs, before.wallpaper_configs);
        assert_eq!(
            failed.wallpaper_drafts[B].current(),
            before.wallpaper_drafts[B].current()
        );
        assert!(engine.observations()[mark..].iter().any(|o|if fail_fps {
            matches!(o,EngineObservation::Fps{handle,fps:1,phase:OperationPhase::Rejected} if handle.raw()==4101)
        } else {matches!(o,EngineObservation::RenderScale{handle,scale,phase:OperationPhase::Rejected} if handle.raw()==4101 && *scale==0.25)}));
        let retry_mark = engine.observations().len();
        ask!(
            &bridge,
            SetQualityThrottle {
                causes: causes.clone()
            },
            BridgeSnapshotBundle
        )
        .unwrap();
        let retried = observe(&bridge).await;
        assert_eq!(retried.quality_throttle, failed.quality_throttle);
        assert_eq!(retried.app_config, before.app_config);
        assert_eq!(retried.playback_state, BridgePlaybackState::Paused);
        assert_eq!(retried.active_wallpaper_ids, before.active_wallpaper_ids);
        assert!(engine.observations()[retry_mark..].iter().any(|o|matches!(o,EngineObservation::Fps{handle,fps:1,phase:OperationPhase::Applied} if handle.raw()==4101)));
        assert!(engine.observations()[retry_mark..].iter().any(|o|matches!(o,EngineObservation::RenderScale{handle,scale,phase:OperationPhase::Applied} if handle.raw()==4101 && *scale==0.25)));
        let restoration_mark = engine.observations().len();
        ask!(
            &bridge,
            SetQualityThrottle { causes: vec![] },
            BridgeSnapshotBundle
        )
        .unwrap();
        let cleared = observe(&bridge).await;
        assert!(cleared.quality_throttle.is_empty());
        assert_eq!(cleared.app_config, before.app_config);
        assert_eq!(cleared.playback_state, BridgePlaybackState::Paused);
        let restoration = engine.observations();
        assert!(restoration[restoration_mark..].iter().any(|o|matches!(o,EngineObservation::Fps{handle,fps:37,phase:OperationPhase::Started} if handle.raw()==4101)));
        assert!(restoration[restoration_mark..].iter().any(|o|matches!(o,EngineObservation::Fps{handle,fps:37,phase:OperationPhase::Applied} if handle.raw()==4101)));
        let live = engine.display_rows();
        let row = live
            .iter()
            .find(|row| row.desc.display_id == 41)
            .expect("quality target display missing");
        assert_eq!(
            row.handle
                .as_ref()
                .expect("live handle missing after throttle clear")
                .raw(),
            4101
        );
        match row
            .assignment
            .as_ref()
            .expect("live assignment missing after throttle clear")
        {
            WallpaperAssignment::Direct(template) => {
                assert_eq!(template.for_display(row.desc.clone()).fps, 37)
            }
            WallpaperAssignment::Mirror(_) => {
                panic!("quality fixture unexpectedly became mirrored")
            }
        }
        finish(bridge).await;
    }
}

#[tokio::test]
async fn m16_unload_keeps_active_marks_suppresses_exports_and_reload_uses_real_configured_scenes() {
    let root = OwnedRoot::new();
    let paths = root.paths();
    write_projects(&paths);
    let store = root.store();
    let mut state = seeded_state();
    state.app_config.monitors = vec![
        monitor(41, A, true, "independent"),
        monitor(43, WEB, true, "independent"),
    ];
    state.active_wallpaper_ids = vec![A.into(), WEB.into()];
    let engine = ControlledEngine::new(vec![
        display_row(&paths, 41, Some(A), Some(4101)),
        display_row(&paths, 43, None, None),
    ]);
    let bridge = builder!(engine.clone(), store, paths)
        .with_state(state)
        .build()
        .unwrap();
    let loaded_web = ask!(&bridge, GetWebWallpapers, Vec<BridgeWebWallpaper>).unwrap();
    assert!(
        !loaded_web.is_empty(),
        "configured loaded Web must export before unload"
    );
    let mark = engine.observations().len();
    let snapshot = ask!(
        &bridge,
        SetPresentationUnloaded { unloaded: true },
        BridgeSnapshotBundle
    )
    .unwrap();
    assert_eq!(snapshot.app.active_wallpaper_ids, vec![A, WEB]);
    let unloaded = observe(&bridge).await;
    assert!(unloaded.presentation_unloaded);
    assert_eq!(unloaded.active_wallpaper_ids, vec![A, WEB]);
    assert!(engine.observations()[mark..].iter().any(|o|matches!(o,EngineObservation::Reconcile{scenes,phase:OperationPhase::Applied} if scenes.is_empty())));
    let after_first = engine.observations().len();
    ask!(
        &bridge,
        SetPresentationUnloaded { unloaded: true },
        BridgeSnapshotBundle
    )
    .unwrap();
    assert!(
        !engine.observations()[after_first..]
            .iter()
            .any(|o| matches!(o, EngineObservation::Reconcile { .. }))
    );
    let web = ask!(&bridge, GetWebWallpapers, Vec<BridgeWebWallpaper>).unwrap();
    assert!(web.is_empty());
    let control =
        engine.hold_next_reconcile(Ok(vec![SceneResult::new(41, SceneHandle::new(4101), 0)]));
    let reload = async {
        ask!(
            &bridge,
            SetPresentationUnloaded { unloaded: false },
            BridgeSnapshotBundle
        )
    };
    let release = async {
        let scenes = tokio::time::timeout(LIMIT, control.entered)
            .await
            .expect("reload never reconciled")
            .expect("reload entered sender dropped");
        assert_eq!(scenes.len(), 1);
        assert_eq!(scenes[0].display.display_id, 41);
        assert_eq!(
            Path::new(&scenes[0].scene_path)
                .parent()
                .unwrap()
                .file_name()
                .unwrap(),
            A
        );
        control
            .release
            .send(())
            .expect("reload release receiver dropped");
        engine.emit_first_frame(SceneHandle::new(4101));
    };
    let (reply, ()) = tokio::join!(reload, release);
    let snapshot = reply.unwrap();
    assert_eq!(snapshot.app.active_wallpaper_ids, vec![A, WEB]);
    let loaded = observe(&bridge).await;
    assert!(!loaded.presentation_unloaded);
    assert_eq!(loaded.active_wallpaper_ids, vec![A, WEB]);
    assert_eq!(loaded.wallpaper_configs, unloaded.wallpaper_configs);
    assert_eq!(
        loaded.wallpaper_drafts[B].current(),
        unloaded.wallpaper_drafts[B].current()
    );
    finish(bridge).await;
}

#[tokio::test]
async fn m16_refresh_displays_persists_real_known_display_change_before_rebase_and_preserves_pending_values()
 {
    for obstruct in [false, true] {
        let root = OwnedRoot::new();
        let paths = root.paths();
        write_projects(&paths);
        let store = root.store();
        let mut state = seeded_state();
        let mut primary = MonitorCfg::default();
        primary.wallpaper = Some(A.into());
        state.app_config.monitors = vec![primary, monitor(41, A, true, "independent")];
        let selectors = state.enabled_selectors(A);
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            state.wallpaper_configs[A].clone(),
            selectors.clone(),
        );
        draft.edit_property(
            &state.project_models[A],
            SLIDER,
            PropertyValue::Number(PENDING),
        );
        draft.set_display_enabled(selector(42), true, &selectors);
        state.wallpaper_drafts.insert(A.into(), draft);
        store.save_app_config(&state.app_config).unwrap();
        let before = state.clone();
        let engine = ControlledEngine::new(vec![]);
        let bridge = builder!(engine.clone(), store.clone(), paths.clone())
            .with_state(state)
            .build()
            .unwrap();
        if obstruct {
            let target = store.root().join("config.toml");
            fs::remove_file(&target).unwrap();
            fs::create_dir(&target).unwrap();
            fs::write(target.join("owned-sentinel"), b"refresh obstruction").unwrap();
        }
        // Parent-declared actual sync protects Primary(A) and removes its live41 assignment alias.
        // The formerly empty display inventory now reports the matching empty-identity display.
        engine.replace_display_rows(vec![display_row(&paths, 41, None, None)]);
        let reply = if obstruct {
            // Actual first-save error exits before reconcile_configured: install no unused gate.
            let reply = ask!(&bridge, RefreshDisplays, BridgeSnapshotBundle);
            assert!(
                !engine
                    .observations()
                    .iter()
                    .any(|o| matches!(o, EngineObservation::Reconcile { .. }))
            );
            reply
        } else {
            let control = engine.hold_next_reconcile(Ok(vec![SceneResult::new(
                41,
                SceneHandle::new(4101),
                0,
            )]));
            let refresh = async { ask!(&bridge, RefreshDisplays, BridgeSnapshotBundle) };
            let release = async {
                let scenes = tokio::time::timeout(LIMIT, control.entered)
                    .await
                    .expect("RefreshDisplays did not enter real configured reconcile")
                    .expect("refresh entered sender dropped");
                assert_eq!(scenes.len(), 1);
                assert_eq!(scenes[0].display.display_id, 41);
                assert_eq!(
                    Path::new(&scenes[0].scene_path)
                        .parent()
                        .unwrap()
                        .file_name()
                        .unwrap(),
                    A
                );
                let persisted = store.load().unwrap().config;
                assert_ne!(persisted, before.app_config);
                assert!(
                    persisted
                        .monitors
                        .iter()
                        .any(|row| row.selector == SerializedSelector::Primary
                            && row.wallpaper.as_deref() == Some(A))
                );
                assert!(
                    !persisted
                        .monitors
                        .iter()
                        .any(|row| row.selector == selector(41)
                            && row.wallpaper.as_deref() == Some(A))
                );
                control
                    .release
                    .send(())
                    .expect("refresh release receiver dropped");
                engine.emit_first_frame(SceneHandle::new(4101));
            };
            let (reply, ()) = tokio::join!(refresh, release);
            reply
        };
        let after = observe(&bridge).await;
        assert!(engine.observations().iter().any(|o| matches!(
            o,
            EngineObservation::Refresh {
                phase: OperationPhase::Applied
            }
        )));
        assert_eq!(after.wallpaper_configs, before.wallpaper_configs);
        assert_eq!(after.wallpaper_drafts.len(), before.wallpaper_drafts.len());
        for id in [A, B] {
            assert_eq!(
                after.wallpaper_drafts[id].current(),
                before.wallpaper_drafts[id].current()
            );
            assert_eq!(
                after.wallpaper_drafts[id].committed(),
                before.wallpaper_drafts[id].committed()
            );
            if obstruct {
                assert_eq!(
                    after.wallpaper_drafts[id].enabled_displays(),
                    before.wallpaper_drafts[id].enabled_displays()
                );
                assert_eq!(
                    after.wallpaper_drafts[id]
                        .effective_enabled_displays(&before.enabled_selectors(id)),
                    before.wallpaper_drafts[id]
                        .effective_enabled_displays(&before.enabled_selectors(id))
                );
            } else {
                let mut expected = before.wallpaper_drafts[id].clone();
                expected.rebase_enabled_displays(after.enabled_selectors(id));
                assert_eq!(
                    after.wallpaper_drafts[id].enabled_displays(),
                    expected.enabled_displays()
                );
                assert_eq!(
                    after.wallpaper_drafts[id]
                        .effective_enabled_displays(&after.enabled_selectors(id)),
                    expected.effective_enabled_displays(&after.enabled_selectors(id))
                );
            }
        }
        if obstruct {
            assert_eq!(reply.unwrap_err().kind(), BridgeErrorKind::Io);
            assert_eq!(after.app_config, before.app_config);
            assert_eq!(
                fs::read(store.root().join("config.toml/owned-sentinel")).unwrap(),
                b"refresh obstruction"
            );
        } else {
            reply.unwrap();
            assert_ne!(after.app_config, before.app_config);
            assert_eq!(
                after.enabled_selectors(A),
                vec![SerializedSelector::Primary]
            );
            assert_eq!(
                after.wallpaper_drafts[A].enabled_displays(),
                &[SerializedSelector::Primary]
            );
            assert_ne!(
                after.wallpaper_drafts[A].enabled_displays(),
                before.wallpaper_drafts[A].enabled_displays()
            );
            assert_eq!(
                after.wallpaper_drafts[A].current().property_overrides[SLIDER].as_f64(),
                Some(PENDING)
            );
            assert_eq!(
                after.wallpaper_drafts[A].committed().property_overrides[SLIDER].as_f64(),
                Some(0.35)
            );
            assert_eq!(store.load().unwrap().config, after.app_config);
            assert!(!after.wallpaper_drafts.contains_key(WEB));
        }
        finish(bridge).await;
    }
}

#[test]
fn m16_pending_texture_alone_stays_committed_until_apply_and_scalar_default_is_omitted() {
    let model = model(A, "scene");
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for(A, "scene"));
    let baseline = draft.property_documents(&model);
    draft.edit_property(
        &model,
        "veil_texture",
        PropertyValue::String("new/literal-texture.png".into()),
    );
    assert_eq!(draft.property_documents(&model), baseline);
    draft.edit_property(&model, SLIDER, PropertyValue::Number(0.57));
    let pending = draft.property_documents(&model);
    assert_eq!(json_document(&pending.shown)[SLIDER].as_f64(), Some(0.57));
    assert_eq!(pending.saved, baseline.saved);
    assert!(json_document(&pending.shown).get("veil_texture").is_none());
    draft.apply();
    let committed = draft.property_documents(&model);
    assert_eq!(committed.shown, committed.saved);
    assert_eq!(
        json_document(&committed.saved)["veil_texture"],
        serde_json::json!("new/literal-texture.png")
    );
    draft.edit_property(&model, SLIDER, PropertyValue::Number(0.24));
    let reverted = draft.property_documents(&model);
    assert!(json_document(&reverted.shown).get(SLIDER).is_none());
    assert_eq!(json_document(&reverted.saved)[SLIDER].as_f64(), Some(0.57));
    assert_eq!(
        json_document(&reverted.shown)["veil_texture"],
        json_document(&reverted.saved)["veil_texture"]
    );
}

#[tokio::test]
async fn m16_native_video_unload_routing_has_a_real_loaded_descriptor_positive_control() {
    let root = OwnedRoot::new();
    let paths = root.paths();
    let store = root.store();
    let id = "687241589";
    let entry_file = "opaque-routing-sample.mp4";
    let metadata =
        serde_json::json!({"type":"video","title":"Copper routing metadata","file":entry_file});
    let project = paths.project_json(id);
    fs::create_dir_all(project.parent().unwrap()).unwrap();
    fs::write(&project, metadata.to_string()).unwrap();
    let media = paths.steam_workshop_root().join(id).join(entry_file);
    // Admission inspects regular-file metadata only. These explicitly opaque bytes are NOT
    // playable media, a decoder fixture, or evidence about a native host/player/pixels.
    fs::write(
        &media,
        b"opaque metadata-only native-video routing fixture; not playable video\n",
    )
    .unwrap();
    assert!(fs::metadata(&media).unwrap().is_file());
    let parsed = ProjectModel::parse(id, &metadata.to_string()).unwrap();
    let mut app = AppConfig::default();
    app.monitors = vec![monitor(61, id, true, "independent")];
    let mut config = WallpaperConfig::new_for(id, "video");
    config.audio.volume = 0.36;
    config.audio.muted = true;
    store.save_app_config(&app).unwrap();
    store.save_wallpaper(&config).unwrap();
    let mut state = BridgeActorState::from_app_config(app);
    state.library = vec![entry(id, BridgeWallpaperKind::Video)];
    state.project_models.insert(id.into(), parsed);
    state.wallpaper_configs.insert(id.into(), config);
    let engine = ControlledEngine::new(vec![display_row(&paths, 61, None, None)]);
    let bridge = builder!(engine.clone(), store, paths)
        .with_state(state)
        .build()
        .unwrap();
    let loaded = ask!(
        &bridge,
        GetNativeVideoWallpapers,
        Vec<BridgeNativeVideoWallpaper>
    )
    .unwrap();
    assert_eq!(
        loaded.len(),
        1,
        "regular owned metadata fixture must admit an actual loaded descriptor"
    );
    let descriptor = loaded
        .iter()
        .find(|row| row.display_id == 61 && row.wallpaper_id == id)
        .expect("actual native-video descriptor for configured id/display missing");
    assert_eq!(descriptor.media_path, media.to_string_lossy().into_owned());
    ask!(
        &bridge,
        SetPresentationUnloaded { unloaded: true },
        BridgeSnapshotBundle
    )
    .unwrap();
    assert!(observe(&bridge).await.presentation_unloaded);
    let unloaded = ask!(
        &bridge,
        GetNativeVideoWallpapers,
        Vec<BridgeNativeVideoWallpaper>
    )
    .unwrap();
    assert!(unloaded.is_empty());
    finish(bridge).await;
}
