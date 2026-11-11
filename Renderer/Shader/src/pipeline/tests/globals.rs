// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Global initializers that read run-time values (spec D test 35, R64) and the lighting arrays
//! (test 36, R65), checked on the translated module and on the reflection.

use naga::{Block, Expression, Handle, Module, Statement};

use super::support::*;
use crate::backend::compile_glsl;
use crate::request::StageKind;
use crate::source::MemorySource;

/// The names of the globals stored to by the statements of `block`, in order, nested blocks
/// included. A store is a `Statement::Store` whose pointer is the global itself.
fn stores(module: &Module, function: &naga::Function, block: &Block, out: &mut Vec<String>) {
    for statement in block.iter() {
        match statement {
            Statement::Store { pointer, .. } => {
                if let Expression::GlobalVariable(g) = function.expressions[*pointer] {
                    out.push(module.global_variables[g].name.clone().unwrap_or_default());
                }
            }
            Statement::Block(b) => stores(module, function, b, out),
            Statement::If { accept, reject, .. } => {
                stores(module, function, accept, out);
                stores(module, function, reject, out);
            }
            Statement::Loop { body, continuing, .. } => {
                stores(module, function, body, out);
                stores(module, function, continuing, out);
            }
            _ => {}
        }
    }
}

/// The globals the stage's `main` function stores to, in program order.
fn stores_in_main(glsl: &str, kind: StageKind) -> Vec<String> {
    let compiled = compile_glsl(kind, glsl).unwrap_or_else(|e| panic!("{e}\n{glsl}"));
    let module = compiled.translated.expect("a module").module;
    let main: Vec<(Handle<naga::Function>, &naga::Function)> = module.functions.iter().filter(|(_, f)| f.name.as_deref() == Some("main")).collect();
    let (_, f) = main.first().expect("the author's main is a function of the module");
    let mut out = Vec::new();
    stores(&module, f, &f.body, &mut out);
    out
}

fn legalized_fragment(vertex: &str, fragment: &str) -> String {
    glsl_of(&ok(vertex, fragment), StageKind::Fragment)
}

const VERTEX: &str = "void main() { gl_Position = CAST4(1.0); }";

#[test]
fn a_chain_of_const_globals_that_read_a_uniform_is_stored_in_declaration_order() {
    let f = "uniform float u_Near; uniform float u_Far;
float depthSpan() { return u_Far - u_Near; }
const float RANGE = depthSpan();
const float HALF_RANGE = RANGE * 0.5;
const float STEP = HALF_RANGE / 8.0;
void main() { gl_FragColor = CAST4(STEP + HALF_RANGE); }";
    let glsl = legalized_fragment(VERTEX, f);
    let stored = stores_in_main(&glsl, StageKind::Fragment);
    let pos = |name: &str| stored.iter().position(|n| n == name).unwrap_or_else(|| panic!("no store to {name}: {stored:?}\n{glsl}"));
    assert!(pos("RANGE") < pos("HALF_RANGE") && pos("HALF_RANGE") < pos("STEP"), "{stored:?}");
    // Every one of them is stored before the colour is written.
    let colour = stored.iter().position(|n| n.contains("FragColor") || n == "_we_FragColor").unwrap();
    assert!(pos("STEP") < colour, "{stored:?}");
}

#[test]
fn a_mutable_global_initialised_from_a_uniform_keeps_its_value() {
    let f = "uniform float u_Level;\nfloat gain = u_Level * 3.0;\nvoid main() { gl_FragColor = CAST4(gain); }";
    let glsl = legalized_fragment(VERTEX, f);
    let stored = stores_in_main(&glsl, StageKind::Fragment);
    assert!(stored.iter().any(|n| n == "gain"), "the front end drops a global initializer that reads a uniform, so main stores it: {stored:?}\n{glsl}");
}

