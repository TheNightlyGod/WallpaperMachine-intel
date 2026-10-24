// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The dialect front end must never panic, overflow the stack or hang on hostile or garbled
// text: the answer is converted text or diagnostics. Inputs come from a fixed seed so a failure
// reproduces. Deep inputs run on a thread with a small stack, the worst case an engine thread
// may have.

use wm_shader::StageKind;
use wm_shader::dialect::convert_stage;

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
    "{", "}", "(", ")", "[", "]", ";", ",", ".", "=", "+", "-", "*", "/", "%", "?", ":", "!", "~", "&&", "||", "<", ">", "<<=", "%=",
    "++", "--", "uniform", "varying", "attribute", "layout(location = 0)", "struct", "float", "vec3", "vec2", "float3", "int", "uint",
    "bool", "mat4", "mat4x3", "sampler2D", "sampler3D", "void", "main", "if", "else", "for", "while", "do", "return", "discard", "break",
    "const", "in", "out", "inout", "g_Texture0", "x", "y", "z", "xy", "rgb", "1", "2.5", "1u", "0.5f", "\"str\"", "`", "@", "\\",
    "mul", "saturate", "lerp", "frac", "fmod", "CAST3", "CAST3X3", "CASTU", "clip", "inverse", "texSample2D", "texSample3D", "smoothstep",
    "mix", "step", "pow", "dot", "gl_FragColor", "gl_VertexID", "sample", "DECLARE_SAMPLER2D_PARAMETER", "MAKE_SAMPLER2D_ARGUMENT",
    "#define A 1", "#define F(a) a", "#undef A", "#extension GL_X : enable", "#define", "A", "F", "// {\"default\":1}", "/* c */",
];

fn generate(rng: &mut Lcg) -> String {
    let n = 1 + (rng.next() % 80) as usize;
    let mut out = String::new();
    for _ in 0..n {
        out.push_str(rng.pick(PIECES));
        out.push_str(rng.pick(&[" ", " ", "\n", "", "\t"]));
    }
    out
}

/// Runs `f` on a thread with a 2 MiB stack so a runaway recursion fails the test, not the process.
fn on_small_stack<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    std::thread::Builder::new().stack_size(2 * 1024 * 1024).spawn(f).unwrap().join().expect("the conversion panicked or overflowed")
}

#[test]
fn garbled_text_never_panics_in_the_dialect_front_end() {
    on_small_stack(|| {
        let mut rng = Lcg(0xd1a1_ec7f_0123_4567);
        let (mut ok, mut failed) = (0, 0);
        let iterations: usize = std::env::var("WM_SHADER_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(6000);
        for _ in 0..iterations {
            let text = generate(&mut rng);
            for kind in [StageKind::Fragment, StageKind::Vertex] {
                match convert_stage(kind, &text) {
                    Ok(c) => {
                        ok += 1;
                        // what comes out converts again without failing for a new reason
                        let _ = convert_stage(kind, &c.text);
                    }
                    Err(d) => {
                        failed += 1;
                        assert!(!d.is_empty());
                        for x in &d {
                            assert!(!x.message.contains('\u{1b}'));
                            if let Some(s) = x.span {
                                assert!(s.is_within(&text), "span outside the text: {s:?} in {text:?}");
                            }
                        }
                    }
                }
            }
        }
        eprintln!("converted {ok}, rejected {failed}");
        assert!(ok > 0 && failed > 0);
    });
}

#[test]
fn hostile_shapes_are_handled_in_bounded_time_and_stack() {
    let started = std::time::Instant::now();
    let deep_parens = format!("void main() {{ float x = {}1{}; }}", "(".repeat(50_000), ")".repeat(50_000));
    let deep_blocks = format!("void main() {}{}", "{".repeat(50_000), "}".repeat(50_000));
    let deep_ifs = format!("void main() {{ {} x = 1; }}", "if (a) ".repeat(50_000));
    let long_sum = format!("void main() {{ float a = {}; }}", (0..60_000).map(|i| format!("f{i}")).collect::<Vec<_>>().join(" + "));
    let long_statement = format!("void main() {{ float a = {}; }}", (0..30_000).map(|i| format!("f({i}, g({i}))")).collect::<Vec<_>>().join(" + "));
    let nested_calls = format!("void main() {{ float a = {}x{}; }}", "f(".repeat(20_000), ")".repeat(20_000));
    let swizzle_chain = format!("void main() {{ float a = v{}; }}", ".x".repeat(50_000));
    let index_chain = format!("void main() {{ float a = v{}; }}", "[0]".repeat(50_000));
    let ternaries = format!("void main() {{ float a = {} 1.0 {}; }}", "c ? 1.0 : (".repeat(5_000), ")".repeat(5_000));
    let many_declarators = format!("void main() {{ float {}; }}", (0..60_000).map(|i| format!("v{i}")).collect::<Vec<_>>().join(", "));
    let macro_chain: String = (0..5000).map(|i| format!("#define M{i} M{}\n", i + 1)).collect::<String>() + "#define M5000 1\nvoid main() { float a = M0; }";
    let macro_nesting = "#define F(x) x\n".to_string() + &format!("void main() {{ float a = {}1{}; }}", "F(".repeat(30_000), ")".repeat(30_000));
    let macro_bomb = {
        let mut s = String::from("#define A0 x x\n");
        for i in 1..40 {
            s.push_str(&format!("#define A{i} A{} A{}\n", i - 1, i - 1));
        }
        s + "void main() { float a = A39; }"
    };
    let unterminated = "void main() { float a = f(".repeat(10_000);
    let inputs = vec![
        deep_parens, deep_blocks, deep_ifs, long_sum, long_statement, nested_calls, swizzle_chain, index_chain, ternaries, many_declarators,
        macro_chain, macro_nesting, macro_bomb, unterminated,
    ];
    on_small_stack(move || {
        for (i, text) in inputs.iter().enumerate() {
            for kind in [StageKind::Fragment, StageKind::Vertex] {
                let t0 = std::time::Instant::now();
                let _ = convert_stage(kind, text);
                eprintln!("input {i} ({kind:?}): {:?}", t0.elapsed());
            }
        }
    });
    assert!(started.elapsed().as_secs() < 60, "took {:?}", started.elapsed());
}

#[test]
fn a_legitimately_deep_shader_still_converts() {
    // 64 nested parentheses and a long else-if chain are well inside the bounds (E16)
    let parens = format!("float f(float x) {{ return {}x{}; }}\nvoid main() {{ gl_FragColor = vec4(f(1.0)); }}", "(".repeat(64), ")".repeat(64));
    let chain: String = (0..60).map(|i| format!("if (x == {i}.0) {{ r = {i}.0; }} else ")).collect::<String>() + "{ r = 0.0; }";
    let ladder = format!("varying float x;\nvoid main() {{ float r; {chain} gl_FragColor = vec4(r); }}");
    let sum = format!("uniform float u;\nvoid main() {{ float a = {}; gl_FragColor = vec4(a); }}", (0..200).map(|_| "u").collect::<Vec<_>>().join(" + "));
    on_small_stack(move || {
        for (name, src) in [("parens", parens), ("ladder", ladder), ("sum", sum)] {
            convert_stage(StageKind::Fragment, &src).unwrap_or_else(|d| panic!("{name}: {d:?}"));
        }
    });
}
