// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Merging, the cache key and the identity (spec D tests 15 to 17), and the substitutable
//! steps of the pipeline (R6): these tests replace the compiler and the reflector, so they
//! need neither naga nor a translation to Metal.

use std::collections::BTreeSet;

use super::support::*;
use crate::backend::{CompiledStage, StageCompiler};
use crate::error::{ErrorCategory, ShaderError};
use crate::identity::compiler_identity;
use crate::legalize::LegalStage;
use crate::pipeline::{CompiledProgram, Pipeline};
use crate::reflect::{InputNames, StageReflector};
use crate::reflection::{
    BlockMember, DescriptorBinding, DescriptorKind, Reflection, StageMask, UniformBlock, VertexFormat, VertexInput, VertexScalar,
};
use crate::request::{CachePolicy, Property, PropertyValue, StageKind, TextureFormat, VideoPlanes};
use crate::response::StagePayload;
use crate::source::NoIncludes;

/// A compiler that merely returns the legalized text.
struct TextOnly;

impl StageCompiler for TextOnly {
    fn compile(&self, kind: StageKind, stage: &LegalStage) -> Result<CompiledStage, ShaderError> {
        Ok(CompiledStage {
            payload: StagePayload::new(kind, stage.text.clone(), "main".into(), vec![]),
            translated: None,
            diagnostics: vec![],
        })
    }
}

/// A reflector that returns what it was given, per stage.
struct Canned {
    vertex: Reflection,
    fragment: Reflection,
}

impl StageReflector for Canned {
    fn reflect(&self, kind: StageKind, _: &CompiledStage, _: &InputNames) -> Result<Reflection, ShaderError> {
        Ok(if kind == StageKind::Vertex { self.vertex.clone() } else { self.fragment.clone() })
    }
}

struct NoReflection;

impl StageReflector for NoReflection {
    fn reflect(&self, _: StageKind, _: &CompiledStage, _: &InputNames) -> Result<Reflection, ShaderError> {
        Ok(Reflection::default())
    }
}

fn run(req: &Req, reflector: &dyn StageReflector) -> Result<CompiledProgram, ShaderError> {
    Pipeline { compiler: &TextOnly, reflector }.compile(&req.build(), &NoIncludes)
}

fn descriptor(name: &str, binding: u32, kind: DescriptorKind, stages: StageMask, count: u32) -> DescriptorBinding {
    DescriptorBinding { name: name.into(), set: 0, binding, descriptor: kind, stages, count }
}

fn block(name: &str, binding: u32, offset_of_second: u32) -> UniformBlock {
    let member = |n: &str, offset| BlockMember { name: n.into(), offset, size: 4, element_count: 1, array_count: 0, array_stride: 0 };
    UniformBlock { name: name.into(), set: 0, binding, size: 32, members: vec![member("g_A", 0), member("g_B", offset_of_second)] }
}

fn input(name: &str, location: u32) -> VertexInput {
    VertexInput { name: name.into(), location, format: VertexFormat::new(VertexScalar::Float, 2).unwrap() }
}

// ---- R6: the steps are replaceable ----

#[test]
fn the_pipeline_runs_with_a_compiler_that_returns_the_legalized_text() {
    let req = Req::new(PASS_VERTEX, PASS_FRAGMENT);
    let p = run(&req, &NoReflection).unwrap();
    for s in &p.stages {
        assert_eq!(s.payload.msl_source, s.glsl, "the substitute passes the text through");
    }
    assert!(p.reflection == Reflection::default());
    assert_eq!(p.stages.len(), 2);
    assert!(!p.cache_key.is_empty());
}

#[test]
fn the_default_reflector_needs_a_module_and_says_so() {
    let e = Pipeline { compiler: &TextOnly, reflector: &crate::reflect::NagaReflector }.compile(&Req::new(PASS_VERTEX, PASS_FRAGMENT).build(), &NoIncludes).unwrap_err();
    assert_eq!(e.category(), ErrorCategory::Internal, "{e}");
}

// ---- 15: the merge ----

#[test]
fn stage_masks_union_counts_take_the_larger_and_the_order_is_canonical() {
    let vertex = Reflection {
        descriptor_bindings: vec![
            descriptor("u_Z", 5, DescriptorKind::SampledImage, StageMask::VERTEX, 1),
            descriptor("shared", 2, DescriptorKind::UniformBuffer, StageMask::VERTEX, 1),
            descriptor("pool", 9, DescriptorKind::SampledImage, StageMask::VERTEX, 2),
        ],
        ..Reflection::default()
    };
    let fragment = Reflection {
        descriptor_bindings: vec![
            descriptor("a_First", 0, DescriptorKind::Sampler, StageMask::FRAGMENT, 1),
            descriptor("shared", 2, DescriptorKind::UniformBuffer, StageMask::FRAGMENT, 1),
            descriptor("pool", 9, DescriptorKind::SampledImage, StageMask::FRAGMENT, 4),
        ],
        ..Reflection::default()
    };
    let p = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex, fragment }).unwrap();
    let list: Vec<(&str, u32, StageMask, u32)> = p.reflection.descriptor_bindings.iter().map(|d| (d.name.as_str(), d.binding, d.stages, d.count)).collect();
    assert_eq!(
        list,
        [
            ("a_First", 0, StageMask::FRAGMENT, 1),
            ("shared", 2, StageMask::BOTH, 1),
            ("u_Z", 5, StageMask::VERTEX, 1),
            ("pool", 9, StageMask::BOTH, 4),
        ]
    );
}

