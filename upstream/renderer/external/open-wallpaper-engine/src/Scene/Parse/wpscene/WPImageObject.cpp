#include "WPImageObject.h"
#include "WPObjectSchema.hpp"
#include "Utils/Logging.h"
#include "Fs/VFS.h"

#include <algorithm>
#include <sstream>

using namespace wallpaper::wpscene;

void wallpaper::wpscene::ParsePuppetAnimationLayers(
    const nlohmann::json& json, std::vector<WPPuppetLayer::AnimationLayer>& layers,
    std::vector<nlohmann::json>& settings) {
    const auto entries = json.find("animationlayers");
    if (entries == json.end() || !entries->is_array()) return;
    for (const auto& entry : *entries) {
        if (!entry.is_object()) continue;
        WPPuppetLayer::AnimationLayer layer;
        GET_JSON_NAME_VALUE(entry, "animation", layer.id);
        GET_JSON_NAME_VALUE(entry, "blend", layer.blend);
        GET_JSON_NAME_VALUE(entry, "rate", layer.rate);
        GET_JSON_NAME_VALUE_NOWARN(entry, "visible", layer.visible);
        GET_JSON_NAME_VALUE_NOWARN(entry, "id", layer.layer_id);
        GET_JSON_NAME_VALUE_NOWARN(entry, "name", layer.name);
        GET_JSON_NAME_VALUE_NOWARN(entry, "additive", layer.additive);
        GET_JSON_NAME_VALUE_NOWARN(entry, "blendin", layer.blendin);
        GET_JSON_NAME_VALUE_NOWARN(entry, "blendout", layer.blendout);
        GET_JSON_NAME_VALUE_NOWARN(entry, "blendtime", layer.blendtime);
        layers.push_back(layer);
        settings.push_back(entry);
    }
}

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


bool WPEffectCommand::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "command", command);
    GET_JSON_NAME_VALUE(json, "target", target);
    GET_JSON_NAME_VALUE(json, "source", source);
    return true;
}

bool WPEffectFbo::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "format", format);

    GET_JSON_NAME_VALUE(json, "scale", scale);
    if(scale == 0) { 
        LOG_ERROR("fbo scale can't be 0");
        scale = 1;
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "width", width);
    GET_JSON_NAME_VALUE_NOWARN(json, "height", height);
    GET_JSON_NAME_VALUE_NOWARN(json, "fit", fit);
    return true;
}

// Define and initialize the static property
const std::unordered_set<std::string> WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS = 
{
    "2799421411" // Audio Responsive Oscilloscope   --  causes vulcan deadlock
};


bool WPImageEffect::IsEffectBlacklisted(const std::string& filePath) {
    
    std::filesystem::path path(filePath);
    // Check if the path has a parent path
    if (path.has_parent_path()) {
        path = path.parent_path();
        if(path.has_parent_path()) {
            std::string effectId = path.parent_path().filename().string();
            std::string parentPath = path.parent_path().string();
            return WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS.find(effectId) != WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS.end();
        }
    }
    return false;
}
    
bool WPImageEffect::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    std::string filePath;
    GET_JSON_NAME_VALUE(json, "file", filePath);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if(this->IsEffectBlacklisted(filePath)) {
        //hide blacklisted effects
        visible = false;
    } else if (json.contains("visible")) {
        const auto& setting = json.at("visible");
        if (setting.is_object() && (setting.contains("user") || setting.contains("script"))) {
            visible_setting  = setting;
            scripted_visible = setting.contains("script");
        }
    }
	GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    nlohmann::json jEffect;
    if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + filePath), jEffect))
        return false;
    if(!FromFileJson(jEffect, vfs))
        return false;

    if(json.contains("passes")) {
        const auto& jPasses = json.at("passes");
        if(jPasses.size() > passes.size()) {
            LOG_ERROR("passes is not injective");
            return false;
        }
        int32_t i = 0;
        for(const auto& jP:jPasses) {
            WPMaterialPass pass;
            pass.FromJson(jP);
            passes[i++].Update(pass); 
        }
    }
    return true;
}

