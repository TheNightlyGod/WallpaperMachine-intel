#include "Particle/ParticleEmitter.h"
#include "Interface/IParticleRawGener.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPParticleParser.hpp"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <set>
#include <vector>

namespace wallpaper
{
namespace
{

class CapturingParticleRawGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                   SceneMesh&,
                   ParticleRawGenSpecOp&,
                   ParticleRenderScale render_scale,
                   ParticleOverflowFlags&) override {
        last_render_scale = render_scale;
        particles.clear();
        for (const auto& instance : instances) {
            if (instance) {
                const auto instanceParticles = instance->Particles();
                particles.insert(particles.end(), instanceParticles.begin(), instanceParticles.end());
            }
        }
    }

    std::vector<Particle> particles;
    ParticleRenderScale   last_render_scale;
};

std::unique_ptr<ParticleSubSystem> MakeTestSubsystem(ParticleSystem& system,
                                                     std::shared_ptr<SceneMesh> mesh,
                                                     ParticleRawGenSpecOp spec = {}) {
    if (! spec) {
        spec = [](const Particle&, const ParticleRawGenSpec&) {
        };
    }
    return std::make_unique<ParticleSubSystem>(system,
                                               std::move(mesh),
                                               8,
                                               1.0,
                                               1,
                                               1.0,
                                               ParticleSubSystem::SpawnType::STATIC,
                                               std::move(spec));
}

TEST(ParticleMouseControlpoint, AWorldspaceLayersMatrixScalesTheVelocityInitializersDraw) {
    // The engine hands the spawning emitter's control point matrix, which carries
    // a worldspace layer's rotation and scale, to the velocity initializers: a
    // layer stretched along x launches its particles faster along x. A layer-space
    // system, whose layer draws its particles, leaves the velocity as authored.
    const nlohmann::json json {
        { "name", "velocityrandom" },
        { "min", { 2.0f, 2.0f, 0.0f } },
        { "max", { 2.0f, 2.0f, 0.0f } },
    };
    for (const bool world : { true, false }) {
        SCOPED_TRACE(world);
        auto spawn              = std::make_shared<ParticleSpawnContext>();
        spawn->world_linear     = linalg::Vector3d(24.0, 1.0, 1.0).asDiagonal();
        spawn->has_world_linear = world;
        ParticleParseContext ctx;
        ctx.spawn = spawn;
        auto init = WPParticleParser::genParticleInitOp(json, ctx);

        Particle particle;
        init(particle, 0.0);
        EXPECT_NEAR(particle.velocity.x(), world ? 48.0f : 2.0f, 1.0e-4f);
        EXPECT_NEAR(particle.velocity.y(), 2.0f, 1.0e-4f);
    }
}

