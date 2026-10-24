//! Guards on how the engine's C boundary is declared: every callable
//! declaration unwinds safely, and the retired descriptor layer stays gone.

use std::{
    fs,
    path::{Path, PathBuf},
};

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()))
}

/// Every file with one of the source extensions below `root`, recursively.
fn source_files(root: &Path, found: &mut Vec<PathBuf>) {
    const EXTENSIONS: [&str; 5] = ["rs", "h", "hpp", "mm", "cpp"];
    if root.is_file() {
        found.push(root.to_path_buf());
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            source_files(&path, found);
        } else if path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| EXTENSIONS.contains(&extension))
        {
            found.push(path);
        }
    }
}

#[test]
fn engine_calls_are_declared_with_the_unwinding_abi() {
    let root = manifest_dir();
    let sources = ["src/owe/unwind.rs", "src/owe/backend.rs", "build.rs"]
        .map(|relative| read(&root.join(relative)))
        .join("\n");
    let bindings = read(&Path::new(env!("OUT_DIR")).join("owe_backend_bindings.rs"));

    assert!(
        sources.contains("bindgen::Abi::CUnwind"),
        "build.rs must ask bindgen for the C-unwind ABI"
    );
    assert!(
        !sources.contains("unsafe extern \"C\""),
        "a hand-written plain C block lets a panic cross the boundary"
    );
    assert!(
        bindings.contains("extern \"C-unwind\""),
        "the generated bindings must use the C-unwind ABI"
    );
    assert!(
        !bindings.contains("unsafe extern \"C\""),
        "the generated bindings must not use the plain C ABI"
    );
}

#[test]
fn the_retired_scene_descriptor_layer_does_not_come_back() {
    const RETIRED: [&str; 8] = [
        "RawDisplayDesc",
        "RawSceneDesc",
        "RawSceneResult",
        "OweSceneRequest",
        "RuntimeManager",
        "owe_backend_scene_desc",
        "owe_scene_desc",
        "owe_scene_result",
    ];
    let manifest = manifest_dir();
    let workspace = manifest.join("..");
    let mut files = Vec::new();
    for root in [
        manifest.join("build.rs"),
        manifest.join("src/engine.rs"),
        manifest.join("src/owe"),
        workspace.join("Engine/src/Platform/Apple"),
    ] {
        source_files(&root, &mut files);
    }
    assert!(!files.is_empty(), "no source files were found to check");

    for file in files {
        let text = read(&file);
        for token in RETIRED {
            assert!(!text.contains(token), "{} mentions {token}", file.display());
        }
    }
}
