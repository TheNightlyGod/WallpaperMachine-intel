#pragma once

#include "Core/RendererCounters.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "Scene/include/Scene/SceneResolution.hpp"
#include "Type.hpp"

#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{
class Scene;

namespace rg
{
class RenderGraph;
}

namespace metal
{

/// Everything the native backend needs to start drawing.
///
/// `metal_layer` is the `CAMetalLayer` the host created for this wallpaper
/// window, never the `NSView`. The backend takes the layer over: it owns the
/// drawable for as long as it is running, because two drawable loops cannot share one layer.
struct MetalRenderInitInfo
{
    void*                 metal_layer { nullptr };
    uint16_t              width { 1920 };
    uint16_t              height { 1080 };
    uint16_t              render_width { 0 };
    uint16_t              render_height { 0 };
    double                display_scale_factor { 1.0 };
    std::function<void()> redraw_callback;

    /// Asked on the render thread whether the host wants a still of the
    /// wallpaper right now. Empty means posters are never captured, and the
    /// capture path then costs nothing.
    std::function<bool()> wants_poster;
    /// Delivers one captured still: the pixel bytes, width, height, and whether
    /// those bytes are BGRA rather than RGBA. Called from a Metal-owned thread
    /// once the capture's command buffer completes.
    std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)> poster_ready;
};

/// Outcome of one `ServicePosterRequest` call.
///
/// `NoFrameYet` is not a failure: it is the answer while the compiled graph has
/// never been drawn, and composing then would publish an empty image as if it
/// were the wallpaper.
enum class PosterServiceResult : uint8_t
{
    NotRequested,
    Submitted,
    NoFrameYet,
    Busy,
    Failed,
};

/// Whether this machine has a Metal device at all. Tests that need one skip
/// visibly when it answers false rather than passing on a machine that never
/// ran them.
[[nodiscard]] bool MetalDeviceAvailable();

/// What this process knows about its pipeline archives, for the settings
/// surface and for tests.
struct MetalPipelineArchiveStatus
{
    /// An archive file for this device was opened, or created to be written.
    bool     available { false };
    /// Pipelines this process has offered to the archive because creating them
    /// found nothing stored. Not a failure count: the first run of a wallpaper
    /// has nothing stored by definition.
    uint64_t collected { 0 };
    /// Times the archive was written back out.
    uint64_t published { 0 };
};
[[nodiscard]] MetalPipelineArchiveStatus MetalPipelineArchiveStatusForDiagnostics();

/// Native Metal scene renderer.
///
/// The scene's render handler holds it behind `SceneRendererHandle`. It is the
/// draw backend only: parsing, the scene graph, materials, shaders, animation,
/// scripts, resource resolution and pause policy are all unchanged and shared.
///
/// There is no clock in here. The scene's existing `FrameTimer` remains the
/// single clock; this acquires one drawable per `drawFrame` call and never
/// starts a display link of its own, so the configured frame-rate ceiling and
/// the on-demand idle path keep working.
class MetalRender {
public:
    MetalRender();
    ~MetalRender();

    MetalRender(const MetalRender&) = delete;
    MetalRender& operator=(const MetalRender&) = delete;

    bool init(const MetalRenderInitInfo& info);
    void destroy();
    [[nodiscard]] bool inited() const;

    /// Releases presentation-scoped state: the layer and its drawable. The
    /// device, queue, compiled pipelines and uploaded textures survive, so a
    /// display reconfiguration does not reload the wallpaper.
    bool releaseSurface();
    bool resetSurface(const MetalRenderInitInfo& info);

