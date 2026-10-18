#pragma once
#include <string_view>
#include <cstdint>
#include "Core/Literals.hpp"
#include "Core/StringHelper.hpp"
#include "Utils/String.h"

namespace wallpaper
{

#define BASE_GLTEX_NAMES(ext)                                                                      \
    "g_Texture0" #ext, "g_Texture1" #ext, "g_Texture2" #ext, "g_Texture3" #ext, "g_Texture4" #ext, \
        "g_Texture5" #ext, "g_Texture6" #ext, "g_Texture7" #ext, "g_Texture8" #ext,                \
        "g_Texture9" #ext, "g_Texture10" #ext, "g_Texture11" #ext, "g_Texture12" #ext

constexpr std::array WE_GLTEX_NAMES { BASE_GLTEX_NAMES() };
constexpr std::array WE_GLTEX_RESOLUTION_NAMES { BASE_GLTEX_NAMES(Resolution) };
constexpr std::array WE_GLTEX_ROTATION_NAMES { BASE_GLTEX_NAMES(Rotation) };
constexpr std::array WE_GLTEX_TRANSLATION_NAMES { BASE_GLTEX_NAMES(Translation) };
constexpr std::array WE_GLTEX_MIPMAPINFO_NAMES { BASE_GLTEX_NAMES(MipMapInfo) };
/// Wallpaper Engine's per-texture step: (1 / width, 1 / height, width, height)
/// of the texture a slot samples.
constexpr std::array WE_GLTEX_TEXEL_NAMES { BASE_GLTEX_NAMES(Texel) };
#undef BASE_GLTEX_NAMES

constexpr std::string_view WE_SPEC_PREFIX { "_rt_" };
constexpr std::string_view WE_ALIAS_PREFIX { "_alias_" };
constexpr std::string_view WE_IMAGE_LAYER_COMPOSITE_PREFIX { "_rt_imageLayerComposite_" };
constexpr std::string_view WE_HALF_COMPO_BUFFER_PREFIX { "_rt_HalfCompoBuffer" };
constexpr std::string_view WE_QUARTER_COMPO_BUFFER_PREFIX { "_rt_QuarterCompoBuffer" };
constexpr std::string_view WE_FULL_COMPO_BUFFER_PREFIX { "_rt_FullCompoBuffer" };
constexpr std::string_view WE_MIP_MAPPED_FRAME_BUFFER { "_rt_MipMappedFrameBuffer" };

constexpr std::string_view WE_EFFECT_PPONG_PREFIX { "_rt_effect_pingpong_" };
constexpr std::string_view WE_EFFECT_PPONG_PREFIX_A { "_rt_effect_pingpong_a_" };
constexpr std::string_view WE_EFFECT_PPONG_PREFIX_B { "_rt_effect_pingpong_b_" };

constexpr std::string_view WE_IN_POSITION { "a_Position" };
constexpr std::string_view WE_IN_TEXCOORD { "a_TexCoord" };
constexpr std::string_view WE_IN_NORMAL { "a_Normal" };
/// The signed tangent of a model (xyz, and the bitangent's handedness in w).
/// Wallpaper Engine's model shaders declare it `attribute vec4 a_Tangent4`, and
/// a renderer hands a shader input the mesh attribute of the same name, so the
/// mesh has to use that spelling: under any other the input is left unbound.
constexpr std::string_view WE_IN_TANGENT { "a_Tangent4" };
constexpr std::string_view WE_IN_BLENDINDICES { "a_BlendIndices" };
constexpr std::string_view WE_IN_BLENDWEIGHTS { "a_BlendWeights" };

// particle

constexpr std::string_view WE_IN_POSITIONVEC4 { "a_PositionVec4" };
constexpr std::string_view WE_IN_COLOR { "a_Color" };
constexpr std::string_view WE_IN_TEXCOORDVEC4 { "a_TexCoordVec4" };
constexpr std::string_view WE_IN_TEXCOORDVEC4C1 { "a_TexCoordVec4C1" };
constexpr std::string_view WE_IN_TEXCOORDVEC4C2 { "a_TexCoordVec4C2" };
constexpr std::string_view WE_IN_TEXCOORDVEC4C3 { "a_TexCoordVec4C3" };
constexpr std::string_view WE_IN_TEXCOORDVEC3C2 { "a_TexCoordVec3C2" };
constexpr std::string_view WE_IN_TEXCOORDC2 { "a_TexCoordC2" };
constexpr std::string_view WE_IN_TEXCOORDC3 { "a_TexCoordC3" };
constexpr std::string_view WE_IN_TEXCOORDC4 { "a_TexCoordC4" };
constexpr std::string_view WE_CB_THICK_FORMAT { "THICKFORMAT" };
/// Set on a mesh the sprite-particle generator owns: its vertex stream is
/// rewritten every frame from the simulation, in the billboard-quad layout
/// `GenParticleData` writes. A renderer needs a positive statement of that,
/// because "the mesh is dynamic" is shared with every other per-frame
/// geometry in the engine and says nothing about the layout.
constexpr std::string_view WE_PRENDER_SPRITE { "PRENDER_SPRITE" };
constexpr std::string_view WE_PRENDER_ROPE { "PRENDER_ROPE" };
/// Set on a particle mesh drawn by a trail renderer, next to the marker of the
/// generator that fills it: with `WE_PRENDER_SPRITE` it is a sprite trail, whose
/// stretch the author's vertex shader derives from the velocity the thick
/// sprite record already carries; with `WE_PRENDER_ROPE` it is a rope trail.
constexpr std::string_view WE_PRENDER_TRAIL { "PRENDER_TRAIL" };
/// Set on a rope trail's mesh, together with the two above. Its segments follow
/// one particle's own recorded path rather than joining neighbouring particles,
/// so a renderer can name the case without re-reading the project file.
constexpr std::string_view WE_PRENDER_ROPETRAIL { "PRENDER_ROPETRAIL" };

constexpr std::string_view G_M { "g_ModelMatrix" };
constexpr std::string_view G_VP { "g_ViewProjectionMatrix" };
constexpr std::string_view G_MVP { "g_ModelViewProjectionMatrix" };
constexpr std::string_view G_AM { "g_AltModelMatrix" };
constexpr std::string_view G_MI { "g_ModelMatrixInverse" };
constexpr std::string_view G_MVPI { "g_ModelViewProjectionMatrixInverse" };
constexpr std::string_view G_ETVP { "g_EffectTextureProjectionMatrix" };
constexpr std::string_view G_ETVPI { "g_EffectTextureProjectionMatrixInverse" };
constexpr std::string_view G_LP { "g_LightsPosition" };
constexpr std::string_view G_LCP { "g_LightsColorPremultiplied" };
constexpr std::string_view G_EYEPOSITION { "g_EyePosition" };
constexpr std::string_view G_VIEWFORWARD { "g_ViewForward" };
constexpr std::string_view G_VIEWUP { "g_ViewUp" };
constexpr std::string_view G_VIEWRIGHT { "g_ViewRight" };

constexpr std::string_view G_TIME { "g_Time" };
constexpr std::string_view G_DAYTIME { "g_DayTime" };
constexpr std::string_view G_POINTERPOSITION { "g_PointerPosition" };
constexpr std::string_view G_POINTERPOSITIONLAST { "g_PointerPositionLast" };
constexpr std::string_view G_POINTERSTATE { "g_PointerState" };
constexpr std::string_view G_FRAMETIME { "g_Frametime" };
constexpr std::string_view G_TEXTUREREDUCTIONSCALE { "g_TextureReductionScale" };
constexpr std::string_view G_EFFECTMODEL { "g_EffectModelMatrix" };
constexpr std::string_view G_EFFECTMVP { "g_EffectModelViewProjectionMatrix" };
constexpr std::string_view G_EFFECTMVPI { "g_EffectModelViewProjectionMatrixInverse" };
constexpr std::string_view G_TEXELSIZE { "g_TexelSize" };
constexpr std::string_view G_TEXELSIZEHALF { "g_TexelSizeHalf" };
constexpr std::string_view G_BONES { "g_Bones" };
constexpr std::string_view G_SCREEN { "g_Screen" };
constexpr std::string_view G_PARALLAXPOSITION { "g_ParallaxPosition" };
constexpr std::string_view G_ORIENTATIONUP { "g_OrientationUp" };
constexpr std::string_view G_ORIENTATIONRIGHT { "g_OrientationRight" };
constexpr std::string_view G_ORIENTATIONFORWARD { "g_OrientationForward" };

constexpr std::string_view SpecTex_Default { "_rt_default" };
constexpr std::string_view SpecTex_Link { "_rt_link_" };

inline bool IsImplicitSpecTex(const std::string_view name) {
    return !name.empty() && name.front() == '_' && name.find('/') == std::string_view::npos &&
           name.find('.') == std::string_view::npos;
}
inline bool IsSpecTex(const std::string_view name) {
    return sstart_with(name, WE_SPEC_PREFIX) || sstart_with(name, WE_ALIAS_PREFIX) ||
           IsImplicitSpecTex(name);
}
inline std::string EnsureSpecTexName(const std::string_view name) {
    if (name.empty() || IsSpecTex(name)) return std::string(name);
    return std::string(WE_SPEC_PREFIX) + std::string(name);
}
inline bool IsSpecLinkTex(const std::string_view name) { return sstart_with(name, SpecTex_Link); }
inline uint32_t ParseLinkTex(const std::string_view name) {
    std::string sid { name };
    sid = sid.substr(9);
    uint32_t result { 0 };
    STRTONUM(sid, result);
    return result;
}
inline std::string GenLinkTex(idx id) { return std::string(SpecTex_Link) + std::to_string(id); }
inline std::string LayerCompositeTargetKey(idx id) {
    return std::string(WE_IMAGE_LAYER_COMPOSITE_PREFIX) + std::to_string(id);
}
/// The layer-local camera layer `id` is drawn through into its composite target.
inline std::string LayerCompositeCameraKey(idx id) {
    return "layer_composite_camera_" + std::to_string(id);
}
/// The camera a fullscreen layer's result is drawn through: the whole canvas,
/// whatever a camera layer does to the view of the scene.
constexpr std::string_view FullscreenLayerCamera { "fullscreen" };

} // namespace wallpaper
