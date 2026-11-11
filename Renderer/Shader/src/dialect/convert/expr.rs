// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Expressions: typing of every form and the operator rules of spec 4.C and 4.D.

use crate::lexer::Operator;

use super::super::ast::*;
use super::super::builtins::builtin_variable;
use super::super::ty::*;
use super::{Converter, T, literal_type};

/// The type of `base.field` for a swizzle on a vector (R7): letters of one set, in range.
pub(super) fn swizzle_type(kind: Sc, width: u8, field: &str) -> Option<Ty> {
    let sets: [&str; 3] = ["xyzw", "rgba", "stpq"];
    let set = sets.iter().find(|s| field.chars().next().is_some_and(|c| s.contains(c)))?;
    if field.is_empty() || field.len() > 4 {
        return None;
    }
    for c in field.chars() {
        let idx = set.find(c)?;
        if idx >= width as usize {
            return None;
        }
    }
    Some(Ty::of(kind, field.len() as u8))
}

/// The scalar kind of the common type of two numeric kinds (int with uint is uint).
pub(super) fn promote(a: Sc, b: Sc) -> Sc {
    if a == Sc::Float || b == Sc::Float {
        Sc::Float
    } else if a == Sc::Uint || b == Sc::Uint {
        Sc::Uint
    } else if a == Sc::Int || b == Sc::Int {
        Sc::Int
    } else {
        Sc::Bool
    }
}

fn is_vec2_ctor(e: &Expr) -> bool {
    match &e.peel().kind {
        ExprKind::Call(Callee::Type(t), _) => t.name == "vec2" && t.dims.is_empty(),
        ExprKind::Call(Callee::Name(n), _) => n == "CAST2",
        _ => false,
    }
}

/// The type of a matrix, vector or scalar product (R82, R103).
pub(super) fn product_type(a: &Ty, b: &Ty) -> Ty {
    match (a, b) {
        (Ty::Mat(c1, r1), Ty::Mat(c2, r2)) => {
            if c1 == r2 {
                Ty::Mat(*c2, *r1)
            } else {
                Ty::Unknown
            }
        }
        (Ty::Mat(c, r), Ty::Vec(Sc::Float, n)) => {
            if c == n { Ty::vec(*r) } else { Ty::Unknown }
        }
        (Ty::Vec(Sc::Float, n), Ty::Mat(c, r)) => {
            if r == n { Ty::vec(*c) } else { Ty::Unknown }
        }
        (Ty::Mat(c, r), Ty::Scalar(_)) | (Ty::Scalar(_), Ty::Mat(c, r)) => Ty::Mat(*c, *r),
        _ => Ty::Unknown,
    }
}

impl Converter {
    pub(super) fn expr(&mut self, e: Expr) -> T {
        self.expr_target(e, None)
    }

    /// Converts an expression. `target` is the type the value flows into, used only by the
    /// one rule that depends on it (R31).
    pub(super) fn expr_target(&mut self, e: Expr, target: Option<&Ty>) -> T {
        let span = e.span.clone();
        match e.kind {
            ExprKind::Number(ref t) => {
                let ty = literal_type(t);
                T::new(e, ty)
            }
            ExprKind::Bool(_) => T::new(e, BOOL),
            ExprKind::Opaque(_) => T::new(e, Ty::Unknown),
            ExprKind::Ident(name) => self.ident(name, span),
            ExprKind::Paren(inner) => {
                let t = self.expr_target(*inner, target);
                T::new(Expr::new(ExprKind::Paren(Box::new(t.e)), span), t.ty)
            }
            ExprKind::Unary(op, inner) => self.unary(op, *inner, span),
            ExprKind::Postfix(op, inner) => {
                if let Some(root) = super::special::root_ident(&inner).map(str::to_string) {
                    self.note_write(&root);
                }
                let t = self.expr(*inner);
                T::new(Expr::new(ExprKind::Postfix(op, Box::new(t.e)), span), t.ty)
            }
            ExprKind::Binary(op, l, r) => self.binary(op, *l, *r, span, target),
            ExprKind::Assign(op, l, r) => self.assign(op, *l, *r, span),
            ExprKind::Cond(c, a, b) => self.conditional(*c, *a, *b, span),
            ExprKind::Comma(list) => {
                let mut out = Vec::with_capacity(list.len());
                let mut ty = Ty::Unknown;
                for x in list {
                    let t = self.expr(x);
                    ty = t.ty;
                    out.push(t.e);
                }
                T::new(Expr::new(ExprKind::Comma(out), span), ty)
            }
            ExprKind::Call(callee, args) => self.call(callee, args, span),
            ExprKind::Index(base, idx) => self.index(*base, *idx, span),
            ExprKind::Member(base, field) => self.member(*base, field, span),
            ExprKind::Method(base, name, args) => {
                let b = self.expr(*base);
                let args: Vec<Expr> = args.into_iter().map(|a| self.expr(a).e).collect();
                let ty = if name == "length" { INT } else { Ty::Unknown };
                T::new(Expr::new(ExprKind::Method(Box::new(b.e), name, args), span), ty)
            }
            ExprKind::InitList(list) => {
                let list: Vec<Expr> = list.into_iter().map(|a| self.expr(a).e).collect();
                T::new(Expr::new(ExprKind::InitList(list), span), Ty::Unknown)
            }
        }
    }

