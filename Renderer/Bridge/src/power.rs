use std::{
    ffi::c_void,
    fmt, ptr,
    sync::{
        Arc, Mutex, MutexGuard, PoisonError,
        atomic::{AtomicBool, Ordering},
    },
    thread,
};

use objc2_core_foundation::{
    CFRetained, CFRunLoop, CFRunLoopRunResult, CFRunLoopSource, CFRunLoopSourceContext,
    CFTimeInterval,
};
use objc2_io_kit::IOPSNotificationCreateRunLoopSource;

use crate::{
    actor::{BridgeActorHandle, messages::SetPowerSource},
    engine::EngineFacade,
};

/// How long one pass of the watcher's run loop may sleep: the value `CFRunLoopRun` itself uses
/// for "no timeout". A pass ends earlier when `IOKit` reports a change or the thread is woken
/// through [`WatcherSignal`], so nothing wakes the thread while the power source is unchanged.
const IDLE_WAIT: CFTimeInterval = 1.0e10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerSource {
    External,
    Battery,
    Unknown,
}

/// Follows plugging in and unplugging, and hands each change to the bridge actor.
///
/// The thread behind it sleeps in its run loop until `IOKit` reports a change or the watcher is
/// dropped; dropping wakes it, so shutdown never waits on a timeout.
#[derive(Debug)]
pub(crate) struct PowerWatcher {
    signal: Arc<WatcherSignal>,
    worker: Option<thread::JoinHandle<()>>,
}

impl PowerWatcher {
    /// Follows the source `read` reports and hands each change to `actor`.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn spawn<E: EngineFacade + Clone>(
        actor: BridgeActorHandle<E>,
        read: impl Fn() -> PowerSource + Send + 'static,
    ) -> Self {
        Self::spawn_with(read, move |source| {
            match actor.blocking_ask(SetPowerSource {
                source,
                initial_sample: false,
            }) {
                Ok(_) => true,
                Err(error) => {
                    log::debug!("power source update skipped: {error}");
                    false
                }
            }
        })
    }

    /// Asks the thread to read the power source again and hand it over if it differs from what
    /// the consumer last took. Cheap, never waits for the read, and safe at any time: a request
    /// made while one is waiting to run is the same request, and one made after the thread
    /// stopped does nothing.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn resample(&self) {
        self.signal.request_resample();
    }

    /// Starts the watcher thread. `read` samples the power source; `deliver` hands a changed
    /// source to its consumer and reports whether the consumer took it. The source sampled here
    /// counts as already delivered.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn spawn_with(
        read: impl Fn() -> PowerSource + Send + 'static,
        deliver: impl FnMut(PowerSource) -> bool + Send + 'static,
    ) -> Self {
        let delivered = read();
        let signal = Arc::new(WatcherSignal::default());
        let event_loop = PowerEventLoop {
            context: Box::new(PowerNotificationContext {
                read: Box::new(read),
                deliver: Box::new(deliver),
                delivered,
            }),
            signal: Arc::clone(&signal),
        };
        let worker = thread::Builder::new()
            .name("wallpaper-bridge-power-watcher".to_string())
            .spawn(move || event_loop.run())
            .ok();

        Self { signal, worker }
    }
}

