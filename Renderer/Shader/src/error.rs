// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The failure type of a compile and its plain-text form (R70 to R72).
//!
//! `Display` is the "last error" text: plain UTF-8, no terminal colour codes,
//! carrying every fact the layer has. A failure that carries several
//! diagnostics includes all of them, one block each, in the order produced.

use std::any::Any;
use std::fmt;

use crate::binding::BindingError;
use crate::diagnostic::{Diagnostic, RenderContext};
use crate::include::IncludeError;
use crate::reflection::ReflectionError;
use crate::request::{RequestError, StageKind};
use crate::text::{quote, sanitize};
use crate::uniforms::UniformError;

/// A diagnostic together with the text its span refers to, so it can be
/// rendered with an excerpt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FailedDiagnostic {
    pub diagnostic: Diagnostic,
    pub source: Option<String>,
}

impl FailedDiagnostic {
    pub fn new(diagnostic: Diagnostic, source: impl Into<String>) -> FailedDiagnostic {
        FailedDiagnostic { diagnostic, source: Some(source.into()) }
    }

    pub fn without_source(diagnostic: Diagnostic) -> FailedDiagnostic {
        FailedDiagnostic { diagnostic, source: None }
    }
}

/// The class of a failure (D section 5): the distinctions the callers and the tests rely on,
/// whatever the variant that carries the facts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCategory {
    /// The request, or a program-level rule about it, is violated.
    InvalidRequest,
    /// An include file could not be read.
    SourceRead,
    /// Includes, conditionals or macros of a stage.
    Preprocess,
    /// A rule found by the dialect conversion, the legalizer or the cross-stage analysis.
    Legalization,
    /// The downstream compiler's front end, validation or Metal writer failed.
    Compile,
    /// A translated module cannot be described, or does not fit the host's tables.
    Reflection,
    /// A bug-induced panic caught at the boundary.
    Internal,
}

/// Why a compile failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShaderError {
    /// The request could not be read or did not validate.
    Request(RequestError),
    /// An include could not be used.
    Include(IncludeError),
    /// Preprocessing, parsing, code generation or the downstream compiler
    /// failed in a way that has positions: one or more diagnostics.
    Source { shader_name: Option<String>, failures: Vec<FailedDiagnostic> },
    /// A stage defines no `main` (R105).
    NoEntryPoint { stage: StageKind },
    Uniform(UniformError),
    Binding(BindingError),
    Reflection(ReflectionError),
    /// A default uniform value that is not a finite number cannot be written (2.6.2).
    NonFiniteDefault { name: String },
    /// A bug-induced panic caught at the boundary (R4).
    Internal { message: Option<String> },
}

impl ShaderError {
    /// The class of this failure.
    pub fn category(&self) -> ErrorCategory {
        use crate::diagnostic::Pass;
        match self {
            ShaderError::Request(_) | ShaderError::Uniform(_) | ShaderError::NonFiniteDefault { .. } => {
                ErrorCategory::InvalidRequest
            }
            ShaderError::Include(_) => ErrorCategory::SourceRead,
            ShaderError::Source { failures, .. } => {
                match failures.first().and_then(|f| f.diagnostic.pass) {
                    Some(Pass::Preprocess) => ErrorCategory::Preprocess,
                    Some(Pass::Parse | Pass::Legalize | Pass::Codegen) | None => ErrorCategory::Legalization,
                    Some(Pass::GlslParse | Pass::Validate | Pass::MslWrite) => ErrorCategory::Compile,
                    Some(Pass::Binding | Pass::Reflection) => ErrorCategory::Reflection,
                }
            }
            ShaderError::NoEntryPoint { .. } => ErrorCategory::Compile,
            ShaderError::Binding(_) | ShaderError::Reflection(_) => ErrorCategory::Reflection,
            ShaderError::Internal { .. } => ErrorCategory::Internal,
        }
    }

    /// Fills in the shader name of a source failure that does not carry one yet, so the
    /// rendered text names it (2.4).
    pub fn named(mut self, name: &str) -> ShaderError {
        if let ShaderError::Source { shader_name, .. } = &mut self
            && shader_name.is_none()
        {
            *shader_name = Some(name.to_string());
        }
        self
    }

    /// A failure made of diagnostics, tagged with the shader's normalised name.
    pub fn source_failure(shader_name: &str, failures: Vec<FailedDiagnostic>) -> ShaderError {
        ShaderError::Source { shader_name: Some(shader_name.to_string()), failures }
    }

    /// Turns a caught panic payload into a failure that says the layer failed
    /// internally and, when the panic carried a message, includes it (R4).
    pub fn from_panic(payload: Box<dyn Any + Send>) -> ShaderError {
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_string())
            .or_else(|| payload.downcast_ref::<String>().cloned());
        ShaderError::Internal { message }
    }
}

macro_rules! impl_from {
    ($($ty:ty => $variant:ident),* $(,)?) => {
        $(impl From<$ty> for ShaderError {
            fn from(e: $ty) -> ShaderError {
                ShaderError::$variant(e)
            }
        })*
    };
}

impl_from! {
    RequestError => Request,
    IncludeError => Include,
    UniformError => Uniform,
    BindingError => Binding,
    ReflectionError => Reflection,
}

