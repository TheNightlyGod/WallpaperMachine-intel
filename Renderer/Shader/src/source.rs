// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Where include text comes from (R9, R11).
//!
//! The preprocessor asks an [`IncludeSource`] for the text of a validated
//! include path. There is no search path in this crate: the caller (the engine
//! callback in production, a map in tests) decides what a path means.

use std::cell::RefCell;
use std::collections::HashMap;

use crate::include::{IncludeError, IncludeErrorKind};

/// Reads include files by their normalised path.
pub trait IncludeSource {
    /// The whole text of `path`, or why it cannot be had (R9).
    fn read(&self, path: &str) -> Result<String, IncludeError>;
}

impl<F> IncludeSource for F
where
    F: Fn(&str) -> Result<String, IncludeError>,
{
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        self(path)
    }
}

/// A source with no files: every include is "not found" (the engine passed no callback).
#[derive(Clone, Copy, Debug, Default)]
pub struct NoIncludes;

impl IncludeSource for NoIncludes {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        Err(IncludeError { path: path.to_string(), kind: IncludeErrorKind::NotFound })
    }
}

/// An in-memory source. Inserting a path twice replaces the text.
#[derive(Clone, Debug, Default)]
pub struct MemorySource {
    files: HashMap<String, String>,
}

impl MemorySource {
    pub fn new() -> MemorySource {
        MemorySource::default()
    }

    pub fn insert(&mut self, path: impl Into<String>, text: impl Into<String>) -> &mut MemorySource {
        self.files.insert(path.into(), text.into());
        self
    }

    /// Builder form of [`MemorySource::insert`].
    pub fn with(mut self, path: impl Into<String>, text: impl Into<String>) -> MemorySource {
        self.insert(path, text);
        self
    }
}

impl IncludeSource for MemorySource {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        self.files
            .get(path)
            .cloned()
            .ok_or_else(|| IncludeError { path: path.to_string(), kind: IncludeErrorKind::NotFound })
    }
}

/// Remembers every answer of the wrapped source for the lifetime of one
/// program compile, so a path reads the same text each time it is asked for
/// and is fetched at most once (6.1). Failures are remembered too.
pub struct CachingSource<'a> {
    inner: &'a dyn IncludeSource,
    seen: RefCell<HashMap<String, Result<String, IncludeError>>>,
    reads: RefCell<Vec<String>>,
}

impl<'a> CachingSource<'a> {
    pub fn new(inner: &'a dyn IncludeSource) -> CachingSource<'a> {
        CachingSource { inner, seen: RefCell::default(), reads: RefCell::default() }
    }

    /// The distinct paths asked of the wrapped source, in first-asked order.
    pub fn paths_read(&self) -> Vec<String> {
        self.reads.borrow().clone()
    }
}

impl IncludeSource for CachingSource<'_> {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        if let Some(answer) = self.seen.borrow().get(path) {
            return answer.clone();
        }
        let answer = self.inner.read(path);
        self.reads.borrow_mut().push(path.to_string());
        self.seen.borrow_mut().insert(path.to_string(), answer.clone());
        answer
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn memory_source_replaces_and_reports_missing_paths() {
        let mut m = MemorySource::new();
        m.insert("a.h", "one").insert("a.h", "two");
        assert_eq!(m.read("a.h").unwrap(), "two");
        let e = m.read("b.h").unwrap_err();
        assert_eq!(e.kind, IncludeErrorKind::NotFound);
        assert_eq!(e.path, "b.h");
    }

    #[test]
    fn no_callback_means_every_include_is_not_found() {
        assert_eq!(NoIncludes.read("x.h").unwrap_err().kind, IncludeErrorKind::NotFound);
    }

    #[test]
    fn closures_are_sources() {
        let f = |p: &str| -> Result<String, IncludeError> { Ok(format!("// {p}")) };
        assert_eq!(f.read("q.h").unwrap(), "// q.h");
    }

    #[test]
    fn the_caching_source_asks_once_per_path_and_keeps_failures() {
        let calls = Cell::new(0);
        let inner = |p: &str| -> Result<String, IncludeError> {
            calls.set(calls.get() + 1);
            if p == "ok.h" {
                Ok("text".into())
            } else {
                Err(IncludeError { path: p.into(), kind: IncludeErrorKind::NotUtf8 })
            }
        };
        let cache = CachingSource::new(&inner);
        for _ in 0..3 {
            assert_eq!(cache.read("ok.h").unwrap(), "text");
            assert_eq!(cache.read("bad.h").unwrap_err().kind, IncludeErrorKind::NotUtf8);
        }
        assert_eq!(calls.get(), 2);
        assert_eq!(cache.paths_read(), ["ok.h", "bad.h"]);
    }
}
