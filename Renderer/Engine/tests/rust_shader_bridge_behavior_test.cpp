// Behaviour of the C++ side of the shader compiler: the request document it builds,
// how it merges the compiler's metadata and reflection documents, the one-call
// compile, and what the parser entry point takes from a compile.

#include "Shader/RustShaderBridge.hpp"

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Scene/Parse/WPShaderParser.hpp"
#include "shader_test_scratch.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <set>
#include <string>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::shader;
using nlohmann::json;

namespace
{

const char* const kPlainVertex =
    "attribute vec2 a_Position;\n"
    "void main() {\n"
    "    gl_Position = vec4(a_Position, 0.0, 1.0);\n"
    "}\n";

const char* const kPlainFragment =
    "void main() {\n"
    "    gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0);\n"
    "}\n";

RustShaderRequest PlainRequest() {
    RustShaderRequest request;
    request.shader_name   = "bridge_plain";
    request.scene_id      = "bridge-scene";
    request.cache_enabled = true;
    request.stages        = { { ShaderType::VERTEX, kPlainVertex }, { ShaderType::FRAGMENT, kPlainFragment } };
    request.combos["BLENDMODE"] = "0";
    RustShaderTextureInfo texture;
    texture.slot       = 0;
    texture.present    = true;
    texture.enabled    = true;
    texture.format     = "rgba8";
    texture.components = { true, false, false, false };
    request.textures.push_back(texture);
    return request;
}

RustShaderTextureInfo TextureRecord(uint32_t slot, bool present, bool enabled) {
    RustShaderTextureInfo texture;
    texture.slot    = slot;
    texture.present = present;
    texture.enabled = enabled;
    return texture;
}

// A request without any cache so repeated compiles always reach the compiler.
RustShaderRequest UncachedPlainRequest() {
    auto request          = PlainRequest();
    request.cache_enabled = false;
    return request;
}

void SetFragment(RustShaderRequest& request, const std::string& source) {
    request.stages[1].source = source;
}

const char* const kTwoSamplerFragment =
    "varying vec2 v_Uv;\n"
    "uniform sampler2D g_Texture0;\n"
    "uniform sampler2D g_Texture1;\n"
    "void main() {\n"
    "    gl_FragColor = texSample2D(g_Texture0, v_Uv) + texSample2D(g_Texture1, v_Uv);\n"
    "}\n";

const char* const kOneSampledFragment =
    "varying vec2 v_Uv;\n"
    "uniform sampler2D g_Texture0;\n"
    "uniform sampler2D g_Texture1;\n"
    "void main() {\n"
    "    gl_FragColor = texSample2D(g_Texture0, v_Uv);\n"
    "}\n";

// The fragment of the NORMALMAP scenario: the combo only exists while the second
// sampler is declared, and the second sampler only exists under LIGHTING.
const char* const kComboGatedFragment =
    "// [COMBO] {\"combo\":\"LIGHTING\",\"default\":1}\n"
    "varying vec2 v_Uv;\n"
    "uniform sampler2D g_Texture0;\n"
    "#if LIGHTING\n"
    "uniform sampler2D g_Texture1; // {\"combo\":\"NORMALMAP\"}\n"
    "#endif\n"
    "void main() {\n"
    "    vec4 color = texSample2D(g_Texture0, v_Uv);\n"
    "#if LIGHTING && NORMALMAP\n"
    "    color += texSample2D(g_Texture1, v_Uv);\n"
    "#endif\n"
    "    gl_FragColor = color;\n"
    "}\n";

const char* const kAnnotatedVertex =
    "attribute vec2 a_Position;\n"
    "varying vec2 v_Uv;\n"
    "void main() {\n"
    "    v_Uv = a_Position * 0.5 + vec2(0.5, 0.5);\n"
    "    gl_Position = vec4(a_Position, 0.0, 1.0);\n"
    "}\n";

const char* const kAnnotatedFragment =
    "varying vec2 v_Uv;\n"
    "uniform sampler2D g_Texture0; // {\"material\":\"albedo\",\"combo\":\"HAS_TEXTURE\",\"default\":\"materials/default.png\"}\n"
    "uniform float g_Brightness; // {\"material\":\"brightness\",\"default\":1.25}\n"
    "void main() {\n"
    "    gl_FragColor = texSample2D(g_Texture0, v_Uv) * g_Brightness;\n"
    "}\n";

std::vector<WPShaderUnit> AnnotatedUnits(const std::string& fragment = kAnnotatedFragment) {
    std::vector<WPShaderUnit> units(2);
    units[0].stage = ShaderType::VERTEX;
    units[0].src   = kAnnotatedVertex;
    units[1].stage = ShaderType::FRAGMENT;
    units[1].src   = fragment;
    return units;
}

struct ParserRun {
    bool                              ok { false };
    std::string                       error;
    std::vector<WPShaderUnit>         units;
    std::vector<RustShaderMetalStage> stages;
    WPShaderInfo                      info;
    std::string                       reflection;
};

ParserRun RunAnnotated(const std::string& scene, const std::string& name,
                       const std::vector<WPShaderTexInfo>& textures,
                       const std::string& fragment = kAnnotatedFragment) {
    ParserRun run;
    run.units = AnnotatedUnits(fragment);
    fs::VFS vfs;
    run.ok    = WPShaderParser::CompileToMslRust(scene, name, run.units, run.stages, vfs, &run.info, textures,
                                                 &run.reflection);
    if (! run.ok) run.error = LastRustShaderError();
    return run;
}

std::vector<WPShaderTexInfo> OnePresentTexture() {
    WPShaderTexInfo texture;
    texture.present = true;
    texture.enabled = true;
    return { texture };
}

std::set<std::string> DescriptorNames(const std::string& reflection_text) {
    std::set<std::string> names;
    const auto            reflection = json::parse(reflection_text);
    for (const auto& descriptor : reflection.at("descriptor_bindings")) {
        names.insert(descriptor.at("name").get<std::string>());
    }
    return names;
}

std::set<uint> ReflectedSlots(const std::string& reflection_text) {
    std::set<uint> slots;
    for (const auto& slot : json::parse(reflection_text).value("active_texture_slots", json::array())) {
        slots.insert(slot.get<uint>());
    }
    return slots;
}

const json* FindNamed(const json& list, const std::string& name) {
    for (const auto& entry : list) {
        if (entry.at("name").get<std::string>() == name) return &entry;
    }
    return nullptr;
}

const RustShaderMetalBinding* FindBinding(const RustShaderMetalStage& stage, const std::string& name) {
    for (const auto& binding : stage.bindings) {
        if (binding.name == name) return &binding;
    }
    return nullptr;
}

json CompleteMetadata() {
    return {
        { "combos", json::array({ { { "name", "HASALPHA" }, { "value", "1" } } }) },
        { "aliases", json::array({ { { "material", "strength" }, { "uniform", "g_Strength" } } }) },
        { "default_uniforms",
          json::array({ { { "name", "g_Strength" }, { "value", { { "kind", "number" }, { "value", 0.75 } } } } }) },
        { "default_textures", json::array({ { { "slot", 0 }, { "path", "materials/default.png" } } }) },
        { "active_texture_slots", json::array({ 0, 2 }) },
    };
}

json CompleteReflection() {
    return {
        { "descriptor_bindings",
          json::array({
              { { "name", "GlobalUniforms" }, { "set", 0 }, { "binding", 0 }, { "descriptor", "uniform_buffer" },
                { "stages", json::array({ "vertex", "fragment" }) }, { "count", 1 } },
              { { "name", "g_Texture0" }, { "set", 0 }, { "binding", 1 }, { "descriptor", "sampled_image" },
                { "stages", json::array({ "fragment" }) }, { "count", 1 } },
              { { "name", "_we_Sampler_g_Texture0" }, { "set", 0 }, { "binding", 2 }, { "descriptor", "sampler" },
                { "stages", json::array({ "fragment" }) }, { "count", 1 } },
          }) },
        { "uniform_blocks",
          json::array({ { { "name", "GlobalUniforms" }, { "set", 0 }, { "binding", 0 }, { "size", 64 },
                          { "members",
                            json::array({ { { "name", "g_ModelViewProjectionMatrix" }, { "offset", 0 },
                                            { "size", 64 }, { "element_count", 16 }, { "array_count", 0 },
                                            { "array_stride", 0 } } }) } } }) },
        { "vertex_inputs",
          json::array({ { { "name", "a_Position" }, { "location", 0 }, { "format", "r32g32_sfloat" } } }) },
        { "active_texture_slots", json::array({ 0 }) },
    };
}

} // namespace

