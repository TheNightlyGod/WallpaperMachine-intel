//! Two display changes overlap and the engine then fails every reconcile: both
//! callers hear about it, settings show what was last committed, and the
//! renderer is asked once more to be put right.

use std::{
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

use tempfile::tempdir;

use super::bridge_waits::wait_for_at_least;
use super::engine_release::EngineRelease;
use super::fixture_observations::{expect_enabled, settings_key, settings_row};
use super::fixture_values::identified;
use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig};
use crate::engine::FakeEngineFacade;
use crate::paths::BridgePaths;
use crate::{BridgeDisplayMode, WallpaperBridge};

const BOUND: Duration = Duration::from_secs(2);

/// Runs one bridge call on its own thread with its own runtime, so the call can
/// stay parked inside the engine while the test goes on.
fn call_on_thread<T: Send + 'static>(
    bridge: &Arc<WallpaperBridge>,
    call: impl FnOnce(Arc<WallpaperBridge>) -> std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send>>
        + Send
        + 'static,
) -> (thread::JoinHandle<()>, mpsc::Receiver<T>) {
    let (sender, receiver) = mpsc::channel();
    let bridge = Arc::clone(bridge);
    let handle = thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new().expect("a runtime for the call");
        let _ = sender.send(runtime.block_on(call(bridge)));
    });
    (handle, receiver)
}

/// Two overlapping failures, with the parked reconciles released in the given
/// order. Both must fail and the end state must be the committed one.
async fn overlapping_failures_end_in_the_committed_state(release_second_first: bool) {
    let root = tempdir().unwrap();
    let home = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_owned(),
                wallpaper: Some("100".to_owned()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store.save_wallpaper(&WallpaperConfig::new_for("100", "scene")).unwrap();

    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    let displays = vec![identified("primary", 1, 60), identified("secondary", 3, 60)];
    engine.set_snapshot(displays.clone());
    engine.set_snapshot_after_refresh(displays);
    let bridge = Arc::new(
        crate::api::BridgeBuilder::new(engine.clone())
            .with_config_store(store)
            .with_paths(BridgePaths::for_home(home.path()))
            .build()
            .expect("the bridge should build"),
    );
    bridge.bootstrap().await.expect("bootstrap should succeed");
    let calls_before = engine.calls().len();
    let secondary = settings_key(&bridge, "secondary").await;

    let first = engine.block_next_reconcile();
    let second = engine.block_next_reconcile();
    let id = secondary.clone();
    let (first_thread, first_result) = call_on_thread(&bridge, move |bridge| {
        Box::pin(async move { bridge.set_display_enabled(id, false).await })
    });
    assert!(first.wait_until_blocked(BOUND), "the first reconcile never started");
    let id = secondary.clone();
    let (second_thread, second_result) = call_on_thread(&bridge, move |bridge| {
        Box::pin(async move { bridge.set_display_mode(id, BridgeDisplayMode::Mirror).await })
    });
    assert!(second.wait_until_blocked(BOUND), "the second reconcile never started");

    engine.fail_reconcile_with("post-reconcile failure");
    if release_second_first {
        second.release();
        first.release();
    } else {
        first.release();
    }
    let first_outcome = first_result.recv_timeout(BOUND).expect("the first call never answered");
    assert!(first_outcome.is_err(), "the first change reported success: {first_outcome:?}");
    first_thread.join().unwrap();
    if !release_second_first {
        second.release();
    }
    let second_outcome = second_result.recv_timeout(BOUND).expect("the second call never answered");
    assert!(second_outcome.is_err(), "the second change reported success: {second_outcome:?}");
    second_thread.join().unwrap();

    assert!(
        wait_for_at_least(&engine, calls_before + 3, BOUND).await,
        "no repair reconcile followed the failures"
    );
    expect_enabled(&bridge, &secondary, true).await;
    assert_eq!(settings_row(&bridge, &secondary).await.mode, BridgeDisplayMode::Standalone);
    let attempts = engine.calls().len() - calls_before;
    assert!(
        (3..=4).contains(&attempts),
        "expected two failed changes and one or two repairs, saw {attempts} reconciles"
    );
}

#[tokio::test]
async fn a_failed_display_change_rolls_back_and_asks_for_one_repair() {
    overlapping_failures_end_in_the_committed_state(false).await;
}

#[tokio::test]
async fn the_outcome_does_not_depend_on_which_parked_reconcile_is_released_first() {
    overlapping_failures_end_in_the_committed_state(true).await;
}
