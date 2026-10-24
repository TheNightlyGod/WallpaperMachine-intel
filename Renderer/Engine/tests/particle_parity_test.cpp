// How particle systems behave where Wallpaper Engine 2.8.42 defines it: spawn
// distributions, emitter schedules, initializer draws, operator maths, the
// prewarm, event followers, and the renderer records of a particle file. Every
// case builds its fixture from JSON in the test; none depends on a local scene.
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Audio/SoundManager.h"
#include "Interface/IParticleRawGener.h"
#include "Interface/IShaderValueUpdater.h"
#include "Particle/ParticleEmitter.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPParticleParser.hpp"
#include "WPSceneParser.hpp"
#include "support/byte_fs.hpp"
#include "wpscene/WPParticleObject.h"
#include "wpscene/WPScene.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <numeric>
#include <set>
#include <span>
#include <string>
#include <vector>

namespace wallpaper
{
namespace
{
namespace PM = ParticleModify;
using nlohmann::json;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The text files of a fixture as the byte map the in-memory file space serves.
test::MapFs::Files FilesAsBytes(const std::map<std::string, std::string>& files) {
    test::MapFs::Files bytes;
    for (const auto& [name, content] : files) bytes[name].assign(content.begin(), content.end());
    return bytes;
}

/// A generator that builds no geometry: the tests read the simulation itself.
class SilentGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>>, SceneMesh&,
                   ParticleRawGenSpecOp&, ParticleRenderScale, ParticleOverflowFlags&) override {}
};

std::vector<Particle> LiveParticles(const ParticleInstance& instance) {
    std::vector<Particle> live;
    for (const auto& p : instance.Particles()) {
        if (PM::LifetimeOk(p)) live.push_back(p);
    }
    return live;
}

wpscene::Emitter ParseEmitter(json fields) {
    fields["id"] = 1;
    wpscene::Emitter emitter;
    EXPECT_TRUE(emitter.FromJson(fields));
    return emitter;
}

/// `count` particles from one emitter in a single step, each living a long time.
std::vector<Particle> SpawnBurst(json emitter, std::size_t count,
                                 std::span<const ParticleControlpoint> controlpoints = {}) {
    emitter["instantaneous"] = count;
    emitter["rate"]          = 0;
    auto                        op = WPParticleParser::genParticleEmittOp(ParseEmitter(emitter));
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers { [](Particle& particle, double) {
        PM::InitLifetime(particle, 1000.0f);
    } };
    op(particles, initializers, static_cast<uint32_t>(count + 8), 0.0, controlpoints);
    return particles;
}

/// Runs one emitter for `steps` steps of `dt` and returns how many particles
/// each step added.
std::vector<std::size_t> EmissionPerStep(json emitter, int steps, double dt,
                                         uint32_t maxcount = 100000) {
    auto                        op = WPParticleParser::genParticleEmittOp(ParseEmitter(std::move(emitter)));
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers { [](Particle& particle, double) {
        PM::InitLifetime(particle, 1000.0f);
    } };
    std::vector<std::size_t> added;
    std::size_t              before = 0;
    for (int i = 0; i < steps; ++i) {
        op(particles, initializers, maxcount, dt, {});
        added.push_back(particles.size() - before);
        before = particles.size();
    }
    return added;
}

double Mean(const std::vector<double>& values) {
    return std::accumulate(values.begin(), values.end(), 0.0) / static_cast<double>(values.size());
}

std::shared_ptr<const wpscene::ParticleInstanceoverride> NoOverride() {
    return std::make_shared<wpscene::ParticleInstanceoverride>();
}

ParticleOperatorOp MakeOperator(json fields,
                                std::shared_ptr<const wpscene::ParticleInstanceoverride> over = nullptr) {
    return WPParticleParser::genParticleOperatorOp(fields, over ? over : NoOverride());
}

ParticleOperatorOp MakeOperatorIn(json fields, const ParticleParseContext& ctx) {
    return WPParticleParser::genParticleOperatorOp(fields, ctx);
}

/// The context of a particle file that sets the "ignore speed override" flag.
ParticleParseContext IgnoringSpeedOverride(std::shared_ptr<const wpscene::ParticleInstanceoverride> over) {
    ParticleParseContext ctx;
    ctx.over           = std::move(over);
    ctx.speed_override = false;
    return ctx;
}

/// Runs an operator once over `particles`.
template<std::size_t N>
void RunOperator(const ParticleOperatorOp& op, std::array<Particle, N>& particles, double dt,
                 const std::array<ParticleControlpoint, 8>& controlpoints = {}, double time = 0.0) {
    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = time,
        .time_pass     = dt,
    };
    op(info);
}

Particle LivingParticle(float lifetime = 10.0f) {
    Particle p;
    PM::InitLifetime(p, lifetime);
    return p;
}

// ---------------------------------------------------------------------------
// Spawn distributions
// ---------------------------------------------------------------------------

TEST(ParticleSpawn, SphereWithAFlatDirectionsFillsTowardTheCentreLikeABallSeenFromAbove) {
    // A point of a uniform ball, flattened by directions (1 1 0): its distance
    // from the centre has CDF 1 - (1 - a^2)^1.5, mean 3*pi/16.
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 0 },
                                        { "distancemax", 1 },
                                        { "directions", "1 1 0" } },
                                      20000);
    ASSERT_EQ(particles.size(), 20000u);
    std::vector<double> radius;
    std::size_t         inner = 0;
    for (const auto& p : particles) {
        EXPECT_FLOAT_EQ(p.position.z(), 0.0f);
        const double r = p.position.norm();
        radius.push_back(r);
        if (r < 0.5) ++inner;
    }
    EXPECT_NEAR(Mean(radius), 3.0 * M_PI / 16.0, 0.01);
    EXPECT_NEAR(static_cast<double>(inner) / 20000.0, 1.0 - std::pow(0.75, 1.5), 0.02);
}

TEST(ParticleSpawn, SphereWithEveryDirectionNonZeroIsAUniformBall) {
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 0 },
                                        { "distancemax", 1 },
                                        { "directions", "1 1 1" } },
                                      20000);
    std::vector<double> radius;
    for (const auto& p : particles) radius.push_back(p.position.norm());
    EXPECT_NEAR(Mean(radius), 0.75, 0.01);
}

TEST(ParticleSpawn, SphereStretchesWithTheMagnitudeOfDirections) {
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 0 },
                                        { "distancemax", 1 },
                                        { "directions", "2 2 0" } },
                                      4000);
    double farthest = 0.0;
    for (const auto& p : particles) farthest = std::max<double>(farthest, p.position.norm());
    EXPECT_GT(farthest, 1.5);
    EXPECT_LE(farthest, 2.0 + 1.0e-4);
}

TEST(ParticleSpawn, SphereKeepsEveryParticleBetweenItsMinimumAndMaximumDistance) {
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 5 },
                                        { "distancemax", 9 },
                                        { "directions", "1 1 1" } },
                                      2000);
    for (const auto& p : particles) {
        EXPECT_GE(p.position.norm(), 5.0f - 1.0e-4f);
        EXPECT_LE(p.position.norm(), 9.0f + 1.0e-4f);
    }
}

TEST(ParticleSpawn, SphereVelocityPointsAwayFromTheCentre) {
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 2 },
                                        { "distancemax", 6 },
                                        { "directions", "1 1 1" },
                                        { "speedmin", 10 },
                                        { "speedmax", 10 } },
                                      500);
    for (const auto& p : particles) {
        EXPECT_NEAR(p.velocity.norm(), 10.0f, 1.0e-3f);
        EXPECT_GT(p.velocity.dot(p.position), 0.0f);
    }
}

TEST(ParticleSpawn, ParticlesSpawnedOnTheCentreStillLeaveAlongARandomDirection) {
    // Nothing separates the spawn point from the centre: the direction is
    // drawn instead of being the zero vector.
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 0 },
                                        { "distancemax", 0 },
                                        { "directions", "1 1 0" },
                                        { "speedmin", 10 },
                                        { "speedmax", 10 } },
                                      200);
    std::set<float> distinct;
    for (const auto& p : particles) {
        EXPECT_NEAR(p.velocity.norm(), 10.0f, 1.0e-3f);
        distinct.insert(p.velocity.x());
    }
    EXPECT_GT(distinct.size(), 100u);
}

TEST(ParticleSpawn, ConeNarrowsTheSphereAboutThePositiveXAxis) {
    for (const float cone : { 0.5f, 1.0f }) {
        const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                            { "distancemin", 1 },
                                            { "distancemax", 1 },
                                            { "directions", "1 1 1" },
                                            { "cone", cone } },
                                          2000);
        for (const auto& p : particles) {
            EXPECT_GE(p.position.x(), -1.0e-4f) << "cone " << cone;
            if (cone == 1.0f) {
                EXPECT_NEAR(p.position.y(), 0.0f, 1.0e-4f);
                EXPECT_NEAR(p.position.z(), 0.0f, 1.0e-4f);
                EXPECT_NEAR(p.position.x(), 1.0f, 1.0e-4f);
            }
        }
    }
}

TEST(ParticleSpawn, SphereSignForcesTheSignOfAnAxis) {
    const auto particles = SpawnBurst({ { "name", "sphererandom" },
                                        { "distancemin", 1 },
                                        { "distancemax", 4 },
                                        { "directions", "1 1 1" },
                                        { "sign", "0 -1 0" } },
                                      500);
    for (const auto& p : particles) EXPECT_LE(p.position.y(), 0.0f);
}

TEST(ParticleSpawn, BoxFoldsANegativeMinimumOntoASymmetricRange) {
    // min -600, max 600, directions 0.5: |s| < .5 gives distances from the
    // centre of (-600 + 1200 |s|) on the sign of s, which covers -600..600.
    const auto particles = SpawnBurst({ { "name", "boxrandom" },
                                        { "distancemin", "-600 -600 0" },
                                        { "distancemax", "600 600 0" },
                                        { "directions", "0.5 0.5 0" } },
                                      20000);
    std::vector<double> magnitude;
    double              lowest = 0.0, highest = 0.0;
    for (const auto& p : particles) {
        lowest  = std::min<double>(lowest, p.position.x());
        highest = std::max<double>(highest, p.position.x());
        magnitude.push_back(std::abs(p.position.x()));
    }
    EXPECT_GT(lowest, -600.0 - 1.0e-3);
    EXPECT_LT(highest, 600.0 + 1.0e-3);
    EXPECT_LT(lowest, -550.0);
    EXPECT_GT(highest, 550.0);
    EXPECT_NEAR(Mean(magnitude), 300.0, 10.0);
}

TEST(ParticleSpawn, BoxWithPositiveMinimumLeavesTheCentreEmptyOnBothSides) {
    const auto particles = SpawnBurst({ { "name", "boxrandom" },
                                        { "distancemin", "100 0 0" },
                                        { "distancemax", "300 0 0" },
                                        { "directions", "1 0 0" } },
                                      5000);
    bool left = false, right = false;
    for (const auto& p : particles) {
        EXPECT_GE(std::abs(p.position.x()), 100.0f - 1.0e-3f);
        EXPECT_LE(std::abs(p.position.x()), 300.0f + 1.0e-3f);
        (p.position.x() < 0 ? left : right) = true;
    }
    EXPECT_TRUE(left);
    EXPECT_TRUE(right);
}

TEST(ParticleSpawn, BoxWithoutAMinimumIsUnchanged) {
    const auto particles = SpawnBurst({ { "name", "boxrandom" },
                                        { "distancemin", "0 0 0" },
                                        { "distancemax", "10 20 0" },
                                        { "directions", "1 1 0" } },
                                      5000);
    for (const auto& p : particles) {
        EXPECT_LE(std::abs(p.position.x()), 10.0f + 1.0e-4f);
        EXPECT_LE(std::abs(p.position.y()), 20.0f + 1.0e-4f);
        EXPECT_EQ(p.position.z(), 0.0f);
    }
}

TEST(ParticleSpawn, ControlpointOrientationTurnsTheSpawnOfAnEmitterThatNamesIt) {
    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[2].offset       = linalg::Vector3d(100.0, 0.0, 0.0);
    controlpoints[2].rotation     = linalg::AngleAxisd(M_PI / 2.0, linalg::Vector3d::UnitZ()).toRotationMatrix();
    controlpoints[2].has_rotation = true;
    const auto particles = SpawnBurst({ { "name", "boxrandom" },
                                        { "distancemin", "-1 0 0" },
                                        { "distancemax", "10 0 0" },
                                        { "directions", "1 0 0" },
                                        { "origin", "0 5 0" },
                                        { "controlpoint", 2 } },
                                      200,
                                      controlpoints);
    for (const auto& p : particles) {
        // The offset along x is turned onto y; the control point's translation
        // and the emitter's own origin are added, neither of them turned.
        EXPECT_NEAR(p.position.x(), 100.0f, 1.0e-3f);
        EXPECT_GE(p.position.y(), 5.0f - 10.0f - 1.0e-3f);
        EXPECT_LE(p.position.y(), 5.0f + 10.0f + 1.0e-3f);
    }
    // The first control point never turns a spawn.
    controlpoints[0].offset       = linalg::Vector3d(100.0, 0.0, 0.0);
    controlpoints[0].rotation     = controlpoints[2].rotation;
    controlpoints[0].has_rotation = true;
    const auto first              = SpawnBurst({ { "name", "boxrandom" },
                                                 { "distancemin", "0 0 0" },
                                                 { "distancemax", "10 0 0" },
                                                 { "directions", "1 0 0" },
                                                 { "controlpoint", 0 } },
                                               200,
                                               controlpoints);
    for (const auto& p : first) EXPECT_NEAR(p.position.y(), 0.0f, 1.0e-3f);
}

TEST(ParticleSpawn, EveryParticleCarriesItsOwnSeed) {
    const auto particles = SpawnBurst({ { "name", "boxrandom" }, { "directions", "0 0 0" } }, 256);
    std::set<float> seeds;
    for (const auto& p : particles) {
        EXPECT_GE(p.seed, 0.0f);
        EXPECT_LT(p.seed, 1.0f);
        seeds.insert(p.seed);
    }
    EXPECT_GT(seeds.size(), 200u);
}

// ---------------------------------------------------------------------------
// Emitter schedule
// ---------------------------------------------------------------------------

TEST(EmitterSchedule, OnePerFrameFollowsTheRateInsteadOfFiringEveryFrame) {
    // Rate 1 at 60 fps: one particle a second, and none on the first frame.
    const auto added = EmissionPerStep(
        { { "name", "boxrandom" }, { "rate", 1 }, { "flags", 2 }, { "directions", "0 0 0" } },
        130,
        1.0 / 60.0);
    EXPECT_EQ(added.front(), 0u);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 58, std::size_t { 0 }), 0u);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 65, std::size_t { 0 }), 1u);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 100, std::size_t { 0 }), 1u);
    EXPECT_EQ(std::accumulate(added.begin(), added.end(), std::size_t { 0 }), 2u);
}

TEST(EmitterSchedule, OnePerFrameNeverEmitsMoreThanOneAFrameWhateverTheRate) {
    const auto added = EmissionPerStep(
        { { "name", "boxrandom" }, { "rate", 600 }, { "flags", 2 }, { "directions", "0 0 0" } },
        30,
        1.0 / 60.0);
    for (const auto n : added) EXPECT_EQ(n, 1u);
}

TEST(EmitterSchedule, TheRateDoesNotChangeWithoutTheFlag) {
    const auto added = EmissionPerStep(
        { { "name", "boxrandom" }, { "rate", 600 }, { "directions", "0 0 0" } }, 30, 1.0 / 60.0);
    for (const auto n : added) EXPECT_EQ(n, 10u);
}

TEST(EmitterSchedule, ABurstRidesWithTheRateAndIsPaidForOutOfIt) {
    // Rate 10 with a burst of 5, ten steps of a tenth: the burst and the first
    // rate particle arrive together, and the stream resumes once the account
    // the burst overdrew is back in credit.
    const auto added = EmissionPerStep({ { "name", "boxrandom" },
                                         { "rate", 10 },
                                         { "instantaneous", 5 },
                                         { "directions", "0 0 0" } },
                                       8,
                                       0.125 * 0.8);
    EXPECT_EQ(added[0], 6u);
    for (int i = 1; i < 5; ++i) EXPECT_EQ(added[i], 0u) << i;
    EXPECT_EQ(std::accumulate(added.begin() + 1, added.end(), std::size_t { 0 }), 2u);
}

TEST(EmitterSchedule, DelayHoldsBackTheFirstParticle) {
    // Rate 8 at a step of 0.125 is one particle a step; a delay of half a
    // second is four steps.
    const auto added = EmissionPerStep({ { "name", "boxrandom" },
                                         { "rate", 8 },
                                         { "delay", 0.5 },
                                         { "directions", "0 0 0" } },
                                       8,
                                       0.125);
    for (int i = 0; i < 4; ++i) EXPECT_EQ(added[i], 0u) << i;
    for (int i = 4; i < 8; ++i) EXPECT_EQ(added[i], 1u) << i;
}

TEST(EmitterSchedule, DurationStopsTheEmitterForGood) {
    const auto added = EmissionPerStep({ { "name", "boxrandom" },
                                         { "rate", 8 },
                                         { "duration", 1.0 },
                                         { "directions", "0 0 0" } },
                                       16,
                                       0.125);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 8, std::size_t { 0 }), 8u);
    EXPECT_EQ(std::accumulate(added.begin() + 8, added.end(), std::size_t { 0 }), 0u);
}

TEST(EmitterSchedule, DurationCountsOnlyAfterTheDelay) {
    const auto added = EmissionPerStep({ { "name", "boxrandom" },
                                         { "rate", 8 },
                                         { "delay", 0.5 },
                                         { "duration", 0.5 },
                                         { "directions", "0 0 0" } },
                                       16,
                                       0.125);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 4, std::size_t { 0 }), 0u);
    EXPECT_EQ(std::accumulate(added.begin() + 4, added.begin() + 8, std::size_t { 0 }), 4u);
    EXPECT_EQ(std::accumulate(added.begin() + 8, added.end(), std::size_t { 0 }), 0u);
}

TEST(EmitterSchedule, PeriodicEmissionWorksInWindowsSeparatedByPauses) {
    // Windows of 0.6 s and pauses of 0.6 s at a step of 0.25: four steps emit
    // (the window opens, then runs down through zero), two are paused.
    const json fields {
        { "name", "boxrandom" }, { "rate", 4 }, { "flags", 4 }, { "directions", "0 0 0" },
        { "minperiodicduration", 0.6 }, { "maxperiodicduration", 0.6 },
        { "minperiodicdelay", 0.6 }, { "maxperiodicdelay", 0.6 },
    };
    const auto added = EmissionPerStep(fields, 12, 0.25);
    const std::vector<std::size_t> expected { 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0 };
    EXPECT_EQ(added, expected);
}

TEST(EmitterSchedule, PeriodicWindowCapsTheRateEmissionsButNotTheBurst) {
    const json fields {
        { "name", "boxrandom" }, { "rate", 40 }, { "flags", 4 }, { "directions", "0 0 0" },
        { "minperiodicduration", 0.6 }, { "maxperiodicduration", 0.6 },
        { "minperiodicdelay", 0.6 }, { "maxperiodicdelay", 0.6 },
        { "maxtoemitperperiod", 3 },
    };
    const auto added = EmissionPerStep(fields, 12, 0.25);
    // Three in each window of four steps, none while paused.
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 6, std::size_t { 0 }), 3u);
    EXPECT_EQ(std::accumulate(added.begin() + 6, added.end(), std::size_t { 0 }), 3u);
}

TEST(EmitterSchedule, PeriodicBurstIsRearmedAtTheStartOfEveryWindow) {
    const json fields {
        { "name", "boxrandom" }, { "rate", 0 }, { "flags", 4 }, { "directions", "0 0 0" },
        { "instantaneous", 5 },
        { "minperiodicduration", 0.6 }, { "maxperiodicduration", 0.6 },
        { "minperiodicdelay", 0.6 }, { "maxperiodicdelay", 0.6 },
    };
    const auto added = EmissionPerStep(fields, 12, 0.25);
    EXPECT_EQ(std::accumulate(added.begin(), added.begin() + 6, std::size_t { 0 }), 5u);
    EXPECT_EQ(std::accumulate(added.begin() + 6, added.end(), std::size_t { 0 }), 5u);
}

TEST(EmitterSchedule, ABurstHeldBackByAZeroCountMultiplierIsStillOwedWhenItRises) {
    auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled = true;
    over->count   = 0.0f;
    auto op = WPParticleParser::genParticleEmittOp(
        ParseEmitter({ { "name", "boxrandom" }, { "rate", 0 }, { "instantaneous", 5 },
                       { "directions", "0 0 0" } }),
        false, over);
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers { [](Particle& p, double) { PM::InitLifetime(p, 1000.0f); } };
    for (int i = 0; i < 3; ++i) op(particles, initializers, 100, 0.1, {});
    EXPECT_TRUE(particles.empty()) << "no count, no burst";
    over->count = 2.0f;
    op(particles, initializers, 100, 0.1, {});
    EXPECT_EQ(particles.size(), 10u) << "the burst of five, doubled, arrives once the count allows it";
    op(particles, initializers, 100, 0.1, {});
    EXPECT_EQ(particles.size(), 10u) << "and is paid out only once";
}

TEST(EmitterSchedule, AnEmitterWithNoRateAndNoWindowFiresItsBurstOnce) {
    const auto added = EmissionPerStep({ { "name", "boxrandom" },
                                         { "rate", 0 },
                                         { "instantaneous", 7 },
                                         { "directions", "0 0 0" } },
                                       4,
                                       0.1);
    EXPECT_EQ(added[0], 7u);
    EXPECT_EQ(added[1] + added[2] + added[3], 0u);
}

TEST(EmitterSchedule, EachInstanceOfASubsystemRunsItsOwnSchedule) {
    // A recycled follower or event child starts its delay and burst again;
    // one that exists next to it does not borrow its clock.
    Scene scene;
    scene.frameTime = 0.25;
    ParticleSystem system(scene);
    system.gener = std::make_unique<SilentGener>();
    auto mesh    = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSubSystem subsystem(system, mesh, 64, 1.0, 4, 1.0,
                                ParticleSubSystem::SpawnType::EVENT_SPAWN,
                                [](const Particle&, const ParticleRawGenSpec&) {});
    subsystem.AddEmitter(WPParticleParser::genParticleEmittOp(ParseEmitter(
        { { "name", "boxrandom" }, { "rate", 0 }, { "instantaneous", 3 }, { "directions", "0 0 0" } })));
    subsystem.AddInitializer([](Particle& p, double) { PM::InitLifetime(p, 100.0f); });

    auto* first = subsystem.QueryNewInstance();
    ASSERT_NE(first, nullptr);
    subsystem.Emitt();
    EXPECT_EQ(LiveParticles(*first).size(), 3u);
    auto* second = subsystem.QueryNewInstance();
    ASSERT_NE(second, nullptr);
    ASSERT_NE(first, second);
    subsystem.Emitt();
    EXPECT_EQ(LiveParticles(*first).size(), 3u) << "the first burst fires once";
    EXPECT_EQ(LiveParticles(*second).size(), 3u) << "the second instance has a burst of its own";
}

