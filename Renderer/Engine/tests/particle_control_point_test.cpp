// Control points in the particle simulation: where an emitter measures from, how a world-space
// layer stretches what it spawns, how a control point linked to the pointer is placed, and in
// which order the operators of one step see the particles.
//
// CPU only, no geometry: the subsystem is stepped and its particles inspected directly.

#include "Particle/ParticleEmitter.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Scene/Scene.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "WPParticleParser.hpp"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <array>
#include <cmath>
#include <memory>
#include <span>
#include <vector>

using namespace wallpaper;

namespace
{

// A scene, a particle system without a generator, and one static subsystem stepped by one
// second per Emitt().
struct StepRig {
    Scene              scene;
    ParticleSystem     system { scene };
    ParticleSubSystem* subsystem { nullptr };

    StepRig() {
        scene.frameTime = 1.0;
        auto made       = std::make_unique<ParticleSubSystem>(
            system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 8, 1.0, 1, 1.0,
            ParticleSubSystem::SpawnType::STATIC, [](const Particle&, const ParticleRawGenSpec&) {});
        subsystem = made.get();
        system.subsystems.push_back(std::move(made));
    }

    const Particle& OnlyParticle() const {
        const auto& instances = subsystem->Instances();
        EXPECT_FALSE(instances.empty());
        const auto slots = instances.front()->Particles();
        EXPECT_EQ(slots.size(), 1u);
        return slots[0];
    }
};

// Calls an emitter once, as the subsystem would, with its own set of eight control points.
std::vector<Particle> EmitOnce(const ParticleEmittOp& emitter,
                               const std::array<ParticleControlpoint, 8>& points) {
    std::vector<Particle>       slots;
    std::vector<ParticleInitOp> initializers;
    emitter(slots, initializers, 8, 1.0, points);
    return slots;
}

ParticleBoxEmitterArgs BurstOfOne() {
    ParticleBoxEmitterArgs args {};
    args.emitSpeed     = 1.0f;
    args.instantaneous = 1;
    args.orgin         = { 10.0f, 20.0f, 30.0f };
    return args;
}

// An emitter that adds a single particle once, heading along +x from the origin.
ParticleEmittOp SingleRunner(float lifetime, bool place_at_origin) {
    return [lifetime, place_at_origin](std::vector<Particle>& slots, std::vector<ParticleInitOp>&,
                                       uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! slots.empty()) return;
        Particle p;
        if (place_at_origin) ParticleModify::MoveTo(p, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(p, 1.0, 0.0, 0.0);
        ParticleModify::InitLifetime(p, lifetime);
        slots.push_back(p);
    };
}

ParticleOperatorOp OperatorFrom(const char* json_text) {
    return WPParticleParser::genParticleOperatorOp(
        nlohmann::json::parse(json_text), std::make_shared<wpscene::ParticleInstanceoverride>());
}

constexpr const char* kAttractTowardsPointZero =
    R"({"name":"controlpointattract","controlpoint":0,"scale":2,"threshold":20})";

} // namespace

// PE-01
TEST(ParticleControlPoints, WorldSpaceMatrixStretchesPlacementAndHeadingButNotSpeed) {
    std::array<ParticleControlpoint, 8> points {};
    points[0].world_linear     = linalg::Matrix3d::Identity();
    points[0].world_linear(0, 0) = 24.0;
    points[0].has_world_linear = true;

    for (int repetition = 0; repetition < 8; ++repetition) {
        SCOPED_TRACE(testing::Message() << "repetition " << repetition);
        ParticleBoxEmitterArgs args {};
        args.directions    = { 1.0f, 1.0f, 0.0f };
        args.minDistance   = { 5.0f, 5.0f, 0.0f };
        args.maxDistance   = { 5.0f, 5.0f, 0.0f };
        args.emitSpeed     = 1.0f;
        args.orgin         = { 10.0f, 20.0f, 30.0f };
        args.instantaneous = 1;
        args.minSpeed      = 3.0f;
        args.maxSpeed      = 3.0f;
        const auto slots   = EmitOnce(ParticleBoxEmitterArgs::MakeEmittOp(args), points);

        ASSERT_EQ(slots.size(), 2u) << "one particle paid by the rate, one by the burst";
        for (const Particle& p : slots) {
            EXPECT_EQ(std::abs(p.position.x() - 10.0f), 120.0f) << "5 stretched by 24";
            EXPECT_EQ(std::abs(p.position.y() - 20.0f), 5.0f);
            EXPECT_EQ(p.position.z(), 30.0f);
            EXPECT_NEAR(p.velocity.norm(), 3.0f, 1e-5f) << "the matrix does not change the speed";
            EXPECT_NEAR(std::abs(p.velocity.x()) / std::abs(p.velocity.y()), 24.0f, 1e-3f)
                << "the heading is that of the stretched offset";
        }
    }
}

