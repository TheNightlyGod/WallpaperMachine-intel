// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Calls: constructors, user functions and overloads (R58 to R65), the dialect vocabulary
//! (R9 to R19, R105, R106) and the shape rules of the built-ins (R28, R29, R40).

use std::collections::HashMap;

use crate::lexer::Operator;
use crate::request::StageKind;

use super::super::ast::*;
use super::super::builtins::{Class, class_of, is_dialect_call, unsupported_reason, we_refused_call};
use super::super::ty::*;
use super::expr::product_type;
use super::helpers::HelperKind;
use super::{Converter, T};

/// The outcome of looking for a user function for a call.
enum Pick {
    /// The function, and whether every argument matches without a change of shape.
    Chosen { index: usize, promotion_only: bool },
    /// Several functions fit equally well; the call is left to naga.
    Ambiguous(Ty),
    /// No function of that name and arity.
    None,
}

/// How a built-in argument position treats scalars (R28).
#[derive(Clone, Copy)]
struct Pos {
    scalar_ok: bool,
    group: u8,
}

const FULL: Pos = Pos { scalar_ok: false, group: 0 };
const fn lenient(group: u8) -> Pos {
    Pos { scalar_ok: true, group }
}

fn positions(class: Class, n: usize) -> Option<Vec<Pos>> {
    Some(match (class, n) {
        (Class::Unary | Class::UnaryInt, 1) => vec![FULL],
        (Class::Pair, 2) => vec![FULL, FULL],
        (Class::MinMax | Class::Mod, 2) => vec![FULL, lenient(0)],
        (Class::Step, 2) => vec![lenient(0), FULL],
        (Class::Smoothstep, 3) => vec![lenient(1), lenient(1), FULL],
        (Class::Clamp, 3) => vec![FULL, lenient(1), lenient(1)],
        (Class::Mix, 3) => vec![FULL, FULL, lenient(0)],
        _ => return None,
    })
}

/// Cost of passing a value of type `from` where `to` is expected (R60): 0 exact, 1 scalar
/// kind promotion, 2 and 3 for broadcast and truncation, 4 for a lossy scalar conversion.
fn arg_cost(from: &Ty, to: &Ty) -> Option<u8> {
    if from == to || from.is_unknown() || to.is_unknown() {
        return Some(0);
    }
    let scalar = |a: Sc, b: Sc| -> Option<u8> {
        if a == b {
            return Some(0);
        }
        Some(match (a, b) {
            (Sc::Int, Sc::Uint) | (Sc::Int | Sc::Uint, Sc::Float) | (Sc::Uint, Sc::Int) => 1,
            (Sc::Bool, _) => 1,
            (Sc::Float, Sc::Int | Sc::Uint) => 4,
            (_, Sc::Bool) => 4,
            _ => return None,
        })
    };
    match (from, to) {
        (Ty::Scalar(a), Ty::Scalar(b)) => scalar(*a, *b),
        (Ty::Scalar(a), Ty::Vec(b, _)) => scalar(*a, *b).map(|c| c + 2),
        (Ty::Vec(a, _), Ty::Scalar(b)) => scalar(*a, *b).map(|c| c + 3),
        (Ty::Vec(a, m), Ty::Vec(b, n)) if m >= n => {
            if a == b {
                Some(if m == n { 0 } else { 3 })
            } else {
                scalar(*a, *b).map(|c| c + if m == n { 1 } else { 3 })
            }
        }
        (Ty::Mat(c1, r1), Ty::Mat(c2, r2)) if c1 >= c2 && r1 >= r2 => Some(3),
        _ => None,
    }
}

impl Converter {
    pub(super) fn call(&mut self, callee: Callee, args: Vec<Expr>, span: Span) -> T {
        match callee {
            Callee::Type(tr) => self.ctor_call(tr, args, span),
            Callee::Cast(tr) => {
                if let Some(reason) = self.unsupported_type(&tr.name, false) {
                    self.error(&span, format!("unsupported construct `{}`: {reason}", tr.name));
                }
                let ty = self.resolve_type(&tr, &[]);
                let args = args.into_iter().map(|arg| self.expr(arg)).collect();
                self.typed_ctor(ty, args, &span)
            }
            Callee::Name(name) => self.named_call(name, args, span),
        }
    }

    // ----- constructors -----

