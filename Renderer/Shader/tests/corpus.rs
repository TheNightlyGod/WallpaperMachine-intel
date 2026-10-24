// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Runs the pipeline's front end over Wallpaper Engine's shipped shaders. The
// shaders are third-party test input, never committed; the tests skip with a
// printed reason when the asset folder is absent.

use std::fs;
use std::path::{Path, PathBuf};

use wm_shader::facts::Facts;
use wm_shader::include::{IncludeError, IncludeErrorKind};
use wm_shader::items::{BraceMode, scan_items};
use wm_shader::lexer::lex;
use wm_shader::prepare::prepare_program;
use wm_shader::preprocess::{Mode, preprocess_stage};
use wm_shader::response::UniformValue;
use wm_shader::source::IncludeSource;
use wm_shader::{Combo, ShaderRequest, Stage, StageKind, TextureRecord};

/// The shipped shader folder: `WALLPAPER_MACHINE_ASSETS_ROOT` (the folder that holds `shaders/`)
/// or the default application support location.
fn shaders_root() -> Option<PathBuf> {
    let root = match std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT") {
        Some(dir) => PathBuf::from(dir).join("shaders"),
        None => {
            let home = std::env::var_os("HOME")?;
            PathBuf::from(home).join("Library/Application Support/WallpaperMachine/SceneAssets/shaders")
        }
    };
    root.is_dir().then_some(root)
}

macro_rules! require_assets {
    () => {
        match shaders_root() {
            Some(root) => root,
            None => {
                eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
                return;
            }
        }
    };
}

struct DiskIncludes(PathBuf);

impl IncludeSource for DiskIncludes {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        let err = |kind| IncludeError { path: path.to_string(), kind };
        match fs::read(self.0.join(path)) {
            Ok(bytes) => String::from_utf8(bytes).map_err(|_| err(IncludeErrorKind::NotUtf8)),
            Err(_) => Err(err(IncludeErrorKind::NotFound)),
        }
    }
}

