#include "ParticleSystem.h"
#include "Interface/IParticleRawGener.h"
#include "Core/Literals.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "ParticleModify.h"
#include "Scene/SceneMesh.h"
#include "Core/Random.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cmath>

using namespace wallpaper;

void ParticleInstance::Refresh() {
    SetDeath(false);
    SetNoLiveParticle(false);
    GetBoundedData() = {};
    ParticlesVec().clear();
    TrailsVec().clear();
    // A recycled instance starts every emitter's schedule again.
    m_emitters.clear();
    m_initializers.clear();
    m_bound_version = 0;
}

bool ParticleInstance::IsDeath() const { return m_is_death; }
void ParticleInstance::SetDeath(bool v) { m_is_death = v; };

bool ParticleInstance::IsNoLiveParticle() const { return m_no_live_particle; };
void ParticleInstance::SetNoLiveParticle(bool v) { m_no_live_particle = v; };

std::span<const Particle> ParticleInstance::Particles() const { return m_particles; };
std::vector<Particle>&    ParticleInstance::ParticlesVec() { return m_particles; };

std::span<const ParticleTrailHistory> ParticleInstance::Trails() const { return m_trails; };
std::vector<ParticleTrailHistory>&    ParticleInstance::TrailsVec() { return m_trails; };

ParticleInstance::BoundedData& ParticleInstance::GetBoundedData() { return m_bounded_data; }

ParticleSubSystem::ParticleSubSystem(ParticleSystem& p, std::shared_ptr<SceneMesh> sm,
                                     uint32_t maxcount, double rate, u32 maxcount_instance,
                                     double probability, SpawnType type,
                                     ParticleRawGenSpecOp specOp)
    : m_sys(p),
      m_mesh(sm),
      m_maxcount(maxcount),
      m_rate(rate),
      m_genSpecOp(specOp),
      m_time(0),
      m_maxcount_instance(maxcount_instance),
      m_probability(probability),
      m_spawn_type(type) {};

ParticleSubSystem::~ParticleSubSystem() = default;

void ParticleSubSystem::AddEmitter(ParticleEmittOp&& em) {
    m_emiters.emplace_back(std::move(em));
    ++m_ops_version;
}

void ParticleSubSystem::AddInitializer(ParticleInitOp&& ini) {
    m_initializers.emplace_back(std::move(ini));
    ++m_ops_version;
}

void ParticleSubSystem::AddOperator(ParticleOperatorOp&& op) { m_operators.emplace_back(op); }

std::span<const ParticleControlpoint> ParticleSubSystem::Controlpoints() const {
    return m_controlpoints;
}
std::span<ParticleControlpoint> ParticleSubSystem::Controlpoints() { return m_controlpoints; };

void ParticleSubSystem::SetOwnerNode(std::weak_ptr<SceneNode> node) {
    m_owner_node = std::move(node);
}

void ParticleSubSystem::SetRateMultiplier(std::function<double()> rate_multiplier) {
    m_rate_multiplier = std::move(rate_multiplier);
}

void ParticleSubSystem::SetRopeSubdivision(u32 subdivision) {
    m_rope_subdivision = std::max<u32>(1, subdivision);
}

void ParticleSubSystem::SetRopeUv(float scale, bool scrolling, bool smoothing) {
    m_uv_scale     = RopeUvScaleOrOne(scale);
    m_uv_scrolling = scrolling;
    m_uv_smoothing = smoothing;
    if (m_trail.enabled() && m_mesh != nullptr && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4) {
            it->second[3] = EncodeRopeTrailLength(
                static_cast<float>(m_trail.samples) * static_cast<float>(m_rope_subdivision),
                m_uv_scale);
        }
    }
    if (m_mesh != nullptr) m_mesh->SetDirty();
}

void ParticleSubSystem::SetTrail(ParticleTrailConfig config) {
    m_trail       = config;
    m_trail_timer = 0.0;
}

float ParticleSubSystem::TrailPeriodFraction() const {
    if (! m_trail.enabled()) return 0;
    return static_cast<float>(std::clamp(m_trail_timer / m_trail.period, 0.0, 1.0));
}

ParticleSubSystem::SpawnType ParticleSubSystem::Type() const { return m_spawn_type; }

