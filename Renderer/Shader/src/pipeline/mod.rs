// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The program pipeline (spec D, 4.1 and 4.4): one request in, one compiled program out.
//!
//! The steps, in the order a failure stops the compile (R5):
//!
//! 1. combos, includes and metadata ([`crate::prepare`]): the stage texts for the final combos;
//! 2. both stages are legalized together ([`crate::legalize`]) so the varying interface and the
//!    resource layout are decided once for the program (R4, R9 to R32);
//! 3. each stage, in request order, is compiled by the [`StageCompiler`] and described by the
//!    [`StageReflector`];
//! 4. the stage reflections are merged (R33), the metadata gets the active texture slots (R34),
//!    and the cache key is computed (R35).
//!
//! The compiler and the reflector are parameters (R6): the layout, merging and key behaviour of
//! the pipeline is tested without naga by substituting both.

use crate::backend::{NagaBackend, StageCompiler};
use crate::cache_key::{ProgramKeyInput, StageKeyInput, program_key};
use crate::diagnostic::Diagnostic;
use crate::error::{FailedDiagnostic, ShaderError};
use crate::legalize::{BlockPlan, LegalizeError, LegalProgram, ProgramInput, legalize};
use crate::prepare::{PreparedProgram, prepare_program};
use crate::reflect::{InputNames, NagaReflector, StageReflector};
use crate::reflection::{Reflection, ReflectionError};
use crate::request::{Combo, RequestError, StageKind, ValidRequest};
use crate::response::{Metadata, StagePayload};
use crate::source::IncludeSource;
use crate::uniforms::UniformType;

#[cfg(test)]
pub(crate) mod tests;

/// One compiled stage of a program.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramStage {
    pub kind: StageKind,
    /// The Metal stage code: MSL text, entry point, language version, binding records and
    /// conventions (R52).
    pub payload: StagePayload,
    /// The legalized GLSL the payload was compiled from, retained as text (R1, R52).
    pub glsl: String,
    /// Diagnostic storage types from this stage's original translated module, not merged
    /// author-facing component counts. Entirely absent in normal builds.
    #[cfg(feature = "observer-uniform-layout")]
    pub uniform_layout: crate::observer_uniform_layout::StageUniformLayout,
}

/// A compiled program (spec D 2.2).
#[derive(Clone, Debug, PartialEq)]
pub struct CompiledProgram {
    /// The request's shader name.
    pub name: String,
    /// The cache key of R35.
    pub cache_key: String,
    /// In the request's stage order (R1).
    pub stages: Vec<ProgramStage>,
    /// The combos the stages were compiled for: the request's plus the discovered defaults (R2).
    pub combos: Vec<Combo>,
    /// Combos, aliases, default uniforms and textures, and the active texture slots (R3, R34).
    pub metadata: Metadata,
    /// The merged reflection of the stages (R33).
    pub reflection: Reflection,
    /// Per stage in request order: the preprocessor's non-fatal entries, then the legalizer's, then
    /// the backend's (R5, R36).
    pub diagnostics: Vec<Diagnostic>,
}

impl CompiledProgram {
    pub fn stage(&self, kind: StageKind) -> Option<&ProgramStage> {
        self.stages.iter().find(|s| s.kind == kind)
    }
}

/// The replaceable steps of the pipeline.
#[derive(Clone, Copy)]
pub struct Pipeline<'a> {
    pub compiler: &'a dyn StageCompiler,
    pub reflector: &'a dyn StageReflector,
}

impl Pipeline<'static> {
    /// The default pipeline: naga's Metal backend and the naga reflector.
    pub fn metal() -> Pipeline<'static> {
        Pipeline { compiler: &NagaBackend, reflector: &NagaReflector }
    }
}

/// Compiles a request for Metal with the default pipeline.
pub fn compile(request: &ValidRequest, includes: &dyn IncludeSource) -> Result<CompiledProgram, ShaderError> {
    Pipeline::metal().compile(request, includes)
}

