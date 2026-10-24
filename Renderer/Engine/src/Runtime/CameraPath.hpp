#pragma once

#include "Runtime/ScalarAnimation.hpp"
#include "Utils/Linalg.hpp"
#include <array>
#include <optional>
#include <string_view>
#include <vector>

namespace wallpaper
{
class SceneNode;
class SceneCamera;

// Curves are decoded once, never from JSON on the frame path.
struct CameraPath {
    std::array<ScalarAnimation, 3> eye, center, up;
    std::optional<ScalarAnimation> fov;
    double duration { 0.0 };
    bool loop { false };
};

class CameraPathPlayback {
public:
    CameraPathPlayback() = default;
    CameraPathPlayback(std::vector<CameraPath> paths, std::string_view queue_mode);
    bool empty() const { return m_paths.empty(); }
    void Advance(double seconds);
    void Apply(SceneNode& node, SceneCamera& camera) const;

private:
    std::vector<CameraPath> m_paths;
    std::size_t m_index { 0 };
    double m_seconds { 0.0 };
    bool m_random { false };
};
} // namespace wallpaper
