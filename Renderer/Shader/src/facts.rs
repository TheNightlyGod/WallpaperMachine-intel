// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Token-level facts that the legalizer consumes (R43 to R49).
//!
//! Everything is derived from the token stream alone and refers to token
//! indices of the *preprocessed* text. Index ranges are half-open
//! `[start, end)`. The facts are computed once by [`Facts::analyze`]; the
//! expression helpers (operand queries, form classification) work on any token
//! range of the same stream.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ops::Range;

use crate::lexer::{Keyword, Operator, Precedence, Token, TokenKind, TokenStream};

/// Parameter qualifiers skipped when looking for a parameter's type (R46).
const PARAMETER_QUALIFIERS: [&str; 7] = ["const", "in", "out", "inout", "lowp", "mediump", "highp"];

/// Deepest nesting of ranges for which summaries are built, and the work allowed in total.
const MAX_SUMMARY_DEPTH: usize = 96;
const MAX_SUMMARY_WORK_BASE: usize = 2_000_000;
const MAX_SUMMARY_WORK_PER_TOKEN: usize = 64;

/// Deepest block nesting followed when building control-flow facts.
const MAX_FLOW_DEPTH: usize = 256;

/// A statement ending in `;` at parenthesis and bracket depth zero (R43).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Statement {
    /// First token through the `;`.
    pub range: Range<usize>,
    /// The same without the `;`.
    pub expression: Range<usize>,
}

/// One declarator of a declaration (R44).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Declarator {
    pub type_text: String,
    pub name: String,
    pub type_index: usize,
    pub name_index: usize,
    /// The statement (or `for` initializer section) holding the declaration.
    pub statement: Range<usize>,
    /// The name token through its terminating `,` or `;`, inclusive.
    pub range: Range<usize>,
    /// The tokens after the first top-level `=`, up to the terminator.
    pub initializer: Option<Range<usize>>,
}

/// An identifier, primitive type or `if for while switch` directly followed by a matching `(...)` (R45).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invocation {
    pub name: String,
    pub name_index: usize,
    pub open: usize,
    pub close: usize,
    /// Top-level arguments (split on commas at depth zero, empty segments skipped).
    pub arguments: Vec<Range<usize>>,
}

/// One parameter of a function (R46, R52).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParameterFact {
    /// The first token that is not a parameter qualifier.
    pub type_text: String,
    /// The first identifier after the type that is outside square brackets.
    pub name: Option<String>,
    /// Byte span, first token through last token of the parameter.
    pub span: Range<usize>,
    /// Token range of the parameter.
    pub tokens: Range<usize>,
    /// `name` when the parameter is `name[N]` with exactly one number or identifier inside the brackets.
    pub simple_array_name: Option<String>,
}

/// A function prototype or definition seen as a call-shaped span (R46).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignatureRecord {
    pub name: String,
    pub name_index: usize,
    pub return_type: String,
    pub parameters: Vec<ParameterFact>,
    pub is_definition: bool,
    pub open: usize,
    pub close: usize,
}

/// Control-flow nodes in source order, parents before the statements nested in them (R47).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FlowNode {
    Simple { range: Range<usize> },
    If { range: Range<usize>, condition: Range<usize>, then_body: Range<usize>, else_body: Option<Range<usize>> },
    For {
        range: Range<usize>,
        init: Option<Range<usize>>,
        condition: Option<Range<usize>>,
        step: Option<Range<usize>>,
        body: Range<usize>,
    },
    While { range: Range<usize>, condition: Range<usize>, body: Range<usize> },
    DoWhile { range: Range<usize>, body: Range<usize>, condition: Range<usize> },
}

impl FlowNode {
    pub fn range(&self) -> Range<usize> {
        match self {
            FlowNode::Simple { range }
            | FlowNode::If { range, .. }
            | FlowNode::For { range, .. }
            | FlowNode::While { range, .. }
            | FlowNode::DoWhile { range, .. } => range.clone(),
        }
    }
}

/// The operators visible at the top level of an expression range and its modulo pieces (R48).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExprSummary {
    pub range: Range<usize>,
    /// Operators outside parentheses and square brackets, restricted to the
    /// loosest-binding precedence class present, in source order. Unary signs
    /// and the grouping tokens are not listed.
    pub operators: Vec<(usize, Operator)>,
    /// Segments inside which the legalizer rewrites `%`.
    pub modulo_pieces: Vec<Range<usize>>,
}

impl ExprSummary {
    /// The pieces of the range between its listed operators (empty pieces left out).
    pub fn operands(&self) -> Vec<Range<usize>> {
        split_at(&self.range, self.operators.iter().map(|(i, _)| *i))
    }
}

/// How a range is built at its top level (R48, "top-level form").
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExprForm {
    /// Exactly one parenthesis pair; the range inside it.
    Wrapped { inner: Range<usize> },
    /// Split at the rightmost additive (or, failing that, multiplicative) operator.
    Binary { operator_index: usize, operator: Operator, left: Range<usize>, right: Range<usize> },
    /// Ends in `.name`.
    FieldSelect { base: Range<usize>, field_index: usize },
    /// Ends in a matched `[...]`.
    Subscript { base: Range<usize>, index: Range<usize> },
    /// `name ( ... )` end to end.
    Invocation { name_index: usize, open: usize, close: usize, arguments: Vec<Range<usize>> },
    /// One number or identifier token, or a sign followed by one number.
    SingleOperand,
    Other,
}

