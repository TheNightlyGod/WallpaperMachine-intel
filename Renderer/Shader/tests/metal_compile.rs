// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The one check that proves the generated Metal text compiles on macOS (spec D test 26): the
// MSL of programs is compiled with default options by the system's Metal compiler service, as the
// host does (`makeLibrary(source:options:)`), through a small Swift runner. No window, no
// display, nothing is drawn.
//
// Opt-in: set WM_SHADER_METAL_COMPILE=1. Without it, or without swiftc and a Metal device, the
// tests print why they did nothing. WM_SHADER_METAL_COMPILE_CORPUS=1 also compiles the MSL of every
// shipped Wallpaper Engine program that translates.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use wm_shader::pipeline::{CompiledProgram, compile};
use wm_shader::source::{MemorySource, NoIncludes};
use wm_shader::{Combo, ShaderRequest, Stage, StageKind, TextureRecord};

fn metal_available() -> bool {
    if std::env::var_os("WM_SHADER_METAL_COMPILE").is_none() {
        eprintln!("skipped: set WM_SHADER_METAL_COMPILE=1 to compile the generated text with the system's Metal compiler");
        return false;
    }
    true
}

fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("metal_compile").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The compile runner (tests/probes/compile_msl.swift), built once.
fn runner() -> Option<PathBuf> {
    static BUILT: OnceLock<Option<PathBuf>> = OnceLock::new();
    BUILT
        .get_or_init(|| {
            let dir = scratch("runner");
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes/compile_msl.swift");
            let binary = dir.join("compile_msl");
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
        .clone()
}

/// Compiles texts with default options, the way the host does. `items` are
/// `(label, entry point, MSL)`; the result lists the labels the compiler refused, with its words.
/// `None` when no compiler can be run here (printed as a skip).
fn metal_compile(dir: &Path, items: &[(String, String, String)]) -> Option<Vec<String>> {
    let runner = runner()?;
    let mut args = Vec::new();
    for (label, entry, msl) in items {
        let file = dir.join(format!("{label}.metal"));
        std::fs::write(&file, msl).unwrap();
        args.push(format!("{}::{entry}", file.display()));
    }
    let mut failures = Vec::new();
    for chunk in args.chunks(40) {
        let out = Command::new(&runner).args(chunk).output().expect("the runner starts");
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        if text.contains("no-device") {
            eprintln!("skipped: no Metal device");
            return None;
        }
        failures.extend(text.lines().filter(|l| !l.starts_with("ok ")).map(str::to_string));
    }
    for (label, _, _) in items {
        let _ = std::fs::remove_file(dir.join(format!("{label}.metal")));
    }
    Some(failures)
}

fn request(name: &str, vertex: &str, fragment: &str, combos: &[(&str, &str)], textures: Vec<TextureRecord>) -> wm_shader::ValidRequest {
    ShaderRequest {
        shader_name: name.into(),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: vertex.into() },
            Stage { kind: StageKind::Fragment, source: fragment.into() },
        ],
        combos: combos.iter().map(|(n, v)| Combo { name: (*n).into(), value: (*v).into() }).collect(),
        textures,
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap()
}

fn texture(slot: u8) -> TextureRecord {
    let mut t = TextureRecord::new(slot);
    t.enabled = true;
    t.components.compo1 = true;
    t.components.compo2 = true;
    t.components.compo3 = true;
    t.components.compo4 = true;
    t
}

const VERTEX: &str = "attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord;
void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }";

