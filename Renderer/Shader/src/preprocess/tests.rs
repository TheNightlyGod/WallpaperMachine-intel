// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Behaviour tests for the preprocessor (spec section 8, items 10 to 34).

use super::*;
use crate::include::IncludeErrorKind;
use crate::source::{MemorySource, NoIncludes};

fn combo(name: &str, value: &str) -> Combo {
    Combo { name: name.to_string(), value: value.to_string() }
}

fn run_with(
    source: &str,
    combos: &[Combo],
    includes: &dyn IncludeSource,
    mode: Mode,
) -> Result<StageOutput, PreprocessError> {
    preprocess_stage(StageKind::Fragment, source, combos, includes, mode)
}

fn eval(source: &str) -> String {
    eval_with(source, &[])
}

fn eval_with(source: &str, combos: &[Combo]) -> String {
    run_with(source, combos, &NoIncludes, Mode::Evaluated).unwrap_or_else(|e| panic!("{e}")).text
}

fn view(source: &str, includes: &MemorySource) -> String {
    run_with(source, &[], includes, Mode::MetadataPreserving).unwrap_or_else(|e| panic!("{e}")).text
}

fn fail(source: &str) -> SyntaxFailure {
    fail_with(source, &[], &NoIncludes)
}

fn fail_with(source: &str, combos: &[Combo], includes: &dyn IncludeSource) -> SyntaxFailure {
    match run_with(source, combos, includes, Mode::Evaluated) {
        Err(PreprocessError::Syntax(s)) => *s,
        other => panic!("expected a syntax failure for {source:?}, got {other:?}"),
    }
}

fn message(source: &str) -> String {
    fail(source).message
}

/// Which of the marker lines `A`, `B`, ... survive.
fn taken(source: &str, combos: &[Combo]) -> Vec<String> {
    eval_with(source, combos).lines().map(str::to_string).collect()
}

fn lines(text: &str) -> Vec<&str> {
    text.lines().collect()
}

#[test]
fn combo_definitions_come_first_in_request_order_with_upper_case_names() {
    let out = eval_with("float a;\n", &[combo("DETAIL", "3"), combo("Sparkle", "1")]);
    assert_eq!(lines(&out), ["#define DETAIL 3", "#define SPARKLE 1", "float a;"]);
    assert_eq!(eval("float a;\n"), "float a;\n");
}

#[test]
fn combo_values_are_written_verbatim() {
    let out = eval_with("x\n", &[combo("Q", "0.50"), combo("E", "")]);
    assert_eq!(lines(&out)[0], "#define Q 0.50");
    assert_eq!(lines(&out)[1], "#define E ");
}

#[test]
fn a_combo_value_with_a_line_break_cannot_inject_lines() {
    let out = eval_with("x\n", &[combo("Q", "1\n#include \"evil.h\"")]);
    assert_eq!(lines(&out), ["#define Q 1 #include \"evil.h\"", "x"]);
}

#[test]
fn dialect_macros_select_the_direct3d_branches_without_being_written() {
    for cond in ["#if HLSL", "#ifdef HLSL", "#if GLSL", "#ifdef GLSL", "#if HLSL_SM40", "#ifdef HLSL_SM40", "#if HLSL && GLSL && HLSL_SM40"] {
        let src = format!("{cond}\nyes\n#else\nno\n#endif\n");
        assert_eq!(eval(&src), "yes\n", "{cond}");
    }
    for cond in ["#ifdef HLSL_SM30", "#ifdef HLSL_GS40", "#if HLSL_SM30", "#if HLSL_GS40", "#ifdef SHADERVERSION", "#ifdef VERSION"] {
        let src = format!("{cond}\nyes\n#else\nno\n#endif\n");
        assert_eq!(eval(&src), "no\n", "{cond}");
    }
    assert_eq!(eval("#ifndef VERSION\nyes\n#endif\n"), "yes\n");
    assert_eq!(eval("#if SHADERVERSION < 62\nyes\n#endif\n"), "yes\n");
    let out = eval_with("x\n", &[combo("A", "1")]);
    for name in ["GLSL", "HLSL", "HLSL_SM40"] {
        assert!(!out.contains(&format!("#define {name}")), "{name}");
    }
}

#[test]
fn a_request_combo_named_shaderversion_wins_like_any_other() {
    let out = eval_with("#if SHADERVERSION < 62\nold\n#else\nnew\n#endif\n", &[combo("SHADERVERSION", "70")]);
    assert!(out.ends_with("new\n"), "{out}");
}

#[test]
fn undef_of_a_dialect_macro_takes_effect_and_is_kept() {
    let out = eval("#undef HLSL\n#if HLSL\nyes\n#else\nno\n#endif\n#define HLSL 2\n#if HLSL == 2\nagain\n#endif\n");
    assert_eq!(lines(&out), ["#undef HLSL", "no", "#define HLSL 2", "again"]);
}

#[test]
fn combos_answer_to_both_spellings() {
    let c = [combo("fxlevel", "2")];
    assert_eq!(taken("#if FXLEVEL == 2\nA\n#endif\n#if fxlevel == 2\nB\n#endif\n", &c)[1..], ["A", "B"]);
    assert_eq!(taken("#ifdef FXLEVEL\nA\n#endif\n#ifdef fxlevel\nB\n#endif\n", &c)[1..], ["A", "B"]);
    // A name in neither spelling does not match: lookups are case-sensitive.
    let c = [combo("FxLevel", "2")];
    assert_eq!(taken("#ifdef FxLevel\nA\n#endif\n#ifdef fxlevel\nB\n#endif\n#ifdef FXLEVEL\nC\n#endif\n", &c)[1..], ["A", "C"]);
}

