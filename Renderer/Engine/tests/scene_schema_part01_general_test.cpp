// Scene file schema, part 1: the `general` block and the package-version gates.
//
// Pure JSON -> struct checks (no parser, no runtime): every key of the block is read, a key is
// only read from the package version that introduced it, and the height fog is read at any
// version.
#include "support/schema_fixtures.hpp"

#include "wpscene/WPScene.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>

namespace
{

using namespace we_schema;
using wallpaper::wpscene::WPScene;
using wallpaper::wpscene::WPSceneGeneral;

using Vec3 = std::array<float, 3>;

// The block every wide-reading test feeds: one authored value for nearly every key.
Json WideGeneral()
{
    return { { "ambientcolor", Json::array({ 0.1, 0.2, 0.3 }) },
             { "skylightcolor", Json::array({ 0.4, 0.5, 0.6 }) },
             { "clearcolor", Json::array({ 0.7, 0.8, 0.9 }) },
             { "cameraparallax", true },
             { "cameraparallaxamount", 1.5 },
             { "cameraparallaxdelay", 0.25 },
             { "cameraparallaxmouseinfluence", 0.75 },
             { "zoom", 2 },
             { "fov", 63 },
             { "nearz", 0.5 },
             { "farz", 9000 },
             { "bloom", true },
             { "bloomstrength", 1.25 },
             { "bloomthreshold", 0.8 },
             { "hdr", true },
             { "norecompile", true },
             { "bloomtint", Json::array({ 0.2, 0.3, 0.4 }) },
             { "perspectiveoverridefov", 70 },
             { "windenabled", true },
             { "winddirection", Json::array({ 1, 0, 0 }) },
             { "windstrength", 3 },
             { "gravitydirection", Json::array({ 0, -1, 0 }) },
             { "gravitystrength", 9.8 },
             { "transparentsorting", true },
             { "fogdistance", true },
             { "fogdistancestart", 10 },
             { "fogdistanceend", 100 },
             { "fogdistancecolor", Json::array({ 0.6, 0.7, 0.8 }) },
             { "fogheight", true },
             { "fogheightstart", 2 },
             { "fogheightend", 8 },
             { "fogheightcolor", Json::array({ 0.9, 0.8, 0.7 }) },
             { "lightconfig", { { "directional", 1 }, { "point", 2 }, { "spotshadow", 3 } } },
             { "orthogonalprojection", { { "width", 1280 }, { "height", 720 } } } };
}

Json SceneRootOf(const Json& general)
{
    return { { "camera", { { "center", Json::array({ 0, 0, 0 }) }, { "eye", Json::array({ 0, 10, 20 }) }, { "up", Json::array({ 0, 1, 0 }) } } },
             { "general", general } };
}

// Reads `block` at `version` into a fresh struct; the read itself must succeed.
WPSceneGeneral ReadAt(const Json& block, std::uint16_t version)
{
    WPSceneGeneral general;
    EXPECT_TRUE(general.FromJson(block, version)) << "version " << version;
    return general;
}

// ---- the whole block, no version ---------------------------------------------------------

// R-1.01 / B-1.01
TEST(GeneralBlockSchema, ReadsEveryKeyOfAWideBlockWhenTheVersionIsUnknown)
{
    WPScene scene;
    ASSERT_TRUE(scene.FromJson(SceneRootOf(WideGeneral())));
    const WPSceneGeneral& g = scene.general;

    EXPECT_EQ(g.ambientcolor, (Vec3 { 0.1f, 0.2f, 0.3f }));
    EXPECT_EQ(g.skylightcolor, (Vec3 { 0.4f, 0.5f, 0.6f }));
    EXPECT_EQ(g.clearcolor, (Vec3 { 0.7f, 0.8f, 0.9f }));
    EXPECT_TRUE(g.cameraparallax);
    EXPECT_FLOAT_EQ(g.cameraparallaxamount, 1.5f);
    EXPECT_FLOAT_EQ(g.cameraparallaxdelay, 0.25f);
    EXPECT_FLOAT_EQ(g.cameraparallaxmouseinfluence, 0.75f);
    EXPECT_FLOAT_EQ(g.zoom, 2.0f);
    EXPECT_FLOAT_EQ(g.fov, 63.0f);
    EXPECT_FLOAT_EQ(g.nearz, 0.5f);
    EXPECT_FLOAT_EQ(g.farz, 9000.0f);
    EXPECT_TRUE(g.bloom);
    EXPECT_FLOAT_EQ(g.bloomstrength, 1.25f);
    EXPECT_FLOAT_EQ(g.bloomthreshold, 0.8f);
    EXPECT_TRUE(g.hdr);
    EXPECT_TRUE(g.norecompile);
    EXPECT_FLOAT_EQ(g.bloomtint[0], 0.2f);
    EXPECT_FLOAT_EQ(g.bloomtint[1], 0.3f);
    EXPECT_FLOAT_EQ(g.bloomtint[2], 0.4f);
    EXPECT_FLOAT_EQ(g.perspectiveoverridefov, 70.0f);
    EXPECT_TRUE(g.windenabled);
    EXPECT_EQ(g.winddirection, (Vec3 { 1.0f, 0.0f, 0.0f }));
    EXPECT_FLOAT_EQ(g.windstrength, 3.0f);
    EXPECT_EQ(g.gravitydirection, (Vec3 { 0.0f, -1.0f, 0.0f }));
    EXPECT_FLOAT_EQ(g.gravitystrength, 9.8f);
    EXPECT_TRUE(g.transparentsorting);
    EXPECT_TRUE(g.fogdistance);
    EXPECT_FLOAT_EQ(g.fogdistancestart, 10.0f);
    EXPECT_FLOAT_EQ(g.fogdistanceend, 100.0f);
    EXPECT_EQ(g.fogdistancecolor, (Vec3 { 0.6f, 0.7f, 0.8f }));
    EXPECT_TRUE(g.fogheight);
    EXPECT_FLOAT_EQ(g.fogheightstart, 2.0f);
    EXPECT_FLOAT_EQ(g.fogheightend, 8.0f);
    EXPECT_EQ(g.fogheightcolor, (Vec3 { 0.9f, 0.8f, 0.7f }));
    ASSERT_TRUE(g.lightconfig.is_object());
    EXPECT_EQ(g.lightconfig.at("directional").get<int>(), 1);
    EXPECT_EQ(g.lightconfig.at("point").get<int>(), 2);
    EXPECT_EQ(g.lightconfig.at("spotshadow").get<int>(), 3);
    EXPECT_TRUE(g.isOrtho);
    EXPECT_EQ(g.orthogonalprojection.width, 1280);
    EXPECT_EQ(g.orthogonalprojection.height, 720);
    EXPECT_EQ(scene.pkg_version, WPSceneGeneral::kSceneVersionUnknown);
}

// B-1.01: values that differ from the defaults the wide block happens to share (bloom on, the
// downward gravity), so a key that stopped being read would show.
TEST(GeneralBlockSchema, ValuesOppositeToTheDefaultsAreReadToo)
{
    WPSceneGeneral g;
    ASSERT_TRUE(g.FromJson({ { "bloom", false },
                             { "gravitydirection", Json::array({ 0, 0, 1 }) },
                             { "clearenabled", false },
                             { "camerashake", true },
                             { "camerashakeamplitude", 2 },
                             { "camerashakespeed", 4 },
                             { "camerashakeroughness", 3 },
                             { "orthogonalprojection", { { "auto", true } } } }));
    EXPECT_FALSE(g.bloom);
    EXPECT_EQ(g.gravitydirection, (Vec3 { 0.0f, 0.0f, 1.0f }));
    EXPECT_FALSE(g.clearenabled);
    EXPECT_TRUE(g.camerashake);
    EXPECT_FLOAT_EQ(g.camerashakeamplitude, 2.0f);
    EXPECT_FLOAT_EQ(g.camerashakespeed, 4.0f);
    EXPECT_FLOAT_EQ(g.camerashakeroughness, 3.0f);
    EXPECT_TRUE(g.orthogonalprojection.auto_);
}

// B-1.01: the bare block reads the same through its own entry point.
TEST(GeneralBlockSchema, TheBareBlockReadsLikeTheBlockInsideARoot)
{
    WPSceneGeneral g;
    ASSERT_TRUE(g.FromJson(WideGeneral()));
    EXPECT_TRUE(g.hdr);
    EXPECT_TRUE(g.norecompile);
    EXPECT_FLOAT_EQ(g.bloomtint[2], 0.4f);
    EXPECT_TRUE(g.windenabled);
    EXPECT_FLOAT_EQ(g.windstrength, 3.0f);
    EXPECT_TRUE(g.transparentsorting);
    EXPECT_TRUE(g.fogdistance);
    EXPECT_TRUE(g.fogheight);
    EXPECT_EQ(g.lightconfig.at("point").get<int>(), 2);
}

// B-1.01: a general block that is not an object is refused, whatever it is.
TEST(GeneralBlockSchema, ANonObjectBlockIsRefused)
{
    for (const Json& bad : { Json(5), Json("text"), Json::array({ 1, 2 }), Json(nullptr), Json(true) }) {
        WPSceneGeneral g;
        EXPECT_FALSE(g.FromJson(bad)) << bad.dump();
        EXPECT_FALSE(g.FromJson(bad, 22)) << bad.dump();
    }
    WPScene scene;
    EXPECT_FALSE(scene.FromJson(Json::array()));
    EXPECT_FALSE(scene.FromJson(Json("scene")));
}

// ---- version gates -----------------------------------------------------------------------

// The block the gate tests feed (a bare general object).
Json GateInput()
{
    return { { "ambientcolor", Json::array({ 0.1, 0.2, 0.3 }) },
             { "skylightcolor", Json::array({ 0.4, 0.5, 0.6 }) },
             { "clearcolor", Json::array({ 0.7, 0.8, 0.9 }) },
             { "cameraparallax", false },
             { "cameraparallaxamount", 0 },
             { "cameraparallaxdelay", 0 },
             { "cameraparallaxmouseinfluence", 0 },
             { "hdr", true },
             { "norecompile", true },
             { "bloomtint", Json::array({ 0.2, 0.3, 0.4 }) },
             { "windenabled", true },
             { "windstrength", 3 },
             { "lightconfig", { { "directional", 1 }, { "point", 2 } } },
             { "transparentsorting", true },
             { "fogdistance", true },
             { "fogdistancestart", 10 },
             { "fogheight", true },
             { "fogheightstart", 2 } };
}

// R-1.02 / B-1.02: each gated key appears at the version that introduced it and not before.
TEST(GeneralBlockSchema, GatedKeysAppearAtTheVersionThatIntroducedThem)
{
    const Json input = GateInput();

    {
        SCOPED_TRACE("version 9: nothing gated yet");
        const auto g = ReadAt(input, 9);
        EXPECT_FALSE(g.hdr);
        EXPECT_FALSE(g.norecompile);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 1.0f);
        EXPECT_FALSE(g.windenabled);
        EXPECT_TRUE(g.lightconfig.is_null());
        EXPECT_FALSE(g.transparentsorting);
        EXPECT_FALSE(g.fogdistance);
    }
    {
        SCOPED_TRACE("version 10: hdr and norecompile");
        const auto g = ReadAt(input, 10);
        EXPECT_TRUE(g.hdr);
        EXPECT_TRUE(g.norecompile);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 1.0f);
        EXPECT_FALSE(g.windenabled);
    }
    {
        SCOPED_TRACE("version 19: bloomtint still waits");
        const auto g = ReadAt(input, 19);
        EXPECT_TRUE(g.hdr);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 1.0f);
    }
    {
        SCOPED_TRACE("version 20: bloomtint, but not wind or lighting");
        const auto g = ReadAt(input, 20);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 0.4f);
        EXPECT_FALSE(g.windenabled);
        EXPECT_TRUE(g.lightconfig.is_null());
    }
    {
        SCOPED_TRACE("version 21: wind and lighting, but not the later switches");
        const auto g = ReadAt(input, 21);
        EXPECT_TRUE(g.windenabled);
        EXPECT_FLOAT_EQ(g.windstrength, 3.0f);
        ASSERT_TRUE(g.lightconfig.is_object());
        EXPECT_EQ(g.lightconfig.at("point").get<int>(), 2);
        EXPECT_FALSE(g.transparentsorting);
        EXPECT_FALSE(g.fogdistance);
    }
    {
        SCOPED_TRACE("version 22: transparent sorting and distance fog");
        const auto g = ReadAt(input, 22);
        EXPECT_TRUE(g.transparentsorting);
        EXPECT_TRUE(g.fogdistance);
        EXPECT_FLOAT_EQ(g.fogdistancestart, 10.0f);
        EXPECT_TRUE(g.windenabled);
        EXPECT_TRUE(g.hdr);
    }
    {
        SCOPED_TRACE("version 23: everything of 22 still holds");
        const auto g = ReadAt(input, 23);
        EXPECT_TRUE(g.transparentsorting);
        EXPECT_TRUE(g.fogdistance);
        EXPECT_FLOAT_EQ(g.fogdistancestart, 10.0f);
        EXPECT_TRUE(g.windenabled);
        EXPECT_EQ(g.lightconfig.at("point").get<int>(), 2);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 0.4f);
        EXPECT_TRUE(g.hdr);
    }
    {
        SCOPED_TRACE("unknown version: every key reads its authored value");
        const auto g = ReadAt(input, WPSceneGeneral::kSceneVersionUnknown);
        EXPECT_TRUE(g.hdr);
        EXPECT_TRUE(g.norecompile);
        EXPECT_FLOAT_EQ(g.bloomtint[2], 0.4f);
        EXPECT_TRUE(g.windenabled);
        EXPECT_FLOAT_EQ(g.windstrength, 3.0f);
        EXPECT_EQ(g.lightconfig.at("point").get<int>(), 2);
        EXPECT_TRUE(g.transparentsorting);
        EXPECT_TRUE(g.fogdistance);
        EXPECT_FLOAT_EQ(g.fogdistancestart, 10.0f);
    }
}

