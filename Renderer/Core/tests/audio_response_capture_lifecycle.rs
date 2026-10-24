//! The audio-response controller owns system audio capture: it runs while at
//! least one scene wants it and permission is held, and not otherwise.

use std::sync::{Arc, Mutex};

use wallpaper_core::{
    media::audio::{
        AudioCaptureBackend, AudioCaptureError, AudioFrameConsumer, AudioResponseController,
        AudioResponseEngine, InterleavedStereoF32, MonoPcmF32,
    },
    project::SceneHandle,
};

/// An engine that only remembers which scenes were switched, in order.
#[derive(Default)]
struct ToggleLog {
    toggles: Mutex<Vec<(u64, bool)>>,
}

impl ToggleLog {
    fn entries(&self) -> Vec<(u64, bool)> {
        self.toggles.lock().unwrap().clone()
    }
}

impl AudioFrameConsumer for ToggleLog {
    fn submit_audio_frames(&self, _: InterleavedStereoF32<'_>) -> Result<(), AudioCaptureError> {
        Ok(())
    }

    fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
        Ok(())
    }
}

impl AudioResponseEngine for ToggleLog {
    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        self.toggles.lock().unwrap().push((handle.raw(), enabled));
        Ok(())
    }
}

/// A capture backend that counts what it is asked to do.
struct CountingBackend {
    permitted: bool,
    running: bool,
    starts: usize,
    stops: usize,
    permission_requests: usize,
}

impl CountingBackend {
    fn new(permitted: bool) -> Self {
        Self { permitted, running: false, starts: 0, stops: 0, permission_requests: 0 }
    }
}

impl AudioCaptureBackend for CountingBackend {
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(self.permitted)
    }

    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        self.permission_requests += 1;
        self.permitted = true;
        Ok(true)
    }

    fn start(&mut self, _: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        self.starts += 1;
        self.running = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        self.stops += 1;
        self.running = false;
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.running
    }
}

fn controller(
    permitted: bool,
) -> (Arc<ToggleLog>, AudioResponseController<ToggleLog, CountingBackend>) {
    let engine = Arc::new(ToggleLog::default());
    let controller = AudioResponseController::new(Arc::clone(&engine), CountingBackend::new(permitted));
    (engine, controller)
}

#[test]
fn the_first_enabled_scene_starts_capture_when_permission_is_held() {
    let (engine, mut controller) = controller(true);

    controller.set_scene_enabled(SceneHandle::new(7), true).unwrap();

    assert_eq!(engine.entries(), vec![(7, true)]);
    assert!(controller.is_capturing());
    assert_eq!(controller.backend().starts, 1);
}

#[test]
fn disabling_the_last_scene_stops_capture_once() {
    let (engine, mut controller) = controller(true);

    controller.set_scene_enabled(SceneHandle::new(9), true).unwrap();
    controller.set_scene_enabled(SceneHandle::new(9), false).unwrap();

    assert!(!controller.is_capturing());
    assert_eq!(controller.backend().stops, 1);
    assert_eq!(engine.entries(), vec![(9, true), (9, false)]);
}

#[test]
fn granting_permission_starts_capture_for_a_scene_that_was_already_waiting() {
    let (_engine, mut controller) = controller(false);

    controller.set_scene_enabled(SceneHandle::new(11), true).unwrap();
    assert!(!controller.is_capturing());
    assert_eq!(controller.backend().starts, 0);

    assert_eq!(controller.request_permission(), Ok(true));

    assert!(controller.is_capturing());
    assert_eq!(controller.backend().permission_requests, 1);
    assert_eq!(controller.backend().starts, 1);
}

#[test]
fn the_active_scene_count_follows_which_scenes_are_enabled() {
    let (_engine, mut controller) = controller(true);

    controller.set_scene_enabled(SceneHandle::new(42), true).unwrap();
    assert!(controller.is_capturing());
    assert_eq!(controller.active_scene_count(), 1);

    controller.set_scene_enabled(SceneHandle::new(42), false).unwrap();
    assert!(!controller.is_capturing());
    assert_eq!(controller.active_scene_count(), 0);
}

#[test]
fn capture_keeps_running_while_another_scene_still_wants_it() {
    let (_engine, mut controller) = controller(true);

    controller.set_scene_enabled(SceneHandle::new(1), true).unwrap();
    controller.set_scene_enabled(SceneHandle::new(2), true).unwrap();
    controller.set_scene_enabled(SceneHandle::new(1), false).unwrap();

    assert!(controller.is_capturing());
    assert_eq!(controller.active_scene_count(), 1);
    assert_eq!(controller.backend().starts, 1);
    assert_eq!(controller.backend().stops, 0);
}
