// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Lexing of preprocessed shader text (R39 to R42).
//!
//! The lexer never expands anything and never fails: every character lands in
//! some token or is skipped as whitespace or a dropped comment. Tokens own
//! their text and carry byte spans `[start, end)` into the lexed text, which is
//! the *preprocessed* text, not the original file (R42).

use std::ops::{Deref, Range};

/// Words that lex as keyword tokens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Keyword {
    Attribute,
    Const,
    Do,
    Else,
    For,
    If,
    In,
    Layout,
    Out,
    Precision,
    Return,
    Struct,
    Switch,
    Uniform,
    Varying,
    Void,
    While,
}

impl Keyword {
    pub fn parse(word: &str) -> Option<Keyword> {
        Some(match word {
            "attribute" => Keyword::Attribute,
            "const" => Keyword::Const,
            "do" => Keyword::Do,
            "else" => Keyword::Else,
            "for" => Keyword::For,
            "if" => Keyword::If,
            "in" => Keyword::In,
            "layout" => Keyword::Layout,
            "out" => Keyword::Out,
            "precision" => Keyword::Precision,
            "return" => Keyword::Return,
            "struct" => Keyword::Struct,
            "switch" => Keyword::Switch,
            "uniform" => Keyword::Uniform,
            "varying" => Keyword::Varying,
            "void" => Keyword::Void,
            "while" => Keyword::While,
            _ => return None,
        })
    }

    pub fn text(self) -> &'static str {
        match self {
            Keyword::Attribute => "attribute",
            Keyword::Const => "const",
            Keyword::Do => "do",
            Keyword::Else => "else",
            Keyword::For => "for",
            Keyword::If => "if",
            Keyword::In => "in",
            Keyword::Layout => "layout",
            Keyword::Out => "out",
            Keyword::Precision => "precision",
            Keyword::Return => "return",
            Keyword::Struct => "struct",
            Keyword::Switch => "switch",
            Keyword::Uniform => "uniform",
            Keyword::Varying => "varying",
            Keyword::Void => "void",
            Keyword::While => "while",
        }
    }
}

/// The canonical spelling of a primitive type word, or `None` when the word is
/// not one. The square spellings `mat2x2`, `mat3x3`, `mat4x4` report the short form.
pub fn primitive_type(word: &str) -> Option<&'static str> {
    Some(match word {
        "bool" => "bool",
        "int" => "int",
        "uint" => "uint",
        "float" => "float",
        "double" => "double",
        "vec2" => "vec2",
        "vec3" => "vec3",
        "vec4" => "vec4",
        "ivec2" => "ivec2",
        "ivec3" => "ivec3",
        "ivec4" => "ivec4",
        "uvec2" => "uvec2",
        "uvec3" => "uvec3",
        "uvec4" => "uvec4",
        "bvec2" => "bvec2",
        "bvec3" => "bvec3",
        "bvec4" => "bvec4",
        "mat2" | "mat2x2" => "mat2",
        "mat3" | "mat3x3" => "mat3",
        "mat4" | "mat4x4" => "mat4",
        "mat2x3" => "mat2x3",
        "mat2x4" => "mat2x4",
        "mat3x2" => "mat3x2",
        "mat3x4" => "mat3x4",
        "mat4x2" => "mat4x2",
        "mat4x3" => "mat4x3",
        "sampler2D" => "sampler2D",
        "sampler2DArray" => "sampler2DArray",
        "samplerCube" => "samplerCube",
        _ => return None,
    })
}

/// Identifier texts that qualify a declaration without being a type.
pub const DECLARATION_MODIFIERS: [&str; 8] =
    ["lowp", "mediump", "highp", "flat", "smooth", "noperspective", "centroid", "sample"];

/// Operators, plus the comma, which the lexer reports as punctuation but the
/// expression summaries treat as the loosest operator (R48).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Operator {
    Inc,
    Dec,
    ShlAssign,
    ShrAssign,
    AddAssign,
    SubAssign,
    MulAssign,
    DivAssign,
    ModAssign,
    AndAssign,
    XorAssign,
    OrAssign,
    Shl,
    Shr,
    Le,
    Ge,
    Eq,
    Ne,
    AndAnd,
    OrOr,
    XorXor,
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Assign,
    Not,
    Lt,
    Gt,
    BitAnd,
    BitOr,
    BitXor,
    BitNot,
    Question,
    Colon,
    Dot,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Comma,
}

/// The domain an operator belongs to (R39).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperatorDomain {
    Arithmetic,
    Logical,
    Relational,
    Equality,
    Bitwise,
    Assignment,
    Increment,
    MemberAccess,
    Conditional,
    Grouping,
    Subscript,
    Comma,
}

/// Binding strength classes of R48, loosest first (the order of the variants).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Precedence {
    Comma,
    Assignment,
    Conditional,
    LogicalOr,
    LogicalXor,
    LogicalAnd,
    BitOr,
    BitXor,
    BitAnd,
    Equality,
    Relational,
    Shift,
    Additive,
    Multiplicative,
    Unary,
    Postfix,
}

