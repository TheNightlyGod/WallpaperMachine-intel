use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

#[path = "capture_recovery_tests.rs"]
mod recovery_tests;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Stop,
    IoProc,
    Aggregate,
    Tap,
}

#[derive(Default)]
struct Trace {
    calls: Vec<Step>,
    fail: Option<Step>,
    fail_once: bool,
}

#[derive(Clone, Default)]
struct FakeTeardown(Arc<Mutex<Trace>>);

impl FakeTeardown {
    fn call(&self, step: Step) -> i32 {
        let mut trace = self.0.lock().unwrap();
        trace.calls.push(step);
        if trace.fail == Some(step) {
            if trace.fail_once {
                trace.fail = None;
                trace.fail_once = false;
            }
            -1
        } else {
            0
        }
    }

    fn fail(&self, step: Option<Step>) {
        self.0.lock().unwrap().fail = step;
    }

    fn calls(&self) -> Vec<Step> {
        self.0.lock().unwrap().calls.clone()
    }
}

impl TeardownOperations for FakeTeardown {
    fn stop(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32 {
        assert_eq!(aggregate, 20);
        assert!(io_proc.is_some());
        self.call(Step::Stop)
    }
    fn destroy_io_proc(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32 {
        assert_eq!(aggregate, 20);
        assert!(io_proc.is_some());
        self.call(Step::IoProc)
    }
    fn destroy_aggregate(&mut self, aggregate: AudioObjectID) -> i32 {
        assert_eq!(aggregate, 20);
        self.call(Step::Aggregate)
    }
    fn destroy_tap(&mut self, tap: AudioObjectID) -> i32 {
        assert_eq!(tap, 10);
        self.call(Step::Tap)
    }
}

struct Consumer;
impl AudioFrameConsumer for Consumer {
    fn submit_audio_frames(&self, _: InterleavedStereoF32<'_>) -> Result<(), AudioCaptureError> {
        Ok(())
    }
    fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
        Ok(())
    }
}

fn populate(state: &mut CaptureState<FakeTeardown>, consumer: Arc<dyn AudioFrameConsumer>) {
    state.tap = Some(10);
    state.aggregate = Some(20);
    state.io_proc = Some(io_callback);
    state.running = true;
    state.callback = Box::into_raw(Box::new(CallbackState {
        consumer,
        channel_mode: AudioTapChannelMode::Stereo,
        sample_rate: 48_000,
        scratch: Mutex::new(vec![0.0; CALLBACK_CHUNK_FRAMES * 2]),
    }));
}

fn owner(ops: &FakeTeardown, consumer: Arc<dyn AudioFrameConsumer>) -> CaptureOwner<FakeTeardown> {
    let mut state = CaptureState::with_teardown(ops.clone());
    populate(&mut state, consumer);
    CaptureOwner { state: Some(state) }
}

fn failed_release_retries(step: Step) {
    let ops = FakeTeardown::default();
    ops.fail(Some(step));
    let consumer = Arc::new(Consumer);
    let weak = Arc::downgrade(&consumer);
    let mut capture = owner(&ops, consumer);
    let error = capture.stop().unwrap_err();
    let operation = match step {
        Step::Stop => "AudioDeviceStop",
        Step::IoProc => "AudioDeviceDestroyIOProcID",
        Step::Aggregate => "AudioHardwareDestroyAggregateDevice",
        Step::Tap => "AudioHardwareDestroyProcessTap",
    };
    assert!(error.to_string().contains(operation));
    assert!(!capture.is_running());
    assert!(
        capture.has_pending_cleanup(),
        "controller must still see an owned session to retry stop"
    );
    let state = capture
        .state
        .as_ref()
        .expect("failed stop must retain its state");
    assert_eq!(state.running, step == Step::Stop);
    assert_eq!(
        state.io_proc.is_some(),
        matches!(step, Step::Stop | Step::IoProc)
    );
    assert_eq!(state.aggregate.is_some(), step != Step::Tap);
    assert_eq!(state.tap, Some(10));
    assert_eq!(weak.upgrade().is_some(), step != Step::Tap);

    let order = [Step::Stop, Step::IoProc, Step::Aggregate, Step::Tap];
    let index = order
        .iter()
        .position(|&candidate| candidate == step)
        .unwrap();
    assert_eq!(ops.calls(), order[..=index]);
    ops.fail(None);
    capture.stop().unwrap();
    assert!(!capture.is_running());
    assert!(!capture.has_pending_cleanup());
    assert!(capture.state.is_none());
    assert!(
        weak.upgrade().is_none(),
        "callback storage must eventually be reclaimed"
    );
    let expected: Vec<_> = order[..=index]
        .iter()
        .chain(&order[index..])
        .copied()
        .collect();
    assert_eq!(
        ops.calls(),
        expected,
        "successful destructive calls must not repeat"
    );
    capture.stop().unwrap();
    capture.stop().unwrap();
    assert_eq!(ops.calls(), expected);
}

#[test]
fn stop_failure_retains_session_and_callback_for_retry() {
    failed_release_retries(Step::Stop);
}

#[test]
fn io_proc_failure_retains_session_and_callback_for_retry() {
    failed_release_retries(Step::IoProc);
}

#[test]
fn aggregate_failure_retains_session_and_callback_for_retry() {
    failed_release_retries(Step::Aggregate);
}

#[test]
fn tap_failure_retains_session_for_retry() {
    failed_release_retries(Step::Tap);
}

#[test]
fn start_cannot_open_another_capture_until_cleanup_succeeds() {
    for step in [Step::Stop, Step::IoProc, Step::Aggregate, Step::Tap] {
        let ops = FakeTeardown::default();
        ops.fail(Some(step));
        let mut capture = owner(&ops, Arc::new(Consumer));
        assert!(capture.stop().is_err());
        let opens = AtomicUsize::new(0);
        let start = |capture: &mut CaptureOwner<FakeTeardown>| {
            capture.start_with(
                || CaptureState::with_teardown(ops.clone()),
                |state| {
                    opens.fetch_add(1, Ordering::Relaxed);
                    populate(state, Arc::new(Consumer));
                    Ok(())
                },
            )
        };
        assert!(start(&mut capture).is_err());
        assert_eq!(opens.load(Ordering::Relaxed), 0);
        ops.fail(None);
        start(&mut capture).unwrap();
        assert_eq!(opens.load(Ordering::Relaxed), 1);
        start(&mut capture).unwrap();
        assert_eq!(opens.load(Ordering::Relaxed), 1);
        capture.stop().unwrap();
    }
}

#[test]
fn callback_remains_callable_after_failed_teardown_until_release() {
    struct FrameCounter(AtomicUsize);
    impl AudioFrameConsumer for FrameCounter {
        fn submit_audio_frames(
            &self,
            frames: InterleavedStereoF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            assert_eq!(frames.sample_rate(), 48_000);
            assert_eq!(frames.samples(), &[0.25, -0.5]);
            self.0
                .fetch_add(frames.frame_count() as usize, Ordering::Relaxed);
            Ok(())
        }
        fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
            panic!("stereo callback must not submit mono");
        }
    }
    for step in [Step::Stop, Step::IoProc, Step::Aggregate] {
        let ops = FakeTeardown::default();
        ops.fail(Some(step));
        let consumer = Arc::new(FrameCounter(AtomicUsize::new(0)));
        let mut capture = owner(&ops, consumer.clone());
        assert!(capture.stop().is_err());
        let callback = capture.state.as_ref().unwrap().callback;
        assert!(!callback.is_null());
        let mut samples = [0.25_f32, -0.5];
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
        assert_eq!(
            unsafe {
                io_callback(
                    20,
                    timestamp,
                    list,
                    timestamp,
                    list,
                    timestamp,
                    callback.cast(),
                )
            },
            0
        );
        assert_eq!(consumer.0.load(Ordering::Relaxed), 1);
        ops.fail(None);
        capture.stop().unwrap();
        assert_eq!(Arc::strong_count(&consumer), 1);
    }
}

