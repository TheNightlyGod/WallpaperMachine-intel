#pragma once
#include "Vulkan/Instance.hpp"
#include "Vulkan/Device.hpp"
#include "Vulkan/Parameters.hpp"
#include "Resource.hpp"
#include "Vulkan/SampleCount.hpp"
#include "Type.hpp"
#include "Vulkan/TextureCache.hpp"
#include "SpecTexs.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneRenderTarget.h"
#include "Presentation/WallpaperScaling.hpp"
#include "Utils/Algorism.h"
#include "VulkanRender/StaticSubgraphCache.hpp"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

namespace wallpaper
{
namespace vulkan
{
inline void RecordShaderReadBarrier(
    vvk::CommandBuffer& command, const ImageParameters& image,
    VkPipelineStageFlags destination_stages =
        VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT) {
    VkImageMemoryBarrier barrier {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT |
                         VK_ACCESS_SHADER_READ_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = image.layout,
        .newLayout = image.layout,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image.handle,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS,
                             0, VK_REMAINING_ARRAY_LAYERS },
    };
    command.PipelineBarrier(
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT |
            VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        destination_stages, 0, barrier);
}

struct CachedColorFramebuffer {
    VkImageView      view {};
    VkRenderPass     render_pass {};
    uint32_t         width { 0 };
    uint32_t         height { 0 };
    vvk::Framebuffer framebuffer;
};

inline VkResult GetOrCreateColorFramebuffer(
    const Device& device, VkRenderPass pass, const ImageParameters& image,
    std::vector<CachedColorFramebuffer>& cache, VkFramebuffer& out) {
    out = VK_NULL_HANDLE;
    if (pass == VK_NULL_HANDLE || image.view == VK_NULL_HANDLE || image.handle == VK_NULL_HANDLE ||
        image.extent.width == 0 || image.extent.height == 0 || image.extent.depth != 1)
        return VK_ERROR_INITIALIZATION_FAILED;
    for (const auto& cached : cache) {
        if (cached.view == image.view && cached.render_pass == pass &&
            cached.width == image.extent.width && cached.height == image.extent.height) {
            out = *cached.framebuffer;
            return VK_SUCCESS;
        }
    }
    CachedColorFramebuffer cached {
        .view = image.view,
        .render_pass = pass,
        .width = image.extent.width,
        .height = image.extent.height,
    };
    VkFramebufferCreateInfo info {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = pass,
        .attachmentCount = 1,
        .pAttachments = &image.view,
        .width = image.extent.width,
        .height = image.extent.height,
        .layers = 1,
    };
    const auto result = device.handle().CreateFramebuffer(info, cached.framebuffer);
    if (result != VK_SUCCESS) return result;
    try {
        cache.push_back(std::move(cached));
    } catch (const std::bad_alloc&) {
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    out = *cache.back().framebuffer;
    return VK_SUCCESS;
}

inline VkViewport ResolvePresentationViewport(const RenderingResources& rr, VkExtent2D extent) {
    if (rr.wallpaper_viewport.width > 0.0f && rr.wallpaper_viewport.height != 0.0f)
        return rr.wallpaper_viewport;
    return VkViewport {
        .x = 0.0f,
        .y = static_cast<float>(extent.height),
        .width = static_cast<float>(extent.width),
        .height = -static_cast<float>(extent.height),
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
}

inline VkRect2D ResolvePresentationScissor(const RenderingResources& rr, VkExtent2D extent) {
    if (rr.wallpaper_scissor.extent.width > 0 && rr.wallpaper_scissor.extent.height > 0)
        return rr.wallpaper_scissor;
    return VkRect2D { { 0, 0 }, extent };
}

inline void SetBlend(BlendMode bm, VkPipelineColorBlendAttachmentState& state,
                     VkSampleCountFlagBits sample_count = VK_SAMPLE_COUNT_1_BIT) {
    if (bm == BlendMode::AlphaToCoverage && sample_count == VK_SAMPLE_COUNT_1_BIT) {
        bm = BlendMode::Translucent;
    }
    state.blendEnable  = true;
    state.colorBlendOp = VK_BLEND_OP_ADD;
    state.alphaBlendOp = VK_BLEND_OP_ADD;
    switch (bm) {
    case BlendMode::Disable: state.blendEnable = false; break;
    case BlendMode::Normal:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO;
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
        break;
    // Coverage, not blending, decides what an alpha-to-coverage pass keeps:
    // surviving samples are written at full strength. Blending as well
    // multiplied thin, minified texels by their alpha a second time.
    case BlendMode::AlphaToCoverage: state.blendEnable = false; break;
    case BlendMode::Translucent:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        // Source-over coverage is As + Ad * (1 - As), not As squared.
        // Squaring it exposes the background along otherwise opaque overlaps.
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        break;
    case BlendMode::Additive:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ONE;
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        break;
    }
}
inline VkAttachmentLoadOp ResolveAttachmentLoadOp(bool preserve_target_contents,
                                                  bool clear_on_first_use) {
    if (clear_on_first_use) return VK_ATTACHMENT_LOAD_OP_CLEAR;
    if (preserve_target_contents) return VK_ATTACHMENT_LOAD_OP_LOAD;
    return VK_ATTACHMENT_LOAD_OP_DONT_CARE;
}

inline VkClearValue ResolveAttachmentClearValue(bool scene_output,
                                                const std::array<float, 3>& clear_color) {
    if (scene_output) {
        return VkClearValue { .color = { clear_color[0], clear_color[1], clear_color[2], 1.0f } };
    }
    return VkClearValue { .color = { 0.0f, 0.0f, 0.0f, 0.0f } };
}

inline VkSampleCountFlagBits
ResolveCustomPassRenderTargetSampleCount(std::uint32_t requested_sample_count,
                                         VkSampleCountFlags supported_color_samples) {
    return ResolveSampleCount(requested_sample_count, supported_color_samples);
}

inline constexpr i32 kMinRenderTargetDimension = 4;

inline i32 ResolveScreenBoundRenderTargetDimension(double source_dimension, double scale) {
    if (! std::isfinite(source_dimension) || source_dimension <= 0.0) {
        source_dimension = static_cast<double>(kMinRenderTargetDimension);
    }
    if (! std::isfinite(scale) || scale <= 0.0) {
        scale = 1.0;
    }
    return std::max(
        kMinRenderTargetDimension,
        static_cast<i32>(std::lround(scale * source_dimension)));
}

inline void ResolveScreenBoundRenderTargetSize(SceneRenderTarget&      target,
                                               const VkExtent2D&       source_extent) {
    target.width = ResolveScreenBoundRenderTargetDimension(
        static_cast<double>(source_extent.width), target.bind.scale);
    target.height = ResolveScreenBoundRenderTargetDimension(
        static_cast<double>(source_extent.height), target.bind.scale);
}

/// The smallest internal render scale that still leaves a usable image. Below
/// this the raster is coarse enough that the upscale at present dominates
/// whatever is saved, and the min-dimension clamp starts distorting small
/// targets rather than scaling them.
inline constexpr double kMinRenderScale = 0.25;

/// Scene-wide internal render scale, clamped to (0, 1].
///
/// Returns 1.0 for the engine's own plain-video scene: there the only content
/// is a decoded frame that already has its own resolution, so scaling the
/// target it is copied into would downsample and then upsample the same pixels
/// for no useful reduction in work. Those wallpapers report the control as not
/// applicable rather than pretending to honour it.
inline double ResolveSceneRenderScale(const wallpaper::Scene& scene) {
    if (scene.single_video_source) return 1.0;
    const double scale = scene.render_scale;
    if (! std::isfinite(scale) || scale >= 1.0) return 1.0;
    return std::max(kMinRenderScale, scale);
}

/// Latches the authored size of a target the first time it is resolved, then
/// derives the physical size from that latched value. Deriving from the
/// authored size rather than the current one is what keeps 100% -> 50% -> 100%
/// exact instead of drifting by a rounding step each way.
inline void ResolveRenderScaledSize(SceneRenderTarget& target, double render_scale) {
    if (target.authored_width <= 0 || target.authored_height <= 0) {
        target.authored_width  = target.width;
        target.authored_height = target.height;
    }
    if (target.media_sized) {
        target.width  = target.authored_width;
        target.height = target.authored_height;
        return;
    }
    target.width =
        ResolveScreenBoundRenderTargetDimension(target.authored_width, render_scale);
    target.height =
        ResolveScreenBoundRenderTargetDimension(target.authored_height, render_scale);
}

/// The author's canvas, in scene units. Never scaled: presentation layout and
/// cursor mapping are computed against this, so the internal raster size
/// cannot move the letterbox or offset the hit test.
inline VkExtent2D ResolveSceneSourceExtent(const wallpaper::Scene& scene,
                                           const VkExtent2D&       fallback_extent) {
    if (scene.display_sized) {
        return { std::max(1u, fallback_extent.width), std::max(1u, fallback_extent.height) };
    }
    if (scene.scene_extent[0] > 0 && scene.scene_extent[1] > 0) {
        return {
            static_cast<uint32_t>(scene.scene_extent[0]),
            static_cast<uint32_t>(scene.scene_extent[1]),
        };
    }

    auto spec_rt = scene.renderTargets.find(std::string(wallpaper::SpecTex_Default));
    if (spec_rt != scene.renderTargets.end()) {
        const auto& rt      = spec_rt->second;
        const auto  width   = rt.authored_width > 0 ? rt.authored_width : rt.width;
        const auto  height  = rt.authored_height > 0 ? rt.authored_height : rt.height;
        if (width > 0 && height > 0) {
            return {
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height),
            };
        }
    }

    const auto ortho_width  = static_cast<uint32_t>(std::max(0, scene.ortho[0]));
    const auto ortho_height = static_cast<uint32_t>(std::max(0, scene.ortho[1]));
    if (ortho_width > 2 && ortho_height > 2) return { ortho_width, ortho_height };

    return {
        std::max(1u, fallback_extent.width),
        std::max(1u, fallback_extent.height),
    };
}

/// The authored canvas and the internal raster it is drawn at. Equal at render
/// scale 1.0 with the canvas resolution; the display resolution makes the raster
/// the size the canvas is presented at instead.
struct SceneRasterExtents {
    VkExtent2D source {};
    VkExtent2D raster {};
};

/// What the output a scene is presented on means for its raster.
struct SceneRasterSurface {
    /// Output pixels per layout point, the display's backing scale.
    double   display_scale_factor { 1.0 };
    /// The longest side a render target may have on this device. Zero when the
    /// device's limit is not known, which caps nothing.
    uint32_t max_dimension { 0 };
};

/// Whether `Scene::resolution` decides anything for this scene.
///
/// A perspective scene already rasterizes at the output size, and a plain video
/// keeps the size of the frame it copies, so for neither is there a canvas whose
/// raster could be sized one way or the other.
inline bool SceneResolutionAffectsRaster(const wallpaper::Scene& scene) {
    return ! scene.display_sized && ! scene.single_video_source;
}

/// The output pixels the authored canvas covers once it is presented: the FILL
/// layout the renderers lay it out with, scaled by the display's backing factor.
/// A canvas whose aspect differs from the output's is filled, so this extent
/// keeps the canvas aspect and exceeds the output along one axis; the
/// presentation crops the excess, and that crop is not this function's concern.
///
/// The user's zoom is left out on purpose: it changes with a slider and must
/// not rebuild the graph every time it moves, so the raster is sized for the
/// placement every display starts from.
inline VkExtent2D ResolveSceneDisplayExtent(const VkExtent2D& source, const VkExtent2D& output,
                                            double display_scale_factor) {
    const double factor =
        std::isfinite(display_scale_factor) && display_scale_factor > 0.0 ? display_scale_factor
                                                                          : 1.0;
    // Rounded to the same whole points the renderers lay the canvas out in, so
    // the raster matches the viewport they present it into.
    const auto logical = [factor](uint32_t pixels) {
        return static_cast<uint32_t>(
            std::max(1L, std::lround(static_cast<double>(pixels) / factor)));
    };
    const auto layout = wallpaper::ComputeWallpaperScalingLayout(
        wallpaper::WallpaperScalingMode::FILL, source.width, source.height,
        logical(output.width), logical(output.height), factor, 1.0);
    return {
        static_cast<uint32_t>(std::max(1, layout.viewport_px.width)),
        static_cast<uint32_t>(std::max(1, layout.viewport_px.height)),
    };
}

/// Shrinks `extent` so its longest side fits `max_dimension`, keeping the
/// aspect. Zero means the limit is unknown, and nothing is shrunk.
inline VkExtent2D CapRasterExtent(const VkExtent2D& extent, uint32_t max_dimension) {
    const uint32_t longest = std::max(extent.width, extent.height);
    if (max_dimension == 0 || longest <= max_dimension) return extent;
    const double shrink = static_cast<double>(max_dimension) / static_cast<double>(longest);
    return {
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.width, shrink)),
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.height, shrink)),
    };
}

