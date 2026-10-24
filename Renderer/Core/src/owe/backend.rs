// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr::NonNull,
    sync::Arc,
};


/// One system-audio analysis result in the layout Wallpaper Engine's web audio
/// listener expects: 128 values, indices 0..=63 the left channel and 64..=127
/// the right, low index meaning low frequency.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioSpectrum128 {
    pub generation: u64,
    /// True only when the captured signal genuinely had two channels. When
    /// false the two halves are equal because the source was mono, which is
    /// not the same thing as stereo.
    pub stereo: bool,
    pub bins: [f32; AudioSpectrum128::BIN_COUNT],
}

impl AudioSpectrum128 {
    pub const BIN_COUNT: usize = 128;
}


use crate::{
    EngineError,
    media::audio::{AudioVolume, InterleavedStereoF32, MonoPcmF32},
    owe::{sys, unwind::UnwindSafeFFI},
    project::{ScalingMode, SceneDesc, SceneFraming, SerdeValudeExt},
};

#[derive(Clone, Copy, Debug, Default)]
pub struct OweBackend;

pub type FirstFrameCallback = Arc<dyn Fn() + Send + Sync + 'static>;

pub type PointerInputCallback = Arc<dyn Fn(bool) + Send + Sync + 'static>;
/// Receives one `engine.openUserShortcut` request: the property the wallpaper
/// named, and the value its user chose for it.
pub type UserShortcutCallback = Arc<dyn Fn(String, String) + Send + Sync + 'static>;
/// Receives whether the renderer's committed scene reads system audio. Called
/// on the native main looper: once on install, then on every change. A newly
/// committed scene starts at `false`; a replaced scene's late report never
/// arrives.
pub type AudioRequirementCallback = Arc<dyn Fn(bool) + Send + Sync + 'static>;
/// Told, on the native main looper, that a scene which had drawn failed a frame
/// and stopped. One call per failure and no payload; never replayed on install
/// and never raised for a failure before the first presented frame.
pub type RenderFailureCallback = Arc<dyn Fn() + Send + Sync + 'static>;


impl OweBackend {
    /// # Errors
    ///
    /// Reserved for future backend initialization failures.
    pub fn initialize() -> Result<Self, EngineError> {

        // The engine calls the rs_shader_* exports from C++ only; naming one keeps their object in the link.
        let _ = wm_shader::ffi::keep_exports_alive();

        // SAFETY: the callback is a plain function that contains its own panics.
        unsafe {
            UnwindSafeFFI::new("owe_set_log_callback")
                .call(|| sys::owe_set_log_callback(Some(owe_log_callback)))?;
        }
        Ok(Self)
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] when the OWE scene cannot be allocated or any
    /// renderer initialization/configuration call fails.
    pub fn open_scene(
        &self,
        desc: &SceneDesc,
        metal_layer: *mut c_void,
        scaling_mode: ScalingMode,
        scaling_factor: f64,
        framing: SceneFraming,
        render_resolution: Option<(u32, u32)>,
        first_frame_callback: Option<FirstFrameCallback>,
        pointer_input_callback: Option<PointerInputCallback>,
        user_shortcut_callback: Option<UserShortcutCallback>,
        audio_requirement_callback: Option<AudioRequirementCallback>,
        render_failure_callback: Option<RenderFailureCallback>,
    ) -> Result<OweScene, EngineError> {

        let display = &desc.display;
        let load = crate::log_context::begin_load(
            "scene",
            std::path::Path::new(&desc.scene_path),
            format_args!(
                "display {} {}x{} @{}x {}Hz, fps {}, scaling {scaling_mode} x{scaling_factor}, \
                 pan {},{}, render {}, paused {}",
                display.display_id,
                display.width,
                display.height,
                display.scale_factor,
                display.refresh_rate_hz,
                desc.fps,
                framing.pan_x,
                framing.pan_y,
                render_resolution.map_or_else(|| "native".to_string(), |(w, h)| format!("{w}x{h}")),
                desc.paused,
            ),
        );
        // Lines this thread logs while opening belong to the load too; the
        // scene's own threads are tagged below, before `init` starts them.
        let _scope = crate::log_context::LoadScope::enter(load);

        let mut raw: *mut sys::owe_scene_wallpaper = std::ptr::null_mut();
        call_status("owe_scene_wallpaper_new", || unsafe {
            sys::owe_scene_wallpaper_new(&raw mut raw)
        })?;
        let raw = NonNull::new(raw).ok_or_else(|| {
            EngineError::Render("open-wallpaper-engine returned no scene object".to_owned())
        })?;

        // From here on the object is owned by `scene`: any early return below shuts
        // it down and deletes it (skipping the surface release while no surface
        // exists yet) through its `Drop`.
        let mut scene = OweScene {
            raw: Some(raw),
            render_initialized: false,
            registration: None,
            load,
            previewed_properties: None,
        };

        call_status("owe_scene_wallpaper_set_log_scope", || unsafe {
            sys::owe_scene_wallpaper_set_log_scope(raw.as_ptr(), load)
        })?;
        call_status("owe_scene_wallpaper_init", || unsafe {
            sys::owe_scene_wallpaper_init(raw.as_ptr())
        })?;

        let (render_width, render_height) = render_resolution.unwrap_or((0, 0));
        call_status("owe_scene_wallpaper_init_metal", || unsafe {
            sys::owe_scene_wallpaper_init_metal(
                raw.as_ptr(),
                metal_layer,
                display.width,
                display.height,
                render_width,
                render_height,
                display.scale_factor,
            )
        })?;
        scene.render_initialized = true;

        if first_frame_callback.is_some() {
            scene.set_first_frame_callback(first_frame_callback)?;
        }
        if pointer_input_callback.is_some() {
            scene.set_pointer_input_callback(pointer_input_callback)?;
        }
        if user_shortcut_callback.is_some() {
            scene.set_user_shortcut_callback(user_shortcut_callback)?;
        }
        if audio_requirement_callback.is_some() {
            scene.set_audio_requirement_callback(audio_requirement_callback)?;
        }
        if render_failure_callback.is_some() {
            scene.set_render_failure_callback(render_failure_callback)?;
        }

        // The surface settings go before the configuration: the configuration loads the scene
        // and queues its first frame behind it, so a setting sent after it would only reach the
        // second frame, and the first would be drawn with the renderer's defaults (fit, centred).
        scene.set_scaling_mode(scaling_mode)?;
        scene.set_scaling_factor(scaling_factor)?;
        scene.set_framing(framing)?;
        scene.apply_scene_config(desc)?;
        Ok(scene)
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] when OWE rejects the audio frame upload.
    pub fn submit_audio_frames(&self, frames: InterleavedStereoF32<'_>) -> Result<(), EngineError> {
        call_status("owe_audio_submit_frames", || unsafe {
            sys::owe_audio_submit_frames(
                frames.sample_rate(),
                frames.frame_count(),
                frames.samples().as_ptr(),
            )
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] when OWE rejects the audio frame upload.
    pub fn submit_audio_mono_frames(&self, frames: &MonoPcmF32<'_>) -> Result<(), EngineError> {
        call_status("owe_audio_submit_mono_frames", || unsafe {
            sys::owe_audio_submit_mono_frames(
                frames.sample_rate(),
                frames.frame_count(),
                frames.samples().as_ptr(),
            )
        })
    }


    /// Turns renderer counting on or off for the whole process.
    ///
    /// Off is the default. Enabling adds one relaxed atomic increment to each
    /// counted event; it starts no thread, no timer and no output stream, and
    /// reading counters stays a pull.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if OWE rejects the call.
    pub fn set_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        call_status("owe_renderer_counters_set_enabled", || unsafe {
            sys::owe_renderer_counters_set_enabled(enabled)
        })
    }

    /// Turns scene render optimisation on or off for the whole renderer
    /// process. On by default; switching it off makes every pass execute every
    /// frame so the two paths can be compared directly.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the call unwinds.
    pub fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        unsafe {
            UnwindSafeFFI::new("owe_set_scene_optimization_enabled")
                .call(|| sys::owe_set_scene_optimization_enabled(enabled))
        }
    }

