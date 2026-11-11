#include "Text/TextShaper.hpp"

#include <hb-ft.h>
#include <hb.h>

namespace wallpaper
{

TextShaper::TextShaper(): m_buffer(hb_buffer_create()) {}

TextShaper::~TextShaper() {
    for (auto& [face, font] : m_fonts) hb_font_destroy(font);
    hb_buffer_destroy(m_buffer);
}

hb_font_t* TextShaper::FontFor(FT_Face face) {
    for (auto& [held, font] : m_fonts) {
        if (held == face) return font;
    }
    // Wallpaper Engine uses hb_ft_font_create with HarfBuzz's default load flags, which read
    // the glyphs unhinted (G-F1.md); the referenced form keeps the face alive with the font.
    hb_font_t* font = hb_ft_font_create_referenced(face);
    hb_ft_font_set_load_flags(font, FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING);
    m_fonts.emplace_back(face, font);
    return font;
}

std::vector<ShapedGlyph> TextShaper::ShapeRun(FT_Face face, std::span<const uint32_t> codepoints) {
    std::vector<ShapedGlyph> out;
    if (face == nullptr || codepoints.empty() || ! hb_buffer_allocation_successful(m_buffer)) return out;
    hb_font_t* font = FontFor(face);
    hb_buffer_clear_contents(m_buffer);
    const auto length = static_cast<int>(codepoints.size());
    hb_buffer_add_utf32(m_buffer, codepoints.data(), length, 0, length);
    hb_buffer_guess_segment_properties(m_buffer);
    hb_shape(font, m_buffer, nullptr, 0);

    unsigned int               count     = 0;
    const hb_glyph_info_t*     infos     = hb_buffer_get_glyph_infos(m_buffer, &count);
    const hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(m_buffer, nullptr);
    out.reserve(count);
    for (unsigned int index = 0; index < count; ++index) {
        out.push_back(ShapedGlyph { .glyph_index = infos[index].codepoint,
                                    .cluster     = infos[index].cluster,
                                    .x_advance   = positions[index].x_advance,
                                    .x_offset    = positions[index].x_offset,
                                    .y_offset    = positions[index].y_offset });
    }
    return out;
}

} // namespace wallpaper
