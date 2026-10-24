// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Use facts of a named variable (R7): how much of it a stage touches. The interface part uses
//! them to reconcile a varying declared with different widths in the two stages.

use super::ast::*;
use super::ty::builtin_type;

/// What the stage does with one variable, outside its declaration.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UseFacts {
    /// The largest component index any swizzle on the variable needs: `x` is 1 and `w` is 4. A
    /// swizzle whose letters come from no one set counts as the whole declared width.
    pub max_component: u8,
    /// The variable is assigned as a whole (`name = ...`).
    pub assigned_whole: bool,
    /// The variable is read as a whole, or used in a way that cannot be narrowed.
    pub read_whole: bool,
}

/// The number of components a swizzle needs, from the letters of one set.
fn swizzle_need(field: &str, declared_width: u8) -> u8 {
    for set in ["xyzw", "rgba", "stpq"] {
        if field.chars().all(|c| set.contains(c)) && !field.is_empty() {
            return field.chars().filter_map(|c| set.find(c)).max().map_or(0, |i| i as u8 + 1);
        }
    }
    declared_width
}

/// The declared width of a global variable named `name` (1 for a scalar, 0 when unknown).
fn declared_width(module: &Module, name: &str) -> u8 {
    for item in &module.items {
        if let Item::Var(d) = item
            && d.declarators.iter().any(|x| x.name == name) {
                return builtin_type(&d.ty.name).and_then(|t| t.width()).unwrap_or(0);
            }
    }
    0
}

fn go(e: &Expr, name: &str, width: u8, facts: &mut UseFacts) {
    match &e.kind {
        ExprKind::Ident(n) if n == name => facts.read_whole = true,
        ExprKind::Member(base, field) => {
            if matches!(&base.kind, ExprKind::Ident(n) if n == name) {
                facts.max_component = facts.max_component.max(swizzle_need(field, width));
            } else {
                go(base, name, width, facts);
            }
        }
        ExprKind::Assign(op, l, r) => {
            let whole = matches!(&l.peel().kind, ExprKind::Ident(n) if n == name);
            if whole && *op == crate::lexer::Operator::Assign {
                facts.assigned_whole = true;
            } else {
                go(l, name, width, facts);
            }
            go(r, name, width, facts);
        }
        ExprKind::Paren(a) | ExprKind::Unary(_, a) | ExprKind::Postfix(_, a) => go(a, name, width, facts),
        ExprKind::Binary(_, a, b) | ExprKind::Index(a, b) => {
            go(a, name, width, facts);
            go(b, name, width, facts);
        }
        ExprKind::Cond(a, b, c) => {
            go(a, name, width, facts);
            go(b, name, width, facts);
            go(c, name, width, facts);
        }
        ExprKind::Comma(list) | ExprKind::InitList(list) | ExprKind::Call(_, list) => {
            list.iter().for_each(|x| go(x, name, width, facts))
        }
        ExprKind::Method(base, _, args) => {
            go(base, name, width, facts);
            args.iter().for_each(|x| go(x, name, width, facts));
        }
        ExprKind::Number(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Opaque(_) => {}
    }
}

/// The use facts of `name` over a whole parsed stage.
pub fn use_facts(module: &Module, name: &str) -> UseFacts {
    let width = declared_width(module, name);
    let mut facts = UseFacts::default();
    // Top-level expression roots only: `go` recurses itself.
    let mut roots: Vec<&Expr> = Vec::new();
    fn collect_stmt<'a>(s: &'a Stmt, roots: &mut Vec<&'a Expr>) {
        match s {
            Stmt::Block(list) | Stmt::Seq(list) => list.iter().for_each(|s| collect_stmt(s, roots)),
            Stmt::Decl(d) => collect_decl(d, roots),
            Stmt::Expr(e) | Stmt::Case(e) => roots.push(e),
            Stmt::If { cond, then, otherwise } => {
                roots.push(cond);
                collect_stmt(then, roots);
                if let Some(o) = otherwise {
                    collect_stmt(o, roots);
                }
            }
            Stmt::For { init, cond, step, body } => {
                if let Some(i) = init {
                    collect_stmt(i, roots);
                }
                roots.extend(cond.iter());
                roots.extend(step.iter());
                collect_stmt(body, roots);
            }
            Stmt::While { cond, body } | Stmt::DoWhile { body, cond } => {
                roots.push(cond);
                collect_stmt(body, roots);
            }
            Stmt::Switch { value, body } => {
                roots.push(value);
                body.iter().for_each(|s| collect_stmt(s, roots));
            }
            Stmt::Return(Some(e), _) => roots.push(e),
            _ => {}
        }
    }
    fn collect_decl<'a>(d: &'a VarDecl, roots: &mut Vec<&'a Expr>) {
        for x in &d.declarators {
            roots.extend(x.dims.iter().flatten());
            roots.extend(x.init.iter());
        }
    }
    for item in &module.items {
        match item {
            Item::Var(d) => collect_decl(d, &mut roots),
            Item::Function(f) => {
                if let Some(body) = &f.body {
                    body.iter().for_each(|s| collect_stmt(s, &mut roots));
                }
            }
            _ => {}
        }
    }
    for e in roots {
        go(e, name, width, &mut facts);
    }
    facts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dialect::parse_stage;
    use crate::request::StageKind;

    fn facts(src: &str, name: &str) -> UseFacts {
        let (m, _) = parse_stage(StageKind::Fragment, src).unwrap();
        use_facts(&m, name)
    }

    #[test]
    fn swizzle_widths_come_from_all_three_letter_sets() {
        assert_eq!(facts("varying vec4 v; void main() { float a = v.x; }", "v").max_component, 1);
        assert_eq!(facts("varying vec4 v; void main() { vec2 a = v.xy; vec3 b = v.rgb; }", "v").max_component, 3);
        assert_eq!(facts("varying vec4 v; void main() { vec2 a = v.st; float c = v.q; }", "v").max_component, 4);
        assert_eq!(facts("varying vec4 v; void main() { vec2 a = v.yz; }", "v").max_component, 3);
        // letters from no set count as the declared width
        assert_eq!(facts("varying vec3 v; void main() { vec2 a = v.xg; }", "v").max_component, 3);
        assert_eq!(facts("varying vec3 v; void main() { float a = v.x; }", "v"), UseFacts { max_component: 1, assigned_whole: false, read_whole: false });
    }

    #[test]
    fn whole_assignment_and_whole_reads_are_told_apart() {
        let f = facts("vec4 v; void main() { v = vec4(1.0); }", "v");
        assert!(f.assigned_whole && !f.read_whole);
        let f = facts("vec4 v; void main() { vec4 a = v; }", "v");
        assert!(!f.assigned_whole && f.read_whole);
        let f = facts("vec4 v; void main() { v += vec4(1.0); }", "v");
        assert!(f.read_whole);
        let f = facts("vec4 v; void main() { g(v); }", "v");
        assert!(f.read_whole);
        let f = facts("vec4 v; void main() { v.xy = vec2(1.0); }", "v");
        assert!(!f.assigned_whole && !f.read_whole && f.max_component == 2);
    }

    #[test]
    fn comments_and_the_declaration_never_count() {
        let f = facts("varying vec4 v; // v.w and v = 1\nvoid main() { /* v */ float a = v.y; }", "v");
        assert_eq!(f, UseFacts { max_component: 2, assigned_whole: false, read_whole: false });
        let f = facts("varying vec4 v; void main() { }", "v");
        assert_eq!(f, UseFacts::default());
    }
}
