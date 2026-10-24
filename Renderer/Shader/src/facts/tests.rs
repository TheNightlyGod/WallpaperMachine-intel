// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Behaviour tests for the token facts (spec section 8, items 40 to 45 and 63).

use super::*;
use crate::lexer::lex;

fn txt(tokens: &TokenStream, range: Range<usize>) -> String {
    tokens[range].iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join(" ")
}

fn decls(src: &str) -> Vec<(String, String, Option<String>, String)> {
    let s = lex(src);
    let f = Facts::analyze(&s);
    f.declarators()
        .iter()
        .map(|d| {
            (
                d.type_text.clone(),
                d.name.clone(),
                d.initializer.clone().map(|r| txt(&s, r)),
                txt(&s, d.range.clone()),
            )
        })
        .collect()
}

fn names(src: &str) -> Vec<String> {
    decls(src).into_iter().map(|d| d.1).collect()
}

#[test]
fn statements_end_at_semicolons_outside_parentheses_and_skip_annotations() {
    let s = lex("uniform float a; // {\"default\":1}\n#define X 1\nfor (int i = 0; i < 3; ++i) x += 1;\nvoid f() { return; }");
    let f = Facts::analyze(&s);
    let st: Vec<String> = f.statements().iter().map(|st| txt(&s, st.range.clone())).collect();
    assert_eq!(st, ["uniform float a ;", "for ( int i = 0 ; i < 3 ; ++ i ) x += 1 ;", "return ;"]);
    // The expression range leaves out the semicolon.
    assert_eq!(txt(&s, f.statements()[0].expression.clone()), "uniform float a");
}

#[test]
fn struct_member_lines_are_statements_and_yield_declarations() {
    assert_eq!(names("struct Lamp { vec4 tint; float reach; };"), ["tint", "reach"]);
    let d = decls("struct S { vec2 a, b[2]; } inst;");
    assert_eq!(d.iter().map(|d| d.1.as_str()).collect::<Vec<_>>(), ["a", "b"]);
}

#[test]
fn comma_declarators_split_at_top_level_only() {
    let d = decls("vec2 p = uv * 2.0, q, r = vec2(0.5, 1.0);");
    assert_eq!(d.len(), 3);
    assert_eq!((d[0].1.as_str(), d[0].2.as_deref()), ("p", Some("uv * 2.0")));
    assert_eq!((d[1].1.as_str(), d[1].2.as_deref()), ("q", None));
    assert_eq!((d[2].1.as_str(), d[2].2.as_deref()), ("r", Some("vec2 ( 0.5 , 1.0 )")));
    assert_eq!(d[0].3, "p = uv * 2.0 ,");
    assert_eq!(d[1].3, "q ,");
    assert_eq!(d[2].3, "r = vec2 ( 0.5 , 1.0 ) ;");
    for x in &d {
        assert_eq!(x.0, "vec2");
    }
}

#[test]
fn nested_calls_and_array_suffixes_stay_inside_their_declarator() {
    let d = decls("vec4 w[3], tint = mix(a, b, f(t, u)), last;");
    assert_eq!(d.iter().map(|d| d.1.as_str()).collect::<Vec<_>>(), ["w", "tint", "last"]);
    assert_eq!(d[0].3, "w [ 3 ] ,");
    assert_eq!(d[0].2, None);
    assert_eq!(d[1].2.as_deref(), Some("mix ( a , b , f ( t , u ) )"));
    let d = decls("float k[2] = float[2](1.0, 2.0), z = 1.0;");
    assert_eq!(d.len(), 2);
    assert_eq!(d[0].2.as_deref(), Some("float [ 2 ] ( 1.0 , 2.0 )"));
}

#[test]
fn modifiers_in_either_order_and_layout_groups_are_skipped() {
    let d = decls("highp const float lut[4], bias = 0.5;");
    assert_eq!(d.iter().map(|d| (d.0.as_str(), d.1.as_str())).collect::<Vec<_>>(), [("float", "lut"), ("float", "bias")]);
    assert_eq!(d[0].2, None);
    assert_eq!(names("const highp vec3 c = vec3(1.0);"), ["c"]);
    let d = decls("layout(binding=1) uniform sampler2D t;");
    assert_eq!((d[0].0.as_str(), d[0].1.as_str()), ("sampler2D", "t"));
    assert_eq!(names("layout(location = 3) varying highp vec2 v_Uv;"), ["v_Uv"]);
    assert_eq!(names("flat in uint id;"), ["id"]);
    assert_eq!(names("Ray r = Ray(o, d);"), ["r"]);
}

