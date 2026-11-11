// The program cache behind WPShaderParser::CompileToMslRust: what a hit gives back,
// what the stored entry looks like, when an entry stops being valid, and how a
// damaged entry is recovered from.

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Scene/Parse/WPShaderParser.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "shader_test_scratch.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>
#include <vector>

using namespace wallpaper;
namespace stdfs = std::filesystem;
using wallpaper::shader_test::ReadFile;
using wallpaper::shader_test::WriteFile;

namespace
{

const char* const kVertex =
    "in vec3 a_Position;\n"
    "out vec2 v_TexCoord;\n"
    "void main() {\n"
    "    v_TexCoord = a_Position.xy;\n"
    "    gl_Position = vec4(a_Position, 1.0);\n"
    "}\n";

const char* const kFragment =
    "in vec2 v_TexCoord;\n"
    "uniform sampler2D g_Texture0;\n"
    "void main() {\n"
    "    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);\n"
    "}\n";

const char* const kAnnotatedFragment =
    "in vec2 v_TexCoord;\n"
    "uniform sampler2D g_Texture0; // {\"material\":\"albedo\",\"combo\":\"HAS_TEXTURE\",\"default\":\"materials/default.png\"}\n"
    "uniform float g_Brightness; // {\"material\":\"brightness\",\"default\":1.25}\n"
    "void main() {\n"
    "    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Brightness;\n"
    "}\n";

struct Job {
    std::string                  scene { "scene-a" };
    std::string                  name { "shader_a" };
    std::string                  fragment { kFragment };
    std::vector<WPShaderTexInfo> textures { [] {
        WPShaderTexInfo texture;
        texture.enabled = true;
        return std::vector<WPShaderTexInfo> { texture };
    }() };
    Combos                       combos;
};

struct Result {
    bool                      ok { false };
    std::string               error;
    std::string               reflection;
    std::vector<WPShaderUnit> units;
    WPShaderInfo              info;
};

std::size_t EntryCount(const stdfs::path& folder) {
    return static_cast<std::size_t>(std::distance(stdfs::directory_iterator(folder), stdfs::directory_iterator()));
}

std::vector<stdfs::path> FilesIn(const stdfs::path& folder) {
    std::vector<stdfs::path> files;
    for (const auto& entry : stdfs::directory_iterator(folder)) files.push_back(entry.path());
    std::sort(files.begin(), files.end());
    return files;
}

// A scratch area with `cache/` and `assets/` folders, a file system that has them
// mounted (the cache only when asked) and the counters of the thread running the test.
class CacheRig {
public:
    explicit CacheRig(bool cache_mounted = true) {
        stdfs::create_directories(m_scratch.sub("cache"));
        stdfs::create_directories(m_scratch.sub("assets/shaders"));
        if (cache_mounted) m_vfs.Mount("/cache", fs::CreatePhysicalFs(cache().string(), true), "cache");
        m_vfs.Mount("/assets", fs::CreatePhysicalFs(m_scratch.sub("assets").string(), true), "assets");
        WPShaderParser::ClearProgramCache();
        WPShaderParser::ResetStartupMetrics();
    }

    stdfs::path cache() const { return m_scratch.sub("cache"); }
    stdfs::path include_file(const std::string& name) const { return m_scratch.sub("assets/shaders/" + name); }
    stdfs::path programs(const std::string& scene) const { return cache() / scene / "programs01"; }

    Result Compile(const Job& job) {
        Result result;
        result.units.resize(2);
        result.units[0].stage = ShaderType::VERTEX;
        result.units[0].src   = kVertex;
        result.units[1].stage = ShaderType::FRAGMENT;
        result.units[1].src   = job.fragment;
        result.info.combos    = job.combos;
        std::vector<shader::RustShaderMetalStage> stages;
        result.ok = WPShaderParser::CompileToMslRust(job.scene, job.name, result.units, stages, m_vfs, &result.info,
                                                     job.textures, &result.reflection);
        if (! result.ok) result.error = shader::LastRustShaderError();
        return result;
    }

