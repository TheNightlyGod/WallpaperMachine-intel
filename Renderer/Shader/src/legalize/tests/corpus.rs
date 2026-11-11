// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The interface and resource part over Wallpaper Engine's shipped shaders, and over workshop
//! shaders unpacked under `artifacts/p5/workshop-shaders/<id>/shaders/` (third-party test
//! input, never committed). Each test skips with a printed reason when its input is absent.

use std::collections::BTreeMap;
use std::fs;

use crate::dialect::tests::corpus::{
    Layered, cause, combo_sets, pairs, present_textures, shader_files, shaders_root, workshop_root,
};
use crate::dialect::tests::support::compile_glsl;
use crate::legalize::{ProgramInput, legalize};
use crate::prepare::prepare_program;
use crate::request::{ShaderRequest, Stage, StageKind};

struct Sweep {
    ok: usize,
    failures: BTreeMap<String, Vec<String>>,
}

fn sweep(files: &[(String, StageKind, String)], includes: &Layered, skip: impl Fn(&str) -> bool) -> Sweep {
    sweep_with_planes(files, includes, skip, &[])
}

fn sweep_with_planes(files: &[(String, StageKind, String)], includes: &Layered, skip: impl Fn(&str) -> bool, planes: &[u8]) -> Sweep {
    let mut s = Sweep { ok: 0, failures: BTreeMap::new() };
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
            let text_of = |kind: StageKind| prepared.stages.iter().find(|st| st.kind == kind).map(|st| st.evaluated.clone()).unwrap_or_default();
            let (v, f) = (text_of(StageKind::Vertex), text_of(StageKind::Fragment));
            let trivial = |t: &str| {
                let code: String = t.lines().filter(|l| !l.trim_start().starts_with('#')).collect::<Vec<_>>().join(" ");
                code.split_whitespace().collect::<Vec<_>>().join(" ") == "void main() { }"
            };
            if trivial(&v) && trivial(&f) {
                continue;
            }
            let label = format!("{name} ({set_name})");
            let program = match legalize(&ProgramInput::program(&v, &f).with_planes(planes)) {
                Ok(p) => p,
                Err(e) => {
                    s.failures.entry(format!("legalize: {}", cause(&e.message()))).or_default().push(label);
                    continue;
                }
            };
            let mut all_ok = true;
            for stage in [program.vertex.as_ref().unwrap(), program.fragment.as_ref().unwrap()] {
                // A missing half of a pair is a stub `main`; it is legalized but not compiled.
                if trivial(if stage.kind == StageKind::Vertex { &v } else { &f }) {
                    continue;
                }
                if let Err(e) = compile_glsl(stage.kind, &stage.text) {
                    all_ok = false;
                    if std::env::var("LEGALIZE_SHOW").is_ok_and(|v| label.contains(&v)) {
                        eprintln!("=== {label} {}\n{e}\n", stage.kind.name());
                    }
                    s.failures.entry(format!("naga {}: {}", stage.kind.name(), cause(&e))).or_default().push(label.clone());
                }
            }
            if all_ok {
                s.ok += 1;
            }
        }
    }
    s
}

fn report(title: &str, s: &Sweep) {
    let failed: usize = s.failures.values().map(Vec::len).sum();
    eprintln!("{title}: {} programs legalized and compiled, {failed} failed", s.ok);
    for (cause, labels) in &s.failures {
        eprintln!("  [{}] {cause}\n      e.g. {}", labels.len(), labels.iter().take(3).cloned().collect::<Vec<_>>().join(", "));
    }
}

#[test]
fn shipped_programs_legalize_and_compile_through_naga() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let files = shader_files(&root);
    let includes = Layered { dirs: vec![root.clone()] };
    let s = sweep(&files, &includes, |n| n.starts_with("HLSL/"));
    report("shipped programs", &s);
    // One shipped file cannot be translated by anyone: the shadow-caster vertex stage of the
    // foliage model reads `g_Texture1Texel`, which no shipped file declares (it is the only use
    // of the name in the tree). The sweep expects exactly that failure and no other.
    const KNOWN: [&str; 1] = ["naga vertex: glsl parse: Unknown variable: g_Texture1Texel"];
    for (cause, labels) in &s.failures {
        assert!(KNOWN.iter().any(|k| cause.starts_with(k)), "a shipped program fails: {cause}: {labels:?}");
        assert!(labels.iter().all(|l| l.starts_with("shadowcasterfoliage4 ")), "{labels:?}");
    }
    assert!(s.ok >= 164, "{} programs legalized and compiled", s.ok);
}

