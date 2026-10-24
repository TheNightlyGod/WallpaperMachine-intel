use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use wallpaper_core::FirstFrameCallback;
use wallpaper_core::project::SceneHandle;

use crate::api::BridgeError;

#[derive(Debug)]
pub(crate) enum FirstFrameDelivery {
    Delivered,
    TargetGone,
    Failed(BridgeError),
}

#[cfg(test)]
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ObservedFirstFrameDelivery {
    Delivered,
    TargetGone,
    Failed(crate::api::BridgeErrorKind),
}

pub(crate) trait FirstFrameTarget: Send + Sync + 'static {
    fn deliver(&self, handle: SceneHandle) -> impl Future<Output = FirstFrameDelivery> + Send + '_;
}

const OPEN: u8 = 0;
const INVOKING: u8 = 1;
const CLOSED: u8 = 2;

struct Intake {
    sender: mpsc::UnboundedSender<SceneHandle>,
    state: AtomicU8,
    #[cfg(test)]
    observation: std::sync::Mutex<Option<Arc<tests::DispatchObservation>>>,
    #[cfg(test)]
    completed: std::sync::OnceLock<mpsc::UnboundedSender<(SceneHandle, ObservedFirstFrameDelivery)>>,
}

impl Intake {
    fn new() -> (Arc<Self>, mpsc::UnboundedReceiver<SceneHandle>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (
            Arc::new(Self {
                sender,
                state: AtomicU8::new(OPEN),
                #[cfg(test)]
                observation: std::sync::Mutex::new(None),
                #[cfg(test)]
                completed: std::sync::OnceLock::new(),
            }),
            receiver,
        )
    }

    fn callback(this: &Arc<Self>) -> FirstFrameCallback {
        let weak = Arc::downgrade(this);
        Arc::new(move |handle| {
            if let Some(intake) = weak.upgrade() {
                if intake.state.load(Ordering::Acquire) & CLOSED == 0 {
                    // Unbounded MPSC admission never waits for the consumer, an
                    // actor, a reply, or capacity. A send racing closure may be
                    // queued, but cannot reserve a post-close invocation.
                    let _ = intake.sender.send(handle);
                }
            }
        })
    }

    fn close(&self) {
        let _previous = self.state.fetch_or(CLOSED, Ordering::AcqRel);
        #[cfg(test)]
        if let Some(observation) = self.observation() {
            observation.record(tests::DispatchEvent::Closed(_previous));
        }
    }

    #[cfg(test)]
    fn observation(&self) -> Option<Arc<tests::DispatchObservation>> {
        self.observation.lock().unwrap().clone()
    }

    #[cfg(test)]
    fn record_completed(&self, handle: SceneHandle, outcome: ObservedFirstFrameDelivery) {
        if let Some(sender) = self.completed.get() {
            let _ = sender.send((handle, outcome));
        }
    }
}

// Constructed before spawning, so even cancellation of a never-polled task
// closes intake. Also runs on dispatcher panic and runtime cancellation.
struct DispatcherLifetime(Arc<Intake>);

impl Drop for DispatcherLifetime {
    fn drop(&mut self) {
        self.0.close();
    }
}

async fn dispatch<T: FirstFrameTarget>(
    lifetime: DispatcherLifetime,
    mut receiver: mpsc::UnboundedReceiver<SceneHandle>,
    target: T,
) {
    while let Some(handle) = receiver.recv().await {
        // The successful reservation is the invocation's linearization point.
        // Close's fetch_or totally orders with it: close may cancel a reserved
        // invocation, but a reservation cannot succeed once close has won.
        // No synchronization guard is held while calling/polling target code;
        // reentrant callbacks and nonwaiting close therefore remain possible.
        #[cfg(test)]
        let observation = lifetime.0.observation();
        #[cfg(test)]
        if let Some(observation) = &observation {
            observation.before_reservation(handle).await;
        }
        let reservation =
            lifetime
                .0
                .state
                .compare_exchange(OPEN, INVOKING, Ordering::AcqRel, Ordering::Acquire);
        #[cfg(test)]
        if let Some(observation) = &observation {
            observation.after_reservation(handle, reservation).await;
        }
        if reservation.is_err() {
            break;
        }
        // Avoid constructing an already-canceled request when close won just
        // after reservation. This is not a promise to retract an actor message.
        if lifetime.0.state.load(Ordering::Acquire) & CLOSED != 0 {
            break;
        }
        match target.deliver(handle).await {
            FirstFrameDelivery::Delivered => {
                #[cfg(test)]
                lifetime.0.record_completed(handle, ObservedFirstFrameDelivery::Delivered);
            }
            FirstFrameDelivery::TargetGone => {
                log::debug!(
                    "First-frame notification skipped for {:?}: target gone",
                    handle
                );
                #[cfg(test)]
                if let Some(observation) = &observation {
                    observation.diagnostic(handle, tests::DiagnosticOutcome::TargetGone);
                }
                #[cfg(test)]
                lifetime.0.record_completed(handle, ObservedFirstFrameDelivery::TargetGone);
            }
            FirstFrameDelivery::Failed(error) => {
                log::warn!(
                    "First-frame notification failed for {:?}: {}",
                    handle,
                    error
                );
                #[cfg(test)]
                if let Some(observation) = &observation {
                    observation.diagnostic(
                        handle,
                        tests::DiagnosticOutcome::Failed {
                            kind: error.kind(),
                            message: error.message().to_owned(),
                        },
                    );
                }
                #[cfg(test)]
                lifetime.0.record_completed(handle, ObservedFirstFrameDelivery::Failed(error.kind()));
            }
        }
        if lifetime.0.state.fetch_and(!INVOKING, Ordering::AcqRel) & CLOSED != 0 {
            break;
        }
    }
    // Receiver destruction discards queued receipts, not already-enqueued
    // actor messages. Target destruction releases the supplied weak capability.
}

