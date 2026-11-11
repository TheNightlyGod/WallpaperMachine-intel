#include "GlobalCameraPath.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Parse/wpscene/WPObjectSchema.hpp"

#include <algorithm>
#include <cmath>
#include <nlohmann/json.hpp>

namespace wallpaper {
std::vector<GlobalCameraPath> ParseGlobalCameraPaths(const nlohmann::json& document) {
    std::vector<GlobalCameraPath> result;
    const auto paths = document.find("paths");
    if (paths == document.end() || !paths->is_array()) return result;
    for (const auto& entry : *paths) {
        if (!entry.is_object()) continue;
        if (entry.contains("disabled") && entry["disabled"] == true) continue;
        const auto duration = entry.find("duration"), transforms = entry.find("transforms");
        if (duration == entry.end() || !duration->is_number() || transforms == entry.end() ||
            !transforms->is_array()) continue;
        GlobalCameraPath path;
        path.duration = duration->get<float>();
        if (!std::isfinite(path.duration) || path.duration <= 0) continue;
        for (std::size_t index = 0; index < transforms->size(); ++index) {
            const auto& frame = (*transforms)[index];
            if (!frame.is_object() || (frame.contains("disabled") && frame["disabled"] == true)) continue;
            GlobalCameraKey key;
            key.timestamp = transforms->size() > 1
                ? float(index) / float(transforms->size() - 1) * path.duration : 0;
            if (frame.contains("timestamp") && frame["timestamp"].is_number())
                key.timestamp = frame["timestamp"].get<float>();
            bool valid = std::isfinite(key.timestamp);
            for (std::size_t group = 0; group < 3; ++group) {
                const char* field = group == 0 ? "eye" : group == 1 ? "center" : "up";
                std::array<float,3> value {};
                // WE initializes each missing pose vector to zero; present but
                // malformed/non-finite input still cannot produce a usable pose.
                if (frame.contains(field) && !wpscene::ReadStrictVec(frame[field], value)) {
                    valid = false; break;
                }
                for (std::size_t lane = 0; lane < 3; ++lane) key.pose[group * 3 + lane] = value[lane];
            }
            if (frame.contains("zoom") && frame["zoom"].is_number()) key.pose[9] = frame["zoom"].get<double>();
            valid = valid && std::all_of(key.pose.begin(), key.pose.end(), [](double x) { return std::isfinite(x); });
            if (!valid || key.pose[9] <= 0 || (!path.keys.empty() && key.timestamp <= path.keys.back().timestamp)) continue;
            path.keys.push_back(key);
        }
        if (!path.keys.empty()) result.push_back(std::move(path));
    }
    return result;
}

std::array<double,10> GlobalCameraPlayback::Sample() const {
    if (empty()) return GlobalCameraKey{}.pose;
    const auto& keys = m_paths[m_path].keys;
    const auto& first = keys[m_key];
    auto pose = first.pose;
    if (m_seconds < first.timestamp || m_key + 1 >= keys.size()) return pose;
    const auto& next = keys[m_key + 1];
    const double t = (m_seconds - first.timestamp) / (next.timestamp - first.timestamp);
    // WE 0x1401891A0 uses half the endpoint difference for both Hermite tangents.
    const double blend = -t*t*t + 1.5*t*t + 0.5*t;
    for (std::size_t lane = 0; lane < pose.size(); ++lane)
        pose[lane] += (next.pose[lane] - pose[lane]) * blend;
    return pose;
}

void GlobalCameraPlayback::Advance(double seconds) {
    if (empty() || !std::isfinite(seconds) || seconds <= 0) return;
    const auto& path = m_paths[m_path];
    const auto& first = path.keys[m_key];
    const bool next = m_key + 1 < path.keys.size();
    float threshold = next ? path.keys[m_key + 1].timestamp : path.duration - first.timestamp;
    if (m_seconds < first.timestamp) threshold = first.timestamp + (next ? path.keys[m_key + 1].timestamp : 0);
    // scene+236 is a float in WE: its rounding decides the strict cut boundary.
    m_seconds += static_cast<float>(seconds);
    if (m_seconds <= threshold) return;
    if (!next || path.keys[m_key + 1].timestamp >= path.duration) {
        m_key = 0;
        m_seconds = 0;
        m_path = (m_path + 1) % m_paths.size();
    } else {
        ++m_key;
    }
}

double GlobalCameraPlayback::FadeAlpha() const {
    if (empty()) return 0;
    const double remaining = m_paths[m_path].duration - m_seconds;
    // The end ramp wins when a segment shorter than one second overlaps both windows.
    if (remaining < 0.5) return 1 - 2*remaining;
    return m_seconds < 0.5 ? 1 - 2*m_seconds : 0;
}
} // namespace wallpaper
