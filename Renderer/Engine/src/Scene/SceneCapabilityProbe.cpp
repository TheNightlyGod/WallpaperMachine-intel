#include "Scene/SceneCapabilityProbe.hpp"

#include "Audio/SoundManager.h"
#include "Fs/VFS.h"
#include "MetalRender/MetalCapability.hpp"
#include "Scene/SceneProjectLoading.hpp"
#include "SceneSourceResolver.hpp"
#include "WPSceneParser.hpp"

#include <nlohmann/json.hpp>

#include <exception>
#include <memory>

namespace wallpaper
{

SceneCapabilityProbeResult ProbeSceneCapability(const SceneCapabilityProbeRequest& request) {
    SceneCapabilityProbeResult result;
    try {
        SceneSourceResolution resolved;
        std::string           error;
        if (! ResolveSceneSourcePaths(request.project_file, &resolved, &error)) {
            result.read_error = "the scene source cannot be resolved: " + error;
            return result;
        }
        if (resolved.kind != SceneSourceResolutionKind::Scene) {
            result.read_error = "the project is not a scene";
            return result;
        }
        fs::VFS vfs;
        if (! MountSceneFileSpace(vfs, request.assets, resolved.scene_source, request.cache, &error)) {
            result.read_error = error;
            return result;
        }
        const std::string scene_text = fs::GetFileContent(vfs, "/assets/" + resolved.scene_source.pkg_entry);
        if (scene_text.empty()) {
            result.read_error = "the scene file is missing or empty: " + resolved.scene_source.pkg_entry;
            return result;
        }
        ProjectProperties authored;
        ProjectProperties merged;
        if (! ReadSceneProperties(request.project_file, request.property_override_json, &authored,
                                  &merged, &error)) {
            result.read_error = error;
            return result;
        }

        SceneParseRequest parse;
        parse.scene_id                    = resolved.scene_source.scene_id;
        parse.project_path                = request.project_file;
        parse.project_properties          = &merged;
        parse.authored_project_properties = &authored;
        parse.pkg_version                 = ReadPackageVersion(resolved.scene_source.pkg_path);

        // Sounds are mounted as a load mounts them, and never played.
        audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
        WPSceneParser       parser;
        auto                scene = parser.Parse(parse, scene_text, vfs, sound);
        if (scene == nullptr) {
            result.read_error = "the parse produced no scene";
            return result;
        }
        result.selection     = metal::EvaluateMetalSupport(*scene);
        result.missing_files = scene->missing_files;
        // The scene's runtime and sounds go before the file space they read from.
        scene.reset();
    } catch (const std::exception& failure) {
        result = {};
        result.read_error = std::string("reading the scene failed: ") + failure.what();
    }
    return result;
}

std::string SceneCapabilityProbeJson(const SceneCapabilityProbeResult& result) {
    nlohmann::json missing = nlohmann::json::array();
    for (const auto& file : result.missing_files) {
        missing.push_back({ { "layer", file.layer }, { "object_id", file.object_id }, { "path", file.path } });
    }
    const nlohmann::json document {
        { "read_error", result.read_error },
        { "failure_stage", ToString(result.selection.failure_stage) },
        { "failure_reason", result.selection.failure_reason },
        { "missing_files", std::move(missing) },
    };
    // Paths and layer names are the author's bytes: never let one stop the answer.
    return document.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

} // namespace wallpaper
