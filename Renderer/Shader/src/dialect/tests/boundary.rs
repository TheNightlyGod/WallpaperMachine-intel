// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Sections 8.7 and 8.8: boundary items, output properties and the behaviours added by review
//! (R83 to R106).

use super::support::*;
use crate::dialect::convert_stage;
use crate::diagnostic::Pass;
use crate::request::StageKind;

// ----- alpha-to-coverage idiom (R83) -----

const SHARPEN: &str = "gl_FragColor.a = saturate((gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5);";

fn frag_with(body: &str) -> String {
    format!("varying vec2 v_T; uniform vec4 g_C;\nvoid main() {{\n{body}\n}}")
}

#[test]
fn the_derivative_sharpening_of_the_colour_alpha_is_replaced_by_the_source_alpha() {
    let t = frag(&frag_with(&format!("vec4 col = g_C; gl_FragColor = col;\n{SHARPEN}")));
    assert!(t.contains("gl_FragColor.a = clamp(col.a, 0.0, 1.0);"), "{t}");
    assert!(!t.contains("fwidth"), "{t}");
    // without the saturate wrapper the replacement has no clamp
    let t = frag(&frag_with("vec4 col = g_C; gl_FragColor = col;\ngl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;"));
    assert!(t.contains("gl_FragColor.a = col.a;"), "{t}");
    // a reserved word as the source variable
    let t = frag(&frag_with(&format!("vec4 sample = g_C; gl_FragColor = sample;\n{SHARPEN}")));
    assert!(t.contains("gl_FragColor.a = clamp(sample_wm.a, 0.0, 1.0);"), "{t}");
    legacy_frag(&frag_with(&format!("vec4 col = g_C; gl_FragColor = col;\n{SHARPEN}")));
}

#[test]
fn the_idiom_is_left_alone_when_no_visible_source_exists() {
    // colour assigned from a non-identifier
    let t = frag(&frag_with(&format!("gl_FragColor = g_C * 2.0;\n{SHARPEN}")));
    assert!(t.contains("fwidth"), "{t}");
    // the colour is assigned only in another function
    let t = frag(&format!("uniform vec4 g_C;\nvoid set() {{ vec4 col = g_C; gl_FragColor = col; }}\nvoid main() {{ set();\n{SHARPEN}\n}}"));
    assert!(t.contains("fwidth"), "{t}");
    // the source went out of scope with an inner block
    let t = frag(&frag_with(&format!("{{ vec4 col = g_C; gl_FragColor = col; }}\n{SHARPEN}")));
    assert!(t.contains("fwidth"), "{t}");
    // a statement that only resembles the form (no derivative call)
    let t = frag(&frag_with("vec4 col = g_C; gl_FragColor = col;\ngl_FragColor.a = saturate((gl_FragColor.a - 0.5) / 0.0001 + 0.5);"));
    assert!(!t.contains("col.a"), "{t}");
}

#[test]
fn only_the_colour_output_alpha_is_neutralised() {
    let helper = "void sharpen(inout float alpha) { alpha = saturate((alpha - 0.5) / max(fwidth(alpha), 0.0001) + 0.5); }";
    let t = frag(&format!("{helper}\nuniform vec4 g_C;\nvoid main() {{ vec4 col = g_C; sharpen(col.a); gl_FragColor = col; }}"));
    assert!(t.contains("fwidth(alpha)"), "{t}");
    let t = frag("uniform vec4 g_C;\nvoid main() { vec4 albedo = g_C; albedo.a = (albedo.a - 0.5) / max(fwidth(albedo.a), 0.0001) + 0.5; gl_FragColor = albedo; }");
    assert!(t.contains("fwidth(albedo.a)"), "{t}");
    legacy_frag("uniform vec4 g_C;\nvoid main() { vec4 albedo = g_C; albedo.a = (albedo.a - 0.5) / max(fwidth(albedo.a), 0.0001) + 0.5; gl_FragColor = albedo; }");
}

#[test]
fn the_sharpening_idiom_is_fragment_only() {
    let t = vert("attribute vec4 a_C;\nvoid main() { vec4 col = a_C; gl_Position = col; gl_Position.a = (gl_Position.a - 0.5) / max(fwidth(gl_Position.a), 0.0001) + 0.5; }");
    assert!(t.contains("fwidth"), "{t}");
}

// ----- matrix inverse (R87) -----

