//! A record of the wallpapers a process was opening, so that one which took the
//! whole app down twice in a row is held back instead of crashing every launch.
//!
//! The saved configuration is replayed at every launch. A scene that kills the
//! process while it loads (a renderer fault, an out-of-memory kill, a bad
//! driver state) would therefore kill the next launch the same way, and the one
//! after that. The journal breaks that loop without deleting anything:
//!
//! * [`LoadJournal::begin`] writes the wallpapers that are *about to open* to
//!   `load-journal.json` before the engine is asked to open them.
//! * [`LoadTicket::succeed`] keeps them recorded for a short settle window after
//!   the first frame, because a scene can also die just after it starts.
//!   When the window ends the entries and the wallpaper's strikes are cleared.
//! * A ticket that is dropped without succeeding (the load failed, returned
//!   early, or panicked) leaves no trace: the process is alive and the failure
//!   was reported.
//! * [`LoadJournal::clean_shutdown`] is the app quitting on purpose. It closes
//!   the record at once, from whichever thread the quit runs on, and nothing
//!   that starts opening afterwards is recorded: a load that outlives the
//!   quit's deadline must not be blamed on its wallpaper.
//! * [`LoadJournal::open`] runs at the next launch. Entries left behind by a
//!   *different* session mean that session died mid-load, so each of those
//!   wallpapers earns one strike. At [`HOLD_AFTER_STRIKES`] consecutive strikes
//!   the wallpaper is [held](LoadJournal::held): activation plans skip it until
//!   the user applies it again ([`LoadJournal::forgive`]) or the app is updated.
//!
//! Writes happen only when a scene is actually going to open and once when the
//! settle window ends, never on a timer and never for a reconcile that opens
//! nothing.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt, fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

/// Consecutive deaths while opening the same wallpaper before it is held back.
///
/// One death proves little: a force quit, a power loss or a logout kill during
/// a slow load looks identical to a crash from here. Two in a row do not.
pub const HOLD_AFTER_STRIKES: u32 = 2;

/// How long an opened scene stays on record after its first frame.
pub const SETTLE: Duration = Duration::from_secs(20);

/// The file name under the support root.
pub const FILE_NAME: &str = "load-journal.json";

const VERSION: u32 = 1;

type Clock = Arc<dyn Fn() -> u64 + Send + Sync>;

/// How many consecutive sessions died while opening one wallpaper.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Strike {
    pub count: u32,
    /// Unix seconds of the launch that recorded the latest strike.
    pub last_at: u64,
    /// The display the wallpaper was opening on.
    pub display: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct InFlight {
    wallpaper: String,
    display: u32,
    started_at: u64,
    /// Set once the scene reported its first frame: the entry then stays until
    /// this moment so that a death just after loading is still attributed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    settled_until: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Document {
    version: u32,
    /// The build that wrote the file. A different build releases every hold.
    build: String,
    /// Which process wrote the file last.
    session: String,
    #[serde(default)]
    strikes: BTreeMap<String, Strike>,
    #[serde(default)]
    in_flight: Vec<InFlight>,
}

struct Flight {
    attempt: u64,
    entry: InFlight,
}

struct Inner {
    path: Option<PathBuf>,
    build: String,
    session: String,
    strikes: BTreeMap<String, Strike>,
    in_flight: Vec<Flight>,
    next_attempt: u64,
    settle: Duration,
    clock: Clock,
    /// Set by [`LoadJournal::clean_shutdown`]; nothing is recorded after it.
    closed: bool,
}

/// The shared handle to the journal. Cheap to clone; every clone sees the same
/// state.
#[derive(Clone)]
pub struct LoadJournal {
    inner: Arc<Mutex<Inner>>,
}

impl fmt::Debug for LoadJournal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let inner = self.lock();
        formatter
            .debug_struct("LoadJournal")
            .field("path", &inner.path)
            .field("strikes", &inner.strikes)
            .field("in_flight", &inner.in_flight.len())
            .finish_non_exhaustive()
    }
}

impl LoadJournal {
    /// Reads the journal under `root` and settles what the previous session
    /// left behind. With no root the journal lives in memory only.
    ///
    /// `build` identifies the running build. A journal written by another
    /// build is discarded: the code that crashed is gone.
    #[must_use]
    pub fn open(root: Option<&Path>, build: &str) -> Self {
        Self::open_with(root, build, Arc::new(unix_now), SETTLE)
    }