// RB-01 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeRequest, DocumentCarriesNameTargetCachePolicyStagesCombosAndTextures) {
    const auto request  = PlainRequest();
    const auto document = BuildRustShaderRequestJson(request);

    EXPECT_EQ(document.at("shader_name"), request.shader_name);
    EXPECT_EQ(document.at("target"), "metal_msl");
    EXPECT_EQ(document.at("cache_policy"), (json { { "mode", "enabled" }, { "scene_id", request.scene_id } }));

    ASSERT_EQ(document.at("stages").size(), 2u);
    EXPECT_EQ(document.at("stages")[0].at("kind"), "vertex");
    EXPECT_EQ(document.at("stages")[1].at("kind"), "fragment");
    EXPECT_EQ(document.at("stages")[0].at("source"), kPlainVertex);
    EXPECT_EQ(document.at("stages")[1].at("source"), kPlainFragment);

    ASSERT_EQ(document.at("combos").size(), 1u);
    EXPECT_EQ(document.at("combos")[0], (json { { "name", "BLENDMODE" }, { "value", "0" } }));

    ASSERT_EQ(document.at("textures").size(), 1u);
    const auto& texture = document.at("textures")[0];
    EXPECT_TRUE(texture.at("present").get<bool>());
    EXPECT_TRUE(texture.at("enabled").get<bool>());
    EXPECT_EQ(texture.at("slot"), 0);
    EXPECT_EQ(texture.at("format"), "rgba8");
    EXPECT_EQ(texture.at("components"),
              (json { { "compo1", true }, { "compo2", false }, { "compo3", false }, { "compo4", false } }));
    EXPECT_FALSE(texture.contains("video_planes"));

    EXPECT_TRUE(document.at("properties").is_array());
}

