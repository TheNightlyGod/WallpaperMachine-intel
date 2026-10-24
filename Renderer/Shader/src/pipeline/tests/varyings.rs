// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The varying interface of a program (spec D 4.2, tests 6 to 10): matching by name, widths,
//! synthesized outputs, array bounds, and what the Metal text shows of all of it.

use std::collections::HashSet;

use super::support::*;
use crate::error::{ErrorCategory, ShaderError};
use crate::request::StageKind;

fn vert(declarations: &str, body: &str) -> String {
    vertex_with(declarations, body)
}

fn frag(declarations: &str, body: &str) -> String {
    fragment_with(declarations, body)
}

fn legalized(p: &crate::pipeline::CompiledProgram, kind: StageKind) -> String {
    p.stage(kind).unwrap().glsl.clone()
}

fn cross_stage(e: &ShaderError) -> &crate::diagnostic::Diagnostic {
    assert_eq!(e.category(), ErrorCategory::Legalization, "{e}");
    let ShaderError::Source { failures, .. } = e else { panic!("expected a diagnostic failure: {e}") };
    assert_eq!(failures.len(), 1, "a single diagnostic: {e}");
    &failures[0].diagnostic
}

// ---- 6: locations by name ----

#[test]
fn locations_follow_the_fragment_declaration_order_in_both_stages() {
    let p = ok(
        &vert("varying vec2 v_Tex;\nvarying vec3 v_Pos;", "  v_Tex = a_Coord;\n  v_Pos = a_Position;"),
        &frag("varying vec3 v_Pos;\nvarying vec2 v_Tex;", "  c = vec4(v_Pos, v_Tex.x);"),
    );
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        let glsl = legalized(&p, kind);
        assert_eq!(declared_location(&glsl, "v_Pos"), Some(0), "{kind:?}");
        assert_eq!(declared_location(&glsl, "v_Tex"), Some(1), "{kind:?}");
    }
    // The vertex declaration order does not matter.
    let q = ok(
        &vert("varying vec3 v_Pos;\nvarying vec2 v_Tex;", "  v_Tex = a_Coord;\n  v_Pos = a_Position;"),
        &frag("varying vec3 v_Pos;\nvarying vec2 v_Tex;", "  c = vec4(v_Pos, v_Tex.x);"),
    );
    let sorted = |mut list: Vec<(String, u32)>| {
        list.sort();
        list
    };
    assert_eq!(sorted(interface_of(&p).1), sorted(interface_of(&q).1));
    assert_eq!(sorted(interface_of(&p).0), sorted(interface_of(&q).0));
}

#[test]
fn an_array_between_two_scalars_takes_a_location_per_element() {
    let decls = "varying float v_A;\nvarying vec2 v_Taps[3];\nvarying float v_B;";
    let writes = "  v_A = 1.0;\n  v_Taps[0] = a_Coord;\n  v_Taps[1] = a_Coord;\n  v_Taps[2] = a_Coord;\n  v_B = 2.0;";
    let p = ok(&vert(decls, writes), &frag(decls, "  c = vec4(v_A + v_B + v_Taps[2].x);"));
    let f = legalized(&p, StageKind::Fragment);
    assert_eq!((declared_location(&f, "v_A"), declared_location(&f, "v_Taps"), declared_location(&f, "v_B")), (Some(0), Some(1), Some(4)));
    let (vertex_outputs, fragment_inputs) = interface_of(&p);
    let numbers: Vec<u32> = fragment_inputs.iter().map(|(_, n)| *n).collect();
    assert_eq!(numbers, [0, 1, 2, 3, 4]);
    for (name, loc) in &fragment_inputs {
        assert!(vertex_outputs.contains(&(name.clone(), *loc)), "{name} at {loc}");
    }
}

