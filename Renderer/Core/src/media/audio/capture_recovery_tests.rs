// Device-free recovery regressions: real controllers and session ownership,
// with only native setup/teardown replaced at the lifecycle boundary.
use super::*;
use crate::{
    media::audio::{AudioCaptureController, AudioResponseEngine, RestartOutcome},
    project::SceneHandle,
};

struct Control {
    opens: usize,
    permission: bool,
    fail_setup: bool,
    report_native_running: bool,
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
                fail_setup: false,
                report_native_running: false,
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
        self.control.lock().unwrap().permission = true;
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