/// Re-bakes `g_TextureNResolution` for every material slot that samples a
/// screen-bound render target.
///
/// Those constants are folded in while the scene is parsed, when a target that
/// follows the screen still has placeholder dimensions because the output size
/// is not known yet. Nothing refreshes them afterwards, so a shader that
/// divides by the resolution -- a separable blur steps by
/// `1 / g_Texture0Resolution.zw` -- was dividing by two. Every one of its taps
/// landed outside the texture and clamped to the edge, which turns a gentle
/// blur into a flat wash and is why an effect chain's background lost its
/// shape entirely.
inline void RefreshScreenBoundTextureResolutions(Scene& scene) {
    const auto refresh = [&scene](SceneNode* node) {
        if (node == nullptr || node->Mesh() == nullptr) return;
        auto* mesh = node->Mesh();
        for (uint32_t slot = 0; slot < mesh->MaterialSlots().size(); ++slot) {
            auto* material = mesh->MaterialForSlot(slot);
            if (material == nullptr) continue;
            for (std::size_t index = 0; index < material->textures.size(); ++index) {
                if (index >= wallpaper::WE_GLTEX_RESOLUTION_NAMES.size()) break;
                const auto& texture = material->textures[index];
                if (texture.empty()) continue;
                // The material keeps the authored name; the scene keys targets
                // by the resolved one.
                const auto* target =
                    scene.FindRenderTarget(scene.ResolveRenderTargetName(texture));
                if (target == nullptr) continue;
                if (! (target->bind.enable && target->bind.screen)) continue;
                const std::array<i32, 4> resolution { target->width, target->height,
                                                      target->width, target->height };
                material->customShader.constValues[std::string(
                    wallpaper::WE_GLTEX_RESOLUTION_NAMES[index])] = array_cast<float>(resolution);
            }
        }
    };
    const auto walk = [&refresh](auto&& self, SceneNode* node) -> void {
        if (node == nullptr) return;
        refresh(node);
        for (const auto& child : node->GetChildren()) self(self, child.get());
    };
    walk(walk, scene.sceneGraph.get());
    // An effect chain's nodes are not children of the layer they belong to, so
    // a plain graph walk misses exactly the passes this matters most for.
    for (auto& [name, camera] : scene.cameras) {
        (void)name;
        if (camera == nullptr || ! camera->HasImgEffect()) continue;
        auto& layer = *camera->GetImgEffect();
        for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
            const auto& effect = layer.GetEffect(i);
            if (effect == nullptr) continue;
            for (const auto& effect_node : effect->nodes) refresh(effect_node.sceneNode.get());
        }
    }
    for (const auto& post : scene.post_processes) {
        if (post == nullptr) continue;
        for (const auto& step : post->steps) {
            const auto* pass = std::get_if<ScenePostProcessPass>(&step);
            if (pass == nullptr || pass->node == nullptr) continue;
            refresh(pass->node.get());
            auto* mesh = pass->node->Mesh();
            if (mesh == nullptr || pass->source_texel_radius <= 0.0f) continue;
            for (const auto& material : mesh->MaterialSlots()) {
                if (material == nullptr || material->textures.empty()) continue;
                const auto* source = scene.FindRenderTarget(material->textures.front());
                if (source == nullptr || source->width <= 0 || source->height <= 0) continue;
                const float x = pass->source_texel_radius / source->width;
                const float y = pass->source_texel_radius / source->height;
                material->customShader.constValues["g_RenderVar0"] =
                    std::array<float, 4>{x, y, -x, -y};
            }
        }
    }
}

