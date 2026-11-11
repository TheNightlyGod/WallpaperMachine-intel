// Device-free recovery regressions: real controllers and session ownership,
// with only native setup/teardown replaced at the lifecycle boundary.
use std::time::{Duration, Instant};

use super::*;
use crate::{
    media::audio::{
        AudioCaptureController, AudioResponseEngine, RestartOutcome, TAP_STALL_REBUILD_LIMIT,
        TapStallCheck,
    },
    project::SceneHandle,
};

struct Control {
    opens: usize,
    permission: bool,
    permission_requests: usize,
    fail_setup: bool,
    report_native_running: bool,
    output_running: bool,
}

struct RecoveryBackend {
    capture: CaptureOwner<FakeTeardown>,
    ops: FakeTeardown,
    control: Arc<Mutex<Control>>,
}

impl RecoveryBackend {
    fn new() -> Self {
        Self {
            capture: CaptureOwner { state: None },
            ops: FakeTeardown::default(),
            control: Arc::new(Mutex::new(Control {
                opens: 0,
                permission: true,
                permission_requests: 0,
                fail_setup: false,
                report_native_running: false,
                output_running: true,
            })),
        }
    }

    fn opens(&self) -> usize {
        self.control.lock().unwrap().opens
    }

    fn assert_healthy(&self) {
        assert!(self.is_running());
        assert!(!self.has_pending_cleanup());
        let state = self.capture.state.as_ref().unwrap();
        assert!(
            state.running,
            "successful activation must actually start native recording"
        );
        assert!(!state.releasing);
    }
}

impl AudioCaptureBackend for RecoveryBackend {
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(self.control.lock().unwrap().permission)
    }

    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let mut control = self.control.lock().unwrap();
        control.permission = true;
        control.permission_requests += 1;
        Ok(true)
    }

    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        self.capture.start_with(
            || CaptureState::with_teardown(self.ops.clone()),
            |state| {
                let mut control = self.control.lock().unwrap();
                control.opens += 1;
                populate(state, consumer);
                if mem::take(&mut control.fail_setup) {
                    // IOProc and its callback exist, but AudioDeviceStart was
                    // never reached. Failed cleanup must not masquerade as capture.
                    state.running = false;
                    Err(AudioCaptureError::Platform(
                        "injected pre-start failure".into(),
                    ))
                } else {
                    Ok(())
                }
            },
        )
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        self.capture.stop()
    }

    fn is_running(&self) -> bool {
        if self.control.lock().unwrap().report_native_running {
            // Exercise a backend that exposes the native running bit separately
            // from pending teardown (both queries can then be true).
            self.capture
                .state
                .as_ref()
                .is_some_and(|state| state.running)
        } else {
            self.capture.is_running()
        }
    }

    fn has_pending_cleanup(&self) -> bool {
        self.capture.has_pending_cleanup()
    }

    fn io_callback_count(&self) -> Option<u64> {
        self.capture.io_callback_count()
    }

    fn output_device_is_running(&self) -> bool {
        self.control.lock().unwrap().output_running
    }
}

impl AudioResponseEngine for Consumer {
    fn set_audio_response_enabled(&self, _: SceneHandle, _: bool) -> Result<(), AudioCaptureError> {
        Ok(())
    }
}

fn reenable_after_partial_stop(step: Step) {
    let backend = RecoveryBackend::new();
    let ops = backend.ops.clone();
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
    let handle = SceneHandle::new(11);
    controller.set_scene_capturing(handle, true).unwrap();
    ops.fail(Some(step));
    assert!(controller.set_scene_capturing(handle, false).is_err());
    assert_eq!(controller.active_scene_count(), 0);
    assert!(!controller.is_capturing());
    assert!(controller.backend().has_pending_cleanup());
    assert!(!controller.backend().capture.state.as_ref().unwrap().running);
    ops.fail(None);
    controller.set_scene_capturing(handle, true).unwrap();
    controller.backend().assert_healthy();
    assert!(controller.is_capturing());
    assert_eq!(controller.backend().opens(), 2);
    controller.set_scene_capturing(handle, true).unwrap();
    controller.set_demand(false, false).unwrap();
    assert_eq!(
        controller.backend().opens(),
        2,
        "healthy demand must not duplicate capture"
    );
    controller.set_scene_capturing(handle, false).unwrap();
    assert!(!controller.backend().has_pending_cleanup());
}

#[test]
fn scene_reactivation_after_io_proc_destroy_failure_starts_capture() {
    reenable_after_partial_stop(Step::IoProc);
}

