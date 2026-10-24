// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.2: the dialect vocabulary (R8 to R22).

use super::support::*;
use crate::request::StageKind;

// ----- HLSL type aliases (R8) -----

#[test]
fn float_aliases_are_types_everywhere() {
    let c = ok(
        "struct S { float3 a; float2 b; float1 c; float4 d; };
float2 f(float3 p, float1 q) { float4 t = float4(p, q); return t.xy; }",
        "float2 a = float2(1.0, 2.0);
float3 b = float3(a, 3.0);
float1 c = float1(2.0);
float4 d = float4(b, c);
S s;
s.a = b;
s.b = f(b, c);
float2 r = s.b;
o = float4(r, s.a.xy);",
    );
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("b"), "vec3<f32>");
    assert_eq!(c.local_type("c"), "f32");
    assert_eq!(c.local_type("d"), "vec4<f32>");
    let t = text("float2 f2(float3 p) { return p.xy; }", "o = vec4(f2(u3), 0.0, 1.0);");
    assert!(!t.contains("float2") && !t.contains("float3"), "no alias is left in the output: {t}");
}

#[test]
fn float_aliases_in_interface_declarations() {
    let c = legacy_frag("varying float2 v_Tex;\nuniform float1 g_Level;\nuniform float3 g_Tint;\nvoid main() { gl_FragColor = float4(v_Tex, g_Level, g_Tint.x); }");
    assert!(c.module.entry_points.len() == 1);
    let out = legacy_text(StageKind::Fragment, "varying float2 v_Tex;\nuniform float1 g_Level;\nvoid main() { gl_FragColor = float4(v_Tex, g_Level, 1.0); }");
    assert!(out.contains("in vec2 v_Tex;"), "{out}");
    assert!(out.contains("float g_Level;"), "{out}");
}

// ----- cast macros (R9 to R11) -----

#[test]
fn cast_constructors_take_scalars_and_wider_vectors() {
    let c = legacy_frag(
        "uniform float g_F; uniform vec3 g_V3; uniform vec4 g_V4; uniform mat4 g_M;
void main() {
  vec2 a = CAST2(g_F);
  vec3 b = CAST3(0.5);
  vec4 c = CAST4(g_F);
  vec2 d = CAST2(g_V3);
  vec3 e = CAST3X3(g_M) * g_V3;
  gl_FragColor = vec4(a, b.x, c.x + d.y + e.z);
}",
    );
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("b"), "vec3<f32>");
    assert_eq!(c.local_type("c"), "vec4<f32>");
    assert_eq!(c.local_type("d"), "vec2<f32>");
    assert_eq!(c.local_type("e"), "vec3<f32>");
}

#[test]
fn cast3_of_a_wider_value_narrows_next_to_a_narrower_operand() {
    // `CAST3(h) + n2` cuts the 3-vector to the 2-vector's width (R9, R27)
    let c = ok("", "vec3 h3 = u3; vec2 s = CAST3(h3) + u2; o = vec4(s, 0.0, 1.0);");
    assert_eq!(c.local_type("s"), "vec2<f32>");
}

#[test]
fn cast3x3_works_as_operand_of_star_mul_and_in_macros() {
    let a = ok("", "vec3 r = CAST3X3(um4) * u3; o = vec4(r, 1.0);");
    let b = ok("", "vec3 r = mat3(um4) * u3; o = vec4(r, 1.0);");
    assert_eq!(a.msl, b.msl);
    let c = ok("", "vec3 r = mul(u3, CAST3X3(um4)); o = vec4(r, 1.0);");
    let d = ok("", "vec3 r = mat3(um4) * u3; o = vec4(r, 1.0);");
    assert_eq!(c.msl, d.msl);
    let m = ok("#define ROT(m) CAST3X3(m)\n", "vec3 r = ROT(um4) * u3; o = vec4(r, 1.0);");
    assert_eq!(m.msl, a.msl);
    // weighted sums of several 3x3 blocks, as the skinning code writes them
    ok("", "vec3 r = mul(u3, CAST3X3(um4) * uf + CAST3X3(um4) * 0.5); o = vec4(r, 1.0);");
}

