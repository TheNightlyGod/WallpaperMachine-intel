// Pixel helpers for tests that look at what a scene draws.
//
// Written for this project's own tests; nothing here depends on the renderer, so a
// test of any kind can include it.
#pragma once

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace we_test
{

using Rgba = std::array<uint8_t, 4>;

/// An RGBA8 picture, four bytes per pixel, row 0 on top, straight (not premultiplied) alpha.
struct Image {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> rgba;

    [[nodiscard]] bool empty() const { return width == 0 || height == 0 || rgba.empty(); }
    [[nodiscard]] Rgba At(uint32_t x, uint32_t y) const;
    void               Set(uint32_t x, uint32_t y, Rgba value);

    static Image Solid(uint32_t width, uint32_t height, Rgba value);
    /// Four flat quadrants: top-left, top-right, bottom-left, bottom-right.
    static Image Quadrants(uint32_t width, uint32_t height, Rgba top_left, Rgba top_right,
                           Rgba bottom_left, Rgba bottom_right);
};

/// The mean of each channel over a rectangle, in 0..255. The rectangle is clipped to the image.
std::array<double, 4> RegionAverage(const Image& image, uint32_t x, uint32_t y, uint32_t width,
                                    uint32_t height);

/// The largest per-channel difference of any pixel; 256 when the sizes differ.
int MaxChannelDifference(const Image& a, const Image& b);

/// How many pixels differ by more than `tolerance` in at least one channel; every pixel when
/// the sizes differ.
std::size_t CountDifferingPixels(const Image& a, const Image& b, int tolerance = 0);

/// Success when the pixel at (x, y) is within `tolerance` of `expected` in every channel. The
/// failure message names the pixel, both colours and the picture size. Use as
/// `EXPECT_TRUE(ExpectPixel(...))`.
::testing::AssertionResult ExpectPixel(const Image& image, uint32_t x, uint32_t y, Rgba expected,
                                       int tolerance = 0);

/// Success when the average colour of the rectangle is within `tolerance` of `expected`.
::testing::AssertionResult ExpectRegionAverage(const Image& image, uint32_t x, uint32_t y,
                                               uint32_t width, uint32_t height, Rgba expected,
                                               double tolerance = 0.0);

/// Success when the two pictures have one size and no pixel differs by more than `tolerance`.
/// The failure message is compact: the first differing pixel, the counts and the largest
/// difference. No picture is written unless `WE_TEST_KEEP_PICTURES` names a directory (see
/// `KeepPicture`).
::testing::AssertionResult ExpectSamePicture(const Image& actual, const Image& expected,
                                             int tolerance = 0);

/// A one-line description of how two pictures differ ("identical" when they do not).
std::string DescribeDifference(const Image& actual, const Image& expected, int tolerance = 0);

/// Writes `image` as `<dir>/<name>.png` when the environment variable `WE_TEST_KEEP_PICTURES`
/// holds a directory, and does nothing otherwise. Returns whether a file was written.
bool KeepPicture(const std::string& name, const Image& image);

/// A PNG (zlib "stored" blocks, so no compressor is involved) holding `image`. Also what the
/// scene package uses for loose picture files.
std::string EncodePng(const Image& image);

} // namespace we_test