impl Operator {
    /// Longest-match table, text to operator. Includes the comma.
    pub fn parse(text: &str) -> Option<Operator> {
        Some(match text {
            "++" => Operator::Inc,
            "--" => Operator::Dec,
            "<<=" => Operator::ShlAssign,
            ">>=" => Operator::ShrAssign,
            "+=" => Operator::AddAssign,
            "-=" => Operator::SubAssign,
            "*=" => Operator::MulAssign,
            "/=" => Operator::DivAssign,
            "%=" => Operator::ModAssign,
            "&=" => Operator::AndAssign,
            "^=" => Operator::XorAssign,
            "|=" => Operator::OrAssign,
            "<<" => Operator::Shl,
            ">>" => Operator::Shr,
            "<=" => Operator::Le,
            ">=" => Operator::Ge,
            "==" => Operator::Eq,
            "!=" => Operator::Ne,
            "&&" => Operator::AndAnd,
            "||" => Operator::OrOr,
            "^^" => Operator::XorXor,
            "+" => Operator::Add,
            "-" => Operator::Sub,
            "*" => Operator::Mul,
            "/" => Operator::Div,
            "%" => Operator::Mod,
            "=" => Operator::Assign,
            "!" => Operator::Not,
            "<" => Operator::Lt,
            ">" => Operator::Gt,
            "&" => Operator::BitAnd,
            "|" => Operator::BitOr,
            "^" => Operator::BitXor,
            "~" => Operator::BitNot,
            "?" => Operator::Question,
            ":" => Operator::Colon,
            "." => Operator::Dot,
            "(" => Operator::LParen,
            ")" => Operator::RParen,
            "[" => Operator::LBracket,
            "]" => Operator::RBracket,
            "," => Operator::Comma,
            _ => return None,
        })
    }

