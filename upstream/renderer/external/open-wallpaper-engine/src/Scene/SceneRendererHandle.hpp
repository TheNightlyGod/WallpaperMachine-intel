#pragma once

#include "MetalRender/MetalRender.hpp"
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "VulkanRender/VulkanRender.hpp"

#include <memory>
#include <string>
#include <utility>

namespace wallpaper
{

/// Owns whichever renderer is drawing this surface, and never more than one.
///
/// The two backends present to the same `CAMetalLayer`, and a layer has exactly
/// one drawable producer: a Vulkan swapchain and a Metal drawable loop running
/// together would fight over it. This type exists so that invariant is
/// structural rather than a rule someone has to remember — holding one means
/// not holding the other, and switching releases before it acquires.
///
/// Starts empty. Which backend a scene needs is only known once the scene is
/// parsed, and creating one before then means creating a device and a swapchain
/// that the very next step may have to tear down. Every forwarder therefore has
/// to answer for an empty handle, and each answers with the honest "nothing has
/// been created yet" value rather than with a value that reads as a fact.
///
/// The two renderers share their method names deliberately, so this forwards
/// rather than defining a virtual interface. Adding virtuals to `VulkanRender`
/// would put a dispatch on the per-pass path of the backend that draws every
/// wallpaper today, to serve a backend that draws a subset.
class SceneRendererHandle : NoCopy, NoMove {
public:
    SceneRendererHandle() = default;

    /// Whether a backend exists at all. Distinct from `inited()`: a creation
    /// that failed leaves neither, and a caller deciding whether to re-create
    /// needs to tell "not yet" from "there and working".
    [[nodiscard]] bool hasBackend() const { return m_metal != nullptr || m_vulkan != nullptr; }

    /// Which backend exists. Only meaningful when `hasBackend()` is true; an
    /// empty handle reports the compatibility backend because that is the
    /// default a caller would create, not because anything is drawing.
    [[nodiscard]] SceneBackend backend() const {
        return m_metal != nullptr ? SceneBackend::NativeMetal : SceneBackend::LegacyVulkan;
    }

    /// The Vulkan renderer, or null when Metal is driving this surface or
    /// nothing has been created yet.
    ///
    /// Only for the two entry points Metal has no equivalent of. Everything
    /// else goes through the forwarders, so a caller cannot accidentally reach
    /// past the active backend.
    [[nodiscard]] vulkan::VulkanRender* vulkanOnly() const { return m_vulkan.get(); }

    /// Creates the compatibility backend on this surface, replacing whatever
    /// was there.
    ///
    /// Releases first: the layer cannot carry a live swapchain and a Metal
    /// drawable at once. A failure leaves the handle empty rather than holding
    /// a renderer that cannot draw.
    [[nodiscard]] bool createVulkan(const RenderInitInfo& info) {
        release();
        auto candidate = std::make_unique<vulkan::VulkanRender>();
        if (! candidate->init(info)) return false;
        m_vulkan = std::move(candidate);
        if (! m_pipeline_cache_path.empty()) m_vulkan->SetPipelineCachePath(m_pipeline_cache_path);
        return true;
    }

    /// Creates the native backend on this surface, replacing whatever was
    /// there.
    ///
    /// On failure the handle is left empty and `error` says why, so the caller
    /// records the failure against the scene and creates the compatibility
    /// backend itself. Re-creating one here would hide which backend is
    /// drawing from the routine that has to publish it.
    [[nodiscard]] bool createMetal(const RenderInitInfo& info, std::string& error) {
        release();
        auto candidate = std::make_unique<metal::MetalRender>();
        if (! candidate->init(toMetalInitInfo(info))) {
            error = candidate->lastError();
            return false;
        }
        m_metal = std::move(candidate);
        if (! m_pipeline_cache_path.empty()) m_metal->SetPipelineArchivePath(m_pipeline_cache_path);
        return true;
    }

