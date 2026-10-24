//! Two identical monitors, told apart only by UUID and serial, keep their own
//! wallpapers while macOS renumbers displays across reboots and reconnects.
//! The setup reproduces issue #33: a built-in display, a 32" monitor and two
//! 27" monitors of the same vendor and model.

use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry};

use crate::{
    WallpaperBridge,
    api::BridgeBuilder,
    config::{
        AppConfig, ConfigStore, MonitorCfg, MonitorSettingsCfg, SerializedSelector, WallpaperConfig,
    },
    engine::{ActivationInputs, FakeEngineFacade},
    paths::BridgePaths,
};

const BUILT_IN: &str = "37D8832A";
const TOP: &str = "50D3A07B";
const LEFT: &str = "2CD33828";
const RIGHT: &str = "541250DC";
const WALLPAPERS: [&str; 5] = ["100", "200", "300", "400", "500"];

fn identity(uuid: &str, unit_number: Option<u32>, name: &str) -> DisplayIdentity {
    let (vendor_id, model_id, serial_number) = match uuid {
        BUILT_IN => (1552, 41054, None),
        TOP => (16652, 49983, Some(1)),
        LEFT => (16652, 50182, Some(2)),
        RIGHT => (16652, 50182, Some(3)),
        _ => unreachable!("unknown test display {uuid}"),
    };
    DisplayIdentity {
        uuid: Some(uuid.to_string()),
        vendor_id: Some(vendor_id),
        model_id: Some(model_id),
        serial_number,
        unit_number,
        name: Some(name.to_string()),
    }
}

fn display(display_id: u32, identity: DisplayIdentity) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 3840, 2160, 2.0),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

/// The displays as logged in the report: the left 27" is display 4 with unit
/// number 3, the right one display 5 with unit number 4.
fn reported_displays() -> Vec<DisplaySnapshotEntry> {
    vec![
        display(1, identity(BUILT_IN, None, "Built-in Retina Display")),
        display(2, identity(TOP, Some(1), "32E1N1800LA")),
        display(4, identity(LEFT, Some(3), "27M2N3200NF (1)")),
        display(5, identity(RIGHT, Some(4), "27M2N3200NF (2)")),
    ]
}

/// The next boot: macOS swaps the identical monitors' display ids, unit
/// numbers and name suffixes, and renumbers the 32".
fn renumbered_displays() -> Vec<DisplaySnapshotEntry> {
    vec![
        display(1, identity(BUILT_IN, None, "Built-in Retina Display")),
        display(3, identity(TOP, Some(2), "32E1N1800LA")),
        display(5, identity(LEFT, Some(4), "27M2N3200NF (2)")),
        display(4, identity(RIGHT, Some(3), "27M2N3200NF (1)")),
    ]
}

fn selector(identity: DisplayIdentity) -> SerializedSelector {
    SerializedSelector::from_selector(&DisplaySelector::Identity(identity))
}

fn monitor(selector: SerializedSelector, wallpaper: &str) -> MonitorCfg {
    MonitorCfg {
        selector,
        wallpaper: Some(wallpaper.to_string()),
        ..MonitorCfg::default()
    }
}

