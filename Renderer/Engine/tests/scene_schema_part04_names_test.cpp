// Scene file schema, part 4: how layers are named at run time and scripted. Layers sharing an
// authored name get id-based runtime names, name lookups go to the first declaration, entries that
// are not layers are skipped without disturbing that, a click script on duplicate buttons toggles
// its group once per click, and a layer hidden in the file follows its visibility script.
#include "support/schema_fixtures_part03.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p3;
using namespace wallpaper;

constexpr const char* kAlwaysVisible = "export function update(value) { return value; }";

Json SmallCanvas(Json objects)
{
    return QuietScene(std::move(objects), { { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } });
}

Json Plain(int id, const std::string& name, const Json& extra = Json::object())
{
    Json layer = { { "id", id }, { "name", name } };
    for (const auto& [key, value] : extra.items()) layer[key] = value;
    return layer;
}

Json Sized(int id, const std::string& name, const Json& extra = Json::object())
{
    Json layer = { { "id", id }, { "name", name }, { "image", "image.json" }, { "size", Json::array({ 64, 32 }) }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) layer[key] = value;
    return layer;
}

// ---- layers that share a name ------------------------------------------------------------------

// R-4.07 / B-4.11
TEST(DuplicateLayerNames, TwoPlainLayersWithOneNameGetIdBasedRuntimeNames)
{
    ParseRig rig(BasicAssets());
    const Json visible = { { "value", true }, { "script", kAlwaysVisible } };
    auto       scene   = rig.Parse(SmallCanvas(Json::array({ Plain(10, "tap target", { { "origin", Json::array({ 100, 150, 0 }) }, { "visible", visible } }),
                                                           Plain(11, "tap target", { { "origin", Json::array({ 300, 150, 0 }) }, { "visible", visible } }) })),
                             { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_10"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_11"));
}

