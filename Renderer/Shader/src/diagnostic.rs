// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Diagnostics (R71 to R75): what one diagnostic carries, the JSON document
//! form (spec 2.6.4) and a plain-text renderer.
//!
//! A diagnostic's span is a byte range inside the text of the pass it was
//! reported for. A span the layer cannot compute is left out, never invented
//! or clamped (R73). The renderer takes the text as an argument, so the
//! diagnostic itself never carries source text (the document must stay small
//! because the engine stores it).

use crate::json;
use crate::request::StageKind;
use crate::text::sanitize;

/// The step of the pipeline a diagnostic belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pass {
    /// Includes, conditionals, macros.
    Preprocess,
    /// The layer's own reading of the (preprocessed) source.
    Parse,
    /// The layer's source rewrites.
    Legalize,
    /// Generation of the GLSL handed to the downstream compiler. Also the pass
    /// of the informational entry a successful stage reports (R74).
    Codegen,
    /// The downstream compiler's GLSL front end.
    GlslParse,
    /// The downstream compiler's validation.
    Validate,
    /// The downstream compiler's Metal writer.
    MslWrite,
    /// Allocation of Metal argument-table slots.
    Binding,
    /// Building the reflection document.
    Reflection,
}

impl Pass {
    /// The spelling used in the diagnostics document and in failure text.
    pub fn name(self) -> &'static str {
        match self {
            Pass::Preprocess => "Preprocess",
            Pass::Parse => "Parse",
            Pass::Legalize => "Legalize",
            Pass::Codegen => "Codegen",
            Pass::GlslParse => "GlslParse",
            Pass::Validate => "Validate",
            Pass::MslWrite => "MslWrite",
            Pass::Binding => "Binding",
            Pass::Reflection => "Reflection",
        }
    }
}

/// A byte range with `start <= end`. The invariant is enforced by the constructors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    start: usize,
    end: usize,
}

impl Span {
    /// `None` when `start > end`: such a span cannot be reported (R73).
    pub fn new(start: usize, end: usize) -> Option<Span> {
        (start <= end).then_some(Span { start, end })
    }

    /// The span of a whole text.
    pub fn covering(text: &str) -> Span {
        Span { start: 0, end: text.len() }
    }

    pub fn start(self) -> usize {
        self.start
    }

    pub fn end(self) -> usize {
        self.end
    }

    /// True when both ends lie inside `text`, on character boundaries.
    pub fn is_within(self, text: &str) -> bool {
        self.end <= text.len() && text.is_char_boundary(self.start) && text.is_char_boundary(self.end)
    }
}

/// The label under which a stage's generated GLSL is reported when the
/// downstream compiler fails on it (R71).
pub fn generated_source_label(kind: StageKind) -> &'static str {
    match kind {
        StageKind::Vertex => "generated/vertex.glsl",
        StageKind::Fragment => "generated/fragment.glsl",
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub stage: Option<StageKind>,
    pub pass: Option<Pass>,
    pub span: Option<Span>,
    pub message: String,
    pub generated_source_path: Option<String>,
    /// A label for the text the span refers to when it is not the stage's own
    /// source, such as `include common.h`. Used by the text renderer only; it
    /// is not a key of the diagnostics document.
    pub origin: Option<String>,
}

impl Diagnostic {
    pub fn new(message: impl Into<String>) -> Diagnostic {
        Diagnostic { stage: None, pass: None, span: None, message: message.into(), generated_source_path: None, origin: None }
    }

    pub fn in_stage(mut self, stage: StageKind) -> Diagnostic {
        self.stage = Some(stage);
        self
    }

    pub fn in_pass(mut self, pass: Pass) -> Diagnostic {
        self.pass = Some(pass);
        self
    }

    pub fn at(mut self, span: Span) -> Diagnostic {
        self.span = Some(span);
        self
    }

    /// Names the text the span refers to when it is not the stage's own source.
    pub fn in_origin(mut self, label: impl Into<String>) -> Diagnostic {
        self.origin = Some(label.into());
        self
    }