    fn ctor_call(&mut self, mut tr: TypeRef, args: Vec<Expr>, span: Span) -> T {
        if let Some(reason) = self.unsupported_type(&tr.name, false) {
            self.error(&span, format!("unsupported construct `{}`: {reason}", tr.name));
        }
        let ty = self.resolve_type(&tr, &[]);
        let mut out = Vec::with_capacity(args.len());
        for a in args {
            let t = self.expr(a);
            out.push(t);
        }
        // WE's float-vector constructors consume exactly their component count.
        // Scalar broadcasts and vector truncation belong to casts, not constructors.
        // Generated GLSL and expressions synthesized by this converter retain GLSL's rules.
        if !self.options.glsl_builtins && let Ty::Vec(Sc::Float, width) = ty {
            let components: Option<usize> = out.iter().map(|arg| match &arg.ty {
                Ty::Scalar(_) => Some(1),
                Ty::Vec(_, width) => Some(usize::from(*width)),
                _ => None,
            }).sum();
            if let Some(components) = components && components != usize::from(width) {
                self.error(&span, format!("`{}` requires {width} numeric components, got {components}; use an explicit cast for broadcast or truncation", tr.name));
            }
        }
        let list = match &ty {
            Ty::Array(elem, _) => {
                let elem = (**elem).clone();
                out.into_iter().map(|t| self.coerce(t, &elem)).collect()
            }
            _ => self.constructor_args(&ty, out),
        };
        Self::emit_type_alias(&mut tr);
        T::new(Expr::new(ExprKind::Call(Callee::Type(tr), list), span), ty)
    }

    /// Arguments of a constructor of `ty`: a boolean scalar becomes a number of the
    /// constructed type's kind, because a boolean cannot be spread into a float vector.
    fn constructor_args(&mut self, ty: &Ty, args: Vec<T>) -> Vec<Expr> {
        // A scalar constructor converts a boolean itself.
        let kind = match ty {
            Ty::Vec(k, _) => Some(*k),
            Ty::Mat(..) => Some(Sc::Float),
            _ => None,
        };
        args.into_iter()
            .map(|t| match kind {
                Some(k) if k.is_numeric() && t.ty.is_bool_scalar() => self.convert_kind(t, k).e,
                _ => t.e,
            })
            .collect()
    }

    fn typed_ctor(&mut self, ty: Ty, args: Vec<T>, span: &Span) -> T {
        let list = self.constructor_args(&ty, args);
        let e = self.ctor_expr(&ty, list, span);
        T::new(e, ty)
    }

    // ----- named calls -----

    fn named_call(&mut self, name: String, args: Vec<Expr>, span: Span) -> T {
        if let Some(reason) = unsupported_reason(&name) {
            self.error(&span, format!("unsupported construct `{name}`: {reason}"));
            let args = args.into_iter().map(|a| self.expr(a).e).collect();
            return T::new(Expr::new(ExprKind::Call(Callee::Name(name), args), span), Ty::Unknown);
        }
        // A GLSL built-in Wallpaper Engine's HLSL does not have, unless the stage declares a
        // function of that name taking that many arguments (probes T6, T13).
        let declared = self.fn_by_name.get(&name).is_some_and(|list| list.iter().any(|i| self.fns[*i].params.len() == args.len()));
        let refused = if self.options.glsl_builtins { None } else { we_refused_call(&name, args.len()) };
        if !declared && let Some(reason) = refused.as_ref() {
            self.error(&span, format!("unsupported construct `{name}`: {reason}"));
            let args = args.into_iter().map(|a| self.expr(a).e).collect();
            return T::new(Expr::new(ExprKind::Call(Callee::Name(name), args), span), Ty::Unknown);
        }
        if let Some(&i) = self.struct_by_name.get(&name) {
            let args = args.into_iter().map(|a| self.expr(a).e).collect();
            let emit = self.structs[i].name.clone();
            return T::new(Expr::new(ExprKind::Call(Callee::Name(emit), args), span), Ty::Struct(i));
        }
        let targs: Vec<T> = args.into_iter().map(|a| self.expr(a)).collect();
        // A name absent from HLSL has no competing intrinsic overload. An author's
        // function still takes HLSL truncation/broadcast conversions at the call.
        let builtin = refused.is_none() && (is_dialect_call(&name) || class_of(&name).is_some());
        match self.pick_user(&name, &targs) {
            Pick::Chosen { index, promotion_only } if !builtin || promotion_only => self.user_call(index, targs, span),
            Pick::Chosen { .. } | Pick::None => {
                if builtin {
                    self.builtin_call(&name, targs, span)
                } else {
                    self.opaque_call(&name, targs, span)
                }
            }
            Pick::Ambiguous(ty) => {
                if builtin {
                    return self.builtin_call(&name, targs, span);
                }
                let emit = self.user_emit_name(&name);
                let args = targs.into_iter().map(|t| t.e).collect();
                T::new(Expr::new(ExprKind::Call(Callee::Name(emit), args), span), ty)
            }
        }
    }

