// Explicit diagnostic tool. Parses scene projects repeatedly in one process,
// each parse on a fresh thread with a fresh VFS, mirroring how production
// creates a new SceneWallpaper (and therefore a new parse thread) for every
// wallpaper switch. No surface, swapchain, AppKit window or desktop capture.
#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "SceneSourceResolver.hpp"
#include "WPSceneParser.hpp"

#include <charconv>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace wallpaper;

namespace {
void Check(bool ok, const char* message) {
    if (! ok) throw std::runtime_error(message);
}

uint16_t PackageVersion(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    uint32_t      length = 0;
    file.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (! file || length < 5 || length > 64) return SceneParseRequest::kUnknownPkgVersion;
    std::string stamp(length, '\0');
    file.read(stamp.data(), length);
    if (! file || ! stamp.starts_with("PKGV")) return SceneParseRequest::kUnknownPkgVersion;
    uint16_t   version    = 0;
    const auto [end, ec]  = std::from_chars(stamp.data() + 4, stamp.data() + stamp.size(), version);
    return ec == std::errc {} && end == stamp.data() + stamp.size()
               ? version
               : SceneParseRequest::kUnknownPkgVersion;
}

std::vector<std::string> Split(std::string_view value, char separator) {
    std::vector<std::string> parts;
    while (! value.empty()) {
        const auto index = value.find(separator);
        if (index == std::string_view::npos) {
            parts.emplace_back(value);
            break;
        }
        if (index > 0) parts.emplace_back(value.substr(0, index));
        value.remove_prefix(index + 1);
    }
    return parts;
}

// One parse, exactly as production does it: fresh VFS mounts, fresh
// SoundManager, fresh ProjectProperties, on a thread that exits afterwards.
void ParseOnce(const std::string& project, const std::string& assets,
               const std::filesystem::path& cache_root) {
    SceneSourcePaths paths;
    std::string      error;
    Check(ResolveSceneSourcePaths(project, &paths, &error), error.c_str());
    fs::VFS vfs;
    Check(vfs.Mount("/assets", fs::CreatePhysicalFs(assets), "assets"), "assets mount");
    Check(MountSceneSource(vfs, paths, &error), error.c_str());
    Check(vfs.Mount("/cache", fs::CreatePhysicalFs(cache_root.string(), true), "cache"),
          "cache mount");
    InstallVirtualAssets(vfs);
    ProjectProperties properties;
    Check(ParseProjectProperties(project, &properties, &error), error.c_str());
    auto source = vfs.Open("/assets/" + paths.pkg_entry);
    Check(source != nullptr, "scene source");
    WPSceneParser      parser;
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    auto                scene = parser.Parse(SceneParseRequest {
                          .scene_id           = paths.scene_id,
                          .project_path       = project,
                          .project_properties = &properties,
                          .pkg_version        = PackageVersion(paths.pkg_path),
    },
                                             source->ReadAllStr(), vfs, sound);
    Check(scene != nullptr, "parse scene");
}
} // namespace

int main() {
    try {
        const char* projects = std::getenv("WE_TEST_PROJECTS");
        const char* assets   = std::getenv("WE_TEST_ASSETS");
        const char* output   = std::getenv("WE_TEST_OUTPUT");
        Check(projects && assets && output,
              "Set WE_TEST_PROJECTS (';'-separated), WE_TEST_ASSETS, WE_TEST_OUTPUT");
        const std::filesystem::path out(output);
        std::filesystem::create_directories(out);
        int cycles = 2;
        if (const char* value = std::getenv("WE_TEST_CYCLES")) {
            const std::string_view text(value);
            const auto parsed = std::from_chars(text.data(), text.data() + text.size(), cycles);
            Check(parsed.ec == std::errc {} && parsed.ptr == text.data() + text.size() &&
                      cycles >= 1 && cycles <= 64,
                  "WE_TEST_CYCLES must be 1..64");
        }
        const auto list = Split(projects, ';');
        Check(! list.empty(), "WE_TEST_PROJECTS is empty");

        const auto started = std::chrono::steady_clock::now();
        for (int cycle = 0; cycle < cycles; ++cycle) {
            for (std::size_t index = 0; index < list.size(); ++index) {
                const auto label = "cycle=" + std::to_string(cycle) + " project=" +
                                   std::filesystem::path(list[index]).parent_path().filename().string();
                std::cout << "=== parse begin " << label << std::endl;
                std::string       failure;
                const std::string project = list[index];
                const std::string assets_path(assets);
                const auto        cache_root = out / "cache";
                std::thread       worker([&] {
                    try {
                        ParseOnce(project, assets_path, cache_root);
                    } catch (const std::exception& error) {
                        failure = error.what();
                    }
                });
                worker.join();
                Check(failure.empty(), failure.c_str());
                std::cout << "=== parse done  " << label << " elapsed_ms="
                          << std::chrono::duration<double, std::milli>(
                                 std::chrono::steady_clock::now() - started)
                                 .count()
                          << std::endl;
            }
        }
        std::cout << "All parses completed" << std::endl;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    return 0;
}
