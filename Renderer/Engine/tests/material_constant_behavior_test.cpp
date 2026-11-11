// Material shader constants: how a registered constant follows a live value, how the keys of a
// scene-file material find their uniforms, and how a layer copied from a template inherits its
// source's bindings. No device or files; scenes are assembled in memory.

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Utils/Logging.h"
#include "WPShaderParser.hpp"
#include "WPSceneParser.hpp"
#include "wpscene/WPMaterial.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr double kFrame = 1.0 / 60.0;

std::unique_ptr<SceneRuntimeContext> MakeRuntime(ProjectProperties properties = {})
{
    return CreateSceneRuntimeContext(SceneRuntimeBootstrap { .project_properties = std::move(properties) });
}

// A constant of `size` components that follows the project property `property`.
std::unique_ptr<DynamicValue> Follow(SceneRuntimeContext& rt, std::unique_ptr<DynamicValue> value,
                                     const char* property)
{
    DynamicValue* source = rt.FindPropertyValue(property);
    EXPECT_NE(source, nullptr) << property;
    if (source != nullptr) value->connect(source);
    return value;
}

std::unique_ptr<DynamicValue> FollowColor(SceneRuntimeContext& rt, const char* property)
{
    return Follow(rt, std::make_unique<DynamicValue>(linalg::Vector3f(0.0f, 0.0f, 0.0f)), property);
}

void ExpectLanes(const SceneMaterial& material, const char* name, std::vector<float> lanes)
{
    const auto found = material.customShader.constValues.find(name);
    ASSERT_NE(found, material.customShader.constValues.end()) << name;
    ASSERT_EQ(found->second.size(), lanes.size()) << name;
    for (std::size_t i = 0; i < lanes.size(); ++i) {
        EXPECT_FLOAT_EQ(found->second[i], lanes[i]) << name << "[" << i << "]";
    }
}

// ---- a constant bound to a project property ----------------------------------------------------

TEST(MaterialConstants, ABoundConstantFollowsItsPropertyAtRegistrationAndAfterEveryChange)
{
    auto rt = MakeRuntime({ { "colorprop", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
                            { "alphaprop", RuntimeScalarValue::Float(0.75f) } });
    auto material = std::make_shared<SceneMaterial>();
    rt->RegisterMaterialConstant(material, "g_Color", FollowColor(*rt, "colorprop"));
    rt->RegisterMaterialConstant(
        material, "g_UserAlpha", Follow(*rt, std::make_unique<DynamicValue>(1.0f), "alphaprop"));

    // Written at registration, before any tick.
    ExpectLanes(*material, "g_Color", { 1.0f, 0.8117647f, 0.8705882f });
    ExpectLanes(*material, "g_UserAlpha", { 0.75f });

    rt->ApplyProjectPropertyOverride({ { "colorprop", RuntimeScalarValue::String("0.25 0.5 0.75") },
                                       { "alphaprop", RuntimeScalarValue::Float(0.25f) } });
    rt->Tick(kFrame);
    ExpectLanes(*material, "g_Color", { 0.25f, 0.5f, 0.75f });
    ExpectLanes(*material, "g_UserAlpha", { 0.25f });

    // A quiet frame leaves both where they were.
    rt->Tick(kFrame);
    ExpectLanes(*material, "g_Color", { 0.25f, 0.5f, 0.75f });
    ExpectLanes(*material, "g_UserAlpha", { 0.25f });
}

TEST(MaterialConstants, ARegistrationWithoutAMaterialANameOrAValueWritesNothing)
{
    auto rt = MakeRuntime({ { "alphaprop", RuntimeScalarValue::Float(0.5f) } });
    auto material = std::make_shared<SceneMaterial>();

    rt->RegisterMaterialConstant(material, "", Follow(*rt, std::make_unique<DynamicValue>(1.0f), "alphaprop"));
    rt->RegisterMaterialConstant(material, "g_Alpha", nullptr);
    rt->RegisterMaterialConstant(nullptr, "g_Alpha", Follow(*rt, std::make_unique<DynamicValue>(1.0f), "alphaprop"));
    rt->Tick(kFrame);
    EXPECT_TRUE(material->customShader.constValues.empty());
}

// ---- a constant behind a property script --------------------------------------------------------

TEST(MaterialConstants, AScriptedConstantRunsEveryTickAndSeesLivePropertiesAndTheEngineClock)
{
    auto rt = MakeRuntime({ { "speed", RuntimeScalarValue::Float(0.5f) } });
    const char* module = R"js(
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'speed', value: 1.0 })
            .finish();
        export function update(value) {
            return new Vec3(scriptProperties.speed, engine.runtime, 0);
        }
    )js";
    const nlohmann::json setting = { { "script", module },
                                     { "scriptproperties", { { "speed", { { "user", "speed" }, { "value", 1.0 } } } } },
                                     { "value", "1 1 1" } };
    auto material = std::make_shared<SceneMaterial>();
    rt->RegisterMaterialConstant(material, "g_Tint", ResolveVec3Setting(*rt, setting, "layer"));

    rt->Tick(0.25);
    ASSERT_TRUE(material->customShader.constValues.contains("g_Tint"));
    ASSERT_EQ(material->customShader.constValues.at("g_Tint").size(), 3u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[0], 0.5f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[1], 0.25f);

    rt->ApplyProjectPropertyOverride({ { "speed", RuntimeScalarValue::Float(0.75f) } });
    rt->Tick(0.5);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[0], 0.75f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[1], 0.75f);
    EXPECT_EQ(rt->scriptErrorCount(), 0u);

    rt->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[0], 0.75f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[1], 1.75f);
}