    /// A call of a function this pass knows nothing about: left as written.
    fn opaque_call(&mut self, name: &str, targs: Vec<T>, span: Span) -> T {
        let emit = self.user_emit_name(name);
        // A user function of this name that fits no argument list: its result shape is still
        // known when every declaration of that name returns the same type.
        let ty = match self.fn_by_name.get(name) {
            Some(list) if !list.is_empty() => {
                let first = self.fns[list[0]].ret.clone();
                if list.iter().all(|i| self.fns[*i].ret == first) { first } else { Ty::Unknown }
            }
            _ => Ty::Unknown,
        };
        let args = targs.into_iter().map(|t| t.e).collect();
        T::new(Expr::new(ExprKind::Call(Callee::Name(emit), args), span), ty)
    }

    fn user_emit_name(&self, name: &str) -> String {
        match self.fn_by_name.get(name).and_then(|l| l.first()) {
            Some(i) => self.fns[*i].emit.clone(),
            None => name.to_string(),
        }
    }

    fn pick_user(&self, name: &str, targs: &[T]) -> Pick {
        let Some(list) = self.fn_by_name.get(name) else { return Pick::None };
        let cands: Vec<usize> = list.iter().copied().filter(|i| self.fns[*i].params.len() == targs.len()).collect();
        if cands.is_empty() {
            return Pick::None;
        }
        let any_unknown = targs.iter().any(|t| t.ty.is_unknown());
        let costs: Vec<Vec<Option<u8>>> = cands
            .iter()
            .map(|i| {
                self.fns[*i]
                    .params
                    .iter()
                    .zip(targs)
                    .map(|(p, a)| {
                        if p.dir != ParamDir::In {
                            // An argument bound to `out` or `inout` is an lvalue and is never converted.
                            return if a.ty == p.ty || a.ty.is_unknown() || p.ty.is_unknown() { Some(0) } else { None };
                        }
                        arg_cost(&a.ty, &p.ty)
                    })
                    .collect()
            })
            .collect();
        let promotion = |c: &Vec<Option<u8>>| !any_unknown && c.iter().all(|x| matches!(x, Some(v) if *v <= 1));
        if cands.len() == 1 {
            return Pick::Chosen { index: cands[0], promotion_only: promotion(&costs[0]) };
        }
        let valid: Vec<usize> = (0..cands.len()).filter(|k| costs[*k].iter().all(Option::is_some)).collect();
        let ret_of = |k: usize| self.fns[cands[k]].ret.clone();
        let common_ret = |ks: &[usize]| {
            let first = ret_of(ks[0]);
            if ks.iter().all(|k| ret_of(*k) == first) { first } else { Ty::Unknown }
        };
        if valid.is_empty() {
            return Pick::None;
        }
        let cost_vec = |k: usize| -> Vec<u8> { costs[k].iter().map(|c| c.unwrap()).collect() };
        let dominated = |a: usize, b: usize| {
            // `b` dominates `a`: no worse anywhere and better somewhere.
            let (ca, cb) = (cost_vec(a), cost_vec(b));
            ca.iter().zip(&cb).all(|(x, y)| y <= x) && ca.iter().zip(&cb).any(|(x, y)| y < x)
        };
        let best: Vec<usize> = valid.iter().copied().filter(|a| !valid.iter().any(|b| dominated(*a, *b))).collect();
        if best.len() == 1 {
            return Pick::Chosen { index: cands[best[0]], promotion_only: promotion(&costs[best[0]]) };
        }
        // Identical signatures declared twice (a prototype and its definition) are one function.
        let first = &self.fns[cands[best[0]]];
        if best.iter().all(|k| {
            let f = &self.fns[cands[*k]];
            f.ret == first.ret && f.params.iter().zip(&first.params).all(|(a, b)| a.ty == b.ty && a.dir == b.dir)
        }) {
            return Pick::Chosen { index: cands[best[0]], promotion_only: promotion(&costs[best[0]]) };
        }
        Pick::Ambiguous(common_ret(&best))
    }

    fn user_call(&mut self, index: usize, targs: Vec<T>, span: Span) -> T {
        if self.specials.contains_key(&index) {
            return self.specialise_call(index, targs, span);
        }
        let info = self.fns[index].clone();
        let mut args = Vec::with_capacity(targs.len());
        for (t, p) in targs.into_iter().zip(&info.params) {
            let convertible = p.dir == ParamDir::In && !matches!(p.ty, Ty::Array(..) | Ty::Struct(_) | Ty::Sampler(_));
            if p.dir != ParamDir::In {
                self.note_write_emitted(&t.e);
            }
            args.push(if convertible { self.coerce(t, &p.ty) } else { t.e });
        }
        T::new(Expr::new(ExprKind::Call(Callee::Name(info.emit), args), span), info.ret)
    }

