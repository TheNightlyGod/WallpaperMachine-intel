// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Helpers that keep failure text plain: no terminal colour codes or other
//! control characters (R71), and no unbounded echo of an offending value.

/// Longest echo of a user-supplied value inside a message, in characters.
const MAX_ECHO_CHARS: usize = 120;

/// Replaces control characters so that text can never carry terminal escape
/// sequences. Newlines survive (messages are multi-line); tabs become spaces
/// (so excerpt columns stay aligned); every other control character becomes `?`.
pub(crate) fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '\n' => '\n',
            '\t' => ' ',
            c if c.is_control() => '?',
            c => c,
        })
        .collect()
}

/// A user-supplied value for use inside a message: control characters
/// replaced, long values cut short, wrapped in backticks.
pub(crate) fn quote(s: &str) -> String {
    let mut out: String = s.chars().take(MAX_ECHO_CHARS).collect();
    if s.chars().nth(MAX_ECHO_CHARS).is_some() {
        out.push_str("...");
    }
    // Newlines inside a quoted value would break the one-line shape of messages.
    format!("`{}`", sanitize(&out).replace('\n', " "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_removes_escape_sequences_and_keeps_newlines() {
        assert_eq!(sanitize("a\u{1b}[31mred\u{1b}[0m\tb\nc\u{0}d\u{7f}"), "a?[31mred?[0m b\nc?d?");
        assert_eq!(sanitize("é\u{1F600}"), "é\u{1F600}");
    }

    #[test]
    fn quote_bounds_and_flattens() {
        assert_eq!(quote("ab"), "`ab`");
        assert_eq!(quote("a\nb"), "`a b`");
        let long = "x".repeat(500);
        let q = quote(&long);
        assert!(q.len() < 140 && q.ends_with("...`"));
        assert_eq!(quote(&"y".repeat(MAX_ECHO_CHARS)), format!("`{}`", "y".repeat(MAX_ECHO_CHARS)));
    }
}