impl Drop for PowerWatcher {
    fn drop(&mut self) {
        self.signal.stop.store(true, Ordering::SeqCst);
        self.signal.notify();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// What the owner of a [`PowerWatcher`] uses to reach its thread while that thread sleeps.
#[derive(Debug, Default)]
struct WatcherSignal {
    stop: AtomicBool,
    /// Set by [`PowerWatcher::resample`], cleared by the thread as it starts reading.
    resample: AtomicBool,
    /// Present from the moment the thread's run loop is ready to be woken until it stops.
    wake: Mutex<Option<RunLoopWake>>,
}

impl WatcherSignal {
    fn should_stop(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    fn request_resample(&self) {
        self.resample.store(true, Ordering::SeqCst);
        self.notify();
    }

    /// Whether a resample was requested since the last call; asking clears the request, so a
    /// request that arrives while the thread reads is kept for the next pass.
    fn take_resample_request(&self) -> bool {
        self.resample.swap(false, Ordering::SeqCst)
    }

    fn publish(&self, wake: RunLoopWake) {
        *self.wake() = Some(wake);
    }

    fn unpublish(&self) {
        *self.wake() = None;
    }

    /// Ends the thread's current wait. A signal sent while the loop is not running stays
    /// pending, so it is seen on the loop's next pass; one sent before the handle is published
    /// finds nothing to wake, and the thread reads the stop flag only after publishing.
    fn notify(&self) {
        if let Some(wake) = self.wake().as_ref() {
            wake.source.signal();
            wake.run_loop.wake_up();
        }
    }

    fn wake(&self) -> MutexGuard<'_, Option<RunLoopWake>> {
        self.wake.lock().unwrap_or_else(PoisonError::into_inner)
    }

    #[cfg(test)]
    fn is_asleep(&self) -> bool {
        self.wake()
            .as_ref()
            .is_some_and(|wake| wake.run_loop.is_waiting())
    }
}

/// A run loop and the source that wakes it.
struct RunLoopWake {
    run_loop: CFRetained<CFRunLoop>,
    source: CFRetained<CFRunLoopSource>,
}

// SAFETY: `CFRunLoopSourceSignal` and `CFRunLoopWakeUp` are the calls Apple documents for waking
// a run loop from another thread, and a retained `CFRunLoop` or `CFRunLoopSource` may be
// released on any thread. `objc2-core-foundation` marks these types `!Send` and `!Sync`
// conservatively. `RunLoopWake` offers nothing else, and its fields are only reached through
// `WatcherSignal`, which serialises them behind a mutex.
unsafe impl Send for RunLoopWake {}

impl fmt::Debug for RunLoopWake {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RunLoopWake")
            .finish_non_exhaustive()
    }
}

#[allow(clippy::single_call_fn)]
extern "C-unwind" fn wake_source_perform(_info: *mut c_void) {}

/// A source that does nothing when it runs. Signalling it is only how the thread is woken.
#[allow(clippy::single_call_fn)]
fn create_wake_source() -> Option<CFRetained<CFRunLoopSource>> {
    let mut context = CFRunLoopSourceContext {
        version: 0,
        info: ptr::null_mut(),
        retain: None,
        release: None,
        copyDescription: None,
        equal: None,
        hash: None,
        schedule: None,
        cancel: None,
        perform: Some(wake_source_perform),
    };
    // SAFETY: `context` is a fully initialised version-0 context that outlives the call, and
    // `CFRunLoopSourceCreate` copies it, so no pointer to it is kept. A null allocator selects
    // the default allocator. `info` is null and `wake_source_perform` never reads it.
    unsafe { CFRunLoopSource::new(None, 0, ptr::from_mut(&mut context)) }
}

#[derive(Debug)]
pub(crate) struct SystemPowerSource;

impl From<&objc2_core_foundation::CFString> for PowerSource {
    fn from(source: &objc2_core_foundation::CFString) -> Self {
        let length = source.length();
        let (label, category): (&[u8], Self) = match length {
            n if n == b"AC Power".len() as objc2_core_foundation::CFIndex => {
                (b"AC Power", Self::External)
            }
            n if n == b"Battery Power".len() as objc2_core_foundation::CFIndex => {
                (b"Battery Power", Self::Battery)
            }
            n if n == b"UPS Power".len() as objc2_core_foundation::CFIndex => {
                (b"UPS Power", Self::Battery)
            }
            _ => return Self::Unknown,
        };

        // Every recognized label is ASCII, so each byte is one UTF-16 code unit.
        for (index, expected) in label.iter().copied().enumerate() {
            // SAFETY: The length match proves index < source.length(), and these
            // short label indices fit CFIndex. The shared source borrow remains
            // valid and unmodified throughout the checked accesses.
            let actual = unsafe {
                source.character_at_index(index as objc2_core_foundation::CFIndex)
            };
            if actual != u16::from(expected) {
                return Self::Unknown;
            }
        }

        category
    }
}

impl SystemPowerSource {
    pub(crate) fn current() -> PowerSource {
        let Some(snapshot) = objc2_io_kit::IOPSCopyPowerSourcesInfo() else {
            return PowerSource::Unknown;
        };

        // SAFETY: This is the live opaque snapshot returned by the Copy operation.
        // Its owner remains in scope throughout access and classification.
        let Some(source) = (unsafe {
            objc2_io_kit::IOPSGetProvidingPowerSourceType(Some(&*snapshot))
        }) else {
            return PowerSource::Unknown;
        };

        PowerSource::from(&*source)
    }
}

struct PowerEventLoop {
    context: Box<PowerNotificationContext>,
    signal: Arc<WatcherSignal>,
}

impl PowerEventLoop {
    fn run(mut self) {
        let Some(run_loop) = objc2_core_foundation::CFRunLoop::current() else {
            log::debug!("Power watcher startup ended: the current run loop is unavailable");
            return;
        };
        // SAFETY: This immutable foreign constant is borrowed for the process lifetime.
        let Some(mode) = (unsafe { objc2_core_foundation::kCFRunLoopDefaultMode }) else {
            log::debug!("Power watcher startup ended: the default run-loop mode is unavailable");
            return;
        };
        let Some(wake_source) = create_wake_source() else {
            log::debug!("power source watcher skipped: wake source unavailable");
            return;
        };
        // One pointer serves both users of the context, the IOKit callback and the resample pass
        // below. Taking a second one from `self.context` would invalidate this one.
        let context = ptr::from_mut(&mut *self.context);
        let Some(power_source) = PowerNotificationContext::create_run_loop_source(context) else {
            log::debug!("Power watcher startup ended: the power notification source is unavailable");
            return;
        };

        run_loop.add_source(Some(&power_source), Some(mode));
        run_loop.add_source(Some(&wake_source), Some(mode));
        // Publish before reading the stop flag: a stop requested earlier is seen here, and one
        // requested later finds the handle and leaves a signal pending for the loop.
        self.signal.publish(RunLoopWake {
            run_loop: run_loop.clone(),
            source: wake_source.clone(),
        });
        while !self.signal.should_stop() {
            if self.signal.take_resample_request() {
                // SAFETY: `context` points into the box `self.context` owns, which is neither
                // moved nor dropped before `run` returns. Only this thread uses it, and the
                // IOKit callback that shares it runs inside `run_in_mode` below, never while
                // this call is in progress.
                if let Some(context) = unsafe { context.as_mut() } {
                    context.reconcile(SampleOrigin::Resample);
                }
            }
            let outcome = CFRunLoop::run_in_mode(Some(mode), IDLE_WAIT, true);
            if outcome == CFRunLoopRunResult::Finished {
                // Nothing is left to wait for; looping again would spin.
                log::debug!("power source watcher stopped: run loop has no sources");
                break;
            }
        }
        // From here a late `notify` has nothing to wake.
        self.signal.unpublish();
        run_loop.remove_source(Some(&power_source), Some(mode));
        run_loop.remove_source(Some(&wake_source), Some(mode));
        power_source.invalidate();
        wake_source.invalidate();
        log::debug!("power source watcher stopped");
    }
}

/// What prompted a reading of the power source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SampleOrigin {
    /// `IOKit` reported a change.
    Notification,
    /// The owner asked for a fresh reading, for instance because the Mac woke from sleep and a
    /// change during sleep may not have been reported.
    Resample,
}