    /// Turns whole-scene on-demand updating on or off, process-wide.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the call unwinds.
    pub fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        unsafe {
            UnwindSafeFFI::new("owe_set_scene_on_demand_enabled")
                .call(|| sys::owe_set_scene_on_demand_enabled(enabled))
        }
    }

    /// Turns direct NV12 plane sampling on or off inside native Metal scenes,
    /// process-wide.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the call unwinds.
    pub fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        unsafe {
            UnwindSafeFFI::new("owe_set_scene_video_plane_sampling_enabled")
                .call(|| sys::owe_set_scene_video_plane_sampling_enabled(enabled))
        }
    }

    /// Chooses how many pixels a 2D scene is rasterized with, process-wide.
    ///
    /// New scenes take it when they are built; a running scene takes it the
    /// next time its render scale is applied.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the call unwinds.
    pub fn set_scene_resolution(
        &self,
        resolution: crate::SceneResolution,
    ) -> Result<(), EngineError> {
        unsafe {
            UnwindSafeFFI::new("owe_set_scene_resolution")
                .call(|| sys::owe_set_scene_resolution(resolution.as_raw()))
        }
    }

    /// Latest system-audio spectrum, or `None` when no analysis has run yet.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the call unwinds.
    pub fn current_audio_spectrum(&self) -> Result<Option<AudioSpectrum128>, EngineError> {
        let mut bins = [0.0f32; AudioSpectrum128::BIN_COUNT];
        let mut generation: u64 = 0;
        let written = unsafe {
            UnwindSafeFFI::new("owe_audio_current_spectrum_128").call(|| {
                sys::owe_audio_current_spectrum_128(
                    bins.as_mut_ptr(),
                    AudioSpectrum128::BIN_COUNT,
                    &raw mut generation,
                )
            })?
        };
        if written != 0 || generation == 0 {
            return Ok(None);
        }
        let stereo = unsafe {
            UnwindSafeFFI::new("owe_audio_spectrum_is_stereo")
                .call(|| sys::owe_audio_spectrum_is_stereo())?
        };
        Ok(Some(AudioSpectrum128 {
            generation,
            // Anything other than an explicit 1 means the analysis did not
            // carry two distinct channels. A mono source is never reported as
            // stereo just because both halves are populated.
            stereo: stereo == 1,
            bins,
        }))
    }

    /// Copies process-wide renderer counters, in `owe_renderer_shared_counter`
    /// order. These belong to no single surface.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if OWE rejects the call.
    pub fn shared_counters(&self) -> Result<Vec<u64>, EngineError> {
        let mut values = vec![0u64; sys::owe_renderer_shared_counter_OWE_RC_SHARED_COUNT as usize];
        let mut written: usize = 0;
        call_status("owe_renderer_shared_counters", || unsafe {
            sys::owe_renderer_shared_counters(values.as_mut_ptr(), values.len(), &raw mut written)
        })?;
        values.truncate(written);
        Ok(values)
    }
}

/// The value of the engine's scaling-mode property for `mode`, as the C ABI
/// numbers them. An engine that does not know a value ignores it.
pub(crate) fn scaling_mode_property_value(mode: ScalingMode) -> i32 {
    match mode {
        ScalingMode::None => 0,
        ScalingMode::Stretch => 1,
        ScalingMode::Fit => 2,
        ScalingMode::Fill => 3,
        ScalingMode::FitBlurred => 4,
    }
}

pub struct OweScene {
    raw: Option<NonNull<sys::owe_scene_wallpaper>>,
    #[allow(dead_code)]
    render_initialized: bool,
    /// Registry entry to withdraw before this scene is destroyed.
    ///
    /// Held here, not by the caller, because `Drop` also closes: a scene that
    /// is dropped without an explicit close must still withdraw, or a reader
    /// could follow a pointer into freed memory.
    registration: Option<(crate::SceneRegistry, u64)>,
    /// The load this renderer belongs to, so a line logged about it later
    /// (a recovery, say) can carry the same `load#N` as the lines that opened it.
    load: u64,
    /// The property document this renderer was last shown by
    /// [`Self::preview_property_override`], so a document it already shows is
    /// not sent again.
    ///
    /// Kept here, not by the caller, because the renderer is what shows it and
    /// what loses it: a renderer that is replaced starts without one, and a
    /// reload through [`Self::set_property_override`] or
    /// [`Self::reset_property_override`] clears it, so no path that rebuilds a
    /// scene (a descriptor change, a shader cache clear, a surface recovery
    /// after a wake or a failed frame) can leave a record of a look the scene
    /// no longer has. `None` is "shows what it loaded with", and also "not
    /// known" after an update the renderer refused.
    previewed_properties: Option<String>,
}