// R-4.08 / B-4.12
TEST(DuplicateLayerNames, TwoImageLayersWithOneNameLikewiseAndKeepTheirSizes)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(SmallCanvas(Json::array({ Sized(20, "tap target", { { "origin", Json::array({ 100, 150, 0 }) } }),
                                                       Sized(21, "tap target", { { "origin", Json::array({ 300, 150, 0 }) } }) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    ASSERT_TRUE(scene->runtime->HasNodeNamed("__we_layer_20"));
    ASSERT_TRUE(scene->runtime->HasNodeNamed("__we_layer_21"));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_20"), linalg::Vector2f(64, 32));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_21"), linalg::Vector2f(64, 32));
}

TEST(DuplicateLayerNames, AUniqueNameIsKeptAnEmptyNameIsIdBasedAndAnObjectWithoutIdIsNotBuilt)
{
    ParseRig rig(BasicAssets());
    Json     no_id = Sized(0, "no id");
    no_id.erase("id");
    auto scene = rig.Parse(SmallCanvas(Json::array({ Sized(20, "only one"), Sized(21, ""), no_id })), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->HasNodeNamed("only one"));
    EXPECT_FALSE(scene->runtime->HasNodeNamed("__we_layer_20"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_21"));
    EXPECT_FALSE(scene->runtime->HasNodeNamed("no id"));
}

// A driver that sits before the layers it addresses, and sets the scale of the first layer called
// "image first" and of the first called "group first".
Json DriverLayer(int id, const std::string& name = "driver")
{
    const std::string script = "const first = thisScene.getLayer('shared');\n"
                               "export function update(value) { first.scale = new Vec3(0.125); return value; }\n";
    return Plain(id, name, { { "origin", { { "value", Json::array({ 0, 0, 0 }) }, { "script", script } } } });
}

// R-4.09 / B-4.13
TEST(LayerNameLookup, BindingsStayWithTheirLayerWhileANameResolvesToTheFirstDeclaration)
{
    const std::string driver_script = "const image = thisScene.getLayer('image first');\n"
                                      "const group = thisScene.getLayer('group first');\n"
                                      "export function update(value) {\n"
                                      "  image.scale = new Vec3(0.125);\n"
                                      "  group.scale = new Vec3(0.25);\n"
                                      "  return value;\n"
                                      "}\n";
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(SmallCanvas(Json::array({
                               Plain(30, "driver", { { "origin", { { "value", Json::array({ 0, 0, 0 }) }, { "script", driver_script } } } }),
                               Sized(10, "image first"),
                               Plain(11, "image first", { { "visible", { { "value", true }, { "script", "export function update(value) { thisLayer.scale = new Vec3(9); return value; }" } } } }),
                               Plain(20, "group first"),
                               Sized(21, "group first", { { "visible", { { "value", true }, { "script", "export function update(value) { thisLayer.scale = new Vec3(7); return value; }" } } } }),
                           })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int tick = 0; tick < 3; ++tick) {
        SCOPED_TRACE("tick " + std::to_string(tick + 1));
        scene->runtime->Tick(1.0 / 60.0);
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_10"), linalg::Vector3f::Constant(0.125f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_11"), linalg::Vector3f::Constant(9.0f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_20"), linalg::Vector3f::Constant(0.25f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_21"), linalg::Vector3f::Constant(7.0f));
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

// R-4.09 / B-4.14
TEST(LayerNameLookup, WithoutAPropertyTableThereIsNoRuntime)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(SmallCanvas(Json::array({ DriverLayer(30), Sized(10, "shared"), Sized(11, "shared") })));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->runtime, nullptr);
}

// R-4.10 / B-4.15
class MalformedObjectEntries : public ::testing::TestWithParam<int> {};

Json MalformedEntry(int which)
{
    switch (which) {
    case 0: return nullptr;
    case 1: return 7;
    case 2: return Json::array();
    case 3: return { { "id", 30 }, { "name", 7 } };
    case 4: return { { "id", 30 }, { "name", nullptr } };
    case 5: return { { "id", "invalid" }, { "name", "shared" } };
    case 6: return { { "id", nullptr }, { "name", "shared" } };
    case 7: return { { "name", "shared" } };
    default: return { { "id", 31 } };
    }
}

TEST_P(MalformedObjectEntries, AreIgnoredWithoutDisturbingNameResolution)
{
    ParseRig  rig(BasicAssets());
    const Json scene_json = SmallCanvas(Json::array({ MalformedEntry(GetParam()), Plain(10, "shared"), Plain(11, "shared"), DriverLayer(20) }));
    std::shared_ptr<Scene> scene;
    ASSERT_NO_THROW(scene = rig.Parse(scene_json, { .live = true }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->ResolveLayerName("shared"), "__we_layer_10");
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(scene->runtime->NodeScale("__we_layer_10"), linalg::Vector3f::Constant(0.125f));
    EXPECT_EQ(scene->runtime->NodeScale("__we_layer_11"), linalg::Vector3f::Ones());
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

std::string MalformedName(const ::testing::TestParamInfo<int>& info)
{
    static const char* const names[] = { "Null", "Number", "EmptyArray", "NameIsANumber", "NameIsNull", "IdIsAString", "IdIsNull", "NoId", "NoName" };
    return names[info.param];
}

INSTANTIATE_TEST_SUITE_P(Entries, MalformedObjectEntries, ::testing::Range(0, 9), MalformedName);

// ---- clicks on duplicate buttons ---------------------------------------------------------------

// R-4.11 / B-4.16
TEST(ScriptedVisibility, ACallbackOnlyScriptOnDuplicateButtonsTogglesItsGroupOncePerClick)
{
    const std::string script = "export var scriptProperties = createScriptProperties()\n"
                               "  .addText({ name: 'target', label: 'target', value: 'missing' })\n"
                               "  .finish();\n"
                               "let visible;\n"
                               "export function init(value) { visible = true; return value; }\n"
                               "export function cursorClick() {\n"
                               "  visible = !visible;\n"
                               "  thisScene.getLayer(scriptProperties.target).visible = visible;\n"
                               "}\n";
    const Json setting = { { "value", true }, { "script", script }, { "scriptproperties", { { "target", "mode" } } } };

    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(SmallCanvas(Json::array({
                               Plain(1, "mode", { { "visible", true } }),
                               Sized(2, "content", { { "parent", 1 } }),
                               Sized(3, "button", { { "origin", Json::array({ 200, 150, 0 }) }, { "size", Json::array({ 80, 80 }) }, { "visible", setting } }),
                               Sized(4, "button", { { "parent", 3 }, { "scale", Json::array({ 0.9, 0.9, 1 }) }, { "size", Json::array({ 80, 80 }) }, { "visible", setting } }),
                           })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& runtime = *scene->runtime;

    runtime.Tick(0.01);
    runtime.SetCursorInput(0.5f, 0.5f);
    runtime.SetCursorEnter(true);
    for (const bool expected : { false, true, false }) {
        SCOPED_TRACE(expected ? "second click" : "first or third click");
        runtime.SetCursorButtons(0, 1, 1);
        runtime.DispatchCursorFrameEvents(true);
        runtime.SetCursorButtons(0, 0, 0);
        runtime.Tick(0.01);
        EXPECT_EQ(runtime.NodeVisible("mode"), expected);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// ---- layers hidden in the file ---------------------------------------------------------------

std::string VisibilityScript(const std::string& property)
{
    return "let on = false;\n"
           "export function applyUserProperties(changed) {\n"
           "  if (Object.prototype.hasOwnProperty.call(changed, '" + property + "')) on = changed['" + property + "'];\n"
           "}\n"
           "export function update() { return on; }\n";
}

Json HiddenByDefault(const std::string& property) { return { { "value", false }, { "script", VisibilityScript(property) } }; }

struct HiddenRow {
    bool first;
    bool second;
};

class HiddenLayerWithVisibilityScript : public ::testing::TestWithParam<HiddenRow> {};

// R-4.12 / B-4.17
TEST_P(HiddenLayerWithVisibilityScript, FollowsTheScriptInsteadOfBeingDropped)
{
    const HiddenRow row = GetParam();
    ParseRig        rig(BasicAssets());
    rig.properties() = ProjectProperties { { "show_first", RuntimeScalarValue::Bool(row.first) }, { "show_second", RuntimeScalarValue::Bool(row.second) } };
    auto scene = rig.Parse(SmallCanvas(Json::array({
                               Sized(11, "shown by script", { { "size", Json::array({ 80, 60 }) },
                                                              { "origin", { { "value", Json::array({ 0, 0, 0 }) }, { "script", "export function update() { return new Vec3(30, 0, 0); }" } } },
                                                              { "visible", HiddenByDefault("show_first") } }),
                               Sized(12, "hidden by script", { { "size", Json::array({ 80, 60 }) }, { "visible", HiddenByDefault("show_second") } }),
                           })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(0.01);

    SceneNode* first = FindRootChild(*scene, "shown by script");
    ASSERT_NE(first, nullptr);
    EXPECT_EQ(first->Visible(), row.first);
    EXPECT_FLOAT_EQ(first->Translate().x(), 30.0f);
    SceneNode* second = FindRootChild(*scene, "hidden by script");
    ASSERT_NE(second, nullptr) << "a layer hidden by default must not be dropped when a script can show it";
    EXPECT_EQ(second->Visible(), row.second);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

const HiddenRow kHiddenRows[] = { { true, false }, { false, true }, { true, true }, { false, false } };

std::string HiddenName(const ::testing::TestParamInfo<HiddenRow>& info)
{
    return std::string(info.param.first ? "FirstShown" : "FirstHidden") + (info.param.second ? "SecondShown" : "SecondHidden");
}

INSTANTIATE_TEST_SUITE_P(Properties, HiddenLayerWithVisibilityScript, ::testing::ValuesIn(kHiddenRows), HiddenName);

TEST(HiddenLayerWithoutScript, IsNotBuilt)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(SmallCanvas(Json::array({ Sized(11, "plain hidden", { { "visible", false } }), Sized(12, "shown") })), { .live = true });
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(FindRootChild(*scene, "plain hidden"), nullptr);
    EXPECT_NE(FindRootChild(*scene, "shown"), nullptr);
}

} // namespace
