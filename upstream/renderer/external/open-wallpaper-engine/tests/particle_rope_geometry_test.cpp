#include "Interface/IParticleRawGener.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Scene/Scene.h"
#include "Scene/SceneMesh.h"
#include "SpecTexs.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <span>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr uint32_t kMeshCapacity = 16;

Particle LiveAt(const Eigen::Vector3f& pos, float size = 20.0f, float lifetime = 1.0f) {
    Particle particle;
    particle.position = pos;
    particle.size     = size;
    particle.lifetime = lifetime;
    return particle;
}

Particle DeadAt(const Eigen::Vector3f& pos) {
    Particle particle;
    particle.position = pos;
    particle.lifetime = 0.0f;
    return particle;
}

std::unique_ptr<ParticleInstance> MakeInstance(std::initializer_list<Particle> particles) {
    auto instance = std::make_unique<ParticleInstance>();
    instance->ParticlesVec().assign(particles);
    return instance;
}

// Attribute list copied from SetRopeParticleMesh; every attribute is FLOAT4.
void AddRopeParticleMesh(SceneMesh& mesh, uint32_t capacity, bool thick, bool trail = false) {
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
    };
    if (thick) {
        attrs.push_back({ WE_IN_TEXCOORDVEC4C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDVEC4C3.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC4.data(), VertexType::FLOAT4 });
    } else {
        attrs.push_back({ WE_IN_TEXCOORDVEC3C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC3.data(), VertexType::FLOAT4 });
    }
    attrs.push_back({ WE_IN_COLOR.data(), VertexType::FLOAT4 });
    mesh.AddVertexArray(SceneVertexArray(attrs, capacity * 4));
    const auto layout = PlanParticleIndexLayout(capacity);
    mesh.AddIndexArray(SceneIndexArray(capacity, layout.width));
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    mesh.GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, thick);
    if (trail) {
        mesh.GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
        mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPETRAIL, true);
    }
}

void GenRope(std::vector<std::unique_ptr<ParticleInstance>>& instances, SceneMesh& mesh,
             ParticleRenderScale scale) {
    WPParticleRawGener     gener;
    ParticleRawGenSpecOp   spec = [](const Particle&, const ParticleRawGenSpec&) {
    };
    ParticleOverflowFlags flags;
    gener.GenGLData(instances, mesh, spec, scale, flags);
}

const float* QuadVertex(const SceneVertexArray& vertices, std::size_t quad, std::size_t vert) {
    return vertices.Data() + (quad * 4 + vert) * vertices.OneSize();
}

void ExpectVec3(const float* components, const Eigen::Vector3f& expected) {
    EXPECT_FLOAT_EQ(components[0], expected.x());
    EXPECT_FLOAT_EQ(components[1], expected.y());
    EXPECT_FLOAT_EQ(components[2], expected.z());
}

void ExpectSegment(const SceneVertexArray& vertices, std::size_t quad, const Eigen::Vector3f& start,
                   const Eigen::Vector3f& end, float trail_length, float trail_position) {
    const float* vertex = QuadVertex(vertices, quad, 0);
    ExpectVec3(vertex + 0, start);
    ExpectVec3(vertex + 4, end);
    EXPECT_FLOAT_EQ(vertex[7], trail_length);
    EXPECT_FLOAT_EQ(vertex[11], trail_position);
}

void ExpectUvCorners(const SceneVertexArray& vertices, std::size_t quad, bool thick) {
    const std::size_t uv_offset             = thick ? 20 : 16;
    const float       expected[4][2]        = { { 0.0f, 1.0f },
                                                { 1.0f, 1.0f },
                                                { 1.0f, 0.0f },
                                                { 0.0f, 0.0f } };
    for (std::size_t vert = 0; vert < 4; ++vert) {
        const float* uv = QuadVertex(vertices, quad, vert) + uv_offset;
        EXPECT_FLOAT_EQ(uv[0], expected[vert][0]) << "vert " << vert;
        EXPECT_FLOAT_EQ(uv[1], expected[vert][1]) << "vert " << vert;
    }
}

void ExpectNoNaN(const SceneVertexArray& vertices) {
    const float* data = vertices.Data();
    for (std::size_t i = 0; i < vertices.CapacitySize(); ++i) {
        EXPECT_TRUE(std::isfinite(data[i])) << i;
    }
}