bool WPImageEffect::FromFileJson(const nlohmann::json& json, fs::VFS& vfs) {
	GET_JSON_NAME_VALUE_NOWARN(json, "version", version);
    GET_JSON_NAME_VALUE(json, "name", name);
    if(json.contains("fbos")) {
        for(auto& jF:json.at("fbos")) {
            WPEffectFbo fbo;
            fbo.FromJson(jF);
            fbos.push_back(std::move(fbo));
        }
    }
    if(json.contains("passes")) {
        const auto& jEPasses = json.at("passes");
        bool compose {false};
        for(const auto& jP:jEPasses) {
            if(!jP.contains("material")) {
                if(jP.contains("command")) {
                    WPEffectCommand cmd;
                    cmd.FromJson(jP);
                    cmd.afterpos = passes.size();
                    commands.push_back(cmd);
                    continue;
                }
                LOG_ERROR("no material in effect pass");
                return false;
            }
            std::string matPath;
            GET_JSON_NAME_VALUE(jP, "material", matPath);
            nlohmann::json jMat;
            if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat))
                return false;
            WPMaterial material;
            material.FromJson(jMat);
            materials.push_back(std::move(material));
            WPMaterialPass pass;
            pass.FromJson(jP);
            passes.push_back(std::move(pass));
            if(jP.contains("compose"))
	            GET_JSON_NAME_VALUE(jP, "compose", compose);
        }
        if(compose) {
            if(passes.size() != 2) {
                LOG_ERROR("effect compose option error");
                return false;
            }
            WPEffectFbo fbo; {fbo.name = "_rt_FullCompoBuffer1"; fbo.scale = 1;}
            fbos.push_back(fbo);
            passes.at(0).bind.push_back({ "previous", 0});
            passes.at(0).target = "_rt_FullCompoBuffer1";
            passes.at(1).bind.push_back({"_rt_FullCompoBuffer1", 0});
        }
    } else {
        LOG_ERROR("no passes in effect file");
        return false;
    }
    return true;
}

