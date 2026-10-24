//! A saved assignment can outlive its wallpaper files; the other displays must
//! still get their scenes.

use std::fs;

use tempfile::tempdir;

use super::engine_release::EngineRelease;
use super::fixture_values::anonymous;
use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig};
use crate::engine::FakeEngineFacade;
use crate::paths::BridgePaths;

fn independent(display_id: u32, wallpaper: &str) -> MonitorCfg {
    MonitorCfg {
        selector: SerializedSelector::LiveDisplayId { display_id },
        enabled: true,
        mode: "independent".to_owned(),
        wallpaper: Some(wallpaper.to_owned()),
        mirror_target: None,
    }
}

#[tokio::test]
async fn bootstrap_leaves_out_the_wallpaper_that_is_no_longer_installed() {
    let home = tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let installed = paths.steam_workshop_root().join("100");
    fs::create_dir_all(&installed).unwrap();
    fs::write(
        installed.join("project.json"),
        r#"{"type":"scene","title":"Scene 100","file":"scene.json"}"#,
    )
    .unwrap();

    let root = tempdir().unwrap();
    let store = ConfigStore::open(root.path());
    store
        .save_app_config(&AppConfig {
            monitors: vec![independent(7, "100"), independent(8, "gone")],
            ..AppConfig::default()
        })
        .unwrap();
    store.save_wallpaper(&WallpaperConfig::new_for("100", "scene")).unwrap();
    store.save_wallpaper(&WallpaperConfig::new_for("gone", "scene")).unwrap();

    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot_after_refresh(vec![anonymous(7, 1.0, 60, true), anonymous(8, 1.0, 60, true)]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_config_store(store)
        .with_paths(paths)
        .build()
        .expect("the bridge should build");

    bridge.bootstrap().await.expect("bootstrap should succeed");

    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(app.active_wallpaper_ids, vec!["100".to_owned()]);
    let calls = engine.calls();
    assert_eq!(calls.len(), 1, "expected one reconcile, saw {}", calls.len());
    let displays: Vec<u32> = calls[0].iter().map(|scene| scene.display.display_id).collect();
    assert_eq!(displays, vec![7]);
}
