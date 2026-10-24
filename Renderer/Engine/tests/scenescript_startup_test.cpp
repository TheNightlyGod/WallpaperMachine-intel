// How scripts start and what they find (item 4 of the SceneScript behaviour list): the order the
// first tick starts them in, what `init` returns, the names layers answer to, and sound objects
// as layers of the scene.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

namespace
{
using namespace we_test;

std::string ModelOf(ScenePackage& package) { return package.AddImageModel("plain"); }

// A layer whose alpha is driven by `source`. A script that exports no `update` drives nothing
// and is not attached to a setting, so one that has only handlers gets an empty `update`.
Json Scripted(const std::string& model, int id, const std::string& name, const std::string& source,
              const Json& properties = Json::object())
{
    const std::string text =
        source.find("export function update") == std::string::npos ? source + "\nexport function update() {}\n" : source;
    return PlainImage(model, id, name, { { "alpha", ScriptedValue(text, 1.0, properties) } });
}

} // namespace

// ---- the order scripts start in ----------------------------------------------------------

TEST(ScriptStartUp, EveryInitRunsBeforeAnyScriptIsToldTheUserPropertiesAndBeforeAnyUpdate)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   body  = [](const std::string& tag, const std::string& tail) {
        return Join({ "shared.log = shared.log || [];",
                      "var first = true;",
                      "export function init() { shared.log.push('i" + tag + "'); }",
                      "export function applyUserProperties() { shared.log.push('a" + tag + "'); }",
                      "export function update() {",
                      "  if (!first) return;",
                      "  first = false;",
                      "  shared.log.push('u" + tag + "');",
                      tail,
                      "}" });
    };
    const std::string report = Join({ "  thisScene.getLayer('probe').origin = new Vec3(",
                                      "    shared.log.join(' ') === 'iA iB iC aA aB aC uA uB uC' ? 1 : 0, shared.log.length, 0);" });
    Publish(package, { PlainImage(model, 1, "probe"), Scripted(model, 2, "A", body("A", "")),
                       Scripted(model, 3, "B", body("B", "")), Scripted(model, 4, "C", body("C", report)) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    const auto seen = scene.Origin("probe");
    EXPECT_EQ(seen[1], 9.0f) << "every handler ran once";
    EXPECT_EQ(seen[0], 1.0f) << "init, init, init, notices, notices, notices, update, update, update";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptStartUp, AnOptionsLayerMayCallWhatALaterLayersInitSetUpInItsFirstNotice)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   options = Join({ "export function applyUserProperties(props) {",
                                  "  shared.helper();",
                                  "  thisScene.getLayer('probe').origin = new Vec3(1, 0, 0);",
                                  "}" });
    const auto   provider = Join({ "export function init() {",
                                   "  shared.helper = function () { shared.helped = true; };",
                                   "}" });
    Publish(package, { PlainImage(model, 1, "probe"), Scripted(model, 2, "options", options),
                       Scripted(model, 3, "provider", provider) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 1.0f) << "the options layer finished its notice";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptStartUp, ScriptsStartOnTheFirstTickAndNotWhenTheSceneLoads)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "probe"), Scripted(model, 2, "late", "export function init() { thisScene.getLayer('probe').origin = new Vec3(5, 0, 0); }") });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_EQ(scene.Origin("probe")[0], 128.0f);
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 5.0f);
}

// ---- what init returns -------------------------------------------------------------------

TEST(ScriptInitResult, AHandleThatHidesItselfFromInitIsHidden)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "handle", { { "visible", ScriptedValue("export function init() { return false; }", true) } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(scene.Visible("handle"));
    scene.Tick(1);
    EXPECT_FALSE(scene.Visible("handle"));
    scene.Tick(5);
    EXPECT_FALSE(scene.Visible("handle"));
}

