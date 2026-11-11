// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Stage interfaces: varying locations, width reconciliation, synthesized vertex outputs,
//! written inputs, builtins and the fragment output (spec C2 section 8, items 11 to 14, 30).

use super::support::*;
use crate::legalize::{InterfacePlan, LegalizeError};
use crate::request::StageKind;

fn location_of(text: &str, name: &str) -> u32 {
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("layout(location = ")
            && let Some((n, after)) = rest.split_once(')')
            && after.trim_end_matches(';').split_whitespace().last().map(|w| w.split('[').next().unwrap()) == Some(name)
        {
            return n.parse().unwrap();
        }
    }
    panic!("no location for {name} in\n{text}");
}

fn names_with_locations(list: &[InterfacePlan]) -> Vec<(String, u32)> {
    list.iter().map(|i| (i.name.clone(), i.location)).collect()
}

#[test]
fn vertex_inputs_are_numbered_in_source_order() {
    let p = program(
        "attribute vec3 a_Position; attribute vec2 a_TexCoord; in vec4 a_Color;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }",
        "void main() { gl_FragColor = CAST4(1.0); }",
    );
    assert_eq!(names_with_locations(&p.layout.vertex_inputs), [("a_Position".into(), 0), ("a_TexCoord".into(), 1), ("a_Color".into(), 2)]);
    let t = &p.vertex.as_ref().unwrap().text;
    assert!(t.contains("layout(location = 0) in vec3 a_Position;") && t.contains("layout(location = 2) in vec4 a_Color;"), "{t}");
}

#[test]
fn varyings_are_matched_by_name_and_numbered_by_the_fragment_stage() {
    let v = "varying vec4 a; varying vec2 b;\nvoid main() { a = CAST4(1.0); b = CAST2(1.0); gl_Position = CAST4(1.0); }";
    let f = "varying vec2 b; varying vec4 a;\nvoid main() { gl_FragColor = vec4(b, 0.0, 0.0) + a; }";
    let both = compile_program(v, f);
    let (vt, ft) = (&both.program.vertex.as_ref().unwrap().text, &both.program.fragment.as_ref().unwrap().text);
    assert_eq!((location_of(vt, "b"), location_of(vt, "a")), (0, 1));
    assert_eq!((location_of(ft, "b"), location_of(ft, "a")), (0, 1));
    assert!(vt.contains("out vec2 b;") && ft.contains("in vec2 b;"));
}

#[test]
fn arrays_take_a_location_per_element_and_vertex_only_varyings_follow() {
    let v = "varying vec2 t[3]; varying float w; varying vec3 only_v; varying vec4 only_v2;\nvoid main() { t[0] = CAST2(0.0); w = 1.0; only_v = CAST3(0.0); only_v2 = CAST4(0.0); gl_Position = CAST4(1.0); }";
    let f = "varying float w; varying vec2 t[3];\nvoid main() { gl_FragColor = vec4(t[2], w, 1.0); }";
    let both = compile_program(v, f);
    let (vt, ft) = (&both.program.vertex.as_ref().unwrap().text, &both.program.fragment.as_ref().unwrap().text);
    assert_eq!((location_of(ft, "w"), location_of(ft, "t")), (0, 1));
    assert_eq!((location_of(vt, "w"), location_of(vt, "t")), (0, 1));
    assert_eq!((location_of(vt, "only_v"), location_of(vt, "only_v2")), (4, 5), "t takes 1..=3, so the vertex-only ones follow");
    let plan = &both.program.layout.varyings;
    assert_eq!(plan.iter().map(|v| (v.name.as_str(), v.location)).collect::<Vec<_>>(), [("w", 0), ("t", 1), ("only_v", 4), ("only_v2", 5)]);
}

#[test]
fn a_fragment_only_varying_gets_a_zero_initialised_vertex_output() {
    let v = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }";
    let f = "varying vec3 v_Only; varying float v_F; varying vec2 v_Arr[2];\nvoid main() { gl_FragColor = vec4(v_Only, v_F + v_Arr[1].x); }";
    let both = compile_program(v, f);
    let vt = &both.program.vertex.as_ref().unwrap().text;
    assert!(vt.contains("layout(location = 0) out vec3 v_Only;") && vt.contains("layout(location = 2) out vec2 v_Arr[2];"), "{vt}");
    let main = &vt[vt.find("void main()").unwrap()..];
    assert!(main.contains("v_Only = vec3(0.0);") && main.contains("v_F = 0.0;"), "{vt}");
    assert!(main.contains("v_Arr = vec2[2](vec2(0.0), vec2(0.0));"), "every element of an array output starts at zero: {vt}");
    let plan = &both.program.layout.varyings;
    assert!(plan.iter().all(|v| !v.in_vertex && v.synthesized.is_some()));
}