u32 ParticleSubSystem::MaxInstanceCount() const { return m_maxcount_instance; };

ParticleRenderScale ParticleSubSystem::RenderScale() const {
    // The size goes out as authored: the layer's model matrix scales the
    // billboard, so a particle layer scaled up draws its sprites larger, in a
    // 2D canvas as in 3D, as Wallpaper Engine's particle shader does.
    return {
        .rope_subdivision = m_rope_subdivision,
        .trail_fraction   = TrailPeriodFraction(),
        .uv_scale         = m_uv_scale,
        .uv_scrolling     = m_uv_scrolling,
        .uv_smoothing     = m_uv_smoothing && ! m_uv_scrolling,
    };
}

void ParticleSubSystem::UpdateMouseControlpoints() {
    if (std::none_of(m_controlpoints.begin(), m_controlpoints.end(),
                     [](const auto& cp) { return cp.link_mouse; })) {
        return;
    }
    // The presentation's own answer when there is one. Stretching the
    // window-normalized pointer across the whole canvas is only right when the
    // window shows the whole canvas: a cropped wallpaper agrees at the centre
    // and is wrong by half the cropped-away span at either edge.
    const auto& scene_pointer = m_sys.scene.pointerScenePosition;
    const auto  pointer       = m_sys.scene.pointerPosition;
    const Eigen::Vector3d mouse_world {
        scene_pointer.has_value()
            ? static_cast<double>((*scene_pointer)[0])
            : static_cast<double>(pointer[0]) * static_cast<double>(m_sys.scene.ortho[0]),
        scene_pointer.has_value()
            ? static_cast<double>((*scene_pointer)[1])
            : (1.0 - static_cast<double>(pointer[1])) * static_cast<double>(m_sys.scene.ortho[1]),
        0.0,
    };
    Eigen::Vector3d mouse_local = mouse_world;
    if (const auto world = m_world_space ? OwnerWorldFrame() : std::nullopt) {
        // A world-space system measures from its layer's origin along the
        // scene's own axes.
        mouse_local = mouse_world - world->origin;
    } else if (auto owner = m_owner_node.lock()) {
        owner->UpdateTrans();
        const Eigen::Vector4d local =
            owner->ModelTrans().inverse() * Eigen::Vector4d(mouse_world.x(), mouse_world.y(), 0.0, 1.0);
        mouse_local = local.head<3>();
    }
    for (auto& cp : m_controlpoints) {
        if (cp.link_mouse) cp.offset = cp.base_offset + mouse_local;
    }
}

void ParticleSubSystem::AddChild(std::unique_ptr<ParticleSubSystem>&& child) {
    child->m_parent_system = this;
    m_children.emplace_back(std::move(child));
}

void ParticleSubSystem::AddMirror(std::unique_ptr<ParticleSubSystem>&& mirror) {
    m_mirrors.emplace_back(std::move(mirror));
}

void ParticleSubSystem::GenerateFrom(const ParticleSubSystem& source) {
    if (! m_drawn) return;
    m_mesh->SetDirty();
    const auto owner = m_owner_node.lock();
    if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
        m_sys.gener->GenGLData(
            source.m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
        m_mesh_rebuilt = true;
    } else {
        m_mesh_rebuilt = false;
    }
}

ParticleInstance* ParticleSubSystem::QueryNewInstance() {
    if (Random::get(0.0, 1.0) <= m_probability) {
        for (auto& inst : m_instances) {
            if (inst->IsDeath() && inst->IsNoLiveParticle()) {
                inst->Refresh();
                return inst.get();
            }
        }
        if (m_instances.size() < m_maxcount_instance) {
            m_instances.emplace_back(std::make_unique<ParticleInstance>());
            return m_instances.back().get();
        }
    }
    return nullptr;
}

void ParticleSubSystem::BindInstance(ParticleInstance& inst) {
    if (inst.BoundVersion() == m_ops_version) return;
    inst.Emitters()    = m_emiters;
    inst.Initializers() = m_initializers;
    inst.SetBoundVersion(m_ops_version);
}