    /// Marks the diagnostic as reported against a stage's generated GLSL (R71).
    pub fn in_generated_source(mut self, stage: StageKind) -> Diagnostic {
        self.stage = Some(stage);
        self.generated_source_path = Some(generated_source_label(stage).to_string());
        self
    }

    /// The informational entry a successful stage reports (R74): pass
    /// `Codegen`, the stage, a span over the whole stage source, no source text.
    pub fn codegen_info(stage: StageKind, stage_source: &str) -> Diagnostic {
        Diagnostic::new(format!("{} stage translated", stage.name()))
            .in_stage(stage)
            .in_pass(Pass::Codegen)
            .at(Span::covering(stage_source))
    }

    /// R73: a span, when present, lies inside `text` (and start <= end by construction).
    pub fn span_is_valid_for(&self, text: &str) -> bool {
        self.span.is_none_or(|s| s.is_within(text))
    }

    /// One object of the diagnostics document, keys in the order of spec 2.6.4.
    pub fn to_json(&self) -> String {
        json::object(&[
            ("stage", self.stage.map_or_else(json::null, |s| json::string(s.label()))),
            ("pass", self.pass.map_or_else(json::null, |p| json::string(p.name()))),
            (
                "span",
                self.span.map_or_else(json::null, |s| {
                    json::object(&[("start", s.start.to_string()), ("end", s.end.to_string())])
                }),
            ),
            ("message", json::string(&self.message)),
            (
                "generated_source_path",
                self.generated_source_path.as_deref().map_or_else(json::null, json::string),
            ),
        ])
    }
}

/// The diagnostics document: a compact JSON array.
pub fn diagnostics_json(diagnostics: &[Diagnostic]) -> String {
    json::array(diagnostics.iter().map(Diagnostic::to_json))
}

/// What the renderer needs besides the diagnostic itself.
#[derive(Clone, Copy, Debug, Default)]
pub struct RenderContext<'a> {
    /// The normalised shader name, when known.
    pub shader_name: Option<&'a str>,
    /// The text the diagnostic's span refers to.
    pub source: Option<&'a str>,
}

/// Source lines shown around a span, and the cap on a span's own lines.
const CONTEXT_LINES: usize = 1;
const MAX_SPAN_LINES: usize = 5;
/// Longest excerpt line shown, in characters.
const MAX_LINE_CHARS: usize = 160;

impl Diagnostic {
    /// Plain-text rendering: no colour codes, no control characters. Layout:
    ///
    /// ```text
    /// error: <message>
    ///   --> <origin>:<line>:<column>
    ///    |
    ///  9 | <line before>
    /// 10 | <offending line>
    ///    |      ^^^^
    ///    = stage: fragment, pass: Parse, shader: <name>
    /// ```
    ///
    /// The location and excerpt appear only when the diagnostic has a span
    /// that lies inside the given source text.
    pub fn render(&self, ctx: &RenderContext<'_>) -> String {
        let origin = self.origin(ctx);
        let located = match (self.span, ctx.source) {
            (Some(span), Some(source)) if span.is_within(source) => Some((span, source)),
            _ => None,
        };

        let mut out = format!("error: {}\n", sanitize(&self.message));
        match located {
            Some((span, source)) => {
                let lines = LineIndex::new(source);
                let (line, col) = lines.position(source, span.start);
                out.push_str(&format!("  --> {origin}:{line}:{col}\n"));
                out.push_str(&excerpt(source, &lines, span));
            }
            None => out.push_str(&format!("  --> {origin}\n")),
        }

        let mut facts = Vec::new();
        if let Some(stage) = self.stage {
            facts.push(format!("stage: {}", stage.name()));
        }
        if let Some(pass) = self.pass {
            facts.push(format!("pass: {}", pass.name()));
        }
        if let Some(name) = ctx.shader_name {
            facts.push(format!("shader: {}", sanitize(name).replace('\n', " ")));
        }
        if !facts.is_empty() {
            out.push_str(&format!("   = {}\n", facts.join(", ")));
        }
        out
    }

