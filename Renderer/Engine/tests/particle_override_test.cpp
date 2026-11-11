// A scene object can override how its particle file behaves (`instanceoverride`): alpha, size,
// speed, lifetime, colour, and how often and how many particles are emitted. A field may be
// bound to a project property and then follows it live. These tests cover the record itself,
// the birth-time initializer and the rate / count overrides.
//
// CPU only: no geometry, no renderer.

#include "Particle/ParticleEmitter.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneMesh.h"
#include "WPParticleParser.hpp"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <array>
#include <cmath>
#include <functional>
#include <limits>
#include <memory>
#include <vector>

using namespace wallpaper;
using nlohmann::json;

namespace
{

using Override = wpscene::ParticleInstanceoverride;

std::shared_ptr<Override> EnabledOverride() {
    auto over     = std::make_shared<Override>();
    over->enabled = true;
    return over;
}

// A box emitter with the default shape and the given steady rate.
wpscene::Emitter SteadyEmitter() {
    return wpscene::Emitter { .instantaneous = 0, .name = "boxrandom", .rate = 1.0f };
}

std::size_t Alive(std::span<const Particle> slots) {
    std::size_t n = 0;
    for (const Particle& p : slots) n += p.lifetime > 0.0f ? 1 : 0;
    return n;
}

// A one-step-per-second subsystem whose particles live ten seconds, so the live count after
// each Emitt() is the number emitted so far.
struct EmissionRig {
    Scene              scene;
    ParticleSystem     system { scene };
    ParticleSubSystem* subsystem { nullptr };

    explicit EmissionRig(uint32_t maxcount = 8) {
        scene.frameTime = 1.0;
        auto made       = std::make_unique<ParticleSubSystem>(
            system, std::make_shared<SceneMesh>(MeshUpdate::PerFrame), maxcount, 1.0, 1, 1.0,
            ParticleSubSystem::SpawnType::STATIC, [](const Particle&, const ParticleRawGenSpec&) {});
        subsystem = made.get();
        subsystem->AddInitializer(
            [](Particle& p, double) { ParticleModify::InitLifetime(p, 10.0f); });
        system.subsystems.push_back(std::move(made));
    }

    std::size_t LiveCount() const {
        if (subsystem->Instances().empty()) return 0;
        return Alive(subsystem->Instances().front()->Particles());
    }
};

// Calls an emitter once with one second elapsed and fresh slots.
std::size_t ParticlesFromOneCall(const ParticleEmittOp& emitter) {
    std::vector<Particle>                slots;
    std::vector<ParticleInitOp>          initializers;
    const std::array<ParticleControlpoint, 8> points {};
    emitter(slots, initializers, 8, 1.0, points);
    return slots.size();
}

} // namespace

// PO-01
TEST(ParticleInstanceOverride, ParsingKeepsTheLiteralAndThePropertyBindingOfABoundField) {
    Override over;
    const json document = {
        { "alpha", { { "user", "alpha_property" }, { "value", 0.25 } } },
        { "size", { { "user", "size_property" }, { "value", 2.0 } } },
        { "colorn", { { "user", "color_property" }, { "value", "0.1 0.2 0.3" } } },
    };
    EXPECT_TRUE(over.FromJosn(document));
    EXPECT_TRUE(over.enabled);
    EXPECT_EQ(over.alpha, 0.25f);
    EXPECT_EQ(over.size, 2.0f);
    EXPECT_TRUE(over.overColorn);
    EXPECT_NEAR(over.colorn[0], 0.1f, 1e-6f);
    EXPECT_NEAR(over.colorn[1], 0.2f, 1e-6f);
    EXPECT_NEAR(over.colorn[2], 0.3f, 1e-6f);

    ASSERT_EQ(over.bindings.size(), 3u);
    EXPECT_EQ(over.bindings["alpha"], "alpha_property");
    EXPECT_EQ(over.bindings["size"], "size_property");
    EXPECT_EQ(over.bindings["colorn"], "color_property");
}