unsafe impl Send for OweScene {}

impl OweScene {
    fn property_name(
        operation: &'static str,
        call: impl FnOnce() -> *const c_char,
    ) -> Result<*const c_char, EngineError> {
        let name = unsafe { UnwindSafeFFI::new(operation).call(call)? };
        if name.is_null() {
            return Err(EngineError::Render(
                "open-wallpaper-engine returned a null property name".to_owned(),
            ));
        }
        Ok(name)
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn scaling_mode() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_scaling_mode", || unsafe { sys::owe_property_scaling_mode() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn scaling_factor() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_scaling_factor", || unsafe { sys::owe_property_scaling_factor() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn audio_response_enabled() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_audio_response_enabled", || unsafe { sys::owe_property_audio_response_enabled() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn media_integration_enabled() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_media_integration_enabled", || unsafe { sys::owe_property_media_integration_enabled() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn force_shader_refresh() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_force_shader_refresh", || unsafe { sys::owe_property_force_shader_refresh() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn project_property_override_json() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_project_property_override_json", || unsafe { sys::owe_property_project_property_override_json() })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn project_property_reset() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_project_property_reset", || unsafe { sys::owe_property_project_property_reset() })
    }

    /// Retrieves the name of the property that shows a project property
    /// document on the running scene without loading it again.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError::Render`] if OWE returns a null property name or
    /// [`EngineError::Crash`] if the FFI call unwinds.
    pub fn project_property_preview_json() -> Result<*const c_char, EngineError> {
        Self::property_name("owe_property_project_property_preview_json", || unsafe {
            sys::owe_property_project_property_preview_json()
        })
    }
}

impl OweScene {
    /// # Errors
    ///
    /// Returns [`EngineError`] when descriptor paths contain interior NUL
    /// bytes, project override JSON cannot be flattened, shader cache
    /// preparation fails, or OWE rejects any property/configuration update.
    pub fn apply_scene_config(&mut self, desc: &SceneDesc) -> Result<(), EngineError> {
        let source = cstring(&desc.scene_path)?;
        let assets = cstring(&desc.assets_path)?;
        let cache = desc.shader_cache_path()?.map(|path| cstring(&path)).transpose()?;
        let overrides = desc
            .property_override_json
            .as_deref()
            .map(|json| -> Result<CString, EngineError> {
                let document: serde_json::Value = serde_json::from_str(json).map_err(|error| {
                    EngineError::InvalidInput(format!("failed to parse property override: {error}"))
                })?;
                let flat = document.flatten()?;
                let text = serde_json::to_string(&flat).map_err(|error| {
                    EngineError::InvalidInput(format!("failed to encode property override: {error}"))
                })?;
                cstring(&text)
            })
            .transpose()?;

        let raw = self.raw_ptr()?;
        // The volume and mute travel with the configuration: the scene can load as soon as
        // it is configured, and its sounds play from the moment they are mounted, before a
        // later setting would be read.
        call_status("owe_scene_wallpaper_apply_config", || unsafe {
            sys::owe_scene_wallpaper_apply_config(
                raw.as_ptr(),
                source.as_ptr(),
                assets.as_ptr(),
                cache.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                desc.fps,
                desc.paused,
                f32::from(desc.audio_volume),
                desc.audio_muted,
                desc.force_shader_refresh,
                overrides.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
            )
        })?;

        self.set_audio_response_enabled(desc.audio_response_enabled)?;
        self.set_media_integration_enabled(desc.media_integration_enabled)
    }

