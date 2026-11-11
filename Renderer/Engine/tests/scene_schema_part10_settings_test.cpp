// Scene file schema, part 10 (scene settings): the defaults a scene file that leaves settings out
// gets, how a parented layer inherits parallax depth, which ids are accepted, and which general
// settings are read at every package version.
#include "Scene/Parse/LayerParallax.hpp"
#include "Scene/Parse/wpscene/WPScene.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <string>
#include <tuple>
#include <vector>

namespace
{

using Json = nlohmann::json;
using wallpaper::ResolveLayerParallax;
using wallpaper::wpscene::WPScene;
using wallpaper::wpscene::WPSceneGeneral;

// ---- defaults -------------------------------------------------------------------------------------

// R-10.03 / B-10.03
TEST(SceneSettingDefaults, AbsentSettingsTakeWallpaperEnginesDefaults)
{
    const Json document = { { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
                            { "general", { { "cameraparallax", true }, { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } } };
    WPScene     scene;
    ASSERT_TRUE(scene.FromJson(document));
    const auto& general = scene.general;

    EXPECT_TRUE(general.cameraparallax);
    EXPECT_FLOAT_EQ(general.cameraparallaxamount, 0.5f);
    EXPECT_FLOAT_EQ(general.cameraparallaxdelay, 0.1f);
    EXPECT_FLOAT_EQ(general.cameraparallaxmouseinfluence, 0.5f);
    for (int lane = 0; lane < 3; ++lane) {
        EXPECT_FLOAT_EQ(general.ambientcolor[lane], 0.0f) << "ambient lane " << lane;
        EXPECT_FLOAT_EQ(general.skylightcolor[lane], 0.0f) << "skylight lane " << lane;
    }
    EXPECT_FLOAT_EQ(general.bloomhdrstrength, 2.0f);
    EXPECT_FLOAT_EQ(general.bloomhdrthreshold, 1.0f);
    EXPECT_FLOAT_EQ(general.bloomhdrfeather, 0.1f);
    EXPECT_FLOAT_EQ(general.bloomhdrscatter, 1.619f);
    EXPECT_EQ(general.bloomhdriterations, 8);
}

TEST(SceneGeneral, OmittedPhysicsAndNearPlaneTakeWallpaperEngineDefaults)
{
    // wallpaper64.exe sub_140186C90: nearz 0.1, gravity 1 along (0,-1,0), wind 1 along (0.707,0.707,0).
    const Json document = { { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
                            { "general", { { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } } };
    WPScene     scene;
    ASSERT_TRUE(scene.FromJson(document));
    const auto& general = scene.general;
    EXPECT_FLOAT_EQ(general.nearz, 0.1f);
    EXPECT_FLOAT_EQ(general.gravitystrength, 1.0f);
    EXPECT_FLOAT_EQ(general.gravitydirection[1], -1.0f);
    EXPECT_FLOAT_EQ(general.windstrength, 1.0f);
    EXPECT_NEAR(general.winddirection[0], 0.70710677f, 1e-6f);
    EXPECT_NEAR(general.winddirection[1], 0.70710677f, 1e-6f);
    EXPECT_FLOAT_EQ(general.winddirection[2], 0.0f);
}

TEST(SceneSettingDefaults, WrittenSettingsReplaceTheDefaults)
{
    const Json document = { { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
                            { "general",
                              { { "cameraparallax", true },
                                { "cameraparallaxamount", 0.9 },
                                { "cameraparallaxdelay", 0.4 },
                                { "cameraparallaxmouseinfluence", 0.25 },
                                { "bloomhdrstrength", 3.5 },
                                { "bloomhdrthreshold", 0.75 },
                                { "bloomhdrfeather", 0.2 },
                                { "bloomhdrscatter", 2.5 },
                                { "bloomhdriterations", 5 },
                                { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } } };
    WPScene     scene;
    ASSERT_TRUE(scene.FromJson(document));
    const auto& general = scene.general;
    EXPECT_FLOAT_EQ(general.cameraparallaxamount, 0.9f);
    EXPECT_FLOAT_EQ(general.cameraparallaxdelay, 0.4f);
    EXPECT_FLOAT_EQ(general.cameraparallaxmouseinfluence, 0.25f);
    EXPECT_FLOAT_EQ(general.bloomhdrstrength, 3.5f);
    EXPECT_FLOAT_EQ(general.bloomhdrthreshold, 0.75f);
    EXPECT_FLOAT_EQ(general.bloomhdrfeather, 0.2f);
    EXPECT_FLOAT_EQ(general.bloomhdrscatter, 2.5f);
    EXPECT_EQ(general.bloomhdriterations, 5);
}

// ---- parallax depth of parented layers ---------------------------------------------------------------

Json Layer(std::int64_t id, const Json& parent, const Json& depth)
{
    Json layer = { { "id", id } };
    if (!parent.is_null()) layer["parent"] = parent;
    if (!depth.is_null()) layer["parallaxDepth"] = depth;
    return layer;
}

// Runs the resolver over `layers`, in the order given or (when `reversed`) reversed around the call.
Json Resolved(Json layers, bool reversed)
{
    if (reversed) std::reverse(layers.begin(), layers.end());
    ResolveLayerParallax(layers);
    if (reversed) std::reverse(layers.begin(), layers.end());
    return layers;
}

// R-10.04 / B-10.04
TEST(LayerParallaxInheritance, AParentedLayerTakesTheOutermostParentsDepthWhateverTheOrder)
{
    const Json depth_root = Json::array({ 0.75, -0.25 });
    const Json layers     = Json::array({ Layer(3, 2, Json::array({ 9, 9 })),       // 0: grandchild of layer 1
                                          Layer(2, 1, Json::array({ 0, 0 })),       // 1: child of layer 1
                                          Layer(1, nullptr, depth_root),            // 2: a root
                                          Layer(4, 5, Json::array({ 1, 1 })),       // 3: child of a root with no depth
                                          Layer(5, nullptr, nullptr),               // 4: that root
                                          Layer(6, 99, Json::array({ 0.2, 0.4 })),  // 5: parent id names no layer
                                          Layer(7, 8, Json::array({ 2, 3 })),       // 6: a cycle with 7
                                          Layer(8, 7, Json::array({ 4, 5 })),       // 7
                                          Layer(9, nullptr, Json::array({ 6, 7 })), // 8: id 9 is used twice
                                          Layer(9, nullptr, Json::array({ 8, 9 })), // 9
                                          Layer(10, 9, Json::array({ 10, 11 })) }); // 10: its parent id is ambiguous
    for (const bool reversed : { false, true }) {
        SCOPED_TRACE(reversed ? "reversed order" : "listed order");
        const Json result = Resolved(layers, reversed);
        ASSERT_EQ(result.size(), layers.size());

        EXPECT_EQ(result[0]["parallaxDepth"], depth_root) << "grandchild";
        EXPECT_EQ(result[1]["parallaxDepth"], depth_root) << "child";
        EXPECT_EQ(result[3]["parallaxDepth"], Json::array({ 1, 1 })) << "a root without a depth gives the default";
        for (const std::size_t unchanged : { 2u, 4u, 5u, 6u, 7u, 8u, 9u, 10u }) {
            EXPECT_EQ(result[unchanged], layers[unchanged]) << "layer " << unchanged << " is left alone";
        }
        // The other keys of an inheriting layer survive.
        EXPECT_EQ(result[0]["id"], 3);
        EXPECT_EQ(result[0]["parent"], 2);
    }
}

TEST(LayerParallaxInheritance, ADeepChainReachesTheRootAndASiblingKeepsItsOwnRoot)
{
    const Json layers = Json::array({ Layer(1, nullptr, Json::array({ 0.5, 0.5 })), Layer(2, 1, Json::array({ 7, 7 })),
                                      Layer(3, 2, Json::array({ 7, 7 })), Layer(4, 3, Json::array({ 7, 7 })),
                                      Layer(5, nullptr, Json::array({ 0.25, 2 })), Layer(6, 5, Json::array({ 7, 7 })) });
    for (const bool reversed : { false, true }) {
        SCOPED_TRACE(reversed ? "reversed order" : "listed order");
        const Json result = Resolved(layers, reversed);
        for (const int index : { 1, 2, 3 }) EXPECT_EQ(result[index]["parallaxDepth"], Json::array({ 0.5, 0.5 })) << index;
        EXPECT_EQ(result[5]["parallaxDepth"], Json::array({ 0.25, 2 }));
        EXPECT_EQ(result[0], layers[0]);
        EXPECT_EQ(result[4], layers[4]);
    }
}

// ---- ids outside 32 bits ---------------------------------------------------------------------------------

struct IdRow {
    Json invalid;
    Json valid;
};

std::vector<IdRow> OutOfRangeRows()
{
    return { { Json(std::int64_t { 2147483648LL }), Json(std::int64_t { -2147483648LL }) },
             { Json(std::int64_t { -2147483649LL }), Json(std::int64_t { 2147483647LL }) },
             { Json(std::uint64_t { 2147483648ULL }), Json(std::int64_t { -2147483648LL }) },
             { Json(std::uint64_t { 18446744073709551615ULL }), Json(std::int64_t { -1 }) },
             { Json(std::int64_t { 4294967297LL }), Json(std::int64_t { 1 }) } };
}

// R-10.05 / B-10.05
TEST(LayerParallaxIds, AnIdOutsideThirtyTwoBitsNeverAliasesARealLayer)
{
    for (const auto& row : OutOfRangeRows()) {
        for (const bool include_invalid_id : { false, true }) {
            for (const bool reversed : { false, true }) {
                SCOPED_TRACE("invalid id " + row.invalid.dump() + ", valid id " + row.valid.dump() +
                             (include_invalid_id ? ", a layer carries the invalid id" : "") + (reversed ? ", reversed" : ""));
                Json layers = Json::array({ Layer(0, nullptr, Json::array({ 0.75, -0.25 })), Layer(2, nullptr, Json::array({ 2, 3 })),
                                            Layer(3, nullptr, Json::array({ 4, 5 })) });
                layers[0]["id"]     = row.valid;
                layers[1]["parent"] = row.valid;
                layers[2]["parent"] = row.invalid;
                if (include_invalid_id) {
                    layers.push_back(Layer(0, nullptr, Json::array({ 9, 9 })));
                    layers[3]["id"] = row.invalid;
                }
                const Json result = Resolved(layers, reversed);
                EXPECT_EQ(result[1]["parallaxDepth"], result[0]["parallaxDepth"]);
                EXPECT_EQ(result[2], layers[2]) << "an out-of-range parent id names no layer";
                EXPECT_EQ(result[0], layers[0]);
                if (include_invalid_id) EXPECT_EQ(result[3], layers[3]);
            }
        }
    }
}

// R-10.06 / B-10.06
TEST(LayerParallaxIds, TheSignedBoundariesAndUnsignedInRangeIdsAreAccepted)
{
    const std::vector<Json> ids = { Json(std::int64_t { -2147483648LL }), Json(std::int64_t { 2147483647LL }),
                                    Json(std::uint64_t { 2147483647ULL }) };
    for (const auto& id : ids) {
        SCOPED_TRACE("id " + id.dump() + (id.is_number_unsigned() ? " (unsigned)" : ""));
        Json layers         = Json::array({ Layer(1, id, Json::array({ 9, 9 })), Layer(0, nullptr, Json::array({ 0.75, -0.25 })) });
        layers[1]["id"]     = id;
        const Json result   = Resolved(layers, false);
        EXPECT_EQ(result[0]["parallaxDepth"], result[1]["parallaxDepth"]);
        EXPECT_EQ(result[0]["parallaxDepth"], Json::array({ 0.75, -0.25 }));
    }
}

TEST(LayerParallaxIds, AFractionalOrTextualIdIsNoId)
{
    Json layers = Json::array({ Layer(1, nullptr, Json::array({ 0.75, -0.25 })), Layer(2, 1, Json::array({ 2, 3 })) });
    layers[0]["id"] = 1.5;
    EXPECT_EQ(Resolved(layers, false)[1], layers[1]) << "a parent id with a fraction names no layer";
    layers[0]["id"] = "1";
    EXPECT_EQ(Resolved(layers, false)[1], layers[1]) << "a textual id names no layer";
    layers[0]["id"] = 1;
    EXPECT_EQ(Resolved(layers, false)[1]["parallaxDepth"], layers[0]["parallaxDepth"]);
}

// ---- package version gates ---------------------------------------------------------------------------------

// R-10.08 / B-10.08
TEST(GeneralSettingVersionGates, PerspectiveOverrideFovIsReadAtAnyVersionAndWindIsGated)
{
    const Json general = { { "perspectiveoverridefov", 70.0 }, { "windenabled", true } };
    {
        WPSceneGeneral read;
        ASSERT_TRUE(read.FromJson(general, 9));
        EXPECT_FLOAT_EQ(read.perspectiveoverridefov, 70.0f);
        EXPECT_FALSE(read.windenabled) << "wind is a version-21 key";
    }
    for (const std::uint16_t version : { std::uint16_t { 21 }, WPSceneGeneral::kSceneVersionUnknown }) {
        SCOPED_TRACE("version " + std::to_string(version));
        WPSceneGeneral read;
        ASSERT_TRUE(read.FromJson(general, version));
        EXPECT_FLOAT_EQ(read.perspectiveoverridefov, 70.0f);
        EXPECT_TRUE(read.windenabled);
    }
}

TEST(GeneralSettingVersionGates, EachKeyIsReadFromItsVersionOn)
{
    const Json general = { { "hdr", true },
                           { "bloomtint", { 0.25, 0.5, 0.75 } },
                           { "windenabled", true },
                           { "transparentsorting", true },
                           { "fogdistance", true },
                           { "fogheight", true },
                           { "fov", 33.0 },
                           { "zoom", 2.0 },
                           { "perspectiveoverridefov", 70.0 } };
    for (const std::uint16_t version : { std::uint16_t { WPSceneGeneral::kSceneVersionUnknown }, std::uint16_t { 1 }, std::uint16_t { 9 },
                                         std::uint16_t { 10 }, std::uint16_t { 19 }, std::uint16_t { 20 }, std::uint16_t { 21 },
                                         std::uint16_t { 22 }, std::uint16_t { 23 } }) {
        SCOPED_TRACE("version " + std::to_string(version));
        const auto reads = [version](std::uint16_t gate) { return version == WPSceneGeneral::kSceneVersionUnknown || version >= gate; };
        WPSceneGeneral read;
        ASSERT_TRUE(read.FromJson(general, version));
        EXPECT_EQ(read.hdr, reads(10));
        EXPECT_EQ(read.bloomtint[0] == 0.25f, reads(20));
        EXPECT_EQ(read.windenabled, reads(21));
        EXPECT_EQ(read.transparentsorting, reads(22));
        EXPECT_EQ(read.fogdistance, reads(22));
        EXPECT_TRUE(read.fogheight) << "height fog is read at any version";
        EXPECT_FLOAT_EQ(read.fov, 33.0f);
        EXPECT_FLOAT_EQ(read.zoom, 2.0f);
        EXPECT_FLOAT_EQ(read.perspectiveoverridefov, 70.0f);
    }
}

} // namespace
