// A running scene can be handed a whole property document without being loaded
// again. These tests pin what that document means, with no device, window or
// audio output: it is the project's declared defaults with exactly the given
// values over them, whatever the scene happened to load with, and a scene that
// takes it ends up exactly where a fresh load with the same document would. The
// few properties a scene reads only while it loads are noted, and a preview holds
// them at the value they were read with. The last tests send the document through
// the engine's own command, to a scene that is running on its render thread.

#include <gtest/gtest.h>

#include <nlohmann/json.hpp>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneImageEffectLayer.h"
#include "Scene/include/Scene/SceneMaterial.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "SceneWallpaper.hpp"
#include "WPSceneParser.hpp"
#include "WPSoundParser.hpp"
#include "wpscene/WPMaterial.h"
#include "wpscene/WPSoundObject.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{
namespace
{

// What the project's `project.json` declares.
const ProjectProperties kAuthored {
    { "a", RuntimeScalarValue::Float(1.0f) },
    { "b", RuntimeScalarValue::Float(2.0f) },
    { "c", RuntimeScalarValue::String("x") },
};

ProjectProperties Loaded(const ProjectProperties& saved_choices) {
    return MergeProjectProperties(kAuthored, saved_choices);
}

void ExpectSameTable(const ProjectProperties& actual, const ProjectProperties& expected) {
    EXPECT_EQ(actual.size(), expected.size());
    for (const auto& [name, want] : expected) {
        const auto found = actual.find(name);
        ASSERT_NE(found, actual.end()) << name << " is missing";
        EXPECT_EQ(found->second.kind, want.kind) << name;
        switch (want.kind) {
        case RuntimeScalarValue::Kind::Bool:
            EXPECT_EQ(found->second.bool_value, want.bool_value) << name;
            break;
        case RuntimeScalarValue::Kind::Float:
            EXPECT_EQ(found->second.float_value, want.float_value) << name;
            break;
        case RuntimeScalarValue::Kind::String:
            EXPECT_EQ(found->second.string_value, want.string_value) << name;
            break;
        }
    }
}

std::vector<std::string> Names(std::initializer_list<const char*> names) {
    return { names.begin(), names.end() };
}

// A saved choice -- a preset, or what the user picked last time -- is loaded
// over the project's defaults. A document sent to the running scene afterwards
// is the whole state, so a value it leaves out has to be the project's own
// default again, not the choice the scene happened to be loaded with.
TEST(ProjectPropertyRuntime, ApplyingAnEmptyDocumentReturnsToTheAuthoredDefaultsNotTheLoadedOverrides) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties          = Loaded({ { "a", RuntimeScalarValue::Float(5.0f) } }),
        .authored_project_properties = kAuthored,
    });
    ASSERT_NE(runtime, nullptr);
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 5.0f);
    ExpectSameTable(runtime->defaultProjectProperties(), kAuthored);
    ASSERT_NE(runtime->FindPropertyValue("a"), nullptr);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 5.0f);

    // `a` is left out: it returns to what the project declares. `b` is set.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "b", RuntimeScalarValue::Float(7.0f) } }),
              Names({ "a", "b" }));
    EXPECT_EQ(runtime->projectProperties().at("a").kind, RuntimeScalarValue::Kind::Float);
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 1.0f);
    EXPECT_EQ(runtime->projectProperties().at("b").float_value, 7.0f);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 1.0f);
    EXPECT_EQ(runtime->FindPropertyValue("b")->getFloat(), 7.0f);

    // Nothing is left of either the saved choice or the document.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({}), Names({ "b" }));
    ExpectSameTable(runtime->projectProperties(), kAuthored);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 1.0f);
    EXPECT_EQ(runtime->FindPropertyValue("b")->getFloat(), 2.0f);
    EXPECT_EQ(runtime->FindPropertyValue("c")->getString(), "x");

    // Applying what is already in effect changes nothing.
    EXPECT_TRUE(runtime->ApplyProjectPropertyOverride({}).empty());
    EXPECT_TRUE(runtime->ResetProjectPropertyOverride().empty());

    // And a reset is the same as applying that empty document.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "c", RuntimeScalarValue::String("y") },
                                                       { "a", RuntimeScalarValue::Float(3.0f) } }),
              Names({ "a", "c" }));
    EXPECT_EQ(runtime->ResetProjectPropertyOverride(), Names({ "a", "c" }));
    ExpectSameTable(runtime->projectProperties(), kAuthored);
}

// Every caller before this one handed over a single table, and what a scene
// that gets no authored table does is what it always did.
TEST(ProjectPropertyRuntime, ARequestWithoutAnAuthoredTableBehavesAsBefore) {
    const auto loaded = Loaded({ { "a", RuntimeScalarValue::Float(5.0f) } });
    auto       runtime =
        CreateSceneRuntimeContext(SceneRuntimeBootstrap { .project_properties = loaded });
    ASSERT_NE(runtime, nullptr);
    ExpectSameTable(runtime->defaultProjectProperties(), loaded);

    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "b", RuntimeScalarValue::Float(7.0f) } }),
              Names({ "b" }));
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 5.0f);
    EXPECT_EQ(runtime->ResetProjectPropertyOverride(), Names({ "b" }));
    ExpectSameTable(runtime->projectProperties(), loaded);
}

// A document that changes only the kind of a value still changes it.
TEST(ProjectPropertyRuntime, ADocumentThatOnlyChangesAValuesKindReportsTheChange) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = { { "level", RuntimeScalarValue::Float(0.0f) },
                                { "flag", RuntimeScalarValue::Bool(false) } },
    });
    ASSERT_NE(runtime, nullptr);
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "flag", RuntimeScalarValue::Bool(true) },
                                                       { "level", RuntimeScalarValue::Float(0.0f) } }),
              Names({ "flag" }));
}

constexpr std::string_view kVert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
constexpr std::string_view kFrag = R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)";

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::string> m_files;
};

std::string SceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

// One layer per way a property reaches a scene: a flag and a choice decide
// whether a layer shows, a slider and a colour decide how it is drawn, and a
// text decides what a text layer says.
constexpr std::string_view kStillLayers = R"([
  {"id":1,"name":"gate","image":"image.json","visible":{"user":"show","value":true}},
  {"id":2,"name":"pick","image":"image.json",
   "visible":{"user":{"name":"style","condition":"1"},"value":true}},
  {"id":3,"name":"fader","image":"image.json",
   "alpha":{"user":"opacity","value":1.0},"color":{"user":"tint","value":"1 1 1"}}
])";
constexpr std::string_view kTextLayer = R"({"id":4,"name":"caption",
  "text":{"user":"words","value":"authored"},"font":"Arial","pointsize":10,
  "origin":[32,16,0],"visible":true})";

// What the project declares for those layers.
const ProjectProperties kLayerAuthored {
    { "show", RuntimeScalarValue::Bool(true) },
    { "style", RuntimeScalarValue::String("0") },
    { "opacity", RuntimeScalarValue::Float(1.0f) },
    { "tint", RuntimeScalarValue::String("1 1 1") },
    { "words", RuntimeScalarValue::String("authored") },
};

// What a user's saved choices make of them, which is not what the project says.
const ProjectProperties kLayerSaved {
    { "show", RuntimeScalarValue::Bool(false) },
    { "style", RuntimeScalarValue::String("1") },
    { "opacity", RuntimeScalarValue::Float(0.25f) },
    { "tint", RuntimeScalarValue::String("0.2 0.4 0.6") },
    { "words", RuntimeScalarValue::String("loaded") },
};

// Neither of those, for every property that can be anything.
const ProjectProperties kLayerDocument {
    { "show", RuntimeScalarValue::Bool(false) },
    { "style", RuntimeScalarValue::String("1") },
    { "opacity", RuntimeScalarValue::Float(0.5f) },
    { "tint", RuntimeScalarValue::String("0.9 0.8 0.7") },
    { "words", RuntimeScalarValue::String("a longer preview") },
};

