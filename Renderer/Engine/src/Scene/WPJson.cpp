// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#include "WPJson.hpp"
#include <nlohmann/json.hpp>

#include <array>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>

#include "Utils/Identity.hpp"
#include "Utils/String.h"

namespace wallpaper
{

namespace
{
// Wallpaper Engine accepts a comma before the `]` or `}` that closes an array
// or object, and ships documents that rely on it: its own fluid simulation
// effect is one, and workshop packages copy it. Strict parsing dropped every
// such effect. This removes those commas, leaving strings untouched, so the
// document reads as Wallpaper Engine reads it.
std::string WithoutTrailingCommas(const std::string& source) {
    std::string out;
    out.reserve(source.size());
    bool in_string = false;
    bool escaped   = false;
    for (std::size_t i = 0; i < source.size(); ++i) {
        const char c = source[i];
        if (in_string) {
            out.push_back(c);
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true;
        if (c == ',') {
            std::size_t next = i + 1;
            while (next < source.size() && std::isspace(static_cast<unsigned char>(source[next])))
                ++next;
            if (next < source.size() && (source[next] == ']' || source[next] == '}')) continue;
        }
        out.push_back(c);
    }
    return out;
}
} // namespace

bool ParseJson(const char* file, const char* func, int line, const std::string& source,
               nlohmann::json& result) {
    std::string message;
    try {
        result = nlohmann::json::parse(source);
        return true;
    } catch (const nlohmann::json::exception& e) {
        message = e.what();
    }
    // Only a document strict parsing rejected pays for the second pass.
    try {
        auto lenient = nlohmann::json::parse(WithoutTrailingCommas(source), nullptr, false);
        if (! lenient.is_discarded()) {
            result = std::move(lenient);
            return true;
        }
    } catch (...) {
    }
    WallpaperLog(LOGLEVEL_ERROR, file, line, "%s: json parse failed: %s", func, message.c_str());
    return false;
}

namespace
{
// ---- reading one node -------------------------------------------------------

// The text of a node for a log line; never throws, whatever bytes the node holds.
std::string NodeText(const nlohmann::json& node) {
    try {
        return node.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
    } catch (...) {
        return "<unprintable>";
    }
}

struct CallSite {
    const char*      file;
    const char*      func;
    int              line;
    std::string_view key;
};

void LogMismatch(const CallSite& at, const nlohmann::json& node) {
    WallpaperLog(LOGLEVEL_INFO,
                 at.file,
                 at.line,
                 "%s: \"%.*s\" has an unexpected type: %s",
                 at.func,
                 static_cast<int>(at.key.size()),
                 at.key.data(),
                 NodeText(node).c_str());
}

void LogBadText(const CallSite& at, const char* what, const std::string& text) {
    WallpaperLog(LOGLEVEL_ERROR,
                 at.file,
                 at.line,
                 "%s: \"%.*s\" %s: %s",
                 at.func,
                 static_cast<int>(at.key.size()),
                 at.key.data(),
                 what,
                 text.c_str());
}

// A number held by a node, as the widest value that keeps it exactly.
struct Num {
    enum Kind { Signed, Unsigned, Real } kind { Real };
    std::int64_t  s { 0 };
    std::uint64_t u { 0 };
    double        d { 0 };
};

bool NumberOf(const nlohmann::json& node, Num& out) {
    if (node.is_number_unsigned()) {
        out.kind = Num::Unsigned;
        out.u    = node.get<std::uint64_t>();
    } else if (node.is_number_integer()) {
        out.kind = Num::Signed;
        out.s    = node.get<std::int64_t>();
    } else if (node.is_number_float()) {
        out.kind = Num::Real;
        out.d    = node.get<double>();
    } else if (node.is_boolean()) {
        out.kind = Num::Signed;
        out.s    = node.get<bool>() ? 1 : 0;
    } else {
        return false;
    }
    return true;
}

// Integer targets truncate toward zero and saturate at the type's limits.
template<typename I>
I ToInteger(const Num& n) {
    constexpr I lo = std::numeric_limits<I>::min();
    constexpr I hi = std::numeric_limits<I>::max();
    switch (n.kind) {
    case Num::Signed:
        if (n.s < static_cast<std::int64_t>(lo)) return lo;
        if (n.s > static_cast<std::int64_t>(hi)) return hi;
        return static_cast<I>(n.s);
    case Num::Unsigned:
        return n.u > static_cast<std::uint64_t>(hi) ? hi : static_cast<I>(n.u);
    case Num::Real:
        if (std::isnan(n.d)) return 0;
        if (n.d <= static_cast<double>(lo)) return lo;
        if (n.d >= static_cast<double>(hi)) return hi;
        return static_cast<I>(n.d);
    }
    return 0;
}

template<typename F>
F ToReal(const Num& n) {
    switch (n.kind) {
    case Num::Signed: return static_cast<F>(n.s);
    case Num::Unsigned: return static_cast<F>(n.u);
    case Num::Real: return static_cast<F>(n.d);
    }
    return 0;
}

template<typename E>
E ToElement(const Num& n) {
    if constexpr (std::is_floating_point_v<E>) return ToReal<E>(n);
    else return ToInteger<E>(n);
}

// A field of a space-separated list: the longest numeric prefix, or failure.
bool FieldNumber(const std::string& token, Num& out) {
    if (token.empty()) return false;
    const char c = token[0];
    if (! (std::isdigit(static_cast<unsigned char>(c)) || c == '-' || c == '+' || c == '.'))
        return false;
    errno = 0;
    char*        end   = nullptr;
    const double value = std::strtod(token.c_str(), &end);
    if (end == token.c_str() || ! std::isfinite(value)) return false;
    out.kind = Num::Real;
    out.d    = value;
    return true;
}

// Every field of `text`, split on the space character only (empty fields stay).
std::vector<std::string> SpaceFields(const std::string& text) {
    std::vector<std::string> fields;
    std::size_t              from = 0;
    for (;;) {
        const std::size_t at = text.find(' ', from);
        if (at == std::string::npos) {
            fields.push_back(text.substr(from));
            return fields;
        }
        fields.push_back(text.substr(from, at - from));
        from = at + 1;
    }
}

// The numbers a node stands for when read as a list: a number, a string of
// space-separated numbers, or an array of numbers and flags.
bool ListOf(const CallSite& at, const nlohmann::json& node, std::vector<Num>& list) {
    list.clear();
    Num one;
    if (node.is_number()) {
        NumberOf(node, one);
        list.push_back(one);
        return true;
    }
    if (node.is_string()) {
        for (const auto& token : SpaceFields(node.get<std::string>())) {
            if (! FieldNumber(token, one)) {
                LogBadText(at, "has a field that is not a number", node.get<std::string>());
                return false;
            }
            list.push_back(one);
        }
        return true;
    }
    if (node.is_array()) {
        for (const auto& item : node) {
            if (! (item.is_number() || item.is_boolean()) || ! NumberOf(item, one)) {
                LogMismatch(at, node);
                return false;
            }
            list.push_back(one);
        }
        return true;
    }
    LogMismatch(at, node);
    return false;
}

template<typename T>
struct IsStdArray : std::false_type {};
template<typename E, std::size_t N>
struct IsStdArray<std::array<E, N>> : std::true_type {};

template<typename T>
bool ReadNode(const CallSite& at, const nlohmann::json& node, T& value) {
    if constexpr (std::is_same_v<T, bool>) {
        if (! node.is_boolean()) return LogMismatch(at, node), false;
        value = node.get<bool>();
        return true;
    } else if constexpr (std::is_same_v<T, std::string>) {
        if (! node.is_string()) return LogMismatch(at, node), false;
        value = node.get<std::string>();
        return true;
    } else if constexpr (std::is_arithmetic_v<T>) {
        Num n;
        if (! NumberOf(node, n)) return LogMismatch(at, node), false;
        value = ToElement<T>(n);
        return true;
    } else if constexpr (IsStdArray<T>::value) {
        using E               = typename T::value_type;
        constexpr std::size_t N = std::tuple_size_v<T>;
        std::vector<Num>      list;
        if (node.is_boolean()) return LogMismatch(at, node), false;
        if (! ListOf(at, node, list)) return false;
        if (node.is_number()) {
            // A lone number is the first element; the others are zero.
            T out {};
            out[0] = ToElement<E>(list[0]);
            value  = out;
            return true;
        }
        if (list.size() != N) {
            LogBadText(at, "has the wrong number of elements", NodeText(node));
            return false;
        }
        T out {};
        for (std::size_t i = 0; i < N; ++i) out[i] = ToElement<E>(list[i]);
        value = out;
        return true;
    } else {
        // The growable list of numbers.
        using E = typename T::value_type;
        std::vector<Num> list;
        if (node.is_boolean()) return LogMismatch(at, node), false;
        if (! ListOf(at, node, list)) return false;
        T out;
        out.reserve(list.size());
        for (const auto& n : list) out.push_back(ToElement<E>(n));
        value = std::move(out);
        return true;
    }
}
} // namespace

template<typename T>
typename JsonTemplateTypeCheck<T>::type
GetJsonValue(const char* file, const char* func, int line, const nlohmann::json& json, T& value,
             bool has_name, std::string_view name_view, bool warn) {
    const CallSite at { file, func, line, name_view };
    try {
        const nlohmann::json* node = &json;
        if (has_name) {
            const auto found = json.is_object() ? json.find(std::string(name_view)) : json.end();
            if (! json.is_object() || found == json.end() || found->is_null()) {
                if (warn) {
                    WallpaperLog(LOGLEVEL_INFO,
                                 file,
                                 line,
                                 "%s: no \"%.*s\" in the document",
                                 func,
                                 static_cast<int>(name_view.size()),
                                 name_view.data());
                }
                return false;
            }
            node = &*found;
        }
        // An object that wraps its literal in `value` is read through it, one level.
        if (node->is_object()) {
            const auto inner = node->find("value");
            if (inner != node->end()) node = &*inner;
        }
        return ReadNode<T>(at, *node, value);
    } catch (const std::exception& e) {
        LogBadText(at, "could not be read", e.what());
        return false;
    } catch (...) {
        return false;
    }
}

#define T_IMPL_GET_JSON(TYPE)                                                            \
    template JsonTemplateTypeCheck<TYPE>::type GetJsonValue<TYPE>(const char*,           \
                                                                  const char*,           \
                                                                  int,                   \
                                                                  const nlohmann::json&, \
                                                                  TYPE&,                 \
                                                                  bool,                  \
                                                                  std::string_view,      \
                                                                  bool);

T_IMPL_GET_JSON(bool);
// A type with a comma in it cannot be a macro argument.
template<std::size_t N>
using iarray = std::array<int, N>;
template<std::size_t N>
using farray = std::array<float, N>;

// Scalars and text.
T_IMPL_GET_JSON(int32_t);   T_IMPL_GET_JSON(uint32_t);
T_IMPL_GET_JSON(float);     T_IMPL_GET_JSON(double);
T_IMPL_GET_JSON(std::string);
// Lists and fixed-size vectors the parsers read.
T_IMPL_GET_JSON(std::vector<float>);
T_IMPL_GET_JSON(iarray<3>);
T_IMPL_GET_JSON(farray<2>);   T_IMPL_GET_JSON(farray<3>);

// template bool GetJsonValue();
} // namespace wallpaper