// B-1.02: whatever the version, the keys that are not gated are read.
TEST(GeneralBlockSchema, UngatedKeysAreReadAtEveryVersion)
{
    const Json input = GateInput();
    for (const std::uint16_t version : { 0, 1, 9, 10, 19, 20, 21, 22, 23, 65535 }) {
        SCOPED_TRACE(version);
        const auto g = ReadAt(input, version);
        EXPECT_EQ(g.clearcolor, (Vec3 { 0.7f, 0.8f, 0.9f }));
        EXPECT_EQ(g.ambientcolor, (Vec3 { 0.1f, 0.2f, 0.3f }));
        EXPECT_EQ(g.skylightcolor, (Vec3 { 0.4f, 0.5f, 0.6f }));
        EXPECT_FALSE(g.cameraparallax);
        EXPECT_FLOAT_EQ(g.cameraparallaxamount, 0.0f);
        EXPECT_FLOAT_EQ(g.cameraparallaxdelay, 0.0f);
        EXPECT_FLOAT_EQ(g.cameraparallaxmouseinfluence, 0.0f);
    }
}

// B-1.02: the lowest and the highest version bracket the gates.
TEST(GeneralBlockSchema, TheExtremeVersionsReadNothingGatedAndEverythingGated)
{
    const Json input = GateInput();
    {
        const auto low = ReadAt(input, 1);
        EXPECT_FALSE(low.hdr);
        EXPECT_FALSE(low.norecompile);
        EXPECT_FLOAT_EQ(low.bloomtint[2], 1.0f);
        EXPECT_FALSE(low.windenabled);
        EXPECT_FLOAT_EQ(low.windstrength, 1.0f) << "the default (sub_140186C90)";
        EXPECT_TRUE(low.lightconfig.is_null());
        EXPECT_FALSE(low.transparentsorting);
        EXPECT_FALSE(low.fogdistance);
        EXPECT_FLOAT_EQ(low.fogdistancestart, 1.0f);
        EXPECT_EQ(low.clearcolor, (Vec3 { 0.7f, 0.8f, 0.9f }));
    }
    {
        const auto high = ReadAt(input, 65535);
        EXPECT_TRUE(high.hdr);
        EXPECT_TRUE(high.norecompile);
        EXPECT_FLOAT_EQ(high.bloomtint[2], 0.4f);
        EXPECT_TRUE(high.windenabled);
        EXPECT_FLOAT_EQ(high.windstrength, 3.0f);
        EXPECT_EQ(high.lightconfig.at("point").get<int>(), 2);
        EXPECT_TRUE(high.transparentsorting);
        EXPECT_TRUE(high.fogdistance);
        EXPECT_FLOAT_EQ(high.fogdistancestart, 10.0f);
    }
}

