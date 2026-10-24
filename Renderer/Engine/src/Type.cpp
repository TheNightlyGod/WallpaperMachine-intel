#include "Type.hpp"
#include <cmath>

float wallpaper::HalfFloatToFloat(uint16_t bits) {
    const auto sign = bits & 0x8000 ? -1.0f : 1.0f;
    const auto exponent = (bits >> 10) & 31;
    const auto fraction = bits & 1023;
    if (exponent == 0) return sign * std::ldexp(static_cast<float>(fraction), -24);
    if (exponent == 31) {
        return sign * (fraction == 0 ? INFINITY : NAN);
    }
    return sign * std::ldexp(static_cast<float>(1024 + fraction), exponent - 25);
}
