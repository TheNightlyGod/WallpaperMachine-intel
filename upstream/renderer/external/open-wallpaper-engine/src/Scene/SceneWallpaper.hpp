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
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "Scene/include/Scene/SceneResolution.hpp"
#include "Scene/include/Scene/SceneVideoPath.hpp"
#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "Swapchain/ExSwapchain.hpp"

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
constexpr std::string_view PROPERTY_HORIZONTAL_FLIP            = "horizontal_flip";
constexpr std::string_view PROPERTY_SPEED                     = "speed";
constexpr std::string_view PROPERTY_GRAPHIVZ                  = "graphivz";
constexpr std::string_view PROPERTY_VOLUME                    = "volume";
constexpr std::string_view PROPERTY_MUTED                     = "muted";
constexpr std::string_view PROPERTY_AUDIO_RESPONSE_ENABLED    = "audio_response_enabled";
constexpr std::string_view PROPERTY_MEDIA_INTEGRATION_ENABLED = "media_integration_enabled";
constexpr std::string_view PROPERTY_MEDIA_EVENT_JSON          = "media_event_json";
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON =
    "project_property_override_json";
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_RESET = "project_property_reset";
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

    void initVulkan(const RenderInitInfo&);
    void applyConfig(const SceneWallpaperConfig&);

    /// Pauses rendering and releases the Vulkan surface + swapchain on the
    /// render thread. Blocks until the render thread confirms completion.
    /// The scene, shaders, render graph, audio, and runtime state remain
    /// loaded. Returns false on any internal failure.
    bool beginSurfaceReconfigure();

    /// Rebuilds the Vulkan surface + swapchain on the render thread from a
    /// new RenderInitInfo and resumes rendering. Blocks until the render
    /// thread confirms completion.
    /// Preconditions: `beginSurfaceReconfigure` has returned true since the
    /// last successful init/finish. Returns false on failure.
    bool finishSurfaceReconfigure(const RenderInitInfo& info);

    void play();
    void pause();
    void setPaused(bool paused);
    void setSceneSource(std::string source);
    void setAssetsPath(std::string assets);
    void setCachePath(std::string cache_path);
    void setTargetFps(uint32_t fps);
    void mouseInput(double x, double y);
    void mouseButton(int button, bool pressed);
    void mouseButtonBaseline(uint32_t down);
    void mouseEnter(bool entered);
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

    /// Which renderer actually drew this scene, and why it is not the
    /// preferred one.
    ///
    /// Reports the backend in use, never the preference: a scene that fell
    /// back has to look like it fell back.
    [[nodiscard]] SceneBackendSelection sceneBackendSelection() const;
    /// How this scene's video textures reached the shaders sampling them on the
    /// last frame drawn.
    [[nodiscard]] SceneVideoPath sceneVideoPath() const;
    /// Whether this wallpaper's compiled graph is running under the current
    /// scene optimisation setting. False while a change is still waiting for
    /// the next frame, which is what distinguishes a saved preference from one
    /// that is really in force.
    [[nodiscard]] bool sceneOptimizationApplied() const;

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

    ExSwapchain* exSwapchain() const;

    // Ownership-transfer getter for the dma_fence sync_file fd that
    // was exported after the most recent completed offscreen frame.
    // Returns -1 if no frame has completed since the last call (or
    // export failed). The caller MUST close() the returned fd.
    int takeLastFrameSyncFd();

    /// Copies the renderer work counters for this surface. Returns how many
    /// values were written, which is never more than `len`. Safe to call from
    /// any thread: every counter is an independent atomic, so the result is a
    /// set of live readings rather than one consistent instant.
    std::size_t counters(uint64_t* out, std::size_t len) const;

private:
    bool m_inited { false };

private:
    friend class MainHandler;
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif

    bool                         m_offscreen { false };
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
    /// The production plain-video project scene for `project_json`, built the
    /// way `loadScene` builds it, without needing a render surface.
    static std::shared_ptr<Scene> CreateVideoProjectScene(const std::string& project_json,
                                                          std::string*       error);
    /// The production plain-video layer -- its quad and its copy shader --
    /// sampling `texture`, without a media file to probe.
    static std::shared_ptr<SceneNode> CreateVideoProjectNode(const std::string& texture,
                                                             std::string*       error);
#if defined(__APPLE__)
    static SceneWallpaper& FromNative(owe_scene_wallpaper&);
#endif
    /// Runs, on the render thread, the routine a failed draw runs: the failure
    /// is counted and latched, rendering stops, and the host's render-failure
    /// callback is told. A real presentation failure cannot be produced
    /// without breaking the GPU, so this is how the consequence is exercised.
    static void InjectFrameFailure(SceneWallpaper&);
};
#endif
} // namespace wallpaper
