use std::{
    fs,
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{ScalingMode, SceneHandle, SceneTemplate},
};

use crate::{
    BridgeDisplayMode, BridgeErrorKind, BridgePlaybackState, BridgeScalingMode,
    api::BridgeBuilder, config::ConfigStore, engine::FakeEngineFacade,
};

fn assert_f32_close(actual: f32, expected: f32) {
    assert!(
        (actual - expected).abs() <= f32::EPSILON,
        "expected {actual} to be within f32::EPSILON of {expected}"
    );
}

fn assert_f64_close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() <= f64::EPSILON,
        "expected {actual} to be within f64::EPSILON of {expected}"
    );
}

#[tokio::test]
async fn apply_options_clears_dirty_state() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    assert!(
        bridge
            .wallpaper_options_snapshot("100".to_string())
            .await
            .unwrap()
            .dirty
    );

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    assert!(
        !bridge
            .wallpaper_options_snapshot("100".to_string())
            .await
            .unwrap()
            .dirty
    );
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
}

#[tokio::test]
async fn apply_while_globally_paused_preserves_paused_snapshot_and_scene_seed() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge.pause_all().await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    assert_eq!(engine.paused_calls(), vec![true]);

    let calls = engine.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].len(), 1);
    assert!(calls[0][0].paused, "reconciled scene should stay paused");
}

#[tokio::test]
async fn apply_options_keeps_draft_uncommitted_when_reconcile_fails() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    engine.fail_reconcile_with("reconcile failed");
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge.set_volume("100".to_string(), 0.5).await.unwrap();
    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();

    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .expect_err("reconcile should fail");
    assert!(done.wait(Duration::from_secs(2)));

    let edited = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(edited.dirty);
    assert_f32_close(edited.volume, 0.5);
    assert!(edited.display_configurations[0].enabled);

    bridge
        .cancel_wallpaper_options("100".to_string())
        .await
        .unwrap();

    let restored = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!restored.dirty);
    assert_f32_close(restored.volume, 0.5);
    assert!(!restored.display_configurations[0].enabled);
}

#[tokio::test]
async fn cancel_options_restores_display_enable_draft() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let edited = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(edited.dirty);
    assert!(edited.display_configurations[0].enabled);

    bridge
        .cancel_wallpaper_options("100".to_string())
        .await
        .unwrap();

    let restored = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!restored.dirty);
    assert!(!restored.display_configurations[0].enabled);
}

#[tokio::test]
async fn target_fps_is_clamped_to_display_refresh_rate() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_target_fps("100".to_string(), "7".to_string(), 144)
        .await
        .unwrap();

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert_eq!(options.display_configurations[0].max_fps, 75);
    assert_eq!(options.display_configurations[0].target_fps, 75);
}

#[tokio::test]
async fn only_the_default_rate_is_stored_as_following_the_display() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 120), display_snapshot(8, 120)]);
    let bridge = BridgeBuilder::new(engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    // The full refresh of a 120 Hz display is above the default, so it is a
    // choice and is saved; the default itself keeps following the display.
    bridge
        .set_target_fps("100".into(), "7".into(), 120)
        .await
        .unwrap();
    let wallpaper_path = root.path().join("wallpapers").join("100.json");
    assert_saved_monitor_rate(&wallpaper_path, Some(120));

    bridge
        .set_target_fps("100".into(), "7".into(), 60)
        .await
        .unwrap();
    assert_saved_monitor_rate(&wallpaper_path, None);

    bridge
        .set_target_fps("100".into(), "7".into(), 30)
        .await
        .unwrap();
    assert_saved_monitor_rate(&wallpaper_path, Some(30));

    bridge
        .set_display_mode("8".into(), BridgeDisplayMode::Mirror)
        .await
        .unwrap();
    bridge.set_mirror_target_fps("8".into(), 120).await.unwrap();
    assert_eq!(saved_mirror_rate(root.path()), Some(120));
    bridge.set_mirror_target_fps("8".into(), 60).await.unwrap();
    assert_eq!(saved_mirror_rate(root.path()), None);
    bridge.set_mirror_target_fps("8".into(), 45).await.unwrap();
    assert_eq!(saved_mirror_rate(root.path()), Some(45));
}

