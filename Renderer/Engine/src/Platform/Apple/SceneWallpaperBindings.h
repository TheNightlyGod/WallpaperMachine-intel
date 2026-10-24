#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../../Core/RendererCounters.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct owe_scene_wallpaper owe_scene_wallpaper;

typedef void (*owe_log_callback)(int level, const char* file, int line, const char* message);
typedef void (*owe_first_frame_callback)(void* user_data);
typedef void (*owe_first_frame_callback_drop)(void* user_data);
typedef void (*owe_pointer_input_callback)(void* user_data, bool accepts_pointer_input);
typedef void (*owe_pointer_input_callback_drop)(void* user_data);
typedef void (*owe_audio_requirement_callback)(void* user_data, bool requires_audio);
typedef void (*owe_audio_requirement_callback_drop)(void* user_data);
typedef void (*owe_render_failure_callback)(void* user_data);
typedef void (*owe_render_failure_callback_drop)(void* user_data);

/*
 * One `engine.openUserShortcut` request: the property the wallpaper named and
 * the value its user chose for it. Both strings are owned by the caller and
 * valid only for the duration of the call.
 */
typedef void (*owe_user_shortcut_callback)(void* user_data, const char* property_name,
                                           const char* property_value);
typedef void (*owe_user_shortcut_callback_drop)(void* user_data);

void owe_set_log_callback(owe_log_callback callback);

/*
 * Log scopes: a host-assigned load number carried by every line a scene's
 * threads log, zero meaning untagged. `owe_current_log_scope` reads the calling
 * thread's scope, so the host's log sink can tag lines from renderer threads.
 * `owe_scene_wallpaper_set_log_scope` must be called before
 * `owe_scene_wallpaper_init`, which starts the scene's threads.
 */
uint64_t owe_current_log_scope(void);
int owe_scene_wallpaper_set_log_scope(owe_scene_wallpaper* scene, uint64_t scope);

/* Lifecycle of the host handle. Every function here returns 0 on success. */
int owe_scene_wallpaper_new(owe_scene_wallpaper** out_scene);
int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene);
int owe_scene_wallpaper_init(owe_scene_wallpaper* scene);
int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene);

/* The drawing surface: the CAMetalLayer, its size in points and the size to render at. */
int owe_scene_wallpaper_init_metal(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor);
int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene);
int owe_scene_wallpaper_finish_surface_reconfigure(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor);

/* What to show and how fast. `paused`, `volume` (0 to 1) and `muted` are in force before
   the scene loads, which can start at once; the setters below act only from when they are
   read, after a load that already began has started its sounds. */
int owe_scene_wallpaper_apply_config(
    owe_scene_wallpaper* scene,
    const char* source,
    const char* assets,
    const char* cache_path,
    uint32_t fps,
    bool paused,
    float volume,
    bool muted,
    bool force_shader_refresh,
    const char* project_property_override_json);
int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps);
int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused);

int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale);

int owe_scene_wallpaper_set_framing(owe_scene_wallpaper* scene, double pan_x, double pan_y);

int owe_scene_wallpaper_set_first_frame_callback(owe_scene_wallpaper* scene,
                                                 owe_first_frame_callback callback,
                                                 void* user_data,
                                                 owe_first_frame_callback_drop drop_user_data);

/*
 * Reports committed scene pointer capability on the native main looper, with
 * an immediate replay there when installed. Requires an initialized scene.
 * Success transfers user_data ownership to drop_user_data; failure does not.
 * Replacing/clearing keeps old userdata alive until its last queued/in-flight
 * callback is released. A null callback clears notifications.
 */
int owe_scene_wallpaper_set_pointer_input_callback(
    owe_scene_wallpaper* scene, owe_pointer_input_callback callback, void* user_data,
    owe_pointer_input_callback_drop drop_user_data);

/*
 * Reports `engine.openUserShortcut` requests on the native main looper, in the
 * order the wallpaper made them. Requires an initialized scene. Success
 * transfers user_data ownership to drop_user_data; failure does not.
 * Replacing/clearing keeps old userdata alive until its last queued/in-flight
 * callback is released. A null callback clears notifications.
 *
 * What a request means is the host's to decide: the engine neither interprets
 * the value nor acts on it.
 */
