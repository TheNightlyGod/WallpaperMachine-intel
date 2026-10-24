//! Battery mode, the global frame-rate cap, presentation unload and transient mute.
//!
//! Saved per-display rates are never rewritten. A cap lowers what is running
//! through a live `set_fps`, not by rebuilding the scene. Unload closes
//! runtimes and host windows without forgetting which wallpapers are assigned.

use std::fs;

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, project::SceneHandle,
};

use crate::{
    BridgeBatteryMode,
    api::BridgeBuilder,
    config::{AppConfig, BatteryModeCfg, ConfigStore},
    engine::FakeEngineFacade,
    paths::BridgePaths,
    power::PowerSource,
};

fn display(display_id: u32, handle: Option<u64>) -> DisplaySnapshotEntry {
    display_at(display_id, 60, handle)
}

fn display_at(display_id: u32, refresh_hz: u32, handle: Option<u64>) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(refresh_hz);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: handle.map(SceneHandle::new),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn bridge_with(engine: &FakeEngineFacade, temp: &tempfile::TempDir) -> crate::api::WallpaperBridge {
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let video = paths.steam_workshop_root().join("400");
    fs::create_dir_all(&video).unwrap();
    fs::write(video.join("clip.mp4"), b"presence is all the native player checks").unwrap();
    BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap()
}

async fn commit(
    bridge: &crate::api::WallpaperBridge,
    wallpaper: &str,
    title: &str,
    project_json: &str,
    display: &str,
) {
    bridge
        .inject_scene_project_for_test(wallpaper, title, project_json)
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, title)
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

fn write_config(root: &std::path::Path, body: &str) {
    fs::write(root.join("config.toml"), body).unwrap();
}

fn loaded_mode(root: &std::path::Path) -> BatteryModeCfg {
    ConfigStore::open(root.to_path_buf())
        .load()
        .unwrap()
        .config
        .power
        .on_battery
}

#[test]
fn legacy_battery_keys_fold_into_battery_mode_and_the_new_key_wins() {
    let pause_only = tempfile::tempdir().unwrap();
    write_config(
        pause_only.path(),
        "[power]\npause_on_battery_power = true\n",
    );
    assert_eq!(loaded_mode(pause_only.path()), BatteryModeCfg::Pause);

    let profile_only = tempfile::tempdir().unwrap();
    write_config(
        profile_only.path(),
        "[quality]\nbattery_profile_enabled = true\n",
    );
    assert_eq!(
        loaded_mode(profile_only.path()),
        BatteryModeCfg::ReducedQuality
    );

    let both = tempfile::tempdir().unwrap();
    write_config(
        both.path(),
        "[power]\npause_on_battery_power = true\n\n[quality]\nbattery_profile_enabled = true\n",
    );
    assert_eq!(loaded_mode(both.path()), BatteryModeCfg::Pause);

    let explicit = tempfile::tempdir().unwrap();
    write_config(
        explicit.path(),
        "[power]\non_battery = \"reduced_quality\"\npause_on_battery_power = true\n",
    );
    assert_eq!(loaded_mode(explicit.path()), BatteryModeCfg::ReducedQuality);

    let explicit_default = tempfile::tempdir().unwrap();
    write_config(
        explicit_default.path(),
        "[power]\non_battery = \"keep_running\"\npause_on_battery_power = true\n",
    );
    assert_eq!(
        loaded_mode(explicit_default.path()),
        BatteryModeCfg::KeepRunning,
        "an explicit keep_running wins over the legacy pause flag"
    );

    let store = ConfigStore::open(pause_only.path().to_path_buf());
    let migrated = store.load().unwrap().config;
    store.save_app_config(&migrated).unwrap();
    let saved = fs::read_to_string(pause_only.path().join("config.toml")).unwrap();
    assert!(
        !saved.contains("pause_on_battery_power"),
        "migration must not write the legacy pause key back: {saved}"
    );
    assert!(
        !saved.contains("battery_profile_enabled"),
        "migration must not write the legacy profile key back: {saved}"
    );
}

