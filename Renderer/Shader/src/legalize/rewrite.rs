// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The rewrites that act on the body of a stage (spec C2): sampling calls on split textures
//! (4.7), video-plane sampling (4.8), reads of widened uniform arrays and of members stored
//! differently from how the author declared them (R19, R21, R87), and the fragment colour
//! output (R78).
//!
//! The converter has already expanded macros and renamed the spellings of the dialect, so
//! this pass works on a tree: an identifier is a read of a global only when no parameter or
//! local declaration hides it, and no rewrite can touch a comment, a string or a member field.

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::dialect::ast::*;
use crate::lexer::Operator;
use crate::request::StageKind;

use super::block::ReadInfo;
use super::collect::TexKind;
use super::error::LegalizeError;

/// What the stage knows about one uniform member it declares.
#[derive(Clone, Debug)]
pub(crate) struct MemberCx {
    pub read: ReadInfo,
    /// The stage declares the member narrower than the block does (R19).
    pub view: Option<&'static str>,
}

#[derive(Clone, Debug)]
pub(crate) struct TexCx {
    pub kind: TexKind,
    pub sampler: String,
    /// The material slot, when the texture is the luma plane of a flagged video slot.
    pub plane: Option<u8>,
}

pub(crate) struct StageCx {
    pub kind: StageKind,
    pub members: HashMap<String, MemberCx>,
    pub textures: HashMap<String, TexCx>,
    /// The name `gl_FragColor` is replaced by (fragment stage only).
    pub frag_out: Option<String>,
    /// The plane helper of each flagged slot, by slot.
    pub plane_helpers: HashMap<u8, String>,
}

/// What the pass found.
#[derive(Default)]
pub(crate) struct Findings {
    pub used_frag_color: bool,
    pub sampled_planes: BTreeSet<u8>,
    pub errors: Vec<LegalizeError>,
}

/// The largest widened array a shader may read as a whole (copied element by element).
const MAX_WHOLE_ARRAY: u32 = 4096;

pub(crate) fn is_sampling_fn(name: &str) -> bool {
    matches!(
        name,
        "texture"
            | "textureLod"
            | "textureGrad"
            | "textureOffset"
            | "textureProj"
            | "textureProjLod"
            | "textureLodOffset"
            | "textureGather"
            | "textureQueryLod"
    )
}

pub(crate) struct Rewriter<'a> {
    cx: &'a StageCx,
    scopes: Vec<HashSet<String>>,
    pub found: Findings,
}

fn ident(name: &str, span: &Span) -> Expr {
    Expr::ident(name, span.clone())
}

fn member(base: Expr, field: &str) -> Expr {
    let span = base.span.clone();
    Expr::new(ExprKind::Member(Box::new(base), field.to_string()), span)
}

fn index(base: Expr, i: u32) -> Expr {
    let span = base.span.clone();
    Expr::new(ExprKind::Index(Box::new(base), Box::new(Expr::number(&i.to_string(), span.clone()))), span)
}

fn unsigned_zero(width: u8, span: &Span) -> Expr {
    if width == 1 {
        Expr::number("0u", span.clone())
    } else {
        Expr::new(ExprKind::Call(Callee::Type(TypeRef::named(&format!("uvec{width}"))), vec![Expr::number("0u", span.clone())]), span.clone())
    }
}

impl<'a> Rewriter<'a> {
    pub fn new(cx: &'a StageCx) -> Rewriter<'a> {
        Rewriter { cx, scopes: Vec::new(), found: Findings::default() }
    }

    fn is_local(&self, name: &str) -> bool {
        self.scopes.iter().any(|s| s.contains(name))
    }

    fn declare(&mut self, name: &str) {
        if let Some(s) = self.scopes.last_mut() {
            s.insert(name.to_string());
        }
    }

    pub fn module(&mut self, m: &mut Module) {
        for item in m.items.iter_mut() {
            match item {
                Item::Var(d) => self.var_decl(d, false),
                Item::Function(f) => self.function(f),
                _ => {}
            }
        }
    }

    fn function(&mut self, f: &mut Function) {
        let Some(body) = &mut f.body else { return };
        let mut params = HashSet::new();
        for p in f.params.iter_mut() {
            for d in p.dims.iter_mut().flatten() {
                self.expr(d);
            }
            if let Some(n) = &p.name {
                params.insert(n.clone());
            }
        }
        self.scopes.push(params);
        self.stmts(body);
        self.scopes.pop();
    }

    fn var_decl(&mut self, d: &mut VarDecl, local: bool) {
        for dim in d.ty.dims.iter_mut().flatten() {
            self.expr(dim);
        }
        for x in d.declarators.iter_mut() {
            for dim in x.dims.iter_mut().flatten() {
                self.expr(dim);
            }
            if let Some(i) = &mut x.init {
                self.expr(i);
            }
            if local {
                self.declare(&x.name);
            }
        }
    }

    fn stmts(&mut self, list: &mut [Stmt]) {
        for s in list.iter_mut() {
            self.stmt(s);
        }
    }

    fn scoped(&mut self, s: &mut Stmt) {
        self.scopes.push(HashSet::new());
        self.stmt(s);
        self.scopes.pop();
    }

    fn stmt(&mut self, s: &mut Stmt) {
        match s {
            Stmt::Block(list) => {
                self.scopes.push(HashSet::new());
                self.stmts(list);
                self.scopes.pop();
            }
            Stmt::Seq(list) => self.stmts(list),
            Stmt::Decl(d) => self.var_decl(d, true),
            Stmt::Expr(e) | Stmt::Case(e) => self.expr(e),
            Stmt::If { cond, then, otherwise } => {
                self.expr(cond);
                self.scoped(then);
                if let Some(o) = otherwise {
                    self.scoped(o);
                }
            }
            Stmt::For { init, cond, step, body } => {
                self.scopes.push(HashSet::new());
                if let Some(i) = init {
                    self.stmt(i);
                }
                if let Some(c) = cond {
                    self.expr(c);
                }
                if let Some(st) = step {
                    self.expr(st);
                }
                self.scoped(body);
                self.scopes.pop();
            }
            Stmt::While { cond, body } | Stmt::DoWhile { body, cond } => {
                self.expr(cond);
                self.scoped(body);
            }
            Stmt::Switch { value, body } => {
                self.expr(value);
                self.scopes.push(HashSet::new());
                self.stmts(body);
                self.scopes.pop();
            }
            Stmt::Return(Some(e), _) => self.expr(e),
            _ => {}
        }
    }

    fn global_member(&self, e: &Expr) -> Option<&'a MemberCx> {
        let ExprKind::Ident(n) = &e.kind else { return None };
        if self.is_local(n) {
            return None;
        }
        self.cx.members.get(n)
    }