    /// Releases the compiled graph and everything that belongs to it: the scene's
    /// videos are closed.
    bool clearLastRenderGraph();
    /// The first half of building the same scene's graph again, as the host does
    /// whenever something the graph is made of changes under a scene that is
    /// playing. The scene's videos are not closed: they are kept open for the
    /// `compileRenderGraph` that follows, which takes back the ones its graph
    /// still uses and closes the rest with it. The video then does not start
    /// over at the head of its clip, and a video packaged in the scene is not read
    /// again. Only for a compile of the scene that was drawing, which must follow.
    bool clearLastRenderGraphForRebuild();
    bool compileRenderGraph(Scene& scene, rg::RenderGraph& graph);
    /// Gives an already compiled graph the render target sizes the scene holds now, for a
    /// change that only resized targets (the buffers an effect chain draws into follow the
    /// size of the text it is applied to). The prepared passes, their pipelines and vertex
    /// buffers, the uploaded images and the videos are kept, which is what a rebuild repeats
    /// and a scene with heavy models and textures pays for dearly; the targets, the copy plan
    /// and the reuse table are made again as a compile makes them, so the next frame draws
    /// what a compile would have drawn. The targets are cleared in that frame's own command
    /// buffer and nothing waits on the GPU. False leaves the graph unusable: build it again.
    bool ResizeRenderTargets(Scene& scene);
    /// Applies a new internal rasterization scale, and the resolution the scene
    /// is rasterized at, to an already compiled graph. Render targets and the
    /// pipelines attached to them are rebuilt, and only when one of the two
    /// changes what this scene rasterizes; the parsed scene, uploaded images and
    /// shader libraries are not.
    bool ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale,
                          SceneResolution resolution);

    /// Draws one frame. `presented`, when given, reports whether a frame
    /// actually reached the layer: returning true having presented nothing is
    /// how a tick that found no drawable is distinguished from a failure, and
    /// the caller needs that difference to decide when the first frame exists.
    /// With scene optimisation on, a frame whose passes were all reused and
    /// whose composition would repeat the last present takes no drawable,
    /// commits nothing and also reports `presented` false.
    bool drawFrame(Scene& scene, bool* presented = nullptr);

    /// Forgets the last presented composition, so the next frame presents
    /// whatever it would have presented anyway.
    void InvalidatePresentedFrame();

    /// Serves a pending poster request outside the frame loop. Render thread
    /// only.
    ///
    /// Composes the output image the last drawn frame left, exactly as the
    /// drawable composition does. It draws no scene pass, advances no clock,
    /// runs no shader value update and takes no drawable, so an idle wallpaper
    /// can be captured without being resumed.
    PosterServiceResult ServicePosterRequest(Scene& scene);

    void UpdateCameraFillMode(Scene& scene, FillMode fillmode);
    void SetWallpaperScalingMode(WallpaperScalingMode mode);
    void SetWallpaperScalingFactor(double factor);
    /// Where the presented image sits in the slack around it. The composition,
    /// the cursor mapping and a poster all take it from the one layout, so they
    /// agree. Takes effect on the next frame; no pass or target is rebuilt.
    void SetWallpaperFraming(const WallpaperFraming& framing);
    /// Mirrors the presented wallpaper left to right from the next frame on. No pass or target
    /// is rebuilt.
    void SetWallpaperHorizontalFlip(bool enabled);

    /// Where this surface keeps the compiled pipelines it can rebuild.
    ///
    /// Set with the scene, because that is where the path is known, and per
    /// renderer rather than per process: two displays showing different
    /// wallpapers have different caches, and one must not file its pipelines
    /// under the other's. An empty path turns the archive off for this surface
    /// -- pipelines are created exactly as they were before, and nothing is
    /// read or written.
    ///
    /// The contents are regenerable. They live beside that scene's compiled
    /// shaders and are removed with them; nothing a user imported is stored
    /// there.
    void SetPipelineArchivePath(std::string_view path);
    /// Forwarded to the video textures this scene binds, and remembered for
    /// textures prepared later, so the host's pause policy has one shape.
    void SetVideoPlaybackPaused(bool paused);
    void SetVideoPlaybackRate(float rate);

    /// How this scene's video textures reached the shaders that sample them on
    /// the last frame drawn. A report, not a request: a scene with no video, or
    /// one that has not drawn yet, says `None`.
    [[nodiscard]] VideoFramePath VideoPath() const;

    /// Scene-level demand bits for the graph currently compiled, in the same
    /// `render::DynamicReason` vocabulary, so
    /// the on-demand mapping has one vocabulary to consume.
    ///
    /// Reports `UnknownInput` before any graph has been analysed, and for any
    /// pass whose inputs this backend cannot account for. Reporting nothing
    /// would tell the on-demand path a still-animating scene is provably
    /// static and let it stop the clock.
    ///
    /// The video bit is evaluated on every call rather than latched at compile:
    /// pausing playback changes the answer without rebuilding the graph.
    [[nodiscard]] uint32_t ShaderUpdateDemandReasons() const;

    void SetCounters(RendererCounters* counters);

    [[nodiscard]] WallpaperCursorMapping CursorMapping(const Scene& scene) const;

    /// Why the last failed call failed, for the fallback reason the settings
    /// pane shows. Empty when nothing has failed.
    [[nodiscard]] const std::string& lastError() const;

