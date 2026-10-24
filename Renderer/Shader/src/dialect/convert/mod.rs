// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The typed rewrite: walks the tree, decides the type of every expression and inserts the
//! conversions the dialect needs (spec C1, R8 to R88).
//!
//! The pass follows one principle (P3): a conversion is inserted only where both types are
//! known. A construct whose type cannot be decided is left as written for naga to judge.
//! Types of rewritten forms feed the rules above them, so rules compose in any nesting
//! (E6); each source operand appears once in the output (R68).

use std::collections::{HashMap, HashSet};

use crate::diagnostic::{Diagnostic, Pass, Span as DiagSpan};
use crate::request::StageKind;

use super::ast::*;
use super::builtins::is_reserved_identifier;
use super::ty::*;

mod call;
mod coerce;
mod expr;
mod helpers;
mod items;
mod special;
mod stmt;

pub(super) use helpers::Helpers;

/// An expression with its type (after rewriting).
#[derive(Clone, Debug)]
pub(super) struct T {
    pub e: Expr,
    pub ty: Ty,
}

impl T {
    pub fn new(e: Expr, ty: Ty) -> T {
        T { e, ty }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum VarKind {
    Local,
    Param,
    Global,
    /// `uniform`, `attribute`, `varying`, `in`, `out` and block members.
    Interface,
}

#[derive(Clone, Debug)]
pub(super) struct Var {
    pub ty: Ty,
    pub id: u32,
    pub emit: String,
    /// The name as the author wrote it.
    pub source: String,
    pub kind: VarKind,
    /// A `const` whose initializer is a constant expression.
    pub constant: bool,
    /// The value of a constant integer, for array sizes.
    pub int_value: Option<i64>,
}

#[derive(Clone, Debug)]
pub(super) struct StructInfo {
    pub name: String,
    /// Source name, type and emitted name of each field.
    pub fields: Vec<(String, Ty, String)>,
}

#[derive(Clone, Debug)]
pub(super) struct ParamInfo {
    pub ty: Ty,
    pub dir: ParamDir,
}

#[derive(Clone, Debug)]
pub(super) struct FnInfo {
    pub name: String,
    pub params: Vec<ParamInfo>,
    pub ret: Ty,
    pub emit: String,
}

pub(super) struct Converter {
    pub kind: StageKind,
    pub taken: HashSet<String>,
    pub prefix: String,
    pub diags: Vec<Diagnostic>,
    pub structs: Vec<StructInfo>,
    pub struct_by_name: HashMap<String, usize>,
    pub fns: Vec<FnInfo>,
    pub fn_by_name: HashMap<String, Vec<usize>>,
    pub scopes: Vec<HashMap<String, Var>>,
    pub next_id: u32,
    pub cur_ret: Option<Ty>,
    pub helpers: Helpers,
    pub renames: HashMap<String, String>,
    /// Global initializers that run at the start of `main` (R72).
    pub relocated: Vec<Stmt>,
    /// Names of the colour outputs of a fragment stage and the last whole-vec4 source
    /// assigned to the colour output in the current function (R83).
    pub color_outputs: HashSet<String>,
    pub color_source: Option<(String, u32)>,
    /// The stage defines `main`, so initializers can move into it.
    pub has_main: bool,
    /// Stage inputs by variable id, and the ones the shader writes (R75).
    pub inputs: HashMap<u32, String>,
    pub written_inputs: std::collections::BTreeSet<u32>,
    /// Functions with array or sampler parameters, kept as templates (R66, R67).
    pub specials: HashMap<usize, special::Special>,
    /// Specialised functions waiting to be emitted ahead of the function being converted.
    pub pending: Vec<Item>,
}

/// The identifiers of the stage, collected before conversion so generated names never collide.
pub fn collect_identifiers(tokens: &[crate::lexer::Token]) -> HashSet<String> {
    tokens.iter().filter(|t| t.is_name_like()).map(|t| t.text.clone()).collect()
}

/// Converts a parsed stage. On success the converted module; on failure the diagnostics.
pub fn convert(module: Module, kind: StageKind, taken: HashSet<String>) -> Result<Module, Vec<Diagnostic>> {
    let mut prefix = String::from("_wm_");
    let mut n = 0;
    while taken.iter().any(|t| t.starts_with(&prefix)) {
        n += 1;
        prefix = format!("_wm{n}_");
    }
    let mut c = Converter {
        kind,
        taken,
        prefix,
        diags: Vec::new(),
        structs: Vec::new(),
        struct_by_name: HashMap::new(),
        fns: Vec::new(),
        fn_by_name: HashMap::new(),
        scopes: vec![HashMap::new()],
        next_id: 0,
        cur_ret: None,
        helpers: Helpers::default(),
        renames: HashMap::new(),
        relocated: Vec::new(),
        color_outputs: HashSet::new(),
        color_source: None,
        has_main: false,
        inputs: HashMap::new(),
        written_inputs: std::collections::BTreeSet::new(),
        specials: HashMap::new(),
        pending: Vec::new(),
    };
    let out = c.module(module);
    if c.diags.is_empty() { Ok(out) } else { Err(c.diags) }
}

impl Converter {
    pub fn error(&mut self, span: &Span, message: impl Into<String>) {
        let mut d = Diagnostic::new(message).in_stage(self.kind).in_pass(Pass::Codegen);
        if let Some(s) = DiagSpan::new(span.start, span.end) {
            d = d.at(s);
        }
        self.diags.push(d);
    }

    // ----- scopes -----

    pub fn push_scope(&mut self) {
        self.scopes.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.scopes.pop();
    }

    pub fn lookup(&self, name: &str) -> Option<&Var> {
        self.scopes.iter().rev().find_map(|s| s.get(name))
    }

    /// The name a declaration is written under: reserved words get a fresh spelling (R70).
    pub fn emit_name(&mut self, name: &str) -> String {
        if !is_reserved_identifier(name) {
            return name.to_string();
        }
        if let Some(n) = self.renames.get(name) {
            return n.clone();
        }
        let mut candidate = format!("{name}_wm");
        let mut k = 0;
        while self.taken.contains(&candidate) {
            k += 1;
            candidate = format!("{name}_wm{k}");
        }
        self.taken.insert(candidate.clone());
        self.renames.insert(name.to_string(), candidate.clone());
        candidate
    }

    pub fn declare(&mut self, name: &str, ty: Ty, kind: VarKind, constant: bool, int_value: Option<i64>) -> String {
        let emit = self.emit_name(name);
        self.next_id += 1;
        let var = Var { ty, id: self.next_id, emit: emit.clone(), source: name.to_string(), kind, constant, int_value };
        self.scopes.last_mut().expect("a scope is open").insert(name.to_string(), var);
        emit
    }

    // ----- types -----

    /// The type a `TypeRef` names, with the extra array dimensions of a declarator.
    pub fn resolve_type(&mut self, tr: &TypeRef, extra: &[Option<Expr>]) -> Ty {
        let base = match builtin_type(&tr.name) {
            Some(t) => t,
            None => match self.struct_by_name.get(&tr.name) {
                Some(i) => Ty::Struct(*i),
                None => Ty::Unknown,
            },
        };
        self.wrap_dims(base, tr.dims.iter().chain(extra.iter()))
    }

    /// `base` as an array type for each dimension (outermost first); an unknown size is `None`.
    pub fn wrap_dims<'a>(&self, base: Ty, dims: impl Iterator<Item = &'a Option<Expr>>) -> Ty {
        let lens: Vec<Option<u32>> =
            dims.map(|d| d.as_ref().and_then(|e| self.eval_const_int(e)).and_then(|v| u32::try_from(v).ok())).collect();
        let mut ty = base;
        for len in lens.into_iter().rev() {
            ty = Ty::Array(Box::new(ty), len);
        }
        ty
    }

    /// A small evaluator for constant integer expressions (array sizes, `case` labels).
    pub fn eval_const_int(&self, e: &Expr) -> Option<i64> {
        use crate::lexer::Operator as Op;
        match &e.kind {
            ExprKind::Number(t) => parse_int_literal(t),
            ExprKind::Paren(i) => self.eval_const_int(i),
            ExprKind::Ident(n) => self.lookup(n).and_then(|v| v.int_value),
            ExprKind::Unary(Op::Sub, i) => self.eval_const_int(i).and_then(i64::checked_neg),
            ExprKind::Unary(Op::Add, i) => self.eval_const_int(i),
            ExprKind::Binary(op, l, r) => {
                let (a, b) = (self.eval_const_int(l)?, self.eval_const_int(r)?);
                match op {
                    Op::Add => a.checked_add(b),
                    Op::Sub => a.checked_sub(b),
                    Op::Mul => a.checked_mul(b),
                    Op::Div => a.checked_div(b),
                    Op::Mod => a.checked_rem(b),
                    Op::Shl => u32::try_from(b).ok().and_then(|s| a.checked_shl(s)),
                    Op::Shr => u32::try_from(b).ok().and_then(|s| a.checked_shr(s)),
                    Op::BitAnd => Some(a & b),
                    Op::BitOr => Some(a | b),
                    Op::BitXor => Some(a ^ b),
                    _ => None,
                }
            }
            _ => None,
        }
    }
}

/// The value of an integer literal (decimal, octal or hex), without its `u` suffix.
pub(super) fn parse_int_literal(text: &str) -> Option<i64> {
    let t = text.trim_end_matches(['u', 'U']);
    if t.is_empty() || t.contains(['.', 'e', 'E', 'f', 'F']) && !t.starts_with("0x") && !t.starts_with("0X") {
        return None;
    }
    if let Some(hex) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        return i64::from_str_radix(hex, 16).ok();
    }
    t.parse().ok()
}

