// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#pragma once

#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

#include "Scripting/ScriptModuleSyntax.hpp"
#include "Utils/Logging.h"
#include "WPJson.hpp"

namespace wallpaper::wpscene
{

// ---------------------------------------------------------------------------
// Reading a scene value. A value is a plain literal or an object that carries
// the authored default in `value` beside its bindings (`user`, `script`,
// `scriptproperties`, `animation`).
// ---------------------------------------------------------------------------

/// What a read finds in an object that has no `value`: nothing readable.
inline const nlohmann::json& NoSettingValue() {
    static const nlohmann::json nothing;
    return nothing;
}

/// The literal a setting holds: the setting itself, or the `value` member of a
/// wrapper. A wrapper without `value` holds no literal.
inline const nlohmann::json& UnwrapSetting(const nlohmann::json& setting) {
    if (! setting.is_object()) return setting;
    const auto found = setting.find("value");
    return found == setting.end() ? NoSettingValue() : *found;
}

/// Whether a setting is an object that carries one of the binding members.
inline bool SettingHasBinding(const nlohmann::json& setting) {
    return setting.is_object() &&
           (setting.contains("user") || setting.contains("script") ||
            setting.contains("scriptproperties") || setting.contains("animation"));
}

/// Whether something outside the file drives the setting each tick: a project
/// property, or a script that exports `update` (a handler-only script drives
/// nothing).
inline bool SettingIsDriven(const nlohmann::json& setting) {
    if (! setting.is_object()) return false;
    if (setting.contains("user")) return true;
    const auto script = setting.find("script");
    return script != setting.end() && script->is_string() &&
           ExportsFunction(script->get_ref<const std::string&>(), "update");
}

/// A `visible` setting that a property or a script decides.
inline bool VisibilityIsBound(const nlohmann::json& setting) {
    return setting.is_object() && (setting.contains("script") || setting.contains("user"));
}

namespace detail
{

inline bool ParseNumberToken(std::string_view token, float& out) {
    if (token.empty()) return false;
    const std::string text(token);
    char*             end = nullptr;
    const float       value = std::strtof(text.c_str(), &end);
    if (end == text.c_str()) return false;
    out = value;
    return true;
}

} // namespace detail

/// Tolerant three-number reader (origin, scale, angles, colours of the scene):
/// an array of at least three numbers takes the first three; a bare number
/// fills every lane; a string is read as whitespace separated numbers, lanes
/// the text does not reach keeping what they hold. A value of any other shape,
/// or text holding a token that is not a finite number, changes nothing.
/// Returns whether `out` was read.
inline bool ReadTolerantVec3(const nlohmann::json& setting, std::array<float, 3>& out) {
    const auto& value = UnwrapSetting(setting);
    if (value.is_number()) {
        const float number = value.get<float>();
        out                = { number, number, number };
        return true;
    }
    if (value.is_array()) {
        if (value.size() < 3) return false;
        std::array<float, 3> lanes;
        for (std::size_t i = 0; i < 3; ++i) {
            if (! value[i].is_number()) {
                LOG_INFO("vector holds an element that is not a number, keeping its default");
                return false;
            }
            lanes[i] = value[i].get<float>();
        }
        out = lanes;
        return true;
    }
    if (! value.is_string()) return false;
    const auto&          text  = value.get_ref<const std::string&>();
    std::array<float, 3> lanes = out;
    std::size_t          count = 0;
    std::size_t          at    = 0;
    while (count < 3) {
        while (at < text.size() && std::isspace(static_cast<unsigned char>(text[at]))) ++at;
        if (at >= text.size()) break;
        const std::size_t begin = at;
        while (at < text.size() && ! std::isspace(static_cast<unsigned char>(text[at]))) ++at;
        float number = 0.0f;
        if (! detail::ParseNumberToken(std::string_view(text).substr(begin, at - begin), number) ||
            ! std::isfinite(number)) {
            LOG_INFO("vector text '%s' holds a token that is not a finite number, keeping its default",
                     text.c_str());
            return false;
        }
        lanes[count++] = number;
    }
    if (count == 0) return false;
    out = lanes;
    return true;
}

/// Strict fixed-size reader (size, parallaxDepth, camera vectors, ambient and
/// fog colours, directions): an array of exactly N numbers, a string of exactly
/// N numbers separated by single spaces, or a bare number which sets lane 0 and
/// zeroes the rest. Anything else changes nothing.
template<std::size_t N>
bool ReadStrictVec(const nlohmann::json& setting, std::array<float, N>& out) {
    const auto& value = UnwrapSetting(setting);
    if (value.is_number()) {
        out.fill(0.0f);
        out[0] = value.get<float>();
        return true;
    }
    std::array<float, N> lanes {};
    if (value.is_array()) {
        if (value.size() != N) return false;
        for (std::size_t i = 0; i < N; ++i) {
            if (! value[i].is_number()) return false;
            lanes[i] = value[i].get<float>();
        }
        out = lanes;
        return true;
    }
    if (! value.is_string()) return false;
    const std::string_view text  = value.get_ref<const std::string&>();
    std::size_t            begin = 0;
    for (std::size_t i = 0; i < N; ++i) {
        // The last piece runs to the end of the text, so a surplus piece makes
        // its token unreadable (a leading number would otherwise hide it).
        const std::size_t end = text.find(' ', begin);
        if ((i + 1 == N) != (end == std::string_view::npos)) return false;
        const auto piece = text.substr(begin, end == std::string_view::npos ? end : end - begin);
        if (! detail::ParseNumberToken(piece, lanes[i])) return false;
        begin = end == std::string_view::npos ? text.size() : end + 1;
    }
    out = lanes;
    return true;
}

/// A plain or wrapped scalar number. Returns whether `out` was read. A number
/// that does not fit an integer target takes the nearest value that does.
template<typename T>
bool ReadNumberSetting(const nlohmann::json& setting, T& out) {
    const auto& value = UnwrapSetting(setting);
    if (! value.is_number()) return false;
    if constexpr (std::is_floating_point_v<T>) {
        out = static_cast<T>(value.get<double>());
    } else {
        const double number = value.get<double>();
        if (! std::isfinite(number)) return false;
        constexpr double lowest  = static_cast<double>(std::numeric_limits<T>::lowest());
        constexpr double highest = static_cast<double>(std::numeric_limits<T>::max());
        out = number <= lowest ? std::numeric_limits<T>::lowest()
              : number >= highest ? std::numeric_limits<T>::max()
                                  : static_cast<T>(number);
    }
    return true;
}

/// How many arrays and objects a document may hold inside one another. Real
/// files stay in the tens; the readers of a document walk it recursively, so a
/// file that nests without bound would exhaust the stack.
inline constexpr std::size_t kMaxJsonNesting = 512;

/// Whether `text` opens more than `limit` arrays and objects inside one another.
/// Brackets inside strings do not count.
inline bool JsonNestsDeeperThan(std::string_view text, std::size_t limit) {
    std::size_t depth     = 0;
    bool        in_string = false;
    bool        escaped   = false;
    for (const char c : text) {
        if (in_string) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '[' || c == '{') {
            if (++depth > limit) return true;
        } else if ((c == ']' || c == '}') && depth > 0) {
            --depth;
        }
    }
    return false;
}