struct LoadedScene {
    fs::VFS             vfs;
    audio::SoundManager sound { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    std::shared_ptr<Scene> scene;

    SceneRuntimeContext& runtime() { return *scene->runtime; }
};

// Loads the scene as the engine does: the values it loads with, and the
// project's own beside them when those carry saved choices.
std::unique_ptr<LoadedScene> Load(std::string_view objects, const ProjectProperties& loaded,
                                  const ProjectProperties* authored,
                                  const std::map<std::string, std::string>& more_files = {}) {
    auto loaded_scene = std::make_unique<LoadedScene>();
    std::map<std::string, std::string> files {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"]}]})" },
        { "/shaders/genericimage.vert", std::string(kVert) },
        { "/shaders/genericimage.frag", std::string(kFrag) },
        { "/materials/solid.tex", "" },
    };
    files.insert(more_files.begin(), more_files.end());
    if (! loaded_scene->vfs.Mount("/assets", std::make_unique<MemoryFs>(files))) return nullptr;
    loaded_scene->scene = loaded_scene->parser.Parse(
        SceneParseRequest {
            .scene_id                    = "property-preview",
            .project_properties          = &loaded,
            .authored_project_properties = authored,
        },
        SceneJson(objects),
        loaded_scene->vfs,
        loaded_scene->sound);
    if (loaded_scene->scene == nullptr || loaded_scene->scene->runtime == nullptr) return nullptr;
    return loaded_scene;
}

SceneNode* FindNode(SceneNode& node, std::string_view name) {
    if (node.Name() == name) return &node;
    for (const auto& child : node.GetChildren()) {
        if (child == nullptr) continue;
        if (auto* found = FindNode(*child, name)) return found;
    }
    return nullptr;
}

struct LayerState {
    bool                                     visible { false };
    std::map<std::string, std::vector<float>> constants;

    bool operator==(const LayerState&) const = default;
};

struct SceneState {
    std::map<std::string, LayerState> layers;
    std::string                       text;

    bool operator==(const SceneState&) const = default;
};

// Everything the properties decide about the scene, after the tick that applies
// them: whether each layer shows, every constant its material holds, the text.
SceneState Capture(LoadedScene& loaded, bool with_text) {
    SceneState state;
    for (const char* name : { "gate", "pick", "fader" }) {
        auto* node = FindNode(*loaded.scene->sceneGraph, name);
        EXPECT_NE(node, nullptr) << name;
        if (node == nullptr) continue;
        LayerState layer;
        layer.visible = loaded.runtime().NodeVisible(name);
        if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->Material() != nullptr) {
            for (const auto& [constant, value] : mesh->Material()->customShader.constValues) {
                auto& floats = layer.constants[constant];
                for (std::size_t index = 0; index < value.size(); ++index) {
                    floats.push_back(value[index]);
                }
            }
        }
        state.layers.emplace(name, std::move(layer));
    }
    if (with_text) state.text = loaded.runtime().NodeText("caption");
    return state;
}

std::string Objects(bool with_text) {
    if (! with_text) return std::string(kStillLayers);
    std::string objects(kStillLayers);
    objects.insert(objects.rfind(']'), "," + std::string(kTextLayer));
    return objects;
}

void ExpectSameState(const SceneState& actual, const SceneState& expected, const char* what) {
    EXPECT_EQ(actual.text, expected.text) << what;
    ASSERT_EQ(actual.layers.size(), expected.layers.size()) << what;
    for (const auto& [name, want] : expected.layers) {
        const auto found = actual.layers.find(name);
        ASSERT_NE(found, actual.layers.end()) << what << ": " << name;
        EXPECT_EQ(found->second.visible, want.visible) << what << ": " << name << " visibility";
        EXPECT_EQ(found->second.constants, want.constants) << what << ": " << name << " constants";
    }
}

// The saved choices differ from the project's defaults in every kind, so a scene
// that kept any of them when it was told to return would show.
TEST(ProjectPropertyRoundTrip, EachKindReturnsToTheAuthoredValueExactly) {
    for (const bool with_text : { false, true }) {
        SCOPED_TRACE(with_text ? "with a text layer" : "images only");

        const auto fresh_authored = Load(Objects(with_text), kLayerAuthored, nullptr);
        ASSERT_NE(fresh_authored, nullptr);
        fresh_authored->runtime().Tick(1.0 / 60.0);
        const auto authored = Capture(*fresh_authored, with_text);

        const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
        const auto fresh_saved = Load(Objects(with_text), loaded_values, &kLayerAuthored);
        ASSERT_NE(fresh_saved, nullptr);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        const auto saved = Capture(*fresh_saved, with_text);

        // The fixture tells the two apart on every layer it has, so a return
        // that stopped short of any one of them could not pass unnoticed.
        EXPECT_NE(authored.layers.at("gate").visible, saved.layers.at("gate").visible);
        EXPECT_NE(authored.layers.at("pick").visible, saved.layers.at("pick").visible);
        EXPECT_NE(authored.layers.at("fader").constants, saved.layers.at("fader").constants);
        if (with_text) EXPECT_NE(authored.text, saved.text);

        // Load with the saved choices, take a document, then return.
        fresh_saved->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        const auto previewing = Capture(*fresh_saved, with_text);
        EXPECT_NE(previewing.layers.at("fader").constants, saved.layers.at("fader").constants);
        if (with_text) EXPECT_EQ(previewing.text, "a longer preview");

        fresh_saved->runtime().ApplyProjectPropertyOverride({});
        fresh_saved->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*fresh_saved, with_text), authored,
                        "after applying the empty document");

        // The same, for a reset.
        fresh_saved->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        fresh_saved->runtime().ResetProjectPropertyOverride();
        fresh_saved->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*fresh_saved, with_text), authored, "after a reset");
    }
}

// Showing a document on a running scene and loading the scene with it are the
// same thing to everything these properties reach.
TEST(ProjectPropertyRoundTrip, ApplyingADocumentEqualsLoadingWithIt) {
    for (const bool with_text : { false, true }) {
        SCOPED_TRACE(with_text ? "with a text layer" : "images only");
        const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
        const auto hot           = Load(Objects(with_text), loaded_values, &kLayerAuthored);
        ASSERT_NE(hot, nullptr);
        hot->runtime().Tick(1.0 / 60.0);
        hot->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        hot->runtime().Tick(1.0 / 60.0);

        const auto fresh = Load(Objects(with_text),
                                MergeProjectProperties(kLayerAuthored, kLayerDocument),
                                &kLayerAuthored);
        ASSERT_NE(fresh, nullptr);
        fresh->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*hot, with_text), Capture(*fresh, with_text),
                        "hot against a fresh load");

        // A document that mentions a subset is the defaults plus that subset.
        const ProjectProperties subset { { "opacity", RuntimeScalarValue::Float(0.75f) } };
        hot->runtime().ApplyProjectPropertyOverride(subset);
        hot->runtime().Tick(1.0 / 60.0);
        const auto fresh_subset =
            Load(Objects(with_text), MergeProjectProperties(kLayerAuthored, subset),
                 &kLayerAuthored);
        ASSERT_NE(fresh_subset, nullptr);
        fresh_subset->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*hot, with_text), Capture(*fresh_subset, with_text),
                        "a subset against a fresh load");
    }
}

