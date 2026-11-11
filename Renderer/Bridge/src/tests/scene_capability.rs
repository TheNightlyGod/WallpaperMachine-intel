use wallpaper_core::{SceneCapabilityProbe, SceneMissingFile};

use crate::{
    BridgeErrorKind, BridgePropertyValue, BridgeSceneMissingFile, WallpaperBridge,
    api::BridgeBuilder, config::WallpaperConfig, engine::FakeEngineFacade,
};

const PROJECT: &str = r#"{
    "type":"scene", "file":"scene.json", "title":"Rain",
    "general":{"properties":{"rain":{"type":"bool","value":false}}}
}"#;

fn bridge(engine: &FakeEngineFacade) -> WallpaperBridge {
    BridgeBuilder::new(engine.clone()).build().expect("tokio runtime and config load for wallpaper bridge")
}

#[tokio::test]
async fn a_scene_is_read_with_its_saved_choices_not_the_editors_draft() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);
    bridge.inject_scene_project_for_test("rain", "Rain", PROJECT).await;
    bridge
        .edit_property("rain".into(), "rain".into(), BridgePropertyValue::Bool { value: true })
        .await
        .unwrap();

    bridge.scene_capability("rain".into()).await.unwrap();
    let draft_only = engine.scene_probe_calls().pop().expect("the scene was read");
    assert!(draft_only.project_file.ends_with("rain/project.json"));
    assert!(
        !draft_only.property_overrides.as_deref().unwrap_or("").contains("\"rain\":true"),
        "an edit waiting for Apply is not what loading the scene would use"
    );

    let mut saved = WallpaperConfig::new_for("rain", "scene");
    saved.property_overrides.insert("rain".into(), serde_json::json!(true));
    bridge.replace_wallpaper_config_for_test("rain", saved).await;
    bridge.scene_capability("rain".into()).await.unwrap();
    let applied = engine.scene_probe_calls().pop().expect("the scene was read again");
    assert!(applied.property_overrides.as_deref().unwrap_or("").contains("\"rain\":true"));
}

#[tokio::test]
async fn the_engines_answer_is_handed_on_with_empty_fields_as_none() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);
    bridge.inject_scene_project_for_test("rain", "Rain", PROJECT).await;

    let clean = bridge.scene_capability("rain".into()).await.unwrap();
    assert_eq!((clean.read_error, clean.failure_stage, clean.failure_reason), (None, None, None));
    assert!(clean.missing_files.is_empty());

    engine.set_scene_probe_answer(SceneCapabilityProbe {
        read_error: String::new(),
        failure_stage: "unsupported".into(),
        failure_reason: "the scene uses a light probe".into(),
        missing_files: vec![SceneMissingFile {
            layer: "Drops".into(),
            object_id: 12,
            path: "materials/drops.json".into(),
        }],
    });
    let refused = bridge.scene_capability("rain".into()).await.unwrap();
    assert_eq!(refused.failure_stage.as_deref(), Some("unsupported"));
    assert_eq!(refused.failure_reason.as_deref(), Some("the scene uses a light probe"));
    assert_eq!(
        refused.missing_files,
        vec![BridgeSceneMissingFile {
            layer: "Drops".into(),
            object_id: 12,
            path: "materials/drops.json".into()
        }]
    );
}

#[tokio::test]
async fn only_an_installed_scene_can_be_read() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);
    bridge
        .inject_scene_project_for_test("page", "Page", r#"{"type":"web","file":"index.html","title":"Page"}"#)
        .await;
    for id in ["page", "missing", "../outside"] {
        let error = bridge.scene_capability(id.into()).await.unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput, "{id}");
    }
    assert!(engine.scene_probe_calls().is_empty(), "nothing was read for them");
}
