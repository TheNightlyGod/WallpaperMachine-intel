// Scene file schema, part 8: what scripts can ask the scene for (the layer registry, the object
// list), the layers they make, how the scene is torn down, and the bound on JSON nesting.
//
// Scripts here check their own surroundings and throw when something is off; because a script
// that never ran would leave the error list just as empty, every such test also asserts what the
// C++ side holds.
#include "support/schema_fixtures.hpp"

#include "Fs/MemBinaryStream.h"
#include "Runtime/RuntimeImageSource.hpp"
#include "Text/TextLayer.hpp"
#include "Utils/Logging.h"
#include "WPSceneParser.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

Json V3(double x, double y, double z) { return Json::array({ x, y, z }); }

// The scene every test of this part parses: black, no parallax, a 640x360 canvas looking down -z.
Json Document(Json objects)
{
    Json scene = QuietScene(std::move(objects), { { "ambientcolor", V3(0, 0, 0) }, { "skylightcolor", V3(0, 0, 0) }, { "bloom", false } });
    scene["camera"] = { { "center", V3(0, 0, -1) }, { "eye", V3(0, 0, 0) }, { "up", V3(0, 1, 0) } };
    return scene;
}

// ---- error log capture ----------------------------------------------------------------------

std::mutex               g_log_mutex;
std::vector<std::string> g_errors;

void CaptureError(int level, const char*, int, const char* message)
{
    if (level != LOGLEVEL_ERROR) return;
    std::lock_guard lock(g_log_mutex);
    g_errors.emplace_back(message);
}

// Keeps the process-wide log sink pointed at `CaptureError` for its lifetime.
class ErrorLog {
public:
    ErrorLog()
    {
        {
            std::lock_guard lock(g_log_mutex);
            g_errors.clear();
        }
        SetWallpaperLogCallback(&CaptureError);
    }
    ~ErrorLog() { SetWallpaperLogCallback(nullptr); }
    ErrorLog(const ErrorLog&)            = delete;
    ErrorLog& operator=(const ErrorLog&) = delete;

    static std::vector<std::string> Lines()
    {
        std::lock_guard lock(g_log_mutex);
        return g_errors;
    }
    static std::size_t Count(const std::string& needle)
    {
        std::size_t count = 0;
        for (const std::string& line : Lines()) count += line.find(needle) != std::string::npos ? 1 : 0;
        return count;
    }
};

// ---- the rig ---------------------------------------------------------------------------------

class Played {
public:
    Played(const Json& objects, FileMap assets = BasicAssets(), bool tick = true) : rig_(std::move(assets))
    {
        scene_ = rig_.Parse(Document(objects), ParseOptions { .live = true });
        if (ok() && tick) scene_->runtime->Tick(1.0 / 60.0);
    }

    bool                 ok() const { return scene_ != nullptr && scene_->runtime != nullptr; }
    Scene&               scene() { return *scene_; }
    SceneRuntimeContext& rt() { return *scene_->runtime; }

    // Whether some script error mentions `text`.
    bool ErrorMentions(const std::string& text)
    {
        const auto& errors = rt().scriptErrors();
        return std::any_of(errors.begin(), errors.end(), [&](const std::string& line) { return line.find(text) != std::string::npos; });
    }
    // The names of the scene graph root's children.
    std::vector<std::string> RootNames()
    {
        std::vector<std::string> names;
        for (const auto& child : scene().sceneGraph->GetChildren()) names.push_back(child->Name());
        return names;
    }
    SceneNode* Root(std::string_view name) { return FindRootChild(scene(), name); }

private:
    ParseRig               rig_;
    std::shared_ptr<Scene> scene_; // after rig_: dies first
};

constexpr const char* kCheckHelper = "function check(ok, what) { if (!ok) throw new Error('check failed: ' + what); }\n";

// An image layer that hosts `script` as its visibility script.
Json ScriptOwner(int id, const std::string& script, const Json& more = Json::object())
{
    Json owner = { { "id", id }, { "name", "owner" }, { "image", "image.json" }, { "visible", { { "value", true }, { "script", script } } } };
    for (const auto& [key, value] : more.items()) owner[key] = value;
    return owner;
}

Json TextObject(int id, const std::string& name, const Json& more = Json::object())
{
    Json text = { { "id", id }, { "name", name }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } };
    for (const auto& [key, value] : more.items()) text[key] = value;
    return text;
}

Json ImageObject(int id, const std::string& name, const Json& more = Json::object())
{
    Json image = { { "id", id }, { "image", "image.json" } };
    if (!name.empty()) image["name"] = name;
    for (const auto& [key, value] : more.items()) image[key] = value;
    return image;
}

// ---- createLayer on a model that cannot be copied -------------------------------------------

const std::string kCreateFromModel = std::string(R"JS(
export function init() { thisScene.createLayer('MODEL'); }
export function update(value) { return value; }
)JS");

