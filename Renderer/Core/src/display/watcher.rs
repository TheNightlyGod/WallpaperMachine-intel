// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
#![allow(clippy::single_call_fn)]

use std::ffi::c_void;
use std::ptr;
use std::sync::{
    Arc, Mutex, OnceLock, PoisonError, Weak,
    atomic::{AtomicBool, Ordering},
};

use arc_swap::ArcSwap;

use async_channel::{Receiver, Sender};
use objc2_core_graphics::{
    CGDisplayChangeSummaryFlags, CGDisplayRegisterReconfigurationCallback, CGError,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisplayEvent {
    Connected(u32),
    Disconnected(u32),
    ModeChanged(u32),
    PrimaryChanged(u32),
    MirrorChanged(u32),
    Other(u32, CGDisplayChangeSummaryFlags),
}

/// Initialized by subscribers, never by the callback: get() cannot wait for
/// initialization, and before it succeeds there cannot be a live subscriber.
static SUBSCRIBERS: OnceLock<Arc<Subscribers>> = OnceLock::new();

/// Only registration/removal takes writer. Callback readers borrow an immutable
/// snapshot, with no registry lock and no subscriber-table allocation.
struct Subscribers {
    writer: Mutex<()>,
    live: ArcSwap<Vec<Arc<Sender<DisplayEvent>>>>,
}

impl Subscribers {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            writer: Mutex::new(()),
            live: ArcSwap::from_pointee(Vec::new()),
        })
    }

    fn subscribe(self: &Arc<Self>) -> QueueHandle {
        let (sender, events) = async_channel::unbounded();
        let sender = Arc::new(sender);
        let subscription = Arc::new(Subscription {
            registry: Arc::downgrade(self),
            sender: Arc::clone(&sender),
            removed: AtomicBool::new(false),
        });
        let _writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        let mut next = (**self.live.load()).clone();
        next.push(sender);
        // Subscription linearizes here; no event loaded from an earlier
        // snapshot is replayed, and every later snapshot includes this queue.
        self.live.store(Arc::new(next));
        QueueHandle {
            events,
            subscription,
        }
    }

    fn remove(&self, sender: &Arc<Sender<DisplayEvent>>) {
        let _writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        let next = self
            .live
            .load()
            .iter()
            .filter(|entry| !Arc::ptr_eq(entry, sender))
            .cloned()
            .collect();
        self.live.store(Arc::new(next));
    }

    fn publish(&self, event: &DisplayEvent) {
        // This short-lived reader guard cannot retain historical snapshots
        // beyond this fanout. Only channel event storage is allocated here.
        let subscribers = self.live.load();
        for subscriber in subscribers.iter() {
            let _ = subscriber.try_send(event.clone());
        }
    }

    #[cfg(test)]
    fn subscriber_count(&self) -> usize {
        self.live.load().len()
    }
}

/// Snapshots contain senders, NOT these tokens: the callback can never become
/// the last owner of a token and run writer-side removal on its own thread.
struct Subscription {
    registry: Weak<Subscribers>,
    sender: Arc<Sender<DisplayEvent>>,
    removed: AtomicBool,
}

impl Subscription {
    fn remove(&self) {
        if !self.removed.swap(true, Ordering::AcqRel)
            && let Some(registry) = self.registry.upgrade()
        {
            registry.remove(&self.sender);
        }
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        self.remove();
    }
}

/// Every receiver clone carries the same lifetime token. Raw receiver handles
/// never escape, so closing a queue or dropping its last handle removes its
/// sender promptly, even if no further display event ever arrives.
#[derive(Clone)]
pub(crate) struct QueueHandle {
    events: Receiver<DisplayEvent>,
    subscription: Arc<Subscription>,
}

impl QueueHandle {
    pub(crate) fn close(&self) -> bool {
        let closed = self.events.close();
        self.subscription.remove();
        closed
    }

    fn recv_blocking(&self) -> Result<DisplayEvent, async_channel::RecvError> {
        self.events.recv_blocking()
    }

    async fn recv(&self) -> Result<DisplayEvent, async_channel::RecvError> {
        self.events.recv().await
    }

