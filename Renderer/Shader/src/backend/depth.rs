// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! A bound on how much stack the downstream compiler needs for a stage (spec A R91).
//!
//! naga reads, validates and writes expressions and statements recursively, so a text that nests
//! brackets or chains operators thousands deep overflows the small stack of an engine worker
//! thread (512 KiB). The layer may not create a thread of its own (R89) and may not crash (R91),
//! so the text is measured first and a text that is too deep is a normal failure.
//!
//! The measure adds up what is open at the deepest point of the text: each open bracket weighs
//! what its recursion costs (a block more than a parenthesis), each operator or member access
//! in an expression that is still being read weighs one, because a chain of them is a tree as
//! deep as it is long, and each statement whose body has not ended weighs [`STATEMENT_WEIGHT`]:
//! `if`, `for`, `while`, `switch` and `do` heads, and the `else` links of a chain, which nest one
//! statement inside the next without any bracket (`if (a) if (b) ... x;`). A statement ends at
//! the `;` or the closing `}` that ends its body, unless an `else` follows. Measured against
//! naga 29.0.3 in a release build on a 512 KiB stack, one unit is about a kilobyte of stack in the
//! worst of the shapes tried (nested blocks, nested calls, ternaries, sums, unary chains, swizzle
//! chains, unbraced statements), so [`STACK_BUDGET`] leaves most of the stack to the callers.
//! Shipped and workshop shaders stay far below it.
//!
//! Nesting of types is the other recursion: a structure that contains a structure that contains
//! one ... is read recursively by the compiler without a single open bracket, so
//! [`struct_depth`] measures it separately against [`STRUCT_DEPTH_LIMIT`].

/// The most the measure may reach.
pub const STACK_BUDGET: u32 = 128;

/// The deepest nesting of structure types the layer accepts (real shaders nest two or three).
pub const STRUCT_DEPTH_LIMIT: u32 = 64;

const BLOCK_WEIGHT: u32 = 4;
const GROUP_WEIGHT: u32 = 3;
/// A statement head (`if`, `for`, `while`, `switch`, `do`) or an `else` link whose body has not
/// ended: nested statements without any bracket in between still nest in the compiler.
pub const STATEMENT_WEIGHT: u32 = 3;

struct Level {
    weight: u32,
    /// Operators seen in the expression this level is reading now.
    chain: u32,
    /// Statement heads and `else` links of this level whose body has not ended, in units.
    pending: u32,
    /// `do` statements of this level still waiting for their `while`, in units.
    dos: u32,
}

impl Level {
    fn new(weight: u32) -> Level {
        Level { weight, chain: 0, pending: 0, dos: 0 }
    }

    /// What this level still holds when it closes.
    fn held(&self) -> u32 {
        self.weight + self.chain + self.pending + self.dos
    }
}

/// Whether the next word after `from` (comments and white space skipped) is `else`.
fn else_follows(bytes: &[u8], from: usize) -> bool {
    let mut i = from;
    while i < bytes.len() {
        match bytes[i] {
            b if b.is_ascii_whitespace() => i += 1,
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i < bytes.len() && !(bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/')) {
                    i += 1;
                }
                i += 2;
            }
            _ => break,
        }
    }
    bytes[i.min(bytes.len())..].starts_with(b"else")
        && !bytes.get(i + 4).is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_')
}