#[test]
fn scene_reactivation_after_aggregate_destroy_failure_starts_capture() {
    reenable_after_partial_stop(Step::Aggregate);
}

#[test]
fn scene_reactivation_after_tap_destroy_failure_starts_capture() {
    reenable_after_partial_stop(Step::Tap);
}

#[test]
fn suspension_rollback_reports_failed_restoration_and_later_recovers() {
    let backend = RecoveryBackend::new();
    let ops = backend.ops.clone();
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
    controller.set_demand(false, true).unwrap();
    ops.fail(Some(Step::IoProc));
    let error = controller.set_demand(true, true).unwrap_err().to_string();
    assert!(error.contains("audio capture rollback failed:"));
    assert!(
        controller.wants_capture(),
        "previous external demand must be restored"
    );
    assert!(!controller.is_capturing());
    assert!(controller.backend().has_pending_cleanup());
    assert_eq!(controller.backend().opens(), 1);
    assert!(controller.set_demand(false, true).is_err());
    assert_eq!(
        controller.backend().opens(),
        1,
        "failed cleanup blocks a second tap"
    );
    ops.fail(None);
    controller.set_demand(false, true).unwrap();
    controller.backend().assert_healthy();
    assert!(controller.is_capturing());
    assert_eq!(controller.backend().opens(), 2);
    controller.set_demand(false, false).unwrap();
}

#[test]
fn suspension_rollback_returns_original_error_after_actual_restoration() {
    let backend = RecoveryBackend::new();
    let ops = backend.ops.clone();
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
    controller.set_demand(false, true).unwrap();
    {
        let mut trace = ops.0.lock().unwrap();
        trace.fail = Some(Step::Aggregate);
        trace.fail_once = true;
    }
    let error = controller.set_demand(true, true).unwrap_err().to_string();
    assert!(error.contains("AudioHardwareDestroyAggregateDevice"));
    assert!(!error.contains("audio capture rollback failed:"));
    assert!(controller.wants_capture());
    controller.backend().assert_healthy();
    assert_eq!(
        controller.backend().opens(),
        2,
        "rollback must restore actual capture"
    );
    assert_eq!(
        ops.calls(),
        [
            Step::Stop,
            Step::IoProc,
            Step::Aggregate,
            Step::Aggregate,
            Step::Tap
        ]
    );
    controller.set_demand(false, false).unwrap();
}

#[test]
fn failed_pre_start_setup_with_pending_cleanup_retries_activation() {
    let backend = RecoveryBackend::new();
    let ops = backend.ops.clone();
    backend.control.lock().unwrap().fail_setup = true;
    ops.fail(Some(Step::IoProc));
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
    let handle = SceneHandle::new(12);
    let error = controller.set_scene_capturing(handle, true).unwrap_err();
    assert_eq!(
        error,
        AudioCaptureError::Platform("injected pre-start failure".into())
    );
    assert_eq!(controller.active_scene_count(), 0);
    assert!(!controller.is_capturing());
    assert!(controller.backend().has_pending_cleanup());
    assert!(!controller.backend().capture.state.as_ref().unwrap().running);
    assert!(controller.set_scene_capturing(handle, true).is_err());
    assert_eq!(controller.active_scene_count(), 0);
    assert_eq!(controller.backend().opens(), 1);
    ops.fail(None);
    controller.set_scene_capturing(handle, true).unwrap();
    controller.backend().assert_healthy();
    assert_eq!(controller.backend().opens(), 2);
    assert_eq!(controller.active_scene_count(), 1);
    controller.set_scene_capturing(handle, false).unwrap();
}

fn legacy_reenable_after_partial_stop(step: Step) {
    let backend = RecoveryBackend::new();
    let ops = backend.ops.clone();
    let mut controller = AudioResponseController::new(Arc::new(Consumer), backend);
    let handle = SceneHandle::new(13);
    controller.set_scene_enabled(handle, true).unwrap();
    ops.fail(Some(step));
    assert!(controller.set_scene_enabled(handle, false).is_err());
    assert_eq!(controller.active_scene_count(), 0);
    assert!(!controller.is_capturing());
    assert!(controller.backend().has_pending_cleanup());
    ops.fail(None);
    controller.set_scene_enabled(handle, true).unwrap();
    controller.backend().assert_healthy();
    assert!(controller.is_capturing());
    assert_eq!(controller.backend().opens(), 2);
    controller.set_scene_enabled(handle, true).unwrap();
    assert_eq!(controller.backend().opens(), 2);
    controller.set_scene_enabled(handle, false).unwrap();
}

