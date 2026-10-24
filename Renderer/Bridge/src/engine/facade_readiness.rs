use std::collections::HashSet;
use std::future::{Future, poll_fn};
use std::sync::{Arc, Mutex};
use std::task::Poll;
use std::time::Duration;

use tokio::sync::Notify;
use tokio::time::{Instant, sleep_until};
use wallpaper_core::project::{SceneHandle, SceneResult};
use wallpaper_core::{EngineError, FirstFrameCallback};

// Unknown targets require retaining every distinct event since the checkpoint.
// Once results are known, replace that storage with only outstanding targets.
enum WindowState {
    Collecting(HashSet<SceneHandle>),
    Outstanding(HashSet<SceneHandle>),
}

struct ObservationWindow {
    state: Mutex<WindowState>,
    arrivals: Notify,
}

struct SharedReadiness {
    windows: Mutex<Vec<Arc<ObservationWindow>>>,
}

#[derive(Clone)]
pub(crate) struct FirstFrameReadiness {
    shared: Arc<SharedReadiness>,
}

pub(crate) struct ReadinessCheckpoint {
    shared: Arc<SharedReadiness>,
    window: Arc<ObservationWindow>,
}

impl ReadinessCheckpoint {
    fn track_targets(&self, changed_displays: &[u32], results: &[SceneResult]) {
        let mut state = self.window.state.lock().unwrap();
        let seen = match &*state {
            WindowState::Collecting(seen) => seen,
            WindowState::Outstanding(_) => unreachable!("checkpoint is consumed by one wait"),
        };
        let remaining = results
            .iter()
            .filter(|result| changed_displays.contains(&result.display_id))
            .filter(|result| !seen.contains(&result.handle))
            .map(|result| result.handle)
            .collect();
        // A fresh set drops all early-event storage, including its capacity.
        // Callbacks use this same lock, so no event is lost at the transition.
        *state = WindowState::Outstanding(remaining);
    }

    fn complete(&self) -> bool {
        let state = self.window.state.lock().unwrap();
        matches!(&*state, WindowState::Outstanding(remaining) if remaining.is_empty())
    }
}

impl Drop for ReadinessCheckpoint {
    fn drop(&mut self) {
        let mut windows = self.shared.windows.lock().unwrap();
        if let Some(index) = windows
            .iter()
            .position(|window| Arc::ptr_eq(window, &self.window))
        {
            windows.swap_remove(index);
        }
    }
}

impl FirstFrameReadiness {
    pub(crate) fn new() -> Self {
        Self {
            shared: Arc::new(SharedReadiness {
                windows: Mutex::new(Vec::new()),
            }),
        }
    }

    pub(crate) fn checkpoint(&self) -> ReadinessCheckpoint {
        let window = Arc::new(ObservationWindow {
            state: Mutex::new(WindowState::Collecting(HashSet::new())),
            arrivals: Notify::new(),
        });
        self.shared.windows.lock().unwrap().push(window.clone());
        ReadinessCheckpoint {
            shared: self.shared.clone(),
            window,
        }
    }

    pub(crate) fn wrap_callback(&self, downstream: FirstFrameCallback) -> FirstFrameCallback {
        let shared = self.shared.clone();
        Arc::new(move |handle| {
            let (first_progress, additional_progress) = {
                let windows = shared.windows.lock().unwrap();
                let mut first_progress = None;
                let mut additional_progress = Vec::new();
                for window in windows.iter() {
                    let progressed = {
                        let mut state = window.state.lock().unwrap();
                        match &mut *state {
                            WindowState::Collecting(seen) => {
                                seen.insert(handle);
                                false // No wait is registered before targets exist.
                            }
                            WindowState::Outstanding(remaining) => remaining.remove(&handle),
                        }
                    };
                    if progressed {
                        // The normal single-wait path needs no notification list allocation.
                        if first_progress.is_none() {
                            first_progress = Some(window.clone());
                        } else {
                            additional_progress.push(window.clone());
                        }
                    }
                }
                (first_progress, additional_progress)
            };
            // Both wakers and the downstream sink run outside readiness locks.
            // Only the windows whose outstanding target sets shrank are notified.
            if let Some(window) = first_progress {
                window.arrivals.notify_waiters();
            }
            for window in additional_progress {
                window.arrivals.notify_waiters();
            }
            downstream(handle);
        })
    }