TEST(ParticleMouseControlpoint, AWorldspaceSystemsControlpointsAreWhereItsLayersMatrixPutsThem) {
    // A worldspace system measures from its layer's origin along the scene's own
    // axes. Wallpaper Engine multiplies the layer's matrix into the control
    // point matrices of such a system, so an authored offset is turned and scaled
    // by the layer. The one exception is a control point pinned to the world
    // (flag 2, never the first), whose matrix is left as authored: it is a place
    // in the scene, so its offset is that place less the layer's origin, and the
    // layer's turn and scale are no part of it. A cursor-linked control point is
    // the cursor's place less the origin.
    Scene scene;
    scene.ortho[0]        = 200;
    scene.ortho[1]        = 100;
    scene.frameTime       = 1.0;
    scene.pointerPosition = { 0.75f, 0.25f };
    ParticleSystem system(scene);
    auto subsystem = MakeTestSubsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame));
    subsystem->SetDrawn(false);
    subsystem->SetWorldSpace(true);
    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate(linalg::Vector3f(100.0f, 50.0f, 0.0f));
    owner->SetScale(linalg::Vector3f(2.0f, 3.0f, 1.0f));
    owner->SetRotation(linalg::Vector3f(0.0f, 0.0f, static_cast<float>(M_PI / 2.0)));
    subsystem->SetOwnerNode(owner);

    auto controlpoints = subsystem->Controlpoints();
    // The flag on the first control point does not pin it.
    controlpoints[0].worldspace   = true;
    controlpoints[0].base_offset  = linalg::Vector3d(1.0, 2.0, 0.0);
    controlpoints[1].worldspace   = true;
    controlpoints[1].base_offset  = linalg::Vector3d(500.0, 400.0, 0.0);
    controlpoints[2].base_offset  = linalg::Vector3d(10.0, 0.0, 0.0);
    controlpoints[3].link_mouse   = true;
    controlpoints[3].base_offset  = linalg::Vector3d(1.0, 2.0, 3.0);

    subsystem->Emitt();

    // Scaled by (2, 3), then a quarter turn: (x, y) -> (-y, x).
    EXPECT_NEAR(controlpoints[0].offset.x(), -6.0, 1.0e-5);
    EXPECT_NEAR(controlpoints[0].offset.y(), 2.0, 1.0e-5);
    EXPECT_NEAR(controlpoints[2].offset.x(), 0.0, 1.0e-5);
    EXPECT_NEAR(controlpoints[2].offset.y(), 20.0, 1.0e-5);
    // The pinned one: the scene place 500, 400 seen from the layer's origin.
    EXPECT_NEAR(controlpoints[1].offset.x(), 400.0, 1.0e-9);
    EXPECT_NEAR(controlpoints[1].offset.y(), 350.0, 1.0e-9);
    // The cursor at 150, 75 seen from the layer's origin, plus the authored offset.
    EXPECT_NEAR(controlpoints[3].offset.x(), 51.0, 1.0e-9);
    EXPECT_NEAR(controlpoints[3].offset.y(), 27.0, 1.0e-9);
    EXPECT_NEAR(controlpoints[3].offset.z(), 3.0, 1.0e-9);

    // Whose matrix carries the layer's: every control point but the pinned one.
    EXPECT_TRUE(controlpoints[0].has_world_linear);
    EXPECT_FALSE(controlpoints[1].has_world_linear);
    EXPECT_TRUE(controlpoints[2].has_world_linear);
    EXPECT_TRUE(controlpoints[3].has_world_linear);
    owner->UpdateTrans();
    const linalg::Matrix3d linear = owner->ModelTrans().topLeftCorner<3, 3>();
    EXPECT_TRUE(controlpoints[2].world_linear.isApprox(linear, 1.0e-9));
}

TEST(ParticleMouseControlpoint, AWorldspaceEmitterOnAPinnedControlpointIsNotStretchedByItsLayer) {
    // An emitter takes the matrix of the control point it names, for the offset
    // it places a particle at and, handed on, for the velocity initializers. On
    // the first or an ordinary control point that matrix carries the layer of a
    // worldspace system, so a layer 24 times wider than tall spreads the spawns 24
    // times wider and launches them 24 times faster along x. On a control point
    // pinned to the world it does not: the layer's scale touches neither.
    struct Case {
        bool   pinned;
        double spread;
        double velocity_x;
    };
    for (const auto& [pinned, spread, velocity_x] :
         { Case { true, 5.0, 2.0 }, Case { false, 120.0, 48.0 } }) {
        SCOPED_TRACE(pinned);
        Scene scene;
        scene.frameTime = 1.0 / 60.0;
        ParticleSystem system(scene);
        auto subsystem = MakeTestSubsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame));
        subsystem->SetDrawn(false);
        subsystem->SetWorldSpace(true);
        auto owner = std::make_shared<SceneNode>();
        owner->SetTranslate(linalg::Vector3f(100.0f, 50.0f, 0.0f));
        owner->SetScale(linalg::Vector3f(24.0f, 1.0f, 1.0f));
        subsystem->SetOwnerNode(owner);
        auto controlpoints          = subsystem->Controlpoints();
        controlpoints[1].worldspace = pinned;
        controlpoints[1].base_offset =
            pinned ? linalg::Vector3d(500.0, 400.0, 0.0) : linalg::Vector3d(10.0, 0.0, 0.0);

        ParticleBoxEmitterArgs args {};
        args.directions    = { 1.0f, 0.0f, 0.0f };
        args.minDistance   = { 5.0f, 0.0f, 0.0f };
        args.maxDistance   = { 5.0f, 0.0f, 0.0f };
        args.emitSpeed     = 1.0f;
        args.instantaneous = 1;
        args.controlpoint  = 1;
        args.spawn         = subsystem->SpawnContext();
        subsystem->AddEmitter(ParticleBoxEmitterArgs::MakeEmittOp(args));
        subsystem->AddInitializer([](Particle& particle, double) {
            ParticleModify::InitLifetime(particle, 10.0f);
        });
        ParticleParseContext ctx;
        ctx.spawn = subsystem->SpawnContext();
        subsystem->AddInitializer(WPParticleParser::genParticleInitOp(
            { { "name", "velocityrandom" }, { "min", { 2.0f, 2.0f, 0.0f } },
              { "max", { 2.0f, 2.0f, 0.0f } } },
            ctx));

        subsystem->Emitt();

        ASSERT_EQ(subsystem->Instances().size(), 1u);
        const auto particles = subsystem->Instances().front()->Particles();
        ASSERT_EQ(particles.size(), 1u);
        // The control point's place seen from the layer's origin: the pinned
        // one at 400 across, the ordinary one 24 times its authored 10.
        const double centre = pinned ? 400.0 : 240.0;
        EXPECT_NEAR(std::abs(particles[0].position.x() - centre), spread, 1.0e-3);
        EXPECT_NEAR(particles[0].velocity.x(), velocity_x, 1.0e-3);
        EXPECT_NEAR(particles[0].velocity.y(), 2.0, 1.0e-3);
    }
}

