// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The resource layout of a program (spec D 4.3, tests 11 to 14): the generated block, texture
//! and sampler indices, video planes and the active texture slots. Every assertion is made on
//! the legalized text, the Metal binding records and the reflection together.

use super::support::*;
use crate::error::ErrorCategory;
use crate::legalize::{LegalizeError, ProgramInput, legalize};
use crate::request::{StageKind, VideoPlanes};

const VERTEX: &str = "attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_Tex;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_Tex = a_TexCoord; }";

fn frag(body: &str) -> String {
    format!("varying vec2 v_Tex;\n{body}")
}

fn binding_in(p: &crate::pipeline::CompiledProgram, kind: StageKind, name: &str) -> Option<u32> {
    glsl_binding(&glsl_of(p, kind), name)
}

fn record_binding(p: &crate::pipeline::CompiledProgram, kind: StageKind, name: &str) -> Option<u32> {
    p.stage(kind).unwrap().payload.bindings.iter().find(|b| b.name == name).map(|b| b.binding)
}

// ---- 11: indices ----

#[test]
fn the_first_worked_example_of_the_allocation_order() {
    let f = frag("uniform sampler2D g_Texture1;\nuniform sampler2D u_Noise;\nuniform float g_Time;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, v_Tex) + texSample2D(u_Noise, v_Tex * g_Time); }");
    let p = ok(VERTEX, &f);
    let at = |name: &str| binding_in(&p, StageKind::Fragment, name).unwrap_or_else(|| panic!("{name}"));
    assert_eq!(at("GlobalUniforms"), 0, "the block takes the lowest index nothing encodes");
    assert_eq!((at("g_Texture1"), at("_we_Sampler_g_Texture1")), (1, 2));
    assert_eq!((at("u_Noise"), at("_we_Sampler_u_Noise")), (3, 4));
    assert_bindings_agree(&p);
    // The same numbers in the Metal records and in the reflection.
    for (name, binding) in [("GlobalUniforms", 0), ("g_Texture1", 1), ("_we_Sampler_g_Texture1", 2), ("u_Noise", 3), ("_we_Sampler_u_Noise", 4)] {
        assert_eq!(record_binding(&p, StageKind::Fragment, name), Some(binding), "{name}");
        assert!(p.reflection.descriptor_bindings.iter().any(|d| d.name == name && d.binding == binding), "{name}");
    }
}

#[test]
fn the_second_worked_example_has_no_block() {
    let v = "attribute vec3 a_Position; attribute vec2 a_TexCoord;\nuniform sampler2D g_Texture2;\nvoid main() { gl_Position = vec4(a_Position, 1.0) + texSample2DLod(g_Texture2, a_TexCoord, 0.0); }";
    let f = frag("uniform sampler2D u_Edge;\nvoid main() { gl_FragColor = texSample2D(u_Edge, v_Tex); }");
    let p = ok(v, &f);
    let (vt, ft) = (glsl_of(&p, StageKind::Vertex), glsl_of(&p, StageKind::Fragment));
    assert_eq!((glsl_binding(&vt, "g_Texture2"), glsl_binding(&vt, "_we_Sampler_g_Texture2")), (Some(2), Some(0)));
    assert_eq!((glsl_binding(&ft, "u_Edge"), glsl_binding(&ft, "_we_Sampler_u_Edge")), (Some(1), Some(3)));
    assert!(!vt.contains("GlobalUniforms") && !ft.contains("GlobalUniforms"));
    assert!(p.reflection.uniform_blocks.is_empty());
    assert!(!p.reflection.descriptor_bindings.iter().any(|d| d.name == "GlobalUniforms"));
    assert_bindings_agree(&p);
}

#[test]
fn an_encoded_texture_index_never_moves_when_other_resources_appear() {
    let base = ok(VERTEX, &frag("uniform sampler2D g_Texture3;\nvoid main() { gl_FragColor = texSample2D(g_Texture3, v_Tex); }"));
    let more = ok(
        VERTEX,
        &frag("uniform sampler2D g_Texture3;\nuniform sampler2D u_Extra;\nuniform vec4 g_Tint;\nvoid main() { gl_FragColor = texSample2D(g_Texture3, v_Tex) * g_Tint + texSample2D(u_Extra, v_Tex); }"),
    );
    for p in [&base, &more] {
        assert_eq!(binding_in(p, StageKind::Fragment, "g_Texture3"), Some(3));
        let block = binding_in(p, StageKind::Fragment, "GlobalUniforms");
        assert_ne!(block, Some(3), "a block index never equals an encoded texture index");
    }
    assert!(binding_in(&base, StageKind::Fragment, "GlobalUniforms").is_none());
}

