// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Amendments 1, D4: four HLSL idioms the layer accepts (c1 R58, R52 and R53 with c2 R62, R11, R67),
//! pinned so a regression test exists. Each check compiles the program through to Metal text.

use std::fs;

use super::support::*;
use crate::dialect::tests::corpus::{Layered, combo_sets, present_textures, shaders_root};
use crate::request::{Combo, ShaderRequest, Stage};
use crate::request::StageKind;

const V: &str = "attribute vec3 a_Position; attribute vec2 a_Coord; varying vec2 v_Coord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_Coord = a_Coord; }";

fn msl(p: &crate::pipeline::CompiledProgram) -> String {
    p.stage(StageKind::Fragment).unwrap().payload.msl_source.clone()
}

#[test]
fn a_float_argument_to_an_int_parameter_converts_when_the_callee_is_unique() {
    let f = "varying vec2 v_Coord;\nint bucket(in int n) { return n * 2; }\nvoid main() { float u = v_Coord.x; gl_FragColor = CAST4(float(bucket(u * 8.0))); }";
    let p = ok(V, f);
    assert!(glsl_of(&p, StageKind::Fragment).contains("bucket(int(u * 8.0))"), "{}", glsl_of(&p, StageKind::Fragment));
    // In the Metal text a float-to-int conversion sits at the call.
    let text = msl(&p);
    let call = text.lines().find(|l| l.contains("= bucket(")).expect("the call");
    assert!(call.contains("naga_f2i32(") || call.contains("static_cast<int>"), "{call}");
    // The conversion truncates toward zero: the written conversion is `int(...)`, which does.
    // With a second overload of the same arity differing in that position, nothing is converted.
    let f = "varying vec2 v_Coord;\nint bucket(in int n) { return n * 2; }\nint bucket(in float n) { return 7; }\nvoid main() { float u = v_Coord.x; gl_FragColor = CAST4(float(bucket(u * 8.0))); }";
    let p = ok(V, f);
    let glsl = glsl_of(&p, StageKind::Fragment);
    assert!(glsl.contains("bucket(u * 8.0)") && !glsl.contains("bucket(int("), "{glsl}");
}

#[test]
fn a_number_is_a_condition_and_compares_with_the_zero_of_its_type() {
    for value in 0..=4 {
        // An object-like macro value as a condition, the value coming from a combo.
        let f = "varying vec2 v_Coord;\nvoid main() { float a = v_Coord.x; float b = v_Coord.y; float c = MODE ? a : b; gl_FragColor = CAST4(c); }";
        let p = Req::new(V, f).combo("MODE", &value.to_string()).ok();
        let glsl = glsl_of(&p, StageKind::Fragment);
        assert!(glsl.contains(&format!("{value} != 0 ? a : b")), "MODE={value}: {glsl}");
        // Integer arithmetic as a condition.
        let f = "varying vec2 v_Coord;\nvoid main() { int n = N; float c = 0.0; if (n - 4) { c = 1.0; } gl_FragColor = CAST4(c); }";
        let p = Req::new(V, f).combo("N", &value.to_string()).ok();
        let glsl = glsl_of(&p, StageKind::Fragment);
        assert!(glsl.contains("n - 4 != 0"), "N={value}: {glsl}");
        assert!(msl(&p).contains("!= 0") || msl(&p).contains("!= 0u") || msl(&p).contains("n_1"), "N={value}");
    }
    // A literal define, as the check states it.
    let p = ok(V, "#define MODE 2\nvarying vec2 v_Coord;\nvoid main() { float a = v_Coord.x; float b = v_Coord.y; float c = MODE ? a : b; gl_FragColor = CAST4(c); }");
    assert!(glsl_of(&p, StageKind::Fragment).contains("2 != 0 ? a : b"));
    // A float condition compares with 0.0.
    let p = ok(V, "varying vec2 v_Coord;\nvoid main() { float x = v_Coord.x; float c = 0.0; if (x) { c = 1.0; } gl_FragColor = CAST4(c); }");
    assert!(glsl_of(&p, StageKind::Fragment).contains("x != 0.0"), "{}", glsl_of(&p, StageKind::Fragment));
}

