// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <memory>
#include <optional>
#include <stdexcept>

namespace wallpaper::shader
{
namespace
{


struct RsShaderOwnedBytes {
    uint8_t* ptr;
    size_t   len;
    void (*free)(uint8_t*, size_t, void*);
    void* free_user_data;
};

struct RsShaderProgram;

// Called back while a compile runs, for every `#include`d path the shader names.
using RsShaderIncludeCallback = RsShaderOwnedBytes (*)(const char* path, void* user_data);

#ifdef WESCENE_HAS_RUST_SHADER_FFI
extern "C" {
int rs_shader_compile_program(const char* request_json, RsShaderIncludeCallback include_callback,
                              void* include_user_data, RsShaderProgram** out_program);
size_t      rs_shader_program_stage_count(const RsShaderProgram* program);
int         rs_shader_program_stage_kind(const RsShaderProgram* program, size_t stage_index);
int         rs_shader_program_stage_target(const RsShaderProgram* program, size_t stage_index);
const char* rs_shader_program_stage_msl_source(const RsShaderProgram* program, size_t stage_index);
const char* rs_shader_program_stage_metal_json(const RsShaderProgram* program, size_t stage_index);
const char* rs_shader_program_metadata_json(const RsShaderProgram* program);
const char* rs_shader_program_reflection_json(const RsShaderProgram* program);
const char* rs_shader_program_diagnostics_json(const RsShaderProgram* program);
const char* rs_shader_program_cache_key(const RsShaderProgram* program);
void        rs_shader_program_free(RsShaderProgram* program);
const char* rs_shader_last_error();
const char* rs_shader_cache_identity();
}
#endif

RustShaderMetalSlotKind FromMetalSlotKind(std::string_view slot_kind)
{
    if (slot_kind == "buffer") {
        return RustShaderMetalSlotKind::Buffer;
    }
    if (slot_kind == "texture") {
        return RustShaderMetalSlotKind::Texture;
    }
    if (slot_kind == "sampler") {
        return RustShaderMetalSlotKind::Sampler;
    }
    throw std::runtime_error("Rust shader returned an unknown metal slot kind");
}

const char* StageKindName(ShaderType kind)
{
    switch (kind) {
    case ShaderType::VERTEX: return "vertex";
    case ShaderType::FRAGMENT: return "fragment";
    default: break;
    }
    throw std::runtime_error("shader stage kind must be vertex or fragment");
}

ShaderValue ShaderValueFromDefault(const nlohmann::json& value)
{
    const auto& kind = value.at("kind").get_ref<const std::string&>();
    const auto& body = value.at("value");
    if (kind == "number") return ShaderValue(body.get<float>());
    if (kind == "bool") return ShaderValue(body.get<bool>() ? 1.0f : 0.0f);
    if (kind == "vec2" || kind == "vec3" || kind == "vec4" || kind == "matrix4") {
        const auto floats = body.get<std::vector<float>>();
        return ShaderValue(floats.data(), floats.size());
    }
    return ShaderValue {};
}

void MergeActiveSlots(const nlohmann::json& document, RustShaderOutput& output)
{
    const auto slots = document.value("active_texture_slots", nlohmann::json::array());
    for (const auto& slot : slots) {
        output.fragment_preprocessor_info.active_tex_slots.insert(slot.get<uint>());
    }
}

#ifdef WESCENE_HAS_RUST_SHADER_FFI
std::string CopyCString(const char* text)
{
    return text ? std::string(text) : std::string();
}

// Owns the compiler's program for the span of one compile.
class ScopedCompilerProgram {
public:
    explicit ScopedCompilerProgram(RsShaderProgram* program) noexcept: m_program(program) {}
    ScopedCompilerProgram(const ScopedCompilerProgram&)            = delete;
    ScopedCompilerProgram& operator=(const ScopedCompilerProgram&) = delete;
    ~ScopedCompilerProgram()
    {
        if (m_program != nullptr) rs_shader_program_free(m_program);
    }
    const RsShaderProgram* get() const noexcept { return m_program; }
    explicit operator bool() const noexcept { return m_program != nullptr; }

private:
    RsShaderProgram* m_program;
};

// An include reply owns its text as a heap string; the compiler's release call deletes it.
void DeleteIncludeText(uint8_t*, size_t, void* owner)
{
    delete static_cast<std::string*>(owner);
}

RsShaderOwnedBytes NoInclude()
{
    return RsShaderOwnedBytes { nullptr, 0, nullptr, nullptr };
}

RsShaderOwnedBytes ServeInclude(const char* path, void* user_data)
{
    const auto* reader = static_cast<const RustShaderIncludeReader*>(user_data);
    if (reader == nullptr || ! static_cast<bool>(*reader) || path == nullptr) return NoInclude();

    std::unique_ptr<std::string> text;
    try {
        std::optional<std::string> found = (*reader)(path);
        if (found) text = std::make_unique<std::string>(std::move(*found));
    } catch (...) {
        // a reader fault or an allocation failure is "not available" to the compiler
    }
    if (! text) return NoInclude();

    // std::string::data() is never null, so an empty include stays distinguishable from a missing one.
    auto* bytes = reinterpret_cast<uint8_t*>(text->data());
    const size_t length = text->size();
    return RsShaderOwnedBytes { bytes, length, &DeleteIncludeText, text.release() };
}

// What reading a compiler program produced: a complete output, or nothing usable.
struct ProgramReading {
    bool             usable { false };
    RustShaderOutput output;
};

ProgramReading ReadProgram(const RsShaderProgram* program)
{
    ProgramReading reading;
    try {
        RustShaderOutput gathered;
        const size_t count = rs_shader_program_stage_count(program);
        gathered.metal_stages.reserve(count);
        for (size_t index = 0; index < count; ++index) {
            const char* source = rs_shader_program_stage_msl_source(program, index);
            if (source == nullptr || source[0] == '\0') return reading;
            if (rs_shader_program_stage_target(program, index) != 1) return reading;
            const int  kind  = rs_shader_program_stage_kind(program, index);
            const bool is_vs = kind == 0;
            if (! is_vs && kind != 1) return reading;

            RustShaderMetalStage stage;
            ApplyRustShaderMetalStageJson(CopyCString(rs_shader_program_stage_metal_json(program, index)),
                                          source,
                                          is_vs ? ShaderType::VERTEX : ShaderType::FRAGMENT,
                                          stage);
            gathered.metal_stages.push_back(std::move(stage));
        }

        gathered.cache_key        = CopyCString(rs_shader_program_cache_key(program));
        gathered.diagnostics_json = CopyCString(rs_shader_program_diagnostics_json(program));
        gathered.reflection_json  = CopyCString(rs_shader_program_reflection_json(program));
        gathered.metadata_json    = CopyCString(rs_shader_program_metadata_json(program));
        ApplyRustShaderReflectionJson(gathered.reflection_json, gathered);
        ApplyRustShaderMetadataJson(gathered.metadata_json, gathered);

        reading.output = std::move(gathered);
        reading.usable = true;
    } catch (...) {
        reading = ProgramReading {};
    }
    return reading;
}

bool CompileRequestText(const std::string& request_text,
                        RustShaderOutput& output,
                        const RustShaderIncludeReader& include_reader)
{
    RsShaderProgram* produced = nullptr;
    RsShaderIncludeCallback callback = include_reader ? &ServeInclude : nullptr;
    const int status = rs_shader_compile_program(
        request_text.c_str(), callback, const_cast<RustShaderIncludeReader*>(&include_reader), &produced);
    const ScopedCompilerProgram program(produced);

    ProgramReading reading;
    if (status == 0 && program) reading = ReadProgram(program.get());

    output = reading.usable ? std::move(reading.output) : RustShaderOutput {};
    return reading.usable;
}
#endif

} // namespace

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request)
{
    using nlohmann::json;
    json document = json::object();
    document["shader_name"] = request.shader_name;
    document["target"]      = "metal_msl";
    if (request.point_geometry) {
        const auto& geometry = *request.point_geometry;
        document["point_geometry"] = { { "source", geometry.source },
                                       { "max_vertices", geometry.max_vertices },
                                       { "output_index_attribute", geometry.output_index_attribute } };
    }
    if (request.cache_enabled) {
        document["cache_policy"] = { { "mode", "enabled" }, { "scene_id", request.scene_id } };
    } else {
        document["cache_policy"] = { { "mode", "disabled" } };
    }

    json stages = json::array();
    for (const auto& stage : request.stages) {
        stages.push_back({ { "kind", StageKindName(stage.kind) }, { "source", stage.source } });
    }
    document["stages"] = std::move(stages);

    json combos = json::array();
    for (const auto& [name, value] : request.combos) {
        combos.push_back({ { "name", name }, { "value", value } });
    }
    document["combos"] = std::move(combos);

    json textures = json::array();
    for (const auto& texture : request.textures) {
        json entry = {
            { "slot", texture.slot },
            { "present", texture.present },
            { "enabled", texture.enabled },
            { "format", texture.format },
            { "components",
              { { "compo1", texture.components[0] },
                { "compo2", texture.components[1] },
                { "compo3", texture.components[2] },
                { "compo4", texture.components[3] } } },
        };
        if (texture.video_planes == RustShaderVideoPlanes::Nv12Biplanar) {
            entry["video_planes"] = "nv12_biplanar";
        }
        if (texture.sample_count) entry["sample_count"] = *texture.sample_count;
        textures.push_back(std::move(entry));
    }
    document["textures"] = std::move(textures);

    json properties = json::array();
    for (const auto& property : request.properties) {
        properties.push_back({ { "name", property.name },
                               { "value",
                                 { { "kind", property.value.kind },
                                   { "value", property.value.value } } } });
    }
    document["properties"] = std::move(properties);
    return document;
}