// ---------------------------------------------------------------------------
// Initializers
// ---------------------------------------------------------------------------

std::vector<Particle> RunInitializer(json fields, std::size_t count,
                                     const ParticleParseContext& ctx = {}) {
    const auto            op = WPParticleParser::genParticleInitOp(fields, ctx);
    std::vector<Particle> particles(count);
    for (auto& particle : particles) op(particle, 0.0);
    return particles;
}

/// The initializers of one file, applied in order to particles that have just
/// been created.
std::vector<Particle> RunInitializers(const std::vector<json>& chain, std::size_t count,
                                      const ParticleParseContext& ctx = {}) {
    std::vector<ParticleInitOp> ops;
    for (const auto& fields : chain) ops.push_back(WPParticleParser::genParticleInitOp(fields, ctx));
    std::vector<Particle> particles(count);
    for (auto& particle : particles) {
        for (const auto& op : ops) op(particle, 0.0);
    }
    return particles;
}

TEST(Initializers, ExponentCrowdsSizesTowardTheMinimum) {
    const auto flat    = RunInitializer({ { "name", "sizerandom" }, { "min", 0 }, { "max", 30 } }, 20000);
    const auto crowded = RunInitializer(
        { { "name", "sizerandom" }, { "min", 0 }, { "max", 30 }, { "exponent", 2 } }, 20000);
    std::vector<double> a, b;
    for (const auto& p : flat) a.push_back(p.size);
    for (const auto& p : crowded) b.push_back(p.size);
    EXPECT_NEAR(Mean(a), 15.0, 0.4);
    // E[u^2] is a third of the range.
    EXPECT_NEAR(Mean(b), 10.0, 0.4);
}

TEST(Initializers, ExponentShapesAlphaAndLifetimeToo) {
    const auto alpha = RunInitializer(
        { { "name", "alpharandom" }, { "min", 0 }, { "max", 1 }, { "exponent", 3 } }, 20000);
    const auto life = RunInitializer(
        { { "name", "lifetimerandom" }, { "min", 1 }, { "max", 5 }, { "exponent", 3 } }, 20000);
    std::vector<double> a, l;
    for (const auto& p : alpha) a.push_back(p.alpha);
    for (const auto& p : life) l.push_back(p.lifetime);
    EXPECT_NEAR(Mean(a), 0.25, 0.01);
    EXPECT_NEAR(Mean(l), 1.0 + 4.0 / 4.0, 0.05);
}

TEST(Initializers, ExponentIsDrawnPerComponentForVectors) {
    const auto particles = RunInitializer({ { "name", "velocityrandom" },
                                            { "min", "0 0 0" },
                                            { "max", "100 100 100" },
                                            { "exponent", 3 } },
                                          20000);
    std::vector<double> x, y;
    for (const auto& p : particles) {
        x.push_back(p.velocity.x());
        y.push_back(p.velocity.y());
    }
    EXPECT_NEAR(Mean(x), 25.0, 1.0);
    EXPECT_NEAR(Mean(y), 25.0, 1.0);
    // Independent draws: the two components are not the same number.
    std::size_t equal = 0;
    for (std::size_t i = 0; i < x.size(); ++i) equal += (x[i] == y[i]);
    EXPECT_LT(equal, 10u);
}

TEST(Initializers, ColourExponentUsesOneDrawForTheThreeChannels) {
    const auto particles = RunInitializer({ { "name", "colorrandom" },
                                            { "min", "0 0 0" },
                                            { "max", "255 255 255" },
                                            { "exponent", 2 } },
                                          2000);
    for (const auto& p : particles) {
        EXPECT_FLOAT_EQ(p.color.x(), p.color.y());
        EXPECT_FLOAT_EQ(p.color.y(), p.color.z());
    }
}

TEST(Initializers, LifetimeNeverFallsBelowAMillisecond) {
    const auto particles =
        RunInitializer({ { "name", "lifetimerandom" }, { "min", 0 }, { "max", 0 } }, 10);
    for (const auto& p : particles) {
        EXPECT_FLOAT_EQ(p.lifetime, 0.001f);
        EXPECT_FLOAT_EQ(p.init.lifetime, 0.001f);
    }
}

TEST(Initializers, SizeDefaultsFollowThePixelOrSceneUnitCanvas) {
    ParticleParseContext pixels;
    pixels.ortho = true;
    ParticleParseContext units;
    units.ortho = false;
    for (const auto& p : RunInitializer({ { "name", "sizerandom" } }, 200, pixels)) {
        EXPECT_GE(p.size, 5.0f);
        EXPECT_LE(p.size, 50.0f);
    }
    for (const auto& p : RunInitializer({ { "name", "sizerandom" } }, 200, units)) {
        EXPECT_GE(p.size, 0.001f);
        EXPECT_LE(p.size, 1.0f);
    }
}

// Wallpaper Engine's size and alpha initializers scale the value the particle
// has so far, as its colour initializers do; only the lifetime is replaced.
// A particle file may therefore stack them: a size of 70 to 75, then a share
// of 0.7 to 1 of it.
TEST(Initializers, ASecondSizeInitializerScalesTheFirstInsteadOfReplacingIt) {
    const auto particles = RunInitializers({ { { "name", "sizerandom" }, { "min", 70 }, { "max", 75 } },
                                             { { "name", "sizerandom" }, { "min", 0.7 }, { "max", 1.0 } } },
                                           4000);
    std::vector<double> sizes;
    for (const auto& p : particles) {
        EXPECT_GE(p.size, 70.0f * 0.7f - 1.0e-3f);
        EXPECT_LE(p.size, 75.0f + 1.0e-3f);
        EXPECT_FLOAT_EQ(p.init.size, p.size) << "the base the size operators scale is the product";
        sizes.push_back(p.size);
    }
    EXPECT_NEAR(Mean(sizes), 72.5 * 0.85, 0.5);
}

// A lone size initializer draws exactly the size it names: the start size a
// particle scales from is the unit of the size held here.
TEST(Initializers, ASizeInitializerAloneKeepsItsRange) {
    const auto alone = RunInitializers({ { { "name", "sizerandom" }, { "min", 70 }, { "max", 75 } } }, 400);
    for (const auto& p : alone) {
        EXPECT_GE(p.size, 70.0f);
        EXPECT_LE(p.size, 75.0f);
        EXPECT_FLOAT_EQ(p.init.size, p.size);
    }
}

TEST(Initializers, TwoSizeInitializersScaleInEitherOrder) {
    const auto share_first = RunInitializers({ { { "name", "sizerandom" }, { "min", 0.5 }, { "max", 0.5 } },
                                               { { "name", "sizerandom" }, { "min", 70 }, { "max", 70 } } },
                                             4);
    for (const auto& p : share_first) EXPECT_FLOAT_EQ(p.size, 35.0f);
    const auto size_first = RunInitializers({ { { "name", "sizerandom" }, { "min", 70 }, { "max", 70 } },
                                              { { "name", "sizerandom" }, { "min", 0.5 }, { "max", 0.5 } } },
                                            4);
    for (const auto& p : size_first) EXPECT_FLOAT_EQ(p.size, 35.0f);
}

TEST(Initializers, ASecondAlphaInitializerScalesTheFirstInsteadOfReplacingIt) {
    const auto particles = RunInitializers({ { { "name", "alpharandom" }, { "min", 0.5 }, { "max", 1.0 } },
                                             { { "name", "alpharandom" }, { "min", 0.4 }, { "max", 0.5 } } },
                                           4000);
    std::vector<double> alphas;
    for (const auto& p : particles) {
        EXPECT_GE(p.alpha, 0.5f * 0.4f - 1.0e-5f);
        EXPECT_LE(p.alpha, 0.5f + 1.0e-5f);
        EXPECT_FLOAT_EQ(p.init.alpha, p.alpha) << "the alpha fade starts from the product";
        alphas.push_back(p.alpha);
    }
    EXPECT_NEAR(Mean(alphas), 0.75 * 0.45, 0.01);

    const auto alone = RunInitializers({ { { "name", "alpharandom" }, { "min", 0.5 }, { "max", 1.0 } } }, 400);
    for (const auto& p : alone) {
        EXPECT_GE(p.alpha, 0.5f);
        EXPECT_LE(p.alpha, 1.0f);
        EXPECT_FLOAT_EQ(p.init.alpha, p.alpha);
    }
}

TEST(Initializers, TheLifetimeStaysReplacedWhileSizeAndAlphaScale) {
    const auto particles = RunInitializers({ { { "name", "lifetimerandom" }, { "min", 8 }, { "max", 8 } },
                                             { { "name", "lifetimerandom" }, { "min", 2 }, { "max", 2 } } },
                                           4);
    for (const auto& p : particles) EXPECT_FLOAT_EQ(p.lifetime, 2.0f);
}

linalg::Vector3f Hsv(const linalg::Vector3f& c) {
    const float mx = c.maxCoeff(), mn = c.minCoeff(), range = mx - mn;
    if (range < 1.0e-5f) return { 0.0f, 0.0f, mx };
    float h;
    if (c.x() >= mx) h = (c.y() - c.z()) / range;
    else if (c.y() >= mx) h = (c.z() - c.x()) / range + 2.0f;
    else h = (c.x() - c.y()) / range + 4.0f;
    h /= 6.0f;
    if (h < 0.0f) h += 1.0f;
    return { h, range / mx, mx };
}

ParticleParseContext ColourContext(const json& initializers, const json& operators,
                                   linalg::Vector3f colorn, bool with_override = true) {
    ParticleParseContext ctx;
    std::vector<json>    ini(initializers.begin(), initializers.end());
    std::vector<json>    ops(operators.begin(), operators.end());
    ctx.color = WPParticleParser::analyzeColorSources(ini, ops);
    auto over = std::make_shared<wpscene::ParticleInstanceoverride>();
    if (with_override) {
        over->enabled   = true;
        over->overColorn = true;
        over->colorn    = { colorn.x(), colorn.y(), colorn.z() };
    }
    ctx.over = over;
    return ctx;
}

TEST(ColourOverride, RetintsThePresetsColoursAndKeepsTheirSpread) {
    const json initializers = json::array({ { { "name", "colorrandom" },
                                               { "min", "255 0 0" },
                                               { "max", "255 128 0" } } });
    // Red to orange, overridden with blue: every colour moves the same way in
    // hue, so the spread survives and none of them stays red.
    const auto ctx       = ColourContext(initializers, json::array(), { 0.0f, 0.0f, 1.0f });
    const auto particles = RunInitializer(initializers[0], 400, ctx);
    std::set<float> distinct;
    float           lowest = 2.0f, highest = -1.0f;
    for (const auto& p : particles) {
        distinct.insert(p.color.y());
        const float hue = Hsv(p.color).x();
        lowest          = std::min(lowest, hue);
        highest         = std::max(highest, hue);
        EXPECT_GT(p.color.z(), p.color.x() - 1.0e-3f);
    }
    EXPECT_GT(distinct.size(), 100u);
    EXPECT_GT(lowest, 0.60f);
    EXPECT_LT(highest, 0.73f);
    EXPECT_GT(highest - lowest, 0.05f);
}

TEST(ColourOverride, AnOverrideEqualToThePresetColourChangesNothing) {
    const json initializers = json::array({ { { "name", "colorrandom" },
                                               { "min", "255 0 0" },
                                               { "max", "255 128 0" } } });
    // The preset's own representative colour is the midpoint.
    const auto ctx       = ColourContext(initializers, json::array(), { 1.0f, 64.0f / 255.0f, 0.0f });
    const auto particles = RunInitializer(initializers[0], 400, ctx);
    for (const auto& p : particles) {
        EXPECT_FLOAT_EQ(p.color.x(), 1.0f);
        EXPECT_GE(p.color.y(), -1.0e-6f);
        EXPECT_LE(p.color.y(), 128.0f / 255.0f + 1.0e-5f);
    }
}

TEST(ColourOverride, WhiteOnAColouredPresetDesaturatesInsteadOfFlatteningToWhite) {
    // Pinks of different saturation. White moves every one of them by the same
    // amount toward no saturation, so they stay different from each other.
    const json initializers = json::array({ { { "name", "colorrandom" },
                                               { "min", "255 128 128" },
                                               { "max", "255 0 0" } } });
    const auto ctx       = ColourContext(initializers, json::array(), { 1.0f, 1.0f, 1.0f });
    const auto particles = RunInitializer(initializers[0], 200, ctx);
    std::set<float> distinct;
    float           greenest = 0.0f;
    for (const auto& p : particles) {
        distinct.insert(p.color.y());
        greenest = std::max(greenest, p.color.y());
        EXPECT_LE(Hsv(p.color).y(), 0.26f);
        EXPECT_GE(p.color.maxCoeff(), 0.99f);
    }
    EXPECT_GT(distinct.size(), 50u);
    EXPECT_GT(greenest, 0.95f) << "the less saturated end is white";
}

TEST(ColourOverride, APresetWithNoColourSourceTakesTheOverrideAsAPlainTint) {
    ParticleParseContext ctx = ColourContext(json::array(), json::array(), { 0.2f, 0.4f, 0.6f });
    EXPECT_FALSE(ctx.color.hasColor);
    auto           op = WPParticleParser::genOverrideInitOp(ctx.over, ctx.color);
    Particle       p;
    op(p, 0.0);
    EXPECT_FLOAT_EQ(p.color.x(), 0.2f);
    EXPECT_FLOAT_EQ(p.color.y(), 0.4f);
    EXPECT_FLOAT_EQ(p.color.z(), 0.6f);
}

TEST(ColourOverride, ARetintedFileIsTintedByTheOverrideToo) {
    // Wallpaper Engine 2.8 draws a green colorrandom under an orange override
    // as orange times orange, not as orange.
    const json initializers = json::array({ { { "name", "colorrandom" },
                                               { "min", "0 255 0" },
                                               { "max", "0 255 0" } } });
    auto ctx = ColourContext(initializers, json::array(), { 1.0f, 0.5f, 0.0f });
    auto op  = WPParticleParser::genOverrideInitOp(ctx.over, ctx.color);
    Particle p = RunInitializer(initializers[0], 1, ctx).front();
    op(p, 0.0);
    EXPECT_NEAR(p.color.x(), 1.0f, 1.0e-5f);
    EXPECT_NEAR(p.color.y(), 0.25f, 1.0e-5f);
    EXPECT_NEAR(p.color.z(), 0.0f, 1.0e-5f);
    EXPECT_EQ(p.init.color, p.color) << "the colour operators start from the tinted colour";
}

TEST(ColourOverride, AnOverrideEqualToTheFilesColourDoesNotTint) {
    const json operators = json::array({ { { "name", "colorchange" },
                                            { "startvalue", "1 0.74902 0" },
                                            { "endvalue", "1 0 0" } } });
    auto ctx = ColourContext(json::array(), operators, { 1.0f, 0.74902f, 0.0f });
    Particle p;
    WPParticleParser::genOverrideInitOp(ctx.over, ctx.color)(p, 0.0);
    EXPECT_EQ(p.color, linalg::Vector3f::Ones());
}

