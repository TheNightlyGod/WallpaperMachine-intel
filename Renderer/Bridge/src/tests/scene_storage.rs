//! Scene scripts' `localStorage` (plan decision I3): a scene is told its
//! wallpaper's folder under `SceneStorage`, and clearing the shader cache never
//! touches it.

use std::{fs, time::Duration};

use tempfile::tempdir;

use super::bridge_waits::{apply_on_primary, wait_for_reconciles};
use super::engine_release::EngineRelease;
use super::fixture_observations::last_scene;
use super::fixture_values::anonymous;
use crate::engine::FakeEngineFacade;
use crate::paths::BridgePaths;

const BOUND: Duration = Duration::from_secs(2);

#[tokio::test]
async fn a_scene_keeps_its_storage_in_its_wallpapers_folder_and_a_cache_clear_leaves_it() {
    let home = tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let storage = paths.scene_storage_dir("100");
    fs::create_dir_all(&storage).unwrap();
    fs::write(storage.join("global.json"), b"{}").unwrap();

    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![anonymous(1, 1.0, 60, true)]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_paths(paths.clone())
        .build()
        .expect("the bridge should build");
    bridge.inject_scene_wallpaper_config_for_test("100", "Scene").await;
    apply_on_primary(&bridge, "100").await;
    assert!(wait_for_reconciles(&engine, 1, BOUND).await, "applying did not reconcile once");
    assert_eq!(
        last_scene(&engine, 1).scene_storage_dir.as_deref(),
        Some(storage.to_string_lossy().as_ref())
    );

    bridge.clear_shader_cache().await.expect("clearing should succeed");
    assert!(storage.join("global.json").is_file(), "the scripts' storage is user data, not a cache");
}