#[test]
fn a_synthesized_name_avoids_every_top_level_declaration_of_the_vertex_stage() {
    let v = "attribute vec3 v_X; uniform float v_G; float v_H = 1.0; float v_Fn(float a) { return a; }\nvoid main() { gl_Position = vec4(v_X, v_G + v_H + v_Fn(1.0)); }";
    let f = "varying float v_X; varying float v_G; varying float v_H; varying float v_Fn; varying float _we_out_v_X;\nvoid main() { gl_FragColor = CAST4(v_X + v_G + v_H + v_Fn + _we_out_v_X); }";
    let both = compile_program(v, f);
    let plan = &both.program.layout.varyings;
    let name = |n: &str| plan.iter().find(|v| v.name == n).unwrap().synthesized.clone().unwrap();
    assert_eq!(name("v_X"), "_we_out_v_X");
    assert_eq!(name("v_G"), "_we_out_v_G");
    assert_eq!(name("v_H"), "_we_out_v_H");
    assert_eq!(name("v_Fn"), "_we_out_v_Fn");
    assert_eq!(name("_we_out_v_X"), "_we_out__we_out_v_X", "a generated name is taken as soon as it is chosen");
    let names: std::collections::HashSet<_> = plan.iter().map(|v| v.synthesized.clone().unwrap()).collect();
    assert_eq!(names.len(), plan.len());
}

#[test]
fn a_synthesized_output_is_set_before_a_written_input_is_copied_and_before_relocated_initialisers() {
    let v = "attribute vec2 a_T; vec2 g_Doubled = a_T * 2.0;\nvoid main() { a_T *= 3.0; gl_Position = vec4(a_T + g_Doubled, 0.0, 1.0); }";
    let f = "varying float v_Late;\nvoid main() { gl_FragColor = CAST4(v_Late); }";
    let both = compile_program(v, f);
    let t = &both.program.vertex.as_ref().unwrap().text;
    let main = &t[t.find("void main()").unwrap()..];
    let at = |s: &str| main.find(s).unwrap_or_else(|| panic!("{s} missing in\n{main}"));
    assert!(at("v_Late = 0.0;") < at("a_T = _we_in_a_T;") && at("a_T = _we_in_a_T;") < at("g_Doubled = a_T * 2.0;"), "{main}");
}

#[test]
fn nothing_is_inserted_into_main_when_nothing_is_needed() {
    let t = vert("attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }");
    assert!(t.ends_with("void main() {\n  gl_Position = vec4(a_Position, 1.0);\n}\n"), "{t}");
    // a stage without main silently omits the prelude
    let _ = program("void helper() { }", "varying float v_A;\nvoid main() { gl_FragColor = CAST4(v_A); }");
}