std::optional<ParticleSubSystem::WorldFrame> ParticleSubSystem::OwnerWorldFrame() const {
    const auto owner = m_owner_node.lock();
    if (! owner) return std::nullopt;
    owner->UpdateTrans();
    const Eigen::Matrix4d model = owner->ModelTrans();
    WorldFrame            frame;
    frame.linear = model.topLeftCorner<3, 3>();
    frame.origin = model.topRightCorner<3, 1>();
    return frame;
}

void ParticleSubSystem::UpdateControlpoints() {
    if (m_cp_source) m_cp_source(m_controlpoints);
    UpdateMouseControlpoints();

    // A world-space system's control points are where its layer's matrix puts
    // them, measured from the layer's origin: the authored offset turned and
    // scaled by the layer. A control point pinned to the world (flag 2, never
    // the first) is a place in the scene whose matrix Wallpaper Engine leaves as
    // authored, without the layer's: its offset is that place less the layer's
    // origin, and an emitter on it is neither spread nor launched by the layer's
    // scale. The system and its emitters both read them in this frame.
    const auto world = m_world_space ? OwnerWorldFrame() : std::nullopt;
    if (world) {
        for (usize i = 0; i < m_controlpoints.size(); ++i) {
            auto&      cp     = m_controlpoints[i];
            const bool pinned = cp.worldspace && ! cp.link_mouse && i != 0;
            cp.has_world_linear = ! pinned;
            cp.world_linear     = pinned ? Eigen::Matrix3d(Eigen::Matrix3d::Identity()) : world->linear;
            if (cp.link_mouse) continue;
            cp.offset = pinned ? Eigen::Vector3d(cp.base_offset - world->origin)
                               : Eigen::Vector3d(world->linear * cp.base_offset);
        }
    } else {
        // A control point pinned to the world (flag 2, never the first) holds
        // its authored position in scene coordinates; the simulation lives in
        // the layer's local space, so it is carried back through the layer's
        // matrix as the layer moves. Every other control point keeps the offset
        // it was given.
        std::shared_ptr<SceneNode> owner;
        for (usize i = 1; i < m_controlpoints.size(); ++i) {
            auto& cp = m_controlpoints[i];
            if (cp.link_mouse || ! cp.worldspace) continue;
            if (! owner) {
                owner = m_owner_node.lock();
                if (owner) owner->UpdateTrans();
            }
            if (! owner) continue;
            const Eigen::Vector4d local =
                owner->ModelTrans().inverse() *
                Eigen::Vector4d(cp.base_offset.x(), cp.base_offset.y(), cp.base_offset.z(), 1.0);
            cp.offset = local.head<3>();
        }
    }

    if (! m_cp_primed) {
        // The first step has no earlier position: a control point that has
        // not moved yet must not read as having jumped.
        for (auto& cp : m_controlpoints) cp.prev_offset = cp.offset;
        m_cp_primed = true;
    }
}

void ParticleSubSystem::KeepWorldPositions() {
    if (! m_world_space) return;
    const auto owner = m_owner_node.lock();
    const auto world = OwnerWorldFrame();
    if (! owner || ! world) return;
    // The matrix the system is drawn by is the layer's origin and nothing else:
    // the particles are already in scene units. Every node that draws one of its
    // renderers takes it; a node under the layer keeps its own place.
    Eigen::Matrix4d draw = Eigen::Matrix4d::Identity();
    draw.topRightCorner<3, 1>() = world->origin;
    const auto place = [&draw](SceneNode& node) {
        // A shift a screen anchor adds to where the node is drawn goes with it.
        Eigen::Matrix4d placed = draw;
        placed.topRightCorner<3, 1>() += node.DrawOffset().cast<double>();
        if (! node.HasRenderTransformOverride() ||
            ! (node.RenderTrans().array() == placed.array()).all()) {
            node.SetRenderTransformOverride(placed);
        }
    };
    place(*owner);
    for (auto& mirror : m_mirrors) {
        if (const auto node = mirror->m_owner_node.lock()) place(*node);
    }
    if (m_have_prev_model && ! draw.isApprox(m_prev_model, 1.0e-12)) {
        // Where the layer was, relative to where it is: what a point kept at one
        // place in the scene has to be called now. Only the move counts; a turn
        // or a rescale of the layer is not a move of the scene.
        const Eigen::Vector3f shift = (m_prev_model.topRightCorner<3, 1>() - world->origin).cast<float>();
        Eigen::Matrix4d       delta = Eigen::Matrix4d::Identity();
        delta.topRightCorner<3, 1>() = shift.cast<double>();
        for (auto& inst : m_instances) {
            for (auto& p : inst->ParticlesVec()) {
                if (! ParticleModify::LifetimeOk(p)) continue;
                p.position += shift;
            }
            for (auto& trail : inst->TrailsVec()) trail.Transform(delta);
        }
    }
    m_prev_model      = draw;
    m_have_prev_model = true;
}

