// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Writes a [`Module`] as GLSL text.
//!
//! Output is deterministic (R95): two-space indentation, one statement per line, and
//! parentheses decided from operator precedence so a rewritten tree is always printed with
//! the grouping it has, whatever shape the rewrite gave it.

use crate::lexer::Operator;

use super::ast::*;

/// Binding strength of an expression when printed; larger binds tighter.
fn prec_of(e: &Expr) -> u8 {
    match &e.kind {
        ExprKind::Comma(_) => 1,
        ExprKind::Assign(..) => 2,
        ExprKind::Cond(..) => 3,
        ExprKind::Binary(op, ..) => binary_prec(*op),
        ExprKind::Unary(..) => 15,
        ExprKind::Postfix(..) => 16,
        _ => 17,
    }
}

fn binary_prec(op: Operator) -> u8 {
    match op {
        Operator::OrOr => 4,
        Operator::XorXor => 5,
        Operator::AndAnd => 6,
        Operator::BitOr => 7,
        Operator::BitXor => 8,
        Operator::BitAnd => 9,
        Operator::Eq | Operator::Ne => 10,
        Operator::Lt | Operator::Gt | Operator::Le | Operator::Ge => 11,
        Operator::Shl | Operator::Shr => 12,
        Operator::Add | Operator::Sub => 13,
        _ => 14,
    }
}

pub fn expr_to_string(e: &Expr) -> String {
    let mut out = String::new();
    write_expr(&mut out, e, 0);
    out
}

fn write_expr(out: &mut String, e: &Expr, min: u8) {
    let own = prec_of(e);
    let wrap = own < min;
    if wrap {
        out.push('(');
    }
    match &e.kind {
        ExprKind::Number(t) | ExprKind::Opaque(t) => out.push_str(t),
        ExprKind::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        ExprKind::Ident(n) => out.push_str(n),
        ExprKind::Paren(inner) => {
            out.push('(');
            write_expr(out, inner, 0);
            out.push(')');
        }
        ExprKind::Unary(op, inner) => {
            out.push_str(op.text());
            let before = out.len();
            write_expr(out, inner, 15);
            // `- -x` and `+ +x` must not fuse into `--x` and `++x`.
            let first = out[before..].chars().next();
            let fuse = match op {
                Operator::Sub | Operator::Dec => first == Some('-'),
                Operator::Add | Operator::Inc => first == Some('+'),
                _ => false,
            };
            if fuse {
                out.insert(before, ' ');
            }
        }
        ExprKind::Postfix(op, inner) => {
            write_expr(out, inner, 16);
            out.push_str(op.text());
        }
        ExprKind::Binary(op, l, r) => {
            let p = binary_prec(*op);
            write_expr(out, l, p);
            out.push(' ');
            out.push_str(op.text());
            out.push(' ');
            write_expr(out, r, p + 1);
        }
        ExprKind::Assign(op, l, r) => {
            write_expr(out, l, 16);
            out.push(' ');
            out.push_str(op.text());
            out.push(' ');
            write_expr(out, r, 2);
        }
        ExprKind::Cond(c, a, b) => {
            write_expr(out, c, 4);
            out.push_str(" ? ");
            write_expr(out, a, 2);
            out.push_str(" : ");
            write_expr(out, b, 2);
        }
        ExprKind::Comma(list) => {
            for (i, x) in list.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_expr(out, x, 2);
            }
        }
        ExprKind::Call(callee, args) => {
            let cast = matches!(callee, Callee::Cast(_));
            if cast { out.push_str("(("); }
            match callee {
                Callee::Name(n) => out.push_str(n),
                Callee::Type(t) | Callee::Cast(t) => write_type(out, t),
            }
            if cast { out.push(')'); }
            out.push('(');
            write_list(out, args);
            out.push(')');
            if cast { out.push(')'); }
        }
        ExprKind::Index(base, idx) => {
            write_expr(out, base, 16);
            out.push('[');
            write_expr(out, idx, 0);
            out.push(']');
        }
        ExprKind::Member(base, field) => {
            write_expr(out, base, 16);
            out.push('.');
            out.push_str(field);
        }
        ExprKind::Method(base, name, args) => {
            write_expr(out, base, 16);
            out.push('.');
            out.push_str(name);
            out.push('(');
            write_list(out, args);
            out.push(')');
        }
        ExprKind::InitList(list) => {
            out.push('{');
            write_list(out, list);
            out.push('}');
        }
    }
    if wrap {
        out.push(')');
    }
}