    // ----- dialect vocabulary and built-ins -----

    fn builtin_call(&mut self, name: &str, mut targs: Vec<T>, span: Span) -> T {
        let n = targs.len();
        match (name, n) {
            ("CAST2", 1) => return self.typed_ctor(Ty::vec(2), targs, &span),
            ("CAST3", 1) => return self.typed_ctor(Ty::vec(3), targs, &span),
            ("CAST4", 1) => return self.typed_ctor(Ty::vec(4), targs, &span),
            ("CAST3X3", 1) => return self.typed_ctor(Ty::Mat(3, 3), targs, &span),
            ("CASTU", 1) => return self.typed_ctor(UINT, targs, &span),
            ("CASTF", 1) => return self.typed_ctor(FLOAT, targs, &span),
            ("CASTI", 1) => return self.typed_ctor(INT, targs, &span),
            ("CAST4U", 1) => return self.typed_ctor(Ty::Vec(Sc::Uint, 4), targs, &span),
            ("MAKE_SAMPLER2D_ARGUMENT", 1) => return targs.remove(0),
            ("mul", 2) => {
                let b = targs.pop().unwrap();
                let a = targs.pop().unwrap();
                return self.mul_call(a, b, span);
            }
            ("saturate", 1) => {
                let x = targs.pop().unwrap();
                let x = self.float_shape(x);
                let ty = x.ty.clone();
                let zero = Expr::number("0.0", span.clone());
                let one = Expr::number("1.0", span.clone());
                return T::new(Expr::call("clamp", vec![x.e, zero, one], span), ty);
            }
            ("frac", 1) => return self.shaped("fract", Class::Unary, targs, span),
            ("lerp", 3) => return self.shaped("mix", Class::Mix, targs, span),
            ("atan2", 2) => return self.shaped("atan", Class::Pair, targs, span),
            ("ddx", 1) => return self.shaped("dFdx", Class::Unary, targs, span),
            ("ddy", 1) => {
                // `ddy` keeps the author's orientation: the derivative of the negated value.
                let x = targs.pop().unwrap();
                let ty = self.float_shape_ty(&x.ty);
                let neg = Expr::new(ExprKind::Unary(Operator::Sub, Box::new(x.e.paren())), span.clone());
                return T::new(Expr::call("dFdy", vec![neg], span), ty);
            }
            ("log10", 1) => {
                let x = targs.pop().unwrap();
                let x = self.float_shape(x);
                let ty = x.ty.clone();
                let log2 = Expr::call("log2", vec![x.e], span.clone());
                let k = Expr::number("0.301029995663981", span.clone());
                return T::new(Expr::binary(Operator::Mul, log2, k).paren(), ty);
            }
            ("fmod", 2) => {
                let (mut a, mut b) = {
                    let b = targs.pop().unwrap();
                    (targs.pop().unwrap(), b)
                };
                if a.ty.kind().is_some() && b.ty.kind().is_some() {
                    let (shaped, _) = self.shape_args(Class::Pair, vec![a, b]);
                    let mut it = shaped.into_iter();
                    a = it.next().unwrap();
                    b = it.next().unwrap();
                } else {
                    // Without both types the operands stay as written.
                }
                return self.binary_typed(Operator::Mod, a, b, span);
            }
            ("clip", 1) if self.kind == StageKind::Fragment => return self.clip_call(targs.pop().unwrap(), span),
            // HLSL spellings (probe T13 compiles `rsqrt`, `asuint` and `countbits`).
            // Keep their component types and vector widths: unsigned bit scans return
            // 0xffffffff for a zero input, not the signed -1 of GLSL's findMSB/findLSB.
            ("rsqrt", 1) => return self.shaped("inversesqrt", Class::Unary, targs, span),
            ("countbits" | "firstbithigh" | "firstbitlow", 1) => {
                let x = targs.pop().unwrap();
                let kind = if name == "countbits" { Some(Sc::Uint) } else { x.ty.kind() };
                let ty = match (kind, x.ty.width()) {
                    (Some(k @ (Sc::Int | Sc::Uint)), Some(w)) => Ty::of(k, w),
                    _ => Ty::Unknown,
                };
                let function = match name { "countbits" => "bitCount", "firstbithigh" => "findMSB", _ => "findLSB" };
                let call = Expr::call(function, vec![x.e], span.clone());
                let call = if ty.kind() == Some(Sc::Uint) { self.ctor_expr(&ty, vec![call], &span) } else { call };
                return T::new(call, ty);
            }
            ("asuint" | "asint", 1) => {
                let (to, from_float) = if name == "asuint" { (Sc::Uint, "floatBitsToUint") } else { (Sc::Int, "floatBitsToInt") };
                let x = targs.pop().unwrap();
                return match x.ty.kind() {
                    Some(k) if k == to => x,
                    // Between `int` and `uint` a conversion keeps the bits.
                    Some(Sc::Int | Sc::Uint) => self.convert_kind(x, to),
                    _ => Self::bit_cast_call(from_float, x, to, span),
                };
            }
            ("asfloat", 1) => {
                let x = targs.pop().unwrap();
                return match x.ty.kind() {
                    Some(Sc::Float) => x,
                    Some(Sc::Int) => Self::bit_cast_call("intBitsToFloat", x, Sc::Float, span),
                    Some(Sc::Uint) => Self::bit_cast_call("uintBitsToFloat", x, Sc::Float, span),
                    _ => {
                        let bits = Expr::call("uint", vec![x.e], span.clone());
                        T::new(Expr::call("uintBitsToFloat", vec![bits], span), Ty::Unknown)
                    }
                };
            }
            ("modf", 2) => return self.modf_call(targs, span),
            ("texSample2D", 2) => return self.texture_call("texture", targs, span),
            ("tex2D" | "texture2D", 2 | 3) => return self.texture_call("texture", targs, span),
            ("texSample2DLod" | "texture2DLod" | "tex2DLod", 3) => return self.texture_call("textureLod", targs, span),
            ("texSample3D", 2) => return self.texture_call("texture", targs, span),
            // E-D8: `s.SampleCmpLevelZero(s ## SamplerComparisonState, u, d)`.
            ("texSample2DCompare", 3) => return self.compare_call(targs, span),
            // E-D8: `s.Load(int3((u) * (r), 0))`.
            ("texLoad2D", 3) => return self.texel_fetch_call(targs, span),
            // E-D8: sample 0 at `int2((u) * (r))` of the multisampled back buffer, else an
            // ordinary sample at `u`.
            ("texSample2DBackBuffer", 3) => {
                if self.options.backbuffer_ms {
                    return self.texel_fetch_call(targs, span);
                }
                targs.pop();
                return self.texture_call("texture", targs, span);
            }
            ("MAKE_SAMPLER2D_COMPARE_ARGUMENT", 1) => return targs.remove(0),
            _ => {}
        }
        let Some(class) = class_of(name) else {
            // A dialect name used with another arity: left for naga to refuse.
            let args = targs.into_iter().map(|t| t.e).collect();
            return T::new(Expr::new(ExprKind::Call(Callee::Name(name.to_string()), args), span), Ty::Unknown);
        };
        match class {
            Class::Unary | Class::UnaryInt | Class::Pair | Class::MinMax | Class::Mod | Class::Step | Class::Smoothstep | Class::Clamp | Class::Mix => {
                let class = if name == "atan" && n == 1 { Class::Unary } else { class };
                self.shaped(name, class, targs, span)
            }
            Class::ScalarResult => {
                let args = targs.into_iter().map(|t| t.e).collect();
                T::new(Expr::call(name, args, span), FLOAT)
            }
            Class::Cross => {
                let args = targs.into_iter().map(|t| t.e).collect();
                T::new(Expr::call(name, args, span), Ty::vec(3))
            }
            Class::Matrix => Self::matrix_call(name, targs, span),
            Class::Reduce => {
                let ty = match (name, targs.first().and_then(|t| t.ty.vec_width())) {
                    ("isnan" | "isinf", Some(w)) => Ty::Vec(Sc::Bool, w),
                    _ => BOOL,
                };
                let args = targs.into_iter().map(|t| t.e).collect();
                T::new(Expr::call(name, args, span), ty)
            }
            Class::Texture => self.texture_call(name, targs, span),
            Class::Other => {
                let ty = match name {
                    "refract" | "faceforward" => targs.first().map_or(Ty::Unknown, |t| t.ty.clone()),
                    _ => Ty::Unknown,
                };
                let args = targs.into_iter().map(|t| t.e).collect();
                T::new(Expr::call(name, args, span), ty)
            }
        }
    }

