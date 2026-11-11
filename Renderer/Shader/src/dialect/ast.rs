// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The syntax tree of one stage after macro expansion.
//!
//! The tree covers the GLSL-looking dialect: top-level items, statements and
//! expressions. Nodes own their children; the converter consumes a tree and
//! builds the rewritten one. Spans are byte ranges into the stage text and are
//! used for diagnostics only: generated nodes borrow the span of the node they
//! stand for.

use std::ops::Range;

use crate::lexer::Operator;

pub type Span = Range<usize>;

#[derive(Clone, Debug, PartialEq)]
pub struct Module {
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Item {
    /// A preprocessor line that survived macro expansion (`#extension`, `#pragma`, `#line`).
    Directive(String),
    /// A WE annotation comment line, carried through untouched.
    Annotation(String),
    /// `precision highp float;` kept as written (without the `;`).
    Precision(String),
    Struct(StructDef),
    /// A uniform, in, out, block or ordinary global variable declaration.
    Var(VarDecl),
    /// `uniform Name { ... } instance;`
    Block(BlockDecl),
    Function(Function),
    /// Tokens the grammar cannot place, carried through as text.
    Raw(String),
}

/// A qualifier in front of a type, kept in source order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Qualifier {
    /// `const uniform attribute varying in out inout lowp mediump highp flat smooth
    /// noperspective centroid sample invariant buffer shared ...`
    Word(String),
    /// The text between the parentheses of `layout(...)`.
    Layout(String),
}

impl Qualifier {
    pub fn is_word(&self, word: &str) -> bool {
        matches!(self, Qualifier::Word(w) if w == word)
    }
}

/// A type as written: a name (canonical GLSL spelling for the built-in ones, the struct name
/// otherwise) and optional array dimensions (`float[3]`).
#[derive(Clone, Debug, PartialEq)]
pub struct TypeRef {
    pub name: String,
    pub dims: Vec<Option<Expr>>,
}

