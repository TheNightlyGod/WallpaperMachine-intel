//! Private controlled-dependency mechanics; feature policy stays with the adapters.

use std::collections::{HashMap, VecDeque};
use std::future::{Future, pending};
use std::hash::Hash;
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

use tokio::sync::oneshot;

pub(crate) struct Observation<T> {
    values: Arc<Mutex<Vec<T>>>,
}

impl<T> Clone for Observation<T> {
    fn clone(&self) -> Self {
        Self {
            values: Arc::clone(&self.values),
        }
    }
}

impl<T> Observation<T> {
    pub(crate) fn new() -> Self {
        Self {
            values: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub(crate) fn record(&self, value: T) {
        self.values
            .lock()
            .expect("observation poisoned")
            .push(value);
    }

    pub(crate) fn len(&self) -> usize {
        self.values.lock().expect("observation poisoned").len()
    }

    pub(crate) fn snapshot(&self) -> Vec<T>
    where
        T: Clone,
    {
        self.values.lock().expect("observation poisoned").clone()
    }
}

struct ReadingState<T> {
    stored: T,
    script: VecDeque<T>,
}

pub(crate) struct Reading<T> {
    state: Arc<Mutex<ReadingState<T>>>,
}

impl<T> Clone for Reading<T> {
    fn clone(&self) -> Self {
        Self {
            state: Arc::clone(&self.state),
        }
    }
}

impl<T> Reading<T> {
    pub(crate) fn new(stored: T) -> Self {
        Self {
            state: Arc::new(Mutex::new(ReadingState {
                stored,
                script: VecDeque::new(),
            })),
        }
    }

    pub(crate) fn set(&self, value: T) {
        let old = {
            let mut state = self.state.lock().expect("reading poisoned");
            std::mem::replace(&mut state.stored, value)
        };
        drop(old);
    }

    pub(crate) fn script(&self, values: Vec<T>) {
        let old = {
            let mut state = self.state.lock().expect("reading poisoned");
            std::mem::replace(&mut state.script, values.into())
        };
        drop(old);
    }

    pub(crate) fn read(&self) -> T
    where
        T: Clone,
    {
        let mut state = self.state.lock().expect("reading poisoned");
        if state.script.len() > 1 {
            state
                .script
                .pop_front()
                .expect("script has multiple samples")
        } else {
            state.script.front().unwrap_or(&state.stored).clone()
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReleaseFailure {
    TimedOut,
    Disconnected,
}

struct EntryEvidence {
    entered: Mutex<bool>,
    changed: Condvar,
}

struct QueuedHold {
    entered: Arc<EntryEvidence>,
    release: oneshot::Receiver<()>,
}

/// Only hold handles own the sender. Dropping the last one is a genuine loss
/// of the release owner, independently of the control and admission lifetimes.
#[derive(Clone)]
pub(crate) struct Hold {
    entered: Arc<EntryEvidence>,
    release: Arc<Mutex<Option<oneshot::Sender<()>>>>,
}

impl Hold {
    pub(crate) fn wait_entered(&self, timeout: Duration) -> bool {
        let entered = self
            .entered
            .entered
            .lock()
            .expect("entry evidence poisoned");
        let (entered, _) = self
            .entered
            .changed
            .wait_timeout_while(entered, timeout, |value| !*value)
            .expect("entry evidence poisoned");
        *entered
    }

    pub(crate) fn release(&self) {
        let sender = self.release.lock().expect("release owner poisoned").take();
        if let Some(sender) = sender {
            let _ = sender.send(());
        }
    }
}

pub(crate) struct Admission {
    release: Option<oneshot::Receiver<()>>,
}

impl Admission {
    /// Owner loss is not a release and does not manufacture operation failure.
    /// Adapters needing a bounded failure distinction use `wait_bounded`.
    pub(crate) async fn wait(self) {
        if let Some(release) = self.release {
            if release.await.is_err() {
                pending::<()>().await;
            }
        }
    }

    /// Requires the caller's Tokio time-driver context only when release is pending.
    pub(crate) async fn wait_bounded(self, timeout: Duration) -> Result<(), ReleaseFailure> {
        let Some(mut release) = self.release else {
            return Ok(());
        };
        match release.try_recv() {
            Ok(()) => return Ok(()),
            Err(oneshot::error::TryRecvError::Closed) => return Err(ReleaseFailure::Disconnected),
            Err(oneshot::error::TryRecvError::Empty) => {}
        }
        match tokio::time::timeout(timeout, release).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) => Err(ReleaseFailure::Disconnected),
            Err(_) => Err(ReleaseFailure::TimedOut),
        }
    }
}

pub(crate) struct Completion {
    next: mpsc::Receiver<()>,
}

impl Completion {
    pub(crate) fn wait(self, timeout: Duration) -> bool {
        self.next.recv_timeout(timeout).is_ok()
    }
}

struct ControlState<K> {
    holds: HashMap<K, VecDeque<QueuedHold>>,
    completions: HashMap<K, Vec<mpsc::Sender<()>>>,
}

pub(crate) struct Control<K> {
    state: Arc<Mutex<ControlState<K>>>,
}

impl<K> Clone for Control<K> {
    fn clone(&self) -> Self {
        Self {
            state: Arc::clone(&self.state),
        }
    }
}

impl<K: Eq + Hash> Control<K> {
    pub(crate) fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(ControlState {
                holds: HashMap::new(),
                completions: HashMap::new(),
            })),
        }
    }

