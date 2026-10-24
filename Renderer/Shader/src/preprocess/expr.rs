// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! `#if` and `#elif` expressions (R24 to R26, R25a).
//!
//! Integers, identifiers, `|| && ! == != < <= > >=`, parentheses and one
//! optional trailing `;`. Identifiers read their macro's replacement text:
//! undefined is 0, a plain number is that number, anything else is opaque.
//! There is no short circuit: both operands are always evaluated, so an invalid
//! right operand fails even when the left one already decides the result.

use std::collections::HashMap;

use crate::names::is_identifier;

/// The longest chain of single-identifier macros followed inside a comparison (R25a).
const MAX_CHAIN_LINKS: usize = 16;
/// Nesting of parentheses and `!` accepted before the expression is refused.
const MAX_NESTING: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Value {
    Int(i64),
    Frac(f64),
    /// Text that is not a plain number; truthy or not, and never comparable.
    Opaque(bool),
}

impl Value {
    fn truthy(self) -> bool {
        match self {
            Value::Int(i) => i != 0,
            Value::Frac(f) => f != 0.0,
            Value::Opaque(t) => t,
        }
    }

    fn flag(b: bool) -> Value {
        Value::Int(i64::from(b))
    }
}

/// A plain number (R25): optional sign, digits, optionally a dot and more digits.
fn plain_number(text: &str) -> Option<Value> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    let (int_part, frac_part) = match digits.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (digits, None),
    };
    let all_digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if !all_digits(int_part) || frac_part.is_some_and(|f| !all_digits(f)) {
        return None;
    }
    match frac_part {
        None => text.parse::<i64>().ok().map(Value::Int),
        Some(_) => {
            // The integer part must itself fit a signed 64-bit integer.
            let signed_int = &text[..text.len() - digits.len() + int_part.len()];
            signed_int.parse::<i64>().ok()?;
            text.parse::<f64>().ok().map(Value::Frac)
        }
    }
}

fn value_of_text(text: &str) -> Value {
    let text = text.trim();
    plain_number(text).unwrap_or_else(|| Value::Opaque(!text.is_empty() && text != "0"))
}

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Int(i64),
    Ident(String),
    OrOr,
    AndAnd,
    Not,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    LParen,
    RParen,
}

fn unsupported(detail: impl AsRef<str>) -> String {
    format!("#if expression is unsupported: {}", detail.as_ref())
}

fn tokenize(expr: &str) -> Result<Vec<Tok>, String> {
    let bytes = expr.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        let next = bytes.get(i + 1).copied();
        match c {
            b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c => i += 1,
            b'0'..=b'9' => {
                let start = i;
                while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                    i += 1;
                }
                let value = expr[start..i]
                    .parse::<i64>()
                    .map_err(|_| unsupported(format!("the integer literal `{}` is out of range", &expr[start..i])))?;
                toks.push(Tok::Int(value));
            }
            c if c.is_ascii_alphabetic() || c == b'_' => {
                let start = i;
                while bytes.get(i).is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_') {
                    i += 1;
                }
                toks.push(Tok::Ident(expr[start..i].to_string()));
            }
            b'|' if next == Some(b'|') => {
                toks.push(Tok::OrOr);
                i += 2;
            }
            b'&' if next == Some(b'&') => {
                toks.push(Tok::AndAnd);
                i += 2;
            }
            b'=' if next == Some(b'=') => {
                toks.push(Tok::Eq);
                i += 2;
            }
            b'!' if next == Some(b'=') => {
                toks.push(Tok::Ne);
                i += 2;
            }
            b'<' if next == Some(b'=') => {
                toks.push(Tok::Le);
                i += 2;
            }
            b'>' if next == Some(b'=') => {
                toks.push(Tok::Ge);
                i += 2;
            }
            b'!' => {
                toks.push(Tok::Not);
                i += 1;
            }
            b'<' => {
                toks.push(Tok::Lt);
                i += 1;
            }
            b'>' => {
                toks.push(Tok::Gt);
                i += 1;
            }
            b'(' => {
                toks.push(Tok::LParen);
                i += 1;
            }
            b')' => {
                toks.push(Tok::RParen);
                i += 1;
            }
            b';' => {
                // Only a single terminator at the very end.
                if expr[i + 1..].trim().is_empty() {
                    break;
                }
                return Err(unsupported("text after the `;` terminator"));
            }
            _ => {
                let ch = expr[i..].chars().next().unwrap_or('?');
                return Err(unsupported(format!("the character `{}` is not allowed", ch.escape_default())));
            }
        }
    }
    Ok(toks)
}

