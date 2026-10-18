#include "Interface/IImageParser.h"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/include/Scene/Scene.h"
#include "Scene/include/Scene/SceneMaterial.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Utils/Logging.h"
#include "WPShaderParser.hpp"
#include "WPSceneParser.hpp"
#include "wpscene/WPMaterial.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace
{

class NullImageParser final : public IImageParser {
public:
    std::shared_ptr<Image> Parse(const std::string&) override { return nullptr; }
    ImageHeader            ParseHeader(const std::string&) override { return {}; }
};

class CountingImageParser final : public IImageParser {
public:
    int parse_calls { 0 };
    int header_calls { 0 };

    std::shared_ptr<Image> Parse(const std::string& name) override {
        ++parse_calls;
        auto image           = std::make_shared<Image>();
        image->key           = name;
        image->header.width  = 1;
        image->header.height = 1;
        return image;
    }

    ImageHeader ParseHeader(const std::string&) override {
        ++header_calls;
        return {};
    }
};

TEST(MediaThumbnailTexture, KeepsPreviousCoverAndClearsBothWhenDisabled) {
    RuntimeImageSource images(std::make_unique<NullImageParser>());
    const uint8_t first[] = {255, 0, 0, 255};
    const uint8_t second[] = {0, 255, 0, 255};
    const uint8_t empty[] = {0, 0, 0, 0};
    images.SetRgbaImage("$mediaThumbnail", 1, 1, first, sizeof(first));
    auto old_cover = images.Parse("$mediaThumbnail");
    images.SetRgbaImage("$mediaThumbnail", 1, 1, second, sizeof(second));
    EXPECT_EQ(images.Parse("$mediaPreviousThumbnail"), old_cover);
    EXPECT_NE(images.Parse("$mediaThumbnail"), old_cover);
    images.SetRgbaImage("$mediaThumbnail", 1, 1, empty, sizeof(empty));
    EXPECT_EQ(images.Parse("$mediaPreviousThumbnail"), images.Parse("$mediaThumbnail"));
    std::vector<std::string> textures;
    ApplySystemUserTextures(textures, {{.name = "$mediaPreviousThumbnail", .type = "system"}});
    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "$mediaPreviousThumbnail");
}

std::unique_ptr<DynamicValue> BoundValue(SceneRuntimeContext& runtime,
                                         std::string_view     property_name,
                                         std::unique_ptr<DynamicValue> value) {
    if (auto* property = runtime.FindPropertyValue(property_name); property != nullptr) {
        value->connect(property);
    }
    return value;
}

std::vector<std::string>* captured_error_logs = nullptr;

void CaptureErrorLogs(int level, const char*, int, const char* message) {
    if (level == LOGLEVEL_ERROR && captured_error_logs != nullptr) {
        captured_error_logs->push_back(message == nullptr ? "" : message);
    }
}

class ScopedErrorLogCapture {
public:
    explicit ScopedErrorLogCapture(std::vector<std::string>& logs) {
        captured_error_logs = &logs;
        SetWallpaperLogCallback(CaptureErrorLogs);
    }

    ~ScopedErrorLogCapture() {
        SetWallpaperLogCallback(nullptr);
        captured_error_logs = nullptr;
    }
};

bool ContainsLog(std::span<const std::string> logs, std::string_view message) {
    return std::any_of(logs.begin(), logs.end(), [message](const std::string& log) {
        return log.find(message) != std::string::npos;
    });
}

void AddTestConstantValue(wpscene::WPMaterial& material, std::string name, std::vector<float> value) {
    material.constantshadervalues[std::move(name)] = wpscene::WPConstantShaderValue {
        .value = std::move(value),
    };
}

TEST(MediaThumbnailTextureSmoke, RegularUserTextureSlotZeroResolvesToMediaThumbnail) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/default.tex" } },
              { "usertextures", { { { "type", "system" }, { "name", "$mediaThumbnail" } } } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));
    ASSERT_EQ(material.textures.size(), 1u);
    ASSERT_EQ(material.usertextures.size(), 1u);

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "$mediaThumbnail");
}