// A shader constant a property drives is read from the property each frame, so
// it follows a document and returns with it like any other binding.
TEST(ProjectPropertyRoundTrip, AMaterialConstantReturnsToItsAuthoredValue) {
    const ProjectProperties authored {
        { "amount", RuntimeScalarValue::Float(0.5f) },
        { "tint", RuntimeScalarValue::String("1 1 1") },
    };
    const auto make = [&](const ProjectProperties& loaded, const ProjectProperties* declared,
                          std::shared_ptr<SceneMaterial>& material) {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
            .project_properties          = loaded,
            .authored_project_properties = declared != nullptr
                                               ? std::optional<ProjectProperties>(*declared)
                                               : std::nullopt,
        });
        material = std::make_shared<SceneMaterial>();
        runtime->RegisterMaterialConstant(
            material, "g_Amount",
            ResolveFloatSetting(*runtime, { { "user", "amount" }, { "value", 0.5f } }));
        runtime->RegisterMaterialConstant(
            material, "g_Tint",
            ResolveVec3Setting(*runtime, { { "user", "tint" }, { "value", { 1.0f, 1.0f, 1.0f } } }));
        runtime->Tick(1.0 / 60.0);
        return runtime;
    };
    const auto constants = [](const std::shared_ptr<SceneMaterial>& material) {
        std::map<std::string, std::vector<float>> values;
        for (const auto& [name, value] : material->customShader.constValues) {
            for (std::size_t index = 0; index < value.size(); ++index) {
                values[name].push_back(value[index]);
            }
        }
        return values;
    };

    std::shared_ptr<SceneMaterial> fresh_material;
    auto                           fresh = make(authored, nullptr, fresh_material);
    const auto                     authored_constants = constants(fresh_material);
    ASSERT_EQ(authored_constants.at("g_Amount"), std::vector<float>({ 0.5f }));

    const auto saved = MergeProjectProperties(
        authored, { { "amount", RuntimeScalarValue::Float(3.0f) },
                    { "tint", RuntimeScalarValue::String("0.2 0.4 0.6") } });
    std::shared_ptr<SceneMaterial> material;
    auto                           runtime = make(saved, &authored, material);
    EXPECT_EQ(constants(material).at("g_Amount"), std::vector<float>({ 3.0f }));

    runtime->ApplyProjectPropertyOverride({ { "amount", RuntimeScalarValue::Float(0.75f) } });
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(constants(material).at("g_Amount"), std::vector<float>({ 0.75f }));
    // The colour is left out, so it is the project's and not the saved one.
    EXPECT_EQ(constants(material).at("g_Tint"), authored_constants.at("g_Tint"));

    runtime->ApplyProjectPropertyOverride({});
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(constants(material), authored_constants);
}

// Taking a document must not make a still scene tick: the renderer stops
// drawing a scene that has nothing moving by itself, and a property that
// arrives wakes it for exactly the frame it changes.
TEST(ProjectPropertyRuntime, ApplyingPropertiesAddsNoTimeAdvancingWork) {
    const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
    const auto loaded        = Load(Objects(false), loaded_values, &kLayerAuthored);
    ASSERT_NE(loaded, nullptr);
    loaded->runtime().Tick(1.0 / 60.0);
    const auto before = loaded->runtime().DescribeTimeAdvancingWork();
    EXPECT_EQ(before, 0u) << "the fixture is a still scene";

    loaded->runtime().ApplyProjectPropertyOverride(kLayerDocument);
    loaded->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(loaded->runtime().DescribeTimeAdvancingWork(), before);

    loaded->runtime().ApplyProjectPropertyOverride({});
    loaded->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(loaded->runtime().DescribeTimeAdvancingWork(), before);
}


// What a scene reads only while it loads. A slot a `scenetexture` property picks,
// and an effect a toggle switches on, are decided by the scene's first build and
// never revisited, so each is a load-only property.
const std::map<std::string, std::string> kLoadOnlyFiles = [] {
    std::map<std::string, std::string> files {
        { "/picture.json", R"({"width":64,"height":32,"material":"picture_mat.json"})" },
        { "/picture_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"],"usertextures":["backdrop"]}]})" },
        { "/materials/other.tex", "" },
    };
    // A material is named after its shader, so each effect gets its own.
    for (const std::string name : { "toggled", "chosen", "scripted", "plain", "caption" }) {
        files["/effects/" + name + "/effect.json"] =
            R"({"name":")" + name + R"(","passes":[{"material":"materials/effects/)" + name +
            R"(.json"}]})";
        files["/materials/effects/" + name + ".json"] =
            R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effects/)" +
            name + R"(","textures":[null]}]})";
        files["/shaders/effects/" + name + ".vert"] = std::string(kVert);
        files["/shaders/effects/" + name + ".frag"] = std::string(kFrag);
    }
    return files;
}();

// A layer a picture property fills, an image layer whose effects follow a toggle,
// a combo condition, a script and nothing, a layer the toggle also shows, and a
// slider only a live binding reads. `glow` is bound twice -- to an effect and to
// a layer's visibility -- so a hold on it has to reach both.
constexpr std::string_view kLoadOnlyLayers = R"([
  {"id":1,"name":"picture","image":"picture.json","visible":true},
  {"id":2,"name":"effects","image":"image.json","visible":true,
   "effects":[
     {"file":"effects/toggled/effect.json","id":10,
      "visible":{"user":"glow","value":false}},
     {"file":"effects/chosen/effect.json","id":11,
      "visible":{"user":{"name":"mode","condition":"2"},"value":false}},
     {"file":"effects/scripted/effect.json","id":12,
      "visible":{"script":"'use strict'; export function update(value) { return value; }","value":true}},
     {"file":"effects/plain/effect.json","id":13,"visible":true}
   ]},
  {"id":3,"name":"gate","image":"image.json","visible":{"user":"glow","value":false}},
  {"id":4,"name":"fader","image":"image.json","alpha":{"user":"opacity","value":1.0}}
])";
constexpr std::string_view kLoadOnlyText = R"({"id":5,"name":"caption",
  "text":"hello","font":"Arial","pointsize":10,"origin":[32,16,0],"size":"200 40","visible":true,
  "effects":[{"file":"effects/caption/effect.json","id":14,
              "visible":{"user":"captionglow","value":false}}]})";

std::string LoadOnlyObjects(bool with_text) {
    std::string objects(kLoadOnlyLayers);
    if (with_text) objects.insert(objects.rfind(']'), "," + std::string(kLoadOnlyText));
    return objects;
}

// What the project declares for them, and what a user's saved choices make of it.
const ProjectProperties kLoadOnlyAuthored {
    { "backdrop", RuntimeScalarValue::String("") },
    { "glow", RuntimeScalarValue::Bool(false) },
    { "captionglow", RuntimeScalarValue::Bool(false) },
    { "mode", RuntimeScalarValue::String("1") },
    { "opacity", RuntimeScalarValue::Float(1.0f) },
    { "unused", RuntimeScalarValue::Bool(false) },
};

// The materials of every effect the parser built, by name.
std::vector<std::string> BuiltEffects(Scene& scene) {
    std::vector<std::string> names;
    for (auto& [camera_name, camera] : scene.cameras) {
        (void)camera_name;
        if (! camera->HasImgEffect()) continue;
        auto& layer = *camera->GetImgEffect();
        for (std::size_t index = 0; index < layer.EffectCount(); ++index) {
            for (const auto& node : layer.GetEffect(index)->nodes) {
                if (node.sceneNode == nullptr || node.sceneNode->Mesh() == nullptr) continue;
                if (const auto* material = node.sceneNode->Mesh()->Material()) {
                    names.push_back(material->name);
                }
            }
        }
    }
    std::sort(names.begin(), names.end());
    return names;
}

// The texture the picture layer's slot ended up on.
std::string PictureTexture(LoadedScene& loaded) {
    auto* node = FindNode(*loaded.scene->sceneGraph, "picture");
    if (node == nullptr || node->Mesh() == nullptr || node->Mesh()->Material() == nullptr) {
        return "<none>";
    }
    const auto& textures = node->Mesh()->Material()->textures;
    return textures.empty() ? "<none>" : textures.front();
}

std::unique_ptr<LoadedScene> LoadOnly(bool with_text, const ProjectProperties& saved) {
    return Load(LoadOnlyObjects(with_text), MergeProjectProperties(kLoadOnlyAuthored, saved),
                &kLoadOnlyAuthored, kLoadOnlyFiles);
}

