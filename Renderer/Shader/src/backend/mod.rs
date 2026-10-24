// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The backend (spec D, 4.5): turns the legalized GLSL of one stage into Metal Shading
//! Language through naga, and reports the Metal binding map.
//!
//! The steps, in the order a failure is reported:
//!
//! 1. the GLSL front end reads the text as a module of the requested stage (R39, R40);
//! 2. the module must have an entry point of that stage (R42);
//! 3. every resource global gets a Metal slot, by rank within its namespace (R45 to R47);
//! 4. the module is validated with every flag and naga's default capabilities (R41);
//! 5. the Metal writer runs for exactly that entry point with an explicit resource map and no
//!    bounds-check, vertex-pulling or compatibility options (R42, R43).
//!
//! The slots come before validation so that a resource the Metal target cannot take is
//! reported as such even when it would also fail the default capability set.

use std::ops::Range;

use naga::back::msl;
use naga::front::glsl::{Frontend, Options as GlslOptions};
use naga::valid::{Capabilities, ModuleInfo, ValidationFlags, Validator};

use crate::binding::{Binding, BindingError, SlotKind, StageResource, assign_stage_slots};
use crate::diagnostic::{Diagnostic, Pass, Span, generated_source_label};
use crate::error::{FailedDiagnostic, ShaderError};
use crate::identity::MSL_LANGUAGE_VERSION;
use crate::legalize::LegalStage;
use crate::nagair::{ResourceClass, classify, error_chain, resource_name};
use crate::request::{RequestError, StageKind};
use crate::response::StagePayload;

pub mod depth;

#[cfg(test)]
pub(crate) mod tests;

/// The language version the Metal writer targets, as the writer takes it.
pub const MSL_VERSION: (u8, u8) = (2, 0);

/// A translated module, kept so reflection can read it (D R53).
#[derive(Debug)]
pub struct TranslatedModule {
    pub module: naga::Module,
    /// The result of validating `module` with every flag and the default capabilities.
    pub info: ModuleInfo,
}

/// What a backend returns for one stage.
#[derive(Debug)]
pub struct CompiledStage {
    pub payload: StagePayload,
    /// The module the payload was written from. A substituted compiler has none.
    pub translated: Option<TranslatedModule>,
    /// The backend's own diagnostics (none on success today).
    pub diagnostics: Vec<Diagnostic>,
}

/// A step of the pipeline that can be replaced (D R6): turns a legalized stage into a payload.
pub trait StageCompiler: Sync {
    fn compile(&self, requested: StageKind, stage: &LegalStage) -> Result<CompiledStage, ShaderError>;
}

/// The default compiler: naga's GLSL front end, validator and Metal writer.
#[derive(Clone, Copy, Debug, Default)]
pub struct NagaBackend;

impl StageCompiler for NagaBackend {
    fn compile(&self, requested: StageKind, stage: &LegalStage) -> Result<CompiledStage, ShaderError> {
        if stage.kind != requested {
            return Err(RequestError::Program(format!(
                "a legalized {} source cannot be compiled as the {} stage",
                stage.kind.name(),
                requested.name()
            ))
            .into());
        }
        compile_glsl(requested, &stage.text)
    }
}

fn naga_stage(kind: StageKind) -> naga::ShaderStage {
    match kind {
        StageKind::Vertex => naga::ShaderStage::Vertex,
        StageKind::Fragment => naga::ShaderStage::Fragment,
    }
}

/// Reads the legalized text of `kind` and translates it (R39 to R52).
pub fn compile_glsl(kind: StageKind, glsl: &str) -> Result<CompiledStage, ShaderError> {
    // The downstream compiler recurses over nesting; a text it could not read on a small stack
    // is refused before it is handed over (R91).
    let cost = depth::stack_cost(glsl);
    if cost > depth::STACK_BUDGET {
        return Err(failure(
            kind,
            Pass::GlslParse,
            format!(
                "the {} source nests brackets or chains operators too deeply to translate (depth measure {cost}, limit {})",
                kind.name(),
                depth::STACK_BUDGET
            ),
            None,
            glsl,
        ));
    }
    let nesting = depth::struct_depth(glsl);
    if nesting > depth::STRUCT_DEPTH_LIMIT {
        return Err(failure(
            kind,
            Pass::GlslParse,
            format!(
                "the {} source nests structure types too deeply to translate (depth {nesting}, limit {})",
                kind.name(),
                depth::STRUCT_DEPTH_LIMIT
            ),
            None,
            glsl,
        ));
    }
    let mut front = Frontend::default();
    let module = front.parse(&GlslOptions::from(naga_stage(kind)), glsl).map_err(|errors| {
        let first = errors.errors.first();
        let explanation: Vec<String> = errors.errors.iter().take(8).map(|e| e.kind.to_string()).collect();
        let span = first.and_then(|e| e.meta.to_range());
        let message = format!("GLSL parse failed: {}", explanation.join("; "));
        failure(kind, Pass::GlslParse, message, span, glsl)
    })?;
    translate_module(kind, module, glsl)
}

