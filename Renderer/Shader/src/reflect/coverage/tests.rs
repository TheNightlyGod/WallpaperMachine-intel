// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The coverage facts, through the whole pipeline (Wallpaper Engine's dialect, legalized and
//! read by naga) and on Wallpaper Engine's own effect shaders when they are installed.

use std::path::{Path, PathBuf};

use crate::dialect::tests::corpus::{Layered, engine_combos, present_textures, shaders_root};
use crate::pipeline::tests::support::{Req, texture};
use crate::pipeline::{CompiledProgram, compile};
use crate::reflection::{ColourFactor, FragmentColour, PositionSource};
use crate::request::{Combo, ShaderRequest, Stage, StageKind};

const PLAIN_FRAGMENT: &str = "\
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
";

fn vertex_with(body: &str) -> String {
    format!(
        "uniform mat4 g_ModelViewProjectionMatrix;\nuniform mat4 g_ModelMatrix;\nuniform mat4 g_ViewProjectionMatrix;\n\
         uniform float g_Top;\nattribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n\
         void main() {{\n{body}\n  v_TexCoord = a_TexCoord;\n}}\n"
    )
}

fn program(vertex: &str, fragment: &str) -> CompiledProgram {
    Req::new(vertex, fragment).texture(texture(0)).ok()
}

fn position(body: &str) -> Option<PositionSource> {
    program(&vertex_with(body), PLAIN_FRAGMENT).reflection.vertex_position
}

fn through(matrix: &str) -> Option<PositionSource> {
    Some(PositionSource { input: "a_Position".into(), matrix: Some(matrix.into()) })
}

fn itself() -> Option<PositionSource> {
    Some(PositionSource { input: "a_Position".into(), matrix: None })
}

fn always_writes(body: &str) -> bool {
    let fragment = format!("varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\nuniform float g_Edge;\n{body}");
    program(&vertex_with("  gl_Position = vec4(a_Position, 1.0);"), &fragment).reflection.fragment_always_writes
}

// ---- the vertex position ----

#[test]
fn the_effect_forms_of_the_position_are_proven() {
    assert_eq!(position("  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);"), through("g_ModelViewProjectionMatrix"));
    assert_eq!(position("  gl_Position = vec4(a_Position, 1.0);"), itself());
    assert_eq!(position("  gl_Position = vec4(a_Position.xyz, 1.0);"), itself());
    assert_eq!(position("  gl_Position = vec4(a_Position.x, a_Position.y, a_Position.z, 1.0);"), itself());
}

#[test]
fn an_unmodified_copy_of_the_input_is_seen_through() {
    // spin.vert and transform.vert copy the input into a local first.
    assert_eq!(
        position("  vec3 position = a_Position;\n  gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);"),
        through("g_ModelViewProjectionMatrix")
    );
    assert_eq!(
        position("  vec3 position = a_Position;\n  vec4 p = vec4(position, 1.0);\n  gl_Position = p;"),
        itself()
    );
    assert_eq!(
        position("  mat4 m = g_ModelViewProjectionMatrix;\n  gl_Position = mul(vec4(a_Position, 1.0), m);"),
        through("g_ModelViewProjectionMatrix")
    );
}