#[test]
fn macro_sized_arrays_follow_the_combo() {
    for taps in [2u32, 3, 6] {
        let decls = "varying vec2 v_Taps[TAPS];\nvarying float v_After;";
        let writes = "  for (int i = 0; i < TAPS; i++) { v_Taps[i] = a_Coord; }\n  v_After = 1.0;";
        let p = Req::new(&vert(decls, writes), &frag(decls, "  c = vec4(v_After);")).combo("TAPS", &taps.to_string()).ok();
        let f = legalized(&p, StageKind::Fragment);
        assert_eq!(declared_location(&f, "v_Taps"), Some(0), "TAPS={taps}");
        assert_eq!(declared_location(&f, "v_After"), Some(taps), "TAPS={taps}");
        assert!(f.contains(&format!("v_Taps[{taps}]")), "the bound is a number in the legalized text: {f}");
        assert!(!f.contains("TAPS"), "{f}");
    }
}

#[test]
fn a_macro_redefined_between_declarations_gives_each_its_own_size() {
    let both = |tail: &str| format!("#define N 3\nvarying vec2 a[N];\n#undef N\n#define N 5\nvarying vec2 b[N];\nvarying vec2 c_;\n{tail}");
    let writes = "  for (int i = 0; i < 3; i++) { a[i] = a_Coord; }\n  for (int i = 0; i < 5; i++) { b[i] = a_Coord; }\n  c_ = a_Coord;";
    let p = ok(&vert(&both(""), writes), &frag(&both(""), "  c = vec4(a[2].x + b[4].x + c_.x);"));
    let f = legalized(&p, StageKind::Fragment);
    assert_eq!((declared_location(&f, "a"), declared_location(&f, "b"), declared_location(&f, "c_")), (Some(0), Some(3), Some(8)));
    assert!(f.contains("a[3]") && f.contains("b[5]"), "{f}");
}

#[test]
fn a_definition_inside_an_earlier_function_body_counts_for_later_declarations() {
    let text = |tail: &str| format!("void helper() {{\n#define LATE 4\n}}\nvarying vec2 v_Late[LATE];\n{tail}");
    let p = ok(&vert(&text(""), "  for (int i = 0; i < 4; i++) { v_Late[i] = a_Coord; }"), &frag(&text(""), "  c = vec4(v_Late[3], 0.0, 0.0);"));
    assert!(legalized(&p, StageKind::Fragment).contains("v_Late[4]"));
}

#[test]
fn a_bare_define_gives_a_bound_of_one() {
    let decls = "#define TAPS 6\n#define TAPS\nvarying vec2 v_One[TAPS];\nvarying float v_After;";
    let p = ok(&vert(decls, "  v_One[0] = a_Coord;\n  v_After = 1.0;"), &frag(decls, "  c = vec4(v_One[0], v_After, 0.0);"));
    let f = legalized(&p, StageKind::Fragment);
    assert!(f.contains("v_One[1]"), "{f}");
    assert_eq!(declared_location(&f, "v_After"), Some(1));
}

#[test]
fn every_rejected_bound_form_fails_naming_the_text_before_locations_exist() {
    let cases: [(&str, &str, &str); 9] = [
        ("", "1<<2", ""),
        ("", "3u", ""),
        ("", "0x4", ""),
        ("", "2.0", ""),
        ("", "0", ""),
        ("", "-1", ""),
        ("", "UNKNOWN_BOUND", ""),
        ("", "LATER", "#define LATER 3\n"),
        ("#define FUNCLIKE 3\n#define FUNCLIKE(x) x\n", "FUNCLIKE", ""),
    ];
    for (before, bound, after) in cases {
        let decls = format!("{before}varying vec2 v_Bad[{bound}];\n{after}");
        let e = err(&vert(&decls, "  gl_Position = vec4(0.0);"), &frag(&decls, "  c = vec4(0.0);"));
        let text = e.to_string();
        assert!(text.contains(bound) && text.contains("bound"), "{bound}: {text}");
        assert!(matches!(e.category(), ErrorCategory::Legalization | ErrorCategory::InvalidRequest), "{bound}: {e}");
    }
}

// ---- 7: width rules ----

fn pair(vertex_decl: &str, vertex_body: &str, fragment_decl: &str, fragment_body: &str) -> Result<crate::pipeline::CompiledProgram, ShaderError> {
    Req::new(&vert(vertex_decl, vertex_body), &frag(fragment_decl, fragment_body)).compile()
}

