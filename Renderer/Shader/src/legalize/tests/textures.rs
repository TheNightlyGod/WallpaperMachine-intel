// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Texture splitting, sampling calls and the NV12 plane variant (spec C2 section 8, items
//! 15, 16, 31 and 36).

use super::support::*;
use crate::legalize::LegalizeError;
use crate::request::StageKind;

const PASS_V: &str = "attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_T;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_T = a_TexCoord; }";

fn frag_with(decl_and_body: &str) -> String {
    format!("uniform sampler2D g_Texture0; uniform sampler2D g_Texture1; varying vec2 v_T;\n{decl_and_body}")
}

#[test]
fn every_sampling_spelling_pairs_the_texture_with_its_sampler() {
    for call in ["texture(g_Texture0, v_T)", "texture2D(g_Texture0, v_T)", "tex2D(g_Texture0, v_T)", "texSample2D(g_Texture0, v_T)"] {
        let t = frag(&frag_with(&format!("void main() {{ gl_FragColor = {call}; }}")));
        assert!(t.contains("texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_T)"), "{call}: {t}");
    }
    for call in ["textureLod(g_Texture1, v_T, 2.0)", "texSample2DLod(g_Texture1, v_T, 2.0)", "texture2DLod(g_Texture1, v_T, 2.0)", "tex2DLod(g_Texture1, v_T, 2.0)"] {
        let t = frag(&frag_with(&format!("void main() {{ gl_FragColor = {call}; }}")));
        assert!(t.contains("textureLod(sampler2D(g_Texture1, _we_Sampler_g_Texture1), v_T, 2.0)"), "{call}: {t}");
        let _ = compile_frag(&frag_with(&format!("void main() {{ gl_FragColor = {call}; }}")));
    }
}

#[test]
fn texel_fetch_and_size_queries_use_the_separated_texture_object() {
    let src = frag_with("void main() { ivec2 s = textureSize(g_Texture0, 0); vec4 c = texelFetch(g_Texture0, ivec2(1, 2), 0); gl_FragColor = c * float(s.x); }");
    let t = frag(&src);
    assert!(t.contains("textureSize(g_Texture0, 0)") && t.contains("texelFetch(g_Texture0, ivec2(1, 2), 0)"), "{t}");
    let _ = compile_frag(&src);
}

#[test]
fn sampling_inside_macro_bodies_and_through_an_alias_macro_is_translated() {
    let direct = "uniform sampler2D g_Texture3; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture3, v_T) + tex2D(g_Texture3, v_T * 2.0); }";
    let via_macro = "uniform sampler2D g_Texture3; varying vec2 v_T;\n#define SAMPLE(uv) texSample2D(g_Texture3, uv)\n#define TEX g_Texture3\nvoid main() {\n#define LOCAL(uv) tex2D(TEX, uv)\n gl_FragColor = SAMPLE(v_T) + LOCAL(v_T * 2.0); }";
    let a = program(PASS_V, direct);
    let b = program(PASS_V, via_macro);
    assert_eq!(a.layout.textures, b.layout.textures, "the same descriptors");
    assert_eq!(a.fragment.as_ref().unwrap().text, b.fragment.as_ref().unwrap().text);
    let _ = compile_program(PASS_V, via_macro);
}

#[test]
fn a_sampler_passed_to_a_helper_function_is_specialised_to_the_texture() {
    let src = "uniform sampler2D g_Texture2; varying vec2 v_T;\nvec4 fetch(sampler2D s, vec2 uv) { return texSample2D(s, uv); }\nvoid main() { gl_FragColor = fetch(g_Texture2, v_T); }";
    let t = frag(src);
    assert!(t.contains("sampler2D(g_Texture2, _we_Sampler_g_Texture2)"), "{t}");
    let _ = compile_frag(src);
}

#[test]
fn a_local_that_hides_a_texture_name_is_not_a_texture() {
    let src = frag_with("void main() { vec4 g_Texture0 = vec4(v_T, 0.0, 1.0); gl_FragColor = g_Texture0 + texSample2D(g_Texture1, v_T); }");
    let t = frag(&src);
    assert!(t.contains("vec4 g_Texture0 = vec4(v_T, 0.0, 1.0);") && t.contains("_we_FragColor = g_Texture0 +"), "{t}");
}