/// A small set of synthetic programs that between them use every kind of resource, interface
/// and helper the translation emits.
fn programs() -> Vec<(&'static str, wm_shader::ValidRequest)> {
    vec![
        ("quad", request("quad", VERTEX, "varying vec2 v_TexCoord; uniform sampler2D g_Texture0; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Alpha; }", &[], vec![texture(0)])),
        (
            "members",
            request("members", VERTEX, "varying vec2 v_TexCoord; uniform float pre; uniform vec3 b; uniform mat3 m; uniform vec4 ring[2]; uniform float bands[8]; uniform uint offs[3]; uniform ivec3 iv[2]; uniform mat4x3 bones[2]; uniform bool flag; uniform bvec3 bv; uniform vec2 post;\nvoid main() { gl_FragColor = vec4(pre + b.x + m[1].y + ring[1].x + bands[7] + float(offs[2]) + float(iv[1].z) + bones[1][0].x + (flag ? 1.0 : 0.0) + (bv.y ? 1.0 : 0.0) + post.x); }", &[], vec![]),
        ),
        (
            "interface",
            request(
                "interface",
                "attribute vec3 a_Position; attribute vec4 a_Color; varying vec4 v_Wide; varying vec2 v_Taps[3]; varying float v_Spare;\nvoid main() { a_Color.a = 1.0; v_Wide = a_Color; v_Taps[0] = a_Position.xy; v_Taps[1] = a_Position.yz; v_Taps[2] = a_Position.zx; v_Spare = 2.0; gl_Position = vec4(a_Position, float(gl_VertexID)); }",
                "varying vec2 v_Wide; varying vec2 v_Taps[3]; varying vec3 v_FragmentOnly;\nvoid main() { gl_FragColor = vec4(v_Wide + v_Taps[0] + v_Taps[2], v_FragmentOnly.xy); }",
                &[],
                vec![],
            ),
        ),
        (
            "inverse",
            request("inverse", VERTEX, "varying vec2 v_TexCoord; uniform vec4 g_A; uniform mat3 g_M3; uniform mat4 g_M4;\nvoid main() { mat2 m2 = mat2(g_A.x, g_A.y, g_A.z, g_A.w); gl_FragColor = vec4(inverse(m2)[0].x + inverse(g_M3)[1].y + inverse(g_M4)[2].z); }", &[], vec![]),
        ),
        (
            "globals",
            request("globals", VERTEX, "uniform float u_Near; uniform float u_Far;\nfloat depthSpan() { return u_Far - u_Near; }\nconst float RANGE = depthSpan();\nconst float STEP = RANGE / 8.0;\nfloat gain = u_Near * 3.0;\nvoid main() { gl_FragColor = vec4(STEP + gain); }", &[], vec![]),
        ),
        (
            "planes",
            request("planes", VERTEX, "varying vec2 v_TexCoord; uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }", &[], {
                let mut t = texture(0);
                t.video_planes = wm_shader::VideoPlanes::Nv12Biplanar;
                vec![t]
            }),
        ),
        (
            "sampling in a branch",
            request("branch", VERTEX, "varying vec2 v_TexCoord; uniform sampler2D g_Texture0;\nvoid main() { vec4 c = vec4(0.0); if (v_TexCoord.x > 0.5) { c = texSample2D(g_Texture0, v_TexCoord); } gl_FragColor = c; }", &[], vec![texture(0)]),
        ),
    ]
}

/// Builds a render pipeline state from the two stages of `program` with the system's Metal device
/// (tests/probes/render_pipeline.swift). `Err` carries the runner's words; `None` when it cannot run here.
fn pipeline_state(dir: &Path, name: &str, program: &CompiledProgram) -> Option<Result<(), String>> {
    static BUILT: OnceLock<Option<PathBuf>> = OnceLock::new();
    let runner = BUILT
        .get_or_init(|| {
            let dir = scratch("pipeline_runner");
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes/render_pipeline.swift");
            let binary = dir.join("render_pipeline");
            match Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output() {
                Ok(o) if o.status.success() => Some(binary),
                _ => {
                    eprintln!("skipped: swiftc could not build the pipeline runner");
                    None
                }
            }
        })
        .clone()?;
    let mut parts = Vec::new();
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        let stage = program.stage(kind)?;
        let file = dir.join(format!("{name}-{}.metal", kind.name()));
        std::fs::write(&file, &stage.payload.msl_source).unwrap();
        parts.push(format!("{}::{}", file.display(), stage.payload.entry_point));
    }
    let formats: Vec<String> = program
        .reflection
        .vertex_inputs
        .iter()
        .map(|i| match i.format.name().as_str() {
            "r32_sfloat" => "float",
            "r32g32_sfloat" => "float2",
            "r32g32b32_sfloat" => "float3",
            _ => "float4",
        })
        .map(str::to_string)
        .collect();
    let out = Command::new(&runner).args(&parts).args(&formats).output().expect("the runner starts");
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    for part in &parts {
        let _ = std::fs::remove_file(part.split("::").next().unwrap());
    }
    if text.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    Some(if text.trim() == "ok" { Ok(()) } else { Err(text) })
}

