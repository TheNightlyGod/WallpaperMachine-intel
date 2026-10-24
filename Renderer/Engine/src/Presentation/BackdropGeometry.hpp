#pragma once

#include "Presentation/WallpaperScaling.hpp"

#include <array>
#include <cstdint>
#include <vector>

namespace wallpaper
{

/// The (up to four) rectangles of a display the picture does not cover, in display pixels
/// with the origin at the top left. The backdrop is drawn into these and nowhere else, so the
/// picture's own pixels are never touched by it.
struct SurroundBands {
    std::array<PixelRect, 4> rects {};
    int                      count { 0 };
};

/// `display` minus `picture`. The picture is clipped to the display first, so a picture that
/// is moved or scaled past an edge leaves a band only where the display really shows nothing
/// of it. The bands never overlap each other or the picture; a picture that covers the
/// display leaves none, one that covers nothing leaves the whole display.
SurroundBands ComputeSurroundBands(const PixelRect& display, const PixelRect& picture);

/// One reduction of the picture towards the small image the backdrop is blurred from.
struct BackdropReductionStep {
    uint32_t width { 0 };
    uint32_t height { 0 };
    /// Held in an 8-bit image; the last step is always half-float.
    bool     eight_bit { false };
    /// Bilinear taps per destination texel along each axis, spread evenly over the texel's
    /// footprint in the source.
    uint32_t taps_x { 1 };
    uint32_t taps_y { 1 };
    /// Source texels between two neighbouring taps along each axis: at most
    /// `kBackdropMaxTapSpacing`, so only a fraction of the source texels are read.
    double   spacing_x { 1.0 };
    double   spacing_y { 1.0 };
};

constexpr uint32_t kBackdropLongSide     = 128;
/// Pictures longer than this are first reduced to an eighth of their size in an 8-bit image.
constexpr uint32_t kBackdropLargeSide    = 1024;
constexpr double   kBackdropMaxTapSpacing = 4.0;

/// The reductions from a picture of this size down to an image `kBackdropLongSide` texels on
/// its longer side: one step, or two for a picture longer than `kBackdropLargeSide`.
std::vector<BackdropReductionStep> PlanBackdropReduction(uint32_t width, uint32_t height);

} // namespace wallpaper