struct PowerNotificationContext {
    read: Box<dyn Fn() -> PowerSource + Send>,
    deliver: Box<dyn FnMut(PowerSource) -> bool + Send>,
    /// The last source the consumer took. It moves only once `deliver` says it was taken, so a
    /// source the consumer turned down is offered again the next time.
    delivered: PowerSource,
}

impl PowerNotificationContext {
    /// Creates the run-loop source that calls [`handle_power_change`] with `context`.
    ///
    /// `context` must point to the boxed context owned by `PowerEventLoop::run`, which has to
    /// keep it alive and in place until the returned source is removed and invalidated.
    #[allow(clippy::single_call_fn)]
    fn create_run_loop_source(context: *mut Self) -> Option<CFRetained<CFRunLoopSource>> {
        // SAFETY: The caller keeps `context` pointing to the live boxed
        // `PowerNotificationContext` while the source exists. The callback casts it back to the
        // same type.
        unsafe {
            IOPSNotificationCreateRunLoopSource(Some(handle_power_change), context.cast::<c_void>())
        }
    }

    fn reconcile(&mut self, origin: SampleOrigin) {
        let next = (self.read)();
        if next == self.delivered {
            return;
        }
        // A reading that failed says nothing about the source, and the consumer must not lose
        // what it knows because the system was slow to answer after waking.
        if origin == SampleOrigin::Resample && next == PowerSource::Unknown {
            log::debug!("power source resample skipped: the source could not be read");
            return;
        }
        let previous = self.delivered;
        if (self.deliver)(next) {
            self.delivered = next;
            if origin == SampleOrigin::Resample {
                log::info!("power source corrected after wake: {previous:?} -> {next:?}");
            }
        }
    }
}