#[test]
fn a_moved_vertex_is_not_proven() {
    for body in [
        // skew.vert: the copy is written again.
        "  vec3 position = a_Position;\n  position.x += g_Top;\n  gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);",
        "  gl_Position = mul(vec4(a_Position * 0.5, 1.0), g_ModelViewProjectionMatrix);",
        "  gl_Position = vec4(a_Position + vec3(g_Top, 0.0, 0.0), 1.0);",
        "  gl_Position = vec4(a_Position, 2.0);",
        "  gl_Position = vec4(a_Position.xy, 0.0, 1.0);",
        "  gl_Position = vec4(a_Position.yxz, 1.0);",
        "  gl_Position = vec4(a_TexCoord, 0.0, 1.0);",
        // The matrix on the right is its transpose.
        "  gl_Position = mul(g_ModelViewProjectionMatrix, vec4(a_Position, 1.0));",
        // A product of matrices is not one uniform.
        "  gl_Position = mul(vec4(a_Position, 1.0), mul(g_ModelMatrix, g_ViewProjectionMatrix));",
        // Written twice, conditionally, or after a possible return.
        "  gl_Position = vec4(a_Position, 1.0);\n  gl_Position.x += g_Top;",
        "  gl_Position = vec4(a_Position, 1.0);\n  if (g_Top > 0.5) gl_Position = vec4(0.0, 0.0, 0.0, 1.0);",
        "  if (g_Top > 0.5) { gl_Position = vec4(a_Position, 1.0); } else { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }",
        "  if (g_Top > 0.5) { v_TexCoord = a_TexCoord; return; }\n  gl_Position = vec4(a_Position, 1.0);",
        // The local is read before it is written.
        "  vec3 position;\n  gl_Position = vec4(position, 1.0);\n  position = a_Position;",
    ] {
        assert_eq!(position(body), None, "{body}");
    }
}

#[test]
fn a_position_written_through_a_function_parameter_is_not_proven() {
    let vertex = "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n\
                  void place(out vec4 p) { p = vec4(a_Position, 1.0); }\n\
                  void main() { place(gl_Position); v_TexCoord = a_TexCoord; }\n";
    assert_eq!(program(vertex, PLAIN_FRAGMENT).reflection.vertex_position, None);
}

#[test]
fn gaussian_kernels_selected_by_combos_keep_the_position() {
    // blur_gaussian.vert's shape: the position first, then one of three kernels by `#if`.
    let vertex = "\
uniform vec2 g_Scale;
uniform vec4 g_Texture0Resolution;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if KERNEL == 0
varying vec2 v_TexCoord[13];
#endif
#if KERNEL == 1
varying vec2 v_TexCoord[7];
#endif
#if KERNEL == 2
varying vec2 v_TexCoord[3];
#endif
void main() {
	gl_Position = vec4(a_Position, 1.0);
#if VERTICAL
	float offsetX = 0.0f;
	float offsetY = g_Scale.y / g_Texture0Resolution.w;
#else
	float offsetX = g_Scale.x / g_Texture0Resolution.z;
	float offsetY = 0.0f;
#endif
#if KERNEL == 0
	for (int i = 0; i < 13; ++i) v_TexCoord[i] = a_TexCoord + vec2(offsetX, offsetY) * float(i - 6);
#endif
#if KERNEL == 1
	v_TexCoord[0] = vec2(a_TexCoord.x - offsetX * 3.0, a_TexCoord.y - offsetY * 3.0);
	v_TexCoord[3] = a_TexCoord;
	v_TexCoord[6] = vec2(a_TexCoord.x + offsetX * 3.0, a_TexCoord.y + offsetY * 3.0);
#endif
#if KERNEL == 2
	v_TexCoord[0] = vec2(a_TexCoord.x - offsetX, a_TexCoord.y - offsetY);
	v_TexCoord[1] = a_TexCoord;
	v_TexCoord[2] = vec2(a_TexCoord.x + offsetX, a_TexCoord.y + offsetY);
#endif
}
";
    let fragment = "\
#if KERNEL == 0
varying vec2 v_TexCoord[13];
#endif
#if KERNEL == 1
varying vec2 v_TexCoord[7];
#endif
#if KERNEL == 2
varying vec2 v_TexCoord[3];
#endif
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord[1]); }
";
    for kernel in ["0", "1", "2"] {
        for vertical in ["0", "1"] {
            let p = Req::new(vertex, fragment).texture(texture(0)).combo("KERNEL", kernel).combo("VERTICAL", vertical).ok();
            assert_eq!(p.reflection.vertex_position, itself(), "KERNEL {kernel} VERTICAL {vertical}");
            assert!(p.reflection.fragment_always_writes, "KERNEL {kernel} VERTICAL {vertical}");
        }
    }
}

// ---- the fragment stage ----

