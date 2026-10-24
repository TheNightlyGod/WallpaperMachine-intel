// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Probes of the Metal backend that decide how the dialect front end spells a few constructs.
// They compile and run a small Swift program that dispatches a compute kernel (no window, no
// display), so they are opt-in: set WM_SHADER_GPU_PROBES=1. Without it the test prints why it
// did nothing.

use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;

use naga::back::msl;
use naga::front::glsl::{Frontend, Options};
use naga::valid::{Capabilities, ValidationFlags, Validator};
use wm_shader::StageKind;
use wm_shader::dialect::convert_stage;

fn probe_output(script: &str) -> Option<String> {
    if std::env::var_os("WM_SHADER_GPU_PROBES").is_none() {
        eprintln!("skipped: set WM_SHADER_GPU_PROBES=1 to run the Metal probes (needs swiftc and a GPU)");
        return None;
    }
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
    std::fs::create_dir_all(&dir).unwrap();
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes").join(script);
    let binary = dir.join(script.trim_end_matches(".swift"));
    let compiled = Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output();
    match compiled {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&o.stderr));
            return None;
        }
        Err(e) => {
            eprintln!("skipped: swiftc is not available: {e}");
            return None;
        }
    }
    let run = Command::new(&binary).output().expect("the probe runs");
    let text = String::from_utf8_lossy(&run.stdout).to_string();
    if text.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    assert!(run.status.success(), "probe failed: {}", String::from_utf8_lossy(&run.stderr));
    Some(text)
}

/// Direct3D's `smoothstep`: the Hermite curve of the saturated ratio, whatever the order of the edges.
fn d3d_smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The remainder with the sign of the dividend, which is what `%` on floats means (R47).
fn truncated_remainder(x: f32, y: f32) -> f32 {
    x - y * (x / y).trunc()
}

#[test]
fn metal_smoothstep_with_reversed_edges_is_the_direct3d_curve() {
    let Some(out) = probe_output("smoothstep_reversed.swift") else { return };
    let mut samples = 0;
    for line in out.lines().filter(|l| l.starts_with("sample ")) {
        let v: Vec<f32> = line.split_whitespace().skip(1).map(|t| t.parse().unwrap()).collect();
        let (x, runtime, literal, vector, fmod) = (v[0], v[1], v[2], v[3], v[4]);
        let want = d3d_smoothstep(0.9, 0.4, x);
        for (what, got) in [("runtime edges", runtime), ("literal edges", literal), ("vector", vector)] {
            assert!((got - want).abs() < 1e-4, "smoothstep(0.9, 0.4, {x}) with {what}: backend {got}, Direct3D {want}");
        }
        let rem = truncated_remainder(x * 7.0 - 3.0, 2.0);
        assert!((fmod - rem).abs() < 1e-4, "fmod({}, 2) = {fmod}, wanted {rem}", x * 7.0 - 3.0);
        samples += 1;
    }
    assert_eq!(samples, 7, "{out}");
}

// ----- evaluating converted shaders on the GPU -----

fn runner() -> Option<&'static PathBuf> {
    static RUNNER: OnceLock<Option<PathBuf>> = OnceLock::new();
    RUNNER
        .get_or_init(|| {
            if std::env::var_os("WM_SHADER_GPU_PROBES").is_none() {
                eprintln!("skipped: set WM_SHADER_GPU_PROBES=1 to run the Metal probes (needs swiftc and a GPU)");
                return None;
            }
            let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
            std::fs::create_dir_all(&dir).unwrap();
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes/run_kernel.swift");
            let binary = dir.join("run_kernel");
            match Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output() {
                Ok(o) if o.status.success() => Some(binary),
                Ok(o) => {
                    eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&o.stderr));
                    None
                }
                Err(e) => {
                    eprintln!("skipped: swiftc is not available: {e}");
                    None
                }
            }
        })
        .as_ref()
}