#[test]
fn the_width_of_a_varying_is_reconciled_when_neither_stage_uses_the_difference() {
    // (a) the vertex output is wider and is only written whole or through narrow selections
    let both = compile_program(
        "varying vec4 v_T;\nvoid main() { v_T = vec4(1.0, 2.0, 3.0, 4.0); gl_Position = CAST4(1.0); }",
        "varying vec2 v_T;\nvoid main() { gl_FragColor = vec4(v_T, 0.0, 1.0); }",
    );
    let vt = &both.program.vertex.as_ref().unwrap().text;
    assert!(vt.contains("out vec2 v_T;"), "the vertex output takes the fragment width: {vt}");
    assert!(vt.contains("v_T = vec4(1.0, 2.0, 3.0, 4.0).xy;") || vt.contains("v_T = (vec4(1.0, 2.0, 3.0, 4.0)).xy;"), "the whole assignment is narrowed too: {vt}");
    let both = compile_program(
        "varying vec3 v_T;\nvoid main() { v_T.xy = CAST2(1.0); gl_Position = CAST4(1.0); }",
        "varying vec2 v_T;\nvoid main() { gl_FragColor = vec4(v_T, 0.0, 1.0); }",
    );
    assert!(both.program.vertex.as_ref().unwrap().text.contains("out vec2 v_T;"));
    // (b) the vertex output is narrower and the fragment stage only needs what it has
    let both = compile_program(
        "varying vec2 v_T;\nvoid main() { v_T = CAST2(1.0); gl_Position = CAST4(1.0); }",
        "varying vec4 v_T;\nvoid main() { gl_FragColor = vec4(v_T.xy, 0.0, 1.0); }",
    );
    assert!(both.program.fragment.as_ref().unwrap().text.contains("in vec2 v_T;"), "the fragment input takes the vertex width");
    // (c) the fragment stage selects more than it declares and the vertex stage declares enough
    let both = compile_program(
        "varying vec4 v_T;\nvoid main() { v_T = CAST4(1.0); gl_Position = CAST4(1.0); }",
        "varying vec2 v_T;\nvoid main() { gl_FragColor = vec4(v_T.zw, 0.0, 1.0); }",
    );
    let (vt, ft) = (&both.program.vertex.as_ref().unwrap().text, &both.program.fragment.as_ref().unwrap().text);
    assert!(vt.contains("out vec4 v_T;") && ft.contains("in vec4 v_T;"), "both use the vertex type:\n{vt}\n{ft}");
    // float1 is float
    let _ = compile_program(
        "varying float1 v_S;\nvoid main() { v_S = 1.0; gl_Position = CAST4(1.0); }",
        "varying float v_S;\nvoid main() { gl_FragColor = CAST4(v_S); }",
    );
}

#[test]
fn a_width_difference_the_stages_use_is_a_cross_stage_error() {
    let msg = |v: &str, f: &str| -> LegalizeError { program_err(v, f) };
    // the vertex stage uses components the fragment stage lacks
    let e = msg(
        "varying vec4 v_T;\nvoid main() { v_T = CAST4(1.0); gl_Position = vec4(v_T.zw, 0.0, 1.0); }",
        "varying vec2 v_T;\nvoid main() { gl_FragColor = vec4(v_T, 0.0, 1.0); }",
    );
    assert!(e.is_cross_stage());
    assert_eq!(e.message(), "cross-stage varying `v_T` type mismatch: vertex outputs vec4 but fragment inputs vec2");
    assert_eq!(e.diagnostics()[0].stage, Some(StageKind::Fragment));
    assert!(e.diagnostics()[0].span.is_some());
    // the fragment stage reads a wider input as a whole
    let e = msg(
        "varying vec2 v_T;\nvoid main() { v_T = CAST2(1.0); gl_Position = CAST4(1.0); }",
        "varying vec4 v_T;\nvoid main() { gl_FragColor = v_T; }",
    );
    assert_eq!(e.message(), "cross-stage varying `v_T` type mismatch: vertex outputs vec2 but fragment inputs vec4");
    // the fragment stage reads a component the vertex stage lacks
    let e = msg(
        "varying vec2 v_T;\nvoid main() { v_T = CAST2(1.0); gl_Position = CAST4(1.0); }",
        "varying vec4 v_T;\nvoid main() { gl_FragColor = vec4(v_T.xyz, 1.0); }",
    );
    assert!(e.message().contains("type mismatch"), "{e}");
    // unrelated types
    let e = msg(
        "varying vec3 v_T;\nvoid main() { v_T = CAST3(1.0); gl_Position = CAST4(1.0); }",
        "varying ivec3 v_T;\nvoid main() { gl_FragColor = CAST4(float(v_T.x)); }",
    );
    assert!(e.message().contains("type mismatch: vertex outputs vec3 but fragment inputs ivec3"), "{e}");
}

#[test]
fn a_varying_declared_twice_or_with_other_bounds_is_refused() {
    let e = program_err(
        "varying vec2 v_A; varying vec2 v_A;\nvoid main() { gl_Position = CAST4(1.0); }",
        "varying vec2 v_A;\nvoid main() { gl_FragColor = vec4(v_A, 0.0, 1.0); }",
    );
    assert!(e.is_cross_stage() && e.message().contains("v_A") && e.message().contains("twice"), "{e}");
    let e = program_err(
        "varying vec2 v_A[3];\nvoid main() { v_A[0] = CAST2(0.0); gl_Position = CAST4(1.0); }",
        "varying vec2 v_A[2];\nvoid main() { gl_FragColor = vec4(v_A[1], 0.0, 1.0); }",
    );
    assert!(e.is_cross_stage() && e.message().contains("v_A") && e.message().contains('3') && e.message().contains('2'), "{e}");
    let e = program_err(
        "varying vec2 v_A;\nvoid main() { v_A = CAST2(0.0); gl_Position = CAST4(1.0); }",
        "varying vec2 v_A[2];\nvoid main() { gl_FragColor = vec4(v_A[1], 0.0, 1.0); }",
    );
    assert!(e.is_cross_stage(), "{e}");
}