    fn ident(&mut self, name: String, span: Span) -> T {
        if let Some(v) = self.lookup(&name) {
            return T::new(Expr::new(ExprKind::Ident(v.emit.clone()), span), v.ty.clone());
        }
        // The backend's index builtins stand in for WE's names; WE reads them as `uint` (R88).
        let (emit, ty) = match name.as_str() {
            "gl_VertexID" => ("gl_VertexIndex".to_string(), UINT),
            "gl_InstanceID" => ("gl_InstanceIndex".to_string(), UINT),
            n => (n.to_string(), builtin_variable(n).unwrap_or(Ty::Unknown)),
        };
        T::new(Expr::new(ExprKind::Ident(emit), span), ty)
    }

    fn unary(&mut self, op: Operator, inner: Expr, span: Span) -> T {
        if op.is_increment_or_decrement()
            && let Some(root) = super::special::root_ident(&inner).map(str::to_string) {
                self.note_write(&root);
            }
        let t = self.expr(inner);
        if op == Operator::Not {
            return match &t.ty {
                Ty::Scalar(k) if k.is_numeric() => {
                    // `!x` on a number means `x == 0` (R54).
                    let zero = Expr::number(k.zero(), span.clone());
                    T::new(Expr::binary(Operator::Eq, t.e, zero).paren(), BOOL)
                }
                // An operand whose type was not worked out: `!bool(x)`, HLSL's "is zero".
                Ty::Unknown => {
                    let operand = Expr::ctor("bool", vec![t.e], span.clone());
                    T::new(Expr::new(ExprKind::Unary(op, Box::new(operand)), span), BOOL)
                }
                _ => T::new(Expr::new(ExprKind::Unary(op, Box::new(t.e)), span), BOOL),
            };
        }
        T::new(Expr::new(ExprKind::Unary(op, Box::new(t.e)), span), t.ty)
    }

    fn binary(&mut self, op: Operator, l: Expr, r: Expr, span: Span, target: Option<&Ty>) -> T {
        let pad = matches!(op, Operator::Add | Operator::Sub) && matches!(target, Some(Ty::Vec(Sc::Float, 3)));
        let l_vec2 = pad && is_vec2_ctor(&l);
        let r_vec2 = pad && is_vec2_ctor(&r);
        let mut lt = self.expr(l);
        let mut rt = self.expr(r);
        if pad {
            // The one widening kept from the old compiler (R31): `vec3 + vec2(...)` pads the
            // 2-vector constructor with a zero third component.
            if r_vec2 && lt.ty == Ty::vec(3) && rt.ty == Ty::vec(2) {
                rt = self.pad_to_vec3(rt);
            } else if l_vec2 && rt.ty == Ty::vec(3) && lt.ty == Ty::vec(2) {
                lt = self.pad_to_vec3(lt);
            }
        }
        self.binary_typed(op, lt, rt, span)
    }

    fn pad_to_vec3(&mut self, t: T) -> T {
        let span = t.e.span.clone();
        let zero = Expr::number("0.0", span.clone());
        T::new(Expr::ctor("vec3", vec![t.e, zero], span), Ty::vec(3))
    }