struct Operand {
    value: Value,
    /// The name, when the operand was a bare identifier (not parenthesised, not under `!`).
    ident: Option<String>,
}

struct Parser<'a> {
    toks: Vec<Tok>,
    pos: usize,
    depth: usize,
    env: &'a HashMap<String, String>,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn or(&mut self) -> Result<Value, String> {
        let mut left = self.and()?;
        while self.peek() == Some(&Tok::OrOr) {
            self.pos += 1;
            let right = self.and()?;
            left = Value::flag(left.truthy() || right.truthy());
        }
        Ok(left)
    }

    fn and(&mut self) -> Result<Value, String> {
        let mut left = self.comparison()?;
        while self.peek() == Some(&Tok::AndAnd) {
            self.pos += 1;
            let right = self.comparison()?;
            left = Value::flag(left.truthy() && right.truthy());
        }
        Ok(left)
    }

    fn comparison(&mut self) -> Result<Value, String> {
        let first = self.unary()?;
        let is_cmp = |t: Option<&Tok>| matches!(t, Some(Tok::Eq | Tok::Ne | Tok::Lt | Tok::Le | Tok::Gt | Tok::Ge));
        if !is_cmp(self.peek()) {
            return Ok(first.value);
        }
        let mut left = self.comparable(first)?;
        while is_cmp(self.peek()) {
            let op = self.toks[self.pos].clone();
            self.pos += 1;
            let rhs = self.unary()?;
            let right = self.comparable(rhs)?;
            let ord = match (left, right) {
                (Value::Int(a), Value::Int(b)) => a.partial_cmp(&b),
                (a, b) => as_f64(a).partial_cmp(&as_f64(b)),
            };
            let result = match op {
                Tok::Eq => ord == Some(std::cmp::Ordering::Equal),
                Tok::Ne => ord != Some(std::cmp::Ordering::Equal),
                Tok::Lt => ord == Some(std::cmp::Ordering::Less),
                Tok::Le => matches!(ord, Some(std::cmp::Ordering::Less | std::cmp::Ordering::Equal)),
                Tok::Gt => ord == Some(std::cmp::Ordering::Greater),
                _ => matches!(ord, Some(std::cmp::Ordering::Greater | std::cmp::Ordering::Equal)),
            };
            left = Value::flag(result);
        }
        Ok(left)
    }

    /// A number for a comparison, following single-identifier macro chains (R25a).
    fn comparable(&self, operand: Operand) -> Result<Value, String> {
        if !matches!(operand.value, Value::Opaque(_)) {
            return Ok(operand.value);
        }
        let Some(name) = operand.ident else {
            return Err(unsupported("a value that is not a number cannot be compared"));
        };
        let mut visited = vec![name.clone()];
        let mut current = name;
        let mut links = 0;
        loop {
            let text = self.env.get(&current).map(|t| t.trim()).unwrap_or("");
            if let Some(v) = plain_number(text) {
                return Ok(v);
            }
            if !is_identifier(text) {
                return Err(unsupported(format!("`{current}` is not a number and cannot be compared")));
            }
            links += 1;
            if links > MAX_CHAIN_LINKS {
                return Err(unsupported(format!("the macro chain from `{}` is longer than {MAX_CHAIN_LINKS} links", visited[0])));
            }
            if !self.env.contains_key(text) {
                return Err(unsupported(format!("`{text}` (the value of `{current}`) is not defined, so `{}` cannot be compared", visited[0])));
            }
            if visited.iter().any(|v| v == text) {
                return Err(unsupported(format!("the macro chain from `{}` loops back to `{text}`", visited[0])));
            }
            visited.push(text.to_string());
            current = text.to_string();
        }
    }

    fn unary(&mut self) -> Result<Operand, String> {
        self.depth += 1;
        if self.depth > MAX_NESTING {
            return Err(unsupported("the expression is nested too deeply"));
        }
        let result = self.unary_inner();
        self.depth -= 1;
        result
    }

    fn unary_inner(&mut self) -> Result<Operand, String> {
        let Some(tok) = self.toks.get(self.pos).cloned() else {
            return Err(unsupported("the expression ends where a value was expected"));
        };
        self.pos += 1;
        match tok {
            Tok::Not => {
                let inner = self.unary()?;
                Ok(Operand { value: Value::flag(!inner.value.truthy()), ident: None })
            }
            Tok::Int(i) => Ok(Operand { value: Value::Int(i), ident: None }),
            Tok::Ident(name) => {
                let value = match self.env.get(&name) {
                    None => Value::Int(0),
                    Some(text) => value_of_text(text),
                };
                Ok(Operand { value, ident: Some(name) })
            }
            Tok::LParen => {
                let value = self.or()?;
                if self.peek() != Some(&Tok::RParen) {
                    return Err(unsupported("a `(` is not closed"));
                }
                self.pos += 1;
                Ok(Operand { value, ident: None })
            }
            other => Err(unsupported(format!("unexpected {}", describe(&other)))),
        }
    }
}

