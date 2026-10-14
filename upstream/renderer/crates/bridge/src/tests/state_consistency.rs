//! State consistency across previews, mirrors, media and delegated reconciliation.
use crate::{
    actor::state::BridgeActorState,
    api::{BridgeBuilder, WallpaperBridge},
    config::{MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::FakeEngineFacade,
    paths::BridgePaths,
};
use std::{sync::Arc, time::Duration};
use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, project::SceneHandle};

#[tokio::test]
async fn host_startup_completion_applies_battery_pause_and_rejects_stale_identity() {
    for native in [false, true] {
        for ready in [false, true] {
            let home = tempfile::tempdir().unwrap();
            let engine = FakeEngineFacade::default();
            let mut screen = display(7, 1);
            screen.handle = None;
            engine.set_snapshot(vec![screen]);
            let mut state = state();
            state.app_config.power.on_battery = crate::config::BatteryModeCfg::Pause;
            state.apply_startup_power_source(crate::power::PowerSource::Battery);
            let manifest = if native {
                state.app_config.video_backend =
                    crate::config::VideoBackendModeCfg::NativePreferred;
                let project = BridgePaths::for_home(home.path())
                    .steam_workshop_root()
                    .join("100");
                std::fs::create_dir_all(&project).unwrap();
                std::fs::write(project.join("clip.mp4"), b"descriptor metadata only").unwrap();
                r#"{"type":"video","file":"clip.mp4"}"#
            } else {
                r#"{"type":"web","file":"index.html"}"#
            };
            state.project_models.insert(
                "100".into(),
                crate::project::ProjectModel::parse("100", manifest).unwrap(),
            );
            let bridge = build(&engine, state, &home);
            let (revision, key) = if native {
                let descriptor = bridge.native_video_wallpapers().await.unwrap().remove(0);
                (descriptor.startup_revision, Some(descriptor.admission_key))
            } else {
                (
                    bridge.web_wallpapers().await.unwrap()[0].startup_revision,
                    None,
                )
            };
            bridge
                .report_host_wallpaper_startup(7, "100".into(), revision + 1, key, ready)
                .await
                .unwrap();
            bridge
                .report_host_wallpaper_startup(7, "previous-wallpaper".into(), revision, key, ready)
                .await
                .unwrap();
            if let Some(key) = key {
                bridge.report_host_wallpaper_startup(7, "100".into(), revision,
                    Some(key.wrapping_add(1)), ready).await.unwrap();
            }
            assert_eq!(
                bridge.app_snapshot().await.unwrap().playback_state,
                crate::BridgePlaybackState::Playing
            );
            let settled = bridge
                .report_host_wallpaper_startup(7, "100".into(), revision, key, ready)
                .await
                .unwrap();
            assert_eq!(
                settled.app.playback_state,
                crate::BridgePlaybackState::Paused
            );
            bridge.play_all().await.unwrap();
            let repeated = bridge
                .report_host_wallpaper_startup(7, "100".into(), revision, key, ready)
                .await
                .unwrap();
            assert_eq!(
                repeated.app.playback_state,
                crate::BridgePlaybackState::Playing,
                "a later completion cannot override manual resume on battery"
            );
        }
    }
}

#[tokio::test]
async fn empty_bootstrap_does_not_wait_forever_for_a_first_frame() {
    let home = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let mut state = BridgeActorState::default();
    state.app_config.power.on_battery = crate::config::BatteryModeCfg::Pause;
    state.apply_startup_power_source(crate::power::PowerSource::Battery);
    let bridge = build(&engine, state, &home);
    assert_eq!(
        bridge.bootstrap().await.unwrap().app.playback_state,
        crate::BridgePlaybackState::Paused
    );
}

