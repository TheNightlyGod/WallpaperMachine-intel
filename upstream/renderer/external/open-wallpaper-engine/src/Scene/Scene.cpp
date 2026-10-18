#include "Scene.h"

#include "Fs/VFS.h"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"
#include "Particle/ParticleSystem.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Utils/Algorism.h"

namespace wallpaper 
{

Scene::Scene(): sceneGraph(std::make_shared<SceneNode>()) ,paritileSys(std::make_unique<ParticleSystem>(*this)) {}
Scene::~Scene() {
    // A script's `destroy()` may reach the file system, the render-exclusion list
    // and the scene graph. Members die in reverse order of declaration, and the
    // runtime is declared above the first two, so left to its own destructor it
    // would end its scripts after those were gone. Ending them here, before any
    // member is destroyed, is the one point at which all of it still exists.
    if (runtime != nullptr) runtime->TearDownScripts();
}

void Scene::FrameCanvas(double zoom, const Eigen::Vector2f& offset) {
    const auto global = cameras.find("global");
    if (global == cameras.end() || global->second == nullptr) return;
    auto& camera = *global->second;

    const Eigen::Vector2f centre = Eigen::Vector2f(static_cast<float>(ortho[0]),
                                                   static_cast<float>(ortho[1])) * 0.5f + offset;
    // Aiming moves only the view's centre. How far the perspective camera then
    // sits in front of the canvas plane follows from the view's size, below.
    const auto aim = [&centre](SceneCamera& target) {
        const auto node = target.GetAttachedNode();
        if (node == nullptr) return;
        Eigen::Vector3f translate = node->Translate();
        translate.head<2>()       = centre;
        node->SetTranslate(translate);
    };
    camera.SetZoom(zoom);
    aim(camera);
    camera.Update();
    if (const auto perspective = cameras.find("global_perspective");
        perspective != cameras.end() && perspective->second != nullptr) {
        auto& perspective_camera = *perspective->second;
        aim(perspective_camera);
        FitCanvasPerspective(perspective_camera, camera);
        perspective_camera.Update();
    }
    UpdateLinkedCamera("global");
}

}