fn assert_saved_monitor_rate(path: &std::path::Path, expected: Option<u32>) {
    let written = fs::read_to_string(path).unwrap();
    let value: serde_json::Value = serde_json::from_str(&written).unwrap();
    let monitor = &value["monitors"][0];
    assert!(monitor.get("fps").is_none(), "{written}");
    match expected {
        None => assert!(monitor.get("frame_rate").is_none(), "{written}"),
        Some(rate) => {
            assert_eq!(monitor["frame_rate"], rate, "{written}");
        }
    }
}

fn saved_mirror_rate(root: &std::path::Path) -> Option<u32> {
    let written = fs::read_to_string(root.join("config.toml")).unwrap();
    let value: toml::Value = toml::from_str(&written).unwrap();
    let settings = value
        .get("monitor_settings")
        .and_then(toml::Value::as_array)
        .and_then(|rows| {
            rows.iter()
                .find(|row| row.get("display_id").and_then(toml::Value::as_integer) == Some(8))
        })
        .unwrap_or_else(|| panic!("missing mirror settings in {written}"));
    assert!(
        settings.get("target_fps").is_none(),
        "legacy target_fps must not be written: {written}"
    );
    settings
        .get("frame_rate")
        .map(|rate| u32::try_from(rate.as_integer().unwrap()).unwrap())
}

#[tokio::test]
async fn scaling_factor_edit_updates_draft_and_apply_persists_without_reconcile() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    assert_eq!(engine.calls().len(), 1);
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 42)]);

    bridge
        .edit_scaling_factor("100".to_string(), "7".to_string(), 1.25)
        .await
        .unwrap();

    assert_eq!(
        engine.scaling_factor_calls(),
        vec![(SceneHandle::new(42), 1.25)]
    );

    let edited = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(edited.dirty);
    assert_f64_close(edited.display_configurations[0].scaling_factor, 1.25);

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    assert_eq!(
        engine.calls().len(),
        1,
        "scaling-factor-only apply must not reconstruct scenes"
    );

    let next_engine = FakeEngineFacade::default();
    next_engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let next_bridge = BridgeBuilder::new(next_engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    next_bridge
        .inject_wallpaper_for_test("100", "Scene", crate::BridgeWallpaperKind::ProjectScene)
        .await;
    let persisted_config = ConfigStore::open(root.path().to_path_buf())
        .load_wallpaper("100")
        .unwrap();
    next_bridge
        .replace_wallpaper_config_for_test("100", persisted_config)
        .await;

    let persisted = next_bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!persisted.dirty);
    assert_f64_close(persisted.display_configurations[0].scaling_factor, 1.25);
}

#[tokio::test]
async fn scaling_factor_edit_rejects_non_positive_and_non_finite_values() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    for invalid_factor in [0.0, -0.1, f64::INFINITY, f64::NAN] {
        let error = bridge
            .edit_scaling_factor("100".to_string(), "7".to_string(), invalid_factor)
            .await
            .expect_err("invalid scaling factor should be rejected");
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        assert!(error.message().contains("greater than 0"));
    }

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!options.dirty);
    assert_f64_close(options.display_configurations[0].scaling_factor, 1.0);
}

#[tokio::test]
async fn scaling_factor_edit_does_not_update_another_wallpapers_active_scene() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test("200", "Other Scene")
        .await;

    bridge
        .set_display_config_enabled("200".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("200".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    engine.set_snapshot(vec![active_display_snapshot_for_wallpaper(
        7, 75, 42, "200",
    )]);

    bridge
        .edit_scaling_factor("100".to_string(), "7".to_string(), 1.25)
        .await
        .unwrap();

    assert_eq!(
        engine.scaling_factor_calls(),
        Vec::<(SceneHandle, f64)>::new()
    );
}

#[tokio::test]
async fn audio_option_edits_apply_to_active_scene_without_reconcile() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    assert_eq!(engine.calls().len(), 1);
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 42)]);

    bridge.set_volume("100".to_string(), 0.25).await.unwrap();
    bridge.set_muted("100".to_string(), true).await.unwrap();
    bridge
        .set_audio_response_enabled("100".to_string(), false)
        .await
        .unwrap();

    assert_eq!(engine.calls().len(), 1);
    wait_for_audio_volume_calls(
        &engine,
        &[(SceneHandle::new(1), 1.0), (SceneHandle::new(42), 0.25)],
    );
    wait_for_audio_muted_calls(
        &engine,
        &[(SceneHandle::new(1), false), (SceneHandle::new(42), true)],
    );
    wait_for_audio_response_calls(
        &engine,
        &[(SceneHandle::new(1), true), (SceneHandle::new(42), false)],
    );
    wait_for_audio_capture_calls(
        &engine,
        &[(SceneHandle::new(1), true), (SceneHandle::new(42), false)],
    );

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!options.dirty);

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    assert_eq!(engine.calls().len(), 1);
    assert!(
        !bridge
            .wallpaper_options_snapshot("100".to_string())
            .await
            .unwrap()
            .dirty
    );
}