/// Dispatches a native power notification through the retained host reconciler.
///
/// # Safety
/// A non-null context must point to a correctly aligned, initialized, live
/// `PowerNotificationContext` in stable storage. The caller must provide exclusive
/// mutable access for this dispatch and prevent conflicting or reentrant access.
/// The registration owner must keep that storage alive throughout registration
/// and all in-flight callbacks, preventing further dispatch and completing active
/// dispatch before destroying it. This callback borrows, but never owns, the
/// context. Its ABI alone does not establish that unwinding through native frames
/// is safe.
pub unsafe extern "C-unwind" fn handle_power_change(context: *mut core::ffi::c_void) {
    if context.is_null() {
        return;
    }

    // SAFETY: The caller supplies the type, alignment, initialization, lifetime,
    // and exclusive-access guarantees documented above; non-null alone is not
    // evidence that an arbitrary pointer is valid.
    let context = unsafe { &mut *context.cast::<PowerNotificationContext>() };
    context.reconcile(SampleOrigin::Notification);
}

#[cfg(test)]
#[path = "power/classifier_contract.rs"]
mod classifier_contract;

#[cfg(test)]
mod tests {
    use std::{
        ffi::c_void,
        ptr,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        thread,
        time::{Duration, Instant},
    };

    use objc2_core_foundation::{CFRunLoop, CFRunLoopRunResult, kCFRunLoopDefaultMode};

    use super::{
        PowerNotificationContext, PowerSource, PowerWatcher, RunLoopWake, SampleOrigin,
        WatcherSignal, create_wake_source, handle_power_change,
    };

    /// How long a watcher that has nothing left to wait for may take to finish. The loop used to
    /// wake every five seconds to check a flag, so a shutdown that waits on a timeout misses it.
    const PROMPT: Duration = Duration::from_secs(1);

    /// Only a bound for the failing case: a delivery that never comes fails the test after this
    /// long, and one that does come is seen as soon as it is made.
    const GIVE_UP: Duration = Duration::from_secs(10);


    #[test]
    fn dropping_the_watcher_does_not_wait_for_a_timeout() {
        let watcher = PowerWatcher::spawn_with(|| PowerSource::External, |_| true);
        wait_until_asleep(&watcher);

        let started = Instant::now();
        drop(watcher);

        assert!(
            started.elapsed() < PROMPT,
            "a sleeping watcher took {:?} to stop",
            started.elapsed()
        );
    }

    #[test]
    fn dropping_right_after_spawn_always_returns_promptly() {
        for round in 0..50 {
            let watcher = PowerWatcher::spawn_with(|| PowerSource::External, |_| true);
            assert!(
                drops_within(watcher, PROMPT),
                "watcher {round} was still running a second after it was dropped"
            );
        }
    }

    #[test]
    fn a_wake_signalled_before_the_loop_runs_ends_its_next_wait() {
        let run_loop = CFRunLoop::current().expect("test thread has a run loop");
        // SAFETY: CoreFoundation exposes this immutable process-wide constant.
        let mode = unsafe { kCFRunLoopDefaultMode }.expect("default run loop mode");
        let source = create_wake_source().expect("wake source");
        run_loop.add_source(Some(&source), Some(mode));
        let signal = WatcherSignal::default();
        signal.publish(RunLoopWake {
            run_loop: run_loop.clone(),
            source: source.clone(),
        });

        signal.notify();
        // Only a bound for the failing case: a lost signal would sleep out all of it.
        let outcome = CFRunLoop::run_in_mode(Some(mode), 10.0, true);

        run_loop.remove_source(Some(&source), Some(mode));
        source.invalidate();
        assert_eq!(outcome, CFRunLoopRunResult::HandledSource);
    }

