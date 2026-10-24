// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#include "WPShaderParser.hpp"

#include "Fs/IBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"
#include <unordered_map>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <unistd.h>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace wallpaper;

namespace
{

// Re-encodes a compiled Metal stage into the same payload shape the Rust
// bridge returns, so cached programs restore through one parser.
nlohmann::json MetalStageMetaJson(const wallpaper::shader::RustShaderMetalStage& stage) {
    auto bindings = nlohmann::json::array();
    for (const auto& binding : stage.bindings) {
        const char* slot_kind = "buffer";
        switch (binding.slot_kind) {
        case wallpaper::shader::RustShaderMetalSlotKind::Buffer: slot_kind = "buffer"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Texture: slot_kind = "texture"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Sampler: slot_kind = "sampler"; break;
        }
        bindings.push_back({
            {"name", binding.name},
            {"set", binding.set},
            {"binding", binding.binding},
            {"slot_kind", slot_kind},
            {"slot", binding.slot},
        });
    }

    return {
        {"entry_point", stage.entry_point},
        {"language_version", stage.language_version},
        {"bindings", std::move(bindings)},
        {"conventions",
         {
             {"clip_space_y_flipped", stage.conventions.clip_space_y_flipped},
             {"clip_space_depth_remapped", stage.conventions.clip_space_depth_remapped},
             {"texture_origin_flipped", stage.conventions.texture_origin_flipped},
         }},
    };
}

} // namespace

namespace
{

// The state of one thread's shader work: the programs it has compiled or restored
// and the counters of what that cost. Threads never share it, so a background
// compile does not disturb the numbers of a parse.
constexpr std::size_t kProgramTableLimit = 128;
constexpr std::uintmax_t kMaxProgramFile  = std::uintmax_t { 16 } << 20;

// Everything one compile gave back, in the shape a later load needs to rebuild it
// without compiling.
struct StoredStage {
    ShaderType  kind { ShaderType::VERTEX };
    std::string source;
    std::string metal_json;
};

struct StoredProgram {
    std::string                                                     request;
    std::string                                                     identity;
    std::vector<std::pair<std::string, std::optional<std::string>>> includes;
    std::vector<StoredStage>                                        stages;
    std::string                                                     metadata_json;
    std::string                                                     reflection_json;
    std::string                                                     program_key;
    nlohmann::json                                                  vertex_info;
    nlohmann::json                                                  fragment_info;
};

struct ThreadShaderState {
    std::unordered_map<std::string, StoredProgram> programs;
    std::deque<std::string>                        order; // oldest first
    ShaderStartupMetrics                           metrics;

    void Remember(const std::string& key, StoredProgram program) {
        if (programs.find(key) == programs.end()) {
            order.push_back(key);
            while (order.size() > kProgramTableLimit) {
                programs.erase(order.front());
                order.pop_front();
            }
        }
        programs[key] = std::move(program);
    }
    void Clear() {
        programs.clear();
        order.clear();
    }
};

ThreadShaderState& State() {
    thread_local ThreadShaderState state;
    return state;
}

double MillisSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

} // namespace

void WPShaderParser::BeginShaderSession() {
    auto& state = State();
    state.Clear();
    state.metrics = {};
}
void WPShaderParser::EndShaderSession() {
    auto& state = State();
    LOG_INFO("shader programs: %llu restored, %llu compiled in %.1f ms, %.1f ms reading the cache",
             static_cast<unsigned long long>(state.metrics.cache_hits),
             static_cast<unsigned long long>(state.metrics.cache_misses),
             state.metrics.compile_ms,
             state.metrics.cache_read_ms);
    state.Clear();
}

void WPShaderParser::ResetStartupMetrics() { State().metrics = {}; }
ShaderStartupMetrics WPShaderParser::GetStartupMetrics() { return State().metrics; }
void WPShaderParser::ClearProgramCache() { State().Clear(); }

