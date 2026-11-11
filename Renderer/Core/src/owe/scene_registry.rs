//! Synchronous, lifetime-safe access to live scene state.
//!
//! The values a settings pane shows — how a scene is being updated, which
//! backend drew it — live behind a raw renderer pointer the engine actor owns.
//! Reading them must not block the caller on the actor's mailbox: a settings
//! snapshot is built on the bridge actor, and making it wait on the engine
//! actor would turn any engine stall into a frozen panel.
//!
//! So scenes publish themselves here when they open and withdraw before they
//! are destroyed, both under this registry's lock. A reader holding the lock
//! therefore cannot observe a pointer whose scene is being torn down, and the
//! reads themselves are relaxed atomic loads inside the renderer.

use std::{
    collections::BTreeMap,
    ptr::NonNull,
    sync::{Arc, Mutex},
};

use super::{
    scene_demand::{
        SceneBackend, SceneDemandReasons, SceneFailure, SceneFailureStage, SceneRuntimeReport,
        SceneUpdateMode, SceneVideoPath, SurfaceHealth,
    },
    sys,
};

/// A live scene pointer plus the display it presents on.
struct Entry {
    display_id: u32,
    scene: NonNull<sys::owe_scene_wallpaper>,
}

// SAFETY: the pointer is only ever passed back to the renderer's pull-only
// state getters, which read atomics and take no renderer locks. The registry's
// own mutex is what keeps the pointee alive for the duration of a read: a scene
// withdraws under the same lock before it is destroyed.
unsafe impl Send for Entry {}

/// Scenes currently open, keyed by engine handle.
#[derive(Clone, Default)]
pub struct SceneRegistry {
    entries: Arc<Mutex<BTreeMap<u64, Entry>>>,
}

impl SceneRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The registry for this process.
    ///
    /// Process-wide because the renderer it describes is: OWE is statically
    /// linked and `OweBackend` is a unit struct. Threading an instance through
    /// the actor would add a parameter to every scene call site without making
    /// anything more isolated than the renderer already is.
    #[must_use]
    pub fn shared() -> Self {
        static SHARED: std::sync::OnceLock<SceneRegistry> = std::sync::OnceLock::new();
        SHARED.get_or_init(SceneRegistry::default).clone()
    }

    /// Publishes a scene. Replacing an existing handle is normal: a display
    /// whose scene is rebuilt reuses its handle.
    pub fn register(
        &self,
        handle: u64,
        display_id: u32,
        scene: NonNull<sys::owe_scene_wallpaper>,
    ) {
        let mut entries = self.lock();
        entries.insert(handle, Entry { display_id, scene });
    }

    /// Withdraws a scene. **Must** be called before the scene is destroyed, or
    /// a reader could hold a pointer to freed memory.
    pub fn unregister(&self, handle: u64) {
        let mut entries = self.lock();
        entries.remove(&handle);
    }

    /// One row per open scene, in handle order.
    ///
    /// A scene the renderer declines to describe still produces a row, with
    /// `None` fields. Omitting it would make "running but unreadable"
    /// indistinguishable from "nothing running".
    #[must_use]
    pub fn reports(&self) -> Vec<SceneRuntimeReport> {
        let entries = self.lock();
        entries
            .iter()
            .map(|(handle, entry)| {
                let raw = entry.scene.as_ptr().cast::<std::ffi::c_void>();
                // SAFETY: the entry is alive for as long as this lock is held,
                // and each of these reads is a relaxed atomic load in the
                // renderer with no further locking.
                let (mode, reasons, backend, video_path, optimization_applied, surface) = unsafe {
                    (
                        sys::owe_scene_wallpaper_update_mode(raw),
                        sys::owe_scene_wallpaper_demand_reasons(raw),
                        sys::owe_scene_wallpaper_backend(raw),
                        sys::owe_scene_wallpaper_video_path(raw),
                        sys::owe_scene_wallpaper_scene_optimization_applied(raw),
                        read_surface_health(raw),
                    )
                };
                SceneRuntimeReport {
                    display_id: entry.display_id,
                    handle: *handle,
                    update_mode: SceneUpdateMode::from_raw(mode),
                    demand_reasons: SceneDemandReasons::from_raw(reasons),
                    backend: SceneBackend::from_raw(backend),
                    // SAFETY: as above, the entry is alive while the lock is held.
                    failure: unsafe { read_failure(raw) },
                    video_path: SceneVideoPath::from_raw(video_path),
                    // Anything the renderer cannot answer stays unknown rather
                    // than becoming "applied", which would read as evidence.
                    optimization_applied: match optimization_applied {
                        0 => Some(false),
                        1 => Some(true),
                        _ => None,
                    },
                    surface,
                    // SAFETY: as above, the entry is alive while the lock is held.
                    quality_in_force: unsafe { read_quality_in_force(raw) },
                }
            })
            .collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<u64, Entry>> {
        // A panic while holding this lock leaves the map intact: every mutation
        // is a single insert or remove. Recovering is better than poisoning the
        // settings pane for the rest of the session.
        self.entries.lock().unwrap_or_else(|error| error.into_inner())
    }
}