// `randomframe` sprites read this value; an integral one always chose frame 0.
TEST(ParticleMouseControlpoint, SpawnedParticlesCarryAnIndependentFrameValueSpreadOverTheSheet) {
    ParticleSphereEmitterArgs args {};
    args.directions    = { 1.0f, 1.0f, 1.0f };
    args.minDistance   = 3.0f;
    args.maxDistance   = 18.0f;
    args.emitSpeed     = 1.0f;
    args.instantaneous = 256;
    auto                        emitter = ParticleSphereEmitterArgs::MakeEmittOp(args);
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers;
    emitter(particles, initializers, 256, 0.0, {});
    ASSERT_EQ(particles.size(), 256u);
    std::array<int, 13> frames {};
    for (const auto& particle : particles) {
        ASSERT_GE(particle.init.frame, 0.0f);
        ASSERT_LT(particle.init.frame, 1.0f);
        ++frames[static_cast<std::size_t>(particle.init.frame * frames.size())];
    }
    for (const int count : frames) EXPECT_GT(count, 0);

    // A draw of its own for every particle: identical spawns still get
    // different frames, so a sheet of identical sprites is not all one frame.
    ParticleBoxEmitterArgs fixed {};
    fixed.directions    = { 0.0f, 0.0f, 0.0f };
    fixed.emitSpeed     = 1.0f;
    fixed.orgin         = { 1.0f, 2.0f, 3.0f };
    fixed.instantaneous = 64;
    std::array<ParticleControlpoint, 8> controlpoints {};
    auto                emitter_fixed = ParticleBoxEmitterArgs::MakeEmittOp(fixed);
    std::vector<Particle>       identical;
    std::vector<ParticleInitOp> none;
    emitter_fixed(identical, none, 64, 0.0, controlpoints);
    ASSERT_EQ(identical.size(), 64u);
    std::set<float> distinct;
    for (const auto& particle : identical) distinct.insert(particle.init.frame);
    EXPECT_GT(distinct.size(), 32u);
    // The same value serves every operator that varies a particle against its neighbours.
    for (const auto& particle : identical) EXPECT_EQ(particle.seed, particle.init.frame);
}

class ParticleEmitterAudio : public testing::TestWithParam<const char*> {
protected:
    ParticleEmittOp MakeEmitter(nlohmann::json fields) {
        fields["name"] = GetParam();
        fields["id"]   = 1;
        wpscene::Emitter authored;
        EXPECT_TRUE(authored.FromJson(fields));
        return WPParticleParser::genParticleEmittOp(authored, false, nullptr, [this]() {
            return spectrum;
        });
    }

    void Emit(ParticleEmittOp& emitter, double duration) {
        emitter(particles, initializers, 128, duration, {});
    }

    audio::AudioSpectrumSnapshot spectrum;
    std::vector<Particle>        particles;
    std::vector<ParticleInitOp>  initializers { [](Particle& particle, double) {
        ParticleModify::InitLifetime(particle, 1000.0f);
    } };
};

TEST_P(ParticleEmitterAudio, SilenceDiscardsPendingEmissionAcrossAudioTransitions) {
    auto emitter = MakeEmitter({
        { "audioprocessingmode", 3 },
        { "audioprocessingbounds", "0 1" },
        { "audioprocessingexponent", 1 },
        { "rate", 4.0f },
    });
    Emit(emitter, 100.0);
    EXPECT_TRUE(particles.empty());
    spectrum.average16.fill(0.5f);
    Emit(emitter, 0.25);
    EXPECT_TRUE(particles.empty());
    spectrum = {};
    Emit(emitter, 100.0);
    EXPECT_TRUE(particles.empty());
    spectrum.average16.fill(0.5f);
    Emit(emitter, 0.25);
    EXPECT_TRUE(particles.empty());
    Emit(emitter, 0.25);
    EXPECT_EQ(particles.size(), 1u);
    spectrum = {};
    Emit(emitter, 100.0);
    EXPECT_EQ(particles.size(), 1u);
    spectrum.average16.fill(1.0f);
    Emit(emitter, 0.25);
    EXPECT_EQ(particles.size(), 2u);
}