void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output)
{
    const auto document = nlohmann::json::parse(metadata_json);
    const auto& none    = nlohmann::json::array();
    // Decode everything first so a malformed element leaves the output as it was.
    Combos                                combos;
    WPAliasValueDict                      aliases;
    Set<std::string>                      angle_aliases;
    ShaderValueMap                        uniforms;
    WPDefaultTexs                         textures;
    for (const auto& entry : document.value("combos", none)) {
        combos[entry.at("name").get<std::string>()] = entry.at("value").get<std::string>();
    }
    for (const auto& entry : document.value("aliases", none)) {
        const auto material = entry.at("material").get<std::string>();
        aliases[material] = entry.at("uniform").get<std::string>();
        // Optional flags keep old metadata/cache documents compatible. For a
        // duplicate alias the final entry supplies its uniform and conversion.
        if (entry.value("rad2deg", false)) angle_aliases.insert(material);
        else angle_aliases.erase(material);
    }
    for (const auto& entry : document.value("default_uniforms", none)) {
        uniforms.insert_or_assign(entry.at("name").get<std::string>(),
                                  ShaderValueFromDefault(entry.at("value")));
    }
    for (const auto& entry : document.value("default_textures", none)) {
        textures.emplace_back(entry.at("slot").get<i32>(), entry.at("path").get<std::string>());
    }
    std::vector<uint> slots;
    for (const auto& slot : document.value("active_texture_slots", none)) {
        slots.push_back(slot.get<uint>());
    }

    auto& info = output.shader_info;
    for (auto& [k, v] : combos) info.combos[k] = std::move(v);
    for (auto& [k, v] : aliases) {
        info.alias[k] = std::move(v);
        if (angle_aliases.contains(k)) info.alias_rad2deg.insert(k);
        else info.alias_rad2deg.erase(k);
    }
    for (auto& [k, v] : uniforms) info.svs.insert_or_assign(k, std::move(v));
    for (auto& t : textures) info.defTexs.push_back(std::move(t));
    output.fragment_preprocessor_info.active_tex_slots.insert(slots.begin(), slots.end());
}

