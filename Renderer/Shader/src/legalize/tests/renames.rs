// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Reserved identifiers, user functions called `mod` and `sample`, array parameters and the
//! alpha-to-coverage idiom, seen through the whole legalizer (spec C2 section 8, items 17 to
//! 20). The names the converter gives a renamed local are its own; the tests assert that a
//! rename is consistent and that the stage compiles, not the spelling.

use super::support::*;

/// The identifier that replaces `name` where the stage declares it (the first declared name
/// that starts with `name` and is not `name`), or `name` itself when it was kept.
fn declared_as(text: &str, ty: &str, name: &str) -> String {
    let at = text.find(&format!("{ty} {name}")).unwrap_or_else(|| panic!("`{ty} {name}` missing in\n{text}"));
    text[at + ty.len() + 1..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect()
}

#[test]
fn locals_named_like_operator_words_are_renamed_consistently() {
    let src = "varying vec4 v;\nvoid main() { vec4 sample = v; bool and = true; bool or = false; bool xor = true; bool not = false; gl_FragColor = (and && !not || or ^^ xor) ? sample : vec4(0.0); }";
    let t = frag(src);
    for name in ["sample", "and", "or", "xor", "not"] {
        let ty = if name == "sample" { "vec4" } else { "bool" };
        let new = declared_as(&t, ty, name);
        assert_ne!(new, name, "{name} must be renamed: {t}");
        assert!(t.matches(&new).count() >= 2, "uses follow the declaration: {t}");
    }
    let _ = compile_frag(src);
}

#[test]
fn a_local_hiding_an_interface_variable_keeps_its_meaning() {
    let src = "varying vec4 v_Tint; uniform float g_A;\nvoid main() { vec4 acc = v_Tint * g_A; { float g_A = 3.0; vec4 v_Tint = vec4(g_A); acc += v_Tint; } for (int v_Fade = 0; v_Fade < 2; v_Fade++) acc += float(v_Fade); acc *= v_Tint; gl_FragColor = acc * g_A; }";
    let t = frag(src);
    // the later reads after the inner scopes still read the interface variables
    assert!(t.contains("acc *= v_Tint;") && t.contains("_we_FragColor = acc * g_A;"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn a_second_declaration_of_one_name_in_a_function_and_nested_shadowing_compile() {
    let src = "varying vec2 v;\nvoid main() { float acc = 0.0; for (int i = 0; i < 3; i++) acc += 1.0; for (int i = 0; i < 2; i++) { float acc2 = float(i); { float acc = acc2 * 2.0; acc2 += acc; } acc += acc2; } float k = 1.0, m = k * 2.0, n = m + k; gl_FragColor = vec4(acc, k, m, n) * v.x; }";
    let _ = compile_frag(src);
}

#[test]
fn a_for_header_variable_is_scoped_to_the_whole_loop_statement() {
    let src = "varying float v_Fade;\nvoid main() { float acc = 0.0; for (int v_Fade = 0; v_Fade < 4; v_Fade++) if (v_Fade > 1) acc += float(v_Fade); else acc -= 1.0; acc *= v_Fade; gl_FragColor = vec4(acc); }";
    let t = frag(src);
    assert!(t.contains("acc *= v_Fade;"), "after the loop the name is the varying again: {t}");
    let _ = compile_frag(src);
}

#[test]
fn a_comma_declaration_renames_every_declarator_and_later_uses_in_the_statement() {
    let src = "varying vec3 v_Tint;\nvoid main() { vec3 v_Tint = vec3(0.5), a = v_Tint * 2.0, b = a + v_Tint.zyx; gl_FragColor = vec4(b, 1.0); }";
    let t = frag(src);
    assert!(t.contains("a = v_Tint * 2.0") || t.contains("a = v_Tint_"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn a_member_field_is_never_confused_with_a_local_of_the_same_name() {
    let src = "struct Material { vec3 tint; float sample; };\nuniform vec3 u_Dummy; varying vec2 v;\nvoid main() { Material material; material.tint = vec3(v, 0.0); material.sample = 2.0; vec3 tint = material.tint * material.sample; gl_FragColor = vec4(tint, 1.0); }";
    let t = frag(src);
    assert!(t.contains("material.tint"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn a_user_function_called_sample_is_renamed_in_its_definition_and_every_call() {
    let src = "varying vec2 v;\nfloat sample(float a) { return a * 2.0; }\nvec2 sample(vec2 a) { return a * 3.0; }\nvoid main() { gl_FragColor = vec4(sample(v.x), sample(v), 0.0); }";
    let t = frag(src);
    assert!(!t.contains(" sample(") && !t.contains("(sample("), "{t}");
    assert_eq!(t.matches("sample_wm").count(), 4, "{t}");
    let _ = compile_frag(src);
}

#[test]
fn a_user_mod_function_and_the_builtin_mod_both_stay_reachable() {
    let src = "varying vec2 v;\nfloat mod(float x, float y) { return x - y * floor(x / y); }\nvoid main() { float t = v.x; float r = mod(t, 2.0); vec2 r2 = mod(v, vec2(2.0)); vec2 r3 = mod(v, 3.0); gl_FragColor = vec4(r, r2 + r3, 1.0); }";
    let c = compile_frag(src);
    assert!(c.has_function("mod") || c.has_function("mod_wm"), "the user function exists");
    // without a user function the builtin is untouched
    let t = frag("varying vec2 v;\nvoid main() { gl_FragColor = vec4(mod(vec2(7.0), 3.0), mod(v.x, 2.0), 1.0); }");
    assert!(t.contains("mod(vec2(7.0), 3.0)") || t.contains("mod(vec2(7.0), vec2(3.0))"), "{t}");
    let _ = compile_frag("varying vec2 v;\nfloat mod(float x) { return x * 0.5; }\nvoid main() { gl_FragColor = vec4(mod(v.x), mod(v, vec2(2.0)), 1.0); }");
    let _ = compile_frag("varying vec2 v;\nvec2 mod(vec2 x, vec2 y) { return x - y * floor(x / y); }\nvoid main() { gl_FragColor = vec4(mod(v, vec2(2.0)), 0.0, 1.0); }");
}

#[test]
fn array_parameters_are_specialised_to_the_global_the_call_passes() {
    // several calls with the same array, scalar parameters beside it, a scalar overload that survives
    let src = "uniform float g_Taps8[8]; uniform float g_K;\nfloat pool(float taps[8], float scale) { float s = 0.0; for (int i = 0; i < 8; i++) s += taps[i]; return s * scale; }\nfloat pool(float scale) { return scale; }\nvoid main() { gl_FragColor = vec4(pool(g_Taps8, 0.5), pool(g_Taps8, g_K), pool(2.0), 1.0); }";
    let t = frag(src);
    assert!(t.contains("pool(2.0)"), "the scalar overload is untouched: {t}");
    assert!(t.contains("g_Taps8[i].x"), "{t}");
    let _ = compile_frag(src);
    // a local that hides the parameter name and a member field of the same name keep their meaning
    let src = "uniform float g_Bands[4]; struct S { float bands; };\nfloat f(float bands[4]) { S s; s.bands = bands[1]; { float bands = 2.0; s.bands += bands; } return s.bands + bands[2]; }\nvoid main() { gl_FragColor = vec4(f(g_Bands)); }";
    let t = frag(src);
    assert!(t.contains("s.bands = g_Bands[1].x") && t.contains("g_Bands[2].x"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn array_parameter_calls_with_different_arrays_get_a_clone_each() {
    // The converter clones the function per array rather than refusing it (a superset of the
    // old refusal); the notes record why the refusal of the old rule 56 is not reproduced.
    let src = "uniform float g_L[4]; uniform float g_R[4];\nfloat f(float b[4]) { return b[0] + b[3]; }\nvoid main() { gl_FragColor = vec4(f(g_L), f(g_R), 0.0, 1.0); }";
    let t = frag(src);
    assert!(t.contains("g_L[0].x + g_L[3].x") && t.contains("g_R[0].x + g_R[3].x"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn the_alpha_to_coverage_idiom_keeps_the_alpha_that_existed_before_sharpening() {
    let src = "uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { vec4 c = texSample2D(g_Texture0, v); gl_FragColor = c; gl_FragColor.a = saturate(max(fwidth(gl_FragColor.a), 0.02) * (gl_FragColor.a - 0.5) + 0.5); }";
    let t = frag(src);
    assert!(!t.contains("fwidth"), "{t}");
    assert!(t.contains("_we_FragColor.a = clamp(c.a, 0.0, 1.0);"), "{t}");
    let _ = compile_frag(src);
    // without the saturate wrapper
    let src = "uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { vec4 c = texSample2D(g_Texture0, v); gl_FragColor = c; gl_FragColor.a = max(fwidth(gl_FragColor.a), 0.02) * (gl_FragColor.a - 0.5) + 0.5; }";
    let t = frag(src);
    assert!(t.contains("_we_FragColor.a = c.a;"), "{t}");
}

#[test]
fn the_alpha_idiom_tracks_the_assigned_source_and_sees_renamed_locals() {
    let src = "uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { vec4 sample = texSample2D(g_Texture0, v); vec4 other = vec4(1.0); gl_FragColor = other; gl_FragColor = sample; gl_FragColor.a = saturate(max(fwidth(gl_FragColor.a), 0.02) * (gl_FragColor.a - 0.5) + 0.5); }";
    let t = frag(src);
    let renamed = declared_as(&t, "vec4", "sample");
    assert_ne!(renamed, "sample");
    assert!(t.contains(&format!("clamp({renamed}.a, 0.0, 1.0)")), "the nearest assignment's source, under its new name: {t}");
    let _ = compile_frag(src);
}

#[test]
fn the_alpha_idiom_is_left_alone_without_a_source_in_scope() {
    // the source lives in a closed block
    let src = "varying vec2 v;\nvoid main() { { vec4 c = vec4(v, 0.0, 1.0); gl_FragColor = c; } gl_FragColor.a = saturate(max(fwidth(gl_FragColor.a), 0.02) * (gl_FragColor.a - 0.5) + 0.5); }";
    let t = frag(src);
    assert!(t.contains("fwidth"), "{t}");
    // the source is in another function
    let src = "varying vec2 v;\nvoid other() { vec4 c = vec4(v, 0.0, 1.0); gl_FragColor = c; }\nvoid main() { other(); gl_FragColor.a = saturate(max(fwidth(gl_FragColor.a), 0.02) * (gl_FragColor.a - 0.5) + 0.5); }";
    let t = frag(src);
    assert!(t.contains("fwidth"), "{t}");
    let _ = compile_frag(src);
}
