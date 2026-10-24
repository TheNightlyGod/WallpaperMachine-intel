// Scene file schema, part 10 (vector constants): timelines on the two-component shader constants
// of a material share one clock when the file links them, hold their first keys while that clock
// is paused, answer to a script that plays or stops the clock, and wrap on the parent's length.
#include "support/schema_fixtures.hpp"
#include "support/schema_layer_assets.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

#include <gtest/gtest.h>

#include <array>
#include <memory>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::layers;
using namespace wallpaper;

constexpr const char* kLayer = "fold page";

// One image layer `fold page` over the given constants, parsed live.
struct FoldRig {
    explicit FoldRig(const Json& constants)
        : rig(VectorAssets({ { kLayer, constants } }))
    {
        scene = rig.Parse(VectorSceneJson({ { kLayer, constants } }), { .live = true });
    }
    // The live constant `key` of the layer's material, read afresh.
    std::vector<float> Read(const std::string& key) const
    {
        auto* material = scene ? FoldMaterial(*scene, kLayer) : nullptr;
        if (material == nullptr) {
            ADD_FAILURE() << "no material";
            return {};
        }
        return Constant(*material, key);
    }
    void Expect(const std::string& key, std::initializer_list<float> lanes, const std::string& what = {}) const
    {
        const auto actual = Read(key);
        ASSERT_EQ(actual.size(), 2u) << key << " " << what;
        std::size_t lane = 0;
        for (const float want : lanes) {
            EXPECT_FLOAT_EQ(actual[lane], want) << key << "[" << lane << "] " << what;
            ++lane;
        }
    }
    SceneRuntimeContext& runtime() { return *scene->runtime; }

    ParseRig               rig;
    std::shared_ptr<Scene> scene;
};

// ---- a paused group ----------------------------------------------------------------------------------

// R-10.11 / B-10.11
TEST(VectorConstantTimelines, APausedGroupAppliesItsFirstKeysToEveryMemberAtOnce)
{
    FoldRig fold(PausedFoldConstants());
    ASSERT_NE(fold.scene, nullptr);
    ASSERT_NE(fold.scene->runtime, nullptr);

    {
        SCOPED_TRACE("after parse: the child's static value is not used");
        fold.Expect("u_Point1", { 0.875f, 0.875f });
        fold.Expect("u_Point2", { 0.75f, 0.375f });
    }
    fold.runtime().Tick(5.0);
    {
        SCOPED_TRACE("the parent's clock is paused, so time passes for nobody");
        fold.Expect("u_Point1", { 0.875f, 0.875f });
        ASSERT_EQ(fold.Read("u_Point2").size(), 2u);
        EXPECT_FLOAT_EQ(fold.Read("u_Point2")[0], 0.75f);
    }
}

TEST(VectorConstantTimelines, TheGroupsClockRunsBothMembersOnceItPlays)
{
    FoldRig fold(PausedFoldConstants());
    ASSERT_NE(fold.scene, nullptr);
    auto* clock = fold.runtime().FindScalarAnimation(kLayer, "fold");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    fold.runtime().Tick(1.5 / 30.0);
    fold.Expect("u_Point1", { 0.625f, 0.875f });
    fold.Expect("u_Point2", { 0.5f, 0.375f });
    fold.runtime().Tick(5.0);
    fold.Expect("u_Point1", { 0.375f, 0.875f }, "at the end");
    fold.Expect("u_Point2", { 0.25f, 0.375f }, "at the end");
}

// ---- a script drives the group ----------------------------------------------------------------------------

// Runs `commands` as the body of a property script's update, on the fold layer, once.
void RunScript(FoldRig& fold, const std::string& commands)
{
    auto& runtime = fold.runtime();
    const std::string source = "export function update(value) { var fold = thisLayer.getAnimation('fold'); " + commands + " return value; }";
    auto program = runtime.scriptEngine().CreatePropertyScriptProgram(&runtime, source, kLayer, {}, DynamicValue(0.0f), runtime.hostContext());
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->Valid());
    (void)program->Evaluate(runtime.hostContext(), DynamicValue(0.0f));
}

