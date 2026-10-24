// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! NV12 video planes (spec C2, 4.8): a flagged material slot is sampled as a luma texture
//! plus a half-resolution chroma texture, and the shader converts to RGB itself.

use crate::names::{
    sampler_name, video_chroma_name, video_matrix_member, video_range_member, video_uv_offset_member,
    video_uv_transform_member,
};
use crate::uniforms::{Scalar, UniformType};

/// The four generated block members of a plane, in their fixed order (R46).
pub(crate) fn plane_members(slot: u8) -> Vec<(String, UniformType)> {
    let slot = u32::from(slot);
    let vec4 = UniformType::Vector(Scalar::Float, 4);
    vec![
        (video_range_member(slot), vec4),
        (video_matrix_member(slot), vec4),
        (video_uv_transform_member(slot), vec4),
        (video_uv_offset_member(slot), UniformType::Vector(Scalar::Float, 2)),
    ]
}

/// The chroma texture and its sampler declarations (R6).
pub(crate) fn chroma_declarations(slot: u8, texture: u32, sampler: u32) -> String {
    let name = video_chroma_name(u32::from(slot));
    format!(
        "layout(set = 0, binding = {texture}) uniform texture2D {name};\nlayout(set = 0, binding = {sampler}) uniform sampler {};\n",
        sampler_name(&name)
    )
}

/// The conversion helper and the sampling helper of a plane (R47, R48). `convert` holds the
/// arithmetic as a pure function of its inputs so that it can be evaluated on its own.
pub(crate) fn helper_source(slot: u8, texture: &str, helper: &str, convert: &str) -> String {
    let n = u32::from(slot);
    let chroma = video_chroma_name(n);
    let (range, matrix) = (video_range_member(n), video_matrix_member(n));
    let (transform, offset) = (video_uv_transform_member(n), video_uv_offset_member(n));
    let (luma_sampler, chroma_sampler) = (sampler_name(texture), sampler_name(&chroma));
    format!(
        "vec4 {convert}(float y, vec2 c, vec2 p, vec4 t, vec4 r, vec4 m) {{
    float l = clamp((y - r.x) * r.y, 0.0, 1.0);
    vec2 cc = (c - vec2(r.z)) * r.w;
    vec4 rgba = vec4(clamp(l + m.x * cc.y, 0.0, 1.0), clamp(l + m.y * cc.x + m.z * cc.y, 0.0, 1.0), clamp(l + m.w * cc.x, 0.0, 1.0), 1.0);
    float cover = 1.0;
    if (abs(t.x * t.y) > 1e-6 || abs(t.z * t.w) > 1e-6) {{
        cover = (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) ? 1.0 : 0.0;
    }}
    return rgba * cover;
}}
vec4 {helper}(vec2 uv) {{
    vec4 t = {transform};
    vec2 p = vec2(dot(uv, t.xy), dot(uv, t.zw)) + {offset};
    float y = texture(sampler2D({texture}, {luma_sampler}), p).r;
    vec2 c = texture(sampler2D({chroma}, {chroma_sampler}), p).rg;
    return {convert}(y, c, p, t, {range}, {matrix});
}}
"
    )
}