// B-1.02: the rest of the groups come in with their gate too (HDR bloom values at 10, the rest of
// the distance fog at 22).
TEST(GeneralBlockSchema, EveryKeyOfAGatedGroupSharesItsGate)
{
    const Json input = { { "bloomhdrstrength", 3 },       { "bloomhdrthreshold", 0.5 }, { "bloomhdrscatter", 2 },
                         { "bloomhdrfeather", 0.3 },      { "bloomhdriterations", 5 },  { "winddirection", Json::array({ 1, 0, 0 }) },
                         { "gravitydirection", Json::array({ 0, 0, -1 }) },             { "gravitystrength", 4 },
                         { "fogdistanceend", 50 },        { "fogdistancestartdensity", 0.2 },
                         { "fogdistanceenddensity", 0.6 }, { "fogdistancecolor", Json::array({ 0.1, 0.1, 0.1 }) } };
    const WPSceneGeneral untouched;

    const auto before_hdr = ReadAt(input, 9);
    EXPECT_FLOAT_EQ(before_hdr.bloomhdrstrength, untouched.bloomhdrstrength);
    EXPECT_FLOAT_EQ(before_hdr.bloomhdrthreshold, untouched.bloomhdrthreshold);
    EXPECT_FLOAT_EQ(before_hdr.bloomhdrscatter, untouched.bloomhdrscatter);
    EXPECT_FLOAT_EQ(before_hdr.bloomhdrfeather, untouched.bloomhdrfeather);
    EXPECT_EQ(before_hdr.bloomhdriterations, untouched.bloomhdriterations);

    const auto at_hdr = ReadAt(input, 10);
    EXPECT_FLOAT_EQ(at_hdr.bloomhdrstrength, 3.0f);
    EXPECT_FLOAT_EQ(at_hdr.bloomhdrthreshold, 0.5f);
    EXPECT_FLOAT_EQ(at_hdr.bloomhdrscatter, 2.0f);
    EXPECT_FLOAT_EQ(at_hdr.bloomhdrfeather, 0.3f);
    EXPECT_EQ(at_hdr.bloomhdriterations, 5);

    const auto before_wind = ReadAt(input, 20);
    EXPECT_EQ(before_wind.winddirection, untouched.winddirection);
    EXPECT_EQ(before_wind.gravitydirection, untouched.gravitydirection);
    EXPECT_FLOAT_EQ(before_wind.gravitystrength, untouched.gravitystrength);
    const auto at_wind = ReadAt(input, 21);
    EXPECT_EQ(at_wind.winddirection, (Vec3 { 1.0f, 0.0f, 0.0f }));
    EXPECT_EQ(at_wind.gravitydirection, (Vec3 { 0.0f, 0.0f, -1.0f }));
    EXPECT_FLOAT_EQ(at_wind.gravitystrength, 4.0f);

    const auto before_fog = ReadAt(input, 21);
    EXPECT_FLOAT_EQ(before_fog.fogdistanceend, untouched.fogdistanceend);
    EXPECT_FLOAT_EQ(before_fog.fogdistancestartdensity, untouched.fogdistancestartdensity);
    EXPECT_FLOAT_EQ(before_fog.fogdistanceenddensity, untouched.fogdistanceenddensity);
    EXPECT_EQ(before_fog.fogdistancecolor, untouched.fogdistancecolor);
    const auto at_fog = ReadAt(input, 22);
    EXPECT_FLOAT_EQ(at_fog.fogdistanceend, 50.0f);
    EXPECT_FLOAT_EQ(at_fog.fogdistancestartdensity, 0.2f);
    EXPECT_FLOAT_EQ(at_fog.fogdistanceenddensity, 0.6f);
    EXPECT_EQ(at_fog.fogdistancecolor, (Vec3 { 0.1f, 0.1f, 0.1f }));
}