    #[test]
    fn a_changed_power_source_is_delivered_once() {
        let source = Arc::new(Mutex::new(PowerSource::External));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let mut context = fake_context(&source, &delivered, 0);

        deliver_callback(&mut context);
        assert!(delivered.lock().unwrap().is_empty());

        *source.lock().unwrap() = PowerSource::Battery;
        deliver_callback(&mut context);
        deliver_callback(&mut context);

        assert_eq!(*delivered.lock().unwrap(), [PowerSource::Battery]);
    }

    #[test]
    fn a_delivery_the_actor_rejected_is_retried() {
        let source = Arc::new(Mutex::new(PowerSource::External));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let mut context = fake_context(&source, &delivered, 1);

        *source.lock().unwrap() = PowerSource::Battery;
        deliver_callback(&mut context);
        deliver_callback(&mut context);
        deliver_callback(&mut context);

        // Offered again after the rejection, then left alone once taken.
        assert_eq!(
            *delivered.lock().unwrap(),
            [PowerSource::Battery, PowerSource::Battery]
        );
    }

    #[test]
    fn a_resample_delivers_a_source_that_changed_without_a_report() {
        let mut probe = Probe::start(PowerSource::External, 0);

        probe.set(PowerSource::Battery);
        probe.resample_and_wait_for_the_read();
        assert_eq!(probe.next_attempt(), PowerSource::Battery);

        // Asking again with nothing changed delivers nothing, so the next attempt is the change
        // that follows and not a repeat of the one already taken.
        probe.resample_and_wait_for_the_read();
        probe.set(PowerSource::External);
        probe.resample_and_wait_for_the_read();
        assert_eq!(probe.next_attempt(), PowerSource::External);
        assert_eq!(probe.finish(), []);
    }

    #[test]
    fn a_resample_offers_again_what_the_actor_turned_down() {
        let mut probe = Probe::start(PowerSource::External, 1);

        probe.set(PowerSource::Battery);
        probe.resample_and_wait_for_the_read();
        assert_eq!(probe.next_attempt(), PowerSource::Battery);

        probe.resample_and_wait_for_the_read();
        assert_eq!(probe.next_attempt(), PowerSource::Battery);

        // Taken this time, so it is not offered a third time.
        probe.resample_and_wait_for_the_read();
        probe.set(PowerSource::External);
        probe.resample_and_wait_for_the_read();
        assert_eq!(probe.next_attempt(), PowerSource::External);
        assert_eq!(probe.finish(), []);
    }

    #[test]
    fn a_resample_that_could_not_read_the_source_leaves_the_consumer_alone() {
        let mut probe = Probe::start(PowerSource::External, 0);

        probe.set(PowerSource::Unknown);
        probe.resample_and_wait_for_the_read();
        probe.set(PowerSource::Battery);
        probe.resample_and_wait_for_the_read();

        // The unreadable moment was not handed over, so the consumer still believes external
        // power until a real answer arrives.
        assert_eq!(probe.next_attempt(), PowerSource::Battery);
        assert_eq!(probe.finish(), []);
    }

    #[test]
    fn a_change_reported_by_iokit_is_still_delivered_even_when_unreadable() {
        let source = Arc::new(Mutex::new(PowerSource::External));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let mut context = fake_context(&source, &delivered, 0);

        *source.lock().unwrap() = PowerSource::Unknown;
        context.reconcile(SampleOrigin::Resample);
        assert!(delivered.lock().unwrap().is_empty());
        context.reconcile(SampleOrigin::Notification);

        assert_eq!(*delivered.lock().unwrap(), [PowerSource::Unknown]);
    }

    #[test]
    fn a_resample_asked_for_as_the_watcher_stops_does_not_delay_it() {
        for round in 0..20 {
            let watcher = PowerWatcher::spawn_with(|| PowerSource::External, |_| true);
            watcher.resample();
            assert!(
                drops_within(watcher, PROMPT),
                "watcher {round} was still running a second after it was dropped"
            );
        }
    }

    #[test]
    fn a_resample_asked_for_after_the_watcher_stopped_does_nothing() {
        let mut probe = Probe::start(PowerSource::External, 0);
        let signal = Arc::clone(&probe.watcher.as_ref().expect("watcher").signal);
        probe.set(PowerSource::Battery);
        drop(probe.watcher.take());

        signal.request_resample();

        assert_eq!(probe.finish(), []);
    }

