//! The `primary` block follows the role, whichever display macOS makes the
//! main one, while each display keeps its own wallpaper. The setup reproduces
//! issue #62: a built-in display with a wallpaper and an external monitor the
//! user switched off, which macOS makes the main display on a wake.

use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry};

use crate::{
    api::BridgeBuilder,
    config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::{ActivationInputs, FakeEngineFacade},
    paths::BridgePaths,
};

const WALLPAPERS: [&str; 2] = ["3051995716", "200"];

fn built_in_identity() -> DisplayIdentity {
    DisplayIdentity {
        uuid: Some("37D8832A-2D66-02CA-B9F7-8F30A301B230".to_string()),
        vendor_id: Some(1552),
        model_id: Some(41042),
        serial_number: Some(4_251_086_178),
        unit_number: None,
        name: None,
    }
}

fn external_identity() -> DisplayIdentity {
    DisplayIdentity {
        uuid: Some("1B943868-9419-4B27-8934-A4956AB353F7".to_string()),
        vendor_id: Some(8547),
        model_id: Some(10001),
        serial_number: None,
        unit_number: Some(2),
        name: None,
    }
}

fn display(display_id: u32, identity: DisplayIdentity) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 1.0),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn built_in() -> DisplaySnapshotEntry {
    display(1, built_in_identity())
}

fn external() -> DisplaySnapshotEntry {
    display(3, external_identity())
}

fn selector(identity: DisplayIdentity) -> SerializedSelector {
    SerializedSelector::from_selector(&DisplaySelector::Identity(identity))
}

fn block<'a>(config: &'a AppConfig, selector: &SerializedSelector) -> &'a MonitorCfg {
    config
        .monitors
        .iter()
        .find(|monitor| &monitor.selector == selector)
        .unwrap_or_else(|| panic!("no block for {selector:?}: {:#?}", config.monitors))
}

/// The reported `config.toml`: the wallpaper on the built-in display, which
/// was the main one, and the external monitor switched off.
fn reported_config() -> AppConfig {
    AppConfig {
        monitors: vec![
            MonitorCfg {
                selector: SerializedSelector::Primary,
                wallpaper: Some(WALLPAPERS[0].to_string()),
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: selector(external_identity()),
                enabled: false,
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: selector(built_in_identity()),
                wallpaper: Some(WALLPAPERS[0].to_string()),
                ..MonitorCfg::default()
            },
        ],
        ..AppConfig::default()
    }
}

fn wallpaper_by_display(
    config: &AppConfig,
    displays: &[DisplaySnapshotEntry],
) -> BTreeMap<u32, String> {
    let wallpapers = WALLPAPERS
        .into_iter()
        .map(|id| (id.to_string(), WallpaperConfig::new_for(id, "scene")))
        .collect::<BTreeMap<_, _>>();
    let paths = BridgePaths::for_home("/Users/example");
    ActivationInputs {
        app_config: config,
        wallpapers: &wallpapers,
        library: None,
        displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap()
    .into_iter()
    .map(|scene| (scene.display.display_id, wallpaper_in(&scene.scene_path)))
    .collect()
}

fn wallpaper_in(scene_path: &str) -> String {
    WALLPAPERS
        .into_iter()
        .find(|id| scene_path.contains(&format!("/{id}/")))
        .unwrap_or_else(|| panic!("unexpected scene {scene_path}"))
        .to_string()
}

fn expected(pairs: &[(u32, &str)]) -> BTreeMap<u32, String> {
    pairs
        .iter()
        .map(|(display_id, wallpaper)| (*display_id, (*wallpaper).to_string()))
        .collect()
}

fn latest_wallpapers(engine: &FakeEngineFacade) -> BTreeMap<u32, String> {
    engine
        .calls()
        .last()
        .expect("reconcile call")
        .iter()
        .map(|scene| (scene.display.display_id, wallpaper_in(&scene.scene_path)))
        .collect()
}

#[tokio::test]
async fn a_new_main_display_keeps_its_own_assignment_across_wake() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store.save_app_config(&reported_config()).unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for(WALLPAPERS[0], "scene"))
        .unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot_after_refresh(vec![built_in(), external()]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge.bootstrap().await.unwrap();
    assert_eq!(latest_wallpapers(&engine), expected(&[(1, WALLPAPERS[0])]));

    // On wake macOS makes the external monitor the main display.
    engine.set_snapshot_after_refresh(vec![external(), built_in()]);
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        latest_wallpapers(&engine),
        expected(&[(1, WALLPAPERS[0])]),
        "the wallpaper stays on the built-in display and the switched-off monitor stays empty"
    );
    let saved = store.load().unwrap().config;
    assert_eq!(block(&saved, &SerializedSelector::Primary).wallpaper, None);
    assert!(!block(&saved, &selector(external_identity())).enabled);
    assert_eq!(saved.primary_display, Some(selector(external_identity())));

    // A later wake that keeps the external monitor main changes nothing.
    bridge.refresh_displays().await.unwrap();
    assert_eq!(latest_wallpapers(&engine), expected(&[(1, WALLPAPERS[0])]));

    // The built-in display becoming main again takes its wallpaper back.
    engine.set_snapshot_after_refresh(vec![built_in(), external()]);
    bridge.refresh_displays().await.unwrap();
    assert_eq!(latest_wallpapers(&engine), expected(&[(1, WALLPAPERS[0])]));
    let saved = store.load().unwrap().config;
    assert_eq!(
        block(&saved, &SerializedSelector::Primary).wallpaper.as_deref(),
        Some(WALLPAPERS[0])
    );
    assert!(!block(&saved, &selector(external_identity())).enabled);
}

#[test]
fn a_wallpaper_chosen_for_the_main_display_stays_on_it_when_the_role_moves() {
    let mut config = reported_config();
    config.sync_known_monitors(&[built_in(), external()]);
    // An edit through the `primary` block that its display's own block has
    // not seen yet.
    config.monitors[0].wallpaper = Some(WALLPAPERS[1].to_string());

    let displays = [external(), built_in()];
    config.sync_known_monitors(&displays);

    assert_eq!(
        wallpaper_by_display(&config, &displays),
        expected(&[(1, WALLPAPERS[1])])
    );
}

#[test]
fn a_main_display_without_a_block_of_its_own_shows_the_roles_wallpaper() {
    let mut config = AppConfig {
        monitors: vec![MonitorCfg {
            selector: SerializedSelector::Primary,
            wallpaper: Some(WALLPAPERS[0].to_string()),
            ..MonitorCfg::default()
        }],
        ..AppConfig::default()
    };
    config.sync_known_monitors(&[built_in()]);

    // The lid closes with a monitor attached that was never configured.
    let lid_closed = [external()];
    config.sync_known_monitors(&lid_closed);
    assert_eq!(
        wallpaper_by_display(&config, &lid_closed),
        expected(&[(3, WALLPAPERS[0])])
    );

    // Opening the lid gives the built-in display its wallpaper back, and the
    // monitor keeps the one it showed.
    let lid_open = [built_in(), external()];
    config.sync_known_monitors(&lid_open);
    assert_eq!(
        wallpaper_by_display(&config, &lid_open),
        expected(&[(1, WALLPAPERS[0]), (3, WALLPAPERS[0])])
    );
}