#[test]
fn legacy_reactivation_after_io_proc_destroy_failure_starts_capture() {
    legacy_reenable_after_partial_stop(Step::IoProc);
}

#[test]
fn legacy_reactivation_after_aggregate_destroy_failure_starts_capture() {
    legacy_reenable_after_partial_stop(Step::Aggregate);
}

#[test]
fn legacy_reactivation_after_tap_destroy_failure_starts_capture() {
    legacy_reenable_after_partial_stop(Step::Tap);
}

#[test]
fn restart_pending_survives_partial_teardown_and_heals_via_retry_or_demand() {
    for recovery in 0..3 {
        let backend = RecoveryBackend::new();
        let ops = backend.ops.clone();
        let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
        let handle = SceneHandle::new(14);
        controller.set_scene_capturing(handle, true).unwrap();
        ops.fail(Some(Step::IoProc));
        assert!(controller.restart_capture().is_err());
        assert!(
            controller.restart_pending,
            "failed teardown must keep the owed rebuild"
        );
        assert!(!controller.is_capturing());
        assert!(controller.backend().has_pending_cleanup());
        assert!(controller.set_scene_capturing(handle, true).is_err());
        assert!(
            controller.restart_pending,
            "owned resources are not a healed restart"
        );
        assert_eq!(controller.backend().opens(), 1);
        ops.fail(None);
        match recovery {
            0 => assert_eq!(
                controller.restart_capture().unwrap(),
                RestartOutcome::Restarted
            ),
            1 => controller.set_scene_capturing(handle, true).unwrap(),
            _ => controller.set_demand(false, false).unwrap(),
        }
        controller.backend().assert_healthy();
        assert!(!controller.restart_pending);
        assert_eq!(controller.backend().opens(), 2);
        controller.set_scene_capturing(handle, false).unwrap();
        assert_eq!(
            controller.restart_capture().unwrap(),
            RestartOutcome::NotRunning
        );
        assert_eq!(controller.backend().opens(), 2);
    }
}

#[test]
fn both_controllers_treat_running_plus_pending_as_unhealthy() {
    for legacy in [false, true] {
        let backend = RecoveryBackend::new();
        backend.control.lock().unwrap().report_native_running = true;
        let ops = backend.ops.clone();
        let handle = SceneHandle::new(15);
        if legacy {
            let mut controller = AudioResponseController::new(Arc::new(Consumer), backend);
            controller.set_scene_enabled(handle, true).unwrap();
            ops.fail(Some(Step::Stop));
            assert!(controller.set_scene_enabled(handle, false).is_err());
            assert!(controller.backend().is_running());
            assert!(controller.backend().has_pending_cleanup());
            assert!(!controller.is_capturing());
            assert!(controller.set_scene_enabled(handle, true).is_err());
            assert_eq!(controller.backend().opens(), 1);
            ops.fail(None);
            controller.set_scene_enabled(handle, true).unwrap();
            controller.backend().assert_healthy();
            assert_eq!(controller.backend().opens(), 2);
            controller.set_scene_enabled(handle, false).unwrap();
        } else {
            let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
            controller.set_scene_capturing(handle, true).unwrap();
            ops.fail(Some(Step::Stop));
            assert!(controller.set_scene_capturing(handle, false).is_err());
            assert!(controller.backend().is_running());
            assert!(controller.backend().has_pending_cleanup());
            assert!(!controller.is_capturing());
            assert!(controller.set_scene_capturing(handle, true).is_err());
            assert_eq!(controller.backend().opens(), 1);
            ops.fail(None);
            controller.set_scene_capturing(handle, true).unwrap();
            controller.backend().assert_healthy();
            assert_eq!(controller.backend().opens(), 2);
            controller.set_scene_capturing(handle, false).unwrap();
        }
    }
}

#[test]
fn pending_cleanup_never_bypasses_permission_in_either_controller() {
    for legacy in [false, true] {
        let backend = RecoveryBackend::new();
        let ops = backend.ops.clone();
        let control = backend.control.clone();
        let handle = SceneHandle::new(16);
        if legacy {
            let mut controller = AudioResponseController::new(Arc::new(Consumer), backend);
            controller.set_scene_enabled(handle, true).unwrap();
            ops.fail(Some(Step::Tap));
            assert!(controller.set_scene_enabled(handle, false).is_err());
            ops.fail(None);
            control.lock().unwrap().permission = false;
            controller.set_scene_enabled(handle, true).unwrap();
            assert!(!controller.is_capturing());
            assert!(controller.backend().has_pending_cleanup());
            assert_eq!(controller.backend().opens(), 1);
            controller.request_permission().unwrap();
            controller.backend().assert_healthy();
            assert_eq!(controller.backend().opens(), 2);
            controller.set_scene_enabled(handle, false).unwrap();
        } else {
            let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
            controller.set_scene_capturing(handle, true).unwrap();
            ops.fail(Some(Step::Tap));
            assert!(controller.set_scene_capturing(handle, false).is_err());
            ops.fail(None);
            control.lock().unwrap().permission = false;
            controller.set_scene_capturing(handle, true).unwrap();
            assert!(!controller.is_capturing());
            assert!(controller.backend().has_pending_cleanup());
            assert_eq!(controller.backend().opens(), 1);
            controller.request_permission().unwrap();
            controller.backend().assert_healthy();
            assert_eq!(controller.backend().opens(), 2);
            controller.set_scene_capturing(handle, false).unwrap();
        }
    }
}

