// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Implicit conversions (spec 3.8, R23 to R45): the one place that decides how a value of
//! one type becomes a value of another.

use crate::lexer::Operator;

use super::super::ast::*;
use super::super::ty::*;
use super::{Converter, T, parse_int_literal, to_float_literal};

/// `.x`, `.xy`, `.xyz`, `.xyzw`.
pub(super) fn leading_swizzle(n: u8) -> &'static str {
    match n {
        1 => "x",
        2 => "xy",
        3 => "xyz",
        _ => "xyzw",
    }
}

impl Converter {
    pub(super) fn ctor_expr(&self, ty: &Ty, args: Vec<Expr>, span: &Span) -> Expr {
        let name = ty.glsl_name().expect("constructible type");
        Expr::ctor(&name, args, span.clone())
    }

    /// The first `n` components of `e`.
    pub(super) fn truncate(&self, e: Expr, n: u8) -> Expr {
        let span = e.span.clone();
        Expr::new(ExprKind::Member(Box::new(e), leading_swizzle(n).to_string()), span)
    }

    /// Converts a scalar between kinds (R37, R38, R41 to R45).
    pub(super) fn scalar_convert(&self, e: Expr, from: Sc, to: Sc) -> Expr {
        if from == to {
            return e;
        }
        let span = e.span.clone();
        match &e.kind {
            ExprKind::Number(text) => match (from, to) {
                (Sc::Int | Sc::Uint, Sc::Float) => {
                    if let Some(f) = to_float_literal(text) {
                        return Expr::number(&f, span);
                    }
                }
                (Sc::Int, Sc::Uint) => {
                    if text.bytes().all(|b| b.is_ascii_digit()) {
                        return Expr::number(&format!("{text}u"), span);
                    }
                }
                (Sc::Uint, Sc::Int) => {
                    let t = text.trim_end_matches(['u', 'U']);
                    if !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit()) {
                        return Expr::number(t, span);
                    }
                }
                _ => {}
            },
            ExprKind::Bool(b) if to != Sc::Bool => {
                let text = if *b { to.one() } else { to.zero() };
                return Expr::number(text, span);
            }
            _ => {}
        }
        match (from, to) {
            (_, Sc::Bool) => {
                // A number is true exactly when it is not zero (R43).
                let zero = Expr::number(from.zero(), span.clone());
                Expr::binary(Operator::Ne, e, zero).paren()
            }
            _ => Expr::ctor(to.name(), vec![e], span),
        }
    }

    /// Converts a value to the type `to` the way an assignment would (R23 to R30, R37, R38,
    /// R42, R43). Types that cannot be decided, and conversions HLSL forbids (widening a
    /// vector), leave the value as it is.
    pub(super) fn coerce(&mut self, t: T, to: &Ty) -> Expr {
        let T { e, ty } = t;
        if ty.is_unknown() {
            // A value whose type was not worked out (`ldexp`, unresolved macro calls, ...) stored
            // into a scalar takes the scalar's constructor, which HLSL's implicit conversion is.
            return match to {
                Ty::Scalar(k @ (Sc::Int | Sc::Uint | Sc::Float)) => {
                    let span = e.span.clone();
                    Expr::ctor(k.name(), vec![e], span)
                }
                _ => e,
            };
        }
        if ty == *to || to.is_unknown() || matches!(to, Ty::Void) {
            return e;
        }
        let span = e.span.clone();
        match (&ty, to) {
            (Ty::Scalar(a), Ty::Scalar(b)) => self.scalar_convert(e, *a, *b),
            (Ty::Scalar(a), Ty::Vec(b, _)) => {
                let inner = self.scalar_convert(e, *a, *b);
                self.ctor_expr(to, vec![inner], &span)
            }
            (Ty::Vec(a, _), Ty::Scalar(b)) => {
                let first = self.truncate(e, 1);
                self.scalar_convert(first, *a, *b)
            }
            (Ty::Vec(a, m), Ty::Vec(b, n)) => {
                if m < n {
                    return e;
                }
                let e = if m > n { self.truncate(e, *n) } else { e };
                if a != b { self.ctor_expr(to, vec![e], &span) } else { e }
            }
            (Ty::Mat(c1, r1), Ty::Mat(c2, r2)) if c1 >= c2 && r1 >= r2 => self.ctor_expr(to, vec![e], &span),
            _ => e,
        }
    }

    /// A value used as a condition: a number is true when it is not zero (R52, R53).
    pub(super) fn cond_of(&mut self, t: T) -> Expr {
        match &t.ty {
            Ty::Scalar(k) if k.is_numeric() => {
                let zero = Expr::number(k.zero(), t.e.span.clone());
                Expr::binary(Operator::Ne, t.e, zero)
            }
            // An operand whose type was not worked out is tested as HLSL tests a number:
            // `bool(x)` is the identity on a bool and "not zero" on a number.
            Ty::Unknown => {
                let span = t.e.span.clone();
                Expr::ctor("bool", vec![t.e], span)
            }
            _ => t.e,
        }
    }

    /// A value used as an operand of `&&`, `||` or `^^`, or of `!` (R54, R55).
    pub(super) fn bool_operand(&mut self, t: T) -> Expr {
        match &t.ty {
            Ty::Scalar(k) if k.is_numeric() => {
                let zero = Expr::number(k.zero(), t.e.span.clone());
                Expr::binary(Operator::Ne, t.e, zero).paren()
            }
            Ty::Unknown => {
                let span = t.e.span.clone();
                Expr::ctor("bool", vec![t.e], span)
            }
            _ => t.e,
        }
    }

    /// A value used as an array subscript (R39).
    pub(super) fn index_of(&mut self, t: T) -> Expr {
        match &t.ty {
            Ty::Scalar(Sc::Float | Sc::Bool) => {
                let k = t.ty.kind().unwrap();
                self.scalar_convert(t.e, k, Sc::Int)
            }
            _ => t.e,
        }
    }

    /// Converts a scalar or vector value to another scalar kind, keeping its shape.
    pub(super) fn convert_kind(&mut self, t: T, to: Sc) -> T {
        match &t.ty {
            Ty::Scalar(k) if *k != to => {
                let k = *k;
                let e = self.scalar_convert(t.e, k, to);
                T::new(e, Ty::Scalar(to))
            }
            Ty::Vec(k, n) if *k != to => {
                let new_ty = Ty::Vec(to, *n);
                let span = t.e.span.clone();
                let e = self.ctor_expr(&new_ty, vec![t.e], &span);
                T::new(e, new_ty)
            }
            _ => t,
        }
    }

    /// A value of `ty` widened to width `n` by replicating a scalar (R28b).
    pub(super) fn broadcast(&mut self, t: T, n: u8) -> T {
        match &t.ty {
            Ty::Scalar(k) => {
                let ty = Ty::Vec(*k, n);
                let span = t.e.span.clone();
                let e = self.ctor_expr(&ty, vec![t.e], &span);
                T::new(e, ty)
            }
            _ => t,
        }
    }

    /// Narrows a vector to its leading `n` components (R27).
    pub(super) fn narrow_to(&mut self, t: T, n: u8) -> T {
        match &t.ty {
            Ty::Vec(k, m) if *m > n => {
                let ty = Ty::of(*k, n);
                let e = self.truncate(t.e, n);
                T::new(e, ty)
            }
            _ => t,
        }
    }

    /// True when the expression is a numeric literal of integral value written as a float
    /// (`4.0`), and its integer spelling.
    pub(super) fn integral_float_literal(e: &Expr) -> Option<String> {
        let ExprKind::Number(t) = &e.peel().kind else { return None };
        if !t.contains('.') || t.contains(['e', 'E']) {
            return None;
        }
        let t = t.trim_end_matches(['f', 'F']);
        let (int, frac) = t.split_once('.')?;
        if !frac.bytes().all(|b| b == b'0') || int.is_empty() || !int.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        parse_int_literal(int)?;
        Some(int.to_string())
    }
}
