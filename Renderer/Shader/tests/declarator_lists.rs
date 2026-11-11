// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// An array suffix belongs to one declarator, not to the type a declaration list shares
// (`float color[4], f;` declares a float array and a float). naga's GLSL front end gives the
// declarators after an array declarator the array type, so a later `vec2 + f` failed validation and
// the whole effect was dropped. Each declaration of that shape must translate as if every
// declarator had been written as its own statement, with its own type and qualifiers: locals,
// globals, constants, declarators with initializers (constructors and brace lists) and uniforms.
// A `for` initializer list stays one statement.
//
// The kernels are checked with naga's types always and evaluated on the GPU with
// WM_SHADER_GPU_PROBES=1.

mod support;

use naga::ScalarKind::Float;
use support::*;

#[test]
fn a_scalar_after_an_array_declarator_is_a_scalar() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float color[4], f;
  f = data[0];
  for (int i = 0; i < 4; i++) {{ color[i] = data[1 + i]; }}
  vec2 s = CAST2(1.0) + f;
  data[16] = s.x + s.y * 10.0;
  data[17] = color[2] + f;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("f"), FLOAT);
    assert_eq!(k.ir.local("color"), array(FLOAT, 4));
    let Some(out) = gpu_run(&k, &[0.5, 1.0, 2.0, 3.0, 4.0]) else { return };
    assert_values(&out, &[(16, 1.5 + 15.0), (17, 3.5)]);
}

#[test]
fn an_array_declarator_in_the_middle_of_a_list_types_only_itself() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  vec2 a, b[2], c;
  a = vec2(data[0], data[1]);
  b[0] = a * 2.0; b[1] = a * 3.0;
  c = a + CAST2(1.0);
  vec2 d = a + c + b[1];
  data[16] = d.x; data[17] = d.y;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("a"), vector(Float, 2));
    assert_eq!(k.ir.local("b"), array(vector(Float, 2), 2));
    assert_eq!(k.ir.local("c"), vector(Float, 2));
    let Some(out) = gpu_run(&k, &[1.0, 2.0]) else { return };
    // a + (a + 1) + 3a
    assert_values(&out, &[(16, 1.0 + 2.0 + 3.0), (17, 2.0 + 3.0 + 6.0)]);
}

#[test]
fn global_and_constant_lists_declare_each_name_with_its_own_type() {
    let src = format!(
        "{KERNEL_HEAD}float taps[3], gain;
const float K[2] = float[2](1.0, 2.0), G = 3.0;
void main() {{
  const float L[2] = float[2](4.0, 5.0), H = 6.0;
  gain = data[0];
  taps[1] = data[1];
  vec2 s = CAST2(1.0) + gain + G + H;
  data[16] = s.y;
  data[17] = taps[1] * K[1] + L[0];
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.global("gain"), FLOAT);
    assert_eq!(k.ir.global("taps"), array(FLOAT, 3));
    assert_eq!(k.ir.global("G"), FLOAT);
    assert_eq!(k.ir.global("K"), array(FLOAT, 2));
    let Some(out) = gpu_run(&k, &[0.5, 7.0]) else { return };
    assert_values(&out, &[(16, 1.0 + 0.5 + 3.0 + 6.0), (17, 7.0 * 2.0 + 4.0)]);
}

#[test]
fn declarators_with_initializers_keep_their_own_initializer() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float a[2] = float[2](data[0], 2.0), b = 3.0;
  float p[2] = {{data[1], 5.0}}, q;
  q = data[2];
  vec2 s = vec2(a[0], p[0]) + b + q;
  data[16] = s.x; data[17] = s.y;
  data[18] = a[1] + p[1];
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("b"), FLOAT);
    assert_eq!(k.ir.local("q"), FLOAT);
    assert_eq!(k.ir.local("p"), array(FLOAT, 2));
    let Some(out) = gpu_run(&k, &[10.0, 20.0, 0.25]) else { return };
    assert_values(&out, &[(16, 10.0 + 3.25), (17, 20.0 + 3.25), (18, 7.0)]);
}