std::string CreateFrom(const std::string& model)
{
    std::string script = kCreateFromModel;
    script.replace(script.find("MODEL"), 5, model);
    return script;
}

struct ModelRow {
    const char* label;
    const char* path;
    Json        model;
};

class RefusedModel : public testing::TestWithParam<int> {};

std::vector<ModelRow> RefusedModels()
{
    return { { "passthrough", "models/pass.json", { { "width", 64 }, { "height", 32 }, { "passthrough", true }, { "material", "mat.json" } } },
             { "fullscreen", "models/full.json", { { "width", 64 }, { "height", 32 }, { "fullscreen", true }, { "material", "mat.json" } } },
             { "composelayer", "models/util/composelayer.json", { { "width", 64 }, { "height", 32 }, { "material", "mat.json" } } },
             { "composelayer_depthtest", "models/util/composelayer_depthtest.json", { { "width", 64 }, { "height", 32 }, { "material", "mat.json" } } } };
}

// R-8.01 / B-8.01
TEST_P(RefusedModel, AModelThatCannotBeCopiedLeavesNothingBehind)
{
    const ModelRow row = RefusedModels()[GetParam()];
    FileMap        files = BasicAssets();
    PutJson(files, std::string("/") + row.path, row.model);
    Played run(Json::array({ ScriptOwner(2, CreateFrom(row.path), { { "origin", V3(320, 180, 0) } }) }), files);
    ASSERT_TRUE(run.ok());
    run.rt().Tick(1.0 / 60.0);

    EXPECT_FALSE(run.rt().HasNodeNamed(std::string("__template:") + row.path));
    EXPECT_FALSE(run.rt().HasNodeNamed(std::string("__we_template_") + row.path)) << "the key a template node would have been given";
    for (const std::string& name : run.RootNames()) EXPECT_NE(name.rfind("__generated_layer_", 0), 0u) << name;
    EXPECT_EQ(run.rt().LayerCount(), 1u) << "only the owner";
    EXPECT_TRUE(run.ErrorMentions(std::string("Unable to create layer: ") + row.path));
}

INSTANTIATE_TEST_SUITE_P(Models, RefusedModel, testing::Values(0, 1, 2, 3),
                         [](const testing::TestParamInfo<int>& info) { return std::string(RefusedModels()[info.param].label); });

TEST(CreateLayerFromModel, ACopyableModelOfTheSameShapeIsMadeAsAControl)
{
    FileMap files = BasicAssets();
    PutJson(files, "/models/plain.json", { { "width", 64 }, { "height", 32 }, { "material", "mat.json" } });
    Played run(Json::array({ ScriptOwner(2, CreateFrom("models/plain.json"), { { "origin", V3(320, 180, 0) } }) }), files);
    ASSERT_TRUE(run.ok());
    run.rt().Tick(1.0 / 60.0);
    EXPECT_TRUE(run.rt().scriptErrors().empty());
    const auto names = run.RootNames();
    EXPECT_TRUE(std::any_of(names.begin(), names.end(), [](const std::string& name) { return name.rfind("__generated_layer_", 0) == 0; }));
}

// R-8.02 / B-8.02
TEST(CreateLayerFromModel, AModelPathThatResolvesToNoFileIsAbsentAndNeverParsed)
{
    ErrorLog log;
    Played   run(Json::array({ ScriptOwner(2, CreateFrom("models/ghost.json"), { { "origin", V3(320, 180, 0) } }) }));
    ASSERT_TRUE(run.ok());
    run.rt().Tick(1.0 / 60.0);

    EXPECT_EQ(ErrorLog::Count("LoadLayerTemplate"), 0u);
    EXPECT_EQ(ErrorLog::Count("json parse failed"), 0u) << "an empty file text is no document, so nothing is parsed from it";
    std::size_t not_found = 0;
    for (const std::string& line : ErrorLog::Lines()) {
        if (line.find("not found") != std::string::npos && line.find("models/ghost.json") != std::string::npos) ++not_found;
    }
    EXPECT_GE(not_found, 1u);
    EXPECT_TRUE(run.ErrorMentions("Unable to create layer: models/ghost.json"));
}

TEST(CreateLayerFromModel, AFailedPathIsAskedForOnce)
{
    const std::string once = R"JS(
export function init() { try { thisScene.createLayer('models/ghost.json'); } catch (e) {} }
export function update(value) { return value; }
)JS";
    const std::string twice = R"JS(
