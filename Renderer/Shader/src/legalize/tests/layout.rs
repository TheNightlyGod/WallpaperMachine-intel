// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Resource layout of a program: the uniform block, descriptor bindings, split textures
//! (spec C2 section 8, items 5 to 10 and 29).

use super::support::*;
use crate::dialect::tests::support::{Compiled, compile_glsl};
use crate::legalize::{LegalizeError, ProgramInput, legalize};
use crate::request::StageKind;
use crate::uniforms::UniformError;

const PASS_V: &str = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }";
const PASS_F: &str = "void main() { gl_FragColor = CAST4(1.0); }";

fn block_lines(text: &str) -> Vec<String> {
    let start = text.find("uniform GlobalUniforms {").expect("a block");
    let rest = &text[start..];
    rest.lines().skip(1).take_while(|l| !l.starts_with('}')).map(|l| l.trim().to_string()).collect()
}

/// The member offsets naga read from the generated block.
fn naga_offsets(c: &Compiled) -> Vec<(String, u32)> {
    for (_, ty) in c.module.types.iter() {
        if let naga::TypeInner::Struct { members, .. } = &ty.inner
            && ty.name.as_deref() == Some("GlobalUniforms")
        {
            return members.iter().map(|m| (m.name.clone().unwrap_or_default(), m.offset)).collect();
        }
    }
    panic!("naga has no GlobalUniforms struct");
}

fn legalize_err(v: &str, f: &str) -> LegalizeError {
    program_err(v, f)
}

#[test]
fn members_of_both_stages_share_one_block_in_first_appearance_order() {
    let v = "uniform mat4 g_Mvp; uniform vec3 g_Eye; attribute vec3 a_Position;\nvoid main() { gl_Position = mul(vec4(a_Position + g_Eye, 1.0), g_Mvp); }";
    let f = "uniform float g_Alpha; uniform vec3 g_Eye; uniform vec4 g_Tint;\nvoid main() { gl_FragColor = g_Tint * g_Alpha + vec4(g_Eye, 0.0); }";
    let p = program(v, f);
    let (vt, ft) = (&p.vertex.as_ref().unwrap().text, &p.fragment.as_ref().unwrap().text);
    let want = ["mat4 g_Mvp;", "vec3 g_Eye;", "float g_Alpha;", "vec4 g_Tint;"];
    assert_eq!(block_lines(vt), want);
    assert_eq!(block_lines(ft), want, "the same list, in the same order, in the other stage");
    let block = p.layout.block.as_ref().unwrap();
    assert_eq!(block.members.iter().map(|m| m.name.as_str()).collect::<Vec<_>>(), ["g_Mvp", "g_Eye", "g_Alpha", "g_Tint"]);
}

#[test]
fn the_block_offsets_are_std140_and_naga_agrees() {
    let v = "uniform mat4 a; uniform vec3 b; uniform float c; uniform vec2 d; uniform float e[3]; uniform mat4x3 f[2]; uniform mat3 g; uniform vec4 h; uniform vec3 i; uniform vec2 j[2]; uniform int k[2]; uniform float after;\nvoid main() { gl_Position = CAST4(a[0][0] + b.x + c + d.x + e[1] + f[1][0].x + g[0][0] + h.x + i.x + j[1].x + float(k[1]) + after); }";
    let both = compile_program(v, PASS_F);
    let layout = both.program.layout.block.as_ref().unwrap().layout().unwrap();
    let naga = naga_offsets(&both.vertex);
    assert_eq!(layout.members.len(), naga.len());
    for (m, (name, offset)) in layout.members.iter().zip(&naga) {
        assert_eq!((&m.name, m.offset), (name, *offset), "{name}");
    }
    let off = |n: &str| layout.members.iter().find(|m| m.name == n).unwrap().offset;
    assert_eq!((off("a"), off("b"), off("c"), off("d")), (0, 64, 76, 80), "a scalar fits in the last four bytes of a vec3");
    assert_eq!(off("e"), 96);
    assert_eq!(off("g") % 16, 0);
    assert_eq!(layout.size % 16, 0);
}

#[test]
fn a_narrower_stage_reads_the_leading_components_of_a_shared_member() {
    let v = "uniform float u_Size; attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position * u_Size, 1.0); }";
    let f = "uniform vec2 u_Size;\nvoid main() { gl_FragColor = vec4(u_Size, 0.0, 1.0); }";
    let both = compile_program(v, f);
    let (vt, ft) = (&both.program.vertex.as_ref().unwrap().text, &both.program.fragment.as_ref().unwrap().text);
    assert_eq!(block_lines(vt), ["vec2 u_Size;"], "the wider type wins in both stages");
    assert_eq!(block_lines(ft), ["vec2 u_Size;"]);
    assert!(vt.contains("(u_Size.x)"), "{vt}");
    assert!(!ft.contains("u_Size.x") && !ft.contains("u_Size.y"), "the wide stage reads it as written: {ft}");
}