    uint64_t hits() const { return WPShaderParser::GetStartupMetrics().cache_hits; }
    uint64_t misses() const { return WPShaderParser::GetStartupMetrics().cache_misses; }

private:
    shader_test::ScratchFolder m_scratch;
    fs::VFS                    m_vfs;
};

void ExpectUsable(const Result& result) {
    EXPECT_TRUE(result.ok) << result.error;
    EXPECT_FALSE(result.reflection.empty());
    EXPECT_EQ(result.units[1].preprocess_info.active_tex_slots.count(0), 1u);
}

bool IsProgramFileName(const std::string& name) {
    if (name.size() != 40 + 5 || name.substr(40) != ".json") return false;
    return std::all_of(name.begin(), name.begin() + 40, [](unsigned char c) { return std::isxdigit(c) != 0; });
}

} // namespace

// SC-01 -------------------------------------------------------------------------------------------

TEST(ShaderProgramCache, FirstCompileWritesOneProgramFileAndReportsTheSlot) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    const auto result = rig.Compile(Job {});
    ExpectUsable(result);
    EXPECT_TRUE(result.units[0].preprocess_info.active_tex_slots.empty());

    EXPECT_TRUE(stdfs::is_directory(rig.programs("scene-a")));
    EXPECT_EQ(EntryCount(rig.cache() / "scene-a"), 1u);
    EXPECT_EQ(rig.misses(), 1u);
    EXPECT_EQ(rig.hits(), 0u);

    const auto files = FilesIn(rig.programs("scene-a"));
    ASSERT_EQ(files.size(), 1u);
    EXPECT_TRUE(IsProgramFileName(files[0].filename().string())) << files[0];
    EXPECT_TRUE(nlohmann::json::parse(ReadFile(files[0])).is_object());
}

TEST(ShaderProgramCache, WithoutACacheMountNothingIsWrittenAndEveryCompileIsAMiss) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig(false);
    ExpectUsable(rig.Compile(Job {}));
    ExpectUsable(rig.Compile(Job {}));

    EXPECT_EQ(EntryCount(rig.cache()), 0u);
    EXPECT_EQ(rig.hits(), 0u);
    EXPECT_EQ(rig.misses(), 2u);
}

// SC-02 -------------------------------------------------------------------------------------------

TEST(ShaderProgramCache, RepeatInTheSameProcessIsServedFromMemory) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    const auto first = rig.Compile(Job {});
    ASSERT_TRUE(first.ok) << first.error;

    const auto again = rig.Compile(Job {});
    ExpectUsable(again);
    EXPECT_EQ(rig.hits(), 1u);
    EXPECT_EQ(rig.misses(), 1u);
    EXPECT_EQ(again.reflection, first.reflection);
}

TEST(ShaderProgramCache, HitFromDiskRestoresReflectionAndSlots) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    const auto first = rig.Compile(Job {});
    ASSERT_TRUE(first.ok) << first.error;

    WPShaderParser::ClearProgramCache();
    const auto hits_before = rig.hits();
    const auto restored    = rig.Compile(Job {});
    ExpectUsable(restored);
    EXPECT_EQ(rig.hits(), hits_before + 1);
    EXPECT_EQ(rig.misses(), 1u);
    EXPECT_EQ(restored.reflection, first.reflection);
    EXPECT_TRUE(restored.units[0].preprocess_info.active_tex_slots.empty());
}

