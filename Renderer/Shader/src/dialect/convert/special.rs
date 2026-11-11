// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Array and sampler parameters (R66, R67) and writes to stage inputs (R75).
//!
//! naga's GLSL front end does not register a function that takes an array or a sampler, so such
//! a function is kept as a template and specialised for the global array or sampler each call
//! passes: the parameter is dropped, the body reads the global, and every call drops the
//! argument. A call site with a different global gets a clone of its own. A parameter that the
//! body writes is copied into a local first.

use std::collections::BTreeSet;

use super::super::ast::*;
use super::super::ty::*;
use super::{Converter, FnInfo, T, VarKind};

pub(in crate::dialect) struct Special {
    pub template: Function,
    /// Indices of the array and sampler parameters.
    pub positions: Vec<usize>,
    /// The globals a variant was made for (source names) and the variant's name.
    pub variants: Vec<(Vec<String>, String)>,
}

/// The variable at the root of an lvalue: `a` in `a.x`, `a[i].y`, `(a)`.
pub(super) fn root_ident(e: &Expr) -> Option<&str> {
    match &e.kind {
        ExprKind::Ident(n) => Some(n),
        ExprKind::Paren(a) | ExprKind::Member(a, _) | ExprKind::Index(a, _) => root_ident(a),
        _ => None,
    }
}

/// True when some statement writes to `name` (assignment, increment, or as the root of one).
fn writes(body: &[Stmt], name: &str) -> bool {
    let mut found = false;
    walk_stmts(body, &mut |e| match &e.kind {
        ExprKind::Assign(_, l, _) | ExprKind::Unary(crate::lexer::Operator::Inc | crate::lexer::Operator::Dec, l) | ExprKind::Postfix(_, l)
            if root_ident(l) == Some(name) => {
                found = true;
            }
        _ => {}
    });
    found
}

/// Replaces every read of `from` by `to`, stopping where a declaration hides `from`.
fn substitute_block(list: &mut [Stmt], from: &str, to: &str) {
    for s in list.iter_mut() {
        if let Stmt::Decl(d) = s {
            let mut hidden = false;
            for dim in d.ty.dims.iter_mut().flatten() {
                substitute_expr(dim, from, to);
            }
            for decl in d.declarators.iter_mut() {
                if !hidden {
                    for dim in decl.dims.iter_mut().flatten() {
                        substitute_expr(dim, from, to);
                    }
                    if let Some(i) = &mut decl.init {
                        substitute_expr(i, from, to);
                    }
                }
                if decl.name == from {
                    hidden = true;
                }
            }
            if hidden {
                return;
            }
        } else {
            substitute_stmt(s, from, to);
        }
    }
}

fn substitute_expr(e: &mut Expr, from: &str, to: &str) {
    rewrite_expr(e, &mut |x| {
        if let ExprKind::Ident(n) = &mut x.kind
            && n == from {
                *n = to.to_string();
            }
    });
}

fn substitute_stmt(s: &mut Stmt, from: &str, to: &str) {
    match s {
        Stmt::Block(list) | Stmt::Seq(list) => substitute_block(list, from, to),
        Stmt::Expr(e) | Stmt::Case(e) => substitute_expr(e, from, to),
        Stmt::Return(Some(e), _) => substitute_expr(e, from, to),
        Stmt::If { cond, then, otherwise } => {
            substitute_expr(cond, from, to);
            substitute_block(std::slice::from_mut(then), from, to);
            if let Some(o) = otherwise {
                substitute_block(std::slice::from_mut(o), from, to);
            }
        }
        Stmt::For { init, cond, step, body } => {
            let mut hidden = false;
            if let Some(i) = init {
                if let Stmt::Decl(d) = &**i {
                    hidden = d.declarators.iter().any(|x| x.name == from);
                }
                // The initializer sees the outer name; everything after it may not.
                let mut one = vec![std::mem::replace(&mut **i, Stmt::Empty)];
                substitute_block(&mut one, from, to);
                **i = one.pop().unwrap();
            }
            if !hidden {
                if let Some(c) = cond {
                    substitute_expr(c, from, to);
                }
                if let Some(st) = step {
                    substitute_expr(st, from, to);
                }
                substitute_block(std::slice::from_mut(body), from, to);
            }
        }
        Stmt::While { cond, body } | Stmt::DoWhile { body, cond } => {
            substitute_expr(cond, from, to);
            substitute_block(std::slice::from_mut(body), from, to);
        }
        Stmt::Switch { value, body } => {
            substitute_expr(value, from, to);
            substitute_block(body, from, to);
        }
        _ => {}
    }
}