#[test]
fn a_g_name_with_two_widths_or_conflicting_arrays_or_structs_fail() {
    let e = legalize_err("uniform float g_Size;\nvoid main() { gl_Position = CAST4(g_Size); }", "uniform vec2 g_Size;\nvoid main() { gl_FragColor = vec4(g_Size, 0.0, 1.0); }");
    assert!(e.message().contains("conflicting GlobalUniforms member declarations"), "{e}");
    assert!(e.is_invalid_request());
    let e = legalize_err("uniform float u_A[3];\nvoid main() { gl_Position = CAST4(u_A[0]); }", "uniform float u_A[4];\nvoid main() { gl_FragColor = CAST4(u_A[0]); }");
    assert!(e.message().contains("conflicting GlobalUniforms member declarations"), "{e}");
    let e = legalize_err("uniform float u_A[3];\nvoid main() { gl_Position = CAST4(u_A[0]); }", "uniform float u_A;\nvoid main() { gl_FragColor = CAST4(u_A); }");
    assert!(e.message().contains("conflicting GlobalUniforms member declarations"), "{e}");
    let e = legalize_err("uniform float u_A;\nvoid main() { gl_Position = CAST4(u_A); }", "uniform int u_A;\nvoid main() { gl_FragColor = CAST4(float(u_A)); }");
    assert!(e.message().contains("conflicting GlobalUniforms member declarations"), "int against float is no width difference: {e}");
    let e = legalize_err("struct Light { vec3 c; }; uniform Light u_L;\nvoid main() { gl_Position = vec4(u_L.c, 1.0); }", PASS_F);
    assert_eq!(e.message(), "unsupported GlobalUniforms member type `Light`");
}

#[test]
fn a_float1_spelling_is_the_same_type_as_float_across_stages() {
    let both = compile_program(
        "uniform float1 g_X;\nvoid main() { gl_Position = CAST4(g_X); }",
        "uniform float g_X;\nvoid main() { gl_FragColor = CAST4(g_X); }",
    );
    assert_eq!(block_lines(&both.program.vertex.as_ref().unwrap().text), ["float g_X;"]);
}

#[test]
fn array_bounds_come_from_literals_macros_and_combos() {
    let src = "#define COUNT 3\n#define PAD 04\nuniform float a[COUNT]; uniform vec4 b[ 2 ]; uniform vec4 c[PAD];\n#define COUNT 5\nuniform float d[COUNT];\nvoid main() { gl_Position = CAST4(a[0] + b[1].x + c[3].x + d[4]); }";
    let both = compile_program(src, PASS_F);
    let m = both.program.layout.block.as_ref().unwrap();
    let counts: Vec<_> = m.members.iter().map(|m| (m.name.as_str(), m.array)).collect();
    assert_eq!(counts, [("a", Some(3)), ("b", Some(2)), ("c", Some(4)), ("d", Some(5))], "a macro redefined later does not change an earlier bound");
    // `[04]` and `[4]` declare one member
    let both = compile_program(
        "uniform vec4 g_X[04];\nvoid main() { gl_Position = g_X[1]; }",
        "uniform vec4 g_X[4];\nvoid main() { gl_FragColor = g_X[1]; }",
    );
    assert_eq!(block_lines(&both.program.vertex.as_ref().unwrap().text), ["vec4 g_X[4];"]);
}

#[test]
fn a_bound_that_is_not_a_literal_fails_with_the_message_of_its_kind() {
    let e = legalize_err("uniform float a[2 * 4];\nvoid main() { gl_Position = CAST4(a[0]); }", PASS_F);
    assert!(e.message().contains("unresolved GlobalUniforms member array suffix") && e.message().contains("vertex"), "{e}");
    let e = legalize_err("#define N 4\n#undef N\nuniform float a[N];\nvoid main() { gl_Position = CAST4(a[0]); }", PASS_F);
    assert!(e.message().contains("unresolved GlobalUniforms member array suffix") && e.message().contains("[N]"), "{e}");
    let e = legalize_err("varying float v[N + 1];\nvoid main() { v[0] = 1.0; gl_Position = CAST4(1.0); }", PASS_F);
    assert!(e.message().contains("unsupported stage-interface array bound") && e.message().contains("N + 1"), "{e}");
    assert!(e.is_invalid_request());
    let e = legalize_err(PASS_V, "#define N 3\nvarying vec2 v[M];\nvoid main() { gl_FragColor = vec4(v[0], 0.0, 1.0); }");
    assert!(e.message().contains("unsupported stage-interface array bound"), "{e}");
    let e = legalize_err("varying float v[0];\nvoid main() { gl_Position = CAST4(1.0); }", PASS_F);
    assert!(e.message().contains("unsupported stage-interface array bound"), "zero is no bound: {e}");
}

