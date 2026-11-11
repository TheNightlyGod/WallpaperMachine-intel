// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "ParticleSystem.h"
#include "Interface/IParticleRawGener.h"
#include "Core/Literals.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "ParticleModify.h"
#include "Scene/SceneMesh.h"
#include "Scene/SpecTexs.hpp"
#include "Utils/Random.hpp"
#include "Utils/TimeOfDay.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
using namespace wallpaper;

double wallpaper::ParticleForceStepScale(uint32_t target_fps) {
    if (target_fps == 0) return 1.0;
    // 0.025 / X with X the frame interval 1 / fps, held at 1 or less.
    const double x = std::min(0.025 * static_cast<double>(target_fps), 1.0);
    return std::pow(x, 0.7);
}

bool wallpaper::ParticleRunsHalfSteps(uint32_t target_fps) {
    return target_fps >= 1 && target_fps <= 20;
}

void ParticleInstance::Refresh() {
    ++m_generation;
    m_deaths           = 0;
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
    m_emitting = false;
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

bool ParticleSubSystem::Paused() const {
    for (auto* system = this; system; system = system->m_parent_system)
        if (system->m_script_paused) return true;
    return false;
}

bool ParticleSubSystem::HasRawActivity() const {
    for (const auto& instance : m_instances) {
        if ((!instance->Particles().empty() && !instance->IsNoLiveParticle()) ||
            (!instance->IsDeath() && instance->Emitting())) return true;
    }
    if (m_spawn_type == SpawnType::STATIC && m_instances.empty() && !m_emitters_stopped) {
        for (const auto& emitter : m_emiters) if (!emitter.Finished()) return true;
    }
    for (const auto& child : m_children) if (child->HasRawActivity()) return true;
    return false;
}

bool ParticleSubSystem::IsPlaying() const { return !Paused() && HasRawActivity(); }

void ParticleSubSystem::ClearPauseTree() {
    m_script_paused = false;
    for (auto& child : m_children) child->ClearPauseTree();
}

void ParticleSubSystem::RestartTree() {
    for (auto& instance : m_instances) {
        BindInstance(*instance);
        bool emitting = false;
        for (auto& emitter : instance->Emitters()) { emitter.Play(); emitting = true; }
        instance->SetEmitting(emitting);
    }
    m_emitters_stopped = false;
    for (auto& child : m_children) child->RestartTree();
}

void ParticleSubSystem::Play() {
    ClearPauseTree();
    // Native play does not restart a system whose particles or children are still
    // alive. Only a fully inactive tree has its emitter-finished flags reopened.
    if (!HasRawActivity()) RestartTree();
    m_sys.InvalidateTimeDemand();
}

void ParticleSubSystem::Pause() {
    m_script_paused = true;
    m_sys.InvalidateTimeDemand();
}

void ParticleSubSystem::ApplyInstanceOverride() {
    if (m_spawn_type == SpawnType::STATIC) {
        if (m_instances.empty()) m_instances.emplace_back(std::make_unique<ParticleInstance>());
        for (auto& instance : m_instances) {
            BindInstance(*instance);
            bool emitting = false;
            for (auto& emitter : instance->Emitters()) {
                emitter.ApplyOverride();
                emitting = emitting || ! emitter.Finished();
            }
            instance->SetEmitting(emitting);
            if (emitting) m_emitters_stopped = false;
        }
    }
    // Native rebinding updates existing event records but does not reopen their
    // finished flags. The shared override is already visible to their operators.
    for (auto& child : m_children)
        if (child->m_spawn_type == SpawnType::STATIC) child->ApplyInstanceOverride();
}

void ParticleSubSystem::InvalidateMeshes() {
    m_mesh_rebuilt = false;
    if (m_mesh) m_mesh->SetDirty();
    for (auto& mirror : m_mirrors) {
        mirror->m_mesh_rebuilt = false;
        if (mirror->m_mesh) mirror->m_mesh->SetDirty();
    }
    for (auto& child : m_children) child->InvalidateMeshes();
}

void ParticleSubSystem::StopTree() {
    m_emitters_stopped = true;
    m_time = m_trail_timer = 0;
    m_local_live = m_local_emitting = m_time_advancing = false;
    if (m_spawn_type == SpawnType::STATIC) {
        for (auto& instance : m_instances) {
            instance->Refresh();
            instance->SetNoLiveParticle(true);
        }
    } else m_instances.clear();
    for (auto& child : m_children) child->StopTree();
}

void ParticleSubSystem::Stop() {
    StopTree();
    InvalidateMeshes();
    m_sys.InvalidateTimeDemand();
}

void ParticleSubSystem::EmitParticles(int32_t count) {
    if (count < 0 || m_spawn_type != SpawnType::STATIC) return;
    const uint32_t extra = count == 0 ? 1u : static_cast<uint32_t>(count);
    KeepWorldPositions();
    UpdateControlpoints();
    if (m_instances.empty()) m_instances.emplace_back(std::make_unique<ParticleInstance>());
    auto& instance = *m_instances.front();
    BindInstance(instance);
    m_spawn_ctx->controlpoints = m_controlpoints;
    m_spawn_ctx->system_time = m_time;
    m_spawn_ctx->frame_time = 0;
    m_spawn_ctx->scene_frame_time = m_sys.scene.frameTime;
    m_spawn_ctx->layer_time = m_sys.scene.elapsingTime;
    m_spawn_ctx->time_of_day = m_needs_time_of_day
        ? LocalTimeOfDay(std::chrono::system_clock::now()).value_or(0.0) : 0.0;
    m_spawn_ctx->layer_origin = linalg::Vector3d::Zero();
    m_spawn_ctx->parent = nullptr;
    m_spawn_ctx->world_space = m_world_space;
    if (const auto frame = OwnerWorldFrame()) {
        if (m_needs_layer_origin || m_world_space) m_spawn_ctx->layer_origin = frame->origin;
        if (m_needs_scene_frame) {
            linalg::Matrix4d model = linalg::Matrix4d::Identity();
            model.topRightCorner<3,1>() = frame->origin;
            if (!m_world_space) model.topLeftCorner<3,3>() = frame->linear;
            const linalg::Matrix4d inverse = model.inverse();
            if (inverse.allFinite()) m_spawn_ctx->scene_to_local = inverse;
        }
    }
    bool emitting = false;
    for (auto& emitter : instance.Emitters()) {
        ParticleEmitterControl control { .scheduled=!Paused(), .extra=extra };
        emitter(instance.ParticlesVec(), instance.Initializers(), std::min<u32>(m_maxcount,20000u),
                0, m_controlpoints, control);
        emitting = emitting || !control.finished;
    }
    instance.SetEmitting(emitting);
    instance.SetNoLiveParticle(std::none_of(instance.Particles().begin(), instance.Particles().end(),
        [](const Particle& particle) { return ParticleModify::LifetimeOk(particle); }));
    InvalidateMeshes();
    m_sys.InvalidateTimeDemand();
}

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
    RefreshParentFrameMetadata();
}

