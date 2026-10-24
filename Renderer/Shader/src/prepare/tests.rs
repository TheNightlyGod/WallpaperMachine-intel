// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Behaviour tests for the combo protocol (spec section 8, items 56, 57 and 60) and for the program front end.

use super::*;
use crate::include::IncludeErrorKind;
use crate::request::{Combo, ShaderRequest, Stage, TextureComponents, TextureFormat, TextureRecord, VideoPlanes};
use crate::source::{MemorySource, NoIncludes};

fn request(vertex: &str, fragment: &str, combos: &[(&str, &str)], textures: Vec<TextureRecord>) -> ValidRequest {
    ShaderRequest {
        shader_name: "fx/test".into(),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: vertex.into() },
            Stage { kind: StageKind::Fragment, source: fragment.into() },
        ],
        combos: combos.iter().map(|(n, v)| Combo { name: n.to_string(), value: v.to_string() }).collect(),
        textures,
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap()
}

fn texture(slot: u8, present: bool) -> TextureRecord {
    TextureRecord {
        slot,
        present,
        enabled: true,
        format: TextureFormat::Unknown,
        components: TextureComponents::default(),
        video_planes: VideoPlanes::None,
    }
}

fn prepare(r: &ValidRequest) -> PreparedProgram {
    prepare_program(r, &NoIncludes).unwrap_or_else(|e| panic!("{e}"))
}

fn names(p: &PreparedProgram) -> Vec<(&str, &str)> {
    p.compile_combos.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect()
}

const VOID_MAIN: &str = "void main() { }\n";

