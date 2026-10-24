use super::PropertyValue;
use crate::{BridgeError, BridgeErrorKind};

#[derive(Clone, Debug, PartialEq)]
pub enum Condition {
    Or(Box<Condition>, Box<Condition>),
    And(Box<Condition>, Box<Condition>),
    Not(Box<Condition>),
    Truthy(String),
    Compare(String, CmpOp, Literal),
    In(String, Vec<Literal>),
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

impl Condition {
    pub fn parse(input: &str) -> Result<Self, BridgeError> {
        let mut parser = Parser { input, position: 0 };
        if input.len() > 2048 {
            return Err(parser.error("input exceeds 2048 bytes"));
        }
        let result = parser.or(0)?;
        parser.whitespace();
        if parser.position != input.len() {
            return Err(parser.error("unexpected trailing input"));
        }
        Ok(result)
    }

    pub fn eval(&self, lookup: &impl Fn(&str) -> Option<PropertyValue>) -> bool {
        match self {
            Self::Or(left, right) => left.eval(lookup) || right.eval(lookup),
            Self::And(left, right) => left.eval(lookup) && right.eval(lookup),
            Self::Not(inner) => !inner.eval(lookup),
            Self::Const(value) => *value,
            Self::Truthy(id) => lookup(id).is_none_or(|value| match value {
                PropertyValue::Bool(value) => value,
                PropertyValue::Number(value) => value != 0.0,
                PropertyValue::String(value) => {
                    let value = value.trim();
                    !value.is_empty() && value != "0" && !value.eq_ignore_ascii_case("false")
                }
                PropertyValue::ColorRgb(..) => true,
                PropertyValue::Null => false,
            }),
            Self::Compare(id, op, literal) => {
                lookup(id).is_none_or(|value| compare(&value, *op, literal))
            }
            Self::In(id, literals) => lookup(id).is_none_or(|value| {
                literals
                    .iter()
                    .any(|literal| compare(&value, CmpOp::Eq, literal))
            }),
        }
    }
}

fn numeric_compare(left: f64, op: CmpOp, right: f64) -> bool {
    match op {
        CmpOp::Eq => left == right,
        CmpOp::Ne => left != right,
        CmpOp::Ge => left >= right,
        CmpOp::Le => left <= right,
        CmpOp::Gt => left > right,
        CmpOp::Lt => left < right,
    }
}

fn compare(value: &PropertyValue, op: CmpOp, literal: &Literal) -> bool {
    match (value, literal) {
        (PropertyValue::Number(left), Literal::Number(right)) => numeric_compare(*left, op, *right),
        (PropertyValue::Bool(left), Literal::Number(right)) => {
            numeric_compare(u8::from(*left) as f64, op, *right)
        }
        (PropertyValue::Bool(left), Literal::Bool(right)) => {
            numeric_compare(u8::from(*left) as f64, op, u8::from(*right) as f64)
        }
        _ => {
            let rendered_value;
            let left = match value {
                PropertyValue::String(value) => value.as_str(),
                PropertyValue::Bool(true) => "true",
                PropertyValue::Bool(false) => "false",
                PropertyValue::Null => "",
                _ => {
                    rendered_value = value.to_property_string();
                    &rendered_value
                }
            };
            let rendered;
            let right = match literal {
                Literal::String(value) => value.as_str(),
                Literal::Number(value) => {
                    rendered = value.to_string();
                    &rendered
                }
                Literal::Bool(true) => "true",
                Literal::Bool(false) => "false",
            };
            match op {
                CmpOp::Eq => left == right,
                CmpOp::Ne => left != right,
                _ => numeric_compare(
                    left.trim().parse().unwrap_or(0.0),
                    op,
                    right.trim().parse().unwrap_or(0.0),
                ),
            }
        }
    }
}

struct Parser<'a> {
    input: &'a str,
    position: usize,
}

type ParseResult<T> = Result<T, BridgeError>;

impl<'a> Parser<'a> {
    fn error(&self, reason: &str) -> BridgeError {
        BridgeError::Error {
            kind: BridgeErrorKind::Project,
            message: format!("condition parse error at {}: {reason}", self.position),
        }
    }

    fn whitespace(&mut self) {
        while self
            .input
            .as_bytes()
            .get(self.position)
            .is_some_and(u8::is_ascii_whitespace)
        {
            self.position += 1;
        }
    }