// B-1.02: `lightconfig` is kept only when it is an object.
TEST(GeneralBlockSchema, LightconfigIsKeptOnlyAsAnObject)
{
    for (const Json& not_an_object : { Json(3), Json("point"), Json::array({ 1, 2 }), Json(nullptr), Json(true) }) {
        SCOPED_TRACE(not_an_object.dump());
        for (const std::uint16_t version : { 21, 22, 65535, 0 }) {
            const auto g = ReadAt({ { "lightconfig", not_an_object } }, version);
            EXPECT_TRUE(g.lightconfig.is_null()) << "version " << version;
        }
    }
    const auto g = ReadAt({ { "lightconfig", { { "point", 4 } } } }, 21);
    ASSERT_TRUE(g.lightconfig.is_object());
    EXPECT_EQ(g.lightconfig.at("point").get<int>(), 4);
}

// ---- height fog --------------------------------------------------------------------------

namespace
{

Json FogInput()
{
    return { { "fogheight", true },
             { "fogheightstart", 2 },
             { "fogheightend", 8 },
             { "fogheightstartdensity", 0.25 },
             { "fogheightenddensity", 0.75 },
             { "fogheightcolor", Json::array({ 0.9, 0.8, 0.7 }) },
             { "fogdistance", true },
             { "fogdistancestart", 10 } };
}

void ExpectHeightFogRead(const WPSceneGeneral& g)
{
    EXPECT_TRUE(g.fogheight);
    EXPECT_FLOAT_EQ(g.fogheightstart, 2.0f);
    EXPECT_FLOAT_EQ(g.fogheightend, 8.0f);
    EXPECT_FLOAT_EQ(g.fogheightstartdensity, 0.25f);
    EXPECT_FLOAT_EQ(g.fogheightenddensity, 0.75f);
    EXPECT_EQ(g.fogheightcolor, (Vec3 { 0.9f, 0.8f, 0.7f }));
}

} // namespace

