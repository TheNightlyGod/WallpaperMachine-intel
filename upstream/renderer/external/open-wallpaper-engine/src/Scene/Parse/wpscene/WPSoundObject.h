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
    int32_t                  id { 0 };
    std::string              playbackmode { "loop" };
    float                    maxtime { 10.0f };
    float                    mintime { 0.0f };
    float                    volume { 1.0f };
    bool                     muted { false };
    bool                     startsilent { false };
    bool                     visible { true };
    std::string              name;
    /// Project property this sound's volume follows, when the user bound one.
    std::string              volume_user;
    std::vector<std::string> sound;
    std::vector<int32_t>     dependencies;
    nlohmann::json           field_bindings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        // A slider-bound volume arrives as {"user": …, "value": …} rather than
        // a number. Reading only the number kept the author's default and left
        // the user's own slider doing nothing to this sound.
        if (json.contains("volume") && json.at("volume").is_object()) {
            GET_JSON_NAME_VALUE_NOWARN(json.at("volume"), "value", volume);
            if (json.at("volume").contains("user") && json.at("volume").at("user").is_string()) {
                volume_user = json.at("volume").at("user").get<std::string>();
            }
        } else {
            GET_JSON_NAME_VALUE(json, "volume", volume);
        }
        GET_JSON_NAME_VALUE_NOWARN(json, "muted", muted);
        GET_JSON_NAME_VALUE_NOWARN(json, "startsilent", startsilent);
        GET_JSON_NAME_VALUE(json, "playbackmode", playbackmode);
        GET_JSON_NAME_VALUE_NOWARN(json, "mintime", mintime);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxtime", maxtime);
        GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
        GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
        GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
        ParseDependencies(json, dependencies);
        if (! json.contains("sound") || ! json.at("sound").is_array()) {
            return false;
        }
        for (const auto& el : json.at("sound")) {
            std::string name;
            GET_JSON_VALUE(el, name);
            if (! name.empty()) sound.push_back(name);
        }
        AbsorbFieldBindings(json, field_bindings);
        return true;
    }
};
} // namespace wpscene
} // namespace wallpaper
