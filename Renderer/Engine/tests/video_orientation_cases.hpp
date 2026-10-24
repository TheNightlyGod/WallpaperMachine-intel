#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#ifdef __OBJC__
#include <CoreVideo/CoreVideo.h>
#include <cstring>
#endif

namespace wallpaper::video::testing_media
{
struct OrientationCase {
    const char* name;
    int32_t a, b, c, d;
    std::array<size_t, 4> source_quadrants;
    bool swaps_axes;
    std::array<int32_t, 9> matrix() const {
        return {a * 65536, b * 65536, 0, c * 65536, d * 65536, 0, 0, 0, 1 << 30};
    }
};
inline constexpr std::array<OrientationCase, 8> kOrientations {{
    {"identity", 1, 0, 0, 1, {0, 1, 2, 3}, false},
    {"rotate90", 0, 1, -1, 0, {2, 0, 3, 1}, true},
    {"rotate180", -1, 0, 0, -1, {3, 2, 1, 0}, false},
    {"rotate270", 0, -1, 1, 0, {1, 3, 0, 2}, true},
    {"mirrorX", -1, 0, 0, 1, {1, 0, 3, 2}, false},
    {"mirrorY", 1, 0, 0, -1, {2, 3, 0, 1}, false},
    {"transpose", 0, 1, 1, 0, {0, 2, 1, 3}, true},
    {"transverse", 0, -1, -1, 0, {3, 1, 2, 0}, true},
}};
inline constexpr std::array<uint8_t, 4> kQuadrantLuma {32, 96, 160, 224};

#ifdef __OBJC__
inline bool FillVideoQuadrants(CVPixelBufferRef buffer) {
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) return false;
    const size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    const bool planar = CVPixelBufferIsPlanar(buffer);
    auto* pixels = static_cast<uint8_t*>(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer));
    const auto stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        const auto value = kQuadrantLuma[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)];
        if (planar) pixels[y * stride + x] = value;
        else {
            auto* pixel = pixels + y * stride + x * 4;
            pixel[0] = pixel[1] = pixel[2] = value; pixel[3] = 255;
        }
    }
    if (planar) {
        auto* chroma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
        for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(buffer, 1); ++y) {
            std::memset(chroma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), 128,
                        CVPixelBufferGetWidthOfPlane(buffer, 1) * 2);
        }
    }
    return CVPixelBufferUnlockBaseAddress(buffer, 0) == kCVReturnSuccess;
}
#endif
} // namespace wallpaper::video::testing_media
