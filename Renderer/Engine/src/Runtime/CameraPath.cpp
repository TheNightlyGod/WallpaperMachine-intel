#include "Runtime/CameraPath.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Utils/Random.hpp"
#include "Scene/SceneCamera.h"
#include "Scene/SceneNode.h"
#include "Utils/Logging.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>

namespace wallpaper
{
std::vector<CameraPath> ParseCameraPaths(const nlohmann::json& json) {
    std::vector<CameraPath> paths;
    const auto entries = json.find("paths");
    if (entries == json.end() || !entries->is_array()) return paths;
    for (const auto& entry : *entries) {
        if (!entry.is_object()) continue;
        if (const auto visible = entry.find("visible"); visible != entry.end() &&
            (!visible->is_boolean() || !visible->get<bool>())) continue;
        const auto options = entry.find("options");
        if (options == entry.end() || !options->is_object()) continue;
        const auto fps_value = options->find("fps");
        const auto length_value = options->find("length");
        if (fps_value == options->end() || !fps_value->is_number() ||
            length_value == options->end() || !length_value->is_number()) continue;
        CameraPath path;
        const double fps = fps_value->get<double>();
        const double length = length_value->get<double>();
        if (!std::isfinite(fps) || !std::isfinite(length) || fps <= 0 || length <= 0) continue;
        path.duration = length / fps;
        if (!std::isfinite(path.duration) || path.duration <= 0) continue;
        path.loop = options->contains("mode") && options->at("mode") == "loop";
        bool valid = true;
        for (const auto& [name, destination] : {
                 std::pair { "eye", &path.eye }, { "center", &path.center }, { "up", &path.up } }) {
            const auto source = entry.find(name);
            if (source == entry.end() || !source->is_object()) { valid = false; break; }
            auto animation = *source;
            animation["options"] = *options;
            // The queue owns wrapping, so all components sample the same time.
            animation["options"]["mode"] = "single";
            const nlohmann::json setting { { "animation", std::move(animation) } };
            for (std::size_t i = 0; i < 3; ++i) {
                auto curve = ResolveScalarAnimation(setting, i);
                if (!curve) { valid = false; break; }
                (*destination)[i] = std::move(*curve);
            }
            if (!valid) break;
        }
        if (!valid) { LOG_ERROR("incomplete camera path"); continue; }
        if (const auto fov = entry.find("fov"); fov != entry.end() && fov->is_array()) {
            nlohmann::json animation { { "c0", *fov }, { "options", *options } };
            animation["options"]["mode"] = "single";
            path.fov = ResolveScalarAnimation({ { "animation", std::move(animation) } });
        }
        paths.push_back(std::move(path));
    }
    return paths;
}

CameraPathPlayback::CameraPathPlayback(std::vector<CameraPath> paths, std::string_view queue_mode)
    : m_paths(std::move(paths)), m_random(queue_mode == "random") {
    if (m_random && !m_paths.empty()) m_index = Random::get<std::size_t>(0, m_paths.size() - 1);
}

void CameraPathPlayback::Advance(double seconds) {
    if (empty() || !std::isfinite(seconds) || seconds <= 0) return;
    m_seconds += seconds;
    // Bound catch-up after suspension even for a random queue of tiny clips.
    // Ordinary ticks carry all overshoot into the next clip, without drift.
    for (unsigned transitions = 0; m_seconds >= m_paths[m_index].duration; ++transitions) {
        const auto& path = m_paths[m_index];
        if (path.loop || m_paths.size() == 1 || transitions == 64) {
            m_seconds = std::fmod(m_seconds, path.duration);
            break;
        }
        m_seconds -= path.duration;
        if (m_random) {
            const auto offset = Random::get<std::size_t>(1, m_paths.size() - 1);
            m_index = (m_index + offset) % m_paths.size();
        } else {
            m_index = (m_index + 1) % m_paths.size();
        }
    }
}

void CameraPathPlayback::Apply(SceneNode& node, SceneCamera& camera) const {
    if (empty()) return;
    const auto& path = m_paths[m_index];
    const auto sample = [this](const auto& curves) {
        return linalg::Vector3d(curves[0].Evaluate(m_seconds), curves[1].Evaluate(m_seconds),
                               curves[2].Evaluate(m_seconds));
    };
    const auto eye = sample(path.eye);
    const auto center = sample(path.center);
    const auto up = sample(path.up);
    if (!eye.allFinite() || !center.allFinite() || !up.allFinite()) return;
    const linalg::Vector3d backward = eye - center;
    if (backward.squaredNorm() < 1e-12) return;
    const linalg::Vector3d z = backward.normalized();
    const linalg::Vector3d right = up.cross(z);
    if (right.squaredNorm() < 1e-12) return;
    linalg::Matrix3d rotation;
    rotation.col(0) = right.normalized();
    rotation.col(1) = z.cross(rotation.col(0));
    rotation.col(2) = z;
    const linalg::Vector3d zyx = rotation.eulerAngles(2, 1, 0);
    node.SetTranslate(eye.cast<float>());
    node.SetRotation(linalg::Vector3f(zyx[2], zyx[1], zyx[0]));
    if (path.fov) {
        const double fov = path.fov->Evaluate(m_seconds);
        if (std::isfinite(fov) && fov > 0 && fov < 180) camera.SetFov(fov);
    }
}
} // namespace wallpaper
