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

/// Converts one stage's preprocessed text. A stage either converts completely or fails with
/// diagnostics (E17).
pub fn convert_stage(kind: StageKind, text: &str) -> Result<Converted, Vec<Diagnostic>> {
    let (module, taken) = parse_stage(kind, text)?;
    convert_parsed(kind, module, taken, text)
}

/// Converts a stage that [`parse_stage`] parsed (and that the caller may have adjusted, as the
/// interface part does when it reconciles the width of a varying). `text` is the stage text the
/// tree came from; it is only used for the informational diagnostic.
pub fn convert_parsed(
    kind: StageKind,
    module: Module,
    taken: std::collections::HashSet<String>,
    text: &str,
) -> Result<Converted, Vec<Diagnostic>> {
    let mut module = convert::convert(module, kind, taken)?;
    // The header already declares the default precision; a stage that restates it (as a
    // converted stage does) is not given a second copy.
    module.items.retain(|i| !matches!(i, ast::Item::Precision(p) if p == "precision highp float"));
    let mut out = String::from(HEADER);
    out.push_str(&print::module_to_string(&module));
    Ok(Converted { text: out, module, diagnostics: vec![Diagnostic::codegen_info(kind, text)] })
}

#[cfg(test)]
pub(crate) mod tests;