int owe_scene_wallpaper_set_user_shortcut_callback(
    owe_scene_wallpaper* scene, owe_user_shortcut_callback callback, void* user_data,
    owe_user_shortcut_callback_drop drop_user_data);

/*
 * Reports whether the committed scene reads system audio (audio-processing
 * materials or particles, g_AudioSpectrum* uniforms, registerAudioBuffers), on
 * the native main looper, with an immediate replay there when installed, then
 * only on changes. A newly committed scene reports false until it marks itself;
 * the mark is monotonic for that scene, and a late mark from a replaced scene
 * is dropped. Plain video projects never report true. Optional: a host that
 * does not install it is unaffected. Requires an initialized scene. Success
 * transfers user_data ownership to drop_user_data; failure does not.
 * Replacing/clearing keeps old userdata alive until its last queued/in-flight
 * callback is released. A null callback clears notifications.
 */
int owe_scene_wallpaper_set_audio_requirement_callback(
    owe_scene_wallpaper* scene, owe_audio_requirement_callback callback, void* user_data,
    owe_audio_requirement_callback_drop drop_user_data);

/*
 * Reports, on the native main looper, that a scene which had already presented
 * a frame failed one and stopped drawing (a swapchain, acquire, present or
 * submit the surface could not take). One call per failure, no payload: the
 * surface health reading says what failed, and rendering stays stopped until
 * the host rebuilds the surface (begin/finish_surface_reconfigure) or the scene.
 * Not replayed when installed, and not raised for a failure before the first
 * presented frame, which the host's own first-frame wait already covers.
 * Optional: a host that does not install it is unaffected. Requires an
 * initialized scene. Success transfers user_data ownership to drop_user_data;
 * failure does not. Replacing/clearing keeps old userdata alive until its last
 * queued/in-flight callback is released. A null callback clears notifications.
 */
int owe_scene_wallpaper_set_render_failure_callback(
    owe_scene_wallpaper* scene, owe_render_failure_callback callback, void* user_data,
    owe_render_failure_callback_drop drop_user_data);

int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y);
int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed);
int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered);

/* Reconciles held levels without creating or clearing pending edges. Requires initialization. */
int owe_scene_wallpaper_set_mouse_button_baseline(owe_scene_wallpaper* scene, uint32_t down);

/* Property setters: a property takes exactly one of these kinds (see its accessor below). */
int owe_scene_wallpaper_set_property_bool(
    owe_scene_wallpaper* scene,
    const char* name,
    bool value);
int owe_scene_wallpaper_set_property_int32(
    owe_scene_wallpaper* scene,
    const char* name,
    int32_t value);
int owe_scene_wallpaper_set_property_float(
    owe_scene_wallpaper* scene,
    const char* name,
    float value);
int owe_scene_wallpaper_set_property_string(
    owe_scene_wallpaper* scene,
    const char* name,
    const char* value);

/* Sound and media. */
int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume);
int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted);
int owe_scene_wallpaper_submit_media_event_json(
    owe_scene_wallpaper* scene,
    const char* event_json);
int owe_scene_wallpaper_apply_system_media_artwork(
    owe_scene_wallpaper* scene,
    uint32_t width,
    uint32_t height,
    const uint8_t* rgba,
    uintptr_t rgba_len);

/*
 * The names the setters above are given. Each pointer is NUL-terminated, valid
 * for the life of the process and never freed.
 */
const char* owe_property_scaling_mode(void);                    /* int32 */
const char* owe_property_scaling_factor(void);                  /* float */
const char* owe_property_horizontal_flip(void);                 /* bool */
const char* owe_property_audio_response_enabled(void);          /* bool */
const char* owe_property_media_integration_enabled(void);       /* bool */
const char* owe_property_force_shader_refresh(void);            /* bool */
const char* owe_property_project_property_override_json(void);  /* string */
const char* owe_property_project_property_reset(void);          /* bool, true resets */

