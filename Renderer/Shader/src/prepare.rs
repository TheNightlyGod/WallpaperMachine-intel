// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The front end of the pipeline for one program: preprocessing both stages,
//! deciding the combos that are compiled, and extracting the metadata that is
//! reported (spec 2.3, P1 to P5, R73).
//!
//! The protocol, in this crate's own order:
//!
//! 1. Each stage is preprocessed in metadata-preserving mode with the request
//!    combos alone. That view decides which includes are read, and it is what
//!    the reported metadata is extracted from (P4, Q16).
//! 2. The texture-switch scan (R70) over the view gives *texture-derived*
//!    combos. They are known before the evaluated text is produced, so a
//!    texture switch declared inside the very branch it enables works (P2).
//! 3. The evaluated text is produced for request plus texture-derived combos,
//!    and full extraction over that text (inactive branches already gone) gives
//!    the annotation defaults that apply (P1, P3). Each discovered combo is
//!    added only if no combo of that name exists, ignoring case: the request
//!    always wins.
//! 4. The evaluated text is produced once more for the final combo list
//!    (skipped when nothing was added). One round only: a default reachable
//!    only through another default of the same round is not applied (Q4).
//!
//! The order of the combo definitions in the compiled text is: request combos
//! in request order, then texture-derived combos, then annotation defaults,
//! each in stage order and first-seen order.

use crate::diagnostic::Diagnostic;
use crate::error::ShaderError;
use crate::items::{BraceMode, scan_items};
use crate::lexer::lex;
use crate::metadata::{ExtractMode, extract};
use crate::preprocess::{MacroFacts, Mode, preprocess_stage};
use crate::request::{Combo, StageKind, ValidRequest};
use crate::response::Metadata;
use crate::source::{CachingSource, IncludeSource};

/// One stage after preprocessing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreparedStage {
    pub kind: StageKind,
    /// The text that is compiled (R15).
    pub evaluated: String,
    /// Macro values known before the first ordinary line of `evaluated` (R38).
    pub macros: MacroFacts,
    /// The metadata-preserving text (R29), built with the request combos only.
    pub view: String,
    /// The preprocessor's non-fatal diagnostics for `evaluated`.
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedProgram {
    /// In request stage order.
    pub stages: Vec<PreparedStage>,
    /// The combos the evaluated text was produced for: request plus discovered.
    pub compile_combos: Vec<Combo>,
    /// The reported metadata (P4): the stages' lists concatenated, without active texture slots.
    pub metadata: Metadata,
    /// The distinct include paths asked of the source, in first-asked order.
    pub includes_read: Vec<String>,
}

fn add_if_absent(list: &mut Vec<Combo>, name: &str, value: &str) {
    if !list.iter().any(|c| c.name.eq_ignore_ascii_case(name)) {
        list.push(Combo { name: name.to_string(), value: value.to_string() });
    }
}

/// Runs the protocol above for a validated request.
pub fn prepare_program(request: &ValidRequest, includes: &dyn IncludeSource) -> Result<PreparedProgram, ShaderError> {
    let name = request.shader_name();
    let cache = CachingSource::new(includes);
    let textures = request.textures();

    // 1 and 2: the view with the request combos, the reported metadata, the texture switches.
    let mut views = Vec::new();
    let mut reported = Metadata::default();
    let mut compile_combos: Vec<Combo> = request.combos().to_vec();
    for stage in request.stages() {
        let view = preprocess_stage(stage.kind, &stage.source, request.combos(), &cache, Mode::MetadataPreserving)
            .map_err(|e| e.into_shader_error(name))?;
        let tokens = lex(&view.text);
        let items = scan_items(&tokens, &view.text, BraceMode::Conditional)
            .map_err(|e| e.into_shader_error(stage.kind, name, &view.text))?;
        let full = extract(&items, &view.text, textures, ExtractMode::Full)?;
        let switches = extract(&items, &view.text, textures, ExtractMode::TextureSwitchOnly)?;
        for c in &switches.combos {
            add_if_absent(&mut compile_combos, &c.name, &c.value);
        }
        reported.combos.extend(full.combos);
        reported.aliases.extend(full.aliases);
        reported.default_uniforms.extend(full.default_uniforms);
        reported.default_textures.extend(full.default_textures);
        views.push(view.text);
    }

    // 3: evaluated text for request plus texture-derived combos; annotation defaults that survive.
    let mut discovered: Vec<(String, String)> = Vec::new();
    let mut first_pass = Vec::new();
    for stage in request.stages() {
        let evaluated = preprocess_stage(stage.kind, &stage.source, &compile_combos, &cache, Mode::Evaluated)
            .map_err(|e| e.into_shader_error(name))?;
        let tokens = lex(&evaluated.text);
        let items = scan_items(&tokens, &evaluated.text, BraceMode::Compiled)
            .map_err(|e| e.into_shader_error(stage.kind, name, &evaluated.text))?;
        let found = extract(&items, &evaluated.text, textures, ExtractMode::Full)?;
        discovered.extend(found.combos.into_iter().map(|c| (c.name, c.value)));
        first_pass.push(evaluated);
    }
    let before = compile_combos.len();
    for (n, v) in &discovered {
        add_if_absent(&mut compile_combos, n, v);
    }
    let changed = compile_combos.len() != before;

    // 4: the final text.
    let mut stages = Vec::new();
    for ((stage, view), earlier) in request.stages().iter().zip(views).zip(first_pass) {
        let evaluated = if changed {
            preprocess_stage(stage.kind, &stage.source, &compile_combos, &cache, Mode::Evaluated)
                .map_err(|e| e.into_shader_error(name))?
        } else {
            earlier
        };
        stages.push(PreparedStage {
            kind: stage.kind,
            evaluated: evaluated.text,
            macros: evaluated.macros,
            view,
            diagnostics: evaluated.diagnostics,
        });
    }
    Ok(PreparedProgram { stages, compile_combos, metadata: reported, includes_read: cache.paths_read() })
}

#[cfg(test)]
mod tests;