    pub fn text(self) -> &'static str {
        match self {
            Operator::Inc => "++",
            Operator::Dec => "--",
            Operator::ShlAssign => "<<=",
            Operator::ShrAssign => ">>=",
            Operator::AddAssign => "+=",
            Operator::SubAssign => "-=",
            Operator::MulAssign => "*=",
            Operator::DivAssign => "/=",
            Operator::ModAssign => "%=",
            Operator::AndAssign => "&=",
            Operator::XorAssign => "^=",
            Operator::OrAssign => "|=",
            Operator::Shl => "<<",
            Operator::Shr => ">>",
            Operator::Le => "<=",
            Operator::Ge => ">=",
            Operator::Eq => "==",
            Operator::Ne => "!=",
            Operator::AndAnd => "&&",
            Operator::OrOr => "||",
            Operator::XorXor => "^^",
            Operator::Add => "+",
            Operator::Sub => "-",
            Operator::Mul => "*",
            Operator::Div => "/",
            Operator::Mod => "%",
            Operator::Assign => "=",
            Operator::Not => "!",
            Operator::Lt => "<",
            Operator::Gt => ">",
            Operator::BitAnd => "&",
            Operator::BitOr => "|",
            Operator::BitXor => "^",
            Operator::BitNot => "~",
            Operator::Question => "?",
            Operator::Colon => ":",
            Operator::Dot => ".",
            Operator::LParen => "(",
            Operator::RParen => ")",
            Operator::LBracket => "[",
            Operator::RBracket => "]",
            Operator::Comma => ",",
        }
    }

    pub fn domain(self) -> OperatorDomain {
        use Operator::*;
        match self {
            Add | Sub | Mul | Div | Mod => OperatorDomain::Arithmetic,
            AndAnd | OrOr | XorXor | Not => OperatorDomain::Logical,
            Lt | Gt | Le | Ge => OperatorDomain::Relational,
            Eq | Ne => OperatorDomain::Equality,
            BitAnd | BitOr | BitXor | BitNot | Shl | Shr => OperatorDomain::Bitwise,
            Assign | AddAssign | SubAssign | MulAssign | DivAssign | ModAssign | AndAssign | XorAssign
            | OrAssign | ShlAssign | ShrAssign => OperatorDomain::Assignment,
            Inc | Dec => OperatorDomain::Increment,
            Dot => OperatorDomain::MemberAccess,
            Question | Colon => OperatorDomain::Conditional,
            LParen | RParen => OperatorDomain::Grouping,
            LBracket | RBracket => OperatorDomain::Subscript,
            Comma => OperatorDomain::Comma,
        }
    }

    pub fn precedence(self) -> Precedence {
        use Operator::*;
        match self {
            Comma => Precedence::Comma,
            Assign | AddAssign | SubAssign | MulAssign | DivAssign | ModAssign | AndAssign | XorAssign
            | OrAssign | ShlAssign | ShrAssign => Precedence::Assignment,
            Question | Colon => Precedence::Conditional,
            OrOr => Precedence::LogicalOr,
            XorXor => Precedence::LogicalXor,
            AndAnd => Precedence::LogicalAnd,
            BitOr => Precedence::BitOr,
            BitXor => Precedence::BitXor,
            BitAnd => Precedence::BitAnd,
            Eq | Ne => Precedence::Equality,
            Lt | Gt | Le | Ge => Precedence::Relational,
            Shl | Shr => Precedence::Shift,
            Add | Sub => Precedence::Additive,
            Mul | Div | Mod => Precedence::Multiplicative,
            Not | BitNot | Inc | Dec => Precedence::Unary,
            Dot | LParen | RParen | LBracket | RBracket => Precedence::Postfix,
        }
    }

    pub fn is_assignment(self) -> bool {
        self.domain() == OperatorDomain::Assignment
    }

    /// `=` alone, not a compound assignment.
    pub fn is_simple_assignment(self) -> bool {
        self == Operator::Assign
    }

    pub fn is_compound_assignment(self) -> bool {
        self.is_assignment() && self != Operator::Assign
    }

    pub fn is_additive(self) -> bool {
        matches!(self, Operator::Add | Operator::Sub)
    }

    pub fn is_multiplicative(self) -> bool {
        matches!(self, Operator::Mul | Operator::Div | Operator::Mod)
    }

    /// Relational or equality.
    pub fn is_comparison(self) -> bool {
        matches!(self.domain(), OperatorDomain::Relational | OperatorDomain::Equality)
    }

    pub fn is_increment_or_decrement(self) -> bool {
        matches!(self, Operator::Inc | Operator::Dec)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenKind {
    /// A `//` comment that carries WE metadata: `// [TAG]...` or `// {...}`.
    Annotation,
    /// A preprocessor line, with its continuations and trailing comment.
    Directive,
    /// A string literal, quotes included.
    StringLiteral,
    /// A numeric literal as written.
    Number,
    Identifier,
    Keyword(Keyword),
    /// A primitive type; the token text is the canonical spelling.
    Type,
    LBrace,
    RBrace,
    Semicolon,
    Comma,
    Operator(Operator),
    /// Any other single character.
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    /// Owned: a stream outlives the text it was lexed from.
    pub text: String,
    /// Byte offsets into the lexed text, `start <= end`.
    pub start: usize,
    pub end: usize,
}

impl Token {
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }

    /// The text of identifier, keyword, type, literal, string, other, operator,
    /// annotation and directive tokens; `None` for the punctuation tokens
    /// (`{`, `}`, `;`, `,`).
    pub fn source_text(&self) -> Option<&str> {
        match self.kind {
            TokenKind::LBrace | TokenKind::RBrace | TokenKind::Semicolon | TokenKind::Comma => None,
            _ => Some(&self.text),
        }
    }

    pub fn is_keyword(&self, keyword: Keyword) -> bool {
        self.kind == TokenKind::Keyword(keyword)
    }

    pub fn is_operator(&self, op: Operator) -> bool {
        match self.kind {
            TokenKind::Operator(o) => o == op,
            TokenKind::Comma => op == Operator::Comma,
            _ => false,
        }
    }

    /// The operator of an operator token. A comma token answers
    /// [`Operator::Comma`] so that expression code can treat it uniformly.
    pub fn operator(&self) -> Option<Operator> {
        match self.kind {
            TokenKind::Operator(o) => Some(o),
            TokenKind::Comma => Some(Operator::Comma),
            _ => None,
        }
    }

    pub fn is_identifier(&self) -> bool {
        self.kind == TokenKind::Identifier
    }

    pub fn is_type(&self) -> bool {
        self.kind == TokenKind::Type
    }

    pub fn is_annotation(&self) -> bool {
        self.kind == TokenKind::Annotation
    }

    pub fn is_directive(&self) -> bool {
        self.kind == TokenKind::Directive
    }

    pub fn is_number(&self) -> bool {
        self.kind == TokenKind::Number
    }

    /// Plain identifiers, keywords and primitive types.
    pub fn is_name_like(&self) -> bool {
        matches!(self.kind, TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Type)
    }

    pub fn is_assignment(&self) -> bool {
        self.operator().is_some_and(Operator::is_assignment)
    }

    pub fn is_simple_assignment(&self) -> bool {
        self.is_operator(Operator::Assign)
    }

    pub fn is_member_access(&self) -> bool {
        self.is_operator(Operator::Dot)
    }

    pub fn is_additive(&self) -> bool {
        self.operator().is_some_and(Operator::is_additive)
    }

    pub fn is_multiplicative(&self) -> bool {
        self.operator().is_some_and(Operator::is_multiplicative)
    }

    pub fn is_comparison(&self) -> bool {
        self.operator().is_some_and(Operator::is_comparison)
    }

    pub fn is_logical_not(&self) -> bool {
        self.is_operator(Operator::Not)
    }

    pub fn is_increment_or_decrement(&self) -> bool {
        self.operator().is_some_and(Operator::is_increment_or_decrement)
    }

    pub fn is_left_paren(&self) -> bool {
        self.is_operator(Operator::LParen)
    }

    pub fn is_right_paren(&self) -> bool {
        self.is_operator(Operator::RParen)
    }

    pub fn is_left_bracket(&self) -> bool {
        self.is_operator(Operator::LBracket)
    }

    pub fn is_right_bracket(&self) -> bool {
        self.is_operator(Operator::RBracket)
    }

    /// An opening `(`, `[` or `{`.
    pub fn is_opener(&self) -> bool {
        self.is_left_paren() || self.is_left_bracket() || self.kind == TokenKind::LBrace
    }

    pub fn is_closer(&self) -> bool {
        self.is_right_paren() || self.is_right_bracket() || self.kind == TokenKind::RBrace
    }

    /// `lowp mediump highp flat smooth noperspective centroid sample invariant`
    /// as identifiers, or the `const` keyword.
    pub fn is_declaration_modifier(&self) -> bool {
        match self.kind {
            TokenKind::Identifier => {
                DECLARATION_MODIFIERS.contains(&self.text.as_str()) || self.text == "invariant"
            }
            TokenKind::Keyword(Keyword::Const) => true,
            _ => false,
        }
    }
}

