// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.1: source acceptance and structure (R1 to R7).

use super::support::*;
use crate::dialect::ast::{Item, Qualifier};
use crate::dialect::parse_stage;
use crate::request::StageKind;

fn items(src: &str) -> Vec<Item> {
    parse_stage(StageKind::Fragment, src).unwrap().0.items
}

#[test]
fn every_interface_qualifier_modifier_and_layout_order_parses() {
    let src = "
precision mediump float;
attribute vec3 a_Position;
varying lowp vec2 v_A;
uniform mediump float g_X;
flat in int k_a;
smooth in vec2 s_a;
noperspective in vec2 n_a;
centroid in vec2 c_a;
layout(location = 5) highp in vec4 l_a;
highp layout(location = 6) in vec4 l_b;
invariant out vec4 inv_o;
const float K = 1.0;
sample in vec4 smp;
void main() {}
";
    let it = items(src);
    assert_eq!(it.iter().filter(|i| matches!(i, Item::Var(_))).count(), 12);
    let Item::Var(k) = &it[12] else { panic!("{:?}", it[12]) };
    assert!(k.has_word("sample") && k.has_word("in"));
    let Item::Var(c) = &it[11] else { panic!() };
    assert!(c.has_word("const"));
    // The converted stage keeps `const`, precision and layout qualifiers and a `precision` statement.
    let out = frag("precision mediump float;\nconst float K = 1.0;\nlayout(location = 0) out lowp vec4 o;\nvoid main() { o = vec4(K); }");
    assert!(out.contains("const float K = 1.0;"), "{out}");
    assert!(out.contains("precision mediump float;"), "{out}");
    assert!(out.contains("layout(location = 0) out lowp vec4 o;"), "{out}");
}

#[test]
fn a_stage_without_legacy_qualifiers_is_accepted_and_compiles() {
    ok("", "o = i4 + vec4(u3, uf);");
}

#[test]
fn functions_are_recognised_with_comments_prototypes_and_parameter_forms() {
    let src = "
vec2 /* b */ warp(vec2 q) { return q; }
float tap(float v[8]);
float inout_it(inout float a, const in float, out float z);
float nothing(void);
float nothing(void) { return 1.0; }
void main() {}
";
    let it = items(src);
    let fns: Vec<_> = it.iter().filter_map(|i| if let Item::Function(f) = i { Some(f) } else { None }).collect();
    assert_eq!(fns.len(), 6);
    assert_eq!(fns[0].name, "warp");
    assert!(fns[0].body.is_some());
    assert!(fns[1].body.is_none() && !fns[1].params[0].dims.is_empty());
    assert_eq!(fns[2].params.len(), 3);
    assert_eq!(fns[2].params[1].name, None);
    assert!(fns[3].params.is_empty() && fns[3].body.is_none());
    assert!(fns[4].body.is_some());
}

#[test]
fn struct_declarations_with_and_without_the_final_semicolon() {
    let src = "struct A { vec2 v; float w; };\nstruct B { vec2 v; }\nvoid main() {}";
    let it = items(src);
    assert!(matches!(it[0], Item::Struct(_)) && matches!(it[1], Item::Struct(_)) && matches!(it[2], Item::Function(_)));
    let out = frag("struct A { vec2 v; float w; };\nstruct B { vec2 v; }\nlayout(location = 0) out vec4 o;\nvoid main() { A a; a.v = vec2(1.0); B b; b.v = a.v; o = vec4(b.v, 0.0, 1.0); }");
    compile_glsl(StageKind::Fragment, &out).unwrap();
}

#[test]
fn interface_declaration_facts_are_available_on_the_tree() {
    let src = "
layout(set = 1, binding = 4) uniform sampler2D g_Texture0;
uniform vec4 g_Colors[4];
varying vec2 v_A;
void main() {}
";
    let it = items(src);
    let Item::Var(s) = &it[0] else { panic!() };
    assert_eq!(s.ty.name, "sampler2D");
    assert!(matches!(&s.quals[0], Qualifier::Layout(t) if t == "set = 1, binding = 4"));
    let Item::Var(c) = &it[1] else { panic!() };
    assert_eq!(c.declarators[0].dims.len(), 1);
}

#[test]
fn annotations_strings_and_comments_are_not_code() {
    let src = "
uniform float g_Time; // {\"material\":\"float2 mul(\"}
// [COMBO] {\"material\":\"x % y\",\"combo\":\"A\"}
/* float2 inside a comment, mul(a, b), saturate(x) */
varying vec2 v_A;
void main() {
  // float2 q = mul(a, b);
  vec2 q = v_A; /* lerp(x, y, z) */
  gl_FragColor = vec4(q, 0.0, 1.0);
}
";
    let out = frag(src);
    assert!(out.contains("// {\"material\":\"float2 mul(\"}"), "{out}");
    assert!(out.contains("// [COMBO] {\"material\":\"x % y\",\"combo\":\"A\"}"), "{out}");
    assert!(!out.contains("mul(a"), "comments are dropped: {out}");
    assert!(!out.contains("lerp"), "{out}");
}

#[test]
fn a_continued_define_is_one_item_and_its_text_is_converted() {
    let out = frag("#define TINT(c) \\\n  saturate(c) * \\\n  0.5\nvarying float v_A;\nvoid main() { gl_FragColor = vec4(TINT(v_A)); }");
    assert!(out.contains("clamp(v_A, 0.0, 1.0) * 0.5"), "{out}");
}

#[test]
fn unbalanced_braces_fail_at_the_opening_brace_and_a_stray_character_does_not() {
    let src = "void main() {\n  if (a) {\n    b = 1;\n}";
    let err = parse_stage(StageKind::Fragment, src).unwrap_err();
    let span = err[0].span.unwrap();
    assert_eq!(&src[span.start()..span.end()], "{");
    assert!(src[..span.start()].ends_with("main() "));
    // a stray `@` is carried through
    let out = convert_stage_text("void main() { float a = 1.0; @ float b = 2.0; }");
    assert!(out.contains('@'), "{out}");
}

fn convert_stage_text(src: &str) -> String {
    frag(src)
}

#[test]
fn number_lexing_survives_rewrites_digit_for_digit() {
    let out = frag("void main() { float a = .5; float b = 5.; float c = 1e-3; uint d = 2u; float e = 0.5f; float f = 1.17549435e-38; vec3 g = vec3(a * 2.5); }");
    for lit in [".5", "5.", "1e-3", "2u", "0.5f", "1.17549435e-38"] {
        assert!(out.contains(lit), "{lit}: {out}");
    }
}