bool WPImageObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "image", image);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (json.contains("visible")) {
        visible_setting  = json.at("visible");
        dynamic_visible = visible_setting.is_object() &&
                          (visible_setting.contains("script") || visible_setting.contains("user"));
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "alignment", alignment);
    nlohmann::json jImage;
    if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + image), jImage)) {
        LOG_ERROR("Can't load image json: %s", image.c_str());
        return false;
    }
    GET_JSON_NAME_VALUE_NOWARN(jImage, "fullscreen", fullscreen);
    GET_JSON_NAME_VALUE_NOWARN(jImage, "autosize", autosize);
    GET_JSON_NAME_VALUE_NOWARN(jImage, "projectlayer", projectlayer);
    GET_JSON_NAME_VALUE_NOWARN(jImage, "solidlayer", solidlayer);
    GET_JSON_NAME_VALUE_NOWARN(jImage, "passthrough", config.passthrough);
	GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
	GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
	GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
	GET_JSON_NAME_VALUE_NOWARN(json, "attachment", attachment);
	GET_JSON_NAME_VALUE_NOWARN(json, "colorBlendMode", colorBlendMode);
    GET_JSON_NAME_VALUE_NOWARN(json, "copybackground", copybackground);
    GET_JSON_NAME_VALUE_NOWARN(json, "clampuvs", clampuvs);
    GET_JSON_NAME_VALUE_NOWARN(json, "nointerpolation", nointerpolation);
    GET_JSON_NAME_VALUE_NOWARN(json, "solid", solid);
    GET_JSON_NAME_VALUE_NOWARN(json, "disablepropagation", disablepropagation);
    read_vec3_setting(json, "origin", &origin, &origin_setting, &dynamic_origin);
    read_vec3_setting(json, "scale", &scale, &scale_setting, nullptr);
    read_vec3_setting(json, "angles", &angles, &angles_setting, nullptr);
	if(!fullscreen) {
		GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
		// The size the scene saved is the one the layer was given in the editor;
		// a model's own size (a sprite sheet's frame) is only for a layer that
		// saved none it can be read from.
		const bool saved_size = json.contains("size");
		if(!(saved_size && GET_JSON_NAME_VALUE(json, "size", size))) {
			if(jImage.contains("width")) {
				int32_t w,h;
				GET_JSON_NAME_VALUE(jImage, "width", w);
				GET_JSON_NAME_VALUE(jImage, "height", h);
				size = {(float)w, (float)h};
			} else if(!saved_size) {
				size = {origin.at(0)*2, origin.at(1)*2};
			}
		}
    }
    GET_JSON_NAME_VALUE_NOWARN(jImage, "nopadding", nopadding);
    GET_JSON_NAME_VALUE_NOWARN(json, "color", color);
    if (json.contains("alpha")) {
        alpha_setting = json.at("alpha");
        dynamic_alpha = alpha_setting.is_object() && alpha_setting.contains("animation");
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
    GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);

	GET_JSON_NAME_VALUE_NOWARN(jImage, "puppet", puppet);	
    if(jImage.contains("material")) {
        std::string matPath;
		GET_JSON_NAME_VALUE(jImage, "material", matPath);	
        nlohmann::json jMat;
        if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat)) {
            LOG_ERROR("Can't load material json: %s", matPath.c_str());
            return false;
        }
        material.FromJson(jMat);
    } else {
        LOG_INFO("image object no material");
        return false;
    }
    if(json.contains("effects")) {
        for(const auto& jE:json.at("effects")) {
            WPImageEffect wpeff;
            wpeff.FromJson(jE, vfs);
            effects.push_back(std::move(wpeff));
        }
    }
    ParsePuppetAnimationLayers(json, puppet_layers, puppet_layer_settings);
    if(json.contains("config")) {
        const auto& jConf = json.at("config");
        GET_JSON_NAME_VALUE_NOWARN(jConf, "passthrough", config.passthrough);
    }
    ParseDependencies(json, dependencies);
    bool runtime_image_replaces_color = false;
    // A solid instance layer carries its own pass overrides next to the shared
    // model material: the textures, the user textures a scene binds by name —
    // `$mediaThumbnail` for the now-playing cover — and the combos the shader
    // is compiled with. Parsing them into a side struct left every such layer
    // on the model's placeholder texture, so they are merged into the layer's
    // material the same way an effect pass is.
    if (json.contains("instance") && json.at("instance").is_object()) {
        WPMaterialPass instance_pass;
        instance_pass.FromJson(json.at("instance"));
        const bool replaces_placeholder =
            std::any_of(instance_pass.usertextures.begin(),
                        instance_pass.usertextures.end(),
                        IsSystemUserTexture);
        material.MergePass(instance_pass);
        instance_usertextures = instance_pass.usertextures;
        // The layer colour of a solid instance layer tints the placeholder the
        // model material ships — `util/white`. Once a runtime image is actually
        // substituted into that slot the colour has nothing left to describe,
        // and keeping it multiplies the image instead: this scene dims its
        // cover layer to 0.118, while the author's own recording of it shows
        // the cover at full strength. A binding that names a project property
        // substitutes too, but only once its user has chosen a picture, and the
        // property table is not readable from here: the parser makes that call
        // (ParseImageObj), and until then the layer keeps its colour.
        if (replaces_placeholder) color = { 1.0f, 1.0f, 1.0f };
        runtime_image_replaces_color = replaces_placeholder;
    }
    AbsorbFieldBindings(json, field_bindings);
    // Nor does a colour bound to a user property tint the substituted image.
    if (runtime_image_replaces_color && field_bindings.is_object()) field_bindings.erase("color");
    return true;
}