TEST(ShaderProgramCache, HitFromDiskRestoresMetadataLikeTheMissDid) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    Job      job;
    job.fragment = kAnnotatedFragment;
    job.textures[0].present = true;

    const auto compiled = rig.Compile(job);
    ASSERT_TRUE(compiled.ok) << compiled.error;
    WPShaderParser::ClearProgramCache();
    const auto restored = rig.Compile(job);
    ASSERT_TRUE(restored.ok) << restored.error;
    ASSERT_EQ(rig.hits(), 1u);

    for (const auto* result : { &compiled, &restored }) {
        EXPECT_EQ(result->info.combos.at("HAS_TEXTURE"), "1");
        EXPECT_EQ(result->info.alias.at("albedo"), "g_Texture0");
        EXPECT_EQ(result->info.alias.at("brightness"), "g_Brightness");
        ASSERT_EQ(result->info.defTexs.size(), 1u);
        EXPECT_EQ(result->info.defTexs[0].first, 0);
        EXPECT_EQ(result->info.defTexs[0].second, "materials/default.png");
        EXPECT_EQ(result->info.svs.count("g_Brightness"), 1u);
        EXPECT_EQ(result->units[1].preprocess_info.active_tex_slots, (Set<uint> { 0 }));
        EXPECT_TRUE(result->units[0].preprocess_info.active_tex_slots.empty());
    }
}

// SC-03 -------------------------------------------------------------------------------------------

namespace
{
Job IncludingJob() {
    Job job;
    job.name     = "shader_include";
    job.fragment = std::string("#include \"tint.h\"\n") + kFragment;
    return job;
}
} // namespace

TEST(ShaderProgramCache, EditingAnIncludeInvalidatesTheStoredProgram) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    WriteFile(rig.include_file("tint.h"), "// first revision of the include\n");

    ExpectUsable(rig.Compile(IncludingJob()));
    const auto after_first = rig.misses();
    EXPECT_EQ(after_first, 1u);

    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.misses(), after_first);

    WriteFile(rig.include_file("tint.h"), "// a different comment in the include\n");
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.misses(), after_first + 1);

    // The entry was rewritten with the new text, so the next compile is served.
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.misses(), after_first + 1);
}

TEST(ShaderProgramCache, IncludeTextIsComparedForDiskEntriesToo) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    WriteFile(rig.include_file("tint.h"), "// stored revision\n");
    ASSERT_TRUE(rig.Compile(IncludingJob()).ok);

    WPShaderParser::ClearProgramCache();
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.hits(), 1u);
    EXPECT_EQ(rig.misses(), 1u);

    WPShaderParser::ClearProgramCache();
    WriteFile(rig.include_file("tint.h"), "// edited after the entry was written\n");
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.hits(), 1u);
    EXPECT_EQ(rig.misses(), 2u);
}

TEST(ShaderProgramCache, MissingIncludeFailsWithoutLeavingAnEntryBehind) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    Job      job;
    job.scene    = "scene-missing";
    job.fragment = std::string("#include \"later.h\"\n") + kFragment;

    const auto failed = rig.Compile(job);
    EXPECT_FALSE(failed.ok);
    EXPECT_NE(failed.error.find("shader include not found"), std::string::npos) << failed.error;
    EXPECT_FALSE(stdfs::exists(rig.cache() / "scene-missing"));

    WriteFile(rig.include_file("later.h"), "// now present\n");
    ExpectUsable(rig.Compile(job));
}

// SC-04 -------------------------------------------------------------------------------------------

namespace
{
void OverwriteAll(const stdfs::path& folder, const std::string& text) {
    for (const auto& file : FilesIn(folder)) WriteFile(file, text);
}
} // namespace

TEST(ShaderProgramCache, TruncatedEntryIsRecompiledAndRepublished) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    WriteFile(rig.include_file("tint.h"), "// stable\n");
    ASSERT_TRUE(rig.Compile(IncludingJob()).ok);
    Job sibling = IncludingJob();
    sibling.combos["VARIANT"] = "2";
    ASSERT_TRUE(rig.Compile(sibling).ok);
    ASSERT_EQ(rig.misses(), 2u);
    ASSERT_EQ(FilesIn(rig.programs("scene-a")).size(), 2u);

    WPShaderParser::ClearProgramCache();
    OverwriteAll(rig.programs("scene-a"), "{");
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.misses(), 3u);

    WPShaderParser::ClearProgramCache();
    ExpectUsable(rig.Compile(IncludingJob()));
    EXPECT_EQ(rig.hits(), 1u);
    EXPECT_EQ(rig.misses(), 3u);
}