#[test]
fn samplers_avoid_indices_the_other_stage_encodes() {
    // The vertex stage encodes index 1 and 2; the fragment's non-encoded texture and every
    // sampler must go around them.
    let v = "attribute vec3 a_Position; attribute vec2 a_TexCoord;\nuniform sampler2D g_Texture1; uniform sampler2D g_Texture2;\nvoid main() { gl_Position = vec4(a_Position, 1.0) + texSample2DLod(g_Texture1, a_TexCoord, 0.0) + texSample2DLod(g_Texture2, a_TexCoord, 0.0); }";
    let f = frag("uniform sampler2D u_Mask;\nvoid main() { gl_FragColor = texSample2D(u_Mask, v_Tex); }");
    let p = ok(v, &f);
    let used: Vec<u32> = glsl_bindings(&glsl_of(&p, StageKind::Fragment)).into_iter().map(|(_, b)| b).collect();
    let mut all: Vec<u32> = p.stages.iter().flat_map(|s| glsl_bindings(&s.glsl)).map(|(_, b)| b).collect();
    all.sort_unstable();
    all.dedup();
    assert_eq!(all.len(), 6, "g_Texture1, g_Texture2, u_Mask and their samplers: no two share an index, {all:?}");
    assert!(!used.is_empty());
    assert_bindings_agree(&p);
}

#[test]
fn a_texture_declared_in_both_stages_is_one_resource_with_both_stages_in_its_mask() {
    let v = "attribute vec3 a_Position; attribute vec2 a_TexCoord;\nuniform sampler2D g_Texture0;\nvoid main() { gl_Position = vec4(a_Position, 1.0) + texSample2DLod(g_Texture0, a_TexCoord, 0.0); }";
    let f = frag("uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex); }");
    let p = ok(v, &f);
    for name in ["g_Texture0", "_we_Sampler_g_Texture0"] {
        assert_eq!(binding_in(&p, StageKind::Vertex, name), binding_in(&p, StageKind::Fragment, name), "{name}");
        let d: Vec<_> = p.reflection.descriptor_bindings.iter().filter(|d| d.name == name).collect();
        assert_eq!(d.len(), 1, "{name}");
        assert_eq!(d[0].stages, crate::reflection::StageMask::BOTH, "{name}");
    }
    assert_eq!(p.reflection.active_texture_slots.iter().copied().collect::<Vec<_>>(), [0]);
}

#[test]
fn the_indices_do_not_depend_on_the_order_of_the_stages_in_the_request() {
    let f = frag("uniform sampler2D g_Texture1;\nuniform sampler2D u_Noise;\nuniform float g_Time;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, v_Tex) + texSample2D(u_Noise, v_Tex * g_Time); }");
    let a = Req::new(VERTEX, &f).ok();
    let b = Req::new(VERTEX, &f).fragment_first().ok();
    assert_eq!(a.reflection, b.reflection);
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        assert_eq!(a.stage(kind).unwrap().glsl, b.stage(kind).unwrap().glsl);
        assert_eq!(a.stage(kind).unwrap().payload, b.stage(kind).unwrap().payload);
    }
    assert_eq!(b.stages[0].kind, StageKind::Fragment);
}

/// A program the legalizer lays out; the kept samplers of these cases cannot be compiled by
/// naga, so the layout is read from the legalized text.
fn layout_only(vertex: &str, fragment: &str) -> Result<crate::legalize::LegalProgram, LegalizeError> {
    legalize(&ProgramInput::program(vertex, fragment))
}

