// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The dialect lets a scalar be swizzled like a vector: `f.x`, `f.xx`, `f.xxx` and `f.xxxx` (and the
// same with `r` and `s`) repeat its one component, so `vec3 v = f.xxx;` is `vec3(f)`. naga refuses
// any swizzle of a scalar, which dropped the whole effect. A genuine vector swizzle keeps its
// mapping, the declaration in scope decides whether a name is a scalar, and a splat flows into the
// width rules like any vector. A scalar initialised from a vector expression takes the first
// component of the complete expression, after every component-wise consumer has run.
//
// naga's types are checked always; the values with WM_SHADER_GPU_PROBES=1.

mod support;

use naga::MathFunction::{Max, Mix};
use naga::ScalarKind::{Bool, Float, Sint, Uint};
use support::*;

#[test]
fn a_scalar_swizzle_repeats_the_scalar_in_every_width_and_kind() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float f = data[0];
  vec3 v = f.xxx;
  vec4 w = f.rrrr;
  vec2 q = f.ss;
  float z = f.x + f.r + f.s;
  int n = int(data[1]);
  int3 nv = n.xxx;
  uint u = uint(data[1]);
  uint2 uu = u.rr;
  bool b = data[0] > 1.0;
  bool2 bb = b.xx;
  data[16] = v.x + v.y * 10.0 + v.z * 100.0;
  data[17] = w.x + w.w;
  data[18] = q.y;
  data[19] = z;
  data[20] = float(nv.x + nv.y + nv.z);
  data[21] = float(uu.x + uu.y);
  data[22] = (bb.x && bb.y) ? 1.0 : 0.0;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("v"), vector(Float, 3));
    assert_eq!(k.ir.local("w"), vector(Float, 4));
    assert_eq!(k.ir.local("q"), vector(Float, 2));
    assert_eq!(k.ir.local("nv"), vector(Sint, 3));
    assert_eq!(k.ir.local("uu"), vector(Uint, 2));
    assert_eq!(k.ir.local("bb"), vector(Bool, 2));
    let Some(out) = gpu_run(&k, &[1.5, 3.0]) else { return };
    assert_values(&out, &[(16, 1.5 * 111.0), (17, 3.0), (18, 1.5), (19, 4.5), (20, 9.0), (21, 6.0), (22, 1.0)]);
}

#[test]
fn a_splat_works_in_arguments_arithmetic_parameters_and_call_results() {
    let src = format!(
        "{KERNEL_HEAD}float twice(float s) {{ return s * 2.0; }}
vec3 tint(float s) {{ return s.xxx * vec3(1.0, 2.0, 3.0); }}
void main() {{
  float f = data[0];
  vec3 a = tint(f);
  vec3 b = twice(f).xxx + a;
  float d = dot(f.xxx, vec3(1.0, 2.0, 3.0));
  vec4 c = vec4(f.xx, f.xx * 2.0);
  data[16] = a.x + a.y * 10.0 + a.z * 100.0;
  data[17] = b.x + b.y * 10.0 + b.z * 100.0;
  data[18] = d;
  data[19] = c.x + c.y + c.z + c.w;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("b"), vector(Float, 3));
    assert_eq!(k.ir.local("c"), vector(Float, 4));
    let Some(out) = gpu_run(&k, &[0.5]) else { return };
    // a = (0.5, 1, 1.5); b = 1 + a; d = 0.5 * 6; c = (0.5, 0.5, 1, 1)
    assert_values(&out, &[(16, 0.5 + 10.0 + 150.0), (17, 1.5 + 20.0 + 250.0), (18, 3.0), (19, 3.0)]);
}

#[test]
fn a_vector_swizzle_keeps_its_component_mapping() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  vec3 p = vec3(data[0], data[1], data[2]);
  vec3 r = p.zyx;
  vec2 g = p.yx;
  vec4 x = p.xxzz;
  data[16] = r.x + r.y * 10.0 + r.z * 100.0;
  data[17] = g.x + g.y * 10.0;
  data[18] = x.x + x.y * 10.0 + x.z * 100.0 + x.w * 1000.0;
}}"
    );
    let k = kernel(&src);
    let Some(out) = gpu_run(&k, &[1.0, 2.0, 3.0]) else { return };
    assert_values(&out, &[(16, 3.0 + 20.0 + 100.0), (17, 2.0 + 10.0), (18, 1.0 + 10.0 + 300.0 + 3000.0)]);
}

