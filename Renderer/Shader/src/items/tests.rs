// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Behaviour tests for the item scan (spec section 8, items 46 and 47, and the R51 examples).

use super::*;
use crate::lexer::lex;

fn scan(src: &str, mode: BraceMode) -> Vec<Item> {
    let s = lex(src);
    scan_items(&s, src, mode).unwrap_or_else(|e| panic!("{e}: {e:?}"))
}

fn compiled(src: &str) -> Vec<Item> {
    scan(src, BraceMode::Compiled)
}

fn kind_names(items: &[Item]) -> Vec<&'static str> {
    items
        .iter()
        .map(|i| match &i.kind {
            ItemKind::Annotation { .. } => "annotation",
            ItemKind::Directive(_) => "directive",
            ItemKind::Struct { .. } => "struct",
            ItemKind::Function(_) => "function",
            ItemKind::Declaration(_) => "declaration",
            ItemKind::Opaque => "opaque",
        })
        .collect()
}

#[test]
fn items_cover_every_token_exactly_once_in_order() {
    let src = "#define A 1\nuniform float g; // {\"default\":1}\nstruct S { float a; };\n} ; 3 +\nfloat f(float x) { return x; }\nfloat p(float x);\nvoid main() {}";
    let s = lex(src);
    let items = scan_items(&s, src, BraceMode::Compiled).unwrap();
    let mut next = 0;
    for item in &items {
        assert_eq!(item.tokens.start, next, "{item:?}");
        assert!(item.tokens.end > item.tokens.start);
        assert_eq!(item.span, s[item.tokens.start].start..s[item.tokens.end - 1].end);
        next = item.tokens.end;
    }
    assert_eq!(next, s.len());
}

#[test]
fn annotations_and_directives_keep_their_spans_and_typed_forms() {
    let src = "#include \"a/b.h\"\n#define N 4 // c\n#define F(x) (x)\n#define BARE\n#if N >= 2\n#else\n#endif\n#pragma once\n#include <c.h> // x\nuniform float g; // {\"default\":2}\n";
    let items = compiled(src);
    let dirs: Vec<&DirectiveItem> = items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Directive(d) => Some(d),
            _ => None,
        })
        .collect();
    assert_eq!(dirs[0].kind, DirectiveKind::Include { path: "a/b.h".into() });
    assert_eq!(
        dirs[1].kind,
        DirectiveKind::Define { name: "N".into(), function_like: false, replacement: "4".into() }
    );
    assert_eq!(dirs[1].body, "N 4");
    assert_eq!(dirs[1].text, "#define N 4 // c");
    assert_eq!(dirs[2].kind, DirectiveKind::Define { name: "F".into(), function_like: true, replacement: "(x)".into() });
    assert_eq!(dirs[3].kind, DirectiveKind::Define { name: "BARE".into(), function_like: false, replacement: String::new() });
    assert_eq!(dirs[4].kind, DirectiveKind::Conditional(ConditionalKind::If));
    assert_eq!(dirs[5].kind, DirectiveKind::Conditional(ConditionalKind::Else));
    assert_eq!(dirs[6].kind, DirectiveKind::Conditional(ConditionalKind::Endif));
    assert_eq!(dirs[7].kind, DirectiveKind::Other);
    assert_eq!(dirs[8].kind, DirectiveKind::Include { path: "c.h".into() });
    let ann: Vec<&Item> = items.iter().filter(|i| matches!(i.kind, ItemKind::Annotation { .. })).collect();
    assert_eq!(ann.len(), 1);
    assert_eq!(&src[ann[0].span.clone()], "// {\"default\":2}");
    // Directive spans slice the exact directive line.
    let first = items.iter().find(|i| matches!(i.kind, ItemKind::Directive(_))).unwrap();
    assert_eq!(&src[first.span.clone()], "#include \"a/b.h\"");
}

