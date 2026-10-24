// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "ParticleSystem.h"
#include "Interface/IParticleRawGener.h"
#include "Core/Literals.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "ParticleModify.h"
#include "Scene/SceneMesh.h"
#include "Utils/Random.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cassert>
#include <cmath>

using namespace wallpaper;

void ParticleInstance::Refresh() {
    m_is_death         = false;
    m_no_live_particle = false;
    m_bounded_data     = BoundedData {};
    m_particles.clear();
    m_trails.clear();
    // The copies are dropped with their version, so the next step binds fresh
    // ones: a recycled instance starts every schedule and sequence again.
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
    ParticleRenderScale scale;
    scale.rope_subdivision = m_rope_subdivision;
    scale.trail_fraction   = TrailPeriodFraction();
    scale.uv_scale         = m_uv_scale;
    scale.uv_scrolling     = m_uv_scrolling;
    // Smoothing eases the strip position that scrolling already owns.
    scale.uv_smoothing     = m_uv_smoothing && ! m_uv_scrolling;
    return scale;
}

namespace
{
using Vec3 = linalg::Vector3d;

/// Where the pointer is in the scene, in canvas units with y up: the
/// presentation's own answer when it has one, else the window position
/// stretched over the canvas.
Vec3 ScenePointer(const Scene& scene) {
    if (scene.pointerScenePosition.has_value()) {
        return { static_cast<double>((*scene.pointerScenePosition)[0]),
                 static_cast<double>((*scene.pointerScenePosition)[1]), 0.0 };
    }
    return { static_cast<double>(scene.pointerPosition[0]) * static_cast<double>(scene.ortho[0]),
             (1.0 - static_cast<double>(scene.pointerPosition[1])) *
                 static_cast<double>(scene.ortho[1]),
             0.0 };
}

/// A point carried through a 4x4 matrix as a position.
Vec3 TransformPoint(const linalg::Matrix4d& m, const Vec3& p) {
    const linalg::Vector4d out = m * linalg::Vector4d(p.x(), p.y(), p.z(), 1.0);
    return { out.x(), out.y(), out.z() };
}

Vec3 Origin(const linalg::Matrix4d& m) { return { m(0, 3), m(1, 3), m(2, 3) }; }

/// Control point numbers the engine treats as pinned: flag 2, never the first
/// point, never one that also follows the pointer.
bool IsPinned(const ParticleControlpoint& point, std::size_t index) {
    return point.worldspace && index != 0 && ! point.link_mouse;
}
} // namespace