/// One bridge's owned, event-driven first-frame dispatcher. The callback is
/// weak and has neither registration authority nor a runtime/actor reference.
pub(crate) struct FirstFrameHandoff {
    intake: Arc<Intake>,
    task: Option<JoinHandle<()>>,
}

impl FirstFrameHandoff {
    pub(crate) fn start<T: FirstFrameTarget>(runtime: &tokio::runtime::Handle, target: T) -> Self {
        let (intake, receiver) = Intake::new();
        let lifetime = DispatcherLifetime(Arc::clone(&intake));
        let task = runtime.spawn(dispatch(lifetime, receiver, target));
        Self {
            intake,
            task: Some(task),
        }
    }

    pub(crate) fn callback(&self) -> FirstFrameCallback {
        Intake::callback(&self.intake)
    }

    #[cfg(test)]
    pub(crate) fn observe_deliveries_for_test(
        &self,
    ) -> mpsc::UnboundedReceiver<(SceneHandle, ObservedFirstFrameDelivery)> {
        let (sender, receiver) = mpsc::unbounded_channel();
        // The observer is supplied at runtime, once; delivery needs no observer lock.
        assert!(self.intake.completed.set(sender).is_ok(), "one completion observer per owned handoff");
        receiver
    }

    pub(crate) fn close(&self) {
        self.intake.close();
        if let Some(task) = &self.task {
            task.abort();
        }
    }

    async fn close_and_join(&mut self) {
        self.close();
        if let Some(task) = self.task.take() {
            match task.await {
                Ok(()) => {}
                Err(error) if error.is_cancelled() => {}
                Err(error) => std::panic::resume_unwind(error.into_panic()),
            }
        }
    }

    pub(crate) async fn stop(mut self) {
        self.close_and_join().await;
    }

    #[cfg(test)]
    pub(crate) async fn stop_for_test(&mut self) {
        self.close_and_join().await;
    }
}

