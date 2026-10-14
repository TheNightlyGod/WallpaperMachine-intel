use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use arc_swap::ArcSwap;
use futures_util::future::{BoxFuture, FutureExt};
use wallpaper_core::{
    DisplaySelector, DisplaySnapshotEntry, EngineError, FirstFrameCallback, PropertyPreview,
    WallpaperAssignment,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult},
};

use super::api_smoke::{
    active_mouse_display, assert_mouse_idle, await_mouse_sample, mouse_scenario,
};
use crate::{
    BridgePlaybackState,
    api::BridgeBuilder,
    engine::{EngineFacade, FakeEngineFacade},
};

#[test]
fn mouse_polling_manual_pause_survives_presentation_resume() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        await_mouse_sample(&engine);
        bridge.pause_all().await.unwrap();
        assert_mouse_idle(&engine);
        bridge.set_presentation_suspended(true).await.unwrap();
        bridge.set_presentation_suspended(false).await.unwrap();
        assert_mouse_idle(&engine);
        assert_eq!(
            bridge.app_snapshot().await.unwrap().playback_state,
            BridgePlaybackState::Paused
        );
        bridge.play_all().await.unwrap();
        await_mouse_sample(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_survives_renderer_pause_failure() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        await_mouse_sample(&engine);
        engine.fail_next_pause();
        assert!(bridge.pause_all().await.is_err());
        // Still armed: the next move is sampled.
        engine.simulate_pointer_input();
        await_mouse_sample(&engine);
        assert_eq!(
            bridge.app_snapshot().await.unwrap().playback_state,
            BridgePlaybackState::Playing
        );
        bridge.pause_all().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_preserves_confirmed_state_after_audio_pause_and_resume_failures() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        await_mouse_sample(&engine);
        engine.fail_next_suspend();
        assert!(bridge.set_presentation_suspended(true).await.is_err());
        await_mouse_sample(&engine);
        bridge.set_presentation_suspended(true).await.unwrap();
        assert_mouse_idle(&engine);
        engine.fail_next_suspend();
        assert!(bridge.set_presentation_suspended(false).await.is_err());
        assert_mouse_idle(&engine);
        bridge.set_presentation_suspended(false).await.unwrap();
        await_mouse_sample(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_recovers_after_shutdown_audio_failure_and_stops_after_success() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        await_mouse_sample(&engine);
        engine.fail_next_disable_capture();
        assert!(bridge.shutdown().await.is_err());
        await_mouse_sample(&engine);
        bridge.shutdown().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_recovers_after_shutdown_close_failure_but_not_when_paused() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        await_mouse_sample(&engine);
        engine.fail_next_close();
        assert!(bridge.shutdown().await.is_err());
        await_mouse_sample(&engine);
        bridge.pause_all().await.unwrap();
        engine.fail_next_close();
        assert!(bridge.shutdown().await.is_err());
        assert_mouse_idle(&engine);
        bridge.play_all().await.unwrap();
        await_mouse_sample(&engine);
        engine.set_snapshot(Vec::new());
        engine.fail_next_close();
        assert!(bridge.shutdown().await.is_err());
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

enum MouseReconcilePath {
    Configured,
    ShaderCache,
    Restore,
}

fn assert_mouse_polling_after_reconcile_error(path: MouseReconcilePath) {
    mouse_scenario(move || async move {
        let root = tempfile::tempdir().unwrap();
        let engine = FakeEngineFacade::default();
        let mut display = active_mouse_display();
        display.handle = None;
        display.accepts_pointer_input = false;
        engine.set_snapshot(vec![display]);
        let mut state = crate::actor::state::BridgeActorState::default();
        state.app_config.monitors = vec![crate::config::MonitorCfg {
            selector: crate::config::SerializedSelector::Primary,
            enabled: true,
            mode: "independent".into(),
            wallpaper: Some("100".into()),
            mirror_target: None,
        }];
        state.wallpaper_configs.insert(
            "100".into(),
            crate::config::WallpaperConfig::new_for("100", "scene"),
        );
        let bridge = Arc::new(
            BridgeBuilder::new(engine.clone())
                .with_state(state)
                .with_paths(crate::paths::BridgePaths::for_home(root.path()))
                .build()
                .unwrap(),
        );
        assert_mouse_idle(&engine);
        engine.fail_audio_capture_with(Some("capture failed after scene creation".into()));
        let audio = engine.block_next_audio_capture();
        let restore_audio =
            matches!(path, MouseReconcilePath::Restore).then(|| engine.block_next_audio_capture());
        let display_id = bridge.settings_snapshot().await.unwrap().displays[0]
            .display_id
            .clone();
        let operation_bridge = Arc::clone(&bridge);
        let (done, result) = std::sync::mpsc::channel();
        let operation = std::thread::spawn(move || {
            let outcome = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    match path {
                        MouseReconcilePath::Configured => {
                            operation_bridge.refresh_displays().await.map(|_| ())
                        }
                        MouseReconcilePath::ShaderCache => {
                            operation_bridge.clear_shader_cache().await.map(|_| ())
                        }
                        MouseReconcilePath::Restore => operation_bridge
                            .set_display_enabled(display_id, true)
                            .await
                            .map(|_| ()),
                    }
                });
            let _ = done.send(outcome);
        });
        let reached_audio = audio.wait_until_blocked(Duration::from_secs(1));
        if restore_audio.is_none() {
            // Rendering is already live when the later audio operation fails.
            engine.set_snapshot(vec![active_mouse_display()]);
        }
        audio.release();
        if !reached_audio {
            let outcome = result.recv_timeout(Duration::from_secs(1));
            operation.join().unwrap();
            panic!("reconciliation did not reach audio synchronization: {outcome:?}");
        }
        if let Some(restore_audio) = restore_audio {
            let reached_restore = restore_audio.wait_until_blocked(Duration::from_secs(1));
            engine.set_snapshot(vec![active_mouse_display()]);
            restore_audio.release();
            assert!(
                reached_restore,
                "failed mutation must reconcile committed state"
            );
        }
        assert!(
            result
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .is_err()
        );
        operation.join().unwrap();
        await_mouse_sample(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_tracks_handles_after_configured_reconcile_error() {
    assert_mouse_polling_after_reconcile_error(MouseReconcilePath::Configured);
}

#[test]
fn mouse_polling_tracks_handles_after_shader_cache_reconcile_error() {
    assert_mouse_polling_after_reconcile_error(MouseReconcilePath::ShaderCache);
}

#[test]
fn mouse_polling_tracks_handles_after_restore_reconcile_error() {
    assert_mouse_polling_after_reconcile_error(MouseReconcilePath::Restore);
}

#[tokio::test]
async fn pause_and_play_update_global_snapshot_state_and_engine() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.pause_all().await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    wait_for_paused_calls(&engine, &[true]);

    bridge.play_all().await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
    wait_for_paused_calls(&engine, &[true, false]);
}

#[tokio::test]
async fn failed_pause_keeps_playback_state_unchanged() {
    let engine = FailingPlaybackEngine;
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    let error = bridge
        .pause_all()
        .await
        .expect_err("pause should report engine failure");

    assert!(error.message().contains("pause failed"));
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing
    );
}

#[tokio::test]
async fn presentation_suspension_pauses_without_changing_playback_state() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.set_presentation_suspended(true).await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing,
        "suspension is a system condition, not the user's Play/Pause choice"
    );
    wait_for_paused_calls(&engine, &[true]);
    assert_eq!(engine.audio_capture_suspend_calls(), vec![true]);

    bridge.set_presentation_suspended(false).await.unwrap();
    wait_for_paused_calls(&engine, &[true, false]);
    // No wallpaper is configured here, so nothing consumes system audio and
    // resuming presentation must not start the capture tap. Audio follows the
    // visible consumers, not the pause flag.
    assert_eq!(engine.audio_capture_suspend_calls(), vec![true, true]);
}

