//! A wallpaper saved for the primary display follows the primary display when
//! the engine's display order flips, and the former primary keeps showing it.

use tempfile::tempdir;

use super::engine_release::EngineRelease;
use super::fixture_observations::{expect_last_owner, settings_key};
use super::fixture_values::identified;
use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig};
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
