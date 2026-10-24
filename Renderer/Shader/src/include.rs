// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The include model (spec 2.3, R17 to R22): path normalisation and validity,
//! and the include failures a compile can report. Fetching include text goes
//! through a caller-provided callback and belongs to the preprocessor.

use std::fmt;

use crate::text::{quote, sanitize};

/// Why an include path is rejected before the provider is asked for it (R18).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidPathClass {
    Empty,
    ContainsNul,
    /// Starts with `/` or `//` (a Windows share, `\\server`, normalises to this too).
    Absolute,
    /// Starts with a drive prefix such as `C:`.
    DrivePrefix,
    /// Has a `..` component.
    ParentComponent,
}

impl fmt::Display for InvalidPathClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            InvalidPathClass::Empty => "the path is empty",
            InvalidPathClass::ContainsNul => "the path contains a NUL character",
            InvalidPathClass::Absolute => "the path is absolute",
            InvalidPathClass::DrivePrefix => "the path starts with a drive prefix",
            InvalidPathClass::ParentComponent => "the path has a `..` component",
        })
    }
}

/// Backslashes become forward slashes. The path is not resolved against the including file (2.3).
pub fn normalize_include_path(path: &str) -> String {
    path.replace('\\', "/")
}

/// Checks a normalised include path (R18). The provider is never asked for a path that fails.
pub fn check_include_path(path: &str) -> Result<(), InvalidPathClass> {
    if path.is_empty() {
        return Err(InvalidPathClass::Empty);
    }
    if path.contains('\0') {
        return Err(InvalidPathClass::ContainsNul);
    }
    if path.starts_with('/') {
        return Err(InvalidPathClass::Absolute);
    }
    let bytes = path.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return Err(InvalidPathClass::DrivePrefix);
    }
    if path.split('/').any(|component| component == "..") {
        return Err(InvalidPathClass::ParentComponent);
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IncludeErrorKind {
    NotFound,
    /// The provider returned a null pointer with a non-zero length.
    Unreadable { len: usize },
    NotUtf8,
    /// The chain of paths from the first include back to the repeated one (`a -> b -> a`).
    Cycle { chain: Vec<String> },
    InvalidPath(InvalidPathClass),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IncludeError {
    pub path: String,
    pub kind: IncludeErrorKind,
}

impl fmt::Display for IncludeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The wording of R9 for the three provider failures.
        let path = sanitize(&self.path).replace('\n', " ");
        let text = match &self.kind {
            IncludeErrorKind::NotFound => format!("shader include not found: {path}"),
            IncludeErrorKind::Unreadable { len } => format!(
                "shader source read failed for {path}: the provider returned a null pointer with a non-zero length ({len})"
            ),
            IncludeErrorKind::NotUtf8 => format!("shader source utf-8 invalid for {path}"),
            IncludeErrorKind::Cycle { chain } => {
                format!("include cycle: {}", chain.iter().map(|p| sanitize(p)).collect::<Vec<_>>().join(" -> "))
            }
            IncludeErrorKind::InvalidPath(class) => format!("#include path {} is invalid: {class}", quote(&self.path)),
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for IncludeError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backslashes_are_normalised_without_resolving() {
        assert_eq!(normalize_include_path("common\\blur.h"), "common/blur.h");
        assert_eq!(normalize_include_path("a/b.h"), "a/b.h");
        assert_eq!(normalize_include_path("..\\x.h"), "../x.h");
    }

    #[test]
    fn ordinary_paths_pass() {
        for ok in ["common.h", "common/blur.h", "a..b.h", "..a/b.h", "a/b..c", "1:x", "x"] {
            assert_eq!(check_include_path(ok), Ok(()), "{ok}");
        }
    }

    #[test]
    fn every_invalid_class_is_detected_after_normalisation() {
        let cases = [
            ("", InvalidPathClass::Empty),
            ("a\0b.h", InvalidPathClass::ContainsNul),
            ("/etc/x.h", InvalidPathClass::Absolute),
            ("//server/x.h", InvalidPathClass::Absolute),
            ("\\\\server\\x.h", InvalidPathClass::Absolute),
            ("\\x.h", InvalidPathClass::Absolute),
            ("C:/x.h", InvalidPathClass::DrivePrefix),
            ("c:\\x.h", InvalidPathClass::DrivePrefix),
            ("c:x.h", InvalidPathClass::DrivePrefix),
            ("../x.h", InvalidPathClass::ParentComponent),
            ("a/../x.h", InvalidPathClass::ParentComponent),
            ("a/..", InvalidPathClass::ParentComponent),
            ("a\\..\\x.h", InvalidPathClass::ParentComponent),
            ("..", InvalidPathClass::ParentComponent),
        ];
        for (path, class) in cases {
            assert_eq!(check_include_path(&normalize_include_path(path)), Err(class), "{path:?}");
        }
    }

    #[test]
    fn failure_text_names_the_path_and_the_kind() {
        let t = |kind| IncludeError { path: "common/x.h".into(), kind }.to_string();
        assert_eq!(t(IncludeErrorKind::NotFound), "shader include not found: common/x.h");
        let text = t(IncludeErrorKind::Unreadable { len: 12 });
        assert!(
            text.starts_with("shader source read failed for common/x.h: ")
                && text.contains("null pointer")
                && text.contains("non-zero length")
                && text.contains("12"),
            "{text}"
        );
        assert_eq!(t(IncludeErrorKind::NotUtf8), "shader source utf-8 invalid for common/x.h");
        let text = t(IncludeErrorKind::InvalidPath(InvalidPathClass::ParentComponent));
        assert!(text.contains("`common/x.h`") && text.contains("`..`"), "{text}");
    }

    #[test]
    fn a_cycle_names_the_whole_chain() {
        let e = IncludeError {
            path: "a".into(),
            kind: IncludeErrorKind::Cycle { chain: vec!["a".into(), "b".into(), "a".into()] },
        };
        assert!(e.to_string().contains("a -> b -> a"), "{e}");
    }

    #[test]
    fn include_failure_text_is_plain() {
        let e = IncludeError { path: "x\u{1b}[31m.h".into(), kind: IncludeErrorKind::NotFound };
        assert!(!e.to_string().contains('\u{1b}'));
    }
}