impl Converter {
    /// The parameters of `f` that are arrays or samplers.
    pub(super) fn special_positions(&mut self, f: &Function) -> Vec<usize> {
        let mut out = Vec::new();
        for (i, p) in f.params.iter().enumerate() {
            let ty = self.resolve_type(&p.ty, &p.dims);
            if p.sampler_param || matches!(ty, Ty::Array(..) | Ty::Sampler(_)) {
                out.push(i);
            }
        }
        out
    }

    pub(super) fn register_special(&mut self, fn_index: usize, template: Function, positions: Vec<usize>) {
        match self.specials.get_mut(&fn_index) {
            Some(existing) => {
                // A definition after its prototype supplies the body.
                if template.body.is_some() {
                    existing.template = template;
                }
            }
            None => {
                self.specials.insert(fn_index, Special { template, positions, variants: Vec::new() });
            }
        }
    }

    fn lookup_emit(&self, emit: &str) -> Option<&super::Var> {
        self.scopes.iter().rev().find_map(|s| s.values().find(|v| v.emit == emit))
    }

    /// A call of a template: the function specialised for the globals the call passes.
    pub(super) fn specialise_call(&mut self, index: usize, targs: Vec<T>, span: Span) -> T {
        let info: FnInfo = self.fns[index].clone();
        let (positions, has_body) = match self.specials.get(&index) {
            Some(s) => (s.positions.clone(), s.template.body.is_some()),
            None => (Vec::new(), false),
        };
        let fail = |this: &mut Converter, span: &Span, why: String| {
            this.error(span, why);
        };
        if !has_body {
            fail(self, &span, format!("`{}` takes an array or sampler parameter and has no definition to specialise", info.name));
            let args = targs.into_iter().map(|t| t.e).collect();
            return T::new(Expr::new(ExprKind::Call(Callee::Name(info.emit), args), span), info.ret);
        }
        let mut key: Vec<String> = Vec::new();
        for &pos in &positions {
            let name = match &targs[pos].e.peel().kind {
                ExprKind::Ident(emit) => self.lookup_emit(emit).filter(|v| matches!(v.kind, VarKind::Global | VarKind::Interface)).map(|v| v.source.clone()),
                _ => None,
            };
            match name {
                Some(n) => key.push(n),
                None => {
                    fail(
                        self,
                        &span,
                        format!(
                            "array-parameter specialisation limit: `{}` is specialised for the global array or sampler its call passes, and this call site passes a local or computed value for argument {} (call sites with different array arguments need a global array each)",
                            info.name,
                            pos + 1
                        ),
                    );
                    let args = targs.into_iter().map(|t| t.e).collect();
                    return T::new(Expr::new(ExprKind::Call(Callee::Name(info.emit), args), span), info.ret);
                }
            }
        }
        let existing = self.specials[&index].variants.iter().find(|(k, _)| *k == key).map(|(_, n)| n.clone());
        let callee = match existing {
            Some(n) => n,
            None => self.make_variant(index, &positions, key),
        };
        let mut args = Vec::new();
        for (i, (t, p)) in targs.into_iter().zip(&info.params).enumerate() {
            if positions.contains(&i) {
                continue;
            }
            let convertible = p.dir == ParamDir::In && !matches!(p.ty, Ty::Array(..) | Ty::Struct(_) | Ty::Sampler(_));
            args.push(if convertible { self.coerce(t, &p.ty) } else { t.e });
        }
        T::new(Expr::new(ExprKind::Call(Callee::Name(callee), args), span), info.ret)
    }