/// Translates a module that is already built (the front end is not involved): used by
/// [`compile_glsl`] and by callers that hold naga's own IR. `glsl` is only the text diagnostics
/// refer to.
pub fn translate_module(kind: StageKind, module: naga::Module, glsl: &str) -> Result<CompiledStage, ShaderError> {
    let stage = naga_stage(kind);
    let Some(entry) = module.entry_points.iter().find(|e| e.stage == stage) else {
        return Err(ShaderError::NoEntryPoint { stage: kind });
    };
    let entry_name = entry.name.clone();

    let (bindings, map) = resource_map(kind, &module, glsl)?;

    let info = Validator::new(ValidationFlags::all(), Capabilities::default()).validate(&module).map_err(|e| {
        let chain = error_chain(e.as_inner());
        let span = e.spans().next().and_then(|(s, _)| s.to_range());
        failure(kind, Pass::Validate, format!("validation failed: {chain}"), span, glsl)
    })?;

    let mut per_entry_point_map = msl::EntryPointResourceMap::new();
    per_entry_point_map.insert(entry_name.clone(), msl::EntryPointResources { resources: map, ..Default::default() });
    let options = msl::Options {
        lang_version: MSL_VERSION,
        per_entry_point_map,
        fake_missing_bindings: false,
        ..msl::Options::default()
    };
    let pipeline = msl::PipelineOptions { entry_point: Some((stage, entry_name)), ..msl::PipelineOptions::default() };
    let (text, written) = msl::write_string(&module, &info, &options, &pipeline)
        .map_err(|e| failure(kind, Pass::MslWrite, format!("the Metal writer failed: {e}"), None, glsl))?;
    let name = match written.entry_point_names.into_iter().next() {
        Some(Ok(name)) => name,
        Some(Err(e)) => {
            return Err(failure(
                kind,
                Pass::MslWrite,
                format!("the entry point reads a resource global the resource map has no record for: {e}"),
                None,
                glsl,
            ));
        }
        None => return Err(ShaderError::NoEntryPoint { stage: kind }),
    };
    debug_assert_eq!(format!("{}.{}", MSL_VERSION.0, MSL_VERSION.1), MSL_LANGUAGE_VERSION);
    Ok(CompiledStage {
        payload: StagePayload::new(kind, text, name, bindings),
        translated: Some(TranslatedModule { module, info }),
        diagnostics: Vec::new(),
    })
}

/// A failure of the backend: one diagnostic against the generated text of the stage, with that
/// text attached so the rendering can show the offending line (R40).
fn failure(kind: StageKind, pass: Pass, message: String, span: Option<Range<usize>>, glsl: &str) -> ShaderError {
    let mut message = message;
    let mut located = None;
    if let Some(range) = span.as_ref().filter(|r| r.start <= glsl.len() && glsl.is_char_boundary(r.start)) {
        let before = &glsl[..range.start];
        let line = before.matches('\n').count() + 1;
        let text = glsl.lines().nth(line - 1).unwrap_or("").trim();
        message.push_str(&format!(" (in {}, line {line}: `{text}`)", generated_source_label(kind)));
        located = Span::new(range.start, range.end.max(range.start));
    }
    let mut diagnostic = Diagnostic::new(message).in_generated_source(kind).in_pass(pass);
    if let Some(span) = located {
        diagnostic = diagnostic.at(span);
    }
    ShaderError::Source { shader_name: None, failures: vec![FailedDiagnostic::new(diagnostic, glsl)] }
}

/// The records of the stage's binding map and the writer's resource map built from them
/// (D R45 to R47): every resource global, used or not, in declaration order.
fn resource_map(kind: StageKind, module: &naga::Module, glsl: &str) -> Result<(Vec<Binding>, msl::BindingMap), ShaderError> {
    let mut resources: Vec<StageResource> = Vec::new();
    for (_, var) in module.global_variables.iter() {
        let name = resource_name(module, var);
        let slot_kind = match classify(module, var) {
            ResourceClass::NotAResource => continue,
            ResourceClass::UniformBuffer | ResourceClass::StorageBuffer => SlotKind::Buffer,
            ResourceClass::SampledImage | ResourceClass::StorageImage => SlotKind::Texture,
            ResourceClass::Sampler => SlotKind::Sampler,
            ResourceClass::Immediate => {
                return Err(unmappable(kind, format!(
                    "metal binding map cannot cover global {}: it is immediate (push-constant) data, which the host cannot bind",
                    crate::text::quote(&name)
                ), glsl));
            }
            ResourceClass::Unsupported(what) => {
                return Err(unmappable(kind, format!(
                    "metal binding map cannot cover global {}: it is {what}, which the Metal target does not support",
                    crate::text::quote(&name)
                ), glsl));
            }
        };
        let (set, binding) = match &var.binding {
            Some(b) => (b.group, Some(b.binding)),
            None => (0, None),
        };
        resources.push(StageResource { name, set, binding, kind: slot_kind });
    }
    let bindings = assign_stage_slots(&resources).map_err(|e| match e {
        BindingError::SlotLimit { .. } => ShaderError::Binding(e),
        other => unmappable(kind, other.to_string(), glsl),
    })?;
    let mut map = msl::BindingMap::new();
    for b in &bindings {
        let target = map.entry(naga::ResourceBinding { group: b.set, binding: b.binding }).or_default();
        let slot = u8::try_from(b.slot).expect("slots are limited to 127");
        match b.slot_kind {
            SlotKind::Buffer => target.buffer = Some(slot),
            SlotKind::Texture => target.texture = Some(slot),
            SlotKind::Sampler => target.sampler = Some(msl::BindSamplerTarget::Resource(slot)),
        }
    }
    Ok((bindings, map))
}

fn unmappable(kind: StageKind, message: String, glsl: &str) -> ShaderError {
    failure(kind, Pass::MslWrite, message, None, glsl)
}
