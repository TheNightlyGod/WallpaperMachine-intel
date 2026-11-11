// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The Wallpaper Engine shader dialect (spec part C1): macro expansion, parsing, type
//! inference, implicit conversions and the dialect vocabulary, producing GLSL 450 text that
//! naga's GLSL front end accepts.
//!
//! A stage goes through four steps: its tokens are macro-expanded ([`expand`]), parsed into a
//! tree ([`parse`]), rewritten with types ([`convert`]) and printed ([`print`]). The rewritten
//! tree is part of the result so that later steps (interface layout, resource layout) can work
//! on it instead of on text.

pub mod ast;
pub mod builtins;
mod convert;
pub mod expand;
pub mod parse;
pub mod print;
pub mod ty;
pub mod usage;

use crate::diagnostic::{Diagnostic, Pass, Span};
use crate::lexer::lex;
use crate::request::StageKind;

pub use ast::Module;

/// The first lines of every converted stage (spec 2.2, 3.6).
pub const HEADER: &str = "#version 450\nprecision highp float;\n";

/// A converted stage.
#[derive(Clone, Debug, PartialEq)]
pub struct Converted {
    /// The stage as GLSL 450 text, header included.
    pub text: String,
    /// The rewritten tree the text was printed from.
    pub module: Module,
    /// One informational entry (R100).
    pub diagnostics: Vec<Diagnostic>,
}

fn failure(kind: StageKind, pass: Pass, message: String, start: usize, end: usize) -> Diagnostic {
    let d = Diagnostic::new(message).in_stage(kind).in_pass(pass);
    match Span::new(start, end) {
        Some(s) => d.at(s),
        None => d,
    }
}

/// Parses a stage after macro expansion (R1 to R6).
pub fn parse_stage(kind: StageKind, text: &str) -> Result<(Module, std::collections::HashSet<String>), Vec<Diagnostic>> {
    let tokens = lex(text);
    let expanded = expand::expand(&tokens).map_err(|e| vec![failure(kind, Pass::Parse, e.message, e.start, e.end)])?;
    let taken = convert::collect_identifiers(&expanded);
    let module = parse::parse(&expanded).map_err(|e| vec![failure(kind, Pass::Parse, e.message, e.start, e.end)])?;
    Ok((module, taken))
}

/// What the program's combos decide about the dialect's own types (E-D8).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ConvertOptions {
    /// `BACKBUFFER_MS` is set: `sampler2DBackBuffer` is Wallpaper Engine's `Texture2DMS<float4>`
    /// and `texSample2DBackBuffer` loads sample 0; otherwise it is an ordinary 2D texture.
    pub backbuffer_ms: bool,
    /// The text is this converter's own output, which calls GLSL built-ins: converting it again
    /// changes nothing (R95). It also keeps the generated GLSL vector types valid.
    /// An author's stage never sets it, so calls/types Wallpaper Engine refuses
    /// fail the stage as there (`builtins::WE_REFUSED_GLSL_CALLS`).
    pub glsl_builtins: bool,
}

/// Converts one stage's preprocessed text. A stage either converts completely or fails with
/// diagnostics (E17).
pub fn convert_stage(kind: StageKind, text: &str) -> Result<Converted, Vec<Diagnostic>> {
    convert_stage_with(kind, text, ConvertOptions::default())
}

/// [`convert_stage`] with the options the program's combos decide.
pub fn convert_stage_with(kind: StageKind, text: &str, options: ConvertOptions) -> Result<Converted, Vec<Diagnostic>> {
    let (module, taken) = parse_stage(kind, text)?;
    convert_parsed(kind, module, taken, text, options)
}

/// The GLSL type of a dialect sampler type (`sub_1400D5070`): `sampler2DComparison` is a depth
/// texture with a comparison sampler; `sampler2DBackBuffer` is `Texture2DMS<float4>` under
/// `BACKBUFFER_MS` and an ordinary 2D texture otherwise.
fn glsl_sampler_name(name: &str, options: ConvertOptions) -> Option<&'static str> {
    match name {
        "sampler2DComparison" => Some("sampler2DShadow"),
        "sampler2DBackBuffer" => Some(if options.backbuffer_ms { "sampler2DMS" } else { "sampler2D" }),
        _ => None,
    }
}

/// Gives the dialect's own sampler types their GLSL spelling, in globals and parameters alike.
fn resolve_dialect_samplers(module: &mut Module, options: ConvertOptions) {
    for item in &mut module.items {
        match item {
            ast::Item::Var(d) => {
                if let Some(name) = glsl_sampler_name(&d.ty.name, options) {
                    d.ty.name = name.to_string();
                }
            }
            ast::Item::Function(f) => {
                for p in &mut f.params {
                    if let Some(name) = glsl_sampler_name(&p.ty.name, options) {
                        p.ty.name = name.to_string();
                    }
                }
            }
            _ => {}
        }
    }
}

/// Converts a stage that [`parse_stage`] parsed (and that the caller may have adjusted, as the
/// interface part does when it reconciles the width of a varying). `text` is the stage text the
/// tree came from; it is only used for the informational diagnostic.
pub fn convert_parsed(
    kind: StageKind,
    mut module: Module,
    taken: std::collections::HashSet<String>,
    text: &str,
    options: ConvertOptions,
) -> Result<Converted, Vec<Diagnostic>> {
    resolve_dialect_samplers(&mut module, options);
    let mut module = convert::convert(module, kind, taken, options)?;
    // The header already declares the default precision; a stage that restates it (as a
    // converted stage does) is not given a second copy.
    module.items.retain(|i| !matches!(i, ast::Item::Precision(p) if p == "precision highp float"));
    let mut out = String::from(HEADER);
    out.push_str(&print::module_to_string(&module));
    Ok(Converted { text: out, module, diagnostics: vec![Diagnostic::codegen_info(kind, text)] })
}

#[cfg(test)]
pub(crate) mod tests;
