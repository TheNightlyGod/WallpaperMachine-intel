// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Matrix inverse (spec D test 22, R44): no builtin `inverse(` reaches the MSL, and a stage
//! that declares its own `inverse` keeps calling it. These go through the whole pipeline
//! because the helper is the legalizer's.

use crate::pipeline::tests::support::{PASS_VERTEX, ok};
use crate::request::StageKind;

/// True when `text` calls a function spelled exactly `inverse` (not `_wm_inverse` or
/// `metal::inverse`'s look-alikes with another prefix character).
fn calls_bare_inverse(text: &str) -> bool {
    text.match_indices("inverse(").any(|(at, _)| {
        let before = text[..at].chars().next_back();
        !before.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

fn msl_and_glsl(fragment: &str) -> (String, String) {
    let p = ok(PASS_VERTEX, fragment);
    let s = p.stage(StageKind::Fragment).unwrap();
    (s.payload.msl_source.clone(), s.glsl.clone())
}

#[test]
fn the_inverse_of_mat2_mat3_and_mat4_translates_without_the_builtin() {
    let f = "uniform vec4 g_A; uniform mat3 g_M3; uniform mat4 g_M4;
void main() {
  mat2 m2 = mat2(g_A.x, g_A.y, g_A.z, g_A.w);
  mat2 i2 = inverse(m2);
  mat3 i3 = inverse(g_M3);
  mat4 i4 = inverse(g_M4);
  gl_FragColor = vec4(i2[0].x + i3[1].y + i4[2].z);
}";
    let (msl, glsl) = msl_and_glsl(f);
    assert!(!calls_bare_inverse(&msl), "{msl}");
    assert!(!calls_bare_inverse(&glsl), "the legalized text calls the helper, not the builtin: {glsl}");
    assert!(msl.contains("_wm_inverse"), "{msl}");
}

#[test]
fn each_size_alone_translates() {
    for (ty, source) in [
        ("mat2", "mat2 m = mat2(g_A.x, g_A.y, g_A.z, g_A.w);"),
        ("mat3", "mat3 m = mat3(g_A.xyz, g_A.yzw, g_A.zwx);"),
        ("mat4", "mat4 m = mat4(g_A, g_A.yzwx, g_A.zwxy, g_A.wxyz);"),
    ] {
        let f = format!("uniform vec4 g_A;\nvoid main() {{ {source} gl_FragColor = inverse(m)[0].xxxx; }}");
        let (msl, _) = msl_and_glsl(&f);
        assert!(!calls_bare_inverse(&msl), "{ty}: {msl}");
    }
}

#[test]
fn an_author_declared_inverse_is_kept_and_gets_no_helper() {
    // Wallpaper Engine's perspective include declares its own `inverse` for Direct3D.
    let f = "uniform mat3 g_M3;
mat3 inverse(mat3 m) { return m * 2.0; }
void main() { mat3 i3 = inverse(g_M3); gl_FragColor = vec4(i3[1].y); }";
    let (msl, glsl) = msl_and_glsl(f);
    assert!(glsl.contains("mat3 inverse(mat3 m)") && glsl.contains("= inverse(g_M3)"), "{glsl}");
    assert!(!glsl.contains("_wm_inverse"), "no generated helper: {glsl}");
    assert!(!msl.contains("_wm_inverse"), "{msl}");
    assert!(msl.contains("inverse("), "the author's function is still called: {msl}");
}

#[test]
fn only_the_sizes_a_stage_uses_get_a_helper() {
    let f = "uniform mat3 g_M3;\nvoid main() { gl_FragColor = vec4(inverse(g_M3)[0].x); }";
    let (_, glsl) = msl_and_glsl(f);
    assert!(glsl.contains("mat3 _wm_inverse(mat3 m)"), "{glsl}");
    assert!(!glsl.contains("mat4 _wm_inverse") && !glsl.contains("mat2 _wm_inverse"), "{glsl}");
}
