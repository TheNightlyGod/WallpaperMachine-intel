#pragma once

#include "Scene/Scene.h"
#include "Scene/SceneBackendSelection.hpp"

#include <string>
#include <vector>

namespace wallpaper
{

/// The scene to read: the paths and saved choices the scene host would load it with.
struct SceneCapabilityProbeRequest {
    /// The project's `project.json`.
    std::string project_file;
    /// The shared Wallpaper Engine assets folder.
    std::string assets;
    /// The shader cache folder, or empty to translate every shader afresh.
    std::string cache;
    /// The saved property choices as a flat JSON object, or empty for the project's defaults.
    std::string property_override_json;
};

/// What reading a scene, without drawing it, says about it.
struct SceneCapabilityProbeResult {
    /// Why the scene could not be read at all. Empty when it was; nothing below is known otherwise.
    std::string read_error;
    /// Whether Native Metal would refuse the scene, and why: the decision the scene host takes
    /// once the scene is parsed, before any renderer exists (`EvaluateMetalSupport`). A scene it
    /// accepts can still fail later, when its shaders are compiled for the device or its render
    /// graph is built; neither happens here.
    SceneBackendSelection selection;
    /// The files the scene names and does not have (`Scene::missing_files`).
    std::vector<SceneMissingFile> missing_files;
};

/// Reads a scene exactly as the scene host loads it (the same file space, saved choices and
/// parser, shader translation included) and answers without a display, a GPU or audio output.
/// Blocks for as long as the parse takes, which for a large scene is seconds; it writes only to
/// the shader cache, as a load does.
SceneCapabilityProbeResult ProbeSceneCapability(const SceneCapabilityProbeRequest& request);

/// The result as the JSON document the C interface hands out:
/// `{"read_error", "failure_stage", "failure_reason", "missing_files": [{"layer", "object_id", "path"}]}`.
std::string SceneCapabilityProbeJson(const SceneCapabilityProbeResult& result);

} // namespace wallpaper