#[test]
fn failed_setup_retains_failed_cleanup_and_reports_setup_error_first() {
    let ops = FakeTeardown::default();
    ops.fail(Some(Step::IoProc));
    let mut capture = CaptureOwner { state: None };
    let setup_error = AudioCaptureError::Platform("injected setup failure".into());
    let error = capture
        .start_with(
            || CaptureState::with_teardown(ops.clone()),
            |state| {
                populate(state, Arc::new(Consumer));
                Err(setup_error.clone())
            },
        )
        .unwrap_err();
    assert_eq!(error, setup_error);
    assert!(!capture.is_running());
    assert!(capture.has_pending_cleanup());
    assert_eq!(ops.calls(), [Step::Stop, Step::IoProc]);
    let creates = AtomicUsize::new(0);
    assert!(
        capture
            .start_with(
                || {
                    creates.fetch_add(1, Ordering::Relaxed);
                    CaptureState::with_teardown(ops.clone())
                },
                |_| Ok(()),
            )
            .is_err()
    );
    assert_eq!(creates.load(Ordering::Relaxed), 0);
    ops.fail(None);
    capture.stop().unwrap();
    assert!(!capture.is_running());
    assert_eq!(
        ops.calls(),
        [
            Step::Stop,
            Step::IoProc,
            Step::IoProc,
            Step::IoProc,
            Step::Aggregate,
            Step::Tap
        ]
    );
}

