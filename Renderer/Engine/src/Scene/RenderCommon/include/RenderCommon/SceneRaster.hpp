// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once

#include "Presentation/WallpaperScaling.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneRenderTarget.h"
#include "SpecTexs.hpp"
#include "Type.hpp"
#include "Utils/Algorism.h"

#include "Utils/Linalg.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

// Scene-side raster arithmetic: how large each render target is for a given
// output, render scale and display, and how the authored canvas is framed in
// it. Nothing here touches a GPU API, so every caller shares these one
// definitions; two copies would drift, and the drift would show as the same
// wallpaper sized or framed differently.
namespace wallpaper
{

/// A width and height in pixels. Plain pixels, so code that only sizes
/// things carries no GPU header.
struct Extent2D {
    uint32_t width { 0 };
    uint32_t height { 0 };
};

namespace render
{

inline constexpr i32 kMinRenderTargetDimension = 4;

inline i32 ResolveScreenBoundRenderTargetDimension(double source, double scale,
    SceneRenderTarget::Bind::SizePolicy policy = SceneRenderTarget::Bind::SizePolicy::Effect) {
    const bool native = policy == SceneRenderTarget::Bind::SizePolicy::NativeFramebuffer;
    const i32 minimum = native ? 2 : kMinRenderTargetDimension;
    if (! std::isfinite(source) || source <= 0.0) source = minimum;
    if (! std::isfinite(scale) || scale <= 0.0) scale = 1.0;
    // std::round takes halves away from zero. The product can overflow a double
    // (or an i32) for absurd sources, so it saturates rather than converting.
    const double scaled = native ? std::floor(source * scale) : std::round(source * scale);
    if (! (scaled < static_cast<double>(std::numeric_limits<i32>::max())))
        return std::numeric_limits<i32>::max();
    return std::max(minimum, static_cast<i32>(scaled));
}

inline void ResolveScreenBoundRenderTargetSize(SceneRenderTarget& target, const Extent2D& extent) {
    target.width  = ResolveScreenBoundRenderTargetDimension(static_cast<double>(extent.width),
                                                           target.bind.scale, target.bind.size_policy);
    target.height = ResolveScreenBoundRenderTargetDimension(static_cast<double>(extent.height),
                                                           target.bind.scale, target.bind.size_policy);
}

/// The smallest internal render scale that still leaves a usable image. Below
/// this the raster is coarse enough that the upscale at present dominates
/// whatever is saved, and the min-dimension clamp starts distorting small
/// targets rather than scaling them.
inline constexpr double kMinRenderScale = 0.25;

/// Scene-wide internal render scale, clamped to (0, 1].
///
inline double ResolveSceneRenderScale(const wallpaper::Scene& scene) {
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
    target.width =
        ResolveScreenBoundRenderTargetDimension(target.authored_width, render_scale);
    target.height =
        ResolveScreenBoundRenderTargetDimension(target.authored_height, render_scale);
}

/// The author's canvas, in scene units. Never scaled: presentation layout and
/// cursor mapping are computed against this, so the internal raster size
/// cannot move the letterbox or offset the hit test.
inline Extent2D ResolveSceneSourceExtent(const wallpaper::Scene& scene, const Extent2D& fallback) {
    const Extent2D output { std::max(1u, fallback.width), std::max(1u, fallback.height) };
    if (scene.display_sized) return output;
    if (scene.scene_extent[0] > 0 && scene.scene_extent[1] > 0)
        return { static_cast<uint32_t>(scene.scene_extent[0]),
                 static_cast<uint32_t>(scene.scene_extent[1]) };
    // The default target is found by its own key; an alias must not redirect it.
    const auto found = scene.renderTargets.find(std::string(SpecTex_Default));
    if (found != scene.renderTargets.end()) {
        const SceneRenderTarget& target = found->second;
        const bool               latched = target.authored_width > 0 && target.authored_height > 0;
        const i32                width   = latched ? target.authored_width : target.width;
        const i32                height  = latched ? target.authored_height : target.height;
        if (width > 0 && height > 0)
            return { static_cast<uint32_t>(width), static_cast<uint32_t>(height) };
    }
    const i32 canvas_width  = std::max<i32>(0, scene.ortho[0]);
    const i32 canvas_height = std::max<i32>(0, scene.ortho[1]);
    if (canvas_width > 2 && canvas_height > 2)
        return { static_cast<uint32_t>(canvas_width), static_cast<uint32_t>(canvas_height) };
    return output;
}

/// The authored canvas and the internal raster it is drawn at. Equal at render
/// scale 1.0 with the canvas resolution; the display resolution makes the raster
/// the size the canvas is presented at instead.
struct SceneRasterExtents {
    Extent2D source {};
    Extent2D raster {};
};

/// What the output a scene is presented on means for its raster.
struct SceneRasterSurface {
    /// Output pixels per layout point, the display's backing scale.
    double   display_scale_factor { 1.0 };
    /// The longest side a render target may have on this device. Zero when the
    /// device's limit is not known, which caps nothing.
    uint32_t max_dimension { 0 };
    /// For a framed SDR scene (`Scene::display_framed` without HDR): the part of its
    /// canvas-cover raster it draws, in that raster's own pixels
    /// (`SceneRasterWindow::size`). Empty for every other scene.
    Extent2D window {};
};

/// Whether `Scene::resolution` decides anything for this scene.
///
/// A perspective scene already rasterizes at the output size, so for it there is
/// no canvas whose raster could be sized one way or the other.
inline bool SceneResolutionAffectsRaster(const wallpaper::Scene& scene) {
    return ! scene.display_sized;
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
inline Extent2D ResolveSceneDisplayExtent(const Extent2D& source, const Extent2D& output,
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
inline Extent2D CapRasterExtent(const Extent2D& extent, uint32_t max_dimension) {
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
    const auto* frame = scene.FindRenderTarget(SpecTex_Default);
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
                float x = pass->source_texel_radius / source->width;
                float y = pass->source_texel_radius / source->height;
                if (source->bind.enable && source->bind.screen &&
                    std::isfinite(source->bind.scale) && source->bind.scale > 0.0 &&
                    frame != nullptr && frame->width > 0 && frame->height > 0) {
                    // WE scales the full-raster reciprocal for each bloom level
                    // (0x140183610), before rounding or clamping its allocation.
                    // Bicubic sampling also derives its coordinate grid from
                    // this offset, so using the rounded texture size reshapes it.
                    const float radius = pass->source_texel_radius /
                                         static_cast<float>(source->bind.scale);
                    x = radius / frame->width;
                    y = radius / frame->height;
                }
                material->customShader.constValues["g_RenderVar0"] =
                    std::array<float, 4>{x, y, -x, -y};
            }
        }
    }
}

namespace detail
{

/// What one sizing pass decided for a scene, before any record is touched.
struct ScreenBoundSizingPlan {
    Extent2D source {};
    Extent2D raster {};
    /// Longest side a record may keep; zero when nothing caps it.
    uint32_t cap { 0 };
};

inline Extent2D ScaleExtent(const Extent2D& extent, double scale,
    SceneRenderTarget::Bind::SizePolicy policy = SceneRenderTarget::Bind::SizePolicy::Effect) {
    return {
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.width, scale, policy)),
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.height, scale, policy)),
    };
}