#[test]
fn a_pass_through_sampler_reserves_its_index_only_in_set_zero() {
    let reserved = "layout(set = 0, binding = 0) uniform samplerCube g_Cube; uniform sampler2D g_Texture1; uniform float g_X;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, vec2(g_X)); }";
    let p = layout_only("void main() { gl_Position = vec4(1.0); }", reserved).unwrap();
    assert_eq!(glsl_binding(&p.fragment.as_ref().unwrap().text, "GlobalUniforms"), Some(2), "0 is the cube, 1 the texture");
    let other_set = reserved.replace("set = 0", "set = 1");
    let p = layout_only("void main() { gl_Position = vec4(1.0); }", &other_set).unwrap();
    assert_eq!(glsl_binding(&p.fragment.as_ref().unwrap().text, "GlobalUniforms"), Some(0), "a resource in set 1 reserves nothing in set 0");
    // Such a program cannot be compiled for the native renderer: naga reads no combined sampler.
    let e = err("void main() { gl_Position = vec4(1.0); }", reserved);
    assert_eq!(e.category(), ErrorCategory::Compile, "{e}");
}

#[test]
fn one_index_claimed_by_two_different_resources_fails_naming_index_and_resources() {
    let v = "layout(binding = 0) uniform float g_A;\nvoid main() { gl_Position = vec4(g_A); }";
    let f = "uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }";
    let e = err(v, f);
    assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{e}");
    let text = e.to_string();
    assert!(text.contains("binding 0") || text.contains("index 0"), "{text}");
    assert!(text.contains("GlobalUniforms") && text.contains("g_Texture0"), "{text}");
}

#[test]
fn an_explicit_block_binding_wins() {
    let sampled = |name: &str| format!("uniform sampler2D {name};\nvoid main() {{ gl_FragColor = texSample2D({name}, vec2(g_A)); }}");
    // Separated from its uniform by a comment, followed by further layout qualifiers, on one of
    // several members: the first `binding` wins.
    let v = "uniform vec2 g_B; /* a comment */ layout(row_major) /* another */ layout(binding = 5) uniform float g_A;\nvoid main() { gl_Position = vec4(g_A, g_B, 1.0); }";
    let f = format!("layout(binding = 5) uniform float g_A;\n{}", sampled("g_Texture0"));
    let p = ok(v, &f);
    assert_eq!(binding_in(&p, StageKind::Fragment, "GlobalUniforms"), Some(5));
    assert_eq!(p.reflection.uniform_blocks[0].binding, 5);
    assert_eq!(binding_in(&p, StageKind::Fragment, "_we_Sampler_g_Texture0"), Some(1), "5 is the block's, 0 the texture's");
    assert_bindings_agree(&p);
    // Two different explicit values fail naming both.
    let e = err("layout(binding = 5) uniform float g_A;\nvoid main() { gl_Position = vec4(g_A); }", "layout(binding = 6) uniform float g_A;\nvoid main() { gl_FragColor = vec4(g_A); }");
    let text = e.to_string();
    assert!(e.category() == ErrorCategory::InvalidRequest && text.contains('5') && text.contains('6'), "{text}");
}

// ---- 12: block-bound uniforms ----

fn block_members(p: &crate::pipeline::CompiledProgram) -> Vec<(String, u32, u32)> {
    p.reflection.uniform_blocks[0].members.iter().map(|m| (m.name.clone(), m.element_count, m.array_count)).collect()
}

#[test]
fn members_are_in_the_order_of_first_appearance_vertex_stage_first() {
    let v = "uniform float g_V1; uniform vec2 g_Shared; uniform float g_V2;\nvoid main() { gl_Position = vec4(g_V1 + g_V2, g_Shared, 1.0); }";
    let f = frag("uniform float g_F1; uniform vec2 g_Shared; uniform vec4 g_F2;\nvoid main() { gl_FragColor = vec4(g_F1 + g_Shared.x) + g_F2; }");
    let p = Req::new(v, &f).fragment_first().ok();
    let names: Vec<(String, u32, u32)> = block_members(&p);
    assert_eq!(names.iter().map(|m| m.0.as_str()).collect::<Vec<_>>(), ["g_V1", "g_Shared", "g_V2", "g_F1", "g_F2"]);
}

#[test]
fn a_member_declared_in_both_stages_is_one() {
    let v = "uniform float g_A;\nvoid main() { gl_Position = vec4(g_A); }";
    let f = "uniform float g_A;\nvoid main() { gl_FragColor = vec4(g_A); }";
    let p = ok(v, f);
    assert_eq!(block_members(&p), [("g_A".to_string(), 1, 0)]);
    assert!(p.reflection.descriptor_bindings.iter().find(|d| d.name == "GlobalUniforms").unwrap().stages == crate::reflection::StageMask::BOTH);
}

