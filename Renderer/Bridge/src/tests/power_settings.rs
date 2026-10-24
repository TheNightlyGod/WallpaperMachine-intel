use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

use crate::{
    BridgePlaybackState,
    api::BridgeBuilder,
    engine::FakeEngineFacade,
    power::PowerSource,
};

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

    assert!(engine.wait_for_pause_trace(&[true], Duration::from_secs(2)).await);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );

    // Plugged in during the next sleep.
    *source.lock().unwrap() = PowerSource::External;
    bridge.resample_power_source();

    assert!(engine.wait_for_pause_trace(&[true, false], Duration::from_secs(2)).await);
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
    assert!(engine.wait_for_pause_trace(&[], Duration::from_secs(2)).await);
}

