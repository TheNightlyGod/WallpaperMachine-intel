//! Quality and video-backend settings.
//!
//! Three properties matter here. A render scale the user chooses has to reach
//! the scenes that are already running, without a reconcile — a quality slider
//! that reparses projects and reopens video is not a quality slider. A power
//! profile may lower what is running but must never overwrite what the user
//! saved, and turning it off has to hand the saved values back rather than some
//! constant. And a backend report has to describe what is actually rendering,
//! with a reason attached only where the user asked for something and did not
//! get it.

use std::fs;

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, project::SceneHandle};

use crate::{
    BridgeSettingsSnapshot, api::BridgeBuilder, engine::FakeEngineFacade, paths::BridgePaths,
    power::PowerSource,
};

fn display_with_scene(display_id: u32, handle: u64) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
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

/// A bridge over a workshop tree holding one scene project and one video
/// project whose media file exists.
fn bridge_with(engine: &FakeEngineFacade, temp: &tempfile::TempDir) -> crate::api::WallpaperBridge {
    let paths = BridgePaths::for_home(temp.path().to_path_buf());

    let video = paths.steam_workshop_root().join("300");
    fs::create_dir_all(&video).unwrap();
    fs::write(
        video.join("project.json"),
        r#"{"type":"video","title":"Clip 300","file":"clip.mp4","description":""}"#,
    )
    .unwrap();
    fs::write(video.join("clip.mp4"), b"presence is all that is read here").unwrap();

    let scene = paths.steam_workshop_root().join("100");
    fs::create_dir_all(&scene).unwrap();
    fs::write(
        scene.join("project.json"),
        r#"{"type":"scene","title":"Scene 100","file":"scene.pkg","description":""}"#,
    )
    .unwrap();

    BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap()
}

/// Puts a wallpaper of the given project type on one display.
async fn commit(
    bridge: &crate::api::WallpaperBridge,
    wallpaper: &str,
    project_type: &str,
    display: &str,
) {
    bridge
        .inject_scene_project_for_test(
            wallpaper,
            "Wallpaper",
            &format!(
                r#"{{"type":"{project_type}","title":"Wallpaper {wallpaper}","file":"clip.mp4","description":""}}"#
            ),
        )
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, "Wallpaper")
        .await;
    bridge
        .set_display_config_enabled(wallpaper.into(), display.into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options(wallpaper.into(), true)
        .await
        .unwrap();
}

async fn settings(bridge: &crate::api::WallpaperBridge) -> BridgeSettingsSnapshot {
    bridge.settings_snapshot().await.unwrap()
}

fn last_render_scale(engine: &FakeEngineFacade) -> f32 {
    engine
        .render_scale_calls()
        .last()
        .expect("a render scale change must reach the renderer")
        .1
}

#[tokio::test]
async fn render_scale_reaches_every_open_scene_without_a_reconcile() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1), display_with_scene(9, 2)]);
    let bridge = bridge_with(&engine, &temp);

    let reconciles_before = engine.calls().len();
    let snapshot = bridge.set_render_scale(0.5).await.unwrap().settings;

    assert_eq!(
        engine.render_scale_calls(),
        vec![(SceneHandle::new(1), 0.5), (SceneHandle::new(2), 0.5)]
    );
    assert_eq!(
        engine.calls().len(),
        reconciles_before,
        "changing the render scale must not rebuild the scene list"
    );
    assert_eq!(snapshot.render_scale, 0.5);
    assert_eq!(snapshot.preferred_render_scale, 0.5);
}

#[tokio::test]
async fn render_scale_below_the_supported_floor_is_clamped() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);

    let snapshot = bridge.set_render_scale(0.01).await.unwrap().settings;

    assert_eq!(last_render_scale(&engine), 0.25);
    assert_eq!(snapshot.preferred_render_scale, 0.25);
}

#[tokio::test]
async fn battery_profile_lowers_what_runs_and_restores_the_saved_values() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);
    commit(&bridge, "100", "scene", "7").await;
    bridge.set_render_scale(0.9).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;

    bridge
        .set_battery_mode(crate::BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    let on_profile = bridge
        .set_battery_quality_profile(0.5, 30)
        .await
        .unwrap()
        .settings;

    assert_eq!(on_profile.render_scale, 0.5);
    assert_eq!(
        on_profile.preferred_render_scale, 0.9,
        "a power profile must not overwrite what the user saved"
    );
    assert!(on_profile.on_battery_power);
    assert_eq!(last_render_scale(&engine), 0.5);
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(30),
        "the profile's rate must reach the running scene"
    );

    let off_profile = bridge
        .set_battery_mode(crate::BridgeBatteryMode::KeepRunning)
        .await
        .unwrap()
        .settings;

    assert_eq!(off_profile.render_scale, 0.9);
    assert_eq!(last_render_scale(&engine), 0.9);
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(60),
        "restoring must hand back the display's own configured rate"
    );
}

#[tokio::test]
async fn battery_profile_left_off_changes_nothing_on_a_power_transition() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);
    commit(&bridge, "100", "scene", "7").await;
    let fps_before = engine.fps_calls().len();
    let scales_before = engine.render_scale_calls().len();

    bridge.set_power_source_for_test(PowerSource::Battery).await;

    assert_eq!(engine.fps_calls().len(), fps_before);
    assert_eq!(engine.render_scale_calls().len(), scales_before);
}