#[test]
fn a_fragment_that_cannot_discard_always_writes() {
    assert!(always_writes("void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }"));
    assert!(always_writes(
        "void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); if (c.a < g_Edge) { c = CAST4(0.0); } gl_FragColor = c; }"
    ));
    // A shader that returns early still writes its colour output (whatever it held).
    assert!(always_writes("void main() { gl_FragColor = CAST4(1.0); if (g_Edge > 0.5) return; gl_FragColor = CAST4(0.5); }"));
}

#[test]
fn a_fragment_that_can_discard_does_not() {
    for body in [
        "void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); if (c.a < g_Edge) discard; gl_FragColor = c; }",
        // The dialect's `clip` discards below zero.
        "void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); clip(c.a - g_Edge); gl_FragColor = c; }",
        // In a helper the entry point calls.
        "void cut(float a) { if (a < 0.5) discard; }\nvoid main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); cut(c.a); gl_FragColor = c; }",
    ] {
        assert!(!always_writes(body), "{body}");
    }
}

#[test]
fn each_fact_belongs_to_its_own_stage_and_reaches_the_document() {
    let p = program(&vertex_with("  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);"), PLAIN_FRAGMENT);
    let text = p.reflection.to_json();
    assert!(
        text.contains(r#","vertex_position":{"input":"a_Position","matrix":"g_ModelViewProjectionMatrix"},"fragment_always_writes":true,"#),
        "{text}"
    );
    let itself = program(&vertex_with("  gl_Position = vec4(a_Position, 1.0);"), PLAIN_FRAGMENT).reflection.to_json();
    assert!(itself.contains(r#""vertex_position":{"input":"a_Position"}"#), "{itself}");
    // Not proven: the keys are absent, which a host reads as "load the target".
    let neither = program(
        &vertex_with("  gl_Position = vec4(a_Position * 0.5, 1.0);"),
        "varying vec2 v_TexCoord;\nvoid main() { if (v_TexCoord.x < 0.5) discard; gl_FragColor = CAST4(1.0); }\n",
    )
    .reflection
    .to_json();
    assert!(!neither.contains("vertex_position") && !neither.contains("fragment_always_writes"), "{neither}");
}

#[test]
fn a_renamed_input_is_reported_under_its_authors_name() {
    // A shader that writes one of its inputs reads a legalizer copy of it; the position input is
    // still named as the author wrote it, which is the name the mesh supplies it under.
    let vertex = "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n\
                  void main() { a_TexCoord *= 2.0; gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n";
    let p = program(vertex, PLAIN_FRAGMENT);
    assert_eq!(p.reflection.vertex_position, itself());
    assert!(p.reflection.vertex_inputs.iter().any(|i| i.name == "a_Position"));
}

// ---- the fragment colour ----

fn colour(fragment: &str) -> Option<FragmentColour> {
    program(&vertex_with("  gl_Position = vec4(a_Position, 1.0);"), fragment).reflection.fragment_colour
}

fn u(member: &str, component: u32) -> ColourFactor {
    ColourFactor::Uniform { member: member.into(), component }
}

fn k(value: f32) -> ColourFactor {
    ColourFactor::Constant { bits: value.to_bits() }
}

/// Wallpaper Engine's `flat.frag`, the shader of a solid layer, without `VERTEXCOLOR`.
const FLAT: &str = "\
uniform mediump float g_Alpha;
uniform mediump vec3 g_Color;
varying vec4 v_Color;
void main() {
	gl_FragColor = vec4(g_Color, g_Alpha);
#ifdef VERTEXCOLOR
	gl_FragColor *= v_Color.rgba;
#endif
}
";

#[test]
fn a_solid_layers_colour_is_its_uniforms() {
    let c = colour(FLAT).expect("flat.frag's colour is its two uniforms");
    assert_eq!(
        c.channels,
        [Some(vec![u("g_Color", 0)]), Some(vec![u("g_Color", 1)]), Some(vec![u("g_Color", 2)]), Some(vec![u("g_Alpha", 0)])]
    );
    let text = program(&vertex_with("  gl_Position = vec4(a_Position, 1.0);"), FLAT).reflection.to_json();
    assert!(
        text.contains(r#""fragment_colour":[[{"uniform":"g_Color","component":0}],[{"uniform":"g_Color","component":1}],[{"uniform":"g_Color","component":2}],[{"uniform":"g_Alpha","component":0}]]"#),
        "{text}"
    );
}

#[test]
fn products_splats_swizzles_and_constants_are_followed() {
    let fragment = "uniform float g_Alpha;\nuniform vec4 g_Color4;\nuniform float g_Brightness;\n\
                    void main() { vec4 c = g_Color4.bgra * vec4(CAST3(g_Brightness), 0.5); gl_FragColor = c * g_Alpha; }\n";
    let c = colour(fragment).expect("a product of uniforms and constants");
    assert_eq!(c.channels[0], Some(vec![u("g_Color4", 2), u("g_Brightness", 0), u("g_Alpha", 0)]));
    assert_eq!(c.channels[2], Some(vec![u("g_Color4", 0), u("g_Brightness", 0), u("g_Alpha", 0)]));
    assert_eq!(c.channels[3], Some(vec![u("g_Color4", 3), k(0.5), u("g_Alpha", 0)]));
    // One component of a once-written local, and a literal channel.
    let c = colour("uniform vec4 g_Color4;\nvoid main() { vec4 c = g_Color4; gl_FragColor = vec4(c.r, 1.0, 0.0, c.a); }\n")
        .expect("components of a copy");
    assert_eq!(c.channels, [Some(vec![u("g_Color4", 0)]), Some(vec![k(1.0)]), Some(vec![k(0.0)]), Some(vec![u("g_Color4", 3)])]);
}

#[test]
fn a_channel_that_is_not_a_product_is_not_proven() {
    // Vertex colour, a texture, a sum, a function of a uniform: the alpha is not proven, so the
    // fact is absent.
    for fragment in [
        "uniform float g_Alpha;\nvarying vec4 v_Color;\nvoid main() { gl_FragColor = vec4(1.0, 1.0, 1.0, g_Alpha) * v_Color; }\n",
        "uniform float g_Alpha;\nvarying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\n\
         void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); gl_FragColor = vec4(c.rgb, c.a * g_Alpha); }\n",
        "uniform float g_Alpha;\nvoid main() { gl_FragColor = vec4(0.0, 0.0, 0.0, g_Alpha + 0.0); }\n",
        "uniform float g_Alpha;\nvoid main() { gl_FragColor = vec4(0.0, 0.0, 0.0, abs(g_Alpha)); }\n",
        // Written twice (flat.frag with VERTEXCOLOR), or conditionally.
        "uniform float g_Alpha;\nuniform vec3 g_Color;\nvarying vec4 v_Color;\n\
         void main() { gl_FragColor = vec4(g_Color, g_Alpha); gl_FragColor *= v_Color; }\n",
        "uniform float g_Alpha;\nuniform float g_Edge;\n\
         void main() { gl_FragColor = vec4(0.0, 0.0, 0.0, g_Alpha); if (g_Edge > 0.5) gl_FragColor.a = 1.0; }\n",
        // An array element is not one member.
        "uniform vec4 g_Colors[2];\nvoid main() { gl_FragColor = g_Colors[0]; }\n",
    ] {
        assert_eq!(colour(fragment), None, "{fragment}");
    }
    // The alpha alone decides whether the fact is written: an unproven colour channel stays
    // `None` beside a proven alpha.
    let c = colour("uniform float g_Alpha;\nvarying vec4 v_Color;\nvoid main() { gl_FragColor = vec4(v_Color.rgb, g_Alpha); }\n")
        .expect("the alpha is a uniform");
    assert_eq!(c.channels, [None, None, None, Some(vec![u("g_Alpha", 0)])]);
    let text = program(
        &vertex_with("  gl_Position = vec4(a_Position, 1.0);"),
        "varying vec4 v_Color;\nvoid main() { gl_FragColor = v_Color; }\n",
    )
    .reflection
    .to_json();
    assert!(!text.contains("fragment_colour"), "{text}");
}

#[test]
fn the_installed_solid_layer_shader_is_proven() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shaders folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let read = |ext: &str| std::fs::read_to_string(root.join(format!("flat.{ext}"))).ok();
    let (Some(vertex), Some(fragment)) = (read("vert"), read("frag")) else {
        eprintln!("skipped: flat.vert or flat.frag is absent");
        return;
    };
    let request = ShaderRequest {
        shader_name: "flat".into(),
        stages: vec![Stage { kind: StageKind::Vertex, source: vertex }, Stage { kind: StageKind::Fragment, source: fragment }],
        combos: engine_combos(),
        textures: present_textures(),
        ..ShaderRequest::default()
    }
    .validate()
    .expect("a valid request");
    let includes = Layered { dirs: vec![root.clone()] };
    let p = compile(&request, &includes).expect("flat compiles");
    assert_eq!(p.reflection.fragment_colour.map(|c| c.channels[3].clone()), Some(Some(vec![u("g_Alpha", 0)])));
}

// ---- Wallpaper Engine's own effects, when installed ----

/// `SceneAssets/effects/<effect>/shaders/` of the installed assets.
fn effects_root() -> Option<PathBuf> {
    let root = shaders_root()?.parent()?.join("effects");
    root.is_dir().then_some(root)
}

fn compile_effect(root: &Path, effect: &str, shader: &str, combos: &[(&str, &str)]) -> Option<CompiledProgram> {
    let dir = root.join(effect).join("shaders");
    let read = |ext: &str| std::fs::read_to_string(dir.join(format!("{shader}.{ext}"))).ok();
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
    let includes = Layered { dirs: vec![dir, shaders_root()?] };
    compile(&request, &includes).ok()
}

#[test]
fn wallpaper_engines_own_effects_are_proven_where_they_draw_the_card_as_given() {
    let Some(root) = effects_root() else {
        eprintln!("skipped: the shipped effects folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    // (effect, shader, combos, proven): the card drawn unmoved through the matrix or as given,
    // and the ones that move its corners.
    let cases: &[(&str, &str, &[(&str, &str)], Option<bool>)] = &[
        ("waterwaves", "effects/waterwaves", &[], Some(true)),
        ("tint", "effects/tint", &[], Some(true)),
        ("blur", "effects/blur_gaussian", &[("KERNEL", "0")], Some(false)),
        ("blur", "effects/blur_gaussian", &[("KERNEL", "2"), ("VERTICAL", "1")], Some(false)),
        ("spin", "effects/spin", &[("ELLIPTICAL", "1")], Some(true)),
        // `MODE` 0 moves the texture coordinates, 1 the corners.
        ("skew", "effects/skew", &[("MODE", "0")], Some(true)),
        ("skew", "effects/skew", &[("MODE", "1")], None),
        ("transform", "effects/transform", &[("MODE", "0")], Some(true)),
        ("transform", "effects/transform", &[("MODE", "1")], None),
        ("foliagesway", "effects/foliagesway", &[("MODE", "0")], Some(true)),
        ("foliagesway", "effects/foliagesway", &[("MODE", "1")], None),
    ];
    let mut checked = 0;
    for (effect, shader, combos, proven) in cases {
        let Some(p) = compile_effect(&root, effect, shader, combos) else {
            eprintln!("skipped: {effect}/{shader} is absent or did not compile");
            continue;
        };
        checked += 1;
        let want = proven.map(|through_matrix| PositionSource {
            input: "a_Position".into(),
            matrix: through_matrix.then(|| "g_ModelViewProjectionMatrix".into()),
        });
        assert_eq!(p.reflection.vertex_position, want, "{effect}/{shader} {combos:?}");
        assert!(p.reflection.fragment_always_writes, "{effect}/{shader}: no shipped effect discards");
    }
    eprintln!("coverage facts checked on {checked} shipped effect programs");
}
