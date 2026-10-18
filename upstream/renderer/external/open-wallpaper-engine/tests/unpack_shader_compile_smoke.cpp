#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "WPMdlParser.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace
{

#ifndef UNPACK_SHADER_COMPILE_SMOKE_DEFAULT_CORPUS_ROOT
#error "UNPACK_SHADER_COMPILE_SMOKE_DEFAULT_CORPUS_ROOT must be provided by CMake"
#endif

// Both roots are found at run time, the way the shader crate's pipeline tests
// and the bridge find them, so no machine's home directory is compiled in.

/// Workshop packages unpacked one per folder (<id>/scene.json):
/// WALLPAPER_MACHINE_UNPACK_ROOT, or upstream/renderer/unpack.
std::filesystem::path CorpusRoot() {
    const char* root = std::getenv("WALLPAPER_MACHINE_UNPACK_ROOT");
    if (root != nullptr && *root != '\0') return root;
    return UNPACK_SHADER_COMPILE_SMOKE_DEFAULT_CORPUS_ROOT;
}

/// Wallpaper Engine's shipped assets: WALLPAPER_MACHINE_ASSETS_ROOT, or the
/// Steam install under the current user's home. Empty when neither is known.
const std::filesystem::path& CommonAssets() {
    static const std::filesystem::path root = [] {
        if (const char* assets = std::getenv("WALLPAPER_MACHINE_ASSETS_ROOT");
            assets != nullptr && *assets != '\0') {
            return std::filesystem::path(assets);
        }
        const char* home = std::getenv("HOME");
        if (home == nullptr || *home == '\0') return std::filesystem::path();
        return std::filesystem::path(home) /
               "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets";
    }();
    return root;
}

constexpr unsigned int kSpirvMagicWord = 0x07230203;
constexpr std::size_t kMaxWorkshopSceneDirs = 4096;

struct ShaderFailure {
    std::string           workshop_id;
    std::filesystem::path scene_json;
    bool                  mounted_common_assets = false;
    std::filesystem::path source_path;
    std::string           context;
    std::string           shader_name;
    std::string           shader_path;
    std::string           stage;
    std::filesystem::path generated_glsl_path;
    std::string           diagnostic_source;
    std::string           message;
};

struct NonShaderBlocker {
    std::string           workshop_id;
    std::filesystem::path scene_json;
    bool                  mounted_common_assets = false;
    std::string           message;
};

struct ExpectedShaderContext {
    std::filesystem::path source_path;
    std::string           context;
    std::string           identity_key;
    std::string           shader_name;
    std::string           shader_path;
    /// Combos the scene sets on an effect's pass, over the material's own:
    /// the effect file's pass first, then the scene's instance of it.
    wallpaper::Combos     scene_combos;
};

struct DirectShaderCompileJob {
    std::filesystem::path  source_path;
    std::string            context;
    std::string            shader_name;
    std::string            shader_path;
    wallpaper::Combos      combos;
    std::vector<std::string> base_textures;
};

struct WorkshopShaderWork {
    std::string           workshop_id;
    std::filesystem::path scene_json;
    std::size_t           expectations = 0;
    std::size_t           compile_jobs  = 0;
};

struct CorpusShaderWork {
    std::size_t                      expectations = 0;
    std::size_t                      compile_jobs  = 0;
    std::vector<WorkshopShaderWork>  workshops;
};

std::optional<nlohmann::json> ReadJsonFile(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (! input.good()) return std::nullopt;

    auto parsed = nlohmann::json::parse(input, nullptr, false);
    if (parsed.is_discarded()) return std::nullopt;
    return parsed;
}

std::filesystem::path LexicallyNormalAbsolute(const std::filesystem::path& path) {
    return std::filesystem::absolute(path).lexically_normal();
}

bool IsPathWithin(const std::filesystem::path& path, const std::filesystem::path& root) {
    const auto normalized_path = LexicallyNormalAbsolute(path);
    const auto normalized_root = LexicallyNormalAbsolute(root);
    auto       root_iter       = normalized_root.begin();
    auto       path_iter       = normalized_path.begin();
    for (; root_iter != normalized_root.end(); ++root_iter, ++path_iter) {
        if (path_iter == normalized_path.end() || *path_iter != *root_iter) return false;
    }
    return true;
}

std::optional<std::filesystem::path> ResolveCorpusRelativePath(
    const std::filesystem::path& root, const std::string& relative_path) {
    const std::filesystem::path path(relative_path);
    if (relative_path.empty() || path.is_absolute()) return std::nullopt;

    const auto candidate = LexicallyNormalAbsolute(root / path);
    const auto root_abs  = LexicallyNormalAbsolute(root);
    if (! IsPathWithin(candidate, root_abs)) return std::nullopt;
    return candidate;
}

bool IsBroadFilesystemRoot(const std::filesystem::path& path) {
    const auto normalized = LexicallyNormalAbsolute(path);
    return normalized == normalized.root_path() || normalized == "/System" ||
           normalized == "/Library" || normalized == "/Users" || normalized == "/private" ||
           normalized == "/Volumes";
}

testing::AssertionResult ValidateCorpusRoot(const std::filesystem::path& root) {
    if (IsBroadFilesystemRoot(root)) {
        return testing::AssertionFailure()
               << "refusing to enumerate broad corpus root '" << root
               << "'; configure UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT to the unpack directory";
    }

    std::error_code ec;
    const auto      status = std::filesystem::symlink_status(root, ec);
    if (ec) {
        return testing::AssertionFailure() << "failed to stat corpus root '" << root
                                           << "': " << ec.message();
    }
    if (! std::filesystem::exists(status)) {
        return testing::AssertionFailure() << "corpus root does not exist: " << root;
    }
    if (! std::filesystem::is_directory(status)) {
        return testing::AssertionFailure() << "corpus root is not a directory: " << root;
    }
    if (std::filesystem::is_symlink(status)) {
        return testing::AssertionFailure()
               << "refusing symlink corpus root '" << root
               << "'; use the real unpack directory to avoid traversing outside the corpus";
    }

    return testing::AssertionSuccess();
}

std::vector<std::filesystem::path> FindWorkshopSceneDirs(const std::filesystem::path& root) {
    std::vector<std::filesystem::path> dirs;
    if (! std::filesystem::exists(root) || ! std::filesystem::is_directory(root)) {
        return dirs;
    }

    const auto normalized_root = LexicallyNormalAbsolute(root);
    std::error_code ec;
    const std::filesystem::directory_options options =
        std::filesystem::directory_options::skip_permission_denied;
    for (const auto& entry : std::filesystem::directory_iterator(root, options, ec)) {
        if (ec) break;
        const auto entry_path = entry.path();
        if (! IsPathWithin(entry_path, normalized_root)) continue;
        if (entry.is_symlink(ec) || ec) {
            ec.clear();
            continue;
        }
        if (! entry.is_directory(ec) || ec) {
            ec.clear();
            continue;
        }
        const auto scene_json_path = entry_path / "scene.json";
        if (std::filesystem::is_regular_file(scene_json_path, ec)) dirs.push_back(entry_path);
        ec.clear();
        if (dirs.size() > kMaxWorkshopSceneDirs) break;
    }
    std::sort(dirs.begin(), dirs.end());
    return dirs;
}

bool MountPhysical(fs::VFS& vfs, const std::filesystem::path& path, std::string_view name = {}) {
    auto physical_fs = fs::CreatePhysicalFs(path.string());
    if (physical_fs == nullptr) return false;
    return vfs.Mount("/assets", std::move(physical_fs), name);
}

void AddAssetBlocker(std::string_view workshop_id, const std::filesystem::path& scene_json,
                     bool mounted_common_assets, const std::string& asset_kind,
                     const std::string& asset_path, const std::string& context,
                     std::vector<NonShaderBlocker>& blockers) {
    std::ostringstream message;
    message << "missing/unreadable " << asset_kind << " JSON asset";
    if (! asset_path.empty()) message << " '" << asset_path << "'";
    if (! context.empty()) message << " for " << context;
    blockers.push_back(
        { std::string(workshop_id), scene_json, mounted_common_assets, message.str() });
}

std::optional<std::pair<nlohmann::json, std::filesystem::path>>
ReadAssetJson(const std::filesystem::path& scene_dir, const std::string& asset_path,
              std::string_view workshop_id, const std::filesystem::path& scene_json,
              bool mounted_common_assets, const std::string& asset_kind, const std::string& context,
              std::vector<NonShaderBlocker>& blockers) {
    if (asset_path.empty()) return std::nullopt;

    if (const auto workshop_path = ResolveCorpusRelativePath(scene_dir, asset_path)) {
        if (auto json = ReadJsonFile(*workshop_path)) {
            return std::make_pair(std::move(*json), *workshop_path);
        }
    }

    if (! CommonAssets().empty()) {
        if (const auto common_path = ResolveCorpusRelativePath(CommonAssets(), asset_path)) {
            if (auto json = ReadJsonFile(*common_path)) {
                return std::make_pair(std::move(*json), *common_path);
            }
        }
    }

    AddAssetBlocker(
        workshop_id, scene_json, mounted_common_assets, asset_kind, asset_path, context, blockers);
    return std::nullopt;
}

std::string JsonStringValue(const nlohmann::json& json, std::string_view key) {
    if (! json.is_object() || ! json.contains(key) || ! json.at(key).is_string()) return {};
    return json.at(key).get<std::string>();
}

bool JsonBoolValue(const nlohmann::json& json, std::string_view key, bool fallback) {
    if (! json.is_object() || ! json.contains(key)) return fallback;
    const auto& value = json.at(key);
    if (value.is_boolean()) return value.get<bool>();
    if (value.is_object() && value.contains("value") && value.at("value").is_boolean()) {
        return value.at("value").get<bool>();
    }
    return fallback;
}

int32_t JsonIntValue(const nlohmann::json& json, std::string_view key, int32_t fallback) {
    if (! json.is_object() || ! json.contains(key) || ! json.at(key).is_number_integer()) {
        return fallback;
    }
    return json.at(key).get<int32_t>();
}

/// Whether a layer's colour blend mode is drawn through the passthrough
/// material: every mode but 0 and 31, which is drawn additively instead.
bool ColorBlendNeedsPassthrough(const nlohmann::json& object) {
    const auto mode = JsonIntValue(object, "colorBlendMode", 0);
    return mode != 0 && mode != 31;
}

bool HasDynamicVisibility(const nlohmann::json& json) {
    if (! json.is_object() || ! json.contains("visible") || ! json.at("visible").is_object()) {
        return false;
    }
    const auto& visible = json.at("visible");
    return visible.contains("script") || visible.contains("user");
}

bool HasChildObject(const nlohmann::json& objects, int32_t parent_id) {
    if (! objects.is_array()) return false;
    for (const auto& object : objects) {
        if (JsonIntValue(object, "parent", -1) == parent_id) return true;
    }
    return false;
}

bool IsLayerObject(const nlohmann::json& object) {
    return ! object.contains("image") && ! object.contains("particle") &&
           ! object.contains("sound") && ! object.contains("light") && ! object.contains("text") &&
           ! object.contains("model") && ! object.contains("camera");
}

bool IsSchemaOnlyObject(const nlohmann::json& object) {
    return (object.contains("text") && ! object.at("text").is_null()) ||
           (object.contains("model") && ! object.at("model").is_null()) ||
           (object.contains("camera") && ! object.at("camera").is_null());
}

bool IsCountedLayerObject(const nlohmann::json& object, const nlohmann::json& objects) {
    const auto id = JsonIntValue(object, "id", 0);
    if (! IsLayerObject(object) &&
        (! IsSchemaOnlyObject(object) || id == 0 || ! HasChildObject(objects, id))) {
        return false;
    }
    return id != 0;
}

std::string NodeRuntimeName(const std::string& name, int32_t id, uint32_t count) {
    if (! name.empty() && count <= 1u) return name;
    return "__we_layer_" + std::to_string(id);
}

bool IsVisibleShaderObject(const nlohmann::json& object) {
    return JsonBoolValue(object, "visible", true) || HasDynamicVisibility(object);
}

std::unordered_map<int32_t, std::string> BuildRuntimeNames(const nlohmann::json& objects) {
    std::unordered_map<std::string, uint32_t> name_counts;
    std::unordered_map<int32_t, std::string>  runtime_names;

    if (! objects.is_array()) return runtime_names;

    for (const auto& object : objects) {
        if ((object.contains("image") && ! object.at("image").is_null()) ||
            (object.contains("particle") && ! object.at("particle").is_null())) {
            if (! IsVisibleShaderObject(object)) continue;
            const auto name = JsonStringValue(object, "name");
            if (! name.empty()) ++name_counts[name];
        } else if (IsCountedLayerObject(object, objects)) {
            const auto name = JsonStringValue(object, "name");
            if (! name.empty()) ++name_counts[name];
        }
    }

    for (const auto& object : objects) {
        if ((! object.contains("image") || object.at("image").is_null()) &&
            (! object.contains("particle") || object.at("particle").is_null())) {
            continue;
        }
        if (! IsVisibleShaderObject(object)) continue;

        const auto id     = JsonIntValue(object, "id", 0);
        const auto name   = JsonStringValue(object, "name");
        const auto count  = name.empty() ? 0u : name_counts[name];
        runtime_names[id] = NodeRuntimeName(name, id, count);
    }

    return runtime_names;
}

std::string RuntimeNameForObject(const nlohmann::json&                           object,
                                 const std::unordered_map<int32_t, std::string>& runtime_names) {
    const auto id = JsonIntValue(object, "id", 0);
    if (const auto it = runtime_names.find(id); it != runtime_names.end()) return it->second;

    const auto name = JsonStringValue(object, "name");
    if (! name.empty()) return name;
    return "__we_layer_" + std::to_string(id);
}

std::optional<std::string> MaterialShaderName(const nlohmann::json& material_json) {
    if (! material_json.is_object() || ! material_json.contains("passes") ||
        ! material_json.at("passes").is_array() || material_json.at("passes").empty()) {
        return std::nullopt;
    }

    const auto& first_pass = material_json.at("passes").at(0);
    if (! first_pass.is_object() || ! first_pass.contains("shader") ||
        ! first_pass.at("shader").is_string()) {
        return std::nullopt;
    }
    return first_pass.at("shader").get<std::string>();
}

const nlohmann::json* FirstMaterialPass(const nlohmann::json& material_json) {
    if (! material_json.is_object() || ! material_json.contains("passes") ||
        ! material_json.at("passes").is_array() || material_json.at("passes").empty() ||
        ! material_json.at("passes").at(0).is_object()) {
        return nullptr;
    }
    return &material_json.at("passes").at(0);
}

std::optional<DirectShaderCompileJob> BuildDirectShaderCompileJob(
    const ExpectedShaderContext& expectation, const nlohmann::json& material_json) {
    const auto* first_pass = FirstMaterialPass(material_json);
    if (first_pass == nullptr) return std::nullopt;

    auto shader_name = expectation.shader_name;
    if (shader_name.empty()) shader_name = JsonStringValue(*first_pass, "shader");
    if (shader_name.empty()) return std::nullopt;

    DirectShaderCompileJob job {
        .source_path   = expectation.source_path,
        .context       = expectation.context,
        .shader_name   = shader_name,
        .shader_path   = "shaders/" + shader_name,
        .combos        = {},
        .base_textures = {},
    };

    if (JsonStringValue(*first_pass, "blending") == "alphatocoverage") {
        job.combos["ALPHATOCOVERAGE"] = "1";
    }

    if (first_pass->contains("combos") && first_pass->at("combos").is_object()) {
        for (const auto& combo : first_pass->at("combos").items()) {
            if (combo.value().is_number_integer()) {
                job.combos[combo.key()] = std::to_string(combo.value().get<int32_t>());
            }
        }
    }

    for (const auto& [name, value] : expectation.scene_combos) job.combos[name] = value;

    if (first_pass->contains("textures") && first_pass->at("textures").is_array()) {
        job.base_textures.reserve(first_pass->at("textures").size());
        for (const auto& texture : first_pass->at("textures")) {
            job.base_textures.push_back(texture.is_string() ? texture.get<std::string>()
                                                            : std::string {});
        }
    }

    return job;
}

std::vector<WPShaderTexInfo> BuildConservativeTextureInfos(
    const std::vector<std::string>& textures) {
    std::vector<WPShaderTexInfo> tex_infos;
    tex_infos.reserve(textures.size());
    for (const auto& texture : textures) {
        WPShaderTexInfo info;
        info.present = ! texture.empty();
        info.enabled = info.present;
        tex_infos.push_back(info);
    }
    return tex_infos;
}

std::optional<DirectShaderCompileJob> BuildDirectShaderCompileJob(
    const ExpectedShaderContext& expectation, std::vector<NonShaderBlocker>& blockers,
    std::string_view workshop_id, const std::filesystem::path& scene_json,
    bool mounted_common_assets) {
    const auto material_json = ReadJsonFile(expectation.source_path);
    if (! material_json.has_value()) {
        AddAssetBlocker(workshop_id,
                        scene_json,
                        mounted_common_assets,
                        "material",
                        expectation.source_path.string(),
                        expectation.context,
                        blockers);
        return std::nullopt;
    }
    return BuildDirectShaderCompileJob(expectation, *material_json);
}

/// The integer combos of one pass entry, as the engine reads them from a
/// scene's effect or an effect file's pass. Others are left out, like a
/// material's own.
void AddPassCombos(const nlohmann::json& pass, wallpaper::Combos& combos) {
    if (! pass.is_object() || ! pass.contains("combos") || ! pass.at("combos").is_object()) {
        return;
    }
    for (const auto& combo : pass.at("combos").items()) {
        if (combo.value().is_number_integer()) {
            combos[combo.key()] = std::to_string(combo.value().get<int32_t>());
        }
    }
}

void AddMaterialExpectation(const std::filesystem::path& scene_dir,
                            const std::string& material_path, const std::string& context,
                            const std::string& identity_key, std::string_view workshop_id,
                            const std::filesystem::path& scene_json, bool mounted_common_assets,
                            std::vector<ExpectedShaderContext>& expected,
                            std::vector<NonShaderBlocker>&      blockers,
                            std::optional<std::string>          shader_override = std::nullopt,
                            wallpaper::Combos                   scene_combos    = {}) {
    auto material = ReadAssetJson(scene_dir,
                                  material_path,
                                  workshop_id,
                                  scene_json,
                                  mounted_common_assets,
                                  "material",
                                  context,
                                  blockers);
    if (! material.has_value()) return;

    auto shader_name = shader_override.has_value()
                           ? std::move(*shader_override)
                           : MaterialShaderName(material->first).value_or(std::string {});
    if (shader_name.empty()) return;

    expected.push_back({
        .source_path  = material->second,
        .context      = context,
        .identity_key = identity_key,
        .shader_name  = shader_name,
        .shader_path  = "shaders/" + shader_name,
        .scene_combos = std::move(scene_combos),
    });
}

std::string ObjectContext(const nlohmann::json& object, std::string_view kind) {
    const auto         name = JsonStringValue(object, "name");
    const auto         id   = JsonIntValue(object, "id", 0);
    std::ostringstream out;
    out << kind << ":";
    if (! name.empty()) {
        out << name;
    } else {
        out << "<unnamed>";
    }
    out << "/id:" << id;
    return out.str();
}

void CollectEffectExpectations(const std::filesystem::path& scene_dir,
                               const nlohmann::json& effect_ref, const std::string& context,
                               const std::string& owner_identity, std::size_t effect_index,
                               std::string_view             workshop_id,
                               const std::filesystem::path& scene_json, bool mounted_common_assets,
                               std::vector<ExpectedShaderContext>& expected,
                               std::vector<NonShaderBlocker>&      blockers) {
    if (! JsonBoolValue(effect_ref, "visible", true)) return;

    const auto effect_path = JsonStringValue(effect_ref, "file");
    if (effect_path.empty()) return;

    auto effect = ReadAssetJson(scene_dir,
                                effect_path,
                                workshop_id,
                                scene_json,
                                mounted_common_assets,
                                "effect",
                                context,
                                blockers);
    if (! effect.has_value() || ! effect->first.is_object() || ! effect->first.contains("passes") ||
        ! effect->first.at("passes").is_array()) {
        return;
    }

    const auto effect_name = JsonStringValue(effect->first, "name");
    const auto effect_context =
        context + "/effect:" + (effect_name.empty() ? effect_path : effect_name);

    // The scene's entries for the effect's passes follow its material passes in
    // order, a command pass not counted.
    const auto* scene_passes = effect_ref.is_object() && effect_ref.contains("passes") &&
                                       effect_ref.at("passes").is_array()
                                   ? &effect_ref.at("passes")
                                   : nullptr;
    std::size_t raw_pass_index      = 0;
    std::size_t material_pass_index = 0;
    for (const auto& pass : effect->first.at("passes")) {
        const auto material_path = JsonStringValue(pass, "material");
        if (! material_path.empty()) {
            wallpaper::Combos scene_combos;
            AddPassCombos(pass, scene_combos);
            if (scene_passes != nullptr && material_pass_index < scene_passes->size()) {
                AddPassCombos(scene_passes->at(material_pass_index), scene_combos);
            }
            AddMaterialExpectation(scene_dir,
                                   material_path,
                                   effect_context + "/source-pass-" +
                                       std::to_string(raw_pass_index),
                                   owner_identity + "/effect-" + std::to_string(effect_index) +
                                       "/pass-" + std::to_string(material_pass_index) +
                                       "/material-slot-0",
                                   workshop_id,
                                   scene_json,
                                   mounted_common_assets,
                                   expected,
                                   blockers,
                                   std::nullopt,
                                   std::move(scene_combos));
            ++material_pass_index;
        }
        ++raw_pass_index;
    }
}

std::optional<std::string> ParticleShaderOverride(const nlohmann::json& particle_json) {
    if (! particle_json.is_object() || ! particle_json.contains("renderer") ||
        ! particle_json.at("renderer").is_array() || particle_json.at("renderer").empty()) {
        return std::nullopt;
    }

    // Mirrors the parser: every rope renderer, a rope trail included, draws
    // with the rope shader. A rope trail is no longer loaded as a sprite trail.
    const auto renderer_name = JsonStringValue(particle_json.at("renderer").at(0), "name");
    if (renderer_name.starts_with("rope")) return std::string("genericropeparticle");
    return std::nullopt;
}

void CollectParticleExpectations(const std::filesystem::path& scene_dir,
                                 const std::string& particle_path, const std::string& context,
                                 const std::string& particle_identity, std::string_view workshop_id,
                                 const std::filesystem::path&        scene_json,
                                 bool                                mounted_common_assets,
                                 std::vector<ExpectedShaderContext>& expected,
                                 std::vector<NonShaderBlocker>&      blockers,
                                 std::unordered_set<std::string>&    visiting_particles) {
    if (particle_path.empty()) return;
    if (! visiting_particles.insert(particle_path).second) return;

    auto particle = ReadAssetJson(scene_dir,
                                  particle_path,
                                  workshop_id,
                                  scene_json,
                                  mounted_common_assets,
                                  "particle",
                                  context,
                                  blockers);
    if (! particle.has_value()) {
        visiting_particles.erase(particle_path);
        return;
    }

    const auto material_path = JsonStringValue(particle->first, "material");
    if (! material_path.empty()) {
        AddMaterialExpectation(scene_dir,
                               material_path,
                               context + "/particle-material:" + material_path,
                               particle_identity + "/material-slot-0",
                               workshop_id,
                               scene_json,
                               mounted_common_assets,
                               expected,
                               blockers,
                               ParticleShaderOverride(particle->first));
    }

    if (particle->first.contains("children") && particle->first.at("children").is_array()) {
        std::size_t child_index = 0;
        for (const auto& child : particle->first.at("children")) {
            const auto child_path = JsonStringValue(child, "name");
            const auto child_type = JsonStringValue(child, "type");
            CollectParticleExpectations(
                scene_dir,
                child_path,
                context + "/child-" + std::to_string(child_index) +
                    (child_type.empty() ? std::string {} : "/type:" + child_type),
                particle_identity + "/child-" + std::to_string(child_index),
                workshop_id,
                scene_json,
                mounted_common_assets,
                expected,
                blockers,
                visiting_particles);
            ++child_index;
        }
    }

    visiting_particles.erase(particle_path);
}

void CollectImageExpectations(const std::filesystem::path& scene_dir, fs::VFS& vfs,
                              const nlohmann::json& object, const nlohmann::json& objects,
                              const std::unordered_map<int32_t, std::string>& runtime_names,
                              std::string_view workshop_id, const std::filesystem::path& scene_json,
                              bool                                mounted_common_assets,
                              std::vector<ExpectedShaderContext>& expected,
                              std::vector<NonShaderBlocker>&      blockers) {
    if (! JsonBoolValue(object, "visible", true) && ! HasDynamicVisibility(object)) return;

    const auto image_path = JsonStringValue(object, "image");
    auto       image      = ReadAssetJson(scene_dir,
                               image_path,
                               workshop_id,
                               scene_json,
                               mounted_common_assets,
                               "image",
                               ObjectContext(object, "image"),
                               blockers);
    if (! image.has_value()) return;

    const auto runtime_name   = RuntimeNameForObject(object, runtime_names);
    const auto identity_scope = "node:" + runtime_name;
    const auto context        = ObjectContext(object, "image") + "/source:" + image_path;

    bool passthrough = JsonBoolValue(image->first, "passthrough", false);
    if (object.contains("config") && object.at("config").is_object()) {
        passthrough = JsonBoolValue(object.at("config"), "passthrough", passthrough);
    }

    const auto  id                = JsonIntValue(object, "id", 0);
    const bool  is_compose        = image_path == "models/util/composelayer.json";
    const bool  has_child_content = HasChildObject(objects, id);
    const bool  copy_background   = JsonBoolValue(object, "copybackground", true);
    std::size_t visible_effects   = 0;
    if (object.contains("effects") && object.at("effects").is_array()) {
        for (const auto& effect_ref : object.at("effects")) {
            const auto effect_path = JsonStringValue(effect_ref, "file");
            if (JsonBoolValue(effect_ref, "visible", true)) ++visible_effects;
        }
    }
    if (ColorBlendNeedsPassthrough(object)) ++visible_effects;

    const bool render_as_compose =
        is_compose && has_child_content && (! copy_background || visible_effects > 0);
    const bool has_effect =
        visible_effects > 0 || render_as_compose || (is_compose && ! copy_background);
    const bool skip_compose_render = is_compose && ! has_effect;

    std::optional<WPMdl> puppet;
    const auto           puppet_path = JsonStringValue(image->first, "puppet");
    if (! puppet_path.empty()) {
        WPMdl parsed_puppet;
        if (! ResolveCorpusRelativePath(scene_dir, puppet_path).has_value()) {
            blockers.push_back({ std::string(workshop_id),
                                 scene_json,
                                 mounted_common_assets,
                                 "puppet model asset path escapes corpus/common roots '" +
                                     puppet_path + "' for " + context });
        } else if (WPMdlParser::Parse(puppet_path, vfs, parsed_puppet)) {
            bool has_puppet_mesh = false;
            for (const auto& mesh : parsed_puppet.meshes) {
                if (! mesh.positions.empty()) has_puppet_mesh = true;
            }
            const bool has_puppet_bones =
                parsed_puppet.puppet != nullptr && ! parsed_puppet.puppet->bones.empty();
            if (has_puppet_bones || has_puppet_mesh) puppet = std::move(parsed_puppet);
        } else {
            blockers.push_back(
                { std::string(workshop_id),
                  scene_json,
                  mounted_common_assets,
                  "missing/unreadable puppet model asset '" + puppet_path + "' for " + context });
        }
    }

    bool suppress_base_material_for_puppet_slots = false;
    if (puppet.has_value() && ! has_effect && ! puppet->meshes.empty()) {
        suppress_base_material_for_puppet_slots = true;
        bool                               has_readable_puppet_material_slots = true;
        std::vector<ExpectedShaderContext> puppet_slot_expectations;
        for (std::size_t slot_index = 0; slot_index < puppet->meshes.size(); ++slot_index) {
            const auto& material_path = puppet->meshes[slot_index].mat_json_file;
            if (material_path.empty()) {
                has_readable_puppet_material_slots = false;
                blockers.push_back({ std::string(workshop_id),
                                     scene_json,
                                     mounted_common_assets,
                                     "puppet mesh " + std::to_string(slot_index) +
                                         " has no material JSON asset for " + context });
                break;
            }
            auto material = ReadAssetJson(scene_dir,
                                          material_path,
                                          workshop_id,
                                          scene_json,
                                          mounted_common_assets,
                                          "puppet material",
                                          context + "/puppet-material:" + material_path,
                                          blockers);
            if (! material.has_value()) {
                has_readable_puppet_material_slots = false;
                break;
            }
            auto shader_name = MaterialShaderName(material->first).value_or(std::string {});
            if (shader_name.empty()) continue;
            puppet_slot_expectations.push_back({
                .source_path  = material->second,
                .context      = context + "/puppet-material:" + material_path,
                .identity_key = identity_scope + "/material-slot-" + std::to_string(slot_index),
                .shader_name  = shader_name,
                .shader_path  = "shaders/" + shader_name,
            });
        }
        if (has_readable_puppet_material_slots) {
            expected.insert(expected.end(),
                            puppet_slot_expectations.begin(),
                            puppet_slot_expectations.end());
        }
    }

    if (! skip_compose_render && ! (passthrough && ! has_effect && ! is_compose)) {
        const auto material_path = JsonStringValue(image->first, "material");
        if (! material_path.empty() && ! suppress_base_material_for_puppet_slots) {
            AddMaterialExpectation(scene_dir,
                                   material_path,
                                   context + "/image-material:" + material_path,
                                   identity_scope + "/material-slot-0",
                                   workshop_id,
                                   scene_json,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
        }
    }

    if (object.contains("effects") && object.at("effects").is_array()) {
        std::size_t visible_effect_index = 0;
        for (const auto& effect_ref : object.at("effects")) {
            if (! JsonBoolValue(effect_ref, "visible", true)) continue;
            CollectEffectExpectations(scene_dir,
                                      effect_ref,
                                      context,
                                      identity_scope,
                                      visible_effect_index,
                                      workshop_id,
                                      scene_json,
                                      mounted_common_assets,
                                      expected,
                                      blockers);
            ++visible_effect_index;
        }
        if (ColorBlendNeedsPassthrough(object)) {
            AddMaterialExpectation(scene_dir,
                                   "materials/util/effectpassthrough.json",
                                   context + "/effect:colorBlendMode/passthrough",
                                   identity_scope + "/effect-" +
                                       std::to_string(visible_effect_index) +
                                       "/pass-0/material-slot-0",
                                   workshop_id,
                                   scene_json,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
        }
    } else if (ColorBlendNeedsPassthrough(object)) {
        AddMaterialExpectation(scene_dir,
                               "materials/util/effectpassthrough.json",
                               context + "/effect:colorBlendMode/passthrough",
                               identity_scope + "/effect-0/pass-0/material-slot-0",
                               workshop_id,
                               scene_json,
                               mounted_common_assets,
                               expected,
                               blockers);
    }

    if (render_as_compose &&
        (! object.contains("effects") || ! object.at("effects").is_array() ||
         object.at("effects").empty()) &&
        ! ColorBlendNeedsPassthrough(object)) {
        AddMaterialExpectation(scene_dir,
                               "materials/util/effectpassthrough.json",
                               context + "/effect:compose-passthrough",
                               identity_scope + "/effect-0/pass-0/material-slot-0",
                               workshop_id,
                               scene_json,
                               mounted_common_assets,
                               expected,
                               blockers);
    }
}

std::vector<ExpectedShaderContext> CollectSourceShaderExpectations(
    const std::filesystem::path& scene_dir, fs::VFS& vfs, const nlohmann::json& scene_json,
    std::string_view workshop_id, const std::filesystem::path& scene_json_path,
    bool mounted_common_assets, std::vector<NonShaderBlocker>& blockers) {
    std::vector<ExpectedShaderContext> expected;
    if (! scene_json.is_object() || ! scene_json.contains("objects") ||
        ! scene_json.at("objects").is_array()) {
        return expected;
    }

    const auto& objects       = scene_json.at("objects");
    const auto  runtime_names = BuildRuntimeNames(objects);
    for (const auto& object : objects) {
        if (object.contains("image") && ! object.at("image").is_null()) {
            CollectImageExpectations(scene_dir,
                                     vfs,
                                     object,
                                     objects,
                                     runtime_names,
                                     workshop_id,
                                     scene_json_path,
                                     mounted_common_assets,
                                     expected,
                                     blockers);
        } else if (object.contains("particle") && ! object.at("particle").is_null()) {
            if (! JsonBoolValue(object, "visible", true) && ! HasDynamicVisibility(object)) {
                continue;
            }
            const auto runtime_name = RuntimeNameForObject(object, runtime_names);
            std::unordered_set<std::string> visiting_particles;
            CollectParticleExpectations(scene_dir,
                                        JsonStringValue(object, "particle"),
                                        ObjectContext(object, "particle"),
                                        "node:" + runtime_name,
                                        workshop_id,
                                        scene_json_path,
                                        mounted_common_assets,
                                        expected,
                                        blockers,
                                        visiting_particles);
        }
    }

    if (scene_json.contains("general") && scene_json.at("general").is_object()) {
        const auto& general = scene_json.at("general");
        if (JsonBoolValue(general, "bloom", false)) {
            AddMaterialExpectation(scene_dir,
                                   "materials/util/downsample_quarter_bloom.json",
                                   "post-process:__bloom/downsample-quarter",
                                   "post-process:__bloom/step-0/material-slot-0",
                                   workshop_id,
                                   scene_json_path,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
            AddMaterialExpectation(scene_dir,
                                   "materials/util/downsample_eighth_blur_v.json",
                                   "post-process:__bloom/downsample-eighth",
                                   "post-process:__bloom/step-1/material-slot-0",
                                   workshop_id,
                                   scene_json_path,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
            AddMaterialExpectation(scene_dir,
                                   "materials/util/blur_h_bloom.json",
                                   "post-process:__bloom/blur-horizontal",
                                   "post-process:__bloom/step-2/material-slot-0",
                                   workshop_id,
                                   scene_json_path,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
            AddMaterialExpectation(scene_dir,
                                   "materials/util/combine_ldr.json",
                                   "post-process:__bloom/combine",
                                   "post-process:__bloom/step-3/material-slot-0",
                                   workshop_id,
                                   scene_json_path,
                                   mounted_common_assets,
                                   expected,
                                   blockers);
        }
    }

    return expected;
}

std::string ShaderStageName(std::size_t index) {
    switch (index) {
    case 0: return "vertex";
    case 1: return "fragment";
    default: return "stage-" + std::to_string(index);
    }
}

bool LooksLikeSpirv(const ShaderCode& code) {
    return ! code.empty() && code.front() == kSpirvMagicWord;
}

std::array<WPShaderUnit, 2> LoadShaderUnits(fs::VFS& vfs, const DirectShaderCompileJob& job) {
    const auto shader_path = "/assets/" + job.shader_path;
    return {
        WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = fs::GetFileContent(vfs, shader_path + ".vert"),
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = fs::GetFileContent(vfs, shader_path + ".frag"),
            .preprocess_info = {},
        },
    };
}

void CheckCompiledSpirv(const std::vector<ShaderCode>& codes, const DirectShaderCompileJob& job,
                        std::string_view workshop_id, const std::filesystem::path& scene_json,
                        bool mounted_common_assets, std::vector<ShaderFailure>& failures) {
    if (codes.size() < 2) {
        failures.push_back(
            { std::string(workshop_id),
              scene_json,
              mounted_common_assets,
              job.source_path,
              job.context,
              job.shader_name,
              job.shader_path,
              codes.empty() ? std::string("vertex") : std::string("fragment"),
              {},
              "direct Rust shader compile output",
              "compiled shader is missing required vertex/fragment SPIR-V stages" });
    }

    for (std::size_t i = 0; i < codes.size(); ++i) {
        if (LooksLikeSpirv(codes[i])) continue;
        const auto message = codes[i].empty()
                                 ? "compiled " + ShaderStageName(i) + " SPIR-V stage is empty"
                                 : "compiled " + ShaderStageName(i) +
                                       " stage does not start with SPIR-V magic word 0x07230203";
        failures.push_back({ std::string(workshop_id),
                             scene_json,
                             mounted_common_assets,
                             job.source_path,
                             job.context,
                             job.shader_name,
                             job.shader_path,
                             ShaderStageName(i),
                             {},
                             "direct Rust shader compile output[" + std::to_string(i) + "]",
                             message });
    }
}

void CompileDirectShaderJob(fs::VFS& vfs, const DirectShaderCompileJob& job,
                            std::string_view workshop_id,
                            const std::filesystem::path& scene_json, bool mounted_common_assets,
                            std::vector<ShaderFailure>& failures) {
    auto units = LoadShaderUnits(vfs, job);
    if (units[0].src.empty() || units[1].src.empty()) {
        failures.push_back({ std::string(workshop_id),
                             scene_json,
                             mounted_common_assets,
                             job.source_path,
                             job.context,
                             job.shader_name,
                             job.shader_path,
                             units[0].src.empty() ? std::string("vertex") : std::string("fragment"),
                             {},
                             "shader source",
                             "missing/unreadable shader source" });
        return;
    }

    WPShaderInfo shader_info;
    shader_info.combos = job.combos;
    auto                    textures = job.base_textures;
    std::vector<ShaderCode> codes;
    std::string             reflection_json;
    constexpr std::size_t   kMaxDefaultTextureCompilePasses = 8;
    for (std::size_t pass = 0; pass < kMaxDefaultTextureCompilePasses; ++pass) {
        codes.clear();
        reflection_json.clear();
        for (auto& unit : units) {
            unit.preprocess_info = {};
        }

        const auto tex_infos = BuildConservativeTextureInfos(textures);
        if (! WPShaderParser::CompileToSpvRust("unpack-shader-compile-smoke",
                                               job.shader_name,
                                               units,
                                               codes,
                                               vfs,
                                               &shader_info,
                                               tex_infos,
                                               &reflection_json)) {
            failures.push_back({ std::string(workshop_id),
                                 scene_json,
                                 mounted_common_assets,
                                 job.source_path,
                                 job.context,
                                 job.shader_name,
                                 job.shader_path,
                                 "unknown",
                                 {},
                                 "Rust shader compiler",
                                 wallpaper::shader::LastRustShaderError() });
            return;
        }

        auto next_textures = job.base_textures;
        for (const auto& [slot, texture] : shader_info.defTexs) {
            if (slot < 0) continue;
            const auto index = static_cast<std::size_t>(slot);
            if (next_textures.size() <= index) next_textures.resize(index + 1);
            if (next_textures[index].empty()) next_textures[index] = texture;
        }
        if (next_textures == textures) break;
        if (pass + 1 == kMaxDefaultTextureCompilePasses) {
            failures.push_back({ std::string(workshop_id),
                                 scene_json,
                                 mounted_common_assets,
                                 job.source_path,
                                 job.context,
                                 job.shader_name,
                                 job.shader_path,
                                 "all",
                                 {},
                                 "Rust shader default texture metadata",
                                 "default texture list did not stabilize" });
            return;
        }
        textures = std::move(next_textures);
    }

    CheckCompiledSpirv(codes, job, workshop_id, scene_json, mounted_common_assets, failures);
}

std::string ShaderFailureReport(const std::vector<ShaderFailure>& failures) {
    std::ostringstream out;
    out << "shader compile smoke found shader pipeline failures\n"
        << "The smoke test compiles shader-bearing materials directly from source JSON to avoid "
           "texture image/header parsing.\n";
    for (const auto& failure : failures) {
        out << "- workshop " << failure.workshop_id << "\n  scene: " << failure.scene_json
            << "\n  common assets: " << CommonAssets().string()
            << (failure.mounted_common_assets ? " (mounted)" : " (missing/not mounted)");
        if (! failure.source_path.empty()) {
            out << "\n  source: " << failure.source_path;
        }
        if (! failure.shader_path.empty()) {
            out << "\n  shader path: " << failure.shader_path;
        }
        if (! failure.stage.empty()) {
            out << "\n  stage: " << failure.stage;
        }
        if (! failure.generated_glsl_path.empty()) {
            out << "\n  generated GLSL: " << failure.generated_glsl_path;
        }
        if (! failure.diagnostic_source.empty()) {
            out << "\n  diagnostic source: " << failure.diagnostic_source;
        }
        out << "\n  " << failure.context << " shader='" << failure.shader_name
            << "': " << failure.message << "\n";
    }
    return out.str();
}

std::string NonShaderBlockerReport(const std::vector<NonShaderBlocker>& blockers) {
    std::ostringstream out;
    out << "shader compile smoke skipped " << blockers.size()
        << " blocker(s) because shader-bearing source JSON could not be read\n";
    for (const auto& blocker : blockers) {
        out << "- workshop " << blocker.workshop_id << "\n  scene: " << blocker.scene_json
            << "\n  common assets: " << CommonAssets().string()
            << (blocker.mounted_common_assets ? " (mounted)" : " (missing/not mounted)")
            << "\n  blocker: " << blocker.message << "\n";
    }
    return out.str();
}

} // namespace

TEST(UnpackShaderCompileSmoke, BuildsDirectCompileJobFromMaterialJsonWithoutTextureHeaders) {
    const auto material = nlohmann::json::parse(R"({
        "passes": [{
            "shader": "effects/custom",
            "blending": "alphatocoverage",
            "textures": ["materials/albedo.tex", null, "materials/mask.tex"],
            "combos": {
                "USE_DETAIL": 1,
                "MODE": 3
            }
        }]
    })");
    const ExpectedShaderContext expectation {
        .source_path  = "/workshop/materials/custom.json",
        .context      = "image:Layer/id:7/image-material:materials/custom.json",
        .identity_key = "node:Layer/material-slot-0",
        .shader_name  = "effects/custom",
        .shader_path  = "shaders/effects/custom",
    };

    const auto job = BuildDirectShaderCompileJob(expectation, material);

    ASSERT_TRUE(job.has_value());
    EXPECT_EQ(job->source_path, expectation.source_path);
    EXPECT_EQ(job->context, expectation.context);
    EXPECT_EQ(job->shader_name, "effects/custom");
    EXPECT_EQ(job->shader_path, "shaders/effects/custom");
    EXPECT_EQ(job->combos.at("USE_DETAIL"), "1");
    EXPECT_EQ(job->combos.at("MODE"), "3");
    EXPECT_EQ(job->combos.at("ALPHATOCOVERAGE"), "1");
    ASSERT_EQ(job->base_textures.size(), 3u);
    EXPECT_EQ(job->base_textures.at(0), "materials/albedo.tex");
    EXPECT_TRUE(job->base_textures.at(1).empty());
    EXPECT_EQ(job->base_textures.at(2), "materials/mask.tex");

    const auto tex_infos = BuildConservativeTextureInfos(job->base_textures);
    ASSERT_EQ(tex_infos.size(), 3u);
    EXPECT_TRUE(tex_infos.at(0).enabled);
    EXPECT_FALSE(tex_infos.at(0).composEnabled.at(0));
    EXPECT_FALSE(tex_infos.at(0).composEnabled.at(1));
    EXPECT_FALSE(tex_infos.at(0).composEnabled.at(2));
    EXPECT_FALSE(tex_infos.at(1).enabled);
    EXPECT_TRUE(tex_infos.at(2).enabled);
}

TEST(UnpackShaderCompileSmoke, RejectsBroadCorpusRootsBeforeEnumeration) {
    EXPECT_FALSE(ValidateCorpusRoot("/"));
    EXPECT_FALSE(ValidateCorpusRoot("/Users"));
    EXPECT_FALSE(ValidateCorpusRoot("/Library"));
    EXPECT_FALSE(ValidateCorpusRoot("/System"));
}

TEST(UnpackShaderCompileSmoke, RejectsAssetPathsThatEscapeConfiguredRoots) {
    const std::filesystem::path root = "/tmp/unpack/123";

    EXPECT_TRUE(ResolveCorpusRelativePath(root, "materials/layer.json").has_value());
    EXPECT_FALSE(ResolveCorpusRelativePath(root, "../other/scene.json").has_value());
    EXPECT_FALSE(ResolveCorpusRelativePath(root, "../../Library/Secrets/scene.json").has_value());
    EXPECT_FALSE(ResolveCorpusRelativePath(root, "/Library/Secrets/scene.json").has_value());
}

TEST(UnpackShaderCompileSmoke, CollectsVisibleEffectsUnderPreviouslyBlacklistedWorkshopPath) {
    // Per process: concurrent runs share the temporary directory, and this
    // folder is deleted before and after use.
    const std::string test_name = testing::UnitTest::GetInstance()->current_test_info()->name();
    const auto        scene_dir = std::filesystem::temp_directory_path() /
                           (test_name + "-" + std::to_string(::getpid()));
    std::filesystem::remove_all(scene_dir);
    ASSERT_TRUE(std::filesystem::create_directories(scene_dir / "materials"));
    ASSERT_TRUE(std::filesystem::create_directories(scene_dir / "2799421411/effects"));
    ASSERT_TRUE(std::filesystem::create_directories(scene_dir / "2799421411/materials"));

    {
        std::ofstream image(scene_dir / "materials/layer.json");
        image << R"({"material": ""})";
    }
    {
        std::ofstream effect(scene_dir / "2799421411/effects/visible.json");
        effect << R"({
            "name": "visible-workshop-effect",
            "passes": [{
                "material": "2799421411/materials/effect.json"
            }]
        })";
    }
    {
        std::ofstream material(scene_dir / "2799421411/materials/effect.json");
        material << R"({
            "passes": [{
                "shader": "effects/visible_workshop_shader"
            }]
        })";
    }

    const auto scene_json = nlohmann::json::parse(R"({
        "objects": [{
            "id": 7,
            "name": "Layer",
            "visible": true,
            "image": "materials/layer.json",
            "effects": [{
                "visible": true,
                "file": "2799421411/effects/visible.json"
            }]
        }]
    })");

    fs::VFS vfs;
    std::vector<NonShaderBlocker> blockers;
    const auto expected = CollectSourceShaderExpectations(scene_dir,
                                                          vfs,
                                                          scene_json,
                                                          "2799421411",
                                                          scene_dir / "scene.json",
                                                          false,
                                                          blockers);

    EXPECT_TRUE(blockers.empty()) << NonShaderBlockerReport(blockers);
    ASSERT_EQ(expected.size(), 1u);
    EXPECT_EQ(expected.at(0).source_path, scene_dir / "2799421411/materials/effect.json");
    EXPECT_EQ(expected.at(0).shader_name, "effects/visible_workshop_shader");
    EXPECT_EQ(expected.at(0).shader_path, "shaders/effects/visible_workshop_shader");
    EXPECT_EQ(expected.at(0).identity_key, "node:Layer/effect-0/pass-0/material-slot-0");
    EXPECT_NE(expected.at(0).context.find("visible-workshop-effect"), std::string::npos);

    std::filesystem::remove_all(scene_dir);
}