TEST(ScriptInitResult, InitConvertsItsResultAsUpdateDoes)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package,
            { PlainImage(model, 1, "vector", { { "scale", ScriptedValue("export function init() { return new Vec3(3, 4, 5); }", "1 1 1") } }),
              PlainImage(model, 2, "number", { { "scale", ScriptedValue("export function init() { return 2; }", "1 1 1") } }),
              PlainImage(model, 3, "angled", { { "angles", ScriptedValue("export function init() { return new Vec3(0, 0, 90); }", "0 0 0") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.Scale("vector"), (std::array<float, 3> { 3.0f, 4.0f, 5.0f }));
    EXPECT_EQ(scene.Scale("number"), (std::array<float, 3> { 2.0f, 2.0f, 2.0f })) << "a number fills every component";
    EXPECT_NEAR(scene.AnglesDegrees("angled")[2], 90.0f, 1e-3f) << "angles are written in degrees";
}

TEST(ScriptInitResult, NothingAnExceptionOrAnObjectForAFlagLeaveTheValueAlone)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package,
            { PlainImage(model, 1, "silent", { { "scale", ScriptedValue("export function init() { }", "2 2 2") } }),
              PlainImage(model, 2, "thrown", { { "scale", ScriptedValue("export function init() { throw new Error('no'); }", "2 2 2") } }),
              PlainImage(model, 3, "flag", { { "visible", ScriptedValue("export function init() { return { x: 1 }; }", true) } }),
              PlainImage(model, 4, "undefined", { { "scale", ScriptedValue("export function init() { return undefined; }\nexport function update() { }", "2 2 2") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_EQ(scene.Scale("silent"), (std::array<float, 3> { 2.0f, 2.0f, 2.0f }));
    EXPECT_EQ(scene.Scale("thrown"), (std::array<float, 3> { 2.0f, 2.0f, 2.0f }));
    EXPECT_EQ(scene.Scale("undefined"), (std::array<float, 3> { 2.0f, 2.0f, 2.0f }));
    EXPECT_TRUE(scene.Visible("flag"));
    // Only the script that threw reported anything.
    EXPECT_EQ(scene.ScriptErrors().size(), 1u) << Describe(scene.ScriptErrors());
}

// ---- layer names -------------------------------------------------------------------------

namespace
{
constexpr const char* kSeeNames = R"(
export function init() {
  var layers = thisScene.enumerateLayers();
  var names = layers.map(function (layer) { return layer.name; }).join('|');
  for (var i = 0; i < layers.length; ++i) {
    if (layers[i].name === 'twin') layers[i].origin = new Vec3(10 * (i + 1), 5, 0);
    if (layers[i].name === '') layers[i].origin = new Vec3(99, 99, 0);
  }
  thisScene.getLayer('probe').origin = new Vec3(names === 'probe|twin|twin||mover' ? 1 : 0, layers.length, 0);
}
)";

// A layer script that reads its own layer's name while it compiles and reports it on its scale.
std::string ReadsItsNameWhileCompiling(const std::string& expected)
{
    return Join({ "var mine = thisLayer.name;",
                  "export function update() {",
                  "  thisLayer.scale = new Vec3(mine === '" + expected + "' ? 1 : 0, 1, 1);",
                  "}" });
}
} // namespace

TEST(ScriptLayerNames, TwinsAndUnnamedLayersKeepTheirAuthoredNames)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    // Every layer has a script of its own; the mover's `init` finds the others by name.
    Publish(package, { PlainImage(model, 1, "probe"),
                       Scripted(model, 10, "twin", ReadsItsNameWhileCompiling("twin")),
                       Scripted(model, 11, "twin", ReadsItsNameWhileCompiling("twin")),
                       Scripted(model, 12, "", ReadsItsNameWhileCompiling("")),
                       Scripted(model, 13, "mover", kSeeNames) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 1.0f) << "the mover saw every layer under its authored name";
    EXPECT_EQ(scene.Origin("probe")[1], 5.0f);
    EXPECT_EQ(scene.Origin("__we_layer_10")[0], 20.0f);
    EXPECT_EQ(scene.Origin("__we_layer_11")[0], 30.0f);
    EXPECT_EQ(scene.Origin("__we_layer_12")[0], 99.0f);
    for (const char* key : { "__we_layer_10", "__we_layer_11", "__we_layer_12" }) {
        EXPECT_EQ(scene.Scale(key)[0], 1.0f) << key << " read its own authored name while it compiled";
    }
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_layer_10"), "twin");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_layer_11"), "twin");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_layer_12"), "");
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

namespace
{
Json TextLayer(int id, const std::string& name, const std::string& text, const std::string& source)
{
    return { { "id", id },
             { "name", name },
             { "origin", "100 50 0" },
             { "size", "100 30" },
             { "pointsize", 20 },
             { "text", { { "value", text }, { "script", source } } } };
}
} // namespace

TEST(ScriptLayerNames, TwinTextLayersEachWithAScriptKeepTheirNamesAndAreFoundByThem)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   own   = "var mine = thisLayer.name;\nexport function update(value) { return mine === 'caption' ? value : 'wrong name: ' + mine; }";
    const auto   mover = Join({ "export function init() {",
                                "  var layers = thisScene.enumerateLayers();",
                                "  var moved = 0;",
                                "  for (var i = 0; i < layers.length; ++i) {",
                                "    if (layers[i].name === 'caption') { layers[i].origin = new Vec3(10 * (moved + 1), 1, 0); moved += 1; }",
                                "  }",
                                "  thisScene.getLayer('probe').origin = new Vec3(moved, 0, 0);",
                                "}" });
    Publish(package, { PlainImage(model, 1, "probe"), TextLayer(5, "caption", "one", own), TextLayer(6, "caption", "two", own),
                       Scripted(model, 7, "mover", mover) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_EQ(scene.Origin("probe")[0], 2.0f) << "both captions were found by name";
    EXPECT_EQ(scene.Origin("__we_text_5")[0], 10.0f);
    EXPECT_EQ(scene.Origin("__we_text_6")[0], 20.0f);
    EXPECT_EQ(scene.runtime().NodeText("__we_text_5"), "one");
    EXPECT_EQ(scene.runtime().NodeText("__we_text_6"), "two");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_text_5"), "caption");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_text_6"), "caption");
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptInitResult, ATypingTextStartsEmpty)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   typing = Join({ "var full = 'Hello world';",
                                 "var typed = 0;",
                                 "export function init() { return ''; }",
                                 "export function update(value) { return value; }" });
    Publish(package, { PlainImage(model, 1, "probe"), TextLayer(5, "typing", "Hello world", typing) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_EQ(scene.runtime().NodeText("typing"), "");
}

TEST(ScriptInitResult, ATextThatInitLeavesAloneKeepsTheFilesText)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "probe"),
                       TextLayer(5, "caption", "Hello world", "export function init() { }\nexport function update(value) { return value; }") });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_EQ(scene.runtime().NodeText("caption"), "Hello world");
}

