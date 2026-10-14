use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

use wallpaper_core::project::SceneHandle;

use crate::{
    BridgePlaybackState,
    api::BridgeBuilder,
    config::{AppConfig, ConfigStore, PowerCfg},
    engine::FakeEngineFacade,
    power::PowerSource,
};

#[tokio::test]
async fn pause_on_battery_setting_persists_and_appears_in_settings_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    let bridge = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    let snapshot = bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();

    assert_eq!(snapshot.settings.battery_mode, crate::BridgeBatteryMode::Pause);
    assert_eq!(store.load().unwrap().config.power.on_battery, crate::config::BatteryModeCfg::Pause);
}

#[test]
fn power_watcher_spawn_does_not_block_bridge_construction() {
    let (done_tx, done_rx) = std::sync::mpsc::channel();

    std::thread::spawn(move || {
        let _bridge = BridgeBuilder::new(FakeEngineFacade::default())
            .with_power_watching_enabled(true)
            .build()
            .expect("tokio runtime and config load for wallpaper bridge");
        done_tx
            .send(())
            .expect("test receiver should observe bridge construction");
    });

    done_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("power watcher startup must not block bridge construction");
}

#[tokio::test]
async fn startup_battery_sample_from_builder_waits_for_first_frame() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            power: PowerCfg {
                on_battery: crate::config::BatteryModeCfg::Pause,
                ..PowerCfg::default()
            },
            ..AppConfig::default()
        })
        .unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_startup_power_source(PowerSource::Battery)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[]);

    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true]);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
}

#[tokio::test]
async fn startup_battery_sample_from_builder_is_app_launch_only() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            power: PowerCfg {
                on_battery: crate::config::BatteryModeCfg::Pause,
                ..PowerCfg::default()
            },
            ..AppConfig::default()
        })
        .unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_startup_power_source(PowerSource::Battery)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);
    engine.trigger_first_frame(SceneHandle::new(2));

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[true, false]);
}

#[tokio::test]
async fn enabling_pause_on_battery_while_on_battery_auto_pauses_playback() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_power_source_for_test(PowerSource::Battery).await;
    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    wait_for_paused_calls(&engine, &[true]);
}

#[tokio::test]
async fn external_power_resumes_only_when_bridge_auto_paused_playback() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    wait_for_paused_calls(&engine, &[true]);

    bridge
        .set_power_source_for_test(PowerSource::External)
        .await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[true, false]);
}

#[tokio::test]
async fn manual_resume_on_battery_suppresses_auto_pause_until_next_battery_transition() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);

    bridge.set_power_source_for_test(PowerSource::Battery).await;
    wait_for_paused_calls(&engine, &[true, false]);

    bridge
        .set_power_source_for_test(PowerSource::External)
        .await;
    wait_for_paused_calls(&engine, &[true, false]);

    bridge.set_power_source_for_test(PowerSource::Battery).await;
    wait_for_paused_calls(&engine, &[true, false, true]);
}

#[tokio::test]
async fn battery_transition_does_not_resume_playback_that_user_paused_first() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.pause_all().await.unwrap();
    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    bridge
        .set_power_source_for_test(PowerSource::External)
        .await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    wait_for_paused_calls(&engine, &[true]);
}

#[tokio::test]
async fn startup_on_battery_defers_auto_pause_until_initial_frame_is_ready() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[]);

    bridge.initial_frame_ready_for_test().await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    wait_for_paused_calls(&engine, &[true]);
}

#[tokio::test]
async fn startup_on_battery_auto_pauses_after_engine_first_frame_callback() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;
    wait_for_paused_calls(&engine, &[]);

    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true]);

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
}

#[tokio::test]
async fn startup_first_frame_after_manual_resume_on_battery_does_not_pause_again() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;
    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);

    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true, false]);

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
}

#[tokio::test]
async fn initial_battery_sample_after_first_frame_auto_pauses_immediately() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge.initial_frame_ready_for_test().await;
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    wait_for_paused_calls(&engine, &[true]);
}

#[tokio::test]
async fn duplicate_initial_battery_sample_after_manual_resume_does_not_pause_again() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;
    bridge.initial_frame_ready_for_test().await;
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[true, false]);
}

#[tokio::test]
async fn scene_first_frame_after_manual_resume_on_battery_does_not_pause_again() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();
    bridge
        .set_initial_power_source_for_test(PowerSource::Battery)
        .await;
    engine.trigger_first_frame(SceneHandle::new(1));
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);
    engine.trigger_first_frame(SceneHandle::new(2));

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[true, false]);
}

#[tokio::test]
async fn resample_applies_the_battery_policy_missed_while_asleep() {
    let engine = FakeEngineFacade::default();
    let source = Arc::new(Mutex::new(PowerSource::External));
    let reader_source = Arc::clone(&source);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_power_watching_enabled(true)
        .with_power_reader(Arc::new(move || *reader_source.lock().unwrap()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge.set_battery_mode(crate::BridgeBatteryMode::Pause).await.unwrap();

    // Unplugged while the Mac slept, and nobody was told.
    *source.lock().unwrap() = PowerSource::Battery;
    bridge.resample_power_source();

    wait_for_paused_calls(&engine, &[true]);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );

    // Plugged in during the next sleep.
    *source.lock().unwrap() = PowerSource::External;
    bridge.resample_power_source();

    wait_for_paused_calls(&engine, &[true, false]);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
}

#[tokio::test]
async fn resample_on_a_bridge_that_is_not_watching_power_does_nothing() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.resample_power_source();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[]);
}

fn wait_for_paused_calls(engine: &FakeEngineFacade, expected: &[bool]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.paused_calls();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected paused calls {expected:?}, got {calls:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
