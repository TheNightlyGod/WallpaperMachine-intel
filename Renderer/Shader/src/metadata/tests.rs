// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Behaviour tests for metadata extraction (spec section 8, items 48 to 55, 59 and 61).

use super::*;
use crate::items::{BraceMode, scan_items};
use crate::lexer::lex;
use crate::request::{TextureComponents, TextureFormat, VideoPlanes};

fn extract_with(src: &str, textures: &[TextureRecord], mode: ExtractMode) -> Result<Metadata, RequestError> {
    let tokens = lex(src);
    let items = scan_items(&tokens, src, BraceMode::Conditional).unwrap_or_else(|e| panic!("{e:?}"));
    extract(&items, src, textures, mode)
}

fn run(src: &str) -> Metadata {
    extract_with(src, &[], ExtractMode::Full).unwrap_or_else(|e| panic!("{e}"))
}

fn err(src: &str) -> String {
    extract_with(src, &[], ExtractMode::Full).unwrap_err().to_string()
}

fn combos(m: &Metadata) -> Vec<(&str, &str)> {
    m.combos.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect()
}

fn tex(slot: u8, present: bool, enabled: bool, flags: [bool; 4]) -> TextureRecord {
    TextureRecord {
        slot,
        present,
        enabled,
        format: TextureFormat::Unknown,
        components: TextureComponents { compo1: flags[0], compo2: flags[1], compo3: flags[2], compo4: flags[3] },
        video_planes: VideoPlanes::None,
    }
}

#[test]
fn combo_annotations_record_their_defaults_before_main() {
    let m = run("// [COMBO] {\"material\":\"ui_quality\",\"combo\":\"QUALITY\",\"type\":\"options\",\"default\":2,\"options\":{\"low\":1,\"high\":2}}\n// [COMBO] {\"combo\":\"FOG\",\"default\":1}\nvoid main() {}\n// [COMBO] {\"combo\":\"LATE\",\"default\":1}\n");
    assert_eq!(combos(&m), [("QUALITY", "2"), ("FOG", "1")]);
    // `material` on a combo is a label, never an alias.
    assert!(m.aliases.is_empty());
}

#[test]
fn combo_default_text_is_used_as_written() {
    for (default, expected) in [
        ("", "0"),
        (",\"default\":7", "7"),
        (",\"default\":0.50", "0.50"),
        (",\"default\":-4", "-4"),
        (",\"default\":\"3\"", "0"),
        (",\"default\":true", "0"),
        (",\"default\":false", "0"),
        (",\"default\":null", "0"),
        (",\"default\":[1]", "0"),
        (",\"default\":1e2", "1e2"),
    ] {
        let m = run(&format!("// [COMBO] {{\"combo\":\"C\"{default}}}\n"));
        assert_eq!(combos(&m), [("C", expected)], "{default}");
    }
}

#[test]
fn a_malformed_number_fails_the_shader_everywhere_a_default_is_read() {
    let msg = "invalid shader request: metadata number is invalid";
    assert_eq!(err("// [COMBO] {\"combo\":\"C\",\"default\":1.2.3}\n"), msg);
    assert_eq!(err("uniform float g_A; // {\"default\":1.2.3}\n"), msg);
    assert_eq!(err("uniform sampler2D g_Texture0; // {\"default\":1.2.3}\n"), msg);
    assert_eq!(err("uniform float g_A; // {\"default\":-}\n"), msg);
    // A string default is validated only for scalar and vector uniforms.
    assert_eq!(err("uniform float g_A; // {\"default\":\"util/white\"}\n"), msg);
    assert_eq!(err("uniform float g_A; // {\"default\":\"3 y\"}\n"), msg);
    let m = run("uniform sampler2D g_Texture0; // {\"default\":\"util/white\"}\n// [COMBO] {\"combo\":\"C\",\"default\":\"util/white\"}\n");
    assert_eq!(m.default_textures.len(), 1);
    assert_eq!(combos(&m), [("C", "0")]);
}