/// The raster extent and the cap that goes with it. Only a Display-resolution
/// scene with a canvas is sized from the display and limited by the device.
inline ScreenBoundSizingPlan PlanScreenBoundSizing(const Scene& scene, const Extent2D& fallback,
                                                   const SceneRasterSurface& surface) {
    ScreenBoundSizingPlan plan;
    plan.source = ResolveSceneSourceExtent(scene, fallback);
    const bool from_display =
        scene.resolution == SceneResolution::Display && SceneResolutionAffectsRaster(scene);
    plan.cap = from_display ? surface.max_dimension : 0u;
    if (from_display && scene.display_framed && surface.window.width > 0 &&
        surface.window.height > 0) {
        // A window of the capped canvas-cover raster, already in its pixels.
        plan.raster = surface.window;
        return plan;
    }
    const Extent2D basis =
        from_display && scene.display_framed ? fallback : from_display
            ? ResolveSceneDisplayExtent(plan.source, fallback, surface.display_scale_factor)
            : plan.source;
    plan.raster = ScaleExtent(basis, ResolveSceneRenderScale(scene));
    if (plan.cap != 0) plan.raster = CapRasterExtent(plan.raster, plan.cap);
    return plan;
}

/// Sets the authored size once; a record that already has both sides keeps it.
inline void LatchAuthoredSize(SceneRenderTarget& record, i32 width, i32 height) {
    if (record.authored_width > 0 && record.authored_height > 0) return;
    record.authored_width  = width;
    record.authored_height = height;
}