fn as_f64(v: Value) -> f64 {
    match v {
        Value::Int(i) => i as f64,
        Value::Frac(f) => f,
        Value::Opaque(_) => f64::NAN,
    }
}

fn describe(tok: &Tok) -> String {
    match tok {
        Tok::Int(i) => format!("`{i}`"),
        Tok::Ident(n) => format!("`{n}`"),
        Tok::OrOr => "`||`".into(),
        Tok::AndAnd => "`&&`".into(),
        Tok::Not => "`!`".into(),
        Tok::Eq => "`==`".into(),
        Tok::Ne => "`!=`".into(),
        Tok::Lt => "`<`".into(),
        Tok::Le => "`<=`".into(),
        Tok::Gt => "`>`".into(),
        Tok::Ge => "`>=`".into(),
        Tok::LParen => "`(`".into(),
        Tok::RParen => "`)`".into(),
    }
}

/// The first token of a directive expression that no preprocessor expression can contain, which
/// marks the text as a test of run-time values (`g_Texture0Resolution.x < g_Texture0Resolution.y`):
/// a `.` after a name, a number or a `)` (a member access), and any character outside names,
/// numbers, parentheses and the operators of the C preprocessor (`[`, `,`, a quote...). Tokens of
/// that language this evaluator does not support (`defined`, arithmetic, `?:`, `0x10`, `2.5`) are
/// not such a mark. `None` when there is no such token.
pub(super) fn runtime_token(expr: &str) -> Option<String> {
    let bytes = expr.as_bytes();
    let number_byte = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'.';
    let mut i = 0;
    // The previous token was a name, a number or a `)`.
    let mut after_operand = false;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_ascii_whitespace() {
            i += 1;
        } else if c.is_ascii_digit() || (c == b'.' && !after_operand && bytes.get(i + 1).is_some_and(u8::is_ascii_digit)) {
            // A number as the C preprocessor reads one: digits, letters, `_`, `.` and an exponent sign.
            i += 1;
            while i < bytes.len() && (number_byte(bytes[i]) || (matches!(bytes[i], b'+' | b'-') && matches!(bytes[i - 1], b'e' | b'E'))) {
                i += 1;
            }
            after_operand = true;
        } else if c.is_ascii_alphabetic() || c == b'_' {
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            after_operand = true;
        } else if c == b')' {
            i += 1;
            after_operand = true;
        } else if b"(!=<>&|+-*/%^~?:;".contains(&c) {
            i += 1;
            after_operand = false;
        } else {
            let ch = expr[i..].chars().next().unwrap_or('?');
            return Some(format!("`{}`", ch.escape_default()));
        }
    }
    None
}

