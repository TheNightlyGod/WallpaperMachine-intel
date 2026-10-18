#include "WPParticleObject.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"
#include "Core/StringHelper.hpp"

#include <sstream>
#include <algorithm>
#include <cmath>

using namespace wallpaper::wpscene;

namespace
{

const nlohmann::json& unwrap_setting(const nlohmann::json& value)
{
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

bool has_dynamic_setting(const nlohmann::json& value)
{
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

void remember_user_binding(
    const nlohmann::json&                  json,
    const char*                            key,
    std::map<std::string, std::string>*    bindings)
{
    if (bindings == nullptr || !json.contains(key)) return;
    const auto& value = json.at(key);
    if (!value.is_object() || !value.contains("user") || !value.at("user").is_string()) return;
    (*bindings)[key] = value.at("user").get<std::string>();
}

void read_vec3_setting(
    const nlohmann::json&  json,
    const char*            key,
    std::array<float, 3>*  destination,
    nlohmann::json*        setting,
    bool*                  dynamic)
{
    if (!json.contains(key) || destination == nullptr || setting == nullptr) return;

    *setting = json.at(key);
    if (dynamic != nullptr) *dynamic = has_dynamic_setting(*setting);

    const auto& source = unwrap_setting(*setting);
    if (source.is_array() && source.size() >= 3) {
        (*destination)[0] = source.at(0).get<float>();
        (*destination)[1] = source.at(1).get<float>();
        (*destination)[2] = source.at(2).get<float>();
        return;
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        *destination = { scalar, scalar, scalar };
        return;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        stream >> (*destination)[0] >> (*destination)[1] >> (*destination)[2];
    }
}

} // namespace

bool ParticleChild::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "type", type);

    if (name.empty()) {
        return false;
    }

    nlohmann::json jParticle;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + name), jParticle)) return false;

    if (! obj.FromJson(jParticle, vfs)) return false;

    GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpointstartindex", controlpointstartindex);
    GET_JSON_NAME_VALUE_NOWARN(json, "probability", probability);

    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "scale", scale);
    GET_JSON_NAME_VALUE_NOWARN(json, "angles", angles);
    return true;
}

bool ParticleControlpoint::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "id", id);

    uint32_t _raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", _raw_flags);
    flags = EFlags(_raw_flags);

    GET_JSON_NAME_VALUE_NOWARN(json, "offset", offset);
    return true;
};

bool ParticleRender::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);

    // Each renderer fills the keys a file leaves out with its own numbers.
    if (name == "rope") {
        subdivision = 4.0f;
        uvsmoothing = true;
    } else if (name == "ropetrail") {
        length      = 1.0f;
        segments    = 4.0f;
        subdivision = 1.0f;
    }

    if (sstart_with(name, "rope")) {
        GET_JSON_NAME_VALUE_NOWARN(json, "subdivision", subdivision);
        // Truncated, never rounded, and kept inside what the renderer supports.
        subdivision = std::clamp(std::trunc(subdivision), 0.0f, 32.0f);
        if (json.contains("uvscale")) {
            uvscale_setting = json.at("uvscale");
            const auto& source = unwrap_setting(uvscale_setting);
            if (source.is_number()) uvscale = source.get<float>();
        }
        if (json.contains("uvscrolling")) {
            uvscrolling_setting = json.at("uvscrolling");
            const auto& source  = unwrap_setting(uvscrolling_setting);
            if (source.is_boolean()) uvscrolling = source.get<bool>();
            else if (source.is_number()) uvscrolling = source.get<float>() != 0.0f;
        }
        // Smoothing belongs to the plain rope and is only read while the
        // texture is not scrolling; a rope trail has none.
        if (name == "rope" && json.contains("uvsmoothing")) {
            uvsmoothing_setting = json.at("uvsmoothing");
            const auto& source  = unwrap_setting(uvsmoothing_setting);
            if (source.is_boolean()) uvsmoothing = source.get<bool>();
            else if (source.is_number()) uvsmoothing = source.get<float>() != 0.0f;
        }
        if (uvscrolling) uvsmoothing = false;
        if (name != "rope") uvsmoothing = false;
    }
    if (name == "spritetrail") {
        GET_JSON_NAME_VALUE_NOWARN(json, "length", length);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxlength", maxlength);
        GET_JSON_NAME_VALUE_NOWARN(json, "minlength", minlength);
    }
    if (name == "ropetrail") {
        GET_JSON_NAME_VALUE_NOWARN(json, "length", length);
        GET_JSON_NAME_VALUE_NOWARN(json, "segments", segments);
        length   = std::max(length, 0.001f);
        segments = std::clamp(std::trunc(segments), 2.0f, 32.0f);
    }
    return true;
}

