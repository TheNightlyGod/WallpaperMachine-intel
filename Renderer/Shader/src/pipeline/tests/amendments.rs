// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Amendments 1, D2: the member-access suffix on a declared name (c1 R107, b R81); each test is the
//! black-box check of its amendment.

use super::support::*;
use crate::error::{ErrorCategory, ShaderError};
use crate::pipeline::CompiledProgram;
use crate::request::StageKind;

/// Everything a caller reads of a program, minus the stage text a test compares on its own.
fn observable(p: &CompiledProgram) -> (Vec<String>, Vec<String>, String, String) {
    // The cache key is left out on purpose: it covers the raw source text, which differs.
    (
        p.stages.iter().map(|s| s.glsl.clone()).collect(),
        p.stages.iter().map(|s| s.payload.msl_source.clone()).collect(),
        p.reflection.to_json(),
        format!("{:?}", p.metadata),
    )
}

// ---- D2: c1 R107, b R81 ----

fn haze_vertex() -> String {
    vertex_with("varying vec4 v_Haze;", "  v_Haze = vec4(a_Coord, 0.5, 1.0);")
}

fn haze_fragment(declaration: &str) -> String {
    fragment_with(declaration, "  c = vec4(v_Haze.xy, 0.0, 1.0);")
}

#[test]
fn a_suffixed_varying_compiles_to_the_program_of_the_plain_declaration() {
    let plain = ok(&haze_vertex(), &haze_fragment("varying vec4 v_Haze;"));
    for declaration in [
        "varying vec4 v_Haze.xy;",
        "varying vec4 v_Haze . xyz ;",
        "varying vec4 v_Haze /* between name and dot */ .xy;",
        "varying vec4 v_Haze . /* between dot and letters */ rg ;",
        "varying vec4 v_Haze.xyzw;",
    ] {
        let suffixed = ok(&haze_vertex(), &haze_fragment(declaration));
        assert_eq!(observable(&suffixed), observable(&plain), "{declaration}");
    }
}

#[test]
fn the_suffix_is_not_counted_as_a_use_when_the_widths_are_reconciled() {
    // The vertex stage writes a vec2; the fragment declares vec4 with a suffix and reads only `.xy`.
    let vertex = vertex_with("varying vec2 v_Haze;", "  v_Haze = a_Coord;");
    let plain = ok(&vertex, &haze_fragment("varying vec4 v_Haze;"));
    let suffixed = ok(&vertex, &haze_fragment("varying vec4 v_Haze.xyzw;"));
    assert_eq!(declared_type(&glsl_of(&suffixed, StageKind::Fragment), "v_Haze").as_deref(), Some("vec2"));
    assert_eq!(declared_type(&glsl_of(&suffixed, StageKind::Vertex), "v_Haze").as_deref(), Some("vec2"));
    assert_eq!(observable(&suffixed), observable(&plain));
    // And a suffix that names more components than the variable is read with does not widen it back.
    let narrow = ok(&vertex, &fragment_with("varying vec4 v_Haze.xyz;", "  c = vec4(v_Haze.x, v_Haze.y, 0.0, 1.0);"));
    assert_eq!(declared_type(&glsl_of(&narrow, StageKind::Fragment), "v_Haze").as_deref(), Some("vec2"));
}

#[test]
fn the_other_interface_qualifiers_tolerate_the_suffix_too() {
    let plain = ok(
        "attribute vec3 a_Position;\nuniform float g_Gain;\nvoid main() { gl_Position = vec4(a_Position * g_Gain, 1.0); }",
        "void main() { gl_FragColor = CAST4(1.0); }",
    );
    let suffixed = ok(
        "attribute vec3 a_Position.xyz;\nuniform float g_Gain.x;\nvoid main() { gl_Position = vec4(a_Position * g_Gain, 1.0); }",
        "void main() { gl_FragColor = CAST4(1.0); }",
    );
    assert_eq!(observable(&suffixed), observable(&plain));
}

#[test]
fn a_malformed_suffix_fails_with_a_diagnostic_on_that_declaration() {
    for declaration in ["varying vec4 v_Haze.;", "varying vec4 v_Haze.xy = 1.0;", "varying vec4 v_Haze.foo;"] {
        let fragment = format!("uniform float g_Before;\n{declaration}\nvarying float v_After;\nvoid main() {{ gl_FragColor = CAST4(0.0); }}\n");
        let e = err(&haze_vertex(), &fragment);
        assert_eq!(e.category(), ErrorCategory::Legalization, "{declaration}: {e}");
        let ShaderError::Source { failures, .. } = &e else { panic!("{e}") };
        let d = &failures[0].diagnostic;
        assert_eq!(d.stage, Some(StageKind::Fragment), "{e}");
        let span = d.span.expect("a span");
        let at = fragment.find(declaration).unwrap();
        assert_eq!((span.start(), span.end()), (at, at + declaration.len()), "{declaration}: {e}");
    }
}