#[test]
fn both_controller_drops_attempt_pending_cleanup_without_unbounded_retry() {
    for legacy in [false, true] {
        let backend = RecoveryBackend::new();
        let ops = backend.ops.clone();
        let handle = SceneHandle::new(17);
        let callback;
        ops.fail(Some(Step::IoProc));
        if legacy {
            let mut controller = AudioResponseController::new(Arc::new(Consumer), backend);
            controller.set_scene_enabled(handle, true).unwrap();
            assert!(controller.set_scene_enabled(handle, false).is_err());
            callback = controller
                .backend()
                .capture
                .state
                .as_ref()
                .unwrap()
                .callback;
            ops.0.lock().unwrap().calls.clear();
            drop(controller);
        } else {
            let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
            controller.set_scene_capturing(handle, true).unwrap();
            assert!(controller.set_scene_capturing(handle, false).is_err());
            callback = controller
                .backend()
                .capture
                .state
                .as_ref()
                .unwrap()
                .callback;
            ops.0.lock().unwrap().calls.clear();
            drop(controller);
        }
        // One controller cleanup attempt, then one bounded CaptureState Drop.
        assert_eq!(ops.calls(), [Step::IoProc, Step::IoProc]);
        // No native callback was registered by this fake, so reclaim the block
        // deliberately retained by failed Drop after both owners are gone.
        drop(unsafe { Box::from_raw(callback) });
    }
}

// Stall watch: the real controller and the real I/O callback, with the clock
// injected as one `Instant` per check, the way the capture worker runs it once
// a second.

/// A controller whose scene wants capture and whose tap is running.
fn watched_controller() -> AudioCaptureController<RecoveryBackend> {
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), RecoveryBackend::new());
    assert!(!controller.watches_tap_stall(), "no tap runs, so nothing is checked");
    controller
        .set_scene_capturing(SceneHandle::new(21), true)
        .unwrap();
    assert!(controller.watches_tap_stall());
    controller
}

/// Core Audio calling the running tap once with a buffer of zeros, as it does
/// while nothing plays.
fn call_back_with_silence(controller: &AudioCaptureController<RecoveryBackend>) {
    let callback = controller
        .backend()
        .capture
        .state
        .as_ref()
        .expect("a tap runs")
        .callback;
    let mut samples = [0.0_f32; 2 * 64];
    let mut list = AudioBufferList {
        mNumberBuffers: 1,
        mBuffers: [AudioBuffer {
            mNumberChannels: 2,
            mDataByteSize: mem::size_of_val(&samples) as u32,
            mData: samples.as_mut_ptr().cast(),
        }],
    };
    let list = NonNull::from(&mut list);
    let mut timestamp: AudioTimeStamp = unsafe { mem::zeroed() };
    let timestamp = NonNull::from(&mut timestamp);
    let status = unsafe {
        io_callback(20, timestamp, list, timestamp, list, timestamp, callback.cast())
    };
    assert_eq!(status, 0);
}

/// One check of the capture worker at `now`: a stalled tap is rebuilt.
fn check(controller: &mut AudioCaptureController<RecoveryBackend>, now: Instant) -> TapStallCheck {
    let found = controller.check_tap_stall(now);
    if found == TapStallCheck::Stalled {
        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);
    }
    found
}

fn at(base: Instant, seconds: u64) -> Instant {
    base + Duration::from_secs(seconds)
}

fn permission_requests(controller: &AudioCaptureController<RecoveryBackend>) -> usize {
    controller.backend().control.lock().unwrap().permission_requests
}

