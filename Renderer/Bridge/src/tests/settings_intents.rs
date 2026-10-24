use wallpaper_core::{
    DisplaySelector, DisplaySnapshotEntry,
    WallpaperAssignment,
    project::{SceneHandle, SceneTemplate},
};

use super::{
    engine_release::EngineRelease,
    fixture_observations::{expect_enabled, expect_last_owner, last_scene, settings_key},
    fixture_values::{anonymous, identified},
};
use crate::{
    BridgePropertyValue,
    WallpaperBridge,
    api::BridgeBuilder,
    config::{
        AppConfig, ConfigStore, MonitorCfg, SerializedSelector,
        WallpaperConfig,
    },
    engine::FakeEngineFacade,
};

#[tokio::test]
async fn first_seen_display_starts_with_primary_wallpaper_and_keeps_opt_out_after_reconnect() {
    let primary = identified("primary", 1, 60);
    let mut external = identified("external", 3, 60);
    // The engine has never shown this display, so it reports no window.
    external.window_active = false;
    let external_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(external.identity.clone()));
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![primary.clone()]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge.bootstrap().await.unwrap();

    engine.set_snapshot_after_refresh(vec![primary.clone(), external.clone()]);
    bridge.refresh_displays().await.unwrap();

    let external_id = settings_key(&bridge, "external").await;
    expect_enabled(&bridge, &external_id, true).await;
    expect_last_owner(&engine, 1, "100");
    expect_last_owner(&engine, 3, "100");

    bridge
        .set_display_enabled(external_id.clone(), false)
        .await
        .expect("external display should be disabled");
    engine.set_snapshot_after_refresh(vec![primary.clone()]);
    bridge.refresh_displays().await.unwrap();
    engine.set_snapshot_after_refresh(vec![primary, external]);
    bridge.refresh_displays().await.unwrap();

    expect_enabled(&bridge, &external_id, false).await;
    assert!(
        engine
            .calls()
            .last()
            .expect("reconcile call")
            .iter()
            .all(|scene| scene.display.display_id != 3),
        "a display the user turned off must stay dark when it reconnects"
    );
    let saved = store.load().unwrap().config;
    assert!(
        saved
            .monitors
            .iter()
            .any(|monitor| monitor.selector == external_selector && !monitor.enabled),
        "the opt-out must be saved under the display's identity"
    );
}

/// One scene committed to a 120 Hz primary display and running. The engine
/// snapshot carries the descriptor the scene was opened with, and live
/// updates land in it as they do in the real engine.
async fn running_scene_bridge(engine: &FakeEngineFacade) -> (WallpaperBridge, tempfile::TempDir) {
    let display = identified("primary", 1, 60);
    let primary = DisplaySnapshotEntry {
        desc: display.desc.clone().with_refresh_rate(120),
        ..display
    };
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();
    engine.set_snapshot_after_refresh(vec![primary]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.refresh_displays().await.unwrap();
    let opened = engine.calls()[0][0].clone();
    let running = vec![DisplaySnapshotEntry {
        identity: opened.display.identity.clone(),
        desc: opened.display.clone(),
        handle: Some(SceneHandle::new(1)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&opened))),
    }];
    engine.set_snapshot(running.clone());
    engine.set_snapshot_after_refresh(running);
    (bridge, root)
}

async fn assert_refresh_keeps_the_scene(bridge: &WallpaperBridge, engine: &FakeEngineFacade) {
    let calls_before = engine.calls().len();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        calls_before,
        "nothing about the wallpaper changed, so a display refresh must not reload it"
    );
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_whose_audio_response_has_nothing_to_read() {
    // Audio response is on, but the scene has not reported reading audio, so
    // the system-audio tap stays shut for it. That is not a different wallpaper.
    let engine = FakeEngineFacade::default();
    engine.scenes_start_without_audio();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(
        engine.audio_capture_calls().last(),
        Some(&(SceneHandle::new(1), false))
    );

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_battery_frame_rate() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_battery_mode(crate::BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    bridge
        .set_power_source_for_test(crate::power::PowerSource::Battery)
        .await;
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 30)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_quality_throttle() {
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_quality_throttle(vec![crate::BridgeQualityThrottleCause::Heat])
        .await
        .unwrap();
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 30)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_muted_for_other_audio() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_audio_suppressed(true).await.unwrap();

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_paused_by_a_lock_or_a_covered_display() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge
        .set_display_presentation_suspended("1".into(), true)
        .await
        .unwrap();

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_frame_rate_cap() {
    // A 120 Hz display under a 60 fps cap: the scene runs at 60.
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_frame_rate_cap(Some(60)).await.unwrap();
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 60)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_reported_press_comes_back_out_of_the_bridge() {
    // The sink the bridge installs owns the only sender for its channel. A
    // facade that accepted it and dropped it closed that channel before the
    // first press, so every button in every wallpaper was dead from startup --
    // and it looked exactly like a button nobody had bound.
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..anonymous(7, 1.0, 60, true)
    }]);
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
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(bridge.system_media_consent_handles().await.unwrap(), vec![11]);

    assert!(
        engine.report_user_shortcut(SceneHandle::new(11), "nextsongbutton", "media:next"),
        "the bridge never installed its sink, so nothing could report a press"
    );
    let event = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        bridge.next_user_shortcut(),
    )
    .await
    .expect("a reported press has to come back out rather than hang")
    .expect("the channel closed instead of delivering the press");
    assert_eq!(event.property, "nextsongbutton");
    assert_eq!(event.value, "media:next");
}

#[tokio::test]
async fn an_unbound_transport_shortcut_reaches_the_scene_engine() {
    // The scene engine parses the project file itself, where these ship empty,
    // so a default this host supplies is invisible to it unless it is sent
    // along with the user's overrides. Without that the button resolves to
    // nothing, `openUserShortcut` reports an empty value and the press is
    // dropped -- however the panel happens to show the binding.
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![anonymous(1, 1.0, 60, true)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "playpausebutton":{"type":"usershortcut","text":"Play","value":"","order":1},
                "nextsongbutton":{"type":"usershortcut","text":"Next","value":"","order":2},
                "secretbutton":{"type":"usershortcut","text":"Secret","value":"","order":3}
            }}
        }"#,
        )
        .await;
    bridge
        .set_display_config_enabled("100".to_string(), "1".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    // A name that says nothing stays out of it rather than being guessed at.
    assert_eq!(
        last_scene(&engine, 1).property_override_json.as_deref(),
        Some(r#"{"nextsongbutton":"media:next","playpausebutton":"media:playpause"}"#)
    );

    // The user's own choice still wins, including choosing no action.
    bridge
        .edit_property(
            "100".to_string(),
            "nextsongbutton".to_string(),
            BridgePropertyValue::String {
                value: String::new(),
            },
        )
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert_eq!(
        last_scene(&engine, 1).property_override_json.as_deref(),
        Some(r#"{"nextsongbutton":"","playpausebutton":"media:playpause"}"#)
    );
}

#[tokio::test]
async fn verbose_logging_persists_across_relaunch_and_can_be_turned_off() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    let bridge = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    assert!(!bridge.settings_snapshot().await.unwrap().verbose_logging);

    let snapshot = bridge.set_verbose_logging(true).await.unwrap();
    assert!(snapshot.settings.verbose_logging);
    drop(bridge);

    let relaunched = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    assert!(relaunched.settings_snapshot().await.unwrap().verbose_logging);

    let snapshot = relaunched.set_verbose_logging(false).await.unwrap();
    assert!(!snapshot.settings.verbose_logging);
    assert!(!store.load().unwrap().config.diagnostics.verbose_logging);
}
