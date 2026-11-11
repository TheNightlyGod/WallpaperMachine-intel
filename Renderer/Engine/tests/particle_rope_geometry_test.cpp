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

Particle LiveAt(const linalg::Vector3f& pos, float size = 20.0f, float lifetime = 1.0f) {
    Particle particle;
    particle.position = pos;
    particle.size     = size;
    particle.lifetime = lifetime;
    return particle;
}

void GenRope(std::vector<std::unique_ptr<ParticleInstance>>& instances, SceneMesh& mesh,
             ParticleRenderScale scale) {
    WPParticleRawGener     gener;
    ParticleRawGenSpecOp   spec = [](const Particle&, const ParticleRawGenSpec&) {
    };
    ParticleOverflowFlags flags;
    gener.GenGLData(instances, mesh, spec, scale, flags);
}

void ExpectVec3(const float* components, const linalg::Vector3f& expected) {
    EXPECT_FLOAT_EQ(components[0], expected.x());
    EXPECT_FLOAT_EQ(components[1], expected.y());
    EXPECT_FLOAT_EQ(components[2], expected.z());
}

struct SlotSnap {
    Particle                   particle;
    uint32_t                   trail_count { 0 };
    uint32_t                   trail_capacity { 0 };
    std::vector<linalg::Vector3f> trail;
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

// The recording clock and the frame clock are kept apart in these tests -- half
// a period per tick, in binary-exact numbers -- so a tick either records a point
// or does not, and a particle's birth point can be told from a recorded one. The
// clock is WE's countdown (0x1402308A0): it starts due, so the first tick records.
TEST(ParticleTrailHistory, FirstTickRecordsWhereTheParticleMovedAfterItsBirthPosition) {
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
    ASSERT_EQ(cap->slots[0].trail_count, 2u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 4.25f, 4.0f, 5.0f });
    ExpectVec3(cap->slots[0].trail[1].data(), { 3.0f, 4.0f, 5.0f });
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

    // The birth point, then one recorded point on the first tick and on every
    // second tick after it, until the history is full and the oldest is dropped.
    for (int tick = 1; tick <= 10; ++tick) {
        subsystem->Emitt();
        ASSERT_EQ(cap->slots.size(), 1u) << tick;
        EXPECT_EQ(cap->slots[0].trail_count, static_cast<uint32_t>(std::min(1 + (tick + 1) / 2, 4)))
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
    ASSERT_EQ(cap->slots[0].trail_count, 2u);
    ExpectVec3(cap->slots[0].trail[1].data(), { 3.0f, 4.0f, 5.0f });

    subsystem->Emitt();
    subsystem->Emitt();

    // Born again on the third tick, which records where it moved to.
    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 2u);
    ExpectVec3(cap->slots[0].trail[1].data(), { 9.0f, 8.0f, 7.0f });
    ExpectVec3(cap->slots[0].trail[0].data(), { 10.25f, 8.0f, 7.0f });
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

} // namespace
} // namespace wallpaper
