//! Scene quality (`[quality.scene]`): the default is Wallpaper Engine's
//! first-run "medium" preset, a change is saved and loads each running scene
//! once more, an equal value changes nothing, and a restart reads what was saved.

use wallpaper_core::project::{PostProcessing, QualityLevel, SceneQuality};

use super::fixture_values::anonymous;
use crate::{
    BridgeMsaa, BridgePostProcessing, BridgeQualityLevel, BridgeSceneQuality,
    api::{BridgeBuilder, WallpaperBridge},
    config::ConfigStore,
    engine::FakeEngineFacade,
};

fn wallpaper_engine_medium() -> BridgeSceneQuality {
    BridgeSceneQuality {
        msaa: BridgeMsaa::Off,
        shadows: BridgeQualityLevel::Medium,
        volumetrics: BridgeQualityLevel::Medium,
        reflections: true,
        post_processing: BridgePostProcessing::Enabled,
    }
}

async fn with_scene(engine: &FakeEngineFacade, store: Option<ConfigStore>) -> WallpaperBridge {
    engine.set_snapshot(vec![anonymous(7, 1.0, 60, false)]);
    let mut builder = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default());
    if let Some(store) = store {
        builder = builder.with_config_store(store);
    }
    let bridge = builder.build().unwrap();
    bridge.inject_scene_wallpaper_config_for_test("100", "Scene").await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge
}

#[tokio::test]
async fn the_default_is_wallpaper_engines_first_run_medium_preset_and_reaches_the_scene() {
    let engine = FakeEngineFacade::default();
    let bridge = with_scene(&engine, None).await;

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_quality,
        wallpaper_engine_medium()
    );
    assert_eq!(engine.rendered_scenes()[0].quality, SceneQuality::default());
    assert_eq!(
        SceneQuality::default(),
        SceneQuality {
            msaa: 0,
            shadows: QualityLevel::Medium,
            volumetrics: QualityLevel::Medium,
            reflection: true,
            post_processing: PostProcessing::Enabled,
        }
    );
}

#[tokio::test]
async fn a_change_is_saved_and_loads_running_scenes_once_with_it() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = with_scene(&engine, Some(store.clone())).await;

    let chosen = BridgeSceneQuality {
        msaa: BridgeMsaa::X4,
        shadows: BridgeQualityLevel::Ultra,
        volumetrics: BridgeQualityLevel::Off,
        reflections: false,
        post_processing: BridgePostProcessing::DisplayHdr,
    };
    let reconciles = engine.reconcile_call_count();
    let snapshot = bridge.set_scene_quality(chosen).await.unwrap().settings;
    assert_eq!(snapshot.scene_quality, chosen);
    assert_eq!(engine.reconcile_call_count(), reconciles + 1);
    assert_eq!(engine.rendered_scenes()[0].quality, SceneQuality::from(chosen));

    let reconciles = engine.reconcile_call_count();
    bridge.set_scene_quality(chosen).await.unwrap();
    assert_eq!(
        engine.reconcile_call_count(),
        reconciles,
        "the same quality again must not reload anything"
    );

    let saved = std::fs::read_to_string(temp.path().join("config.toml")).unwrap();
    assert!(saved.contains("[quality.scene]"), "{saved}");
    assert!(saved.contains("msaa = \"x4\""), "{saved}");
    assert!(saved.contains("volumetrics = \"disabled\""), "{saved}");
    assert!(saved.contains("post_processing = \"displayhdr\""), "{saved}");

    drop(bridge);
    let restarted = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store)
        .build()
        .unwrap();
    assert_eq!(restarted.settings_snapshot().await.unwrap().scene_quality, chosen);
}
