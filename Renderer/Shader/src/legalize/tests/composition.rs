// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Composition of the rewrites, rule order, robustness and determinism (spec C2 section 8,
//! items 1 to 4, 27, 28, 32 and 33).

use super::support::*;
use crate::legalize::{ProgramInput, legalize};
use crate::request::StageKind;

#[test]
fn rewrites_compose_in_one_expression_whatever_the_nesting() {
    // texture sampling inside mul inside fmod inside a bool-to-float conversion inside a renamed local
    let src = "uniform sampler2D g_Texture0; uniform mat4 g_M; varying vec2 v;\nvoid main() { float sample = fmod(mul(g_M, texSample2D(g_Texture0, v)).y * 3.0, 2.0) > 0.5; gl_FragColor = CAST4(sample); }";
    let t = frag(src);
    assert_eq!(count(&t, "sampler2D(g_Texture0, _we_Sampler_g_Texture0)"), 1, "{t}");
    assert_eq!(count(&t, "g_M"), 2, "declared once, used once: {t}");
    assert!(t.contains("sample_wm") && !has_word(&t, "sample"), "{t}");
    assert!(t.contains('%') || t.contains("fmod"), "the remainder is there once: {t}");
    assert_eq!(count(&t, "_we_FragColor"), 2, "the output declaration and its one use: {t}");
    let _ = compile_frag(src);
}

#[test]
fn the_order_of_the_rules_shows_in_their_effects() {
    // a sampling call is paired with its sampler although the dialect spelling is renamed afterwards
    let t = frag("uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v); }");
    assert!(t.contains("texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v)") && !t.contains("tex2D"), "{t}");
    // a local renamed for a reserved word is seen by the coercions after it
    let t = frag("varying vec2 v;\nvoid main() { float sample = v.x; bool or = sample; if (sample) { gl_FragColor = CAST4(float(or)); } }");
    assert!(t.contains("sample_wm != 0.0"), "{t}");
    // The colour output rename reaches every read in the authored alpha expression.
    let t = frag("varying vec4 v;\nvoid main() { vec4 c = v; gl_FragColor = c; gl_FragColor.a = saturate((gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5); }");
    assert!(t.contains("fwidth(_we_FragColor.a)") && t.contains("clamp("), "{t}");
}

#[test]
fn a_comment_or_string_or_annotation_never_changes_the_stage() {
    let src = "// uniform float g_Hidden; gl_FragColor = texSample2D(g_Texture0, v);\nuniform float g_Real; // {\"material\":\"real\"}\n/* uniform sampler2D g_Texture9; */\nvarying vec2 v;\nvoid main() { /* gl_FragColor = vec4(1.0); */ float x = g_Real; discard; }";
    let t = frag(src);
    assert!(!t.contains("g_Hidden") && !t.contains("g_Texture9"), "{t}");
    assert!(!t.contains("_we_FragColor"), "a comment does not make the stage write the colour: {t}");
    let _ = compile_frag(src);
}

#[test]
fn a_function_like_macro_that_reads_a_widened_array_selects_its_component() {
    let src = "uniform float g_Bands[8];\n#define BAND(i) g_Bands[i]\nvoid main() { gl_Position = CAST4(BAND(2) + BAND(3)); }";
    let t = vert(src);
    assert!(t.contains("g_Bands[2].x + g_Bands[3].x"), "{t}");
    let _ = compile_vert(src);
    // an alias directive with a trailing comment is still an alias
    let t = vert("uniform float g_Bands[8];\n#define U_BANDS g_Bands // alias\nvoid main() { gl_Position = CAST4(U_BANDS[1]); }");
    assert!(t.contains("g_Bands[1].x"), "{t}");
}

#[test]
fn sampling_inside_alpha_sharpening_survives_legalisation() {
    // Both the derivative and the sampling call are observable parts of the expression.
    let src = "uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { vec4 c = CAST4(1.0); gl_FragColor = c; gl_FragColor.a = saturate(max(fwidth(gl_FragColor.a), texSample2D(g_Texture0, v).a) * (gl_FragColor.a - 0.5) + 0.5); }";
    let t = frag(src);
    assert!(t.contains("fwidth(_we_FragColor.a)"), "{t}");
    assert_eq!(count(&t, "sampler2D(g_Texture0"), 1, "the sampling call survives: {t}");
    let _ = compile_frag(src);
}