#[tokio::test]
async fn scaling_and_fps_option_edits_apply_to_active_scene_without_reconcile() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    assert_eq!(engine.calls().len(), 1);
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 42)]);

    bridge
        .set_scaling_mode("100".to_string(), "7".to_string(), BridgeScalingMode::Fill)
        .await
        .unwrap();
    bridge
        .set_target_fps("100".to_string(), "7".to_string(), 30)
        .await
        .unwrap();

    assert_eq!(
        engine.scaling_mode_calls(),
        vec![(SceneHandle::new(42), ScalingMode::Fill)]
    );
    assert_eq!(engine.fps_calls(), vec![(SceneHandle::new(42), 30)]);

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!options.dirty);
    assert_eq!(
        options.display_configurations[0].scaling_mode,
        BridgeScalingMode::Fill
    );
    assert_eq!(options.display_configurations[0].target_fps, 30);

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    assert_eq!(engine.calls().len(), 1);
}

#[tokio::test]
async fn pending_render_option_edits_apply_to_active_scene_without_reconcile() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    assert_eq!(engine.calls().len(), 1);
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 42)]);

    bridge
        .edit_scaling_factor("100".to_string(), "7".to_string(), 1.5)
        .await
        .unwrap();

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(options.dirty);
    assert_f64_close(options.display_configurations[0].scaling_factor, 1.5);

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    assert_eq!(
        engine.calls().len(),
        1,
        "render-only option edits on an active scene must not reconstruct scenes"
    );
    assert_eq!(
        engine.scaling_factor_calls(),
        vec![(SceneHandle::new(42), 1.5)]
    );
    assert!(
        !bridge
            .wallpaper_options_snapshot("100".to_string())
            .await
            .unwrap()
            .dirty
    );
}

#[tokio::test]
async fn applying_default_scene_starts_audio_capture() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge.set_volume("100".to_string(), 0.25).await.unwrap();
    bridge.set_muted("100".to_string(), true).await.unwrap();
    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    wait_for_audio_volume_calls(&engine, &[(SceneHandle::new(1), 0.25)]);
    wait_for_audio_muted_calls(&engine, &[(SceneHandle::new(1), true)]);
    wait_for_audio_response_calls(&engine, &[(SceneHandle::new(1), true)]);
    wait_for_audio_capture_calls(&engine, &[(SceneHandle::new(1), true)]);

    assert_eq!(
        engine.audio_volume_calls(),
        vec![(SceneHandle::new(1), 0.25)]
    );
    assert_eq!(
        engine.audio_muted_calls(),
        vec![(SceneHandle::new(1), true)]
    );
    assert_eq!(
        engine.audio_response_calls(),
        vec![(SceneHandle::new(1), true)]
    );
    assert_eq!(
        engine.audio_capture_calls(),
        vec![(SceneHandle::new(1), true)]
    );
}

#[tokio::test]
async fn live_audio_response_toggle_keeps_selection_responsive_while_capture_starts() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = Arc::new(
        BridgeBuilder::new(engine.clone())
            .with_state(crate::actor::state::BridgeActorState::default())
            .build()
            .expect("tokio runtime and config load for wallpaper bridge"),
    );
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test("200", "Other")
        .await;
    bridge
        .set_audio_response_enabled("100".to_string(), false)
        .await
        .unwrap();

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 42)]);

    let block = engine.block_next_audio_capture();
    let (toggle_tx, toggle_rx) = mpsc::channel();
    let toggle_bridge = Arc::clone(&bridge);
    let toggle = thread::spawn(move || {
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            toggle_bridge
                .set_audio_response_enabled("100".to_string(), true)
                .await
        });
        toggle_tx.send(result).unwrap();
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(2)),
        "audio response toggle did not reach audio capture"
    );

    assert!(
        matches!(toggle_rx.try_recv(), Err(mpsc::TryRecvError::Empty)),
        "audio activation must not report success before capture starts"
    );

    bridge
        .select_wallpaper("200".to_string())
        .await
        .expect("selection should stay responsive while capture finishes");
    assert_eq!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .selected_wallpaper_id
            .as_deref(),
        Some("200")
    );

    block.release();
    toggle_rx
        .recv_timeout(Duration::from_secs(2))
        .unwrap()
        .unwrap();
    toggle.join().unwrap();
}