#[test]
fn interface_bounds_follow_macro_definitions_in_text_order() {
    let src = "#define N 2\nvarying vec2 a[N];\n#undef N\n#define N 3\nvarying vec2 b[N];\nvoid main() { a[0] = CAST2(0.0); b[2] = CAST2(1.0); gl_Position = CAST4(1.0); }";
    let p = program(src, "varying vec2 b[3]; varying vec2 a[2];\nvoid main() { gl_FragColor = vec4(a[1] + b[2], 0.0, 1.0); }");
    let v = &p.vertex.as_ref().unwrap().text;
    assert!(v.contains("out vec2 a[2];") && v.contains("out vec2 b[3];"), "{v}");
    let _ = compile_program(src, "varying vec2 b[3]; varying vec2 a[2];\nvoid main() { gl_FragColor = vec4(a[1] + b[2], 0.0, 1.0); }");
}

#[test]
fn narrow_arrays_are_widened_and_reads_select_the_authors_components() {
    let src = "uniform float g_F[5]; uniform vec2 g_V2[3]; uniform vec3 g_V3[2]; uniform vec4 g_V4[2]; uniform float after;\nvoid main() { gl_Position = vec4(g_F[2], g_V2[1].y, g_V3[1].x, g_V4[1].w) + vec4(g_V2[0], g_V3[0].yz) + CAST4(after); }";
    let both = compile_program(src, PASS_F);
    let t = &both.program.vertex.as_ref().unwrap().text;
    assert_eq!(block_lines(t), ["vec4 g_F[5];", "vec4 g_V2[3];", "vec4 g_V3[2];", "vec4 g_V4[2];", "float after;"]);
    assert!(t.contains("g_F[2].x"), "{t}");
    assert!(t.contains("g_V2[1].y") && t.contains("g_V2[0].xy"), "a read of a vec2 element selects two components: {t}");
    assert!(t.contains("g_V3[1].x") && t.contains("g_V3[0].yz"), "an explicit selection is left alone: {t}");
    assert!(!t.contains("g_V4[1].w.x"), "{t}");
    assert!(both.vertex.msl.contains("metal::float4 inner[5]"), "the Metal block has four-component elements:\n{}", both.vertex.msl);
    // the offsets naga reports are the ones the layout reports
    let layout = both.program.layout.block.as_ref().unwrap().layout().unwrap();
    let naga = naga_offsets(&both.vertex);
    for (m, (name, offset)) in layout.members.iter().zip(&naga) {
        assert_eq!((&m.name, m.offset), (name, *offset));
    }
}

#[test]
fn a_float1_array_is_widened_like_a_float_array() {
    let both = compile_vert_with_planes("uniform float1 g_Taps[4]; uniform float g_After;\nvoid main() { gl_Position = vec4(g_Taps[1], g_After, 0.0, 1.0); }");
    let t = &both.program.vertex.as_ref().unwrap().text;
    assert_eq!(block_lines(t), ["vec4 g_Taps[4];", "float g_After;"]);
    assert!(t.contains("g_Taps[1].x"));
    let layout = both.program.layout.block.as_ref().unwrap().layout().unwrap();
    assert_eq!(layout.members[1].offset, 64, "the member after the array sits at the sixteen-byte-stride offset");
    assert_eq!(naga_offsets(&both.vertex)[1].1, 64);
}

fn compile_vert_with_planes(v: &str) -> super::support::BothCompiled {
    compile_program(v, PASS_F)
}

#[test]
fn a_second_subscript_of_a_scalar_element_selects_the_component() {
    let t = vert("uniform float g_Bands[32];\nvoid main() { int j = 9; gl_Position = vec4(g_Bands[(j + 1) / 8][j & 7]); }");
    assert!(t.contains("g_Bands[(j + 1) / 8].x"), "{t}");
    assert!(!t.contains("& 7"), "the index expression of the second subscript is discarded: {t}");
    let _ = compile_vert("uniform float g_Bands[32];\nvoid main() { int j = 9; gl_Position = vec4(g_Bands[(j + 1) / 8][j & 7]); }");
}

