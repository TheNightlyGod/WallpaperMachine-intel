use std::{fs, io::Write as _, path::Path, str::FromStr};

use chrono::{DateTime, Local, TimeZone};
use log::{Level, LevelFilter};
use wallpaper_core::log_context;

use crate::{BridgeError, BridgeErrorKind, paths::BridgePaths};

const MAX_LOG_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// Files kept per session: a session that runs for weeks keeps its newest
/// 50 MB rather than growing without bound.
const MAX_FILES_PER_SESSION: u64 = 10;
/// Earlier sessions kept at launch besides the new one, newest first, while
/// they fit in [`MAX_OLD_SESSION_BYTES`]. A report needs the last few
/// launches, not a history of every one.
const MAX_OLD_SESSIONS: usize = 9;
const MAX_OLD_SESSION_BYTES: u64 = 100 * 1024 * 1024;
/// Overrides the level for the process, whatever the verbose-logging setting.
const LEVEL_ENV: &str = "WALLPAPER_ENGINE_LOG_LEVEL";

/// A snapshot of the application's selected log destination and tracked size.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogStatus {
    pub logs_root: std::path::PathBuf,
    pub active_session: String,
    pub active_file: std::path::PathBuf,
    pub active_file_size_bytes: u64,
}

/// An independently usable logger; construction alone does not install it.
pub struct ApplicationLogger {
    lifecycle: std::sync::Mutex<LifecycleState>,
}

static LIFECYCLE_APPLICATION: std::sync::OnceLock<ApplicationLogger> =
    std::sync::OnceLock::new();

struct LifecycleState {
    status: LogStatus,
    file_id: u64,
    destination: Option<std::fs::File>,
    io: LifecycleIo,
}

#[derive(Clone, Copy)]
enum LifecycleOpen {
    Initial,
    Clear,
    Rotation,
}

struct LifecycleIo {
    #[cfg(test)]
    control: Option<std::sync::Arc<lifecycle_tests::Control>>,
}

impl Default for LifecycleIo {
    fn default() -> Self {
        Self {
            #[cfg(test)]
            control: lifecycle_tests::current_control(),
        }
    }
}

fn lifecycle_error(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Io,
        message: error.to_string(),
    }
}

/// Where one line came from; everything the formatted prefix needs.
struct LineOrigin<'a> {
    time: DateTime<Local>,
    level: Level,
    load: Option<u64>,
    file: Option<&'a str>,
    line: Option<u32>,
}

impl ApplicationLogger {
    pub fn new(paths: &BridgePaths) -> Result<Self, BridgeError> {
        Self::lifecycle_construct(paths.logs_root(), LifecycleIo::default())
    }

    fn lifecycle_construct(
        root: std::path::PathBuf,
        io: LifecycleIo,
    ) -> Result<Self, BridgeError> {
        io.create_root(&root).map_err(lifecycle_error)?;
        prune_old_sessions(&root, MAX_OLD_SESSIONS, MAX_OLD_SESSION_BYTES);
        let (session, directory) = io.select_session(&root);
        io.create_session(&directory, false)
            .map_err(lifecycle_error)?;
        let active_file = directory.join("0.log");
        let destination = io
            .open(&active_file, LifecycleOpen::Initial)
            .map_err(lifecycle_error)?;
        let size = io.file_len(&destination, &active_file).unwrap_or(0);
        Ok(Self {
            lifecycle: std::sync::Mutex::new(LifecycleState {
                status: LogStatus {
                    logs_root: root,
                    active_session: session,
                    active_file,
                    active_file_size_bytes: size,
                },
                file_id: 0,
                destination: Some(destination),
                io,
            }),
        })
    }

    pub fn install(paths: &BridgePaths) -> Result<(), BridgeError> {
        // Even a losing/repeated install must finish its filesystem work first.
        let candidate = Self::new(paths)?;
        if LIFECYCLE_APPLICATION.set(candidate).is_err() {
            return Ok(());
        }
        let logger = Self::lifecycle_published()
            .expect("a successfully published logger remains present");
        // Publication intentionally survives a registration failure.
        log::set_logger(logger).map_err(|error| {
            lifecycle_error(format!("failed to install application logger: {error}"))
        })?;
        let (level, source) = level_for(false);
        log::set_max_level(level);
        log::info!(
            "application logger started: pid={} level={} source={}",
            std::process::id(),
            level,
            source,
        );
        Ok(())
    }

    pub fn status() -> Option<LogStatus> {
        Self::lifecycle_published()?.lifecycle_snapshot()
    }

