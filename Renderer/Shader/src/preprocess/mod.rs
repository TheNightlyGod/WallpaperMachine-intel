// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The preprocessor (R12 to R38).
//!
//! Each stage is processed on its own, line by line, with a fresh macro
//! environment. Two flavours of output exist:
//!
//! * [`Mode::Evaluated`]: includes expanded, inactive code and conditional
//!   directives removed. This is what is compiled.
//! * [`Mode::MetadataPreserving`]: includes (that are active) expanded, but
//!   inactive lines and the conditional directives kept, so that annotations in
//!   every branch can be found.
//!
//! Macros are not expanded here: ordinary lines pass through untouched and the
//! author's `#define` lines are kept for the downstream compiler (3.7). Output
//! line numbers do not match input line numbers; the diagnostics of this pass
//! name the origin (the stage text or an include path) and the line inside it.

mod expr;
pub mod lighting;

use std::collections::HashMap;
use std::fmt;
use std::ops::Range;

use crate::diagnostic::{Diagnostic, Pass, Span};
use crate::error::{FailedDiagnostic, ShaderError};
use crate::include::{IncludeError, check_include_path, normalize_include_path};
use crate::names::is_identifier;
use crate::request::{Combo, StageKind};
use crate::source::IncludeSource;
use crate::text::sanitize;

/// Deepest include nesting accepted (R77); stock trees nest about three deep.
pub const MAX_INCLUDE_DEPTH: usize = 64;
/// Most include expansions in one stage (bounds a tree that includes the same file many times).
pub const MAX_INCLUDE_EXPANSIONS: usize = 20_000;
/// Largest expanded stage text, in bytes (6.4).
pub const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
/// Conditions about run-time values recorded one by one per stage; further ones are counted in
/// one closing entry, so a hostile stage cannot inflate the diagnostics the engine stores.
pub const MAX_CONDITION_NOTES: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// The text that is compiled.
    Evaluated,
    /// The text that annotation scanning reads (R29).
    MetadataPreserving,
}

/// Which text a diagnostic's line number belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Origin {
    /// The stage's own text.
    Stage,
    /// An included file, by its normalised path as written.
    Include(String),
}

/// A preprocessing failure with a position (R37).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyntaxFailure {
    pub stage: StageKind,
    pub origin: Origin,
    /// 1-based, inside the origin's text.
    pub line: usize,
    /// Byte range of that line inside the origin's text.
    pub span: Range<usize>,
    pub message: String,
    /// The origin's text, for rendering an excerpt.
    pub origin_text: String,
}

impl fmt::Display for SyntaxFailure {
    /// `stage <Kind> line <n>: <message>` for the stage text, `include <path> line <n>: <message>` for an include.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match &self.origin {
            Origin::Stage => format!("stage {} line {}: {}", self.stage.label(), self.line, self.message),
            Origin::Include(path) => format!("include {path} line {}: {}", self.line, self.message),
        };
        f.write_str(&sanitize(&text))
    }
}

/// Why preprocessing failed: a syntax problem with a position, or the include
/// provider's own failure (which keeps its kind and path).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreprocessError {
    Syntax(Box<SyntaxFailure>),
    Include(IncludeError),
}

impl fmt::Display for PreprocessError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PreprocessError::Syntax(s) => s.fmt(f),
            PreprocessError::Include(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PreprocessError {}

impl PreprocessError {
    pub fn syntax(&self) -> Option<&SyntaxFailure> {
        match self {
            PreprocessError::Syntax(s) => Some(s),
            PreprocessError::Include(_) => None,
        }
    }

    /// The failure as a compile error: a diagnostic with the stage, the pass,
    /// the offending line as its span and the origin text for the excerpt.
    pub fn into_shader_error(self, shader_name: &str) -> ShaderError {
        match self {
            PreprocessError::Include(e) => ShaderError::Include(e),
            PreprocessError::Syntax(s) => {
                let mut diagnostic = Diagnostic::new(s.message.clone()).in_stage(s.stage).in_pass(Pass::Preprocess);
                if let Some(span) = Span::new(s.span.start, s.span.end) {
                    diagnostic = diagnostic.at(span);
                }
                if let Origin::Include(path) = &s.origin {
                    diagnostic = diagnostic.in_origin(format!("include {path}"));
                }
                ShaderError::source_failure(shader_name, vec![FailedDiagnostic::new(diagnostic, s.origin_text)])
            }
        }
    }
}

/// What the later stages know about macros before the first ordinary line of
/// the evaluated output (R38): object-like `#define` values and the combos.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MacroFacts {
    entries: Vec<(String, Option<String>)>,
}