TEST(MediaThumbnailTextureSmoke, EffectUserTextureSlotOneResolvesToMediaThumbnail) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex", "materials/placeholder.tex" } },
          } } },
    };
    const nlohmann::json effect_pass_json = {
        { "textures", { "materials/base.tex", "materials/effect-placeholder.tex" } },
        { "usertextures", { nullptr, { { "type", "system" }, { "name", "$mediaThumbnail" } } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    wpscene::WPMaterialPass effect_pass;
    ASSERT_TRUE(effect_pass.FromJson(effect_pass_json));
    material.MergePass(effect_pass);

    ASSERT_EQ(material.textures.size(), 2u);
    ASSERT_EQ(material.usertextures.size(), 2u);

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[0], "materials/base.tex");
    EXPECT_EQ(textures[1], "$mediaThumbnail");
}

TEST(MediaThumbnailTextureSmoke, PreviousThumbnailSlotResolvesForCrossFades) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex", "masks/blend.tex" } },
              { "usertextures",
                { nullptr, { { "type", "system" }, { "name", "$mediaPreviousThumbnail" } } } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[0], "materials/base.tex");
    EXPECT_EQ(textures[1], "$mediaPreviousThumbnail");
}

TEST(MediaThumbnailTextureSmoke, UnknownSystemTextureKeepsAuthoredTexture) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex" } },
              { "usertextures", { { { "type", "system" }, { "name", "$somethingElse" } } } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

// A `scenetexture` property appears in `usertextures` as a bare string naming
// the property. Wallpapers built around "choose your own picture" slots are
// only as good as this substitution.
wpscene::WPMaterial TexturePropertyMaterial() {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex" } },
              { "usertextures", { nullptr, "_1" } },
          } } },
    };
    wpscene::WPMaterial material;
    EXPECT_TRUE(material.FromJson(material_json));
    return material;
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyTakesTheSlotItNames) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String("materials/chosen.tex");

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[0], "materials/base.tex");
    // The loader addresses packaged textures by bare name, so the authored form
    // the editor writes into the property is reduced to one.
    EXPECT_EQ(textures[1], "chosen");
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyCarriesTheUsersOwnFileThrough) {
    // Per process: concurrent runs share the temporary directory.
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wpe-user-texture-slot-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    const auto picture = directory / "photo.png";
    std::ofstream { picture, std::ios::binary } << "a readable file is what decides the slot";

    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String(picture.string());

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[1], picture.string());

    std::filesystem::remove_all(directory);
}

// The property holds the path, not a copy. A file the user has since moved, or
// one a sandboxed process may not open, has to leave the slot on the artwork
// the wallpaper shipped: a name that decodes to nothing is a hole on screen.
TEST(MediaThumbnailTextureSmoke, AnUnreadableUserFileKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String(
        (std::filesystem::temp_directory_path() / "wpe-user-texture-gone.png").string());

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, UnsetTexturePropertyKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String("");

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyWithoutATableKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, ConstantShaderValuesPreserveUserBindingAndFallback) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "workshop/2652493753/tint" },
              { "textures", { "workshop/2652493753/bar" } },
              { "constantshadervalues",
                {
                    { "color",
                      {
                          { "user", "ypcolor" },
                          { "value", "0.00000 0.00000 0.00000" },
                      } },
                    { "Alpha",
                      {
                          { "user", "newproperty14" },
                          { "value", 1.0f },
                      } },
                } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    const auto color = material.constantshadervalues.find("color");
    ASSERT_NE(color, material.constantshadervalues.end());
    EXPECT_EQ(color->second.user, "ypcolor");
    ASSERT_EQ(color->second.value.size(), 3u);
    EXPECT_FLOAT_EQ(color->second.value[0], 0.0f);
    EXPECT_FLOAT_EQ(color->second.value[1], 0.0f);
    EXPECT_FLOAT_EQ(color->second.value[2], 0.0f);

    const auto alpha = material.constantshadervalues.find("Alpha");
    ASSERT_NE(alpha, material.constantshadervalues.end());
    EXPECT_EQ(alpha->second.user, "newproperty14");
    ASSERT_EQ(alpha->second.value.size(), 1u);
    EXPECT_FLOAT_EQ(alpha->second.value[0], 1.0f);
}

