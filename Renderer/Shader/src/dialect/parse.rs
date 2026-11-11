// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Parser for the dialect: tokens (after macro expansion) to a [`Module`].
//!
//! The grammar is C-like. It is lenient on purpose (P3): a statement or item it cannot
//! place is carried through as raw text for the downstream compiler to judge, and a stray
//! punctuation character never fails the stage by itself (R5, E19). Only delimiter
//! problems are hard failures (R6): an opener without a closer reports the opener. The other
//! hard failure is a malformed member-access suffix on a declared interface name (amendment
//! c1 R107), which reports the declaration.

use std::collections::HashSet;

use crate::lexer::{Keyword, Operator, Precedence, Token, TokenKind};

use super::ast::*;
use super::ty::builtin_type;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub message: String,
    pub start: usize,
    pub end: usize,
}

/// A parse step that failed. The caller falls back to raw text; delimiter problems, the only
/// hard failures, are found before parsing starts.
#[derive(Debug)]
struct Soft;

type PResult<T> = Result<T, Soft>;

/// Qualifier words recognised in front of a type.
const QUALIFIER_WORDS: [&str; 22] = [
    "lowp",
    "mediump",
    "highp",
    "flat",
    "smooth",
    "noperspective",
    "centroid",
    "invariant",
    "precise",
    "buffer",
    "shared",
    "coherent",
    "volatile",
    "restrict",
    "readonly",
    "writeonly",
    "patch",
    "inout",
    "subroutine",
    "sample",
    "attribute",
    "varying",
];

/// Checks that every `(`, `[` and `{` has its closer, in order.
fn check_delimiters(tokens: &[Token]) -> Result<(), ParseError> {
    let mut stack: Vec<(usize, char)> = Vec::new();
    for (i, t) in tokens.iter().enumerate() {
        let open = match t.kind {
            TokenKind::LBrace => Some('{'),
            TokenKind::Operator(Operator::LParen) => Some('('),
            TokenKind::Operator(Operator::LBracket) => Some('['),
            _ => None,
        };
        if let Some(c) = open {
            stack.push((i, c));
            continue;
        }
        let close = match t.kind {
            TokenKind::RBrace => Some('{'),
            TokenKind::Operator(Operator::RParen) => Some('('),
            TokenKind::Operator(Operator::RBracket) => Some('['),
            _ => None,
        };
        if let Some(want) = close {
            match stack.pop() {
                Some((_, c)) if c == want => {}
                Some((j, c)) => {
                    // A closer of the wrong kind: report the unclosed opener.
                    let o = &tokens[j];
                    return Err(ParseError {
                        message: format!("unbalanced delimiters: `{c}` is not closed before `{}`", t.text),
                        start: o.start,
                        end: o.end,
                    });
                }
                None => {
                    return Err(ParseError {
                        message: format!("unbalanced delimiters: `{}` closes nothing", t.text),
                        start: t.start,
                        end: t.end,
                    });
                }
            }
        }
    }
    if let Some((j, c)) = stack.pop() {
        let o = &tokens[j];
        return Err(ParseError {
            message: format!("unbalanced delimiters: `{c}` is never closed"),
            start: o.start,
            end: o.end,
        });
    }
    Ok(())
}

pub fn parse(tokens: &[Token]) -> Result<Module, ParseError> {
    check_delimiters(tokens)?;
    let mut p = Parser { toks: tokens, pos: 0, structs: HashSet::new(), depth: 0, hard: None };
    let mut items = Vec::new();
    while p.pos < p.toks.len() {
        let start = p.pos;
        match p.item() {
            Ok(Some(item)) => items.push(item),
            Ok(None) => {}
            Err(Soft) => {
                if let Some(error) = p.hard.take() {
                    return Err(error);
                }
                p.pos = start;
                items.push(p.raw_item());
            }
        }
    }
    Ok(Module { items })
}

/// How deeply statements and parenthesised expressions may nest before the construct is
/// carried through as raw text instead of parsed (a bound on recursion for hostile input).
const MAX_NESTING: u32 = 128;

struct Parser<'a> {
    toks: &'a [Token],
    pos: usize,
    structs: HashSet<String>,
    depth: u32,
    /// A failure that must not fall back to raw text: set where the step fails, read by [`parse`].
    hard: Option<ParseError>,
}

/// The letters a member-access suffix on a declared name may be made of (R107): component letters of
/// any of the three sets, in any mix (the suffix is discarded, so no set has to be consistent).
fn is_component_name(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| "xyzwrgbastpq".contains(c))
}

