//! "Fit with blurred backdrop" (`MatchBlurred`) is carried, saved, loaded and
//! reported like every other scaling mode.
use wallpaper_core::{DisplaySnapshotEntry, project::ScalingMode};

use super::{
    fixture_values::identified,
    live_scene_fixture::{bridge, foreign_scene, installed, live, showing},
};
use crate::{
    api::BridgeScalingMode,
    config::{
        AppConfig, ConfigStore, MonitorCfg, MonitorRender, MonitorSettingsCfg, SerializedSelector,
    },
    display::DisplaySnapshotExt,
    engine::FakeEngineFacade,
};

const DRIFT: &str = "drift";

fn main_display() -> DisplaySnapshotEntry {
    identified("blur-main", 1, 60)
}

fn mirror_display() -> DisplaySnapshotEntry {
    identified("blur-mirror", 6, 60)
}

#[test]
fn the_blurred_fit_converts_to_the_engine_mode_and_back() {
    assert_eq!(
        ScalingMode::from(BridgeScalingMode::MatchBlurred),
        ScalingMode::FitBlurred
    );
    assert_eq!(
        BridgeScalingMode::from(ScalingMode::FitBlurred),
        BridgeScalingMode::MatchBlurred
    );
    for (bridge, core) in [
        (BridgeScalingMode::None, ScalingMode::None),
        (BridgeScalingMode::Stretch, ScalingMode::Stretch),
        (BridgeScalingMode::Match, ScalingMode::Fit),
        (BridgeScalingMode::Fill, ScalingMode::Fill),
    ] {
        assert_eq!(ScalingMode::from(bridge), core);
        assert_eq!(BridgeScalingMode::from(core), bridge);
    }
}

#[test]
fn a_wallpapers_display_setting_reads_and_writes_fit_blurred() {
    let render: MonitorRender = serde_json::from_value(serde_json::json!({
        "selector": { "kind": "primary" },
        "scaling_mode": "fit_blurred",
        "scaling_factor": 1.0
    }))
    .expect("render setting");
    assert_eq!(render.parse_scaling_mode(), ScalingMode::FitBlurred);
    let written = serde_json::to_value(&render).expect("serialize");
    assert_eq!(written["scaling_mode"], "fit_blurred");

    let unknown = MonitorRender {
        scaling_mode: "cinematic".into(),
        ..MonitorRender::default()
    };
    assert_eq!(
        unknown.parse_scaling_mode(),
        ScalingMode::Fill,
        "unknown values are read as before"
    );
}

#[test]
fn a_displays_monitor_entry_reads_and_writes_fit_blurred() {
    let mut app = AppConfig::default();
    app.monitor_settings.push(MonitorSettingsCfg {
        selector: SerializedSelector::LiveDisplayId { display_id: 6 },
        scaling_mode: ScalingMode::FitBlurred.to_string(),
        ..MonitorSettingsCfg::default()
    });
    let home = tempfile::tempdir().expect("temporary home");
    let store = ConfigStore::open(home.path());
    store.save_app_config(&app).expect("save");
    let text = std::fs::read_to_string(home.path().join("config.toml")).expect("saved file");
    assert!(text.contains("scaling_mode = \"fit_blurred\""), "{text}");

    let loaded = store.load().expect("load").config;
    assert_eq!(
        loaded.monitor_settings[0].parse_scaling_mode(),
        ScalingMode::FitBlurred
    );
    assert_eq!(loaded, app);
}

#[tokio::test(flavor = "multi_thread")]
async fn setting_the_blurred_fit_for_a_wallpaper_on_a_display_is_applied_saved_and_reported() {
    let engine = FakeEngineFacade::default();
    let scene = foreign_scene(&main_display(), DRIFT);
    engine.set_snapshot(vec![live(main_display(), 3, &scene, false)]);
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, DRIFT)];
    let fixture = bridge(&engine, installed(app, vec![(DRIFT, None)]), true);

    let bundle = fixture
        .bridge
        .set_scaling_mode(
            DRIFT.into(),
            "primary".into(),
            BridgeScalingMode::MatchBlurred,
        )
        .await
        .expect("set scaling mode");

    let row = bundle
        .wallpaper_options
        .display_configurations
        .iter()
        .find(|row| row.display_id == "primary")
        .expect("primary row");
    assert_eq!(row.scaling_mode, BridgeScalingMode::MatchBlurred);
    let options = fixture
        .bridge
        .wallpaper_options_snapshot(DRIFT.into())
        .await
        .expect("options snapshot");
    assert!(
        options
            .display_configurations
            .iter()
            .any(|row| row.display_id == "primary"
                && row.scaling_mode == BridgeScalingMode::MatchBlurred)
    );
    assert!(
        bundle
            .monitor_information
            .rows
            .iter()
            .any(|row| row.scaling_mode == "MatchBlurred"),
        "{:?}",
        bundle.monitor_information.rows
    );
    assert_eq!(
        engine.scaling_mode_calls(),
        vec![(
            wallpaper_core::project::SceneHandle::new(3),
            ScalingMode::FitBlurred
        )]
    );

    let store = ConfigStore::open(fixture.home.path().join("support"));
    let saved = store.load_wallpaper(DRIFT).expect("saved wallpaper");
    let render = saved
        .monitors
        .iter()
        .find(|render| render.selector == SerializedSelector::Primary)
        .expect("primary render setting");
    assert_eq!(render.scaling_mode, "fit_blurred");
    assert_eq!(render.parse_scaling_mode(), ScalingMode::FitBlurred);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_mirror_display_takes_the_blurred_fit_and_reports_it() {
    let engine = FakeEngineFacade::default();
    let scene = foreign_scene(&main_display(), DRIFT);
    let mirrored = foreign_scene(&mirror_display(), DRIFT);
    engine.set_snapshot(vec![
        live(main_display(), 3, &scene, false),
        live(mirror_display(), 4, &mirrored, false),
    ]);
    let mirror_selector = mirror_display().connected_selector();
    let mut app = AppConfig::default();
    app.monitors = vec![
        showing(SerializedSelector::Primary, DRIFT),
        MonitorCfg {
            selector: mirror_selector.clone(),
            mode: "mirror".into(),
            mirror_target: Some(SerializedSelector::Primary),
            ..MonitorCfg::default()
        },
    ];
    let fixture = bridge(&engine, installed(app, vec![(DRIFT, None)]), true);

    let bundle = fixture
        .bridge
        .set_mirror_scaling_mode("6".into(), BridgeScalingMode::MatchBlurred)
        .await
        .expect("set mirror scaling mode");

    let row = bundle
        .settings
        .displays
        .iter()
        .find(|row| row.display_id == mirror_selector.id())
        .expect("mirror display row");
    assert_eq!(row.scaling_mode, BridgeScalingMode::MatchBlurred);
    let store = ConfigStore::open(fixture.home.path().join("support"));
    let saved = store.load().expect("saved configuration").config;
    let settings = saved
        .monitor_settings
        .iter()
        .find(|settings| settings.selector == mirror_selector)
        .expect("mirror settings");
    assert_eq!(settings.scaling_mode, "fit_blurred");
    assert!(engine.scaling_mode_calls().contains(&(
        wallpaper_core::project::SceneHandle::new(4),
        ScalingMode::FitBlurred
    )));
}