    fn refuse(&mut self, slot: u8, reason: &str) {
        self.found.errors.push(LegalizeError::request(format!(
            "texture slot {slot} cannot be sampled as planes: {reason}"
        )));
    }

    /// A call that samples a split texture (4.7, 4.8).
    fn try_sample(&mut self, e: &mut Expr) -> bool {
        let ExprKind::Call(Callee::Name(name), args) = &mut e.kind else { return false };
        if !is_sampling_fn(name) || args.is_empty() {
            return false;
        }
        let ExprKind::Ident(tex_name) = &args[0].kind else { return false };
        if self.is_local(tex_name) {
            return false;
        }
        let Some(tex) = self.cx.textures.get(tex_name) else { return false };
        let tex_name = tex_name.clone();
        let span = e.span.clone();
        if let Some(slot) = tex.plane {
            let plain = name == "texture" && args.len() == 2;
            if !plain {
                let reason = if name == "textureLod" {
                    "a mip-level sample is not available on a video plane".to_string()
                } else if args.len() < 2 {
                    "the call has no coordinate".to_string()
                } else if name == "texture" {
                    "the call has surplus arguments (only the texture and a coordinate are translated)".to_string()
                } else {
                    format!("`{name}` is not a plain sample")
                };
                self.refuse(slot, &reason);
                return true;
            }
            for a in args.iter_mut().skip(1) {
                self.expr(a);
            }
            let coord = args.remove(1);
            let helper = self.cx.plane_helpers.get(&slot).cloned().unwrap_or_default();
            self.found.sampled_planes.insert(slot);
            *e = Expr::new(ExprKind::Call(Callee::Name(helper), vec![coord]), span);
            return true;
        }
        let combined = TypeRef::named(tex.kind.combined_type());
        let pair = Expr::new(
            ExprKind::Call(Callee::Type(combined), vec![ident(&tex_name, &span), ident(&tex.sampler, &span)]),
            span.clone(),
        );
        args[0] = pair;
        for a in args.iter_mut().skip(1) {
            self.expr(a);
        }
        true
    }

    /// Reads of widened array members (R21, R87): `name[i]` selects the author's components.
    fn try_array_read(&mut self, e: &mut Expr) -> bool {
        match &mut e.kind {
            ExprKind::Index(base, idx) => {
                // An element of a two-row matrix array: the author's matrix from the stored one.
                if let Some(m) = self.global_member(base)
                    && m.read.array.is_some()
                    && let Some(ty) = m.read.narrow_matrix.clone() {
                        self.expr(idx);
                        let span = e.span.clone();
                        let inner = std::mem::replace(e, Expr::number("0", 0..0));
                        *e = Expr::new(ExprKind::Call(Callee::Type(TypeRef::named(&ty)), vec![inner]), span).paren();
                        return true;
                    }
                if let Some(m) = self.global_member(base)
                    && m.read.array.is_some()
                    && let Some(sel) = m.read.select {
                        self.expr(idx);
                        let inner = std::mem::replace(e, Expr::number("0", 0..0));
                        *e = member(inner, sel);
                        return true;
                    }
                // A second subscript of a one-component element selects that component (R21).
                if let ExprKind::Index(inner_base, inner_idx) = &mut base.kind
                    && let Some(m) = self.global_member(inner_base)
                    && m.read.array.is_some()
                    && m.read.scalar_element
                    && let Some(sel) = m.read.select {
                        self.expr(inner_idx);
                        let first = std::mem::replace(&mut **base, Expr::number("0", 0..0));
                        *e = member(first, sel);
                        return true;
                    }
                false
            }
            ExprKind::Member(base, _) => {
                if let ExprKind::Index(inner_base, inner_idx) = &mut base.kind
                    && let Some(m) = self.global_member(inner_base)
                    && m.read.array.is_some()
                    && m.read.select.is_some() {
                        // The author already selects from the element: left alone (R21).
                        self.expr(inner_idx);
                        return true;
                    }
                false
            }
            ExprKind::Method(base, _, args) => {
                // `name.length()` is the same on the widened array.
                if self.global_member(base).is_some_and(|m| m.read.array.is_some()) {
                    for a in args.iter_mut() {
                        self.expr(a);
                    }
                    return true;
                }
                false
            }
            _ => false,
        }
    }

