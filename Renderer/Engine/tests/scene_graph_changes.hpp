#pragma once

#include "RenderCommon/SceneToRenderGraph.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"

#include <cstdlib>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper::tests {

/// What a harness's frame boundary did about the changes the runtime asked for.
enum class SceneChangeApplied { None, Resized, Rebuilt };

/// `WE_TEST_RESIZE_AS_REBUILD` set (any value other than `0`): a change that only resized
/// render targets builds the whole graph again instead, as every build before the resize path
/// did. It is how one binary draws the same scene both ways, for a picture and cost comparison.
inline bool ResizeAsRebuild()
{
    const char* value = std::getenv("WE_TEST_RESIZE_AS_REBUILD");
    return value != nullptr && *value != '\0' && std::string_view(value) != "0";
}

/// `WE_TEST_SETTLE_TEXT` set (any value other than `0`): every layout a tick asked for lands in
/// that same frame, instead of whenever the text worker is done with it. Two runs of one scene
/// then draw byte-identical pictures even when its text changes as it runs, which is what a
/// before and after comparison of such a scene needs.
inline void SettleTextLayout(Scene& scene)
{
    const char* value = std::getenv("WE_TEST_SETTLE_TEXT");
    if (scene.runtime == nullptr || value == nullptr || *value == '\0' ||
        std::string_view(value) == "0") {
        return;
    }
    scene.runtime->WaitForTextLayoutForTests();
    scene.runtime->PumpTextLayerCache();
}

/// The host's frame boundary, for a renderer a harness drives: a change to the graph builds it
/// again (the videos stay open when `keep_videos`), and a change that only resized render
/// targets resizes them under the graph that is compiled. `Render` is `MetalRender` or
/// `SceneRendererHandle`. `error` gets the renderer's reason when it fails.
template <class Render>
SceneChangeApplied ApplyRuntimeSceneChanges(Render& render, Scene& scene,
                                            std::unique_ptr<rg::RenderGraph>& graph,
                                            bool keep_videos, std::string* error,
                                            bool force_rebuild = false)
{
    if (scene.runtime == nullptr) return SceneChangeApplied::None;
    const bool graph_changed   = scene.runtime->ConsumeSceneGraphMutationFlag();
    const bool targets_resized = scene.runtime->ConsumeRenderTargetResizeFlag();
    const auto fail            = [&](const std::string& message) {
        if (error != nullptr) *error = message;
        return SceneChangeApplied::None;
    };
    if (graph_changed || force_rebuild || (targets_resized && ResizeAsRebuild())) {
        if (! (keep_videos ? render.clearLastRenderGraphForRebuild()
                           : render.clearLastRenderGraph())) {
            return fail("could not rebuild: " + render.lastError());
        }
        graph = sceneToRenderGraph(scene);
        if (graph == nullptr || ! render.compileRenderGraph(scene, *graph)) {
            return fail("could not rebuild: " + render.lastError());
        }
        return SceneChangeApplied::Rebuilt;
    }
    if (targets_resized) {
        if (! render.ResizeRenderTargets(scene)) {
            return fail("could not resize the render targets: " + render.lastError());
        }
        return SceneChangeApplied::Resized;
    }
    return SceneChangeApplied::None;
}

} // namespace wallpaper::tests