#[tokio::test]
async fn failed_audio_activation_is_reported_and_rolls_back_without_losing_other_options() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_audio_response_enabled("100".into(), false)
        .await
        .unwrap();
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    engine.set_snapshot(vec![active_display_snapshot(7, 75, 1)]);
    bridge.set_volume("100".into(), 0.25).await.unwrap();
    engine.fail_audio_capture_with(Some("System audio recording denied".into()));
    let error = bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    let options = bridge
        .wallpaper_options_snapshot("100".into())
        .await
        .unwrap();
    assert!(!options.audio_response_enabled);
    assert_f32_close(options.volume, 0.25);
    let stored = ConfigStore::open(root.path().to_path_buf())
        .load_wallpaper("100")
        .unwrap();
    assert!(!stored.audio.response_enabled);
    assert_f32_close(stored.audio.volume, 0.25);
    engine.fail_audio_capture_with(None);
    let enabled = bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    assert!(enabled.wallpaper_options.audio_response_enabled);
    let disabled = bridge
        .set_audio_response_enabled("100".into(), false)
        .await
        .unwrap();
    assert!(!disabled.wallpaper_options.audio_response_enabled);
}

#[tokio::test]
async fn apply_options_clamps_scene_fps_to_display_refresh_rate() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 30)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(2)));

    let calls = engine.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].len(), 1);
    assert_eq!(calls[0][0].fps, 30);
}

#[tokio::test]
async fn apply_options_updates_active_wallpaper_snapshots() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(1, 75), display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(app.active_wallpaper_ids, vec!["100".to_string()]);
    assert!(
        bridge
            .library_snapshot()
            .await
            .unwrap()
            .wallpapers
            .iter()
            .any(|entry| entry.id == "100" && entry.active)
    );
    assert!(
        bridge
            .monitor_information_snapshot()
            .await
            .unwrap()
            .rows
            .iter()
            .any(|row| row.display_id == "7" && row.wallpaper_id == "100")
    );

    bridge
        .set_display_enabled("7".to_string(), false)
        .await
        .expect("display setting should commit");

    assert!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .active_wallpaper_ids
            .is_empty()
    );
    assert!(
        !bridge
            .library_snapshot()
            .await
            .unwrap()
            .wallpapers
            .iter()
            .any(|entry| entry.id == "100" && entry.active)
    );
}

#[tokio::test]
async fn applied_options_persist_across_bridge_instances() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge.set_volume("100".to_string(), 0.25).await.unwrap();
    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    let next_engine = FakeEngineFacade::default();
    next_engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let next_bridge = BridgeBuilder::new(next_engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    next_bridge
        .inject_wallpaper_for_test("100", "Scene", crate::BridgeWallpaperKind::ProjectScene)
        .await;
    next_bridge
        .select_wallpaper("100".to_string())
        .await
        .unwrap();

    let options = next_bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!options.dirty);
    assert_f32_close(options.volume, 0.25);
    assert!(options.display_configurations[0].enabled);
}

#[tokio::test]
async fn failed_save_reports_live_assignment_and_preserves_pending_scaling() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("wallpapers"), b"not a directory").unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    bridge
        .edit_scaling_factor("100".to_string(), "7".to_string(), 1.5)
        .await
        .unwrap();

    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .expect_err("wallpaper config write should fail");

    let monitor = bridge.monitor_information_snapshot().await.unwrap();
    assert_eq!(monitor.rows[0].wallpaper_id, "100");
    let pending = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(pending.dirty);
    assert_f64_close(pending.display_configurations[0].scaling_factor, 1.5);

    let reverted = bridge
        .cancel_wallpaper_options("100".to_string())
        .await
        .unwrap();
    assert_f64_close(
        reverted.wallpaper_options.display_configurations[0].scaling_factor,
        1.0,
    );
    fs::remove_file(root.path().join("wallpapers")).unwrap();
    let saved = bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert!(!saved.wallpaper_options.dirty);
}