/// Converts a compute kernel written in the dialect, writes it as Metal through naga and runs it
/// with one thread over `data` (the shader's `buffer` block of 64 floats). `None` when the probes
/// are off or the machine cannot run them.
fn gpu_run(glsl: &str, inputs: &[f32]) -> Option<Vec<f32>> {
    let runner = runner()?;
    let converted = convert_stage(StageKind::Fragment, glsl).unwrap_or_else(|d| panic!("{d:?}\n{glsl}"));
    let module = Frontend::default()
        .parse(&Options::from(naga::ShaderStage::Compute), &converted.text)
        .unwrap_or_else(|e| panic!("naga parse: {:?}\n{}", e.errors, converted.text));
    let info = Validator::new(ValidationFlags::all(), Capabilities::all())
        .validate(&module)
        .unwrap_or_else(|e| panic!("naga validate: {}\n{}", e.as_inner(), converted.text));
    let mut options = msl::Options { lang_version: (2, 0), fake_missing_bindings: false, ..Default::default() };
    let mut resources = msl::EntryPointResources::default();
    resources.resources.insert(
        naga::ResourceBinding { group: 0, binding: 0 },
        msl::BindTarget { buffer: Some(0), mutable: true, ..Default::default() },
    );
    options.per_entry_point_map.insert("main".to_string(), resources);
    let (text, _) = msl::write_string(&module, &info, &options, &msl::PipelineOptions::default())
        .unwrap_or_else(|e| panic!("msl: {e}\n{}", converted.text));
    let kernel = text
        .lines()
        .find_map(|l| l.strip_prefix("kernel void ").and_then(|r| r.split('(').next()))
        .unwrap_or_else(|| panic!("no kernel in\n{text}"))
        .to_string();
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let file = dir.join(format!("kernel_{}_{}.metal", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
    std::fs::write(&file, &text).unwrap();
    let mut cmd = Command::new(runner);
    cmd.arg(&file).arg(&kernel).arg("64");
    for v in inputs {
        cmd.arg(v.to_string());
    }
    let run = cmd.output().expect("the runner runs");
    let _ = std::fs::remove_file(&file);
    let out = String::from_utf8_lossy(&run.stdout).to_string();
    if out.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    assert!(run.status.success(), "runner failed: {out}{}\n{text}", String::from_utf8_lossy(&run.stderr));
    Some(out.lines().map(|l| l.parse().unwrap()).collect())
}

const KERNEL_HEAD: &str = "layout(local_size_x = 1) in;\nlayout(std430, set = 0, binding = 0) buffer Out { float data[64]; };\n";

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() <= 1e-4 * (1.0 + b.abs())
}

#[test]
fn matrix_inverse_helpers_compute_exact_inverses_on_the_gpu() {
    // Each matrix is multiplied by its inverse; the products are the identity. The input floats keep
    // the compiler from folding the matrices away.
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  mat2 a = mat2(data[0], data[1], data[2], data[3]);
  mat3 b = mat3(data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11], data[12]);
  mat4 c = mat4(data[13], data[14], data[15], data[16], data[17], data[18], data[19], data[20],
                data[21], data[22], data[23], data[24], data[25], data[26], data[27], data[28]);
  mat2 pa = inverse(a) * a;
  mat3 pb = inverse(b) * b;
  mat4 pc = inverse(c) * c;
  for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++) data[29 + i * 2 + j] = pa[i][j];
  for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) data[33 + i * 3 + j] = pb[i][j];
  for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) data[42 + i * 4 + j] = pc[i][j];
}}"
    );
    let inputs: Vec<f32> = [
        2.0, 1.0, 1.0, 3.0, // mat2
        2.0, 0.0, 1.0, 1.0, 3.0, 0.0, 0.0, 1.0, 4.0, // mat3
        4.0, 1.0, 0.5, 0.0, 1.0, 3.0, 0.0, 1.0, 0.5, 0.0, 5.0, 2.0, -1.0, 0.0, 1.0, 2.0, // mat4
    ]
    .to_vec();
    let Some(out) = gpu_run(&src, &inputs) else { return };
    for (base, n) in [(29usize, 2usize), (33, 3), (42, 4)] {
        for i in 0..n {
            for j in 0..n {
                let want = if i == j { 1.0 } else { 0.0 };
                let got = out[base + i * n + j];
                assert!((got - want).abs() < 1e-4, "inverse {n}x{n} times itself at [{i}][{j}]: {got}");
            }
        }
    }
}