TEST(ShaderBridgeRequest, EveryComponentFlagTravelsInItsOwnSlot) {
    auto request                    = PlainRequest();
    request.textures[0].components  = { false, true, true, false };
    request.textures.push_back(TextureRecord(1, true, true));
    request.textures[1].components  = { false, false, false, true };
    const auto textures             = BuildRustShaderRequestJson(request).at("textures");
    EXPECT_EQ(textures[0].at("components"),
              (json { { "compo1", false }, { "compo2", true }, { "compo3", true }, { "compo4", false } }));
    EXPECT_EQ(textures[1].at("components"),
              (json { { "compo1", false }, { "compo2", false }, { "compo3", false }, { "compo4", true } }));
    EXPECT_EQ(textures[1].at("slot"), 1);
}

TEST(ShaderBridgeRequest, CombosFollowKeyOrder) {
    auto request = PlainRequest();
    request.combos["ZETA"]  = "2";
    request.combos["ALPHA"] = "9";
    const auto document     = BuildRustShaderRequestJson(request);

    ASSERT_EQ(document.at("combos").size(), 3u);
    EXPECT_EQ(document.at("combos")[0], (json { { "name", "ALPHA" }, { "value", "9" } }));
    EXPECT_EQ(document.at("combos")[1], (json { { "name", "BLENDMODE" }, { "value", "0" } }));
    EXPECT_EQ(document.at("combos")[2], (json { { "name", "ZETA" }, { "value", "2" } }));
}

// RB-02 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeMerge, MetadataAndReflectionFillTheOutput) {
    RustShaderOutput output;
    ApplyRustShaderMetadataJson(CompleteMetadata().dump(), output);
    ApplyRustShaderReflectionJson(CompleteReflection().dump(), output);

    EXPECT_EQ(output.shader_info.combos.at("HASALPHA"), "1");
    EXPECT_EQ(output.shader_info.alias.at("strength"), "g_Strength");
    ASSERT_EQ(output.shader_info.svs.at("g_Strength").size(), 1u);
    EXPECT_FLOAT_EQ(output.shader_info.svs.at("g_Strength")[0], 0.75f);
    ASSERT_EQ(output.shader_info.defTexs.size(), 1u);
    EXPECT_EQ(output.shader_info.defTexs.at(0).first, 0);
    EXPECT_EQ(output.shader_info.defTexs.at(0).second, "materials/default.png");

    const auto& slots = output.fragment_preprocessor_info.active_tex_slots;
    EXPECT_TRUE(slots.count(2) == 1);
    EXPECT_TRUE(slots.count(0) == 1);
    EXPECT_EQ(slots, (Set<uint> { 0, 2 }));
}

TEST(ShaderBridgeMerge, DefaultUniformKindsDecodeToTheirLaneCounts) {
    const auto decode = [](const json& value) {
        json metadata = { { "default_uniforms", json::array({ { { "name", "u" }, { "value", value } } }) } };
        RustShaderOutput output;
        ApplyRustShaderMetadataJson(metadata.dump(), output);
        return output.shader_info.svs.at("u");
    };

    const auto yes = decode({ { "kind", "bool" }, { "value", true } });
    ASSERT_EQ(yes.size(), 1u);
    EXPECT_FLOAT_EQ(yes[0], 1.0f);
    const auto no = decode({ { "kind", "bool" }, { "value", false } });
    ASSERT_EQ(no.size(), 1u);
    EXPECT_FLOAT_EQ(no[0], 0.0f);

    const auto triple = decode({ { "kind", "vec3" }, { "value", json::array({ 1, 2, 3 }) } });
    ASSERT_EQ(triple.size(), 3u);
    EXPECT_FLOAT_EQ(triple[0], 1.0f);
    EXPECT_FLOAT_EQ(triple[1], 2.0f);
    EXPECT_FLOAT_EQ(triple[2], 3.0f);

    EXPECT_EQ(decode({ { "kind", "vec2" }, { "value", json::array({ 1, 2 }) } }).size(), 2u);
    EXPECT_EQ(decode({ { "kind", "vec4" }, { "value", json::array({ 1, 2, 3, 4 }) } }).size(), 4u);
    json sixteen = json::array();
    for (int i = 0; i < 16; ++i) sixteen.push_back(i);
    EXPECT_EQ(decode({ { "kind", "matrix4" }, { "value", sixteen } }).size(), 16u);
    EXPECT_EQ(decode({ { "kind", "mystery" }, { "value", 1 } }).size(), 0u);
}