#[test]
fn a_macro_alias_of_a_widened_array_reads_through_its_target() {
    let src = "uniform float g_S16[16]; uniform float g_S32[32];\n#define u_Bands g_S16\nvoid main() {\n#define u_Inner g_S32\n gl_Position = CAST4(u_Bands[3] + u_Inner[4]); }";
    let t = vert(src);
    assert!(t.contains("g_S16[3].x") && t.contains("g_S32[4].x"), "{t}");
    let _ = compile_vert(src);
}

#[test]
fn a_local_array_copied_from_a_widened_array_is_an_array_of_floats() {
    let src = "uniform float g_Audio[8];\nfloat sum(float b[8]) { float s = 0.0; for (int i = 0; i < 8; i++) s += b[i]; return s; }\nvoid main() { float bins[8] = g_Audio; gl_Position = CAST4(sum(g_Audio) + bins[2]); }";
    let t = vert(src);
    assert!(t.contains("float bins[8] = float[8](g_Audio[0].x"), "{t}");
    assert!(t.contains("g_Audio[i].x"), "reads through the specialised parameter select too: {t}");
    let _ = compile_vert(src);
}

#[test]
fn array_parameter_specialisation_carries_the_selector() {
    let src = "uniform float g_Weights[4]; uniform float g_Lo; uniform float g_Hi;\nfloat mix2(float w[4], float a, float b) { return w[1] + a - b; }\nvoid main() { gl_Position = CAST4(mix2(g_Weights, g_Lo, g_Hi)); }";
    let t = vert(src);
    assert!(t.contains("g_Weights[1].x + a - b"), "{t}");
    assert!(t.contains("(g_Lo, g_Hi)"), "the array argument is gone: {t}");
    assert!(t.contains("vec4 g_Weights[4];"), "{t}");
    let _ = compile_vert(src);
}

#[test]
fn integer_arrays_are_widened_to_the_matching_vector() {
    let src = "uniform uint g_Slots[3]; uniform int2 g_Pair[2]; uniform int g_Ints[2]; uniform float g_After; uniform vec4 g_Keep[2]; uniform mat4 g_Mats[2];\nvoid main() { uint i = 1u; gl_Position = CAST4(float(g_Slots[i]) + float(g_Pair[1].y) + float(g_Ints[1]) + g_After + g_Keep[1].x + g_Mats[1][0][0]); }";
    let both = compile_program(src, PASS_F);
    let t = &both.program.vertex.as_ref().unwrap().text;
    assert_eq!(
        block_lines(t),
        ["uvec4 g_Slots[3];", "ivec4 g_Pair[2];", "ivec4 g_Ints[2];", "float g_After;", "vec4 g_Keep[2];", "mat4 g_Mats[2];"],
        "arrays of vec4 and of matrices are not widened"
    );
    assert!(t.contains("g_Slots[i].x") && t.contains("g_Pair[1].y") && t.contains("g_Ints[1].x"), "{t}");
    assert!(both.vertex.msl.contains("metal::uint4 inner[3]"), "{}", both.vertex.msl);
    let layout = both.program.layout.block.as_ref().unwrap().layout().unwrap();
    let naga = naga_offsets(&both.vertex);
    for (m, (name, offset)) in layout.members.iter().zip(&naga) {
        assert_eq!((&m.name, m.offset), (name, *offset), "{name}");
    }
    assert_eq!(layout.members.iter().find(|m| m.name == "g_After").unwrap().offset, 3 * 16 + 2 * 16 + 2 * 16);
}

#[test]
fn a_narrow_uint_array_stays_tight_on_metal_without_the_widening() {
    // Documents why R87 exists: naga gives a plain `uint[3]` a four-byte stride in Metal.
    let glsl = "#version 450\nlayout(std140, set = 0, binding = 0) uniform GlobalUniforms { uint g[3]; float after; };\nlayout(location = 0) out vec4 o;\nvoid main() { o = vec4(float(g[1]), after, 0.0, 0.0); }\n";
    let c = compile_glsl(StageKind::Fragment, glsl).unwrap();
    assert!(c.msl.contains("uint inner[3]"), "{}", c.msl);
}