#[test]
fn inverse_of_every_square_size_compiles_to_metal() {
    let c = legacy_frag("uniform vec4 g_V; uniform mat3 g_B; uniform mat4 g_C;\nvoid main() { mat2 a = inverse(mat2(g_V.xy, g_V.zw)); mat3 b = inverse(g_B); mat4 c = inverse(g_C); gl_FragColor = vec4(a[0], b[1].x, c[2].y); }");
    assert_eq!(c.local_type("b"), "mat3x3");
    assert!(!c.msl.contains("metal::inverse") && !c.msl.contains("Inverse"), "the Metal writer has no inverse: {}", c.msl);
}

#[test]
fn only_the_sizes_a_stage_calls_are_generated() {
    let t = frag("uniform mat3 g_B;\nvoid main() { mat3 b = inverse(g_B); gl_FragColor = vec4(b[0], 1.0); }");
    assert!(t.contains("mat3 _wm_inverse(mat3 m)") && !t.contains("mat2 _wm_inverse") && !t.contains("mat4 _wm_inverse"), "{t}");
    assert!(!frag("void main() { gl_FragColor = vec4(1.0); }").contains("inverse"));
}

#[test]
fn a_shader_defined_mat3_inverse_is_called_and_the_other_sizes_are_still_supplied() {
    let src = "uniform mat3 g_B; uniform mat4 g_C;
mat3 inverse(mat3 m) { return transpose(m); }
void main() { mat3 b = inverse(g_B); mat4 c = inverse(g_C); gl_FragColor = vec4(b[0], c[1].x); }";
    let t = frag(src);
    assert!(t.contains("mat3 b = inverse(g_B);"), "the author's function is called: {t}");
    assert!(t.contains("mat4 c = _wm_inverse(g_C);"), "{t}");
    legacy_frag(src);
}

// ----- builtin variables (R88) -----

#[test]
fn index_builtins_are_unsigned_and_a_restated_one_is_not_an_input() {
    let c = legacy_vert("attribute vec3 a_P; in uint gl_VertexID; attribute uint gl_InstanceID; varying uint gl_VertexID;\nvoid main() { uint a = gl_InstanceID * 3u; float b = CASTF(gl_VertexID) * 0.25; gl_Position = vec4(a_P, b + float(a)); }");
    assert_eq!(c.local_type("a"), "u32");
    assert!(c.msl.contains("[[vertex_id]]") && c.msl.contains("[[instance_id]]"), "{}", c.msl);
    assert_eq!(count(&c.msl, "[[attribute("), 1, "only a_P is a vertex input: {}", c.msl);
}

#[test]
fn a_macro_naming_an_index_builtin_is_renamed_where_it_is_written() {
    let t = vert("#define IDX gl_VertexID\nattribute vec3 a_P;\nvoid main() { float k = CASTF(IDX); gl_Position = vec4(a_P, k); }");
    assert!(t.contains("gl_VertexIndex") && !t.contains("gl_VertexID"), "{t}");
}

#[test]
fn only_the_uint_spelling_restates_a_builtin_and_other_gl_names_keep_their_handling() {
    let t = vert("in uint gl_VertexID;\nin int gl_ViewportIndex;\nattribute vec3 my_gl_thing;\nvoid main() { gl_Position = vec4(my_gl_thing, 1.0); }");
    assert!(!t.contains("gl_VertexID;"), "{t}");
    assert!(t.contains("in int gl_ViewportIndex;") && t.contains("attribute vec3 my_gl_thing;"), "{t}");
    let t = vert("in int gl_VertexID;\nvoid main() { gl_Position = vec4(1.0); }");
    assert!(t.contains("in int gl_VertexID;"), "the same name with another type is a user variable: {t}");
}

// ----- output properties (R93 to R95) -----

#[test]
fn the_output_starts_with_the_version_and_precision_lines() {
    let t = frag("void main() { gl_FragColor = vec4(1.0); }");
    let mut lines = t.lines();
    assert_eq!(lines.next(), Some("#version 450"));
    assert_eq!(lines.next(), Some("precision highp float;"));
}