void ParticleSubSystem::Advance(double dt) {
    KeepWorldPositions();
    m_time += dt;
    bool record_trail = false;
    if (m_trail.enabled()) {
        m_trail_timer += dt;
        if (m_trail_timer >= m_trail.period) {
            record_trail  = true;
            m_trail_timer = std::fmod(m_trail_timer, m_trail.period);
        }
    }
    UpdateControlpoints();

    if (m_spawn_type == SpawnType::STATIC) {
        if (m_instances.empty()) m_instances.emplace_back(std::make_unique<ParticleInstance>());
    }

    for (auto& inst : m_instances) {
        assert(inst);
        AdvanceInstance(*inst, dt, m_time, record_trail);
    }
    for (auto& cp : m_controlpoints) cp.prev_offset = cp.offset;
}

void ParticleSubSystem::AdvanceInstance(ParticleInstance& inst, double dt, double time,
                                        bool record_trail) {
    BindInstance(inst);

    auto spawn_inst = [](ParticleInstance& parent, ParticleSubSystem& child, isize idx) {
        ParticleInstance* n_inst = child.QueryNewInstance();
        if (n_inst != nullptr) {
            n_inst->GetBoundedData() = {
                .parent       = &parent,
                .particle_idx = idx,
            };
            child.PrewarmInstance(*n_inst);
        }
    };

    auto& bounded_data = inst.GetBoundedData();

    bool type_has_death =
        m_spawn_type == SpawnType::EVENT_SPAWN || m_spawn_type == SpawnType::EVENT_FOLLOW;

    const Particle* parent_particle = nullptr;
    // bouded data and death
    if (bounded_data.parent != nullptr) {
        std::span particles = bounded_data.parent->Particles();
        if (bounded_data.particle_idx != -1 &&
            static_cast<usize>(bounded_data.particle_idx) < particles.size()) {
            auto& p          = particles[bounded_data.particle_idx];
            parent_particle  = &p;
            bounded_data.pos = ParticleModify::GetPos(p);
            // A world-space parent's particles are scene units from its layer's
            // origin; this system lives in the layer's own space, drawn through
            // its matrix, and is hung where that matrix puts the same place.
            if (m_parent_system != nullptr && m_parent_system->m_world_space) {
                if (const auto frame = m_parent_system->OwnerWorldFrame();
                    frame && std::abs(frame->linear.determinant()) > 1.0e-18) {
                    bounded_data.pos =
                        (frame->linear.inverse() * bounded_data.pos.cast<double>()).cast<float>();
                }
            }
            // only update pos once when event_death
            if (m_spawn_type == SpawnType::EVENT_DEATH) bounded_data.particle_idx = -1;

            // death if bounded particle death
            if (! inst.IsDeath() && type_has_death) {
                bool cur_life_ok = ParticleModify::LifetimeOk(p);
                inst.SetDeath(! cur_life_ok && bounded_data.pre_lifetime_ok);
                bounded_data.pre_lifetime_ok = cur_life_ok;
                // A follower whose particle ended stays where that particle
                // was: it keeps its own particles alive but stops following,
                // so a later particle reusing the slot cannot drag it away.
                if (inst.IsDeath() && m_spawn_type == SpawnType::EVENT_FOLLOW) {
                    bounded_data.particle_idx = -1;
                }
            }
        }

        // death if parent death
        if (! inst.IsDeath() && type_has_death) {
            inst.SetDeath(bounded_data.parent->IsDeath());
        }
    }

    // A dead follower keeps the particles it already emitted: only its
    // emitters stop, the rest live out their lifetime.

    if (! inst.IsDeath()) {
        m_spawn_ctx->controlpoints = m_controlpoints;
        m_spawn_ctx->system_time   = time;
        m_spawn_ctx->frame_time    = dt;
        m_spawn_ctx->parent        = parent_particle;
        for (auto& emittOp : inst.Emitters()) {
            emittOp(inst.ParticlesVec(), inst.Initializers(), m_maxcount, dt, m_controlpoints);
        }
        m_spawn_ctx->parent = nullptr;
    }

    auto& trails = inst.TrailsVec();
    if (m_trail.enabled()) {
        if (trails.size() < inst.ParticlesVec().size()) trails.resize(inst.ParticlesVec().size());
    }

    // event_death is always death after emitop
    if (m_spawn_type == SpawnType::EVENT_DEATH) inst.SetDeath(true);

    ParticleInfo info {
        .particles     = inst.ParticlesVec(),
        .controlpoints = m_controlpoints,
        .time          = time,
        .time_pass     = dt,
    };
    info.track_previous_position = m_tracks_prev_position;
    // A world-space system is already in the scene's own axes: gravity needs no
    // turning.
    if (m_needs_world_axes && ! m_world_space) {
        if (auto owner = m_owner_node.lock()) {
            owner->UpdateTrans();
            // The layer's 3x3 as it stands, scale included: Wallpaper Engine
            // takes the transposed matrix without normalising it.
            info.world_to_local = owner->ModelTrans().block<3, 3>(0, 0).transpose();
        }
    }

    bool  has_live = false;
    isize i        = -1;
    for (auto& p : info.particles) {
        i++;

        if (ParticleModify::IsNew(p)) {
            // new spawn
            for (auto& child : m_children) {
                if (child->Type() == SpawnType::EVENT_FOLLOW ||
                    child->Type() == SpawnType::EVENT_SPAWN)
                    spawn_inst(inst, *child, i);
            }
            if (m_trail.enabled() && static_cast<std::size_t>(i) < trails.size()) {
                trails[i].Reset(m_trail.samples);
                trails[i].Push({ bounded_data.pos + p.position });
            }
        }

        ParticleModify::MarkOld(p);
        if (! ParticleModify::LifetimeOk(p)) {
            continue;
        }
        ParticleModify::Reset(p);
        ParticleModify::ChangeLifetime(p, -dt);

        if (! ParticleModify::LifetimeOk(p)) {
            // new dead
            for (auto& child : m_children) {
                if (child->Type() == SpawnType::EVENT_DEATH) spawn_inst(inst, *child, i);
            }
        } else {
            has_live = true;
        }
    }

    inst.SetNoLiveParticle(! has_live);

    std::for_each(m_operators.begin(), m_operators.end(), [&info](ParticleOperatorOp& op) {
        op(info);
    });

    // Nothing advances a particle after the operators: its position and angle
    // change only inside the movement and angular movement operators (and the
    // few operators that place it directly), in the order they stand. A file
    // without a movement operator keeps its particles where they are.

    if (record_trail) {
        isize slot = -1;
        for (auto& p : info.particles) {
            slot++;
            if (! ParticleModify::LifetimeOk(p)) continue;
            if (static_cast<std::size_t>(slot) < trails.size()) {
                trails[slot].Push({ bounded_data.pos + p.position });
            }
        }
    }
}

