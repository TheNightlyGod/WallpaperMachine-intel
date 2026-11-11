// Reading a scene without drawing it: whether Native Metal would refuse it, and which files its
// layers name and do not have. Parse-level: no device, display or audio output is needed.

#include <gtest/gtest.h>

#include "support/scene_package.hpp"

#include "Scene/SceneCapabilityProbe.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <filesystem>
#include <string>

#include <unistd.h>

namespace
{
using namespace we_test;
using wallpaper::ProbeSceneCapability;
using wallpaper::SceneCapabilityProbeJson;
using wallpaper::SceneCapabilityProbeRequest;
using wallpaper::SceneCapabilityProbeResult;
using wallpaper::SceneFailureStage;
using wallpaper::SceneMissingFile;
namespace disk = std::filesystem;

/// An empty shared assets folder and a shader cache, removed with the fixture: the synthetic
/// packages carry the shaders and textures they draw with.
class ProbeFolders {
public:
    ProbeFolders()
    {
        std::string pattern = (disk::temp_directory_path() / "we-capability-XXXXXX").string();
        if (::mkdtemp(pattern.data()) != nullptr) root_ = pattern;
        disk::create_directories(root_ / "shared");
        disk::create_directories(root_ / "cache");
    }
    ~ProbeFolders()
    {
        std::error_code ignored;
        if (! root_.empty()) disk::remove_all(root_, ignored);
    }
    ProbeFolders(const ProbeFolders&)            = delete;
    ProbeFolders& operator=(const ProbeFolders&) = delete;

    [[nodiscard]] SceneCapabilityProbeRequest Request(const ScenePackage& package) const
    {
        return SceneCapabilityProbeRequest {
            .project_file = package.project_file(),
            .assets       = (root_ / "shared").string(),
            .cache        = (root_ / "cache").string(),
        };
    }

private:
    disk::path root_;
};

const SceneMissingFile* Missing(const SceneCapabilityProbeResult& result, const std::string& path)
{
    const auto found = std::find_if(result.missing_files.begin(), result.missing_files.end(),
                                    [&](const SceneMissingFile& file) { return file.path == path; });
    return found == result.missing_files.end() ? nullptr : &*found;
}

} // namespace

TEST(SceneCapabilityProbe, AWholeSceneIsReadAndNativeMetalAcceptsIt)
{
    ScenePackage package;
    package.MakeSolidScene({ 200, 40, 40, 255 });
    ProbeFolders folders;

    const auto result = ProbeSceneCapability(folders.Request(package));
    EXPECT_TRUE(result.read_error.empty()) << result.read_error;
    EXPECT_FALSE(result.selection.failed()) << result.selection.failure_reason;
    EXPECT_TRUE(result.missing_files.empty()) << result.missing_files.front().path;
}

TEST(SceneCapabilityProbe, AFileALayerNamesAndTheSceneLacksIsPutDownToThatLayer)
{
    ScenePackage package;
    package.InstallStandardAssets();
    package.PutJson("models/rain.json", { { "material", "materials/rain-drops.json" } });
    ImageLayer layer;
    layer.id    = 12;
    layer.name  = "Rain";
    layer.model = "models/rain.json";
    ImageLayer sky;
    sky.id    = 3;
    sky.name  = "Sky";
    sky.model = package.AddImageModel("sky", "clouds");
    package.SetProject();
    package.SetScene(SceneJson({}, { ImageLayerJson(sky), ImageLayerJson(layer) }));
    ProbeFolders folders;

    const auto result = ProbeSceneCapability(folders.Request(package));
    ASSERT_TRUE(result.read_error.empty()) << result.read_error;

    const auto* material = Missing(result, "materials/rain-drops.json");
    ASSERT_NE(material, nullptr) << "a material the model names and nobody installed";
    EXPECT_EQ(material->layer, "Rain");
    EXPECT_EQ(material->object_id, 12);

    const auto* texture = Missing(result, "materials/clouds");
    ASSERT_NE(texture, nullptr) << "a texture found neither as a container nor as a picture";
    EXPECT_EQ(texture->layer, "Sky");
    EXPECT_EQ(texture->object_id, 3);

    EXPECT_EQ(std::count_if(result.missing_files.begin(), result.missing_files.end(),
                            [](const SceneMissingFile& file) { return file.path.rfind("cache", 0) == 0; }),
              0)
        << "a shader cache entry that is not there yet is not something the scene lacks";
}

TEST(SceneCapabilityProbe, AnOptionalSharedMaterialThatIsAbsentIsNotAMissingFile)
{
    // A fogged layer with an effect looks for the fog composite material, which older shared
    // assets lack; the layer then keeps its fog where it was. That lookup is not a file the
    // scene names.
    ScenePackage package;
    ImageLayer   layer;
    layer.model   = package.AddImageModel("card");
    layer.effects = { EffectUse(package.AddTintEffect("tint"), { { "tint", "1 1 1" } }) };
    SceneGeneral general;
    general.extra = { { "fogdistance", true }, { "fogdistancestart", 0.0 }, { "fogdistanceend", 10.0 } };
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));
    ProbeFolders folders;

    const auto result = ProbeSceneCapability(folders.Request(package));
    ASSERT_TRUE(result.read_error.empty()) << result.read_error;
    EXPECT_EQ(Missing(result, "materials/util/effectpassthrough_4.json"), nullptr);
}

TEST(SceneCapabilityProbe, AProjectThatCannotBeReadSaysWhy)
{
    ScenePackage package;
    package.SetProject();
    ProbeFolders folders;
    const auto   no_scene = ProbeSceneCapability(folders.Request(package));
    EXPECT_FALSE(no_scene.read_error.empty()) << "scene.json was never written";

    SceneCapabilityProbeRequest nowhere = folders.Request(package);
    nowhere.project_file                = (package.root() / "missing" / "project.json").string();
    EXPECT_FALSE(ProbeSceneCapability(nowhere).read_error.empty());
}

TEST(SceneCapabilityProbe, TheAnswerIsOneJsonDocument)
{
    SceneCapabilityProbeResult result;
    result.selection.failure_stage  = SceneFailureStage::Unsupported;
    result.selection.failure_reason = "the scene uses a light probe";
    result.missing_files.push_back({ .layer = "Rain \xff", .object_id = 12, .path = "materials/rain.json" });

    const auto document = nlohmann::json::parse(SceneCapabilityProbeJson(result));
    EXPECT_EQ(document["read_error"], "");
    EXPECT_EQ(document["failure_stage"], "unsupported");
    EXPECT_EQ(document["failure_reason"], "the scene uses a light probe");
    ASSERT_EQ(document["missing_files"].size(), 1u);
    EXPECT_EQ(document["missing_files"][0]["object_id"], 12);
    EXPECT_EQ(document["missing_files"][0]["path"], "materials/rain.json");
    EXPECT_TRUE(document["missing_files"][0]["layer"].get<std::string>().rfind("Rain ", 0) == 0)
        << "a name that is not UTF-8 is replaced, not dropped with the whole answer";
}