#[test]
fn a_pure_glsl_stage_keeps_its_meaning_and_converting_the_output_changes_nothing() {
    let src = "#version 450
layout(std140, set = 0, binding = 0) uniform U { vec4 a; vec3 b; float c; };
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 outColor;
float luma(vec3 v) { return dot(v, vec3(0.3, 0.6, 0.1)); }
vec2 blur2(vec2 q) { return q * 0.5; }
float blur2(float q) { return q * 0.25; }
void main() {
  vec3 t = b * c;
  float l = luma(t);
  vec2 q = blur2(uv);
  float r = blur2(c);
  vec4 col = vec4(mix(t, vec3(l), 0.5), 1.0);
  col.rg += q;
  col.b *= r;
  for (int i = 0; i < 3; i++) { col += a * float(i); }
  if (c > 0.5) { col = col.bgra; }
  outColor = col;
}";
    let direct = compile_glsl(StageKind::Fragment, src).unwrap();
    let converted = convert_stage(StageKind::Fragment, src).unwrap();
    let through = compile_glsl(StageKind::Fragment, &converted.text).unwrap();
    assert_eq!(direct.msl, through.msl, "the meaning is unchanged");
    let again = convert_stage(StageKind::Fragment, &converted.text).unwrap();
    assert_eq!(again.text, converted.text, "converting the output again changes nothing");
}

#[test]
fn converting_the_same_input_twice_is_byte_identical() {
    let src = "varying vec4 v_T; uniform sampler2D g_Texture0; uniform float g_F;
float f(float a) { return a % 2; }
void main() { int k = floor(g_F * 3.0); vec3 c = texSample2D(g_Texture0, v_T); gl_FragColor = vec4(c * lerp(1.0, 2.0, saturate(g_F)) + float(k) + f(g_F) + (g_F > 0.5), 1.0); }";
    let a = convert_stage(StageKind::Fragment, src).unwrap();
    let b = convert_stage(StageKind::Fragment, src).unwrap();
    assert_eq!(a.text, b.text);
    assert_eq!(a.module, b.module);
}

#[test]
fn the_converted_text_has_no_dialect_left() {
    let src = "varying float2 v_T; uniform float4x4_ g_Unused_;
void main() { float3 c = CAST3(0.5); float2 p = v_T * 2; c = lerp(c, saturate(c), frac(p.x)); gl_FragColor = float4(c, ddx(p.x) + log10(p.y) + fmod(p.x, 2.0)); }";
    let src = src.replace("uniform float4x4_ g_Unused_;", "");
    let t = frag(&src);
    for word in ["float2", "float3", "float4", "CAST3", "lerp", "saturate", "frac", "ddx", "log10", "fmod"] {
        assert!(!has_word(&t, word), "{word}: {t}");
    }
}

// ----- diagnostics (R100) -----

#[test]
fn success_carries_one_informational_codegen_entry() {
    let src = "void main() { gl_FragColor = vec4(1.0); }";
    let c = convert_stage(StageKind::Fragment, src).unwrap();
    assert_eq!(c.diagnostics.len(), 1);
    let d = &c.diagnostics[0];
    assert_eq!(d.pass, Some(Pass::Codegen));
    assert_eq!(d.stage, Some(StageKind::Fragment));
    assert_eq!((d.span.unwrap().start(), d.span.unwrap().end()), (0, src.len()));
    assert!(crate::diagnostic::diagnostics_json(&c.diagnostics).contains("\"pass\":\"Codegen\""));
}

#[test]
fn a_rejection_carries_the_stage_the_pass_and_a_span_inside_the_source() {
    let src = "uniform sampler2D g_T; varying vec2 v;\nvoid main() { gl_FragColor = texSample2DCompare(g_T, v, 0.5); }";
    let Err(d) = convert_stage(StageKind::Fragment, src) else { panic!("should be refused") };
    assert_eq!(d[0].stage, Some(StageKind::Fragment));
    assert_eq!(d[0].pass, Some(Pass::Codegen));
    let s = d[0].span.unwrap();
    assert!(s.is_within(src) && src[s.start()..s.end()].contains("texSample2DCompare"));
    let Err(d) = convert_stage(StageKind::Fragment, "void main() { if (a) { b(); }") else { panic!() };
    assert!(d[0].span.is_some());
}

// ----- revision (R99) -----