TEST(UnpackShaderCompileSmoke, CompilesAnEffectUnderTheCombosTheSceneSetsOnIt) {
    // A scene picks an effect's combos on its own entry for each pass (the
    // audio bars effect's SHAPE), over the effect file's and the material's.
    // A shader can compile under its defaults and fail under the scene's
    // choice, so the sweep has to compile what the scene asks for. The scene's
    // entries follow the effect's material passes; a command pass takes none.
    const std::string test_name = testing::UnitTest::GetInstance()->current_test_info()->name();
    const auto        scene_dir = std::filesystem::temp_directory_path() /
                           (test_name + "-" + std::to_string(::getpid()));
    std::filesystem::remove_all(scene_dir);
    ASSERT_TRUE(std::filesystem::create_directories(scene_dir / "materials"));
    ASSERT_TRUE(std::filesystem::create_directories(scene_dir / "effects"));

    const auto write = [&scene_dir](const std::string& path, const std::string& text) {
        std::ofstream(scene_dir / path) << text;
    };
    write("materials/layer.json", R"({"material": ""})");
    write("effects/bars.json", R"({
        "name": "bars",
        "passes": [
            { "material": "materials/first.json" },
            { "command": "copy", "target": "_rt_copy", "source": "previous" },
            { "material": "materials/second.json", "combos": { "FROM_FILE": 1, "BOTH": 1 } }
        ]
    })");
    write("materials/first.json", R"({
        "passes": [{ "shader": "effects/first", "combos": { "SHAPE": 0, "KEPT": 1 } }]
    })");
    write("materials/second.json", R"({ "passes": [{ "shader": "effects/second" }] })");

    const auto scene_json = nlohmann::json::parse(R"({
        "objects": [{
            "id": 7,
            "name": "Layer",
            "visible": true,
            "image": "materials/layer.json",
            "effects": [{
                "visible": true,
                "file": "effects/bars.json",
                "passes": [
                    { "combos": { "SHAPE": 7, "NOT_AN_INTEGER": "x" } },
                    { "combos": { "BOTH": 2 } }
                ]
            }]
        }]
    })");

    fs::VFS vfs;
    std::vector<NonShaderBlocker> blockers;
    const auto expected = CollectSourceShaderExpectations(scene_dir,
                                                          vfs,
                                                          scene_json,
                                                          "1",
                                                          scene_dir / "scene.json",
                                                          false,
                                                          blockers);

    EXPECT_TRUE(blockers.empty()) << NonShaderBlockerReport(blockers);
    ASSERT_EQ(expected.size(), 2u);
    const auto first  = BuildDirectShaderCompileJob(expected.at(0), blockers, "1",
                                                    scene_dir / "scene.json", false);
    const auto second = BuildDirectShaderCompileJob(expected.at(1), blockers, "1",
                                                    scene_dir / "scene.json", false);
    ASSERT_TRUE(first.has_value());
    ASSERT_TRUE(second.has_value());
    EXPECT_EQ(first->combos.at("SHAPE"), "7") << "the scene's choice replaces the material's";
    EXPECT_EQ(first->combos.at("KEPT"), "1") << "a combo the scene does not set stays";
    EXPECT_EQ(first->combos.count("NOT_AN_INTEGER"), 0u);
    EXPECT_EQ(second->combos.at("FROM_FILE"), "1") << "the effect file's pass sets combos too";
    EXPECT_EQ(second->combos.at("BOTH"), "2") << "the scene's entry wins over the effect file's";

    std::filesystem::remove_all(scene_dir);
}