/// Tokens in source order. Read-only; behaves like a slice and converts to an
/// owned vector.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TokenStream {
    tokens: Vec<Token>,
}

impl Deref for TokenStream {
    type Target = [Token];
    fn deref(&self) -> &[Token] {
        &self.tokens
    }
}

impl IntoIterator for TokenStream {
    type Item = Token;
    type IntoIter = std::vec::IntoIter<Token>;
    fn into_iter(self) -> Self::IntoIter {
        self.tokens.into_iter()
    }
}

impl<'a> IntoIterator for &'a TokenStream {
    type Item = &'a Token;
    type IntoIter = std::slice::Iter<'a, Token>;
    fn into_iter(self) -> Self::IntoIter {
        self.tokens.iter()
    }
}

impl From<TokenStream> for Vec<Token> {
    fn from(stream: TokenStream) -> Vec<Token> {
        stream.tokens
    }
}

impl From<Vec<Token>> for TokenStream {
    fn from(tokens: Vec<Token>) -> TokenStream {
        TokenStream { tokens }
    }
}

impl TokenStream {
    pub fn into_vec(self) -> Vec<Token> {
        self.tokens
    }

    pub fn as_slice(&self) -> &[Token] {
        &self.tokens
    }

    /// The index after `index`, when there is a token there.
    pub fn next_index(&self, index: usize) -> Option<usize> {
        let next = index.checked_add(1)?;
        (next < self.tokens.len()).then_some(next)
    }

    pub fn previous_index(&self, index: usize) -> Option<usize> {
        index.checked_sub(1).filter(|i| *i < self.tokens.len())
    }

    /// The closing delimiter of the `(`, `{` or `[` at `open`, counting only
    /// delimiters of the same kind; `None` when `open` is not an opener or no
    /// closer balances it.
    pub fn matching_close(&self, open: usize) -> Option<usize> {
        let first = self.tokens.get(open)?;
        let is_open: fn(&Token) -> bool;
        let is_close: fn(&Token) -> bool;
        if first.is_left_paren() {
            is_open = Token::is_left_paren;
            is_close = Token::is_right_paren;
        } else if first.is_left_bracket() {
            is_open = Token::is_left_bracket;
            is_close = Token::is_right_bracket;
        } else if first.kind == TokenKind::LBrace {
            is_open = |t| t.kind == TokenKind::LBrace;
            is_close = |t| t.kind == TokenKind::RBrace;
        } else {
            return None;
        }
        let mut depth = 0usize;
        for (i, token) in self.tokens.iter().enumerate().skip(open) {
            if is_open(token) {
                depth += 1;
            } else if is_close(token) {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
        }
        None
    }

    /// Plain identifiers, keywords and primitive types, as `(index, text, byte range)`.
    pub fn name_tokens(&self) -> impl Iterator<Item = (usize, &str, Range<usize>)> + '_ {
        self.tokens
            .iter()
            .enumerate()
            .filter(|(_, t)| t.is_name_like())
            .map(|(i, t)| (i, t.text.as_str(), t.range()))
    }

    /// The byte span from the first token of `range` to the end of its last.
    pub fn span_of(&self, range: Range<usize>) -> Option<Range<usize>> {
        if range.start >= range.end || range.end > self.tokens.len() {
            return None;
        }
        Some(self.tokens[range.start].start..self.tokens[range.end - 1].end)
    }

    /// The token indices whose tokens lie inside the byte range.
    pub fn token_range_in_bytes(&self, bytes: Range<usize>) -> Range<usize> {
        let first = self.tokens.partition_point(|t| t.start < bytes.start);
        let last = self.tokens.partition_point(|t| t.end <= bytes.end).max(first);
        first..last
    }

    /// The name of the first declarator of the declaration inside `bytes`: the
    /// name-like token after the type, skipping `layout(...)` groups, modifiers
    /// and the qualifiers `attribute uniform varying in out`.
    pub fn first_declarator_name(&self, bytes: Range<usize>) -> Option<usize> {
        let range = self.token_range_in_bytes(bytes);
        let mut i = range.start;
        while i < range.end {
            let t = &self.tokens[i];
            if t.is_keyword(Keyword::Layout) && self.tokens.get(i + 1).is_some_and(Token::is_left_paren) {
                i = self.matching_close(i + 1)? + 1;
            } else if t.is_declaration_modifier()
                || matches!(
                    t.kind,
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
        // `i` is the type; the name is the next name-like token.
        let name = i + 1;
        (name < range.end && self.tokens[name].is_name_like()).then_some(name)
    }
}

/// Lexes `text`. Total: every byte is covered by a token, whitespace or a
/// dropped comment (R39).
pub fn lex(text: &str) -> TokenStream {
    Lexer { text, bytes: text.as_bytes(), pos: 0, tokens: Vec::new(), block_close_missing: false }.run()
}

struct Lexer<'a> {
    text: &'a str,
    bytes: &'a [u8],
    pos: usize,
    tokens: Vec<Token>,
    /// Set once a `/*` found no `*/`: no later one can find a closer either.
    block_close_missing: bool,
}

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

impl Lexer<'_> {
    fn peek(&self, offset: usize) -> Option<u8> {
        self.bytes.get(self.pos + offset).copied()
    }

