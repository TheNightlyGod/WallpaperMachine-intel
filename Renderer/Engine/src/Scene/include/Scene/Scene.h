#pragma once
#include "SceneReflection.hpp"
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
#include "SceneShadows.hpp"
#include "SceneResolution.hpp"
#include "SceneQuality.hpp"
#include "WeUserOptions.hpp"

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

/// A file the scene names that none of its file systems holds, found while it was parsed: the path
/// below the scene's own space (`materials/rain.json`), and the layer being built when it was asked
/// for (an empty name and id -1 when none was).
struct SceneMissingFile {
    std::string layer;
    int32_t     object_id { -1 };
    std::string path;
};

struct ScenePostProcessPass {
    std::shared_ptr<SceneNode> node;
    std::string                output;
    /// When positive, the pass's `g_RenderVar0` is kept at this many texels of
    /// its first texture, (+x, +y, -x, -y). A screen-bound source uses its
    /// fractional raster extent before allocation rounding/minimum-size clamps.
    float                      source_texel_radius { 0.0f };
};

struct SceneVolumetricLight {
    const SceneLight* light {nullptr};
    std::shared_ptr<SceneNode> back, front, fullscreen;
    bool shadow {false};
    // Cached once per active light, shared by its back/front variants.
    linalg::Matrix4d volume {linalg::Matrix4d::Identity()};
    linalg::Matrix4d projection {linalg::Matrix4d::Identity()};
    linalg::Matrix4d camera_inverse {linalg::Matrix4d::Identity()};
    std::array<std::array<float,4>,5> parameters {};
    linalg::Matrix4d previous_world {linalg::Matrix4d::Zero()};
    linalg::Matrix4d previous_camera {linalg::Matrix4d::Zero()};
    std::array<float,3> previous_shape {};
    uint64_t generation {1};
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
class Scene;
void UpdateSceneVolumetrics(Scene& scene);

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
    std::vector<SceneVolumetricLight> volumetric_lights;
    std::shared_ptr<ScenePostProcess> volumetric_combine;
    bool volumetric_dirty {false};
    std::size_t volumetric_cast_count {0};
    std::function<bool()> prepare_volumetrics;
    /// The light counts lit shaders are compiled for (`general.lightconfig`).
    SceneLightConfig                         light_config;
    /// The shadow views and atlas layout (Appendix C item 6); empty when no shadow is drawn.
    SceneShadowState                         shadows;
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
    /// The project file (`project.json`) this scene was loaded from, or empty for
    /// a scene built some other way. What the surface reads to find the project's
    /// preview picture when the scene cannot be drawn.
    std::string project_path;
    /// Shared layer-as-texture resolution. An error
    /// here leaves the scene undrawn.
    std::unordered_set<int32_t> layer_texture_sources;
    std::string                 layer_texture_error;
    /// One sentence per shader of the scene that could not be compiled for Metal, naming the
    /// shader and the compiler's reason. Diagnostic only: the pass that wanted it is drawn with
    /// Wallpaper Engine's fallback shader in place of the stage that failed, as there.
    std::vector<std::string>    shader_fallbacks;
    /// Files the scene names and does not have, at most 64, each once, in the order the parse
    /// asked for them. A layer that names one draws without it or not at all; the scene is still
    /// drawn, as Wallpaper Engine draws what it can.
    std::vector<SceneMissingFile> missing_files;
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
    bool                 transparent_sorting { false };
    // Stable ties retain the preceding sorted list, not a fresh file-order list.
    // Weak handles do not prolong removed layers. No allocation while sorting is off.
    std::vector<std::weak_ptr<SceneNode>> transparent_order;
    // A runtime exposes the raw authored origin. A parse without one records that
    // origin before image alignment changes the node's geometry-centre transform.
    std::unordered_map<const SceneNode*, linalg::Vector3f> sorting_origins;
    bool                 hdr { false };
    /// HDR output for a display that can show it (post-processing "displayhdr").
    bool                 display_hdr { false };
    /// The completed global post-process output is linear light. Ordinary scene
    /// materials and their intermediate targets keep their authored encoding.
    bool                 output_linear { false };
    float                display_hdr_headroom { 1.0f };
    std::weak_ptr<SceneMaterial> display_hdr_combine_material;
    /// The quality the scene was parsed with (`SceneParseRequest::quality`).
    SceneQuality         quality {};
    /// Samples actually negotiated by the renderer; zero means single-sample rendering.
    uint32_t             effective_msaa { 0 };
    /// Whether `_rt_MipMappedFrameBuffer` is refreshed (the `reflection`
    /// quality setting; WE flag 0x80, cleared and not updated when off).
    bool                 reflection_enabled { true };
    SceneReflection      reflection;
    /// The user's colour / LUT pass (`ccsimple`, Wallpaper Engine's per-wallpaper
    /// colour options and image filter), drawn after bloom; null when the options
    /// leave the picture unchanged. Its `g_Params` / `g_LutParams` are written in
    /// place when only a value changes (`ccsimple_shape` stays).
    std::shared_ptr<SceneMaterial> color_correction_material;
    CcsimpleShape                  ccsimple_shape {};
    /// The colour of the bars a fitted picture leaves on the display: the
    /// project's `schemecolor` property (WE sub_140181F30 / sub_14017FA70), black
    /// when the project has none. Never shown under the blurred backdrop.
    std::array<float, 3> border_color { 0.0f, 0.0f, 0.0f };
    /// Render targets a script's `executeMaterialFunction` asked to clear since the last frame
    /// (`SceneRuntimeContext::RunEffectFunction`); the renderer clears them at the start of its
    /// next frame, before any pass, and takes them off the list.
    struct EffectClear {
        std::string          target;
        std::array<float, 4> color { 0.0f, 0.0f, 0.0f, 0.0f };
    };
    std::vector<EffectClear> pending_effect_clears;
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
    /// HDR Display output is framed before global postprocessing. Authored
    /// cameras and local layer buffers keep their own coordinate systems.
    bool                 display_framed {false};
    std::array<double, 4> display_clip {1.0, 1.0, 0.0, 0.0};
    uint64_t             display_clip_generation {0};
    std::array<float, 3> clearColor { 1.0f, 1.0f, 1.0f };
    bool                 clearEnabled { true };