namespace
{
/// Wallpaper Engine's prewarm step: 0.05 s, or 0.2 s once a particle file
/// holds 500 or more particles.
constexpr double PrewarmStepSeconds(u32 maxcount) { return maxcount < 500 ? 0.05 : 0.2; }
/// Upper bound on the steps one prewarm simulates. A start time of hours would
/// otherwise cost minutes at load; a system that emits without end is in the
/// same state after the bound as after the full run, so the remaining time is
/// only added to the system clock.
constexpr int kMaxPrewarmSteps = 6000;
} // namespace

void ParticleSubSystem::PrewarmInstance(ParticleInstance& inst) {
    if (m_starttime <= 0.0) return;
    const double dt    = PrewarmStepSeconds(m_maxcount);
    double       timer = 0.0;
    double       trail_timer = 0.0;
    double       elapsed     = 0.0;
    int          steps       = 0;
    do {
        bool record_trail = false;
        if (m_trail.enabled()) {
            trail_timer += dt;
            if (trail_timer >= m_trail.period) {
                record_trail = true;
                trail_timer  = std::fmod(trail_timer, m_trail.period);
            }
        }
        AdvanceInstance(inst, dt, m_time + elapsed + dt, record_trail);
        elapsed += dt;
        timer += dt;
        ++steps;
    } while (timer < m_starttime && steps < kMaxPrewarmSteps);
}