#[test]
fn calls_constructors_control_headers_and_prototypes_are_not_declarations() {
    for src in [
        "ivec2(3, 4);",
        "emit(p, q);",
        "switch (int(sel)) { }",
        "float f(float x);",
        "x = y;",
        "return a;",
        "discard;",
        "precision highp float;",
        "a.b = c;",
        "v[0] = 1.0;",
        "vec3 g(vec3 a);",
    ] {
        assert!(decls(src).is_empty(), "{src}: {:?}", decls(src));
    }
}

#[test]
fn for_header_declarations_are_found() {
    let d = decls("for (int i = 0, n = 4; i < n; ++i) { s += i; }");
    assert_eq!(d.iter().map(|d| (d.0.as_str(), d.1.as_str(), d.2.clone())).collect::<Vec<_>>(), [
        ("int", "i", Some("0".to_string())),
        ("int", "n", Some("4".to_string())),
    ]);
    assert!(decls("for (i = 0; i < 4; ++i) {}").is_empty());
    assert!(decls("for (; ; ) {}").is_empty());
}

#[test]
fn declarations_skip_annotations_and_directives_before_a_statement() {
    let src = "uniform float g_A; // {\"default\":1}\n#define K 2\nvec2 uv;";
    let s = lex(src);
    let f = Facts::analyze(&s);
    let d = f.declarators();
    assert_eq!(d.len(), 2);
    assert_eq!(d[1].name, "uv");
    // The statement of the second one starts at its type token, after the annotation and the directive.
    assert_eq!(s[d[1].statement.start].text, "vec2");
}

#[test]
fn declarators_are_retrievable_by_name_index_and_statement_start() {
    let s = lex("float a, b; vec3 c;");
    let f = Facts::analyze(&s);
    let b = s.iter().position(|t| t.text == "b").unwrap();
    assert_eq!(f.declarator_by_name(b).unwrap().name, "b");
    assert!(f.declarator_by_name(0).is_none());
    let first_stmt = f.statements()[0].range.start;
    assert_eq!(f.declarators_at_statement(first_stmt).len(), 2);
    assert_eq!(f.declarators_at_statement(f.statements()[1].range.start).len(), 1);
}

#[test]
fn invocation_spans_report_each_call_once_with_top_level_arguments() {
    let s = lex("y = f(g(a, b), h(), (c, d), 3);");
    let f = Facts::analyze(&s);
    let inv: Vec<(&str, Vec<String>)> = f
        .invocations()
        .iter()
        .map(|i| (i.name.as_str(), i.arguments.iter().map(|a| txt(&s, a.clone())).collect()))
        .collect();
    assert_eq!(
        inv,
        [
            ("f", vec!["g ( a , b )".into(), "h ( )".into(), "( c , d )".into(), "3".into()]),
            ("g", vec!["a".into(), "b".into()]),
            ("h", vec![]),
        ]
    );
    let f0 = &f.invocations()[0];
    assert_eq!(s[f0.name_index].text, "f");
    assert!(s[f0.open].is_left_paren() && s[f0.close].is_right_paren());
}

#[test]
fn keyword_and_type_calls_are_invocations() {
    let s = lex("if (a) { vec2(1.0, 2.0); } for (;;) {} while (x) {} switch (k) {}");
    let f = Facts::analyze(&s);
    let n: Vec<&str> = f.invocations().iter().map(|i| i.name.as_str()).collect();
    assert_eq!(n, ["if", "vec2", "for", "while", "switch"]);
    // Arguments split on commas only: `for (;;)` has one segment, and `h()` none.
    assert_eq!(f.invocations()[2].arguments.len(), 1);
    assert_eq!(txt(&s, f.invocations()[2].arguments[0].clone()), "; ;");
}