#[test]
fn absent_frame_rate_cap_round_trips_as_no_limit() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    let config = AppConfig::default();
    store.save_app_config(&config).unwrap();
    let saved = fs::read_to_string(root.path().join("config.toml")).unwrap();
    assert!(
        !saved.contains("frame_rate_cap"),
        "no limit must omit the key, not write a null: {saved}"
    );
    assert!(store.load().unwrap().config.quality.frame_rate_cap.is_none());

    let mut capped = AppConfig::default();
    capped.quality.frame_rate_cap = Some(24);
    store.save_app_config(&capped).unwrap();
    assert_eq!(
        store.load().unwrap().config.quality.frame_rate_cap,
        Some(24)
    );
}

#[tokio::test]
async fn leaving_pause_on_battery_resumes_the_auto_pause() {
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .build()
        .expect("bridge");
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    bridge
        .set_battery_mode(BridgeBatteryMode::Pause)
        .await
        .unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Paused
    );

    bridge
        .set_battery_mode(BridgeBatteryMode::KeepRunning)
        .await
        .unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Playing,
        "leaving pause must resume a pause the policy asked for"
    );
}

#[tokio::test]
async fn reduced_quality_applies_and_restores_scale_and_frame_rate() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    bridge.set_render_scale(0.9).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    bridge
        .set_battery_quality_profile(0.5, 30)
        .await
        .unwrap();

    let on = bridge
        .set_battery_mode(BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap()
        .settings;
    assert_eq!(on.render_scale, 0.5);
    assert_eq!(on.preferred_render_scale, 0.9);
    assert_eq!(engine.fps_calls().last().map(|call| call.1), Some(30));

    let off = bridge
        .set_battery_mode(BridgeBatteryMode::KeepRunning)
        .await
        .unwrap()
        .settings;
    assert_eq!(off.render_scale, 0.9);
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(60),
        "leaving reduced quality restores the display's saved rate"
    );
}

#[tokio::test]
async fn frame_rate_cap_lowers_open_scenes_live_and_restores_on_none() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    let reconciles = engine.calls().len();
    let descriptor_fps = engine.rendered_scenes()[0].fps;

    let capped = bridge.set_frame_rate_cap(Some(24)).await.unwrap().settings;
    assert_eq!(capped.frame_rate_cap, Some(24));
    assert_eq!(engine.calls().len(), reconciles, "a cap must not rebuild");
    assert_eq!(engine.rendered_scenes()[0].fps, descriptor_fps);
    assert_eq!(engine.fps_calls().last().map(|call| call.1), Some(24));

    bridge.set_frame_rate_cap(None).await.unwrap();
    assert!(
        bridge
            .settings_snapshot()
            .await
            .unwrap()
            .frame_rate_cap
            .is_none()
    );
    assert_eq!(engine.calls().len(), reconciles);
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(descriptor_fps),
        "clearing the cap restores the saved rate"
    );
}

#[tokio::test]
async fn global_cap_and_battery_cap_combine_as_the_minimum() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    bridge
        .set_battery_quality_profile(0.75, 30)
        .await
        .unwrap();
    bridge
        .set_battery_mode(BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    bridge.set_frame_rate_cap(Some(15)).await.unwrap();
    assert_eq!(engine.fps_calls().last().map(|call| call.1), Some(15));

    bridge.set_frame_rate_cap(Some(45)).await.unwrap();
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(30),
        "the battery cap is stricter than the global cap"
    );

    bridge
        .set_battery_mode(BridgeBatteryMode::KeepRunning)
        .await
        .unwrap();
    assert_eq!(
        engine.fps_calls().last().map(|call| call.1),
        Some(45),
        "leaving reduced quality leaves only the global cap"
    );
}

