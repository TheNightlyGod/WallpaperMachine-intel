use std::fs;
use std::io::{self, Write};
use std::path::Path;

pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "configuration target has no parent",
        )
    })?;
    let parent = if parent.as_os_str().is_empty() {
        Path::new(".")
    } else {
        parent
    };
    fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    let write_result = temporary.write_all(bytes);
    #[cfg(test)]
    let write_result = fault::check(fault::Stage::Write, write_result);
    write_result?;
    let sync_result = temporary.as_file().sync_all();
    #[cfg(test)]
    let sync_result = fault::check(fault::Stage::Sync, sync_result);
    sync_result?;
    temporary.persist(path).map_err(|failure| failure.error)?;
    Ok(())
}

// Fault controls and their call sites do not exist in a delivered non-test build.
// Tests replace a successful operation result before the shared error-propagation step.
#[cfg(test)]
pub(super) mod fault {
    use std::cell::Cell;
    use std::io;

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Stage {
        Write,
        Sync,
    }

    thread_local! {
        static NEXT: Cell<Option<Stage>> = const { Cell::new(None) };
    }

    pub(super) fn check(stage: Stage, actual: io::Result<()>) -> io::Result<()> {
        actual?;
        NEXT.with(|next| {
            if next.get() == Some(stage) {
                next.set(None);
                Err(io::Error::other("injected temporary-file IO failure"))
            } else {
                Ok(())
            }
        })
    }

    pub(crate) fn during<T>(stage: Stage, action: impl FnOnce() -> T) -> T {
        struct Restore(Option<Stage>);
        impl Drop for Restore {
            fn drop(&mut self) {
                NEXT.with(|next| next.set(self.0));
            }
        }
        let _restore = Restore(NEXT.with(|next| next.replace(Some(stage))));
        action()
    }
}