TEST(MediaThumbnailTextureSmoke, ConstantShaderValuesPreserveScriptAndScriptProperties) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "workshop/2727665642/tint" },
              { "textures", { "workshop/2727665642/bar" } },
              { "constantshadervalues",
                {
                    { "color",
                      {
                          { "script",
                            "export var scriptProperties = createScriptProperties().addSlider({name:'speed',value:1}).finish(); export function update(value) { value.x = scriptProperties.speed; return value; }" },
                          { "scriptproperties",
                            { { "speed", { { "user", "speed_user" }, { "value", 0.5f } } } } },
                          { "value", "1 1 1" },
                      } },
                } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    const auto color = material.constantshadervalues.find("color");
    ASSERT_NE(color, material.constantshadervalues.end());
    EXPECT_NE(color->second.script.find("export function update"), std::string::npos);
    ASSERT_TRUE(color->second.scriptproperties.is_object());
    ASSERT_TRUE(color->second.scriptproperties.contains("speed"));
    EXPECT_EQ(color->second.scriptproperties.at("speed").at("user"), "speed_user");
    ASSERT_EQ(color->second.value.size(), 3u);
    EXPECT_FLOAT_EQ(color->second.value[0], 1.0f);
    EXPECT_FLOAT_EQ(color->second.value[1], 1.0f);
    EXPECT_FLOAT_EQ(color->second.value[2], 1.0f);
}

TEST(MediaThumbnailTextureSmoke, RuntimeMaterialConstantsFollowProjectProperties) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "ypcolor", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
            { "alpha", RuntimeScalarValue::Float(0.75f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(
        material,
        "g_Color",
        BoundValue(
            *runtime,
            "ypcolor",
            std::make_unique<DynamicValue>(Eigen::Vector3f(0.0f, 0.0f, 0.0f))));
    runtime->RegisterMaterialConstant(
        material,
        "g_UserAlpha",
        BoundValue(
            *runtime,
            "alpha",
            std::make_unique<DynamicValue>(1.0f)));

    ASSERT_TRUE(material->customShader.constValues.contains("g_Color"));
    ASSERT_EQ(material->customShader.constValues.at("g_Color").size(), 3u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[0], 1.0f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[1], 0.8117647f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[2], 0.8705882f);
    ASSERT_TRUE(material->customShader.constValues.contains("g_UserAlpha"));
    ASSERT_EQ(material->customShader.constValues.at("g_UserAlpha").size(), 1u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_UserAlpha")[0], 0.75f);

    runtime->ApplyProjectPropertyOverride({
        { "ypcolor", RuntimeScalarValue::String("0.25 0.5 0.75") },
        { "alpha", RuntimeScalarValue::Float(0.25f) },
    });
    runtime->Tick(1.0 / 60.0);

    ASSERT_EQ(material->customShader.constValues.at("g_Color").size(), 3u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[0], 0.25f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[1], 0.5f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color")[2], 0.75f);
    ASSERT_EQ(material->customShader.constValues.at("g_UserAlpha").size(), 1u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_UserAlpha")[0], 0.25f);
}

TEST(MediaThumbnailTextureSmoke, RuntimeMaterialConstantsEvaluatePropertyScriptsEachTick) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "speed", RuntimeScalarValue::Float(0.5f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto material = std::make_shared<SceneMaterial>();
    const nlohmann::json setting = {
        {
            "script",
            R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'speed', value: 1.0 })
  .finish();
export function update(value) {
  value.x = scriptProperties.speed;
  value.y = engine.runtime;
  return value;
}
)JS",
        },
        { "scriptproperties", { { "speed", { { "user", "speed" }, { "value", 1.0f } } } } },
        { "value", "1 1 1" },
    };

    auto value = ResolveVec3Setting(*runtime, setting, "bar material");
    runtime->RegisterMaterialConstant(material, "g_TintColor", std::move(value));

    runtime->Tick(0.25);
    ASSERT_TRUE(material->customShader.constValues.contains("g_TintColor"));
    ASSERT_EQ(material->customShader.constValues.at("g_TintColor").size(), 3u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_TintColor")[0], 0.5f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_TintColor")[1], 0.25f);

    runtime->ApplyProjectPropertyOverride({
        { "speed", RuntimeScalarValue::Float(0.75f) },
    });
    runtime->Tick(0.5);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_TintColor")[0], 0.75f);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_TintColor")[1], 0.75f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MediaThumbnailTextureSmoke, CompositeMaterialShaderValueRequiresSplitShaderAndMaterialValues) {
    WPShaderInfo shader_info;
    shader_info.alias = {
        { "frequencyRangeStart", "u_FrequencyRangeStart" },
        { "frequencyRangeEnd", "u_FrequencyRangeEnd" },
        { "volumeScale", "u_VolumeScale" },
    };

    wpscene::WPMaterial complete_material;
    AddTestConstantValue(complete_material, "frequencyRange", { 0.0f, 31.73f });
    AddTestConstantValue(complete_material, "frequencyRangeStart", { 0.0f });
    AddTestConstantValue(complete_material, "frequencyRangeEnd", { 63.0f });
    AddTestConstantValue(complete_material, "volumeScale", { 0.8f });

    SceneMaterial complete_scene_material;
    std::vector<std::string> complete_logs;
    {
        ScopedErrorLogCapture capture(complete_logs);
        LoadMaterialConstantShaderValues(complete_scene_material, complete_material, shader_info);
    }

    EXPECT_FALSE(ContainsLog(complete_logs, "ShaderValue: frequencyRange not found in glsl"));
    EXPECT_TRUE(complete_scene_material.customShader.constValues.contains("u_FrequencyRangeStart"));
    EXPECT_TRUE(complete_scene_material.customShader.constValues.contains("u_FrequencyRangeEnd"));
    EXPECT_TRUE(complete_scene_material.customShader.constValues.contains("u_VolumeScale"));

    wpscene::WPMaterial incomplete_material;
    AddTestConstantValue(incomplete_material, "frequencyRange", { 0.0f, 31.73f });

    SceneMaterial incomplete_scene_material;
    std::vector<std::string> incomplete_logs;
    {
        ScopedErrorLogCapture capture(incomplete_logs);
        LoadMaterialConstantShaderValues(
            incomplete_scene_material, incomplete_material, shader_info);
    }

    EXPECT_TRUE(ContainsLog(incomplete_logs, "ShaderValue: frequencyRange not found in glsl"));
}