    /// HLSL modf: truncate each component and return the remainder. The output
    /// determines the overload: scalar inputs broadcast, vector inputs cannot
    /// narrow into an output. Out conversions keep a separate float whole value.
    fn modf_call(&mut self, mut args: Vec<T>, span: Span) -> T {
        let output = args.pop().expect("two arguments");
        let input = args.pop().expect("two arguments");
        let (columns, rows, kind, value_ty) = match &output.ty {
            Ty::Scalar(k) => (0, 1, *k, FLOAT),
            Ty::Vec(k, w) => (0, *w, *k, Ty::vec(*w)),
            Ty::Mat(c, r) => (*c, *r, Sc::Float, Ty::Mat(*c, *r)),
            _ => {
                self.error(&span, "modf requires a scalar, vector or matrix output argument");
                return T::new(Expr::call("modf", vec![input.e, output.e], span), Ty::Unknown);
            }
        };
        let fits = input.ty.is_scalar() || input.ty.is_unknown() ||
            input.ty.with_kind(Sc::Float) == value_ty;
        if !fits {
            self.error(&span, "modf input and output shapes do not match");
        }
        let mut input = self.coerce(input, &value_ty);
        let mut output = output.e;
        let mut before = Vec::new();
        if self.has_dynamic_output_index(&output) {
            // Naga evaluates an out-argument's index for both its temporary and
            // its write-back. Capture it once, after the input argument, as WE does.
            let value = self.call_temporary(&value_ty, &span);
            before.push(Self::call_assignment(value.clone(), input, &span));
            input = value;
            self.capture_output_indices(&mut output, &mut before);
        }
        self.helpers.need(HelperKind::Modf(columns, rows, kind));
        let name = format!("{}modf_{columns}_{rows}_{}", self.prefix, kind.name());
        let call = Expr::call(&name, vec![input, output], span.clone());
        let expr = if before.is_empty() { call } else {
            before.push(call);
            Expr::new(ExprKind::Comma(before), span)
        };
        T::new(expr, value_ty)
    }

