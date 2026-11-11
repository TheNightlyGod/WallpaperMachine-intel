// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Matrix inverse: GLSL's built-in `inverse` is refused as Wallpaper Engine refuses it (probe
//! T13), and a stage that declares its own `inverse` (Wallpaper Engine's perspective include
//! does) keeps calling it, through the whole pipeline to Metal.

use crate::pipeline::tests::support::{PASS_VERTEX, ok};
use crate::request::StageKind;

fn msl_and_glsl(fragment: &str) -> (String, String) {
    let p = ok(PASS_VERTEX, fragment);
    let s = p.stage(StageKind::Fragment).unwrap();
    (s.payload.msl_source.clone(), s.glsl.clone())
}

#[test]
fn an_author_declared_inverse_is_kept_and_gets_no_helper() {
    // Wallpaper Engine's perspective include declares its own `inverse` for Direct3D.
    let f = "uniform mat3 g_M3;
mat3 inverse(mat3 m) { return m * 2.0; }
void main() { mat3 i3 = inverse(g_M3); gl_FragColor = CAST4(i3[1].y); }";
    let (msl, glsl) = msl_and_glsl(f);
    assert!(glsl.contains("mat3 inverse(mat3 m)") && glsl.contains("= inverse(g_M3)"), "{glsl}");
    assert!(!glsl.contains("_wm_inverse"), "no generated helper: {glsl}");
    assert!(!msl.contains("_wm_inverse"), "{msl}");
    assert!(msl.contains("inverse("), "the author's function is still called: {msl}");
}