    double elapsingTime { 0.0f }, frameTime { 0.0f };
    void   PassFrameTime(double t) {
        frameTime = t;
        elapsingTime += t;
    }
    /// The frame rate the host paces this scene at (its FPS cap), refreshed
    /// every frame before the particles step. 0 = unknown: particles then take
    /// full-length force steps and no half steps (Wallpaper Engine's
    /// engine+0x148, artifacts/we-parity/decompiles/F-D5.md).
    uint32_t targetFps { 0 };

    void UpdateLinkedCamera(const std::string& name) {
        const auto list = linkedCameras.find(name);
        if (list == linkedCameras.end()) return;
        const auto source = cameras.find(name);
        if (source == cameras.end() || source->second == nullptr) return;
        for (const auto& linked_name : list->second) {
            const auto linked = cameras.find(linked_name);
            if (linked == cameras.end() || linked->second == nullptr) continue;
            if (linked->second == source->second) continue;
            linked->second->Clone(*source->second);
            linked->second->Update();
        }
    }

    /// Points a 2D scene's view: `zoom` narrows it about its centre and
    /// `offset` moves that centre away from the canvas centre, in scene units.
    /// The orthographic camera and the perspective one perspective layers draw
    /// through follow it together, so every layer is framed alike. A zoom of 1
    /// with no offset shows the whole canvas.
    void FrameCanvas(double zoom, const linalg::Vector2f& offset);

    /// One hop through the alias table; a name that is no alias comes back as it is.
    std::string ResolveRenderTargetName(std::string_view name) const {
        std::string key(name);
        const auto  alias = renderTargetAliases.find(key);
        if (alias != renderTargetAliases.end()) return alias->second;
        return key;
    }

    bool HasRenderTarget(std::string_view name) const { return FindRenderTarget(name) != nullptr; }

    SceneRenderTarget* FindRenderTarget(std::string_view name) {
        const std::string key(name);
        const auto        found = renderTargets.find(AliasTarget(key));
        return found != renderTargets.end() ? &found->second : nullptr;
    }

    const SceneRenderTarget* FindRenderTarget(std::string_view name) const {
        const std::string key(name);
        const auto        found = renderTargets.find(AliasTarget(key));
        return found != renderTargets.end() ? &found->second : nullptr;
    }

private:
    /// The alias table's value for `key`, or `key` itself: one hop, no copy.
    const std::string& AliasTarget(const std::string& key) const {
        const auto alias = renderTargetAliases.find(key);
        return alias != renderTargetAliases.end() ? alias->second : key;
    }
};
} // namespace wallpaper