#[tokio::test]
async fn render_scale_is_unsupported_when_only_a_video_wallpaper_runs() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);

    commit(&bridge, "300", "video", "7").await;
    assert!(!settings(&bridge).await.render_scale_supported);

    commit(&bridge, "100", "scene", "7").await;
    assert!(settings(&bridge).await.render_scale_supported);
}

#[tokio::test]
async fn render_scale_is_supported_when_a_web_wallpaper_runs() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);

    commit(&bridge, "300", "video", "7").await;
    assert!(
        !settings(&bridge).await.render_scale_supported,
        "a lone video still has nothing to rescale"
    );

    commit(&bridge, "400", "web", "7").await;
    assert!(
        settings(&bridge).await.render_scale_supported,
        "a web page takes the scale through its devicePixelRatio"
    );
}

#[tokio::test]
async fn video_backend_report_names_the_running_backend_and_only_real_fallbacks() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);
    commit(&bridge, "300", "video", "7").await;

    let compatibility = settings(&bridge).await;
    assert_eq!(compatibility.video_backend, "compatibility");
    assert_eq!(compatibility.video_backends.len(), 1);
    assert_eq!(compatibility.video_backends[0].display_id, 7);
    assert_eq!(compatibility.video_backends[0].wallpaper_id, "300");
    assert_eq!(compatibility.video_backends[0].backend, "legacy");
    assert_eq!(
        compatibility.video_backends[0].fallback_reason, None,
        "the scene engine is not a fallback when it is what the user chose"
    );

    let native = bridge
        .set_video_backend("native_preferred".into())
        .await
        .unwrap()
        .settings;
    assert_eq!(native.video_backend, "native_preferred");
    assert_eq!(native.video_backends[0].backend, "native");
    assert_eq!(native.video_backends[0].fallback_reason, None);

    let key = bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == "300")
        .expect("the wallpaper has to be offered natively before it can be refused")
        .admission_key;
    bridge
        .reject_native_video("300".into(), key, "codec the player cannot decode".into())
        .await
        .unwrap();

    let refused = settings(&bridge).await;
    assert_eq!(refused.video_backends[0].backend, "legacy");
    assert_eq!(
        refused.video_backends[0].fallback_reason.as_deref(),
        Some("codec the player cannot decode")
    );
}

#[tokio::test]
async fn battery_video_backend_report_preserves_native_rejection() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = bridge_with(&engine, &temp);
    commit(&bridge, "300", "video", "7").await;

    let compatibility = settings(&bridge).await;
    assert_eq!(compatibility.video_backend, "compatibility");
    assert_eq!(compatibility.video_backends.len(), 1);
    assert_eq!(compatibility.video_backends[0].display_id, 7);
    assert_eq!(compatibility.video_backends[0].wallpaper_id, "300");
    assert_eq!(compatibility.video_backends[0].backend, "legacy");
    assert_eq!(
        compatibility.video_backends[0].fallback_reason, None,
        "the scene engine is not a fallback when it is what the user chose"
    );

    let native = bridge
        .set_video_backend("native_preferred".into())
        .await
        .unwrap()
        .settings;
    assert_eq!(native.video_backend, "native_preferred");
    assert_eq!(native.video_backends[0].backend, "native");
    assert_eq!(native.video_backends[0].fallback_reason, None);

    bridge.set_battery_quality_profile(0.5, 24).await.unwrap();
    bridge.set_battery_mode(crate::BridgeBatteryMode::ReducedQuality).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert_eq!(bridge.native_video_wallpapers().await.unwrap()[0].admission_fps, 24);

    let key = bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == "300")
        .expect("the wallpaper has to be offered natively before it can be refused")
        .admission_key;
    bridge
        .reject_native_video("300".into(), key, "codec the player cannot decode".into())
        .await
        .unwrap();

    let refused = settings(&bridge).await;
    assert_eq!(refused.video_backends[0].backend, "legacy");
    assert_eq!(
        refused.video_backends[0].fallback_reason.as_deref(),
        Some("codec the player cannot decode")
    );
}

#[tokio::test]
async fn unknown_video_backend_mode_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = bridge_with(&engine, &temp);

    let error = bridge
        .set_video_backend("turbo".into())
        .await
        .expect_err("only the two declared modes exist");

    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);
}

#[tokio::test]
async fn shared_video_decode_counts_come_from_the_renderer() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = bridge_with(&engine, &temp);
    engine.set_shared_video_decode_counts(1, 3);

    let snapshot = bridge
        .set_shared_video_decode_enabled(true)
        .await
        .unwrap()
        .settings;

    assert!(snapshot.shared_video_decode_enabled);
    assert_eq!(snapshot.shared_video_decode_sessions, 1);
    assert_eq!(
        snapshot.shared_video_decode_consumers, 3,
        "sharing is consumers exceeding sessions, not the setting being on"
    );
}

#[tokio::test]
async fn content_pacing_is_reported_from_the_renderer_not_the_preference() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = bridge_with(&engine, &temp);

    assert!(!settings(&bridge).await.content_pacing_enabled);

    let snapshot = bridge
        .set_content_pacing_enabled(true)
        .await
        .unwrap()
        .settings;

    assert!(snapshot.content_pacing_enabled);
}