#ifdef WESCENE_BUILD_TESTS
    /// Copies one render target back to host memory as RGBA8.
    ///
    /// Test-only, and the only way to see what the author's translated shader
    /// actually wrote: the targets are private-storage textures and the
    /// drawable is gone once it has been presented. Synchronous by nature,
    /// which is why it is not on the per-frame path.
    bool ReadRenderTargetForTests(const std::string& key, std::vector<uint8_t>& rgba,
                                  uint32_t& width, uint32_t& height,
                                  std::vector<float>* radiance = nullptr);

    /// How many times pixels have been written into a replaceable image since
    /// this graph was compiled.
    ///
    /// Test-only, and the only externally visible difference between "the text
    /// did not change" and "the text was uploaded again anyway": both draw the
    /// same picture.
    [[nodiscard]] uint64_t RuntimeImageUploadsForTests() const;

    /// Encoders the pass loop of the last drawn frame opened: render passes,
    /// how many of them rendered into the scene's output image, and blits.
    ///
    /// Test-only, and the only way to see how a frame was split into passes:
    /// the picture is the same whether two layers share one render pass or
    /// open one each. The final composition and a poster capture are not scene
    /// passes and are not counted.
    struct FrameEncodeCountsForTests
    {
        uint32_t render_passes { 0 };
        uint32_t scene_output_passes { 0 };
        uint32_t blit_passes { 0 };
    };
    [[nodiscard]] FrameEncodeCountsForTests LastFrameEncodeCountsForTests() const;

    /// Bytes Metal allocated for this renderer's colour and depth targets, each
    /// texture counted once however many keys share it.
    ///
    /// Test-only, and the number to compare when target residency changes: the
    /// device's own counter is process-wide and moves with the drawable pool.
    [[nodiscard]] uint64_t RenderTargetBytesForTests() const;

    /// Whether render targets whose lifetimes in a frame do not overlap share
    /// one image, for graphs compiled from now on. On unless
    /// `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0`; process-wide, test-only.
    static void SetTargetSharingForTests(bool enabled);

    /// How many shader sources this process has handed to the Metal compiler.
    ///
    /// Test-only, and process-wide rather than per renderer: what it exists to
    /// show is that a second surface, or the same wallpaper loaded again, does
    /// not compile a program that is already compiled.
    [[nodiscard]] static uint64_t ProgramCompilesForTests();

    /// The texture this renderer binds for picture slot `slot` of the scene texture
    /// `key`, as an opaque handle (null when it has none). Two renderers that answer the
    /// same handle show one texture.
    [[nodiscard]] const void* ImportedImageForTests(const std::string& key, std::size_t slot = 0) const;
    /// Source bytes of the imported pictures alive in this process, each counted once
    /// however many renderers bind it.
    [[nodiscard]] static uint64_t SharedImageBytesForTests();
    /// Entries the process-wide picture cache holds, dead ones included until the next
    /// import prunes them.
    [[nodiscard]] static std::size_t SharedImageEntriesForTests();
    /// Picture slots uploaded to a GPU by any renderer since the process started.
    [[nodiscard]] static uint64_t ImageUploadsForTests();

    /// Whether the pipeline archive can supply every pipeline this process has
    /// created so far, asked strictly.
    ///
    /// Test-only, and deliberately not on the production path: it asks Metal to
    /// fail rather than compile when the archive has nothing, which is the only
    /// way to tell a real archive hit from a fast compile. A wallpaper must
    /// never be refused a pipeline because a cache missed, so the renderer
    /// itself never asks this question.
    [[nodiscard]] static bool PipelineArchiveServesEverySeenPipelineForTests();
    /// Returns once every pipeline-archive write already scheduled has run.
    static void WaitForPipelineArchiveWritesForTests();

    /// What the process-wide pipeline-archive bookkeeping holds right now.
    struct ArchiveResidency
    {
        /// Stores kept open at once (never more than eight).
        std::size_t stores { 0 };
        /// Stores that carry a write-generation record. A record exists only for an
        /// open store and goes with it, so this never exceeds `stores`.
        std::size_t generation_records { 0 };
    };
    [[nodiscard]] static ArchiveResidency PipelineArchiveResidencyForTests();

    /// One open store, by the directory it lives in, on the default device.
    struct ArchiveStoreState
    {
        bool        open { false };
        /// Pipeline descriptors the store has accepted from completed compiles.
        std::size_t descriptors { 0 };
        /// Names the store this answer is about: it changes whenever a store is opened
        /// again after having been let go.
        uint64_t    identity { 0 };
        /// Writes of the file this store has started.
        uint64_t    writes { 0 };
        /// The object additions are made on and that a write publishes.
        const void* collector { nullptr };
    };
    [[nodiscard]] static ArchiveStoreState PipelineArchiveStoreForTests(std::string_view archive_root);

    /// Holds back (or lets run) the queue the archive's additions and writes
    /// complete on. While held, nothing completes; everything queued runs on release.
    static void SuspendPipelineArchiveQueueForTests(bool suspended);

    /// Builds one small pipeline, distinct for every `variant`, for the default
    /// device as a scene would: it opens the store of `archive_root` if that is
    /// not open and hands the pipeline to it. False if the machine has no device
    /// or Metal refuses the pipeline.
    static bool BuildArchivedPipelineForTests(std::string_view archive_root, uint32_t variant);
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> pImpl;
};

} // namespace metal
} // namespace wallpaper