TEST(ShaderBridgeMerge, MalformedMetadataChangesNothing) {
    RustShaderOutput output;
    output.shader_info.combos["KEEP"] = "7";
    output.fragment_preprocessor_info.active_tex_slots.insert(5);

    // The first combo is well formed, the second has no value: nothing may be merged.
    json broken = CompleteMetadata();
    broken["combos"] = json::array({ { { "name", "FIRST" }, { "value", "1" } }, { { "name", "SECOND" } } });

    EXPECT_ANY_THROW(ApplyRustShaderMetadataJson(broken.dump(), output));
    EXPECT_EQ(output.shader_info.combos, (Combos { { "KEEP", "7" } }));
    EXPECT_TRUE(output.shader_info.alias.empty());
    EXPECT_TRUE(output.shader_info.svs.empty());
    EXPECT_TRUE(output.shader_info.defTexs.empty());
    EXPECT_EQ(output.fragment_preprocessor_info.active_tex_slots, (Set<uint> { 5 }));
}

TEST(ShaderBridgeMerge, AngleConversionFollowsAliasesAndOldDocumentsDefaultToFalse) {
    RustShaderOutput output;
    json metadata = { { "aliases", json::array({
        { { "material", "angle" }, { "uniform", "g_Angle" }, { "rad2deg", true } },
        { { "material", "plain" }, { "uniform", "g_Plain" } },
    }) } };
    ApplyRustShaderMetadataJson(metadata.dump(), output);
    EXPECT_EQ(output.shader_info.alias_rad2deg, (Set<std::string> { "angle" }));
    metadata["aliases"] = json::array({
        { { "material", "angle" }, { "uniform", "g_Replacement" }, { "rad2deg", true } },
        { { "material", "angle" }, { "uniform", "g_Last" } },
    });
    ApplyRustShaderMetadataJson(metadata.dump(), output);
    EXPECT_EQ(output.shader_info.alias.at("angle"), "g_Last");
    EXPECT_TRUE(output.shader_info.alias_rad2deg.empty());
}

TEST(ShaderBridgeMerge, MalformedAngleConversionDoesNotPartiallyUpdateAliases) {
    RustShaderOutput output;
    output.shader_info.alias["keep"] = "g_Keep";
    output.shader_info.alias_rad2deg.insert("keep");
    const json broken = { { "aliases", json::array({
        { { "material", "first" }, { "uniform", "g_First" }, { "rad2deg", true } },
        { { "material", "broken" }, { "uniform", "g_Broken" }, { "rad2deg", "yes" } },
    }) } };
    EXPECT_ANY_THROW(ApplyRustShaderMetadataJson(broken.dump(), output));
    EXPECT_EQ(output.shader_info.alias, (WPAliasValueDict { { "keep", "g_Keep" } }));
    EXPECT_EQ(output.shader_info.alias_rad2deg, (Set<std::string> { "keep" }));
}

TEST(ShaderBridgeMerge, NonJsonTextThrowsAndReflectionAloneOnlyAddsSlots) {
    RustShaderOutput output;
    EXPECT_ANY_THROW(ApplyRustShaderMetadataJson("this is not json", output));
    EXPECT_ANY_THROW(ApplyRustShaderReflectionJson("this is not json", output));

    ApplyRustShaderReflectionJson(CompleteReflection().dump(), output);
    EXPECT_EQ(output.fragment_preprocessor_info.active_tex_slots, (Set<uint> { 0 }));
    EXPECT_TRUE(output.shader_info.combos.empty());
    EXPECT_TRUE(output.shader_info.alias.empty());
    EXPECT_TRUE(output.shader_info.svs.empty());
    EXPECT_TRUE(output.shader_info.defTexs.empty());
}

// RB-03 / RB-04 -----------------------------------------------------------------------------------

TEST(ShaderBridgeCompile, MinimalProgramYieldsOneMetalStagePerSource) {
    REQUIRE_LINKED_COMPILER();
    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(PlainRequest(), output)) << LastRustShaderError();

    ASSERT_EQ(output.metal_stages.size(), 2u);
    EXPECT_EQ(output.metal_stages[0].kind, ShaderType::VERTEX);
    EXPECT_EQ(output.metal_stages[1].kind, ShaderType::FRAGMENT);
    for (const auto& stage : output.metal_stages) {
        EXPECT_FALSE(stage.source.empty());
        EXPECT_NE(stage.source.find("#include <metal_stdlib>"), std::string::npos);
    }
    EXPECT_FALSE(output.metadata_json.empty());
    EXPECT_FALSE(output.reflection_json.empty());
    EXPECT_TRUE(json::parse(output.metadata_json).is_object());
    EXPECT_TRUE(json::parse(output.reflection_json).is_object());
    EXPECT_FALSE(output.cache_key.empty());
}