struct SlotSnap {
    Particle                   particle;
    uint32_t                   trail_count { 0 };
    uint32_t                   trail_capacity { 0 };
    std::vector<Eigen::Vector3f> trail;
};

class CapturingParticleRawGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances, SceneMesh&,
                   ParticleRawGenSpecOp&, ParticleRenderScale, ParticleOverflowFlags&) override {
        slots.clear();
        for (const auto& instance : instances) {
            if (! instance) continue;
            const auto particles = instance->Particles();
            const auto trails    = instance->Trails();
            for (std::size_t i = 0; i < particles.size(); ++i) {
                SlotSnap snap;
                snap.particle = particles[i];
                if (i < trails.size()) {
                    snap.trail_count    = trails[i].Count();
                    snap.trail_capacity = trails[i].Capacity();
                    snap.trail.reserve(snap.trail_count);
                    for (uint32_t age = 0; age < snap.trail_count; ++age) {
                        snap.trail.push_back(trails[i].At(age).position);
                    }
                }
                slots.push_back(std::move(snap));
            }
        }
    }

    std::vector<SlotSnap> slots;
};

std::unique_ptr<ParticleSubSystem> MakeTestSubsystem(ParticleSystem&            system,
                                                     std::shared_ptr<SceneMesh> mesh) {
    auto subsystem = std::make_unique<ParticleSubSystem>(
        system,
        std::move(mesh),
        8,
        1.0,
        1,
        1.0,
        ParticleSubSystem::SpawnType::STATIC,
        [](const Particle&, const ParticleRawGenSpec&) {
        });
    // A particle only moves inside a movement operator, as in a particle file:
    // this is the one the trail tests need to give their particles somewhere to go.
    subsystem->AddOperator([](const ParticleInfo& info) {
        for (auto& particle : info.particles) {
            if (ParticleModify::LifetimeOk(particle)) {
                ParticleModify::MoveByTime(particle, info.time_pass);
            }
        }
    });
    return subsystem;
}

TEST(ParticleRopeGeometry, ThreeLiveParticlesWithSubdivisionOneEmitTwoQuads) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { 10.0f, 0.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 20.0f, 0.0f, 0.0f }, 3.0f, 1.0f);
    ExpectUvCorners(vertices, 0, false);
}

TEST(ParticleRopeGeometry, DeadParticleBetweenLiveOnesIsSkippedAndNeighboursJoined) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       DeadAt({ 100.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    ExpectSegment(mesh.GetVertexArray(0), 0, { 0.0f, 0.0f, 0.0f }, { 20.0f, 0.0f, 0.0f }, 2.0f,
                  0.0f);
}

TEST(ParticleRopeGeometry, RopeQuadsNeverSpanInstances) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), LiveAt({ 1.0f, 0.0f, 0.0f }) }));
    instances.push_back(
        MakeInstance({ LiveAt({ 10.0f, 0.0f, 0.0f }), LiveAt({ 11.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { 1.0f, 0.0f, 0.0f }, 2.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 11.0f, 0.0f, 0.0f }, 2.0f, 0.0f);
}

TEST(ParticleRopeGeometry, ZeroAndOneLiveParticleEmitNoQuads) {
    ParticleRenderScale scale;
    scale.rope_subdivision = 1;

    {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({}));
        GenRope(instances, mesh, scale);
        EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    }
    {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({ LiveAt({ 1.0f, 2.0f, 3.0f }) }));
        GenRope(instances, mesh, scale);
        EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    }
}

TEST(ParticleRopeGeometry, SubdivisionThreeSplitsThreeParticlesIntoSixQuadsThroughTheMiddle) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    const Eigen::Vector3f a { 0.0f, 0.0f, 0.0f };
    const Eigen::Vector3f b { 10.0f, 0.0f, 0.0f };
    const Eigen::Vector3f c { 20.0f, 0.0f, 0.0f };
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt(a), LiveAt(b), LiveAt(c) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 3;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 6u * 3);
    const float* first  = QuadVertex(vertices, 0, 0);
    const float* fourth = QuadVertex(vertices, 3, 0);
    const float* last   = QuadVertex(vertices, 5, 0);
    ExpectVec3(first + 0, a);
    EXPECT_FLOAT_EQ(first[7], 7.0f);
    EXPECT_FLOAT_EQ(first[11], 0.0f);
    EXPECT_NEAR(fourth[0], b.x(), 1.0e-5f);
    EXPECT_NEAR(fourth[1], b.y(), 1.0e-5f);
    EXPECT_NEAR(fourth[2], b.z(), 1.0e-5f);
    EXPECT_FLOAT_EQ(fourth[7], 7.0f);
    EXPECT_FLOAT_EQ(fourth[11], 3.0f);
    EXPECT_NEAR(last[4], c.x(), 1.0e-5f);
    EXPECT_NEAR(last[5], c.y(), 1.0e-5f);
    EXPECT_NEAR(last[6], c.z(), 1.0e-5f);
}