#[test]
fn written_inputs_are_copied_into_locals_and_reflected_under_their_source_names() {
    let v = "attribute vec3 a_Position; attribute vec4 a_Col; attribute vec2 a_Uv; attribute float a_W; attribute vec2 a_Pair;\nvoid main() { a_Col.rg *= 2.0; a_Uv = a_Uv * 0.5; a_W++; a_Pair[0] += 1.0; gl_Position = vec4(a_Position, a_Col.r + a_W + a_Uv.x + a_Pair.x); }";
    let both = compile_program(v, "void main() { gl_FragColor = CAST4(1.0); }");
    let t = &both.program.vertex.as_ref().unwrap().text;
    for name in ["a_Col", "a_Uv", "a_W", "a_Pair"] {
        assert!(t.contains(&format!(" _we_in_{name};")), "{name}: {t}");
        assert!(t.contains(&format!("{name} = _we_in_{name};")), "{name}: {t}");
    }
    assert!(!t.contains("_we_in_a_Position"), "a read-only input keeps its name and has no copy: {t}");
    let inputs = names_with_locations(&both.program.layout.vertex_inputs);
    assert_eq!(inputs, [("a_Position".into(), 0), ("a_Col".into(), 1), ("a_Uv".into(), 2), ("a_W".into(), 3), ("a_Pair".into(), 4)], "the copy keeps the location its name would have had");
    assert_eq!(both.program.layout.vertex_inputs[1].emitted_name, "_we_in_a_Col");
}

#[test]
fn a_written_fragment_input_is_copied_and_a_read_only_one_is_not() {
    let f = "varying vec4 v_Tint; varying vec2 v_Uv;\nvoid main() { v_Tint.rg *= 0.5; gl_FragColor = v_Tint + vec4(v_Uv, 0.0, 0.0); }";
    let t = frag(f);
    assert!(t.contains("in vec4 _we_in_v_Tint;") && t.contains("v_Tint = _we_in_v_Tint;"), "{t}");
    assert!(t.contains("in vec2 v_Uv;") && !t.contains("_we_in_v_Uv"), "{t}");
    // the other stage still finds it by its source name
    let both = compile_program(
        "varying vec4 v_Tint;\nvoid main() { v_Tint = CAST4(1.0); gl_Position = CAST4(1.0); }",
        f,
    );
    let plan = both.program.layout.varyings.iter().find(|v| v.name == "v_Tint").unwrap();
    assert!(plan.in_vertex && plan.in_fragment);
}

#[test]
fn a_written_array_input_keeps_its_array_suffix_in_the_copy() {
    let f = "varying float v_W[3];\nvoid main() { v_W[1] = 2.0; gl_FragColor = CAST4(v_W[1] + v_W[2]); }";
    let t = frag(f);
    assert!(t.contains("in float _we_in_v_W[3];") && t.contains("float v_W[3];"), "{t}");
    let _ = compile_frag(f);
}

#[test]
fn the_fragment_colour_output_exists_only_when_referenced() {
    let t = frag("varying vec4 v;\nvoid main() { gl_FragColor = v; }");
    assert!(t.contains("layout(location = 0) out vec4 _we_FragColor;") && t.contains("_we_FragColor = v;") && !t.contains("gl_FragColor"), "{t}");
    let t = frag("varying vec4 v;\nvoid main() { discard; }");
    assert!(!t.contains("out vec4"), "{t}");
    // an author-declared output keeps its place and gets locations from 0
    let t = frag("out vec4 outA; out vec2 outB;\nvoid main() { outA = CAST4(1.0); outB = CAST2(0.0); }");
    assert!(t.contains("layout(location = 0) out vec4 outA;") && t.contains("layout(location = 1) out vec2 outB;"), "{t}");
    // a vertex stage is not touched
    let t = vert("void main() { gl_Position = CAST4(1.0); }");
    assert!(!t.contains("_we_FragColor"));
    let both = compile_program("void main() { gl_Position = CAST4(1.0); }", "void main() { gl_FragColor = CAST4(1.0); }");
    assert!(both.program.fragment.as_ref().unwrap().text.contains("_we_FragColor"));
}