// R-1.02 / B-1.03: the height fog is read at any package version (the distance fog keeps its gate).
TEST(GeneralBlockSchema, HeightFogIsReadAtEveryPackageVersion)
{
    struct Row {
        std::uint16_t version;
        bool          distance_fog;
        float         distance_start;
    };
    const Row rows[] = {
        { 0, true, 10.0f },  { 1, false, 1.0f },  { 9, false, 1.0f },  { 10, false, 1.0f },
        { 20, false, 1.0f }, { 21, false, 1.0f }, { 22, true, 10.0f }, { 23, true, 10.0f },
    };
    for (const Row& row : rows) {
        SCOPED_TRACE(row.version);
        const auto g = ReadAt(FogInput(), row.version);
        ExpectHeightFogRead(g);
        EXPECT_EQ(g.fogdistance, row.distance_fog);
        EXPECT_FLOAT_EQ(g.fogdistancestart, row.distance_start);
    }
}

// B-1.03: absent fog keys leave the documented defaults.
TEST(GeneralBlockSchema, HeightFogDefaultsWhenTheKeysAreAbsent)
{
    for (const std::uint16_t version : { 0, 5, 23 }) {
        const auto g = ReadAt(Json::object(), version);
        EXPECT_FALSE(g.fogheight);
        EXPECT_FLOAT_EQ(g.fogheightstart, 1.0f);
        EXPECT_FLOAT_EQ(g.fogheightend, -3.0f);
        EXPECT_FLOAT_EQ(g.fogheightstartdensity, 0.0f);
        EXPECT_FLOAT_EQ(g.fogheightenddensity, 1.0f);
        EXPECT_EQ(g.fogheightcolor, (Vec3 { 0.0f, 0.0f, 0.0f }));
    }
}

