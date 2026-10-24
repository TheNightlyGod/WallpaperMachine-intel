// On-request sweep: every shader-bearing material of every scene in a folder of
// unpacked workshop packages is compiled under the combos the scene chooses.
//
// Disabled by default because it needs a local corpus and takes minutes. Run it with
//   shader_corpus_test --gtest_also_run_disabled_tests --gtest_filter='*ParsesCorpus*'
// after pointing WALLPAPER_MACHINE_UNPACK_ROOT at a folder of <id>/scene.json and, when
// the shipped assets are not in the Steam default, WALLPAPER_MACHINE_ASSETS_ROOT.

#include "shader_corpus_support.hpp"

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "shader_test_scratch.hpp"

#include <gtest/gtest.h>

#include <cstdlib>
#include <iostream>

#ifndef WM_DEFAULT_UNPACK_ROOT
#define WM_DEFAULT_UNPACK_ROOT ""
#endif

using namespace wallpaper;
using namespace wallpaper::corpus;

namespace
{

struct SweepFailure {
    std::string workshop_id;
    std::string scene_path;
    std::string common_root;
    bool        common_mounted { false };
    std::string source;
    std::string shader_path;
    std::string stage;
    std::string message;
};

std::string Describe(const SweepFailure& failure) {
    std::ostringstream text;
    text << "workshop " << failure.workshop_id << ", scene " << failure.scene_path << "\n"
         << "  common assets: " << (failure.common_root.empty() ? "<none>" : failure.common_root)
         << (failure.common_mounted ? " (mounted)" : " (not mounted)") << "\n"
         << "  material: " << failure.source << ", shader: " << failure.shader_path << ", stage: " << failure.stage
         << "\n  " << failure.message << "\n";
    return text.str();
}

constexpr int kMaxSettleRounds = 8;

// Compiles one job. Default textures a compile reports fill empty texture slots and the
// compile is repeated until that stops changing.
std::optional<std::pair<std::string, std::string>> CompileSettled(fs::VFS& vfs, const std::string& scene_id,
                                                                  const CompileJob& job) {
    const auto vertex   = fs::GetFileContent(vfs, "/assets/" + job.shader_path + ".vert");
    const auto fragment = fs::GetFileContent(vfs, "/assets/" + job.shader_path + ".frag");
    if (vertex.empty()) return std::make_pair(std::string("vertex"), "shader source is missing or unreadable: " + job.shader_path + ".vert");
    if (fragment.empty()) return std::make_pair(std::string("fragment"), "shader source is missing or unreadable: " + job.shader_path + ".frag");

    std::vector<std::string> textures = job.base_textures;
    for (int round = 0; round < kMaxSettleRounds; ++round) {
        std::vector<WPShaderUnit> units(2);
        units[0].stage = ShaderType::VERTEX;
        units[0].src   = vertex;
        units[1].stage = ShaderType::FRAGMENT;
        units[1].src   = fragment;

        std::vector<WPShaderTexInfo> infos;
        for (const auto& path : textures) infos.push_back(ConservativeTexture(path));

        WPShaderInfo info;
        info.combos = Combos(job.combos.begin(), job.combos.end());
        std::vector<shader::RustShaderMetalStage> stages;
        if (! WPShaderParser::CompileToMslRust(scene_id, job.shader_name, units, stages, vfs, &info, infos)) {
            return std::make_pair(std::string("compile"), shader::LastRustShaderError());
        }

        bool changed = false;
        for (const auto& [slot, path] : info.defTexs) {
            if (slot < 0) continue;
            if (static_cast<std::size_t>(slot) >= textures.size()) textures.resize(static_cast<std::size_t>(slot) + 1);
            if (textures[static_cast<std::size_t>(slot)].empty() && ! path.empty()) {
                textures[static_cast<std::size_t>(slot)] = path;
                changed                                  = true;
            }
        }
        if (! changed) return std::nullopt;
    }
    return std::make_pair(std::string("compile"), std::string("the default-texture list did not stabilise"));
}

} // namespace

TEST(ShaderCorpusSweep, DISABLED_ParsesCorpus) {
    const auto config = ResolveSweepConfig([](const char* name) { return std::getenv(name); }, WM_DEFAULT_UNPACK_ROOT);

    const auto gate = DecideSweepGate(config.unpack_root);
    if (gate.gate == SweepGate::Skip) GTEST_SKIP() << gate.message;
    ASSERT_NE(gate.gate, SweepGate::Fail) << gate.message;
    REQUIRE_LINKED_COMPILER();
    ASSERT_LE(gate.scenes.size(), kSceneFolderLimit);

    std::vector<SweepFailure> failures;
    std::vector<std::string>  blockers;
    std::size_t               compiled = 0;

    for (const auto& scene_folder : gate.scenes) {
        const std::string id         = scene_folder.filename().string();
        const auto        scene_path = scene_folder / "scene.json";

        SweepFailure where;
        where.workshop_id = id;
        where.scene_path  = scene_path.string();
        if (config.assets_root) where.common_root = config.assets_root->string();

        fs::VFS vfs;
        if (config.assets_root && stdfs::is_directory(*config.assets_root)) {
            where.common_mounted =
                vfs.Mount("/assets", fs::CreatePhysicalFs(config.assets_root->string()), "common-assets");
        }
        if (! vfs.Mount("/assets", fs::CreatePhysicalFs(scene_folder.string()), "workshop-" + id)) {
            auto failure    = where;
            failure.stage   = "mount";
            failure.message = "the scene folder could not be mounted";
            failures.push_back(failure);
            continue;
        }

        const auto text = ReadWholeFile(scene_path);
        auto       scene = text ? nlohmann::json::parse(*text, nullptr, false) : nlohmann::json(nlohmann::json::value_t::discarded);
        if (scene.is_discarded()) {
            blockers.push_back("scene.json of workshop " + id + " is unreadable");
            continue;
        }

        const Roots roots { scene_folder, where.common_mounted ? config.assets_root : std::nullopt };
        auto        collection = CollectExpectations(scene, roots, vfs, id);
        for (const auto& blocker : collection.blockers) blockers.push_back("workshop " + id + ": " + blocker.message);

        for (const auto& expectation : collection.expectations) {
            std::vector<Blocker> job_blockers;
            const auto           job = BuildJob(expectation, job_blockers);
            for (const auto& blocker : job_blockers) blockers.push_back("workshop " + id + ": " + blocker.message);
            if (! job) continue;

            ++compiled;
            if (const auto problem = CompileSettled(vfs, id, *job)) {
                auto failure        = where;
                failure.source      = job->source.string();
                failure.shader_path = job->shader_path;
                failure.stage       = problem->first;
                failure.message     = problem->second;
                failures.push_back(std::move(failure));
            }
        }
    }

    if (! blockers.empty()) {
        std::ostringstream report;
        for (const auto& line : blockers) report << line << "\n";
        std::cerr << "corpus blockers (unreadable assets, not failures):\n" << report.str();
        RecordProperty("corpus_blockers", report.str());
    }
    std::cerr << "corpus sweep compiled " << compiled << " programs from " << gate.scenes.size() << " scenes\n";

    std::ostringstream report;
    for (const auto& failure : failures) report << Describe(failure);
    EXPECT_TRUE(failures.empty()) << failures.size() << " shader(s) failed:\n" << report.str();
}
