//! A wallpaper saved for the primary display follows the primary display when
//! the engine's display order flips, and the former primary keeps showing it.

use tempfile::tempdir;

use super::engine_release::EngineRelease;
use super::fixture_observations::{expect_last_owner, settings_key};
use super::fixture_values::identified;
use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig};
use crate::display::DisplaySnapshotExt;
use crate::engine::FakeEngineFacade;
use crate::paths::BridgePaths;

#[tokio::test]
async fn the_primary_wallpaper_moves_with_the_primary_display() {
    let root = tempdir().unwrap();
    let home = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_owned(),
                wallpaper: Some("300".to_owned()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store.save_wallpaper(&WallpaperConfig::new_for("300", "scene")).unwrap();

    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    let (a, b) = (identified("a", 1, 60), identified("b", 3, 60));
    engine.set_snapshot_after_refresh(vec![a.clone(), b.clone()]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_config_store(store)
        .with_paths(BridgePaths::for_home(home.path()))
        .build()
        .expect("the bridge should build");
    bridge.inject_scene_wallpaper_config_for_test("300", "Scene").await;
    bridge.bootstrap().await.expect("bootstrap should succeed");
    expect_last_owner(&engine, 1, "300");
    assert_eq!(settings_key(&bridge, "Display a").await, "primary");

    engine.set_snapshot_after_refresh(vec![b, a]);
    bridge.refresh_displays().await.expect("the refresh should succeed");

    expect_last_owner(&engine, 3, "300");
    expect_last_owner(&engine, 1, "300");
    assert_eq!(
        settings_key(&bridge, "Display b").await,
        "primary",
        "the primary role must move to the display the engine now lists first"
    );
}

#[tokio::test]
async fn mirrors_follow_later_wallpaper_changes_after_a_main_display_roundtrip() {
    let root = tempdir().unwrap();
    let home = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    let (main, left, right) = (
        identified("main", 3, 60),
        identified("left", 2, 60),
        identified("right", 1, 60),
    );
    let mirror = |selector| MonitorCfg {
        selector,
        mode: "mirror".into(),
        mirror_target: Some(SerializedSelector::Primary),
        ..MonitorCfg::default()
    };
    let left_config = mirror(left.connected_selector());
    let right_config = mirror(right.connected_selector());
    store.save_app_config(&AppConfig {
        primary_display: Some(main.connected_selector()),
        monitors: vec![
            MonitorCfg {
                wallpaper: Some("300".into()),
                ..MonitorCfg::default()
            },
            left_config.clone(),
            right_config.clone(),
        ],
        ..AppConfig::default()
    }).unwrap();
    for id in ["300", "400"] {
        store.save_wallpaper(&WallpaperConfig::new_for(id, "scene")).unwrap();
    }
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot_after_refresh(vec![main.clone(), left.clone(), right.clone()]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .with_paths(BridgePaths::for_home(home.path()))
        .build()
        .unwrap();
    for id in ["300", "400"] {
        bridge.inject_scene_wallpaper_config_for_test(id, "Scene").await;
    }
    bridge.bootstrap().await.unwrap();
    for id in [1, 2, 3] {
        expect_last_owner(&engine, id, "300");
    }

    engine.set_snapshot_after_refresh(vec![right.clone(), main.clone(), left.clone()]);
    bridge.refresh_displays().await.unwrap();
    engine.set_snapshot_after_refresh(vec![main, left, right]);
    bridge.refresh_displays().await.unwrap();
    let saved = store.load().unwrap().config;
    for expected in [&left_config, &right_config] {
        assert_eq!(
            saved.monitors.iter().find(|row| row.selector == expected.selector),
            Some(expected),
            "refresh saves each physical display's mirror choice"
        );
    }
    for id in [1, 2, 3] {
        expect_last_owner(&engine, id, "300");
    }

    bridge.set_display_config_enabled("400".into(), "primary".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("400".into(), false).await.unwrap();
    for id in [1, 2, 3] {
        expect_last_owner(&engine, id, "400");
    }
}

#[tokio::test]
async fn choosing_a_wallpaper_while_a_mirror_is_main_replaces_its_saved_mirror() {
    let root = tempdir().unwrap();
    let home = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    let (main, mirror) = (identified("main", 3, 60), identified("mirror", 1, 60));
    let mirror_selector = mirror.connected_selector();
    store.save_app_config(&AppConfig {
        primary_display: Some(main.connected_selector()),
        monitors: vec![
            MonitorCfg {
                wallpaper: Some("300".into()),
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: mirror_selector.clone(),
                mode: "mirror".into(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        ..AppConfig::default()
    }).unwrap();
    for id in ["300", "400"] {
        store.save_wallpaper(&WallpaperConfig::new_for(id, "scene")).unwrap();
    }
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot_after_refresh(vec![main.clone(), mirror.clone()]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .with_paths(BridgePaths::for_home(home.path()))
        .build()
        .unwrap();
    for id in ["300", "400"] {
        bridge.inject_scene_wallpaper_config_for_test(id, "Scene").await;
    }
    bridge.bootstrap().await.unwrap();
    engine.set_snapshot_after_refresh(vec![mirror.clone(), main.clone()]);
    bridge.refresh_displays().await.unwrap();

    bridge.set_display_config_enabled("400".into(), "primary".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("400".into(), true).await.unwrap();
    engine.set_snapshot_after_refresh(vec![main, mirror]);
    bridge.refresh_displays().await.unwrap();

    let saved = store.load().unwrap().config;
    assert_eq!(
        saved.monitors.iter().find(|row| row.selector == mirror_selector),
        Some(&MonitorCfg {
            selector: mirror_selector.clone(),
            wallpaper: Some("400".into()),
            ..MonitorCfg::default()
        })
    );
    expect_last_owner(&engine, 1, "400");
    expect_last_owner(&engine, 3, "300");
}

/// #179, playlist case: a playlist rotation lands on `primary` while macOS
/// briefly makes a mirrored display main during wake. That apply is not the
/// user's choice, so the mirror's saved block must survive it and the mirror
/// must follow the main display again once it is back.
#[tokio::test]
async fn an_automatic_apply_while_a_mirror_is_main_keeps_its_saved_mirror() {
    for earlier in [None, Some("400")] {
        assert_automatic_apply_preserves_saved_mirror(earlier).await;
    }
}

async fn assert_automatic_apply_preserves_saved_mirror(earlier: Option<&str>) {
    let root = tempdir().unwrap();
    let home = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    let (main, left, right) = (
        identified("main", 3, 60),
        identified("left", 2, 60),
        identified("right", 1, 60),
    );
    let mirror = |selector| MonitorCfg {
        selector,
        mode: "mirror".into(),
        mirror_target: Some(SerializedSelector::Primary),
        ..MonitorCfg::default()
    };
    let left_config = mirror(left.connected_selector());
    let mut right_config = mirror(right.connected_selector());
    right_config.wallpaper = earlier.map(str::to_owned);
    store.save_app_config(&AppConfig {
        primary_display: Some(main.connected_selector()),
        monitors: vec![
            MonitorCfg {
                wallpaper: Some("300".into()),
                ..MonitorCfg::default()
            },
            left_config.clone(),
            right_config.clone(),
        ],
        ..AppConfig::default()
    }).unwrap();
    for id in ["300", "400", "500"] {
        store.save_wallpaper(&WallpaperConfig::new_for(id, "scene")).unwrap();
    }
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot_after_refresh(vec![main.clone(), left.clone(), right.clone()]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .with_paths(BridgePaths::for_home(home.path()))
        .build()
        .unwrap();
    for id in ["300", "400", "500"] {
        bridge.inject_scene_wallpaper_config_for_test(id, "Scene").await;
    }
    bridge.bootstrap().await.unwrap();

    // Wake: the right display is main for a moment, and the playlist advances.
    engine.set_snapshot_after_refresh(vec![right.clone(), main.clone(), left.clone()]);
    bridge.refresh_displays().await.unwrap();
    bridge.set_display_config_enabled("400".into(), "primary".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("400".into(), false).await.unwrap();
    assert_eq!(
        store.load().unwrap().config.monitors.iter()
            .find(|row| row.selector == right_config.selector),
        Some(&right_config),
        "the automatic apply preserves the mirror and its earlier wallpaper before handover"
    );

    // The real main display takes the role back.
    engine.set_snapshot_after_refresh(vec![main, left, right]);
    bridge.refresh_displays().await.unwrap();

    let saved = store.load().unwrap().config;
    for expected in [&left_config, &right_config] {
        assert_eq!(
            saved.monitors.iter().find(|row| row.selector == expected.selector),
            Some(expected),
            "an automatic apply while a mirror is main must not replace its saved mirror"
        );
    }
    // The real main display's own block takes the role back, and both
    // mirrors follow it again.
    for id in [1, 2, 3] {
        expect_last_owner(&engine, id, "300");
    }

    // A later rotation still reaches every mirror.
    bridge.set_display_config_enabled("500".into(), "primary".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("500".into(), false).await.unwrap();
    for id in [1, 2, 3] {
        expect_last_owner(&engine, id, "500");
    }
}