void ParticleSubSystem::SetWorldSpace(bool value) {
    m_world_space = value;
    RefreshParentFrameMetadata();
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
    if (IsTrailRenderer() && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4 && m_trail.enabled()) {
            // A trail drawn by its geometry stage has one record per recorded pair.
            const bool  strips = m_mesh->GetVertexArray(0).GetOption(WE_PRENDER_GEOMETRY);
            const float points = static_cast<float>(m_trail.samples * (strips ? 1u : m_rope_subdivision));
            it->second[0] = scrolling ? points - 1.0f : static_cast<float>(m_trail.samples);
            it->second[3] = RopeTrailMaxCount(points, m_uv_scale, m_uv_scrolling);
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
    // The part of the period gone by since the last point (`g_RenderVar0.z`, 0x1402366F0).
    return static_cast<float>(std::clamp(1.0 - std::max(m_trail_timer, 0.0) / m_trail.period, 0.0, 1.0));
}

ParticleSubSystem::SpawnType ParticleSubSystem::Type() const { return m_spawn_type; }

u32 ParticleSubSystem::MaxInstanceCount() const { return m_maxcount_instance; };

bool ParticleSubSystem::IsTrailRenderer() const {
    return m_mesh != nullptr && m_mesh->VertexCount() != 0 &&
        m_mesh->GetVertexArray(0).GetOption(WE_PRENDER_ROPETRAIL);
}

void ParticleSubSystem::UpdateTrailFraction(float fraction) {
    if (!IsTrailRenderer() || m_mesh->Material() == nullptr) return;
    auto& values = m_mesh->Material()->customShader.constValues;
    const auto found = values.find("g_RenderVar0");
    if (found != values.end() && found->second.size() >= 4) found->second[2] = fraction;
}

ParticleRenderScale ParticleSubSystem::RenderScale(float trail_fraction) const {
    ParticleRenderScale scale;
    scale.positions_include_binding = m_world_space;
    scale.rope_subdivision = m_rope_subdivision;
    scale.rope_rate        = m_rope_rate;
    scale.rope_lifetime    = m_rope_lifetime;
    scale.target_fps       = m_sys.scene.targetFps;
    scale.trail_fraction   = trail_fraction;
    scale.trail_fade_flags = m_trail_fade_flags;
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
    for (const auto& point : m_controlpoints) any = any || (point.link_mouse && !point.written_by_remap);
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
        if (point.link_mouse && !point.written_by_remap) point.offset = pointer;
    }
}