TEST_P(ParticleEmitterAudio, SelectedInclusiveBandsApplyBoundsThenExponent) {
    auto emitter = MakeEmitter({
        { "audioprocessingmode", 3 },
        { "audioprocessingbounds", { 0.25f, 0.75f } },
        { "audioprocessingexponent", 2 },
        { "audioprocessingfrequencystart", 4 },
        { "audioprocessingfrequencyend", 5 },
        { "rate", 8.0f },
    });
    spectrum.average16.fill(1.0f);
    spectrum.average16[4] = spectrum.average16[5] = 0.0f;
    Emit(emitter, 1.0);
    EXPECT_TRUE(particles.empty());
    // The loudest selected band decides, not their mean: .5 -> bounds midpoint
    // .5 -> smoothstep .5 -> exponent .25, so two of the eight a second.
    spectrum.average16[4] = 0.25f;
    spectrum.average16[5] = 0.5f;
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 2u);
    spectrum.average16[4] = 0.75f;
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 10u);
    spectrum.average16[4] = spectrum.average16[5] = 0.25f;
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 10u);
    // A band outside the selection does not count however loud it is.
    spectrum.average16[3] = spectrum.average16[6] = 1.0f;
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 10u);
}

TEST_P(ParticleEmitterAudio, DisabledAudioModePreservesOrdinaryEmission) {
    auto emitter = MakeEmitter({ { "audioprocessingmode", 0 }, { "rate", 4.0f } });
    Emit(emitter, 0.25);
    EXPECT_EQ(particles.size(), 1u);
    spectrum.average16.fill(1.0f);
    Emit(emitter, 0.25);
    EXPECT_EQ(particles.size(), 2u);
    spectrum = {};
    Emit(emitter, 0.25);
    EXPECT_EQ(particles.size(), 3u);
}

TEST_P(ParticleEmitterAudio, OnePerFrameAndInstantaneousCannotBypassSilence) {
    auto emitter = MakeEmitter({
        { "audioprocessingmode", 3 },
        { "audioprocessingbounds", "0 1" },
        { "audioprocessingexponent", 0 },
        { "rate", 4.0f },
        { "instantaneous", 10 },
        { "flags", 2 },
    });
    Emit(emitter, 100.0);
    EXPECT_TRUE(particles.empty());
    spectrum.average16.fill(1.0f);
    Emit(emitter, 0.01);
    EXPECT_EQ(particles.size(), 1u);
    Emit(emitter, 0.01);
    EXPECT_EQ(particles.size(), 1u);
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 2u);
    particles.clear();
    spectrum = {};
    Emit(emitter, 100.0);
    EXPECT_TRUE(particles.empty());
    spectrum.average16.fill(1.0f);
    Emit(emitter, 0.01);
    EXPECT_TRUE(particles.empty());
}

TEST_P(ParticleEmitterAudio, InstantaneousQuantityScalesOnceWithAudio) {
    auto emitter = MakeEmitter({
        { "audioprocessingmode", 3 },
        { "audioprocessingbounds", "0 1" },
        { "audioprocessingexponent", 1 },
        { "rate", 0.0f },
        { "instantaneous", 8 },
    });
    Emit(emitter, 10.0);
    EXPECT_TRUE(particles.empty());
    spectrum.average16.fill(0.5f);
    Emit(emitter, 1.0);
    EXPECT_EQ(particles.size(), 4u);
    particles.clear();
    spectrum = {};
    Emit(emitter, 10.0);
    spectrum.average16.fill(1.0f);
    Emit(emitter, 1.0);
    EXPECT_TRUE(particles.empty());
}