inline SceneRasterExtents ResolveScreenBoundRenderTargetSizes(Scene&                    scene,
                                                              const VkExtent2D&         fallback_extent,
                                                              const SceneRasterSurface& surface = {}) {
    const auto source_extent = ResolveSceneSourceExtent(scene, fallback_extent);
    if (scene.display_sized) {
        const double aspect = double(source_extent.width) / source_extent.height;
        for (auto& [name, camera] : scene.cameras) {
            (void)name;
            if (camera != nullptr && camera->IsPerspective()) {
                camera->SetAspect(aspect);
                camera->Update();
            }
        }
    }
    const auto render_scale = ResolveSceneRenderScale(scene);
    // The raster starts from the canvas, or from the size the canvas is
    // presented at when the scene is asked to rasterize for the display. Only
    // then is it bounded by the device: the canvas has always been allowed to
    // be whatever the author made it.
    const bool display_raster = scene.resolution == wallpaper::SceneResolution::Display &&
                                SceneResolutionAffectsRaster(scene);
    const auto raster_basis =
        display_raster ? ResolveSceneDisplayExtent(source_extent, fallback_extent,
                                                   surface.display_scale_factor)
                       : source_extent;
    const uint32_t max_dimension = display_raster ? surface.max_dimension : 0u;
    const VkExtent2D raster_extent = CapRasterExtent(
        {
            static_cast<uint32_t>(
                ResolveScreenBoundRenderTargetDimension(raster_basis.width, render_scale)),
            static_cast<uint32_t>(
                ResolveScreenBoundRenderTargetDimension(raster_basis.height, render_scale)),
        },
        max_dimension);

    for (auto& item : scene.renderTargets) {
        auto& target = item.second;
        if (item.first == wallpaper::SpecTex_Default) {
            // The scene's own colour buffer and the source the final blit
            // samples. It is bound to the screen with scale 1.0, so the raster
            // extent is exactly its size.
            if (target.authored_width <= 0 || target.authored_height <= 0) {
                target.authored_width  = static_cast<i32>(source_extent.width);
                target.authored_height = static_cast<i32>(source_extent.height);
            }
            if (target.media_sized) {
                target.width  = target.authored_width;
                target.height = target.authored_height;
            } else {
                target.width  = static_cast<i32>(raster_extent.width);
                target.height = static_cast<i32>(raster_extent.height);
            }
            continue;
        }
        if (target.bind.enable && target.bind.screen) {
            if (target.authored_width <= 0 || target.authored_height <= 0) {
                target.authored_width = ResolveScreenBoundRenderTargetDimension(
                    source_extent.width, target.bind.scale);
                target.authored_height = ResolveScreenBoundRenderTargetDimension(
                    source_extent.height, target.bind.scale);
            }
            ResolveScreenBoundRenderTargetSize(target, raster_extent);
            if (max_dimension > 0) {
                const auto limit = static_cast<i32>(max_dimension);
                target.width     = std::min(target.width, limit);
                target.height    = std::min(target.height, limit);
            }
        }
    }
    RefreshScreenBoundTextureResolutions(scene);
    return { source_extent, raster_extent };
}