TEST(ParticleRopeGeometry, CoincidentParticlesEmitNoQuadAndNoNaN) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(
        MakeInstance({ LiveAt({ 4.0f, 5.0f, 6.0f }), LiveAt({ 4.0f, 5.0f, 6.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    ExpectNoNaN(mesh.GetVertexArray(0));
}

TEST(ParticleRopeGeometry, ThickFormatWritesEndColourAndEndHalfSize) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true);

    Particle start = LiveAt({ 0.0f, 0.0f, 0.0f }, 8.0f);
    start.color    = { 1.0f, 0.0f, 0.0f };
    start.alpha    = 0.5f;
    Particle end   = LiveAt({ 10.0f, 0.0f, 0.0f }, 12.0f);
    end.color      = { 0.0f, 1.0f, 0.0f };
    end.alpha      = 0.25f;

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ start, end }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    const float* vertex = QuadVertex(mesh.GetVertexArray(0), 0, 0);
    EXPECT_FLOAT_EQ(vertex[3], 4.0f);
    EXPECT_FLOAT_EQ(vertex[15], 6.0f);
    EXPECT_FLOAT_EQ(vertex[16], 0.0f);
    EXPECT_FLOAT_EQ(vertex[17], 1.0f);
    EXPECT_FLOAT_EQ(vertex[18], 0.0f);
    EXPECT_FLOAT_EQ(vertex[19], 0.25f);
    EXPECT_FLOAT_EQ(vertex[24], 1.0f);
    EXPECT_FLOAT_EQ(vertex[25], 0.0f);
    EXPECT_FLOAT_EQ(vertex[26], 0.0f);
    EXPECT_FLOAT_EQ(vertex[27], 0.5f);
}

TEST(ParticleRopeGeometry, InstanceBoundedOffsetIsAddedToRopePositions) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    auto instance = MakeInstance({ LiveAt({ 1.0f, 2.0f, 3.0f }), LiveAt({ 4.0f, 5.0f, 6.0f }) });
    instance->GetBoundedData().pos = { 100.0f, 200.0f, 300.0f };

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    ExpectSegment(mesh.GetVertexArray(0), 0, { 101.0f, 202.0f, 303.0f },
                  { 104.0f, 205.0f, 306.0f }, 2.0f, 0.0f);
}

void PushOldestFirst(ParticleTrailHistory& history, std::initializer_list<Eigen::Vector3f> points) {
    for (const auto& point : points) {
        history.Push({ .position = point });
    }
}

TEST(ParticleRopeGeometry, RopeTrailEmitsQuadsFromCurrentPositionAlongRecordedPoints) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 30.0f, 0.0f }) });
    instance->TrailsVec().resize(1);
    instance->TrailsVec()[0].Reset(8);
    // Oldest first so At(0) is the newest recorded point.
    PushOldestFirst(instance->TrailsVec()[0],
                    { { 0.0f, 0.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, { 0.0f, 20.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 3u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 30.0f, 0.0f }, { 0.0f, 20.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 1, { 0.0f, 20.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, 3.0f, 1.0f);
    ExpectSegment(vertices, 2, { 0.0f, 10.0f, 0.0f }, { 0.0f, 0.0f, 0.0f }, 3.0f, 2.0f);
}

TEST(ParticleRopeGeometry, FullTrailHistoryMovesTheLastPointByTrailFraction) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 30.0f, 0.0f }) });
    instance->TrailsVec().resize(1);
    instance->TrailsVec()[0].Reset(3);
    PushOldestFirst(instance->TrailsVec()[0],
                    { { 0.0f, 0.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, { 0.0f, 20.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    scale.trail_fraction   = 0.5f;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 3u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 30.0f, 0.0f }, { 0.0f, 20.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 2, { 0.0f, 10.0f, 0.0f }, { 0.0f, 5.0f, 0.0f }, 3.0f, 2.0f);
}

TEST(ParticleRopeGeometry, EmptyHistoryAndDeadParticleDrawNothing) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), DeadAt({ 5.0f, 0.0f, 0.0f }) });
    instance->TrailsVec().resize(2);
    instance->TrailsVec()[0].Reset(4);
    instance->TrailsVec()[1].Reset(4);
    PushOldestFirst(instance->TrailsVec()[1],
                    { { 5.0f, 0.0f, 0.0f }, { 6.0f, 0.0f, 0.0f }, { 7.0f, 0.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
}

TEST(ParticleRopeGeometry, TwoParticlesTrailsAreNeverJoined) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance =
        MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), LiveAt({ 10.0f, 0.0f, 0.0f }) });
    instance->TrailsVec().resize(2);
    instance->TrailsVec()[0].Reset(4);
    instance->TrailsVec()[1].Reset(4);
    PushOldestFirst(instance->TrailsVec()[0], { { -1.0f, 0.0f, 0.0f } });
    PushOldestFirst(instance->TrailsVec()[1], { { 11.0f, 0.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { -1.0f, 0.0f, 0.0f }, 1.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 11.0f, 0.0f, 0.0f }, 1.0f, 0.0f);
}

