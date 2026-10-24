// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Public-API checks of the compiler-independent model: purity and thread
// safety of what the layer builds (R85, R86, R89), and one request read end
// to end into a cache key.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::thread;

use wm_shader::cache_key::{ProgramKeyInput, StageKeyInput, program_key};
use wm_shader::reflection::{
    DescriptorBinding, DescriptorKind, Reflection, StageMask, UniformBlock, VertexFormat, VertexInput, VertexScalar,
};
use wm_shader::response::{ComboEntry, DefaultUniform, Metadata, UniformValue};
use wm_shader::uniforms::{MemberDecl, UniformType, layout_std140};
use wm_shader::{Combo, StageKind, ValidRequest, parse_request};

const REQUEST: &str = r#"{
  "shader_name": "effects\\ripple",
  "stages": [
    {"kind": "fragment", "source": "// [COMBO] {\"combo\":\"A\"}\nvoid main() {}"},
    {"kind": "vertex", "source": "void main() {}"}
  ],
  "combos": [{"name": "A", "value": "1"}],
  "textures": [{"slot": 0, "enabled": true, "format": "rgba8"}],
  "cache_policy": {"mode": "enabled", "scene_id": "scene-7"},
  "something_new": [1, 2, 3]
}"#;

fn assert_send_sync<T: Send + Sync>() {}

#[test]
fn the_public_model_can_cross_threads() {
    assert_send_sync::<ValidRequest>();
    assert_send_sync::<Reflection>();
    assert_send_sync::<Metadata>();
    assert_send_sync::<wm_shader::ShaderError>();
}

fn key_for(request: &ValidRequest) -> String {
    let combos: Vec<Combo> = request.combos().to_vec();
    let stages: Vec<StageKeyInput> = request
        .stages()
        .iter()
        .map(|s| StageKeyInput { kind: s.kind, preprocessed: "pre", translated_glsl: "glsl" })
        .collect();
    program_key(&ProgramKeyInput { request, effective_combos: &combos, stages: &stages })
}

fn sample_reflection() -> Reflection {
    let layout = layout_std140(&[
        MemberDecl { name: "g_Time".into(), ty: UniformType::parse("float").unwrap(), array: None },
        MemberDecl { name: "g_Bones".into(), ty: UniformType::parse("mat4x3").unwrap(), array: Some(4) },
    ])
    .unwrap();
    Reflection {
        descriptor_bindings: vec![DescriptorBinding {
            name: "GlobalUniforms".into(),
            set: 0,
            binding: 0,
            descriptor: DescriptorKind::UniformBuffer,
            stages: StageMask::BOTH,
            count: 1,
        }],
        uniform_blocks: vec![UniformBlock {
            name: "GlobalUniforms".into(),
            set: 0,
            binding: 0,
            size: layout.size,
            members: layout.members,
        }],
        vertex_inputs: vec![VertexInput {
            name: "a_Position".into(),
            location: 0,
            format: VertexFormat::new(VertexScalar::Float, 3).unwrap(),
        }],
        active_texture_slots: BTreeSet::from([0]),
    }
}

fn sample_metadata() -> Metadata {
    Metadata {
        combos: vec![ComboEntry { name: "A".into(), value: "1".into() }],
        default_uniforms: vec![DefaultUniform { name: "g_X".into(), value: UniformValue::Vec3([0.1, 0.2, 0.3]) }],
        ..Metadata::default()
    }
}

#[test]
fn documents_and_keys_are_byte_identical_across_200_calls_on_8_threads() {
    let request = Arc::new(parse_request(REQUEST).unwrap());
    let expected = (
        key_for(&request),
        sample_reflection().to_json(),
        sample_metadata().to_json().unwrap(),
        wm_shader::identity::compiler_identity().to_string(),
    );
    let expected = Arc::new(expected);
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let request = Arc::clone(&request);
            let expected = Arc::clone(&expected);
            thread::spawn(move || {
                for _ in 0..200 {
                    assert_eq!(key_for(&request), expected.0);
                    assert_eq!(sample_reflection().to_json(), expected.1);
                    assert_eq!(sample_metadata().to_json().unwrap(), expected.2);
                    assert_eq!(wm_shader::identity::compiler_identity(), expected.3);
                }
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap();
    }
}

#[test]
fn a_request_read_from_json_is_normalised_and_ready_for_keying() {
    let request = parse_request(REQUEST).unwrap();
    assert_eq!(request.shader_name(), "effects/ripple");
    assert_eq!(request.stages()[0].kind, StageKind::Fragment, "request order is kept");
    assert_eq!(request.stage(StageKind::Vertex).source, "void main() {}");
    let key = key_for(&request);
    assert_eq!(key.len(), 32);

    // The same request with the optional defaults spelled out reads to the same value and key.
    let spelled_out = REQUEST.replace(
        r#""something_new": [1, 2, 3]"#,
        r#""target": "metal_msl", "properties": [], "something_new": 0"#,
    );
    assert_eq!(parse_request(&spelled_out).unwrap(), request);
    assert_eq!(key_for(&parse_request(&spelled_out).unwrap()), key);
}

#[test]
fn the_documents_of_a_small_program_parse_with_the_crates_own_reader() {
    for text in [sample_reflection().to_json(), sample_metadata().to_json().unwrap()] {
        wm_shader::json::parse(&text).unwrap();
        assert!(!text.contains(char::is_whitespace), "compact: {text}");
    }
}
