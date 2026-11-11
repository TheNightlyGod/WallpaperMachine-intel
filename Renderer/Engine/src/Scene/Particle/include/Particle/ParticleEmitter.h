#pragma once
#include "Particle.h"

#include <vector>
#include <random>
#include <memory>
#include <functional>
#include <array>
#include <span>
#include <optional>
#include <type_traits>
#include <utility>

#include "Core/Literals.hpp"

namespace wallpaper
{

struct ParticleControlpoint {
    bool            link_mouse { false };
    bool            worldspace { false };
    bool            copy_from_parent { false };
    bool            copy_raw { false };
    uint32_t        parent_point { 0 };
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
    /// The source supplied a complete parent-derived frame this step.
    bool parent_resolved { false };
    bool written_by_remap { false };
    /// The native operator's SIMD write also updates the point's matrix w.
    /// Kept in the existing alignment padding; ordinary points remain affine.
    float homogeneous { 1.0f };
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
    bool            owned_world_relative { false };
    bool            homogeneous_may_vary { false };
};

struct ParticleInfo {
    std::span<Particle>                   particles;
    std::span<const ParticleControlpoint> controlpoints;
    double                                time;
    double                                time_pass;
    /// Wallpaper Engine's second timestep, `time_pass · pow(min(0.025·fps, 1), 0.7)`
    /// (0x140237724, artifacts/we-parity/decompiles/F-D5.md): the forces and drags
    /// (movement and angular drag, control point attraction, turbulence, vortex)
    /// act over it while positions still integrate over `time_pass`. Equal to
    /// `time_pass` at 40 frames a second or more, or with the frame rate unknown.
    double                                time_pass_scaled;
    /// Rotation that carries a direction authored in the world (screen) frame
    /// into the owner layer's local frame. Identity for an unrotated layer.
    linalg::Matrix3d world_to_local { linalg::Matrix3d::Identity() };
    /// A movement operator stores each particle's position before it moves it
    /// in `Particle::prev_position`. Set while an operator reads it.
    bool track_previous_position { false };
    bool world_space { false };
    /// For an event child: the live parent particle its instance is bound to,
    /// else null (`inheritvaluefromevent`).
    const Particle* parent { nullptr };
    /// Counts the subsystem's steps; both half steps of one frame share it
    /// (`boids` updates a slice of the particles chosen by it).
    uint32_t step { 0 };
    /// What `remapvalue` reads besides the particles: the scene time (the
    /// layer's clock), the local time of day as a fraction of the day, and the
    /// layer's origin in the scene (zero unless an operator asked for it).
    double           layer_time { 0.0 };
    double           time_of_day { 0.0 };
    linalg::Vector3d layer_origin { 0.0, 0.0, 0.0 };
    /// Carries a point given in scene coordinates into the particles' own
    /// frame (the inverse of the layer's model matrix; for a world-space system
    /// the shift by the layer origin it draws through), and the scene canvas
    /// size. Filled only while an operator asked for them
    /// (`ParticleSubSystem::SetNeedsSceneFrame`): `collisionbounds` and
    /// `collisionmodel`.
    linalg::Matrix4d scene_to_local { linalg::Matrix4d::Identity() };
    linalg::Vector2d canvas { 0.0, 0.0 };
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
    /// Scene time before a particle instance's rate multiplier (layer-image motion).
    double scene_frame_time { 0.0 };
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
    bool world_space { false };
    /// As `ParticleInfo::layer_time`, `time_of_day` and `layer_origin`, for
    /// `remapinitialvalue`.
    double           layer_time { 0.0 };
    double           time_of_day { 0.0 };
    linalg::Vector3d layer_origin { 0.0, 0.0, 0.0 };
    /// The scene-to-particle transform, filled only for layer-linked emitters.
    linalg::Matrix4d scene_to_local { linalg::Matrix4d::Identity() };
};

using ParticleInitOp = std::function<void(Particle&, double)>;
using ParticleOperatorOp = std::function<void(const ParticleInfo&)>;

struct ParticleEmitterControl {
    enum class Command { Step, Inspect, Stop, Play, ApplyOverride };
    Command command { Command::Step };
    bool scheduled { true };
    uint32_t extra { 0 };
    bool finished { false };
};

/// One value-owned emitter, including its mutable schedule. Copying an operation
/// for a new instance copies that schedule; controls never share it across instances.
class ParticleEmittOp {
    using Function = std::function<void(std::vector<Particle>&, std::vector<ParticleInitOp>&,
        uint32_t, double, std::span<const ParticleControlpoint>, ParticleEmitterControl&)>;
    using Legacy = std::function<void(std::vector<Particle>&, std::vector<ParticleInitOp>&,
        uint32_t, double, std::span<const ParticleControlpoint>)>;
public:
    ParticleEmittOp() = default;
    template<class F> requires (!std::is_same_v<std::remove_cvref_t<F>, ParticleEmittOp>)
    ParticleEmittOp(F&& function) {
        if constexpr (std::is_invocable_r_v<void, F&, std::vector<Particle>&,
            std::vector<ParticleInitOp>&, uint32_t, double,
            std::span<const ParticleControlpoint>, ParticleEmitterControl&>) {
            m_function = std::forward<F>(function);
        } else {
            m_function = [step=Legacy(std::forward<F>(function)), stopped=false](
                std::vector<Particle>& particles, std::vector<ParticleInitOp>& initializers,
                uint32_t capacity, double seconds, std::span<const ParticleControlpoint> points,
                ParticleEmitterControl& control) mutable {
                using Command = ParticleEmitterControl::Command;
                if (control.command == Command::Stop) stopped = true;
                else if (control.command == Command::Play) stopped = false;
                else if (control.command == Command::Step && step &&
                         ((!stopped && control.scheduled) || control.extra != 0))
                    step(particles, initializers, capacity, seconds, points);
                control.finished = stopped || !step;
            };
        }
    }
    void operator()(std::vector<Particle>& particles, std::vector<ParticleInitOp>& initializers,
                    uint32_t capacity, double seconds, std::span<const ParticleControlpoint> points,
                    ParticleEmitterControl& control) const {
        if (m_function) m_function(particles, initializers, capacity, seconds, points, control);
        else control.finished = true;
    }
    void operator()(std::vector<Particle>& particles, std::vector<ParticleInitOp>& initializers,
                    uint32_t capacity, double seconds, std::span<const ParticleControlpoint> points) const {
        ParticleEmitterControl control;
        (*this)(particles, initializers, capacity, seconds, points, control);
    }
    bool Finished() const { return Command(ParticleEmitterControl::Command::Inspect); }
    void Stop() { (void)Command(ParticleEmitterControl::Command::Stop); }
    void Play() { (void)Command(ParticleEmitterControl::Command::Play); }
    void ApplyOverride() { (void)Command(ParticleEmitterControl::Command::ApplyOverride); }
private:
    bool Command(ParticleEmitterControl::Command command) const {
        std::vector<Particle> particles;
        std::vector<ParticleInitOp> initializers;
        ParticleEmitterControl control { .command=command };
        (*this)(particles, initializers, 0, 0, {}, control);
        return control.finished;
    }
    Function m_function;
};

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

/// An emitter that places each particle where a caller says (the `layerimage`
/// emitter: a texel of a linked layer). It shares the rate, burst, timing,
/// count and audio rules of the shape emitters. The supplied particle already
/// has its position, inherited velocity and image colour, before initializers
/// add to them. An empty result consumes the step without spawning.
struct ParticlePlacedEmitterArgs {
    float                         emitSpeed { 0.0f };
    bool                          one_per_frame { false };
    bool                          sort { false };
    u32                           instantaneous { 0 };
    i32                           controlpoint { 0 };
    std::shared_ptr<const float>  countMultiplier;
    std::function<float()>        audioResponse;
    ParticleEmitterTiming         timing {};
    std::shared_ptr<ParticleSpawnContext> spawn;
    std::function<std::optional<Particle>()> particle;

    static ParticleEmittOp MakeEmittOp(ParticlePlacedEmitterArgs);
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
