// Runtime text mutation: a text change is recorded at once and measured and drawn later by the
// text worker; dirty flags, the cache revision and the cache identity; the card and its picture
// being replaced under the same texture key. Some tests use a runtime with no scene at all.
// Headless: no renderer, no window.

#include "text_fixture.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"

#include <chrono>
#include <thread>

namespace
{
using namespace we_test;
using namespace wallpaper;

TextLayerState Layer(const std::string& text, float point_size, const std::string& font = "Arial")
{
    TextLayerState state;
    state.text       = text;
    state.font_key   = font;
    state.point_size = point_size;
    return state;
}

/// A runtime without a scene, with nodes it owns.
class BareRuntime : public ::testing::Test {
protected:
    std::unique_ptr<SceneRuntimeContext>    runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    std::vector<std::shared_ptr<SceneNode>> nodes;

    void Add(const std::string& name, TextLayerState state)
    {
        nodes.push_back(std::make_shared<SceneNode>());
        runtime->RegisterNode(name, nodes.back().get());
        runtime->RegisterTextLayer(name, std::move(state));
    }

    TextLayerState State(const std::string& name)
    {
        const auto state = runtime->NodeTextState(name);
        EXPECT_TRUE(state.has_value());
        return state.value_or(TextLayerState {});
    }
};

} // namespace

class TextRuntimeBare : public BareRuntime {};
class TextRuntimeScene : public TextSceneTest {};

// ---- I. mutating text at run time --------------------------------------------------------

TEST_F(TextRuntimeBare, AChangeUpdatesTextSizeRevisionAndDirtyState)
{
    ASSERT_NE(runtime, nullptr);
    TextLayerState state = Layer("a", 10.0f);
    state.padding = state.authored_padding = linalg::Vector2f(2.0f, 2.0f);
    state.horizontal_align                  = "left";
    state.vertical_align                    = "top";
    Add("caption", state);

    const auto before_size  = runtime->NodeSize("caption");
    const auto before_state = State("caption");
    EXPECT_FALSE(before_state.texture_cache_key.empty());
    EXPECT_EQ(before_state.cache_revision, 1u);

    ASSERT_TRUE(runtime->SetNodeText("caption", "longer text"));
    EXPECT_EQ(runtime->NodeText("caption"), "longer text");
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));

    ASSERT_TRUE(PumpUntilClean(*runtime, { "caption" }));
    const auto after_size = runtime->NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_EQ(after_size.y(), before_size.y());
    const auto after_state = State("caption");
    EXPECT_EQ(after_state.cache_revision, before_state.cache_revision + 1);
    EXPECT_FALSE(after_state.cache_dirty);
    EXPECT_FALSE(after_state.full_dirty);

    runtime->ClearNodeTextDirty("caption");
    const auto cleared = State("caption");
    EXPECT_EQ(cleared.text, "longer text");
    EXPECT_EQ(cleared.cache_revision, after_state.cache_revision);
    EXPECT_FALSE(cleared.cache_dirty);
    EXPECT_FALSE(cleared.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST_F(TextRuntimeBare, WritingTheTextAlreadyHeldCostsNothing)
{
    TextLayerState state = Layer("12:34", 33.0f, "systemfont_sansserif");
    state.padding = state.authored_padding = linalg::Vector2f(32.0f, 32.0f);
    Add("caption", state);
    auto  value = std::make_unique<DynamicValue>(std::string("12:34"));
    auto* bound = value.get();
    runtime->RegisterTextValue("caption", std::move(value));
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    const auto before = State("caption");
    ASSERT_FALSE(before.cache_dirty);
    ASSERT_FALSE(before.full_dirty);

    // The bound value is assigned the very text the layer shows: its generation moves on, so the
    // tick looks at the layer, and finds nothing to do.
    bound->update(std::string("12:34"));
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    const auto after = State("caption");
    EXPECT_EQ(after.cache_revision, before.cache_revision);
    EXPECT_FALSE(after.cache_dirty);
    EXPECT_FALSE(after.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeBare, APumpedChangeClearsDirtyWithoutLosingTheText)
{
    Add("caption", Layer("before", 12.0f));
    ASSERT_TRUE(runtime->SetNodeText("caption", "after"));
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(*runtime, { "caption" }));
    const auto state = State("caption");
    EXPECT_EQ(state.text, "after");
    EXPECT_FALSE(state.cache_dirty);
    EXPECT_FALSE(state.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextRuntimeSceneless, ASceneThatCannotTakeATextureStillEndsClean)
{
    // A scene object with a runtime but no image source: nowhere to publish a picture to.
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    SceneRuntimeContext& rt = *scene.runtime;
    rt.AttachScene(&scene);
    const auto holder = std::make_shared<SceneNode>();
    rt.RegisterNode("caption", holder.get());
    rt.RegisterTextLayer("caption", Layer("before", 12.0f));

    const bool accepted = rt.SetNodeText("caption", "after");
    ASSERT_TRUE(accepted);
    ASSERT_TRUE(rt.NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(rt, { "caption" }));

    const auto settled = rt.NodeTextState("caption");
    ASSERT_TRUE(settled.has_value());
    EXPECT_FALSE(settled->cache_dirty || settled->full_dirty);
    EXPECT_FALSE(rt.NodeTextDirty("caption"));
    EXPECT_FALSE(rt.ConsumeSceneGraphMutationFlag()) << "no picture was published, so nothing needs a rebuild";
}

TEST_F(TextRuntimeScene, APumpedChangeRedrawsTheTextureTheMaterialUses)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a") })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    const std::string key    = CardTexture(*node);
    const auto        before = scene->imageParser->Parse(key);
    ASSERT_NE(before, nullptr);
    (void)Runtime().ConsumeSceneGraphMutationFlag();

    ASSERT_TRUE(Runtime().SetNodeText("caption", "aaaaaa"));
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    const auto after = scene->imageParser->Parse(key);
    ASSERT_NE(after, nullptr);
    EXPECT_NE(before->key, after->key) << "the picture was not replaced";
    EXPECT_GT(after->header.width, before->header.width);
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag()) << "the texture is swapped under its key";
    EXPECT_EQ(CardTexture(*node), key);
}