#[test]
fn booleans_are_stored_as_unsigned_integers_and_read_back_as_booleans() {
    let src = "uniform bool g_On; uniform bool3 g_On3;\nvoid main() { gl_FragColor = g_On ? CAST4(float(g_On3.y)) : CAST4(0.0); }";
    let t = frag(src);
    assert_eq!(block_lines(&t), ["uint g_On;", "uvec3 g_On3;"]);
    assert!(t.contains("g_On != 0u") && t.contains("notEqual(g_On3, uvec3(0u))"), "{t}");
    let _ = compile_frag(src);
    let e = stage_err(StageKind::Fragment, "uniform bool g_Flags[2];\nvoid main() { gl_FragColor = CAST4(1.0); }");
    assert!(e.message().contains("g_Flags") && e.is_invalid_request(), "{e}");
}

#[test]
fn a_two_row_matrix_is_stored_with_four_rows_and_read_back_as_the_authors_matrix() {
    let src = "uniform mat2 g_Rot;\nuniform mat3x2 g_Aff;\nuniform mat4x2 g_Many[3];\nuniform mat2x2 g_Pair[2];\nuniform float g_After;\n\
               void main() {\n\
                 mat2 r = g_Rot;\n\
                 vec2 c = g_Rot[1];\n\
                 float e = g_Rot[1][0];\n\
                 vec2 p = mul(CAST3(1.0), g_Aff);\n\
                 mat4x2 m = g_Many[1];\n\
                 vec2 d = g_Many[2][3];\n\
                 mat2 q = g_Pair[1] * g_Pair[0];\n\
                 mat2 all[2] = g_Pair;\n\
                 int n = g_Many.length();\n\
                 gl_FragColor = vec4(r[0] + c + p + m[1] + d + q[0] + all[1][1], e + g_After, float(n));\n\
               }";
    let both = compile_program(PASS_V, src);
    let text = &both.program.fragment.as_ref().unwrap().text;
    let lines = block_lines(text);
    assert_eq!(
        lines,
        ["mat2x4 g_Rot;", "mat3x4 g_Aff;", "mat4x4 g_Many[3];", "mat2x4 g_Pair[2];", "float g_After;"]
    );
    assert!(text.contains("mat2(g_Rot)") && text.contains("mat4x2(g_Many[1])") && text.contains("mat2[2]("), "{text}");
    // Metal agrees with the std140 offsets of the model: 32, 48, 192 and 64 bytes before g_After.
    let offsets = naga_offsets(&both.fragment);
    assert_eq!(offsets.last().map(|(n, o)| (n.as_str(), *o)), Some(("g_After", 32 + 48 + 192 + 64)));
}

// ----- descriptor bindings -----

fn bindings_of(text: &str) -> Vec<(String, u32)> {
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("layout(") {
            let (inside, after) = rest.split_once(')').unwrap();
            if let Some(b) = inside.split(',').find_map(|p| p.trim().strip_prefix("binding = ")) {
                let name = after.trim().trim_end_matches(';').trim_end_matches('{').split_whitespace().last().unwrap().to_string();
                out.push((name, b.parse().unwrap()));
            }
        }
    }
    out
}

fn binding(text: &str, name: &str) -> u32 {
    bindings_of(text).into_iter().find(|(n, _)| n == name).map(|(_, b)| b).unwrap_or_else(|| panic!("no binding for {name} in\n{text}"))
}

#[test]
fn encoded_textures_take_their_slot_and_the_rest_take_the_lowest_free_binding() {
    // reserved {0, 2}; the block goes to 1; samplers and the other texture follow in R28's order
    let f = "uniform sampler2D g_Texture0; uniform sampler2D g_Texture2; uniform sampler2D u_Dist; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, CAST2(0.0)) + texSample2D(g_Texture2, CAST2(0.0)) + texSample2D(u_Dist, CAST2(g_X)); }";
    let p = program(PASS_V, f);
    let t = &p.fragment.as_ref().unwrap().text;
    assert_eq!(binding(t, "GlobalUniforms"), 1);
    assert_eq!((binding(t, "g_Texture0"), binding(t, "g_Texture2")), (0, 2));
    assert_eq!(binding(t, "_we_Sampler_g_Texture0"), 3);
    assert_eq!(binding(t, "_we_Sampler_g_Texture2"), 4);
    assert_eq!((binding(t, "u_Dist"), binding(t, "_we_Sampler_u_Dist")), (5, 6));
    let _ = compile_program(PASS_V, f);
}