fn is_assign_op(op: Operator) -> bool {
    op.is_assignment()
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a Token> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, k: usize) -> Option<&'a Token> {
        self.toks.get(self.pos + k)
    }

    fn bump(&mut self) -> Option<&'a Token> {
        let t = self.toks.get(self.pos);
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn at_op(&self, op: Operator) -> bool {
        self.peek().is_some_and(|t| t.is_operator(op))
    }

    fn at_op_k(&self, k: usize, op: Operator) -> bool {
        self.peek_at(k).is_some_and(|t| t.is_operator(op))
    }

    fn eat_op(&mut self, op: Operator) -> bool {
        if self.at_op(op) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn at_kind(&self, kind: TokenKind) -> bool {
        self.peek().is_some_and(|t| t.kind == kind)
    }

    fn eat_kind(&mut self, kind: TokenKind) -> bool {
        if self.at_kind(kind) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn at_ident_text(&self, text: &str) -> bool {
        self.peek().is_some_and(|t| t.kind == TokenKind::Identifier && t.text == text)
    }

    fn soft<T>(&self) -> PResult<T> {
        Err(Soft)
    }

    fn expect_op(&mut self, op: Operator) -> PResult<&'a Token> {
        if self.at_op(op) { Ok(self.bump().unwrap()) } else { self.soft() }
    }

    fn expect_kind(&mut self, kind: TokenKind) -> PResult<&'a Token> {
        if self.at_kind(kind) { Ok(self.bump().unwrap()) } else { self.soft() }
    }

    fn span_from(&self, start_tok: usize) -> Span {
        let first = self.toks.get(start_tok).map_or(0, |t| t.start);
        let last = self.toks.get(self.pos.saturating_sub(1)).map_or(first, |t| t.end);
        first..last.max(first)
    }

    // ----- items -----

    /// Carries the tokens up to the end of the construct (a `;` at depth zero, or a closing
    /// brace that balances an opening one) as text.
    fn raw_item(&mut self) -> Item {
        Item::Raw(self.raw_tokens_text())
    }

    fn raw_tokens_text(&mut self) -> String {
        let start = self.pos;
        let mut depth = 0i32;
        let mut i = self.pos;
        while let Some(t) = self.toks.get(i) {
            i += 1;
            match t.kind {
                TokenKind::LBrace | TokenKind::Operator(Operator::LParen) | TokenKind::Operator(Operator::LBracket) => {
                    depth += 1
                }
                TokenKind::RBrace | TokenKind::Operator(Operator::RParen) | TokenKind::Operator(Operator::RBracket) => {
                    depth -= 1;
                    if depth <= 0 && t.kind == TokenKind::RBrace {
                        break;
                    }
                }
                TokenKind::Semicolon if depth <= 0 => break,
                _ => {}
            }
        }
        if i == start {
            i = start + 1;
        }
        self.pos = i;
        join_tokens(&self.toks[start..i])
    }

    fn item(&mut self) -> PResult<Option<Item>> {
        let Some(t) = self.peek() else { return Ok(None) };
        match t.kind {
            TokenKind::Directive => {
                self.pos += 1;
                Ok(Some(Item::Directive(t.text.clone())))
            }
            TokenKind::Annotation => {
                self.pos += 1;
                Ok(Some(Item::Annotation(t.text.clone())))
            }
            TokenKind::Semicolon => {
                self.pos += 1;
                Ok(None)
            }
            TokenKind::Keyword(Keyword::Precision) => {
                let start = self.pos;
                while let Some(t) = self.bump() {
                    if t.kind == TokenKind::Semicolon {
                        break;
                    }
                }
                let end = if self.toks[self.pos - 1].kind == TokenKind::Semicolon { self.pos - 1 } else { self.pos };
                Ok(Some(Item::Precision(join_tokens(&self.toks[start..end]))))
            }
            TokenKind::Keyword(Keyword::Struct) => self.struct_item().map(Some),
            _ => self.decl_or_function().map(Some),
        }
    }

    fn struct_item(&mut self) -> PResult<Item> {
        let def = self.struct_def(Vec::new())?;
        Ok(Item::Struct(def))
    }

    /// `struct [Name] { fields } [declarators] [;]`
    fn struct_def(&mut self, quals: Vec<Qualifier>) -> PResult<StructDef> {
        let start = self.pos;
        self.expect_kind(TokenKind::Keyword(Keyword::Struct))?;
        let name = match self.peek() {
            Some(t) if t.kind == TokenKind::Identifier => {
                self.pos += 1;
                Some(t.text.clone())
            }
            _ => None,
        };
        if let Some(n) = &name {
            self.structs.insert(n.clone());
        }
        if !self.at_kind(TokenKind::LBrace) {
            // `struct Name inst;` is a declaration of an instance, not a definition.
            return self.soft();
        }
        self.pos += 1;
        let mut fields = Vec::new();
        while !self.at_kind(TokenKind::RBrace) {
            if self.peek().is_none() {
                return self.soft();
            }
            if self.eat_kind(TokenKind::Semicolon) {
                continue;
            }
            if self.peek().is_some_and(Token::is_annotation) {
                self.pos += 1;
                continue;
            }
            fields.push(self.field_decl()?);
        }
        self.pos += 1;
        let mut declarators = Vec::new();
        if !self.at_kind(TokenKind::Semicolon) && self.peek().is_some_and(|t| t.kind == TokenKind::Identifier) {
            declarators = self.declarators(None)?;
        }
        // The final `;` may be missing (R2).
        self.eat_kind(TokenKind::Semicolon);
        Ok(StructDef { name, fields, declarators, quals, span: self.span_from(start) })
    }

    fn field_decl(&mut self) -> PResult<VarDecl> {
        let start = self.pos;
        let quals = self.qualifiers(true);
        let ty = self.type_ref()?;
        let declarators = self.declarators(None)?;
        self.expect_kind(TokenKind::Semicolon)?;
        Ok(VarDecl { quals, ty, declarators, span: self.span_from(start) })
    }

    /// The qualifier run in front of a type. `sample` counts as a qualifier only when a
    /// type or another qualifier follows (R70).
    fn qualifiers(&mut self, allow_sample: bool) -> Vec<Qualifier> {
        let mut quals = Vec::new();
        while let Some(t) = self.peek() {
            match t.kind {
                TokenKind::Keyword(Keyword::Const | Keyword::Uniform | Keyword::Attribute | Keyword::Varying)
                | TokenKind::Keyword(Keyword::In | Keyword::Out) => {
                    quals.push(Qualifier::Word(t.text.clone()));
                    self.pos += 1;
                }
                TokenKind::Keyword(Keyword::Layout) if self.at_op_k(1, Operator::LParen) => {
                    let open = self.pos + 1;
                    let close = self.matching(open);
                    let inner = layout_text(&self.toks[open + 1..close]);
                    quals.push(Qualifier::Layout(inner));
                    self.pos = close + 1;
                }
                TokenKind::Identifier if QUALIFIER_WORDS.contains(&t.text.as_str()) => {
                    if t.text == "sample" {
                        let next_is_type_like = self.peek_at(1).is_some_and(|n| {
                            matches!(
                                n.kind,
                                TokenKind::Type
                                    | TokenKind::Keyword(Keyword::In | Keyword::Out | Keyword::Uniform | Keyword::Const)
                            ) || (n.kind == TokenKind::Identifier
                                && (QUALIFIER_WORDS.contains(&n.text.as_str())
                                    || self.peek_at(2).is_some_and(|nn| nn.kind == TokenKind::Identifier)))
                        });
                        if !allow_sample || !next_is_type_like {
                            break;
                        }
                    }
                    quals.push(Qualifier::Word(t.text.clone()));
                    self.pos += 1;
                }
                _ => break,
            }
        }
        quals
    }

    /// The index of the closer matching the opener at `open` (delimiters are known to balance).
    fn matching(&self, open: usize) -> usize {
        let mut depth = 0i32;
        for (i, t) in self.toks.iter().enumerate().skip(open) {
            match t.kind {
                TokenKind::LBrace | TokenKind::Operator(Operator::LParen) | TokenKind::Operator(Operator::LBracket) => {
                    depth += 1
                }
                TokenKind::RBrace | TokenKind::Operator(Operator::RParen) | TokenKind::Operator(Operator::RBracket) => {
                    depth -= 1;
                    if depth == 0 {
                        return i;
                    }
                }
                _ => {}
            }
        }
        self.toks.len().saturating_sub(1)
    }

    fn is_type_token(t: &Token) -> bool {
        matches!(t.kind, TokenKind::Type | TokenKind::Identifier)
    }

    /// A type name with optional array dimensions (`float[3]`).
    fn type_ref(&mut self) -> PResult<TypeRef> {
        let t = match self.peek() {
            Some(t) if Self::is_type_token(t) || t.is_keyword(Keyword::Void) => t,
            _ => return self.soft(),
        };
        self.pos += 1;
        let name = super::ty::canonical_type_name(&t.text);
        let mut dims = Vec::new();
        while self.at_op(Operator::LBracket) {
            dims.push(self.dim()?);
        }
        Ok(TypeRef { name, dims })
    }

    /// `[expr]` or `[]`.
    fn dim(&mut self) -> PResult<Option<Expr>> {
        self.expect_op(Operator::LBracket)?;
        if self.eat_op(Operator::RBracket) {
            return Ok(None);
        }
        let first = self.pos;
        let e = self.assign()?;
        if self.at_op(Operator::RBracket) {
            self.pos += 1;
            return Ok(Some(e));
        }
        // Something the grammar cannot place follows the expression (`0x4` lexes as `0` then
        // `x4`): everything up to the closing bracket is kept as one opaque expression, written as
        // it was in the source, so the declaration survives and its bound can be named in a message.
        let mut depth = 0usize;
        let mut end = self.pos;
        while let Some(t) = self.toks.get(end) {
            if t.is_operator(Operator::LBracket) {
                depth += 1;
            } else if t.is_operator(Operator::RBracket) {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            end += 1;
        }
        let mut text = String::new();
        let mut previous_end = None;
        for t in &self.toks[first..end.min(self.toks.len())] {
            if previous_end.is_some_and(|p| t.start > p) {
                text.push(' ');
            }
            text.push_str(&t.text);
            previous_end = Some(t.end);
        }
        let span = self.toks[first].start..self.toks[end.min(self.toks.len()) - 1].end;
        self.pos = end;
        self.expect_op(Operator::RBracket)?;
        Ok(Some(Expr::new(ExprKind::Opaque(text), span)))
    }

    /// The member-access suffix after a declared interface name, `.xy` in `varying vec4 v.xy;`
    /// (R107): consumed and dropped when it is a dot, component letters and then `;` or `,`.
    /// Anything else after the dot is a hard failure that reports the declaration that began at
    /// token `decl_start`, so the failure is at that declaration and not at the next one.
    fn member_suffix(&mut self, decl_start: usize) -> PResult<()> {
        let dot = self.pos;
        self.pos += 1;
        let well_formed = match self.peek() {
            Some(t) if t.kind == TokenKind::Identifier && is_component_name(&t.text) => {
                self.pos += 1;
                matches!(self.peek().map(|t| t.kind), Some(TokenKind::Semicolon | TokenKind::Comma))
            }
            _ => false,
        };
        if well_formed { Ok(()) } else { self.bad_suffix(decl_start, dot) }
    }

    /// Records the hard failure of a malformed suffix: the span is the declaration, from its first
    /// token through the `;` that ends it (or the last token when there is none).
    fn bad_suffix<T>(&mut self, decl_start: usize, from: usize) -> PResult<T> {
        let end = (from..self.toks.len()).find(|&i| self.toks[i].kind == TokenKind::Semicolon).unwrap_or(self.toks.len() - 1);
        self.hard = Some(ParseError {
            message: "a declared name may only be followed by a member-access suffix of component letters, such as `.xy`".to_string(),
            start: self.toks[decl_start].start,
            end: self.toks[end].end,
        });
        self.soft()
    }

    /// Declarators separated by commas. `suffix_from` is the first token of the declaration when
    /// it is a top-level interface declaration that tolerates a member-access suffix on a name.
    fn declarators(&mut self, suffix_from: Option<usize>) -> PResult<Vec<Declarator>> {
        let mut list = Vec::new();
        loop {
            let name_tok = match self.peek() {
                Some(t) if matches!(t.kind, TokenKind::Identifier) => t,
                _ => return self.soft(),
            };
            self.pos += 1;
            if let Some(decl_start) = suffix_from {
                if self.at_op(Operator::Dot) {
                    self.member_suffix(decl_start)?;
                } else if self.peek().is_some_and(|t| t.kind == TokenKind::Number && t.text.starts_with('.')) {
                    // `v.12`: the lexer took the dot into a number, and no identifier follows it.
                    return self.bad_suffix(decl_start, self.pos);
                }
            }
            let mut dims = Vec::new();
            while self.at_op(Operator::LBracket) {
                dims.push(self.dim()?);
            }
            let init = if self.eat_op(Operator::Assign) { Some(self.initializer()?) } else { None };
            list.push(Declarator { name: name_tok.text.clone(), name_span: name_tok.start..name_tok.end, dims, init });
            if !self.eat_kind(TokenKind::Comma) {
                break;
            }
        }
        Ok(list)
    }

    fn initializer(&mut self) -> PResult<Expr> {
        if self.depth >= MAX_NESTING {
            return self.soft();
        }
        self.depth += 1;
        let r = self.initializer_inner();
        self.depth -= 1;
        r
    }

    fn initializer_inner(&mut self) -> PResult<Expr> {
        if self.at_kind(TokenKind::LBrace) {
            let start = self.pos;
            self.pos += 1;
            let mut list = Vec::new();
            while !self.at_kind(TokenKind::RBrace) {
                if self.peek().is_none() {
                    return self.soft();
                }
                list.push(self.initializer()?);
                if !self.eat_kind(TokenKind::Comma) {
                    break;
                }
            }
            self.expect_kind(TokenKind::RBrace)?;
            Ok(Expr::new(ExprKind::InitList(list), self.span_from(start)))
        } else {
            self.assign()
        }
    }

    fn decl_or_function(&mut self) -> PResult<Item> {
        let start = self.pos;
        let quals = self.qualifiers(true);
        if self.at_kind(TokenKind::Keyword(Keyword::Struct)) {
            let def = self.struct_def(quals)?;
            return Ok(Item::Struct(def));
        }
        // Interface block: `uniform Name { ... } instance;`
        if self.peek().is_some_and(|t| t.kind == TokenKind::Identifier) && self.peek_at(1).is_some_and(|t| t.kind == TokenKind::LBrace) {
            let name = self.bump().unwrap().text.clone();
            self.pos += 1;
            let mut fields = Vec::new();
            while !self.at_kind(TokenKind::RBrace) {
                if self.peek().is_none() {
                    return self.soft();
                }
                if self.eat_kind(TokenKind::Semicolon) {
                    continue;
                }
                fields.push(self.field_decl()?);
            }
            self.pos += 1;
            let instance = if self.peek().is_some_and(|t| t.kind == TokenKind::Identifier) {
                self.declarators(None)?.into_iter().next()
            } else {
                None
            };
            self.eat_kind(TokenKind::Semicolon);
            return Ok(Item::Block(BlockDecl { quals, name, fields, instance, span: self.span_from(start) }));
        }
        let ty = self.type_ref()?;
        let name_tok = match self.peek() {
            Some(t) if t.kind == TokenKind::Identifier => t,
            _ => return self.soft(),
        };
        if self.at_op_k(1, Operator::LParen) {
            self.pos += 1;
            self.pos += 1; // `(`
            let params = self.params()?;
            let body = if self.at_kind(TokenKind::LBrace) {
                Some(self.block_body()?)
            } else {
                self.expect_kind(TokenKind::Semicolon)?;
                None
            };
            return Ok(Item::Function(Function {
                quals,
                ret: ty,
                name: name_tok.text.clone(),
                name_span: name_tok.start..name_tok.end,
                params,
                body,
                span: self.span_from(start),
            }));
        }
        let interface = quals.iter().any(|q| ["uniform", "attribute", "varying", "in", "out"].iter().any(|w| q.is_word(w)));
        let declarators = self.declarators(interface.then_some(start))?;
        self.expect_kind(TokenKind::Semicolon)?;
        Ok(Item::Var(VarDecl { quals, ty, declarators, span: self.span_from(start) }))
    }

    /// The parameter list after `(`, consuming the closing `)`.
    fn params(&mut self) -> PResult<Vec<Param>> {
        let mut params = Vec::new();
        if self.eat_op(Operator::RParen) {
            return Ok(params);
        }
        // `(void)`
        if self.at_kind(TokenKind::Keyword(Keyword::Void)) && self.at_op_k(1, Operator::RParen) {
            self.pos += 2;
            return Ok(params);
        }
        loop {
            let start = self.pos;
            let mut quals: Vec<String> = Vec::new();
            loop {
                let Some(t) = self.peek() else { return self.soft() };
                let is_qual = matches!(t.kind, TokenKind::Keyword(Keyword::Const | Keyword::In | Keyword::Out))
                    || (t.kind == TokenKind::Identifier
                        && matches!(t.text.as_str(), "inout" | "lowp" | "mediump" | "highp" | "precise" | "restrict" | "readonly" | "writeonly"));
                if is_qual {
                    quals.push(t.text.clone());
                    self.pos += 1;
                } else {
                    break;
                }
            }
            // DECLARE_SAMPLER2D_PARAMETER(name), DECLARE_SAMPLER2D_COMPARE_PARAMETER(name) (E-D8)
            let declared = if self.at_ident_text("DECLARE_SAMPLER2D_PARAMETER") {
                Some("sampler2D")
            } else if self.at_ident_text("DECLARE_SAMPLER2D_COMPARE_PARAMETER") {
                Some("sampler2DShadow")
            } else {
                None
            };
            if let Some(sampler_type) = declared.filter(|_| self.at_op_k(1, Operator::LParen)) {
                self.pos += 2;
                let name = match self.peek() {
                    Some(t) if t.kind == TokenKind::Identifier => {
                        self.pos += 1;
                        t.text.clone()
                    }
                    _ => return self.soft(),
                };
                self.expect_op(Operator::RParen)?;
                params.push(Param {
                    quals,
                    ty: TypeRef::named(sampler_type),
                    name: Some(name),
                    dims: Vec::new(),
                    sampler_param: true,
                    span: self.span_from(start),
                });
            } else {
                let ty = self.type_ref()?;
                let name = match self.peek() {
                    Some(t) if t.kind == TokenKind::Identifier => {
                        self.pos += 1;
                        Some(t.text.clone())
                    }
                    _ => None,
                };
                let mut dims = Vec::new();
                while self.at_op(Operator::LBracket) {
                    dims.push(self.dim()?);
                }
                params.push(Param { quals, ty, name, dims, sampler_param: false, span: self.span_from(start) });
            }
            if self.eat_kind(TokenKind::Comma) {
                continue;
            }
            self.expect_op(Operator::RParen)?;
            return Ok(params);
        }
    }

    // ----- statements -----

    /// `{ stmts }`, returning the statements.
    fn block_body(&mut self) -> PResult<Vec<Stmt>> {
        self.expect_kind(TokenKind::LBrace)?;
        let mut list = Vec::new();
        loop {
            match self.peek() {
                None => return self.soft(),
                Some(t) if t.kind == TokenKind::RBrace => {
                    self.pos += 1;
                    return Ok(list);
                }
                _ => {}
            }
            if let Some(s) = self.stmt_or_raw() {
                list.push(s);
            }
        }
    }

    /// A statement, or its tokens as raw text when it cannot be parsed. `None` for tokens
    /// that produce nothing (annotations).
    fn stmt_or_raw(&mut self) -> Option<Stmt> {
        if self.peek().is_some_and(Token::is_annotation) {
            self.pos += 1;
            return None;
        }
        let start = self.pos;
        match self.stmt() {
            Ok(s) => Some(s),
            Err(_) => {
                self.pos = start;
                let text = self.raw_tokens_text();
                Some(Stmt::Directive(text))
            }
        }
    }

    fn at_decl_start(&self) -> bool {
        let mut i = self.pos;
        // qualifier words
        while let Some(t) = self.toks.get(i) {
            let q = matches!(t.kind, TokenKind::Keyword(Keyword::Const))
                || (t.kind == TokenKind::Identifier
                    && matches!(t.text.as_str(), "lowp" | "mediump" | "highp" | "precise" | "volatile"));
            if q {
                i += 1;
            } else {
                break;
            }
        }
        let Some(t) = self.toks.get(i) else { return false };
        if !(Self::is_type_token(t)) {
            return false;
        }
        let mut j = i + 1;
        // optional array dims on the type
        while self.toks.get(j).is_some_and(|t| t.is_operator(Operator::LBracket)) {
            let close = self.matching(j);
            j = close + 1;
        }
        self.toks.get(j).is_some_and(|t| t.kind == TokenKind::Identifier)
    }

    fn local_decl(&mut self) -> PResult<VarDecl> {
        let start = self.pos;
        let quals = self.qualifiers(false);
        let ty = self.type_ref()?;
        let declarators = self.declarators(None)?;
        Ok(VarDecl { quals, ty, declarators, span: self.span_from(start) })
    }

    fn stmt(&mut self) -> PResult<Stmt> {
        if self.depth >= MAX_NESTING {
            return self.soft();
        }
        self.depth += 1;
        let r = self.stmt_inner();
        self.depth -= 1;
        r
    }

    fn stmt_inner(&mut self) -> PResult<Stmt> {
        let Some(t) = self.peek() else { return self.soft() };
        match t.kind {
            TokenKind::LBrace => Ok(Stmt::Block(self.block_body()?)),
            TokenKind::Semicolon => {
                self.pos += 1;
                Ok(Stmt::Empty)
            }
            TokenKind::Directive => {
                self.pos += 1;
                Ok(Stmt::Directive(t.text.clone()))
            }
            TokenKind::Keyword(Keyword::If) => self.if_stmt(),
            TokenKind::Keyword(Keyword::For) => self.for_stmt(),
            TokenKind::Keyword(Keyword::While) => self.while_stmt(),
            TokenKind::Keyword(Keyword::Do) => self.do_stmt(),
            TokenKind::Keyword(Keyword::Switch) => self.switch_stmt(),
            TokenKind::Keyword(Keyword::Return) => self.return_stmt(),
            TokenKind::Keyword(Keyword::Struct) => {
                let def = self.struct_def(Vec::new())?;
                Ok(Stmt::Struct(def))
            }
            TokenKind::Keyword(Keyword::Precision) => {
                let text = self.raw_tokens_text();
                Ok(Stmt::Directive(text))
            }
            TokenKind::Identifier => self.word_stmt(t),
            _ => self.simple_stmt(),
        }
    }

    /// Statements that start with a word: the jump statements, labels, or a simple statement.
    fn word_stmt(&mut self, t: &Token) -> PResult<Stmt> {
        match t.text.as_str() {
            "break" if self.next_is_semicolon() => {
                self.pos += 2;
                Ok(Stmt::Break)
            }
            "continue" if self.next_is_semicolon() => {
                self.pos += 2;
                Ok(Stmt::Continue)
            }
            "discard" if self.next_is_semicolon() => {
                self.pos += 2;
                Ok(Stmt::Discard)
            }
            "case" => {
                self.pos += 1;
                let e = self.ternary()?;
                self.expect_op(Operator::Colon)?;
                Ok(Stmt::Case(e))
            }
            "default" if self.at_op_k(1, Operator::Colon) => {
                self.pos += 2;
                Ok(Stmt::Default)
            }
            _ => self.simple_stmt(),
        }
    }

    /// A declaration or an expression statement.
    fn simple_stmt(&mut self) -> PResult<Stmt> {
        if self.at_decl_start() {
            let d = self.local_decl()?;
            self.expect_kind(TokenKind::Semicolon)?;
            return Ok(Stmt::Decl(d));
        }
        let e = self.expr()?;
        self.expect_kind(TokenKind::Semicolon)?;
        Ok(Stmt::Expr(e))
    }

    fn if_stmt(&mut self) -> PResult<Stmt> {
        self.pos += 1;
        self.expect_op(Operator::LParen)?;
        let cond = self.expr()?;
        self.expect_op(Operator::RParen)?;
        let then = Box::new(self.sub_stmt()?);
        let otherwise = if self.eat_kind(TokenKind::Keyword(Keyword::Else)) { Some(Box::new(self.sub_stmt()?)) } else { None };
        Ok(Stmt::If { cond, then, otherwise })
    }

    fn for_stmt(&mut self) -> PResult<Stmt> {
        self.pos += 1;
        self.expect_op(Operator::LParen)?;
        let init = if self.eat_kind(TokenKind::Semicolon) {
            None
        } else if self.at_decl_start() {
            let d = self.local_decl()?;
            self.expect_kind(TokenKind::Semicolon)?;
            Some(Box::new(Stmt::Decl(d)))
        } else {
            let e = self.expr()?;
            self.expect_kind(TokenKind::Semicolon)?;
            Some(Box::new(Stmt::Expr(e)))
        };
        let cond = if self.at_kind(TokenKind::Semicolon) { None } else { Some(self.expr()?) };
        self.expect_kind(TokenKind::Semicolon)?;
        let step = if self.at_op(Operator::RParen) { None } else { Some(self.expr()?) };
        self.expect_op(Operator::RParen)?;
        let body = Box::new(self.sub_stmt()?);
        Ok(Stmt::For { init, cond, step, body })
    }

    fn while_stmt(&mut self) -> PResult<Stmt> {
        self.pos += 1;
        self.expect_op(Operator::LParen)?;
        let cond = self.expr()?;
        self.expect_op(Operator::RParen)?;
        let body = Box::new(self.sub_stmt()?);
        Ok(Stmt::While { cond, body })
    }

    fn do_stmt(&mut self) -> PResult<Stmt> {
        self.pos += 1;
        let body = Box::new(self.sub_stmt()?);
        self.expect_kind(TokenKind::Keyword(Keyword::While))?;
        self.expect_op(Operator::LParen)?;
        let cond = self.expr()?;
        self.expect_op(Operator::RParen)?;
        self.expect_kind(TokenKind::Semicolon)?;
        Ok(Stmt::DoWhile { body, cond })
    }

    fn switch_stmt(&mut self) -> PResult<Stmt> {
        self.pos += 1;
        self.expect_op(Operator::LParen)?;
        let value = self.expr()?;
        self.expect_op(Operator::RParen)?;
        let body = self.block_body()?;
        Ok(Stmt::Switch { value, body })
    }

    fn return_stmt(&mut self) -> PResult<Stmt> {
        let start = self.pos;
        self.pos += 1;
        let value = if self.at_kind(TokenKind::Semicolon) { None } else { Some(self.expr()?) };
        self.expect_kind(TokenKind::Semicolon)?;
        Ok(Stmt::Return(value, self.span_from(start)))
    }

    fn next_is_semicolon(&self) -> bool {
        self.peek_at(1).is_some_and(|t| t.kind == TokenKind::Semicolon)
    }

    /// The body of an `if`, loop or `else`: a statement that is never silently dropped.
    fn sub_stmt(&mut self) -> PResult<Stmt> {
        if self.peek().is_some_and(Token::is_annotation) {
            self.pos += 1;
        }
        self.stmt()
    }

    // ----- expressions -----

    fn expr(&mut self) -> PResult<Expr> {
        let first = self.assign()?;
        if !self.at_kind(TokenKind::Comma) {
            return Ok(first);
        }
        let start = first.span.start;
        let mut list = vec![first];
        while self.eat_kind(TokenKind::Comma) {
            list.push(self.assign()?);
        }
        // (a comma list is flat: its depth is that of its deepest element)
        let end = list.last().unwrap().span.end;
        Ok(Expr::new(ExprKind::Comma(list), start..end))
    }

    fn assign(&mut self) -> PResult<Expr> {
        if self.depth >= MAX_NESTING {
            return self.soft();
        }
        self.depth += 1;
        let r = self.assign_inner();
        self.depth -= 1;
        r
    }

    fn assign_inner(&mut self) -> PResult<Expr> {
        let lhs = self.ternary()?;
        if let Some(t) = self.peek()
            && let TokenKind::Operator(op) = t.kind
                && is_assign_op(op) {
                    self.pos += 1;
                    let rhs = self.assign()?;
                    let span = lhs.span.start..rhs.span.end.max(lhs.span.end);
                    return Ok(Expr::new(ExprKind::Assign(op, Box::new(lhs), Box::new(rhs)), span));
                }
        Ok(lhs)
    }

    fn ternary(&mut self) -> PResult<Expr> {
        let cond = self.binary(0)?;
        if self.eat_op(Operator::Question) {
            let a = self.assign()?;
            self.expect_op(Operator::Colon)?;
            let b = self.assign()?;
            let span = cond.span.start..b.span.end.max(cond.span.end);
            return Ok(Expr::new(ExprKind::Cond(Box::new(cond), Box::new(a), Box::new(b)), span));
        }
        Ok(cond)
    }

    fn binary_prec(op: Operator) -> Option<u8> {
        Some(match op.precedence() {
            Precedence::LogicalOr => 1,
            Precedence::LogicalXor => 2,
            Precedence::LogicalAnd => 3,
            Precedence::BitOr => 4,
            Precedence::BitXor => 5,
            Precedence::BitAnd => 6,
            Precedence::Equality => 7,
            Precedence::Relational => 8,
            Precedence::Shift => 9,
            Precedence::Additive => 10,
            Precedence::Multiplicative => 11,
            _ => return None,
        })
    }

    fn binary(&mut self, min: u8) -> PResult<Expr> {
        let mut lhs = self.unary()?;
        while let Some(t) = self.peek() {
            let TokenKind::Operator(op) = t.kind else { break };
            let Some(prec) = Self::binary_prec(op) else { break };
            if prec <= min {
                break;
            }
            self.pos += 1;
            let rhs = self.binary(prec)?;
            let span = lhs.span.start..rhs.span.end.max(lhs.span.end);
            lhs = Expr::new(ExprKind::Binary(op, Box::new(lhs), Box::new(rhs)), span);
            if lhs.depth > MAX_EXPR_DEPTH {
                return self.soft();
            }
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> PResult<Expr> {
        if self.depth >= MAX_NESTING {
            return self.soft();
        }
        self.depth += 1;
        let r = self.unary_inner();
        self.depth -= 1;
        r
    }

    fn unary_inner(&mut self) -> PResult<Expr> {
        let Some(t) = self.peek() else { return self.soft() };
        if self.at_op(Operator::LParen)
            && let Some(ty) = self.toks.get(self.pos + 1)
            && builtin_type(&ty.text).is_some_and(|ty| ty.is_scalar() || ty.vec_width().is_some())
            && self.toks.get(self.pos + 2).is_some_and(|t| t.kind == TokenKind::Operator(Operator::RParen)) {
                let name = super::ty::canonical_type_name(&ty.text);
                self.pos += 3;
                let value = self.unary()?;
                let span = t.start..value.span.end;
                return Ok(Expr::new(ExprKind::Call(Callee::Cast(TypeRef::named(&name)), vec![value]), span));
            }
        if let TokenKind::Operator(op) = t.kind
            && matches!(op, Operator::Not | Operator::BitNot | Operator::Add | Operator::Sub | Operator::Inc | Operator::Dec) {
                self.pos += 1;
                let e = self.unary()?;
                let span = t.start..e.span.end.max(t.end);
                return Ok(Expr::new(ExprKind::Unary(op, Box::new(e)), span));
            }
        self.postfix()
    }

    fn postfix(&mut self) -> PResult<Expr> {
        let mut e = self.primary()?;
        while let Some(t) = self.peek() {
            match t.kind {
                TokenKind::Operator(Operator::Dot) => {
                    self.pos += 1;
                    let name = match self.peek() {
                        Some(n) if n.is_name_like() => n,
                        _ => return self.soft(),
                    };
                    self.pos += 1;
                    let start = e.span.start;
                    if self.at_op(Operator::LParen) {
                        self.pos += 1;
                        let args = self.args()?;
                        let end = self.toks[self.pos - 1].end;
                        e = Expr::new(ExprKind::Method(Box::new(e), name.text.clone(), args), start..end);
                    } else {
                        e = Expr::new(ExprKind::Member(Box::new(e), name.text.clone()), start..name.end);
                    }
                    if e.depth > MAX_EXPR_DEPTH {
                        return self.soft();
                    }
                }
                TokenKind::Operator(Operator::LBracket) => {
                    self.pos += 1;
                    let idx = self.expr()?;
                    let close = self.expect_op(Operator::RBracket)?;
                    let start = e.span.start;
                    e = Expr::new(ExprKind::Index(Box::new(e), Box::new(idx)), start..close.end);
                    if e.depth > MAX_EXPR_DEPTH {
                        return self.soft();
                    }
                }
                TokenKind::Operator(op @ (Operator::Inc | Operator::Dec)) => {
                    self.pos += 1;
                    let span = e.span.start..t.end;
                    e = Expr::new(ExprKind::Postfix(op, Box::new(e)), span);
                    if e.depth > MAX_EXPR_DEPTH {
                        return self.soft();
                    }
                }
                _ => break,
            }
        }
        Ok(e)
    }

    /// Arguments after `(`, consuming the closing `)`.
    fn args(&mut self) -> PResult<Vec<Expr>> {
        let mut args = Vec::new();
        if self.eat_op(Operator::RParen) {
            return Ok(args);
        }
        loop {
            args.push(self.assign()?);
            if self.eat_kind(TokenKind::Comma) {
                continue;
            }
            self.expect_op(Operator::RParen)?;
            return Ok(args);
        }
    }

    fn primary(&mut self) -> PResult<Expr> {
        let Some(t) = self.peek() else { return self.soft() };
        let span = t.start..t.end;
        match t.kind {
            TokenKind::Number => {
                self.pos += 1;
                Ok(Expr::new(ExprKind::Number(t.text.clone()), span))
            }
            TokenKind::StringLiteral | TokenKind::Other => {
                self.pos += 1;
                Ok(Expr::new(ExprKind::Opaque(t.text.clone()), span))
            }
            TokenKind::Operator(Operator::LParen) => {
                self.pos += 1;
                let inner = self.expr()?;
                let close = self.expect_op(Operator::RParen)?;
                Ok(Expr::new(ExprKind::Paren(Box::new(inner)), t.start..close.end))
            }
            TokenKind::LBrace => self.initializer(),
            TokenKind::Type => {
                self.pos += 1;
                let name = super::ty::canonical_type_name(&t.text);
                let mut dims = Vec::new();
                while self.at_op(Operator::LBracket) {
                    dims.push(self.dim()?);
                }
                if self.at_op(Operator::LParen) {
                    self.pos += 1;
                    let args = self.args()?;
                    let end = self.toks[self.pos - 1].end;
                    return Ok(Expr::new(ExprKind::Call(Callee::Type(TypeRef { name, dims }), args), t.start..end));
                }
                self.soft()
            }
            TokenKind::Identifier => {
                self.pos += 1;
                if t.text == "true" || t.text == "false" {
                    return Ok(Expr::new(ExprKind::Bool(t.text == "true"), span));
                }
                // An array constructor `S[2](...)` or `float2[2](...)` of a named type.
                if self.at_op(Operator::LBracket) && builtin_type(&t.text).is_some() {
                    let save = self.pos;
                    let mut dims = Vec::new();
                    while self.at_op(Operator::LBracket) {
                        dims.push(self.dim()?);
                    }
                    if self.at_op(Operator::LParen) {
                        self.pos += 1;
                        let args = self.args()?;
                        let end = self.toks[self.pos - 1].end;
                        let name = super::ty::canonical_type_name(&t.text);
                        return Ok(Expr::new(ExprKind::Call(Callee::Type(TypeRef { name, dims }), args), t.start..end));
                    }
                    self.pos = save;
                }
                if self.at_op(Operator::LParen) {
                    self.pos += 1;
                    let args = self.args()?;
                    let end = self.toks[self.pos - 1].end;
                    let callee = if builtin_type(&t.text).is_some() {
                        Callee::Type(TypeRef::named(&super::ty::canonical_type_name(&t.text)))
                    } else {
                        Callee::Name(t.text.clone())
                    };
                    return Ok(Expr::new(ExprKind::Call(callee, args), t.start..end));
                }
                Ok(Expr::new(ExprKind::Ident(t.text.clone()), span))
            }
            _ => self.soft(),
        }
    }
}

/// Tokens joined for raw carry-through.
fn join_tokens(tokens: &[Token]) -> String {
    let mut out = String::new();
    for t in tokens {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(&t.text);
    }
    out
}

/// The text inside `layout( ... )`, normalised: `a = 1, b = 2`.
fn layout_text(tokens: &[Token]) -> String {
    let mut out = String::new();
    for t in tokens {
        match t.kind {
            TokenKind::Comma => out.push_str(", "),
            TokenKind::Operator(Operator::Assign) => out.push_str(" = "),
            _ => out.push_str(&t.text),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dialect::expand::expand;
    use crate::lexer::lex;

    fn module(src: &str) -> Module {
        let tokens = expand(&lex(src)).unwrap();
        parse(&tokens).unwrap()
    }

    fn functions(m: &Module) -> Vec<&Function> {
        m.items.iter().filter_map(|i| if let Item::Function(f) = i { Some(f) } else { None }).collect()
    }

    #[test]
    fn items_in_source_order() {
        let m = module(
            "#extension GL_A : enable\nprecision mediump float;\nuniform sampler2D g_Texture0; // {\"material\":\"x\"}\nstruct S { vec4 a; float b[2]; };\nvarying vec2 v_Tex;\nvec2 f(vec2 q);\nvoid main() { }\n",
        );
        let kinds: Vec<&str> = m
            .items
            .iter()
            .map(|i| match i {
                Item::Directive(_) => "dir",
                Item::Annotation(_) => "ann",
                Item::Precision(_) => "prec",
                Item::Struct(_) => "struct",
                Item::Var(_) => "var",
                Item::Block(_) => "block",
                Item::Function(f) if f.body.is_some() => "fn",
                Item::Function(_) => "proto",
                Item::Raw(_) => "raw",
            })
            .collect();
        assert_eq!(kinds, ["dir", "prec", "var", "ann", "struct", "var", "proto", "fn"]);
    }

    #[test]
    fn qualifiers_layout_and_modifiers_parse_in_any_order() {
        let m = module("layout(set = 0, binding = 1) highp uniform vec4 a; flat layout(location=2) in lowp int b; const mediump float c = 1.0;");
        let Item::Var(a) = &m.items[0] else { panic!() };
        assert_eq!(a.quals, vec![Qualifier::Layout("set = 0, binding = 1".into()), Qualifier::Word("highp".into()), Qualifier::Word("uniform".into())]);
        let Item::Var(b) = &m.items[1] else { panic!() };
        assert_eq!(b.quals.len(), 4);
        assert_eq!(b.ty.name, "int");
        let Item::Var(c) = &m.items[2] else { panic!() };
        assert!(c.has_word("const"));
    }

    #[test]
    fn sample_is_a_qualifier_only_in_front_of_a_type() {
        let m = module("sample in vec4 x; float sample = 1.0; void f(float sample) { float g = sample; }");
        let Item::Var(x) = &m.items[0] else { panic!() };
        assert!(x.has_word("sample") && x.has_word("in"));
        let Item::Var(s) = &m.items[1] else { panic!() };
        assert!(!s.has_word("sample"));
        assert_eq!(s.declarators[0].name, "sample");
        let Item::Function(f) = &m.items[2] else { panic!() };
        assert_eq!(f.params[0].name.as_deref(), Some("sample"));
    }

    #[test]
    fn functions_have_signatures_prototypes_and_array_parameters() {
        let m = module("float a(float x[8], inout vec2 y, const in float, out float z); vec3 b(void) { return vec3(1.0); } void c() {}");
        let fs = functions(&m);
        assert_eq!(fs.len(), 3);
        assert!(fs[0].body.is_none());
        assert_eq!(fs[0].params.len(), 4);
        assert!(fs[0].params[0].dims[0].is_some());
        assert_eq!(fs[0].params[1].dir(), ParamDir::InOut);
        assert_eq!(fs[0].params[2].name, None);
        assert_eq!(fs[0].params[3].dir(), ParamDir::Out);
        assert!(fs[1].params.is_empty() && fs[1].body.is_some());
    }

    #[test]
    fn declarations_have_independent_declarators() {
        let m = module("void main() { vec3 tint = vec3(1.0), shade[3], bias = tint * 0.5; }");
        let f = functions(&m)[0];
        let Stmt::Decl(d) = &f.body.as_ref().unwrap()[0] else { panic!() };
        assert_eq!(d.declarators.len(), 3);
        assert!(d.declarators[0].init.is_some());
        assert_eq!(d.declarators[1].dims.len(), 1);
        assert!(d.declarators[1].init.is_none());
    }

    #[test]
    fn expressions_follow_c_precedence() {
        let m = module("void main() { x = a + b * c % d - -e; y = p ? q : r ? s : t; z = f(a, b)[1].xy++; }");
        let f = functions(&m)[0];
        let body = f.body.as_ref().unwrap();
        let Stmt::Expr(e) = &body[0] else { panic!() };
        // x = ((a + ((b * c) % d)) - (-e))
        let ExprKind::Assign(_, _, rhs) = &e.kind else { panic!() };
        let ExprKind::Binary(Operator::Sub, l, _) = &rhs.kind else { panic!("{:?}", rhs.kind) };
        let ExprKind::Binary(Operator::Add, _, r) = &l.kind else { panic!() };
        let ExprKind::Binary(Operator::Mod, ml, _) = &r.kind else { panic!() };
        assert!(matches!(ml.kind, ExprKind::Binary(Operator::Mul, _, _)));
        let Stmt::Expr(t) = &body[1] else { panic!() };
        let ExprKind::Assign(_, _, rhs) = &t.kind else { panic!() };
        let ExprKind::Cond(_, _, f) = &rhs.kind else { panic!() };
        assert!(matches!(f.kind, ExprKind::Cond(..)));
    }

    #[test]
    fn constructors_array_constructors_and_aliases_are_type_calls() {
        let m = module("void main() { a = float3(1.0); b = float[2](1.0, 2.0); c = S(1.0); d = mat4x4(1.0); }");
        let f = functions(&m)[0];
        let calls: Vec<&Callee> = f
            .body
            .as_ref()
            .unwrap()
            .iter()
            .filter_map(|s| {
                let Stmt::Expr(e) = s else { return None };
                let ExprKind::Assign(_, _, rhs) = &e.kind else { return None };
                let ExprKind::Call(c, _) = &rhs.kind else { return None };
                Some(c)
            })
            .collect();
        assert!(matches!(calls[0], Callee::Type(t) if t.name == "vec3"));
        assert!(matches!(calls[1], Callee::Type(t) if t.name == "float" && t.dims.len() == 1));
        assert!(matches!(calls[2], Callee::Name(n) if n == "S"));
        assert!(matches!(calls[3], Callee::Type(t) if t.name == "mat4"));
    }

    #[test]
    fn control_flow_statements() {
        let m = module(
            "void main() { for (int i = 0; i < 4; i++) if (i) continue; else break; while (x) y++; do { z--; } while (w); switch (k) { case 1: a = 1; break; default: break; } if (c) discard; return; }",
        );
        let f = functions(&m)[0];
        let body = f.body.as_ref().unwrap();
        assert!(matches!(body[0], Stmt::For { .. }));
        assert!(matches!(body[1], Stmt::While { .. }));
        assert!(matches!(body[2], Stmt::DoWhile { .. }));
        assert!(matches!(body[3], Stmt::Switch { .. }));
        assert!(matches!(body[4], Stmt::If { .. }));
        assert!(matches!(body[5], Stmt::Return(None, _)));
    }

    #[test]
    fn brace_lists_and_struct_forms() {
        let m = module("const float R[3] = {0.1, 0.5, 0.9}; struct A { int t; } a, b; struct B { vec2 v; } void main(){}");
        let Item::Var(v) = &m.items[0] else { panic!() };
        assert!(matches!(v.declarators[0].init.as_ref().unwrap().kind, ExprKind::InitList(ref l) if l.len() == 3));
        let Item::Struct(a) = &m.items[1] else { panic!() };
        assert_eq!(a.declarators.len(), 2);
        let Item::Struct(b) = &m.items[2] else { panic!("{:?}", m.items[2]) };
        assert_eq!(b.name.as_deref(), Some("B"));
        assert!(matches!(m.items[3], Item::Function(_)));
    }

    #[test]
    fn interface_blocks_parse() {
        let m = module("layout(std140, set = 0, binding = 1) uniform GlobalUniforms { vec4 a; mat4 b[2]; } u;");
        let Item::Block(b) = &m.items[0] else { panic!("{:?}", m.items[0]) };
        assert_eq!(b.name, "GlobalUniforms");
        assert_eq!(b.fields.len(), 2);
        assert_eq!(b.instance.as_ref().unwrap().name, "u");
    }

    #[test]
    fn unbalanced_delimiters_report_the_opener() {
        let src = "void main() { vec2 a = f(1; }";
        let err = parse(&lex(src)).unwrap_err();
        assert_eq!(&src[err.start..err.end], "(");
        let src2 = "void main() { if (x) { y = 1; }";
        let err = parse(&lex(src2)).unwrap_err();
        assert_eq!(&src2[err.start..err.end], "{");
        assert_eq!(&src2[err.start..err.end], "{");
        assert!(src2[..err.start].ends_with("main() "));
    }

    #[test]
    fn unknown_punctuation_is_carried_not_fatal() {
        let m = module("void main() { a = 1; @ b = 2; c = d @ e; }");
        assert_eq!(functions(&m).len(), 1);
        let m2 = module("@ float x; void main() {}");
        assert!(m2.items.iter().any(|i| matches!(i, Item::Raw(_))));
    }

    #[test]
    fn annotations_inside_bodies_are_dropped_and_between_items_kept() {
        let m = module("// [COMBO] {\"a\":1}\nvoid main() {\n// {\"x\":1}\n}");
        assert!(matches!(m.items[0], Item::Annotation(_)));
        let f = functions(&m)[0];
        assert!(f.body.as_ref().unwrap().is_empty());
    }
}
