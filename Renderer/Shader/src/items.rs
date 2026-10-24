// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The top-level item scan (R50 to R55).
//!
//! The scan runs over a token stream and yields a flat, source-ordered list of
//! items that covers every token exactly once: annotations, directives,
//! structs, functions, declarations and opaque tokens. Metadata extraction and
//! the legalizer both rely on it.
//!
//! The text of a stage exists in two shapes. The evaluated (compiled) text has
//! no conditionals, and its braces are matched by plain counting
//! ([`BraceMode::Compiled`]). The metadata-preserving text keeps every arm of
//! every conditional, so counting braces would see a function or struct body
//! as unclosed whenever an arm opens a brace that one shared `}` closes. In
//! [`BraceMode::Conditional`] the matcher follows the conditional directives:
//! each arm starts from the depth the conditional was opened at, and after the
//! `#endif` the depth of the first arm is kept.

use std::ops::Range;

use crate::diagnostic::{Diagnostic, Pass, Span};
use crate::error::{FailedDiagnostic, ShaderError};
use crate::facts::{ParameterFact, delimiter_table, layout_field, parameter_facts};
use crate::lexer::{Keyword, Token, TokenKind, TokenStream};
use crate::preprocess::{parse_define, parse_directive, parse_include_path};
use crate::request::StageKind;

/// Longest construct (tokens) the scan looks across to classify it. A longer one is reported in pieces of
/// this size, which keeps hostile text near linear: real headers and declarations are far shorter.
const MAX_CONSTRUCT_TOKENS: usize = 2048;
/// A `struct` header is `struct Name {`: how far to look for the brace.
const MAX_STRUCT_HEADER_TOKENS: usize = 16;

