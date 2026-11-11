#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/CameraPlacement.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneMesh.h"

#include <algorithm>
#include <cmath>

namespace wallpaper {

// Allocated only for a canvas with global paths. The path temporarily owns these
// internal nodes; an explicit camera shot must receive the original basis.
struct SceneRuntimeContext::GlobalCameraBasePose {
    struct NodePose {
        std::shared_ptr<SceneNode> node;
        linalg::Vector3f position, scale, rotation;
        void Save(const std::shared_ptr<SceneNode>& value) {
            node = value;
            if (!node) return;
            position = node->Translate();
            scale = node->Scale();
            rotation = node->Rotation();
        }
        void Restore() const {
            if (!node) return;
            node->SetTranslate(position);
            node->SetScale(scale);
            node->SetRotation(rotation);
        }
    } canvas, perspective;
    double zoom { 1 };
    bool applied { false };
};

bool SceneRuntimeContext::IsCameraLayer(std::string_view name) const {
    for (const auto& shot : m_camera_shots)
        if (shot.node && shot.node->Name() == name) return true;
    for (const auto& group : m_perspective_camera_groups)
        for (const auto& shot : group.shots)
            if (shot.node && shot.node->Name() == name) return true;
    return false;
}

void SceneRuntimeContext::RegisterStaticCameraTransforms(StaticCameraTransforms value) {
    m_initial_static_camera = value;
}

void SceneRuntimeContext::StartStaticCamera() {
    if (m_static_camera_started) return;
    m_static_camera = m_initial_static_camera;
    m_static_camera_started = true;
}

bool SceneRuntimeContext::SetStaticCameraTransforms(const StaticCameraTransforms& value,
                                                   uint32_t fields) {
    if (m_scene == nullptr || (fields & 15u) == 0) return false;
    auto next = m_static_camera;
    for (std::size_t group = 0; group < 3; ++group) {
        if (fields & (1u << group)) {
            for (std::size_t lane = 0; lane < 3; ++lane) next[group * 3 + lane] = value[group * 3 + lane];
        }
    }
    if (fields & 8u) next[9] = value[9];
    if (!std::all_of(next.begin(), next.end(), [](double v) { return std::isfinite(v); }) || next[9] <= 0)
        return false;
    if (next == m_static_camera) return true;
    m_static_camera = next;

    const bool canvas = !m_scene->display_sized;
    // The lens zoom is a separate scene setting and is already live during init. Camera
    // positions written during init are replaced by the file before the first update.
    if (fields & 8u) {
        m_initial_static_camera[9] = next[9];
        if (canvas) ApplySceneZoom(next[9]);
    }
    if (!m_static_camera_started || !(fields & 7u)) return true;

    const auto camera = m_scene->cameras.find(canvas ? "global" : "global_perspective");
    if (camera == m_scene->cameras.end() || !camera->second) return false;
    const auto node = camera->second->GetAttachedNode();
    if (!node) return false;
    const linalg::Vector3d offset = canvas
        ? linalg::Vector3d(m_scene->ortho[0] * 0.5, m_scene->ortho[1] * 0.5, 0)
        : linalg::Vector3d::Zero();
    const linalg::Vector3d eye(next[0], next[1], next[2]);
    const linalg::Vector3d center(next[3], next[4], next[5]);
    const linalg::Vector3d up(next[6], next[7], next[8]);
    PlaceCameraNode(*node, eye + offset, center + offset, up);
    camera->second->Update();
    if (canvas) {
        const auto perspective = m_scene->cameras.find("global_perspective");
        if (perspective != m_scene->cameras.end() && perspective->second) {
            if (auto linked = perspective->second->GetAttachedNode()) {
                PlaceCameraNode(*linked, eye + offset, center + offset, up);
                FitCanvasPerspective(*perspective->second, *camera->second);
                perspective->second->Update();
            }
        }
        m_scene->UpdateLinkedCamera("global");
    }
    return true;
}

void SceneRuntimeContext::SetCameraFadeEnabled(bool enabled) {
    if (m_camera_fade_enabled == enabled) return;
    m_camera_fade_enabled = enabled;
    ApplyCameraFadeBinding();
}

void SceneRuntimeContext::RegisterGlobalCameraPaths(SceneCamera* camera,
        std::shared_ptr<SceneNode> node, GlobalCameraPlayback paths) {
    m_global_camera_paths = std::move(paths);
    m_global_path_camera = camera;
    m_global_path_node = std::move(node);
    m_has_camera_paths = camera && m_global_path_node && !m_global_camera_paths.empty();
    m_global_camera_base.reset();
    if (m_has_camera_paths && m_scene && !m_scene->display_sized) {
        m_global_camera_base = std::make_shared<GlobalCameraBasePose>();
        m_global_camera_base->canvas.Save(m_global_path_node);
        m_global_camera_base->zoom = camera->Zoom();
        const auto perspective = m_scene->cameras.find("global_perspective");
        if (perspective != m_scene->cameras.end() && perspective->second &&
            perspective->second->GetAttachedNode() != m_global_path_node)
            m_global_camera_base->perspective.Save(perspective->second->GetAttachedNode());
    }
    SetCameraFadeAlpha(m_has_camera_paths ? m_global_camera_paths.FadeAlpha() : 0);
}

void SceneRuntimeContext::RestoreGlobalCameraBase() {
    if (!m_global_camera_base || !m_global_camera_base->applied) return;
    m_global_camera_base->canvas.Restore();
    m_global_camera_base->perspective.Restore();
    m_global_path_camera->SetZoom(m_global_camera_base->zoom);
    m_global_camera_base->applied = false;
    m_framed_camera_shot.reset();
}

void SceneRuntimeContext::ApplyGlobalCameraPaths(double seconds) {
    if (!m_has_camera_paths || !m_scene) return;
    // Explicit camera layers override this queue and pause its clock (WE 0x1401891A0).
    if (!m_canvas_shot_selected && !m_perspective_shot_selected) {
        const auto pose = m_global_camera_paths.Sample();
        const bool canvas = !m_scene->display_sized;
        const linalg::Vector3d offset = canvas
            ? linalg::Vector3d(m_scene->ortho[0]*0.5, m_scene->ortho[1]*0.5, 0)
            : linalg::Vector3d::Zero();
        const linalg::Vector3d eye(pose[0],pose[1],pose[2]);
        const linalg::Vector3d center(pose[3],pose[4],pose[5]);
        const linalg::Vector3d up(pose[6],pose[7],pose[8]);
        if (m_global_path_camera->GetAttachedNode() != m_global_path_node)
            m_global_path_camera->AttatchNode(m_global_path_node);
        PlaceCameraNode(*m_global_path_node, eye+offset, center+offset, up);
        if (canvas) {
            // Width/height already hold the scene zoom. The path is the same
            // separate camera zoom an explicit canvas shot uses.
            m_global_path_camera->SetZoom(pose[9]);
            m_framed_camera_shot.reset();
            if (m_global_camera_base) m_global_camera_base->applied = true;
            const auto perspective = m_scene->cameras.find("global_perspective");
            if (perspective != m_scene->cameras.end() && perspective->second) {
                if (auto node = perspective->second->GetAttachedNode())
                    PlaceCameraNode(*node, eye+offset, center+offset, up);
                FitCanvasPerspective(*perspective->second,*m_global_path_camera);
                perspective->second->Update();
            }
            m_scene->UpdateLinkedCamera("global");
        }
        m_global_path_camera->Update();
        m_scene->activeCamera = m_global_path_camera;
        // Pose sampling precedes advancing the fade clock; no overshoot is carried at a cut.
        m_global_camera_paths.Advance(seconds);
    } else {
        // Canvas selection restores before FrameCanvas. A perspective override
        // uses its own node; restore only our saved internal nodes here.
        RestoreGlobalCameraBase();
    }
    SetCameraFadeAlpha(m_global_camera_paths.FadeAlpha());
}

void SceneRuntimeContext::RegisterCameraFadeNode(const std::shared_ptr<SceneNode>& node) {
    m_camera_fade_node = node;
    ApplyCameraFadeBinding();
}

void SceneRuntimeContext::SetCameraFadeAlpha(double alpha) {
    if (m_camera_fade_alpha == alpha) return;
    m_camera_fade_alpha = alpha;
    if (m_camera_fade_enabled) ApplyCameraFadeBinding();
}

void SceneRuntimeContext::ApplyCameraFadeBinding() {
    const auto node = m_camera_fade_node.lock();
    if (!node) return;
    node->SetVisible(m_camera_fade_enabled && m_camera_fade_alpha > 0.0);
    if (auto* mesh = node->Mesh()) {
        if (auto* material = mesh->Material()) {
            material->customShader.constValues["g_Alpha"] = ShaderValue(static_cast<float>(m_camera_fade_alpha));
        }
    }
}

} // namespace wallpaper