#[tokio::test]
async fn a_reassigned_web_wallpaper_rejects_its_previous_startup_revision() {
    let home = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let mut screen = display(7, 1);
    screen.handle = None;
    engine.set_snapshot(vec![screen]);
    let mut state = state();
    state.app_config.power.on_battery = crate::config::BatteryModeCfg::Pause;
    state.apply_startup_power_source(crate::power::PowerSource::Battery);
    state.project_models.insert("100".into(), crate::project::ProjectModel::parse("100",
        r#"{"type":"web","file":"index.html"}"#).unwrap());
    let bridge = build(&engine, state, &home);
    let previous = bridge.web_wallpapers().await.unwrap().remove(0);
    bridge.eject_wallpaper_from_display("7".into(), "100".into()).await.unwrap();
    bridge.set_display_config_enabled("100".into(), "7".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    let current = bridge.web_wallpapers().await.unwrap().remove(0);
    assert_ne!(previous.startup_revision, current.startup_revision);
    let stale = bridge.report_host_wallpaper_startup(7, "100".into(), previous.startup_revision,
        None, true).await.unwrap();
    assert_eq!(stale.app.playback_state, crate::BridgePlaybackState::Playing);
    let ready = bridge.report_host_wallpaper_startup(7, "100".into(), current.startup_revision,
        None, true).await.unwrap();
    assert_eq!(ready.app.playback_state, crate::BridgePlaybackState::Paused);
}

fn display(id: u32, handle: u64) -> DisplaySnapshotEntry {
    let desc = DisplayDesc::with_identity(id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
        .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: Some(SceneHandle::new(handle)),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}
fn entry(id: &str) -> crate::BridgeWallpaperEntry {
    crate::BridgeWallpaperEntry {
        id: id.into(),
        title: id.into(),
        kind: crate::BridgeWallpaperKind::ProjectScene,
        supported: true,
        active: true,
        selected: false,
        preview_path: None,
    }
}
fn state() -> BridgeActorState {
    let mut s = BridgeActorState::default();
    s.app_config.monitors = vec![MonitorCfg {
        selector: SerializedSelector::Primary,
        wallpaper: Some("100".into()),
        ..Default::default()
    }];
    s.wallpaper_configs
        .insert("100".into(), WallpaperConfig::new_for("100", "scene"));
    s.library = vec![entry("100")];
    s
}
fn build(
    engine: &FakeEngineFacade,
    s: BridgeActorState,
    home: &tempfile::TempDir,
) -> WallpaperBridge {
    BridgeBuilder::new(engine.clone())
        .with_state(s)
        .with_paths(BridgePaths::for_home(home.path()))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .unwrap()
}
#[tokio::test]
async fn cancel_restores_live_scaling() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 1)]);
    let b = build(&e, state(), &home);
    b.edit_scaling_factor("100".into(), "7".into(), 1.5)
        .await
        .unwrap();
    let s = b.cancel_wallpaper_options("100".into()).await.unwrap();
    assert_eq!(
        s.wallpaper_options.display_configurations[0].scaling_factor,
        1.0
    );
    assert_eq!(
        e.scaling_factor_calls().last().map(|v| v.1),
        Some(1.0),
        "Cancel restored the editor but left the live renderer at its preview factor"
    );
}
#[tokio::test]
async fn mirror_does_not_forward_old_wallpaper_volume() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 11), display(9, 12)]);
    let mut s = state();
    s.library.push(entry("200"));
    s.wallpaper_configs
        .insert("200".into(), WallpaperConfig::new_for("200", "scene"));
    s.app_config.monitors.push(MonitorCfg {
        selector: SerializedSelector::LiveDisplayId { display_id: 9 },
        mode: "mirror".into(),
        wallpaper: Some("200".into()),
        mirror_target: Some(SerializedSelector::Primary),
        ..Default::default()
    });
    let b = build(&e, s, &home);
    b.set_volume("200".into(), 0.2).await.unwrap();
    assert_eq!(
        b.monitor_information_snapshot()
            .await
            .unwrap()
            .rows
            .iter()
            .find(|row| row.mirror_target_display_id.is_some())
            .unwrap()
            .wallpaper_id,
        "100"
    );
    assert!(
        e.audio_volume_calls().is_empty(),
        "Old independent wallpaper's control reached the new mirrored scene: {:?}",
        e.audio_volume_calls()
    );
}
#[tokio::test]
async fn stale_media_not_sent_to_running_scene() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 11)]);
    let mut s = state();
    s.wallpaper_configs
        .get_mut("100")
        .unwrap()
        .media_integration_enabled = true;
    let b = build(&e, s, &home);
    b.submit_system_media_event(
        r#"{"type":"mediaPropertiesChanged","generation":7,"title":"New"}"#.into(),
    )
    .await
    .unwrap();
    b.submit_system_media_event(
        r#"{"type":"mediaPropertiesChanged","generation":6,"title":"Old"}"#.into(),
    )
    .await
    .unwrap();
    assert!(b.current_system_media_state().unwrap().contains("New"));
    assert_eq!(
        e.media_event_calls().len(),
        1,
        "Replay rejected stale generation, live fanout did not"
    );
}
#[tokio::test]
async fn battery_fps_caps_web_and_native_descriptors() {
    let home = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 1), display(9, 2)]);
    let mut s = state();
    s.power_source = crate::power::PowerSource::Battery;
    s.app_config.power.on_battery = crate::config::BatteryModeCfg::ReducedQuality;
    s.app_config.quality.battery.target_fps = 24;
    s.app_config.video_backend = crate::config::VideoBackendModeCfg::NativePreferred;
    s.project_models.insert(
        "100".into(),
        crate::project::ProjectModel::parse("100", r#"{"type":"web","file":"index.html"}"#)
            .unwrap(),
    );
    s.wallpaper_configs
        .insert("200".into(), WallpaperConfig::new_for("200", "video"));
    s.library.push(entry("200"));
    s.project_models.insert(
        "200".into(),
        crate::project::ProjectModel::parse("200", r#"{"type":"video","file":"clip.mp4"}"#)
            .unwrap(),
    );
    s.app_config.monitors.push(MonitorCfg {
        selector: SerializedSelector::LiveDisplayId { display_id: 9 },
        wallpaper: Some("200".into()),
        ..Default::default()
    });
    let video = paths.steam_workshop_root().join("200");
    std::fs::create_dir_all(&video).unwrap();
    std::fs::write(video.join("clip.mp4"), b"metadata fixture only").unwrap();
    let b = build(&e, s, &home);
    let web = b.web_wallpapers().await.unwrap();
    let native = b.native_video_wallpapers().await.unwrap();
    assert_eq!(
        (web[0].fps, native[0].fps, native[0].admission_fps),
        (24, 24, 24),
        "Host descriptors ignored effective battery ceiling"
    );
    b.set_frame_rate_cap(Some(15)).await.unwrap();
    assert_eq!(b.web_wallpapers().await.unwrap()[0].fps, 15);
    assert_eq!(
        b.native_video_wallpapers().await.unwrap()[0].admission_fps,
        15
    );
    b.set_power_source_for_test(crate::power::PowerSource::External)
        .await;
    b.set_frame_rate_cap(None).await.unwrap();
    assert_eq!(b.web_wallpapers().await.unwrap()[0].fps, 60);
    assert_eq!(b.native_video_wallpapers().await.unwrap()[0].fps, 60);
}
#[tokio::test]
async fn scene_audio_enable_recomputes_demand() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 1)]);
    let mut s = state();
    s.wallpaper_configs
        .get_mut("100")
        .unwrap()
        .audio
        .response_enabled = false;
    let b = build(&e, s, &home);
    b.set_presentation_suspended(true).await.unwrap();
    b.set_presentation_suspended(false).await.unwrap();
    assert!(e.audio_capture_suspended());
    b.set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(
        e.audio_capture_calls().last(),
        Some(&(SceneHandle::new(1), true))
    );
    assert!(
        !e.audio_capture_suspended(),
        "Enabled scene registration never reopened the global capture gate"
    );
    assert!(super::web_audio_media::tap_open_for_scenes(
        &e,
        &[SceneHandle::new(1)]
    ));
    b.set_audio_response_enabled("100".into(), false)
        .await
        .unwrap();
    assert!(!super::web_audio_media::tap_open_for_scenes(
        &e,
        &[SceneHandle::new(1)]
    ));
}
#[tokio::test]
async fn video_backend_survives_older_apply_completion() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 1)]);
    let b = Arc::new(build(&e, state(), &home));
    b.inject_scene_wallpaper_config_for_test("200", "Next")
        .await;
    b.set_display_config_enabled("200".into(), "7".into(), true)
        .await
        .unwrap();
    let gate = e.block_next_reconcile();
    let other = b.clone();
    let job = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(other.apply_wallpaper_options("200".into(), true))
    });
    assert!(gate.wait_until_blocked(Duration::from_secs(2)));
    b.set_video_backend("native_preferred".into())
        .await
        .unwrap();
    gate.release();
    job.join().unwrap().unwrap();
    assert_eq!(
        b.settings_snapshot().await.unwrap().video_backend,
        "native_preferred",
        "Older Apply overwrote newer video backend preference"
    );
}
#[tokio::test]
async fn failed_repair_does_not_block_future_repairs() {
    let home = tempfile::tempdir().unwrap();
    let e = FakeEngineFacade::default();
    e.set_snapshot(vec![display(7, 1)]);
    let b = Arc::new(build(&e, state(), &home));
    b.inject_scene_wallpaper_config_for_test("200", "Next")
        .await;
    b.set_display_config_enabled("200".into(), "7".into(), true)
        .await
        .unwrap();
    e.fail_reconcile_with("review transient failure");
    assert!(b.apply_wallpaper_options("200".into(), true).await.is_err());
    tokio::time::timeout(Duration::from_secs(2), async {
        while b.app_snapshot().await.unwrap().errors.len() < 2 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("failed repair must finish");
    e.clear_reconcile_failure();
    let before = e.calls().len();
    let gate = e.block_next_reconcile();
    let other = b.clone();
    let job = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(other.apply_wallpaper_options("200".into(), true))
    });
    assert!(gate.wait_until_blocked(Duration::from_secs(2)));
    b.pause_all().await.unwrap();
    gate.release();
    job.join().unwrap().unwrap();
    for _ in 0..100 {
        if e.calls().len() > before + 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    assert!(
        e.calls().len() > before + 1,
        "The failed restore's active-generation latch prevented the next required repair: before={before}, after={}",
        e.calls().len()
    );
}