    #[cfg(test)]
    fn try_recv(&self) -> Result<DisplayEvent, async_channel::TryRecvError> {
        self.events.try_recv()
    }
}

/// A subscription to the process-wide stream of display reconfiguration
/// events.
pub struct DisplayWatcher {
    events: QueueHandle,
}

/// Turns the flags of one reconfiguration report into an event. The first
/// matching rule wins; a report that only begins a configuration is no event.
fn classify(display: u32, flags: CGDisplayChangeSummaryFlags) -> Option<DisplayEvent> {
    let has = |flag: CGDisplayChangeSummaryFlags| flags.contains(flag);
    if has(CGDisplayChangeSummaryFlags::AddFlag) {
        Some(DisplayEvent::Connected(display))
    } else if has(CGDisplayChangeSummaryFlags::RemoveFlag) {
        Some(DisplayEvent::Disconnected(display))
    } else if has(CGDisplayChangeSummaryFlags::MovedFlag)
        || has(CGDisplayChangeSummaryFlags::SetMainFlag)
    {
        Some(DisplayEvent::PrimaryChanged(display))
    } else if has(CGDisplayChangeSummaryFlags::DesktopShapeChangedFlag)
        || has(CGDisplayChangeSummaryFlags::SetModeFlag)
    {
        Some(DisplayEvent::ModeChanged(display))
    } else if has(CGDisplayChangeSummaryFlags::MirrorFlag)
        || has(CGDisplayChangeSummaryFlags::UnMirrorFlag)
    {
        Some(DisplayEvent::MirrorChanged(display))
    } else if has(CGDisplayChangeSummaryFlags::BeginConfigurationFlag) {
        None
    } else {
        Some(DisplayEvent::Other(display, flags))
    }
}

/// Delivers `event` to the live snapshot. Closed queues are ignored; their
/// owning handles remove them on the writer side, never from this callback.
fn publish(event: &DisplayEvent) {
    if let Some(subscribers) = SUBSCRIBERS.get() {
        subscribers.publish(event);
    }
}

/// The system's reconfiguration callback; it runs on a thread the system
/// owns and must stay non-blocking.
unsafe extern "C-unwind" fn reconfiguration_callback(
    display: u32,
    flags: CGDisplayChangeSummaryFlags,
    _user_info: *mut c_void,
) {
    if let Some(event) = classify(display, flags) {
        publish(&event);
    }
}

impl DisplayWatcher {
    /// Registers the system callback. Call it on the main thread, at most
    /// once per process.
    pub fn setup() {
        // SAFETY: the callback is a plain function and takes no user data.
        let status = unsafe {
            CGDisplayRegisterReconfigurationCallback(
                Some(reconfiguration_callback),
                ptr::null_mut(),
            )
        };
        if status != CGError::Success {
            log::warn!(
                "[wallpaper-core display] registering the display callback failed: CoreGraphics error {}",
                status.0
            );
        }
    }

    pub fn new() -> Self {
        Self {
            events: SUBSCRIBERS.get_or_init(Subscribers::new).subscribe(),
        }
    }

    /// A second handle on this watcher's queue, so its owner can close the
    /// queue and wake a thread parked in [`Self::next_event`].
    pub(crate) fn queue_handle(&self) -> QueueHandle {
        self.events.clone()
    }

    /// Blocks for the next event; `None` once the queue is closed.
    #[must_use]
    pub fn next_event(&self) -> Option<DisplayEvent> {
        self.events.recv_blocking().ok()
    }

    pub async fn recv(&self) -> Option<DisplayEvent> {
        self.events.recv().await.ok()
    }
}

impl Default for DisplayWatcher {
    fn default() -> Self {
        Self::new()
    }
}