/// Amendment d R66 (5): the stage pairs the budget lets through are accepted by real pipeline creation.
#[test]
fn programs_near_the_inter_stage_budget_build_a_render_pipeline_state() {
    if !metal_available() {
        return;
    }
    let both = |declarations: &str, writes: &str, reads: &str| {
        request(
            "budget",
            &format!("attribute vec3 a_Position; attribute vec2 a_Coord;\n{declarations}\nvoid main() {{ gl_Position = vec4(a_Position, 1.0);\n{writes} }}"),
            &format!("{declarations}\nvoid main() {{ vec4 c = vec4(0.0);\n{reads} gl_FragColor = c; }}"),
            &[],
            vec![],
        )
    };
    let cases: Vec<(&str, String, String, String)> = vec![
        // 49 vec2 and a vec4: 102 components, locations up to 49.
        (
            "ring",
            "varying vec2 v_Ring[49];\nvarying vec4 v_Main;".into(),
            format!("{} v_Main = vec4(a_Coord, 0.5, 1.0);", (0..49).map(|i| format!("v_Ring[{i}] = a_Coord * {i}.0;")).collect::<String>()),
            "c = v_Main + vec4(v_Ring[0], v_Ring[48]);".into(),
        ),
        // 31 vec4: exactly 124 components.
        (
            "thirty_one",
            (0..31).map(|i| format!("varying vec4 v_{i};")).collect::<Vec<_>>().join("\n"),
            (0..31).map(|i| format!("v_{i} = vec4(a_Coord, {i}.0, 1.0);")).collect::<String>(),
            (0..31).map(|i| format!("c += v_{i};")).collect::<String>(),
        ),
        // 62 vec2: 124 components.
        (
            "sixty_two",
            "varying vec2 v_Ring[62];".into(),
            (0..62).map(|i| format!("v_Ring[{i}] = a_Coord * {i}.0;")).collect::<String>(),
            "c.xy += v_Ring[0] + v_Ring[61];".into(),
        ),
    ];
    let dir = scratch("pipeline_state");
    for (name, declarations, writes, reads) in cases {
        let program = compile(&both(&declarations, &writes, &reads), &NoIncludes).unwrap_or_else(|e| panic!("{name}: {e}"));
        let Some(result) = pipeline_state(&dir, name, &program) else { return };
        assert!(result.is_ok(), "{name}: the Metal device refused the pipeline: {}", result.unwrap_err());
    }
}

fn items(name: &str, program: &CompiledProgram) -> Vec<(String, String, String)> {
    program
        .stages
        .iter()
        .map(|s| (format!("{name}-{}", s.kind.name()).replace(' ', "_"), s.payload.entry_point.clone(), s.payload.msl_source.clone()))
        .collect()
}

#[test]
fn the_runner_reports_what_the_compiler_refuses() {
    if !metal_available() {
        return;
    }
    let good = "#include <metal_stdlib>\nvertex float4 ok_entry(uint v [[vertex_id]]) { return float4(float(v)); }\n".to_string();
    let broken = "#include <metal_stdlib>\nvertex float4 bad_entry(uint v [[vertex_id]]) { return float4(undeclared_name); }\n".to_string();
    let items = vec![
        ("good".to_string(), "ok_entry".to_string(), good.clone()),
        ("broken".to_string(), "bad_entry".to_string(), broken),
        ("wrong_entry".to_string(), "missing".to_string(), good),
    ];
    let Some(failures) = metal_compile(&scratch("runner_check"), &items) else { return };
    assert_eq!(failures.len(), 2, "{failures:?}");
    assert!(failures.iter().any(|f| f.contains("broken") && f.contains("undeclared_name")), "{failures:?}");
    assert!(failures.iter().any(|f| f.contains("wrong_entry") && f.contains("missing")), "{failures:?}");
}

#[test]
fn the_msl_of_synthetic_programs_compiles_with_the_system_metal_compiler() {
    if !metal_available() {
        return;
    }
    let mut all = Vec::new();
    for (name, request) in programs() {
        let program = compile(&request, &NoIncludes).unwrap_or_else(|e| panic!("{name}: {e}"));
        all.extend(items(name, &program));
    }
    let Some(failures) = metal_compile(&scratch("synthetic"), &all) else { return };
    assert!(failures.is_empty(), "the Metal compiler refused generated text:\n{}", failures.join("\n"));
}

