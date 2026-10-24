use super::*;

use std::sync::{Arc, Condvar, Mutex};
use std::sync::atomic::{AtomicBool, Ordering as PowerInputOrdering};

use crate::actor::messages::{InitialFrameReady, SetPowerSource};
use crate::api::first_frame_handoff::ObservedFirstFrameDelivery;
use crate::api::{BridgeBatteryMode, BridgePlaybackState, BridgeSnapshotBundle};
use crate::config::{AppConfig, BatteryModeCfg, ConfigStore};
use crate::engine::FakeEngineFacade;
use crate::power::PowerSource;
use wallpaper_core::project::SceneHandle;

// These consumers exercise the real bridge/actor policy with the accepted
// synthetic engine. A callback is not evidence of a native rendered frame.
type FrameReceipts = tokio::sync::mpsc::UnboundedReceiver<(
    SceneHandle,
    ObservedFirstFrameDelivery,
)>;

fn power_store(root: &OwnedRoot, paths: &BridgePaths) -> ConfigStore {
    let store_root = root.checked(paths.app_support_root());
    root.checked(store_root.join("config.toml"));
    root.checked(store_root.join("load-journal.json"));
    root.checked(store_root.join("wallpapers"));
    ConfigStore::open(store_root)
}

async fn drain_power_bridge(bridge: Option<WallpaperBridge>) -> Vec<String> {
    let mut errors = Vec::new();
    if let Some(bridge) = bridge {
        let shutdown = AssertUnwindSafe(tokio::time::timeout(
            WATCHDOG,
            crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
        ))
        .catch_unwind()
        .await;
        match shutdown {
            Ok(Ok(Ok(()))) => {}
            Ok(Ok(Err(error))) => errors.push(format!("power bridge shutdown failed: {error:?}")),
            Ok(Err(error)) => errors.push(format!("power bridge drain timed out: {error}")),
            Err(_) => errors.push("power bridge drain panicked".to_owned()),
        }
    } else {
        errors.push("bridge construction supplied no owned drain handle".to_owned());
    }
    errors
}

fn finish_power_fixture(
    mut root: OwnedRoot,
    result: Result<(), PanicPayload>,
    mut cleanup_errors: Vec<String>,
) {
    if cleanup_errors.is_empty() {
        root.remove_on_drop = true;
        if let Err(error) = root.remove_now() {
            cleanup_errors.push(format!("remove power root {:?}: {error}", root.path));
        }
    } else {
        cleanup_errors.push(format!(
            "retained power root {:?} because successful drain was not confirmed",
            root.path
        ));
    }
    if let Err(payload) = result {
        if !cleanup_errors.is_empty() {
            eprintln!("cleanup after power consumer failure: {cleanup_errors:?}");
        }
        resume_unwind(payload);
    }
    assert!(cleanup_errors.is_empty(), "{cleanup_errors:?}");
}

async fn with_power_bridge<F>(saved_mode: BatteryModeCfg, startup: Option<PowerSource>, body: F)
where
    F: for<'a> FnOnce(
        &'a OwnedRoot,
        &'a BridgePaths,
        &'a WallpaperBridge,
        &'a FakeEngineFacade,
    ) -> TestBody<'a>,
{
    let mut root = OwnedRoot::new();
    let paths = root.bridge_paths();
    let engine = FakeEngineFacade::default();
    let mut bridge = None;
    root.remove_on_drop = false;
    let result: Result<(), PanicPayload> = AssertUnwindSafe(async {
        let store = power_store(&root, &paths);
        let mut config = AppConfig::default();
        config.power.on_battery = saved_mode;
        config.power.on_battery_explicit = true;
        store
            .save_app_config(&config)
            .expect("persist the deliberate power input before building");
        let login = crate::api::lifecycle_test_support::inert_login_controller(
            crate::login::LaunchAtLoginStatus::Unavailable,
        );
        let mut builder = BridgeBuilder::new(engine.clone())
            .with_paths(paths.clone())
            .with_config_store(store)
            .with_launch_at_login(login)
            .with_mouse_polling_enabled(false)
            .with_power_watching_enabled(false);
        if let Some(source) = startup {
            builder = builder.with_startup_power_source(source);
        }
        bridge = Some(builder.build().expect("build the real power consumer bridge"));
        tokio::time::timeout(
            WATCHDOG,
            body(
                &root,
                &paths,
                bridge.as_ref().expect("the power bridge is owned"),
                &engine,
            ),
        )
        .await
        .expect("power consumer operations exceeded the watchdog");
    })
    .catch_unwind()
    .await;

    let cleanup_errors = drain_power_bridge(bridge.take()).await;
    drop(engine);
    finish_power_fixture(root, result, cleanup_errors);
}

