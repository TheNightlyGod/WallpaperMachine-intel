// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
use std::{
    io,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    thread::{self, JoinHandle},
};

use objc2::MainThreadMarker;

use crate::{
    EngineError,
    display::watcher::{DisplayEvent, DisplayWatcher, QueueHandle},
};

/// What a display-change registration refreshes when the display layout
/// changes.
pub trait DisplayRefreshTarget: Send + Sync + 'static {
    fn schedule(&self);
}

/// No refresh thread exists.
const QUIET: u8 = 0;
/// A worker owns the next refresh, but has not admitted it yet.
const QUEUED: u8 = 1;
/// The worker admitted a call to the weak target.
const RUNNING: u8 = 2;
/// Events during queued/running work request exactly one trailing refresh.
const DIRTY: u8 = 4;
/// Terminal bit: neither a queued nor a trailing call may be admitted.
/// Keep worker bits until that worker acknowledges cancellation/completion.
const RETIRED: u8 = 8;

/// Everything one registration shares with its consumer and refresh threads.
/// The whole coalescing protocol lives in the single `phase` atomic.
struct Refresher<T: DisplayRefreshTarget> {
    subject: Weak<T>,
    phase: AtomicU8,
}

impl<T: DisplayRefreshTarget> Refresher<T> {
    fn new(subject: Weak<T>) -> Arc<Self> {
        Arc::new(Self {
            subject,
            phase: AtomicU8::new(QUIET),
        })
    }

    fn is_retired(&self) -> bool {
        self.phase.load(Ordering::Acquire) & RETIRED != 0
    }

    fn retire(&self) {
        // This RMW and admit_refresh's CAS share one modification order.
        // Already admitted target code may finish, but retirement never waits
        // for it and no worker can admit another call afterwards.
        self.phase.fetch_or(RETIRED, Ordering::AcqRel);
    }

    /// Consumer-side handling of one event. Returns false once the
    /// registration was dropped, which ends the consumer.
    fn on_event(self: &Arc<Self>, event: &DisplayEvent) -> bool {
        if self.is_retired() {
            return false;
        }
        log::debug!("[wallpaper-core display] event {event:?}");
        self.request_refresh();
        true
    }

    /// Records that a refresh is wanted; the caller that moves the phase out
    /// of `QUIET` is the one that starts the thread.
    fn request_refresh(self: &Arc<Self>) {
        self.request_refresh_with(|worker| {
            spawn_named("wallpaper-display-refresh", move || worker.refresh_loop()).map(|_| ())
        });
    }

    fn request_refresh_with(self: &Arc<Self>, spawn: impl FnOnce(Arc<Self>) -> io::Result<()>) {
        let previous = self
            .phase
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |phase| {
                if phase & RETIRED != 0 {
                    None
                } else if phase == QUIET {
                    Some(QUEUED)
                } else {
                    Some(phase | DIRTY)
                }
            });
        if previous != Ok(QUIET) {
            return;
        }
        if let Err(error) = spawn(Arc::clone(self)) {
            log::warn!("[wallpaper-core display] could not start a refresh thread: {error}");
            // No worker exists after a spawn error. Preserve concurrent
            // retirement; a later event can otherwise start a fresh worker.
            self.phase.fetch_and(RETIRED, Ordering::AcqRel);
        }
    }

    /// The refresh-start linearization point. A queued worker must win this
    /// transition before it may upgrade the weak target and call schedule().
    fn admit_refresh(&self) -> bool {
        let started = self
            .phase
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |phase| {
                if phase & RETIRED != 0 {
                    // Acknowledge cancellation of this queued worker.
                    Some(RETIRED)
                } else if phase & QUEUED != 0 {
                    Some(RUNNING | (phase & DIRTY))
                } else {
                    None
                }
            });
        matches!(started, Ok(phase) if phase & RETIRED == 0)
    }

    /// The same worker owns trailing work; events racing with completion are
    /// either included in that trailing call or queue a new worker from QUIET.
    fn refresh_loop(&self) {
        while self.admit_refresh() {
            self.refresh_once();
            if !self.complete_refresh() {
                return;
            }
        }
    }

    fn complete_refresh(&self) -> bool {
        let finished = self
            .phase
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |phase| {
                if phase & RETIRED != 0 {
                    Some(RETIRED)
                } else if phase & DIRTY != 0 {
                    Some(QUEUED)
                } else {
                    Some(QUIET)
                }
            });
        // Do not try admission again after publishing QUIET: a new worker
        // may already own a later event's QUEUED state.
        matches!(finished, Ok(phase) if phase & RETIRED == 0 && phase & DIRTY != 0)
    }

    fn refresh_once(&self) {
        let Some(target) = self.subject.upgrade() else {
            return;
        };
        let contained =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| target.schedule()));
        if contained.is_err() {
            log::warn!("[wallpaper-core display] a display refresh panicked and was contained");
        }
    }

    #[cfg(test)]
    fn is_quiet(&self) -> bool {
        self.phase.load(Ordering::Acquire) & (QUEUED | RUNNING) == 0
    }
}

