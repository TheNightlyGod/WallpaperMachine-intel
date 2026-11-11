// Stand-ins for Wallpaper Engine's font materials (`materials/fonts/*.json`) and the `font` and
// `flat` shaders they name, for tests that parse text layers without the wallpaper assets. The
// materials have the shipped ones' shape (shader, blending, depth words, combos); the shaders are
// written here and draw what the shipped ones draw: the layer's colour at the atlas's coverage (mono), a
// distance field's median past its edge (MSDF) with the outline and drop shadow the style's
// render variables ask for, or the colour atlas.
#pragma once

#include <filesystem>
#include <fstream>
#include <map>
#include <string>

namespace wallpaper::test
{

inline std::map<std::string, std::string> FontAssetFiles() {
    std::map<std::string, std::string> files;
    for (const bool color : { false, true }) {
        for (const bool msdf : { false, true }) {
            for (const bool depth : { false, true }) {
                std::string name = std::string("basefont") + (color ? "rgba" : "") + (msdf ? "_msdf" : "") +
                                   (depth ? "_depth" : "");
                std::string combos;
                if (color || msdf) {
                    combos = std::string(R"(,"combos":{)") + (color ? R"("COLORFONT":1)" : "") +
                             (color && msdf ? "," : "") + (msdf ? R"("MSDF":1)" : "") + "}";
                }
                files["/materials/fonts/" + name + ".json"] =
                    std::string(R"({"passes":[{"shader":"font","blending":"translucent","depthtest":")") +
                    (depth ? "enabled" : "disabled") + R"(","depthwrite":")" + (depth ? "enabled" : "disabled") +
                    R"(","cullmode":"nocull")" + combos + "}]}";
            }
        }
    }
    for (const bool depth : { false, true }) {
        files[std::string("/materials/fonts/fontbackground") + (depth ? "_depth" : "") + ".json"] =
            std::string(R"({"passes":[{"shader":"flat","blending":"translucent","depthtest":")") +
            (depth ? "enabled" : "disabled") + R"(","depthwrite":")" + (depth ? "enabled" : "disabled") +
            R"(","cullmode":"nocull"}]})";
    }
    files["/shaders/font.vert"] = R"(uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = mul(vec4(a_Position.xy, 0.0, 1.0), g_ModelViewProjectionMatrix);
  v_TexCoord = a_TexCoord;
}
)";
    // Written here, not copied: the distance a texel lies past the glyph's edge is its median's
    // offset from 0.5 times the field's range (g_RenderVar0.x, atlas pixels); the fill covers
    // what lies inside, an outline g_RenderVar0.y pixels further out takes g_RenderVar1's colour,
    // and a drop shadow is the same field read g_RenderVar1.w / g_RenderVar2.w pixels away, at
    // g_RenderVar3.x opacity in g_RenderVar2's colour, under the glyph.
    files["/shaders/font.frag"] = R"(uniform vec4 g_Color4;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
#if MSDF
uniform vec4 g_Texture0Resolution;
uniform vec4 g_RenderVar0;
#if OUTLINE_ENABLED || DROP_SHADOW_ENABLED
uniform vec4 g_RenderVar1;
#endif
#if DROP_SHADOW_ENABLED
uniform vec4 g_RenderVar2;
uniform vec4 g_RenderVar3;
#endif
float Distance(vec2 uv) {
  vec3 s = texSample2D(g_Texture0, uv).rgb;
  return (max(min(s.r, s.g), min(max(s.r, s.g), s.b)) - 0.5) * g_RenderVar0.x;
}
#endif
void main() {
#if MSDF
  float d = Distance(v_TexCoord);
  float fill = clamp(d + 0.5, 0.0, 1.0);
#if COLORFONT
  vec3 base = texSample2D(g_Texture1, v_TexCoord).rgb;
#else
  vec3 base = g_Color4.rgb;
#endif
#if OUTLINE_ENABLED
  vec4 glyph = vec4(mix(g_RenderVar1.rgb, base, fill), clamp(d + 0.5 + g_RenderVar0.y, 0.0, 1.0) * g_Color4.a);
#else
  vec4 glyph = vec4(base, fill * g_Color4.a);
#endif
#if DROP_SHADOW_ENABLED
  vec2 away = vec2(g_RenderVar1.w, g_RenderVar2.w) / g_Texture0Resolution.xy;
#if OUTLINE_ENABLED
  float reach = g_RenderVar0.y;
#else
  float reach = 0.0;
#endif
  float soft = max(g_RenderVar0.w, 0.5);
  float shadow = clamp(g_RenderVar3.x * smoothstep(-soft, soft, Distance(v_TexCoord - away) + reach), 0.0, 1.0) * g_Color4.a;
  float total = glyph.a + shadow * (1.0 - glyph.a);
  glyph = vec4((glyph.rgb * glyph.a + g_RenderVar2.rgb * shadow * (1.0 - glyph.a)) / max(total, 1e-6), total);
#endif
  gl_FragColor = glyph;
#else
#if COLORFONT
  vec4 c = texSample2D(g_Texture0, v_TexCoord);
  gl_FragColor = vec4(c.rgb, c.a * g_Color4.a);
#else
  gl_FragColor = vec4(g_Color4.rgb, texSample2D(g_Texture0, v_TexCoord).r * g_Color4.a);
#endif
#endif
}
)";
    files["/shaders/flat.vert"] = R"(uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
void main() {
  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
}
)";
    files["/shaders/flat.frag"] = R"(uniform float g_Alpha;
uniform vec3 g_Color;
void main() {
  gl_FragColor = vec4(g_Color, g_Alpha);
}
)";
    return files;
}

/// The stand-ins written under an assets folder `root` (as `root/materials/fonts/...`), for a
/// fixture that mounts a directory; files already there are kept.
inline void WriteFontAssets(const std::filesystem::path& root) {
    for (const auto& [path, body] : FontAssetFiles()) {
        const auto file = root / path.substr(1);
        if (std::filesystem::exists(file)) continue;
        std::filesystem::create_directories(file.parent_path());
        std::ofstream(file) << body;
    }
}

/// `files` with the stand-ins added where it has none of its own.
inline std::map<std::string, std::string> WithFontAssets(std::map<std::string, std::string> files) {
    for (auto& [path, body] : FontAssetFiles()) files.emplace(path, body);
    return files;
}

} // namespace wallpaper::test