#[tokio::test]
async fn set_target_fps_above_the_cap_stays_capped_live_and_saves_the_request() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    bridge.set_frame_rate_cap(Some(30)).await.unwrap();

    bridge
        .set_target_fps("100".into(), "7".into(), 50)
        .await
        .unwrap();

    assert_eq!(engine.fps_calls().last().map(|call| call.1), Some(30));
    let options = bridge.wallpaper_options_snapshot("100".into()).await.unwrap();
    assert_eq!(
        options.display_configurations[0].target_fps, 50,
        "the saved per-display rate is the request, not the cap"
    );
}

#[tokio::test]
async fn wallpapers_applied_under_a_frame_rate_cap_start_at_the_capped_rate() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1)), display(8, None)]);
    let bridge = bridge_with(&engine, &temp);
    bridge.set_frame_rate_cap(Some(20)).await.unwrap();

    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    commit(
        &bridge,
        "300",
        "Web",
        r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        "8",
    )
    .await;

    assert_eq!(bridge.web_wallpapers().await.unwrap()[0].fps, 20);
    assert_eq!(
        engine.rendered_scenes()[0].fps, 20,
        "a scene opens at its descriptor's rate, so the descriptor carries the cap"
    );
}

#[tokio::test]
async fn unsaved_frame_rate_follows_the_display_up_to_60_for_every_descriptor() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![
        display_at(7, 120, Some(1)),
        display_at(8, 60, Some(2)),
    ]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    commit(
        &bridge,
        "200",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "8",
    )
    .await;

    let scenes = engine.rendered_scenes();
    assert_eq!(scene_fps(&scenes, 7), 60, "a 120 Hz display runs at 60 until the user picks more");
    assert_eq!(scene_fps(&scenes, 8), 60);
    let options = bridge.wallpaper_options_snapshot("100".into()).await.unwrap();
    assert!(
        options
            .display_configurations
            .iter()
            .any(|row| row.max_fps == 120 && row.target_fps == 60),
        "a 120 Hz display with no saved rate must report 60 of 120: {:?}",
        options.display_configurations
    );
    assert!(
        options
            .display_configurations
            .iter()
            .any(|row| row.max_fps == 60 && row.target_fps == 60),
        "a 60 Hz display with no saved rate must report 60: {:?}",
        options.display_configurations
    );

    commit(
        &bridge,
        "300",
        "Web",
        r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        "7",
    )
    .await;
    commit(
        &bridge,
        "301",
        "Web",
        r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        "8",
    )
    .await;
    let web = bridge.web_wallpapers().await.unwrap();
    assert_eq!(row_fps(&web, 7, |row| row.display_id, |row| row.fps), 60);
    assert_eq!(row_fps(&web, 8, |row| row.display_id, |row| row.fps), 60);

    write_clip(&temp, "400");
    write_clip(&temp, "401");
    commit(
        &bridge,
        "400",
        "Clip",
        r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#,
        "7",
    )
    .await;
    commit(
        &bridge,
        "401",
        "Clip",
        r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#,
        "8",
    )
    .await;
    // A native clip carries no rate: it plays at its own.
    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 2);
}

fn scene_fps(scenes: &[wallpaper_core::project::SceneDesc], display_id: u32) -> u32 {
    scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene on display {display_id}"))
        .fps
}

fn row_fps<T>(
    rows: &[T],
    display_id: u32,
    id_of: impl Fn(&T) -> u32,
    fps_of: impl Fn(&T) -> u32,
) -> u32 {
    rows.iter()
        .find(|row| id_of(row) == display_id)
        .map_or_else(
            || panic!("missing descriptor on display {display_id}"),
            fps_of,
        )
}

fn write_clip(temp: &tempfile::TempDir, id: &str) {
    let dir = BridgePaths::for_home(temp.path().to_path_buf())
        .steam_workshop_root()
        .join(id);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("clip.mp4"), b"presence is all the native player checks").unwrap();
}