impl MacroFacts {
    /// The value of an object-like macro defined in the leading region.
    pub fn value(&self, name: &str) -> Option<&str> {
        self.entries.iter().find(|(n, _)| n == name).and_then(|(_, v)| v.as_deref())
    }

    /// True for a name defined in the leading region, with or without a value
    /// (a bare `#define FLAG` and a function-like macro are known by name only).
    pub fn knows(&self, name: &str) -> bool {
        self.entries.iter().any(|(n, _)| n == name)
    }

    /// Names with their values (`None` when known by name only), in definition order.
    pub fn entries(&self) -> &[(String, Option<String>)] {
        &self.entries
    }

    fn define(&mut self, name: &str, value: Option<String>) {
        self.entries.retain(|(n, _)| n != name);
        self.entries.push((name.to_string(), value));
    }

    fn undefine(&mut self, name: &str) {
        self.entries.retain(|(n, _)| n != name);
    }
}

/// The result of preprocessing one stage.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StageOutput {
    pub text: String,
    pub macros: MacroFacts,
    /// Non-fatal findings, such as a condition that was treated as false because it refers to
    /// run-time values. Spans are byte ranges of the directive line in its origin's text.
    pub diagnostics: Vec<Diagnostic>,
}

/// Preprocesses one stage (R15, R29). `combos` are written as macros at the
/// top and are visible to every condition (R16, R17).
pub fn preprocess_stage(
    kind: StageKind,
    source: &str,
    combos: &[Combo],
    includes: &dyn IncludeSource,
    mode: Mode,
) -> Result<StageOutput, PreprocessError> {
    let mut engine = Engine {
        kind,
        mode,
        includes,
        env: HashMap::new(),
        out: String::with_capacity(source.len() + 256),
        leading: true,
        macros: MacroFacts::default(),
        include_stack: Vec::new(),
        expansions: 0,
        diagnostics: Vec::new(),
        unrecorded_conditions: 0,
    };
    engine.start(combos);
    engine.expand(source, &Origin::Stage)?;
    if engine.unrecorded_conditions > 0 {
        let more = Diagnostic::new(format!(
            "{} more conditions that test run-time values are treated as false",
            engine.unrecorded_conditions
        ))
        .in_stage(kind)
        .in_pass(Pass::Preprocess);
        engine.diagnostics.push(more);
    }
    Ok(StageOutput { text: engine.out, macros: engine.macros, diagnostics: engine.diagnostics })
}

/// What a written line means for the leading macro facts.
enum Emitted {
    Define { name: String, value: Option<String> },
    Undef(String),
    Other,
}

struct StackEntry {
    spelled: String,
    canonical: String,
}

struct Cond {
    /// The enclosing region is active.
    enclosing_active: bool,
    active: bool,
    /// Some branch of this conditional was already selected.
    taken: bool,
    seen_else: bool,
    line: usize,
    span: Range<usize>,
}

struct Engine<'a> {
    kind: StageKind,
    mode: Mode,
    includes: &'a dyn IncludeSource,
    env: HashMap<String, String>,
    out: String,
    leading: bool,
    macros: MacroFacts,
    include_stack: Vec<StackEntry>,
    expansions: usize,
    diagnostics: Vec<Diagnostic>,
    /// Conditions about run-time values past [`MAX_CONDITION_NOTES`].
    unrecorded_conditions: usize,
}