    pub(crate) async fn await_results(
        &self,
        checkpoint: ReadinessCheckpoint,
        changed_displays: &[u32],
        results: Vec<SceneResult>,
        timeout_error: fn() -> EngineError,
    ) -> Result<Vec<SceneResult>, EngineError> {
        // This async body first executes only after the parent's successful
        // core-and-prune boundary. Callback arrivals never change this instant.
        let entered_at = Instant::now();
        checkpoint.track_targets(changed_displays, &results);
        if checkpoint.complete() {
            return Ok(results);
        }

        let mut arrival = std::pin::pin!(checkpoint.window.arrivals.notified());
        // Register before rechecking progress. A callback during registration
        // removes its target permanently even if no notification was registered.
        arrival.as_mut().enable();
        if checkpoint.complete() {
            return Ok(results);
        }

        // Empty/already-satisfied waits never construct a timer. All remaining
        // targets share this one immutable deadline, not one timer per handle.
        let mut deadline = std::pin::pin!(sleep_until(entered_at + Duration::from_secs(90)));
        loop {
            let expired = poll_fn(|cx| {
                let arrived = arrival.as_mut().poll(cx).is_ready();
                let expired = deadline.as_mut().poll(cx).is_ready();
                if arrived || expired {
                    Poll::Ready(expired)
                } else {
                    Poll::Pending
                }
            })
            .await;

            if !expired {
                arrival.set(checkpoint.window.arrivals.notified());
                arrival.as_mut().enable();
            }
            // Evidence wins even if the executor first resumes after expiry.
            // Rearming before this check also closes the next pending transition.
            if checkpoint.complete() {
                return Ok(results);
            }
            if expired {
                return Err(timeout_error());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::{Context, Wake, Waker};

    #[derive(Default)]
    struct WakeCounter(AtomicUsize);

    impl Wake for WakeCounter {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }

        fn wake_by_ref(self: &Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn counting_waker() -> (Arc<WakeCounter>, Waker) {
        let counter = Arc::new(WakeCounter::default());
        let waker = Waker::from(counter.clone());
        (counter, waker)
    }

    fn poll_once<F: Future + ?Sized>(future: Pin<&mut F>, waker: &Waker) -> Poll<F::Output> {
        future.poll(&mut Context::from_waker(waker))
    }

    fn result(display: u32, raw_handle: u64, status: i32) -> SceneResult {
        SceneResult::new(display, SceneHandle::new(raw_handle), status)
    }

    fn unexpected_timeout() -> EngineError {
        panic!("a successful readiness wait invoked the timeout factory")
    }

    fn success(poll: Poll<Result<Vec<SceneResult>, EngineError>>) -> Vec<SceneResult> {
        match poll {
            Poll::Ready(Ok(results)) => results,
            other => panic!("expected successful readiness, received {other:?}"),
        }
    }

    fn render_error(poll: Poll<Result<Vec<SceneResult>, EngineError>>, expected: &str) {
        match poll {
            Poll::Ready(Err(EngineError::Render(message))) => assert_eq!(message, expected),
            other => panic!("expected the Render timeout sentinel, received {other:?}"),
        }
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr01_empty_and_untargeted_results_return_the_original_vector() {
        let readiness = FirstFrameReadiness::new();
        let (counter, waker) = counting_waker();
        let changed = [404];
        let mut empty = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            Vec::new(),
            unexpected_timeout,
        ));
        assert!(success(poll_once(empty.as_mut(), &waker)).is_empty());

        let expected = [
            result(31, 701, -7),
            result(9, 702, 41),
            result(31, 703, i32::MIN),
        ];
        let input = expected.to_vec();
        let allocation = input.as_ptr();
        let capacity = input.capacity();
        let mut absent_display = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            input,
            unexpected_timeout,
        ));
        let actual = success(poll_once(absent_display.as_mut(), &waker));
        assert_eq!(actual, expected);
        assert_eq!(actual.as_ptr(), allocation);
        assert_eq!(actual.capacity(), capacity);

        let no_changes = [];
        let mut unchanged = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &no_changes,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert_eq!(success(poll_once(unchanged.as_mut(), &waker)), expected);
        tokio::time::advance(Duration::from_secs(200)).await;
        assert_eq!(counter.0.load(Ordering::SeqCst), 0);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr02_precheckpoint_events_do_not_count_across_observer_clones() {
        let readiness = FirstFrameReadiness::new();
        let checkpoint_clone = readiness.clone();
        let callback_clone = readiness.clone();
        let callback = callback_clone.wrap_callback(Arc::new(|_| {}));
        let changed = [12];
        let expected = [result(12, 810, -24)];
        let (_, waker) = counting_waker();

        for owner in [&readiness, &checkpoint_clone] {
            callback(expected[0].handle);
            let checkpoint = owner.checkpoint();
            let mut wait = Box::pin(readiness.await_results(
                checkpoint,
                &changed,
                expected.to_vec(),
                unexpected_timeout,
            ));
            assert!(poll_once(wait.as_mut(), &waker).is_pending());
            callback(expected[0].handle);
            assert_eq!(success(poll_once(wait.as_mut(), &waker)), expected);
        }
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr03_evidence_survives_before_wait_and_controlled_upstream_phases() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [14, 15];
        let (_, waker) = counting_waker();
        let checkpoint = readiness.checkpoint();
        let first = result(14, 901, -36);
        callback(first.handle);
        let mut immediate = Box::pin(readiness.await_results(
            checkpoint,
            &changed,
            vec![first],
            unexpected_timeout,
        ));
        assert_eq!(success(poll_once(immediate.as_mut(), &waker)), vec![first]);

        // These gates model unfinished upstream phases only. They are not an
        // engine, a prune implementation, or an orchestration substitute.
        let checkpoint = readiness.checkpoint();
        let (finish_preparation, preparation) = tokio::sync::oneshot::channel::<()>();
        let (finish_pruning, pruning) = tokio::sync::oneshot::channel::<()>();
        let mut upstream_phases = Box::pin(async move {
            preparation.await.unwrap();
            pruning.await.unwrap();
        });
        let expected = [result(14, 902, -37), result(15, 903, 66)];
        assert!(poll_once(upstream_phases.as_mut(), &waker).is_pending());
        callback(expected[0].handle);
        assert!(poll_once(upstream_phases.as_mut(), &waker).is_pending());
        finish_preparation.send(()).unwrap();
        assert!(poll_once(upstream_phases.as_mut(), &waker).is_pending());
        callback(expected[1].handle);
        tokio::time::advance(Duration::from_secs(250)).await;
        assert!(poll_once(upstream_phases.as_mut(), &waker).is_pending());
        finish_pruning.send(()).unwrap();
        assert!(poll_once(upstream_phases.as_mut(), &waker).is_ready());
        let mut wait = Box::pin(readiness.await_results(
            checkpoint,
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert_eq!(success(poll_once(wait.as_mut(), &waker)), expected);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr04_handles_not_callback_counts_select_mixed_and_duplicate_results() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [41, 42];
        let expected = [
            result(41, 1001, -17),
            result(43, 1003, -33),
            result(41, 1001, 39),
            result(42, 1002, i32::MAX),
        ];
        let (_, waker) = counting_waker();
        let mut wait = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        for _ in 0..3 {
            callback(expected[0].handle);
        }
        callback(SceneHandle::new(1999));
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        callback(expected[3].handle);
        assert_eq!(success(poll_once(wait.as_mut(), &waker)), expected);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn known_targets_discard_early_capacity_and_ignore_unrelated_arrivals() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let checkpoint = readiness.checkpoint();
        let window = checkpoint.window.clone();
        let changed = [151, 152];
        let expected = [
            result(151, 2101, -163),
            result(152, 2102, 163),
            result(152, 2102, -164),
        ];
        // Before results exist, every distinct post-checkpoint event is needed
        // as potential early evidence; there is deliberately no eviction cap.
        for raw in 30_000..34_096 {
            callback(SceneHandle::new(raw));
        }
        callback(expected[0].handle);
        let early_capacity = match &*window.state.lock().unwrap() {
            WindowState::Collecting(seen) => {
                assert_eq!(seen.len(), 4097);
                seen.capacity()
            }
            WindowState::Outstanding(_) => panic!("targets are not known yet"),
        };
        let input = expected.to_vec();
        let allocation = input.as_ptr();
        let capacity = input.capacity();
        let (counter, waker) = counting_waker();
        let mut wait =
            Box::pin(readiness.await_results(checkpoint, &changed, input, unexpected_timeout));
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        let remaining_capacity = match &*window.state.lock().unwrap() {
            WindowState::Outstanding(remaining) => {
                assert_eq!(remaining.len(), 1);
                assert!(remaining.contains(&expected[1].handle));
                assert!(remaining.capacity() < early_capacity);
                remaining.capacity()
            }
            WindowState::Collecting(_) => panic!("wait did not fix its targets"),
        };
        // An overlapping, still-collecting checkpoint must not cause unrelated
        // events to wake this fixed-target wait through a shared notification.
        let collecting = readiness.checkpoint();
        let wakes_before = counter.0.load(Ordering::SeqCst);
        for raw in 50_000..58_192 {
            callback(SceneHandle::new(raw));
            callback(expected[0].handle);
        }
        assert_eq!(counter.0.load(Ordering::SeqCst), wakes_before);
        match &*window.state.lock().unwrap() {
            WindowState::Outstanding(remaining) => {
                assert_eq!(remaining.len(), 1);
                assert!(remaining.contains(&expected[1].handle));
                assert_eq!(remaining.capacity(), remaining_capacity);
            }
            WindowState::Collecting(_) => panic!("callback reopened evidence collection"),
        }
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        callback(expected[1].handle);
        let target_wakes = counter.0.load(Ordering::SeqCst);
        assert!(target_wakes > wakes_before);
        callback(expected[1].handle);
        assert_eq!(counter.0.load(Ordering::SeqCst), target_wakes);
        let actual = success(poll_once(wait.as_mut(), &waker));
        assert_eq!(actual, expected);
        assert_eq!(actual.as_ptr(), allocation);
        assert_eq!(actual.capacity(), capacity);
        drop(collecting);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr05_all_targets_share_one_ninety_second_deadline() {
        static FACTORY_CALLS: AtomicUsize = AtomicUsize::new(0);
        fn timeout() -> EngineError {
            FACTORY_CALLS.fetch_add(1, Ordering::SeqCst);
            EngineError::Render("shared-deadline-sentinel".into())
        }

        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [51, 52];
        let expected = [result(51, 1101, -41), result(52, 1102, 19)];
        let (_, waker) = counting_waker();
        let mut wait = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            timeout,
        ));
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(89)).await;
        callback(expected[0].handle);
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 0);
        tokio::time::advance(Duration::from_secs(1)).await;
        render_error(poll_once(wait.as_mut(), &waker), "shared-deadline-sentinel");
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 1);
        drop(wait);

        let mut successful = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            timeout,
        ));
        assert!(poll_once(successful.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(44)).await;
        callback(expected[0].handle);
        assert!(poll_once(successful.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(45)).await;
        callback(expected[1].handle);
        assert_eq!(success(poll_once(successful.as_mut(), &waker)), expected);
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr06_grace_begins_on_first_execution_not_future_construction() {
        fn timeout() -> EngineError {
            EngineError::Render("entry-time-sentinel".into())
        }

        let readiness = FirstFrameReadiness::new();
        let changed = [61];
        let (_, waker) = counting_waker();
        let checkpoint = readiness.checkpoint();
        let mut wait = Box::pin(readiness.await_results(
            checkpoint,
            &changed,
            vec![result(61, 1201, -53)],
            timeout,
        ));
        tokio::time::advance(Duration::from_secs(600)).await;
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(89)).await;
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(1)).await;
        render_error(poll_once(wait.as_mut(), &waker), "entry-time-sentinel");
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr07_ready_evidence_wins_expiry_but_late_events_do_not_rewrite_errors() {
        static FACTORY_CALLS: AtomicUsize = AtomicUsize::new(0);
        fn timeout() -> EngineError {
            FACTORY_CALLS.fetch_add(1, Ordering::SeqCst);
            EngineError::Render("expiry-decision-sentinel".into())
        }

        let readiness = FirstFrameReadiness::new();
        let forwarded = Arc::new(Mutex::new(Vec::new()));
        let sink = forwarded.clone();
        let callback = readiness.wrap_callback(Arc::new(move |handle| {
            sink.lock().unwrap().push(handle);
        }));
        let changed = [71];
        let first = result(71, 1301, -65);
        let (_, waker) = counting_waker();
        let mut ready_at_expiry = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![first],
            timeout,
        ));
        assert!(poll_once(ready_at_expiry.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(95)).await;
        callback(first.handle);
        assert_eq!(
            success(poll_once(ready_at_expiry.as_mut(), &waker)),
            vec![first]
        );
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 0);

        let second = result(71, 1302, 88);
        let mut absent_at_expiry = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![second],
            timeout,
        ));
        assert!(poll_once(absent_at_expiry.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(90)).await;
        let returned_error = match poll_once(absent_at_expiry.as_mut(), &waker) {
            Poll::Ready(Err(error)) => error,
            other => panic!("missing evidence must return an error, received {other:?}"),
        };
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 1);
        callback(second.handle);
        assert_eq!(
            *forwarded.lock().unwrap(),
            vec![first.handle, second.handle]
        );
        match returned_error {
            EngineError::Render(message) => assert_eq!(message, "expiry-decision-sentinel"),
            other => panic!("late delivery changed the error category: {other:?}"),
        }
        assert_eq!(FACTORY_CALLS.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr08_arrivals_before_poll_and_after_pending_are_never_lost() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [81];
        let expected = [result(81, 1401, -77)];
        let (counter, waker) = counting_waker();
        let checkpoint = readiness.checkpoint();
        callback(expected[0].handle);
        let mut before_poll = Box::pin(readiness.await_results(
            checkpoint,
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert_eq!(success(poll_once(before_poll.as_mut(), &waker)), expected);

        let mut after_pending = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert!(poll_once(after_pending.as_mut(), &waker).is_pending());
        let wakes_before = counter.0.load(Ordering::SeqCst);
        callback(expected[0].handle);
        assert!(counter.0.load(Ordering::SeqCst) > wakes_before);
        assert_eq!(success(poll_once(after_pending.as_mut(), &waker)), expected);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr09_independent_waiters_broadcast_evidence_and_cancel_independently() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [91];
        let expected = [result(91, 1501, -89)];
        let (first_counter, first_waker) = counting_waker();
        let (second_counter, second_waker) = counting_waker();
        let mut first = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        let mut second = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert!(poll_once(first.as_mut(), &first_waker).is_pending());
        assert!(poll_once(second.as_mut(), &second_waker).is_pending());
        callback(SceneHandle::new(1599));
        assert!(poll_once(first.as_mut(), &first_waker).is_pending());
        assert!(poll_once(second.as_mut(), &second_waker).is_pending());
        let first_wakes = first_counter.0.load(Ordering::SeqCst);
        let second_wakes = second_counter.0.load(Ordering::SeqCst);
        callback(expected[0].handle);
        assert!(first_counter.0.load(Ordering::SeqCst) > first_wakes);
        assert!(second_counter.0.load(Ordering::SeqCst) > second_wakes);
        assert_eq!(success(poll_once(first.as_mut(), &first_waker)), expected);
        assert_eq!(success(poll_once(second.as_mut(), &second_waker)), expected);

        let mut canceled = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        let mut survivor = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            expected.to_vec(),
            unexpected_timeout,
        ));
        assert!(poll_once(canceled.as_mut(), &first_waker).is_pending());
        assert!(poll_once(survivor.as_mut(), &second_waker).is_pending());
        drop(canceled);
        let canceled_wakes = first_counter.0.load(Ordering::SeqCst);
        callback(expected[0].handle);
        assert_eq!(first_counter.0.load(Ordering::SeqCst), canceled_wakes);
        assert_eq!(
            success(poll_once(survivor.as_mut(), &second_waker)),
            expected
        );
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr10_later_checkpoints_require_new_events_without_erasing_earlier_evidence() {
        let readiness = FirstFrameReadiness::new();
        let callback = readiness.wrap_callback(Arc::new(|_| {}));
        let changed = [101, 102];
        let h = result(101, 1601, -101);
        let j = result(102, 1602, 101);
        let (_, waker) = counting_waker();
        let mut completed = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![h],
            unexpected_timeout,
        ));
        assert!(poll_once(completed.as_mut(), &waker).is_pending());
        callback(h.handle);
        assert_eq!(success(poll_once(completed.as_mut(), &waker)), vec![h]);

        let mut earlier = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![h, j],
            unexpected_timeout,
        ));
        assert!(poll_once(earlier.as_mut(), &waker).is_pending());
        callback(h.handle);
        assert!(poll_once(earlier.as_mut(), &waker).is_pending());
        let mut later = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![h],
            unexpected_timeout,
        ));
        assert!(poll_once(later.as_mut(), &waker).is_pending());
        callback(j.handle);
        assert_eq!(success(poll_once(earlier.as_mut(), &waker)), vec![h, j]);
        assert!(poll_once(later.as_mut(), &waker).is_pending());
        callback(h.handle);
        assert_eq!(success(poll_once(later.as_mut(), &waker)), vec![h]);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr11_forwarding_is_exact_and_downstream_reentry_sees_recorded_readiness() {
        fn timeout() -> EngineError {
            EngineError::Render("late-forward-sentinel".into())
        }

        let readiness = FirstFrameReadiness::new();
        let forwarded = Arc::new(Mutex::new(Vec::new()));
        let reentrant_checkpoints = Arc::new(Mutex::new(Vec::new()));
        let sink = forwarded.clone();
        let checkpoints = reentrant_checkpoints.clone();
        let reentrant = readiness.clone();
        let callback = readiness.wrap_callback(Arc::new(move |handle| {
            sink.lock().unwrap().push(handle);
            checkpoints.lock().unwrap().push(reentrant.checkpoint());
            // Creating another wrapper is also safe during downstream reentry.
            let _uninstalled = reentrant.wrap_callback(Arc::new(|_| {}));
        }));
        let changed = [111];
        let h = result(111, 1701, -113);
        let before = readiness.checkpoint();
        callback(h.handle);
        let during_downstream = reentrant_checkpoints.lock().unwrap().remove(0);
        let (_, waker) = counting_waker();
        let mut earlier =
            Box::pin(readiness.await_results(before, &changed, vec![h], unexpected_timeout));
        assert_eq!(success(poll_once(earlier.as_mut(), &waker)), vec![h]);
        let mut reentrant_wait = Box::pin(readiness.await_results(
            during_downstream,
            &changed,
            vec![h],
            unexpected_timeout,
        ));
        assert!(poll_once(reentrant_wait.as_mut(), &waker).is_pending());
        callback(h.handle);
        assert_eq!(success(poll_once(reentrant_wait.as_mut(), &waker)), vec![h]);
        let untracked = SceneHandle::new(1799);
        callback(untracked);
        callback(untracked);

        let late = result(111, 1702, 113);
        let mut expiring = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![late],
            timeout,
        ));
        assert!(poll_once(expiring.as_mut(), &waker).is_pending());
        tokio::time::advance(Duration::from_secs(90)).await;
        render_error(
            poll_once(expiring.as_mut(), &waker),
            "late-forward-sentinel",
        );
        callback(late.handle);
        assert_eq!(
            *forwarded.lock().unwrap(),
            vec![h.handle, h.handle, untracked, untracked, late.handle],
        );
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr12_replacement_wrappers_share_lineage_without_replay_or_retargeting() {
        let readiness = FirstFrameReadiness::new();
        let old_events = Arc::new(Mutex::new(Vec::new()));
        let new_events = Arc::new(Mutex::new(Vec::new()));
        let old_sink = old_events.clone();
        let old = readiness.wrap_callback(Arc::new(move |handle| {
            old_sink.lock().unwrap().push(handle);
        }));
        let changed = [121, 122];
        let h = result(121, 1801, -127);
        let j = result(122, 1802, 127);
        let (_, waker) = counting_waker();
        let mut outstanding = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![h, j],
            unexpected_timeout,
        ));
        assert!(old_events.lock().unwrap().is_empty());
        assert!(poll_once(outstanding.as_mut(), &waker).is_pending());
        old(h.handle);
        assert!(poll_once(outstanding.as_mut(), &waker).is_pending());

        let replacement_owner = readiness.clone();
        let new_sink = new_events.clone();
        let new = replacement_owner.wrap_callback(Arc::new(move |handle| {
            new_sink.lock().unwrap().push(handle);
        }));
        assert_eq!(*old_events.lock().unwrap(), vec![h.handle]);
        assert!(new_events.lock().unwrap().is_empty());
        assert!(poll_once(outstanding.as_mut(), &waker).is_pending());
        // This invocation models a newly selected dispatch, not slot installation.
        new(j.handle);
        assert_eq!(success(poll_once(outstanding.as_mut(), &waker)), vec![h, j]);
        assert_eq!(*old_events.lock().unwrap(), vec![h.handle]);
        assert_eq!(*new_events.lock().unwrap(), vec![j.handle]);

        let retained_old_result = result(121, 1803, -128);
        let mut retained_old_wait = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![retained_old_result],
            unexpected_timeout,
        ));
        assert!(poll_once(retained_old_wait.as_mut(), &waker).is_pending());
        old(retained_old_result.handle);
        assert_eq!(
            success(poll_once(retained_old_wait.as_mut(), &waker)),
            vec![retained_old_result],
        );
        assert_eq!(
            *old_events.lock().unwrap(),
            vec![h.handle, retained_old_result.handle]
        );
        assert_eq!(*new_events.lock().unwrap(), vec![j.handle]);
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr13_wrapper_and_canceled_wait_release_only_their_owned_resources() {
        fn observer_traits<T: Clone + Send + Sync + 'static>() {}
        fn checkpoint_traits<T: Send + 'static>() {}
        fn future_is_send<F: Future + Send>(_: &F) {}
        observer_traits::<FirstFrameReadiness>();
        checkpoint_traits::<ReadinessCheckpoint>();

        let downstream_owner = Arc::new(());
        let downstream_weak = Arc::downgrade(&downstream_owner);
        let calls = Arc::new(AtomicUsize::new(0));
        let recorded_calls = calls.clone();
        let readiness = FirstFrameReadiness::new();
        let clone = readiness.clone();
        let wrapper = readiness.wrap_callback(Arc::new(move |_| {
            let _keep_alive = &downstream_owner;
            recorded_calls.fetch_add(1, Ordering::SeqCst);
        }));
        drop(readiness);
        drop(clone);
        assert!(downstream_weak.upgrade().is_some());
        wrapper(SceneHandle::new(1901));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        drop(wrapper);
        assert!(downstream_weak.upgrade().is_none());

        let readiness = FirstFrameReadiness::new();
        let unused_sink_owner = Arc::new(());
        let unused_sink_weak = Arc::downgrade(&unused_sink_owner);
        let unused_wrapper = readiness.wrap_callback(Arc::new(move |_| {
            let _keep_alive = &unused_sink_owner;
        }));
        let changed = [131];
        let mut wait = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![result(131, 1902, -139)],
            unexpected_timeout,
        ));
        future_is_send(&wait);
        let wake_owner = Arc::new(WakeCounter::default());
        let wake_weak = Arc::downgrade(&wake_owner);
        let waker = Waker::from(wake_owner.clone());
        assert!(poll_once(wait.as_mut(), &waker).is_pending());
        drop(waker);
        drop(wake_owner);
        assert!(wake_weak.upgrade().is_some());
        drop(wait);
        assert!(wake_weak.upgrade().is_none());
        assert!(unused_sink_weak.upgrade().is_some());
        drop(unused_wrapper);
        assert!(unused_sink_weak.upgrade().is_none());
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn fr14_idle_and_canceled_observers_have_no_periodic_activity() {
        let readiness = FirstFrameReadiness::new();
        let forwards = Arc::new(AtomicUsize::new(0));
        let sink_forwards = forwards.clone();
        let callback = readiness.wrap_callback(Arc::new(move |_| {
            sink_forwards.fetch_add(1, Ordering::SeqCst);
        }));
        let (counter, waker) = counting_waker();
        tokio::time::advance(Duration::from_secs(1000)).await;
        assert_eq!(forwards.load(Ordering::SeqCst), 0);
        assert_eq!(counter.0.load(Ordering::SeqCst), 0);

        let changed = [141];
        let mut canceled = Box::pin(readiness.await_results(
            readiness.checkpoint(),
            &changed,
            vec![result(141, 2001, -151)],
            unexpected_timeout,
        ));
        assert!(poll_once(canceled.as_mut(), &waker).is_pending());
        drop(canceled);
        let wakes_after_cancel = counter.0.load(Ordering::SeqCst);
        tokio::time::advance(Duration::from_secs(1000)).await;
        assert_eq!(counter.0.load(Ordering::SeqCst), wakes_after_cancel);
        assert_eq!(forwards.load(Ordering::SeqCst), 0);
        callback(SceneHandle::new(2001));
        assert_eq!(forwards.load(Ordering::SeqCst), 1);
        assert_eq!(counter.0.load(Ordering::SeqCst), wakes_after_cancel);
    }
}
