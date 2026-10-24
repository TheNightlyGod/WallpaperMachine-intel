use wallpaper_core::DisplaySnapshotEntry;

use super::fixture_values::identified;

use crate::{
    actor::state::BridgeActorState,
    api::BridgeBuilder,
    engine::{EngineFacade, FakeEngineFacade},
};

pub(super) fn mouse_scenario<F: Future<Output = ()>>(run: impl FnOnce() -> F + Send + 'static) {
    let (done, result) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(run());
        }));
        let _ = done.send(outcome);
    });
    let outcome = result
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("mouse scenario, including bridge drop, must finish within two seconds");
    worker.join().unwrap();
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
}

pub(super) fn active_mouse_display() -> DisplaySnapshotEntry {
    let mut display = identified("mouse-display", 7, 60);
    display.handle = Some(wallpaper_core::project::SceneHandle::new(42));
    display.accepts_pointer_input = true;
    display
}

pub(super) fn await_mouse_sample(engine: &FakeEngineFacade) {
    assert!(
        engine.wait_for_unseen_mouse_poll(std::time::Duration::from_secs(1)),
        "enabled poller must reach the engine"
    );
}

pub(super) fn assert_mouse_idle(engine: &FakeEngineFacade) {
    let count = engine.mouse_poll_calls().len();
    std::thread::sleep(std::time::Duration::from_millis(80));
    assert_eq!(
        engine.mouse_poll_calls().len(),
        count,
        "quiescent poller must perform no periodic engine work"
    );
}

#[test]
fn mouse_polling_follows_scene_lifetime_and_samples_latest_input_on_resume() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        bridge.app_snapshot().await.unwrap();
        bridge.poll_mouse_position().await.unwrap();
        assert_mouse_idle(&engine);
        assert!(engine.mouse_poll_calls().is_empty());

        engine.set_snapshot(vec![active_mouse_display()]);
        bridge.refresh_displays().await.unwrap();
        await_mouse_sample(&engine);

        bridge.set_presentation_suspended(true).await.unwrap();
        let suspended_count = engine.mouse_poll_calls().len();
        bridge.poll_mouse_position().await.unwrap();
        assert_eq!(engine.mouse_poll_calls().len(), suspended_count);
        assert_mouse_idle(&engine);
        engine.set_mouse_input(123.0, 456.0);
        let resumed = engine.block_next_mouse_poll();
        bridge.set_presentation_suspended(false).await.unwrap();
        let reached = resumed.wait_until_blocked(std::time::Duration::from_secs(1));
        resumed.release();
        assert!(reached, "resume must sample without any new input event");
        assert_eq!(engine.mouse_samples().last(), Some(&(123.0, 456.0)));

        engine.set_snapshot(Vec::new());
        bridge.refresh_displays().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_stops_while_the_only_interactive_scene_is_suspended_on_its_display() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        // Display 9 shows nothing a pointer can reach, so it is never suspended
        // and the global "every display paused" gate stays open.
        engine.set_snapshot(vec![active_mouse_display(), identified("empty", 9, 60)]);
        let bridge = BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .unwrap();
        await_mouse_sample(&engine);

        bridge
            .set_display_presentation_suspended("7".into(), true)
            .await
            .unwrap();
        assert_mouse_idle(&engine);

        engine.set_mouse_input(12.0, 34.0);
        let resumed = engine.block_next_mouse_poll();
        bridge
            .set_display_presentation_suspended("7".into(), false)
            .await
            .unwrap();
        let reached = resumed.wait_until_blocked(std::time::Duration::from_secs(1));
        resumed.release();
        assert!(reached, "resuming the display must sample at once");
        assert_eq!(engine.mouse_samples().last(), Some(&(12.0, 34.0)));
        drop(bridge);
    });
}

#[test]
fn mouse_polling_samples_only_when_input_arrives() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let bridge = BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .unwrap();
        // A new consumer gets the current position without waiting for input.
        await_mouse_sample(&engine);
        std::thread::sleep(std::time::Duration::from_millis(20));

        let quiet = engine.mouse_poll_calls().len();
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(
            engine.mouse_poll_calls().len(),
            quiet,
            "a consumer with no pointer input must not be sampled"
        );

        // One move: exactly one sample.
        engine.simulate_pointer_input();
        std::thread::sleep(std::time::Duration::from_millis(40));
        assert_eq!(engine.mouse_poll_calls().len(), quiet + 1, "one move is one sample");

        // A burst inside one spacing window: the first sample runs at once and
        // the rest coalesce into at most one more at the end of the window.
        let before_burst = engine.mouse_poll_calls().len();
        for _ in 0..50 {
            engine.simulate_pointer_input();
        }
        std::thread::sleep(std::time::Duration::from_millis(60));
        let burst = engine.mouse_poll_calls().len() - before_burst;
        assert!((1..=2).contains(&burst), "50 moves within 16 ms took {burst} samples");

        // After a quiet period the first move is not held back by the spacing.
        let fastest = (0..3)
            .map(|_| {
                std::thread::sleep(std::time::Duration::from_millis(40));
                let sample = engine.block_next_mouse_poll();
                let moved = std::time::Instant::now();
                engine.simulate_pointer_input();
                let reached = sample.wait_until_blocked(std::time::Duration::from_secs(1));
                let latency = moved.elapsed();
                sample.release();
                assert!(reached, "a move must be sampled");
                latency
            })
            .min()
            .unwrap();
        assert!(
            fastest < std::time::Duration::from_millis(16),
            "a move after a quiet period waited {fastest:?}"
        );
        drop(bridge);
    });
}

