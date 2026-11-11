#include "Scene/SceneReflection.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"

namespace wallpaper {
void EnsureSceneReflectionTarget(Scene& scene, int width, int height) {
    const std::string key(kReflectionTarget);
    if (scene.renderTargets.contains(key)) return;
    SceneRenderTarget target {};
    target.width=std::max(2,width);
    target.height=std::max(2,height);
    target.format=TextureFormat::RGBA8;
    target.withDepth=scene.reflection_enabled;
    target.bind.enable=true;
    target.bind.screen=true;
    target.initial_clear={scene.clearColor[0],scene.clearColor[1],scene.clearColor[2],1};
    scene.renderTargets.emplace(key,target);
}
void PrepareSceneReflection(Scene& scene, bool requested) {
    scene.reflection.requested=requested;
    if (!requested || !scene.reflection_enabled || !scene.activeCamera) return;
    if (!scene.reflection.camera) {
        scene.reflection.camera=std::make_shared<SceneCamera>(*scene.activeCamera);
        scene.reflection.camera_node=std::make_shared<SceneNode>();
        scene.reflection.camera->AttatchNode(scene.reflection.camera_node);
        scene.cameras[std::string(kReflectionCamera)]=scene.reflection.camera;
    }
    UpdateSceneReflection(scene);
}
void UpdateSceneReflection(Scene& scene) {
    auto& state=scene.reflection;
    if (!state.requested || !scene.reflection_enabled || !state.camera || !scene.activeCamera) return;
    state.source_camera=scene.activeCamera;
    const auto& source=*state.source_camera;
    auto mirror=linalg::Matrix4d::Identity().eval();
    mirror(1,1)=-1;
    auto model=linalg::Matrix4d::Identity().eval();
    if (const auto node=source.GetAttachedNode()) {node->UpdateTrans();model=node->ModelTrans();}
    state.camera_node->SetAttachmentTransform(mirror*model);
    state.camera->Clone(source);
    const auto shake=source.ShakeOffset();
    state.camera->SetShakeOffset({shake.x(),-shake.y(),shake.z()});
    // WE's scene framebuffer has the opposite vertical projection convention
    // from its sampled reflection target. This is independent of the world mirror.
    auto framebuffer_flip=linalg::Matrix4d::Identity().eval();
    framebuffer_flip(1,1)=-1;
    const auto source_projection = scene.display_framed
        ? source.GetRasterViewProjectionMatrix(scene.display_clip,scene.display_clip_generation)
        : source.GetViewProjectionMatrix();
    state.camera->SetViewProjectionOverride((framebuffer_flip*source_projection*mirror).eval());
}
}