#[test]
fn a_for_initializer_list_stays_one_statement() {
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float s = 0.0;
  for (int i = 0, j = int(data[0]); i < 3; i++, j++) {{ s += float(i * j); }}
  data[16] = s;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("j"), INT);
    let Some(out) = gpu_run(&k, &[1.0]) else { return };
    // 0 * 1 + 1 * 2 + 2 * 3
    assert_values(&out, &[(16, 8.0)]);
}

#[test]
fn a_for_initializer_with_an_array_declarator_keeps_every_declaration() {
    // The loop variable comes after an array declarator, so it is not the array's type, and it must
    // still be declared (and initialised) for the loop.
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float t = 0.0;
  for (float acc[2], k = data[0]; k < 3.0; k += 1.0) {{ acc[1] = k * 10.0; t += acc[1] + k; }}
  data[16] = t;
}}"
    );
    let k = kernel(&src);
    assert_eq!(k.ir.local("k"), FLOAT);
    assert_eq!(k.ir.local("acc"), array(FLOAT, 2));
    let Some(out) = gpu_run(&k, &[1.0]) else { return };
    // k = 1 and 2: 11 + 22
    assert_values(&out, &[(16, 33.0)]);
}

#[test]
fn a_uniform_list_declares_every_name_with_its_own_type() {
    let fragment = "varying vec2 v_TexCoord;
uniform float g_Bands[4], g_Gain;
uniform vec2 g_Center, g_Points[2], g_Offset;
void main() {
  vec2 s = CAST2(1.0) + g_Gain;
  gl_FragColor = vec4(s * g_Center + g_Points[1] + g_Offset, g_Bands[3], 1.0);
}";
    let p = program_ok(fragment);
    let members: Vec<(String, u32, u32)> = p.reflection.uniform_blocks.iter().flat_map(|b| b.members.iter()).map(|m| (m.name.clone(), m.element_count, m.array_count)).collect();
    // Scalar and narrow-vector arrays are stored with four-component elements in the block.
    for want in [("g_Bands", 4, 4), ("g_Gain", 1, 0), ("g_Center", 2, 0), ("g_Points", 4, 2), ("g_Offset", 2, 0)] {
        assert!(members.contains(&(want.0.to_string(), want.1, want.2)), "{want:?} in {members:?}");
    }
    let ir = fragment_ir(&p);
    assert_eq!(ir.local("s"), vector(Float, 2));
}

#[test]
fn an_annotation_after_a_uniform_list_binds_where_it_did_without_the_array_suffix() {
    // The metadata contract binds an annotation to the declaration it follows on the same line, and
    // names that declaration by its first declarator. An array suffix in the list changes neither.
    let alias_of = |fragment: &str| -> Vec<(String, String)> {
        let p = program_ok(fragment);
        p.metadata.aliases.iter().map(|a| (a.material.clone(), a.uniform.clone())).collect()
    };
    let plain = "varying vec2 v_TexCoord;
uniform float g_Rate, g_Gain; // {\"material\":\"rate\"}
uniform float g_Mix; // {\"material\":\"mix\"}
void main() { gl_FragColor = CAST4(g_Rate + g_Gain + g_Mix); }";
    let with_array = "varying vec2 v_TexCoord;
uniform float g_Rate[4], g_Gain; // {\"material\":\"rate\"}
uniform float g_Mix; // {\"material\":\"mix\"}
void main() { gl_FragColor = CAST4(g_Rate[0] + g_Gain + g_Mix); }";
    let expected = vec![("rate".to_string(), "g_Rate".to_string()), ("mix".to_string(), "g_Mix".to_string())];
    assert_eq!(alias_of(plain), expected);
    assert_eq!(alias_of(with_array), expected);
}