/// Applies the sizing rules of one record: the scene output follows the raster,
/// an enabled screen-bound record follows its own scale of it, the rest stay.
inline void SizeRecord(const ScreenBoundSizingPlan& plan, std::string_view key,
                       SceneRenderTarget& record) {
    if (key == SpecTex_Default) {
        LatchAuthoredSize(record, static_cast<i32>(plan.source.width),
                          static_cast<i32>(plan.source.height));
        record.width  = static_cast<i32>(plan.raster.width);
        record.height = static_cast<i32>(plan.raster.height);
        return;
    }
    if (! record.bind.enable || ! record.bind.screen) return;
    const Extent2D latched = ScaleExtent(plan.source, record.bind.scale, record.bind.size_policy);
    LatchAuthoredSize(record, static_cast<i32>(latched.width), static_cast<i32>(latched.height));
    ResolveScreenBoundRenderTargetSize(record, plan.raster);
    if (plan.cap == 0) return;
    const i32 ceiling = static_cast<i32>(plan.cap);
    record.width      = std::min(record.width, ceiling);
    record.height     = std::min(record.height, ceiling);
}

/// A display-sized scene draws at the output's aspect, so its perspective
/// cameras take the source's.
inline void FollowSourceAspect(Scene& scene, const Extent2D& source) {
    if (! scene.display_sized) return;
    const double aspect = static_cast<double>(source.width) / static_cast<double>(source.height);
    for (auto& entry : scene.cameras) {
        SceneCamera* camera = entry.second.get();
        if (camera == nullptr || ! camera->IsPerspective()) continue;
        camera->SetAspect(aspect);
        camera->Update();
    }
}

} // namespace detail

inline SceneRasterExtents ResolveScreenBoundRenderTargetSizes(Scene& scene,
                                                              const Extent2D& fallback,
                                                              const SceneRasterSurface& surface = {}) {
    const detail::ScreenBoundSizingPlan plan = detail::PlanScreenBoundSizing(scene, fallback, surface);
    for (auto& [key, record] : scene.renderTargets) detail::SizeRecord(plan, key, record);
    detail::FollowSourceAspect(scene, plan.source);
    RefreshScreenBoundTextureResolutions(scene);
    return { plan.source, plan.raster };
}

// SDR display framing. The composition samples only part of the canvas-cover raster of a
// Display-resolution scene: Fill crops the canvas that overhangs the display. Wallpaper
// Engine never draws that part (its frame buffer is the window's size). A framed SDR scene
// draws only a window of the cover raster: the texels the composition reads, rounded out to
// the cover raster's own pixel grid and to the grid of every screen-sized target sampled at
// a fraction of it. Drawn at the same pitch and phase, every pixel the composition reads is
// the one the whole raster would hold, except where a screen-space effect reaches across the
// window's edge, which now clamps there as Wallpaper Engine's does at the window's edge.

/// The canvas-cover raster a Display-resolution scene is drawn at when nothing frames it:
/// the Fill layout of its canvas at the display's scale, through the render scale and the
/// device cap. `capped` says whether the cap shrank it.
inline Extent2D ResolveSceneCoverRaster(const Scene& scene, const Extent2D& fallback,
                                        const SceneRasterSurface& surface,
                                        bool* capped = nullptr) {
    const Extent2D source = ResolveSceneSourceExtent(scene, fallback);
    const Extent2D scaled = detail::ScaleExtent(
        ResolveSceneDisplayExtent(source, fallback, surface.display_scale_factor),
        ResolveSceneRenderScale(scene));
    const Extent2D cover = CapRasterExtent(scaled, surface.max_dimension);
    if (capped != nullptr)
        *capped = cover.width != scaled.width || cover.height != scaled.height;
    return cover;
}

/// The part of a canvas-cover raster a framed SDR scene draws: `size` pixels at (`x`, `y`)
/// of the `cover` raster's own pixel grid.
struct SceneRasterWindow {
    Extent2D cover {};
    uint32_t x { 0 };
    uint32_t y { 0 };
    Extent2D size {};

    /// Whether the window leaves part of the cover raster out.
    bool Framed() const {
        return size.width > 0 && size.height > 0 &&
               (size.width < cover.width || size.height < cover.height);
    }
};

/// How the composition lays the whole cover raster on its destination along one axis, as
/// the unframed composition does: from `origin` over `extent` destination pixels, on a
/// destination `output` pixels long. For a horizontally flipped composition, which reads the
/// raster right to left, the origin is mirrored about the destination.
struct RasterAxisPlacement {
    double   origin { 0.0 };
    double   extent { 1.0 };
    uint32_t output { 1 };
};

