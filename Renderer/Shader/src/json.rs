// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! A small strict JSON reader and compact writer.
//!
//! The reader keeps object members in document order (including duplicates, so
//! the schema layer can report them), keeps numbers as their source text (the
//! metadata scanner needs the text exactly as written) and bounds its recursion
//! so a hostile document cannot overflow a small thread stack.

use std::fmt;

/// Deepest array/object nesting the reader accepts.
pub const MAX_DEPTH: usize = 128;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<Value>),
    /// Members in document order; duplicates are preserved.
    Object(Vec<(String, Value)>),
}

impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Bool(_) => "a boolean",
            Value::Number(_) => "a number",
            Value::String(_) => "a string",
            Value::Array(_) => "an array",
            Value::Object(_) => "an object",
        }
    }
}

/// A number token that obeys the JSON grammar, kept as written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Number {
    text: String,
}

impl Number {
    pub fn as_str(&self) -> &str {
        &self.text
    }

    /// True for tokens with neither a fraction nor an exponent.
    pub fn is_integer(&self) -> bool {
        !self.text.contains(['.', 'e', 'E'])
    }

    /// The value as a finite `f64`, or `None` when it overflows.
    pub fn as_f64(&self) -> Option<f64> {
        self.text.parse::<f64>().ok().filter(|v| v.is_finite())
    }

    /// The value as an unsigned integer. Only plain non-negative integer
    /// tokens qualify (`1.0` and `1e2` do not), and `-0` is rejected.
    pub fn as_u64(&self) -> Option<u64> {
        if !self.is_integer() || self.text.starts_with('-') {
            return None;
        }
        self.text.parse::<u64>().ok()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonError {
    pub offset: usize,
    pub message: String,
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at byte {}", self.message, self.offset)
    }
}

impl std::error::Error for JsonError {}

/// Parses one complete JSON document; anything after it is an error.
pub fn parse(text: &str) -> Result<Value, JsonError> {
    let mut p = Parser { bytes: text.as_bytes(), text, pos: 0 };
    p.skip_ws();
    let value = p.value(0)?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(p.error("unexpected trailing characters after the document"));
    }
    Ok(value)
}

struct Parser<'a> {
    bytes: &'a [u8],
    text: &'a str,
    pos: usize,
}

impl Parser<'_> {
    fn error(&self, message: &str) -> JsonError {
        JsonError { offset: self.pos, message: message.to_string() }
    }

    fn skip_ws(&mut self) {
        while matches!(self.bytes.get(self.pos), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn expect_literal(&mut self, literal: &str, value: Value) -> Result<Value, JsonError> {
        if self.bytes[self.pos..].starts_with(literal.as_bytes()) {
            self.pos += literal.len();
            Ok(value)
        } else {
            Err(self.error("invalid literal"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, JsonError> {
        match self.peek() {
            None => Err(self.error("unexpected end of document")),
            Some(b'n') => self.expect_literal("null", Value::Null),
            Some(b't') => self.expect_literal("true", Value::Bool(true)),
            Some(b'f') => self.expect_literal("false", Value::Bool(false)),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.error("unexpected character")),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, JsonError> {
        if depth >= MAX_DEPTH {
            return Err(self.error("nesting is too deep"));
        }
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(self.error("expected `,` or `]`")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, JsonError> {
        if depth >= MAX_DEPTH {
            return Err(self.error("nesting is too deep"));
        }
        self.pos += 1;
        let mut members = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(members));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(self.error("expected a string key"));
            }
            let key = self.string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(self.error("expected `:` after the key"));
            }
            self.pos += 1;
            self.skip_ws();
            let value = self.value(depth + 1)?;
            members.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(members));
                }
                _ => return Err(self.error("expected `,` or `}`")),
            }
        }
    }

    fn number(&mut self) -> Result<Value, JsonError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => self.digits(),
            _ => return Err(self.error("a number needs digits")),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.error("a fraction needs digits"));
            }
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.error("an exponent needs digits"));
            }
            self.digits();
        }
        Ok(Value::Number(Number { text: self.text[start..self.pos].to_string() }))
    }

    fn digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        let end = self.pos + 4;
        let digits = self
            .bytes
            .get(self.pos..end)
            .filter(|d| d.iter().all(u8::is_ascii_hexdigit))
            .ok_or_else(|| self.error("a \\u escape needs four hex digits"))?;
        // The slice is ASCII hex digits, so both conversions are infallible.
        let value = u32::from_str_radix(std::str::from_utf8(digits).unwrap_or("0"), 16).unwrap_or(0);
        self.pos = end;
        Ok(value)
    }

    fn string(&mut self) -> Result<String, JsonError> {
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            let run_start = self.pos;
            while let Some(b) = self.peek() {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            // Runs end at ASCII bytes, so they are valid UTF-8 slices of the input.
            out.push_str(&self.text[run_start..self.pos]);
            match self.peek() {
                None => return Err(self.error("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let esc = self.peek().ok_or_else(|| self.error("unterminated escape"))?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let first = self.hex4()?;
                            let ch = if (0xD800..0xDC00).contains(&first) {
                                if !self.bytes[self.pos..].starts_with(b"\\u") {
                                    return Err(self.error("a high surrogate needs a low surrogate"));
                                }
                                self.pos += 2;
                                let second = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&second) {
                                    return Err(self.error("invalid low surrogate"));
                                }
                                0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&first) {
                                return Err(self.error("unpaired low surrogate"));
                            } else {
                                first
                            };
                            out.push(char::from_u32(ch).unwrap_or('\u{FFFD}'));
                        }
                        _ => return Err(self.error("invalid escape")),
                    }
                }
                Some(_) => return Err(self.error("control character in string")),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Writer. Documents are assembled from fragments, always compact.

/// A JSON string literal for `s`.
pub fn string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// An array from already-serialised items.
pub fn array<I: IntoIterator<Item = String>>(items: I) -> String {
    let mut out = String::from("[");
    for (i, item) in items.into_iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&item);
    }
    out.push(']');
    out
}