    pub fn logs_root() -> Option<std::path::PathBuf> {
        let logger = Self::lifecycle_published()?;
        let state = logger.lifecycle.lock().ok()?;
        Some(state.status.logs_root.clone())
    }

    pub fn clear() -> Result<LogStatus, BridgeError> {
        Self::lifecycle_published()
            .ok_or_else(|| lifecycle_error("application logger is not installed"))?
            .lifecycle_clear()
    }

    // Narrow integration surface for the parent-retained verbose/host helpers.
    // Presence is deliberately different from successful registration or lock access.
    fn lifecycle_published() -> Option<&'static Self> {
        LIFECYCLE_APPLICATION.get()
    }

    fn lifecycle_dispatch_global(level: log::Level, formatted: &str) {
        if let Some(logger) = Self::lifecycle_published() {
            logger.lifecycle_dispatch(level, formatted);
        }
    }

    fn lifecycle_dispatch(&self, level: log::Level, formatted: &str) {
        let Ok(mut state) = self.lifecycle.lock() else {
            return;
        };
        state.dispatch(level, formatted);
    }

    #[cfg(test)]
    fn lifecycle_write_instance(&self, formatted: &str) {
        self.lifecycle
            .lock()
            .unwrap()
            .dispatch(log::Level::Info, formatted);
    }

    fn lifecycle_snapshot(&self) -> Option<LogStatus> {
        self.lifecycle.lock().ok().map(|state| state.status.clone())
    }

    fn lifecycle_clear(&self) -> Result<LogStatus, BridgeError> {
        let mut state = self
            .lifecycle
            .lock()
            .map_err(|_| lifecycle_error("application logger state is poisoned"))?;
        let old_paths = state
            .io
            .root_entries(&state.status.logs_root)
            .map_err(lifecycle_error)?;
        let (session, directory) = state.io.select_session(&state.status.logs_root);
        state
            .io
            .create_session(&directory, true)
            .map_err(lifecycle_error)?;
        let active_file = directory.join("0.log");
        let destination = state
            .io
            .open(&active_file, LifecycleOpen::Clear)
            .map_err(lifecycle_error)?;

        let retired = state.destination.replace(destination);
        state.file_id = 0;
        state.status.active_session = session;
        state.status.active_file = active_file;
        // Unlike construction and rotation, clear deliberately starts at zero.
        state.status.active_file_size_bytes = 0;
        drop(retired);

        for old_path in old_paths {
            if old_path == directory {
                continue;
            }
            if let Err(error) = state.io.remove_old_path(&old_path) {
                eprintln!("failed to remove old log path {}: {error}", old_path.display());
            }
        }
        Ok(state.status.clone())
    }

    #[cfg(test)]
    fn instance_status(&self) -> Option<LogStatus> {
        self.lifecycle_snapshot()
    }

    #[cfg(test)]
    fn clear_instance(&self) -> Result<LogStatus, BridgeError> {
        self.lifecycle_clear()
    }
}

impl ApplicationLogger {
    /// Applies the persisted verbose-logging choice. `WALLPAPER_ENGINE_LOG_LEVEL`
    /// still wins when set, so a developer's override is not undone by the
    /// setting. Does nothing until the logger is installed, which keeps tests
    /// that build a bridge from changing the process-wide level.
    pub fn set_verbose(verbose: bool) {
        if Self::lifecycle_published().is_none() {
            return;
        }
        let (level, source) = level_for(verbose);
        if level != log::max_level() {
            log::set_max_level(level);
            log::info!("log level {level} ({source})");
        }
    }

    /// Writes one line from the host UI, stamped with when the host produced
    /// it (Unix milliseconds) rather than when it arrived, so lines buffered
    /// before the bridge existed keep their time.
    pub fn emit_gui_log(
        level: Level,
        file: &str,
        line: u32,
        message: &str,
        load: Option<u64>,
        unix_millis: Option<i64>,
    ) {
        if level > log::max_level() {
            return;
        }
        let time = unix_millis
            .and_then(|millis| Local.timestamp_millis_opt(millis).single())
            .unwrap_or_else(Local::now);
        let origin = LineOrigin {
            time,
            level,
            load: load.or_else(log_context::current_load),
            file: Some(file),
            line: Some(line),
        };
        let line = format_record(&origin, &format_args!("{message}"));
        Self::lifecycle_dispatch_global(level, &line);
    }


    #[cfg(test)]
    fn write_instance(&self, line: &str) {
        self.lifecycle_write_instance(line);
    }
}

