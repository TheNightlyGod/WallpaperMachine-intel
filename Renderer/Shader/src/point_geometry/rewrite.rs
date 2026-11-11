//! Scope-aware rewrites of the two independent author modules.
use std::collections::{HashMap, HashSet};
use crate::dialect::ast::*;

pub(super) fn module(module: &mut Module, names: &HashMap<String, String>, types: &HashMap<String, String>,
                     stream: Option<(&str, &str)>) -> Result<(), String> {
    let mut rewrite = Rewrite { names, types, stream, scopes: Vec::new() };
    for item in &mut module.items {
        match item {
            Item::Var(decl) => rewrite.decl(decl, false)?,
            Item::Struct(definition) => rewrite.structure(definition)?,
            Item::Function(function) => {
                if let Some(name) = names.get(&function.name) { function.name = name.clone(); }
                rewrite.ty(&mut function.ret)?;
                let mut scope = HashSet::new();
                for parameter in &mut function.params {
                    rewrite.ty(&mut parameter.ty)?;
                    for dim in parameter.dims.iter_mut().flatten() { rewrite.expr(dim)?; }
                    if let Some(name) = &parameter.name { scope.insert(name.clone()); }
                }
                rewrite.scopes.push(scope);
                if let Some(body) = &mut function.body { rewrite.statements(body)?; }
                rewrite.scopes.pop();
            }
            Item::Block(block) => {
                for field in &mut block.fields { rewrite.ty(&mut field.ty)?; }
            }
            Item::Raw(text) if !text.trim().is_empty() => return Err(format!("unsupported point geometry declaration: {text}")),
            _ => {}
        }
    }
    Ok(())
}

struct Rewrite<'a> {
    names: &'a HashMap<String, String>,
    types: &'a HashMap<String, String>,
    stream: Option<(&'a str, &'a str)>,
    scopes: Vec<HashSet<String>>,
}