/// The reported `config.toml`: each external monitor has a block left from an
/// earlier session, when it had another unit number, ahead of its current
/// one. The right 27"'s stale block carries unit number 3, which now belongs
/// to the left 27".
fn reported_config() -> AppConfig {
    AppConfig {
        monitors: vec![
            monitor(SerializedSelector::Primary, "100"),
            monitor(selector(identity(RIGHT, Some(3), "27M2N3200NF (1)")), "400"),
            monitor(selector(identity(TOP, Some(4), "32E1N1800LA")), "200"),
            monitor(selector(identity(LEFT, Some(2), "27M2N3200NF (1)")), "300"),
            monitor(selector(identity(TOP, Some(1), "32E1N1800LA")), "100"),
            monitor(selector(identity(LEFT, Some(3), "27M2N3200NF (1)")), "300"),
            monitor(selector(identity(RIGHT, Some(4), "27M2N3200NF (2)")), "400"),
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

fn identity_uuids(selectors: impl Iterator<Item = SerializedSelector>) -> Vec<String> {
    selectors
        .filter_map(|selector| match selector {
            SerializedSelector::Identity { uuid, .. } => uuid,
            _ => None,
        })
        .collect()
}

fn assert_one_block_per_display(config: &AppConfig) {
    let mut uuids = identity_uuids(
        config
            .monitors
            .iter()
            .map(|monitor| monitor.selector.clone()),
    );
    let count = uuids.len();
    uuids.sort();
    uuids.dedup();
    assert_eq!(
        uuids.len(),
        count,
        "duplicate [[monitors]] blocks: {:#?}",
        config.monitors
    );
}

#[test]
fn a_stale_block_for_one_identical_monitor_never_lands_on_the_other() {
    // Before any cleanup, the right 27"'s stale unit-3 block comes first and
    // used to match the left 27" by vendor, model and unit number.
    assert_eq!(
        wallpaper_by_display(&reported_config(), &reported_displays()),
        expected(&[(1, "100"), (2, "200"), (4, "300"), (5, "400")])
    );
}

#[test]
fn display_sync_keeps_one_block_per_display_under_its_current_selector() {
    let displays = reported_displays();
    let mut config = reported_config();
    config.monitor_settings = vec![
        MonitorSettingsCfg {
            selector: selector(identity(LEFT, Some(2), "27M2N3200NF (1)")),
            volume: 0.2,
            ..MonitorSettingsCfg::default()
        },
        MonitorSettingsCfg {
            selector: selector(displays[2].identity.clone()),
            volume: 0.7,
            ..MonitorSettingsCfg::default()
        },
    ];
    assert!(config.sync_known_monitors(&displays));

    let current = |index: usize| selector(displays[index].identity.clone());
    assert_eq!(
        config.monitors,
        vec![
            monitor(SerializedSelector::Primary, "100"),
            monitor(current(3), "400"),
            monitor(current(1), "200"),
            monitor(current(2), "300"),
        ],
        "each display keeps its first block, the one that was on screen"
    );
    // The settings panel showed the entry under the current selector.
    assert_eq!(config.monitor_settings.len(), 1);
    assert_eq!(config.monitor_settings[0].selector, current(2));
    assert!((config.monitor_settings[0].volume - 0.7).abs() <= f32::EPSILON);
    assert!(
        !config.sync_known_monitors(&displays),
        "a second sync changes nothing"
    );

    let mut mirrored = reported_config();
    mirrored.monitors[2].mode = "mirror".to_string();
    mirrored.monitors[2].mirror_target = Some(selector(identity(LEFT, Some(2), "27M2N3200NF (1)")));
    mirrored.sync_known_monitors(&displays);
    assert_eq!(mirrored.monitors[2].selector, current(1));
    assert_eq!(mirrored.monitors[2].mirror_target, Some(current(2)));
}

#[test]
fn a_disconnected_display_keeps_only_its_first_block() {
    let mut config = reported_config();
    let built_in_only = &reported_displays()[..1];

    config.sync_known_monitors(built_in_only);

    assert_one_block_per_display(&config);
    let wallpapers = config
        .monitors
        .iter()
        .filter_map(|monitor| monitor.wallpaper.as_deref())
        .collect::<Vec<_>>();
    assert_eq!(wallpapers, ["100", "400", "200", "300"]);
}

async fn row_id(bridge: &WallpaperBridge, uuid: &str) -> String {
    bridge
        .settings_snapshot()
        .await
        .unwrap()
        .displays
        .into_iter()
        .find(|row| row.display_id.contains(uuid))
        .unwrap_or_else(|| panic!("missing settings row for {uuid}"))
        .display_id
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
async fn identical_monitors_keep_their_own_wallpapers_across_renumbering() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store.save_app_config(&reported_config()).unwrap();
    for id in WALLPAPERS {
        store
            .save_wallpaper(&WallpaperConfig::new_for(id, "scene"))
            .unwrap();
    }
    let engine = FakeEngineFacade::default();
    engine.set_snapshot_after_refresh(reported_displays());
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge.bootstrap().await.unwrap();

    assert_eq!(
        latest_wallpapers(&engine),
        expected(&[(1, "100"), (2, "200"), (4, "300"), (5, "400")])
    );
    assert_one_block_per_display(&store.load().unwrap().config);

    // Choosing a wallpaper for the left 27" from the panel reaches it.
    bridge
        .inject_scene_wallpaper_config_for_test("500", "New")
        .await;
    let left_id = row_id(&bridge, LEFT).await;
    bridge
        .set_display_config_enabled("500".to_string(), left_id.clone(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("500".to_string(), true)
        .await
        .unwrap();
    assert_eq!(
        latest_wallpapers(&engine),
        expected(&[(1, "100"), (2, "200"), (4, "500"), (5, "400")])
    );

    engine.set_snapshot_after_refresh(renumbered_displays());
    bridge.refresh_displays().await.unwrap();

    assert_eq!(
        latest_wallpapers(&engine),
        expected(&[(1, "100"), (3, "200"), (5, "500"), (4, "400")])
    );
    let saved = store.load().unwrap().config;
    assert_one_block_per_display(&saved);
    assert!(
        saved.monitors.iter().any(|monitor| monitor.selector
            == selector(renumbered_displays()[2].identity.clone())
            && monitor.wallpaper.as_deref() == Some("500")),
        "the left 27\"'s block follows its new unit number: {:#?}",
        saved.monitors
    );

    // A panel id from before the renumbering still edits the left 27".
    bridge.set_display_enabled(left_id, false).await.unwrap();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        latest_wallpapers(&engine),
        expected(&[(1, "100"), (3, "200"), (4, "400")])
    );
    assert_one_block_per_display(&store.load().unwrap().config);
}
