// This project's own code, written from the clean-room specification of the
// project manifest (specs/engine/e7-small-units.md, R38 to R41).
#include "Project/ProjectManifest.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <nlohmann/json.hpp>
#include <string_view>

#include "Utils/Logging.h"

namespace wallpaper
{
namespace
{

bool ReadWholeFile(const std::string& path, std::string* text)
{
    std::ifstream in(path, std::ios::binary);
    if (! in) return false;
    text->assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return ! in.bad();
}

bool EqualsIgnoreCase(const std::string& text, std::string_view word)
{
    return text.size() == word.size() &&
           std::equal(text.begin(), text.end(), word.begin(), [](unsigned char a, char b) {
               return std::tolower(a) == b;
           });
}

WallpaperProjectType TypeFromWord(const std::string& word)
{
    if (EqualsIgnoreCase(word, "scene")) return WallpaperProjectType::Scene;
    if (EqualsIgnoreCase(word, "video")) return WallpaperProjectType::Video;
    if (EqualsIgnoreCase(word, "web")) return WallpaperProjectType::Web;
    return WallpaperProjectType::Unknown;
}

// A workshop id is written either as text or as a whole number; anything else
// (a fraction, an object, null) is treated as absent.
std::string WorkshopIdFrom(const nlohmann::json& value)
{
    if (value.is_string()) return value.get<std::string>();
    if (value.is_number_unsigned()) return std::to_string(value.get<std::uint64_t>());
    if (value.is_number_integer()) return std::to_string(value.get<std::int64_t>());
    return {};
}

bool Fail(std::string* error, std::string message)
{
    LOG_ERROR("project manifest: %s", message.c_str());
    if (error != nullptr) *error = std::move(message);
    return false;
}

} // namespace

const char* ToString(WallpaperProjectType type)
{
    switch (type) {
    case WallpaperProjectType::Scene: return "scene";
    case WallpaperProjectType::Video: return "video";
    case WallpaperProjectType::Web: return "web";
    case WallpaperProjectType::Unknown: break;
    }
    return "unknown";
}

bool ParseProjectManifest(const std::string& project_path,
                          ProjectManifest*   manifest,
                          std::string*       error)
{
    if (project_path.empty()) return Fail(error, "project path must not be empty");
    if (manifest == nullptr) return Fail(error, "project manifest output must not be null");

    std::string text;
    if (! ReadWholeFile(project_path, &text))
        return Fail(error, "can't read project file: " + project_path);

    // The parser skips a leading UTF-8 byte-order mark by itself.
    const nlohmann::json root = nlohmann::json::parse(text, nullptr, false);
    if (root.is_discarded()) {
        std::string reason = "project file is not valid JSON";
        try {
            (void)nlohmann::json::parse(text);
        } catch (const nlohmann::json::exception& e) {
            reason = e.what();
        }
        return Fail(error, reason);
    }

    ProjectManifest parsed;
    if (root.is_object()) {
        if (const auto it = root.find("type"); it != root.end()) {
            if (! it->is_string()) return Fail(error, "project type must be a string");
            parsed.type = TypeFromWord(it->get<std::string>());
        }
        if (const auto it = root.find("file"); it != root.end()) {
            if (! it->is_string()) return Fail(error, "project file entry must be a string");
            parsed.file = it->get<std::string>();
        }
        if (const auto it = root.find("workshopid"); it != root.end())
            parsed.workshop_id = WorkshopIdFrom(*it);
    }

    *manifest = std::move(parsed);
    return true;
}

} // namespace wallpaper