TEST(ScriptLayerNames, AScriptThatLooksALaterLayerUpWhileItCompilesFindsTheLayer)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    // The first layer's script reads two layers declared after it while it compiles.
    const auto early = Join({ "var later = thisScene.getLayer('later');",
                              "var twin = thisScene.getLayer('twin');",
                              "export function update() {",
                              "  later.origin = new Vec3(7, 7, 0);",
                              "  twin.origin = new Vec3(8, 8, 0);",
                              "}" });
    Publish(package, { Scripted(model, 1, "early", early), PlainImage(model, 2, "later"),
                       PlainImage(model, 3, "twin"), PlainImage(model, 4, "twin") });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("later")[0], 7.0f);
    // A shared name answers with the first layer that carries it.
    EXPECT_EQ(scene.Origin("__we_layer_3")[0], 8.0f);
    EXPECT_EQ(scene.Origin("__we_layer_4")[0], 128.0f);
}

TEST(ScriptLayerNames, UnregisteringALayerForgetsItsName)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "twin"), PlainImage(model, 2, "twin") });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_EQ(scene.runtime().LayerAuthoredName("__we_layer_1"), "twin");
    scene.runtime().UnregisterNode("__we_layer_1");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_layer_1"), "__we_layer_1");
    EXPECT_EQ(scene.runtime().LayerAuthoredName("__we_layer_2"), "twin");
}

// ---- sound layers ------------------------------------------------------------------------

namespace
{
Json SoundObject(int id, const std::string& name, const std::string& file)
{
    return { { "id", id },
             { "name", name },
             { "sound", Json::array({ file }) },
             { "playbackmode", "loop" },
             { "startsilent", true },
             { "volume", 1.0 } };
}
} // namespace

class ScriptSoundLayers : public ::testing::Test {
protected:
    void SetUp() override
    {
        model_ = ModelOf(package_);
        package_.Put("sounds/note.wav", MakeWav());
    }
    ScenePackage package_;
    std::string  model_;
};

