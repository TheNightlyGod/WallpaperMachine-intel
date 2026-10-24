// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#pragma once

#include <cfloat>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <string>
#include <string_view>

namespace wallpaper
{

// Reads the decimal number that opens `text` (after white space, with an optional sign, a
// fraction and an exponent) and moves `position` just past it. Anything else, a number that
// does not fit a 32-bit float included, fails and leaves `position` where it was.
inline bool ReadLeadingNumber(std::string_view text, std::size_t& position, float& out) {
    const auto is_digit = [](char c) { return c >= '0' && c <= '9'; };
    std::size_t at = position;
    while (at < text.size() &&
           (text[at] == ' ' || text[at] == '\t' || text[at] == '\n' || text[at] == '\r' ||
            text[at] == '\f' || text[at] == '\v'))
        ++at;
    const std::size_t start = at;
    if (at < text.size() && (text[at] == '+' || text[at] == '-')) ++at;
    std::size_t digits = 0;
    while (at < text.size() && is_digit(text[at])) ++at, ++digits;
    if (at < text.size() && text[at] == '.') {
        ++at;
        while (at < text.size() && is_digit(text[at])) ++at, ++digits;
    }
    if (digits == 0) return false;
    if (at < text.size() && (text[at] == 'e' || text[at] == 'E')) {
        std::size_t exponent = at + 1;
        if (exponent < text.size() && (text[exponent] == '+' || text[exponent] == '-')) ++exponent;
        if (exponent < text.size() && is_digit(text[exponent])) {
            while (exponent < text.size() && is_digit(text[exponent])) ++exponent;
            at = exponent;
        }
    }
    const std::string span(text.substr(start, at - start));
    const double      value = std::strtod(span.c_str(), nullptr);
    if (!std::isfinite(value) || std::fabs(value) > static_cast<double>(FLT_MAX)) return false;
    out      = static_cast<float>(value);
    position = at;
    return true;
}

// The number a text opens with, 0 when it opens with anything else.
inline float LeadingNumberOrZero(std::string_view text) {
    std::size_t position = 0;
    float       value    = 0.0f;
    return ReadLeadingNumber(text, position, value) ? value : 0.0f;
}

// Up to `count` numbers separated by white space, in order. Reading stops at the first one that
// cannot be read: it and every later one stay 0. Returns how many were read.
inline std::size_t ReadNumberList(std::string_view text, float* out, std::size_t count) {
    for (std::size_t i = 0; i < count; ++i) out[i] = 0.0f;
    std::size_t position = 0;
    std::size_t read     = 0;
    while (read < count && ReadLeadingNumber(text, position, out[read])) ++read;
    for (std::size_t i = read; i < count; ++i) out[i] = 0.0f;
    return read;
}

} // namespace wallpaper
