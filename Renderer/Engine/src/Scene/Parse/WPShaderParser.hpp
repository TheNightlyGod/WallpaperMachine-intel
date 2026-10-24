#pragma once

#include <map>
#include <optional>
#include <span>
#include "Scene/Scene.h"
#include "Scene/SceneShader.h"
#include "Type.hpp"

namespace wallpaper
{
namespace fs
{
class VFS;
}
namespace shader
{
struct RustShaderMetalStage;
}
using Combos = Map<std::string, std::string>;

// ui material name to gl uniform name
using WPAliasValueDict = Map<std::string, std::string>;

using WPDefaultTexs = std::vector<std::pair<i32, std::string>>;

struct WPShaderInfo {
    Combos           combos;
    ShaderValueMap   svs;
    ShaderValueMap   baseConstSvs;
    WPAliasValueDict alias;
    WPDefaultTexs    defTexs;
    /// The pass is drawn somewhere the scene's fog does not belong -- into the
    /// card of a layer that composites through effects -- so `LoadMaterial`
    /// leaves the fog out of it, and says through `fog_deferred` that the pass
    /// would have taken it: its `FOG` combo, the material's or the shader's own
    /// default, is on in a scene that has fog.
    bool             defer_fog { false };
    bool             fog_deferred { false };
};

struct WPPreprocessorInfo {
    Map<std::string, std::string> input; // name to line
    Map<std::string, std::string> output;

    Set<uint> active_tex_slots;
};

struct WPShaderTexInfo {
    bool                present { false };
    bool                enabled { false };
    TextureFormat       format { TextureFormat::RGBA8 };
    std::array<bool, 4> composEnabled { false, false, false, false };
};

struct WPShaderUnit {
    ShaderType         stage;
    std::string        src;
    WPPreprocessorInfo preprocess_info;
};

/// Every include one translation read, with the contents it saw. A value
/// without a string is an include that was asked for and did not exist, which
/// is part of the answer too: a later compile that suddenly finds it is not
/// compiling the same program.
using WPShaderIncludeMap = std::map<std::string, std::optional<std::string>>;

/// The exact inputs one optional Metal variant compile needs, owned
/// independently of the parse that produced them.
///
/// This exists because the variant is deliberately not compiled while the
/// wallpaper is loading. By the time something asks for it -- the renderer
/// after its first frame, or the user ticking a setting an hour later -- the
/// parser, its virtual file system and the project's shader sources are gone.
/// Everything the compile reads is therefore copied in here, including the
/// includes, so the background task owns its whole input and shares no mutable
/// state with a parse that may be running for another scene.
struct SceneMetalVariantInputs {
    std::string                  scene_id;
    std::string                  shader_name;
    std::vector<WPShaderUnit>    units;
    WPShaderInfo                 shader_info;
    std::vector<WPShaderTexInfo> texinfos;
    WPShaderIncludeMap           includes;
    /// Material texture slot this variant samples as NV12 planes.
    uint32_t                     nv12_plane_slot { 0 };
};

struct ShaderStartupMetrics {
    // Program cache lookups of one parse.
    uint64_t cache_hits { 0 };
    uint64_t cache_misses { 0 };
    // Time spent per stage, in milliseconds.
    double include_expand_ms { 0.0 };    // `#include` expansion
    double metadata_extract_ms { 0.0 };  // uniforms, samplers, combos read off the source
    double preprocess_ms { 0.0 };
    double legalize_ms { 0.0 };          // rewriting into the dialect the compiler takes
    double final_assembly_ms { 0.0 };
    double compile_ms { 0.0 };           // the Rust compiler call
    double cache_read_ms { 0.0 };        // disk cache
    double cache_write_ms { 0.0 };
};

class WPShaderParser {
public:
    static constexpr uint32_t kShaderPipelineRevision = 2;

    /// Opens and closes the shader work of one parse: the per-thread program
    /// cache and the startup counters are reset at the start, and the counters
    /// are reported at the end.
    static void BeginShaderSession();
    static void EndShaderSession();

    static void                 ResetStartupMetrics();
    static ShaderStartupMetrics GetStartupMetrics();
    static void ClearProgramCache();

    // Compiles one program to Metal Shading Language and merges what the
    // compile learned (combos, uniforms, aliases, default textures, preprocessor
    // facts) into the units and `WPShaderInfo`. The parse runs this until a
    // material's default textures stop changing, which is what settles its
    // combos, uniforms, aliases and active texture slots; the stages of the last
    // run, the settled one, are the program the renderer draws with.
    // `reflection_json` carries the program's reflection payload.
    //
    // `nv12_plane_slot`, when given, asks for the variant of the same author
    // program that samples that material texture slot as NV12 luma and chroma
    // planes instead of one converted image. It is a different program with a
    // different cache key, never a rewrite of the one above, and a shader that
    // reads the slot in a way the translation cannot reproduce fails this call
    // and keeps the ordinary program.
    //
    // `used_includes`, when given, receives every include this translation
    // read, so the same program can be translated again later without the file
    // system it was read from.
    static bool CompileToMslRust(std::string_view scene_id, std::string_view shader_name,
                                 std::span<WPShaderUnit>,
                                 std::vector<shader::RustShaderMetalStage>& stages, fs::VFS&,
                                 WPShaderInfo*, std::span<const WPShaderTexInfo>,
                                 std::string* reflection_json = nullptr,
                                 std::optional<uint32_t> nv12_plane_slot = std::nullopt,
                                 WPShaderIncludeMap* used_includes = nullptr);

    // The optional plane-sampling variant, compiled from a snapshot rather
    // than from the project.
    //
    // Callable from any thread and from outside a parse: it touches no virtual
    // file system, writes no shader cache file and mutates nothing the caller
    // owns. The compiler's own process-wide state is serialised internally, so
    // this may run while another scene is being parsed.
    //
    // `cache_root`, when given, is the same on-disk shader cache the ordinary
    // translation uses. A hit returns the stored Metal source, reflection and
    // binding metadata without running the compiler at all, including on a
    // launch that has compiled nothing yet; a miss, a stale entry or a
    // corrupted one compiles normally and republishes. Passing nothing keeps
    // the result in memory for this process only.
    static bool CompileMslVariant(const SceneMetalVariantInputs&             inputs,
                                  std::string_view                           cache_root,
                                  std::vector<shader::RustShaderMetalStage>& stages,
                                  std::string* reflection_json, std::string* error);
};
} // namespace wallpaper