    pub(crate) fn hold_next(&self, key: K) -> Hold {
        let entered = Arc::new(EntryEvidence {
            entered: Mutex::new(false),
            changed: Condvar::new(),
        });
        let (sender, release) = oneshot::channel();
        self.state
            .lock()
            .expect("control poisoned")
            .holds
            .entry(key)
            .or_default()
            .push_back(QueuedHold {
                entered: Arc::clone(&entered),
                release,
            });
        Hold {
            entered,
            release: Arc::new(Mutex::new(Some(sender))),
        }
    }

    pub(crate) fn enter(&self, key: K) -> Admission {
        let queued = {
            let mut state = self.state.lock().expect("control poisoned");
            let queued = state.holds.get_mut(&key).and_then(VecDeque::pop_front);
            if state.holds.get(&key).is_some_and(VecDeque::is_empty) {
                state.holds.remove(&key);
            }
            queued
        };
        match queued {
            Some(queued) => {
                *queued
                    .entered
                    .entered
                    .lock()
                    .expect("entry evidence poisoned") = true;
                queued.entered.changed.notify_all();
                Admission {
                    release: Some(queued.release),
                }
            }
            None => Admission { release: None },
        }
    }

    pub(crate) fn observe_next_completion(&self, key: K) -> Completion {
        let (sender, next) = mpsc::channel();
        self.state
            .lock()
            .expect("control poisoned")
            .completions
            .entry(key)
            .or_default()
            .push(sender);
        Completion { next }
    }

