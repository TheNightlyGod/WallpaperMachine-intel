//! Turning audio response on waits for the engine to start capturing, but the
//! bridge stays responsive meanwhile.

use std::{
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

use super::engine_release::EngineRelease;
use super::fixture_values::{anonymous, direct_entry};
use crate::actor::state::BridgeActorState;
use crate::engine::FakeEngineFacade;

const BOUND: Duration = Duration::from_secs(2);

#[tokio::test]
async fn selecting_another_wallpaper_works_while_capture_is_starting() {
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![anonymous(7, 1.0, 75, false)]);
    let bridge = Arc::new(
        crate::api::BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .expect("the bridge should build"),
    );
    bridge.inject_scene_wallpaper_config_for_test("100", "Scene").await;
    bridge.inject_scene_wallpaper_config_for_test("200", "Other").await;
    bridge.set_audio_response_enabled("100".to_owned(), false).await.unwrap();
    bridge.set_display_config_enabled("100".to_owned(), "7".to_owned(), true).await.unwrap();
    let applied = engine.wait_for_next_reconcile();
    bridge.apply_wallpaper_options("100".to_owned(), true).await.unwrap();
    assert!(applied.wait(BOUND), "applying never reconciled");

    // The engine now runs wallpaper 100 on handle 42.
    engine.set_snapshot(vec![direct_entry(anonymous(7, 1.0, 75, false), 42, "100")]);
    let capture = engine.block_next_audio_capture();
    let (sender, receiver) = mpsc::channel();
    let toggler = Arc::clone(&bridge);
    let worker = thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let _ = sender.send(runtime.block_on(toggler.set_audio_response_enabled("100".to_owned(), true)));
    });
    assert!(capture.wait_until_blocked(BOUND), "capture never started");
    assert!(
        matches!(receiver.try_recv(), Err(mpsc::TryRecvError::Empty)),
        "the toggle answered before capture started"
    );

    let selected = tokio::time::timeout(BOUND, bridge.select_wallpaper("200".to_owned()))
        .await
        .expect("selecting hung while capture was starting");
    selected.expect("selecting should succeed");
    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(app.selected_wallpaper_id.as_deref(), Some("200"));

    capture.release();
    let toggled = receiver.recv_timeout(BOUND).expect("the toggle never completed");
    assert!(toggled.is_ok(), "the toggle failed: {toggled:?}");
    worker.join().unwrap();
}
