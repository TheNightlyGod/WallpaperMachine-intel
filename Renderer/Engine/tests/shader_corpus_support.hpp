#pragma once

// Test-local model of how a Wallpaper Engine scene turns into shader compile jobs.
//
// Nothing here is production API. The model walks a scene.json, decides which
// materials the scene instantiates (with the combos the scene chooses on effect
// passes), and turns each material into a job the shader compiler can be fed. The
// always-run tests pin the rules of this model; the opt-in corpus sweep uses it to
// compile every shader of a folder of unpacked scenes.

#include "Fs/VFS.h"
#include "Scene/Parse/WPMdlParser.hpp"
#include "Scene/Parse/WPShaderParser.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper::corpus
{

namespace stdfs = std::filesystem;
using nlohmann::json;
using ComboText = std::map<std::string, std::string>;

// ---- roots and paths -------------------------------------------------------------------------

// Folders that are far too broad to enumerate as a corpus. Returns the reason a root
// may not be used, or nothing when it is a plain, real directory.
inline std::optional<std::string> RefuseCorpusRoot(const stdfs::path& root) {
    static const std::set<std::string> broad = { "/", "/Users", "/Library", "/System", "/private", "/Volumes" };

    stdfs::path tidy = root.lexically_normal();
    if (tidy.has_relative_path() && ! tidy.has_filename()) tidy = tidy.parent_path();
    if (broad.count(tidy.string()) != 0) return "the folder " + root.string() + " is too broad to be a corpus";

    std::error_code failure;
    const auto      link_status = stdfs::symlink_status(root, failure);
    if (failure || ! stdfs::exists(link_status)) return "the folder " + root.string() + " does not exist";
    if (stdfs::is_symlink(link_status)) return "the folder " + root.string() + " is a symbolic link";
    if (! stdfs::is_directory(link_status)) return root.string() + " is not a directory";
    return std::nullopt;
}

// `relative` joined onto `root`, normalised, provided it stays inside `root`.
inline std::optional<stdfs::path> ResolveInRoot(const stdfs::path& root, const std::string& relative) {
    if (relative.empty()) return std::nullopt;
    const stdfs::path given(relative);
    if (given.is_absolute()) return std::nullopt;

    const stdfs::path base   = stdfs::absolute(root).lexically_normal();
    const stdfs::path joined = (base / given).lexically_normal();
    const stdfs::path inside = joined.lexically_relative(base);
    if (inside.empty()) return std::nullopt;
    for (const auto& part : inside) {
        if (part == "..") return std::nullopt;
    }
    return joined;
}

struct Blocker {
    std::string message;
};

struct Roots {
    stdfs::path                scene;
    std::optional<stdfs::path> common;
};

inline std::optional<std::string> ReadWholeFile(const stdfs::path& path) {
    std::error_code failure;
    if (! stdfs::is_regular_file(path, failure) || failure) return std::nullopt;
    std::ifstream in(path, std::ios::binary);
    if (! in) return std::nullopt;
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

struct LoadedAsset {
    json        document;
    stdfs::path found_at;
};

// An asset document, looked up in the scene's folder first and then in the common
// assets. Failing in both leaves a blocker that names the kind, the path and who asked.
inline std::optional<LoadedAsset> LoadAsset(const Roots& roots, const std::string& kind, const std::string& relative,
                                            const std::string& asked_by, std::vector<Blocker>& blockers) {
    std::vector<stdfs::path> candidates;
    if (const auto own = ResolveInRoot(roots.scene, relative)) candidates.push_back(*own);
    if (roots.common) {
        if (const auto shared = ResolveInRoot(*roots.common, relative)) candidates.push_back(*shared);
    }
    for (const auto& candidate : candidates) {
        const auto text = ReadWholeFile(candidate);
        if (! text) continue;
        auto document = json::parse(*text, nullptr, false);
        if (document.is_discarded()) continue;
        return LoadedAsset { std::move(document), candidate };
    }
    blockers.push_back({ kind + " '" + relative + "' could not be read (" + asked_by + ")" });
    return std::nullopt;
}

// ---- expectations ----------------------------------------------------------------------------

struct Expectation {
    stdfs::path source;
    std::string context;
    std::string identity;
    std::string shader_name;
    std::string shader_path;
    ComboText   scene_combos;
};

struct Collection {
    std::vector<Expectation> expectations;
    std::vector<Blocker>     blockers;
};

namespace detail
{

inline const char* const kComposeLayer = "models/util/composelayer.json";
inline const char* const kRopeShader   = "genericropeparticle";

inline std::string StringOf(const json& object, const char* key, const std::string& fallback = {}) {
    const auto found = object.find(key);
    return found != object.end() && found->is_string() ? found->get<std::string>() : fallback;
}

inline bool BoolOf(const json& object, const char* key, bool fallback) {
    const auto found = object.find(key);
    return found != object.end() && found->is_boolean() ? found->get<bool>() : fallback;
}

inline ComboText IntegerCombos(const json& source) {
    ComboText combos;
    if (! source.is_object()) return combos;
    for (const auto& [name, value] : source.items()) {
        if (value.is_number_integer()) combos[name] = std::to_string(value.get<long long>());
    }
    return combos;
}

// Visible unless switched off; a switched-off object that has a script or a user
// property driving its visibility still counts, because it can turn on at run time.
inline bool ObjectCounts(const json& object) {
    const auto found = object.find("visible");
    if (found == object.end()) return true;
    if (found->is_boolean()) return found->get<bool>();
    if (found->is_object()) {
        if (BoolOf(*found, "value", true)) return true;
        return found->contains("script") || found->contains("user");
    }
    return true;
}

inline std::string IdText(const json& object) {
    const auto found = object.find("id");
    if (found == object.end()) return "?";
    return found->is_number_integer() ? std::to_string(found->get<long long>()) : found->dump();
}

class Walker {
public:
    Walker(const json& scene, const Roots& roots, fs::VFS& vfs, std::string workshop_id)
        : m_scene(scene), m_roots(roots), m_vfs(vfs), m_workshop_id(std::move(workshop_id)) {}

    Collection Run() {
        const auto objects = m_scene.find("objects");
        if (objects != m_scene.end() && objects->is_array()) {
            for (const auto& object : *objects) {
                if (object.is_object()) m_names[StringOf(object, "name")]++;
            }
            for (const auto& object : *objects) {
                if (object.is_object() && ObjectCounts(object)) Object(object, *objects);
            }
        }
        const auto general = m_scene.find("general");
        if (general != m_scene.end() && general->is_object() && BoolOf(*general, "bloom", false)) Bloom();
        return std::move(m_out);
    }

private:
    std::string RuntimeName(const json& object) const {
        const auto name = StringOf(object, "name");
        const auto seen = m_names.find(name);
        if (! name.empty() && seen != m_names.end() && seen->second == 1) return name;
        return "__we_layer_" + IdText(object);
    }

    // Reads a material file and records one expectation for it.
    void AddMaterial(const std::string& material_path, const std::string& context, const std::string& identity,
                     const ComboText& combos, const std::string& forced_shader = {}) {
        auto material = LoadAsset(m_roots, "material", material_path, context, m_out.blockers);
        if (! material) return;
        Expectation expectation;
        expectation.source       = material->found_at;
        expectation.context      = context;
        expectation.identity     = identity;
        expectation.scene_combos = combos;
        expectation.shader_name  = forced_shader;
        if (forced_shader.empty()) {
            const auto passes = material->document.find("passes");
            if (passes != material->document.end() && passes->is_array() && ! passes->empty() &&
                (*passes)[0].is_object()) {
                expectation.shader_name = StringOf((*passes)[0], "shader");
            }
        }
        if (! expectation.shader_name.empty()) expectation.shader_path = "shaders/" + expectation.shader_name;
        m_out.expectations.push_back(std::move(expectation));
    }

    void Bloom() {
        for (const char* stem :
             { "downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom", "combine_ldr" }) {
            AddMaterial(std::string("materials/util/") + stem + ".json", std::string("bloom ") + stem,
                        std::string("bloom/") + stem + "/material-slot-0", {});
        }
    }

    void Object(const json& object, const json& all_objects) {
        const auto image    = object.find("image");
        const auto particle = object.find("particle");
        if (image != object.end() && image->is_string()) Image(object, all_objects, image->get<std::string>());
        else if (particle != object.end() && particle->is_string())
            Particle(object, particle->get<std::string>());
    }

    void Image(const json& object, const json& all_objects, const std::string& image_path) {
        const std::string name    = StringOf(object, "name");
        const std::string runtime = RuntimeName(object);
        const std::string layer =
            "image object '" + (name.empty() ? std::string("<unnamed>") : name) + "' (id " + IdText(object) +
            ", workshop " + m_workshop_id + ") " + image_path;
        auto image_doc = LoadAsset(m_roots, "image", image_path, layer, m_out.blockers);
        if (! image_doc) return;
        const json& image = image_doc->document;

        // Effects the layer really draws.
        std::vector<const json*> effects;
        const auto               listed = object.find("effects");
        if (listed != object.end() && listed->is_array()) {
            for (const auto& reference : *listed) {
                if (reference.is_object() && BoolOf(reference, "visible", true)) effects.push_back(&reference);
            }
        }
        const auto blend_found = object.find("colorBlendMode");
        const long long blend  = blend_found != object.end() && blend_found->is_number_integer()
                                     ? blend_found->get<long long>()
                                     : 0;
        const bool blends = blend != 0 && blend != 31;
        const std::size_t effect_count = effects.size() + (blends ? 1 : 0);

        const bool is_compose = image_path == kComposeLayer;
        bool       has_child  = false;
        if (object.contains("id")) {
            for (const auto& other : all_objects) {
                if (&other != &object && other.is_object() && other.contains("parent") &&
                    other.at("parent") == object.at("id")) {
                    has_child = true;
                }
            }
        }
        const bool copy_background = BoolOf(object, "copybackground", true);
        const bool as_compose      = is_compose && has_child && (! copy_background || effect_count > 0);

        bool passthrough = BoolOf(image, "passthrough", false);
        const auto config = object.find("config");
        if (config != object.end() && config->is_object()) passthrough = BoolOf(*config, "passthrough", passthrough);

        // Puppet layers swap the base material for the materials of the model's meshes.
        bool puppet_takes_over = false;
        bool puppet_blocked    = false;
        const auto puppet_path = StringOf(image, "puppet");
        if (! puppet_path.empty() && effect_count == 0) {
            puppet_takes_over = Puppet(puppet_path, runtime, layer, puppet_blocked);
        }

        const bool suppressed = (is_compose && effect_count == 0 && copy_background) ||
                                (passthrough && effect_count == 0 && ! is_compose) || puppet_takes_over ||
                                puppet_blocked;
        const std::string base = StringOf(image, "material");
        if (! suppressed && ! base.empty()) {
            AddMaterial(base, layer, "node:" + runtime + "/material-slot-0", {});
        }

        int ordinal = 0;
        for (const json* reference : effects) {
            Effect(*reference, runtime, layer, ordinal++);
        }
        if (blends || (as_compose && effects.empty())) {
            AddMaterial("materials/util/effectpassthrough.json", layer + "/colour-blend",
                        "node:" + runtime + "/effect-" + std::to_string(ordinal) + "/pass-0/material-slot-0", {});
        }
    }

    void Effect(const json& reference, const std::string& runtime, const std::string& layer, int ordinal) {
        const std::string file = StringOf(reference, "file");
        auto              effect = LoadAsset(m_roots, "effect", file, layer, m_out.blockers);
        if (! effect) return;
        const std::string label = StringOf(effect->document, "name", file);

        const json* scene_passes = nullptr;
        if (const auto found = reference.find("passes"); found != reference.end() && found->is_array()) {
            scene_passes = &*found;
        }
        const auto passes = effect->document.find("passes");
        if (passes == effect->document.end() || ! passes->is_array()) return;

        int material_index = 0;
        for (std::size_t raw = 0; raw < passes->size(); ++raw) {
            const json& pass = (*passes)[raw];
            const auto  material = pass.is_object() ? StringOf(pass, "material") : std::string();
            if (material.empty()) continue;

            ComboText combos = IntegerCombos(pass.value("combos", json::object()));
            if (scene_passes != nullptr && static_cast<std::size_t>(material_index) < scene_passes->size()) {
                const json& chosen = (*scene_passes)[static_cast<std::size_t>(material_index)];
                if (chosen.is_object()) {
                    for (auto& [name, value] : IntegerCombos(chosen.value("combos", json::object()))) {
                        combos[name] = value;
                    }
                }
            }
            AddMaterial(material, layer + "/effect:" + label + "/source-pass-" + std::to_string(raw),
                        "node:" + runtime + "/effect-" + std::to_string(ordinal) + "/pass-" +
                            std::to_string(material_index) + "/material-slot-0",
                        combos);
            ++material_index;
        }
    }

    // True when the model's own materials replace the layer's base material.
    bool Puppet(const std::string& puppet_path, const std::string& runtime, const std::string& layer, bool& blocked) {
        if (! ResolveInRoot(m_roots.scene, puppet_path)) {
            m_out.blockers.push_back({ "puppet model '" + puppet_path + "' leaves the asset folder (" + layer + ")" });
            blocked = true;
            return false;
        }
        WPMdl model;
        if (! WPMdlParser::Parse(puppet_path, m_vfs, model)) {
            m_out.blockers.push_back({ "puppet model '" + puppet_path + "' could not be parsed (" + layer + ")" });
            blocked = true;
            return false;
        }
        const bool animated = model.puppet && ! model.puppet->bones.empty();
        const bool has_mesh = std::any_of(model.meshes.begin(), model.meshes.end(),
                                          [](const WPMdl::Mesh& mesh) { return ! mesh.positions.empty(); });
        if (! animated && ! has_mesh) return false;

        // Collect the slots on the side so a bad slot leaves nothing of this layer behind.
        Collection produced;
        std::swap(m_out, produced);
        for (std::size_t index = 0; index < model.meshes.size(); ++index) {
            const auto& material = model.meshes[index].mat_json_file;
            if (material.empty()) {
                m_out.blockers.push_back({ "puppet mesh " + std::to_string(index) + " has no material (" + layer + ")" });
                continue;
            }
            AddMaterial(material, layer + "/puppet-mesh-" + std::to_string(index),
                        "node:" + runtime + "/material-slot-" + std::to_string(index), {});
        }
        std::swap(m_out, produced);

        for (auto& blocker : produced.blockers) m_out.blockers.push_back(std::move(blocker));
        if (! produced.blockers.empty()) {
            blocked = true;
            return false;
        }
        for (auto& slot : produced.expectations) m_out.expectations.push_back(std::move(slot));
        return true;
    }

    void Particle(const json& object, const std::string& particle_path) {
        const std::string runtime = RuntimeName(object);
        const std::string layer   = "particle object '" + StringOf(object, "name") + "' (id " + IdText(object) +
                                  ", workshop " + m_workshop_id + ") " + particle_path;
        std::set<std::string> visited;
        ParticleFile(particle_path, "node:" + runtime, layer, visited);
    }

    void ParticleFile(const std::string& path, const std::string& identity_base, const std::string& layer,
                      std::set<std::string>& visited) {
        if (! visited.insert(path).second) return;
        auto particle = LoadAsset(m_roots, "particle", path, layer, m_out.blockers);
        if (! particle) return;

        std::string forced;
        const auto  renderers = particle->document.find("renderer");
        if (renderers != particle->document.end() && renderers->is_array() && ! renderers->empty() &&
            (*renderers)[0].is_object() && StringOf((*renderers)[0], "name").rfind("rope", 0) == 0) {
            forced = kRopeShader;
        }
        const std::string material = StringOf(particle->document, "material");
        if (! material.empty()) AddMaterial(material, layer, identity_base + "/material-slot-0", {}, forced);

        const auto children = particle->document.find("children");
        if (children == particle->document.end() || ! children->is_array()) return;
        int index = 0;
        for (const auto& child : *children) {
            const auto child_path = child.is_object() ? StringOf(child, "name") : std::string();
            if (! child_path.empty()) {
                ParticleFile(child_path, identity_base + "/child-" + std::to_string(index), layer + "/" + child_path,
                             visited);
            }
            ++index;
        }
    }

    const json&                m_scene;
    const Roots&               m_roots;
    fs::VFS&                   m_vfs;
    std::string                m_workshop_id;
    std::map<std::string, int> m_names;
    Collection                 m_out;
};

} // namespace detail

inline Collection CollectExpectations(const json& scene, const Roots& roots, fs::VFS& vfs,
                                      const std::string& workshop_id) {
    return detail::Walker(scene, roots, vfs, workshop_id).Run();
}

// ---- compile jobs ----------------------------------------------------------------------------

struct CompileJob {
    stdfs::path                  source;
    std::string                  context;
    std::string                  shader_name;
    std::string                  shader_path;
    ComboText                    combos;
    std::vector<std::string>     base_textures;
    std::vector<WPShaderTexInfo> texture_infos;
};

inline WPShaderTexInfo ConservativeTexture(const std::string& path) {
    WPShaderTexInfo info;
    info.present = ! path.empty();
    info.enabled = ! path.empty();
    return info;
}

// A job from the material document alone: no texture header is opened, so a texture
// counts as present exactly when the material names one.
inline std::optional<CompileJob> BuildJob(const Expectation& expectation, const json& material) {
    const auto passes = material.find("passes");
    if (passes == material.end() || ! passes->is_array() || passes->empty() || ! (*passes)[0].is_object()) {
        return std::nullopt;
    }
    const json& first = (*passes)[0];

    CompileJob job;
    job.source      = expectation.source;
    job.context     = expectation.context;
    job.shader_name = expectation.shader_name.empty() ? detail::StringOf(first, "shader") : expectation.shader_name;
    if (job.shader_name.empty()) return std::nullopt;
    job.shader_path = "shaders/" + job.shader_name;

    if (detail::StringOf(first, "blending") == "alphatocoverage") job.combos["ALPHATOCOVERAGE"] = "1";
    for (auto& [name, value] : detail::IntegerCombos(first.value("combos", json::object()))) job.combos[name] = value;
    for (const auto& [name, value] : expectation.scene_combos) job.combos[name] = value;

    const auto textures = first.find("textures");
    if (textures != first.end() && textures->is_array()) {
        for (const auto& entry : *textures) job.base_textures.push_back(entry.is_string() ? entry.get<std::string>() : "");
    }
    for (const auto& path : job.base_textures) job.texture_infos.push_back(ConservativeTexture(path));
    return job;
}

inline std::optional<CompileJob> BuildJob(const Expectation& expectation, std::vector<Blocker>& blockers) {
    const auto text = ReadWholeFile(expectation.source);
    auto       document = text ? json::parse(*text, nullptr, false) : json(json::value_t::discarded);
    if (document.is_discarded()) {
        blockers.push_back({ "material '" + expectation.source.string() + "' could not be read (" + expectation.context + ")" });
        return std::nullopt;
    }
    return BuildJob(expectation, document);
}

// ---- sweep configuration and gates -----------------------------------------------------------

constexpr std::size_t kSceneFolderLimit = 4096;

struct SweepConfig {
    stdfs::path                unpack_root;
    std::optional<stdfs::path> assets_root;
};

// `lookup` returns the variable's value or null. An empty value counts as unset.
inline SweepConfig ResolveSweepConfig(const std::function<const char*(const char*)>& lookup,
                                      const std::string&                             default_unpack_root) {
    const auto value = [&](const char* name) -> std::string {
        const char* raw = lookup(name);
        return raw != nullptr ? std::string(raw) : std::string();
    };
    SweepConfig config;
    const auto  unpack = value("WALLPAPER_MACHINE_UNPACK_ROOT");
    config.unpack_root = unpack.empty() ? stdfs::path(default_unpack_root) : stdfs::path(unpack);

    const auto assets = value("WALLPAPER_MACHINE_ASSETS_ROOT");
    if (! assets.empty()) {
        config.assets_root = stdfs::path(assets);
    } else if (const auto home = value("HOME"); ! home.empty()) {
        config.assets_root = stdfs::path(home) / "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets";
    }
    return config;
}

// Immediate child folders of `root` that hold a scene.json, sorted, symlinks and
// unreadable entries skipped, stopping once `limit` has been exceeded.
inline std::vector<stdfs::path> EnumerateSceneFolders(const stdfs::path& root, std::size_t limit) {
    std::vector<stdfs::path> found;
    std::error_code          failure;
    for (stdfs::directory_iterator it(root, stdfs::directory_options::skip_permission_denied, failure), end;
         ! failure && it != end; it.increment(failure)) {
        std::error_code entry_failure;
        const auto      status = it->symlink_status(entry_failure);
        if (entry_failure || stdfs::is_symlink(status) || ! stdfs::is_directory(status)) continue;
        const auto scene = it->path() / "scene.json";
        if (! stdfs::is_regular_file(scene, entry_failure) || entry_failure) continue;
        found.push_back(it->path());
    }
    std::sort(found.begin(), found.end());
    if (found.size() > limit + 1) found.resize(limit + 1);
    return found;
}

enum class SweepGate { Run, Skip, Fail };

struct GateDecision {
    SweepGate                gate { SweepGate::Run };
    std::string              message;
    std::vector<stdfs::path> scenes;
};

inline GateDecision DecideSweepGate(const stdfs::path& root) {
    GateDecision decision;
    std::error_code failure;
    const auto      status = stdfs::symlink_status(root, failure);
    if (failure || ! stdfs::exists(status)) {
        decision.gate = SweepGate::Skip;
        decision.message = "no corpus at " + root.string() +
                           "; set WALLPAPER_MACHINE_UNPACK_ROOT to a folder of <id>/scene.json";
        return decision;
    }
    if (const auto refusal = RefuseCorpusRoot(root)) {
        decision.gate    = SweepGate::Fail;
        decision.message = *refusal;
        return decision;
    }
    decision.scenes = EnumerateSceneFolders(root, kSceneFolderLimit);
    if (decision.scenes.empty()) {
        decision.gate    = SweepGate::Skip;
        decision.message = "the corpus folder " + root.string() + " holds no <id>/scene.json";
    } else if (decision.scenes.size() > kSceneFolderLimit) {
        decision.gate    = SweepGate::Fail;
        decision.message = "more than " + std::to_string(kSceneFolderLimit) + " scene folders under " + root.string();
    }
    return decision;
}

} // namespace wallpaper::corpus
