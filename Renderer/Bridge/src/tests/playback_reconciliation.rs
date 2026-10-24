//! After a reconcile, every live scene's pause follows the playback policy in
//! force: a pause the engine kept across a rebuild never holds a visible
//! display still, and a display that should pause is not resumed.
use std::sync::Arc;

use wallpaper_core::DisplaySnapshotEntry;

use super::{
    fixture_values::identified,
    live_scene_fixture::{WAIT, bridge, eventually, foreign_scene, installed, live, showing},
};
use crate::{
    api::{BridgePlaybackState, BridgeScalingMode},
    config::{AppConfig, SerializedSelector},
    display::DisplaySnapshotExt,
    engine::{EngineFacade, FakeEngineFacade},
};

const SCENIC: &str = "scenic";

fn main_display() -> DisplaySnapshotEntry {
    identified("main-panel", 1, 60)
}

fn side_display() -> DisplaySnapshotEntry {
    identified("side-panel", 2, 60)
}

/// Both displays show the scenic wallpaper on their own.
fn two_displays_showing_scenic() -> AppConfig {
    let mut app = AppConfig::default();
    app.monitors = vec![
        showing(SerializedSelector::Primary, SCENIC),
        showing(side_display().connected_selector(), SCENIC),
    ];
    app
}

/// Live scenes that still show a wallpaper no configuration asks for, so the
/// next reconcile has something to do.
fn retained(paused: [bool; 2]) -> Vec<DisplaySnapshotEntry> {
    [main_display(), side_display()]
        .into_iter()
        .zip(paused)
        .enumerate()
        .map(|(index, (display, paused))| {
            let scene = foreign_scene(&display, "previous");
            live(display, index as u64 + 1, &scene, paused)
        })
        .collect()
}

fn live_pause(engine: &FakeEngineFacade, display_id: u32) -> bool {
    engine
        .display_snapshot()
        .iter()
        .find(|entry| entry.desc.display_id == display_id)
        .expect("display listed")
        .paused
}