/// The type of a numeric literal as written.
pub(super) fn literal_type(text: &str) -> Ty {
    let lower = text.to_ascii_lowercase();
    if lower.starts_with("0x") {
        return if lower.ends_with('u') { UINT } else { INT };
    }
    if lower.contains('.') || lower.contains('e') || lower.ends_with('f') {
        return FLOAT;
    }
    if lower.ends_with('u') { UINT } else { INT }
}

/// `3` -> `3.0`, `3u` -> `3.0`, `0` -> `0.0`; `None` when the text is not an integer literal.
pub(super) fn to_float_literal(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    if lower.starts_with("0x") {
        return parse_int_literal(text).map(|v| format!("{v}.0"));
    }
    if lower.contains(['.', 'e', 'f']) {
        return None;
    }
    let digits = text.trim_end_matches(['u', 'U', 'l', 'L']);
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| format!("{digits}.0"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_helpers() {
        assert_eq!(literal_type("3"), INT);
        assert_eq!(literal_type("3u"), UINT);
        assert_eq!(literal_type("3.0"), FLOAT);
        assert_eq!(literal_type(".5"), FLOAT);
        assert_eq!(literal_type("1e-3"), FLOAT);
        assert_eq!(literal_type("0.5f"), FLOAT);
        assert_eq!(literal_type("2U"), UINT);
        assert_eq!(to_float_literal("3").as_deref(), Some("3.0"));
        assert_eq!(to_float_literal("12u").as_deref(), Some("12.0"));
        assert_eq!(to_float_literal("1.5"), None);
        assert_eq!(to_float_literal("1e3"), None);
        assert_eq!(parse_int_literal("24u"), Some(24));
        assert_eq!(parse_int_literal("0x10"), Some(16));
        assert_eq!(parse_int_literal("1.5"), None);
    }
}
