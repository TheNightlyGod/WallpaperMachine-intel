#include "Presentation/BackdropGeometry.hpp"

#include <algorithm>
#include <cmath>

namespace wallpaper
{

SurroundBands ComputeSurroundBands(const PixelRect& display, const PixelRect& picture)
{
    SurroundBands bands;
    const auto    add = [&](int x, int y, int width, int height) {
        if (width > 0 && height > 0) bands.rects[bands.count++] = PixelRect { x, y, width, height };
    };

    const int left   = std::max(display.x, picture.x);
    const int top    = std::max(display.y, picture.y);
    const int right  = std::min(display.x + display.width, picture.x + picture.width);
    const int bottom = std::min(display.y + display.height, picture.y + picture.height);
    if (right <= left || bottom <= top) {
        add(display.x, display.y, display.width, display.height);
        return bands;
    }

    // Full-width strips above and below, then what is left of the picture's own rows.
    add(display.x, display.y, display.width, top - display.y);
    add(display.x, bottom, display.width, display.y + display.height - bottom);
    add(display.x, top, left - display.x, bottom - top);
    add(right, top, display.x + display.width - right, bottom - top);
    return bands;
}

namespace
{

BackdropReductionStep StepBetween(uint32_t from_w, uint32_t from_h, uint32_t to_w, uint32_t to_h, bool eight_bit)
{
    const auto taps = [](double ratio) {
        return std::max<uint32_t>(1, static_cast<uint32_t>(std::ceil(ratio / kBackdropMaxTapSpacing - 1e-9)));
    };
    const double ratio_x = static_cast<double>(from_w) / to_w;
    const double ratio_y = static_cast<double>(from_h) / to_h;

    BackdropReductionStep step;
    step.width     = to_w;
    step.height    = to_h;
    step.eight_bit = eight_bit;
    step.taps_x    = taps(ratio_x);
    step.taps_y    = taps(ratio_y);
    step.spacing_x = ratio_x / step.taps_x;
    step.spacing_y = ratio_y / step.taps_y;
    return step;
}

uint32_t Scaled(uint32_t value, double factor)
{
    return std::max<uint32_t>(1, static_cast<uint32_t>(std::lround(value * factor)));
}

} // namespace

std::vector<BackdropReductionStep> PlanBackdropReduction(uint32_t width, uint32_t height)
{
    width  = std::max<uint32_t>(1, width);
    height = std::max<uint32_t>(1, height);

    const double to_long = static_cast<double>(kBackdropLongSide) / std::max(width, height);
    const uint32_t final_w = width >= height ? kBackdropLongSide : Scaled(width, to_long);
    const uint32_t final_h = height > width ? kBackdropLongSide : Scaled(height, to_long);

    std::vector<BackdropReductionStep> steps;
    uint32_t from_w = width, from_h = height;
    if (std::max(width, height) > kBackdropLargeSide) {
        const uint32_t eighth_w = Scaled(width, 1.0 / 8.0);
        const uint32_t eighth_h = Scaled(height, 1.0 / 8.0);
        steps.push_back(StepBetween(from_w, from_h, eighth_w, eighth_h, true));
        from_w = eighth_w;
        from_h = eighth_h;
    }
    steps.push_back(StepBetween(from_w, from_h, final_w, final_h, false));
    return steps;
}

} // namespace wallpaper