TEST(ColourOverride, AColourchangeEndRetintedPastRedIsTintedBackToRed) {
    // A fire fading from orange to red under a redder orange override: the hue
    // shift moves the red end to magenta, and the tint by the override takes
    // the blue out again, as Wallpaper Engine 2.8 draws it.
    const json operators = json::array({ { { "name", "colorchange" },
                                            { "startvalue", "1 0.74902 0" },
                                            { "endvalue", "1 0 0" },
                                            { "endtime", 0.5 } } });
    const auto ctx = ColourContext(json::array(), operators, { 1.0f, 0.13725f, 0.0f });
    const auto tint = WPParticleParser::genOverrideInitOp(ctx.over, ctx.color);
    const auto op   = WPParticleParser::genParticleOperatorOp(operators[0], ctx);
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    for (auto& p : particles) tint(p, 0.0);
    particles[1].lifetime = 1.0f;   // past the end of the ramp
    RunOperator(op, particles, 0.0);
    EXPECT_NEAR(particles[0].color.x(), 1.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].color.y(), 0.13725f * 0.13725f, 1.0e-3f);
    EXPECT_NEAR(particles[0].color.z(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(particles[1].color.x(), 1.0f, 1.0e-4f);
    EXPECT_NEAR(particles[1].color.y(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(particles[1].color.z(), 0.0f, 1.0e-4f) << "not magenta";
}

TEST(ColourOverride, ColourchangeIsRetintedToo) {
    const json operators = json::array({ { { "name", "colorchange" },
                                            { "startvalue", "1 0 0" },
                                            { "endvalue", "1 0 0" } } });
    const auto ctx = ColourContext(json::array(), operators, { 0.0f, 0.0f, 1.0f });
    EXPECT_TRUE(ctx.color.hasColor);
    const auto op = WPParticleParser::genParticleOperatorOp(operators[0], ctx);
    std::array<Particle, 1> particles { LivingParticle() };
    RunOperator(op, particles, 0.0);
    // Red is moved to the override's hue: blue, not red.
    EXPECT_GT(particles[0].color.z(), 0.9f);
    EXPECT_LT(particles[0].color.x(), 0.1f);
}

TEST(ColourOverride, HsvColourInitializerIsRecentredOnTheOverride) {
    const json initializers = json::array({ { { "name", "hsvcolorrandom" },
                                               { "huemin", 0.0 }, { "huemax", 0.2 },
                                               { "huesteps", 0 },
                                               { "saturationmin", 1 }, { "saturationmax", 1 },
                                               { "valuemin", 1 }, { "valuemax", 1 } } });
    const auto ctx       = ColourContext(initializers, json::array(), { 0.0f, 0.0f, 1.0f });
    const auto particles = RunInitializer(initializers[0], 200, ctx);
    for (const auto& p : particles) EXPECT_NEAR(Hsv(p.color).x(), Hsv({ 0, 0, 1 }).x(), 0.2f);
}

TEST(ColourOverride, HsvAndListInitializersMultiplyIntoTheColour) {
    const auto hsv = RunInitializer({ { "name", "hsvcolorrandom" } }, 300);
    for (const auto& p : hsv) {
        const auto h = Hsv(p.color);
        EXPECT_GE(h.y(), 0.5f - 1.0e-4f);
        EXPECT_GE(h.z(), 0.5f - 1.0e-4f);
    }
    const auto list = RunInitializer({ { "name", "colorlist" }, { "colors", "1 0 0 0 1 0" } }, 300);
    std::set<std::pair<float, float>> seen;
    for (const auto& p : list) seen.insert({ p.color.x(), p.color.y() });
    EXPECT_EQ(seen.size(), 2u);
}

/// The distinct hues (in 1/1000ths of a turn) `count` draws of an hsvcolorrandom
/// initializer produce.
std::set<long> HuesOf(json fields, std::size_t count = 600) {
    fields["name"]          = "hsvcolorrandom";
    fields["saturationmin"] = 1;
    fields["saturationmax"] = 1;
    fields["valuemin"]      = 1;
    fields["valuemax"]      = 1;
    std::set<long> hues;
    for (const auto& p : RunInitializer(fields, count)) {
        float hue = Hsv(p.color).x();
        if (hue > 0.9995f) hue = 0.0f;
        hues.insert(std::lround(hue * 1000.0f));
    }
    return hues;
}

TEST(ColourInitializers, HueStepsAreSpacedOverTheRangeTheWayTheLoaderSpacesThem) {
    // A range that is a whole turn ends where it began, so six steps split it
    // in six and the seventh index lands back on the first hue.
    EXPECT_EQ(HuesOf({ { "huemin", 0.0 }, { "huemax", 1.0 }, { "huesteps", 6 } }),
              (std::set<long> { 0, 167, 333, 500, 667, 833 }));
    // Any other range is divided by one less than the step count, and the
    // index runs from 0 up to the step count itself: three steps over half a
    // turn are a quarter turn apart and the last one lies past the range's end.
    EXPECT_EQ(HuesOf({ { "huemin", 0.0 }, { "huemax", 0.5 }, { "huesteps", 3 } }),
              (std::set<long> { 0, 250, 500, 750 }));
    // Another start moves the whole set.
    EXPECT_EQ(HuesOf({ { "huemin", 0.1 }, { "huemax", 0.3 }, { "huesteps", 2 } }),
              (std::set<long> { 100, 300, 500 }));
}

TEST(ColourInitializers, OneHueStepOrNoneNeverReachesTheEndOfTheRange) {
    EXPECT_EQ(HuesOf({ { "huemin", 0.2 }, { "huemax", 0.7 }, { "huesteps", 1 } }),
              (std::set<long> { 200 }));
    EXPECT_EQ(HuesOf({ { "huemin", 0.2 }, { "huemax", 0.7 }, { "huesteps", 0 } }),
              (std::set<long> { 200 }));
}

TEST(ColourInitializers, ARangeOfNoWidthIsOneTurnWide) {
    EXPECT_EQ(HuesOf({ { "huemin", 0.25 }, { "huemax", 0.25 }, { "huesteps", 4 } }),
              (std::set<long> { 250, 500, 750, 0 }));
}

TEST(ColourInitializers, ColourListNoiseIsADrawOverTheRangeCutOffAtZeroAndOne) {
    // Red is hue 0, saturation 1, value 1. A hue noise of 0.2 draws over
    // [0, 0.2] (the low end is cut off at 0, not wrapped round to 0.8..1), and a
    // saturation noise of 0.5 over [0.5, 1] without a pile of values at 1.
    const auto particles = RunInitializer({ { "name", "colorlist" }, { "colors", "1 0 0" },
                                            { "huenoise", 0.2 }, { "saturationnoise", 0.5 } },
                                          2000);
    std::size_t at_top = 0;
    double      sum    = 0.0;
    for (const auto& p : particles) {
        const auto hsv = Hsv(p.color);
        const float hue = hsv.x() > 0.9995f ? 0.0f : hsv.x();
        EXPECT_GE(hue, -1.0e-4f);
        EXPECT_LE(hue, 0.2f + 1.0e-3f) << "no wrap to the far side of the wheel";
        EXPECT_GE(hsv.y(), 0.5f - 1.0e-3f);
        if (hsv.y() > 0.9999f) ++at_top;
        sum += hsv.y();
    }
    EXPECT_LT(at_top, 20u) << "no run of draws parked on the top edge";
    EXPECT_NEAR(sum / static_cast<double>(particles.size()), 0.75, 0.03);
}

TEST(ColourInitializers, ColourListShiftIsAddedAfterTheNoise) {
    // The override moves hue, saturation and value after the draw, so the
    // result keeps the same width: saturation noise 0.1 around 1 draws over
    // [0.9, 1.0] and the override's lower saturation moves all of it down.
    const json initializers = json::array({ { { "name", "colorlist" },
                                               { "colors", "1 0 0" },
                                               { "saturationnoise", 0.1 } } });
    const auto ctx = ColourContext(initializers, json::array(), { 1.0f, 0.5f, 0.5f });
    for (const auto& p : RunInitializer(initializers[0], 400, ctx)) {
        const auto hsv = Hsv(p.color);
        EXPECT_GE(hsv.y(), 0.4f - 1.0e-3f);
        EXPECT_LE(hsv.y(), 0.5f + 1.0e-3f);
    }
}

TEST(ColourOverride, ColourchangeStartsAtOneWhenTheFileOmitsIt) {
    const auto op = MakeOperator({ { "name", "colorchange" }, { "endvalue", "0 0 0" } });
    std::array<Particle, 1> particles { LivingParticle() };
    RunOperator(op, particles, 0.0);
    EXPECT_FLOAT_EQ(particles[0].color.x(), 1.0f);
    EXPECT_FLOAT_EQ(particles[0].color.y(), 1.0f);
    EXPECT_FLOAT_EQ(particles[0].color.z(), 1.0f);
}

TEST(ColourOverride, BrightnessMultipliesTheTintOnlyInAnHdrScene) {
    auto over        = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled    = true;
    over->brightness = 4.0f;
    {
        Particle p;
        WPParticleParser::genOverrideInitOp(over)(p, 0.0);
        EXPECT_FLOAT_EQ(p.color.x(), 1.0f);
    }
    over->hdr = true;
    Particle p;
    WPParticleParser::genOverrideInitOp(over)(p, 0.0);
    EXPECT_FLOAT_EQ(p.color.x(), 4.0f);
    EXPECT_FLOAT_EQ(p.init.color.y(), 4.0f);
}

// ---------------------------------------------------------------------------
// Initializers that need the control points, the clock or the parent
// ---------------------------------------------------------------------------

struct SpawnRig {
    std::array<ParticleControlpoint, 8> controlpoints {};
    std::shared_ptr<ParticleSpawnContext> spawn { std::make_shared<ParticleSpawnContext>() };
    ParticleParseContext ctx;

    SpawnRig() {
        spawn->controlpoints = controlpoints;
        ctx.spawn            = spawn;
    }
    void Sync() { spawn->controlpoints = controlpoints; }
};

TEST(SequenceInitializers, MapSequenceAroundSpacesConsecutiveSpawnsAroundTheAxis) {
    SpawnRig rig;
    rig.controlpoints[0].offset = linalg::Vector3d(10.0, 20.0, 0.0);
    rig.Sync();
    const auto op = WPParticleParser::genParticleInitOp(
        { { "name", "mapsequencearoundcontrolpoint" },
          { "count", 4 },
          { "axis", "0 0 1" },
          { "speedmin", "0 0 100" },
          { "speedmax", "0 0 100" } },
        rig.ctx);
    std::vector<linalg::Vector3f> spots;
    for (int i = 0; i < 4; ++i) {
        Particle p;
        p.position = { 10.0f + 5.0f, 20.0f, 3.0f }; // 5 units from the axis, 3 along it
        op(p, 0.0);
        spots.push_back(p.position);
        EXPECT_NEAR(p.position.z(), 3.0f, 1.0e-4f) << "the height along the axis is kept";
        EXPECT_NEAR(linalg::Vector2f(p.position.x() - 10.0f, p.position.y() - 20.0f).norm(), 5.0f, 1.0e-4f);
        EXPECT_NEAR(p.velocity.z(), 100.0f, 1.0e-3f) << "the axis speed is added";
    }
    // A quarter turn between neighbours.
    EXPECT_NEAR(spots[0].x(), 15.0f, 1.0e-4f);
    EXPECT_NEAR(spots[1].y(), 25.0f, 1.0e-4f);
    EXPECT_NEAR(spots[2].x(), 5.0f, 1.0e-4f);
    EXPECT_NEAR(spots[3].y(), 15.0f, 1.0e-4f);
}

TEST(SequenceInitializers, MapSequenceAroundTurnsItsAxisWithTheControlpoint) {
    // The control point is turned a quarter of a turn about x, which takes the
    // axis (0 0 1) to (0 -1 0): the spawns circle that axis, keep their height
    // along it (here the y coordinate) and the axis speed points along it.
    SpawnRig rig;
    rig.controlpoints[0].offset       = linalg::Vector3d(10.0, 20.0, 0.0);
    rig.controlpoints[0].rotation     = linalg::AngleAxisd(M_PI / 2.0, linalg::Vector3d::UnitX()).toRotationMatrix();
    rig.controlpoints[0].has_rotation = true;
    rig.Sync();
    const auto op = WPParticleParser::genParticleInitOp(
        { { "name", "mapsequencearoundcontrolpoint" },
          { "count", 4 },
          { "axis", "0 0 1" },
          { "speedmin", "0 0 100" },
          { "speedmax", "0 0 100" } },
        rig.ctx);
    std::vector<linalg::Vector3f> spots;
    for (int i = 0; i < 4; ++i) {
        Particle p;
        p.position = { 15.0f, 23.0f, 0.0f }; // 5 from the axis in x, 3 along y from the control point
        op(p, 0.0);
        spots.push_back(p.position);
        EXPECT_NEAR(p.position.y(), 23.0f, 1.0e-4f) << "the height along the turned axis is kept";
        EXPECT_NEAR(linalg::Vector2f(p.position.x() - 10.0f, p.position.z()).norm(), 5.0f, 1.0e-4f);
        EXPECT_NEAR(p.velocity.y(), -100.0f, 1.0e-3f) << "the axis speed follows the turned axis";
        EXPECT_NEAR(p.velocity.z(), 0.0f, 1.0e-3f);
    }
    // Neighbours are a quarter turn apart around the turned axis.
    EXPECT_NEAR((spots[0] - spots[1]).norm(), 5.0f * std::sqrt(2.0f), 1.0e-3f);
    EXPECT_NEAR((spots[0] - spots[2]).norm(), 10.0f, 1.0e-3f);
}

TEST(SequenceInitializers, MapSequenceBetweenStringsSpawnsAlongTheSegmentBetweenTwoControlpoints) {
    SpawnRig rig;
    rig.controlpoints[0].offset = linalg::Vector3d(0.0, 0.0, 0.0);
    rig.controlpoints[1].offset = linalg::Vector3d(0.0, -450.0, 0.0);
    rig.Sync();
    const auto op = WPParticleParser::genParticleInitOp(
        { { "name", "mapsequencebetweencontrolpoints" }, { "count", 4 } }, rig.ctx);
    const std::vector<float> expected { 0.0f, -150.0f, -300.0f, -450.0f };
    for (const float y : expected) {
        Particle p;
        op(p, 0.0);
        EXPECT_NEAR(p.position.y(), y, 1.0e-3f);
        EXPECT_NEAR(p.position.x(), 0.0f, 1.0e-3f);
    }
    // The sequence starts over.
    Particle again;
    op(again, 0.0);
    EXPECT_NEAR(again.position.y(), 0.0f, 1.0e-3f);
}

TEST(SequenceInitializers, MapSequenceBetweenFlagsPinchTheEndsAndArcTheMiddle) {
    SpawnRig rig;
    rig.controlpoints[1].offset = linalg::Vector3d(100.0, 0.0, 0.0);
    rig.Sync();
    // Flags 1 (pinch the sideways spread at the ends), 4 (smaller toward the
    // ends) and 8 (arc by arcamount in arcdirection).
    const auto op = WPParticleParser::genParticleInitOp({ { "name", "mapsequencebetweencontrolpoints" },
                                                          { "count", 3 },
                                                          { "flags", 1 | 4 | 8 },
                                                          { "arcamount", 0.5 },
                                                          { "arcdirection", "0 1 0" },
                                                          { "sizereductionamount", 1.0 } },
                                                        rig.ctx);
    Particle ends;
    ends.size = 10.0f;
    ends.init.size = 10.0f;
    ends.position = { 0.0f, 7.0f, 0.0f };
    op(ends, 0.0);
    EXPECT_NEAR(ends.position.y(), 0.0f, 1.0e-4f) << "sideways spread pinched at the first end";
    EXPECT_NEAR(ends.size, 0.0f, 1.0e-4f);
    Particle middle;
    middle.size = 10.0f;
    middle.init.size = 10.0f;
    middle.position = { 0.0f, 7.0f, 0.0f };
    op(middle, 0.0);
    EXPECT_NEAR(middle.position.x(), 50.0f, 1.0e-3f);
    EXPECT_NEAR(middle.position.y(), 7.0f + 100.0f * 0.5f, 1.0e-3f) << "spread kept, arc added";
    EXPECT_NEAR(middle.size, 10.0f, 1.0e-4f);
}

TEST(SequenceInitializers, InheritControlpointVelocityTakesAShareOfTheControlpointsMotion) {
    SpawnRig rig;
    rig.controlpoints[2].offset      = linalg::Vector3d(10.0, 0.0, 0.0);
    rig.controlpoints[2].prev_offset = linalg::Vector3d(0.0, 0.0, 0.0);
    rig.spawn->frame_time            = 0.5;
    rig.Sync();
    const auto op = WPParticleParser::genParticleInitOp(
        { { "name", "inheritcontrolpointvelocity" }, { "controlpoint", 2 }, { "min", 0.5 }, { "max", 0.5 } },
        rig.ctx);
    Particle p;
    op(p, 0.0);
    // The control point moves at 20 units a second; the particle takes half.
    EXPECT_NEAR(p.velocity.x(), 10.0f, 1.0e-4f);
}

TEST(SequenceInitializers, PositionOffsetRandomDisplacesBySmoothNoiseAndHonoursDirections) {
    SpawnRig rig;
    rig.spawn->system_time = 1.0;
    const auto op = WPParticleParser::genParticleInitOp({ { "name", "positionoffsetrandom" },
                                                          { "distance", 50 },
                                                          { "scale", 0.01 },
                                                          { "directions", "1 0 0" } },
                                                        rig.ctx);
    std::set<float> seen;
    for (int i = 0; i < 50; ++i) {
        Particle p;
        p.position = { static_cast<float>(i) * 13.0f, 0.0f, 0.0f };
        const float start = p.position.x();
        op(p, 0.0);
        EXPECT_LE(std::abs(p.position.x() - start), 50.0f + 1.0e-3f);
        EXPECT_EQ(p.position.y(), 0.0f);
        EXPECT_EQ(p.position.z(), 0.0f);
        seen.insert(p.position.x() - start);
    }
    EXPECT_GT(seen.size(), 20u);
}

TEST(SequenceInitializers, InheritInitialValueCopiesTheParentParticleOfAnEventChild) {
    SpawnRig rig;
    Particle parent;
    parent.color    = { 0.1f, 0.2f, 0.3f };
    parent.alpha    = 0.5f;
    parent.size     = 7.0f;
    parent.velocity = { 1.0f, 2.0f, 3.0f };
    rig.spawn->parent = &parent;
    {
        Particle p;
        WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" } }, rig.ctx)(p, 0.0);
        EXPECT_FLOAT_EQ(p.color.y(), 0.2f);
        EXPECT_FLOAT_EQ(p.init.color.z(), 0.3f);
    }
    {
        Particle p;
        WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" }, { "input", "setcoloropacity" } },
                                            rig.ctx)(p, 0.0);
        EXPECT_FLOAT_EQ(p.alpha, 0.5f);
    }
    {
        Particle p;
        WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" }, { "input", "addvelocity" } },
                                            rig.ctx)(p, 0.0);
        EXPECT_FLOAT_EQ(p.velocity.z(), 3.0f);
    }
    {
        // The engine multiplies its own start size by the parent's, both half of ours.
        Particle p;
        WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" }, { "input", "multiplysize" } },
                                            rig.ctx)(p, 0.0);
        EXPECT_FLOAT_EQ(p.size, kParticleStartSize * 7.0f / kParticleSizeOverEngine);
        EXPECT_FLOAT_EQ(p.init.size, p.size);
    }
    {
        Particle p;
        WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" }, { "input", "setsize" } },
                                            rig.ctx)(p, 0.0);
        EXPECT_FLOAT_EQ(p.size, 7.0f);
    }
    // No parent, nothing to copy.
    rig.spawn->parent = nullptr;
    Particle alone;
    WPParticleParser::genParticleInitOp({ { "name", "inheritinitialvaluefromevent" } }, rig.ctx)(alone, 0.0);
    EXPECT_FLOAT_EQ(alone.color.x(), 1.0f);
}

// The engine multiplies its own child size (0.5 to start, then a draw) by its own
// parent size. Both are half of the size held here, so a child that draws 10
// beneath a parent held at 8 comes out at 10 * 4, in either order.
TEST(SequenceInitializers, AnInheritedMultiplySizeScalesTheChildByHalfTheSizeHeldForTheParent) {
    SpawnRig rig;
    Particle parent;
    parent.size       = 8.0f;
    rig.spawn->parent = &parent;
    const auto draw    = WPParticleParser::genParticleInitOp(
        { { "name", "sizerandom" }, { "min", 10 }, { "max", 10 } }, rig.ctx);
    const auto inherit = WPParticleParser::genParticleInitOp(
        { { "name", "inheritinitialvaluefromevent" }, { "input", "multiplysize" } }, rig.ctx);
    Particle draw_first;
    draw(draw_first, 0.0);
    inherit(draw_first, 0.0);
    EXPECT_FLOAT_EQ(draw_first.size, 40.0f);
    EXPECT_FLOAT_EQ(draw_first.init.size, 40.0f);
    Particle inherit_first;
    inherit(inherit_first, 0.0);
    draw(inherit_first, 0.0);
    EXPECT_FLOAT_EQ(inherit_first.size, 40.0f);
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

TEST(Movement, DragDampsTheVelocityAfterThePositionHasMovedByIt) {
    const auto op = MakeOperator({ { "name", "movement" }, { "drag", 1.0 } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].velocity = { 10.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.1);
    // Moved by the undamped velocity, then slowed by drag * dt.
    EXPECT_NEAR(particles[0].position.x(), 1.0f, 1.0e-5f);
    EXPECT_NEAR(particles[0].velocity.x(), 9.0f, 1.0e-5f);
}

TEST(Movement, DragCannotReverseTheVelocity) {
    const auto op = MakeOperator({ { "name", "movement" }, { "drag", 100.0 } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].velocity = { 10.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.1);
    EXPECT_GE(particles[0].velocity.x(), 0.0f);
    EXPECT_LT(particles[0].velocity.x(), 1.0e-5f);
}

TEST(Movement, GravityAddsBeforeThePositionMoves) {
    const auto op = MakeOperator({ { "name", "movement" }, { "gravity", "0 -10 0" } });
    std::array<Particle, 1> particles { LivingParticle() };
    RunOperator(op, particles, 0.5);
    EXPECT_NEAR(particles[0].velocity.y(), -5.0f, 1.0e-5f);
    EXPECT_NEAR(particles[0].position.y(), -2.5f, 1.0e-5f);
}

TEST(Movement, TheSpeedOverrideScalesGravityButNotDrag) {
    auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled = true;
    over->speed   = 2.0f;
    const auto op = MakeOperator({ { "name", "movement" }, { "gravity", "0 -10 0" }, { "drag", 1.0 } }, over);
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].velocity = { 10.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.1);
    EXPECT_NEAR(particles[0].velocity.y(), -2.0f * (1.0f - 0.1f), 1.0e-5f);
    EXPECT_NEAR(particles[0].velocity.x(), 9.0f, 1.0e-5f);
}

TEST(Movement, FlagOneKeepsGravityAlignedToTheScreenOnATurnedLayer) {
    const auto op = MakeOperator({ { "name", "movement" }, { "gravity", "0 -10 0" }, { "flags", 1 } });
    std::array<Particle, 1> particles { LivingParticle() };
    const std::array<ParticleControlpoint, 8> controlpoints {};
    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    // The layer is turned a quarter of a turn about z: world down is local +x.
    info.world_to_local = linalg::AngleAxisd(-M_PI / 2.0, linalg::Vector3d::UnitZ()).toRotationMatrix();
    op(info);
    EXPECT_NEAR(particles[0].velocity.x(), -10.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].velocity.y(), 0.0f, 1.0e-4f);
}

/// One static subsystem that spawns a single particle with velocity (3, 0, 0)
/// and spin (0, 0, 2), then runs `operators` over it for two one-second steps.
Particle RunOneParticleWith(const std::vector<json>& operators, bool track_previous = false) {
    Scene scene;
    scene.frameTime = 1.0;
    ParticleSystem system(scene);
    system.gener = std::make_unique<SilentGener>();
    auto mesh    = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSubSystem subsystem(system, mesh, 4, 1.0, 1, 1.0, ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {});
    subsystem.SetTracksPreviousPosition(track_previous);
    subsystem.AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&, uint32_t,
                            double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle p;
        PM::InitLifetime(p, 100.0f);
        p.velocity        = { 3.0f, 0.0f, 0.0f };
        p.angularVelocity = { 0.0f, 0.0f, 2.0f };
        particles.push_back(p);
    });
    for (const auto& op : operators) subsystem.AddOperator(MakeOperator(op));
    subsystem.Emitt();
    subsystem.Emitt();
    EXPECT_EQ(subsystem.Instances().size(), 1u);
    return subsystem.Instances().empty() || subsystem.Instances()[0]->Particles().empty()
               ? Particle {}
               : subsystem.Instances()[0]->Particles()[0];
}

TEST(Movement, OnlyTheMovementOperatorsAdvanceAParticle) {
    // Wallpaper Engine moves a particle inside the movement operator and turns
    // it inside the angular movement operator, and nowhere else: a file without
    // them keeps its particles where they were placed, whatever velocity or spin
    // they were given.
    const Particle idle = RunOneParticleWith({});
    EXPECT_NEAR(idle.position.x(), 0.0f, 1.0e-6f);
    EXPECT_NEAR(idle.rotation.z(), 0.0f, 1.0e-6f);
    EXPECT_NEAR(idle.velocity.x(), 3.0f, 1.0e-6f);

    const Particle other = RunOneParticleWith({ { { "name", "alphafade" } } });
    EXPECT_NEAR(other.position.x(), 0.0f, 1.0e-6f) << "an operator that is not a mover moves nothing";

    const Particle moved = RunOneParticleWith({ { { "name", "movement" } } });
    EXPECT_NEAR(moved.position.x(), 6.0f, 1.0e-4f);
    EXPECT_NEAR(moved.rotation.z(), 0.0f, 1.0e-6f) << "movement does not turn the particle";

    const Particle spun = RunOneParticleWith({ { { "name", "angularmovement" } } });
    EXPECT_NEAR(spun.rotation.z(), 4.0f, 1.0e-4f);
    EXPECT_NEAR(spun.position.x(), 0.0f, 1.0e-6f) << "angular movement does not move it";
}

TEST(Movement, ThePreviousPositionIsKeptOnlyWhileAnOperatorAsksForIt) {
    const Particle tracked = RunOneParticleWith({ { { "name", "movement" } } }, true);
    EXPECT_NEAR(tracked.position.x(), 6.0f, 1.0e-4f);
    EXPECT_NEAR(tracked.prev_position.x(), 3.0f, 1.0e-4f) << "where the last step began";
    const Particle untracked = RunOneParticleWith({ { { "name", "movement" } } }, false);
    EXPECT_NEAR(untracked.prev_position.x(), 0.0f, 1.0e-6f) << "no snapshot, nothing stored";
}

TEST(Movement, FlagOneGravityKeepsTheLayersScale) {
    // The layer's 3x3 is applied transposed without being normalised, so a
    // layer drawn at twice the size pulls twice as hard in its own units.
    Scene scene;
    scene.frameTime = 0.1;
    ParticleSystem system(scene);
    system.gener = std::make_unique<SilentGener>();
    ParticleSubSystem subsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0, 1,
                                1.0, ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {});
    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(linalg::Vector3f(2.0f, 2.0f, 2.0f));
    subsystem.SetOwnerNode(owner);
    subsystem.SetNeedsWorldAxes(true);
    subsystem.AddOperator(MakeOperator({ { "name", "movement" }, { "gravity", "0 -10 0" }, { "flags", 1 } }));
    subsystem.AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&, uint32_t,
                            double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle p;
        PM::InitLifetime(p, 100.0f);
        particles.push_back(p);
    });
    subsystem.Emitt();
    ASSERT_EQ(subsystem.Instances().size(), 1u);
    EXPECT_NEAR(subsystem.Instances()[0]->Particles()[0].velocity.y(), -2.0f, 1.0e-4f);
}

TEST(Movement, FlagOneGravityOfAWorldspaceSystemNeedsNoTurningByItsLayer) {
    // A worldspace system is already in the scene's own axes: gravity authored in
    // them is not carried through the layer's matrix, whatever the layer's scale.
    for (const bool world_space : { true, false }) {
        SCOPED_TRACE(world_space);
        Scene scene;
        scene.frameTime = 0.1;
        ParticleSystem system(scene);
        system.gener = std::make_unique<SilentGener>();
        ParticleSubSystem subsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0,
                                    1, 1.0, ParticleSubSystem::SpawnType::STATIC,
                                    [](const Particle&, const ParticleRawGenSpec&) {});
        auto owner = std::make_shared<SceneNode>();
        owner->SetScale(linalg::Vector3f(2.0f, 2.0f, 2.0f));
        subsystem.SetOwnerNode(owner);
        subsystem.SetWorldSpace(world_space);
        subsystem.SetNeedsWorldAxes(true);
        subsystem.AddOperator(
            MakeOperator({ { "name", "movement" }, { "gravity", "0 -10 0" }, { "flags", 1 } }));
        subsystem.AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                uint32_t, double, std::span<const ParticleControlpoint>) {
            if (! particles.empty()) return;
            Particle p;
            PM::InitLifetime(p, 100.0f);
            particles.push_back(p);
        });
        subsystem.Emitt();
        ASSERT_EQ(subsystem.Instances().size(), 1u);
        EXPECT_NEAR(subsystem.Instances()[0]->Particles()[0].velocity.y(),
                    world_space ? -1.0f : -2.0f, 1.0e-4f);
    }
}

