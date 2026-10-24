// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Orchestration of one program (spec D 4.1, tests 1 to 5): result shape, stage order, combo
//! defaults, metadata and determinism.

use std::sync::Arc;

use super::support::*;
use crate::diagnostic::Pass;
use crate::error::ErrorCategory;
use crate::request::StageKind;
use crate::source::MemorySource;

// ---- 1: result shape ----

#[test]
fn a_minimal_request_compiles_with_everything_present() {
    let p = ok(PASS_VERTEX, PASS_FRAGMENT);
    assert_eq!(p.name, "test/shader");
    assert_eq!(p.stages.len(), 2);
    assert_eq!((p.stages[0].kind, p.stages[1].kind), (StageKind::Vertex, StageKind::Fragment));
    for s in &p.stages {
        assert!(s.payload.msl_source.contains("#include <metal_stdlib>"), "{}", s.payload.msl_source);
        assert!(s.glsl.starts_with("#version 450\n"), "the legalized text is kept");
        assert_eq!(s.payload.kind, s.kind);
        assert!(!s.payload.entry_point.is_empty());
    }
    assert!(!p.cache_key.is_empty() && p.cache_key.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()), "{}", p.cache_key);
    // Metadata, reflection and diagnostics are always there, even when empty.
    assert!(p.metadata.combos.is_empty() && p.metadata.to_json().is_ok());
    assert!(p.reflection.to_json().starts_with("{\"descriptor_bindings\":"));
    assert!(!p.diagnostics.is_empty());
}

#[test]
fn the_legalizers_informational_diagnostics_survive_in_stage_order() {
    let p = ok(PASS_VERTEX, PASS_FRAGMENT);
    let codegen: Vec<_> = p.diagnostics.iter().filter(|d| d.pass == Some(Pass::Codegen)).collect();
    assert_eq!(codegen.len(), 2, "one per stage");
    assert_eq!((codegen[0].stage, codegen[1].stage), (Some(StageKind::Vertex), Some(StageKind::Fragment)));
    let reversed = Req::new(PASS_VERTEX, PASS_FRAGMENT).fragment_first().ok();
    let order: Vec<_> = reversed.diagnostics.iter().filter_map(|d| d.stage).collect();
    assert_eq!(order, [StageKind::Fragment, StageKind::Vertex], "diagnostics follow the request's stage order");
}

#[test]
fn reversing_the_stages_changes_only_the_order_of_the_result() {
    let f = "varying vec2 v_TexCoord; uniform float g_Alpha; uniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Alpha; }";
    let a = Req::new(PASS_VERTEX, f).ok();
    let b = Req::new(PASS_VERTEX, f).fragment_first().ok();
    assert_eq!((b.stages[0].kind, b.stages[1].kind), (StageKind::Fragment, StageKind::Vertex));
    for kind in [StageKind::Vertex, StageKind::Fragment] {
        assert_eq!(a.stage(kind), b.stage(kind), "{kind:?}: same text, same payload, same records");
    }
    assert_eq!(a.reflection, b.reflection);
    assert_eq!(a.metadata, b.metadata);
    assert_ne!(a.cache_key, b.cache_key, "the order of the output is part of the key");
}

// ---- 3: combos ----

const ANNOTATED: &str = "// [COMBO] {\"material\":\"mode\",\"combo\":\"MODE\",\"default\":2}\nvarying vec2 v_TexCoord;\nvoid main() {\n#if MODE == 2\n  gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);\n#elif MODE == 1\n  gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0);\n#else\n  gl_FragColor = vec4(0.0, 0.0, 1.0, 1.0);\n#endif\n}\n";

fn colour_of(p: &crate::pipeline::CompiledProgram) -> String {
    let f = glsl_of(p, StageKind::Fragment);
    f.lines().find(|l| l.contains("_we_FragColor =")).unwrap().trim().to_string()
}

#[test]
fn a_request_value_beats_an_annotation_default() {
    let default = Req::new(PASS_VERTEX, ANNOTATED).ok();
    assert!(colour_of(&default).contains("vec4(1.0, 0.0, 0.0, 1.0)"), "the default 2 applies");
    assert_eq!(default.combos.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect::<Vec<_>>(), [("MODE", "2")]);
    let request = Req::new(PASS_VERTEX, ANNOTATED).combo("MODE", "1").ok();
    assert!(colour_of(&request).contains("vec4(0.0, 1.0, 0.0, 1.0)"));
    // Names compare ASCII case-insensitively: a lower-case request wins and nothing is added.
    let lower = Req::new(PASS_VERTEX, ANNOTATED).combo("mode", "1").ok();
    assert!(colour_of(&lower).contains("vec4(0.0, 1.0, 0.0, 1.0)"));
    assert_eq!(lower.combos.len(), 1, "{:?}", lower.combos);
}

