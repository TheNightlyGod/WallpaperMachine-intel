#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "WPShaderParser.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace wallpaper
{
namespace
{

// Removes a MakeTempDir folder when the test is done with it, so repeated runs
// do not leave one folder per test in the shared temporary directory.
struct RemoveOnExit {
    std::filesystem::path path;
    ~RemoveOnExit() {
        std::error_code ec;
        std::filesystem::remove_all(path, ec);
    }
};

std::filesystem::path MakeTempDir() {
    const auto* test_info = ::testing::UnitTest::GetInstance()->current_test_info();
    std::string test_name = "unknown";
    if (test_info != nullptr) {
        test_name = std::string(test_info->test_suite_name()) + "-" + test_info->name();
    }
    for (char& ch : test_name) {
        if (! std::isalnum(static_cast<unsigned char>(ch))) {
            ch = '-';
        }
    }

    auto root = std::filesystem::temp_directory_path() /
                ("wpe-shader-preprocessor-compat-test-" + std::to_string(getpid()) + "-" + test_name);
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::filesystem::create_directories(root / "assets" / "shaders", ec);
    return root;
}

void MountAssets(fs::VFS& vfs, const std::filesystem::path& root) {
    EXPECT_TRUE(vfs.Mount("/assets", fs::CreatePhysicalFs((root / "assets").string(), true), "assets"));
}

void WriteText(const std::filesystem::path& path, std::string_view text) {
    std::ofstream out(path);
    out << text;
}

bool CompileFragmentShader(std::string fragment_source, Combos combos = {}) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    (void)fragment_source;
    (void)combos;
    return false;
#else
    const auto temp = MakeTempDir();
    RemoveOnExit remove_on_exit { temp };
    fs::VFS    vfs;
    MountAssets(vfs, temp);

    WPShaderInfo info;
    info.combos = std::move(combos);
    std::vector<WPShaderTexInfo> textures;
    std::array units {
        WPShaderUnit {
            .stage = ShaderType::VERTEX,
            .src = R"(
in vec3 a_Position;
void main() {
    gl_Position = vec4(a_Position, 1.0);
}
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage = ShaderType::FRAGMENT,
            .src = std::move(fragment_source),
            .preprocess_info = {},
        },
    };

    std::vector<ShaderCode> codes;
    return WPShaderParser::CompileToSpvRust("compat-fragment",
                                            "tests/compat-fragment",
                                            units,
                                            codes,
                                            vfs,
                                            &info,
                                            textures);
#endif
}

TEST(RustShaderBridgeCompat, IdentifierNamedSampleCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    float sample = 0.25;
    gl_FragColor = vec4(sample, sample, sample, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, ScalarFileScopeConstCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
const float kAlpha = 0.75;
void main() {
    gl_FragColor = vec4(kAlpha, 0.0, 0.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, UserDefinedModDoesNotCreateDuplicateDefinition) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
float mod(float a, float b) {
    return a - b * floor(a / b);
}
void main() {
    gl_FragColor = vec4(mod(5.0, 2.0), 0.0, 0.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, UserDefinedScalarModPreservesBuiltinVectorMod) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
float mod(float a, float b) {
    return a - b * floor(a / b);
}
void main() {
    float scalar = mod(5.0, 2.0);
    vec3 vector = mod(vec3(5.0, 6.0, 7.0), vec3(2.0));
    gl_FragColor = vec4(vector.x + scalar, vector.yz, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, UserDefinedScalarModPreservesVectorVariableBuiltinMod) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
float mod(float a, float b) {
    return a - b * floor(a / b);
}
void main() {
    float scalar = mod(5.0, 2.0);
    vec3 a = vec3(5.0, 6.0, 7.0);
    vec3 b = vec3(2.0);
    vec3 vector = mod(a, b);
    gl_FragColor = vec4(vector.x + scalar, vector.yz, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, UserDefinedScalarModPreservesMultilineMacroBody) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
float mod(float a, float b) {
    return a - b * floor(a / b);
}
#define MOD_THROUGH_MACRO(a, b) \
    mod(a, b)
void main() {
    float scalar = mod(5.0, 2.0);
    gl_FragColor = vec4(scalar, 0.0, 0.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, ExtraStrayEndifIsTolerated) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
#endif
void main() {
    gl_FragColor = vec4(1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, InPlaceIncludeOrderingPreservesMacroVisibility) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    const auto temp = MakeTempDir();
    RemoveOnExit remove_on_exit { temp };
    WriteText(temp / "assets" / "shaders" / "compat_defs.h", "#define INCLUDED_TINT vec4(0.2, 0.4, 0.6, 1.0)\n");
    fs::VFS vfs;
    MountAssets(vfs, temp);

    WPShaderInfo info;
    std::vector<WPShaderTexInfo> textures;
    std::array units {
        WPShaderUnit {
            .stage = ShaderType::VERTEX,
            .src = R"(
in vec3 a_Position;
void main() {
    gl_Position = vec4(a_Position, 1.0);
}
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage = ShaderType::FRAGMENT,
            .src = R"(
#include "compat_defs.h"
void main() {
    gl_FragColor = INCLUDED_TINT;
}
)",
            .preprocess_info = {},
        },
    };

    std::vector<ShaderCode> codes;
    EXPECT_TRUE(WPShaderParser::CompileToSpvRust(
        "compat-include", "tests/compat-include", units, codes, vfs, &info, textures))
        << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, PerformLightingV1StubCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    vec3 lit = PerformLighting_V1(vec3(0.0), vec3(0.8), vec3(0.0, 0.0, 1.0),
                                  vec3(0.0, 0.0, 1.0), vec3(1.0), vec3(0.04), 0.5, 0.0);
    gl_FragColor = vec4(lit, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, ClipIntrinsicCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    clip(1.0);
    gl_FragColor = vec4(1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, Log10IntrinsicCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    float v = log10(100.0);
    gl_FragColor = vec4(v, 0.0, 0.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, MixedIntVectorPowAndClampCompile) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    vec3 base = vec3(2.0, 3.0, 4.0);
    vec3 powered = pow(base, 2);
    vec3 clamped = clamp(powered, 0, 8);
    gl_FragColor = vec4(clamped / 8.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, MixedScalarVectorPowAndClampCompile) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    vec3 exponent = vec3(1.0, 2.0, 3.0);
    vec3 powered = pow(2.0, exponent);
    vec3 clamped = clamp(0.5, vec3(0.0), vec3(1.0));
    gl_FragColor = vec4((powered + clamped) / 9.0, 1.0);
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, ScalarTextureSampleMaskCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"combo":"OPACITY","default":"util/white","material":"mask","mode":"opacitymask"}
uniform float u_strength;
uniform float u_radius;
uniform vec2 g_TexelSize;

varying vec4 v_TexCoord;

#define Src(a,b) texSample2D(g_Texture0, fragCoord + vec2(a,b) * g_TexelSize)

vec4 sharpen(vec2 fragCoord, float mask) {
    vec4 orig = Src(0, 0);
    vec4 c1 = Src(-u_radius, -u_radius);
    vec4 c2 = Src(0, -u_radius);
    vec4 c3 = Src(u_radius,-u_radius);
    vec4 c4 = Src(-u_radius, 0);
    vec4 c5 = Src(u_radius, 0);
    vec4 c6 = Src(-u_radius, u_radius);
    vec4 c7 = Src(0, u_radius);
    vec4 c8 = Src(u_radius, u_radius);
    vec4 blur = (c1 + c3 + c6 + c8 + 2 * (c2 + c4 + c5 + c7) + 4 * orig)/16;
    vec4 corr = (1 + u_strength * mask) * orig - u_strength * mask * blur;
    return corr;
}

void main() {
    vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    float mask = texSample2D(g_Texture1, v_TexCoord.xy);
    if (mask > 0.1) albedo = sharpen(v_TexCoord.xy, mask);
    gl_FragColor = albedo;
}
)")) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, NumericComboMacroTernaryConditionCompiles) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    EXPECT_TRUE(CompileFragmentShader(R"(
void main() {
    float mask = 0.5;
    mask = INVERT ? 1.0 - mask : mask;
    gl_FragColor = vec4(mask, 0.0, 0.0, 1.0);
}
)", Combos { { "INVERT", "0" } })) << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, MacroAliasedSvPositionIsNotCrossStageIo) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    fs::VFS vfs;

    WPShaderInfo info;
    std::vector<WPShaderTexInfo> textures;
    std::array units {
        WPShaderUnit {
            .stage = ShaderType::VERTEX,
            .src = R"(
#define gl_Position _ww_sv_position
out vec2 v_TexCoord;
out vec4 _ww_sv_position;
void main() {
    v_TexCoord = vec2(0.25, 0.75);
    _ww_sv_position = vec4(0.0, 0.0, 0.0, 1.0);
#undef gl_Position
    gl_Position = _ww_sv_position;
}
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage = ShaderType::FRAGMENT,
            .src = R"(
in vec2 v_TexCoord;
void main() {
    gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
}
)",
            .preprocess_info = {},
        },
    };

    std::vector<ShaderCode> codes;
    EXPECT_TRUE(WPShaderParser::CompileToSpvRust(
        "compat-macro-sv-position", "tests/macro-sv-position", units, codes, vfs, &info, textures))
        << shader::LastRustShaderError();
#endif
}

TEST(RustShaderBridgeCompat, GenericRopeParticleGeometrySourceDiscoveryRemainsDisabled) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    const auto temp = MakeTempDir();
    RemoveOnExit remove_on_exit { temp };
    WriteText(temp / "assets" / "shaders" / "genericropeparticle.vert", R"(
in vec3 a_Position;
varying vec2 v_TexCoord;
void main() {
    v_TexCoord = a_Position.xy;
    gl_Position = vec4(a_Position, 1.0);
}
)");
    WriteText(temp / "assets" / "shaders" / "genericropeparticle.frag", R"(
varying vec2 v_TexCoord;
void main() {
    gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
}
)");
    WriteText(temp / "assets" / "shaders" / "genericropeparticle.geom", "#error geometry must remain undiscovered\n");

    fs::VFS vfs;
    MountAssets(vfs, temp);
    EXPECT_FALSE(fs::GetFileContent(vfs, "/assets/shaders/genericropeparticle.geom").empty());

    WPShaderInfo info;
    std::vector<WPShaderTexInfo> textures;
    std::array units {
        WPShaderUnit {
            .stage = ShaderType::VERTEX,
            .src = R"(
#include "genericropeparticle.vert"
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage = ShaderType::FRAGMENT,
            .src = R"(
#include "genericropeparticle.frag"
)",
            .preprocess_info = {},
        },
    };

    std::vector<ShaderCode> codes;
    EXPECT_TRUE(WPShaderParser::CompileToSpvRust(
        "compat-geometry", "tests/genericropeparticle", units, codes, vfs, &info, textures))
        << shader::LastRustShaderError();
#endif
}

} // namespace
} // namespace wallpaper
