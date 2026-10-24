// Constructs that real wallpaper shaders use and that the shader front end has to
// accept: user functions that share a built-in's name, helpers the dialect provides
// without a declaration, mixed integer/float arguments, and a scalar that receives
// a texture sample through a function-like macro.

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Scene/Parse/WPShaderParser.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "shader_test_scratch.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <set>
#include <string>
#include <vector>

using namespace wallpaper;
using wallpaper::shader_test::CountOccurrences;

namespace
{

struct Outcome {
    bool         ok { false };
    std::string  error;
    std::string  fragment_msl;
    WPShaderInfo info;
    WPShaderUnit fragment_unit;
    std::string  reflection;
};

// Compiles a fixed trivial vertex stage together with the given fragment source,
// with no texture records, and returns what came out of the fragment side.
Outcome CompileFragment(const std::string& fragment_source, const Combos& combos = {}) {
    shader_test::ScratchFolder scratch;
    std::filesystem::create_directories(scratch.sub("assets/shaders"));

    fs::VFS vfs;
    vfs.Mount("/assets", fs::CreatePhysicalFs(scratch.sub("assets").string(), true), "assets");

    std::vector<WPShaderUnit> units(2);
    units[0].stage = ShaderType::VERTEX;
    units[0].src   = "in vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }\n";
    units[1].stage = ShaderType::FRAGMENT;
    units[1].src   = fragment_source;

    Outcome                                  outcome;
    std::vector<shader::RustShaderMetalStage> stages;
    outcome.info.combos = combos;
    outcome.ok = WPShaderParser::CompileToMslRust("dialect-scene", "dialect_case", units, stages, vfs, &outcome.info,
                                                  {}, &outcome.reflection);
    if (! outcome.ok) {
        outcome.error = shader::LastRustShaderError();
        return outcome;
    }
    for (const auto& stage : stages) {
        if (stage.kind == ShaderType::FRAGMENT) outcome.fragment_msl = stage.source;
    }
    outcome.fragment_unit = units[1];
    return outcome;
}

bool Has(const std::string& text, const std::string& needle) { return text.find(needle) != std::string::npos; }

const char* const kUserMod = "float mod(float a, float b) {\n    return a - b * floor(a / b);\n}\n";

std::string WithMain(const std::string& prefix, const std::string& body) {
    return prefix + "void main() {\n" + body + "}\n";
}

} // namespace

// PC-01 -------------------------------------------------------------------------------------------

TEST(ShaderDialectCompat, UserFunctionNamedLikeABuiltinIsTheOneCalled) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(WithMain(kUserMod,
        "    float r = mod(5.0, 2.0);\n"
        "    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);\n"));
    ASSERT_TRUE(result.ok) << result.error;
    EXPECT_TRUE(Has(result.fragment_msl, "mod(5.0, 2.0)")) << result.fragment_msl;
    EXPECT_EQ(CountOccurrences(result.fragment_msl, "float mod("), 1u) << result.fragment_msl;
}

// PC-02 -------------------------------------------------------------------------------------------

TEST(ShaderDialectCompat, UserScalarModDoesNotCaptureTheBuiltinVectorFormWithLiterals) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(WithMain(kUserMod,
        "    float scalar = mod(5.0, 2.0);\n"
        "    vec3 vector = mod(vec3(5.0, 6.0, 7.0), vec3(2.0));\n"
        "    gl_FragColor = vec4(vector.x + scalar, vector.yz, 1.0);\n"));
    ASSERT_TRUE(result.ok) << result.error;
    EXPECT_TRUE(Has(result.fragment_msl, "float3(1.0, 0.0, 1.0)")) << result.fragment_msl;
    EXPECT_EQ(CountOccurrences(result.fragment_msl, "float mod("), 1u);
}

// PC-03 -------------------------------------------------------------------------------------------