TEST_F(ScriptSoundLayers, SoundObjectsAreLayersInTheScenesOrder)
{
    const auto source = Join({ "export function init() {",
                               "  var layers = thisScene.enumerateLayers();",
                               "  var names = layers.map(function (l) { return l.name; }).join('|');",
                               "  var byId = thisScene.getLayerByID(21);",
                               "  thisScene.getLayer('probe').origin = new Vec3(",
                               "    names === 'probe|first|second|effect|checker' ? 1 : 0,",
                               "    thisScene.getLayerCount(),",
                               "    byId !== null && thisScene.getLayerIndex(byId) === 2 ? 1 : 0);",
                               "}" });
    Publish(package_, { PlainImage(model_, 1, "probe"), SoundObject(20, "first", "sounds/note.wav"),
                        SoundObject(21, "second", "sounds/note.wav"), SoundObject(22, "effect", "sounds/note.wav"),
                        Scripted(model_, 23, "checker", source) });

    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 1.0f) << "listed in order, by their authored names";
    EXPECT_EQ(scene.Origin("probe")[1], 5.0f) << "counted";
    EXPECT_EQ(scene.Origin("probe")[2], 1.0f) << "found by id, and indexed";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST_F(ScriptSoundLayers, ALayerObjectPlaysAndStopsItsSound)
{
    const auto source = Join({ "var ticks = 0;",
                               "export function update() {",
                               "  ticks += 1;",
                               "  var sound = thisScene.getLayer('effect');",
                               "  if (ticks === 1) sound.play();",
                               "  if (ticks === 3) sound.stop();",
                               "}" });
    Publish(package_, { SoundObject(22, "effect", "sounds/note.wav"), Scripted(model_, 23, "driver", source) });

    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_FALSE(scene.runtime().SoundLayerPlaying("effect"));
    scene.Tick(1);
    EXPECT_TRUE(scene.runtime().SoundLayerPlaying("effect"));
    scene.Tick(2);
    EXPECT_FALSE(scene.runtime().SoundLayerPlaying("effect"));
}

TEST_F(ScriptSoundLayers, TwoSoundLayersThatShareANameArePlayedSeparately)
{
    const auto source = Join({ "export function init() {",
                               "  var layers = thisScene.enumerateLayers();",
                               "  var twins = layers.filter(function (l) { return l.name === 'music'; });",
                               "  thisScene.getLayer('probe').origin = new Vec3(twins.length, 0, 0);",
                               "  twins[1].play();",
                               "}" });
    Publish(package_, { PlainImage(model_, 1, "probe"), SoundObject(30, "music", "sounds/note.wav"),
                        SoundObject(31, "music", "sounds/note.wav"), Scripted(model_, 32, "driver", source) });

    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 2.0f);
    EXPECT_FALSE(scene.runtime().SoundLayerPlaying("__we_layer_30"));
    EXPECT_TRUE(scene.runtime().SoundLayerPlaying("__we_layer_31"));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST_F(ScriptSoundLayers, AWidgetThatFindsItsTracksByANamePatternFindsThem)
{
    const auto source = Join({ "export function init() {",
                               "  var found = 0;",
                               "  var layers = thisScene.enumerateLayers();",
                               "  for (var i = 0; i < layers.length; ++i) {",
                               "    if (layers[i].name.indexOf('track') === 0) { found += 1; layers[i].play(); }",
                               "  }",
                               "  thisScene.getLayer('probe').origin = new Vec3(found, 0, 0);",
                               "}" });
    Publish(package_, { PlainImage(model_, 1, "probe"), SoundObject(40, "track 1", "sounds/note.wav"),
                        SoundObject(41, "track 2", "sounds/note.wav"), SoundObject(42, "other", "sounds/note.wav"),
                        Scripted(model_, 43, "finder", source) });

    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(1);
    EXPECT_EQ(scene.Origin("probe")[0], 2.0f);
    EXPECT_TRUE(scene.runtime().SoundLayerPlaying("track 1"));
    EXPECT_TRUE(scene.runtime().SoundLayerPlaying("track 2"));
    EXPECT_FALSE(scene.runtime().SoundLayerPlaying("other"));
}

TEST_F(ScriptSoundLayers, ASoundThatIsNeverBuiltHasNoIndex)
{
    Json hidden = SoundObject(50, "silent", "sounds/note.wav");
    hidden["visible"] = false;
    Publish(package_, { PlainImage(model_, 1, "probe"), hidden, SoundObject(51, "heard", "sounds/note.wav") });

    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_EQ(scene.runtime().LayerCount(), 2u);
    EXPECT_EQ(scene.runtime().LayerIndex("silent"), -1);
    EXPECT_EQ(scene.runtime().LayerIndex("heard"), 1);
    EXPECT_EQ(scene.runtime().LayerNameForId(50), "");
}


