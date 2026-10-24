// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
//! Build script: generates the Rust declarations of the engine's C ABI, builds the
//! engine's CMake target and tells cargo how to link the resulting archives.

use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
};

/// Environment variables whose change must re-run this script.
const WATCHED_VARIABLES: [&str; 4] = [
    "CMAKE",
    "CMAKE_BUILD_TYPE",
    "OWE_NIX_LIBRARY_PATH",
    "OWE_MACOSX_DEPLOYMENT_TARGET",
];

/// Static archives, each listed before the archives it depends on.
const STATIC_ARCHIVES: [&str; 15] = [
    "wescene-renderer",
    "wpAudio",
    "wmSound",
    "stb_vorbis",
    "wpLooper",
    "wpMetalRender",
    "wpRenderCommon",
    "wpScene",
    "wpRGraph",
    "wpParticle",
    "wpTimer",
    "wpUtils",
    "wmMediaApple",
    "wmMedia",
    "wmSurface",
];

const SHARED_LIBRARIES: [&str; 4] = ["c++", "lz4", "freetype", "qjs"];

const FRAMEWORKS: [&str; 12] = [
    "Accelerate",
    "AppKit",
    "AudioToolbox",
    "CoreGraphics",
    "CoreMedia",
    "CoreVideo",
    "Foundation",
    "IOSurface",
    "Metal",
    "OpenGL",
    "QuartzCore",
    "VideoToolbox",
];

/// Folders of the CMake build tree (relative to it) that hold the archives above.
const ARCHIVE_FOLDERS: [&str; 15] = [
    "src",
    "src/Audio",
    "src/Looper",
    "src/Scene",
    "src/Scene/Particle",
    "src/Scene/RenderCommon",
    "src/Scene/RenderGraph",
    "src/Scene/Timer",
    "src/Scene/MetalRender",
    "src/Utils",
    "Dependencies",
    "Renderer/Sound",
    "Renderer/Media",
    "Renderer/Media/Apple",
    "Renderer/Surface",
];

/// Where everything this script reads or writes lives.
struct Layout {
    engine_dir: PathBuf,
    /// The other source folders the engine's CMake build compiles: the project's
    /// C++ areas beside the engine and the vendored C libraries.
    engine_inputs: [PathBuf; 4],
    wrapper_header: PathBuf,
    wrapper_impl: PathBuf,
    out_dir: PathBuf,
}

impl Layout {
    fn discover() -> Self {
        let crate_dir = PathBuf::from(
            env::var_os("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"),
        );
        let workspace = crate_dir
            .parent()
            .expect("the core crate sits one level below the workspace root");
        let engine_dir = workspace.join("Engine");
        let apple = engine_dir.join("src/Platform/Apple");
        Self {
            wrapper_header: apple.join("SceneWallpaperBindings.h"),
            wrapper_impl: apple.join("SceneWallpaperBindings.mm"),
            engine_inputs: [
                workspace.join("Media"),
                workspace.join("Sound"),
                workspace.join("Surface"),
                workspace.join("../ThirdParty"),
            ],
            out_dir: PathBuf::from(env::var_os("OUT_DIR").expect("cargo sets OUT_DIR")),
            engine_dir,
        }
    }

    fn cmake_prefix(&self) -> PathBuf {
        self.out_dir.join("engine")
    }
}

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").map_or(true, |os| os != "macos") {
        return;
    }
    let layout = Layout::discover();

    announce_rerun_triggers(&layout);
    write_abi_declarations(&layout);
    build_engine(&layout);
    announce_link_inputs(&layout.cmake_prefix().join("build"));
}

fn announce_rerun_triggers(layout: &Layout) {
    for variable in WATCHED_VARIABLES {
        println!("cargo:rerun-if-env-changed={variable}");
    }
    let watched_paths = [&layout.engine_dir, &layout.wrapper_header, &layout.wrapper_impl]
        .into_iter()
        .chain(&layout.engine_inputs);
    for path in watched_paths {
        println!("cargo:rerun-if-changed={}", path.display());
    }
}

/// The declarations must exist before rustc runs, and they must come from the very
/// header the archive is built against.
fn write_abi_declarations(layout: &Layout) {
    let target = layout.out_dir.join("owe_backend_bindings.rs");
    bindgen::Builder::default()
        .header(layout.wrapper_header.to_string_lossy())
        .allowlist_function("owe_.*")
        .allowlist_type("owe_.*")
        .derive_default(true)
        .generate_comments(true)
        .layout_tests(false)
        // The engine may unwind through these calls; the safe wrappers catch it.
        .override_abi(bindgen::Abi::CUnwind, "owe_.*")
        .generate()
        .expect("bindgen could not process the engine's C header")
        .write_to_file(&target)
        .expect("could not write the generated engine declarations");
}

/// Builds the renderer target. The deployment target travels under a private variable
/// name: setting `MACOSX_DEPLOYMENT_TARGET` for cargo would also reach host-side
/// proc-macro builds, whose dylibs the compiler then refuses to load.
fn build_engine(layout: &Layout) {
    let minimum_os: Option<OsString> = env::var_os("OWE_MACOSX_DEPLOYMENT_TARGET");
    let prefix = layout.cmake_prefix();

    let mut cmake_config = cmake::Config::new(&layout.engine_dir);
    cmake_config.out_dir(&prefix);
    for (name, value) in [
        ("BUILD_TESTING", "OFF"),
        ("BUILD_TESTS", "OFF"),
        ("RUST_SHADER_FFI", "ON"),
    ] {
        cmake_config.define(name, value);
    }
    if let Some(minimum_os) = minimum_os {
        cmake_config.define("CMAKE_OSX_DEPLOYMENT_TARGET", minimum_os);
    }
    let produced = cmake_config.build_target("wescene-renderer").build();
    debug_assert_eq!(produced, prefix);
}

fn announce_link_inputs(build_tree: &Path) {
    let extra_dirs = env::var_os("OWE_NIX_LIBRARY_PATH")
        .map(|joined| env::split_paths(&joined).collect::<Vec<_>>())
        .unwrap_or_default();
    let search_dirs = ARCHIVE_FOLDERS
        .iter()
        .map(|folder| build_tree.join(folder))
        .chain(extra_dirs);
    for dir in search_dirs {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }

    let kinds: [(&str, &[&str]); 3] = [
        ("static", &STATIC_ARCHIVES),
        ("dylib", &SHARED_LIBRARIES),
        ("framework", &FRAMEWORKS),
    ];
    for (kind, names) in kinds {
        for name in names {
            println!("cargo:rustc-link-lib={kind}={name}");
        }
    }
}
