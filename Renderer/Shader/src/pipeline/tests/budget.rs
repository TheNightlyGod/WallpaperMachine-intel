// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Amendments 1, D3: no cap on varying location numbers (c2 R90) and the inter-stage component
//! budget of 124 (d R66); each test is the black-box check of its amendment.

use super::support::*;
use crate::error::{ErrorCategory, ShaderError};
use crate::request::StageKind;

fn varyings(declarations: &str, writes: &str, reads: &str) -> Req {
    Req::new(&vertex_with(declarations, writes), &fragment_with(declarations, reads))
}

fn components_error(e: &ShaderError) -> String {
    assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{e}");
    e.to_string()
}

fn write_all(names: &[(&str, &str)]) -> (String, String) {
    // Every varying is written in the vertex stage and read in the fragment stage.
    let writes: String = names.iter().map(|(n, ty)| format!("  {n} = {};\n", if ty.contains('[') { zero_array(ty) } else { zero(ty) })).collect();
    let reads: String = names.iter().map(|(n, ty)| format!("  c.x += {}.x;\n", if ty.contains('[') { format!("{n}[0]") } else { n.to_string() })).collect();
    (writes, reads)
}

fn zero(ty: &str) -> String {
    match ty {
        "float" => "0.5".to_string(),
        t => format!("{t}(0.5)"),
    }
}

fn zero_array(ty: &str) -> String {
    let (base, rest) = ty.split_once('[').unwrap();
    let n: usize = rest.trim_end_matches(']').parse().unwrap();
    format!("{base}[{n}]({})", vec![zero(base); n].join(", "))
}

fn declare(names: &[(&str, &str)]) -> String {
    names
        .iter()
        .map(|(n, ty)| match ty.split_once('[') {
            Some((base, rest)) => format!("varying {base} {n}[{}", rest),
            None => format!("varying {ty} {n};"),
        })
        .map(|l| if l.ends_with(']') { format!("{l};") } else { l })
        .collect::<Vec<_>>()
        .join("\n")
}

fn program_of(names: &[(&str, &str)]) -> Req {
    let (writes, reads) = write_all(names);
    varyings(&declare(names), &writes, &reads)
}

#[test]
fn a_tap_array_past_location_31_compiles_and_nothing_mentions_a_location_cap() {
    // 49 vec2 (98 components) and a vec4: 102 components, locations up to 49.
    let p = program_of(&[("v_Ring", "vec2[49]"), ("v_Main", "vec4")]).ok();
    let f = glsl_of(&p, StageKind::Fragment);
    let v = glsl_of(&p, StageKind::Vertex);
    assert_eq!(declared_location(&f, "v_Ring"), Some(0));
    assert_eq!(declared_location(&f, "v_Main"), Some(49));
    assert_eq!(declared_location(&v, "v_Main"), Some(49));
    let (outputs, inputs) = interface_of(&p);
    assert_eq!(outputs.iter().map(|(_, l)| *l).max(), Some(49), "{outputs:?}");
    assert_eq!(inputs.iter().map(|(_, l)| *l).max(), Some(49), "{inputs:?}");
    let msl = &p.stage(StageKind::Fragment).unwrap().payload.msl_source;
    assert!(msl.contains("[[user(loc49)") && msl.contains("v_Ring_48 [[user(loc48)"), "{msl}");
    // Location numbers are free: a varying written alone behind a large vertex-only prefix still compiles.
    let wide = Req::new(
        &vertex_with(
            &(0..40).map(|i| format!("varying vec4 v_Extra{i};")).collect::<Vec<_>>().join("\n"),
            &(0..40).map(|i| format!("  v_Extra{i} = vec4(1.0);")).collect::<Vec<_>>().join("\n"),
        ),
        &fragment_with("varying vec4 v_Only;", "  c = v_Only;"),
    )
    .ok();
    assert_eq!(wide.stages.len(), 2);
}

fn thirty_one_vec4() -> Vec<(String, &'static str)> {
    (0..31).map(|i| (format!("v_{i}"), "vec4")).collect()
}

