//! Naga-backed GLSL to SPIR-V and Metal Shading Language compilation.

use naga::{
    back::spv,
    front::glsl,
    valid::{Capabilities, ModuleInfo, ValidationFlags, Validator},
};

use super::{diagnostic::DiagnosticBuilder, metal::MetalEmitter};
use crate::{
    CompiledShaderStage, CompiledStageArtifact, CompiledStageCode, ShaderCompiler, ShaderError,
    ShaderResult, ShaderStageKind, ShaderTarget,
    codegen::declarations::functions::MATRIX_INVERSE_POLYFILL_MACRO, legalize::CodegenStageSource,
};

/// Compiler backend that lowers legalized GLSL through Naga.
#[derive(Clone, Debug, Default)]
pub struct NagaCompiler;

impl ShaderCompiler for NagaCompiler {
    type Module = naga::Module;

    fn compile_stage(
        &self,
        target: ShaderTarget,
        stage: ShaderStageKind,
        source: &CodegenStageSource,
    ) -> ShaderResult<CompiledStageArtifact<Self::Module>> {
        if source.stage() != stage {
            return Err(ShaderError::invalid_request(format!(
                "compiler stage {stage:?} does not match legalized source stage {:?}",
                source.stage()
            )));
        }

        let source_text = source.source();
        let source_path = match stage {
            ShaderStageKind::Vertex => "generated/vertex.glsl",
            ShaderStageKind::Fragment => "generated/fragment.glsl",
        };

        let mut options = glsl::Options::from(stage.into_naga());
        if target == ShaderTarget::MetalMsl {
            // Naga's MSL writer has no matrix `inverse`; the legalized source
            // carries a helper for it that only this macro enables.
            let _previous = options
                .defines
                .insert(MATRIX_INVERSE_POLYFILL_MACRO.to_owned(), "1".to_owned());
        }
        let mut frontend = glsl::Frontend::default();
        let module = frontend.parse(&options, source_text).map_err(|err| {
            let diagnostic = DiagnosticBuilder::new(stage, "naga glsl parse", source_path)
                .with_message(err.emit_to_string_with_path(source_text, source_path))
                .with_source(source_text)
                .with_source_location(
                    err.errors
                        .first()
                        .and_then(|error| error.location(source_text)),
                )
                .build();

            ShaderError::Compile {
                diagnostics: Box::from([diagnostic]),
            }
        })?;

        let mut validator = Validator::new(ValidationFlags::default(), Capabilities::default());
        let module_info = validator.validate(&module).map_err(|err| {
            let diagnostic = DiagnosticBuilder::new(stage, "naga validate", source_path)
                .with_message(err.emit_to_string_with_path(source_text, source_path))
                .with_source(source_text)
                .with_source_location(err.location(source_text))
                .build();

            ShaderError::Compile {
                diagnostics: Box::from([diagnostic]),
            }
        })?;

        let code = match target {
            ShaderTarget::VulkanSpirv => CompiledStageCode::VulkanSpirv(write_spirv(
                stage,
                &module,
                &module_info,
                source_text,
                source_path,
            )?),
            ShaderTarget::MetalMsl => CompiledStageCode::MetalMsl(
                MetalEmitter {
                    stage,
                    module: &module,
                    module_info: &module_info,
                    source_text,
                    source_path,
                }
                .emit()?,
            ),
        };

        let compiled_stage = CompiledShaderStage::new(
            stage,
            code,
            Some(source_text.to_owned()),
            Box::from([]),
        );

        Ok(CompiledStageArtifact::new(
            compiled_stage,
            module,
            Box::from([]),
        ))
    }
}

/// Emits SPIR-V words for one validated Naga module.
fn write_spirv(
    stage: ShaderStageKind,
    module: &naga::Module,
    module_info: &ModuleInfo,
    source_text: &str,
    source_path: &'static str,
) -> ShaderResult<Box<[u32]>> {
    let pipeline_options = spv::PipelineOptions {
        shader_stage: stage.into_naga(),
        entry_point: "main".to_owned(),
    };
    let mut spv_options = spv::Options::default();
    spv_options
        .flags
        .remove(spv::WriterFlags::ADJUST_COORDINATE_SPACE);

    let spirv = spv::write_vec(module, module_info, &spv_options, Some(&pipeline_options)).map_err(
        |err| {
            let diagnostic = DiagnosticBuilder::new(stage, "naga spv write", source_path)
                .with_message(format!(
                    "{err}\n{source_path}\n{}",
                    source_text.lines().next().unwrap_or_default()
                ))
                .with_source(source_text)
                .build();

            ShaderError::Compile {
                diagnostics: Box::from([diagnostic]),
            }
        },
    )?;

    Ok(spirv.into_boxed_slice())
}

impl ShaderStageKind {
    /// Converts this stage into Naga's stage enum.
    #[must_use]
    pub const fn into_naga(self) -> naga::ShaderStage {
        match self {
            Self::Vertex => naga::ShaderStage::Vertex,
            Self::Fragment => naga::ShaderStage::Fragment,
        }
    }
}