async fn power_message(
    bridge: &WallpaperBridge,
    source: PowerSource,
    initial_sample: bool,
) -> BridgeSnapshotBundle {
    crate::api::lifecycle_test_support::actor(bridge)
        .ask(SetPowerSource {
            source,
            initial_sample,
        })
        .await
        .expect("the real power handler completed successfully")
}

async fn assert_power_checkpoint(
    bridge: &WallpaperBridge,
    engine: &FakeEngineFacade,
    state: BridgePlaybackState,
    calls: &[bool],
) {
    let app = bridge
        .app_snapshot()
        .await
        .expect("read public playback after the completed causal boundary");
    assert_eq!(app.playback_state, state);
    assert_eq!(engine.paused_calls(), calls);
}

async fn assert_power_reply(
    bridge: &WallpaperBridge,
    engine: &FakeEngineFacade,
    reply: &BridgeSnapshotBundle,
    state: BridgePlaybackState,
    calls: &[bool],
) {
    assert_eq!(reply.app.playback_state, state);
    assert_power_checkpoint(bridge, engine, state, calls).await;
}

fn frame_receipts(bridge: &WallpaperBridge) -> FrameReceipts {
    crate::api::lifecycle_test_support::handoff(bridge).observe_deliveries_for_test()
}

async fn complete_engine_frame(
    bridge: &WallpaperBridge,
    engine: &FakeEngineFacade,
    receipts: &mut FrameReceipts,
    handle: SceneHandle,
    state: BridgePlaybackState,
    calls: &[bool],
) {
    engine.trigger_first_frame(handle);
    let (delivered_handle, delivery) = tokio::time::timeout(WATCHDOG, receipts.recv())
        .await
        .expect("the actual first-frame handoff did not complete within the watchdog")
        .expect("the actual first-frame delivery observer remained open");
    assert_eq!(delivered_handle, handle);
    assert_eq!(delivery, ObservedFirstFrameDelivery::Delivered);
    // A matching Delivered receipt follows the genuine target/actor await.
    // Only now may an unchanged vector prove that a callback had no effect.
    assert_power_checkpoint(bridge, engine, state, calls).await;
}

#[tokio::test]
async fn pause_selection_is_public_and_survives_a_separately_opened_store() {
    with_power_bridge(BatteryModeCfg::KeepRunning, None, |root, paths, bridge, engine| {
        Box::pin(async move {
            let reply = bridge
                .set_battery_mode(BridgeBatteryMode::Pause)
                .await
                .expect("select Pause through the public enum API");
            assert_eq!(reply.settings.battery_mode, BridgeBatteryMode::Pause);
            assert_eq!(
                bridge
                    .settings_snapshot()
                    .await
                    .expect("read public saved power selection")
                    .battery_mode,
                BridgeBatteryMode::Pause
            );
            assert_power_reply(bridge, engine, &reply, BridgePlaybackState::Playing, &[]).await;
            let reopened = power_store(root, paths);
            let loaded = reopened.load().expect("load the real separately opened store");
            assert_eq!(loaded.config.power.on_battery, BatteryModeCfg::Pause);
        })
    })
    .await;
}

// This is only a controlled synchronous input to the genuine watcher. It owns
// neither a watcher loop nor an actor, and never samples the operating system.
struct HeldPowerReader {
    hold_reads: AtomicBool,
    released: Mutex<bool>,
    wake: Condvar,
    entered: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    completed: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}