#[test]
fn the_msl_of_lit_programs_compiles_with_the_system_metal_compiler() {
    if !metal_available() {
        return;
    }
    let includes = MemorySource::new().with(
        "stubs.h",
        "vec3 PointSegmentDelta(vec3 p, vec3 a, vec3 b) { return a - p; }
vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lc, float r, float e, vec3 st, vec3 br, float ro, float me, float sh) { return lc * r + L * e; }
vec3 ComputePBRLightShadowInfinite(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lc, vec3 st, vec3 br, float ro, float me, float sh) { return lc * N + L; }
",
    );
    let fragment = "#include \"stubs.h\"\nvarying vec3 v_World;\n#require LightingV1\nvoid main() { gl_FragColor = vec4(PerformLighting_V1(v_World, vec3(1.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0), vec3(0.04), vec3(0.04), 0.5, 0.0), 1.0); }";
    let vertex = "attribute vec3 a_Position; varying vec3 v_World;\nvoid main() { v_World = a_Position; gl_Position = vec4(a_Position, 1.0); }";
    let lit = request("lit", vertex, fragment, &[("LIGHTING", "1"), ("LIGHTS_POINT", "2"), ("LIGHTS_SPOT", "3"), ("LIGHTS_TUBE", "1"), ("LIGHTS_DIRECTIONAL", "2")], vec![]);
    let program = compile(&lit, &includes).unwrap();
    let Some(failures) = metal_compile(&scratch("lit"), &items("lit", &program)) else { return };
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn the_msl_of_shipped_programs_compiles_with_the_system_metal_compiler() {
    if !metal_available() || std::env::var_os("WM_SHADER_METAL_COMPILE_CORPUS").is_none() {
        eprintln!("skipped: set WM_SHADER_METAL_COMPILE_CORPUS=1 as well to compile the shipped corpus");
        return;
    }
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let includes = |path: &str| -> Result<String, wm_shader::include::IncludeError> {
        std::fs::read_to_string(root.join(path)).map_err(|_| wm_shader::include::IncludeError { path: path.into(), kind: wm_shader::include::IncludeErrorKind::NotFound })
    };
    let dir = scratch("corpus");
    let mut names: Vec<String> = std::fs::read_dir(&root)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|e| e.path().extension().is_some_and(|x| x == "frag").then(|| e.path().file_stem().unwrap().to_string_lossy().to_string()))
        .collect();
    names.sort();
    // The combo sets the engine's scenes give: plain, lit and fogged, skinned and reflective.
    let sets: [(&str, Vec<(&str, &str)>); 3] = [
        ("plain", vec![]),
        ("lit", vec![("LIGHTING", "1"), ("LIGHTS_POINT", "2"), ("LIGHTS_SPOT", "1"), ("LIGHTS_TUBE", "1"), ("LIGHTS_DIRECTIONAL", "1"), ("FOG", "1"), ("FOG_COMPUTED", "1"), ("FOG_DIST", "1"), ("FOG_HEIGHT", "1")]),
        ("skinned", vec![("SKINNING", "1"), ("MORPHING", "1"), ("BONECOUNT", "4"), ("REFLECTION", "1"), ("NORMALMAP", "1"), ("BLENDMODE", "9"), ("HDR", "1")]),
    ];
    let (mut compiled, mut skipped, mut all) = (0, 0, Vec::new());
    for (set, extra) in &sets {
        for name in &names {
            let (Ok(v), Ok(f)) = (std::fs::read_to_string(root.join(format!("{name}.vert"))), std::fs::read_to_string(root.join(format!("{name}.frag")))) else { continue };
            let mut combos: Vec<(&str, &str)> = vec![("TEX8FORMAT", "8"), ("BLENDROWCOUNT", "4")];
            combos.extend(extra.iter().copied());
            let textures = (0..13u8).map(texture).collect();
            let Ok(program) = compile(&request(name, &v, &f, &combos, textures), &includes) else {
                skipped += 1;
                continue;
            };
            compiled += 1;
            all.extend(items(&format!("{set}-{name}"), &program));
        }
    }
    let Some(failed) = metal_compile(&dir, &all) else { return };
    eprintln!("shipped programs: {compiled} translated ({skipped} not translated by the layer), {} stages offered, {} refused by the Metal compiler", all.len(), failed.len());
    for f in &failed {
        eprintln!("  {f}");
    }
    assert!(failed.is_empty(), "{}", failed.join("\n"));
}

fn shaders_root() -> Option<PathBuf> {
    let root = match std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT") {
        Some(dir) => PathBuf::from(dir).join("shaders"),
        None => PathBuf::from(std::env::var_os("HOME")?).join("Library/Application Support/WallpaperMachine/SceneAssets/shaders"),
    };
    root.is_dir().then_some(root)
}