#[test]
fn zero_valued_combos_are_defined_but_false() {
    let c = [combo("X", "0")];
    assert_eq!(taken("#ifdef X\nA\n#endif\n", &c).last().unwrap(), "A");
    assert_eq!(taken("#if X\nA\n#else\nB\n#endif\n", &c).last().unwrap(), "B");
}

#[test]
fn undefined_names_evaluate_to_zero() {
    assert_eq!(eval("#if NOPE\nA\n#else\nB\n#endif\n"), "B\n");
    assert_eq!(eval("#if NOPE == 0\nA\n#endif\n"), "A\n");
    assert_eq!(eval("#if !NOPE\nA\n#endif\n"), "A\n");
}

#[test]
fn expression_forms_work_in_directives() {
    let c = [combo("A", "1"), combo("B", "0"), combo("C", "0"), combo("X", "7"), combo("Z", "1")];
    let yes = |dir: &str| {
        let out = eval_with(&format!("{dir}\nT\n#endif\n"), &c);
        out.ends_with("T\n")
    };
    assert!(yes("#if A || B && C"));
    assert!(!yes("#if (A || B) && C"));
    assert!(yes("#if !A == B"));
    assert!(yes("#if X >= 3 && X <= 7 || X == 12"));
    assert!(yes("#if X != 0"));
    assert!(yes("#if A == 1 // trailing comment"));
    assert!(yes("#if(Z)"));
    assert!(yes("#if X >= 2;"));
    assert!(yes("#if X >= 2; // legacy"));
    assert!(yes("#if X<10"));
}

#[test]
fn unsupported_expressions_fail_when_active_and_pass_inside_an_inactive_parent() {
    for expr in ["defined(X)", "A + 1", "A & B", "-1", "0x10", "1u", "A ? B : C", "(A", "A B"] {
        let m = message(&format!("#if {expr}\n#endif\n"));
        assert!(m.contains("#if expression is unsupported"), "{expr}: {m}");
        // Inside an inactive parent the same text is never read.
        let out = eval(&format!("#if 0\n#if {expr}\nx\n#elif {expr}\ny\n#endif\n#endif\nz\n"));
        assert_eq!(out, "z\n", "{expr}");
    }
    assert_eq!(message("#if\n#endif\n"), "#if expects an expression");
    assert_eq!(message("#if 1\n#elif\n#endif\n#if 0\n#elif\n#endif\n"), "#if expects an expression");
}

#[test]
fn identifier_values_in_directives() {
    let t = |defs: &str, cond: &str| -> Result<bool, String> {
        match run_with(&format!("{defs}{cond}\nT\n#endif\n"), &[], &NoIncludes, Mode::Evaluated) {
            Ok(o) => Ok(o.text.ends_with("T\n")),
            Err(e) => Err(e.syntax().unwrap().message.clone()),
        }
    };
    assert_eq!(t("#define SKIN sprite\n", "#if SKIN"), Ok(true));
    assert!(t("#define SKIN sprite\n", "#if SKIN == 1").unwrap_err().contains("unsupported"));
    assert_eq!(t("#define MUTE 0\n", "#if MUTE"), Ok(false));
    assert_eq!(t("#define Blend(a, b) (a * b)\n", "#if Blend"), Ok(true));
    assert_eq!(t("#define SPEED 0.0\n", "#if SPEED"), Ok(false));
    assert_eq!(t("#define SPEED 0.25\n", "#if SPEED"), Ok(true));
    assert_eq!(t("#define GAIN 2.5\n", "#if GAIN > 2"), Ok(true));
    assert_eq!(t("#define GAIN 2.5\n", "#if GAIN == 2"), Ok(false));
    assert!(t("#define GAIN 2.5\n", "#if GAIN <= 2.5").unwrap_err().contains("unsupported"));
    assert_eq!(t("#define CAP 1.5f\n", "#if CAP"), Ok(true));
    assert!(t("#define CAP 1.5f\n", "#if CAP == 1").unwrap_err().contains("unsupported"));
    assert_eq!(t("#define BARE\n", "#if BARE == 1"), Ok(true));
}

#[test]
fn a_fractional_combo_value_is_that_number() {
    let c = [combo("HALF", "0.5")];
    assert!(eval_with("#if HALF > 0\nT\n#endif\n#if HALF == 0\nU\n#endif\n", &c).ends_with("T\n"));
}

#[test]
fn macro_chains_in_comparisons() {
    let src = "#define TIER_HIGH 3\n#define TIER TIER_HIGH\n";
    assert_eq!(eval(&format!("{src}#if TIER == 3\nT\n#endif\n#if TIER == 4\nF\n#endif\n#if TIER\nU\n#endif\n")).lines().filter(|l| l.len() == 1).collect::<Vec<_>>(), ["T", "U"]);
    let three = "#define A B\n#define B C\n#define C 9\n#if A == 9\nT\n#endif\n";
    assert!(eval(three).ends_with("T\n"));
    assert!(message("#define P Q\n#if P == 1\n#endif\n").contains("unsupported"));
    assert!(message("#define P Q\n#define Q P\n#if P == 1\n#endif\n").contains("unsupported"));
    let chain = |links: usize| {
        let mut s = String::new();
        for i in 0..links {
            s.push_str(&format!("#define M{i} M{}\n", i + 1));
        }
        s.push_str(&format!("#define M{links} 7\n#if M0 == 7\nT\n#endif\n"));
        s
    };
    assert!(eval(&chain(16)).ends_with("T\n"));
    assert!(message(&chain(17)).contains("unsupported"));
}

