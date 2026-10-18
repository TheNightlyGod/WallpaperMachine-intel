#pragma once

#include "Core/RendererCounters.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Scene/include/Scene/SceneResolution.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Swapchain/ExSwapchain.hpp"
#include "Type.hpp"

#include <cstdio>
#include <memory>
#include <string>

namespace wallpaper
{
class Scene;

namespace vulkan
{
class FinPass;

class VulkanRender {
public:
    VulkanRender();
    ~VulkanRender();

    bool init(RenderInitInfo);

    void destroy();

    /// Pauses rendering and releases presentation-scoped resources:
    /// VkSurfaceKHR, swapchain, FinPass/PrePass, and the presentation passes.
    /// The Vulkan instance, logical device, queues, and device-scoped
    /// buffers remain alive. Must be followed by `resetSurface` or `destroy`
    /// before another frame is drawn.
    bool releaseSurface();

    /// Rebuild the surface, swapchain, and presentation passes from a new
    /// RenderInitInfo. The scene, staging buffers, and command buffers are
    /// preserved. Returns false if surface/swapchain creation fails.
    bool resetSurface(const RenderInitInfo& info);

    /// Draws one frame. `presented`, when given, reports whether a frame
    /// actually reached the surface. A swapchain image that cannot be acquired
    /// is a failed frame here, not a skipped one. With scene optimisation on, a
    /// frame that would put back exactly the picture already on the surface --
    /// a plain video whose selected frame did not change, or a scene whose
    /// every pass was reused -- succeeds without acquiring, submitting or
    /// presenting, and reports `presented` false.
    bool drawFrame(Scene&, bool* presented = nullptr);

    /// Forgets the last presented frame, so the next frame presents whatever
    /// it would have presented anyway. For events outside the renderer that
    /// can change the picture without changing what a frame compares, such as
    /// resuming a paused wallpaper.
    void InvalidatePresentedFrame();

    /// Releases the compiled graph and everything that belongs to it: the scene's
    /// videos are closed.
    bool clearLastRenderGraph();
    /// The first half of building the same scene's graph again, as the host does
    /// whenever something the graph is made of changes under a scene that is
    /// playing. The scene's videos are not closed: their decoders are kept open for
    /// the `compileRenderGraph` that follows, which takes back the ones its graph
    /// still uses and closes the rest with it. The video then does not start over
    /// at the head of its clip, and a video packaged in the scene is not read
    /// again. Only for a compile of the scene that was drawing, which must follow.
    bool clearLastRenderGraphForRebuild();
    bool compileRenderGraph(Scene&, rg::RenderGraph&);
    /// Applies a new internal rasterization scale, and the resolution the scene
    /// is rasterized at, to an already compiled graph. Keeps the parsed scene,
    /// the render graph, uploaded images and live video decoders; only render
    /// targets and the passes that attach them are rebuilt, and only when one of
    /// the two changes what this scene rasterizes.
    bool ApplyRenderScale(Scene&, rg::RenderGraph&, double scale, SceneResolution resolution);
    /// Rebuilds the copy plan and the reuse table for the current scene
    /// optimisation setting, without reparsing the project, reopening a video
    /// or resetting a timeline. Called at a frame boundary when the setting
    /// changed, so turning the setting back on takes effect on the next frame
    /// rather than on the next graph compile.
    bool ApplySceneOptimization(Scene&, rg::RenderGraph&);
    void UpdateCameraFillMode(Scene&, wallpaper::FillMode);
    void SetWallpaperScalingMode(wallpaper::WallpaperScalingMode);
    void SetWallpaperScalingFactor(double);
    void SetWallpaperFraming(const wallpaper::WallpaperFraming&);
    void SetWallpaperHorizontalFlip(bool enabled);
    /// Driver pipeline cache beside this scene's shader cache. Empty clears it.
    void SetPipelineCachePath(std::string path);
    void SetVideoPlaybackPaused(bool paused);
    void SetVideoPlaybackRate(float rate);
    /// Shortest frame period among the live video sources, in seconds, or 0
    /// when any of them cannot report one. Read on the render thread only.
    [[nodiscard]] double ShortestVideoFramePeriod() const;

    /// Scene-level demand bits the renderer can prove from shader reflection
    /// and bound resources, for the graph currently compiled.
    ///
    /// Reports `UnknownInput` before any graph has been analysed rather than
    /// reporting nothing, so a caller cannot mistake "not asked yet" for
    /// "nothing changes".
    [[nodiscard]] uint32_t ShaderUpdateDemandReasons() const;

    /// Counters owned by the scene. Installed once, before any frame; the
    /// renderer and its texture cache only read the pointer.
    void SetCounters(RendererCounters* counters);

    /// World rectangle the presented wallpaper covers, for mapping
    /// window-normalized cursor input onto scene coordinates. Invalid before
    /// the output extent is known.
    WallpaperCursorMapping CursorMapping(const Scene&) const;

    ExSwapchain* exSwapchain() const;
    bool inited() const;

    // Transfer ownership of the most recent frame's exported dma_fence
    // sync_file fd. Returns -1 if no frame has been rendered since the
    // last call (or export failed). Caller owns the returned fd and
    // must close() it. Thread-safe.
    int takeLastFrameSyncFd();

private:
    struct Impl;
    std::unique_ptr<Impl> pImpl;
};
} // namespace vulkan
} // namespace wallpaper