TEST(MediaThumbnailTextureSmoke, GeneratedTemplateLayersKeepMaterialConstantBindings) {
    auto scene   = std::make_unique<Scene>();
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "ypcolor", RuntimeScalarValue::String("1 0.8 0.6") },
        },
    });
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(scene.get());

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(100.0f, 50.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene->sceneGraph->AppendChild(source_node);

    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/2652493753/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));
    runtime->RegisterMaterialConstant(
        source_mesh->MaterialSlotPtr(),
        "g_Color",
        BoundValue(
            *runtime,
            "ypcolor",
            std::make_unique<DynamicValue>(Eigen::Vector3f(0.0f, 0.0f, 0.0f))));

    const auto generated_name = runtime->CreateLayerFromTemplate("models/bar.json", "source");
    ASSERT_FALSE(generated_name.empty());
    ASSERT_EQ(scene->sceneGraph->GetChildren().size(), 2u);

    auto generated_node = scene->sceneGraph->GetChildren().back();
    ASSERT_NE(generated_node, nullptr);
    ASSERT_NE(generated_node->Mesh(), nullptr);
    ASSERT_NE(generated_node->Mesh()->Material(), nullptr);

    runtime->ApplyProjectPropertyOverride({
        { "ypcolor", RuntimeScalarValue::String("0.2 0.4 0.6") },
    });
    runtime->Tick(1.0 / 60.0);

    const auto& source_color =
        source_mesh->Material()->customShader.constValues.at("g_Color");
    const auto& generated_color =
        generated_node->Mesh()->Material()->customShader.constValues.at("g_Color");
    ASSERT_EQ(source_color.size(), 3u);
    ASSERT_EQ(generated_color.size(), 3u);
    EXPECT_FLOAT_EQ(source_color[0], 0.2f);
    EXPECT_FLOAT_EQ(source_color[1], 0.4f);
    EXPECT_FLOAT_EQ(source_color[2], 0.6f);
    EXPECT_FLOAT_EQ(generated_color[0], 0.2f);
    EXPECT_FLOAT_EQ(generated_color[1], 0.4f);
    EXPECT_FLOAT_EQ(generated_color[2], 0.6f);
}

