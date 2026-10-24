#pragma once
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <vector>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <exception>
#include <stdexcept>
#include "Utils/Logging.h"
#include "Utils/Identity.hpp"

#define STRTONUM(s, num) utils::StrToNum(s, num, __SHORT_FILE__, __LINE__);

namespace utils
{

// Outcome of reading a number from the front of a text.
enum class NumParse
{
    Ok,
    NotANumber,  // no numeric prefix at all
    TooLarge,    // a numeric prefix that does not fit the target type
    Unsupported, // the target type is not a number type this reader knows
};

namespace detail
{
// The C library readers want a terminated buffer and skip leading white space on
// their own; a view is not terminated, so every read works on a short copy.
inline bool HasMinusSign(const std::string& text) {
    const char* p = text.c_str();
    while (*p == ' ' || (*p >= '\t' && *p <= '\r')) ++p;
    return *p == '-';
}

template<typename TInt>
NumParse ReadSigned(std::string_view text, TInt& out) {
    const std::string copy { text };
    char*             end = nullptr;
    errno                 = 0;
    const long long v     = std::strtoll(copy.c_str(), &end, 10);
    if (end == copy.c_str()) return NumParse::NotANumber;
    if (errno == ERANGE || v < std::numeric_limits<TInt>::min() ||
        v > std::numeric_limits<TInt>::max())
        return NumParse::TooLarge;
    out = static_cast<TInt>(v);
    return NumParse::Ok;
}
} // namespace detail

template<typename TNum>
NumParse _StrToNum(std::string_view, TNum&) {
    return NumParse::Unsupported;
}

template<>
inline NumParse _StrToNum<int32_t>(std::string_view text, int32_t& out) {
    return detail::ReadSigned(text, out);
}

template<>
inline NumParse _StrToNum<uint32_t>(std::string_view text, uint32_t& out) {
    const std::string copy { text };
    char*             end = nullptr;
    errno                 = 0;
    const unsigned long long v = std::strtoull(copy.c_str(), &end, 10);
    if (end == copy.c_str()) return NumParse::NotANumber;
    if (errno == ERANGE) return NumParse::TooLarge;
    constexpr unsigned long long kMax = std::numeric_limits<uint32_t>::max();
    if (detail::HasMinusSign(copy)) {
        // strtoull negates in 64 bits; undo that to get the magnitude, then wrap
        // in 32 bits the way the C library does for a 32-bit unsigned long.
        const unsigned long long magnitude = 0ull - v;
        if (magnitude > kMax) return NumParse::TooLarge;
        out = static_cast<uint32_t>(0u - static_cast<uint32_t>(magnitude));
        return NumParse::Ok;
    }
    if (v > kMax) return NumParse::TooLarge;
    out = static_cast<uint32_t>(v);
    return NumParse::Ok;
}

template<>
inline NumParse _StrToNum<float>(std::string_view text, float& out) {
    const std::string copy { text };
    char*             end = nullptr;
    errno                 = 0;
    const float v         = std::strtof(copy.c_str(), &end);
    if (end == copy.c_str() || std::isnan(v)) return NumParse::NotANumber;
    if (std::isinf(v)) return NumParse::TooLarge;
    out = v;
    return NumParse::Ok;
}

// Reads the number at the front of `text` into `num`. A text without a number, or
// with one that does not fit, logs an error and leaves `num` as it was.
template<typename TNum>
void StrToNum(std::string_view text, TNum& num, const char* file, int line) {
    switch (_StrToNum<TNum>(text, num)) {
    case NumParse::NotANumber:
        WallpaperLog(LOGLEVEL_ERROR, file, line, "not a number: \"%.*s\"",
                     static_cast<int>(text.size()), text.data());
        break;
    case NumParse::TooLarge:
        WallpaperLog(LOGLEVEL_ERROR, file, line, "number too large: \"%.*s\"",
                     static_cast<int>(text.size()), text.data());
        break;
    case NumParse::Ok:
    case NumParse::Unsupported: break;
    }
}

// Every field of `text` between single `sep` characters, empty fields kept. An empty
// text is one empty field.
inline std::vector<std::string> SpliteString(std::string text, char sep) {
    std::vector<std::string> fields;
    std::size_t              begin = 0;
    for (;;) {
        const std::size_t at = text.find(sep, begin);
        if (at == std::string::npos) {
            fields.emplace_back(text, begin);
            return fields;
        }
        fields.emplace_back(text, begin, at - begin);
        begin = at + 1;
    }
}

namespace StrToArray
{
struct WrongSizeExp : public std::exception {
    const char* what() const throw() {
        return "the text holds a different number of fields than the array has elements";
    }
};

namespace detail
{
// Reads every space-separated field as a T. Nothing is returned unless all of them
// read, so a failing text never leaves a half-filled target behind.
template<typename T>
bool ReadFields(const std::vector<std::string>& fields, std::vector<T>& values) {
    values.clear();
    values.reserve(fields.size());
    for (const auto& field : fields) {
        T value {};
        if (_StrToNum<T>(field, value) != NumParse::Ok) {
            LOG_ERROR("can't read \"%s\" as a number", field.c_str());
            return false;
        }
        values.push_back(value);
    }
    return true;
}
} // namespace detail

template<typename T>
bool Convert(const std::string& text, std::vector<T>& out) {
    std::vector<T> values;
    if (! detail::ReadFields(SpliteString(text, ' '), values)) return false;
    out = std::move(values);
    return true;
}
template<typename T, std::size_t N>
bool Convert(const std::string& text, std::array<T, N>& out) {
    const auto fields = SpliteString(text, ' ');
    if (fields.size() != N) throw WrongSizeExp {};
    std::vector<T> values;
    if (! detail::ReadFields(fields, values)) return false;
    std::copy(values.begin(), values.end(), out.begin());
    return true;
}

} // namespace StrToArray
} // namespace utils
