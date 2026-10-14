//! Generated resource declarations.

use std::fmt::Write as _;

use smol_str::SmolStr;

use super::{super::emission::SourceEmitter, types::LegacyTypeName};
use crate::{
    ShaderDiagnostic, ShaderError, ShaderResult, ShaderStageKind, SourceSpan,
    layout::DescriptorBinding, tokenizer::TokenCursor,
};

/// GLSL sampler uniform type classification.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct SamplerType<'src> {
    /// Source type spelling.
    name: &'src str,
}

impl<'src> SamplerType<'src> {
    /// Returns a sampler classification for GLSL sampler type names.
    #[must_use]
    pub(crate) fn new(name: &'src str) -> Option<Self> {
        const PREFIXES: [&str; 3] = ["sampler", "isampler", "usampler"];

        PREFIXES
            .iter()
            .any(|prefix| {
                name.strip_prefix(prefix).is_some_and(|suffix| {
                    suffix.is_empty()
                        || suffix.chars().next().is_some_and(|first| {
                            first.is_ascii_digit() || first.is_ascii_uppercase()
                        })
                })
            })
            .then_some(Self { name })
    }

    /// Returns whether the legalizer can split this source sampler into
    /// backend-compatible texture and sampler descriptors.
    #[must_use]
    pub(crate) fn supports_texture_split(self) -> bool {
        self.name == "sampler2D"
    }
}

/// Scalar or vector uniform moved into the generated global block.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct UniformMember {
    /// Source type name.
    pub ty: SmolStr,
    /// Source variable name.
    pub name: SmolStr,
    /// Optional array suffix following the declaration name.
    pub array_suffix: Option<SmolStr>,
    /// Explicit layout binding parsed from source, when present.
    pub explicit_binding: Option<u32>,
    /// Descriptor binding assigned to the generated block.
    pub binding: Option<DescriptorBinding>,
}
/// Component width a narrow array member is widened from, so its reads can be
/// swizzled back.
///
/// std140 pads every array element to 16 bytes, which is the layout the host
/// packs and the reflection reports. Metal's natural layout for `float[64]` is
/// a tight 4-byte stride and the shader compiler's MSL backend emits it that
/// way, so a scalar array in a uniform block puts the two renderers on
/// different layouts and silently shifts every member after it. Declaring the
/// member `vec4[N]` makes both layouts 16 bytes per element, which is what the
/// host was writing all along.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WidenedArrayMember {
    /// `float name[N]` widened to `vec4 name[N]`.
    Scalar,
    /// `vec2 name[N]` widened to `vec4 name[N]`.
    Two,
    /// `vec3 name[N]` widened to `vec4 name[N]`.
    Three,
}

impl WidenedArrayMember {
    /// Classifies a block member declaration, if widening applies.
    pub(crate) fn classify(ty: &str, array_suffix: Option<&str>) -> Option<Self> {
        if array_suffix.is_none() {
            return None;
        }
        match ty {
            "float" => Some(Self::Scalar),
            "vec2" | "float2" => Some(Self::Two),
            "vec3" | "float3" => Some(Self::Three),
            _ => None,
        }
    }

    /// Swizzle that reads the original value back out of a widened element.
    pub(crate) const fn swizzle(self) -> &'static str {
        match self {
            Self::Scalar => ".x",
            Self::Two => ".xy",
            Self::Three => ".xyz",
        }
    }

    /// Insertion point for the swizzle after a subscripted use beginning at
    /// `index`, or `None` when the use is not an element read.
    ///
    /// A bare mention is the whole array -- passed to a function, say -- and
    /// has no component to select. An author swizzle already following the
    /// subscript needs no help and must not be given one.
    pub(crate) fn subscript_swizzle_span(
        tokens: TokenCursor<'_>,
        index: usize,
    ) -> Option<SourceSpan> {
        let open = tokens.next_non_comment(index + 1)?;
        if !tokens[open].kind().is_left_square() {
            return None;
        }
        let close = tokens.matching_right_square(open)?;
        if tokens
            .next_non_comment(close + 1)
            .is_some_and(|next| tokens[next].kind().is_member_access_operator())
        {
            return None;
        }
        let end = tokens[close].span().end();
        SourceSpan::new(end, end).ok()
    }

    /// Span of a second subscript following the element read beginning at
    /// `index`, which selects a component of that element.
    #[expect(
        clippy::single_call_fn,
        reason = "pairs with subscript_swizzle_span, which reads the same subscript"
    )]
    pub(crate) fn component_subscript_span(
        tokens: TokenCursor<'_>,
        index: usize,
    ) -> Option<SourceSpan> {
        let open = tokens.next_non_comment(index + 1)?;
        if !tokens[open].kind().is_left_square() {
            return None;
        }
        let component_open = tokens.next_non_comment(tokens.matching_right_square(open)? + 1)?;
        if !tokens[component_open].kind().is_left_square() {
            return None;
        }
        let component_close = tokens.matching_right_square(component_open)?;
        SourceSpan::new(
            tokens[component_open].span().start(),
            tokens[component_close].span().end(),
        )
        .ok()
    }
}