#[test]
fn workshop_programs_legalize_and_compile_through_naga() {
    let Some(stock) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let Some(workshop) = workshop_root() else {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders (unpack scene.pkg copies there)");
        return;
    };
    let mut total = Sweep { ok: 0, failures: BTreeMap::new() };
    let mut seen = std::collections::HashSet::new();
    let mut dirs: Vec<_> = fs::read_dir(&workshop).unwrap().filter_map(Result::ok).collect();
    dirs.sort_by_key(|e| e.file_name());
    for entry in dirs {
        let own = entry.path().join("shaders");
        let mut files = shader_files(&own);
        files.retain(|(name, kind, text)| seen.insert((name.clone(), *kind == StageKind::Vertex, text.clone())));
        let includes = Layered { dirs: vec![own.clone(), stock.clone()] };
        let s = sweep(&files, &includes, |_| false);
        total.ok += s.ok;
        for (cause, labels) in s.failures {
            let id = entry.file_name().to_string_lossy().to_string();
            total.failures.entry(cause).or_default().extend(labels.into_iter().map(|l| format!("{id}/{l}")));
        }
    }
    report("workshop programs", &total);
    // What still fails does so for reasons that are not this part's: an undeclared varying and a
    // `#if` the preprocessor refuses (a varying past location 31 and a member-access suffix on a
    // declared name compile since amendments 1).
    const KNOWN: [&str; 2] = ["Unknown variable: v_TexCoordOpacity", "#if expression is unsupported"];
    for cause in total.failures.keys() {
        assert!(KNOWN.iter().any(|k| cause.contains(k)), "a new kind of failure: {cause}");
    }
    assert!(total.ok > 800, "{} workshop programs legalized and compiled", total.ok);
}

/// Random edits of real shaders (a token dropped, doubled, swapped or replaced) must legalize
/// or be refused with an error, never panic.
#[test]
fn mutated_shipped_programs_never_panic_the_legalizer() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let includes = Layered { dirs: vec![root.clone()] };
    let files = shader_files(&root);
    let mut programs: Vec<(String, String)> = Vec::new();
    for (name, vertex, fragment) in pairs(&files) {
        if name.starts_with("HLSL/") {
            continue;
        }
        let request = ShaderRequest {
            shader_name: name.clone(),
            stages: vec![Stage { kind: StageKind::Vertex, source: vertex }, Stage { kind: StageKind::Fragment, source: fragment }],
            textures: present_textures(),
            ..ShaderRequest::default()
        }
        .validate()
        .unwrap();
        if let Ok(p) = prepare_program(&request, &includes) {
            let text_of = |kind: StageKind| p.stages.iter().find(|s| s.kind == kind).map(|s| s.evaluated.clone()).unwrap_or_default();
            programs.push((text_of(StageKind::Vertex), text_of(StageKind::Fragment)));
        }
    }
    assert!(programs.len() > 50);
    let mut state: u64 = 0x2545_f491_4f6c_dd1d;
    let mut next = move || {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (state >> 33) as usize
    };
    let words = ["vec3", "float", "(", ")", ";", "*", "%", "!", "uniform", "varying", "[", "]", "{", "}", "sampler2D", "g_Texture0", "in", "out", "layout", "3", "0.5", "texSample2D", "gl_FragColor", ".xy"];
    let iterations: usize = std::env::var("WM_SHADER_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(600);
    let (mut ok, mut refused) = (0, 0);
    for _ in 0..iterations {
        let (v, f) = &programs[next() % programs.len()];
        let pick_vertex = next() % 2 == 0;
        let text = if pick_vertex { v } else { f };
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
        let input = if pick_vertex { ProgramInput::program(&mutated, f) } else { ProgramInput::program(v, &mutated) };
        match legalize(&input) {
            Ok(p) => {
                ok += 1;
                assert!(p.vertex.unwrap().text.starts_with("#version 450"));
            }
            Err(_) => refused += 1,
        }
    }
    eprintln!("mutated programs: {ok} legalized, {refused} refused");
}

/// Every shipped program with slot 0 or 1 flagged as an NV12 video: it either compiles with the
/// plane helper or is refused because a use of the texture cannot be reproduced; nothing else.
#[test]
fn shipped_programs_with_a_video_plane_compile_or_are_refused_by_name() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let files = shader_files(&root);
    let includes = Layered { dirs: vec![root.clone()] };
    for slots in [[0u8], [1u8]] {
        let s = sweep_with_planes(&files, &includes, |n| n.starts_with("HLSL/"), &slots);
        report(&format!("shipped programs with slot {} as video planes", slots[0]), &s);
        for (cause, labels) in &s.failures {
            let known = cause.contains("cannot be sampled as planes") || cause.contains("Unknown variable: g_Texture1Texel");
            assert!(known, "slot {}: {cause}: {labels:?}", slots[0]);
        }
        assert!(s.ok > 100, "{} programs", s.ok);
    }
}