TEST(LoadOnlyProperties, UserPropertyNameReadsBothAuthoredForms) {
    EXPECT_EQ(UserPropertyName({ { "user", "toggle" }, { "value", true } }), "toggle");
    EXPECT_EQ(UserPropertyName({ { "user", { { "name", "mode" }, { "condition", "2" } } },
                                 { "value", true } }),
              "mode");
    // A combo that names its property without a condition is still bound to it.
    EXPECT_EQ(UserPropertyName({ { "user", { { "name", "mode" } } } }), "mode");
    EXPECT_EQ(UserPropertyName({ { "script", "return value;" }, { "value", true } }), "");
    EXPECT_EQ(UserPropertyName(nlohmann::json(true)), "");
    EXPECT_EQ(UserPropertyName(nlohmann::json()), "");
}

TEST(LoadOnlyProperties, ASlotNamesAPropertyOnlyInItsBareForm) {
    EXPECT_EQ(UserTexturePropertyName({ .name = "backdrop" }), "backdrop");
    // The slots the runtime supplies, and any other typed slot, name no property.
    EXPECT_EQ(UserTexturePropertyName({ .name = "$mediaThumbnail", .type = "system" }), "");
    EXPECT_EQ(UserTexturePropertyName({ .name = "other", .type = "something" }), "");
    EXPECT_EQ(UserTexturePropertyName({}), "");
}

TEST(LoadOnlyProperties, AScenetextureBindingEffectToggleAndComboConditionAreNoted) {
    const auto loaded = LoadOnly(false, {});
    ASSERT_NE(loaded, nullptr);
    // The slot a property picks, an effect a toggle builds, and an effect a combo
    // option builds. A scripted effect visibility is not bound to a property, an
    // effect with a plain value reads none, and `opacity` has a live binding.
    EXPECT_EQ(loaded->runtime().LoadOnlyProperties(), Names({ "backdrop", "glow", "mode" }));

    // The same, for an effect on a text object.
    const auto with_text = LoadOnly(true, {});
    ASSERT_NE(with_text, nullptr);
    EXPECT_EQ(with_text->runtime().LoadOnlyProperties(),
              Names({ "backdrop", "captionglow", "glow", "mode" }));

    // A scene with none of those has nothing to hold.
    const auto plain = Load(Objects(false), kLayerAuthored, nullptr);
    ASSERT_NE(plain, nullptr);
    EXPECT_TRUE(plain->runtime().LoadOnlyProperties().empty());
}

TEST(LoadOnlyProperties, APreviewHoldsALoadOnlyPropertyAndReportsItDeferred) {
    // The user saved the toggle on, so the scene loads with it on although the
    // project's own default is off.
    const auto loaded = LoadOnly(false, { { "glow", RuntimeScalarValue::Bool(true) } });
    ASSERT_NE(loaded, nullptr);
    auto& runtime = loaded->runtime();
    runtime.Tick(1.0 / 60.0);
    // The scripted effect keeps its authored value; the toggle is on.
    ASSERT_EQ(BuiltEffects(*loaded->scene),
              Names({ "effects/plain", "effects/scripted", "effects/toggled" }));

    // Only the slider is live; the toggle, the combo and the picture are held.
    const auto preview = runtime.PreviewProjectPropertyOverride({
        { "glow", RuntimeScalarValue::Bool(false) },
        { "mode", RuntimeScalarValue::String("2") },
        { "backdrop", RuntimeScalarValue::String("materials/other.tex") },
        { "opacity", RuntimeScalarValue::Float(0.5f) },
    });
    EXPECT_EQ(preview.changed, Names({ "opacity" }));
    EXPECT_EQ(preview.deferred, Names({ "backdrop", "glow", "mode" }));
    EXPECT_TRUE(runtime.projectProperties().at("glow").bool_value);
    EXPECT_EQ(runtime.projectProperties().at("mode").string_value, "1");
    EXPECT_EQ(runtime.projectProperties().at("backdrop").string_value, "");
    EXPECT_EQ(runtime.projectProperties().at("opacity").float_value, 0.5f);
    EXPECT_TRUE(runtime.FindPropertyValue("glow")->getBool());
    EXPECT_EQ(runtime.FindPropertyValue("mode")->getString(), "1");

    // A document that leaves the toggle out asks for the project's default, which
    // is not what the scene was built with.
    const auto left_out = runtime.PreviewProjectPropertyOverride({
        { "opacity", RuntimeScalarValue::Float(0.5f) },
    });
    EXPECT_TRUE(left_out.changed.empty());
    EXPECT_EQ(left_out.deferred, Names({ "glow" }));
    EXPECT_TRUE(runtime.projectProperties().at("glow").bool_value);

    // Asking for the value it was read with is not a request for anything else,
    // and the live slider still moves.
    const auto same = runtime.PreviewProjectPropertyOverride({
        { "glow", RuntimeScalarValue::Bool(true) },
        { "opacity", RuntimeScalarValue::Float(0.75f) },
    });
    EXPECT_EQ(same.changed, Names({ "opacity" }));
    EXPECT_TRUE(same.deferred.empty());

    // The empty document is the project's defaults: the slider returns and the
    // toggle, saved on, is the one thing still asked for.
    const auto reset = runtime.PreviewProjectPropertyOverride({});
    EXPECT_EQ(reset.changed, Names({ "opacity" }));
    EXPECT_EQ(reset.deferred, Names({ "glow" }));
    EXPECT_EQ(runtime.projectProperties().at("opacity").float_value, 1.0f);
}

// A property that also drives a layer's visibility is held for that layer too: a
// half applied property would show the toggle in one place and not the other.
TEST(LoadOnlyProperties, HeldEverywhereWhenAlsoBoundToALiveConsumer) {
    const auto loaded = LoadOnly(false, {});
    ASSERT_NE(loaded, nullptr);
    auto& runtime = loaded->runtime();
    runtime.Tick(1.0 / 60.0);
    ASSERT_FALSE(runtime.NodeVisible("gate"));

    const auto preview = runtime.PreviewProjectPropertyOverride({
        { "glow", RuntimeScalarValue::Bool(true) },
        { "opacity", RuntimeScalarValue::Float(0.5f) },
    });
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(preview.deferred, Names({ "glow" }));
    EXPECT_FALSE(runtime.NodeVisible("gate"));
    EXPECT_FALSE(runtime.FindPropertyValue("glow")->getBool());

    // The same document applied for real reaches the layer, so it is the hold,
    // not the binding, that kept it still.
    runtime.ApplyProjectPropertyOverride({ { "glow", RuntimeScalarValue::Bool(true) } });
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(runtime.NodeVisible("gate"));
}

// The audit is not vacuous: a fresh load with a new value builds a different
// effect and fills a different slot, which a running scene cannot do.
TEST(LoadOnlyProperties, AFreshParseWithTheNewValueDiffersWhichIsWhyItIsHeld) {
    const auto before = LoadOnly(false, {});
    ASSERT_NE(before, nullptr);
    const auto after = LoadOnly(false, { { "glow", RuntimeScalarValue::Bool(true) },
                                         { "mode", RuntimeScalarValue::String("2") },
                                         { "backdrop", RuntimeScalarValue::String("materials/other.tex") } });
    ASSERT_NE(after, nullptr);

    EXPECT_EQ(BuiltEffects(*before->scene), Names({ "effects/plain", "effects/scripted" }));
    EXPECT_EQ(BuiltEffects(*after->scene),
              Names({ "effects/chosen", "effects/plain", "effects/scripted", "effects/toggled" }));
    EXPECT_NE(PictureTexture(*before), PictureTexture(*after));

    // Held at the value the first scene read, a preview of the second document
    // leaves the first scene as it was.
    const auto effects = BuiltEffects(*before->scene);
    const auto texture = PictureTexture(*before);
    const auto preview = before->runtime().PreviewProjectPropertyOverride({
        { "glow", RuntimeScalarValue::Bool(true) },
        { "mode", RuntimeScalarValue::String("2") },
        { "backdrop", RuntimeScalarValue::String("materials/other.tex") },
    });
    before->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(preview.deferred, Names({ "backdrop", "glow", "mode" }));
    EXPECT_TRUE(preview.changed.empty());
    EXPECT_EQ(BuiltEffects(*before->scene), effects);
    EXPECT_EQ(PictureTexture(*before), texture);
}

