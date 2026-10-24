// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Section 8.4: operators and conditions (R46 to R57).

use super::support::*;
use crate::request::StageKind;

#[test]
fn integer_remainders_are_left_exactly_as_written() {
    let t = text(
        "",
        "uint u = uu; int r = ui; int c = 5;
uint a = u % 24u;
uint b = (u + 3u) % 24u;
int d = r % c;
uint e = uint(r % c);
float f = float(r % c);
uint g = uuv4.x % uint(uf);
o = vec4(float(a + b + e + g) + float(d) + f);",
    );
    for form in ["u % 24u", "(u + 3u) % 24u", "r % c", "uint(r % c)", "float(r % c)"] {
        assert!(t.contains(form), "{form}: {t}");
    }
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn float_remainders_are_truncated_per_component_with_both_sides_floats() {
    let c = ok(
        "",
        "float a = i1; float b = uf; float p = 5.0, q = 6.0, r = 7.0; vec2 v2 = u2; float s = 3.0; vec2 w = u2; float h = 2.0;
float r1 = a % b;
float r2 = 7.25 % 2.0;
float r3 = a % 6;
vec2 r4 = v2 % s;
float r5 = a % -h;
float r6 = (p % q) % r;
float r7 = p + q % r;
float r8 = p * q % r;
float r9 = p % q - r;
float r10 = w.x % s;
float r11 = float(ui) % uf;
o = vec4(r1 + r2 + r3 + r4.x + r5 + r6 + r7 + r8 + r9 + r10 + r11);",
    );
    for v in ["r1", "r2", "r3", "r5", "r6", "r7", "r8", "r9", "r10", "r11"] {
        assert_eq!(c.local_type(v), "f32", "{v}");
    }
    assert_eq!(c.local_type("r4"), "vec2<f32>");
    assert!(c.msl.contains("fmod"), "{}", c.msl);
}

#[test]
fn remainder_precedence_associativity_and_signed_operands() {
    let t = text("", "float p = uf, q = ug, r = i1; float a = p + q % r; float b = p * q % r; float c = p % q % r; float d = p % q - r; float e = p % -q; o = vec4(a + b + c + d + e);");
    assert!(t.contains("p + q % r"), "{t}");
    assert!(t.contains("p * q % r"), "{t}");
    assert!(t.contains("p % q % r"), "{t}");
    assert!(t.contains("p % q - r"), "{t}");
    assert!(t.contains("p % -q"), "{t}");
}

#[test]
fn remainder_with_mixed_operands_converts_the_integer_side() {
    let t = text("", "float a = uf; int i = ui; float b = a % 4; float c = i % a; vec2 d = u2 % 2.0; uint n = uint(a % 64); uint k = a % 48; o = vec4(b + c + d.x + float(n + k));");
    assert!(t.contains("a % 4.0"), "{t}");
    assert!(t.contains("float(i) % a"), "{t}");
    assert!(t.contains("u2 % vec2(2.0)"), "{t}");
    assert!(t.contains("uint(a % 64.0)"), "{t}");
    assert!(t.contains("uint k = uint(a % 48.0)"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn remainder_assignment_is_per_kind() {
    let c = ok("", "float acc = uf; float n = i1; acc %= n; vec3 w = u3; w.y %= n; w %= 2.0; int k = ui; k %= 3; o = vec4(acc + w.x + float(k));");
    assert_eq!(c.local_type("acc"), "f32");
    let t = text("", "int k = ui; k %= 3; o = vec4(float(k));");
    assert!(t.contains("k %= 3;"), "{t}");
}

#[test]
fn constant_integer_expressions_stay_constant_expressions() {
    // a `%` on integer literals feeds an array size, so it must not become a call
    let t = text("const int N = 24 % 5;\nconst uint M = 8u >> 1u;\nfloat w[N];\nfloat v[M];", "w[0] = 1.0; v[0] = 2.0; o = vec4(w[0] + v[1]);");
    assert!(t.contains("const int N = 24 % 5;") && t.contains("float w[N];"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_remainder_of_unknown_types_is_left_alone() {
    let t = text("", "float r = mystery % other; o = vec4(r);");
    assert!(t.contains("mystery % other"), "{t}");
}

#[test]
fn a_remainder_inside_a_texture_call_inside_fmod_inside_an_int_initializer_converts_at_every_level() {
    let c = legacy_frag("uniform sampler2D g_T; varying vec2 v_T; uniform float g_F;\nvoid main() { int k = fmod(texSample2D(g_T, v_T + g_F % 2).r, 3.0); gl_FragColor = vec4(float(k)); }");
    assert_eq!(c.local_type("k"), "i32");
}

// ----- numbers as conditions (R52, R53) -----

#[test]
fn a_number_condition_compares_with_a_zero_of_its_type() {
    let t = text(
        "",
        "int n = ui; uint k = uu; float f = uf; vec3 m = u3; uvec2 cnt = uuv4.xy; float gate = 1.0;
if (n - 4) { o = vec4(1.0); }
if (m.z) { o = vec4(2.0); }
if (gate) { o = vec4(3.0); }
if (cnt.y) { o = vec4(4.0); }
if (1) { o = vec4(5.0); }
if (1.0) { o = vec4(5.5); }
float a = f ? 1.0 : 2.0;
float b = (f + gate) ? 1.0 : 2.0;
do { n--; } while (k - 2u);
while (n + 2) { n = 0; }
if (f > 1.0) { o = vec4(6.0); }
if (a + b) { o = vec4(7.0); }
o += vec4(a + b);",
    );
    for form in ["n - 4 != 0", "m.z != 0.0", "gate != 0.0", "cnt.y != 0u", "1 != 0", "1.0 != 0.0", "f != 0.0 ? 1.0 : 2.0", "k - 2u != 0u", "n + 2 != 0", "a + b != 0.0"] {
        assert!(t.contains(form), "{form}: {t}");
    }
    assert!(t.contains("if (f > 1.0)"), "a boolean condition is untouched: {t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn a_macro_constant_as_a_condition_takes_its_literals_type() {
    let t = text("#define MODE 3\n#define LEVEL 0.5\n", "if (MODE) { o = vec4(1.0); }\nif (LEVEL) { o = vec4(2.0); }");
    assert!(t.contains("3 != 0") && t.contains("0.5 != 0.0"), "{t}");
}

#[test]
fn a_struct_member_condition_uses_the_zero_of_the_members_type() {
    let t = text("struct Box { int tally; float w; };", "Box b; b.tally = 1; b.w = 2.0; if (b.tally) { o = vec4(1.0); } if (b.w) { o = vec4(2.0); }");
    assert!(t.contains("b.tally != 0") && t.contains("b.w != 0.0"), "{t}");
    compile_glsl(StageKind::Fragment, &t).unwrap();
}

#[test]
fn mixed_signedness_arithmetic_conditions_take_the_unsigned_zero() {
    let t = text("", "int i = ui; uint u = uu; while (i - u) { i = 0; } o = vec4(float(i));");
    assert!(t.contains("i - u != 0u"), "{t}");
}

#[test]
fn an_unknown_condition_is_untouched() {
    let t = text("", "if (mystery) { o = vec4(1.0); }");
    assert!(t.contains("if (mystery)"), "{t}");
}

// ----- `!`, `&&`, `||` on numbers (R54, R55) -----

#[test]
fn logical_operators_accept_numbers() {
    let c = ok(
        "",
        "float f = uf, g = ug; int i = ui; float mask = step(0.5, f); bool inside = f > 0.0;
float r = 0.0;
if (!f) { r += 1.0; }
if (!i) { r += 1.0; }
if (!(f + g)) { r += 1.0; }
if (f && g) { r += 1.0; }
if (i || f) { r += 1.0; }
if (mask && inside) { r += 1.0; }
if (!mask) { r += 1.0; }
float on = f || g;
bool z = !f;
o = vec4(r + on + float(z));",
    );
    assert_eq!(c.local_type("on"), "f32");
    let t = text("", "float f = uf, g = ug; int i = ui; bool a = !f; bool b = !i; bool c = f && i; bool d = !(f + g); o = vec4(float(a) + float(b) + float(c) + float(d));");
    assert!(t.contains("(f == 0.0)") && t.contains("(i == 0)"), "{t}");
    assert!(t.contains("f != 0.0") && t.contains("i != 0"), "{t}");
    assert!(t.contains("((f + g) == 0.0)"), "{t}");
}

#[test]
fn logical_operators_on_booleans_are_untouched() {
    let t = text("", "bool a = uf > 1.0; bool b = ug < 2.0; if (!a && b || a) { o = vec4(1.0); }");
    assert!(t.contains("!a && b || a"), "{t}");
}

#[test]
fn short_circuit_evaluation_is_preserved() {
    let t = text("float n = 0.0;\nbool probe() { n += 1.0; return true; }", "float f = uf; if (f && probe()) { o = vec4(1.0); }");
    assert!(t.contains("f != 0.0) && probe()") || t.contains("(f != 0.0) && probe()"), "{t}");
}

// ----- ternary typing (R56) -----

#[test]
fn ternary_branches_take_a_common_type() {
    let c = ok(
        "",
        "bool c = uf > 0.5; float f = uf; vec3 v3 = u3; vec2 v2 = u2;
float a = c ? 1 : 2.0;
vec2 b = c ? v3 : v2;
vec3 d = c ? f : v3;
int e = c ? 1 : 2;
float g = c ? ui : uf;
o = vec4(a + float(e) + g, b, d.x);",
    );
    assert_eq!(c.local_type("a"), "f32");
    assert_eq!(c.local_type("b"), "vec2<f32>");
    assert_eq!(c.local_type("d"), "vec3<f32>");
    assert_eq!(c.local_type("e"), "i32");
}