TEST(ShaderBridgeCompile, VertexAttributeAppearsInReflection) {
    REQUIRE_LINKED_COMPILER();
    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(PlainRequest(), output)) << LastRustShaderError();
    ASSERT_FALSE(output.reflection_json.empty());

    const auto reflection = json::parse(output.reflection_json);
    const json* input     = FindNamed(reflection.at("vertex_inputs"), "a_Position");
    ASSERT_NE(input, nullptr);
    EXPECT_TRUE(input->at("location").is_number());
    EXPECT_FALSE(input->at("format").get<std::string>().empty());
}

// RB-05 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeCompile, UnsampledTextureProducesNoDescriptors) {
    REQUIRE_LINKED_COMPILER();
    auto request = UncachedPlainRequest();
    SetFragment(request, kOneSampledFragment);
    request.textures.push_back(TextureRecord(1, true, true));

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(request, output)) << LastRustShaderError();
    const auto names = DescriptorNames(output.reflection_json);
    EXPECT_EQ(names.count("g_Texture0"), 1u);
    EXPECT_EQ(names.count("_we_Sampler_g_Texture0"), 1u);
    EXPECT_EQ(names.count("g_Texture1"), 0u);
    EXPECT_EQ(names.count("_we_Sampler_g_Texture1"), 0u);
}

TEST(ShaderBridgeCompile, SampledTexturesGetImageAndSamplerEach) {
    REQUIRE_LINKED_COMPILER();
    auto request = UncachedPlainRequest();
    SetFragment(request, kTwoSamplerFragment);
    request.textures.push_back(TextureRecord(1, true, true));

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(request, output)) << LastRustShaderError();
    const auto names = DescriptorNames(output.reflection_json);
    for (const char* expected : { "g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1" }) {
        EXPECT_EQ(names.count(expected), 1u) << expected;
    }
    EXPECT_EQ(ReflectedSlots(output.reflection_json), (std::set<uint> { 0, 1 }));
    EXPECT_EQ(output.fragment_preprocessor_info.active_tex_slots, (Set<uint> { 0, 1 }));
}

// RB-06 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeCompile, TextureSlotWithoutMaterialKeepsItsComboOff) {
    REQUIRE_LINKED_COMPILER();
    auto request = UncachedPlainRequest();
    SetFragment(request, kComboGatedFragment);
    request.textures.push_back(TextureRecord(1, false, false));

    const auto document = BuildRustShaderRequestJson(request);
    EXPECT_FALSE(document.at("textures")[1].at("present").get<bool>());

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(request, output)) << LastRustShaderError();
    EXPECT_EQ(output.shader_info.combos.at("NORMALMAP"), "0");
    const auto names = DescriptorNames(output.reflection_json);
    EXPECT_EQ(names.count("g_Texture0"), 1u);
    EXPECT_EQ(names.count("g_Texture1"), 0u);
    EXPECT_EQ(names.count("_we_Sampler_g_Texture1"), 0u);
}

TEST(ShaderBridgeCompile, SuppliedTextureSlotTurnsItsComboOn) {
    REQUIRE_LINKED_COMPILER();
    auto request = UncachedPlainRequest();
    SetFragment(request, kComboGatedFragment);
    request.textures.push_back(TextureRecord(1, true, false));

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(request, output)) << LastRustShaderError();
    EXPECT_EQ(output.shader_info.combos.at("NORMALMAP"), "1");
    const auto names = DescriptorNames(output.reflection_json);
    EXPECT_EQ(names.count("g_Texture1"), 1u);
    EXPECT_EQ(names.count("_we_Sampler_g_Texture1"), 1u);
    EXPECT_EQ(output.fragment_preprocessor_info.active_tex_slots, (Set<uint> { 0, 1 }));
}

TEST(ShaderBridgeCompile, MissingTextureRecordCountsAsAbsent) {
    REQUIRE_LINKED_COMPILER();
    auto request = UncachedPlainRequest();
    SetFragment(request, kComboGatedFragment);

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(request, output)) << LastRustShaderError();
    EXPECT_EQ(output.shader_info.combos.at("NORMALMAP"), "0");
    EXPECT_EQ(output.shader_info.combos.at("LIGHTING"), "1");
    EXPECT_EQ(output.fragment_preprocessor_info.active_tex_slots, (Set<uint> { 0 }));
}

// RB-07 -------------------------------------------------------------------------------------------

namespace
{
json PlainDocumentWithVertexInclude(const std::string& include_path) {
    auto document                  = BuildRustShaderRequestJson(PlainRequest());
    document["stages"][0]["source"] = "#include \"" + include_path + "\"\n" + kPlainVertex;
    return document;
}
} // namespace

