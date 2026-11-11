#include "support/script_scene.hpp"

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "SceneSourceResolver.hpp"
#include "Utils/Random.hpp"
#include "WPSceneParser.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>

#include <unistd.h>

namespace we_test
{

using namespace wallpaper;
namespace disk = std::filesystem;

struct ScriptScene::Impl {
    ScriptSceneOptions options;
    std::string        error;
    disk::path         scratch;
    std::unique_ptr<audio::SoundManager> sound;
    std::shared_ptr<Scene>               scene;
    std::map<std::string, Json>          preview_values;

    bool Fail(std::string message)
    {
        error = std::move(message);
        return false;
    }

    bool Load(const std::string& project_file)
    {
        SceneSourceResolution resolved;
        std::string           problem;
        if (!ResolveSceneSourcePaths(project_file, &resolved, &problem)) {
            return Fail("the scene source cannot be resolved: " + problem);
        }
        if (resolved.kind != SceneSourceResolutionKind::Scene) return Fail("the project is not a scene");

        auto vfs = std::make_unique<fs::VFS>();
        {
            auto shared = fs::CreatePhysicalFs((scratch / "shared").string());
            if (shared == nullptr || !vfs->Mount("/assets", std::move(shared))) {
                return Fail("the shared assets cannot be mounted");
            }
        }
        if (!MountSceneSource(*vfs, resolved.scene_source, &problem)) {
            return Fail("the project's files cannot be mounted: " + problem);
        }
        {
            auto cache = fs::CreatePhysicalFs((scratch / "cache").string(), true);
            if (cache == nullptr || !vfs->Mount("/cache", std::move(cache), "cache")) {
                return Fail("the scratch shader cache cannot be mounted");
            }
        }
        if (!InstallVirtualAssets(*vfs)) return Fail("the built-in assets cannot be installed");

        const std::string scene_text = fs::GetFileContent(*vfs, "/assets/" + resolved.scene_source.pkg_entry);
        if (scene_text.empty()) return Fail("the scene file is missing or empty");

        ProjectProperties authored;
        if (!ParseProjectProperties(project_file, &authored, &problem)) {
            return Fail("the project's properties cannot be read: " + problem);
        }
        ProjectProperties merged = authored;
        if (options.saved_properties.is_object() && !options.saved_properties.empty()) {
            ProjectProperties saved;
            if (!ParseFlatProjectPropertyOverrideJson(options.saved_properties.dump(), &saved, &problem)) {
                return Fail("the saved property values cannot be read: " + problem);
            }
            merged = MergeProjectProperties(authored, saved);
        }

        SceneParseRequest request;
        request.scene_id                    = resolved.scene_source.scene_id;
        request.project_path                = project_file;
        request.project_properties          = &merged;
        request.authored_project_properties = &authored;
        request.storage_directory           = options.storage_directory;
        request.storage_screen_key          = options.storage_screen_key;
        request.storage_read_only           = options.storage_read_only;

        Random::seed(1);
        WPSceneParser parser;
        scene = parser.Parse(request, scene_text, *vfs, *sound);
        if (scene == nullptr) return Fail("the parse produced no scene");
        scene->project_path = project_file;
        if (scene->runtime == nullptr) return Fail("the scene has no runtime");
        scene->runtime->SetAudioResponseEnabled(false);
        scene->runtime->SetMediaIntegrationEnabled(false);
        scene->vfs = std::move(vfs);
        return true;
    }

    // The effect chains of the scene, ordered by the camera that carries each.
    std::vector<SceneImageEffectLayer*> Chains()
    {
        std::vector<std::pair<std::string, SceneImageEffectLayer*>> found;
        for (auto& [name, camera] : scene->cameras) {
            if (camera != nullptr && camera->HasImgEffect()) found.emplace_back(name, camera->GetImgEffect().get());
        }
        std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        std::vector<SceneImageEffectLayer*> chains;
        for (auto& entry : found) chains.push_back(entry.second);
        return chains;
    }
};

ScriptScene::ScriptScene(const ScenePackage& package, ScriptSceneOptions options) : impl_(std::make_unique<Impl>())
{
    Impl& impl   = *impl_;
    impl.options = std::move(options);

    std::string pattern = (disk::temp_directory_path() / "we-script-scene-XXXXXX").string();
    if (::mkdtemp(pattern.data()) == nullptr) {
        impl.Fail("cannot create the scratch folder");
        return;
    }
    impl.scratch = pattern;
    std::error_code made;
    disk::create_directories(impl.scratch / "cache", made);
    disk::create_directories(impl.scratch / "shared", made);

    impl.sound = std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null);
    impl.Load(package.project_file());
}

ScriptScene::~ScriptScene()
{
    if (impl_ == nullptr) return;
    impl_->scene.reset();
    impl_->sound.reset();
    if (!impl_->scratch.empty()) {
        std::error_code ignored;
        disk::remove_all(impl_->scratch, ignored);
    }
}