/// Fits the scene's authored canvas into an output of `width` x `height`.
///
/// Purely scene-side camera arithmetic with nothing Vulkan in it, so both
/// render backends call this one definition. Two copies of it would drift, and
/// the drift would show as the two backends framing the same wallpaper
/// differently.
inline void ApplyCameraFillMode(wallpaper::Scene& scene, wallpaper::FillMode fillmode,
                                uint32_t width, uint32_t height) {
    using namespace wallpaper;
    if (width == 0 || height == 0) return;
    const auto global = scene.cameras.find("global");
    const auto global_perspective = scene.cameras.find("global_perspective");
    if (global == scene.cameras.end() || global_perspective == scene.cameras.end()) return;
    if (global->second == nullptr || global_perspective->second == nullptr) return;

    double sw = scene.ortho[0], sh = scene.ortho[1];
    double fboAspect = width / (double)height, sAspect = sw / sh;
    auto&  gCam    = *global->second;
    auto&  gPerCam = *global_perspective->second;
    switch (fillmode) {
    case FillMode::STRETCH:
        gCam.SetWidth(sw);
        gCam.SetHeight(sh);
        gPerCam.SetAspect(sAspect);
        break;
    case FillMode::ASPECTFIT:
        if (fboAspect < sAspect) {
            // scale height
            gCam.SetWidth(sw);
            gCam.SetHeight(sw / fboAspect);
        } else {
            gCam.SetWidth(sh * fboAspect);
            gCam.SetHeight(sh);
        }
        gPerCam.SetAspect(fboAspect);
        break;
    case FillMode::ASPECTCROP:
    default:
        if (fboAspect > sAspect) {
            // scale height
            gCam.SetWidth(sw);
            gCam.SetHeight(sw / fboAspect);
        } else {
            gCam.SetWidth(sh * fboAspect);
            gCam.SetHeight(sh);
        }
        gPerCam.SetAspect(fboAspect);
        break;
    }
    // The extent the orthographic camera actually shows, so a camera layer's
    // zoom narrows perspective layers exactly as it does the rest.
    FitCanvasPerspective(gPerCam, gCam);
    gCam.Update();
    gPerCam.Update();
    scene.UpdateLinkedCamera("global");
}