/*
 * String property taking a flat JSON object: the whole property state to show on
 * the running scene without loading it again. It is never remembered, so any
 * later load shows the saved look. Set it with owe_scene_wallpaper_set_property_string.
 */
const char* owe_property_project_property_preview_json(void);

int owe_audio_submit_mono_frames(uint32_t sample_rate, uint32_t frame_count,
                                 const float* pcm_frames);
int owe_audio_submit_frames(uint32_t sample_rate, uint32_t frame_count, const float* pcm_frames);
int owe_audio_current_spectrum_128(float* out_bins, uintptr_t out_len, uint64_t* out_generation);
/*
 * Whether the analysis behind `owe_audio_current_spectrum_128` genuinely
 * carried two channels. Returns 1 for stereo, 0 for a mono source whose
 * left and right halves are therefore equal, and -1 when no analysis has run.
 * A mono source is never reported as stereo.
 */
int owe_audio_spectrum_is_stereo(void);

/*
 * Scene render optimisation, process-wide.
 *
 * Reuses the previous frame's pixels for render targets whose inputs have not
 * changed, and removes copy passes proven to have no consumer or to duplicate
 * an image nothing rewrites. It does not change output resolution, frame rate
 * or animation timing. Enabled by default; turning it off makes every pass
 * execute every frame so the two paths can be compared directly.
 */
void owe_set_scene_optimization_enabled(bool enabled);
bool owe_scene_optimization_enabled(void);
/*
 * Passes executed and passes skipped since the counters were last reset, plus
 * copies removed at compile time and the size the pinned targets are estimated
 * to occupy. The byte figure is derived from extent and mip count, not queried
 * from the allocator, so it bounds the cache rather than measuring residency.
 */
void owe_scene_optimization_stats(uint64_t* out_executed_passes, uint64_t* out_skipped_passes,
                                  uint64_t* out_elided_copies, uint64_t* out_pinned_bytes);

/*
 * Whole-scene on-demand updating, process-wide. Off by default.
 *
 * When a scene can be shown to have nothing that advances on its own — no
 * script, animation, particle emitter, video, audio-reactive shader, time
 * uniform, animated sprite, puppet, bound text, sound or unaccounted input —
 * its frame clock stops entirely instead of ticking at the configured rate.
 * The last presented frame stays on screen and events restart the clock.
 *
 * This is not a frame-rate setting and does not lower quality. A scene that
 * cannot be shown to be still keeps its existing cadence.
 */
void owe_set_scene_on_demand_enabled(bool enabled);
bool owe_scene_on_demand_enabled(void);

/*
 * How many pixels a 2D scene is rasterized with, process-wide. Canvas by
 * default; the app pushes its setting before any scene opens.
 *
 * A 2D scene has an authored canvas that the presentation stretches over the
 * display. CANVAS rasterizes at the canvas size, which is the cheapest and, on
 * a display with more pixels than the canvas, the softest. DISPLAY rasterizes at
 * the size the canvas is presented at (the fill layout's scale times the display
 * scale factor, capped at the device's largest texture), which is what Wallpaper
 * Engine does. Either way the canvas stays the source of layout, cursor mapping,
 * scripts and camera; only the render targets' pixel sizes differ. The internal
 * render scale divides whichever raster is chosen.
 *
 * Perspective scenes already rasterize at the output size and videos keep their
 * frame's size, so neither reads it. A scene picks a new value up when its render
 * scale is next applied (the host re-sends it to every open scene) or its graph
 * is next built; nothing is reparsed and no video is reopened. An unrecognised
 * value selects CANVAS.
 */
typedef enum owe_scene_resolution {
    OWE_SCENE_RESOLUTION_CANVAS = 0,
    OWE_SCENE_RESOLUTION_DISPLAY = 1
} owe_scene_resolution;

void owe_set_scene_resolution(int resolution);
int  owe_current_scene_resolution(void);