impl HeldPowerReader {
    fn read(&self) -> PowerSource {
        // The constructor's synchronous baseline read, and any ambient reads
        // before caller-visible construction, must return promptly. Holding
        // reads is armed only after the owned builder helper has joined.
        if !self.hold_reads.load(PowerInputOrdering::Acquire) {
            return PowerSource::External;
        }
        if let Some(entered) = self
            .entered
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ = entered.send(());
        }
        let mut released = self
            .released
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        while !*released {
            released = self
                .wake
                .wait(released)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        drop(released);
        if let Some(completed) = self
            .completed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ = completed.send(());
        }
        PowerSource::External
    }

    fn release(&self) {
        *self
            .released
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        self.wake.notify_all();
    }

    fn is_held(&self) -> bool {
        !*self
            .released
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

struct ReleasePowerReader(Arc<HeldPowerReader>);

impl Drop for ReleasePowerReader {
    fn drop(&mut self) {
        self.0.release();
    }
}

#[tokio::test]
async fn watching_builder_completes_then_a_controlled_resample_keeps_the_caller_responsive() {
    let mut root = OwnedRoot::new();
    let paths = root.bridge_paths();
    let store = power_store(&root, &paths);
    let engine = FakeEngineFacade::default();
    let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
    let (completed_tx, completed_rx) = tokio::sync::oneshot::channel();
    let input = Arc::new(HeldPowerReader {
        hold_reads: AtomicBool::new(false),
        released: Mutex::new(false),
        wake: Condvar::new(),
        entered: Mutex::new(Some(entered_tx)),
        completed: Mutex::new(Some(completed_tx)),
    });
    let release_on_unwind = ReleasePowerReader(input.clone());
    let reader: Arc<dyn Fn() -> PowerSource + Send + Sync + 'static> = {
        let input = input.clone();
        Arc::new(move || input.read())
    };
    let build_engine = engine.clone();
    let mut bridge = None;
    let mut builder_work = None;
    let mut resample_work = None;
    root.remove_on_drop = false;

    let result: Result<(), PanicPayload> = AssertUnwindSafe(async {
        let mut config = AppConfig::default();
        config.power.on_battery = BatteryModeCfg::KeepRunning;
        config.power.on_battery_explicit = true;
        store
            .save_app_config(&config)
            .expect("persist explicit KeepRunning before the watching-enabled build");
        builder_work = Some(tokio::task::spawn_blocking(move || {
            let login = crate::api::lifecycle_test_support::inert_login_controller(
                crate::login::LaunchAtLoginStatus::Unavailable,
            );
            BridgeBuilder::new(build_engine)
                .with_paths(paths)
                .with_config_store(store)
                .with_launch_at_login(login)
                .with_mouse_polling_enabled(false)
                .with_power_watching_enabled(true)
                .with_power_reader(reader)
                .build()
        }));
        tokio::time::timeout(WATCHDOG, async {
            let joined = builder_work
                .as_mut()
                .expect("retain ownership of the builder helper")
                .await;
            // Remove the completed JoinHandle before any fallible assertion so
            // unwind cleanup never attempts to poll a completed helper twice.
            let _ = builder_work.take();
            bridge = Some(
                joined
                    .expect("the owned builder helper did not panic")
                    .expect("the watching-enabled real builder returned successfully"),
            );
            assert!(
                input.is_held(),
                "builder completion must precede release of the controlled reader"
            );
            assert_eq!(engine.paused_calls(), Vec::<bool>::new());

            input.hold_reads.store(true, PowerInputOrdering::Release);
            let resample_bridge = bridge.take().expect("own the constructed bridge for resampling");
            resample_work = Some(tokio::task::spawn_blocking(move || {
                resample_bridge.resample_power_source();
                resample_bridge
            }));
            let resampled = resample_work
                .as_mut()
                .expect("retain ownership of the synchronous resample helper")
                .await;
            let _ = resample_work.take();
            bridge = Some(resampled.expect("the owned resample helper did not panic"));
            entered_rx
                .await
                .expect("the real live watcher entered its now-held injected reader");
            assert!(input.is_held(), "reader entry and caller response precede release");
            assert_power_checkpoint(
                bridge.as_ref().expect("the caller owns the resampled bridge"),
                &engine,
                BridgePlaybackState::Playing,
                &[],
            )
            .await;
        })
        .await
        .expect("builder completion, real resample, and caller response exceeded the finite bound");
    })
    .catch_unwind()
    .await;

    // On success, timeout, or unwind release the synchronous dependency BEFORE
    // joining any still-owned builder/resample work or draining its watcher.
    input.release();
    let mut cleanup_errors = Vec::new();
    if let Some(work) = builder_work.take() {
        match work.await {
            Ok(Ok(built)) => bridge = Some(built),
            Ok(Err(error)) => cleanup_errors.push(format!("released builder failed: {error:?}")),
            Err(error) => cleanup_errors.push(format!("released builder helper failed: {error}")),
        }
    }
    if let Some(work) = resample_work.take() {
        match work.await {
            Ok(resampled) => bridge = Some(resampled),
            Err(error) => cleanup_errors.push(format!("released resample helper failed: {error}")),
        }
    }
    if bridge.is_some() {
        match tokio::time::timeout(WATCHDOG, completed_rx).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => cleanup_errors.push(format!("reader completion closed: {error}")),
            Err(error) => cleanup_errors.push(format!("released reader did not finish: {error}")),
        }
    }
    cleanup_errors.extend(drain_power_bridge(bridge.take()).await);
    drop(engine);
    drop(release_on_unwind);
    drop(input);
    finish_power_fixture(root, result, cleanup_errors);
}

