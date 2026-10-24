// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Shipped effects contain conditions such as `#if g_Texture0Resolution.x < g_Texture0Resolution.y`,
// where the names are run-time uniforms, not macros. Wallpaper Engine's compiler accepts the source;
// the preprocessor here refused the whole effect. A condition that refers to run-time values (a
// member access, a subscript or another token a preprocessor expression cannot contain) is false,
// so its `#else` or a later `#elif` is taken, and a non-fatal Preprocess diagnostic records it.
// Every other expression evaluates, or fails, exactly as before.

mod support;

use support::*;
use wm_shader::diagnostic::Pass;
use wm_shader::preprocess::{MAX_CONDITION_NOTES, Mode, StageOutput, preprocess_stage};
use wm_shader::source::{MemorySource, NoIncludes};
use wm_shader::{Combo, StageKind};

fn preprocess(text: &str, combos: &[(&str, &str)]) -> Result<StageOutput, String> {
    let combos: Vec<Combo> = combos.iter().map(|(n, v)| Combo { name: (*n).into(), value: (*v).into() }).collect();
    preprocess_stage(StageKind::Fragment, text, &combos, &NoIncludes, Mode::Evaluated).map_err(|e| e.to_string())
}

/// The ordinary (non-directive) lines the preprocessor kept.
fn kept(out: &StageOutput) -> Vec<&str> {
    out.text.lines().filter(|l| !l.starts_with('#')).collect()
}

const SHIPPED_SHAPE: &str = "varying vec2 v_TexCoord;
uniform vec4 g_Texture0Resolution;
uniform float g_ratio;
#if g_Texture0Resolution.x < g_Texture0Resolution.y
#define ratioDiff (vec2(g_ratio, 1.0))
#else
#define ratioDiff (vec2(g_ratio, 1.0))
#endif
void main() { gl_FragColor = vec4(v_TexCoord * ratioDiff, 0.0, 1.0); }";

#[test]
fn the_shipped_condition_compiles_and_records_a_preprocess_diagnostic() {
    let p = program_ok(SHIPPED_SHAPE);
    let notes: Vec<_> = p.diagnostics.iter().filter(|d| d.pass == Some(Pass::Preprocess)).collect();
    assert_eq!(notes.len(), 1, "{:?}", p.diagnostics);
    let note = notes[0];
    assert_eq!(note.stage, Some(StageKind::Fragment));
    let span = note.span.expect("the diagnostic points at the directive");
    assert!(SHIPPED_SHAPE[span.start()..span.end()].starts_with("#if g_Texture0Resolution.x"), "{span:?}");
    assert!(!note.message.is_empty());
}

#[test]
fn the_else_branch_is_the_one_taken() {
    // Only the `#else` branch names a declared uniform, so the program compiles only if it is taken.
    let fragment = "varying vec2 v_TexCoord;
uniform vec4 g_Texture0Resolution;
uniform float g_ratio;
#if g_Texture0Resolution.x < g_Texture0Resolution.y
#define ratioDiff (vec2(g_NotDeclared, 1.0))
#else
#define ratioDiff (vec2(1.0, g_ratio))
#endif
void main() { gl_FragColor = vec4(v_TexCoord * ratioDiff, 0.0, 1.0); }";
    program_ok(fragment);
    let out = preprocess("#if g_R.x < g_R.y\nIF\n#else\nELSE\n#endif\nAFTER\n", &[]).unwrap();
    assert_eq!(kept(&out), ["ELSE", "AFTER"]);
}

#[test]
fn an_unevaluable_elif_is_false_and_the_later_branches_still_decide() {
    let chain = "#if MODE == 1\nONE\n#elif g_Size.x > 0.5\nSIZE\n#elif MODE == 2\nTWO\n#else\nOTHER\n#endif\n";
    assert_eq!(kept(&preprocess(chain, &[("MODE", "2")]).unwrap()), ["TWO"]);
    assert_eq!(kept(&preprocess(chain, &[("MODE", "3")]).unwrap()), ["OTHER"]);
    assert_eq!(kept(&preprocess(chain, &[("MODE", "1")]).unwrap()), ["ONE"]);
    let out = preprocess("#if g_A.x\nA\n#elif 1\nB\n#else\nC\n#endif\n", &[]).unwrap();
    assert_eq!(kept(&out), ["B"]);
    let out = preprocess("#if g_Values[2] > 1\nA\n#elif g_V.y\nB\n#endif\nD\n", &[]).unwrap();
    assert_eq!(kept(&out), ["D"]);
}