    pub(crate) fn finish(&self, key: K) {
        let observers = self
            .state
            .lock()
            .expect("control poisoned")
            .completions
            .remove(&key);
        if let Some(observers) = observers {
            for observer in observers {
                let _ = observer.send(());
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FaultCategory {
    InvalidInput,
    Platform,
    Render,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Fault {
    pub(crate) category: FaultCategory,
    pub(crate) message: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum FailurePolicy {
    Next(Fault),
    Persistent(Fault),
}

pub(crate) struct Failures<K> {
    policies: Arc<Mutex<HashMap<K, FailurePolicy>>>,
}

impl<K> Clone for Failures<K> {
    fn clone(&self) -> Self {
        Self {
            policies: Arc::clone(&self.policies),
        }
    }
}

impl<K: Eq + Hash> Failures<K> {
    pub(crate) fn new() -> Self {
        Self {
            policies: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub(crate) fn set(&self, key: K, policy: FailurePolicy) {
        let old = self
            .policies
            .lock()
            .expect("failures poisoned")
            .insert(key, policy);
        drop(old);
    }

    pub(crate) fn clear(&self, key: K) {
        let old = self
            .policies
            .lock()
            .expect("failures poisoned")
            .remove(&key);
        drop(old);
    }

    pub(crate) fn check(&self, key: K) -> Result<(), Fault> {
        let mut policies = self.policies.lock().expect("failures poisoned");
        match policies.get(&key) {
            None => Ok(()),
            Some(FailurePolicy::Persistent(fault)) => Err(fault.clone()),
            Some(FailurePolicy::Next(_)) => {
                match policies.remove(&key).expect("checked failure policy") {
                    FailurePolicy::Next(fault) => Err(fault),
                    FailurePolicy::Persistent(_) => unreachable!("policy changed under lock"),
                }
            }
        }
    }
}

pub(crate) struct Callable<C> {
    value: Arc<Mutex<Option<C>>>,
}

impl<C> Clone for Callable<C> {
    fn clone(&self) -> Self {
        Self {
            value: Arc::clone(&self.value),
        }
    }
}

impl<C> Callable<C> {
    pub(crate) fn new() -> Self {
        Self {
            value: Arc::new(Mutex::new(None)),
        }
    }

    pub(crate) fn replace(&self, value: Option<C>) {
        let old = {
            let mut current = self.value.lock().expect("callable poisoned");
            std::mem::replace(&mut *current, value)
        };
        drop(old);
    }

    pub(crate) fn capture(&self) -> Option<C>
    where
        C: Clone,
    {
        self.value.lock().expect("callable poisoned").clone()
    }
}

pub(crate) trait DirectAccess<D, H, T> {
    fn handle(&self, row: &D) -> Option<H>;
    fn direct_mut<'a>(&self, row: &'a mut D) -> Option<&'a mut T>;
}

pub(crate) fn update_direct<D, H: Eq, T>(
    current: &mut [D],
    prepared_refresh: Option<&mut [D]>,
    handle: H,
    access: &impl DirectAccess<D, H, T>,
    update: impl Fn(&mut T),
) {
    for rows in std::iter::once(current).chain(prepared_refresh) {
        if let Some(row) = rows
            .iter_mut()
            .find(|row| access.handle(row).as_ref() == Some(&handle))
        {
            if let Some(template) = access.direct_mut(row) {
                update(template);
            }
        }
    }
}

pub(crate) trait ScenePort<S, D, R> {
    fn rendered(&self) -> Vec<S>;
    fn result(&self, index: usize, scene: &S) -> R;
    fn retain_preview_memory(&self, before: &[S], after: &[S]);
    fn replace_rendered(&self, scenes: Vec<S>);
    fn prepared_refresh(&self) -> Option<Vec<D>>;
    fn current_rows(&self) -> Vec<D>;
    fn publish_rows(&self, rows: Vec<D>);
    fn clear_preview_memory(&self);
    fn remove_live_assignment(&self, row: &mut D);
}

pub(crate) fn reconcile<'a, S, D, R, K, P>(
    scenes: Vec<S>,
    calls: &'a Observation<Vec<S>>,
    control: &'a Control<K>,
    admission_key: K,
    failures: &'a Failures<K>,
    failure_key: K,
    port: &'a P,
) -> impl Future<Output = Result<Vec<R>, Fault>> + Send + 'a
where
    S: Clone + Send + 'a,
    K: Clone + Eq + Hash + Send + 'a,
    P: ScenePort<S, D, R> + Sync + 'a,
{
    async move {
        calls.record(scenes.clone());
        control.enter(admission_key.clone()).wait().await;
        let result = failures.check(failure_key).map(|()| {
            let results = scenes
                .iter()
                .enumerate()
                .map(|(index, scene)| port.result(index, scene))
                .collect();
            let before = port.rendered();
            port.retain_preview_memory(&before, &scenes);
            port.replace_rendered(scenes);
            results
        });
        control.finish(admission_key);
        result
    }
}

pub(crate) fn refresh<S, D, R, K: Eq + Hash>(
    failures: &Failures<K>,
    failure_key: K,
    port: &impl ScenePort<S, D, R>,
) -> Result<(), Fault> {
    if let Some(rows) = port.prepared_refresh() {
        port.publish_rows(rows);
    }
    failures.check(failure_key)
}

pub(crate) fn close<S, D, R, K: Eq + Hash>(
    failures: &Failures<K>,
    failure_key: K,
    port: &impl ScenePort<S, D, R>,
) -> Result<(), Fault> {
    failures.check(failure_key)?;
    port.clear_preview_memory();
    let mut rows = port.current_rows();
    for row in &mut rows {
        port.remove_live_assignment(row);
    }
    port.publish_rows(rows);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::task::noop_waker;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    fn poll_once<F: Future>(future: Pin<&mut F>) -> Poll<F::Output> {
        let waker = noop_waker();
        future.poll(&mut Context::from_waker(&waker))
    }

    fn ready<F: Future>(future: F) -> F::Output {
        let mut future = Box::pin(future);
        match poll_once(future.as_mut()) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("expected immediate readiness"),
        }
    }

    fn fault(category: FaultCategory, message: &str) -> Fault {
        Fault {
            category,
            message: message.into(),
        }
    }

    #[test]
    fn observations_share_without_draining_or_aliasing_independent_histories() {
        let history = Observation::new();
        let shared = history.clone();
        let independent = Observation::new();
        history.record(String::from("first"));
        let before = history.snapshot();
        shared.record(String::from("second"));
        independent.record(String::from("elsewhere"));
        assert_eq!(before, ["first"]);
        assert_eq!(history.snapshot(), ["first", "second"]);
        assert_eq!(history.snapshot(), shared.snapshot());
        assert_eq!(independent.snapshot(), ["elsewhere"]);

        // Merely sharing a handle must not require cloning the payload.
        struct NotClone;
        let opaque = Observation::new();
        opaque.clone().record(NotClone);
    }

    #[test]
    fn concurrent_records_preserve_every_entry_and_each_producers_order() {
        let history = Observation::new();
        std::thread::scope(|scope| {
            for producer in 0..4 {
                let history = history.clone();
                scope.spawn(move || {
                    for sequence in 0..40 {
                        history.record((producer, sequence));
                    }
                });
            }
        });
        let values = history.snapshot();
        assert_eq!(values.len(), 160);
        for producer in 0..4 {
            let sequence: Vec<_> = values
                .iter()
                .filter(|(p, _)| *p == producer)
                .map(|(_, sequence)| *sequence)
                .collect();
            assert_eq!(sequence, (0..40).collect::<Vec<_>>());
        }
    }

    #[test]
    fn readings_keep_stored_and_scripted_values_independent_and_repeat_the_last() {
        let display = Reading::new(vec![1]);
        let report = Reading::<Vec<&str>>::new(Vec::new());
        let spectrum = Reading::<Option<Vec<f32>>>::new(None);
        assert_eq!(display.read(), [1]);
        assert!(report.read().is_empty());
        assert_eq!(spectrum.read(), None);
        display.script(vec![vec![2], vec![3]]);
        report.script(vec![vec!["warming"], vec!["ready"]]);
        display.set(vec![9]);
        assert_eq!(display.clone().read(), [2]);
        assert_eq!(report.read(), ["warming"]);
        assert_eq!(display.read(), [3]);
        assert_eq!(display.read(), [3]);
        assert_eq!(report.read(), ["ready"]);
        assert_eq!(report.read(), ["ready"]);
        display.script(vec![vec![7], vec![8]]);
        assert_eq!(display.read(), [7]);
        assert_eq!(display.read(), [8]);
        assert_eq!(display.read(), [8]);
        display.script(Vec::new());
        assert_eq!(display.read(), [9]);
        assert_eq!(report.read(), ["ready"]);
        report.script(Vec::new());
        assert!(report.read().is_empty());
        assert_eq!(spectrum.read(), None);
    }

    #[test]
    fn holds_are_keyed_fifo_and_completion_is_an_explicit_distinct_event() {
        let control = Control::new();
        let shared = control.clone();
        let first = control.hold_next("capture");
        let second = control.hold_next("capture");
        first.release();
        first.release();
        ready(control.enter("other").wait());
        assert!(!first.wait_entered(Duration::ZERO));
        assert!(!second.wait_entered(Duration::ZERO));
        ready(shared.enter("capture").wait());
        assert!(first.wait_entered(Duration::ZERO));
        assert!(!second.wait_entered(Duration::ZERO));
        let mut waiting = Box::pin(control.enter("capture").wait());
        assert!(second.wait_entered(Duration::ZERO));
        assert!(poll_once(waiting.as_mut()).is_pending());
        assert!(
            !control
                .observe_next_completion("capture")
                .wait(Duration::ZERO)
        );
        let during = control.observe_next_completion("capture");
        let also_during = shared.observe_next_completion("capture");
        let unrelated = control.observe_next_completion("other");
        second.clone().release();
        assert!(poll_once(waiting.as_mut()).is_ready());
        // Admission and release do not imply success or completion.
        assert!(
            !control
                .observe_next_completion("capture")
                .wait(Duration::ZERO)
        );
        control.finish("capture");
        assert!(during.wait(Duration::ZERO));
        assert!(also_during.wait(Duration::ZERO));
        assert!(!unrelated.wait(Duration::ZERO));
        assert!(
            !control
                .observe_next_completion("capture")
                .wait(Duration::ZERO)
        );
        let dropped = control.observe_next_completion("capture");
        drop(control.enter("capture"));
        assert!(!dropped.wait(Duration::ZERO));
        let failed = control.observe_next_completion("capture");
        let failures = Failures::new();
        failures.set(
            "disable",
            FailurePolicy::Next(fault(FaultCategory::Platform, "denied")),
        );
        assert!(failures.check("disable").is_err());
        shared.finish("capture");
        assert!(failed.wait(Duration::ZERO));
    }

    #[test]
    fn bounded_release_distinguishes_real_owner_loss_and_remembers_release() {
        let control = Control::new();
        let hold = control.hold_next(1);
        let retained_owner = hold.clone();
        drop(hold);
        let admission = control.enter(1);
        retained_owner.release();
        assert_eq!(ready(admission.wait_bounded(Duration::ZERO)), Ok(()));
        assert_eq!(ready(control.enter(2).wait_bounded(Duration::ZERO)), Ok(()));
        let lost = control.hold_next(3);
        drop(lost);
        assert_eq!(
            ready(control.enter(3).wait_bounded(Duration::ZERO)),
            Err(ReleaseFailure::Disconnected)
        );
        let lost = control.hold_next(4);
        let mut unbounded = Box::pin(control.enter(4).wait());
        drop(lost);
        assert!(poll_once(unbounded.as_mut()).is_pending());
    }

    #[test]
    fn failures_are_keyed_consumable_and_preserve_exact_categories_and_messages() {
        let failures = Failures::new();
        let next = fault(FaultCategory::Platform, "disable: exact text\n");
        failures.set("disable", FailurePolicy::Next(next.clone()));
        assert_eq!(failures.check("enable"), Ok(()));
        assert_eq!(failures.clone().check("disable"), Err(next));
        assert_eq!(failures.check("disable"), Ok(()));
        let persistent = fault(FaultCategory::Render, "render stays");
        failures.set("reconcile", FailurePolicy::Persistent(persistent.clone()));
        assert_eq!(failures.check("reconcile"), Err(persistent.clone()));
        assert_eq!(failures.check("reconcile"), Err(persistent));
        let replacement = fault(FaultCategory::InvalidInput, "unknown handle");
        failures.set("reconcile", FailurePolicy::Next(replacement.clone()));
        assert_eq!(failures.check("reconcile"), Err(replacement));
        assert_eq!(failures.check("reconcile"), Ok(()));
        failures.set(
            "reconcile",
            FailurePolicy::Persistent(fault(FaultCategory::Render, "clear me")),
        );
        failures.clear("reconcile");
        assert_eq!(failures.check("reconcile"), Ok(()));
    }

    #[test]
    fn callable_snapshots_retain_typed_payloads_and_allow_reentrant_removal() {
        type Callback = Arc<dyn Fn((u64, String, String)) + Send + Sync>;
        let slot = Callable::<Callback>::new();
        let delivered = Observation::new();
        let lifetime = Arc::new(());
        let weak = Arc::downgrade(&lifetime);
        let a_history = delivered.clone();
        let a: Callback = Arc::new(move |payload| {
            let _retained = &lifetime;
            a_history.record(("A", payload));
        });
        slot.replace(Some(a));
        let captured = slot.capture().expect("A installed");
        let b_history = delivered.clone();
        let reentrant = slot.clone();
        slot.replace(Some(Arc::new(move |payload| {
            reentrant.replace(None);
            b_history.record(("B", payload));
        })));
        assert!(weak.upgrade().is_some());
        if let Some(current) = slot.capture() {
            current((22, "action".into(), "current".into()));
        }
        assert!(slot.capture().is_none());
        slot.replace(None);
        if let Some(current) = slot.capture() {
            current((99, "must not".into(), "deliver".into()));
        }
        captured((11, "action".into(), "late".into()));
        assert_eq!(
            delivered.snapshot(),
            vec![
                ("B", (22, "action".into(), "current".into())),
                ("A", (11, "action".into(), "late".into())),
            ]
        );
        drop(captured);
        assert!(weak.upgrade().is_none());
    }

    #[derive(Clone, Debug, PartialEq)]
    enum Scaling {
        Fit,
        Fill,
    }
    #[derive(Clone, Debug, PartialEq)]
    enum Framing {
        Center,
        Offset(f64, f64),
    }
    #[derive(Clone, Debug, PartialEq)]
    struct Template {
        volume: f32,
        mute: bool,
        response: bool,
        media: bool,
        scaling: Scaling,
        factor: f64,
        framing: Framing,
        fps: u32,
    }
    #[derive(Clone, Debug, PartialEq)]
    enum Assignment {
        Direct(Template),
        Mirror(u32),
    }
    #[derive(Clone, Debug, PartialEq)]
    struct Row {
        label: &'static str,
        handle: Option<u64>,
        assignment: Option<Assignment>,
        pointer: bool,
        paused: bool,
        window: bool,
    }
    struct Access;
    impl DirectAccess<Row, u64, Template> for Access {
        fn handle(&self, row: &Row) -> Option<u64> {
            row.handle
        }
        fn direct_mut<'a>(&self, row: &'a mut Row) -> Option<&'a mut Template> {
            match row.assignment.as_mut() {
                Some(Assignment::Direct(template)) => Some(template),
                _ => None,
            }
        }
    }
    fn template() -> Template {
        Template {
            volume: 0.75,
            mute: false,
            response: false,
            media: false,
            scaling: Scaling::Fit,
            factor: 1.0,
            framing: Framing::Center,
            fps: 60,
        }
    }
    fn row(label: &'static str, handle: u64) -> Row {
        Row {
            label,
            handle: Some(handle),
            assignment: Some(Assignment::Direct(template())),
            pointer: true,
            paused: true,
            window: true,
        }
    }

    #[test]
    fn each_typed_update_selects_only_first_matching_direct_in_each_present_target() {
        let updates: [fn(&mut Template); 8] = [
            |t| t.volume = 0.1234567,
            |t| t.mute = true,
            |t| t.response = true,
            |t| t.media = true,
            |t| t.scaling = Scaling::Fill,
            |t| t.factor = 1.234567890123,
            |t| t.framing = Framing::Offset(0.123456789, -0.987654321),
            |t| t.fps = 144,
        ];
        for update in updates {
            let original = vec![row("other", 4), row("first", 7), row("duplicate", 7)];
            let mut current = original.clone();
            let mut prepared = Some(original.clone());
            update_direct(&mut current, prepared.as_deref_mut(), 7, &Access, update);
            let mut expected = original.clone();
            update(Access.direct_mut(&mut expected[1]).unwrap());
            assert_eq!(current, expected);
            assert_eq!(prepared, Some(expected.clone()));
            update_direct(&mut current, None, 900, &Access, update);
            assert_eq!(current, expected);
            update_direct(&mut current, None, 7, &Access, update);
            assert_eq!(current, expected);
            for assignment in [Some(Assignment::Mirror(42)), None] {
                let mut blocked = original.clone();
                blocked[1].assignment = assignment;
                let unchanged = blocked.clone();
                let mut refresh_rows = Some(blocked.clone());
                update_direct(
                    &mut blocked,
                    refresh_rows.as_deref_mut(),
                    7,
                    &Access,
                    update,
                );
                assert_eq!(blocked, unchanged);
                assert_eq!(refresh_rows, Some(unchanged));
            }
            let mut absent: Option<Vec<Row>> = None;
            let mut no_prepared = original;
            update_direct(&mut no_prepared, absent.as_deref_mut(), 7, &Access, update);
            assert_eq!(no_prepared, expected);
            assert!(absent.is_none());
        }
    }

    // A value-level port exercises the helper's algorithm, not an engine or actor.
    // Each hook is independently observed; no opaque operation is delegated here.
    struct Values {
        scenes: Mutex<Vec<&'static str>>,
        prepared: Mutex<Option<Vec<Row>>>,
        rows: Mutex<Vec<Row>>,
        preview: Mutex<Vec<&'static str>>,
        actions: Observation<String>,
        publications: Observation<Vec<Row>>,
        retained: Observation<(Vec<&'static str>, Vec<&'static str>)>,
        completion_before_replace: Mutex<Option<Completion>>,
        publication_check: Callable<Arc<dyn Fn() + Send + Sync>>,
    }
    impl Values {
        fn new() -> Self {
            Self {
                scenes: Mutex::new(vec!["old"]),
                prepared: Mutex::new(None),
                rows: Mutex::new(vec![row("live", 5)]),
                preview: Mutex::new(vec!["document"]),
                actions: Observation::new(),
                publications: Observation::new(),
                retained: Observation::new(),
                completion_before_replace: Mutex::new(None),
                publication_check: Callable::new(),
            }
        }
    }
    impl ScenePort<&'static str, Row, (usize, &'static str)> for Values {
        fn rendered(&self) -> Vec<&'static str> {
            self.scenes.lock().unwrap().clone()
        }
        fn result(&self, index: usize, scene: &&'static str) -> (usize, &'static str) {
            self.actions.record(format!("result:{index}:{scene}"));
            (index, *scene)
        }
        fn retain_preview_memory(&self, before: &[&'static str], after: &[&'static str]) {
            self.actions.record("retain".into());
            self.retained.record((before.to_vec(), after.to_vec()));
        }
        fn replace_rendered(&self, scenes: Vec<&'static str>) {
            self.actions.record("replace".into());
            *self.scenes.lock().unwrap() = scenes;
            let completion = self.completion_before_replace.lock().unwrap().take();
            if let Some(completion) = completion {
                assert!(
                    !completion.wait(Duration::ZERO),
                    "completion preceded replacement"
                );
            }
        }
        fn prepared_refresh(&self) -> Option<Vec<Row>> {
            self.prepared.lock().unwrap().clone()
        }
        fn current_rows(&self) -> Vec<Row> {
            self.rows.lock().unwrap().clone()
        }
        fn publish_rows(&self, rows: Vec<Row>) {
            if let Some(check) = self.publication_check.capture() {
                check();
            }
            self.actions.record("publish".into());
            self.publications.record(rows.clone());
            *self.rows.lock().unwrap() = rows;
        }
        fn clear_preview_memory(&self) {
            self.actions.record("clear".into());
            self.preview.lock().unwrap().clear();
        }
        fn remove_live_assignment(&self, row: &mut Row) {
            self.actions.record(format!("remove:{}", row.label));
            row.handle = None;
            row.assignment = None;
            row.pointer = false;
        }
    }

    #[test]
    fn reconcile_starts_on_poll_records_before_hold_and_completes_after_replacement() {
        let port = Values::new();
        let calls = Observation::new();
        let control = Control::new();
        let failures = Failures::new();
        let hold = control.hold_next("admission");
        let completion = control.observe_next_completion("admission");
        *port.completion_before_replace.lock().unwrap() =
            Some(control.observe_next_completion("admission"));
        let mut operation = Box::pin(reconcile(
            vec!["new-b", "new-a"],
            &calls,
            &control,
            "admission",
            &failures,
            "failure",
            &port,
        ));
        assert!(calls.snapshot().is_empty());
        assert!(!hold.wait_entered(Duration::ZERO));
        assert!(poll_once(operation.as_mut()).is_pending());
        assert_eq!(calls.snapshot(), [vec!["new-b", "new-a"]]);
        assert!(hold.wait_entered(Duration::ZERO));
        assert_eq!(port.rendered(), ["old"]);
        assert!(port.actions.snapshot().is_empty());
        assert!(
            !control
                .observe_next_completion("admission")
                .wait(Duration::ZERO)
        );
        hold.release();
        assert_eq!(
            poll_once(operation.as_mut()),
            Poll::Ready(Ok(vec![(0, "new-b"), (1, "new-a")]))
        );
        assert!(completion.wait(Duration::ZERO));
        assert_eq!(port.rendered(), ["new-b", "new-a"]);
        assert_eq!(
            port.retained.snapshot(),
            [(vec!["old"], vec!["new-b", "new-a"])]
        );
        assert_eq!(
            port.actions.snapshot(),
            ["result:0:new-b", "result:1:new-a", "retain", "replace"]
        );
        assert!(port.publications.snapshot().is_empty());
    }

    #[test]
    fn reconcile_failure_is_checked_after_release_preserves_values_and_finishes() {
        let port = Values::new();
        let calls = Observation::new();
        let control = Control::new();
        let failures = Failures::new();
        let expected = fault(FaultCategory::Render, "reconcile exact failure");
        failures.set("failure", FailurePolicy::Persistent(expected.clone()));
        let hold = control.hold_next("admission");
        let mut operation = Box::pin(reconcile(
            vec!["rejected"],
            &calls,
            &control,
            "admission",
            &failures,
            "failure",
            &port,
        ));
        assert!(poll_once(operation.as_mut()).is_pending());
        // Replace the policy while held: only the post-release checkpoint may consume it.
        failures.set("failure", FailurePolicy::Next(expected.clone()));
        let completion = control.observe_next_completion("admission");
        hold.release();
        assert_eq!(poll_once(operation.as_mut()), Poll::Ready(Err(expected)));
        assert!(completion.wait(Duration::ZERO));
        assert_eq!(failures.check("failure"), Ok(()));
        assert_eq!(port.rendered(), ["old"]);
        assert_eq!(*port.preview.lock().unwrap(), ["document"]);
        assert!(port.actions.snapshot().is_empty());
        assert!(port.retained.snapshot().is_empty());
        assert!(port.publications.snapshot().is_empty());
        assert_eq!(calls.snapshot(), [vec!["rejected"]]);
    }

    #[test]
    fn refresh_publishes_before_failure_and_retains_the_prepared_reading() {
        let port = Values::new();
        let failures = Failures::new();
        let prepared = vec![row("prepared", 8)];
        *port.prepared.lock().unwrap() = Some(prepared.clone());
        let expected = fault(FaultCategory::Platform, "refresh failed after publish");
        failures.set("refresh", FailurePolicy::Next(expected.clone()));
        let checkpoint = failures.clone();
        let at_publication = expected.clone();
        port.publication_check.replace(Some(Arc::new(move || {
            assert_eq!(
                checkpoint.policies.lock().unwrap().get("refresh"),
                Some(&FailurePolicy::Next(at_publication.clone())),
                "refresh consumed its failure before publication"
            );
        })));
        assert_eq!(refresh(&failures, "refresh", &port), Err(expected));
        port.publication_check.replace(None);
        assert_eq!(port.current_rows(), prepared);
        assert_eq!(port.publications.snapshot(), [prepared.clone()]);
        assert_eq!(port.prepared_refresh(), Some(prepared.clone()));
        assert_eq!(refresh(&failures, "refresh", &port), Ok(()));
        assert_eq!(
            port.publications.snapshot(),
            [prepared.clone(), prepared.clone()]
        );
        *port.prepared.lock().unwrap() = None;
        assert_eq!(refresh(&failures, "refresh", &port), Ok(()));
        assert_eq!(port.current_rows(), prepared);
        assert_eq!(port.publications.snapshot().len(), 2);
    }

    #[test]
    fn close_checks_failure_first_then_clears_only_live_fields_and_preserves_histories() {
        let port = Values::new();
        let failures = Failures::new();
        let original = vec![
            row("live", 5),
            Row {
                label: "mirror",
                handle: Some(6),
                assignment: Some(Assignment::Mirror(5)),
                pointer: true,
                paused: false,
                window: true,
            },
        ];
        *port.rows.lock().unwrap() = original.clone();
        let expected = fault(FaultCategory::Platform, "close rejected");
        failures.set("close", FailurePolicy::Next(expected.clone()));
        assert_eq!(close(&failures, "close", &port), Err(expected));
        assert_eq!(port.current_rows(), original);
        assert_eq!(*port.preview.lock().unwrap(), ["document"]);
        assert!(port.actions.snapshot().is_empty());
        port.actions.record("unrelated history".into());
        assert_eq!(close(&failures, "close", &port), Ok(()));
        let expected: Vec<_> = original
            .into_iter()
            .map(|mut row| {
                row.handle = None;
                row.assignment = None;
                row.pointer = false;
                row
            })
            .collect();
        assert_eq!(port.current_rows(), expected);
        assert_eq!(port.publications.snapshot(), [expected]);
        assert!(port.preview.lock().unwrap().is_empty());
        assert_eq!(port.rendered(), ["old"]);
        assert_eq!(
            port.actions.snapshot(),
            [
                "unrelated history",
                "clear",
                "remove:live",
                "remove:mirror",
                "publish"
            ]
        );
    }

    #[test]
    fn generic_storage_does_not_require_send_clone_or_ordering_unnecessarily() {
        #[derive(PartialEq, Eq, Hash)]
        struct Key(u8);
        let control = Control::new();
        let hold = control.clone().hold_next(Key(1));
        hold.release();
        ready(control.enter(Key(1)).wait());
        let failures = Failures::new();
        failures.clone().set(
            Key(2),
            FailurePolicy::Next(fault(FaultCategory::Platform, "local")),
        );
        assert!(failures.check(Key(2)).is_err());
        use std::cell::Cell;
        use std::rc::Rc;
        type LocalCallback = Rc<dyn Fn()>;
        let slot = Callable::<LocalCallback>::new();
        let count = Rc::new(Cell::new(0));
        let retained = Rc::clone(&count);
        slot.clone()
            .replace(Some(Rc::new(move || retained.set(retained.get() + 1))));
        slot.capture().unwrap()();
        assert_eq!(count.get(), 1);
    }

    #[test]
    fn repeated_reconcile_failure_completes_each_attempt_without_consuming_persistence() {
        let port = Values::new();
        let calls = Observation::new();
        let control = Control::new();
        let failures = Failures::new();
        let expected = fault(FaultCategory::Render, "persistent operation failure");
        failures.set("failure", FailurePolicy::Persistent(expected.clone()));
        for _ in 0..2 {
            let completed = control.observe_next_completion("admission");
            assert_eq!(
                ready(reconcile(
                    vec!["rejected"],
                    &calls,
                    &control,
                    "admission",
                    &failures,
                    "failure",
                    &port
                )),
                Err(expected.clone())
            );
            assert!(completed.wait(Duration::ZERO));
        }
        assert_eq!(calls.snapshot(), [vec!["rejected"], vec!["rejected"]]);
        assert_eq!(port.rendered(), ["old"]);
        assert_eq!(*port.preview.lock().unwrap(), ["document"]);
        assert!(port.actions.snapshot().is_empty());
        assert_eq!(failures.check("failure"), Err(expected));
    }
}

#[cfg(test)]
mod timed_tests {
    use super::*;
    use futures_util::task::noop_waker;
    use std::task::Context;

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn bounded_mouse_release_times_out_without_completing_or_consuming_a_failure() {
        let control = Control::new();
        let failures = Failures::new();
        let expected = Fault {
            category: FaultCategory::Platform,
            message: "mouse release".into(),
        };
        failures.set("mouse", FailurePolicy::Next(expected.clone()));
        let hold = control.hold_next("mouse");
        let completion = control.observe_next_completion("mouse");
        let mut waiting = Box::pin(control.enter("mouse").wait_bounded(Duration::from_secs(2)));
        let waker = noop_waker();
        assert!(
            waiting
                .as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending()
        );
        assert!(hold.wait_entered(Duration::ZERO));
        tokio::time::advance(Duration::from_millis(1999)).await;
        assert!(
            waiting
                .as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending()
        );
        tokio::time::advance(Duration::from_millis(1)).await;
        assert_eq!(
            waiting.as_mut().poll(&mut Context::from_waker(&waker)),
            std::task::Poll::Ready(Err(ReleaseFailure::TimedOut)),
        );
        assert!(!completion.wait(Duration::ZERO));
        assert_eq!(failures.check("mouse"), Err(expected));
        hold.release();
        assert!(
            !control
                .observe_next_completion("mouse")
                .wait(Duration::ZERO)
        );
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn pending_bounded_release_succeeds_or_reports_only_actual_last_owner_loss() {
        let control = Control::new();
        let hold = control.hold_next(1);
        let mut waiting = Box::pin(control.enter(1).wait_bounded(Duration::from_secs(2)));
        let waker = noop_waker();
        assert!(
            waiting
                .as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending()
        );
        tokio::time::advance(Duration::from_secs(1)).await;
        hold.release();
        assert_eq!(waiting.await, Ok(()));
        let hold = control.hold_next(2);
        let other_owner = hold.clone();
        let mut waiting = Box::pin(control.enter(2).wait_bounded(Duration::from_secs(2)));
        assert!(
            waiting
                .as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending()
        );
        drop(hold);
        assert!(
            waiting
                .as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending()
        );
        drop(other_owner);
        assert_eq!(waiting.await, Err(ReleaseFailure::Disconnected));
        assert!(!control.observe_next_completion(2).wait(Duration::ZERO));
    }
}
