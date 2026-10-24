// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The failures of the interface and resource part (spec C2, section 2.2 and 5).
//!
//! Two classes carry diagnostics (a failure inside one stage, a failure of the interface
//! between the stages); the third, "invalid request", is a program-level resource or
//! interface conflict whose message the request side reports.

use std::fmt;
use std::ops::Range;

use crate::diagnostic::{Diagnostic, Pass, Span};
use crate::error::{FailedDiagnostic, ShaderError};
use crate::request::{RequestError, StageKind};
use crate::uniforms::UniformError;

/// The origin label of a cross-stage interface failure (D R10, R13).
pub const CROSS_STAGE_ORIGIN: &str = "cross-stage interface check";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LegalizeError {
    /// A stage-local legalisation error (codegen pass).
    StageLocal(Diagnostic),
    /// A cross-stage interface error (codegen pass).
    CrossStage(Diagnostic),
    /// A program-level conflict: "invalid request".
    Request(String),
    /// A uniform member that cannot be declared: "invalid request" with the contract's wording.
    Uniform(UniformError),
    /// The dialect front end refused a stage.
    Front(Vec<Diagnostic>),
}

fn diagnostic(kind: StageKind, span: Option<Range<usize>>, message: String) -> Diagnostic {
    let d = Diagnostic::new(message).in_stage(kind).in_pass(Pass::Codegen);
    match span.and_then(|s| Span::new(s.start, s.end)) {
        Some(s) => d.at(s),
        None => d,
    }
}

impl LegalizeError {
    pub(crate) fn stage_local(kind: StageKind, span: Option<Range<usize>>, message: impl Into<String>) -> LegalizeError {
        LegalizeError::StageLocal(diagnostic(kind, span, message.into()))
    }

    pub(crate) fn cross_stage(kind: StageKind, span: Option<Range<usize>>, message: impl Into<String>) -> LegalizeError {
        LegalizeError::CrossStage(diagnostic(kind, span, message.into()).in_origin(CROSS_STAGE_ORIGIN))
    }

    pub(crate) fn request(message: impl Into<String>) -> LegalizeError {
        LegalizeError::Request(message.into())
    }

    /// The message text of the (first) failure, without any layout.
    pub fn message(&self) -> String {
        match self {
            LegalizeError::StageLocal(d) | LegalizeError::CrossStage(d) => d.message.clone(),
            LegalizeError::Request(m) => m.clone(),
            LegalizeError::Uniform(e) => e.to_string(),
            LegalizeError::Front(list) => list.first().map(|d| d.message.clone()).unwrap_or_default(),
        }
    }

    /// The diagnostics the failure carries (none for a program-level request failure).
    pub fn diagnostics(&self) -> Vec<Diagnostic> {
        match self {
            LegalizeError::StageLocal(d) | LegalizeError::CrossStage(d) => vec![d.clone()],
            LegalizeError::Front(list) => list.clone(),
            LegalizeError::Request(_) | LegalizeError::Uniform(_) => Vec::new(),
        }
    }

    /// True for the "invalid request" class.
    pub fn is_invalid_request(&self) -> bool {
        matches!(self, LegalizeError::Request(_) | LegalizeError::Uniform(_))
    }

    /// True when the failure is a cross-stage interface error.
    pub fn is_cross_stage(&self) -> bool {
        matches!(self, LegalizeError::CrossStage(_))
    }
}

impl fmt::Display for LegalizeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for LegalizeError {}

impl From<LegalizeError> for ShaderError {
    fn from(e: LegalizeError) -> ShaderError {
        match e {
            LegalizeError::Request(m) => ShaderError::Request(RequestError::Program(m)),
            LegalizeError::Uniform(u) => ShaderError::Uniform(u),
            LegalizeError::StageLocal(d) | LegalizeError::CrossStage(d) => {
                ShaderError::Source { shader_name: None, failures: vec![FailedDiagnostic::without_source(d)] }
            }
            LegalizeError::Front(list) => ShaderError::Source {
                shader_name: None,
                failures: list.into_iter().map(FailedDiagnostic::without_source).collect(),
            },
        }
    }
}
