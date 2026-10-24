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
} // namespace wallpaper