impl fmt::Display for ShaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            ShaderError::Request(e) => e.to_string(),
            ShaderError::Include(e) => e.to_string(),
            ShaderError::Source { shader_name, failures } => {
                if failures.is_empty() {
                    "shader failed without a diagnostic".to_string()
                } else {
                    let blocks: Vec<String> = failures
                        .iter()
                        .map(|failure| {
                            failure.diagnostic.render(&RenderContext {
                                shader_name: shader_name.as_deref(),
                                source: failure.source.as_deref(),
                            })
                        })
                        .collect();
                    blocks.join("\n")
                }
            }
            ShaderError::NoEntryPoint { stage } => format!(
                "the {} stage has no entry point: its source defines no `main` function",
                stage.name()
            ),
            ShaderError::Uniform(e) => e.to_string(),
            ShaderError::Binding(e) => e.to_string(),
            ShaderError::Reflection(e) => e.to_string(),
            ShaderError::NonFiniteDefault { name } => {
                format!("the default value of uniform {} is not a finite number", quote(name))
            }
            ShaderError::Internal { message: None } => "the shader layer failed internally".to_string(),
            ShaderError::Internal { message: Some(m) } => {
                format!("the shader layer failed internally: {}", sanitize(m))
            }
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for ShaderError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostic::{Pass, Span};
    use crate::include::IncludeErrorKind;

    fn diag(message: &str, span: Option<(usize, usize)>) -> Diagnostic {
        let d = Diagnostic::new(message).in_stage(StageKind::Fragment).in_pass(Pass::Preprocess);
        match span {
            Some((a, b)) => d.at(Span::new(a, b).unwrap()),
            None => d,
        }
    }

    #[test]
    fn request_failures_carry_the_reason_and_value() {
        let e: ShaderError = RequestError::UnknownTarget("vulkan_spirv".into()).into();
        let text = e.to_string();
        assert!(text.contains("json") && text.contains("vulkan_spirv"), "{text}");
    }

    #[test]
    fn include_failures_carry_path_and_kind() {
        let e: ShaderError = IncludeError { path: "common.h".into(), kind: IncludeErrorKind::NotFound }.into();
        let text = e.to_string();
        assert!(text.contains("common.h") && text.contains("not found"), "{text}");
    }

    #[test]
    fn source_failures_carry_stage_pass_position_excerpt_message_and_shader() {
        let source = "#define A 1\n#if A\nint x = ;\n#endif\n";
        let at = source.find(';').unwrap();
        let e = ShaderError::source_failure(
            "effects/foo",
            vec![FailedDiagnostic::new(diag("expected an expression", Some((at, at + 1))), source)],
        );
        let text = e.to_string();
        for needle in ["fragment", "Preprocess", ":3:9", "3 | int x = ;", "expected an expression", "effects/foo"] {
            assert!(text.contains(needle), "{needle}: {text}");
        }
    }

    #[test]
    fn downstream_failures_name_the_generated_source_label() {
        let d = Diagnostic::new("syntax error")
            .in_generated_source(StageKind::Fragment)
            .in_pass(Pass::GlslParse)
            .at(Span::new(5, 9).unwrap());
        let e = ShaderError::source_failure("s", vec![FailedDiagnostic::new(d, "void main() {}")]);
        let text = e.to_string();
        assert!(text.contains("generated/fragment.glsl:1:6") && text.contains("GlslParse"), "{text}");
    }

    #[test]
    fn several_diagnostics_are_all_present_in_order_one_block_each() {
        let e = ShaderError::source_failure(
            "s",
            vec![
                FailedDiagnostic::without_source(diag("first problem", None)),
                FailedDiagnostic::without_source(diag("second problem", None)),
                FailedDiagnostic::without_source(diag("third problem", None)),
            ],
        );
        let text = e.to_string();
        let positions: Vec<usize> =
            ["first problem", "second problem", "third problem"].iter().map(|n| text.find(n).unwrap()).collect();
        assert!(positions.windows(2).all(|w| w[0] < w[1]), "{text}");
        assert_eq!(text.matches("error: ").count(), 3);
    }

    #[test]
    fn no_entry_point_names_the_stage() {
        let text = ShaderError::NoEntryPoint { stage: StageKind::Vertex }.to_string();
        assert!(text.contains("vertex") && text.contains("no entry point"), "{text}");
    }

    #[test]
    fn binding_and_reflection_failures_keep_their_facts() {
        let e: ShaderError = BindingError::SlotLimit {
            kind: crate::binding::SlotKind::Sampler,
            slot: 20,
            name: "_we_Sampler_g_Texture11".into(),
        }
        .into();
        let text = e.to_string();
        assert!(text.contains("sampler") && text.contains("20") && text.contains("_we_Sampler_g_Texture11") && text.contains("15"), "{text}");
        let e: ShaderError = ReflectionError::ConflictingBlock { name: "B".into(), set: 0, binding: 3 }.into();
        assert!(e.to_string().contains("conflicting reflected uniform block layout"));
        let e: ShaderError = UniformError::UnsupportedType { ty: "Light".into() }.into();
        assert_eq!(e.to_string(), "unsupported GlobalUniforms member type `Light`");
    }

    #[test]
    fn a_caught_panic_becomes_an_internal_failure_with_its_message() {
        let caught = std::panic::catch_unwind(|| {
            panic!("table index {} is wrong", 7);
        })
        .unwrap_err();
        let text = ShaderError::from_panic(caught).to_string();
        assert!(text.contains("failed internally") && text.contains("table index 7 is wrong"), "{text}");

        let caught = std::panic::catch_unwind(|| {
            panic!("static message");
        })
        .unwrap_err();
        assert!(ShaderError::from_panic(caught).to_string().contains("static message"));

        let caught = std::panic::catch_unwind(|| std::panic::panic_any(42u32)).unwrap_err();
        assert_eq!(ShaderError::from_panic(caught).to_string(), "the shader layer failed internally");
    }

    #[test]
    fn failure_text_never_carries_terminal_escapes() {
        let e = ShaderError::Internal { message: Some("\u{1b}[31mboom".into()) };
        assert!(!e.to_string().contains('\u{1b}'));
        let e = ShaderError::NonFiniteDefault { name: "u_\u{1b}x".into() };
        assert!(!e.to_string().contains('\u{1b}'));
    }
}