void ParticleSubSystem::RefreshParentFrameMetadata() {
    if (m_parent_system != nullptr) {
        m_parent_frame_override = m_parent_system->m_parent_frame_override ||
            (m_parent_system->m_world_space && m_spawn_type != SpawnType::STATIC);
        const auto owner = m_owner_node.lock();
        const bool identity_entry = owner != nullptr && owner->Scale().isApprox(linalg::Vector3f(1, 1, 1), 0.0f) &&
                                    owner->Rotation().isZero();
        m_identity_parent_binding = m_parent_system->m_world_space == m_world_space &&
                                    (m_world_space || identity_entry);
    }
    // Construction attaches the outer parent after its descendants were built.
    for (auto& child : m_children) child->RefreshParentFrameMetadata();
}

void ParticleSubSystem::AddChild(std::unique_ptr<ParticleSubSystem>&& child) {
    child->m_parent_system = this;
    child->RefreshParentFrameMetadata();
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
        const auto fraction = source.TrailPeriodFraction();
        if (source.m_trail.enabled()) UpdateTrailFraction(fraction);
        m_sys.gener->GenGLData(
            source.m_instances, *m_mesh, m_genSpecOp, RenderScale(fraction), m_overflow_flags);
        m_mesh_rebuilt = true;
    } else {
        m_mesh_rebuilt = false;
    }
}

ParticleInstance* ParticleSubSystem::QueryNewInstance() {
    if (m_emitters_stopped && m_spawn_type != SpawnType::STATIC) RestartTree();
    // One draw is spent on every event, whether or not it creates anything.
    const double chance = Random::get(0.0, 1.0);
    if (chance > m_probability) return nullptr;
    for (auto& inst : m_instances) {
        if (inst->IsDeath() && inst->IsNoLiveParticle()) {
            inst->Refresh();
            inst->SetGeneration(++m_instance_generation);
            return inst.get();
        }
    }
    if (m_instances.size() < MaxInstanceCount()) {
        m_instances.push_back(std::make_unique<ParticleInstance>());
        m_instances.back()->SetIndex(static_cast<uint32_t>(m_instances.size() - 1));
        m_instances.back()->SetGeneration(++m_instance_generation);
        return m_instances.back().get();
    }
    return nullptr;
}

void ParticleSubSystem::BindInstance(ParticleInstance& inst) {
    if (inst.BoundVersion() == m_ops_version) return;
    inst.Emitters()    = m_emiters;
    inst.Initializers() = m_initializers;
    inst.SetBoundVersion(m_ops_version);
    bool emitting = false;
    for (auto& emitter : inst.Emitters()) {
        if (m_emitters_stopped) emitter.Stop();
        emitting = emitting || !emitter.Finished();
    }
    inst.SetEmitting(emitting);
}

linalg::Matrix4d ParticleSubSystem::SimulationTransform(const std::shared_ptr<SceneNode>& owner) const {
    if (! m_parent_frame_override || m_parent_system == nullptr) return owner->ModelTrans();
    linalg::Matrix4d parent = m_parent_system->SimulationTransform();
    // An event child starts in its parent's simulation space. World particles
    // have already taken the parent's rotation/scale at birth.
    if (m_spawn_type != SpawnType::STATIC && m_parent_system->WorldSpace())
        parent.topLeftCorner<3, 3>() = linalg::Matrix3d::Identity();
    return parent * owner->GetLocalTrans();
}

linalg::Matrix4d ParticleSubSystem::SimulationTransform() const {
    const auto owner = m_owner_node.lock();
    if (! owner) return linalg::Matrix4d::Identity();
    owner->UpdateTrans();
    return SimulationTransform(owner);
}

std::optional<ParticleSubSystem::WorldFrame> ParticleSubSystem::OwnerWorldFrame() const {
    const auto owner = m_owner_node.lock();
    if (! owner) return std::nullopt;
    owner->UpdateTrans();
    const linalg::Matrix4d model = SimulationTransform(owner);
    WorldFrame            frame;
    frame.linear = model.topLeftCorner<3, 3>();
    frame.origin = model.topRightCorner<3, 1>();
    return frame;
}

ParticleSubSystem::ControlpointFrame ParticleSubSystem::PrepareControlpointFrame() const {
    ControlpointFrame frame;
    const auto owner = m_owner_node.lock();
    if (owner) {
        owner->UpdateTrans();
        frame.model = SimulationTransform(owner);
        frame.in_world = m_world_space;
        if (! m_world_space) {
            frame.inverse = frame.model.inverse();
            frame.have_inverse = frame.inverse.allFinite();
        }
    }
    if (m_parent_system != nullptr && m_spawn_type != SpawnType::STATIC && ! m_identity_parent_binding) {
        linalg::Matrix3d mapping = m_parent_system->WorldSpace() ? linalg::Matrix3d::Identity()
            : linalg::Matrix3d(m_parent_system->SimulationTransform().topLeftCorner<3, 3>());
        if (! m_world_space) mapping = frame.inverse.topLeftCorner<3, 3>() * mapping;
        if (mapping.allFinite()) frame.parent_to_local = mapping;
    }
    if (m_world_space && m_spawn_type != SpawnType::STATIC)
        for (std::size_t i = 0; i < m_controlpoints.size(); ++i)
            frame.previous_offsets[i] = m_controlpoints[i].prev_offset;
    return frame;
}

