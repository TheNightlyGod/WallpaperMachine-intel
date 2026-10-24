#pragma once
#include <cstdint>
#include <cuchar>
#include <cstddef>

namespace wallpaper
{

// Fixed-width integers, named by sign and bit count.
using i8  = std::int8_t;
using u8  = std::uint8_t;
using i16 = std::int16_t;
using u16 = std::uint16_t;
using i32 = std::int32_t;
using u32 = std::uint32_t;
using i64 = std::int64_t;
using u64 = std::uint64_t;

// Sizes and offsets into memory or a stream. `idx` and `isize` are the signed
// forms, `usize` the unsigned one.
using usize = std::size_t;
using isize = std::ptrdiff_t;
using idx   = std::ptrdiff_t;

} // namespace wallpaper