    /// A context reading `source`, recording what it delivers, and turning down the first
    /// `rejections` deliveries. It starts out having delivered external power.
    fn fake_context(
        source: &Arc<Mutex<PowerSource>>,
        delivered: &Arc<Mutex<Vec<PowerSource>>>,
        rejections: usize,
    ) -> PowerNotificationContext {
        let source = Arc::clone(source);
        let delivered = Arc::clone(delivered);
        let mut rejections_left = rejections;
        PowerNotificationContext {
            read: Box::new(move || *source.lock().unwrap()),
            deliver: Box::new(move |next| {
                delivered.lock().unwrap().push(next);
                if rejections_left > 0 {
                    rejections_left -= 1;
                    return false;
                }
                true
            }),
            delivered: PowerSource::External,
        }
    }

    fn deliver_callback(context: &mut PowerNotificationContext) {
        // SAFETY: `context` is a live `PowerNotificationContext`, which is what the callback
        // casts its pointer back to.
        unsafe { handle_power_change(ptr::from_mut(context).cast::<c_void>()) };
    }

    /// A running watcher over a power source the test controls. Every delivery the watcher
    /// makes is recorded in order, whether or not the fake consumer took it.
    struct Probe {
        watcher: Option<PowerWatcher>,
        source: Arc<Mutex<PowerSource>>,
        reads: Arc<AtomicUsize>,
        attempts: mpsc::Receiver<PowerSource>,
    }

    impl Probe {
        /// Starts a watcher whose consumer turns down its first `rejections` deliveries.
        fn start(initial: PowerSource, rejections: usize) -> Self {
            let source = Arc::new(Mutex::new(initial));
            let reads = Arc::new(AtomicUsize::new(0));
            let (attempted, attempts) = mpsc::channel();
            let mut rejections_left = rejections;
            let watcher = PowerWatcher::spawn_with(
                {
                    let source = Arc::clone(&source);
                    let reads = Arc::clone(&reads);
                    move || {
                        let _ = reads.fetch_add(1, Ordering::SeqCst);
                        *source.lock().unwrap()
                    }
                },
                move |next| {
                    attempted.send(next).expect("probe outlives the watcher");
                    if rejections_left > 0 {
                        rejections_left -= 1;
                        return false;
                    }
                    true
                },
            );
            Self {
                watcher: Some(watcher),
                source,
                reads,
                attempts,
            }
        }

        fn set(&self, next: PowerSource) {
            *self.source.lock().unwrap() = next;
        }

        /// Asks for a resample and waits until the watcher has read the source for it, so what
        /// the test changes next cannot be mistaken for what this request saw.
        fn resample_and_wait_for_the_read(&self) {
            let before = self.reads.load(Ordering::SeqCst);
            self.watcher.as_ref().expect("watcher").resample();
            let give_up = Instant::now() + GIVE_UP;
            while self.reads.load(Ordering::SeqCst) == before {
                assert!(
                    Instant::now() < give_up,
                    "the watcher never read the source"
                );
                thread::sleep(Duration::from_millis(1));
            }
        }

        fn next_attempt(&self) -> PowerSource {
            self.attempts
                .recv_timeout(GIVE_UP)
                .expect("the watcher made no delivery")
        }

        /// Stops the watcher and returns the deliveries nobody collected.
        fn finish(&mut self) -> Vec<PowerSource> {
            drop(self.watcher.take());
            self.attempts.try_iter().collect()
        }
    }

    /// Waits until the watcher's thread is asleep in its run loop. This is the state the old
    /// five-second loop could be caught in, so the check that follows is about waking it.
    #[allow(clippy::single_call_fn)]
    fn wait_until_asleep(watcher: &PowerWatcher) {
        let give_up = Instant::now() + Duration::from_secs(30);
        while !watcher.signal.is_asleep() {
            assert!(
                Instant::now() < give_up,
                "the watcher thread never went to sleep in its run loop"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    /// Drops `watcher` on another thread so a watcher that never stops fails the test instead
    /// of hanging it.
    #[allow(clippy::single_call_fn)]
    fn drops_within(watcher: PowerWatcher, limit: Duration) -> bool {
        let (done, finished) = mpsc::channel();
        let _ = thread::spawn(move || {
            drop(watcher);
            let _ = done.send(());
        });
        finished.recv_timeout(limit).is_ok()
    }

}