void ParticleSubSystem::SetParentPointFeed(int start) {
    // Invalid author indices cannot address outside the eight-point array.
    m_parent_point_start = start >= 0 && start < 8 ? static_cast<uint8_t>(start) : 255;
}

void ParticleSubSystem::ApplyParentPointFeed(ParticleInstance* instance, const ControlpointFrame& frame) {
    if (m_parent_point_start >= 8 || m_parent_system == nullptr) return;
    ParticleInstance* parent = instance != nullptr ? instance->GetBoundedData().parent : nullptr;
    if (parent == nullptr && !m_parent_system->m_instances.empty()) parent = m_parent_system->m_instances.front().get();
    // Native holds fed destinations when there are fewer live parents, rather
    // than restoring the authored offsets on the next step.
    for (std::size_t i=m_parent_point_start; i<m_controlpoints.size(); ++i) {
        auto& point = m_controlpoints[i];
        if (!point.link_mouse && !point.copy_from_parent && !point.written_by_remap) {
            if (m_world_space && !point.owned_world_relative) {
                point.offset -= frame.model.topRightCorner<3,1>();
                point.prev_offset = point.offset;
                point.owned_world_relative = true;
            }
            point.parent_resolved = true;
        }
    }
    if (parent == nullptr) return;
    linalg::Matrix4d parent_model = m_parent_system->SimulationTransform();
    const auto& binding = parent->GetBoundedData();
    if (!m_parent_system->WorldSpace())
        parent_model.topRightCorner<3,1>() += parent_model.topLeftCorner<3,3>() * binding.pos.cast<double>();
    linalg::Matrix4d mapping = linalg::Matrix4d::Identity();
    if (m_parent_system->WorldSpace() != m_world_space) {
        mapping = m_world_space ? parent_model : parent_model.inverse();
        if (!mapping.allFinite()) return;
    }
    std::size_t next = m_parent_point_start;
    for (const auto& particle : parent->Particles()) {
        if (next >= m_controlpoints.size()) break;
        if (particle.lifetime == 0.0f) continue;
        auto& point = m_controlpoints[next];
        // A protected destination consumes neither a destination nor a source
        // assignment: every remaining particle meets the same protected point.
        if (point.link_mouse || point.copy_from_parent || point.written_by_remap) break;
        Vec3 position = particle.position.cast<double>();
        if (m_parent_system->WorldSpace()) position += parent_model.topRightCorner<3,1>();
        position = mapping.topLeftCorner<3,3>() * position + mapping.topRightCorner<3,1>();
        if (m_world_space) position -= frame.model.topRightCorner<3,1>();
        point.offset = position;
        ++next;
    }
}

void ParticleSubSystem::UpdateControlpoints(ParticleInstance* instance) {
    ApplyControlpointFrame(instance, PrepareControlpointFrame());
}

void ParticleSubSystem::ApplyControlpointFrame(ParticleInstance* instance, const ControlpointFrame& frame,
                                              const linalg::Vector3f& previous_binding) {
    const auto& model = frame.model;
    const auto& inverse = frame.inverse;
    const bool in_world = frame.in_world;
    const bool have_inverse = frame.have_inverse;
    const linalg::Matrix3d linear = model.topLeftCorner<3, 3>();
    if (m_cp_source) m_cp_source(m_controlpoints, instance, model, inverse, ControlpointStage::Prepare);
    UpdateMouseControlpoints();
    ApplyParentPointFeed(instance, frame);

    for (std::size_t i = 0; i < m_controlpoints.size(); ++i) {
        auto& point  = m_controlpoints[i];
        if (point.parent_resolved) continue;
        if (point.written_by_remap) {
            if (in_world && !point.owned_world_relative) {
                point.offset -= Origin(model);
                point.prev_offset = point.offset;
                point.owned_world_relative = true;
            }
            continue;
        }
        const bool pinned = IsPinned(point, i);
        if (in_world && instance != nullptr && m_spawn_type != SpawnType::STATIC) {
            point.prev_offset = frame.previous_offsets[i];
            if (!pinned && !point.link_mouse) point.prev_offset += previous_binding.cast<double>();
        }
        if (in_world) {
            // Particles live in scene units around the layer's origin: a point
            // is the layer's matrix applied to its offset, a pinned one is the
            // scene position measured from the origin and carries no matrix.
            if (pinned) {
                point.offset           = point.base_offset - Origin(model);
                point.has_world_linear = false;
                point.world_linear     = linalg::Matrix3d::Identity();
            } else {
                if (! point.link_mouse) {
                    point.offset = linear * point.base_offset;
                    if (instance != nullptr) point.offset += instance->GetBoundedData().pos.cast<double>();
                }
                point.has_world_linear = true;
                point.world_linear     = linear;
            }
        } else {
            point.has_world_linear = false;
            point.world_linear     = linalg::Matrix3d::Identity();
            if (pinned && have_inverse) point.offset = TransformPoint(inverse, point.base_offset);
        }
        if (in_world && instance != nullptr && !instance->GetBoundedData().controlpoints_primed)
            point.prev_offset = point.offset;
    }
    if (instance != nullptr) instance->GetBoundedData().controlpoints_primed = true;

    if (! m_cp_primed) {
        for (auto& point : m_controlpoints) point.prev_offset = point.offset;
        m_cp_primed = true;
    }
}