#[tokio::test]
async fn saved_pause_and_builder_battery_sample_are_first_frame_and_launch_only() {
    with_power_bridge(
        BatteryModeCfg::Pause,
        Some(PowerSource::Battery),
        |_, _, bridge, engine| {
            Box::pin(async move {
                let mut receipts = frame_receipts(bridge);
                let settings = bridge
                    .settings_snapshot()
                    .await
                    .expect("observe the builder-loaded mode and explicit startup sample");
                assert_eq!(settings.battery_mode, BridgeBatteryMode::Pause);
                assert!(settings.on_battery_power);
                assert_power_checkpoint(bridge, engine, BridgePlaybackState::Playing, &[]).await;

                let launch_handle = SceneHandle::new(517);
                complete_engine_frame(
                    bridge,
                    engine,
                    &mut receipts,
                    launch_handle,
                    BridgePlaybackState::Paused,
                    &[true],
                )
                .await;
                let played = bridge.play_all().await.expect("manually resume after startup pause");
                assert_power_reply(
                    bridge,
                    engine,
                    &played,
                    BridgePlaybackState::Playing,
                    &[true, false],
                )
                .await;

                let later_handle = SceneHandle::new(829);
                assert_ne!(later_handle, launch_handle);
                complete_engine_frame(
                    bridge,
                    engine,
                    &mut receipts,
                    later_handle,
                    BridgePlaybackState::Playing,
                    &[true, false],
                )
                .await;
            })
        },
    )
    .await;
}

#[tokio::test]
async fn selecting_pause_applies_an_already_current_ordinary_battery_source() {
    with_power_bridge(BatteryModeCfg::KeepRunning, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let battery = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(bridge, engine, &battery, BridgePlaybackState::Playing, &[]).await;
            let enabled = bridge
                .set_battery_mode(BridgeBatteryMode::Pause)
                .await
                .expect("enable Pause while the ordinary Battery source is current");
            assert_power_reply(bridge, engine, &enabled, BridgePlaybackState::Paused, &[true]).await;
        })
    })
    .await;
}

#[tokio::test]
async fn ordinary_external_power_resumes_an_ordinary_automatic_pause() {
    with_power_bridge(BatteryModeCfg::KeepRunning, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let enabled = bridge
                .set_battery_mode(BridgeBatteryMode::Pause)
                .await
                .expect("enable Pause before the ordinary transition");
            assert_power_reply(bridge, engine, &enabled, BridgePlaybackState::Playing, &[]).await;
            let battery = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(bridge, engine, &battery, BridgePlaybackState::Paused, &[true]).await;
            let external = power_message(bridge, PowerSource::External, false).await;
            assert_power_reply(
                bridge,
                engine,
                &external,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
        })
    })
    .await;
}

#[tokio::test]
async fn manual_play_requires_a_new_battery_transition_before_another_auto_pause() {
    with_power_bridge(BatteryModeCfg::KeepRunning, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let enabled = bridge
                .set_battery_mode(BridgeBatteryMode::Pause)
                .await
                .expect("enable Pause for the transition ownership sequence");
            assert_power_reply(bridge, engine, &enabled, BridgePlaybackState::Playing, &[]).await;
            let first_battery = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(
                bridge,
                engine,
                &first_battery,
                BridgePlaybackState::Paused,
                &[true],
            )
            .await;
            let played = bridge.play_all().await.expect("send the actual manual Play request");
            assert_power_reply(
                bridge,
                engine,
                &played,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
            let duplicate = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(
                bridge,
                engine,
                &duplicate,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
            let external = power_message(bridge, PowerSource::External, false).await;
            assert_power_reply(
                bridge,
                engine,
                &external,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
            let new_battery = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(
                bridge,
                engine,
                &new_battery,
                BridgePlaybackState::Paused,
                &[true, false, true],
            )
            .await;
        })
    })
    .await;
}