    fn push(&mut self, kind: TokenKind, start: usize, end: usize) {
        self.tokens.push(Token { kind, text: self.text[start..end].to_string(), start, end });
    }

    fn run(mut self) -> TokenStream {
        while let Some(c) = self.peek(0) {
            match c {
                b' ' | b'\t' | b'\r' | b'\n' | 0x0c => self.pos += 1,
                b'/' if self.peek(1) == Some(b'/') => self.line_comment(),
                b'/' if self.peek(1) == Some(b'*') => self.block_comment(),
                b'#' => self.directive(),
                b'"' => self.string(),
                b'0'..=b'9' => self.number(),
                b'.' if self.peek(1).is_some_and(|d| d.is_ascii_digit()) => self.number(),
                c if is_ident_start(c) => self.word(),
                b'{' => self.single(TokenKind::LBrace),
                b'}' => self.single(TokenKind::RBrace),
                b';' => self.single(TokenKind::Semicolon),
                b',' => self.single(TokenKind::Comma),
                _ => self.operator_or_other(),
            }
        }
        TokenStream { tokens: self.tokens }
    }

    fn single(&mut self, kind: TokenKind) {
        self.push(kind, self.pos, self.pos + 1);
        self.pos += 1;
    }

    /// Where the current line ends: the first `\n` or `\r` at or after `from`.
    fn line_end(&self, from: usize) -> usize {
        self.bytes[from..].iter().position(|b| matches!(b, b'\n' | b'\r')).map_or(self.bytes.len(), |p| from + p)
    }

    fn line_comment(&mut self) {
        let start = self.pos;
        let mut i = start + 2;
        while matches!(self.bytes.get(i), Some(b' ' | b'\t')) {
            i += 1;
        }
        let annotation = match self.bytes.get(i) {
            Some(b'{') => true,
            Some(b'[') => {
                let mut j = i + 1;
                while self.bytes.get(j).is_some_and(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_') {
                    j += 1;
                }
                j > i + 1 && self.bytes.get(j) == Some(&b']')
            }
            _ => false,
        };
        if annotation {
            let end = self.line_end(start);
            self.push(TokenKind::Annotation, start, end);
            self.pos = end;
        } else {
            // A comment runs to the next `\n`; the text is dropped.
            self.pos = self.bytes[start..].iter().position(|b| *b == b'\n').map_or(self.bytes.len(), |p| start + p);
        }
    }

    fn block_comment(&mut self) {
        let start = self.pos;
        let close = if self.block_close_missing { None } else { self.text[start + 2..].find("*/") };
        match close {
            Some(p) => self.pos = start + 2 + p + 2,
            None => {
                self.block_close_missing = true;
                // Not a comment: `/` and `*` lex as operators.
                self.push(TokenKind::Operator(Operator::Div), start, start + 1);
                self.pos = start + 1;
            }
        }
    }

    fn directive(&mut self) {
        let start = self.pos;
        let mut i = start;
        loop {
            match self.bytes[i..].iter().position(|b| *b == b'\n') {
                None => {
                    i = self.bytes.len();
                    break;
                }
                Some(p) => {
                    let nl = i + p;
                    // A backslash right before the line break (or before `\r\n`) continues the directive.
                    let before = if nl > start && self.bytes[nl - 1] == b'\r' { nl - 1 } else { nl };
                    if before > start && self.bytes[before - 1] == b'\\' {
                        i = nl + 1;
                        continue;
                    }
                    i = nl;
                    break;
                }
            }
        }
        let mut end = i;
        if end > start && self.bytes[end - 1] == b'\r' {
            end -= 1;
        }
        self.push(TokenKind::Directive, start, end);
        self.pos = i;
    }

    fn string(&mut self) {
        let start = self.pos;
        let mut i = start + 1;
        loop {
            match self.bytes.get(i) {
                None | Some(b'\n' | b'\r') => {
                    // Unterminated: the quote is an ordinary character.
                    self.push(TokenKind::Other, start, start + 1);
                    self.pos = start + 1;
                    return;
                }
                Some(b'\\') => {
                    i += 1;
                    if matches!(self.bytes.get(i), None | Some(b'\n' | b'\r')) {
                        continue;
                    }
                    i += self.text[i..].chars().next().map_or(1, char::len_utf8);
                }
                Some(b'"') => {
                    self.push(TokenKind::StringLiteral, start, i + 1);
                    self.pos = i + 1;
                    return;
                }
                Some(_) => i += 1,
            }
        }
    }

    fn number(&mut self) {
        let start = self.pos;
        let mut i = start;
        let digits = |mut i: usize, bytes: &[u8]| {
            while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
            i
        };
        i = digits(i, self.bytes);
        if self.bytes.get(i) == Some(&b'.') {
            i = digits(i + 1, self.bytes);
        }
        if matches!(self.bytes.get(i), Some(b'e' | b'E')) {
            let mut j = i + 1;
            if matches!(self.bytes.get(j), Some(b'+' | b'-')) {
                j += 1;
            }
            if self.bytes.get(j).is_some_and(u8::is_ascii_digit) {
                i = digits(j, self.bytes);
            }
        }
        while matches!(self.bytes.get(i), Some(b'u' | b'U' | b'l' | b'L' | b'f' | b'F')) {
            i += 1;
        }
        self.push(TokenKind::Number, start, i);
        self.pos = i;
    }