/// Reads the surface's frame-loop health.
///
/// `None` when the renderer declines to answer, which stays distinct from a
/// healthy reading: a caller that acts on "stopped" must not mistake "unread"
/// for "running".
///
/// # Safety
///
/// `raw` must point to a live scene.
pub(super) unsafe fn read_surface_health(raw: *mut std::ffi::c_void) -> Option<SurfaceHealth> {
    let mut out = sys::owe_surface_health::default();
    // SAFETY: `out` is a valid, writable struct for the duration of the call.
    if unsafe { sys::owe_scene_wallpaper_surface_health(raw, &mut out) } != 0 {
        return None;
    }
    Some(SurfaceHealth::from_raw(
        out.frames_completed,
        out.frames_presented,
        out.failed_frames,
        out.last_present_age_ms,
        out.stop_reason,
    ))
}

/// Reads why the scene is held, when it is.
///
/// `None` for a scene that is drawing, one that fell back, and a stage this build
/// does not name. A stage without a reason still reports, with an empty reason:
/// the category is the part the host words for the user.
///
/// # Safety
///
/// `raw` must point to a live scene.
unsafe fn read_failure(raw: *mut std::ffi::c_void) -> Option<SceneFailure> {
    let stage = SceneFailureStage::from_raw(unsafe { sys::owe_scene_wallpaper_backend_failure(raw) })?;
    let needed =
        unsafe { sys::owe_scene_wallpaper_backend_failure_reason(raw, std::ptr::null_mut(), 0) };
    let mut reason = String::new();
    if needed > 0 {
        let mut buffer = vec![0u8; needed + 1];
        let written = unsafe {
            sys::owe_scene_wallpaper_backend_failure_reason(
                raw,
                buffer.as_mut_ptr().cast::<std::os::raw::c_char>(),
                buffer.len(),
            )
        };
        if written > 0 {
            let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
            buffer.truncate(end);
            reason = String::from_utf8_lossy(&buffer).into_owned();
        }
    }
    Some(SceneFailure { stage, reason })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_registry_reports_no_rows() {
        assert!(SceneRegistry::new().reports().is_empty());
    }

    #[test]
    fn unregistering_a_handle_that_was_never_registered_is_harmless() {
        let registry = SceneRegistry::new();
        registry.unregister(7);
        assert!(registry.reports().is_empty());
    }
}

/// # Safety
///
/// `raw` must point at a live scene for the duration of the call.
unsafe fn read_quality_in_force(raw: *mut std::ffi::c_void) -> Option<crate::project::SceneQuality> {
    let mut out = sys::owe_scene_quality {
        msaa: 0,
        shadows: 0,
        volumetrics: 0,
        reflection: false,
        post_processing: 0,
    };
    // SAFETY: the caller keeps `raw` alive; `out` is a valid local.
    let status = unsafe { sys::owe_scene_wallpaper_quality_in_force(raw, &raw mut out) };
    if status != 0 {
        return None;
    }
    crate::project::SceneQuality::from_raw(
        out.msaa,
        out.shadows,
        out.volumetrics,
        out.reflection,
        out.post_processing,
    )
}
