#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>

namespace wallpaper::video
{
struct VideoDisplayTransform {
    // Normalized displayed coordinates -> normalized decoder coordinates.
    std::array<float, 4> matrix {1, 0, 0, 1};
    std::array<float, 2> offset {0, 0};
    uint32_t width {0};
    uint32_t height {0};

    bool identity() const {
        return matrix == std::array<float, 4> {1, 0, 0, 1} && offset == std::array<float, 2> {0, 0};
    }
};

// A track's affine display matrix uses 16.16 coefficients and a 2.30
// homogeneous scale. Translation disappears when the transformed image is
// normalized to its bounding rectangle; rotation, scale and reflection remain.
inline std::optional<VideoDisplayTransform> ResolveVideoDisplayTransform(
    const std::array<int32_t, 9>& matrix, uint32_t width, uint32_t height) {
    if (width == 0 || height == 0 || matrix[2] != 0 || matrix[5] != 0 || matrix[8] == 0) return std::nullopt;
    const double homogeneous = double(matrix[8]) / double(uint64_t {1} << 30);
    const double a = double(matrix[0]) / 65536.0 / homogeneous;
    const double b = double(matrix[1]) / 65536.0 / homogeneous;
    const double c = double(matrix[3]) / 65536.0 / homogeneous;
    const double d = double(matrix[4]) / 65536.0 / homogeneous;
    const double determinant = a * d - b * c;
    const double out_width = std::abs(a) * width + std::abs(c) * height;
    const double out_height = std::abs(b) * width + std::abs(d) * height;
    if (! std::isfinite(determinant) || std::abs(determinant) < 1e-12 ||
        ! std::isfinite(out_width) || ! std::isfinite(out_height) ||
        out_width < 1.0 || out_height < 1.0 ||
        out_width > std::numeric_limits<int32_t>::max() || out_height > std::numeric_limits<int32_t>::max()) return std::nullopt;
    const double left = std::min(0.0, a * width) + std::min(0.0, c * height);
    const double top = std::min(0.0, b * width) + std::min(0.0, d * height);
    return VideoDisplayTransform {
        .matrix = {float(d * out_width / (determinant * width)), float(-c * out_height / (determinant * width)),
                   float(-b * out_width / (determinant * height)), float(a * out_height / (determinant * height))},
        .offset = {float((d * left - c * top) / (determinant * width)),
                   float((-b * left + a * top) / (determinant * height))},
        .width = static_cast<uint32_t>(std::ceil(out_width)),
        .height = static_cast<uint32_t>(std::ceil(out_height)),
    };
}

struct alignas(16) VideoTransformUniforms {
    std::array<float, 4> matrix {1, 0, 0, 1};
    std::array<float, 2> offset {0, 0};
    std::array<float, 2> padding {};
};
static_assert(sizeof(VideoTransformUniforms) == 32);

inline VideoTransformUniforms VideoTransformConstants(const VideoDisplayTransform& transform) {
    return { .matrix = transform.matrix, .offset = transform.offset };
}
} // namespace wallpaper::video
