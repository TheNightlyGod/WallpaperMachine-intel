#pragma once

#include "Project/ProjectProperties.hpp"

#include <cstdint>
#include <string>

namespace wallpaper
{
namespace fs
{
class VFS;
}
struct SceneSourcePaths;

/// The steps a scene project goes through before it is parsed, shared by the scene host that
/// loads it and the probe that only reads it (`ProbeSceneCapability`), so both see the same scene.

/// The version of the package file at `path`, or the unknown value (R-H6).
uint16_t ReadPackageVersion(const std::string& path);

/// Mounts the file space a scene reads for its whole life, lowest layer first: the shared assets
/// at `/assets`, the scene's own files over them, the shader cache at `/cache` when `cache` names
/// a writable folder, and the built-in assets. False, with the reason in `error`, when the scene
/// cannot be read. A cache that cannot be mounted is logged and is not that: a scene without one
/// only compiles its shaders again.
bool MountSceneFileSpace(fs::VFS& vfs, const std::string& assets, const SceneSourcePaths& source,
                         const std::string& cache, std::string* error);

/// The property values a scene loads with: the project's own defaults in `authored`, and those
/// with the saved choices of `override_json` (empty for none) over them in `merged`. False, with
/// the reason in `error`, when either cannot be read.
bool ReadSceneProperties(const std::string& project_path, const std::string& override_json,
                         ProjectProperties* authored, ProjectProperties* merged, std::string* error);

} // namespace wallpaper