TEST(AngularMovement, DragDampsTheSpinInsteadOfPullingTheAngleBack) {
    const auto op = MakeOperator({ { "name", "angularmovement" }, { "drag", 0.5 } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].rotation        = { 0.0f, 0.0f, 2.0f };
    particles[0].angularVelocity = { 0.0f, 0.0f, 4.0f };
    RunOperator(op, particles, 0.1);
    EXPECT_NEAR(particles[0].rotation.z(), 2.0f + 0.4f, 1.0e-5f);
    EXPECT_NEAR(particles[0].angularVelocity.z(), 4.0f * 0.95f, 1.0e-5f);
    // A particle that does not spin keeps its angle however large it is.
    particles[0].angularVelocity = linalg::Vector3f::Zero();
    particles[0].rotation        = { 0.0f, 0.0f, 3.0f };
    RunOperator(op, particles, 0.1);
    EXPECT_NEAR(particles[0].rotation.z(), 3.0f, 1.0e-6f);
}

TEST(AngularMovement, ForceSpinsUpTheParticle) {
    const auto op = MakeOperator({ { "name", "angularmovement" }, { "force", "0 0 -1" }, { "drag", 0.3 } });
    std::array<Particle, 1> particles { LivingParticle() };
    for (int i = 0; i < 600; ++i) RunOperator(op, particles, 0.05);
    // The terminal spin is force / drag.
    EXPECT_NEAR(particles[0].angularVelocity.z(), -1.0f / 0.3f, 0.2f);
}

TEST(ControlpointAttract, FlagTwoNeverCarriesAParticlePastTheControlpoint) {
    const auto op = MakeOperator({ { "name", "controlpointattract" },
                                   { "controlpoint", 0 },
                                   { "scale", 1000.0 },
                                   { "threshold", 1.0 },
                                   { "flags", 2 } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 0.5f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    // The pull would be 500; it is held to the distance, 0.5.
    EXPECT_NEAR(particles[0].velocity.x(), -0.5f, 1.0e-5f);
    const auto free = MakeOperator({ { "name", "controlpointattract" },
                                     { "controlpoint", 0 },
                                     { "scale", 1000.0 },
                                     { "threshold", 1.0 } });
    particles[0].velocity = linalg::Vector3f::Zero();
    RunOperator(free, particles, 1.0);
    EXPECT_NEAR(particles[0].velocity.x(), -500.0f, 1.0e-3f);
}

TEST(ControlpointAttract, NegativeScaleRepelsAndFadesWithDistanceToo) {
    const auto op = MakeOperator({ { "name", "controlpointattract" },
                                   { "scale", -100.0 },
                                   { "threshold", 10.0 } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 4.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    EXPECT_NEAR(particles[0].velocity.x(), 60.0f, 1.0e-4f);
}

TEST(ControlpointAttract, FlagOneRemovesAParticleWhosePathLastStepPassedTheDeleteThreshold) {
    const auto op = MakeOperator({ { "name", "controlpointattract" },
                                   { "scale", 0.0 },
                                   { "threshold", 100.0 },
                                   { "deletethreshold", 2.0 },
                                   { "flags", 1 } });
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    // The first travelled straight through the control point, the second
    // passed 10 units away from it.
    particles[0].prev_position = { -5.0f, 0.0f, 0.0f };
    particles[0].position      = { 5.0f, 0.0f, 0.0f };
    particles[1].prev_position = { -5.0f, 10.0f, 0.0f };
    particles[1].position      = { 5.0f, 10.0f, 0.0f };
    // The third is heading for the control point fast, but the path it has
    // already travelled stays clear of it: only that path counts.
    particles[2].prev_position = { 8.0f, 0.0f, 0.0f };
    particles[2].position      = { 9.0f, 0.0f, 0.0f };
    particles[2].velocity      = { -100.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    EXPECT_TRUE(PM::LifetimeOk(particles[0])) << "it ends at the next age update";
    EXPECT_LT(particles[0].lifetime, 1.0e-6f);
    EXPECT_GT(particles[1].lifetime, 1.0f);
    EXPECT_GT(particles[2].lifetime, 1.0f) << "its next step is not looked at";
}

TEST(ControlpointAttract, TheSpeedOverrideScalesThePullUnlessTheFileIgnoresIt) {
    auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled = true;
    over->speed   = 3.0f;
    const json attract { { "name", "controlpointattract" }, { "scale", 10.0 }, { "threshold", 100.0 } };
    const auto pull = [&](const ParticleOperatorOp& op) {
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].position = { 50.0f, 0.0f, 0.0f };
        RunOperator(op, particles, 1.0);
        return -particles[0].velocity.x();
    };
    const float base = pull(MakeOperator(attract));
    EXPECT_NEAR(base, 0.5f * 10.0f, 1.0e-4f);
    EXPECT_NEAR(pull(MakeOperator(attract, over)), 3.0f * base, 1.0e-3f);
    EXPECT_NEAR(pull(MakeOperatorIn(attract, IgnoringSpeedOverride(over))), base, 1.0e-4f);
}

TEST(ControlpointAttract, DoesNotReadTheOperatorsOwnOrigin) {
    const auto op = MakeOperator({ { "name", "controlpointattract" },
                                   { "scale", 10.0 },
                                   { "threshold", 100.0 },
                                   { "origin", "50 0 0" } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 20.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    // Towards the control point at the origin, not the one 50 units along.
    EXPECT_LT(particles[0].velocity.x(), 0.0f);
}

TEST(Oscillators, AlphaSwingsBetweenTheMinimumAndAShareOfTheRangeSetByTheParticleSeed) {
    const auto op = MakeOperator({ { "name", "oscillatealpha" },
                                   { "frequencymin", 1.0 }, { "frequencymax", 1.0 },
                                   { "phasemin", 0.0 }, { "phasemax", 0.0 },
                                   { "scalemin", 0.2 }, { "scalemax", 1.0 } });
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    particles[0].seed = 0.5f;
    particles[1].seed = 1.0f;
    RunOperator(op, particles, 0.1);
    // Age 0: sin = 0, so the wave is at its midpoint.
    EXPECT_NEAR(particles[0].alpha, 0.2f + 0.5f * 0.5f * 0.8f, 1.0e-5f);
    EXPECT_NEAR(particles[1].alpha, 0.2f + 0.5f * 1.0f * 0.8f, 1.0e-5f);
    // Never above the swing the seed allows.
    for (float age = 0.0f; age < 7.0f; age += 0.05f) {
        std::array<Particle, 1> one { LivingParticle() };
        one[0].seed     = 0.5f;
        one[0].lifetime = 10.0f - age;
        RunOperator(op, one, 0.01);
        EXPECT_LE(one[0].alpha, 0.2f + 0.5f * 0.8f + 1.0e-5f);
        EXPECT_GE(one[0].alpha, 0.2f - 1.0e-5f);
    }
}

TEST(Oscillators, FrequencyMinimumDefaultsToOneNotZero) {
    // With the default range 1..10 and a seed of zero the particle oscillates
    // at once; a minimum of zero would hold it still.
    const auto op = MakeOperator({ { "name", "oscillatesize" } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].seed     = 0.0f;
    particles[0].lifetime = 9.0f; // one second old
    RunOperator(op, particles, 0.01);
    const double expected = 0.8 + 0.5 * (std::sin(1.0 * 1.0) + 1.0) * 0.0 * 0.4;
    EXPECT_NEAR(particles[0].size / kParticleStartSize, expected, 1.0e-5);
}

TEST(Oscillators, PositionMovesByTheDifferenceOfTwoEvaluationsAndZSharesXsWave) {
    const auto op = MakeOperator({ { "name", "oscillateposition" },
                                   { "frequencymin", 1.0 }, { "frequencymax", 1.0 },
                                   { "phasemin", 0.0 }, { "phasemax", 0.0 },
                                   { "scalemin", 2.0 }, { "scalemax", 2.0 },
                                   { "mask", "1 1 0.5" } });
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].seed     = 0.5f;
    particles[0].lifetime = 9.0f; // age 1
    RunOperator(op, particles, 0.1);
    const double wx = 2.0 * (std::sin(1.0) - std::sin(0.9));
    const double wy = 2.0 * (std::sin(M_PI + 1.0) - std::sin(M_PI + 0.9));
    EXPECT_NEAR(particles[0].position.x(), wx, 1.0e-5);
    EXPECT_NEAR(particles[0].position.y(), wy, 1.0e-5);
    EXPECT_NEAR(particles[0].position.z(), 0.5 * wx, 1.0e-5);
}

TEST(Oscillators, OnlyThePositionSwingFollowsTheSpeedOverrideAndOnlyInItsFrequency) {
    auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled = true;
    over->speed   = 2.0f;
    const json fields { { "name", "oscillateposition" },
                        { "frequencymin", 1.0 }, { "frequencymax", 1.0 },
                        { "phasemin", 0.0 }, { "phasemax", 0.0 },
                        { "scalemin", 1.0 }, { "scalemax", 1.0 }, { "mask", "1 0 0" } };
    const auto swing = [&](const ParticleOperatorOp& op) {
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].seed = 0.5f;
        RunOperator(op, particles, 0.1);
        return static_cast<double>(particles[0].position.x());
    };
    // The age is zero, so the wave is sin(f * dt) at frequency f.
    EXPECT_NEAR(swing(MakeOperator(fields)), std::sin(0.1), 1.0e-6);
    EXPECT_NEAR(swing(MakeOperator(fields, over)), std::sin(0.2), 1.0e-6);
    EXPECT_NEAR(swing(MakeOperatorIn(fields, IgnoringSpeedOverride(over))), std::sin(0.1), 1.0e-6);

    // An alpha oscillator has no speed binding in Wallpaper Engine.
    const json alpha { { "name", "oscillatealpha" }, { "frequencymin", 3.0 }, { "frequencymax", 3.0 },
                       { "phasemin", 0.0 }, { "phasemax", 0.0 }, { "scalemin", 0.0 }, { "scalemax", 1.0 } };
    const auto level = [&](const ParticleOperatorOp& op) {
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].seed     = 1.0f;
        particles[0].lifetime = 9.7f;
        RunOperator(op, particles, 0.1);
        return particles[0].alpha;
    };
    EXPECT_FLOAT_EQ(level(MakeOperator(alpha)), level(MakeOperator(alpha, over)));
}

TEST(Oscillators, PositionScaleMaxDefaultsToTheCanvasUnits) {
    ParticleParseContext pixels;
    pixels.over  = NoOverride();
    pixels.ortho = true;
    ParticleParseContext units = pixels;
    units.ortho                = false;
    const json fields { { "name", "oscillateposition" }, { "frequencymin", 1.0 }, { "frequencymax", 1.0 },
                        { "phasemin", 0.0 }, { "phasemax", 0.0 }, { "scalemin", 0.0 } };
    const auto pixel_op = WPParticleParser::genParticleOperatorOp(fields, pixels);
    const auto unit_op  = WPParticleParser::genParticleOperatorOp(fields, units);
    std::array<Particle, 1> a { LivingParticle() }, b { LivingParticle() };
    a[0].seed = b[0].seed = 1.0f;
    a[0].lifetime = b[0].lifetime = 9.0f;
    RunOperator(pixel_op, a, 0.1);
    RunOperator(unit_op, b, 0.1);
    EXPECT_NEAR(a[0].position.x() / b[0].position.x(), 10.0 / 0.5, 1.0e-3);
}

TEST(Oscillators, BlendWindowFadesTheSwingInOverTheLifetime) {
    const auto op = MakeOperator({ { "name", "oscillatealpha" },
                                   { "frequencymin", 1.0 }, { "frequencymax", 1.0 },
                                   { "phasemin", 0.0 }, { "phasemax", 0.0 },
                                   { "scalemin", 0.0 }, { "scalemax", 0.0 },
                                   { "blendinstart", 0.5 }, { "blendinend", 0.7 } });
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.seed = 1.0f;
    particles[0].lifetime = 7.0f;  // 30% through
    particles[1].lifetime = 4.0f;  // 60% through
    particles[2].lifetime = 2.0f;  // 80% through
    RunOperator(op, particles, 0.01);
    EXPECT_NEAR(particles[0].alpha, 1.0f, 1.0e-5f) << "before the window the operator does nothing";
    EXPECT_GT(particles[1].alpha, 0.0f);
    EXPECT_LT(particles[1].alpha, 1.0f);
    EXPECT_LT(particles[2].alpha, particles[1].alpha + 1.0e-6f);
}

TEST(Turbulence, EveryParticleRidesTheFieldAtItsOwnSpeed) {
    const json fields { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 200.0 },
                        { "scale", 0.01 }, { "timescale", 0.0 }, { "mask", "1 1 1" } };
    const auto op = MakeOperator(fields);
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.position = { 13.0f, 29.0f, 7.0f };
    particles[0].seed = 0.0f;
    particles[1].seed = 1.0f;
    RunOperator(op, particles, 0.1);
    // Same place, same noise: the speed range is the only difference.
    ASSERT_GT(particles[0].velocity.norm(), 0.0f);
    EXPECT_NEAR(particles[1].velocity.norm() / particles[0].velocity.norm(), 2.0f, 1.0e-3f);
    EXPECT_NEAR(particles[1].velocity.x() / particles[0].velocity.x(), 2.0f, 1.0e-3f);
}

TEST(Turbulence, TheSpeedOverrideScalesTheParticleSpeedUnlessTheFileIgnoresIt) {
    auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled = true;
    over->speed   = 2.5f;
    const json fields { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 200.0 },
                        { "scale", 0.01 }, { "timescale", 0.0 }, { "mask", "1 1 1" } };
    const auto kick = [&](const ParticleOperatorOp& op) {
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].position = { 13.0f, 29.0f, 7.0f };
        particles[0].seed     = 0.5f;
        RunOperator(op, particles, 0.1);
        return particles[0].velocity;
    };
    const linalg::Vector3f base = kick(MakeOperator(fields));
    ASSERT_GT(base.norm(), 0.0f);
    EXPECT_NEAR(kick(MakeOperator(fields, over)).norm() / base.norm(), 2.5f, 1.0e-3f);
    EXPECT_NEAR(kick(MakeOperatorIn(fields, IgnoringSpeedOverride(over))).norm() / base.norm(), 1.0f,
                1.0e-4f);
}

TEST(Turbulence, PhaseRangeDecorrelatesParticlesAtTheSamePlace) {
    const json fields { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 100.0 },
                        { "scale", 0.01 }, { "timescale", 0.0 }, { "mask", "1 1 1" },
                        { "phasemin", 0.0 }, { "phasemax", 500.0 } };
    const auto op = MakeOperator(fields);
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.position = { 13.0f, 29.0f, 7.0f };
    particles[0].seed = 0.1f;
    particles[1].seed = 0.9f;
    RunOperator(op, particles, 0.1);
    EXPECT_GT((particles[0].velocity - particles[1].velocity).norm(), 0.1f);
}

TEST(Turbulence, MaskWeightsScaleEachAxisAndZeroSkipsIt) {
    const json base { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 100.0 },
                      { "scale", 0.01 }, { "timescale", 0.0 } };
    json full = base, half = base;
    full["mask"] = "1 1 1";
    half["mask"] = "0.5 0 1";
    std::array<Particle, 1> a { LivingParticle() }, b { LivingParticle() };
    a[0].position = b[0].position = { 13.0f, 29.0f, 7.0f };
    RunOperator(MakeOperator(full), a, 0.1);
    RunOperator(MakeOperator(half), b, 0.1);
    EXPECT_NEAR(b[0].velocity.x(), 0.5f * a[0].velocity.x(), 1.0e-4f);
    EXPECT_EQ(b[0].velocity.y(), 0.0f);
    EXPECT_NEAR(b[0].velocity.z(), a[0].velocity.z(), 1.0e-4f);
}

TEST(Turbulence, TheFieldChangesWithTheSystemTime) {
    const json fields { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 100.0 },
                        { "scale", 0.01 }, { "timescale", 7.0 }, { "mask", "1 1 1" } };
    const auto op = MakeOperator(fields);
    std::array<Particle, 1> early { LivingParticle() }, late { LivingParticle() };
    early[0].position = late[0].position = { 13.0f, 29.0f, 7.0f };
    RunOperator(op, early, 0.1, {}, 0.0);
    RunOperator(op, late, 0.1, {}, 0.37);
    EXPECT_GT((early[0].velocity - late[0].velocity).norm(), 1.0e-3f);
}

TEST(Turbulence, BlendWindowSwitchesItOffOutsideTheLifetimeSpan) {
    const json fields { { "name", "turbulence" }, { "speedmin", 100.0 }, { "speedmax", 100.0 },
                        { "scale", 0.01 }, { "timescale", 0.0 }, { "mask", "1 1 1" },
                        { "blendinstart", 0.4 }, { "blendinend", 0.5 },
                        { "blendoutstart", 0.6 }, { "blendoutend", 0.7 } };
    const auto op = MakeOperator(fields);
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.position = { 13.0f, 29.0f, 7.0f };
    particles[0].lifetime = 9.0f; // 10%
    particles[1].lifetime = 4.5f; // 55%
    particles[2].lifetime = 1.0f; // 90%
    RunOperator(op, particles, 0.1);
    EXPECT_EQ(particles[0].velocity.norm(), 0.0f);
    EXPECT_GT(particles[1].velocity.norm(), 0.0f);
    EXPECT_EQ(particles[2].velocity.norm(), 0.0f);
}

TEST(Vortex, PushesParticlesAroundTheControlpointNotTheOrigin) {
    const json fields { { "name", "vortex" }, { "controlpoint", 1 }, { "axis", "0 0 1" },
                        { "distanceinner", 5.0 }, { "distanceouter", 10.0 },
                        { "speedinner", 10.0 }, { "speedouter", 0.0 } };
    const auto op = MakeOperator(fields);
    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[1].offset = linalg::Vector3d(100.0, 0.0, 0.0);
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 101.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0, controlpoints);
    // One unit along +x from the centre: swirls toward -y with the inner speed.
    EXPECT_NEAR(particles[0].velocity.x(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].velocity.y(), -10.0f, 1.0e-3f);
}

TEST(Vortex, SpeedFallsFromInnerToOuterWithoutAnExtraTenth) {
    const json fields { { "name", "vortex" }, { "axis", "0 0 1" },
                        { "distanceinner", 10.0 }, { "distanceouter", 20.0 },
                        { "speedinner", 100.0 }, { "speedouter", 0.0 } };
    const auto op = MakeOperator(fields);
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    particles[0].position = { 5.0f, 0.0f, 0.0f };
    particles[1].position = { 15.0f, 0.0f, 0.0f };
    particles[2].position = { 25.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    EXPECT_NEAR(particles[0].velocity.y(), -100.0f, 1.0e-3f);
    EXPECT_NEAR(particles[1].velocity.y(), -50.0f, 1.0e-3f);
    EXPECT_NEAR(particles[2].velocity.y(), 0.0f, 1.0e-3f);
}

TEST(Vortex, FlagOneMeasuresDistanceFromTheAxisAlone) {
    json fields { { "name", "vortex" }, { "axis", "0 0 1" },
                  { "distanceinner", 5.0 }, { "distanceouter", 10.0 },
                  { "speedinner", 10.0 }, { "speedouter", 0.0 } };
    std::array<Particle, 1> near_axis { LivingParticle() }, high_up { LivingParticle() };
    near_axis[0].position = { 1.0f, 0.0f, 0.0f };
    high_up[0].position   = { 1.0f, 0.0f, 1000.0f };
    // Measured in space, 1000 units up is far outside the outer radius.
    RunOperator(MakeOperator(fields), high_up, 1.0);
    EXPECT_NEAR(high_up[0].velocity.norm(), 0.0f, 1.0e-3f);
    // With the infinite-axis flag only the distance to the axis counts.
    fields["flags"] = 1;
    RunOperator(MakeOperator(fields), near_axis, 1.0);
    high_up[0].velocity = linalg::Vector3f::Zero();
    RunOperator(MakeOperator(fields), high_up, 1.0);
    EXPECT_NEAR(near_axis[0].velocity.y(), -10.0f, 1.0e-3f);
    EXPECT_NEAR(high_up[0].velocity.y(), near_axis[0].velocity.y(), 1.0e-3f);
}

TEST(Vortex, AudioLevelScalesTheSwirl) {
    audio::AudioSpectrumSnapshot spectrum;
    ParticleParseContext         ctx;
    ctx.over     = NoOverride();
    ctx.spectrum = [&spectrum]() { return spectrum; };
    const json fields { { "name", "vortex" }, { "axis", "0 0 1" }, { "distanceinner", 100.0 },
                        { "distanceouter", 200.0 }, { "speedinner", 10.0 },
                        { "audioprocessingmode", 3 }, { "audioprocessingbounds", "0 1" },
                        { "audioprocessingexponent", 1 }, { "audioprocessingfrequencystart", 0 },
                        { "audioprocessingfrequencyend", 0 } };
    const auto op = WPParticleParser::genParticleOperatorOp(fields, ctx);
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 1.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 1.0);
    EXPECT_EQ(particles[0].velocity.norm(), 0.0f) << "silence: no swirl";
    spectrum.average16[0] = 0.5f;
    RunOperator(op, particles, 1.0);
    // Smoothstep of one half is one half.
    EXPECT_NEAR(particles[0].velocity.norm(), 5.0f, 1.0e-3f);
}

TEST(ControlpointOperators, CapVelocityLimitsSpeedOnceItsBlendWindowOpens) {
    const auto op = MakeOperator({ { "name", "capvelocity" }, { "maxspeed", 50.0 },
                                   { "blendinstart", 0.2 }, { "blendinend", 0.2 } });
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    particles[0].velocity = { 200.0f, 0.0f, 0.0f };
    particles[1].velocity = { 200.0f, 0.0f, 0.0f };
    particles[0].lifetime = 9.0f; // 10%: not yet
    particles[1].lifetime = 5.0f; // 50%: capped
    RunOperator(op, particles, 0.01);
    EXPECT_NEAR(particles[0].velocity.x(), 200.0f, 1.0e-3f);
    EXPECT_NEAR(particles[1].velocity.x(), 50.0f, 1.0e-3f);
    particles[1].velocity = { 10.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.01);
    EXPECT_NEAR(particles[1].velocity.x(), 10.0f, 1.0e-4f) << "slower particles are left alone";
}

