#include "Project/ProjectProperties.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <sstream>

namespace wallpaper
{
namespace
{

bool read_file(const std::filesystem::path& path, std::string* content)
{
    if (content == nullptr) return false;

    std::ifstream input(path);
    if (!input.good()) return false;

    std::ostringstream buffer;
    buffer << input.rdbuf();
    *content = buffer.str();
    return input.good() || input.eof();
}

RuntimeScalarValue parse_scalar_value(const nlohmann::json& value)
{
    if (value.is_boolean()) return RuntimeScalarValue::Bool(value.get<bool>());
    if (value.is_number()) return RuntimeScalarValue::Float(value.get<float>());
    if (value.is_string()) return RuntimeScalarValue::String(value.get<std::string>());
    if (value.is_null()) return RuntimeScalarValue::String("");
    return RuntimeScalarValue::String(value.dump());
}

} // namespace

bool StringIsTrue(std::string_view value)
{
    // Read for every string a scripted value returns on every tick, so it compares
    // in place and makes no copy.
    constexpr std::string_view kTrue = "true";
    if (value == "1") return true;
    return value.size() == kTrue.size() &&
           std::equal(value.begin(), value.end(), kTrue.begin(), [](unsigned char ch, char expected) {
               return static_cast<char>(std::tolower(ch)) == expected;
           });
}

RuntimeScalarValue RuntimeScalarValue::Bool(bool value)
{
    RuntimeScalarValue result;
    result.kind         = Kind::Bool;
    result.bool_value   = value;
    result.float_value  = value ? 1.0f : 0.0f;
    result.string_value = value ? "true" : "false";
    return result;
}

RuntimeScalarValue RuntimeScalarValue::Float(float value)
{
    RuntimeScalarValue result;
    result.kind         = Kind::Float;
    result.bool_value   = value != 0.0f;
    result.float_value  = value;
    result.string_value = std::to_string(value);
    return result;
}

RuntimeScalarValue RuntimeScalarValue::String(std::string value)
{
    RuntimeScalarValue result;
    result.kind         = Kind::String;
    result.bool_value   = StringIsTrue(value);
    result.float_value  = 0.0f;
    result.string_value = std::move(value);
    return result;
}

bool RuntimeScalarValue::asBool() const
{
    switch (kind) {
    case Kind::Bool: return bool_value;
    case Kind::Float: return float_value != 0.0f;
    case Kind::String: return StringIsTrue(string_value);
    }
    return false;
}

float RuntimeScalarValue::asFloat() const
{
    switch (kind) {
    case Kind::Bool: return bool_value ? 1.0f : 0.0f;
    case Kind::Float: return float_value;
    case Kind::String:
        try {
            return std::stof(string_value);
        } catch (...) {
            return 0.0f;
        }
    }
    return 0.0f;
}

const std::string& RuntimeScalarValue::asString() const
{
    return string_value;
}

bool ParseProjectProperties(
    const std::string& project_path,
    ProjectProperties* properties,
    std::string*       error)
{
    if (properties == nullptr) {
        if (error != nullptr) *error = "project properties output must not be null";
        return false;
    }
    if (project_path.empty()) {
        if (error != nullptr) *error = "project properties path must not be empty";
        return false;
    }

    std::string content;
    if (!read_file(project_path, &content)) {
        if (error != nullptr) *error = "failed to read project properties source";
        return false;
    }

    nlohmann::json project;
    try {
        project = nlohmann::json::parse(content);
    } catch (const nlohmann::json::exception& exception) {
        if (error != nullptr) *error = exception.what();
        return false;
    }

    if (!project.contains("general") || !project.at("general").is_object()) {
        if (error != nullptr) *error = "project must contain an object `general`";
        return false;
    }
    const auto& general = project.at("general");
    if (!general.contains("properties") || !general.at("properties").is_object()) {
        if (error != nullptr) *error = "project general section must contain object `properties`";
        return false;
    }

    ProjectProperties parsed;
    for (const auto& [name, property] : general.at("properties").items()) {
        if (!property.is_object() || !property.contains("value")) continue;
        parsed.emplace(name, parse_scalar_value(property.at("value")));
    }

    *properties = std::move(parsed);
    return true;
}

bool ParseFlatProjectPropertyOverrideJson(
    std::string_view   json,
    ProjectProperties* properties,
    std::string*       error)
{
    if (properties == nullptr) {
        if (error != nullptr) *error = "override property output must not be null";
        return false;
    }

    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(json);
    } catch (const nlohmann::json::exception& exception) {
        if (error != nullptr) *error = exception.what();
        return false;
    }

    if (!parsed.is_object()) {
        if (error != nullptr) *error = "override json must be an object";
        return false;
    }

    ProjectProperties result;
    for (const auto& [name, value] : parsed.items()) {
        result.emplace(name, parse_scalar_value(value));
    }

    *properties = std::move(result);
    return true;
}

ProjectProperties MergeProjectProperties(
    const ProjectProperties& defaults,
    const ProjectProperties& overrides)
{
    ProjectProperties merged = defaults;
    for (const auto& [name, value] : overrides) {
        merged[name] = value;
    }
    return merged;
}

} // namespace wallpaper
