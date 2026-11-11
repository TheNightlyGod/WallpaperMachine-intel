#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include "Type.hpp"
#include "Core/SurfaceHealth.hpp"
#include "Presentation/WallpaperFraming.hpp"
#include "Scene/SceneQuality.hpp"
#include "Scene/WeUserOptions.hpp"
#include <optional>
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "Scene/include/Scene/SceneResolution.hpp"
#include "Scene/include/Scene/SceneVideoPath.hpp"
#include "Scene/include/Scene/SceneUpdateDemand.hpp"

#if defined(WESCENE_BUILD_TESTS) && defined(__APPLE__)
struct owe_scene_wallpaper;
#endif

namespace wallpaper
{

using FirstFrameCallback = std::function<void()>;
using PointerInputCallback = std::function<void(bool)>;
/// Reports one `engine.openUserShortcut` request: the property the wallpaper
/// named, and the value its user chose for that property.
using UserShortcutCallback = std::function<void(std::string_view, std::string_view)>;
/// Reports whether the committed scene reads system audio (audio-processing
/// materials or particles, `g_AudioSpectrum*` uniforms, `registerAudioBuffers`).
/// Runs on the main looper, once on install with the current value and then
/// only on changes: a newly committed scene starts at `false`, and its own
/// later report raises it; a report from a scene that was since replaced is
/// dropped. Optional: a host that never installs it keeps working unchanged.
using AudioRequirementCallback = std::function<void(bool)>;
/// Reports that a scene which had drawn at least once failed a frame and
/// stopped drawing (a swapchain, acquire, present or submit the surface could
/// not take). Runs on the main looper, once per failure, with no payload: the
/// surface health reading says what failed. Never replayed on install, and
/// never raised for a failure before the first presented frame, which the host
/// already finds through its own first-frame wait. Optional: a host that never
/// installs it keeps working unchanged, and the stop stays visible through
/// `surfaceHealth()`.
using RenderFailureCallback = std::function<void()>;

constexpr std::string_view PROPERTY_SOURCE                    = "source";
constexpr std::string_view PROPERTY_ASSETS                    = "assets";
constexpr std::string_view PROPERTY_FPS                       = "fps";
constexpr std::string_view PROPERTY_FILLMODE                  = "fillmode";
constexpr std::string_view PROPERTY_SCALINGMODE               = "scalingmode";
constexpr std::string_view PROPERTY_SCALINGFACTOR             = "scalingfactor";
/// Object property: a `WallpaperFraming`, both axes in one message so a
/// reader never sees one of them from before a change and one from after.
constexpr std::string_view PROPERTY_FRAMING                   = "framing";
/// Internal rasterization scale in (0,1]. Distinct from PROPERTY_SCALINGFACTOR,
/// which scales the presented image on the output.
constexpr std::string_view PROPERTY_RENDER_SCALE              = "render_scale";
/// Object property: a `SceneQuality`. A different value reloads a loaded scene,
/// because shadows, volumetrics, reflection and post-processing change how the
/// scene is parsed.
constexpr std::string_view PROPERTY_SCENE_QUALITY             = "scene_quality";
/// Object property (`SceneScriptStorageConfig`): where the scripts' `localStorage` is kept.
/// Kept for the load that follows; a running scene keeps the storage it loaded with.
constexpr std::string_view PROPERTY_SCENE_STORAGE             = "scene_storage";
/// Object property: a `WeUserOptions` (Wallpaper Engine's per-wallpaper colour
/// options, image filter, flip, mouse parallax and playback rate). Kept for the
/// next load; on a loaded scene a value is applied live (flip and rate through
/// the `horizontal_flip` / `speed` paths), and only a change of the `ccsimple`
/// pass's shape (COL / LUT on or off, another LUT) loads the scene again.
constexpr std::string_view PROPERTY_WE_USER_OPTIONS           = "we_user_options";
/// Bool property: mirrors the presented wallpaper left to right, and the pointer with it.
constexpr std::string_view PROPERTY_HORIZONTAL_FLIP =
    "horizontal_flip";
/// Float property: playback rate multiplier.
constexpr std::string_view PROPERTY_SPEED =
    "speed";
/// Developer switch; accepted and ignored.
constexpr std::string_view PROPERTY_GRAPHIVZ =
    "graphivz";
/// Sound output: volume (float) and mute (bool).
constexpr std::string_view PROPERTY_VOLUME =
    "volume";
constexpr std::string_view PROPERTY_MUTED =
    "muted";
/// Bool consents: audio-driven effects, and media integration.
constexpr std::string_view PROPERTY_AUDIO_RESPONSE_ENABLED =
    "audio_response_enabled";
constexpr std::string_view PROPERTY_MEDIA_INTEGRATION_ENABLED =
    "media_integration_enabled";
/// String property: one media event as JSON.
constexpr std::string_view PROPERTY_MEDIA_EVENT_JSON =
    "media_event_json";
/// The user's property overrides as a flat JSON object (string), and the bool that clears them.
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON =
    "project_property_override_json";
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_RESET =
    "project_property_reset";
/// String property: a flat JSON object holding the whole property state to show
/// on the scene that is running (the same shape as the override JSON above),
/// without loading it again. Unlike the override it is never remembered: a
/// scene that is loaded again, for any reason, shows the saved look until the
/// next document arrives, and a document sent before any scene exists is
/// dropped. The newest document wins, so a burst of them costs one update. A
/// document that is not a JSON object changes nothing. Properties a scene reads
/// only while it loads stay at the value the scene loaded with.
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON =
    "project_property_preview_json";
constexpr std::string_view PROPERTY_CACHE_PATH             = "cache_path";
constexpr std::string_view PROPERTY_FORCE_SHADER_REFRESH   = "force_shader_refresh";
constexpr std::string_view PROPERTY_FIRST_FRAME_CALLBACK   = "first_frame_callback";
constexpr std::string_view PROPERTY_POINTER_INPUT_CALLBACK = "pointer_input_callback";
constexpr std::string_view PROPERTY_USER_SHORTCUT_CALLBACK = "user_shortcut_callback";
constexpr std::string_view PROPERTY_AUDIO_REQUIREMENT_CALLBACK = "audio_requirement_callback";
constexpr std::string_view PROPERTY_RENDER_FAILURE_CALLBACK     = "render_failure_callback";

/// Plan decision I3: `<directory>/global.json` and `<directory>/screen-<screen_key>.json`.
/// An empty directory keeps `localStorage` in memory only.
struct SceneScriptStorageConfig {
    std::string directory;
    std::string screen_key;
    bool        read_only { false };
};

#include "Core/NoCopyMove.hpp"
class MainHandler;
struct RenderInitInfo;
struct SceneWallpaperConfig {
    std::string source;
    std::string assets;
    std::string cache_path;
    std::string project_property_override_json;
    uint32_t    fps { 15 };
    bool        paused { false };
    /// The sound the wallpaper has from the start. The scene can load as soon as it is
    /// configured, and its sounds play once mounted, before a later `PROPERTY_VOLUME` or
    /// `PROPERTY_MUTED` is read; set afterwards, they would arrive after the music began.
    float       volume { 1.0f };
    bool        muted { false };
    bool        force_shader_refresh { false };
    bool        has_project_property_override { false };
};

class SceneWallpaper : NoCopy {
public:
    SceneWallpaper();
    ~SceneWallpaper();
    bool init();
    bool inited() const;
    void shutdown();
    /// Tags every line this scene's threads log with `scope`. Call before
    /// `init()`; see `SetWallpaperLogScope`.
    void setLogScope(uint64_t scope);

