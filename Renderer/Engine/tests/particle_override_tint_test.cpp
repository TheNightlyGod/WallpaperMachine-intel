// A scene object's instance colour override against a particle preset that has
// colours of its own: the preset is re-tinted toward the override and each new
// particle is then multiplied by the override colour. No GPU, no scene files.
#include <gtest/gtest.h>

#include <nlohmann/json.hpp>

#include <memory>
#include <vector>

#include "WPParticleParser.hpp"
#include "Particle/ParticleModify.h"

namespace wallpaper
{
namespace
{

using nlohmann::json;

std::shared_ptr<wpscene::ParticleInstanceoverride> OverrideWith(float r, float g, float b) {
    auto over        = std::make_shared<wpscene::ParticleInstanceoverride>();
    over->enabled    = true;
    over->overColorn = true;
    over->colorn     = { r, g, b };
    return over;
}

/// The pieces a particle file contributes, wired the way a scene object wires
/// them: the parse context carries the override and the file's own colour.
struct Preset {
    std::vector<json>                                  initializers;
    std::vector<json>                                  operators;
    std::shared_ptr<wpscene::ParticleInstanceoverride> over;

    ParticleParseContext Context() const {
        ParticleParseContext ctx;
        ctx.over  = over;
        ctx.color = WPParticleParser::analyzeColorSources(initializers, operators);
        return ctx;
    }

    /// A default particle born through every initializer and then the override.
    Particle Birth() const {
        const ParticleParseContext ctx = Context();
        Particle                   p;
        for (const auto& record : initializers) WPParticleParser::genParticleInitOp(record, ctx)(p, 0.0);
        WPParticleParser::genOverrideInitOp(over, ctx.color)(p, 0.0);
        return p;
    }
};

json GreenColorRandom() {
    return { { "name", "colorrandom" }, { "min", "0 255 0" }, { "max", "0 255 0" } };
}

json ColorChange(const char* start, const char* end, double end_time) {
    return { { "name", "colorchange" },
             { "startvalue", start },
             { "endvalue", end },
             { "starttime", 0.0 },
             { "endtime", end_time } };
}

void ExpectColor(const Particle& p, double r, double g, double b, double tolerance) {
    EXPECT_NEAR(p.color.x(), r, tolerance);
    EXPECT_NEAR(p.color.y(), g, tolerance);
    EXPECT_NEAR(p.color.z(), b, tolerance);
}

void Step(const std::vector<json>& operators, const ParticleParseContext& ctx,
          std::vector<Particle>& particles) {
    ParticleInfo info {};
    info.particles = particles;
    info.time      = 0.0;
    info.time_pass = 0.0;
    for (const auto& record : operators)
        WPParticleParser::genParticleOperatorOp(record, ctx)(info);
}

TEST(ParticleOverrideTint, RetintedInitializerColourIsMultipliedByTheOverride) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = OverrideWith(1.0f, 0.5f, 0.0f);

    const Particle p = preset.Birth();

    // Green moves to the override's orange, and the orange tints it once more.
    ExpectColor(p, 1.0, 0.25, 0.0, 1.0e-5);
    // The remembered birth colour is the tinted one.
    EXPECT_EQ(p.init.color, p.color);
}

TEST(ParticleOverrideTint, OverrideEqualToTheRepresentativeColourDoesNotTint) {
    Preset preset;
    preset.operators = { ColorChange("1 0.74902 0", "1 0 0", 1.0) };
    preset.over      = OverrideWith(1.0f, 0.74902f, 0.0f);

    const Particle p = preset.Birth();

    ExpectColor(p, 1.0, 1.0, 1.0, 0.0);
    EXPECT_EQ(p.init.color, p.color);
}

TEST(ParticleOverrideTint, ColourChangeRampIsTintedAtBothEnds) {
    Preset preset;
    preset.operators = { ColorChange("1 0.74902 0", "1 0 0", 0.5) };
    preset.over      = OverrideWith(1.0f, 0.13725f, 0.0f);
    const ParticleParseContext ctx = preset.Context();

    std::vector<Particle> particles { preset.Birth(), preset.Birth() };
    // First particle starts its life; the second is past the end of the ramp.
    for (auto& p : particles) p.init.lifetime = p.lifetime = 1.0f;
    particles[1].lifetime = 0.0f;

    Step(preset.operators, ctx, particles);

    ExpectColor(particles[0], 1.0, 0.13725 * 0.13725, 0.0, 1.0e-4);
    EXPECT_NEAR(particles[0].color.y(), 0.13725 * 0.13725, 1.0e-3);
    // Without the tint the end colour would be a magenta; the override has no
    // blue, so the tinted particle has none either.
    ExpectColor(particles[1], 1.0, 0.0, 0.0, 1.0e-4);
}

TEST(ParticleOverrideTint, PresetWithoutColoursTakesTheOverrideOnce) {
    Preset preset;
    preset.over = OverrideWith(0.2f, 0.4f, 0.6f);

    const Particle p = preset.Birth();

    ExpectColor(p, 0.2, 0.4, 0.6, 1.0e-6);
    EXPECT_EQ(p.init.color, p.color);
}

TEST(ParticleOverrideTint, ByteScaleOverrideTintsTheSameWay) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = std::make_shared<wpscene::ParticleInstanceoverride>();
    preset.over->enabled   = true;
    preset.over->overColor = true;
    preset.over->color     = { 255.0f, 127.5f, 0.0f };

    ExpectColor(preset.Birth(), 1.0, 0.25, 0.0, 1.0e-5);
}

TEST(ParticleOverrideTint, DisabledOverrideLeavesTheColourAlone) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = OverrideWith(1.0f, 0.5f, 0.0f);
    preset.over->enabled = false;

    ExpectColor(preset.Birth(), 0.0, 1.0, 0.0, 1.0e-6);
}

TEST(ParticleOverrideTint, HdrBrightnessStillMultipliesOnTop) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = OverrideWith(1.0f, 0.5f, 0.0f);
    preset.over->hdr        = true;
    preset.over->brightness = 2.0f;

    const Particle p = preset.Birth();

    ExpectColor(p, 2.0, 0.5, 0.0, 1.0e-5);
    EXPECT_EQ(p.init.color, p.color);
}

TEST(ParticleOverrideTint, BrightnessIsIgnoredOutsideHdr) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = OverrideWith(1.0f, 0.5f, 0.0f);
    preset.over->brightness = 2.0f;

    ExpectColor(preset.Birth(), 1.0, 0.25, 0.0, 1.0e-5);
}

TEST(ParticleOverrideTint, WhiteOverrideDesaturatesWithoutDarkeningFurther) {
    Preset preset;
    preset.initializers = { GreenColorRandom() };
    preset.over         = OverrideWith(1.0f, 1.0f, 1.0f);

    // Re-tint to white, times white.
    ExpectColor(preset.Birth(), 1.0, 1.0, 1.0, 1.0e-5);
}

} // namespace
} // namespace wallpaper