#[test]
fn bad_combo_annotations_fail_or_are_ignored_as_specified() {
    assert_eq!(run("// [COMBO] {\"default\":1}\n").combos.len(), 0);
    assert!(err("// [COMBO] {\"combo\":\"1ABC\"}\n").contains("combo name `1ABC` is not an ASCII identifier"));
    assert!(err("// [COMBO] {\"combo\":\"A-B\"}\n").contains("not an ASCII identifier"));
    assert!(err("// [COMBO] {\"combo\":\"\"}\n").contains("combo name is empty"));
    assert_eq!(run("// [COMBO_DISABLED] {\"combo\":\"A\",\"default\":1}\n// [PASS] shadow fx\n").combos.len(), 0);
    assert_eq!(run("// [COMBO] LEVEL=2 high\n").combos.len(), 0);
    assert_eq!(run("// [COMBO]\n").combos.len(), 0);
    assert_eq!(run("// [COMBO] {\"combo\":\"A\",\"default\":1} note\n").combos.len(), 0);
    // A malformed annotation does not abort the rest.
    let m = run("// [COMBO] {\"combo\":\"A\",\"default\":\"x}\n// [COMBO] {\"combo\":\"B\",\"default\":2}\n");
    assert_eq!(combos(&m), [("B", "2")]);
}

#[test]
fn combos_merge_inside_a_stage_keeping_position_and_taking_the_later_spelling() {
    let m = run("// [COMBO] {\"combo\":\"Haze\",\"default\":1}\n// [COMBO] {\"combo\":\"RIM\",\"default\":4}\n// [COMBO] {\"combo\":\"Bloom\",\"default\":0}\n// [COMBO] {\"combo\":\"haze\",\"default\":3}\n// [COMBO] {\"combo\":\"rim\",\"default\":2}\n");
    assert_eq!(combos(&m), [("haze", "3"), ("rim", "2"), ("Bloom", "0")]);
}

#[test]
fn combos_inside_inactive_branches_before_main_are_recorded() {
    let m = run("#if 0\n// [COMBO] {\"combo\":\"HIDDEN\",\"default\":1}\n#endif\nvoid main() {}\n");
    assert_eq!(combos(&m), [("HIDDEN", "1")]);
}