TEST(ShaderBridgeInclude, ReaderSeesThePathAsWrittenAndMayAnswerEmpty) {
    REQUIRE_LINKED_COMPILER();
    std::vector<std::string> asked;
    const auto reader = [&](std::string_view path) -> std::optional<std::string> {
        asked.emplace_back(path);
        return std::string();
    };

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgramWithBridgeJson(PlainDocumentWithVertexInclude("empty.glsl"), output, reader))
        << LastRustShaderError();
    ASSERT_EQ(asked.size(), 1u);
    EXPECT_EQ(asked[0], "empty.glsl");
    EXPECT_FALSE(output.metadata_json.empty());
}

TEST(ShaderBridgeInclude, UnavailableIncludeFailsTheCompile) {
    REQUIRE_LINKED_COMPILER();
    const auto reader = [](std::string_view) -> std::optional<std::string> { return std::nullopt; };

    RustShaderOutput output;
    EXPECT_FALSE(CompileRustShaderProgramWithBridgeJson(PlainDocumentWithVertexInclude("gone.glsl"), output, reader));
    EXPECT_NE(LastRustShaderError().find("shader include not found"), std::string::npos) << LastRustShaderError();
}

TEST(ShaderBridgeInclude, ServedTextIsUsedByTheStage) {
    REQUIRE_LINKED_COMPILER();
    bool       asked  = false;
    const auto reader = [&](std::string_view path) -> std::optional<std::string> {
        asked = (path == "defs.h");
        return std::string("#define SCALE 0.5\n");
    };
    auto document                  = BuildRustShaderRequestJson(PlainRequest());
    document["stages"][0]["source"] =
        "#include \"defs.h\"\n"
        "attribute vec2 a_Position;\n"
        "void main() { gl_Position = vec4(a_Position * SCALE, 0.0, 1.0); }\n";

    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgramWithBridgeJson(document, output, reader)) << LastRustShaderError();
    EXPECT_TRUE(asked);
}

// RB-08 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeCompile, FailedCompileClearsPreviousOutput) {
    REQUIRE_LINKED_COMPILER();
    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(PlainRequest(), output)) << LastRustShaderError();
    ASSERT_FALSE(output.metadata_json.empty());

    auto empty_stages       = BuildRustShaderRequestJson(PlainRequest());
    empty_stages["stages"] = json::array();
    EXPECT_FALSE(CompileRustShaderProgramWithBridgeJson(empty_stages, output));
    EXPECT_TRUE(output.metadata_json.empty());
    EXPECT_TRUE(output.reflection_json.empty());
    EXPECT_TRUE(output.metal_stages.empty());
    EXPECT_TRUE(output.cache_key.empty());
    EXPECT_TRUE(output.shader_info.combos.empty());
    EXPECT_TRUE(output.fragment_preprocessor_info.active_tex_slots.empty());
}

TEST(ShaderBridgeCompile, UncompilableSourceAlsoClearsPreviousOutput) {
    REQUIRE_LINKED_COMPILER();
    RustShaderOutput output;
    ASSERT_TRUE(CompileRustShaderProgram(PlainRequest(), output)) << LastRustShaderError();
    ASSERT_FALSE(output.metal_stages.empty());

    auto broken                      = BuildRustShaderRequestJson(PlainRequest());
    broken["stages"][1]["source"]    = "void main() { gl_FragColor = vec4(no_such_name); }\n";
    EXPECT_FALSE(CompileRustShaderProgramWithBridgeJson(broken, output));
    EXPECT_TRUE(output.metadata_json.empty());
    EXPECT_TRUE(output.reflection_json.empty());
    EXPECT_TRUE(output.metal_stages.empty());
    EXPECT_TRUE(output.cache_key.empty());
    EXPECT_TRUE(output.shader_info.combos.empty());
    EXPECT_TRUE(output.fragment_preprocessor_info.active_tex_slots.empty());
}