    pub(super) fn binary_typed(&mut self, op: Operator, lt: T, rt: T, span: Span) -> T {
        match op {
            Operator::Add | Operator::Sub | Operator::Mul | Operator::Div | Operator::Mod => {
                self.arith(op, lt, rt, span)
            }
            Operator::AndAnd | Operator::OrOr | Operator::XorXor => {
                let l = self.bool_operand(lt);
                let r = self.bool_operand(rt);
                T::new(Expr::new(ExprKind::Binary(op, Box::new(l), Box::new(r)), span), BOOL)
            }
            Operator::Lt | Operator::Gt | Operator::Le | Operator::Ge | Operator::Eq | Operator::Ne => {
                self.compare(op, lt, rt, span)
            }
            _ => {
                // Bitwise operators and shifts: the types are left as written.
                let ty = if lt.ty.kind().is_some_and(Sc::is_integer) { lt.ty.clone() } else { Ty::Unknown };
                T::new(Expr::new(ExprKind::Binary(op, Box::new(lt.e), Box::new(rt.e)), span), ty)
            }
        }
    }

    fn plain(&self, op: Operator, l: Expr, r: Expr, span: Span, ty: Ty) -> T {
        T::new(Expr::new(ExprKind::Binary(op, Box::new(l), Box::new(r)), span), ty)
    }

    fn arith(&mut self, op: Operator, mut lt: T, mut rt: T, span: Span) -> T {
        let blocked = |t: &Ty| t.is_unknown() || t.is_aggregate_blocker() || matches!(t, Ty::Void);
        if blocked(&lt.ty) || blocked(&rt.ty) {
            return self.plain(op, lt.e, rt.e, span, Ty::Unknown);
        }
        // A boolean operand counts as 1 or 0, typed like the other operand (R41).
        if lt.ty.is_bool_scalar() || rt.ty.is_bool_scalar() {
            let other = |t: &Ty| t.kind().filter(|k| k.is_numeric());
            let lk = if lt.ty.is_bool_scalar() { other(&rt.ty).unwrap_or(Sc::Float) } else { Sc::Bool };
            if lt.ty.is_bool_scalar() {
                lt = self.convert_kind(lt, lk);
            }
            if rt.ty.is_bool_scalar() {
                let rk = other(&lt.ty).unwrap_or(Sc::Float);
                rt = self.convert_kind(rt, rk);
            }
        }
        // Matrices: linear algebra types, no conversion (R82).
        if lt.ty.is_matrix() || rt.ty.is_matrix() {
            if !self.options.glsl_builtins && op == Operator::Mul
                && ((lt.ty.is_matrix() && rt.ty.vec_width().is_some())
                    || (rt.ty.is_matrix() && lt.ty.vec_width().is_some())) {
                self.error(&span, "Wallpaper Engine requires `mul` for matrix/vector multiplication".to_string());
            }
            let ty = if op == Operator::Mul {
                product_type(&lt.ty, &rt.ty)
            } else if lt.ty == rt.ty || (lt.ty.is_matrix() && rt.ty.is_scalar()) {
                lt.ty.clone()
            } else if rt.ty.is_matrix() && lt.ty.is_scalar() {
                rt.ty.clone()
            } else {
                Ty::Unknown
            };
            return self.plain(op, lt.e, rt.e, span, ty);
        }
        let (Some(lk), Some(rk)) = (lt.ty.kind(), rt.ty.kind()) else {
            return self.plain(op, lt.e, rt.e, span, Ty::Unknown);
        };
        // Vectors of different widths: both are cut to the narrower one (R27).
        if let (Some(m), Some(n)) = (lt.ty.vec_width(), rt.ty.vec_width()) {
            if m > n {
                lt = self.narrow_to(lt, n);
            } else if n > m {
                rt = self.narrow_to(rt, m);
            }
        }
        if op == Operator::Mod && (lk == Sc::Float || rk == Sc::Float) {
            return self.float_remainder(lt, rt, span);
        }
        // An integer vector beside a float operand becomes a float vector (R36).
        let kind = promote(lk, rk);
        if kind == Sc::Float {
            if lt.ty.vec_width().is_some() && lk != Sc::Float {
                lt = self.convert_kind(lt, Sc::Float);
            }
            if rt.ty.vec_width().is_some() && rk != Sc::Float {
                rt = self.convert_kind(rt, Sc::Float);
            }
        }
        let width = match (lt.ty.vec_width(), rt.ty.vec_width()) {
            (Some(n), _) | (_, Some(n)) => n,
            _ => 1,
        };
        self.plain(op, lt.e, rt.e, span, Ty::of(kind, width))
    }