/*
 * How one scene is currently being updated, and why.
 *
 * Pull-only and unaffected by whether renderer counting is enabled: this is
 * live state a settings pane displays, not instrumentation.
 *
 * `owe_scene_wallpaper_update_mode` returns an `owe_scene_update_mode`, or -1
 * when the scene pointer is null. -1 means "not observed" and must not be
 * shown as any real state. `owe_scene_wallpaper_demand_reasons` returns a
 * bitmask of `owe_scene_demand_reason`; zero alongside a continuous mode means
 * on-demand updating is switched off rather than that no reason exists.
 */
int      owe_scene_wallpaper_update_mode(void* scene);
uint32_t owe_scene_wallpaper_demand_reasons(void* scene);

/*
 * Whether one scene's frame loop is alive, and whether it stopped after a
 * failure.
 *
 * Like the update mode this is pull-only and unaffected by whether renderer
 * counting is enabled: a settings pane shows it and a host acts on it, so it
 * cannot depend on a diagnostic switch. Reading it takes no lock and does no
 * work on the render thread.
 *
 * `frames_completed` counts frames that ran to the end, whether or not they
 * reached the display. A frame that would repeat the picture completes without
 * presenting, so a healthy still scene keeps this number moving while
 * `frames_presented` stays flat; liveness must be read from this one.
 * `failed_frames` counts frames lost to a failure inside the draw and is never
 * reset. `last_present_age_ms` is UINT64_MAX until something has been
 * presented, and on a still scene it grows without anything being wrong.
 *
 * `stop_reason` is an `owe_surface_stop_reason`. A non-running value means the
 * surface stopped drawing because something failed, not because it was paused
 * or is idle, and stays latched until a scene, a surface or a rebuilt graph
 * lets it draw again.
 */
typedef enum owe_surface_stop_reason {
    OWE_SURFACE_STOP_RUNNING = 0,
    OWE_SURFACE_STOP_FRAME_FAILED = 1,
    OWE_SURFACE_STOP_GRAPH_FAILED = 2
} owe_surface_stop_reason;

typedef struct owe_surface_health {
    uint64_t frames_completed;
    uint64_t frames_presented;
    uint64_t failed_frames;
    uint64_t last_present_age_ms;
    uint32_t stop_reason;
} owe_surface_health;

/* 0 on success. Non-zero, and `out` untouched, when `scene` or `out` is null. */
int owe_scene_wallpaper_surface_health(void* scene, owe_surface_health* out);

/*
 * Native Metal is the only scene renderer. A scene it cannot draw is not drawn:
 * the surface keeps the last frame it showed (or shows the project's preview
 * picture when it has drawn nothing), and the failure is reported through
 * owe_scene_wallpaper_backend_failure.
 */
typedef enum owe_scene_backend {
    OWE_SCENE_BACKEND_NATIVE_METAL = 1
} owe_scene_backend;

/*
 * OWE_SCENE_BACKEND_NATIVE_METAL when a renderer is drawing this scene, or -1
 * when nothing has been observed yet -- no scene, or a surface whose renderer
 * has not been created because the scene it depends on is still being parsed
 * -- or when the scene is held in a failure and nothing is drawing it (see
 * owe_scene_wallpaper_backend_failure).
 */
int    owe_scene_wallpaper_backend(void* scene);

/*
 * Why a scene is not being drawn, or OWE_SCENE_FAILURE_NONE.
 *
 * A failed scene reports backend -1 from owe_scene_wallpaper_backend: nothing is
 * drawing it. The stage is a category the host words for the user;
 * owe_scene_wallpaper_backend_failure_reason writes the engine's own
 * NUL-terminated explanation (English, for diagnostics) into `out` and returns
 * the length excluding the terminator; passing a null `out` or a zero `out_len`
 * reports the length that would be needed. The two clear together when a
 * recovery makes the scene draw again.
 */
typedef enum owe_scene_failure_stage {
    OWE_SCENE_FAILURE_NONE = 0,
    OWE_SCENE_FAILURE_UNSUPPORTED = 1,
    OWE_SCENE_FAILURE_PREPARE = 2,
    OWE_SCENE_FAILURE_COMPILE = 3,
    OWE_SCENE_FAILURE_FRAME = 4,
    OWE_SCENE_FAILURE_SURFACE = 5
} owe_scene_failure_stage;