TEST(ShaderProgramCache, WrongShapeAndEmptyAndHalfWrittenEntriesAreMisses) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    ASSERT_TRUE(rig.Compile(Job {}).ok);
    const auto original = ReadFile(FilesIn(rig.programs("scene-a")).front());
    ASSERT_GT(original.size(), 8u);

    uint64_t expected_misses = rig.misses();
    for (const std::string& damaged : { std::string("[]"), std::string(), std::string("{\"request\":\"x\"}"),
                                        original.substr(0, original.size() / 2) }) {
        WPShaderParser::ClearProgramCache();
        OverwriteAll(rig.programs("scene-a"), damaged);
        ExpectUsable(rig.Compile(Job {}));
        EXPECT_EQ(rig.misses(), ++expected_misses) << "entry was: " << damaged.substr(0, 20);
    }
    // The last recovery rewrote a whole entry.
    WPShaderParser::ClearProgramCache();
    ExpectUsable(rig.Compile(Job {}));
    EXPECT_EQ(rig.misses(), expected_misses);
}

// SC-05 -------------------------------------------------------------------------------------------

namespace
{
// Compiling `variant` after `base` is a miss; compiling it again from disk is a hit, and
// the base program is still served from its own entry afterwards.
void ExpectSeparateEntry(CacheRig& rig, const Job& base, const Job& variant) {
    const auto misses = rig.misses();
    ASSERT_TRUE(rig.Compile(variant).ok);
    EXPECT_EQ(rig.misses(), misses + 1);

    WPShaderParser::ClearProgramCache();
    const auto hits = rig.hits();
    ASSERT_TRUE(rig.Compile(variant).ok);
    EXPECT_EQ(rig.hits(), hits + 1);
    EXPECT_EQ(rig.misses(), misses + 1);

    WPShaderParser::ClearProgramCache();
    ASSERT_TRUE(rig.Compile(base).ok);
    EXPECT_EQ(rig.hits(), hits + 2);
    EXPECT_EQ(rig.misses(), misses + 1);
}
} // namespace

TEST(ShaderProgramCache, AnotherSceneGetsItsOwnFolder) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    ASSERT_TRUE(rig.Compile(Job {}).ok);
    const auto base_files = FilesIn(rig.programs("scene-a"));
    ASSERT_EQ(base_files.size(), 1u);
    const auto base_text = ReadFile(base_files[0]);

    Job other;
    other.scene = "scene-b";
    ExpectSeparateEntry(rig, Job {}, other);
    EXPECT_TRUE(stdfs::is_directory(rig.programs("scene-b")));
    EXPECT_EQ(FilesIn(rig.programs("scene-a")), base_files);
    EXPECT_EQ(ReadFile(base_files[0]), base_text);
}

TEST(ShaderProgramCache, TexturePresenceIsPartOfTheKey) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    Job      absent;
    absent.fragment            = kAnnotatedFragment;
    absent.textures[0].present = false;
    ASSERT_TRUE(rig.Compile(absent).ok);

    Job present = absent;
    present.textures[0].present = true;
    ExpectSeparateEntry(rig, absent, present);
    EXPECT_EQ(FilesIn(rig.programs("scene-a")).size(), 2u);
}

TEST(ShaderProgramCache, CombosAreAPartOfTheKey) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    ASSERT_TRUE(rig.Compile(Job {}).ok);

    Job with_combo;
    with_combo.combos["EXTRA_CHOICE"] = "1";
    ExpectSeparateEntry(rig, Job {}, with_combo);
    EXPECT_EQ(FilesIn(rig.programs("scene-a")).size(), 2u);
}

TEST(ShaderProgramCache, SourceTextIsAPartOfTheKey) {
    REQUIRE_LINKED_COMPILER();
    CacheRig rig;
    ASSERT_TRUE(rig.Compile(Job {}).ok);

    Job edited;
    edited.fragment += "\n";
    ExpectSeparateEntry(rig, Job {}, edited);
    EXPECT_EQ(FilesIn(rig.programs("scene-a")).size(), 2u);
}