#[test]
fn a_continued_directive_with_crlf_parses_as_one_item() {
    let items = compiled("#define M(a) \\\r\n  (a + 1)\r\nfloat x;\r\n");
    let ItemKind::Directive(d) = &items[0].kind else { panic!() };
    assert!(matches!(&d.kind, DirectiveKind::Define { name, function_like: true, .. } if name == "M"));
    assert_eq!(kind_names(&items), ["directive", "declaration"]);
}

#[test]
fn structs_with_and_without_a_trailing_semicolon() {
    let src = "struct A { float x; };\nstruct B { float y; }\nfloat z;\nstruct C inst;\n";
    let items = compiled(src);
    assert_eq!(kind_names(&items), ["struct", "struct", "declaration", "declaration"]);
    assert_eq!(&src[items[0].span.clone()], "struct A { float x; };");
    assert_eq!(&src[items[1].span.clone()], "struct B { float y; }");
    assert!(matches!(&items[0].kind, ItemKind::Struct { name } if name.as_deref() == Some("A")));
    assert!(matches!(&items[1].kind, ItemKind::Struct { name } if name.as_deref() == Some("B")));
    // `struct Name instance;` is an ordinary declaration.
    assert_eq!(&src[items[3].span.clone()], "struct C inst;");
}

#[test]
fn functions_report_their_facts_and_ignore_comments_between_tokens() {
    let src = "highp vec3 shade /* c */ ( vec3 n, // note\n Ray, float k[LEN] ) /* d */ {\n  return n;\n}\nvoid main() { }";
    let items = compiled(src);
    assert_eq!(kind_names(&items), ["function", "function"]);
    let f = items[0].function().unwrap();
    assert_eq!(f.return_type, "vec3");
    assert_eq!(f.name, "shade");
    assert_eq!(&src[f.name_span.clone()], "shade");
    assert_eq!(f.parameters.len(), 3);
    assert_eq!(f.parameters[1].name, None);
    assert_eq!(f.parameters[2].simple_array_name.as_deref(), Some("k"));
    assert!(f.parameter_text.contains("vec3 n,") && f.parameter_text.contains("float k[LEN]"));
    assert_eq!(&src[f.parameter_span.clone()], f.parameter_text);
    assert!(src[f.signature_span.clone()].starts_with("highp vec3 shade") && src[f.signature_span.clone()].ends_with(')'));
    assert!(src[f.body_span.clone()].starts_with('{') && src[f.body_span.clone()].ends_with('}'));
    assert_eq!(items[0].span.start, f.signature_span.start);
    assert_eq!(items[0].span.end, f.body_span.end);
    let m = items[1].function().unwrap();
    assert_eq!((m.return_type.as_str(), m.name.as_str(), m.parameters.len()), ("void", "main", 0));
}

#[test]
fn a_function_named_mod_is_an_ordinary_function() {
    let items = compiled("float mod(float a, float b) { return a - b * floor(a / b); }");
    assert_eq!(items[0].function().unwrap().name, "mod");
}

#[test]
fn a_prototype_is_a_declaration() {
    let items = compiled("float f(float x);\nfloat f(float x) { return x; }");
    assert_eq!(kind_names(&items), ["declaration", "function"]);
}

#[test]
fn stray_tokens_are_opaque_and_stray_braces_do_not_fail() {
    let items = compiled("} ; 3 + )\nfloat x;\n{\nfloat y;");
    assert_eq!(kind_names(&items), ["opaque", "opaque", "opaque", "opaque", "opaque", "declaration", "opaque", "declaration"]);
}