/// The measure of `glsl`: the largest total of open weights and expression chains at any point.
pub fn stack_cost(glsl: &str) -> u32 {
    let bytes = glsl.as_bytes();
    let mut levels = vec![Level::new(0)];
    let mut total = 0u32;
    let mut worst = 0u32;
    // Whether the previous significant byte ends an operand (so a `.` is a member access).
    let mut after_operand = false;
    // Whether the previous significant token was `else`, so that `if` continues the chain.
    let mut after_else = false;
    // Whether the previous significant token ended a statement (`;` or `}`).
    let mut boundary = false;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i < bytes.len() && !(bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/')) {
                    i += 1;
                }
                i += 2;
                continue;
            }
            b if b.is_ascii_whitespace() => {
                i += 1;
                continue;
            }
            b'0'..=b'9' => {
                i = number_end(bytes, i);
                after_operand = true;
                boundary = false;
                continue;
            }
            b'.' if !after_operand && bytes.get(i + 1).is_some_and(u8::is_ascii_digit) => {
                i = number_end(bytes, i);
                after_operand = true;
                boundary = false;
                continue;
            }
            b if b.is_ascii_alphabetic() || b == b'_' => {
                let start = i;
                while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                    i += 1;
                }
                let word = &bytes[start..i];
                let was_boundary = std::mem::take(&mut boundary);
                let level = levels.last_mut().expect("the outer level stays");
                let mut charge = |level: &mut Level, units: u32, to_dos: bool| {
                    if to_dos {
                        level.dos += units;
                    } else {
                        level.pending += units;
                    }
                    total = total.saturating_add(units);
                    worst = worst.max(total);
                };
                match word {
                    b"else" => charge(level, STATEMENT_WEIGHT, false),
                    // `if` right after `else` is the same link of the chain.
                    b"if" if after_else => {}
                    b"if" | b"for" | b"switch" => charge(level, STATEMENT_WEIGHT, false),
                    b"do" => charge(level, STATEMENT_WEIGHT, true),
                    b"while" if was_boundary && level.dos > 0 => {
                        // The `while` that closes a `do` statement.
                        level.dos -= STATEMENT_WEIGHT;
                        total = total.saturating_sub(STATEMENT_WEIGHT);
                    }
                    b"while" => charge(level, STATEMENT_WEIGHT, false),
                    _ => {}
                }
                after_else = word == b"else";
                after_operand = true;
                continue;
            }
            b'{' | b'(' | b'[' => {
                after_else = false;
                boundary = false;
                let weight = if b == b'{' { BLOCK_WEIGHT } else { GROUP_WEIGHT };
                levels.push(Level::new(weight));
                total = total.saturating_add(weight);
                after_operand = false;
            }
            b'}' | b')' | b']' => {
                after_else = false;
                if levels.len() > 1 {
                    let level = levels.pop().expect("more than the outer level");
                    total = total.saturating_sub(level.held());
                }
                after_operand = true;
                boundary = b == b'}';
                if boundary {
                    end_statements(&mut levels, &mut total, bytes, i + 1);
                }
            }
            b',' | b';' => {
                after_else = false;
                let level = levels.last_mut().expect("the outer level stays");
                total = total.saturating_sub(level.chain);
                level.chain = 0;
                after_operand = false;
                boundary = b == b';';
                if boundary {
                    end_statements(&mut levels, &mut total, bytes, i + 1);
                }
            }
            b'+' | b'-' | b'*' | b'/' | b'%' | b'<' | b'>' | b'=' | b'!' | b'~' | b'&' | b'|' | b'^' | b'?' | b':'
            | b'.' => {
                let level = levels.last_mut().expect("the outer level stays");
                after_else = false;
                boundary = false;
                level.chain += 1;
                total = total.saturating_add(1);
                // `++` and `--` end an operand when postfix; either way the next byte decides nothing.
                after_operand = false;
            }
            _ => {
                after_else = false;
                after_operand = false;
                boundary = false;
            }
        }
        worst = worst.max(total);
        i += 1;
    }
    worst
}

/// A statement ended at `;` or `}` just before `next`: the heads and `else` links of the current
/// level are done, unless an `else` follows and continues the chain.
fn end_statements(levels: &mut [Level], total: &mut u32, bytes: &[u8], next: usize) {
    let level = levels.last_mut().expect("the outer level stays");
    if level.pending > 0 && !else_follows(bytes, next) {
        *total = total.saturating_sub(level.pending);
        level.pending = 0;
    }
}

/// The deepest chain of structure types that contain one another (a structure with no structure
/// member is 1), read from the text. Members refer to structures declared before them, so one
/// pass suffices; a name read in a member list that is not a known structure is not one.
pub fn struct_depth(glsl: &str) -> u32 {
    use std::collections::HashMap;
    let bytes = glsl.as_bytes();
    let mut depths: HashMap<&str, u32> = HashMap::new();
    let mut deepest = 0u32;
    // The words of the text outside comments, and the two braces of a member list.
    let mut words: Vec<&str> = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
        } else if b == b'/' && bytes.get(i + 1) == Some(&b'*') {
            i += 2;
            while i < bytes.len() && !(bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/')) {
                i += 1;
            }
            i += 2;
        } else if b.is_ascii_alphabetic() || b == b'_' {
            let start = i;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            words.push(&glsl[start..i]);
        } else if b == b'{' || b == b'}' {
            words.push(if b == b'{' { "{" } else { "}" });
            i += 1;
        } else {
            i += 1;
        }
    }
    let mut w = 0;
    while w < words.len() {
        if words[w] == "struct"
            && let Some(&name) = words.get(w + 1)
            && words.get(w + 2) == Some(&"{")
        {
            let mut inner = 0u32;
            let mut j = w + 3;
            while j < words.len() && words[j] != "}" {
                if let Some(d) = depths.get(words[j]) {
                    inner = inner.max(*d);
                }
                j += 1;
            }
            let depth = inner.saturating_add(1);
            depths.insert(name, depth);
            deepest = deepest.max(depth);
            w = j;
        }
        w += 1;
    }
    deepest
}

