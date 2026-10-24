// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// `clamp`, `min` and `max` on integers keep integer literals. The dialect lets an integer literal
// stand where a float is wanted, but legacy shaders write `clamp(index, 0, 63)` on an `int` and
// mean integer arithmetic: an `int` or `ivecN` operand (and no float one) selects the integer
// overload, `uint`/`uvecN` operands the unsigned one, and only a float operand turns the literals
// into floats. An integer clamp whose result is used as a float clamps as an integer and converts.
//
// naga's types are checked always; the values with WM_SHADER_GPU_PROBES=1.

mod support;

use naga::MathFunction::{Clamp, Max, Min};
use naga::ScalarKind::{Float, Sint, Uint};
use support::*;

#[test]
fn an_int_operand_keeps_the_literals_integer_and_the_result_indexes() {
    let src = format!(
        "{KERNEL_HEAD}#define BANDS 6
float table[8];
void main() {{
  for (int i = 0; i < 8; i++) {{ table[i] = float(i) * 10.0 + 1.0; }}
  int index = int(data[0]);
  index = clamp(index, 0, BANDS - 1);
  data[16] = table[index];
  int low = clamp(int(data[1]), 0, 5);
  data[17] = float(low);
  ivec2 pair = clamp(ivec2(int(data[0]), int(data[1])), 0, 5);
  data[18] = float(pair.x * 10 + pair.y);
  int m = max(int(data[1]), 2) + min(index, 4);
  data[19] = float(m);
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.math_results(Clamp), vec![INT, INT, vector(Sint, 2)]);
    assert_eq!(k.ir.math_results(Max), vec![INT]);
    assert_eq!(k.ir.math_results(Min), vec![INT]);
    assert_eq!(k.ir.local("index"), INT);
    let Some(out) = gpu_run(&k, &[7.0, -3.0]) else { return };
    // clamp(7, 0, 5) selects element 5; -3 clamps to 0; max(-3, 2) + min(5, 4).
    assert_values(&out, &[(16, 51.0), (17, 0.0), (18, 50.0), (19, 6.0)]);
}

#[test]
fn unsigned_operands_select_the_unsigned_overload() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  uint u = uint(data[0]);
  uint v = min(u, 3);
  uint w = clamp(u, 1, 4);
  uvec2 uv = max(uvec2(u, 1u), 2);
  data[16] = float(v);
  data[17] = float(w);
  data[18] = float(uv.x * 10u + uv.y);
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.math_results(Min), vec![UINT]);
    assert_eq!(k.ir.math_results(Clamp), vec![UINT]);
    assert_eq!(k.ir.math_results(Max), vec![vector(Uint, 2)]);
    let Some(out) = gpu_run(&k, &[9.0]) else { return };
    assert_values(&out, &[(16, 3.0), (17, 4.0), (18, 92.0)]);
}

#[test]
fn a_float_operand_turns_the_literals_into_floats() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float f = data[0];
  data[16] = clamp(f, 0, 5);
  data[17] = clamp(data[1], 0, 5);
  data[18] = min(f, 3) + max(data[1], 1);
  vec2 fv = clamp(vec2(f, data[1]), 0, 5);
  data[19] = fv.x + fv.y * 10.0;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.math_results(Clamp), vec![FLOAT, FLOAT, vector(Float, 2)]);
    assert_eq!(k.ir.math_results(Min), vec![FLOAT]);
    assert_eq!(k.ir.math_results(Max), vec![FLOAT]);
    let Some(out) = gpu_run(&k, &[7.5, 2.5]) else { return };
    // A float clamp keeps the fraction of 2.5.
    assert_values(&out, &[(16, 5.0), (17, 2.5), (18, 3.0 + 2.5), (19, 5.0 + 25.0)]);
}

#[test]
fn literal_only_calls_have_the_literal_value() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  data[16] = clamp(7, 0, 5) * (data[0] + 1.0);
  data[17] = min(2, 9) + max(1, 3);
}}"
    );
    let k = kernel(&src);
    let Some(out) = gpu_run(&k, &[0.5]) else { return };
    assert_values(&out, &[(16, 7.5), (17, 5.0)]);
}

#[test]
fn an_integer_clamp_used_as_a_float_clamps_as_an_integer_then_converts() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  int i = int(data[0]);
  data[16] = clamp(i, 0, 5) * 0.5;
  float g = clamp(int(data[1]), 0, 5) * 0.5 + 0.25;
  data[17] = g;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.math_results(Clamp), vec![INT, INT]);
    let Some(out) = gpu_run(&k, &[7.0, 3.0]) else { return };
    // The same values as a float clamp of float(i) for these integer bounds.
    assert_values(&out, &[(16, 2.5), (17, 1.75)]);
}

#[test]
fn an_int_initialised_from_step_clamps_like_any_int() {
    // The converter keeps `int lit = step(...)` an `int` (with a conversion of the float `step`),
    // so its clamp is an integer clamp with integer literals.
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  int lit = step(data[0], 3.0);
  int c = clamp(lit + 4, 0, 3);
  data[16] = float(c);
  int off = step(5.0, data[0]);
  data[17] = float(clamp(off - 2, -1, 1));
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("lit"), INT);
    assert_eq!(k.ir.math_results(Clamp), vec![INT, INT]);
    let Some(out) = gpu_run(&k, &[2.5]) else { return };
    assert_values(&out, &[(16, 3.0), (17, -1.0)]);
}

#[test]
fn an_integer_uniform_clamped_by_a_macro_bound_compiles_through_the_pipeline() {
    let fragment = "#define BANDS 64
varying vec2 v_TexCoord;
uniform float g_AudioSpectrum[BANDS];
uniform int g_Band;
void main() {
  int index = int(v_TexCoord.x * float(BANDS));
  index = clamp(index, 0, BANDS - 1);
  int other = clamp(g_Band, 0, BANDS - 1);
  gl_FragColor = vec4(g_AudioSpectrum[index] + g_AudioSpectrum[other]);
}";
    let p = program_ok(fragment);
    let ir = fragment_ir(&p);
    assert_eq!(ir.math_results(Clamp), vec![INT, INT]);
    assert_eq!(ir.local("index"), INT);
}