#[test]
fn a_vector_declared_wider_in_one_stage_is_one_wider_member_read_through_a_view() {
    for (vertex_ty, fragment_ty) in [("vec3", "vec2"), ("vec2", "vec3")] {
        let v = format!("uniform {vertex_ty} u_Range;\nvoid main() {{ gl_Position = vec4(u_Range.xy, 0.0, 1.0); }}");
        let f = format!("uniform {fragment_ty} u_Range;\nvoid main() {{ gl_FragColor = vec4(u_Range.xy, 0.0, 1.0); }}");
        let p = ok(&v, &f);
        assert_eq!(block_members(&p), [("u_Range".to_string(), 3, 0)], "{vertex_ty}/{fragment_ty}");
        let narrower = if vertex_ty == "vec2" { StageKind::Vertex } else { StageKind::Fragment };
        assert!(glsl_of(&p, narrower).contains("u_Range.xy") || glsl_of(&p, narrower).contains("(u_Range.xy)"), "{}", glsl_of(&p, narrower));
    }
    // A float against a vec2, in both stage orders.
    for (vertex_ty, fragment_ty) in [("float", "vec2"), ("vec2", "float")] {
        let read = |ty: &str| if ty == "float" { "u_Size" } else { "u_Size.x" };
        let v = format!("uniform {vertex_ty} u_Size;\nvoid main() {{ gl_Position = vec4({}); }}", read(vertex_ty));
        let f = format!("uniform {fragment_ty} u_Size;\nvoid main() {{ gl_FragColor = vec4({}); }}", read(fragment_ty));
        assert_eq!(block_members(&ok(&v, &f)), [("u_Size".to_string(), 2, 0)]);
    }
}

#[test]
fn incompatible_redeclarations_fail_naming_the_member_and_both_declarations() {
    let cases: [(&str, &str, &str); 5] = [
        ("uniform vec2 u_A[2];", "uniform vec2 u_A[3];", "u_A"),            // different array suffix
        ("uniform float g_Alpha;", "uniform vec2 g_Alpha;", "g_Alpha"),     // an engine uniform keeps one type
        ("uniform mat4 u_M;", "uniform vec4 u_M;", "u_M"),                  // differing non-vector types
        ("uniform vec2 u_V; uniform vec3 u_V;", "uniform float u_Z;", "u_V"), // one stage, two types
        ("uniform vec2 u_Arr[2];", "uniform vec4 u_Arr[2];", "u_Arr"),      // arrays do not widen
    ];
    for (v, f, name) in cases {
        let e = err(&format!("{v}\nvoid main() {{ gl_Position = vec4(0.0); }}"), &format!("{f}\nvoid main() {{ gl_FragColor = vec4(0.0); }}"));
        assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{v} / {f}: {e}");
        assert!(e.to_string().contains(name), "{e}");
    }
}

#[test]
fn engine_uniforms_never_merge_by_prefix() {
    let v = "uniform float g_Time;\nvoid main() { gl_Position = vec4(g_Time); }";
    let f = "uniform float g_TimeScale;\nvoid main() { gl_FragColor = vec4(g_TimeScale); }";
    let names: Vec<String> = block_members(&ok(v, f)).into_iter().map(|m| m.0).collect();
    assert_eq!(names, ["g_Time", "g_TimeScale"]);
}

#[test]
fn array_suffixes_are_canonical_and_macro_sizes_are_resolved() {
    for suffix in ["[5]", "[\t5]", "[ 5 ]", "[005]"] {
        let v = format!("uniform vec4 u_Arr{suffix};\nvoid main() {{ gl_Position = u_Arr[4]; }}");
        let f = "uniform vec4 u_Arr[5];\nvoid main() { gl_FragColor = u_Arr[1]; }";
        let p = ok(&v, f);
        assert_eq!(block_members(&p), [("u_Arr".to_string(), 4, 5)], "{suffix:?}");
        assert!(!glsl_of(&p, StageKind::Vertex).contains("u_Arr[005]"));
    }
    // A combo-sized array in both stages never leaves the macro name in the block.
    let both = |tail: &str| format!("uniform mat4 g_Bones[BONECOUNT];\n{tail}");
    let p = Req::new(&both("void main() { gl_Position = g_Bones[0][0]; }"), &both("void main() { gl_FragColor = g_Bones[1][0]; }")).combo("BONECOUNT", "7").ok();
    assert_eq!(block_members(&p), [("g_Bones".to_string(), 16, 7)]);
    assert!(!glsl_of(&p, StageKind::Vertex).contains("BONECOUNT"));
}

