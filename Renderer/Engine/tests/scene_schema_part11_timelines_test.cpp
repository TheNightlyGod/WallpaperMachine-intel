// Scene file schema, part 11 (shader-constant timelines): which timelines of a material join one
// group, what a group whose parent cannot be followed does, what the parser reports about
// constants it cannot place, and that a scripted vector constant keeps both of its components.
#include "support/schema_fixtures.hpp"
#include "support/schema_layer_assets.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Utils/Logging.h"

#include <gtest/gtest.h>

#include <mutex>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::layers;
using namespace wallpaper;

// ---- log capture -------------------------------------------------------------------------------------
// The log callback is process-wide: it is installed for the span of one parse and removed again.

std::mutex               g_log_mutex;
std::vector<std::string> g_errors;

void CollectErrors(int level, const char*, int, const char* message)
{
    if (level != LOGLEVEL_ERROR) return;
    std::scoped_lock lock(g_log_mutex);
    g_errors.emplace_back(message);
}

class ErrorLog {
public:
    ErrorLog()
    {
        {
            std::scoped_lock lock(g_log_mutex);
            g_errors.clear();
        }
        SetWallpaperLogCallback(&CollectErrors);
    }
    ~ErrorLog() { SetWallpaperLogCallback(nullptr); }
    ErrorLog(const ErrorLog&)            = delete;
    ErrorLog& operator=(const ErrorLog&) = delete;

    std::vector<std::string> Errors() const
    {
        std::scoped_lock lock(g_log_mutex);
        return g_errors;
    }
};

// ---- scenes ----------------------------------------------------------------------------------------------

std::vector<float> ReadConstant(Scene& scene, const std::string& layer, const std::string& key)
{
    auto* material = FoldMaterial(scene, layer);
    if (material == nullptr) {
        ADD_FAILURE() << "layer " << layer << " has no material";
        return {};
    }
    return Constant(*material, key);
}

void ExpectConstant(Scene& scene, const std::string& layer, const std::string& key, std::initializer_list<float> lanes)
{
    const auto actual = ReadConstant(scene, layer, key);
    ASSERT_EQ(actual.size(), lanes.size()) << layer << " " << key;
    std::size_t lane = 0;
    for (const float want : lanes) {
        EXPECT_FLOAT_EQ(actual[lane], want) << layer << " " << key << "[" << lane << "]";
        ++lane;
    }
}

Json Single(const Json& extra = Json::object())
{
    return TimelineOptions(3, "single", extra);
}

Json CyclicConstants()
{
    return { { "point1", VectorConstant(9, 0.25, Single({ { "parent", { { "key", "point2" } } } }), Curve({ { 0, 0.5 }, { 3, 0.125 } })) },
             { "point2", VectorConstant(9, 9, Single({ { "parent", { { "key", "point1" } } } }), Curve({ { 0, 0.25 }, { 3, 0.75 } }),
                                        Curve({ { 0, 0.5 }, { 3, 0.75 } })) } };
}

Json OrphanConstants()
{
    return { { "point1", VectorConstant(9, 9, Single({ { "parent", { { "key", "point9" } } } }), Curve({ { 0, 0.25 }, { 3, 0.75 } }),
                                        Curve({ { 0, 0.5 }, { 3, 0.75 } })) } };
}

// R-11.01 / B-11.01
TEST(ConstantTimelineGroups, UnrelatedCyclicAndOrphanTimelinesKeepTheirOwnConstants)
{
    const std::vector<VectorLayer> layers = {
        { "fold page", PausedFoldConstants() },
        { "free page", { { "point1", VectorConstant(0.375, 0.875, Single(), Curve({ { 0, 0.875 }, { 3, 0.125 } }), Curve({ { 0, 0.875 }, { 3, 0.875 } })) } } },
        { "cyclic page", CyclicConstants() },
        { "orphan page", OrphanConstants() },
    };
    ParseRig rig(VectorAssets(layers));
    auto     scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (const auto& layer : layers) ASSERT_NE(FoldMaterial(*scene, layer.name), nullptr) << layer.name;

    scene->runtime->Tick(5.0);
    {
        SCOPED_TRACE("fold page: the paused group holds its first key");
        ASSERT_EQ(ReadConstant(*scene, "fold page", "u_Point1").size(), 2u);
        EXPECT_FLOAT_EQ(ReadConstant(*scene, "fold page", "u_Point1")[0], 0.875f);
    }
    {
        SCOPED_TRACE("free page: its own timeline ran to the end, apart from the other layer's group");
        ASSERT_EQ(ReadConstant(*scene, "free page", "u_Point1").size(), 2u);
        EXPECT_FLOAT_EQ(ReadConstant(*scene, "free page", "u_Point1")[0], 0.125f);
    }
    {
        SCOPED_TRACE("cyclic page: frozen on first keys; the unkeyed lane keeps its value");
        ExpectConstant(*scene, "cyclic page", "u_Point1", { 0.5f, 0.25f });
        ExpectConstant(*scene, "cyclic page", "u_Point2", { 0.25f, 0.5f });
    }
    {
        SCOPED_TRACE("orphan page: the parent does not exist, so the timeline stays on its first keys");
        ExpectConstant(*scene, "orphan page", "u_Point1", { 0.25f, 0.5f });
    }
}