/// Folds into a static-reuse sample the cameras a pass depends on: the one it
/// draws through -- `camera_override` when the graph set one, else its node's --
/// and the scene's active camera, which a compose layer samples the screen with.
/// Neither is covered by the node transform, and both move without a graph
/// rebuild: a fill-mode change, a camera layer's zoom or pan, a script. The
/// view-projection matrix carries the camera's position and visible extent
/// alike. Both backends call this one definition, so their caches invalidate on
/// the same camera changes.
inline uint64_t FoldPassCameras(uint64_t hash, const wallpaper::Scene& scene,
                                const std::string& camera_override,
                                const wallpaper::SceneNode* node) {
    const auto fold = [&hash](const wallpaper::SceneCamera* camera) {
        if (camera == nullptr) return;
        const Eigen::Matrix4d matrix = camera->GetViewProjectionMatrix();
        hash = StaticHashBytes(hash, matrix.data(), sizeof(double) * 16);
    };
    const std::string& camera_name =
        ! camera_override.empty() ? camera_override
                                  : (node != nullptr ? node->Camera() : std::string {});
    if (! camera_name.empty()) {
        const auto found = scene.cameras.find(camera_name);
        fold(found != scene.cameras.end() ? found->second.get() : nullptr);
    }
    fold(scene.activeCamera);
    return hash;
}

