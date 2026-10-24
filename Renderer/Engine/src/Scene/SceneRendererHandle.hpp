#pragma once

#include "MetalRender/MetalRender.hpp"
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "SceneBackendFaults.hpp"
#include "SceneWallpaperSurface.hpp"

#include <memory>
#include <string>
#include <utility>

namespace wallpaper
{

/// Owns the renderer that draws this surface: the native Metal one, and nothing
/// else.
///
/// Starts empty. Whether a scene can be drawn is only known once the scene is
/// parsed, and creating a device before then means creating one that the very
/// next step may have to tear down (a scene that is refused gets none).
/// Every forwarder therefore has to answer for an empty handle, and each answers
/// with the honest "nothing has been created yet" value rather than with a value
/// that reads as a fact.
///
/// The forwarders exist so the scene wallpaper's code reads the same whether or
/// not a renderer has been created; they are not an interface to swap another
/// renderer in.
class SceneRendererHandle : NoCopy, NoMove {
public:
    SceneRendererHandle() = default;

    /// Whether the renderer exists. Distinct from `inited()`: a creation that
    /// failed leaves nothing, and a caller deciding whether to re-create needs
    /// to tell "not yet" from "there and working".
    [[nodiscard]] bool hasBackend() const { return m_metal != nullptr; }

    /// Creates the native renderer on this surface, replacing whatever was
    /// there.
    ///
    /// On failure the handle is left empty and `error` says why, so the caller
    /// records the failure against the scene and reports it; nothing else may
    /// draw the scene.
    [[nodiscard]] bool createMetal(const RenderInitInfo& info, std::string& error) {
        release();
#ifdef WESCENE_BUILD_TESTS
        if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                testing::SceneBackendFault::NativeCreate)) {
            error = *forced;
            return false;
        }
#endif
        auto candidate = std::make_unique<metal::MetalRender>();
        if (! candidate->init(toMetalInitInfo(info))) {
            error = candidate->lastError();
            return false;
        }
        m_metal = std::move(candidate);
        if (! m_pipeline_cache_path.empty()) m_metal->SetPipelineArchivePath(m_pipeline_cache_path);
        return true;
    }

    /// Destroys the renderer, leaving the handle empty.
    void release() {
#ifdef WESCENE_BUILD_TESTS
        m_forced_error.clear();
#endif
        if (m_metal != nullptr) {
            m_metal->destroy();
            m_metal.reset();
        }
    }

#define OWE_FORWARD(call) if (m_metal != nullptr) return m_metal->call

#define OWE_FORWARD_VOID(call)                                                                     \
    if (m_metal != nullptr) m_metal->call

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
    /// The layer is replaced by that reconfiguration, so the renderer has to be
    /// told about the new one. Returns false when it cannot take the new layer;
    /// the caller owns what that means, which is holding the scene and
    /// reporting the failure.
    bool resetSurface(const RenderInitInfo& info) {
#ifdef WESCENE_BUILD_TESTS
        if (m_metal != nullptr) {
            if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                    testing::SceneBackendFault::NativeSurface)) {
                m_forced_error = *forced;
                return false;
            }
        }
#endif
        if (m_metal != nullptr) return m_metal->resetSurface(toMetalInitInfo(info));
        return false;
    }

    /// Why the renderer last failed, for the failure reason shown to the user.
    /// Empty when nothing failed.
    [[nodiscard]] std::string lastError() const {
#ifdef WESCENE_BUILD_TESTS
        if (! m_forced_error.empty()) return m_forced_error;
#endif
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
#ifdef WESCENE_BUILD_TESTS
        if (m_metal != nullptr) {
            if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                    testing::SceneBackendFault::NativeCompile)) {
                m_forced_error = *forced;
                return false;
            }
        }
#endif
        OWE_FORWARD(compileRenderGraph(scene, graph));
        return false;
    }
    /// The first half of what a rebuild does, for a change that only resized render targets:
    /// the targets are allocated again and the compiled graph keeps the rest.
    bool ResizeRenderTargets(Scene& scene) {
        OWE_FORWARD(ResizeRenderTargets(scene));
        return false;
    }
    bool ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale,
                          SceneResolution resolution) {
        OWE_FORWARD(ApplyRenderScale(scene, graph, scale, resolution));
        return false;
    }
    /// How the scene's video textures reached their shaders on the last frame.
    [[nodiscard]] SceneVideoPath VideoPath() const {
        if (m_metal != nullptr) return m_metal->VideoPath();
        return SceneVideoPath::None;
    }

    /// Re-applies the scene optimisation setting to an already-compiled graph.
    ///
    /// The renderer applies the same change inside `drawFrame`, at the point
    /// where it holds the command buffer the reallocated targets are cleared
    /// into, and reports it applied here so the caller's bookkeeping knows.
    bool ApplySceneOptimization(Scene&, rg::RenderGraph&) { return m_metal != nullptr; }
    /// Draws one frame. `presented` reports whether a frame actually reached
    /// the surface; the renderer may legitimately succeed without producing
    /// one, and the caller's first-frame bookkeeping has to tell the two apart.
    bool drawFrame(Scene& scene, bool* presented = nullptr) {
#ifdef WESCENE_BUILD_TESTS
        if (m_metal != nullptr) {
            if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                    testing::SceneBackendFault::NativeDraw)) {
                m_forced_error = *forced;
                if (presented != nullptr) *presented = false;
                return false;
            }
        }
#endif
        OWE_FORWARD(drawFrame(scene, presented));
        if (presented != nullptr) *presented = false;
        return false;
    }
    /// Makes the next frame present whatever it draws, even if it would repeat
    /// the last one exactly.
    void InvalidatePresentedFrame() { OWE_FORWARD_VOID(InvalidatePresentedFrame()); }

    /// Completes a pending poster request without drawing anything new.
    ///
    /// It reads back the last finished composition, so an idle or user-paused
    /// scene is sampled without a drawable, a scene-time advance or a re-run of
    /// its passes.
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
    /// Where compiled pipelines are kept beside this scene's shaders: Metal's
    /// binary archive.
    void SetPipelineArchivePath(std::string_view path) {
        m_pipeline_cache_path = std::string(path);
        if (m_metal != nullptr) m_metal->SetPipelineArchivePath(path);
    }
    void SetVideoPlaybackPaused(bool value) { OWE_FORWARD_VOID(SetVideoPlaybackPaused(value)); }
    void SetVideoPlaybackRate(float value) { OWE_FORWARD_VOID(SetVideoPlaybackRate(value)); }
    /// `UnknownInput` with no backend, never 0: 0 means the graph was analysed
    /// and proved static, which would let the on-demand path stop the clock for
    /// a scene nothing has looked at yet.
    uint32_t ShaderUpdateDemandReasons() const {
        OWE_FORWARD(ShaderUpdateDemandReasons());
        return static_cast<uint32_t>(render::DynamicReason::UnknownInput);
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

    std::unique_ptr<metal::MetalRender> m_metal;
    std::string                         m_pipeline_cache_path;
#ifdef WESCENE_BUILD_TESTS
    /// The reason of the last fault a test armed that fired, so `lastError`
    /// reads like the real renderer's own message.
    std::string m_forced_error;
#endif
};

} // namespace wallpaper