bool ScriptScene::ok() const { return impl_->error.empty() && impl_->scene != nullptr; }

const std::string& ScriptScene::error() const { return impl_->error; }

void ScriptScene::Tick(int frames)
{
    if (!ok()) return;
    auto& runtime = *impl_->scene->runtime;
    for (int frame = 0; frame < frames; ++frame) {
        runtime.Tick(impl_->options.time_step);
        runtime.PumpTextLayerCache();
        (void)runtime.ConsumeSceneGraphMutationFlag();
        (void)runtime.ConsumeRenderTargetResizeFlag();
        (void)runtime.TakeUserShortcutRequests();
    }
}

bool ScriptScene::SetProperty(const std::string& name, const Json& value)
{
    if (!ok()) return false;
    impl_->preview_values[name] = value;
    Json document               = Json::object();
    for (const auto& [key, held] : impl_->preview_values) document[key] = held;
    ProjectProperties table;
    std::string       problem;
    if (!ParseFlatProjectPropertyOverrideJson(document.dump(), &table, &problem)) {
        impl_->error = "the property document is not valid: " + problem;
        return false;
    }
    (void)impl_->scene->runtime->PreviewProjectPropertyOverride(table);
    return true;
}

Scene&               ScriptScene::scene() { return *impl_->scene; }
SceneRuntimeContext& ScriptScene::runtime() { return *impl_->scene->runtime; }

namespace
{
std::array<float, 3> Lanes(const linalg::Vector3f& v) { return { v.x(), v.y(), v.z() }; }
constexpr float kDegrees = 180.0f / 3.14159265358979323846f;
} // namespace

std::array<float, 3> ScriptScene::Origin(const std::string& layer) { return Lanes(runtime().NodeTranslate(layer)); }
std::array<float, 3> ScriptScene::Scale(const std::string& layer) { return Lanes(runtime().NodeScale(layer)); }
std::array<float, 3> ScriptScene::AnglesDegrees(const std::string& layer)
{
    const auto radians = runtime().NodeRotation(layer);
    return { radians.x() * kDegrees, radians.y() * kDegrees, radians.z() * kDegrees };
}
std::array<float, 3> ScriptScene::Color(const std::string& layer) { return Lanes(runtime().NodeColor(layer)); }
std::array<float, 2> ScriptScene::ParallaxDepth(const std::string& layer)
{
    const auto depth = runtime().NodeParallaxDepth(layer);
    return { depth.x(), depth.y() };
}
bool ScriptScene::Visible(const std::string& layer) { return runtime().NodeVisible(layer); }

std::vector<std::string> ScriptScene::ScriptErrors() { return runtime().scriptErrors(); }

std::vector<bool> ScriptScene::EffectVisibility()
{
    std::vector<bool> flags;
    for (auto* chain : impl_->Chains()) {
        for (std::size_t at = 0; at < chain->EffectCount(); ++at) {
            const auto& effect = chain->GetEffect(at);
            if (effect != nullptr && !effect->fallback) flags.push_back(effect->visible);
        }
    }
    return flags;
}

std::vector<float> ScriptScene::EffectConstant(std::size_t effect, const std::string& uniform, std::size_t pass)
{
    for (auto* chain : impl_->Chains()) {
        if (chain->EffectCount() <= effect) continue;
        const auto& held = chain->GetEffect(effect);
        if (held == nullptr || pass >= held->nodes.size()) continue;
        auto position = held->nodes.begin();
        std::advance(position, static_cast<std::ptrdiff_t>(pass));
        auto* node = position->sceneNode.get();
        if (node == nullptr || node->Mesh() == nullptr) continue;
        const auto material = node->Mesh()->MaterialSlotPtr(0);
        if (material == nullptr) continue;
        const auto& constants = material->customShader.constValues;
        const auto  found     = constants.find(uniform);
        if (found == constants.end()) return {};
        std::vector<float> lanes;
        for (std::size_t lane = 0; lane < found->second.size(); ++lane) lanes.push_back(found->second[lane]);
        return lanes;
    }
    return {};
}

std::string MakeWav(double seconds)
{
    const uint32_t rate    = 8000;
    const uint32_t samples = static_cast<uint32_t>(seconds * rate);
    std::string    out;
    const auto     u32 = [&out](uint32_t v) { for (int i = 0; i < 4; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff)); };
    const auto     u16 = [&out](uint16_t v) { for (int i = 0; i < 2; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff)); };
    out += "RIFF";
    u32(36 + samples * 2);
    out += "WAVEfmt ";
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    out += "data";
    u32(samples * 2);
    for (uint32_t i = 0; i < samples; ++i) u16(static_cast<uint16_t>(static_cast<int16_t>(std::sin(i * 0.1) * 8000)));
    return out;
}

} // namespace we_test