bool Emitter::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "id", id);

    GET_JSON_NAME_VALUE_NOWARN(json, "speedmin", speedmin);
    GET_JSON_NAME_VALUE_NOWARN(json, "speedmax", speedmax);
    GET_JSON_NAME_VALUE_NOWARN(json, "instantaneous", instantaneous);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemax", distancemax);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemin", distancemin);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "directions", directions);
    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "sign", sign);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingmode", audioprocessingmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingbounds", audioprocessingbounds);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingexponent", audioprocessingexponent);
    GET_JSON_NAME_VALUE_NOWARN(
        json, "audioprocessingfrequencystart", audioprocessingfrequencystart);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingfrequencyend", audioprocessingfrequencyend);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpoint", controlpoint);
    GET_JSON_NAME_VALUE_NOWARN(json, "delay", delay);
    GET_JSON_NAME_VALUE_NOWARN(json, "duration", duration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicduration", minperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicduration", maxperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicdelay", minperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicdelay", maxperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxtoemitperperiod", maxtoemitperperiod);
    GET_JSON_NAME_VALUE_NOWARN(json, "cone", cone);

    if (controlpoint >= 8) LOG_ERROR("wrong controlpoint %d", controlpoint);
    // Wallpaper Engine keeps 0..6 and names the last control point for
    // anything else, a negative index included.
    controlpoint = static_cast<u32>(controlpoint) < 7u ? controlpoint : 7;

    uint32_t _raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", _raw_flags);
    flags = EFlags(_raw_flags);

    std::transform(sign.begin(), sign.end(), sign.begin(), [](int32_t v) {
        if (v != 0)
            return v / std::abs(v);
        else
            return 0;
    });
    return true;
}

bool ParticleInstanceoverride::FromJosn(const nlohmann::json& json) {
    enabled = true;
    for (const char* key : { "alpha", "size", "lifetime", "rate", "speed", "count", "color", "colorn",
                             "brightness" }) {
        remember_user_binding(json, key, &bindings);
    }
    for (int i = 0; i < 8; ++i) {
        const std::string point = "controlpoint" + std::to_string(i);
        const std::string angle = "controlpointangle" + std::to_string(i);
        remember_user_binding(json, point.c_str(), &bindings);
        remember_user_binding(json, angle.c_str(), &bindings);
        std::array<float, 3> value {};
        if (json.contains(point) && GET_JSON_NAME_VALUE_NOWARN(json, point, value)) {
            controlpointSet[i] = true;
            controlpoint[i]    = value;
        }
        if (json.contains(angle) && GET_JSON_NAME_VALUE_NOWARN(json, angle, value)) {
            controlpointangleSet[i] = true;
            controlpointangle[i]    = value;
        }
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);
    GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
    GET_JSON_NAME_VALUE_NOWARN(json, "size", size);
    GET_JSON_NAME_VALUE_NOWARN(json, "lifetime", lifetime);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "speed", speed);
    GET_JSON_NAME_VALUE_NOWARN(json, "count", count);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    if (json.contains("color")) {
        GET_JSON_NAME_VALUE(json, "color", color);
        overColor = true;
    } else if (json.contains("colorn")) {
        GET_JSON_NAME_VALUE(json, "colorn", colorn);
        overColorn = true;
    }
    return true;
};

bool Particle::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.contains("emitter")) {
        LOG_ERROR("particle no emitter");
        return false;
    }
    for (const auto& el : json.at("emitter")) {
        Emitter emi;
        emi.FromJson(el);
        emitters.push_back(emi);
    }
    // Wallpaper Engine appends a sprite renderer unless the key holds an array;
    // an array the file wrote empty is kept, and then nothing is drawn.
    const bool has_renderer_list = json.contains("renderer") && json.at("renderer").is_array();
    if (has_renderer_list) {
        for (const auto& el : json.at("renderer")) {
            ParticleRender pr;
            pr.FromJson(el);
            renderers.push_back(pr);
        }
    } else {
        ParticleRender pr;
        pr.name = "sprite";
        renderers.push_back(pr);
    }
    if (json.contains("initializer")) {
        for (const auto& el : json.at("initializer")) {
            initializers.push_back(el);
        }
    }
    if (json.contains("operator")) {
        for (const auto& el : json.at("operator")) {
            operators.push_back(el);
        }
    }
    if (json.contains("controlpoint")) {
        for (const auto& el : json.at("controlpoint")) {
            ParticleControlpoint pc;
            pc.FromJson(el);
            controlpoints.push_back(pc);
        }
    }

    if (json.contains("children")) {
        for (const auto& el : json.at("children")) {
            ParticleChild child;
            if (child.FromJson(el, vfs)) {
                children.push_back(child);
            }
        }
    }
    if (json.contains("material")) {
        std::string matPath;
        GET_JSON_NAME_VALUE(json, "material", matPath);
        nlohmann::json jMat;
        if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat)) return false;
        material.FromJson(jMat);
    } else {
        LOG_ERROR("particle object no material");
        return false;
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "animationmode", animationmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "sequencemultiplier", sequencemultiplier);
    GET_JSON_NAME_VALUE(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE(json, "starttime", starttime);

    uint32_t rawflags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", rawflags);
    flags = EFlags(rawflags);

    return true;
}

bool WPParticleObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "particle", particle);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (json.contains("visible")) {
        visible_setting  = json.at("visible");
        dynamic_visible = visible_setting.is_object() &&
                          (visible_setting.contains("script") || visible_setting.contains("user"));
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
    read_vec3_setting(json, "origin", &origin, &origin_setting, &dynamic_origin);
    read_vec3_setting(json, "angles", &angles, &angles_setting, nullptr);
    read_vec3_setting(json, "scale", &scale, &scale_setting, nullptr);
    GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
    ParseDependencies(json, dependencies);

    if (json.contains("instanceoverride") && ! json.at("instanceoverride").is_null()) {
        instanceoverride.FromJosn(json.at("instanceoverride"));
    }

    nlohmann::json jParticle;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + particle), jParticle)) return false;
    if (! particleObj.FromJson(jParticle, vfs)) return false;
    AbsorbFieldBindings(json, field_bindings);
    return true;
}