#[test]
fn converted_arithmetic_has_the_hlsl_values_on_the_gpu() {
    // data[0..8] are inputs; results go to data[8..].
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float f = data[0];            // -2.7
  float g = data[1];            // 2.0
  vec3 v = vec3(data[2], data[3], data[4]);   // 0.25, -0.5, 1.5
  float hit = data[5];          // 0.4
  data[8] = f % g;                              // truncated remainder, sign of the dividend
  data[9] = fmod(7.5, g + 0.0 * f);
  data[10] = float(int(f));                     // int k = f; truncation toward zero
  int k = f;
  data[11] = float(k);
  data[12] = frac(f);                           // 0.3
  data[13] = log10(100.0 + 0.0 * f);            // 2
  data[14] = saturate(f) + saturate(g * 0.25);  // 0 + 0.5
  data[15] = (hit > 0.3) * 0.75 + (hit > 0.5) * 2.0;   // bool in arithmetic: 0.75
  bool on = g;                                  // number as bool
  data[16] = on ? 1.0 : 0.0;
  if (!g) {{ data[17] = 5.0; }} else {{ data[17] = 6.0; }}      // ! on a number
  data[18] = (g && hit) ? 1.0 : 0.0;                         // && on numbers
  data[19] = lerp(0.0, 10.0, hit);
  data[20] = step(hit, 0.5) + step(0.5, hit);   // 1 + 0
  int lit = step(hit, 0.5);
  lit *= (g > 1.0);
  data[21] = float(lit + 1);                    // 2
  vec2 w = v;                                   // narrowing: first components
  data[22] = w.x + w.y * 10.0;                  // 0.25 - 5
  vec3 b = g;                                   // broadcast
  data[23] = b.x + b.y + b.z;                   // 6
  data[24] = float(uint(g) % 3u);               // integer remainder: 2
  data[25] = max(0, v.y) + min(v.z, 2);         // int literals in float builtins: 0 + 1.5
  data[26] = pow(g, 3);                         // 8
  data[27] = smoothstep(0.9, 0.4, hit);         // reversed edges, Direct3D curve
}}"
    );
    let Some(out) = gpu_run(&src, &[-2.7, 2.0, 0.25, -0.5, 1.5, 0.4]) else { return };
    let t = |x: f32, y: f32| x - y * (x / y).trunc();
    let smooth = {
        let t = ((0.4f32 - 0.9) / (0.4 - 0.9)).clamp(0.0, 1.0);
        t * t * (3.0 - 2.0 * t)
    };
    let want = [
        (8, t(-2.7, 2.0)),
        (9, t(7.5, 2.0)),
        (10, -2.0),
        (11, -2.0),
        (12, -2.7 - (-2.7f32).floor()),
        (13, 2.0),
        (14, 0.5),
        (15, 0.75),
        (16, 1.0),
        (17, 6.0),
        (18, 1.0),
        (19, 4.0),
        (20, 1.0),
        (21, 2.0),
        (22, 0.25 - 5.0),
        (23, 6.0),
        (24, 2.0),
        (25, 1.5),
        (26, 8.0),
        (27, smooth),
    ];
    for (i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}