#[test]
fn a_three_dimensional_texture_is_split_like_a_two_dimensional_one() {
    let src = "uniform sampler3D lut; uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { vec3 c = texSample2D(g_Texture0, v_T).rgb; gl_FragColor = vec4(texSample3D(lut, c).rgb, 1.0); }";
    let t = frag(src);
    assert!(t.contains("uniform texture3D lut;") && t.contains("texture(sampler3D(lut, _we_Sampler_lut), c)"), "{t}");
    let p = compile_program(PASS_V, src);
    assert!(p.program.layout.textures.iter().any(|t| t.name == "lut" && t.three_dimensional));
}

// ----- NV12 planes -----

const PLANE_F: &str = "uniform sampler2D g_Texture0; uniform sampler2D g_Texture1; uniform float g_Alpha; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T) * texSample2D(g_Texture1, v_T) * g_Alpha; }";

fn plane_program(slots: &[u8]) -> crate::legalize::LegalProgram {
    planes(PASS_V, PLANE_F, slots).unwrap_or_else(|e| panic!("{e}"))
}

fn binding_of(text: &str, name: &str) -> Option<u32> {
    text.lines()
        .find(|l| l.contains(&format!(" {name};")) && l.starts_with("layout(set = 0, binding = "))
        .and_then(|l| l.strip_prefix("layout(set = 0, binding = ")?.split(')').next()?.parse().ok())
}

#[test]
fn a_flagged_slot_gets_chroma_resources_a_helper_and_four_constants() {
    let p = plane_program(&[0]);
    let (vt, ft) = (&p.vertex.as_ref().unwrap().text, &p.fragment.as_ref().unwrap().text);
    for member in ["vec4 _we_VideoRange0;", "vec4 _we_VideoMatrix0;", "vec4 _we_VideoUvTransform0;", "vec2 _we_VideoUvOffset0;"] {
        assert!(vt.contains(member) && ft.contains(member), "{member}: the vertex stage sees the constants too");
    }
    let block_end = ft.find("g_Alpha;").unwrap();
    assert!(ft[..block_end].find("_we_VideoRange0").is_none(), "the constants come after every author member: {ft}");
    assert!(ft.contains("uniform texture2D _we_VideoChroma0;") && ft.contains("uniform sampler _we_Sampler__we_VideoChroma0;"), "{ft}");
    assert!(!vt.contains("_we_VideoChroma0"), "a stage that never samples the slot declares neither: {vt}");
    assert!(ft.contains("_we_plane0(v_T)") && !ft.contains("texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_T)"), "{ft}");
    assert!(ft.contains("uniform texture2D g_Texture0;"), "the luma declarations are unchanged");
    assert!(ft.contains("texture(sampler2D(g_Texture1, _we_Sampler_g_Texture1), v_T)"), "other slots sample as before");
    let plane = &p.layout.planes[0];
    assert_eq!((plane.slot, plane.chroma_texture.as_str()), (0, "_we_VideoChroma0"));
    assert!(plane.in_fragment && !plane.in_vertex);
    let _ = compile_program(PASS_V, PLANE_F).fragment;
    let both = {
        let v = p.vertex.as_ref().unwrap();
        let f = p.fragment.as_ref().unwrap();
        crate::dialect::tests::support::compile_glsl(StageKind::Vertex, &v.text).unwrap();
        crate::dialect::tests::support::compile_glsl(StageKind::Fragment, &f.text).unwrap()
    };
    assert!(both.msl.contains("_we_plane0"), "{}", both.msl);
}

#[test]
fn author_resources_keep_their_bindings_in_the_plane_variant() {
    let plain = plane_program(&[]);
    let planar = plane_program(&[1]);
    let (pt, qt) = (&plain.fragment.as_ref().unwrap().text, &planar.fragment.as_ref().unwrap().text);
    for name in ["g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1", "GlobalUniforms"] {
        let find = |t: &str| {
            t.lines()
                .find(|l| l.starts_with("layout(") && l.contains(&format!(" {name};")) || l.starts_with("layout(") && l.contains(&format!(" {name} {{")))
                .map(str::to_string)
        };
        assert_eq!(find(pt), find(qt), "{name}");
    }
    let plane = &planar.layout.planes[0];
    let used: Vec<u32> = plain.layout.textures.iter().flat_map(|t| [t.texture_binding, t.sampler_binding]).chain(plain.layout.block.iter().map(|b| b.binding)).collect();
    assert!(!used.contains(&plane.texture_binding) && !used.contains(&plane.sampler_binding), "only the added resources take new numbers");
    assert_eq!(binding_of(qt, "_we_VideoChroma1"), Some(plane.texture_binding));
    assert_eq!(plane.sampler_binding, plane.texture_binding + 1);
}

