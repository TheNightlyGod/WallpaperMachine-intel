// What a property script's `thisObject` is (item 3 of the SceneScript behaviour list): the effect
// whose visibility the script decides, and the animation of the keyed setting the script sits on.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"

#include <gtest/gtest.h>
#include <fstream>

namespace
{
using namespace we_test;

std::string ModelOf(ScenePackage& package) { return package.AddImageModel("plain"); }

// An effect use whose visibility `source` decides.
Json ScriptedEffect(const std::string& effect_file, const std::string& source, bool initial = true)
{
    Json use = EffectUse(effect_file);
    use["visible"] = ScriptedValue(source, initial);
    return use;
}

constexpr const char* kPlaying = R"({"type":"mediaPlaybackChanged","state":1})";
constexpr const char* kStopped = R"({"type":"mediaPlaybackChanged","state":0})";

} // namespace

// ---- thisObject of an effect visibility script ------------------------------------------

TEST(ScriptEffectObject, WritingVisibleFromInitSwitchesTheEffectAndLeavesTheLayer)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    Publish(package, { PlainImage(model, 1, "cover", {},
                                  { ScriptedEffect(effect, "export function init() { thisObject.visible = false; }") }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { false });
    EXPECT_TRUE(scene.Visible("cover")) << "the layer is not the script's to hide";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptEffectObject, WritingVisibleFromAMediaHandlerSwitchesTheEffectAndLeavesTheLayer)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    const auto   source = Join({ "export function mediaPlaybackChanged(event) {",
                                 "  thisObject.visible = event.state === 1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, source) }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    // Without a player the scene hears nothing, so the effect stays as authored.
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });
    scene.runtime().SetMediaIntegrationEnabled(true);
    scene.runtime().DispatchMediaEventJson(kPlaying);
    scene.Tick();
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });
    scene.runtime().DispatchMediaEventJson(kStopped);
    scene.Tick();
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { false });
    EXPECT_TRUE(scene.Visible("cover"));
    scene.runtime().DispatchMediaEventJson(kPlaying);
    scene.Tick();
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });
    EXPECT_TRUE(scene.Visible("cover"));
}

TEST(ScriptEffectObject, WritingVisibleFromUpdateSwitchesTheEffect)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    const auto   source = Join({ "var ticks = 0;",
                                 "export function update() {",
                                 "  ticks += 1;",
                                 "  thisObject.visible = ticks < 3;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, source) }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });
    scene.Tick(3);
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { false });
    EXPECT_TRUE(scene.Visible("cover"));
}

TEST(ScriptEffectObject, AnEffectScriptDoesNotShowALayerAPropertyHid)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    // The effect is hidden by the script; the layer by the property; neither undoes the other.
    Publish(package,
            { PlainImage(model, 1, "cover", { { "visible", PropertyBinding("shown", false) } },
                         { ScriptedEffect(effect, "export function init() { thisObject.visible = true; }", false) }) },
            { { "shown", BoolProperty(false) } });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_FALSE(scene.Visible("cover")) << "the property that hid the layer still decides";
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });

    ASSERT_TRUE(scene.SetProperty("shown", true));
    scene.Tick();
    EXPECT_TRUE(scene.Visible("cover"));
    EXPECT_EQ(scene.EffectVisibility(), std::vector<bool> { true });
}