#[test]
fn the_cast_macros_take_any_scalar_expression_including_an_unsigned_remainder() {
    let f = "varying vec2 v_Coord;\nvoid main() { uint k = uint(v_Coord.x * 10.0); float f = CASTF(k % 3u); int i = CASTI(v_Coord.y * 4.0); uint u = CASTU(v_Coord.x); gl_FragColor = CAST4(f + float(i) + float(u)); }";
    let p = ok(V, f);
    let glsl = glsl_of(&p, StageKind::Fragment);
    // The remainder stays an integer one and the result is converted (c1 R46).
    assert!(glsl.contains("float(k % 3u)") && glsl.contains("int(v_Coord.y * 4.0)") && glsl.contains("uint(v_Coord.x)"), "{glsl}");
    assert!(msl(&p).contains("% 3u") || msl(&p).contains("% metal::select"), "{}", msl(&p));
    // Every stage has them, the vertex stage included.
    let v = "attribute vec3 a_Position; void main() { uint k = uint(a_Position.x); gl_Position = vec4(a_Position, CASTF(k % 3u)); }";
    assert!(ok(v, "void main() { gl_FragColor = CAST4(1.0); }").stage(StageKind::Vertex).is_some());
}

const SAMPLER_FORMS: [(&str, &str); 6] = [
    ("DECLARE_SAMPLER2D_PARAMETER(t), in float w", "MAKE_SAMPLER2D_ARGUMENT(g_Texture1), 0.5"),
    ("in float w, DECLARE_SAMPLER2D_PARAMETER(t)", "0.5, MAKE_SAMPLER2D_ARGUMENT(g_Texture1)"),
    ("in float w, DECLARE_SAMPLER2D_PARAMETER(t), out float o", "0.5, MAKE_SAMPLER2D_ARGUMENT(g_Texture1), r"),
    ("inout float io, DECLARE_SAMPLER2D_PARAMETER(t), in float w", "r, MAKE_SAMPLER2D_ARGUMENT(g_Texture1), 0.5"),
    ("out float o, in float w, DECLARE_SAMPLER2D_PARAMETER(t)", "r, 0.5, MAKE_SAMPLER2D_ARGUMENT(g_Texture1)"),
    ("DECLARE_SAMPLER2D_PARAMETER(t)", "MAKE_SAMPLER2D_ARGUMENT(g_Texture1)"),
];

#[test]
fn the_sampler_parameter_macro_is_one_whole_entry_at_any_position() {
    for (params, args) in SAMPLER_FORMS {
        let writes = if params.contains("out float o") { "o = 1.0;" } else if params.contains("inout") { "io += 1.0;" } else { "" };
        let weight = if params.contains("float w") { "w" } else { "1.0" };
        let f = format!(
            "varying vec2 v_Coord;\nuniform sampler2D g_Texture1;\nfloat shade({params}) {{ {writes} return texSample2D(t, v_Coord).r * {weight}; }}\nvoid main() {{ float r = 0.0; gl_FragColor = CAST4(shade({args})); }}"
        );
        let p = Req::new(V, &f).texture(texture(1)).ok();
        assert_eq!(p.reflection.active_texture_slots.iter().copied().collect::<Vec<_>>(), [1], "{params}");
        assert!(p.reflection.descriptor_bindings.iter().any(|d| d.name == "g_Texture1"), "{params}");
        // The qualifiers survive on the other parameters.
        let glsl = glsl_of(&p, StageKind::Fragment);
        for q in ["out float o", "inout float io", "in float w"] {
            if params.contains(q) {
                assert!(glsl.contains(q), "{params}: {glsl}");
            }
        }
    }
}

