#include "Media/Rational.hpp"

#include <numeric>

namespace wallpaper::media
{
namespace
{
__extension__ typedef __int128 Int128;
}

Rational MakeRational(std::int64_t numerator, std::int64_t denominator)
{
    if (denominator == 0) return {};
    // Negating INT64_MIN overflows; such a value is not a time anyone stores.
    if (numerator == INT64_MIN || denominator == INT64_MIN) return {};
    if (denominator < 0) {
        numerator   = -numerator;
        denominator = -denominator;
    }
    const std::int64_t divisor = std::gcd(numerator < 0 ? -numerator : numerator, denominator);
    return { numerator / divisor, denominator / divisor };
}

int CompareRational(const Rational& a, const Rational& b)
{
    const Int128 left  = static_cast<Int128>(a.numerator) * b.denominator;
    const Int128 right = static_cast<Int128>(b.numerator) * a.denominator;
    return left < right ? -1 : (left > right ? 1 : 0);
}

} // namespace wallpaper::media