#[test]
fn unbalanced_function_bodies_and_structs_fail_with_the_opening_token() {
    let src = "float f(float x) { return x;\nvoid main() {}";
    let s = lex(src);
    // Plain counting: the body of `f` swallows `main`'s braces and still lacks one.
    let e = scan_items(&s, src, BraceMode::Compiled).unwrap_err();
    assert_eq!(e.to_string(), "shader parse failed");
    assert_eq!(&src[e.span.clone()], "{");
    assert_eq!(e.span.start, src.find('{').unwrap());
    let d = e.diagnostic(StageKind::Fragment);
    assert_eq!(d.message, "unbalanced shader delimiter");
    assert_eq!(d.pass, Some(Pass::Parse));
    let rendered = e.into_shader_error(StageKind::Fragment, "fx", src).to_string();
    assert!(rendered.contains("unbalanced shader delimiter") && rendered.contains("1:18"), "{rendered}");

    let src = "struct S { float a;\nfloat b;";
    let s = lex(src);
    let e = scan_items(&s, src, BraceMode::Compiled).unwrap_err();
    assert_eq!(&src[e.span.clone()], "{");

    let src = "float f(float x { return x; }";
    let s = lex(src);
    let e = scan_items(&s, src, BraceMode::Compiled).unwrap_err();
    assert_eq!(&src[e.span.clone()], "(");
}

#[test]
fn an_unbalanced_stray_delimiter_outside_functions_does_not_fail() {
    assert!(scan_items(&lex("float x; }"), "float x; }", BraceMode::Compiled).is_ok());
    assert!(scan_items(&lex("float x = (1;\nfloat y;"), "float x = (1;\nfloat y;", BraceMode::Compiled).is_ok());
    assert!(scan_items(&lex("a ) b ] c"), "a ) b ] c", BraceMode::Compiled).is_ok());
}

fn decl(src: &str) -> DeclarationItem {
    let items = compiled(src);
    assert_eq!(items.len(), 1, "{src}: {items:?}");
    items[0].declaration().unwrap_or_else(|| panic!("{src}: {:?}", items[0])).clone()
}

#[test]
fn qualified_declarations_report_qualifier_type_name_layout_and_array_facts() {
    let d = decl("layout(row_major) layout(set = 3, binding = 7) uniform float gains[12];");
    assert_eq!(d.qualifier, Some(Qualifier::Uniform));
    assert_eq!((d.set, d.binding), (Some(3), Some(7)));
    assert_eq!(d.name.as_deref(), Some("gains"));
    assert_eq!(d.type_text.as_deref(), Some("float"));
    let a = d.array.unwrap();
    assert_eq!((a.text.as_str(), a.size, a.macro_name), ("[12]", Some(12), None));

    let d = decl("uniform vec2 offs[SAMPLES];");
    let a = d.array.unwrap();
    assert_eq!((a.size, a.macro_name.as_deref()), (None, Some("SAMPLES")));

    let d = decl("layout(binding = 4) uniform mediump sampler2D g_Mask;");
    assert_eq!(
        (d.qualifier, d.type_text.as_deref(), d.name.as_deref(), d.set, d.binding),
        (Some(Qualifier::Uniform), Some("sampler2D"), Some("g_Mask"), None, Some(4))
    );
    assert!(d.array.is_none());

    let d = decl("uniform float g_Taps[8];");
    assert_eq!(d.array.unwrap().size, Some(8));

    let d = decl("layout(location = 3) varying highp vec2 v_Uv;");
    assert_eq!(
        (d.qualifier, d.type_text.as_deref(), d.name.as_deref()),
        (Some(Qualifier::Varying), Some("vec2"), Some("v_Uv"))
    );
}

#[test]
fn array_sizes_that_are_not_one_literal_or_one_identifier_are_not_reported() {
    for (src, text) in [("uniform float a[N + 1];", "[N + 1]"), ("uniform float a[2u];", "[2u]"), ("uniform float a[];", "[]"), ("uniform float a[1.5];", "[1.5]")] {
        let a = decl(src).array.unwrap();
        assert_eq!(a.text, text);
        assert_eq!((a.size, a.macro_name), (None, None), "{src}");
    }
}

