//! Clearing the shader cache empties it on disk, reports it empty, and makes
//! every active scene rebuild its cache through one more reconcile.

use std::{fs, time::Duration};

use tempfile::tempdir;

use super::bridge_waits::{apply_on_primary, wait_for_reconciles};
use super::engine_release::EngineRelease;
use super::fixture_observations::{expect_last_owner, last_scene};
use super::fixture_values::anonymous;
use crate::engine::FakeEngineFacade;
use crate::paths::BridgePaths;

const BOUND: Duration = Duration::from_secs(2);

#[tokio::test]
async fn clearing_empties_the_cache_and_forces_the_active_scenes_to_rebuild_it() {
    let home = tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let cache = paths.shader_cache_root();
    fs::create_dir_all(&cache).unwrap();
    let first = cache.join("first.bin");
    fs::write(&first, [1u8, 2, 3]).unwrap();

    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![anonymous(1, 1.0, 60, true)]);
    let bridge = crate::api::BridgeBuilder::new(engine.clone())
        .with_paths(paths)
        .build()
        .expect("the bridge should build");
    bridge.inject_scene_wallpaper_config_for_test("100", "Scene").await;
    apply_on_primary(&bridge, "100").await;
    assert!(wait_for_reconciles(&engine, 1, BOUND).await, "applying did not reconcile once");

    let size = |snapshot: crate::BridgeSettingsSnapshot| snapshot.storage.shader_cache_size_bytes;
    assert_eq!(size(bridge.settings_snapshot().await.unwrap()), 3);

    fs::write(cache.join("second.bin"), [4u8, 5]).unwrap();
    assert_eq!(
        size(bridge.settings_snapshot().await.unwrap()),
        5,
        "a read right after another must still see the files on disk"
    );

    let cleared = bridge.clear_shader_cache().await.expect("clearing should succeed");

    assert_eq!(size(cleared), 0);
    assert!(wait_for_reconciles(&engine, 2, BOUND).await, "clearing did not trigger one reconcile");
    assert!(cache.is_dir(), "the cache directory itself must stay");
    assert!(!first.exists(), "the old cache file survived the clear");
    expect_last_owner(&engine, 1, "100");
    assert!(last_scene(&engine, 1).force_shader_refresh, "the rebuild was not forced");
}