#[tokio::test]
async fn control_plane_stays_responsive_when_apply_reconcile_is_in_flight() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let block = engine.block_next_reconcile();
    let bridge = Arc::new(
        BridgeBuilder::new(engine)
            .with_state(crate::actor::state::BridgeActorState::default())
            .build()
            .expect("tokio runtime and config load for wallpaper bridge"),
    );
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test("200", "Other")
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();

    let (apply_tx, apply_rx) = mpsc::channel();
    let apply_bridge = Arc::clone(&bridge);
    let apply = thread::spawn(move || {
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            apply_bridge
                .apply_wallpaper_options("100".to_string(), true)
                .await
        });
        apply_tx.send(result).unwrap();
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(2)),
        "apply did not reach reconcile"
    );

    let options = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .expect("options should be readable while reconcile is blocked");
    assert!(options.dirty);
    assert!(options.display_configurations[0].enabled);

    bridge
        .select_wallpaper("200".to_string())
        .await
        .expect("wallpaper selection should not wait for renderer reconcile");
    assert_eq!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .selected_wallpaper_id
            .as_deref(),
        Some("200")
    );

    bridge
        .pause_all()
        .await
        .expect("tray pause should not wait for renderer reconcile");
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );

    block.release();
    apply_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("apply should return after renderer reconcile completes")
        .unwrap();
    apply.join().unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused,
        "stale in-flight apply must not overwrite newer playback state"
    );
}

#[tokio::test]
async fn failed_reconcile_does_not_persist_config() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    engine.fail_reconcile_with("reconcile failed");
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;

    bridge.set_volume("100".to_string(), 0.25).await.unwrap();
    bridge
        .set_display_config_enabled("100".to_string(), "7".to_string(), true)
        .await
        .unwrap();

    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .expect_err("reconcile should fail");
    assert!(done.wait(Duration::from_secs(2)));

    assert!(
        !root.path().join("config.toml").exists(),
        "failed reconcile must not persist app config"
    );
    let persisted_wallpaper = fs::read_to_string(root.path().join("wallpapers").join("100.json"))
        .expect("immediate volume edit should have persisted wallpaper config");
    assert!(
        persisted_wallpaper.contains("\"volume\": 0.25"),
        "immediate wallpaper edits should remain persisted"
    );
    assert!(
        !persisted_wallpaper.contains("\"selector\""),
        "failed reconcile must not persist pending display assignments"
    );
}

