// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The read uniforms, through the whole pipeline (Wallpaper Engine's dialect, legalized and read
//! by naga) and on Wallpaper Engine's own generic image shader when it is installed.

use std::collections::BTreeSet;

use crate::dialect::tests::corpus::{Layered, engine_combos, present_textures, shaders_root};
use crate::pipeline::tests::support::{Req, texture};
use crate::pipeline::{CompiledProgram, compile};
use crate::request::{Combo, ShaderRequest, Stage, StageKind};

const DECLARATIONS: &str = "\
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_ModelMatrix;
uniform vec3 g_EyePosition;
uniform float g_Amount;
uniform float g_Unused;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
";

const PLAIN_FRAGMENT: &str = "\
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
";

fn program(vertex: &str, fragment: &str) -> CompiledProgram {
    Req::new(vertex, fragment).texture(texture(0)).ok()
}

/// The uniforms a vertex stage with `helpers` and `body` reads, over the plain fragment stage.
fn reads(helpers: &str, body: &str) -> BTreeSet<String> {
    let vertex = format!("{DECLARATIONS}{helpers}\nvoid main() {{\n{body}\n  v_TexCoord = a_TexCoord;\n}}\n");
    program(&vertex, PLAIN_FRAGMENT).reflection.read_uniforms.expect("the analysis answers")
}

fn names(list: &[&str]) -> BTreeSet<String> {
    list.iter().map(|n| (*n).to_string()).collect()
}

const PLACE: &str = "  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);";

#[test]
fn a_value_computed_from_a_uniform_and_never_used_does_not_read_it() {
    // genericimage4.vert forms the view direction whatever its combos and uses it only to light.
    let body = format!(
        "{PLACE}\n  vec4 worldPos = mul(vec4(a_Position, 1.0), g_ModelMatrix);\n  vec3 viewDir = g_EyePosition - worldPos.xyz;"
    );
    assert_eq!(reads("", &body), names(&["g_ModelViewProjectionMatrix"]));
    // A declaration nothing names is not read either.
    assert!(!reads("", PLACE).contains("g_Unused"));
}

#[test]
fn a_uniform_that_reaches_an_output_is_read_through_variables_and_swizzles() {
    let body = "  vec4 worldPos = mul(vec4(a_Position, 1.0), g_ModelMatrix);\n  vec3 viewDir = g_EyePosition - worldPos.xyz;\n\
                \x20 vec4 p = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n  p.x += viewDir.y * g_Amount;\n  gl_Position = p;";
    assert_eq!(reads("", body), names(&["g_EyePosition", "g_ModelMatrix", "g_ModelViewProjectionMatrix", "g_Amount"]));
}

#[test]
fn a_varying_written_from_a_uniform_is_read() {
    let vertex = format!(
        "{DECLARATIONS}varying vec3 v_Eye;\nvoid main() {{\n{PLACE}\n  v_TexCoord = a_TexCoord;\n  v_Eye = g_EyePosition;\n}}\n"
    );
    let fragment = "varying vec2 v_TexCoord;\nvarying vec3 v_Eye;\nvoid main() { gl_FragColor = vec4(v_Eye, 1.0); }\n";
    let read = program(&vertex, fragment).reflection.read_uniforms.expect("answered");
    assert!(read.contains("g_EyePosition"), "{read:?}");
}

#[test]
fn a_uniform_that_only_decides_a_branch_is_read() {
    // Whether a write runs is part of what the stage produces, even when both branches are empty.
    let body = format!("{PLACE}\n  if (g_Amount > 0.5) {{ }}");
    assert!(reads("", &body).contains("g_Amount"));
    let looped = format!("{PLACE}\n  for (int i = 0; i < int(g_Amount); ++i) {{ }}");
    assert!(reads("", &looped).contains("g_Amount"));
}

#[test]
fn a_helper_reads_what_its_used_result_and_written_parameters_carry() {
    let helpers = "float lift() { return g_Amount; }\nfloat ignored() { return g_EyePosition.x; }\n\
                   void place(out vec4 p) { p = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }\n\
                   void spare(out vec3 v) { v = g_EyePosition; }\n";
    let body = "  vec4 p;\n  place(p);\n  p.y += lift();\n  float unused = ignored();\n  vec3 v;\n  spare(v);\n  gl_Position = p;";
    assert_eq!(reads(helpers, body), names(&["g_Amount", "g_ModelViewProjectionMatrix"]));
    // A parameter the helper uses reads its argument.
    let scaled = "vec4 scaled(vec4 p, float k) { return p * k; }\n";
    let body = format!("{PLACE}\n  gl_Position = scaled(gl_Position, g_Amount);");
    assert!(reads(scaled, &body).contains("g_Amount"));
}

