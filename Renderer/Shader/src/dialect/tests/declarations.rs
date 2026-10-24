// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.6: declarations, scopes, names and constants (R69 to R82).

use super::support::*;
use crate::request::StageKind;

#[test]
fn a_local_hides_a_global_declared_earlier_even_after_the_global_was_read() {
    let src = "varying vec4 v_Tint;
void main() {
  float m = v_Tint.a * 2.0;
  vec3 v_Tint = vec3(0.5);
  vec3 t = v_Tint * m;
  gl_FragColor = vec4(t, 1.0);
}";
    let c = legacy_frag(src);
    assert_eq!(c.local_type("v_Tint"), "vec3<f32>");
    assert_eq!(c.local_type("t"), "vec3<f32>");
    // the later rules use the local's type: assigning the local to a vec3 needs no conversion
    let t = frag(src);
    assert!(t.contains("vec3 t = v_Tint * m;"), "{t}");
}

#[test]
fn an_inner_declaration_hides_the_outer_one_for_every_rule() {
    // `ivec3`, `uvec3`, `bvec3`, `mat2`, `mat3`, `mat4` and a struct hide an outer `vec3 origin`
    for ty in ["ivec3", "uvec3", "bvec3", "mat2", "mat3", "mat4"] {
        let src = format!("varying vec3 origin;\nvoid main() {{ {ty} origin; float f = 1.0; vec3 x = f; gl_FragColor = vec4(x, 1.0); }}");
        let t = frag(&src);
        assert!(t.contains("vec3 x = vec3(f);"), "{ty}: {t}");
        let src = format!("varying vec3 origin;\nvoid main() {{ {ty} origin; vec3 r = origin + vec2(1.0, 2.0); }}");
        let t = frag(&src);
        assert!(!t.contains("vec3(vec2(1.0, 2.0), 0.0)"), "{ty}: a hiding declaration blocks the one widening: {t}");
    }
    let src = "struct S { float v; };\nvarying vec3 origin;\nvoid main() { S origin; origin.v = 1.0; vec3 x = origin.v; gl_FragColor = vec4(x, 1.0); }";
    let c = legacy_frag(src);
    assert_eq!(c.local_type("x"), "vec3<f32>");
    // a parameter hides a global for the body only
    let src = "varying vec3 origin;\nfloat use(float origin) { vec3 x = origin; return x.y; }\nvoid main() { vec3 y = origin; gl_FragColor = vec4(y, use(1.0)); }";
    let t = frag(src);
    assert!(t.contains("vec3 x = vec3(origin);") && t.contains("vec3 y = origin;"), "{t}");
}

#[test]
fn a_for_declaration_is_visible_through_the_loop_and_its_branches_and_nowhere_after() {
    let src = "varying vec3 k;
void main() {
  float acc = 0.0;
  for (float k = 1.0; k < 3.0; k += 1.0) if (acc > 5.0) acc += k; else { vec3 q = k; acc += q.x; }
  vec3 after = k;
  gl_FragColor = vec4(after, acc);
}";
    let t = frag(src);
    assert!(t.contains("vec3 q = vec3(k);"), "the loop's own k is a scalar: {t}");
    assert!(t.contains("vec3 after = k;"), "after the loop `k` is the varying again: {t}");
    legacy_frag(src);
}

#[test]
fn reserved_words_are_legal_identifiers_after_conversion() {
    let src = "void f(float sample) { float x = sample * 2.0; gl_FragColor = vec4(x); }
struct Info { float sample; float input; };
void main() {
  float and = 1.0; bool or = and > 0.5; bool xor = !or; float not = 2.0;
  float filter = 3.0, input = 4.0, common = 5.0, partition = 6.0, active = 7.0;
  Info info; info.sample = 1.0; info.input = 2.0;
  float sample = info.sample + info.input;
  vec4 c = vec4(sample + and + not + filter + input + common + partition + active, float(or) + float(xor), 0.0, 1.0);
  f(sample);
  gl_FragColor = c;
}";
    let t = frag(src);
    for w in ["and", "or", "xor", "not", "sample", "filter", "input", "common", "partition", "active"] {
        assert!(!has_word(&t, w), "{w} survived: {t}");
    }
    legacy_frag(src);
}

#[test]
fn a_reserved_word_is_renamed_consistently_across_declaration_and_use() {
    let t = frag("void main() { float sample = 1.0; sample += 2.0; gl_FragColor = vec4(sample); }");
    assert!(t.contains("sample_wm") && !t.contains(" sample "), "{t}");
    assert_eq!(count(&t, "sample_wm"), 3, "{t}");
}