    fn has_dynamic_output_index(&self, expr: &Expr) -> bool {
        match &expr.kind {
            ExprKind::Index(base, index) => self.eval_const_int(index).is_none() || self.has_dynamic_output_index(base),
            ExprKind::Member(base, _) | ExprKind::Paren(base) => self.has_dynamic_output_index(base),
            _ => false,
        }
    }

    fn call_assignment(target: Expr, value: Expr, span: &Span) -> Expr {
        Expr::new(ExprKind::Assign(Operator::Assign, Box::new(target), Box::new(value)), span.clone())
    }

    fn call_temporary(&mut self, ty: &Ty, span: &Span) -> Expr {
        let name = format!("{}call_{}", self.prefix, self.next_id);
        let emitted = self.declare(&name, ty.clone(), super::VarKind::Local, false, None);
        let decl = VarDecl {
            quals: Vec::new(),
            ty: TypeRef::named(&ty.glsl_name().expect("a numeric call temporary")),
            declarators: vec![Declarator { name: emitted.clone(), name_span: span.clone(), dims: Vec::new(), init: None }],
            span: span.clone(),
        };
        if self.cur_ret.is_some() { self.call_temps.push(decl); }
        else { self.relocated.push(Stmt::Decl(decl)); }
        Expr::ident(&emitted, span.clone())
    }

    fn capture_output_indices(&mut self, expr: &mut Expr, before: &mut Vec<Expr>) {
        match &mut expr.kind {
            ExprKind::Index(base, index) => {
                self.capture_output_indices(base, before);
                if self.eval_const_int(index).is_none() {
                    let value = self.call_temporary(&INT, &index.span);
                    before.push(Self::call_assignment(value.clone(), (**index).clone(), &index.span));
                    **index = value;
                }
            }
            ExprKind::Member(base, _) | ExprKind::Paren(base) => self.capture_output_indices(base, before),
            _ => {}
        }
    }

    /// A bit reinterpretation preserves the scalar/vector shape of its argument.
    fn bit_cast_call(name: &str, arg: T, kind: Sc, span: Span) -> T {
        let ty = arg.ty.width().map_or(Ty::Unknown, |width| Ty::of(kind, width));
        T::new(Expr::call(name, vec![arg.e], span), ty)
    }

    fn float_shape_ty(&self, ty: &Ty) -> Ty {
        match ty {
            Ty::Scalar(_) | Ty::Vec(..) => ty.with_kind(Sc::Float),
            other => other.clone(),
        }
    }

    /// The value as a float of the same shape (an `int` argument of a float function, R13).
    fn float_shape(&mut self, t: T) -> T {
        if t.ty.kind().is_some() { self.convert_kind(t, Sc::Float) } else { t }
    }

