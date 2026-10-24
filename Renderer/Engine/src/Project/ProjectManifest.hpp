#pragma once

#include <string>

namespace wallpaper
{

enum class WallpaperProjectType
{
    Scene,
    Video,
    Web,
    Unknown,
};

struct ProjectManifest {
    WallpaperProjectType type { WallpaperProjectType::Unknown };
    std::string          file;
    std::string          workshop_id;
};

const char* ToString(WallpaperProjectType type);

bool ParseProjectManifest(
    const std::string& project_path,
    ProjectManifest*   manifest,
    std::string*       error);

} // namespace wallpaper
