use std::collections::BTreeMap;

use serde_json::{Value, json};
use wallpaper_core::project::{ScenePropertyOverrideError, SerdeValudeExt};

#[test]
fn nested_and_scalar_leaves_preserve_values_and_serialize_in_key_order() {
    let input = json!({
        "zebra": false,
        "panel": {
            "title": "North window",
            "layout": {
                "columns": 7,
                "enabled": true
            }
        },
        "alpha": "independent",
        "count": 19
    });

    let flattened = input.flatten().expect("supported leaves should flatten");
    let expected: BTreeMap<String, Value> = BTreeMap::from([
        ("alpha".into(), json!("independent")),
        ("count".into(), json!(19)),
        ("panel_layout_columns".into(), json!(7)),
        ("panel_layout_enabled".into(), json!(true)),
        ("panel_title".into(), json!("North window")),
        ("zebra".into(), json!(false)),
    ]);

    assert_eq!(flattened, expected);
    assert_eq!(
        serde_json::to_string(&flattened).expect("flattened values should serialize"),
        r#"{"alpha":"independent","count":19,"panel_layout_columns":7,"panel_layout_enabled":true,"panel_title":"North window","zebra":false}"#
    );
}

#[test]
fn root_and_nested_null_leaves_normalize_without_changing_other_values() {
    let input = json!({
        "caption": null,
        "motion": {
            "curve": { "label": null },
            "active": false,
            "speed": 2.5
        },
        "title": "Still water"
    });

    let flattened = input.flatten().expect("null leaves should normalize");
    let expected: BTreeMap<String, Value> = BTreeMap::from([
        ("caption".into(), json!("")),
        ("motion_active".into(), json!(false)),
        ("motion_curve_label".into(), json!("")),
        ("motion_speed".into(), json!(2.5)),
        ("title".into(), json!("Still water")),
    ]);

    assert_eq!(flattened, expected);
}

#[test]
fn nested_array_leaf_reports_its_complete_underscore_joined_path() {
    let input = json!({
        "scene": {
            "layer": {
                "frames": [true, 12, "dawn"],
                "visible": true
            },
            "opacity": 0.75
        },
        "title": "Morning"
    });

    match input.flatten() {
        Err(ScenePropertyOverrideError::UnsupportedLeafType(path)) => {
            assert_eq!(path, "scene_layer_frames");
        }
        other => panic!("expected UnsupportedLeafType for nested array, got {other:?}"),
    }
}