/// Reads a document of the package (the scene, a model, a material, an effect)
/// with the engine's lenient reader, refusing one that nests too deeply.
inline bool ParseBoundedJson(const std::string& text, nlohmann::json& out) {
    if (JsonNestsDeeperThan(text, kMaxJsonNesting)) {
        LOG_ERROR("json document nests deeper than %zu levels, refusing it", kMaxJsonNesting);
        return false;
    }
    return PARSE_JSON(text, out);
}

/// A plain or wrapped flag. With `numbers_count`, a number reads as non-zero.
inline bool ReadFlagSetting(const nlohmann::json& setting, bool& out, bool numbers_count = false) {
    const auto& value = UnwrapSetting(setting);
    if (value.is_boolean()) {
        out = value.get<bool>();
        return true;
    }
    if (numbers_count && value.is_number()) {
        out = value.get<double>() != 0.0;
        return true;
    }
    return false;
}

/// A plain or wrapped string.
inline bool ReadStringSetting(const nlohmann::json& setting, std::string& out) {
    const auto& value = UnwrapSetting(setting);
    if (! value.is_string()) return false;
    out = value.get<std::string>();
    return true;
}

/// An integer that fits a signed 32-bit value; anything else is not an id.
inline bool ReadInt32(const nlohmann::json& value, int32_t& out) {
    if (value.is_number_integer()) {
        if (value.is_number_unsigned()) {
            const auto number = value.get<uint64_t>();
            if (number > static_cast<uint64_t>(std::numeric_limits<int32_t>::max())) return false;
            out = static_cast<int32_t>(number);
            return true;
        }
        const auto number = value.get<int64_t>();
        if (number < std::numeric_limits<int32_t>::min() ||
            number > std::numeric_limits<int32_t>::max()) {
            return false;
        }
        out = static_cast<int32_t>(number);
        return true;
    }
    if (value.is_number_float()) {
        const double number = value.get<double>();
        if (std::isfinite(number) && number == std::floor(number) &&
            number >= std::numeric_limits<int32_t>::min() &&
            number <= std::numeric_limits<int32_t>::max()) {
            out = static_cast<int32_t>(number);
            return true;
        }
    }
    return false;
}

/// The integer entries of a `dependencies` array; entries of any other kind
/// are skipped. A missing or non-array member adds nothing.
inline void ParseDependencies(const nlohmann::json& json, std::vector<int32_t>& out) {
    if (! json.is_object()) return;
    const auto found = json.find("dependencies");
    if (found == json.end() || ! found->is_array()) return;
    for (const auto& entry : *found) {
        int32_t id = 0;
        if (ReadInt32(entry, id)) out.push_back(id);
    }
}

/// Copies every member of `json` that is an object carrying a binding member
/// into `out`, verbatim and under its own key, whether or not this part knows
/// the key. `out` becomes an object.
inline void AbsorbFieldBindings(const nlohmann::json& json, nlohmann::json& out) {
    out = nlohmann::json::object();
    if (! json.is_object()) return;
    for (const auto& [key, member] : json.items()) {
        if (SettingHasBinding(member)) out[key] = member;
    }
}

} // namespace wallpaper::wpscene