#[test]
fn a_uniform_that_decides_a_discard_is_read() {
    let fragment = "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\nuniform float g_Edge;\nuniform float g_Spare;\n\
                    void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); float s = g_Spare; if (c.a < g_Edge) discard; gl_FragColor = c; }\n";
    let vertex = format!("{DECLARATIONS}void main() {{\n{PLACE}\n  v_TexCoord = a_TexCoord;\n}}\n");
    let read = program(&vertex, fragment).reflection.read_uniforms.expect("answered");
    assert!(read.contains("g_Edge"), "{read:?}");
    assert!(!read.contains("g_Spare"), "{read:?}");
}

#[test]
fn the_program_reads_what_either_stage_reads_and_the_document_carries_it() {
    let vertex = format!("{DECLARATIONS}void main() {{\n{PLACE}\n  v_TexCoord = a_TexCoord;\n}}\n");
    let fragment = "varying vec2 v_TexCoord;\nuniform float g_Amount;\nvoid main() { gl_FragColor = vec4(v_TexCoord, g_Amount, 1.0); }\n";
    let p = program(&vertex, fragment);
    assert_eq!(p.reflection.read_uniforms, Some(names(&["g_Amount", "g_ModelViewProjectionMatrix"])));
    let text = p.reflection.to_json();
    assert!(text.contains(r#","read_uniforms":["g_Amount","g_ModelViewProjectionMatrix"]"#), "{text}");
    // Every read member is a declared member of the block.
    let declared: BTreeSet<String> =
        p.reflection.uniform_blocks.iter().flat_map(|b| b.members.iter().map(|m| m.name.clone())).collect();
    assert!(p.reflection.read_uniforms.as_ref().unwrap().is_subset(&declared));
}

// ---- Wallpaper Engine's own generic image shader, when installed ----

fn compile_shipped(shader: &str, combos: &[(&str, &str)]) -> Option<CompiledProgram> {
    let root = shaders_root()?;
    let read = |ext: &str| std::fs::read_to_string(root.join(format!("{shader}.{ext}"))).ok();
    let (vertex, fragment) = (read("vert")?, read("frag")?);
    let mut all: Vec<Combo> = engine_combos();
    all.extend(combos.iter().map(|(n, v)| Combo { name: (*n).into(), value: (*v).into() }));
    let request = ShaderRequest {
        shader_name: shader.into(),
        stages: vec![Stage { kind: StageKind::Vertex, source: vertex }, Stage { kind: StageKind::Fragment, source: fragment }],
        combos: all,
        textures: present_textures(),
        ..ShaderRequest::default()
    }
    .validate()
    .ok()?;
    compile(&request, &Layered { dirs: vec![root] }).ok()
}

#[test]
fn the_generic_image_card_reads_the_eye_only_when_it_is_lit() {
    let Some(plain) = compile_shipped("genericimage4", &[]) else {
        eprintln!("skipped: the shipped genericimage4 is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let read = plain.reflection.read_uniforms.expect("the analysis answers for the plain card");
    let declared: BTreeSet<String> =
        plain.reflection.uniform_blocks.iter().flat_map(|b| b.members.iter().map(|m| m.name.clone())).collect();
    assert!(declared.contains("g_EyePosition") && declared.contains("g_ModelMatrix"), "{declared:?}");
    assert!(read.contains("g_ModelViewProjectionMatrix"), "{read:?}");
    assert!(!read.contains("g_EyePosition") && !read.contains("g_ModelMatrix"), "{read:?}");
    let Some(lit) = compile_shipped("genericimage4", &[("LIGHTING", "1")]) else {
        eprintln!("skipped: the lit genericimage4 did not compile");
        return;
    };
    let read = lit.reflection.read_uniforms.expect("the analysis answers for the lit card");
    assert!(read.contains("g_EyePosition") && read.contains("g_ModelMatrix"), "{read:?}");
}
