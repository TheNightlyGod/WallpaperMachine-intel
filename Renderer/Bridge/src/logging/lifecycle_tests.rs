use super::*;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Point {
    RootDirectory,
    SessionDirectory,
    InitialOpen,
    ClearEnumeration,
    ClearDirectory,
    ClearOpen,
    RotationOpen,
    Metadata,
    Write,
    Flush,
    Delete,
}

pub(super) struct Failure {
    point: Point,
    path: Option<PathBuf>,
    pub(super) prefix: usize,
}

#[derive(Default)]
struct Controls {
    now: Option<chrono::DateTime<chrono::Local>>,
    failures: Vec<Failure>,
    seeds: Vec<(Point, Vec<u8>)>,
    skipped: Vec<PathBuf>,
    newcomer: Option<(PathBuf, Vec<u8>)>,
    failed_deletions: Vec<PathBuf>,
}

#[derive(Default)]
pub(super) struct Control(Mutex<Controls>);

std::thread_local! {
    static CURRENT: std::cell::RefCell<Option<Arc<Control>>> = const {
        std::cell::RefCell::new(None)
    };
}

pub(super) fn current_control() -> Option<Arc<Control>> {
    CURRENT.with(|slot| slot.borrow().clone())
}

struct Scope(Option<Arc<Control>>);

impl Scope {
    fn enter(control: Arc<Control>) -> Self {
        Self(CURRENT.with(|slot| slot.replace(Some(control))))
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        CURRENT.with(|slot| {
            slot.replace(self.0.take());
        });
    }
}

pub(super) fn injected_error() -> std::io::Error {
    std::io::Error::other("controlled lifecycle IO failure")
}

impl Control {
    fn fixed() -> Arc<Self> {
        let control = Arc::new(Self::default());
        control.0.lock().unwrap().now = Some(
            chrono::DateTime::parse_from_rfc3339("2033-07-19T14:26:38+00:00")
                .unwrap()
                .with_timezone(&chrono::Local),
        );
        control
    }

    pub(super) fn now(&self) -> Option<chrono::DateTime<chrono::Local>> {
        self.0.lock().unwrap().now
    }

    fn stem(&self) -> String {
        self.now().unwrap().format("%Y%m%d-%H%M%S").to_string()
    }

    fn fail(&self, point: Point, path: Option<PathBuf>, prefix: usize) {
        self.0.lock().unwrap().failures.push(Failure {
            point,
            path,
            prefix,
        });
    }

    pub(super) fn take_failure(&self, point: Point, path: Option<&Path>) -> Option<Failure> {
        let mut controls = self.0.lock().unwrap();
        let index = controls.failures.iter().position(|failure| {
            failure.point == point
                && failure
                    .path
                    .as_deref()
                    .map_or(true, |wanted| path == Some(wanted))
        })?;
        if point == Point::Delete {
            if let Some(path) = path {
                controls.failed_deletions.push(path.to_path_buf());
            }
        }
        Some(controls.failures.remove(index))
    }

    fn seed(&self, point: Point, bytes: Vec<u8>) {
        self.0.lock().unwrap().seeds.push((point, bytes));
    }

    pub(super) fn seed_open(&self, point: Point, path: &Path) -> std::io::Result<()> {
        let bytes = {
            let mut controls = self.0.lock().unwrap();
            controls
                .seeds
                .iter()
                .position(|(wanted, _)| *wanted == point)
                .map(|index| controls.seeds.remove(index).1)
        };
        if let Some(bytes) = bytes {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)?
                .write_all(&bytes)?;
        }
        Ok(())
    }

    pub(super) fn skip_entry(&self, path: &Path) -> bool {
        let mut controls = self.0.lock().unwrap();
        if let Some(index) = controls.skipped.iter().position(|wanted| wanted == path) {
            controls.skipped.remove(index);
            true
        } else {
            false
        }
    }

    pub(super) fn after_enumeration(&self) -> std::io::Result<()> {
        let newcomer = self.0.lock().unwrap().newcomer.take();
        if let Some((path, bytes)) = newcomer {
            std::fs::write(path, bytes)?;
        }
        Ok(())
    }
}

fn success<T>(result: Result<T, BridgeError>) -> T {
    match result {
        Ok(value) => value,
        Err(error) => panic!("unexpected logging error: {error}"),
    }
}

fn failure<T>(result: Result<T, BridgeError>, expected: &str) {
    let error = match result {
        Ok(_) => panic!("operation unexpectedly succeeded"),
        Err(error) => error,
    };
    assert!(matches!(error.kind(), BridgeErrorKind::Io));
    assert_eq!(error.message(), expected);
}

fn build(root: &Path, control: &Arc<Control>) -> ApplicationLogger {
    let _scope = Scope::enter(control.clone());
    success(ApplicationLogger::lifecycle_construct(
        root.to_path_buf(),
        LifecycleIo::default(),
    ))
}

fn snapshot(logger: &ApplicationLogger) -> LogStatus {
    logger
        .instance_status()
        .expect("instance status is available")
}

// Large-boundary cases exercise the actual persistence implementation without
// sending megabytes to the test runner's console capture.
fn persist(logger: &ApplicationLogger, bytes: &[u8]) {
    logger.lifecycle.lock().unwrap().persist(bytes).unwrap();
}