// The recording clock and the frame clock are kept apart in these tests -- half
// a period per tick, in binary-exact numbers -- so a tick either records a point
// or does not, and a particle's birth point can be told from a recorded one.
TEST(ParticleTrailHistory, FirstTickRecordsBirthPosition) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();

    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 3.0f, 4.0f, 5.0f });
    EXPECT_FLOAT_EQ(cap->slots[0].particle.position.x(), 4.25f);
}

TEST(ParticleTrailHistory, LaterTicksAppendPointsUpToCapacityThenDropOldest) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    // The birth point on the first tick, then one recorded point on every
    // second tick, until the history is full and the oldest is dropped.
    for (int tick = 1; tick <= 10; ++tick) {
        subsystem->Emitt();
        ASSERT_EQ(cap->slots.size(), 1u) << tick;
        EXPECT_EQ(cap->slots[0].trail_count, static_cast<uint32_t>(std::min(1 + tick / 2, 4)))
            << tick;
    }
    ASSERT_EQ(cap->slots[0].trail.size(), 4u);
    for (const auto& point : cap->slots[0].trail) {
        EXPECT_FALSE(point.x() == 3.0f && point.y() == 4.0f && point.z() == 5.0f);
    }
}

TEST(ParticleTrailHistory, TrailPeriodFractionStaysInUnitInterval) {
    Scene scene;
    scene.frameTime = 0.1;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.1 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    for (int tick = 0; tick < 6; ++tick) {
        subsystem->Emitt();
        const float fraction = subsystem->TrailPeriodFraction();
        EXPECT_GE(fraction, 0.0f) << tick;
        EXPECT_LT(fraction, 1.0f) << tick;
    }
}

TEST(ParticleTrailHistory, ZeroFrameTimeRecordsNothing) {
    Scene scene;
    scene.frameTime = 0.1;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.1 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();
    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    const uint32_t count = cap->slots[0].trail_count;
    ASSERT_GE(count, 1u);

    scene.frameTime = 0.0;
    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    EXPECT_EQ(cap->slots[0].trail_count, count);
}

TEST(ParticleTrailHistory, RespawnedParticleRestartsTrailHistoryAtNewBirth) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    int spawn = 0;
    subsystem->AddEmitter([&spawn](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                   uint32_t, double, std::span<const ParticleControlpoint>) {
        for (const auto& particle : particles) {
            if (particle.lifetime > 0.0f) return;
        }
        Particle particle;
        if (spawn == 0) {
            ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
            ParticleModify::InitLifetime(particle, 0.15f);
        } else {
            ParticleModify::MoveTo(particle, 9.0, 8.0, 7.0);
            ParticleModify::InitLifetime(particle, 10.0f);
        }
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        if (particles.empty()) particles.emplace_back(particle);
        else particles[0] = particle;
        ++spawn;
    });

    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 3.0f, 4.0f, 5.0f });

    subsystem->Emitt();
    subsystem->Emitt();

    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 9.0f, 8.0f, 7.0f });
}

uint32_t IndexAt(const SceneIndexArray& array, usize i) {
    if (array.Width() == SceneIndexWidth::UInt32) return array.Data()[i];
    return reinterpret_cast<const uint16_t*>(array.Data())[i];
}