fn named<'a>(list: &'a [(String, &'static str)]) -> Vec<(&'a str, &'static str)> {
    list.iter().map(|(n, t)| (n.as_str(), *t)).collect()
}

#[test]
fn the_budget_is_124_components_by_the_sum_of_the_fragment_inputs() {
    let base = thirty_one_vec4();
    // 31 vec4 = 124 components: accepted.
    let p = program_of(&named(&base)).ok();
    assert_eq!(p.stage(StageKind::Fragment).unwrap().glsl.matches("layout(location").count(), 32); // 31 inputs and the colour output
    // One more float makes 125.
    let mut more = base.clone();
    more.push(("v_Extra".into(), "float"));
    let e = program_of(&named(&more)).err();
    let text = components_error(&e);
    assert!(text.contains("125") && text.contains("124") && text.contains("fragment"), "{text}");
    assert!(text.contains("v_Extra"), "the varying whose addition crossed the limit is named: {text}");
    // 32 vec4 fail, and the 32nd is the one named.
    let mut thirty_two = base.clone();
    thirty_two.push(("v_Last".into(), "vec4"));
    let text = components_error(&program_of(&named(&thirty_two)).err());
    assert!(text.contains("128") && text.contains("124") && text.contains("v_Last"), "{text}");
    // 62 vec2 are 124; 63 are 126.
    assert!(program_of(&[("v_Ring", "vec2[62]")]).compile().is_ok());
    let text = components_error(&program_of(&[("v_Ring", "vec2[63]")]).err());
    assert!(text.contains("126") && text.contains("124") && text.contains("v_Ring"), "{text}");
}

#[test]
fn the_crossing_varying_is_found_in_source_order_not_by_size() {
    // 100 + 20 + 8: the third declaration crosses 124 although the first is by far the largest.
    let names = [("v_Big", "vec4[25]"), ("v_Mid", "vec4[5]"), ("v_Small", "vec2[4]")];
    let text = components_error(&program_of(&names).err());
    assert!(text.contains("128") && text.contains("v_Small") && !text.contains("v_Big`") && !text.contains("`v_Mid"), "{text}");
}

#[test]
fn vertex_outputs_no_fragment_input_names_are_free() {
    let extra: Vec<(String, &'static str)> = (0..40).map(|i| (format!("v_X{i}"), "vec4")).collect();
    let vertex_declarations = format!("{}\nvarying vec2 v_Use;", declare(&named(&extra)));
    let writes: String = extra.iter().map(|(n, _)| format!("  {n} = vec4(1.0);\n")).collect::<String>() + "  v_Use = a_Coord;\n";
    let fragment = fragment_with("varying vec2 v_Use;\nvarying float v_Alone;", "  c = vec4(v_Use, v_Alone, 1.0);");
    let p = Req::new(&vertex_with(&vertex_declarations, &writes), &fragment).ok();
    assert!(p.stage(StageKind::Vertex).unwrap().glsl.contains("v_X39"));
    // 32 float4 vertex outputs next to 31 fragment inputs: only the fragment side counts.
    let vertex_names = thirty_one_vec4();
    let mut vertex_list = named(&vertex_names);
    vertex_list.push(("v_V32", "vec4"));
    let (writes, _) = write_all(&vertex_list);
    let (_, reads) = write_all(&named(&vertex_names));
    let p = Req::new(&vertex_with(&declare(&vertex_list), &writes), &fragment_with(&declare(&named(&vertex_names)), &reads)).ok();
    assert_eq!(p.stages.len(), 2);
}

#[test]
fn fragment_only_varyings_count_and_builtins_do_not() {
    // Fragment-only varyings get a synthesized vertex output and still count in full.
    let text = components_error(&Req::new(&vertex_with("", ""), &fragment_with(&declare(&[("v_A", "vec4[31]"), ("v_B", "float")]), "  c = v_A[0] + vec4(v_B);")).err());
    assert!(text.contains("125") && text.contains("v_B"), "{text}");
    // gl_FragCoord and friends are builtins: 31 vec4 plus a read of the fragment position is fine.
    let names = thirty_one_vec4();
    let (writes, reads) = write_all(&named(&names));
    let p = Req::new(&vertex_with(&declare(&named(&names)), &writes), &fragment_with(&declare(&named(&names)), &format!("{reads}  c.y += gl_FragCoord.y;"))).ok();
    assert_eq!(p.stages.len(), 2);
}

#[test]
fn the_budget_follows_the_reconciled_width_and_matrices_count_columns_times_rows() {
    // 31 vec4 declared in the fragment stage, but the vertex stage writes vec2 and the fragment only
    // selects `.xy`: after reconciliation they are 62 components.
    let vertex_names: Vec<(String, &'static str)> = (0..31).map(|i| (format!("v_{i}"), "vec2")).collect();
    let vertex_list = named(&vertex_names);
    let writes: String = vertex_list.iter().map(|(n, _)| format!("  {n} = a_Coord;\n")).collect();
    let reads: String = vertex_list.iter().map(|(n, _)| format!("  c.xy += {n}.xy;\n")).collect();
    let fragment_declarations = declare(&named(&thirty_one_vec4()).iter().zip(&vertex_list).map(|((_, t), (n, _))| (*n, *t)).collect::<Vec<_>>());
    let p = Req::new(&vertex_with(&declare(&vertex_list), &writes), &fragment_with(&fragment_declarations, &reads)).ok();
    assert_eq!(p.stages.len(), 2);
    // mat4 is 16 components; eight of them are 128.
    let text = components_error(&program_of(&[("v_M", "mat4[8]")]).err());
    assert!(text.contains("128") && text.contains("124"), "{text}");
}

#[test]
fn vertex_input_locations_keep_their_cap_of_30() {
    let many = |n: u32| {
        let declarations: String = (0..n).map(|i| format!("attribute vec4 a_{i};\n")).collect();
        let sum: Vec<String> = (0..n).map(|i| format!("a_{i}")).collect();
        format!("{declarations}void main() {{ gl_Position = {}; }}", sum.join(" + "))
    };
    let fragment = "void main() { gl_FragColor = vec4(1.0); }";
    let p = ok(&many(31), fragment);
    assert_eq!(p.reflection.vertex_inputs.last().unwrap().location, 30);
    assert!(err(&many(32), fragment).to_string().contains("31"));
}