#[test]
fn descriptor_kinds_sort_by_their_labels() {
    let r = Reflection {
        descriptor_bindings: vec![
            descriptor("c", 1, DescriptorKind::UniformBuffer, StageMask::FRAGMENT, 1),
            descriptor("b", 1, DescriptorKind::Sampler, StageMask::FRAGMENT, 1),
            descriptor("a", 1, DescriptorKind::SampledImage, StageMask::FRAGMENT, 1),
            descriptor("d", 1, DescriptorKind::CombinedImageSampler, StageMask::FRAGMENT, 1),
        ],
        ..Reflection::default()
    };
    let p = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex: Reflection::default(), fragment: r }).unwrap();
    let labels: Vec<&str> = p.reflection.descriptor_bindings.iter().map(|d| d.descriptor.name()).collect();
    assert_eq!(labels, ["combined_image_sampler", "sampled_image", "sampler", "uniform_buffer"]);
}

#[test]
fn vertex_inputs_merge_by_location_and_the_first_stage_that_lists_one_wins() {
    let vertex = Reflection { vertex_inputs: vec![input("a_Second", 1), input("a_First", 0)], ..Reflection::default() };
    let fragment = Reflection { vertex_inputs: vec![input("a_Ignored", 1), input("a_Third", 2)], ..Reflection::default() };
    let p = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex, fragment }).unwrap();
    let names: Vec<&str> = p.reflection.vertex_inputs.iter().map(|i| i.name.as_str()).collect();
    assert_eq!(names, ["a_First", "a_Second", "a_Third"]);
}

#[test]
fn equal_blocks_become_one_and_conflicting_layouts_fail_naming_block_set_and_binding() {
    let same = Reflection { uniform_blocks: vec![block("GlobalUniforms", 1, 4)], ..Reflection::default() };
    let p = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex: same.clone(), fragment: same.clone() }).unwrap();
    assert_eq!(p.reflection.uniform_blocks.len(), 1);
    let other = Reflection { uniform_blocks: vec![block("GlobalUniforms", 1, 8)], ..Reflection::default() };
    let e = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex: same, fragment: other }).unwrap_err();
    assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{e}");
    let text = e.to_string();
    assert!(text.contains("GlobalUniforms") && text.contains("set 0") && text.contains("binding 1"), "{text}");
}

#[test]
fn the_active_slots_are_the_sorted_union_and_the_metadata_repeats_them() {
    let vertex = Reflection { active_texture_slots: BTreeSet::from([5, 1]), ..Reflection::default() };
    let fragment = Reflection { active_texture_slots: BTreeSet::from([3, 1]), ..Reflection::default() };
    let p = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex, fragment }).unwrap();
    assert_eq!(p.reflection.active_texture_slots.iter().copied().collect::<Vec<_>>(), [1, 3, 5]);
    assert_eq!(p.metadata.active_texture_slots, p.reflection.active_texture_slots);
}

#[test]
fn the_model_limits_apply_to_the_merged_reflection() {
    let fragment = Reflection { descriptor_bindings: vec![descriptor("u_Far", 32, DescriptorKind::Sampler, StageMask::FRAGMENT, 1)], ..Reflection::default() };
    let e = run(&Req::new(PASS_VERTEX, PASS_FRAGMENT), &Canned { vertex: Reflection::default(), fragment }).unwrap_err();
    assert_eq!(e.category(), ErrorCategory::Reflection, "{e}");
    assert!(e.to_string().contains("model limits"), "{e}");
}

// ---- 16: the cache key ----

fn key(req: &Req) -> String {
    run(req, &NoReflection).unwrap().cache_key
}

fn base() -> Req {
    let mut t = texture(0);
    t.format = TextureFormat::Unknown;
    Req::new(PASS_VERTEX, PASS_FRAGMENT).texture(t).combo("A", "1").property(Property { name: "p".into(), value: PropertyValue::Number(1.0) })
}

fn changes(label: &str, change: impl FnOnce(Req) -> Req) {
    assert_ne!(key(&base()), key(&change(base())), "{label} must change the key");
}