TEST(ScriptEffectObject, ASecondEffectIsNotTheOneTheScriptSwitches)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    Publish(package, { PlainImage(model, 1, "cover", {},
                                  { EffectUse(effect),
                                    ScriptedEffect(effect, "export function init() { thisObject.visible = false; }") }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.EffectVisibility(), (std::vector<bool> { true, false }));
}

// ---- thisObject of a script on a keyed setting -------------------------------------------

TEST(ScriptEffectObject, GetEffectByNameAnswersTheLastOfTwins)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    Json first = EffectUse(effect), last = EffectUse(effect);
    first["name"] = last["name"] = "twins";
    first["visible"] = ScriptedValue(
        "export function init(value) { thisLayer.getEffect('twins').visible = false; return value; }", true);
    Publish(package, { PlainImage(model, 1, "cover", {}, { first, last }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.EffectVisibility(), (std::vector<bool> { true, false }));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptEffectObject, WritingOriginOnAnEffectLeavesTheLayer)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    Publish(package, { PlainImage(model, 1, "cover", {}, {
        ScriptedEffect(effect, "export function init(value) { thisObject.origin = new Vec3(9,9,9); return value; }") }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.Origin("cover"), (std::array<float, 3> { 128, 72, 0 }));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptEffectObject, AnUnnamedInstanceDoesNotBorrowTheEffectFileTitle)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, R"JS(
export function init(value) {
  if (thisObject.name !== '' || thisLayer.getEffect('probe_effect') !== null || thisLayer.getEffect('') !== null)
    throw new Error('unnamed effects do not use the file title as a script name');
  return value;
}
)JS") }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptEffectObject, GetMaterialByNameAndEmptyString)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    const Json material = Json::parse(std::ifstream(package.root() / "materials/probe_effect.json"));
    package.PutJson("materials/second.json", material);
    package.PutJson(effect, { { "name", "two passes" }, { "passes", Json::array({
        { { "material", "materials/probe_effect.json" } }, { { "material", "materials/second.json" } } }) } });
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, R"JS(
export function init(value) {
  var fx = thisObject;
  if (fx.getMaterial('materials/probe_effect.json') !== fx.getMaterial(0) ||
      fx.getMaterial('materials/second.json') !== fx.getMaterial(1) ||
      fx.getMaterial('') !== fx.getMaterial(1) || fx.getMaterial('missing') !== null)
    throw new Error('material lookup did not resolve the pass');
  fx.getMaterial('materials/probe_effect.json').setConstant('flag', 7);
  return value;
}
)JS") }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.EffectConstant(0, "g_Flag"), (std::vector<float> { 7 }));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptEffectObject, ExecuteMaterialFunctionQueuesTheClear)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    package.PutJson(effect, {
        { "name", "clear function" },
        { "fbos", Json::array({
            { { "name", "_rt_First" }, { "format", "rgba8888" }, { "clear", "0.25 0.5 0.75 1" } },
            { { "name", "_rt_Second" }, { "format", "rgba8888" } } }) },
        { "functions", { { "clearSecond", { { "action", "clear" }, { "fbos", Json::array({ "_rt_Second" }) } } } } },
        { "passes", Json::array({ { { "material", "materials/probe_effect.json" } } }) } });
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, R"JS(
export function init(value) {
  thisObject.executeMaterialFunction('missing');
  thisObject.executeMaterialFunction('clearSecond');
  return value;
}
)JS") }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    ASSERT_EQ(scene.scene().pending_effect_clears.size(), 1u);
    EXPECT_EQ(scene.scene().pending_effect_clears.front().color, (std::array<float, 4> { 0.25f, 0.5f, 0.75f, 1 }));
}