void ExpectQuadIndices(const SceneIndexArray& array, uint32_t quad) {
    const uint32_t base = quad * 4;
    const usize    at   = usize(quad) * 6;
    EXPECT_EQ(IndexAt(array, at + 0), base);
    EXPECT_EQ(IndexAt(array, at + 1), base + 1);
    EXPECT_EQ(IndexAt(array, at + 2), base + 3);
    EXPECT_EQ(IndexAt(array, at + 3), base + 1);
    EXPECT_EQ(IndexAt(array, at + 4), base + 2);
    EXPECT_EQ(IndexAt(array, at + 5), base + 3) << quad;
}

void AddSpriteParticleMesh(SceneMesh& mesh, uint32_t capacity) {
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITION.data(), VertexType::FLOAT3 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC2.data(), VertexType::FLOAT2 },
    };
    const auto layout = PlanParticleIndexLayout(capacity);
    mesh.AddVertexArray(SceneVertexArray(attrs, static_cast<std::size_t>(layout.vertex_count)));
    mesh.AddIndexArray(SceneIndexArray(capacity, layout.width));
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
}

std::unique_ptr<ParticleInstance> MakeLiveSprites(uint32_t count) {
    auto instance = std::make_unique<ParticleInstance>();
    auto& particles = instance->ParticlesVec();
    particles.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        particles.push_back(LiveAt({ float(i), 0.0f, 0.0f }));
    }
    return instance;
}

TEST(ParticleIndex, GeneratorKeepsPackedUInt16AtSixteenBitBoundary) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddSpriteParticleMesh(mesh, static_cast<uint32_t>(kMaxPackedUInt16Quads));
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeLiveSprites(static_cast<uint32_t>(kMaxPackedUInt16Quads)));
    ParticleRenderScale scale;
    GenRope(instances, mesh, scale); // GenGLData via existing helper name

    const auto& indices = mesh.GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt16);
    EXPECT_EQ(indices.DrawIndexCount(), kMaxPackedUInt16Quads * 6);
    ExpectQuadIndices(indices, 0);
    ExpectQuadIndices(indices, static_cast<uint32_t>(kMaxPackedUInt16Quads - 1));
    EXPECT_EQ(IndexAt(indices, (kMaxPackedUInt16Quads - 1) * 6 + 5), 65535u);
}

TEST(ParticleIndex, GeneratorWritesUInt32IndicesPastOldPackedLimit) {
    constexpr uint32_t kQuads = static_cast<uint32_t>(kMaxPackedUInt16Quads + 1);
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddSpriteParticleMesh(mesh, kQuads);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeLiveSprites(kQuads));
    ParticleRenderScale scale;
    GenRope(instances, mesh, scale);

    const auto& indices = mesh.GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt32);
    EXPECT_EQ(indices.DrawIndexCount(), uint64_t(kQuads) * 6);
    ExpectQuadIndices(indices, 0);
    ExpectQuadIndices(indices, kMaxPackedUInt16Quads);
    EXPECT_EQ(IndexAt(indices, kMaxPackedUInt16Quads * 6), 65536u);
}

TEST(ParticleIndex, GeneratorPreservesQuadOrderAcrossInstancesOnUInt32Mesh) {
    constexpr uint32_t kFirst  = 10000;
    constexpr uint32_t kSecond = static_cast<uint32_t>(kMaxPackedUInt16Quads + 1 - kFirst);
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddSpriteParticleMesh(mesh, kFirst + kSecond);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeLiveSprites(kFirst));
    instances.push_back(MakeLiveSprites(kSecond));
    ParticleRenderScale scale;
    GenRope(instances, mesh, scale);

    const auto& indices = mesh.GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt32);
    EXPECT_EQ(indices.DrawIndexCount(), uint64_t(kFirst + kSecond) * 6);
    ExpectQuadIndices(indices, 0);
    ExpectQuadIndices(indices, kFirst - 1);
    ExpectQuadIndices(indices, kFirst);
    ExpectQuadIndices(indices, kFirst + kSecond - 1);
}

float RopeShaderV(float trail_length, float trail_position, float mix_y) {
    const float usable = trail_length - 1.0f;
    const float uv_min = 1.0f - trail_position / usable;
    const float uv_delta = -1.0f / usable;
    return uv_min + uv_delta * mix_y;
}