// Compiling every shader of a whole corpus takes minutes (about six for 60
// scenes), so the sweep runs only on request:
// --gtest_also_run_disabled_tests --gtest_filter='*ParsesCorpus*'.
TEST(UnpackShaderCompileSmoke, DISABLED_ParsesCorpusAndProducesShaderSpirv) {
    const auto      corpus_root = CorpusRoot();
    std::error_code ec;
    if (! std::filesystem::exists(std::filesystem::symlink_status(corpus_root, ec))) {
        GTEST_SKIP() << "no unpacked workshop corpus at " << corpus_root
                     << "; set WALLPAPER_MACHINE_UNPACK_ROOT to a folder of <id>/scene.json";
    }
    ASSERT_TRUE(ValidateCorpusRoot(corpus_root));
    const auto scene_dirs  = FindWorkshopSceneDirs(corpus_root);
    if (scene_dirs.empty()) {
        GTEST_SKIP() << "unpack corpus is missing or contains no scene.json files: " << corpus_root;
    }
    ASSERT_LE(scene_dirs.size(), kMaxWorkshopSceneDirs)
        << "refusing to run shader smoke over an unexpectedly large corpus; root may be too broad: "
        << corpus_root;

    std::vector<NonShaderBlocker> non_shader_blockers;
    std::vector<ShaderFailure>    shader_failures;

    for (const auto& scene_dir : scene_dirs) {
        const auto workshop_id     = scene_dir.filename().string();
        const auto scene_json_path = scene_dir / "scene.json";
        SCOPED_TRACE("workshop " + workshop_id);

        fs::VFS    vfs;
        const bool mounted_common_assets =
            ! CommonAssets().empty() && std::filesystem::exists(CommonAssets()) &&
            MountPhysical(vfs, CommonAssets(), "common-assets");
        ASSERT_TRUE(MountPhysical(vfs, scene_dir, "workshop-" + workshop_id))
            << "failed to mount unpack workshop dir " << scene_dir;

        const auto source_scene_json = ReadJsonFile(scene_json_path);
        if (! source_scene_json.has_value()) {
            non_shader_blockers.push_back({ workshop_id,
                                            scene_json_path,
                                            mounted_common_assets,
                                            "missing/unreadable scene JSON" });
            continue;
        }
        const auto expected_shaders = CollectSourceShaderExpectations(scene_dir,
                                                                      vfs,
                                                                      *source_scene_json,
                                                                      workshop_id,
                                                                      scene_json_path,
                                                                      mounted_common_assets,
                                                                      non_shader_blockers);
        for (const auto& expected_shader : expected_shaders) {
            auto job = BuildDirectShaderCompileJob(expected_shader,
                                                   non_shader_blockers,
                                                   workshop_id,
                                                   scene_json_path,
                                                   mounted_common_assets);
            if (! job.has_value()) continue;
            CompileDirectShaderJob(vfs,
                                   *job,
                                   workshop_id,
                                   scene_json_path,
                                   mounted_common_assets,
                                   shader_failures);
        }
    }

    if (! non_shader_blockers.empty()) {
        const auto report = NonShaderBlockerReport(non_shader_blockers);
        RecordProperty("non_shader_blockers", report);
        std::cerr << report;
    }

    EXPECT_TRUE(shader_failures.empty()) << ShaderFailureReport(shader_failures);
}

} // namespace wallpaper
