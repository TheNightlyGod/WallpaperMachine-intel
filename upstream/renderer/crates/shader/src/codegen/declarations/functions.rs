//! Compatibility helper requests and function declaration facts.

use std::fmt::Write as _;

use super::{super::emission::SourceEmitter, layout::VideoPlaneResource,
            resources::TextureDeclaration};
use crate::{ShaderResult, SourceSpan};

/// Generated name a builtin matrix `inverse` call is rewritten to.
pub(crate) const MATRIX_INVERSE_HELPER: &str = "_we_Inverse";

/// Macro a compiler defines when its backend writer has no matrix `inverse`.
///
/// Without it the helper name expands back to the builtin, so a backend that
/// implements `inverse` itself compiles exactly the call it always did.
pub(crate) const MATRIX_INVERSE_POLYFILL_MACRO: &str = "_WE_POLYFILL_INVERSE";

/// Compatibility helper functions requested during codegen.
// One independent request per helper family, not a state machine.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct CompatibilityFunctionRequests {
    /// Whether generated `clip` overloads are needed.
    clip: bool,
    /// Whether generated `PerformLighting_V1` overloads are needed.
    perform_lighting: bool,
    /// Whether remainder expressions need a single-evaluation float helper.
    float_remainder: bool,
    /// Whether builtin matrix `inverse` calls were renamed to the helper.
    matrix_inverse: bool,
}

impl CompatibilityFunctionRequests {
    /// Requests truncating remainder overloads for generated float `%` calls.
    pub(crate) fn require_float_remainder(&mut self) {
        self.float_remainder = true;
    }

    /// Requests the matrix inverse helper for renamed builtin `inverse` calls.
    pub(crate) fn require_matrix_inverse(&mut self) {
        self.matrix_inverse = true;
    }

    /// Requests generated `clip` overloads.
    pub(crate) fn require_clip(&mut self) {
        self.clip = true;
    }

    /// Requests generated `PerformLighting_V1` overloads.
    pub(crate) fn require_perform_lighting(&mut self) {
        self.perform_lighting = true;
    }

    /// Emits requested compatibility helper functions.
    pub(crate) fn emit(self, output: &mut String) -> ShaderResult<()> {
        if self.perform_lighting {
            writeln!(
                output,
                "vec3 PerformLighting_V1(vec3 world_pos, vec3 albedo, vec3 normal, vec3 \
                 view_vector,\nvec3 specular_tint, vec3 f0, float roughness, float metallic) \
                 {{\nreturn albedo * max(dot(normalize(normal), normalize(view_vector)), \
                 0.0);\n}}\nvec3 PerformLighting_V1(vec3 world_pos, vec3 albedo, vec3 normal, \
                 vec3 view_vector,\nvec3 specular_tint, vec3 f0, float roughness, float metallic, \
                 float ao) {{\nreturn albedo * ao * max(dot(normalize(normal), \
                 normalize(view_vector)), 0.0);\n}}"
            )
            .map_err(SourceEmitter::write_error)?;
        }

        if self.clip {
            writeln!(
                output,
                "void clip(float value) {{ if (value < 0.0) discard; }}\nvoid clip(vec2 value) {{ \
                 if (any(lessThan(value, vec2(0.0)))) discard; }}\nvoid clip(vec3 value) {{ if \
                 (any(lessThan(value, vec3(0.0)))) discard; }}\nvoid clip(vec4 value) {{ if \
                 (any(lessThan(value, vec4(0.0)))) discard; }}"
            )
            .map_err(SourceEmitter::write_error)?;
        }

        if self.float_remainder {
            // Arguments are evaluated once, unlike expanding x - y * trunc(x/y)
            // at the call site when x or y contains a function call or increment.
            for ty in ["float", "vec2", "vec3", "vec4"] {
                writeln!(output, "{ty} _we_Fmod({ty} x, {ty} y) {{ return x - y * trunc(x / y); }}")
                    .map_err(SourceEmitter::write_error)?;
                if ty != "float" {
                    writeln!(output, "{ty} _we_Fmod({ty} x, float y) {{ return x - y * trunc(x / y); }}")
                        .map_err(SourceEmitter::write_error)?;
                    writeln!(output, "{ty} _we_Fmod(float x, {ty} y) {{ return x - y * trunc(x / y); }}")
                        .map_err(SourceEmitter::write_error)?;
                }
            }
        }

        if self.matrix_inverse {
            // Adjugate over determinant, one overload per square size. Cofactor
            // columns are cross products of the other columns, so the 3x3
            // inverse is the transposed cross products over the triple
            // product, and the 4x4 one is assembled from the same products of
            // its upper 3x3 block and bottom row (Lengyel's form). Singular
            // input divides by zero, as the builtin's result is undefined.
            writeln!(
                output,
                "#ifdef {MATRIX_INVERSE_POLYFILL_MACRO}\n\
                 mat2 {MATRIX_INVERSE_HELPER}(mat2 m) {{\n    \
                 return mat2(m[1][1], -m[0][1], -m[1][0], m[0][0]) * \
                 (1.0 / (m[0][0] * m[1][1] - m[1][0] * m[0][1]));\n}}\n\
                 mat3 {MATRIX_INVERSE_HELPER}(mat3 m) {{\n    \
                 vec3 x = cross(m[1], m[2]);\n    vec3 y = cross(m[2], m[0]);\n    \
                 vec3 z = cross(m[0], m[1]);\n    \
                 return transpose(mat3(x, y, z)) * (1.0 / dot(m[0], x));\n}}\n\
                 mat4 {MATRIX_INVERSE_HELPER}(mat4 m) {{\n    \
                 vec3 a = m[0].xyz;\n    vec3 b = m[1].xyz;\n    \
                 vec3 c = m[2].xyz;\n    vec3 d = m[3].xyz;\n    \
                 float x = m[0].w;\n    float y = m[1].w;\n    \
                 float z = m[2].w;\n    float w = m[3].w;\n    \
                 vec3 s = cross(a, b);\n    vec3 t = cross(c, d);\n    \
                 vec3 u = a * y - b * x;\n    vec3 v = c * w - d * z;\n    \
                 float r = 1.0 / (dot(s, v) + dot(t, u));\n    \
                 s *= r;\n    t *= r;\n    u *= r;\n    v *= r;\n    \
                 return transpose(mat4(vec4(cross(b, v) + t * y, -dot(b, t)),\n        \
                 vec4(cross(v, a) - t * x, dot(a, t)),\n        \
                 vec4(cross(d, u) + s * w, -dot(d, s)),\n        \
                 vec4(cross(u, c) - s * z, dot(c, s))));\n}}\n\
                 #else\n#define {MATRIX_INVERSE_HELPER} inverse\n#endif"
            )
            .map_err(SourceEmitter::write_error)?;
        }

        if self.perform_lighting || self.clip || self.float_remainder || self.matrix_inverse {
            writeln!(output).map_err(SourceEmitter::write_error)?;
        }
        Ok(())
    }
}