fn agreed(p: &crate::pipeline::CompiledProgram, name: &str, ty: &str, location: u32) {
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        let glsl = legalized(p, kind);
        assert_eq!(declared_type(&glsl, name).as_deref(), Some(ty), "{kind:?} type of {name}:\n{glsl}");
        assert_eq!(declared_location(&glsl, name), Some(location), "{kind:?} location of {name}");
    }
}

#[test]
fn a_narrow_producer_is_declared_with_the_fragments_type() {
    // The vertex stage only writes a prefix by swizzle.
    let p = pair("varying vec4 v_Warp;", "  v_Warp.xy = a_Coord;", "varying vec2 v_Warp;", "  c = vec4(v_Warp, 0.0, 1.0);").unwrap();
    agreed(&p, "v_Warp", "vec2", 0);
    // Or the whole variable by plain assignment: the assigned value is narrowed.
    let p = pair("varying vec4 v_Warp;", "  v_Warp = vec4(a_Coord, 0.0, 1.0);", "varying vec2 v_Warp;", "  c = vec4(v_Warp, 0.0, 1.0);").unwrap();
    agreed(&p, "v_Warp", "vec2", 0);
    // A vertex stage that never touches it qualifies too.
    let p = pair("varying vec4 v_Warp;", "", "varying vec2 v_Warp;", "  c = vec4(v_Warp, 0.0, 1.0);").unwrap();
    agreed(&p, "v_Warp", "vec2", 0);
}

#[test]
fn a_narrow_producer_that_the_vertex_stage_uses_beyond_the_prefix_is_refused() {
    for body in [
        "  v_Warp.zw = a_Coord;",             // writes components that would be discarded
        "  v_Warp.xy = a_Coord;\n  gl_Position = v_Warp;", // reads its own output as a whole
        "  v_Warp = vec4(a_Coord, 0.0, 1.0);\n  v_Warp += vec4(1.0);", // compound assignment
    ] {
        let e = pair("varying vec4 v_Warp;", body, "varying vec2 v_Warp;", "  c = vec4(v_Warp, 0.0, 1.0);").unwrap_err();
        let text = cross_stage(&e).message.clone();
        assert!(text.contains("v_Warp") && text.contains("vec4") && text.contains("vec2"), "{body}: {text}");
    }
    // The fragment stage reaching beyond its own declared width also disqualifies the narrowing,
    // but then the consumer is widened instead (case c), which needs the swizzle to fit.
    assert!(pair("varying vec4 v_Warp;", "  v_Warp.xy = a_Coord;", "varying vec2 v_Warp;", "  c = v_Warp.zwzw;").is_ok());
}

#[test]
fn a_narrow_consumer_takes_the_vertexs_type() {
    let p = pair("varying vec2 v_Flow;", "  v_Flow = a_Coord;", "varying vec3 v_Flow;", "  c = vec4(v_Flow.xy, 0.0, 1.0);").unwrap();
    agreed(&p, "v_Flow", "vec2", 0);
    // Reading the component the producer lacks, or the whole variable, is a mismatch.
    for read in ["  c = vec4(v_Flow.z);", "  c = vec4(v_Flow, 1.0);"] {
        let e = pair("varying vec2 v_Flow;", "  v_Flow = a_Coord;", "varying vec3 v_Flow;", read).unwrap_err();
        let text = cross_stage(&e).message.clone();
        assert!(text.contains("v_Flow") && text.contains("vec2") && text.contains("vec3"), "{read}: {text}");
    }
}

#[test]
fn a_widened_consumer_keeps_the_producers_width_in_every_combo() {
    // The fragment declares vec2 but reads `.zw`: the interface stays vec4, whether or not the
    // producer writes the extra components in this combo.
    let vertex_decl = "varying vec4 v_Uv;";
    let fragment = frag("varying vec2 v_Uv;", "  c = vec4(v_Uv.xy, v_Uv.zw);");
    for (combo, writes) in [("1", "  v_Uv = vec4(a_Coord, a_Coord);"), ("0", "  v_Uv.xy = a_Coord;")] {
        let vertex = vert(vertex_decl, &format!("#if WRITE_ZW\n{}\n#else\n{}\n#endif", "  v_Uv = vec4(a_Coord, a_Coord);", "  v_Uv.xy = a_Coord;"));
        let p = Req::new(&vertex, &fragment).combo("WRITE_ZW", combo).ok();
        agreed(&p, "v_Uv", "vec4", 0);
        let _ = writes;
    }
}