    pub(crate) fn open_with(
        root: Option<&Path>,
        build: &str,
        clock: Clock,
        settle: Duration,
    ) -> Self {
        let mut inner = Inner {
            path: root.map(|root| root.join(FILE_NAME)),
            build: build.to_string(),
            session: new_session_id(),
            strikes: BTreeMap::new(),
            in_flight: Vec::new(),
            next_attempt: 1,
            settle,
            clock,
            closed: false,
        };
        inner.adopt_previous_session();
        Self {
            inner: Arc::new(Mutex::new(inner)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Wallpapers that are held back: they died while opening in
    /// [`HOLD_AFTER_STRIKES`] sessions in a row.
    #[must_use]
    pub fn held(&self) -> BTreeSet<String> {
        self.lock()
            .strikes
            .iter()
            .filter(|(_, strike)| strike.count >= HOLD_AFTER_STRIKES)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Every wallpaper with at least one strike, for diagnostics.
    #[must_use]
    pub fn strikes(&self) -> BTreeMap<String, Strike> {
        self.lock().strikes.clone()
    }

    /// Records that the engine is about to open these `(wallpaper, display)`
    /// pairs. An empty list is a no-op that never touches the disk.
    ///
    /// The returned ticket must outlive the whole load, up to and including
    /// the work that follows the first frame.
    pub fn begin(&self, openings: Vec<(String, u32)>) -> LoadTicket {
        if openings.is_empty() {
            return LoadTicket {
                journal: self.clone(),
                attempt: None,
            };
        }
        let mut inner = self.lock();
        if inner.closed {
            // The app is on its way out: whatever dies now was not a crash.
            log::debug!(
                "load journal: closed for quitting; {} opening(s) not recorded",
                openings.len()
            );
            return LoadTicket {
                journal: self.clone(),
                attempt: None,
            };
        }
        let attempt = inner.next_attempt;
        inner.next_attempt += 1;
        let now = (inner.clock)();
        for (wallpaper, display) in openings {
            log::debug!("load journal: opening {wallpaper} on display {display}");
            inner.in_flight.push(Flight {
                attempt,
                entry: InFlight {
                    wallpaper,
                    display,
                    started_at: now,
                    settled_until: None,
                },
            });
        }
        inner.persist();
        LoadTicket {
            journal: self.clone(),
            attempt: Some(attempt),
        }
    }

    /// Clears a wallpaper's strikes because the user applied it again.
    ///
    /// Returns whether it was held, which is when the caller has to open it.
    pub fn forgive(&self, wallpaper_id: &str) -> bool {
        let mut inner = self.lock();
        let Some(strike) = inner.strikes.remove(wallpaper_id) else {
            return false;
        };
        let was_held = strike.count >= HOLD_AFTER_STRIKES;
        if was_held {
            log::info!("load journal: released {wallpaper_id} (by the user)");
        }
        inner.persist();
        was_held
    }

    /// The app is quitting on purpose: a load that is still running was not a
    /// crash, so nothing in flight may count against the wallpaper, and
    /// nothing that starts opening from here on is recorded.
    ///
    /// Safe to call from any thread and while the actor is busy: the quit
    /// calls it before it asks the actor to shut down, because a load that
    /// holds the actor (startup waits for its first frame) delays that
    /// request past the time the system gives a quit.
    pub fn clean_shutdown(&self) {
        let mut inner = self.lock();
        inner.closed = true;
        if inner.in_flight.is_empty() {
            return;
        }
        inner.in_flight.clear();
        inner.persist();
    }

    /// Forgets strikes for wallpapers that are no longer installed, so a hold
    /// cannot outlive its files.
    pub fn prune(&self, keep: &BTreeSet<String>) {
        let mut inner = self.lock();
        let before = inner.strikes.len();
        inner.strikes.retain(|id, _| keep.contains(id));
        if inner.strikes.len() != before {
            inner.persist();
        }
    }
}

impl Inner {
    /// Reads the file left by an earlier process and turns what it left in
    /// flight into strikes.
    fn adopt_previous_session(&mut self) {
        let Some(path) = self.path.clone() else {
            return;
        };
        let document = match read_document(&path) {
            Read::Missing => return,
            Read::Unusable(reason) => {
                let aside = path.with_file_name(format!("{FILE_NAME}.corrupt"));
                match fs::rename(&path, &aside) {
                    Ok(()) => log::warn!(
                        "load journal: set aside an unusable journal ({reason}) as {}",
                        aside.display()
                    ),
                    Err(error) => log::warn!(
                        "load journal: unusable journal ({reason}) could not be set aside: {error}"
                    ),
                }
                return;
            }
            Read::Document(document) => document,
        };

        if document.build != self.build {
            let released = document
                .strikes
                .values()
                .filter(|strike| strike.count >= HOLD_AFTER_STRIKES)
                .count();
            if released > 0 {
                log::info!(
                    "load journal: released {released} held wallpaper(s) after update \
                     ({} -> {})",
                    document.build,
                    self.build
                );
            }
            // Nothing the old build left in flight says anything about this one.
            self.persist();
            return;
        }

        self.strikes = document.strikes;
        let now = (self.clock)();
        let mut seen = BTreeSet::new();
        for entry in &document.in_flight {
            if !seen.insert(entry.wallpaper.clone()) {
                continue;
            }
            let strike = self
                .strikes
                .entry(entry.wallpaper.clone())
                .or_insert(Strike {
                    count: 0,
                    last_at: now,
                    display: entry.display,
                });
            strike.count += 1;
            strike.last_at = now;
            strike.display = entry.display;
            log::warn!(
                "load journal: previous session died while opening {} (display {}); strike {}/{}",
                entry.wallpaper,
                entry.display,
                strike.count,
                HOLD_AFTER_STRIKES
            );
        }
        if !document.in_flight.is_empty() {
            self.persist();
        }
    }

    fn persist(&self) {
        let Some(path) = &self.path else {
            return;
        };
        let document = Document {
            version: VERSION,
            build: self.build.clone(),
            session: self.session.clone(),
            strikes: self.strikes.clone(),
            in_flight: self
                .in_flight
                .iter()
                .map(|flight| flight.entry.clone())
                .collect(),
        };
        if let Err(error) = write_document(path, &document) {
            // A journal that cannot be written must never block a load.
            log::warn!("load journal: could not write {}: {error}", path.display());
        }
    }

    fn remove_attempt(&mut self, attempt: u64) -> Vec<String> {
        let mut removed = Vec::new();
        self.in_flight.retain(|flight| {
            if flight.attempt == attempt {
                removed.push(flight.entry.wallpaper.clone());
                false
            } else {
                true
            }
        });
        removed
    }
}

/// Proof that a set of wallpapers is being opened. See [`LoadJournal::begin`].
#[must_use = "dropping a ticket ends the record; hold it for the whole load"]
pub struct LoadTicket {
    journal: LoadJournal,
    attempt: Option<u64>,
}

impl fmt::Debug for LoadTicket {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LoadTicket")
            .field("attempt", &self.attempt)
            .finish_non_exhaustive()
    }
}

impl LoadTicket {
    /// The scenes opened and the work that follows them finished. The entries
    /// stay on record for the settle window, then they and the wallpapers'
    /// strikes are cleared.
    pub fn succeed(mut self) {
        let Some(attempt) = self.attempt.take() else {
            return;
        };
        let settle = {
            let mut inner = self.journal.lock();
            let until = (inner.clock)() + inner.settle.as_secs();
            let mut marked = false;
            for flight in &mut inner.in_flight {
                if flight.attempt == attempt {
                    flight.entry.settled_until = Some(until);
                    marked = true;
                }
            }
            if !marked {
                // `clean_shutdown` already ended the record.
                return;
            }
            inner.persist();
            inner.settle
        };
        let journal = self.journal.clone();
        match tokio::runtime::Handle::try_current() {
            Ok(runtime) => {
                drop(runtime.spawn(async move {
                    tokio::time::sleep(settle).await;
                    journal.finish_settling(attempt);
                }));
            }
            // Nothing can run a timer, so there is nothing to wait for.
            Err(_) => journal.finish_settling(attempt),
        }
    }
}

impl Drop for LoadTicket {
    fn drop(&mut self) {
        let Some(attempt) = self.attempt.take() else {
            return;
        };
        let mut inner = self.journal.lock();
        if !inner.remove_attempt(attempt).is_empty() {
            inner.persist();
        }
    }
}

impl LoadJournal {
    fn finish_settling(&self, attempt: u64) {
        let mut inner = self.lock();
        let survivors = inner.remove_attempt(attempt);
        if survivors.is_empty() {
            return;
        }
        for wallpaper in &survivors {
            if inner.strikes.remove(wallpaper).is_some() {
                log::debug!("load journal: {wallpaper} survived its load; strikes cleared");
            }
        }
        log::debug!("load journal: settled {}", survivors.join(", "));
        inner.persist();
    }
}

enum Read {
    Missing,
    Unusable(String),
    Document(Document),
}

fn read_document(path: &Path) -> Read {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Read::Missing,
        Err(error) => return Read::Unusable(error.to_string()),
    };
    match serde_json::from_slice::<Document>(&bytes) {
        Ok(document) if document.version == VERSION => Read::Document(document),
        Ok(document) => Read::Unusable(format!("unknown version {}", document.version)),
        Err(error) => Read::Unusable(error.to_string()),
    }
}

/// Writes through a temporary file and a rename, without syncing: the journal
/// has to survive the process dying, which the page cache does, and not a power
/// cut, which loses nothing worth keeping.
fn write_document(path: &Path, document: &Document) -> std::io::Result<()> {
    let bytes = serde_json::to_vec_pretty(document)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_file_name(format!("{FILE_NAME}.tmp"));
    fs::write(&temporary, bytes)?;
    fs::rename(&temporary, path)
}

/// Identifies the running build. The host sets `WALLPAPER_MACHINE_BUILD` to its
/// marketing version and build number, which change with every release the
/// updater installs; anything that runs without the host (tests, tools) falls
/// back to this crate's version.
#[must_use]
pub fn build_stamp() -> String {
    std::env::var("WALLPAPER_MACHINE_BUILD")
        .ok()
        .map(|stamp| stamp.trim().to_string())
        .filter(|stamp| !stamp.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

/// Different for every journal opened, including two in one process, which is
/// what lets a test play the part of "another process".
fn new_session_id() -> String {
    use std::hash::{BuildHasher, Hasher};

    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u32(std::process::id());
    hasher.write_u128(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos()),
    );
    format!("{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use std::{
        mem,
        sync::atomic::{AtomicU64, Ordering},
        time::Instant,
    };

    use super::*;

    const LONG: Duration = Duration::from_secs(3600);

    fn open(root: &Path, build: &str, settle: Duration) -> LoadJournal {
        LoadJournal::open_with(Some(root), build, Arc::new(|| 1_000), settle)
    }

    fn file(root: &Path) -> serde_json::Value {
        serde_json::from_slice(&fs::read(root.join(FILE_NAME)).unwrap()).unwrap()
    }

    /// A process that died while opening: the ticket never ends.
    fn die_while_opening(journal: LoadJournal, wallpaper: &str, display: u32) {
        let ticket = journal.begin(vec![(wallpaper.to_string(), display)]);
        mem::forget(ticket);
    }

    fn ids(set: BTreeSet<String>) -> Vec<String> {
        set.into_iter().collect()
    }

    #[test]
    fn a_previous_session_that_died_while_opening_adds_one_strike() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);

        let next = open(root.path(), "1.0", LONG);

        let strikes = next.strikes();
        assert_eq!(strikes.len(), 1);
        assert_eq!(strikes["100"].count, 1);
        assert_eq!(strikes["100"].display, 7);
        assert!(next.held().is_empty(), "one death is not enough to hold");
        assert_eq!(
            file(root.path())["in_flight"].as_array().unwrap().len(),
            0,
            "the dead session's entries are settled into the strike"
        );
    }

    #[test]
    fn a_wallpaper_opening_on_two_displays_earns_one_strike() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);
        mem::forget(journal.begin(vec![("100".into(), 7), ("100".into(), 8)]));