inline void SetAttachmentLoadOp(BlendMode bm, VkAttachmentLoadOp& load_op) {
    switch (bm) {
    case BlendMode::Disable:
    case BlendMode::Normal:
    case BlendMode::AlphaToCoverage: load_op = VK_ATTACHMENT_LOAD_OP_DONT_CARE; break;
    case BlendMode::Additive:
    case BlendMode::Translucent: load_op = VK_ATTACHMENT_LOAD_OP_LOAD; break;
    }
}

inline TextureKey ToTexKey(wallpaper::SceneRenderTarget rt) {
    return TextureKey {
        .width        = rt.width,
        .height       = rt.height,
        .usage        = {},
        .format       = rt.format,
        .sample       = rt.sample,
        .mipmap_level = rt.mipmap_level,
        .sample_count = SampleCountFromValue(rt.sample_count),
    };
}

/// Gives each target that carries pixels into the next frame its own image.
/// Runs before the passes are prepared: preparing them hands on the images of
/// targets they are done with, and a carried target given one of those would
/// be drawn over by the target that had it every frame.
inline bool ReserveCarriedOverTargets(const wallpaper::Scene& scene, TextureCache& cache) {
    for (const auto& [name, rt] : scene.renderTargets) {
        if (! rt.carriesPreviousFrame) continue;
        if (! cache.Reserve(name, ToTexKey(rt)).has_value()) return false;
    }
    return true;
}

inline TextureKey ToTexKeyMsaa(wallpaper::SceneRenderTarget rt,
                               VkSampleCountFlagBits        sample_count) {
    auto key          = ToTexKey(rt);
    key.usage         = TexUsage::MSAA_COLOR;
    key.mipmap_level  = 1;
    key.sample_count  = sample_count;
    return key;
}

inline TextureKey ToTexKeyDepth(wallpaper::SceneRenderTarget rt,
                                VkSampleCountFlagBits        sample_count) {
    auto key          = ToTexKey(rt);
    key.usage         = TexUsage::DEPTH;
    key.mipmap_level  = 1;
    key.sample_count  = sample_count;
    return key;
}
} // namespace vulkan
} // namespace wallpaper