void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output)
{
    MergeActiveSlots(nlohmann::json::parse(reflection_json), output);
}

void ApplyRustShaderMetalStageJson(
    std::string_view metal_json,
    std::string_view msl_source,
    ShaderType kind,
    RustShaderMetalStage& stage)
{
    const auto metal = nlohmann::json::parse(metal_json);

    stage.kind        = kind;
    stage.source      = std::string(msl_source);
    stage.entry_point = metal.at("entry_point").get<std::string>();
    if (stage.entry_point.empty()) {
        throw std::runtime_error("Rust shader returned an empty metal entry point");
    }
    stage.language_version = metal.value("language_version", std::string {});

    stage.bindings.clear();
    for (const auto& binding : metal.value("bindings", nlohmann::json::array())) {
        stage.bindings.push_back(RustShaderMetalBinding {
            .name      = binding.at("name").get<std::string>(),
            .set       = binding.at("set").get<uint32_t>(),
            .binding   = binding.at("binding").get<uint32_t>(),
            .slot_kind = FromMetalSlotKind(binding.at("slot_kind").get<std::string>()),
            .slot      = binding.at("slot").get<uint32_t>(),
        });
    }

    const auto conventions = metal.value("conventions", nlohmann::json::object());
    stage.conventions      = RustShaderMetalConventions {
             .clip_space_y_flipped      = conventions.value("clip_space_y_flipped", false),
             .clip_space_depth_remapped = conventions.value("clip_space_depth_remapped", false),
             .texture_origin_flipped    = conventions.value("texture_origin_flipped", false),
    };
}

bool CompileRustShaderProgram(
    const RustShaderRequest& request,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    try {
        return CompileRequestText(BuildRustShaderRequestJson(request).dump(), output, include_reader);
    } catch (...) {
        output = RustShaderOutput {};
        return false;
    }
#else
    (void)request, (void)include_reader;
    output = RustShaderOutput {};
    return false;
#endif
}

std::string RustShaderCacheIdentity()
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    return CopyCString(rs_shader_cache_identity());
#else
    return "wallpaper-machine-shader-compiler-not-linked";
#endif
}

std::string LastRustShaderError()
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    return CopyCString(rs_shader_last_error());
#else
    return "the shader compiler is not linked into this build";
#endif
}

#ifdef WESCENE_BUILD_TESTS
bool CompileRustShaderProgramWithBridgeJson(
    const nlohmann::json& request_json,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    try {
        return CompileRequestText(request_json.dump(), output, include_reader);
    } catch (...) {
        output = RustShaderOutput {};
        return false;
    }
#else
    (void)request_json, (void)include_reader;
    output = RustShaderOutput {};
    return false;
#endif
}
#endif

} // namespace wallpaper::shader