TEST(ParticleRopeUv, ScaleDoublesRepeatsAlongTheRope) {
    auto span_for = [](float uv_scale, float* authored_length) {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                           LiveAt({ 10.0f, 0.0f, 0.0f }),
                                           LiveAt({ 20.0f, 0.0f, 0.0f }) }));
        ParticleRenderScale scale;
        scale.rope_subdivision = 1;
        scale.uv_scale         = uv_scale;
        GenRope(instances, mesh, scale);
        const auto& vertices = mesh.GetVertexArray(0);
        *authored_length     = QuadVertex(vertices, 0, 0)[7];
        const float* first = QuadVertex(vertices, 0, 0);
        const float* last  = QuadVertex(vertices, 1, 0);
        return RopeShaderV(first[7], first[11], 0.0f) - RopeShaderV(last[7], last[11], 1.0f);
    };
    float length1 = 0;
    float length2 = 0;
    EXPECT_NEAR(span_for(1.0f, &length1), 1.0f, 1.0e-5f);
    EXPECT_NEAR(span_for(2.0f, &length2), 2.0f, 1.0e-5f);
    EXPECT_FLOAT_EQ(length1, 3.0f);
    EXPECT_FLOAT_EQ(length2, 2.0f);
}

TEST(ParticleRopeUv, SubdivisionDoesNotIncreaseRepeats) {
    auto run = [](uint32_t subdiv) {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                           LiveAt({ 10.0f, 0.0f, 0.0f }),
                                           LiveAt({ 20.0f, 0.0f, 0.0f }) }));
        ParticleRenderScale scale;
        scale.rope_subdivision = subdiv;
        scale.uv_scale         = 2.0f;
        GenRope(instances, mesh, scale);
        const auto& vertices = mesh.GetVertexArray(0);
        const std::size_t quads = vertices.VertexCount() / 4;
        const float* first = QuadVertex(vertices, 0, 0);
        const float* last  = QuadVertex(vertices, quads - 1, 0);
        return RopeShaderV(first[7], first[11], 0.0f) - RopeShaderV(last[7], last[11], 1.0f);
    };
    EXPECT_NEAR(run(1), run(3), 1.0e-5f);
    EXPECT_NEAR(run(1), 2.0f, 1.0e-5f);
}

TEST(ParticleRopeUv, ScrollingUsesCapacityInsteadOfLiveCount) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));
    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    scale.uv_scrolling     = true;
    GenRope(instances, mesh, scale);
    const auto& vertices = mesh.GetVertexArray(0);
    EXPECT_FLOAT_EQ(QuadVertex(vertices, 0, 0)[7],
                    EncodeRopeTrailLength(static_cast<float>(kMeshCapacity) + 1.0f, 1.0f));
    EXPECT_NE(QuadVertex(vertices, 0, 0)[7], 3.0f);
}

TEST(ParticleRopeUv, SmoothingEasesInteriorTrailPosition) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }),
                                       LiveAt({ 30.0f, 0.0f, 0.0f }) }));
    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    scale.uv_smoothing     = true;
    GenRope(instances, mesh, scale);
    const auto& vertices = mesh.GetVertexArray(0);
    EXPECT_FLOAT_EQ(QuadVertex(vertices, 0, 0)[11], 0.0f);
    EXPECT_GT(QuadVertex(vertices, 1, 0)[11], 0.0f);
    EXPECT_LT(QuadVertex(vertices, 1, 0)[11], 1.0f);
}

TEST(ParticleRopeUv, WidthUStaysInUnitIntervalForAtlasDomain) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));
    ParticleRenderScale scale;
    scale.uv_scale = 4.0f;
    GenRope(instances, mesh, scale);
    ExpectUvCorners(mesh.GetVertexArray(0), 0, false);
    ExpectUvCorners(mesh.GetVertexArray(0), 1, false);
}

TEST(ParticleRopeUv, RuntimeScaleChangeRewritesLengthWithoutNewParticles) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));
    ParticleRenderScale scale;
    GenRope(instances, mesh, scale);
    EXPECT_FLOAT_EQ(QuadVertex(mesh.GetVertexArray(0), 0, 0)[7], 3.0f);
    scale.uv_scale = 2.0f;
    GenRope(instances, mesh, scale);
    EXPECT_FLOAT_EQ(QuadVertex(mesh.GetVertexArray(0), 0, 0)[7], 2.0f);
    ASSERT_EQ(instances[0]->Particles().size(), 3u);
}

