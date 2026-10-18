#pragma once
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <string_view>
#include <variant>
#include <vector>

#include "SceneTexture.h"
#include "SceneRenderTarget.h"
#include "SceneNode.h"
#include "SceneLight.hpp"
#include "SceneResolution.hpp"

#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
class ParticleSystem;
class IShaderValueUpdater;
class IImageParser;
class SceneRuntimeContext;
/// Declared, never defined here: the scene library must stay free of any
/// renderer, and a shared pointer to an incomplete type is all this needs.
struct SceneMetalProgram;

struct ScenePostProcessPass {
    std::shared_ptr<SceneNode> node;
    std::string                output;
    /// When positive, the pass's `g_RenderVar0` is kept at this many texels of
    /// its first texture, (+x, +y, -x, -y), whatever size that texture has.
    float                      source_texel_radius { 0.0f };
};

struct ScenePostProcessCopy {
    std::string src;
    std::string dst;
};

struct ScenePostProcess {
    using Step = std::variant<ScenePostProcessPass, ScenePostProcessCopy>;

    std::string       name;
    std::vector<Step> steps;
};

namespace fs
{
class VFS;
}
class Scene : NoCopy, NoMove {
public:
    Scene();
    ~Scene();

    std::unordered_map<std::string, SceneTexture>      textures;
    std::unordered_map<std::string, SceneRenderTarget> renderTargets;
    std::unordered_map<std::string, std::string>       renderTargetAliases;

    std::unordered_map<std::string, std::shared_ptr<SceneCamera>> cameras;
    std::unordered_map<std::string, std::vector<std::string>>     linkedCameras;

    std::vector<std::unique_ptr<SceneLight>> lights;
    /// The light counts lit shaders are compiled for (`general.lightconfig`).
    SceneLightConfig                         light_config;
    /// Distance and height fog (`general.fogdistance`, `general.fogheight`):
    /// a pass whose `FOG` combo is on is compiled with `FOG_DIST`/`FOG_HEIGHT`.
    bool                                     fog_distance { false };
    bool                                     fog_height { false };

    std::shared_ptr<SceneNode>           sceneGraph;
    std::vector<std::shared_ptr<ScenePostProcess>> post_processes;
    std::unique_ptr<IShaderValueUpdater> shaderValueUpdater;
    std::unique_ptr<IImageParser>        imageParser;
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::unique_ptr<fs::VFS>             vfs;
    /// Translated programs that could have an optional variant compiled for
    /// them later, collected while parsing so nothing has to walk the scene
    /// graph to find them again.
    ///
    /// Holding them here, rather than only through the materials that use them,
    /// is what lets the variant be asked for long after the parse: an hour
    /// later, when the user ticks a setting, the list is still exactly the
    /// programs this scene draws with.
    std::vector<std::shared_ptr<const SceneMetalProgram>> metal_variant_candidates;

    std::string scene_id { "unknown_id" };
    /// Shared layer-as-texture resolution. Both backends read this; an error
    /// here is unsupported on both, not a Metal-only fallback.
    std::unordered_set<int32_t> layer_texture_sources;
    std::string                 layer_texture_error;
    /// Layers the current render graph leaves out, each the top of a subtree:
    /// hidden by a settled visibility (`SceneNode::VisibilitySettled`) of their
    /// own or an ancestor's, and sampled by no other layer. Written by
    /// `sceneToRenderGraph`. Once one of them is visible again the runtime asks
    /// for a new graph, which draws it.
    std::vector<std::weak_ptr<SceneNode>> render_excluded_nodes;