/// Real shaders of the shipped tree that use the cast macros with morphing on (a `uint` remainder and
/// a morph map read in the vertex stage). Skips with a message when the tree is absent.
#[test]
fn the_shipped_morph_target_and_fur_effects_compile_with_morphing_on() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let includes = Layered { dirs: vec![root.clone()] };
    let mut compiled = 0;
    for name in ["shadowcaster", "shadowcasterfur4", "fur4", "generic4", "genericimage4"] {
        let (Ok(vertex), Ok(fragment)) = (fs::read_to_string(root.join(format!("{name}.vert"))), fs::read_to_string(root.join(format!("{name}.frag")))) else {
            eprintln!("skipped {name}: not in the shipped tree");
            continue;
        };
        for normals in ["0", "1"] {
            let mut combos: Vec<Combo> = combo_sets().into_iter().find(|(n, _)| *n == "no combos").unwrap().1;
            combos.retain(|c| c.name != "MORPHING" && c.name != "MORPHING_NORMALS");
            combos.push(Combo { name: "MORPHING".into(), value: "1".into() });
            combos.push(Combo { name: "MORPHING_NORMALS".into(), value: normals.into() });
            let request = ShaderRequest {
                shader_name: name.into(),
                stages: vec![Stage { kind: StageKind::Vertex, source: vertex.clone() }, Stage { kind: StageKind::Fragment, source: fragment.clone() }],
                combos,
                textures: present_textures(),
                ..ShaderRequest::default()
            }
            .validate()
            .unwrap();
            let p = match crate::pipeline::compile(&request, &includes) {
                Ok(p) => p,
                Err(e) => panic!("{name} with morphing on: {e}"),
            };
            assert!(p.combos.iter().any(|c| c.name == "MORPHING" && c.value == "1"), "{name}");
            compiled += 1;
        }
    }
    eprintln!("morphing effects compiled: {compiled}");
}

/// The volumetric light shader reads the depth of the light volume's back faces through the
/// dialect's back buffer, the single-sample scene depth through `texLoad2D` and the shadow atlas
/// through a comparison sampler (E-D8); every combination of its switches compiles to Metal.
#[test]
fn the_shipped_volumetric_light_shader_compiles_in_every_variant() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let includes = Layered { dirs: vec![root.clone()] };
    let (Ok(vertex), Ok(fragment)) = (fs::read_to_string(root.join("volumetricsfront.vert")), fs::read_to_string(root.join("volumetricsfront.frag"))) else {
        eprintln!("skipped: volumetricsfront is not in the shipped tree");
        return;
    };
    let mut compiled = 0;
    for shadow in ["0", "1"] {
        for point in ["0", "1"] {
            for ms in ["0", "1"] {
                let mut combos: Vec<Combo> = combo_sets().into_iter().find(|(n, _)| *n == "no combos").unwrap().1;
                combos.retain(|c| !["SHADOW", "POINTLIGHT", "BACKBUFFER_MS", "QUALITY"].contains(&c.name.as_str()));
                for (n, v) in [("SHADOW", shadow), ("POINTLIGHT", point), ("BACKBUFFER_MS", ms), ("QUALITY", "2")] {
                    combos.push(Combo { name: n.into(), value: v.into() });
                }
                let request = ShaderRequest {
                    shader_name: "volumetricsfront".into(),
                    stages: vec![Stage { kind: StageKind::Vertex, source: vertex.clone() }, Stage { kind: StageKind::Fragment, source: fragment.clone() }],
                    combos,
                    textures: present_textures(),
                    ..ShaderRequest::default()
                }
                .validate()
                .unwrap();
                if let Err(e) = crate::pipeline::compile(&request, &includes) {
                    panic!("volumetricsfront SHADOW={shadow} POINTLIGHT={point} BACKBUFFER_MS={ms}: {e}");
                }
                compiled += 1;
            }
        }
    }
    assert_eq!(compiled, 8);
}

