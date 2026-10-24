#pragma once

#include "Project/ProjectManifest.hpp"

#include <string>

namespace wallpaper
{

struct SceneSourcePaths {
    std::string pkg_path;
    std::string pkg_entry;
    std::string pkg_dir;
    std::string scene_id;
};

enum class SceneSourceResolutionKind
{
    Scene,
    NotSceneProject,
};

struct SceneSourceResolution {
    SceneSourceResolutionKind kind { SceneSourceResolutionKind::Scene };
    ProjectManifest           manifest;
    SceneSourcePaths          scene_source;
};

bool ResolveSceneSourcePaths(const std::string& source, SceneSourceResolution* resolved,
                             std::string* error);
bool ResolveSceneSourcePaths(const std::string& source, SceneSourcePaths* resolved,
                             std::string* error);

namespace fs
{
class VFS;
}

/// Mounts a scene's own files at `/assets`, above whatever is already mounted
/// there (the shared assets). The project folder goes in first and the package,
/// when there is one, on top of it: anything packaged wins, and a file that only
/// exists beside the package -- a Workshop preset's own picture or video under
/// `files/`, which its `scenetexture` properties name -- is still found.
bool MountSceneSource(fs::VFS& vfs, const SceneSourcePaths& paths, std::string* error);

} // namespace wallpaper
