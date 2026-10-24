// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! What a failure carries (spec D test 21, R38 to R42): stage, pass, source label, symbol,
//! source line, span and the generated text.

use naga::{Module, ShaderStage};

use super::support::*;
use crate::backend::{NagaBackend, StageCompiler, translate_module};
use crate::diagnostic::Pass;
use crate::error::{ErrorCategory, ShaderError};
use crate::legalize::LegalStage;
use crate::request::StageKind;

const BAD_FRAGMENT: &str = "#version 450
precision highp float;
layout(location = 0) out vec4 color;
void main() {
  color = vec4(1.0);
  color = undefined_tint * 0.5;
}
";

fn first(e: &ShaderError) -> &crate::error::FailedDiagnostic {
    let ShaderError::Source { failures, .. } = e else { panic!("expected a source failure: {e}") };
    &failures[0]
}

#[test]
fn a_front_end_failure_names_the_symbol_the_label_the_line_and_the_span() {
    let e = fail(StageKind::Fragment, BAD_FRAGMENT);
    assert_eq!(e.category(), ErrorCategory::Compile);
    let failure = first(&e);
    let d = &failure.diagnostic;
    assert_eq!(d.stage, Some(StageKind::Fragment));
    assert_eq!(d.pass, Some(Pass::GlslParse));
    assert_eq!(d.generated_source_path.as_deref(), Some("generated/fragment.glsl"));
    for needle in ["undefined_tint", "generated/fragment.glsl", "color = undefined_tint * 0.5;"] {
        assert!(d.message.contains(needle), "{needle}: {}", d.message);
    }
    // The span points into the generated text at the offending symbol; the text is attached.
    let source = failure.source.as_deref().expect("the generated text is attached");
    assert_eq!(source, BAD_FRAGMENT);
    let span = d.span.expect("naga gives a span for this error");
    assert!(span.is_within(source) && source[span.start()..span.end()].contains("undefined_tint"), "{span:?}");
    // The rendered text shows the line and its position as well.
    let text = e.clone().named("fx/tint").to_string();
    assert!(text.contains("generated/fragment.glsl:6:") && text.contains("fx/tint"), "{text}");
}

#[test]
fn the_two_stages_have_different_source_labels() {
    let v = fail(StageKind::Vertex, "#version 450\nvoid main() { nope(); }\n");
    assert_eq!(first(&v).diagnostic.generated_source_path.as_deref(), Some("generated/vertex.glsl"));
    assert_eq!(first(&v).diagnostic.stage, Some(StageKind::Vertex));
}

#[test]
fn a_validation_failure_has_the_validation_origin() {
    // A capability outside the default set: the early depth test.
    let early = "#version 450\nlayout(early_fragment_tests) in;\nlayout(location = 0) out vec4 c;\nvoid main() { c = vec4(1.0); }\n";
    let e = fail(StageKind::Fragment, early);
    assert_eq!(e.category(), ErrorCategory::Compile);
    assert_eq!(first(&e).diagnostic.pass, Some(Pass::Validate), "{e}");
    assert_eq!(first(&e).source.as_deref(), Some(early));

    // A rule the front end lets through: a vertex stage that returns no position.
    let e = fail(StageKind::Vertex, "#version 450\nvoid main() { }\n");
    let d = &first(&e).diagnostic;
    assert_eq!(d.pass, Some(Pass::Validate), "{e}");
    assert!(d.message.contains("position"), "{}", d.message);
}

#[test]
fn a_module_without_an_entry_point_of_the_stage_names_the_stage() {
    // Built from naga's IR: a module holding only a fragment entry point cannot be a vertex stage.
    let mut ir = Ir::new();
    ir.entry(ShaderStage::Fragment);
    let e = ir.translate(StageKind::Vertex).unwrap_err();
    assert_eq!(e.category(), ErrorCategory::Compile);
    let text = e.to_string();
    assert!(text.contains("vertex") && text.contains("no entry point"), "{text}");
    let e = translate_module(StageKind::Fragment, Module::default(), "").unwrap_err();
    assert!(e.to_string().contains("fragment"), "{e}");
    // A legalized text with no `main` at all is refused by the front end with the same words.
    let e = fail(StageKind::Fragment, "#version 450\nlayout(location = 0) out vec4 c;\n");
    assert!(e.to_string().to_lowercase().contains("entry point") && e.to_string().contains("fragment"), "{e}");
}

#[test]
fn a_source_of_the_other_stage_is_an_invalid_request_naming_both() {
    let stage = LegalStage {
        kind: StageKind::Vertex,
        text: "#version 450\nvoid main() {}\n".into(),
        diagnostics: vec![],
        sampled_planes: vec![],
    };
    let e = NagaBackend.compile(StageKind::Fragment, &stage).unwrap_err();
    assert_eq!(e.category(), ErrorCategory::InvalidRequest);
    let text = e.to_string();
    assert!(text.contains("vertex") && text.contains("fragment"), "{text}");
}

#[test]
fn implicit_derivative_sampling_in_divergent_control_flow_is_accepted() {
    // Shipped shaders sample inside branches; the pinned naga does not require uniform control
    // flow for implicit-level sampling in a fragment stage (R41, section 10 item 16).
    let text = "#version 450
layout(set = 0, binding = 0) uniform texture2D t;
layout(set = 0, binding = 1) uniform sampler s;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 c;
void main() {
  c = vec4(0.0);
  if (uv.x > 0.5) {
    c = texture(sampler2D(t, s), uv);
  }
}
";
    fragment(text);
}

#[test]
fn a_front_end_failure_text_has_no_terminal_escapes() {
    let e = fail(StageKind::Fragment, "#version 450\nvoid main() { \u{1b}[31m }\n");
    assert!(!e.to_string().contains('\u{1b}'));
}