TEST(ShaderDialectCompat, UserScalarModDoesNotCaptureTheBuiltinVectorFormWithVariables) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(WithMain(kUserMod,
        "    vec3 a = vec3(5.0, 6.0, 7.0);\n"
        "    vec3 b = vec3(2.0);\n"
        "    float scalar = mod(5.0, 2.0);\n"
        "    vec3 vector = mod(a, b);\n"
        "    gl_FragColor = vec4(vector.x + scalar, vector.yz, 1.0);\n"));
    ASSERT_TRUE(result.ok) << result.error;
    EXPECT_EQ(CountOccurrences(result.fragment_msl, "float mod("), 1u);
    // Only the definition and the one scalar call mention the user's function; the vector
    // form is computed inline instead of being squeezed through it.
    EXPECT_EQ(CountOccurrences(result.fragment_msl, "mod("), 2u) << result.fragment_msl;
}

// PC-04 -------------------------------------------------------------------------------------------

TEST(ShaderDialectCompat, UserModNextToAContinuedFunctionLikeMacro) {
    REQUIRE_LINKED_COMPILER();
    const std::string macro =
        std::string(kUserMod) +
        "#define WRAPPED(a, b) \\\n"
        "    mod(a, b)\n";
    const auto direct = CompileFragment(WithMain(macro,
        "    float r = mod(5.0, 2.0);\n"
        "    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);\n"));
    ASSERT_TRUE(direct.ok) << direct.error;

    const auto used = CompileFragment(WithMain(macro,
        "    float r = WRAPPED(5.0, 2.0);\n"
        "    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);\n"));
    ASSERT_TRUE(used.ok) << used.error;
    EXPECT_TRUE(Has(used.fragment_msl, "mod(5.0, 2.0)")) << used.fragment_msl;
}

// PC-05 -------------------------------------------------------------------------------------------

TEST(ShaderDialectCompat, LightingHelperNeedsNoDeclaration) {
    REQUIRE_LINKED_COMPILER();
    const std::string call =
        "    vec3 lit = PerformLighting_V1(vec3(0.0), vec3(0.8), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0),\n"
        "                                  vec3(1.0), vec3(0.04), 0.5, 0.0);\n"
        "    gl_FragColor = vec4(lit, 1.0);\n";

    const auto undeclared = CompileFragment(WithMain("", call));
    ASSERT_TRUE(undeclared.ok) << undeclared.error;
    EXPECT_TRUE(Has(undeclared.fragment_msl, "PerformLighting_V1_(")) << undeclared.fragment_msl;
    EXPECT_TRUE(Has(undeclared.fragment_msl, "PerformLighting_V1_1(")) << undeclared.fragment_msl;

    const std::string own =
        "vec3 PerformLighting_V1(vec3 p, vec3 a, vec3 n, vec3 v, vec3 s, vec3 r, float rough, float metal) {\n"
        "    return a * rough + metal;\n"
        "}\n";
    const auto declared = CompileFragment(WithMain(own, call));
    ASSERT_TRUE(declared.ok) << declared.error;
    EXPECT_EQ(CountOccurrences(declared.fragment_msl, "PerformLighting_V1_("), 2u) << declared.fragment_msl;
    EXPECT_FALSE(Has(declared.fragment_msl, "PerformLighting_V1_1("));
}

// PC-06 / PC-07 -----------------------------------------------------------------------------------

TEST(ShaderDialectCompat, IntegerOperandsAgainstAVectorAreWidened) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(WithMain("",
        "    vec3 base = vec3(2.0, 3.0, 4.0);\n"
        "    vec3 powered = pow(base, 2);\n"
        "    vec3 bounded = clamp(powered, 0, 8);\n"
        "    gl_FragColor = vec4(bounded / 8.0, 1.0);\n"));
    ASSERT_TRUE(result.ok) << result.error;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::pow(")) << result.fragment_msl;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::clamp(")) << result.fragment_msl;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::float3(2.0)")) << result.fragment_msl;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::float3(8.0)")) << result.fragment_msl;
}

