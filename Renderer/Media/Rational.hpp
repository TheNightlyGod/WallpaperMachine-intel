// An exact fraction, used where a container's integer timescale should reach the
// pacing code without a floating-point round trip (a frame period of 1001/30000
// seconds stays exactly that).
#pragma once

#include <cstdint>

namespace wallpaper::media
{

struct Rational {
    std::int64_t numerator { 0 };
    /// Positive for a valid value; 0 marks "unknown".
    std::int64_t denominator { 0 };

    bool valid() const { return denominator > 0; }
    double toDouble() const
    {
        return valid() ? static_cast<double>(numerator) / static_cast<double>(denominator) : 0.0;
    }
};

/// `numerator / denominator` in lowest terms with a positive denominator; an
/// invalid Rational when `denominator` is 0.
Rational MakeRational(std::int64_t numerator, std::int64_t denominator);

/// Orders two valid fractions exactly: negative, zero or positive.
int CompareRational(const Rational& a, const Rational& b);

inline bool operator==(const Rational& a, const Rational& b)
{
    return a.valid() == b.valid() && (! a.valid() || CompareRational(a, b) == 0);
}
inline bool operator!=(const Rational& a, const Rational& b) { return ! (a == b); }

} // namespace wallpaper::media
