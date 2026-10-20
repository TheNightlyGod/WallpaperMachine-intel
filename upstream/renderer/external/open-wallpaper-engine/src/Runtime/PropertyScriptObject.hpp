#pragma once

#include <cstdint>

namespace wallpaper
{

/// What a property script's `thisObject` is, Wallpaper Engine's
/// `IThisPropertyObject`: the layer the setting belongs to (`thisLayer`), unless
/// the setting belongs to one of the layer's animation layers or decides one of
/// its effects' visibility.
struct PropertyScriptObject {
    /// The animation layer (`animationlayers[i]`) the setting belongs to, which
    /// is then `thisObject`; -1 for a setting of the layer.
    int animation_layer_index { -1 };
    /// The setting is an effect's visibility: `thisObject` is that effect, and
    /// what the script writes to its `visible` is the setting's value.
    bool effect_visibility { false };
    /// The timeline bound to the setting itself, which `thisObject.getAnimation()`
    /// returns when it is given no name
    /// (`SceneRuntimeContext::RegisterPropertyAnimation`); 0 when it has none.
    uint64_t property_animation { 0 };
};

} // namespace wallpaper
