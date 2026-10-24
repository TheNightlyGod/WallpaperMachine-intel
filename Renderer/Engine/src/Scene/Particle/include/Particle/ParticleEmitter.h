#pragma once
#include "Particle.h"

#include <vector>
#include <random>
#include <memory>
#include <functional>
#include <array>
#include <span>

#include "Core/Literals.hpp"

namespace wallpaper
{

struct ParticleControlpoint {
    bool            link_mouse { false };
    bool            worldspace { false };
    linalg::Vector3d base_offset { 0, 0, 0 };
    linalg::Vector3d offset { 0, 0, 0 };
    /// Where `offset` was at the end of the previous step. Operators that
    /// follow a moving control point (maintain distance, ...) read the
    /// difference. Equal to `offset` until the control point first moves.
    linalg::Vector3d prev_offset { 0, 0, 0 };
    /// Orientation of the control point. Identity unless the scene object
    /// (`instanceoverride.controlpointangleN`) or the preset turns it.
    linalg::Matrix3d rotation { linalg::Matrix3d::Identity() };
    /// Whether `rotation` is a real orientation (not the identity default).
    bool has_rotation { false };
    /// A world-space system only: the rotation and scale of its layer's matrix.
    /// Wallpaper Engine's control point matrices carry the layer's world matrix
    /// when the particle file is `worldspace`, except a control point pinned to
    /// the world, which keeps the matrix it was authored with. An emitter turns
    /// and scales its spawn offset by the matrix of its control point, so a
    /// layer scaled up spreads the particles it spawns wider while each one
    /// keeps its size. Identity, with `has_world_linear` clear, for a layer-space
    /// system and for a pinned control point.
    linalg::Matrix3d world_linear { linalg::Matrix3d::Identity() };
    bool            has_world_linear { false };
};

struct ParticleInfo {
    std::span<Particle>                   particles;
    std::span<const ParticleControlpoint> controlpoints;
    double                                time;
    double                                time_pass;
    /// Rotation that carries a direction authored in the world (screen) frame
    /// into the owner layer's local frame. Identity for an unrotated layer.
    linalg::Matrix3d world_to_local { linalg::Matrix3d::Identity() };
    /// The second step of a run that was split in two half steps, or an
    /// ordinary step. Reserved for operators that need to tell them apart.
    bool prewarm { false };
    /// A movement operator stores each particle's position before it moves it
    /// in `Particle::prev_position`. Set while an operator reads it.
    bool track_previous_position { false };
};

/// Everything a spawn-time initializer may read besides the particle it
/// creates. The subsystem that owns the initializers keeps one and refreshes
/// it before every emission; initializers hold it by `shared_ptr`.
struct ParticleSpawnContext {
    std::span<const ParticleControlpoint> controlpoints;
    /// Seconds the particle system has been simulated for.
    double system_time { 0.0 };
    /// Length of the step that is spawning.
    double frame_time { 0.0 };
    /// For an event child: the parent particle the instance is bound to, else
    /// null. Valid only while the spawn it was set for runs.
    const Particle* parent { nullptr };
    /// The layer matrix (rotation and scale) the spawning emitter's control point
    /// carries, clear when it carries none: a layer-space system, or a control
    /// point pinned to the world. The engine hands that control point's matrix to
    /// the velocity initializers, and they turn and scale the velocity they draw
    /// by it: a layer stretched along x launches its particles faster along x.
    /// Each emitter writes it before its particles are initialized (see
    /// `ParticleBoxEmitterArgs::spawn`).
    linalg::Matrix3d world_linear { linalg::Matrix3d::Identity() };
    bool            has_world_linear { false };
};

using ParticleInitOp = std::function<void(Particle&, double)>;
using ParticleOperatorOp = std::function<void(const ParticleInfo&)>;

using ParticleEmittOp =
    std::function<void(std::vector<Particle>&, std::vector<ParticleInitOp>&, uint32_t maxcount,
                       double timepass, std::span<const ParticleControlpoint> controlpoints)>;

/// When an emitter starts, stops and pauses. Zero means "not used" for every
/// field, which is Wallpaper Engine's default for a key the file leaves out.
struct ParticleEmitterTiming {
    /// Seconds to wait before the first emission.
    float delay { 0.0f };
    /// Seconds the emitter emits for; 0 is forever.
    float duration { 0.0f };
    /// Emit in windows separated by pauses (emitter `flags` bit 4).
    bool  periodic { false };
    float minPeriodicDuration { 0.0f };
    float maxPeriodicDuration { 0.0f };
    float minPeriodicDelay { 0.0f };
    float maxPeriodicDelay { 0.0f };
    /// Cap on rate emissions in one periodic window; 0 is uncapped.
    u32   maxToEmitPerPeriod { 0 };
};

struct ParticleBoxEmitterArgs {
    std::array<float, 3>         directions;
    std::array<float, 3>         minDistance;
    std::array<float, 3>         maxDistance;
    float                        emitSpeed;
    std::array<float, 3>         orgin;
    bool                         one_per_frame;
    bool                         sort;
    u32                          instantaneous;
    float                        minSpeed;
    float                        maxSpeed;
    i32                          controlpoint { 0 };
    std::shared_ptr<const float> countMultiplier;
    std::function<float()>       audioResponse;
    ParticleEmitterTiming        timing {};
    /// The owning system's spawn context. Before an emission the emitter writes
    /// the layer's matrix its control point carries into it, so the velocity
    /// initializers of the particles it spawns read the matrix of the control
    /// point that spawned them. Null: the context is left as it stands.
    std::shared_ptr<ParticleSpawnContext> spawn;

    static ParticleEmittOp MakeEmittOp(ParticleBoxEmitterArgs);
};

struct ParticleSphereEmitterArgs {
    std::array<float, 3>         directions;
    float                        minDistance;
    float                        maxDistance;
    float                        emitSpeed;
    std::array<float, 3>         orgin;
    std::array<int32_t, 3>       sign;
    bool                         one_per_frame;
    bool                         sort;
    u32                          instantaneous;
    float                        minSpeed;
    float                        maxSpeed;
    i32                          controlpoint { 0 };
    std::shared_ptr<const float> countMultiplier;
    std::function<float()>       audioResponse;
    ParticleEmitterTiming        timing {};
    /// 0 spawns over the whole sphere, 1 along +x only.
    float                        cone { 0.0f };
    /// The owning system's spawn context. Before an emission the emitter writes
    /// the layer's matrix its control point carries into it, so the velocity
    /// initializers of the particles it spawns read the matrix of the control
    /// point that spawned them. Null: the context is left as it stands.
    std::shared_ptr<ParticleSpawnContext> spawn;

    static ParticleEmittOp MakeEmittOp(ParticleSphereEmitterArgs);
};

} // namespace wallpaper
