// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Condition, bool and int repair and the remainder, seen through the whole legalizer (spec C2
//! section 8, items 21 to 26, 34 and 35). The converter decides how a repair is spelled; the
//! tests assert that the stage compiles and that the repair has the meaning HLSL gives.

use super::support::*;

const DECLS: &str = "uniform float g_Gain; uniform int g_Count; uniform uint g_Mask; uniform bool g_On; varying vec2 v; varying float v_F;\n";

fn body(text: &str) -> String {
    format!("{DECLS}void main() {{ {text} }}")
}

fn ok(text: &str) -> String {
    let src = body(text);
    let _ = compile_frag(&src);
    frag(&src)
}

#[test]
fn a_number_used_as_a_condition_is_compared_with_the_zero_of_its_type() {
    let t = ok("vec4 c = CAST4(0.0); if (g_Gain) c.x = 1.0; if (g_Count) c.y = 1.0; if (g_Mask) c.z = 1.0; while (v_F) { v_F -= 1.0; } gl_FragColor = c;");
    assert!(t.contains("if (g_Gain != 0.0)") && t.contains("if (g_Count != 0)") && t.contains("if (g_Mask != 0u)"), "{t}");
    assert!(t.contains("while (v_F != 0.0)") || t.contains("while (_we_in_v_F != 0.0)"), "{t}");
}

#[test]
fn literal_and_arithmetic_conditions_use_a_zero_of_the_expression_type() {
    let t = ok("vec4 c = CAST4(0.0); if (6) c.x = 1.0; if (9u) c.y = 1.0; if (2.5) c.z = 1.0; uint w = g_Mask; if (w * 3u + 5u) c.w = 1.0; if (w % 7u) c.x = 2.0; gl_FragColor = c;");
    assert!(t.contains("6 != 0") && t.contains("9u != 0u") && t.contains("2.5 != 0.0"), "{t}");
    assert!(t.contains("!= 0u"), "{t}");
}

#[test]
fn boolean_conditions_are_left_unchanged() {
    let t = ok("vec4 c = CAST4(0.0); bool b = g_On; if (v.x < 0.5) c.x = 1.0; if (b && g_On) c.y = 1.0; if (!b) c.z = 1.0; if (true) c.w = 1.0; if (b) c.x += 1.0; c.y += (v.x >= v.y) ? 1.0 : 0.0; gl_FragColor = c;");
    for kept in ["if (v.x < 0.5)", "if (b && ", "if (!b)", "if (true)", "if (b)"] {
        assert!(t.contains(kept), "{kept}: {t}");
    }
}

#[test]
fn a_ternary_with_a_numeric_condition_and_an_integer_macro_is_repaired() {
    let t = ok("#define MODE 0\n vec4 c = CAST4(g_Gain ? 1.0 : 2.0); c.y = MODE ? 3.0 : 4.0; c.z = v.x ? 1.0 : 0.0; gl_FragColor = c;");
    assert!(t.contains("g_Gain != 0.0 ?") && t.contains("0 != 0 ?") && t.contains("v.x != 0.0 ?"), "{t}");
}

#[test]
fn a_comparison_stored_into_a_float_becomes_a_number() {
    let t = ok("float m = v.x >= 0.3; vec2 q = CAST2(0.0); q.x += v.x < v.y; float acc = 1.0; acc *= g_On; float lo = 0.75, mid = g_On, hi = 2.5; gl_FragColor = vec4(m, q.x, acc, lo + mid + hi);");
    assert!(t.contains("float m = float(v.x >= 0.3);") || t.contains("float m = ((v.x >= 0.3) ? 1.0 : 0.0);"), "{t}");
    assert!(t.contains("lo = 0.75") && t.contains("hi = 2.5"), "the neighbours are not wrapped: {t}");
}

#[test]
fn nothing_is_assumed_boolean_from_a_name_and_a_float_stays_a_float() {
    let t = ok("float glow = 0.5; float acc = 1.0; acc *= glow; float flag = g_Gain; if (flag) acc += 1.0; gl_FragColor = CAST4(acc);");
    assert!(t.contains("acc *= glow;"), "{t}");
}

