// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.5: calls, overloads, user functions, array and sampler parameters (R58 to R68).

use super::support::*;
use crate::request::StageKind;

#[test]
fn user_function_arguments_convert_to_the_parameter_types() {
    let decls = "vec2 rot(vec2 v, float r) { return v * r; }
float first(float x) { return x; }
vec3 tint(vec3 c) { return c * 0.5; }
int twice(int n) { return n * 2; }
float gate(float g) { return g; }";
    let c = ok(
        decls,
        "vec4 v4 = u4; vec3 w3 = u3;
vec2 a = rot(v4, uf);
float b = first(w3);
vec3 c = tint(0.5);
int d = twice(uf);
bool flag = uf > 1.0;
float e = gate(flag);
o = vec4(a, b + float(d) + e, c.x);",
    );
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("c"), "vec3<f32>");
    assert_eq!(c.local_type("d"), "i32");
    let t = text(decls, "vec4 v4 = u4; vec2 a = rot(v4, uf); vec3 c = tint(0.5); o = vec4(a, c.xy);");
    assert!(t.contains("rot(v4.xy, uf)") && t.contains("tint(vec3(0.5))"), "{t}");
}

#[test]
fn overloads_pick_the_matching_shape() {
    let decls = "float f(float x) { return x; }\nvec3 f(vec3 x) { return x * 2.0; }";
    let c = ok(decls, "vec3 a = f(u3); float b = f(uf); vec3 c = f(i1); o = vec4(a, b + c.x);");
    assert_eq!(c.local_type("a"), "vec3<f32>");
    assert_eq!(c.local_type("b"), "f32");
    assert_eq!(c.function_count("f"), 2);
    // a vector argument keeps the vector overload and a scalar function is not rewritten because a vector overload exists
    let t = text("vec2 blur2(vec2 q) { return q; }\nfloat blur2(float q) { return q; }", "vec2 a = blur2(i2); float b = blur2(uf); o = vec4(a, b, 1.0);");
    assert!(t.contains("blur2(i2)") && !t.contains("blur2(i2.x)") && !t.contains("blur2(uf).x"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn two_overloads_with_different_shapes_make_no_guess_and_an_ambiguous_call_is_left_to_naga() {
    let decls = "float pick(float a, vec2 b) { return a + b.x; }\nfloat pick(vec2 a, float b) { return a.x + b; }";
    let t = text(decls, "float r = pick(uf, i2); o = CAST4(r);");
    assert!(t.contains("pick(uf, i2)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    // equal costs on both: naga decides, the converter adds nothing
    let t = text("float g(float a, int b) { return a; }\nfloat g(int a, float b) { return b; }", "float r = g(1, 2); o = CAST4(r);");
    assert!(t.contains("g(1, 2)"), "{t}");
}

#[test]
fn conflicting_return_shapes_give_an_unknown_call_that_is_not_wrapped() {
    let t = text("float pick(float s) { return s; }\nvec4 pick(float s) { return CAST4(s); }", "vec4 v = pick(uf); o = v;");
    assert!(!t.contains("vec4(pick(uf))") && t.contains("vec4 v = pick(uf);"), "{t}");
}

#[test]
fn out_inout_and_array_parameters_are_never_converted() {
    let decls = "void split(float v, out vec2 o2, inout float acc) { o2 = CAST2(v); acc += v; }";
    let t = text(decls, "vec2 r; float a = 1.0; split(uf, r, a); o = vec4(r, a, 1.0);");
    assert!(t.contains("split(uf, r, a)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn return_values_convert_to_the_declared_return_type() {
    let decls = "vec2 r2(vec4 c) { return c; }
vec3 r3(vec4 c) { return c; }
vec4 r4(float s) { return s * 0.5 + 2.0; }
float r1(vec3 a, vec3 b) { return a * b; }
int ri(float f) { return f * 2.0; }
uint ru(float f) { return f; }
float rf(bool b) { return b; }
bool rb(float f) { return f; }
bool rc(vec2 v) { return v.x > 0.5; }
void rv() { return; }";
    let c = ok(decls, "vec2 a = r2(u4); vec3 b = r3(u4); vec4 c = r4(uf); float d = r1(u3, i3); int e = ri(uf); uint f = ru(uf); float g = rf(uf > 1.0); bool h = rb(uf); rv(); o = vec4(a, b.x, c.x + d + float(e) + float(f) + g + float(h));");
    let _ = c;
    let t = text(decls, "o = vec4(r2(u4), r3(u4).xy);");
    assert!(t.contains("return c.xy;") && t.contains("return c.xyz;"), "{t}");
    assert!(t.contains("return vec4(s * 0.5 + 2.0);"), "{t}");
    assert!(t.contains("return (a * b).x;"), "{t}");
    assert!(t.contains("return int(f * 2.0);") && t.contains("return uint(f);"), "{t}");
    assert!(t.contains("return float(b);") && t.contains("return (f != 0.0);"), "{t}");
}

#[test]
fn a_struct_return_is_untouched() {
    let t = text("struct S { vec2 v; };\nS make() { S s; s.v = u2; return s; }", "S s = make(); o = vec4(s.v, 0.0, 1.0);");
    assert!(t.contains("return s;"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_prototype_lets_an_earlier_call_check_and_a_void_list_has_no_arguments() {
    let decls = "vec2 later(vec4 c);\nvec2 later(vec4 c) { return c.zw; }\nvec4 nothing(void);\nvec4 nothing(void) { return u4; }";
    let t = text(decls, "vec2 a = later(u4); vec2 b = nothing(); o = vec4(a, b);");
    assert!(t.contains("later(u4)"), "{t}");
    assert!(t.contains("vec2 b = nothing().xy;"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    let t = text("vec2 userVec2();\nvec2 userVec2() { return u2; }", "float k = userVec2(); o = CAST4(k);");
    assert!(t.contains("userVec2().x"), "{t}");
}

#[test]
fn no_operand_is_duplicated_dropped_or_reordered() {
    let decls = "float n = 0.0;\nfloat tick() { n += 1.0; return n; }\nvec3 vtick() { n += 1.0; return CAST3(n); }";
    let body = "float a = fmod(tick(), 3.0);
float b = tick() % 2.0;
vec3 c = mul(CAST3(tick()), um3);
vec3 d = mix(vtick(), CAST3(1.0), tick());
vec3 e = CAST3(tick());
vec4 f = u4; f += vtick().xyzx;
vec2 g = vtick() + u4.xyz * 2.0;
o = CAST4(a + b + c.x + d.x + e.x + f.x + g.x);";
    let source_calls = count(&stage(decls, body), "tick(");
    let t = text(decls, body);
    assert_eq!(count(&t, "tick("), source_calls, "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- array and sampler parameters (R66, R67) -----

#[test]
fn an_array_parameter_is_specialised_for_the_global_array_a_call_passes() {
    let decls = "uniform float taps[8];\nfloat pool(float v[8], float scale) { float s = 0.0; for (int i = 0; i < 8; i++) { s += v[i] * scale; } return s; }";
    let t = legacy_text(StageKind::Fragment, &format!("{decls}\nvoid main() {{ gl_FragColor = CAST4(pool(taps, 0.5)); }}"));
    assert!(!t.contains("float v[8]") && !t.contains("pool(taps"), "{t}");
    let c = legacy_frag(&format!("{decls}\nvoid main() {{ gl_FragColor = CAST4(pool(taps, 0.5)); }}"));
    assert!(c.has_function("pool_wm1"));
}

#[test]
fn different_arrays_at_different_calls_get_a_clone_each() {
    let src = "uniform float left[8]; uniform float right[8];
float pool(float v[8], float scale) { return v[1] * scale + v[2]; }
void main() { gl_FragColor = CAST4(pool(left, 1.0) + pool(right, 2.0) + pool(left, 3.0)); }";
    let c = legacy_frag(src);
    assert!(c.has_function("pool_wm1") && c.has_function("pool_wm2"));
    assert!(!c.has_function("pool_wm3"));
}

#[test]
fn a_same_name_scalar_overload_and_other_parameters_survive() {
    let src = "uniform float taps[4];
float pool(float s) { return s * 2.0; }
float pool(float v[4], float scale) { return v[0] * scale; }
void main() { gl_FragColor = CAST4(pool(taps, 0.5) + pool(3.0)); }";
    let c = legacy_frag(src);
    assert!(c.has_function("pool"), "the scalar overload stays");
    assert!(c.has_function("pool_wm1"));
}

#[test]
fn locals_and_struct_fields_named_like_an_array_parameter_are_not_rewritten() {
    let src = "uniform float taps[4]; struct S { float v; };
float pool(float v[4]) { S s; s.v = 2.0; float acc = v[0] + s.v; { float v = 1.5; acc += v; } return acc; }
void main() { gl_FragColor = CAST4(pool(taps)); }";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("s.v = 2.0") && t.contains("float v = 1.5;") && t.contains("acc += v;"), "{t}");
    assert!(t.contains("taps[0]") && t.contains("+ s.v"), "{t}");
    legacy_frag(src);
}

#[test]
fn an_array_parameter_the_body_writes_is_copied_into_a_local() {
    let src = "uniform float taps[4];
float pool(float v[4]) { v[0] = 3.0; return v[0] + v[1]; }
void main() { gl_FragColor = CAST4(pool(taps)); }";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("float v[4] = float[4](taps[0].x, taps[1].x"), "{t}");
}

#[test]
fn a_local_array_argument_is_refused_with_the_specialisation_limit() {
    let d = convert_err(StageKind::Fragment, "float pool(float v[4]) { return v[0]; }\nvoid main() { float loc[4]; loc[0] = 1.0; gl_FragColor = vec4(pool(loc)); }");
    assert!(d.iter().any(|m| m.contains("array-parameter specialisation")), "{d:?}");
}

#[test]
fn a_sampler_parameter_samples_the_texture_the_call_passes() {
    let src = "uniform sampler2D g_Texture0; uniform sampler2D g_Texture1; varying vec2 v_T;
vec4 fetch(DECLARE_SAMPLER2D_PARAMETER(tex), vec2 uv, float k) { return texSample2D(tex, uv) * k; }
void main() { gl_FragColor = fetch(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), v_T, 1.0) + fetch(MAKE_SAMPLER2D_ARGUMENT(g_Texture1), v_T, 2.0); }";
    let c = legacy_frag(src);
    assert!(c.has_function("fetch_wm1") && c.has_function("fetch_wm2"));
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("sampler2D(g_Texture0, _we_Sampler_g_Texture0), uv)") && t.contains("sampler2D(g_Texture1, _we_Sampler_g_Texture1), uv)"), "{t}");
}

#[test]
fn a_sampler_parameter_passes_through_to_a_nested_helper() {
    let src = "uniform sampler2D g_Texture0; varying vec2 v_T;
vec4 inner(DECLARE_SAMPLER2D_PARAMETER(t), vec2 uv) { return texSample2D(t, uv); }
vec4 outer(DECLARE_SAMPLER2D_PARAMETER(t), vec2 uv) { return inner(MAKE_SAMPLER2D_ARGUMENT(t), uv) * 2.0; }
void main() { gl_FragColor = outer(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), v_T); }";
    let c = legacy_frag(src);
    assert!(c.has_function("inner_wm1") && c.has_function("outer_wm1"));
}