// Forwards to the production generator and counts the calls, so a test can see
// both whether a frame generated geometry and what that geometry was.
class CountingParticleRawGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances, SceneMesh& mesh,
                   ParticleRawGenSpecOp& spec, ParticleRenderScale scale,
                   ParticleOverflowFlags& flags) override {
        ++calls;
        inner.GenGLData(instances, mesh, spec, scale, flags);
    }

    WPParticleRawGener inner;
    uint32_t           calls { 0 };
};

struct RevealRun {
    Scene                      scene;
    ParticleSystem             system { scene };
    std::shared_ptr<SceneMesh> mesh { std::make_shared<SceneMesh>(MeshUpdate::PerFrame) };
    std::shared_ptr<SceneNode> parent { std::make_shared<SceneNode>() };
    std::shared_ptr<SceneNode> owner { std::make_shared<SceneNode>() };
    CountingParticleRawGener*  gener { new CountingParticleRawGener() };

    RevealRun() {
        scene.frameTime = 0.125;
        system.gener.reset(gener);
        AddRopeParticleMesh(*mesh, kMeshCapacity, false, true);
        parent->AppendChild(owner);
        auto subsystem = MakeTestSubsystem(system, mesh);
        subsystem->SetTrail({ .samples = 4, .period = 0.25 });
        subsystem->SetOwnerNode(owner);
        // A particle is born on each of the first four frames, each moving at
        // its own speed, so the simulation state differs frame to frame.
        subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                 uint32_t, double, std::span<const ParticleControlpoint>) {
            if (particles.size() >= 4) return;
            const double i = double(particles.size());
            Particle     particle;
            ParticleModify::MoveTo(particle, i, 2.0 * i, 0.0);
            ParticleModify::InitVelocity(particle, 8.0 + i, 4.0 - i, 0.0);
            ParticleModify::InitLifetime(particle, 10.0f);
            particles.emplace_back(particle);
        });
        system.subsystems.push_back(std::move(subsystem));
    }

    // SceneWallpaper's frame order: Emitt, then the runtime Tick (scripts and
    // timelines, which may change visibility), then RebuildVisibleMeshes.
    template<typename Tick>
    void Frame(Tick&& tick) {
        system.Emitt();
        tick();
        system.RebuildVisibleMeshes();
    }

    std::vector<float> Vertices() const {
        const auto& vertices = mesh->GetVertexArray(0);
        return { vertices.Data(), vertices.Data() + vertices.CapacitySize() };
    }
};

// R16: a layer a script or timeline shows mid-run -- after Emitt already ran
// for the frame with it hidden -- draws on that first visible frame exactly
// the geometry an always-generating run has from the same simulation.
TEST(ParticleHiddenGeometry, LayerShownByTickAfterEmittDrawsWhatAlwaysGeneratingDraws) {
    for (const bool hide_parent : { false, true }) {
        SCOPED_TRACE(hide_parent ? "parent group hidden" : "layer hidden");
        RevealRun reference;
        RevealRun revealed;
        auto&     hidden_node = hide_parent ? revealed.parent : revealed.owner;
        hidden_node->SetVisible(false);

        const auto nothing = [] {};
        for (int frame = 0; frame < 5; ++frame) {
            reference.Frame(nothing);
            revealed.Frame(nothing);
        }
        EXPECT_EQ(revealed.gener->calls, 0u) << "a hidden layer generates no geometry";
        EXPECT_EQ(reference.gener->calls, 5u);

        // Frame 6: Emitt sees the layer hidden; the Tick that follows shows it.
        reference.Frame(nothing);
        revealed.Frame([&] { hidden_node->SetVisible(true); });
        EXPECT_EQ(revealed.gener->calls, 1u) << "the first visible frame regenerates once";
        EXPECT_EQ(revealed.mesh->GetIndexArray(0).RenderDataCount(),
                  reference.mesh->GetIndexArray(0).RenderDataCount());
        ASSERT_GT(reference.mesh->GetIndexArray(0).RenderDataCount(), 0u);
        EXPECT_EQ(revealed.Vertices(), reference.Vertices())
            << "the revealed mesh comes from the current simulation, trail history included";

        // Later visible frames stay identical and are generated once each.
        reference.Frame(nothing);
        revealed.Frame(nothing);
        EXPECT_EQ(revealed.gener->calls, 2u);
        EXPECT_EQ(revealed.Vertices(), reference.Vertices());
    }
}

} // namespace
} // namespace wallpaper