export function init() {
    try { thisScene.createLayer('models/ghost.json'); } catch (e) {}
    try { thisScene.createLayer('models/ghost.json'); } catch (e) {}
}
export function update(value) { return value; }
)JS";
    auto lookups = [](const std::string& script) {
        ErrorLog log;
        Played   run(Json::array({ ScriptOwner(2, script, { { "origin", V3(320, 180, 0) } }) }));
        EXPECT_TRUE(run.ok());
        return ErrorLog::Count("models/ghost.json");
    };
    const std::size_t one_call  = lookups(once);
    const std::size_t two_calls = lookups(twice);
    EXPECT_GE(one_call, 1u);
    EXPECT_EQ(two_calls, one_call) << "the second request for the same missing path does not look again";
}

// ---- the layer registry as scripts see it ---------------------------------------------------

// R-8.03 / B-8.03
TEST(LayerRegistry, LayersAreListedInDeclarationOrderFoundByIdAndExposeTheirObject)
{
    const std::string script = std::string(kCheckHelper) + R"JS(
export function init(value) {
    check(thisScene.enumerateLayers().map(function (l) { return l.name; }).join(',') === 'first,label,last', 'names in order');
    check(thisScene.getLayerCount() === 3, 'count');
    check(thisScene.getLayerByID(31) === thisScene.getLayer('first'), 'id 31 is first');
    check(thisScene.getLayerByID(7) === thisScene.getLayer(1), 'id 7 is the second layer');
    var label = thisScene.getInitialLayerConfig(thisScene.getLayer('label'));
    check(label && label.text === 'hello' && label.font === 'Arial' && label.id === 7, 'label config');
    var own = thisScene.getInitialLayerConfig(thisLayer);
    check(own && own.image === 'image.json' && own.name === 'last', 'own config');
    check(thisScene.getLayerByID(9999) === null, 'unknown id');
    check(thisScene.getLayerByID('x') === null, 'non-numeric id');
}
export function update(value) { return value; }
)JS";
    Played run(Json::array({ ImageObject(31, "first", { { "origin", V3(10, 20, 0) } }), TextObject(7, "label"),
                          ImageObject(12, "last", { { "visible", { { "value", true }, { "script", script } } } }) }));
    ASSERT_TRUE(run.ok());
    EXPECT_TRUE(run.rt().scriptErrors().empty()) << (run.rt().scriptErrors().empty() ? "" : run.rt().scriptErrors().front());
    EXPECT_EQ(run.rt().LayerCount(), 3u);
    EXPECT_EQ(run.rt().LayerNameAt(0), "first");
    EXPECT_EQ(run.rt().LayerNameAt(1), "label");
    EXPECT_EQ(run.rt().LayerNameForId(12), "last");
    EXPECT_TRUE(run.rt().InitialLayerConfigRequested());

    const Json label_config = Json::parse(run.rt().InitialLayerConfigJson("label"), nullptr, false);
    ASSERT_TRUE(label_config.is_object());
    EXPECT_EQ(label_config.value("id", -1), 7);
}

// The order scripts see is the order of the file, whatever order the layers' bindings were made in.
TEST(LayerRegistry, DeclarationOrderHoldsForLayersWhoseBindingsAreMadeLate)
{
    auto scripted_origin = [](double x) { return Json { { "value", V3(x, 0, 0) }, { "script", "export function update(value) { return value; }" } }; };
    const std::string script = std::string(kCheckHelper) + R"JS(
export function init(value) {
    check(thisScene.enumerateLayers().map(function (l) { return l.name; }).join(',') === 'late,early,later', 'names in order');
}
export function update(value) { return value; }
)JS";
    Played run(Json::array({ ImageObject(1, "late", { { "origin", scripted_origin(1) } }), ImageObject(2, "early"),
                             ImageObject(3, "later", { { "origin", scripted_origin(3) }, { "visible", { { "value", true }, { "script", script } } } }) }));
    ASSERT_TRUE(run.ok());
    EXPECT_TRUE(run.rt().scriptErrors().empty()) << (run.rt().scriptErrors().empty() ? "" : run.rt().scriptErrors().front());
    ASSERT_EQ(run.rt().LayerCount(), 3u);
    EXPECT_EQ(run.rt().LayerNameAt(0), "late");
    EXPECT_EQ(run.rt().LayerNameAt(1), "early");
    EXPECT_EQ(run.rt().LayerNameAt(2), "later");
}

// A layer declared before the group it hangs from is still listed where the file puts it.
TEST(LayerRegistry, ALayerDeclaredBeforeItsParentKeepsItsPlaceInTheList)
{
    for (const char* kind : { "group", "text" }) {
        SCOPED_TRACE(kind);
        Json parent = { { "id", 2 }, { "name", "parent" }, { "visible", true } };
        if (std::string(kind) == "text") parent = TextObject(2, "parent");
        Played run(Json::array({ ImageObject(1, "child", { { "parent", 2 } }), parent, ImageObject(3, "after") }));
        ASSERT_TRUE(run.ok());
        ASSERT_EQ(run.rt().LayerCount(), 3u);
        EXPECT_EQ(run.rt().LayerNameAt(0), "child");
        EXPECT_EQ(run.rt().LayerNameAt(1), "parent");
        EXPECT_EQ(run.rt().LayerNameAt(2), "after");
    }
}

