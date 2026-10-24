#pragma once

#include "Scene/Parse/WPShaderParser.hpp"
#include "Shader/RustShaderIdentity.hpp"

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace wallpaper::shader
{

// Metal argument-table namespace a shader resource is bound into. Metal keeps
// buffers, textures and samplers in independent index spaces, so a slot is
// only meaningful together with its namespace.
enum class RustShaderMetalSlotKind {
    Buffer,
    Texture,
    Sampler,
};

struct RustShaderStageSource {
    ShaderType  kind;
    std::string source;
};

// Plane layout one texture slot is compiled to sample through. `None` is what
// every ordinary texture carries and what keeps the generated program, and its
// cache key, identical to the one this compiler produced before the option
// existed.
enum class RustShaderVideoPlanes {
    None,
    Nv12Biplanar,
};

struct RustShaderTextureInfo {
    uint32_t              slot { 0 };
    bool                  present { true };
    bool                  enabled { false };
    std::string           format { "rgba8" };
    std::array<bool, 4>   components { false, false, false, false };
    RustShaderVideoPlanes video_planes { RustShaderVideoPlanes::None };
};

struct RustShaderPropertyValue {
    std::string        kind;
    nlohmann::json     value;
};

struct RustShaderProperty {
    std::string             name;
    RustShaderPropertyValue value;
};

struct RustShaderRequest {
    std::string                         shader_name;
    std::string                         scene_id;
    bool                                cache_enabled { false };
    std::vector<RustShaderStageSource>  stages;
    Combos                              combos;
    std::vector<RustShaderTextureInfo>  textures;
    std::vector<RustShaderProperty>     properties;
};

// One shader resource and the Metal argument-table slot it was bound to.
//
// `name` is the original shader-visible global name, which is what the
// reflection payload uses. It is not necessarily the identifier that appears
// in the generated Metal source: the backend appends a suffix on collisions.
struct RustShaderMetalBinding {
    std::string             name;
    uint32_t                set { 0 };
    uint32_t                binding { 0 };
    RustShaderMetalSlotKind slot_kind { RustShaderMetalSlotKind::Buffer };
    uint32_t                slot { 0 };
};

// Coordinate conventions the generated Metal source follows. Every field
// records a transform the shader compiler could have injected; the Metal
// renderer has to agree with these instead of assuming them.
struct RustShaderMetalConventions {
    bool clip_space_y_flipped { false };
    bool clip_space_depth_remapped { false };
    bool texture_origin_flipped { false };
};

// Compiled Metal Shading Language output for one shader stage.
struct RustShaderMetalStage {
    ShaderType                          kind { ShaderType::VERTEX };
    std::string                         source;
    // Generated Metal entry-point function name. The backend renames entry
    // points, so this is never assumed to be "main".
    std::string                         entry_point;
    std::string                         language_version;
    std::vector<RustShaderMetalBinding> bindings;
    RustShaderMetalConventions          conventions;
};

struct RustShaderOutput {
    WPShaderInfo       shader_info;
    WPPreprocessorInfo vertex_preprocessor_info;
    WPPreprocessorInfo fragment_preprocessor_info;
    std::string        metadata_json;
    std::string        reflection_json;
    std::string        diagnostics_json;
    std::string        cache_key;
    // One entry per stage, in request order. The shader layer has one target,
    // Metal Shading Language, so every successful compile carries them.
    std::vector<RustShaderMetalStage> metal_stages;
};

using RustShaderIncludeReader = std::function<std::optional<std::string>(std::string_view)>;

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request);
void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output);
void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output);
void ApplyRustShaderMetalStageJson(
    std::string_view metal_json,
    std::string_view msl_source,
    ShaderType kind,
    RustShaderMetalStage& stage);

// Compiles one shader program through the Rust library. True only when `output` is usable;
// otherwise `LastRustShaderError()` says why. `include_reader` serves `#include` paths.
bool CompileRustShaderProgram(const RustShaderRequest& request, RustShaderOutput& output,
                              const RustShaderIncludeReader& include_reader = {});

// The text of the last bridge failure on the calling thread.
std::string LastRustShaderError();

#ifdef WESCENE_BUILD_TESTS
// The same compile from a hand-written request document, so tests can feed the bridge input
// the request builder would never produce.
bool CompileRustShaderProgramWithBridgeJson(const nlohmann::json& request_json,
                                            RustShaderOutput& output,
                                            const RustShaderIncludeReader& include_reader = {});
#endif
} // namespace wallpaper::shader