    /// `%` on floats: the remainder with the sign of the dividend, per component, with both
    /// operands floats of one shape (R47). The backend's own `%` on floats is that remainder.
    fn float_remainder(&mut self, lt: T, rt: T, span: Span) -> T {
        let mut lt = self.convert_kind(lt, Sc::Float);
        let mut rt = self.convert_kind(rt, Sc::Float);
        match (lt.ty.vec_width(), rt.ty.vec_width()) {
            (Some(n), None) => rt = self.broadcast(rt, n),
            (None, Some(n)) => lt = self.broadcast(lt, n),
            _ => {}
        }
        let ty = lt.ty.clone();
        self.plain(Operator::Mod, lt.e, rt.e, span, ty)
    }

    fn compare(&mut self, op: Operator, mut lt: T, mut rt: T, span: Span) -> T {
        if let (Ty::Scalar(a), Ty::Scalar(b)) = (lt.ty.clone(), rt.ty.clone())
            && a != b {
                if a == Sc::Bool {
                    lt = self.convert_kind(lt, b);
                } else if b == Sc::Bool {
                    rt = self.convert_kind(rt, a);
                } else if a == Sc::Float || b == Sc::Float {
                    // HLSL compares as floats. An integral float literal beside an integer
                    // keeps the comparison in integers (loop bounds such as `i < 4.0`).
                    let (int_side_is_left, int_kind) = if a == Sc::Float { (false, b) } else { (true, a) };
                    let (int_side, float_side) = if int_side_is_left { (&mut lt, &mut rt) } else { (&mut rt, &mut lt) };
                    if let Some(digits) = Self::integral_float_literal(&float_side.e) {
                        let text = if int_kind == Sc::Uint { format!("{digits}u") } else { digits };
                        let sp = float_side.e.span.clone();
                        *float_side = T::new(Expr::number(&text, sp), Ty::Scalar(int_kind));
                    } else {
                        let taken = std::mem::replace(int_side, T::new(Expr::number("0", 0..0), INT));
                        *int_side = self.convert_kind(taken, Sc::Float);
                    }
                }
            }
        self.plain(op, lt.e, rt.e, span, BOOL)
    }

    fn assign(&mut self, op: Operator, l: Expr, r: Expr, span: Span) -> T {
        if let Some(root) = super::special::root_ident(&l).map(str::to_string) {
            self.note_write(&root);
        }
        let lt = self.expr(l);
        let ty = lt.ty.clone();
        let rhs = match op {
            Operator::Assign => {
                let rt = self.expr_target(r, Some(&ty));
                self.coerce(rt, &ty)
            }
            Operator::AddAssign | Operator::SubAssign | Operator::MulAssign | Operator::DivAssign => {
                let rt = self.expr(r);
                self.compound_rhs(&ty, rt)
            }
            Operator::ModAssign => {
                let rt = self.expr(r);
                self.remainder_rhs(&ty, rt)
            }
            _ => self.expr(r).e,
        };
        T::new(Expr::new(ExprKind::Assign(op, Box::new(lt.e), Box::new(rhs)), span), ty)
    }

    /// The right side of `+= -= *= /=` (R30, R42): a bool becomes a number, a wider vector
    /// is cut to the target, a vector flowing into a scalar takes its first component, and
    /// an integer target takes an integer value. A scalar into a vector is legal as written.
    fn compound_rhs(&mut self, lhs: &Ty, rt: T) -> Expr {
        let (Some(lk), Some(rk)) = (lhs.kind(), rt.ty.kind()) else { return rt.e };
        let mut rt = rt;
        if rt.ty.is_bool_scalar() && lk.is_numeric() {
            rt = self.convert_kind(rt, lk);
        }
        match (lhs.width(), rt.ty.width()) {
            (Some(n), Some(m)) if m > n => rt = self.narrow_to(rt, n),
            _ => {}
        }
        let rk = rt.ty.kind().unwrap_or(rk);
        if lk.is_integer() && rk.is_numeric() && rk != lk {
            rt = self.convert_kind(rt, lk);
        } else if lk == Sc::Float && lhs.vec_width().is_some() && rt.ty.vec_width().is_some() && rk != Sc::Float {
            rt = self.convert_kind(rt, Sc::Float);
        }
        rt.e
    }