TEST(ControlpointOperators, ReduceMovementStopsParticlesNearTheControlpoint) {
    const auto op = MakeOperator({ { "name", "reducemovementnearcontrolpoint" },
                                   { "distanceinner", 20.0 }, { "distanceouter", 50.0 },
                                   { "reductioninner", 1000.0 } });
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.velocity = { 10.0f, 0.0f, 0.0f };
    particles[0].position = { 5.0f, 0.0f, 0.0f };
    particles[1].position = { 35.0f, 0.0f, 0.0f };
    particles[2].position = { 80.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.001);
    EXPECT_NEAR(particles[0].velocity.x(), 0.0f, 1.0e-4f) << "inside the inner radius: stopped";
    // Halfway between the radii the reduction is halfway between its two ends.
    EXPECT_NEAR(particles[1].velocity.x(), 5.0f, 1.0e-3f);
    EXPECT_NEAR(particles[2].velocity.x(), 10.0f, 1.0e-4f) << "beyond the outer radius: untouched";
}

TEST(ControlpointOperators, MaintainDistanceBetweenControlpointsKeepsParticlesOnTheMovingSegment) {
    const auto op = MakeOperator({ { "name", "maintaindistancebetweencontrolpoints" } });
    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[0].prev_offset = { 0.0, 0.0, 0.0 };
    controlpoints[1].prev_offset = { 100.0, 0.0, 0.0 };
    // Both ends move up 10 and the far end 20 farther along x.
    controlpoints[0].offset = { 0.0, 10.0, 0.0 };
    controlpoints[1].offset = { 120.0, 10.0, 0.0 };
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 50.0f, 3.0f, 0.0f };
    RunOperator(op, particles, 0.1, controlpoints);
    // Halfway along the old segment is halfway along the new one, 60, and the
    // sideways offset of 3 is kept, now at height 10.
    EXPECT_NEAR(particles[0].position.x(), 60.0f, 1.0e-3f);
    EXPECT_NEAR(particles[0].position.y(), 13.0f, 1.0e-3f);
}

TEST(ControlpointOperators, MaintainDistanceToAControlpointPullsOntoTheShell) {
    const auto op = MakeOperator({ { "name", "maintaindistancetocontrolpoint" }, { "distance", 10.0 } });
    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[0].prev_offset = { 0.0, 0.0, 0.0 };
    controlpoints[0].offset      = { 5.0, 0.0, 0.0 };
    std::array<Particle, 1> particles { LivingParticle() };
    particles[0].position = { 8.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.1, controlpoints);
    // Carried 5 along with the control point, then settled 10 from it.
    EXPECT_NEAR(particles[0].position.x(), 15.0f, 1.0e-4f);
}

TEST(Collision, PlaneBouncesSlidesStopsAndDeletes) {
    struct Case { const char* behavior; float vx; float vy; bool alive; };
    const Case cases[] = {
        { "bounce", 3.0f, 2.0f, true },
        { "slide", 3.0f, 0.0f, true },
        { "stop", 0.0f, 0.0f, true },
        { "delete", 3.0f, -4.0f, false },
    };
    for (const auto& c : cases) {
        const auto op = MakeOperator({ { "name", "collisionplane" }, { "plane", "0 1 0" },
                                       { "distance", 0.0 }, { "bouncefactor", 0.5 },
                                       { "collisionbehavior", c.behavior } });
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].position = { 0.0f, -1.0f, 0.0f };
        particles[0].velocity = { 3.0f, -4.0f, 0.0f };
        RunOperator(op, particles, 0.1);
        EXPECT_NEAR(particles[0].position.y(), c.alive ? 0.0f : 0.0f, 1.0e-5f) << c.behavior;
        EXPECT_NEAR(particles[0].velocity.x(), c.vx, 1.0e-4f) << c.behavior;
        EXPECT_NEAR(particles[0].velocity.y(), c.vy, 1.0e-4f) << c.behavior;
        // A deleted particle ends at the next age update, so a child bound to
        // it still sees it end.
        EXPECT_EQ(particles[0].lifetime > 1.0e-6f, c.alive) << c.behavior;
    }
}

TEST(Collision, EveryParticleFoundBehindThePlaneTakesTheResponseWhicheverWayItMoves) {
    // A particle that is behind the plane but already moving away from it is
    // not spared: the bounce reflects its velocity along the normal anyway and
    // a slide removes that component, as Wallpaper Engine's kernels do.
    const auto run = [](const char* behavior) {
        const auto op = MakeOperator({ { "name", "collisionplane" }, { "plane", "0 1 0" },
                                       { "distance", 0.0 }, { "bouncefactor", 0.5 },
                                       { "collisionbehavior", behavior } });
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].position = { 0.0f, -1.0f, 0.0f };
        particles[0].velocity = { 1.0f, 3.0f, 0.0f };
        RunOperator(op, particles, 0.1);
        return particles[0];
    };
    EXPECT_NEAR(run("bounce").velocity.y(), 3.0f - 1.5f * 3.0f, 1.0e-4f);
    EXPECT_NEAR(run("slide").velocity.y(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(run("slide").velocity.x(), 1.0f, 1.0e-4f);
}

TEST(Collision, SphereKeepsParticlesOutOfIt) {
    const auto op = MakeOperator({ { "name", "collisionsphere" }, { "radius", 10.0 },
                                   { "origin", "0 0 0" }, { "collisionbehavior", "slide" } });
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    particles[0].position = { 5.0f, 0.0f, 0.0f };
    particles[0].velocity = { -6.0f, 2.0f, 0.0f };
    particles[1].position = { 30.0f, 0.0f, 0.0f };
    RunOperator(op, particles, 0.1);
    EXPECT_NEAR(particles[0].position.norm(), 10.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].velocity.x(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].velocity.y(), 2.0f, 1.0e-4f);
    EXPECT_NEAR(particles[1].position.x(), 30.0f, 1.0e-6f);
}

TEST(Collision, ASphereWithoutAnOriginSitsTwoHundredBelowTheOriginInAPixelScene) {
    const json sphere { { "name", "collisionsphere" }, { "collisionbehavior", "stop" } };
    ParticleParseContext pixels;
    pixels.ortho = true;
    ParticleParseContext units;
    units.ortho = false;
    // The default radius is 50 in a pixel scene and 1 in scene units.
    std::array<Particle, 2> particles { LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.velocity = { 1.0f, 1.0f, 0.0f };
    particles[0].position = { 0.0f, -190.0f, 0.0f }; // inside the sphere at y = -200
    particles[1].position = { 0.0f, 0.0f, 0.0f };    // where a sphere at the origin would sit
    RunOperator(MakeOperatorIn(sphere, pixels), particles, 0.1);
    EXPECT_NEAR(particles[0].velocity.x(), 0.0f, 1.0e-6f);
    EXPECT_NEAR(particles[1].velocity.x(), 1.0f, 1.0e-6f) << "the middle of the canvas is free";

    std::array<Particle, 2> in_units { LivingParticle(), LivingParticle() };
    for (auto& p : in_units) p.velocity = { 1.0f, 1.0f, 0.0f };
    in_units[0].position = { 0.0f, -190.0f, 0.0f };
    in_units[1].position = { 0.0f, 0.5f, 0.0f };
    RunOperator(MakeOperatorIn(sphere, units), in_units, 0.1);
    EXPECT_NEAR(in_units[0].velocity.x(), 1.0f, 1.0e-6f);
    EXPECT_NEAR(in_units[1].velocity.x(), 0.0f, 1.0e-6f) << "scene units centre it on the origin";
}

/// A plane or sphere tied to control point 1, which is moved to (10, 100, 0) and
/// turned a quarter of a turn about z.
std::array<ParticleControlpoint, 8> TurnedControlpoint() {
    std::array<ParticleControlpoint, 8> points {};
    points[1].offset       = linalg::Vector3d(10.0, 100.0, 0.0);
    points[1].rotation     = linalg::AngleAxisd(M_PI / 2.0, linalg::Vector3d::UnitZ()).toRotationMatrix();
    points[1].has_rotation = true;
    return points;
}

TEST(Collision, FlagOneCarriesAPlaneWithTheControlpointAndTurnsItsNormal) {
    // Without the flag the plane stays where the file put it.
    const auto points = TurnedControlpoint();
    const json plane { { "name", "collisionplane" }, { "plane", "0 1 0" }, { "distance", 500.0 },
                       { "bouncefactor", 0.5 }, { "controlpoint", 1 } };
    {
        std::array<Particle, 1> particles { LivingParticle() };
        particles[0].position = { 15.0f, 0.0f, 0.0f };
        particles[0].velocity = { 5.0f, 0.0f, 0.0f };
        RunOperator(MakeOperator(plane), particles, 0.1, points);
        // Behind the unflagged plane (y < 500), pushed up to it.
        EXPECT_NEAR(particles[0].position.y(), 500.0f, 1.0e-3f);
    }
    // With it, the normal (0 1 0) turns to (-1 0 0) and the plane passes
    // through the control point: the file's distance of 500 is not read.
    json flagged  = plane;
    flagged["flags"] = 1;
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    particles[0].position = { 15.0f, 0.0f, 0.0f }; // 5 beyond the plane x = 10
    particles[0].velocity = { 5.0f, 0.0f, 0.0f };
    particles[1].position = { 5.0f, 0.0f, 0.0f };  // on the free side
    particles[1].velocity = { 5.0f, 0.0f, 0.0f };
    particles[2].position = { 15.0f, 500.0f, 0.0f };
    RunOperator(MakeOperator(flagged), particles, 0.1, points);
    EXPECT_NEAR(particles[0].position.x(), 10.0f, 1.0e-4f);
    EXPECT_NEAR(particles[0].position.y(), 0.0f, 1.0e-4f);
    // v = (5 0 0), n = (-1 0 0): the normal speed -5 comes back as +2.5 along n.
    EXPECT_NEAR(particles[0].velocity.x(), -2.5f, 1.0e-4f);
    EXPECT_NEAR(particles[1].position.x(), 5.0f, 1.0e-6f);
    EXPECT_NEAR(particles[1].velocity.x(), 5.0f, 1.0e-6f);
    EXPECT_NEAR(particles[2].position.x(), 10.0f, 1.0e-4f) << "y does not matter to the turned plane";
}

TEST(Collision, FlagOneCentresASphereOnTheControlpointAndIgnoresItsOwnOrigin) {
    const auto points = TurnedControlpoint();
    const json sphere { { "name", "collisionsphere" }, { "radius", 10.0 }, { "origin", "300 0 0" },
                        { "collisionbehavior", "stop" }, { "controlpoint", 1 }, { "flags", 1 } };
    std::array<Particle, 3> particles { LivingParticle(), LivingParticle(), LivingParticle() };
    for (auto& p : particles) p.velocity = { 1.0f, 0.0f, 0.0f };
    particles[0].position = { 10.0f, 105.0f, 0.0f }; // 5 from the control point
    particles[1].position = { 300.0f, 0.0f, 0.0f };  // at the file's own origin
    particles[2].position = { 10.0f, 130.0f, 0.0f }; // 30 away
    RunOperator(MakeOperator(sphere), particles, 0.1, points);
    EXPECT_NEAR(particles[0].velocity.x(), 0.0f, 1.0e-6f);
    EXPECT_NEAR((particles[0].position.cast<double>() - points[1].offset).norm(), 10.0, 1.0e-3);
    EXPECT_NEAR(particles[1].velocity.x(), 1.0f, 1.0e-6f);
    EXPECT_NEAR(particles[2].velocity.x(), 1.0f, 1.0e-6f);
}

TEST(Defaults, ControlpointIndexAboveSixIsTheLastControlpoint) {
    wpscene::Emitter emitter = ParseEmitter({ { "name", "boxrandom" }, { "controlpoint", 12 } });
    EXPECT_EQ(emitter.controlpoint, 7);
    emitter = ParseEmitter({ { "name", "boxrandom" }, { "controlpoint", -3 } });
    EXPECT_EQ(emitter.controlpoint, 7);
    emitter = ParseEmitter({ { "name", "boxrandom" }, { "controlpoint", 4 } });
    EXPECT_EQ(emitter.controlpoint, 4);
}

// ---------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------

TEST(AudioLevel, TheLoudestSelectedBandDecides) {
    // Bands 0..3 selected; only band 2 is loud.
    audio::AudioSpectrumSnapshot spectrum;
    spectrum.average16[2] = 1.0f;
    auto op = WPParticleParser::genParticleEmittOp(
        ParseEmitter({ { "name", "boxrandom" }, { "rate", 4 }, { "directions", "0 0 0" },
                       { "audioprocessingmode", 3 }, { "audioprocessingbounds", "0 1" },
                       { "audioprocessingexponent", 1 }, { "audioprocessingfrequencystart", 0 },
                       { "audioprocessingfrequencyend", 3 } }),
        false, nullptr, [&spectrum]() { return spectrum; });
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers { [](Particle& p, double) { PM::InitLifetime(p, 1000.0f); } };
    op(particles, initializers, 100, 1.0, {});
    // A mean over four bands would be a quarter; the loudest band is full scale.
    EXPECT_EQ(particles.size(), 4u);
}

// ---------------------------------------------------------------------------
// Subsystem: prewarm, followers, world space
// ---------------------------------------------------------------------------

// A stand-in for the particle shaders that shows which of the combos the scene
// parser asks for reached the shader: each one gates a uniform that carries a
// default, and a uniform that is compiled out is missing from the shader's
// defaults.
constexpr const char* kProbeVertex =
    "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
    "void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n";
constexpr const char* kProbeFragment =
    "// [COMBO] {\"material\":\"sheet blend\",\"combo\":\"SPRITESHEETBLEND\",\"type\":\"options\",\"default\":0}\n"
    "// [COMBO] {\"material\":\"thick\",\"combo\":\"THICKFORMAT\",\"type\":\"options\",\"default\":0}\n"
    "uniform sampler2D g_Texture0;\n"
    "#if SPRITESHEETBLEND\nuniform float g_ProbeBlend; // {\"material\":\"probe blend\",\"default\":1}\n#endif\n"
    "#if THICKFORMAT\nuniform float g_ProbeThick; // {\"material\":\"probe thick\",\"default\":1}\n#endif\n"
    "varying vec2 v_TexCoord;\n"
    "void main() {\n  gl_FragColor = texture(g_Texture0, v_TexCoord);\n"
    "#if SPRITESHEETBLEND\n  gl_FragColor.r += g_ProbeBlend;\n#endif\n"
    "#if THICKFORMAT\n  gl_FragColor.g += g_ProbeThick;\n#endif\n}\n";

struct ParticleScene {
    fs::VFS               vfs;
    audio::SoundManager   sound_manager;
    ProjectProperties     properties;
    std::shared_ptr<Scene> scene;

    ParticleScene(std::map<std::string, std::string> particle_files, const std::string& objects,
                  const std::string& general = R"("orthogonalprojection":{"width":640,"height":360})",
                  ProjectProperties initial_properties = {}, int version = -1) {
        properties = std::move(initial_properties);
        std::map<std::string, std::string> files {
            { "/mat.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
            { "/shaders/genericimage.vert",
              "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
              "void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
            { "/shaders/genericimage.frag",
              "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
              "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
            { "/mat_probe.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"comboprobe","textures":["a.tex"]}]})" },
            { "/shaders/comboprobe.vert", kProbeVertex },
            { "/shaders/comboprobe.frag", kProbeFragment },
            // The rope renderer swaps the material's shader for this name.
            { "/shaders/genericropeparticle.vert", kProbeVertex },
            { "/shaders/genericropeparticle.frag", kProbeFragment },
            { "/materials/a.tex.tex", "" },
        };
        for (auto& [name, content] : particle_files) files[name] = std::move(content);
        EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<test::MapFs>(FilesAsBytes(files))));
        scene = WPSceneParser().Parse(SceneParseRequest {
                                          .scene_id           = "particle-parity",
                                          .project_properties = &properties,
                                      },
                                      std::string(R"({
          "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
          "general": {"ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
            "clearcolor":[0,0,0], "cameraparallax":false, "cameraparallaxamount":0,
            "cameraparallaxdelay":0, "cameraparallaxmouseinfluence":0, )") +
                                          general + R"(},
          "objects": )" + objects +
                                          (version < 0 ? "" : R"(, "version": )" + std::to_string(version)) + "}",
                                      vfs,
                                      sound_manager);
    }

    ParticleSubSystem& Sub(std::size_t index = 0) { return *scene->paritileSys->subsystems.at(index); }
    void Step(int frames = 1, double dt = 1.0 / 60.0) {
        for (int i = 0; i < frames; ++i) {
            scene->frameTime = dt;
            scene->paritileSys->Emitt();
        }
    }
};

std::string ParticleFile(const std::string& emitter, const std::string& extra = "",
                         const std::string& initializer = R"({"name":"lifetimerandom","min":100,"max":100})",
                         const std::string& material = "mat.json") {
    return R"({"emitter":[)" + emitter + R"(],"initializer":[)" + initializer +
           R"(],"material":")" + material + R"(")" + (extra.empty() ? "" : "," + extra) + "}";
}

std::string OneParticleObject(const std::string& extra = "") {
    return R"([{"id":1,"name":"layer","particle":"particle.json","visible":true,"origin":"320 180 0")" +
           (extra.empty() ? "" : "," + extra) + "}]";
}

TEST(Prewarm, TheFirstFrameAlreadyShowsASystemThatHasLivedForItsStartTime) {
    ParticleScene fresh({ { "/particle.json",
                            ParticleFile(R"({"name":"sphererandom","id":1,"rate":10,"distancemax":0})",
                                         R"("maxcount":200,"starttime":0)") } },
                        OneParticleObject());
    ASSERT_NE(fresh.scene, nullptr);
    ASSERT_EQ(fresh.scene->paritileSys->subsystems.size(), 1u);
    EXPECT_TRUE(fresh.Sub().Instances().empty() ||
                LiveParticles(*fresh.Sub().Instances()[0]).empty())
        << "without a start time the system starts empty";

    ParticleScene warm({ { "/particle.json",
                           ParticleFile(R"({"name":"sphererandom","id":1,"rate":10,"distancemax":0})",
                                        R"("maxcount":200,"starttime":3.2)") } },
                       OneParticleObject());
    ASSERT_NE(warm.scene, nullptr);
    ASSERT_EQ(warm.Sub().Instances().size(), 1u);
    const auto live = LiveParticles(*warm.Sub().Instances()[0]);
    // 64 steps of 0.05 s at ten a second: half a particle a step.
    EXPECT_NEAR(static_cast<double>(live.size()), 32.0, 1.0);
    for (const auto& p : live) {
        EXPECT_LE(PM::LifetimePassed(p), 3.2 + 0.05 + 1.0e-3);
        EXPECT_GE(PM::LifetimePassed(p), 0.0);
    }
}

TEST(Prewarm, TheStepIsAFifthOfASecondOnceTheFileHoldsFiveHundredParticles) {
    const auto ages = [](int maxcount) {
        ParticleScene scene({ { "/particle.json",
                                ParticleFile(R"({"name":"sphererandom","id":1,"rate":10,"distancemax":0})",
                                             R"("maxcount":)" + std::to_string(maxcount) +
                                                 R"(,"starttime":2.0)") } },
                            OneParticleObject());
        std::set<long> distinct;
        EXPECT_EQ(scene.Sub().Instances().size(), 1u);
        for (const auto& p : LiveParticles(*scene.Sub().Instances()[0])) {
            distinct.insert(std::lround(PM::LifetimePassed(p) * 1000.0));
        }
        return distinct;
    };
    const auto coarse = ages(600);
    const auto fine   = ages(100);
    for (const long age : coarse) EXPECT_EQ(age % 200, 0) << age;
    EXPECT_LE(coarse.size(), 10u);
    EXPECT_GT(fine.size(), 15u);
}

TEST(Prewarm, AHugeStartTimeIsBoundedAndStillLeavesAPopulatedSystem) {
    const auto begin = std::chrono::steady_clock::now();
    ParticleScene scene({ { "/particle.json",
                            ParticleFile(R"({"name":"sphererandom","id":1,"rate":100,"distancemax":0})",
                                         R"("maxcount":64,"starttime":1000000,"flags":0)",
                                         R"({"name":"lifetimerandom","min":2,"max":2})") } },
                        OneParticleObject());
    const auto elapsed = std::chrono::steady_clock::now() - begin;
    ASSERT_EQ(scene.Sub().Instances().size(), 1u);
    EXPECT_FALSE(LiveParticles(*scene.Sub().Instances()[0]).empty());
    EXPECT_LT(std::chrono::duration<double>(elapsed).count(), 5.0);
}

TEST(Prewarm, AnEventChildStartsItsInstancesAlreadyAlong) {
    const auto child_age = [](const char* child_start) {
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":1,"distancemax":0})",
                             R"("maxcount":4,"children":[{"name":"child.json","type":"eventspawn","maxcount":2}])") },
              { "/child.json",
                ParticleFile(R"({"name":"sphererandom","id":2,"rate":20,"distancemax":0})",
                             std::string(R"("maxcount":100,"starttime":)") + child_start) } },
            OneParticleObject());
        EXPECT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
        scene.Step();
        const auto& children = scene.Sub().Children();
        EXPECT_EQ(children.size(), 1u);
        std::size_t live = 0;
        for (const auto& instance : children[0]->Instances()) live += LiveParticles(*instance).size();
        return live;
    };
    EXPECT_LE(child_age("0"), 2u);
    EXPECT_GE(child_age("1"), 19u);
}

TEST(Prewarm, AStaticChildPrewarmsAtConstructionWithItsOwnStartTime) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                         R"("maxcount":4,"starttime":0,"children":[{"name":"child.json","type":"static"}])") },
          { "/child.json",
            ParticleFile(R"({"name":"sphererandom","id":2,"rate":20,"distancemax":0})",
                         R"("maxcount":100,"starttime":1)") } },
        OneParticleObject());
    ASSERT_EQ(scene.Sub().Children().size(), 1u);
    const auto& instances = scene.Sub().Children()[0]->Instances();
    ASSERT_EQ(instances.size(), 1u);
    EXPECT_NEAR(static_cast<double>(LiveParticles(*instances[0]).size()), 20.0, 1.0);
}