#[test]
fn an_empty_or_computed_suffix_and_a_structure_fail() {
    for suffix in ["[]", "[2 + 1]", "[UNKNOWN_MACRO]"] {
        let e = err(&format!("uniform vec4 u_Arr{suffix};\nvoid main() {{ gl_Position = vec4(0.0); }}"), "void main() { gl_FragColor = vec4(0.0); }");
        assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{suffix}: {e}");
        let text = e.to_string();
        assert!(text.contains("u_Arr") && text.contains("vertex") || text.contains("Vertex"), "{suffix}: {text}");
    }
    let e = err("struct Light { vec3 c; };\nuniform Light u_Light;\nvoid main() { gl_Position = vec4(0.0); }", "void main() { gl_FragColor = vec4(0.0); }");
    assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{e}");
    assert!(e.to_string().contains("Light"), "{e}");
}

#[test]
fn no_uniforms_and_no_textures_produce_no_block() {
    let p = ok(VERTEX, &frag("void main() { gl_FragColor = vec4(v_Tex, 0.0, 1.0); }"));
    assert!(p.reflection.uniform_blocks.is_empty());
    assert!(p.reflection.descriptor_bindings.is_empty());
    assert!(!glsl_of(&p, StageKind::Vertex).contains("GlobalUniforms") && !glsl_of(&p, StageKind::Fragment).contains("GlobalUniforms"));
}

#[test]
fn a_stage_that_uses_no_uniform_still_declares_the_block() {
    let v = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }";
    let f = "uniform float g_Alpha;\nvoid main() { gl_FragColor = vec4(g_Alpha); }";
    let p = ok(v, f);
    let vt = glsl_of(&p, StageKind::Vertex);
    assert!(vt.contains("uniform GlobalUniforms {") && vt.contains("float g_Alpha;"), "{vt}");
    let d = p.reflection.descriptor_bindings.iter().find(|d| d.name == "GlobalUniforms").unwrap();
    assert_eq!(d.stages, crate::reflection::StageMask::FRAGMENT, "the vertex stage's reflection does not list it");
    assert!(p.stage(StageKind::Vertex).unwrap().payload.bindings.iter().any(|b| b.name == "GlobalUniforms"), "but the record exists");
}

// ---- 13: video planes ----

fn flagged(slot: u8) -> crate::request::TextureRecord {
    let mut t = texture(slot);
    t.video_planes = VideoPlanes::Nv12Biplanar;
    t
}

const PLANE_FRAGMENT: &str = "varying vec2 v_Tex;\nuniform sampler2D g_Texture0; uniform sampler2D g_Texture1; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex) * texSample2D(g_Texture1, v_Tex) * g_Alpha; }";