#[test]
fn symbolic_right_hand_sides_compare_as_numbers() {
    let out = eval_with("#define RIGHT 3\n#if SIDE == RIGHT\nT\n#endif\n", &[combo("SIDE", "3")]);
    assert!(out.ends_with("T\n"));
}

#[test]
fn elif_picks_the_first_true_branch_only() {
    let src = "#if X == 1\nA\n#elif X == 2\nB\n#elif X >= 2\nC\n#else\nD\n#endif\n";
    let run = |v: &str| eval_with(src, &[combo("X", v)]).lines().last().unwrap().to_string();
    assert_eq!(run("1"), "A");
    assert_eq!(run("2"), "B");
    assert_eq!(run("5"), "C");
    assert_eq!(run("0"), "D");
    // A later #elif is never evaluated once a branch was selected: it may even be invalid.
    assert_eq!(eval("#if 1\nA\n#elif 1 +\nB\n#else\nC\n#endif\n"), "A\n");
    assert_eq!(eval("#if 0\nA\n#elif 1\nB\n#elif 1\nC\n#else\nD\n#endif\n"), "B\n");
}

#[test]
fn conditional_structure_errors() {
    assert_eq!(message("#if 1\n#else\n#elif 1\n#endif\n"), "#elif after #else directive");
    assert_eq!(message("#if 1\n#else\n#else\n#endif\n"), "duplicate #else directive");
    assert_eq!(message("#elif 1\n"), "unmatched #elif directive");
    assert_eq!(message("#else\n"), "unmatched #else directive");
    assert_eq!(message("#if 1\nx\n"), "unterminated conditional directive");
    // Structure is enforced in inactive regions too.
    assert_eq!(message("#if 0\n#if 1\n#else\n#else\n#endif\n#endif\n"), "duplicate #else directive");
    assert_eq!(message("#if 0\n#if 1\n#endif\n"), "unterminated conditional directive");
}

#[test]
fn a_stray_endif_is_ignored() {
    assert_eq!(eval("a\n#endif\nb\n"), "a\nb\n");
    assert_eq!(eval("#if 1\na\n#endif\n#endif\n#endif\nb\n"), "a\nb\n");
}

#[test]
fn an_unterminated_if_reports_its_own_line() {
    let f = fail("// comment\nint a;\nint b;\nint c;\n#if 1\nint d;\n");
    assert_eq!(f.line, 5);
    assert_eq!(f.origin, Origin::Stage);
    assert_eq!(f.stage, StageKind::Fragment);
    assert_eq!(&f.origin_text[f.span.clone()], "#if 1");
    assert_eq!(f.to_string(), "stage Fragment line 5: unterminated conditional directive");
    // The innermost open record is the one reported.
    assert_eq!(fail("#if 1\n#if 1\n#endif\n#ifdef Q\n").line, 4);
}

#[test]
fn an_include_that_ends_with_an_open_if_names_the_include_and_its_line() {
    let inc = MemorySource::new().with("open.h", "a\n\n#ifdef X\nb\n");
    let f = fail_with("#include \"open.h\"\n", &[], &inc);
    assert_eq!(f.origin, Origin::Include("open.h".into()));
    assert_eq!(f.line, 3);
    assert_eq!(f.to_string(), "include open.h line 3: unterminated conditional directive");
}

#[test]
fn conditionals_cannot_cross_an_include_boundary() {
    let inc = MemorySource::new().with("close.h", "#endif\nx\n").with("else.h", "#else\n");
    // A stray #endif in the include is ignored and does not close the includer's #if.
    assert_eq!(eval_inc("#if 0\n#include \"close.h\"\n#else\nb\n#endif\n", &inc), "b\n");
    assert_eq!(eval_inc("#if 1\n#include \"close.h\"\ny\n#endif\n", &inc), "#endif\nx\ny\n".replace("#endif\n", ""));
    let f = fail_with("#if 1\n#include \"else.h\"\n#endif\n", &[], &inc);
    assert_eq!(f.message, "unmatched #else directive");
    assert_eq!(f.origin, Origin::Include("else.h".into()));
}

fn eval_inc(source: &str, includes: &MemorySource) -> String {
    run_with(source, &[], includes, Mode::Evaluated).unwrap_or_else(|e| panic!("{e}")).text
}

#[test]
fn trailing_tokens_on_else_and_endif_fail_comments_pass() {
    assert_eq!(message("#if 1\n#else junk\n#endif\n"), "#else does not accept trailing tokens");
    assert_eq!(message("#if 1\n#endif junk\n"), "#endif does not accept trailing tokens");
    assert_eq!(eval("#if 0\na\n#else // aside\nb\n#endif// fin\n"), "b\n");
    // Enforced in inactive regions as well.
    assert_eq!(message("#if 0\n#if 1\n#endif junk\n#endif\n"), "#endif does not accept trailing tokens");
}

#[test]
fn ifdef_takes_exactly_one_name() {
    assert_eq!(message("#ifdef A B\n#endif\n"), "conditional expects a single macro name");
    assert_eq!(message("#ifndef\n#endif\n"), "conditional expects a single macro name");
    assert_eq!(message("#ifdef 1A\n#endif\n"), "conditional expects a single macro name");
    assert_eq!(eval("#if 0\n#ifdef A B\nx\n#endif\n#endif\nz\n"), "z\n");
}

#[test]
fn define_forms_are_normalised() {
    let out = eval("#define K\n#define K2 3\n#define K3(a) (a)+1\n#  define Y 2 // c\n\t#define\tZ\t9\n");
    assert_eq!(lines(&out), ["#define K", "#define K2 3", "#define K3(a) (a)+1", "#define Y 2 // c", "#define\tZ\t9"]);
    assert_eq!(eval("#define K\n#if K\nyes\n#endif\n"), "#define K\nyes\n");
}

