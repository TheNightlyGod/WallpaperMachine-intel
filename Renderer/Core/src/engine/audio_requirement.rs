//! Which live scenes read system audio, as their renderers report it.
//!
//! The system-audio tap is only worth running for a scene whose content reads
//! the spectrum: an audio-processing material or particle, a `g_AudioSpectrum*`
//! uniform, or a script that called `registerAudioBuffers`. Each renderer
//! reports that for the scene it has committed (see
//! `owe_scene_wallpaper_set_audio_requirement_callback`); the engine actor
//! folds the reports into the set held here every time it publishes, and the
//! host is told which handle changed so it can re-sync capture. Nothing polls.

use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

use crate::project::SceneHandle;

/// Told that one live scene's audio requirement changed, and its new value.
/// Runs synchronously under the observer's lock on the engine actor's thread,
/// so it must only hand the event on: no blocking, no call back into the
/// engine.
pub type AudioRequirementCallback = Arc<dyn Fn(SceneHandle, bool) + Send + Sync + 'static>;

#[derive(Default)]
struct AudioRequirementState {
    handles: HashSet<SceneHandle>,
    callback: Option<AudioRequirementCallback>,
}

#[derive(Default)]
pub struct AudioRequirementObserver {
    state: Mutex<AudioRequirementState>,
}

impl AudioRequirementObserver {
    /// Installs (or clears) the observer and replays every scene that
    /// currently reads audio, so an observer installed late misses nothing.
    pub fn set_callback(&self, callback: Option<AudioRequirementCallback>) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.callback = callback;
        if let Some(callback) = &state.callback {
            for handle in &state.handles {
                callback(*handle, true);
            }
        }
    }

    /// Whether the scene behind `handle` reads system audio. A closed or
    /// unknown handle does not.
    #[must_use]
    pub fn requires_audio(&self, handle: SceneHandle) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .handles
            .contains(&handle)
    }

    /// Replaces the set of live scenes that read audio, telling the observer
    /// about every handle that entered or left it. A scene whose renderer was
    /// rebuilt or closed leaves the set here, so an old scene's requirement
    /// never outlives it.
    pub fn publish(&self, handles: HashSet<SceneHandle>) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.handles == handles {
            return;
        }
        let previous = std::mem::replace(&mut state.handles, handles);
        let Some(callback) = state.callback.clone() else { return };
        for handle in previous.difference(&state.handles) {
            callback(*handle, false);
        }
        for handle in state.handles.difference(&previous) {
            callback(*handle, true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recorder() -> (AudioRequirementCallback, Arc<Mutex<Vec<(u64, bool)>>>) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let callback: AudioRequirementCallback = Arc::new(move |handle, requires| {
            sink.lock().unwrap().push((handle.raw(), requires));
        });
        (callback, events)
    }

    #[test]
    fn reports_each_transition_once_and_drops_departed_scenes() {
        let observer = AudioRequirementObserver::default();
        let (callback, events) = recorder();
        observer.set_callback(Some(callback));
        assert!(events.lock().unwrap().is_empty(), "nothing reads audio yet");

        observer.publish(HashSet::from([SceneHandle::new(1)]));
        observer.publish(HashSet::from([SceneHandle::new(1)]));
        assert!(observer.requires_audio(SceneHandle::new(1)));
        assert!(!observer.requires_audio(SceneHandle::new(2)));
        assert_eq!(*events.lock().unwrap(), vec![(1, true)], "a repeat is not a change");

        // Rebuilt or closed: the handle leaves, and a scene that never read
        // audio arriving on another handle is not reported at all.
        observer.publish(HashSet::new());
        assert!(!observer.requires_audio(SceneHandle::new(1)));
        assert_eq!(*events.lock().unwrap(), vec![(1, true), (1, false)]);
    }

    #[test]
    fn a_late_observer_is_replayed_the_current_set() {
        let observer = AudioRequirementObserver::default();
        observer.publish(HashSet::from([SceneHandle::new(3)]));
        let (callback, events) = recorder();
        observer.set_callback(Some(callback));
        assert_eq!(*events.lock().unwrap(), vec![(3, true)]);
    }
}