#[test]
fn the_store_comes_after_the_copies_of_written_inputs() {
    // An initializer may read an input; the input's local copy is made first.
    let v = "attribute vec3 a_Position; attribute vec4 a_Color;\nvarying vec4 v_Color;\nvec4 tint = a_Color * 2.0;\nvoid main() { a_Color.a = 1.0; v_Color = tint; gl_Position = vec4(a_Position, 1.0); }";
    let p = ok(v, "varying vec4 v_Color;\nvoid main() { gl_FragColor = v_Color; }");
    let glsl = glsl_of(&p, StageKind::Vertex);
    let copy = glsl.find("a_Color = _we_in_a_Color;").expect("the written input is copied");
    let initializer = glsl.find("tint = ").expect("the initializer is moved into main");
    assert!(copy < initializer, "{glsl}");
}

#[test]
fn true_constant_initializers_stay_constants_and_bound_a_loop() {
    let f = "#define STEPS 4\nconst int ROUNDS = STEPS * 2;\nuniform float u_X;\nvoid main() { float s = 0.0; for (int i = 0; i < ROUNDS; i++) { s += u_X; } gl_FragColor = CAST4(s); }";
    let glsl = legalized_fragment(VERTEX, f);
    let stored = stores_in_main(&glsl, StageKind::Fragment);
    assert!(!stored.iter().any(|n| n == "ROUNDS"), "no run-time store for a constant expression: {stored:?}");
}

// ---- 36: the lighting arrays ----

/// Stand-ins for the lighting functions the stock include provides; the generated block only
/// needs them to exist with the right arity.
const LIGHTING_INCLUDE: &str = "vec3 PointSegmentDelta(vec3 pos, vec3 a, vec3 b) { return a - pos; }
vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor, float radius, float exponent, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor) { return lightColor * radius + L * exponent; }
vec3 ComputePBRLightShadowInfinite(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor) { return lightColor * N + L; }
";

const LIT_FRAGMENT: &str = "#include \"lighting_stubs.h\"
varying vec3 v_World; varying vec3 v_Normal;
#require LightingV1
void main() {
  vec3 light = PerformLighting_V1(v_World, CAST3(1.0), normalize(v_Normal), vec3(0.0, 0.0, 1.0), CAST3(0.04), CAST3(0.04), 0.5, 0.0);
  gl_FragColor = vec4(light, 1.0);
}
";

const LIT_VERTEX: &str = "attribute vec3 a_Position; attribute vec3 a_Normal; varying vec3 v_World; varying vec3 v_Normal;\nvoid main() { v_World = a_Position; v_Normal = a_Normal; gl_Position = vec4(a_Position, 1.0); }";

fn lit(counts: &[(&str, &str)]) -> crate::pipeline::CompiledProgram {
    let includes = MemorySource::new().with("lighting_stubs.h", LIGHTING_INCLUDE);
    let mut req = Req::new(LIT_VERTEX, LIT_FRAGMENT);
    for (name, value) in counts {
        req = req.combo(name, value);
    }
    match req.compile_with(&includes) {
        Ok(p) => p,
        Err(e) => panic!("{e}"),
    }
}

fn arrays(p: &crate::pipeline::CompiledProgram) -> Vec<(String, u32)> {
    p.reflection.uniform_blocks.first().map(|b| b.members.iter().filter(|m| m.name.starts_with("g_L")).map(|m| (m.name.clone(), m.array_count)).collect()).unwrap_or_default()
}

#[test]
fn each_light_member_has_exactly_the_count_of_its_combo() {
    let p = lit(&[("LIGHTING", "1"), ("LIGHTS_POINT", "2"), ("LIGHTS_SPOT", "3"), ("LIGHTS_TUBE", "1"), ("LIGHTS_DIRECTIONAL", "2")]);
    let list = arrays(&p);
    let count = |name: &str| list.iter().find(|(n, _)| n == name).unwrap_or_else(|| panic!("no member {name}: {list:?}")).1;
    for name in ["g_LPoint_Color", "g_LPoint_Origin"] {
        assert_eq!(count(name), 2, "{name}");
    }
    for name in ["g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent"] {
        assert_eq!(count(name), 3, "{name}");
    }
    for name in ["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"] {
        assert_eq!(count(name), 1, "{name}");
    }
    for name in ["g_LDirectional_Color", "g_LDirectional_Direction"] {
        assert_eq!(count(name), 2, "{name}");
    }
    assert_eq!(list.len(), 11);
    // A single-element array is still an array: reflection says array count 1, stride 16.
    let tube = p.reflection.uniform_blocks[0].members.iter().find(|m| m.name == "g_LTube_Color").unwrap();
    assert_eq!((tube.array_count, tube.array_stride, tube.element_count), (1, 16, 4));
}