TEST_P(ParticleEmitterAudio, ChannelModesSelectTheirOwnSpectrum) {
    auto left           = MakeEmitter({
        { "audioprocessingmode", 1 },
        { "audioprocessingbounds", "0 1" },
        { "audioprocessingexponent", 1 },
        { "audioprocessingfrequencystart", 15 },
        { "audioprocessingfrequencyend", 15 },
        { "rate", 4.0f },
    });
    auto right          = MakeEmitter({
        { "audioprocessingmode", 2 },
        { "audioprocessingbounds", "0 1" },
        { "audioprocessingexponent", 1 },
        { "audioprocessingfrequencystart", 15 },
        { "audioprocessingfrequencyend", 15 },
        { "rate", 4.0f },
    });
    spectrum.left16[15] = 1.0f;
    Emit(right, 1.0);
    EXPECT_TRUE(particles.empty());
    Emit(left, 1.0);
    EXPECT_EQ(particles.size(), 4u);
    spectrum.left16[15]  = 0.0f;
    spectrum.right16[15] = 1.0f;
    Emit(left, 1.0);
    EXPECT_EQ(particles.size(), 4u);
    Emit(right, 1.0);
    EXPECT_EQ(particles.size(), 8u);
}

TEST_P(ParticleEmitterAudio, MissingAudioSourceNeverEmits) {
    wpscene::Emitter authored;
    ASSERT_TRUE(authored.FromJson({
        { "name", GetParam() },
        { "id", 1 },
        { "audioprocessingmode", 3 },
        { "instantaneous", 8 },
        { "flags", 2 },
        { "rate", 4.0f },
    }));
    auto emitter = WPParticleParser::genParticleEmittOp(authored);
    Emit(emitter, 100.0);
    EXPECT_TRUE(particles.empty());
}

INSTANTIATE_TEST_SUITE_P(BoxAndSphere, ParticleEmitterAudio,
                         testing::Values("boxrandom", "sphererandom"));