    /// Builds, converts and queues the variant of a template for `key`; returns its name.
    fn make_variant(&mut self, index: usize, positions: &[usize], key: Vec<String>) -> String {
        let mut f = self.specials[&index].template.clone();
        let n = self.specials[&index].variants.len() + 1;
        let mut name = format!("{}_wm{n}", f.name);
        while self.taken.contains(&name) {
            name.push('_');
        }
        self.taken.insert(name.clone());
        let mut body = f.body.take().unwrap_or_default();
        let mut prologue: Vec<Stmt> = Vec::new();
        for (k, &pos) in positions.iter().enumerate() {
            let p = &f.params[pos];
            let Some(pname) = p.name.clone() else { continue };
            let global = &key[k];
            let is_array = !p.dims.is_empty() || !p.ty.dims.is_empty();
            if is_array && writes(&body, &pname) {
                // The parameter is a copy: a local initialised from the global keeps writes local.
                let mut decl = VarDecl {
                    quals: Vec::new(),
                    ty: p.ty.clone(),
                    declarators: vec![Declarator {
                        name: pname.clone(),
                        name_span: p.span.clone(),
                        dims: p.dims.clone(),
                        init: Some(Expr::ident(global, p.span.clone())),
                    }],
                    span: p.span.clone(),
                };
                decl.quals.clear();
                prologue.push(Stmt::Decl(decl));
            } else {
                substitute_block(&mut body, &pname, global);
            }
        }
        let keep: BTreeSet<usize> = positions.iter().copied().collect();
        f.params = f.params.into_iter().enumerate().filter(|(i, _)| !keep.contains(i)).map(|(_, p)| p).collect();
        prologue.extend(body);
        f.body = Some(prologue);
        f.name = name.clone();
        // The variant sees the globals declared so far and nothing of the caller's scopes.
        let globals = self.scopes[0].clone();
        let saved_scopes = std::mem::replace(&mut self.scopes, vec![globals]);
        let saved_ret = self.cur_ret.take();
        let converted = self.function(f);
        self.scopes = saved_scopes;
        self.cur_ret = saved_ret;
        let emitted = converted.map(|c| {
            let n = c.name.clone();
            self.pending.push(Item::Function(c));
            n
        });
        let emitted = emitted.unwrap_or(name);
        self.specials.get_mut(&index).unwrap().variants.push((key, emitted.clone()));
        emitted
    }

    // ----- writes to stage inputs (R75) -----

    /// Notes that the variable named `name` (as the author wrote it) is written.
    pub(super) fn note_write(&mut self, name: &str) {
        if let Some(v) = self.lookup(name)
            && self.inputs.contains_key(&v.id) {
                let id = v.id;
                self.written_inputs.insert(id);
            }
    }

    /// Notes a write through a converted lvalue (names already as emitted).
    pub(super) fn note_write_emitted(&mut self, e: &Expr) {
        let Some(emit) = root_ident(e).map(str::to_string) else { return };
        let id = self.lookup_emit(&emit).map(|v| v.id);
        if let Some(id) = id
            && self.inputs.contains_key(&id) {
                self.written_inputs.insert(id);
            }
    }

    /// Gives every written input a writable copy: the interface variable is declared as
    /// `_we_in_<name>` and the author's name becomes a global initialised from it at the start
    /// of `main`. Reflection still reports the author's name for the input.
    pub(super) fn copy_written_inputs(&mut self, items: &mut Vec<Item>) {
        if !self.has_main || self.written_inputs.is_empty() {
            return;
        }
        let mut prologue = Vec::new();
        let ids: Vec<u32> = self.written_inputs.iter().copied().collect();
        for id in ids {
            let name = self.inputs[&id].clone();
            let pos = items.iter().position(|i| matches!(i, Item::Var(d) if d.declarators.iter().any(|x| x.name == name)));
            let Some(pos) = pos else { continue };
            let Item::Var(d) = &mut items[pos] else { continue };
            let idx = d.declarators.iter().position(|x| x.name == name).unwrap();
            let original = d.declarators[idx].clone();
            let renamed = format!("_we_in_{name}");
            d.declarators[idx].name = renamed.clone();
            let span = original.name_span.clone();
            let copy = VarDecl {
                quals: Vec::new(),
                ty: TypeRef { name: d.ty.name.clone(), dims: d.ty.dims.clone() },
                declarators: vec![Declarator { name: name.clone(), name_span: span.clone(), dims: original.dims.clone(), init: None }],
                span: d.span.clone(),
            };
            items.insert(pos + 1, Item::Var(copy));
            prologue.push(Stmt::Expr(Expr::new(
                ExprKind::Assign(
                    crate::lexer::Operator::Assign,
                    Box::new(Expr::ident(&name, span.clone())),
                    Box::new(Expr::ident(&renamed, span.clone())),
                ),
                span,
            )));
        }
        let mut moved = prologue;
        moved.append(&mut self.relocated);
        self.relocated = moved;
    }
}