#[test]
fn converted_matrices_arrays_and_globals_have_the_expected_values_on_the_gpu() {
    // data[0..16] are inputs; results go to data[16..].
    let src = format!(
        "{KERNEL_HEAD}
float taps[4];
const float GAIN = data[0] * 2.0;     // reads a run-time value: moved to the start of main
float pool(float v[4], float scale) {{ return (v[0] + v[1] * 2.0 + v[2] * 3.0 + v[3] * 4.0) * scale; }}
void main() {{
  for (int i = 0; i < 4; i++) {{ taps[i] = data[1 + i]; }}               // 1 2 3 4 from data[1..5]
  vec3 p = vec3(data[5], data[6], data[7]);                               // 1 2 3
  mat4x3 m = mat4x3(data[8], 0.0, 0.0, 0.0, data[9], 0.0, 0.0, 0.0, data[10], 1.0, 2.0, 3.0);
  vec3 moved = mul(vec4(p, 1.0), m);              // (m * v): 2*1+1, 3*2+2, 4*3+3
  data[16] = moved.x; data[17] = moved.y; data[18] = moved.z;
  mat3 r = CAST3X3(m);
  vec3 rot = mul(p, r);                           // p * r (the transposed product)
  data[19] = rot.x; data[20] = rot.y; data[21] = rot.z;
  data[22] = pool(taps, 0.5);                     // (1 + 4 + 9 + 16) * 0.5 = 15
  data[23] = GAIN;                                // 2 * data[0]
  float t = data[11] * 3.0;                       // 3.3 -> index 3
  data[24] = taps[t];                             // float subscript: taps[3] = 4
  float acc = 0.0;
  for (int k = data[12]; k < 4.0; k++) {{ acc += float(k); }}   // starts at 1: 1 + 2 + 3
  data[25] = acc;
  ivec3 iv = ivec3(1, 2, 3);
  vec3 sc = iv * vec3(0.5);                       // integer vector beside a float vector
  data[26] = sc.x + sc.y + sc.z;                  // 3
  uint u = 7u; int n = 3;
  data[27] = float(u % uint(n));                  // 1
  data[28] = (data[13] > 0.5) ? 1 : 2.5;          // ternary promotes to float: 1
  vec2 a2 = vec2(data[14], data[15]);
  vec3 b3 = vec3(1.0, 2.0, 3.0);
  vec2 s2 = a2 + b3;                              // mixed widths: the 3-vector is cut to 2
  data[29] = s2.x; data[30] = s2.y;
}}"
    );
    let inputs = [1.5, 1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.1, 1.9, 0.9, 10.0, 20.0];
    let Some(out) = gpu_run(&src, &inputs) else { return };
    let want = [
        (16, 2.0 * 1.0 + 1.0),
        (17, 3.0 * 2.0 + 2.0),
        (18, 4.0 * 3.0 + 3.0),
        // p * r with r = diag(2, 3, 4) in its first three columns: component-wise 1*2, 2*3, 3*4
        (19, 2.0),
        (20, 6.0),
        (21, 12.0),
        (22, 15.0),
        (23, 3.0),
        (24, 4.0),
        (25, 1.0 + 2.0 + 3.0),
        (26, 3.0),
        (27, 1.0),
        (28, 1.0),
        (29, 11.0),
        (30, 22.0),
    ];
    for (i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}

#[test]
fn converted_calls_and_assignments_have_the_expected_values_on_the_gpu() {
    // data[0..12] are inputs; results go to data[16..].
    let src = format!(
        "{KERNEL_HEAD}
struct Pair {{ vec2 xy; float k; }};
vec2 cut(vec4 v, float s) {{ return v * s; }}           // a 4-vector into a vec2 parameter: .xy
vec3 spread(vec3 c) {{ return c + 1.0; }}               // a scalar argument broadcasts
int whole(int n) {{ return n * 2; }}                    // a float argument truncates
float lum(vec3 c) {{ return dot(c, vec3(1.0)); }}        // a scalar function into a vector target
vec3 widen(float s) {{ return s; }}                     // a scalar returned from a vec3 function
float first(vec3 a, vec3 b) {{ return a * b; }}         // a vector returned from a float function
bool nonzero(float f) {{ return f; }}                   // a number returned from a bool function
void main() {{
  float a = data[0];                    // 1.5
  float b = data[1];                    // 2.0
  vec4 v4 = vec4(data[2], data[3], data[4], data[5]);   // 1 2 3 4
  vec3 base = vec3(data[6], data[7], data[8]);          // 10 20 30
  data[16] = cut(v4, b).x + cut(v4, b).y * 100.0;       // 2 + 400
  vec3 sp = spread(0.5);
  data[17] = sp.x + sp.y + sp.z;                        // 4.5
  data[18] = float(whole(a * 3.0));                     // whole(4) = 8
  vec3 l = lum(base);                                   // 60 each
  data[19] = l.x + l.y + l.z;                           // 180
  vec3 w = widen(b);
  data[20] = w.x + w.y + w.z;                           // 6
  data[21] = first(base, base);                         // 100
  data[22] = nonzero(a) ? 1.0 : 0.0;                    // 1
  vec3 padded = base + vec2(1.0, 2.0);                  // the 2-vector is padded with 0
  data[23] = padded.x + padded.y * 100.0 + padded.z * 10000.0;   // 11 + 2200 + 300000
  vec3 acc = vec3(1.0);
  acc *= 2;                                             // int literal into a float vector
  acc += v4;                                            // a wider vector into a vec3
  acc -= (a > 1.0);                                     // a bool into a vector
  data[24] = acc.x + acc.y * 10.0 + acc.z * 100.0;      // (2+1-1) + (2+2-1)*10 + (2+3-1)*100 = 2 + 30 + 400
  float f = 10.0;
  f %= 4;                                               // 2
  f += (b > 1.0);                                       // 3
  f *= (b > 5.0);                                       // 0
  data[25] = f;
  int i = 7;
  i = i / 2;                                            // integer division: 3
  i += a;                                               // truncated: 3 + 1 = 4
  data[26] = float(i);
  Pair p; p.xy = vec2(5.0, 6.0); p.k = 3.0;
  vec3 pp = p.xy.xyx * p.k;                             // member of a struct
  data[27] = pp.x + pp.y + pp.z;                        // 15 + 18 + 15
  vec2 m = max(v4 * vec2(2.0), vec2(3.0, 100.0));       // a 4-vector times a 2-vector: first two
  data[28] = m.x + m.y;                                 // 3 + 100
  float g = (a ? 4 : 5.5);                              // number condition, promoted branches
  data[29] = g;                                         // 4
  vec3 mixd = mix(base, 3, 0.5);                        // scalar broadcast in mix
  data[30] = mixd.x + mixd.y + mixd.z;                  // (6.5 + 11.5 + 16.5)
  mat3 m3 = mat3(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0);
  vec3 q = mul(m3, vec3(1.0, 1.0, 1.0));                // v * m3 for a diagonal matrix
  data[31] = q.x + q.y * 10.0 + q.z * 100.0;            // 2 + 30 + 400
  float ct = 0.0;
  for (uint u = 0u; u < 3u; u++) {{ ct += float(u); }}  // 0 + 1 + 2
  for (float s = 1.0; s > 0.25; s -= 0.25) {{ ct += s; }}   // 1 + .75 + .5
  data[32] = ct;                                        // 5.25
  if (!(a - 1.5)) {{ data[33] = 7.0; }} else {{ data[33] = 8.0; }}   // a - 1.5 is zero: 7
  data[34] = (v4.x < 2 ? 1.0 : 0.0) + (v4.y >= 2.0 ? 10.0 : 0.0);  // int against float: 1 + 10
}}"
    );
    let inputs = [1.5, 2.0, 1.0, 2.0, 3.0, 4.0, 10.0, 20.0, 30.0];
    let Some(out) = gpu_run(&src, &inputs) else { return };
    let want = [
        (16, 2.0 + 400.0),
        (17, 4.5),
        (18, 8.0),
        (19, 180.0),
        (20, 6.0),
        (21, 100.0),
        (22, 1.0),
        (23, 11.0 + 2200.0 + 300000.0),
        (24, 2.0 + 30.0 + 400.0),
        (25, 0.0),
        (26, 4.0),
        (27, 15.0 + 18.0 + 15.0),
        (28, 103.0),
        (29, 4.0),
        (30, 6.5 + 11.5 + 16.5),
        (31, 2.0 + 30.0 + 400.0),
        (32, 5.25),
        (33, 7.0),
        (34, 11.0),
    ];
    for (i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}

// ----- the NV12 plane conversion of the interface part -----

/// The pure conversion function the legalizer emits for a flagged video slot, cut out of the
/// legalized fragment stage so that the GPU can evaluate it on its own.
fn plane_conversion_source() -> String {
    let fragment = "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T); }";
    let vertex = "attribute vec3 a_P;\nvoid main() { gl_Position = vec4(a_P, 1.0); }";
    let program = wm_shader::legalize::legalize(&wm_shader::legalize::ProgramInput::program(vertex, fragment).with_planes(&[0])).unwrap();
    let text = program.fragment.unwrap().text;
    let start = text.find("vec4 _we_nv12_convert0(").expect("the conversion function");
    let end = start + text[start..].find("\n}\n").expect("its end") + 3;
    text[start..end].to_string()
}

/// The conversion as the contract states it (R48), evaluated on the CPU.
fn plane_reference(y: f32, c: [f32; 2], p: [f32; 2], t: [f32; 4], r: [f32; 4], m: [f32; 4]) -> [f32; 4] {
    let l = ((y - r[0]) * r[1]).clamp(0.0, 1.0);
    let (c1, c2) = ((c[0] - r[2]) * r[3], (c[1] - r[2]) * r[3]);
    let rgb = [(l + m[0] * c2).clamp(0.0, 1.0), (l + m[1] * c1 + m[2] * c2).clamp(0.0, 1.0), (l + m[3] * c1).clamp(0.0, 1.0)];
    let skewed = (t[0] * t[1]).abs() > 1e-6 || (t[2] * t[3]).abs() > 1e-6;
    let inside = (0.0..=1.0).contains(&p[0]) && (0.0..=1.0).contains(&p[1]);
    let cover = if skewed && !inside { 0.0 } else { 1.0 };
    [rgb[0] * cover, rgb[1] * cover, rgb[2] * cover, cover]
}

#[test]
fn the_plane_conversion_matches_the_contract_arithmetic_on_the_gpu() {
    let function = plane_conversion_source();
    let src = format!(
        "{KERNEL_HEAD}{function}
void main() {{
  vec4 o = _we_nv12_convert0(data[0], vec2(data[1], data[2]), vec2(data[3], data[4]), vec4(data[5], data[6], data[7], data[8]),
                              vec4(data[9], data[10], data[11], data[12]), vec4(data[13], data[14], data[15], data[16]));
  data[20] = o.x; data[21] = o.y; data[22] = o.z; data[23] = o.w;
}}"
    );
    // limited-range BT.601: the eight constants a host would upload
    let range = [16.0 / 255.0, 255.0 / 219.0, 128.0 / 255.0, 255.0 / 224.0];
    let matrix = [1.402, -0.344136, -0.714136, 1.772];
    let identity = [1.0, 0.0, 0.0, 1.0];
    let rotated = [0.0, 1.0, -1.0, 0.0];
    let cases = [
        (0.5, [0.4, 0.6], [0.3, 0.7], identity),
        (0.9, [0.2, 0.9], [0.5, 0.5], identity),
        (0.1, [0.5, 0.5], [0.0, 1.0], identity),
        (0.6, [0.3, 0.3], [0.25, 0.75], rotated), // inside: coverage 1
        (0.6, [0.3, 0.3], [1.5, 0.25], rotated),  // outside: coverage 0
        (0.6, [0.3, 0.3], [-0.2, 0.5], rotated),
    ];
    for (y, c, p, t) in cases {
        let mut input = vec![y, c[0], c[1], p[0], p[1]];
        input.extend(t);
        input.extend(range);
        input.extend(matrix);
        let Some(out) = gpu_run(&src, &input) else { return };
        let want = plane_reference(y, c, p, t, range, matrix);
        for i in 0..4 {
            assert!((out[20 + i] - want[i]).abs() <= 1.0 / 255.0, "y {y} c {c:?} p {p:?} t {t:?}: channel {i} is {}, wanted {}", out[20 + i], want[i]);
        }
    }
}

#[test]
fn a_float_remainder_has_the_truncated_values_on_the_gpu() {
    // The `%` operator on floats is Metal's fmod: truncated, sign of the dividend, componentwise,
    // with a scalar operand broadcast (C2 R69 to R76).
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float a = data[0];                              // -7.25
  vec2 v = vec2(data[1], data[2]);                // 5.5, -3.0
  data[8] = a % 2.0;                              // -1.25
  vec2 r = v % 2.0;                               // 1.5, -1.0
  data[9] = r.x; data[10] = r.y;
  vec2 q = 7.0 % v;                               // 1.5, 1.0
  data[11] = q.x; data[12] = q.y;
  float u = data[3];                              // 9.0
  u %= 4.0;                                       // 1
  data[13] = u;
  int n = 7; int c = 3;
  data[14] = float(n % c);                        // integer remainder: 1
  data[15] = a % -0.75;                           // -0.5 (the sign of the dividend)
}}"
    );
    let Some(out) = gpu_run(&src, &[-7.25, 5.5, -3.0, 9.0]) else { return };
    for (i, w) in [(8, -1.25), (9, 1.5), (10, -1.0), (11, 1.5), (12, 1.0), (13, 1.0), (14, 1.0), (15, -0.5)] {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}