    void initSurface(const RenderInitInfo&);
    void applyConfig(const SceneWallpaperConfig&);

    bool beginSurfaceReconfigure();

    bool finishSurfaceReconfigure(const RenderInitInfo& info);

    void play();
    void pause();
    // Playback and the scene to show.
    void setPaused(bool is_paused);
    void setSceneSource(std::string scene_source);
    void setAssetsPath(std::string assets_path);
    void setCachePath(std::string cache_directory);
    void setTargetFps(uint32_t frames_per_second);

    // Pointer input, in 0..1 across the surface; buttons as a press/release and as a level.
    void mouseInput(double unit_x, double unit_y);
    void mouseButton(int which, bool is_down);
    void mouseButtonBaseline(uint32_t held_mask);
    void mouseEnter(bool inside);

    // Artwork of the current media item (RGBA8), or the clear value.
    void applySystemMediaArtwork(uint32_t width, uint32_t height, const uint8_t* rgba,
                                 std::size_t rgba_len);

    /// How this scene is currently being updated, and why.
    ///
    /// Pull-only live state, independent of diagnostic counting. Callers that
    /// have no renderer yet get `Continuous` with `UnknownInput`, never a
    /// value that reads as "nothing to do".
    [[nodiscard]] SceneUpdateDemand::Kind sceneUpdateKind() const;
    [[nodiscard]] uint32_t                sceneDemandReasons() const;

