use serde_json::Value;
use wallpaper_core::project::{ScenePropertyOverrideError, SerdeValudeExt};

#[path = "project_override_json/independent_contract.rs"]
mod independent_contract;

#[test]
fn an_empty_parent_key_still_joins_its_children_with_an_underscore() {
    let flattened = serde_json::from_str::<Value>(r#"{"":{"a":1},"a":2}"#)
        .expect("valid override json")
        .flatten()
        .expect("flattening should succeed");
    let flattened = serde_json::to_string(&flattened).expect("flattened json should serialize");
    assert_eq!(flattened, r#"{"_a":1,"a":2}"#);

    let error = serde_json::from_str::<Value>(r#"{"":1}"#)
        .expect("valid override json")
        .flatten()
        .unwrap_err();
    assert!(matches!(error, ScenePropertyOverrideError::EmptyPath));
}