// ---- scene-file keys and the uniforms they name -------------------------------------------------

std::vector<std::string>* g_errors = nullptr;

void CaptureErrors(int level, const char*, int, const char* message)
{
    if (level == LOGLEVEL_ERROR && g_errors != nullptr) g_errors->emplace_back(message);
}

// Installs the capture for one scope and removes it however the scope ends.
class ErrorCapture {
public:
    ErrorCapture() { g_errors = &m_messages; SetWallpaperLogCallback(&CaptureErrors); }
    ~ErrorCapture() { SetWallpaperLogCallback(nullptr); g_errors = nullptr; }

    bool Saw(const std::string& needle) const
    {
        for (const auto& message : m_messages) {
            if (message.find(needle) != std::string::npos) return true;
        }
        return false;
    }

private:
    std::vector<std::string> m_messages;
};

struct KeyedMaterial {
    wpscene::WPMaterial material;
    WPShaderInfo        info;
    SceneMaterial       scene;

    KeyedMaterial& Key(const std::string& key, std::vector<float> lanes)
    {
        wpscene::WPConstantShaderValue constant;
        constant.value = std::move(lanes);
        material.constantshadervalues[key] = std::move(constant);
        return *this;
    }
    KeyedMaterial& Alias(const std::string& key, const std::string& uniform)
    {
        info.alias[key] = uniform;
        return *this;
    }
    void Load() { LoadMaterialConstantShaderValues(scene, material, info); }
};

// The shader names the Start/End pair and one more constant, but not the bare key.
KeyedMaterial RangeFixture(bool declareEnd = true)
{
    KeyedMaterial f;
    f.Alias("frequencyRangeStart", "u_FrequencyRangeStart").Alias("volumeScale", "u_VolumeScale");
    if (declareEnd) f.Alias("frequencyRangeEnd", "u_FrequencyRangeEnd");
    return f;
}

constexpr const char* kNotFound = "ShaderValue: frequencyRange not found in glsl";

