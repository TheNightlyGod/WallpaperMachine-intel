#pragma once
#include <cstdint>
#include <cmath>
#include <span>
#include <memory>
#include <functional>

#include "Particle/Particle.h"
#include "Scene/SceneMesh.h"

namespace wallpaper
{
struct ParticleRawGenSpec {
    float* lifetime;
};
using ParticleRawGenSpecOp = std::function<void(const Particle&, const ParticleRawGenSpec&)>;

/// Per-subsystem generator input. A particle's size is written as authored:
/// the layer's model matrix scales the billboard, as Wallpaper Engine's
/// particle shader builds it in the layer's own space.
struct ParticleRenderScale {
    /// How many straight pieces a rope renderer draws between two connected
    /// particles. One means a single piece per pair; a sprite renderer ignores
    /// it. Carried here because it is per-subsystem generator input exactly as
    /// the scale is, and the generator is shared by every subsystem.
    uint32_t rope_subdivision { 1 };
    /// Rope trails only: `ParticleSubSystem::TrailPeriodFraction()` for this
    /// tick, so the oldest piece of a full trail can shrink by exactly as much
    /// as the newest one has grown instead of vanishing in one step.
    float trail_fraction { 0.0f };
    /// Texture repeats along the whole rope/trail. The author shader has no
    /// uniform for this; it is encoded in the trail-length the generator writes.
    float uv_scale { 1.0f };
    /// When set, a rope's texture is measured against the particles it holds once
    /// steady (`rope_rate` x `rope_lifetime`) and moves on by one for each particle
    /// that dies, so a growing rope unrolls it instead of stretching it.
    bool uv_scrolling { false };
    /// `uvsmoothing`: until the rope is steady WE draws it as without (probe rope-uv-v3).
    bool uv_smoothing { false };
    /// A scrolling rope: its file's emission rate and average lifetime (lifetime
    /// override included), and the scene's frame-rate cap that bounds the rate
    /// while the rope is still filling (0x1402308A0, probe rope-uv-v4).
    float    rope_rate { 0.0f };
    float    rope_lifetime { 0.0f };
    uint32_t target_fps { 0 };
    /// World event emitters store the instance origin in each birth position.
    bool positions_include_binding { false };
    /// Native rope-trail fade bits, applied by the existing vertex preparation.
    uint8_t trail_fade_flags { 0 };
};

inline float RopeUvScaleOrOne(float scale) noexcept {
    return (std::isfinite(scale) && scale > 0.0f) ? scale : 1.0f;
}

/// The length a rope or rope-trail record carries for `length` points: WE stores
/// 1 / uvscale and writes the count times it (0x1402308A0, probe rope-uv-v3).
inline float EncodeRopeTrailLength(float authored_length, float uv_scale) noexcept {
    return authored_length / RopeUvScaleOrOne(uv_scale);
}

/// A rope trail's `g_RenderVar0.w` for a history of `capacity` points (0x1402366F0):
/// the capacity less half a point, or the scaled capacity less one while scrolling.
inline float RopeTrailMaxCount(float capacity, float uv_scale, bool scrolling) noexcept {
    return scrolling ? (capacity - 1.0f) / RopeUvScaleOrOne(uv_scale) : capacity - 0.5f;
}

/// One subsystem's "already logged" latches. The generator is shared by every
/// subsystem, so these cannot live on it: one layer overflowing would silence
/// the log for every other layer, and one layer recovering would re-arm a log
/// another layer is still overflowing.
struct ParticleOverflowFlags {
    bool rope_capacity { false };
    bool index { false };
};
class ParticleInstance;
class IParticleRawGener {
public:
    IParticleRawGener()          = default;
    virtual ~IParticleRawGener() = default;
    virtual void GenGLData(std::span<const std::unique_ptr<ParticleInstance>>, SceneMesh&,
                           ParticleRawGenSpecOp&, ParticleRenderScale render_scale,
                           ParticleOverflowFlags& overflow_flags) = 0;
};
} // namespace wallpaper