#[test]
fn define_errors() {
    for src in ["#define MIN-GAP 3\n", "#define\n", "#define 3x 1\n", "#define F(a b\n", "#define (x) 1\n", "#define A$ 1\n"] {
        assert_eq!(message(src), "#define expects a macro name", "{src:?}");
    }
    // Inactive defines are neither checked, applied nor emitted.
    assert_eq!(eval("#if 0\n#define MIN-GAP 3\n#define X 1\n#endif\n#ifdef X\nbad\n#endif\nok\n"), "ok\n");
}

#[test]
fn redefinition_replaces_silently_and_function_like_macros_register_the_name() {
    let out = eval("#define X 1\n#define X 2\n#if X == 2\nyes\n#endif\n#define F(a) (a)\n#ifdef F\nf\n#endif\n");
    assert_eq!(lines(&out), ["#define X 1", "#define X 2", "yes", "#define F(a) (a)", "f"]);
}

#[test]
fn macros_are_not_expanded_in_ordinary_lines() {
    let out = eval("#define SCALE 2.0\nfloat v = SCALE * x;\n");
    assert_eq!(lines(&out), ["#define SCALE 2.0", "float v = SCALE * x;"]);
}

#[test]
fn undef_removes_the_macro_and_is_kept() {
    let out = eval("#define X 1\n#undef X\n#ifdef X\nbad\n#endif\nok\n");
    assert_eq!(lines(&out), ["#define X 1", "#undef X", "ok"]);
    // Inside an inactive branch it is a no-op and is dropped.
    assert_eq!(eval("#define X 1\n#if 0\n#undef X\n#endif\n#ifdef X\nyes\n#endif\n").lines().last(), Some("yes"));
    assert_eq!(message("#undef 1\n"), "#undef expects a single macro name");
    assert_eq!(message("#undef A B\n"), "#undef expects a single macro name");
    assert_eq!(message("#undef\n"), "#undef expects a single macro name");
    // Removes a macro the engine (a combo) defined.
    assert_eq!(eval_with("#undef LEVEL\n#ifdef LEVEL\nbad\n#endif\nok\n", &[combo("LEVEL", "1")]).lines().last(), Some("ok"));
}

#[test]
fn undef_works_across_includes_in_both_directions() {
    let inc = MemorySource::new()
        .with("a.h", "#define TINT 1\n")
        .with("b.h", "#ifdef TINT\nb sees TINT\n#else\nb does not\n#endif\n")
        .with("u.h", "#undef TINT\n");
    let out = eval_inc("#include \"a.h\"\n#undef TINT\n#include \"b.h\"\n", &inc);
    assert!(out.ends_with("b does not\n"), "{out}");
    let out = eval_inc("#include \"a.h\"\n#include \"u.h\"\n#include \"b.h\"\n", &inc);
    assert!(out.ends_with("b does not\n"), "{out}");
    let out = eval_inc("#include \"a.h\"\n#include \"b.h\"\n", &inc);
    assert!(out.ends_with("b sees TINT\n"), "{out}");
}

#[test]
fn include_forms() {
    let inc = MemorySource::new().with("a.h", "A\n").with("x//a.h", "X\n").with("dir/b.h", "B\n").with("p.h", "P\n");
    assert_eq!(eval_inc("#include \"a.h\"\n", &inc), "A\n");
    assert_eq!(eval_inc("#include <a.h>\n", &inc), "A\n");
    assert_eq!(eval_inc("  #  include   \"a.h\"   // trailing\n", &inc), "A\n");
    assert_eq!(eval_inc("#include <x//a.h>\n", &inc), "X\n");
    assert_eq!(eval_inc("#include \"dir\\b.h\"\n", &inc), "B\n");
    assert_eq!(eval_inc("#include \"./p.h\"\n", &MemorySource::new().with("./p.h", "dot\n")), "dot\n");
    let f = fail_with("#include a.h\n", &[], &inc);
    assert_eq!(f.message, "#include expects a quoted include path");
    for bad in ["#include\n", "#include \"a.h\n", "#include \"a.h\" x\n", "#include <a.h\n", "#include 'a.h'\n"] {
        assert_eq!(fail_with(bad, &[], &inc).message, "#include expects a quoted include path", "{bad:?}");
    }
    for bad in ["../x.h", "/abs.h", "C:/x.h", "a/../b.h", ""] {
        let f = fail_with(&format!("#include \"{bad}\"\n"), &[], &inc);
        assert_eq!(f.message, "#include path is invalid", "{bad}");
    }
}

#[test]
fn includes_nest_share_one_macro_table_and_expand_each_time() {
    let inc = MemorySource::new()
        .with("a.h", "a1\n#include \"b.h\"\na2 sees C=#C_IS_DEFINED\n#ifdef C\nC visible in a\n#endif\n")
        .with("b.h", "b1\n#include \"c.h\"\nb2\n")
        .with("c.h", "#define C 1\nc1\n")
        .with("once.h", "#define N 1\nonce\n");
    let out = eval_inc("#include \"a.h\"\n#ifdef C\nC visible in root\n#endif\n", &inc);
    assert_eq!(
        lines(&out),
        ["a1", "b1", "#define C 1", "c1", "b2", "a2 sees C=#C_IS_DEFINED", "C visible in a", "C visible in root"]
    );
    let out = eval_inc("#include \"once.h\"\n#include \"once.h\"\n", &inc);
    assert_eq!(lines(&out), ["#define N 1", "once", "#define N 1", "once"]);
}