void ParticleSubSystem::KeepWorldPositions() {
    if (! m_world_space && ! m_parent_frame_override) return;
    const auto frame = OwnerWorldFrame();
    if (! frame) return;

    // Draw world particles through translation alone; a local child of a
    // world parent uses the parent's simulation basis rather than its layer basis.
    const auto set_draw_frame = [&](const std::shared_ptr<SceneNode>& node) {
        if (! node) return;
        linalg::Matrix4d transform = linalg::Matrix4d::Identity();
        if (! m_world_space) transform.topLeftCorner<3, 3>() = frame->linear;
        transform.topRightCorner<3, 1>() = frame->origin + node->DrawOffset().cast<double>();
        node->SetRenderTransformOverride(transform);
    };
    set_draw_frame(m_owner_node.lock());
    for (auto& mirror : m_mirrors) set_draw_frame(mirror->m_owner_node.lock());
    if (! m_world_space) return;

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
            if (m_owned_controlpoints != 0) {
                for (std::size_t i=0;i<m_controlpoints.size();++i) {
                    auto& point = m_controlpoints[i];
                    if ((m_owned_controlpoints & (1u << i)) != 0 && point.owned_world_relative) {
                        point.offset -= moved;
                        point.prev_offset -= moved;
                    }
                }
            }
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

/// Counts a recording clock down by `dt` and reports whether it came due. As in
/// WE's trail writer (0x1402308A0) the clock starts at zero, so the first frame
/// records, and a due clock starts the whole period again: what the frame ran
/// past the period is dropped, which puts the points a whole number of frames
/// apart. A clock whose configuration records nothing stays still.
bool TickRecordingClock(const ParticleTrailConfig& config, double& clock, double dt) {
    if (! config.enabled()) return false;
    clock = static_cast<float>(clock) - static_cast<float>(dt);
    if (clock > 0.0) return false;
    clock = static_cast<float>(config.period);
    return true;
}

} // namespace

void ParticleSubSystem::Advance(double dt, bool pause_emission, bool record_trails) {
    KeepWorldPositions();   // a move of the layer since the last step

    m_time += dt;
    ++m_steps;
    const bool recording = record_trails && TickRecordingClock(m_trail, m_trail_timer, dt);

    const auto advance_instances = [&](const ControlpointFrame* frame) {
        // A static system always owns one instance to run.
        if (m_spawn_type == SpawnType::STATIC && m_instances.empty())
            m_instances.emplace_back(std::make_unique<ParticleInstance>());

        // Events create instances in the children only, but the count is read each
        // round so a growing list is never stepped past its end.
        m_local_live = m_local_emitting = false;
        for (std::size_t next = 0; next != m_instances.size(); ++next) {
            auto& instance = *m_instances[next];
            AdvanceInstance(instance, dt, m_time, recording, pause_emission, frame);
            m_local_live = m_local_live || (!instance.Particles().empty() && !instance.IsNoLiveParticle());
            m_local_emitting = m_local_emitting || (!instance.IsDeath() && instance.Emitting());
        }
    };
    // Both control points and binding conversion share this frame. The ordinary
    // path already prepared its model/inverse once in UpdateControlpoints.
    const auto frame = PrepareControlpointFrame();
    if (! m_cp_per_instance && !(m_world_space && m_spawn_type != SpawnType::STATIC))
        ApplyControlpointFrame(nullptr, frame);
    advance_instances(&frame);

    SaveControlpointFrame(m_instances.empty() ? nullptr : m_instances.back().get());
}

void ParticleSubSystem::SaveControlpointFrame(ParticleInstance* instance, ControlpointFrame* frame) {
    for (std::size_t i = 0; i < m_controlpoints.size(); ++i) {
        auto& point = m_controlpoints[i];
        point.prev_offset = point.offset;
        if (m_world_space && m_spawn_type != SpawnType::STATIC && instance != nullptr &&
            !point.parent_resolved && !IsPinned(point, i) && !point.link_mouse)
            point.prev_offset -= instance->GetBoundedData().pos.cast<double>();
        if (frame != nullptr) frame->previous_offsets[i] = point.prev_offset;
    }
}