// Every kind of object is listed where the file puts it.
TEST(LayerRegistry, EveryKindOfObjectIsListedWhereTheFilePutsIt)
{
    Played run(Json::array({ Json { { "id", 1 }, { "name", "voice" }, { "sound", Json::array({ "sounds/a.wav" }) }, { "playbackmode", "single" }, { "startsilent", true } },
                             Json { { "id", 2 }, { "name", "sparks" }, { "particle", "particle.json" }, { "visible", true } },
                             Json { { "id", 3 }, { "name", "bulb" }, { "light", "point" }, { "radius", 10 }, { "intensity", 1 }, { "color", V3(1, 1, 1) }, { "visible", true } },
                             TextObject(4, "caption"), ImageObject(5, "picture"),
                             Json { { "id", 6 }, { "name", "folder" }, { "visible", true } } }));
    ASSERT_TRUE(run.ok());
    std::vector<std::string> seen;
    for (std::size_t i = 0; i < run.rt().LayerCount(); ++i) seen.push_back(run.rt().LayerNameAt(i));
    EXPECT_EQ(seen, (std::vector<std::string> { "voice", "sparks", "bulb", "caption", "picture", "folder" }));
}

// R-8.04 / B-8.04
TEST(LayerRegistry, TheObjectListIsOnlyKeptWhenSomeScriptAsksForIt)
{
    auto plain = [](const std::string& body) {
        return Json::array({ ImageObject(1, "plain", { { "visible", { { "value", true }, { "script", body } } } }) });
    };
    {
        Played run(plain("export function update(value) { return value; }"));
        ASSERT_TRUE(run.ok());
        EXPECT_FALSE(run.rt().InitialLayerConfigRequested());
        EXPECT_EQ(run.rt().InitialLayerConfigJson("plain"), "");
    }
    {
        Played run(plain("// getInitialLayerConfig is only mentioned here\nexport function update(value) { return value; }"));
        ASSERT_TRUE(run.ok());
        EXPECT_TRUE(run.rt().InitialLayerConfigRequested());
        const Json config = Json::parse(run.rt().InitialLayerConfigJson("plain"), nullptr, false);
        ASSERT_TRUE(config.is_object());
        EXPECT_EQ(config.value("id", -1), 1);
    }
}

// R-8.09 / B-8.05
TEST(LayerRegistry, ScriptsSeeTheAuthoredNameOfLayersRegisteredUnderGeneratedKeys)
{
    const std::string script = std::string(kCheckHelper) + R"JS(
export function init(value) {
    check(thisScene.enumerateLayers().map(function (l) { return l.name; }).join(',') === 'twin,twin,,solo', 'names');
    check(thisScene.getLayerByID(2).name === 'twin', 'id 2 name');
    check(thisScene.getLayerByID(2) !== thisScene.getLayer('twin'), 'a shared name resolves to the first');
    check(thisScene.getLayer('twin') === thisScene.getLayer(0), 'twin is layer 0');
    check(thisScene.getLayer(2).name === '', 'nameless');
    check(thisScene.getLayerIndex(thisScene.getLayerByID(2)) === 1, 'index of id 2');
    check(thisLayer.name === 'solo', 'own name');
}
export function update(value) { return value; }
)JS";
    Played run(Json::array({ ImageObject(1, "twin"), ImageObject(2, "twin"), ImageObject(3, ""),
                          ImageObject(4, "solo", { { "visible", { { "value", true }, { "script", script } } } }) }));
    ASSERT_TRUE(run.ok());
    EXPECT_TRUE(run.rt().scriptErrors().empty()) << (run.rt().scriptErrors().empty() ? "" : run.rt().scriptErrors().front());
    ASSERT_EQ(run.rt().LayerCount(), 4u);
    EXPECT_EQ(run.rt().LayerAuthoredName(run.rt().LayerNameAt(1)), "twin");
    EXPECT_EQ(run.rt().LayerAuthoredName(run.rt().LayerNameAt(2)), "");
    EXPECT_EQ(run.rt().LayerNameAt(0), "__we_layer_1");
    EXPECT_EQ(run.rt().LayerNameAt(1), "__we_layer_2");
    EXPECT_EQ(run.rt().LayerNameAt(2), "__we_layer_3");
    EXPECT_EQ(run.rt().LayerNameAt(3), "solo");
}