/// One physical line.
struct Line<'t> {
    no: usize,
    start: usize,
    end: usize,
    raw: &'t str,
}

struct Cursor<'t> {
    text: &'t str,
    pos: usize,
    no: usize,
}

impl<'t> Cursor<'t> {
    fn new(text: &'t str) -> Cursor<'t> {
        Cursor { text, pos: 0, no: 0 }
    }

    /// Lines end at `\n` or `\r\n`; a bare `\r` is not a terminator.
    fn next_line(&mut self) -> Option<Line<'t>> {
        if self.pos >= self.text.len() {
            return None;
        }
        let start = self.pos;
        let bytes = self.text.as_bytes();
        let (end, next) = match bytes[start..].iter().position(|b| *b == b'\n') {
            Some(p) => {
                let nl = start + p;
                (if nl > start && bytes[nl - 1] == b'\r' { nl - 1 } else { nl }, nl + 1)
            }
            None => (self.text.len(), self.text.len()),
        };
        self.pos = next;
        self.no += 1;
        Some(Line { no: self.no, start, end, raw: &self.text[start..end] })
    }
}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// A directive line: first non-whitespace character is `#` (R12).
fn is_directive_line(raw: &str) -> bool {
    raw.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == '\u{b}').starts_with('#')
}

/// A parsed directive line.
pub(crate) struct Directive {
    pub(crate) keyword: String,
    /// Continuations joined, trailing comment removed, trimmed (R13, R14).
    pub(crate) body: String,
    /// `#` and then the directive text, trimmed (R15); line breaks of a continuation stay.
    pub(crate) normalised: String,
}

pub(crate) fn parse_directive(logical: &str) -> Directive {
    let after_hash = logical.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == '\u{b}');
    let after_hash = &after_hash[1..];
    let normalised = format!("#{}", after_hash.trim_matches(|c: char| c.is_whitespace()));
    let rest = after_hash.trim_start_matches(is_blank);
    let kw_len = rest.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
    let keyword = rest[..kw_len].to_string();
    let after_keyword = rest[kw_len..].trim_start_matches(is_blank);
    let joined = after_keyword.replace("\\\n", " ");
    let body = strip_directive_comment(&joined).trim().to_string();
    Directive { keyword, body, normalised }
}

/// Removes a trailing `//` comment from a directive body (R14).
fn strip_directive_comment(body: &str) -> &str {
    let bytes = body.as_bytes();
    // `<path//with/slashes.h>`: nothing between the `<` and its `>` is a comment.
    let protected_to = if bytes.first() == Some(&b'<') { body.find('>') } else { None };
    let mut in_quote = false;
    let mut i = 0;
    while i < bytes.len() {
        if protected_to.is_some_and(|end| i <= end) {
            i += 1;
            continue;
        }
        match bytes[i] {
            b'"' if !(i > 0 && bytes[i - 1] == b'\\') => in_quote = !in_quote,
            b'/' if !in_quote && bytes.get(i + 1) == Some(&b'/') => return &body[..i],
            _ => {}
        }
        i += 1;
    }
    body
}

pub(crate) struct DefineParts {
    pub(crate) name: String,
    pub(crate) function_like: bool,
    /// Empty for a bare `#define NAME`.
    pub(crate) replacement: String,
}

/// R18. `None` is the "expects a macro name" error.
pub(crate) fn parse_define(body: &str) -> Option<DefineParts> {
    let bytes = body.as_bytes();
    if !bytes.first().is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_') {
        return None;
    }
    let name_len = bytes.iter().take_while(|b| b.is_ascii_alphanumeric() || **b == b'_').count();
    let name = body[..name_len].to_string();
    let rest = &body[name_len..];
    match rest.chars().next() {
        None => Some(DefineParts { name, function_like: false, replacement: String::new() }),
        Some(c) if c.is_whitespace() => {
            Some(DefineParts { name, function_like: false, replacement: rest.trim().to_string() })
        }
        Some('(') => {
            let mut depth = 0usize;
            for (i, c) in rest.char_indices() {
                match c {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(DefineParts {
                                name,
                                function_like: true,
                                replacement: rest[i + 1..].trim().to_string(),
                            });
                        }
                    }
                    _ => {}
                }
            }
            None
        }
        Some(_) => None,
    }
}