#[test]
fn an_include_cycle_names_the_chain_and_the_location() {
    let inc = MemorySource::new().with("p.h", "x\n#include \"q.h\"\n").with("q.h", "y\n\n#include \"p.h\"\n");
    let f = fail_with("#include \"p.h\"\n", &[], &inc);
    assert_eq!(f.message, "include cycle detected: p.h -> q.h -> p.h");
    assert_eq!(f.origin, Origin::Include("q.h".into()));
    assert_eq!(f.line, 3);
    assert_eq!(f.to_string(), "include q.h line 3: include cycle detected: p.h -> q.h -> p.h");
    let me = MemorySource::new().with("s.h", "#include \"s.h\"\n");
    let f = fail_with("#include \"s.h\"\n", &[], &me);
    assert_eq!(f.message, "include cycle detected: s.h -> s.h");
}

#[test]
fn aliased_spellings_of_one_path_do_not_defeat_the_cycle_check() {
    let inc = MemorySource::new().with("p.h", "#include \"./p.h\"\n").with("./p.h", "#include \"x//../../p.h\"\n");
    // `./p.h` is the same file as `p.h` once normalised.
    let f = fail_with("#include \"p.h\"\n", &[], &inc);
    assert!(f.message.starts_with("include cycle detected"), "{}", f.message);
    let inc = MemorySource::new().with("a.h", "#include \"x/./a.h\"\n").with("x/./a.h", "#include \"x//a.h\"\n").with("x//a.h", "#include \"a.h\"\n");
    let f = fail_with("#include \"a.h\"\n", &[], &inc);
    assert!(f.message.starts_with("include cycle detected") || f.message.contains("too deep"), "{}", f.message);
}

#[test]
fn a_very_long_acyclic_chain_fails_with_a_bounded_depth_error() {
    struct Chain;
    impl IncludeSource for Chain {
        fn read(&self, path: &str) -> Result<String, IncludeError> {
            let n: usize = path.trim_start_matches('h').trim_end_matches(".h").parse().unwrap();
            Ok(if n < 300 { format!("#include \"h{}.h\"\nl{n}\n", n + 1) } else { "end\n".to_string() })
        }
    }
    let f = fail_with("#include \"h0.h\"\n", &[], &Chain);
    assert!(f.message.contains("too deep") && f.message.contains("h0.h") && f.message.contains("..."), "{}", f.message);
    // A chain below the limit works.
    struct Short;
    impl IncludeSource for Short {
        fn read(&self, path: &str) -> Result<String, IncludeError> {
            let n: usize = path.trim_start_matches('h').trim_end_matches(".h").parse().unwrap();
            Ok(if n < 30 { format!("#include \"h{}.h\"\n", n + 1) } else { "end\n".to_string() })
        }
    }
    assert_eq!(run_with("#include \"h0.h\"\n", &[], &Short, Mode::Evaluated).unwrap().text, "end\n");
}

#[test]
fn an_exponential_include_tree_is_stopped_by_the_expansion_bound() {
    struct Fan;
    impl IncludeSource for Fan {
        fn read(&self, path: &str) -> Result<String, IncludeError> {
            let n: usize = path.trim_start_matches('f').trim_end_matches(".h").parse().unwrap();
            Ok(format!("#include \"f{0}.h\"\n#include \"f{0}.h\"\n", n + 1))
        }
    }
    let f = fail_with("#include \"f0.h\"\n", &[], &Fan);
    assert!(f.message.contains("too deep") || f.message.contains("too many"), "{}", f.message);
}

#[test]
fn the_output_size_is_bounded() {
    struct Big;
    impl IncludeSource for Big {
        fn read(&self, _: &str) -> Result<String, IncludeError> {
            Ok("x".repeat(1_000_000) + "\n")
        }
    }
    let src = "#include \"a.h\"\n".repeat(20);
    let f = fail_with(&src, &[], &Big);
    assert!(f.message.contains("too large"), "{}", f.message);
}

#[test]
fn includes_in_inactive_branches_are_not_read_or_validated() {
    struct Panics;
    impl IncludeSource for Panics {
        fn read(&self, path: &str) -> Result<String, IncludeError> {
            panic!("read {path}");
        }
    }
    let out = run_with("#if 0\n#include \"gone.h\"\n#include \"../bad\"\n#include nonsense\n#endif\nok\n", &[], &Panics, Mode::Evaluated).unwrap();
    assert_eq!(out.text, "ok\n");
    let out = run_with("#ifdef NOPE\n#include \"gone.h\"\n#else\nelse\n#endif\n", &[], &Panics, Mode::Evaluated).unwrap();
    assert_eq!(out.text, "else\n");
}

#[test]
fn a_missing_active_include_is_the_providers_not_found_error() {
    let e = run_with("a\n#include \"gone.h\"\n", &[], &NoIncludes, Mode::Evaluated).unwrap_err();
    match &e {
        PreprocessError::Include(i) => {
            assert_eq!(i.kind, IncludeErrorKind::NotFound);
            assert_eq!(i.path, "gone.h");
        }
        other => panic!("{other:?}"),
    }
    assert!(e.to_string().contains("not found") && e.to_string().contains("gone.h"));
}

#[test]
fn provider_failures_keep_their_kinds_and_paths() {
    struct Failing;
    impl IncludeSource for Failing {
        fn read(&self, path: &str) -> Result<String, IncludeError> {
            let kind = match path {
                "unreadable.h" => IncludeErrorKind::Unreadable { len: 9 },
                "binary.h" => IncludeErrorKind::NotUtf8,
                _ => IncludeErrorKind::NotFound,
            };
            Err(IncludeError { path: path.to_string(), kind })
        }
    }
    for (path, kind) in [
        ("unreadable.h", IncludeErrorKind::Unreadable { len: 9 }),
        ("binary.h", IncludeErrorKind::NotUtf8),
        ("missing.h", IncludeErrorKind::NotFound),
    ] {
        let e = run_with(&format!("#include \"{path}\"\n"), &[], &Failing, Mode::Evaluated).unwrap_err();
        assert_eq!(e, PreprocessError::Include(IncludeError { path: path.into(), kind }));
        assert!(e.to_string().contains(path));
        let as_shader: ShaderError = e.into_shader_error("effects/x");
        assert!(matches!(as_shader, ShaderError::Include(_)));
    }
}