#[test]
fn successful_stop_is_idempotent_and_reclaims_callback() {
    let ops = FakeTeardown::default();
    let consumer = Arc::new(Consumer);
    let weak = Arc::downgrade(&consumer);
    let mut capture = owner(&ops, consumer);
    capture.stop().unwrap();
    capture.stop().unwrap();
    assert_eq!(
        ops.calls(),
        [Step::Stop, Step::IoProc, Step::Aggregate, Step::Tap]
    );
    assert!(weak.upgrade().is_none());
}

#[test]
fn persistent_drop_failure_keeps_callback_alive_without_looping() {
    for (index, step) in [Step::Stop, Step::IoProc, Step::Aggregate, Step::Tap]
        .into_iter()
        .enumerate()
    {
        let ops = FakeTeardown::default();
        ops.fail(Some(step));
        let consumer = Arc::new(Consumer);
        let weak = Arc::downgrade(&consumer);
        let capture = owner(&ops, consumer);
        let callback = capture.state.as_ref().unwrap().callback;
        drop(capture);
        let order = [Step::Stop, Step::IoProc, Step::Aggregate, Step::Tap];
        assert_eq!(
            ops.calls(),
            order[..=index],
            "Drop makes one bounded cleanup attempt"
        );
        if step == Step::Tap {
            assert!(
                weak.upgrade().is_none(),
                "destroyed IOProc cannot retain the consumer"
            );
        } else {
            assert!(weak.upgrade().is_some());
            // This fake never registered a callback with CoreAudio. Reclaim the
            // deliberately retained block after proving Drop left it alive.
            drop(unsafe { Box::from_raw(callback) });
            assert!(weak.upgrade().is_none());
        }
    }
}

struct Backend {
    capture: CaptureOwner<FakeTeardown>,
    ops: FakeTeardown,
}

impl AudioCaptureBackend for Backend {
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(true)
    }
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        Ok(true)
    }
    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        self.capture.start_with(
            || CaptureState::with_teardown(self.ops.clone()),
            |state| {
                populate(state, consumer);
                Ok(())
            },
        )
    }
    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        self.capture.stop()
    }
    fn is_running(&self) -> bool {
        self.capture.is_running()
    }
    fn has_pending_cleanup(&self) -> bool {
        self.capture.has_pending_cleanup()
    }
}

#[test]
fn controller_removal_and_demand_off_retry_after_native_stop_succeeded() {
    use super::super::AudioCaptureController;
    use crate::project::SceneHandle;

    for removal in 0..3 {
        let ops = FakeTeardown::default();
        let backend = Backend {
            capture: CaptureOwner { state: None },
            ops: ops.clone(),
        };
        let mut controller = AudioCaptureController::new(Arc::new(Consumer), backend);
        let handle = SceneHandle::new(7);
        if removal == 2 {
            controller.set_demand(false, true).unwrap();
        } else {
            controller.set_scene_capturing(handle, true).unwrap();
        }
        ops.fail(Some(Step::IoProc));
        let remove = |controller: &mut AudioCaptureController<Backend>| match removal {
            0 => controller.set_scene_capturing(handle, false),
            1 => controller.retain_scenes(&[]),
            _ => controller.set_demand(false, false),
        };
        assert!(remove(&mut controller).is_err());
        assert!(!controller.is_capturing());
        assert!(controller.backend().has_pending_cleanup());
        let mut expected = vec![Step::Stop, Step::IoProc];
        if removal == 2 {
            // Demand rollback also tries to restore actual capture. Its cleanup
            // fails at the same IOProc without repeating the successful stop.
            expected.push(Step::IoProc);
        }
        assert_eq!(ops.calls(), expected);
        ops.fail(None);
        remove(&mut controller).unwrap();
        assert!(!controller.backend().is_running());
        assert!(!controller.backend().has_pending_cleanup());
        expected.extend([Step::IoProc, Step::Aggregate, Step::Tap]);
        assert_eq!(ops.calls(), expected);
    }
}