fn wait_for_audio_capture_calls(engine: &FakeEngineFacade, expected: &[(SceneHandle, bool)]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.audio_capture_calls();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected audio capture calls {expected:?}, got {calls:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn wait_for_audio_volume_calls(engine: &FakeEngineFacade, expected: &[(SceneHandle, f32)]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.audio_volume_calls();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected audio volume calls {expected:?}, got {calls:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn wait_for_audio_muted_calls(engine: &FakeEngineFacade, expected: &[(SceneHandle, bool)]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.audio_muted_calls();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected audio muted calls {expected:?}, got {calls:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn wait_for_audio_response_calls(engine: &FakeEngineFacade, expected: &[(SceneHandle, bool)]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.audio_response_calls();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected audio response calls {expected:?}, got {calls:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[tokio::test]
async fn lock_screen_export_ignores_drafts_and_tracks_pause_and_ejection() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge
        .set_scaling_mode("100".into(), "7".into(), BridgeScalingMode::Fill)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    let applied = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(applied.len(), 1);
    assert_eq!(applied[0].scaling_mode, BridgeScalingMode::Fill);
    assert!(std::path::Path::new(&applied[0].project_path).is_absolute());

    bridge
        .edit_scaling_factor("100".into(), "7".into(), 1.25)
        .await
        .unwrap();
    assert_eq!(
        bridge.lock_screen_scenes().await.unwrap()[0].scaling_factor,
        1.0
    );
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    assert_eq!(
        bridge.lock_screen_scenes().await.unwrap()[0].scaling_factor,
        1.25
    );
    bridge.pause_all().await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge.play_all().await.unwrap();
    assert!(!bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge
        .eject_wallpaper_from_display("7".into(), "100".into())
        .await
        .unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap().is_empty());
}

#[tokio::test]
async fn web_wallpaper_apply_bypasses_engine_and_exports_host_inputs() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_project_for_test(
            "300",
            "Web",
            r#"{
            "type":"web",
            "title":"Web",
            "file":"index.html",
            "general":{"properties":{
                "group":{"type":"group","text":"Group","order":0},
                "theme":{"type":"combo","text":"Theme","value":"light","order":1,
                         "options":[{"label":"Light","value":"light"},{"label":"Dark","value":"dark"}]},
                "tint":{"type":"color","text":"Tint","value":"1 0.5 0","order":2}
            }}
        }"#,
        )
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge
        .edit_property(
            "300".into(),
            "theme".into(),
            crate::BridgePropertyValue::String {
                value: "dark".into(),
            },
        )
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();

    assert!(
        engine.rendered_scenes().is_empty(),
        "web wallpapers must never reach the scene engine"
    );
    assert_eq!(
        bridge.app_snapshot().await.unwrap().active_wallpaper_ids,
        vec!["300".to_string()]
    );

    let web = bridge.web_wallpapers().await.unwrap();
    assert_eq!(web.len(), 1);
    assert_eq!(web[0].display_id, 7);
    assert_eq!(web[0].wallpaper_id, "300");
    assert_eq!(web[0].entry_file, "index.html");
    assert!(std::path::Path::new(&web[0].project_path).is_absolute());
    assert!(web[0].project_path.ends_with("300"));
    assert!(!web[0].paused);
    let properties: serde_json::Value = serde_json::from_str(&web[0].properties_json).unwrap();
    assert_eq!(properties["theme"]["value"], "dark");
    assert_eq!(properties["tint"]["value"], "1 0.5 0");
    assert!(properties.get("group").is_none(), "group rows are not user properties");

    let exported = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(exported.len(), 1);
    assert_eq!(exported[0].display_id, 7);
    assert_eq!(exported[0].wallpaper_id, "300");
    assert_eq!(
        std::path::Path::new(&exported[0].project_path),
        std::path::Path::new(&web[0].project_path).join("project.json")
    );
    assert_eq!(exported[0].assets_path, web[0].project_path);
    assert_eq!(exported[0].scaling_mode, BridgeScalingMode::Fill);
    assert_eq!(exported[0].scaling_factor, 1.0);
    let exported_properties: serde_json::Value =
        serde_json::from_str(exported[0].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(exported_properties["theme"]["value"], "dark");
    assert_eq!(exported_properties["tint"]["value"], "1 0.5 0");
    assert_eq!(exported_properties, properties);

    bridge
        .edit_property(
            "300".into(),
            "theme".into(),
            crate::BridgePropertyValue::String { value: "light".into() },
        )
        .await
        .unwrap();
    let draft_export = bridge.lock_screen_scenes().await.unwrap();
    let properties: serde_json::Value =
        serde_json::from_str(draft_export[0].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(properties["theme"]["value"], "dark");

    bridge.pause_all().await.unwrap();
    assert!(bridge.web_wallpapers().await.unwrap()[0].paused);
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge
        .eject_wallpaper_from_display("7".into(), "300".into())
        .await
        .unwrap();
    assert!(bridge.web_wallpapers().await.unwrap().is_empty());
    assert!(bridge.lock_screen_scenes().await.unwrap().is_empty());
    assert!(bridge.app_snapshot().await.unwrap().active_wallpaper_ids.is_empty());
}

/// A web page has no renderer target to shrink, so the host is handed the scale
/// that is in force and applies it to `devicePixelRatio`. It has to follow the
/// same rule a scene does: the saved scale, or the battery profile's while
/// Reduced quality is selected and the Mac is on battery.
#[tokio::test]
async fn web_wallpaper_descriptor_carries_the_effective_render_scale() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_project_for_test(
            "300",
            "Web",
            r#"{"type":"web","title":"Web","file":"index.html"}"#,
        )
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();

    assert_eq!(bridge.web_wallpapers().await.unwrap()[0].render_scale, 1.0);
    assert!(
        bridge.settings_snapshot().await.unwrap().render_scale_supported,
        "a running web page honours the scale, so the control must be enabled"
    );

    bridge.set_render_scale(0.5).await.unwrap();
    assert_eq!(bridge.web_wallpapers().await.unwrap()[0].render_scale, 0.5);

    bridge
        .set_battery_mode(crate::BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    assert_eq!(
        bridge.web_wallpapers().await.unwrap()[0].render_scale,
        0.5,
        "Reduced quality is selected but the Mac is on external power"
    );

    bridge
        .set_power_source_for_test(crate::power::PowerSource::Battery)
        .await;
    let on_battery = bridge.web_wallpapers().await.unwrap();
    assert_eq!(
        on_battery[0].render_scale, 0.75,
        "the battery profile's default scale"
    );

    bridge
        .set_power_source_for_test(crate::power::PowerSource::External)
        .await;
    assert_eq!(
        bridge.web_wallpapers().await.unwrap()[0].render_scale,
        0.5,
        "leaving battery power hands back the scale the user saved"
    );
}

#[tokio::test]
async fn web_wallpaper_combo_values_keep_authored_types_after_editor_changes() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_project_for_test(
            "300",
            "Web",
            r#"{
            "type":"web","file":"index.html","general":{"properties":{
                "mode":{"type":"combo","value":1,"order":1,"options":[
                    {"label":"Image","value":1},
                    {"label":"Video","value":2},
                    {"label":"String identifier","value":"3"},
                    {"label":"Enabled","value":true},
                    {"label":"Opaque identifier","value":"0.10 0.20 0.30"}
                ]},
                "legacy":{"type":"combo","value":4,"order":2},
                "opaque":{"type":"combo","value":"0.10 0.20 0.30","order":3,
                          "options":[{"label":"Identifier","value":"0.10 0.20 0.30"}]}
            }}
        }"#,
        )
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();

    let web = bridge.web_wallpapers().await.unwrap();
    let initial: serde_json::Value = serde_json::from_str(&web[0].properties_json).unwrap();
    assert_eq!(initial["mode"]["value"].as_f64(), Some(1.0));
    assert_eq!(initial["legacy"]["value"].as_f64(), Some(4.0));
    assert_eq!(initial["opaque"]["value"], "0.10 0.20 0.30");

    for (selection, expected) in [
        ("2", serde_json::json!(2)),
        ("3", serde_json::json!("3")),
        ("true", serde_json::json!(true)),
        ("0.10 0.20 0.30", serde_json::json!("0.10 0.20 0.30")),
        ("1", serde_json::json!(1)),
    ] {
        let edited = bridge
            .edit_property(
                "300".into(),
                "mode".into(),
                crate::BridgePropertyValue::String {
                    value: selection.into(),
                },
            )
            .await
            .unwrap();
        let mode = edited
            .wallpaper_options
            .properties
            .iter()
            .find(|property| property.id == "mode")
            .unwrap();
        assert_eq!(
            mode.value,
            crate::BridgePropertyValue::String {
                value: selection.into()
            }
        );
        bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
        let web = bridge.web_wallpapers().await.unwrap();
        let properties: serde_json::Value = serde_json::from_str(&web[0].properties_json).unwrap();
        assert_eq!(
            properties["mode"]["value"], expected,
            "selection {selection}"
        );
    }
}

#[tokio::test]
async fn lock_screen_export_ignores_presentation_suspension_but_preserves_playback_policy() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();

    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(engine.rendered_scenes()[0].paused);
    assert!(!bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge.pause_all().await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge.play_all().await.unwrap();

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_power_source_for_test(crate::power::PowerSource::Battery)
        .await;
    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge
        .set_power_source_for_test(crate::power::PowerSource::External)
        .await;
    assert!(engine.rendered_scenes()[0].paused);
    assert!(!bridge.lock_screen_scenes().await.unwrap()[0].paused);
}

#[tokio::test]
async fn lock_screen_export_ignores_the_desktop_display_being_covered() {
    // Locking covers the desktop wallpaper, and its display is suspended for
    // that. The lock screen is what is on screen then, so it must not take
    // the covered desktop's suspension as a pause and hold a still frame.
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    assert!(engine.rendered_scenes()[0].paused);
    assert!(!bridge.lock_screen_scenes().await.unwrap()[0].paused);
    bridge.pause_all().await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap()[0].paused);
}

#[tokio::test]
async fn presentation_transitions_repair_in_flight_reconcile_pause_state() {
    for initially_suspended in [false, true] {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![live_display_snapshot(7, 75)]);
        let bridge = Arc::new(
            BridgeBuilder::new(engine.clone())
                .with_state(crate::actor::state::BridgeActorState::default())
                .build()
                .unwrap(),
        );
        bridge
            .inject_scene_wallpaper_config_for_test("100", "Scene")
            .await;
        bridge
            .set_display_config_enabled("100".into(), "7".into(), true)
            .await
            .unwrap();
        bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
        bridge
            .set_presentation_suspended(initially_suspended)
            .await
            .unwrap();
        bridge
            .inject_scene_wallpaper_config_for_test("200", "Other")
            .await;
        bridge
            .set_display_config_enabled("200".into(), "7".into(), true)
            .await
            .unwrap();

        let block = engine.block_next_reconcile();
        let repair_block = engine.block_next_reconcile();
        let apply_bridge = Arc::clone(&bridge);
        let apply = thread::spawn(move || {
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(apply_bridge.apply_wallpaper_options("200".into(), true))
        });
        assert!(
            block.wait_until_blocked(Duration::from_secs(2)),
            "apply did not reach reconcile"
        );
        bridge
            .set_presentation_suspended(!initially_suspended)
            .await
            .unwrap();
        block.release();
        apply.join().unwrap().unwrap();
        assert!(
            repair_block.wait_until_blocked(Duration::from_secs(2)),
            "presentation transition did not invalidate the in-flight reconcile"
        );
        let repair_done = engine.wait_for_next_reconcile();
        repair_block.release();
        assert!(repair_done.wait(Duration::from_secs(2)));

        let rendered = engine.rendered_scenes();
        assert_eq!(rendered.len(), 1);
        assert_eq!(rendered[0].paused, !initially_suspended);
        assert_eq!(engine.audio_capture_suspended(), !initially_suspended);
        assert_eq!(
            bridge.app_snapshot().await.unwrap().playback_state,
            BridgePlaybackState::Playing
        );
    }
}

#[tokio::test]
async fn failed_audio_resume_restores_renderer_and_allows_later_presentation_transitions() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![live_display_snapshot(7, 75)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();
    engine.fail_audio_capture_with(Some("audio restart failed".into()));

    let error = bridge.set_presentation_suspended(false).await.unwrap_err();
    assert!(error.message().contains("audio restart failed"));
    assert!(engine.rendered_scenes()[0].paused);
    assert!(engine.audio_capture_suspended());
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(engine.rendered_scenes()[0].paused);
    assert!(engine.audio_capture_suspended());

    engine.fail_audio_capture_with(None);
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(!engine.rendered_scenes()[0].paused);
    assert!(!engine.audio_capture_suspended());
    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(engine.rendered_scenes()[0].paused);
    assert!(engine.audio_capture_suspended());
}

/// A display showing a live scene, whose renderer the bridge asks whether it
/// reads audio. The fake's first reconcile hands this display handle 1.
fn live_display_snapshot(display_id: u32, refresh_rate_hz: u32) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(1)),
        ..display_snapshot(display_id, refresh_rate_hz)
    }
}

fn display_snapshot(display_id: u32, refresh_rate_hz: u32) -> DisplaySnapshotEntry {
    let desc = DisplayDesc::with_identity(
        display_id,
        DisplayIdentity::default(),
        0,
        0,
        1920,
        1080,
        1.0,
    )
    .with_refresh_rate(refresh_rate_hz);

    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

fn active_display_snapshot(
    display_id: u32,
    refresh_rate_hz: u32,
    handle: u64,
) -> DisplaySnapshotEntry {
    active_display_snapshot_for_wallpaper(display_id, refresh_rate_hz, handle, "100")
}

fn active_display_snapshot_for_wallpaper(
    display_id: u32,
    refresh_rate_hz: u32,
    handle: u64,
    wallpaper_id: &str,
) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(handle)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder(format!(
                "/workshop/content/431960/{wallpaper_id}/project.json"
            ))
            .build()
            .unwrap(),
        )),
        ..display_snapshot(display_id, refresh_rate_hz)
    }
}