void ParticleSubSystem::UpdateMouseControlpoints() {
    bool any = false;
    for (const auto& point : m_controlpoints) any = any || point.link_mouse;
    if (! any) return;

    Vec3 pointer = ScenePointer(m_sys.scene);
    if (const auto owner = m_owner_node.lock()) {
        owner->UpdateTrans();
        const linalg::Matrix4d model = owner->ModelTrans();
        if (m_world_space) {
            pointer -= Origin(model);
        } else {
            const linalg::Matrix4d inverse = model.inverse();
            if (inverse.allFinite()) pointer = TransformPoint(inverse, pointer);
        }
    }
    for (auto& point : m_controlpoints) {
        if (point.link_mouse) point.offset = point.base_offset + pointer;
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
    // One draw is spent on every event, whether or not it creates anything.
    const double chance = Random::get(0.0, 1.0);
    if (chance > m_probability) return nullptr;
    for (auto& inst : m_instances) {
        if (inst->IsDeath() && inst->IsNoLiveParticle()) {
            inst->Refresh();
            return inst.get();
        }
    }
    if (m_instances.size() < MaxInstanceCount()) {
        m_instances.push_back(std::make_unique<ParticleInstance>());
        return m_instances.back().get();
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
    const linalg::Matrix4d model = owner->ModelTrans();
    WorldFrame            frame;
    frame.linear = model.topLeftCorner<3, 3>();
    frame.origin = model.topRightCorner<3, 1>();
    return frame;
}

void ParticleSubSystem::UpdateControlpoints() {
    if (m_cp_source) m_cp_source(m_controlpoints);
    UpdateMouseControlpoints();

    const auto owner = m_owner_node.lock();
    if (owner) owner->UpdateTrans();
    const linalg::Matrix4d model    = owner ? owner->ModelTrans() : linalg::Matrix4d::Identity();
    const bool             in_world = m_world_space && owner != nullptr;
    linalg::Matrix4d       inverse  = linalg::Matrix4d::Identity();
    bool                   have_inverse = false;
    if (owner && ! m_world_space) {
        inverse      = model.inverse();
        have_inverse = inverse.allFinite();
    }
    const linalg::Matrix3d linear = model.topLeftCorner<3, 3>();

    for (std::size_t i = 0; i < m_controlpoints.size(); ++i) {
        auto& point  = m_controlpoints[i];
        const bool pinned = IsPinned(point, i);
        if (in_world) {
            // Particles live in scene units around the layer's origin: a point
            // is the layer's matrix applied to its offset, a pinned one is the
            // scene position measured from the origin and carries no matrix.
            if (pinned) {
                point.offset           = point.base_offset - Origin(model);
                point.has_world_linear = false;
                point.world_linear     = linalg::Matrix3d::Identity();
            } else {
                if (! point.link_mouse) point.offset = linear * point.base_offset;
                point.has_world_linear = true;
                point.world_linear     = linear;
            }
        } else {
            point.has_world_linear = false;
            point.world_linear     = linalg::Matrix3d::Identity();
            if (pinned && have_inverse) point.offset = TransformPoint(inverse, point.base_offset);
        }
    }

    if (! m_cp_primed) {
        for (auto& point : m_controlpoints) point.prev_offset = point.offset;
        m_cp_primed = true;
    }
}

void ParticleSubSystem::KeepWorldPositions() {
    if (! m_world_space) return;
    const auto frame = OwnerWorldFrame();
    if (! frame) return;

    // The nodes that draw this system go through the layer's origin alone; a
    // shift the node carries for its screen anchor stays.
    const auto draw_from_origin = [](const std::shared_ptr<SceneNode>& node) {
        if (! node) return;
        node->UpdateTrans();
        linalg::Matrix4d transform = linalg::Matrix4d::Identity();
        const Vec3 where = Origin(node->ModelTrans()) + node->DrawOffset().cast<double>();
        transform(0, 3) = where.x();
        transform(1, 3) = where.y();
        transform(2, 3) = where.z();
        node->SetRenderTransformOverride(transform);
    };
    draw_from_origin(m_owner_node.lock());
    for (auto& mirror : m_mirrors) draw_from_origin(mirror->m_owner_node.lock());

    const linalg::Matrix4d model = [&] {
        linalg::Matrix4d m = linalg::Matrix4d::Identity();
        m.topLeftCorner<3, 3>() = frame->linear;
        m(0, 3) = frame->origin.x();
        m(1, 3) = frame->origin.y();
        m(2, 3) = frame->origin.z();
        return m;
    }();

    if (m_have_prev_model) {
        // A move of the layer's origin leaves the particles where they are in
        // the scene, so what is stored (measured from the origin) shifts back.
        const Vec3 moved = frame->origin - Origin(m_prev_model);
        if (moved.x() != 0.0 || moved.y() != 0.0 || moved.z() != 0.0) {
            linalg::Matrix4d shift = linalg::Matrix4d::Identity();
            shift(0, 3) = -moved.x();
            shift(1, 3) = -moved.y();
            shift(2, 3) = -moved.z();
            for (auto& inst : m_instances) {
                for (auto& p : inst->ParticlesVec()) {
                    if (! ParticleModify::LifetimeOk(p)) continue;
                    ParticleModify::Move(p, -moved);
                    p.prev_position = (p.prev_position.cast<double>() - moved).cast<float>();
                }
                for (auto& trail : inst->TrailsVec()) trail.Transform(shift);
            }
        }
    }
    m_prev_model      = model;
    m_have_prev_model = true;
}

namespace
{

/// Moves a recording clock on by `dt` and reports whether it came due. A due
/// clock wraps to the remainder of the period; a clock whose configuration
/// records nothing stays still.
bool TickRecordingClock(const ParticleTrailConfig& config, double& clock, double dt) {
    if (! config.enabled()) return false;
    clock += dt;
    if (clock < config.period) return false;
    clock = std::fmod(clock, config.period);
    return true;
}

} // namespace

void ParticleSubSystem::Advance(double dt) {
    KeepWorldPositions();   // a move of the layer since the last step

    m_time += dt;
    const bool recording = TickRecordingClock(m_trail, m_trail_timer, dt);

    UpdateControlpoints();

    // A static system always owns one instance to run.
    if (m_spawn_type == SpawnType::STATIC && m_instances.empty())
        m_instances.emplace_back(std::make_unique<ParticleInstance>());

    // Events create instances in the children only, but the count is read each
    // round so a growing list is never stepped past its end.
    for (std::size_t next = 0; next != m_instances.size(); ++next)
        AdvanceInstance(*m_instances[next], dt, m_time, recording);

    for (auto& point : m_controlpoints) point.prev_offset = point.offset;
}

void ParticleSubSystem::AdvanceInstance(ParticleInstance& inst, double dt, double time,
                                        bool record_trail) {
    auto&       slots = inst.ParticlesVec();
    auto&       bound = inst.GetBoundedData();
    const bool  event_child = m_spawn_type != SpawnType::STATIC;

    // 1. An instance bound to a parent particle takes its place and its state.
    bool first_death_step = false;
    if (bound.parent != nullptr) {
        const auto parent_slots = bound.parent->Particles();
        const bool in_range =
            bound.particle_idx >= 0 &&
            static_cast<std::size_t>(bound.particle_idx) < parent_slots.size();
        if (in_range) {
            const Particle& parent_particle = parent_slots[static_cast<std::size_t>(bound.particle_idx)];
            Vec3 place = parent_particle.position.cast<double>();
            if (m_parent_system != nullptr && m_parent_system->m_world_space) {
                // Scene units from the parent layer's origin, taken back into
                // the layer's own space where the child is drawn.
                if (const auto frame = m_parent_system->OwnerWorldFrame()) {
                    const linalg::Matrix3d back = frame->linear.inverse();
                    if (back.allFinite()) place = back * place;
                }
            }
            place += bound.parent->GetBoundedData().pos.cast<double>();
            bound.pos = place.cast<float>();
            bound.pre_lifetime_ok = ParticleModify::LifetimeOk(parent_particle);
            if (m_spawn_type == SpawnType::EVENT_FOLLOW || m_spawn_type == SpawnType::EVENT_SPAWN) {
                if (! bound.pre_lifetime_ok || bound.parent->IsDeath()) {
                    inst.SetDeath(true);
                    // A follower lets go at once; a spawner keeps reading the slot.
                    if (m_spawn_type == SpawnType::EVENT_FOLLOW) {
                        bound.parent       = nullptr;
                        bound.particle_idx = -1;
                    }
                }
            }
        }
        first_death_step = m_spawn_type == SpawnType::EVENT_DEATH;
    }

    // 2. Emission, from the emitters and initializers this instance owns.
    if (! inst.IsDeath()) {
        BindInstance(inst);
        m_spawn_ctx->controlpoints = m_controlpoints;
        m_spawn_ctx->system_time   = time;
        m_spawn_ctx->frame_time    = dt;
        m_spawn_ctx->parent        = nullptr;
        if (bound.parent != nullptr && bound.particle_idx >= 0) {
            const auto parent_slots = bound.parent->Particles();
            if (static_cast<std::size_t>(bound.particle_idx) < parent_slots.size())
                m_spawn_ctx->parent = &parent_slots[static_cast<std::size_t>(bound.particle_idx)];
        }
        const u32 capacity = std::min<u32>(m_maxcount, 20000u);
        for (auto& emitter : inst.Emitters()) {
            emitter(slots, inst.Initializers(), capacity, dt, m_controlpoints);
        }
        m_spawn_ctx->parent = nullptr;
    }
    if (first_death_step) {
        inst.SetDeath(true);
        bound.parent       = nullptr;
        bound.particle_idx = -1;
    }
    (void)event_child;

    // 3. One pass over the slots: births, restore, ageing, deaths. An event
    // child gets an instance bound to the slot, pre-simulated at once, while
    // the particle still shows its birth values.
    const auto fire = [&](bool death, std::size_t slot) {
        for (auto& child : m_children) {
            const bool on_death = child->m_spawn_type == SpawnType::EVENT_DEATH;
            if (child->m_spawn_type == SpawnType::STATIC || on_death != death) continue;
            ParticleInstance* made = child->QueryNewInstance();
            if (made == nullptr) continue;
            auto& data            = made->GetBoundedData();
            data.parent           = &inst;
            data.particle_idx     = static_cast<isize>(slot);
            data.pre_lifetime_ok  = true;
            child->BindInstance(*made);
            child->PrewarmInstance(*made);
        }
    };
    const bool keeps_trails = m_trail.enabled();
    if (keeps_trails && inst.Trails().size() < slots.size()) inst.TrailsVec().resize(slots.size());
    bool any_alive = false;
    for (std::size_t i = 0; i < slots.size(); ++i) {
        Particle& p = slots[i];
        if (ParticleModify::IsNew(p)) {
            if (keeps_trails) {
                auto& trail = inst.TrailsVec()[i];
                trail.Reset(m_trail.samples);
                trail.Push({ p.position + bound.pos });
            }
            fire(false, i);
            ParticleModify::MarkOld(p);
        }
        // Colour, alpha and size start every step from their birth values;
        // that includes a dead slot, which the ramp operators still visit.
        ParticleModify::Reset(p);
        if (! ParticleModify::LifetimeOk(p)) continue;
        ParticleModify::ChangeLifetime(p, -dt);
        if (ParticleModify::LifetimeOk(p)) {
            any_alive = true;
        } else {
            fire(true, i);
        }
    }
    inst.SetNoLiveParticle(! any_alive);

    // 4. The operators, in file order, over this step's particles.
    ParticleInfo info {
        .particles     = slots,
        .controlpoints = m_controlpoints,
        .time          = time,
        .time_pass     = dt,
    };
    info.track_previous_position = m_tracks_prev_position;
    if (m_needs_world_axes && ! m_world_space) {
        if (const auto frame = OwnerWorldFrame()) info.world_to_local = frame->linear.transpose();
    }
    for (auto& op : m_operators) op(info);

    // 5. Trail points, after the operators have moved the particles.
    if (keeps_trails && record_trail) {
        auto& trails = inst.TrailsVec();
        for (std::size_t i = 0; i < slots.size() && i < trails.size(); ++i) {
            if (ParticleModify::LifetimeOk(slots[i])) trails[i].Push({ slots[i].position + bound.pos });
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
    double multiplier = 1.0;
    if (m_rate_multiplier) {
        const double asked = m_rate_multiplier();
        multiplier         = std::isfinite(asked) ? std::max(0.0, asked) : 0.0;
    }
    double dt = m_sys.scene.frameTime * m_rate * multiplier;
    if (! std::isfinite(dt) || dt < 0.0) dt = 0.0;
    Advance(dt);

    if (m_drawn && m_mesh != nullptr) {
        m_mesh->SetDirty();
        // The rope trail's shader eases the oldest piece by this fraction.
        if (m_trail.enabled() && m_mesh->Material() != nullptr) {
            auto& values = m_mesh->Material()->customShader.constValues;
            auto  found  = values.find("g_RenderVar0");
            if (found != values.end() && found->second.size() >= 4) {
                found->second[2] = TrailPeriodFraction();
            }
        }
        const auto owner = m_owner_node.lock();
        if (m_sys.gener != nullptr && (! owner || owner->EffectiveVisible() || owner->MustProduce())) {
            m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
            m_mesh_rebuilt = true;
        } else {
            m_mesh_rebuilt = false;
        }
        for (auto& mirror : m_mirrors) mirror->GenerateFrom(*this);
    }
    for (auto& child : m_children) child->Emitt();
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
    for (auto& el : subsystems) el->Emitt();
}

void ParticleSystem::RebuildVisibleMeshes() {
    for (auto& el : subsystems) {
        el->RebuildMesh();
    }
}