/// The converter's output for fixed inputs hashes to a digest recorded per pipeline revision. A
/// change of converted output for source that compiled before needs a deliberate bump of
/// `PIPELINE_REVISION` and a new row here (the table is append-only).
#[test]
fn converted_output_is_pinned_per_pipeline_revision() {
    use crate::identity::PIPELINE_REVISION;
    use crate::sha256::{Sha256, to_hex};
    const INPUTS: [&str; 6] = [
        "varying vec2 v_T; uniform sampler2D g_Texture0; uniform float g_F;\nvoid main() { vec3 c = texSample2D(g_Texture0, v_T); gl_FragColor = vec4(c * lerp(1.0, 2.0, saturate(g_F)), 1.0); }",
        "uniform float g_F;\nvoid main() { int k = floor(g_F * 3.0); float r = g_F % 2; bool b = g_F; gl_FragColor = vec4(float(k) + r + b); }",
        "attribute vec3 a_Position; uniform mat4 g_M; varying vec2 v_T; attribute vec2 a_T;\nvoid main() { a_T *= 2.0; v_T = a_T; gl_Position = mul(vec4(a_Position, 1.0), g_M); }",
        "uniform float g_X;\nfloat pool(float v[4], float s) { return v[0] * s; }\nuniform float g_L[4];\nvoid main() { gl_FragColor = vec4(pool(g_L, g_X) + smoothstep(0.9, 0.4, g_X)); }",
        "uniform mat3 g_B; uniform vec4 g_C;\nvoid main() { clip(g_C.x); gl_FragColor = vec4(inverse(g_B)[0], 1.0); }",
        "const float K = 2.0; uniform vec4 g_C; const float G = g_C.x * K;\nvoid main() { vec3 a = g_C; vec2 b = g_C.xyz + vec2(1.0); gl_FragColor = vec4(a, b.x * G); }",
    ];
    let mut hash = Sha256::new();
    for (i, src) in INPUTS.iter().enumerate() {
        let kind = if i == 2 { StageKind::Vertex } else { StageKind::Fragment };
        let out = convert_stage(kind, src).unwrap_or_else(|d| panic!("{d:?}")).text;
        hash.update(&(out.len() as u64).to_le_bytes());
        hash.update(out.as_bytes());
    }
    let digest = to_hex(&hash.finalize());
    const PINNED: &[(u32, &str)] = &[
        (1, "598de99a1dfb6a8fe0e1cf6098dc80652da65681d6a9c506da39ee3628871b9c"),
        (2, "598de99a1dfb6a8fe0e1cf6098dc80652da65681d6a9c506da39ee3628871b9c"),
    ];
    let row = PINNED.iter().find(|(r, _)| *r == PIPELINE_REVISION);
    match row {
        Some((_, d)) => assert_eq!(
            *d, digest,
            "the converter's output changed: bump PIPELINE_REVISION (identity.rs) and append the new digest {digest} to PINNED"
        ),
        None => panic!("no digest is pinned for pipeline revision {PIPELINE_REVISION}: append ({PIPELINE_REVISION}, \"{digest}\")"),
    }
}

// ----- macro-aliased samplers (R101) -----

#[test]
fn a_macro_alias_of_a_sampler_samples_that_texture() {
    let src = "uniform sampler2D g_Texture4; varying vec2 v_T;\n#define GRAD g_Texture4\nvoid main() { gl_FragColor = texSample2D(GRAD, v_T); }";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("texture(sampler2D(g_Texture4, _we_Sampler_g_Texture4), v_T)"), "{t}");
    legacy_frag(src);
}

#[test]
fn aliases_inside_helpers_chains_parentheses_and_redefinitions_resolve_at_the_call() {
    let src = "uniform sampler2D g_Texture1; uniform sampler2D g_Texture2; varying vec2 v_T;
#define A g_Texture1
#define B A
#define C (g_Texture2)
vec4 helper(vec2 uv) { return texSample2D(B, uv); }
void main() {
  vec4 a = helper(v_T);
  vec4 b = texSample2D(C, v_T);
  #undef B
  #define B g_Texture2
  vec4 c = texSample2D(B, v_T);
  gl_FragColor = a + b + c;
}";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("texture(sampler2D(g_Texture1, _we_Sampler_g_Texture1), uv)"), "{t}");
    assert!(count(&t, "sampler2D(g_Texture2, _we_Sampler_g_Texture2)") >= 2, "{t}");
    legacy_frag(src);
}