/// The same for the workshop shaders unpacked under `artifacts/p5/workshop-shaders/<id>/shaders/`
/// (third-party test input, never committed), under the plain combo set.
#[test]
fn the_msl_of_workshop_programs_compiles_with_the_system_metal_compiler() {
    if !metal_available() || std::env::var_os("WM_SHADER_METAL_COMPILE_CORPUS").is_none() {
        eprintln!("skipped: set WM_SHADER_METAL_COMPILE_CORPUS=1 as well to compile the workshop corpus");
        return;
    }
    let (Some(stock), workshop) = (shaders_root(), PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../artifacts/p5/workshop-shaders")) else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    if !workshop.is_dir() {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders");
        return;
    }
    let mut ids: Vec<_> = std::fs::read_dir(&workshop).unwrap().filter_map(Result::ok).collect();
    ids.sort_by_key(|e| e.file_name());
    let mut seen = std::collections::HashSet::new();
    let (mut compiled, mut skipped, mut all) = (0, 0, Vec::new());
    for entry in ids {
        let own = entry.path().join("shaders");
        let includes = |path: &str| -> Result<String, wm_shader::include::IncludeError> {
            std::fs::read_to_string(own.join(path))
                .or_else(|_| std::fs::read_to_string(stock.join(path)))
                .map_err(|_| wm_shader::include::IncludeError { path: path.into(), kind: wm_shader::include::IncludeErrorKind::NotFound })
        };
        let mut names = Vec::new();
        collect_fragments(&own, &mut names);
        names.sort();
        for frag in names {
            let name = frag.file_stem().unwrap().to_string_lossy().to_string();
            let (Ok(v), Ok(f)) = (std::fs::read_to_string(frag.with_extension("vert")), std::fs::read_to_string(&frag)) else { continue };
            if !seen.insert((v.clone(), f.clone())) {
                continue;
            }
            let combos: [(&str, &str); 2] = [("TEX8FORMAT", "8"), ("BLENDROWCOUNT", "4")];
            let textures = (0..13u8).map(texture).collect();
            let Ok(program) = compile(&request(&name, &v, &f, &combos, textures), &includes) else {
                skipped += 1;
                continue;
            };
            compiled += 1;
            all.extend(items(&format!("{}-{name}", entry.file_name().to_string_lossy()), &program));
        }
    }
    let Some(failed) = metal_compile(&scratch("workshop"), &all) else { return };
    eprintln!("workshop programs: {compiled} translated ({skipped} not translated by the layer), {} stages offered, {} refused by the Metal compiler", all.len(), failed.len());
    for f in failed.iter().take(20) {
        eprintln!("  {f}");
    }
    assert!(failed.is_empty(), "{}", failed.iter().take(20).cloned().collect::<Vec<_>>().join("\n"));
}

/// Amendment d R66 and c1 R107 on the workshop effects they came from: `textoutline7x7` (a 49-element
/// varying, locations to 49) and `frame_builder` (a suffix on a declared varying) build real render
/// pipeline states. Skips with a message when the unpacked workshop shaders are absent.
#[test]
fn the_workshop_effects_the_amendments_name_build_a_render_pipeline_state() {
    if !metal_available() {
        return;
    }
    let (Some(stock), workshop) = (shaders_root(), PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../artifacts/p5/workshop-shaders")) else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    if !workshop.is_dir() {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders");
        return;
    }
    let mut ids: Vec<_> = std::fs::read_dir(&workshop).unwrap().filter_map(Result::ok).collect();
    ids.sort_by_key(|e| e.file_name());
    let dir = scratch("amendment_effects");
    let mut built = Vec::new();
    for entry in ids {
        let own = entry.path().join("shaders");
        let includes = |path: &str| -> Result<String, wm_shader::include::IncludeError> {
            std::fs::read_to_string(own.join(path))
                .or_else(|_| std::fs::read_to_string(stock.join(path)))
                .map_err(|_| wm_shader::include::IncludeError { path: path.into(), kind: wm_shader::include::IncludeErrorKind::NotFound })
        };
        let mut names = Vec::new();
        collect_fragments(&own, &mut names);
        for frag in names.into_iter().filter(|f| f.file_stem().is_some_and(|n| n == "textoutline7x7" || n == "frame_builder")) {
            let name = frag.file_stem().unwrap().to_string_lossy().to_string();
            let (Ok(v), Ok(f)) = (std::fs::read_to_string(frag.with_extension("vert")), std::fs::read_to_string(&frag)) else { continue };
            let textures = (0..13u8).map(texture).collect();
            let program = compile(&request(&name, &v, &f, &[("TEX8FORMAT", "8"), ("BLENDROWCOUNT", "4")], textures), &includes).unwrap_or_else(|e| panic!("{name}: {e}"));
            let Some(result) = pipeline_state(&dir, &format!("{}-{name}", entry.file_name().to_string_lossy()), &program) else { return };
            assert!(result.is_ok(), "{name}: the Metal device refused the pipeline: {}", result.unwrap_err());
            built.push(name);
        }
    }
    eprintln!("render pipeline states built for {built:?}");
    if built.is_empty() {
        eprintln!("skipped: neither effect is among the unpacked workshop shaders");
    }
}

fn collect_fragments(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.is_dir() {
            collect_fragments(&path, out);
        } else if path.extension().is_some_and(|x| x == "frag") {
            out.push(path);
        }
    }
}