#[test]
fn sample_is_a_qualifier_in_front_of_a_type_and_an_identifier_elsewhere() {
    let t = frag("sample in vec4 x;\nvoid main() { float sample = 1.0; gl_FragColor = vec4(sample) + x; }");
    assert!(t.contains("sample in vec4 x;"), "{t}");
    assert!(t.contains("float sample_wm = 1.0;"), "{t}");
}

#[test]
fn a_user_float_mod_is_called_for_scalars_and_the_builtin_for_vectors() {
    let decls = "float mod(float x, float y) { return x - y * floor(x / y) + 0.0; }";
    let t = text(
        decls,
        "float a = uf; vec3 v = u3; int i = ui;
float r1 = mod(a, 2.0);
float r2 = mod(float(i), 3.0);
float r3 = mod(-a, (a + 1.0));
float r4 = mod(a * 2.0, +4.0);
float r5 = mod(v.x, a);
vec3 r6 = mod(v, 2.0);
vec2 r7 = mod(i2, vec2(2.0));
o = vec4(r1 + r2 + r3 + r4 + r5 + r6.x + r7.x);",
    );
    assert_eq!(count(&t, "mod(a, 2.0)"), 1, "{t}");
    assert!(t.contains("mod(v, 2.0)") && t.contains("mod(i2, vec2(2.0))"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn the_builtin_two_argument_mod_stays_reachable() {
    let c = ok("", "vec3 r = mod(u3, 2.0); float k = mod(uf, 3.0); o = vec4(r, k);");
    assert_eq!(c.local_type("r"), "vec3<f32>");
}

// ----- global initializers (R72, R73) -----

#[test]
fn a_global_initialised_from_a_uniform_is_evaluated_at_the_start_of_main() {
    let t = text("const float GAIN = uf * uf - 1.0;\nfloat shade = u4.x * 2.0;\nfloat later = shade + 1.0;", "o = vec4(GAIN + shade + later);");
    assert!(t.contains("float GAIN;") && !t.contains("const float GAIN"), "{t}");
    let main = &t[t.find("void main()").unwrap()..];
    let g = main.find("GAIN = uf * uf - 1.0;").unwrap();
    let s = main.find("shade = u4.x * 2.0;").unwrap();
    let l = main.find("later = shade + 1.0;").unwrap();
    assert!(g < s && s < l, "declaration order: {main}");
    assert!(main.find("o = ").unwrap() > l, "{main}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_constant_global_stays_a_constant_and_works_as_an_array_size() {
    let t = text("const uint N = 8u >> 1u;\nconst float RATIO = 3.0 / 8.0;\nconst vec2 K = vec2(RATIO, 1.0);\nfloat w[N];", "w[0] = RATIO; o = vec4(w[0] + K.x);");
    assert!(t.contains("const uint N = 8u >> 1u;") && t.contains("const float RATIO = 3.0 / 8.0;") && t.contains("const vec2 K = vec2(RATIO, 1.0);"), "{t}");
    let main = &t[t.find("void main()").unwrap()..];
    assert!(!main.contains("N =") && !main.contains("RATIO =") && !main.contains("K ="), "nothing moves into main: {t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_global_declaration_list_moves_only_the_declarators_that_need_it() {
    let t = text("const float A = 2.0, B = uf * 2.0, C = 3.0;", "o = vec4(A + B + C);");
    assert!(t.contains("const float A = 2.0;") && t.contains("const float C = 3.0;") && t.contains("float B;"), "{t}");
    assert!(t.contains("B = uf * 2.0;"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_mutable_global_with_a_constant_initializer_keeps_it() {
    let t = text("float g = 4.0;", "g += 1.0; o = vec4(g);");
    assert!(t.contains("float g = 4.0;"), "{t}");
}

#[test]
fn a_precision_qualifier_is_kept_on_a_moved_global() {
    let t = text("const highp float GAIN = uf * 2.0;", "o = vec4(GAIN);");
    assert!(t.contains("highp float GAIN;"), "{t}");
}

#[test]
fn a_local_const_is_left_as_written() {
    let t = text("", "const float k = uf * 2.0; o = vec4(k);");
    assert!(t.contains("const float k = uf * 2.0;"), "{t}");
}

// ----- stage inputs are assignable (R75) -----

#[test]
fn a_vertex_shader_may_assign_to_its_inputs() {
    let src = "attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_Tex; uniform float g_Stretch;
void main() {
  a_TexCoord *= g_Stretch;
  a_Position.x += 1.0;
  v_Tex = a_TexCoord;
  gl_Position = vec4(a_Position, 1.0);
}";
    let t = legacy_text(StageKind::Vertex, src);
    assert!(t.contains("_we_in_a_TexCoord") && t.contains("_we_in_a_Position"), "{t}");
    assert!(t.contains("a_TexCoord = _we_in_a_TexCoord;"), "{t}");
    legacy_vert(src);
}

#[test]
fn a_fragment_shader_may_assign_to_a_varying_input_and_pass_it_as_an_out_argument() {
    let src = "varying vec2 v_TexCoord; uniform float g_Time;
void bump(inout vec2 p) { p += 0.5; }
void main() {
  v_TexCoord.x += g_Time;
  bump(v_TexCoord);
  gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
}";
    let t = legacy_text(StageKind::Fragment, src);
    assert!(t.contains("_we_in_v_TexCoord"), "{t}");
    legacy_frag(src);
}

#[test]
fn a_read_only_input_gets_no_copy() {
    let t = legacy_text(StageKind::Vertex, "attribute vec3 a_Position; void main() { vec3 p = a_Position * 2.0; gl_Position = vec4(p, 1.0); }");
    assert!(!t.contains("_we_in_"), "{t}");
    let t = legacy_text(StageKind::Fragment, "varying vec2 v_T; void main() { gl_FragColor = vec4(v_T, 0.0, 1.0); }");
    assert!(!t.contains("_we_in_"), "{t}");
}

#[test]
fn a_shadowing_local_that_is_written_does_not_copy_the_input() {
    let t = legacy_text(StageKind::Vertex, "attribute vec2 a_Tex; void main() { { vec2 a_Tex = vec2(1.0); a_Tex += 1.0; } gl_Position = vec4(a_Tex, 0.0, 1.0); }");
    assert!(!t.contains("_we_in_"), "{t}");
}

// ----- brace lists and array copies (R78, R79) -----

#[test]
fn brace_list_array_initializers_compile_with_and_without_const() {
    let c = ok("const float R[3] = {0.1, 0.5, 0.9};\nfloat S[3] = {0.2, 0.4, 0.6};\nconst vec2 K[2] = {vec2(1.0), vec2(2.0, 3.0)};", "o = vec4(R[1] + S[2] + K[1].y);");
    let _ = c;
    let t = text("const float R[3] = {0.1, 0.5, 0.9};", "o = vec4(R[1]);");
    assert!(t.contains("{0.1, 0.5, 0.9}"), "the author's text is kept: {t}");
    ok("const float R[3] = float[3](0.1, 0.5, 0.9);", "o = vec4(R[2]);");
    // integer elements of a float array become floats
    let t = text("const float R[3] = {1, 2, 3};", "o = vec4(R[1]);");
    assert!(t.contains("{1.0, 2.0, 3.0}"), "{t}");
}

#[test]
fn a_whole_array_copy_and_a_float_indexed_read() {
    let c = ok(
        "const float SRC[4] = float[4](0.1, 0.2, 0.3, 0.4);\n#define N 4\n",
        "float bins[N] = SRC; float t = uf * 3.0; float v = bins[t]; o = vec4(v);",
    );
    let _ = c;
}

// ----- structs and comma declarators (R76, R80) -----

#[test]
fn struct_locals_parameters_and_returns_pass_through_and_members_keep_their_names() {
    let decls = "struct Light { vec3 color; float power; };\nLight make(vec3 c, float p) { Light l; l.color = c; l.power = p; return l; }\nvec3 shade(Light l) { return l.color * l.power; }";
    let c = ok(decls, "Light a = make(u3, uf); vec3 s = shade(a); o = vec4(s, a.power);");
    assert_eq!(c.local_type("s"), "vec3<f32>");
    let t = text(decls, "Light a = make(u3, uf); o = vec4(shade(a), a.power);");
    assert!(t.contains("l.color = c;") && t.contains("a.power"), "{t}");
}

#[test]
fn comma_declarators_are_typed_and_rewritten_independently() {
    let t = text(
        "",
        "float f = uf; bool k = uf > 1.0;
vec2 sz = vec2(8.0), off[2];
int cell = floor(f * 4.0), side = 7;
bool lit = f > 0.2, dim = f < 0.1;
float hue = f % 360.0, gain = 2.5;
vec3 tint = vec3(1.0), shade[3], bias = tint * 0.5;
float w = k, z = f;
o = vec4(sz, float(cell + side), float(lit) + float(dim) + hue + gain + bias.x + w + z);",
    );
    assert!(t.contains("int cell = int(floor(f * 4.0)), side = 7;"), "{t}");
    assert!(t.contains("float hue = f % 360.0, gain = 2.5;"), "{t}");
    // naga gives the declarators after an array declarator the array type, so such a list is split
    assert!(t.contains("vec3 tint = vec3(1.0);") && t.contains("vec3 shade[3];") && t.contains("vec3 bias = tint * 0.5;"), "{t}");
    assert!(t.contains("float w = float(k), z = f;"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

// ---- amendment c1 R107: a member-access suffix after a declared interface name ----

#[test]
fn a_member_access_suffix_after_an_interface_name_is_dropped_and_changes_nothing() {
    let body = "void main() { gl_FragColor = vec4(v_Haze.xy, 0.0, 1.0); }";
    let plain = frag(&format!("varying vec4 v_Haze;\n{body}"));
    for written in [
        "varying vec4 v_Haze.xy;",
        "varying vec4 v_Haze . xyz ;",
        "varying vec4 v_Haze /* note */ .xy;",
        "varying vec4 v_Haze // note\n  .rgba;",
        "varying vec4 v_Haze.stpq;",
        "varying vec4 v_Haze.xg;",
    ] {
        assert_eq!(frag(&format!("{written}\n{body}")), plain, "{written}");
    }
    // The type and the width are the ones written before the name; the suffix does not narrow them.
    assert!(plain.contains("varying vec4 v_Haze;"), "{plain}");
    // The same leniency for every interface qualifier (one code path).
    assert_eq!(frag("in vec4 v_Haze.xy;\nvoid main() { gl_FragColor = v_Haze; }"), frag("in vec4 v_Haze;\nvoid main() { gl_FragColor = v_Haze; }"));
    assert_eq!(
        vert("attribute vec3 a_Position.xyz;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }"),
        vert("attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }")
    );
    assert_eq!(
        frag("uniform float g_Gain.x;\nvoid main() { gl_FragColor = vec4(g_Gain); }"),
        frag("uniform float g_Gain;\nvoid main() { gl_FragColor = vec4(g_Gain); }")
    );
}

#[test]
fn a_suffixed_declarator_in_a_list_is_accepted_and_does_not_disturb_the_next_declaration() {
    let t = frag("varying vec4 a.xy, b;\nvarying float c;\nvoid main() { gl_FragColor = a + b + vec4(c); }");
    assert_eq!(t, frag("varying vec4 a, b;\nvarying float c;\nvoid main() { gl_FragColor = a + b + vec4(c); }"));
    assert!(t.contains("varying float c;"), "{t}");
}

#[test]
fn a_member_access_suffix_is_not_a_use_of_the_variable() {
    use crate::dialect::{parse_stage, usage::use_facts};
    let (module, _) = parse_stage(StageKind::Fragment, "varying vec4 v_Haze.xyz;\nvoid main() { gl_FragColor = vec4(v_Haze.x, 0.0, 0.0, 1.0); }").unwrap();
    let facts = use_facts(&module, "v_Haze");
    assert_eq!((facts.max_component, facts.read_whole, facts.assigned_whole), (1, false, false));
}

#[test]
fn a_malformed_suffix_is_a_failure_at_that_declaration() {
    for (text, declaration) in [
        ("varying vec4 v_Haze.;", "varying vec4 v_Haze.;"),
        ("varying vec4 v_Haze.xy = 1.0;", "varying vec4 v_Haze.xy = 1.0;"),
        ("varying vec4 v_Haze.xy[2];", "varying vec4 v_Haze.xy[2];"),
        ("varying vec4 v_Haze.12;", "varying vec4 v_Haze.12;"),
        ("varying vec4 v_Haze.foo;", "varying vec4 v_Haze.foo;"),
        ("varying vec4 v_Haze.xy.zw;", "varying vec4 v_Haze.xy.zw;"),
    ] {
        let src = format!("uniform float g_Before;\n{text}\nvarying float v_After;\nvoid main() {{ gl_FragColor = vec4(0.0); }}\n");
        let failure = match crate::dialect::convert_stage(StageKind::Fragment, &src) {
            Ok(c) => panic!("{text} converted: {}", c.text),
            Err(d) => d,
        };
        let span = failure[0].span.unwrap_or_else(|| panic!("{text}: no span"));
        let at = src.find(declaration).unwrap();
        assert_eq!((span.start(), span.end()), (at, at + declaration.len()), "{text}: {failure:?}");
    }
}