#[test]
fn malformed_text_never_panics() {
    let base = "uniform sampler2D g_Texture0; uniform float g_A[4]; uniform vec2 u_B; attribute vec3 a_P; varying vec4 v_T[2]; varying vec2 v_U;\nvoid main() { vec4 c = texSample2D(g_Texture0, v_U) * g_A[1]; v_T[0] = c; float x = c.x % 2.0; for (int i = 0; i < 3; i++) { x += float(i); } if (x) { v_U *= 2.0; } gl_Position = vec4(a_P, x); gl_FragColor = c; }\n";
    let mut count = 0;
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        for end in (0..base.len()).filter(|i| base.is_char_boundary(*i)) {
            let _ = crate::legalize::legalize_stage(kind, &base[..end]);
            count += 1;
        }
        for start in (0..base.len()).step_by(7).filter(|i| base.is_char_boundary(*i)) {
            let _ = crate::legalize::legalize_stage(kind, &base[start..]);
        }
    }
    assert!(count > 500);
    for hostile in [
        "uniform vec4 a[;", "uniform float a[", "varying vec4 v[", "uniform sampler2D;", "uniform;", "varying;", "attribute", "layout(binding = ) uniform float a;",
        "for (", "void main( {", "void main() { for (int i = 0; i < ; i++) }", "uniform float a[3] = {1.0, 2.0};", "uniform float a, ;", "in in in;",
        "#define X(\nvoid main() { }", "varying float v[4000000000]; void main() { v[0] = 1.0; }", "uniform float g[4000000000]; void main() { float a[2] = g; }", "uniform float g[3000000]; void main() { float a = g[1] + g[2]; }", "void main() { texSample2D(); texSample2D(g_Texture0); }", "uniform sampler2D g_Texture0; void main() { gl_FragColor = texSample2D(g_Texture0",
    ] {
        for kind in [StageKind::Vertex, StageKind::Fragment] {
            let _ = crate::legalize::legalize_stage(kind, hostile);
        }
        let _ = legalize(&ProgramInput::program(hostile, hostile));
    }
}

#[test]
fn legalizing_the_same_input_again_gives_the_same_bytes() {
    let v = "uniform mat4 g_Mvp; uniform vec2 g_S[3]; attribute vec3 a_P; attribute vec2 a_T; varying vec2 v_T; varying vec4 v_C;\nvoid main() { a_T *= 2.0; gl_Position = mul(vec4(a_P, 1.0), g_Mvp); v_T = a_T + g_S[1]; v_C = CAST4(1.0); }";
    let f = "uniform sampler2D g_Texture0; uniform sampler2D u_Mask; varying vec2 v_T; varying vec4 v_C; varying float v_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T) * v_C * texSample2D(u_Mask, v_T).r + v_X; }";
    let first = legalize(&ProgramInput::program(v, f)).unwrap();
    for _ in 0..3 {
        assert_eq!(legalize(&ProgramInput::program(v, f)).unwrap(), first);
    }
    let alone = crate::legalize::legalize_stage(StageKind::Fragment, f).unwrap().0;
    assert_eq!(alone, crate::legalize::legalize_stage(StageKind::Fragment, f).unwrap().0);
}

#[test]
fn every_stage_reports_one_informational_diagnostic_covering_its_source() {
    let v = "attribute vec3 a_P;\nvoid main() { gl_Position = vec4(a_P, 1.0); }";
    let f = "void main() { gl_FragColor = CAST4(1.0); }";
    let p = program(v, f);
    for (stage, source) in [(p.vertex.as_ref().unwrap(), v), (p.fragment.as_ref().unwrap(), f)] {
        assert_eq!(stage.diagnostics.len(), 1);
        let d = &stage.diagnostics[0];
        assert_eq!(d.stage, Some(stage.kind));
        assert_eq!((d.span.unwrap().start(), d.span.unwrap().end()), (0, source.len()));
    }
}

#[test]
fn failures_carry_their_class_the_stage_and_the_offending_name() {
    let e = program_err("uniform Light u_L; struct Light { float a; };\nvoid main() { gl_Position = CAST4(1.0); }", "void main() { gl_FragColor = CAST4(1.0); }");
    assert!(e.is_invalid_request());
    let shader_error: crate::ShaderError = e.into();
    assert!(shader_error.to_string().contains("unsupported GlobalUniforms member type"), "{shader_error}");
    let e = stage_err(StageKind::Fragment, "uniform sampler2D g_Texture007;\nvoid main() { gl_FragColor = CAST4(1.0); }");
    let shader_error: crate::ShaderError = e.into();
    assert!(shader_error.to_string().contains("g_Texture007") && shader_error.to_string().contains("fragment"), "{shader_error}");
}