fn split_at(range: &Range<usize>, at: impl Iterator<Item = usize>) -> Vec<Range<usize>> {
    let mut pieces = Vec::new();
    let mut start = range.start;
    for index in at {
        if index > start {
            pieces.push(start..index);
        }
        start = index + 1;
    }
    if range.end > start {
        pieces.push(start..range.end);
    }
    pieces
}

/// All facts of one token stream.
#[derive(Debug)]
pub struct Facts<'a> {
    tokens: &'a TokenStream,
    /// For an opening delimiter, the index of its closing one (same-kind counting).
    close_of: Vec<Option<usize>>,
    statements: Vec<Statement>,
    declarators: Vec<Declarator>,
    invocations: Vec<Invocation>,
    signatures: Vec<SignatureRecord>,
    flow: Vec<FlowNode>,
    conditions: Vec<Range<usize>>,
    summaries: BTreeMap<(usize, usize), ExprSummary>,
}

impl<'a> Facts<'a> {
    pub fn analyze(tokens: &'a TokenStream) -> Facts<'a> {
        let mut facts = Facts {
            tokens,
            close_of: delimiter_table(tokens),
            statements: Vec::new(),
            declarators: Vec::new(),
            invocations: Vec::new(),
            signatures: Vec::new(),
            flow: Vec::new(),
            conditions: Vec::new(),
            summaries: BTreeMap::new(),
        };
        facts.find_statements();
        facts.find_flow();
        facts.find_invocations();
        facts.find_declarators();
        facts.find_signatures();
        facts.find_summaries();
        facts
    }

    pub fn tokens(&self) -> &TokenStream {
        self.tokens
    }

    pub fn statements(&self) -> &[Statement] {
        &self.statements
    }

    /// Declarators in source order.
    pub fn declarators(&self) -> &[Declarator] {
        &self.declarators
    }

    /// The declarator whose name is the token at `name_index`.
    pub fn declarator_by_name(&self, name_index: usize) -> Option<&Declarator> {
        self.declarators.iter().find(|d| d.name_index == name_index)
    }

    /// The declarators of the statement that starts at token `statement_start`.
    pub fn declarators_at_statement(&self, statement_start: usize) -> Vec<&Declarator> {
        self.declarators.iter().filter(|d| d.statement.start == statement_start).collect()
    }

    pub fn invocations(&self) -> &[Invocation] {
        &self.invocations
    }

    pub fn invocation_at(&self, name_index: usize) -> Option<&Invocation> {
        self.invocations.iter().find(|i| i.name_index == name_index)
    }

    pub fn signatures(&self) -> &[SignatureRecord] {
        &self.signatures
    }

    pub fn flow(&self) -> &[FlowNode] {
        &self.flow
    }

    /// Branch-condition ranges (`if`, `while`, `do ... while`, a non-empty `for` condition), in source order.
    pub fn branch_conditions(&self) -> &[Range<usize>] {
        &self.conditions
    }

    /// The `for` nodes, in source order.
    pub fn for_nodes(&self) -> Vec<&FlowNode> {
        self.flow.iter().filter(|n| matches!(n, FlowNode::For { .. })).collect()
    }

    /// Every expression summary, unique by range and sorted by start (R48).
    pub fn summaries(&self) -> impl Iterator<Item = &ExprSummary> {
        self.summaries.values()
    }

    /// The summary of exactly `range`, when one exists.
    pub fn summary(&self, range: Range<usize>) -> Option<&ExprSummary> {
        self.summaries.get(&(range.start, range.end))
    }

    /// The matching closer of the opener at `open`.
    pub fn close_of(&self, open: usize) -> Option<usize> {
        self.close_of.get(open).copied().flatten()
    }

    // ---- statements (R43) ----

    fn find_statements(&mut self) {
        let t = self.tokens;
        let mut depth: usize = 0;
        let skip = |mut s: usize| {
            while s < t.len() && (t[s].is_annotation() || t[s].is_directive()) {
                s += 1;
            }
            s
        };
        let mut start = skip(0);
        let mut i = start;
        while i < t.len() {
            let tok = &t[i];
            if tok.is_left_paren() || tok.is_left_bracket() {
                depth += 1;
            } else if tok.is_right_paren() || tok.is_right_bracket() {
                if depth == 0 {
                    // A closer without an opener ends statement discovery.
                    return;
                }
                depth -= 1;
            } else if depth == 0 && tok.kind == TokenKind::Semicolon {
                self.statements.push(Statement { range: start..i + 1, expression: start..i });
                start = skip(i + 1);
                i = start;
                continue;
            } else if depth == 0 && matches!(tok.kind, TokenKind::LBrace | TokenKind::RBrace) {
                start = skip(i + 1);
                i = start;
                continue;
            }
            i += 1;
        }
    }

    // ---- invocations (R45) and signatures (R46) ----

    fn find_invocations(&mut self) {
        let t = self.tokens;
        for i in 0..t.len() {
            let tok = &t[i];
            let callable = tok.is_identifier()
                || tok.is_type()
                || matches!(
                    tok.kind,
                    TokenKind::Keyword(Keyword::If | Keyword::For | Keyword::While | Keyword::Switch)
                );
            if !callable || !t.get(i + 1).is_some_and(Token::is_left_paren) {
                continue;
            }
            let Some(close) = self.close_of(i + 1) else { continue };
            let arguments = self.top_level_segments(i + 2..close).into_iter().filter(|r| !r.is_empty()).collect();
            self.invocations.push(Invocation { name: tok.text.clone(), name_index: i, open: i + 1, close, arguments });
        }
    }

    fn find_signatures(&mut self) {
        let t = self.tokens;
        let mut found = Vec::new();
        for inv in &self.invocations {
            let tok = &t[inv.name_index];
            if !tok.is_identifier() || inv.name_index == 0 {
                continue;
            }
            let prev = &t[inv.name_index - 1];
            if !(prev.is_identifier() || prev.is_type() || prev.is_keyword(Keyword::Void)) {
                continue;
            }
            let Some(after) = t.get(inv.close + 1) else { continue };
            let is_definition = after.kind == TokenKind::LBrace;
            if !(is_definition || after.kind == TokenKind::Semicolon) {
                continue;
            }
            found.push(SignatureRecord {
                name: tok.text.clone(),
                name_index: inv.name_index,
                return_type: prev.text.clone(),
                parameters: self.parameters(inv.open, inv.close),
                is_definition,
                open: inv.open,
                close: inv.close,
            });
        }
        self.signatures = found;
    }

    /// The parameters between `open` and `close` (R46, R52). A list of only `void` has none.
    pub fn parameters(&self, open: usize, close: usize) -> Vec<ParameterFact> {
        parameter_facts(self.tokens, open, close)
    }


    // ---- declarators (R44) ----

    fn find_declarators(&mut self) {
        let mut found = Vec::new();
        for st in &self.statements {
            self.declarators_of(st.range.start, st.range.end - 1, st.range.clone(), &mut found);
        }
        // The declaration part of a `for` header.
        for node in &self.flow {
            if let FlowNode::For { init: Some(init), .. } = node {
                let semicolon = init.end;
                if self.tokens.get(semicolon).is_some_and(|t| t.kind == TokenKind::Semicolon) {
                    self.declarators_of(init.start, semicolon, init.start..semicolon + 1, &mut found);
                }
            }
        }
        found.sort_by_key(|d: &Declarator| d.name_index);
        self.declarators = found;
    }

    /// Declarators of the declaration that starts at `start` and whose terminator is the token at `terminator`.
    fn declarators_of(&self, start: usize, terminator: usize, statement: Range<usize>, out: &mut Vec<Declarator>) {
        let t = self.tokens;
        let mut i = start;
        while i < terminator {
            let tok = &t[i];
            if tok.is_keyword(Keyword::Layout) && t.get(i + 1).is_some_and(Token::is_left_paren) {
                match self.close_of(i + 1) {
                    Some(c) if c < terminator => i = c + 1,
                    _ => return,
                }
            } else if tok.is_declaration_modifier()
                || matches!(
                    tok.kind,
                    TokenKind::Keyword(
                        Keyword::Attribute | Keyword::Uniform | Keyword::Varying | Keyword::In | Keyword::Out
                    )
                )
            {
                i += 1;
            } else {
                break;
            }
        }
        if i + 2 > terminator {
            return;
        }
        let type_tok = &t[i];
        if !(type_tok.is_type() || type_tok.is_identifier() || type_tok.is_keyword(Keyword::Void)) {
            return;
        }
        if !t[i + 1].is_identifier() {
            return;
        }
        // A call-shaped or function-shaped statement is not a declaration.
        if t.get(i + 2).is_some_and(Token::is_left_paren) {
            return;
        }
        let type_index = i;
        let mut pos = i + 1;
        loop {
            if !t[pos].is_identifier() {
                break;
            }
            // The declarator ends at the first top-level comma, else at the terminator.
            let mut j = pos + 1;
            let mut depth = 0usize;
            let mut equals = None;
            while j < terminator {
                let tk = &t[j];
                if tk.is_opener() {
                    depth += 1;
                } else if tk.is_closer() {
                    depth = depth.saturating_sub(1);
                } else if depth == 0 && tk.kind == TokenKind::Comma {
                    break;
                } else if depth == 0 && equals.is_none() && tk.is_simple_assignment() {
                    equals = Some(j);
                }
                j += 1;
            }
            let initializer = equals.map(|e| e + 1..j).filter(|r| !r.is_empty());
            out.push(Declarator {
                type_text: type_tok.text.clone(),
                name: t[pos].text.clone(),
                type_index,
                name_index: pos,
                statement: statement.clone(),
                range: pos..j + 1,
                initializer,
            });
            if j >= terminator {
                break;
            }
            pos = j + 1;
            if pos >= terminator {
                break;
            }
        }
    }

    // ---- control flow (R47) ----

    fn find_flow(&mut self) {
        let len = self.tokens.len();
        let mut i = 0;
        while i < len {
            i = self.parse_statement(i, len, 0);
        }
        self.flow.sort_by_key(|n| n.range().start);
        let mut conditions: Vec<Range<usize>> = Vec::new();
        for node in &self.flow {
            let candidate = match node {
                FlowNode::If { condition, .. }
                | FlowNode::While { condition, .. }
                | FlowNode::DoWhile { condition, .. } => Some(condition.clone()),
                FlowNode::For { condition, .. } => condition.clone(),
                FlowNode::Simple { .. } => None,
            };
            if let Some(c) = candidate.filter(|c| !c.is_empty()) {
                conditions.push(c);
            }
        }
        conditions.sort_by_key(|c| (c.start, c.end));
        self.conditions = conditions;
    }

    fn token(&self, i: usize, limit: usize) -> Option<&Token> {
        if i < limit { self.tokens.get(i) } else { None }
    }

    /// Parses the statement at `i` (no further than `limit`), records its nodes, returns its end.
    fn parse_statement(&mut self, i: usize, limit: usize, depth: usize) -> usize {
        let t = self.tokens;
        let tok = &t[i];
        if tok.is_annotation() || tok.is_directive() {
            return i + 1;
        }
        let end_of_group = |facts: &Facts<'_>, open: usize| facts.close_of(open).filter(|c| *c < limit);
        match tok.kind {
            TokenKind::LBrace => {
                let slot = self.flow.len();
                self.flow.push(FlowNode::Simple { range: i..limit });
                let close = end_of_group(self, i);
                let end = close.map_or(limit, |c| c + 1);
                self.flow[slot] = FlowNode::Simple { range: i..end };
                if depth < MAX_FLOW_DEPTH {
                    let inner_limit = close.unwrap_or(limit);
                    let mut j = i + 1;
                    while j < inner_limit {
                        j = self.parse_statement(j, inner_limit, depth + 1);
                    }
                }
                end
            }
            TokenKind::Keyword(Keyword::If) if self.token(i + 1, limit).is_some_and(Token::is_left_paren) => {
                let Some(close) = end_of_group(self, i + 1) else { return self.parse_simple(i, limit, depth) };
                let slot = self.flow.len();
                self.flow.push(FlowNode::Simple { range: i..close + 1 });
                let body_start = close + 1;
                let mut end = self.parse_body(body_start, limit, depth);
                let then_body = body_start..end;
                let mut else_body = None;
                if self.token(end, limit).is_some_and(|k| k.is_keyword(Keyword::Else)) {
                    let else_end = self.parse_body(end + 1, limit, depth);
                    else_body = Some(end + 1..else_end);
                    end = else_end;
                }
                self.flow[slot] = FlowNode::If { range: i..end, condition: i + 2..close, then_body, else_body };
                end
            }
            TokenKind::Keyword(Keyword::For) if self.token(i + 1, limit).is_some_and(Token::is_left_paren) => {
                let Some(close) = end_of_group(self, i + 1) else { return self.parse_simple(i, limit, depth) };
                let slot = self.flow.len();
                self.flow.push(FlowNode::Simple { range: i..close + 1 });
                let sections = self.split_semicolons(i + 2..close);
                let trimmed = |r: Option<&Range<usize>>| r.cloned().filter(|r| !r.is_empty());
                let (init, condition, step) = (trimmed(sections.first()), trimmed(sections.get(1)), trimmed(sections.get(2)));
                let end = self.parse_body(close + 1, limit, depth);
                self.flow[slot] = FlowNode::For { range: i..end, init, condition, step, body: close + 1..end };
                end
            }
            TokenKind::Keyword(Keyword::While) if self.token(i + 1, limit).is_some_and(Token::is_left_paren) => {
                let Some(close) = end_of_group(self, i + 1) else { return self.parse_simple(i, limit, depth) };
                let slot = self.flow.len();
                self.flow.push(FlowNode::Simple { range: i..close + 1 });
                let end = self.parse_body(close + 1, limit, depth);
                self.flow[slot] = FlowNode::While { range: i..end, condition: i + 2..close, body: close + 1..end };
                end
            }
            TokenKind::Keyword(Keyword::Do) => {
                let slot = self.flow.len();
                self.flow.push(FlowNode::Simple { range: i..i + 1 });
                let body_end = self.parse_body(i + 1, limit, depth);
                let body = i + 1..body_end;
                let mut end = body_end;
                let mut condition = body_end..body_end;
                if self.token(body_end, limit).is_some_and(|k| k.is_keyword(Keyword::While))
                    && self.token(body_end + 1, limit).is_some_and(Token::is_left_paren)
                    && let Some(close) = end_of_group(self, body_end + 1)
                {
                    condition = body_end + 2..close;
                    end = close + 1;
                    if self.token(end, limit).is_some_and(|k| k.kind == TokenKind::Semicolon) {
                        end += 1;
                    }
                }
                self.flow[slot] = FlowNode::DoWhile { range: i..end, body, condition };
                end
            }
            _ => self.parse_simple(i, limit, depth),
        }
    }

    /// The body of a control statement: the following statement, which may be a block.
    fn parse_body(&mut self, i: usize, limit: usize, depth: usize) -> usize {
        if i >= limit {
            return limit.max(i.min(self.tokens.len()));
        }
        if depth >= MAX_FLOW_DEPTH {
            return self.skip_statement(i, limit);
        }
        self.parse_statement(i, limit, depth + 1)
    }

    /// Ends a statement without recording nested facts (used past the depth limit).
    fn skip_statement(&self, i: usize, limit: usize) -> usize {
        let mut j = i;
        let mut depth = 0usize;
        while j < limit {
            let tok = &self.tokens[j];
            if tok.is_opener() {
                depth += 1;
            } else if tok.is_closer() {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && tok.kind == TokenKind::Semicolon {
                return j + 1;
            }
            j += 1;
        }
        limit
    }

    /// A simple statement: up to the next `;` outside brackets. A braced block inside it is recorded as well.
    /// A function definition ends at the closing brace of its body.
    fn parse_simple(&mut self, i: usize, limit: usize, depth: usize) -> usize {
        let t = self.tokens;
        let slot = self.flow.len();
        self.flow.push(FlowNode::Simple { range: i..limit });
        let mut j = i;
        let mut paren = 0usize;
        let end;
        loop {
            if j >= limit {
                end = limit;
                break;
            }
            let tok = &t[j];
            if tok.is_left_paren() || tok.is_left_bracket() {
                paren += 1;
            } else if tok.is_right_paren() || tok.is_right_bracket() {
                paren = paren.saturating_sub(1);
            } else if paren == 0 && tok.kind == TokenKind::Semicolon {
                end = j + 1;
                break;
            } else if paren == 0 && tok.kind == TokenKind::LBrace {
                let function_like = j > i && t[j - 1].is_right_paren();
                let block_end = self.parse_statement(j, limit, depth + 1);
                j = block_end;
                if function_like {
                    end = block_end;
                    break;
                }
                continue;
            } else if paren == 0 && tok.kind == TokenKind::RBrace && j > i {
                end = j;
                break;
            }
            j += 1;
        }
        let end = end.max(i + 1);
        self.flow[slot] = FlowNode::Simple { range: i..end };
        end
    }

    // ---- ranges, delimiters, segments (R49) ----

    /// The index just past the closing `}` of the block opened at `open`.
    pub fn scope_end(&self, open: usize) -> Option<usize> {
        if self.tokens.get(open)?.kind != TokenKind::LBrace {
            return None;
        }
        self.close_of(open).map(|c| c + 1)
    }

    /// The end (exclusive) of the statement controlled by the `if`, `for`, `while` or `do` at `start`,
    /// a single statement or a block, including `else` chains and `do ... while`.
    pub fn controlled_statement_end(&self, start: usize) -> Option<usize> {
        self.flow
            .iter()
            .find(|n| n.range().start == start && !matches!(n, FlowNode::Simple { .. }))
            .map(|n| n.range().end)
    }

    /// The expression inside the square brackets opened at `open`, when its `]` lies before `limit`.
    pub fn bracket_range(&self, open: usize, limit: usize) -> Option<Range<usize>> {
        if !self.tokens.get(open)?.is_left_bracket() {
            return None;
        }
        let close = self.close_of(open)?;
        (close < limit).then_some(open + 1..close)
    }

    /// True for a `+` or `-` at `index` that is a sign rather than a binary operator, inside a range starting at `range_start`.
    pub fn is_unary_sign(&self, index: usize, range_start: usize) -> bool {
        is_unary_sign(self.tokens, index, range_start)
    }

    /// Splits a range at its top-level semicolons (a `for` header). Empty segments are kept, so the sections stay in position.
    pub fn split_semicolons(&self, range: Range<usize>) -> Vec<Range<usize>> {
        let mut out = Vec::new();
        let mut start = range.start;
        let mut depth = 0usize;
        for i in range.clone() {
            let tok = &self.tokens[i];
            if tok.is_opener() {
                depth += 1;
            } else if tok.is_closer() {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && tok.kind == TokenKind::Semicolon {
                out.push(start..i);
                start = i + 1;
            }
        }
        out.push(start..range.end);
        out
    }

    /// Splits a range at its top-level commas. Empty segments are kept.
    pub fn top_level_segments(&self, range: Range<usize>) -> Vec<Range<usize>> {
        let t = self.tokens;
        let mut out = Vec::new();
        let mut start = range.start;
        let mut i = range.start;
        while i < range.end {
            let tok = &t[i];
            if tok.is_opener() {
                match self.close_of(i) {
                    // Skip the whole nested group in one step.
                    Some(close) if close < range.end => i = close + 1,
                    // An opener that never closes inside the range swallows the rest of it.
                    _ => break,
                }
                continue;
            }
            if tok.kind == TokenKind::Comma {
                out.push(start..i);
                start = i + 1;
            }
            i += 1;
        }
        out.push(start..range.end);
        out
    }

    /// The end of the top-level comma-separated segment that starts at `start` (the comma, or `limit`).
    pub fn segment_end(&self, start: usize, limit: usize) -> usize {
        let mut depth = 0usize;
        for i in start..limit.min(self.tokens.len()) {
            let tok = &self.tokens[i];
            if tok.is_opener() {
                depth += 1;
            } else if tok.is_closer() {
                if depth == 0 {
                    return i;
                }
                depth -= 1;
            } else if depth == 0 && tok.kind == TokenKind::Comma {
                return i;
            }
        }
        limit
    }

    /// `key = <integer>` inside a token range, for `set` and `binding` (R49). An occurrence not followed by
    /// `=` and a number is skipped; the first `key = <number>` whose number is not an unsigned 32-bit
    /// integer ends the search with `None`.
    pub fn layout_field(&self, range: Range<usize>, key: &str) -> Option<u32> {
        layout_field(self.tokens, range, key)
    }

    // ---- expression summaries (R48) ----

    /// The summary of any range without a closer lacking its opener.
    pub fn summarize(&self, range: Range<usize>) -> Option<ExprSummary> {
        summarize(self.tokens, range)
    }

    /// The pieces of `range` (and, recursively, of those pieces) between the requested operators (R48).
    /// A range with no matching top-level operator that is exactly one parenthesis pair is looked through.
    pub fn operands(&self, range: Range<usize>, requested: &[Operator]) -> Vec<Range<usize>> {
        let mut out: BTreeSet<(usize, usize)> = BTreeSet::new();
        self.collect_operands(range, requested, &mut out, 0);
        out.into_iter().map(|(s, len)| s..s + len).collect()
    }

    fn collect_operands(&self, range: Range<usize>, requested: &[Operator], out: &mut BTreeSet<(usize, usize)>, depth: usize) {
        if range.is_empty() || depth > 512 {
            return;
        }
        let Some(summary) = self.summarize(range.clone()) else { return };
        let matching: Vec<usize> =
            summary.operators.iter().filter(|(_, op)| requested.contains(op)).map(|(i, _)| *i).collect();
        if !matching.is_empty() {
            for piece in split_at(&range, matching.into_iter()) {
                out.insert((piece.start, piece.len()));
                self.collect_operands(piece, requested, out, depth + 1);
            }
        } else if let Some(inner) = self.wrapped_inner(&range) {
            self.collect_operands(inner, requested, out, depth + 1);
        }
    }

    /// The inside of a range that is exactly one matched parenthesis pair.
    fn wrapped_inner(&self, range: &Range<usize>) -> Option<Range<usize>> {
        let first = self.tokens.get(range.start)?;
        (first.is_left_paren() && self.close_of(range.start) == Some(range.end - 1)).then(|| range.start + 1..range.end - 1)
    }

    /// How `range` is built at its top level.
    pub fn classify(&self, range: Range<usize>) -> ExprForm {
        let t = self.tokens;
        if range.is_empty() || range.end > t.len() {
            return ExprForm::Other;
        }
        if let Some(inner) = self.wrapped_inner(&range) {
            return ExprForm::Wrapped { inner };
        }
        let Some(summary) = self.summarize(range.clone()) else { return ExprForm::Other };
        let loosest = summary.operators.first().map(|(_, op)| op.precedence());
        if loosest.is_some_and(|c| matches!(c, Precedence::Additive | Precedence::Multiplicative)) {
            let &(index, operator) = summary.operators.last().expect("non-empty");
            return ExprForm::Binary {
                operator_index: index,
                operator,
                left: range.start..index,
                right: index + 1..range.end,
            };
        }
        // Member, index and call forms only apply when nothing binds looser than they do.
        let postfix_only = loosest.is_none_or(|c| c == Precedence::Postfix);
        let last = range.end - 1;
        if postfix_only {
            if range.len() >= 3 && t[last].is_name_like() && t[last - 1].is_member_access() {
                return ExprForm::FieldSelect { base: range.start..last - 1, field_index: last };
            }
            if t[last].is_right_bracket() && range.len() >= 3 {
                // The `[` that closes at `last`.
                if let Some(open) = (range.start + 1..last).rev().find(|i| t[*i].is_left_bracket() && self.close_of(*i) == Some(last)) {
                    return ExprForm::Subscript { base: range.start..open, index: open + 1..last };
                }
            }
            if range.len() >= 3
                && t[range.start].is_name_like()
                && t[range.start + 1].is_left_paren()
                && self.close_of(range.start + 1) == Some(last)
            {
                let arguments = self.top_level_segments(range.start + 2..last).into_iter().filter(|r| !r.is_empty()).collect();
                return ExprForm::Invocation { name_index: range.start, open: range.start + 1, close: last, arguments };
            }
        }
        let single = match range.len() {
            1 => t[range.start].is_number() || t[range.start].is_identifier(),
            2 => (t[range.start].is_additive()) && t[range.start + 1].is_number(),
            _ => false,
        };
        if single { ExprForm::SingleOperand } else { ExprForm::Other }
    }

    fn find_summaries(&mut self) {
        let t = self.tokens;
        let mut queue: Vec<Range<usize>> = Vec::new();
        if !t.is_empty() {
            queue.push(0..t.len());
        }
        let mut rhs: Vec<Range<usize>> = Vec::new();
        for st in &self.statements {
            if st.expression.is_empty() {
                continue;
            }
            queue.push(st.expression.clone());
            if t[st.expression.start].is_keyword(Keyword::Return) && st.expression.len() > 1 {
                queue.push(st.expression.start + 1..st.expression.end);
            }
            if let Some(summary) = summarize(t, st.expression.clone()) {
                for (index, op) in &summary.operators {
                    if op.is_assignment() || matches!(op, Operator::Question | Operator::Colon | Operator::Comma) {
                        rhs.push(index + 1..st.expression.end);
                    }
                }
            }
        }
        queue.extend(rhs);
        for inv in &self.invocations {
            queue.push(inv.name_index..inv.close + 1);
        }
        for node in &self.flow {
            if let FlowNode::For { init: Some(init), .. } = node {
                queue.push(init.clone());
            }
        }
        let mut queue: Vec<(Range<usize>, usize)> = queue.into_iter().map(|r| (r, 0)).collect();
        let mut seen: HashSet<(usize, usize)> = HashSet::new();
        // Hostile nesting must not make the work quadratic: past these bounds no more summaries are built.
        let mut budget = MAX_SUMMARY_WORK_BASE + MAX_SUMMARY_WORK_PER_TOKEN * t.len();
        while let Some((range, depth)) = queue.pop() {
            if range.is_empty() || range.end > t.len() || depth > MAX_SUMMARY_DEPTH || !seen.insert((range.start, range.end)) {
                continue;
            }
            if budget < range.len() {
                break;
            }
            budget -= range.len();
            let Some(summary) = summarize(t, range.clone()) else { continue };
            for piece in summary.operands() {
                if piece != range {
                    queue.push((piece, depth + 1));
                }
            }
            for piece in &summary.modulo_pieces {
                if *piece != range {
                    queue.push((piece.clone(), depth + 1));
                }
            }
            // The parenthesised or bracketed groups directly inside the range, with their comma-separated
            // pieces. Groups nested deeper are reached through the inner range of their parent.
            let mut i = range.start;
            while i < range.end {
                if t[i].is_left_paren() || t[i].is_left_bracket() {
                    let Some(close) = self.close_of(i).filter(|c| *c < range.end) else { break };
                    if close > i + 1 {
                        let inner = i + 1..close;
                        for piece in self.top_level_segments(inner.clone()) {
                            if !piece.is_empty() && piece != range {
                                queue.push((piece, depth + 1));
                            }
                        }
                        if inner != range {
                            queue.push((inner, depth + 1));
                        }
                    }
                    i = close + 1;
                } else {
                    i += 1;
                }
            }
            self.summaries.insert((range.start, range.end), summary);
        }
    }
}

/// `close_of[i]` for every opening `(`, `[` or `{`: the same-kind closer that balances it.
pub(crate) fn delimiter_table(tokens: &TokenStream) -> Vec<Option<usize>> {
    let mut table = vec![None; tokens.len()];
    let mut stacks: [Vec<usize>; 3] = [Vec::new(), Vec::new(), Vec::new()];
    for (i, tok) in tokens.iter().enumerate() {
        let (kind, opens) = if tok.is_left_paren() {
            (0, true)
        } else if tok.is_right_paren() {
            (0, false)
        } else if tok.is_left_bracket() {
            (1, true)
        } else if tok.is_right_bracket() {
            (1, false)
        } else if tok.kind == TokenKind::LBrace {
            (2, true)
        } else if tok.kind == TokenKind::RBrace {
            (2, false)
        } else {
            continue;
        };
        if opens {
            stacks[kind].push(i);
        } else if let Some(open) = stacks[kind].pop() {
            table[open] = Some(i);
        }
    }
    table
}

/// R48: a `+` or `-` is a sign when it starts the range or follows `(`, a comma, an assignment,
/// `?`, `:`, a comparison, `!`, `~` or an arithmetic operator.
pub fn is_unary_sign(tokens: &TokenStream, index: usize, range_start: usize) -> bool {
    if index <= range_start {
        return true;
    }
    let prev = &tokens[index - 1];
    if prev.is_left_paren() || prev.kind == TokenKind::Comma {
        return true;
    }
    match prev.operator() {
        Some(op) => {
            op.is_assignment()
                || matches!(op, Operator::Question | Operator::Colon | Operator::Not | Operator::BitNot)
                || op.is_comparison()
                || op.is_additive()
                || op.is_multiplicative()
        }
        None => false,
    }
}

/// The operators at depth zero of a range, with unary signs and grouping tokens left out.
fn candidates(tokens: &TokenStream, range: &Range<usize>) -> Option<Vec<(usize, Operator)>> {
    let mut depth = 0usize;
    let mut out = Vec::new();
    for i in range.clone() {
        let tok = &tokens[i];
        if tok.is_left_paren() || tok.is_left_bracket() {
            depth += 1;
        } else if tok.is_right_paren() || tok.is_right_bracket() {
            if depth == 0 {
                return None;
            }
            depth -= 1;
        } else if depth == 0
            && let Some(op) = tok.operator()
        {
            if op.is_additive() && is_unary_sign(tokens, i, range.start) {
                continue;
            }
            out.push((i, op));
        }
    }
    Some(out)
}

/// R48. `None` for an empty range or one with a closer lacking its opener.
pub fn summarize(tokens: &TokenStream, range: Range<usize>) -> Option<ExprSummary> {
    if range.is_empty() || range.end > tokens.len() {
        return None;
    }
    let all = candidates(tokens, &range)?;
    let loosest = all.iter().map(|(_, op)| op.precedence()).min();
    let operators: Vec<(usize, Operator)> = match loosest {
        Some(class) => all.iter().copied().filter(|(_, op)| op.precedence() == class).collect(),
        None => Vec::new(),
    };
    // Modulo pieces: split at everything except `* / %`, compound assignments, increments, member access.
    let splits = all.iter().filter(|(_, op)| {
        op.is_simple_assignment()
            || matches!(op, Operator::Question | Operator::Colon | Operator::Comma)
            || op.is_comparison()
            || matches!(
                op,
                Operator::AndAnd
                    | Operator::OrOr
                    | Operator::XorXor
                    | Operator::Not
                    | Operator::BitAnd
                    | Operator::BitOr
                    | Operator::BitXor
                    | Operator::BitNot
                    | Operator::Shl
                    | Operator::Shr
            )
            || op.is_additive()
    });
    let modulo_pieces = split_at(&range, splits.map(|(i, _)| *i));
    Some(ExprSummary { range, operators, modulo_pieces })
}

/// R49 layout field reader.
pub fn layout_field(tokens: &TokenStream, range: Range<usize>, key: &str) -> Option<u32> {
    let mut i = range.start;
    while i < range.end {
        let tok = &tokens[i];
        if tok.is_identifier()
            && tok.text == key
            && i + 2 < range.end
            && tokens[i + 1].is_simple_assignment()
            && tokens[i + 2].is_number()
        {
            let text = &tokens[i + 2].text;
            return if text.bytes().all(|b| b.is_ascii_digit()) { text.parse::<u32>().ok() } else { None };
        }
        i += 1;
    }
    None
}


/// The parameters between `open` and `close` of a call-shaped span (R46, R52). A list of only `void` has none.
pub fn parameter_facts(tokens: &TokenStream, open: usize, close: usize) -> Vec<ParameterFact> {
    let t = tokens;
    let mut out = Vec::new();
    for segment in top_level_segments(tokens, open + 1..close) {
            let indices: Vec<usize> =
                segment.clone().filter(|i| !t[*i].is_annotation() && !t[*i].is_directive()).collect();
            let (Some(&first), Some(&last)) = (indices.first(), indices.last()) else { continue };
            let Some(type_pos) = indices.iter().position(|i| !PARAMETER_QUALIFIERS.contains(&t[*i].text.as_str()))
            else {
                continue;
            };
            let type_index = indices[type_pos];
            let mut name = None;
            let mut simple_array_name = None;
            let mut depth = 0usize;
            for (k, &i) in indices.iter().enumerate().skip(type_pos + 1) {
                let tok = &t[i];
                if tok.is_left_bracket() {
                    depth += 1;
                } else if tok.is_right_bracket() {
                    depth = depth.saturating_sub(1);
                } else if depth == 0 && tok.is_identifier() && name.is_none() {
                    name = Some(tok.text.clone());
                    if let (Some(&b), Some(&inner), Some(&c)) = (indices.get(k + 1), indices.get(k + 2), indices.get(k + 3))
                        && t[b].is_left_bracket()
                        && (t[inner].is_number() || t[inner].is_identifier())
                        && t[c].is_right_bracket()
                        && indices.get(k + 4).is_none()
                    {
                        simple_array_name = Some(tok.text.clone());
                    }
                }
            }
            out.push(ParameterFact {
                type_text: t[type_index].text.clone(),
                name,
                span: t[first].start..t[last].end,
                tokens: first..last + 1,
                simple_array_name,
            });
        }
        // A list of only `void` has no parameters.
        if out.len() == 1 && out[0].type_text == "void" && out[0].name.is_none() && out[0].tokens.len() == 1 {
            out.clear();
        }
        out
}

/// Splits a range at its top-level commas. Empty segments are kept.
pub fn top_level_segments(tokens: &TokenStream, range: Range<usize>) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut start = range.start;
    let mut depth = 0usize;
    for i in range.clone() {
        let tok = &tokens[i];
        if tok.is_opener() {
            depth += 1;
        } else if tok.is_closer() {
            depth = depth.saturating_sub(1);
        } else if depth == 0 && tok.kind == TokenKind::Comma {
            out.push(start..i);
            start = i + 1;
        }
    }
    out.push(start..range.end);
    out
}

#[cfg(test)]
mod tests;
