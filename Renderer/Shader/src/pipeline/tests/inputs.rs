// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Vertex inputs through the whole pipeline (spec D tests 23 and 29, R19, R57 to R59): the
//! names the engine looks the mesh attributes up by, and the location limit.

use super::support::*;
use crate::error::ErrorCategory;
use crate::request::StageKind;

const FRAGMENT: &str = "void main() { gl_FragColor = vec4(1.0); }";

fn inputs(p: &crate::pipeline::CompiledProgram) -> Vec<(String, u32)> {
    p.reflection.vertex_inputs.iter().map(|i| (i.name.clone(), i.location)).collect()
}

#[test]
fn inputs_are_numbered_in_declaration_order_and_reported_unchanged() {
    let p = ok("attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nattribute vec4 a_Color;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }", FRAGMENT);
    assert_eq!(inputs(&p), [("a_Position".to_string(), 0), ("a_TexCoord".to_string(), 1), ("a_Color".to_string(), 2)]);
    let msl = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
    for (name, location) in inputs(&p) {
        assert!(msl.contains(&format!("{name} [[attribute({location})]]")), "{name}: {msl}");
    }
}

#[test]
fn an_input_the_shader_writes_is_reported_under_its_source_name_at_the_same_location() {
    let v = "attribute vec3 a_Position;\nattribute vec4 a_Color;\nattribute vec2 a_TexCoord;\nvarying vec4 v_Color;\nvoid main() { a_Color.a = 1.0; v_Color = a_Color; gl_Position = vec4(a_Position, a_TexCoord.x); }";
    let p = ok(v, "varying vec4 v_Color;\nvoid main() { gl_FragColor = v_Color; }");
    assert_eq!(inputs(&p), [("a_Position".to_string(), 0), ("a_Color".to_string(), 1), ("a_TexCoord".to_string(), 2)]);
    // The declaration the legalizer made is under another name, which reflection does not show.
    let glsl = glsl_of(&p, StageKind::Vertex);
    assert!(glsl.contains("_we_in_a_Color"), "{glsl}");
    assert!(!p.reflection.vertex_inputs.iter().any(|i| i.name.contains("_we_in_")));
    assert_eq!(p.reflection.to_json().matches("a_Color").count(), 1);
}

#[test]
fn an_unread_input_is_still_listed() {
    let p = ok("attribute vec3 a_Position;\nattribute vec4 a_Unused;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }", FRAGMENT);
    assert_eq!(inputs(&p).len(), 2);
}

fn many_attributes(n: u32) -> String {
    let declarations: String = (0..n).map(|i| format!("attribute vec4 a_{i};\n")).collect();
    let sum: Vec<String> = (0..n).map(|i| format!("a_{i}")).collect();
    format!("{declarations}void main() {{ gl_Position = {}; }}", sum.join(" + "))
}

#[test]
fn locations_up_to_thirty_are_accepted_and_thirty_one_fails() {
    let p = ok(&many_attributes(31), FRAGMENT);
    assert_eq!(p.reflection.vertex_inputs.last().unwrap().location, 30);
    let e = err(&many_attributes(32), FRAGMENT);
    assert_eq!(e.category(), ErrorCategory::Reflection, "{e}");
    let text = e.to_string();
    assert!(text.contains("a_31") && text.contains("31") && text.contains("out of range"), "{text}");
}

#[test]
fn integer_inputs_have_integer_formats_and_need_no_attribute_conversion() {
    let p = ok("attribute vec3 a_Position;\nattribute uvec4 a_BlendIndices;\nattribute vec4 a_BlendWeights;\nattribute ivec2 a_Cell;\nvoid main() { gl_Position = vec4(a_Position, 1.0) * a_BlendWeights.x + vec4(float(a_BlendIndices.x) + float(a_Cell.x)); }", FRAGMENT);
    let formats: Vec<String> = p.reflection.vertex_inputs.iter().map(|i| i.format.name()).collect();
    assert_eq!(formats, ["r32g32b32_sfloat", "r32g32b32a32_uint", "r32g32b32a32_sfloat", "r32g32_sint"]);
}
