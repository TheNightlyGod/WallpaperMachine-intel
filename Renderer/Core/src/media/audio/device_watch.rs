//! A debounced notification that the default output device changed.
//!
//! The system-audio tap is created once against whatever the Mac is playing
//! through. Switching to headphones or a USB DAC changes that, and a Bluetooth
//! device announces the change in a burst, so the tap is only rebuilt after the
//! notifications have stopped for [`OUTPUT_CHANGE_QUIET`].
//!
//! The `CoreAudio` HAL listener is registered once, the first time a watcher
//! starts, and never removed. It carries no per-watcher state: it only walks a
//! static table of debouncers, so a late callback can never reach freed memory.
//! A watcher adds itself to that table, with a thread of its own, and removes
//! both when dropped. Between watchers the listener stays registered and finds
//! the table empty: no thread wakes and nothing is logged, so what a process
//! that never needs a watcher pays is nothing, and what one that needed it once
//! keeps paying is that registration. The owner therefore holds a watcher only
//! while something wants the tap. The callback runs on a HAL thread and only
//! records the time and wakes the debouncer thread; it makes no HAL calls and
//! does not allocate.

use std::{
    ffi::c_void,
    fmt,
    ptr::{self, NonNull},
    sync::{
        Arc, Condvar, Mutex, MutexGuard, PoisonError,
        atomic::{AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use objc2_core_audio::{
    AudioObjectAddPropertyListener, AudioObjectID, AudioObjectPropertyAddress,
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyScopeGlobal,
};

use super::AudioCaptureError;

/// How long the default output device must stay unchanged before the change is
/// reported. Bluetooth devices announce a switch as several property changes in
/// quick succession; one rebuild covers all of them.
pub const OUTPUT_CHANGE_QUIET: Duration = Duration::from_millis(300);

const NO_ERR: i32 = 0;
const AUDIO_OBJECT_SYSTEM_OBJECT: AudioObjectID = 1;

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic elsewhere must not stop a HAL callback from waking the watcher.
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the debounce thread should do next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DebounceStep {
    /// Nothing is pending: sleep until a notification arrives.
    Idle,
    /// A notification is pending and the quiet period has this long left.
    Wait(Duration),
    /// The quiet period has passed: report the change once.
    Fire,
    /// The debouncer was cancelled: end the thread.
    Stop,
}

#[derive(Debug, Default)]
struct DebounceState {
    /// When the latest notification arrived; `None` once it has been reported.
    last_notified: Option<Instant>,
    cancelled: bool,
}

impl DebounceState {
    fn step(&mut self, now: Instant, quiet: Duration) -> DebounceStep {
        if self.cancelled {
            return DebounceStep::Stop;
        }
        let Some(last) = self.last_notified else {
            return DebounceStep::Idle;
        };
        let elapsed = now.saturating_duration_since(last);
        if elapsed >= quiet {
            self.last_notified = None;
            DebounceStep::Fire
        } else {
            DebounceStep::Wait(quiet - elapsed)
        }
    }
}

/// Collapses a burst of notifications into one report after a quiet period.
#[derive(Debug, Default)]
pub struct Debouncer {
    state: Mutex<DebounceState>,
    wake: Condvar,
}

impl Debouncer {
    /// Records a notification. Every call restarts the quiet period.
    pub fn notify(&self) {
        locked(&self.state).last_notified = Some(Instant::now());
        self.wake.notify_all();
    }

    /// Ends [`Self::run`] without reporting a pending notification.
    pub fn cancel(&self) {
        locked(&self.state).cancelled = true;
        self.wake.notify_all();
    }

    /// Calls `fire` once after `quiet` has passed with no new notification,
    /// until [`Self::cancel`]. A notification that arrives while `fire` runs
    /// is reported again, because the change it announces may not have been
    /// seen by `fire`.
    pub fn run(&self, quiet: Duration, fire: impl Fn()) {
        let mut state = locked(&self.state);
        loop {
            match state.step(Instant::now(), quiet) {
                DebounceStep::Stop => return,
                DebounceStep::Idle => {
                    state = self
                        .wake
                        .wait(state)
                        .unwrap_or_else(PoisonError::into_inner);
                }
                DebounceStep::Wait(remaining) => {
                    state = self
                        .wake
                        .wait_timeout(state, remaining)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
                DebounceStep::Fire => {
                    drop(state);
                    fire();
                    state = locked(&self.state);
                }
            }
        }
    }
}

/// The debouncers a HAL notification must wake.
struct SubscriberTable {
    entries: Mutex<Vec<(u64, Arc<Debouncer>)>>,
    next_id: AtomicU64,
}

impl SubscriberTable {
    const fn new() -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
        }
    }

    fn add(&self, debouncer: Arc<Debouncer>) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        locked(&self.entries).push((id, debouncer));
        id
    }

    fn remove(&self, id: u64) {
        locked(&self.entries).retain(|(entry, _)| *entry != id);
    }

    /// Runs on a HAL thread: wakes every debouncer without allocating.
    fn notify_all(&self) {
        for (_, debouncer) in locked(&self.entries).iter() {
            debouncer.notify();
        }
    }
}

static OUTPUT_SUBSCRIBERS: SubscriberTable = SubscriberTable::new();

/// Held while the listener is registered, and not while it runs, so that a
/// registration waiting on the HAL can never block a notification.
static LISTENER_REGISTERED: Mutex<bool> = Mutex::new(false);

unsafe extern "C-unwind" fn default_output_device_changed(
    _object: AudioObjectID,
    _address_count: u32,
    _addresses: NonNull<AudioObjectPropertyAddress>,
    _client_data: *mut c_void,
) -> i32 {
    OUTPUT_SUBSCRIBERS.notify_all();
    NO_ERR
}

/// Registers the process-wide HAL listener the first time it is called.
fn ensure_listener_registered() -> Result<(), AudioCaptureError> {
    let mut registered = locked(&LISTENER_REGISTERED);
    if *registered {
        return Ok(());
    }
    let address = AudioObjectPropertyAddress {
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    // SAFETY: `address` outlives the call, the callback is a plain function
    // that touches only statics, and the client data is unused (null).
    let status = unsafe {
        AudioObjectAddPropertyListener(
            AUDIO_OBJECT_SYSTEM_OBJECT,
            NonNull::from_ref(&address),
            Some(default_output_device_changed),
            ptr::null_mut(),
        )
    };
    if status != NO_ERR {
        return Err(AudioCaptureError::Platform(format!(
            "AudioObjectAddPropertyListener failed (OSStatus={status})"
        )));
    }
    *registered = true;
    Ok(())
}

/// Reports changes of the default output device, debounced, until dropped.
pub struct OutputDeviceWatcher {
    table: &'static SubscriberTable,
    id: u64,
    debouncer: Arc<Debouncer>,
    worker: Option<JoinHandle<()>>,
}

impl fmt::Debug for OutputDeviceWatcher {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OutputDeviceWatcher")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}

impl OutputDeviceWatcher {
    /// Starts reporting default-output-device changes to `on_change`.
    ///
    /// `on_change` runs on a watcher thread, not on a `CoreAudio` thread, once
    /// per burst of changes. It should only hand the work to its owner.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError::Platform`] when the `CoreAudio` listener or
    /// the watcher thread cannot be started.
    pub fn start(on_change: Arc<dyn Fn() + Send + Sync>) -> Result<Self, AudioCaptureError> {
        ensure_listener_registered()?;
        Self::subscribe(&OUTPUT_SUBSCRIBERS, OUTPUT_CHANGE_QUIET, on_change)
    }

    fn subscribe(
        table: &'static SubscriberTable,
        quiet: Duration,
        on_change: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<Self, AudioCaptureError> {
        let debouncer = Arc::new(Debouncer::default());
        let runner = Arc::clone(&debouncer);
        let worker = thread::Builder::new()
            .name("wallpaper-core-audio-output-watch".to_string())
            .spawn(move || runner.run(quiet, || on_change()))
            .map_err(|error| {
                AudioCaptureError::Platform(format!(
                    "could not start the output device watcher: {error}"
                ))
            })?;
        let id = table.add(Arc::clone(&debouncer));
        Ok(Self {
            table,
            id,
            debouncer,
            worker: Some(worker),
        })
    }
}

impl Drop for OutputDeviceWatcher {
    fn drop(&mut self) {
        self.table.remove(self.id);
        self.debouncer.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{atomic::AtomicUsize, mpsc};

    use super::*;

    /// Long enough that a busy machine does not fail a test that is waiting for
    /// something that must happen; it never delays a passing run.
    const PATIENCE: Duration = Duration::from_secs(10);
    const QUIET: Duration = Duration::from_millis(20);

    fn counting_fire() -> (
        Arc<AtomicUsize>,
        mpsc::Receiver<()>,
        impl Fn() + Send + 'static,
    ) {
        let count = Arc::new(AtomicUsize::new(0));
        let (sender, receiver) = mpsc::channel();
        let counter = Arc::clone(&count);
        let fire = move || {
            let _ = counter.fetch_add(1, Ordering::SeqCst);
            let _ = sender.send(());
        };
        (count, receiver, fire)
    }

    #[test]
    fn each_notification_pushes_the_report_out_by_the_quiet_period() {
        let base = Instant::now();
        let quiet = Duration::from_millis(20);
        let mut state = DebounceState::default();
        assert_eq!(state.step(base, quiet), DebounceStep::Idle);

        state.last_notified = Some(base);
        assert_eq!(
            state.step(base + Duration::from_millis(15), quiet),
            DebounceStep::Wait(Duration::from_millis(5))
        );
        // A second change at 15 ms restarts the wait instead of firing at 20 ms.
        state.last_notified = Some(base + Duration::from_millis(15));
        assert_eq!(
            state.step(base + Duration::from_millis(30), quiet),
            DebounceStep::Wait(Duration::from_millis(5))
        );
        assert_eq!(
            state.step(base + Duration::from_millis(35), quiet),
            DebounceStep::Fire
        );
        assert_eq!(
            state.step(base + Duration::from_millis(80), quiet),
            DebounceStep::Idle,
            "a reported change is not reported again"
        );

        state.last_notified = Some(base);
        state.cancelled = true;
        assert_eq!(
            state.step(base + Duration::from_secs(1), quiet),
            DebounceStep::Stop
        );
    }

    #[test]
    fn a_burst_of_changes_fires_once_after_the_quiet_period() {
        let debouncer = Arc::new(Debouncer::default());
        // The whole burst is recorded before the thread looks, so the count
        // does not depend on how the scheduler interleaves the two threads.
        for _ in 0..5 {
            debouncer.notify();
        }
        let (count, fired, fire) = counting_fire();
        let runner = Arc::clone(&debouncer);
        let worker = thread::spawn(move || runner.run(QUIET, fire));

        fired.recv_timeout(PATIENCE).expect("the burst is reported");
        debouncer.cancel();
        worker.join().unwrap();
        assert_eq!(
            count.load(Ordering::SeqCst),
            1,
            "five changes are one report"
        );
    }

    #[test]
    fn a_notification_wakes_an_idle_debouncer() {
        let debouncer = Arc::new(Debouncer::default());
        let (count, fired, fire) = counting_fire();
        let runner = Arc::clone(&debouncer);
        let worker = thread::spawn(move || runner.run(QUIET, fire));

        debouncer.notify();
        fired
            .recv_timeout(PATIENCE)
            .expect("the change is reported");
        debouncer.notify();
        fired
            .recv_timeout(PATIENCE)
            .expect("a later change is reported again");
        debouncer.cancel();
        worker.join().unwrap();
        assert_eq!(count.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn cancel_prevents_a_pending_fire() {
        let debouncer = Arc::new(Debouncer::default());
        let (count, _fired, fire) = counting_fire();
        let runner = Arc::clone(&debouncer);
        let quiet = Duration::from_secs(60);
        let worker = thread::spawn(move || runner.run(quiet, fire));

        debouncer.notify();
        let started = Instant::now();
        debouncer.cancel();
        worker.join().unwrap();
        assert!(
            started.elapsed() < quiet,
            "cancel must wake the thread instead of waiting out the quiet period"
        );
        assert_eq!(
            count.load(Ordering::SeqCst),
            0,
            "a cancelled change is dropped"
        );
    }

    #[test]
    fn a_change_reaches_every_subscriber_until_it_is_dropped() {
        let table: &'static SubscriberTable = Box::leak(Box::new(SubscriberTable::new()));
        let (first_count, first_fired, first_fire) = counting_fire();
        let (second_count, second_fired, second_fire) = counting_fire();
        let first = OutputDeviceWatcher::subscribe(table, QUIET, Arc::new(first_fire)).unwrap();
        let second = OutputDeviceWatcher::subscribe(table, QUIET, Arc::new(second_fire)).unwrap();

        // What the HAL callback does when the default output device changes.
        table.notify_all();
        first_fired
            .recv_timeout(PATIENCE)
            .expect("the first watcher is told");
        second_fired
            .recv_timeout(PATIENCE)
            .expect("the second watcher is told");

        drop(first);
        table.notify_all();
        second_fired
            .recv_timeout(PATIENCE)
            .expect("the remaining watcher is still told");
        drop(second);
        assert_eq!(
            first_count.load(Ordering::SeqCst),
            1,
            "a dropped watcher hears nothing more"
        );
        assert_eq!(second_count.load(Ordering::SeqCst), 2);
        assert!(
            locked(&table.entries).is_empty(),
            "dropping removes the subscription"
        );
    }
}