#[test]
fn an_array_pair_that_differs_in_width_is_a_mismatch() {
    let e = pair("varying vec4 v_Arr[2];", "  v_Arr[0] = vec4(1.0);\n  v_Arr[1] = vec4(1.0);", "varying vec2 v_Arr[2];", "  c = vec4(v_Arr[0], v_Arr[1]);").unwrap_err();
    assert!(cross_stage(&e).message.contains("v_Arr"));
}

#[test]
fn different_non_vector_types_are_a_mismatch_and_equal_spellings_agree() {
    let e = pair("varying ivec2 v_Id;", "  v_Id = ivec2(1);", "varying vec2 v_Id;", "  c = vec4(v_Id, 0.0, 1.0);").unwrap_err();
    let text = cross_stage(&e).message.clone();
    assert!(text.contains("v_Id") && text.contains("ivec2") && text.contains("vec2"), "{text}");
    // `float1` and `float` are the same type.
    let p = pair("varying float1 v_S;", "  v_S = 1.0;", "varying float v_S;", "  c = vec4(v_S);").unwrap();
    agreed(&p, "v_S", "float", 0);
}

#[test]
fn comments_neither_disqualify_nor_rescue() {
    // A swizzle in a comment does not widen the producer's use ...
    let p = pair("varying vec4 v_W;", "  v_W.xy = a_Coord; // v_W.zw = a_Coord;", "varying vec2 v_W;", "  c = vec4(v_W, 0.0, 1.0);").unwrap();
    agreed(&p, "v_W", "vec2", 0);
    // ... and one in a comment does not make a real whole read acceptable.
    let e = pair("varying vec2 v_W;", "  v_W = a_Coord;", "varying vec3 v_W;", "  c = vec4(v_W, 1.0); // only v_W.xy\n").unwrap_err();
    assert!(cross_stage(&e).message.contains("v_W"));
}

#[test]
fn the_error_carries_stage_span_and_origin_of_the_cross_stage_check() {
    let e = pair("varying vec2 v_Flow;", "  v_Flow = a_Coord;", "varying vec3 v_Flow;", "  c = vec4(v_Flow, 1.0);").unwrap_err();
    let d = cross_stage(&e);
    assert_eq!(d.stage, Some(StageKind::Fragment));
    assert!(d.span.is_some());
    assert_eq!(d.origin.as_deref(), Some("cross-stage interface check"));
    assert!(e.to_string().contains("cross-stage interface check"));
}

#[test]
fn the_first_mismatching_varying_in_vertex_order_is_reported() {
    let vd = "varying vec2 v_First;\nvarying vec2 v_Second;";
    let fd = "varying vec3 v_Second;\nvarying vec3 v_First;";
    let e = pair(vd, "  v_First = a_Coord;\n  v_Second = a_Coord;", fd, "  c = vec4(v_First, v_Second.x);").unwrap_err();
    assert!(cross_stage(&e).message.contains("v_First"));
}