    /// The right side of `%=` (R49): floats on both sides, of the shape of the target.
    fn remainder_rhs(&mut self, lhs: &Ty, rt: T) -> Expr {
        let Some(lk) = lhs.kind() else { return rt.e };
        let mut rt = rt;
        if let (Some(n), Some(m)) = (lhs.width(), rt.ty.width())
            && m > n {
                rt = self.narrow_to(rt, n);
            }
        if lk == Sc::Float {
            rt = self.convert_kind(rt, Sc::Float);
            if let (Some(n), None) = (lhs.vec_width(), rt.ty.vec_width())
                && rt.ty.is_scalar() {
                    rt = self.broadcast(rt, n);
                }
        } else if lk.is_integer() && rt.ty.kind().is_some_and(|k| k != lk && k.is_numeric()) {
            rt = self.convert_kind(rt, lk);
        }
        rt.e
    }

    fn conditional(&mut self, c: Expr, a: Expr, b: Expr, span: Span) -> T {
        let ct = self.expr(c);
        let cond = self.cond_of(ct);
        let at = self.expr(a);
        let bt = self.expr(b);
        let (at, bt, ty) = self.unify_branches(at, bt);
        T::new(Expr::new(ExprKind::Cond(Box::new(cond), Box::new(at.e), Box::new(bt.e)), span), ty)
    }

    /// Brings the two branches of `?:` to one type (R56).
    fn unify_branches(&mut self, mut a: T, mut b: T) -> (T, T, Ty) {
        if a.ty == b.ty {
            let ty = a.ty.clone();
            return (a, b, ty);
        }
        if a.ty.is_unknown() || b.ty.is_unknown() {
            return (a, b, Ty::Unknown);
        }
        let (Some(ak), Some(bk)) = (a.ty.kind(), b.ty.kind()) else { return (a, b, Ty::Unknown) };
        // A boolean beside a number is that number.
        if ak == Sc::Bool && bk != Sc::Bool {
            a = self.convert_kind(a, bk);
        } else if bk == Sc::Bool && ak != Sc::Bool {
            b = self.convert_kind(b, ak);
        }
        let kind = {
            let (x, y) = (a.ty.kind().unwrap(), b.ty.kind().unwrap());
            if x == y { x } else { promote(x, y) }
        };
        a = self.convert_kind(a, kind);
        b = self.convert_kind(b, kind);
        if let (Some(m), Some(n)) = (a.ty.vec_width(), b.ty.vec_width()) {
            if m > n {
                a = self.narrow_to(a, n);
            } else if n > m {
                b = self.narrow_to(b, m);
            }
        }
        // A scalar beside a vector is replicated; wider vectors were cut above.
        match (a.ty.vec_width(), b.ty.vec_width()) {
            (Some(n), None) => b = self.broadcast(b, n),
            (None, Some(n)) => a = self.broadcast(a, n),
            _ => {}
        }
        let ty = a.ty.clone();
        (a, b, ty)
    }

    fn member(&mut self, base: Expr, field: String, span: Span) -> T {
        let b = self.expr(base);
        let (name, ty) = match &b.ty {
            // A scalar swizzled like a one-component vector (`f.x`, `f.xxx`, `f.rr`, `f.s`) repeats
            // its value. naga takes no swizzle of a scalar: one component is the value itself, more
            // are the constructor of that width, which reads the scalar once.
            Ty::Scalar(k) => match swizzle_type(*k, 1, &field) {
                Some(Ty::Vec(_, n)) => return self.broadcast(b, n),
                Some(_) => return b,
                None => (field, Ty::Unknown),
            },
            Ty::Vec(k, n) => {
                let ty = swizzle_type(*k, *n, &field).unwrap_or(Ty::Unknown);
                (field, ty)
            }
            Ty::Struct(i) => match self.structs[*i].fields.iter().find(|(n, _, _)| *n == field) {
                Some((_, ty, emit)) => (emit.clone(), ty.clone()),
                None => (field, Ty::Unknown),
            },
            _ => (field, Ty::Unknown),
        };
        T::new(Expr::new(ExprKind::Member(Box::new(b.e), name), span), ty)
    }

    fn index(&mut self, base: Expr, idx: Expr, span: Span) -> T {
        let b = self.expr(base);
        let i = self.expr(idx);
        let i = self.index_of(i);
        let ty = match &b.ty {
            Ty::Array(elem, _) => (**elem).clone(),
            Ty::Vec(k, _) => Ty::Scalar(*k),
            Ty::Mat(_, r) => Ty::vec(*r),
            _ => Ty::Unknown,
        };
        T::new(Expr::new(ExprKind::Index(Box::new(b.e), Box::new(i)), span), ty)
    }
}