TEST(MediaThumbnailTextureSmoke, RuntimeImageSourceStoresExactRgbaPayload) {
    RuntimeImageSource         source(std::make_unique<NullImageParser>());
    const std::vector<uint8_t> rgba {
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
    };

    source.SetRgbaImage("$mediaThumbnail", 2, 1, rgba.data(), rgba.size());

    const auto header = source.ParseHeader("$mediaThumbnail");
    EXPECT_EQ(header.width, 2);
    EXPECT_EQ(header.height, 1);
    EXPECT_EQ(header.mapWidth, 2);
    EXPECT_EQ(header.mapHeight, 1);
    EXPECT_EQ(header.count, 1);
    EXPECT_EQ(header.format, TextureFormat::RGBA8);

    const auto image = source.Parse("$mediaThumbnail");
    ASSERT_NE(image, nullptr);
    EXPECT_EQ(image->header.width, 2);
    EXPECT_EQ(image->header.height, 1);
    ASSERT_EQ(image->slots.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 2);
    EXPECT_EQ(image->slots[0].height, 1);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);

    const auto& mip = image->slots[0].mipmaps[0];
    EXPECT_EQ(mip.width, 2);
    EXPECT_EQ(mip.height, 1);
    ASSERT_EQ(mip.size, static_cast<isize>(rgba.size()));
    ASSERT_NE(mip.data, nullptr);
    EXPECT_EQ(std::memcmp(mip.data.get(), rgba.data(), rgba.size()), 0);
}

TEST(MediaThumbnailTextureSmoke, RuntimeImageSourceClassifiesRuntimeImagesWithoutFallbackParse) {
    auto* fallback = new CountingImageParser();
    RuntimeImageSource source { std::unique_ptr<IImageParser>(fallback) };

    EXPECT_TRUE(source.IsRuntimeImage("$mediaThumbnail"));
    EXPECT_FALSE(source.IsRuntimeImage("materials/static.tex"));
    EXPECT_EQ(fallback->parse_calls, 0);
    EXPECT_EQ(fallback->header_calls, 0);

    const std::vector<uint8_t> rgba { 0xFF, 0x00, 0x00, 0xFF };
    source.SetRgbaImage("__we_text_texture_layer", 1, 1, rgba.data(), rgba.size());

    EXPECT_TRUE(source.IsRuntimeImage("__we_text_texture_layer"));
    EXPECT_EQ(fallback->parse_calls, 0);
    EXPECT_EQ(fallback->header_calls, 0);
}

TEST(MediaThumbnailTextureSmoke, PreviousThumbnailKeepsTheCoverItReplaced) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());

    // Before any track: both slots parse, so a bound layer is never missing an
    // image, and the previous cover is transparent rather than a stale one.
    ASSERT_NE(source.Parse("$mediaPreviousThumbnail"), nullptr);

    const std::vector<uint8_t> first { 0x11, 0x22, 0x33, 0xFF };
    const std::vector<uint8_t> second { 0x44, 0x55, 0x66, 0xFF };

    source.SetRgbaImage("$mediaThumbnail", 1, 1, first.data(), first.size());
    ASSERT_TRUE(source.AliasRuntimeImage("$mediaThumbnail", "$mediaPreviousThumbnail"));
    source.SetRgbaImage("$mediaThumbnail", 1, 1, second.data(), second.size());

    const auto current  = source.Parse("$mediaThumbnail");
    const auto previous = source.Parse("$mediaPreviousThumbnail");
    ASSERT_NE(current, nullptr);
    ASSERT_NE(previous, nullptr);
    EXPECT_EQ(std::memcmp(current->slots[0].mipmaps[0].data.get(), second.data(), second.size()), 0);
    EXPECT_EQ(std::memcmp(previous->slots[0].mipmaps[0].data.get(), first.data(), first.size()), 0);
    // Distinct cache identities, so the two covers cannot collapse into one
    // GPU texture while both are on screen during a cross-fade.
    EXPECT_NE(current->key, previous->key);
    EXPECT_EQ(source.Version("$mediaPreviousThumbnail"), source.Version("$mediaThumbnail") - 1);
}