#[test]
fn a_duplicate_declaration_is_found_before_a_type_mismatch_vertex_stage_first() {
    // The fragment stage also disagrees on the type, but the vertex stage's duplicate is reported.
    let e = pair("varying vec2 v_D;\nvarying vec2 v_D;", "  v_D = a_Coord;", "varying vec3 v_D;", "  c = vec4(v_D, 1.0);").unwrap_err();
    let d = cross_stage(&e);
    assert_eq!(d.stage, Some(StageKind::Vertex));
    assert!(d.message.contains("v_D") && d.message.contains("vertex") && d.message.contains("twice"), "{}", d.message);
    // In a fragment stage the first declaration that repeats an earlier name is the one named,
    // and the diagnostic points at the later declaration.
    let fragment = frag("varying vec2 v_A;\nvarying vec2 v_B;\nvarying vec2 v_B;\nvarying vec2 v_A;", "  c = vec4(v_A + v_B, 0.0, 1.0);");
    let e = Req::new(&vert("varying vec2 v_A;\nvarying vec2 v_B;", "  v_A = a_Coord;\n  v_B = a_Coord;"), &fragment).err();
    let d = cross_stage(&e);
    assert_eq!(d.stage, Some(StageKind::Fragment));
    assert!(d.message.contains("v_B") && !d.message.contains("v_A"), "{}", d.message);
    let span = d.span.unwrap();
    let ShaderError::Source { failures, .. } = &e else { unreachable!() };
    let source = failures[0].source.as_deref().unwrap();
    let second_b = source.rfind("varying vec2 v_B").unwrap();
    assert!(span.start() <= second_b + 8 && span.end() >= second_b, "the later declaration: {span:?} in {source}");
}

// ---- 8: fragment-only varyings ----

/// `(type, name)` of the interface declaration at `location` of a legalized text.
fn declaration_at(glsl: &str, location: u32) -> Option<(String, String)> {
    glsl.lines().find_map(|l| {
        let rest = l.strip_prefix(&format!("layout(location = {location}) "))?;
        if !(rest.starts_with("out ") || rest.contains(" out ")) {
            return None;
        }
        let decl = rest.split(';').next()?;
        let words: Vec<&str> = decl.split(' ').collect();
        let name = words.last()?.split('[').next()?.to_string();
        Some((words[words.len() - 2].to_string(), name))
    })
}

fn main_body_start(glsl: &str) -> &str {
    glsl.split_once("void main() {\n").expect("a main function").1
}

#[test]
fn a_fragment_only_varying_becomes_a_zero_initialised_vertex_output() {
    for (decl, ty, zero) in [
        ("varying float v_Only;", "float", "v_Only = 0.0;"),
        ("varying vec2 v_Only;", "vec2", "v_Only = vec2(0.0);"),
        ("varying vec4 v_Only;", "vec4", "v_Only = vec4(0.0);"),
        ("flat varying ivec3 v_Only;", "ivec3", "v_Only = ivec3(0);"),
    ] {
        let p = ok(&vert("", ""), &frag(decl, "  c = vec4(float(v_Only.x));").replace("v_Only.x", if ty == "float" { "v_Only" } else { "v_Only.x" }));
        let v = legalized(&p, StageKind::Vertex);
        assert_eq!(declared_type(&v, "v_Only").as_deref(), Some(ty), "{v}");
        assert!(main_body_start(&v).trim_start().starts_with(zero), "{ty}: the zero comes first:\n{v}");
        let (outputs, inputs) = interface_of(&p);
        assert_eq!(outputs.iter().map(|(_, n)| *n).collect::<Vec<_>>(), inputs.iter().map(|(_, n)| *n).collect::<Vec<_>>(), "{ty}");
    }
}

#[test]
fn a_fragment_only_array_is_zeroed_element_by_element() {
    let p = ok(&vert("", ""), &frag("varying vec2 v_Arr[3];", "  c = vec4(v_Arr[0] + v_Arr[2], 0.0, 1.0);"));
    let v = legalized(&p, StageKind::Vertex);
    assert!(v.contains("v_Arr[3]"), "{v}");
    let (outputs, inputs) = interface_of(&p);
    assert_eq!(outputs.len(), 3, "one output member per element");
    assert_eq!(inputs.len(), 3);
    // Every element is written: no element is left without a store in the vertex stage.
    let msl = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
    for i in 0..3 {
        assert!(msl.contains(&format!("v_Arr.inner[{i}] = ")) || msl.contains("v_Arr = type_"), "element {i} in\n{msl}");
    }
}