#[test]
fn an_alias_of_a_non_sampler_and_a_function_like_macro_are_not_samplers() {
    let t = frag("uniform float g_F; varying vec2 v_T;\n#define NOT g_F\nvoid main() { gl_FragColor = texSample2D(NOT, v_T); }");
    assert!(!t.contains("sampler2D(g_F"), "{t}");
    let t = frag("uniform sampler2D g_Texture0; varying vec2 v_T;\n#define F(x) g_Texture0\nvoid main() { gl_FragColor = texSample2D(F, v_T); }");
    assert!(t.contains("texture(F, v_T)"), "a function-like macro name without arguments is no alias: {t}");
}

// ----- macro-valued operands (R102) -----

#[test]
fn macro_constants_take_the_type_of_their_replacement() {
    let c = ok("#define K 2.0\n#define W 2\n#define U 3u\n", "vec3 v = K; vec3 p = pow(K, u3); int r = ui % W; uint s = uu % U; o = vec4(v + p, float(r) + float(s));");
    assert_eq!(c.local_type("v"), "vec3<f32>");
    let t = text("#define W 2\n", "int r = ui % W; o = vec4(float(r));");
    assert!(t.contains("ui % 2"), "an integer macro keeps the integer remainder: {t}");
    let t = text("#define K 2.5\n", "float r = uf % K; o = vec4(r);");
    assert!(t.contains("uf % 2.5"), "{t}");
}

#[test]
fn a_vector_macro_keeps_its_width_in_a_builtin_and_follows_the_usual_rules_elsewhere() {
    let c = ok("#define C u4.xyz\n", "vec3 f3 = i3; float s = uf; vec3 r = mix(C, f3, s); o = vec4(r, 1.0);");
    assert_eq!(c.local_type("r"), "vec3<f32>");
    let c = ok("#define W4 u4\n", "vec3 v = W4; o = vec4(v, 1.0);");
    assert_eq!(c.local_type("v"), "vec3<f32>");
}

#[test]
fn an_unresolved_macro_name_is_not_scalar_in_a_remainder_or_a_condition() {
    let t = text("", "float r = UNRESOLVED % 2.0; if (UNRESOLVED) { r = 1.0; } o = vec4(r);");
    assert!(t.contains("UNRESOLVED % 2.0") && t.contains("if (UNRESOLVED)"), "{t}");
}

// ----- non-square matrices (R10, R103) -----

#[test]
fn skinning_with_mat4x3_bones_compiles() {
    let c = ok(
        "",
        "vec3 p = i3; vec4 w = u4; uvec4 idx = uuv4;
mat4x3 sum = ub[idx.x] * w.x + ub[idx.y] * w.y + ub[idx.z] * w.z + ub[idx.w] * w.w;
vec3 a = mul(vec4(p, 1.0), sum);
vec4 b4 = vec4(0.0); b4.xyz = mul(vec4(p, 1.0), sum);
vec3 c = mul(vec4(p, 1.0), ub[idx.x] * w.x + ub[idx.y] * w.y);
mat3 n3 = CAST3X3(ub[idx.x]);
vec3 d = mul(p, CAST3X3(ub[idx.x]) * w.x + CAST3X3(ub[idx.y]) * w.y);
vec3 e = mul(vec4(p, 1.0), ub[idx.z]);
o = vec4(a + c + d + e, 1.0) + b4 + vec4(n3[0], 0.0);",
    );
    assert_eq!(c.local_type("a"), "vec3<f32>");
    assert_eq!(c.local_type("n3"), "mat3x3");
    assert_eq!(c.local_type("sum"), "mat4x3");
    assert_eq!(c.local_type("e"), "vec3<f32>");
}

// ----- the stand-in PerformLighting_V1 (R91) -----

#[test]
fn the_stand_in_lighting_function_serves_calls_of_eight_and_nine_arguments() {
    let call8 = "vec3 r = PerformLighting_V1(i3, u3, i3, u3, u3, u3, 0.5, 0.0);";
    let call9 = "vec3 q = PerformLighting_V1(i3, u3, i3, u3, u3, u3, 0.5, 0.0, 0.25);";
    let c = ok("", &format!("{call8} {call9} o = vec4(r + q, 1.0);"));
    assert_eq!(c.local_type("r"), "vec3<f32>");
    let v = legacy_vert("attribute vec3 a_P;\nvoid main() { vec3 r = PerformLighting_V1(a_P, a_P, a_P, a_P, a_P, a_P, 0.5, 0.0); gl_Position = vec4(r, 1.0); }");
    assert!(v.has_function("PerformLighting_V1"));
}