fn entries(root: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect()
}

fn poison(logger: &ApplicationLogger) {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _guard = logger.lifecycle.lock().unwrap();
        panic!("intentional isolated logger poison");
    }));
    assert!(result.is_err());
}

#[test]
fn session_clock_and_mixed_collisions_keep_existing_bytes() {
    let temporary = tempfile::tempdir().unwrap();
    let control = Control::fixed();
    let clean = temporary.path().join("clean");
    let first = build(&clean, &control);
    let first_status = snapshot(&first);
    assert_eq!(first_status.active_session, control.stem());
    assert_eq!(
        first_status.active_file,
        clean.join(control.stem()).join("0.log")
    );
    assert_eq!(first_status.active_file_size_bytes, 0);
    assert_eq!(std::fs::read(&first_status.active_file).unwrap(), b"");

    let crowded = temporary.path().join("mixed");
    std::fs::create_dir_all(&crowded).unwrap();
    let stem = control.stem();
    std::fs::write(crowded.join(&stem), b"unsuffixed-file").unwrap();
    for suffix in [1, 3] {
        let directory = crowded.join(format!("{stem}-{suffix}"));
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(directory.join("marker"), format!("occupied-{suffix}")).unwrap();
    }
    let next = build(&crowded, &control);
    assert_eq!(snapshot(&next).active_session, format!("{stem}-2"));
    assert_eq!(
        std::fs::read(crowded.join(&stem)).unwrap(),
        b"unsuffixed-file"
    );
    for suffix in [1, 3] {
        assert_eq!(
            std::fs::read(crowded.join(format!("{stem}-{suffix}")).join("marker")).unwrap(),
            format!("occupied-{suffix}").as_bytes(),
        );
    }
}

#[test]
fn initialization_failures_keep_completed_work_and_metadata_failure_is_nonfatal() {
    let temporary = tempfile::tempdir().unwrap();
    for point in [
        Point::RootDirectory,
        Point::SessionDirectory,
        Point::InitialOpen,
    ] {
        let control = Control::fixed();
        let root = temporary.path().join(format!("stage-{point:?}"));
        if point == Point::SessionDirectory {
            std::fs::create_dir_all(&root).unwrap();
            for day in 1..=12 {
                std::fs::create_dir(root.join(format!("201104{day:02}-010203"))).unwrap();
            }
        }
        control.fail(point, None, 0);
        let _scope = Scope::enter(control.clone());
        failure(
            ApplicationLogger::lifecycle_construct(root.clone(), LifecycleIo::default()),
            &injected_error().to_string(),
        );
        match point {
            Point::RootDirectory => assert!(!root.exists()),
            Point::SessionDirectory => {
                assert!(root.is_dir());
                assert!(
                    entries(&root).len() < 12,
                    "completed pruning is not rolled back"
                );
                assert!(!root.join(control.stem()).exists());
            }
            Point::InitialOpen => {
                assert!(root.join(control.stem()).is_dir());
                assert!(!root.join(control.stem()).join("0.log").exists());
            }
            _ => unreachable!(),
        }
    }
    let control = Control::fixed();
    control.seed(Point::InitialOpen, b"preexisting-append-bytes".to_vec());
    control.fail(Point::Metadata, None, 0);
    let logger = build(&temporary.path().join("metadata"), &control);
    assert_eq!(snapshot(&logger).active_file_size_bytes, 0);
    logger.lifecycle_dispatch(log::Level::Info, "new\n");
    let status = snapshot(&logger);
    assert_eq!(status.active_file_size_bytes, 4);
    assert_eq!(
        std::fs::read(status.active_file).unwrap(),
        b"preexisting-append-bytesnew\n"
    );
}

#[test]
fn clear_replaces_destination_and_deletes_arbitrary_old_entries() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("logs");
    let control = Control::fixed();
    let logger = build(&root, &control);
    logger.lifecycle_dispatch(log::Level::Info, "before-clear-雪\n");
    let old = snapshot(&logger);
    std::fs::write(root.join("unrecognized.txt"), b"old-root-file").unwrap();
    std::fs::create_dir_all(root.join("arbitrary-folder").join("nested")).unwrap();
    std::fs::write(root.join("arbitrary-folder/nested/item"), b"old-nested").unwrap();
    let cleared = success(logger.clear_instance());
    assert_eq!(cleared.active_session, format!("{}-1", control.stem()));
    assert_ne!(cleared.active_session, old.active_session);
    assert_eq!(cleared.logs_root, root);
    assert_eq!(cleared.active_file.file_name().unwrap(), "0.log");
    assert_eq!(cleared.active_file_size_bytes, 0);
    assert_eq!(snapshot(&logger), cleared);
    assert_eq!(entries(&root), vec![root.join(&cleared.active_session)]);
    assert!(!old.active_file.exists());
    assert_eq!(std::fs::read(&cleared.active_file).unwrap(), b"");
    logger.lifecycle_dispatch(log::Level::Info, "after-clear-月\n");
    assert_eq!(
        std::fs::read(&cleared.active_file).unwrap(),
        "after-clear-月\n".as_bytes()
    );
    assert!(!old.active_file.exists());
    assert_eq!(
        snapshot(&logger).active_file_size_bytes,
        "after-clear-月\n".len() as u64
    );
}