#[test]
fn a_flagged_slot_gets_chroma_resources_after_every_author_index() {
    let plain = Req::new(VERTEX, PLANE_FRAGMENT).texture(texture(0)).texture(texture(1)).ok();
    let planar = Req::new(VERTEX, PLANE_FRAGMENT).texture(flagged(0)).texture(texture(1)).ok();
    for name in ["g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1", "GlobalUniforms"] {
        assert_eq!(binding_in(&plain, StageKind::Fragment, name), binding_in(&planar, StageKind::Fragment, name), "{name} does not move");
    }
    let author: Vec<u32> = glsl_bindings(&glsl_of(&plain, StageKind::Fragment)).into_iter().map(|(_, b)| b).collect();
    let chroma = binding_in(&planar, StageKind::Fragment, "_we_VideoChroma0").unwrap();
    let sampler = binding_in(&planar, StageKind::Fragment, "_we_Sampler__we_VideoChroma0").unwrap();
    assert!(author.iter().all(|b| *b < chroma && *b < sampler) && sampler == chroma + 1, "{author:?} then {chroma}, {sampler}");
    assert_bindings_agree(&planar);
    // The four generated members follow the author's, in order, with the stated types.
    let members: Vec<(String, u32)> = planar.reflection.uniform_blocks[0].members.iter().map(|m| (m.name.clone(), m.element_count)).collect();
    let tail = &members[members.len() - 4..];
    assert_eq!(
        tail,
        [("_we_VideoRange0".to_string(), 4), ("_we_VideoMatrix0".to_string(), 4), ("_we_VideoUvTransform0".to_string(), 4), ("_we_VideoUvOffset0".to_string(), 2)]
    );
    assert_eq!(members[0].0, "g_Alpha");
    // The vertex stage never samples the video: no chroma text there.
    assert!(!glsl_of(&planar, StageKind::Vertex).contains("_we_VideoChroma0"));
    assert!(glsl_of(&planar, StageKind::Fragment).contains("_we_VideoChroma0"));
}

#[test]
fn the_plane_constants_make_a_block_when_the_author_declared_no_uniform() {
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex); }";
    let p = Req::new(VERTEX, f).texture(flagged(0)).ok();
    assert_eq!(p.reflection.uniform_blocks[0].members.len(), 4);
    let ft = glsl_of(&p, StageKind::Fragment);
    assert_eq!((glsl_binding(&ft, "g_Texture0"), glsl_binding(&ft, "_we_Sampler_g_Texture0")), (Some(0), Some(1)));
    // The block takes any binding that collides with nothing (amendment D6): only uniqueness and the
    // chroma resources lying above the author's are required, not the order of the block among them.
    let all: Vec<u32> = glsl_bindings(&ft).into_iter().map(|(_, b)| b).collect();
    assert_eq!(all.len(), all.iter().collect::<std::collections::HashSet<_>>().len(), "{all:?}");
    assert!(glsl_binding(&ft, "GlobalUniforms").is_some());
    assert!(glsl_binding(&ft, "_we_VideoChroma0").unwrap() > 1 && glsl_binding(&ft, "_we_Sampler__we_VideoChroma0").unwrap() > 1);
}

#[test]
fn a_flag_on_a_slot_the_program_never_declares_changes_nothing() {
    let plain = Req::new(VERTEX, PLANE_FRAGMENT).texture(texture(0)).texture(texture(1)).ok();
    let undeclared = Req::new(VERTEX, PLANE_FRAGMENT).texture(texture(0)).texture(texture(1)).texture(flagged(9)).ok();
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        assert_eq!(plain.stage(kind).unwrap(), undeclared.stage(kind).unwrap());
    }
    assert_eq!(plain.reflection, undeclared.reflection);
    assert_eq!(plain.metadata, undeclared.metadata);
}

#[test]
fn an_unflagged_compile_is_identical_with_or_without_the_plane_field() {
    let a = Req::new(VERTEX, PLANE_FRAGMENT).texture(texture(0)).ok();
    let mut explicit = texture(0);
    explicit.video_planes = VideoPlanes::None;
    let b = Req::new(VERTEX, PLANE_FRAGMENT).texture(explicit).ok();
    assert_eq!(a, b);
    // Flagged and unflagged keys differ.
    let flagged_program = Req::new(VERTEX, PLANE_FRAGMENT).texture(flagged(0)).ok();
    assert_ne!(a.cache_key, flagged_program.cache_key);
}

#[test]
fn a_use_the_translation_cannot_reproduce_refuses_the_variant_but_not_the_plain_program() {
    let cases = [
        ("an explicit level", "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2DLod(g_Texture0, v_Tex, 1.0); }"),
        ("a size query", "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = vec4(float(textureSize(g_Texture0, 0).x)); }"),
        ("a level inside a macro body", "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\n#define SAMPLE_LOD(uv) texSample2DLod(g_Texture0, uv, 2.0)\nvoid main() { gl_FragColor = SAMPLE_LOD(v_Tex); }"),
        ("a size query inside a macro body", "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\n#define SIZE textureSize(g_Texture0, 0)\nvoid main() { gl_FragColor = vec4(float(SIZE.x)); }"),
        ("a texel fetch", "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texelFetch(g_Texture0, ivec2(1), 0); }"),
    ];
    for (what, fragment) in cases {
        Req::new(VERTEX, fragment).texture(texture(0)).ok();
        let e = Req::new(VERTEX, fragment).texture(flagged(0)).err();
        assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{what}: {e}");
        let text = e.to_string();
        assert!(text.contains("g_Texture0") || text.contains("slot 0"), "{what}: {text}");
    }
}

