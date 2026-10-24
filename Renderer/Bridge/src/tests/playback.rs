use std::{sync::Arc, time::Duration};

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
    assert_eq!(engine.paused_calls(), vec![true]);
    assert_eq!(engine.audio_capture_suspend_calls(), vec![true]);

    bridge.set_presentation_suspended(false).await.unwrap();
    assert_eq!(engine.paused_calls(), vec![true, false]);
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
async fn shutdown_facade_retains_live_consumers_on_close_failure() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![active_mouse_display()]);
    let (send, receive) = std::sync::mpsc::channel();
    engine.set_pointer_consumer_callback(Some(Arc::new(move |value| {
        send.send(value).unwrap();
    })));
    assert!(receive.recv().unwrap());
    engine.fail_next_close();
    assert!(engine.close_all_scenes().await.is_err());
    assert!(engine.display_snapshot()[0].accepts_pointer_input);
    assert!(receive.try_recv().is_err());
    engine.close_all_scenes().await.unwrap();
    assert!(!receive.recv().unwrap());
    assert!(engine.display_snapshot()[0].handle.is_none());
}