impl Drop for FirstFrameHandoff {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, AtomicUsize};
    use std::sync::{Barrier, Mutex, Weak};
    use std::task::{Context, Poll, Wake, Waker};
    use std::thread::{self, ThreadId};
    use std::time::Duration;
    use tokio::runtime::{Builder, Runtime};
    use tokio::sync::Semaphore;

    const GUARD: Duration = Duration::from_secs(10);
    thread_local! { static IN_CALLBACK: Cell<bool> = const { Cell::new(false) }; }

    fn runtime() -> Runtime {
        Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap()
    }

    async fn bounded<F: Future>(future: F) -> F::Output {
        tokio::time::timeout(GUARD, future)
            .await
            .expect("test synchronization timed out")
    }

    fn invoke(callback: &FirstFrameCallback, raw: u64) {
        IN_CALLBACK.with(|flag| {
            assert!(!flag.replace(true));
            struct Reset<'a>(&'a Cell<bool>);
            impl Drop for Reset<'_> {
                fn drop(&mut self) {
                    self.0.set(false);
                }
            }
            let _reset = Reset(flag);
            callback(SceneHandle::new(raw));
        });
    }

    #[derive(Debug, PartialEq, Eq)]
    pub(super) enum DiagnosticOutcome {
        TargetGone,
        Failed {
            kind: crate::api::BridgeErrorKind,
            message: String,
        },
    }

    #[derive(Debug, PartialEq, Eq)]
    pub(super) enum DispatchEvent {
        BeforeReservation(u64),
        Reservation(u64, Result<u8, u8>),
        Closed(u8),
        Diagnostic(u64, DiagnosticOutcome, ThreadId, bool),
    }

    // Entirely instance-local and cfg(test): no global logger, static hook,
    // production field/allocation, or production synchronization policy.
    pub(super) struct DispatchObservation {
        events: mpsc::UnboundedSender<DispatchEvent>,
        before: Option<Arc<Semaphore>>,
        after: Option<Arc<Semaphore>>,
    }

    impl DispatchObservation {
        pub(super) fn record(&self, event: DispatchEvent) {
            let _ = self.events.send(event);
        }

        pub(super) async fn before_reservation(&self, handle: SceneHandle) {
            self.record(DispatchEvent::BeforeReservation(handle.raw()));
            if let Some(gate) = &self.before {
                gate.acquire().await.unwrap().forget();
            }
        }

        pub(super) async fn after_reservation(&self, handle: SceneHandle, result: Result<u8, u8>) {
            self.record(DispatchEvent::Reservation(handle.raw(), result));
            if let Some(gate) = &self.after {
                gate.acquire().await.unwrap().forget();
            }
        }

        pub(super) fn diagnostic(&self, handle: SceneHandle, outcome: DiagnosticOutcome) {
            self.record(DispatchEvent::Diagnostic(
                handle.raw(),
                outcome,
                thread::current().id(),
                IN_CALLBACK.with(Cell::get),
            ));
        }
    }

    fn observe(
        owner: &FirstFrameHandoff,
        before: Option<Arc<Semaphore>>,
        after: Option<Arc<Semaphore>>,
    ) -> mpsc::UnboundedReceiver<DispatchEvent> {
        let (events, receiver) = mpsc::unbounded_channel();
        *owner.intake.observation.lock().unwrap() = Some(Arc::new(DispatchObservation {
            events,
            before,
            after,
        }));
        receiver
    }

    async fn dispatch_event(
        receiver: &mut mpsc::UnboundedReceiver<DispatchEvent>,
    ) -> DispatchEvent {
        bounded(receiver.recv())
            .await
            .expect("dispatch observation stream closed")
    }

    async fn diagnostic(
        receiver: &mut mpsc::UnboundedReceiver<DispatchEvent>,
    ) -> (u64, DiagnosticOutcome, ThreadId) {
        loop {
            if let DispatchEvent::Diagnostic(raw, outcome, thread, inline) =
                dispatch_event(receiver).await
            {
                assert!(!inline, "dispatcher diagnostic ran on the callback path");
                return (raw, outcome, thread);
            }
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Observed {
        Delivered,
        Gone,
        Failed(crate::api::BridgeErrorKind, String),
    }

    #[derive(Debug)]
    enum Event {
        Started(u64, ThreadId, bool),
        Polled(u64, ThreadId, bool),
        PendingGate(u64, ThreadId, bool),
        Completed(u64, Observed),
        FutureDropped(u64, bool),
        TargetDropped,
    }

    struct Control {
        started: AtomicUsize,
        active: AtomicUsize,
        peak: AtomicUsize,
        gate: Semaphore,
        gated: bool,
        outcomes: Mutex<VecDeque<FirstFrameDelivery>>,
        reenter: Mutex<Option<(FirstFrameCallback, u64)>>,
        panic: AtomicBool,
        events: mpsc::UnboundedSender<Event>,
    }

    struct Target {
        control: Arc<Control>,
        lifetime: Option<Arc<()>>,
        actor_surrogate: Weak<()>,
    }

    impl Drop for Target {
        fn drop(&mut self) {
            // Emit destruction evidence only after releasing the sentinel.
            drop(self.lifetime.take());
            let _ = self.control.events.send(Event::TargetDropped);
        }
    }

    struct InFlight {
        control: Arc<Control>,
        raw: u64,
        completed: bool,
    }

    impl Drop for InFlight {
        fn drop(&mut self) {
            self.control.active.fetch_sub(1, Ordering::SeqCst);
            let _ = self
                .control
                .events
                .send(Event::FutureDropped(self.raw, self.completed));
        }
    }

    impl FirstFrameTarget for Target {
        fn deliver(
            &self,
            handle: SceneHandle,
        ) -> impl Future<Output = FirstFrameDelivery> + Send + '_ {
            let raw = handle.raw();
            self.control.started.fetch_add(1, Ordering::SeqCst);
            let _ = self.control.events.send(Event::Started(
                raw,
                thread::current().id(),
                IN_CALLBACK.with(Cell::get),
            ));
            async move {
                let active = self.control.active.fetch_add(1, Ordering::SeqCst) + 1;
                self.control.peak.fetch_max(active, Ordering::SeqCst);
                let mut in_flight = InFlight {
                    control: Arc::clone(&self.control),
                    raw,
                    completed: false,
                };
                let _ = self.control.events.send(Event::Polled(
                    raw,
                    thread::current().id(),
                    IN_CALLBACK.with(Cell::get),
                ));
                let _actor = self.actor_surrogate.upgrade();
                assert!(
                    !self.control.panic.load(Ordering::SeqCst),
                    "controlled target panic"
                );
                let reenter = self.control.reenter.lock().unwrap().take();
                if let Some((callback, raw)) = reenter {
                    invoke(&callback, raw);
                }
                if self.control.gated {
                    let mut gate = std::pin::pin!(self.control.gate.acquire());
                    let mut reported = false;
                    std::future::poll_fn(|context| match gate.as_mut().poll(context) {
                        Poll::Pending => {
                            if !reported {
                                reported = true;
                                let _ = self.control.events.send(Event::PendingGate(
                                    raw,
                                    thread::current().id(),
                                    IN_CALLBACK.with(Cell::get),
                                ));
                            }
                            Poll::Pending
                        }
                        Poll::Ready(result) => Poll::Ready(result),
                    })
                    .await
                    .unwrap()
                    .forget();
                }
                let outcome = self
                    .control
                    .outcomes
                    .lock()
                    .unwrap()
                    .pop_front()
                    .unwrap_or(FirstFrameDelivery::Delivered);
                let observed = match &outcome {
                    FirstFrameDelivery::Delivered => Observed::Delivered,
                    FirstFrameDelivery::TargetGone => Observed::Gone,
                    FirstFrameDelivery::Failed(error) => {
                        Observed::Failed(error.kind(), error.message().to_owned())
                    }
                };
                in_flight.completed = true;
                let _ = self.control.events.send(Event::Completed(raw, observed));
                outcome
            }
        }
    }

    fn target(
        gated: bool,
    ) -> (
        Target,
        Arc<Control>,
        mpsc::UnboundedReceiver<Event>,
        Weak<()>,
    ) {
        let (events, receiver) = mpsc::unbounded_channel();
        let control = Arc::new(Control {
            started: AtomicUsize::new(0),
            active: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            gate: Semaphore::new(0),
            gated,
            outcomes: Mutex::new(VecDeque::new()),
            reenter: Mutex::new(None),
            panic: AtomicBool::new(false),
            events,
        });
        let lifetime = Arc::new(());
        let weak = Arc::downgrade(&lifetime);
        (
            Target {
                control: Arc::clone(&control),
                lifetime: Some(lifetime),
                actor_surrogate: Weak::new(),
            },
            control,
            receiver,
            weak,
        )
    }

    async fn next(receiver: &mut mpsc::UnboundedReceiver<Event>) -> Event {
        bounded(receiver.recv()).await.expect("event stream closed")
    }

    async fn pending(receiver: &mut mpsc::UnboundedReceiver<Event>) -> (u64, ThreadId, ThreadId) {
        let mut construction = None;
        let mut polling = None;
        loop {
            match next(receiver).await {
                Event::Started(raw, thread, inline) => {
                    assert!(!inline, "delivery constructed on callback path");
                    construction = Some((raw, thread));
                }
                Event::Polled(raw, thread, inline) => {
                    assert!(!inline, "delivery polled on callback path");
                    polling = Some((raw, thread));
                }
                Event::PendingGate(raw, thread, inline) => {
                    assert!(!inline, "pending reply gate polled on callback path");
                    let (constructed_raw, construction_thread) =
                        construction.expect("missing construction event");
                    let (polled_raw, polling_thread) = polling.expect("missing first-poll event");
                    assert_eq!((constructed_raw, polled_raw), (raw, raw));
                    assert_eq!(thread, polling_thread);
                    return (raw, construction_thread, polling_thread);
                }
                other => panic!("expected genuinely pending gate, got {:?}", other),
            }
        }
    }

    async fn completed(
        receiver: &mut mpsc::UnboundedReceiver<Event>,
        count: usize,
    ) -> Vec<(u64, Observed)> {
        let mut result = Vec::new();
        while result.len() < count {
            if let Event::Completed(raw, outcome) = next(receiver).await {
                result.push((raw, outcome));
            }
        }
        result
    }

    #[test]
    fn hh01_explicit_handle_without_ambient_context_and_no_replay() {
        let runtime = runtime();
        let handle = runtime.handle().clone();
        let (target, control, mut events, _) = target(false);
        let (returned, returns) = std::sync::mpsc::channel();
        let thread = thread::spawn(move || {
            assert!(tokio::runtime::Handle::try_current().is_err());
            let owner = FirstFrameHandoff::start(&handle, target);
            let callback = owner.callback();
            assert_eq!(control.started.load(Ordering::SeqCst), 0);
            invoke(&callback, 7);
            returned
                .send(owner)
                .unwrap_or_else(|_| panic!("owner receiver dropped"));
        });
        let owner = returns.recv_timeout(GUARD).unwrap();
        thread.join().unwrap();
        runtime.block_on(async {
            assert_eq!(
                completed(&mut events, 1).await,
                vec![(7, Observed::Delivered)]
            );
            bounded(owner.stop()).await;
        });
    }

    #[test]
    fn hh02_hh03_pending_delivery_never_blocks_or_polls_on_callback_path() {
        let runtime = runtime();
        let (target, control, mut events, _) = target(true);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callback = owner.callback();
        let (returned, returns) = std::sync::mpsc::channel();
        let (continue_callback, continuation) = std::sync::mpsc::channel();
        let thread = thread::spawn(move || {
            let id = thread::current().id();
            invoke(&callback, 1);
            returned.send(id).unwrap();
            continuation.recv_timeout(GUARD).unwrap();
            invoke(&callback, 2);
            returned.send(id).unwrap();
        });
        let callback_thread = returns.recv_timeout(GUARD).unwrap();
        runtime.block_on(async {
            let (raw, construction_thread, polling_thread) = pending(&mut events).await;
            assert_eq!(raw, 1);
            // Callback two cannot begin until the real first-poll gate has
            // returned Pending. Its return is observed before granting replies.
            continue_callback.send(()).unwrap();
            returns.recv_timeout(GUARD).unwrap();
            thread.join().unwrap();
            assert_ne!(callback_thread, construction_thread);
            assert_ne!(callback_thread, polling_thread);
            assert_eq!(control.started.load(Ordering::SeqCst), 1);
            control.gate.add_permits(2);
            assert_eq!(completed(&mut events, 2).await.len(), 2);
            bounded(owner.stop()).await;
        });
    }

    #[test]
    fn hh04_hh05_hh06_exact_burst_multiset_and_concurrent_callbacks() {
        let runtime = runtime();
        let (target, control, mut events, _) = target(true);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callback = owner.callback();
        invoke(&callback, 41);
        runtime.block_on(async {
            assert_eq!(pending(&mut events).await.0, 41);
        });
        let mut threads = Vec::new();
        let mut expected = vec![41];
        let (returned, returns) = std::sync::mpsc::channel();
        for worker in 0..8_u64 {
            let callback = callback.clone();
            let returned = returned.clone();
            threads.push(thread::spawn(move || {
                for index in 0..1024_u64 {
                    let raw = match index % 4 {
                        0 => 0,
                        1 => u64::MAX,
                        2 => 9,
                        _ => worker * 1024 + index,
                    };
                    invoke(&callback, raw);
                }
                returned.send(()).unwrap();
            }));
            for index in 0..1024_u64 {
                expected.push(match index % 4 {
                    0 => 0,
                    1 => u64::MAX,
                    2 => 9,
                    _ => worker * 1024 + index,
                });
            }
        }
        for _ in 0..8 {
            returns.recv_timeout(GUARD).unwrap();
        }
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
        control.gate.add_permits(expected.len());
        runtime.block_on(async {
            let receipts = completed(&mut events, expected.len()).await;
            assert!(
                receipts
                    .iter()
                    .all(|(_, outcome)| *outcome == Observed::Delivered)
            );
            let mut actual: Vec<_> = receipts.into_iter().map(|(raw, _)| raw).collect();
            actual.sort_unstable();
            expected.sort_unstable();
            assert_eq!(actual, expected);
            bounded(owner.stop()).await;
        });
        assert_eq!(control.started.load(Ordering::SeqCst), 8193);
        assert_eq!(control.peak.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn hh07_reentrant_receipt_and_hh08_typed_outcomes_continue_without_retry() {
        let runtime = runtime();
        let (target, control, mut events, _) = target(false);
        let config_error = BridgeError::Error {
            kind: crate::api::BridgeErrorKind::Config,
            message: "caller config failure".to_owned(),
        };
        let engine_error = BridgeError::engine("caller engine failure");
        control.outcomes.lock().unwrap().extend([
            FirstFrameDelivery::Delivered,
            FirstFrameDelivery::TargetGone,
            FirstFrameDelivery::Failed(config_error),
            FirstFrameDelivery::Failed(engine_error),
            FirstFrameDelivery::Delivered,
        ]);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let mut observations = observe(&owner, None, None);
        *control.reenter.lock().unwrap() = Some((owner.callback(), 2));
        invoke(&owner.callback(), 1);
        runtime.block_on(async {
            assert_eq!(
                completed(&mut events, 2).await,
                vec![(1, Observed::Delivered), (2, Observed::Gone)]
            );
            let (raw, outcome, _) = diagnostic(&mut observations).await;
            assert_eq!((raw, outcome), (2, DiagnosticOutcome::TargetGone));
            for raw in 3..=5 {
                invoke(&owner.callback(), raw);
            }
            assert_eq!(
                completed(&mut events, 3).await,
                vec![
                    (
                        3,
                        Observed::Failed(
                            crate::api::BridgeErrorKind::Config,
                            "caller config failure".into()
                        )
                    ),
                    (
                        4,
                        Observed::Failed(
                            crate::api::BridgeErrorKind::Engine,
                            "caller engine failure".into()
                        )
                    ),
                    (5, Observed::Delivered),
                ]
            );
            // These observations originate in the actual dispatcher match
            // arms after logging, not in the target's chosen-outcome report.
            let (raw, outcome, _) = diagnostic(&mut observations).await;
            assert_eq!(
                (raw, outcome),
                (
                    3,
                    DiagnosticOutcome::Failed {
                        kind: crate::api::BridgeErrorKind::Config,
                        message: "caller config failure".into(),
                    }
                )
            );
            let (raw, outcome, _) = diagnostic(&mut observations).await;
            assert_eq!(
                (raw, outcome),
                (
                    4,
                    DiagnosticOutcome::Failed {
                        kind: crate::api::BridgeErrorKind::Engine,
                        message: "caller engine failure".into(),
                    }
                )
            );
            bounded(owner.stop()).await;
            while let Ok(event) = observations.try_recv() {
                assert!(
                    !matches!(event, DispatchEvent::Diagnostic(_, _, _, _)),
                    "unexpected retry/diagnostic"
                );
            }
        });
        assert_eq!(control.started.load(Ordering::SeqCst), 5);
        assert_eq!(control.active.load(Ordering::SeqCst), 0);
    }

    #[derive(Default)]
    struct WakeCount(AtomicUsize);
    impl Wake for WakeCount {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
        fn wake_by_ref(self: &Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn hh09_idle_has_no_target_activity_or_self_wakes() {
        let (intake, receiver) = Intake::new();
        let (target, control, mut events, _) = target(false);
        let wakes = Arc::new(WakeCount::default());
        let waker = Waker::from(Arc::clone(&wakes));
        let mut context = Context::from_waker(&waker);
        let mut dispatcher = Box::pin(dispatch(
            DispatcherLifetime(Arc::clone(&intake)),
            receiver,
            target,
        ));
        assert!(dispatcher.as_mut().poll(&mut context).is_pending());
        assert_eq!(wakes.0.load(Ordering::SeqCst), 0);
        assert_eq!(control.started.load(Ordering::SeqCst), 0);
        assert!(events.try_recv().is_err());
        invoke(&Intake::callback(&intake), 5);
        assert_eq!(wakes.0.load(Ordering::SeqCst), 1);
        assert!(dispatcher.as_mut().poll(&mut context).is_pending());
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
        let after_receipt = wakes.0.load(Ordering::SeqCst);
        assert!(dispatcher.as_mut().poll(&mut context).is_pending());
        assert_eq!(wakes.0.load(Ordering::SeqCst), after_receipt);
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
        drop(dispatcher);
        assert_ne!(intake.state.load(Ordering::Acquire) & CLOSED, 0);
    }

    #[test]
    fn hh10_hh15_close_before_receipts_disables_every_callback() {
        // No dispatcher scheduling occurs until the final block_on below.
        let runtime = Builder::new_current_thread().enable_all().build().unwrap();
        let (target, control, _, weak) = target(false);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callbacks: Vec<_> = (0..8).map(|_| owner.callback()).collect();
        owner.close();
        owner.close();
        for callback in &callbacks {
            invoke(callback, 4);
        }
        runtime.block_on(bounded(owner.stop()));
        for callback in &callbacks {
            invoke(callback, 5);
        }
        assert_eq!(control.started.load(Ordering::SeqCst), 0);
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn hh11_stop_cancels_active_discards_queue_and_observes_destruction() {
        let runtime = runtime();
        let (target, control, mut events, weak) = target(true);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callback = owner.callback();
        invoke(&callback, 1);
        runtime.block_on(async {
            pending(&mut events).await;
            for raw in 2..1024 {
                invoke(&callback, raw);
            }
            owner.close();
            bounded(owner.stop()).await;
            assert!(weak.upgrade().is_none());
            assert_eq!(control.active.load(Ordering::SeqCst), 0);
            assert_eq!(control.started.load(Ordering::SeqCst), 1);
            let mut canceled = false;
            let mut target_dropped = false;
            while let Ok(event) = events.try_recv() {
                match event {
                    Event::FutureDropped(1, false) => canceled = true,
                    Event::TargetDropped => target_dropped = true,
                    Event::Completed(_, _) => panic!("closed pending request reported completion"),
                    _ => {}
                }
            }
            assert!(canceled && target_dropped);
            assert_eq!(control.gate.available_permits(), 0);
        });
    }

    #[test]
    fn hh12_controlled_close_winner_and_racing_admission() {
        let runtime = runtime();
        // Close wins at the actual fetch_or/CAS boundary. Defer the abort
        // half of public close until stop so the rejected CAS is observable;
        // the admission-closing atomic is the very same Intake::close call.
        let (close_target, control, _, weak) = target(false);
        let owner = FirstFrameHandoff::start(runtime.handle(), close_target);
        let before = Arc::new(Semaphore::new(0));
        let mut observations = observe(&owner, Some(Arc::clone(&before)), None);
        invoke(&owner.callback(), 1);
        runtime.block_on(async {
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::BeforeReservation(1)
            );
            owner.intake.close();
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::Closed(OPEN)
            );
            invoke(&owner.callback(), 2);
            before.add_permits(1);
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::Reservation(1, Err(CLOSED))
            );
            bounded(owner.stop()).await;
        });
        assert_eq!(control.started.load(Ordering::SeqCst), 0);
        assert!(weak.upgrade().is_none());

        // Reservation wins the real CAS first, then pauses before construction
        // of target.deliver. Public close cancels that already-started logical
        // invocation without requiring a physical target call or mailbox undo.
        let (reserved_target, control, _, weak) = target(false);
        let owner = FirstFrameHandoff::start(runtime.handle(), reserved_target);
        let after = Arc::new(Semaphore::new(0));
        let mut observations = observe(&owner, None, Some(Arc::clone(&after)));
        invoke(&owner.callback(), 3);
        runtime.block_on(async {
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::BeforeReservation(3)
            );
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::Reservation(3, Ok(OPEN))
            );
            invoke(&owner.callback(), 4);
            owner.close();
            assert_eq!(
                dispatch_event(&mut observations).await,
                DispatchEvent::Closed(INVOKING)
            );
            bounded(owner.stop()).await;
        });
        assert_eq!(after.available_permits(), 0);
        assert_eq!(control.started.load(Ordering::SeqCst), 0);
        assert!(weak.upgrade().is_none());

        // Retain concurrent callback/close coverage in addition to the two
        // deterministic, observed boundary orders above.
        for _ in 0..64 {
            let (target, control, _, _) = target(true);
            let owner = FirstFrameHandoff::start(runtime.handle(), target);
            let callback = owner.callback();
            let barrier = Arc::new(Barrier::new(2));
            let callback_barrier = Arc::clone(&barrier);
            let (returned, returns) = std::sync::mpsc::channel();
            let thread = thread::spawn(move || {
                callback_barrier.wait();
                invoke(&callback, 2);
                returned.send(()).unwrap();
            });
            barrier.wait();
            owner.close();
            returns.recv_timeout(GUARD).unwrap();
            thread.join().unwrap();
            let reservations = owner.intake.state.load(Ordering::Acquire);
            assert_ne!(reservations & CLOSED, 0);
            invoke(&owner.callback(), 3);
            runtime.block_on(bounded(owner.stop()));
            assert!(control.started.load(Ordering::SeqCst) <= 1);
            assert_eq!(control.active.load(Ordering::SeqCst), 0);
        }
    }

    #[test]
    fn hh13_drop_is_nonwaiting_and_cancels_pending_future() {
        let runtime = runtime();
        let (target, control, mut events, weak) = target(true);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callback = owner.callback();
        invoke(&callback, 1);
        runtime.block_on(async {
            pending(&mut events).await;
            drop(owner);
            invoke(&callback, 2);
            let mut canceled = false;
            let mut dropped = false;
            while !canceled || !dropped {
                match next(&mut events).await {
                    Event::FutureDropped(1, false) => canceled = true,
                    Event::TargetDropped => dropped = true,
                    Event::Completed(_, _) => panic!("drop completed gated request"),
                    _ => {}
                }
            }
        });
        assert!(weak.upgrade().is_none());
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
        assert_eq!(control.gate.available_permits(), 0);
    }

    #[test]
    fn hh14_retained_callbacks_own_neither_intake_target_actor_surrogate_nor_runtime_owner() {
        let runtime = Arc::new(runtime());
        let weak_runtime = Arc::downgrade(&runtime);
        let actor_surrogate = Arc::new(());
        let weak_actor = Arc::downgrade(&actor_surrogate);
        let (mut target, control, _, weak_target) = target(true);
        target.actor_surrogate = weak_actor.clone();
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let weak_intake = Arc::downgrade(&owner.intake);
        let callbacks = [owner.callback(), owner.callback()];
        assert_eq!(Arc::strong_count(&actor_surrogate), 1);
        drop(actor_surrogate);
        assert!(weak_actor.upgrade().is_none());
        runtime.block_on(bounded(owner.stop()));
        assert!(weak_intake.upgrade().is_none());
        assert!(weak_target.upgrade().is_none());
        drop(runtime);
        assert!(weak_runtime.upgrade().is_none());
        for callback in &callbacks {
            invoke(callback, 99);
        }
        assert_eq!(control.started.load(Ordering::SeqCst), 0);
    }

    #[derive(Default)]
    struct Slot(Mutex<Option<FirstFrameCallback>>);
    impl Slot {
        fn install(&self, callback: FirstFrameCallback, synchronous: Option<u64>) {
            *self.0.lock().unwrap() = Some(callback.clone());
            if let Some(raw) = synchronous {
                invoke(&callback, raw);
            }
        }
        fn acquire(&self) -> FirstFrameCallback {
            self.0.lock().unwrap().as_ref().unwrap().clone()
        }
    }

    #[test]
    fn hh16_replacement_preserves_old_live_owner_and_new_slot() {
        let runtime = runtime();
        let slot = Slot::default();
        let (a, a_control, mut a_events, _) = target(false);
        let (b, b_control, mut b_events, _) = target(false);
        let a = FirstFrameHandoff::start(runtime.handle(), a);
        let b = FirstFrameHandoff::start(runtime.handle(), b);
        slot.install(a.callback(), None);
        let saved_a = slot.acquire();
        slot.install(b.callback(), None);
        let installed_b = slot.acquire();
        invoke(&saved_a, 1);
        runtime.block_on(async {
            assert_eq!(completed(&mut a_events, 1).await[0].0, 1);
            bounded(a.stop()).await;
            assert!(Arc::ptr_eq(&installed_b, &slot.acquire()));
            invoke(&saved_a, 2);
            invoke(&slot.acquire(), 3);
            assert_eq!(completed(&mut b_events, 1).await[0].0, 3);
            bounded(b.stop()).await;
        });
        assert_eq!(a_control.started.load(Ordering::SeqCst), 1);
        assert_eq!(b_control.started.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn hh17_synchronous_registration_and_constructor_failure_leave_slot_untouched() {
        let runtime = runtime();
        let slot = Slot::default();
        let (target, control, mut events, _) = target(false);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        slot.install(owner.callback(), Some(7));
        let saved = slot.acquire();
        runtime.block_on(async {
            assert_eq!(completed(&mut events, 1).await[0].0, 7);
        });
        drop(owner); // Independently simulated later constructor failure.
        invoke(&saved, 8);
        assert!(Arc::ptr_eq(&saved, &slot.acquire()));
        runtime.block_on(async {
            loop {
                if matches!(next(&mut events).await, Event::TargetDropped) {
                    break;
                }
            }
        });
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn hh18_stop_on_other_executor_and_required_auto_traits() {
        fn send_sync_static<T: Send + Sync + 'static>() {}
        fn send<T: Send>(_: &T) {}
        send_sync_static::<FirstFrameHandoff>();
        send_sync_static::<FirstFrameCallback>();
        let actor_runtime = runtime();
        let other_runtime = Builder::new_current_thread().enable_all().build().unwrap();
        let (target, control, mut events, weak) = target(true);
        let owner = FirstFrameHandoff::start(actor_runtime.handle(), target);
        invoke(&owner.callback(), 9);
        actor_runtime.block_on(async {
            pending(&mut events).await;
        });
        let stop = owner.stop();
        send(&stop);
        other_runtime.block_on(bounded(stop));
        assert!(weak.upgrade().is_none());
        assert_eq!(control.active.load(Ordering::SeqCst), 0);
        assert_eq!(control.gate.available_permits(), 0);
    }

    #[test]
    fn hh19_runtime_loss_cancels_without_success_or_resurrection() {
        let actor_runtime = runtime();
        let (target, control, mut events, weak) = target(true);
        let owner = FirstFrameHandoff::start(actor_runtime.handle(), target);
        let callback = owner.callback();
        invoke(&callback, 1);
        actor_runtime.block_on(async {
            pending(&mut events).await;
        });
        drop(actor_runtime);
        assert!(weak.upgrade().is_none());
        assert_eq!(control.active.load(Ordering::SeqCst), 0);
        assert_ne!(owner.intake.state.load(Ordering::Acquire) & CLOSED, 0);
        invoke(&callback, 2);
        let observer = Builder::new_current_thread().enable_all().build().unwrap();
        observer.block_on(bounded(owner.stop()));
        assert_eq!(control.started.load(Ordering::SeqCst), 1);
        let mut canceled = false;
        while let Ok(event) = events.try_recv() {
            match event {
                Event::FutureDropped(1, false) => canceled = true,
                Event::Completed(_, _) => panic!("runtime loss fabricated success"),
                _ => {}
            }
        }
        assert!(canceled);
    }

    #[test]
    fn hh20_target_panic_stays_off_callback_and_is_resumed_by_stop() {
        let runtime = runtime();
        let (target, control, mut events, _) = target(false);
        control.panic.store(true, Ordering::SeqCst);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                invoke(&owner.callback(), 1);
            }))
            .is_ok()
        );
        runtime.block_on(async {
            loop {
                if matches!(next(&mut events).await, Event::TargetDropped) {
                    break;
                }
            }
            // A spawned stop observer makes its resumed panic an observable
            // JoinError; this test task is not production dispatcher fanout.
            let observer = tokio::spawn(owner.stop());
            let error = bounded(observer)
                .await
                .expect_err("stop suppressed dispatcher panic");
            assert!(error.is_panic());
            let panic = error.into_panic();
            let message = panic
                .downcast_ref::<&str>()
                .copied()
                .or_else(|| panic.downcast_ref::<String>().map(String::as_str));
            assert_eq!(message, Some("controlled target panic"));
        });
    }

    #[test]
    fn hh21_completed_futures_are_released_and_stop_leaves_no_worker() {
        let runtime = runtime();
        let (target, control, mut events, weak) = target(false);
        let owner = FirstFrameHandoff::start(runtime.handle(), target);
        let callback = owner.callback();
        for raw in 0..64 {
            invoke(&callback, raw);
        }
        runtime.block_on(async {
            let mut completed = Vec::new();
            let mut destroyed = Vec::new();
            while completed.len() < 64 || destroyed.len() < 64 {
                match next(&mut events).await {
                    Event::Completed(raw, _) => completed.push(raw),
                    Event::FutureDropped(raw, true) => destroyed.push(raw),
                    Event::FutureDropped(_, false) => panic!("completed event was canceled"),
                    _ => {}
                }
            }
            completed.sort_unstable();
            destroyed.sort_unstable();
            assert_eq!(completed, (0..64).collect::<Vec<_>>());
            assert_eq!(destroyed, completed);
            assert_eq!(control.active.load(Ordering::SeqCst), 0);
            assert!(weak.upgrade().is_some());
            bounded(owner.stop()).await;
            assert!(weak.upgrade().is_none());
            assert!(matches!(next(&mut events).await, Event::TargetDropped));
            invoke(&callback, 65);
            assert_eq!(control.started.load(Ordering::SeqCst), 64);
        });
    }
}
