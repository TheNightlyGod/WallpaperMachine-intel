// Text shaping with HarfBuzz for text layers, as Wallpaper Engine 2.8.0.42 shapes them
// (artifacts/we-parity/decompiles/G-F1.md, G-F2.md): one HarfBuzz font per FreeType face
// (hb_ft_font_create in sub_1401ACAF0), and each run of one face shaped on its own with the
// direction and script HarfBuzz guesses for it (hb_buffer_guess_segment_properties in
// sub_1401B0410), default features and no bidi reordering between runs.
#pragma once

#include <cstdint>
#include <span>
#include <utility>
#include <vector>

#include <ft2build.h>
#include FT_FREETYPE_H

struct hb_buffer_t;
struct hb_font_t;

namespace wallpaper
{

// One shaped glyph, in the order HarfBuzz gives them (visual order within the run).
// `cluster` is the index in the run of the first code point the glyph stands for; the
// distances are 26.6 fixed point at the face's size.
struct ShapedGlyph {
    uint32_t glyph_index { 0 };
    uint32_t cluster { 0 };
    int32_t  x_advance { 0 };
    int32_t  x_offset { 0 };
    int32_t  y_offset { 0 };
};

// The HarfBuzz fonts of one layout. The faces must stay sized as they were when first shaped
// with and outlive the shaper; the caller holds the FreeType lock throughout.
class TextShaper {
public:
    TextShaper();
    ~TextShaper();
    TextShaper(const TextShaper&)            = delete;
    TextShaper& operator=(const TextShaper&) = delete;

    // Shapes `codepoints`, all drawn with `face`.
    std::vector<ShapedGlyph> ShapeRun(FT_Face face, std::span<const uint32_t> codepoints);

private:
    hb_font_t* FontFor(FT_Face face);

    std::vector<std::pair<FT_Face, hb_font_t*>> m_fonts;
    hb_buffer_t*                                m_buffer { nullptr };
};

} // namespace wallpaper