// R-8.10 / B-8.06
TEST(LayerRegistry, ASceneScriptsInitAlreadySeesOrderIdsObjectsAndTheTextHooks)
{
    const std::string script = std::string(kCheckHelper) + R"JS(
engine.on('resizeScreen', function () {});
export function init(value) {
    check(thisScene.enumerateLayers().map(function (l) { return l.name; }).join(',') === 'first,label,last', 'names');
    check(thisScene.getLayerByID(31) === thisScene.getLayer('first'), 'id 31');
    check(thisScene.getLayerByID(7) === thisScene.getLayer(1), 'id 7');
    var label = thisScene.getInitialLayerConfig(thisScene.getLayer('label'));
    check(label && label.text === 'hello' && label.id === 7, 'label config');
    thisScene.getLayer('label').font = 'systemfont_arial';
    var made = thisScene.createLayer({ text: 'from init', name: 'made', pointsize: 18 });
    check(thisScene.getLayer('made') === made, 'made layer is found by name');
    check(thisScene.getLayerCount() === 4, 'count after making');
}
)JS";
    Played run(Json::array({ ImageObject(31, "first"), TextObject(7, "label"),
                          ImageObject(12, "last", { { "visible", { { "value", true }, { "script", script } } } }) }),
            BasicAssets(), /*tick=*/false);
    ASSERT_TRUE(run.ok());
    EXPECT_TRUE(run.rt().scriptErrors().empty()) << (run.rt().scriptErrors().empty() ? "" : run.rt().scriptErrors().front());
    EXPECT_TRUE(run.rt().InitialLayerConfigRequested());
    EXPECT_EQ(run.rt().sceneScriptCount(), 1u);
    EXPECT_EQ(run.rt().LayerCount(), 4u);
    const auto state = run.rt().NodeTextState("label");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->font_key, "systemfont_arial");
    const std::string made = run.rt().ResolveLayerName("made");
    EXPECT_TRUE(run.rt().HasNodeNamed(made));
    EXPECT_EQ(run.rt().NodeText(made), "from init");
}

// ---- layers made with createLayer({ text }) -------------------------------------------------

const std::string kMakeShadow = R"JS(
export function init(value) {
    var label = thisScene.getLayer('label');
    var shadow = thisScene.createLayer({ text: thisScene.getInitialLayerConfig(label).text, font: label.font, pointsize: label.pointsize,
                                         color: '0.2 0.4 0.6', alpha: 0.5, name: 'shadow', horizontalalign: 'left' });
    shadow.origin = new Vec3(40, 50, 0);
    thisScene.createLayer({ text: 'ghost', font: 'Arial', name: 'ghost', alignment: 'right', verticalalign: 'Top' });
}
export function update(value) { return value; }
)JS";

// R-8.05 / B-8.07, B-8.10
TEST(ScriptMadeText, ALayerMadeByAScriptIsBuiltLikeASceneTextObject)
{
    Played run(Json::array({ TextObject(1, "label"), ScriptOwner(2, kMakeShadow) }));
    ASSERT_TRUE(run.ok());
    SceneRuntimeContext& rt = run.rt();

    const std::string name = rt.ResolveLayerName("shadow");
    EXPECT_TRUE(rt.HasNodeNamed(name));
    EXPECT_EQ(name.rfind("__we_text_", 0), 0u);
    EXPECT_EQ(rt.NodeText(name), "hello");
    const auto state = rt.NodeTextState(name);
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 24.0f);
    EXPECT_EQ(state->font_key, "Arial");
    EXPECT_EQ(state->horizontal_align, "left");

    const auto ghost = rt.NodeTextState(rt.ResolveLayerName("ghost"));
    ASSERT_TRUE(ghost.has_value());
    EXPECT_EQ(ghost->horizontal_align, "center") << "`alignment` is not a text key";
    EXPECT_EQ(ghost->vertical_align, "center") << "'Top' is not one of the words top/center/bottom";

    EXPECT_GT(rt.NodeSize(name).x(), 0.0f);
    EXPECT_NEAR(rt.NodeSize(name).x(), rt.NodeSize("label").x(), 1e-3f) << "same text, font and size";

    SceneNode* node = run.Root(name);
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const SceneMaterial* material = node->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    const auto& constants = material->customShader.constValues;
    ASSERT_NE(constants.find("g_Color"), constants.end());
    EXPECT_FLOAT_EQ(constants.at("g_Color")[0], 0.2f);
    EXPECT_FLOAT_EQ(constants.at("g_Color")[1], 0.4f);
    EXPECT_FLOAT_EQ(constants.at("g_Color")[2], 0.6f);
    ASSERT_NE(constants.find("g_Alpha"), constants.end());
    EXPECT_FLOAT_EQ(constants.at("g_Alpha")[0], 0.5f);

    EXPECT_TRUE(rt.ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(rt.LayerCount(), 4u);
    EXPECT_EQ(rt.LayerNameAt(2), name) << "script-made layers follow the scene's own, in creation order";
    EXPECT_EQ(rt.LayerNameAt(3), rt.ResolveLayerName("ghost"));
    EXPECT_EQ(rt.InitialLayerConfigJson(name), "") << "no scene object stands behind a made layer";
    EXPECT_TRUE(rt.scriptErrors().empty()) << (rt.scriptErrors().empty() ? "" : rt.scriptErrors().front());
}

