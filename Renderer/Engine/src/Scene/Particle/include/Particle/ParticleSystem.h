#pragma once
#include <array>
#include "ParticleEmitter.h"
#include "ParticleTrail.h"
#include "Interface/IParticleRawGener.h"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"

#include <memory>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace wallpaper
{

enum class ParticleAnimationMode
{
    SEQUENCE,
    RANDOMONE,
};

class ParticleSystem;
class SceneNode;
namespace wpscene { class ParticleInstanceoverride; }

/// Only allocated on the first SceneScript instance write. The script sees its
/// pending fields immediately; the simulation binds them at its next step.
struct ParticleInstanceUpdate {
    static constexpr std::size_t kFields = 24; // seven scalars, colour, eight points and angles
    std::array<std::array<float, 3>, kFields> values {};
    uint32_t fields { 0 };
    bool queued { false };
    std::function<void(ParticleInstanceUpdate&)> apply;
};

/// Wallpaper Engine's factor between a step and the step its forces act over,
/// `pow(min(0.025 · fps, 1), 0.7)` with fps the host's frame-rate cap
/// (0x140237724; artifacts/we-parity/decompiles/F-D5.md). 1 at 40 frames a
/// second or more, and for an unknown rate (0).
double ParticleForceStepScale(uint32_t target_fps);
/// Whether Wallpaper Engine runs a step's operators as two half steps: a cap of
/// 1 to 20 frames a second (engine+0x148, the same function).
bool ParticleRunsHalfSteps(uint32_t target_fps);

class ParticleInstance : NoCopy, NoMove {
public:
    struct BoundedData {
        ParticleInstance* parent { nullptr };
        isize             particle_idx { -1 };

        bool            pre_lifetime_ok { true };
        bool            controlpoints_primed { false };
        linalg::Vector3f pos { 0.0f, 0.0f, 0.0f };
    };

    void Refresh();
    /// Stable pool slot and recycle generation; stored in existing padding.
    uint32_t Index() const { return m_index; }
    void SetIndex(uint32_t index) { m_index = index; }
    uint32_t Generation() const { return m_generation; }
    /// Particles that have died in this instance since it began (WE's +848, which a
    /// scrolling rope's texture moves on by).
    uint32_t Deaths() const { return m_deaths; }
    void     CountDeath() { ++m_deaths; }
    void SetGeneration(uint32_t generation) { m_generation = generation; }

    /// The emitters and initializers this instance runs. Each instance holds
    /// its own copies of the subsystem's, because an emitter keeps a schedule
    /// (delay, duration, window, pending burst) and an initializer may count
    /// the particles it has placed; a recycled instance starts both again.
    /// Empty until the owning subsystem binds them.
    std::vector<ParticleEmittOp>& Emitters() { return m_emitters; }
    std::vector<ParticleInitOp>&  Initializers() { return m_initializers; }
    /// Version of the subsystem's operations the copies were made from; zero
    /// when there are none.
    u64  BoundVersion() const { return m_bound_version; }
    void SetBoundVersion(u64 version) { m_bound_version = version; }
    bool Emitting() const { return m_emitting; }
    void SetEmitting(bool value) { m_emitting = value; }

    bool IsDeath() const;
    void SetDeath(bool);

    bool IsNoLiveParticle() const;
    void SetNoLiveParticle(bool);

    std::span<const Particle> Particles() const;
    std::vector<Particle>&    ParticlesVec();

    /// Recorded paths, parallel to `Particles()` by slot. Empty unless the
    /// owning subsystem keeps trail history, so a reader must check the size
    /// before indexing it with a particle's slot.
    std::span<const ParticleTrailHistory> Trails() const;
    std::vector<ParticleTrailHistory>&    TrailsVec();

    BoundedData& GetBoundedData();

private:
    uint32_t              m_deaths { 0 };
    bool                  m_is_death { false };
    bool                  m_no_live_particle { false };
    uint32_t              m_index { 0 };
    std::vector<Particle> m_particles;
    std::vector<ParticleTrailHistory> m_trails;
    BoundedData           m_bounded_data;
    std::vector<ParticleEmittOp> m_emitters;
    std::vector<ParticleInitOp>  m_initializers;
    u64                          m_bound_version { 0 };
    bool                         m_emitting { false };
    uint32_t                     m_generation { 0 };
};

class ParticleSubSystem : NoCopy, NoMove {
public:
    enum class SpawnType
    {
        STATIC,
        EVENT_FOLLOW,
        EVENT_SPAWN,
        EVENT_DEATH,
    };

public:
    ParticleSubSystem(ParticleSystem& p, std::shared_ptr<SceneMesh> sm, uint32_t maxcount,
                      double rate, u32 maxcount_instance, double probability, SpawnType type,
                      ParticleRawGenSpecOp specOp);
    ~ParticleSubSystem();

    void Emitt(bool inherited_pause = false);
    void Play();
    void Pause();
    void Stop();
    bool IsPlaying() const;
    void EmitParticles(int32_t count);
    void ApplyInstanceOverride();
    /// Updated by the existing simulation walk, including paused live particles.
    bool HasTimeAdvancingWork() const { return m_time_advancing; }
    /// Rebuilds this subsystem's mesh from the simulation `Emitt` already ran,
    /// without emitting, ageing or killing anything. A frame that hid the
    /// owner skipped that rebuild; the first frame that draws it calls this
    /// so the geometry matches the simulation this frame left behind.
    void RebuildMesh();
    /// The mesh this subsystem writes, so a draw can tell a skipped rebuild
    /// from one this frame already did.
    const SceneMesh* Mesh() const { return m_mesh.get(); }
    void UpdateMouseControlpoints();

    ParticleInstance* QueryNewInstance();

    void AddEmitter(ParticleEmittOp&&);
    void AddInitializer(ParticleInitOp&&);
    void AddOperator(ParticleOperatorOp&&);

    /// What spawn-time initializers read besides their particle. Initializers
    /// that need it capture this pointer; the subsystem refreshes it before
    /// each emission.
    std::shared_ptr<ParticleSpawnContext> SpawnContext() const { return m_spawn_ctx; }

    /// Simulates `starttime` seconds before the first frame, as Wallpaper
    /// Engine does when it builds a particle system, so the first picture
    /// shows a populated system. The step is 0.05 s, or 0.2 s for a particle
    /// file whose `maxcount` is 500 or more. Zero or less does nothing.
    void SetStartTime(double seconds) { m_starttime = seconds; }
    double StartTime() const { return m_starttime; }
    /// Runs the prewarm for this subsystem. Called once, after the emitters,
    /// initializers, operators, control points and children are all in place
    /// and its layer sits under its parent groups: the layer's world matrix
    /// shapes what a prewarm spawns. A static child prewarms itself; an event
    /// child prewarms every instance it spawns.
    void Prewarm();

    /// Whether the subsystem builds geometry for a renderer. A particle file
    /// whose `renderer` list is empty has none: it is simulated (its particles
    /// can spawn children) and draws nothing, with no per-frame geometry cost.
    void SetDrawn(bool drawn) { m_drawn = drawn; }
    bool Drawn() const { return m_drawn; }

    /// Lets the loader set control points from the scene object that owns the
    /// system (`instanceoverride.controlpointN` / `controlpointangleN`). Called
    /// at the start of every step, so a property bound to the value is followed.
    enum class ControlpointStage { Prepare, Commit };
    using ControlpointSource = std::function<void(std::span<ParticleControlpoint>, ParticleInstance*,
        const linalg::Matrix4d&, const linalg::Matrix4d&, ControlpointStage)>;
    void SetControlpointSource(ControlpointSource source, bool per_instance = false, bool commit = false) {
        m_cp_source = std::move(source);
        m_cp_per_instance = per_instance;
        m_cp_commit = commit;
    }
    void SetControlpointCount(uint8_t count) { m_controlpoint_count = count; }
    uint8_t ControlpointCount() const { return m_controlpoint_count; }
    void SetParentPointFeed(int start);
    uint8_t ParentPointFeedStart() const { return m_parent_point_start; }
    void SetOwnedControlpoints(uint8_t mask) { m_owned_controlpoints = mask; }
    bool HasOwnedControlpoints() const { return m_owned_controlpoints != 0; }

    /// The layer's particles live in the world, not in the layer (the particle
    /// file's `worldspace` flag), as Wallpaper Engine draws them: through no
    /// model matrix of the layer's, so a particle keeps the size it was authored
    /// with whatever the layer's scale. Positions are measured from the layer's
    /// origin along the scene's own axes, and the system draws through a matrix
    /// that is only that origin (the nodes' render transform). The layer's
    /// rotation and scale reach a particle once, at its birth: in the offset an
    /// emitter places it at, the offset of a control point, and the velocity the
    /// velocity initializers give it. When the layer moves, turns or is rescaled,
    /// particles already emitted stay where they were in the scene and only new
    /// ones follow it. Without the flag every particle belongs to the layer and
    /// is drawn through its whole matrix.
    void SetWorldSpace(bool value);
    bool WorldSpace() const { return m_world_space; }
    bool ControlpointsPrimed() const { return m_cp_primed; }
    /// Base simulation frame, before each event instance's binding translation.
    linalg::Matrix4d SimulationTransform() const;

    /// The instances this subsystem simulates, for inspection.
    const std::vector<std::unique_ptr<ParticleInstance>>& Instances() const { return m_instances; }
    const std::vector<std::unique_ptr<ParticleSubSystem>>& Children() const { return m_children; }

    /// An operator reads the layer's world axes (a movement operator whose
    /// gravity stays screen-aligned); the subsystem then fills
    /// `ParticleInfo::world_to_local` every step.
    void SetNeedsWorldAxes(bool value) { m_needs_world_axes = value; }
    /// An operator reads `Particle::prev_position` (a control point attraction
    /// that removes the particles it passes); the movement operator then stores
    /// each particle's position before moving it.
    void SetTracksPreviousPosition(bool value) { m_tracks_prev_position = value; }
    /// A `remapvalue` or `remapinitialvalue` reads the layer's origin or the time
    /// of day; the subsystem then fills them every step.
    void SetNeedsLayerOrigin(bool value) { m_needs_layer_origin = value; }
    void SetNeedsTimeOfDay(bool value) { m_needs_time_of_day = value; }
    /// A `collisionbounds` or `collisionmodel` reads scene coordinates; the
    /// subsystem then fills `ParticleInfo::scene_to_local` and `canvas` every step.
    void SetNeedsSceneFrame(bool value) { m_needs_scene_frame = value; }

    void AddChild(std::unique_ptr<ParticleSubSystem>&&);
    /// A second renderer for the particles this subsystem simulates: it owns a
    /// mesh and a material of its own and is filled from this subsystem's
    /// instances, which it never simulates itself.
    void AddMirror(std::unique_ptr<ParticleSubSystem>&&);

    std::span<const ParticleControlpoint> Controlpoints() const;
    std::span<ParticleControlpoint>       Controlpoints();

    void SetOwnerNode(std::weak_ptr<SceneNode> node);
    void SetRateMultiplier(std::function<double()> rate_multiplier);

    /// Rope renderers only: how many straight pieces join two connected
    /// particles. Values below one are treated as one.
    void SetRopeSubdivision(u32 subdivision);
    /// A scrolling rope's measure: its file's rate and average lifetime (0x1402308A0).
    void SetRopeSteady(float rate, float lifetime) { m_rope_rate = rate; m_rope_lifetime = lifetime; }
    void SetRopeUv(float scale, bool scrolling, bool smoothing);
    void SetTrailFades(bool alpha, bool size) { m_trail_fade_flags = (alpha ? 1u : 0u) | (size ? 2u : 0u); }
    float UvScale() const { return m_uv_scale; }
    bool  UvScrolling() const { return m_uv_scrolling; }
    bool  UvSmoothing() const { return m_uv_smoothing; }
    /// Rope trail renderers only: makes every particle record its own path.
    /// The history is simulation state, advanced once per `Emitt()` with the
    /// same time step the particles move by, so pausing the simulation pauses
    /// the recording too.
    void SetTrail(ParticleTrailConfig config);
    /// Fraction of a recording period elapsed since the last point was taken,
    /// in [0, 1). A rope trail's shader reads it to keep the texture from
    /// jumping each time a point is recorded.
    float TrailPeriodFraction() const;

    SpawnType Type() const;
    u32       MaxInstanceCount() const;

private:
    ParticleRenderScale RenderScale(float trail_fraction) const;
    bool IsTrailRenderer() const;
    void UpdateTrailFraction(float fraction);

    struct ControlpointFrame {
        linalg::Matrix4d model { linalg::Matrix4d::Identity() };
        linalg::Matrix4d inverse { linalg::Matrix4d::Identity() };
        bool in_world { false };
        bool have_inverse { false };
        std::optional<linalg::Matrix3d> parent_to_local;
        std::array<linalg::Vector3d, 8> previous_offsets;
    };
    ControlpointFrame PrepareControlpointFrame() const;
    void SaveControlpointFrame(ParticleInstance*, ControlpointFrame* = nullptr);
    void ApplyParentPointFeed(ParticleInstance*, const ControlpointFrame&);
    void ApplyControlpointFrame(ParticleInstance*, const ControlpointFrame&,
                               const linalg::Vector3f& previous_binding = linalg::Vector3f::Zero());
    /// One simulation step of every instance of this subsystem, `dt` long: the
    /// part of `Emitt` that does not build geometry.
    /// `record_trails` false (a prewarm) leaves the trail clock and histories alone.
    void Advance(double dt, bool pause_emission = false, bool record_trails = true);
    /// One step of one instance. `time` is the particle-system time the step
    /// ends at.
    void AdvanceInstance(ParticleInstance& inst, double dt, double time, bool record_trail,
                         bool pause_emission = false, const ControlpointFrame* frame = nullptr);
    /// Steps a freshly spawned or recycled instance through its prewarm.
    void PrewarmInstance(ParticleInstance& inst, bool pause_emission = false);
    /// Starts every live particle's trail again from where it is.
    void RestartTrails(ParticleInstance& inst);
    void BindInstance(ParticleInstance& inst);
    void RefreshParentFrameMetadata();
    bool HasRawActivity() const;
    bool Paused() const;
    void StopTree();
    void RestartTree();
    void ClearPauseTree();
    void InvalidateMeshes();
    void UpdateControlpoints(ParticleInstance* instance = nullptr);
    /// Fills a mirror's mesh from the instances of the subsystem it draws.
    void GenerateFrom(const ParticleSubSystem& source);
    /// For a world-space system: moves the draw matrix of its nodes with the
    /// layer and re-expresses live particles after the layer moved, so they stay
    /// where they were in the scene.
    void KeepWorldPositions();
    /// The rotation and scale, and the origin, of the matrix the owner layer
    /// draws a world-space system's particles by, as of the last step.
    struct WorldFrame {
        linalg::Matrix3d linear { linalg::Matrix3d::Identity() };
        linalg::Vector3d origin { linalg::Vector3d::Zero() };
    };
    std::optional<WorldFrame> OwnerWorldFrame() const;
    linalg::Matrix4d SimulationTransform(const std::shared_ptr<SceneNode>& owner) const;

    ParticleSystem&            m_sys;
    std::shared_ptr<SceneMesh> m_mesh;
    std::weak_ptr<SceneNode>   m_owner_node;
    /// Set when `Emitt` wrote this frame's geometry. A draw that finds it
    /// clear rebuilds before uploading, without running the simulation again.
    bool m_mesh_rebuilt { true };
    bool m_script_paused { false };
    bool m_emitters_stopped { false };
    bool m_local_live { false };
    bool m_local_emitting { false };
    bool m_time_advancing { true };
    bool m_parent_frame_override { false };
    bool m_identity_parent_binding { true };
    std::vector<ParticleEmittOp> m_emiters;

    std::vector<ParticleInitOp>     m_initializers;
    std::vector<ParticleOperatorOp> m_operators;
    /// Bumped whenever an emitter or initializer is added, so an instance that
    /// copied the older set notices and copies again.
    u64                                    m_ops_version { 1 };
    std::shared_ptr<ParticleSpawnContext>  m_spawn_ctx { std::make_shared<ParticleSpawnContext>() };
    double                                 m_starttime { 0.0 };
    ControlpointSource                     m_cp_source;
    bool                                   m_needs_world_axes { false };
    bool                                   m_tracks_prev_position { false };
    bool                                   m_needs_layer_origin { false };
    bool                                   m_needs_time_of_day { false };
    bool                                   m_needs_scene_frame { false };
    bool                                   m_cp_commit { false };
    uint8_t                                m_owned_controlpoints { 0 };
    uint8_t                                m_trail_fade_flags { 0 };
    /// Steps taken, for `ParticleInfo::step`.
    uint32_t                               m_steps { 0 };
    bool                                   m_drawn { true };
    bool                                   m_world_space { false };
    bool                                   m_have_prev_model { false };
    linalg::Matrix4d                        m_prev_model { linalg::Matrix4d::Identity() };
    bool                                   m_cp_primed { false };
    bool                                   m_cp_per_instance { false };
    uint8_t                                m_controlpoint_count { 8 };
    uint8_t                                m_parent_point_start { 255 };
    uint32_t                               m_instance_generation { 0 };

    std::array<ParticleControlpoint, 8> m_controlpoints;

    ParticleRawGenSpecOp m_genSpecOp;
    ParticleOverflowFlags m_overflow_flags {};
    u32                  m_maxcount;
    double               m_rate;
    double               m_time;
    std::function<double()> m_rate_multiplier;

    u32                 m_rope_subdivision { 1 };
    float               m_rope_rate { 0.0f };
    float               m_rope_lifetime { 0.0f };
    float               m_uv_scale { 1.0f };
    bool                m_uv_scrolling { false };
    bool                m_uv_smoothing { false };
    ParticleTrailConfig m_trail {};
    double              m_trail_timer { 0.0 };

    /// The system this one is a child of, for the position of a particle it follows.
    const ParticleSubSystem*                        m_parent_system { nullptr };
    std::vector<std::unique_ptr<ParticleSubSystem>> m_children;
    std::vector<std::unique_ptr<ParticleSubSystem>> m_mirrors;
    std::vector<std::unique_ptr<ParticleInstance>>  m_instances;

    u32       m_maxcount_instance { 1 };
    double    m_probability { 1.0f };
    SpawnType m_spawn_type { SpawnType::STATIC };
};

class Scene;
class ParticleSystem : NoCopy, NoMove {
public:
    ParticleSystem(Scene& scene): scene(scene) {};
    ~ParticleSystem() = default;

    void Emitt();
    /// After visibility is final for the frame. A subsystem whose owner is
    /// now drawn and whose mesh was not rebuilt by `Emitt` is rebuilt here.
    void RebuildVisibleMeshes();

    /// Whether any emitter exists.
    ///
    /// Presence, not live particle count: an emitter with nothing alive this
    /// instant is still going to emit on the next tick, so counting particles
    /// would let a scene fall asleep between bursts.
    [[nodiscard]] bool HasEmitters() const { return ! subsystems.empty(); }
    [[nodiscard]] bool HasTimeAdvancingWork() const {
        return !subsystems.empty() && (!m_work_known || m_time_advancing);
    }
    void InvalidateTimeDemand() { m_work_known = false; }
    void RegisterLayer(std::string key, ParticleSubSystem* system,
                       std::shared_ptr<wpscene::ParticleInstanceoverride> instance);
    ParticleSubSystem* ForLayer(std::string_view key) const;
    std::shared_ptr<wpscene::ParticleInstanceoverride> InstanceForLayer(std::string_view key) const;
    ParticleInstanceUpdate* PendingInstanceForLayer(std::string_view key, bool create = false);
    void QueueInstanceUpdate(std::string_view key);
    void RemoveLayer(std::string_view key);

    Scene& scene;

    std::vector<std::unique_ptr<ParticleSubSystem>> subsystems;
    std::unique_ptr<IParticleRawGener>              gener;
private:
    struct Layer {
        ParticleSubSystem* system;
        std::shared_ptr<wpscene::ParticleInstanceoverride> instance;
        std::unique_ptr<ParticleInstanceUpdate> pending;
    };
    Map<std::string, Layer> m_layers;
    std::vector<Layer*> m_pending_updates;
    bool m_work_known { false };
    bool m_time_advancing { false };
};
} // namespace wallpaper