#[test]
fn without_lighting_there_is_no_light_member_whatever_the_counts() {
    for combos in [vec![("LIGHTS_POINT", "2"), ("LIGHTS_SPOT", "1")], vec![("LIGHTING", "0"), ("LIGHTS_POINT", "2"), ("LIGHTS_DIRECTIONAL", "1")]] {
        // Without the block there is no `PerformLighting_V1` for the stage to call: use a stage
        // that never calls it, so only the generated declarations matter.
        let includes = MemorySource::new().with("lighting_stubs.h", LIGHTING_INCLUDE);
        let f = "#include \"lighting_stubs.h\"\nvarying vec3 v_World;\n#require LightingV1\nvoid main() { gl_FragColor = vec4(v_World, 1.0); }\n";
        let mut req = Req::new(LIT_VERTEX, f);
        for (n, v) in &combos {
            req = req.combo(n, v);
        }
        let p = req.compile_with(&includes).unwrap();
        assert!(arrays(&p).is_empty(), "{combos:?}: {:?}", arrays(&p));
        assert!(!glsl_of(&p, StageKind::Fragment).contains("g_L"), "{combos:?}");
    }
}

#[test]
fn a_change_of_counts_changes_the_sizes_in_the_reflection_and_in_the_msl_block() {
    let few = lit(&[("LIGHTING", "1"), ("LIGHTS_POINT", "1"), ("LIGHTS_SPOT", "0"), ("LIGHTS_TUBE", "0"), ("LIGHTS_DIRECTIONAL", "1")]);
    let many = lit(&[("LIGHTING", "1"), ("LIGHTS_POINT", "4"), ("LIGHTS_SPOT", "0"), ("LIGHTS_TUBE", "0"), ("LIGHTS_DIRECTIONAL", "1")]);
    assert_eq!(arrays(&few).iter().find(|(n, _)| n == "g_LPoint_Color").unwrap().1, 1);
    assert_eq!(arrays(&many).iter().find(|(n, _)| n == "g_LPoint_Color").unwrap().1, 4);
    let msl = |p: &crate::pipeline::CompiledProgram| p.stage(StageKind::Fragment).unwrap().payload.msl_source.clone();
    assert!(msl(&many).contains("metal::float4 inner[4];"), "{}", msl(&many));
    assert!(msl(&few).contains("metal::float4 inner[1];"), "{}", msl(&few));
    assert!(many.reflection.uniform_blocks[0].size > few.reflection.uniform_blocks[0].size);
}

#[test]
fn a_two_row_matrix_reflects_with_the_authors_component_count_and_the_std140_footprint() {
    let fragment = "uniform mat2 g_A; uniform mat3x2 g_B; uniform mat4x2 g_C[2]; uniform mat2x2 g_D; uniform float g_After;\n\
                    void main() { gl_FragColor = vec4(g_A[0] + g_B[1] + g_C[1][2] + g_D[1], g_After, 1.0); }";
    let p = ok("attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }", fragment);
    let block = &p.reflection.uniform_blocks[0];
    let got: Vec<(&str, u32, u32, u32, u32, u32)> = block
        .members
        .iter()
        .map(|m| (m.name.as_str(), m.offset, m.size, m.element_count, m.array_count, m.array_stride))
        .collect();
    assert_eq!(
        got,
        [
            ("g_A", 0, 32, 4, 0, 0),
            ("g_B", 32, 48, 6, 0, 0),
            ("g_C", 80, 128, 8, 2, 64),
            ("g_D", 208, 32, 4, 0, 0),
            ("g_After", 240, 4, 1, 0, 0),
        ]
    );
}
