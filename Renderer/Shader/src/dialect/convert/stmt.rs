// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Statements: scopes (R69), conditions (R52), returns (R61), declarations (R76, R77) and the
//! alpha-to-coverage idiom (R83).

use crate::lexer::Operator;
use crate::request::StageKind;

use super::super::ast::*;
use super::super::builtins::unsupported_reason;
use super::super::ty::*;
use super::{Converter, VarKind};

fn number_is(e: &Expr, value: f64) -> bool {
    match &e.peel().kind {
        ExprKind::Number(t) => t.trim_end_matches(['f', 'F']).parse::<f64>().is_ok_and(|v| v == value),
        _ => false,
    }
}

/// `color.a` for the colour output named `color`.
fn is_color_alpha(e: &Expr, color: &str) -> bool {
    match &e.peel().kind {
        ExprKind::Member(base, field) => field == "a" && matches!(&base.peel().kind, ExprKind::Ident(n) if n == color),
        _ => false,
    }
}

/// What the sharpening idiom needs to contain (R83 and the interface part's R59): at least two
/// reads of the colour output's alpha, a derivative call, a `max` call and at least two literals
/// `0.5`. The shipped form `(c.a - 0.5) / max(fwidth(c.a), 0.0001) + 0.5` is one instance.
fn is_sharpening(inner: &Expr, color: &str) -> bool {
    let (mut alpha_reads, mut derivative, mut max, mut halves) = (0, false, false, 0);
    walk_expr(inner, &mut |e| match &e.kind {
        ExprKind::Member(..) if is_color_alpha(e, color) => alpha_reads += 1,
        ExprKind::Call(Callee::Name(n), _) => {
            derivative |= matches!(n.as_str(), "fwidth" | "dFdx" | "dFdy" | "ddx" | "ddy");
            max |= n == "max";
        }
        ExprKind::Number(_) if number_is(e, 0.5) => halves += 1,
        _ => {}
    });
    alpha_reads >= 2 && derivative && max && halves >= 2
}

/// The argument of the `saturate` call the right-hand side begins with, if it begins with one:
/// what follows the call (a further product, say) is not part of the idiom.
fn leading_saturate(rhs: &Expr) -> Option<&Expr> {
    let mut x = rhs;
    loop {
        match &x.kind {
            ExprKind::Call(Callee::Name(n), args) if n == "saturate" && args.len() == 1 => return Some(&args[0]),
            ExprKind::Binary(_, l, _) => x = l,
            _ => return None,
        }
    }
}

/// Replaces the leading `saturate(...)` call of `rhs` (found like [`leading_saturate`]) by `with`.
fn replace_leading_saturate(rhs: &mut Expr, with: Expr) {
    match &mut rhs.kind {
        ExprKind::Binary(_, l, _) => replace_leading_saturate(l, with),
        _ => *rhs = with,
    }
}

/// True when a declaration list has an array declarator that another declarator follows.
/// naga gives the declarators after an array declarator the array type, so such a list is
/// written as separate declarations.
pub(super) fn needs_split(d: &VarDecl) -> bool {
    let n = d.declarators.len();
    d.declarators.iter().enumerate().any(|(i, x)| !x.dims.is_empty() && i + 1 < n)
}

pub(super) fn split_decl(d: VarDecl) -> Vec<VarDecl> {
    d.declarators
        .iter()
        .map(|x| VarDecl { quals: d.quals.clone(), ty: d.ty.clone(), declarators: vec![x.clone()], span: d.span.clone() })
        .collect()
}

/// True when the first token of the printed expression is a built-in type name.
fn starts_with_type_name(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Call(Callee::Type(_), _) => true,
        ExprKind::Binary(_, l, _) | ExprKind::Assign(_, l, _) | ExprKind::Index(l, _) | ExprKind::Member(l, _) => starts_with_type_name(l),
        ExprKind::Cond(c, _, _) => starts_with_type_name(c),
        ExprKind::Postfix(_, l) => starts_with_type_name(l),
        _ => false,
    }
}

