// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! A textured quad pair (spec D test 18): entry points, version, interface numbers, resources.

use super::support::*;
use crate::binding::SlotKind;
use crate::request::StageKind;

const VERTEX: &str = "#version 450
precision highp float;
layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec2 a_TexCoord;
layout(location = 0) out vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
";

const FRAGMENT: &str = "#version 450
precision highp float;
layout(set = 0, binding = 3) uniform texture2D g_Texture0;
layout(set = 0, binding = 4) uniform sampler _we_Sampler_g_Texture0;
layout(std140, set = 0, binding = 2) uniform GlobalUniforms {
    float g_Alpha;
};
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 _we_FragColor;
void main() {
  _we_FragColor = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord) * g_Alpha;
}
";

#[test]
fn entry_points_are_declared_and_reported_under_their_own_names() {
    let (v, f) = (vertex(VERTEX), fragment(FRAGMENT));
    for (c, keyword) in [(&v, "vertex"), (&f, "fragment")] {
        let name = &c.payload.entry_point;
        assert_ne!(name, "main", "the writer renames `main`");
        assert!(msl(c).contains(&format!("{keyword} main_Output {name}(")), "{}", msl(c));
        assert_eq!(c.payload.language_version, "2.0");
        assert!(msl(c).starts_with("// language: metal2.0\n"), "{}", &msl(c)[..40]);
    }
    assert_eq!(v.payload.kind, StageKind::Vertex);
    assert_eq!(f.payload.kind, StageKind::Fragment);
}

#[test]
fn attributes_user_locations_and_the_colour_output_carry_their_numbers() {
    let (v, f) = (vertex(VERTEX), fragment(FRAGMENT));
    assert!(msl(&v).contains("metal::float3 a_Position [[attribute(0)]];"), "{}", msl(&v));
    assert!(msl(&v).contains("metal::float2 a_TexCoord [[attribute(1)]];"), "{}", msl(&v));
    assert!(msl(&v).contains("[[stage_in]]"));
    assert!(msl(&v).contains("metal::float2 v_TexCoord [[user(loc0)"), "{}", msl(&v));
    assert!(msl(&v).contains("metal::float4 gl_Position [[position]]"), "{}", msl(&v));
    assert!(msl(&f).contains("metal::float2 v_TexCoord [[user(loc0)"), "{}", msl(&f));
    assert!(msl(&f).contains("[[color(0)]]"), "{}", msl(&f));
}

#[test]
fn resources_are_plain_entry_function_parameters_at_their_slots() {
    let f = fragment(FRAGMENT);
    let m = msl(&f);
    assert!(m.contains("metal::texture2d<float, metal::access::sample> g_Texture0_ [[texture(0)]]"), "{m}");
    assert!(m.contains("metal::sampler _we_Sampler_g_Texture0_ [[sampler(0)]]"), "{m}");
    assert!(m.contains("constant GlobalUniforms& global [[buffer(0)]]"), "{m}");
    assert!(!m.contains("[[id("), "no argument buffer: {m}");
    assert!(!m.contains("argument_buffer"), "no argument buffer: {m}");
    assert!(!m.contains("constexpr sampler"), "no inline sampler: {m}");
}

#[test]
fn binding_records_name_the_glsl_identifiers_and_cover_every_resource() {
    let f = fragment(FRAGMENT);
    // Records come in declaration order; a name ending in a digit is reported as written, not
    // with the underscore the writer appends to it in the text.
    let names: Vec<&str> = f.payload.bindings.iter().map(|b| b.name.as_str()).collect();
    assert_eq!(names, ["g_Texture0", "_we_Sampler_g_Texture0", "GlobalUniforms"]);
    assert_eq!(slot_of(&f, "g_Texture0"), (SlotKind::Texture, 3, 0));
    assert_eq!(slot_of(&f, "_we_Sampler_g_Texture0"), (SlotKind::Sampler, 4, 0));
    assert_eq!(slot_of(&f, "GlobalUniforms"), (SlotKind::Buffer, 2, 0));
    assert!(f.payload.bindings.iter().all(|b| b.set == 0));
    let v = vertex(VERTEX);
    assert!(v.payload.bindings.is_empty());
}

#[test]
fn ten_textures_take_slots_zero_to_nine_while_the_bindings_run_to_twenty() {
    let mut text = String::from("#version 450\nprecision highp float;\n");
    text.push_str("layout(std140, set = 0, binding = 0) uniform GlobalUniforms { float g_Alpha; };\n");
    for n in 0..10u32 {
        text.push_str(&format!("layout(set = 0, binding = {}) uniform texture2D g_Texture{n};\n", 1 + 2 * n));
        text.push_str(&format!("layout(set = 0, binding = {}) uniform sampler _we_Sampler_g_Texture{n};\n", 2 + 2 * n));
    }
    text.push_str("layout(location = 0) out vec4 c;\nvoid main() {\n  vec4 sum = vec4(g_Alpha);\n");
    for n in 0..10 {
        text.push_str(&format!("  sum += texture(sampler2D(g_Texture{n}, _we_Sampler_g_Texture{n}), vec2(0.5));\n"));
    }
    text.push_str("  c = sum;\n}\n");
    let f = fragment(&text);
    assert_eq!(slot_of(&f, "GlobalUniforms"), (SlotKind::Buffer, 0, 0));
    for n in 0..10u32 {
        assert_eq!(slot_of(&f, &format!("g_Texture{n}")), (SlotKind::Texture, 1 + 2 * n, n));
        assert_eq!(slot_of(&f, &format!("_we_Sampler_g_Texture{n}")), (SlotKind::Sampler, 2 + 2 * n, n));
    }
    assert!(msl(&f).contains("[[sampler(9)]]") && msl(&f).contains("[[texture(9)]]"), "{}", msl(&f));
}

#[test]
fn the_same_resource_may_have_different_slots_in_the_two_stages() {
    // The vertex stage declares only the second texture pair, so its slots restart from 0.
    let vertex_text = "#version 450
layout(set = 0, binding = 2) uniform texture2D g_Texture1;
layout(set = 0, binding = 3) uniform sampler _we_Sampler_g_Texture1;
layout(location = 0) in vec2 a_TexCoord;
void main() { gl_Position = textureLod(sampler2D(g_Texture1, _we_Sampler_g_Texture1), a_TexCoord, 0.0); }
";
    let v = vertex(vertex_text);
    assert_eq!(slot_of(&v, "g_Texture1"), (SlotKind::Texture, 2, 0));
    assert_eq!(slot_of(&v, "_we_Sampler_g_Texture1"), (SlotKind::Sampler, 3, 0));
}
