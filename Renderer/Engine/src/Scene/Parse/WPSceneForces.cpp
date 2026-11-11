#include "Scene/SceneForces.hpp"
#include "Particle/ParticleNoise.h"

#include <algorithm>
#include <cmath>

namespace wallpaper {
linalg::Vector3f SceneForceState::Gravity() const noexcept {
    // Scene interface +48, sub_1401988E0: raw vector times raw strength.
    return linalg::Vector3f(gravity_direction.data()) * gravity_strength;
}

linalg::Vector3f SceneForceState::WindAt(float world_x, float elapsed) const noexcept {
    // Scene interface +56, sub_140198910: only world x and elapsed scene time
    // enter this field. The width is the authored orthogonal canvas width,
    // not a texture size, layer scale, viewport width, or projection zoom.
    if (!wind_enabled || canvas_width <= 0 || !std::isfinite(canvas_width) ||
        !std::isfinite(world_x) || !std::isfinite(elapsed)) return linalg::Vector3f::Zero();
    const float position = (world_x / canvas_width) * 10.0f;
    if (!std::isfinite(position)) return linalg::Vector3f::Zero();
    const float pulse = std::max(0.0f, ParticleNoise::Simplex2(elapsed, position));
    // Match the reference's multiplication order (direction is not normalized).
    return linalg::Vector3f(pulse * wind_direction[0] * wind_strength,
                            pulse * wind_direction[1] * wind_strength,
                            pulse * wind_direction[2] * wind_strength);
}
} // namespace wallpaper