TEST(ScriptEffectObject, SetMaterialPropertyConvertsDegreesAndWritesVectors)
{
    ScenePackage package;
    const auto model = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    package.PutJson(effect, { { "name", "two property passes" }, { "passes", Json::array({
        { { "material", "materials/probe_effect.json" } }, { { "material", "materials/probe_effect.json" } } }) } });
    package.AddShader("harness_probe", StandardVertexShader(), R"GLSL(
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec3 g_Tint; // {"material":"tint","default":"1 1 1"}
uniform vec2 g_Pair; // {"material":"pair","default":"0 0"}
uniform float g_Dir; // {"material":"dir","default":0,"conversion":"rad2deg"}
uniform int g_Count; // {"material":"count","default":0}
void main() { gl_FragColor = vec4(g_Tint + vec3(g_Pair, g_Dir + float(g_Count)), 1.0); }
)GLSL");
    Publish(package, { PlainImage(model, 1, "cover", {}, { ScriptedEffect(effect, R"JS(
export function init(value) {
  thisObject.setMaterialProperty('dir', 180);
  thisObject.setMaterialProperty('count', -2.7);
  thisObject.setMaterialProperty('tint', new Vec3(0.2, 0.4, 0.6));
  thisObject.setMaterialProperty('pair', new Vec2(-1, 2));
  thisObject.setMaterialProperty('missing', 9);
  return value;
}
)JS") }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    const auto direction = scene.EffectConstant(0, "g_Dir");
    ASSERT_EQ(direction.size(), 1u);
    EXPECT_NEAR(direction[0], kPi, 1e-6);
    // Material aliases retain float storage even when their shader declares int;
    // WE's constant buffer also receives the float's raw bits in that case.
    EXPECT_EQ(scene.EffectConstant(0, "g_Count"), (std::vector<float> { -2.7f }));
    EXPECT_EQ(scene.EffectConstant(0, "g_Tint"), (std::vector<float> { 0.2f, 0.4f, 0.6f }));
    EXPECT_EQ(scene.EffectConstant(0, "g_Pair"), (std::vector<float> { -1, 2 }));
    EXPECT_EQ(scene.EffectConstant(0, "g_Dir", 1), direction);
    EXPECT_EQ(scene.EffectConstant(0, "g_Tint", 1), (std::vector<float> { 0.2f, 0.4f, 0.6f }));
}

namespace
{
// A layer whose origin slides on an animation the layer's own scripts may reach, and whose
// effect has a keyed shader constant driven by `source`.
struct SlidingLayer {
    explicit SlidingLayer(ScenePackage& package, const std::string& source, const std::string& origin_name,
                          bool keyed_constant = true)
    {
        const auto model  = ModelOf(package);
        const auto effect = AddProbeEffect(package);
        Json       tint   = ScriptedValue(source, "0 0 0");
        if (keyed_constant) tint["animation"] = Keyed({ 0, 0, 0 }, { 60, 60, 60 });
        Json origin = { { "value", "100 72 0" }, { "animation", Keyed({ 100, 72, 0 }, { 200, 72, 0 }, origin_name) } };
        Publish(package, { PlainImage(model, 1, "slider", { { "origin", origin } },
                                      { EffectUse(effect, { { "tint", tint } }) }) });
    }
};
} // namespace

TEST(ScriptKeyedSettingObject, GetAnimationWithoutANameIsTheSettingsOwnAnimation)
{
    ScenePackage package;
    const auto   source = Join({ "export function init() { thisObject.getAnimation().play(); }",
                                 "export function update() { return thisObject.getAnimation().getFrame(); }" });
    SlidingLayer layer(package, source, "");

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(21);
    const auto tint = scene.EffectConstant(0, "g_Tint");
    ASSERT_EQ(tint.size(), 3u);
    // 30 fps on a 1/60 s tick: half a frame per tick, from the tick after the script started it.
    EXPECT_NEAR(tint[0], 10.0f, 0.51f);
    EXPECT_EQ(tint[0], tint[1]);
    EXPECT_EQ(tint[0], tint[2]);
    // The layer's own slide was not the animation the script played.
    EXPECT_FLOAT_EQ(scene.Origin("slider")[0], 100.0f);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptKeyedSettingObject, ANamedLookupStillFindsTheLayersAnimationByName)
{
    ScenePackage package;
    const auto   source = Join({ "export function init() { thisObject.getAnimation('slide').play(); }",
                                 "export function update() { return thisObject.getAnimation().getFrame(); }" });
    SlidingLayer layer(package, source, "slide");

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(21);
    EXPECT_GT(scene.Origin("slider")[0], 100.0f) << "the named slide plays";
    // The constant's own clock was never started.
    const auto tint = scene.EffectConstant(0, "g_Tint");
    ASSERT_EQ(tint.size(), 3u);
    EXPECT_FLOAT_EQ(tint[0], 0.0f);
}

TEST(ScriptKeyedSettingObject, ASettingWithoutAnAnimationFindsTheLayersFirstUnnamedOne)
{
    ScenePackage package;
    const auto   source = Join({ "export function init() { thisObject.getAnimation().play(); }",
                                 "export function update(value) { return value; }" });
    SlidingLayer layer(package, source, "", false);

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(21);
    EXPECT_GT(scene.Origin("slider")[0], 100.0f) << "the layer's unnamed animation plays";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

// ---- writable layer names (setter 0x1401A4D00, decompiles/A-7e.md) --------------------------

TEST(ScriptLayerNames, ARenamedLayerIsFoundByItsNewNameOnly)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   source = Join({ "var done = false, results = [0, 0, 0];",
                                 "export function update(value) {",
                                 "  if (!done) {",
                                 "    done = true;",
                                 "    var a = thisScene.getLayer('a'), b = thisScene.getLayer('b');",
                                 "    a.name = 'renamed';",
                                 "    results[0] = thisScene.getLayer('renamed') === a && thisScene.getLayer('a') !== a &&",
                                 "                 a.name === 'renamed' ? 1 : 0;",
                                 "    b.name = 'renamed';",
                                 "    results[1] = thisScene.getLayer('renamed') === a && b.name === 'renamed' ? 1 : 0;",
                                 "    a.name = 'a';",
                                 "    results[2] = thisScene.getLayer('a') === a && thisScene.getLayer('renamed') === b ? 1 : 0;",
                                 "  }",
                                 "  thisLayer.origin = new Vec3(results[0], results[1], results[2]);",
                                 "  return 1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "a"), PlainImage(model, 2, "b"),
                       PlainImage(model, 3, "driver", { { "alpha", ScriptedValue(source, 1.0) } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    const auto origin = scene.Origin("driver");
    EXPECT_FLOAT_EQ(origin[0], 1.0f) << "found by the new name, not the old";
    EXPECT_FLOAT_EQ(origin[1], 1.0f) << "the first layer in order with a name wins";
    EXPECT_FLOAT_EQ(origin[2], 1.0f) << "renaming back";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

namespace
{
// A layer whose effect's `flag` constant is keyed from 1 down to 0 (start-paused, played once)
// and carries `source`, a script that exports no `update`.
void KeyedFlagLayer(ScenePackage& package, const std::string& source)
{
    const auto model  = ModelOf(package);
    const auto effect = AddProbeEffect(package);
    Json       flag   = ScriptedValue(source, 0.0);
    Json       keyed  = Keyed({ 1 }, { 0 });
    keyed["options"]["mode"] = "single";
    flag["animation"]        = keyed;
    Publish(package, { PlainImage(model, 1, "cover", {}, { EffectUse(effect, { { "flag", flag } }) }) });
}
} // namespace

TEST(ScriptKeyedSettingObject, AHandlerOnlyScriptPlaysTheConstantsOwnTimeline)
{
    // A cover cross-fade: the blend amount rests on its first key and a new cover plays it
    // down to the last. The script exports no `update`, so the timeline stays the value and
    // the script only starts it.
    ScenePackage package;
    KeyedFlagLayer(package, Join({ "export function mediaThumbnailChanged(event) {",
                                   "  thisObject.getAnimation().play();",
                                   "}" }));

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_FLOAT_EQ(scene.EffectConstant(0, "g_Flag").at(0), 1.0f) << "start-paused on its first key";
    scene.runtime().SetMediaIntegrationEnabled(true);
    scene.runtime().DispatchMediaEventJson(
        R"({"type":"mediaThumbnailChanged","hasThumbnail":true,"primaryColor":[1,0,0]})");
    // 30 fps on a 1/60 s tick: half a frame per tick, from the tick after the handler ran.
    scene.Tick(61);
    EXPECT_NEAR(scene.EffectConstant(0, "g_Flag").at(0), 0.5f, 0.02f) << "halfway along the curve";
    scene.Tick(120);
    EXPECT_FLOAT_EQ(scene.EffectConstant(0, "g_Flag").at(0), 0.0f) << "held on its last key";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptKeyedSettingObject, AnInitOnlyScriptPlaysTheConstantsOwnTimeline)
{
    // Wallpaper Engine 2.8 draws a probe opacity keyed this way at its last key, and at its
    // first without the script (captured 2026-10-30).
    ScenePackage package;
    KeyedFlagLayer(package, "export function init() { thisObject.getAnimation().play(); }");

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(61);
    EXPECT_NEAR(scene.EffectConstant(0, "g_Flag").at(0), 0.5f, 0.02f);
    scene.Tick(120);
    EXPECT_FLOAT_EQ(scene.EffectConstant(0, "g_Flag").at(0), 0.0f);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}
