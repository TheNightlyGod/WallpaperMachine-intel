// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.3: implicit conversions (R23 to R45).

use super::support::*;
use crate::request::StageKind;

// ----- scalar to vector (R23, R24) -----

#[test]
fn a_scalar_flows_into_a_vector_in_every_context() {
    let c = ok(
        "vec3 up(vec3 v) { return v * 2.0; }
vec4 ret4(float s) { return s + 3.0; }
vec3 ret3(float s) { return s; }",
        "vec3 a = uf;
vec3 b; b = uf;
vec4 c = CAST4(0.0); c.rgb = uf; c.xy = i1;
vec3 d = (uf > 0.5) ? uf : u3;
vec3 e = up(0.5);
vec3 f = ret3(uf);
vec4 g = ret4(uf);
o = vec4(a + b + d + e + f, 1.0) + c + g;",
    );
    for v in ["a", "b", "d", "e", "f"] {
        assert_eq!(c.local_type(v), "vec3<f32>", "{v}");
    }
    assert_eq!(c.local_type("g"), "vec4<f32>");
}

#[test]
fn a_scalar_is_decided_by_type_not_by_spelling() {
    let decls = "float luma(vec3 c) { return dot(c, vec3(0.3, 0.6, 0.1)); }\nstruct S { float t; };";
    let c = ok(
        decls,
        "vec3 t = u3; float s = uf; S st; st.t = 1.0;
vec3 a = s;
vec3 b = t.x;
vec3 c = dot(t, t);
vec3 d = length(t);
vec3 e = luma(t);
vec3 f = s * 2.0 + t.y;
vec3 g = 1.5;
vec3 h = st.t;
o = vec4(a + b + c + d + e + f + g + h, 1.0);",
    );
    for v in ["a", "b", "c", "d", "e", "f", "g", "h"] {
        assert_eq!(c.local_type(v), "vec3<f32>", "{v}");
    }
}

