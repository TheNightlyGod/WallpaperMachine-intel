// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The header and the static library, used the way the engine uses them: a small C program
// (tests/c/abi_smoke.c) is compiled against include/rs_shader.h, linked with libwm_shader.a and
// run; the header is also parsed as C++; the archive's exported symbols are exactly the thirteen
// of the contract. Skips with a printed reason without clang, nm or a buildable library.

#![cfg(feature = "ffi")]

use std::path::PathBuf;
use std::process::Command;
use std::sync::LazyLock;

const EXPORTED: [&str; 13] = [
    "rs_shader_cache_identity",
    "rs_shader_compile_program",
    "rs_shader_last_error",
    "rs_shader_program_cache_key",
    "rs_shader_program_diagnostics_json",
    "rs_shader_program_free",
    "rs_shader_program_metadata_json",
    "rs_shader_program_reflection_json",
    "rs_shader_program_stage_count",
    "rs_shader_program_stage_kind",
    "rs_shader_program_stage_metal_json",
    "rs_shader_program_stage_msl_source",
    "rs_shader_program_stage_target",
];

fn have(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok()
}

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Builds the static library with ffi and this test binary's diagnostic feature selection,
/// in its profile and target directory (None, printed, when that cannot be done here).
fn static_library() -> Option<PathBuf> {
    // Once per test binary: the tests run in parallel and must not read the archive while
    // another one is relinking it.
    static BUILT: LazyLock<Option<PathBuf>> = LazyLock::new(build_static_library);
    BUILT.clone()
}

fn build_static_library() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    // <target>/<profile>/deps/<test> -> <target>/<profile>
    let profile_dir = exe.parent()?.parent()?.to_path_buf();
    let target_dir = profile_dir.parent()?.to_path_buf();
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_string());
    let features = if cfg!(feature = "observer-uniform-layout") { "ffi,observer-uniform-layout" } else { "ffi" };
    let mut command = Command::new(cargo);
    command
        .args(["build", "--lib", "-p", "wm-shader", "--features", features, "--quiet"])
        .arg("--target-dir")
        .arg(&target_dir)
        .current_dir(manifest_dir());
    if profile_dir.file_name().is_some_and(|n| n == "release") {
        command.arg("--release");
    }
    match command.output() {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            eprintln!("skipped: building the static library failed: {}", String::from_utf8_lossy(&o.stderr));
            return None;
        }
        Err(e) => {
            eprintln!("skipped: cargo is not available: {e}");
            return None;
        }
    }
    let lib = profile_dir.join("libwm_shader.a");
    if lib.exists() {
        Some(lib)
    } else {
        eprintln!("skipped: {} was not produced", lib.display());
        None
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("c_abi").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn show(output: &std::process::Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr))
}

#[test]
fn a_c_program_links_the_static_library_and_runs() {
    if !have("clang") {
        eprintln!("skipped: clang is not available");
        return;
    }
    let Some(lib) = static_library() else { return };
    let dir = scratch("smoke");
    let binary = dir.join("abi_smoke");
    let compile = Command::new("clang")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror", "-I"])
        .arg(manifest_dir().join("include"))
        .arg(manifest_dir().join("tests/c/abi_smoke.c"))
        .arg(&lib)
        .args(["-lSystem", "-lc", "-lm", "-o"])
        .arg(&binary)
        .output()
        .expect("clang starts");
    assert!(compile.status.success(), "{}", show(&compile));
    let run = Command::new(&binary).output().expect("the C program starts");
    assert!(run.status.success(), "{}", show(&run));
    // The library writes nothing to the standard streams on its own, failed compiles included (R93).
    assert_eq!(String::from_utf8_lossy(&run.stdout), "c abi ok\n");
    assert_eq!(String::from_utf8_lossy(&run.stderr), "");
    let _ = std::fs::remove_file(&binary);
}

#[test]
fn a_caller_that_declares_only_the_thirteen_functions_links_and_compiles_a_quad() {
    if !have("clang") {
        eprintln!("skipped: clang is not available");
        return;
    }
    let Some(lib) = static_library() else { return };
    let dir = scratch("thirteen");
    let binary = dir.join("thirteen_only");
    let compile = Command::new("clang")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
        .arg(manifest_dir().join("tests/c/thirteen_only.c"))
        .arg(&lib)
        .args(["-lSystem", "-lc", "-lm", "-o"])
        .arg(&binary)
        .output()
        .expect("clang starts");
    assert!(compile.status.success(), "{}", show(&compile));
    let run = Command::new(&binary).output().expect("the C program starts");
    assert!(run.status.success(), "{}", show(&run));
    assert_eq!(String::from_utf8_lossy(&run.stdout), "thirteen ok\n");
    let _ = std::fs::remove_file(&binary);
}

#[test]
fn the_header_parses_as_c_and_as_cplusplus() {
    if !have("clang") {
        eprintln!("skipped: clang is not available");
        return;
    }
    let header = manifest_dir().join("include/rs_shader.h");
    for (language, standard) in [("c", "-std=c11"), ("c++", "-std=c++17")] {
        let out = Command::new("clang")
            .args(["-fsyntax-only", "-Wall", "-Wextra", "-Werror", standard, "-x", language])
            .arg(&header)
            .output()
            .expect("clang starts");
        assert!(out.status.success(), "{language}: {}", show(&out));
    }
}

#[test]
fn the_archive_exports_exactly_the_contract() {
    if !have("nm") {
        eprintln!("skipped: nm is not available");
        return;
    }
    let Some(lib) = static_library() else { return };
    let out = Command::new("nm").arg("-gU").arg(&lib).output().expect("nm starts");
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let mut exported: Vec<&str> = text
        .lines()
        .filter_map(|l| l.split_whitespace().last())
        .filter_map(|name| name.strip_prefix('_'))
        .filter(|name| name.starts_with("rs_shader_"))
        .collect();
    exported.sort_unstable();
    exported.dedup();
    assert_eq!(exported, EXPORTED, "the exported rs_shader_ symbols");
    // the header declares the same names
    let header = std::fs::read_to_string(manifest_dir().join("include/rs_shader.h")).unwrap();
    for name in EXPORTED {
        assert!(header.contains(&format!("{name}(")), "{name}");
    }
}
