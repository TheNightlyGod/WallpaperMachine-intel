// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#pragma once
#include <cstdint>
#include <unordered_map>
#include <cstdint>
#include "WPJson.hpp"
#include "WPObjectSchema.hpp"
#include <nlohmann/json.hpp>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

struct WPSoundObject {
    std::string              playbackmode { "loop" };
    float                    maxtime { 10.0f };
    float                    mintime { 0.0f };
    float                    volume { 1.0f };
    bool                     muted { false };
    bool                     startsilent { false };
    bool                     visible { true };
    // Script-visible members nothing plays with here (no spatial audio, no editor).
    float                    attenuation { 0.0f };
    float                    mindistance { 0.0f };
    bool                     muteineditor { false };
    bool                     spatialization { false };
    std::string              name;
    /// Project property this sound's volume follows, when the user bound one.
    std::string              volume_user;
    std::vector<std::string> sound;
    std::vector<int32_t>     dependencies;
    nlohmann::json           field_bindings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        if (! json.is_object()) return false;
        // The file list is the object's reason to exist: without an array of
        // names there is nothing to play.
        const auto files = json.find("sound");
        if (files == json.end() || ! files->is_array()) return false;
        sound.clear();
        for (const auto& entry : *files) {
            if (entry.is_string() && ! entry.get_ref<const std::string&>().empty()) {
                sound.push_back(entry.get<std::string>());
            }
        }
        if (json.contains("name")) ReadStringSetting(json.at("name"), name);
        if (const auto mode = json.find("playbackmode"); mode != json.end()) {
            ReadStringSetting(*mode, playbackmode);
        }
        if (json.contains("mintime")) ReadNumberSetting(json.at("mintime"), mintime);
        if (json.contains("maxtime")) ReadNumberSetting(json.at("maxtime"), maxtime);
        if (json.contains("muted")) ReadFlagSetting(json.at("muted"), muted);
        if (json.contains("startsilent")) ReadFlagSetting(json.at("startsilent"), startsilent);
        if (json.contains("attenuation")) ReadNumberSetting(json.at("attenuation"), attenuation);
        if (json.contains("mindistance")) ReadNumberSetting(json.at("mindistance"), mindistance);
        if (json.contains("muteineditor")) ReadFlagSetting(json.at("muteineditor"), muteineditor);
        if (json.contains("spatialization")) ReadFlagSetting(json.at("spatialization"), spatialization);
        // A sound follows no visibility binding: only the authored value counts.
        if (json.contains("visible")) ReadFlagSetting(json.at("visible"), visible);
        if (const auto level = json.find("volume"); level != json.end()) {
            ReadNumberSetting(*level, volume);
            if (level->is_object()) {
                if (const auto user = level->find("user"); user != level->end()) {
                    if (user->is_string()) {
                        volume_user = user->get<std::string>();
                    } else if (user->is_object() && user->contains("name") &&
                               user->at("name").is_string()) {
                        volume_user = user->at("name").get<std::string>();
                    }
                }
            }
        }
        ParseDependencies(json, dependencies);
        AbsorbFieldBindings(json, field_bindings);
        return true;
    }
};
} // namespace wpscene
} // namespace wallpaper