// RB-09 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeParser, CompileMergesIntoShaderInfoAndUnits) {
    REQUIRE_LINKED_COMPILER();
    const auto run = RunAnnotated("parser-merge-scene", "parser_merge", OnePresentTexture());
    ASSERT_TRUE(run.ok) << run.error;

    ASSERT_FALSE(run.reflection.empty());
    const auto reflection = json::parse(run.reflection);
    ASSERT_FALSE(reflection.at("descriptor_bindings").empty());
    const json* image = FindNamed(reflection.at("descriptor_bindings"), "g_Texture0");
    ASSERT_NE(image, nullptr);
    EXPECT_EQ(image->at("descriptor"), "sampled_image");
    const json* sampler = FindNamed(reflection.at("descriptor_bindings"), "_we_Sampler_g_Texture0");
    ASSERT_NE(sampler, nullptr);
    EXPECT_EQ(sampler->at("descriptor"), "sampler");
    EXPECT_FALSE(reflection.at("vertex_inputs").empty());

    ASSERT_EQ(run.info.defTexs.size(), 1u);
    EXPECT_EQ(run.info.defTexs[0].first, 0);
    EXPECT_EQ(run.info.defTexs[0].second, "materials/default.png");
    EXPECT_EQ(run.info.combos.at("HAS_TEXTURE"), "1");
    EXPECT_EQ(run.info.alias.at("albedo"), "g_Texture0");
    EXPECT_EQ(run.info.alias.at("brightness"), "g_Brightness");
    ASSERT_EQ(run.info.svs.at("g_Brightness").size(), 1u);
    EXPECT_FLOAT_EQ(run.info.svs.at("g_Brightness")[0], 1.25f);

    EXPECT_EQ(run.units[1].preprocess_info.active_tex_slots.count(0), 1u);
    EXPECT_TRUE(run.units[0].preprocess_info.active_tex_slots.empty());
    EXPECT_EQ(run.stages.size(), 2u);
}

TEST(ShaderBridgeParser, MaterialConversionFlagsSurviveTheParserMerge) {
    REQUIRE_LINKED_COMPILER();
    const std::string fragment = R"(
uniform float g_Angle; // {"material":"angle","conversion":"rad2deg","default":0}
uniform int g_Count; // {"material":"count","default":1}
uniform uint g_Bits; // {"material":"bits","default":0}
uniform float g_Gain; // {"material":"gain","default":1}
void main() { gl_FragColor = CAST4(g_Angle + float(g_Count) + float(g_Bits) + g_Gain); }
)";
    auto request = UncachedPlainRequest();
    SetFragment(request, fragment);
    RustShaderOutput compiled;
    ASSERT_TRUE(CompileRustShaderProgram(request, compiled)) << LastRustShaderError();
    EXPECT_EQ(compiled.shader_info.alias_rad2deg, (Set<std::string> { "angle" })) << compiled.metadata_json;
    const auto run = RunAnnotated("parser-conversion-flags", "conversion_flags", {}, fragment);
    ASSERT_TRUE(run.ok) << run.error;
    EXPECT_EQ(run.info.alias.at("angle"), "g_Angle");
    EXPECT_EQ(run.info.alias_rad2deg, (Set<std::string> { "angle" }));
}

TEST(ShaderBridgeParser, AbsentTextureTurnsTheComboOffButKeepsTheDefaultTexture) {
    REQUIRE_LINKED_COMPILER();
    WPShaderTexInfo missing;
    missing.present = false;
    missing.enabled = true;

    for (const auto& textures : { std::vector<WPShaderTexInfo> { missing }, std::vector<WPShaderTexInfo> {} }) {
        const auto run = RunAnnotated("parser-absent-scene", "parser_absent", textures);
        ASSERT_TRUE(run.ok) << run.error;
        EXPECT_EQ(run.info.combos.at("HAS_TEXTURE"), "0");
        ASSERT_EQ(run.info.defTexs.size(), 1u);
        EXPECT_EQ(run.info.defTexs[0].second, "materials/default.png");
        EXPECT_EQ(run.units[1].preprocess_info.active_tex_slots.count(0), 1u);
    }
}

TEST(ShaderBridgeParser, MissingShaderInfoFailsTheCall) {
    REQUIRE_LINKED_COMPILER();
    auto                      units    = AnnotatedUnits();
    std::vector<RustShaderMetalStage> stages;
    fs::VFS                   vfs;
    EXPECT_FALSE(WPShaderParser::CompileToMslRust("parser-null-scene", "parser_null", units, stages, vfs, nullptr,
                                                  OnePresentTexture()));
}

// RB-10 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeParser, FailureNamesTheGeneratedFragmentAndTheUnknownIdentifier) {
    REQUIRE_LINKED_COMPILER();
    const std::string broken =
        "varying vec2 v_Uv;\n"
        "uniform sampler2D g_Texture0; // {\"material\":\"albedo\"}\n"
        "void main() {\n"
        "    gl_FragColor = nowhere_declared_value;\n"
        "}\n";
    WPShaderTexInfo texture;
    texture.enabled = true;
    texture.present = false;

    const auto run = RunAnnotated("parser-fail-scene", "parser_fail", { texture }, broken);
    EXPECT_FALSE(run.ok);
    EXPECT_NE(run.error.find("generated/fragment.glsl"), std::string::npos) << run.error;
    EXPECT_NE(run.error.find("nowhere_declared_value"), std::string::npos) << run.error;
    EXPECT_TRUE(run.stages.empty());
    EXPECT_TRUE(run.reflection.empty());
}