void ParticleSubSystem::AdvanceInstance(ParticleInstance& inst, double dt, double time,
                                        bool record_trail, bool pause_emission, const ControlpointFrame* frame) {
    auto&       slots = inst.ParticlesVec();
    auto&       bound = inst.GetBoundedData();
    const bool  event_child = m_spawn_type != SpawnType::STATIC;
    const linalg::Vector3f previous_binding = bound.pos;

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
            if (m_parent_system == nullptr || ! m_parent_system->WorldSpace())
                place += bound.parent->GetBoundedData().pos.cast<double>();
            if (frame != nullptr && frame->parent_to_local) place = *frame->parent_to_local * place;
            bound.pos = place.cast<float>();
            bound.pre_lifetime_ok = ParticleModify::LifetimeOk(parent_particle);
            if (m_spawn_type == SpawnType::EVENT_FOLLOW || m_spawn_type == SpawnType::EVENT_SPAWN) {
                if (! bound.pre_lifetime_ok || bound.parent->IsDeath()) {
                    inst.SetDeath(true);
                    // Stop following the particle, but retain the control-point
                    // parent link (native +16 survives clearing particle index +1144).
                    if (m_spawn_type == SpawnType::EVENT_FOLLOW) bound.particle_idx = -1;
                }
            }
        }
        first_death_step = in_range && m_spawn_type == SpawnType::EVENT_DEATH;
    }

    const linalg::Vector3f render_anchor = m_world_space ? linalg::Vector3f::Zero() : bound.pos;
    if (m_cp_per_instance || (m_world_space && event_child)) {
        if (frame != nullptr) ApplyControlpointFrame(&inst, *frame, previous_binding);
        else UpdateControlpoints(&inst);
    }

    // What `remapvalue` and `remapinitialvalue` read besides the particles.
    const double layer_time  = m_sys.scene.elapsingTime;
    const double time_of_day = m_needs_time_of_day
                                   ? LocalTimeOfDay(std::chrono::system_clock::now()).value_or(0.0)
                                   : 0.0;
    linalg::Vector3d layer_origin { 0.0, 0.0, 0.0 };
    if (m_world_space && frame != nullptr) layer_origin = frame->model.topRightCorner<3, 1>();
    else if (m_needs_layer_origin) {
        if (const auto owner_frame = OwnerWorldFrame()) layer_origin = owner_frame->origin;
    }
    // The parent particle of an event child, while it lives.
    const Particle* live_parent = nullptr;
    if (bound.parent != nullptr && bound.particle_idx >= 0) {
        const auto parent_slots = bound.parent->Particles();
        if (static_cast<std::size_t>(bound.particle_idx) < parent_slots.size() &&
            ParticleModify::LifetimeOk(parent_slots[static_cast<std::size_t>(bound.particle_idx)]))
            live_parent = &parent_slots[static_cast<std::size_t>(bound.particle_idx)];
    }

    if (m_needs_scene_frame) {
        // Wallpaper Engine takes the collision planes and capsules through the
        // inverse of the layer's model matrix unless the system is in world
        // space (0x1401C5490, artifacts/we-parity/decompiles/F-D13.md); ours
        // also measures a world-space system and an event child from an origin.
        linalg::Matrix4d to_local = linalg::Matrix4d::Identity();
        if (const auto frame = OwnerWorldFrame()) {
            if (m_world_space) {
                to_local.topRightCorner<3, 1>() = -frame->origin;
            } else {
                linalg::Matrix4d model         = linalg::Matrix4d::Identity();
                model.topLeftCorner<3, 3>()    = frame->linear;
                model.topRightCorner<3, 1>()   = frame->origin;
                const linalg::Matrix4d inverse = model.inverse();
                if (inverse.allFinite()) to_local = inverse;
            }
        }
        linalg::Matrix4d shift          = linalg::Matrix4d::Identity();
        shift.topRightCorner<3, 1>()    = -render_anchor.cast<double>();
        m_spawn_ctx->scene_to_local      = shift * to_local;
        m_spawn_ctx->scene_frame_time = m_sys.scene.frameTime;
    }

    // 2. Emission, from the emitters and initializers this instance owns.
    inst.SetEmitting(false);
    if (! inst.IsDeath()) {
        BindInstance(inst);
        m_spawn_ctx->controlpoints = m_controlpoints;
        m_spawn_ctx->system_time   = time;
        m_spawn_ctx->frame_time    = dt;
        m_spawn_ctx->layer_time    = layer_time;
        m_spawn_ctx->time_of_day   = time_of_day;
        m_spawn_ctx->layer_origin  = layer_origin;
        m_spawn_ctx->world_space   = m_world_space;
        m_spawn_ctx->parent        = nullptr;
        if (bound.parent != nullptr && bound.particle_idx >= 0) {
            const auto parent_slots = bound.parent->Particles();
            if (static_cast<std::size_t>(bound.particle_idx) < parent_slots.size())
                m_spawn_ctx->parent = &parent_slots[static_cast<std::size_t>(bound.particle_idx)];
        }
        const u32 capacity = std::min<u32>(m_maxcount, 20000u);
        bool emitting = false;
        for (auto& emitter : inst.Emitters()) {
            ParticleEmitterControl control { .scheduled=!pause_emission };
            emitter(slots, inst.Initializers(), capacity, dt, m_controlpoints, control);
            emitting = emitting || !control.finished;
        }
        inst.SetEmitting(emitting);
        m_spawn_ctx->parent = nullptr;
        // The death an `eventdeath` instance was born of never stops its emitters
        // (0x140236CD0 clears their stop bit); it is done, and can be taken again,
        // once they have all finished.
        if (m_spawn_type == SpawnType::EVENT_DEATH && ! emitting) inst.SetDeath(true);
    }
    // It stays where the particle died rather than following the slot.
    if (first_death_step) bound.particle_idx = -1;

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
            child->PrewarmInstance(*made, pause_emission || child->m_script_paused);
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
                trail.Push({ p.position + render_anchor });
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
            inst.CountDeath();
            fire(true, i);
        }
    }
    inst.SetNoLiveParticle(! any_alive);

    // 4. The operators, in file order, over this step's particles. The forces
    // act over a shortened step below 40 frames a second, and a cap of 20 or
    // less runs the operators twice over half steps; both passes read the same
    // system time, and emission, ageing and trails stay single (0x140237724,
    // artifacts/we-parity/decompiles/F-D5.md).
    const uint32_t fps    = m_sys.scene.targetFps;
    const bool     halves = ParticleRunsHalfSteps(fps);
    const double   pass   = halves ? 0.5 * dt : dt;
    ParticleInfo info {
        .particles        = slots,
        .controlpoints    = m_controlpoints,
        .time             = time,
        .time_pass        = pass,
        .time_pass_scaled = pass * ParticleForceStepScale(fps),
    };
    info.track_previous_position = m_tracks_prev_position;
    info.world_space = m_world_space;
    info.parent                  = live_parent;
    info.step                    = m_steps;
    info.layer_time              = layer_time;
    info.time_of_day             = time_of_day;
    info.layer_origin            = layer_origin;
    if (m_needs_world_axes && ! m_world_space) {
        if (const auto frame = OwnerWorldFrame()) info.world_to_local = frame->linear.transpose();
    }
    if (m_needs_scene_frame) {
        info.scene_to_local = m_spawn_ctx->scene_to_local;
        info.canvas = linalg::Vector2d(m_sys.scene.ortho[0], m_sys.scene.ortho[1]);
    }
    for (int run = halves ? 2 : 1; run > 0; --run) {
        // Each pass starts colour, alpha and size from their birth values, as
        // the operator interpreter copies them in before it runs (0x14023FC34).
        if (run == 1 && halves) {
            for (auto& p : slots) ParticleModify::Reset(p);
        }
        for (auto& op : m_operators) op(info);
    }

    // 5. Trail points, after the operators have moved the particles.
    if (keeps_trails && record_trail) {
        auto& trails = inst.TrailsVec();
        for (std::size_t i = 0; i < slots.size() && i < trails.size(); ++i) {
            if (ParticleModify::LifetimeOk(slots[i])) trails[i].Push({ slots[i].position + render_anchor });
        }
    }
    if (m_cp_commit && m_cp_source && frame != nullptr)
        m_cp_source(m_controlpoints, &inst, frame->model, frame->inverse, ControlpointStage::Commit);

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