#[test]
fn unknown_directives_pass_through_normalised() {
    let out = eval("#pragma once\n#  extension X : enable\n#version 450\n##define Z 1\n#ifdef Z\nbad\n#endif\n#line 5\n#error x\n");
    assert_eq!(lines(&out), ["#pragma once", "#extension X : enable", "#version 450", "##define Z 1", "#line 5", "#error x"]);
    let out = eval("##include \"a.h\"\n");
    assert_eq!(out, "##include \"a.h\"\n");
    // Dropped when inactive.
    assert_eq!(eval("#if 0\n#pragma once\n#endif\n"), "");
}

#[test]
fn the_keyword_ends_at_the_first_non_identifier_character() {
    assert_eq!(eval("#if(1)\nA\n#endif// fin\n"), "A\n");
    assert_eq!(eval("#definePOWER 9\n"), "#definePOWER 9\n");
    assert_eq!(eval("#ifdefX\nA\n"), "#ifdefX\nA\n");
    assert_eq!(eval("#IF 1\n"), "#IF 1\n");
}

#[test]
fn ordinary_line_continuations_drop_the_backslash_and_do_not_join() {
    assert_eq!(eval("v = base * \\\nscale;\n"), "v = base * \nscale;\n");
    assert_eq!(eval("emit(u, \\\nv);\n"), "emit(u, \nv);\n");
    assert_eq!(eval("x \\  \ny\n"), "x \ny\n");
    assert_eq!(eval("a \\\n\\\nb\n"), "a \n\nb\n");
}

#[test]
fn a_continued_define_keeps_its_line_break_and_a_continued_if_is_joined() {
    let out = eval("#define M(a) \\\n  (a + 1) \\\n  + 2\nx\n");
    assert_eq!(lines(&out), ["#define M(a) \\", "  (a + 1) \\", "  + 2", "x"]);
    assert_eq!(eval("#define N 3\n#if N == \\\n  3\nyes\n#endif\n").lines().last(), Some("yes"));
    // The continuation lines of a directive are not seen as directives of their own.
    assert_eq!(eval("#define K 1 \\\n#undef K\n#ifdef K\nyes\n#endif\n").lines().last(), Some("yes"));
}

#[test]
fn line_terminators_and_the_final_newline() {
    assert_eq!(eval("a\r\nb\r\n"), "a\nb\n");
    assert_eq!(eval("a\nb"), "a\nb\n");
    assert_eq!(eval("a\r\n#define X 1\r\n#if X\r\nb\r\n#endif\r\n"), "a\n#define X 1\nb\n");
    assert_eq!(eval(""), "");
    assert_eq!(eval("\n"), "\n");
    assert_eq!(eval("a\n\nb\n"), "a\n\nb\n");
    // A bare CR is not a terminator.
    assert_eq!(eval("a\rb\n"), "a\rb\n");
    let out = eval("#if X\r\nx\r\n#else // c\r\ny\r\n#endif\r\n");
    assert!(!out.contains('\r'));
    // No file at all still gets the combos.
    assert_eq!(eval_with("", &[combo("A", "1")]), "#define A 1\n");
}

#[test]
fn an_empty_include_is_fine_and_non_ascii_passes_through() {
    let inc = MemorySource::new().with("empty.h", "").with("u.h", "// é€ comment\nstring s = \"ü\";\n");
    assert_eq!(eval_inc("a\n#include \"empty.h\"\nb\n", &inc), "a\nb\n");
    assert_eq!(eval_inc("#include \"u.h\"\n", &inc), "// é€ comment\nstring s = \"ü\";\n");
}

#[test]
fn inactive_text_can_be_anything() {
    let out = eval("#if 0\n@@ not glsl ` \u{1}\n#if (((\nfoo bar\n#else\n#endif\n#endif\nz\n");
    assert_eq!(out, "z\n");
}

#[test]
fn evaluated_output_never_contains_conditional_or_include_directives() {
    let inc = MemorySource::new().with("a.h", "#if 1\nin a\n#else\ninvalid [[[\n#endif\n#require Whatever\n");
    let src = "#include \"a.h\"\n#ifdef NOPE\n}}} invalid\n#elif 0\nalso invalid (\n#else\nkept\n#endif\n#ifndef NOPE\nkept2\n#endif\n#require LightingV1\n";
    let out = eval_inc(src, &inc);
    for banned in ["#include", "#if", "#else", "#elif", "#endif", "#require", "invalid"] {
        assert!(!out.contains(banned), "{banned}: {out}");
    }
    assert_eq!(lines(&out), ["in a", "kept", "kept2"]);
}