TEST(ParticleInstanceOverride, ColourControlPointAndOddInputsParseAsTheRulesSay) {
    {
        // `color` wins over `colorn`, which is then not read at all.
        Override over;
        over.FromJosn(json { { "color", "255 0 0" }, { "colorn", "0 0 1" } });
        EXPECT_TRUE(over.overColor);
        EXPECT_FALSE(over.overColorn);
        EXPECT_EQ(over.color[0], 255.0f);
        EXPECT_EQ(over.color[1], 0.0f);
        EXPECT_EQ(over.color[2], 0.0f);
    }
    {
        Override over;
        over.FromJosn(json { { "controlpoint3", { { "user", "p" }, { "value", "1 2 3" } } } });
        EXPECT_TRUE(over.controlpointSet[3]);
        EXPECT_FALSE(over.controlpointSet[2]);
        EXPECT_EQ(over.controlpoint[3], (std::array<float, 3> { 1.0f, 2.0f, 3.0f }));
        EXPECT_EQ(over.bindings["controlpoint3"], "p");
    }
    {
        // Only the plain fields and the control point slots can be bound.
        Override over;
        over.FromJosn(json { { "id", { { "user", "x" }, { "value", 4 } } } });
        EXPECT_EQ(over.id, 4);
        EXPECT_TRUE(over.bindings.empty());
    }
    {
        // The property name has to be text.
        Override over;
        over.FromJosn(json { { "alpha", { { "user", 5 }, { "value", 0.5 } } } });
        EXPECT_EQ(over.alpha, 0.5f);
        EXPECT_TRUE(over.bindings.empty());
    }
    {
        // Anything that is not an object enables the record and changes nothing else.
        Override over;
        EXPECT_TRUE(over.FromJosn(json::array()));
        EXPECT_TRUE(over.enabled);
        EXPECT_EQ(over.alpha, 1.0f);
        EXPECT_EQ(over.size, 1.0f);
        EXPECT_FALSE(over.overColor);
        EXPECT_FALSE(over.overColorn);
        EXPECT_TRUE(over.bindings.empty());
    }
}

// PO-02
TEST(ParticleInstanceOverride, ColourOverrideReplacesAParticleColourWhenTheFileHasNoColourSource) {
    const auto colour_after = [](const std::shared_ptr<Override>& over, ParticleColorDefinition file) {
        auto     op = WPParticleParser::genOverrideInitOp(over, file);
        Particle p;
        ParticleModify::InitColor(p, 0.2, 0.2, 0.2);
        op(p, 0.0);
        return p.color;
    };

    {
        auto over        = EnabledOverride();
        over->overColorn = true;
        over->colorn     = { 0.25f, 0.5f, 0.75f };
        const auto c     = colour_after(over, {});
        EXPECT_EQ(c.x(), 0.25f) << "replaced, not multiplied";
        EXPECT_EQ(c.y(), 0.5f);
        EXPECT_EQ(c.z(), 0.75f);
    }
    {
        auto over       = EnabledOverride();
        over->overColor = true;
        over->color     = { 51.0f, 102.0f, 204.0f };
        const auto c    = colour_after(over, {});
        EXPECT_NEAR(c.x(), 0.2f, 1e-6f) << "the 0-255 form is scaled down";
        EXPECT_NEAR(c.y(), 0.4f, 1e-6f);
        EXPECT_NEAR(c.z(), 0.8f, 1e-6f);
    }
    {
        auto over        = EnabledOverride();
        over->enabled    = false;
        over->overColorn = true;
        over->colorn     = { 0.25f, 0.5f, 0.75f };
        const auto c     = colour_after(over, {});
        EXPECT_EQ(c.x(), 0.2f) << "a disabled record changes nothing";
        EXPECT_EQ(c.y(), 0.2f);
        EXPECT_EQ(c.z(), 0.2f);
    }
    {
        auto over        = EnabledOverride();
        over->overColorn = true;
        over->colorn     = { 0.25f, 0.5f, 0.75f };
        ParticleColorDefinition file;
        file.hasColor = true;
        const auto c  = colour_after(over, file);
        EXPECT_NEAR(c.x(), 0.05f, 1e-6f) << "a colour-bearing file is still tinted by a differing override";
        EXPECT_NEAR(c.y(), 0.1f, 1e-6f);
        EXPECT_NEAR(c.z(), 0.15f, 1e-6f);
    }
}