/// An object from already-serialised values, keys in the order given.
pub fn object(fields: &[(&str, String)]) -> String {
    let mut out = String::from("{");
    for (i, (key, value)) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&string(key));
        out.push(':');
        out.push_str(value);
    }
    out.push('}');
    out
}

pub fn boolean(b: bool) -> String {
    if b { "true" } else { "false" }.to_string()
}

pub fn null() -> String {
    "null".to_string()
}

/// The shortest decimal text that reads back as the same `f32`, or `None` for
/// NaN and infinities (which JSON cannot carry).
pub fn f32_token(x: f32) -> Option<String> {
    x.is_finite().then(|| format!("{x}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_scalars_and_containers() {
        let v = parse(r#" {"a":[1,2.5,-3e2,true,false,null,"x"],"b":{}} "#).unwrap();
        let Value::Object(members) = v else { panic!() };
        assert_eq!(members[0].0, "a");
        let Value::Array(items) = &members[0].1 else { panic!() };
        assert_eq!(items.len(), 7);
        assert_eq!(items[1], Value::Number(Number { text: "2.5".into() }));
        assert_eq!(members[1].1, Value::Object(vec![]));
    }

    #[test]
    fn keeps_numbers_as_written() {
        let Value::Number(n) = parse("1.50").unwrap() else { panic!() };
        assert_eq!(n.as_str(), "1.50");
        assert!(!n.is_integer());
        assert_eq!(n.as_f64(), Some(1.5));
        assert_eq!(n.as_u64(), None);
        let Value::Number(n) = parse("42").unwrap() else { panic!() };
        assert_eq!(n.as_u64(), Some(42));
        let Value::Number(n) = parse("-1").unwrap() else { panic!() };
        assert_eq!(n.as_u64(), None);
        let Value::Number(n) = parse("1e999").unwrap() else { panic!() };
        assert_eq!(n.as_f64(), None);
    }

    #[test]
    fn rejects_malformed_documents() {
        for bad in [
            "", "{", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "-", "1e", "tru", "nul",
            "\"abc", "{\"a\" 1}", "{a:1}", "[1 2]", "1 2", "'x'", "\"\\x\"", "\"\\u12\"",
            "\"\\ud800\"", "\"\\udc00\"", "\"a\nb\"", "\u{feff}{}",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} must be rejected");
        }
    }

    #[test]
    fn decodes_escapes_and_surrogate_pairs() {
        let Value::String(s) = parse(r#""a\n\t\"\\\/\u0041\ud83d\ude00é""#).unwrap() else { panic!() };
        assert_eq!(s, "a\n\t\"\\/A\u{1F600}é");
    }

    #[test]
    fn nul_escape_is_representable() {
        let Value::String(s) = parse(r#""a\u0000b""#).unwrap() else { panic!() };
        assert_eq!(s, "a\0b");
    }

    #[test]
    fn preserves_duplicate_keys_in_order() {
        let Value::Object(m) = parse(r#"{"k":1,"k":2}"#).unwrap() else { panic!() };
        assert_eq!(m.len(), 2);
    }

    #[test]
    fn nesting_is_bounded_without_overflowing_a_small_stack() {
        let text = "[".repeat(100_000);
        let handle = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || parse(&text))
            .unwrap();
        let err = handle.join().unwrap().unwrap_err();
        assert!(err.message.contains("too deep"));
        let ok = format!("{}{}", "[".repeat(MAX_DEPTH), "]".repeat(MAX_DEPTH));
        assert!(parse(&ok).is_ok());
        let too_deep = format!("{}{}", "[".repeat(MAX_DEPTH + 1), "]".repeat(MAX_DEPTH + 1));
        assert!(parse(&too_deep).is_err());
    }

    #[test]
    fn writer_is_compact_and_escapes() {
        assert_eq!(string("a\"b\\c\n\u{1}\u{7f}é"), "\"a\\\"b\\\\c\\n\\u0001\\u007fé\"");
        let doc = object(&[("a", array(["1".into(), boolean(true), null()])), ("b", string("x"))]);
        assert_eq!(doc, r#"{"a":[1,true,null],"b":"x"}"#);
        assert_eq!(array(Vec::<String>::new()), "[]");
        assert_eq!(object(&[]), "{}");
    }

    #[test]
    fn writer_output_round_trips_through_the_reader() {
        let nasty = "tab\there \"quote\" \\ \u{0}nul \u{1b}[31m é \u{1F600}";
        let Value::String(back) = parse(&string(nasty)).unwrap() else { panic!() };
        assert_eq!(back, nasty);
    }

    #[test]
    fn f32_tokens_round_trip_and_reject_non_finite() {
        for x in [0.0f32, -0.0, 1.0, 0.1, 1.0e-7, 3.4028235e38, 123456.79, f32::MIN_POSITIVE] {
            let token = f32_token(x).unwrap();
            assert_eq!(token.parse::<f32>().unwrap().to_bits(), x.to_bits(), "{token}");
            assert!(parse(&token).is_ok(), "{token} must be a JSON number");
        }
        assert_eq!(f32_token(0.5).unwrap(), "0.5");
        assert!(f32_token(f32::NAN).is_none());
        assert!(f32_token(f32::INFINITY).is_none());
    }
}