#[test]
fn mouse_polling_in_a_monitor_gap_checks_the_cursor_without_engine_work() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let initial_sample = engine.block_next_mouse_poll();
        let bridge = BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .unwrap();
        let reached = initial_sample.wait_until_blocked(std::time::Duration::from_secs(1));
        initial_sample.release();
        assert!(reached, "a new consumer must sample the cursor");
        // This app became active: motion over its own windows reaches no
        // monitor, so the poller has to look at the cursor itself.
        let gap_sample = engine.block_next_mouse_poll();
        engine.set_pointer_monitor_gap(true);
        let reached = gap_sample.wait_until_blocked(std::time::Duration::from_secs(1));
        gap_sample.release();
        assert!(reached, "entering the monitor gap must sample the cursor");

        let calls = engine.mouse_poll_calls().len();
        let probes = engine.pointer_probe_count();
        // Reaching the second probe proves the first unchanged probe was
        // processed, without depending on the worker being scheduled in 80 ms.
        assert!(
            engine.wait_for_pointer_probes(probes + 2, std::time::Duration::from_secs(1)),
            "the gap is checked"
        );
        assert_eq!(
            engine.mouse_poll_calls().len(),
            calls,
            "an unchanged cursor must not reach the engine"
        );

        let moved_sample = engine.block_next_mouse_poll();
        engine.set_pointer_probe(wallpaper_core::PointerProbe { x: 10.0, y: 20.0, buttons: 0 });
        let reached = moved_sample.wait_until_blocked(std::time::Duration::from_secs(1));
        // Close the gap while the poller is blocked in this sample, so no
        // cursor probe can still be in flight when we record the final count.
        engine.set_pointer_monitor_gap(false);
        let probes = engine.pointer_probe_count();
        moved_sample.release();
        assert!(reached, "a changed cursor must reach the engine");
        assert_eq!(engine.mouse_poll_calls().len(), calls + 1, "one change is one sample");

        // Closing the gap stops the checks.
        std::thread::sleep(std::time::Duration::from_millis(60));
        assert_eq!(engine.pointer_probe_count(), probes);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_disabled_drop_exits_without_an_input_event() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        bridge.app_snapshot().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
        assert!(engine.mouse_poll_calls().is_empty());
    });
}

#[test]
fn bridge_mouse_polling_waits_for_stalled_engine_poll() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let blocked_poll = engine.block_next_mouse_poll();
        let bridge = BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .expect("bridge should build");

        let reached = blocked_poll.wait_until_blocked(std::time::Duration::from_secs(1));
        if !reached {
            blocked_poll.release();
        }
        assert!(reached, "first mouse poll should reach the engine");
        std::thread::sleep(std::time::Duration::from_millis(80));
        let calls = engine.mouse_poll_calls().len();
        let next_poll = engine.block_next_mouse_poll();
        blocked_poll.release();
        assert_eq!(calls, 1, "only one poll may be in flight");
        let queued = next_poll.wait_until_blocked(std::time::Duration::from_millis(8));
        next_poll.release();
        assert!(!queued, "stalled poll must not accumulate a backlog");
        drop(bridge);
    });
}