#[test]
fn failed_clear_stages_leave_the_previous_destination_writable() {
    let temporary = tempfile::tempdir().unwrap();
    for point in [
        Point::ClearEnumeration,
        Point::ClearDirectory,
        Point::ClearOpen,
    ] {
        let control = Control::fixed();
        let root = temporary.path().join(format!("clear-{point:?}"));
        let logger = build(&root, &control);
        logger.lifecycle_dispatch(log::Level::Info, "original\n");
        let before = snapshot(&logger);
        control.fail(point, None, 0);
        failure(logger.clear_instance(), &injected_error().to_string());
        assert_eq!(snapshot(&logger), before);
        assert_eq!(
            root.join(format!("{}-1", control.stem())).exists(),
            point == Point::ClearOpen,
        );
        logger.lifecycle_dispatch(log::Level::Info, "still-original\n");
        assert_eq!(
            std::fs::read(&before.active_file).unwrap(),
            b"original\nstill-original\n"
        );
    }
}

#[test]
fn clear_skips_failed_entries_and_does_not_claim_postenumeration_newcomers() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("logs");
    let control = Control::fixed();
    let logger = build(&root, &control);
    let old = snapshot(&logger);
    let skipped = root.join("entry-with-controlled-enumeration-error");
    let newcomer = root.join("created-after-root-enumeration");
    std::fs::write(&skipped, b"skipped").unwrap();
    {
        let mut settings = control.0.lock().unwrap();
        settings.skipped.push(skipped.clone());
        settings.newcomer = Some((newcomer.clone(), b"newcomer".to_vec()));
    }
    let cleared = success(logger.clear_instance());
    assert!(!old.active_file.exists());
    assert!(cleared.active_file.is_file());
    assert_eq!(std::fs::read(skipped).unwrap(), b"skipped");
    assert_eq!(std::fs::read(newcomer).unwrap(), b"newcomer");
}

#[test]
fn clear_reports_zero_even_for_a_controlled_preexisting_append_target() {
    let temporary = tempfile::tempdir().unwrap();
    let control = Control::fixed();
    let logger = build(&temporary.path().join("logs"), &control);
    control.seed(Point::ClearOpen, b"raced-content\n".to_vec());
    let cleared = success(logger.clear_instance());
    assert_eq!(cleared.active_file_size_bytes, 0);
    assert_eq!(
        std::fs::read(&cleared.active_file).unwrap(),
        b"raced-content\n"
    );
    logger.lifecycle_dispatch(log::Level::Info, "tail\n");
    assert_eq!(snapshot(&logger).active_file_size_bytes, 5);
    assert_eq!(
        std::fs::read(cleared.active_file).unwrap(),
        b"raced-content\ntail\n"
    );
}

#[test]
fn byte_boundaries_and_oversized_records_preserve_whole_records() {
    let temporary = tempfile::tempdir().unwrap();
    let control = Control::fixed();
    let logger = build(&temporary.path().join("equal"), &control);
    let prefix = vec![b'a'; MAX_LOG_FILE_BYTES as usize - 2];
    persist(&logger, &prefix);
    let initial = snapshot(&logger);
    assert_eq!(initial.active_file_size_bytes, MAX_LOG_FILE_BYTES - 2);
    persist(&logger, "é".as_bytes());
    assert_eq!(snapshot(&logger).active_file, initial.active_file);
    assert_eq!(snapshot(&logger).active_file_size_bytes, MAX_LOG_FILE_BYTES);
    persist(&logger, b"x");
    let rotated = snapshot(&logger);
    assert_eq!(rotated.active_file.file_name().unwrap(), "1.log");
    assert_eq!(rotated.active_file_size_bytes, 1);
    let old_bytes = std::fs::read(&initial.active_file).unwrap();
    assert_eq!(old_bytes.len() as u64, MAX_LOG_FILE_BYTES);
    assert!(old_bytes.ends_with("é".as_bytes()));
    assert_eq!(std::fs::read(rotated.active_file).unwrap(), b"x");

    let oversized = build(&temporary.path().join("oversized"), &control);
    persist(&oversized, b"");
    let beginning = snapshot(&oversized);
    assert_eq!(std::fs::read(&beginning.active_file).unwrap(), b"");
    let record = vec![b'Z'; MAX_LOG_FILE_BYTES as usize + 23];
    persist(&oversized, &record);
    assert_eq!(snapshot(&oversized).active_file, beginning.active_file);
    assert_eq!(std::fs::read(&beginning.active_file).unwrap(), record);
    assert!(!beginning.active_file.with_file_name("1.log").exists());
    persist(&oversized, b"following\n");
    assert_eq!(
        snapshot(&oversized).active_file.file_name().unwrap(),
        "1.log"
    );
    assert_eq!(
        std::fs::read(snapshot(&oversized).active_file).unwrap(),
        b"following\n"
    );
}

