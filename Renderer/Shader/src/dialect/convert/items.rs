// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Top-level items: structs, globals (R72, R73, R88), blocks, functions, and the assembly of
//! the converted module with its helpers.

use std::collections::HashSet;

use crate::lexer::Operator;

use super::super::ast::*;
use super::super::builtins::{RESTATED_BUILTINS, unsupported_reason};
use super::super::ty::*;
use super::helpers::HelperKind;
use super::{Converter, FnInfo, ParamInfo, StructInfo, VarKind};

const INTERFACE_WORDS: [&str; 6] = ["uniform", "attribute", "varying", "in", "out", "buffer"];

impl Converter {
    pub(super) fn module(&mut self, m: Module) -> Module {
        let mut defined: HashSet<String> = HashSet::new();
        let mut has_main = false;
        for item in &m.items {
            if let Item::Function(f) = item {
                defined.insert(f.name.clone());
                if f.name == "main" && f.body.is_some() {
                    has_main = true;
                }
            }
        }
        let mut calls_lighting = false;
        walk_module(&m, &mut |e| {
            if let ExprKind::Call(Callee::Name(n), _) = &e.kind
                && n == "PerformLighting_V1" {
                    calls_lighting = true;
                }
        });
        self.has_main = has_main;
        if calls_lighting && !defined.contains("PerformLighting_V1") {
            self.register_lighting_stand_in();
        }
        let mut out: Vec<Item> = Vec::with_capacity(m.items.len());
        for item in m.items {
            match item {
                Item::Struct(def) => {
                    let def = self.struct_def(def);
                    out.push(Item::Struct(def));
                }
                Item::Var(decl) => out.extend(self.global_var(decl)),
                Item::Block(b) => out.push(Item::Block(self.block_decl(b))),
                Item::Function(f) => {
                    let converted = self.function(f);
                    out.append(&mut self.pending);
                    if let Some(c) = converted {
                        out.push(Item::Function(c));
                    }
                }
                other => out.push(other),
            }
        }
        self.copy_written_inputs(&mut out);
        // Initializers that read run-time values run first in `main` (R72).
        if !self.relocated.is_empty() {
            let moved = std::mem::take(&mut self.relocated);
            for item in out.iter_mut() {
                if let Item::Function(f) = item
                    && f.name == "main"
                        && let Some(body) = &mut f.body {
                            body.splice(0..0, moved);
                            break;
                        }
            }
        }
        // Helpers go ahead of the first function (R86).
        let helpers = self.helpers.items(&self.prefix);
        if !helpers.is_empty() {
            let at = out.iter().position(|i| matches!(i, Item::Function(_))).unwrap_or(out.len());
            out.splice(at..at, helpers);
        }
        Module { items: out }
    }

    fn register_lighting_stand_in(&mut self) {
        self.helpers.need(HelperKind::Lighting);
        let v3 = ParamInfo { ty: Ty::vec(3), dir: ParamDir::In };
        let f = ParamInfo { ty: FLOAT, dir: ParamDir::In };
        let mut eight = vec![v3.clone(); 6];
        eight.push(f.clone());
        eight.push(f.clone());
        let mut nine = eight.clone();
        nine.push(f);
        for params in [eight, nine] {
            self.fns.push(FnInfo { name: "PerformLighting_V1".into(), params, ret: Ty::vec(3), emit: "PerformLighting_V1".into() });
            let idx = self.fns.len() - 1;
            self.fn_by_name.entry("PerformLighting_V1".into()).or_default().push(idx);
        }
    }

    // ----- structs -----

    pub(super) fn struct_def(&mut self, mut def: StructDef) -> StructDef {
        let mut fields_info: Vec<(String, Ty, String)> = Vec::new();
        for f in def.fields.iter_mut() {
            if let Some(reason) = unsupported_reason(&f.ty.name) {
                let span = f.span.clone();
                self.error(&span, format!("unsupported construct `{}`: {reason}", f.ty.name));
            }
            for d in f.declarators.iter_mut() {
                let ty = self.resolve_type(&f.ty, &d.dims);
                let emit = self.emit_name(&d.name);
                fields_info.push((d.name.clone(), ty, emit.clone()));
                d.name = emit;
            }
        }
        let info = StructInfo { name: def.name.clone().unwrap_or_default(), fields: fields_info };
        self.structs.push(info);
        let idx = self.structs.len() - 1;
        if let Some(n) = &def.name {
            self.struct_by_name.insert(n.clone(), idx);
        }
        let instances = std::mem::take(&mut def.declarators);
        for d in &instances {
            let ty = self.wrap_dims(Ty::Struct(idx), d.dims.iter());
            self.declare(&d.name, ty, VarKind::Global, false, None);
        }
        def.declarators = instances;
        def
    }