#[test]
fn cast3x3_of_a_mat4x3_bone_element_gives_a_mat3() {
    let c = ok("", "mat3 b = CAST3X3(ub[uuv4.x]); vec3 r = b * u3; o = vec4(r, 1.0);");
    assert_eq!(c.local_type("b"), "mat3x3");
    ok("", "vec3 n = mul(u3, CAST3X3(ub[uuv4.x]) * u4.x + CAST3X3(ub[uuv4.y]) * u4.y); o = vec4(n, 1.0);");
}

#[test]
fn integer_and_float_cast_macros_need_no_shader_side_definition() {
    let c = legacy_vert(
        "attribute vec3 a_Position; uniform vec2 g_Texture5Resolution; uniform float g_F;
void main() {
  uint a = CASTU(gl_VertexID);
  float b = CASTF(gl_VertexID % 4u) * 0.25;
  int c = CASTI(g_F);
  uint d = CASTU(g_Texture5Resolution.x);
  float e = CASTF(gl_VertexID) * 0.25;
  uvec4 f = CAST4U(a);
  gl_Position = vec4(a_Position, 1.0 + b + float(c) + float(d) + e + float(f.x));
}",
    );
    assert_eq!(c.local_type("a"), "u32");
    assert_eq!(c.local_type("b"), "f32");
    assert_eq!(c.local_type("c"), "i32");
    assert_eq!(c.local_type("d"), "u32");
}

#[test]
fn a_shader_that_defines_a_cast_macro_itself_keeps_its_meaning() {
    let c = ok("#define CAST2(x) (vec2(x, x))\n#define CASTU(x) uint(x + 1.0)\n", "vec2 a = CAST2(uf); uint b = CASTU(uf); o = vec4(a, float(b), 1.0);");
    assert_eq!(c.local_type("a"), "vec2<f32>");
    let t = text("#define CASTU(x) uint(x + 1.0)\n", "uint b = CASTU(uf); o = vec4(float(b));");
    assert!(t.contains("uint(uf + 1.0)"), "{t}");
}

// ----- mul (R12) -----

#[test]
fn mul_is_the_swapped_product_for_every_operand_shape() {
    assert_eq!(ok("", "o = mul(u4, um4);").msl, ok("", "o = um4 * u4;").msl);
    assert_eq!(ok("", "o = mul(um4, um4) * u4;").msl, ok("", "o = (um4 * um4) * u4;").msl);
    assert_eq!(ok("", "o = mul(u4.yxzw, um4);").msl, ok("", "o = um4 * u4.yxzw;").msl);
    assert_eq!(ok("", "o = mul(u4 * 2.0, um4);").msl, ok("", "o = um4 * (u4 * 2.0);").msl);
    assert_eq!(ok("", "o = mul(vec4(i3, 1.0), um4);").msl, ok("", "o = um4 * vec4(i3, 1.0);").msl);
}

#[test]
fn mul_nests_and_swaps_at_every_level() {
    assert_eq!(ok("", "o = mul(mul(u4, um4), um4);").msl, ok("", "o = um4 * (um4 * u4);").msl);
    let a = ok("", "mat4 p = um4; o = mul(mul(u4, p), um4);");
    let b = ok("", "mat4 p = um4; o = um4 * (p * u4);");
    assert_eq!(a.msl, b.msl);
}

#[test]
fn mul_with_a_user_function_result_and_a_matrix_first_operand() {
    let decls = "mat4 make(float k) { return um4 * k; }\nvec4 vecfn() { return u4; }";
    assert_eq!(ok(decls, "o = mul(u4, make(uf));").msl, ok(decls, "o = make(uf) * u4;").msl);
    assert_eq!(ok(decls, "o = mul(make(uf), u4);").msl, ok(decls, "o = u4 * make(uf);").msl);
    assert_eq!(ok(decls, "o = mul(vecfn().yxzw, um4);").msl, ok(decls, "o = um4 * vecfn().yxzw;").msl);
    // a mat3 first, a vector second: the transposed product
    assert_eq!(ok("", "vec3 v = mul(um3, u3); o = vec4(v, 1.0);").msl, ok("", "vec3 v = u3 * um3; o = vec4(v, 1.0);").msl);
}