TEST(MaterialConstantKeys, ASplitStartEndPairStandsInForTheKeyAndIsNotReported)
{
    KeyedMaterial f = RangeFixture();
    f.Key("frequencyRange", { 0.0f, 31.73f }).Key("frequencyRangeStart", { 0.0f })
        .Key("frequencyRangeEnd", { 63.0f }).Key("volumeScale", { 0.8f });
    ErrorCapture capture;
    f.Load();

    EXPECT_FALSE(capture.Saw(kNotFound));
    EXPECT_TRUE(f.scene.customShader.constValues.contains("u_FrequencyRangeStart"));
    EXPECT_TRUE(f.scene.customShader.constValues.contains("u_FrequencyRangeEnd"));
    EXPECT_TRUE(f.scene.customShader.constValues.contains("u_VolumeScale"));
    ExpectLanes(f.scene, "u_FrequencyRangeEnd", { 63.0f });
    ExpectLanes(f.scene, "u_VolumeScale", { 0.8f });
}

TEST(MaterialConstantKeys, AKeyWithoutAUniformOrACompletePairIsReported)
{
    {
        KeyedMaterial f = RangeFixture();
        f.Key("frequencyRange", { 0.0f, 31.73f });
        ErrorCapture capture;
        f.Load();
        EXPECT_TRUE(capture.Saw(kNotFound));
    }
    {
        // The material supplies only half of the pair.
        KeyedMaterial f = RangeFixture();
        f.Key("frequencyRange", { 0.0f, 31.73f }).Key("frequencyRangeStart", { 0.0f });
        ErrorCapture capture;
        f.Load();
        EXPECT_TRUE(capture.Saw(kNotFound));
    }
    {
        // The material supplies both, but the shader declares only one of them.
        KeyedMaterial f = RangeFixture(/*declareEnd=*/false);
        f.Key("frequencyRange", { 0.0f, 31.73f }).Key("frequencyRangeStart", { 0.0f })
            .Key("frequencyRangeEnd", { 63.0f });
        ErrorCapture capture;
        f.Load();
        EXPECT_TRUE(capture.Saw(kNotFound));
    }
    {
        // A key without lanes writes no entry even though its uniform exists.
        KeyedMaterial f = RangeFixture();
        f.Key("volumeScale", {});
        ErrorCapture capture;
        f.Load();
        EXPECT_FALSE(f.scene.customShader.constValues.contains("u_VolumeScale"));
    }
}

// A scene whose every material carries the same leftover key (a model importer's `Alpha`
// on hundreds of models) says it once, with the count, and never as an error: a scene
// parse holds a tally, and a load under one reports nothing of its own.
TEST(MaterialConstantKeys, ATallyGathersTheLeftoverKeysOfAScopeAndSaysThemOnce)
{
    KeyedMaterial ranged = RangeFixture();
    ranged.Key("frequencyRange", { 0.0f, 31.73f }).Key("volumeScale", { 0.8f });
    KeyedMaterial plain;
    plain.Alias("color", "g_TintColor");
    plain.Key("Alpha", { 1.0f }).Key("Color", { 1.0f, 1.0f, 1.0f }).Key("color", { 0.5f, 0.5f, 0.5f });

    ErrorCapture capture;
    {
        UnmatchedConstantTally tally;
        for (int repeat = 0; repeat < 3; ++repeat) plain.Load();
        ranged.Load();
        EXPECT_EQ(tally.Summary(), "Alpha x3, Color x3, frequencyRange x1");
    }
    EXPECT_FALSE(capture.Saw("not found in glsl")) << "a gathered key is not also an error of its own";
    // The constants that do name a uniform are loaded as before.
    ExpectLanes(plain.scene, "g_TintColor", { 0.5f, 0.5f, 0.5f });
    ExpectLanes(ranged.scene, "u_VolumeScale", { 0.8f });

    // With no tally the same load is reported on its own, as a constant loaded outside a
    // scene parse always was.
    plain.Load();
    EXPECT_TRUE(capture.Saw("ShaderValue: Alpha not found in glsl"));
}