    /// Destroys whichever backend exists, leaving the handle empty.
    void release() {
        if (m_metal != nullptr) {
            m_metal->destroy();
            m_metal.reset();
        }
        if (m_vulkan != nullptr) {
            m_vulkan->destroy();
            m_vulkan.reset();
        }
    }

#define OWE_FORWARD(call)                                                                          \
    if (m_metal != nullptr) return m_metal->call;                                                  \
    if (m_vulkan != nullptr) return m_vulkan->call

#define OWE_FORWARD_VOID(call)                                                                     \
    if (m_metal != nullptr)                                                                        \
        m_metal->call;                                                                             \
    else if (m_vulkan != nullptr)                                                                  \
        m_vulkan->call

    bool inited() const {
        OWE_FORWARD(inited());
        return false;
    }
    void destroy() { OWE_FORWARD_VOID(destroy()); }
    bool releaseSurface() {
        OWE_FORWARD(releaseSurface());
        return false;
    }
    /// Re-establishes the surface after a display reconfiguration.
    ///
    /// The layer is replaced by that reconfiguration, so the Metal backend has
    /// to be told about the new one too. Returns false when the active backend
    /// cannot take the new layer; the caller owns the fallback, because
    /// switching backends carries bookkeeping this type has no business doing
    /// silently — remembering the failure against the scene, publishing the new
    /// backend and its reason, re-applying counters and pause. A holder that
    /// switched silently would leave the panel reporting a backend that is no
    /// longer drawing.
    bool resetSurface(const RenderInitInfo& info) {
        if (m_metal != nullptr) return m_metal->resetSurface(toMetalInitInfo(info));
        if (m_vulkan != nullptr) return m_vulkan->resetSurface(info);
        return false;
    }

    /// Why the active backend last failed, for the fallback reason shown to
    /// the user. Empty when nothing failed.
    [[nodiscard]] std::string lastError() const {
        if (m_metal != nullptr) return m_metal->lastError();
        return std::string {};
    }
    bool clearLastRenderGraph() {
        OWE_FORWARD(clearLastRenderGraph());
        return false;
    }
    /// `clearLastRenderGraph` for a graph that is about to be compiled again for
    /// the scene that is drawing it: the scene's videos stay open for that
    /// compile instead of starting over. The compile must follow.
    bool clearLastRenderGraphForRebuild() {
        OWE_FORWARD(clearLastRenderGraphForRebuild());
        return false;
    }
    bool compileRenderGraph(Scene& scene, rg::RenderGraph& graph) {
        OWE_FORWARD(compileRenderGraph(scene, graph));
        return false;
    }
    bool ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale,
                          SceneResolution resolution) {
        OWE_FORWARD(ApplyRenderScale(scene, graph, scale, resolution));
        return false;
    }
    /// How the scene's video textures reached their shaders on the last frame.
    /// Only the native backend has two paths to report; the compatibility
    /// backend always pre-converts, and says so rather than saying nothing.
    [[nodiscard]] SceneVideoPath VideoPath() const {
        if (m_metal != nullptr) return m_metal->VideoPath();
        return SceneVideoPath::None;
    }

    /// Re-applies the scene optimisation setting to an already-compiled graph.
    ///
    /// Only the compatibility backend needs to be asked: the native backend
    /// applies the same change inside `drawFrame`, at the point where it holds
    /// the command buffer the reallocated targets are cleared into, and
    /// reports it applied here so the caller's bookkeeping is the same either
    /// way.
    bool ApplySceneOptimization(Scene& scene, rg::RenderGraph& graph) {
        if (m_metal != nullptr) return true;
        if (m_vulkan != nullptr) return m_vulkan->ApplySceneOptimization(scene, graph);
        return false;
    }
    /// Draws one frame with whichever backend is active. `presented` reports
    /// whether a frame actually reached the surface; a backend may legitimately
    /// succeed without producing one, and the caller's first-frame bookkeeping
    /// has to tell the two apart.
    bool drawFrame(Scene& scene, bool* presented = nullptr) {
        OWE_FORWARD(drawFrame(scene, presented));
        if (presented != nullptr) *presented = false;
        return false;
    }
    /// Makes the next frame present whatever it draws, even if it would repeat
    /// the last one exactly.
    void InvalidatePresentedFrame() { OWE_FORWARD_VOID(InvalidatePresentedFrame()); }