#[test]
fn the_first_name_of_a_list_is_reported_and_a_set_without_binding_falls_back_to_the_last_group() {
    let d = decl("uniform vec4 a, b;");
    assert_eq!(d.name.as_deref(), Some("a"));
    let d = decl("layout(set = 1) layout(set = 2) uniform float x;");
    assert_eq!((d.set, d.binding), (Some(2), None));
    let d = decl("layout(binding = 1) layout(binding = 2) uniform float x;");
    assert_eq!(d.binding, Some(1));
}

#[test]
fn unqualified_and_const_declarations_are_other() {
    for src in ["const float k = 1.0;", "float g;", "highp float h;", "precision highp float;", "vec3 v = vec3(1.0);"] {
        let d = decl(src);
        assert_eq!(d.qualifier, None, "{src}");
        assert_eq!(d.name, None, "{src}");
    }
    let d = decl("attribute vec3 a_Position;");
    assert_eq!(d.qualifier, Some(Qualifier::Attribute));
    let d = decl("in vec3 a;");
    assert_eq!(d.qualifier, Some(Qualifier::In));
    let d = decl("flat out vec3 a;");
    assert_eq!((d.qualifier, d.name.as_deref()), (Some(Qualifier::Out), Some("a")));
}

#[test]
fn a_construct_reaching_a_brace_becomes_a_one_token_declaration_and_scanning_continues() {
    let items = compiled("FOO(x)\nvoid main() { }");
    assert!(items.iter().any(|i| i.function().is_some_and(|f| f.name == "main")), "{:?}", kind_names(&items));
}

const PER_ARM: &str = "struct Lamp {
#ifdef HDR
    vec4 tint;
#else
    vec3 tint;