// R-8.05 / B-8.10 (the alignment words a made layer carries)
TEST(ScriptMadeText, TextAlignmentWordsAreTheLowerCaseOnesOrTheDefault)
{
    const std::string script = R"JS(
export function init(value) {
    thisScene.createLayer({ text: 'a', name: 'plain' });
    thisScene.createLayer({ text: 'b', name: 'low', horizontalalign: 'right', verticalalign: 'bottom' });
    thisScene.createLayer({ text: 'c', name: 'odd', horizontalalign: 'sideways', verticalalign: 'Top' });
}
export function update(value) { return value; }
)JS";
    Played run(Json::array({ ScriptOwner(2, script) }));
    ASSERT_TRUE(run.ok());
    auto words = [&](const char* layer) {
        const auto state = run.rt().NodeTextState(run.rt().ResolveLayerName(layer));
        EXPECT_TRUE(state.has_value()) << layer;
        return state.has_value() ? std::make_pair(state->horizontal_align, state->vertical_align) : std::pair<std::string, std::string> {};
    };
    EXPECT_EQ(words("plain"), std::make_pair(std::string("center"), std::string("center")));
    EXPECT_EQ(words("low"), std::make_pair(std::string("right"), std::string("bottom")));
    // An unknown horizontal word reads as left; an unknown vertical word as centre.
    EXPECT_EQ(words("odd"), std::make_pair(std::string("left"), std::string("center")));
}

// R-8.06 / B-8.08
TEST(ScriptMadeText, ASizeSuppliedByTheScriptIsIgnoredForText)
{
    const std::string script = R"JS(
export function init(value) { thisScene.createLayer({ text: 'hello', font: 'Arial', pointsize: 24, name: 'boxed', size: '640 400' }); }
export function update(value) { return value; }
)JS";
    Played run(Json::array({ TextObject(1, "label"), ScriptOwner(2, script) }));
    ASSERT_TRUE(run.ok());
    const std::string name = run.rt().ResolveLayerName("boxed");
    ASSERT_TRUE(run.rt().HasNodeNamed(name));
    const linalg::Vector2f size = run.rt().NodeSize(name);
    EXPECT_GT(size.x(), 0.0f);
    EXPECT_LT(size.x(), 640.0f);
    EXPECT_LT(size.y(), 400.0f);
    EXPECT_TRUE(size.isApprox(run.rt().NodeSize("label")));
}

// The extent of the card mesh of `node` along one vertex component (0 = x, 1 = y).
std::pair<float, float> CardExtent(SceneNode& node, std::size_t component)
{
    const SceneVertexArray& vertices = node.Mesh()->GetVertexArray(0);
    float low = 1e30f, high = -1e30f;
    for (std::size_t i = 0; i < vertices.VertexCount(); ++i) {
        const float v = vertices.Data()[i * vertices.OneSize() + component];
        low  = std::min(low, v);
        high = std::max(high, v);
    }
    return { low, high };
}

// R-8.07 / B-8.09
TEST(ScriptMadeText, ALayerMadeByAScriptSitsAgainstItsOriginAccordingToItsAlignment)
{
    auto make = [](const char* horizontal, const char* vertical) {
        return std::string("export function init(value) {\n  var label = thisScene.createLayer({ text: 'hello', font: 'Arial', pointsize: 24, name: 'label', horizontalalign: '") +
               horizontal + "', verticalalign: '" + vertical + "', size: '640 400' });\n  label.origin = new Vec3(300, 100, 0);\n}\nexport function update(value) { return value; }\n";
    };
    {
        Played run(Json::array({ ScriptOwner(1, make("right", "bottom")) }));
        ASSERT_TRUE(run.ok());
        const std::string name = run.rt().ResolveLayerName("label");
        SceneNode*        node = run.Root(name);
        ASSERT_NE(node, nullptr);
        ASSERT_NE(node->Mesh(), nullptr);
        EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(300, 100, 0)));
        EXPECT_TRUE(run.rt().NodeTranslate(name).isApprox(linalg::Vector3f(300, 100, 0)));
        const auto layout = run.rt().NodeTextLayout(name);
        ASSERT_TRUE(layout.has_value());
        EXPECT_NEAR(CardExtent(*node, 0).second, 0.0f, 1e-3f) << "right alignment puts the card's right edge on the origin";
        EXPECT_NEAR(CardExtent(*node, 1).second, layout->top + layout->descender, 1e-3f) << "bottom: the last row's descender line is on the origin";
        EXPECT_LT(run.rt().NodeSize(name).x(), 640.0f);
        EXPECT_TRUE(run.rt().scriptErrors().empty());
    }
    {
        Played run(Json::array({ ScriptOwner(1, make("left", "top")) }));
        ASSERT_TRUE(run.ok());
        const std::string name = run.rt().ResolveLayerName("label");
        SceneNode*        node = run.Root(name);
        ASSERT_NE(node, nullptr);
        ASSERT_NE(node->Mesh(), nullptr);
        EXPECT_NEAR(CardExtent(*node, 0).first, 0.0f, 1e-3f) << "left alignment puts the card's left edge on the origin";
        EXPECT_LT(CardExtent(*node, 1).second, run.rt().NodeSize(name).y() + 1e-3f);
        EXPECT_NEAR(CardExtent(*node, 1).second, 0.0f, 1e-3f) << "top alignment puts the card's upper edge on the origin";
    }
}