#[tokio::test]
async fn native_export_keeps_all_wallpaper_kinds_and_mirrors_with_playback_and_power_policy() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot((7..=14).map(|id| display(id, None)).collect());
    let bridge = bridge_with(&engine, &temp);
    for (id, title, project, display_id) in [
        ("100", "Scene", r#"{"type":"scene","file":"scene.pkg","general":{"properties":{
            "speed":{"type":"slider","value":1,"min":0,"max":10}}}}"#, "7"),
        ("400", "Clip", r#"{"type":"video","file":"clip.mp4"}"#, "8"),
        ("300", "Web", r#"{"type":"web","file":"index.html","general":{"properties":{
            "speed":{"type":"slider","value":1,"min":0,"max":10}}}}"#, "9"),
        ("500", "Still", r#"{"type":"web","file":"index.html","general":{"properties":{
            "image":{"type":"file","fileType":"image","value":"poster.png"}}}}"#, "10"),
    ] {
        commit(&bridge, id, title, project, display_id).await;
    }
    bridge
        .edit_property("300".into(), "speed".into(), crate::BridgePropertyValue::Number { value: 2.0 })
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
    bridge
        .edit_property("100".into(), "speed".into(), crate::BridgePropertyValue::Number { value: 3.0 })
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    for (mirror, source) in [("11", "7"), ("12", "8"), ("13", "9"), ("14", "10")] {
        bridge
            .set_display_mode(mirror.into(), crate::BridgeDisplayMode::Mirror)
            .await
            .unwrap();
        bridge.set_mirror_target(mirror.into(), source.into()).await.unwrap();
        bridge.set_mirror_target_fps(mirror.into(), 45).await.unwrap();
        bridge.set_display_presentation_suspended(mirror.into(), true).await.unwrap();
    }
    bridge.set_mirror_scaling_factor("12".into(), 1.25).await.unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();

    let desktop_scenes = engine.rendered_scenes();
    assert_eq!(
        desktop_scenes.iter().map(|scene| scene.display.display_id).collect::<Vec<_>>(),
        vec![7, 11]
    );
    assert!(desktop_scenes.iter().all(|scene| scene.scene_path.contains("/100/")));
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 2);
    assert_eq!(bridge.web_wallpapers().await.unwrap().len(), 4);
    let exported = bridge.lock_screen_scenes().await.unwrap();
    let by_display = exported.iter().map(|row| (row.display_id, row)).collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(by_display.keys().copied().collect::<Vec<_>>(), (7..=14).collect::<Vec<_>>());
    for (source, mirror, wallpaper) in [(7, 11, "100"), (8, 12, "400"), (9, 13, "300"), (10, 14, "500")] {
        for row in [by_display[&source], by_display[&mirror]] {
            assert_eq!(row.wallpaper_id, wallpaper);
            assert!(std::path::Path::new(&row.project_path).is_absolute());
            assert!(std::path::Path::new(&row.assets_path).is_absolute());
            assert!(!row.paused, "desktop suspension must not pause native presentations");
        }
        assert_eq!(by_display[&source].project_path, by_display[&mirror].project_path);
        assert_eq!(by_display[&source].properties_json, by_display[&mirror].properties_json);
        assert_eq!(by_display[&mirror].fps, 45);
    }
    assert_eq!(by_display[&12].scaling_factor, 1.25);
    let scene: serde_json::Value =
        serde_json::from_str(by_display[&11].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(scene["speed"], 3.0, "renderer options remain flat");
    for display_id in [9, 10, 13, 14] {
        assert_eq!(by_display[&display_id].scaling_mode, crate::BridgeScalingMode::Fill);
        assert_eq!(by_display[&display_id].scaling_factor, 1.0);
        assert!(by_display[&display_id].project_path.ends_with("/project.json"));
    }
    let web: serde_json::Value =
        serde_json::from_str(by_display[&13].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(web["speed"]["value"], 2.0);
    let still: serde_json::Value =
        serde_json::from_str(by_display[&14].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(still["image"]["value"], "poster.png");

    bridge.set_presentation_unloaded(true).await.unwrap();
    assert_eq!(bridge.lock_screen_scenes().await.unwrap(), exported);
    assert_eq!(bridge.lock_screen_scenes().await.unwrap(), exported);
    bridge.pause_all().await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap().iter().all(|row| row.paused));
    bridge.play_all().await.unwrap();
    bridge.set_battery_mode(BridgeBatteryMode::Pause).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert!(bridge.lock_screen_scenes().await.unwrap().iter().all(|row| row.paused));
    bridge.set_power_source_for_test(PowerSource::External).await;
    assert!(bridge.lock_screen_scenes().await.unwrap().iter().all(|row| !row.paused));
    bridge.set_battery_quality_profile(0.5, 24).await.unwrap();
    bridge.set_battery_mode(BridgeBatteryMode::ReducedQuality).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert!(bridge.lock_screen_scenes().await.unwrap().iter().all(|row| row.fps == 24));
    bridge.set_frame_rate_cap(Some(15)).await.unwrap();
    assert!(bridge.lock_screen_scenes().await.unwrap().iter().all(|row| row.fps == 15));
}

#[tokio::test]
async fn unload_closes_scenes_and_host_lists_and_reload_restores_them() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1)), display(8, None), display(9, None)]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    commit(
        &bridge,
        "300",
        "Web",
        r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        "8",
    )
    .await;
    commit(
        &bridge,
        "400",
        "Clip",
        r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#,
        "9",
    )
    .await;

    assert!(!engine.rendered_scenes().is_empty());
    assert_eq!(bridge.web_wallpapers().await.unwrap().len(), 1);
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);
    assert_eq!(bridge.lock_screen_scenes().await.unwrap().len(), 3);
    let active = bridge.app_snapshot().await.unwrap().active_wallpaper_ids;
    assert!(active.iter().any(|id| id == "100"));

    let reconciles = engine.calls().len();
    bridge.set_presentation_unloaded(true).await.unwrap();
    assert!(engine.rendered_scenes().is_empty(), "unload closes scene runtimes");
    assert!(bridge.web_wallpapers().await.unwrap().is_empty());
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
    assert_eq!(
        bridge.lock_screen_scenes().await.unwrap().len(),
        3,
        "the lock screen is not a desktop presentation"
    );
    assert_eq!(
        bridge.app_snapshot().await.unwrap().active_wallpaper_ids,
        active,
        "unload must not blank the panel's active marks"
    );

    bridge.set_presentation_unloaded(true).await.unwrap();
    assert_eq!(
        engine.calls().len(),
        reconciles + 1,
        "the same unload value must not reconcile again"
    );

    bridge.set_presentation_unloaded(false).await.unwrap();
    assert!(
        !engine.rendered_scenes().is_empty(),
        "clearing unload opens the configured scenes again"
    );
    assert_eq!(bridge.web_wallpapers().await.unwrap().len(), 1);
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().active_wallpaper_ids,
        active
    );
}

#[tokio::test]
async fn audio_suppression_mutes_live_and_restores_the_saved_mute() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    bridge.set_muted("100".into(), true).await.unwrap();

    bridge.set_audio_suppressed(true).await.unwrap();
    assert_eq!(
        engine.audio_muted_calls().last().map(|call| call.1),
        Some(true)
    );

    bridge.set_audio_suppressed(false).await.unwrap();
    assert_eq!(
        engine.audio_muted_calls().last().map(|call| call.1),
        Some(true),
        "clearing suppression restores the saved mute, which was on"
    );
}

#[tokio::test]
async fn unmute_while_suppressed_stays_muted_live() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(
        &bridge,
        "100",
        "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#,
        "7",
    )
    .await;
    bridge.set_audio_suppressed(true).await.unwrap();

    bridge.set_muted("100".into(), false).await.unwrap();
    assert_eq!(
        engine.audio_muted_calls().last().map(|call| call.1),
        Some(true),
        "a user unmute while suppressed must not become audible"
    );

    bridge.set_audio_suppressed(false).await.unwrap();
    assert_eq!(
        engine.audio_muted_calls().last().map(|call| call.1),
        Some(false),
        "clearing suppression then honours the unmute the user saved"
    );
}
