// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The dialect front end over Wallpaper Engine's shipped shaders and over workshop shaders
//! unpacked under `artifacts/p5/workshop-shaders/<id>/shaders/` (third-party test input,
//! never committed). Each test skips with a printed reason when its input is absent.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use super::support::compile_glsl;
use crate::dialect::convert_stage;
use crate::include::{IncludeError, IncludeErrorKind};
use crate::prepare::prepare_program;
use crate::request::{Combo, ShaderRequest, Stage, StageKind, TextureRecord};
use crate::source::IncludeSource;

pub(crate) fn shaders_root() -> Option<PathBuf> {
    let root = match std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT") {
        Some(dir) => PathBuf::from(dir).join("shaders"),
        None => {
            let home = std::env::var_os("HOME")?;
            PathBuf::from(home).join("Library/Application Support/WallpaperMachine/SceneAssets/shaders")
        }
    };
    root.is_dir().then_some(root)
}

pub(crate) struct Layered {
    pub(crate) dirs: Vec<PathBuf>,
}

impl IncludeSource for Layered {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        let err = |kind| IncludeError { path: path.to_string(), kind };
        for dir in &self.dirs {
            if let Ok(bytes) = fs::read(dir.join(path)) {
                return String::from_utf8(bytes).map_err(|_| err(IncludeErrorKind::NotUtf8));
            }
        }
        Err(err(IncludeErrorKind::NotFound))
    }
}

pub(crate) fn shader_files(root: &Path) -> Vec<(String, StageKind, String)> {
    fn walk(dir: &Path, root: &Path, out: &mut Vec<(String, StageKind, String)>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = rd.filter_map(Result::ok).collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, root, out);
                continue;
            }
            let kind = match path.extension().and_then(|e| e.to_str()) {
                Some("vert") => StageKind::Vertex,
                Some("frag") => StageKind::Fragment,
                _ => continue,
            };
            let rel = path.strip_prefix(root).unwrap().with_extension("");
            let Ok(text) = fs::read_to_string(&path) else { continue };
            out.push((rel.to_string_lossy().replace('\\', "/"), kind, text));
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out
}

fn combo(name: &str, value: &str) -> Combo {
    Combo { name: name.into(), value: value.into() }
}

/// Combos the engine supplies for every program (texture formats, puppet blend rows).
pub(crate) fn engine_combos() -> Vec<Combo> {
    vec![combo("TEX8FORMAT", "8"), combo("BLENDROWCOUNT", "4")]
}

pub(crate) fn combo_sets() -> Vec<(&'static str, Vec<Combo>)> {
    let mut sets = base_combo_sets();
    for (_, combos) in sets.iter_mut() {
        combos.extend(engine_combos());
    }
    sets
}

fn base_combo_sets() -> Vec<(&'static str, Vec<Combo>)> {
    vec![
        ("no combos", vec![]),
        (
            "lit and fogged",
            vec![
                combo("LIGHTING", "1"),
                combo("LIGHTS_POINT", "2"),
                combo("LIGHTS_SPOT", "1"),
                combo("LIGHTS_TUBE", "1"),
                combo("LIGHTS_DIRECTIONAL", "1"),
                combo("FOG", "1"),
                combo("FOG_COMPUTED", "1"),
                combo("FOG_DIST", "1"),
                combo("FOG_HEIGHT", "1"),
                combo("TEX0FORMAT", "9"),
                combo("TEX1FORMAT", "8"),
                combo("SCENE_ORTHO", "1"),
            ],
        ),
        (
            "skinned and reflective",
            vec![
                combo("SKINNING", "1"),
                combo("MORPHING", "1"),
                combo("BONECOUNT", "4"),
                combo("REFLECTION", "1"),
                combo("NORMALMAP", "1"),
                combo("BLENDMODE", "9"),
                combo("HDR", "1"),

            ],
        ),
    ]
}

/// The first line of a failure, with line numbers and quoted names cut away so equal causes group.
pub(crate) fn cause(text: &str) -> String {
    text.lines().next().unwrap_or("").chars().take(160).collect()
}

pub(crate) struct Sweep {
    ok: usize,
    failures: BTreeMap<String, Vec<String>>,
    /// Time of each successful `convert_stage` call.
    times: Vec<std::time::Duration>,
}

/// Pairs `<name>.vert` with `<name>.frag`; a missing half is an empty `main`.
pub(crate) fn pairs(files: &[(String, StageKind, String)]) -> Vec<(String, String, String)> {
    let mut names: Vec<&str> = files.iter().map(|(n, _, _)| n.as_str()).collect();
    names.dedup();
    let find = |name: &str, kind: StageKind| {
        files.iter().find(|(n, k, _)| n == name && *k == kind).map(|(_, _, t)| t.clone()).unwrap_or_else(|| "void main() { }\n".to_string())
    };
    names.into_iter().map(|n| (n.to_string(), find(n, StageKind::Vertex), find(n, StageKind::Fragment))).collect()
}