int    owe_scene_wallpaper_backend_failure(void* scene);
size_t owe_scene_wallpaper_backend_failure_reason(void* scene, char* out, size_t out_len);

/*
 * Direct NV12 plane sampling inside native Metal scenes, process-wide. Off by
 * default.
 *
 * A material whose shader could be translated to sample the decoder's luma and
 * chroma planes then does so, and no full-frame colour conversion is produced
 * for it. Both programs are compiled with the scene's graph, so this selects
 * between them and never triggers a compile inside a frame. A material with no
 * usable variant, and any frame that is not 8-bit NV12, keeps the existing
 * conversion whatever this says.
 */
void owe_set_scene_video_plane_sampling_enabled(bool enabled);
bool owe_scene_video_plane_sampling_enabled(void);

/*
 * How each of a scene's video textures reached the shaders sampling it, as of
 * the last frame it drew. Reported, never requested: it says what the frame's
 * real pixel format and the material's own program allowed.
 */
typedef enum owe_scene_video_path {
    OWE_SCENE_VIDEO_PATH_NONE = 0,
    OWE_SCENE_VIDEO_PATH_BGRA = 1,
    OWE_SCENE_VIDEO_PATH_NV12_DIRECT = 2,
    OWE_SCENE_VIDEO_PATH_NV12_CONVERTED = 3,
    OWE_SCENE_VIDEO_PATH_NV12_MIXED = 4,
    OWE_SCENE_VIDEO_PATH_NV12_CONVERTED_PREPARING = 5,
    OWE_SCENE_VIDEO_PATH_YUV10_CONVERTED = 6
} owe_scene_video_path;

/*
 * The path shared by this scene's video textures, or
 * `OWE_SCENE_VIDEO_PATH_NONE` when it has none, has drawn no frame yet, or is
 * not on the native backend. Textures on different paths report the mixed
 * value, which is the honest answer for a scene whose materials differ.
 *
 * `..._NV12_CONVERTED_PREPARING` is the converted path before its conversion
 * is ready. It is distinct from `NONE` because the scene does have a path and
 * is working towards it; reporting `NONE` there told the host there was no
 * video at all.
 *
 * `..._YUV10_CONVERTED` is 10-bit video (HDR tone mapped to SDR, or 10-bit SDR
 * carried over), converted once per frame into one image.
 */
int owe_scene_wallpaper_video_path(void* scene);

/*
 * Whether this scene's compiled graph is running under the current scene
 * optimisation setting, rather than still carrying the plan the previous value
 * produced. 1 applied, 0 still applying, -1 no scene.
 *
 * This is the read-back the settings surface needs to tell a saved preference
 * apart from one that is actually in force.
 */
int owe_scene_wallpaper_scene_optimization_applied(void* scene);

/*
 * Renderer work counters.
 *
 * Counting is off by default and costs one relaxed atomic load per counted
 * event when enabled. Reading is pull-only: nothing is pushed, logged, or
 * written to disk, and enabling does not start a thread or a timer.
 *
 * `owe_scene_wallpaper_counters` writes at most `out_len` values in
 * `owe_renderer_counter` order and reports how many it wrote, so a caller
 * built against a shorter list stays correct. Values are read individually,
 * so a snapshot is a set of live readings rather than one instant.
 */
int owe_renderer_counters_set_enabled(bool enabled);
bool owe_renderer_counters_enabled(void);
int owe_scene_wallpaper_counters(owe_scene_wallpaper* scene, uint64_t* out_values,
                                 uintptr_t out_len, uintptr_t* out_written);
/* Process-wide counters, in `owe_renderer_shared_counter` order. */
int owe_renderer_shared_counters(uint64_t* out_values, uintptr_t out_len, uintptr_t* out_written);

const char* owe_last_error(void);

#ifdef __cplusplus
}
#endif