// RB-11 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeRequest, OptionalFieldsAppearOnlyWhenSet) {
    auto request          = PlainRequest();
    request.cache_enabled = false;
    EXPECT_EQ(BuildRustShaderRequestJson(request).at("cache_policy"), (json { { "mode", "disabled" } }));
    EXPECT_EQ(BuildRustShaderRequestJson(request).at("target"), "metal_msl");
    EXPECT_EQ(BuildRustShaderRequestJson(request).at("stages")[0].at("kind"), "vertex");

    request.textures.push_back(TextureRecord(1, true, true));
    request.textures.back().video_planes = RustShaderVideoPlanes::Nv12Biplanar;
    const auto textures                  = BuildRustShaderRequestJson(request).at("textures");
    EXPECT_FALSE(textures[0].contains("video_planes"));
    EXPECT_EQ(textures[1].at("video_planes"), "nv12_biplanar");

    request.properties.push_back({ "p", { "number", 0.5 } });
    EXPECT_EQ(BuildRustShaderRequestJson(request).at("properties")[0],
              (json { { "name", "p" }, { "value", { { "kind", "number" }, { "value", 0.5 } } } }));
}

TEST(ShaderBridgeRequest, UnknownStageKindIsRejected) {
    auto request = PlainRequest();
    request.stages.push_back({ static_cast<ShaderType>(99), "void main() {}\n" });
    EXPECT_THROW(BuildRustShaderRequestJson(request), std::runtime_error);
}

// RB-12 -------------------------------------------------------------------------------------------

TEST(ShaderBridgeParser, MetalStagesCarrySourceBindingsAndConventions) {
    REQUIRE_LINKED_COMPILER();
    const auto run = RunAnnotated("parser-metal-scene", "parser_metal", OnePresentTexture());
    ASSERT_TRUE(run.ok) << run.error;

    ASSERT_EQ(run.stages.size(), 2u);
    EXPECT_EQ(run.stages[0].kind, ShaderType::VERTEX);
    EXPECT_EQ(run.stages[1].kind, ShaderType::FRAGMENT);
    EXPECT_EQ(run.stages[0].language_version, "2.0");
    for (const auto& stage : run.stages) {
        EXPECT_NE(stage.source.find("#include <metal_stdlib>"), std::string::npos);
        EXPECT_FALSE(stage.entry_point.empty());
        EXPECT_NE(stage.entry_point, "main");
        EXPECT_NE(stage.source.find(stage.entry_point + "("), std::string::npos);
        EXPECT_FALSE(stage.conventions.clip_space_y_flipped);
        EXPECT_FALSE(stage.conventions.clip_space_depth_remapped);
        EXPECT_FALSE(stage.conventions.texture_origin_flipped);
    }

    const auto& fragment = run.stages[1];
    const auto* texture  = FindBinding(fragment, "g_Texture0");
    const auto* sampler  = FindBinding(fragment, "_we_Sampler_g_Texture0");
    ASSERT_NE(texture, nullptr);
    ASSERT_NE(sampler, nullptr);
    EXPECT_EQ(texture->set, 0u);
    EXPECT_EQ(texture->slot_kind, RustShaderMetalSlotKind::Texture);
    EXPECT_EQ(texture->slot, 0u);
    EXPECT_EQ(sampler->slot_kind, RustShaderMetalSlotKind::Sampler);
    EXPECT_EQ(sampler->slot, 0u);
    EXPECT_NE(texture->binding, sampler->binding);

    EXPECT_FALSE(run.reflection.empty());
    const auto reflection = json::parse(run.reflection);
    EXPECT_FALSE(reflection.at("descriptor_bindings").empty());
    EXPECT_FALSE(reflection.at("vertex_inputs").empty());
    EXPECT_EQ(run.info.alias.at("albedo"), "g_Texture0");
    EXPECT_EQ(run.units[1].preprocess_info.active_tex_slots.count(0), 1u);
}

TEST(ShaderBridgeParser, EachMetalNamespaceNumbersItsOwnSlotsFromZero) {
    REQUIRE_LINKED_COMPILER();
    const auto run = RunAnnotated("parser-slots-scene", "parser_slots", OnePresentTexture());
    ASSERT_TRUE(run.ok) << run.error;
    ASSERT_EQ(run.stages.size(), 2u);

    for (const auto& stage : run.stages) {
        const auto* globals = FindBinding(stage, "GlobalUniforms");
        ASSERT_NE(globals, nullptr);
        EXPECT_EQ(globals->slot_kind, RustShaderMetalSlotKind::Buffer);
        EXPECT_EQ(globals->set, 0u);
        EXPECT_EQ(globals->slot, 0u);
    }
    for (const auto& binding : run.stages[0].bindings) {
        EXPECT_EQ(binding.slot_kind, RustShaderMetalSlotKind::Buffer) << binding.name;
    }
    EXPECT_EQ(FindBinding(run.stages[1], "g_Texture0")->slot, 0u);
    EXPECT_EQ(FindBinding(run.stages[1], "_we_Sampler_g_Texture0")->slot, 0u);
}
