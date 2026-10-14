//! Property visibility condition DSL used by Wallpaper Engine.
//!
//! Grammar:
//! ```text
//! condition  := and_expr ( "||" and_expr )*
//! and_expr   := unary ( "&&" unary )*
//! unary      := "!" unary | primary
//! primary    := "(" condition ")" | "true" | "false" | membership | property
//! property   := ident "." "value" ( op literal )?
//! membership := "[" ( literal ( "," literal )* )? "]" "." "includes" "(" ident "." "value" ")"
//! op         := "==" | "===" | "!=" | "!==" | ">=" | "<=" | ">" | "<"
//! literal    := Number | String | Bool
//! ```
//!
//! Strings may be written with either quote and have no escapes. `true` and
//! `false` are constants only when no `.` follows them, so a property may still
//! be named `true`. A leading `!` negates the whole comparison that follows
//! it, so `!a.value == 1` is `!(a.value == 1)`. `===` and `!==` behave as `==`
//! and `!=`: the app stores combo selections as strings, and a strict type
//! match would hide controls that Wallpaper Engine shows.
//!
//! Project files are untrusted Workshop data, so the parser bounds its input.
//! A rule that is too long, nests too deeply or lists too many elements is
//! an error, exactly like one that is not understood, and an unreadable rule
//! leaves its property visible.

use super::property::PropertyValue;
use crate::{BridgeError, BridgeErrorKind};