    fn read_ident(&mut self, e: &mut Expr) {
        let ExprKind::Ident(n) = &e.kind else { return };
        if self.is_local(n) {
            return;
        }
        let span = e.span.clone();
        if self.cx.kind == StageKind::Fragment && n == "gl_FragColor"
            && let Some(out) = &self.cx.frag_out {
                self.found.used_frag_color = true;
                *e = ident(out, &span);
                return;
            }
        if let Some(tex) = self.cx.textures.get(n) {
            if let Some(slot) = tex.plane {
                self.refuse(slot, "the texture is used other than as the first argument of a plain sample");
            }
            return;
        }
        let Some(m) = self.cx.members.get(n) else { return };
        if let Some(ty) = &m.read.narrow_matrix {
            let author = |inner: Expr, span: &Span| {
                Expr::new(ExprKind::Call(Callee::Type(TypeRef::named(ty)), vec![inner]), span.clone())
            };
            let Some(count) = m.read.array else {
                *e = author(ident(n, &span), &span).paren();
                return;
            };
            if count > MAX_WHOLE_ARRAY {
                self.found.errors.push(LegalizeError::stage_local(
                    self.cx.kind,
                    Some(span.clone()),
                    format!("uniform array `{n}` has {count} elements and is read as a whole: a whole read of a widened array is limited to {MAX_WHOLE_ARRAY} elements"),
                ));
                return;
            }
            let elements: Vec<Expr> = (0..count).map(|i| author(index(ident(n, &span), i), &span)).collect();
            let array_ty = TypeRef { name: ty.clone(), dims: vec![Some(Expr::number(&count.to_string(), span.clone()))] };
            *e = Expr::new(ExprKind::Call(Callee::Type(array_ty), elements), span);
            return;
        }
        if let (Some(count), Some(sel)) = (m.read.array, m.read.select) {
            if count > MAX_WHOLE_ARRAY {
                self.found.errors.push(LegalizeError::stage_local(
                    self.cx.kind,
                    Some(span.clone()),
                    format!("uniform array `{n}` has {count} elements and is read as a whole: a whole read of a widened array is limited to {MAX_WHOLE_ARRAY} elements"),
                ));
                return;
            }
            // The whole array: a constructor of the author's element type.
            let elements: Vec<Expr> = (0..count).map(|i| member(index(ident(n, &span), i), sel)).collect();
            let ty = TypeRef { name: m.read.author_element.clone(), dims: vec![Some(Expr::number(&count.to_string(), span.clone()))] };
            *e = Expr::new(ExprKind::Call(Callee::Type(ty), elements), span);
            return;
        }
        if let Some(width) = m.read.as_bool {
            let id = ident(n, &span);
            let cmp = if width == 1 {
                Expr::binary(Operator::Ne, id, unsigned_zero(1, &span)).paren()
            } else {
                Expr::call("notEqual", vec![id, unsigned_zero(width, &span)], span.clone())
            };
            *e = cmp;
            return;
        }
        if let Some(sel) = m.view {
            let inner = std::mem::replace(e, Expr::number("0", 0..0));
            *e = member(inner, sel).paren();
        }
    }

    pub fn expr(&mut self, e: &mut Expr) {
        if self.try_array_read(e) || self.try_sample(e) {
            return;
        }
        match &mut e.kind {
            ExprKind::Ident(_) => self.read_ident(e),
            ExprKind::Paren(a) | ExprKind::Unary(_, a) | ExprKind::Postfix(_, a) | ExprKind::Member(a, _) => self.expr(a),
            ExprKind::Binary(_, a, b) | ExprKind::Assign(_, a, b) | ExprKind::Index(a, b) => {
                self.expr(a);
                self.expr(b);
            }
            ExprKind::Cond(a, b, c) => {
                self.expr(a);
                self.expr(b);
                self.expr(c);
            }
            ExprKind::Comma(list) | ExprKind::InitList(list) | ExprKind::Call(_, list) => {
                for x in list.iter_mut() {
                    self.expr(x);
                }
            }
            ExprKind::Method(base, _, args) => {
                self.expr(base);
                for x in args.iter_mut() {
                    self.expr(x);
                }
            }
            ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Opaque(_) => {}
        }
    }
}