#[test]
fn every_ingredient_of_the_key_changes_it() {
    assert_eq!(key(&base()), key(&base()));
    changes("the vertex source", |mut r| {
        r.vertex.push_str("\n// edited\n");
        r
    });
    changes("the fragment source", |mut r| {
        r.fragment.push_str("\n// edited\n");
        r
    });
    changes("the shader name", |mut r| {
        r.name = "other/name".into();
        r
    });
    changes("a combo value", |mut r| {
        r.combos[0].1 = "2".into();
        r
    });
    changes("a combo name", |mut r| {
        r.combos[0].0 = "B".into();
        r
    });
    changes("an extra combo", |r| r.combo("C", "1"));
    changes("the scene id", |r| r.cache(CachePolicy::Enabled { scene_id: "scene-7".into() }));
    changes("the cache strategy", |r| r.cache(CachePolicy::Enabled { scene_id: String::new() }));
    changes("texture presence", |mut r| {
        r.textures[0].present = false;
        r
    });
    changes("texture enabled", |mut r| {
        r.textures[0].enabled = false;
        r
    });
    changes("texture format", |mut r| {
        r.textures[0].format = TextureFormat::Rg8;
        r
    });
    for (i, flag) in ["compo1", "compo2", "compo3", "compo4"].iter().enumerate() {
        changes(flag, |mut r| {
            let c = &mut r.textures[0].components;
            match i {
                0 => c.compo1 = true,
                1 => c.compo2 = true,
                2 => c.compo3 = true,
                _ => c.compo4 = true,
            }
            r
        });
    }
    changes("the plane marker", |mut r| {
        r.textures[0].video_planes = VideoPlanes::Nv12Biplanar;
        r
    });
    changes("a property value", |mut r| {
        r.properties[0].value = PropertyValue::Number(2.0);
        r
    });
    changes("a property name", |mut r| {
        r.properties[0].name = "q".into();
        r
    });
}

#[test]
fn a_different_legalization_changes_the_key_with_the_sources_unchanged() {
    // The same text under two combos legalizes differently (the text depends on a macro).
    let f = "void main() {\n#if FLAG\n  gl_FragColor = vec4(1.0);\n#else\n  gl_FragColor = vec4(0.0);\n#endif\n}\n";
    let a = Req::new(PASS_VERTEX, f).combo("FLAG", "1");
    let b = Req::new(PASS_VERTEX, f).combo("FLAG", "0");
    assert_ne!(key(&a), key(&b));
}

#[test]
fn property_kinds_with_equal_numbers_differ() {
    let with = |value| key(&Req::new(PASS_VERTEX, PASS_FRAGMENT).property(Property { name: "p".into(), value }));
    let all = [
        with(PropertyValue::Vec2([1.0; 2])),
        with(PropertyValue::Vec3([1.0; 3])),
        with(PropertyValue::Vec4([1.0; 4])),
        with(PropertyValue::Matrix4([1.0; 16])),
        with(PropertyValue::Number(1.0)),
        with(PropertyValue::Bool(true)),
        with(PropertyValue::String("1".into())),
    ];
    let unique: BTreeSet<&String> = all.iter().collect();
    assert_eq!(unique.len(), all.len());
    assert_ne!(with(PropertyValue::Number(0.0)), with(PropertyValue::Number(-0.0)), "bit patterns count");
}

#[test]
fn an_ordinary_texture_key_does_not_change_when_the_plane_field_is_spelled_out() {
    let mut explicit = texture(0);
    explicit.video_planes = VideoPlanes::None;
    assert_eq!(key(&Req::new(PASS_VERTEX, PASS_FRAGMENT).texture(texture(0))), key(&Req::new(PASS_VERTEX, PASS_FRAGMENT).texture(explicit)));
}

#[test]
fn the_key_names_the_compiler_identity() {
    use crate::cache_key::{ProgramKeyInput, StageKeyInput, program_key_with_identity};
    let request = base().build();
    let stages = [
        StageKeyInput { kind: StageKind::Vertex, preprocessed: "v", translated_glsl: "v" },
        StageKeyInput { kind: StageKind::Fragment, preprocessed: "f", translated_glsl: "f" },
    ];
    let input = ProgramKeyInput { request: &request, effective_combos: &[], stages: &stages };
    assert_ne!(program_key_with_identity("1:naga-29.0.3-msl2.0-untransformed", &input), program_key_with_identity("2:naga-29.0.3-msl2.0-untransformed", &input), "a new revision is a new key");
}

// ---- 17: the identity ----

#[test]
fn the_identity_is_an_integer_a_colon_and_text_and_never_mentions_spirv() {
    let id = compiler_identity();
    let (revision, rest) = id.split_once(':').expect("<revision>:<options>");
    assert!(revision.parse::<u32>().is_ok() && !rest.is_empty(), "{id}");
    for part in [revision, rest] {
        let lower = part.to_lowercase();
        assert!(!lower.contains("spir") && !lower.contains("spv") && !lower.contains("vulkan"), "{id}");
    }
    assert!(rest.contains("naga") && rest.contains("msl"), "the options identity names the translator and the language: {id}");
}