#[test]
fn append_metadata_and_rotation_targets_account_for_existing_bytes() {
    let temporary = tempfile::tempdir().unwrap();
    let control = Control::fixed();
    control.seed(Point::InitialOpen, b"kept-prefix\n".to_vec());
    let logger = build(&temporary.path().join("append"), &control);
    assert_eq!(snapshot(&logger).active_file_size_bytes, 12);
    logger.lifecycle_write_instance("tail\n");
    assert_eq!(
        std::fs::read(snapshot(&logger).active_file).unwrap(),
        b"kept-prefix\ntail\n"
    );

    for fail_metadata in [false, true] {
        let control = Control::fixed();
        let logger = build(
            &temporary.path().join(format!("rotation-{fail_metadata}")),
            &control,
        );
        persist(&logger, &vec![b'R'; MAX_LOG_FILE_BYTES as usize]);
        control.seed(Point::RotationOpen, b"older-target\n".to_vec());
        if fail_metadata {
            control.fail(Point::Metadata, None, 0);
        }
        persist(&logger, "λ".as_bytes());
        let status = snapshot(&logger);
        assert_eq!(status.active_file.file_name().unwrap(), "1.log");
        assert_eq!(
            status.active_file_size_bytes,
            if fail_metadata { 2 } else { 15 }
        );
        assert_eq!(
            std::fs::read(status.active_file).unwrap(),
            "older-target\nλ".as_bytes()
        );
    }
}

#[test]
fn retained_rotation_window_keeps_only_numbered_window_and_manual_files() {
    let temporary = tempfile::tempdir().unwrap();
    let control = Control::fixed();
    let logger = build(&temporary.path().join("logs"), &control);
    let directory = snapshot(&logger)
        .active_file
        .parent()
        .unwrap()
        .to_path_buf();
    std::fs::write(directory.join("manual-note"), b"not-numbered").unwrap();
    let record = vec![b'W'; MAX_LOG_FILE_BYTES as usize];
    for _ in 0..MAX_FILES_PER_SESSION + 3 {
        persist(&logger, &record);
    }
    let expected_name = format!("{}.log", MAX_FILES_PER_SESSION + 2);
    assert_eq!(
        snapshot(&logger).active_file.file_name().unwrap(),
        std::ffi::OsStr::new(&expected_name)
    );
    for id in 0..MAX_FILES_PER_SESSION + 3 {
        assert_eq!(directory.join(format!("{id}.log")).exists(), id >= 3);
    }
    assert_eq!(
        std::fs::read(directory.join("manual-note")).unwrap(),
        b"not-numbered"
    );
    assert_eq!(
        entries(&directory).len(),
        usize::try_from(MAX_FILES_PER_SESSION).unwrap() + 1
    );
}

#[test]
fn concurrent_instance_records_and_snapshots_do_not_tear() {
    let temporary = tempfile::tempdir().unwrap();
    let logger = Arc::new(build(&temporary.path().join("logs"), &Control::fixed()));
    let barrier = Arc::new(std::sync::Barrier::new(7));
    let mut workers = Vec::new();
    for worker in 0..6 {
        let logger = logger.clone();
        let barrier = barrier.clone();
        workers.push(std::thread::spawn(move || {
            barrier.wait();
            for number in 0..40 {
                logger.lifecycle_dispatch(
                    log::Level::Info,
                    &format!("worker-{worker}:item-{number}\n"),
                );
                let status = snapshot(&logger);
                assert_eq!(
                    status.active_file,
                    status.logs_root.join(&status.active_session).join("0.log")
                );
            }
        }));
    }
    barrier.wait();
    for worker in workers {
        worker.join().unwrap();
    }
    let status = snapshot(&logger);
    let bytes = std::fs::read(&status.active_file).unwrap();
    assert_eq!(status.active_file_size_bytes, bytes.len() as u64);
    let actual: std::collections::BTreeSet<_> =
        std::str::from_utf8(&bytes).unwrap().lines().collect();
    let expected: std::collections::BTreeSet<_> = (0..6)
        .flat_map(|worker| (0..40).map(move |number| format!("worker-{worker}:item-{number}")))
        .collect();
    assert_eq!(actual.len(), 240);
    assert_eq!(bytes.iter().filter(|byte| **byte == b'\n').count(), 240);
    assert_eq!(
        actual
            .into_iter()
            .map(str::to_owned)
            .collect::<std::collections::BTreeSet<_>>(),
        expected
    );
}

#[test]
fn concurrent_clear_publishes_a_complete_destination_between_whole_records() {
    let temporary = tempfile::tempdir().unwrap();
    let logger = Arc::new(build(&temporary.path().join("logs"), &Control::fixed()));
    let before = snapshot(&logger);
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let writer_logger = logger.clone();
    let writer_barrier = barrier.clone();
    let writer = std::thread::spawn(move || {
        writer_barrier.wait();
        for index in 0..100 {
            writer_logger
                .lifecycle_dispatch(log::Level::Info, &format!("concurrent-item-{index}\n"));
        }
    });
    barrier.wait();
    let cleared = success(logger.clear_instance());
    writer.join().unwrap();
    logger.lifecycle_dispatch(log::Level::Info, "after-both-operations\n");
    let final_status = snapshot(&logger);
    assert_eq!(final_status.active_file, cleared.active_file);
    assert!(!before.active_file.exists());
    let bytes = std::fs::read(&final_status.active_file).unwrap();
    assert_eq!(final_status.active_file_size_bytes, bytes.len() as u64);
    assert!(bytes.ends_with(b"after-both-operations\n"));
    for line in std::str::from_utf8(&bytes).unwrap().lines() {
        if line == "after-both-operations" {
            continue;
        }
        let index: usize = line
            .strip_prefix("concurrent-item-")
            .unwrap()
            .parse()
            .unwrap();
        assert!(index < 100);
    }
    assert_eq!(
        entries(&final_status.logs_root),
        vec![final_status.active_file.parent().unwrap().to_path_buf()]
    );
}