#[test]
fn require_lines_vanish_and_lighting_is_written_only_for_a_lit_pass() {
    assert_eq!(eval("#require OtherThing\n#require\n#require LightingV1 extra\nx\n"), "x\n");
    let lights = [combo("LIGHTING", "1"), combo("LIGHTS_POINT", "4"), combo("LIGHTS_SPOT", "2"), combo("LIGHTS_TUBE", "1"), combo("LIGHTS_DIRECTIONAL", "3")];
    let out = eval_with("#require LightingV1\nvoid main() {}\n", &lights);
    for needle in [
        "uniform vec4 g_LPoint_Color[4];",
        "uniform vec4 g_LSpot_Exponent[2];",
        "uniform vec4 g_LTube_OriginB[1];",
        "uniform vec4 g_LDirectional_Direction[3];",
        "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic)",
        "PointSegmentDelta(",
        "ComputePBRLightShadowInfinite(",
        "smoothstep(",
    ] {
        assert!(out.contains(needle), "{needle}");
    }
    assert!(out.ends_with("void main() {}\n"));
    assert!(!out.contains("#require"));
    // No LIGHTING, or zero: nothing, even with light counts.
    for c in [vec![combo("LIGHTS_POINT", "3")], vec![combo("LIGHTING", "0"), combo("LIGHTS_POINT", "3")]] {
        let out = eval_with("#require LightingV1\nx\n", &c);
        assert!(!out.contains("PerformLighting_V1"), "{out}");
    }
    // In an inactive branch: nothing.
    let out = eval_with("#if 0\n#require LightingV1\n#endif\nx\n", &lights);
    assert!(!out.contains("PerformLighting_V1"));
}

#[test]
fn a_lit_pass_without_lights_still_gets_the_function() {
    let out = eval_with("#require LightingV1\n", &[combo("LIGHTING", "1")]);
    assert!(out.contains("vec3 PerformLighting_V1("));
    assert!(!out.contains("uniform") && !out.contains("ComputePBR"));
    // Counts outside 0 to 15 are clamped; bad text counts as 0.
    let out = eval_with(
        "#require LightingV1\n",
        &[combo("LIGHTING", "1"), combo("LIGHTS_POINT", "99"), combo("LIGHTS_SPOT", "-7"), combo("LIGHTS_TUBE", "x9")],
    );
    assert!(out.contains("uniform vec4 g_LPoint_Color[15];"));
    assert!(!out.contains("g_LSpot") && !out.contains("g_LTube"));
}

#[test]
fn the_lighting_block_is_written_where_the_require_line_stood() {
    let out = eval_with("before\n#require LightingV1\nafter\n", &[combo("LIGHTING", "1")]);
    let l = lines(&out);
    assert_eq!(l[1], "before");
    assert_eq!(l.last(), Some(&"after"));
    assert!(l[2].starts_with("vec3 PerformLighting_V1"));
}