#[test]
fn a_generated_name_never_collides_with_the_vertex_stage() {
    // The fragment-only varyings reuse a vertex attribute, a vertex uniform and a vertex global
    // variable name, and one that already looks like a generated name.
    let vertex = "attribute vec3 a_Position;
attribute vec2 x;
uniform vec4 u_Name;
vec2 g_Local = vec2(1.0);
float _we_out_x = 1.0;
float v_Func() { return u_Name.x + g_Local.x + _we_out_x; }
void main() { gl_Position = vec4(a_Position, v_Func() + x.x); }
";
    let fragment = "varying vec2 x;
varying vec2 u_Name;
varying vec2 g_Local;
varying vec2 _we_out_x;
varying float v_Func;
void main() { gl_FragColor = vec4(x + u_Name + g_Local + _we_out_x, v_Func, 1.0); }
";
    let p = ok(vertex, fragment);
    let v = legalized(&p, StageKind::Vertex);
    let f = legalized(&p, StageKind::Fragment);
    let mut seen = HashSet::new();
    for location in 0..5u32 {
        let (_, name) = declaration_at(&v, location).unwrap_or_else(|| panic!("no vertex output at {location}:\n{v}"));
        assert!(seen.insert(name.clone()), "duplicate vertex name {name}:\n{v}");
        assert!(!["a_Position", "x", "u_Name", "g_Local", "_we_out_x", "v_Func"].contains(&name.as_str()) || declaration_at(&f, location).unwrap().1 == name, "{name}");
    }
    // Each fragment input is fed from the output at the same location, whatever it is called.
    let (outputs, inputs) = interface_of(&p);
    assert_eq!(outputs.iter().map(|(_, n)| *n).collect::<HashSet<_>>(), inputs.iter().map(|(_, n)| *n).collect::<HashSet<_>>());
}