TEST(Prewarm, AWorldspaceSystemIsPrewarmedAgainstTheMatrixItsLayerEndsUpWith) {
    // A layer joins its parent group after its particle system is built, and
    // the layer's matrix shapes where a worldspace system's particles are born.
    // The particle the prewarm spawns must sit where one born on the first frame
    // does: 5 units out, stretched by the layer's 2 and the group's 3, not by
    // the layer's 2 alone. A file that is not worldspace keeps its particles in
    // the layer's own space, where the matrix above changes nothing.
    for (const auto& [flags, out] : { std::pair<int, float> { 1, 30.0f }, { 0, 5.0f } }) {
        SCOPED_TRACE(flags);
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"boxrandom","id":1,"rate":0,"instantaneous":1,)"
                             R"("directions":"1 0 0","distancemin":"5 0 0","distancemax":"5 0 0"})",
                             R"("maxcount":4,"starttime":1,"flags":)" + std::to_string(flags)) } },
            R"([{"id":10,"name":"group","origin":"100 50 0","scale":"3 3 1","visible":true},)"
            R"({"id":1,"name":"layer","parent":10,"particle":"particle.json","visible":true,)"
            R"("origin":"20 10 0","scale":"2 2 1"}])");
        ASSERT_NE(scene.scene, nullptr);
        ASSERT_EQ(scene.Sub().WorldSpace(), flags == 1);
        ASSERT_EQ(scene.Sub().Instances().size(), 1u);
        const auto live = LiveParticles(*scene.Sub().Instances()[0]);
        ASSERT_EQ(live.size(), 1u);
        EXPECT_NEAR(std::abs(live[0].position.x()), out, 1.0e-3f);
        EXPECT_NEAR(live[0].position.y(), 0.0f, 1.0e-3f);
    }
}

TEST(Prewarm, AStaticChildIsPrewarmedOnceItsLayerHasJoinedItsGroup) {
    // A pinned control point is a place in the scene, carried into the layer's
    // space through the layer's matrix. The static child hangs under the layer
    // node, itself under a group, and the child's prewarm reads that whole chain.
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                         R"("maxcount":4,"starttime":0,"children":[{"name":"child.json","type":"static"}])") },
          { "/child.json",
            ParticleFile(R"({"name":"boxrandom","id":2,"rate":0,"instantaneous":1,"controlpoint":1,)"
                         R"("directions":"0 0 0"})",
                         R"("maxcount":4,"starttime":1,"controlpoint":[{"id":0},)"
                         R"({"id":1,"flags":2,"offset":"700 400 0"}])") } },
        R"([{"id":10,"name":"group","origin":"100 50 0","scale":"2 2 1","visible":true},)"
        R"({"id":1,"name":"layer","parent":10,"particle":"particle.json","visible":true,)"
        R"("origin":"20 10 0"}])");
    ASSERT_NE(scene.scene, nullptr);
    ASSERT_EQ(scene.Sub().Children().size(), 1u);
    const auto& instances = scene.Sub().Children()[0]->Instances();
    ASSERT_EQ(instances.size(), 1u);
    const auto live = LiveParticles(*instances[0]);
    ASSERT_EQ(live.size(), 1u);
    // The group puts the layer at 100 + 2 * 20 = 140, 50 + 2 * 10 = 70, drawn
    // twice as large: the scene place 700, 400 is 280, 165 from it in the
    // layer's own units.
    EXPECT_NEAR(live[0].position.x(), 280.0f, 1.0e-2f);
    EXPECT_NEAR(live[0].position.y(), 165.0f, 1.0e-2f);
}

/// How many simulation steps one event child instance runs through when it is
/// spawned, for a child file of `maxcount` particles and `starttime` seconds.
int StepsOfAnEventChildPrewarm(double starttime, u32 maxcount) {
    Scene scene;
    scene.frameTime = 0.25;
    ParticleSystem system(scene);
    system.gener = std::make_unique<SilentGener>();
    auto parent  = std::make_unique<ParticleSubSystem>(
        system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0, 1, 1.0,
        ParticleSubSystem::SpawnType::STATIC, [](const Particle&, const ParticleRawGenSpec&) {});
    auto child = std::make_unique<ParticleSubSystem>(
        system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), maxcount, 1.0, 2, 1.0,
        ParticleSubSystem::SpawnType::EVENT_SPAWN, [](const Particle&, const ParticleRawGenSpec&) {});
    int steps = 0;
    child->AddOperator([&steps](const ParticleInfo&) { ++steps; });
    child->SetStartTime(starttime);
    parent->AddChild(std::move(child));
    parent->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&, uint32_t,
                          double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle p;
        PM::InitLifetime(p, 100.0f);
        particles.push_back(p);
    });
    // The step that spawns the particle prewarms the child's instance, then
    // runs the child once more as part of the frame.
    parent->Emitt();
    return steps - 1;
}

TEST(Prewarm, AnEventChildInstanceRunsTheStepsOfItsStartTimeAndNoMoreThanTheCap) {
    // 0.05 s steps for a small file, 0.2 s once it holds 500 particles.
    EXPECT_NEAR(StepsOfAnEventChildPrewarm(2.0, 100), 40, 1);
    EXPECT_NEAR(StepsOfAnEventChildPrewarm(2.0, 600), 10, 1);
    EXPECT_EQ(StepsOfAnEventChildPrewarm(0.0, 100), 0) << "no start time, no prewarm";
    // A start time of hours is cut at the cap, so one spawn can never cost more
    // than that many steps of its own system.
    EXPECT_EQ(StepsOfAnEventChildPrewarm(1.0e7, 100), 6000);
    EXPECT_EQ(StepsOfAnEventChildPrewarm(1.0e7, 600), 6000);
}

// A parent that emits once and a follower child, driven directly.
struct FollowerRig {
    Scene                              scene;
    std::unique_ptr<ParticleSystem>    system;
    std::unique_ptr<ParticleSubSystem> parent;
    ParticleSubSystem*                 child { nullptr };
    int                                parent_spawns { 0 };

    FollowerRig() {
        scene.frameTime = 0.25;
        system          = std::make_unique<ParticleSystem>(scene);
        system->gener   = std::make_unique<SilentGener>();
        parent          = std::make_unique<ParticleSubSystem>(
            *system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0, 1, 1.0,
            ParticleSubSystem::SpawnType::STATIC, [](const Particle&, const ParticleRawGenSpec&) {});
        auto follower = std::make_unique<ParticleSubSystem>(
            *system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 16, 1.0, 2, 1.0,
            ParticleSubSystem::SpawnType::EVENT_FOLLOW,
            [](const Particle&, const ParticleRawGenSpec&) {});
        child = follower.get();
        parent->AddChild(std::move(follower));
        // The parent: a particle that lives one second, then another in the
        // same slot far away.
        parent->AddEmitter([this](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                  uint32_t, double, std::span<const ParticleControlpoint>) {
            const bool empty = particles.empty();
            const bool dead  = ! empty && ! PM::LifetimeOk(particles[0]);
            if ((! empty && ! dead) || parent_spawns >= 2) return;
            Particle p;
            PM::InitLifetime(p, 1.0f);
            p.position = { parent_spawns == 0 ? 0.0f : 100.0f, 0.0f, 0.0f };
            ++parent_spawns;
            if (empty) particles.push_back(p);
            else particles[0] = p;
        });
        // The follower emits one particle a step for as long as it may.
        child->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&, uint32_t,
                             double, std::span<const ParticleControlpoint>) {
            Particle p;
            PM::InitLifetime(p, 10.0f);
            particles.push_back(p);
        });
    }
    std::size_t FollowerLive() const {
        std::size_t live = 0;
        for (const auto& inst : child->Instances()) live += LiveParticles(*inst).size();
        return live;
    }
};

TEST(EventFollow, ParticlesAFollowerAlreadyEmittedOutliveTheParticleItFollowed) {
    FollowerRig rig;
    // The parent particle lives one second: it ends on the fourth step.
    for (int i = 0; i < 3; ++i) rig.parent->Emitt();
    ASSERT_EQ(rig.child->Instances().size(), 1u);
    const auto& first = *rig.child->Instances()[0];
    EXPECT_EQ(LiveParticles(first).size(), 3u);
    rig.parent->Emitt();
    // Its emitters stopped when the particle ended, but nothing was cleared.
    EXPECT_TRUE(first.IsDeath());
    EXPECT_EQ(LiveParticles(first).size(), 3u);
    const auto ages = [&] {
        std::vector<double> passed;
        for (const auto& p : LiveParticles(first)) passed.push_back(PM::LifetimePassed(p));
        return passed;
    };
    const auto   before = ages();
    const double oldest = *std::max_element(before.begin(), before.end());
    for (int i = 0; i < 4; ++i) rig.parent->Emitt();
    EXPECT_EQ(LiveParticles(first).size(), 3u) << "still alive and not growing";
    const auto later = ages();
    EXPECT_GT(*std::max_element(later.begin(), later.end()), oldest + 0.9) << "and still ageing";
    // The particle that took the slot got a follower of its own.
    EXPECT_EQ(rig.child->Instances().size(), 2u);
}

TEST(EventFollow, ALingeringFollowerStaysWhereItsParticleEnded) {
    FollowerRig rig;
    for (int i = 0; i < 12; ++i) rig.parent->Emitt();
    ASSERT_EQ(rig.parent_spawns, 2) << "the slot was reused by a particle elsewhere";
    ASSERT_EQ(rig.child->Instances().size(), 2u);
    EXPECT_NEAR(rig.child->Instances()[0]->GetBoundedData().pos.x(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(rig.child->Instances()[1]->GetBoundedData().pos.x(), 100.0f, 1.0e-4f);
}

TEST(WorldSpace, LiveParticlesStayPutWhenTheLayerMovesAndNewOnesFollowIt) {
    for (const bool world_space : { true, false }) {
        Scene scene;
        scene.frameTime = 0.01;
        ParticleSystem system(scene);
        system.gener = std::make_unique<SilentGener>();
        ParticleSubSystem subsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0,
                                    1, 1.0, ParticleSubSystem::SpawnType::STATIC,
                                    [](const Particle&, const ParticleRawGenSpec&) {});
        auto owner = std::make_shared<SceneNode>();
        subsystem.SetOwnerNode(owner);
        subsystem.SetWorldSpace(world_space);
        int spawned = 0;
        subsystem.AddEmitter([&spawned](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                        uint32_t, double, std::span<const ParticleControlpoint>) {
            if (spawned >= 2) return;
            Particle p;
            PM::InitLifetime(p, 100.0f);
            p.position = { 10.0f, 0.0f, 0.0f };
            particles.push_back(p);
            ++spawned;
        });
        subsystem.Emitt();
        owner->SetTranslate(linalg::Vector3f(100.0f, 0.0f, 0.0f));
        subsystem.Emitt();
        const auto& particles = subsystem.Instances()[0]->Particles();
        ASSERT_EQ(particles.size(), 2u);
        if (world_space) {
            EXPECT_NEAR(particles[0].position.x(), 10.0f - 100.0f, 1.0e-3f) << "stays in the scene";
        } else {
            EXPECT_NEAR(particles[0].position.x(), 10.0f, 1.0e-3f) << "carried with the layer";
        }
        // The one emitted after the move starts in the moved layer's own space.
        EXPECT_NEAR(particles[1].position.x(), 10.0f, 1.0e-3f);
    }
}

TEST(WorldSpace, ARotatingOrScalingLayerLeavesLiveParticlesAndTheirVelocityAlone) {
    // The particles of a worldspace system are in the scene's own axes and
    // units: turning or rescaling their layer changes neither where they are nor
    // which way, or how fast, they go. Only the layer's origin carries them.
    Scene scene;
    scene.frameTime = 0.01;
    ParticleSystem system(scene);
    system.gener = std::make_unique<SilentGener>();
    ParticleSubSystem subsystem(system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), 4, 1.0, 1,
                                1.0, ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {});
    auto owner = std::make_shared<SceneNode>();
    subsystem.SetOwnerNode(owner);
    subsystem.SetWorldSpace(true);
    bool spawned = false;
    subsystem.AddEmitter([&spawned](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                    uint32_t, double, std::span<const ParticleControlpoint>) {
        if (spawned) return;
        spawned = true;
        Particle p;
        PM::InitLifetime(p, 100.0f);
        p.position = { 5.0f, 7.0f, 0.0f };
        p.velocity = { 1.0f, 0.0f, 0.0f };
        particles.push_back(p);
    });
    subsystem.Emitt();
    owner->SetRotation(linalg::Vector3f(0.0f, 0.0f, static_cast<float>(M_PI / 2.0)));
    owner->SetScale(linalg::Vector3f(24.0f, 1.0f, 1.0f));
    subsystem.Emitt();
    const auto& p = subsystem.Instances()[0]->Particles()[0];
    EXPECT_NEAR(p.velocity.x(), 1.0f, 1.0e-4f);
    EXPECT_NEAR(p.velocity.y(), 0.0f, 1.0e-4f);
    EXPECT_NEAR(p.position.x(), 5.0f, 1.0e-4f);
    EXPECT_NEAR(p.position.y(), 7.0f, 1.0e-4f);
}

TEST(WorldSpace, AFollowerHangsWhereItsLayersMatrixPutsAWorldspaceParentsParticle) {
    // A worldspace parent's particles are scene units from the layer's origin;
    // its follower lives in the layer's own space and is drawn through the
    // layer's matrix, so it is hung where that matrix puts the same place.
    for (const bool world_space : { true, false }) {
        SCOPED_TRACE(world_space);
        FollowerRig rig;
        auto        owner      = std::make_shared<SceneNode>();
        auto        child_node = std::make_shared<SceneNode>();
        owner->AppendChild(child_node);
        owner->SetTranslate(linalg::Vector3f(10.0f, 0.0f, 0.0f));
        owner->SetScale(linalg::Vector3f(2.0f, 2.0f, 1.0f));
        rig.parent->SetOwnerNode(owner);
        rig.parent->SetWorldSpace(world_space);
        rig.child->SetOwnerNode(child_node);
        for (int i = 0; i < 12; ++i) rig.parent->Emitt();
        ASSERT_EQ(rig.child->Instances().size(), 2u);
        const float anchored = rig.child->Instances()[1]->GetBoundedData().pos.x();
        // The second parent particle is 100 out. In the layer's space that is
        // already the follower's coordinate; in scene units it is 50 of them.
        EXPECT_NEAR(anchored, world_space ? 50.0f : 100.0f, 1.0e-3f);
        child_node->UpdateTrans();
        const linalg::Vector3d hung =
            (child_node->ModelTrans() * linalg::Vector4d(anchored, 0.0, 0.0, 1.0)).head<3>();
        EXPECT_NEAR(hung.x(), world_space ? 10.0 + 100.0 : 10.0 + 200.0, 1.0e-3);
    }
}

TEST(WorldSpace, EveryRendererOfAFileIsDrawnFromItsLayersOriginAloneOrThroughItsWholeMatrix) {
    // A file with two renderers draws its particles through two nodes, the
    // second a child of the layer's that draws in the layer's own place. A
    // worldspace system hands both the matrix that is only the layer's origin;
    // any other system's nodes draw through the layer's whole matrix.
    for (const bool world_space : { true, false }) {
        SCOPED_TRACE(world_space);
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":3,"distancemax":10})",
                             std::string(R"("maxcount":8,"flags":)") + (world_space ? "1" : "0") +
                                 R"(,"renderer":[{"name":"sprite"},{"name":"spritetrail"}])") } },
            OneParticleObject(R"("scale":"24 1 1")"));
        scene.Step();
        SceneNode* layer = nullptr;
        for (const auto& node : scene.scene->sceneGraph->GetChildren()) {
            if (node != nullptr && node->Name() == "layer") layer = node.get();
        }
        ASSERT_NE(layer, nullptr);
        ASSERT_NE(layer->Mesh(), nullptr);
        ASSERT_EQ(layer->GetChildren().size(), 1u);
        SceneNode& second = *layer->GetChildren().front();
        ASSERT_NE(second.Mesh(), nullptr);
        for (SceneNode* node : { layer, &second }) {
            node->UpdateTrans();
            const linalg::Matrix4d drawn = node->RenderTrans();
            EXPECT_NEAR(drawn(0, 0), world_space ? 1.0 : 24.0, 1.0e-9);
            EXPECT_NEAR(drawn(1, 1), 1.0, 1.0e-9);
            EXPECT_NEAR(drawn(0, 3), 320.0, 1.0e-9);
            EXPECT_NEAR(drawn(1, 3), 180.0, 1.0e-9);
        }
    }
}

TEST(WorldSpace, ALayerUnderAScaledGroupIsDrawnFromItsOriginAndSpreadByTheWholeChain) {
    // The matrix a worldspace system is born by is its layer's world matrix, its
    // parent groups' included; the matrix it is drawn by is only where that puts
    // the layer's origin.
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"boxrandom","id":1,"rate":0,"instantaneous":1,)"
                         R"("directions":"1 0 0","distancemin":"5 0 0","distancemax":"5 0 0"})",
                         R"("maxcount":4,"flags":1)") } },
        R"([{"id":10,"name":"group","origin":"100 50 0","scale":"3 3 1","visible":true},)"
        R"({"id":1,"name":"layer","parent":10,"particle":"particle.json","visible":true,)"
        R"("origin":"20 10 0","scale":"2 2 1"}])");
    scene.Step();
    SceneNode* group = nullptr;
    for (const auto& node : scene.scene->sceneGraph->GetChildren()) {
        if (node != nullptr && node->Name() == "group") group = node.get();
    }
    ASSERT_NE(group, nullptr);
    ASSERT_EQ(group->GetChildren().size(), 1u);
    SceneNode& layer = *group->GetChildren().front();
    layer.UpdateTrans();
    const linalg::Matrix4d drawn = layer.RenderTrans();
    EXPECT_TRUE(linalg::Matrix3d(drawn.topLeftCorner<3, 3>()).isIdentity(1.0e-12));
    EXPECT_NEAR(drawn(0, 3), 100.0 + 3.0 * 20.0, 1.0e-9);
    EXPECT_NEAR(drawn(1, 3), 50.0 + 3.0 * 10.0, 1.0e-9);
    ASSERT_EQ(scene.Sub().Instances().size(), 1u);
    const auto live = LiveParticles(*scene.Sub().Instances()[0]);
    ASSERT_EQ(live.size(), 1u);
    EXPECT_NEAR(std::abs(live[0].position.x()), 5.0 * 2.0 * 3.0, 1.0e-3);
}

TEST(WorldSpace, TheFlagIsReadFromTheParticleFile) {
    ParticleScene scene({ { "/particle.json",
                            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                                         R"("maxcount":4,"flags":1)") } },
                        OneParticleObject());
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    EXPECT_TRUE(scene.Sub().WorldSpace());
    ParticleScene plain({ { "/particle.json",
                            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                                         R"("maxcount":4,"flags":0)") } },
                        OneParticleObject());
    EXPECT_FALSE(plain.Sub().WorldSpace());
}

// ---------------------------------------------------------------------------
// Parse level
// ---------------------------------------------------------------------------

TEST(ParseLevel, RandomFrameNeverBlendsNeighbouringSpriteFrames) {
    wpscene::Particle particle;
    EXPECT_TRUE(particle.BlendsSpriteFrames());
    particle.animationmode = "sequence";
    EXPECT_TRUE(particle.BlendsSpriteFrames());
    particle.animationmode = "randomframe";
    EXPECT_FALSE(particle.BlendsSpriteFrames());
    particle.animationmode = "sequence";
    particle.flags.set(wpscene::Particle::FlagEnum::spritenoframeblending);
    EXPECT_FALSE(particle.BlendsSpriteFrames());
}

TEST(ParseLevel, StartTimeIsAFractionOfASecond) {
    ParticleScene scene({ { "/particle.json",
                            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                                         R"("maxcount":4,"starttime":0.5)") } },
                        OneParticleObject());
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    EXPECT_DOUBLE_EQ(scene.Sub().StartTime(), 0.5);
}

TEST(ParseLevel, TwoSizeInitializersOfOneFileScaleTheParticlesItSpawns) {
    // The falling-leaf preset: a size of 70 to 75, then 0.7 to 1 of it.
    ParticleScene scene({ { "/particle.json",
                            ParticleFile(R"({"name":"boxrandom","id":1,"rate":0,"instantaneous":200,"directions":"0 0 0"})",
                                         R"("maxcount":256,"flags":0)",
                                         R"({"name":"lifetimerandom","min":100,"max":100},)"
                                         R"({"name":"sizerandom","min":70,"max":75},)"
                                         R"({"name":"sizerandom","min":0.7,"max":1.0},)"
                                         R"({"name":"alpharandom","min":0.5,"max":0.5},)"
                                         R"({"name":"alpharandom","min":0.5,"max":1.0})") } },
                        OneParticleObject());
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    scene.Step();
    ASSERT_EQ(scene.Sub().Instances().size(), 1u);
    const auto live = LiveParticles(*scene.Sub().Instances()[0]);
    ASSERT_EQ(live.size(), 200u);
    for (const auto& p : live) {
        EXPECT_GE(p.size, 49.0f - 1.0e-3f);
        EXPECT_LE(p.size, 75.0f + 1.0e-3f);
        // Half, then 0.5 to 1 of that: replacing would leave 0.5 to 1.
        EXPECT_GE(p.alpha, 0.25f - 1.0e-5f);
        EXPECT_LE(p.alpha, 0.5f + 1.0e-5f);
    }
}

TEST(ParseLevel, EmitterTimingKeysAreRead) {
    const auto emitter = ParseEmitter({ { "name", "sphererandom" }, { "delay", 0.2 }, { "duration", 3 },
                                        { "flags", 4 }, { "minperiodicduration", 1 },
                                        { "maxperiodicduration", 2 }, { "minperiodicdelay", 3 },
                                        { "maxperiodicdelay", 4 }, { "maxtoemitperperiod", 32 },
                                        { "cone", 0.5 } });
    EXPECT_FLOAT_EQ(emitter.delay, 0.2f);
    EXPECT_FLOAT_EQ(emitter.duration, 3.0f);
    EXPECT_TRUE(emitter.flags[wpscene::Emitter::FlagEnum::periodic]);
    EXPECT_FLOAT_EQ(emitter.minperiodicduration, 1.0f);
    EXPECT_FLOAT_EQ(emitter.maxperiodicdelay, 4.0f);
    EXPECT_EQ(emitter.maxtoemitperperiod, 32u);
    EXPECT_FLOAT_EQ(emitter.cone, 0.5f);
}

TEST(ParseLevel, RopeRendererFillsWhatTheFileLeavesOutWithItsOwnDefaults) {
    wpscene::ParticleRender rope;
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" } }));
    EXPECT_FLOAT_EQ(rope.subdivision, 4.0f);
    EXPECT_TRUE(rope.uvsmoothing);
    EXPECT_FALSE(rope.uvscrolling);
    EXPECT_FLOAT_EQ(rope.uvscale, 1.0f);

    wpscene::ParticleRender trail;
    ASSERT_TRUE(trail.FromJson({ { "name", "ropetrail" } }));
    EXPECT_FLOAT_EQ(trail.length, 1.0f);
    EXPECT_FLOAT_EQ(trail.segments, 4.0f);
    EXPECT_FLOAT_EQ(trail.subdivision, 1.0f);
    EXPECT_FALSE(trail.uvsmoothing);
}

