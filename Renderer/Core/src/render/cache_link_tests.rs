use super::*;
use std::os::unix::fs::symlink;

#[test]
fn invalid_link_metadata_remains_a_render_error() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("resources");
    fs::create_dir(&root).unwrap();
    symlink("cycle-b", root.join("cycle-a")).unwrap();
    symlink("cycle-a", root.join("cycle-b")).unwrap();
    let error = resource_stamps(&root, &temp.path().join("cache")).unwrap_err();
    assert!(matches!(error, crate::EngineError::Render(_)));
}

#[test]
fn file_links_into_cache_do_not_invalidate_their_own_sources() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("resources");
    fs::create_dir(&root).unwrap();
    let project = root.join("project.json");
    let entry = root.join("scene.json");
    let source = root.join("source.txt");
    let external = temp.path().join("external.txt");
    let cache = root.join("cache");
    fs::write(&project, "{}").unwrap();
    fs::write(&entry, "{}").unwrap();
    fs::write(&source, "source").unwrap();
    fs::write(&external, "external").unwrap();
    // Both links initially dangle; the first points into a cache that does not yet exist.
    symlink(cache.join("scene/compiled"), root.join("compiled-link")).unwrap();
    symlink(root.join("compiled-link"), root.join("compiled-chain")).unwrap();
    let repaired = temp.path().join("repaired.txt");
    symlink(&repaired, root.join("repaired-link")).unwrap();
    symlink(&external, root.join("external-link")).unwrap();
    let directory = temp.path().join("directory");
    fs::create_dir(&directory).unwrap();
    fs::write(directory.join("ignored.txt"), "ignored").unwrap();
    symlink(&directory, root.join("directory-link")).unwrap();
    let inputs = ShaderCacheInputs::builder("scene", &cache)
        .project_json_path(&project)
        .scene_pkg_path(root.join("missing.pkg"))
        .unpacked_source(&entry, &root)
        .build()
        .unwrap();

    let first = ShaderCacheDecision::prepare(&inputs).unwrap();
    assert!(first.purged_cache());
    let compiled = first.scene_cache_path().join("compiled");
    fs::write(&compiled, "cached shader").unwrap();
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    assert_eq!(fs::read_to_string(&compiled).unwrap(), "cached shader");
    fs::write(&compiled, "changed cache artifact").unwrap();
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );

    fs::write(&source, "changed real source with different length").unwrap();
    assert!(
        ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    assert!(!compiled.exists());
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    fs::write(
        &external,
        "changed external link target with different length",
    )
    .unwrap();
    assert!(
        ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    fs::write(
        directory.join("ignored.txt"),
        "directory links stay ignored",
    )
    .unwrap();
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    fs::write(&repaired, "now a regular file").unwrap();
    assert!(
        ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
    assert!(
        !ShaderCacheDecision::prepare(&inputs)
            .unwrap()
            .purged_cache()
    );
}