// A solid placeholder: a solid instance layer whose model ships `util/white`,
// painted in a colour bound to the scheme colour, and whose slot a `scenetexture`
// property can fill. A preset fills it with a picture it installs beside the
// package (`files/...`).
constexpr std::string_view kPlaceholderLayer = R"([
  {"id":6,"name":"placeholder","image":"placeholder.json","size":"64 32","origin":[32,16,0],
   "color":{"user":"scheme","value":"0.1 0.1 0.1"},
   "instance":{"id":7,"textures":["util/white"],"usertextures":["picture"]}}
])";

const ProjectProperties kPlaceholderAuthored {
    { "picture", RuntimeScalarValue::String("") },
    { "scheme", RuntimeScalarValue::String("0.1 0.1 0.1") },
};

std::unique_ptr<LoadedScene> LoadPlaceholder(const ProjectProperties& saved) {
    // One opaque white pixel.
    constexpr unsigned char kPng[] {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const std::map<std::string, std::string> files {
        { "/placeholder.json",
          R"({"instanced":true,"solidlayer":true,"material":"placeholder_mat.json"})" },
        { "/placeholder_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["util/white"]}]})" },
        { "/materials/util/white.tex", "" },
        { "/files/picked.png", std::string(std::begin(kPng), std::end(kPng)) },
    };
    return Load(kPlaceholderLayer, MergeProjectProperties(kPlaceholderAuthored, saved),
                &kPlaceholderAuthored, files);
}

struct PlaceholderState {
    std::string        texture;
    std::vector<float> color;
};

// What the placeholder samples, and the `g_Color4` it multiplies that by.
PlaceholderState Placeholder(LoadedScene& loaded) {
    PlaceholderState state;
    auto*            node = FindNode(*loaded.scene->sceneGraph, "placeholder");
    if (node == nullptr || node->Mesh() == nullptr || node->Mesh()->Material() == nullptr) {
        return state;
    }
    const auto* material = node->Mesh()->Material();
    if (! material->textures.empty()) state.texture = material->textures.front();
    if (const auto found = material->customShader.constValues.find("g_Color4");
        found != material->customShader.constValues.end()) {
        for (std::size_t index = 0; index < found->second.size(); ++index) {
            state.color.push_back(found->second[index]);
        }
    }
    return state;
}

void ExpectColor(const PlaceholderState& state, float rgb) {
    ASSERT_EQ(state.color.size(), 4u);
    for (std::size_t index = 0; index < 3; ++index) EXPECT_NEAR(state.color[index], rgb, 1e-5f);
    EXPECT_NEAR(state.color[3], 1.0f, 1e-5f);
}

// The colour paints the placeholder, not the picture that replaces it: Wallpaper
// Engine shows a picture chosen for a placeholder as it is. Multiplied by a dark
// scheme colour, a preset's whole background drew black.
TEST(PlaceholderPicture, APictureChosenForAPlaceholderIsNotTintedByItsColour) {
    const auto chosen = LoadPlaceholder({ { "picture", RuntimeScalarValue::String("files/picked.png") } });
    ASSERT_NE(chosen, nullptr);
    chosen->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(Placeholder(*chosen).texture, "files/picked.png");
    ExpectColor(Placeholder(*chosen), 1.0f);

    // Nor does a scheme colour picked afterwards reach it.
    chosen->runtime().ApplyProjectPropertyOverride({
        { "picture", RuntimeScalarValue::String("files/picked.png") },
        { "scheme", RuntimeScalarValue::String("0.5 0.5 0.5") },
    });
    chosen->runtime().Tick(1.0 / 60.0);
    ExpectColor(Placeholder(*chosen), 1.0f);
}

TEST(PlaceholderPicture, WithNoPictureChosenThePlaceholderKeepsItsColour) {
    const auto plain = LoadPlaceholder({});
    ASSERT_NE(plain, nullptr);
    plain->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(Placeholder(*plain).texture, "util/white");
    ExpectColor(Placeholder(*plain), 0.1f);

    // The colour still follows the property it is bound to.
    plain->runtime().ApplyProjectPropertyOverride({ { "scheme", RuntimeScalarValue::String("0.5 0.5 0.5") } });
    plain->runtime().Tick(1.0 / 60.0);
    ExpectColor(Placeholder(*plain), 0.5f);

    // A picture of the user's own that can no longer be opened leaves the
    // placeholder, and so its colour, in place.
    const auto gone = LoadPlaceholder({ { "picture",
                                          RuntimeScalarValue::String(
                                              (std::filesystem::temp_directory_path() /
                                               "wpe-placeholder-picture-gone.png")
                                                  .string()) } });
    ASSERT_NE(gone, nullptr);
    gone->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(Placeholder(*gone).texture, "util/white");
    ExpectColor(Placeholder(*gone), 0.1f);
}

// A sound layer's volume is a slider like any other. It is read by a binding that
// writes an atomic the audio thread already reads, so following a property costs
// nothing per frame and needs no audio device to test.
class FakeSoundStream final : public audio::SoundStream {
public:
    uint64_t NextPcmData(void*, uint32_t) override { return 0; }
    void     PassDesc(const Desc&) override {}
};

std::shared_ptr<WPSoundStream> SilentStream(float volume) {
    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    return std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .volume = volume, .startsilent = true });
}

// What the project declares for the sound, and what a user saved over it.
const ProjectProperties kSoundAuthored {
    { "loudness", RuntimeScalarValue::Float(0.625f) },
    { "other", RuntimeScalarValue::Float(1.0f) },
};
const ProjectProperties kSoundSaved {
    { "loudness", RuntimeScalarValue::Float(0.125f) },
};

std::unique_ptr<SceneRuntimeContext> SoundRuntime(const ProjectProperties& saved) {
    return CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties          = MergeProjectProperties(kSoundAuthored, saved),
        .authored_project_properties = kSoundAuthored,
    });
}

TEST(SoundLayerVolume, FollowsTheBoundPropertyAndReturnsToTheAuthoredVolume) {
    auto runtime = SoundRuntime(kSoundSaved);
    ASSERT_NE(runtime, nullptr);
    // The layer starts at some other volume than the layer's authored 0.4, and
    // the saved choice is what the scene loads with.
    auto stream = SilentStream(1.0f);
    runtime->RegisterSoundLayer("music", stream);
    WPSoundParser::BindVolumeProperty(*runtime, stream, "loudness", 0.4f);
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.125f);

    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.2f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.2f);
    EXPECT_EQ(stream->Volume(), 0.2f);

    // A volume is never louder than full, whatever the slider is sent.
    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(3.0f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 1.0f);

    // The empty document is the project's own volume: not the saved choice the
    // scene loaded with, and not the volume the layer carries in the scene.
    runtime->ApplyProjectPropertyOverride({});
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.625f);

    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.5f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.5f);
    runtime->ResetProjectPropertyOverride();
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.625f);

    // A preview moves it the same way and has nothing to defer.
    const auto preview = runtime->PreviewProjectPropertyOverride(
        { { "loudness", RuntimeScalarValue::Float(0.3f) } });
    EXPECT_EQ(preview.changed, Names({ "loudness" }));
    EXPECT_TRUE(preview.deferred.empty());
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.3f);
}