/// Every `.vert` and `.frag` below `root`, as (relative path without extension, kind, text).
fn shader_files(root: &Path) -> Vec<(String, StageKind, String)> {
    fn walk(dir: &Path, root: &Path, out: &mut Vec<(String, StageKind, String)>) {
        let mut entries: Vec<_> = fs::read_dir(dir).unwrap().filter_map(Result::ok).collect();
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

fn combo_sets() -> Vec<(&'static str, Vec<Combo>)> {
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

#[test]
fn every_shipped_stage_preprocesses_in_both_modes() {
    let root = require_assets!();
    let files = shader_files(&root);
    assert!(files.len() > 50, "found only {} shader files under {}", files.len(), root.display());
    let includes = DiskIncludes(root.clone());
    let mut failures = Vec::new();
    for (set_name, combos) in combo_sets() {
        for (name, kind, text) in &files {
            for mode in [Mode::Evaluated, Mode::MetadataPreserving] {
                if let Err(e) = preprocess_stage(*kind, text, &combos, &includes, mode) {
                    failures.push(format!("{name} ({set_name}, {mode:?}): {e}"));
                }
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    eprintln!("preprocessed {} stages x {} combo sets x 2 modes", files.len(), combo_sets().len());
}

#[test]
fn lit_shaders_expand_the_lighting_block() {
    let root = require_assets!();
    let includes = DiskIncludes(root.clone());
    let lights = vec![
        combo("LIGHTING", "1"),
        combo("LIGHTS_POINT", "2"),
        combo("LIGHTS_SPOT", "1"),
        combo("LIGHTS_TUBE", "1"),
        combo("LIGHTS_DIRECTIONAL", "1"),
    ];
    let mut checked = 0;
    for (name, kind, text) in shader_files(&root) {
        if !text.contains("#require LightingV1") && !text.contains("LightingV1") {
            continue;
        }
        let out = preprocess_stage(kind, &text, &lights, &includes, Mode::Evaluated).unwrap_or_else(|e| panic!("{name}: {e}"));
        // Only a stage whose `#require` is active gets the block.
        if text.contains("#require LightingV1") {
            let unlit = preprocess_stage(kind, &text, &[], &includes, Mode::Evaluated).unwrap();
            assert!(!unlit.text.contains("PerformLighting_V1(vec3 worldPos"), "{name}");
            if out.text.contains("PerformLighting_V1(vec3 worldPos") {
                assert!(out.text.contains("uniform vec4 g_LPoint_Color[2];"), "{name}");
                checked += 1;
            }
        }
    }
    assert!(checked > 0, "no stock stage requires the lighting block under the given combos");
}

/// Pairs `<name>.vert` with `<name>.frag`; a missing half is an empty `main`.
fn pairs(files: &[(String, StageKind, String)]) -> Vec<(String, String, String)> {
    let mut names: Vec<&str> = files.iter().map(|(n, _, _)| n.as_str()).collect();
    names.dedup();
    let find = |name: &str, kind: StageKind| {
        files.iter().find(|(n, k, _)| n == name && *k == kind).map(|(_, _, t)| t.clone()).unwrap_or_else(|| "void main() { }\n".to_string())
    };
    names.into_iter().map(|n| (n.to_string(), find(n, StageKind::Vertex), find(n, StageKind::Fragment))).collect()
}

fn request(name: &str, vertex: &str, fragment: &str, combos: &[Combo], textures: Vec<TextureRecord>) -> wm_shader::ValidRequest {
    ShaderRequest {
        shader_name: name.to_string(),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: vertex.to_string() },
            Stage { kind: StageKind::Fragment, source: fragment.to_string() },
        ],
        combos: combos.to_vec(),
        textures,
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap()
}

fn present_textures() -> Vec<TextureRecord> {
    (0..8u8).map(TextureRecord::new).map(|mut t| {
        t.enabled = true;
        t.components.compo1 = true;
        t.components.compo2 = true;
        t.components.compo3 = true;
        t.components.compo4 = true;
        t
    }).collect()
}

#[test]
fn every_shipped_stage_scans_in_both_shapes_and_yields_facts() {
    let root = require_assets!();
    let includes = DiskIncludes(root.clone());
    let files = shader_files(&root);
    let mut failures = Vec::new();
    let mut tokens_total = 0usize;
    let started = std::time::Instant::now();
    for (set_name, combos) in combo_sets() {
        for (name, kind, text) in &files {
            let view = match preprocess_stage(*kind, text, &combos, &includes, Mode::MetadataPreserving) {
                Ok(o) => o.text,
                Err(e) => {
                    failures.push(format!("{name} ({set_name}) view: {e}"));
                    continue;
                }
            };
            let tokens = lex(&view);
            if let Err(e) = scan_items(&tokens, &view, BraceMode::Conditional) {
                failures.push(format!("{name} ({set_name}) view scan: {e:?}"));
            }
            let evaluated = preprocess_stage(*kind, text, &combos, &includes, Mode::Evaluated).unwrap().text;
            let tokens = lex(&evaluated);
            tokens_total += tokens.len();
            match scan_items(&tokens, &evaluated, BraceMode::Compiled) {
                Ok(items) => {
                    // Items cover the stream exactly once.
                    let mut next = 0;
                    for item in &items {
                        assert_eq!(item.tokens.start, next, "{name}");
                        next = item.tokens.end;
                    }
                    assert_eq!(next, tokens.len(), "{name}");
                    let main = items.iter().filter_map(|i| i.function()).any(|f| f.name == "main" && f.return_type == "void");
                    // The `HLSL/` folder holds Direct3D fallback programs in real HLSL: no GLSL-style `main`.
                    if !main && !name.starts_with("HLSL/") {
                        failures.push(format!("{name} ({set_name}): no `void main` found"));
                    }
                }
                Err(e) => failures.push(format!("{name} ({set_name}) evaluated scan: {e:?}")),
            }
            let facts = Facts::analyze(&tokens);
            assert!(facts.summaries().count() > 0 || tokens.is_empty());
        }
    }
    eprintln!("lexed, scanned and analysed {tokens_total} tokens in {:?}", started.elapsed());
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

#[test]
fn every_shipped_program_prepares_with_and_without_textures() {
    let root = require_assets!();
    let includes = DiskIncludes(root.clone());
    let files = shader_files(&root);
    let programs = pairs(&files);
    assert!(programs.len() > 30);
    let mut failures = Vec::new();
    for (set_name, combos) in combo_sets() {
        for textures in [vec![], present_textures()] {
            for (name, vertex, fragment) in &programs {
                let r = request(name, vertex, fragment, &combos, textures.clone());
                if let Err(e) = prepare_program(&r, &includes) {
                    failures.push(format!("{name} ({set_name}, {} textures): {e}", textures.len()));
                }
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

fn program(root: &Path, name: &str, combos: &[Combo], textures: Vec<TextureRecord>) -> wm_shader::prepare::PreparedProgram {
    let read = |ext: &str| fs::read_to_string(root.join(format!("{name}.{ext}"))).unwrap_or_else(|_| "void main() { }\n".to_string());
    let r = request(name, &read("vert"), &read("frag"), combos, textures);
    prepare_program(&r, &DiskIncludes(root.to_path_buf())).unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[test]
fn annotations_of_stock_shaders_are_reported() {
    let root = require_assets!();
    let p = program(&root, "genericimage4", &[], vec![]);
    let fog = p.metadata.combos.iter().find(|c| c.name == "FOG").expect("FOG is reported");
    assert_eq!(fog.value, "1");
    let atlas = p.metadata.default_textures.iter().find(|t| t.slot == 6).expect("the shadow atlas default");
    assert_eq!(atlas.path, "_rt_shadowAtlas");
    // The request wins and the compiled text carries the default of the others.
    let p = program(&root, "genericimage4", &[combo("FOG", "0")], vec![]);
    assert!(p.compile_combos.iter().any(|c| c.name == "FOG" && c.value == "0"));
    let p = program(&root, "genericimage4", &[], vec![]);
    assert!(p.stages[1].evaluated.contains("#define FOG 1\n"), "the FOG default becomes a macro");

    let p = program(&root, "generic3", &[], vec![]);
    assert!(p.metadata.aliases.iter().any(|a| a.material == "brightness" && a.uniform == "g_Brightness"));
    let brightness = p.metadata.default_uniforms.iter().find(|d| d.name == "g_Brightness");
    assert!(matches!(brightness.map(|d| &d.value), Some(UniformValue::Number(_))));

    let p = program(&root, "foliage4", &[], vec![]);
    for name in ["LIGHTING", "FOG", "REFLECTION"] {
        assert!(p.metadata.combos.iter().any(|c| c.name == name), "{name}");
    }
    assert!(p.metadata.combos.iter().any(|c| c.name == "LIGHTING" && c.value == "1"));

    // An include below shader level carries an annotated uniform.
    for name in ["genericparticle", "genericropeparticle"] {
        let p = program(&root, name, &[], vec![]);
        let refract = p.metadata.default_uniforms.iter().find(|d| d.name == "g_RefractAmount").unwrap_or_else(|| panic!("{name}"));
        let UniformValue::Number(v) = refract.value else { panic!("{name}") };
        assert!((v - 0.05).abs() < 1e-6, "{name}");
        assert!(p.metadata.aliases.iter().any(|a| a.uniform == "g_RefractAmount"), "{name}");
    }
}

#[test]
fn stock_combo_defaults_follow_the_branches_that_are_active() {
    let root = require_assets!();
    // With the lighting default on (foliage4), the compiled text has the lighting block when the pass is lit.
    let combos = [combo("LIGHTS_POINT", "1")];
    let p = program(&root, "foliage4", &combos, vec![]);
    assert!(p.compile_combos.iter().any(|c| c.name == "LIGHTING"));
    assert!(p.stages[1].evaluated.contains("PerformLighting_V1(vec3 worldPos"));
    assert!(p.stages[1].evaluated.contains("uniform vec4 g_LPoint_Color[1];"));
}

#[test]
fn texture_derived_combos_of_a_stock_program_follow_the_texture_facts() {
    let root = require_assets!();
    let with = program(&root, "genericimage4", &[], present_textures());
    let without = program(&root, "genericimage4", &[], vec![]);
    let value = |p: &wm_shader::prepare::PreparedProgram, name: &str| p.metadata.combos.iter().find(|c| c.name == name).map(|c| c.value.clone());
    // `g_Texture1` carries a mask switch in the stock image shader.
    let masked = |p| value(p, "MASK");
    assert_eq!(masked(&without).as_deref().unwrap_or("0"), "0");
    if let Some(v) = masked(&with) {
        assert_eq!(v, "1");
    }
}

fn workshop_root() -> Option<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../artifacts/p5/workshop-shaders");
    root.is_dir().then_some(root)
}

/// Includes of a workshop shader: the wallpaper's own `shaders/` folder first, then the stock assets.
struct LayeredIncludes {
    own: PathBuf,
    stock: PathBuf,
}

impl IncludeSource for LayeredIncludes {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        let err = |kind| IncludeError { path: path.to_string(), kind };
        for dir in [&self.own, &self.stock] {
            if let Ok(bytes) = fs::read(dir.join(path)) {
                return String::from_utf8(bytes).map_err(|_| err(IncludeErrorKind::NotUtf8));
            }
        }
        Err(err(IncludeErrorKind::NotFound))
    }
}

#[test]
fn workshop_shaders_from_the_local_library_prepare_or_fail_cleanly() {
    let Some(stock) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let Some(workshop) = workshop_root() else {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders (unpack scene.pkg copies there)");
        return;
    };
    let mut ok = 0;
    let mut failures = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for entry in fs::read_dir(&workshop).unwrap().filter_map(Result::ok) {
        let own = entry.path().join("shaders");
        let files = shader_files(&own);
        let includes = LayeredIncludes { own: own.clone(), stock: stock.clone() };
        for (name, vertex, fragment) in pairs(&files) {
            // The same effect shipped by many wallpapers is checked once per distinct text.
            if !seen.insert((name.clone(), vertex.clone(), fragment.clone())) {
                continue;
            }
            for combos in [vec![], vec![combo("LIGHTING", "1"), combo("LIGHTS_POINT", "2"), combo("FOG", "1")]] {
                let r = request(&name, &vertex, &fragment, &combos, present_textures());
                match prepare_program(&r, &includes) {
                    Ok(_) => ok += 1,
                    Err(e) => failures.push(format!("{}/{name}: {e}", entry.file_name().to_string_lossy())),
                }
            }
        }
    }
    eprintln!("workshop programs prepared: {ok}, failed: {}", failures.len());
    // Failures are reported as plain-text errors, never crashes. Print them for review.
    for f in &failures {
        eprintln!("workshop failure: {}", f.lines().next().unwrap_or(""));
    }
    assert!(ok > 0);
}