#[test]
fn the_worked_example_of_a_small_program() {
    let v = "uniform mat4 g_ModelViewProjectionMatrix; uniform vec2 g_Scroll; attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec4 v_Tint;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_Tint = vec4(a_TexCoord + g_Scroll, 0.0, 1.0); }";
    let f = "uniform sampler2D g_Texture0; uniform float g_Alpha; varying vec4 v_Tint;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tint.xy) * v_Tint * g_Alpha; }";
    let p = program(v, f);
    let l = &p.layout;
    let block = l.block.as_ref().unwrap();
    assert_eq!(block.binding, 1);
    let m = block.layout().unwrap();
    assert_eq!(m.members.iter().map(|m| (m.name.as_str(), m.offset)).collect::<Vec<_>>(), [("g_ModelViewProjectionMatrix", 0), ("g_Scroll", 64), ("g_Alpha", 72)]);
    assert_eq!(m.size, 80);
    let tex = &l.textures[0];
    assert_eq!((tex.name.as_str(), tex.texture_binding, tex.sampler_binding), ("g_Texture0", 0, 2));
    assert!(!tex.in_vertex && tex.in_fragment);
    let inputs: Vec<_> = l.vertex_inputs.iter().map(|i| (i.name.as_str(), i.location)).collect();
    assert_eq!(inputs, [("a_Position", 0), ("a_TexCoord", 1)]);
    assert_eq!((l.varyings[0].name.as_str(), l.varyings[0].location), ("v_Tint", 0));
    assert!(l.varyings[0].in_vertex && l.varyings[0].in_fragment);
}

#[test]
fn an_explicit_block_binding_is_honoured_and_reserved() {
    let v = "layout(binding = 5) uniform float g_A; uniform vec2 g_B;\nvoid main() { gl_Position = vec4(g_A, g_B, 1.0); }";
    let f = "layout(binding = 5) uniform float g_A; uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, CAST2(g_A)); }";
    let p = program(v, f);
    assert_eq!(p.layout.block.as_ref().unwrap().binding, 5);
    assert_eq!(binding(&p.fragment.as_ref().unwrap().text, "_we_Sampler_g_Texture0"), 1, "5 is taken, 0 is the texture: the sampler gets 1");
    let e = legalize_err(
        "layout(binding = 5) uniform float g_A;\nvoid main() { gl_Position = CAST4(g_A); }",
        "layout(binding = 6) uniform float g_A;\nvoid main() { gl_FragColor = CAST4(g_A); }",
    );
    assert!(e.message().contains("conflicting explicit GlobalUniforms descriptor bindings"), "{e}");
    // an explicit binding that another resource already holds
    let e = legalize_err(
        "layout(binding = 0) uniform float g_A;\nvoid main() { gl_Position = CAST4(g_A); }",
        "uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, CAST2(0.0)); }",
    );
    assert!(e.message().contains("binding 0") && e.is_invalid_request(), "{e}");
}

#[test]
fn a_kept_sampler_reserves_its_set_zero_binding_and_a_set_one_resource_reserves_nothing() {
    let f = "layout(set = 0, binding = 0) uniform samplerCube g_Cube; uniform sampler2D g_Texture1; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, CAST2(g_X)); }";
    let (stage, layout) = crate::legalize::legalize_stage(StageKind::Fragment, f).unwrap();
    assert!(stage.text.contains("uniform samplerCube g_Cube;"), "left exactly as written: {}", stage.text);
    assert!(!block_lines(&stage.text).iter().any(|l| l.contains("g_Cube")), "never in the block");
    assert_eq!(layout.kept[0].name, "g_Cube");
    assert_eq!(binding(&stage.text, "GlobalUniforms"), 2, "0 is the cube, 1 is g_Texture1");
    let f1 = "layout(set = 1, binding = 0) uniform samplerCube g_Cube; uniform sampler2D g_Texture1; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, CAST2(g_X)); }";
    let (stage, _) = crate::legalize::legalize_stage(StageKind::Fragment, f1).unwrap();
    assert_eq!(binding(&stage.text, "GlobalUniforms"), 0, "a set-one resource reserves nothing in set zero");
    // two resources claiming one binding
    let e = legalize_err(
        "layout(binding = 0) uniform samplerCube g_Texture0;\nvoid main() { gl_Position = CAST4(1.0); }",
        "uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, CAST2(0.0)); }",
    );
    assert!(e.message().contains("binding 0") && e.message().contains("incompatible"), "{e}");
}

#[test]
fn the_first_layout_qualifier_that_declares_a_binding_wins() {
    let f = "layout(row_major) layout(binding = 9) uniform samplerCube g_C; uniform sampler2D g_Texture0; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, CAST2(g_X)); }";
    let (_, layout) = crate::legalize::legalize_stage(StageKind::Fragment, f).unwrap();
    assert_eq!(layout.kept[0].binding, Some(9));
}