#[test]
fn a_program_without_author_uniforms_still_has_the_block_for_the_plane_constants() {
    let f = "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T); }";
    let p = planes(PASS_V, f, &[0]).unwrap();
    let block = p.layout.block.as_ref().expect("a block with only generated members");
    assert_eq!(block.members.len(), 4);
    assert!(block.members.iter().all(|m| m.video));
    // The author's texture and sampler keep their numbers; the block takes any binding that collides
    // with nothing and the chroma resources lie above the author's (amendment D6): the order of the
    // block among them is not pinned.
    let ft = &p.fragment.as_ref().unwrap().text;
    assert_eq!((binding_of(ft, "g_Texture0"), binding_of(ft, "_we_Sampler_g_Texture0")), (Some(0), Some(1)));
    let chroma = binding_of(ft, "_we_VideoChroma0").unwrap();
    let chroma_sampler = binding_of(ft, "_we_Sampler__we_VideoChroma0").unwrap();
    assert!(chroma > 1 && chroma_sampler > 1);
    let all = [0, 1, block.binding, chroma, chroma_sampler];
    assert_eq!(all.iter().collect::<std::collections::HashSet<_>>().len(), all.len(), "{all:?}");
}

#[test]
fn the_plain_variant_is_unchanged_by_the_option_and_a_flag_on_an_undeclared_slot_changes_nothing() {
    let plain = program(PASS_V, PLANE_F);
    let none = planes(PASS_V, PLANE_F, &[]).unwrap();
    let undeclared = planes(PASS_V, PLANE_F, &[5, 9]).unwrap();
    assert_eq!(plain, none);
    assert_eq!(plain, undeclared, "flagging a slot no stage declares is not an error and not a change");
}

#[test]
fn sampling_through_a_macro_is_translated_like_any_other_call() {
    let f = "uniform sampler2D g_Texture0; varying vec2 v_T;\n#define VIDEO(uv) texSample2D(g_Texture0, uv)\nvoid main() { gl_FragColor = VIDEO(v_T) + VIDEO(v_T * 0.5); }";
    let p = planes(PASS_V, f, &[0]).unwrap();
    let t = &p.fragment.as_ref().unwrap().text;
    assert_eq!(count(t, "_we_plane0(v_T"), 2, "{t}");
}

fn refused(f: &str) -> String {
    match planes(PASS_V, f, &[0]) {
        Ok(p) => panic!("should have been refused:\n{}", p.fragment.unwrap().text),
        Err(e) => {
            assert!(matches!(e, LegalizeError::Request(_)), "{e}");
            e.message()
        }
    }
}

#[test]
fn a_use_the_translation_cannot_reproduce_refuses_the_variant() {
    let cases = [
        ("a mip-level sample", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2DLod(g_Texture0, v_T, 1.0); }"),
        ("a size query", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = vec4(float(textureSize(g_Texture0, 0).x)); }"),
        ("surplus arguments", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T, 0.5); }"),
        ("a texel fetch", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texelFetch(g_Texture0, ivec2(1), 0); }"),
        ("a call without a coordinate", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texture(g_Texture0); }"),
        ("a macro body", "uniform sampler2D g_Texture0; varying vec2 v_T;\n#define SIZE textureSize(g_Texture0, 0)\nvoid main() { gl_FragColor = vec4(float(SIZE.x)); }"),
        ("a helper function", "uniform sampler2D g_Texture0; varying vec2 v_T;\nvec4 fetch(sampler2D s, vec2 uv) { return textureGrad(s, uv, vec2(0.0), vec2(0.0)); }\nvoid main() { gl_FragColor = fetch(g_Texture0, v_T); }"),
    ];
    for (what, src) in cases {
        let message = refused(src);
        assert!(message.contains("slot 0") && message.contains("cannot be sampled as planes"), "{what}: {message}");
    }
}

#[test]
fn a_refusal_is_decided_before_anything_is_produced() {
    // one good sample and one bad one: the whole variant fails
    let f = "uniform sampler2D g_Texture0; varying vec2 v_T;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_T) + texSample2DLod(g_Texture0, v_T, 1.0); }";
    assert!(refused(f).contains("cannot be sampled as planes"));
    // the same stage is fine as a plain program
    let _ = program(PASS_V, f);
}