fn write_list(out: &mut String, list: &[Expr]) {
    for (i, a) in list.iter().enumerate() {
        if i > 0 {
            out.push_str(", ");
        }
        write_expr(out, a, 2);
    }
}

fn write_type(out: &mut String, t: &TypeRef) {
    out.push_str(&t.name);
    for d in &t.dims {
        write_dim(out, d);
    }
}

fn write_dim(out: &mut String, d: &Option<Expr>) {
    out.push('[');
    if let Some(e) = d {
        write_expr(out, e, 0);
    }
    out.push(']');
}

fn write_quals(out: &mut String, quals: &[Qualifier]) {
    for q in quals {
        match q {
            Qualifier::Word(w) => out.push_str(w),
            Qualifier::Layout(inner) => {
                out.push_str("layout(");
                out.push_str(inner);
                out.push(')');
            }
        }
        out.push(' ');
    }
}

fn write_declarators(out: &mut String, list: &[Declarator]) {
    for (i, d) in list.iter().enumerate() {
        if i > 0 {
            out.push_str(", ");
        }
        out.push_str(&d.name);
        for dim in &d.dims {
            write_dim(out, dim);
        }
        if let Some(init) = &d.init {
            out.push_str(" = ");
            write_expr(out, init, 2);
        }
    }
}