namespace detail
{

/// A bilinear weight below this is zero in the sampler's 8-bit sub-texel position, so the
/// texel it belongs to is not read.
inline constexpr double kSubTexelTolerance = 1.0 / 512.0;

/// The cover-raster texels one axis of the composition reads, half-open and clamped to the
/// raster: the bilinear pair under every destination pixel centre the raster covers, less a
/// texel whose weight rounds to zero. Empty when the raster is not seen at all.
inline std::pair<uint32_t, uint32_t> SampledCoverTexels(uint32_t cover,
                                                        const RasterAxisPlacement& place) {
    if (cover == 0 || ! std::isfinite(place.origin) || ! std::isfinite(place.extent) ||
        ! (place.extent > 0.0) || place.output == 0)
        return { 0, cover };
    const double first = std::max(0.0, std::ceil(place.origin - 0.5));
    const double last =
        std::min(static_cast<double>(place.output) - 1.0, std::floor(place.origin + place.extent - 0.5));
    if (last < first) return { 0, 0 };
    const double texels_per_pixel = static_cast<double>(cover) / place.extent;
    // The texel-centre coordinate a destination pixel centre samples.
    const auto sample = [&](double pixel) {
        return (pixel + 0.5 - place.origin) * texels_per_pixel - 0.5;
    };
    const double low  = std::floor(sample(first) + kSubTexelTolerance);
    const double high = std::floor(sample(last) - kSubTexelTolerance) + 2.0;
    const auto clamp = [cover](double value) {
        return static_cast<uint32_t>(std::clamp(value, 0.0, static_cast<double>(cover)));
    };
    return { clamp(low), clamp(high) };
}

inline uint32_t RoundDownTo(uint32_t value, uint32_t align) { return value / align * align; }
inline uint32_t RoundUpTo(uint32_t value, uint32_t align) {
    return (value + align - 1) / align * align;
}

/// One axis of `PlanSceneRasterWindow`: start and size.
inline std::pair<uint32_t, uint32_t> PlanRasterWindowAxis(uint32_t cover,
                                                          const RasterAxisPlacement& place,
                                                          uint32_t align, bool headroom) {
    const auto [low, high] = SampledCoverTexels(cover, place);
    if (align == 0 || cover % align != 0 || high <= low) return { 0, cover };
    const uint32_t start = RoundDownTo(low, align);
    uint32_t       size  = std::min(cover, RoundUpTo(high, align)) - start;
    // Room for the same span to be read at any phase of the alignment grid.
    if (headroom) size = std::max(size, RoundUpTo(high - low + 1, align) + align);
    if (size >= cover) return { 0, cover };
    return { std::min(start, cover - size), size };
}

/// One axis of `PlaceSceneRasterWindow`: the start that keeps a window of `size` over what
/// `place` reads, or nothing.
inline std::optional<uint32_t> PlaceRasterWindowAxis(uint32_t cover, uint32_t size,
                                                     const RasterAxisPlacement& place,
                                                     uint32_t align) {
    if (size >= cover) return 0u;
    const auto [low, high] = SampledCoverTexels(cover, place);
    if (align == 0 || high <= low) return std::nullopt;
    const uint32_t start = std::min(RoundDownTo(low, align), cover - size);
    if (start % align != 0 || start > low || start + size < high) return std::nullopt;
    return start;
}

/// `value` as a fraction with a denominator up to `limit`, or nothing.
inline std::optional<std::pair<uint64_t, uint64_t>> SmallFraction(double value, uint64_t limit) {
    if (! std::isfinite(value) || ! (value > 0.0)) return std::nullopt;
    for (uint64_t denominator = 1; denominator <= limit; ++denominator) {
        const double numerator = value * static_cast<double>(denominator);
        const double whole     = std::round(numerator);
        if (whole >= 1.0 && std::abs(numerator - whole) <= 1e-9 * std::max(1.0, numerator))
            return std::pair<uint64_t, uint64_t> { static_cast<uint64_t>(whole), denominator };
    }
    return std::nullopt;
}

} // namespace detail

/// The largest denominator a window keeps whole; a finer fraction of the raster leaves the
/// scene unframed.
inline constexpr uint32_t kMaxRasterWindowAlignment = 64;

