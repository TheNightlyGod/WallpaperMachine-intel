#pragma once

#include <string>
#include <string_view>
#include <unordered_map>

namespace wallpaper
{

struct RuntimeScalarValue
{
    enum class Kind
    {
        Bool,
        Float,
        String,
    };

    static RuntimeScalarValue Bool(bool value);
    static RuntimeScalarValue Float(float value);
    static RuntimeScalarValue String(std::string value);

    bool               asBool() const;
    float              asFloat() const;
    const std::string& asString() const;

    Kind        kind { Kind::String };
    bool        bool_value { false };
    float       float_value { 0.0f };
    std::string string_value {};
};

using ProjectProperties = std::unordered_map<std::string, RuntimeScalarValue>;

// Whether a string property, a combo's choice among them, reads as a true flag:
// `true` in any case, or `1`. Every other string is false.
bool StringIsTrue(std::string_view value);

// Reads a project's `project.json` property defaults into `properties`. False, with the
// reason in `error`, when the file or its properties cannot be read.
bool ParseProjectProperties(const std::string& project_path, ProjectProperties* properties,
                            std::string* error);

// Reads a flat JSON object of property name to value (the shape a host sends as an override).
bool ParseFlatProjectPropertyOverrideJson(std::string_view json, ProjectProperties* properties,
                                          std::string* error);

// `defaults` with every entry of `overrides` laid over it.
ProjectProperties MergeProjectProperties(const ProjectProperties& defaults,
                                         const ProjectProperties& overrides);

} // namespace wallpaper