impl Pipeline<'_> {
    /// Compiles a request with this pipeline's steps. Stops at the first error and returns no
    /// program (section 5).
    pub fn compile(&self, request: &ValidRequest, includes: &dyn IncludeSource) -> Result<CompiledProgram, ShaderError> {
        let name = request.shader_name();
        let prepared = prepare_program(request, includes)?;
        let legal = legalize_program(request, &prepared, name)?;

        let names = InputNames::from_pairs(
            legal.layout.vertex_inputs.iter().map(|i| (i.emitted_name.as_str(), i.name.as_str())),
        );
        let mut stages = Vec::new();
        let mut reflections = Vec::new();
        let mut diagnostics = Vec::new();
        let mut key_stages = Vec::new();
        for requested in request.stages() {
            let kind = requested.kind;
            let legal_stage = legal.stage(kind).expect("both stages are legalized");
            let compiled = self.compiler.compile(kind, legal_stage).map_err(|e| e.named(name))?;
            let mut reflection = self.reflector.reflect(kind, &compiled, &names).map_err(|e| e.named(name))?;
            // Retain while the exact translated module and its validation are still owned.
            // Diagnostic selection shares the reflector's entry/resource helpers; unavailable
            // metadata is not a shader failure and never changes ordinary reflection.
            #[cfg(feature = "observer-uniform-layout")]
            let uniform_layout = crate::observer_uniform_layout::retain(kind, &compiled);
            if let Some(plan) = &legal.layout.block {
                restore_author_element_counts(&mut reflection, plan);
            }
            let prepared_stage = prepared.stages.iter().find(|s| s.kind == kind).expect("both stages are prepared");
            diagnostics.extend(prepared_stage.diagnostics.iter().cloned());
            diagnostics.extend(legal_stage.diagnostics.iter().cloned());
            diagnostics.extend(compiled.diagnostics.iter().cloned());
            key_stages.push((kind, prepared_stage.evaluated.as_str(), legal_stage.text.as_str()));
            reflections.push(reflection);
            stages.push(ProgramStage {
                kind,
                payload: compiled.payload,
                glsl: legal_stage.text.clone(),
                #[cfg(feature = "observer-uniform-layout")]
                uniform_layout,
            });
        }

        // Two stages that disagree about a block they share are a request the layer cannot
        // describe (D R33); the other merge failures are reflection errors.
        let reflection = Reflection::merge(&reflections).map_err(|e| match e {
            ReflectionError::ConflictingBlock { .. } => ShaderError::Request(RequestError::Program(e.to_string())),
            other => ShaderError::Reflection(other),
        })?;
        let mut metadata = prepared.metadata.clone();
        metadata.active_texture_slots = reflection.active_texture_slots.clone();

        let key_inputs: Vec<StageKeyInput<'_>> = key_stages
            .iter()
            .map(|(kind, preprocessed, translated_glsl)| StageKeyInput { kind: *kind, preprocessed, translated_glsl })
            .collect();
        let cache_key = program_key(&ProgramKeyInput {
            request,
            effective_combos: &prepared.compile_combos,
            stages: &key_inputs,
        });
        Ok(CompiledProgram {
            name: name.to_string(),
            cache_key,
            stages,
            combos: prepared.compile_combos,
            metadata,
            reflection,
            diagnostics,
        })
    }
}

/// A two-row matrix is stored with four rows (the block's std140 columns are 16 bytes wide), so
/// the module reports eight components for a `mat2`; reflection reports the author's four (R99).
fn restore_author_element_counts(reflection: &mut Reflection, plan: &BlockPlan) {
    for block in reflection.uniform_blocks.iter_mut().filter(|b| b.name == crate::names::GLOBAL_UNIFORMS) {
        for member in &mut block.members {
            if let Some(p) = plan.members.iter().find(|p| p.name == member.name)
                && matches!(p.ty, UniformType::Matrix { rows: 2, .. })
            {
                member.element_count = p.ty.element_count();
            }
        }
    }
}

/// Legalizes both stages of the request together (R4).
fn legalize_program(request: &ValidRequest, prepared: &PreparedProgram, name: &str) -> Result<LegalProgram, ShaderError> {
    let text_of = |kind: StageKind| -> &str {
        prepared.stages.iter().find(|s| s.kind == kind).map(|s| s.evaluated.as_str()).unwrap_or_default()
    };
    let planar = request.planar_slots();
    let input = ProgramInput {
        vertex: Some(text_of(StageKind::Vertex)),
        fragment: Some(text_of(StageKind::Fragment)),
        planar_slots: &planar,
        // The model's highest binding is reflection's to enforce (D R60, R61): a texture the
        // stage uses above it is a reflection error, one it only declares is no error.
        unlimited_bindings: true,
    };
    legalize(&input).map_err(|e| legalize_failure(e, name, text_of))
}

/// A legalization failure with the text its spans refer to, so the failure text can show the
/// offending line, and with the shader name.
fn legalize_failure<'a>(error: LegalizeError, name: &str, text_of: impl Fn(StageKind) -> &'a str) -> ShaderError {
    let with_source = |mut d: Diagnostic| {
        let source = d.stage.map(|s| text_of(s).to_string());
        if d.origin.is_none() {
            let which = d.stage.map_or("stage", |s| s.name());
            d.origin = Some(format!("preprocessed {which} source"));
        }
        FailedDiagnostic { diagnostic: d, source }
    };
    match error {
        LegalizeError::StageLocal(d) | LegalizeError::CrossStage(d) => {
            ShaderError::source_failure(name, vec![with_source(d)])
        }
        LegalizeError::Front(list) => ShaderError::source_failure(name, list.into_iter().map(with_source).collect()),
        other => ShaderError::from(other),
    }
}