// R-10.12 / B-10.12
TEST(VectorConstantTimelineScripts, ParentAndChildFollowAScriptOnTheSameFrame)
{
    FoldRig fold(PausedFoldConstants());
    ASSERT_NE(fold.scene, nullptr);
    ASSERT_NE(fold.scene->runtime, nullptr);
    auto& runtime = fold.runtime();

    RunScript(fold, "fold.play();");
    runtime.Tick(1.5 / 30.0);
    {
        SCOPED_TRACE("play");
        fold.Expect("u_Point1", { 0.625f, 0.875f });
        fold.Expect("u_Point2", { 0.5f, 0.375f });
    }
    RunScript(fold, "fold.pause();");
    runtime.Tick(1.0);
    {
        SCOPED_TRACE("pause");
        fold.Expect("u_Point1", { 0.625f, 0.875f });
        fold.Expect("u_Point2", { 0.5f, 0.375f });
    }
    RunScript(fold, "fold.play(); fold.rate = 2;");
    runtime.Tick(1.0 / 30.0);
    {
        SCOPED_TRACE("play at twice the rate: two frames carry it to the end");
        fold.Expect("u_Point1", { 0.375f, 0.875f });
        fold.Expect("u_Point2", { 0.25f, 0.375f });
    }
    RunScript(fold, "fold.play();");
    runtime.Tick(0.0);
    {
        SCOPED_TRACE("playing a finished single timeline starts it over");
        fold.Expect("u_Point1", { 0.875f, 0.875f });
        fold.Expect("u_Point2", { 0.75f, 0.375f });
    }
    RunScript(fold, "fold.setFrame(3); fold.stop();");
    runtime.Tick(0.0);
    {
        SCOPED_TRACE("stop returns to the first key");
        fold.Expect("u_Point1", { 0.875f, 0.875f });
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// ---- a parent that is longer than its child ------------------------------------------------------------------

Json WrapConstants(const std::string& parent_mode)
{
    return { { "point1",
               VectorConstant(9, 9, TimelineOptions(15, "loop", { { "parent", { { "key", "point2" } } } }), Curve({ { 0, 0 }, { 15, 1 } }),
                              Curve({ { 0, 0 }, { 15, 2 } })) },
             { "point2", VectorConstant(0, 0.625, TimelineOptions(60, parent_mode, { { "name", "fold" } }), Curve({ { 0, 0 }, { 60, 1 } })) } };
}

class SharedTimelineWrap : public ::testing::TestWithParam<std::string> {};

// R-10.13 / B-10.13
TEST_P(SharedTimelineWrap, AChildWrapsOnlyOnTheParentsClock)
{
    const std::string mode = GetParam();
    FoldRig           fold(WrapConstants(mode));
    ASSERT_NE(fold.scene, nullptr);
    ASSERT_NE(fold.scene->runtime, nullptr);
    auto& runtime = fold.runtime();

    {
        SCOPED_TRACE("after parse");
        ASSERT_EQ(fold.Read("u_Point1").size(), 2u);
        EXPECT_FLOAT_EQ(fold.Read("u_Point1")[0], 0.0f);
        ASSERT_EQ(fold.Read("u_Point2").size(), 2u);
        EXPECT_FLOAT_EQ(fold.Read("u_Point2")[1], 0.625f) << "a component with no curve keeps its value";
    }
    runtime.Tick(1.0);
    {
        SCOPED_TRACE("parent frame 30");
        fold.Expect("u_Point1", { 1.0f, 2.0f }, "the child holds its end instead of restarting every 15 frames");
        fold.Expect("u_Point2", { 0.5f, 0.625f });
    }
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("parent frame 45");
        fold.Expect("u_Point1", { 1.0f, 2.0f });
    }
    auto* clock = runtime.FindScalarAnimation(kLayer, "fold");
    ASSERT_NE(clock, nullptr);
    clock->SetFrame(10);
    runtime.Tick(0.0);
    {
        SCOPED_TRACE("a seek to frame 10 puts the child at 10/15 of its curves");
        const auto actual = fold.Read("u_Point1");
        ASSERT_EQ(actual.size(), 2u);
        EXPECT_NEAR(actual[0], 2.0 / 3.0, 1e-6);
        EXPECT_NEAR(actual[1], 4.0 / 3.0, 1e-6);
    }
    clock->SetFrame(45);
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("parent frame 60");
        if (mode == "loop") {
            fold.Expect("u_Point1", { 0.0f, 0.0f }, "the parent wrapped and took the child with it");
        } else {
            fold.Expect("u_Point1", { 1.0f, 2.0f }, "the parent finished");
        }
    }
    if (mode == "single") {
        clock->Play();
        runtime.Tick(0.0);
        SCOPED_TRACE("playing the finished parent starts the group over");
        fold.Expect("u_Point1", { 0.0f, 0.0f });
    }
}

INSTANTIATE_TEST_SUITE_P(Modes, SharedTimelineWrap, ::testing::Values(std::string("single"), std::string("loop")));

} // namespace