#[tokio::test(flavor = "multi_thread")]
async fn applying_a_wallpaper_resumes_a_scene_whose_pause_outlived_the_rebuild() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![retained([true, false])[0].clone()]);
    let fixture = bridge(
        &engine,
        installed(AppConfig::default(), vec![(SCENIC, None)]),
        false,
    );
    fixture
        .bridge
        .set_display_config_enabled(SCENIC.into(), "primary".into(), true)
        .await
        .expect("enable on the main display");

    fixture
        .bridge
        .apply_wallpaper_options(SCENIC.into(), true)
        .await
        .expect("apply");

    assert_eq!(
        engine.reconcile_call_count(),
        1,
        "the apply reconciled the engine"
    );
    assert_eq!(engine.display_paused_calls(), vec![(1, false)]);
    assert!(!live_pause(&engine, 1));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unchanged_configuration_still_corrects_a_retained_pause() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![main_display()]);
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, SCENIC)];
    let fixture = bridge(&engine, installed(app, vec![(SCENIC, None)]), false);
    fixture
        .bridge
        .refresh_displays()
        .await
        .expect("first refresh");
    let opened = engine.calls().pop().expect("a reconcile").remove(0);
    // The engine now runs exactly what the configuration asks for, but kept
    // the scene paused from before.
    engine.set_snapshot(vec![live(main_display(), 1, &opened, true)]);

    fixture
        .bridge
        .refresh_displays()
        .await
        .expect("second refresh");

    assert_eq!(
        engine.reconcile_call_count(),
        1,
        "nothing needed rebuilding"
    );
    assert_eq!(engine.display_paused_calls(), vec![(1, false)]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_covered_display_stays_paused_while_the_visible_one_resumes() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(retained([true, true]));
    let mut state = installed(two_displays_showing_scenic(), vec![(SCENIC, None)]);
    state.suspended_displays.insert(2);
    let fixture = bridge(&engine, state, false);

    fixture.bridge.refresh_displays().await.expect("refresh");

    assert_eq!(engine.reconcile_call_count(), 1);
    assert_eq!(engine.display_paused_calls(), vec![(1, false)]);
    assert!(!live_pause(&engine, 1));
    assert!(live_pause(&engine, 2), "the covered display stays paused");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_pause_is_not_undone_by_a_reconcile() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(retained([true, true]));
    let mut state = installed(two_displays_showing_scenic(), vec![(SCENIC, None)]);
    state.playback_state = BridgePlaybackState::Paused;
    let fixture = bridge(&engine, state, false);

    fixture.bridge.refresh_displays().await.expect("refresh");

    assert_eq!(engine.reconcile_call_count(), 1);
    assert!(engine.display_paused_calls().is_empty());
    assert!(live_pause(&engine, 1) && live_pause(&engine, 2));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_display_that_should_pause_is_paused_and_matching_ones_are_left_alone() {
    let engine = FakeEngineFacade::default();
    // The side display is covered but its rebuilt scene runs.
    engine.set_snapshot(retained([false, false]));
    let mut state = installed(two_displays_showing_scenic(), vec![(SCENIC, None)]);
    state.suspended_displays.insert(2);
    let fixture = bridge(&engine, state, false);

    fixture.bridge.refresh_displays().await.expect("refresh");

    assert_eq!(engine.display_paused_calls(), vec![(2, true)]);
}

#[tokio::test(flavor = "multi_thread")]
async fn scenes_that_already_follow_the_policy_get_no_command() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(retained([false, false]));
    let fixture = bridge(
        &engine,
        installed(two_displays_showing_scenic(), vec![(SCENIC, None)]),
        false,
    );

    fixture.bridge.refresh_displays().await.expect("refresh");

    assert_eq!(engine.reconcile_call_count(), 1);
    assert!(engine.display_paused_calls().is_empty());
    assert!(engine.paused_calls().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reconcile_that_was_superseded_does_not_correct_and_its_repair_does() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![retained([true, false])[0].clone()]);
    let fixture = bridge(
        &engine,
        installed(AppConfig::default(), vec![(SCENIC, None)]),
        false,
    );
    let bridge = Arc::new(fixture.bridge);
    bridge
        .set_display_config_enabled(SCENIC.into(), "primary".into(), true)
        .await
        .expect("enable on the main display");

    let first = engine.block_next_reconcile();
    let applying = tokio::spawn({
        let bridge = Arc::clone(&bridge);
        async move { bridge.apply_wallpaper_options(SCENIC.into(), true).await }
    });
    assert!(
        first.wait_until_blocked(WAIT),
        "the apply reached the engine"
    );
    // An unrelated edit while the apply is in flight makes it stale.
    bridge
        .set_scaling_mode(SCENIC.into(), "primary".into(), BridgeScalingMode::Stretch)
        .await
        .expect("edit while applying");
    let repair = engine.block_next_reconcile();
    first.release();
    applying.await.expect("apply task").expect("apply");
    assert!(
        repair.wait_until_blocked(WAIT),
        "the stale apply asked for a repair"
    );

    assert!(
        engine.display_paused_calls().is_empty(),
        "a stale reconcile corrects nothing"
    );

    repair.release();
    assert!(
        eventually(|| !engine.display_paused_calls().is_empty()).await,
        "the repair corrects the retained pause"
    );
    assert_eq!(engine.display_paused_calls(), vec![(1, false)]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_policy_change_during_a_reconcile_wins_over_the_pause_it_started_with() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![retained([false, false])[0].clone()]);
    let fixture = bridge(
        &engine,
        installed(AppConfig::default(), vec![(SCENIC, None)]),
        false,
    );
    let bridge = Arc::new(fixture.bridge);
    bridge
        .set_display_config_enabled(SCENIC.into(), "primary".into(), true)
        .await
        .expect("enable on the main display");

    let first = engine.block_next_reconcile();
    let applying = tokio::spawn({
        let bridge = Arc::clone(&bridge);
        async move { bridge.apply_wallpaper_options(SCENIC.into(), true).await }
    });
    assert!(
        first.wait_until_blocked(WAIT),
        "the apply reached the engine"
    );
    bridge.pause_all().await.expect("pause while applying");
    assert!(live_pause(&engine, 1));
    // The renderer the in-flight reconcile builds starts from the descriptor
    // made before the pause, which said play.
    engine.set_snapshot(vec![retained([false, false])[0].clone()]);
    first.release();
    applying.await.expect("apply task").expect("apply");

    assert!(
        eventually(|| live_pause(&engine, 1)).await,
        "the newer policy (paused) is what the display ends with"
    );
    assert_eq!(engine.display_paused_calls(), vec![(1, true)]);
}