impl Converter {
    /// Statements of a braced block, in a scope of their own.
    pub(super) fn block_scoped(&mut self, list: Vec<Stmt>) -> Vec<Stmt> {
        self.push_scope();
        let out = list.into_iter().map(|s| self.stmt(s)).collect();
        self.pop_scope();
        out
    }

    /// The body of `if`, `else` and loops: always a scope of its own.
    fn sub_stmt(&mut self, s: Stmt) -> Stmt {
        self.push_scope();
        let out = self.stmt(s);
        self.pop_scope();
        out
    }

    pub(super) fn convert_init(&mut self, e: Expr, ty: &Ty) -> Expr {
        match e.kind {
            ExprKind::InitList(list) => {
                let span = e.span;
                let elem = match ty {
                    Ty::Array(el, _) => Some((**el).clone()),
                    _ => None,
                };
                let list = list
                    .into_iter()
                    .map(|x| match &elem {
                        Some(t) => self.convert_init(x, t),
                        None => self.expr(x).e,
                    })
                    .collect();
                Expr::new(ExprKind::InitList(list), span)
            }
            _ => {
                let t = self.expr_target(e, Some(ty));
                self.coerce(t, ty)
            }
        }
    }

    fn local_decl(&mut self, mut d: VarDecl) -> VarDecl {
        if let Some(reason) = unsupported_reason(&d.ty.name) {
            let span = d.span.clone();
            self.error(&span, format!("unsupported construct `{}`: {reason}", d.ty.name));
        }
        let is_const = d.has_word("const");
        let declarators = std::mem::take(&mut d.declarators);
        let mut out = Vec::with_capacity(declarators.len());
        for mut decl in declarators {
            let ty = self.resolve_type(&d.ty, &decl.dims);
            let init = decl.init.take().map(|e| self.convert_init(e, &ty));
            let int_value = match (&init, &ty) {
                (Some(e), Ty::Scalar(Sc::Int | Sc::Uint)) if is_const => self.eval_const_int(e),
                _ => None,
            };
            let constant = is_const && init.as_ref().is_some_and(|e| self.is_constant_expr(e));
            decl.name = self.declare(&decl.name, ty, VarKind::Local, constant, int_value);
            decl.dims = self.convert_dims(std::mem::take(&mut decl.dims));
            decl.init = init;
            out.push(decl);
        }
        d.ty.dims = self.convert_dims(std::mem::take(&mut d.ty.dims));
        d.declarators = out;
        d
    }

    fn condition(&mut self, e: Expr) -> Expr {
        let t = self.expr(e);
        self.cond_of(t)
    }

    pub(super) fn stmt(&mut self, s: Stmt) -> Stmt {
        match s {
            Stmt::Block(list) => Stmt::Block(self.block_scoped(list)),
            Stmt::Decl(d) => {
                let d = self.local_decl(d);
                if needs_split(&d) {
                    Stmt::Seq(split_decl(d).into_iter().map(Stmt::Decl).collect())
                } else {
                    Stmt::Decl(d)
                }
            }
            Stmt::Struct(def) => Stmt::Struct(self.struct_def(def)),
            Stmt::Expr(e) => Stmt::Expr(self.expr_stmt(e)),
            Stmt::If { cond, then, otherwise } => {
                let cond = self.condition(cond);
                let then = Box::new(self.sub_stmt(*then));
                let otherwise = otherwise.map(|o| Box::new(self.sub_stmt(*o)));
                Stmt::If { cond, then, otherwise }
            }
            Stmt::For { init, cond, step, body } => {
                self.push_scope();
                let init = init.map(|i| self.stmt(*i));
                // naga reads a `for` condition that starts with a type name as a declaration.
                let cond = cond.map(|c| {
                    let c = self.condition(c);
                    if starts_with_type_name(&c) { c.paren() } else { c }
                });
                let step = step.map(|s| self.expr(s).e);
                let body = Box::new(self.sub_stmt(*body));
                self.pop_scope();
                match init {
                    // A declaration list split at an array declarator is several statements, which
                    // the loop header cannot hold: they go into a block of their own around the
                    // loop, so the names still belong to the loop alone.
                    Some(Stmt::Seq(mut decls)) => {
                        decls.push(Stmt::For { init: None, cond, step, body });
                        Stmt::Block(decls)
                    }
                    init => Stmt::For { init: init.map(Box::new), cond, step, body },
                }
            }
            Stmt::While { cond, body } => {
                let cond = self.condition(cond);
                let body = Box::new(self.sub_stmt(*body));
                Stmt::While { cond, body }
            }
            Stmt::DoWhile { body, cond } => {
                let body = Box::new(self.sub_stmt(*body));
                let cond = self.condition(cond);
                Stmt::DoWhile { body, cond }
            }
            Stmt::Switch { value, body } => {
                let t = self.expr(value);
                let value = self.index_of(t);
                let body = self.block_scoped(body);
                Stmt::Switch { value, body }
            }
            Stmt::Case(e) => Stmt::Case(self.expr(e).e),
            Stmt::Return(value, span) => {
                let value = value.map(|e| match self.cur_ret.clone() {
                    Some(ret) if !matches!(ret, Ty::Void | Ty::Unknown) => {
                        let t = self.expr_target(e, Some(&ret));
                        self.coerce(t, &ret)
                    }
                    _ => self.expr(e).e,
                });
                Stmt::Return(value, span)
            }
            other => other,
        }
    }