#[derive(Clone, Debug, PartialEq)]
pub enum Condition {
    Or(Box<Condition>, Box<Condition>),
    And(Box<Condition>, Box<Condition>),
    Not(Box<Condition>),
    Truthy(String),
    Compare(String, CmpOp, Literal),
    /// `[a, b].includes(id.value)`.
    In(String, Vec<Literal>),
    /// A bare `true` or `false`.
    Const(bool),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CmpOp {
    Eq,
    Ne,
    Ge,
    Le,
    Gt,
    Lt,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Literal {
    Number(f64),
    String(String),
    Bool(bool),
}

/// Longest rule accepted, in bytes. The longest rule in a real library is a
/// fraction of this.
const MAX_CONDITION_BYTES: usize = 2048;
/// Deepest nesting of `(` and `!` accepted. The parser recurses once per level.
const MAX_NESTING: usize = 24;
/// Most elements accepted in one `[...]` list.
const MAX_LIST_ELEMENTS: usize = 256;

impl Condition {
    /// # Errors
    ///
    /// Returns an error when the condition string does not match the supported
    /// DSL grammar or exceeds the length, nesting or list-size bounds.
    pub fn parse(input: &str) -> Result<Self, BridgeError> {
        if input.len() > MAX_CONDITION_BYTES {
            return Err(condition_error(0, "condition too long"));
        }

        let tokens = Token::tokenize(input)?;
        let mut parser = Parser {
            tokens,
            pos: 0,
            depth: 0,
        };
        let condition = parser.parse_or()?;

        if parser.pos != parser.tokens.len() {
            let pos = parser.tokens[parser.pos].pos;
            return Err(condition_error(pos, "trailing tokens"));
        }

        Ok(condition)
    }

    #[must_use]
    pub fn eval(&self, lookup: &impl Fn(&str) -> Option<PropertyValue>) -> bool {
        match self {
            Condition::Or(left, right) => left.eval(lookup) || right.eval(lookup),
            Condition::And(left, right) => left.eval(lookup) && right.eval(lookup),
            Condition::Not(inner) => !inner.eval(lookup),
            Condition::Const(value) => *value,
            Condition::Truthy(id) => match lookup(id) {
                Some(PropertyValue::Bool(value)) => value,
                Some(PropertyValue::Number(value)) => value != 0.0,
                Some(PropertyValue::String(value)) => {
                    let value = value.trim();
                    !value.is_empty()
                        && !matches!(value.to_ascii_lowercase().as_str(), "0" | "false")
                }
                Some(PropertyValue::Null) => false,
                None | Some(PropertyValue::ColorRgb(..)) => true,
            },
            Condition::Compare(id, op, literal) => {
                lookup(id).is_none_or(|value| compare(&value, *op, literal))
            }
            Condition::In(id, literals) => lookup(id).is_none_or(|value| {
                literals
                    .iter()
                    .any(|literal| compare(&value, CmpOp::Eq, literal))
            }),
        }
    }
}

/// Compares a property's value with a literal the way the rule language does:
/// numbers and booleans numerically, everything else through its text.
fn compare(value: &PropertyValue, op: CmpOp, literal: &Literal) -> bool {
    match (value, literal) {
        (PropertyValue::Number(left), Literal::Number(right)) => {
            compare_number(*left, *right, op)
        }
        (PropertyValue::Bool(left), Literal::Number(right)) => {
            let left = if *left { 1.0 } else { 0.0 };
            compare_number(left, *right, op)
        }
        (PropertyValue::Bool(left), Literal::Bool(right)) => match op {
            CmpOp::Eq => left == right,
            CmpOp::Ne => left != right,
            _ => {
                let left = if *left { 1.0 } else { 0.0 };
                let right = if *right { 1.0 } else { 0.0 };
                compare_number(left, right, op)
            }
        },
        (value, literal) => {
            let value = match value {
                PropertyValue::Bool(value) => value.to_string(),
                PropertyValue::Number(value) => {
                    if value.fract() == 0.0 {
                        format!("{value:.0}")
                    } else {
                        value.to_string()
                    }
                }
                PropertyValue::String(value) => value.clone(),
                PropertyValue::ColorRgb(r, g, b) => format!("{r} {g} {b}"),
                PropertyValue::Null => String::new(),
            };
            let literal = match literal {
                Literal::Number(value) => {
                    if value.fract() == 0.0 {
                        format!("{value:.0}")
                    } else {
                        value.to_string()
                    }
                }
                Literal::String(value) => value.clone(),
                Literal::Bool(value) => value.to_string(),
            };

            match op {
                CmpOp::Eq => value == literal,
                CmpOp::Ne => value != literal,
                CmpOp::Ge => {
                    value.trim().parse::<f64>().unwrap_or(0.0)
                        >= literal.trim().parse::<f64>().unwrap_or(0.0)
                }
                CmpOp::Le => {
                    value.trim().parse::<f64>().unwrap_or(0.0)
                        <= literal.trim().parse::<f64>().unwrap_or(0.0)
                }
                CmpOp::Gt => {
                    value.trim().parse::<f64>().unwrap_or(0.0)
                        > literal.trim().parse::<f64>().unwrap_or(0.0)
                }
                CmpOp::Lt => {
                    value.trim().parse::<f64>().unwrap_or(0.0)
                        < literal.trim().parse::<f64>().unwrap_or(0.0)
                }
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Token {
    kind: TokenKind,
    pos: usize,
}

impl Token {
    #[allow(clippy::single_call_fn, clippy::too_many_lines)] // Tokenization is a distinct grammar unit for this DSL parser.
    pub fn tokenize(input: &str) -> Result<Vec<Self>, BridgeError> {
        let bytes = input.as_bytes();
        let mut tokens = Vec::new();
        let mut pos = 0;

        while let Some(&byte) = bytes.get(pos) {
            let ch = byte as char;
            if ch.is_ascii_whitespace() {
                pos += 1;
                continue;
            }

            match ch {
                '.' => {
                    tokens.push(Token {
                        kind: TokenKind::Dot,
                        pos,
                    });
                    pos += 1;
                }
                '!' => {
                    if bytes.get(pos + 1) == Some(&b'=') && bytes.get(pos + 2) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::StrictNe,
                            pos,
                        });
                        pos += 3;
                    } else if bytes.get(pos + 1) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::Ne,
                            pos,
                        });
                        pos += 2;
                    } else {
                        tokens.push(Token {
                            kind: TokenKind::Not,
                            pos,
                        });
                        pos += 1;
                    }
                }
                '=' => {
                    if bytes.get(pos + 1) == Some(&b'=') && bytes.get(pos + 2) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::StrictEq,
                            pos,
                        });
                        pos += 3;
                    } else if bytes.get(pos + 1) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::Eq,
                            pos,
                        });
                        pos += 2;
                    } else {
                        return Err(condition_error(pos, "bare `=`"));
                    }
                }
                '>' => {
                    if bytes.get(pos + 1) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::Ge,
                            pos,
                        });
                        pos += 2;
                    } else {
                        tokens.push(Token {
                            kind: TokenKind::Gt,
                            pos,
                        });
                        pos += 1;
                    }
                }
                '<' => {
                    if bytes.get(pos + 1) == Some(&b'=') {
                        tokens.push(Token {
                            kind: TokenKind::Le,
                            pos,
                        });
                        pos += 2;
                    } else {
                        tokens.push(Token {
                            kind: TokenKind::Lt,
                            pos,
                        });
                        pos += 1;
                    }
                }
                '&' => {
                    if bytes.get(pos + 1) == Some(&b'&') {
                        tokens.push(Token {
                            kind: TokenKind::And,
                            pos,
                        });
                        pos += 2;
                    } else {
                        return Err(condition_error(pos, "bare `&`"));
                    }
                }
                '|' => {
                    if bytes.get(pos + 1) == Some(&b'|') {
                        tokens.push(Token {
                            kind: TokenKind::Or,
                            pos,
                        });
                        pos += 2;
                    } else {
                        return Err(condition_error(pos, "bare `|`"));
                    }
                }
                '(' | ')' | '[' | ']' | ',' => {
                    let kind = match ch {
                        '(' => TokenKind::LParen,
                        ')' => TokenKind::RParen,
                        '[' => TokenKind::LBracket,
                        ']' => TokenKind::RBracket,
                        _ => TokenKind::Comma,
                    };
                    tokens.push(Token { kind, pos });
                    pos += 1;
                }
                '"' | '\'' => {
                    let start = pos + 1;
                    let mut end = start;
                    while end < bytes.len() && bytes[end] != byte {
                        end += 1;
                    }

                    if end >= bytes.len() {
                        return Err(condition_error(start, "unclosed string"));
                    }

                    tokens.push(Token {
                        kind: TokenKind::String(input[start..end].to_string()),
                        pos,
                    });
                    pos = end + 1;
                }
                '-' | '0'..='9' => {
                    let start = pos;
                    let (value, next_pos) = {
                        let mut number_pos = pos;

                        if bytes[number_pos] == b'-' {
                            number_pos += 1;
                        }

                        let digits_start = number_pos;
                        while matches!(bytes.get(number_pos), Some(b'0'..=b'9')) {
                            number_pos += 1;
                        }

                        let mut saw_fraction = false;
                        if bytes.get(number_pos) == Some(&b'.') {
                            saw_fraction = true;
                            number_pos += 1;
                            let fraction_start = number_pos;
                            while matches!(bytes.get(number_pos), Some(b'0'..=b'9')) {
                                number_pos += 1;
                            }

                            if number_pos == fraction_start {
                                return Err(condition_error(start, "bad number"));
                            }
                        }

                        if number_pos == digits_start {
                            return Err(condition_error(start, "bad number"));
                        }

                        if matches!(
                            bytes.get(number_pos),
                            Some(b'a'..=b'z' | b'A'..=b'Z' | b'_' | b'.')
                        ) {
                            return Err(condition_error(start, "bad number"));
                        }

                        let text = &input[start..number_pos];
                        let value = text
                            .parse::<f64>()
                            .map_err(|_| condition_error(start, "bad number"))?;

                        if saw_fraction && text.ends_with('.') {
                            return Err(condition_error(start, "bad number"));
                        }

                        (value, number_pos)
                    };
                    pos = next_pos;
                    tokens.push(Token {
                        kind: TokenKind::Number(value),
                        pos: start,
                    });
                }
                'a'..='z' | 'A'..='Z' | '_' => {
                    let start = pos;
                    pos += 1;
                    while let Some(&next) = bytes.get(pos) {
                        let next = next as char;
                        if next.is_ascii_alphanumeric() || next == '_' {
                            pos += 1;
                        } else {
                            break;
                        }
                    }

                    tokens.push(Token {
                        kind: TokenKind::Ident(input[start..pos].to_string()),
                        pos: start,
                    });
                }
                _ => {
                    return Err(condition_error(pos, format!("unexpected `{ch}`")));
                }
            }
        }

        Ok(tokens)
    }
}

