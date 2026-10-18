#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "WPShaderParser.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace
{

std::filesystem::path MakeTempDir() {
    // Per process: concurrent runs share the temporary directory, and this
    // folder is deleted before and after use.
    auto root = std::filesystem::temp_directory_path() /
                ("wpe-shader-cache-metadata-test-" + std::to_string(::getpid()));
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::filesystem::create_directories(root / "cache", ec);
    std::filesystem::create_directories(root / "assets", ec);
    return root;
}

std::array<WPShaderUnit, 2> MakeShaderUnits() {
    return {
        WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = R"(
in vec3 a_Position;
out vec2 v_TexCoord;
void main() {
    v_TexCoord = vec2(0.5, 0.5);
    gl_Position = vec4(a_Position, 1.0);
}
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = R"(
in vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)",
            .preprocess_info = {},
        },
    };
}

uint32_t ReadU32LE(const std::string& bytes, size_t offset) {
    return static_cast<uint32_t>(static_cast<unsigned char>(bytes.at(offset))) |
           (static_cast<uint32_t>(static_cast<unsigned char>(bytes.at(offset + 1))) << 8u) |
           (static_cast<uint32_t>(static_cast<unsigned char>(bytes.at(offset + 2))) << 16u) |
           (static_cast<uint32_t>(static_cast<unsigned char>(bytes.at(offset + 3))) << 24u);
}

void ExpectCacheBodyMatchesCodes(const std::string& cache_body,
                                 const std::vector<ShaderCode>& codes) {
    ASSERT_GE(cache_body.size(), 9u + 4u + 256u);
    EXPECT_EQ(cache_body.substr(0, 8), "SPVS0001");
    EXPECT_EQ(static_cast<unsigned char>(cache_body.at(8)), 0u);

    size_t offset = 9;
    ASSERT_GE(cache_body.size() - offset, sizeof(uint32_t));
    ASSERT_EQ(ReadU32LE(cache_body, offset), codes.size());
    offset += sizeof(uint32_t);

    for (size_t i = 0; i < codes.size(); ++i) {
        ASSERT_GE(cache_body.size() - offset, sizeof(uint32_t));
        const auto size_bytes = ReadU32LE(cache_body, offset);
        offset += sizeof(uint32_t);

        ASSERT_LE(codes[i].size(),
                  std::numeric_limits<uint32_t>::max() / sizeof(uint32_t));
        ASSERT_EQ(size_bytes, codes[i].size() * sizeof(uint32_t));
        ASSERT_GE(cache_body.size() - offset, size_bytes);
        ASSERT_GE(size_bytes, sizeof(uint32_t));
        EXPECT_EQ(ReadU32LE(cache_body, offset), 0x07230203u);

        const auto payload = std::string_view(cache_body).substr(offset, size_bytes);
        const auto expected =
            std::string_view(reinterpret_cast<const char*>(codes[i].data()), size_bytes);
        EXPECT_EQ(payload, expected);
        offset += size_bytes;
    }

    ASSERT_EQ(cache_body.size() - offset, 256u);
    for (; offset < cache_body.size(); ++offset) {
        EXPECT_EQ(static_cast<unsigned char>(cache_body.at(offset)), 0u);
    }
}

TEST(ShaderCacheMetadataTest, CacheHitStillPopulatesActiveTextureSlots) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    const auto temp = MakeTempDir();
    struct RemoveOnExit {
        std::filesystem::path path;
        ~RemoveOnExit() {
            std::error_code ec;
            std::filesystem::remove_all(path, ec);
        }
    } remove_on_exit { temp };
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();

    fs::VFS vfs;
    ASSERT_TRUE(
        vfs.Mount("/cache", fs::CreatePhysicalFs((temp / "cache").string(), true), "cache"));
    ASSERT_TRUE(
        vfs.Mount("/assets", fs::CreatePhysicalFs((temp / "assets").string(), true), "assets"));

    std::vector<WPShaderTexInfo> textures { WPShaderTexInfo { .enabled = true } };

    {
        WPShaderInfo            info;
        auto                    units = MakeShaderUnits();
        std::vector<ShaderCode> codes;
        ASSERT_TRUE(WPShaderParser::CompileToSpvRust(
            "demo-scene", "tests/cache-metadata", units, codes, vfs, &info, textures))
            << shader::LastRustShaderError();
        ASSERT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
        const auto cache_root = temp / "cache" / "demo-scene" / "spvs01";
        ASSERT_TRUE(std::filesystem::is_directory(cache_root));

        std::vector<std::filesystem::path> cache_files;
        for (const auto& entry : std::filesystem::directory_iterator(cache_root)) {
            if (entry.path().extension() == ".spvs") {
                cache_files.push_back(entry.path());
            }
        }
        ASSERT_EQ(cache_files.size(), 1u);

        const auto cache_body = fs::CreateCBinaryStream(cache_files.front().string())->ReadAllStr();
        ExpectCacheBodyMatchesCodes(cache_body, codes);
        EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, 1u);
    }

    // A disk hit, not just a same-process hit, must restore reflection as well.
    WPShaderParser::ClearProgramCache();
    {
        WPShaderInfo            info;
        auto                    units = MakeShaderUnits();
        std::vector<ShaderCode> codes;
        ASSERT_TRUE(WPShaderParser::CompileToSpvRust(
            "demo-scene", "tests/cache-metadata", units, codes, vfs, &info, textures))
            << shader::LastRustShaderError();
        ASSERT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
        EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_hits, 1u);
    }

    auto compile = [&] {
        WPShaderInfo info;
        auto units = MakeShaderUnits();
        units[1].src = "#include \"tint.h\"\n" + units[1].src;
        std::vector<ShaderCode> codes;
        std::string reflection;
        EXPECT_TRUE(WPShaderParser::CompileToSpvRust(
            "demo-scene", "tests/cache-includes", units, codes, vfs, &info, textures, &reflection));
        EXPECT_FALSE(reflection.empty());
        EXPECT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
    };
    std::filesystem::create_directories(temp / "assets/shaders");
    std::ofstream(temp / "assets/shaders/tint.h") << "// first include\n";
    compile();
    auto misses = WPShaderParser::GetStartupMetrics().cache_misses;
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, misses);
    std::ofstream(temp / "assets/shaders/tint.h") << "// changed include\n";
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, ++misses);

    // A truncated persisted entry must trigger recompilation, not break loading.
    WPShaderParser::ClearProgramCache();
    for (const auto& entry : std::filesystem::directory_iterator(temp / "cache/demo-scene/programs01")) {
        std::ofstream(entry.path()) << "{";
    }
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, ++misses);
#endif
}

} // namespace
} // namespace wallpaper
