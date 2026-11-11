#pragma once

#include "Utils/Linalg.hpp"
#include <array>

namespace wallpaper {
// Shared only by consumers of the scene's force interface. Authored directions
// are not unit vectors: their magnitude remains part of the applied force.
struct SceneForceState {
    bool wind_enabled { false };
    std::array<float, 3> wind_direction { 0.70710677f, 0.70710677f, 0.0f };
    float wind_strength { 1.0f };
    std::array<float, 3> gravity_direction { 0.0f, -1.0f, 0.0f };
    float gravity_strength { 1.0f };
    float canvas_width { 0.0f };

    linalg::Vector3f Gravity() const noexcept;
    linalg::Vector3f WindAt(float world_x, float elapsed) const noexcept;
};
} // namespace wallpaper