/// A shipped program compiled with the "no combos" set plus `extra`, or `None` with a message when
/// the shipped tree or the program is absent.
fn shipped(name: &str, extra: &[(&str, &str)]) -> Option<crate::pipeline::CompiledProgram> {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return None;
    };
    let (Ok(vertex), Ok(fragment)) = (fs::read_to_string(root.join(format!("{name}.vert"))), fs::read_to_string(root.join(format!("{name}.frag")))) else {
        eprintln!("skipped: {name} is not in the shipped tree");
        return None;
    };
    let mut combos: Vec<Combo> = combo_sets().into_iter().find(|(n, _)| *n == "no combos").unwrap().1;
    combos.retain(|c| !extra.iter().any(|(n, _)| c.name == *n));
    combos.extend(extra.iter().map(|(n, v)| Combo { name: (*n).into(), value: (*v).into() }));
    let request = ShaderRequest {
        shader_name: name.into(),
        stages: vec![Stage { kind: StageKind::Vertex, source: vertex }, Stage { kind: StageKind::Fragment, source: fragment }],
        combos,
        textures: present_textures(),
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap();
    let includes = Layered { dirs: vec![root] };
    Some(crate::pipeline::compile(&request, &includes).unwrap_or_else(|e| panic!("{name} {extra:?}: {e}")))
}

/// Wallpaper Engine leaves `GLSL` undefined (probe T5), so the shipped alpha-to-coverage branch
/// never takes its `#if GLSL` discard: coverage alone decides what is kept.
#[test]
fn the_alpha_to_coverage_branch_of_generic4_has_no_discard() {
    let Some(p) = shipped("generic4", &[("ALPHATOCOVERAGE", "1")]) else { return };
    let glsl = glsl_of(&p, StageKind::Fragment);
    assert!(!glsl.contains("discard"), "{glsl}");
    assert!(!msl(&p).contains("discard_fragment"), "{}", msl(&p));
}

/// At 4x, WE preserves a sharpened quarter-alpha as zero coverage and a sharpened
/// three-quarter-alpha as full coverage. Replacing the expression by its input
/// alpha changes both pixels; the renderer must receive the author's formula.
#[test]
fn the_alpha_sharpening_reaches_metal_without_becoming_the_source_alpha() {
    let f = "varying vec2 v_Coord; uniform float g_Alpha;\nvoid main() {\nvec4 color = vec4(1.0, 0.0, 0.0, g_Alpha + v_Coord.x * 0.1);\ngl_FragColor = color;\ngl_FragColor.a = saturate((gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5);\n}";
    let p = ok(V, f);
    let glsl = glsl_of(&p, StageKind::Fragment);
    assert!(glsl.contains("fwidth("), "{glsl}");
    let metal = msl(&p);
    assert!(metal.contains("metal::fwidth("), "{metal}");
    assert!(!metal.contains("discard_fragment"), "{metal}");
}

/// The puppet blend-map shader indexes `g_BlendMap` the Direct3D way (`a_BlendIndices.x / 4.0`)
/// rather than through the `#ifdef GLSL` `floor`/`mod` form.
#[test]
fn puppettexturechannels_takes_the_direct3d_branch() {
    let Some(p) = shipped("puppettexturechannels", &[("BLENDROWCOUNT", "4")]) else { return };
    let glsl = glsl_of(&p, StageKind::Vertex);
    assert!(glsl.contains("g_BlendMap["), "{glsl}");
    assert!(!glsl.contains("floor(float(a_BlendIndices"), "the GLSL branch was taken: {glsl}");
}

/// The bool and number forms `docs/testing/renderer.md` once listed as not compiling, through the
/// whole pipeline to Metal: they do, so that entry is gone.
#[test]
fn the_renderer_doc_bool_forms_compile_through_the_pipeline() {
    let f = "varying vec2 v_Coord;\nvoid main() { bool flag = v_Coord.x > 0.5; float mask = step(0.5, v_Coord.y); bool inside = v_Coord.y < 0.9;\nint n = 2; n *= flag; int m; m = v_Coord.x < v_Coord.y; uint u = 3u; u *= flag; int k = flag;\nfloat c = 0.0; if (!mask) { c += 1.0; } if (mask && inside) { c += 1.0; }\ngl_FragColor = CAST4(float(n + m + k) + float(u) + c); }";
    let p = ok(V, f);
    assert!(!msl(&p).is_empty());
}