namespace
{

// Where one compile reads its includes from and what it is allowed to cache.
//
// A parse has the project mounted and caches to it. A variant compiled later
// has neither: it replays the includes the ordinary translation of the same
// program recorded, and writes nothing. Both go through the identical compile
// below, so the second is not a different translation with different rules.
// The one compile path of the Rust shader layer, which has a single target
// (Metal Shading Language): include resolution, combo defaults, program caching,
// metadata and reflection, and the compiled stages.
struct RustCompileEnv {
    fs::VFS*                  vfs { nullptr };
    const WPShaderIncludeMap* includes { nullptr };
    WPShaderIncludeMap*       used_includes { nullptr };
};

using IncludeList = std::vector<std::pair<std::string, std::optional<std::string>>>;

const char* FormatText(TextureFormat format) {
    switch (format) {
    case TextureFormat::RGBA8: return "rgba8";
    case TextureFormat::RG8: return "rg8";
    case TextureFormat::R8: return "r8";
    default: return "unknown";
    }
}

// An include as the shader layer asks for it: `shaders/<path>` of the project, or
// the path itself when it already names a project file. A snapshot answers from
// its record instead and never reaches a file system.
std::optional<std::string> ReadInclude(const RustCompileEnv& env, std::string_view path) {
    if (env.includes != nullptr) {
        const auto found = env.includes->find(std::string(path));
        return found == env.includes->end() ? std::nullopt : found->second;
    }
    if (env.vfs == nullptr) return std::nullopt;
    std::string candidates[2] = { "/assets/shaders/" + std::string(path), std::string(path) };
    for (int i = 0; i < 2; ++i) {
        // Only the project's own space is searched: a bare path has to name a file
        // below `/assets`, never the cache or anything else mounted.
        if (i == 1 && candidates[i].rfind("/assets/", 0) != 0) break;
        if (! env.vfs->Contains(candidates[i])) continue;
        const auto stream = env.vfs->Open(candidates[i]);
        if (stream) return stream->ReadAllStr();
    }
    return std::nullopt;
}

std::string ProgramFolder(std::string_view scene_id) { return "/cache/" + std::string(scene_id) + "/programs01"; }

nlohmann::json InfoToJson(const WPPreprocessorInfo& info) {
    nlohmann::json slots = nlohmann::json::array();
    for (const auto slot : info.active_tex_slots) slots.push_back(slot);
    return {
        { "input", info.input },
        { "output", info.output },
        { "active", std::move(slots) },
    };
}

void InfoFromJson(const nlohmann::json& json, WPPreprocessorInfo& info) {
    info = {};
    for (const auto& [name, line] : json.at("input").items()) info.input[name] = line.get<std::string>();
    for (const auto& [name, line] : json.at("output").items()) info.output[name] = line.get<std::string>();
    for (const auto& slot : json.at("active")) info.active_tex_slots.insert(slot.get<uint>());
}

std::string Dump(const nlohmann::json& json) {
    return json.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

std::string Serialize(const StoredProgram& program) {
    nlohmann::json includes = nlohmann::json::array();
    for (const auto& [path, text] : program.includes) {
        nlohmann::json entry { { "path", path } };
        if (text.has_value()) entry["text"] = *text;
        includes.push_back(std::move(entry));
    }
    nlohmann::json stages = nlohmann::json::array();
    for (const auto& stage : program.stages) {
        stages.push_back({ { "kind", static_cast<int>(stage.kind) },
                           { "source", stage.source },
                           { "metal", stage.metal_json } });
    }
    return Dump({
        { "request", program.request },
        { "identity", program.identity },
        { "includes", std::move(includes) },
        { "stages", std::move(stages) },
        { "metadata", program.metadata_json },
        { "reflection", program.reflection_json },
        { "program_key", program.program_key },
        { "vertex_info", program.vertex_info },
        { "fragment_info", program.fragment_info },
    });
}

std::optional<StoredProgram> Deserialize(const std::string& text) {
    try {
        const auto json = nlohmann::json::parse(text, nullptr, false);
        if (json.is_discarded() || ! json.is_object()) return std::nullopt;
        StoredProgram program;
        program.request         = json.at("request").get<std::string>();
        program.identity        = json.at("identity").get<std::string>();
        program.metadata_json   = json.at("metadata").get<std::string>();
        program.reflection_json = json.at("reflection").get<std::string>();
        program.program_key     = json.at("program_key").get<std::string>();
        program.vertex_info     = json.at("vertex_info");
        program.fragment_info   = json.at("fragment_info");
        for (const auto& entry : json.at("includes")) {
            std::optional<std::string> body;
            if (entry.contains("text")) body = entry.at("text").get<std::string>();
            program.includes.emplace_back(entry.at("path").get<std::string>(), std::move(body));
        }
        for (const auto& entry : json.at("stages")) {
            program.stages.push_back({ static_cast<ShaderType>(entry.at("kind").get<int>()),
                                       entry.at("source").get<std::string>(),
                                       entry.at("metal").get<std::string>() });
        }
        return program;
    } catch (...) {
        return std::nullopt;
    }
}

// Rebuilds a compile's output from a stored program, provided it is the program
// this request asks for: same request text, same compiler, every include still
// reading as it did, and every part parsing. Anything else is a miss.
bool Restore(const StoredProgram& program, const std::string& request_text,
             const std::string& identity, std::size_t stage_count, const RustCompileEnv& env,
             wallpaper::shader::RustShaderOutput& output) {
    if (program.request != request_text || program.identity != identity) return false;
    if (program.stages.size() != stage_count || program.reflection_json.empty()) return false;
    for (const auto& [path, text] : program.includes) {
        if (ReadInclude(env, path) != text) return false;
    }
    try {
        wallpaper::shader::RustShaderOutput next;
        for (const auto& stage : program.stages) {
            if (stage.source.empty()) return false;
            wallpaper::shader::RustShaderMetalStage restored;
            wallpaper::shader::ApplyRustShaderMetalStageJson(stage.metal_json, stage.source, stage.kind, restored);
            next.metal_stages.push_back(std::move(restored));
        }
        next.metadata_json   = program.metadata_json;
        next.reflection_json = program.reflection_json;
        next.cache_key       = program.program_key;
        wallpaper::shader::ApplyRustShaderMetadataJson(next.metadata_json, next);
        wallpaper::shader::ApplyRustShaderReflectionJson(next.reflection_json, next);
        InfoFromJson(program.vertex_info, next.vertex_preprocessor_info);
        InfoFromJson(program.fragment_info, next.fragment_preprocessor_info);
        output = std::move(next);
        return true;
    } catch (...) {
        return false;
    }
}

std::optional<StoredProgram> ReadProgramFile(fs::VFS& vfs, const std::string& path) {
    if (! vfs.Contains(path)) return std::nullopt;
    const auto stream = vfs.Open(path);
    if (! stream) return std::nullopt;
    const auto size = stream->Size();
    if (size <= 0 || static_cast<std::uintmax_t>(size) > kMaxProgramFile) return std::nullopt;
    return Deserialize(stream->ReadAllStr());
}

// Writes a program so that a reader sees the whole old file, the whole new one or
// none: staged under a name of its own, then renamed into place. Failing to write
// loses nothing but the cache entry.
void WriteProgramFile(fs::VFS& vfs, const std::string& path, const std::string& body) {
    static std::atomic<std::uint64_t> counter { 0 };
    const auto write = [&](const std::string& target) {
        auto stream = vfs.OpenW(target);
        return stream && (body.empty() || stream->Write(body.data(), body.size()) != 0);
    };
    const std::string staged = path + ".tmp-" + std::to_string(::getpid()) + "-" +
                               std::to_string(counter.fetch_add(1));
    if (write(staged) && vfs.Rename(staged, path)) return;
    if (! write(path)) LOG_INFO("shader cache entry %s could not be written", path.c_str());
}

// Takes what a compile (or a restored program) learned into the pass: combos, aliases
// and default uniforms the pass has no value for, the default textures, and each
// unit's own stage facts.
void MergeOutput(const wallpaper::shader::RustShaderOutput& output, std::span<WPShaderUnit> units,
                 WPShaderInfo& info) {
    for (const auto& [name, value] : output.shader_info.combos) info.combos.emplace(name, value);
    for (const auto& [material, uniform] : output.shader_info.alias) info.alias.emplace(material, uniform);
    for (const auto& [name, value] : output.shader_info.svs) {
        if (value.size() > 0) info.svs.emplace(name, value);
    }
    for (const auto& texture : output.shader_info.defTexs) info.defTexs.push_back(texture);
    for (auto& unit : units) {
        if (unit.stage == ShaderType::VERTEX) unit.preprocess_info = output.vertex_preprocessor_info;
        else if (unit.stage == ShaderType::FRAGMENT) unit.preprocess_info = output.fragment_preprocessor_info;
    }
}

bool CompileProgramRust(std::string_view scene_id, std::string_view shader_name,
                        std::span<WPShaderUnit> units,
                        wallpaper::shader::RustShaderOutput& output, const RustCompileEnv& env,
                        WPShaderInfo* shader_info, std::span<const WPShaderTexInfo> texs,
                        std::string* reflection_json,
                        std::optional<uint32_t> nv12_plane_slot = std::nullopt) {
    if (shader_info == nullptr) return false;
    if (nv12_plane_slot.has_value() && *nv12_plane_slot >= texs.size()) {
        LOG_ERROR("shader '%s': no texture slot %u to sample as planes",
                  std::string(shader_name).c_str(), *nv12_plane_slot);
        return false;
    }
    auto& state = State();

    // One request, a pure function of the pass: the same text on every launch.
    shader::RustShaderRequest request;
    request.shader_name   = std::string(shader_name);
    request.scene_id      = std::string(scene_id);
    request.cache_enabled = env.vfs != nullptr && env.vfs->IsMounted("cache");
    request.combos        = shader_info->combos;
    for (const auto& unit : units) request.stages.push_back({ unit.stage, unit.src });
    for (std::size_t slot = 0; slot < texs.size(); ++slot) {
        const auto& tex = texs[slot];
        shader::RustShaderTextureInfo info;
        info.slot       = static_cast<uint32_t>(slot);
        info.present    = tex.present;
        info.enabled    = tex.enabled;
        info.format     = FormatText(tex.format);
        info.components = tex.composEnabled;
        if (nv12_plane_slot.has_value() && *nv12_plane_slot == slot)
            info.video_planes = shader::RustShaderVideoPlanes::Nv12Biplanar;
        request.textures.push_back(std::move(info));
    }
    const std::string request_text = shader::BuildRustShaderRequestJson(request).dump();
    const std::string identity     = shader::RustShaderCacheIdentity();

    std::string table_key, file_path;
    if (request.cache_enabled) {
        const std::string keyed = request_text + '\n' + identity;
        table_key               = utils::genSha1(std::span<const char>(keyed.data(), keyed.size()));
        file_path               = ProgramFolder(scene_id) + "/" + table_key + ".json";
    }

    const auto finish = [&](const wallpaper::shader::RustShaderOutput& result) {
        MergeOutput(result, units, *shader_info);
        if (reflection_json != nullptr) *reflection_json = result.reflection_json;
    };

    if (request.cache_enabled) {
        const auto start = std::chrono::steady_clock::now();
        std::optional<StoredProgram> found;
        const auto                   resident = state.programs.find(table_key);
        if (resident != state.programs.end() &&
            Restore(resident->second, request_text, identity, units.size(), env, output)) {
            found = resident->second;
        } else if (auto stored = ReadProgramFile(*env.vfs, file_path);
                   stored && Restore(*stored, request_text, identity, units.size(), env, output)) {
            found = std::move(stored);
        }
        state.metrics.cache_read_ms += MillisSince(start);
        if (found) {
            ++state.metrics.cache_hits;
            if (env.used_includes != nullptr) {
                for (const auto& [path, text] : found->includes) (*env.used_includes)[path] = text;
            }
            state.Remember(table_key, std::move(*found));
            finish(output);
            return true;
        }
    }

    // A compile. Every include the shader layer asks for is recorded, with what it
    // got, so the program can be restored (and translated again) without them.
    ++state.metrics.cache_misses;
    WPShaderIncludeMap recorded;
    const auto         reader = [&](std::string_view path) {
        auto body = ReadInclude(env, path);
        recorded[std::string(path)] = body;
        return body;
    };
    const auto start = std::chrono::steady_clock::now();
    bool       ok    = false;
    try {
        ok = shader::CompileRustShaderProgram(request, output, reader);
        if (ok) {
            ok = ! output.reflection_json.empty() &&
                 ! nlohmann::json::parse(output.reflection_json, nullptr, false).is_discarded();
            for (const auto& stage : output.metal_stages) {
                ok = ok && ! stage.source.empty() && ! stage.entry_point.empty();
            }
            if (! ok) LOG_ERROR("shader '%s': the compiler's result is not usable", request.shader_name.c_str());
        } else {
            LOG_ERROR("shader '%s' failed to compile: %s", request.shader_name.c_str(),
                      shader::LastRustShaderError().c_str());
        }
    } catch (const std::exception& e) {
        LOG_ERROR("shader '%s' failed to compile: %s", request.shader_name.c_str(), e.what());
        ok = false;
    }
    state.metrics.compile_ms += MillisSince(start);
    if (! ok) return false;

    if (env.used_includes != nullptr) {
        for (const auto& [path, text] : recorded) (*env.used_includes)[path] = text;
    }
    // A program is remembered and published only when it is a whole one that the
    // request asked for.
    if (request.cache_enabled && ! output.cache_key.empty() && output.metal_stages.size() == units.size()) {
        StoredProgram program;
        program.request         = request_text;
        program.identity        = identity;
        program.includes.assign(recorded.begin(), recorded.end());
        for (const auto& stage : output.metal_stages)
            program.stages.push_back({ stage.kind, stage.source, Dump(MetalStageMetaJson(stage)) });
        program.metadata_json   = output.metadata_json;
        program.reflection_json = output.reflection_json;
        program.program_key     = output.cache_key;
        program.vertex_info     = InfoToJson(output.vertex_preprocessor_info);
        program.fragment_info   = InfoToJson(output.fragment_preprocessor_info);

        const auto write_start = std::chrono::steady_clock::now();
        WriteProgramFile(*env.vfs, file_path, Serialize(program));
        state.metrics.cache_write_ms += MillisSince(write_start);
        state.Remember(table_key, std::move(program));
    }
    finish(output);
    return true;
}

} // namespace

bool WPShaderParser::CompileToMslRust(std::string_view scene_id, std::string_view shader_name,
                                      std::span<WPShaderUnit> units,
                                      std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                      fs::VFS& vfs, WPShaderInfo* shader_info,
                                      std::span<const WPShaderTexInfo> texs,
                                      std::string* reflection_json,
                                      std::optional<uint32_t> nv12_plane_slot,
                                      WPShaderIncludeMap* used_includes) {
    shader::RustShaderOutput output {};
    const RustCompileEnv env { .vfs = &vfs, .used_includes = used_includes };
    if (! CompileProgramRust(scene_id, shader_name, units, output, env,
                             shader_info, texs, reflection_json, nv12_plane_slot)) {
        return false;
    }
    if (output.metal_stages.size() != units.size()) {
        LOG_ERROR("Rust shader returned %zu metal stages for %zu units in '%s'",
                  output.metal_stages.size(), units.size(), std::string(shader_name).c_str());
        return false;
    }

    stages = std::move(output.metal_stages);
    return true;
}

bool WPShaderParser::CompileMslVariant(const SceneMetalVariantInputs&             inputs,
                                       std::string_view                           cache_root,
                                       std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                       std::string* reflection_json, std::string* error) {
    // Copies of the caller's snapshot, never the snapshot itself: this compile
    // merges its own combos, default textures and preprocessor results into
    // whatever it is handed, and the snapshot has to stay exactly as captured
    // so a second attempt -- after a failure, or for another surface -- starts
    // from the same place.
    auto         units       = inputs.units;
    WPShaderInfo shader_info = inputs.shader_info;

    // The same on-disk program cache the ordinary translation writes, reached
    // without the parse's virtual file system because that is long gone by the
    // time anything asks for a variant. Only `/cache` is mounted: the includes
    // come from the snapshot, so nothing here can read the project, and the
    // cache key is built from the request exactly as it is during a parse --
    // which is why an entry written by one launch is found by the next.
    //
    // An absent or unusable cache root is not a failure. It compiles, and the
    // result lives for as long as this process does.
    fs::VFS cache_vfs;
    if (! cache_root.empty()) {
        if (! cache_vfs.Mount("/cache", fs::CreatePhysicalFs(cache_root, true), "cache")) {
            LOG_INFO("metal variant cache folder unavailable: %s",
                     std::string(cache_root).c_str());
        }
    }

    shader::RustShaderOutput output {};
    const RustCompileEnv env { .vfs      = cache_vfs.IsMounted("cache") ? &cache_vfs : nullptr,
                               .includes = &inputs.includes };
    const auto           set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };

    try {
        if (! CompileProgramRust(inputs.scene_id, inputs.shader_name, units, output, env,
                                 &shader_info, inputs.texinfos, reflection_json,
                                 inputs.nv12_plane_slot)) {
            auto message = wallpaper::shader::LastRustShaderError();
            if (message.empty()) message = "the shader cannot sample the video as planes";
            return set_error(std::move(message));
        }
    } catch (const std::exception& e) {
        return set_error(e.what());
    }
    if (output.metal_stages.size() != units.size()) {
        return set_error("the plane variant produced the wrong number of stages");
    }

    stages = std::move(output.metal_stages);
    return true;
}