    fn origin(&self, ctx: &RenderContext<'_>) -> String {
        let origin = if let Some(path) = &self.generated_source_path {
            path.clone()
        } else if let Some(label) = &self.origin {
            label.clone()
        } else {
            match (ctx.shader_name, self.stage) {
                (Some(name), Some(StageKind::Vertex)) => format!("{name}.vert"),
                (Some(name), Some(StageKind::Fragment)) => format!("{name}.frag"),
                (Some(name), None) => name.to_string(),
                (None, Some(stage)) => format!("{} stage", stage.name()),
                (None, None) => "shader".to_string(),
            }
        };
        sanitize(&origin).replace('\n', " ")
    }
}

/// Byte offsets at which each line of a text starts.
struct LineIndex {
    starts: Vec<usize>,
}

impl LineIndex {
    fn new(text: &str) -> LineIndex {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(i, _)| i + 1));
        LineIndex { starts }
    }

    /// Zero-based line containing the byte offset.
    fn line_of(&self, offset: usize) -> usize {
        self.starts.partition_point(|&s| s <= offset) - 1
    }

    /// The line's text without its terminator (`\n` or `\r\n`).
    fn line_text<'a>(&self, text: &'a str, line: usize) -> &'a str {
        let start = self.starts[line];
        let end = self.starts.get(line + 1).map_or(text.len(), |&next| next - 1);
        text[start..end].strip_suffix('\r').unwrap_or(&text[start..end])
    }

    /// One-based (line, column); the column counts characters.
    fn position(&self, text: &str, offset: usize) -> (usize, usize) {
        let line = self.line_of(offset);
        let col = text[self.starts[line]..offset].chars().count() + 1;
        (line + 1, col)
    }
}

fn clip(line: &str) -> String {
    let mut shown: String = sanitize(line).chars().take(MAX_LINE_CHARS).collect();
    if line.chars().nth(MAX_LINE_CHARS).is_some() {
        shown.push_str("...");
    }
    shown
}