TEST(ParticleControlPoints, WorldMatrixIsIgnoredWhileItsFlagIsClear) {
    std::array<ParticleControlpoint, 8> points {};
    points[0].world_linear       = linalg::Matrix3d::Identity();
    points[0].world_linear(0, 0) = 24.0;
    points[0].has_world_linear   = false;

    for (int repetition = 0; repetition < 8; ++repetition) {
        ParticleBoxEmitterArgs args {};
        args.directions    = { 1.0f, 1.0f, 0.0f };
        args.minDistance   = { 5.0f, 5.0f, 0.0f };
        args.maxDistance   = { 5.0f, 5.0f, 0.0f };
        args.emitSpeed     = 1.0f;
        args.orgin         = { 10.0f, 20.0f, 30.0f };
        args.instantaneous = 1;
        args.minSpeed      = 3.0f;
        args.maxSpeed      = 3.0f;
        const auto slots   = EmitOnce(ParticleBoxEmitterArgs::MakeEmittOp(args), points);
        ASSERT_FALSE(slots.empty());
        for (const Particle& p : slots) {
            EXPECT_EQ(std::abs(p.position.x() - 10.0f), 5.0f);
            EXPECT_EQ(std::abs(p.position.y() - 20.0f), 5.0f);
            EXPECT_NEAR(std::abs(p.velocity.x()) / std::abs(p.velocity.y()), 1.0f, 1e-5f);
        }
    }
}

// PE-02
TEST(ParticleControlPoints, EmitterMeasuresFromTheControlPointItNames) {
    std::array<ParticleControlpoint, 8> points {};
    points[2].offset = { 5.0, 6.0, 7.0 };

    ParticleBoxEmitterArgs args = BurstOfOne();
    args.controlpoint           = 2;
    auto slots                  = EmitOnce(ParticleBoxEmitterArgs::MakeEmittOp(args), points);
    ASSERT_FALSE(slots.empty());
    EXPECT_EQ(slots[0].position.x(), 15.0f);
    EXPECT_EQ(slots[0].position.y(), 26.0f);
    EXPECT_EQ(slots[0].position.z(), 37.0f);

    // A negative index names the last point.
    points[7].offset  = { 1.0, 1.0, 1.0 };
    args.controlpoint = -1;
    slots             = EmitOnce(ParticleBoxEmitterArgs::MakeEmittOp(args), points);
    ASSERT_FALSE(slots.empty());
    EXPECT_EQ(slots[0].position.x(), 11.0f);
    EXPECT_EQ(slots[0].position.y(), 21.0f);
    EXPECT_EQ(slots[0].position.z(), 31.0f);

    // An index past the array names no point: the emitter's own origin is all there is.
    args.controlpoint = 9;
    slots             = EmitOnce(ParticleBoxEmitterArgs::MakeEmittOp(args), points);
    ASSERT_FALSE(slots.empty());
    EXPECT_EQ(slots[0].position.x(), 10.0f);
    EXPECT_EQ(slots[0].position.y(), 20.0f);
    EXPECT_EQ(slots[0].position.z(), 30.0f);
}

// PM-01
TEST(ParticleControlPoints, MouseLinkedPointFollowsThePointerInCanvasUnits) {
    StepRig rig;
    rig.scene.ortho[0]        = 200;
    rig.scene.ortho[1]        = 100;
    rig.scene.pointerPosition = { 0.75f, 0.25f };

    auto points         = rig.subsystem->Controlpoints();
    points[0].link_mouse  = true;
    points[0].base_offset = { 1.0, 2.0, 3.0 };
    points[0].offset      = points[0].base_offset;
    points[1].link_mouse  = false;
    points[1].offset      = { 7.0, 8.0, 9.0 };

    rig.subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(points[0].offset.x(), 151.0);
    EXPECT_EQ(points[0].offset.y(), 77.0) << "the pointer's y runs upward";
    EXPECT_EQ(points[0].offset.z(), 3.0);
    EXPECT_EQ(points[1].offset, linalg::Vector3d(7.0, 8.0, 9.0)) << "an unlinked point is left alone";

    // When the presentation reports where the pointer is in the scene, that answer wins.
    rig.scene.pointerScenePosition = std::array<float, 2> { 20.0f, 30.0f };
    rig.subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(points[0].offset.x(), 21.0);
    EXPECT_EQ(points[0].offset.y(), 32.0);
    EXPECT_EQ(points[0].offset.z(), 3.0);
    EXPECT_EQ(points[1].offset, linalg::Vector3d(7.0, 8.0, 9.0));
}