#[test]
fn a_float_that_shadows_a_bool_is_not_converted() {
    let t = ok("bool armed = true; float acc = 1.0; { float armed = 2.0; acc *= armed; } acc *= armed; gl_FragColor = CAST4(acc);");
    assert!(t.contains("acc *= armed;"), "{t}");
}

#[test]
fn a_chained_assignment_converts_only_the_right_side_that_qualifies() {
    let t = ok("float b = 0.0; float c = 0.0; float a = 0.0; a = b = v.x < v.y; gl_FragColor = vec4(a, b, c, 1.0);");
    assert!(t.contains("b = float(") || t.contains("? 1.0 : 0.0"), "{t}");
}

#[test]
fn an_int_from_step_is_a_float_and_a_plain_int_of_the_same_name_is_not() {
    let t = ok("int q = step(v.x, v.y); float f = 0.0; if (q) f = 1.0; { int q = 3; if (q) f += 1.0; } gl_FragColor = vec4(f, q, 0.0, 1.0);");
    assert!(t.contains("if (q != 0.0)") || t.contains("if (float(q) != 0.0)") || t.contains("q != 0"), "{t}");
    assert!(t.contains("int q = 3;"), "the other scope keeps its integer: {t}");
    let t = ok("const int lo = 7, hi = step(v.x, v.y), mid = 3; gl_FragColor = vec4(float(lo), float(hi), float(mid), 1.0);");
    assert!(t.contains("lo = 7") && t.contains("mid = 3"), "{t}");
}

#[test]
fn an_int_from_a_float_expression_is_cast_and_an_integer_one_is_not() {
    let t = ok("vec4 tex4 = vec4(v, 0.0, 1.0); int idx = floor(v.x * 8.0); int a = tex4.x; int b = clamp(g_Count, 0, 3); int c = abs(g_Count); int d = min(idx, a) + g_Count; gl_FragColor = CAST4(float(idx + a + b + c + d));");
    assert!(t.contains("int idx = int(floor(v.x * 8.0));") && t.contains("int a = int(tex4.x);"), "{t}");
    assert!(t.contains("int b = clamp(g_Count, 0, 3);") && t.contains("int c = abs(g_Count);"), "{t}");
}

#[test]
fn a_float_array_index_and_a_float_loop_bound_are_repaired() {
    let t = ok("float arr[4]; float i = v.x; arr[i] = 1.0; float s = 0.0; for (int k = 0; k < v_F; k++) s += arr[k]; for (int k = 1.0; k <= g_Count; k++) s += 1.0; gl_FragColor = CAST4(s + arr[i]);");
    assert!(t.contains("arr[int(i)]"), "{t}");
    let t = ok("float s = 0.0; for (int k = 0; k < g_Count && g_On; k++) s += 1.0; gl_FragColor = CAST4(s);");
    assert!(t.contains("k < g_Count && ("), "a compound condition is not wrapped as a whole: {t}");
    // a float loop variable is untouched
    let t = ok("float s = 0.0; for (float k = 0.0; k < 3.0; k += 1.0) s += k; gl_FragColor = CAST4(s);");
    assert!(t.contains("float k = 0.0") && t.contains("k < 3.0"), "{t}");
}

#[test]
fn a_number_as_an_operand_of_not_and_or_is_compared_with_zero() {
    let t = ok("bool a = !g_Gain; bool b = g_Gain && g_On; bool c = g_On || g_Count; bool d = !g_Mask; gl_FragColor = vec4(a ? 1.0 : 0.0, b ? 1.0 : 0.0, c ? 1.0 : 0.0, d ? 1.0 : 0.0);");
    assert!(t.contains("(g_Gain == 0.0)") && t.contains("(g_Gain != 0.0) &&") && t.contains("(g_Count != 0)") && t.contains("(g_Mask == 0u)"), "{t}");
}

#[test]
fn a_boolean_stored_into_an_integer_becomes_one_or_zero() {
    let t = ok("int on = g_On; uint bits = g_On; on = g_On; gl_FragColor = vec4(float(on), float(bits), 0.0, 1.0);");
    assert!(t.contains("int on = int(") && t.contains("uint bits = uint("), "{t}");
}