// B-1.03: `fogheight` is a plain flag; a wrapped one reads, a number does not.
TEST(GeneralBlockSchema, HeightFogFlagTakesABooleanOrAWrappedBoolean)
{
    EXPECT_FALSE(ReadAt({ { "fogheight", 1 } }, 5).fogheight) << "a number is not a switch here";
    EXPECT_FALSE(ReadAt({ { "fogheight", 1 } }, 0).fogheight);
    EXPECT_TRUE(ReadAt({ { "fogheight", { { "value", true } } } }, 5).fogheight);
    EXPECT_TRUE(ReadAt({ { "fogheight", { { "value", true } } } }, 0).fogheight);
    EXPECT_FALSE(ReadAt({ { "fogheight", false } }, 23).fogheight);
}

// B-1.03: the settings a project property may drive keep the whole object beside the value.
TEST(GeneralBlockSchema, HeightFogSettingsKeepTheirBindings)
{
    const Json bound = { { "user", "p" }, { "value", 2 } };
    const auto g     = ReadAt({ { "fogheightstart", bound },
                                { "fogheightend", { { "user", "q" }, { "value", 8 } } },
                                { "fogheightstartdensity", { { "user", "r" }, { "value", 0.25 } } },
                                { "fogheightenddensity", { { "user", "s" }, { "value", 0.75 } } },
                                { "fogheightcolor", { { "user", "t" }, { "value", Json::array({ 0.9, 0.8, 0.7 }) } } } },
                              5);
    EXPECT_FLOAT_EQ(g.fogheightstart, 2.0f);
    EXPECT_EQ(g.fogheightstart_setting, bound);
    EXPECT_FLOAT_EQ(g.fogheightend, 8.0f);
    EXPECT_EQ(g.fogheightend_setting, (Json { { "user", "q" }, { "value", 8 } }));
    EXPECT_FLOAT_EQ(g.fogheightstartdensity, 0.25f);
    EXPECT_EQ(g.fogheightstartdensity_setting, (Json { { "user", "r" }, { "value", 0.25 } }));
    EXPECT_FLOAT_EQ(g.fogheightenddensity, 0.75f);
    EXPECT_EQ(g.fogheightenddensity_setting, (Json { { "user", "s" }, { "value", 0.75 } }));
    EXPECT_EQ(g.fogheightcolor, (Vec3 { 0.9f, 0.8f, 0.7f }));
    EXPECT_TRUE(g.fogheightcolor_setting.is_object());
    EXPECT_EQ(g.fogheightcolor_setting.at("user").get<std::string>(), "t");
}

