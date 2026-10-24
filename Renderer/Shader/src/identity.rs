// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The compiler identity (R76 to R78): the string the engine folds into its
//! program cache key and the file name of its pipeline binary archive.
//!
//! It must change whenever the layer could answer a request it answered
//! before with a different response: any change to translation output, to
//! reflection, to metadata, to binding allocation, to the compiler
//! dependency, to the MSL language version or to the compile options. That
//! is a deliberate act: bump [`PIPELINE_REVISION`] in the same change, and
//! add the new row to the golden table in `cache_key.rs`, whose tests fail
//! when a stored program changes without a bump (R88). The opt-in layout
//! diagnostic uses a separate options identity; it is not an ordinary shipped revision.
//!
//! Nothing here varies per build or per launch: no timestamp, path or
//! process id (R78).

use std::sync::LazyLock;

/// Counts behavioural revisions of this layer. The first release of the
/// rewrite is 1; stored programs of the earlier implementation are stale.
///
/// The identity is compared only for equality: the revision is an opaque counter, not an ordered
/// version, and no consumer may compare identities numerically. It only ever grows: a counter that is
/// reset or reused would make a later build return a string an earlier build returned, so a stored
/// program of different output would hit. The table of shipped identities and the digest of their Metal
/// text is `SHIPPED` in `pipeline/tests/golden.rs`; a change of output appends a row there.
pub const PIPELINE_REVISION: u32 = 2;

/// Version of the vendored compiler library, checked against its manifest by a test.
pub const NAGA_VERSION: &str = "29.0.3";

/// The Metal Shading Language version the translated source targets (R25).
pub const MSL_LANGUAGE_VERSION: &str = "2.0";

/// The set of compile options in force: the source is left untransformed
/// (all three conventions of R26 are false).
#[cfg(not(feature = "observer-uniform-layout"))]
pub const COMPILE_OPTIONS: &str = "untransformed";
/// Diagnostic reflection must never hit an ordinary cached response without typed metadata.
#[cfg(feature = "observer-uniform-layout")]
pub const COMPILE_OPTIONS: &str = "untransformed-observer-uniform-layout-v1";

/// Builds an identity from its parts: `<revision>:<options identity>` (D R37). The options
/// identity names the translator, the Metal language version and the compile options, and only
/// uses ASCII letters, digits, `.` and `-`.
pub fn build_identity(revision: u32, compiler_version: &str, msl_version: &str, options: &str) -> String {
    format!("{revision}:naga-{compiler_version}-msl{msl_version}-{options}")
}

/// The identity of this build; computed once, valid for the process lifetime.
pub fn compiler_identity() -> &'static str {
    static IDENTITY: LazyLock<String> = LazyLock::new(|| build_identity(PIPELINE_REVISION, NAGA_VERSION, MSL_LANGUAGE_VERSION, COMPILE_OPTIONS));
    &IDENTITY
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_non_empty_and_stable() {
        let a = compiler_identity();
        assert!(!a.is_empty());
        assert_eq!(a, compiler_identity());
        assert!(std::ptr::eq(a, compiler_identity()), "one process-lifetime string");
    }

    #[test]
    fn identity_differs_from_the_stored_upstream_value() {
        assert_ne!(compiler_identity(), "17:naga-29.0.3-spv-no-coordinate-space-adjustment");
    }

    #[test]
    fn identity_is_an_integer_then_a_colon_then_text_and_never_mentions_spirv() {
        let id = compiler_identity();
        let (revision, options) = id.split_once(':').expect("<revision>:<options>");
        assert!(revision.parse::<u32>().is_ok(), "{id}");
        assert!(!options.is_empty());
        assert!(!id.to_lowercase().contains("spir") && !id.to_lowercase().contains("spv"), "{id}");
    }

    #[test]
    fn identity_has_no_per_build_or_per_launch_data() {
        let id = compiler_identity();
        assert!(id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b':'), "{id}");
        assert!(!id.contains('/'), "no path");
    }

    #[test]
    fn identity_is_a_pure_function_of_its_parts_and_each_part_matters() {
        let base = build_identity(1, "29.0.3", "2.0", "untransformed");
        assert_eq!(base, build_identity(1, "29.0.3", "2.0", "untransformed"));
        assert_ne!(base, build_identity(2, "29.0.3", "2.0", "untransformed"), "revision");
        assert_ne!(base, build_identity(1, "29.0.4", "2.0", "untransformed"), "compiler dependency");
        assert_ne!(base, build_identity(1, "29.0.3", "2.1", "untransformed"), "language version");
        assert_ne!(base, build_identity(1, "29.0.3", "2.0", "flip-y"), "options");
        assert_eq!(compiler_identity(), build_identity(PIPELINE_REVISION, NAGA_VERSION, MSL_LANGUAGE_VERSION, COMPILE_OPTIONS));
    }

    #[test]
    fn the_recorded_compiler_version_matches_the_vendored_manifest() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ThirdParty/naga/Cargo.toml");
        let text = std::fs::read_to_string(&manifest).expect("the vendored naga manifest is in the checkout");
        let version = text
            .lines()
            .skip_while(|l| l.trim() != "[package]")
            .find_map(|l| l.strip_prefix("version = "))
            .map(|v| v.trim().trim_matches('"').to_string())
            .expect("the manifest has a package version");
        assert_eq!(version, NAGA_VERSION, "update NAGA_VERSION and bump PIPELINE_REVISION together");
    }
}
