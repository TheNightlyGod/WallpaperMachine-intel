// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#include "Project/ProjectProperties.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <limits>
#include <nlohmann/json.hpp>

#include "Utils/Logging.h"

namespace wallpaper
{

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

namespace
{

// The C library's `%f` form of a number, every digit kept.
std::string FixedText(float value)
{
    char text[96];
    const int n = std::snprintf(text, sizeof(text), "%f", static_cast<double>(value));
    if (n < 0) return {};
    return std::string(text, std::min<std::size_t>(static_cast<std::size_t>(n), sizeof(text) - 1));
}

bool ReadWholeFile(const std::string& path, std::string* text)
{
    std::ifstream in(path, std::ios::binary);
    if (! in) return false;
    text->assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return ! in.bad();
}

bool Fail(std::string* error, std::string message)
{
    LOG_ERROR("project properties: %s", message.c_str());
    if (error != nullptr) *error = std::move(message);
    return false;
}

// A JSON number as a single-precision value; one beyond the range becomes an
// infinity instead of an undefined narrowing.
float NumberToFloat(const nlohmann::json& number)
{
    const double wide = number.get<double>();
    if (std::isnan(wide)) return std::numeric_limits<float>::quiet_NaN();
    constexpr double kMost = std::numeric_limits<float>::max();
    if (wide > kMost) return std::numeric_limits<float>::infinity();
    if (wide < -kMost) return -std::numeric_limits<float>::infinity();
    return static_cast<float>(wide);
}

RuntimeScalarValue ValueFromJson(const nlohmann::json& node)
{
    if (node.is_boolean()) return RuntimeScalarValue::Bool(node.get<bool>());
    if (node.is_number()) return RuntimeScalarValue::Float(NumberToFloat(node));
    if (node.is_string()) return RuntimeScalarValue::String(node.get<std::string>());
    if (node.is_null()) return RuntimeScalarValue::String({});
    return RuntimeScalarValue::String(node.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace));
}

// Strict parse; on failure the library's own message, when there is one.
bool ParseDocument(const std::string& text, nlohmann::json* root, std::string* reason)
{
    *root = nlohmann::json::parse(text, nullptr, false);
    if (! root->is_discarded()) return true;
    *reason = "not valid JSON";
    try {
        (void)nlohmann::json::parse(text);
    } catch (const nlohmann::json::exception& e) {
        *reason = e.what();
    }
    return false;
}

} // namespace

RuntimeScalarValue RuntimeScalarValue::Bool(bool value)
{
    return RuntimeScalarValue { Kind::Bool, value, value ? 1.0f : 0.0f, value ? "true" : "false" };
}

RuntimeScalarValue RuntimeScalarValue::Float(float value)
{
    // A flag by comparison: NaN differs from 0, so it is true.
    return RuntimeScalarValue { Kind::Float, value != 0.0f, value, FixedText(value) };
}

RuntimeScalarValue RuntimeScalarValue::String(std::string value)
{
    const bool flag = StringIsTrue(value);
    return RuntimeScalarValue { Kind::String, flag, 0.0f, std::move(value) };
}

bool RuntimeScalarValue::asBool() const
{
    return kind == Kind::String ? StringIsTrue(string_value) : bool_value;
}

float RuntimeScalarValue::asFloat() const
{
    if (kind != Kind::String) return float_value;
    // The C library's reader, at single precision: it skips leading white space,
    // takes the longest number it finds and ignores whatever follows.
    errno              = 0;
    const char* begin  = string_value.c_str();
    char*       end    = nullptr;
    const float number = std::strtof(begin, &end);
    if (end == begin) return 0.0f;
    // A magnitude beyond the range is not read as infinity (the literal `inf` is).
    if (errno == ERANGE && std::isinf(number)) return 0.0f;
    return number;
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
    if (properties == nullptr) return Fail(error, "property table output must not be null");
    if (project_path.empty()) return Fail(error, "project path must not be empty");

    std::string text;
    if (! ReadWholeFile(project_path, &text))
        return Fail(error, "can't read project file: " + project_path);

    nlohmann::json root;
    std::string    reason;
    if (! ParseDocument(text, &root, &reason)) return Fail(error, reason);

    const auto general = root.is_object() ? root.find("general") : root.end();
    if (root.is_object() && general != root.end() && general->is_object()) {
        const auto declared = general->find("properties");
        if (declared != general->end() && declared->is_object()) {
            ProjectProperties table;
            for (const auto& [name, member] : declared->items()) {
                // A directory or group property has no value to carry.
                if (! member.is_object()) continue;
                const auto value = member.find("value");
                if (value == member.end()) continue;
                table.insert_or_assign(name, ValueFromJson(*value));
            }
            *properties = std::move(table);
            return true;
        }
        return Fail(error, "project has no general.properties object: " + project_path);
    }
    return Fail(error, "project has no general object: " + project_path);
}

bool ParseFlatProjectPropertyOverrideJson(
    std::string_view   json,
    ProjectProperties* properties,
    std::string*       error)
{
    if (properties == nullptr) return Fail(error, "property table output must not be null");

    nlohmann::json root;
    std::string    reason;
    if (! ParseDocument(std::string(json), &root, &reason)) return Fail(error, reason);
    if (! root.is_object()) return Fail(error, "property document must be a JSON object");

    ProjectProperties table;
    for (const auto& [name, member] : root.items()) table.insert_or_assign(name, ValueFromJson(member));
    *properties = std::move(table);
    return true;
}

ProjectProperties MergeProjectProperties(
    const ProjectProperties& defaults,
    const ProjectProperties& overrides)
{
    ProjectProperties merged = defaults;
    for (const auto& [name, value] : overrides) merged.insert_or_assign(name, value);
    return merged;
}

} // namespace wallpaper