/// How braces are matched when finding the end of a body.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BraceMode {
    /// Plain counting, for evaluated text.
    Compiled,
    /// Conditional-aware, for metadata-preserving text (R54).
    Conditional,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConditionalKind {
    If,
    Ifdef,
    Ifndef,
    Elif,
    Else,
    Endif,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DirectiveKind {
    Include { path: String },
    Define { name: String, function_like: bool, replacement: String },
    Conditional(ConditionalKind),
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectiveItem {
    pub keyword: String,
    /// The body with continuations joined and the trailing comment removed (R13, R14).
    pub body: String,
    pub text: String,
    pub kind: DirectiveKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Qualifier {
    Uniform,
    Attribute,
    Varying,
    In,
    Out,
}

/// The bracket suffix after a declared name (R51).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArraySuffix {
    /// The source text from `[` through `]`.
    pub text: String,
    /// Set when the brackets hold exactly one unsigned decimal literal.
    pub size: Option<u32>,
    /// Set when the brackets hold exactly one identifier (a macro name).
    pub macro_name: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeclarationItem {
    /// Present for the interface qualifiers `uniform attribute varying in out`.
    pub qualifier: Option<Qualifier>,
    pub type_text: Option<String>,
    /// The first name-like token after the type (`uniform vec4 a, b;` reports `a`).
    pub name: Option<String>,
    pub name_index: Option<usize>,
    pub array: Option<ArraySuffix>,
    pub set: Option<u32>,
    pub binding: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FunctionItem {
    pub return_type: String,
    pub name: String,
    pub name_index: usize,
    pub name_span: Range<usize>,
    /// The text between the parentheses.
    pub parameter_text: String,
    pub parameter_span: Range<usize>,
    pub parameters: Vec<ParameterFact>,
    /// First token through the closing parenthesis.
    pub signature_span: Range<usize>,
    /// `{` through its matching `}`, inclusive.
    pub body_span: Range<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Annotation { text: String },
    Directive(DirectiveItem),
    Struct { name: Option<String> },
    Function(Box<FunctionItem>),
    Declaration(DeclarationItem),
    Opaque,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub kind: ItemKind,
    /// Token indices, half-open.
    pub tokens: Range<usize>,
    /// Byte span in the scanned text.
    pub span: Range<usize>,
}

impl Item {
    pub fn is_declaration(&self) -> bool {
        matches!(self.kind, ItemKind::Declaration(_))
    }

    pub fn function(&self) -> Option<&FunctionItem> {
        match &self.kind {
            ItemKind::Function(f) => Some(f),
            _ => None,
        }
    }

    pub fn declaration(&self) -> Option<&DeclarationItem> {
        match &self.kind {
            ItemKind::Declaration(d) => Some(d),
            _ => None,
        }
    }
}

/// The scan could not balance the delimiters of a function or struct (R55).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanError {
    /// Byte span of the unmatched opening token.
    pub span: Range<usize>,
    /// Index of that token.
    pub token_index: usize,
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("shader parse failed")
    }
}

impl std::error::Error for ScanError {}

impl ScanError {
    /// The diagnostic `unbalanced shader delimiter`, spanning the unmatched opener.
    pub fn diagnostic(&self, stage: StageKind) -> Diagnostic {
        let d = Diagnostic::new("unbalanced shader delimiter").in_stage(stage).in_pass(Pass::Parse);
        match Span::new(self.span.start, self.span.end) {
            Some(span) => d.at(span),
            None => d,
        }
    }

    /// The failure as a compile error, with the scanned text for the excerpt.
    pub fn into_shader_error(self, stage: StageKind, shader_name: &str, text: &str) -> ShaderError {
        ShaderError::source_failure(shader_name, vec![FailedDiagnostic::new(self.diagnostic(stage), text)])
    }
}

/// Scans `tokens` (lexed from `text`) into items.
pub fn scan_items(tokens: &TokenStream, text: &str, mode: BraceMode) -> Result<Vec<Item>, ScanError> {
    Scanner::new(tokens, text, mode).run()
}

struct Scanner<'a> {
    t: &'a TokenStream,
    text: &'a str,
    mode: BraceMode,
    close_of: Vec<Option<usize>>,
    conditionals: Vec<Option<ConditionalKind>>,
}

fn directive_kind(token: &Token) -> (DirectiveItem, Option<ConditionalKind>) {
    // CRLF continuations: the preprocessor model works on `\n`.
    let text = token.text.replace('\r', "");
    let parsed = parse_directive(&text);
    let conditional = match parsed.keyword.as_str() {
        "if" => Some(ConditionalKind::If),
        "ifdef" => Some(ConditionalKind::Ifdef),
        "ifndef" => Some(ConditionalKind::Ifndef),
        "elif" => Some(ConditionalKind::Elif),
        "else" => Some(ConditionalKind::Else),
        "endif" => Some(ConditionalKind::Endif),
        _ => None,
    };
    let kind = if let Some(c) = conditional {
        DirectiveKind::Conditional(c)
    } else if parsed.keyword == "include" {
        match parse_include_path(&parsed.body) {
            Some(path) => DirectiveKind::Include { path: path.replace('\\', "/") },
            None => DirectiveKind::Other,
        }
    } else if parsed.keyword == "define" {
        match parse_define(&parsed.body) {
            Some(d) => DirectiveKind::Define { name: d.name, function_like: d.function_like, replacement: d.replacement },
            None => DirectiveKind::Other,
        }
    } else {
        DirectiveKind::Other
    };
    (DirectiveItem { keyword: parsed.keyword, body: parsed.body, text: token.text.clone(), kind }, conditional)
}

fn qualifier_of(token: &Token) -> Option<Qualifier> {
    match token.kind {
        TokenKind::Keyword(Keyword::Uniform) => Some(Qualifier::Uniform),
        TokenKind::Keyword(Keyword::Attribute) => Some(Qualifier::Attribute),
        TokenKind::Keyword(Keyword::Varying) => Some(Qualifier::Varying),
        TokenKind::Keyword(Keyword::In) => Some(Qualifier::In),
        TokenKind::Keyword(Keyword::Out) => Some(Qualifier::Out),
        _ => None,
    }
}

impl<'a> Scanner<'a> {
    fn new(t: &'a TokenStream, text: &'a str, mode: BraceMode) -> Scanner<'a> {
        let conditionals = t.iter().map(|tok| if tok.is_directive() { directive_kind(tok).1 } else { None }).collect();
        Scanner { t, text, mode, close_of: delimiter_table(t), conditionals }
    }

    fn span(&self, tokens: Range<usize>) -> Range<usize> {
        self.t[tokens.start].start..self.t[tokens.end - 1].end
    }

    fn item(&self, kind: ItemKind, tokens: Range<usize>) -> Item {
        let span = self.span(tokens.clone());
        Item { kind, tokens, span }
    }

    fn error_at(&self, token_index: usize) -> ScanError {
        ScanError { span: self.t[token_index].range(), token_index }
    }

    fn run(&self) -> Result<Vec<Item>, ScanError> {
        let t = self.t;
        let mut items = Vec::new();
        let mut i = 0;
        while i < t.len() {
            let tok = &t[i];
            match tok.kind {
                TokenKind::Annotation => {
                    items.push(self.item(ItemKind::Annotation { text: tok.text.clone() }, i..i + 1));
                    i += 1;
                }
                TokenKind::Directive => {
                    items.push(self.item(ItemKind::Directive(directive_kind(tok).0), i..i + 1));
                    i += 1;
                }
                _ if tok.is_name_like() => {
                    let item = self.name_like(i)?;
                    i = item.tokens.end;
                    items.push(item);
                }
                _ => {
                    items.push(self.item(ItemKind::Opaque, i..i + 1));
                    i += 1;
                }
            }
        }
        Ok(items)
    }

    /// The end (index of the closing brace, or of the `#endif` that completes it) of the body opened at `open`.
    fn body_end(&self, open: usize) -> Option<usize> {
        match self.mode {
            BraceMode::Compiled => self.close_of[open],
            BraceMode::Conditional => self.conditional_close(open),
        }
    }

    /// Brace matching that follows conditional arms (R54).
    fn conditional_close(&self, open: usize) -> Option<usize> {
        struct Frame {
            base: i64,
            first_end: Option<i64>,
        }
        let mut depth: i64 = 0;
        let mut frames: Vec<Frame> = Vec::new();
        // A conditional opened before the scan began (the per-arm header shape) starts at depth zero.
        let mut outer: Option<i64> = None;
        for i in open..self.t.len() {
            if let Some(kind) = self.conditionals[i] {
                match kind {
                    ConditionalKind::If | ConditionalKind::Ifdef | ConditionalKind::Ifndef => {
                        frames.push(Frame { base: depth, first_end: None });
                    }
                    ConditionalKind::Elif | ConditionalKind::Else => {
                        if let Some(f) = frames.last_mut() {
                            f.first_end.get_or_insert(depth);
                            depth = f.base;
                        } else {
                            outer.get_or_insert(depth);
                            depth = 0;
                        }
                    }
                    ConditionalKind::Endif => {
                        if let Some(f) = frames.pop() {
                            if let Some(first) = f.first_end {
                                depth = first;
                            }
                        } else if let Some(first) = outer.take() {
                            depth = first;
                        }
                        if depth == 0 && frames.is_empty() && outer.is_none() && i > open {
                            // Every arm closed the body: the conditional completes it.
                            return Some(i);
                        }
                    }
                }
                continue;
            }
            match self.t[i].kind {
                TokenKind::LBrace => depth += 1,
                TokenKind::RBrace => {
                    depth -= 1;
                    if depth == 0 && frames.is_empty() {
                        return Some(i);
                    }
                }
                _ => {}
            }
        }
        None
    }

    fn name_like(&self, i: usize) -> Result<Item, ScanError> {
        let t = self.t;
        if t[i].is_keyword(Keyword::Struct)
            && let Some(item) = self.try_struct(i)?
        {
            return Ok(item);
        }
        if let Some(item) = self.try_function(i)? {
            return Ok(item);
        }
        Ok(self.declaration(i))
    }

    fn try_struct(&self, i: usize) -> Result<Option<Item>, ScanError> {
        let t = self.t;
        let header_end = t.len().min(i + 1 + MAX_STRUCT_HEADER_TOKENS);
        let Some(brace) = (i + 1..header_end).find(|j| matches!(t[*j].kind, TokenKind::LBrace | TokenKind::Semicolon)) else {
            return Ok(None);
        };
        if t[brace].kind != TokenKind::LBrace {
            return Ok(None);
        }
        let Some(close) = self.body_end(brace) else { return Err(self.error_at(brace)) };
        let name = t.get(i + 1).filter(|n| n.is_identifier()).map(|n| n.text.clone());
        let mut end = close + 1;
        if t.get(end).is_some_and(|n| n.kind == TokenKind::Semicolon) {
            end += 1;
        }
        Ok(Some(self.item(ItemKind::Struct { name }, i..end)))
    }

    fn try_function(&self, i: usize) -> Result<Option<Item>, ScanError> {
        let t = self.t;
        // Find the first top-level `(` and the token that ends the construct.
        let mut j = i;
        let mut depth = 0usize;
        let mut first_paren = None;
        loop {
            if j >= t.len() || j - i > MAX_CONSTRUCT_TOKENS {
                break;
            }
            let tok = &t[j];
            if tok.is_annotation() || tok.is_directive() {
                break;
            }
            if tok.is_left_paren() {
                if depth == 0 {
                    // Everything after the first top-level parenthesis is decided by its matching closer.
                    first_paren = Some(j);
                    break;
                }
                depth += 1;
            } else if tok.is_right_paren() || tok.is_right_bracket() {
                depth = depth.saturating_sub(1);
            } else if tok.is_left_bracket() {
                depth += 1;
            } else if depth == 0 && matches!(tok.kind, TokenKind::Semicolon | TokenKind::LBrace | TokenKind::RBrace) {
                break;
            }
            j += 1;
        }
        let Some(p) = first_paren else { return Ok(None) };
        if p < i + 2 || !t[p - 1].is_identifier() {
            return Ok(None);
        }
        let before = &t[p - 2];
        if !(before.is_identifier() || before.is_type() || before.is_keyword(Keyword::Void)) {
            return Ok(None);
        }
        let Some(close) = self.close_of[p] else {
            // `type name (` whose parenthesis never closes: the function cannot be balanced.
            return Err(self.error_at(p));
        };
        let Some(brace) = Some(close + 1).filter(|b| t.get(*b).is_some_and(|k| k.kind == TokenKind::LBrace)) else {
            return Ok(None);
        };
        let Some(body_close) = self.body_end(brace) else { return Err(self.error_at(brace)) };
        let name = &t[p - 1];
        let parameters = parameter_facts(t, p, close);
        let function = FunctionItem {
            return_type: before.text.clone(),
            name: name.text.clone(),
            name_index: p - 1,
            name_span: name.range(),
            parameter_text: self.text[t[p].end..t[close].start].to_string(),
            parameter_span: t[p].end..t[close].start,
            parameters,
            signature_span: t[i].start..t[close].end,
            body_span: t[brace].start..t[body_close].end,
        };
        Ok(Some(self.item(ItemKind::Function(Box::new(function)), i..body_close + 1)))
    }

    fn declaration(&self, i: usize) -> Item {
        let t = self.t;
        let mut j = i;
        let mut depth = 0usize;
        let end = loop {
            if j >= t.len() {
                break j;
            }
            if j - i > MAX_CONSTRUCT_TOKENS {
                // Too long to classify as one construct: report what was read as one opaque declaration and go on.
                return self.item(ItemKind::Declaration(DeclarationItem::default()), i..j);
            }
            let tok = &t[j];
            if tok.is_annotation() || tok.is_directive() {
                break j;
            }
            if tok.is_left_paren() || tok.is_left_bracket() {
                if self.close_of[j].is_none() {
                    // An opener that never closes: report one token and move on.
                    return self.item(ItemKind::Declaration(DeclarationItem::default()), i..i + 1);
                }
                depth += 1;
            } else if tok.is_right_paren() || tok.is_right_bracket() {
                depth = depth.saturating_sub(1);
            } else if depth == 0 {
                match tok.kind {
                    TokenKind::Semicolon => break j + 1,
                    TokenKind::LBrace | TokenKind::RBrace => {
                        // A construct that reaches a brace before any `;`: one token.
                        return self.item(ItemKind::Declaration(DeclarationItem::default()), i..i + 1);
                    }
                    _ => {}
                }
            }
            j += 1;
        };
        let range = i..end.max(i + 1);
        let facts = self.declaration_facts(range.clone());
        self.item(ItemKind::Declaration(facts), range)
    }

    fn declaration_facts(&self, range: Range<usize>) -> DeclarationItem {
        let t = self.t;
        let mut i = range.start;
        let mut groups: Vec<Range<usize>> = Vec::new();
        while i < range.end {
            let tok = &t[i];
            if tok.is_keyword(Keyword::Layout) && t.get(i + 1).is_some_and(Token::is_left_paren) {
                match self.close_of[i + 1] {
                    Some(c) if c < range.end => {
                        groups.push(i + 2..c);
                        i = c + 1;
                    }
                    _ => break,
                }
            } else if tok.is_declaration_modifier() {
                i += 1;
            } else {
                break;
            }
        }
        let Some(qualifier) = t.get(i).filter(|_| i < range.end).and_then(qualifier_of) else {
            return DeclarationItem::default();
        };
        i += 1;
        while i < range.end && t[i].is_declaration_modifier() {
            i += 1;
        }
        let mut facts = DeclarationItem { qualifier: Some(qualifier), ..DeclarationItem::default() };
        // Layout facts: the first group that sets a binding wins, else the last group.
        let read = |g: &Range<usize>| (layout_field(t, g.clone(), "set"), layout_field(t, g.clone(), "binding"));
        let chosen = groups.iter().find(|g| read(g).1.is_some()).or(groups.last());
        if let Some(group) = chosen {
            (facts.set, facts.binding) = read(group);
        }
        if i >= range.end || !t[i].is_name_like() {
            return facts;
        }
        facts.type_text = Some(t[i].text.clone());
        let name = i + 1;
        if name < range.end && t[name].is_name_like() {
            facts.name = Some(t[name].text.clone());
            facts.name_index = Some(name);
            if t.get(name + 1).is_some_and(|b| b.is_left_bracket())
                && let Some(close) = self.close_of[name + 1]
                && close < range.end
            {
                let inner = name + 2..close;
                let text = self.text[t[name + 1].start..t[close].end].to_string();
                let mut size = None;
                let mut macro_name = None;
                if inner.len() == 1 {
                    let only = &t[inner.start];
                    if only.is_number() && only.text.bytes().all(|b| b.is_ascii_digit()) {
                        size = only.text.parse::<u32>().ok();
                    } else if only.is_identifier() {
                        macro_name = Some(only.text.clone());
                    }
                }
                facts.array = Some(ArraySuffix { text, size, macro_name });
            }
        }
        facts
    }
}

#[cfg(test)]
mod tests;