#[test]
fn a_tap_that_stops_calling_back_is_rebuilt_once_after_three_seconds() {
    let mut controller = watched_controller();
    let requests = permission_requests(&controller);
    let base = Instant::now();
    call_back_with_silence(&controller);
    for second in 0..3 {
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Healthy);
    }
    assert_eq!(controller.backend().opens(), 1, "under 3 s without callbacks is no stall");

    assert_eq!(check(&mut controller, at(base, 3)), TapStallCheck::Stalled);
    assert_eq!(controller.backend().opens(), 2, "the silent tap is replaced");
    controller.backend().assert_healthy();

    let mut found = Vec::new();
    for second in 4..30 {
        call_back_with_silence(&controller);
        found.push(check(&mut controller, at(base, second)));
    }
    assert_eq!(found[0], TapStallCheck::Recovered, "the new tap's first callback is reported");
    assert!(found[1..].iter().all(|&check| check == TapStallCheck::Healthy));
    assert_eq!(controller.backend().opens(), 2, "a tap that calls back is left alone");
    assert_eq!(
        permission_requests(&controller),
        requests,
        "a rebuild never asks for permission again"
    );
}

#[test]
fn silence_an_idle_output_or_suspension_never_rebuild_the_tap() {
    let mut controller = watched_controller();
    let base = Instant::now();
    for second in 0..30 {
        call_back_with_silence(&controller);
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Healthy);
    }

    // Nothing plays and the output device stops: no callback is expected.
    controller.backend().control.lock().unwrap().output_running = false;
    for second in 30..60 {
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Healthy);
    }
    assert_eq!(controller.backend().opens(), 1);

    // The device runs again: only three seconds of it running without a
    // callback stall, counted from the first check that finds it running.
    controller.backend().control.lock().unwrap().output_running = true;
    for second in 60..63 {
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Healthy);
    }
    assert_eq!(check(&mut controller, at(base, 63)), TapStallCheck::Stalled);
    assert_eq!(controller.backend().opens(), 2);

    // A paused display suspends capture: nothing is checked or rebuilt.
    controller.set_demand(true, false).unwrap();
    assert!(!controller.watches_tap_stall());
    for second in 64..80 {
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Idle);
    }
    assert_eq!(controller.backend().opens(), 2);

    // Resuming starts a fresh tap with a fresh wait.
    controller.set_demand(false, false).unwrap();
    assert!(controller.watches_tap_stall());
    for second in 80..83 {
        assert_eq!(check(&mut controller, at(base, second)), TapStallCheck::Healthy);
    }
    controller
        .set_scene_capturing(SceneHandle::new(21), false)
        .unwrap();
    assert!(!controller.watches_tap_stall(), "the watch ends with the last consumer");
    assert_eq!(check(&mut controller, at(base, 90)), TapStallCheck::Idle);
    assert_eq!(
        controller.backend().opens(),
        3,
        "the first tap, the one stall rebuild and the resume"
    );
}

#[test]
fn stall_rebuilds_stop_after_three_a_minute_until_a_demand_change() {
    let mut controller = watched_controller();
    let base = Instant::now();
    // Every tap on this device stays silent while the device runs.
    let (mut stalls, mut gave_up) = (0, 0);
    for second in 0..60 {
        match check(&mut controller, at(base, second)) {
            TapStallCheck::Stalled => stalls += 1,
            TapStallCheck::GaveUp => gave_up += 1,
            _ => {}
        }
    }
    assert_eq!(stalls, TAP_STALL_REBUILD_LIMIT);
    assert_eq!(gave_up, 1, "giving up is reported once");
    assert_eq!(controller.backend().opens(), 1 + TAP_STALL_REBUILD_LIMIT);
    assert!(!controller.watches_tap_stall(), "a watch that gave up schedules no check");
    controller.backend().assert_healthy();

    // A web page asking for audio is a demand change: the budget starts over.
    controller.set_demand(false, true).unwrap();
    assert!(controller.watches_tap_stall());
    assert_eq!(check(&mut controller, at(base, 60)), TapStallCheck::Stalled);
    assert_eq!(controller.backend().opens(), 2 + TAP_STALL_REBUILD_LIMIT);
}

#[test]
fn the_rebuild_limit_counts_only_the_last_minute() {
    let mut controller = watched_controller();
    let base = Instant::now();
    // The tap goes quiet for three seconds out of every 25.
    let mut stalls = 0;
    for second in 0..200 {
        if second % 25 < 22 {
            call_back_with_silence(&controller);
        }
        match check(&mut controller, at(base, second)) {
            TapStallCheck::Stalled => stalls += 1,
            TapStallCheck::GaveUp => panic!("three stalls are never within a minute here"),
            _ => {}
        }
    }
    assert_eq!(stalls, 8);
    assert!(controller.watches_tap_stall());
}