TEST(SoundLayerVolume, AnUndeclaredOrNonNumericPropertyLeavesTheVolumeAlone) {
    // The project declares no such property: the layer keeps the volume it was
    // authored with, as a fresh load would give it.
    auto runtime = SoundRuntime({});
    ASSERT_NE(runtime, nullptr);
    auto stream = SilentStream(1.0f);
    runtime->RegisterSoundLayer("music", stream);
    WPSoundParser::BindVolumeProperty(*runtime, stream, "missing", 0.4f);
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.4f);
    runtime->ApplyProjectPropertyOverride({ { "other", RuntimeScalarValue::Float(0.1f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.4f);

    // No property named at all binds nothing.
    auto unbound = SilentStream(0.7f);
    runtime->RegisterSoundLayer("unbound", unbound);
    WPSoundParser::BindVolumeProperty(*runtime, unbound, "", 0.4f);
    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.1f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("unbound"), 0.7f);

    // A choice or a switch is not a loudness, so the volume stays where it was.
    auto words = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = { { "loudness", RuntimeScalarValue::String("loud") } },
    });
    ASSERT_NE(words, nullptr);
    auto spoken = SilentStream(0.9f);
    words->RegisterSoundLayer("music", spoken);
    WPSoundParser::BindVolumeProperty(*words, spoken, "loudness", 0.4f);
    EXPECT_EQ(words->SoundLayerVolume("music"), 0.9f);
    words->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Bool(true) } });
    EXPECT_EQ(words->SoundLayerVolume("music"), 0.9f);
    words->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.2f) } });
    EXPECT_EQ(words->SoundLayerVolume("music"), 0.2f);
    words->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::String("quiet") } });
    EXPECT_EQ(words->SoundLayerVolume("music"), 0.2f);
}

// Every document refreshes every property, changed or not. A volume a script set
// stays until the slider it follows is what moves.
TEST(SoundLayerVolume, AnUnchangedPropertyDoesNotUndoAVolumeAScriptSet) {
    auto runtime = SoundRuntime({});
    ASSERT_NE(runtime, nullptr);
    auto stream = SilentStream(1.0f);
    runtime->RegisterSoundLayer("music", stream);
    WPSoundParser::BindVolumeProperty(*runtime, stream, "loudness", 0.4f);
    ASSERT_EQ(runtime->SoundLayerVolume("music"), 0.625f);

    ASSERT_TRUE(runtime->SetSoundLayerVolume("music", 0.9f));
    runtime->ApplyProjectPropertyOverride({ { "other", RuntimeScalarValue::Float(0.5f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.9f);

    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.25f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.25f);

    ASSERT_TRUE(runtime->SetSoundLayerVolume("music", 0.9f));
    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.25f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.9f);
    runtime->ApplyProjectPropertyOverride({});
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.625f);
}

TEST(SoundLayerVolume, ADestroyedStreamIsNotTouched) {
    auto runtime = SoundRuntime({});
    ASSERT_NE(runtime, nullptr);
    auto stream = SilentStream(1.0f);
    std::weak_ptr<WPSoundStream> watcher = stream;
    runtime->RegisterSoundLayer("music", stream);
    WPSoundParser::BindVolumeProperty(*runtime, stream, "loudness", 0.4f);
    stream.reset();
    ASSERT_TRUE(watcher.expired()) << "the binding must not keep the stream alive";

    EXPECT_EQ(runtime->ApplyProjectPropertyOverride(
                  { { "loudness", RuntimeScalarValue::Float(0.2f) } }),
              Names({ "loudness" }));
    EXPECT_FALSE(runtime->HasSoundLayer("music"));
}

// The parser binds the layer it creates, from the volume the scene file writes as
// `{"user": ..., "value": ...}`; a plain number is the author's and stays.
TEST(SoundLayerVolume, ALoadedSoundLayerFollowsItsSliderAndAPlainOneDoesNot) {
    auto runtime = SoundRuntime(kSoundSaved);
    ASSERT_NE(runtime, nullptr);
    fs::VFS             vfs;
    audio::SoundManager sound { audio::SoundManager::OutputBackend::Null };
    const auto          parse = [&](const char* json) {
        wpscene::WPSoundObject object;
        EXPECT_TRUE(object.FromJson(nlohmann::json::parse(json), vfs));
        WPSoundParser::Parse(object, vfs, sound, runtime.get());
    };
    parse(R"({"name":"music","sound":["a.ogg"],"startsilent":true,
              "volume":{"user":"loudness","value":0.4}})");
    parse(R"({"name":"click","sound":["b.ogg"],"startsilent":true,"volume":0.75})");
    ASSERT_TRUE(runtime->HasSoundLayer("music"));
    ASSERT_TRUE(runtime->HasSoundLayer("click"));
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.125f);
    EXPECT_EQ(runtime->SoundLayerVolume("click"), 0.75f);

    runtime->ApplyProjectPropertyOverride({ { "loudness", RuntimeScalarValue::Float(0.5f) } });
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.5f);
    EXPECT_EQ(runtime->SoundLayerVolume("click"), 0.75f);

    runtime->ApplyProjectPropertyOverride({});
    EXPECT_EQ(runtime->SoundLayerVolume("music"), 0.625f);
    EXPECT_EQ(runtime->SoundLayerVolume("click"), 0.75f);
}

// ---- A flag bound to a choice ------------------------------------------------
//
// An author who turns a toggle into a combo keeps the layers the toggle showed
// bound to it by name alone, with no condition. A choice is a string, so what
// such a binding reads is the choice's own truth, the way a string property is
// read as a flag everywhere else (`true` or `1`), and not "never". A binding
// that names a condition compares the choice with it instead.

constexpr std::string_view kChoiceLayers = R"([
  {"id":1,"name":"bare","image":"image.json","visible":{"user":"mode","value":true}},
  {"id":2,"name":"is_one","image":"image.json",
   "visible":{"user":{"name":"mode","condition":"1"},"value":true}},
  {"id":3,"name":"is_two","image":"image.json",
   "visible":{"user":{"name":"mode","condition":"2"},"value":true}}
])";

struct ChoiceShows {
    bool bare { false };
    bool is_one { false };
    bool is_two { false };

    bool operator==(const ChoiceShows&) const = default;
};

ChoiceShows ChoiceAfterATick(LoadedScene& loaded) {
    loaded.runtime().Tick(1.0 / 60.0);
    return ChoiceShows {
        .bare   = loaded.runtime().NodeVisible("bare"),
        .is_one = loaded.runtime().NodeVisible("is_one"),
        .is_two = loaded.runtime().NodeVisible("is_two"),
    };
}

TEST(ChoiceProperty, ABindingWithoutAConditionReadsTheChoiceAsAFlag) {
    struct Case {
        const char* choice;
        ChoiceShows shows;
    };
    for (const auto& [choice, want] : std::vector<Case> {
             { "1", { .bare = true, .is_one = true } },
             { "true", { .bare = true } },
             { "TRUE", { .bare = true } },
             { "0", {} },
             { "false", {} },
             { "", {} },
             { "None", {} },
         }) {
        SCOPED_TRACE(choice);
        const ProjectProperties saved { { "mode", RuntimeScalarValue::String(choice) } };
        const auto              loaded = Load(kChoiceLayers, saved, nullptr);
        ASSERT_NE(loaded, nullptr);
        EXPECT_EQ(ChoiceAfterATick(*loaded), want);
    }

    // The condition compares the choice with itself, so `2` shows the layer that
    // waits for it and not the one that waits for `1`.
    const auto second = Load(kChoiceLayers, { { "mode", RuntimeScalarValue::String("2") } }, nullptr);
    ASSERT_NE(second, nullptr);
    EXPECT_EQ(ChoiceAfterATick(*second), (ChoiceShows { .is_two = true }));
}

// Picking another option on a running scene is the same as loading with it.
TEST(ChoiceProperty, ABindingWithoutAConditionFollowsTheChoiceWhileTheSceneRuns) {
    const auto loaded = Load(kChoiceLayers, { { "mode", RuntimeScalarValue::String("0") } }, nullptr);
    ASSERT_NE(loaded, nullptr);
    EXPECT_EQ(ChoiceAfterATick(*loaded), ChoiceShows {});

    loaded->runtime().ApplyProjectPropertyOverride({ { "mode", RuntimeScalarValue::String("1") } });
    EXPECT_EQ(ChoiceAfterATick(*loaded), (ChoiceShows { .bare = true, .is_one = true }));

    loaded->runtime().ApplyProjectPropertyOverride({ { "mode", RuntimeScalarValue::String("2") } });
    EXPECT_EQ(ChoiceAfterATick(*loaded), (ChoiceShows { .is_two = true }));

    loaded->runtime().ApplyProjectPropertyOverride({ { "mode", RuntimeScalarValue::String("false") } });
    EXPECT_EQ(ChoiceAfterATick(*loaded), ChoiceShows {});
}

