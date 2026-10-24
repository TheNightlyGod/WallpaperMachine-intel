#include "Media/Checked.hpp"

namespace wallpaper::media
{
namespace
{
__extension__ typedef __int128 Int128;
}

bool RescaleRound(std::int64_t value, std::int64_t numerator, std::int64_t denominator,
                  std::int64_t* out)
{
    if (denominator <= 0) return false;
    const Int128 product = static_cast<Int128>(value) * numerator;
    const Int128 half    = denominator / 2;
    const Int128 rounded = (product >= 0 ? product + half : product - half) / denominator;
    if (rounded > INT64_MAX || rounded < INT64_MIN) return false;
    *out = static_cast<std::int64_t>(rounded);
    return true;
}

} // namespace wallpaper::media