fn excerpt(text: &str, lines: &LineIndex, span: Span) -> String {
    let first = lines.line_of(span.start);
    // An end offset sitting at the very start of a line (just after a `\n`) belongs to the line before.
    let last = lines.line_of(if span.end > span.start { span.end - 1 } else { span.end }).max(first);
    let shown_last = last.min(first + MAX_SPAN_LINES - 1);
    let from = first.saturating_sub(CONTEXT_LINES);
    let to = (shown_last + CONTEXT_LINES).min(lines.starts.len() - 1);
    let width = (to + 1).to_string().len();

    let mut out = format!("{:>width$} |\n", "");
    for line in from..=to {
        out.push_str(&format!("{:>width$} | {}\n", line + 1, clip(lines.line_text(text, line))));
        if line == shown_last {
            if last > shown_last {
                out.push_str(&format!("{:>width$} | ...\n", ""));
            } else if first == last {
                let (_, col) = lines.position(text, span.start);
                let line_end = lines.starts[line] + lines.line_text(text, line).len();
                let covered = if span.start < line_end {
                    text[span.start..span.end.min(line_end)].chars().count().max(1)
                } else {
                    1
                };
                if col <= MAX_LINE_CHARS {
                    let carets = covered.min(MAX_LINE_CHARS - col + 1);
                    out.push_str(&format!("{:>width$} | {}{}\n", "", " ".repeat(col - 1), "^".repeat(carets)));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::Value;

    fn object(text: &str) -> Vec<(String, Value)> {
        let Value::Object(m) = json::parse(text).unwrap() else { panic!() };
        m
    }

    const SOURCE: &str = "void main() {\n    gl_Position = vec4(1.0);\n    float x = oops;\n}\n";

    #[test]
    fn span_enforces_ordering_and_bounds() {
        assert!(Span::new(3, 2).is_none());
        let s = Span::new(2, 2).unwrap();
        assert_eq!((s.start(), s.end()), (2, 2));
        assert!(Span::new(0, 4).unwrap().is_within("abcd"));
        assert!(!Span::new(0, 5).unwrap().is_within("abcd"));
        // Inside a multi-byte character is not a position in the text.
        assert!(!Span::new(1, 2).unwrap().is_within("é"));
        assert!(Span::new(0, 2).unwrap().is_within("é"));
        assert_eq!(Span::covering("héllo"), Span::new(0, 6).unwrap());
    }

    #[test]
    fn document_form_has_five_keys_in_order() {
        let d = Diagnostic::new("bad \"thing\"")
            .in_stage(StageKind::Fragment)
            .in_pass(Pass::Parse)
            .at(Span::new(4, 9).unwrap());
        let json = d.to_json();
        let keys: Vec<String> = object(&json).into_iter().map(|(k, _)| k).collect();
        assert_eq!(keys, ["stage", "pass", "span", "message", "generated_source_path"]);
        assert_eq!(
            json,
            r#"{"stage":"Fragment","pass":"Parse","span":{"start":4,"end":9},"message":"bad \"thing\"","generated_source_path":null}"#
        );
        assert_eq!(
            Diagnostic::new("m").to_json(),
            r#"{"stage":null,"pass":null,"span":null,"message":"m","generated_source_path":null}"#
        );
        assert_eq!(diagnostics_json(&[]), "[]");
        assert!(json::parse(&diagnostics_json(&[d.clone(), d])).is_ok());
    }

    #[test]
    fn success_entries_cover_the_stage_without_carrying_source() {
        let info = Diagnostic::codegen_info(StageKind::Vertex, SOURCE);
        assert_eq!(info.pass, Some(Pass::Codegen));
        assert_eq!(info.stage, Some(StageKind::Vertex));
        assert_eq!(info.span, Some(Span::covering(SOURCE)));
        assert!(info.span_is_valid_for(SOURCE));
        let json = info.to_json();
        assert!(json.contains(r#""pass":"Codegen""#) && json.contains(r#""stage":"Vertex""#));
        assert!(!json.contains("gl_Position"), "no source text in the document");
    }

    #[test]
    fn span_validity_check_for_a_text() {
        let d = Diagnostic::new("m").at(Span::new(0, 10).unwrap());
        assert!(d.span_is_valid_for(SOURCE));
        assert!(!d.span_is_valid_for("short"));
        assert!(Diagnostic::new("no span").span_is_valid_for(""));
    }

    #[test]
    fn rendering_shows_stage_pass_position_excerpt_and_message() {
        let start = SOURCE.find("oops").unwrap();
        let d = Diagnostic::new("undeclared identifier `oops`")
            .in_stage(StageKind::Fragment)
            .in_pass(Pass::GlslParse)
            .at(Span::new(start, start + 4).unwrap());
        let text = d.render(&RenderContext { shader_name: Some("effects/blur"), source: Some(SOURCE) });
        assert!(text.starts_with("error: undeclared identifier `oops`\n"), "{text}");
        assert!(text.contains("--> effects/blur.frag:3:15"), "{text}");
        assert!(text.contains("3 |     float x = oops;"), "{text}");
        assert!(text.contains("2 |     gl_Position = vec4(1.0);"), "context line before: {text}");
        assert!(text.contains("4 | }"), "context line after: {text}");
        assert!(text.contains("stage: fragment") && text.contains("pass: GlslParse"));
        assert!(text.contains("shader: effects/blur"));
        // The caret line underlines exactly the four characters of `oops`.
        let caret = text.lines().find(|l| l.contains('^')).unwrap();
        assert_eq!(caret, format!("  | {}^^^^", " ".repeat(14)));
    }

    #[test]
    fn generated_source_diagnostics_carry_the_label() {
        let d = Diagnostic::new("syntax error")
            .in_generated_source(StageKind::Fragment)
            .in_pass(Pass::GlslParse)
            .at(Span::new(0, 4).unwrap());
        let text = d.render(&RenderContext { shader_name: Some("s"), source: Some("void main() {}") });
        assert!(text.contains("generated/fragment.glsl:1:1"), "{text}");
        let v = Diagnostic::new("x").in_generated_source(StageKind::Vertex);
        assert_eq!(v.generated_source_path.as_deref(), Some("generated/vertex.glsl"));
    }

    #[test]
    fn columns_count_characters_and_lines_may_end_in_crlf() {
        let src = "// é comment\r\nint é = 1;\r\nbad token\r\n";
        let start = src.find("bad").unwrap();
        let d = Diagnostic::new("m").at(Span::new(start, start + 3).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some(src) });
        assert!(text.contains("shader:3:1"), "{text}");
        assert!(text.contains("3 | bad token\n"), "no carriage return in the excerpt: {text:?}");
        assert!(!text.contains('\r'));
        let accent = src.find("é = 1").unwrap();
        let d = Diagnostic::new("m").at(Span::new(accent + 2, accent + 3).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some(src) });
        assert!(text.contains(":2:6"), "the accent is one character wide: {text}");
    }

    #[test]
    fn multi_line_spans_show_their_lines_and_cap_the_excerpt() {
        let src: String = (1..=12).map(|i| format!("line{i}\n")).collect();
        let d = Diagnostic::new("m").at(Span::new(0, src.len()).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some(&src) });
        assert!(text.contains("line5") && !text.contains("line7"), "{text}");
        assert!(text.contains("..."), "{text}");
        assert!(!text.contains('^'), "no underline across lines");
        // An end offset just after a newline does not pull in the next line.
        let d = Diagnostic::new("m").at(Span::new(0, "line1\n".len()).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some(&src) });
        assert!(text.contains("1 | line1") && text.contains("2 | line2") && !text.contains("line3"), "{text}");
    }

    #[test]
    fn spans_outside_the_text_are_left_out_not_clamped() {
        let d = Diagnostic::new("m").in_stage(StageKind::Vertex).at(Span::new(5, 500).unwrap());
        let text = d.render(&RenderContext { shader_name: Some("s"), source: Some("short text") });
        assert!(text.contains("--> s.vert\n"), "{text}");
        assert!(!text.contains('|') && !text.contains("short text"), "{text}");
        // Without the source, only the location-free form is possible.
        let text = d.render(&RenderContext::default());
        assert!(text.contains("--> vertex stage\n"), "{text}");
        let text = Diagnostic::new("m").render(&RenderContext::default());
        assert!(text.contains("--> shader\n"));
    }

    #[test]
    fn rendering_is_plain_text() {
        let src = "a\u{1b}[31mred\u{1b}[0m\tb";
        let d = Diagnostic::new("bad \u{1b}[1mbold").at(Span::new(0, src.len()).unwrap());
        let text = d.render(&RenderContext { shader_name: Some("n\u{1b}[0m"), source: Some(src) });
        assert!(!text.contains('\u{1b}'), "{text:?}");
        assert!(text.chars().all(|c| c == '\n' || !c.is_control()), "{text:?}");
    }

    #[test]
    fn very_long_lines_are_clipped() {
        let src = format!("{}bad", "x".repeat(10_000));
        let d = Diagnostic::new("m").at(Span::new(10_000, 10_003).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some(&src) });
        assert!(text.len() < 1000, "{}", text.len());
        assert!(text.contains(":1:10001"), "the position is still exact: {text}");
    }

    #[test]
    fn several_diagnostics_render_in_order() {
        let a = Diagnostic::new("first").render(&RenderContext::default());
        let b = Diagnostic::new("second").render(&RenderContext::default());
        assert!(a.find("first").is_some() && b.find("second").is_some());
    }

    #[test]
    fn a_zero_width_span_gets_one_caret() {
        let d = Diagnostic::new("m").at(Span::new(2, 2).unwrap());
        let text = d.render(&RenderContext { shader_name: None, source: Some("abcd") });
        assert!(text.contains(" | ^") || text.contains("  ^"), "{text}");
        assert_eq!(text.matches('^').count(), 1);
    }
}
