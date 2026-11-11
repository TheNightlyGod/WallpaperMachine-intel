#include "Scene.h"
#include "SceneCamera.h"
#include "SceneShadows.hpp"
#include <cmath>
#include <algorithm>

namespace wallpaper {
using namespace linalg;

void UpdateSceneVolumetrics(Scene& scene) {
    if (scene.volumetric_lights.empty() || !scene.activeCamera) return;
    const Matrix4d camera = scene.display_framed
        ? scene.activeCamera->GetRasterViewProjectionMatrix(scene.display_clip,
                                                            scene.display_clip_generation)
        : scene.activeCamera->GetViewProjectionMatrix();
    for (auto& volume : scene.volumetric_lights) {
        const auto& light = *volume.light;
        auto* node = light.node();
        node->UpdateTrans();
        const Matrix4d world = node->ModelTrans();
        const std::array<float,3> shape {light.radius(),light.innerCone(),light.outerCone()};
        bool changed = false;
        if (world != volume.previous_world || camera != volume.previous_camera || shape != volume.previous_shape) {
            volume.previous_world = world;
            volume.previous_camera = camera;
            volume.previous_shape = shape;
            volume.camera_inverse = camera.inverse();
            volume.volume = Matrix4d::Identity();
            volume.projection = Matrix4d::Identity();
            if (light.type() == SceneLightType::Point) {
                volume.volume.block<3,3>(0,0) *= light.radius();
                volume.volume.block<3,1>(0,3) = world.block<3,1>(0,3);
            } else {
                volume.projection = SceneVolumeProjection(light, scene.shadows.ortho_scene);
                volume.volume = volume.projection.inverse();
                // Shadow maps use reversed depth; the volume itself uses normal scene depth.
                if (volume.shadow)
                    volume.projection.row(2) = volume.projection.row(3) - volume.projection.row(2);
            }
            changed = true;
        }
        const double radians = std::acos(-1.0) / 180.0;
        const auto color = light.color();
        const Vector3d forward = world.block<3,1>(0,0).normalized();
        std::array<std::array<float,4>,5> parameters {{
            {0,0,1,1},
            {light.radius()*0.99f,static_cast<float>(std::cos(light.innerCone()*radians)),
                static_cast<float>(std::cos(light.outerCone()*radians)),light.intensity()},
            {static_cast<float>(world(0,3)),static_cast<float>(world(1,3)),
                static_cast<float>(world(2,3)),light.castsVolumetrics() ? light.density() : 0.0f},
            {static_cast<float>(forward.x()),static_cast<float>(forward.y()),static_cast<float>(forward.z()),0},
            {color.x(),color.y(),color.z(),light.volumetricsExponent()}
        }};
        if (volume.shadow) {
            if (light.type()==SceneLightType::Point) {
                const Matrix4d projection=ScenePointShadowProjection(light,scene.shadows.ortho_scene,scene.quality.shadows);
                parameters[3]={static_cast<float>(projection(2,2)),static_cast<float>(projection(2,3)),
                    static_cast<float>(projection(3,2)),static_cast<float>(projection(3,3))};
            }
            for (const auto& view : scene.shadows.views) {
                if (view.light != &light) continue;
                const auto& transform = light.type()==SceneLightType::Point
                    ? scene.shadows.point_transform : scene.shadows.projection_transform;
                if (transform.size() >= (view.slot+1)*4)
                    std::copy_n(transform.data()+view.slot*4,4,parameters[0].data());
                if (light.type()==SceneLightType::Point && scene.shadows.point_projection.size()>=(view.slot+1)*4)
                    std::copy_n(scene.shadows.point_projection.data()+view.slot*4,4,parameters[3].data());
                break;
            }
        }
        if (parameters != volume.parameters) {
            volume.parameters = parameters;
            changed = true;
        }
        // Orthographic rays start at the near plane, not at the canvas origin.
        Vector3d eye = scene.activeCamera->GetPosition();
        if (!scene.activeCamera->IsPerspective()) {
            // Display framing changes raster coordinates, not the camera's
            // near-plane origin used to choose the entry surface.
            const auto& frame = scene.display_clip;
            const Vector4d centre = scene.display_framed
                ? Vector4d(frame[2],frame[3],0,1) : Vector4d(0,0,0,1);
            const Vector4d near = volume.camera_inverse * centre;
            eye = near.head<3>() / near.w();
        }
        eye += scene.activeCamera->GetDirection() *
            ((light.flags() & SceneLight::kUseCookie) != 0 ? 0.1 : 0.2);
        bool inside = false;
        if (light.type()==SceneLightType::Point) {
            inside = (eye-world.block<3,1>(0,3)).squaredNorm() < double(light.radius())*light.radius();
        } else {
            Matrix4d projection = volume.projection;
            if (volume.shadow) projection.row(2) = projection.row(3) - projection.row(2);
            const Vector4d clip = projection * Vector4d(eye.x(),eye.y(),eye.z(),1);
            if (clip.w()>0) {
                const Vector3d ndc = clip.head<3>() / clip.w();
                const bool cookie = (light.flags() & SceneLight::kUseCookie) != 0;
                inside = ndc.z()>=0 && ndc.z()<=1 &&
                    (cookie ? (std::abs(ndc.x())<=1 && std::abs(ndc.y())<=1)
                            : ndc.x()*ndc.x()+ndc.y()*ndc.y()<=1);
            }
        }
        const bool visible = light.visible() && light.castsVolumetrics();
        volume.back->SetVisible(visible);
        volume.front->SetVisible(visible && !inside);
        volume.fullscreen->SetVisible(visible && inside);
        if (changed) ++volume.generation;
    }
}
} // namespace wallpaper