#endif
    float reach;
};
uniform float g_Pre; // {\"default\":1}
#ifdef HDR
vec3 grade(Lamp l) {
#else
vec3 grade(Lamp l, float ev) {
#endif
#ifdef HDR
#ifdef FAST
    return l.tint.rgb;
#else
    return l.tint.rgb * l.reach;
#endif
#else
    return l.tint * ev;
#endif
}
uniform float g_Post; // {\"default\":2}
void main() { }
";

#[test]
fn per_arm_headers_and_nested_conditionals_find_the_body_end_in_the_conditional_view() {
    let items = scan(PER_ARM, BraceMode::Conditional);
    let names: Vec<(String, &'static str)> = items
        .iter()
        .filter(|i| matches!(i.kind, ItemKind::Function(_) | ItemKind::Struct { .. }) || i.is_declaration())
        .map(|i| match &i.kind {
            ItemKind::Function(f) => (f.name.clone(), "function"),
            ItemKind::Struct { name } => (name.clone().unwrap(), "struct"),
            ItemKind::Declaration(d) => (d.name.clone().unwrap_or_default(), "declaration"),
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(
        names,
        [
            ("Lamp".to_string(), "struct"),
            ("g_Pre".to_string(), "declaration"),
            ("grade".to_string(), "function"),
            ("g_Post".to_string(), "declaration"),
            ("main".to_string(), "function"),
        ]
    );
    let grade = items.iter().find(|i| i.function().is_some_and(|f| f.name == "grade")).unwrap();
    // From the first header through the final `}`.
    assert!(PER_ARM[grade.span.clone()].starts_with("vec3 grade(Lamp l) {"));
    assert!(PER_ARM[grade.span.clone()].ends_with("return l.tint * ev;\n#endif\n}"));
    let lamp = items.iter().find(|i| matches!(i.kind, ItemKind::Struct { .. })).unwrap();
    assert!(PER_ARM[lamp.span.clone()].ends_with("};"));
    // Uniforms before and after the per-arm header function are scanned normally.
    assert!(items.iter().any(|i| i.declaration().is_some_and(|d| d.name.as_deref() == Some("g_Post"))));
}

#[test]
fn the_same_text_fails_under_plain_brace_counting() {
    let s = lex(PER_ARM);
    let e = scan_items(&s, PER_ARM, BraceMode::Compiled).unwrap_err();
    assert_eq!(&PER_ARM[e.span.clone()], "{");
    assert!(PER_ARM[..e.span.start].ends_with("vec3 grade(Lamp l) "));
}

#[test]
fn a_conditional_that_wraps_only_a_loop_header_is_accepted() {
    let src = "float tally(float n) {
    float t = 0.0;
#ifdef DENSE
    for (int i = 0; i < 8; ++i) {
#else
    while (t < n) {
#endif
        t += 1.0;
    }
    return t;
}
uniform float g_After;
";
    let items = scan(src, BraceMode::Conditional);
    let f = items[0].function().unwrap();
    assert_eq!(f.name, "tally");
    assert!(src[f.body_span.clone()].ends_with("return t;\n}"));
    assert!(items.iter().any(|i| i.declaration().is_some_and(|d| d.name.as_deref() == Some("g_After"))));
    let s = lex(src);
    assert!(scan_items(&s, src, BraceMode::Compiled).is_err());
}

#[test]
fn balanced_arms_at_any_depth_and_unmatched_bodies_in_the_conditional_view() {
    let src = "void f() {
#if A
#if B
  if (x) { y(); }
#else
  { z(); }
#endif
#else
  while (q) { w(); }
#endif
}
float after;
";
    let items = scan(src, BraceMode::Conditional);
    assert_eq!(kind_names(&items), ["function", "declaration"]);
    // Compiled-form counting agrees here: the arms are balanced.
    assert_eq!(kind_names(&compiled(src)), ["function", "declaration"]);
    // A body that never closes still fails.
    let bad = "void f() {\n#if A\n  x();\n#endif\n";
    let s = lex(bad);
    assert!(scan_items(&s, bad, BraceMode::Conditional).is_err());
}

#[test]
fn a_directive_does_not_swallow_the_declaration_that_follows_it() {
    let src = "#if X\nuniform float a;\n#endif\nuniform float b; // {\"default\":1}\n";
    let items = scan(src, BraceMode::Conditional);
    assert_eq!(kind_names(&items), ["directive", "declaration", "directive", "declaration", "annotation"]);
}

// ---- amendment b R81: a member-access suffix after the declared name ----

#[test]
fn a_member_access_suffix_after_the_declared_name_stays_inside_one_declaration() {
    for text in ["varying vec4 v_Haze.xy;", "varying vec4 v_Haze . xyz ;", "varying vec4 v_Haze /* c */ . rg ;", "varying vec4 v_Haze\n  .\n  xy;"] {
        let src = format!("{text}\nuniform float g_After;\nvoid main() {{}}\n");
        let items = compiled(&src);
        assert_eq!(kind_names(&items), ["declaration", "declaration", "function"], "{text}");
        let d = items[0].declaration().unwrap();
        assert_eq!((d.qualifier, d.type_text.as_deref(), d.name.as_deref()), (Some(Qualifier::Varying), Some("vec4"), Some("v_Haze")), "{text}");
        assert!(d.array.is_none(), "{text}");
        // The declarations after it are found as before.
        assert_eq!(items[1].declaration().unwrap().name.as_deref(), Some("g_After"), "{text}");
        assert_eq!(items[2].function().unwrap().name, "main", "{text}");
        assert_eq!(items[0].span, 0..text.len(), "{text}");
    }
}

#[test]
fn the_conditional_view_scans_a_suffixed_declaration_the_same_way() {
    let src = "#if A\nvarying vec4 v_Haze.xy;\n#else\nvarying vec4 v_Haze;\n#endif\nuniform float g_After;\nvoid main() {}\n";
    let items = scan(src, BraceMode::Conditional);
    let names: Vec<Option<&str>> = items.iter().filter_map(Item::declaration).map(|d| d.name.as_deref()).collect();
    assert_eq!(names, [Some("v_Haze"), Some("v_Haze"), Some("g_After")]);
}
