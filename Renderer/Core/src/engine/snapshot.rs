use std::sync::{Arc, Mutex};

use super::{
    DisplaySnapshotEntry, PointerActivity, SceneWindowEntry, PointerActivityCallback, PointerConsumerCallback,
    UserShortcutObserverCallback,
};
use crate::window::MouseButtonTracker;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EngineSnapshot {
    pub displays: Vec<DisplaySnapshotEntry>,
    /// Every open scene with its window, the parked ones included.
    pub scenes: Vec<SceneWindowEntry>,
}

impl EngineSnapshot {
    /// Only a presenting scene consumes pointer input: a paused scene's clock
    /// is stopped, so sampling the pointer for it is work nobody sees.
    pub fn has_pointer_consumers(&self) -> bool {
        self.displays
            .iter()
            .any(|entry| entry.handle.is_some() && entry.accepts_pointer_input && !entry.paused)
    }
}

struct PointerConsumerObserver {
    callback: Option<PointerConsumerCallback>,
    /// The engine's own hook that installs the OS pointer monitors only while
    /// a presenting scene reads the pointer.
    monitor_hook: Option<PointerConsumerCallback>,
    has_consumers: bool,
}

/// Whether the OS event monitors can miss pointer motion right now.
#[derive(Default)]
struct PointerMonitorGap {
    app_active: bool,
    monitors_installed: bool,
}

impl PointerMonitorGap {
    fn open(&self) -> bool { self.app_active || !self.monitors_installed }
}

pub struct EngineSnapshotPublisher {
    snapshot: arc_swap::ArcSwap<EngineSnapshot>,
    pointer_consumer: Mutex<PointerConsumerObserver>,
    user_shortcut: Mutex<Option<UserShortcutObserverCallback>>,
    mouse_buttons: Arc<Mutex<MouseButtonTracker>>,
    /// Read lock-free on every OS pointer event; written only on install.
    pointer_activity: arc_swap::ArcSwapOption<PointerActivityCallback>,
    /// Serializes gap changes with callback installation so a replay cannot
    /// overtake a newer change.
    pointer_monitor_gap: Mutex<PointerMonitorGap>,
    /// Live scenes whose renderers report that they read system audio.
    audio_requirement: super::audio_requirement::AudioRequirementObserver,
}

impl EngineSnapshotPublisher {
    pub fn new(snapshot: EngineSnapshot, mouse_buttons: Arc<Mutex<MouseButtonTracker>>) -> Self {
        let has_consumers = snapshot.has_pointer_consumers();
        Self {
            snapshot: arc_swap::ArcSwap::from_pointee(snapshot),
            pointer_consumer: Mutex::new(PointerConsumerObserver {
                callback: None,
                monitor_hook: None,
                has_consumers,
            }),
            user_shortcut: Mutex::new(None),
            mouse_buttons,
            pointer_activity: arc_swap::ArcSwapOption::empty(),
            pointer_monitor_gap: Mutex::new(PointerMonitorGap::default()),
            audio_requirement: super::audio_requirement::AudioRequirementObserver::default(),
        }
    }

    pub fn load(&self) -> Arc<EngineSnapshot> { self.snapshot.load_full() }

    pub fn audio_requirement(&self) -> &super::audio_requirement::AudioRequirementObserver {
        &self.audio_requirement
    }

    /// Installs the pointer activity sink and synchronously replays whether the
    /// monitors currently have a gap.
    pub fn set_pointer_activity_callback(&self, callback: Option<PointerActivityCallback>) {
        let gap = self.pointer_monitor_gap.lock().unwrap_or_else(|error| error.into_inner());
        self.pointer_activity.store(callback.map(Arc::new));
        self.signal_pointer_activity(PointerActivity::MonitorGap(gap.open()));
    }

    /// OS input arrived, or a presenting scene needs its pointer state again.
    /// Called from the AppKit main thread for every monitored event: loads the
    /// sink without locking or allocating.
    pub fn signal_pointer_input(&self) {
        self.signal_pointer_activity(PointerActivity::Input);
    }