TEST(ParseLevel, RopeRendererTruncatesAndClampsWhatItReads) {
    wpscene::ParticleRender rope;
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" }, { "subdivision", 3.9 } }));
    EXPECT_FLOAT_EQ(rope.subdivision, 3.0f);
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" }, { "subdivision", 99 } }));
    EXPECT_FLOAT_EQ(rope.subdivision, 32.0f);
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" }, { "subdivision", -4 } }));
    EXPECT_FLOAT_EQ(rope.subdivision, 0.0f);

    wpscene::ParticleRender trail;
    ASSERT_TRUE(trail.FromJson({ { "name", "ropetrail" }, { "segments", 1 }, { "length", 0 },
                                 { "subdivision", 40 } }));
    EXPECT_FLOAT_EQ(trail.segments, 2.0f);
    EXPECT_FLOAT_EQ(trail.length, 0.001f);
    EXPECT_FLOAT_EQ(trail.subdivision, 32.0f);
    ASSERT_TRUE(trail.FromJson({ { "name", "ropetrail" }, { "segments", 99 } }));
    EXPECT_FLOAT_EQ(trail.segments, 32.0f);
}

TEST(ParseLevel, RopeSmoothingIsReadOnlyWhileTheTextureDoesNotScroll) {
    wpscene::ParticleRender rope;
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" }, { "uvsmoothing", false } }));
    EXPECT_FALSE(rope.uvsmoothing);
    ASSERT_TRUE(rope.FromJson({ { "name", "rope" }, { "uvscrolling", true }, { "uvsmoothing", true } }));
    EXPECT_FALSE(rope.uvsmoothing);
    wpscene::ParticleRender trail;
    ASSERT_TRUE(trail.FromJson({ { "name", "ropetrail" }, { "uvsmoothing", true } }));
    EXPECT_FALSE(trail.uvsmoothing);
}

TEST(ParseLevel, SpriteTrailKeepsItsOwnDefaults) {
    wpscene::ParticleRender trail;
    ASSERT_TRUE(trail.FromJson({ { "name", "spritetrail" } }));
    EXPECT_FLOAT_EQ(trail.length, 0.05f);
    EXPECT_FLOAT_EQ(trail.maxlength, 10.0f);
    EXPECT_FLOAT_EQ(trail.minlength, 0.0f);
}

TEST(ParseLevel, InstanceOverrideReadsControlpointsAngleAndBrightness) {
    wpscene::ParticleInstanceoverride over;
    ASSERT_TRUE(over.FromJosn({ { "controlpoint1", "100 200 0" },
                                { "controlpointangle2", { { "value", "0 0 1.5" } } },
                                { "controlpoint7", { { "user", "pos" }, { "value", "1 2 3" } } },
                                { "brightness", 5.0 } }));
    EXPECT_TRUE(over.controlpointSet[1]);
    EXPECT_FLOAT_EQ(over.controlpoint[1][1], 200.0f);
    EXPECT_FALSE(over.controlpointSet[0]);
    EXPECT_TRUE(over.controlpointangleSet[2]);
    EXPECT_FLOAT_EQ(over.controlpointangle[2][2], 1.5f);
    EXPECT_TRUE(over.controlpointSet[7]);
    EXPECT_EQ(over.bindings.at("controlpoint7"), "pos");
    EXPECT_FLOAT_EQ(over.brightness, 5.0f);
}

TEST(ParseLevel, ControlpointsOfTheSceneObjectReplaceThePresetsAndTurnThem) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                         R"("maxcount":4,"controlpoint":[{"id":1,"offset":"5 5 0","flags":0}])") } },
        OneParticleObject(R"("instanceoverride":{"id":1,"controlpoint1":"100 200 0","controlpointangle1":"0 0 1.5707963"})"));
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    scene.Step();
    const auto points = scene.Sub().Controlpoints();
    EXPECT_NEAR(points[1].offset.x(), 100.0, 1.0e-4);
    EXPECT_NEAR(points[1].offset.y(), 200.0, 1.0e-4);
    EXPECT_TRUE(points[1].has_rotation);
    EXPECT_NEAR(points[1].rotation(1, 0), 1.0, 1.0e-5) << "a quarter turn about z";
    EXPECT_FALSE(points[0].has_rotation);
}

TEST(ParseLevel, APinnedControlpointHoldsItsScenePositionWhileTheLayerMoves) {
    // Flag 2 pins a control point (after the first) to scene coordinates.
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"distancemax":0})",
                         R"("maxcount":4,"controlpoint":[{"id":0,"offset":"0 0 0","flags":0},{"id":1,"offset":"100 0 0","flags":2}])") } },
        OneParticleObject());
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    scene.Step();
    // The layer sits at (320, 180): a point pinned at (100, 0) is (-220, -180) from it.
    const auto points = scene.Sub().Controlpoints();
    EXPECT_NEAR(points[1].offset.x(), 100.0 - 320.0, 1.0e-3);
    EXPECT_NEAR(points[1].offset.y(), 0.0 - 180.0, 1.0e-3);
}

TEST(ParseLevel, ThePixelCanvasFlagFollowsTheProjectionTheSceneIsDrawnWith) {
    wpscene::WPSceneGeneral pixel;
    ASSERT_TRUE(pixel.FromJson({ { "orthogonalprojection", { { "width", 1920 }, { "height", 1080 } } } }));
    EXPECT_TRUE(pixel.pixelCanvas);
    wpscene::WPSceneGeneral automatic;
    ASSERT_TRUE(automatic.FromJson({ { "orthogonalprojection", { { "auto", true } } } }));
    EXPECT_TRUE(automatic.pixelCanvas);
    wpscene::WPSceneGeneral empty;
    ASSERT_TRUE(empty.FromJson({ { "orthogonalprojection", { { "width", 0 }, { "height", 0 } } } }));
    EXPECT_FALSE(empty.pixelCanvas);
    wpscene::WPSceneGeneral perspective;
    ASSERT_TRUE(perspective.FromJson({ { "orthogonalprojection", nullptr } }));
    EXPECT_FALSE(perspective.isOrtho);
    EXPECT_FALSE(perspective.pixelCanvas);
    // No key: this loader draws the scene as its default orthogonal canvas, so
    // its particles take the pixel defaults rather than flipping to scene units.
    wpscene::WPSceneGeneral absent;
    ASSERT_TRUE(absent.FromJson(json::object()));
    EXPECT_TRUE(absent.isOrtho);
    EXPECT_TRUE(absent.pixelCanvas);
}

/// The sizes of six particles whose `sizerandom` leaves its range out, in a scene
/// whose `general` block is `general`.
std::vector<float> SizesWithDefaultRange(const std::string& general) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":6,"distancemax":0})",
                         R"("maxcount":8)",
                         R"({"name":"lifetimerandom","min":100,"max":100},{"name":"sizerandom"})") } },
        OneParticleObject(), general);
    std::vector<float> sizes;
    if (scene.scene == nullptr || scene.scene->paritileSys->subsystems.empty()) {
        ADD_FAILURE() << "the scene did not parse";
        return sizes;
    }
    scene.Step();
    for (const auto& instance : scene.Sub().Instances()) {
        for (const auto& p : LiveParticles(*instance)) sizes.push_back(p.size);
    }
    return sizes;
}

TEST(ParseLevel, ASceneDrawnAsACanvasKeepsPixelDefaultsWhetherOrNotItNamesAProjection) {
    for (const std::string general : { std::string(R"("orthogonalprojection":{"width":640,"height":360})"),
                                       std::string(R"("orthogonalprojection":{"auto":true})"),
                                       std::string(R"("bloom":false)") }) {
        const auto sizes = SizesWithDefaultRange(general);
        ASSERT_EQ(sizes.size(), 6u) << general;
        for (const float size : sizes) {
            EXPECT_GE(size, 5.0f) << general;
            EXPECT_LE(size, 50.0f) << general;
        }
    }
}

TEST(ParseLevel, AScenePlacedInSceneUnitsFillsParticleDefaultsInSceneUnits) {
    const auto sizes = SizesWithDefaultRange(R"("orthogonalprojection":null)");
    ASSERT_EQ(sizes.size(), 6u);
    for (const float size : sizes) {
        EXPECT_GE(size, 0.001f);
        EXPECT_LE(size, 1.0f);
    }
}

// ---------------------------------------------------------------------------
// The scene object's overrides, followed while the scene runs
// ---------------------------------------------------------------------------

TEST(InstanceOverride, BrightnessIsFoundAmongTheBindingsOfAUserProperty) {
    wpscene::ParticleInstanceoverride over;
    ASSERT_TRUE(over.FromJosn({ { "brightness", { { "user", "glow" }, { "value", 3.0 } } },
                                { "speed", { { "user", "pace" }, { "value", 2.0 } } } }));
    ASSERT_EQ(over.bindings.count("brightness"), 1u);
    EXPECT_EQ(over.bindings.at("brightness"), "glow");
    EXPECT_FLOAT_EQ(over.brightness, 3.0f);
}

// Stand-ins for the HDR bloom materials an HDR scene is drawn with: a scene
// renders in HDR only with its bloom on.
std::map<std::string, std::string> HdrBloomStandIns() {
    const std::string vert = "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
                             "varying vec2 v_TexCoord;\nvoid main() {\n"
                             "  gl_Position = vec4(a_Position, 1.0);\n  v_TexCoord = a_TexCoord;\n}\n";
    const std::string frag = "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
                             "void main() {\n  gl_FragColor = texture(g_Texture0, v_TexCoord);\n}\n";
    std::map<std::string, std::string> files;
    for (const char* material : { "hdr_downsample_bloom", "hdr_downsample", "hdr_upsample",
                                  "combine_hdr_upsample_linear" }) {
        files[std::string("/materials/util/") + material + ".json"] =
            R"({"passes":[{"shader":"bloom_stand_in","cullmode":"nocull","blending":"normal",)"
            R"("depthwrite":"disabled","depthtest":"disabled"}]})";
    }
    files["/shaders/bloom_stand_in.vert"] = vert;
    files["/shaders/bloom_stand_in.frag"] = frag;
    return files;
}

TEST(InstanceOverride, BoundControlpointAngleAndBrightnessFollowTheirPropertiesAsTheSceneRuns) {
    ProjectProperties properties {
        { "where", RuntimeScalarValue::String("100 200 0") },
        { "turn", RuntimeScalarValue::String("0 0 0") },
        { "glow", RuntimeScalarValue::Float(1.0f) },
    };
    auto files = HdrBloomStandIns();
    files["/particle.json"] =
        ParticleFile(R"({"name":"sphererandom","id":1,"rate":30,"distancemax":0})",
                     R"("maxcount":64,"controlpoint":[{"id":1,"offset":"5 5 0","flags":0}])");
    ParticleScene scene(
        files,
        OneParticleObject(R"("instanceoverride":{"id":1,)"
                          R"("controlpoint1":{"user":"where","value":"100 200 0"},)"
                          R"("controlpointangle1":{"user":"turn","value":"0 0 0"},)"
                          R"("brightness":{"user":"glow","value":1}})"),
        R"("orthogonalprojection":{"width":640,"height":360},"hdr":true,"bloom":true)", properties);
    ASSERT_NE(scene.scene, nullptr);
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    ASSERT_NE(scene.scene->runtime, nullptr);

    scene.Step(4);
    {
        const auto points = scene.Sub().Controlpoints();
        EXPECT_NEAR(points[1].offset.x(), 100.0, 1.0e-4);
        EXPECT_NEAR(points[1].offset.y(), 200.0, 1.0e-4);
        // An angle of zero is still an angle the object set.
        EXPECT_TRUE(points[1].has_rotation);
        EXPECT_NEAR(points[1].rotation(1, 0), 0.0, 1.0e-5);
    }
    const auto brightest = [&] {
        float highest = 0.0f;
        for (const auto& p : LiveParticles(*scene.Sub().Instances()[0])) {
            highest = std::max(highest, p.init.color.x());
        }
        return highest;
    };
    EXPECT_NEAR(brightest(), 1.0f, 1.0e-4f);

    scene.scene->runtime->ApplyProjectPropertyOverride({
        { "where", RuntimeScalarValue::String("300 40 0") },
        { "turn", RuntimeScalarValue::String("0 0 1.5707963") },
        { "glow", RuntimeScalarValue::Float(4.0f) },
    });
    scene.Step(4);
    const auto points = scene.Sub().Controlpoints();
    EXPECT_NEAR(points[1].offset.x(), 300.0, 1.0e-4) << "the bound control point moved";
    EXPECT_NEAR(points[1].offset.y(), 40.0, 1.0e-4);
    EXPECT_NEAR(points[1].rotation(1, 0), 1.0, 1.0e-5) << "and turned a quarter about z";
    EXPECT_NEAR(points[1].rotation(0, 0), 0.0, 1.0e-5);
    EXPECT_NEAR(brightest(), 4.0f, 1.0e-4f) << "particles born after the change glow four times as bright";
    float dimmest = 99.0f;
    for (const auto& p : LiveParticles(*scene.Sub().Instances()[0])) dimmest = std::min(dimmest, p.init.color.x());
    EXPECT_NEAR(dimmest, 1.0f, 1.0e-4f) << "and the ones born before it keep their colour";
}

TEST(InstanceOverride, TheSpeedOverrideScalesTheEmitterSpeedUnlessTheFileIgnoresIt) {
    const auto speed_of_first = [](const std::string& flags) {
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":3,"distancemax":0,)"
                             R"("speedmin":10,"speedmax":10})",
                             R"("maxcount":8)" + flags) } },
            OneParticleObject(R"("instanceoverride":{"id":1,"speed":3})"));
        scene.Step();
        const auto live = LiveParticles(*scene.Sub().Instances()[0]);
        EXPECT_EQ(live.size(), 3u);
        return live.empty() ? 0.0f : live.front().velocity.norm();
    };
    EXPECT_NEAR(speed_of_first(""), 30.0f, 1.0e-3f);
    EXPECT_NEAR(speed_of_first(R"(,"flags":16)"), 10.0f, 1.0e-3f);
}

TEST(InstanceOverride, TheSizeOverrideScalesTheBirthSizeAndEachSizeRampUnlessTheFileIgnoresIt) {
    // A file whose `sizerandom` draws 40 and whose two `sizechange` ramps each
    // hold 0.5, under an instance size override of 3. Wallpaper Engine gives the
    // draw and each ramp the override: 40 * 3 * (0.5 * 3)^2 = 270. A file with
    // the "ignore size override" flag (128) keeps it out of all three: 10.
    const auto size_of_first = [](const std::string& flags) {
        const std::string ramp = R"({"name":"sizechange","starttime":0,"endtime":1,"startvalue":0.5,"endvalue":0.5})";
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":3,"distancemax":0})",
                             R"("maxcount":8,"operator":[)" + ramp + "," + ramp + "]" + flags,
                             R"({"name":"lifetimerandom","min":100,"max":100},)"
                             R"({"name":"sizerandom","min":40,"max":40})") } },
            OneParticleObject(R"("instanceoverride":{"id":1,"size":3})"));
        scene.Step(2);
        const auto live = LiveParticles(*scene.Sub().Instances()[0]);
        EXPECT_EQ(live.size(), 3u);
        return live.empty() ? 0.0f : live.front().size;
    };
    EXPECT_NEAR(size_of_first(""), 270.0f, 1.0e-2f);
    EXPECT_NEAR(size_of_first(R"(,"flags":128)"), 10.0f, 1.0e-3f);
    EXPECT_NEAR(size_of_first(R"(,"flags":16)"), 270.0f, 1.0e-2f) << "the speed flag leaves the size alone";
}

TEST(InstanceOverride, FromSceneVersionFiveARetintedPresetIsNotTintedByTheOverrideAgain) {
    // A grey preset under a dark teal override, as Wallpaper Engine 2.8 draws it
    // (probe scenes captured in the VM): a scene saved at version 4 or before
    // re-tints the grey to the teal and multiplies by the teal once more; from
    // version 5 the re-tint is the colour.
    const auto colour_at = [](int version) {
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":1,"distancemax":0})",
                             R"("maxcount":4)",
                             R"({"name":"lifetimerandom","min":100,"max":100},)"
                             R"({"name":"colorrandom","min":"92 95 97","max":"92 95 97"})") } },
            OneParticleObject(R"("instanceoverride":{"id":1,"colorn":"0.2 0.4 0.6"})"),
            R"("orthogonalprojection":{"width":640,"height":360})", {}, version);
        scene.Step();
        const auto live = LiveParticles(*scene.Sub().Instances()[0]);
        EXPECT_EQ(live.size(), 1u);
        return live.empty() ? linalg::Vector3f::Zero().eval() : live.front().color;
    };
    const linalg::Vector3f before = colour_at(4);
    EXPECT_NEAR(before.x(), 0.04f, 1.0e-3f);
    EXPECT_NEAR(before.y(), 0.16f, 1.0e-3f);
    EXPECT_NEAR(before.z(), 0.36f, 1.0e-3f);
    for (const int version : { 5, 6 }) {
        const linalg::Vector3f now = colour_at(version);
        EXPECT_NEAR(now.x(), 0.2f, 1.0e-3f) << "version " << version;
        EXPECT_NEAR(now.y(), 0.4f, 1.0e-3f) << "version " << version;
        EXPECT_NEAR(now.z(), 0.6f, 1.0e-3f) << "version " << version;
    }
    const linalg::Vector3f unversioned = colour_at(-1);
    EXPECT_NEAR(unversioned.y(), 0.16f, 1.0e-3f) << "a scene without a version is an old one";
}

TEST(ParseLevel, TheIgnoreSizeOverrideFlagIsTheOneHundredTwentyEightBitOfTheFilesFlags) {
    wpscene::Particle plain;
    EXPECT_TRUE(plain.AppliesSizeOverride());
    plain.flags.set(wpscene::Particle::FlagEnum::ignoresizeoverride);
    EXPECT_FALSE(plain.AppliesSizeOverride());
    EXPECT_TRUE(plain.AppliesSpeedOverride());
    EXPECT_EQ(plain.flags.count(), 1u);
    EXPECT_TRUE(plain.flags[7u]);
}

TEST(ParseLevel, TheIgnoreSpeedOverrideFlagIsTheSixteenBitOfTheFilesFlags) {
    wpscene::Particle plain;
    EXPECT_TRUE(plain.AppliesSpeedOverride());
    plain.flags.set(wpscene::Particle::FlagEnum::ignorespeedoverride);
    EXPECT_FALSE(plain.AppliesSpeedOverride());
    EXPECT_EQ(plain.flags.count(), 1u);
    EXPECT_TRUE(plain.flags[4u]);
}

// ---------------------------------------------------------------------------
// Several renderers in one file
// ---------------------------------------------------------------------------

std::size_t CountMeshes(const SceneNode& node) {
    std::size_t count = 0;
    for (const auto& child : node.GetChildren()) {
        if (child->Mesh() != nullptr) ++count;
        count += CountMeshes(*child);
    }
    return count;
}

/// The meshes of a scene graph in drawing order: a layer's own, then the one
/// each extra renderer of its file added, then its children's.
std::vector<SceneMesh*> CollectMeshes(SceneNode& root) {
    std::vector<SceneMesh*>         meshes;
    std::function<void(SceneNode&)> collect = [&](SceneNode& node) {
        for (auto& child : node.GetChildren()) {
            if (child->Mesh() != nullptr) meshes.push_back(child->Mesh());
            collect(*child);
        }
    };
    collect(root);
    return meshes;
}

const std::string kThreeInABurst =
    R"({"name":"boxrandom","id":1,"rate":0,"instantaneous":3,"directions":"1 0 0","distancemax":"100 0 0"})";

TEST(MultipleRenderers, EachRendererEntryDrawsTheSameParticlesThroughAMeshOfItsOwn) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":3,"distancemax":10})",
                         R"("maxcount":8,"renderer":[{"name":"sprite"},{"name":"spritetrail"}])") } },
        OneParticleObject());
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 2u) << "one mesh per renderer entry";
    scene.Step(2);
    const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
    ASSERT_EQ(meshes.size(), 2u);
    for (auto* mesh : meshes) {
        EXPECT_EQ(mesh->GetIndexArray(0).DrawIndexCount(), 3u * 6u) << "three quads each";
    }
}

TEST(MultipleRenderers, AFileWithOneRendererStillMakesOneMesh) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":3,"distancemax":10})",
                         R"("maxcount":8,"renderer":[{"name":"sprite"}])") } },
        OneParticleObject());
    EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 1u);
}

/// What a mesh was built as and the shader its material draws through.
struct MeshKind {
    bool        rope { false };
    bool        sprite { false };
    bool        thick { false };
    std::string shader;
};

MeshKind KindOf(SceneMesh& mesh) {
    MeshKind kind;
    if (mesh.VertexCount() > 0) {
        kind.rope   = mesh.GetVertexArray(0).GetOption(WE_PRENDER_ROPE);
        kind.sprite = mesh.GetVertexArray(0).GetOption(WE_PRENDER_SPRITE);
        kind.thick  = mesh.GetVertexArray(0).GetOption(WE_CB_THICK_FORMAT);
    }
    if (mesh.Material() != nullptr && mesh.Material()->customShader.shader != nullptr) {
        kind.shader = mesh.Material()->customShader.shader->name;
    }
    return kind;
}

/// The uniforms the compiled shader of `mesh` really uses. The shader's list of
/// defaults names every annotated uniform whatever the combos select; its
/// reflection lists only the ones that survived compilation.
std::set<std::string> ActiveUniforms(const SceneMesh& mesh) {
    std::set<std::string> names;
    if (mesh.Material() == nullptr || mesh.Material()->customShader.shader == nullptr ||
        ! mesh.Material()->customShader.shader->rust_reflection_json) {
        return names;
    }
    const json reflection =
        json::parse(*mesh.Material()->customShader.shader->rust_reflection_json, nullptr, false);
    if (reflection.is_discarded() || ! reflection.contains("uniform_blocks")) return names;
    for (const auto& block : reflection.at("uniform_blocks")) {
        if (! block.contains("members")) continue;
        for (const auto& member : block.at("members")) names.insert(member.at("name").get<std::string>());
    }
    return names;
}

TEST(MultipleRenderers, EachEntryDrawsThroughItsOwnShaderWhateverTheEntryBeforeItWas) {
    // The file's material names an ordinary shader; the rope entry swaps it for
    // the rope shader on its own copy and must not change the sprite's.
    for (const bool rope_first : { true, false }) {
        const std::string renderers = rope_first ? R"([{"name":"rope"},{"name":"sprite"}])"
                                                 : R"([{"name":"sprite"},{"name":"rope"}])";
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(kThreeInABurst, R"("maxcount":8,"renderer":)" + renderers) } },
            OneParticleObject());
        ASSERT_NE(scene.scene, nullptr);
        const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
        ASSERT_EQ(meshes.size(), 2u) << renderers;
        const MeshKind rope   = KindOf(*meshes[rope_first ? 0 : 1]);
        const MeshKind sprite = KindOf(*meshes[rope_first ? 1 : 0]);
        EXPECT_TRUE(rope.rope) << renderers;
        EXPECT_EQ(rope.shader, "genericropeparticle") << renderers;
        EXPECT_TRUE(sprite.sprite) << renderers;
        EXPECT_FALSE(sprite.rope) << renderers;
        EXPECT_EQ(sprite.shader, "genericimage") << renderers;
    }
}

