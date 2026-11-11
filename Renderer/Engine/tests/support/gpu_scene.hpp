// A headless GPU harness for tests that need to see what a scene draws.
//
// `GpuScene` loads a `ScenePackage` the way the host does (project folder, shared file space,
// scratch shader cache, property tables, the scene parser), builds the render graph, compiles
// it with the native Metal renderer on a layer no window owns, advances frames with a fixed
// time step and a fixed random seed, and hands back the final picture as RGBA8. Every GPU
// image is private to the process: the renderer draws into a detached `CAMetalLayer`, and the
// picture is read from the poster texture the renderer composes for itself, never from a
// window or the desktop.
//
// A test that uses it skips, with a message, on a machine without a Metal device.
#pragma once

#include "support/pixels.hpp"
#include "support/scene_package.hpp"
#include "Scene/WeUserOptions.hpp"
#include "Scene/SceneQuality.hpp"
#include "MetalRender/MetalRender.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper
{
class Scene;
class SceneRuntimeContext;
namespace metal
{
class MetalRender;
}
} // namespace wallpaper

namespace we_test
{

/// Whether this process can use a Metal device. Setting `WE_TEST_SIMULATE_NO_METAL=1` makes it
/// answer false, which is how the skip path is exercised on a machine that has one.
bool MetalAvailable();

/// Skips the running test, with the reason, when `MetalAvailable()` is false.
#define WE_SKIP_WITHOUT_METAL()                                                                    \
    do {                                                                                           \
        if (!::we_test::MetalAvailable()) GTEST_SKIP() << "no Metal device in this process";       \
    } while (false)

struct GpuSceneOptions {
    /// Size of the surface in points; the picture is `width * backing_scale` pixels wide.
    uint32_t width { 256 };
    uint32_t height { 144 };
    double   backing_scale { 1.0 };
    /// Seconds each frame advances the scene clock, whatever the wall clock did.
    double time_step { 1.0 / 60.0 };
    /// Seed of the engine's random source (see `Random::seed`), applied before the scene is
    /// parsed and again by `Reseed()`.
    uint32_t seed { 1 };
    /// The user's saved property values, as the host passes them on load: a flat object of
    /// property name to value.
    Json saved_properties { Json::object() };
    /// Static reuse and copy elimination. Process-wide and restored when the scene is
    /// destroyed; switch it off to count every pass of every frame.
    bool scene_optimization { true };
    /// The internal render scale the graph is compiled at, as the host's quality setting
    /// applies it: 1 draws at full resolution.
    double render_scale { 1.0 };
    /// The container version the scene file is read as, as a package of that version would
    /// say it. 0 reads every key the scene file holds, as a loose project does.
    uint16_t package_version { 0 };
    /// Wallpaper Engine's per-wallpaper options the scene is parsed with (identity by default).
    wallpaper::WeUserOptions user_options {};
    wallpaper::SceneQuality quality {};
    std::function<wallpaper::metal::MetalDisplayCharacteristics(uint32_t)> display_characteristics;
    bool display_hdr_output_allowed {true};
    uint32_t display_id {0};
};

/// What the renderer opened for one frame: the pass count a test compares between scenes.
struct PassCounts {
    uint32_t render_passes { 0 };
    /// How many of the render passes drew into the scene's output image.
    uint32_t scene_output_passes { 0 };
    uint32_t blit_passes { 0 };
    [[nodiscard]] uint32_t total() const { return render_passes + blit_passes; }
};

class GpuScene {
public:
    /// Loads the package and compiles its render graph. Check `ok()` before using the rest.
    explicit GpuScene(const ScenePackage& package, GpuSceneOptions options = {});
    ~GpuScene();
    GpuScene(const GpuScene&)            = delete;
    GpuScene& operator=(const GpuScene&) = delete;

    /// False when the Metal device is missing, the scene did not load, the backend refused it
    /// or the graph did not compile. `error()` then says why.
    [[nodiscard]] bool                ok() const;
    [[nodiscard]] const std::string&  error() const;

    // ---- running ----------------------------------------------------------------------

    /// Advances `frames` frames the way the host's frame handler does: pointer, runtime tick
    /// (scripts, property bindings, animations), graph changes the tick asked for, then the
    /// draw. False if a frame failed; `error()` says why.
    bool Step(int frames = 1);
    /// `Step(frames)` and then `Picture()`.
    Image Run(int frames);
    /// The final composition of the last frame drawn, read back. Empty on failure.
    Image Picture();
    /// Where the pointer is, in 0..1 across the surface with y down. Applies from the next frame.
    void SetPointer(double x, double y);
    /// Restarts the random source with `options.seed`.
    void Reseed();
    /// Gives a user property a new value while the scene runs, as the host's live property
    /// preview does. Values set earlier stay set. Takes effect on the next `Step`.
    bool SetProperty(const std::string& name, const Json& value);
    /// Runs the runtime (scripts, bindings, animations) for `seconds` without drawing.
    void TickRuntime(double seconds);

    // ---- looking inside ---------------------------------------------------------------

    /// Counts for the last frame drawn, and for every frame `Step` has run (oldest first).
    /// With static reuse on, a frame that changed nothing opens no pass; the first frame after
    /// a compile always opens them all.
    [[nodiscard]] PassCounts                 LastFramePasses() const;
    [[nodiscard]] const std::vector<PassCounts>& FramePasses() const;
    [[nodiscard]] PassCounts                 FirstFramePasses() const;
    [[nodiscard]] uint64_t                   frames() const;

    /// Every render target of the compiled scene, by name.
    [[nodiscard]] std::vector<std::string> RenderTargetNames() const;
    /// The targets that belong to image layer `id`: the buffers of its effect chain.
    [[nodiscard]] std::vector<std::string> RenderTargetsOfLayer(int id) const;
    /// Reads one render target back as RGBA8 (and, when asked, as the float values of a
    /// half-float target). False if the name is unknown.
    bool ReadRenderTarget(const std::string& name, Image* out, std::vector<float>* radiance = nullptr);
    /// `ReadRenderTarget` returning an empty image when the name is unknown.
    Image RenderTarget(const std::string& name);

    // ---- the graph --------------------------------------------------------------------

    /// Builds and compiles the render graph again over the same scene, which is what the host
    /// does whenever a change needs a new graph. The first picture afterwards draws every pass.
    bool Rebuild();
    /// How many times the graph was compiled after the first time, whether by `Rebuild()` or
    /// because a frame's tick asked for it.
    [[nodiscard]] int RebuildCount() const;

    /// Releases the renderer, the graph and the scene. Everything but `ok()` and `error()` is
    /// unusable afterwards. The destructor does the same.
    void Release();
    [[nodiscard]] bool released() const;

    // ---- access for tests that need more ----------------------------------------------

    [[nodiscard]] wallpaper::Scene&                scene();
    [[nodiscard]] wallpaper::SceneRuntimeContext*  runtime();
    [[nodiscard]] wallpaper::metal::MetalRender&   renderer();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace we_test