#[test]
fn signatures_for_definitions_and_prototypes() {
    let s = lex("vec3 shade(vec3 n, const in float k[LEN], Ray);\nvoid main() { }\nfloat g(void);\nvec4 f(Ray r, vec2) { return h(); }\nvoid k() { res = fold(res, w); y = f(1); }");
    let f = Facts::analyze(&s);
    let sig: Vec<(String, String, usize, bool)> =
        f.signatures().iter().map(|g| (g.name.clone(), g.return_type.clone(), g.parameters.len(), g.is_definition)).collect();
    assert_eq!(
        sig,
        [
            ("shade".into(), "vec3".into(), 3, false),
            ("main".into(), "void".into(), 0, true),
            ("g".into(), "float".into(), 0, false),
            ("f".into(), "vec4".into(), 2, true),
            ("k".into(), "void".into(), 0, true),
        ]
    );
}

#[test]
fn parameter_facts_cover_unnamed_struct_and_array_parameters() {
    let src = "vec4 f(Ray, vec3, in float w[LEN], vec2 k[4], float v[A + 1], out vec3 o);";
    let s = lex(src);
    let f = Facts::analyze(&s);
    let p = &f.signatures()[0].parameters;
    assert_eq!(p.len(), 6);
    assert_eq!((p[0].type_text.as_str(), p[0].name.as_deref()), ("Ray", None));
    assert_eq!((p[1].type_text.as_str(), p[1].name.as_deref()), ("vec3", None));
    assert_eq!((p[2].type_text.as_str(), p[2].name.as_deref(), p[2].simple_array_name.as_deref()), ("float", Some("w"), Some("w")));
    assert_eq!((p[3].type_text.as_str(), p[3].name.as_deref(), p[3].simple_array_name.as_deref()), ("vec2", Some("k"), Some("k")));
    assert_eq!((p[4].name.as_deref(), p[4].simple_array_name.as_deref()), (Some("v"), None));
    assert_eq!((p[5].type_text.as_str(), p[5].name.as_deref()), ("vec3", Some("o")));
    assert_eq!(&src[p[2].span.clone()], "in float w[LEN]");
    assert_eq!(&src[p[0].span.clone()], "Ray");
    assert_eq!(txt(&s, p[3].tokens.clone()), "vec2 k [ 4 ]");
}

#[test]
fn calls_and_returns_are_not_signatures() {
    let s = lex("void k() { return f(); }\nvoid m() { res = fold(res, w); emit(p, q); fold(a); }");
    let f = Facts::analyze(&s);
    let names: Vec<&str> = f.signatures().iter().map(|g| g.name.as_str()).collect();
    assert_eq!(names, ["k", "m"]);
}

#[test]
fn a_void_only_parameter_list_has_no_parameters() {
    let s = lex("void f(void) {}");
    let f = Facts::analyze(&s);
    assert!(f.signatures()[0].parameters.is_empty());
    let s = lex("void f(void x) {}");
    assert_eq!(Facts::analyze(&s).signatures()[0].parameters.len(), 1);
}