/// Reflection reports what the engine must bind (E 1.3): a comparison sampler and a depth
/// texture, a multisampled texture, a 3D texture. Plain 2D textures carry neither key.
#[test]
fn reflection_reports_the_texture_shape_and_a_comparison_sampler() {
    let f = "varying vec2 v_Coord; uniform sampler2DComparison g_Texture6; uniform sampler3D g_Texture2; uniform sampler2D g_Texture0;\nvoid main() { float s = texSample2DCompare(g_Texture6, v_Coord, 0.5); gl_FragColor = CAST4(s) + texSample3D(g_Texture2, vec3(v_Coord, 0.5)) + texSample2D(g_Texture0, v_Coord); }";
    let p = Req::new(V, f).texture(texture(0)).texture(texture(2)).texture(texture(6)).ok();
    let d = |name: &str| p.reflection.descriptor_bindings.iter().find(|d| d.name == name).unwrap_or_else(|| panic!("{name}")).clone();
    use crate::reflection::ImageShape;
    assert_eq!(d("g_Texture6").image, ImageShape::Depth2D);
    assert!(d("_we_Sampler_g_Texture6").comparison);
    assert!(d("g_Texture6").to_json().contains("\"dimension\":\"depth_2d\""));
    assert!(d("_we_Sampler_g_Texture6").to_json().contains("\"comparison\":true"));
    assert_eq!(d("g_Texture2").image, ImageShape::D3);
    assert_eq!(d("g_Texture0").image, ImageShape::D2);
    assert!(!d("g_Texture0").to_json().contains("dimension") && !d("_we_Sampler_g_Texture0").to_json().contains("comparison"));
    let f = "varying vec2 v_Coord; uniform sampler2DBackBuffer g_Texture1; uniform vec2 g_Res;\nvoid main() { gl_FragColor = texSample2DBackBuffer(g_Texture1, v_Coord, g_Res); }";
    let p = Req::new(V, f).texture(texture(1)).combo("BACKBUFFER_MS", "1").ok();
    let ms = p.reflection.descriptor_bindings.iter().find(|d| d.name == "g_Texture1").unwrap();
    assert_eq!(ms.image, ImageShape::D2Ms);
}

/// WE's default framebuffer can be a Texture2DMS with one sample after resolving
/// the scene. Metal uses an ordinary 2D image for that resource, with the same
/// integer sample-zero lookup; another slot may still hold real MS samples.
#[test]
fn resolved_backbuffer_keeps_point_sample_zero_with_a_multisampled_peer() {
    let fragment = "varying vec2 v_Coord;\nuniform sampler2DBackBuffer g_Texture0;\nuniform sampler2DBackBuffer g_Texture1;\nuniform vec2 g_Res;\nvec4 readBuffer(sampler2DBackBuffer image, vec2 uv) { return texSample2DBackBuffer(image, uv, g_Res); }\nvoid main() { gl_FragColor = readBuffer(g_Texture0, v_Coord) + readBuffer(g_Texture1, v_Coord); }";
    let document = format!(r#"{{"shader_name":"resolved-backbuffer","stages":[{{"kind":"vertex","source":{}}},{{"kind":"fragment","source":{}}}],"combos":[{{"name":"BACKBUFFER_MS","value":"1"}}],"textures":[{{"slot":0,"enabled":true,"sample_count":1}},{{"slot":1,"enabled":true,"sample_count":4}}]}}"#,
        crate::json::string(V), crate::json::string(fragment));
    let request = crate::parse_request(&document).unwrap();
    let p = crate::pipeline::compile(&request, &crate::source::NoIncludes).unwrap();
    use crate::reflection::ImageShape;
    let image = |name: &str| p.reflection.descriptor_bindings.iter().find(|d| d.name == name).unwrap().image;
    assert_eq!(image("g_Texture0"), ImageShape::D2);
    assert_eq!(image("g_Texture1"), ImageShape::D2Ms);
    let glsl = glsl_of(&p, StageKind::Fragment);
    assert!(glsl.contains("texelFetch(g_Texture0,"), "{glsl}");
    assert!(glsl.contains("texelFetch(g_Texture1,"), "{glsl}");
    assert!(!glsl.contains("texture(sampler2D(g_Texture0,"), "no filtered sampling: {glsl}");
}