/// Live particles of the first instance in slot order, as how long each has lived.
std::vector<double> AgesInSlotOrder(ParticleScene& scene) {
    std::vector<double> ages;
    if (scene.Sub().Instances().empty()) return ages;
    for (const auto& p : scene.Sub().Instances()[0]->Particles()) {
        if (PM::LifetimeOk(p)) ages.push_back(PM::LifetimePassed(p));
    }
    return ages;
}

/// Whether, over a run in which short-lived particles keep dying and being
/// replaced, the live particles stayed in birth order (oldest first) after every step.
bool StaysInBirthOrder(const std::string& renderers) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"boxrandom","id":1,"rate":60,"directions":"0 0 0"})",
                         R"("maxcount":8,"renderer":)" + renderers,
                         R"({"name":"lifetimerandom","min":0.06,"max":0.06})") } },
        OneParticleObject());
    bool ordered = true;
    for (int step = 0; step < 24; ++step) {
        scene.Step(1, 1.0 / 60.0);
        const auto ages = AgesInSlotOrder(scene);
        for (std::size_t i = 1; i < ages.size(); ++i) {
            if (ages[i] > ages[i - 1] + 1.0e-9) ordered = false;
        }
    }
    return ordered;
}

TEST(MultipleRenderers, APlainRopeInAnyEntryKeepsTheSharedSlotsInBirthOrder) {
    // A rope joins consecutive live slots, so the slots of the system that
    // feeds it must not be refilled out of order. That has to hold when the rope
    // is the second entry, not only the first.
    EXPECT_TRUE(StaysInBirthOrder(R"([{"name":"rope"}])"));
    EXPECT_TRUE(StaysInBirthOrder(R"([{"name":"sprite"},{"name":"rope"}])"));
    EXPECT_TRUE(StaysInBirthOrder(R"([{"name":"rope"},{"name":"sprite"}])"));
    // The control: without a plain rope, a dead slot is simply reused where it is.
    EXPECT_FALSE(StaysInBirthOrder(R"([{"name":"sprite"}])"));
}

TEST(MultipleRenderers, ARopeTrailInTheListDoesNotOrderTheSlots) {
    EXPECT_FALSE(StaysInBirthOrder(R"([{"name":"sprite"},{"name":"ropetrail"}])"));
}

TEST(Renderers, AnEmptyRendererListDrawsNothingButTheSystemStillRuns) {
    // Two particle files whose renderer list is empty, one of them also with a
    // colour ramp that leaves its start out: nothing is drawn for either, and
    // the first still spawns the child it parents.
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":2,"distancemax":0})",
                         R"("maxcount":4,"renderer":[],"operator":[{"name":"colorchange","endvalue":"1 1 1"}],)"
                         R"("children":[{"name":"child.json","type":"eventspawn","maxcount":4}])") },
          { "/child.json",
            ParticleFile(R"({"name":"sphererandom","id":2,"rate":0,"instantaneous":1,"distancemax":0})",
                         R"("maxcount":4,"renderer":[])") } },
        OneParticleObject());
    ASSERT_NE(scene.scene, nullptr);
    ASSERT_EQ(scene.scene->paritileSys->subsystems.size(), 1u);
    EXPECT_FALSE(scene.Sub().Drawn());
    EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 0u);
    scene.Step(3);
    ASSERT_EQ(scene.Sub().Instances().size(), 1u);
    EXPECT_EQ(LiveParticles(*scene.Sub().Instances()[0]).size(), 2u) << "the system is simulated";
    ASSERT_EQ(scene.Sub().Children().size(), 1u);
    std::size_t spawned = 0;
    for (const auto& instance : scene.Sub().Children()[0]->Instances()) {
        spawned += LiveParticles(*instance).size();
    }
    EXPECT_GT(spawned, 0u) << "and still spawns children";
    EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 0u);
}

TEST(Renderers, AFileThatLeavesTheRendererKeyOutOrHoldsNoArrayThereGetsADefaultSprite) {
    for (const char* extra : { R"("maxcount":4)", R"("maxcount":4,"renderer":"sprite")",
                               R"("maxcount":4,"renderer":null)" }) {
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":2,"distancemax":10})",
                             extra) } },
            OneParticleObject());
        ASSERT_NE(scene.scene, nullptr) << extra;
        EXPECT_TRUE(scene.Sub().Drawn()) << extra;
        EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 1u) << extra;
    }
}

TEST(Renderers, ARendererListWithoutEntriesBuildsNoMeshForAChildEither) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":1,"distancemax":0})",
                         R"("maxcount":4,"children":[{"name":"child.json","type":"static"}])") },
          { "/child.json",
            ParticleFile(R"({"name":"sphererandom","id":2,"rate":5,"distancemax":0})",
                         R"("maxcount":4,"renderer":[])") } },
        OneParticleObject());
    ASSERT_NE(scene.scene, nullptr);
    EXPECT_EQ(CountMeshes(*scene.scene->sceneGraph), 1u) << "the parent's sprite only";
    ASSERT_EQ(scene.Sub().Children().size(), 1u);
    EXPECT_FALSE(scene.Sub().Children()[0]->Drawn());
}

TEST(Renderers, RandomFrameDropsTheSheetBlendFromTheShaderWhateverTheFileAsks) {
    const auto defaults = [](const std::string& extra) {
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":2,"distancemax":10})",
                             R"("maxcount":4)" + extra,
                             R"({"name":"lifetimerandom","min":100,"max":100})", "mat_probe.json") } },
            OneParticleObject());
        const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
        EXPECT_EQ(meshes.size(), 1u);
        return meshes.empty() ? std::set<std::string> {} : ActiveUniforms(*meshes[0]);
    };
    EXPECT_TRUE(defaults("").count("g_ProbeBlend")) << "a sequence blends neighbouring frames";
    EXPECT_TRUE(defaults(R"(,"animationmode":"sequence")").count("g_ProbeBlend"));
    EXPECT_FALSE(defaults(R"(,"animationmode":"randomframe")").count("g_ProbeBlend"));
    EXPECT_FALSE(defaults(R"(,"flags":2)").count("g_ProbeBlend")) << "the file's own no-blending flag";
}

// ---------------------------------------------------------------------------
// Rope geometry
// ---------------------------------------------------------------------------

void AddThickRopeTrailMesh(SceneMesh& mesh, uint32_t capacity) {
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C2.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C3.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC4.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
    };
    mesh.AddVertexArray(SceneVertexArray(attrs, capacity * 4));
    mesh.AddIndexArray(SceneIndexArray(capacity, PlanParticleIndexLayout(capacity).width));
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPETRAIL, true);
    mesh.GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, true);
}

TEST(RopeGeometry, ATrailIsDrawnAsOnePiecePerSubdivisionBetweenItsRecordedPoints) {
    const auto quads = [](uint32_t subdivision) {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddThickRopeTrailMesh(mesh, 64);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        auto instance = std::make_unique<ParticleInstance>();
        Particle p;
        PM::InitLifetime(p, 10.0f);
        p.position = { 4.0f, 0.0f, 0.0f };
        instance->ParticlesVec().push_back(p);
        auto& trail = instance->TrailsVec().emplace_back();
        trail.Reset(4);
        for (int i = 1; i <= 4; ++i) trail.Push({ linalg::Vector3f(4.0f - static_cast<float>(i), 0.0f, 0.0f) });
        instances.push_back(std::move(instance));
        WPParticleRawGener   gener;
        ParticleRawGenSpecOp spec = [](const Particle&, const ParticleRawGenSpec&) {};
        ParticleOverflowFlags flags;
        ParticleRenderScale   scale;
        scale.rope_subdivision = subdivision;
        gener.GenGLData(instances, mesh, spec, scale, flags);
        return mesh.GetIndexArray(0).DrawIndexCount() / 6;
    };
    // Four recorded points plus the particle make four segments.
    EXPECT_EQ(quads(1), 4u);
    EXPECT_EQ(quads(2), 8u);
    EXPECT_EQ(quads(5), 20u);
}

TEST(RopeGeometry, APlainRopeIsOneMorePiecePerPairThanItsSubdivisionAndThickInEveryRendererPosition) {
    for (const int subdivision : { 0, 2, 5 }) {
        const std::string rope = R"({"name":"rope","subdivision":)" + std::to_string(subdivision) + "}";
        for (const bool first : { true, false }) {
            const std::string renderers =
                first ? "[" + rope + "]" : R"([{"name":"sprite"},)" + rope + "]";
            ParticleScene scene(
                { { "/particle.json",
                    ParticleFile(kThreeInABurst, R"("maxcount":8,"renderer":)" + renderers,
                                 R"({"name":"lifetimerandom","min":100,"max":100})", "mat_probe.json") } },
                OneParticleObject());
            ASSERT_NE(scene.scene, nullptr);
            scene.Step(2);
            const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
            ASSERT_EQ(meshes.size(), first ? 1u : 2u);
            const std::size_t at = first ? 0 : 1;
            const MeshKind    kind = KindOf(*meshes[at]);
            EXPECT_TRUE(kind.rope) << renderers;
            EXPECT_TRUE(kind.thick) << "a plain rope carries an end size and colour per piece";
            // Three connected particles are two pairs, each drawn as subdivision + 1 pieces.
            EXPECT_EQ(meshes[at]->GetIndexArray(0).DrawIndexCount() / 6,
                      2u * static_cast<std::size_t>(subdivision + 1))
                << renderers;
            EXPECT_TRUE(ActiveUniforms(*meshes[at]).count("g_ProbeThick"))
                << "THICKFORMAT reaches the shader";
        }
    }
}

TEST(RopeGeometry, ATrailRecordsItsSegmentsAndEncodesTheStripTheySubdivideInto) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"boxrandom","id":1,"rate":0,"instantaneous":1,"directions":"0 0 0"})",
                         R"("maxcount":4,"renderer":[{"name":"ropetrail","length":1,"segments":3,"subdivision":1}])",
                         R"({"name":"lifetimerandom","min":100,"max":100})", "mat_probe.json") } },
        OneParticleObject());
    ASSERT_NE(scene.scene, nullptr);
    const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
    ASSERT_EQ(meshes.size(), 1u);
    const auto& constants = meshes[0]->Material()->customShader.constValues;
    const auto  var0      = constants.find("g_RenderVar0");
    ASSERT_NE(var0, constants.end());
    ASSERT_GE(var0->second.size(), 4u);
    EXPECT_FLOAT_EQ(var0->second[0], 3.0f) << "three recorded points";
    // Every recorded pair is drawn as subdivision + 1 = 2 pieces: a strip of 6.
    EXPECT_FLOAT_EQ(var0->second[3], EncodeRopeTrailLength(6.0f, 1.0f));
    EXPECT_NE(var0->second[3], EncodeRopeTrailLength(3.0f, 1.0f));
    const auto kind = KindOf(*meshes[0]);
    EXPECT_TRUE(kind.rope);
    EXPECT_TRUE(kind.thick);
    // Room for every particle's strip: 4 particles x 3 recorded points x 2 pieces.
    EXPECT_EQ(meshes[0]->GetIndexArray(0).QuadCapacity(), 4u * 3u * 2u);
}

TEST(Renderers, ATwoDimensionalSceneSetsTheEyeTwoThousandUnitsInFrontOfTheCanvas) {
    ParticleScene scene(
        { { "/particle.json",
            ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":1,"distancemax":0})",
                         R"("maxcount":4)") } },
        OneParticleObject());
    const auto meshes = CollectMeshes(*scene.scene->sceneGraph);
    ASSERT_EQ(meshes.size(), 1u);
    const auto& constants = meshes[0]->Material()->customShader.constValues;
    const auto  eye       = constants.find("g_EyePosition");
    ASSERT_NE(eye, constants.end());
    ASSERT_GE(eye->second.size(), 3u);
    EXPECT_FLOAT_EQ(eye->second[0], 320.0f);
    EXPECT_FLOAT_EQ(eye->second[1], 180.0f);
    EXPECT_FLOAT_EQ(eye->second[2], 2000.0f);
}

/// The node of `root`'s subtree that draws a mesh through the camera `camera`.
SceneNode* FindMeshNodeOnCamera(SceneNode& root, std::string_view camera) {
    for (auto& child : root.GetChildren()) {
        if (child->Mesh() != nullptr && child->Camera() == camera) return child.get();
        if (auto* found = FindMeshNodeOnCamera(*child, camera)) return found;
    }
    return nullptr;
}

// A particle with the `perspective` flag draws through the 2D scene's perspective
// camera, which sits where the field of view puts it. The eye its shaders read is
// not that camera's position: Wallpaper Engine keeps it at the view's centre, 2000
// units in front of the canvas, and a trail's ribbon turns on the angle between
// the particle and that eye. A narrow field of view puts the camera far out and a
// wide one close, and neither moves the shader's eye.
TEST(Renderers, APerspectiveParticleReadsTheEyeTwoThousandUnitsOutWhateverTheLens) {
    for (const double fov : { 30.0, 95.0, 150.0 }) {
        SCOPED_TRACE("perspectiveoverridefov " + std::to_string(fov));
        ParticleScene scene(
            { { "/particle.json",
                ParticleFile(R"({"name":"sphererandom","id":1,"rate":0,"instantaneous":1,"distancemax":0})",
                             R"("maxcount":4,"flags":4)") } },
            OneParticleObject(),
            R"("orthogonalprojection":{"width":640,"height":360},"perspectiveoverridefov":)" +
                std::to_string(fov));
        ASSERT_NE(scene.scene, nullptr);
        auto* node = FindMeshNodeOnCamera(*scene.scene->sceneGraph, "global_perspective");
        ASSERT_NE(node, nullptr);
        auto* updater = scene.scene->shaderValueUpdater.get();
        ASSERT_NE(updater, nullptr);
        updater->InitUniforms(node, 0, [](std::string_view name) { return name == "g_EyePosition"; });
        const auto read_eye = [&] {
            std::array<float, 3> eye { 0.0f, 0.0f, 0.0f };
            sprite_map_t         sprites;
            updater->UpdateUniforms(node, sprites,
                                    [&](std::string_view name, const ShaderValue& value) {
                                        if (name == "g_EyePosition") eye = { value[0], value[1], value[2] };
                                    });
            return eye;
        };

        const double distance =
            scene.scene->cameras.at("global_perspective")->GetPosition().z();
        ASSERT_NEAR(distance, 180.0 / std::tan(fov * M_PI / 360.0), distance * 1e-5);
        auto eye = read_eye();
        EXPECT_NEAR(eye[0], 320.0f, 1e-3f);
        EXPECT_NEAR(eye[1], 180.0f, 1e-3f);
        EXPECT_NEAR(eye[2], 2000.0f, 1e-3f);

        // A reframed canvas moves the view's centre and the camera's distance.
        scene.scene->FrameCanvas(2.0, linalg::Vector2f(-40.0f, 20.0f));
        eye = read_eye();
        EXPECT_NEAR(eye[0], 280.0f, 1e-3f);
        EXPECT_NEAR(eye[1], 200.0f, 1e-3f);
        EXPECT_NEAR(eye[2], 2000.0f, 1e-3f);
    }
}

// ---------------------------------------------------------------------------
// Opt-in: every particle file of a local library simulates
// ---------------------------------------------------------------------------

/// One particle file of the local library, built as a static subsystem whose
/// control points are scattered about.
struct CorpusRig {
    Scene                              scene;
    std::unique_ptr<ParticleSystem>    system;
    std::unique_ptr<ParticleSubSystem> subsystem;
    uint32_t                           maxcount { 0 };
    double                             starttime { 0.0 };

    /// Null for a document that is not a loadable particle file. `start_cap` caps
    /// the start time the subsystem prewarms for; a negative value keeps it.
    static std::unique_ptr<CorpusRig> Load(const std::filesystem::path& path, double start_cap) {
        std::ifstream stream(path);
        json          document = json::parse(stream, nullptr, false);
        if (document.is_discarded() || ! document.is_object() || ! document.contains("emitter") ||
            ! document.contains("material")) {
            return nullptr;
        }
        document["material"] = "mat.json";
        document.erase("children");
        wpscene::Particle particle;
        fs::VFS           vfs;
        if (! vfs.Mount("/assets",
                        std::make_unique<test::MapFs>(FilesAsBytes(
                            { { "/mat.json", R"({"passes":[]})" } })))) {
            return nullptr;
        }
        if (! particle.FromJson(document, vfs)) return nullptr;

        auto rig = std::make_unique<CorpusRig>();
        rig->scene.frameTime = 1.0 / 60.0;
        rig->system          = std::make_unique<ParticleSystem>(rig->scene);
        rig->system->gener   = std::make_unique<SilentGener>();
        rig->maxcount        = std::min<uint32_t>(particle.maxcount, 20000u);
        rig->subsystem       = std::make_unique<ParticleSubSystem>(
            *rig->system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), rig->maxcount, 1.0, 1, 1.0,
            ParticleSubSystem::SpawnType::STATIC, [](const Particle&, const ParticleRawGenSpec&) {});
        auto over     = std::make_shared<wpscene::ParticleInstanceoverride>();
        over->enabled = true;
        ParticleParseContext ctx;
        ctx.over  = over;
        ctx.spawn = rig->subsystem->SpawnContext();
        ctx.color = WPParticleParser::analyzeColorSources(particle.initializers, particle.operators);
        for (const auto& emitter : particle.emitters) {
            rig->subsystem->AddEmitter(WPParticleParser::genParticleEmittOp(emitter, false, over));
        }
        for (const auto& initializer : particle.initializers) {
            rig->subsystem->AddInitializer(WPParticleParser::genParticleInitOp(initializer, ctx));
        }
        for (const auto& op : particle.operators) {
            rig->subsystem->AddOperator(WPParticleParser::genParticleOperatorOp(op, ctx));
        }
        rig->starttime = static_cast<double>(particle.starttime);
        rig->subsystem->SetStartTime(start_cap < 0.0 ? rig->starttime : std::min(rig->starttime, start_cap));
        auto points = rig->subsystem->Controlpoints();
        for (std::size_t i = 0; i < points.size(); ++i) {
            points[i].base_offset = linalg::Vector3d(120.0 * static_cast<double>(i), -40.0 * static_cast<double>(i), 0.0);
            points[i].offset      = points[i].base_offset;
            points[i].prev_offset = points[i].offset;
        }
        return rig;
    }
};

/// `WE_TEST_PARTICLE_DIR` names a directory of unpacked scenes. Every particle
/// file under it (its emitters, initializers and operators, with control points
/// scattered about and one of them moving) is run for twenty seconds of
/// simulated time, and no particle may ever hold a non-finite value or exceed
/// the file's `maxcount`.
TEST(ParticleCorpus, EveryLocalParticleFileSimulatesWithoutNonFiniteValues) {
    const char* directory = std::getenv("WE_TEST_PARTICLE_DIR");
    if (directory == nullptr || *directory == '\0') {
        GTEST_SKIP() << "WE_TEST_PARTICLE_DIR names no directory of unpacked scenes";
    }
    std::size_t files = 0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
        if (! entry.is_regular_file() || entry.path().extension() != ".json") continue;
        auto rig = CorpusRig::Load(entry.path(), 5.0);
        if (! rig) continue;
        ++files;
        auto& subsystem = *rig->subsystem;
        auto  points    = subsystem.Controlpoints();
        subsystem.Prewarm();
        for (int frame = 0; frame < 1200; ++frame) {
            points[1].base_offset.x() = 300.0 * std::sin(frame * 0.05);
            points[1].offset          = points[1].base_offset;
            subsystem.Emitt();
            for (const auto& instance : subsystem.Instances()) {
                ASSERT_LE(instance->Particles().size(), static_cast<std::size_t>(rig->maxcount))
                    << entry.path().filename();
                for (const auto& p : instance->Particles()) {
                    if (! PM::LifetimeOk(p)) continue;
                    ASSERT_TRUE(p.position.allFinite() && p.velocity.allFinite() &&
                                p.color.allFinite() && std::isfinite(p.alpha) &&
                                std::isfinite(p.size) && p.angularVelocity.allFinite() &&
                                p.rotation.allFinite())
                        << entry.path() << " frame " << frame;
                }
            }
        }
    }
    EXPECT_GT(files, 0u) << "no particle file under " << directory;
}

/// What the prewarm costs on the local library, with each file's own start
/// time (not the five-second cap of the test above): the slowest few files and
/// the total are printed, so the figure quoted in the notes can be reproduced.
/// An event child pays the same per spawned instance. Reports; asserts only that
/// no file's prewarm is unbounded.
TEST(ParticleCorpus, PrewarmCostOfTheLocalLibraryIsReported) {
    const char* directory = std::getenv("WE_TEST_PARTICLE_DIR");
    if (directory == nullptr || *directory == '\0') {
        GTEST_SKIP() << "WE_TEST_PARTICLE_DIR names no directory of unpacked scenes";
    }
    std::vector<std::pair<double, std::string>> costs;
    double                                      total_ms = 0.0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
        if (! entry.is_regular_file() || entry.path().extension() != ".json") continue;
        auto rig = CorpusRig::Load(entry.path(), -1.0);
        if (! rig || rig->starttime <= 0.0) continue;
        const auto begin = std::chrono::steady_clock::now();
        rig->subsystem->Prewarm();
        const double ms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
        total_ms += ms;
        costs.emplace_back(ms, entry.path().filename().string() + " (starttime " +
                                   std::to_string(rig->starttime) + ", maxcount " +
                                   std::to_string(rig->maxcount) + ")");
        EXPECT_LT(ms, 5000.0) << entry.path();
    }
    std::sort(costs.rbegin(), costs.rend());
    std::fprintf(stderr, "prewarm cost: %zu files with a start time, %.1f ms in all\n", costs.size(), total_ms);
    for (std::size_t i = 0; i < costs.size() && i < 5; ++i) {
        std::fprintf(stderr, "  %7.2f ms  %s\n", costs[i].first, costs[i].second.c_str());
    }
    RecordProperty("prewarm_total_ms", std::to_string(total_ms));
    if (! costs.empty()) RecordProperty("prewarm_slowest_ms", std::to_string(costs.front().first));
}

} // namespace
} // namespace wallpaper