#[test]
fn added_defaults_reach_the_compiled_text_and_the_cache_key() {
    let a = Req::new(PASS_VERTEX, ANNOTATED).ok();
    let b = Req::new(PASS_VERTEX, ANNOTATED).combo("MODE", "2").ok();
    // The default 2 and an explicit 2 compile to the same text; the key tells which request it was.
    assert_eq!(a.stage(StageKind::Fragment).unwrap().glsl, b.stage(StageKind::Fragment).unwrap().glsl);
    assert_eq!(a.combos, b.combos);
    let c = Req::new(PASS_VERTEX, ANNOTATED).combo("MODE", "0").ok();
    assert_ne!(a.cache_key, c.cache_key);
    assert!(colour_of(&c).contains("vec4(0.0, 0.0, 1.0, 1.0)"));
}

#[test]
fn a_default_in_an_inactive_branch_is_not_added_but_is_reported() {
    let f = "#if FANCY\n// [COMBO] {\"combo\":\"SPARKLE\",\"default\":3}\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }\n";
    let p = Req::new(PASS_VERTEX, f).combo("FANCY", "0").ok();
    assert!(p.combos.iter().all(|c| c.name != "SPARKLE"), "{:?}", p.combos);
    assert!(p.metadata.combos.iter().any(|c| c.name == "SPARKLE"), "metadata is read from the conditional-preserving source");
    let on = Req::new(PASS_VERTEX, f).combo("FANCY", "1").ok();
    assert!(on.combos.iter().any(|c| c.name == "SPARKLE" && c.value == "3"));
}

#[test]
fn a_default_reachable_only_through_another_default_is_not_restored() {
    let f = "// [COMBO] {\"combo\":\"A\",\"default\":1}\n#if A\n// [COMBO] {\"combo\":\"B\",\"default\":1}\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }\n";
    let p = Req::new(PASS_VERTEX, f).ok();
    assert_eq!(p.combos.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["A"]);
    assert_eq!(p.metadata.combos.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["A", "B"]);
}

/// A sampler declared inside the very branch the combo it names controls, behind another
/// switch, as an included file would declare it.
const TEXTURE_SWITCH: &str = "varying vec2 v_TexCoord;\n#if SHARP\nvec4 tap(vec2 uv) { return vec4(0.5); }\n#elif DITHER\nuniform sampler2D g_Texture4; // {\"material\":\"noise\",\"combo\":\"DITHER\"}\nvec4 tap(vec2 uv) { return texSample2D(g_Texture4, uv); }\n#else\nvec4 tap(vec2 uv) { return vec4(0.25); }\n#endif\nvoid main() { gl_FragColor = tap(v_TexCoord); }\n";

fn declares_sampler(p: &crate::pipeline::CompiledProgram) -> bool {
    glsl_of(p, StageKind::Fragment).contains("g_Texture4")
}

#[test]
fn a_texture_switch_inside_the_branch_it_controls_follows_the_texture() {
    let base = || Req::new(PASS_VERTEX, TEXTURE_SWITCH).combo("SHARP", "0");
    let present = base().texture(texture(4)).ok();
    assert!(declares_sampler(&present));
    assert_eq!(present.combos.iter().find(|c| c.name == "DITHER").map(|c| c.value.as_str()), Some("1"));
    let mut absent_record = texture(4);
    absent_record.present = false;
    let absent = base().texture(absent_record).ok();
    assert!(!declares_sampler(&absent));
    assert_eq!(absent.combos.iter().find(|c| c.name == "DITHER").map(|c| c.value.as_str()), Some("0"));
    let none = base().ok();
    assert!(!declares_sampler(&none));
    // The request wins in both directions.
    let off = base().texture(texture(4)).combo("DITHER", "0").ok();
    assert!(!declares_sampler(&off));
    let mut absent_record = texture(4);
    absent_record.present = false;
    let on = base().texture(absent_record).combo("DITHER", "1").ok();
    assert!(declares_sampler(&on));
}

#[test]
fn a_texture_switch_found_in_an_include_works_and_a_missing_include_in_a_dead_branch_is_no_error() {
    let includes = MemorySource::new().with("noise.h", "uniform sampler2D g_Texture4; // {\"combo\":\"DITHER\"}\n");
    let f = "varying vec2 v_TexCoord;\n#include \"noise.h\"\n#if MISSING_FEATURE\n#include \"does_not_exist.h\"\n#endif\nvoid main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }\n";
    let p = Req::new(PASS_VERTEX, f).texture(texture(4)).compile_with(&includes).unwrap();
    assert!(p.combos.iter().any(|c| c.name == "DITHER" && c.value == "1"));
    assert!(glsl_of(&p, StageKind::Fragment).contains("g_Texture4"));
}