    fn word(&mut self) {
        let start = self.pos;
        let mut i = start + 1;
        while self.bytes.get(i).is_some_and(|b| is_ident_continue(*b)) {
            i += 1;
        }
        let word = &self.text[start..i];
        if let Some(keyword) = Keyword::parse(word) {
            self.push(TokenKind::Keyword(keyword), start, i);
        } else if let Some(canonical) = primitive_type(word) {
            self.tokens.push(Token { kind: TokenKind::Type, text: canonical.to_string(), start, end: i });
        } else {
            self.push(TokenKind::Identifier, start, i);
        }
        self.pos = i;
    }

    fn operator_or_other(&mut self) {
        let start = self.pos;
        for len in [3usize, 2, 1] {
            let Some(candidate) = self.text.get(start..start + len) else { continue };
            if candidate == "," {
                continue;
            }
            if let Some(op) = Operator::parse(candidate) {
                // Three characters only for the shift assignments.
                if len == 3 && !matches!(op, Operator::ShlAssign | Operator::ShrAssign) {
                    continue;
                }
                self.push(TokenKind::Operator(op), start, start + len);
                self.pos = start + len;
                return;
            }
        }
        let len = self.text[start..].chars().next().map_or(1, char::len_utf8);
        self.push(TokenKind::Other, start, start + len);
        self.pos = start + len;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(TokenKind, String)> {
        lex(text).iter().map(|t| (t.kind, t.text.clone())).collect()
    }

    fn texts(text: &str) -> Vec<String> {
        lex(text).iter().map(|t| t.text.clone()).collect()
    }

    #[test]
    fn every_token_text_is_the_slice_at_its_span_except_canonical_types() {
        let src = "uniform float g_A; // {\"default\":1}\nvec2 v = vec2(1.5e-3f, .5); #define X 1 \\\n  + 2\nmat2x2 m; /* é */ \"s\\\"t\" `";
        let stream = lex(src);
        for t in &stream {
            if t.kind != TokenKind::Type {
                assert_eq!(&src[t.range()], t.text);
            }
            assert!(t.start <= t.end);
        }
        let m = stream.iter().find(|t| t.text == "mat2").unwrap();
        assert_eq!(&src[m.range()], "mat2x2");
    }

    #[test]
    fn operators_use_longest_match() {
        assert_eq!(texts("k<<=2"), ["k", "<<=", "2"]);
        assert_eq!(texts("k<<2"), ["k", "<<", "2"]);
        assert_eq!(texts("lo>=hi"), ["lo", ">=", "hi"]);
        assert_eq!(texts("m>>=1"), ["m", ">>=", "1"]);
        assert_eq!(texts("p^^q"), ["p", "^^", "q"]);
        assert_eq!(texts("i--"), ["i", "--"]);
        assert_eq!(texts("a+++b"), ["a", "++", "+", "b"]);
        assert_eq!(texts("a<<<b"), ["a", "<<", "<", "b"]);
        assert_eq!(texts("a?b:c.d[1](2)"), ["a", "?", "b", ":", "c", ".", "d", "[", "1", "]", "(", "2", ")"]);
        for t in lex("++ -- <<= >>= += -= *= /= %= &= ^= |= << >> <= >= == != && || ^^ + - * / % = ! < > & | ^ ~ ? : . ( ) [ ]").iter() {
            let TokenKind::Operator(op) = t.kind else { panic!("{t:?}") };
            assert_eq!(Operator::parse(&t.text), Some(op));
            assert_eq!(op.text(), t.text);
        }
    }

    #[test]
    fn commas_and_braces_are_punctuation_not_operators() {
        let k = kinds("{ } ; ,");
        assert_eq!(
            k.iter().map(|(k, _)| *k).collect::<Vec<_>>(),
            [TokenKind::LBrace, TokenKind::RBrace, TokenKind::Semicolon, TokenKind::Comma]
        );
        let stream = lex(",");
        assert_eq!(stream[0].operator(), Some(Operator::Comma));
        assert_eq!(stream[0].source_text(), None);
    }

    #[test]
    fn numbers_follow_the_literal_rules() {
        assert_eq!(texts(".5"), [".5"]);
        assert_eq!(texts("1."), ["1."]);
        assert_eq!(texts("1.5"), ["1.5"]);
        assert_eq!(texts("1e-3f"), ["1e-3f"]);
        assert_eq!(texts("2u 3U 4l 5lu 6f"), ["2u", "3U", "4l", "5lu", "6f"]);
        assert_eq!(texts("1.e3"), ["1.e3"]);
        assert_eq!(texts("1e"), ["1", "e"]);
        assert_eq!(texts("1e+"), ["1", "e", "+"]);
        assert_eq!(kinds("0x1F"), [(TokenKind::Number, "0".into()), (TokenKind::Identifier, "x1F".into())]);
        assert_eq!(texts("v.5"), ["v", ".5"]);
    }

    #[test]
    fn words_are_keywords_types_or_identifiers() {
        let s = lex("uniform mat2x2 mat2x3 float2 sampler2DComparison inout true highp discard sampler2D samplerCube");
        let k: Vec<(TokenKind, &str)> = s.iter().map(|t| (t.kind, t.text.as_str())).collect();
        assert_eq!(k[0], (TokenKind::Keyword(Keyword::Uniform), "uniform"));
        assert_eq!(k[1], (TokenKind::Type, "mat2"));
        assert_eq!(k[2], (TokenKind::Type, "mat2x3"));
        for (i, word) in [(3, "float2"), (4, "sampler2DComparison"), (5, "inout"), (6, "true"), (7, "highp"), (8, "discard")] {
            assert_eq!(k[i], (TokenKind::Identifier, word));
        }
        assert_eq!(k[9], (TokenKind::Type, "sampler2D"));
        assert_eq!(k[10], (TokenKind::Type, "samplerCube"));
        for word in ["attribute", "const", "do", "else", "for", "if", "in", "layout", "out", "precision", "return", "struct", "switch", "uniform", "varying", "void", "while"] {
            assert_eq!(Keyword::parse(word).unwrap().text(), word);
            assert!(matches!(lex(word)[0].kind, TokenKind::Keyword(_)));
        }
        for word in ["bool", "int", "uint", "float", "double", "vec4", "ivec3", "uvec2", "bvec4", "mat4", "mat3x3", "mat4x2", "sampler2DArray"] {
            assert_eq!(lex(word)[0].kind, TokenKind::Type, "{word}");
        }
    }

    #[test]
    fn unknown_characters_are_other_tokens() {
        assert_eq!(kinds("`"), [(TokenKind::Other, "`".into())]);
        assert_eq!(texts("a@b$c\\d"), ["a", "@", "b", "$", "c", "\\", "d"]);
        let s = lex("é x");
        assert_eq!(s[0].kind, TokenKind::Other);
        assert_eq!((s[0].start, s[0].end), (0, 2));
    }

    #[test]
    fn strings_have_escapes_and_unterminated_quotes_become_other() {
        assert_eq!(kinds(r#""a\"b" x"#), [(TokenKind::StringLiteral, r#""a\"b""#.into()), (TokenKind::Identifier, "x".into())]);
        assert_eq!(kinds("\"abc\nx\""), [
            (TokenKind::Other, "\"".into()),
            (TokenKind::Identifier, "abc".into()),
            (TokenKind::Identifier, "x".into()),
            (TokenKind::Other, "\"".into()),
        ]);
        assert_eq!(kinds("\"open"), [(TokenKind::Other, "\"".into()), (TokenKind::Identifier, "open".into())]);
    }

    #[test]
    fn comments_are_dropped_and_an_unterminated_block_comment_gives_operators() {
        assert_eq!(texts("a // plain\nb /* x\ny */ c /// z\nd"), ["a", "b", "c", "d"]);
        assert_eq!(texts("a /* never closed"), ["a", "/", "*", "never", "closed"]);
        assert_eq!(texts("a /**/ b"), ["a", "b"]);
    }

    #[test]
    fn annotation_comments_become_tokens() {
        let src = "// [COMBO] {\"combo\":\"A\"}\n//{\"a\":1}\n//\t[PASS] x\n// plain\n/// x\n// [lower] x\n// []\nuniform float g; // {\"default\":2}\r\n";
        let t: Vec<String> = lex(src).iter().filter(|t| t.is_annotation()).map(|t| t.text.clone()).collect();
        assert_eq!(
            t,
            ["// [COMBO] {\"combo\":\"A\"}", "//{\"a\":1}", "//\t[PASS] x", "// {\"default\":2}"]
        );
        assert!(!t.iter().any(|a| a.ends_with('\r')));
        // Inside a block comment there is no annotation.
        assert!(lex("/* // {\"a\":1} */ x").iter().all(|t| !t.is_annotation()));
    }

    #[test]
    fn directives_run_to_the_end_of_the_line_and_swallow_comments() {
        let s = lex("#define A 1 // note\n  #if X\nint x; # tail\n");
        let d: Vec<&str> = s.iter().filter(|t| t.is_directive()).map(|t| t.text.as_str()).collect();
        assert_eq!(d, ["#define A 1 // note", "#if X", "# tail"]);
        let src = "  #if X\n";
        assert_eq!(lex(src)[0].start, 2);
        assert_eq!(texts("#define A 1 // {\"x\":1}"), ["#define A 1 // {\"x\":1}"]);
        assert!(lex("#define A 1 // {\"x\":1}").iter().all(|t| !t.is_annotation()));
    }

    #[test]
    fn directive_continuations_join_lines_for_lf_and_crlf() {
        let s = lex("#define M(a) \\\n  (a + 1) \\\n  + 2\nint x;");
        assert_eq!(s[0].text, "#define M(a) \\\n  (a + 1) \\\n  + 2");
        assert_eq!(s[1].text, "int");
        let s = lex("#define M \\\r\n  1\r\nint x;\r\n");
        assert_eq!(s[0].text, "#define M \\\r\n  1");
        assert_eq!(s[1].text, "int");
        // A directive that is the last line has no terminator and no trailing CR.
        assert_eq!(lex("#x\r")[0].text, "#x");
    }

    #[test]
    fn multibyte_characters_before_a_token_do_not_break_offsets() {
        let src = "// é€ comment\n/* ü */ float é2 = x;";
        let stream = lex(src);
        for t in &stream {
            assert!(src.is_char_boundary(t.start) && src.is_char_boundary(t.end), "{t:?}");
            if t.kind != TokenKind::Type {
                assert_eq!(&src[t.range()], t.text);
            }
        }
        assert_eq!(stream[0].text, "float");
    }

    #[test]
    fn stream_queries_find_matching_delimiters() {
        let s = lex("f(a[1], (b)) { x; } ( [");
        assert_eq!(s.matching_close(1), Some(10));
        assert_eq!(s.matching_close(3), Some(5));
        assert_eq!(s.matching_close(7), Some(9));
        let open_brace = s.iter().position(|t| t.kind == TokenKind::LBrace).unwrap();
        assert_eq!(s.matching_close(open_brace), Some(open_brace + 3));
        let unbalanced_paren = s.len() - 2;
        assert_eq!(s.matching_close(unbalanced_paren), None);
        assert_eq!(s.matching_close(s.len() - 1), None);
        assert_eq!(s.matching_close(0), None);
        assert_eq!(s.next_index(0), Some(1));
        assert_eq!(s.next_index(s.len() - 1), None);
        assert_eq!(s.previous_index(0), None);
        assert_eq!(s.previous_index(3), Some(2));
    }

    #[test]
    fn name_like_tokens_include_keywords_and_types() {
        let s = lex("float blend /* x */ (vec2 uv) { return uv.x; }");
        let names: Vec<&str> = s.name_tokens().map(|(_, t, _)| t).collect();
        assert_eq!(names, ["float", "blend", "vec2", "uv", "return", "uv", "x"]);
        let (i, text, range) = s.name_tokens().nth(1).unwrap();
        assert_eq!((i, text, range), (1, "blend", 6..11));
    }

    #[test]
    fn spans_and_byte_ranges_map_to_token_ranges() {
        let src = "uniform float g_A; vec3 v;";
        let s = lex(src);
        assert_eq!(s.span_of(0..3), Some(0..17));
        assert_eq!(s.span_of(3..3), None);
        assert_eq!(s.span_of(0..99), None);
        assert_eq!(s.token_range_in_bytes(19..26), 4..7);
        assert_eq!(s.token_range_in_bytes(0..src.len()), 0..s.len());
        assert!(s.token_range_in_bytes(1..3).is_empty());
        assert_eq!(s.token_range_in_bytes(100..200).len(), 0);
    }

    #[test]
    fn the_first_declarator_name_skips_qualifiers_modifiers_and_layout() {
        let src = "layout(binding = 4) uniform highp const sampler2D g_Mask, other;";
        let s = lex(src);
        let at = s.first_declarator_name(0..src.len()).unwrap();
        assert_eq!(s[at].text, "g_Mask");
        let src = "vec4 w[3], b;";
        let s = lex(src);
        assert_eq!(s[s.first_declarator_name(0..src.len()).unwrap()].text, "w");
        assert_eq!(lex("float;").first_declarator_name(0..6), None);
    }

    #[test]
    fn token_predicates_classify() {
        let s = lex("= += + * < == ! ++ . ( ) [ ] highp const invariant foo");
        let t = |i: usize| &s[i];
        assert!(t(0).is_assignment() && t(0).is_simple_assignment());
        assert!(t(1).is_assignment() && !t(1).is_simple_assignment());
        assert!(t(2).is_additive() && t(3).is_multiplicative());
        assert!(t(4).is_comparison() && t(5).is_comparison());
        assert!(t(6).is_logical_not() && t(7).is_increment_or_decrement());
        assert!(t(8).is_member_access() && t(9).is_left_paren() && t(10).is_right_paren());
        assert!(t(11).is_left_bracket() && t(12).is_right_bracket());
        assert!(t(13).is_declaration_modifier() && t(14).is_declaration_modifier() && t(15).is_declaration_modifier());
        assert!(!t(16).is_declaration_modifier());
        assert_eq!(t(2).operator().unwrap().domain(), OperatorDomain::Arithmetic);
        assert!(Operator::Mul.precedence() > Operator::Add.precedence());
        assert!(Operator::Comma.precedence() < Operator::Assign.precedence());
    }

    #[test]
    fn a_stream_outlives_its_source_and_converts_to_vec() {
        let stream = {
            let source = String::from("float x;");
            lex(&source)
        };
        assert_eq!(stream.len(), 3);
        let by_ref: Vec<&str> = (&stream).into_iter().map(|t| t.text.as_str()).collect();
        assert_eq!(by_ref, ["float", "x", ";"]);
        let owned: Vec<Token> = stream.clone().into();
        assert_eq!(owned.len(), 3);
        let by_value: Vec<String> = stream.into_iter().map(|t| t.text).collect();
        assert_eq!(by_value, ["float", "x", ";"]);
    }

    #[test]
    fn empty_and_blank_input_give_no_tokens() {
        assert!(lex("").is_empty());
        assert!(lex(" \t\r\n\x0c").is_empty());
    }
}