    /// Completes a pending poster request without drawing anything new.
    ///
    /// Only the native backend can do this: it reads back the last finished
    /// composition, so an idle or user-paused scene is sampled without a
    /// drawable, a scene-time advance or a re-run of its passes. The Vulkan
    /// path polls `wants_poster` inside its own frame instead, so there is
    /// nothing to service here.
    metal::PosterServiceResult ServicePosterRequest(Scene& scene) {
        if (m_metal != nullptr) return m_metal->ServicePosterRequest(scene);
        return metal::PosterServiceResult::NotRequested;
    }

    void UpdateCameraFillMode(Scene& scene, FillMode mode) {
        OWE_FORWARD_VOID(UpdateCameraFillMode(scene, mode));
    }
    void SetWallpaperScalingMode(WallpaperScalingMode mode) {
        OWE_FORWARD_VOID(SetWallpaperScalingMode(mode));
    }
    void SetWallpaperScalingFactor(double value) {
        OWE_FORWARD_VOID(SetWallpaperScalingFactor(value));
    }
    void SetWallpaperFraming(const WallpaperFraming& value) {
        OWE_FORWARD_VOID(SetWallpaperFraming(value));
    }
    void SetWallpaperHorizontalFlip(bool value) {
        OWE_FORWARD_VOID(SetWallpaperHorizontalFlip(value));
    }
    /// Both backends keep compiled pipelines beside this scene's shaders.
    /// Metal uses its binary archive; Vulkan uses the driver's pipeline cache.
    void SetPipelineArchivePath(std::string_view path) {
        m_pipeline_cache_path = std::string(path);
        if (m_metal != nullptr) m_metal->SetPipelineArchivePath(path);
        if (m_vulkan != nullptr) m_vulkan->SetPipelineCachePath(m_pipeline_cache_path);
    }
    void SetVideoPlaybackPaused(bool value) { OWE_FORWARD_VOID(SetVideoPlaybackPaused(value)); }
    void SetVideoPlaybackRate(float value) { OWE_FORWARD_VOID(SetVideoPlaybackRate(value)); }
    double ShortestVideoFramePeriod() const {
        OWE_FORWARD(ShortestVideoFramePeriod());
        return 0.0;
    }
    /// `UnknownInput` with no backend, never 0: 0 means the graph was analysed
    /// and proved static, which would let the on-demand path stop the clock for
    /// a scene nothing has looked at yet.
    uint32_t ShaderUpdateDemandReasons() const {
        OWE_FORWARD(ShaderUpdateDemandReasons());
        return static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput);
    }
    void SetCounters(RendererCounters* counters) { OWE_FORWARD_VOID(SetCounters(counters)); }
    WallpaperCursorMapping CursorMapping(const Scene& scene) const {
        OWE_FORWARD(CursorMapping(scene));
        return WallpaperCursorMapping {};
    }

#undef OWE_FORWARD
#undef OWE_FORWARD_VOID

private:
    /// The one place a surface description becomes a native-backend one, so a
    /// field added to `RenderInitInfo` cannot reach creation but miss a surface
    /// reset.
    [[nodiscard]] static metal::MetalRenderInitInfo toMetalInitInfo(const RenderInitInfo& info) {
        metal::MetalRenderInitInfo metal_info;
        metal_info.metal_layer          = info.metal_layer;
        metal_info.width                = info.width;
        metal_info.height               = info.height;
        metal_info.render_width         = info.render_width;
        metal_info.render_height        = info.render_height;
        metal_info.display_scale_factor = info.display_scale_factor;
        metal_info.redraw_callback      = info.redraw_callback;
        metal_info.wants_poster         = info.wants_poster;
        metal_info.poster_ready         = info.poster_ready;
        return metal_info;
    }

    std::unique_ptr<vulkan::VulkanRender> m_vulkan;
    std::unique_ptr<metal::MetalRender>   m_metal;
    std::string                           m_pipeline_cache_path;
};

} // namespace wallpaper