/// Generated std140 block containing scalar/vector uniforms.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct UniformBlock {
    /// Members emitted inside the block.
    pub members: Vec<UniformMember>,
    /// Descriptor binding shared by all members.
    pub binding: DescriptorBinding,
}

impl UniformBlock {
    /// Emits the generated uniform block declaration, resolving member array
    /// suffixes through a caller-supplied macro resolver when available.
    pub(crate) fn emit_with_array_suffix_resolver(
        &self,
        output: &mut String,
        mut resolve_array_suffix: impl FnMut(&str) -> Option<String>,
    ) -> ShaderResult<()> {
        writeln!(
            output,
            "layout(std140, set = {}, binding = {}) uniform GlobalUniforms {{",
            self.binding.set(),
            self.binding.binding()
        )
        .map_err(SourceEmitter::write_error)?;
        for member in &self.members {
            let widened =
                WidenedArrayMember::classify(member.ty.as_str(), member.array_suffix.as_deref());
            writeln!(
                output,
                "    {} {}{};",
                if widened.is_some() {
                    "vec4"
                } else {
                    LegacyTypeName::new(member.ty.as_str()).glsl()
                },
                member.name,
                member
                    .array_suffix
                    .as_deref()
                    .and_then(&mut resolve_array_suffix)
                    .as_deref()
                    .or(member.array_suffix.as_deref())
                    .unwrap_or_default()
            )
            .map_err(SourceEmitter::write_error)?;
        }
        writeln!(output, "}};").map_err(SourceEmitter::write_error)
    }
}

/// Separated texture declaration with an assigned descriptor binding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TextureDeclaration<'src> {
    /// Emitted texture type name.
    pub ty: &'src str,
    /// Source texture variable name.
    pub name: &'src str,
    /// Descriptor binding assigned to the texture.
    pub binding: Option<DescriptorBinding>,
    /// Descriptor binding assigned to this texture's paired sampler.
    pub sampler_binding: Option<DescriptorBinding>,
}

impl TextureDeclaration<'_> {
    /// Prefix for generated sampler descriptors paired to texture declarations.
    pub(crate) const SAMPLER_PREFIX: &'static str = "_we_Sampler_";

    /// Parses `g_TextureN` texture names into fixed binding indices.
    pub(crate) fn texture_binding(self, stage: ShaderStageKind) -> ShaderResult<Option<u32>> {
        let Some(suffix) = self.name.strip_prefix("g_Texture") else {
            return Ok(None);
        };
        if suffix.is_empty() || !suffix.chars().all(|character| character.is_ascii_digit()) {
            return Ok(None);
        }
        if suffix.len() > 1 && suffix.starts_with('0') {
            return Err(ShaderError::Codegen {
                diagnostics: Box::new([self.non_canonical_binding_diagnostic(stage)]),
            });
        }

        Ok(suffix.parse::<u32>().ok())
    }

    /// Builds a diagnostic for non-canonical `g_TextureN` encoded bindings.
    fn non_canonical_binding_diagnostic(self, stage: ShaderStageKind) -> ShaderDiagnostic {
        ShaderDiagnostic::new(format!(
            "source texture `{}` is not a canonical g_TextureN descriptor binding name",
            self.name
        ))
        .with_stage(stage)
        .with_pass("Codegen")
    }

    /// Builds a diagnostic for duplicate `g_TextureN` encoded bindings.
    pub(crate) fn duplicate_binding_diagnostic(
        self,
        stage: ShaderStageKind,
        previous_name: &str,
        binding: u32,
    ) -> ShaderDiagnostic {
        ShaderDiagnostic::new(format!(
            "source textures `{previous_name}` and `{}` both encode descriptor binding {binding}",
            self.name
        ))
        .with_stage(stage)
        .with_pass("Codegen")
    }

    /// Emits the generated texture declaration.
    pub(crate) fn emit(self, output: &mut String) -> ShaderResult<()> {
        let binding = self.binding.ok_or_else(|| {
            ShaderError::invalid_request("texture binding was not assigned before emission")
        })?;
        writeln!(
            output,
            "layout(set = {}, binding = {}) uniform {} {};",
            binding.set(),
            binding.binding(),
            self.ty,
            self.name
        )
        .map_err(SourceEmitter::write_error)
    }
}

/// Generated sampler paired to a separated texture handle.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TextureSampler<'src> {
    /// Source texture variable name.
    pub texture_name: &'src str,
    /// Generated sampler descriptor binding.
    pub binding: DescriptorBinding,
}

impl TextureSampler<'_> {
    /// Emits the generated sampler declaration.
    pub(crate) fn emit(self, output: &mut String) -> ShaderResult<()> {
        writeln!(
            output,
            "layout(set = {}, binding = {}) uniform sampler {};",
            self.binding.set(),
            self.binding.binding(),
            TextureDeclaration::SAMPLER_PREFIX.to_owned() + self.texture_name
        )
        .map_err(SourceEmitter::write_error)
    }
}

/// Generated fragment color output declaration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct FragmentOutput;

impl FragmentOutput {
    /// Generated output variable name used to replace `gl_FragColor`.
    pub(crate) const NAME: &'static str = "_we_FragColor";
}