#[test]
fn the_same_texture_in_both_stages_shares_its_bindings() {
    let v = "uniform sampler2D g_Texture1; uniform sampler2D u_Noise; attribute vec2 a;\nvoid main() { gl_Position = texSample2DLod(g_Texture1, a, 0.0) + texSample2DLod(u_Noise, a, 0.0); }";
    let f = "uniform sampler2D u_Noise; uniform sampler2D g_Texture1; uniform float g_K;\nvoid main() { gl_FragColor = texSample2D(u_Noise, CAST2(g_K)) + texSample2D(g_Texture1, CAST2(g_K)); }";
    let p = program(v, f);
    let (vt, ft) = (&p.vertex.as_ref().unwrap().text, &p.fragment.as_ref().unwrap().text);
    for name in ["g_Texture1", "u_Noise", "_we_Sampler_g_Texture1", "_we_Sampler_u_Noise", "GlobalUniforms"] {
        assert_eq!(binding(vt, name), binding(ft, name), "{name}");
    }
    let all: Vec<u32> = bindings_of(vt).into_iter().map(|(_, b)| b).collect();
    let mut dedup = all.clone();
    dedup.sort();
    dedup.dedup();
    assert_eq!(all.len(), dedup.len(), "every resource has its own binding: {all:?}");
    assert_eq!(p.layout.textures.len(), 2);
    assert!(p.layout.textures.iter().all(|t| t.in_vertex && t.in_fragment));
    let _ = compile_program(v, f);
}

#[test]
fn a_texture_name_with_a_leading_zero_is_not_canonical() {
    let e = stage_err(StageKind::Fragment, "uniform sampler2D g_Texture007;\nvoid main() { gl_FragColor = texSample2D(g_Texture007, CAST2(0.0)); }");
    assert!(e.message().contains("g_Texture007") && e.message().contains("canonical"), "{e}");
    assert!(!e.is_invalid_request() && !e.is_cross_stage());
    let d = &e.diagnostics()[0];
    assert_eq!(d.stage, Some(StageKind::Fragment));
    assert!(d.span.is_some());
}

#[test]
fn standalone_numbering_puts_the_block_first_and_the_samplers_last() {
    let f = "uniform sampler2D g_Texture1; uniform sampler2D g_Texture4; uniform sampler2D u_Noise; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, CAST2(g_X)) + texSample2D(g_Texture4, CAST2(0.0)) + texSample2D(u_Noise, CAST2(0.0)); }";
    let t = frag(f);
    assert_eq!((binding(&t, "g_Texture1"), binding(&t, "g_Texture4"), binding(&t, "u_Noise")), (1, 4, 2));
    assert_eq!(binding(&t, "GlobalUniforms"), 0);
    assert_eq!(
        (binding(&t, "_we_Sampler_g_Texture1"), binding(&t, "_we_Sampler_g_Texture4"), binding(&t, "_we_Sampler_u_Noise")),
        (3, 5, 6)
    );
    // the program numbering of the same stage differs for the non-encoded texture
    let p = program(PASS_V, f);
    let pt = &p.fragment.as_ref().unwrap().text;
    assert_eq!(binding(pt, "_we_Sampler_g_Texture1"), 2);
    assert_eq!((binding(pt, "u_Noise"), binding(pt, "_we_Sampler_u_Noise")), (5, 6));
}

#[test]
fn thirteen_textures_and_the_block_compile_to_metal() {
    let mut f = String::new();
    let mut body = String::from("vec4 c = CAST4(0.0);\n");
    for n in 0..13 {
        f.push_str(&format!("uniform sampler2D g_Texture{n};\n"));
        body.push_str(&format!("c += texSample2D(g_Texture{n}, CAST2(g_X));\n"));
    }
    f.push_str(&format!("uniform float g_X;\nvoid main() {{ {body} gl_FragColor = c; }}"));
    let both = compile_program(PASS_V, &f);
    let layout = &both.program.layout;
    assert_eq!(layout.textures.len(), 13);
    // the backend ranks each namespace of a stage from 0 (D R46), so the samplers take slots 0 to 12
    let mut resources = vec![crate::binding::StageResource {
        name: "GlobalUniforms".into(),
        set: 0,
        binding: layout.block.as_ref().map(|b| b.binding),
        kind: crate::binding::SlotKind::Buffer,
    }];
    for t in &layout.textures {
        resources.push(crate::binding::StageResource { name: t.name.clone(), set: 0, binding: Some(t.texture_binding), kind: crate::binding::SlotKind::Texture });
        resources.push(crate::binding::StageResource { name: t.sampler_name.clone(), set: 0, binding: Some(t.sampler_binding), kind: crate::binding::SlotKind::Sampler });
    }
    let map = crate::binding::assign_stage_slots(&resources).unwrap();
    let mut sampler_slots: Vec<u32> = map.iter().filter(|b| b.slot_kind == crate::binding::SlotKind::Sampler).map(|b| b.slot).collect();
    sampler_slots.sort();
    assert_eq!(sampler_slots, (0..13).collect::<Vec<_>>());
}

