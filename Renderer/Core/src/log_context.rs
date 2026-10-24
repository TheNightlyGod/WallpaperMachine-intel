//! Which wallpaper load a log line belongs to.
//!
//! Every wallpaper load gets a process-unique number, `load#N`. Its header
//! line names the wallpaper and the display; every later line the load
//! produces carries the same number, whichever thread writes it. Rust code
//! enters a [`LoadScope`]; a renderer scene's own threads take the number when
//! they start (`owe_scene_wallpaper_set_log_scope`). The log sink reads both
//! through [`current_load`], so two displays loading at once stay apart.

use std::{
    cell::Cell,
    fmt::{self, Display},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use serde_json::Value;

use crate::owe::sys;

static NEXT_LOAD: AtomicU64 = AtomicU64::new(1);

thread_local! {
    static SCOPE: Cell<u64> = const { Cell::new(0) };
}

/// Allocates the next load number. Never zero: zero means "untagged".
#[must_use]
pub fn next_load_id() -> u64 {
    NEXT_LOAD.fetch_add(1, Ordering::Relaxed)
}

/// The load the calling thread's log lines belong to, if any.
///
/// A Rust [`LoadScope`] wins over the renderer thread's own scope, so a host
/// call made while one load is in progress is attributed to that load.
#[must_use]
pub fn current_load() -> Option<u64> {
    let scope = SCOPE.with(Cell::get);
    let scope = if scope == 0 {
        // SAFETY: reads a thread-local integer; no pointers, cannot unwind.
        unsafe { sys::owe_current_log_scope() }
    } else {
        scope
    };
    (scope != 0).then_some(scope)
}

/// Attributes the calling thread's log lines to one load until dropped,
/// restoring whatever scope was in force before.
#[must_use = "the scope ends when the guard is dropped"]
pub struct LoadScope {
    previous: u64,
}

impl LoadScope {
    pub fn enter(load: u64) -> Self {
        Self {
            previous: SCOPE.with(|scope| scope.replace(load)),
        }
    }
}

impl Drop for LoadScope {
    fn drop(&mut self) {
        SCOPE.with(|scope| scope.set(self.previous));
    }
}

/// Starts one wallpaper load: allocates its number and writes the header
/// line naming the project and `detail` (display, rate, renderer, ...).
///
/// `project` may be the project directory, its `project.json`, or any file
/// beside it.
pub fn begin_load(kind: &str, project: &Path, detail: impl Display) -> u64 {
    let load = next_load_id();
    let _scope = LoadScope::enter(load);
    log::info!("{kind} load: {detail}; {}", ProjectSummary::read(project));
    load
}

/// What a bug report needs to know about a project, read leniently: a field
/// of an unexpected type is left out rather than failing the summary.
#[derive(Debug)]
pub struct ProjectSummary {
    manifest: PathBuf,
    fields: Vec<(&'static str, String)>,
    error: Option<String>,
}

impl ProjectSummary {
    const FIELDS: [(&'static str, &'static str); 5] = [
        ("title", "title"),
        ("type", "type"),
        ("version", "version"),
        ("workshop", "workshopid"),
        ("file", "file"),
    ];

    #[must_use]
    pub fn read(project: &Path) -> Self {
        let manifest = Self::manifest_path(project);
        let parsed = std::fs::read_to_string(&manifest)
            .map_err(|error| error.to_string())
            .and_then(|text| {
                serde_json::from_str::<Value>(&text).map_err(|error| error.to_string())
            });
        match parsed {
            Ok(json) => Self {
                fields: Self::FIELDS
                    .iter()
                    .filter_map(|(label, key)| {
                        let value = match json.get(key)? {
                            Value::String(text) if !text.is_empty() => format!("{text:?}"),
                            Value::Number(number) => number.to_string(),
                            _ => return None,
                        };
                        Some((*label, value))
                    })
                    .collect(),
                manifest,
                error: None,
            },
            Err(error) => Self {
                manifest,
                fields: Vec::new(),
                error: Some(error),
            },
        }
    }

    fn manifest_path(project: &Path) -> PathBuf {
        if project.file_name().is_some_and(|name| name == "project.json") {
            project.to_path_buf()
        } else if project.is_dir() {
            project.join("project.json")
        } else {
            project
                .parent()
                .map_or_else(|| PathBuf::from("project.json"), |dir| dir.join("project.json"))
        }
    }
}

impl Display for ProjectSummary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(error) = &self.error {
            return write!(f, "project.json unreadable at {}: {error}", self.manifest.display());
        }
        f.write_str("project")?;
        for (label, value) in &self.fields {
            write!(f, " {label}={value}")?;
        }
        write!(f, " at {}", self.manifest.display())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{LoadScope, ProjectSummary, current_load, next_load_id};

    #[test]
    fn scopes_nest_and_restore() {
        let outer = next_load_id();
        let inner = next_load_id();
        assert_ne!(outer, inner);
        assert_eq!(current_load(), None);
        {
            let _outer = LoadScope::enter(outer);
            {
                let _inner = LoadScope::enter(inner);
                assert_eq!(current_load(), Some(inner));
            }
            assert_eq!(current_load(), Some(outer));
        }
        assert_eq!(current_load(), None);
    }

    #[test]
    fn summary_reads_the_manifest_beside_any_project_file() {
        let root = tempfile::tempdir().unwrap();
        fs::write(
            root.path().join("project.json"),
            r#"{"title":"Rain \"Night\"","type":"scene","version":3,"workshopid":123,"file":"scene.json","general":{}}"#,
        )
        .unwrap();
        let expected = format!(
            r#"project title="Rain \"Night\"" type="scene" version=3 workshop=123 file="scene.json" at {}"#,
            root.path().join("project.json").display()
        );

        for path in [root.path().to_path_buf(), root.path().join("project.json"), root.path().join("scene.pkg")] {
            assert_eq!(ProjectSummary::read(&path).to_string(), expected);
        }
    }

    #[test]
    fn summary_skips_fields_of_unexpected_type_and_reports_unreadable_manifests() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("project.json"), r#"{"title":["x"],"type":"video"}"#).unwrap();
        let summary = ProjectSummary::read(root.path()).to_string();
        assert!(summary.starts_with(r#"project type="video" at "#), "{summary}");

        let missing = ProjectSummary::read(&root.path().join("gone").join("project.json"));
        assert!(missing.to_string().starts_with("project.json unreadable at "));
    }
}