#[test]
fn stages_are_independent() {
    let a = preprocess_stage(StageKind::Vertex, "#define ONLY_VERTEX 1\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    let b = preprocess_stage(StageKind::Fragment, "#ifdef ONLY_VERTEX\nleak\n#endif\nok\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(a.text.contains("ONLY_VERTEX"));
    assert_eq!(b.text, "ok\n");
}

#[test]
fn view_mode_keeps_inactive_lines_and_conditionals() {
    let src = "#if 0\n  inactive line\n#else // other\nactive line\n#endif\n#ifdef HLSL\nh\n#endif\n";
    let out = view(src, &MemorySource::new());
    assert_eq!(
        lines(&out),
        ["#if 0", "  inactive line", "#else // other", "active line", "#endif", "#ifdef HLSL", "h", "#endif"]
    );
}

#[test]
fn view_mode_expands_active_includes_and_keeps_inactive_ones_unread() {
    let inc = MemorySource::new().with("a.h", "from a\n#if X\nx\n#endif\n");
    let src = "#include \"a.h\"\n#if 0\n#include \"gone.h\"\n#endif\n#if 1\n#include \"a.h\"\n#endif\n";
    let out = view(src, &inc);
    assert_eq!(
        lines(&out),
        ["from a", "#if X", "x", "#endif", "#if 0", "#include \"gone.h\"", "#endif", "#if 1", "from a", "#if X", "x", "#endif", "#endif"]
    );
}

#[test]
fn view_mode_drops_inactive_defines_and_they_do_not_affect_later_conditionals() {
    let src = "#if 0\n#define HIDDEN 1\n#endif\n#define SHOWN 1\n#ifdef HIDDEN\nh\n#endif\n#ifdef SHOWN\ns\n#endif\n";
    let out = view(src, &MemorySource::new());
    assert!(!out.contains("#define HIDDEN"));
    assert!(out.contains("#define SHOWN 1"));
    // Inactive `h` is kept (it is an ordinary line), the structure is intact.
    assert_eq!(lines(&out).iter().filter(|l| **l == "#endif").count(), 3);
}

#[test]
fn view_mode_has_the_combo_definitions_drops_require_and_still_fails_on_bad_structure() {
    let out = run_with("#require LightingV1\nx\n", &[combo("LIGHTING", "1"), combo("LIGHTS_POINT", "2")], &NoIncludes, Mode::MetadataPreserving).unwrap().text;
    assert!(out.starts_with("#define LIGHTING 1\n#define LIGHTS_POINT 2\n"));
    assert!(!out.contains("PerformLighting_V1") && !out.contains("#require"));
    for src in ["#if 1\n", "#else\n", "#if 1\n#else\n#else\n#endif\n", "#if 1 +\n#endif\n", "#define\n", "#if 1\n#endif junk\n"] {
        assert!(matches!(run_with(src, &[], &NoIncludes, Mode::MetadataPreserving), Err(PreprocessError::Syntax(_))), "{src:?}");
    }
}

#[test]
fn view_mode_keeps_active_unknown_directives_once() {
    let out = view("#pragma once\nx\n", &MemorySource::new());
    assert_eq!(out.matches("#pragma once").count(), 1);
}

#[test]
fn leading_macro_facts_follow_the_first_ordinary_line() {
    let src = "#define SIZE 8\n#define FLAG\n#define F(a) a\n#define TAPS 3 // c\nfloat x;\n#define LATE 1\n";
    let out = run_with(src, &[combo("K", "2")], &NoIncludes, Mode::Evaluated).unwrap();
    let m = &out.macros;
    assert_eq!(m.value("K"), Some("2"));
    assert_eq!(m.value("SIZE"), Some("8"));
    assert_eq!(m.value("TAPS"), Some("3"));
    assert!(m.knows("FLAG") && m.value("FLAG").is_none());
    assert!(m.knows("F") && m.value("F").is_none());
    assert!(!m.knows("LATE"));
}

#[test]
fn a_blank_or_comment_line_ends_the_leading_region() {
    let blank = run_with("#define A 1\n\n#define B 2\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert_eq!(blank.macros.entries().len(), 1);
    let comment = run_with("#define A 1\n// note\n#define B 2\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(comment.macros.knows("A") && !comment.macros.knows("B"));
    let other = run_with("#define A 1\n#pragma x\n#define B 2\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(other.macros.knows("A") && !other.macros.knows("B"));
}

#[test]
fn definepower_is_not_a_define_and_undef_removes_a_fact() {
    let out = run_with("#definePOWER 9\n#define Q 1\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(!out.macros.knows("POWER") && !out.macros.knows("Q"));
    let out = run_with("#define Q 1\n#define R 2\n#undef Q\nx\n", &[], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(!out.macros.knows("Q") && out.macros.value("R") == Some("2"));
    // Combos with an empty value contribute no value.
    let out = run_with("x\n", &[combo("E", ""), combo("F", "4")], &NoIncludes, Mode::Evaluated).unwrap();
    assert!(out.macros.value("E").is_none() && out.macros.value("F") == Some("4"));
}

#[test]
fn leading_defines_inside_an_include_count_and_conditionals_do_not_end_the_region() {
    let inc = MemorySource::new().with("c.h", "#define INC 5\n");
    let out = run_with("#include \"c.h\"\n#if 1\n#define IN_IF 6\n#endif\nx\n", &[], &inc, Mode::Evaluated).unwrap();
    assert_eq!(out.macros.value("INC"), Some("5"));
    assert_eq!(out.macros.value("IN_IF"), Some("6"));
}

#[test]
fn the_cast_and_sampler_names_pass_through_unchanged() {
    let src = "float a = CASTI(1) + CASTU(n) + CASTF(m);\nuvec4 b = CAST4U(k);\nvec4 f(DECLARE_SAMPLER2D_PARAMETER(tex), vec2 uv);\nvec4 c = f(MAKE_SAMPLER2D_ARGUMENT(g_Texture2), uv);\n";
    let evaluated = eval(src);
    assert_eq!(evaluated, src);
    let preserved = view(src, &MemorySource::new());
    assert_eq!(preserved, src);
    let out = run_with(src, &[], &NoIncludes, Mode::Evaluated).unwrap();
    for name in ["CASTI", "CASTU", "CASTF", "CAST4U", "DECLARE_SAMPLER2D_PARAMETER", "MAKE_SAMPLER2D_ARGUMENT"] {
        assert!(!out.macros.knows(name), "{name}");
    }
}

#[test]
fn failures_become_diagnostics_with_stage_origin_line_and_excerpt() {
    let err = run_with("a\nb\n#if 1 +\n#endif\n", &[], &NoIncludes, Mode::Evaluated).unwrap_err();
    let shader_error = err.into_shader_error("effects/glow");
    let text = shader_error.to_string();
    for needle in ["#if expression is unsupported", "effects/glow.frag:3:1", "3 | #if 1 +", "stage: fragment", "pass: Preprocess", "shader: effects/glow"] {
        assert!(text.contains(needle), "{needle}: {text}");
    }
    let inc = MemorySource::new().with("lib/x.h", "ok\n#else\n");
    let err = preprocess_stage(StageKind::Vertex, "#include \"lib/x.h\"\n", &[], &inc, Mode::Evaluated).unwrap_err();
    let text = err.into_shader_error("fx").to_string();
    for needle in ["unmatched #else directive", "include lib/x.h:2:1", "2 | #else", "stage: vertex"] {
        assert!(text.contains(needle), "{needle}: {text}");
    }
}

#[test]
fn a_directive_does_not_hide_inside_an_ordinary_comment_line() {
    // The preprocessor does not know about block comments (R12): a directive on its own line is executed.
    assert_eq!(eval("/*\n#define X 1\n*/\n#ifdef X\nseen\n#endif\n").lines().last(), Some("seen"));
}

#[test]
fn comment_stripping_rules_for_directive_bodies() {
    assert_eq!(strip_directive_comment("A // c"), "A ");
    assert_eq!(strip_directive_comment("\"a//b\" // c"), "\"a//b\" ");
    assert_eq!(strip_directive_comment("\"a\\\"//b\" // c"), "\"a\\\"//b\" ");
    assert_eq!(strip_directive_comment("<pkg//util/x.h> // c"), "<pkg//util/x.h> ");
    assert_eq!(strip_directive_comment("<pkg//util/x.h>"), "<pkg//util/x.h>");
    // A `<` that is a comparison never hides a comment.
    assert_eq!(strip_directive_comment("A < B // c"), "A < B ");
    assert_eq!(strip_directive_comment("A /* c */"), "A /* c */");
    assert_eq!(strip_directive_comment("<oops // c"), "<oops ");
}

#[test]
fn directive_arguments_tolerate_trailing_comments() {
    assert_eq!(eval("#define V 2 // two\n#ifdef V // check\nyes\n#endif // end\n#if V < 3 // small\nsmall\n#endif\n").lines().skip(1).collect::<Vec<_>>(), ["yes", "small"]);
}