#[test]
fn a_shader_shaped_like_the_clipping_mask_effect_compiles() {
    // a logical not applied to a float uniform
    let src = "uniform float g_Clip; uniform sampler2D g_Texture0; varying vec2 v;\nvoid main() { vec4 c = texSample2D(g_Texture0, v); if (!g_Clip) { c.a = 0.0; } gl_FragColor = c; }";
    let _ = compile_frag(src);
}

#[test]
fn a_float_remainder_has_the_sign_of_the_dividend() {
    let t = ok("float a = -7.25 % 2.0; float c = v.x % v.y; vec2 d = v % 2.0; vec2 e = 2.0 % v; vec3 f = CAST3(1.0) % vec3(0.5, 2.0, 3.0); gl_FragColor = vec4(a, c + d.x + e.y, f.x, 1.0);");
    assert!(t.contains('%'), "{t}");
    let c = compile_frag(&body("float c = v.x % v.y; gl_FragColor = CAST4(c);"));
    assert!(c.msl.contains("fmod"), "Metal's fmod is the truncated remainder: {}", c.msl);
}

#[test]
fn an_integer_remainder_stays_an_integer_remainder() {
    let t = ok("int tick = g_Count; int cycle = 7; int pos = tick % cycle; float lane = 0.25 * float(tick % cycle); uint n = g_Mask; uint ring = uint(tick % cycle + 3); uint m = n % 8u; gl_FragColor = vec4(float(pos), lane, float(ring), float(m));");
    for kept in ["tick % cycle", "n % 8u"] {
        assert!(t.contains(kept), "{kept}: {t}");
    }
}

#[test]
fn a_remainder_with_an_integer_operand_meets_a_float_in_float() {
    let t = ok("float ang = v.x; #define SPOKES 12\n int ring = ang % SPOKES; float w = float(int(ang % 3.0) + 1); float k = v.y % 2; gl_FragColor = vec4(float(ring), w, k, 1.0);");
    assert!(t.contains("int ring = int(") && t.contains("ang % 12.0"), "{t}");
}

#[test]
fn a_compound_remainder_assignment_and_chains_and_signs_compile() {
    let t = ok("float u = v.x; u %= 2.0; vec2 q = v; q.x %= 0.5; float a = v.x % v.y % 3.0; float b = (v.x % 2.0) % (v.y % 3.0); float d = v.x % -0.75; float s = 2.0 * v.y - v.x % v.y; gl_FragColor = vec4(u + q.x, a, b, d + s);");
    assert!(t.contains("u %= 2.0"), "{t}");
}

#[test]
fn a_remainder_operand_with_a_side_effect_is_evaluated_once() {
    let src = "varying float v_F;\nfloat bump(float x) { return x + 1.0; }\nvoid main() { float r = bump(v_F) % bump(2.0); float u = 5.0; u %= bump(v_F); gl_FragColor = vec4(r, u, 0.0, 1.0); }";
    let t = frag(src);
    assert_eq!(count(&t, "bump(v_F)"), 2, "once in each statement: {t}");
    assert_eq!(count(&t, "bump(2.0)"), 1, "{t}");
    let _ = compile_frag(src);
}

#[test]
fn the_numeric_condition_of_a_do_while_and_a_for_is_repaired_too() {
    let t = ok("float n = 3.0; do { n -= 1.0; } while (n); int k = 2; for (; k; k--) { n += 1.0; } gl_FragColor = CAST4(n);");
    assert!(t.contains("while (n != 0.0)") && t.contains("k != 0"), "{t}");
}

#[test]
fn a_function_parameter_and_an_uniform_type_the_condition() {
    let src = "uniform int g_Level; varying vec2 v;\nfloat f(float gain, bool on, int n) { if (gain) return 1.0; if (on) return 2.0; if (n) return 3.0; return g_Level ? 4.0 : 5.0; }\nvoid main() { gl_FragColor = CAST4(f(v.x, true, 2)); }";
    let t = frag(src);
    assert!(t.contains("if (gain != 0.0)") && t.contains("if (n != 0)") && t.contains("if (on)"), "{t}");
    let _ = compile_frag(src);
}