        let next = open(root.path(), "1.0", LONG);

        assert_eq!(next.strikes()["100"].count, 1);
    }

    #[test]
    fn two_unfinished_launches_in_a_row_hold_the_wallpaper_and_it_stays_held_on_a_third_open() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);

        let third = open(root.path(), "1.0", LONG);
        assert_eq!(ids(third.held()), vec!["100".to_string()]);
        assert_eq!(file(root.path())["strikes"]["100"]["count"], 2);

        // The held wallpaper is not opened, so this launch dies of nothing.
        let fourth = open(root.path(), "1.0", LONG);
        assert_eq!(ids(fourth.held()), vec!["100".to_string()]);
    }

    #[test]
    fn strikes_belong_to_the_wallpaper_that_was_opening() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        die_while_opening(open(root.path(), "1.0", LONG), "200", 7);

        let next = open(root.path(), "1.0", LONG);

        assert!(next.held().is_empty());
        assert_eq!(next.strikes()["100"].count, 1);
        assert_eq!(next.strikes()["200"].count, 1);
    }

    #[tokio::test]
    async fn a_ticket_that_succeeds_stays_on_record_until_the_settle_window_ends() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);
        assert_eq!(journal.strikes()["100"].count, 1);

        journal.begin(vec![("100".into(), 7)]).succeed();

        assert_eq!(
            journal.strikes()["100"].count,
            1,
            "a first frame does not prove the scene is stable"
        );
        let entries = file(root.path())["in_flight"].clone();
        assert_eq!(entries[0]["wallpaper"], "100");
        assert!(
            entries[0]["settled_until"].is_u64(),
            "the entry carries the end of its window: {entries}"
        );
        // A death inside the window is still attributed to the wallpaper.
        assert_eq!(open(root.path(), "1.0", LONG).strikes()["100"].count, 2);
    }

    #[tokio::test]
    async fn a_ticket_that_succeeds_clears_strikes_after_the_settle_window() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", Duration::from_millis(50));
        assert_eq!(journal.strikes()["100"].count, 1);

        journal.begin(vec![("100".into(), 7)]).succeed();

        let deadline = Instant::now() + Duration::from_secs(10);
        while !journal.strikes().is_empty() {
            assert!(Instant::now() < deadline, "the settle window never ended");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let written = file(root.path());
        assert_eq!(written["in_flight"].as_array().unwrap().len(), 0);
        assert!(written["strikes"].as_object().unwrap().is_empty());
        assert!(
            open(root.path(), "1.0", LONG).strikes().is_empty(),
            "a settled load leaves nothing for the next launch to count"
        );
    }

    #[test]
    fn without_a_runtime_a_succeeded_ticket_settles_at_once() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);

        journal.begin(vec![("100".into(), 7)]).succeed();

        assert!(journal.strikes().is_empty());
        assert_eq!(file(root.path())["in_flight"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn a_dropped_ticket_leaves_no_strike() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);

        let ticket = journal.begin(vec![("100".into(), 7)]);
        assert_eq!(file(root.path())["in_flight"][0]["wallpaper"], "100");
        drop(ticket);

        assert_eq!(file(root.path())["in_flight"].as_array().unwrap().len(), 0);
        assert!(open(root.path(), "1.0", LONG).strikes().is_empty());
    }

    #[test]
    fn clean_shutdown_clears_in_flight_entries() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);
        let ticket = journal.begin(vec![("100".into(), 7)]);

        journal.clean_shutdown();
        // The load that was cut short still finishes and reports.
        ticket.succeed();

        assert_eq!(file(root.path())["in_flight"].as_array().unwrap().len(), 0);
        assert!(
            open(root.path(), "1.0", LONG).strikes().is_empty(),
            "quitting during a load is not a crash"
        );
    }

    #[test]
    fn nothing_is_recorded_once_the_app_is_quitting() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);
        journal.clean_shutdown();

        // A scene that starts opening during the exit, and a process that is
        // killed before the exit finishes.
        mem::forget(journal.begin(vec![("100".into(), 7)]));

        assert!(
            !root.path().join(FILE_NAME).exists(),
            "a quit in progress records nothing"
        );
        assert!(open(root.path(), "1.0", LONG).strikes().is_empty());
    }

    #[test]
    fn a_quit_on_another_thread_closes_a_record_the_loading_thread_still_holds() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);
        let ticket = journal.begin(vec![("100".into(), 7)]);

        let quitting = journal.clone();
        std::thread::spawn(move || quitting.clean_shutdown())
            .join()
            .unwrap();

        assert_eq!(file(root.path())["in_flight"].as_array().unwrap().len(), 0);
        mem::forget(ticket);
        assert!(open(root.path(), "1.0", LONG).strikes().is_empty());
    }

    #[test]
    fn a_new_build_releases_holds_and_forgets_what_the_old_build_left_in_flight() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        assert_eq!(open(root.path(), "1.0", LONG).held().len(), 1);
        die_while_opening(open(root.path(), "1.0", LONG), "200", 7);

        let updated = open(root.path(), "1.1", LONG);

        assert!(updated.held().is_empty());
        assert!(
            updated.strikes().is_empty(),
            "the old build's crash says nothing about the new one"
        );
        let written = file(root.path());
        assert_eq!(written["build"], "1.1");
        assert_eq!(written["in_flight"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn forgive_removes_a_hold() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);
        assert_eq!(journal.held().len(), 1);

        assert!(
            journal.forgive("100"),
            "a held wallpaper has to be reopened"
        );

        assert!(journal.held().is_empty());
        assert!(open(root.path(), "1.0", LONG).strikes().is_empty());
    }

    #[test]
    fn forgiving_a_wallpaper_that_was_not_held_changes_nothing_to_open() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);

        assert!(!journal.forgive("100"), "it was never held back");
        assert!(!journal.forgive("never-seen"));

        assert!(
            journal.strikes().is_empty(),
            "applying a wallpaper again starts its count over"
        );
    }

    #[test]
    fn a_corrupt_file_is_set_aside() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join(FILE_NAME), b"{ not json").unwrap();

        let journal = open(root.path(), "1.0", LONG);

        assert!(journal.strikes().is_empty());
        assert!(!root.path().join(FILE_NAME).exists());
        assert_eq!(
            fs::read(root.path().join("load-journal.json.corrupt")).unwrap(),
            b"{ not json"
        );
        // And the journal still works afterwards.
        die_while_opening(journal, "100", 7);
        assert_eq!(open(root.path(), "1.0", LONG).strikes()["100"].count, 1);
    }

    #[test]
    fn a_journal_from_an_unknown_version_is_set_aside() {
        let root = tempfile::tempdir().unwrap();
        fs::write(
            root.path().join(FILE_NAME),
            br#"{"version":99,"build":"1.0","session":"x","strikes":{"100":{"count":2,"last_at":1,"display":1}}}"#,
        )
        .unwrap();

        let journal = open(root.path(), "1.0", LONG);

        assert!(journal.held().is_empty());
        assert!(root.path().join("load-journal.json.corrupt").exists());
    }

    #[test]
    fn an_empty_begin_never_creates_or_rewrites_the_file() {
        let root = tempfile::tempdir().unwrap();
        let journal = open(root.path(), "1.0", LONG);

        journal.begin(Vec::new()).succeed();
        drop(journal.begin(Vec::new()));
        assert!(!root.path().join(FILE_NAME).exists());

        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);
        let before = fs::read(root.path().join(FILE_NAME)).unwrap();
        journal.begin(Vec::new()).succeed();
        journal.clean_shutdown();
        assert_eq!(fs::read(root.path().join(FILE_NAME)).unwrap(), before);
    }

    #[test]
    fn prune_drops_strikes_for_deleted_wallpapers() {
        let root = tempfile::tempdir().unwrap();
        die_while_opening(open(root.path(), "1.0", LONG), "100", 7);
        let journal = open(root.path(), "1.0", LONG);
        die_while_opening(journal, "200", 7);
        let journal = open(root.path(), "1.0", LONG);
        assert_eq!(journal.strikes().len(), 2);

        journal.prune(&BTreeSet::from(["100".to_string()]));

        assert_eq!(journal.strikes().keys().collect::<Vec<_>>(), vec!["100"]);
        assert!(file(root.path())["strikes"].get("200").is_none());
    }

    #[test]
    fn with_no_root_the_journal_lives_in_memory_and_never_fails() {
        let journal = LoadJournal::open(None, "1.0");

        journal.begin(vec![("100".into(), 7)]).succeed();
        drop(journal.begin(vec![("100".into(), 7)]));
        journal.clean_shutdown();

        assert!(journal.held().is_empty());
    }

    #[test]
    fn the_time_of_a_strike_comes_from_the_clock() {
        let root = tempfile::tempdir().unwrap();
        let now = Arc::new(AtomicU64::new(5_000));
        let clock: Clock = {
            let now = Arc::clone(&now);
            Arc::new(move || now.load(Ordering::SeqCst))
        };
        let first = LoadJournal::open_with(Some(root.path()), "1.0", Arc::clone(&clock), LONG);
        die_while_opening(first, "100", 7);
        now.store(9_000, Ordering::SeqCst);

        let next = LoadJournal::open_with(Some(root.path()), "1.0", clock, LONG);

        assert_eq!(next.strikes()["100"].last_at, 9_000);
    }
}