struct ExternalLogger(Mutex<Vec<String>>);
static EXTERNAL: ExternalLogger = ExternalLogger(Mutex::new(Vec::new()));

impl log::Log for ExternalLogger {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }
    fn log(&self, record: &log::Record<'_>) {
        self.0.lock().unwrap().push(record.args().to_string());
    }
    fn flush(&self) {}
}

const CASE_ENV: &str = "WM_INDEPENDENT_LIFECYCLE_CASE";
const HOME_ENV: &str = "WM_INDEPENDENT_LIFECYCLE_HOME";

fn paths(home: &Path) -> BridgePaths {
    BridgePaths::for_home(home.to_path_buf())
}

// Each branch runs in a new invocation of the test executable. Neither logger
// publication nor process logger registration is reset or shared across branches.
#[test]
fn isolated_process_contracts() {
    if let Some(case) = std::env::var_os(CASE_ENV) {
        let home = PathBuf::from(std::env::var_os(HOME_ENV).expect("isolated temporary home"));
        process_case(&case.to_string_lossy(), &home);
        return;
    }
    let name = std::thread::current().name().expect("test name").to_owned();
    for case in [
        "constructed",
        "unavailable",
        "install_failure",
        "installed",
        "startup_off",
        "repeat",
        "repeat_pruning",
        "repeat_failure",
        "registration_failure",
        "global_poison",
        "instance_poison",
        "console",
        "trace",
        "clear_deletion",
        "rotation_failure",
        "partial_write",
        "flush_failure",
        "install_race",
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .arg("--exact")
            .arg(&name)
            .arg("--nocapture")
            .arg("--test-threads=1")
            .env(CASE_ENV, case)
            .env(HOME_ENV, temporary.path())
            .env_remove("WALLPAPER_MACHINE_SUPPORT_ROOT")
            .env_remove("WALLPAPER_ENGINE_LOG_LEVEL");
        if case == "startup_off" {
            command.env("WALLPAPER_ENGINE_LOG_LEVEL", "off");
        }
        let output = command.output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            output.status.success(),
            "scenario {case} failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
        );
        match case {
            "console" => {
                for marker in ["console-info-雪", "console-debug-月", "console-trace-星"] {
                    assert!(stdout.contains(marker));
                    assert!(!stderr.contains(marker));
                }
                for marker in ["console-warning-火", "console-error-水"] {
                    assert!(stderr.contains(marker));
                    assert!(!stdout.contains(marker));
                }
            }
            "clear_deletion" | "partial_write" | "flush_failure" => {
                assert!(stderr.contains(&injected_error().to_string()));
            }
            "rotation_failure" => {
                assert!(stdout.contains("rotation-rejected-λ"));
                assert!(stderr.contains(&injected_error().to_string()));
            }
            "unavailable" | "global_poison" | "instance_poison" => {
                assert!(!stdout.contains("must-not-dispatch-marker"));
                assert!(!stderr.contains("must-not-dispatch-marker"));
            }
            _ => {}
        }
    }
}

