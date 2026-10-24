// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Vertex and instance index (spec D test 23, R49, R57): builtin parameters of the function,
//! not attributes, and not reflected inputs.

use crate::pipeline::tests::support::ok;
use crate::request::StageKind;

const FRAGMENT: &str = "void main() { gl_FragColor = vec4(1.0); }";

fn compiled(vertex: &str) -> crate::pipeline::CompiledProgram {
    ok(vertex, FRAGMENT)
}

#[test]
fn the_indices_are_function_parameters_not_attributes() {
    let p = compiled("attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, float(gl_VertexID) + float(gl_InstanceID)); }");
    let msl = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
    assert!(msl.contains("uint gl_VertexIndex [[vertex_id]]"), "{msl}");
    assert!(msl.contains("uint gl_InstanceIndex [[instance_id]]"), "{msl}");
    assert_eq!(msl.matches("[[attribute(").count(), 1, "only a_Position is an attribute: {msl}");
    let names: Vec<&str> = p.reflection.vertex_inputs.iter().map(|i| i.name.as_str()).collect();
    assert_eq!(names, ["a_Position"], "no phantom builtin input");
}

#[test]
fn redeclaring_them_as_inputs_produces_no_attribute_and_no_reflected_input() {
    for decl in ["attribute uint gl_VertexID;", "in uint gl_VertexID;", "attribute uint gl_InstanceID; in uint gl_VertexID;"] {
        let p = compiled(&format!("attribute vec3 a_Position;\n{decl}\nvoid main() {{ gl_Position = vec4(a_Position, float(gl_VertexID)); }}"));
        let msl = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
        assert_eq!(msl.matches("[[attribute(").count(), 1, "{decl}: {msl}");
        assert!(msl.contains("[[vertex_id]]"), "{decl}: {msl}");
        assert_eq!(p.reflection.vertex_inputs.len(), 1, "{decl}");
    }
}

#[test]
fn a_vertex_stage_that_reads_neither_still_has_no_builtin_parameters() {
    let p = compiled("attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }");
    let msl = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
    assert!(!msl.contains("[[vertex_id]]") && !msl.contains("[[instance_id]]"), "{msl}");
}