fn write_var_decl(out: &mut String, d: &VarDecl) {
    write_quals(out, &d.quals);
    write_type(out, &d.ty);
    out.push(' ');
    write_declarators(out, &d.declarators);
    out.push(';');
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_struct(out: &mut String, s: &StructDef, depth: usize) {
    write_quals(out, &s.quals);
    out.push_str("struct");
    if let Some(n) = &s.name {
        out.push(' ');
        out.push_str(n);
    }
    out.push_str(" {\n");
    for f in &s.fields {
        indent(out, depth + 1);
        write_var_decl(out, f);
        out.push('\n');
    }
    indent(out, depth);
    out.push('}');
    if !s.declarators.is_empty() {
        out.push(' ');
        write_declarators(out, &s.declarators);
    }
    out.push(';');
}

fn write_stmts(out: &mut String, list: &[Stmt], depth: usize) {
    for s in list {
        write_stmt(out, s, depth);
    }
}

/// A statement controlled by `if`, `else` or a loop: a block stays a block, anything else
/// goes on its own indented line.
fn write_body(out: &mut String, s: &Stmt, depth: usize) {
    if let Stmt::Block(list) = s {
        out.push_str(" {\n");
        write_stmts(out, list, depth + 1);
        indent(out, depth);
        out.push('}');
    } else {
        out.push('\n');
        write_stmt_inline(out, s, depth + 1);
    }
}

/// Writes a statement on the current line position (the caller wrote the indentation).
fn write_stmt_inline(out: &mut String, s: &Stmt, depth: usize) {
    let mut tmp = String::new();
    write_stmt(&mut tmp, s, depth);
    // `write_stmt` ends with a newline; the caller handles line ends.
    out.push_str(tmp.trim_end_matches('\n'));
}

fn write_stmt(out: &mut String, s: &Stmt, depth: usize) {
    match s {
        Stmt::Directive(text) => {
            // Directives start in column zero; a raw carried statement is indented.
            if text.starts_with('#') {
                out.push_str(text);
            } else {
                indent(out, depth);
                out.push_str(text);
            }
            out.push('\n');
            return;
        }
        Stmt::Block(list) => {
            indent(out, depth);
            out.push_str("{\n");
            write_stmts(out, list, depth + 1);
            indent(out, depth);
            out.push_str("}\n");
            return;
        }
        Stmt::Seq(list) => {
            write_stmts(out, list, depth);
            return;
        }
        _ => {}
    }
    indent(out, depth);
    match s {
        Stmt::Decl(d) => write_var_decl(out, d),
        Stmt::Struct(def) => write_struct(out, def, depth),
        Stmt::Expr(e) => {
            write_expr(out, e, 0);
            out.push(';');
        }
        Stmt::If { cond, then, otherwise } => {
            out.push_str("if (");
            write_expr(out, cond, 0);
            out.push(')');
            write_body(out, then, depth);
            if let Some(o) = otherwise {
                if matches!(**then, Stmt::Block(_)) {
                    out.push_str(" else");
                } else {
                    out.push('\n');
                    indent(out, depth);
                    out.push_str("else");
                }
                if let Stmt::If { .. } = **o {
                    out.push(' ');
                    let mut tmp = String::new();
                    write_stmt(&mut tmp, o, depth);
                    out.push_str(tmp.trim_start().trim_end_matches('\n'));
                } else {
                    write_body(out, o, depth);
                }
            }
        }
        Stmt::For { init, cond, step, body } => {
            out.push_str("for (");
            match init.as_deref() {
                Some(Stmt::Decl(d)) => write_var_decl(out, d),
                Some(Stmt::Expr(e)) => {
                    write_expr(out, e, 0);
                    out.push(';');
                }
                _ => out.push(';'),
            }
            out.push(' ');
            if let Some(c) = cond {
                write_expr(out, c, 0);
            }
            out.push(';');
            if let Some(st) = step {
                out.push(' ');
                write_expr(out, st, 0);
            }
            out.push(')');
            write_body(out, body, depth);
        }
        Stmt::While { cond, body } => {
            out.push_str("while (");
            write_expr(out, cond, 0);
            out.push(')');
            write_body(out, body, depth);
        }
        Stmt::DoWhile { body, cond } => {
            out.push_str("do");
            write_body(out, body, depth);
            if matches!(**body, Stmt::Block(_)) {
                out.push(' ');
            } else {
                out.push('\n');
                indent(out, depth);
            }
            out.push_str("while (");
            write_expr(out, cond, 0);
            out.push_str(");");
        }
        Stmt::Switch { value, body } => {
            out.push_str("switch (");
            write_expr(out, value, 0);
            out.push_str(") {\n");
            write_stmts(out, body, depth + 1);
            indent(out, depth);
            out.push('}');
        }
        Stmt::Case(e) => {
            out.push_str("case ");
            write_expr(out, e, 0);
            out.push(':');
        }
        Stmt::Default => out.push_str("default:"),
        Stmt::Return(v, _) => {
            out.push_str("return");
            if let Some(e) = v {
                out.push(' ');
                write_expr(out, e, 0);
            }
            out.push(';');
        }
        Stmt::Break => out.push_str("break;"),
        Stmt::Continue => out.push_str("continue;"),
        Stmt::Discard => out.push_str("discard;"),
        Stmt::Empty => out.push(';'),
        Stmt::Directive(_) | Stmt::Block(_) | Stmt::Seq(_) => unreachable!(),
    }
    out.push('\n');
}

fn write_function(out: &mut String, f: &Function) {
    write_quals(out, &f.quals);
    write_type(out, &f.ret);
    out.push(' ');
    out.push_str(&f.name);
    out.push('(');
    for (i, p) in f.params.iter().enumerate() {
        if i > 0 {
            out.push_str(", ");
        }
        for q in &p.quals {
            out.push_str(q);
            out.push(' ');
        }
        write_type(out, &p.ty);
        if let Some(n) = &p.name {
            out.push(' ');
            out.push_str(n);
        }
        for d in &p.dims {
            write_dim(out, d);
        }
    }
    out.push(')');
    match &f.body {
        None => out.push_str(";\n"),
        Some(body) => {
            out.push_str(" {\n");
            write_stmts(out, body, 1);
            out.push_str("}\n");
        }
    }
}

pub fn write_item(out: &mut String, item: &Item) {
    match item {
        Item::Directive(t) | Item::Annotation(t) | Item::Raw(t) => {
            out.push_str(t);
            out.push('\n');
        }
        Item::Precision(t) => {
            out.push_str(t);
            out.push_str(";\n");
        }
        Item::Struct(s) => {
            write_struct(out, s, 0);
            out.push('\n');
        }
        Item::Var(d) => {
            write_var_decl(out, d);
            out.push('\n');
        }
        Item::Block(b) => {
            write_quals(out, &b.quals);
            out.push_str(&b.name);
            out.push_str(" {\n");
            for f in &b.fields {
                indent(out, 1);
                write_var_decl(out, f);
                out.push('\n');
            }
            out.push('}');
            if let Some(i) = &b.instance {
                out.push(' ');
                write_declarators(out, std::slice::from_ref(i));
            }
            out.push_str(";\n");
        }
        Item::Function(f) => write_function(out, f),
    }
}

/// The items of a module as text, without any header.
pub fn module_to_string(m: &Module) -> String {
    let mut out = String::new();
    for item in &m.items {
        write_item(&mut out, item);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dialect::expand::expand;
    use crate::dialect::parse::parse;
    use crate::lexer::lex;

    fn print(src: &str) -> String {
        let tokens = expand(&lex(src)).unwrap();
        module_to_string(&parse(&tokens).unwrap())
    }

    #[test]
    fn printing_is_stable_under_reparse() {
        let src = "uniform float g_X; // {\"a\":1}\nstruct S { vec2 v; float w[2]; } s;\nfloat f(float a, inout vec2 b) {\n  float r = a * (b.x + 1.0) - -2.0;\n  for (int i = 0; i < 3; i++) if (i > 1) r += float(i); else continue;\n  do { r--; } while (r > 0.0);\n  return r > 1.0 ? r : -r;\n}\nvoid main() { vec4 c = vec4(1.0), d[2]; c.xy = vec2(f(1.0, c.xy)); }\n";
        let once = print(src);
        let twice = print(&once);
        assert_eq!(once, twice);
    }

    #[test]
    fn parentheses_follow_the_tree_not_the_source() {
        let src = "void main() { a = (b + c) * d; e = b + (c * d); f = a - (b - c); g = -(-x); h = a ? b : c ? d : e; i = (a ? b : c) ? d : e; }";
        let out = print(src);
        assert!(out.contains("a = (b + c) * d;"), "{out}");
        assert!(out.contains("e = b + (c * d);"), "{out}");
        assert!(out.contains("f = a - (b - c);"), "{out}");
        assert!(out.contains("g = -(-x);"), "{out}");
        assert!(out.contains("i = (a ? b : c) ? d : e;"), "{out}");
    }

    #[test]
    fn a_synthesised_tree_gets_the_parentheses_it_needs() {
        use crate::dialect::ast::Expr;
        let sp = 0..0;
        let sum = Expr::binary(Operator::Add, Expr::ident("a", sp.clone()), Expr::ident("b", sp.clone()));
        let prod = Expr::binary(Operator::Mul, sum, Expr::ident("c", sp.clone()));
        assert_eq!(expr_to_string(&prod), "(a + b) * c");
        let neg = Expr::new(ExprKind::Unary(Operator::Sub, Box::new(Expr::new(ExprKind::Unary(Operator::Sub, Box::new(Expr::ident("x", sp.clone()))), sp.clone()))), sp.clone());
        assert_eq!(expr_to_string(&neg), "- -x");
        let sw = Expr::binary(Operator::Add, Expr::ident("a", sp.clone()), Expr::ident("b", sp.clone())).member("xy");
        assert_eq!(expr_to_string(&sw), "(a + b).xy");
    }

    #[test]
    fn literals_are_copied_digit_for_digit() {
        let out = print("void main() { float a = .5 + 5. + 1e-3 + 2.0f + 1.17549435e-38; uint u = 2u + 0u; }");
        for lit in [".5", "5.", "1e-3", "2.0f", "1.17549435e-38", "2u", "0u"] {
            assert!(out.contains(lit), "{lit} in {out}");
        }
    }
}