fn flow_kinds(f: &Facts<'_>) -> Vec<&'static str> {
    f.flow()
        .iter()
        .map(|n| match n {
            FlowNode::Simple { .. } => "simple",
            FlowNode::If { .. } => "if",
            FlowNode::For { .. } => "for",
            FlowNode::While { .. } => "while",
            FlowNode::DoWhile { .. } => "do",
        })
        .collect()
}

#[test]
fn a_for_with_empty_sections_has_only_a_step_and_a_body() {
    let s = lex("for (; ; ++n) n += 2;");
    let f = Facts::analyze(&s);
    let FlowNode::For { range, init, condition, step, body } = &f.flow()[0] else { panic!("{:?}", f.flow()) };
    assert_eq!(*range, 0..11);
    assert_eq!(*init, None);
    assert_eq!(*condition, None);
    assert_eq!(*step, Some(4..6));
    assert_eq!(*body, 7..11);
    assert_eq!(txt(&s, body.clone()), "n += 2 ;");
    assert!(f.branch_conditions().is_empty());
    assert_eq!(f.for_nodes().len(), 1);
}

#[test]
fn a_for_with_an_initializer_and_condition_but_no_step() {
    let s = lex("for (int j = 0; j < n;) { j += 2; }");
    let f = Facts::analyze(&s);
    let FlowNode::For { init, condition, step, body, .. } = &f.flow()[0] else { panic!() };
    assert_eq!(txt(&s, init.clone().unwrap()), "int j = 0");
    assert_eq!(txt(&s, condition.clone().unwrap()), "j < n");
    assert_eq!(*step, None);
    assert!(s[body.start].kind == TokenKind::LBrace);
    assert_eq!(f.branch_conditions().len(), 1);
}

#[test]
fn if_else_chains_nest_and_conditions_are_listed_in_order() {
    let s = lex("if (a) x = 1; else if (b) { y = 2; } else z = 3;");
    let f = Facts::analyze(&s);
    assert_eq!(flow_kinds(&f), ["if", "simple", "if", "simple", "simple", "simple"]);
    let FlowNode::If { range, condition, then_body, else_body } = &f.flow()[0] else { panic!() };
    assert_eq!(*range, 0..s.len());
    assert_eq!(txt(&s, condition.clone()), "a");
    assert_eq!(txt(&s, then_body.clone()), "x = 1 ;");
    let else_body = else_body.clone().unwrap();
    assert_eq!(s[else_body.start].text, "if");
    // The nested `if` is the else body and ends where the outer one does.
    assert_eq!(else_body.end, s.len());
    let conds: Vec<String> = f.branch_conditions().iter().map(|c| txt(&s, c.clone())).collect();
    assert_eq!(conds, ["a", "b"]);
}

#[test]
fn while_and_do_while_have_ranges_through_their_ends() {
    let s = lex("while (i < 4) i++; do { i--; } while (i > 0); do i++; while (k);");
    let f = Facts::analyze(&s);
    let FlowNode::While { range, condition, body } = &f.flow()[0] else { panic!("{:?}", f.flow()) };
    assert_eq!(txt(&s, condition.clone()), "i < 4");
    assert_eq!(txt(&s, body.clone()), "i ++ ;");
    assert_eq!(range.end, body.end);
    let dos: Vec<&FlowNode> = f.flow().iter().filter(|n| matches!(n, FlowNode::DoWhile { .. })).collect();
    assert_eq!(dos.len(), 2);
    let FlowNode::DoWhile { range, body, condition } = dos[0] else { panic!() };
    assert_eq!(s[body.start].kind, TokenKind::LBrace);
    assert_eq!(txt(&s, condition.clone()), "i > 0");
    assert_eq!(s[range.end - 1].kind, TokenKind::Semicolon);
    let FlowNode::DoWhile { body, condition, .. } = dos[1] else { panic!() };
    assert_eq!(txt(&s, body.clone()), "i ++ ;");
    assert_eq!(txt(&s, condition.clone()), "k");
    let conds: Vec<String> = f.branch_conditions().iter().map(|c| txt(&s, c.clone())).collect();
    assert_eq!(conds, ["i < 4", "i > 0", "k"]);
}

#[test]
fn nested_blocks_inside_function_bodies_are_visible_and_ordered() {
    let src = "void f() { if (a) { for (;;) { while (b) {} } } { y = 1; } }\nfloat g;";
    let s = lex(src);
    let f = Facts::analyze(&s);
    assert_eq!(
        flow_kinds(&f),
        ["simple", "simple", "if", "simple", "for", "simple", "while", "simple", "simple", "simple", "simple"]
    );
    let starts: Vec<usize> = f.flow().iter().map(|n| n.range().start).collect();
    assert!(starts.windows(2).all(|w| w[0] <= w[1]));
    // The function definition ends at its closing brace, not at the next declaration.
    let function = f.flow()[0].range();
    assert_eq!(s[function.end - 1].kind, TokenKind::RBrace);
    assert_eq!(s[function.end].text, "float");
    // Every braced block is reported as a simple statement from `{` through `}`.
    let braces = f.flow().iter().filter(|n| matches!(n, FlowNode::Simple { range } if s[range.start].kind == TokenKind::LBrace)).count();
    assert_eq!(braces, 5);
}

#[test]
fn a_struct_definition_and_its_block_are_reported() {
    let s = lex("struct S { float a; };\nvoid m() {}");
    let f = Facts::analyze(&s);
    let r = f.flow()[0].range();
    assert_eq!(txt(&s, r), "struct S { float a ; } ;");
    assert!(f.flow().iter().any(|n| matches!(n, FlowNode::Simple { range } if txt(&s, range.clone()) == "float a ;")));
}

#[test]
fn control_flow_survives_unbalanced_and_truncated_input() {
    for src in ["if (a", "for (;;", "{ {", "do x;", "while (", "else else", "} }", ") ) ;", "if (a) else"] {
        let s = lex(src);
        let f = Facts::analyze(&s);
        for n in f.flow() {
            let r = n.range();
            assert!(r.start < r.end && r.end <= s.len(), "{src}: {r:?}");
        }
    }
}

#[test]
fn deeply_nested_blocks_do_not_overflow_the_stack() {
    let src = format!("{}x;{}", "{".repeat(20_000), "}".repeat(20_000));
    let s = lex(&src);
    let f = Facts::analyze(&s);
    assert!(!f.flow().is_empty());
    let src = format!("{}x;", "if (a) ".repeat(20_000));
    let s = lex(&src);
    let _ = Facts::analyze(&s);
}

fn ops(src: &str) -> Vec<String> {
    let s = lex(src);
    let f = Facts::analyze(&s);
    f.summarize(0..s.len()).unwrap().operators.iter().map(|(_, o)| o.text().to_string()).collect()
}

#[test]
fn the_summary_lists_only_the_loosest_class_present() {
    assert_eq!(ops("a + b * c - d"), ["+", "-"]);
    assert_eq!(ops("a * b / c"), ["*", "/"]);
    assert_eq!(ops("a < b + c"), ["<"]);
    assert_eq!(ops("a = b ? c : d"), ["="]);
    assert_eq!(ops("a ? b : c"), ["?", ":"]);
    assert_eq!(ops("a || b && c"), ["||"]);
    assert_eq!(ops("a, b = c"), [","]);
    assert_eq!(ops("f(a + b) * (c - d)"), ["*"]);
    assert_eq!(ops("a.b + c[i - 1]"), ["+"]);
    assert_eq!(ops("a.b"), ["."]);
    assert_eq!(ops("!a || b"), ["||"]);
    assert_eq!(ops("!a"), ["!"]);
    assert_eq!(ops("f(x)"), Vec::<String>::new());
    assert_eq!(ops("x"), Vec::<String>::new());
}

#[test]
fn unary_signs_are_not_operators() {
    assert_eq!(ops("-a"), Vec::<String>::new());
    assert_eq!(ops("a * -b"), ["*"]);
    assert_eq!(ops("a - -b"), ["-"]);
    assert_eq!(ops("a = -b + c"), ["="]);
    assert_eq!(ops("a < -b"), ["<"]);
    assert_eq!(ops("(a) - b"), ["-"]);
    assert_eq!(ops("a[1] - b"), ["-"]);
    assert_eq!(ops("a++ - b"), ["-"]);
    // After `&` the sign is binary, but `&` binds looser than `-`, so only `&` is listed.
    assert_eq!(ops("a & -b"), ["&"]);
}

#[test]
fn the_sign_after_a_logical_or_bitwise_operator_is_binary() {
    let s = lex("s = m & -n");
    let f = Facts::analyze(&s);
    let minus = s.iter().position(|t| t.text == "-").unwrap();
    assert!(!f.is_unary_sign(minus, 0));
    let s = lex("s = m * -n");
    let f = Facts::analyze(&s);
    let minus = s.iter().position(|t| t.text == "-").unwrap();
    assert!(f.is_unary_sign(minus, 0));
    // The first token of a range is a sign; so is one after `(` or a comma.
    let s = lex("f(-1, -2)");
    let f = Facts::analyze(&s);
    for (i, t) in s.iter().enumerate() {
        if t.text == "-" {
            assert!(f.is_unary_sign(i, 0));
        }
    }
    for src in ["a && -b", "a || -b", "a ^^ -b", "a | -b", "a ^ -b", "a << -b", "a >> -b"] {
        let s = lex(src);
        let minus = s.iter().position(|t| t.text == "-").unwrap();
        assert!(!is_unary_sign(&s, minus, 0), "{src}");
    }
    for src in ["a = -b", "a += -b", "a ? -b : c", "a ? b : -c", "a < -b", "a == -b", "!-b", "~-b", "a + -b", "a * -b", "a / -b", "a % -b"] {
        let s = lex(src);
        let minus = s.iter().rposition(|t| t.text == "-").unwrap();
        assert!(is_unary_sign(&s, minus, 0), "{src}");
    }
}

fn operand_texts(src: &str, requested: &[Operator]) -> Vec<String> {
    let s = lex(src);
    let f = Facts::analyze(&s);
    f.operands(0..s.len(), requested).into_iter().map(|r| txt(&s, r)).collect()
}

#[test]
fn operand_queries_descend_and_look_through_parentheses() {
    let src = "f(p) - q / r * (s + t)";
    let mdm = [Operator::Sub, Operator::Div, Operator::Mul];
    assert_eq!(
        operand_texts(src, &mdm),
        ["f ( p )", "q", "q / r * ( s + t )", "r", "( s + t )"]
    );
    let with_plus = [Operator::Sub, Operator::Div, Operator::Mul, Operator::Add];
    assert_eq!(
        operand_texts(src, &with_plus),
        ["f ( p )", "q", "q / r * ( s + t )", "r", "( s + t )", "s", "t"]
    );
    // Only `/` and `*`: the loosest class present is additive, which was not requested.
    assert!(operand_texts(src, &[Operator::Div, Operator::Mul]).is_empty());
}

#[test]
fn operand_query_ordering_and_ranges() {
    let s = lex("f(p) - q / r * (s + t)");
    let f = Facts::analyze(&s);
    let r = f.operands(0..s.len(), &[Operator::Sub, Operator::Div, Operator::Mul]);
    assert_eq!(r, [0..4, 5..6, 5..14, 7..8, 9..14]);
    // Shorter first on equal starts, no duplicates.
    let r = f.operands(0..s.len(), &[Operator::Sub, Operator::Div, Operator::Mul, Operator::Add]);
    assert_eq!(r.iter().filter(|x| **x == (5..6)).count(), 1);
    let starts: Vec<(usize, usize)> = r.iter().map(|x| (x.start, x.len())).collect();
    let mut sorted = starts.clone();
    sorted.sort();
    assert_eq!(starts, sorted);
}

fn modulo(src: &str) -> Vec<String> {
    let s = lex(src);
    let f = Facts::analyze(&s);
    f.summarize(0..s.len()).unwrap().modulo_pieces.into_iter().map(|r| txt(&s, r)).collect()
}

#[test]
fn modulo_pieces_split_at_the_documented_operators_only() {
    assert_eq!(
        modulo("total *= pick(i % 4, n) % 2.0 && ok || t % u"),
        ["total *= pick ( i % 4 , n ) % 2.0", "ok", "t % u"]
    );
    assert_eq!(modulo("s = m * -n"), ["s", "m * - n"]);
    assert_eq!(modulo("s = m & -n"), ["s", "m", "n"]);
    assert_eq!(modulo("a % b"), ["a % b"]);
    assert_eq!(modulo("x = a % b + c % d"), ["x", "a % b", "c % d"]);
    assert_eq!(modulo("a ? b % c : d"), ["a", "b % c", "d"]);
    assert_eq!(modulo("v.x % 2"), ["v . x % 2"]);
    assert_eq!(modulo("i++ % 3"), ["i ++ % 3"]);
}

#[test]
fn form_classification() {
    let form = |src: &str| {
        let s = lex(src);
        let f = Facts::analyze(&s);
        (f.classify(0..s.len()), s.len())
    };
    assert!(matches!(form("(a + b)").0, ExprForm::Wrapped { inner } if inner == (1..4)));
    assert!(matches!(form("(a) + (b)").0, ExprForm::Binary { operator: Operator::Add, .. }));
    assert!(matches!(form("a * b / c").0, ExprForm::Binary { operator: Operator::Div, operator_index: 3, .. }));
    if let ExprForm::Binary { left, right, .. } = form("a - b - c").0 {
        assert_eq!((left, right), (0..3, 4..5));
    } else {
        panic!();
    }
    // A looser class at the top makes the range not binary.
    assert_eq!(form("p < q + r").0, ExprForm::Other);
    assert_eq!(form("a && b + c").0, ExprForm::Other);
    assert_eq!(form("a ? b + c : d").0, ExprForm::Other);
    assert_eq!(form("x << a + b").0, ExprForm::Other);
    assert!(matches!(form("v.xyz").0, ExprForm::FieldSelect { base, field_index } if base == (0..1) && field_index == 2));
    assert!(matches!(form("f(a).x").0, ExprForm::FieldSelect { base, .. } if base == (0..4)));
    assert!(matches!(form("m[i + 1]").0, ExprForm::Subscript { base, index } if base == (0..1) && index == (2..5)));
    assert!(matches!(form("f(a)[2]").0, ExprForm::Subscript { base, .. } if base == (0..4)));
    match form("mix(a, b, f(c, d))").0 {
        ExprForm::Invocation { name_index, open, close, arguments } => {
            assert_eq!((name_index, open, close), (0, 1, 12));
            assert_eq!(arguments.len(), 3);
        }
        other => panic!("{other:?}"),
    }
    assert!(matches!(form("vec3(1.0)").0, ExprForm::Invocation { .. }));
    assert_eq!(form("x").0, ExprForm::SingleOperand);
    assert_eq!(form("3.5").0, ExprForm::SingleOperand);
    assert_eq!(form("-2").0, ExprForm::SingleOperand);
    assert_eq!(form("-x").0, ExprForm::Other);
    assert_eq!(form("a b").0, ExprForm::Other);
    // `p < q.x` is not a field select (the looser comparison comes first).
    assert_eq!(form("p < q.x").0, ExprForm::Other);
}

#[test]
fn which_summaries_exist() {
    let src = "float f(float a) { float r = a ? 1.0 : (a + 2.0) * g(a, 3.0); return r + a; }";
    let s = lex(src);
    let f = Facts::analyze(&s);
    // The whole stream.
    assert!(f.summary(0..s.len()).is_some());
    let find = |text: &str| -> Range<usize> {
        for st in 0..s.len() {
            for en in st + 1..=s.len() {
                if txt(&s, st..en) == text {
                    return st..en;
                }
            }
        }
        panic!("{text}")
    };
    // A statement without its semicolon, a return value, an invocation, a right-hand side after `=` and after `?`.
    for text in [
        "float r = a ? 1.0 : ( a + 2.0 ) * g ( a , 3.0 )",
        "r + a",
        "g ( a , 3.0 )",
        "a ? 1.0 : ( a + 2.0 ) * g ( a , 3.0 )",
        "( a + 2.0 ) * g ( a , 3.0 )",
        "a + 2.0",
        "3.0",
        "return r + a",
    ] {
        let r = find(text);
        assert!(f.summary(r.clone()).is_some(), "{text} {r:?}");
    }
    // Unique and sorted by start.
    let all: Vec<(usize, usize)> = f.summaries().map(|x| (x.range.start, x.range.end)).collect();
    let mut sorted = all.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(all, sorted);
}

#[test]
fn a_range_with_a_closer_lacking_its_opener_has_no_summary() {
    let s = lex("a ) + b");
    let f = Facts::analyze(&s);
    assert!(f.summarize(0..s.len()).is_none());
    assert!(f.summary(0..s.len()).is_none());
    // An unclosed opener does not prevent one.
    let s = lex("f ( a + b");
    let f = Facts::analyze(&s);
    assert!(f.summarize(0..s.len()).is_some());
    assert!(f.summary(0..s.len()).is_some());
    assert!(Facts::analyze(&lex("")).summary(0..0).is_none());
}

#[test]
fn the_for_initializer_section_has_a_summary() {
    let s = lex("for (int i = 0; i < 3; ++i) {}");
    let f = Facts::analyze(&s);
    let FlowNode::For { init, .. } = &f.flow()[0] else { panic!() };
    assert!(f.summary(init.clone().unwrap()).is_some());
}

#[test]
fn delimiter_scope_helpers() {
    let s = lex("void f() { a[1 + 2] = g(x, y); } if (c) x; else y; do z; while (w);");
    let f = Facts::analyze(&s);
    let open = s.iter().position(|t| t.kind == TokenKind::LBrace).unwrap();
    let end = f.scope_end(open).unwrap();
    assert_eq!(s[end - 1].kind, TokenKind::RBrace);
    assert!(f.scope_end(0).is_none());
    let if_at = s.iter().position(|t| t.is_keyword(Keyword::If)).unwrap();
    let after_chain = f.controlled_statement_end(if_at).unwrap();
    assert_eq!(s[after_chain - 1].kind, TokenKind::Semicolon);
    assert_eq!(s[after_chain].text, "do");
    let do_at = s.iter().position(|t| t.is_keyword(Keyword::Do)).unwrap();
    assert_eq!(f.controlled_statement_end(do_at), Some(s.len()));
    assert_eq!(f.controlled_statement_end(0), None);
    let b = s.iter().position(|t| t.is_left_bracket()).unwrap();
    assert_eq!(f.bracket_range(b, s.len()), Some(b + 1..b + 4));
    assert_eq!(f.bracket_range(b, b + 2), None);
    assert_eq!(f.bracket_range(0, s.len()), None);
}

#[test]
fn semicolon_and_comma_splitting() {
    let s = lex("(int i = 0; i < f(a; b); ++i)");
    let f = Facts::analyze(&s);
    // Inside the parentheses of the whole thing the sections are three.
    let sections = f.split_semicolons(1..s.len() - 1);
    assert_eq!(sections.len(), 3);
    assert_eq!(txt(&s, sections[0].clone()), "int i = 0");
    assert_eq!(txt(&s, sections[1].clone()), "i < f ( a ; b )");
    let empty = lex("; ;");
    let fe = Facts::analyze(&empty);
    assert_eq!(fe.split_semicolons(0..2), [0..0, 1..1, 2..2]);
    let c = lex("a, f(b, c), [d, e], g");
    let fc = Facts::analyze(&c);
    assert_eq!(fc.top_level_segments(0..c.len()).len(), 4);
    let comma = c.iter().position(|t| t.kind == TokenKind::Comma).unwrap();
    assert_eq!(fc.segment_end(0, c.len()), comma);
    assert_eq!(fc.segment_end(2, c.len()), 8);
    assert_eq!(fc.segment_end(9, c.len()), 14);
    assert_eq!(fc.segment_end(15, c.len()), 16);
}

fn layout(src: &str, key: &str) -> Option<u32> {
    let s = lex(src);
    let f = Facts::analyze(&s);
    f.layout_field(0..s.len(), key)
}

#[test]
fn layout_fields_are_read_as_unsigned_integers() {
    assert_eq!(layout("set = 2, binding = 6", "set"), Some(2));
    assert_eq!(layout("set = 2, binding = 6", "binding"), Some(6));
    assert_eq!(layout("binding=9", "binding"), Some(9));
    assert_eq!(layout("binding=9", "set"), None);
    assert_eq!(layout("binding = 1u", "binding"), None);
    assert_eq!(layout("binding = 2.5", "binding"), None);
    // An occurrence not followed by `= number` is skipped; the scan continues.
    assert_eq!(layout("set, set = x, set = 4", "set"), Some(4));
    assert_eq!(layout("binding binding = 7", "binding"), Some(7));
    // The first malformed number ends the search.
    assert_eq!(layout("binding = 1u, binding = 2", "binding"), None);
    assert_eq!(layout("row_major", "binding"), None);
    assert_eq!(layout("binding =", "binding"), None);
}

#[test]
fn function_parameter_facts_include_struct_member_lines() {
    let s = lex("struct Lamp { vec4 tint; float reach; }; vec3 grade(Lamp l, float ev) { return l.tint.rgb * ev; }");
    let f = Facts::analyze(&s);
    let decl: Vec<&str> = f.declarators().iter().map(|d| d.name.as_str()).collect();
    assert_eq!(decl, ["tint", "reach"]);
    assert_eq!(f.signatures().len(), 1);
    assert!(f.summary(0..s.len()).is_some());
}
