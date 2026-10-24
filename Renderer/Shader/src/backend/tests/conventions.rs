// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! No coordinate transformation, and the conventions reported honestly (spec D test 20, R50).

use super::support::*;
use crate::response::Conventions;

const VERTEX: &str = "#version 450
layout(location = 0) in vec4 a_Position;
layout(location = 1) in vec2 a_TexCoord;
layout(location = 0) out vec2 v_TexCoord;
void main() {
  gl_Position = a_Position;
  v_TexCoord = a_TexCoord;
}
";

const FRAGMENT: &str = "#version 450
layout(set = 0, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 c;
void main() { c = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord); }
";

/// `name = <identifier>;` with nothing else on the right-hand side: a plain copy.
fn assigned_plainly(text: &str, name: &str) -> bool {
    text.lines().any(|l| {
        let l = l.trim();
        l.strip_prefix(&format!("{name} = ")).is_some_and(|rest| {
            rest.strip_suffix(';').is_some_and(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
        })
    })
}

#[test]
fn all_three_conventions_are_reported_false() {
    for c in [vertex(VERTEX), fragment(FRAGMENT)] {
        assert_eq!(c.payload.conventions, Conventions::default());
        assert!(!c.payload.conventions.clip_space_y_flipped);
        assert!(!c.payload.conventions.clip_space_depth_remapped);
        assert!(!c.payload.conventions.texture_origin_flipped);
    }
}

#[test]
fn the_vertex_position_leaves_the_function_unmodified() {
    let v = vertex(VERTEX);
    let m = msl(&v);
    assert!(assigned_plainly(m, "gl_Position"), "the author's position is copied unchanged: {m}");
    // The output struct carries it as is: no negation, no `1 -`, no depth remap.
    assert!(m.contains("return main_Output { _tmp.v_TexCoord, _tmp.gl_Position };"), "{m}");
    for forbidden in ["-gl_Position", "1.0 - ", "* 0.5", "gl_Position.y =", "gl_Position.z ="] {
        assert!(!m.contains(forbidden), "{forbidden}: {m}");
    }
}

#[test]
fn sampling_coordinates_pass_through() {
    let f = fragment(FRAGMENT);
    let m = msl(&f);
    let sample = m.lines().find(|l| l.contains(".sample(")).expect("a sample call").trim();
    let args = sample.split(".sample(").nth(1).unwrap().trim_end_matches(");");
    let (sampler, coordinate) = args.split_once(", ").expect("sampler, coordinate");
    assert_eq!(sampler, "_we_Sampler_g_Texture0_");
    assert!(coordinate.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'), "the coordinate is the loaded varying: {sample}");
}

#[test]
fn the_conventions_document_follows_the_flags() {
    let c = vertex(VERTEX);
    assert!(c.payload.to_json().contains(r#""conventions":{"clip_space_y_flipped":false,"clip_space_depth_remapped":false,"texture_origin_flipped":false}"#));
}
