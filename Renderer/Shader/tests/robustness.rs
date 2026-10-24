// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The front end must never panic or hang on hostile or garbled text: whatever
// comes in, the answer is a value or a plain error. Inputs are generated
// from a fixed seed so a failure reproduces.

use wm_shader::facts::Facts;
use wm_shader::items::{BraceMode, scan_items};
use wm_shader::lexer::lex;
use wm_shader::prepare::prepare_program;
use wm_shader::preprocess::{Mode, preprocess_stage};
use wm_shader::source::{MemorySource, NoIncludes};
use wm_shader::{Combo, ShaderRequest, Stage, StageKind};

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[(self.next() as usize) % items.len()]
    }
}

const PIECES: &[&str] = &[
    "{", "}", "(", ")", "[", "]", ";", ",", ".", "=", "+", "-", "*", "/", "%", "?", ":", "!", "~", "&&", "||", "<", ">", "<<=",
    "++", "uniform", "varying", "attribute", "layout", "struct", "float", "vec3", "sampler2D", "void", "main", "if", "else",
    "for", "while", "do", "return", "g_Texture0", "g_Texture40", "x", "y", "1", "2.5", "0x1F", "\"str\"", "\"open", "`", "@",
    "#if X", "#if", "#ifdef Y", "#ifndef Z", "#elif Q", "#else", "#endif", "#define A 1", "#define", "#undef A", "#include \"a.h\"",
    "#include \"b.h\"", "#include", "#require LightingV1", "#pragma once", "// {\"default\":1}", "// {\"combo\":\"C\",\"default\":2}",
    "// [COMBO] {\"combo\":\"D\",\"default\":3}", "// [COMBO] {", "// {\"material\":\"m\"}", "/* c */", "/*", "\\", "é",
];

fn generate(rng: &mut Lcg) -> String {
    let n = 1 + (rng.next() % 60) as usize;
    let mut out = String::new();
    for _ in 0..n {
        out.push_str(rng.pick(PIECES));
        out.push_str(rng.pick(&[" ", " ", "\n", "\r\n", "", "\t"]));
    }
    out
}

fn includes() -> MemorySource {
    MemorySource::new().with("a.h", "uniform float g_A; // {\"default\":1}\n#if X\n{\n#endif\n").with("b.h", "#include \"a.h\"\n#include \"b.h\"\n")
}

#[test]
fn garbled_text_never_panics_anywhere_in_the_front_end() {
    let mut rng = Lcg(0x5eed_1234_abcd_ef01);
    let inc = includes();
    let combos = [Combo { name: "X".into(), value: "1".into() }, Combo { name: "LIGHTING".into(), value: "1".into() }];
    let (mut ok_prepare, mut failed_prepare) = (0, 0);
    for _ in 0..4000 {
        let text = generate(&mut rng);
        let tokens = lex(&text);
        for t in &tokens {
            assert!(text.is_char_boundary(t.start) && text.is_char_boundary(t.end));
        }
        let facts = Facts::analyze(&tokens);
        let _ = facts.summaries().count();
        for mode in [BraceMode::Compiled, BraceMode::Conditional] {
            let _ = scan_items(&tokens, &text, mode);
        }
        for mode in [Mode::Evaluated, Mode::MetadataPreserving] {
            if let Ok(out) = preprocess_stage(StageKind::Fragment, &text, &combos, &inc, mode) {
                let t = lex(&out.text);
                let _ = Facts::analyze(&t);
                let _ = scan_items(&t, &out.text, BraceMode::Conditional);
            }
        }
        let request = ShaderRequest {
            shader_name: "fuzz".into(),
            stages: vec![
                Stage { kind: StageKind::Vertex, source: text.clone() },
                Stage { kind: StageKind::Fragment, source: generate(&mut rng) },
            ],
            combos: combos.to_vec(),
            ..ShaderRequest::default()
        }
        .validate()
        .unwrap();
        match prepare_program(&request, &inc) {
            Ok(_) => ok_prepare += 1,
            Err(e) => {
                failed_prepare += 1;
                assert!(!e.to_string().contains('\u{1b}'));
            }
        }
    }
    eprintln!("prepared {ok_prepare}, rejected {failed_prepare}");
    assert!(ok_prepare > 0 && failed_prepare > 0);
}

#[test]
fn hostile_shapes_are_handled_in_bounded_time() {
    let started = std::time::Instant::now();
    let deep_parens = format!("float x = {}1{};", "(".repeat(50_000), ")".repeat(50_000));
    let deep_blocks = format!("void main() {}{}", "{".repeat(50_000), "}".repeat(50_000));
    let many_openers = "(".repeat(100_000);
    let long_statement = format!("float a = {};", (0..30_000).map(|i| format!("f({i}, g({i}))")).collect::<Vec<_>>().join(" + "));
    let many_ifs = "#if 1\n".repeat(20_000) + &"#endif\n".repeat(20_000);
    let long_line = "a ".repeat(200_000);
    let open_comments = "/* ".repeat(100_000);
    let structs = "struct ".repeat(100_000);
    let braces_after_words = "a ".repeat(50_000) + "{ " + &"b ".repeat(50_000) + "}";
    let nested_calls = format!("{}x{};", "f(".repeat(20_000), ")".repeat(20_000));
    let many_defines_chain: String = (0..5000).map(|i| format!("#define M{i} M{}\n", i + 1)).collect::<String>() + "#define M5000 1\n#if M0 == 1\nx\n#endif\n";
    for text in [
        &deep_parens,
        &deep_blocks,
        &many_openers,
        &long_statement,
        &many_ifs,
        &long_line,
        &open_comments,
        &structs,
        &braces_after_words,
        &nested_calls,
        &many_defines_chain,
    ] {
        let tokens = lex(text);
        let _ = Facts::analyze(&tokens);
        let _ = scan_items(&tokens, text, BraceMode::Compiled);
        let _ = scan_items(&tokens, text, BraceMode::Conditional);
        let _ = preprocess_stage(StageKind::Vertex, text, &[], &NoIncludes, Mode::Evaluated);
        let _ = preprocess_stage(StageKind::Vertex, text, &[], &NoIncludes, Mode::MetadataPreserving);
    }
    assert!(started.elapsed().as_secs() < 30, "took {:?}", started.elapsed());
}
