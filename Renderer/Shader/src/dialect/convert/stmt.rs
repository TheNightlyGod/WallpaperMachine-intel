// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Statements: scopes (R69), conditions (R52), returns (R61) and declarations (R76, R77).

use super::super::ast::*;
use super::super::ty::*;
use super::{Converter, VarKind};

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
        if let Some(reason) = self.unsupported_type(&d.ty.name, false) {
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
        Self::emit_type_alias(&mut d.ty);
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

    /// Keep authored expressions, including alpha-to-coverage sharpening. Its
    /// derivative controls multisample coverage and is not interchangeable with
    /// the alpha that existed before it.
    fn expr_stmt(&mut self, e: Expr) -> Expr {
        self.expr(e).e
    }
}