/// Re-sending the cover that is already showing must change nothing.
///
/// Replays are routine: every new scene handle is handed the current state
/// again. Treating that as a new cover retires the texture the GPU is
/// sampling, uploads another, and moves the current cover into the previous
/// slot — so a wallpaper would cross-fade a cover into itself, and would do it
/// every time a display was added or a wallpaper switched.
TEST(MediaThumbnailTextureSmoke, RepublishingTheSameCoverChangesNothing) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());

    const std::vector<uint8_t> first { 0x11, 0x22, 0x33, 0xFF };
    const std::vector<uint8_t> second { 0x44, 0x55, 0x66, 0xFF };

    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    const auto current  = source.Parse("$mediaThumbnail");
    const auto previous = source.Parse("$mediaPreviousThumbnail");
    const auto version  = source.Version("$mediaThumbnail");

    EXPECT_FALSE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()))
        << "the cover already on screen was published again";
    EXPECT_EQ(source.Parse("$mediaThumbnail"), current) << "an identical cover replaced the image";
    EXPECT_EQ(source.Version("$mediaThumbnail"), version)
        << "an identical cover moved the version a renderer watches for changes";
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), previous)
        << "an identical cover overwrote the cover a cross-fade fades from";

    // A real change still lands, and still keeps the cover it replaced.
    EXPECT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), current);
    EXPECT_GT(source.Version("$mediaThumbnail"), version);
}

TEST(MediaThumbnailTextureSmoke, EmptyArtworkClearsBothSlotsAndAReplayDoesNoWork) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());
    const std::array<uint8_t, 4> first {255, 0, 0, 255}, second {0, 255, 0, 255}, empty {};
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    EXPECT_TRUE(source.MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    EXPECT_TRUE(source.MatchesRgba("$mediaPreviousThumbnail", 1, 1, empty.data(), empty.size()));
    const auto cleared = source.Parse("$mediaThumbnail");
    const auto version = source.Version("$mediaThumbnail");
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    EXPECT_EQ(source.Version("$mediaThumbnail"), version);
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), cleared);
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 1, nullptr, 0));
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 2, 2, first.data(), first.size()));
    EXPECT_EQ(source.Version("$mediaThumbnail"), version);
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), cleared);
}

// What a cover layer ships in the slot a cover is bound to: pictures by name,
// each of them one 4x4 block of its own byte, decoded on demand and counted.
class AuthoredPictures final : public IImageParser {
public:
    int parse_calls { 0 };
    int header_calls { 0 };

    void Add(const std::string& name, uint8_t fill, bool video = false, bool sprite = false,
             TextureFormat format = TextureFormat::BC3) {
        m_pictures[name] = Picture { fill, video, sprite, true, format };
    }
    /// A file whose header reads but whose pixels do not decode.
    void AddUndecodable(const std::string& name) {
        m_pictures[name] = Picture { 0, false, false, false, TextureFormat::BC3 };
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        ++parse_calls;
        const auto picture = m_pictures.find(name);
        if (picture == m_pictures.end() || ! picture->second.decodes) return nullptr;
        auto image    = std::make_shared<Image>();
        image->key    = name;
        image->header = HeaderOf(picture->second);
        Image::Slot slot;
        slot.width  = 4;
        slot.height = 4;
        ImageData mip;
        mip.width  = 4;
        mip.height = 4;
        mip.size   = 16;
        mip.data   = ImageDataPtr(new uint8_t[16], [](uint8_t* data) { delete[] data; });
        std::memset(mip.data.get(), picture->second.fill, 16);
        slot.mipmaps.push_back(std::move(mip));
        image->slots.push_back(std::move(slot));
        return image;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        ++header_calls;
        const auto picture = m_pictures.find(name);
        return picture == m_pictures.end() ? ImageHeader {} : HeaderOf(picture->second);
    }

private:
    struct Picture {
        uint8_t fill { 0 };
        bool    video { false };
        bool    sprite { false };
        bool    decodes { true };
        TextureFormat format { TextureFormat::BC3 };
    };

    static ImageHeader HeaderOf(const Picture& picture) {
        ImageHeader header;
        header.width     = header.mapWidth  = 4;
        header.height    = header.mapHeight = 4;
        header.count     = 1;
        header.format    = picture.format;
        header.isVideo   = picture.video;
        header.isSprite  = picture.sprite;
        return header;
    }

    std::map<std::string, Picture> m_pictures;
};

