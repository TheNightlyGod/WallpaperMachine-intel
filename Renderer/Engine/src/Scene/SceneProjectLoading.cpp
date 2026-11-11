#include "Scene/SceneProjectLoading.hpp"

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Interface/ISceneParser.h"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "SceneSourceResolver.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <fstream>
#include <string_view>

#include <unistd.h>

namespace wallpaper
{
namespace
{

/// The version a package's leading tag names ("PKGV" then decimal digits to the end), or the
/// unknown value when the tag is anything else (R-H6).
uint16_t VersionFromPackageTag(std::string_view tag) {
    constexpr std::string_view kPrefix = "PKGV";
    if (tag.size() <= kPrefix.size() || tag.substr(0, kPrefix.size()) != kPrefix) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    const std::string_view digits = tag.substr(kPrefix.size());
    if (! std::all_of(digits.begin(), digits.end(),
                      [](char c) { return c >= '0' && c <= '9'; })) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    uint16_t value = 0;
    const auto [stop, status] = std::from_chars(digits.data(), digits.data() + digits.size(), value);
    if (status != std::errc {} || stop != digits.data() + digits.size()) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    return value;
}

/// Whether `folder` can be written to.
bool IsWritableFolder(const std::string& folder) {
    return ::access(folder.c_str(), W_OK) == 0;
}

} // namespace

uint16_t ReadPackageVersion(const std::string& path) {
    constexpr int32_t kLongestTag = 64;
    std::ifstream     in(path, std::ios::binary);
    int32_t           declared = 0;
    if (! in.read(reinterpret_cast<char*>(&declared), sizeof(declared))) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    if (declared < 1 || declared > kLongestTag) return SceneParseRequest::kUnknownPkgVersion;
    std::array<char, kLongestTag> field {};
    if (! in.read(field.data(), declared)) return SceneParseRequest::kUnknownPkgVersion;
    return VersionFromPackageTag(
        std::string_view(field.data(), static_cast<std::size_t>(declared)));
}

bool MountSceneFileSpace(fs::VFS& vfs, const std::string& assets, const SceneSourcePaths& source,
                         const std::string& cache, std::string* error) {
    {
        auto shared = fs::CreatePhysicalFs(assets);
        if (shared == nullptr || ! vfs.Mount("/assets", std::move(shared))) {
            *error = "the shared assets cannot be mounted: " + assets;
            return false;
        }
    }
    std::string reason;
    if (! MountSceneSource(vfs, source, &reason)) {
        *error = "the wallpaper's files cannot be mounted: " + reason;
        return false;
    }
    if (! cache.empty()) {
        // Optional: a scene without a cache only compiles its shaders again.
        auto mounted = fs::CreatePhysicalFs(cache, true);
        if (mounted == nullptr || ! IsWritableFolder(cache) ||
            ! vfs.Mount("/cache", std::move(mounted), "cache")) {
            LOG_ERROR("shader cache not available, loading without it: %s", cache.c_str());
        }
    }
    if (! InstallVirtualAssets(vfs)) {
        *error = "the built-in assets cannot be installed";
        return false;
    }
    return true;
}

bool ReadSceneProperties(const std::string& project_path, const std::string& override_json,
                         ProjectProperties* authored, ProjectProperties* merged, std::string* error) {
    std::string reason;
    if (! ParseProjectProperties(project_path, authored, &reason)) {
        *error = "the project properties cannot be read: " + reason;
        return false;
    }
    *merged = *authored;
    if (! override_json.empty()) {
        ProjectProperties saved;
        if (! ParseFlatProjectPropertyOverrideJson(override_json, &saved, &reason)) {
            *error = "the saved property choices cannot be read: " + reason;
            return false;
        }
        *merged = MergeProjectProperties(*authored, saved);
    }
    return true;
}

} // namespace wallpaper