// ---- 4: metadata ----

#[test]
fn metadata_is_reported_from_inactive_branches_and_includes() {
    let includes = MemorySource::new().with(
        "extra.h",
        "// [COMBO] {\"material\":\"extra\",\"combo\":\"EXTRA\",\"default\":1}\nuniform float g_Extra; // {\"material\":\"extra amount\",\"default\":0.5}\n",
    );
    let f = "#include \"extra.h\"\n#if 0\nuniform sampler2D g_Texture1; // {\"default\":\"util/white\"}\n#endif\nuniform float g_Gain; // {\"material\":\"gain\",\"default\":2}\nvoid main() { gl_FragColor = vec4(g_Gain + g_Extra); }\n";
    let p = Req::new(PASS_VERTEX, f).compile_with(&includes).unwrap();
    assert!(p.metadata.combos.iter().any(|c| c.name == "EXTRA"));
    let aliases: Vec<&str> = p.metadata.aliases.iter().map(|a| a.uniform.as_str()).collect();
    assert!(aliases.contains(&"g_Extra") && aliases.contains(&"g_Gain"), "{aliases:?}");
    let defaults: Vec<&str> = p.metadata.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(defaults, ["g_Extra", "g_Gain"]);
    assert_eq!(p.metadata.default_textures.len(), 1, "a default texture in an inactive branch is still reported");
}

#[test]
fn a_missing_include_on_an_active_line_fails_naming_the_path() {
    let e = Req::new(PASS_VERTEX, "#include \"nope.h\"\nvoid main() {}\n").err();
    assert_eq!(e.category(), ErrorCategory::SourceRead, "{e}");
    assert!(e.to_string().contains("nope.h"), "{e}");
}

// ---- 5: determinism ----

#[test]
fn compiling_twice_gives_identical_programs() {
    let f = "varying vec2 v_TexCoord; uniform sampler2D g_Texture0; uniform vec4 g_Tint;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Tint; }";
    let req = Req::new(PASS_VERTEX, f).texture(texture(0)).combo("A", "1");
    let (a, b) = (req.ok(), req.ok());
    assert_eq!(a, b);
    for (x, y) in a.stages.iter().zip(&b.stages) {
        assert_eq!(x.payload.msl_source, y.payload.msl_source);
        assert_eq!(x.payload.bindings, y.payload.bindings);
    }
    assert_eq!(a.reflection.to_json(), b.reflection.to_json());
    assert_eq!(a.cache_key, b.cache_key);
}

#[test]
fn nothing_from_an_earlier_request_influences_a_later_one() {
    let f = "uniform sampler2D g_Texture0; varying vec2 v_TexCoord;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }";
    let alone = Req::new(PASS_VERTEX, f).ok();
    // Compile other, different programs in between (one of them failing).
    let _ = err("void main() { nope(); }", "void main() {}");
    let _ = Req::new(PASS_VERTEX, ANNOTATED).combo("MODE", "1").ok();
    assert_eq!(alone, Req::new(PASS_VERTEX, f).ok());
}

#[test]
fn compiling_the_same_request_on_several_threads_gives_identical_results() {
    let f = "varying vec2 v_TexCoord; uniform sampler2D g_Texture0; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Alpha; }";
    let expected = Arc::new(Req::new(PASS_VERTEX, f).texture(texture(0)).ok());
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let f = f.to_string();
            std::thread::spawn(move || Req::new(PASS_VERTEX, &f).texture(texture(0)).ok())
        })
        .collect();
    for h in handles {
        assert_eq!(h.join().expect("a worker finishes"), *expected);
    }
}

#[test]
fn a_stage_with_no_main_fails_naming_the_stage() {
    let e = err("attribute vec3 a_Position;\n", PASS_FRAGMENT);
    let text = e.to_string().to_lowercase();
    assert!(text.contains("vertex") && text.contains("entry point"), "{text}");
    let e = err(PASS_VERTEX, "");
    assert!(e.to_string().to_lowercase().contains("fragment"), "{e}");
}

#[test]
fn a_failing_stage_returns_no_program_and_names_the_shader() {
    let e = err(PASS_VERTEX, "void main() { gl_FragColor = vec4(undefined_name); }");
    let text = e.to_string();
    assert!(text.contains("undefined_name") && text.contains("test/shader") && text.contains("fragment"), "{text}");
}
