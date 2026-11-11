#pragma once
#include "WPJson.hpp"
#include <nlohmann/json.hpp>
#include "WPMaterial.h"
#include <vector>
#include <unordered_map>
#include "WPPuppet.hpp"
#include <unordered_set>
#include <string>
#include <filesystem>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

void ParsePuppetAnimationLayers(const nlohmann::json& json,
                                std::vector<WPPuppetLayer::AnimationLayer>& layers,
                                std::vector<nlohmann::json>& settings);

class WPEffectCommand {
public:
    bool        FromJson(const nlohmann::json&);
    std::string command;
    std::string target;
    std::string source;

    i32 afterpos { 0 };
};

/// One `fbos` entry of an effect file (Wallpaper Engine 2.8.0.42 `sub_1401E7170`): an entry
/// without a `name` and a `format` string is not a buffer.
class WPEffectFbo {
public:
    bool        FromJson(const nlohmann::json&);
    std::string name;
    std::string format;
    uint32_t    scale { 1 };
    // A size of its own, and the longest side it may have; zero for none.
    uint32_t    width { 0 };
    uint32_t    height { 0 };
    uint32_t    fit { 0 };
    /// `unique`: a buffer of this effect instance alone. Without it every effect of the scene
    /// that declares the same name at the same size and scale reads and writes one buffer
    /// (`sub_1401EA500`).
    bool                 unique { false };
    /// `uvs: "repeat"`: sampled with wrapping instead of clamping.
    bool                 repeat { false };
    /// `clear`: an empty string or four numbers; the buffer is cleared to `clear_color` when it
    /// is made (and remade), and by the effect's functions. One to three numbers set the colour
    /// a function clears to without the clear at creation, as Wallpaper Engine reads them.
    bool                 clear { false };
    std::array<float, 4> clear_color { 0.0f, 0.0f, 0.0f, 0.0f };
};

/// One `functions` entry of an effect file that a script runs with
/// `executeMaterialFunction(name)`: Wallpaper Engine keeps only `"action": "clear"`, with the
/// positions in `fbos` of the buffers it names (`sub_1401E7170`).
struct WPEffectFunction {
    std::string           name;
    std::vector<uint32_t> fbos;
};

/// Whether an effect file's `conditions` hold over the effect instance's `combos`
/// (`sub_1401E63B0`): every object of the array must hold, each of its keys compares the
/// combo (0 when missing) with a number, or with `{"value", "op": ge|gt|le|lt}` (anything else
/// is equality). Not an array holds.
bool EffectConditionsHold(const nlohmann::json& conditions, const nlohmann::json* combos);

class WPImageEffect {
public:
    bool                         FromJson(const nlohmann::json&, fs::VFS& vfs);
    /// `combos` is the instance's own `combos` object, which the file's `conditions` read.
    bool                         FromFileJson(const nlohmann::json&, fs::VFS& vfs,
                                              const nlohmann::json* combos = nullptr);
    int32_t                      id { 0 };
    std::string                  name;
    std::string                  instance_name;
    bool                         visible { true };
    /// `visible` as written when a user property or a script decides it:
    /// `visible` above is then only the editor's default. A property's current
    /// value replaces it as the scene loads; a script keeps deciding it while
    /// the scene runs (`scripted_visible`). Null for a fixed visibility.
    nlohmann::json               visible_setting;
    bool                         scripted_visible { false };
    int32_t                      version { 0 };
    std::vector<WPMaterial>      materials;
    std::vector<std::string>     material_paths;
    std::vector<WPMaterialPass>  passes;
    std::vector<WPEffectCommand> commands;
    std::vector<WPEffectFbo>     fbos;
    std::vector<WPEffectFunction> functions;
    /// The position in the file's `passes` of each entry of `materials`: the instance's
    /// `passes` entry of that position overrides it.
    std::vector<std::size_t>     material_entries;
};

class WPImageObject {
public:
    struct Config {
        bool passthrough { false };
        bool model_passthrough { false };
    };

    bool FromJson(const nlohmann::json&, fs::VFS&);

    int32_t     id { 0 };
    int32_t     parent_id { -1 };  // -1: a layer of the scene itself
    std::string name;
    // Placement.
    std::array<float, 3> origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> angles { 0.0f, 0.0f, 0.0f };
    std::array<float, 2> size { 2.0f, 2.0f };
    // What the key reads when the file leaves it out.
    std::array<float, 2> parallaxDepth { 1.0f, 1.0f };
    std::array<float, 2> cropoffset { 0.0f, 0.0f };
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    // A picture stands in for the plain colour this layer is made of, and is drawn as it is: the
    // colour (and whatever property or script drives it) no longer tints it.
    bool                       colorIgnored { false };
    int32_t                    colorBlendMode { 0 };
    bool                       copybackground { true };
    float                      alpha { 1.0f };
    float                      brightness { 1.0f };
    bool                       fullscreen { false };
    bool                       nopadding { false };
    // The model's `instanced` flag (Wallpaper Engine `sub_1401FAC50`, layer flag 0x800).
    bool                       instanced { false };
    // How the layer's texture (`_rt_imageLayerComposite_<id>`) is addressed
    // outside 0..1. Unspecified keeps the historical clamp.
    bool                       clampuvs { true };
    // Drawn through the perspective camera of a 2D scene instead of the flat view.
    bool                       perspective { false };
    // Point-samples the layer's own render targets (the ping-pong pair its
    // effects run through and the composite other layers read), as a texture
    // whose header asks for it is sampled. Off by default.
    bool                       nointerpolation { false };
    // Script-visible members kept for their readers (an LED source, the shadow caster pass).
    bool                       ledsource { false };
    bool                       castshadow { false };
    // Cursor targeting: `solid` layers are hit-tested, on by default, and a layer
    // with `disablepropagation` hides the layers behind it from the cursor where
    // it is under it.
    bool                       solid { true };
    bool                       disablepropagation { false };
    bool                       visible { true };
    // The model's own flags (`models/util/*.json`): `autosize` sizes the layer from
    // its texture, or from the scene's canvas with `projectlayer`, instead of from
    // the object's `size`; `solidlayer` marks a layer drawn as a flat colour.
    bool                       autosize { false };
    bool                       projectlayer { false };
    bool                       solidlayer { false };
    // Set when a script or user property drives the value, so it is bound rather than read once.
    bool dynamic_origin { false };
    bool dynamic_visible { false };
    bool dynamic_alpha { false };

    std::string image;                      // model file
    std::string alignment { "center" };     // layout tests rely on this default

    // The setting objects as authored, whole, for the ones a property or script may drive.
    nlohmann::json origin_setting;
    nlohmann::json scale_setting;
    nlohmann::json angles_setting;
    nlohmann::json visible_setting;
    nlohmann::json alpha_setting;

    WPMaterial                 material;        // the layer's own pass
    std::vector<WPImageEffect> effects;         // run in order over the layer's picture
    Config                     config;
    std::vector<int32_t>       dependencies;    // ids of the layers this one depends on
    nlohmann::json             field_bindings;

    std::string                                puppet;
    std::vector<WPPuppetLayer::AnimationLayer> puppet_layers;
    // Raw "animationlayers" entries, parallel to puppet_layers, so the parser
    // can bind visible/rate/blend to user properties.
    std::vector<nlohmann::json>                puppet_layer_settings;
    std::string                                attachment;
};

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPEffectFbo, name, scale);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPImageEffect, name, visible, passes, fbos, materials);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPImageObject, name, origin, angles, scale, size, visible,
                                   material, effects, autosize, cropoffset);

} // namespace wpscene
} // namespace wallpaper