#[test]
fn nesting_inside_a_false_condition_is_skipped_and_an_inactive_one_is_not_read() {
    let out = preprocess("#if g_A.x\n#if 1\nINNER\n#endif\n#else\nOUTER\n#endif\n", &[]).unwrap();
    assert_eq!(kept(&out), ["OUTER"]);
    // Inside a region that is already inactive the condition is never evaluated.
    let program = program_ok(
        "varying vec2 v_TexCoord;\n#if 0\n#if g_A.x < g_A.y\n#endif\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }",
    );
    assert!(program.diagnostics.iter().all(|d| d.pass != Some(Pass::Preprocess)), "{:?}", program.diagnostics);
}

#[test]
fn a_condition_in_an_include_names_the_include() {
    let includes = MemorySource::new().with("ratio.h", "#if g_Texture0Resolution.x < g_Texture0Resolution.y\n#define R 1.0\n#else\n#define R 2.0\n#endif\n");
    let out = preprocess_stage(StageKind::Fragment, "#include \"ratio.h\"\nvoid main() {}\n", &[], &includes, Mode::Evaluated).unwrap();
    assert!(out.text.contains("#define R 2.0") && !out.text.contains("#define R 1.0"), "{}", out.text);
    assert_eq!(out.diagnostics.len(), 1);
    assert_eq!(out.diagnostics[0].origin.as_deref(), Some("include ratio.h"));
    assert_eq!(out.diagnostics[0].pass, Some(Pass::Preprocess));
}

#[test]
fn preprocessor_expressions_evaluate_or_fail_as_before() {
    // Valid expressions keep their value.
    let taken = |expr: &str, combos: &[(&str, &str)]| -> bool {
        let out = preprocess(&format!("#if {expr}\nT\n#else\nF\n#endif\n"), combos).unwrap_or_else(|e| panic!("{expr}: {e}"));
        assert!(out.diagnostics.is_empty(), "{expr}: {:?}", out.diagnostics);
        kept(&out) == ["T"]
    };
    assert!(taken("TYPE == 1", &[("TYPE", "1")]));
    assert!(!taken("TYPE == 1", &[("TYPE", "0")]));
    assert!(taken("A && B > 2 || C", &[("A", "1"), ("B", "3")]));
    assert!(taken("!UNDEFINED_NAME", &[]));
    assert!(!taken("g_RuntimeName > 1", &[]));
    // Expressions made of preprocessor tokens that were refused stay refused: unbalanced
    // parentheses, `defined`, arithmetic (division by zero included), float literals.
    for expr in ["(TYPE == 1", "TYPE == 1)", "defined(A) && B > 2", "TYPE / 0", "1 +", "GAIN <= 2.5", "TYPE ? 1 : 0"] {
        let e = preprocess(&format!("#if {expr}\nT\n#endif\n"), &[("TYPE", "1"), ("A", "1"), ("B", "3"), ("GAIN", "2.5")]).expect_err(expr);
        assert!(e.contains("#if expression is unsupported"), "{expr}: {e}");
    }
}

#[test]
fn many_run_time_conditions_are_all_false_but_recorded_only_up_to_a_bound() {
    let mut text = String::new();
    for i in 0..200 {
        text.push_str(&format!("#if g_V.x > {i}\nA{i}\n#else\nB{i}\n#endif\n"));
    }
    let out = preprocess(&text, &[]).unwrap();
    assert_eq!(kept(&out).len(), 200);
    assert!(kept(&out).iter().all(|l| l.starts_with('B')));
    // One entry per condition up to the bound, then one that counts the rest.
    assert_eq!(out.diagnostics.len(), MAX_CONDITION_NOTES + 1);
    assert!(out.diagnostics.iter().all(|d| d.pass == Some(Pass::Preprocess)));
    assert!(out.diagnostics.last().unwrap().message.contains(&(200 - MAX_CONDITION_NOTES).to_string()));
}

#[test]
fn a_program_with_only_valid_conditions_has_no_preprocess_diagnostic() {
    let p = program_ok("varying vec2 v_TexCoord;\n#if 1\n#define K 1.0\n#endif\nvoid main() { gl_FragColor = vec4(K); }");
    assert!(p.diagnostics.iter().all(|d| d.pass != Some(Pass::Preprocess)), "{:?}", p.diagnostics);
}
