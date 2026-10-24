// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#pragma once
#include <functional>
#include <cassert>
#include <cmath>
#include "Utils/Linalg.hpp"

#include "Core/Literals.hpp"

namespace wallpaper
{
namespace algorism
{
double CalculatePersperctiveDistance(double fov, double height) noexcept;

constexpr bool IsPowOfTwo(u32 x) {
    // Exactly one bit set, and not the unit: 0 and 1 do not count.
    return x > 1 && (x & (x - 1)) == 0;
}

constexpr double lerp(double t, double a, double b) noexcept {
    return a + t * (b - a);
}

double PerlinNoise(double x, double y, double z) noexcept;

inline linalg::Vector3d CurlNoise(linalg::Vector3d p) noexcept {
    // Central differences of the vector noise, one step either side on each axis.
    constexpr double kStep = 1e-5;
    const auto vector_noise = [](double x, double y, double z) {
        return linalg::Vector3d(PerlinNoise(x, y, z),
                                PerlinNoise(x + 89.2, y + 33.1, z + 57.3),
                                PerlinNoise(x + 100.3, y + 120.1, z + 142.2));
    };
    const double x = p(0), y = p(1), z = p(2);
    const linalg::Vector3d dx = vector_noise(x + kStep, y, z) - vector_noise(x - kStep, y, z);
    const linalg::Vector3d dy = vector_noise(x, y + kStep, z) - vector_noise(x, y - kStep, z);
    const linalg::Vector3d dz = vector_noise(x, y, z + kStep) - vector_noise(x, y, z - kStep);
    return linalg::Vector3d(dy(2) - dz(1), dz(0) - dx(2), dx(1) - dy(0)) / (2.0 * kStep);
}

} // namespace algorism
} // namespace wallpaper
