// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The MSL text (spec D test 37, R52, R43): a complete translation unit with one entry
//! function, no NUL byte, identical for identical input, and none of the options R43 forbids.

use super::support::*;
use crate::pipeline::tests::support::{PASS_FRAGMENT, PASS_VERTEX, ok};
use crate::request::StageKind;

const VERTEX: &str = "#version 450
layout(location = 0) in vec3 a_Position;
void main() { gl_Position = vec4(a_Position, 1.0); }
";

/// Entry functions are the ones that start with a stage keyword.
fn entry_functions(msl: &str) -> usize {
    msl.lines().filter(|l| l.starts_with("vertex ") || l.starts_with("fragment ") || l.starts_with("kernel ")).count()
}

#[test]
fn the_text_includes_the_standard_library_and_defines_one_entry_function() {
    for (c, keyword) in [(vertex(VERTEX), "vertex"), (fragment("#version 450\nlayout(location = 0) out vec4 c;\nvoid main() { c = vec4(1.0); }\n"), "fragment")] {
        let m = msl(&c);
        assert!(m.contains("#include <metal_stdlib>"), "{m}");
        assert!(m.contains("#include <simd/simd.h>"), "{m}");
        assert_eq!(entry_functions(m), 1, "{m}");
        assert!(m.lines().any(|l| l.starts_with(&format!("{keyword} "))), "{m}");
        // The include need not be the first line: a language-version comment comes first.
        assert!(m.lines().next().unwrap().starts_with("//"), "{m}");
    }
}

#[test]
fn the_text_has_no_nul_and_is_identical_for_identical_input() {
    let a = ok(PASS_VERTEX, PASS_FRAGMENT);
    let b = ok(PASS_VERTEX, PASS_FRAGMENT);
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        let (x, y) = (&a.stage(kind).unwrap().payload.msl_source, &b.stage(kind).unwrap().payload.msl_source);
        assert!(!x.contains('\0'));
        assert_eq!(x, y);
    }
}

#[test]
fn none_of_the_forbidden_options_shows_in_the_text() {
    let p = ok(PASS_VERTEX, "uniform sampler2D g_Texture0; varying vec2 v_TexCoord;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }");
    for s in &p.stages {
        let m = &s.payload.msl_source;
        assert!(!m.contains("constexpr sampler"), "no inline samplers: {m}");
        assert!(!m.contains("spvArrayCopy") && !m.contains("spirv"), "no compatibility helpers: {m}");
        assert!(!m.contains("[[buffer(30)]]") && !m.contains("_vertex_buffer"), "no vertex pulling: {m}");
        assert!(!m.contains("[[point_size]]"), "no forced point size: {m}");
    }
    assert!(p.stages[0].payload.msl_source.contains("[[attribute("), "stage-in attributes");
}

#[test]
fn the_language_comment_names_version_two() {
    let c = vertex(VERTEX);
    assert!(msl(&c).starts_with("// language: metal2.0\n"), "{}", msl(&c));
    assert_eq!(c.payload.language_version, "2.0");
}