#[tokio::test]
async fn a_real_manual_pause_before_policy_enablement_remains_user_owned() {
    with_power_bridge(BatteryModeCfg::KeepRunning, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let paused = bridge.pause_all().await.expect("send the actual manual Pause request");
            assert_power_reply(bridge, engine, &paused, BridgePlaybackState::Paused, &[true]).await;
            let enabled = bridge
                .set_battery_mode(BridgeBatteryMode::Pause)
                .await
                .expect("enable battery Pause after the manual pause");
            assert_power_reply(bridge, engine, &enabled, BridgePlaybackState::Paused, &[true]).await;
            let battery = power_message(bridge, PowerSource::Battery, false).await;
            assert_power_reply(bridge, engine, &battery, BridgePlaybackState::Paused, &[true]).await;
            let external = power_message(bridge, PowerSource::External, false).await;
            assert_power_reply(bridge, engine, &external, BridgePlaybackState::Paused, &[true]).await;
        })
    })
    .await;
}

#[tokio::test]
async fn an_initial_sample_waits_for_the_actual_explicit_readiness_message() {
    with_power_bridge(BatteryModeCfg::Pause, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let initial = power_message(bridge, PowerSource::Battery, true).await;
            assert_power_reply(bridge, engine, &initial, BridgePlaybackState::Playing, &[]).await;
            let ready = crate::api::lifecycle_test_support::actor(bridge)
                .ask(InitialFrameReady)
                .await
                .expect("the actual explicit first-frame-ready handler completed");
            assert_power_reply(bridge, engine, &ready, BridgePlaybackState::Paused, &[true]).await;
        })
    })
    .await;
}

#[tokio::test]
async fn callback_consumed_initial_pause_does_not_reclaim_manual_play() {
    with_power_bridge(BatteryModeCfg::Pause, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let mut receipts = frame_receipts(bridge);
            let initial = power_message(bridge, PowerSource::Battery, true).await;
            assert_power_reply(bridge, engine, &initial, BridgePlaybackState::Playing, &[]).await;
            let first_handle = SceneHandle::new(1207);
            complete_engine_frame(
                bridge,
                engine,
                &mut receipts,
                first_handle,
                BridgePlaybackState::Paused,
                &[true],
            )
            .await;
            let played = bridge.play_all().await.expect("manually play after the initial callback pause");
            assert_power_reply(
                bridge,
                engine,
                &played,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;

            // The identical handle must produce its own real delivery receipt.
            complete_engine_frame(
                bridge,
                engine,
                &mut receipts,
                first_handle,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
            let duplicate_initial = power_message(bridge, PowerSource::Battery, true).await;
            assert_power_reply(
                bridge,
                engine,
                &duplicate_initial,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;

            let replacement_handle = SceneHandle::new(1873);
            assert_ne!(replacement_handle, first_handle);
            complete_engine_frame(
                bridge,
                engine,
                &mut receipts,
                replacement_handle,
                BridgePlaybackState::Playing,
                &[true, false],
            )
            .await;
        })
    })
    .await;
}

#[tokio::test]
async fn the_first_initial_battery_sample_after_callback_readiness_pauses_immediately() {
    with_power_bridge(BatteryModeCfg::Pause, None, |_, _, bridge, engine| {
        Box::pin(async move {
            let mut receipts = frame_receipts(bridge);
            assert_power_checkpoint(bridge, engine, BridgePlaybackState::Playing, &[]).await;
            complete_engine_frame(
                bridge,
                engine,
                &mut receipts,
                SceneHandle::new(2219),
                BridgePlaybackState::Playing,
                &[],
            )
            .await;
            // No startup override or earlier initial sample exists in this
            // bridge: this is the first actual initial-sample message.
            let first_initial = power_message(bridge, PowerSource::Battery, true).await;
            assert_power_reply(
                bridge,
                engine,
                &first_initial,
                BridgePlaybackState::Paused,
                &[true],
            )
            .await;
        })
    })
    .await;
}