// PO-03
TEST(ParticleInstanceOverride, InitializerReadsTheLiveRecordForEveryParticle) {
    auto over   = EnabledOverride();
    over->size  = 2.0f;
    over->speed = 3.0f;
    auto op     = WPParticleParser::genOverrideInitOp(over);

    Particle first;
    ParticleModify::InitSize(first, 1.0);
    ParticleModify::InitVelocity(first, 1.0, 0.0, 0.0);
    op(first, 0.0);
    EXPECT_EQ(first.size, 2.0f);
    EXPECT_EQ(first.velocity.x(), 3.0f);

    over->size  = 4.0f;
    over->speed = 0.5f;
    Particle second;
    ParticleModify::InitSize(second, 1.0);
    ParticleModify::InitVelocity(second, 2.0, 0.0, 0.0);
    op(second, 0.0);
    EXPECT_EQ(second.size, 4.0f) << "the record was changed after the op was built";
    EXPECT_EQ(second.velocity.x(), 1.0f);
}

TEST(ParticleInstanceOverride, ADisabledRecordLeavesTheParticleAlone) {
    auto over        = EnabledOverride();
    over->enabled    = false;
    over->size       = 2.0f;
    over->speed      = 3.0f;
    over->alpha      = 0.5f;
    over->lifetime   = 4.0f;
    over->overColorn = true;
    over->colorn     = { 0.25f, 0.5f, 0.75f };
    auto op          = WPParticleParser::genOverrideInitOp(over);

    Particle p;
    ParticleModify::InitSize(p, 1.0);
    ParticleModify::InitVelocity(p, 1.0, 0.0, 0.0);
    ParticleModify::InitAlpha(p, 1.0);
    ParticleModify::InitLifetime(p, 1.0f);
    op(p, 0.0);
    EXPECT_EQ(p.size, 1.0f);
    EXPECT_EQ(p.velocity.x(), 1.0f);
    EXPECT_EQ(p.alpha, 1.0f);
    EXPECT_EQ(p.lifetime, 1.0f);
    EXPECT_EQ(p.color.x(), 1.0f);
}

TEST(ParticleInstanceOverride, ANonFiniteFactorIsReadAsOne) {
    auto over  = EnabledOverride();
    over->size = std::numeric_limits<float>::quiet_NaN();
    auto op    = WPParticleParser::genOverrideInitOp(over);
    Particle p;
    ParticleModify::InitSize(p, 1.0);
    op(p, 0.0);
    EXPECT_EQ(p.size, 1.0f);
}

// PR-01
TEST(ParticleRateOverride, RateMultiplierIsConsultedAtEveryStep) {
    EmissionRig rig;
    double      multiplier = 0.5;
    rig.subsystem->SetRateMultiplier([&multiplier] { return multiplier; });
    rig.subsystem->AddEmitter(WPParticleParser::genParticleEmittOp(SteadyEmitter()));

    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 0u) << "half a second at one per second owes half a particle";

    multiplier = 2.0;
    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 2u) << "two seconds make 2.5 due: two now, a half carried";

    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 4u) << "the carried half completes the next whole particle";

    // The half left over from step 3 is spent here: half a second makes up the missing half.
    multiplier = 0.5;
    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 5u) << "0.5 carried plus 0.5 owed makes one more";
}

// 0x14022AF30 holds the override rate at fmaxf(0.01, rate): a negative rate or one that is not a
// number runs the system at a hundredth of its speed instead of stopping it.
TEST(ParticleRateOverride, ARateBelowAHundredthRunsAtAHundredth) {
    for (const double asked : { -1.0, std::numeric_limits<double>::quiet_NaN(), 0.0 }) {
        EmissionRig rig(4);
        rig.subsystem->SetRateMultiplier([asked] { return asked; });
        rig.subsystem->AddEmitter(WPParticleParser::genParticleEmittOp(SteadyEmitter()));
        for (int i = 0; i < 99; ++i) rig.subsystem->Emitt();
        EXPECT_EQ(rig.LiveCount(), 0u) << asked;
        rig.subsystem->Emitt();
        rig.subsystem->Emitt();
        EXPECT_EQ(rig.LiveCount(), 1u) << "a hundred and one hundredths of a second make one particle";
    }
}

