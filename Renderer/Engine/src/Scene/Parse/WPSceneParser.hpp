#pragma once
#include "Interface/ISceneParser.h"

#include <cmath>
#include <cstddef>
#include <string>
#include <string_view>
#include <random>
#include <utility>
#include <vector>

namespace wallpaper
{
/// The alpha a translucent draw of alpha `src` leaves over a target of alpha `dst`: Wallpaper
/// Engine's translucent blend is `SRC_ALPHA / INV_SRC_ALPHA` on colour and on alpha alike
/// (`sub_140099F60`; `MetalBlend`'s `AlphaBlendRule::Material`).
inline float TranslucentBlendAlpha(float src, float dst) {
    return src * src + dst * (1.0f - src);
}

/// How far from the scene behind it towards its own colour text of alpha `alpha` stands when it
/// goes through a composite: the glyphs blend translucent into a seed of alpha 0, so the colour
/// carries one factor of `alpha` and the composite's alpha is `TranslucentBlendAlpha(alpha, 0)`,
/// by which the composite goes onto the scene: `alpha` cubed, what Wallpaper Engine's frames
/// show (black text at 0.65 and 0.5 over white stands at 0.275 and 0.125, docs/testing/renderer.md).
inline float TextCompositeReach(float alpha) {
    return alpha * TranslucentBlendAlpha(alpha, 0.0f);
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
void ApplySystemUserTextures(std::vector<std::string>& textures,
                             const std::vector<wpscene::WPUserTexture>& usertextures,
                             const ProjectProperties* properties = nullptr,
                             RuntimeImageSource* covers = nullptr);
/// The property a `usertextures` slot names (the bare-string form), or empty for
/// a slot the runtime supplies or one that names nothing. The scene reads such a
/// property once, while it loads.
std::string_view UserTexturePropertyName(const wpscene::WPUserTexture& user_texture);
void LoadMaterialConstantShaderValues(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                      const WPShaderInfo& info);

/// Gathers, for the scope it lives in, the material constants that name no uniform of
/// their shader, and says them once when the scope ends.
///
/// Such a key is an authored leftover, not a binding failure: Wallpaper Engine keeps a
/// constant in the material after its uniform is renamed, removed or compiled out by a
/// combo, and ignores it, as this parser does. A scene can hold the same leftover in
/// every material (a model importer's `Alpha` and `Color` on five hundred models), so
/// one line per material buried every real error of the load under a thousand of these.
/// A scene parse holds one tally and logs one informational line naming each key and how
/// often it came up; a constant loaded outside any tally is still reported on its own.
///
/// Tallies nest and belong to the thread that made them: the innermost one takes the
/// keys, and another scene loading on another thread has its own.
class UnmatchedConstantTally {
public:
    UnmatchedConstantTally();
    ~UnmatchedConstantTally();
    UnmatchedConstantTally(const UnmatchedConstantTally&)            = delete;
    UnmatchedConstantTally& operator=(const UnmatchedConstantTally&) = delete;

    /// Adds `key` to the innermost tally of this thread. False when there is none.
    static bool Note(const std::string& key);
    /// The line the tally logs: each key with its count, in key order, the first
    /// `kNamed` of them by name and the rest as a number. Empty when nothing was noted.
    std::string Summary() const;

    /// How many keys the summary names before it counts the rest.
    static constexpr std::size_t kNamed = 12;

private:
    std::vector<std::pair<std::string, std::size_t>> m_counts;
    UnmatchedConstantTally*                          m_outer;
};

class WPSceneParser : public ISceneParser {
public:
    WPSceneParser()  = default;
    ~WPSceneParser() = default;
    std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) override;
    std::shared_ptr<Scene> Parse(std::string_view scene_id, const std::string&, fs::VFS&, audio::SoundManager&);
};
} // namespace wallpaper