TEST(ShaderDialectCompat, ScalarFirstOperandIsBroadcastAgainstVectors) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(WithMain("",
        "    vec3 exponent = vec3(1.0, 2.0, 3.0);\n"
        "    vec3 powered = pow(2.0, exponent);\n"
        "    vec3 clamped = clamp(0.5, vec3(0.0), vec3(1.0));\n"
        "    gl_FragColor = vec4((powered + clamped) / 9.0, 1.0);\n"));
    ASSERT_TRUE(result.ok) << result.error;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::pow(metal::float3(2.0)")) << result.fragment_msl;
    EXPECT_TRUE(Has(result.fragment_msl, "metal::float3(0.5")) << result.fragment_msl;
}

// PC-08 -------------------------------------------------------------------------------------------

namespace
{
const char* const kSharpenFragment =
    "uniform sampler2D g_Texture0; // {\"hidden\":true}\n"
    "uniform sampler2D g_Texture1; // {\"combo\":\"OPACITY\",\"default\":\"util/white\",\"material\":\"mask\",\"mode\":\"opacitymask\"}\n"
    "uniform float u_strength;\n"
    "uniform float u_radius;\n"
    "uniform vec2 g_TexelSize;\n"
    "varying vec4 v_TexCoord;\n"
    "#define Src(a, b) texSample2D(g_Texture0, fragCoord + vec2(a, b) * g_TexelSize)\n"
    "vec4 sharpen(vec2 fragCoord, float mask) {\n"
    "    vec4 orig = Src(0, 0);\n"
    "    vec4 blur = Src(-u_radius, -u_radius) + 2 * (Src(0, -u_radius) + Src(-u_radius, 0)) + 4 * orig\n"
    "              + 2 * (Src(u_radius, 0) + Src(0, u_radius)) + Src(u_radius, u_radius)\n"
    "              + Src(-u_radius, u_radius) + Src(u_radius, -u_radius);\n"
    "    blur /= 16;\n"
    "    return (1 + u_strength * mask) * orig - u_strength * mask * blur;\n"
    "}\n"
    "void main() {\n"
    "    vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);\n"
    "    float mask = texSample2D(g_Texture1, v_TexCoord.xy);\n"
    "    if (mask > 0.1) {\n"
    "        albedo = sharpen(v_TexCoord.xy, mask);\n"
    "    }\n"
    "    gl_FragColor = albedo;\n"
    "}\n";
}

TEST(ShaderDialectCompat, ScalarReceivesTextureSampleThroughFunctionLikeMacro) {
    REQUIRE_LINKED_COMPILER();
    const auto result = CompileFragment(kSharpenFragment);
    ASSERT_TRUE(result.ok) << result.error;

    EXPECT_EQ(result.info.combos.at("OPACITY"), "0");
    EXPECT_EQ(result.info.alias.at("mask"), "g_Texture1");
    bool found_default = false;
    for (const auto& [slot, path] : result.info.defTexs) {
        if (slot == 1 && path == "util/white") found_default = true;
    }
    EXPECT_TRUE(found_default);
    EXPECT_EQ(result.fragment_unit.preprocess_info.active_tex_slots, (Set<uint> { 0, 1 }));

    std::set<std::string> names;
    const auto reflection = nlohmann::json::parse(result.reflection);
    for (const auto& descriptor : reflection.at("descriptor_bindings")) {
        names.insert(descriptor.at("name").get<std::string>());
    }
    for (const char* expected : { "g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1" }) {
        EXPECT_EQ(names.count(expected), 1u) << expected << " in " << result.reflection;
    }

    const auto sampled = result.fragment_msl.find("g_Texture1_.sample(");
    ASSERT_NE(sampled, std::string::npos) << result.fragment_msl;
    EXPECT_NE(result.fragment_msl.find(".x;", sampled), std::string::npos) << result.fragment_msl;
}