#[test]
fn mul_with_other_arities_is_left_for_naga_to_refuse() {
    for call in ["mul(u4)", "mul(u4, um4, um4)"] {
        let t = text("", &format!("o = {call};"));
        assert!(t.contains("mul("), "{t}");
        assert!(compile_glsl(StageKind::Fragment, &t).is_err());
    }
}

#[test]
fn a_user_two_argument_mul_wins() {
    let decls = "vec4 mul(vec4 a, float b) { return a * b + 1.0; }";
    let t = text(decls, "o = mul(u4, uf);");
    assert!(t.contains("mul(u4, uf)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    // arguments the user function cannot take still get the dialect meaning
    let t = text(decls, "o = mul(u4, um4);");
    assert!(t.contains("um4 * u4"), "{t}");
}

#[test]
fn mul_inside_a_macro_replacement_is_converted() {
    let a = ok("#define XFORM(v, m) mul(v, m)\n", "o = XFORM(u4, um4);");
    assert_eq!(a.msl, ok("", "o = um4 * u4;").msl);
    // the macro that stands for a mul, used as an operand of another mul
    let b = ok("#define MVP mul(um4, um4)\n", "o = mul(u4, MVP);");
    assert_eq!(b.msl, ok("", "o = (um4 * um4) * u4;").msl);
}

#[test]
fn mul_of_two_vectors_of_one_width_is_the_dot_product() {
    let c = ok("", "float d = mul(u3, i3); o = vec4(d);");
    assert_eq!(c.local_type("d"), "f32");
    assert_eq!(ok("", "float d = mul(u3, i3); o = vec4(d);").msl, ok("", "float d = dot(u3, i3); o = vec4(d);").msl);
    // mixed widths keep the swapped product and the failure that comes with it
    let t = text("", "vec3 d = mul(u3, i2); o = vec4(d, 1.0);");
    assert!(t.contains("i2 * u3"), "{t}");
}

// ----- renamed calls (R13 to R17) -----

#[test]
fn saturate_clamps_scalars_vectors_and_integers() {
    let c = ok("", "float a = saturate(uf); vec3 b = saturate(u3 * 2.0); float c = saturate(2); o = vec4(a, b.x, c, 1.0);");
    assert_eq!(c.local_type("a"), "f32");
    assert_eq!(c.local_type("b"), "vec3<f32>");
    let t = text("", "float c = saturate(2); o = vec4(c);");
    assert!(t.contains("clamp(2.0, 0.0, 1.0)"), "{t}");
}

#[test]
fn frac_lerp_and_atan2_map_to_their_glsl_names_and_argument_order() {
    let t = text("", "float a = frac(uf); vec3 b = lerp(u3, vec3(1.0), 0.5); float c = atan2(uf, 2.0); o = vec4(a, b.x, c, 1.0);");
    assert!(t.contains("fract(uf)"), "{t}");
    assert!(t.contains("mix(u3, vec3(1.0), 0.5)"), "{t}");
    assert!(t.contains("atan(uf, 2.0)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
    // lerp with an integer literal and a scalar against a vector
    let t = text("", "vec3 b = lerp(u3, 5, 0.25); vec3 c = lerp(0.25, 0.75, u3); o = vec4(b + c, 1.0);");
    assert!(t.contains("vec3(5.0)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn ddx_and_ddy_are_screen_derivatives() {
    let t = text("", "float a = ddx(i1); float b = ddy(i1); o = vec4(a * a + b * b);");
    assert!(t.contains("dFdx(i1)"), "{t}");
    assert!(t.contains("dFdy(-(i1))"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn fmod_is_a_truncated_remainder_for_scalars_and_vectors() {
    let c = ok("", "float a = fmod(uf, 3.0); vec3 b = fmod(u3, 2.0); vec3 c = fmod(2.0, u3); o = vec4(a + b.x + c.y);");
    assert_eq!(c.local_type("a"), "f32");
    assert_eq!(c.local_type("b"), "vec3<f32>");
    assert!(c.msl.contains("fmod"), "{}", c.msl);
}

#[test]
fn log10_is_log2_times_a_constant() {
    let t = text("", "float a = log10(uf); vec3 b = log10(u3); o = vec4(a, b.x, 0.0, 1.0);");
    assert!(t.contains("log2(uf) * 0.301029995663981"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn fmod_and_float_remainder_call_a_side_effecting_operand_once() {
    let decls = "float n = 0.0;\nfloat tick() { n += 1.0; return n; }";
    let source = count(&stage(decls, "float r = fmod(tick(), 3.0);\nfloat s = tick() % 2.0;\nfloat q = 7.0 % tick();\no = vec4(r + s + q);"), "tick(");
    let t = text(decls, "float r = fmod(tick(), 3.0);\nfloat s = tick() % 2.0;\nfloat q = 7.0 % tick();\no = vec4(r + s + q);");
    assert_eq!(count(&t, "tick("), source, "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- clip (R18) -----

#[test]
fn clip_discards_for_negative_scalars_and_any_negative_component() {
    let c = ok("", "clip(uf - 0.5); clip(u3); clip(u2); clip(u4); o = vec4(1.0);");
    assert!(count(&c.msl, "discard_fragment") >= 4, "{}", c.msl);
    let t = text("", "clip(uf); o = vec4(1.0);");
    assert!(t.contains("clip(float v)"), "{t}");
    assert!(!t.contains("clip(vec3"), "only the overload in use is emitted: {t}");
}

#[test]
fn clip_is_generated_only_when_used_and_not_when_the_shader_defines_it() {
    assert!(!text("", "o = vec4(1.0);").contains("clip"));
    let t = text("void clip(float v) { if (v < 0.0) discard; }", "clip(uf); o = vec4(1.0);");
    assert_eq!(count(&t, "void clip(float v)"), 1, "{t}");
    assert!(!t.contains("_wm_clip"), "{t}");
    // a vertex stage has no `clip`: it is an ordinary identifier there
    let v = vert("layout(location = 0) in vec3 a;\nvoid main() { clip(a.x); gl_Position = vec4(a, 1.0); }");
    assert!(v.contains("clip(a.x)") && !v.contains("_wm_clip"), "{v}");
}

// ----- texture calls (R16, R19, R84) -----

#[test]
fn every_sampling_spelling_samples_a_2d_coordinate() {
    for call in ["texSample2D(g_Texture0, v_T)", "tex2D(g_Texture0, v_T)", "texture2D(g_Texture0, v_T)", "texture(g_Texture0, v_T)"] {
        let c = legacy_frag(&format!("uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() {{ vec4 s = {call}; gl_FragColor = s; }}"));
        assert_eq!(c.local_type("s"), "vec4<f32>", "{call}");
    }
    for call in ["texSample2DLod(g_Texture0, v_T, 1.0)", "textureLod(g_Texture0, v_T, 1)"] {
        let c = legacy_frag(&format!("uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() {{ vec4 s = {call}; gl_FragColor = s; }}"));
        assert_eq!(c.local_type("s"), "vec4<f32>", "{call}");
    }
}

#[test]
fn a_shader_defining_texture_or_tex2d_keeps_its_calls() {
    let src = "uniform sampler2D g_Texture0; varying vec2 v_T;
vec4 tex2D(sampler2D s, vec2 uv) { return vec4(uv, 0.0, 1.0); }
void main() { gl_FragColor = tex2D(g_Texture0, v_T); }";
    // the call stays a call of the author's function; a sampler argument is passed to it, so it is
    // specialised for the texture and still compiles
    let t = legacy_text(StageKind::Fragment, src);
    assert!(!t.contains("texture(") , "{t}");
}

#[test]
fn a_sampler_function_parameter_is_not_required_to_work_for_unknown_names() {
    // an unresolved name is renamed like the rest; naga then judges it
    let t = frag("varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(mystery, v_T); }");
    assert!(t.contains("texture(mystery"), "{t}");
}

// ----- user definitions win (R65, R21) -----

#[test]
fn shader_defined_log10_saturate_and_lerp_are_called() {
    let decls = "float log10(float x) { return x * 10.0; }\nfloat saturate(float x) { return x * 3.0; }\nfloat lerp(float a, float b, float t) { return a + b + t; }";
    let t = text(decls, "float a = log10(uf); float b = saturate(uf); float c = lerp(uf, uf, uf); o = vec4(a + b + c);");
    assert!(t.contains("log10(uf)") && t.contains("saturate(uf)") && t.contains("lerp(uf, uf, uf)"), "{t}");
    assert!(!t.contains("log2("), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_vector_argument_to_a_user_saturate_of_a_float_still_clamps() {
    let t = text("float saturate(float x) { return x * 3.0; }", "float a = saturate(uf); vec3 b = saturate(u3); o = vec4(a, b);");
    assert!(t.contains("saturate(uf)"), "{t}");
    assert!(t.contains("clamp(u3, 0.0, 1.0)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ----- macros of dialect names (R20, E11) -----

#[test]
fn macro_bodies_are_converted_where_they_expand() {
    let c = ok("#define TINT(c, k) lerp(c * 0.5, CAST3(0.8), saturate(k))\n", "vec3 col3 = u3; float f = uf; vec3 r = TINT(col3, f); o = vec4(r, 1.0);");
    assert_eq!(c.local_type("r"), "vec3<f32>");
    let t = text("#define TINT(c, k) lerp(c * 0.5, CAST3(0.8), saturate(k))\n", "vec3 r = TINT(u3, uf); o = vec4(r, 1.0);");
    assert!(t.contains("mix(u3 * 0.5, vec3(0.8), clamp(uf, 0.0, 1.0))"), "{t}");
}

#[test]
fn a_macro_that_is_only_a_dialect_name_works_as_a_call() {
    let t = text("#define MIXFN lerp\n", "vec3 r = MIXFN(u3, u3, 0.5); o = vec4(r, 1.0);");
    assert!(t.contains("mix(u3, u3, 0.5)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn macros_defined_in_a_function_body_apply_from_there_and_undef_stops_them() {
    let t = text("", "#define K lerp\nvec3 r = K(u3, u3, 0.5);\n#undef K\no = vec4(r, 1.0);");
    assert!(t.contains("mix("), "{t}");
    assert!(!t.contains("#define"), "{t}");
}

// ----- unsupported names (R22) -----

#[test]
fn unsupported_constructs_fail_with_a_diagnostic_that_names_them() {
    let d = convert_err(StageKind::Fragment, "uniform sampler2D g_T; varying vec2 v;\nvoid main() { gl_FragColor = vec4(texSample2DCompare(g_T, v, 0.5)); }");
    assert!(d.iter().any(|m| m.contains("texSample2DCompare")), "{d:?}");
    let d = convert_err(StageKind::Fragment, "uniform sampler2DComparison g_S;\nvoid main() { }");
    assert!(d.iter().any(|m| m.contains("sampler2DComparison")), "{d:?}");
    let d = convert_err(StageKind::Fragment, "uniform sampler2D g_T; varying vec2 v;\nvoid main() { gl_FragColor = texLoad2D(g_T, v) + texSample2DBackBuffer(g_T, v, v); }");
    assert!(d.iter().any(|m| m.contains("texLoad2D")) && d.iter().any(|m| m.contains("texSample2DBackBuffer")), "{d:?}");
}