void ParticleSubSystem::PrewarmInstance(ParticleInstance& inst, bool pause_emission) {
    if (m_starttime <= 0.0) return;
    auto frame = PrepareControlpointFrame();
    const double dt    = PrewarmStepSeconds(m_maxcount);
    double       timer = 0.0;
    double       elapsed     = 0.0;
    int          steps       = 0;
    do {
        // WE's prewarm runs the simulation only; trails are recorded by the writer.
        AdvanceInstance(inst, dt, m_time + elapsed + dt, false, pause_emission, &frame);
        SaveControlpointFrame(&inst, &frame);
        elapsed += dt;
        timer += dt;
        ++steps;
    } while (timer < m_starttime && steps < kMaxPrewarmSteps);
    RestartTrails(inst);
}

void ParticleSubSystem::RestartTrails(ParticleInstance& inst) {
    if (! m_trail.enabled()) return;
    // After a prewarm WE fills every particle's history with where it is (0x14022F430).
    auto& slots  = inst.ParticlesVec();
    auto& trails = inst.TrailsVec();
    if (trails.size() < slots.size()) trails.resize(slots.size());
    const linalg::Vector3f anchor = m_world_space ? linalg::Vector3f::Zero() : inst.GetBoundedData().pos;
    for (std::size_t i = 0; i < slots.size(); ++i) {
        if (! ParticleModify::LifetimeOk(slots[i])) continue;
        trails[i].Reset(m_trail.samples);
        trails[i].Push({ slots[i].position + anchor });
    }
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
        sys.Advance(dt, false, false);
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) step(*child);
        }
    };
    for (int i = 0; i < steps; ++i) step(*this);
    std::function<void(ParticleSubSystem&)> restart = [&](ParticleSubSystem& sys) {
        for (auto& instance : sys.m_instances) sys.RestartTrails(*instance);
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) restart(*child);
        }
    };
    restart(*this);
    if (skipped > 0.0) add_time(*this);
    // A script or a timeline can still place the layer after the parse: the
    // first frame sets the matrix the particles are kept against, so the
    // prewarmed ones are not carried away from it.
    m_have_prev_model = false;
    // The mesh is built by the first frame that draws it.
    m_mesh_rebuilt = false;
}