#[tokio::test]
async fn resuming_presentation_keeps_a_manual_pause() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.pause_all().await.unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    assert_eq!(
        engine.paused_calls().last().copied(),
        Some(true),
        "a manually paused wallpaper must stay paused after the screen wakes"
    );
}

#[tokio::test]
async fn shutdown_closes_all_engine_scenes() {
    let engine = ShutdownEngine::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.shutdown().await.unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let calls = engine.close_calls();
        if calls == 1 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected close calls 1, got {calls}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[tokio::test]
async fn shutdown_disables_audio_capture_before_closing_scenes() {
    let engine = ShutdownEngine::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        identity: wallpaper_core::DisplayIdentity::default(),
        desc: wallpaper_core::DisplayDesc::new(7, 0, 0, 1920, 1080, 1.0),
        handle: Some(SceneHandle::new(42)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            wallpaper_core::project::SceneTemplate::builder("/tmp/project.json")
                .audio_response_enabled(true)
                .build()
                .expect("template should build"),
        )),
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.shutdown().await.unwrap();

    assert_eq!(
        engine.events(),
        vec![
            ShutdownEvent::AudioCapture(SceneHandle::new(42), false),
            ShutdownEvent::CloseAll,
        ]
    );
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

#[derive(Clone)]
struct FailingPlaybackEngine;

impl EngineFacade for FailingPlaybackEngine {
    fn set_audio_capture_demand(
        &self,
        _demand: crate::engine::AudioCaptureDemand,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn set_user_shortcut_callback(
        &self,
        _callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
    }

    // Every scene reads audio here, as in `FakeEngineFacade` by default.
    fn scene_requires_audio(&self, _handle: SceneHandle) -> bool { true }

    fn set_audio_requirement_callback(
        &self,
        _callback: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
    }

    fn update_media(&self, _handle: SceneHandle, _enabled: bool, _state: wallpaper_core::media::MediaPollResult) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }
    fn reconcile_scenes(
        &self,
        _scenes: Vec<SceneDesc>,
    ) -> BoxFuture<'static, Result<Vec<SceneResult>, EngineError>> {
        async move { Ok(Vec::new()) }.boxed()
    }

    fn refresh_displays(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        Vec::new()
    }

    fn close_all_scenes(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn set_display_paused(
        &self,
        _display_id: u32,
        _paused: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn set_all_paused(
        &self,
        _paused: bool,
        _suspended_displays: Vec<u32>,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Err(EngineError::Platform("pause failed".to_string())) }.boxed()
    }

    fn set_audio_volume(
        &self,
        _handle: SceneHandle,
        _volume: AudioVolume,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_muted(
        &self,
        _handle: SceneHandle,
        _muted: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_response_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_media_integration_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_capture_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_scaling_mode(
        &self,
        _handle: SceneHandle,
        _mode: ScalingMode,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_scaling_factor(
        &self,
        _handle: SceneHandle,
        _factor: f64,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_framing(
        &self,
        _handle: SceneHandle,
        _framing: SceneFraming,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn preview_framing(
        &self,
        _handle: SceneHandle,
        _framing: SceneFraming,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn preview_property_override(
        &self,
        _handle: SceneHandle,
        _scene_path: String,
        _flat_json: String,
    ) -> BoxFuture<'static, Result<PropertyPreview, EngineError>> {
        async move { Ok(PropertyPreview::Shown) }.boxed()
    }

    fn set_fps(
        &self,
        _handle: SceneHandle,
        _fps: u32,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_render_scale(
        &self,
        _handle: SceneHandle,
        _scale: f32,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn poll_mouse_position(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_position(
        &self,
        _handle: SceneHandle,
        _x: f64,
        _y: f64,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_button(
        &self,
        _handle: SceneHandle,
        _button: u32,
        _pressed: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_entered(
        &self,
        _handle: SceneHandle,
        _entered: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn create_window_for_display(
        &self,
        _selector: DisplaySelector,
    ) -> BoxFuture<'static, Result<Option<SceneHandle>, EngineError>> {
        async move { Ok::<Option<SceneHandle>, EngineError>(None) }.boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        _selector: DisplaySelector,
        _assignment: WallpaperAssignment,
    ) -> BoxFuture<'static, Result<Option<SceneHandle>, EngineError>> {
        async move { Ok::<Option<SceneHandle>, EngineError>(None) }.boxed()
    }

    fn set_first_frame_callback(&self, _callback: FirstFrameCallback) {}

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        if let Some(callback) = callback {
            callback(false);
        }
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        if let Some(callback) = callback {
            callback(wallpaper_core::PointerActivity::MonitorGap(false));
        }
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        wallpaper_core::PointerProbe::default()
    }
}

#[derive(Clone, Default)]
struct ShutdownEngine {
    close_calls: Arc<AtomicUsize>,
    fake: FakeEngineFacade,
    events: Arc<ArcSwap<Vec<ShutdownEvent>>>,
}

impl ShutdownEngine {
    fn close_calls(&self) -> usize {
        self.close_calls.load(Ordering::SeqCst)
    }

    fn set_snapshot(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        self.fake.set_snapshot(snapshot);
    }

    fn events(&self) -> Vec<ShutdownEvent> {
        self.events.load_full().as_ref().clone()
    }

    #[allow(clippy::needless_pass_by_value)]
    fn push_event(&self, event: ShutdownEvent) {
        self.events.rcu(|current| {
            let mut next = current.as_ref().clone();
            next.push(event.clone());
            next
        });
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ShutdownEvent {
    AudioCapture(SceneHandle, bool),
    CloseAll,
}

impl EngineFacade for ShutdownEngine {
    fn set_audio_capture_demand(
        &self,
        _demand: crate::engine::AudioCaptureDemand,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn set_user_shortcut_callback(
        &self,
        _callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
    }

    // Every scene reads audio here, as in `FakeEngineFacade` by default.
    fn scene_requires_audio(&self, _handle: SceneHandle) -> bool { true }

    fn set_audio_requirement_callback(
        &self,
        _callback: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
    }

    fn update_media(&self, handle: SceneHandle, enabled: bool, state: wallpaper_core::media::MediaPollResult) -> BoxFuture<'static, Result<(), EngineError>> {
        self.fake.update_media(handle, enabled, state)
    }
    fn reconcile_scenes(
        &self,
        _scenes: Vec<SceneDesc>,
    ) -> BoxFuture<'static, Result<Vec<SceneResult>, EngineError>> {
        async move { Ok(Vec::new()) }.boxed()
    }

    fn refresh_displays(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.fake.display_snapshot()
    }

    fn close_all_scenes(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        let engine = self.clone();
        async move {
            engine.close_calls.fetch_add(1, Ordering::SeqCst);
            engine.push_event(ShutdownEvent::CloseAll);
            engine.fake.close_all_scenes().await
        }
        .boxed()
    }

    fn set_display_paused(
        &self,
        _display_id: u32,
        _paused: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok(()) }.boxed()
    }

    fn set_all_paused(
        &self,
        _paused: bool,
        _suspended_displays: Vec<u32>,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_volume(
        &self,
        _handle: SceneHandle,
        _volume: AudioVolume,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_muted(
        &self,
        _handle: SceneHandle,
        _muted: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_response_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_media_integration_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_audio_capture_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        let engine = self.clone();
        async move {
            engine.push_event(ShutdownEvent::AudioCapture(handle, enabled));
            Ok::<(), EngineError>(())
        }
        .boxed()
    }

    fn set_scaling_mode(
        &self,
        _handle: SceneHandle,
        _mode: ScalingMode,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_scaling_factor(
        &self,
        _handle: SceneHandle,
        _factor: f64,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_framing(
        &self,
        _handle: SceneHandle,
        _framing: SceneFraming,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn preview_framing(
        &self,
        _handle: SceneHandle,
        _framing: SceneFraming,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn preview_property_override(
        &self,
        _handle: SceneHandle,
        _scene_path: String,
        _flat_json: String,
    ) -> BoxFuture<'static, Result<PropertyPreview, EngineError>> {
        async move { Ok(PropertyPreview::Shown) }.boxed()
    }

    fn set_fps(
        &self,
        _handle: SceneHandle,
        _fps: u32,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_render_scale(
        &self,
        _handle: SceneHandle,
        _scale: f32,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn poll_mouse_position(&self) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_position(
        &self,
        _handle: SceneHandle,
        _x: f64,
        _y: f64,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_button(
        &self,
        _handle: SceneHandle,
        _button: u32,
        _pressed: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn set_mouse_entered(
        &self,
        _handle: SceneHandle,
        _entered: bool,
    ) -> BoxFuture<'static, Result<(), EngineError>> {
        async move { Ok::<(), EngineError>(()) }.boxed()
    }

    fn create_window_for_display(
        &self,
        _selector: DisplaySelector,
    ) -> BoxFuture<'static, Result<Option<SceneHandle>, EngineError>> {
        async move { Ok::<Option<SceneHandle>, EngineError>(None) }.boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        _selector: DisplaySelector,
        _assignment: WallpaperAssignment,
    ) -> BoxFuture<'static, Result<Option<SceneHandle>, EngineError>> {
        async move { Ok::<Option<SceneHandle>, EngineError>(None) }.boxed()
    }

    fn set_first_frame_callback(&self, _callback: FirstFrameCallback) {}

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.fake.set_pointer_consumer_callback(callback);
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        self.fake.set_pointer_activity_callback(callback);
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        self.fake.probe_pointer()
    }
}

#[tokio::test]
async fn shutdown_facade_retains_live_consumers_on_close_failure() {
    let engine = ShutdownEngine::default();
    engine.set_snapshot(vec![active_mouse_display()]);
    let (send, receive) = std::sync::mpsc::channel();
    engine.set_pointer_consumer_callback(Some(Arc::new(move |value| {
        send.send(value).unwrap();
    })));
    assert!(receive.recv().unwrap());
    engine.fake.fail_next_close();
    assert!(engine.close_all_scenes().await.is_err());
    assert!(engine.display_snapshot()[0].accepts_pointer_input);
    assert!(receive.try_recv().is_err());
    engine.close_all_scenes().await.unwrap();
    assert!(!receive.recv().unwrap());
    assert!(engine.display_snapshot()[0].handle.is_none());
}