    /// `mul(a, b)` is `(b) * (a)`; two vectors of one width give the dot product (R12).
    fn mul_call(&mut self, a: T, b: T, span: Span) -> T {
        if let (Ty::Vec(Sc::Float, n), Ty::Vec(Sc::Float, m)) = (&a.ty, &b.ty)
            && n == m {
                return T::new(Expr::call("dot", vec![a.e, b.e], span), FLOAT);
            }
        let blocked = |t: &Ty| t.is_unknown() || t.is_aggregate_blocker();
        if blocked(&a.ty) || blocked(&b.ty) || (a.ty.is_vector() && b.ty.is_vector()) {
            let e = Expr::binary(Operator::Mul, b.e, a.e);
            return T::new(Expr::new(e.kind, span), Ty::Unknown);
        }
        if a.ty.is_matrix() || b.ty.is_matrix() {
            let ty = product_type(&b.ty, &a.ty);
            let e = Expr::binary(Operator::Mul, b.e, a.e);
            return T::new(Expr::new(e.kind, span), ty);
        }
        self.binary_typed(Operator::Mul, b, a, span)
    }

    /// A component-wise call of a built-in, with the arguments brought to one shape.
    fn shaped(&mut self, emit: &str, class: Class, targs: Vec<T>, span: Span) -> T {
        let (args, ty) = self.shape_args(class, targs);
        T::new(Expr::call(emit, args.into_iter().map(|t| t.e).collect(), span), ty)
    }

    /// The shape rules of R28 and the literal rule of R40.
    fn shape_args(&mut self, class: Class, targs: Vec<T>) -> (Vec<T>, Ty) {
        let n = targs.len();
        let Some(pos) = positions(class, n) else { return (targs, Ty::Unknown) };
        let ints_ok = matches!(class, Class::UnaryInt | Class::MinMax | Class::Clamp);
        let mut args = targs;
        let all_typed = args.iter().all(|t| t.ty.kind().is_some());
        if !all_typed {
            // Without every type the shape cannot be decided; literals still take the float
            // type of a float-only function (R40).
            if !ints_ok {
                for t in args.iter_mut() {
                    if matches!(t.ty, Ty::Scalar(Sc::Int | Sc::Uint)) {
                        let taken = std::mem::replace(t, T::new(Expr::number("0", 0..0), INT));
                        *t = if matches!(taken.e.kind, ExprKind::Number(_)) { self.convert_kind(taken, Sc::Float) } else { taken };
                    }
                }
            }
            return (args, Ty::Unknown);
        }
        for t in args.iter_mut() {
            if t.ty.is_bool_scalar() {
                let taken = std::mem::replace(t, T::new(Expr::number("0", 0..0), INT));
                *t = self.convert_kind(taken, Sc::Float);
            }
        }
        let any_float = args.iter().any(|t| t.ty.kind() == Some(Sc::Float));
        let any_uint = args.iter().any(|t| t.ty.kind() == Some(Sc::Uint));
        let kind = if !ints_ok || any_float {
            Sc::Float
        } else if any_uint {
            Sc::Uint
        } else {
            Sc::Int
        };
        let mut args: Vec<T> = args.into_iter().map(|t| self.convert_kind(t, kind)).collect();
        let width = args.iter().filter_map(|t| t.ty.vec_width()).min();
        if let Some(w) = width {
            for t in args.iter_mut() {
                if t.ty.vec_width().is_some_and(|m| m > w) {
                    let taken = std::mem::replace(t, T::new(Expr::number("0", 0..0), INT));
                    *t = self.narrow_to(taken, w);
                }
            }
            let mut group_has_vec: HashMap<u8, bool> = HashMap::new();
            for (t, p) in args.iter().zip(&pos) {
                if t.ty.is_vector() {
                    group_has_vec.insert(p.group, true);
                }
            }
            for (t, p) in args.iter_mut().zip(&pos) {
                let needs = t.ty.is_scalar() && (!p.scalar_ok || (p.group != 0 && group_has_vec.contains_key(&p.group)));
                if needs {
                    let taken = std::mem::replace(t, T::new(Expr::number("0", 0..0), INT));
                    *t = self.broadcast(taken, w);
                }
            }
        }
        (args, Ty::of(kind, width.unwrap_or(1)))
    }

    fn clip_call(&mut self, x: T, span: Span) -> T {
        let x = if x.ty.kind().is_some() { self.convert_kind(x, Sc::Float) } else { x };
        match x.ty.width() {
            Some(w) => self.helpers.need(HelperKind::Clip(w)),
            None => {
                for w in 1..=4 {
                    self.helpers.need(HelperKind::Clip(w));
                }
            }
        }
        let name = format!("{}clip", self.prefix);
        T::new(Expr::call(&name, vec![x.e], span), Ty::Void)
    }