#[test]
fn the_declaration_in_scope_decides_whether_a_name_is_a_scalar() {
    let src = format!(
        "{KERNEL_HEAD}vec3 k;
float through(float k) {{ return dot(k.xxx, CAST3(1.0)); }}
void main() {{
  float v = data[0];
  vec3 outer = v.xxx;
  {{
    vec3 v = vec3(data[1], data[2], data[3]);
    vec3 inner = v.xxx;
    vec3 rev = v.zyx;
    data[16] = inner.x + inner.y + inner.z;
    data[17] = rev.x;
  }}
  vec3 again = v.xxx;
  data[18] = again.x + again.y + again.z + outer.y;
  vec2 s = vec2(data[1], data[2]);
  for (int i = 0; i < 1; i++) {{
    float s = data[3];
    vec2 t = s.xx;
    data[19] = t.x + t.y;
  }}
  data[20] = s.yx.x;
  k = vec3(data[1], data[2], data[3]);
  data[21] = through(data[0]) + k.zyx.x;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.locals("v"), vec![FLOAT, vector(Float, 3)]);
    assert_eq!(k.ir.locals("s"), vec![vector(Float, 2), FLOAT]);
    let Some(out) = gpu_run(&k, &[2.0, 1.0, 2.0, 3.0]) else { return };
    assert_values(&out, &[(16, 3.0), (17, 3.0), (18, 8.0), (19, 6.0), (20, 2.0), (21, 6.0 + 3.0)]);
}

#[test]
fn a_splat_takes_part_in_the_width_rules_like_any_vector() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float f = data[0];
  vec2 cut = f.xxx;
  vec4 sum = vec4(1.0, 2.0, 3.0, 4.0) + f.xxxx;
  vec2 mixed = f.xx + vec3(1.0, 2.0, 3.0);
  float back = f.xxx;
  int whole = f.xx;
  data[16] = cut.x + cut.y;
  data[17] = sum.x + sum.w;
  data[18] = mixed.x + mixed.y * 10.0;
  data[19] = back;
  data[20] = float(whole);
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("cut"), vector(Float, 2));
    assert_eq!(k.ir.local("mixed"), vector(Float, 2));
    assert_eq!(k.ir.local("back"), FLOAT);
    assert_eq!(k.ir.local("whole"), INT);
    let Some(out) = gpu_run(&k, &[2.0]) else { return };
    assert_values(&out, &[(16, 4.0), (17, 3.0 + 6.0), (18, 3.0 + 40.0), (19, 2.0), (20, 2.0)]);
}

#[test]
fn uniform_scalars_can_be_splatted_through_the_pipeline() {
    let fragment = "varying vec2 v_TexCoord;
uniform float g_Brightness;
uniform int g_Steps;
void main() {
  vec3 c = g_Brightness.xxx;
  int2 s = g_Steps.xx;
  gl_FragColor = vec4(c * float(s.y), g_Brightness.r);
}";
    let p = program_ok(fragment);
    let ir = fragment_ir(&p);
    assert_eq!(ir.local("c"), vector(Float, 3));
    assert_eq!(ir.local("s"), vector(Sint, 2));
}

#[test]
fn only_repeats_of_the_first_component_are_scalar_swizzles() {
    for swizzle in ["y", "xy", "rg", "xxxxx", "w"] {
        let fragment = format!("varying vec2 v_TexCoord;\nuniform float g_F;\nvoid main() {{ gl_FragColor = vec4(g_F.{swizzle}.x); }}");
        assert!(program(&fragment).is_err(), "`g_F.{swizzle}` is not a swizzle of a scalar");
    }
}

#[test]
fn a_scalar_initialised_from_a_vector_expression_takes_its_first_component_last() {
    // The vectors have a different value in every component, and `swap` reverses its argument, so
    // narrowing anything before the whole expression is evaluated gives other numbers.
    let src = format!(
        "{KERNEL_HEAD}vec4 swap(vec4 v) {{ return v.wzyx; }}
void main() {{
  vec4 s = vec4(data[0], data[1], data[2], data[3]);
  vec4 o = vec4(0.5, 0.1, 0.8, 0.3);
  float a = max(s, o) * 2.0 + 1.0;
  float b = mix(s, o, 0.25) * 4.0 - 1.0;
  float c = swap(max(s, o));
  float d = abs(swap(s) - o);
  float e = clamp(swap(s), o, CAST4(0.6)) + min(s, o).y;
  data[16] = a; data[17] = b; data[18] = c; data[19] = d; data[20] = e;
}}"
    );
    let k = kernel(&src);
    for name in ["a", "b", "c", "d", "e"] {
        assert_eq!(k.ir.local(name), FLOAT, "{name}");
    }
    let Some(out) = gpu_run(&k, &[0.2, 0.7, 0.4, 0.9]) else { return };
    let mix = 0.2 + (0.5 - 0.2) * 0.25;
    assert_values(&out, &[(16, 2.0), (17, mix * 4.0 - 1.0), (18, 0.9), (19, 0.4), (20, 0.6 + 0.1)]);
}

#[test]
fn a_sample_reaches_its_component_wise_consumer_whole_before_the_scalar_narrowing() {
    let fragment = "varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Gain;
void main() {
  float a = max(texSample2D(g_Texture0, v_TexCoord), vec4(0.5, 0.1, 0.8, 0.3)) * g_Gain + 0.25;
  float b = mix(texSample2D(g_Texture0, v_TexCoord), vec4(1.0, 2.0, 3.0, 4.0), g_Gain);
  gl_FragColor = vec4(a, b, 0.0, 1.0);
}";
    let p = program_ok(fragment);
    let ir = fragment_ir(&p);
    // The whole sample is the consumer's operand; the narrowing comes after the arithmetic.
    assert_eq!(ir.math_first_argument_is_a_sample(Max), vec![true]);
    assert_eq!(ir.math_first_argument_is_a_sample(Mix), vec![true]);
    assert_eq!(ir.math_results(Max), vec![vector(Float, 4)]);
    assert_eq!(ir.math_results(Mix), vec![vector(Float, 4)]);
    assert_eq!(ir.local("a"), FLOAT);
    assert_eq!(ir.local("b"), FLOAT);
}