#[test]
fn a_macro_that_names_the_colour_output_reaches_the_new_name() {
    let t = frag("#define OUT gl_FragColor\nvoid main() { OUT = CAST4(1.0); }");
    assert!(t.contains("_we_FragColor = vec4(1.0)") && !t.contains("gl_FragColor"), "{t}");
}

#[test]
fn redeclared_builtins_are_dropped_whatever_their_qualifier() {
    let v = "attribute vec4 gl_Position; out float gl_PointSize; varying vec4 gl_FragCoord; in uint gl_VertexID; in uint gl_InstanceID; attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, float(gl_VertexID + gl_InstanceID)); }";
    let both = compile_program(v, "in vec4 gl_FragCoord; in bool gl_FrontFacing;\nvoid main() { gl_FragColor = gl_FrontFacing ? gl_FragCoord : CAST4(0.0); }");
    let t = &both.program.vertex.as_ref().unwrap().text;
    assert!(!t.contains("in vec4 gl_Position") && !t.contains("out float gl_PointSize") && !t.contains("in uint gl_VertexID"), "{t}");
    assert!(t.contains("gl_VertexIndex") && t.contains("gl_InstanceIndex") && !t.contains("gl_VertexID"), "the index builtins are renamed: {t}");
    assert_eq!(names_with_locations(&both.program.layout.vertex_inputs), [("a_Position".into(), 0)], "no builtin becomes a vertex attribute");
    assert!(both.vertex.msl.contains("[[vertex_id]]") && both.vertex.msl.contains("[[instance_id]]"), "{}", both.vertex.msl);
}

#[test]
fn an_index_builtin_in_a_macro_is_renamed_where_the_macro_is_written() {
    let t = vert("#define IDX gl_VertexID\nvoid main() { gl_Position = vec4(float(IDX), float(int(gl_VertexID) - 5), float(gl_InstanceID << 2u), 1.0); }");
    assert!(t.contains("gl_VertexIndex") && !t.contains("gl_VertexID") && !t.contains("gl_InstanceID"), "{t}");
}

#[test]
fn an_index_declared_with_another_type_or_an_unbacked_builtin_keeps_its_declaration() {
    // `gl_VertexID` declared as an int is an ordinary attribute of the shader
    let (stage, layout) = crate::legalize::legalize_stage(StageKind::Vertex, "attribute int gl_VertexID;\nvoid main() { gl_Position = CAST4(float(gl_VertexID)); }").unwrap();
    assert!(stage.text.contains("in int gl_VertexID;"), "{}", stage.text);
    assert_eq!(layout.vertex_inputs.len(), 1);
    // builtins naga has no variable for pass through as ordinary globals
    let t = vert("in int gl_PrimitiveID; in float gl_ClipDistance; attribute vec3 a_P;\nvoid main() { gl_Position = vec4(a_P, 1.0); }");
    assert!(t.contains("in int gl_PrimitiveID;") && t.contains("in float gl_ClipDistance;"), "{t}");
    // a name that only contains gl_ is an interface variable
    let p = program("attribute float a_Weight_gl; varying float v_gl_Haze;\nvoid main() { v_gl_Haze = a_Weight_gl; gl_Position = CAST4(1.0); }", "varying float v_gl_Haze;\nvoid main() { gl_FragColor = CAST4(v_gl_Haze); }");
    assert_eq!(p.layout.vertex_inputs.len(), 1);
    assert_eq!(p.layout.varyings.len(), 1);
}

#[test]
fn a_qualified_declaration_with_several_names_is_handled_name_by_name() {
    let v = "uniform float g_A, g_B; attribute vec2 a_P, a_Q; varying vec2 v_X, v_Y;\nvoid main() { v_X = a_P; v_Y = a_Q; gl_Position = CAST4(g_A + g_B); }";
    let f = "varying vec2 v_Y, v_X;\nvoid main() { gl_FragColor = vec4(v_X, v_Y); }";
    let both = compile_program(v, f);
    assert_eq!(names_with_locations(&both.program.layout.vertex_inputs), [("a_P".into(), 0), ("a_Q".into(), 1)]);
    let t = &both.program.vertex.as_ref().unwrap().text;
    assert!(t.contains("float g_A;") && t.contains("float g_B;"), "{t}");
    assert_eq!(both.program.layout.varyings.len(), 2);
}