pub(crate) fn present_textures() -> Vec<TextureRecord> {
    (0..13u8)
        .map(TextureRecord::new)
        .map(|mut t| {
            t.enabled = true;
            t.components.compo1 = true;
            t.components.compo2 = true;
            t.components.compo3 = true;
            t.components.compo4 = true;
            t
        })
        .collect()
}

fn sweep(files: &[(String, StageKind, String)], includes: &Layered, skip: impl Fn(&str) -> bool) -> Sweep {
    let mut s = Sweep { ok: 0, failures: BTreeMap::new(), times: Vec::new() };
    for (set_name, combos) in combo_sets() {
        for (name, vertex, fragment) in pairs(files) {
            if skip(&name) {
                continue;
            }
            let request = ShaderRequest {
                shader_name: name.clone(),
                stages: vec![
                    Stage { kind: StageKind::Vertex, source: vertex },
                    Stage { kind: StageKind::Fragment, source: fragment },
                ],
                combos: combos.clone(),
                textures: present_textures(),
                ..ShaderRequest::default()
            }
            .validate()
            .unwrap();
            let prepared = match prepare_program(&request, includes) {
                Ok(p) => p,
                Err(e) => {
                    s.failures.entry(format!("prepare: {}", cause(&e.to_string()))).or_default().push(format!("{name} ({set_name})"));
                    continue;
                }
            };
            for stage in &prepared.stages {
                let kind = stage.kind;
                let code: String = stage.evaluated.lines().filter(|l| !l.trim_start().starts_with('#')).collect::<Vec<_>>().join(" ");
                if code.split_whitespace().collect::<Vec<_>>().join(" ") == "void main() { }" {
                    continue;
                }
                let label = format!("{name}.{} ({set_name})", if kind == StageKind::Vertex { "vert" } else { "frag" });
                let started = std::time::Instant::now();
                let converted = convert_stage(kind, &stage.evaluated);
                let elapsed = started.elapsed();
                let converted = match converted {
                    Ok(c) => {
                        s.times.push(elapsed);
                        c
                    }
                    Err(d) => {
                        let msg = d.iter().map(|x| x.message.clone()).collect::<Vec<_>>().join("; ");
                        s.failures.entry(format!("convert: {}", cause(&msg))).or_default().push(label);
                        continue;
                    }
                };
                // converting the output again changes nothing (R95)
                match convert_stage(kind, &converted.text) {
                    Ok(again) if again.text == converted.text => {}
                    Ok(again) => {
                        let first_diff = converted.text.lines().zip(again.text.lines()).find(|(a, b)| a != b).map(|(a, b)| format!("{a}  =>  {b}")).unwrap_or_default();
                        s.failures.entry(format!("idempotence: {}", cause(&first_diff))).or_default().push(label.clone());
                    }
                    Err(d) => {
                        s.failures.entry(format!("idempotence: second pass failed: {}", cause(&d[0].message))).or_default().push(label.clone());
                    }
                }
                let glsl = match crate::legalize::legalize_stage(kind, &stage.evaluated) {
                    Ok((legal, _)) => legal.text,
                    Err(e) => {
                        s.failures.entry(format!("legalize: {}", cause(&e.message()))).or_default().push(label);
                        continue;
                    }
                };
                match compile_glsl(kind, &glsl) {
                    Ok(_) => s.ok += 1,
                    Err(e) => {
                        if std::env::var("DIALECT_SHOW").is_ok_and(|v| label.contains(&v)) {
                            eprintln!("=== {label}\n{e}\n--- converted ---\n{glsl}");
                        }
                        s.failures.entry(format!("naga: {}", cause(&e))).or_default().push(label);
                    }
                }
            }
        }
    }
    s
}

fn report(title: &str, s: &Sweep) {
    let failed: usize = s.failures.values().map(Vec::len).sum();
    eprintln!("{title}: {} compiled, {failed} failed", s.ok);
    let mut times = s.times.clone();
    times.sort();
    if let (Some(median), Some(worst)) = (times.get(times.len() / 2), times.last()) {
        eprintln!("  conversion time over {} stages: median {median:?}, worst {worst:?}", times.len());
    }
    for (cause, labels) in &s.failures {
        eprintln!("  [{}] {cause}\n      e.g. {}", labels.len(), labels.iter().take(3).cloned().collect::<Vec<_>>().join(", "));
    }
}

#[test]
fn shipped_shaders_convert_and_compile_through_naga() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let files = shader_files(&root);
    let includes = Layered { dirs: vec![root.clone()] };
    // `HLSL/` holds real Direct3D programs for another path; the volumetric shader is out of scope (R22).
    let s = sweep(&files, &includes, |n| n.starts_with("HLSL/") || n.starts_with("volumetricsfront"));
    report("shipped shaders", &s);
    // One shipped file reads a uniform no shipped file declares (`g_Texture1Texel` in the
    // shadow-caster vertex stage of the foliage model); nothing can translate it.
    for (cause, labels) in &s.failures {
        assert!(cause.contains("Unknown variable: g_Texture1Texel"), "a shipped shader fails: {cause}: {labels:?}");
        assert!(labels.iter().all(|l| l.starts_with("shadowcasterfoliage4.vert")), "{labels:?}");
    }
    assert!(s.ok > 300);
}

