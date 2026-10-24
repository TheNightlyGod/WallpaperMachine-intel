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
    let f = "varying vec2 v_Coord;\nint bucket(in int n) { return n * 2; }\nvoid main() { float u = v_Coord.x; gl_FragColor = vec4(float(bucket(u * 8.0))); }";
    let p = ok(V, f);
    assert!(glsl_of(&p, StageKind::Fragment).contains("bucket(int(u * 8.0))"), "{}", glsl_of(&p, StageKind::Fragment));
    // In the Metal text a float-to-int conversion sits at the call.
    let text = msl(&p);
    let call = text.lines().find(|l| l.contains("= bucket(")).expect("the call");
    assert!(call.contains("naga_f2i32(") || call.contains("static_cast<int>"), "{call}");
    // The conversion truncates toward zero: the written conversion is `int(...)`, which does.
    // With a second overload of the same arity differing in that position, nothing is converted.
    let f = "varying vec2 v_Coord;\nint bucket(in int n) { return n * 2; }\nint bucket(in float n) { return 7; }\nvoid main() { float u = v_Coord.x; gl_FragColor = vec4(float(bucket(u * 8.0))); }";
    let p = ok(V, f);
    let glsl = glsl_of(&p, StageKind::Fragment);
    assert!(glsl.contains("bucket(u * 8.0)") && !glsl.contains("bucket(int("), "{glsl}");
}

#[test]
fn a_number_is_a_condition_and_compares_with_the_zero_of_its_type() {
    for value in 0..=4 {
        // An object-like macro value as a condition, the value coming from a combo.
        let f = "varying vec2 v_Coord;\nvoid main() { float a = v_Coord.x; float b = v_Coord.y; float c = MODE ? a : b; gl_FragColor = vec4(c); }";
        let p = Req::new(V, f).combo("MODE", &value.to_string()).ok();
        let glsl = glsl_of(&p, StageKind::Fragment);
        assert!(glsl.contains(&format!("{value} != 0 ? a : b")), "MODE={value}: {glsl}");
        // Integer arithmetic as a condition.
        let f = "varying vec2 v_Coord;\nvoid main() { int n = N; float c = 0.0; if (n - 4) { c = 1.0; } gl_FragColor = vec4(c); }";
        let p = Req::new(V, f).combo("N", &value.to_string()).ok();
        let glsl = glsl_of(&p, StageKind::Fragment);
        assert!(glsl.contains("n - 4 != 0"), "N={value}: {glsl}");
        assert!(msl(&p).contains("!= 0") || msl(&p).contains("!= 0u") || msl(&p).contains("n_1"), "N={value}");
    }
    // A literal define, as the check states it.
    let p = ok(V, "#define MODE 2\nvarying vec2 v_Coord;\nvoid main() { float a = v_Coord.x; float b = v_Coord.y; float c = MODE ? a : b; gl_FragColor = vec4(c); }");
    assert!(glsl_of(&p, StageKind::Fragment).contains("2 != 0 ? a : b"));
    // A float condition compares with 0.0.
    let p = ok(V, "varying vec2 v_Coord;\nvoid main() { float x = v_Coord.x; float c = 0.0; if (x) { c = 1.0; } gl_FragColor = vec4(c); }");
    assert!(glsl_of(&p, StageKind::Fragment).contains("x != 0.0"), "{}", glsl_of(&p, StageKind::Fragment));
}

#[test]
fn the_cast_macros_take_any_scalar_expression_including_an_unsigned_remainder() {
    let f = "varying vec2 v_Coord;\nvoid main() { uint k = uint(v_Coord.x * 10.0); float f = CASTF(k % 3u); int i = CASTI(v_Coord.y * 4.0); uint u = CASTU(v_Coord.x); gl_FragColor = vec4(f + float(i) + float(u)); }";
    let p = ok(V, f);
    let glsl = glsl_of(&p, StageKind::Fragment);
    // The remainder stays an integer one and the result is converted (c1 R46).
    assert!(glsl.contains("float(k % 3u)") && glsl.contains("int(v_Coord.y * 4.0)") && glsl.contains("uint(v_Coord.x)"), "{glsl}");
    assert!(msl(&p).contains("% 3u") || msl(&p).contains("% metal::select"), "{}", msl(&p));
    // Every stage has them, the vertex stage included.
    let v = "attribute vec3 a_Position; void main() { uint k = uint(a_Position.x); gl_Position = vec4(a_Position, CASTF(k % 3u)); }";
    assert!(ok(v, "void main() { gl_FragColor = vec4(1.0); }").stage(StageKind::Vertex).is_some());
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
            "varying vec2 v_Coord;\nuniform sampler2D g_Texture1;\nfloat shade({params}) {{ {writes} return texSample2D(t, v_Coord).r * {weight}; }}\nvoid main() {{ float r = 0.0; gl_FragColor = vec4(shade({args})); }}"
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
    for name in ["shadowcaster", "shadowcasterfur4", "fur4", "generic4"] {
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