    /// An expression statement. In a fragment stage the alpha-to-coverage idiom is neutralised
    /// (R83) and the source of the colour output is tracked for it.
    fn expr_stmt(&mut self, e: Expr) -> Expr {
        if self.kind == StageKind::Fragment
            && let Some(replacement) = self.neutralise_sharpening(&e) {
                return replacement;
            }
        let source = self.color_assignment_source(&e);
        let t = self.expr(e);
        if let Some(name) = source
            && let Some(v) = self.lookup(&name)
                && v.ty == Ty::vec(4) {
                    self.color_source = Some((name, v.id));
                }
        t.e
    }

    fn is_color_name(&self, name: &str) -> bool {
        name == "gl_FragColor" || self.color_outputs.contains(name)
    }

    /// `color = source;` with a whole vec4 variable: the variable's name.
    fn color_assignment_source(&self, e: &Expr) -> Option<String> {
        let ExprKind::Assign(Operator::Assign, l, r) = &e.kind else { return None };
        let ExprKind::Ident(c) = &l.peel().kind else { return None };
        if !self.is_color_name(c) {
            return None;
        }
        match &r.peel().kind {
            ExprKind::Ident(n) => Some(n.clone()),
            _ => None,
        }
    }

    /// `color.a = [saturate](sharpening of color.a)` becomes the clamped alpha of the colour's
    /// source (R83, R59). The target must be the colour output's alpha and the right-hand side must
    /// contain the idiom; anything else is untouched.
    fn neutralise_sharpening(&mut self, e: &Expr) -> Option<Expr> {
        let ExprKind::Assign(Operator::Assign, l, r) = &e.kind else { return None };
        let ExprKind::Member(base, field) = &l.peel().kind else { return None };
        if field != "a" {
            return None;
        }
        let ExprKind::Ident(color) = &base.peel().kind else { return None };
        if !self.is_color_name(color) {
            return None;
        }
        let wrapper = leading_saturate(r);
        if !is_sharpening(wrapper.unwrap_or(r), color) {
            return None;
        }
        let saturated = wrapper.is_some();
        let (source, id) = self.color_source.clone()?;
        let var = self.lookup(&source)?;
        if var.id != id {
            return None;
        }
        let span = e.span.clone();
        let alpha = Expr::ident(&source, span.clone()).member("a");
        let value = if saturated {
            let zero = Expr::number("0.0", span.clone());
            let one = Expr::number("1.0", span.clone());
            Expr::call("clamp", vec![alpha, zero, one], span.clone())
        } else {
            alpha
        };
        // Anything after a leading `saturate(...)` stays: it is converted like any expression.
        let mut rhs = (**r).clone();
        if saturated {
            replace_leading_saturate(&mut rhs, value);
        } else {
            rhs = value;
        }
        let rhs = self.expr(rhs).e;
        let lhs = self.expr((**l).clone()).e;
        Some(Expr::new(ExprKind::Assign(Operator::Assign, Box::new(lhs), Box::new(rhs)), span))
    }
}
