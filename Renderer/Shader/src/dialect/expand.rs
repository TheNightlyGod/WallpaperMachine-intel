// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Macro expansion of one stage's tokens.
//!
//! Wallpaper Engine's compiler expands macros before it looks at types, so
//! every type rule (R20, R101, R102, R104) is easiest to satisfy by expanding
//! them here, once, before parsing. The expander follows the usual rescanning
//! model: object-like and function-like macros, arguments expanded before they
//! are substituted, a name never re-expanded inside its own expansion, and a
//! function-like macro name that is not followed by `(` left alone. `#define`
//! and `#undef` lines are consumed in source order (a macro defined in a
//! function body applies from there on); other directives pass through.
//!
//! Tokens that come from a macro's replacement list take the span of the
//! invocation, so a diagnostic about expanded text points at the use. Tokens
//! that come from an argument keep their own span.

use std::collections::HashMap;
use std::rc::Rc;

use crate::lexer::{Operator, Token, TokenKind, lex};

/// A bound on the number of tokens the expander may produce for one stage.
pub const MAX_EXPANDED_TOKENS: usize = 1_000_000;

/// Why expansion stopped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExpandFailure {
    pub message: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Clone, Debug)]
struct Macro {
    params: Option<Vec<String>>,
    body: Vec<Token>,
}

type Hide = Rc<Vec<String>>;

#[derive(Clone, Debug)]
struct Q {
    tok: Token,
    hide: Hide,
}

/// How deeply invocations may nest inside the arguments of other invocations.
const MAX_ARGUMENT_DEPTH: usize = 64;

struct Expander {
    macros: HashMap<String, Macro>,
    produced: usize,
    depth: usize,
}

/// Expands every macro of `tokens` (a lexed stage). `#define` and `#undef` lines are removed.
pub fn expand(tokens: &[Token]) -> Result<Vec<Token>, ExpandFailure> {
    let empty: Hide = Rc::new(Vec::new());
    let input: Vec<Q> = tokens.iter().cloned().map(|tok| Q { tok, hide: empty.clone() }).collect();
    let mut expander = Expander { macros: HashMap::new(), produced: 0, depth: 0 };
    let out = expander.run(input, true)?;
    Ok(out.into_iter().map(|q| q.tok).collect())
}

/// Splits `#define` text into the macro name and definition.
fn parse_define(text: &str) -> Option<(String, Macro)> {
    let s = text.strip_prefix('#')?.trim_start();
    let s = s.strip_prefix("define")?;
    if !s.starts_with([' ', '\t']) {
        return None;
    }
    let s = s.trim_start_matches([' ', '\t']);
    let name_len = s.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
    if name_len == 0 || s.as_bytes()[0].is_ascii_digit() {
        return None;
    }
    let name = s[..name_len].to_string();
    let rest = &s[name_len..];
    let (params, body_text) = if let Some(after) = rest.strip_prefix('(') {
        let close = after.find(')')?;
        let list = &after[..close];
        let mut params = Vec::new();
        if !list.trim().is_empty() {
            for p in list.split(',') {
                let p = p.trim();
                if p.is_empty() || !p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
                    return None;
                }
                params.push(p.to_string());
            }
        }
        (Some(params), &after[close + 1..])
    } else {
        (None, rest)
    };
    let joined = body_text.replace("\\\r\n", " ").replace("\\\n", " ");
    let body: Vec<Token> = lex(&joined)
        .into_vec()
        .into_iter()
        .filter(|t| !matches!(t.kind, TokenKind::Directive | TokenKind::Annotation))
        .collect();
    Some((name, Macro { params, body }))
}

fn undef_name(text: &str) -> Option<String> {
    let s = text.strip_prefix('#')?.trim_start().strip_prefix("undef")?;
    if !s.starts_with([' ', '\t']) {
        return None;
    }
    let s = s.trim_start_matches([' ', '\t']);
    let len = s.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
    (len > 0).then(|| s[..len].to_string())
}