/// A particle born at `born` (its life `position` of the way through) after the
/// initializer that carries the instance's size override and the operators that
/// shape its size over its life.
float SizeAfter(const std::shared_ptr<const wpscene::ParticleInstanceoverride>& override,
                const std::vector<nlohmann::json>& ramps, float born, double position,
                bool size_applies = true) {
    auto init = WPParticleParser::genOverrideInitOp(override, {}, true, size_applies);
    ParticleParseContext ctx;
    ctx.over          = override;
    ctx.size_override = size_applies;

    std::array<Particle, 1> particles {};
    ParticleModify::InitLifetime(particles[0], 10.0f);
    ParticleModify::InitSize(particles[0], born);
    init(particles[0], 0.0);
    ParticleModify::Reset(particles[0]);
    particles[0].lifetime = static_cast<float>((1.0 - position) * 10.0);
    ParticleInfo info {
        .particles     = particles,
        .controlpoints = {},
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    for (const auto& ramp : ramps) WPParticleParser::genParticleOperatorOp(ramp, ctx)(info);
    return particles[0].size;
}

std::shared_ptr<wpscene::ParticleInstanceoverride> SizeOverride(float size) {
    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->size    = size;
    return override;
}

nlohmann::json Ramp(double starttime, double endtime, double startvalue, double endvalue) {
    return { { "name", "sizechange" },
             { "starttime", starttime },
             { "endtime", endtime },
             { "startvalue", startvalue },
             { "endvalue", endvalue } };
}

TEST(ParticleMouseControlpoint, ASizeOverrideScalesTheBirthSizeAndEverySizeRamp) {
    // Wallpaper Engine's loader gives every size record of a particle file a
    // binding to the instance's `size` override (tag 0xcc of the bindings
    // FUN_1401d15a0 applies): a `sizerandom` draw is multiplied by it, and so
    // are the start and the change of each `sizechange` ramp. A ramp therefore
    // scales the running size by `override * ramp`, and a particle born at 40
    // under n ramps that each hold 0.5 is 40 * override * (0.5 * override)^n.
    for (const float size_override : { 1.0f, 2.5f, 0.4f }) {
        for (const int ramps : { 0, 1, 2, 3 }) {
            SCOPED_TRACE(::testing::Message() << "override " << size_override << ", " << ramps << " ramps");
            const std::vector<nlohmann::json> list(static_cast<std::size_t>(ramps), Ramp(0.0, 1.0, 0.5, 0.5));
            const float expected = 40.0f * size_override * std::pow(0.5f * size_override, ramps);
            EXPECT_NEAR(SizeAfter(SizeOverride(size_override), list, 40.0f, 0.5), expected,
                        1.0e-4f * std::max(1.0f, expected));
        }
    }
}

TEST(ParticleMouseControlpoint, EachSizeRampScalesTheRunningSizeByItsOwnValueTimesTheOverride) {
    // The petal preset: one ramp from 0 to 1 over the first 5 percent of the
    // life, another from 1 to 0 from 20 percent on. Both multiply the size the
    // earlier ones left, and the override reaches each: at a given moment the
    // size is born * override * (override * first) * (override * second).
    const std::vector<nlohmann::json> petal { Ramp(0.0, 0.05, 0.0, 1.0), Ramp(0.2, 1.0, 1.0, 0.0) };
    const auto first  = [](double t) { return std::clamp(t / 0.05, 0.0, 1.0); };
    const auto second = [](double t) { return 1.0 - std::clamp((t - 0.2) / 0.8, 0.0, 1.0); };
    for (const float size_override : { 1.0f, 1.27f, 0.6f }) {
        for (const double t : { 0.0, 0.025, 0.05, 0.1, 0.2, 0.6, 1.0 }) {
            SCOPED_TRACE(::testing::Message() << "override " << size_override << " at " << t);
            const double o        = size_override;
            const double expected = 30.0 * o * (o * first(t)) * (o * second(t));
            EXPECT_NEAR(SizeAfter(SizeOverride(size_override), petal, 30.0f, t), expected, 1.0e-4 * std::max(1.0, expected));
        }
    }
}

TEST(ParticleMouseControlpoint, AFileThatIgnoresTheSizeOverrideKeepsItOutOfTheBirthSizeAndEveryRamp) {
    // The binding the loader creates for a size record is skipped when the
    // file's flags carry bit 128 (the editor's "ignore size override"), for the
    // `sizerandom` draw and the `sizechange` ramps alike.
    const std::vector<nlohmann::json> two { Ramp(0.0, 1.0, 0.5, 0.5), Ramp(0.0, 1.0, 0.5, 0.5) };
    for (const float size_override : { 1.0f, 2.5f, 0.4f }) {
        SCOPED_TRACE(size_override);
        EXPECT_NEAR(SizeAfter(SizeOverride(size_override), two, 40.0f, 0.5, false), 10.0f, 1.0e-4f);
        EXPECT_NEAR(SizeAfter(SizeOverride(size_override), {}, 40.0f, 0.5, false), 40.0f, 1.0e-4f);
    }
}

TEST(ParticleMouseControlpoint, ControlpointAttractFallsOffLinearlyToTheThreshold) {
    nlohmann::json json {
        { "name", "controlpointattract" },
        { "controlpoint", 1 },
        { "scale", 10.0f },
        { "threshold", 4.0f },
        // Wallpaper Engine's executor never reads the operator's own origin.
        { "origin", { 2.0f, 0.0f, 0.0f } },
    };

    WPParticleParser parser;
    auto             op = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[1].offset = linalg::Vector3d(3.0, 0.0, 0.0);

    std::array<Particle, 1> particles {};
    ParticleModify::MoveTo(particles[0], 0.0, 0.0, 0.0);

    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    op(info);

    // Three away of a threshold of four: a quarter of the strength.
    EXPECT_NEAR(particles[0].velocity.x(), 2.5f, 1.0e-5f);

    // At the threshold and beyond there is no pull; at the control point the
    // distance is zero and nothing is divided by it.
    particles[0].velocity = linalg::Vector3f::Zero();
    ParticleModify::MoveTo(particles[0], -1.0, 0.0, 0.0);
    op(info);
    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.0f);

    json["threshold"] = 6.0f;
    op                = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());
    particles[0].velocity = linalg::Vector3f::Zero();
    ParticleModify::MoveTo(particles[0], 0.0, 0.0, 0.0);
    op(info);
    EXPECT_NEAR(particles[0].velocity.x(), 5.0f, 1.0e-5f);

    // The misspelt key some files carry is still read as the threshold.
    json.erase("threshold");
    json["threadhold"] = 4.0f;
    op                 = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());
    particles[0].velocity = linalg::Vector3f::Zero();
    op(info);
    EXPECT_NEAR(particles[0].velocity.x(), 2.5f, 1.0e-5f);
}

TEST(ParticleMouseControlpoint, ControlpointAttractNamesTheLastControlpointForAnyIndexPastTheRange) {
    // Wallpaper Engine keeps 0..6 and sends everything else, negative values
    // included, to the last control point.
    for (const int index : { -1, 7, 8, 100 }) {
        nlohmann::json json {
            { "name", "controlpointattract" },
            { "controlpoint", index },
            { "scale", 10.0f },
            { "threshold", 20.0f },
        };

        WPParticleParser parser;
        auto             op = parser.genParticleOperatorOp(
            json,
            std::make_shared<wpscene::ParticleInstanceoverride>());

        std::array<ParticleControlpoint, 8> controlpoints {};
        controlpoints[0].offset = linalg::Vector3d(-10.0, 0.0, 0.0);
        controlpoints[7].offset = linalg::Vector3d(10.0, 0.0, 0.0);

        std::array<Particle, 1> particles {};
        ParticleModify::MoveTo(particles[0], 0.0, 0.0, 0.0);

        ParticleInfo info {
            .particles     = particles,
            .controlpoints = controlpoints,
            .time          = 0.0,
            .time_pass     = 1.0,
        };
        op(info);

        EXPECT_NEAR(particles[0].velocity.x(), 5.0f, 1.0e-5f) << "index " << index;
    }
}

