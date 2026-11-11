#pragma once
#include <memory>

namespace wallpaper
{

class Scene;
namespace rg
{
class RenderGraph;
}

/// Builds the render graph of a parsed scene out of the backend-neutral steps in
/// ScenePass.hpp: the order, the targets each step reads and writes, and how
/// each draw loads its target. The renderer executes this graph. It also
/// records the targets that must keep their image from one frame to the next in
/// `Scene::renderTargets`, so `scene` is not const.
std::unique_ptr<rg::RenderGraph> sceneToRenderGraph(Scene&);

/// Whether draws into one image that nothing but their order or their depth attachment kept
/// apart share one render pass. A scene whose objects are drawn in their own order but never
/// re-sorted while it runs (a layer samples another layer's picture, or a planar reflection,
/// without transparent sorting) leaves the passes of its objects to the dependencies their
/// reads and writes declare, instead of running every pass of one object before the next
/// object's first, so a layer's own buffers are drawn ahead of the draws into the scene's image
/// around it. And the Metal backend gives a draw that does not depth-test, between two into the
/// same image that do, that image's depth attachment (`metal::ShareDepthAttachments`). On
/// unless `WALLPAPER_MACHINE_SCENE_PASS_MERGE=0`, read once; a graph takes the value it was
/// built with.
bool ScenePassMergeEnabled();
/// Test-only, process-wide: sets the switch and returns what it was.
bool SetScenePassMergeForTests(bool enabled);
} // namespace wallpaper