/// Test seam: pushes a forged event to every subscriber, as the system
/// callback would.
#[cfg(test)]
pub(crate) fn inject_for_tests(event: &DisplayEvent) {
    publish(event);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Skips events other tests injected into the shared registry.
    fn wait_for(watcher: &DisplayWatcher, wanted: &DisplayEvent) -> bool {
        std::iter::from_fn(|| watcher.next_event()).any(|event| event == *wanted)
    }

    #[test]
    fn the_watcher_types_are_exported_from_the_crate_root() {
        let _constructor: fn() -> crate::DisplayWatcher = crate::DisplayWatcher::new;
        let event: crate::DisplayEvent = crate::DisplayEvent::Connected(1);
        assert_eq!(event.clone(), event);
    }

    #[tokio::test]
    async fn an_injected_event_reaches_the_async_receiver() {
        let watcher = DisplayWatcher::new();
        let wanted = DisplayEvent::MirrorChanged(0xD15_0001);

        inject_for_tests(&wanted);

        let mut seen = false;
        while let Some(event) = watcher.recv().await {
            if event == wanted {
                seen = true;
                break;
            }
        }
        assert!(seen);
    }

    #[test]
    fn events_arrive_in_order_and_earlier_ones_are_not_replayed() {
        let first = DisplayEvent::Disconnected(0xD15_0002);
        inject_for_tests(&first);
        let watcher = DisplayWatcher::new();
        let (a, b) = (
            DisplayEvent::Connected(0xD15_0003),
            DisplayEvent::ModeChanged(0xD15_0003),
        );

        inject_for_tests(&a);
        inject_for_tests(&b);

        let ours: Vec<_> = std::iter::from_fn(|| watcher.next_event())
            .filter(|event| {
                matches!(
                    event,
                    DisplayEvent::Disconnected(0xD15_0002)
                        | DisplayEvent::Connected(0xD15_0003)
                        | DisplayEvent::ModeChanged(0xD15_0003)
                )
            })
            .take(2)
            .collect();
        assert_eq!(ours, vec![a, b]);
    }

    #[test]
    fn a_dropped_watcher_is_pruned_and_the_others_keep_receiving() {
        let gone = DisplayWatcher::new();
        let stays = DisplayWatcher::new();
        drop(gone);
        let wanted = DisplayEvent::PrimaryChanged(0xD15_0004);

        inject_for_tests(&wanted);

        assert!(wait_for(&stays, &wanted));
    }

    #[test]
    fn closing_the_queue_handle_wakes_a_parked_reader() {
        let watcher = DisplayWatcher::new();
        let handle = watcher.queue_handle();
        // Events other tests inject may arrive first; the loop ends only
        // when the queue is closed.
        let reader =
            std::thread::spawn(move || std::iter::from_fn(|| watcher.next_event()).count());

        handle.close();

        reader
            .join()
            .expect("the reader thread ends once the queue is closed");
    }

    #[test]
    fn callback_delivery_finishes_while_the_registration_lock_is_held() {
        use std::{sync::mpsc::sync_channel, thread, time::Duration};
        let subscribers = Subscribers::new();
        let receiver = subscribers.subscribe();
        let writer = subscribers.writer.lock().unwrap();
        let publisher = Arc::clone(&subscribers);
        let (finished_tx, finished) = sync_channel(1);
        let callback = thread::spawn(move || {
            publisher.publish(&DisplayEvent::Connected(17));
            finished_tx.send(()).unwrap();
        });
        let delivered_with_writer_held = finished.recv_timeout(Duration::from_secs(5));
        // Do not leave the deliberately blocked baseline callback behind.
        drop(writer);
        callback.join().unwrap();
        assert!(
            delivered_with_writer_held.is_ok(),
            "callback waited for the registration lock"
        );
        assert_eq!(receiver.try_recv().unwrap(), DisplayEvent::Connected(17));
    }

    #[test]
    fn established_subscriber_keeps_all_events_during_registration_churn() {
        use std::{sync::Barrier, thread};
        let subscribers = Subscribers::new();
        let receiver = subscribers.subscribe();
        let barrier = Arc::new(Barrier::new(2));
        let writers = Arc::clone(&subscribers);
        let writers_barrier = Arc::clone(&barrier);
        let writer = thread::spawn(move || {
            writers_barrier.wait();
            for _ in 0..256 {
                drop(writers.subscribe());
            }
        });
        barrier.wait();
        for id in 0..256 {
            subscribers.publish(&DisplayEvent::ModeChanged(id));
        }
        writer.join().unwrap();
        for id in 0..256 {
            assert_eq!(receiver.try_recv().unwrap(), DisplayEvent::ModeChanged(id));
        }
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn isolated_fanout_preserves_order_no_replay_and_receiver_clone_lifetime() {
        let subscribers = Subscribers::new();
        subscribers.publish(&DisplayEvent::Connected(1));
        let receiver = subscribers.subscribe();
        assert!(receiver.try_recv().is_err());
        let clone = receiver.clone();
        drop(receiver);
        assert_eq!(subscribers.subscriber_count(), 1);
        for id in 2..5 {
            subscribers.publish(&DisplayEvent::Connected(id));
        }
        for id in 2..5 {
            assert_eq!(clone.try_recv().unwrap(), DisplayEvent::Connected(id));
        }
        drop(clone);
        assert_eq!(subscribers.subscriber_count(), 0);
    }

    #[test]
    fn closed_queues_leave_the_snapshot_without_waiting_for_another_event() {
        let subscribers = Subscribers::new();
        for _ in 0..256 {
            let receiver = subscribers.subscribe();
            let clone = receiver.clone();
            receiver.close();
            assert_eq!(subscribers.subscriber_count(), 0);
            subscribers.publish(&DisplayEvent::Connected(9));
            assert!(clone.try_recv().is_err());
        }
        assert_eq!(subscribers.subscriber_count(), 0);
        let receiver = subscribers.subscribe();
        subscribers.publish(&DisplayEvent::Connected(10));
        assert_eq!(receiver.try_recv().unwrap(), DisplayEvent::Connected(10));
    }

    #[test]
    fn a_callback_snapshot_never_owns_a_subscription_cleanup_token() {
        use std::{sync::mpsc::sync_channel, thread, time::Duration};
        let subscribers = Subscribers::new();
        let receiver = subscribers.subscribe();
        let token = Arc::downgrade(&receiver.subscription);
        // Model a callback that loaded its snapshot just before removal.
        let callback_snapshot = subscribers.live.load_full();
        drop(receiver);
        assert!(token.upgrade().is_none());
        assert_eq!(subscribers.subscriber_count(), 0);

        let writer = subscribers.writer.lock().unwrap();
        let (finished_tx, finished) = sync_channel(1);
        let callback = thread::spawn(move || {
            for sender in callback_snapshot.iter() {
                assert!(sender.try_send(DisplayEvent::Connected(31)).is_err());
            }
            drop(callback_snapshot);
            finished_tx.send(()).unwrap();
        });
        let completed_with_writer_held = finished.recv_timeout(Duration::from_secs(5));
        drop(writer);
        callback.join().unwrap();
        assert!(
            completed_with_writer_held.is_ok(),
            "snapshot cleanup waited for writer"
        );
        assert_eq!(subscribers.subscriber_count(), 0);
    }

    #[test]
    fn flags_classify_by_precedence() {
        use CGDisplayChangeSummaryFlags as F;
        assert_eq!(
            classify(3, F::AddFlag | F::MovedFlag),
            Some(DisplayEvent::Connected(3))
        );
        assert_eq!(
            classify(3, F::RemoveFlag | F::SetModeFlag),
            Some(DisplayEvent::Disconnected(3))
        );
        assert_eq!(
            classify(3, F::MovedFlag | F::SetModeFlag),
            Some(DisplayEvent::PrimaryChanged(3))
        );
        assert_eq!(
            classify(3, F::SetMainFlag),
            Some(DisplayEvent::PrimaryChanged(3))
        );
        assert_eq!(
            classify(3, F::SetModeFlag | F::MirrorFlag),
            Some(DisplayEvent::ModeChanged(3))
        );
        assert_eq!(
            classify(3, F::DesktopShapeChangedFlag),
            Some(DisplayEvent::ModeChanged(3))
        );
        assert_eq!(
            classify(3, F::UnMirrorFlag),
            Some(DisplayEvent::MirrorChanged(3))
        );
        assert_eq!(classify(3, F::BeginConfigurationFlag), None);
        assert_eq!(
            classify(3, F::EnabledFlag),
            Some(DisplayEvent::Other(3, F::EnabledFlag))
        );
    }
}