// The value underneath: a flag connected to a string is the string's truth, and
// a condition still decides for itself.
TEST(ChoiceProperty, AConnectedFlagIsTheChoicesTruthAndAConditionStillCompares) {
    DynamicValue choice(std::string("1"));
    EXPECT_TRUE(choice.getBool());

    DynamicValue flag(false);
    flag.connect(&choice);
    EXPECT_TRUE(flag.getBool());
    choice.update(std::string("0"));
    EXPECT_FALSE(flag.getBool());
    choice.update(std::string("true"));
    EXPECT_TRUE(flag.getBool());

    DynamicValue second(false);
    second.attachCondition(ConditionInfo { .name = "mode", .condition = "2" });
    second.connect(&choice);
    EXPECT_FALSE(second.getBool());
    choice.update(std::string("2"));
    EXPECT_TRUE(second.getBool());
    EXPECT_FALSE(flag.getBool());
    // `1` is a true choice, but not the one this value waits for.
    choice.update(std::string("1"));
    EXPECT_FALSE(second.getBool());
}

// The reading itself. It is also what a script that returns a string is read with
// on every tick, so it is a comparison in place.
TEST(ChoiceProperty, AStringIsATrueFlagOnlyForTrueInAnyCaseOrOne) {
    for (const std::string choice : std::vector<std::string> { "1", "true", "TRUE", "True", "tRuE" }) {
        SCOPED_TRACE(choice);
        EXPECT_TRUE(StringIsTrue(choice));
        EXPECT_TRUE(RuntimeScalarValue::String(choice).asBool());
        EXPECT_TRUE(DynamicValue(choice).getBool());
    }
    for (const std::string choice : std::vector<std::string> {
             "", "0", "2", "01", "11", "-1", "1 ", " 1", "false", "yes", "tru", "truee", "true ",
             " true", "t rue", "None", std::string("tru\0", 4), std::string("\xff" "rue") }) {
        SCOPED_TRACE(choice);
        EXPECT_FALSE(StringIsTrue(choice));
        EXPECT_FALSE(RuntimeScalarValue::String(choice).asBool());
        EXPECT_FALSE(DynamicValue(choice).getBool());
    }
}

// A combo whose project.json value is a number reaches the scene as a number,
// and a number is a flag by being other than zero. The choice the app sends is the
// option's key, a string, which only `1` and `true` turn on. The two readings
// differ for choices other than 0 and 1 (the bare layer is all this pins: how a
// conditioned binding reads a number is not part of this rule).
TEST(ChoiceProperty, ANumberDeclaredAsTheChoiceIsAFlagByBeingNonZero) {
    struct Case {
        RuntimeScalarValue choice;
        bool               bare;
    };
    for (const auto& [choice, bare] : std::vector<Case> {
             { RuntimeScalarValue::Float(0.0f), false },
             { RuntimeScalarValue::Float(1.0f), true },
             { RuntimeScalarValue::Float(2.0f), true },
             { RuntimeScalarValue::String("0"), false },
             { RuntimeScalarValue::String("1"), true },
             { RuntimeScalarValue::String("2"), false },
         }) {
        SCOPED_TRACE(choice.asString() + "/" + std::to_string(choice.asFloat()));
        const auto loaded = Load(kChoiceLayers, { { "mode", choice } }, nullptr);
        ASSERT_NE(loaded, nullptr);
        EXPECT_EQ(ChoiceAfterATick(*loaded).bare, bare);
    }
}

// An effect a choice switches on is built when the scene loads, by the same
// reading of the choice as a layer's visibility.
TEST(ChoiceProperty, AnEffectBoundToAChoiceWithoutAConditionIsBuiltForATrueChoice) {
    constexpr std::string_view layers = R"([
      {"id":1,"name":"effects","image":"image.json","visible":true,
       "effects":[
         {"file":"effects/chosen/effect.json","id":10,
          "visible":{"user":"mode","value":false}},
         {"file":"effects/toggled/effect.json","id":11,
          "visible":{"user":{"name":"mode","condition":"2"},"value":false}}
       ]}
    ])";
    struct Case {
        const char*              choice;
        std::vector<std::string> built;
    };
    for (const auto& [choice, built] : std::vector<Case> {
             { "1", Names({ "effects/chosen" }) },
             { "true", Names({ "effects/chosen" }) },
             { "TRUE", Names({ "effects/chosen" }) },
             { "0", {} },
             { "false", {} },
             { "None", {} },
             { "2", Names({ "effects/toggled" }) },
         }) {
        SCOPED_TRACE(choice);
        const auto loaded = Load(layers, { { "mode", RuntimeScalarValue::String(choice) } },
                                 nullptr, kLoadOnlyFiles);
        ASSERT_NE(loaded, nullptr);
        EXPECT_EQ(BuiltEffects(*loaded->scene), built);
    }
}

// ---- The engine's own command ------------------------------------------------
//
// A document reaches a running scene as a property of the wallpaper, is parsed on
// the main looper and is shown on the render looper, the only thread that ticks a
// runtime. The scenes below have a runtime and nothing to draw, so no surface,
// window or device is involved: the command reaches the runtime either way.

std::shared_ptr<Scene> RuntimeOnlyScene(const ProjectProperties& saved_choices) {
    auto scene          = std::make_shared<Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties          = Loaded(saved_choices),
        .authored_project_properties = kAuthored,
    });
    return scene;
}

// Returns once the main looper has handled everything posted before the call:
// installing a pointer callback replays the current capability from that looper.
// Bounded only so a broken looper fails the test instead of hanging it.
bool MainLooperCaughtUp(SceneWallpaper& wallpaper) {
    struct Replay {
        std::mutex              mutex;
        std::condition_variable changed;
        bool                    seen { false };
    };
    auto replay = std::make_shared<Replay>();
    wallpaper.setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK,
                                std::make_shared<PointerInputCallback>([replay](bool) {
                                    std::scoped_lock lock(replay->mutex);
                                    replay->seen = true;
                                    replay->changed.notify_all();
                                }));
    std::unique_lock lock(replay->mutex);
    return replay->changed.wait_for(lock, std::chrono::seconds(5), [&] { return replay->seen; });
}

// Returns once both loopers have handled everything posted before the call: a
// render round trip, a main round trip, and a render round trip again for whatever
// the main looper forwarded.
bool Settle(SceneWallpaper& wallpaper) {
    return wallpaper.beginSurfaceReconfigure() && MainLooperCaughtUp(wallpaper) &&
           wallpaper.beginSurfaceReconfigure();
}

void Preview(SceneWallpaper& wallpaper, const std::string& document) {
    wallpaper.setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON, document);
}

TEST(ScenePropertyPreview, ADocumentReachesTheRunningSceneAndTheLoadOnlyPropertiesStayPut) {
    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    // `c` is read once, as a toggled effect's switch is, and was saved as "saved".
    auto scene = RuntimeOnlyScene({ { "a", RuntimeScalarValue::Float(5.0f) },
                                    { "c", RuntimeScalarValue::String("saved") } });
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.NoteLoadOnlyProperty("c");
    SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(Settle(wallpaper));
    ASSERT_EQ(runtime.projectProperties().at("a").float_value, 5.0f);

    // `a` is left out, so it is the project's own value again, not the saved 5;
    // `b` is new; `c` cannot change on a running scene.
    Preview(wallpaper, R"({"b":7,"c":"asked"})");
    ASSERT_TRUE(Settle(wallpaper));
    EXPECT_EQ(runtime.projectProperties().at("a").float_value, 1.0f);
    EXPECT_EQ(runtime.projectProperties().at("b").float_value, 7.0f);
    EXPECT_EQ(runtime.projectProperties().at("c").string_value, "saved");
    ASSERT_NE(runtime.FindPropertyValue("b"), nullptr);
    EXPECT_EQ(runtime.FindPropertyValue("b")->getFloat(), 7.0f);
    EXPECT_EQ(runtime.FindPropertyValue("a")->getFloat(), 1.0f);

    // A later document is the whole state again: the empty one is the project's
    // defaults, with the one property that is held still where the scene read it.
    Preview(wallpaper, "{}");
    ASSERT_TRUE(Settle(wallpaper));
    ProjectProperties expected = kAuthored;
    expected["c"]              = RuntimeScalarValue::String("saved");
    ExpectSameTable(runtime.projectProperties(), expected);
    wallpaper.shutdown();
}