fn spawn_named(name: &str, body: impl FnOnce() + Send + 'static) -> io::Result<JoinHandle<()>> {
    thread::Builder::new().name(name.to_owned()).spawn(body)
}

/// A live subscription of one [`DisplayRefreshTarget`] to display
/// reconfiguration events.
pub struct DisplayChangeRegistration<T: DisplayRefreshTarget> {
    shared: Arc<Refresher<T>>,
    /// The consumer's event queue; closing it on drop ends the consumer
    /// thread at once instead of at the next display event.
    queue: QueueHandle,
}

/// Flipped by the first registration; the system callback is installed once.
static CALLBACK_INSTALLED: AtomicBool = AtomicBool::new(false);

fn install_system_callback_once() {
    if CALLBACK_INSTALLED.swap(true, Ordering::AcqRel) {
        return;
    }
    match MainThreadMarker::new() {
        Some(_) => DisplayWatcher::setup(),
        None => crate::window::run_on_main_thread(DisplayWatcher::setup),
    }
}

impl<T: DisplayRefreshTarget> DisplayChangeRegistration<T> {
    pub fn register(target: &Arc<T>) -> Result<Self, EngineError> {
        install_system_callback_once();
        let watcher = DisplayWatcher::new();
        let queue = watcher.queue_handle();
        let shared = Refresher::new(Arc::downgrade(target));
        let consumer = Arc::clone(&shared);
        spawn_named("wallpaper-display-watcher", move || {
            std::iter::from_fn(|| watcher.next_event()).all(|event| consumer.on_event(&event));
        })
        .map_err(|error| {
            EngineError::Platform(format!("failed to start display watcher thread: {error}"))
        })?;
        Ok(Self { shared, queue })
    }
}