    /// Whether this surface's frame loop is alive, and whether it stopped
    /// after a failure.
    ///
    /// Pull-only, always on and independent of diagnostic counting, for the
    /// same reason as the update mode: it is state a settings pane shows and a
    /// host acts on. A caller with no renderer yet gets a zeroed snapshot that
    /// reports `Running`.
    [[nodiscard]] SurfaceHealthSnapshot surfaceHealth() const;

    /// Whether this scene has a renderer drawing it and, when it has none,
    /// why it is held instead.
    ///
    /// Reports what is the case now: a scene held in a failure has no
    /// renderer, whatever it had before.
    [[nodiscard]] SceneBackendSelection sceneBackendSelection() const;
    /// How this scene's video textures reached the shaders sampling them on the
    /// last frame drawn.
    [[nodiscard]] SceneVideoPath sceneVideoPath() const;
    /// Whether this wallpaper's compiled graph is running under the current
    /// scene optimisation setting. False while a change is still waiting for
    /// the next frame, which is what distinguishes a saved preference from one
    /// that is really in force.
    [[nodiscard]] bool sceneOptimizationApplied() const;
    /// The scene quality the loaded scene actually renders with: features the
    /// scene does not use (MSAA, shadows, volumetrics) read 0, and
    /// reflection / post-processing read what the parse applied. Empty before
    /// a scene has loaded.
    [[nodiscard]] std::optional<SceneQuality> qualityInForce() const;
    /// Kept for the next load; a loaded scene with another value is reloaded.
    void setSceneQuality(const SceneQuality&);
    void setSceneStorage(SceneScriptStorageConfig);
    /// See `PROPERTY_WE_USER_OPTIONS`.
    void setUserOptions(const WeUserOptions&);
    void setDisplayId(uint32_t identity);

    void setPropertyBool(std::string_view, bool);
    void setPropertyInt32(std::string_view, int32_t);
    void setPropertyFloat(std::string_view, float);
    void setPropertyString(std::string_view, std::string);
    void setPropertyObject(std::string_view, std::shared_ptr<void>);

    /// Where the presented wallpaper sits inside the slack the display leaves
    /// around it (see `WallpaperFraming`); the default centres it. Applied
    /// live like the scaling factor: nothing is rebuilt, an idle scene draws
    /// one frame to show it and a paused one shows it when playback resumes.
    /// The render handler holds the value, so it survives hot-switching,
    /// surface reconfiguration and a backend change. Each axis is clamped to
    /// [0, 1] and a non-finite one becomes the centre. Safe before the first
    /// frame: the value is kept and applied when the surface exists.
    void setFraming(const WallpaperFraming&);

    /// Copies the renderer work counters for this surface. Returns how many
    /// values were written, which is never more than `len`. Safe to call from
    /// any thread: every counter is an independent atomic, so the result is a
    /// set of live readings rather than one consistent instant.
    std::size_t counters(uint64_t* out, std::size_t len) const;

private:
    friend class MainHandler;
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif

    std::shared_ptr<MainHandler> m_main_handler;
};

#ifdef WESCENE_BUILD_TESTS
class Scene;
class SceneNode;
struct SceneWallpaperInputTestAccess {
    struct MouseButtonSnapshot {
        uint32_t down;
        uint32_t pressed;
        uint32_t released;
    };
    static void PostScene(SceneWallpaper&, std::shared_ptr<Scene>);
    static MouseButtonSnapshot ConsumeMouseButtons(SceneWallpaper&);
    /// How many property-preview commands the render thread has handled. A burst
    /// of documents is one pending command plus the one it was waiting behind.
    static uint64_t PropertyPreviewCommandsHandled(SceneWallpaper&);
#if defined(__APPLE__)
    static SceneWallpaper& FromNative(owe_scene_wallpaper&);
#endif
    /// Runs, on the render thread, the routine a failed draw runs: the failure
    /// is counted and latched, rendering stops, and the host's render-failure
    /// callback is told. A real presentation failure cannot be produced
    /// without breaking the GPU, so this is how the consequence is exercised.
    static void InjectFrameFailure(SceneWallpaper&);
    /// Before `init()`: the scene's sounds play on miniaudio's null backend, so a test
    /// opens no audio device, and what the output does can still be read.
    static void UseNullSoundOutput(SceneWallpaper&);
    /// How many times the scene's sound output has started.
    static uint64_t SoundOutputStarts(SceneWallpaper&);
    /// Whether the render thread has taken a surface, so that a configuration loads
    /// the scene as soon as it is handled.
    static bool SurfaceHandedOver(SceneWallpaper&);
};
#endif
} // namespace wallpaper