TEST(ParticleMouseControlpoint, ControlpointAttractSkipsZeroDistance) {
    nlohmann::json json {
        { "name", "controlpointattract" },
        { "controlpoint", 1 },
        { "scale", 10.0f },
        { "threshold", 6.0f },
    };

    WPParticleParser parser;
    auto             op = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[1].offset = linalg::Vector3d(5.0, 0.0, 0.0);

    std::array<Particle, 1> particles {};
    ParticleModify::MoveTo(particles[0], 5.0, 0.0, 0.0);

    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    op(info);

    EXPECT_TRUE(std::isfinite(particles[0].velocity.x()));
    EXPECT_TRUE(std::isfinite(particles[0].velocity.y()));
    EXPECT_TRUE(std::isfinite(particles[0].velocity.z()));
    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.0f);
}

// A wallpaper is cropped onto a display whose aspect is not its canvas's, so
// the window shows only part of the canvas. Stretching the window-normalized
// pointer across the whole canvas agrees with the cursor at the centre of the
// window and is wrong by half the cropped-away span at either edge -- a mouse
// trail that tracks in the middle of the screen and slides away toward the
// sides.
TEST(ParticleMouseControlpoint, MouseControlpointFollowsTheCroppedPresentation) {
    Scene scene;
    scene.ortho[0]  = 200;
    scene.ortho[1]  = 100;
    scene.frameTime = 1.0;

    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 200,
        .canvas_height = 100,
    });
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(&scene);
    // 40 canvas units cropped off each side: the window shows x in [40, 160].
    runtime->SetCursorViewport(CursorViewport {
        .origin         = linalg::Vector2f(40.0f, 0.0f),
        .size           = linalg::Vector2f(120.0f, 100.0f),
        .content_origin = linalg::Vector2f(0.0f, 0.0f),
        .content_size   = linalg::Vector2f(200.0f, 100.0f),
    });

    auto              mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem    system(scene);
    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    auto controlpoints          = subsystem.Controlpoints();
    controlpoints[0].link_mouse = true;

    // Dead centre: the crop is symmetric, so this is the one place the canvas
    // product happens to be right. A fix that moved this would be moving every
    // mouse-linked wallpaper that is not cropped at all.
    scene.pointerPosition = { 0.5f, 0.5f };
    runtime->SetCursorInput(0.5f, 0.5f);
    subsystem.UpdateMouseControlpoints();
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.x(), 100.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.y(), 50.0);

    // Right edge of the window. The canvas product says 200; the window's
    // right edge is canvas x = 160, which is where the cursor actually is.
    scene.pointerPosition = { 1.0f, 0.5f };
    runtime->SetCursorInput(1.0f, 0.5f);
    subsystem.UpdateMouseControlpoints();
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.x(), 160.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.y(), 50.0);

    scene.pointerPosition = { 0.0f, 0.5f };
    runtime->SetCursorInput(0.0f, 0.5f);
    subsystem.UpdateMouseControlpoints();
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.x(), 40.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.y(), 50.0);
}

TEST(ParticleMouseControlpoint, UnlinkedControlpointsKeepEveryAuthoredOffset) {
    Scene scene;
    scene.ortho[0] = 200;
    scene.ortho[1] = 100;
    scene.pointerPosition = { 0.75f, 0.25f };
    ParticleSystem system(scene);
    auto subsystem = MakeTestSubsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame));
    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate(linalg::Vector3f(100.0f, 50.0f, 0.0f));
    subsystem->SetOwnerNode(owner);
    auto controlpoints = subsystem->Controlpoints();
    std::array<linalg::Vector3d, 8> authored;
    for (std::size_t i = 0; i < controlpoints.size(); ++i) {
        authored[i] = linalg::Vector3d(double(i + 1), double(i + 11), double(i + 21));
        controlpoints[i].base_offset = linalg::Vector3d::Zero();
        controlpoints[i].offset = authored[i];
    }
    subsystem->UpdateMouseControlpoints();
    scene.pointerPosition = { 0.0f, 1.0f };
    owner->SetScale(linalg::Vector3f(2.0f, 3.0f, 1.0f));
    subsystem->UpdateMouseControlpoints();
    for (std::size_t i = 0; i < controlpoints.size(); ++i) {
        EXPECT_EQ(controlpoints[i].offset, authored[i]) << i;
    }
}