fn process_case(case: &str, home: &Path) {
    let control = Control::fixed();
    let _scope = Scope::enter(control.clone());
    let configured = paths(home);
    let root = configured.logs_root();
    assert!(
        root.starts_with(home),
        "all configured storage must remain synthetic"
    );
    match case {
        "constructed" => {
            assert!(ApplicationLogger::status().is_none());
            let level = log::max_level();
            let logger = success(ApplicationLogger::new(&configured));
            let status = snapshot(&logger);
            assert_eq!(status.logs_root, root);
            assert!(status.active_file.is_file());
            assert_eq!(status.active_file_size_bytes, 0);
            assert_eq!(std::fs::read(&status.active_file).unwrap(), b"");
            assert!(ApplicationLogger::status().is_none());
            assert!(ApplicationLogger::logs_root().is_none());
            assert_eq!(log::max_level(), level);
            log::set_logger(&EXTERNAL).unwrap();
            log::set_max_level(log::LevelFilter::Info);
            log::info!("external-after-construction");
            assert_eq!(
                EXTERNAL.0.lock().unwrap().as_slice(),
                ["external-after-construction"]
            );
            assert_eq!(std::fs::read(status.active_file).unwrap(), b"");
        }
        "unavailable" => {
            assert!(ApplicationLogger::status().is_none());
            assert!(ApplicationLogger::logs_root().is_none());
            failure(
                ApplicationLogger::clear(),
                "application logger is not installed",
            );
            ApplicationLogger::lifecycle_dispatch_global(
                log::Level::Info,
                "must-not-dispatch-marker\n",
            );
            assert!(!root.exists());
        }
        "install_failure" => {
            let before_level = log::max_level();
            control.fail(Point::InitialOpen, None, 0);
            failure(
                ApplicationLogger::install(&configured),
                &injected_error().to_string(),
            );
            assert!(ApplicationLogger::status().is_none());
            assert!(ApplicationLogger::logs_root().is_none());
            assert_eq!(log::max_level(), before_level);
            assert!(root.join(control.stem()).is_dir());
            assert!(!root.join(control.stem()).join("0.log").exists());
            log::set_logger(&EXTERNAL).unwrap();
            log::set_max_level(log::LevelFilter::Warn);
            log::warn!("external-after-failed-construction");
            assert_eq!(
                EXTERNAL.0.lock().unwrap().as_slice(),
                ["external-after-failed-construction"]
            );
        }
        "installed" => {
            success(ApplicationLogger::install(&configured));
            let status = ApplicationLogger::status().unwrap();
            assert_eq!(ApplicationLogger::logs_root(), Some(root));
            let (level, source) = level_for(false);
            assert_eq!(log::max_level(), level);
            log::info!("ordinary-facade-after-install");
            let bytes = std::fs::read(&status.active_file).unwrap();
            let text = std::str::from_utf8(&bytes).unwrap();
            assert!(text.contains("ordinary-facade-after-install"));
            assert!(text.contains(&std::process::id().to_string()));
            assert!(text.contains(&level.to_string()));
            assert!(text.contains(source));
            assert_eq!(
                ApplicationLogger::status().unwrap().active_file_size_bytes,
                bytes.len() as u64
            );
        }
        "startup_off" => {
            success(ApplicationLogger::install(&configured));
            assert_eq!(log::max_level(), log::LevelFilter::Off);
            let status = ApplicationLogger::status().unwrap();
            assert_eq!(status.active_file_size_bytes, 0);
            assert_eq!(std::fs::read(status.active_file).unwrap(), b"");
        }
        "repeat" => {
            success(ApplicationLogger::install(&configured));
            let before = ApplicationLogger::status().unwrap();
            let bytes = std::fs::read(&before.active_file).unwrap();
            log::set_max_level(log::LevelFilter::Trace);
            success(ApplicationLogger::install(&configured));
            assert!(
                root.join(format!("{}-1", control.stem()))
                    .join("0.log")
                    .is_file()
            );
            let second = paths(&home.join("second-home"));
            success(ApplicationLogger::install(&second));
            assert!(
                second
                    .logs_root()
                    .join(control.stem())
                    .join("0.log")
                    .is_file()
            );
            assert_eq!(ApplicationLogger::status().unwrap(), before);
            assert_eq!(log::max_level(), log::LevelFilter::Trace);
            assert_eq!(std::fs::read(&before.active_file).unwrap(), bytes);
            assert_eq!(
                std::fs::read(second.logs_root().join(control.stem()).join("0.log")).unwrap(),
                b""
            );
            log::warn!("still-owned-by-first-session");
            assert!(
                std::fs::read_to_string(before.active_file)
                    .unwrap()
                    .contains("still-owned-by-first-session")
            );
        }
        "repeat_pruning" => {
            success(ApplicationLogger::install(&configured));
            let before = ApplicationLogger::status().unwrap();
            for day in 1..=10 {
                std::fs::create_dir(root.join(format!("209901{day:02}-030405"))).unwrap();
            }
            let next_day = control.now().unwrap() + chrono::Duration::days(1);
            control.0.lock().unwrap().now = Some(next_day);
            success(ApplicationLogger::install(&configured));
            assert_eq!(ApplicationLogger::status().unwrap(), before);
            assert!(
                !before.active_file.exists(),
                "ordinary pruning does not exempt the published session"
            );
            assert!(root.join(control.stem()).join("0.log").is_file());
            assert_eq!(entries(&root).len(), 10);
        }
        "repeat_failure" => {
            success(ApplicationLogger::install(&configured));
            let before = ApplicationLogger::status().unwrap();
            let other = paths(&home.join("failed-repeat"));
            control.fail(Point::InitialOpen, None, 0);
            failure(
                ApplicationLogger::install(&other),
                &injected_error().to_string(),
            );
            assert_eq!(ApplicationLogger::status().unwrap(), before);
            assert!(other.logs_root().join(control.stem()).is_dir());
            assert!(
                !other
                    .logs_root()
                    .join(control.stem())
                    .join("0.log")
                    .exists()
            );
            log::info!("after-repeat-failure");
            assert!(
                std::fs::read_to_string(before.active_file)
                    .unwrap()
                    .contains("after-repeat-failure")
            );
        }
        "registration_failure" => {
            log::set_logger(&EXTERNAL).unwrap();
            log::set_max_level(log::LevelFilter::Warn);
            let error = match ApplicationLogger::install(&configured) {
                Ok(()) => panic!("external process logger must reject registration"),
                Err(error) => error,
            };
            assert!(matches!(error.kind(), BridgeErrorKind::Io));
            assert!(
                error
                    .message()
                    .starts_with("failed to install application logger: ")
            );
            assert!(error.message().len() > "failed to install application logger: ".len());
            assert_eq!(log::max_level(), log::LevelFilter::Warn);
            let published = ApplicationLogger::status().unwrap();
            assert_eq!(std::fs::read(&published.active_file).unwrap(), b"");
            log::warn!("external-facade-marker");
            assert_eq!(
                EXTERNAL.0.lock().unwrap().as_slice(),
                ["external-facade-marker"]
            );
            assert_eq!(std::fs::read(&published.active_file).unwrap(), b"");
            ApplicationLogger::emit_gui_log(
                log::Level::Warn,
                "isolated.rs",
                17,
                "direct-host-after-rejection",
                Some(0),
                None,
            );
            assert!(
                std::fs::read_to_string(&published.active_file)
                    .unwrap()
                    .contains("direct-host-after-rejection")
            );
            let cleared = success(ApplicationLogger::clear());
            assert_ne!(cleared.active_session, published.active_session);
            ApplicationLogger::emit_gui_log(
                log::Level::Error,
                "isolated.rs",
                18,
                "host-after-rejected-install-clear",
                None,
                None,
            );
            assert!(
                std::fs::read_to_string(&cleared.active_file)
                    .unwrap()
                    .contains("host-after-rejected-install-clear")
            );
            let before_repeat = ApplicationLogger::status().unwrap();
            let other = paths(&home.join("later-install"));
            success(ApplicationLogger::install(&other));
            assert_eq!(ApplicationLogger::status().unwrap(), before_repeat);
            assert!(
                other
                    .logs_root()
                    .join(control.stem())
                    .join("0.log")
                    .is_file()
            );
            let external_before = EXTERNAL.0.lock().unwrap().len();
            ApplicationLogger::set_verbose(false);
            assert_eq!(log::max_level(), level_for(false).0);
            assert!(EXTERNAL.0.lock().unwrap().len() > external_before);
        }
        "global_poison" => {
            success(ApplicationLogger::install(&configured));
            let before = ApplicationLogger::status().unwrap();
            let bytes = std::fs::read(&before.active_file).unwrap();
            poison(ApplicationLogger::lifecycle_published().unwrap());
            assert!(ApplicationLogger::status().is_none());
            assert!(ApplicationLogger::logs_root().is_none());
            failure(
                ApplicationLogger::clear(),
                "application logger state is poisoned",
            );
            ApplicationLogger::lifecycle_dispatch_global(
                log::Level::Info,
                "must-not-dispatch-marker\n",
            );
            assert_eq!(std::fs::read(before.active_file).unwrap(), bytes);
        }
        "instance_poison" => {
            let logger = success(ApplicationLogger::new(&configured));
            let before = snapshot(&logger);
            poison(&logger);
            assert!(logger.instance_status().is_none());
            failure(
                logger.clear_instance(),
                "application logger state is poisoned",
            );
            logger.lifecycle_dispatch(log::Level::Info, "must-not-dispatch-marker\n");
            let direct_write = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                logger.lifecycle_write_instance("must-not-dispatch-marker\n");
            }));
            assert!(
                direct_write.is_err(),
                "the retained instance-write hook panics on poison"
            );
            assert_eq!(std::fs::read(before.active_file).unwrap(), b"");
            assert!(ApplicationLogger::status().is_none());
        }
        "console" => {
            let logger = success(ApplicationLogger::new(&configured));
            let records = [
                (log::Level::Info, "console-info-雪\nsecond-info-line\n"),
                (log::Level::Debug, "console-debug-月\nsecond-debug-line\n"),
                (log::Level::Trace, "console-trace-星\nsecond-trace-line\n"),
                (
                    log::Level::Warn,
                    "console-warning-火\nsecond-warning-line\n",
                ),
                (log::Level::Error, "console-error-水\nsecond-error-line\n"),
            ];
            let mut expected = Vec::new();
            for (level, record) in records {
                logger.lifecycle_dispatch(level, record);
                expected.extend_from_slice(record.as_bytes());
            }
            assert_eq!(
                std::fs::read(snapshot(&logger).active_file).unwrap(),
                expected
            );
        }
        "trace" => {
            success(ApplicationLogger::install(&configured));
            log::set_max_level(log::LevelFilter::Warn);
            let logger = ApplicationLogger::lifecycle_published().unwrap();
            let metadata = log::Metadata::builder().level(log::Level::Trace).build();
            assert!(log::Log::enabled(logger, &metadata));
            log::Log::log(
                logger,
                &log::Record::builder()
                    .args(format_args!("direct-trace-識別"))
                    .level(log::Level::Trace)
                    .file(Some("direct.rs"))
                    .line(Some(41))
                    .build(),
            );
            let before = std::fs::read(ApplicationLogger::status().unwrap().active_file).unwrap();
            assert!(
                std::str::from_utf8(&before)
                    .unwrap()
                    .contains("direct-trace-識別")
            );
            log::trace!("facade-trace-must-be-filtered");
            ApplicationLogger::emit_gui_log(
                log::Level::Trace,
                "host.rs",
                42,
                "host-trace-must-be-filtered",
                None,
                None,
            );
            assert_eq!(
                std::fs::read(ApplicationLogger::status().unwrap().active_file).unwrap(),
                before
            );
        }
        "clear_deletion" => {
            let logger = success(ApplicationLogger::new(&configured));
            let old = snapshot(&logger);
            let blocked_file = root.join("controlled-unremovable-file");
            let blocked_dir = root.join("controlled-unremovable-directory");
            let deletable = root.join("deletable-old-file");
            std::fs::write(&blocked_file, b"leave-file").unwrap();
            std::fs::create_dir(&blocked_dir).unwrap();
            std::fs::write(blocked_dir.join("child"), b"leave-directory").unwrap();
            std::fs::write(&deletable, b"remove").unwrap();
            control.fail(Point::Delete, Some(blocked_file.clone()), 0);
            control.fail(Point::Delete, Some(blocked_dir.clone()), 0);
            let cleared = success(logger.clear_instance());
            assert!(!old.active_file.exists());
            assert!(!deletable.exists());
            assert_eq!(std::fs::read(blocked_file).unwrap(), b"leave-file");
            assert_eq!(
                std::fs::read(blocked_dir.join("child")).unwrap(),
                b"leave-directory"
            );
            assert_eq!(snapshot(&logger), cleared);
            logger.lifecycle_dispatch(log::Level::Info, "after-partial-delete\n");
            assert_eq!(
                std::fs::read(cleared.active_file).unwrap(),
                b"after-partial-delete\n"
            );
            // Force the very first deletion to fail, independent of read_dir order.
            let second_old_paths = entries(&root);
            control.fail(Point::Delete, None, 0);
            let second = success(logger.clear_instance());
            let failed_path = control
                .0
                .lock()
                .unwrap()
                .failed_deletions
                .last()
                .unwrap()
                .clone();
            assert!(failed_path.exists());
            for old_path in second_old_paths {
                if old_path != failed_path {
                    assert!(
                        !old_path.exists(),
                        "deletion continues after its first failure"
                    );
                }
            }
            assert!(second.active_file.is_file());
            assert_eq!(snapshot(&logger), second);
        }
        "rotation_failure" => {
            let logger = success(ApplicationLogger::new(&configured));
            persist(&logger, &vec![b'P'; MAX_LOG_FILE_BYTES as usize - 1]);
            let before = snapshot(&logger);
            control.fail(Point::RotationOpen, None, 0);
            logger.lifecycle_dispatch(log::Level::Info, "rotation-rejected-λ\n");
            let failed = snapshot(&logger);
            assert_eq!(failed.active_file.file_name().unwrap(), "1.log");
            assert!(!failed.active_file.exists());
            assert_eq!(failed.active_file_size_bytes, before.active_file_size_bytes);
            assert_eq!(
                std::fs::metadata(&before.active_file).unwrap().len(),
                before.active_file_size_bytes
            );
            logger.lifecycle_dispatch(log::Level::Info, "x");
            assert_eq!(snapshot(&logger).active_file, failed.active_file);
            assert_eq!(snapshot(&logger).active_file_size_bytes, MAX_LOG_FILE_BYTES);
            assert!(std::fs::read(&before.active_file).unwrap().ends_with(b"x"));
            logger.lifecycle_dispatch(log::Level::Info, "later-successful-rotation\n");
            let recovered = snapshot(&logger);
            assert_eq!(recovered.active_file.file_name().unwrap(), "2.log");
            assert_eq!(
                std::fs::read(recovered.active_file).unwrap(),
                b"later-successful-rotation\n"
            );
        }
        "partial_write" | "flush_failure" => {
            let logger = success(ApplicationLogger::new(&configured));
            logger.lifecycle_dispatch(log::Level::Info, "settled\n");
            let before = snapshot(&logger);
            let record = b"failed-operation-record\n";
            control.fail(
                if case == "partial_write" {
                    Point::Write
                } else {
                    Point::Flush
                },
                None,
                4,
            );
            logger.lifecycle_dispatch(log::Level::Info, std::str::from_utf8(record).unwrap());
            assert_eq!(snapshot(&logger), before);
            let mut expected = b"settled\n".to_vec();
            expected.extend_from_slice(if case == "partial_write" {
                &record[..4]
            } else {
                record
            });
            assert_eq!(std::fs::read(&before.active_file).unwrap(), expected);
            logger.lifecycle_dispatch(log::Level::Info, "recovered\n");
            expected.extend_from_slice(b"recovered\n");
            assert_eq!(std::fs::read(&before.active_file).unwrap(), expected);
            assert_eq!(
                snapshot(&logger).active_file_size_bytes,
                before.active_file_size_bytes + 10
            );
        }
        "install_race" => {
            let barrier = Arc::new(std::sync::Barrier::new(6));
            let mut workers = Vec::new();
            for worker in 0..6 {
                let home = home.join(format!("racer-{worker}"));
                let barrier = barrier.clone();
                let control = control.clone();
                workers.push(std::thread::spawn(move || {
                    let _scope = Scope::enter(control);
                    let paths = paths(&home);
                    barrier.wait();
                    success(ApplicationLogger::install(&paths));
                    assert!(paths.logs_root().is_dir());
                    assert!(
                        entries(&paths.logs_root())
                            .iter()
                            .any(|path| path.join("0.log").is_file())
                    );
                }));
            }
            for worker in workers {
                worker.join().unwrap();
            }
            let selected = ApplicationLogger::status().unwrap();
            log::info!("facade-after-install-race");
            assert!(
                std::fs::read_to_string(&selected.active_file)
                    .unwrap()
                    .contains("facade-after-install-race")
            );
            assert_eq!(ApplicationLogger::logs_root(), Some(selected.logs_root));
        }
        _ => panic!("unknown isolated scenario: {case}"),
    }
}
