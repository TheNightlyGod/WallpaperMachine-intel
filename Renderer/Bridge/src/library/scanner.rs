use std::fs;
use std::path::{Path, PathBuf};

use crate::project::ProjectModel;
use crate::{BridgeError, BridgeErrorKind};

use super::entry::{WallpaperEntry, modified_time};

pub fn scan(root: &Path) -> Result<Vec<WallpaperEntry>, BridgeError> {
    if !root.exists() {
        return Err(BridgeError::Error {
            kind: BridgeErrorKind::Library,
            message: format!("Library root does not exist: {}", root.display()),
        });
    }

    let children = fs::read_dir(root);
    #[cfg(test)]
    let children = test_controls::listing(root, children);
    let children = children.map_err(|error| {
        BridgeError::from(std::io::Error::new(
            error.kind(),
            format!("Cannot list library root {}: {error}", root.display()),
        ))
    })?;

    let mut entries = Vec::new();
    for child in children {
        #[cfg(test)]
        let child = test_controls::enumeration(child);
        let child = match child {
            Ok(child) => child,
            Err(error) => {
                log::warn!("Skipping a child of {}: {error}", root.display());
                continue;
            }
        };
        let file_type = child.file_type();
        #[cfg(test)]
        let file_type = test_controls::file_type(&child.path(), file_type);
        let file_type = match file_type {
            Ok(file_type) => file_type,
            Err(error) => {
                log::warn!("Cannot inspect {}: {error}", child.path().display());
                continue;
            }
        };
        if !file_type.is_dir() {
            log::debug!("Skipping non-directory child {}", child.path().display());
            continue;
        }

        let manifest = child.path().join("project.json");
        if !manifest.is_file() {
            log::debug!(
                "Skipping child without regular manifest {}",
                manifest.display()
            );
            continue;
        }
        let file_name = child.file_name();
        #[cfg(test)]
        let file_name = test_controls::file_name(&child.path(), file_name);
        let id = file_name.to_string_lossy().into_owned();
        let model = match ProjectModel::load(&id, &manifest) {
            Ok(model) => model,
            Err(error) => {
                log::warn!("Cannot load {}: {error}", manifest.display());
                continue;
            }
        };
        let mut entry = WallpaperEntry::from_model(&model);
        entry.project_json_mtime = modified_time(&manifest);
        entries.push(entry);
    }
    entries.sort_unstable_by(|left, right| {
        left.workshop_id
            .cmp(&right.workshop_id)
            .then_with(|| left.title.cmp(&right.title))
    });
    Ok(entries)
}

#[must_use]
pub fn resolve_preview(workshop_folder: &Path) -> Option<PathBuf> {
    ["preview.gif", "preview.jpg", "preview.jpeg", "preview.png"]
        .into_iter()
        .map(|name| workshop_folder.join(name))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
pub(super) mod test_controls {
    use std::cell::RefCell;
    use std::ffi::OsString;
    use std::fs::{DirEntry, FileType, Metadata, ReadDir};
    use std::io;
    use std::path::{Path, PathBuf};
    use std::time::SystemTime;

    #[derive(Default)]
    pub(crate) struct Failures {
        pub(crate) listing: Option<PathBuf>,
        pub(crate) enumeration: Option<PathBuf>,
        pub(crate) file_type: Option<PathBuf>,
        pub(crate) metadata: Option<PathBuf>,
        pub(crate) modified: Option<PathBuf>,
        pub(crate) file_names: Vec<(PathBuf, OsString)>,
    }

    std::thread_local! {
        static ACTIVE: RefCell<Failures> = RefCell::new(Failures::default());
    }

    struct Restore(Option<Failures>);

    impl Drop for Restore {
        fn drop(&mut self) {
            let previous = self.0.take().expect("failure scope owns its prior state");
            ACTIVE.with(|active| {
                active.replace(previous);
            });
        }
    }

    pub(crate) fn with_failures<T>(failures: Failures, operation: impl FnOnce() -> T) -> T {
        let previous = ACTIVE.with(|active| active.replace(failures));
        let _restore = Restore(Some(previous));
        operation()
    }

    pub(crate) fn file_name(path: &Path, observed: OsString) -> OsString {
        ACTIVE.with(|active| {
            let controls = active.borrow();
            match controls
                .file_names
                .iter()
                .find(|(selected, _)| selected == path)
            {
                Some((_, supplied)) => supplied.clone(),
                None => observed,
            }
        })
    }

    fn denied<T>() -> io::Result<T> {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "scoped operation-result failure",
        ))
    }

    pub(crate) fn listing(path: &Path, result: io::Result<ReadDir>) -> io::Result<ReadDir> {
        if ACTIVE.with(|active| active.borrow().listing.as_deref() == Some(path)) {
            denied()
        } else {
            result
        }
    }

    pub(crate) fn enumeration(result: io::Result<DirEntry>) -> io::Result<DirEntry> {
        match result {
            Ok(entry)
                if ACTIVE.with(|active| {
                    active.borrow().enumeration.as_deref() == Some(entry.path().as_path())
                }) =>
            {
                denied()
            }
            other => other,
        }
    }

    pub(crate) fn file_type(path: &Path, result: io::Result<FileType>) -> io::Result<FileType> {
        if ACTIVE.with(|active| active.borrow().file_type.as_deref() == Some(path)) {
            denied()
        } else {
            result
        }
    }

    pub(crate) fn metadata(path: &Path, result: io::Result<Metadata>) -> io::Result<Metadata> {
        if ACTIVE.with(|active| active.borrow().metadata.as_deref() == Some(path)) {
            denied()
        } else {
            result
        }
    }

    pub(crate) fn modified(path: &Path, result: io::Result<SystemTime>) -> io::Result<SystemTime> {
        if ACTIVE.with(|active| active.borrow().modified.as_deref() == Some(path)) {
            denied()
        } else {
            result
        }
    }
}