#[test]
fn the_skeleton_has_the_generated_declarations_before_the_authors_code() {
    let f = "precision mediump float;\nuniform sampler2D g_Texture0; uniform float g_A; varying vec2 v_T; const float K = 2.0;\nfloat helper(float x) { return x * K; }\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T) * helper(g_A); }";
    let t = frag(f);
    assert!(t.starts_with("#version 450\nprecision highp float;\n"), "{t}");
    let at = |s: &str| t.find(s).unwrap_or_else(|| panic!("{s} missing in\n{t}"));
    let order = [
        at("uniform texture2D g_Texture0;"),
        at("uniform sampler _we_Sampler_g_Texture0;"),
        at("uniform GlobalUniforms {"),
        at("in vec2 v_T;"),
        at("out vec4 _we_FragColor;"),
        at("precision mediump float;"),
        at("float helper("),
    ];
    assert!(order.windows(2).all(|w| w[0] < w[1]), "{order:?}\n{t}");
    assert!(!t.contains("uniform sampler2D g_Texture0;") && !t.contains("uniform float g_A;"), "the originals are gone: {t}");
}

#[test]
fn a_stage_without_declarations_is_the_header_plus_the_authors_text() {
    let t = vert("void main() { gl_Position = CAST4(1.0); }");
    assert_eq!(t, "#version 450\nprecision highp float;\n\nvoid main() {\n  gl_Position = vec4(1.0);\n}\n");
}

#[test]
fn engine_visible_names_are_the_only_generated_resources() {
    let v = "uniform mat4 g_Mvp; attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_T;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_Mvp); v_T = a_TexCoord; }";
    let f = "uniform sampler2D g_Texture0; uniform sampler2D g_Texture3; uniform float g_A; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T) + texSample2D(g_Texture3, v_T) * g_A; }";
    let both = compile_program(v, f);
    for stage in [both.program.vertex.as_ref().unwrap(), both.program.fragment.as_ref().unwrap()] {
        for (name, _) in bindings_of(&stage.text) {
            let ok = name == "GlobalUniforms"
                || (name.starts_with("g_Texture") && name[9..].parse::<u32>().is_ok())
                || (name.starts_with("_we_Sampler_g_Texture") && name[21..].parse::<u32>().is_ok());
            assert!(ok, "{name} is not a name the engine accepts");
        }
    }
    let kinds: Vec<_> = both.program.layout.textures.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(kinds, ["g_Texture0", "g_Texture3"]);
}

#[test]
fn a_texture_with_another_name_is_legalized_and_compiles() {
    let f = "uniform sampler2D u_Grain; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(u_Grain, v_T); }";
    let both = compile_program(PASS_V, f);
    let t = &both.program.fragment.as_ref().unwrap().text;
    assert!(t.contains("uniform texture2D u_Grain;") && t.contains("_we_Sampler_u_Grain"));
}

#[test]
fn legalizing_twice_gives_the_same_text() {
    let v = "uniform mat4 g_Mvp; uniform float g_F[3]; attribute vec3 a_Position; varying vec4 v_A; varying vec2 v_B;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_Mvp); v_A = CAST4(g_F[1]); v_B = CAST2(0.0); }";
    let f = "uniform sampler2D g_Texture0; varying vec2 v_B; varying vec4 v_A; varying vec3 v_C;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_B) * v_A + vec4(v_C, 0.0); }";
    let a = legalize(&ProgramInput::program(v, f)).unwrap();
    let b = legalize(&ProgramInput::program(v, f)).unwrap();
    assert_eq!(a, b);
}

#[test]
fn a_binding_above_the_limit_is_refused() {
    let e = stage_err(StageKind::Fragment, "uniform sampler2D g_Texture40;\nvoid main() { gl_FragColor = texSample2D(g_Texture40, CAST2(0.0)); }");
    assert!(e.message().contains("40") && e.is_invalid_request(), "{e}");
}

#[test]
fn unsupported_uniform_types_name_the_type() {
    let e = legalize_err("uniform double g_D;\nvoid main() { gl_Position = CAST4(1.0); }", PASS_F);
    assert!(matches!(e, LegalizeError::Uniform(UniformError::UnsupportedType { .. })), "{e}");
}