    pub(crate) fn set_pointer_app_active(&self, active: bool) {
        self.update_pointer_monitor_gap(|gap| gap.app_active = active);
    }

    pub(crate) fn set_pointer_monitors_installed(&self, installed: bool) {
        self.update_pointer_monitor_gap(|gap| gap.monitors_installed = installed);
    }

    fn update_pointer_monitor_gap(&self, update: impl FnOnce(&mut PointerMonitorGap)) {
        let mut gap = self.pointer_monitor_gap.lock().unwrap_or_else(|error| error.into_inner());
        let was_open = gap.open();
        update(&mut gap);
        if gap.open() != was_open {
            self.signal_pointer_activity(PointerActivity::MonitorGap(gap.open()));
        }
    }

    fn signal_pointer_activity(&self, activity: PointerActivity) {
        if let Some(callback) = self.pointer_activity.load().as_ref() {
            callback(activity);
        }
    }

    /// Callbacks run synchronously under the observer lock and must only update
    /// polling control. They must not call back into the engine or panic.
    pub fn set_pointer_consumer_callback(&self, callback: Option<PointerConsumerCallback>) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback = callback;
        if let Some(callback) = &observer.callback { callback(observer.has_consumers); }
    }

    /// Installs the hook told when pointer consumers appear or go, and replays
    /// the current presence. Runs under the observer lock like the consumer
    /// callback, so it must only schedule work, never block or reenter.
    pub(crate) fn set_pointer_monitor_hook(&self, hook: Option<PointerConsumerCallback>) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.monitor_hook = hook;
        if let Some(hook) = &observer.monitor_hook { hook(observer.has_consumers); }
    }

    /// Installs the observer for `engine.openUserShortcut` requests.
    ///
    /// Replaces rather than adds: one host, one sink. The callback runs under
    /// this lock and must only hand the request on, never reenter the engine.
    pub fn set_user_shortcut_callback(&self, callback: Option<UserShortcutObserverCallback>) {
        let mut observer = self.user_shortcut.lock().unwrap_or_else(|error| error.into_inner());
        *observer = callback;
    }

    /// Reports one request. Returns false when no host is listening, which is
    /// the ordinary state before the app has installed its sink.
    pub fn report_user_shortcut(&self, handle: crate::project::SceneHandle, name: &str, value: &str) -> bool {
        let observer = self.user_shortcut.lock().unwrap_or_else(|error| error.into_inner());
        let Some(callback) = observer.as_ref() else { return false };
        callback(handle, name.to_owned(), value.to_owned());
        true
    }

    pub fn publish(&self, snapshot: EngineSnapshot) {
        let has_consumers = snapshot.has_pointer_consumers();
        let snapshot = Arc::new(snapshot);
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        let changed = observer.has_consumers != has_consumers;
        if has_consumers && !observer.has_consumers {
            // Serialize activation with OS events and samples; preserve held levels.
            let mut tracker = self.mouse_buttons.lock().unwrap_or_else(|error| error.into_inner());
            let _ = tracker.consume_edges();
            self.snapshot.store(snapshot);
            observer.has_consumers = has_consumers;
            drop(tracker);
        } else {
            self.snapshot.store(snapshot);
            observer.has_consumers = has_consumers;
        }
        if changed {
            if let Some(callback) = &observer.callback { callback(has_consumers); }
            if let Some(hook) = &observer.monitor_hook { hook(has_consumers); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DisplayDesc, DisplayIdentity};

    fn interactive_snapshot() -> EngineSnapshot {
        EngineSnapshot { displays: vec![DisplaySnapshotEntry {
            identity: DisplayIdentity::default(),
            desc: DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: None,
        }], scenes: Vec::new() }
    }

    #[test]
    fn activation_discards_old_edges_preserves_held_levels_and_new_taps() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone());
        {
            let mut tracker = tracker.lock().unwrap();
            tracker.set_button(0, true);
            tracker.set_button(0, false);
            tracker.set_button(1, true);
        }
        publisher.publish(interactive_snapshot());
        {
            let mut tracker = tracker.lock().unwrap();
            let held = tracker.consume_edges();
            assert_eq!(held.down().mask(), 2);
            assert!(held.transitions().next().is_none());
            tracker.set_button(1, false);
            tracker.set_button(2, true);
            tracker.set_button(2, false);
        }
        // Neither observer replay nor a true -> true commit clears active edges.
        let replay = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let replay = replay.clone();
            move |value| replay.lock().unwrap().push(value)
        })));
        publisher.publish(interactive_snapshot());
        let edges: Vec<_> = tracker.lock().unwrap().consume_edges().transitions()
            .map(|edge| (edge.button, edge.pressed)).collect();
        assert_eq!(edges, vec![(1, false), (2, true), (2, false)]);
        assert_eq!(*replay.lock().unwrap(), vec![true]);
    }

    #[test]
    fn a_paused_scene_is_not_a_pointer_consumer_and_its_resume_drops_paused_clicks() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone());
        let seen = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let seen = seen.clone();
            move |value| seen.lock().unwrap().push(value)
        })));
        publisher.publish(interactive_snapshot());

        let mut paused = interactive_snapshot();
        paused.displays[0].paused = true;
        assert!(!paused.has_pointer_consumers(), "the only interactive scene is paused");
        publisher.publish(paused);
        // A click while the scene is paused must not reach it after resume.
        {
            let mut tracker = tracker.lock().unwrap();
            tracker.set_button(0, true);
            tracker.set_button(0, false);
        }
        publisher.publish(interactive_snapshot());

        assert_eq!(*seen.lock().unwrap(), vec![false, true, false, true]);
        assert!(tracker.lock().unwrap().consume_edges().transitions().next().is_none());
    }

    #[test]
    fn the_monitor_hook_follows_pointer_consumers_beside_the_bridge_callback() {
        let publisher = EngineSnapshotPublisher::new(
            EngineSnapshot::default(),
            Arc::new(Mutex::new(MouseButtonTracker::new())),
        );
        let hook = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_monitor_hook(Some(Arc::new({
            let hook = hook.clone();
            move |value| hook.lock().unwrap().push(value)
        })));
        let bridge = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let bridge = bridge.clone();
            move |value| bridge.lock().unwrap().push(value)
        })));

        publisher.publish(interactive_snapshot());
        publisher.publish(interactive_snapshot());
        let mut paused = interactive_snapshot();
        paused.displays[0].paused = true;
        publisher.publish(paused);

        // Replayed on install, then told only when presence changes: no
        // monitors while nothing reads the pointer, including a paused scene.
        assert_eq!(*hook.lock().unwrap(), vec![false, true, false]);
        assert_eq!(*bridge.lock().unwrap(), vec![false, true, false],
            "the bridge callback is not replaced by the engine's hook");
    }

    #[test]
    fn pointer_monitor_gap_is_replayed_and_reported_only_on_change() {
        let publisher = EngineSnapshotPublisher::new(
            EngineSnapshot::default(),
            Arc::new(Mutex::new(MouseButtonTracker::new())),
        );
        publisher.set_pointer_monitors_installed(true);
        let seen = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_activity_callback(Some(Arc::new({
            let seen = seen.clone();
            move |activity| seen.lock().unwrap().push(activity)
        })));
        publisher.set_pointer_app_active(false);
        publisher.set_pointer_app_active(true);
        publisher.set_pointer_app_active(true);
        publisher.signal_pointer_input();
        publisher.set_pointer_app_active(false);
        publisher.set_pointer_monitors_installed(false);

        assert_eq!(*seen.lock().unwrap(), vec![
            PointerActivity::MonitorGap(false),
            PointerActivity::MonitorGap(true),
            PointerActivity::Input,
            PointerActivity::MonitorGap(false),
            PointerActivity::MonitorGap(true),
        ]);
    }

    #[test]
    fn activation_waits_for_tracker_before_publishing() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone()));
        let mut held = tracker.lock().unwrap();
        held.set_button(0, true);
        held.set_button(0, false);
        let started = Arc::new(std::sync::Barrier::new(2));
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            let started = started.clone();
            move || {
                started.wait();
                publisher.publish(interactive_snapshot());
            }
        });
        started.wait();
        assert!(!publisher.load().has_pointer_consumers());
        drop(held);
        writer.join().unwrap();
        assert!(publisher.load().has_pointer_consumers());
        assert!(tracker.lock().unwrap().consume_edges().transitions().next().is_none());
    }

    #[test]
    fn registration_replay_serializes_before_publication() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker));
        let (seen_tx, seen_rx) = std::sync::mpsc::channel();
        let release = Arc::new(std::sync::Barrier::new(2));
        let register = std::thread::spawn({
            let publisher = publisher.clone();
            let release = release.clone();
            move || publisher.set_pointer_consumer_callback(Some(Arc::new(move |value| {
                seen_tx.send(value).unwrap();
                if !value { release.wait(); }
            })))
        });
        assert!(!seen_rx.recv().unwrap());
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.publish(interactive_snapshot())
        });
        release.wait();
        register.join().unwrap();
        writer.join().unwrap();
        assert!(seen_rx.recv().unwrap());
        publisher.set_pointer_consumer_callback(None);
    }

    #[test]
    fn publication_serializes_before_replacement_replay() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker));
        let (committed_tx, committed_rx) = std::sync::mpsc::channel();
        let release = Arc::new(std::sync::Barrier::new(2));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let release = release.clone();
            move |value| if value { committed_tx.send(()).unwrap(); release.wait(); }
        })));
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.publish(interactive_snapshot())
        });
        committed_rx.recv().unwrap();
        let (replay_tx, replay_rx) = std::sync::mpsc::channel();
        let register = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.set_pointer_consumer_callback(Some(Arc::new(move |value| {
                replay_tx.send(value).unwrap();
            })))
        });
        release.wait();
        writer.join().unwrap();
        register.join().unwrap();
        assert!(replay_rx.recv().unwrap());
        let mut video = interactive_snapshot();
        video.displays[0].accepts_pointer_input = false;
        publisher.publish(video);
        assert!(!replay_rx.recv().unwrap());
    }

    #[test]
    fn poisoned_tracker_retains_levels_at_activation() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let _ = std::thread::spawn({
            let tracker = tracker.clone();
            move || {
                tracker.lock().unwrap().set_button(3, true);
                let _guard = tracker.lock().unwrap();
                panic!("poison tracker");
            }
        }).join();
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone());
        publisher.publish(interactive_snapshot());
        let edges = tracker.lock().unwrap_or_else(|error| error.into_inner()).consume_edges();
        assert_eq!(edges.down().mask(), 8);
        assert!(edges.transitions().next().is_none());
    }

    #[test]
    fn publisher_returns_initial_snapshot() {
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), Arc::new(Mutex::new(MouseButtonTracker::new())));

        assert_eq!(publisher.load().displays, Vec::new());
    }

    #[test]
    fn publisher_returns_latest_snapshot() {
        let identity = DisplayIdentity {
            uuid: Some("display-uuid".to_string()),
            vendor_id: Some(10),
            model_id: Some(20),
            serial_number: Some(30),
            unit_number: Some(1),
            name: Some("Studio Display".to_string()),
        };
        let display = DisplayDesc::with_identity(9, identity.clone(), 0, 0, 1920, 1080, 1.0);
        let entry = DisplaySnapshotEntry {
            identity,
            desc: display,
            handle: None,
            accepts_pointer_input: false,
            paused: false,
            window_active: true,
            assignment: None,
        };
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), Arc::new(Mutex::new(MouseButtonTracker::new())));

        publisher.publish(EngineSnapshot {
            displays: vec![entry.clone()],
            scenes: Vec::new(),
        });

        assert_eq!(publisher.load().displays, vec![entry]);
    }
}