    /// Whether a frame of this scene has reached the surface.
    ///
    /// Written by the scene's frame handler and by nothing else. A backend
    /// that sets it directly would satisfy the handler's own check before the
    /// handler ran, and the one thing the handler does on that edge -- telling
    /// the host a first frame exists -- would never happen, leaving the host
    /// waiting out its startup deadline on a wallpaper that is drawing fine.
    bool                 first_frame_ok { false };
    bool                 accepts_pointer_input { true };
    /// Set only by the engine's own plain-video scene: one video texture, a
    /// copy shader, a no-op shader value updater, and no script, particle,
    /// audio or pointer input. Its only time-varying input is therefore that
    /// video, which is what lets the frame clock follow the video's own rate
    /// instead of the display's. Authored scenes never set it.
    bool                 single_video_source { false };
    /// Window-normalized pointer: 0..1 across the presented window, y down.
    std::array<float, 2> pointerPosition { 0.5f, 0.5f };
    /// The same pointer in scene coordinates, written by
    /// `SceneRuntimeContext::SetCursorInput` from the presentation's cursor
    /// viewport. Unset until a host publishes cursor input.
    ///
    /// `pointerPosition * ortho` is not a substitute. A wallpaper is cropped
    /// or letterboxed onto a display whose aspect is not the canvas's, so the
    /// window shows only part of the canvas; that product agrees with the
    /// cursor at the centre of the window and drifts further from it toward
    /// every edge.
    std::optional<std::array<float, 2>> pointerScenePosition;

    SceneMesh default_effect_mesh;

    std::unique_ptr<ParticleSystem> paritileSys;

    SceneCamera* activeCamera { nullptr };

    i32                  ortho[2] { 1920, 1080 }; // w, h
    /// The author's canvas in scene units: what "100% render scale" means for
    /// this scene, and the size presentation layout and cursor mapping are
    /// computed against. Latched once when the scene is built and never
    /// touched by the render scale, so shrinking the internal raster cannot
    /// move the letterbox or the hit test. Zero means "not latched"; the
    /// resolver then falls back to the default render target, then `ortho`.
    i32                  scene_extent[2] { 0, 0 };
    /// Perspective scenes have no authored pixel canvas. Their raster and
    /// presentation follow the output surface instead of the 2D fallback size.
    bool                 display_sized { false };
    bool                 opaque_first { false };
    bool                 hdr { false };
    /// Internal rasterization scale in (0, 1]. Multiplies the size of the
    /// render targets the scene draws into; it never touches the swapchain,
    /// the camera frustum or the presentation viewport, so output size and
    /// composition are unchanged and only the sampled detail differs.
    double               render_scale { 1.0 };
    /// How large the raster behind the canvas is before `render_scale` takes
    /// its share: the canvas itself, or the size the canvas is presented at.
    /// Like the scale it only changes the render targets; the canvas stays the
    /// source extent of layout, cursor mapping and every coordinate a script
    /// sees. A scene built without a host keeps the canvas.
    SceneResolution      resolution { SceneResolution::Canvas };
    std::array<float, 3> clearColor { 1.0f, 1.0f, 1.0f };
    bool                 clearEnabled { true };

    double elapsingTime { 0.0f }, frameTime { 0.0f };
    void   PassFrameTime(double t) {
        frameTime = t;
        elapsingTime += t;
    }

    void UpdateLinkedCamera(const std::string& name) {
        if (linkedCameras.count(name) != 0) {
            auto& cams = linkedCameras.at(name);
            for (auto& cam : cams) {
                if (cameras.count(cam) != 0) {
                    cameras.at(cam)->Clone(*cameras.at(name));
                    cameras.at(cam)->Update();
                }
            }
        }
    }

    /// Points a 2D scene's view: `zoom` narrows it about its centre and
    /// `offset` moves that centre away from the canvas centre, in scene units.
    /// The orthographic camera and the perspective one perspective layers draw
    /// through follow it together, so every layer is framed alike. A zoom of 1
    /// with no offset shows the whole canvas.
    void FrameCanvas(double zoom, const Eigen::Vector2f& offset);

    std::string ResolveRenderTargetName(std::string_view name) const {
        auto alias = renderTargetAliases.find(std::string(name));
        if (alias != renderTargetAliases.end()) return alias->second;
        return std::string(name);
    }

    bool HasRenderTarget(std::string_view name) const { return FindRenderTarget(name) != nullptr; }

    SceneRenderTarget* FindRenderTarget(std::string_view name) {
        const std::string resolved = ResolveRenderTargetName(name);
        auto              it       = renderTargets.find(resolved);
        if (it == renderTargets.end()) return nullptr;
        return &it->second;
    }

    const SceneRenderTarget* FindRenderTarget(std::string_view name) const {
        const std::string resolved = ResolveRenderTargetName(name);
        auto              it       = renderTargets.find(resolved);
        if (it == renderTargets.end()) return nullptr;
        return &it->second;
    }
};
} // namespace wallpaper