impl log::Log for ApplicationLogger {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }

    fn log(&self, record: &log::Record<'_>) {
        let origin = LineOrigin {
            time: Local::now(),
            level: record.level(),
            load: log_context::current_load(),
            file: record.file(),
            line: record.line(),
        };
        let line = format_record(&origin, record.args());
        self.lifecycle_dispatch(record.level(), &line);
    }

    fn flush(&self) {}
}

/// The level in force and why: the environment override, else the setting.
fn level_for(verbose: bool) -> (LevelFilter, &'static str) {
    if let Some(level) = std::env::var(LEVEL_ENV)
        .ok()
        .and_then(|value| LevelFilter::from_str(&value).ok())
    {
        return (level, LEVEL_ENV);
    }
    if verbose {
        (LevelFilter::Debug, "verbose logging on")
    } else {
        (LevelFilter::Info, "default")
    }
}

/// `2026-09-27T15:02:11.482+08:00 ERROR [load#7] Parser.cpp:1061 message`.
/// Local time with its offset, so a line can be matched both to what the
/// user saw on their clock and to a crash report.
fn format_record(origin: &LineOrigin<'_>, args: &std::fmt::Arguments<'_>) -> String {
    let file = origin
        .file
        .and_then(|path| Path::new(path).file_name())
        .and_then(|name| name.to_str())
        .unwrap_or("unknown");
    let line = origin.line.unwrap_or(0);
    let time = origin.time.format("%Y-%m-%dT%H:%M:%S%.3f%:z");
    let level = origin.level;
    match origin.load {
        Some(load) => format!("{time} {level} [load#{load}] {file}:{line} {args}\n"),
        None => format!("{time} {level} {file}:{line} {args}\n"),
    }
}

impl LifecycleState {
    fn dispatch(&mut self, level: log::Level, formatted: &str) {
        match level {
            log::Level::Error | log::Level::Warn => eprint!("{formatted}"),
            log::Level::Info | log::Level::Debug | log::Level::Trace => print!("{formatted}"),
        }
        if let Err(error) = self.persist(formatted.as_bytes()) {
            eprintln!("failed to persist application log: {error}");
        }
    }

    fn persist(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if self.destination.is_none() {
            return Ok(());
        }
        let incoming = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if self.status.active_file_size_bytes != 0
            && self.status.active_file_size_bytes.saturating_add(incoming)
                > MAX_LOG_FILE_BYTES
        {
            // Failed opens deliberately leave this advanced identity visible while
            // retaining the old destination and its previous tracked byte count.
            self.file_id = self.file_id.saturating_add(1);
            self.status.active_file = self
                .status
                .active_file
                .with_file_name(format!("{}.log", self.file_id));
            let destination = self
                .io
                .open(&self.status.active_file, LifecycleOpen::Rotation)?;
            let size = self
                .io
                .file_len(&destination, &self.status.active_file)
                .unwrap_or(0);
            self.destination = Some(destination);
            self.status.active_file_size_bytes = size;
            retain_rotated_files(
                self.status
                    .active_file
                    .parent()
                    .expect("numbered logs always have a session directory"),
                self.file_id,
            );
        }
        if let Some(destination) = self.destination.as_mut() {
            self.io.write_record(destination, bytes)?;
            self.io.flush_record(destination)?;
            self.status.active_file_size_bytes = self
                .status
                .active_file_size_bytes
                .saturating_add(incoming);
        }
        Ok(())
    }
}

impl LifecycleIo {
    fn create_root(&self, path: &std::path::Path) -> std::io::Result<()> {
        #[cfg(test)]
        self.check(lifecycle_tests::Point::RootDirectory, path)?;
        std::fs::create_dir_all(path)
    }

    fn create_session(&self, path: &std::path::Path, _clear: bool) -> std::io::Result<()> {
        #[cfg(test)]
        self.check(
            if _clear {
                lifecycle_tests::Point::ClearDirectory
            } else {
                lifecycle_tests::Point::SessionDirectory
            },
            path,
        )?;
        std::fs::create_dir_all(path)
    }

    fn select_session(&self, root: &std::path::Path) -> (String, std::path::PathBuf) {
        let now = {
            #[cfg(test)]
            {
                self.control
                    .as_ref()
                    .and_then(|control| control.now())
                    .unwrap_or_else(chrono::Local::now)
            }
            #[cfg(not(test))]
            {
                chrono::Local::now()
            }
        };
        let stem = now.format("%Y%m%d-%H%M%S").to_string();
        let path = root.join(&stem);
        if !path.exists() {
            return (stem, path);
        }
        let mut suffix = 1_u64;
        loop {
            let name = format!("{stem}-{suffix}");
            let path = root.join(&name);
            if !path.exists() {
                return (name, path);
            }
            suffix += 1;
        }
    }