uint8_t FirstByte(const std::shared_ptr<Image>& image) {
    return image != nullptr && ! image->slots.empty() && ! image->slots[0].mipmaps.empty() &&
                   image->slots[0].mipmaps[0].data != nullptr
               ? image->slots[0].mipmaps[0].data.get()[0]
               : uint8_t { 0xEE };
}

TEST(CoverSlot, ShowsTheAuthoredPictureUntilACoverIsPublishedAndAfterItIsCleared) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 0x5A);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    const auto slot = source.BindCoverSlot("$mediaThumbnail", "art");
    ASSERT_NE(slot, "$mediaThumbnail");
    EXPECT_TRUE(source.IsRuntimeImage(slot)) << "a renderer would never refresh the slot";
    // The header a material reads while it loads is the authored picture's.
    EXPECT_EQ(source.ParseHeader(slot).format, TextureFormat::BC3);
    EXPECT_EQ(source.ParseHeader(slot).width, 4);

    const auto idle = source.Parse(slot);
    ASSERT_NE(idle, nullptr);
    EXPECT_EQ(FirstByte(idle), 0x5A) << "no track is playing, so the author's art shows";
    const auto idle_version = source.Version(slot);
    EXPECT_NE(idle_version, 0u);

    const std::vector<uint8_t> cover { 0x11, 0x22, 0x33, 0xFF };
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, cover.data(), cover.size()));
    const auto showing = source.Parse(slot);
    EXPECT_EQ(showing, source.Parse("$mediaThumbnail")) << "the slot must show the track's cover";
    EXPECT_EQ(FirstByte(showing), 0x11);
    EXPECT_GT(source.Version(slot), idle_version) << "a renderer would not notice the cover";
    // Its header is still the authored picture's: a material's size and format
    // constants were fixed from it before any track played.
    EXPECT_EQ(source.ParseHeader(slot).format, TextureFormat::BC3);

    const auto showing_version = source.Version(slot);
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    const auto cleared_version = source.Version(slot);
    EXPECT_GT(cleared_version, showing_version) << "a renderer would not notice the clear";
    EXPECT_EQ(source.Parse(slot), idle) << "the explicit clear brings the author's art back";
    EXPECT_EQ(parser->parse_calls, 1) << "the art was decoded again instead of kept";

    // A replay of the clear changes nothing, and so does reading the slot.
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    for (int i = 0; i < 50; ++i) (void)source.Parse(slot);
    EXPECT_EQ(source.Version(slot), cleared_version);
    EXPECT_EQ(parser->parse_calls, 1);
}

TEST(CoverSlot, ThePreviousCoverSlotStaysOnItsAuthoredPictureUntilThereIsAPreviousCover) {
    auto* parser = new AuthoredPictures();
    parser->Add("black", 0x10);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaPreviousThumbnail", "black");
    ASSERT_NE(slot, "$mediaPreviousThumbnail");
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x10);

    const std::vector<uint8_t> first { 0x21, 0x22, 0x23, 0xFF };
    const std::vector<uint8_t> second { 0x31, 0x32, 0x33, 0xFF };
    // The first track has nothing before it: what it replaced was the empty cover.
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x10);
    const auto before = source.Version(slot);
    // The second one fades from the first.
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x21);
    EXPECT_GT(source.Version(slot), before);
}

TEST(CoverSlot, KeepsTheCoverNameWhenThereIsNothingToStandInForIt) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 1);
    parser->Add("clip", 2, true);
    parser->Add("sheet", 3, false, true);
    parser->Add("mask", 4, false, false, TextureFormat::R8);
    parser->Add("normal", 5, false, false, TextureFormat::RG8);
    parser->Add("plain", 6, false, false, TextureFormat::RGBA8);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", ""), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "missing"), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "clip"), "$mediaThumbnail")
        << "a video is not a picture a cover can stand in for";
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "sheet"), "$mediaThumbnail");
    // A material is compiled to read a one- or two-channel picture through those
    // channels, which is not how it reads a track's RGBA cover.
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "mask"), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "normal"), "$mediaThumbnail");
    EXPECT_NE(source.BindCoverSlot("$mediaThumbnail", "plain"), "$mediaThumbnail")
        << "art stored as plain RGBA is a picture like any other";
    EXPECT_EQ(source.BindCoverSlot("materials/other.tex", "art"), "materials/other.tex")
        << "only the two cover names are slots";
    EXPECT_EQ(parser->parse_calls, 0);

    RuntimeImageSource bare { nullptr };
    EXPECT_EQ(bare.BindCoverSlot("$mediaThumbnail", "art"), "$mediaThumbnail");
}