#[test]
fn a_vector_that_shadows_a_scalar_is_not_broadcast() {
    // inner `vec2 gain` hides the outer `float gain`
    let t = text("float gain = 2.0;", "{ vec2 gain = u2; vec2 p = gain; o = vec4(p, 0.0, 1.0); }");
    assert!(!t.contains("vec2(gain)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn an_unknown_name_and_a_struct_are_not_assumed_scalar() {
    let t = text("struct S { float a; };", "S s; s.a = 1.0; vec3 v = u3 * s.a; o = vec4(v, 1.0);");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    // an undeclared name is left alone for naga to report
    let t = text("", "vec3 v = mystery; o = vec4(v, 1.0);");
    assert!(t.contains("vec3 v = mystery;"), "{t}");
}

// ----- narrowing (R25, R26) -----

fn tex_decls() -> String {
    "layout(set = 0, binding = 1) uniform texture2D tx;\nlayout(set = 0, binding = 2) uniform sampler sm;\n".to_string()
}

#[test]
fn narrowing_applies_to_variables_constructors_calls_arithmetic_and_samples() {
    let c = ok(
        &(tex_decls() + "vec4 make() { return u4; }"),
        "vec2 a = u4;
vec3 b = vec4(i2, 0.0, 1.0);
vec2 c = make();
vec2 d = u4 * 2.0;
vec3 e = texSample2D(sampler2D(tx, sm), i2);
float f = u4;
float g = i2 * 2.0;
float h = texSample2D(sampler2D(tx, sm), i2);
o = vec4(a, b.xy) + vec4(c, d) + vec4(e, 1.0) + CAST4(f + g + h);",
    );
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("b"), "vec3<f32>");
    assert_eq!(c.local_type("f"), "f32");
    let t = text("", "vec2 c = vec4(i2, 0.0, 1.0); float g = i2 * 2.0; o = vec4(c, g, 1.0);");
    assert!(t.contains("vec2 c = vec4(i2, 0.0, 1.0).xy;"), "{t}");
    assert!(t.contains("float g = (i2 * 2.0).x;"), "{t}");
}

#[test]
fn a_sample_assigned_to_a_narrower_target_takes_leading_components() {
    let c = legacy_frag("uniform sampler2D g_T; varying vec2 v_T;\nvoid main() { vec3 c = texSample2D(g_T, v_T); float a = texSample2D(g_T, v_T); vec3 r = texSample2D(g_T, v_T).rgb; gl_FragColor = vec4(c, a + r.x); }");
    assert_eq!(c.local_type("c"), "vec3<f32>");
    assert_eq!(c.local_type("a"), "f32");
    let t = legacy_text(StageKind::Fragment, "uniform sampler2D g_T; varying vec2 v_T;\nvoid main() { vec3 c = texSample2D(g_T, v_T); vec3 r = texSample2D(g_T, v_T).rgb; gl_FragColor = vec4(c + r, 1.0); }");
    assert!(t.contains(".xyz;"), "{t}");
    assert_eq!(count(&t, ".rgb"), 1, "an initializer that already ends in a swizzle is untouched: {t}");
}

// ----- mixed widths in binary operators (R27) -----

#[test]
fn mixed_width_operands_are_cut_to_the_narrower_one() {
    let c = ok(
        "",
        "vec2 a = i2 + u3;
vec2 b = u4 * i2;
vec2 c = (u4 + u3).xy;
vec3 d = (u4 + u3) * uf;
vec2 e = floor(i2) * u3;
vec2 f = max(u4 * i2, u2);
vec2 g = i2 + u3 * uf;
o = vec4(a + b + c + e + f + g, d.xy);",
    );
    for v in ["a", "b", "c", "e", "f", "g"] {
        assert_eq!(c.local_type(v), "vec2<f32>", "{v}");
    }
    assert_eq!(c.local_type("d"), "vec3<f32>");
}

#[test]
fn mixed_widths_inside_a_call_argument_have_no_target() {
    let t = text("", "float k = length(i2 * u3); o = CAST4(k);");
    assert!(t.contains("i2 * u3.xy"), "{t}");
    let t = text("", "vec2 v = max(u4 * i2, u2); o = vec4(v, 0.0, 1.0);");
    assert!(t.contains("u4.xy * i2"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn equal_widths_and_a_swizzled_operand_are_untouched() {
    let t = text("", "vec3 a = u3 + i3; vec2 b = u3.xy + i2; o = vec4(a, b.x);");
    assert!(t.contains("u3 + i3") && t.contains("u3.xy + i2"), "{t}");
    assert_eq!(count(&t, ".xy"), 1, "{t}");
}

// ----- builtins with mixed shapes (R28, R29, R40) -----

#[test]
fn builtins_broadcast_scalars_and_cut_wide_peers() {
    let c = ok(
        "",
        "vec2 a = mix(i2, CAST2(5), 0.375);
vec3 b = min(u4.rgb, 2.5);
vec4 pq = u4; pq.xy = mix(pq, i2, uf);
vec2 d = step(u3, i3);
vec3 e = mix(0.25, 0.75, i3);
vec3 f = pow(sqrt(uf), i3 + ug);
float g = step(u4, CAST4(3.0));
vec3 h = step(0.3, u3);
vec3 i = smoothstep(0.1, 0.9, u3);
vec3 j = clamp(u3, 0.0, 1.0);
vec4 k = clamp(u4, 1, 5);
vec3 l = pow(dot(u3, i3), u3);
o = vec4(a, b.x, 1.0) + pq + vec4(d, e.x, f.x) + CAST4(g) + vec4(h + i + j + l, 1.0) + k;",
    );
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("e"), "vec3<f32>");
    assert_eq!(c.local_type("g"), "f32");
}

#[test]
fn integer_literals_become_float_literals_for_float_builtins() {
    let t = text("", "float a = smoothstep(2, 5, uf); float b = pow(uf, 3); float c = clamp(uf, 0, 8); float d = step(4, uf); o = CAST4(a + b + c + d);");
    assert!(t.contains("smoothstep(2.0, 5.0, uf)") || t.contains("smoothstep(2.0, 5.0"), "{t}");
    assert!(t.contains("pow(uf, 3.0)") && t.contains("clamp(uf, 0.0, 8.0)") && t.contains("step(4.0, uf)"), "{t}");
    let t = text("", "int a = max(ui, 2); uint b = max(uu, 3u); o = CAST4(float(a) + float(b));");
    assert!(t.contains("max(ui, 2)") && t.contains("max(uu, 3u)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_vec4_target_is_never_repaired_by_narrowing_the_arguments() {
    // the program is invalid under HLSL as well and stays invalid
    let t = text("", "vec4 res = mix(u4, i2, uf); o = res;");
    assert!(compile_glsl(StageKind::Fragment, &t).is_err(), "{t}");
}

#[test]
fn a_trailing_member_access_owns_the_context() {
    let t = text("", "vec3 o3 = clamp(u4, u4, u4).zyx; o = vec4(o3, 1.0);");
    assert!(t.contains("clamp(u4, u4, u4).zyx"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- struct members (R30, R80) -----

#[test]
fn a_struct_member_named_like_a_swizzle_is_a_member() {
    let c = ok(
        "struct Holder { vec4 rgb; float x; };",
        "Holder h; h.rgb = u4; h.x = 1.0; vec4 r = h.rgb; vec3 u3b = h.rgb.xyz; o = r + vec4(u3b, h.x);",
    );
    assert_eq!(c.local_type("r"), "vec4<f32>");
    // an outer vector of the same name does not influence the member
    let c = ok("vec3 rgb;\nstruct Holder { vec4 rgb; };", "Holder h; h.rgb = u4; vec4 r = h.rgb; o = r;");
    assert_eq!(c.local_type("r"), "vec4<f32>");
}

// ----- compound assignments (R30) -----

#[test]
fn compound_assignments_cut_wider_values_and_broadcast_scalars() {
    let decls = "float userFloat(float t) { return t * 2.0; }\nvec4 userVec4(float t) { return CAST4(t); }";
    let c = ok(
        decls,
        "vec3 v3 = u3; v3 += u4; v3 += uf; v3 *= 2.0;
vec4 v4 = u4; v4 += userFloat(uf); v4 += userVec4(uf); v4 -= uf * 1.5;
vec2 v2 = u2; v2 -= u3;
o = vec4(v3, 1.0) + v4 + vec4(v2, 0.0, 0.0);",
    );
    let _ = c;
    let t = text(decls, "vec4 v4 = u4; v4 += userVec4(uf); o = v4;");
    assert!(t.contains("v4 += userVec4(uf);"), "a call that returns a 4-vector is never wrapped: {t}");
}

// ----- the one widening (R31) -----

#[test]
fn a_vec2_constructor_is_padded_in_a_vec3_sum_and_in_no_other_shape() {
    let t = text("", "vec3 d = u3 + vec2(1.0, 2.0); o = vec4(d, 1.0);");
    assert!(t.contains("vec3(vec2(1.0, 2.0), 0.0)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    let t = text("", "vec3 d = u3 - CAST2(1.0); o = vec4(d, 1.0);");
    assert!(t.contains("vec3(vec2(1.0), 0.0)"), "{t}");
    // guards: a swizzled vec3 stays two wide, a 2-vector variable is not padded, `*` is not a sum
    let t = text("", "vec2 d = u3.xy + vec2(1.0, 2.0); o = vec4(d, 0.0, 1.0);");
    assert!(!t.contains("0.0)"), "{t}");
    let t = text("", "vec2 w = CAST2(1.0); vec3 d = u3 + w; o = vec4(d, 1.0);");
    assert!(!t.contains("vec3(w"), "{t}");
    let t = text("", "vec3 d = u3 * vec2(1.0, 2.0); o = vec4(d, 1.0);");
    assert!(!t.contains("vec3(vec2"), "{t}");
}

// ----- texture coordinates (R34) -----

#[test]
fn a_sampling_coordinate_keeps_its_leading_two_components() {
    let src = |coord: &str| format!("uniform sampler2D g_T; varying vec4 v_4; varying vec3 v_3; varying vec2 v_2; uniform vec4 g_U4;\nvec4 mk() {{ return g_U4; }}\nvoid main() {{ vec4 s = texSample2D(g_T, {coord}); gl_FragColor = s; }}");
    for coord in ["v_4", "v_3", "v_4 * v_3", "mk()", "mk() * 2.0", "texSample2D(g_T, v_2).xyz", "v_2", "frac(v_4) - v_2"] {
        let c = legacy_frag(&src(coord));
        assert_eq!(c.local_type("s"), "vec4<f32>", "{coord}");
    }
    let t = legacy_text(StageKind::Fragment, &src("v_4"));
    assert!(t.contains("v_4.xy"), "{t}");
    let t = legacy_text(StageKind::Fragment, &src("v_2"));
    assert!(!t.contains("v_2.xy"), "a 2-vector coordinate is untouched: {t}");
}

// ----- integer vectors beside float vectors (R36) -----

#[test]
fn an_integer_vector_beside_a_float_vector_converts() {
    let c = legacy_frag("uniform vec2 g_Size; varying vec2 v_T;\nvoid main() { vec2 size = g_Size; vec2 px = v_T * size; int3 k = int3(1, 2, 3); vec3 w = k * CAST3(0.5); gl_FragColor = vec4(px, w.xy); }");
    assert_eq!(c.local_type("px"), "vec2<f32>");
}

// ----- float to integer (R37 to R40) -----

#[test]
fn float_values_stored_into_integers_truncate() {
    let c = ok(
        "",
        "int a = floor(uf * 32.0);
int b = uf;
int c = i2.x;
uint d = uf;
int e = clamp(ui, 0, 5);
int f = abs(ui);
uint g = max(uu, 2u);
o = vec4(float(a + b + c + e + f), float(d + g), 0.0, 1.0);",
    );
    for v in ["a", "b", "c", "e", "f"] {
        assert_eq!(c.local_type(v), "i32", "{v}");
    }
    assert_eq!(c.local_type("d"), "u32");
    let t = text("", "int a = floor(uf * 32.0); int e = clamp(ui, 0, 5); int f = abs(ui); o = CAST4(float(a + e + f));");
    assert!(t.contains("int a = int(floor(uf * 32.0));"), "{t}");
    assert!(t.contains("int e = clamp(ui, 0, 5);") && t.contains("int f = abs(ui);"), "{t}");
}

#[test]
fn integer_members_and_user_functions_are_left_alone() {
    let t = text("struct Box { int tally; float w; };\nint count() { return 3; }", "Box b; b.tally = 2; int a = b.tally; int c = count(); o = CAST4(float(a + c));");
    assert!(t.contains("int a = b.tally;") && t.contains("int c = count();"), "{t}");
}

#[test]
fn float_values_in_assignments_arguments_and_returns_truncate() {
    let c = ok(
        "int half_of(int n) { return n / 2; }\nint pick(float f) { return f * 2.0; }",
        "int k = 2; k = uf * 3.0; int m = half_of(uf * 4.0); int p = pick(uf); o = CAST4(float(k + m + p));",
    );
    assert_eq!(c.local_type("m"), "i32");
}

#[test]
fn float_indices_and_loop_headers_convert() {
    let c = ok(
        "float bins[4] = float[4](0.1, 0.2, 0.3, 0.4);",
        "float t = uf * 3.0; float w = bins[t]; float acc = 0.0;
for (int i = uf; i < 4; i++) { acc += float(i); }
for (int j = 0; j < 4.0; j++) { acc += 1.0; }
for (float s = 1.0; s > 0.25; s -= 0.25) { acc += s; }
o = CAST4(w + acc);",
    );
    let _ = c;
    let t = text("", "float acc = 0.0; for (int i = uf; i < 4; i++) { acc += 1.0; } o = CAST4(acc);");
    assert!(t.contains("int i = int(uf)"), "{t}");
    let t = text("", "float acc = 0.0; for (int j = 0; j < 4.0; j++) { acc += 1.0; } for (float s = 1.0; s > 0.25; s -= 0.25) { acc += s; } o = CAST4(acc);");
    assert!(t.contains("j < 4;"), "an integral float bound beside an integer counter compares as an integer: {t}");
    assert!(t.contains("for (float s = 1.0; s > 0.25; s -= 0.25)"), "a float counter header is untouched: {t}");
    // a non-integral bound compares in float
    let t = text("", "float acc = 0.0; for (int j = 0; j < 2.5; j++) { acc += 1.0; } o = CAST4(acc);");
    assert!(t.contains("float(j) < 2.5"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- booleans (R41 to R44) -----

#[test]
fn a_boolean_in_arithmetic_counts_as_one_or_zero() {
    let c = ok(
        "float isLit(float x) { return x; }",
        "float hits = 1.0; vec2 m = i2; float p = uf; float q = i1;
hits -= (m.x <= 0.2) * 0.75;
hits += (p >= q) * 0.25;
bool flag = p > q;
float a = flag * 2.0;
float w = flag;
float acc = 0.0; acc -= p > q;
int n = 2; n *= flag;
uint cnt = flag;
bool b2 = uf;
float y = 1.0; y += flag;
o = vec4(hits + a + w + acc + float(n) + float(cnt) + y, float(b2), 0.0, 1.0);",
    );
    assert_eq!(c.local_type("w"), "f32");
    assert_eq!(c.local_type("n"), "i32");
    assert_eq!(c.local_type("cnt"), "u32");
    assert_eq!(c.local_type("b2"), "bool");
}

#[test]
fn nearest_declaration_decides_whether_a_name_is_boolean() {
    // an inner float hides an outer bool; a name that only looks boolean is not converted
    let t = text(
        "",
        "bool active_ = uf > 0.5;
{ float active_ = 2.0; float r = active_ * 3.0; o = CAST4(r); }
float hasGlow = 0.5; float z = hasGlow * 2.0; o += CAST4(z);",
    );
    assert!(t.contains("active_ * 3.0") && !t.contains("float(active_) * 3.0"), "{t}");
    assert!(t.contains("hasGlow * 2.0") && !t.contains("float(hasGlow)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn prototype_parameters_create_no_facts_and_definition_parameters_do() {
    let t = text(
        "float g(bool flag);\nfloat g(bool flag) { return flag * 2.0; }",
        "bool flag = uf > 1.0; float f2 = g(flag); float v = flag * 3.0; o = CAST4(f2 + v);",
    );
    assert!(t.contains("float(flag) * 2.0") && t.contains("float(flag) * 3.0"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn comparisons_that_remain_conditions_and_number_selecting_conditionals_are_untouched() {
    let t = text(
        "",
        "int i = ui; int j = 3; int n = 9;
int k = (i > j ? i : j);
while ((i < n) && (j >= 0)) { i++; j--; }
o = CAST4(float(k + i + j));",
    );
    assert!(t.contains("(i > j ? i : j)"), "{t}");
    assert!(t.contains("while ((i < n) && (j >= 0))"), "{t}");
}

// ----- step stored into an integer (R44) -----

#[test]
fn a_step_stored_into_an_integer_behaves_as_zero_or_one() {
    let c = ok(
        "",
        "float e = uf; float x = i1; bool ok2 = x > 0.1;
int lit = step(e, x);
lit *= ok2;
int m = lit + 1;
int r = lit % 2;
int q = 0;
if (lit) { q = 4; }
o = CAST4(float(m + r + q));",
    );
    for v in ["lit", "m", "r", "q"] {
        assert_eq!(c.local_type(v), "i32", "{v}");
    }
}

#[test]
fn declaration_lists_with_qualifiers_keep_them() {
    let t = text("", "float e = uf; float x = i1; const int a = 1, b = int(step(e, x)); highp /*q*/ int lvl = step(e, 0.75); o = CAST4(float(a + b + lvl));");
    assert!(t.contains("const int a = 1, b = int(step(e, x));"), "{t}");
    assert!(t.contains("highp int lvl = int(step(e, 0.75));"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- int and uint (R45) -----

#[test]
fn int_beside_uint_is_unsigned_and_uint_into_int_converts() {
    let c = ok("", "int i = 3; uint u = 2u; uint a = i + u; int b = u; uint c = i + 1u; bool t = (i + u) > 0u; o = vec4(float(a) + float(b) + float(c), float(t), 0.0, 1.0);");
    assert_eq!(c.local_type("a"), "u32");
    assert_eq!(c.local_type("b"), "i32");
    let t = text("", "int i = 3; uint u = 2u; if (i - u) { i = 1; } o = CAST4(float(i));");
    assert!(t.contains("i - u != 0u"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}
