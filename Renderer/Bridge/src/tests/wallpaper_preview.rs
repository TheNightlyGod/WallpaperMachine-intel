use crate::{BridgeErrorKind, BridgePropertyEdit, BridgePropertyValue, WallpaperBridge};

#[tokio::test]
async fn preview_reads_the_draft_without_selecting_applying_or_consuming_it() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test("preview", "Preview", r#"{
        "type":"scene", "file":"scene.json", "title":"Preview",
        "general":{"properties":{"size":{"type":"slider","value":10,"min":0,"max":100}}}
    }"#).await;
    bridge.select_wallpaper("preview".into()).await.unwrap();
    bridge.edit_property("preview".into(), "size".into(), BridgePropertyValue::Number { value: 25.0 }).await.unwrap();
    let before = bridge.all_snapshots().await.unwrap();
    let preview = bridge.wallpaper_preview("preview".into(), "primary".into(), Vec::new(), Vec::new()).await.unwrap();
    let properties: serde_json::Value = serde_json::from_str(&preview.properties_json).unwrap();
    assert_eq!(properties["size"].as_f64(), Some(25.0));
    assert!(preview.fps <= 30 && preview.fps > 0);
    assert_eq!(bridge.all_snapshots().await.unwrap(), before);
    assert!(bridge.wallpaper_options_snapshot("preview".into()).await.unwrap().dirty);
    assert!(bridge.app_snapshot().await.unwrap().active_wallpaper_ids.is_empty());
}

#[tokio::test]
async fn web_preview_keeps_combo_json_types_and_can_preview_an_unselected_project() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test("web-preview", "Web", r#"{
        "type":"web", "file":"index.html", "title":"Web",
        "general":{"properties":{
            "number":{"type":"combo","value":2,"options":[{"label":"Two","value":2}]},
            "flag":{"type":"bool","value":true},
            "label":{"type":"text","text":"Read me"}
        }}
    }"#).await;
    let before = bridge.app_snapshot().await.unwrap();
    let preview = bridge.wallpaper_preview("web-preview".into(), "primary".into(), Vec::new(), Vec::new()).await.unwrap();
    let properties: serde_json::Value = serde_json::from_str(&preview.properties_json).unwrap();
    assert_eq!(properties["number"]["value"], 2);
    assert_eq!(properties["flag"]["value"], true);
    assert!(properties.get("label").is_none());
    assert_eq!(preview.entry_file, "index.html");
    assert_eq!(bridge.app_snapshot().await.unwrap(), before);
}

#[tokio::test]
async fn preview_refuses_unknown_and_escaping_identifiers() {
    let bridge = WallpaperBridge::new_for_test();
    for id in ["missing", "../outside", "/absolute", ""] {
        assert!(bridge.wallpaper_preview(id.into(), "primary".into(), Vec::new(), Vec::new()).await.is_err());
    }
}

fn pending(property: &str, value: BridgePropertyValue) -> BridgePropertyEdit {
    BridgePropertyEdit {
        property_id: property.into(),
        value,
    }
}

#[tokio::test]
async fn pending_values_are_exported_over_the_draft_and_the_draft_never_learns_of_them() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test("preview", "Preview", r#"{
        "type":"scene", "file":"scene.json", "title":"Preview",
        "general":{"properties":{
            "size":{"type":"slider","value":10,"min":0,"max":100},
            "tint":{"type":"color","value":"1 1 1"}
        }}
    }"#).await;
    bridge.edit_property("preview".into(), "size".into(), BridgePropertyValue::Number { value: 25.0 }).await.unwrap();
    let before = bridge.all_snapshots().await.unwrap();
    let options = bridge.wallpaper_options_snapshot("preview".into()).await.unwrap();

    let preview = bridge.wallpaper_preview("preview".into(), "primary".into(), vec![
        pending("size", BridgePropertyValue::Number { value: 40.0 }),
        pending("tint", BridgePropertyValue::ColorRgb { red: 0.0, green: 0.5, blue: 1.0 }),
    ], Vec::new()).await.unwrap();

    let properties: serde_json::Value = serde_json::from_str(&preview.properties_json).unwrap();
    assert_eq!(properties["size"].as_f64(), Some(40.0), "the step wins over the draft's 25");
    assert_eq!(properties["tint"], "0 0.5 1");
    assert_eq!(bridge.all_snapshots().await.unwrap(), before);
    assert_eq!(bridge.wallpaper_options_snapshot("preview".into()).await.unwrap(), options, "not even the draft's dirty marks move");

    let after = bridge.wallpaper_preview("preview".into(), "primary".into(), Vec::new(), Vec::new()).await.unwrap();
    let properties: serde_json::Value = serde_json::from_str(&after.properties_json).unwrap();
    assert_eq!(properties["size"].as_f64(), Some(25.0), "the next export is the draft again");
    assert_eq!(properties["tint"], "1 1 1");
}

#[tokio::test]
async fn a_web_preview_follows_pending_values_too() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test("web-preview", "Web", r#"{
        "type":"web", "file":"index.html", "title":"Web",
        "general":{"properties":{"flag":{"type":"bool","value":true}}}
    }"#).await;

    let preview = bridge.wallpaper_preview("web-preview".into(), "primary".into(), vec![
        pending("flag", BridgePropertyValue::Bool { value: false }),
    ], Vec::new()).await.unwrap();

    let properties: serde_json::Value = serde_json::from_str(&preview.properties_json).unwrap();
    assert_eq!(properties["flag"]["value"], false);
    assert!(!bridge.wallpaper_options_snapshot("web-preview".into()).await.unwrap().dirty);
}

#[tokio::test]
async fn a_pending_value_is_refused_for_what_an_edit_is_refused_for_and_nothing_is_exported() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test("preview", "Preview", r#"{
        "type":"scene", "file":"scene.json", "title":"Preview",
        "general":{"properties":{
            "size":{"type":"slider","value":10,"min":0,"max":100},
            "mode":{"type":"combo","value":"a","options":[{"label":"A","value":"a"}]},
            "label":{"type":"text","text":"Read me"}
        }}
    }"#).await;

    for (property, value) in [
        ("size", BridgePropertyValue::Number { value: 101.0 }),
        ("size", BridgePropertyValue::Number { value: f64::NAN }),
        ("size", BridgePropertyValue::String { value: "10".into() }),
        ("mode", BridgePropertyValue::String { value: "z".into() }),
        ("label", BridgePropertyValue::String { value: "x".into() }),
        ("missing", BridgePropertyValue::Bool { value: true }),
    ] {
        let editing = bridge.edit_property("preview".into(), property.into(), value.clone()).await.unwrap_err();
        let exporting = bridge.wallpaper_preview("preview".into(), "primary".into(), vec![pending(property, value.clone())], Vec::new())
            .await.unwrap_err();
        assert_eq!(exporting.kind(), BridgeErrorKind::InvalidInput, "{property} = {value:?}");
        assert_eq!(exporting.message(), editing.message(), "{property} = {value:?}");
    }
}
