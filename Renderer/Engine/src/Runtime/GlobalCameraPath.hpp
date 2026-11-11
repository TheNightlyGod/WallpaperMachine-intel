#pragma once

#include <array>
#include <utility>
#include <vector>

namespace wallpaper {
// The scene camera's legacy paths are separate from camera-layer animation curves.
struct GlobalCameraKey {
    float timestamp { 0 };
    std::array<double, 10> pose { 0,0,0, 0,0,-1, 0,1,0, 1 };
};
struct GlobalCameraPath {
    float duration { 0 };
    std::vector<GlobalCameraKey> keys;
};

class GlobalCameraPlayback {
public:
    GlobalCameraPlayback() = default;
    explicit GlobalCameraPlayback(std::vector<GlobalCameraPath> paths) : m_paths(std::move(paths)) {}
    bool empty() const { return m_paths.empty(); }
    std::array<double,10> Sample() const;
    void Advance(double seconds);
    double FadeAlpha() const;
private:
    std::vector<GlobalCameraPath> m_paths;
    std::size_t m_path { 0 }, m_key { 0 };
    float m_seconds { 0 };
};
} // namespace wallpaper
