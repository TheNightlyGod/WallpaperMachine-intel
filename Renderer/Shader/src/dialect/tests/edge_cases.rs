// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 5 of the spec: edge cases and error handling (E1 to E20) not covered elsewhere.

use super::support::*;
use crate::dialect::convert_stage;
use crate::preprocess::{Mode, preprocess_stage};
use crate::request::StageKind;
use crate::source::NoIncludes;

#[test]
fn comments_between_the_tokens_of_a_construct_do_not_stop_it() {
    let t = frag("/*x*/ uniform float /*y*/ g_Soft;\nvec2 /* b */ warp(vec2 q) { return q * g_Soft; }\nvoid main() { highp /*q*/ vec2 a = warp(CAST2(1.0)); gl_FragColor = vec4(a, 0.0, 1.0); }");
    assert!(t.contains("uniform float g_Soft;") && t.contains("vec2 warp(vec2 q)") && t.contains("highp vec2 a = warp(vec2(1.0));"), "{t}");
}

#[test]
fn a_declaration_after_an_annotation_or_define_line_is_still_a_declaration() {
    let src = "uniform float g_A; // {\"material\":\"a\"}\n// [COMBO] {\"combo\":\"X\",\"material\":\"x\"}\n#define K 2.0\nuniform float g_B;\nvoid main() {\n// {\"x\":1}\n#define L 3.0\nfloat v = K + L + g_A + g_B;\ngl_FragColor = CAST4(v);\n}";
    let t = frag(src);
    assert!(t.contains("float v = 2.0 + 3.0 + g_A + g_B;"), "{t}");
}

#[test]
fn crlf_line_endings_a_missing_final_newline_and_continuations_work() {
    let src = "#define M(a) \\\r\n  saturate(a)\r\nvarying float v;\r\nvoid main() { gl_FragColor = CAST4(M(v)); }";
    let t = frag(src);
    assert!(t.contains("clamp(v, 0.0, 1.0)"), "{t}");
    assert!(!t.contains('\r'), "output uses LF");
    let t = frag("void main() { gl_FragColor = CAST4(1.0); }");
    assert!(t.ends_with('\n'));
}

#[test]
fn a_stage_converts_completely_or_not_at_all() {
    // one unsupported construct fails the stage; nothing partial is returned (E17)
    let src = "uniform sampler2D g_T; varying vec2 v;\nvoid main() { vec4 a = texSample2D(g_T, v); vec4 b = textureCompare(g_T, v); gl_FragColor = a + b; }";
    assert!(convert_stage(StageKind::Fragment, src).is_err());
}

#[test]
fn an_unsupported_name_in_an_inactive_branch_does_not_matter() {
    let src = "#if SHADOWS\nfloat s = texSample2DCompare(g_T, v, 0.5);\n#endif\nuniform sampler2D g_T; varying vec2 v;\nvoid main() { gl_FragColor = texSample2D(g_T, v); }";
    let pre = preprocess_stage(StageKind::Fragment, src, &[], &NoIncludes, Mode::Evaluated).unwrap();
    legacy_frag(&pre.text);
}

#[test]
fn words_inside_other_identifiers_and_non_calls_are_not_rewritten() {
    let t = frag("void main() { float fracture = 2.0; float halfWidth = fracture * 2.0; float lerpFactor = halfWidth; gl_FragColor = CAST4(lerpFactor); }");
    assert!(t.contains("float fracture = 2.0;") && t.contains("float halfWidth = fracture * 2.0;") && t.contains("float lerpFactor = halfWidth;"), "{t}");
}

#[test]
fn a_parameter_named_like_a_dialect_function_does_not_switch_it_off() {
    let t = text("float f(float saturate) { return saturate * 2.0; }", "float a = saturate(uf); float b = f(uf); o = CAST4(a + b);");
    assert!(t.contains("clamp(uf, 0.0, 1.0)") && t.contains("return saturate * 2.0;"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn adjacent_tokens_lex_as_expected() {
    let t = text("", "int k = ui; int m = 3; vec2 a[2] = vec2[2](CAST2(1.0), CAST2(2.0)); int i = 0; float r = a[i].x * 2.0;\nint q = k%-m; ++i; o = CAST4(r + float(q) + float(i));");
    assert!(t.contains("k % -m") && t.contains("++i;") && t.contains("a[i].x"), "{t}");
    // (the elements are vectors: `.x` of a scalar element is a splat and is written without the swizzle)
    let t = text("", "int k = ui; int m = 3; int q = k%-m; int i = 0; ++i; vec2 v = i2; float r = v.xy.x; o = CAST4(float(q + i) + r);");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_stray_backslash_and_unknown_punctuation_are_carried_through() {
    let t = frag("void main() { float a = 1.0; \\ float b = 2.0; gl_FragColor = vec4(a + b); }");
    assert!(t.contains('\\'), "{t}");
}

#[test]
fn a_scalar_call_into_a_compound_assignment_or_a_vector_shape_broadcasts() {
    let c = ok("", "vec2 v = u2; v += pow(dot(u3, i3), v); v *= pow(uf, u2); vec3 w = u3; w -= min(uf, 0.5); o = vec4(v, w.x, 1.0);");
    assert_eq!(c.local_type("v"), "vec2<f32>");
}

#[test]
fn an_integer_comparison_chain_with_macros_keeps_integers() {
    let t = text("#define COUNT 4\n#define STEP 2u\n", "int n = 0; for (int i = 0; i < COUNT; i++) { n += i; } uint u = uu % STEP; o = CAST4(float(n) + float(u));");
    assert!(t.contains("i < 4") && t.contains("uu % 2u"), "{t}");
}