#[test]
fn flat_is_carried_on_an_interface_declaration() {
    let both = compile_program(
        "varying flat int v_I; varying mediump vec2 v_U;\nvoid main() { v_I = 3; v_U = CAST2(0.0); gl_Position = CAST4(1.0); }",
        "varying flat int v_I; varying highp vec2 v_U;\nvoid main() { gl_FragColor = vec4(float(v_I), v_U, 1.0); }",
    );
    let t = &both.program.fragment.as_ref().unwrap().text;
    assert!(t.contains("flat in int v_I;") && t.contains("in vec2 v_U;") && !t.contains("highp vec2"), "{t}");
}

// ---- amendment c2 R90 and d R66: no cap on varying locations, a component budget instead ----

fn many_varyings(n: usize, ty: &str) -> String {
    (0..n).map(|i| format!("varying {ty} v_{i};\n")).collect()
}

fn sum_of(n: usize) -> String {
    (0..n).map(|i| format!("v_{i}")).collect::<Vec<_>>().join(" + ")
}

#[test]
fn a_varying_location_above_31_is_accepted_in_a_program_and_in_either_stage_alone() {
    let decls = many_varyings(40, "vec2");
    let writes: String = (0..40).map(|i| format!("v_{i} = CAST2({i}.0);")).collect();
    let v = format!("{decls}void main() {{ {writes} gl_Position = CAST4(1.0); }}");
    let f = format!("{decls}void main() {{ vec2 s = {}; gl_FragColor = vec4(s, 0.0, 1.0); }}", sum_of(40));
    let both = compile_program(&v, &f);
    assert_eq!(location_of(&both.program.fragment.as_ref().unwrap().text, "v_39"), 39);
    assert_eq!(location_of(&both.program.vertex.as_ref().unwrap().text, "v_39"), 39);
    // Alone, the stage numbers its own inputs and outputs from 0 and has no cap on a varying either.
    let (alone, _) = crate::legalize::legalize_stage(StageKind::Fragment, &f).unwrap();
    assert_eq!(location_of(&alone.text, "v_39"), 39);
    let (alone, _) = crate::legalize::legalize_stage(StageKind::Vertex, &v).unwrap();
    assert_eq!(location_of(&alone.text, "v_39"), 39);
}

#[test]
fn the_budget_counts_the_fragment_inputs_and_names_the_varying_that_crossed_it() {
    let ok = format!("{}void main() {{ gl_FragColor = {}; }}", many_varyings(31, "vec4"), sum_of(31));
    assert!(crate::legalize::legalize_stage(StageKind::Fragment, &ok).is_ok());
    let over = format!("{}varying float v_extra;\nvoid main() {{ gl_FragColor = {} + CAST4(v_extra); }}", many_varyings(31, "vec4"), sum_of(31));
    let e = crate::legalize::legalize_stage(StageKind::Fragment, &over).unwrap_err();
    assert!(e.is_invalid_request(), "{e}");
    let text = e.message();
    assert!(text.contains("125") && text.contains("124") && text.contains("fragment") && text.contains("v_extra"), "{text}");
    // A vertex stage alone never counts: its outputs are free until a fragment stage names them.
    let many = format!("{}void main() {{ gl_Position = CAST4(1.0); }}", many_varyings(60, "vec4"));
    assert!(crate::legalize::legalize_stage(StageKind::Vertex, &many).is_ok());
}

#[test]
fn the_cap_of_a_vertex_input_location_stays() {
    // 33 attributes: the last would sit at location 32, above the model's limit of 31.
    let attributes: String = (0..33).map(|i| format!("attribute vec4 a_{i};\n")).collect();
    let sum: String = (0..33).map(|i| format!("a_{i}")).collect::<Vec<_>>().join(" + ");
    let source = format!("{attributes}void main() {{ gl_Position = {sum}; }}");
    let e = crate::legalize::legalize_stage(StageKind::Vertex, &source).unwrap_err();
    assert!(e.message().contains("highest location 31") && e.message().contains("vertex"), "{e}");
}