#[test]
fn a_vertex_only_varying_stays_and_the_fragment_never_mentions_it() {
    let p = ok(
        &vert("varying vec4 v_Spare;
varying vec2 v_Tex;", "  v_Spare = vec4(1.0);
  v_Tex = a_Coord;"),
        &frag("varying vec2 v_Tex;", "  c = vec4(v_Tex, 0.0, 1.0);"),
    );
    let v = legalized(&p, StageKind::Vertex);
    let f = legalized(&p, StageKind::Fragment);
    assert_eq!(declared_location(&v, "v_Tex"), Some(0));
    assert_eq!(declared_location(&v, "v_Spare"), Some(1), "after every fragment-consumed one");
    assert!(!f.contains("v_Spare"));
}

#[test]
fn a_position_alias_and_a_redeclared_builtin_take_no_location() {
    // A shader that aliases the position through a macro, and one that restates gl_Position.
    let vertex = "attribute vec3 a_Position;\nvarying vec2 v_Tex;\nattribute vec2 a_Coord;\nout vec4 gl_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_Tex = a_Coord; }\n";
    let p = ok(vertex, &frag("varying vec2 v_Tex;", "  c = vec4(v_Tex, 0.0, 1.0);"));
    let v = legalized(&p, StageKind::Vertex);
    assert_eq!(declared_location(&v, "v_Tex"), Some(0));
    assert_eq!(declared_location(&v, "gl_Position"), None, "{v}");
    assert!(!v.contains("out vec4 gl_Position"), "{v}");
}

// ---- 9 and 10: locations are unique, and the text shows them on both sides ----

#[test]
fn matched_narrowed_widened_synthesized_and_vertex_only_varyings_share_numbers_in_the_text() {
    let vertex = vert(
        "varying vec2 v_Matched;\nvarying vec4 v_Narrowed;\nvarying vec4 v_Widened;\nvarying vec4 v_VertexOnly;",
        "  v_Matched = a_Coord;\n  v_Narrowed.xy = a_Coord;\n  v_Widened = vec4(a_Coord, a_Coord);\n  v_VertexOnly = vec4(1.0);",
    );
    let fragment = frag(
        "varying vec2 v_Matched;\nvarying vec2 v_Narrowed;\nvarying vec2 v_Widened;\nvarying vec3 v_Synthesized;",
        "  c = vec4(v_Matched + v_Narrowed + v_Widened.zw, v_Synthesized.xy);",
    );
    let p = ok(&vertex, &fragment);
    let (outputs, inputs) = interface_of(&p);
    // Every fragment input has a vertex output with the same name and number ...
    for (name, loc) in &inputs {
        assert!(outputs.iter().any(|(n, l)| n == name && l == loc), "{name} at {loc}: {outputs:?}");
    }
    // ... and the vertex-only output comes after every consumed one.
    let spare = outputs.iter().find(|(n, _)| n == "v_VertexOnly").unwrap().1;
    assert!(inputs.iter().all(|(_, l)| *l < spare), "{inputs:?} {spare}");
    assert_eq!(inputs.len(), 4);
    assert_eq!(outputs.len(), 5);
    // The widened consumer reads vec4 in the interface; the narrowed producer writes vec2.
    agreed(&p, "v_Widened", "vec4", declared_location(&legalized(&p, StageKind::Fragment), "v_Widened").unwrap());
    agreed(&p, "v_Narrowed", "vec2", declared_location(&legalized(&p, StageKind::Fragment), "v_Narrowed").unwrap());
}

/// A deterministic generator of small interface programs: no two varyings of a program may
/// share a location, whatever their kind, order, width or array size.
#[test]
fn no_two_varyings_of_a_generated_program_share_a_location() {
    let mut state: u64 = 0x1234_5678_9abc_def1;
    let mut next = move |n: u64| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state % n
    };
    for round in 0..60 {
        // (name, vertex width, fragment width, array, in vertex, in fragment)
        let count = 3 + next(5) as usize;
        let mut vars = Vec::new();
        for i in 0..count {
            let width = 1 + next(4) as usize;
            let array = if next(4) == 0 { Some(2 + next(3) as usize) } else { None };
            let (in_v, in_f) = match next(4) {
                0 => (true, false),
                1 => (false, true),
                _ => (true, true),
            };
            vars.push((format!("v_{round}_{i}"), width, array, in_v, in_f));
        }
        let ty = |w: usize| ["float", "vec2", "vec3", "vec4"][w - 1];
        let (mut vd, mut vb, mut fd, mut fb) = (String::new(), String::new(), String::new(), String::new());
        let mut order: Vec<usize> = (0..vars.len()).collect();
        for i in (1..order.len()).rev() {
            order.swap(i, next(i as u64 + 1) as usize);
        }
        for &i in &order {
            let (name, w, array, in_v, in_f) = &vars[i];
            let suffix = array.map(|n| format!("[{n}]")).unwrap_or_default();
            let zero = |w: usize| if w == 1 { "0.0".to_string() } else { format!("{}(0.0)", ty(w)) };
            if *in_v {
                vd.push_str(&format!("varying {} {name}{suffix};\n", ty(*w)));
                match array {
                    Some(n) => (0..*n).for_each(|k| vb.push_str(&format!("  {name}[{k}] = {};\n", zero(*w)))),
                    None => vb.push_str(&format!("  {name} = {};\n", zero(*w))),
                }
            }
            if *in_f {
                fd.push_str(&format!("varying {} {name}{suffix};\n", ty(*w)));
                let read = match array {
                    Some(_) => format!("{name}[1]"),
                    None => name.clone(),
                };
                fb.push_str(&format!("  c += vec4({}{});\n", read, if *w == 1 { "" } else { ".x" }));
            }
        }
        let p = Req::new(&vert(&vd, &vb), &frag(&fd, &fb)).ok();
        let (outputs, inputs) = interface_of(&p);
        for (label, list) in [("vertex", &outputs), ("fragment", &inputs)] {
            let numbers: Vec<u32> = list.iter().map(|(_, n)| *n).collect();
            let unique: HashSet<u32> = numbers.iter().copied().collect();
            assert_eq!(numbers.len(), unique.len(), "round {round}: two {label} varyings share a location: {list:?}\n{vd}\n{fd}");
        }
        for (name, loc) in &inputs {
            assert!(outputs.iter().any(|(n, l)| n == name && l == loc), "round {round}: {name} at {loc} has no vertex output");
        }
    }
}
