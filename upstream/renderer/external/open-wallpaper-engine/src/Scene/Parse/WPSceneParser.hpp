#pragma once
#include "Interface/ISceneParser.h"

#include <cmath>
#include <string>
#include <string_view>
#include <random>
#include <vector>

namespace wallpaper
{
/// The exponent of the alpha Wallpaper Engine's glyph pass leaves in a text composite. The pass
/// blends with `SRC_ALPHA / INV_SRC_ALPHA` on colour and on alpha alike (the D3D translucent
/// blend of its font material; the alpha factor is decoded from denormal constants, so it is
/// inferred), so over a card whose alpha starts at zero the glyph's alpha `a` lands as `a * a`:
/// the colour carries one factor of `a` and the alpha this exponent, and the card goes onto the
/// scene by that alpha. Text through an `opacity` effect then stands at `a ^ (1 + exponent)`,
/// `a` cubed, which is what Wallpaper Engine's frames show (black text at 0.65 and 0.5 over
/// white stands at 0.275 and 0.125). One frame of a `skew` chain stands at `a` squared instead,
/// which an exponent of 1 would give (and an `opacity` effect fed the layer's alpha would then
/// supply the third factor): see docs/testing/renderer.md. One constant, so that a capture that
/// settles it changes this line, and every expectation is derived from it.
inline constexpr float kTextCompositeAlphaExponent = 2.0f;

/// How far from the scene behind it towards its own colour text of alpha `alpha` stands when it
/// goes through a composite: the share of the colour that lands on the scene.
inline float TextCompositeReach(float alpha) {
    return std::pow(alpha, 1.0f + kTextCompositeAlphaExponent);
}

struct SceneMaterial;
struct WPShaderInfo;
class RuntimeImageSource;

namespace wpscene
{
class WPMaterial;
struct WPUserTexture;
}

/// Substitutes the texture slots a material delegates. Two kinds arrive in the
/// same `usertextures` list: the cover slots the runtime supplies itself, and a
/// slot that names one of the wallpaper's own `scenetexture` properties. The
/// second kind needs the property table to resolve, so a parse without one
/// leaves those slots on their authored texture.
///
/// A cover slot whose position also has an authored texture keeps that texture
/// until the runtime has a cover to show, as Wallpaper Engine does, when
/// `covers` is given: the slot is then bound through `BindCoverSlot` and holds
/// the name that shows the authored picture until a cover arrives. Without
/// `covers` it names the cover itself.
///
/// A cover slot whose authored texture is a render target (another layer's
/// composite: a default cover a layer of its own draws) keeps that target when
/// `target_covers` is given, and the cover's name goes into `target_covers` at
/// the slot's position, for the renderer to bind in its place while a cover is
/// published (`SceneMaterial::texture_covers`). Without it the slot names the
/// cover itself.
void ApplySystemUserTextures(std::vector<std::string>& textures,
                             const std::vector<wpscene::WPUserTexture>& usertextures,
                             const ProjectProperties* properties = nullptr,
                             RuntimeImageSource* covers = nullptr,
                             std::vector<std::string>* target_covers = nullptr);
/// The property a `usertextures` slot names (the bare-string form), or empty for
/// a slot the runtime supplies or one that names nothing. The scene reads such a
/// property once, while it loads.
std::string_view UserTexturePropertyName(const wpscene::WPUserTexture& user_texture);
void LoadMaterialConstantShaderValues(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                      const WPShaderInfo& info);

class WPSceneParser : public ISceneParser {
public:
    WPSceneParser()  = default;
    ~WPSceneParser() = default;
    std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) override;
    std::shared_ptr<Scene> Parse(std::string_view scene_id, const std::string&, fs::VFS&, audio::SoundManager&);
};
} // namespace wallpaper