/// `"path"` or `<path>` (R20). `None` is the "expects a quoted include path" error.
pub(crate) fn parse_include_path(body: &str) -> Option<&str> {
    if let Some(inner) = body.strip_prefix('"') {
        let close = inner.find('"')?;
        return (close + 1 == inner.len()).then_some(&inner[..close]);
    }
    let inner = body.strip_prefix('<')?.strip_suffix('>')?;
    Some(inner)
}

/// An include path with `.` and empty components removed, for cycle detection (R77).
fn canonical_path(path: &str) -> String {
    path.split('/').filter(|c| !c.is_empty() && *c != ".").collect::<Vec<_>>().join("/")
}

fn chain_text(stack: &[StackEntry], offending: &str) -> String {
    let mut names: Vec<&str> = stack.iter().map(|e| e.spelled.as_str()).collect();
    names.push(offending);
    if names.len() > 8 {
        let tail = names.split_off(names.len() - 3);
        names.truncate(3);
        names.push("...");
        names.extend(tail);
    }
    names.join(" -> ")
}

impl Engine<'_> {
    fn start(&mut self, combos: &[Combo]) {
        for (name, value) in [("GLSL", "1"), ("HLSL", "1"), ("HLSL_SM40", "1")] {
            self.env.insert(name.to_string(), value.to_string());
        }
        for combo in combos {
            // A line break in a value would corrupt the definition line (Q21).
            let value = combo.value.replace(['\n', '\r'], " ");
            self.env.insert(combo.name.clone(), value.clone());
            self.env.insert(combo.name.to_ascii_uppercase(), value.clone());
            let shown = value.trim();
            let upper = combo.name.to_ascii_uppercase();
            self.emit(
                &format!("#define {upper} {value}"),
                Emitted::Define { name: upper, value: (!shown.is_empty()).then(|| shown.to_string()) },
            );
        }
    }

    fn emit(&mut self, line: &str, class: Emitted) {
        self.out.push_str(line);
        self.out.push('\n');
        match class {
            Emitted::Define { name, value } if self.leading => self.macros.define(&name, value),
            Emitted::Undef(name) if self.leading => self.macros.undefine(&name),
            Emitted::Define { .. } | Emitted::Undef(_) => {}
            Emitted::Other => self.leading = false,
        }
    }

    fn fail(&self, origin: &Origin, text: &str, line: &Line<'_>, message: impl Into<String>) -> PreprocessError {
        self.fail_at(origin, text, line.no, line.start..line.end, message)
    }

    fn fail_at(
        &self,
        origin: &Origin,
        text: &str,
        line: usize,
        span: Range<usize>,
        message: impl Into<String>,
    ) -> PreprocessError {
        PreprocessError::Syntax(Box::new(SyntaxFailure {
            stage: self.kind,
            origin: origin.clone(),
            line,
            span,
            message: message.into(),
            origin_text: text.to_string(),
        }))
    }

    /// The value of an `#if` or `#elif` condition. A condition that tests run-time values (a member
    /// access such as `g_Texture0Resolution.x`, a subscript) cannot be decided before the shader
    /// runs; Wallpaper Engine's compiler accepts such source, so the condition is false, as an
    /// unknown name is, and a diagnostic records it. Any other failure stops preprocessing.
    fn condition(&mut self, dir: &Directive, origin: &Origin, text: &str, line: &Line<'_>) -> Result<bool, PreprocessError> {
        let message = match expr::evaluate(&dir.body, &self.env) {
            Ok(value) => return Ok(value),
            Err(message) => message,
        };
        let Some(token) = expr::runtime_token(&dir.body) else {
            return Err(self.fail(origin, text, line, message));
        };
        if self.diagnostics.len() >= MAX_CONDITION_NOTES {
            self.unrecorded_conditions += 1;
            return Ok(false);
        }
        let mut note = Diagnostic::new(format!(
            "#{} condition tests run-time values ({token} cannot appear in a preprocessor expression); it is treated as false",
            dir.keyword
        ))
        .in_stage(self.kind)
        .in_pass(Pass::Preprocess);
        if let Some(span) = Span::new(line.start, line.end) {
            note = note.at(span);
        }
        if let Origin::Include(path) = origin {
            note = note.in_origin(format!("include {path}"));
        }
        self.diagnostics.push(note);
        Ok(false)
    }

    fn expand(&mut self, text: &str, origin: &Origin) -> Result<(), PreprocessError> {
        let mut conds: Vec<Cond> = Vec::new();
        let mut cursor = Cursor::new(text);
        let preserving = self.mode == Mode::MetadataPreserving;
        while let Some(line) = cursor.next_line() {
            if self.out.len() > MAX_OUTPUT_BYTES {
                return Err(self.fail(
                    origin,
                    text,
                    &line,
                    format!("the expanded shader source is too large (limit {MAX_OUTPUT_BYTES} bytes)"),
                ));
            }
            let active = conds.last().is_none_or(|c| c.active);
            if !is_directive_line(line.raw) {
                if active {
                    let trimmed = line.raw.trim_end();
                    // R31: a trailing backslash is dropped; the next line is not joined.
                    let shown = trimmed.strip_suffix('\\').unwrap_or(line.raw);
                    self.emit(shown, Emitted::Other);
                } else if preserving {
                    self.emit(line.raw, Emitted::Other);
                }
                continue;
            }

            // Join backslash-continued directive lines (Q2).
            let mut logical = line.raw.to_string();
            let mut last_raw = line.raw;
            let mut span_end = line.end;
            while last_raw.trim_end().ends_with('\\') {
                let Some(next) = cursor.next_line() else { break };
                logical.push('\n');
                logical.push_str(next.raw);
                last_raw = next.raw;
                span_end = next.end;
            }
            let line = Line { no: line.no, start: line.start, end: span_end, raw: line.raw };
            let dir = parse_directive(&logical);
            match dir.keyword.as_str() {
                "if" | "ifdef" | "ifndef" => {
                    let condition = if active {
                        if dir.keyword == "if" {
                            self.condition(&dir, origin, text, &line)?
                        } else {
                            if !is_identifier(&dir.body) {
                                return Err(self.fail(origin, text, &line, "conditional expects a single macro name"));
                            }
                            self.env.contains_key(&dir.body) == (dir.keyword == "ifdef")
                        }
                    } else {
                        false
                    };
                    conds.push(Cond {
                        enclosing_active: active,
                        active: active && condition,
                        taken: active && condition,
                        seen_else: false,
                        line: line.no,
                        span: line.start..line.end,
                    });
                    if preserving {
                        self.emit(&logical, Emitted::Other);
                    }
                }
                "elif" => {
                    let Some(top) = conds.last() else {
                        return Err(self.fail(origin, text, &line, "unmatched #elif directive"));
                    };
                    if top.seen_else {
                        return Err(self.fail(origin, text, &line, "#elif after #else directive"));
                    }
                    let evaluate = top.enclosing_active && !top.taken;
                    let condition = if evaluate {
                        self.condition(&dir, origin, text, &line)?
                    } else {
                        false
                    };
                    let top = conds.last_mut().expect("checked above");
                    top.active = condition;
                    top.taken |= condition;
                    if preserving {
                        self.emit(&logical, Emitted::Other);
                    }
                }
                "else" => {
                    let Some(top) = conds.last_mut() else {
                        return Err(self.fail(origin, text, &line, "unmatched #else directive"));
                    };
                    if top.seen_else {
                        return Err(self.fail(origin, text, &line, "duplicate #else directive"));
                    }
                    top.seen_else = true;
                    top.active = top.enclosing_active && !top.taken;
                    top.taken = true;
                    if !dir.body.is_empty() {
                        return Err(self.fail(origin, text, &line, "#else does not accept trailing tokens"));
                    }
                    if preserving {
                        self.emit(&logical, Emitted::Other);
                    }
                }
                "endif" => {
                    if !dir.body.is_empty() {
                        return Err(self.fail(origin, text, &line, "#endif does not accept trailing tokens"));
                    }
                    // A stray `#endif` is tolerated and ignored (R22).
                    conds.pop();
                    if preserving {
                        self.emit(&logical, Emitted::Other);
                    }
                }
                "define" => {
                    if active {
                        let Some(parts) = parse_define(&dir.body) else {
                            return Err(self.fail(origin, text, &line, "#define expects a macro name"));
                        };
                        let replacement =
                            if parts.replacement.is_empty() { "1".to_string() } else { parts.replacement.clone() };
                        let value = (!parts.function_like && !parts.replacement.is_empty())
                            .then(|| parts.replacement.clone());
                        self.env.insert(parts.name.clone(), replacement);
                        self.emit(&dir.normalised, Emitted::Define { name: parts.name, value });
                    }
                }
                "undef" => {
                    if active {
                        if !is_identifier(&dir.body) {
                            return Err(self.fail(origin, text, &line, "#undef expects a single macro name"));
                        }
                        self.env.remove(&dir.body);
                        self.emit(&dir.normalised, Emitted::Undef(dir.body.clone()));
                    } else if preserving {
                        self.emit(&dir.normalised, Emitted::Other);
                    }
                }
                "include" => {
                    if active {
                        self.include(&dir, text, origin, &line)?;
                    } else if preserving {
                        self.emit(&logical, Emitted::Other);
                    }
                }
                "require" => {
                    if active && !preserving && dir.body == "LightingV1" && lighting::lighting_enabled(&self.env) {
                        for block_line in lighting::lighting_block(lighting::light_counts(&self.env)) {
                            self.emit(&block_line, Emitted::Other);
                        }
                    }
                }
                _ => {
                    if active || preserving {
                        self.emit(&dir.normalised, Emitted::Other);
                    }
                }
            }
        }
        if let Some(open) = conds.last() {
            return Err(self.fail_at(origin, text, open.line, open.span.clone(), "unterminated conditional directive"));
        }
        Ok(())
    }

    fn include(&mut self, dir: &Directive, text: &str, origin: &Origin, line: &Line<'_>) -> Result<(), PreprocessError> {
        let Some(raw_path) = parse_include_path(&dir.body) else {
            return Err(self.fail(origin, text, line, "#include expects a quoted include path"));
        };
        let path = normalize_include_path(raw_path);
        if check_include_path(&path).is_err() {
            return Err(self.fail(origin, text, line, "#include path is invalid"));
        }
        let canonical = canonical_path(&path);
        if self.include_stack.iter().any(|e| e.canonical == canonical) {
            let chain = chain_text(&self.include_stack, &path);
            return Err(self.fail(origin, text, line, format!("include cycle detected: {chain}")));
        }
        if self.include_stack.len() >= MAX_INCLUDE_DEPTH {
            let chain = chain_text(&self.include_stack, &path);
            return Err(self.fail(
                origin,
                text,
                line,
                format!("include nesting is too deep (limit {MAX_INCLUDE_DEPTH}): {chain}"),
            ));
        }
        self.expansions += 1;
        if self.expansions > MAX_INCLUDE_EXPANSIONS {
            return Err(self.fail(
                origin,
                text,
                line,
                format!("too many include expansions (limit {MAX_INCLUDE_EXPANSIONS})"),
            ));
        }
        let content = self.includes.read(&path).map_err(PreprocessError::Include)?;
        self.include_stack.push(StackEntry { spelled: path.clone(), canonical });
        let result = self.expand(&content, &Origin::Include(path));
        self.include_stack.pop();
        result
    }
}

#[cfg(test)]
mod tests;