impl Expander {
    fn run(&mut self, input: Vec<Q>, top: bool) -> Result<Vec<Q>, ExpandFailure> {
        let mut stack: Vec<Q> = input;
        stack.reverse();
        let mut out: Vec<Q> = Vec::new();
        while let Some(q) = stack.pop() {
            self.produced += 1;
            if self.produced > MAX_EXPANDED_TOKENS {
                return Err(ExpandFailure {
                    message: "macro expansion is too large".to_string(),
                    start: q.tok.start,
                    end: q.tok.end,
                });
            }
            match q.tok.kind {
                TokenKind::Directive if top => {
                    if let Some((name, mac)) = parse_define(&q.tok.text) {
                        self.macros.insert(name, mac);
                    } else if let Some(name) = undef_name(&q.tok.text) {
                        self.macros.remove(&name);
                    } else if is_version_line(&q.tok.text) {
                        // The stage is emitted under its own `#version` line.
                    } else {
                        out.push(q);
                    }
                }
                TokenKind::Identifier => {
                    let name = q.tok.text.clone();
                    if q.hide.contains(&name) || !self.macros.contains_key(&name) {
                        out.push(q);
                        continue;
                    }
                    let mac = self.macros[&name].clone();
                    match &mac.params {
                        None => {
                            // A macro defined with no replacement text and used alone as an array
                            // bound has the value 1 (`#define TAPS` then `[TAPS]` is `[1]`).
                            let bare_bound = mac.body.is_empty()
                                && out.last().is_some_and(|p| p.tok.is_left_bracket())
                                && stack.last().is_some_and(|n| n.tok.is_operator(Operator::RBracket));
                            if bare_bound {
                                let mut tok = q.tok.clone();
                                tok.kind = TokenKind::Number;
                                tok.text = "1".to_string();
                                out.push(Q { tok, hide: q.hide.clone() });
                                continue;
                            }
                            let hide = extend_hide(&q.hide, &name);
                            let span = (q.tok.start, q.tok.end);
                            let body = relocate(&mac.body, span, &hide, None);
                            stack.extend(body.into_iter().rev());
                        }
                        Some(params) => {
                            let Some((args, consumed, end)) = collect_args(&stack, params.len()) else {
                                out.push(q);
                                continue;
                            };
                            let new_len = stack.len() - consumed;
                            stack.truncate(new_len);
                            let mut expanded_args = Vec::with_capacity(args.len());
                            if self.depth >= MAX_ARGUMENT_DEPTH {
                                return Err(ExpandFailure {
                                    message: "macro invocations nest too deeply".to_string(),
                                    start: q.tok.start,
                                    end: q.tok.end,
                                });
                            }
                            self.depth += 1;
                            for arg in args {
                                match self.run(arg, false) {
                                    Ok(done) => expanded_args.push(done),
                                    Err(e) => {
                                        self.depth -= 1;
                                        return Err(e);
                                    }
                                }
                            }
                            self.depth -= 1;
                            let hide = extend_hide(&q.hide, &name);
                            let span = (q.tok.start, end.max(q.tok.end));
                            let body = relocate(&mac.body, span, &hide, Some((params, &expanded_args)));
                            stack.extend(body.into_iter().rev());
                        }
                    }
                }
                _ => out.push(q),
            }
        }
        Ok(out)
    }
}

fn is_version_line(text: &str) -> bool {
    text.strip_prefix('#').is_some_and(|s| s.trim_start().starts_with("version"))
}

fn extend_hide(hide: &Hide, name: &str) -> Hide {
    let mut v: Vec<String> = hide.as_ref().clone();
    v.push(name.to_string());
    Rc::new(v)
}

/// Builds the replacement of one invocation: body tokens take the invocation span and the
/// extended hide set; parameter names are replaced by the (already expanded) arguments.
fn relocate(body: &[Token], span: (usize, usize), hide: &Hide, subst: Option<(&[String], &[Vec<Q>])>) -> Vec<Q> {
    let mut out = Vec::with_capacity(body.len());
    for t in body {
        if t.kind == TokenKind::Identifier
            && let Some((params, args)) = subst
                && let Some(i) = params.iter().position(|p| *p == t.text) {
                    for a in &args[i] {
                        let mut h = a.hide.as_ref().clone();
                        for n in hide.iter() {
                            if !h.contains(n) {
                                h.push(n.clone());
                            }
                        }
                        out.push(Q { tok: a.tok.clone(), hide: Rc::new(h) });
                    }
                    continue;
                }
        let mut tok = t.clone();
        tok.start = span.0;
        tok.end = span.1;
        out.push(Q { tok, hide: hide.clone() });
    }
    out
}