#[test]
fn the_request_beats_an_annotation_default() {
    let frag = format!("// [COMBO] {{\"combo\":\"QUALITY\",\"default\":2}}\n#if QUALITY == 3\nhigh\n#endif\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &frag, &[("QUALITY", "3")], vec![]));
    assert_eq!(names(&p), [("QUALITY", "3")]);
    assert!(p.stages[1].evaluated.contains("high"));
    // In any case: a request combo spelled in lower case still wins.
    let p = prepare(&request(VOID_MAIN, &frag, &[("quality", "3")], vec![]));
    assert_eq!(names(&p), [("quality", "3")]);
}

#[test]
fn an_annotation_default_fills_a_missing_name_and_becomes_a_macro() {
    let frag = format!("// [COMBO] {{\"combo\":\"GRAIN\",\"default\":4}}\n#if GRAIN == 4\nwith grain\n#endif\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &frag, &[("OTHER", "1")], vec![]));
    assert_eq!(names(&p), [("OTHER", "1"), ("GRAIN", "4")]);
    let fragment = &p.stages[1];
    assert!(fragment.evaluated.starts_with("#define OTHER 1\n#define GRAIN 4\n"), "{}", fragment.evaluated);
    assert!(fragment.evaluated.contains("with grain"));
    assert_eq!(fragment.macros.value("GRAIN"), Some("4"));
    // Both stages get the same definitions.
    assert!(p.stages[0].evaluated.starts_with("#define OTHER 1\n#define GRAIN 4\n"));
    // Reported metadata lists the default too.
    assert_eq!(p.metadata.combos.len(), 1);
    assert_eq!((p.metadata.combos[0].name.as_str(), p.metadata.combos[0].value.as_str()), ("GRAIN", "4"));
}

#[test]
fn a_default_in_an_inactive_branch_is_reported_but_not_compiled() {
    let frag = format!("#if QUALITY == 0\n// [COMBO] {{\"combo\":\"GRAIN\",\"default\":1}}\n#endif\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &frag, &[("QUALITY", "3")], vec![]));
    assert_eq!(names(&p), [("QUALITY", "3")]);
    assert!(!p.stages[1].evaluated.contains("GRAIN"));
    assert_eq!(p.metadata.combos.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["GRAIN"]);
}

#[test]
fn defaults_are_discovered_in_a_single_round() {
    // B's annotation only becomes reachable once A's default is applied: it is not applied (Q4), though reported.
    let frag = format!("// [COMBO] {{\"combo\":\"A\",\"default\":1}}\n#if A\n// [COMBO] {{\"combo\":\"B\",\"default\":1}}\n#endif\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &frag, &[], vec![]));
    assert_eq!(names(&p), [("A", "1")]);
    assert!(!p.stages[1].evaluated.contains("#define B"));
    let reported: Vec<&str> = p.metadata.combos.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(reported, ["A", "B"]);
}

#[test]
fn a_texture_switch_inside_the_branch_it_enables_follows_the_texture() {
    let frag = format!("#if EDGEFX\nuniform sampler2D g_Texture1; // {{\"combo\":\"EDGEFX\"}}\nedge code\n#endif\n{VOID_MAIN}");
    let present = prepare(&request(VOID_MAIN, &frag, &[], vec![texture(1, true)]));
    assert_eq!(names(&present), [("EDGEFX", "1")]);
    assert!(present.stages[1].evaluated.contains("edge code"));
    let absent = prepare(&request(VOID_MAIN, &frag, &[], vec![texture(1, false)]));
    assert_eq!(names(&absent), [("EDGEFX", "0")]);
    assert!(!absent.stages[1].evaluated.contains("edge code"));
    let none = prepare(&request(VOID_MAIN, &frag, &[], vec![]));
    assert_eq!(names(&none), [("EDGEFX", "0")]);
    // An explicit request value always wins.
    let overridden = prepare(&request(VOID_MAIN, &frag, &[("EDGEFX", "0")], vec![texture(1, true)]));
    assert_eq!(names(&overridden), [("EDGEFX", "0")]);
    assert!(!overridden.stages[1].evaluated.contains("edge code"));
}

#[test]
fn a_texture_switch_that_comes_from_an_include_works_too() {
    let inc = MemorySource::new().with("edge.h", "#if EDGEFX\nuniform sampler2D g_Texture1; // {\"combo\":\"EDGEFX\"}\nedge from include\n#endif\n");
    let frag = format!("#include \"edge.h\"\n{VOID_MAIN}");
    let r = request(VOID_MAIN, &frag, &[], vec![texture(1, true)]);
    let p = prepare_program(&r, &inc).unwrap();
    assert_eq!(names(&p), [("EDGEFX", "1")]);
    assert!(p.stages[1].evaluated.contains("edge from include"));
    assert_eq!(p.includes_read, ["edge.h"]);
    let r = request(VOID_MAIN, &frag, &[], vec![]);
    let p = prepare_program(&r, &inc).unwrap();
    assert!(!p.stages[1].evaluated.contains("edge from include"));
}

#[test]
fn texture_derived_combos_sit_between_the_request_and_the_annotation_defaults() {
    let frag = format!("// [COMBO] {{\"combo\":\"DEFAULTED\",\"default\":5}}\nuniform sampler2D g_Texture0; // {{\"combo\":\"HASMASK\"}}\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &frag, &[("REQ", "1")], vec![texture(0, true)]));
    let n: Vec<&str> = p.compile_combos.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(n, ["REQ", "HASMASK", "DEFAULTED"]);
    assert!(p.stages[1].evaluated.starts_with("#define REQ 1\n#define HASMASK 1\n#define DEFAULTED 5\n"));
}

#[test]
fn reported_metadata_is_the_plain_concatenation_in_stage_order() {
    let vertex = format!("// [COMBO] {{\"combo\":\"SHARED\",\"default\":1}}\nuniform vec2 g_Offset; // {{\"material\":\"offset\",\"default\":\"0 0\"}}\n{VOID_MAIN}");
    let fragment = format!("// [COMBO] {{\"combo\":\"SHARED\",\"default\":2}}\nuniform float g_Amount; // {{\"default\":0.5}}\nuniform sampler2D g_Texture0; // {{\"default\":\"util/white\"}}\n{VOID_MAIN}");
    let p = prepare(&request(&vertex, &fragment, &[], vec![]));
    let combos: Vec<(&str, &str)> = p.metadata.combos.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect();
    assert_eq!(combos, [("SHARED", "1"), ("SHARED", "2")]);
    let defaults: Vec<&str> = p.metadata.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(defaults, ["g_Offset", "g_Amount"]);
    assert_eq!(p.metadata.aliases.len(), 1);
    assert_eq!(p.metadata.default_textures.len(), 1);
    // The compiled definition comes from the first stage that declared it.
    assert_eq!(names(&p), [("SHARED", "1")]);
    // The reported document has the documented shape.
    let doc = p.metadata.to_json().unwrap();
    assert!(doc.starts_with("{\"combos\":[{\"name\":\"SHARED\",\"value\":\"1\"},{\"name\":\"SHARED\",\"value\":\"2\"}]"), "{doc}");
    assert!(doc.contains("\"default_textures\":[{\"slot\":0,\"path\":\"util/white\"}]"));
    assert!(doc.ends_with("\"active_texture_slots\":[]}"));
}

#[test]
fn reported_fog_default_survives_with_its_exact_value() {
    let on = format!("// [COMBO] {{\"material\":\"ui_editor_properties_fog\",\"combo\":\"FOG\",\"default\":1}}\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &on, &[], vec![]));
    assert_eq!((p.metadata.combos[0].name.as_str(), p.metadata.combos[0].value.as_str()), ("FOG", "1"));
    // Also from an inactive branch.
    let hidden = format!("#if 0\n// [COMBO] {{\"combo\":\"FOG\",\"default\":1}}\n#endif\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &hidden, &[], vec![]));
    assert_eq!((p.metadata.combos[0].name.as_str(), p.metadata.combos[0].value.as_str()), ("FOG", "1"));
    // A default of 0 is reported as 0.
    let off = format!("// [COMBO] {{\"combo\":\"FOG\",\"default\":0}}\n{VOID_MAIN}");
    let p = prepare(&request(VOID_MAIN, &off, &[], vec![]));
    assert_eq!(p.metadata.combos[0].value, "0");
}

#[test]
fn the_view_depends_on_the_request_combos_alone() {
    let inc = MemorySource::new().with("late.h", "// [COMBO] {\"combo\":\"FROMLATE\",\"default\":1}\n");
    // The include sits behind a combo that only an annotation default would turn on: not read.
    let frag = format!("// [COMBO] {{\"combo\":\"USELATE\",\"default\":1}}\n#if USELATE\n#include \"late.h\"\n#endif\n{VOID_MAIN}");
    let p = prepare_program(&request(VOID_MAIN, &frag, &[], vec![]), &inc).unwrap();
    assert!(p.metadata.combos.iter().all(|c| c.name != "FROMLATE"));
    // With the request turning it on, it is read and its annotation reported.
    let p = prepare_program(&request(VOID_MAIN, &frag, &[("USELATE", "1")], vec![]), &inc).unwrap();
    assert!(p.metadata.combos.iter().any(|c| c.name == "FROMLATE"));
}

#[test]
fn every_distinct_include_is_read_once_per_program() {
    use std::cell::Cell;
    let reads = Cell::new(0);
    let source = |p: &str| -> Result<String, crate::include::IncludeError> {
        reads.set(reads.get() + 1);
        if p == "a.h" {
            Ok("x\n".into())
        } else {
            Err(crate::include::IncludeError { path: p.into(), kind: IncludeErrorKind::NotFound })
        }
    };
    let frag = format!("#include \"a.h\"\n#include \"a.h\"\n{VOID_MAIN}");
    let vertex = format!("#include \"a.h\"\n{VOID_MAIN}");
    prepare_program(&request(&vertex, &frag, &[("T", "1")], vec![]), &source).unwrap();
    assert_eq!(reads.get(), 1);
}

#[test]
fn the_view_and_evaluated_text_both_start_with_the_request_combos() {
    let p = prepare(&request(VOID_MAIN, VOID_MAIN, &[("DETAIL", "3"), ("Sparkle", "1")], vec![]));
    for stage in &p.stages {
        assert!(stage.evaluated.starts_with("#define DETAIL 3\n#define SPARKLE 1\n"));
        assert!(stage.view.starts_with("#define DETAIL 3\n#define SPARKLE 1\n"));
    }
}

#[test]
fn stage_independence_and_order_follow_the_request() {
    let r = ShaderRequest {
        shader_name: "fx".into(),
        stages: vec![
            Stage { kind: StageKind::Fragment, source: format!("#ifdef V\nleak\n#endif\n{VOID_MAIN}") },
            Stage { kind: StageKind::Vertex, source: format!("#define V 1\n{VOID_MAIN}") },
        ],
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap();
    let p = prepare(&r);
    assert_eq!(p.stages[0].kind, StageKind::Fragment);
    assert_eq!(p.stages[1].kind, StageKind::Vertex);
    assert!(!p.stages[0].evaluated.contains("leak"));
}

#[test]
fn failures_carry_the_shader_name_stage_and_line() {
    let r = request(VOID_MAIN, "a\n#if 1 +\n#endif\nvoid main() {}\n", &[], vec![]);
    let e = prepare_program(&r, &NoIncludes).unwrap_err().to_string();
    for needle in ["#if expression is unsupported", "fx/test.frag:2:1", "stage: fragment", "shader: fx/test"] {
        assert!(e.contains(needle), "{needle}: {e}");
    }
    // Unbalanced braces in the evaluated text are a parse failure.
    let r = request("void main() {\n", VOID_MAIN, &[], vec![]);
    let e = prepare_program(&r, &NoIncludes).unwrap_err().to_string();
    assert!(e.contains("unbalanced shader delimiter") && e.contains("pass: Parse"), "{e}");
    // A missing include is the provider's not-found failure.
    let r = request("#include \"nope.h\"\nvoid main() {}\n", VOID_MAIN, &[], vec![]);
    let e = prepare_program(&r, &NoIncludes).unwrap_err().to_string();
    assert!(e.contains("not found") && e.contains("nope.h"), "{e}");
    // Annotation errors name the problem.
    let r = request(VOID_MAIN, "// [COMBO] {\"combo\":\"1A\"}\nvoid main() {}\n", &[], vec![]);
    assert!(prepare_program(&r, &NoIncludes).unwrap_err().to_string().contains("combo name"));
}

#[test]
fn per_arm_headers_prepare_in_the_view_and_the_evaluated_text_balances() {
    let frag = "uniform float g_Pre; // {\"default\":1}\n#ifdef HDR\nvec3 grade(vec3 l) {\n#else\nvec3 grade(vec3 l, float ev) {\n#endif\n    return l;\n}\nuniform float g_Post; // {\"default\":2}\nvoid main() { }\n";
    let p = prepare(&request(VOID_MAIN, frag, &[], vec![]));
    let names: Vec<&str> = p.metadata.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(names, ["g_Pre", "g_Post"]);
    // The evaluated text keeps only one header.
    assert_eq!(p.stages[1].evaluated.matches("vec3 grade").count(), 1);
}

#[test]
fn a_property_value_does_not_change_the_output() {
    use crate::request::{Property, PropertyValue};
    let base = request(VOID_MAIN, VOID_MAIN, &[("A", "1")], vec![]);
    let mut with = ShaderRequest {
        shader_name: "fx/test".into(),
        stages: base.stages().to_vec(),
        combos: base.combos().to_vec(),
        ..ShaderRequest::default()
    };
    with.properties.push(Property { name: "tint".into(), value: PropertyValue::Vec4([1.0, 0.0, 0.5, 1.0]) });
    with.properties.push(Property { name: "m".into(), value: PropertyValue::Matrix4([0.0; 16]) });
    let a = prepare(&base);
    let b = prepare(&with.validate().unwrap());
    assert_eq!(a, b);
}