/// Parsed function declaration information needed by collision rewrites.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct FunctionEntry<'src> {
    /// Function name from the parsed declaration.
    pub name: &'src str,
    /// Span covering only the function name token.
    pub name_span: SourceSpan,
}

/// Video plane sampling helpers requested during codegen.
///
/// A helper is emitted only for a slot whose sampling calls were actually
/// rewritten in this stage, so a vertex stage that never touches the video
/// texture declares no chroma plane and carries no dead function.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct VideoSamplingFunctionRequests {
    /// Material texture slots whose sampling calls were rewritten.
    slots: Vec<u8>,
}

impl VideoSamplingFunctionRequests {
    /// Requests the sampling helper for one material texture slot.
    pub(crate) fn require(&mut self, slot: u8) {
        if !self.slots.contains(&slot) {
            self.slots.push(slot);
        }
    }

    /// Returns whether a slot's helper was requested.
    #[must_use]
    pub(crate) fn contains(&self, slot: u8) -> bool {
        self.slots.contains(&slot)
    }

    /// Emits the requested helpers for the program's plane resources.
    ///
    /// The arithmetic is the same affine transform the renderer's own NV12
    /// conversion kernel applies, expressed against the same eight constants,
    /// so the direct path and the pre-converted path cannot disagree about
    /// range, matrix or alpha for one frame. Chroma is read from a plane at
    /// half resolution and is filtered by its own sampler, which is what
    /// reproduces the kernel's chroma upsample rather than approximating it.
    pub(crate) fn emit<'plane>(
        &self,
        output: &mut String,
        planes: impl Iterator<Item = &'plane VideoPlaneResource>,
    ) -> ShaderResult<()> {
        let mut emitted = false;
        for plane in planes.filter(|plane| self.contains(plane.slot)) {
            let helper = VideoPlaneResource::helper_name(plane.slot);
            let range = VideoPlaneResource::range_uniform_name(plane.slot);
            let matrix = VideoPlaneResource::matrix_uniform_name(plane.slot);
            let uv_transform = VideoPlaneResource::uv_transform_uniform_name(plane.slot);
            let uv_offset = VideoPlaneResource::uv_offset_uniform_name(plane.slot);
            let luma = plane.base_name.as_str();
            let luma_sampler = format!("{}{luma}", TextureDeclaration::SAMPLER_PREFIX);
            let chroma = plane.chroma_name.as_str();
            let chroma_sampler = format!("{}{chroma}", TextureDeclaration::SAMPLER_PREFIX);
            writeln!(
                output,
                "vec4 {helper}(vec2 _we_video_coord) {{\n    \
                 _we_video_coord = vec2(dot(_we_video_coord, {uv_transform}.xy), \
                 dot(_we_video_coord, {uv_transform}.zw)) + {uv_offset};\n    float _we_video_y = \
                 texture(sampler2D({luma}, {luma_sampler}), _we_video_coord).r;\n    vec2 \
                 _we_video_cbcr = texture(sampler2D({chroma}, {chroma_sampler}), \
                 _we_video_coord).rg;\n    float _we_video_luma = clamp((_we_video_y - \
                 {range}.x) * {range}.y, 0.0, 1.0);\n    vec2 _we_video_chroma = \
                 (_we_video_cbcr - {range}.z) * {range}.w;\n    float _we_video_coverage = 1.0;\n    \
                 if (abs({uv_transform}.x * {uv_transform}.y) > 0.000001 || \
                 abs({uv_transform}.z * {uv_transform}.w) > 0.000001) {{\n        \
                 _we_video_coverage = float(all(greaterThanEqual(_we_video_coord, vec2(0.0))) && \
                 all(lessThanEqual(_we_video_coord, vec2(1.0))));\n    }}\n    return vec4(\n        \
                 clamp(_we_video_luma + {matrix}.x * _we_video_chroma.y, 0.0, 1.0),\n        \
                 clamp(_we_video_luma + {matrix}.y * _we_video_chroma.x + {matrix}.z * \
                 _we_video_chroma.y, 0.0, 1.0),\n        clamp(_we_video_luma + {matrix}.w * \
                 _we_video_chroma.x, 0.0, 1.0),\n        1.0) * _we_video_coverage;\n}}"
            )
            .map_err(SourceEmitter::write_error)?;
            emitted = true;
        }
        if emitted {
            writeln!(output).map_err(SourceEmitter::write_error)?;
        }
        Ok(())
    }
}