    fn open(
        &self,
        path: &std::path::Path,
        _purpose: LifecycleOpen,
    ) -> std::io::Result<std::fs::File> {
        #[cfg(test)]
        {
            let point = match _purpose {
                LifecycleOpen::Initial => lifecycle_tests::Point::InitialOpen,
                LifecycleOpen::Clear => lifecycle_tests::Point::ClearOpen,
                LifecycleOpen::Rotation => lifecycle_tests::Point::RotationOpen,
            };
            self.check(point, path)?;
            if let Some(control) = &self.control {
                control.seed_open(point, path)?;
            }
        }
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
    }

    fn file_len(&self, file: &std::fs::File, _path: &std::path::Path) -> std::io::Result<u64> {
        #[cfg(test)]
        self.check(lifecycle_tests::Point::Metadata, _path)?;
        Ok(file.metadata()?.len())
    }

    fn root_entries(&self, root: &std::path::Path) -> std::io::Result<Vec<std::path::PathBuf>> {
        #[cfg(test)]
        self.check(lifecycle_tests::Point::ClearEnumeration, root)?;
        let mut paths = Vec::new();
        for entry in std::fs::read_dir(root)? {
            let path = entry.map(|entry| entry.path());
            #[cfg(test)]
            let path = path.and_then(|path| {
                if self.control.as_ref().is_some_and(|control| control.skip_entry(&path)) {
                    Err(lifecycle_tests::injected_error())
                } else {
                    Ok(path)
                }
            });
            if let Ok(path) = path {
                paths.push(path);
            }
        }
        #[cfg(test)]
        if let Some(control) = &self.control {
            control.after_enumeration()?;
        }
        Ok(paths)
    }

    fn remove_old_path(&self, path: &std::path::Path) -> std::io::Result<()> {
        #[cfg(test)]
        self.check(lifecycle_tests::Point::Delete, path)?;
        if path.is_dir() {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        }
    }

    fn write_record(&self, file: &mut std::fs::File, bytes: &[u8]) -> std::io::Result<()> {
        #[cfg(test)]
        if let Some(control) = &self.control {
            if let Some(failure) = control.take_failure(lifecycle_tests::Point::Write, None) {
                file.write_all(&bytes[..failure.prefix.min(bytes.len())])?;
                return Err(lifecycle_tests::injected_error());
            }
        }
        file.write_all(bytes)
    }

    fn flush_record(&self, file: &mut std::fs::File) -> std::io::Result<()> {
        #[cfg(test)]
        if let Some(control) = &self.control {
            if control
                .take_failure(lifecycle_tests::Point::Flush, None)
                .is_some()
            {
                return Err(lifecycle_tests::injected_error());
            }
        }
        file.flush()
    }

    #[cfg(test)]
    fn check(
        &self,
        point: lifecycle_tests::Point,
        path: &std::path::Path,
    ) -> std::io::Result<()> {
        if self.control.as_ref().is_some_and(|control| {
            control.take_failure(point, Some(path)).is_some()
        }) {
            Err(lifecycle_tests::injected_error())
        } else {
            Ok(())
        }
    }
}

fn retain_rotated_files(session_dir: &Path, active_file_id: u64) {
    if let Some(expired) = active_file_id.checked_sub(MAX_FILES_PER_SESSION) {
        // Only ever the one file that just fell out of the window: the
        // ones before it went on earlier rotations.
        let _ = fs::remove_file(session_dir.join(format!("{expired}.log")));
    }
}

/// Keeps the newest `keep` session directories, as long as together they fit
/// in `max_bytes`, and removes every older one. Session names are timestamps,
/// so name order is age order. Runs before the new session exists, so it can
/// never remove the one being written.
fn prune_old_sessions(logs_root: &Path, keep: usize, max_bytes: u64) {
    let Ok(entries) = fs::read_dir(logs_root) else {
        return;
    };
    let mut sessions = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    sessions.sort_by(|a, b| session_order(b).cmp(&session_order(a)));

    let mut kept_bytes = 0_u64;
    let mut full = false;
    for (index, session) in sessions.iter().enumerate() {
        let bytes = directory_bytes(session);
        full = full || index >= keep || kept_bytes.saturating_add(bytes) > max_bytes;
        if !full {
            kept_bytes = kept_bytes.saturating_add(bytes);
            continue;
        }
        if let Err(error) = fs::remove_dir_all(session) {
            eprintln!("ERROR logging.rs:0 failed to remove expired log session: {error}");
        }
    }
}