/// The end of the numeric literal that starts at `start`: digits, letters (suffixes, hex), dots,
/// and a sign right after an exponent.
fn number_end(bytes: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        let exponent_sign = (b == b'+' || b == b'-')
            && i > start
            && matches!(bytes[i - 1], b'e' | b'E')
            && !bytes[start..i].starts_with(b"0x")
            && !bytes[start..i].starts_with(b"0X");
        if b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || exponent_sign {
            i += 1;
        } else {
            break;
        }
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_shaders_measure_small() {
        let text = "#version 450\nvoid main() {\n  float a = (1.0 + 2.0) * g(3.0, 4.0); // (((((\n  /* {{{{ */ gl_Position = vec4(a);\n}\n";
        assert!(stack_cost(text) < 20, "{}", stack_cost(text));
    }

    #[test]
    fn nesting_adds_up_by_weight() {
        assert_eq!(stack_cost("{((["), BLOCK_WEIGHT + 2 * GROUP_WEIGHT + GROUP_WEIGHT);
        assert_eq!(stack_cost("{{{{}}}}"), 4 * BLOCK_WEIGHT);
        // closed levels no longer count
        assert_eq!(stack_cost("(((())))((()))"), 4 * GROUP_WEIGHT);
    }

    #[test]
    fn chains_count_while_the_expression_is_open_and_reset_at_its_end() {
        assert_eq!(stack_cost("a+b+c+d;"), 3);
        assert_eq!(stack_cost("a+b; c+d+e;"), 2);
        assert_eq!(stack_cost("f(a+b, c+d)"), GROUP_WEIGHT + 1);
        // an operator before an open bracket stays part of the depth
        assert_eq!(stack_cost("a+(b+(c+d))"), 1 + GROUP_WEIGHT + 1 + GROUP_WEIGHT + 1);
        assert_eq!(stack_cost("v.x.y.z"), 3);
    }

    #[test]
    fn an_else_if_chain_counts_by_link_and_separate_statements_do_not_add_up() {
        let chain = |links: usize| format!("if (a) {{ x; }}{}", " else if (b) { y; }".repeat(links));
        assert_eq!(stack_cost(&chain(10)) - stack_cost(&chain(9)), STATEMENT_WEIGHT);
        assert!(stack_cost(&chain(300)) > STACK_BUDGET);
        let sequence = "if (a) { x; } else { y; } ".repeat(500);
        assert!(stack_cost(&sequence) < 2 * BLOCK_WEIGHT + 2 * STATEMENT_WEIGHT + 2 * GROUP_WEIGHT, "{}", stack_cost(&sequence));
    }

    #[test]
    fn statements_nested_without_brackets_add_up_until_their_body_ends() {
        let nest = |head: &str, n: usize| format!("void main() {{ float x = 0.0; {}x = 1.0; }}", format!("{head} ").repeat(n));
        for head in ["if (x < 5.0)", "for (;;)", "while (x < 1.0)", "switch (1)", "do"] {
            let (shallow, deep) = (stack_cost(&nest(head, 10)), stack_cost(&nest(head, 11)));
            assert_eq!(deep - shallow, STATEMENT_WEIGHT, "{head}");
            assert!(stack_cost(&nest(head, 300)) > STACK_BUDGET, "{head}");
        }
        // the body ends at its `;`: the statements that follow do not stack up
        let sequence = "if (x < 5.0) x = 1.0; for (;;) x = 2.0; while (x < 1.0) x = 3.0; ".repeat(300);
        assert!(stack_cost(&sequence) < 4 * STATEMENT_WEIGHT + 2 * GROUP_WEIGHT, "{}", stack_cost(&sequence));
    }

    #[test]
    fn an_unbraced_else_chain_counts_by_link_until_the_chain_ends() {
        let chain = |links: usize| format!("if (x < 0.0) x = 1.0; {}", "else if (x < 5.0) x = 2.0; ".repeat(links));
        assert_eq!(stack_cost(&chain(10)) - stack_cost(&chain(9)), STATEMENT_WEIGHT);
        assert!(stack_cost(&chain(300)) > STACK_BUDGET);
        let plain = |links: usize| format!("if (x < 5.0) x = 3.0; {}", "else ".repeat(links));
        assert!(stack_cost(&format!("{}x = 1.0;", plain(300))) > STACK_BUDGET);
        // an `else` after a comment still continues the chain, and a later separate chain starts over
        let spaced = "if (a) x = 1.0; // note\n /* more */ else x = 2.0; ".repeat(300);
        assert!(stack_cost(&spaced) < 4 * STATEMENT_WEIGHT + 2 * GROUP_WEIGHT, "{}", stack_cost(&spaced));
    }

    #[test]
    fn do_while_statements_release_their_weight_at_their_while() {
        let nested = |n: usize| format!("{}x = 1.0; {}", "do ".repeat(n), "while (x < 1.0); ".repeat(n));
        assert!(stack_cost(&nested(300)) > STACK_BUDGET);
        let sequence = "do { x = 1.0; } while (x < 1.0); ".repeat(300);
        assert!(stack_cost(&sequence) < 2 * STATEMENT_WEIGHT + BLOCK_WEIGHT + 2 * GROUP_WEIGHT, "{}", stack_cost(&sequence));
        // a `while` loop that is the body of a `do` is a head, not the tail
        let mixed = format!("{}x = 1.0;", "do while (x < 1.0) ".repeat(150));
        assert!(stack_cost(&mixed) > STACK_BUDGET);
    }

    #[test]
    fn structure_nesting_is_the_longest_chain_of_structs_in_structs() {
        let chain = |n: usize| {
            let mut text = String::from("struct S0 { float a; };\n");
            for i in 1..n {
                text.push_str(&format!("struct S{i} {{ S{} a; float b[2]; }};\n", i - 1));
            }
            text
        };
        assert_eq!(struct_depth(""), 0);
        assert_eq!(struct_depth(&chain(1)), 1);
        assert_eq!(struct_depth(&chain(5)), 5);
        assert!(struct_depth(&chain(2000)) > STRUCT_DEPTH_LIMIT);
        // wide is not deep; comments and unrelated words are not members
        let wide = "struct A { float a; }; struct B { A a; A b; A c; }; // struct C { B x; };\nstruct D { /* B */ float d; A e; };";
        assert_eq!(struct_depth(wide), 2);
        assert_eq!(struct_depth("struct P; struct Q { int x; } q; void f(struct Q y) {}"), 1);
    }

    #[test]
    fn numbers_and_comments_are_not_operators() {
        assert_eq!(stack_cost("a = 1.5e-3 + .5f + 0x1F + 2.0;"), 4);
        assert_eq!(stack_cost("a = 1.0; // + + + +\n b; /* - - - */"), 1);
    }

    #[test]
    fn unbalanced_text_does_not_underflow() {
        assert_eq!(stack_cost(")))]]]}}}"), 0);
        assert!(stack_cost("((((") > 0);
    }

    #[test]
    fn hostile_shapes_exceed_the_budget_and_ordinary_depth_does_not() {
        let deep = |open: &str, close: &str, n: usize| format!("{}x{}", open.repeat(n), close.repeat(n));
        assert!(stack_cost(&deep("(", ")", 1000)) > STACK_BUDGET);
        assert!(stack_cost(&deep("{", "}", 200)) > STACK_BUDGET);
        assert!(stack_cost(&deep("f(", ")", 200)) > STACK_BUDGET);
        assert!(stack_cost(&vec!["1.0"; 400].join("+")) > STACK_BUDGET);
        assert!(stack_cost(&"- ".repeat(400)) > STACK_BUDGET);
        assert!(stack_cost(&deep("(", ")", 20)) < STACK_BUDGET);
        assert!(stack_cost(&vec!["1.0"; 60].join("+")) < STACK_BUDGET);
    }
}
