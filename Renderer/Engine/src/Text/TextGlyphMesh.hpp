// The mesh a text layer draws, and publishing its glyph atlases: shared by the parser, which
// builds them as the scene loads, and the runtime, which rewrites them on every relayout.
#pragma once

#include "Text/TextLayer.hpp"

#include <cstddef>
#include <memory>
#include <span>
#include <string_view>

namespace wallpaper
{
class SceneMesh;
class RuntimeImageSource;
struct SceneMaterial;
struct Image;

/// The submeshes of a text layer's mesh (Wallpaper Engine's draw order, decompiles/G-F9.md):
/// the background or composite seed quad, the mono or distance-field glyphs, the colour glyphs.
inline constexpr std::size_t kTextBackgroundSubmesh = 0;
inline constexpr std::size_t kTextGlyphSubmesh      = 1;
inline constexpr std::size_t kTextColorGlyphSubmesh = 2;

/// A text layer's mesh: the card quad over `[left, right] x [bottom, top]` in submesh 0 and
/// the build's glyphs in submeshes 1 and 2, each drawn with its own material slot. The mesh is
/// rewritten only when the text is laid out again (`MeshUpdate::OnEvent`).
std::shared_ptr<SceneMesh> MakeTextLayerMesh(const TextLayerRenderBounds& card, const TextGlyphBuild& build);

/// Writes `quads` into submesh `index`, growing its arrays (to the next power of two of at
/// least 64 glyphs) when they no longer hold them, and marks the mesh changed.
void WriteTextGlyphSubmesh(SceneMesh& mesh, std::size_t index, std::span<const TextGlyphQuad> quads);

/// Publishes the build's atlases under `TextAtlasName` / `TextColorAtlasName` of `layer_key`;
/// the colour atlas is a transparent texel while the text has no colour glyph. An atlas whose
/// pixels are what the name holds already is left alone.
void PublishTextAtlases(RuntimeImageSource& images, std::string_view layer_key, const TextGlyphBuild& build);

/// Hands the atlases' sizes to the glyph materials (`g_Texture0Resolution`, and
/// `g_Texture1Resolution` for a distance-field colour material), as the font shader reads them.
void SetTextAtlasResolutions(SceneMaterial* glyphs, SceneMaterial* color_glyphs, const TextGlyphBuild& build);

/// A temporary quarter-resolution image for a particle emitter that explicitly samples text.
/// Uses the already-published mesh and atlases, with no shaping or persistent layer bitmap.
/// `frame` is the source texture's local frame; the caller supplies the downsampled dimensions.
std::shared_ptr<Image> RenderTextEmissionImage(
    const SceneMesh& mesh, RuntimeImageSource& images, const TextLayerRenderFrame& frame,
    bool distance_field, const TextStyleUniforms& style, uint32_t width, uint32_t height,
    const SceneMaterial* background = nullptr);

} // namespace wallpaper