/// `20260927-150211-2` sorts after `20260927-150211` and before
/// `20260927-150211-10`: the base timestamp, then the numeric suffix.
fn session_order(path: &Path) -> (String, u64) {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    match name.rsplit_once('-') {
        Some((base, suffix)) if base.contains('-') => {
            (base.to_string(), suffix.parse().unwrap_or(0))
        }
        _ => (name.to_string(), 0),
    }
}

fn directory_bytes(path: &Path) -> u64 {
    fs::read_dir(path).map_or(0, |entries| {
        entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.metadata().ok())
            .filter(fs::Metadata::is_file)
            .map(|metadata| metadata.len())
            .sum()
    })
}


#[cfg(test)]
#[path = "logging/lifecycle_tests.rs"]
mod lifecycle_tests;

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use chrono::{Local, TimeZone};
    use log::Level;

    use super::{
        ApplicationLogger, LineOrigin, MAX_FILES_PER_SESSION, MAX_LOG_FILE_BYTES,
        format_record, prune_old_sessions,
    };
    use crate::paths::BridgePaths;

    fn origin(load: Option<u64>) -> LineOrigin<'static> {
        LineOrigin {
            time: Local.with_ymd_and_hms(2026, 9, 27, 15, 2, 11).unwrap()
                + chrono::Duration::milliseconds(482),
            level: Level::Error,
            load,
            file: Some("/tmp/Parser.cpp"),
            line: Some(1061),
        }
    }

    #[test]
    fn lines_carry_local_time_with_offset_level_and_source() {
        let line = format_record(&origin(None), &format_args!("unknown tex {:?}", "x"));
        let offset = Local
            .with_ymd_and_hms(2026, 9, 27, 15, 2, 11)
            .unwrap()
            .format("%:z");
        assert_eq!(
            line,
            format!("2026-09-27T15:02:11.482{offset} ERROR Parser.cpp:1061 unknown tex \"x\"\n")
        );
    }

    #[test]
    fn lines_of_a_load_carry_its_number() {
        let line = format_record(&origin(Some(7)), &format_args!("scene backend: native_metal"));
        assert!(
            line.contains(" ERROR [load#7] Parser.cpp:1061 scene backend: native_metal\n"),
            "{line}"
        );
    }


    fn session(root: &Path, name: &str, bytes: usize) {
        fs::create_dir_all(root.join(name)).unwrap();
        fs::write(root.join(name).join("0.log"), vec![b'x'; bytes]).unwrap();
    }

    fn sessions(root: &Path) -> Vec<String> {
        let mut names = fs::read_dir(root)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    #[test]
    fn pruning_keeps_the_newest_sessions_by_count() {
        let root = tempfile::tempdir().unwrap();
        for name in ["20260101-000000", "20260102-000000", "20260102-000000-1", "20260102-000000-10", "20260103-000000"] {
            session(root.path(), name, 1);
        }

        prune_old_sessions(root.path(), 3, u64::MAX);

        assert_eq!(
            sessions(root.path()),
            ["20260102-000000-1", "20260102-000000-10", "20260103-000000"]
        );
    }

    #[test]
    fn pruning_stops_at_the_byte_budget_even_below_the_count() {
        let root = tempfile::tempdir().unwrap();
        session(root.path(), "20260101-000000", 10);
        session(root.path(), "20260102-000000", 60);
        session(root.path(), "20260103-000000", 50);

        prune_old_sessions(root.path(), 9, 100);

        assert_eq!(sessions(root.path()), ["20260103-000000"]);
    }

    #[test]
    fn a_long_session_keeps_only_its_newest_files() {
        let root = tempfile::tempdir().unwrap();
        let logger = ApplicationLogger::new(&BridgePaths::for_home(root.path())).unwrap();
        let status = logger.instance_status().unwrap();
        let chunk = "x".repeat(usize::try_from(MAX_LOG_FILE_BYTES).unwrap());
        let rotations = MAX_FILES_PER_SESSION + 2;
        for _ in 0..=rotations {
            logger.write_instance(&chunk);
        }

        let session = status.logs_root.join(&status.active_session);
        let mut files = fs::read_dir(&session)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        files.sort_by_key(|name| name.trim_end_matches(".log").parse::<u64>().unwrap());
        let expected = (rotations - MAX_FILES_PER_SESSION + 1..=rotations)
            .map(|id| format!("{id}.log"))
            .collect::<Vec<_>>();
        assert_eq!(files, expected);
    }
}