// ---- restyling a scene text layer ----------------------------------------------------------

// Waits (bounded) until the layout of `layer` has settled.
void SettleText(SceneRuntimeContext& rt, const std::string& layer)
{
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (!rt.NodeTextDirty(layer)) break;
        rt.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

Json ClockObject() { return TextObject(1, "clock", { { "text", "12:30" }, { "pointsize", 20 }, { "origin", V3(320, 180, 0) }, { "horizontalalign", "left" }, { "verticalalign", "top" } }); }

// R-8.08 / B-8.11
TEST(TextRestyle, PointSizeFontAndAlignmentWrittenByAScriptChangeTheStateAtOnceAndTheLayoutLater)
{
    const std::string script = R"JS(
export function init(value) {}
export function update(value) { return value; }
export function cursorClick() {
    var c = thisScene.getLayer('clock');
    c.pointsize = c.pointsize * 2;
    c.font = 'systemfont_arial';
    c.horizontalalign = 'right';
}
)JS";
    Played run(Json::array({ ClockObject(), ScriptOwner(2, script) }));
    ASSERT_TRUE(run.ok());
    SceneRuntimeContext& rt = run.rt();
    SettleText(rt, "clock");
    const linalg::Vector2f before = rt.NodeSize("clock");
    ASSERT_TRUE(rt.NodeTextState("clock").has_value());
    EXPECT_EQ(rt.NodeTextState("clock")->horizontal_align, "left");

    rt.DispatchCursorClick();
    EXPECT_TRUE(rt.scriptErrors().empty());
    const auto state = rt.NodeTextState("clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 40.0f);
    EXPECT_EQ(state->font_key, "systemfont_arial");
    EXPECT_EQ(state->resolved_font_kind, "system");
    EXPECT_EQ(state->horizontal_align, "right");
    EXPECT_EQ(state->vertical_align, "top");

    SettleText(rt, "clock");
    EXPECT_FALSE(rt.NodeTextDirty("clock"));
    const linalg::Vector2f after = rt.NodeSize("clock");
    EXPECT_GT(after.x(), before.x());
    EXPECT_GT(after.y(), before.y());
}

TEST(TextRestyle, ValuesTheStyleCannotTakeAreRefusedAndTheStateStays)
{
    const std::string script = R"JS(
export function update(value) { return value; }
export function cursorClick() {
    var c = thisScene.getLayer('clock');
    c.pointsize = 0;
    c.horizontalalign = 'sideways';
    c.verticalalign = 'middle';
}
)JS";
    Played run(Json::array({ ClockObject(), ScriptOwner(2, script) }));
    ASSERT_TRUE(run.ok());
    SettleText(run.rt(), "clock");
    run.rt().DispatchCursorClick();
    const auto state = run.rt().NodeTextState("clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 20.0f);
    EXPECT_EQ(state->horizontal_align, "left");
    EXPECT_EQ(state->vertical_align, "top");
}

// ---- teardown ---------------------------------------------------------------------------------

// A file system that holds nothing, counts the questions put to it, and notes when it is destroyed.
struct ProbeState {
    std::atomic<int>  asked_alive { 0 };
    std::atomic<int>  asked_after { 0 };
    std::atomic<bool> dead { false };
};

class ProbeFs final : public fs::Fs {
public:
    explicit ProbeFs(std::shared_ptr<ProbeState> state) : state_(std::move(state)) {}
    ~ProbeFs() override { state_->dead = true; }

    bool Contains(std::string_view) const override
    {
        (state_->dead ? state_->asked_after : state_->asked_alive)++;
        return false;
    }
    std::shared_ptr<fs::IBinaryStream>  Open(std::string_view) override { return nullptr; }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::shared_ptr<ProbeState> state_;
};

// R-8.11 / B-8.12
TEST(Teardown, ScriptsDestroyRunsWhileTheScenesFilesAndLayersStillExist)
{
    auto state = std::make_shared<ProbeState>();
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    auto                vfs = std::make_unique<fs::VFS>();
    MountAssets(*vfs, BasicAssets());
    vfs->Mount("/assets", std::make_unique<ProbeFs>(state));

    const std::string script = R"JS(
export function init(value) {}
export function update(value) { return value; }
export function destroy() {
    thisScene.getLayer('label').font = 'fonts/probe.ttf';
    thisLayer.visible = true;
}
)JS";
    ProjectProperties properties;
    SceneParseRequest request;
    request.scene_id           = "teardown";
    request.project_properties = &properties;
    WPSceneParser parser;
    auto          scene = parser.Parse(request, Document(Json::array({ TextObject(1, "label"), ScriptOwner(2, script) })).dump(), *vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->vfs = std::move(vfs);
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(scene->runtime->scriptErrors().empty());
    const int asked_before = state->asked_alive;

    scene.reset();
    EXPECT_GT(state->asked_alive.load(), asked_before) << "destroy() reached the files";
    EXPECT_EQ(state->asked_after.load(), 0);
    EXPECT_TRUE(state->dead.load());
}

// Counts the scene's textures that belong to text layers made at run time.
std::size_t RuntimeTextTextures(const Scene& scene)
{
    std::size_t count = 0;
    for (const auto& [name, texture] : scene.textures) count += name.rfind("runtime/text/", 0) == 0 ? 1 : 0;
    return count;
}

// R-8.12 / B-8.13
TEST(Teardown, TheRastersOfMadeAndDestroyedTextLayersAreReleased)
{
    Played run(Json::array({ ImageObject(2, "owner") }));
    ASSERT_TRUE(run.ok());
    auto* images = dynamic_cast<RuntimeImageSource*>(run.scene().imageParser.get());
    ASSERT_NE(images, nullptr);
    SceneRuntimeContext& rt       = run.rt();
    const std::size_t    baseline = RuntimeTextTextures(run.scene());

    for (int round = 0; round < 4; ++round) {
        SCOPED_TRACE("round " + std::to_string(round));
        const std::string name = rt.CreateTextLayer("{\"text\":\"x\",\"pointsize\":20,\"visible\":true}", "owner");
        ASSERT_FALSE(name.empty());
        const std::string texture = TextTextureName(name);
        EXPECT_TRUE(run.scene().textures.count(texture) > 0);
        EXPECT_TRUE(images->IsRuntimeImage(texture));
        EXPECT_EQ(RuntimeTextTextures(run.scene()), baseline + 1);

        rt.ConsumeSceneGraphMutationFlag();
        EXPECT_TRUE(rt.DestroyLayer(name));
        EXPECT_TRUE(run.scene().textures.count(texture) > 0) << "the compiled graph may still sample it";
        rt.Tick(1.0 / 60.0);
        EXPECT_TRUE(run.scene().textures.count(texture) > 0) << "not while the graph that samples it has yet to be rebuilt";

        EXPECT_TRUE(rt.ConsumeSceneGraphMutationFlag()) << "a rebuilt graph no longer holds the layer";
        rt.Tick(1.0 / 60.0);
        EXPECT_EQ(run.scene().textures.count(texture), 0u);
        EXPECT_FALSE(images->IsRuntimeImage(texture));
        EXPECT_EQ(RuntimeTextTextures(run.scene()), baseline);
    }
    EXPECT_TRUE(images->IsRuntimeImage("$mediaThumbnail")) << "cover images are never removed";
}

// ---- bounded JSON nesting ---------------------------------------------------------------------

std::string NestedDocument(std::size_t depth)
{
    return "{\"camera\":{},\"general\":{\"bloom\":false},\"objects\":[{\"id\":1,\"name\":\"g\",\"extra\":" + std::string(depth, '[') + std::string(depth, ']') + "}]}";
}

// R-8.13 / B-8.14
TEST(JsonNesting, ADocumentThatNestsWithoutBoundIsRefusedAndOrdinaryOnesAreParsed)
{
    ParseRig rig(BasicAssets());
    EXPECT_NE(rig.Parse(NestedDocument(100)), nullptr);
    EXPECT_EQ(rig.Parse(NestedDocument(100000)), nullptr);

    // Brackets inside a string do not count.
    const std::string quoted = "{\"camera\":{},\"general\":{\"bloom\":false},\"objects\":[{\"id\":1,\"name\":\"" + std::string(2000, '[') + "\\\"[\"}]}";
    EXPECT_NE(rig.Parse(quoted), nullptr);
}

TEST(JsonNesting, TheLimitIsFiveHundredAndTwelveOpenBracketsOutsideStrings)
{
    ParseRig rig(BasicAssets());
    EXPECT_NE(rig.Parse(NestedDocument(509)), nullptr) << "three outer levels plus 509 make exactly 512";
    ErrorLog log;
    EXPECT_EQ(rig.Parse(NestedDocument(510)), nullptr);
    EXPECT_GE(ErrorLog::Count("nests deeper than"), 1u);
}

} // namespace
