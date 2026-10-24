use std::fs;
use std::path::{Path, PathBuf};

use crate::project::{
    ProjectManifest, ProjectProperties, SceneDesc, SceneFile, SceneSourceResolution,
    WallpaperProjectType,
};
use crate::render::{ShaderCacheDecision, ShaderCacheInputs};
use crate::{DisplayDesc, EngineError};
use serde_json::{Value, json};

// Keep the allocation alive while using its canonical path, including all unsafe-path targets.
struct OwnedRoot {
    _directory: tempfile::TempDir,
    path: PathBuf,
}

impl OwnedRoot {
    fn new() -> Self {
        let directory = tempfile::tempdir().expect("allocate isolated temporary directory");
        let path = directory
            .path()
            .canonicalize()
            .expect("canonicalize owned root");
        Self {
            _directory: directory,
            path,
        }
    }

    fn write(&self, relative: &str, contents: &[u8]) -> PathBuf {
        let relative = Path::new(relative);
        assert!(
            relative
                .components()
                .all(|component| matches!(component, std::path::Component::Normal(_)))
        );
        let path = self.path.join(relative);
        fs::create_dir_all(path.parent().expect("owned file parent"))
            .expect("create owned directories");
        fs::write(&path, contents).expect("write owned file");
        path
    }

    fn write_json(&self, relative: &str, value: &Value) -> PathBuf {
        self.write(
            relative,
            &serde_json::to_vec(value).expect("serialize fixture"),
        )
    }
}

fn require_invalid_input<T>(result: Result<T, EngineError>) {
    match result {
        Err(EngineError::InvalidInput(_)) => {}
        Err(other) => panic!("expected InvalidInput, got {other:?}"),
        Ok(_) => panic!("unsafe or invalid input unexpectedly accepted"),
    }
}

fn display() -> DisplayDesc {
    DisplayDesc::new(19, 0, 0, 1280, 720, 1.0)
}

fn write_manifest(root: &OwnedRoot, entry: &str) -> PathBuf {
    root.write_json(
        "project/project.json",
        &json!({"type": "scene", "file": entry}),
    )
}

#[test]
fn scene_descriptor_rejects_empty_scene_path() {
    require_invalid_input(SceneDesc::builder(display(), "").fps(30).build());
}

#[test]
fn scene_descriptor_rejects_zero_fps_with_nonempty_path() {
    let root = OwnedRoot::new();
    let manifest = write_manifest(&root, "scene.json");
    root.write_json("project/scene.json", &json!({"objects": []}));
    require_invalid_input(
        SceneDesc::builder(display(), manifest.to_string_lossy().into_owned())
            .fps(0)
            .build(),
    );
}