    fn matrix_call(name: &str, targs: Vec<T>, span: Span) -> T {
        let first = targs.first().map(|t| t.ty.clone()).unwrap_or(Ty::Unknown);
        let ty = match (name, first) {
            ("transpose", Ty::Mat(c, r)) => Ty::Mat(r, c),
            ("determinant", _) => FLOAT,
            _ => Ty::Unknown,
        };
        T::new(Expr::call(name, targs.into_iter().map(|t| t.e).collect(), span), ty)
    }

    /// The sampler argument of a call, with any parentheses an alias spelled it with removed.
    fn sampler_arg(t: T) -> Expr {
        if t.ty.is_sampler() { t.e.into_peeled() } else { t.e }
    }

    /// `texelFetch(s, ivec2(u * r), 0)`: the texel under a coordinate given in `[0, 1]` times a
    /// resolution, truncated as HLSL's `int3((u) * (r), 0)` is (E-D8).
    fn texel_fetch_call(&mut self, mut targs: Vec<T>, span: Span) -> T {
        let r = targs.pop().expect("three arguments");
        let uv = targs.pop().expect("three arguments");
        let s = Self::sampler_arg(targs.pop().expect("three arguments"));
        let uv = self.coordinate(uv, 2).paren();
        let r = self.coordinate(r, 2).paren();
        let at = Expr::ctor("ivec2", vec![Expr::binary(Operator::Mul, uv, r)], span.clone());
        T::new(Expr::call("texelFetch", vec![s, at, Expr::number("0", span.clone())], span), Ty::vec(4))
    }

    /// `textureLod(s, vec3(u, d), 0.0)`: a level-0 comparison of a depth texture, as
    /// `SampleCmpLevelZero` is (E-D8). The result is the comparison's float.
    fn compare_call(&mut self, mut targs: Vec<T>, span: Span) -> T {
        let d = targs.pop().expect("three arguments");
        let uv = targs.pop().expect("three arguments");
        let s = Self::sampler_arg(targs.pop().expect("three arguments"));
        let uv = self.coordinate(uv, 2);
        let d = self.coerce(d, &FLOAT);
        let at = Expr::ctor("vec3", vec![uv, d], span.clone());
        T::new(Expr::call("textureLod", vec![s, at, Expr::number("0.0", span.clone())], span), FLOAT)
    }

    /// Sampling calls (R19, R34, R84, R105): the coordinate keeps its leading components.
    fn texture_call(&mut self, emit: &str, mut targs: Vec<T>, span: Span) -> T {
        // A parenthesised sampler (`(g_Texture4)`, as a macro alias may spell it) is the sampler.
        if let Some(first) = targs.first_mut()
            && first.ty.is_sampler() {
                let e = std::mem::replace(&mut first.e, Expr::number("0", 0..0));
                first.e = e.into_peeled();
            }
        let kind = match targs.first().map(|t| &t.ty) {
            Some(Ty::Sampler(k)) => Some(*k),
            _ => None,
        };
        let dims = match kind {
            Some(SamplerKind::D2) | Some(SamplerKind::Shadow) | Some(SamplerKind::D2Ms) | None => 2,
            Some(_) => 3,
        };
        let mut out: Vec<Expr> = Vec::with_capacity(targs.len());
        let mut ty = Ty::vec(4);
        let n = targs.len();
        for (i, t) in targs.into_iter().enumerate() {
            let e = match (emit, i) {
                ("texture" | "textureLod" | "textureGrad" | "textureOffset" | "textureProj" | "textureGather", 1) => {
                    if kind == Some(SamplerKind::D3) && t.ty.width().is_some_and(|w| w < 3) {
                        self.error(&span, "a `sampler3D` is sampled with a 3-component coordinate");
                    }
                    self.coordinate(t, dims)
                }
                ("textureLod", 2) | ("texture", 2) if n >= 3 => self.coerce(t, &FLOAT),
                _ => t.e,
            };
            out.push(e);
        }
        match emit {
            "textureSize" => ty = if kind == Some(SamplerKind::D3) || kind == Some(SamplerKind::D2Array) { Ty::Vec(Sc::Int, 3) } else { Ty::Vec(Sc::Int, 2) },
            "textureQueryLod" => ty = Ty::vec(2),
            "textureQueryLevels" => ty = INT,
            _ => {}
        }
        T::new(Expr::call(emit, out, span), ty)
    }

    /// A sampling coordinate: a vector wider than the sampler needs keeps its leading
    /// components. Nothing else is changed (HLSL cannot widen a coordinate).
    fn coordinate(&mut self, t: T, dims: u8) -> Expr {
        match &t.ty {
            Ty::Vec(_, m) if *m > dims => self.narrow_to(t, dims).e,
            _ => t.e,
        }
    }
}