// Hundreds of documents arrive while the render thread is busy with the first one.
// The newest wins and the rest cost nothing: the scene is told twice in all, once
// for the document that held the thread and once for the last of the burst.
TEST(ScenePropertyPreview, ABurstOfDocumentsCostsOneUpdateAndEndsOnTheLastOne) {
    struct Gate {
        std::mutex              mutex;
        std::condition_variable changed;
        bool                    armed { false };
        bool                    entered { false };
        bool                    release { false };
        std::vector<float>      seen;
    };
    auto gate = std::make_shared<Gate>();

    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    auto scene = RuntimeOnlyScene({});
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    // Every document refreshes every property, so this runs once per document.
    // The first one holds the render thread here until the burst is queued.
    runtime.RegisterDynamicValueListener(
        ResolveFloatSetting(runtime, { { "user", "a" }, { "value", 1.0 } }),
        [gate](const DynamicValue& value) {
            std::unique_lock lock(gate->mutex);
            if (! gate->armed) return;
            gate->seen.push_back(value.getFloat());
            if (gate->seen.size() != 1) return;
            gate->entered = true;
            gate->changed.notify_all();
            gate->changed.wait_for(lock, std::chrono::seconds(5), [&] { return gate->release; });
        });
    SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(Settle(wallpaper));
    {
        std::scoped_lock lock(gate->mutex);
        gate->armed = true;
    }

    Preview(wallpaper, R"({"a":1000})");
    {
        std::unique_lock lock(gate->mutex);
        ASSERT_TRUE(gate->changed.wait_for(lock, std::chrono::seconds(5),
                                           [&] { return gate->entered; }))
            << "the first document never reached the render thread";
    }
    constexpr int kBurst = 500;
    for (int index = 1; index <= kBurst; ++index) {
        Preview(wallpaper, R"({"a":)" + std::to_string(index) + "}");
    }
    // The main looper has parsed and staged all of them; the render thread is
    // still inside the first document.
    ASSERT_TRUE(MainLooperCaughtUp(wallpaper));
    {
        std::scoped_lock lock(gate->mutex);
        gate->release = true;
        gate->changed.notify_all();
    }
    ASSERT_TRUE(Settle(wallpaper));

    std::scoped_lock lock(gate->mutex);
    EXPECT_EQ(gate->seen, (std::vector<float> { 1000.0f, static_cast<float>(kBurst) }))
        << "a burst of documents was shown one by one";
    // And it queued one command behind the first, not one each: every command an
    // idle scene handles is a frame it draws.
    EXPECT_EQ(SceneWallpaperInputTestAccess::PropertyPreviewCommandsHandled(wallpaper), 2u);
    EXPECT_EQ(runtime.projectProperties().at("a").float_value, static_cast<float>(kBurst));
    wallpaper.shutdown();
}

TEST(ScenePropertyPreview, ABadDocumentOrASceneThatIsNotThereYetChangesNothing) {
    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());

    // No scene yet: the document is dropped, and the scene that arrives next is
    // not given it.
    Preview(wallpaper, R"({"a":9})");
    ASSERT_TRUE(Settle(wallpaper));
    const ProjectProperties saved { { "a", RuntimeScalarValue::Float(5.0f) } };
    auto                    scene = RuntimeOnlyScene(saved);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(Settle(wallpaper));
    ExpectSameTable(runtime.projectProperties(), Loaded(saved));

    // Anything that is not a JSON object is refused whole.
    for (const std::string bad : { std::string(), std::string("not json"), std::string("[1,2]"),
                                   std::string("null"), std::string("7"),
                                   std::string(R"({"a":)") }) {
        SCOPED_TRACE("document: " + bad);
        Preview(wallpaper, bad);
        ASSERT_TRUE(Settle(wallpaper));
        ExpectSameTable(runtime.projectProperties(), Loaded(saved));
    }

    // And the refusals left nothing behind that a good document trips over.
    Preview(wallpaper, R"({"a":2})");
    ASSERT_TRUE(Settle(wallpaper));
    EXPECT_EQ(runtime.projectProperties().at("a").float_value, 2.0f);
    wallpaper.shutdown();
}

// A document is for the scene that is running when it is shown. Nothing is kept
// for the next one, so another wallpaper that happens to share a property name
// shows its own loaded value, and the old scene is not touched again.
TEST(ScenePropertyPreview, AReloadedSceneShowsItsOwnLoadedValuesAndNothingLeaksAcrossScenes) {
    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    auto first = RuntimeOnlyScene({ { "a", RuntimeScalarValue::Float(5.0f) } });
    ASSERT_NE(first->runtime, nullptr);
    SceneWallpaperInputTestAccess::PostScene(wallpaper, first);
    ASSERT_TRUE(Settle(wallpaper));
    Preview(wallpaper, R"({"a":9,"b":8})");
    ASSERT_TRUE(Settle(wallpaper));
    ASSERT_EQ(first->runtime->projectProperties().at("a").float_value, 9.0f);
    ASSERT_EQ(first->runtime->projectProperties().at("b").float_value, 8.0f);

    const ProjectProperties other_saved { { "a", RuntimeScalarValue::Float(3.0f) } };
    auto                    second = RuntimeOnlyScene(other_saved);
    ASSERT_NE(second->runtime, nullptr);
    SceneWallpaperInputTestAccess::PostScene(wallpaper, second);
    ASSERT_TRUE(Settle(wallpaper));
    ExpectSameTable(second->runtime->projectProperties(), Loaded(other_saved));

    // The next document is for the scene now running.
    Preview(wallpaper, R"({"a":4})");
    ASSERT_TRUE(Settle(wallpaper));
    EXPECT_EQ(second->runtime->projectProperties().at("a").float_value, 4.0f);
    EXPECT_EQ(first->runtime->projectProperties().at("a").float_value, 9.0f);
    wallpaper.shutdown();
}

// A preview that holds load-only properties and moves live ones adds no work that
// advances with time, so the on-demand idle analysis needs no change for it.
TEST(ScenePropertyPreview, PreviewingAddsNoTimeAdvancingWork) {
    // Without the effect a script switches: that script runs every frame, as a
    // visibility script must, which would hide any work a preview added.
    std::string objects = LoadOnlyObjects(false);
    const std::string scripted =
        R"(     {"file":"effects/scripted/effect.json","id":12,
      "visible":{"script":"'use strict'; export function update(value) { return value; }","value":true}},
)";
    const auto at = objects.find(scripted);
    ASSERT_NE(at, std::string::npos);
    objects.erase(at, scripted.size());
    const auto loaded =
        Load(objects, kLoadOnlyAuthored, &kLoadOnlyAuthored, kLoadOnlyFiles);
    ASSERT_NE(loaded, nullptr);
    auto& runtime = loaded->runtime();
    runtime.Tick(1.0 / 60.0);
    const auto before = runtime.DescribeTimeAdvancingWork();
    EXPECT_EQ(before, 0u) << "the fixture is a still scene";

    runtime.PreviewProjectPropertyOverride({ { "glow", RuntimeScalarValue::Bool(true) },
                                             { "mode", RuntimeScalarValue::String("2") },
                                             { "opacity", RuntimeScalarValue::Float(0.5f) } });
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(runtime.DescribeTimeAdvancingWork(), before);

    runtime.PreviewProjectPropertyOverride({});
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(runtime.DescribeTimeAdvancingWork(), before);
}

} // namespace
} // namespace wallpaper