TEST_F(TextRuntimeScene, AHiddenLayerWaitsUntilItIsShown)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "before", { { "visible", false } }) })));
    ASSERT_NE(Node("caption"), nullptr);
    const std::string key    = CardTexture(*Node("caption"));
    const auto        before = scene->imageParser->Parse(key);
    ASSERT_NE(before, nullptr);

    ASSERT_TRUE(Runtime().SetNodeText("caption", "after"));
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    Runtime().PumpTextLayerCache();
    ASSERT_NE(scene->imageParser->Parse(key), nullptr);
    EXPECT_EQ(scene->imageParser->Parse(key)->key, before->key);
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    // Even when given time, nothing is prepared while the layer is hidden.
    for (int round = 0; round < 5; ++round) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        Runtime().PumpTextLayerCache();
    }
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    EXPECT_EQ(scene->imageParser->Parse(key)->key, before->key);

    EXPECT_TRUE(Runtime().SetNodeVisible("caption", true));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_NE(scene->imageParser->Parse(key)->key, before->key);
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
}

TEST_F(TextRuntimeBare, SettingTextNeverMeasuresOnTheCallingThread)
{
    TextLayerState state = Layer("fps: 59", 20.0f);
    state.padding = state.authored_padding = linalg::Vector2f(32.0f, 32.0f);
    Add("caption", state);
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->NodeTextDirty("caption"));

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(runtime->SetNodeText("caption", "fps: 60"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
}

TEST_F(TextRuntimeScene, AVisibleLayersPreparationIsDeferredAndLandsLater)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "before",
                                                { { "pointsize", 28 }, { "padding", 32 } }) })));
    ASSERT_NE(Node("caption"), nullptr);
    const std::string key    = CardTexture(*Node("caption"));
    const auto        before = scene->imageParser->Parse(key);
    ASSERT_NE(before, nullptr);

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(Runtime().SetNodeText("caption", "after after after"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(Runtime().NodeText("caption"), "after after after");
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    Runtime().PumpTextLayerCache();
    ASSERT_NE(scene->imageParser->Parse(key), nullptr);
    EXPECT_EQ(scene->imageParser->Parse(key)->key, before->key) << "the first pump only queues the job";
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    std::string latest = before->key;
    for (int round = 0; round < 200 && latest == before->key; ++round) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        Runtime().PumpTextLayerCache();
        const auto image = scene->imageParser->Parse(key);
        ASSERT_NE(image, nullptr);
        latest = image->key;
    }
    EXPECT_NE(latest, before->key) << "the job never landed";
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
}

TEST_F(TextRuntimeScene, AChangedTextResizesTheDrawnCardWithoutRebuilding)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a", { { "pointsize", 10 } }) })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Mesh()->Dynamic());
    const auto  before_size  = Runtime().NodeSize("caption");
    const float before_width = PositionBox(*node->Mesh()).W();
    (void)Runtime().ConsumeSceneGraphMutationFlag();

    ASSERT_TRUE(Runtime().SetNodeText("caption", "aaaaaaaaaa"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    const auto after_size = Runtime().NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    const float after_width = PositionBox(*node->Mesh()).W();
    EXPECT_GT(after_width, before_width);
    EXPECT_NEAR(after_width, after_size.x(), 1.0f);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

// ---- J. bare registration ----------------------------------------------------------------

TEST_F(TextRuntimeBare, ARegisteredLayerReportsTheRuntimeRgbaBackend)
{
    Add("caption", Layer("layout only", 12.0f));
    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->render_backend, "runtime-rgba-texture");
}

TEST_F(TextRuntimeBare, LayersWithIdenticalTextFontAndSizeStillGetDistinctCacheKeys)
{
    Add("first", Layer("same", 12.0f));
    Add("second", Layer("same", 12.0f));
    const auto first  = State("first");
    const auto second = State("second");
    EXPECT_FALSE(first.texture_cache_key.empty());
    EXPECT_FALSE(second.texture_cache_key.empty());
    EXPECT_NE(first.texture_cache_key, second.texture_cache_key);
}

TEST_F(TextRuntimeBare, LayersWithDifferentTextGetDistinctCacheKeys)
{
    Add("first", Layer("one", 12.0f));
    Add("second", Layer("two", 12.0f));
    EXPECT_NE(State("first").texture_cache_key, State("second").texture_cache_key);
}