#[test]
fn uniforms_get_aliases_and_typed_defaults() {
    let m = run(r#"
uniform float g_Brightness; // {"material":"brightness","label":"x","default":0.75}
uniform vec3 g_Tint; // {"material":"color","type":"color","default":"1 0.5 0"}
uniform vec3 g_Comma; // {"default":"8, 16, 24"}
uniform vec2 g_Pair; // {"default":"3 7"}
uniform bool g_On; // {"default":false}
uniform float g_Flag; // {"default":true}
uniform mat4 g_M; // {"default":"1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"}
uniform float g_Six; // {"default":"1 2 3 4 5 6"}
uniform float g_Nothing; // {"default":null}
uniform float g_Arr; // {"default":[1,2]}
uniform float g_Plain; // {"material":"plain"}
"#);
    let defaults: Vec<(&str, &UniformValue)> = m.default_uniforms.iter().map(|d| (d.name.as_str(), &d.value)).collect();
    assert_eq!(defaults.len(), 8);
    assert_eq!(*defaults[0].1, UniformValue::Number(0.75));
    assert_eq!(*defaults[1].1, UniformValue::Vec3([1.0, 0.5, 0.0]));
    assert_eq!(*defaults[2].1, UniformValue::Vec3([8.0, 16.0, 24.0]));
    assert_eq!(*defaults[3].1, UniformValue::Vec2([3.0, 7.0]));
    assert_eq!(*defaults[4].1, UniformValue::Bool(false));
    assert_eq!(*defaults[5].1, UniformValue::Bool(true));
    assert!(matches!(defaults[6].1, UniformValue::Matrix4(_)));
    assert_eq!(*defaults[7].1, UniformValue::Text("1 2 3 4 5 6".into()));
    let aliases: Vec<(&str, &str)> = m.aliases.iter().map(|a| (a.material.as_str(), a.uniform.as_str())).collect();
    assert_eq!(aliases, [("brightness", "g_Brightness"), ("color", "g_Tint"), ("plain", "g_Plain")]);
}

#[test]
fn aliases_keep_case_and_duplicates_and_an_empty_material_fails() {
    let m = run("uniform float a; // {\"material\":\"Fancy\"}\nuniform float b; // {\"material\":\"Fancy\"}\nuniform sampler2D g_Texture1; // {\"material\":\"mask\"}\n");
    let aliases: Vec<(&str, &str)> = m.aliases.iter().map(|a| (a.material.as_str(), a.uniform.as_str())).collect();
    assert_eq!(aliases, [("Fancy", "a"), ("Fancy", "b"), ("mask", "g_Texture1")]);
    assert!(err("uniform float a; // {\"material\":\"\"}\n").contains("material alias is empty"));
}

#[test]
fn a_combo_key_on_a_plain_uniform_is_recorded_as_one() {
    let m = run("uniform float g_Mix; // {\"combo\":\"MIXING\",\"default\":0.5}\n");
    assert_eq!(combos(&m), [("MIXING", "1")]);
    assert!(err("uniform float g_Mix; // {\"combo\":\"1X\"}\n").contains("not an ASCII identifier"));
}

#[test]
fn only_uniform_declarations_on_the_same_line_are_annotated() {
    // Same line: yes. Next line: no. A block comment between: yes.
    let m = run("uniform float a; // {\"default\":1}\nuniform float b;\n// {\"default\":2}\nuniform float c; /* x */ // {\"default\":3}\n");
    let names: Vec<&str> = m.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(names, ["a", "c"]);
    // A block comment spanning a line break between them: the break disqualifies it.
    let m = run("uniform float a; /* x\ny */ // {\"default\":1}\n");
    assert!(m.default_uniforms.is_empty());
    // Not uniform qualifiers.
    let m = run("varying float a; // {\"default\":1}\nattribute float b; // {\"default\":1}\nfloat c; // {\"default\":1}\nconst float d = 1.0; // {\"default\":1}\nin float e; // {\"default\":1}\n");
    assert!(m.default_uniforms.is_empty());
    // Qualifier combinations.
    let m = run("layout(binding = 3) uniform highp float a; // {\"default\":1}\nuniform lowp vec2 b; // {\"default\":\"1 2\"}\n");
    assert_eq!(m.default_uniforms.len(), 2);
    // A list of names annotates only the first.
    let m = run("uniform float a, b; // {\"default\":1}\n");
    assert_eq!(m.default_uniforms.len(), 1);
    assert_eq!(m.default_uniforms[0].name, "a");
}

#[test]
fn nothing_after_void_main_is_considered() {
    let m = run("uniform float a; // {\"default\":1}\nvoid main() { }\nuniform float b; // {\"default\":2}\n// [COMBO] {\"combo\":\"Z\"}\n");
    assert_eq!(m.default_uniforms.len(), 1);
    assert!(m.combos.is_empty());
    // A non-void main or a function called main with other return type does not stop the walk.
    let m = run("int main() { return 0; }\nuniform float b; // {\"default\":2}\n");
    assert_eq!(m.default_uniforms.len(), 1);
}

#[test]
fn the_awaiting_declaration_rules() {
    // A struct or non-uniform declaration replaces it; an annotation consumes it.
    let m = run("uniform float a;\nstruct S { float x; }; // {\"default\":1}\n");
    assert!(m.default_uniforms.is_empty());
    // A second annotation cannot reuse the first one's declaration.
    let m = run("uniform float a; // {\"default\":1}\n// {\"default\":2}\n");
    assert_eq!(m.default_uniforms.len(), 1);
    // The annotation consumes the declaration even when unused: the next declaration is separate.
    let m = run("float k; // {\"default\":1}\nuniform float a; // {\"default\":2}\n");
    assert_eq!(m.default_uniforms.len(), 1);
    // Directive, function and stray-token items clear the association.
    for between in ["#define X 1\n", "float f() { return 1.0; }\n", "} \n"] {
        let m = run(&format!("uniform float a;\n{between}// {{\"default\":1}}\n"));
        assert!(m.default_uniforms.is_empty(), "{between}");
        // On the same line as the clearing item the annotation has nothing to attach to either.
    }
    // A [PASS] or [COMBO_DISABLED] line leaves the awaiting declaration alone but annotates nothing itself.
    let m = run("uniform float a; // [PASS] x\n// [COMBO_DISABLED] {\"combo\":\"Q\"}\n");
    assert!(m.default_uniforms.is_empty() && m.combos.is_empty());
    let m = run("uniform float a; // [COMBO] {\"combo\":\"Q\",\"default\":1}\n// {\"default\":5}\n");
    // The combo annotation is on the same line as `a` but does not touch the awaiting declaration; the JSON
    // annotation on the next line is not on the declaration's line.
    assert_eq!(combos(&m), [("Q", "1")]);
    assert!(m.default_uniforms.is_empty());
}

#[test]
fn block_commented_code_contributes_nothing_but_code_after_the_comment_on_its_last_line_does() {
    let m = run("/* off:\n   uniform vec3 g_Gone; // {\"default\":\"1 1 1\"} */ uniform float g_Live; // {\"default\":6}\n");
    let names: Vec<&str> = m.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(names, ["g_Live"]);
    assert_eq!(m.default_uniforms[0].value, UniformValue::Number(6.0));
}

#[test]
fn texture_slot_detection() {
    for (name, slot) in [("g_Texture0", Some(0)), ("g_Texture12", Some(12)), ("g_Texture31", Some(31)), ("g_Texture007", Some(7))] {
        assert_eq!(texture_slot(name).unwrap(), slot, "{name}");
    }
    for name in ["g_Texture0Resolution", "g_Texture", "g_TextureA", "g_Texture999", "g_Texture-1", "u_Texture1"] {
        assert_eq!(texture_slot(name).unwrap(), None, "{name}");
    }
    assert_eq!(texture_slot("g_Texture40").unwrap_err(), RequestError::TextureSlotOutOfRange(40));
    assert!(err("uniform sampler2D g_Texture40; // {\"default\":\"util/white\"}\n").contains("texture slot 40 is out of range"));
    // Companions are ordinary uniforms, not slots.
    let m = run("uniform vec2 g_Texture0Resolution; // {\"default\":\"1 1\"}\n");
    assert_eq!(m.default_uniforms.len(), 1);
    assert!(m.default_textures.is_empty());
}

#[test]
fn texture_defaults() {
    let m = run("uniform sampler2D g_Texture0; // {\"default\":\"util/white\"}\nuniform sampler2D g_Texture1; // {\"default\":\"\"}\nuniform sampler2D g_Texture2; // {\"default\":3}\nuniform sampler2D g_Texture6; // {\"default\":\"_rt_shadowAtlas\",\"hidden\":true}\n");
    let t: Vec<(u8, &str)> = m.default_textures.iter().map(|t| (t.slot, t.path.as_str())).collect();
    assert_eq!(t, [(0, "util/white"), (6, "_rt_shadowAtlas")]);
    assert!(m.default_uniforms.is_empty());
}

const COMPONENTS: &str = "uniform sampler2D g_Texture2; // {\"combo\":\"PBRMASKS\",\"components\":[{\"combo\":\"METALLIC_MAP\"},{\"combo\":\"ROUGHNESS_MAP\"},{\"x\":1},{\"combo\":\"AMBIENT_MAP\"}]}\n";

#[test]
fn texture_combos_for_each_kind_of_fact() {
    let all = [true; 4];
    let with = |t: &[TextureRecord]| combos(&extract_with(COMPONENTS, t, ExtractMode::Full).unwrap()).into_iter().map(|(a, b)| (a.to_string(), b.to_string())).collect::<Vec<_>>();
    // No fact, or absent: 0 and nothing else.
    assert_eq!(with(&[]), [("PBRMASKS".to_string(), "0".to_string())]);
    assert_eq!(with(&[tex(2, false, true, all)]), [("PBRMASKS".to_string(), "0".to_string())]);
    // A fact for another slot does not count.
    assert_eq!(with(&[tex(3, true, true, all)]), [("PBRMASKS".to_string(), "0".to_string())]);
    // Present and enabled: 1 and the component combos whose flag is on and whose entry has a combo.
    let enabled = with(&[tex(2, true, true, [true, false, true, true])]);
    assert_eq!(enabled, [("PBRMASKS", "1"), ("METALLIC_MAP", "1"), ("AMBIENT_MAP", "1")].map(|(a, b)| (a.to_string(), b.to_string())));
    // Components that are off record nothing (no 0 entry).
    let some = with(&[tex(2, true, true, [false, true, false, false])]);
    assert_eq!(some, [("PBRMASKS", "1"), ("ROUGHNESS_MAP", "1")].map(|(a, b)| (a.to_string(), b.to_string())));
    // Present but disabled: one texture combo, no components.
    assert_eq!(with(&[tex(2, true, false, all)]), [("PBRMASKS".to_string(), "1".to_string())]);
}

#[test]
fn components_with_fewer_than_four_entries() {
    let src = "uniform sampler2D g_Texture0; // {\"combo\":\"T\",\"components\":[{\"combo\":\"R\"}]}\n";
    let m = extract_with(src, &[tex(0, true, true, [true, true, true, true])], ExtractMode::Full).unwrap();
    assert_eq!(combos(&m), [("T", "1"), ("R", "1")]);
}

#[test]
fn a_bad_component_combo_name_fails() {
    let src = "uniform sampler2D g_Texture0; // {\"components\":[{\"combo\":\"1R\"}]}\n";
    assert!(extract_with(src, &[tex(0, true, true, [true; 4])], ExtractMode::Full).is_err());
    // Off components are never looked at.
    assert!(extract_with(src, &[tex(0, true, true, [false; 4])], ExtractMode::Full).is_ok());
}

#[test]
fn the_texture_switch_scan_skips_combo_annotations_and_plain_uniforms() {
    let src = "// [COMBO] {\"combo\":\"Q\",\"default\":2}\nuniform float g_A; // {\"material\":\"a\",\"default\":1,\"combo\":\"PLAIN\"}\nuniform sampler2D g_Texture1; // {\"material\":\"mask\",\"combo\":\"MASKED\",\"default\":\"util/white\"}\n";
    let full = extract_with(src, &[tex(1, true, true, [false; 4])], ExtractMode::Full).unwrap();
    assert_eq!(combos(&full), [("Q", "2"), ("PLAIN", "1"), ("MASKED", "1")]);
    let scan = extract_with(src, &[tex(1, true, true, [false; 4])], ExtractMode::TextureSwitchOnly).unwrap();
    assert_eq!(combos(&scan), [("MASKED", "1")]);
    // Aliases and default textures are produced for the texture uniform too.
    assert_eq!(scan.aliases.len(), 1);
    assert_eq!(scan.aliases[0].uniform, "g_Texture1");
    assert_eq!(scan.default_textures.len(), 1);
    assert!(scan.default_uniforms.is_empty());
}

#[test]
fn defaults_are_never_deduplicated_inside_a_stage() {
    let m = run("uniform float a; // {\"default\":1}\nuniform float a; // {\"default\":2}\nuniform sampler2D g_Texture0; // {\"default\":\"x\"}\nuniform sampler2D g_Texture0; // {\"default\":\"x\"}\n");
    assert_eq!(m.default_uniforms.len(), 2);
    assert_eq!(m.default_textures.len(), 2);
}

#[test]
fn per_arm_header_functions_do_not_hide_uniforms_around_them() {
    let src = "uniform float g_Pre; // {\"default\":1}\n#ifdef HDR\nvec3 grade(vec3 l) {\n#else\nvec3 grade(vec3 l, float ev) {\n#endif\n    return l;\n}\nuniform float g_Mid; // {\"default\":2}\n#ifdef HDR\nvec3 other(vec3 l) {\n#else\nvec3 other(vec3 l, float ev) {\n#endif\n    return l;\n}\nuniform float g_Post; // {\"default\":3}\nvoid main() { }\nuniform float g_After; // {\"default\":4}\n";
    let m = run(src);
    let names: Vec<&str> = m.default_uniforms.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(names, ["g_Pre", "g_Mid", "g_Post"]);
}

#[test]
fn a_struct_member_or_nested_declaration_does_not_take_a_trailing_annotation() {
    let m = run("struct S {\n float a; // {\"default\":1}\n};\n");
    assert!(m.default_uniforms.is_empty());
}

#[test]
fn merge_combo_replaces_in_place() {
    let mut l = Vec::new();
    merge_combo(&mut l, "A", "1");
    merge_combo(&mut l, "B", "2");
    merge_combo(&mut l, "a", "3");
    assert_eq!(l.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect::<Vec<_>>(), [("a", "3"), ("B", "2")]);
}

#[test]
fn json_annotations_with_trailing_text_or_no_object_are_ignored() {
    let m = run("uniform float a; // {\"default\":1} note\nuniform float b; // {\"default\":2\nuniform float c; // {\"default\":\"open}\n");
    assert!(m.default_uniforms.is_empty());
    // Prose that looks like an annotation is harmless.
    let m = run("uniform float a; // { this is prose }\n");
    assert!(m.default_uniforms.is_empty());
}

// ---- amendment b R81: the scan tolerates a member-access suffix after a declared name ----

#[test]
fn annotations_after_a_suffixed_declaration_are_still_found() {
    let suffixed = "varying vec4 v_Haze.xy;\n// [COMBO] {\"combo\":\"AFTER\",\"default\":2}\nuniform sampler2D g_Texture1; // {\"material\":\"mask\",\"default\":\"util/white\"}\nuniform float g_Gain; // {\"material\":\"gain\",\"default\":0.5}\nvoid main() {}\n";
    let plain = suffixed.replace("v_Haze.xy", "v_Haze");
    let m = run(suffixed);
    assert_eq!(combos(&m), [("AFTER", "2")]);
    assert_eq!(m.default_textures.len(), 1);
    assert_eq!((m.default_textures[0].slot, m.default_textures[0].path.as_str()), (1, "util/white"));
    assert_eq!(m, run(&plain));
    // The texture-switch scan finds the default texture past the suffixed declaration too.
    let only = extract_with(suffixed, &[], ExtractMode::TextureSwitchOnly).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(only, extract_with(&plain, &[], ExtractMode::TextureSwitchOnly).unwrap());
    assert_eq!(only.default_textures.len(), 1);
}