/// The multiple a raster window's start and size keep on both axes so that every screen-sized
/// target among `sampled` keeps the cover raster's texel grid: a target drawn at a fraction
/// p/q of the raster, directly or through bound targets, has its texels start at multiples of
/// q of the raster's, and the window must cut it there. Zero when no window can: a
/// mip-mapped target (its smallest levels would need a window of nearly the whole raster) or
/// a fraction with a denominator over `kMaxRasterWindowAlignment`.
template <typename Keys>
uint32_t ScreenBoundWindowAlignment(const Scene& scene, const Keys& sampled) {
    uint64_t alignment = 1;
    const std::string output(SpecTex_Default);
    for (const std::string& name : sampled) {
        std::string key = scene.ResolveRenderTargetName(name);
        uint64_t    numerator = 1, denominator = 1, hops = 0;
        bool        screen = false, mipmapped = false;
        while (hops++ < 16) {
            const auto found = scene.renderTargets.find(key);
            if (found == scene.renderTargets.end()) break;
            const SceneRenderTarget& target = found->second;
            mipmapped = mipmapped || (target.has_mipmap && target.mipmap_level != 1);
            if (key == output) {
                screen = true;
                break;
            }
            if (target.unscaled || ! target.bind.enable) break;
            const auto fraction =
                detail::SmallFraction(target.bind.scale, kMaxRasterWindowAlignment);
            if (! fraction) return 0;
            numerator *= fraction->first;
            denominator *= fraction->second;
            const uint64_t common = std::gcd(numerator, denominator);
            numerator /= common;
            denominator /= common;
            alignment = std::lcm(alignment, denominator);
            if (alignment > kMaxRasterWindowAlignment) return 0;
            if (target.bind.screen) {
                screen = true;
                break;
            }
            key = target.bind.name;
        }
        if (screen && mipmapped) return 0;
        if (! screen) continue;
    }
    return static_cast<uint32_t>(alignment);
}

/// The window of `cover` a framed SDR scene draws for the composition `x` and `y` describe,
/// its start and size multiples of `align`. With `headroom` it is large enough for the
/// composition to move by any amount without leaving it (a pan). The whole raster when
/// nothing would be left out, when the cover raster is not a multiple of `align` on an axis
/// it would cut, or when `align` is zero.
inline SceneRasterWindow PlanSceneRasterWindow(const Extent2D& cover, const RasterAxisPlacement& x,
                                               const RasterAxisPlacement& y, uint32_t align,
                                               bool headroom) {
    SceneRasterWindow window { .cover = cover, .x = 0, .y = 0, .size = cover };
    if (align == 0) return window;
    const auto [left, width]  = detail::PlanRasterWindowAxis(cover.width, x, align, headroom);
    const auto [top, height]  = detail::PlanRasterWindowAxis(cover.height, y, align, headroom);
    window.x    = left;
    window.y    = top;
    window.size = { width, height };
    return window;
}

/// Moves `window` (same size) so it holds what the composition `x` and `y` describe reads.
/// False, and `window` as it was, when it cannot.
inline bool PlaceSceneRasterWindow(SceneRasterWindow& window, const RasterAxisPlacement& x,
                                   const RasterAxisPlacement& y, uint32_t align) {
    const auto left = detail::PlaceRasterWindowAxis(window.cover.width, window.size.width, x, align);
    const auto top  = detail::PlaceRasterWindowAxis(window.cover.height, window.size.height, y, align);
    if (! left || ! top) return false;
    window.x = *left;
    window.y = *top;
    return true;
}

/// The clip-space scale and offset (`Scene::display_clip`) that draw the canvas, which fills
/// the cover raster, into `window`.
inline std::array<double, 4> SceneRasterWindowClip(const SceneRasterWindow& window) {
    const double cover_w = window.cover.width, cover_h = window.cover.height;
    const double width = std::max(1u, window.size.width), height = std::max(1u, window.size.height);
    return { cover_w / width, cover_h / height, (cover_w - 2.0 * window.x) / width - 1.0,
             1.0 - (cover_h - 2.0 * window.y) / height };
}

/// Where along one axis the composition draws a window of `size` texels starting at `start`
/// of a `cover` raster that the unframed composition lays over `extent` destination pixels
/// from `origin`, so each destination pixel samples the same cover-raster position:
/// origin and length in destination pixels. `mirrored` for a flipped composition, which
/// reads the raster right to left.
inline std::pair<double, double> RasterWindowFootprint(uint32_t cover, uint32_t start, uint32_t size,
                                                       double origin, double extent, bool mirrored) {
    const double pixels_per_texel = extent / std::max(1u, cover);
    const double length           = size * pixels_per_texel;
    return { mirrored ? origin + extent - (static_cast<double>(start) + size) * pixels_per_texel
                      : origin + start * pixels_per_texel,
             length };
}

