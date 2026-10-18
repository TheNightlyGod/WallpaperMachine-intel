#include "WPJson.hpp"
#include <nlohmann/json.hpp>

#include <cctype>
#include <string>

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
    try {
        result = nlohmann::json::parse(source);
    } catch (nlohmann::json::parse_error& e) {
        // Only a document strict parsing rejected pays for the second pass.
        auto lenient = nlohmann::json::parse(WithoutTrailingCommas(source), nullptr, false);
        if (! lenient.is_discarded()) {
            result = std::move(lenient);
            return true;
        }
        WallpaperLog(LOGLEVEL_ERROR, file, line, "parse json(%s), %s", func, e.what());
        return false;
    }
    return true;
}

template<typename T>
inline bool _GetJsonValue(const nlohmann::json&                  json,
                          typename utils::is_std_array<T>::type& value) {
    using Tv          = typename T::value_type;
    const auto* pjson = &json;
    if (json.contains("value")) pjson = &json.at("value");
    const auto& njson = *pjson;
    if (njson.is_number()) {
        value = { njson.get<Tv>() };
        return true;
    } else if (njson.is_array()) {
        if (njson.size() != value.size()) {
            throw utils::StrToArray::WrongSizeExp {};
        }
        for (std::size_t i = 0; i < value.size(); ++i) {
            value[i] = njson.at(i).get<Tv>();
        }
        return true;
    } else {
        std::string strvalue;
        strvalue = njson.get<std::string>();
        return utils::StrToArray::Convert(strvalue, value);
    }
}

template<typename T>
inline bool _GetJsonValue(const nlohmann::json& json, T& value) {
    if (json.contains("value"))
        value = json.at("value").get<T>();
    else
        value = json.get<T>();
    return true;
}

template<typename T>
inline bool _GetJsonValue(const char* file, const char* func, int line, const nlohmann::json& json,
                          T& value, bool warn, const char* name) {
    (void)warn;

    using njson = nlohmann::json;
    std::string nameinfo;
    if (name != nullptr) nameinfo = std::string("(key: ") + name + ")";
    try {
        return _GetJsonValue<T>(json, value);
    } catch (const njson::type_error& e) {
        WallpaperLog(LOGLEVEL_INFO,
                     file,
                     line,
                     "%s %s at %s\n%s",
                     e.what(),
                     nameinfo.c_str(),
                     func,
                     json.dump(4).c_str());
    } catch (const std::invalid_argument& e) {
        WallpaperLog(LOGLEVEL_ERROR, file, line, "%s %s at %s", e.what(), nameinfo.c_str(), func);
    } catch (const std::out_of_range& e) {
        WallpaperLog(LOGLEVEL_ERROR, file, line, "%s %s at %s", e.what(), nameinfo.c_str(), func);
    } catch (const utils::StrToArray::WrongSizeExp& e) {
        WallpaperLog(LOGLEVEL_ERROR, file, line, "%s %s at %s", e.what(), nameinfo.c_str(), func);
    }
    return false;
}

template<typename T>
typename JsonTemplateTypeCheck<T>::type
GetJsonValue(const char* file, const char* func, int line, const nlohmann::json& json, T& value,
             bool has_name, std::string_view name_view, bool warn) {
    std::string name { name_view };
    if (has_name) {
        if (! json.contains(name)) {
            if (warn)
                WallpaperLog(LOGLEVEL_INFO,
                             "",
                             0,
                             "read json \"%s\" not a key at %s(%s:%d)",
                             name.data(),
                             func,
                             file,
                             line);
            return false;
        } else if (json.at(name).is_null()) {
            if (warn)
                WallpaperLog(LOGLEVEL_INFO,
                             "",
                             0,
                             "read json \"%s\" is null at %s(%s:%d)",
                             name.data(),
                             func,
                             file,
                             line);
            return false;
        }
    }
    return _GetJsonValue<T>(file,
                            func,
                            line,
                            has_name ? json.at(name) : json,
                            value,
                            warn,
                            name.empty() ? nullptr : name.c_str());
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
T_IMPL_GET_JSON(int32_t);
T_IMPL_GET_JSON(uint32_t);
T_IMPL_GET_JSON(float);
T_IMPL_GET_JSON(double);
T_IMPL_GET_JSON(std::string);
T_IMPL_GET_JSON(std::vector<float>);

template<std::size_t N>
using iarray = std::array<int, N>;
T_IMPL_GET_JSON(iarray<3>);

template<std::size_t N>
using farray = std::array<float, N>;
T_IMPL_GET_JSON(farray<2>);
T_IMPL_GET_JSON(farray<3>);

// template bool GetJsonValue();
} // namespace wallpaper