#[test]
fn the_stand_in_is_emitted_only_when_called_and_never_beside_a_definition() {
    assert!(!text("", "o = vec4(1.0);").contains("PerformLighting_V1"));
    let t = text("vec3 PerformLighting_V1(vec3 a) { return a; }", "vec3 r = PerformLighting_V1(u3); o = vec4(r, 1.0);");
    assert_eq!(count(&t, "vec3 PerformLighting_V1("), 1, "{t}");
    // with a user function of another arity the call is left to naga
    let t = text("vec3 PerformLighting_V1(vec3 a) { return a; }", "vec3 r = PerformLighting_V1(u3, u3, u3, u3, u3, u3, 0.5, 0.0); o = vec4(r, 1.0);");
    assert_eq!(count(&t, "vec3 PerformLighting_V1("), 1, "{t}");
    assert!(compile_glsl(StageKind::Fragment, &t).is_err());
}

// ----- widened uniform array reads through an alias macro (R104) -----

#[test]
fn a_macro_alias_of_an_array_defined_in_main_reads_one_element() {
    let src = "uniform float g_AudioSpectrum8Right[8]; uniform float g_AudioSpectrum32Right[32]; uniform sampler2D g_Texture0;
void main() {
  #define u_Bins g_AudioSpectrum32Right
  float e = u_Bins[3];
  #undef u_Bins
  #define u_Bins g_AudioSpectrum8Right
  float f = u_Bins[2];
  gl_FragColor = vec4(e + f);
}";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("g_AudioSpectrum32Right[3]") && t.contains("g_AudioSpectrum8Right[2]"), "{t}");
    legacy_frag(src);
}

// ----- 3D sampling (R105) -----

#[test]
fn a_3d_texture_is_sampled_with_a_three_component_coordinate() {
    let c = legacy_frag("uniform sampler3D lut; varying vec3 v_3; varying vec4 v_4;\nvoid main() { vec3 a = texSample3D(lut, v_3); vec3 b = texSample3D(lut, v_4); gl_FragColor = vec4(a + b, 1.0); }");
    assert_eq!(c.local_type("a"), "vec3<f32>");
    let t = legacy_text(StageKind::Fragment, "uniform sampler3D lut; varying vec4 v_4;\nvoid main() { vec3 b = texSample3D(lut, v_4); gl_FragColor = vec4(b, 1.0); }");
    assert!(t.contains("sampler3D(lut, _we_Sampler_lut)") && t.contains("v_4.xyz"), "{t}");
}

#[test]
fn a_two_component_coordinate_for_a_3d_texture_is_refused() {
    let d = convert_err(StageKind::Fragment, "uniform sampler3D lut; varying vec2 v_2;\nvoid main() { gl_FragColor = texSample3D(lut, v_2); }");
    assert!(d.iter().any(|m| m.contains("sampler3D")), "{d:?}");
}

// ----- reversed smoothstep edges (R106) -----

#[test]
fn smoothstep_keeps_the_backends_own_function_because_it_already_has_the_direct3d_meaning() {
    // A probe on the Metal backend (tests/probes/smoothstep_reversed.swift, run by
    // `WM_SHADER_GPU_PROBES=1 cargo test --test gpu_probe`) shows `smoothstep(0.9, 0.4, x)` already
    // returns the saturated-ratio Hermite, so no call is rewritten (R106); the shape rules of R28 still apply.
    let t = text("", "float a = smoothstep(0.9, 0.4, uf); float b = smoothstep(0.1, 0.9, uf); vec3 c = smoothstep(0.9, 0.4, u3); vec3 d = smoothstep(2, 5, u3); o = vec4(a + b + c.x + d.x);");
    assert!(t.contains("smoothstep(0.9, 0.4, uf)") && t.contains("smoothstep(0.1, 0.9, uf)"), "{t}");
    assert!(t.contains("smoothstep(0.9, 0.4, u3)") && t.contains("smoothstep(2.0, 5.0, u3)"), "{t}");
    assert!(!t.contains("_wm_smoothstep"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn smoothstep_with_scalar_edges_and_a_vector_follows_the_shape_rules() {
    let c = ok("", "vec2 a = smoothstep(0.9, 0.4, i2); vec3 b = smoothstep(u3, i3, i3); float c1 = smoothstep(u4.x, 0.5, uf); o = vec4(a, b.x, c1);");
    assert_eq!(c.local_type("a"), "vec2<f32>");
    assert_eq!(c.local_type("b"), "vec3<f32>");
}