#[test]
fn disk_manifest_and_properties_preserve_types_order_and_original_values() {
    let root = OwnedRoot::new();
    let manifest_path = root.write_json(
        "project.json",
        &json!({
            "type": "scene",
            "file": "painted-scene.json",
            "workshopid": 73190542,
            "dependencies": ["second-library", "first-library/resources"],
            "general": {"properties": {
                "intensity": {"value": 1.25},
                "enabled": {"value": false},
                "caption": {"value": "unchanged caption"}
            }}
        }),
    );
    let manifest = ProjectManifest::load(&manifest_path).expect("load real manifest");
    assert_eq!(manifest.project_type(), WallpaperProjectType::Scene);
    assert_eq!(manifest.file(), "painted-scene.json");
    assert_eq!(manifest.workshop_id(), "73190542");
    assert_eq!(
        manifest.dependency_paths(&root.path),
        vec![
            root.path.join("second-library"),
            root.path.join("first-library/resources"),
        ]
    );

    let original = ProjectProperties::load(&manifest_path).expect("load general.properties");
    let snapshot = original.clone();
    assert_eq!(original.get("intensity").expect("number").as_float(), 1.25);
    assert!(!original.get("enabled").expect("boolean").as_bool());
    assert_eq!(
        original.get("caption").expect("string").as_string(),
        "unchanged caption"
    );
    let updated = original
        .apply_override(r#"{"intensity":6.5,"enabled":true,"new_toggle":false}"#)
        .expect("apply scalar overrides");
    assert_eq!(
        updated.get("intensity").expect("updated number").as_float(),
        6.5
    );
    assert!(updated.get("enabled").expect("updated boolean").as_bool());
    assert!(!updated.get("new_toggle").expect("added boolean").as_bool());
    assert_eq!(updated.get("caption"), original.get("caption"));
    assert_eq!(
        updated
            .get("caption")
            .expect("preserved string")
            .as_string(),
        "unchanged caption"
    );
    assert_ne!(updated.get("intensity"), original.get("intensity"));
    assert_ne!(updated.get("enabled"), original.get("enabled"));
    assert!(original.get("new_toggle").is_none());
    assert_eq!(original, snapshot);
}

#[test]
fn public_source_resolver_accepts_relative_scene_then_rejects_existing_unsafe_targets() {
    let root = OwnedRoot::new();
    let scene = json!({"objects": []});
    root.write_json("project/scene.json", &scene);
    let parent_target = root.write_json("parent-scene.json", &scene);
    let absolute_target = root.write_json("absolute-scene.json", &scene);
    let manifest = write_manifest(&root, "scene.json");
    SceneSourceResolution::load(&manifest).expect("positive resolver control");

    assert!(parent_target.is_file());
    write_manifest(&root, "../parent-scene.json");
    require_invalid_input(SceneSourceResolution::load(&manifest));

    assert!(absolute_target.is_file());
    write_manifest(
        &root,
        absolute_target.to_str().expect("temporary path is UTF-8"),
    );
    require_invalid_input(SceneSourceResolution::load(&manifest));
}

#[test]
fn public_scene_loader_accepts_relative_scene_then_rejects_existing_unsafe_targets() {
    let root = OwnedRoot::new();
    let scene = json!({"objects": []});
    root.write_json("project/scene.json", &scene);
    let parent_target = root.write_json("parent-scene.json", &scene);
    let absolute_target = root.write_json("absolute-scene.json", &scene);
    let assets = root.path.join("project/assets");
    fs::create_dir_all(&assets).expect("create owned asset root");
    let manifest = write_manifest(&root, "scene.json");
    SceneFile::load_project(&manifest, &assets).expect("positive scene-loader control");

    assert!(parent_target.is_file());
    write_manifest(&root, "../parent-scene.json");
    require_invalid_input(SceneFile::load_project(&manifest, &assets));

    assert!(absolute_target.is_file());
    write_manifest(
        &root,
        absolute_target.to_str().expect("temporary path is UTF-8"),
    );
    require_invalid_input(SceneFile::load_project(&manifest, &assets));
}

#[test]
fn scene_loader_rejects_escaping_image_after_loading_existing_valid_asset() {
    let root = OwnedRoot::new();
    let asset = json!({});
    root.write_json("project/assets/image.json", &asset);
    let escaped_asset = root.write_json("project/outside-image.json", &asset);
    let assets = root.path.join("project/assets");
    let manifest = write_manifest(&root, "scene.json");
    root.write_json(
        "project/scene.json",
        &json!({"objects": [{"image": "image.json"}]}),
    );
    SceneFile::load_project(&manifest, &assets).expect("positive existing-asset control");

    assert!(escaped_asset.is_file());
    root.write_json(
        "project/scene.json",
        &json!({"objects": [{"image": "../outside-image.json"}]}),
    );
    require_invalid_input(SceneFile::load_project(&manifest, &assets));
}

fn packaged_inputs(root: &OwnedRoot, override_json: Option<&str>) -> ShaderCacheInputs {
    ShaderCacheInputs::builder("painted-room", root.path.join("cache"))
        .project_json_path(root.path.join("project.json"))
        .scene_pkg_path(root.path.join("scene.pkg"))
        .property_override_json(override_json)
        .build()
        .expect("build packaged metadata inputs")
}

fn write_packaged_metadata_inputs(root: &OwnedRoot) {
    root.write_json(
        "project.json",
        &json!({"type": "scene", "file": "scene.json"}),
    );
    // These bytes are opaque metadata inputs, not a claimed decodable scene package.
    root.write("scene.pkg", b"opaque cache-policy input 8429");
}

#[test]
fn packaged_cache_cold_purges_and_unchanged_warm_preserves_compiled_artifact() {
    let root = OwnedRoot::new();
    write_packaged_metadata_inputs(&root);
    let inputs = packaged_inputs(&root, None);
    let cold = ShaderCacheDecision::prepare(&inputs).expect("cold cache preparation");
    assert!(cold.purged_cache());
    assert_eq!(
        cold.scene_cache_path(),
        root.path.join("cache/painted-room")
    );
    let artifact = cold.scene_cache_path().join("caller-compiled.bin");
    fs::write(&artifact, b"compiled shader sentinel").expect("write compiled artifact");

    let warm = ShaderCacheDecision::prepare(&inputs).expect("warm cache preparation");
    assert!(!warm.purged_cache());
    assert_eq!(warm.scene_cache_path(), cold.scene_cache_path());
    assert_eq!(
        fs::read(&artifact).expect("preserved compiled artifact"),
        b"compiled shader sentinel"
    );
}

#[test]
fn raw_override_change_purges_then_identical_override_reuses_artifact() {
    let root = OwnedRoot::new();
    write_packaged_metadata_inputs(&root);
    let before = packaged_inputs(&root, Some(r#"{"amount":2}"#));
    let initial = ShaderCacheDecision::prepare(&before).expect("initial cache preparation");
    assert!(initial.purged_cache());
    let artifact = initial.scene_cache_path().join("caller-compiled.bin");
    fs::write(&artifact, b"old compiled shader").expect("write old artifact");

    // Semantically identical JSON differs only in raw text: policy fingerprints raw overrides.
    let after = packaged_inputs(&root, Some(r#"{ "amount": 2 }"#));
    let changed = ShaderCacheDecision::prepare(&after).expect("changed override preparation");
    assert!(changed.purged_cache());
    assert_eq!(changed.scene_cache_path(), initial.scene_cache_path());
    assert!(
        !artifact.exists(),
        "override transition must remove old compiled artifact"
    );
    fs::write(&artifact, b"new compiled shader").expect("write replacement artifact");

    let repeated = ShaderCacheDecision::prepare(&after).expect("identical override preparation");
    assert!(!repeated.purged_cache());
    assert_eq!(repeated.scene_cache_path(), changed.scene_cache_path());
    assert_eq!(
        fs::read(&artifact).expect("preserved replacement artifact"),
        b"new compiled shader"
    );
}

#[test]
fn invalid_cache_ids_are_rejected_even_when_force_refresh_is_requested() {
    let root = OwnedRoot::new();
    write_packaged_metadata_inputs(&root);
    let sentinel = root.write("sibling-sentinel.bin", b"must remain untouched");
    let absolute = root.path.join("absolute-invalid-id");
    let ids = [
        "",
        "..",
        "../sibling-sentinel.bin",
        "nested/id",
        "nested\\id",
        ".",
        "nested/./id",
        absolute.to_str().expect("temporary path is UTF-8"),
    ];
    for id in ids {
        let result = ShaderCacheInputs::builder(id, root.path.join("cache"))
            .project_json_path(root.path.join("project.json"))
            .scene_pkg_path(root.path.join("scene.pkg"))
            .force_refresh(true)
            .build();
        // Never prepare an unexpectedly accepted invalid ID.
        require_invalid_input(result);
        assert_eq!(
            fs::read(&sentinel).expect("intact sibling sentinel"),
            b"must remain untouched"
        );
    }
}

#[test]
fn non_scene_descriptor_has_no_shader_cache_even_when_configured() {
    let root = OwnedRoot::new();
    let manifest = root.write_json(
        "web/project.json",
        &json!({"type": "web", "file": "index.html"}),
    );
    root.write(
        "web/index.html",
        b"<!doctype html><title>Owned web wallpaper</title>",
    );
    assert!(!root.path.join("web/scene.pkg").exists());
    let descriptor = SceneDesc::builder(display(), manifest.to_string_lossy().into_owned())
        .fps(30)
        .shader_cache_path(
            root.path
                .join("configured-cache")
                .to_string_lossy()
                .into_owned(),
        )
        .build()
        .expect("construct descriptor for real web project");
    assert_eq!(
        descriptor
            .shader_cache_path()
            .expect("query non-scene cache"),
        None
    );
}