/// Fits the scene's authored canvas into an output of `width` x `height`.
///
/// Purely scene-side camera arithmetic with nothing GPU-specific in it, so
/// every caller shares this one definition. Two copies of it would drift, and
/// the drift would show as the same wallpaper framed differently.
inline void ApplyCameraFillMode(wallpaper::Scene& scene, wallpaper::FillMode mode, uint32_t width,
                                uint32_t height) {
    if (width == 0 || height == 0) return;
    const auto canvas_entry      = scene.cameras.find("global");
    const auto perspective_entry = scene.cameras.find("global_perspective");
    if (canvas_entry == scene.cameras.end() || perspective_entry == scene.cameras.end()) return;
    SceneCamera* canvas      = canvas_entry->second.get();
    SceneCamera* perspective = perspective_entry->second.get();
    if (canvas == nullptr || perspective == nullptr) return;

    const double scene_width  = std::max<i32>(1, scene.ortho[0]);
    const double scene_height = std::max<i32>(1, scene.ortho[1]);
    const double scene_aspect = scene_width / scene_height;
    const double output_aspect = static_cast<double>(width) / static_cast<double>(height);

    double frame_width  = scene_width;
    double frame_height = scene_height;
    double aspect       = scene_aspect;
    switch (mode) {
    case wallpaper::FillMode::STRETCH: break;
    case wallpaper::FillMode::ASPECTFIT:
        aspect = output_aspect;
        if (output_aspect < scene_aspect) frame_height = scene_width / output_aspect;
        else frame_width = scene_height * output_aspect;
        break;
    default:
        aspect = output_aspect;
        if (output_aspect > scene_aspect) frame_height = scene_width / output_aspect;
        else frame_width = scene_height * output_aspect;
        break;
    }
    canvas->SetWidth(frame_width);
    canvas->SetHeight(frame_height);
    perspective->SetAspect(aspect);
    FitCanvasPerspective(*perspective, *canvas);
    canvas->Update();
    perspective->Update();
}

/// What a static-reuse sample folds of one camera: a digest of its
/// view-projection matrix, which carries the camera's position and visible
/// extent alike.
inline uint64_t CameraSampleDigest(const wallpaper::SceneCamera& camera) {
    const linalg::Matrix4d matrix = camera.GetViewProjectionMatrix();
    return StaticHashBytes(0xcbf29ce484222325ULL, matrix.data(), sizeof(double) * 16);
}

/// Folds into a static-reuse sample the cameras a pass depends on: the one it
/// draws through -- `camera_override` when the graph set one, else its node's --
/// and the scene's active camera, which a compose layer samples the screen with.
/// Neither is covered by the node transform, and both move without a graph
/// rebuild: a fill-mode change, a camera layer's zoom or pan, a script. Every
/// caller shares this one definition, so caches invalidate on the same camera
/// changes. `active_camera` false leaves the active camera out, for a pass whose
/// uniforms are proven not to read it (`IShaderValueUpdater::TransformInputs`);
/// the camera it draws through is folded either way.
///
/// `digest` gives each camera's `CameraSampleDigest`. A caller sampling many
/// passes of one frame may remember it per camera for that frame, since nearly
/// every pass draws through the same one or two cameras, but never across
/// frames.
template <typename Digest>
inline uint64_t FoldPassCameras(uint64_t hash, const wallpaper::Scene& scene,
                                const std::string& camera_override,
                                const wallpaper::SceneNode* node, Digest&& digest,
                                bool active_camera = true) {
    const auto fold = [&hash, &digest](const wallpaper::SceneCamera* camera) {
        if (camera == nullptr) return;
        hash = StaticHashMix(hash, digest(*camera));
    };
    const std::string& camera_name =
        ! camera_override.empty() ? camera_override
                                  : (node != nullptr ? node->Camera() : std::string {});
    if (! camera_name.empty()) {
        const auto found = scene.cameras.find(camera_name);
        fold(found != scene.cameras.end() ? found->second.get() : nullptr);
    }
    if (active_camera) fold(scene.activeCamera);
    return hash;
}

inline uint64_t FoldPassCameras(uint64_t hash, const wallpaper::Scene& scene,
                                const std::string& camera_override,
                                const wallpaper::SceneNode* node) {
    return FoldPassCameras(hash, scene, camera_override, node,
                           [](const wallpaper::SceneCamera& camera) {
                               return CameraSampleDigest(camera);
                           });
}

} // namespace render
} // namespace wallpaper