impl Rewrite<'_> {
    fn local(&self, name: &str) -> bool { self.scopes.iter().rev().any(|scope| scope.contains(name)) }
    fn ty(&mut self, ty: &mut TypeRef) -> Result<(), String> {
        if let Some(name) = self.types.get(&ty.name) { ty.name = name.clone(); }
        for dim in ty.dims.iter_mut().flatten() { self.expr(dim)?; }
        Ok(())
    }
    fn structure(&mut self, definition: &mut StructDef) -> Result<(), String> {
        if let Some(name) = &mut definition.name { if let Some(to) = self.types.get(name) { *name = to.clone(); } }
        for field in &mut definition.fields {
            self.ty(&mut field.ty)?;
            for variable in &mut field.declarators {
                if self.stream.is_some() && variable.name == "gl_Position" { variable.name = super::POSITION.into(); }
                for dim in variable.dims.iter_mut().flatten() { self.expr(dim)?; }
                if let Some(init) = &mut variable.init { self.expr(init)?; }
            }
        }
        Ok(())
    }
    fn decl(&mut self, decl: &mut VarDecl, local: bool) -> Result<(), String> {
        self.ty(&mut decl.ty)?;
        for variable in &mut decl.declarators {
            for dim in variable.dims.iter_mut().flatten() { self.expr(dim)?; }
            if let Some(init) = &mut variable.init { self.expr(init)?; }
            if local {
                if let Some(scope) = self.scopes.last_mut() { scope.insert(variable.name.clone()); }
            } else if let Some(name) = self.names.get(&variable.name) { variable.name = name.clone(); }
        }
        Ok(())
    }
    fn statements(&mut self, statements: &mut [Stmt]) -> Result<(), String> {
        for statement in statements { self.statement(statement)?; }
        Ok(())
    }
    fn scoped(&mut self, statement: &mut Stmt) -> Result<(), String> {
        self.scopes.push(HashSet::new());
        let result = self.statement(statement);
        self.scopes.pop(); result
    }
    fn statement(&mut self, statement: &mut Stmt) -> Result<(), String> {
        match statement {
            Stmt::Block(statements) => { self.scopes.push(HashSet::new()); self.statements(statements)?; self.scopes.pop(); }
            Stmt::Seq(statements) => self.statements(statements)?,
            Stmt::Decl(decl) => self.decl(decl, true)?,
            Stmt::Expr(expr) | Stmt::Case(expr) | Stmt::Return(Some(expr), _) => self.expr(expr)?,
            Stmt::If { cond, then, otherwise } => {
                self.expr(cond)?; self.scoped(then)?;
                if let Some(otherwise) = otherwise { self.scoped(otherwise)?; }
            }
            Stmt::For { init, cond, step, body } => {
                self.scopes.push(HashSet::new());
                if let Some(init) = init { self.statement(init)?; }
                if let Some(cond) = cond { self.expr(cond)?; }
                if let Some(step) = step { self.expr(step)?; }
                self.scoped(body)?; self.scopes.pop();
            }
            Stmt::While { cond, body } | Stmt::DoWhile { cond, body } => { self.expr(cond)?; self.scoped(body)?; }
            Stmt::Switch { value, body } => {
                self.expr(value)?; self.scopes.push(HashSet::new()); self.statements(body)?; self.scopes.pop();
            }
            Stmt::Struct(definition) => self.structure(definition)?,
            _ => {}
        }
        Ok(())
    }
    fn expr(&mut self, expr: &mut Expr) -> Result<(), String> {
        if let Some((emit, _)) = self.stream {
            if let ExprKind::Method(base, method, args) = &mut expr.kind {
                if matches!(&base.kind, ExprKind::Ident(name) if name == "OUT" && !self.local(name)) {
                    if method != "Append" || args.len() != 1 {
                        return Err("point geometry supports OUT.Append(value), not RestartStrip or other stream methods".into());
                    }
                    for arg in args.iter_mut() { self.expr(arg)?; }
                    expr.kind = ExprKind::Call(Callee::Name(emit.into()), std::mem::take(args));
                    return Ok(());
                }
            }
            if let ExprKind::Index(base, index) = &expr.kind {
                if matches!(&base.kind, ExprKind::Ident(name) if name == "IN" && !self.local(name)) &&
                    !matches!(&index.peel().kind, ExprKind::Number(number) if number.trim_end_matches(['u', 'U']) == "0") {
                    return Err("point geometry input is exactly IN[0]".into());
                }
            }
        }
        match &mut expr.kind {
            ExprKind::Ident(name) => if !self.local(name) { if let Some(to) = self.names.get(name) { *name = to.clone(); } },
            ExprKind::Paren(value) | ExprKind::Unary(_, value) | ExprKind::Postfix(_, value) => self.expr(value)?,
            ExprKind::Binary(_, a, b) | ExprKind::Assign(_, a, b) | ExprKind::Index(a, b) => { self.expr(a)?; self.expr(b)?; }
            ExprKind::Member(value, field) => {
                self.expr(value)?;
                if self.stream.is_some() && field == "gl_Position" { *field = super::POSITION.into(); }
            }
            ExprKind::Cond(a, b, c) => { self.expr(a)?; self.expr(b)?; self.expr(c)?; }
            ExprKind::Comma(values) | ExprKind::InitList(values) => for value in values { self.expr(value)?; },
            ExprKind::Call(callee, arguments) => {
                match callee {
                    Callee::Name(name) => if !self.local(name) {
                        if let Some(to) = self.names.get(name).or_else(|| self.types.get(name)) { *name = to.clone(); }
                    },
                    Callee::Type(ty) | Callee::Cast(ty) => self.ty(ty)?,
                }
                for arg in arguments { self.expr(arg)?; }
            }
            ExprKind::Method(base, _, args) => { self.expr(base)?; for arg in args { self.expr(arg)?; } }
            _ => {}
        }
        Ok(())
    }
}