#[test]
fn mouse_polling_uses_committed_capability_without_refresh_or_first_frame() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let mut video = active_mouse_display();
        video.accepts_pointer_input = false;
        engine.set_snapshot(vec![video.clone()]);
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        bridge.app_snapshot().await.unwrap();
        bridge.poll_mouse_position().await.unwrap();
        assert_mouse_idle(&engine);
        assert!(engine.mouse_poll_calls().is_empty());

        // A configured refresh is not a committed native capability.
        engine.set_snapshot_after_refresh(vec![active_mouse_display()]);
        bridge.poll_mouse_position().await.unwrap();
        assert!(engine.mouse_poll_calls().is_empty());

        // Unknown native state is conservatively interactive, even without assignment.
        let mut unknown = active_mouse_display();
        unknown.desc.display_id = 8;
        unknown.handle = Some(wallpaper_core::project::SceneHandle::new(43));
        engine.set_snapshot(vec![video.clone(), unknown]);
        await_mouse_sample(&engine);

        bridge.pause_all().await.unwrap();
        engine.set_snapshot(vec![video.clone()]);
        engine.set_snapshot(vec![active_mouse_display()]);
        bridge.poll_mouse_position().await.unwrap();
        assert_mouse_idle(&engine);
        bridge.play_all().await.unwrap();
        await_mouse_sample(&engine);

        engine.set_snapshot(vec![video]);
        bridge.app_snapshot().await.unwrap();
        assert_mouse_idle(&engine);
        bridge.pause_all().await.unwrap();
        bridge.play_all().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn partial_refresh_error_publishes_actual_consumers() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        engine.set_snapshot_after_refresh(vec![active_mouse_display()]);
        engine.fail_next_refresh();
        assert!(bridge.refresh_displays().await.is_err());
        await_mouse_sample(&engine);

        engine.set_snapshot_after_refresh(Vec::new());
        engine.fail_next_refresh();
        assert!(bridge.refresh_displays().await.is_err());
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn dropping_an_older_bridge_does_not_unregister_the_new_consumer_callback() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let first = BridgeBuilder::new(engine.clone()).build().unwrap();
        let second = BridgeBuilder::new(engine.clone()).build().unwrap();
        drop(first);
        engine.set_snapshot(vec![active_mouse_display()]);
        await_mouse_sample(&engine);
        drop(second);
        let count = engine.mouse_poll_calls().len();
        engine.set_snapshot(Vec::new());
        engine.set_snapshot(vec![active_mouse_display()]);
        assert_eq!(engine.mouse_poll_calls().len(), count);
    });
}

#[tokio::test]
async fn fake_consumer_observer_replays_only_committed_snapshot_changes() {
    let engine = FakeEngineFacade::default();
    let (send, receive) = std::sync::mpsc::channel();
    engine.set_pointer_consumer_callback(Some(std::sync::Arc::new(move |value| {
        send.send(value).unwrap();
    })));
    assert!(!receive.recv().unwrap());
    engine.set_snapshot_after_refresh(vec![active_mouse_display()]);
    assert!(receive.try_recv().is_err());
    engine.refresh_displays().await.unwrap();
    assert!(receive.recv().unwrap());
    engine.set_snapshot(vec![active_mouse_display()]);
    assert!(receive.try_recv().is_err());
    engine.fail_next_close();
    assert!(engine.close_all_scenes().await.is_err());
    assert!(engine.display_snapshot()[0].accepts_pointer_input);
    assert!(receive.try_recv().is_err());
    engine.close_all_scenes().await.unwrap();
    assert!(!receive.recv().unwrap());
    assert!(engine.display_snapshot()[0].handle.is_none());
    engine.set_pointer_consumer_callback(None);
    engine.set_snapshot(vec![active_mouse_display()]);
    assert!(receive.try_recv().is_err());
}

#[test]
fn consumer_registration_and_publication_are_serialized_in_both_orders() {
    use std::sync::{Arc, Barrier, mpsc};

    for publication_first in [false, true] {
        let engine = FakeEngineFacade::default();
        let reached = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let (events, received) = mpsc::channel();
        let blocking_callback: wallpaper_core::PointerConsumerCallback = {
            let reached = reached.clone();
            let release = release.clone();
            Arc::new(move |value| {
                events.send(value).unwrap();
                if value == publication_first {
                    reached.wait();
                    release.wait();
                }
            })
        };
        if publication_first {
            engine.set_pointer_consumer_callback(Some(blocking_callback.clone()));
            assert!(!received.recv().unwrap());
        }
        let first_engine = engine.clone();
        let first = std::thread::spawn(move || {
            if publication_first {
                first_engine.set_snapshot(vec![active_mouse_display()]);
            } else {
                first_engine.set_pointer_consumer_callback(Some(blocking_callback));
            }
        });
        reached.wait();
        assert_eq!(received.recv().unwrap(), publication_first);
        let second_engine = engine.clone();
        let (started, starting) = mpsc::channel();
        let (replayed, replay) = mpsc::channel();
        let second = std::thread::spawn(move || {
            started.send(()).unwrap();
            if publication_first {
                second_engine.set_pointer_consumer_callback(Some(Arc::new(move |value| {
                    replayed.send(value).unwrap();
                })));
            } else {
                second_engine.set_snapshot(vec![active_mouse_display()]);
            }
        });
        starting.recv().unwrap();
        release.wait();
        first.join().unwrap();
        second.join().unwrap();
        if publication_first {
            assert!(replay.recv().unwrap());
        } else {
            assert!(received.recv().unwrap());
        }
        assert!(engine.display_snapshot()[0].accepts_pointer_input);
    }
}