// Each layer alone, so a failure names the layer without the others' help.
TEST(ConstantTimelineGroups, AFreeTimelineEndsOnItsLastKeyAndTheOtherLanesStay)
{
    const std::vector<VectorLayer> layers = { { "free page", { { "point1", VectorConstant(0.375, 0.875, Single(), Curve({ { 0, 0.875 }, { 3, 0.125 } }), Curve({ { 0, 0.875 }, { 3, 0.875 } })) } } } };
    ParseRig                       rig(VectorAssets(layers));
    auto                           scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ExpectConstant(*scene, "free page", "u_Point1", { 0.875f, 0.875f });
    scene->runtime->Tick(0.05);
    ExpectConstant(*scene, "free page", "u_Point1", { 0.875f - (0.875f - 0.125f) * 1.5f / 3.0f, 0.875f });
    scene->runtime->Tick(5.0);
    ExpectConstant(*scene, "free page", "u_Point1", { 0.125f, 0.875f });
}

// ---- reports about broken groups ---------------------------------------------------------------------------

Json OrphanPair(const std::string& parent1, const std::string& parent2)
{
    return { { "point1", VectorConstant(9, 9, Single({ { "parent", { { "key", parent1 } } } }), Curve({ { 0, 0.25 }, { 3, 0.75 } })) },
             { "point2", VectorConstant(9, 9, Single({ { "parent", { { "key", parent2 } } } }), Curve({ { 0, 0.5 }, { 3, 0.75 } })) } };
}

std::size_t ErrorsWhileParsing(const std::vector<VectorLayer>& layers)
{
    ParseRig rig(VectorAssets(layers));
    ErrorLog log;
    auto     scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    EXPECT_NE(scene, nullptr);
    return log.Errors().size();
}

// R-11.02 / B-11.02
TEST(ConstantTimelineErrors, ABrokenParentIsReportedOncePerBrokenGroup)
{
    EXPECT_EQ(ErrorsWhileParsing({ { "orphans", OrphanPair("point9", "point9") } }), 1u)
        << "two constants naming the same missing parent are one group";
    EXPECT_EQ(ErrorsWhileParsing({ { "orphans", OrphanPair("point8", "point9") } }), 2u)
        << "two different missing parents are two groups";
}

TEST(ConstantTimelineErrors, ACyclicPairIsOneBrokenGroupAndAGoodGroupIsSilent)
{
    EXPECT_EQ(ErrorsWhileParsing({ { "cyclic page", CyclicConstants() } }), 1u);
    EXPECT_EQ(ErrorsWhileParsing({ { "fold page", PausedFoldConstants() } }), 0u);
    EXPECT_EQ(ErrorsWhileParsing({ { "fold page", PausedFoldConstants() }, { "free page", CyclicConstants() } }), 1u);
}

// R-11.03 / B-11.03
TEST(ConstantTimelineErrors, AConstantThatNamesNoUniformIsReportedOncePerPass)
{
    const std::vector<VectorLayer> layers = { { "ghosts",
                                                { { "point1", VectorConstant(0.25, 0.5) }, { "ghostpoint", { { "value", Json::array({ 1, 2 }) } } } } } };
    ParseRig rig(VectorAssets(layers));
    ErrorLog log;
    auto     scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    ASSERT_NE(scene, nullptr);
    const auto errors = log.Errors();
    ASSERT_EQ(errors.size(), 1u);
    EXPECT_NE(errors[0].find("ghostpoint"), std::string::npos) << errors[0];
    ExpectConstant(*scene, "ghosts", "u_Point1", { 0.25f, 0.5f });
}

TEST(ConstantTimelineErrors, AKeySuppliedAsAStartEndPairIsSilent)
{
    const std::string extra = "uniform float u_RangeStart; // {\"material\":\"rangeStart\",\"default\":0.0}\n"
                              "uniform float u_RangeEnd; // {\"material\":\"rangeEnd\",\"default\":1.0}\n";
    const std::vector<VectorLayer> layers = { { "ranges",
                                                { { "point1", VectorConstant(0.25, 0.5) },
                                                  { "range", { { "value", Json::array({ 1, 2 }) } } },
                                                  { "rangeStart", { { "value", 0.25 } } },
                                                  { "rangeEnd", { { "value", 0.75 } } } } } };
    ParseRig                       rig(VectorAssets(layers, extra));
    ErrorLog                       log;
    auto                           scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(log.Errors().empty()) << log.Errors().front();
}

// ---- scripted vector constants ----------------------------------------------------------------------------------

// R-11.04 / B-11.04
TEST(ScriptedVectorConstants, EveryComponentReachesTheScriptAndComesBack)
{
    const std::vector<VectorLayer> layers = {
        { "scripted",
          { { "point1", Scripted(Json::array({ 0.125, 0.25 }), "export function update(value) { return new Vec2(value.y, value.x); }") },
            { "point2", Scripted(Json::array({ 0.5, 0.75 }), "export function update(value) { return value; }") } } }
    };
    ParseRig rig(VectorAssets(layers));
    auto     scene = rig.Parse(VectorSceneJson(layers), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* material = FoldMaterial(*scene, "scripted");
    ASSERT_NE(material, nullptr);
    EXPECT_TRUE(material->customShader.constValues.contains("u_Point1"));
    EXPECT_TRUE(material->customShader.constValues.contains("u_Point2"));

    scene->runtime->Tick(1.0 / 60.0);
    ExpectConstant(*scene, "scripted", "u_Point1", { 0.25f, 0.125f });
    ExpectConstant(*scene, "scripted", "u_Point2", { 0.5f, 0.75f });
    scene->runtime->Tick(1.0 / 60.0);
    ExpectConstant(*scene, "scripted", "u_Point1", { 0.125f, 0.25f });
    ExpectConstant(*scene, "scripted", "u_Point2", { 0.5f, 0.75f });
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

} // namespace