TEST(MaterialConstantKeys, ATallyNamesTheFirstKeysAndCountsTheRestAndTheInnermostTakesThem)
{
    UnmatchedConstantTally outer;
    {
        UnmatchedConstantTally inner;
        for (int index = 0; index < 14; ++index) {
            KeyedMaterial f;
            f.Key("key" + std::string(index < 10 ? "0" : "") + std::to_string(index), { 1.0f });
            f.Load();
        }
        const std::string summary = inner.Summary();
        EXPECT_EQ(summary.find("key00 x1, key01 x1"), 0u);
        EXPECT_NE(summary.find("key11 x1, and 2 more"), std::string::npos) << summary;
        EXPECT_EQ(summary.find("key12"), std::string::npos) << summary;
    }
    EXPECT_TRUE(outer.Summary().empty()) << "the inner scope took every key";
    KeyedMaterial f;
    f.Key("late", { 1.0f });
    f.Load();
    EXPECT_EQ(outer.Summary(), "late x1") << "the outer scope takes them again once the inner one ended";
}

// ---- a layer copied from a template -------------------------------------------------------------

TEST(MaterialConstants, ALayerCopiedFromATemplateKeepsTheTemplatesConstantBindings)
{
    Scene scene;
    auto  rt = MakeRuntime({ { "colorprop", RuntimeScalarValue::String("1 0.8 0.6") } });
    rt->AttachScene(&scene);

    auto source = std::make_shared<SceneNode>(linalg::Vector3f(100.0f, 50.0f, 0.0f),
                                              linalg::Vector3f(1.0f, 1.0f, 1.0f),
                                              linalg::Vector3f(0.0f, 0.0f, 0.0f), "source");
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    source->AddMesh(mesh);
    scene.sceneGraph->AppendChild(source);
    rt->RegisterNode("source", source.get());
    rt->RegisterLayerTemplate("models/workshop/1234567/bar.json", source, { 20.0f, 10.0f });
    auto sourceMaterial = mesh->MaterialSlotPtr(0);
    ASSERT_NE(sourceMaterial, nullptr);
    rt->RegisterMaterialConstant(sourceMaterial, "g_Color", FollowColor(*rt, "colorprop"));

    const std::string made = rt->CreateLayerFromTemplate("models/bar.json", "source");
    ASSERT_FALSE(made.empty());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    auto copy = scene.sceneGraph->GetChildren().back();
    ASSERT_NE(copy->Mesh(), nullptr);
    auto copyMaterial = copy->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(copyMaterial, nullptr);
    EXPECT_NE(copyMaterial.get(), sourceMaterial.get());
    ExpectLanes(*copyMaterial, "g_Color", { 1.0f, 0.8f, 0.6f });  // synced at creation

    // A second copy is bound too.
    ASSERT_FALSE(rt->CreateLayerFromTemplate("models/bar.json", "source").empty());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 3u);
    auto secondMaterial = scene.sceneGraph->GetChildren().back()->Mesh()->MaterialSlotPtr(0);

    rt->ApplyProjectPropertyOverride({ { "colorprop", RuntimeScalarValue::String("0.2 0.4 0.6") } });

    // A copy made before the next tick starts from the live value, not the template's last frame.
    ASSERT_FALSE(rt->CreateLayerFromTemplate("models/bar.json", "source").empty());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 4u);
    auto lateMaterial = scene.sceneGraph->GetChildren().back()->Mesh()->MaterialSlotPtr(0);
    ExpectLanes(*lateMaterial, "g_Color", { 0.2f, 0.4f, 0.6f });

    rt->Tick(kFrame);
    ExpectLanes(*sourceMaterial, "g_Color", { 0.2f, 0.4f, 0.6f });
    ExpectLanes(*copyMaterial, "g_Color", { 0.2f, 0.4f, 0.6f });
    ExpectLanes(*secondMaterial, "g_Color", { 0.2f, 0.4f, 0.6f });
    ExpectLanes(*lateMaterial, "g_Color", { 0.2f, 0.4f, 0.6f });
}

} // namespace
} // namespace wallpaper
