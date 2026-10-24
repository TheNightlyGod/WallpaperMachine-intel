// Overflow-checked integer arithmetic for sizes and times read from untrusted
// files. Every helper returns false and leaves `out` unspecified on overflow.
// They use the Clang/GCC builtins: the engine already builds with Clang only.
#pragma once

#include <cstdint>
#include <type_traits>

namespace wallpaper::media
{

template<typename T>
bool CheckedAdd(T a, T b, T* out)
{
    static_assert(std::is_integral_v<T>);
    return ! __builtin_add_overflow(a, b, out);
}

template<typename T>
bool CheckedSub(T a, T b, T* out)
{
    static_assert(std::is_integral_v<T>);
    return ! __builtin_sub_overflow(a, b, out);
}

template<typename T>
bool CheckedMul(T a, T b, T* out)
{
    static_assert(std::is_integral_v<T>);
    return ! __builtin_mul_overflow(a, b, out);
}

/// `value * numerator / denominator`, rounded to nearest with ties away from
/// zero, computed without overflowing a 64-bit intermediate. False when
/// `denominator` is not positive or the result does not fit.
bool RescaleRound(std::int64_t value, std::int64_t numerator, std::int64_t denominator,
                  std::int64_t* out);

} // namespace wallpaper::media