// PM-02
TEST(ParticleControlPoints, MouseLinkedPointIsTakenIntoTheOwnersLocalSpace) {
    StepRig rig;
    rig.scene.ortho[0]        = 200;
    rig.scene.ortho[1]        = 100;
    rig.scene.pointerPosition = { 0.75f, 0.25f };

    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate({ 100.0f, 50.0f, 0.0f });
    owner->SetScale({ 2.0f, 1.0f, 1.0f });
    rig.subsystem->SetOwnerNode(owner);

    auto points          = rig.subsystem->Controlpoints();
    points[0].link_mouse  = true;
    points[0].base_offset = { 1.0, 2.0, 3.0 };
    points[0].offset      = points[0].base_offset;

    rig.subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(points[0].offset.x(), 26.0) << "(150 - 100) / 2 + 1";
    EXPECT_EQ(points[0].offset.y(), 27.0) << "75 - 50 + 2";
    EXPECT_EQ(points[0].offset.z(), 3.0);

    // A world-space system only measures from the layer's origin.
    rig.subsystem->SetWorldSpace(true);
    rig.subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(points[0].offset.x(), 51.0) << "150 - 100 + 1";
    EXPECT_EQ(points[0].offset.y(), 27.0);
    EXPECT_EQ(points[0].offset.z(), 3.0);
}

// PX-01
TEST(ParticleControlPoints, MovementThenAttractionAddsThePullAfterTheParticleHasMoved) {
    StepRig rig;
    rig.subsystem->Controlpoints()[0].offset = { 10.0, 0.0, 0.0 };
    rig.subsystem->AddEmitter(SingleRunner(2.0f, /*place_at_origin=*/true));
    rig.subsystem->AddOperator(OperatorFrom(R"({"name":"movement","gravity":[0,0,0],"drag":0})"));
    rig.subsystem->AddOperator(OperatorFrom(kAttractTowardsPointZero));

    rig.subsystem->Emitt();
    const Particle& p = rig.OnlyParticle();
    EXPECT_NEAR(p.position.x(), 1.0f, 1e-5f) << "movement carried it by its own velocity";
    // The pull is measured from where the particle stands after moving: distance 9 of 20.
    EXPECT_NEAR(p.velocity.x(), 2.1f, 1e-5f);
}

TEST(ParticleControlPoints, AttractionOutsideItsThresholdLeavesTheVelocityAlone) {
    StepRig rig;
    rig.subsystem->Controlpoints()[0].offset = { 10.0, 0.0, 0.0 };
    rig.subsystem->AddEmitter(SingleRunner(2.0f, /*place_at_origin=*/true));
    rig.subsystem->AddOperator(OperatorFrom(R"({"name":"movement","gravity":[0,0,0],"drag":0})"));
    rig.subsystem->AddOperator(
        OperatorFrom(R"({"name":"controlpointattract","controlpoint":0,"scale":2,"threshold":5})"));

    rig.subsystem->Emitt();
    const Particle& p = rig.OnlyParticle();
    EXPECT_NEAR(p.position.x(), 1.0f, 1e-5f);
    EXPECT_NEAR(p.velocity.x(), 1.0f, 1e-5f);
}

// PX-02
TEST(ParticleControlPoints, AttractionThenMovementIntegratesThePullInTheSameStep) {
    StepRig rig;
    rig.subsystem->Controlpoints()[0].offset = { 10.0, 0.0, 0.0 };
    rig.subsystem->AddEmitter(SingleRunner(2.0f, /*place_at_origin=*/false));
    rig.subsystem->AddOperator(OperatorFrom(kAttractTowardsPointZero));
    rig.subsystem->AddOperator(OperatorFrom(R"({"name":"movement","drag":0})"));

    rig.subsystem->Emitt();
    const Particle& p = rig.OnlyParticle();
    EXPECT_NEAR(p.velocity.x(), 2.0f, 1e-5f) << "distance 10 of 20 pulls with strength 1";
    EXPECT_NEAR(p.position.x(), 2.0f, 1e-5f) << "movement then carried it by the new velocity";
}