void ParticleSubSystem::Prewarm() {
    if (m_spawn_type != SpawnType::STATIC || m_starttime <= 0.0) return;
    const double dt = PrewarmStepSeconds(m_maxcount);
    // WE runs `t = 0; do { step; t += dt } while (t < starttime)`.
    const double wanted_steps = std::max(1.0, std::ceil(m_starttime / dt));
    const int    steps = static_cast<int>(std::min<double>(wanted_steps, kMaxPrewarmSteps));
    const double skipped = (wanted_steps - steps) * dt;

    std::function<void(ParticleSubSystem&)> add_time = [&](ParticleSubSystem& sys) {
        sys.m_time += skipped;
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) add_time(*child);
        }
    };
    std::function<void(ParticleSubSystem&)> step = [&](ParticleSubSystem& sys) {
        sys.Advance(dt);
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) step(*child);
        }
    };
    for (int i = 0; i < steps; ++i) step(*this);
    if (skipped > 0.0) add_time(*this);
    // A script or a timeline can still place the layer after the parse: the
    // first frame sets the matrix the particles are kept against, so the
    // prewarmed ones are not carried away from it.
    m_have_prev_model = false;
    // The mesh is built by the first frame that draws it.
    m_mesh_rebuilt = false;
}

void ParticleSubSystem::Emitt() {
    double frameTime    = m_sys.scene.frameTime;
    const double rate_multiplier =
        m_rate_multiplier ? std::max(0.0, m_rate_multiplier()) : 1.0;
    double particleTime = frameTime * m_rate * rate_multiplier;
    Advance(particleTime);

    // A system without a renderer simulates and builds nothing.
    if (! m_drawn) {
        for (auto& child : m_children) child->Emitt();
        return;
    }

    m_mesh->SetDirty();

    // Geometry is only read by a pass that draws this owner. A hidden layer
    // keeps the simulation above — birth, death, operators, trail history —
    // and rebuilds the mesh from that state on the first frame it is shown.
    // An owner that must produce (a layer something else samples) still
    // generates, and a missing owner does too: there is nothing to prove it
    // hidden.
    const auto owner = m_owner_node.lock();
    if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
        m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
        m_mesh_rebuilt = true;
    } else {
        // Visibility is not final here. Tick, which runs after Emitt, can show
        // this owner before the frame draws; the draw rebuilds from the
        // simulation this call just advanced.
        m_mesh_rebuilt = false;
    }

    if (m_trail.enabled() && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4) {
            it->second[2] = TrailPeriodFraction();
        }
    }

    for (auto& mirror : m_mirrors) mirror->GenerateFrom(*this);

    for (auto& child : m_children) {
        child->Emitt();
    }
}

void ParticleSubSystem::RebuildMesh() {
    if (m_drawn && ! m_mesh_rebuilt && m_sys.gener != nullptr && m_mesh != nullptr) {
        const auto owner = m_owner_node.lock();
        // Still hidden, and nothing samples it: the mesh is not read this
        // frame. A missing owner is rebuilt, matching Emitt.
        if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
            m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
            m_mesh_rebuilt = true;
        }
    }
    // A mirror reads this subsystem's instances; the mesh it skipped while
    // hidden is rebuilt from what the simulation holds now.
    for (auto& mirror : m_mirrors) {
        if (! mirror->m_mesh_rebuilt) mirror->GenerateFrom(*this);
    }
    for (auto& child : m_children) child->RebuildMesh();
}

void ParticleSystem::Emitt() {
    for (auto& el : subsystems) {
        el->Emitt();
    }
}

void ParticleSystem::RebuildVisibleMeshes() {
    for (auto& el : subsystems) {
        el->RebuildMesh();
    }
}