    fn block_decl(&mut self, mut b: BlockDecl) -> BlockDecl {
        let mut fields_info = Vec::new();
        for f in b.fields.iter_mut() {
            for d in f.declarators.iter_mut() {
                let ty = self.resolve_type(&f.ty, &d.dims);
                let emit = self.emit_name(&d.name);
                fields_info.push((d.name.clone(), ty, emit.clone()));
                d.name = emit;
            }
        }
        match &b.instance {
            Some(inst) => {
                self.structs.push(StructInfo { name: b.name.clone(), fields: fields_info });
                let idx = self.structs.len() - 1;
                self.declare(&inst.name, Ty::Struct(idx), VarKind::Interface, false, None);
            }
            None => {
                for (name, ty, _) in fields_info {
                    self.declare(&name, ty, VarKind::Interface, false, None);
                }
            }
        }
        b
    }

    // ----- globals -----

    /// True when the (converted) expression is built only from literals and constants (R72).
    pub(super) fn is_constant_expr(&self, e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Number(_) | ExprKind::Bool(_) => true,
            ExprKind::Ident(n) => self.scopes.iter().rev().find_map(|s| s.values().find(|v| v.emit == *n)).is_some_and(|v| v.constant),
            ExprKind::Paren(a) | ExprKind::Member(a, _) => self.is_constant_expr(a),
            ExprKind::Unary(op, a) => !op.is_increment_or_decrement() && self.is_constant_expr(a),
            ExprKind::Binary(_, a, b) | ExprKind::Index(a, b) => self.is_constant_expr(a) && self.is_constant_expr(b),
            ExprKind::Cond(a, b, c) => self.is_constant_expr(a) && self.is_constant_expr(b) && self.is_constant_expr(c),
            ExprKind::InitList(list) => list.iter().all(|x| self.is_constant_expr(x)),
            ExprKind::Call(Callee::Type(_), args) => args.iter().all(|x| self.is_constant_expr(x)),
            ExprKind::Call(Callee::Name(n), args) => self.struct_by_name.contains_key(n) && args.iter().all(|x| self.is_constant_expr(x)),
            _ => false,
        }
    }

    fn global_var(&mut self, mut d: VarDecl) -> Vec<Item> {
        if let Some(reason) = unsupported_reason(&d.ty.name) {
            let span = d.span.clone();
            self.error(&span, format!("unsupported construct `{}`: {reason}", d.ty.name));
        }
        let interface = d.quals.iter().any(|q| matches!(q, Qualifier::Word(w) if INTERFACE_WORDS.contains(&w.as_str())));
        // A restated builtin is not an input or an output: the backend provides it (R88, and
        // the interface part's R11). The OpenGL spellings of the index builtins count only
        // when written with the type `uint`.
        let stage_qualified = d.quals.iter().any(|q| matches!(q, Qualifier::Word(w) if matches!(w.as_str(), "attribute" | "varying" | "in" | "out")));
        if stage_qualified {
            let uint_index = d.ty.name == "uint" && d.ty.dims.is_empty();
            d.declarators.retain(|x| {
                !(RESTATED_BUILTINS.contains(&x.name.as_str()) || uint_index && (x.name == "gl_VertexID" || x.name == "gl_InstanceID"))
            });
            if d.declarators.is_empty() {
                return Vec::new();
            }
        }
        let is_const = d.has_word("const");
        let is_out = d.quals.iter().any(|q| q.is_word("out"));
        let is_input = match self.kind {
            crate::request::StageKind::Vertex => d.quals.iter().any(|q| q.is_word("attribute") || q.is_word("in")),
            crate::request::StageKind::Fragment => d.quals.iter().any(|q| q.is_word("varying") || q.is_word("in")),
        };
        let mut parts: Vec<(Declarator, bool)> = Vec::new(); // declarator, relocated
        let mut relocated_any = false;
        let declarators = std::mem::take(&mut d.declarators);
        for mut decl in declarators {
            let ty = self.resolve_type(&d.ty, &decl.dims);
            let init = decl.init.take().map(|e| self.convert_init(e, &ty));
            let init_const = init.as_ref().is_some_and(|e| self.is_constant_expr(e));
            let int_value = match (&init, &ty) {
                (Some(e), Ty::Scalar(Sc::Int | Sc::Uint)) if is_const => self.eval_const_int(e),
                _ => None,
            };
            let kind = if interface { VarKind::Interface } else { VarKind::Global };
            let emit = self.declare(&decl.name, ty.clone(), kind, is_const && init_const && !interface, int_value);
            if is_input {
                let id = self.lookup(&decl.name).map(|v| v.id).unwrap_or(0);
                self.inputs.insert(id, decl.name.clone());
            }
            if is_out && ty == Ty::vec(4) && self.kind == crate::request::StageKind::Fragment {
                self.color_outputs.insert(emit.clone());
            }
            decl.name = emit.clone();
            decl.dims = self.convert_dims(std::mem::take(&mut decl.dims));
            let relocate = !interface && self.has_main && init.is_some() && !init_const;
            if relocate {
                let init = init.unwrap();
                let span = init.span.clone();
                let target = Expr::ident(&emit, span.clone());
                self.relocated.push(Stmt::Expr(Expr::new(
                    ExprKind::Assign(Operator::Assign, Box::new(target), Box::new(init)),
                    span,
                )));
                relocated_any = true;
                parts.push((decl, true));
            } else {
                decl.init = init;
                parts.push((decl, false));
            }
        }
        d.ty.dims = self.convert_dims(std::mem::take(&mut d.ty.dims));
        if !relocated_any {
            d.declarators = parts.into_iter().map(|(x, _)| x).collect();
            if super::stmt::needs_split(&d) {
                return super::stmt::split_decl(d).into_iter().map(Item::Var).collect();
            }
            return vec![Item::Var(d)];
        }
        // A declaration list with a moved initializer is split: the moved ones lose `const`.
        parts
            .into_iter()
            .map(|(decl, moved)| {
                let mut one = d.clone();
                if moved {
                    one.quals.retain(|q| !q.is_word("const"));
                }
                one.declarators = vec![decl];
                Item::Var(one)
            })
            .collect()
    }

    /// Array dimensions are expressions too (`float w[N + 1]`): converted like any other.
    pub(super) fn convert_dims(&mut self, dims: Vec<Option<Expr>>) -> Vec<Option<Expr>> {
        dims.into_iter().map(|d| d.map(|e| self.expr(e).e)).collect()
    }

    // ----- functions -----

    pub(super) fn function(&mut self, mut f: Function) -> Option<Function> {
        if let Some(reason) = unsupported_reason(&f.ret.name) {
            let span = f.span.clone();
            self.error(&span, format!("unsupported construct `{}`: {reason}", f.ret.name));
        }
        let ret = self.resolve_type(&f.ret, &[]);
        let mut infos = Vec::with_capacity(f.params.len());
        for p in &f.params {
            if let Some(reason) = unsupported_reason(&p.ty.name) {
                self.error(&p.span.clone(), format!("unsupported construct `{}`: {reason}", p.ty.name));
            }
            let ty = if p.sampler_param { Ty::Sampler(SamplerKind::D2) } else { self.resolve_type(&p.ty, &p.dims) };
            infos.push(ParamInfo { ty, dir: p.dir() });
        }
        let emit = self.emit_name(&f.name);
        let positions = self.special_positions(&f);
        let same = |a: &FnInfo| {
            a.name == f.name && a.ret == ret && a.params.len() == infos.len() && a.params.iter().zip(&infos).all(|(x, y)| x.ty == y.ty && x.dir == y.dir)
        };
        let index = match self.fns.iter().position(same) {
            Some(i) => i,
            None => {
                self.fns.push(FnInfo { name: f.name.clone(), params: infos.clone(), ret: ret.clone(), emit: emit.clone() });
                let idx = self.fns.len() - 1;
                self.fn_by_name.entry(f.name.clone()).or_default().push(idx);
                idx
            }
        };
        if !positions.is_empty() {
            // naga does not take array or sampler parameters: the function is kept as a
            // template and specialised per call (R66, R67).
            self.register_special(index, f, positions);
            return None;
        }
        f.name = emit;
        if let Some(body) = f.body.take() {
            self.push_scope();
            for (p, info) in f.params.iter_mut().zip(&infos) {
                if let Some(name) = &p.name {
                    let emitted = self.declare(name, info.ty.clone(), VarKind::Param, false, None);
                    p.name = Some(emitted);
                }
                p.dims = self.convert_dims(std::mem::take(&mut p.dims));
            }
            let saved = (self.cur_ret.replace(ret), self.color_source.take());
            let converted = self.block_scoped(body);
            self.cur_ret = saved.0;
            self.color_source = saved.1;
            self.pop_scope();
            f.body = Some(converted);
        } else {
            for p in f.params.iter_mut() {
                if let Some(name) = &p.name {
                    p.name = Some(self.emit_name(name));
                }
            }
        }
        Some(f)
    }
}