impl<T: DisplayRefreshTarget> Drop for DisplayChangeRegistration<T> {
    fn drop(&mut self) {
        // The consumer may be parked on the next event; closing its queue
        // wakes it (it is not joined), and the terminal phase rejects work.
        self.shared.retire();
        self.queue.close();
    }
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Condvar, Mutex, atomic::AtomicUsize},
        time::{Duration, Instant},
    };

    use super::*;

    /// A target whose refresh can be held open and that counts its runs.
    #[derive(Default)]
    struct Probe {
        runs: AtomicUsize,
        hold: Mutex<bool>,
        hold_changed: Condvar,
        blow_up_next: AtomicBool,
    }

    impl Probe {
        fn set_hold(&self, on: bool) {
            *self.hold.lock().unwrap_or_else(|e| e.into_inner()) = on;
            self.hold_changed.notify_all();
        }

        fn runs(&self) -> usize {
            self.runs.load(Ordering::Acquire)
        }
    }

    impl DisplayRefreshTarget for Probe {
        fn schedule(&self) {
            let _ = self.runs.fetch_add(1, Ordering::AcqRel);
            let guard = self.hold.lock().unwrap_or_else(|e| e.into_inner());
            let _held = self
                .hold_changed
                .wait_timeout_while(guard, Duration::from_secs(5), |held| *held)
                .unwrap_or_else(|e| e.into_inner());
            assert!(
                !self.blow_up_next.swap(false, Ordering::AcqRel),
                "probe refresh failed"
            );
        }
    }

    fn spin_for(what: &str, mut ready: impl FnMut() -> bool) {
        let give_up = Instant::now() + Duration::from_secs(5);
        while !ready() {
            assert!(Instant::now() < give_up, "timed out waiting for {what}");
            thread::yield_now();
        }
    }

    fn fresh_probe() -> (Arc<Probe>, Arc<Refresher<Probe>>) {
        let probe = Arc::new(Probe::default());
        let refresher = Refresher::new(Arc::downgrade(&probe));
        (probe, refresher)
    }

    #[test]
    fn events_during_a_refresh_collapse_into_one_trailing_refresh() {
        let (probe, refresher) = fresh_probe();
        probe.set_hold(true);

        refresher.request_refresh();
        spin_for("the first refresh", || probe.runs() == 1);
        for _ in 0..7 {
            refresher.request_refresh();
        }
        probe.set_hold(false);

        spin_for("the trailing refresh", || {
            probe.runs() == 2 && refresher.is_quiet()
        });
        assert_eq!(probe.runs(), 2);
    }

    #[test]
    fn a_later_event_refreshes_again_after_a_refresh_ended() {
        let (probe, refresher) = fresh_probe();

        refresher.request_refresh();
        spin_for("the first refresh to end", || {
            probe.runs() == 1 && refresher.is_quiet()
        });
        refresher.request_refresh();
        spin_for("the second refresh to end", || {
            probe.runs() == 2 && refresher.is_quiet()
        });

        assert_eq!(probe.runs(), 2);
    }

    #[test]
    fn a_panicking_refresh_is_contained_and_does_not_block_later_ones() {
        let (probe, refresher) = fresh_probe();
        probe.blow_up_next.store(true, Ordering::Release);

        refresher.request_refresh();
        spin_for("the failing refresh to end", || {
            probe.runs() == 1 && refresher.is_quiet()
        });
        refresher.request_refresh();

        spin_for("a refresh after the failure", || {
            probe.runs() == 2 && refresher.is_quiet()
        });
    }

    #[test]
    fn a_refresh_for_a_dropped_target_ends_and_the_next_event_starts_another() {
        let (probe, refresher) = fresh_probe();
        drop(probe);

        refresher.request_refresh();
        spin_for("the idle refresh to end", || refresher.is_quiet());
        assert!(refresher.on_event(&DisplayEvent::ModeChanged(1)));
        spin_for("the second idle refresh to end", || refresher.is_quiet());
    }

    #[test]
    fn a_retired_refresher_ignores_events() {
        let (probe, refresher) = fresh_probe();
        refresher.retire();

        assert!(!refresher.on_event(&DisplayEvent::Connected(2)));
        refresher.request_refresh();

        assert_eq!(probe.runs(), 0);
        assert!(refresher.is_quiet());
    }

    #[test]
    fn a_retired_refresher_does_not_run_the_trailing_refresh() {
        let (probe, refresher) = fresh_probe();
        probe.set_hold(true);

        refresher.request_refresh();
        spin_for("the first refresh", || probe.runs() == 1);
        refresher.request_refresh();
        refresher.retire();
        probe.set_hold(false);

        spin_for("the thread to wind down", || refresher.is_quiet());
        assert_eq!(probe.runs(), 1);
    }

    // The launcher hands the worker to the test instead of the OS scheduler,
    // so retirement always precedes the worker's first admission attempt.
    fn queued_worker<T: DisplayRefreshTarget>(refresher: &Arc<Refresher<T>>) -> Arc<Refresher<T>> {
        let mut queued = None;
        refresher.request_refresh_with(|worker| {
            queued = Some(worker);
            Ok(())
        });
        queued.expect("an idle refresher queues one worker")
    }

    fn registration<T: DisplayRefreshTarget>(
        shared: &Arc<Refresher<T>>,
    ) -> DisplayChangeRegistration<T> {
        DisplayChangeRegistration {
            shared: Arc::clone(shared),
            queue: DisplayWatcher::new().queue_handle(),
        }
    }

    #[test]
    fn dropping_registration_cancels_a_worker_that_has_not_started() {
        let (probe, refresher) = fresh_probe();
        let registration = registration(&refresher);
        let queued = queued_worker(&refresher);
        refresher.request_refresh();

        drop(registration);
        queued.refresh_loop();

        assert_eq!(probe.runs(), 0);
        assert!(refresher.is_quiet());
    }

    #[test]
    fn dropping_registration_does_not_join_active_target_or_start_its_trailing_work() {
        use std::sync::mpsc::{Receiver, sync_channel};

        struct HeldTarget {
            runs: AtomicUsize,
            entered: std::sync::mpsc::SyncSender<()>,
            release: Mutex<Receiver<()>>,
        }
        impl DisplayRefreshTarget for HeldTarget {
            fn schedule(&self) {
                self.runs.fetch_add(1, Ordering::AcqRel);
                self.entered.try_send(()).unwrap();
                self.release
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(10))
                    .unwrap();
            }
        }

        let (entered_tx, entered) = sync_channel(1);
        let (release, release_rx) = sync_channel(1);
        let target = Arc::new(HeldTarget {
            runs: AtomicUsize::new(0),
            entered: entered_tx,
            release: Mutex::new(release_rx),
        });
        let refresher = Refresher::new(Arc::downgrade(&target));
        let registration = registration(&refresher);
        let queued = queued_worker(&refresher);
        let worker = thread::spawn(move || queued.refresh_loop());
        entered.recv_timeout(Duration::from_secs(5)).unwrap();
        for _ in 0..9 {
            refresher.request_refresh();
        }
        let (dropped_tx, dropped) = sync_channel(1);
        let dropper = thread::spawn(move || {
            drop(registration);
            dropped_tx.send(()).unwrap();
        });
        let returned_without_target = dropped.recv_timeout(Duration::from_secs(5));
        // Always unblock the target before asserting, even on a failed test.
        release.send(()).unwrap();
        dropper.join().unwrap();
        worker.join().unwrap();

        assert!(
            returned_without_target.is_ok(),
            "drop waited for target.schedule()"
        );
        assert_eq!(target.runs.load(Ordering::Acquire), 1);
        assert!(refresher.is_quiet());
    }

    #[test]
    fn retirement_between_completion_and_trailing_admission_cancels_the_trailing_call() {
        let (probe, refresher) = fresh_probe();
        let registration = registration(&refresher);
        let worker = queued_worker(&refresher);
        assert!(worker.admit_refresh());
        worker.refresh_once();
        for _ in 0..5 {
            refresher.request_refresh();
        }
        assert!(worker.complete_refresh());

        drop(registration);
        worker.refresh_loop();

        assert_eq!(probe.runs(), 1);
        assert!(refresher.is_retired());
    }

    #[test]
    fn retirement_does_not_revoke_an_already_admitted_call() {
        let (probe, refresher) = fresh_probe();
        let registration = registration(&refresher);
        let worker = queued_worker(&refresher);
        assert!(worker.admit_refresh());
        drop(registration);

        // Admission, not entry into arbitrary target code, is the boundary.
        worker.refresh_once();
        assert!(!worker.complete_refresh());
        assert_eq!(probe.runs(), 1);
        assert!(refresher.is_retired());
    }

    #[test]
    fn spawn_failure_cannot_undo_concurrent_retirement() {
        let (probe, refresher) = fresh_probe();
        let registration = registration(&refresher);
        refresher.request_refresh_with(|_| {
            drop(registration);
            Err(io::Error::other("injected failure after retirement"))
        });
        refresher.request_refresh_with(|_| panic!("retired registrations cannot launch workers"));

        assert!(refresher.is_retired());
        assert_eq!(probe.runs(), 0);
    }

    #[test]
    fn registration_is_send_sync_and_queued_workers_do_not_keep_the_target_alive() {
        fn send_sync<T: Send + Sync>() {}
        send_sync::<DisplayChangeRegistration<Probe>>();
        let (probe, refresher) = fresh_probe();
        let worker = queued_worker(&refresher);
        assert_eq!(Arc::strong_count(&probe), 1);
        let weak = Arc::downgrade(&probe);
        drop(probe);
        assert!(weak.upgrade().is_none());
        worker.refresh_loop();
        assert!(refresher.is_quiet());
    }

    #[test]
    fn queued_events_coalesce_and_later_events_still_start_workers() {
        let (probe, refresher) = fresh_probe();
        let queued = queued_worker(&refresher);
        for _ in 0..11 {
            refresher.request_refresh();
        }
        queued.refresh_loop();
        assert_eq!(probe.runs(), 2);
        assert!(refresher.is_quiet());

        queued_worker(&refresher).refresh_loop();
        assert_eq!(probe.runs(), 3);
    }

    #[test]
    fn controlled_workers_recover_after_panic_missing_target_and_spawn_failure() {
        let (probe, refresher) = fresh_probe();
        refresher.request_refresh_with(|_| Err(io::Error::other("injected spawn failure")));
        assert!(refresher.is_quiet());
        probe.blow_up_next.store(true, Ordering::Release);
        queued_worker(&refresher).refresh_loop();
        assert_eq!(probe.runs(), 1);
        assert!(refresher.is_quiet());
        queued_worker(&refresher).refresh_loop();
        assert_eq!(probe.runs(), 2);
        drop(probe);
        queued_worker(&refresher).refresh_loop();
        assert!(refresher.is_quiet());
        queued_worker(&refresher).refresh_loop();
        assert!(refresher.is_quiet());
    }
}