/// Reads the arguments of an invocation from the top of the (reversed) stack. Returns the
/// argument lists, how many stack entries the invocation consumed, and the end offset of the
/// closing parenthesis. `None` when no `(` follows or the argument count does not match.
fn collect_args(stack: &[Q], param_count: usize) -> Option<(Vec<Vec<Q>>, usize, usize)> {
    let mut i = stack.len();
    let open = stack.get(i.checked_sub(1)?)?;
    if !open.tok.is_left_paren() {
        return None;
    }
    i -= 1;
    let mut depth = 1usize;
    let mut args: Vec<Vec<Q>> = vec![Vec::new()];
    let mut consumed = 1usize;
    loop {
        i = i.checked_sub(1)?;
        let q = &stack[i];
        consumed += 1;
        match q.tok.kind {
            TokenKind::Operator(Operator::LParen) => depth += 1,
            TokenKind::Operator(Operator::RParen) => {
                depth -= 1;
                if depth == 0 {
                    let end = q.tok.end;
                    if param_count == 0 && args.len() == 1 && args[0].is_empty() {
                        return Some((Vec::new(), consumed, end));
                    }
                    if args.len() != param_count {
                        return None;
                    }
                    return Some((args, consumed, end));
                }
            }
            TokenKind::Comma if depth == 1 => {
                args.push(Vec::new());
                continue;
            }
            _ => {}
        }
        args.last_mut().unwrap().push(q.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(src: &str) -> String {
        let tokens = lex(src);
        let out = expand(&tokens).unwrap();
        out.iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn object_like_macros_expand_and_rescan() {
        assert_eq!(run("#define A 1\n#define B A + A\nx = B ;"), "x = 1 + 1 ;");
        assert_eq!(run("#define E\nx E y"), "x y");
        assert_eq!(run("#define A B\n#define B 2\nA"), "2");
    }

    #[test]
    fn a_bare_macro_used_alone_as_an_array_bound_is_one() {
        assert_eq!(run("#define TAPS 6\n#define TAPS\nfloat a[TAPS];"), "float a [ 1 ] ;");
        assert_eq!(run("#define E\n#define A E\nfloat a[A];"), "float a [ 1 ] ;");
        // Anywhere else an empty macro is still empty.
        assert_eq!(run("#define E\nfloat a[E + 2]; E x"), "float a [ + 2 ] ; x");
        assert_eq!(run("#define E\nfloat a[2 E];"), "float a [ 2 ] ;");
    }

    #[test]
    fn function_like_macros_take_arguments() {
        assert_eq!(run("#define F(a, b) a * b\nF(x + 1, f(2, 3));"), "x + 1 * f ( 2 , 3 ) ;");
        assert_eq!(run("#define Z() 7\nZ() Z ()"), "7 7");
        assert_eq!(run("#define F(a) a\nF"), "F");
        assert_eq!(run("#define F(a, b) a\nF(1)"), "F ( 1 )");
    }

    #[test]
    fn a_macro_is_not_expanded_inside_itself() {
        assert_eq!(run("#define A A + 1\nA"), "A + 1");
        assert_eq!(run("#define F(x) F(x)\nF(1)"), "F ( 1 )");
        assert_eq!(run("#define X Y\n#define Y X\nX"), "X");
    }

    #[test]
    fn arguments_are_expanded_before_substitution_and_a_name_alias_takes_following_arguments() {
        assert_eq!(run("#define N 3\n#define F(a) a + a\nF(N)"), "3 + 3");
        assert_eq!(run("#define FN lerp\nFN(a, b, t)"), "lerp ( a , b , t )");
        assert_eq!(run("#define G(a) a\n#define H G\nH(5)"), "5");
    }

    #[test]
    fn define_and_undef_apply_in_order_and_other_directives_pass_through() {
        assert_eq!(run("#define A 1\nA\n#undef A\nA\n#define A 2\nA"), "1 A 2");
        assert_eq!(run("#extension GL_X : enable\nx").trim(), "#extension GL_X : enable x");
        assert_eq!(run("#version 450\nx"), "x");
    }

    #[test]
    fn continued_definitions_join_their_lines() {
        assert_eq!(run("#define M(a) \\\n  a + \\\n  1\nM(x)"), "x + 1");
    }

    #[test]
    fn replacement_tokens_take_the_span_of_the_use() {
        let src = "#define K 12\nint a = K;";
        let tokens = lex(src);
        let out = expand(&tokens).unwrap();
        let twelve = out.iter().find(|t| t.text == "12").unwrap();
        assert_eq!(&src[twelve.start..twelve.end], "K");
    }

    #[test]
    fn unterminated_invocations_and_arity_mismatches_are_left_alone() {
        assert_eq!(run("#define F(a) a\nF(1"), "F ( 1");
        assert_eq!(run("#define F(a) a\nF(1, 2)"), "F ( 1 , 2 )");
    }

    #[test]
    fn nested_parentheses_inside_arguments_do_not_split_them() {
        assert_eq!(run("#define F(a, b) [a|b]\nF((1, 2), 3)"), "[ ( 1 , 2 ) | 3 ]");
    }

    #[test]
    fn explosive_expansion_is_bounded() {
        let mut src = String::from("#define A0 x x\n");
        for i in 1..40 {
            src.push_str(&format!("#define A{i} A{} A{}\n", i - 1, i - 1));
        }
        src.push_str("A39\n");
        let tokens = lex(&src);
        let err = expand(&tokens).unwrap_err();
        assert!(err.message.contains("too large"));
    }
}