TEST(CoverSlot, OneSlotPerCoverAndAuthoredPicture) {
    auto* parser = new AuthoredPictures();
    parser->Add("one", 1);
    parser->Add("two", 2);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         generation = source.NamesGeneration();

    const auto first = source.BindCoverSlot("$mediaThumbnail", "one");
    EXPECT_NE(source.NamesGeneration(), generation) << "a renderer keeps its per-slot answers";
    const auto joined = source.NamesGeneration();
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "one"), first);
    EXPECT_EQ(source.NamesGeneration(), joined);
    EXPECT_NE(source.BindCoverSlot("$mediaThumbnail", "two"), first);
    EXPECT_NE(source.BindCoverSlot("$mediaPreviousThumbnail", "one"), first);
    // Never removed with the layers a script makes and destroys.
    EXPECT_FALSE(source.RemoveImage(first));
    EXPECT_TRUE(source.IsRuntimeImage(first));
}

TEST(CoverSlot, DecodesTheAuthoredPictureOnlyWhenARendererAsksAndOnlyOnce) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 7);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaThumbnail", "art");
    (void)source.IsRuntimeImage(slot);
    (void)source.Version(slot);
    (void)source.ParseHeader(slot);
    EXPECT_EQ(parser->parse_calls, 0) << "decoded while the scene loaded, before any texture budget";
    const auto first = source.Parse(slot);
    for (int i = 0; i < 100; ++i) EXPECT_EQ(source.Parse(slot), first);
    EXPECT_EQ(parser->parse_calls, 1);
}

TEST(CoverSlot, AnAuthoredPictureThatCannotBeDecodedLeavesTheCoverAsItWas) {
    auto* parser = new AuthoredPictures();
    parser->AddUndecodable("broken");
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaThumbnail", "broken");
    ASSERT_NE(slot, "$mediaThumbnail");
    // The slot still answers, with the cover's own transparent texel.
    EXPECT_EQ(source.Parse(slot), source.Parse("$mediaThumbnail"));
    EXPECT_EQ(parser->parse_calls, 1) << "a file that cannot be read was read again every frame";
    const std::vector<uint8_t> cover { 0x41, 0x42, 0x43, 0xFF };
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, cover.data(), cover.size()));
    EXPECT_EQ(source.Parse(slot), source.Parse("$mediaThumbnail"));
}

TEST(CoverSlot, ASystemSlotKeepsItsAuthoredTextureWhenCoversAreGiven) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 0x33);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    const std::vector<wpscene::WPUserTexture> usertextures {
        { .name = "$mediaThumbnail", .type = "system" },
        { .name = "$mediaPreviousThumbnail", .type = "system" },
    };
    std::vector<std::string> textures { "art", "_rt_imageLayerComposite_3_a" };
    ApplySystemUserTextures(textures, usertextures, nullptr, &source);
    ASSERT_EQ(textures.size(), 2u);
    EXPECT_NE(textures[0], "$mediaThumbnail");
    EXPECT_EQ(FirstByte(source.Parse(textures[0])), 0x33);
    EXPECT_EQ(textures[1], "$mediaPreviousThumbnail")
        << "another layer's composite is not a picture the source can hold";

    // No authored texture in the slot: the cover alone.
    std::vector<std::string> empty { "" };
    ApplySystemUserTextures(empty, { usertextures[0] }, nullptr, &source);
    EXPECT_EQ(empty[0], "$mediaThumbnail");
    std::vector<std::string> none;
    ApplySystemUserTextures(none, { usertextures[0] }, nullptr, &source);
    ASSERT_EQ(none.size(), 1u);
    EXPECT_EQ(none[0], "$mediaThumbnail");

    // Without a source to bind through it names the cover, as it always has.
    std::vector<std::string> unbound { "art" };
    ApplySystemUserTextures(unbound, { usertextures[0] });
    EXPECT_EQ(unbound[0], "$mediaThumbnail");
}

} // namespace
} // namespace wallpaper
