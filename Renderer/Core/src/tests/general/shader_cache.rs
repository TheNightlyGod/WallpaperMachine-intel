use std::fs;

#[test]
fn unpacked_scene_cache_tracks_entries_and_resources_without_tracking_itself() {
    for entry in ["scene.json", "scenes/custom.json"] {
        let root = tempfile::tempdir().unwrap();
        let entry_path = root.path().join(entry);
        fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
        fs::write(&entry_path, r#"{"objects":[]}"#).unwrap();
        let project = root.path().join("project.json");
        fs::write(&project, serde_json::json!({"type":"scene","file":entry}).to_string()).unwrap();
        let shaders = root.path().join("shaders");
        fs::create_dir_all(&shaders).unwrap();
        let shader = shaders.join("common.glsl");
        fs::write(&shader, "float value = 1.0;\n").unwrap();
        let descriptor = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 100, 100, 1.0), project.to_string_lossy())
            .shader_cache_path(root.path().join("cache").to_string_lossy()).build().unwrap();
        let cache = std::path::PathBuf::from(descriptor.shader_cache_path().unwrap().unwrap());
        let artifact = cache.join("compiled-shader");
        fs::write(&artifact, "cached").unwrap();
        assert_eq!(descriptor.shader_cache_path().unwrap().as_deref(), cache.to_str());
        assert!(artifact.is_file(), "cache outputs must not invalidate source fingerprints");
        #[cfg(unix)]
        {
            let target = root.path().join("optional.glsl");
            std::os::unix::fs::symlink(&target, root.path().join("optional-link.glsl")).unwrap();
            descriptor.shader_cache_path().unwrap();
            assert!(artifact.is_file(), "a dangling link must not prevent loading or invalidate the cache");
            fs::write(&target, "float optional = 1.0;").unwrap();
            descriptor.shader_cache_path().unwrap();
            assert!(!artifact.exists(), "a repaired link must participate in cache freshness");
            fs::write(&artifact, "cached").unwrap();
        }
        fs::write(&shader, "float value = 22.0;\n").unwrap();
        descriptor.shader_cache_path().unwrap();
        assert!(!artifact.exists(), "changed physical shader resources invalidate the cache");
        fs::write(&artifact, "cached").unwrap();
        fs::write(&entry_path, r#"{"objects":[],"general":{}}"#).unwrap();
        descriptor.shader_cache_path().unwrap();
        assert!(!artifact.exists(), "the custom entry participates in freshness");
    }
}
