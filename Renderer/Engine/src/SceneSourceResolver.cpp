// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#include "SceneSourceResolver.hpp"

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectManifest.hpp"
#include "WPPkgFs.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <filesystem>

namespace wallpaper
{

namespace
{

bool Fail(std::string* error, std::string message)
{
    LOG_ERROR("scene source: %s", message.c_str());
    if (error != nullptr) *error = std::move(message);
    return false;
}

bool LeavesFolder(const std::filesystem::path& entry)
{
    return std::any_of(entry.begin(), entry.end(), [](const std::filesystem::path& part) {
        return part == "..";
    });
}

// The four path strings of a scene whose entry name inside its folder is `entry`.
void FillPaths(const std::filesystem::path& folder, const std::string& entry, SceneSourcePaths* out)
{
    std::filesystem::path pkg_name { entry };
    pkg_name.replace_extension(".pkg");
    std::filesystem::path json_name { entry };
    json_name.replace_extension(".json");
    out->pkg_path  = (folder / pkg_name).string();
    out->pkg_entry = json_name.generic_string();
    out->pkg_dir   = folder.string();
    out->scene_id  = folder.filename().string();
}

} // namespace

bool ResolveSceneSourcePaths(
    const std::string&     source,
    SceneSourceResolution* resolved,
    std::string*           error)
{
    if (resolved == nullptr) return Fail(error, "scene source output must not be null");
    // Whatever happens next, a failure leaves nothing half filled.
    *resolved = SceneSourceResolution {};
    if (source.empty()) return Fail(error, "no scene source was given");

    const std::filesystem::path path { source };
    const std::filesystem::path folder = path.parent_path();
    const std::string           file   = path.filename().string();

    SceneSourceResolution result;
    std::string           entry;
    if (file == "project.json") {
        std::string reason;
        if (! ParseProjectManifest(source, &result.manifest, &reason)) return Fail(error, reason);
        if (result.manifest.type != WallpaperProjectType::Scene) {
            result.kind = SceneSourceResolutionKind::NotSceneProject;
            *resolved   = std::move(result);
            return true;
        }
        entry = result.manifest.file.empty() ? "scene.json" : result.manifest.file;
    } else {
        // Not a project file: the source is the scene entry itself.
        result.manifest.type        = WallpaperProjectType::Scene;
        result.manifest.file        = file;
        result.manifest.workshop_id = folder.filename().string();
        entry                       = file;
    }

    if (entry.empty()) return Fail(error, "scene entry must not be empty");
    if (entry.front() == '/') return Fail(error, "scene entry must be relative: " + entry);
    if (LeavesFolder(entry)) return Fail(error, "scene entry leaves its folder: " + entry);

    result.kind = SceneSourceResolutionKind::Scene;
    FillPaths(folder, entry, &result.scene_source);
    *resolved = std::move(result);
    return true;
}

bool ResolveSceneSourcePaths(
    const std::string& source,
    SceneSourcePaths*  resolved,
    std::string*       error)
{
    if (resolved == nullptr) return Fail(error, "scene source output must not be null");
    *resolved = SceneSourcePaths {};

    SceneSourceResolution resolution;
    if (! ResolveSceneSourcePaths(source, &resolution, error)) return false;
    if (resolution.kind != SceneSourceResolutionKind::Scene)
        return Fail(error,
                    std::string("project is not a scene: ") + ToString(resolution.manifest.type));
    *resolved = std::move(resolution.scene_source);
    return true;
}

bool MountSceneSource(fs::VFS& vfs, const SceneSourcePaths& paths, std::string* error)
{
    auto folder = fs::CreatePhysicalFs(paths.pkg_dir);
    if (!folder || !vfs.Mount("/assets", std::move(folder))) {
        if (error != nullptr) *error = "can't load pkg directory: " + paths.pkg_dir;
        return false;
    }
    std::error_code ec;
    if (!std::filesystem::is_regular_file(paths.pkg_path, ec)) return true;
    if (!vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(paths.pkg_path))) {
        LOG_INFO("load pkg file %s failed, fallback to use dir", paths.pkg_path.c_str());
    }
    return true;
}

} // namespace wallpaper