    fn take(&mut self, text: &str) -> bool {
        self.whitespace();
        if self.input[self.position..].starts_with(text) {
            self.position += text.len();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, text: &str) -> ParseResult<()> {
        if self.take(text) {
            Ok(())
        } else {
            Err(self.error("expected expression punctuation"))
        }
    }

    fn or(&mut self, depth: usize) -> ParseResult<Condition> {
        let mut left = self.and(depth)?;
        while self.take("||") {
            left = Condition::Or(Box::new(left), Box::new(self.and(depth)?));
        }
        Ok(left)
    }

    fn and(&mut self, depth: usize) -> ParseResult<Condition> {
        let mut left = self.unary(depth)?;
        while self.take("&&") {
            left = Condition::And(Box::new(left), Box::new(self.unary(depth)?));
        }
        Ok(left)
    }

    fn unary(&mut self, depth: usize) -> ParseResult<Condition> {
        if self.take("!") {
            if depth == 24 {
                return Err(self.error("nesting exceeds 24"));
            }
            return Ok(Condition::Not(Box::new(self.unary(depth + 1)?)));
        }
        if self.take("(") {
            if depth == 24 {
                return Err(self.error("nesting exceeds 24"));
            }
            let result = self.or(depth + 1)?;
            self.expect(")")?;
            return Ok(result);
        }
        self.atom()
    }

    fn atom(&mut self) -> ParseResult<Condition> {
        if self.take("[") {
            let mut literals = Vec::new();
            if !self.take("]") {
                loop {
                    if literals.len() == 256 {
                        return Err(self.error("list exceeds 256 elements"));
                    }
                    literals.push(self.literal()?);
                    if self.take("]") {
                        break;
                    }
                    self.expect(",")?;
                }
            }
            self.expect(".")?;
            if self.identifier()? != "includes" {
                return Err(self.error("expected includes"));
            }
            self.expect("(")?;
            let id = self.reference()?;
            self.expect(")")?;
            return Ok(Condition::In(id, literals));
        }
        let id = self.identifier()?;
        if !self.take(".") {
            return match id {
                "true" => Ok(Condition::Const(true)),
                "false" => Ok(Condition::Const(false)),
                _ => Err(self.error("expected property reference")),
            };
        }
        if self.identifier()? != "value" {
            return Err(self.error("expected value"));
        }
        let op = if self.take("===") || self.take("==") {
            Some(CmpOp::Eq)
        } else if self.take("!==") || self.take("!=") {
            Some(CmpOp::Ne)
        } else if self.take(">=") {
            Some(CmpOp::Ge)
        } else if self.take("<=") {
            Some(CmpOp::Le)
        } else if self.take(">") {
            Some(CmpOp::Gt)
        } else if self.take("<") {
            Some(CmpOp::Lt)
        } else {
            None
        };
        match op {
            Some(op) => Ok(Condition::Compare(id.to_owned(), op, self.literal()?)),
            None => Ok(Condition::Truthy(id.to_owned())),
        }
    }

    fn reference(&mut self) -> ParseResult<String> {
        let id = self.identifier()?;
        self.expect(".")?;
        if self.identifier()? != "value" {
            return Err(self.error("expected value"));
        }
        Ok(id.to_owned())
    }

    fn identifier(&mut self) -> ParseResult<&'a str> {
        self.whitespace();
        let start = self.position;
        let bytes = self.input.as_bytes();
        if !bytes
            .get(start)
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
        {
            return Err(self.error("expected identifier"));
        }
        self.position += 1;
        while bytes
            .get(self.position)
            .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
        {
            self.position += 1;
        }
        Ok(&self.input[start..self.position])
    }

    fn literal(&mut self) -> ParseResult<Literal> {
        self.whitespace();
        let bytes = self.input.as_bytes();
        if let Some(quote @ (b'\'' | b'"')) = bytes.get(self.position).copied() {
            self.position += 1;
            let start = self.position;
            while let Some(byte) = bytes.get(self.position) {
                if *byte == quote {
                    let value = self.input[start..self.position].to_owned();
                    self.position += 1;
                    return Ok(Literal::String(value));
                }
                self.position += 1;
            }
            return Err(self.error("unterminated string"));
        }
        if bytes
            .get(self.position)
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
        {
            return match self.identifier()? {
                "true" => Ok(Literal::Bool(true)),
                "false" => Ok(Literal::Bool(false)),
                _ => Err(self.error("expected literal")),
            };
        }
        let start = self.position;
        let negative = bytes.get(self.position) == Some(&b'-');
        if negative {
            self.position += 1;
        }
        let digits = self.position;
        while bytes.get(self.position).is_some_and(u8::is_ascii_digit) {
            self.position += 1;
        }
        let has_integer = self.position != digits;
        if bytes.get(self.position) == Some(&b'.') && (has_integer || negative) {
            self.position += 1;
            let fraction = self.position;
            while bytes.get(self.position).is_some_and(u8::is_ascii_digit) {
                self.position += 1;
            }
            if fraction == self.position {
                return Err(self.error("expected fractional digits"));
            }
        } else if !has_integer {
            return Err(self.error("expected number"));
        }
        if bytes
            .get(self.position)
            .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'.')
        {
            return Err(self.error("invalid numeric suffix"));
        }
        let value = self.input[start..self.position]
            .parse()
            .map_err(|_| self.error("invalid number"))?;
        Ok(Literal::Number(value))
    }
}
