//! The user's own Play/Pause outlives a relaunch: it is saved as `general.paused`
//! and comes back once the next session's first frame is up, before the battery
//! policy, while power rules never write it.
use super::live_scene_fixture::{bridge, installed, showing};
use crate::{
    api::BridgePlaybackState,
    config::{AppConfig, BatteryModeCfg, ConfigStore, SerializedSelector},
    engine::FakeEngineFacade,
    power::PowerSource,
};

const SCENIC: &str = "scenic";

fn showing_scenic(paused: bool) -> AppConfig {
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, SCENIC)];
    app.general.paused = paused;
    app
}

fn saved_pause(home: &tempfile::TempDir) -> bool {
    ConfigStore::open(home.path().join("support"))
        .load()
        .expect("load the saved configuration")
        .config
        .general
        .paused
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_pause_and_play_are_saved_for_the_next_launch() {
    let engine = FakeEngineFacade::default();
    let fixture = bridge(&engine, installed(showing_scenic(false), vec![(SCENIC, None)]), true);

    fixture.bridge.pause_all().await.expect("pause");
    assert!(saved_pause(&fixture.home));
    fixture.bridge.play_all().await.expect("play");
    assert!(!saved_pause(&fixture.home));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pause_that_could_not_be_saved_is_saved_when_chosen_again() {
    let engine = FakeEngineFacade::default();
    let fixture = bridge(&engine, installed(showing_scenic(false), vec![(SCENIC, None)]), true);
    // A directory where the configuration file goes makes the save fail.
    let config = fixture.home.path().join("support").join("config.toml");
    std::fs::create_dir_all(&config).expect("block the configuration file");

    fixture.bridge.pause_all().await.expect("pause");
    std::fs::remove_dir_all(&config).expect("unblock the configuration file");
    fixture.bridge.pause_all().await.expect("pause again");
    assert!(saved_pause(&fixture.home));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pause_on_battery_is_not_saved_as_the_users() {
    let engine = FakeEngineFacade::default();
    let mut app = showing_scenic(false);
    app.power.on_battery = BatteryModeCfg::Pause;
    let fixture = bridge(&engine, installed(app, vec![(SCENIC, None)]), true);
    fixture.bridge.pause_all().await.expect("pause");
    fixture.bridge.play_all().await.expect("play");

    fixture.bridge.initial_frame_ready_for_test().await;
    fixture.bridge.set_power_source_for_test(PowerSource::Battery).await;

    let snapshot = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(snapshot.playback_state, BridgePlaybackState::Paused, "the battery rule paused");
    assert!(!saved_pause(&fixture.home), "but that is not the user's choice to restore");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_saved_pause_returns_once_the_first_frame_is_up() {
    let engine = FakeEngineFacade::default();
    let fixture = bridge(&engine, installed(showing_scenic(true), vec![(SCENIC, None)]), true);

    let before = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(
        before.playback_state,
        BridgePlaybackState::Playing,
        "the wallpaper draws its first frame before it is held still"
    );
    fixture.bridge.initial_frame_ready_for_test().await;
    let after = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(after.playback_state, BridgePlaybackState::Paused);
    assert_eq!(engine.paused_calls().last(), Some(&true));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_saved_pause_that_fails_is_tried_again_at_the_next_ready_report() {
    let engine = FakeEngineFacade::default();
    let fixture = bridge(&engine, installed(showing_scenic(true), vec![(SCENIC, None)]), true);

    engine.fail_next_pause();
    fixture.bridge.initial_frame_ready_for_test().await;
    let failed = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(failed.playback_state, BridgePlaybackState::Playing, "the failed pause is rolled back");

    fixture.bridge.initial_frame_ready_for_test().await;
    let after = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(after.playback_state, BridgePlaybackState::Paused);
    assert_eq!(engine.paused_calls().last(), Some(&true));
}

#[tokio::test(flavor = "multi_thread")]
async fn playing_before_the_first_frame_cancels_the_saved_pause() {
    let engine = FakeEngineFacade::default();
    let fixture = bridge(&engine, installed(showing_scenic(true), vec![(SCENIC, None)]), true);

    fixture.bridge.play_all().await.expect("play");
    fixture.bridge.initial_frame_ready_for_test().await;

    let snapshot = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(snapshot.playback_state, BridgePlaybackState::Playing);
    assert!(!saved_pause(&fixture.home));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_restored_pause_on_battery_is_still_the_users_when_power_returns() {
    let engine = FakeEngineFacade::default();
    let mut app = showing_scenic(true);
    app.power.on_battery = BatteryModeCfg::Pause;
    let fixture = bridge(&engine, installed(app, vec![(SCENIC, None)]), true);
    fixture.bridge.set_initial_power_source_for_test(PowerSource::Battery).await;

    fixture.bridge.initial_frame_ready_for_test().await;
    fixture.bridge.set_power_source_for_test(PowerSource::External).await;

    let snapshot = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(
        snapshot.playback_state,
        BridgePlaybackState::Paused,
        "external power resumes only a pause the battery rule made"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_saved_pause_with_nothing_assigned_does_not_hold_a_later_wallpaper() {
    let engine = FakeEngineFacade::default();
    let mut app = AppConfig::default();
    app.general.paused = true;
    let fixture = bridge(&engine, installed(app, vec![(SCENIC, None)]), true);

    fixture.bridge.initial_frame_ready_for_test().await;

    let snapshot = fixture.bridge.app_snapshot().await.expect("snapshot");
    assert_eq!(snapshot.playback_state, BridgePlaybackState::Playing);
}