#[test]
fn a_macro_body_that_only_samples_the_video_texture_is_rewritten() {
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture0;\n#define VIDEO(uv) texSample2D(g_Texture0, uv)\nvoid main() { gl_FragColor = VIDEO(v_Tex) + VIDEO(v_Tex * 0.5); }";
    let p = Req::new(VERTEX, f).texture(flagged(0)).ok();
    let ft = glsl_of(&p, StageKind::Fragment);
    assert_eq!(ft.matches("_we_plane0(v_Tex").count(), 2, "{ft}");
}

// ---- 14: active texture slots ----

fn slots(p: &crate::pipeline::CompiledProgram) -> Vec<u8> {
    p.reflection.active_texture_slots.iter().copied().collect()
}

#[test]
fn slots_follow_names_and_not_binding_indices() {
    let f = frag("uniform sampler2D g_Texture5; uniform sampler2D g_Texture1; uniform sampler2D g_Texture6; uniform sampler2D u_Overlay;\nvoid main() { gl_FragColor = texSample2D(g_Texture5, v_Tex) + texSample2D(g_Texture1, v_Tex) + texSample2D(u_Overlay, v_Tex); }");
    let p = ok(VERTEX, &f);
    assert_eq!(slots(&p), [1, 5], "g_Texture6 is declared and never sampled");
    let names: Vec<&str> = p.reflection.descriptor_bindings.iter().map(|d| d.name.as_str()).collect();
    assert!(!names.contains(&"g_Texture6"), "{names:?}");
    assert!(names.contains(&"u_Overlay"), "a texture with another name still appears as a descriptor");
    assert_eq!(p.metadata.active_texture_slots, p.reflection.active_texture_slots, "the metadata lists the same slots");
}

#[test]
fn the_slots_are_the_union_over_both_stages() {
    let v = "attribute vec3 a_Position; attribute vec2 a_TexCoord;\nuniform sampler2D g_Texture2;\nvoid main() { gl_Position = vec4(a_Position, 1.0) + texSample2DLod(g_Texture2, a_TexCoord, 0.0); }";
    let f = frag("uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex); }");
    assert_eq!(slots(&ok(v, &f)), [0, 2]);
}

#[test]
fn a_combo_that_removes_the_sampling_removes_the_slot() {
    let f = frag("uniform sampler2D g_Texture0; uniform sampler2D g_Texture1;\nvoid main() {\n  vec4 c = texSample2D(g_Texture0, v_Tex);\n#if MASK\n  c *= texSample2D(g_Texture1, v_Tex);\n#endif\n  gl_FragColor = c;\n}");
    assert_eq!(slots(&Req::new(VERTEX, &f).combo("MASK", "1").ok()), [0, 1]);
    assert_eq!(slots(&Req::new(VERTEX, &f).combo("MASK", "0").ok()), [0]);
}

#[test]
fn a_non_canonical_name_fails_early_and_a_slot_above_31_fails_when_used() {
    let e = err(VERTEX, &frag("uniform sampler2D g_Texture07;\nvoid main() { gl_FragColor = vec4(1.0); }"));
    assert_eq!(e.category(), ErrorCategory::Legalization, "{e}");
    let text = e.to_string();
    assert!(text.contains("g_Texture07") && text.contains("canonical"), "{text}");
    let e = err(VERTEX, &frag("uniform sampler2D g_Texture32;\nvoid main() { gl_FragColor = texSample2D(g_Texture32, v_Tex); }"));
    assert_eq!(e.category(), ErrorCategory::Reflection, "{e}");
    assert!(e.to_string().contains("model limits") && e.to_string().contains("g_Texture32"), "{e}");
    // Declared and never sampled: no error.
    ok(VERTEX, &frag("uniform sampler2D g_Texture32;\nvoid main() { gl_FragColor = vec4(1.0); }"));
}