impl TypeRef {
    pub fn named(name: &str) -> TypeRef {
        TypeRef { name: name.to_string(), dims: Vec::new() }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Declarator {
    pub name: String,
    pub name_span: Span,
    /// Array suffixes after the name, `None` for `[]`.
    pub dims: Vec<Option<Expr>>,
    pub init: Option<Expr>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct VarDecl {
    pub quals: Vec<Qualifier>,
    pub ty: TypeRef,
    pub declarators: Vec<Declarator>,
    pub span: Span,
}

impl VarDecl {
    pub fn has_word(&self, word: &str) -> bool {
        self.quals.iter().any(|q| q.is_word(word))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StructDef {
    pub name: Option<String>,
    pub fields: Vec<VarDecl>,
    /// Instances declared in the same statement (`struct S { ... } a, b;`).
    pub declarators: Vec<Declarator>,
    pub quals: Vec<Qualifier>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BlockDecl {
    pub quals: Vec<Qualifier>,
    pub name: String,
    pub fields: Vec<VarDecl>,
    pub instance: Option<Declarator>,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParamDir {
    In,
    Out,
    InOut,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Param {
    /// Words before the type: `const in out inout lowp mediump highp`.
    pub quals: Vec<String>,
    pub ty: TypeRef,
    pub name: Option<String>,
    pub dims: Vec<Option<Expr>>,
    /// `DECLARE_SAMPLER2D_PARAMETER(name)`.
    pub sampler_param: bool,
    pub span: Span,
}

impl Param {
    pub fn dir(&self) -> ParamDir {
        let has = |w: &str| self.quals.iter().any(|q| q == w);
        if has("inout") {
            ParamDir::InOut
        } else if has("out") {
            ParamDir::Out
        } else {
            ParamDir::In
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Function {
    pub quals: Vec<Qualifier>,
    pub ret: TypeRef,
    pub name: String,
    pub name_span: Span,
    pub params: Vec<Param>,
    /// `None` for a prototype.
    pub body: Option<Vec<Stmt>>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Stmt {
    Block(Vec<Stmt>),
    Decl(VarDecl),
    Expr(Expr),
    If { cond: Expr, then: Box<Stmt>, otherwise: Option<Box<Stmt>> },
    For { init: Option<Box<Stmt>>, cond: Option<Expr>, step: Option<Expr>, body: Box<Stmt> },
    While { cond: Expr, body: Box<Stmt> },
    DoWhile { body: Box<Stmt>, cond: Expr },
    Switch { value: Expr, body: Vec<Stmt> },
    Case(Expr),
    Default,
    Return(Option<Expr>, Span),
    Break,
    Continue,
    Discard,
    Empty,
    Directive(String),
    /// A struct declared inside a function body.
    Struct(StructDef),
    /// Statements that belong to the enclosing scope, written one after the other (a
    /// declaration list that was split). The parser never produces it.
    Seq(Vec<Stmt>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
    /// Height of the tree below and including this node. Kept so that a hostile, very deep
    /// expression is refused before anything recurses over it.
    pub depth: u32,
}

/// The deepest expression the front end accepts. Real shaders stay far below it.
pub const MAX_EXPR_DEPTH: u32 = 256;

#[derive(Clone, Debug, PartialEq)]
pub enum Callee {
    Name(String),
    /// A constructor: `vec3(...)`, `float[2](...)`, `S(...)`.
    Type(TypeRef),
    /// An explicit scalar/vector HLSL cast, whose broadcast/truncation rules
    /// differ from a numeric constructor's component count.
    Cast(TypeRef),
}

#[derive(Clone, Debug, PartialEq)]
pub enum ExprKind {
    /// A numeric literal as written.
    Number(String),
    Bool(bool),
    Ident(String),
    Paren(Box<Expr>),
    /// Prefix operators: `- + ! ~ ++ --`.
    Unary(Operator, Box<Expr>),
    /// Postfix `++` and `--`.
    Postfix(Operator, Box<Expr>),
    Binary(Operator, Box<Expr>, Box<Expr>),
    Assign(Operator, Box<Expr>, Box<Expr>),
    Cond(Box<Expr>, Box<Expr>, Box<Expr>),
    Comma(Vec<Expr>),
    Call(Callee, Vec<Expr>),
    Index(Box<Expr>, Box<Expr>),
    Member(Box<Expr>, String),
    /// `base.name(args)`, as in `arr.length()`.
    Method(Box<Expr>, String, Vec<Expr>),
    /// `{a, b, c}`, only meaningful as an initializer.
    InitList(Vec<Expr>),
    /// A token the grammar does not know, carried through.
    Opaque(String),
}

impl Expr {
    pub fn new(kind: ExprKind, span: Span) -> Expr {
        let below = match &kind {
            ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Opaque(_) => 0,
            ExprKind::Paren(a) | ExprKind::Unary(_, a) | ExprKind::Postfix(_, a) | ExprKind::Member(a, _) => a.depth,
            ExprKind::Binary(_, a, b) | ExprKind::Assign(_, a, b) | ExprKind::Index(a, b) => a.depth.max(b.depth),
            ExprKind::Cond(a, b, c) => a.depth.max(b.depth).max(c.depth),
            ExprKind::Comma(list) | ExprKind::InitList(list) | ExprKind::Call(_, list) => list.iter().map(|x| x.depth).max().unwrap_or(0),
            ExprKind::Method(base, _, args) => args.iter().map(|x| x.depth).max().unwrap_or(0).max(base.depth),
        };
        Expr { kind, span, depth: below.saturating_add(1) }
    }

    pub fn ident(name: &str, span: Span) -> Expr {
        Expr::new(ExprKind::Ident(name.to_string()), span)
    }

    pub fn number(text: &str, span: Span) -> Expr {
        Expr::new(ExprKind::Number(text.to_string()), span)
    }

    pub fn paren(self) -> Expr {
        let span = self.span.clone();
        Expr::new(ExprKind::Paren(Box::new(self)), span)
    }

    /// A call of a named function.
    pub fn call(name: &str, args: Vec<Expr>, span: Span) -> Expr {
        Expr::new(ExprKind::Call(Callee::Name(name.to_string()), args), span)
    }

    /// A constructor call of a built-in type.
    pub fn ctor(type_name: &str, args: Vec<Expr>, span: Span) -> Expr {
        Expr::new(ExprKind::Call(Callee::Type(TypeRef::named(type_name)), args), span)
    }

    pub fn binary(op: Operator, l: Expr, r: Expr) -> Expr {
        let span = l.span.start.min(r.span.start)..l.span.end.max(r.span.end);
        Expr::new(ExprKind::Binary(op, Box::new(l), Box::new(r)), span)
    }

    pub fn member(self, field: &str) -> Expr {
        let span = self.span.clone();
        Expr::new(ExprKind::Member(Box::new(self), field.to_string()), span)
    }

    /// The expression with enclosing parentheses removed.
    pub fn peel(&self) -> &Expr {
        let mut e = self;
        while let ExprKind::Paren(inner) = &e.kind {
            e = inner;
        }
        e
    }

    pub fn into_peeled(self) -> Expr {
        match self.kind {
            ExprKind::Paren(inner) => inner.into_peeled(),
            _ => self,
        }
    }

    /// True for nodes that print as a single primary expression, so a postfix can follow directly.
    pub fn is_primary(&self) -> bool {
        match &self.kind {
            ExprKind::Number(_)
            | ExprKind::Bool(_)
            | ExprKind::Ident(_)
            | ExprKind::Paren(_)
            | ExprKind::Call(..)
            | ExprKind::Index(..)
            | ExprKind::Member(..)
            | ExprKind::Method(..) => true,
            ExprKind::Postfix(..) => false,
            _ => false,
        }
    }

    /// Whether evaluating the expression twice could differ from evaluating it once or could
    /// have an effect: calls, assignments, increments. Constructors and builtin calls count as
    /// calls only when an argument does, but the converter treats every call conservatively.
    pub fn has_effects(&self) -> bool {
        match &self.kind {
            ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Opaque(_) => false,
            ExprKind::Paren(e) | ExprKind::Member(e, _) => e.has_effects(),
            ExprKind::Unary(op, e) => op.is_increment_or_decrement() || e.has_effects(),
            ExprKind::Postfix(_, _) | ExprKind::Assign(..) | ExprKind::Method(..) => true,
            ExprKind::Binary(_, l, r) | ExprKind::Index(l, r) => l.has_effects() || r.has_effects(),
            ExprKind::Cond(a, b, c) => a.has_effects() || b.has_effects() || c.has_effects(),
            ExprKind::Comma(list) | ExprKind::InitList(list) => list.iter().any(Expr::has_effects),
            ExprKind::Call(Callee::Type(_) | Callee::Cast(_), args) => args.iter().any(Expr::has_effects),
            ExprKind::Call(Callee::Name(_), _) => true,
        }
    }
}

impl Stmt {
    pub fn block_or_single(self) -> Vec<Stmt> {
        match self {
            Stmt::Block(list) => list,
            other => vec![other],
        }
    }
}

/// Calls `f` on every expression of the module, parents before children.
pub fn walk_module(m: &Module, f: &mut dyn FnMut(&Expr)) {
    for item in &m.items {
        match item {
            Item::Var(d) => walk_decl(d, f),
            Item::Struct(def) => def.fields.iter().for_each(|d| walk_decl(d, f)),
            Item::Block(b) => b.fields.iter().for_each(|d| walk_decl(d, f)),
            Item::Function(func) => {
                for p in &func.params {
                    walk_dims(&p.dims, f);
                }
                if let Some(body) = &func.body {
                    walk_stmts(body, f);
                }
            }
            _ => {}
        }
    }
}

fn walk_dims(dims: &[Option<Expr>], f: &mut dyn FnMut(&Expr)) {
    for d in dims.iter().flatten() {
        walk_expr(d, f);
    }
}

fn walk_decl(d: &VarDecl, f: &mut dyn FnMut(&Expr)) {
    walk_dims(&d.ty.dims, f);
    for x in &d.declarators {
        walk_dims(&x.dims, f);
        if let Some(i) = &x.init {
            walk_expr(i, f);
        }
    }
}

pub fn walk_stmts(list: &[Stmt], f: &mut dyn FnMut(&Expr)) {
    list.iter().for_each(|s| walk_stmt(s, f));
}

pub fn walk_stmt(s: &Stmt, f: &mut dyn FnMut(&Expr)) {
    match s {
        Stmt::Block(list) | Stmt::Seq(list) => walk_stmts(list, f),
        Stmt::Decl(d) => walk_decl(d, f),
        Stmt::Expr(e) => walk_expr(e, f),
        Stmt::If { cond, then, otherwise } => {
            walk_expr(cond, f);
            walk_stmt(then, f);
            if let Some(o) = otherwise {
                walk_stmt(o, f);
            }
        }
        Stmt::For { init, cond, step, body } => {
            if let Some(i) = init {
                walk_stmt(i, f);
            }
            if let Some(c) = cond {
                walk_expr(c, f);
            }
            if let Some(s) = step {
                walk_expr(s, f);
            }
            walk_stmt(body, f);
        }
        Stmt::While { cond, body } | Stmt::DoWhile { body, cond } => {
            walk_expr(cond, f);
            walk_stmt(body, f);
        }
        Stmt::Switch { value, body } => {
            walk_expr(value, f);
            walk_stmts(body, f);
        }
        Stmt::Case(e) => walk_expr(e, f),
        Stmt::Return(Some(e), _) => walk_expr(e, f),
        Stmt::Struct(def) => def.fields.iter().for_each(|d| walk_decl(d, f)),
        _ => {}
    }
}

/// Calls `f` on `e` and then on each sub-expression.
pub fn walk_expr(e: &Expr, f: &mut dyn FnMut(&Expr)) {
    f(e);
    match &e.kind {
        ExprKind::Paren(a) | ExprKind::Unary(_, a) | ExprKind::Postfix(_, a) | ExprKind::Member(a, _) => walk_expr(a, f),
        ExprKind::Binary(_, a, b) | ExprKind::Assign(_, a, b) | ExprKind::Index(a, b) => {
            walk_expr(a, f);
            walk_expr(b, f);
        }
        ExprKind::Cond(a, b, c) => {
            walk_expr(a, f);
            walk_expr(b, f);
            walk_expr(c, f);
        }
        ExprKind::Comma(list) | ExprKind::InitList(list) | ExprKind::Call(_, list) => list.iter().for_each(|x| walk_expr(x, f)),
        ExprKind::Method(base, _, args) => {
            walk_expr(base, f);
            args.iter().for_each(|x| walk_expr(x, f));
        }
        ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Opaque(_) => {}
    }
}

/// Calls `f` on every sub-expression of `e` (children first) and then on `e`, allowing each
/// node to be replaced.
pub fn rewrite_expr(e: &mut Expr, f: &mut dyn FnMut(&mut Expr)) {
    match &mut e.kind {
        ExprKind::Paren(a) | ExprKind::Unary(_, a) | ExprKind::Postfix(_, a) | ExprKind::Member(a, _) => rewrite_expr(a, f),
        ExprKind::Binary(_, a, b) | ExprKind::Assign(_, a, b) | ExprKind::Index(a, b) => {
            rewrite_expr(a, f);
            rewrite_expr(b, f);
        }
        ExprKind::Cond(a, b, c) => {
            rewrite_expr(a, f);
            rewrite_expr(b, f);
            rewrite_expr(c, f);
        }
        ExprKind::Comma(list) | ExprKind::InitList(list) | ExprKind::Call(_, list) => list.iter_mut().for_each(|x| rewrite_expr(x, f)),
        ExprKind::Method(base, _, args) => {
            rewrite_expr(base, f);
            args.iter_mut().for_each(|x| rewrite_expr(x, f));
        }
        ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Opaque(_) => {}
    }
    f(e);
}