// PR-02
TEST(ParticleCountOverride, CountScalesWhatTheFirstEmissionProduces) {
    {
        auto over   = EnabledOverride();
        over->count = 3.0f;
        EXPECT_EQ(ParticlesFromOneCall(WPParticleParser::genParticleEmittOp(SteadyEmitter(), false, over)),
                  3u);
    }
    {
        auto over   = EnabledOverride();
        over->count = 0.0f;
        EXPECT_EQ(ParticlesFromOneCall(WPParticleParser::genParticleEmittOp(SteadyEmitter(), false, over)),
                  0u);
    }
    {
        // Half a particle is owed per second; two calls make one.
        auto over   = EnabledOverride();
        over->count = 0.5f;
        auto op     = WPParticleParser::genParticleEmittOp(SteadyEmitter(), false, over);
        std::vector<Particle>                     slots;
        std::vector<ParticleInitOp>               initializers;
        const std::array<ParticleControlpoint, 8> points {};
        op(slots, initializers, 8, 1.0, points);
        EXPECT_EQ(slots.size(), 0u);
        op(slots, initializers, 8, 1.0, points);
        EXPECT_EQ(slots.size(), 1u);
    }
}

// PR-03
TEST(ParticleCountOverride, CountIsReadAgainAtEveryEmission) {
    auto over   = EnabledOverride();
    over->count = 1.0f;
    auto op     = WPParticleParser::genParticleEmittOp(SteadyEmitter(), false, over);

    std::vector<Particle>                     slots;
    std::vector<ParticleInitOp>               initializers;
    const std::array<ParticleControlpoint, 8> points {};
    op(slots, initializers, 8, 1.0, points);
    EXPECT_EQ(slots.size(), 1u);

    over->count = 3.0f;
    op(slots, initializers, 8, 1.0, points);
    EXPECT_EQ(slots.size(), 4u);
}

// PR-04
TEST(ParticleRateOverride, ProjectPropertiesDriveRateAndCountAtLoadAndAtRuntime) {
    EmissionRig rig(16);
    rig.scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = { { "particle_rate", RuntimeScalarValue::Float(1.0f) },
                                { "particle_count", RuntimeScalarValue::Float(2.0f) } } });
    ASSERT_NE(rig.scene.runtime, nullptr);

    auto over = std::make_shared<Override>();
    ASSERT_TRUE(over->FromJosn(json {
        { "rate", { { "user", "particle_rate" }, { "value", 1.0 } } },
        { "count", { { "user", "particle_count" }, { "value", 1.0 } } },
    }));
    ASSERT_EQ(over->bindings.at("rate"), "particle_rate");
    ASSERT_EQ(over->bindings.at("count"), "particle_count");

    // What the scene parser does for a real scene: follow each property with a value whose
    // listener writes into the record.
    const auto bind = [&](const std::string& property, float Override::*field) {
        DynamicValue* source = rig.scene.runtime->FindPropertyValue(property);
        ASSERT_NE(source, nullptr) << property;
        auto value = std::make_unique<DynamicValue>(over.get()->*field);
        value->connect(source);
        rig.scene.runtime->RegisterDynamicValueListener(
            std::move(value),
            [over, field](const DynamicValue& v) { over.get()->*field = v.getFloat(); });
    };
    bind(over->bindings.at("rate"), &Override::rate);
    bind(over->bindings.at("count"), &Override::count);
    EXPECT_EQ(over->rate, 1.0f) << "the load-time value arrives at registration";
    EXPECT_EQ(over->count, 2.0f);

    rig.subsystem->SetRateMultiplier(
        [over] { return over->enabled ? static_cast<double>(over->rate) : 1.0; });
    rig.subsystem->AddEmitter(WPParticleParser::genParticleEmittOp(SteadyEmitter(), false, over));

    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 2u) << "one second at rate 1, count 2";

    rig.scene.runtime->ApplyProjectPropertyOverride(
        { { "particle_rate", RuntimeScalarValue::Float(2.0f) },
          { "particle_count", RuntimeScalarValue::Float(3.0f) } });
    EXPECT_EQ(over->rate, 2.0f);
    EXPECT_EQ(over->count, 3.0f);
    rig.subsystem->Emitt();
    EXPECT_EQ(rig.LiveCount(), 8u) << "two seconds at count 3 add six";
}
