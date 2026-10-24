//! Fallback commit id for bare `cargo` builds.
//!
//! `scripts/build.py` exports `GIT_SHORT_COMMIT`, which `snapshots.rs` prefers. When it is
//! absent this script asks git for the short commit, and falls back to "unknown" when git or
//! the repository is unavailable (for example a source tarball).

use std::path::PathBuf;
use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn watch(path: &str) {
    if let Some(dir) = git(&["rev-parse", "--path-format=absolute", "--git-path", path]) {
        // Cargo treats a missing rerun-if-changed path as always stale, which would rebuild
        // the crate on every invocation, so only watch paths that exist right now.
        let path = PathBuf::from(dir);
        if path.exists() {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=GIT_SHORT_COMMIT");
    if std::env::var_os("GIT_SHORT_COMMIT").is_none() {
        // HEAD changes on checkout; the branch ref (loose or packed) changes on commit.
        watch("HEAD");
        if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
            watch(&reference);
        }
        watch("packed-refs");
        // A branch ref created or packed later appears under this directory.
        watch("refs/heads");
    }
    let commit = git(&["rev-parse", "--short=8", "HEAD"]).unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=WM_FALLBACK_GIT_SHORT_COMMIT={commit}");
}