TEST(ParticleMouseControlpoint, RuntimeLinksFollowAncestorChangesWithStationaryPointer) {
    Scene scene;
    scene.ortho[0] = 200;
    scene.ortho[1] = 100;
    scene.pointerPosition = { 0.75f, 0.25f };
    ParticleSystem system(scene);
    auto subsystem = MakeTestSubsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame));
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(linalg::Vector3f(100.0f, 20.0f, 0.0f));
    parent->SetScale(linalg::Vector3f(2.0f, 1.0f, 1.0f));
    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate(linalg::Vector3f(10.0f, 5.0f, 0.0f));
    owner->SetScale(linalg::Vector3f(1.0f, 2.0f, 1.0f));
    parent->AppendChild(owner);
    subsystem->SetOwnerNode(owner);
    auto controlpoints = subsystem->Controlpoints();
    auto& cp = controlpoints.back();
    cp.base_offset = linalg::Vector3d(1.0, 2.0, 3.0);
    cp.offset = linalg::Vector3d(9.0, 8.0, 7.0);
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(9.0, 8.0, 7.0));
    cp.link_mouse = true;
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(16.0, 27.0, 3.0));
    parent->SetTranslate(linalg::Vector3f(80.0f, 40.0f, 0.0f));
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(26.0, 17.0, 3.0));
    cp.link_mouse = false;
    parent->SetTranslate(linalg::Vector3f::Zero());
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(26.0, 17.0, 3.0));
    cp.link_mouse = true;
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(66.0, 37.0, 3.0));
    for (std::size_t i = 0; i + 1 < controlpoints.size(); ++i) {
        EXPECT_EQ(controlpoints[i].offset, linalg::Vector3d::Zero());
    }
}

TEST(ParticleMouseControlpoint, MissingAndExpiredOwnersUseWorldCoordinates) {
    Scene scene;
    scene.ortho[0] = 200;
    scene.ortho[1] = 100;
    scene.pointerPosition = { 0.75f, 0.25f };
    ParticleSystem system(scene);
    auto subsystem = MakeTestSubsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame));
    auto& cp = subsystem->Controlpoints()[3];
    cp.link_mouse = true;
    cp.base_offset = linalg::Vector3d(1.0, 2.0, 3.0);
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(151.0, 77.0, 3.0));
    {
        auto owner = std::make_shared<SceneNode>();
        owner->SetTranslate(linalg::Vector3f(100.0f, 0.0f, 0.0f));
        subsystem->SetOwnerNode(owner);
        subsystem->UpdateMouseControlpoints();
        EXPECT_EQ(cp.offset, linalg::Vector3d(51.0, 77.0, 3.0));
    }
    subsystem->UpdateMouseControlpoints();
    EXPECT_EQ(cp.offset, linalg::Vector3d(151.0, 77.0, 3.0));
}

TEST(ParticleMouseControlpoint, MovementOperatorReadsRuntimeMutatedSpeedOverride) {
    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->speed   = 2.0f;

    auto op = WPParticleParser::genParticleOperatorOp(
        nlohmann::json {
            { "name", "movement" },
            { "gravity", { 1.0f, 0.0f, 0.0f } },
            { "drag", 0.0f },
        },
        override);

    std::array<ParticleControlpoint, 8> controlpoints {};
    std::array<Particle, 1>             particles {};
    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };

    op(info);
    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 2.0f);

    override->speed = 0.5f;
    particles[0].velocity = linalg::Vector3f::Zero();
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.5f);
}

TEST(ParticleMouseControlpoint, SubsystemRateOverrideControlsInitialEmissionTiming) {
    Scene scene;
    scene.frameTime = 1.0;

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                0.5,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    subsystem.SetRateMultiplier([] {
        return 2.0;
    });
    subsystem.AddEmitter(WPParticleParser::genParticleEmittOp(wpscene::Emitter {
        .instantaneous = 0,
        .name          = "boxrandom",
        .rate          = 1.0f,
    }));
    subsystem.AddInitializer([](Particle& particle, double) {
        ParticleModify::InitLifetime(particle, 10.0f);
    });

    subsystem.Emitt();

    ASSERT_EQ(rawGener->particles.size(), 1u);
}

} // namespace
} // namespace wallpaper