    /// # Errors
    ///
    /// Returns [`EngineError::InvalidInput`] if the scene is already closed, or
    /// [`EngineError::Render`] if OWE fails the reconfigure-begin transaction.
    pub fn begin_surface_reconfigure(&mut self) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_begin_surface_reconfigure", || unsafe {
            sys::owe_scene_wallpaper_begin_surface_reconfigure(raw.as_ptr())
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError::InvalidInput`] if `metal_layer` is null or the
    /// scene is closed, or [`EngineError::Render`] if OWE fails the finish
    /// step.
    pub fn finish_surface_reconfigure(
        &mut self,
        metal_layer: *mut c_void,
        width: u32,
        height: u32,
        render_width: u32,
        render_height: u32,
        scale_factor: f64,
    ) -> Result<(), EngineError> {
        if metal_layer.is_null() {
            return Err(EngineError::InvalidInput(
                "metal_layer must not be null".to_owned(),
            ));
        }
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_finish_surface_reconfigure", || unsafe {
            sys::owe_scene_wallpaper_finish_surface_reconfigure(
                raw.as_ptr(),
                metal_layer,
                width,
                height,
                render_width,
                render_height,
                scale_factor,
            )
        })?;
        self.render_initialized = true;
        Ok(())
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed, OWE property lookup
    /// fails, or OWE rejects the property update.
    pub fn set_scaling_mode(&mut self, mode: ScalingMode) -> Result<(), EngineError> {
        let name = Self::scaling_mode()?;
        self.set_property_int32(name, scaling_mode_property_value(mode))
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed, OWE property lookup
    /// fails, or OWE rejects the property update.
    pub fn set_scaling_factor(&mut self, factor: f64) -> Result<(), EngineError> {
        let name = Self::scaling_factor()?;
        self.set_property_float(name, factor as f32)
    }

    /// Sets where the presented wallpaper sits inside the room its display
    /// leaves around it, live.
    ///
    /// The renderer applies it without a rebuild: nothing is reparsed and video
    /// keeps playing. The caller validates the fractions first, so a value the
    /// renderer would have to clamp never reaches it.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_framing(&mut self, framing: SceneFraming) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_framing", || unsafe {
            sys::owe_scene_wallpaper_set_framing(raw.as_ptr(), framing.pan_x, framing.pan_y)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_target_fps(&mut self, fps: u32) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_target_fps", || unsafe {
            sys::owe_scene_wallpaper_set_target_fps(raw.as_ptr(), fps)
        })
    }

    /// Sets the internal rasterization scale, live.
    ///
    /// This is the size the scene is actually rendered at, as a fraction of
    /// the surface's native pixel grid — not window scaling and not wallpaper
    /// scaling. The renderer resizes its own targets in place, so unlike
    /// [`crate::engine::WallpaperEngine::set_render_resolution`] nothing is
    /// reparsed and no video is reopened.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE cannot resize to
    /// the requested scale.
    pub fn set_render_scale(&mut self, scale: f64) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_render_scale", || unsafe {
            sys::owe_scene_wallpaper_set_render_scale(raw.as_ptr(), scale)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_paused(&mut self, paused: bool) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_paused", || unsafe {
            sys::owe_scene_wallpaper_set_paused(raw.as_ptr(), paused)
        })
    }

    /// Copies this surface's renderer work counters, in `owe_renderer_counter`
    /// order.
    ///
    /// Counting is process-wide and off by default; see
    /// [`OweBackend::set_counters_enabled`]. With it off every value is zero,
    /// which reads as "not recorded" rather than "no work".
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the call.
    pub fn counters(&self) -> Result<Vec<u64>, EngineError> {
        let raw = self.raw_ptr()?;
        let mut values = vec![0u64; sys::owe_renderer_counter_OWE_RC_COUNT as usize];
        let mut written: usize = 0;
        call_status("owe_scene_wallpaper_counters", || unsafe {
            sys::owe_scene_wallpaper_counters(
                raw.as_ptr(),
                values.as_mut_ptr(),
                values.len(),
                &raw mut written,
            )
        })?;
        values.truncate(written);
        Ok(values)
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// callback registration.
    pub fn set_first_frame_callback(
        &mut self,
        callback: Option<FirstFrameCallback>,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        let user_data = callback.map_or(std::ptr::null_mut(), |callback| {
            Box::into_raw(Box::new(callback)).cast::<c_void>()
        });
        let result = call_status("owe_scene_wallpaper_set_first_frame_callback", || unsafe {
            sys::owe_scene_wallpaper_set_first_frame_callback(
                raw.as_ptr(),
                if user_data.is_null() { None } else { Some(owe_first_frame_callback) },
                user_data,
                if user_data.is_null() { None } else { Some(owe_first_frame_callback_drop) },
            )
        });
        if result.is_err() && !user_data.is_null() {
            // A refused registration never consumes the userdata; take it back.
            drop(unsafe { Box::<FirstFrameCallback>::from_raw(user_data.cast()) });
        }
        result
    }

    pub fn set_pointer_input_callback(
        &mut self,
        callback: Option<PointerInputCallback>,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        let user_data = callback.map_or(std::ptr::null_mut(), |callback| {
            Box::into_raw(Box::new(callback)).cast::<c_void>()
        });
        let result = call_status("owe_scene_wallpaper_set_pointer_input_callback", || unsafe {
            sys::owe_scene_wallpaper_set_pointer_input_callback(
                raw.as_ptr(),
                if user_data.is_null() { None } else { Some(owe_pointer_input_callback) },
                user_data,
                if user_data.is_null() { None } else { Some(owe_pointer_input_callback_drop) },
            )
        });
        if result.is_err() && !user_data.is_null() {
            // Failed registration never consumes the caller's userdata.
            drop(unsafe { Box::<PointerInputCallback>::from_raw(user_data.cast()) });
        }
        result
    }

    /// Installs the sink for `engine.openUserShortcut` requests.
    ///
    /// The callback receives the property the wallpaper named and the value its
    /// user chose for it. What that value means is decided above this layer.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// registration.
    pub fn set_user_shortcut_callback(
        &mut self,
        callback: Option<UserShortcutCallback>,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        let user_data = callback.map_or(std::ptr::null_mut(), |callback| {
            Box::into_raw(Box::new(callback)).cast::<c_void>()
        });
        let result = call_status("owe_scene_wallpaper_set_user_shortcut_callback", || unsafe {
            sys::owe_scene_wallpaper_set_user_shortcut_callback(
                raw.as_ptr(),
                if user_data.is_null() { None } else { Some(owe_user_shortcut_callback) },
                user_data,
                if user_data.is_null() { None } else { Some(owe_user_shortcut_callback_drop) },
            )
        });
        if result.is_err() && !user_data.is_null() {
            // Failed registration never consumes the caller's userdata.
            drop(unsafe { Box::<UserShortcutCallback>::from_raw(user_data.cast()) });
        }
        result
    }

    /// Installs the sink for the committed scene's audio requirement, replayed
    /// once on install. `None` clears it.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// registration.
    pub fn set_audio_requirement_callback(
        &mut self,
        callback: Option<AudioRequirementCallback>,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        let user_data = callback.map_or(std::ptr::null_mut(), |callback| {
            Box::into_raw(Box::new(callback)).cast::<c_void>()
        });
        let result = call_status("owe_scene_wallpaper_set_audio_requirement_callback", || unsafe {
            sys::owe_scene_wallpaper_set_audio_requirement_callback(
                raw.as_ptr(),
                if user_data.is_null() { None } else { Some(owe_audio_requirement_callback) },
                user_data,
                if user_data.is_null() { None } else { Some(owe_audio_requirement_callback_drop) },
            )
        });
        if result.is_err() && !user_data.is_null() {
            // Failed registration never consumes the caller's userdata.
            drop(unsafe { Box::<AudioRequirementCallback>::from_raw(user_data.cast()) });
        }
        result
    }

    /// Installs the sink for "this scene had drawn and has now stopped after a
    /// failed frame". `None` clears it. Not replayed on install.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// registration.
    pub fn set_render_failure_callback(
        &mut self,
        callback: Option<RenderFailureCallback>,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        let user_data = callback.map_or(std::ptr::null_mut(), |callback| {
            Box::into_raw(Box::new(callback)).cast::<c_void>()
        });
        let result = call_status("owe_scene_wallpaper_set_render_failure_callback", || unsafe {
            sys::owe_scene_wallpaper_set_render_failure_callback(
                raw.as_ptr(),
                if user_data.is_null() { None } else { Some(owe_render_failure_callback) },
                user_data,
                if user_data.is_null() { None } else { Some(owe_render_failure_callback_drop) },
            )
        });
        if result.is_err() && !user_data.is_null() {
            // Failed registration never consumes the caller's userdata.
            drop(unsafe { Box::<RenderFailureCallback>::from_raw(user_data.cast()) });
        }
        result
    }

    /// The number of the load that opened this renderer; see
    /// [`crate::log_context`].
    #[must_use]
    pub fn load_id(&self) -> u64 {
        self.load
    }

    /// The surface's frame-loop health right now, or `None` when the scene is
    /// closed or the renderer returned no reading.
    #[must_use]
    pub fn surface_health(&self) -> Option<crate::owe::scene_demand::SurfaceHealth> {
        let raw = self.raw?;
        // SAFETY: `raw` is this scene's own live pointer for as long as `self`
        // holds it, and the read is a set of relaxed atomic loads.
        unsafe { super::scene_registry::read_surface_health(raw.as_ptr().cast()) }
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if coordinates are non-finite, the scene is
    /// closed, or OWE rejects the update.
    pub fn set_mouse_position(&mut self, x: f64, y: f64) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput(
                "mouse coordinates must be finite".to_owned(),
            ));
        }
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_mouse_input", || unsafe {
            sys::owe_scene_wallpaper_mouse_input(raw.as_ptr(), x, y)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the button is out of range, the scene is
    /// closed, or OWE rejects the update.
    pub fn set_mouse_button(&mut self, button: u32, pressed: bool) -> Result<(), EngineError> {
        let button = i32::try_from(button)
            .ok()
            .filter(|button| (0..=31).contains(button))
            .ok_or_else(|| {
                EngineError::InvalidInput("mouse button must be in range 0..31".to_owned())
            })?;
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_mouse_button", || unsafe {
            sys::owe_scene_wallpaper_mouse_button(raw.as_ptr(), button, pressed)
        })
    }

    /// Reconciles sampled button levels without producing or clearing edges.
    pub(crate) fn set_mouse_button_baseline(&mut self, down: u32) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_mouse_button_baseline", || unsafe {
            sys::owe_scene_wallpaper_set_mouse_button_baseline(raw.as_ptr(), down)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_mouse_entered(&mut self, entered: bool) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_mouse_enter", || unsafe {
            sys::owe_scene_wallpaper_mouse_enter(raw.as_ptr(), entered)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed, OWE property lookup
    /// fails, or OWE rejects the property update.
    pub fn set_audio_response_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        let name = Self::audio_response_enabled()?;
        self.set_property_bool(name, enabled)
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_audio_volume(&mut self, volume: AudioVolume) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_audio_volume", || unsafe {
            sys::owe_scene_wallpaper_set_audio_volume(raw.as_ptr(), f32::from(volume))
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// update.
    pub fn set_audio_muted(&mut self, muted: bool) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_audio_muted", || unsafe {
            sys::owe_scene_wallpaper_set_audio_muted(raw.as_ptr(), muted)
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed, OWE property lookup
    /// fails, or OWE rejects the property update.
    pub fn set_media_integration_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        let name = Self::media_integration_enabled()?;
        self.set_property_bool(name, enabled)
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if event serialization fails, the JSON contains
    /// an interior NUL byte, the scene is closed, or OWE rejects the event.
    pub fn submit_media_event(
        &mut self,
        event: &crate::media::MediaIntegrationEvent,
    ) -> Result<(), EngineError> {
        let json = event
            .to_json()
            .map_err(|error| EngineError::InvalidInput(error.to_string()))?;
        self.submit_media_event_json(&json)
    }

    /// Submits one SceneScript media event as already-serialized JSON.
    ///
    /// The host owns the object shape. Passing a narrower Rust model through
    /// here would drop fields such as `subTitle` and `albumArtist`.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the JSON contains an interior NUL byte, the
    /// scene is closed, or OWE rejects the event.
    pub fn submit_media_event_json(&mut self, json: &str) -> Result<(), EngineError> {
        let encoded = cstring(json)?;
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_submit_media_event_json", || unsafe {
            sys::owe_scene_wallpaper_submit_media_event_json(raw.as_ptr(), encoded.as_ptr())
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed or OWE rejects the
    /// artwork.
    pub fn apply_system_media_artwork(
        &mut self,
        artwork: &crate::media::MediaThumbnailRgba,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_apply_system_media_artwork", || unsafe {
            sys::owe_scene_wallpaper_apply_system_media_artwork(
                raw.as_ptr(),
                artwork.width,
                artwork.height,
                artwork.rgba.as_ptr(),
                artwork.rgba.len(),
            )
        })
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the JSON contains an interior NUL byte, the
    /// scene is closed, OWE property lookup fails, or OWE rejects the update.
    pub fn set_property_override(&mut self, flat_json: &str) -> Result<(), EngineError> {
        let encoded = cstring(flat_json)?;
        // The scene loads again whatever comes of the call, and shows what it
        // loads.
        self.previewed_properties = None;
        // A returned name is only valid until the next name is asked for, so each
        // is fetched right before it is used.
        let refresh = Self::force_shader_refresh()?;
        self.set_property_bool(refresh, true)?;
        let name = Self::project_property_override_json()?;
        self.set_property_string(name, encoded.as_ptr())
    }

    /// # Errors
    ///
    /// Returns [`EngineError`] if the scene is closed, OWE property lookup
    /// fails, or OWE rejects the update.
    pub fn reset_property_override(&mut self) -> Result<(), EngineError> {
        self.previewed_properties = None;
        let refresh = Self::force_shader_refresh()?;
        self.set_property_bool(refresh, true)?;
        let reset = Self::project_property_reset()?;
        self.set_property_bool(reset, true)
    }

    /// Shows a flattened project property document on the running scene
    /// without loading it again.
    ///
    /// The document is the whole property state to show: the project's
    /// declared defaults with exactly these values over them, so a property it
    /// leaves out is back at its declared default. The renderer never keeps
    /// it, which is why this does not ask for a shader refresh the way
    /// [`Self::set_property_override`] does: nothing is loaded again, and a
    /// scene that is loaded later, for any reason, shows its saved look.
    ///
    /// A renderer that already shows exactly this document is not told again.
    /// Whether it does is known here and nowhere else, because this object is
    /// what shows it and what loses it (see `previewed_properties`).
    ///
    ///
    /// # Errors
    ///
    /// Returns [`EngineError`] if the JSON contains an interior NUL byte, the
    /// scene is closed, OWE property lookup fails, or OWE rejects the update.
    /// A refused update leaves nothing recorded, so asking again sends it.
    pub fn preview_property_override(&mut self, flat_json: &str) -> Result<(), EngineError> {
        let encoded = cstring(flat_json)?;
        let name = Self::project_property_preview_json()?;
        // A closed scene is refused whatever it was last shown.
        self.raw_ptr()?;
        if self.previewed_properties.as_deref() == Some(flat_json) {
            return Ok(());
        }
        self.previewed_properties = None;
        self.set_property_string(name, encoded.as_ptr())?;
        self.previewed_properties = Some(flat_json.to_owned());
        Ok(())
    }

    /// The property document this renderer was last shown by
    /// [`Self::preview_property_override`], or `None` when it shows what it
    /// loaded with.
    pub fn previewed_properties(&self) -> Option<&str> {
        self.previewed_properties.as_deref()
    }

    /// Publishes this scene so its live update state can be read without
    /// going through the engine actor.
    ///
    /// Registering twice for one handle replaces the entry, which is what a
    /// display whose scene was rebuilt needs.
    pub fn publish_runtime_state(&mut self, registry: &crate::SceneRegistry, handle: u64, display_id: u32) {
        let Some(raw) = self.raw else {
            return;
        };
        if let Some((previous, previous_handle)) = self.registration.take() {
            previous.unregister(previous_handle);
        }
        registry.register(handle, display_id, raw);
        self.registration = Some((registry.clone(), handle));
    }

    /// Publishes the replacement under the previous scene's live identity.
    /// The old scene relinquishes ownership before it can close and withdraw it.
    pub fn inherit_runtime_registration(&mut self, previous: &mut Self, display_id: u32) {
        if self.raw.is_none() { return; }
        if let Some((registry, handle)) = previous.registration.take() {
            self.publish_runtime_state(&registry, handle, display_id);
        }
    }

    /// Keeps the registry's physical display identity in sync with window moves.
    pub fn update_runtime_display(&mut self, display_id: u32) {
        if let (Some((registry, handle)), Some(raw)) = (&self.registration, self.raw) {
            registry.register(*handle, display_id, raw);
        }
    }

    pub fn close(&mut self) -> Result<(), EngineError> {
        // Withdraw first, unconditionally, and before anything that can fail
        // or return early. After this line no reader can reach this scene.
        if let Some((registry, handle)) = self.registration.take() {
            registry.unregister(handle);
        }
        // A second close is fine: there is nothing left to release.
        let Some(raw) = self.raw.take() else {
            return Ok(());
        };

        // All three steps run whatever happens; the first failure is the one reported.
        let mut first_error = None;
        let mut note = |result: Result<(), EngineError>| {
            if let Err(error) = result {
                first_error.get_or_insert(error);
            }
        };
        if std::mem::take(&mut self.render_initialized) {
            // Quiesce: drawing stops and the surface is released before shutdown.
            note(call_status("owe_scene_wallpaper_begin_surface_reconfigure", || unsafe {
                sys::owe_scene_wallpaper_begin_surface_reconfigure(raw.as_ptr())
            }));
        }
        note(call_status("owe_scene_wallpaper_shutdown", || unsafe {
            sys::owe_scene_wallpaper_shutdown(raw.as_ptr())
        }));
        note(call_status("owe_scene_wallpaper_delete", || unsafe {
            sys::owe_scene_wallpaper_delete(raw.as_ptr())
        }));
        first_error.map_or(Ok(()), Err)
    }

    fn set_property_bool(&mut self, name: *const c_char, value: bool) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_property_bool", || unsafe {
            sys::owe_scene_wallpaper_set_property_bool(raw.as_ptr(), name, value)
        })
    }

    fn set_property_int32(&mut self, name: *const c_char, value: i32) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_property_int32", || unsafe {
            sys::owe_scene_wallpaper_set_property_int32(raw.as_ptr(), name, value)
        })
    }

    fn set_property_float(&mut self, name: *const c_char, value: f32) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_property_float", || unsafe {
            sys::owe_scene_wallpaper_set_property_float(raw.as_ptr(), name, value)
        })
    }

    fn set_property_string(
        &mut self,
        name: *const c_char,
        value: *const c_char,
    ) -> Result<(), EngineError> {
        let raw = self.raw_ptr()?;
        call_status("owe_scene_wallpaper_set_property_string", || unsafe {
            sys::owe_scene_wallpaper_set_property_string(raw.as_ptr(), name, value)
        })
    }

    fn raw_ptr(&self) -> Result<NonNull<sys::owe_scene_wallpaper>, EngineError> {
        self.raw
            .ok_or_else(|| EngineError::InvalidInput("scene is already closed".to_owned()))
    }
}

impl Drop for OweScene {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

#[cfg(test)]
impl OweScene {
    /// A renderer object that was allocated and never initialized: it opens no
    /// backend, window or audio device and loads nothing, yet it takes
    /// property updates like a running one, so a test can follow what it is told.
    pub(crate) fn uninitialized_for_test() -> Self {
        let mut raw = std::ptr::null_mut();
        call_status("owe_scene_wallpaper_new", || unsafe {
            sys::owe_scene_wallpaper_new(&raw mut raw)
        })
        .unwrap();
        Self {
            raw: Some(NonNull::new(raw).unwrap()),
            render_initialized: false,
            registration: None,
            load: 0,
            previewed_properties: None,
        }
    }
}

fn cstring(value: &str) -> Result<CString, EngineError> {
    CString::new(value).map_err(|error| EngineError::InvalidInput(error.to_string()))
}

fn call_status(operation: &'static str, call: impl FnOnce() -> c_int) -> Result<(), EngineError> {
    // SAFETY: the closure only calls the engine ABI, whose declarations allow unwinding.
    let status = unsafe { UnwindSafeFFI::new(operation).call(call)? };
    if status == 0 {
        Ok(())
    } else {
        // SAFETY: the engine's thread-local error text is readable at any time.
        Err(EngineError::Render(unsafe { UnwindSafeFFI::last_error() }))
    }
}

#[allow(dead_code)]
unsafe extern "C-unwind" fn owe_log_callback(
    level: c_int,
    file: *const c_char,
    line: c_int,
    message: *const c_char,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let text = |pointer: *const c_char| {
            (!pointer.is_null()).then(|| unsafe { CStr::from_ptr(pointer) }.to_string_lossy())
        };
        let message = text(message).unwrap_or_default();
        let file = text(file);
        log::logger().log(
            &log::Record::builder()
                .args(format_args!("{message}"))
                .level(if level == 1 { log::Level::Error } else { log::Level::Info })
                .target("open_wallpaper_engine")
                .file(Some(file.as_deref().unwrap_or("unknown")))
                .line(u32::try_from(line).ok())
                .build(),
        );
    }));
}

#[allow(dead_code)]
unsafe extern "C-unwind" fn owe_first_frame_callback(user_data: *mut c_void) {
    if let Some(callback) = unsafe { user_data.cast::<FirstFrameCallback>().as_ref() } {
        let _ = catch_unwind(AssertUnwindSafe(|| callback()));
    }
}

#[allow(dead_code)]
unsafe extern "C-unwind" fn owe_first_frame_callback_drop(user_data: *mut c_void) {
    release_callback::<FirstFrameCallback>(user_data);
}

unsafe extern "C-unwind" fn owe_pointer_input_callback(
    user_data: *mut c_void,
    accepts_pointer_input: bool,
) {
    if let Some(callback) = unsafe { user_data.cast::<PointerInputCallback>().as_ref() } {
        let _ = catch_unwind(AssertUnwindSafe(|| callback(accepts_pointer_input)));
    }
}

unsafe extern "C-unwind" fn owe_pointer_input_callback_drop(user_data: *mut c_void) {
    release_callback::<PointerInputCallback>(user_data);
}

unsafe extern "C-unwind" fn owe_user_shortcut_callback(
    user_data: *mut c_void,
    property_name: *const c_char,
    property_value: *const c_char,
) {
    let Some(callback) = (unsafe { user_data.cast::<UserShortcutCallback>().as_ref() }) else {
        return;
    };
    let read = |pointer: *const c_char| {
        if pointer.is_null() {
            return None;
        }
        unsafe { CStr::from_ptr(pointer) }.to_str().ok().map(str::to_owned)
    };
    // A name or value the engine handed over unreadable is dropped silently.
    let (Some(name), Some(value)) = (read(property_name), read(property_value)) else {
        return;
    };
    let _ = catch_unwind(AssertUnwindSafe(|| callback(name, value)));
}

unsafe extern "C-unwind" fn owe_user_shortcut_callback_drop(user_data: *mut c_void) {
    release_callback::<UserShortcutCallback>(user_data);
}

unsafe extern "C-unwind" fn owe_audio_requirement_callback(
    user_data: *mut c_void,
    requires_audio: bool,
) {
    if let Some(callback) = unsafe { user_data.cast::<AudioRequirementCallback>().as_ref() } {
        let _ = catch_unwind(AssertUnwindSafe(|| callback(requires_audio)));
    }
}

unsafe extern "C-unwind" fn owe_audio_requirement_callback_drop(user_data: *mut c_void) {
    release_callback::<AudioRequirementCallback>(user_data);
}

unsafe extern "C-unwind" fn owe_render_failure_callback(user_data: *mut c_void) {
    if let Some(callback) = unsafe { user_data.cast::<RenderFailureCallback>().as_ref() } {
        let _ = catch_unwind(AssertUnwindSafe(|| callback()));
    }
}

unsafe extern "C-unwind" fn owe_render_failure_callback_drop(user_data: *mut c_void) {
    release_callback::<RenderFailureCallback>(user_data);
}

/// Frees one boxed callback registration, whose drop may itself panic.
fn release_callback<T>(user_data: *mut c_void) {
    if user_data.is_null() {
        return;
    }
    // SAFETY: a registration owns exactly one `Box<T>` and releases it once.
    let boxed = unsafe { Box::<T>::from_raw(user_data.cast()) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(boxed)));
}

#[cfg(test)]
mod registration_tests {
    use super::*;

    // Allocation alone creates no backend, window or audio device. No renderer
    // initialization or resource loading is performed in this lifecycle test.
    fn uninitialized_scene() -> OweScene {
        OweScene::uninitialized_for_test()
    }

    #[test]
    fn replacement_retains_one_live_report_after_the_old_scene_closes() {
        let registry = crate::SceneRegistry::new();
        let mut previous = uninitialized_scene();
        previous.publish_runtime_state(&registry, 42, 7);
        let mut replacement = uninitialized_scene();
        replacement.inherit_runtime_registration(&mut previous, 9);
        previous.close().unwrap();
        let reports = registry.reports();
        assert_eq!(reports.len(), 1);
        assert_eq!((reports[0].handle, reports[0].display_id), (42, 9));
        replacement.update_runtime_display(11);
        assert_eq!(registry.reports()[0].display_id, 11);
        drop(replacement);
        assert!(registry.reports().is_empty());
    }
}

#[cfg(test)]
mod pointer_callback_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct DropWitness(Arc<AtomicUsize>);

    impl Drop for DropWitness {
        fn drop(&mut self) { self.0.fetch_add(1, Ordering::SeqCst); }
    }

    #[test]
    fn closed_registration_does_not_leak_callback_userdata() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let witness = DropWitness(dropped.clone());
        let callback: PointerInputCallback = Arc::new(move |_| { let _ = &witness; });
        let mut scene = OweScene { raw: None, render_initialized: false, registration: None, load: 0, previewed_properties: None };
        assert!(scene.set_pointer_input_callback(Some(callback)).is_err());
        assert_eq!(dropped.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn native_callback_contains_panics_and_drop_releases_userdata_once() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let observed = Arc::new(AtomicUsize::new(0));
        let witness = DropWitness(dropped.clone());
        let callback: PointerInputCallback = Arc::new({
            let observed = observed.clone();
            move |accepts| {
                let _ = &witness;
                observed.fetch_add(usize::from(accepts), Ordering::SeqCst);
                panic!("consumer panic must not cross the ABI");
            }
        });
        let raw = Box::into_raw(Box::new(callback)).cast::<c_void>();
        unsafe {
            owe_pointer_input_callback(raw, true);
            owe_pointer_input_callback_drop(raw);
        }
        assert_eq!(observed.load(Ordering::SeqCst), 1);
        assert_eq!(dropped.load(Ordering::SeqCst), 1);
    }
}

#[cfg(test)]
mod render_failure_callback_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct DropWitness(Arc<AtomicUsize>);

    impl Drop for DropWitness {
        fn drop(&mut self) { self.0.fetch_add(1, Ordering::SeqCst); }
    }

    fn callback_with(dropped: &Arc<AtomicUsize>, called: &Arc<AtomicUsize>) -> RenderFailureCallback {
        let witness = DropWitness(dropped.clone());
        let called = called.clone();
        Arc::new(move || {
            let _ = &witness;
            called.fetch_add(1, Ordering::SeqCst);
        })
    }

    #[test]
    fn a_registration_on_a_closed_scene_hands_the_callback_back_to_be_dropped_once() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let called = Arc::new(AtomicUsize::new(0));
        let mut scene = OweScene { raw: None, render_initialized: false, registration: None, load: 0, previewed_properties: None };

        assert!(scene.set_render_failure_callback(Some(callback_with(&dropped, &called))).is_err());

        assert_eq!(dropped.load(Ordering::SeqCst), 1, "a rejected registration leaked its callback");
        assert_eq!(called.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_registration_the_renderer_rejects_hands_the_callback_back_to_be_dropped_once() {
        // The renderer refuses to take a callback before it is initialized,
        // which is the same path as any other refusal: Rust still owns the box.
        let dropped = Arc::new(AtomicUsize::new(0));
        let called = Arc::new(AtomicUsize::new(0));
        let mut raw = std::ptr::null_mut();
        call_status("owe_scene_wallpaper_new", || unsafe {
            sys::owe_scene_wallpaper_new(&raw mut raw)
        })
        .unwrap();
        let mut scene = OweScene {
            raw: Some(NonNull::new(raw).unwrap()),
            render_initialized: false,
            registration: None,
            load: 0,
            previewed_properties: None,
        };

        assert!(scene.set_render_failure_callback(Some(callback_with(&dropped, &called))).is_err());

        assert_eq!(dropped.load(Ordering::SeqCst), 1, "a rejected registration leaked its callback");
        assert_eq!(called.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn clearing_the_callback_on_a_closed_scene_has_nothing_to_drop() {
        let mut scene = OweScene { raw: None, render_initialized: false, registration: None, load: 0, previewed_properties: None };
        assert!(scene.set_render_failure_callback(None).is_err());
    }

    #[test]
    fn the_native_callback_contains_a_panic_and_its_drop_releases_the_callback_once() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let called = Arc::new(AtomicUsize::new(0));
        let witness = DropWitness(dropped.clone());
        let callback: RenderFailureCallback = Arc::new({
            let called = called.clone();
            move || {
                let _ = &witness;
                called.fetch_add(1, Ordering::SeqCst);
                panic!("consumer panic must not cross the ABI");
            }
        });
        let raw = Box::into_raw(Box::new(callback)).cast::<c_void>();

        unsafe {
            owe_render_failure_callback(raw);
            // Still callable afterwards: a panic is the consumer's, not the
            // registration's.
            owe_render_failure_callback(raw);
            owe_render_failure_callback_drop(raw);
        }

        assert_eq!(called.load(Ordering::SeqCst), 2);
        assert_eq!(dropped.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_null_registration_is_ignored_by_both_trampolines() {
        unsafe {
            owe_render_failure_callback(std::ptr::null_mut());
            owe_render_failure_callback_drop(std::ptr::null_mut());
        }
    }
}

#[cfg(test)]
mod property_preview_tests {
    use super::*;

    fn name(pointer: *const c_char) -> String {
        assert!(!pointer.is_null());
        unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned()
    }

    #[test]
    fn the_preview_is_a_property_of_its_own() {
        let preview = name(OweScene::project_property_preview_json().unwrap());
        let others = [
            name(OweScene::project_property_override_json().unwrap()),
            name(OweScene::project_property_reset().unwrap()),
            name(OweScene::force_shader_refresh().unwrap()),
        ];

        assert!(!preview.is_empty());
        // A preview sent under the override's name would load the scene again
        // and keep the document; under the reset's name it would clear the
        // saved override.
        for other in others {
            assert_ne!(preview, other);
        }
    }

    #[test]
    fn a_document_with_a_nul_byte_never_reaches_the_renderer() {
        let mut scene = OweScene { raw: None, render_initialized: false, registration: None, load: 0, previewed_properties: None };

        let err = scene.preview_property_override("{\"a\":\"b\0c\"}").expect_err("a NUL byte is refused");

        // The closed scene would have said so had the document got that far.
        assert!(
            matches!(&err, EngineError::InvalidInput(message) if !message.contains("already closed")),
            "{err:?}"
        );
    }

    #[test]
    fn a_shown_document_is_remembered_until_the_scene_loads_again() {
        let mut scene = OweScene::uninitialized_for_test();
        assert_eq!(scene.previewed_properties(), None, "a new renderer shows what it loaded");

        scene.preview_property_override(r#"{"alpha":0.5}"#).unwrap();
        assert_eq!(scene.previewed_properties(), Some(r#"{"alpha":0.5}"#));
        scene.preview_property_override(r#"{"alpha":0.5}"#).unwrap();
        assert_eq!(scene.previewed_properties(), Some(r#"{"alpha":0.5}"#));
        scene.preview_property_override(r#"{"alpha":0.25}"#).unwrap();
        assert_eq!(scene.previewed_properties(), Some(r#"{"alpha":0.25}"#));

        // Both ways of loading the scene again put its own look back, and the
        // renderer must not go on believing it shows the edit.
        scene.set_property_override(r#"{"alpha":0.75}"#).unwrap();
        assert_eq!(scene.previewed_properties(), None);
        scene.preview_property_override(r#"{"alpha":0.5}"#).unwrap();
        scene.reset_property_override().unwrap();
        assert_eq!(scene.previewed_properties(), None);
    }

    #[test]
    fn a_document_the_renderer_never_took_is_not_remembered() {
        let mut scene = OweScene::uninitialized_for_test();
        scene.preview_property_override(r#"{"alpha":0.5}"#).unwrap();

        scene.preview_property_override("{\"a\":\"b\0c\"}").expect_err("a NUL byte is refused");

        assert_eq!(
            scene.previewed_properties(),
            Some(r#"{"alpha":0.5}"#),
            "a document refused before the renderer heard it changed nothing the renderer shows"
        );
    }

    #[test]
    fn a_closed_scene_refuses_a_document_it_was_last_shown() {
        let mut scene = OweScene::uninitialized_for_test();
        scene.preview_property_override("{}").unwrap();
        scene.close().unwrap();

        let err = scene.preview_property_override("{}").expect_err("a closed scene takes nothing");

        assert!(matches!(&err, EngineError::InvalidInput(message) if message.contains("already closed")), "{err:?}");
    }

    #[test]
    fn a_closed_scene_refuses_a_preview() {
        let mut scene = OweScene { raw: None, render_initialized: false, registration: None, load: 0, previewed_properties: None };

        let err = scene.preview_property_override("{}").expect_err("a closed scene takes nothing");

        assert!(matches!(&err, EngineError::InvalidInput(message) if message.contains("already closed")), "{err:?}");
    }
}