#[derive(Clone, Debug, PartialEq)]
enum TokenKind {
    Ident(String),
    Number(f64),
    String(String),
    Dot,
    Not,
    And,
    Or,
    Eq,
    Ne,
    StrictEq,
    StrictNe,
    Ge,
    Le,
    Gt,
    Lt,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Comma,
}

fn condition_error(pos: usize, reason: impl Into<String>) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Project,
        message: format!("condition parse error at {pos}: {}", reason.into()),
    }
}

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    /// How many `(` and `!` enclose the token being parsed.
    depth: usize,
}

impl Parser {
    fn parse_or(&mut self) -> Result<Condition, BridgeError> {
        let mut condition = self.parse_and()?;
        while self.matches(&TokenKind::Or) {
            let right = self.parse_and()?;
            condition = Condition::Or(Box::new(condition), Box::new(right));
        }
        Ok(condition)
    }

    fn parse_and(&mut self) -> Result<Condition, BridgeError> {
        let mut condition = self.parse_unary()?;
        while self.matches(&TokenKind::And) {
            let right = self.parse_unary()?;
            condition = Condition::And(Box::new(condition), Box::new(right));
        }
        Ok(condition)
    }

    fn parse_unary(&mut self) -> Result<Condition, BridgeError> {
        if self.matches(&TokenKind::Not) {
            self.enter()?;
            let inner = self.parse_unary();
            self.depth -= 1;
            return Ok(Condition::Not(Box::new(inner?)));
        }

        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<Condition, BridgeError> {
        if self.matches(&TokenKind::LParen) {
            self.enter()?;
            let inner = self.parse_or();
            self.depth -= 1;
            let inner = inner?;
            self.expect(&TokenKind::RParen, "`)`")?;
            return Ok(inner);
        }

        if self.peek_kind_is(&TokenKind::LBracket) {
            return self.parse_membership();
        }

        if let Some(value) = self.take_constant() {
            return Ok(Condition::Const(value));
        }

        let ident = self.expect_ident()?;
        self.expect(&TokenKind::Dot, "`.`")?;
        self.expect_word("value")?;

        let Some(op) = self.peek_cmp() else {
            return Ok(Condition::Truthy(ident));
        };

        self.pos += 1;
        let literal = self.parse_literal()?;
        Ok(Condition::Compare(ident, op, literal))
    }

    /// `[a, b].includes(id.value)`
    fn parse_membership(&mut self) -> Result<Condition, BridgeError> {
        self.expect(&TokenKind::LBracket, "`[`")?;

        let mut literals = Vec::new();
        if !self.matches(&TokenKind::RBracket) {
            loop {
                if literals.len() >= MAX_LIST_ELEMENTS {
                    let pos = self.peek_pos().unwrap_or_else(|| self.eof_pos());
                    return Err(condition_error(pos, "list too long"));
                }

                literals.push(self.parse_literal()?);
                if !self.matches(&TokenKind::Comma) {
                    self.expect(&TokenKind::RBracket, "`]`")?;
                    break;
                }
            }
        }

        self.expect(&TokenKind::Dot, "`.`")?;
        self.expect_word("includes")?;
        self.expect(&TokenKind::LParen, "`(`")?;
        let ident = self.expect_ident()?;
        self.expect(&TokenKind::Dot, "`.`")?;
        self.expect_word("value")?;
        self.expect(&TokenKind::RParen, "`)`")?;
        Ok(Condition::In(ident, literals))
    }

    fn parse_literal(&mut self) -> Result<Literal, BridgeError> {
        match self.bump() {
            Some(Token {
                kind: TokenKind::Number(value),
                ..
            }) => Ok(Literal::Number(value)),
            Some(Token {
                kind: TokenKind::String(value),
                ..
            }) => Ok(Literal::String(value)),
            Some(Token {
                kind: TokenKind::Ident(value),
                ..
            }) if value == "true" => Ok(Literal::Bool(true)),
            Some(Token {
                kind: TokenKind::Ident(value),
                ..
            }) if value == "false" => Ok(Literal::Bool(false)),
            Some(token) => Err(condition_error(token.pos, "expected literal")),
            None => Err(condition_error(self.eof_pos(), "expected literal")),
        }
    }

    /// Descends one nesting level, so hostile input cannot recurse without
    /// bound. Every successful call is paired with `self.depth -= 1`.
    fn enter(&mut self) -> Result<(), BridgeError> {
        if self.depth >= MAX_NESTING {
            let pos = self.peek_pos().unwrap_or_else(|| self.eof_pos());
            return Err(condition_error(pos, "condition nested too deeply"));
        }

        self.depth += 1;
        Ok(())
    }

    /// Consumes `true` or `false` unless a `.` follows, which makes it the
    /// name of a property.
    fn take_constant(&mut self) -> Option<bool> {
        let value = match self.tokens.get(self.pos).map(|token| &token.kind) {
            Some(TokenKind::Ident(word)) if word == "true" => true,
            Some(TokenKind::Ident(word)) if word == "false" => false,
            _ => return None,
        };
        let names_property = matches!(
            self.tokens.get(self.pos + 1).map(|token| &token.kind),
            Some(TokenKind::Dot)
        );
        if names_property {
            return None;
        }

        self.pos += 1;
        Some(value)
    }

    fn expect_ident(&mut self) -> Result<String, BridgeError> {
        match self.bump() {
            Some(Token {
                kind: TokenKind::Ident(value),
                ..
            }) => Ok(value),
            Some(token) => Err(condition_error(token.pos, "expected identifier")),
            None => Err(condition_error(self.eof_pos(), "expected identifier")),
        }
    }

    fn expect_word(&mut self, word: &str) -> Result<(), BridgeError> {
        match self.bump() {
            Some(Token {
                kind: TokenKind::Ident(value),
                ..
            }) if value == word => Ok(()),
            Some(token) => Err(condition_error(token.pos, format!("expected `{word}`"))),
            None => Err(condition_error(self.eof_pos(), format!("expected `{word}`"))),
        }
    }

    fn matches(&mut self, kind: &TokenKind) -> bool {
        if self.peek_kind_is(kind) {
            self.pos += 1;
            return true;
        }

        false
    }

    fn expect(&mut self, kind: &TokenKind, expected: &str) -> Result<(), BridgeError> {
        if self.matches(kind) {
            return Ok(());
        }

        let pos = self.peek_pos().unwrap_or_else(|| self.eof_pos());
        Err(condition_error(pos, format!("expected {expected}")))
    }

    fn peek_cmp(&self) -> Option<CmpOp> {
        match self.tokens.get(self.pos).map(|token| &token.kind) {
            Some(TokenKind::Eq | TokenKind::StrictEq) => Some(CmpOp::Eq),
            Some(TokenKind::Ne | TokenKind::StrictNe) => Some(CmpOp::Ne),
            Some(TokenKind::Ge) => Some(CmpOp::Ge),
            Some(TokenKind::Le) => Some(CmpOp::Le),
            Some(TokenKind::Gt) => Some(CmpOp::Gt),
            Some(TokenKind::Lt) => Some(CmpOp::Lt),
            _ => None,
        }
    }

    /// Whether the next token is of the same kind as `expected`, ignoring any
    /// text or number it carries.
    fn peek_kind_is(&self, expected: &TokenKind) -> bool {
        self.tokens.get(self.pos).is_some_and(|token| {
            std::mem::discriminant(&token.kind) == std::mem::discriminant(expected)
        })
    }

    fn bump(&mut self) -> Option<Token> {
        let token = self.tokens.get(self.pos).cloned();
        if token.is_some() {
            self.pos += 1;
        }
        token
    }

    fn peek_pos(&self) -> Option<usize> {
        self.tokens.get(self.pos).map(|token| token.pos)
    }

    fn eof_pos(&self) -> usize {
        self.tokens.last().map_or(0, |token| token.pos + 1)
    }
}

fn compare_number(left: f64, right: f64, op: CmpOp) -> bool {
    match op {
        CmpOp::Eq => left
            .partial_cmp(&right)
            .is_some_and(std::cmp::Ordering::is_eq),
        CmpOp::Ne => !left
            .partial_cmp(&right)
            .is_some_and(std::cmp::Ordering::is_eq),
        CmpOp::Ge => left >= right,
        CmpOp::Le => left <= right,
        CmpOp::Gt => left > right,
        CmpOp::Lt => left < right,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lookup<'a>(
        items: &'a [(&'a str, PropertyValue)],
    ) -> impl Fn(&str) -> Option<PropertyValue> + 'a {
        move |key| {
            items
                .iter()
                .find(|(id, _)| *id == key)
                .map(|(_, value)| value.clone())
        }
    }

    #[test]
    fn truthy_bool() {
        let condition = Condition::parse("foo.value").unwrap();
        assert!(condition.eval(&lookup(&[("foo", PropertyValue::Bool(true))])));
        assert!(!condition.eval(&lookup(&[("foo", PropertyValue::Bool(false))])));
    }

    #[test]
    fn not_inverts() {
        let condition = Condition::parse("!foo.value").unwrap();
        assert!(condition.eval(&lookup(&[("foo", PropertyValue::Bool(false))])));
    }

    #[test]
    fn numeric_eq() {
        let condition = Condition::parse("x.value==1").unwrap();
        assert!(condition.eval(&lookup(&[("x", PropertyValue::Number(1.0))])));
        assert!(!condition.eval(&lookup(&[("x", PropertyValue::Number(2.0))])));
    }

    #[test]
    fn numeric_ge_lt() {
        let ge = Condition::parse("x.value>=5").unwrap();
        let lt = Condition::parse("x.value<5").unwrap();
        assert!(ge.eval(&lookup(&[("x", PropertyValue::Number(5.0))])));
        assert!(!ge.eval(&lookup(&[("x", PropertyValue::Number(4.0))])));
        assert!(lt.eval(&lookup(&[("x", PropertyValue::Number(4.0))])));
        assert!(!lt.eval(&lookup(&[("x", PropertyValue::Number(5.0))])));
    }

    #[test]
    fn string_eq_permissive_coercion() {
        let condition = Condition::parse(r#"x.value=="1""#).unwrap();
        assert!(condition.eval(&lookup(&[("x", PropertyValue::Number(1.0))])));
        assert!(condition.eval(&lookup(&[("x", PropertyValue::String("1".into()))])));
    }

    #[test]
    fn missing_id_is_fail_open() {
        let truthy = Condition::parse("absent.value").unwrap();
        let compare = Condition::parse("absent.value==1").unwrap();
        assert!(truthy.eval(&lookup(&[])));
        assert!(compare.eval(&lookup(&[])));
    }

    #[test]
    fn string_truthy_matches_condition_semantics() {
        let condition = Condition::parse("x.value").unwrap();
        assert!(condition.eval(&lookup(&[("x", PropertyValue::String("yes".into()))])));
        assert!(!condition.eval(&lookup(&[("x", PropertyValue::String(String::new()))])));
        assert!(!condition.eval(&lookup(&[("x", PropertyValue::String("0".into()))])));
        assert!(!condition.eval(&lookup(&[("x", PropertyValue::String("false".into()))])));
    }

    #[test]
    fn keyword_named_property_ids_are_allowed() {
        let condition = Condition::parse("true.value&&value.value&&false.value==true").unwrap();
        assert!(condition.eval(&lookup(&[
            ("true", PropertyValue::Bool(true)),
            ("value", PropertyValue::Bool(true)),
            ("false", PropertyValue::Bool(true)),
        ])));
    }

    #[test]
    fn compound_and() {
        let condition = Condition::parse("a.value&&b.value&&c.value").unwrap();
        assert!(condition.eval(&lookup(&[
            ("a", PropertyValue::Bool(true)),
            ("b", PropertyValue::Bool(true)),
            ("c", PropertyValue::Bool(true)),
        ])));
        assert!(!condition.eval(&lookup(&[
            ("a", PropertyValue::Bool(true)),
            ("b", PropertyValue::Bool(false)),
            ("c", PropertyValue::Bool(true)),
        ])));
    }

    #[test]
    fn or_precedence_without_parentheses() {
        let condition = Condition::parse("a.value||b.value&&c.value").unwrap();
        assert!(condition.eval(&lookup(&[
            ("a", PropertyValue::Bool(true)),
            ("b", PropertyValue::Bool(false)),
            ("c", PropertyValue::Bool(false)),
        ])));
        assert!(!condition.eval(&lookup(&[
            ("a", PropertyValue::Bool(false)),
            ("b", PropertyValue::Bool(true)),
            ("c", PropertyValue::Bool(false)),
        ])));
    }

    fn bools<'a>(
        items: &'a [(&'a str, bool)],
    ) -> impl Fn(&str) -> Option<PropertyValue> + 'a {
        move |key| {
            items
                .iter()
                .find(|(id, _)| *id == key)
                .map(|(_, value)| PropertyValue::Bool(*value))
        }
    }

    #[test]
    fn bare_boolean_atoms_follow_javascript_logic() {
        let trailing_true = Condition::parse("a.value && true").unwrap();
        let plain = Condition::parse("a.value").unwrap();
        let and_false = Condition::parse("a.value&&false").unwrap();
        let only_false = Condition::parse("false").unwrap();
        let only_true = Condition::parse(" true ").unwrap();
        let or_true = Condition::parse("true || a.value").unwrap();

        for a in [true, false] {
            let items = [("a", a)];
            assert_eq!(
                trailing_true.eval(&bools(&items)),
                plain.eval(&bools(&items))
            );
            assert!(!and_false.eval(&bools(&items)));
            assert!(!only_false.eval(&bools(&items)));
            assert!(only_true.eval(&bools(&items)));
        }
        assert!(or_true.eval(&bools(&[("a", false)])));
    }

    #[test]
    fn a_comparison_chain_with_a_trailing_constant_is_readable() {
        let condition = Condition::parse("a.value == true && b.value && true").unwrap();
        assert!(condition.eval(&bools(&[("a", true), ("b", true)])));
        assert!(!condition.eval(&bools(&[("a", true), ("b", false)])));
        assert!(!condition.eval(&bools(&[("a", false), ("b", true)])));
    }

    #[test]
    fn parentheses_group_before_precedence() {
        let grouped = Condition::parse("(a.value || b.value) && c.value").unwrap();
        let ungrouped = Condition::parse("a.value || b.value && c.value").unwrap();
        let items = [("a", true), ("b", false), ("c", false)];
        assert!(!grouped.eval(&bools(&items)));
        assert!(ungrouped.eval(&bools(&items)));

        let negated_group = Condition::parse("!(a.value && b.value)").unwrap();
        assert!(negated_group.eval(&bools(&[("a", true), ("b", false)])));
        assert!(!negated_group.eval(&bools(&[("a", true), ("b", true)])));

        let double_negation = Condition::parse("!!a.value").unwrap();
        assert!(double_negation.eval(&bools(&[("a", true)])));
        assert!(!double_negation.eval(&bools(&[("a", false)])));
    }

    #[test]
    fn negation_still_covers_the_whole_comparison() {
        let condition = Condition::parse("!x.value == 1").unwrap();
        assert!(!condition.eval(&lookup(&[("x", PropertyValue::Number(1.0))])));
        assert!(condition.eval(&lookup(&[("x", PropertyValue::Number(2.0))])));
    }

    #[test]
    fn single_and_double_quoted_strings_are_equal() {
        let single = Condition::parse("x.value == 'night'").unwrap();
        let double = Condition::parse(r#"x.value == "night""#).unwrap();
        for value in ["night", "day"] {
            let items = [("x", PropertyValue::String(value.into()))];
            assert_eq!(single.eval(&lookup(&items)), double.eval(&lookup(&items)));
        }
        assert!(single.eval(&lookup(&[("x", PropertyValue::String("night".into()))])));
        assert!(!single.eval(&lookup(&[("x", PropertyValue::String("day".into()))])));
    }

    #[test]
    fn strict_operators_behave_like_loose_ones() {
        let equal = Condition::parse("x.value === 1").unwrap();
        assert!(equal.eval(&lookup(&[("x", PropertyValue::Number(1.0))])));
        assert!(equal.eval(&lookup(&[("x", PropertyValue::String("1".into()))])));
        assert!(!equal.eval(&lookup(&[("x", PropertyValue::Number(2.0))])));

        let different = Condition::parse(r#"x.value !== "2""#).unwrap();
        assert!(different.eval(&lookup(&[("x", PropertyValue::Number(1.0))])));
        assert!(!different.eval(&lookup(&[("x", PropertyValue::Number(2.0))])));
    }

    #[test]
    fn array_membership_uses_property_coercion() {
        let numbers = Condition::parse("[1, 2, 3].includes(n.value)").unwrap();
        assert!(numbers.eval(&lookup(&[("n", PropertyValue::Number(2.0))])));
        // Combo selections are stored as strings.
        assert!(numbers.eval(&lookup(&[("n", PropertyValue::String("3".into()))])));
        assert!(!numbers.eval(&lookup(&[("n", PropertyValue::Number(4.0))])));
        assert!(!numbers.eval(&lookup(&[("n", PropertyValue::String("4".into()))])));
        // An id the project does not define never hides a row.
        assert!(numbers.eval(&lookup(&[])));

        let words = Condition::parse(r#"['day', "night"].includes(t.value)"#).unwrap();
        assert!(words.eval(&lookup(&[("t", PropertyValue::String("night".into()))])));
        assert!(!words.eval(&lookup(&[("t", PropertyValue::String("dusk".into()))])));

        let empty = Condition::parse("[].includes(n.value)").unwrap();
        assert!(!empty.eval(&lookup(&[("n", PropertyValue::Number(1.0))])));

        let negated = Condition::parse("![1, 2].includes(n.value)").unwrap();
        assert!(negated.eval(&lookup(&[("n", PropertyValue::Number(5.0))])));
    }

    #[test]
    fn membership_combines_with_the_other_operators() {
        let condition =
            Condition::parse("a.value == true && b.value && [3, 4, 5].includes(n.value)").unwrap();
        let on = |n: f64| {
            [
                ("a", PropertyValue::Bool(true)),
                ("b", PropertyValue::Bool(true)),
                ("n", PropertyValue::Number(n)),
            ]
        };
        assert!(condition.eval(&lookup(&on(4.0))));
        assert!(!condition.eval(&lookup(&on(9.0))));
    }

    #[test]
    fn still_unreadable_rules_stay_errors() {
        for rule in [
            "Math.abs(a.value)",
            "a.value == b.value",
            "(a.value",
            "a.value)",
            "[1, 2].includes(a.value",
            "[1, 2].includes(3)",
            "[1,,2].includes(a.value)",
            "[1, 2,].includes(a.value)",
            "[1, 2].indexOf(a.value)",
            "[1, 2]",
            "a.value = 1",
            "a.value ==== 1",
            "a.value == 'unclosed",
            "1",
            "",
        ] {
            assert!(Condition::parse(rule).is_err(), "`{rule}` should not parse");
        }
    }

    #[test]
    fn hostile_inputs_are_bounded() {
        // Deep enough to overflow the stack if the parser followed it.
        let nested = format!("{}a.value{}", "(".repeat(1_000), ")".repeat(1_000));
        assert!(Condition::parse(&nested).is_err());
        assert!(Condition::parse(&format!("{}a.value", "!".repeat(1_000))).is_err());

        let long = vec!["a.value"; 400].join(" && ");
        assert!(long.len() > 3_000);
        assert!(Condition::parse(&long).is_err());

        let elements = |count: usize| {
            format!("[{}].includes(n.value)", vec!["1"; count].join(","))
        };
        assert!(Condition::parse(&elements(256)).is_ok());
        assert!(Condition::parse(&elements(257)).is_err());

        let at_limit = format!("{}a.value{}", "(".repeat(MAX_NESTING), ")".repeat(MAX_NESTING));
        assert!(Condition::parse(&at_limit).is_ok());
        let past_limit = format!(
            "{}a.value{}",
            "(".repeat(MAX_NESTING + 1),
            ")".repeat(MAX_NESTING + 1)
        );
        assert!(Condition::parse(&past_limit).is_err());
    }

    #[test]
    fn malformed_fails() {
        assert!(Condition::parse("foo.value = 1").is_err());
        assert!(Condition::parse("foo.value & bar.value").is_err());
        assert!(Condition::parse(r#"foo.value=="unterminated"#).is_err());
        assert!(Condition::parse("foo.value @ 1").is_err());
        assert!(Condition::parse("foo.value==1.2.3").is_err());
    }
}