/// Evaluates a (comment-stripped, trimmed) directive expression. The error is the message text.
pub(super) fn evaluate(expr: &str, env: &HashMap<String, String>) -> Result<bool, String> {
    let toks = tokenize(expr)?;
    if toks.is_empty() {
        return Err("#if expects an expression".to_string());
    }
    let mut parser = Parser { toks, pos: 0, depth: 0, env };
    let value = parser.or()?;
    if let Some(extra) = parser.peek() {
        return Err(unsupported(format!("unexpected {} after the expression", describe(extra))));
    }
    Ok(value.truthy())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn eval(expr: &str, pairs: &[(&str, &str)]) -> Result<bool, String> {
        evaluate(expr, &env(pairs))
    }

    fn ok(expr: &str, pairs: &[(&str, &str)]) -> bool {
        eval(expr, pairs).unwrap_or_else(|e| panic!("{expr}: {e}"))
    }

    fn fails(expr: &str, pairs: &[(&str, &str)]) -> String {
        eval(expr, pairs).expect_err(expr)
    }

    #[test]
    fn precedence_and_grouping() {
        let e = [("A", "1"), ("B", "0"), ("C", "0")];
        assert!(ok("A || B && C", &e));
        assert!(!ok("(A || B) && C", &e));
        // `!` binds tighter than `==`: (!A) == B is 0 == 0.
        assert!(ok("!A == B", &e));
        assert!(!ok("!(A == B)", &[("A", "0"), ("B", "0")]));
        let x = |v: &'static str| [("X", v)];
        for (v, expected) in [("3", true), ("7", true), ("8", false), ("2", false), ("12", true)] {
            assert_eq!(ok("X >= 3 && X <= 7 || X == 12", &x(v)), expected, "{v}");
        }
        assert!(ok("X != 0", &x("5")));
        assert!(!ok("X != 0", &x("0")));
    }

    #[test]
    fn chained_comparisons_compare_the_zero_one_result() {
        assert!(ok("1 < 2 < 3", &[]));
        // (3 < 2) is 0, and 0 < 1.
        assert!(ok("3 < 2 < 1", &[]));
        // (1 == 1) is 1, and 1 == 1.
        assert!(ok("1 == 1 == 1", &[]));
        assert!(!ok("2 == 2 == 2", &[]));
    }

    #[test]
    fn terminators_comments_and_spacing() {
        assert!(ok("LEVEL >= 2;", &[("LEVEL", "2")]));
        assert!(ok("  LEVEL >= 2 ;  ", &[("LEVEL", "2")]));
        assert!(ok("(Z)", &[("Z", "1")]));
        assert!(!ok("(Z)", &[]));
        assert!(fails("A; B", &[]).contains("#if expression is unsupported"));
        assert!(fails("A;;", &[]).contains("#if expression is unsupported"));
    }

    #[test]
    fn an_empty_expression_is_its_own_error() {
        assert_eq!(fails("", &[]), "#if expects an expression");
        assert_eq!(fails("   ", &[]), "#if expects an expression");
        assert_eq!(fails(";", &[]), "#if expects an expression");
    }

    #[test]
    fn unsupported_constructs_name_the_phrase() {
        let e = [("A", "1"), ("B", "2"), ("C", "3"), ("X", "1")];
        for expr in [
            "defined(X)",
            "defined X",
            "A + 1",
            "A - 1",
            "A * 2",
            "A / 2",
            "A % 2",
            "A & B",
            "A | B",
            "A << 1",
            "~A",
            "-1",
            "0x10",
            "1u",
            "1.5",
            "A ? B : C",
            "(A",
            "A)",
            "A B",
            "A = B",
            "A == ",
            "&& A",
            "A $ B",
            "99999999999999999999",
        ] {
            let message = fails(expr, &e);
            assert!(message.contains("#if expression is unsupported"), "{expr}: {message}");
        }
    }

    #[test]
    fn both_operands_are_evaluated_so_a_bad_right_side_fails() {
        assert!(fails("1 || (", &[]).contains("unsupported"));
        assert!(fails("0 && 0x1", &[]).contains("unsupported"));
    }

    #[test]
    fn a_comparison_with_an_opaque_right_side_fails_even_under_a_decided_or() {
        let e = [("SKIN", "sprite")];
        assert!(eval("1 || SKIN == 1", &e).is_err());
    }

    #[test]
    fn undefined_names_are_zero() {
        assert!(!ok("NOPE", &[]));
        assert!(ok("!NOPE", &[]));
        assert!(ok("NOPE == 0", &[]));
        assert!(ok("NOPE < 62", &[]));
        assert!(ok("SHADERVERSION < 62", &[]));
        assert!(!ok("NOPE >= 1", &[]));
    }

    #[test]
    fn identifier_values_follow_the_replacement_text() {
        // An object-like macro whose text is another unknown word is opaque and truthy.
        assert!(ok("SKIN", &[("SKIN", "sprite")]));
        assert!(fails("SKIN == 1", &[("SKIN", "sprite")]).contains("unsupported"));
        assert!(!ok("MUTE", &[("MUTE", "0")]));
        // A function-like macro name alone is truthy.
        assert!(ok("Blend", &[("Blend", "(a * b)")]));
        assert!(!ok("SPEED", &[("SPEED", "0.0")]));
        assert!(!ok("SPEED", &[("SPEED", "-0.00")]));
        assert!(ok("SPEED", &[("SPEED", "0.25")]));
        let gain = [("GAIN", "2.5")];
        assert!(ok("GAIN > 2", &gain));
        assert!(!ok("GAIN == 2", &gain));
        assert!(fails("GAIN <= 2.5", &gain).contains("unsupported"));
        assert!(ok("GAIN >= 1", &[("GAIN", "1.5")]));
        assert!(!ok("GAIN == 1", &[("GAIN", "1.5")]));
        let cap = [("CAP", "1.5f")];
        assert!(ok("CAP", &cap));
        assert!(fails("CAP == 1", &cap).contains("unsupported"));
        assert!(ok("HALF > 0 && HALF < 1", &[("HALF", "0.5")]));
        // A negative macro value is a plain number, even though the literal `-3` is not allowed.
        assert!(ok("N < 0", &[("N", "-3")]));
    }

    #[test]
    fn plain_numbers_are_strict() {
        assert_eq!(plain_number("7"), Some(Value::Int(7)));
        assert_eq!(plain_number("-3"), Some(Value::Int(-3)));
        assert_eq!(plain_number("+3"), Some(Value::Int(3)));
        assert_eq!(plain_number("0.0"), Some(Value::Frac(0.0)));
        assert_eq!(plain_number("1.5"), Some(Value::Frac(1.5)));
        for text in ["", "-", ".5", "5.", "1e3", "1.5f", "2u", "0x10", "1 2", "--1", "99999999999999999999", "99999999999999999999.5"] {
            assert_eq!(plain_number(text), None, "{text:?}");
        }
    }

    #[test]
    fn a_combo_value_with_a_fraction_is_that_number() {
        assert!(ok("Q > 0", &[("Q", "0.5")]));
        assert!(!ok("Q", &[("Q", "0.0")]));
    }

    #[test]
    fn symbolic_right_hand_sides_compare_as_numbers() {
        let e = [("SIDE", "3"), ("RIGHT", "3"), ("LEFT", "1")];
        assert!(ok("SIDE == RIGHT", &e));
        assert!(!ok("SIDE == LEFT", &e));
        assert!(ok("SIDE != LEFT", &e));
    }

    #[test]
    fn macro_chains_resolve_in_comparisons_only() {
        let e = [("TIER_HIGH", "3"), ("TIER", "TIER_HIGH")];
        assert!(ok("TIER == 3", &e));
        assert!(!ok("TIER == 4", &e));
        assert!(ok("TIER", &e));
        assert!(ok("3 == TIER", &e));
        // Three links.
        let e3 = [("A", "B"), ("B", "C"), ("C", "D"), ("D", "5")];
        assert!(ok("A == 5", &e3));
        // A link to an undefined name.
        assert!(fails("A == 5", &[("A", "NOWHERE")]).contains("unsupported"));
        // Two macros defined in terms of each other.
        let cycle = [("P", "Q"), ("Q", "P")];
        assert!(fails("P == 1", &cycle).contains("unsupported"));
        // A self-reference.
        assert!(fails("P == 1", &[("P", "P")]).contains("unsupported"));
        // `!` and parentheses are not direct operands, so no chain is followed.
        assert!(fails("(TIER) == 3", &e).contains("unsupported"));
        assert!(ok("!TIER == 0", &e));
    }

    #[test]
    fn chain_length_limit_is_sixteen_links() {
        let build = |links: usize| -> HashMap<String, String> {
            let mut m = HashMap::new();
            for i in 0..links {
                m.insert(format!("M{i}"), format!("M{}", i + 1));
            }
            m.insert(format!("M{links}"), "7".into());
            m
        };
        assert_eq!(evaluate("M0 == 7", &build(16)), Ok(true));
        assert!(evaluate("M0 == 7", &build(17)).unwrap_err().contains("unsupported"));
    }

    #[test]
    fn deep_nesting_is_refused_instead_of_overflowing_the_stack() {
        let open = "(".repeat(5000);
        let close = ")".repeat(5000);
        let message = fails(&format!("{open}1{close}"), &[]);
        assert!(message.contains("nested too deeply"), "{message}");
        let bangs = "!".repeat(5000);
        assert!(fails(&format!("{bangs}1"), &[]).contains("nested too deeply"));
        // A reasonable depth still works.
        assert!(ok(&format!("{}1{}", "(".repeat(50), ")".repeat(50)), &[]));
    }
}