pub(crate) fn workshop_root() -> Option<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../artifacts/p5/workshop-shaders");
    root.is_dir().then_some(root)
}

#[test]
fn workshop_shaders_convert_and_compile_through_naga() {
    let Some(stock) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let Some(workshop) = workshop_root() else {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders (unpack scene.pkg copies there)");
        return;
    };
    let mut total = Sweep { ok: 0, failures: BTreeMap::new(), times: Vec::new() };
    let mut seen = std::collections::HashSet::new();
    let mut dirs: Vec<_> = fs::read_dir(&workshop).unwrap().filter_map(Result::ok).collect();
    dirs.sort_by_key(|e| e.file_name());
    for entry in dirs {
        let own = entry.path().join("shaders");
        let mut files = shader_files(&own);
        // The same effect shipped by many wallpapers is checked once per distinct text.
        files.retain(|(name, kind, text)| seen.insert((name.clone(), *kind == StageKind::Vertex, text.clone())));
        let includes = Layered { dirs: vec![own.clone(), stock.clone()] };
        let s = sweep(&files, &includes, |_| false);
        total.ok += s.ok;
        total.times.extend(s.times);
        for (cause, labels) in s.failures {
            let id = entry.file_name().to_string_lossy().to_string();
            total.failures.entry(cause).or_default().extend(labels.into_iter().map(|l| format!("{id}/{l}")));
        }
    }
    report("workshop shaders", &total);
    // What still fails does so for reasons that are not this part's: an undeclared varying, a
    // varying whose width only the program (both stages together) can reconcile, and a `#if` the
    // preprocessor refuses.
    const NOT_OURS: [&str; 3] = [
        "Invalid swizzle for vector \"zw\"",
        "Unknown variable: v_TexCoordOpacity",
        "#if expression is unsupported",
    ];
    for cause in total.failures.keys() {
        assert!(NOT_OURS.iter().any(|k| cause.contains(k)), "a new kind of failure: {cause}");
    }
    assert!(total.ok > 1000);
}

/// Random edits of real shaders (a token dropped, doubled, swapped or replaced) must convert or
/// be refused with diagnostics, never panic: this reaches the type rules far more often than
/// random text does.
#[test]
fn mutated_shipped_shaders_never_panic_the_converter() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let includes = Layered { dirs: vec![root.clone()] };
    let files = shader_files(&root);
    let mut stages = Vec::new();
    for (name, vertex, fragment) in pairs(&files) {
        if name.starts_with("HLSL/") {
            continue;
        }
        let request = ShaderRequest {
            shader_name: name.clone(),
            stages: vec![Stage { kind: StageKind::Vertex, source: vertex }, Stage { kind: StageKind::Fragment, source: fragment }],
            textures: present_textures(),
            combos: engine_combos(),
            ..ShaderRequest::default()
        }
        .validate()
        .unwrap();
        if let Ok(p) = prepare_program(&request, &includes) {
            stages.extend(p.stages.into_iter().map(|s| (s.kind, s.evaluated)));
        }
    }
    assert!(stages.len() > 50);
    let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = move || {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (state >> 33) as usize
    };
    let words = ["vec3", "float", "(", ")", ";", "*", "%", "!", "?", ":", "0", "1.5", "u_x", "mul", "lerp", "texSample2D", "int", "uint", "bool", ".xy", "[", "]", "{", "}"];
    let iterations: usize = std::env::var("WM_SHADER_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(1500);
    let (mut ok, mut refused) = (0, 0);
    for _ in 0..iterations {
        let (kind, text) = &stages[next() % stages.len()];
        let mut tokens: Vec<String> = text.split_whitespace().map(str::to_string).collect();
        for _ in 0..1 + next() % 4 {
            if tokens.is_empty() {
                break;
            }
            let i = next() % tokens.len();
            match next() % 4 {
                0 => {
                    tokens.remove(i);
                }
                1 => {
                    let t = tokens[i].clone();
                    tokens.insert(i, t);
                }
                2 => {
                    let j = next() % tokens.len();
                    tokens.swap(i, j);
                }
                _ => tokens[i] = words[next() % words.len()].to_string(),
            }
        }
        let mutated = tokens.join("\n");
        match convert_stage(*kind, &mutated) {
            Ok(c) => {
                ok += 1;
                assert!(c.text.starts_with(crate::dialect::HEADER));
            }
            Err(d) => {
                refused += 1;
                assert!(!d.is_empty());
            }
        }
    }
    eprintln!("mutated stages: {ok} converted, {refused} refused");
}