// B-1.03: a colour that is not three numbers keeps black.
TEST(GeneralBlockSchema, HeightFogColourNeedsThreeNumbers)
{
    for (const Json& bad : { Json::array({ 0.9, 0.8 }), Json::array({ 0.9, 0.8, 0.7, 0.6 }), Json::array({ "a", "b", "c" }), Json(nullptr), Json::object() }) {
        SCOPED_TRACE(bad.dump());
        EXPECT_EQ(ReadAt({ { "fogheightcolor", bad } }, 5).fogheightcolor, (Vec3 { 0.0f, 0.0f, 0.0f }));
    }
}

// ---- the same gates through the scene root -----------------------------------------------

// R-1.03 / B-1.02: the root hands its package version to the general block.
TEST(GeneralBlockSchema, SceneRootPassesItsVersionToTheGates)
{
    const Json root = SceneRootOf(GateInput());

    WPScene at20;
    ASSERT_TRUE(at20.FromJson(root, 20));
    EXPECT_EQ(at20.pkg_version, 20);
    EXPECT_TRUE(at20.general.hdr);
    EXPECT_TRUE(at20.general.norecompile);
    EXPECT_FLOAT_EQ(at20.general.bloomtint[2], 0.4f);
    EXPECT_FALSE(at20.general.windenabled);
    EXPECT_TRUE(at20.general.lightconfig.is_null());
    EXPECT_FALSE(at20.general.transparentsorting);
    EXPECT_FALSE(at20.general.fogdistance);

    WPScene at23;
    ASSERT_TRUE(at23.FromJson(root, 23));
    EXPECT_EQ(at23.pkg_version, 23);
    EXPECT_TRUE(at23.general.hdr);
    EXPECT_FLOAT_EQ(at23.general.bloomtint[2], 0.4f);
    EXPECT_TRUE(at23.general.windenabled);
    EXPECT_FLOAT_EQ(at23.general.windstrength, 3.0f);
    EXPECT_EQ(at23.general.lightconfig.at("point").get<int>(), 2);
    EXPECT_TRUE(at23.general.transparentsorting);
    EXPECT_TRUE(at23.general.fogdistance);
    EXPECT_FLOAT_EQ(at23.general.fogdistancestart, 10.0f);

    EXPECT_EQ(at20.camera.eye, (Vec3 { 0.0f, 10.0f, 20.0f })) << "the camera block is read at any version";
}

// R-1.03 / B-1.03: height fog survives at the low and the high root version alike.
TEST(GeneralBlockSchema, SceneRootReadsHeightFogAtEveryVersion)
{
    const Json root = SceneRootOf(FogInput());
    for (const std::uint16_t version : { 0, 1, 20, 22, 23 }) {
        SCOPED_TRACE(version);
        WPScene scene;
        ASSERT_TRUE(scene.FromJson(root, version));
        EXPECT_EQ(scene.pkg_version, version);
        ExpectHeightFogRead(scene.general);
    }
}

// B-1.02: the unversioned root overload behaves as version 0.
TEST(GeneralBlockSchema, SceneRootWithoutAVersionReadsEverything)
{
    WPScene scene;
    ASSERT_TRUE(scene.FromJson(SceneRootOf(GateInput())));
    EXPECT_EQ(scene.pkg_version, WPSceneGeneral::kSceneVersionUnknown);
    EXPECT_TRUE(scene.general.hdr);
    EXPECT_TRUE(scene.general.fogdistance);
    EXPECT_TRUE(scene.general.fogheight);
}

} // namespace