void ParticleSubSystem::Emitt(bool inherited_pause) {
    double multiplier = 1.0;
    if (m_rate_multiplier) {
        const double asked = m_rate_multiplier();
        // Wallpaper Engine holds the override rate at 0.01 or more (0x14022AF30:
        // fmaxf(0.01f, rate)), a value that is not a number included.
        multiplier         = std::fmax(0.01, asked);
    }
    double dt = m_sys.scene.frameTime * m_rate * multiplier;
    if (! std::isfinite(dt) || dt < 0.0) dt = 0.0;
    const bool paused = inherited_pause || m_script_paused;
    Advance(dt, paused);
    m_time_advancing = m_local_live || (!paused && m_local_emitting);

    if (m_drawn && m_mesh != nullptr) {
        m_mesh->SetDirty();
        // The rope trail's shader eases the oldest piece by this fraction.
        if (m_trail.enabled()) UpdateTrailFraction(TrailPeriodFraction());
        const auto owner = m_owner_node.lock();
        if (m_sys.gener != nullptr && (! owner || owner->EffectiveVisible() || owner->MustProduce())) {
            m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(TrailPeriodFraction()), m_overflow_flags);
            m_mesh_rebuilt = true;
        } else {
            m_mesh_rebuilt = false;
        }
        for (auto& mirror : m_mirrors) mirror->GenerateFrom(*this);
    }
    for (auto& child : m_children) {
        child->Emitt(paused);
        m_time_advancing = m_time_advancing || child->HasTimeAdvancingWork();
    }
}

void ParticleSubSystem::RebuildMesh() {
    if (m_drawn && ! m_mesh_rebuilt && m_sys.gener != nullptr && m_mesh != nullptr) {
        const auto owner = m_owner_node.lock();
        // Still hidden, and nothing samples it: the mesh is not read this
        // frame. A missing owner is rebuilt, matching Emitt.
        if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
            m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(TrailPeriodFraction()), m_overflow_flags);
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
    for (auto* layer : m_pending_updates) {
        auto& pending = *layer->pending;
        pending.apply(pending);
        pending.fields = 0;
        pending.queued = false;
        layer->system->ApplyInstanceOverride();
    }
    m_pending_updates.clear();
    m_time_advancing = false;
    for (auto& el : subsystems) {
        el->Emitt();
        m_time_advancing = m_time_advancing || el->HasTimeAdvancingWork();
    }
    m_work_known = true;
}

void ParticleSystem::RegisterLayer(std::string key, ParticleSubSystem* system,
                                   std::shared_ptr<wpscene::ParticleInstanceoverride> instance) {
    if (const auto found = m_layers.find(key); found != m_layers.end())
        std::erase(m_pending_updates, &found->second);
    m_layers.insert_or_assign(std::move(key), Layer {system, std::move(instance), {}});
    InvalidateTimeDemand();
}

ParticleSubSystem* ParticleSystem::ForLayer(std::string_view key) const {
    const auto found = m_layers.find(key);
    return found == m_layers.end() ? nullptr : found->second.system;
}

std::shared_ptr<wpscene::ParticleInstanceoverride> ParticleSystem::InstanceForLayer(std::string_view key) const {
    const auto found = m_layers.find(key);
    return found == m_layers.end() ? nullptr : found->second.instance;
}

ParticleInstanceUpdate* ParticleSystem::PendingInstanceForLayer(std::string_view key, bool create) {
    const auto found = m_layers.find(key);
    if (found == m_layers.end()) return nullptr;
    auto& pending = found->second.pending;
    if (create && ! pending) pending = std::make_unique<ParticleInstanceUpdate>();
    return pending.get();
}

void ParticleSystem::QueueInstanceUpdate(std::string_view key) {
    const auto found = m_layers.find(key);
    if (found == m_layers.end() || ! found->second.pending || found->second.pending->queued) return;
    found->second.pending->queued = true;
    m_pending_updates.push_back(&found->second);
    InvalidateTimeDemand();
}

void ParticleSystem::RemoveLayer(std::string_view key) {
    const auto found = m_layers.find(key);
    if (found == m_layers.end()) return;
    auto* system = found->second.system;
    std::erase(m_pending_updates, &found->second);
    m_layers.erase(found);
    std::erase_if(subsystems, [system](const auto& value) { return value.get() == system; });
    InvalidateTimeDemand();
}

void ParticleSystem::RebuildVisibleMeshes() {
    for (auto& el : subsystems) {
        el->RebuildMesh();
    }
}
