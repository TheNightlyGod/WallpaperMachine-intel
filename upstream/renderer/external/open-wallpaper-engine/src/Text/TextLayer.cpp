#include "Text/TextLayer.hpp"
#include "Text/SystemFontResolver.hpp"

#include <algorithm>
#include <atomic>
#include <array>
#include <cmath>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string_view>
#include <type_traits>
#include <utility>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_ADVANCES_H

namespace wallpaper
{

namespace
{
// Wallpaper Engine sets a face's size in points at 300 dpi, so one point of
// `pointsize` is 300 / 72 pixels, and clamps `pointsize` to 1..256 first.
constexpr float kTextDpi       = 300.0f;
constexpr float kPointsPerInch = 72.0f;
constexpr float kMinPointSize  = 1.0f;
constexpr float kMaxPointSize  = 256.0f;
#ifdef WESCENE_BUILD_TESTS
std::atomic_uint64_t g_measurement_count { 0 };
std::atomic_uint64_t g_fallback_requests { 0 };
#endif
std::mutex g_freetype_mutex;

class FtLibrary {
public:
    static FtLibrary& Get() {
        static FtLibrary instance;
        return instance;
    }

    FT_Library handle() const { return m_library; }

private:
    FtLibrary() {
        if (FT_Init_FreeType(&m_library) != 0) m_library = nullptr;
    }

    ~FtLibrary() {
        if (m_library != nullptr) FT_Done_FreeType(m_library);
    }

    FtLibrary(const FtLibrary&)            = delete;
    FtLibrary& operator=(const FtLibrary&) = delete;

    FT_Library m_library { nullptr };
};

struct FtFaceDeleter {
    void operator()(FT_Face face) const {
        if (face != nullptr) FT_Done_Face(face);
    }
};

float ClampedPointSize(float point_size) {
    if (! std::isfinite(point_size)) point_size = 12.0f;
    return std::clamp(point_size, kMinPointSize, kMaxPointSize);
}

// The size in whole pixels of a point size as the layout and fallback
// estimates see it. A real face is sized by `FreeTypeCharHeight` instead, which
// leaves the rounding to FreeType as Wallpaper Engine does.
float PointSizeToPixels(float point_size) {
    return ClampedPointSize(point_size) * kTextDpi / kPointsPerInch;
}

// The nominal height Wallpaper Engine requests from FreeType: `pointsize` in
// 26.6 fixed point, truncated.
FT_F26Dot6 FreeTypeCharHeight(float point_size) {
    return static_cast<FT_F26Dot6>(static_cast<int>(ClampedPointSize(point_size) * 64.0f));
}

// One placed glyph. Distances are pixels, `advance` is the pen step including
// the layer's `spacing.x`, and the ink box is relative to the pen and the
// baseline (y up). A glyph without ink, a space, has an empty box at the pen.
struct GlyphRun {
    uint32_t codepoint { 0 };
    float    advance { 0.0f };
    // The face that draws the glyph: 0 is the layer's font, then the faces of the
    // fallback chain in the order the layout opened them (`FaceChain`).
    uint8_t  face { 0 };
    float    left { 0.0f };
    float    right { 0.0f };
    float    top { 0.0f };
    float    bottom { 0.0f };
    bool     has_ink { false };
    // What `advance` is made of: the glyph's unhinted advance and the kerning it
    // takes against the glyph after it, in 26.6 fixed point.
    uint32_t glyph_index { 0 };
    int32_t  advance_26_6 { 0 };
    int32_t  kerning_26_6 { 0 };
};

// One row of text. Its extents are those of the ink and of the pen at every
// glyph start, always including the row origin, as Wallpaper Engine measures
// them: a trailing advance that carries no ink is not part of the row.
struct LineRun {
    std::vector<GlyphRun> glyphs;
    float                 advance_width { 0.0f };
    float                 bounds_left { 0.0f };
    float                 bounds_right { 0.0f };
    float                 bounds_top { 0.0f };
    float                 bounds_bottom { 0.0f };
    // The row ended at an automatic word wrap and a row follows it; the only
    // kind of row `blockalign` justifies.
    bool                  wrapped { false };

    float ExtentRight() const { return bounds_right; }
    float LayoutWidth() const { return bounds_right - bounds_left; }
};

// What a face gives the layout: the ascender and descender in whole pixels (the
// descender as a distance below the baseline) and the pitch of one row.
struct FaceLayoutMetrics {
    float ascender { 0.0f };
    float descender { 0.0f };
    float pitch { 0.0f };
};

// A text block's box. `top` and `bottom` are heights above the first row's
// baseline, y up; rows step down by `pitch`. `widest_row` is the width of the widest
// row, which the rows are aligned within.
struct TextBlock {
    float    min_x { 0.0f };
    float    max_x { 0.0f };
    float    top { 0.0f };
    float    bottom { 0.0f };
    float    ascender { 0.0f };
    float    descender { 0.0f };
    float    pitch { 0.0f };
    float    widest_row { 0.0f };
    uint32_t rows { 0 };

    float Width() const { return max_x - min_x; }
    float Height() const { return top - bottom; }
};

uint8_t ColorByte(float value) {
    if (! std::isfinite(value)) value = 1.0f;
    value = std::clamp(value, 0.0f, 1.0f);
    return static_cast<uint8_t>(std::lround(value * 255.0f));
}

std::array<uint8_t, 4> TextColorBytes(const TextLayerState& state) {
    const float brightness =
        std::isfinite(state.brightness) ? std::max(0.0f, state.brightness) : 1.0f;
    return {
        ColorByte(state.color.x() * brightness),
        ColorByte(state.color.y() * brightness),
        ColorByte(state.color.z() * brightness),
        ColorByte(state.alpha),
    };
}

using OwnedFace = std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter>;

// Sizes `face` as Wallpaper Engine does: `point_size` points at 300 dpi.
bool SetFaceSize(FT_Face face, float point_size) {
    return FT_Set_Char_Size(face, 0, FreeTypeCharHeight(point_size), static_cast<FT_UInt>(kTextDpi),
                            static_cast<FT_UInt>(kTextDpi)) == 0;
}

// A face of a font the wallpaper ships, which is in memory already.
OwnedFace CreateFreeTypeFaceFromBytes(const std::vector<uint8_t>& data, float point_size) {
    FT_Library library = FtLibrary::Get().handle();
    if (library == nullptr) return nullptr;
    if (data.empty()) return nullptr;

    FT_Face raw_face = nullptr;
    if (FT_New_Memory_Face(library,
                           reinterpret_cast<const FT_Byte*>(data.data()),
                           static_cast<FT_Long>(data.size()),
                           0,
                           &raw_face) != 0) {
        return nullptr;
    }

    OwnedFace face(raw_face);
    if (! SetFaceSize(raw_face, point_size)) return nullptr;
    return face;
}

bool HasPostScriptName(FT_Face face, const std::string& name) {
    const char* face_name = FT_Get_Postscript_Name(face);
    return face_name != nullptr && name == face_name;
}

// The faces opened from font files, kept for the layouts after the one that opened
// them. A text layer lays out again for every change of its text, and a clock
// changes every second; a system font file can be tens of megabytes (PingFang is
// 78), so a layout must not read it. Wallpaper Engine keeps the faces it loads by
// path as well.
//
// A face is told apart by its file and its index in the file, and asked for by
// PostScript name: a file that holds a collection holds several faces, and the first
// is not the one the system means (PingFang.ttc starts with the Hong Kong cut, and
// Songti.ttc with a weight that is not the regular one). Every use is under
// `g_freetype_mutex`. A layout touches a handful of faces at most and takes them
// last, so the ones it is using are the newest when the cache drops its oldest.
//
// FreeType maps a file it opens and reads the glyphs out of the mapping, so a file
// truncated or rewritten in place under an open face (a font a user installed and then
// replaced) would fault the read. `Refresh` therefore drops the faces whose file is
// gone or no longer has the size and modification time it had when it was opened,
// before a layout takes any face, so the next use opens the file as it is.
class FaceCache {
public:
    static constexpr std::size_t kCapacity = 8;

    static FaceCache& Get() {
        static FaceCache instance;
        return instance;
    }

    // Drops every face whose file has changed since it was opened. Called before a layout
    // takes its faces, so none is dropped while a layout holds it.
    void Refresh() {
        std::erase_if(m_entries, [](const Entry& entry) {
            if (FileStamp::Of(entry.path) == entry.stamp) return false;
            FT_Done_Face(entry.face);
            return true;
        });
    }

    // The face of `path` that has `postscript_name`, or the file's first face when
    // the name is empty or the file has no such face. Null when it cannot be opened.
    FT_Face Acquire(const std::string& path, const std::string& postscript_name) {
        if (path.empty()) return nullptr;
        if (Entry* entry = Find(path, postscript_name)) return Use(*entry);

        FT_Library library = FtLibrary::Get().handle();
        if (library == nullptr) return nullptr;
        FT_Face face = nullptr;
        if (FT_New_Face(library, path.c_str(), 0, &face) != 0) return nullptr;
        FT_Long index = 0;
        if (! postscript_name.empty() && ! HasPostScriptName(face, postscript_name)) {
            for (FT_Long other = 1; other < face->num_faces; ++other) {
                FT_Face candidate = nullptr;
                if (FT_New_Face(library, path.c_str(), other, &candidate) != 0) continue;
                if (HasPostScriptName(candidate, postscript_name)) {
                    FT_Done_Face(face);
                    face  = candidate;
                    index = other;
                    break;
                }
                FT_Done_Face(candidate);
            }
        }

        // The face may be held already, asked for by another name.
        const auto held = std::ranges::find_if(m_entries, [&](const Entry& entry) {
            return entry.index == index && entry.path == path;
        });
        if (held != m_entries.end()) {
            FT_Done_Face(face);
            held->names.push_back(postscript_name);
            return Use(*held);
        }

#ifdef WESCENE_BUILD_TESTS
        ++m_files_opened;
#endif
        m_entries.push_back(Entry { .path = path, .index = index, .face = face,
                                    .used = ++m_clock, .stamp = FileStamp::Of(path),
                                    .names = { postscript_name } });
        if (m_entries.size() > kCapacity) {
            const auto oldest = std::ranges::min_element(
                m_entries, {}, [](const Entry& entry) { return entry.used; });
            FT_Done_Face(oldest->face);
            m_entries.erase(oldest);
        }
        return face;
    }

#ifdef WESCENE_BUILD_TESTS
    uint64_t    FilesOpened() const { return m_files_opened; }
    std::size_t Size() const { return m_entries.size(); }
    // Whether every face reads from its file, not from a copy of the font in memory.
    bool FromFiles() const {
        return std::ranges::all_of(m_entries, [](const Entry& entry) {
            return entry.face->stream != nullptr && entry.face->stream->close != nullptr;
        });
    }
    void        Reset() {
        Clear();
        m_files_opened = 0;
    }
#endif

private:
    // The size and modification time of a file; two stamps are equal while the file is
    // the one that was opened. A file that cannot be read has the stamp of none.
    struct FileStamp {
        std::uintmax_t                  size { static_cast<std::uintmax_t>(-1) };
        std::filesystem::file_time_type time {};

        static FileStamp Of(const std::string& path) {
            std::error_code failure;
            FileStamp       stamp;
            stamp.size = std::filesystem::file_size(path, failure);
            if (failure) return {};
            stamp.time = std::filesystem::last_write_time(path, failure);
            return failure ? FileStamp {} : stamp;
        }
        bool operator==(const FileStamp&) const = default;
    };

    struct Entry {
        std::string path;
        FT_Long     index { 0 };
        FT_Face     face { nullptr };
        uint64_t    used { 0 };
        FileStamp   stamp;
        // What the face has been asked for by; the empty name is a request with none.
        std::vector<std::string> names;
    };

    // The statics are destroyed in reverse order of their construction: the library
    // goes after the faces made from it.
    FaceCache() { (void)FtLibrary::Get(); }
    ~FaceCache() { Clear(); }

    FaceCache(const FaceCache&)            = delete;
    FaceCache& operator=(const FaceCache&) = delete;

    void Clear() {
        for (auto& entry : m_entries) FT_Done_Face(entry.face);
        m_entries.clear();
    }

    Entry* Find(const std::string& path, const std::string& postscript_name) {
        for (auto& entry : m_entries) {
            if (entry.path == path && std::ranges::find(entry.names, postscript_name) != entry.names.end()) {
                return &entry;
            }
        }
        return nullptr;
    }

    FT_Face Use(Entry& entry) {
        entry.used = ++m_clock;
        return entry.face;
    }

    std::vector<Entry> m_entries;
    uint64_t           m_clock { 0 };
#ifdef WESCENE_BUILD_TESTS
    uint64_t m_files_opened { 0 };
#endif
};

// An installed face at `point_size`, from the cache. Null where the file does not
// open or the face cannot be sized.
FT_Face OpenInstalledFace(const std::string& path, const std::string& postscript_name,
                          float point_size) {
    FT_Face face = FaceCache::Get().Acquire(path, postscript_name);
    return face != nullptr && SetFaceSize(face, point_size) ? face : nullptr;
}

// What draws a glyph the layer's font does not have: Wallpaper Engine tries a fixed list of
// fonts for it, opening each only when no face it holds has the glyph, and draws the glyph
// from the first that does. Its list is Arial, Segoe UI Emoji, Arial Unicode MS, Segoe UI,
// Twemoji, Segoe UI Symbol, Microsoft YaHei and Malgun Gothic, each from the Windows Fonts
// folder (or, for Twemoji, its own assets). The faces here are the ones that stand for them.
//
//  - Colour emoji (Segoe UI Emoji, Twemoji) are colour bitmaps, which FreeType's monochrome
//    glyphs do not draw (docs/features/scene-rendering.md), so neither has a face here.
//  - Arial Unicode MS is last, not third: it ships with Microsoft Office and not with Windows,
//    so Wallpaper Engine on a stock install draws Chinese in Microsoft YaHei, and PingFang SC
//    is the face that sets Simplified Chinese punctuation as it does. The scripts no other face
//    has (Thai, Hebrew with points, ...) still draw from it.
//  - Apple Symbols stands for Segoe UI Symbol but is not asked for the CJK punctuation and
//    fullwidth forms (U+3000-303F, U+FF00-FFEF): it has some of them, set centred in the cell,
//    where Microsoft YaHei, whose stand-in is the next face, sets them as Simplified Chinese
//    does, so a string would otherwise mix the two (a centred fullwidth comma beside a
//    left-set ideographic one). That Segoe UI Symbol does not have them is inferred.
struct ChainFace {
    // A scene font key (`ResolveSceneFont`), or an installed family (`ResolveInstalledFamily`).
    std::string_view name;
    bool             scene_key;
    // The face is not asked for CJK punctuation and fullwidth forms (`IsCjkPunctuation`).
    bool             not_for_cjk_punctuation { false };
};
constexpr ChainFace kFallbackChain[] = {
    { "systemfont_arial", true },   // arial.ttf
    { "systemfont_segoe", true },   // segoeui.ttf
    { "Apple Symbols", false, true }, // seguisym.ttf
    { "PingFang SC", false },       // msyh.ttc
    { "Apple SD Gothic Neo", false }, // Malgun.ttf
    { "Arial Unicode MS", false },  // arialuni.ttf
};

// CJK Symbols and Punctuation, and Halfwidth and Fullwidth Forms.
constexpr bool IsCjkPunctuation(uint32_t codepoint) {
    return (codepoint >= 0x3000u && codepoint <= 0x303Fu) ||
           (codepoint >= 0xFF00u && codepoint <= 0xFFEFu);
}
// A layout holds its font, a face standing in for it when it cannot be opened, and the chain,
// so none of what it holds is the face the cache drops.
static_assert(std::size(kFallbackChain) + 2 <= FaceCache::kCapacity);

// The faces one layout draws with: the layer's own font, and the fallback chain's, none of
// which is opened until a glyph needs it. All are sized for the layout and only good while the
// caller holds `g_freetype_mutex`.
class FaceChain {
public:
    explicit FaceChain(const TextLayerState& state): m_point_size(ClampedPointSize(state.point_size)) {
        FaceCache::Get().Refresh();
        // Keep an authored, usable font first. A package can also contain a broken
        // font, or a previously resolved file can disappear before rasterization.
        // Recover at the decoder boundary so measurement and rasterization choose
        // the same real face in all of these cases, not placeholder rectangles.
        if (! state.resolved_font_data.empty()) {
            m_owned = CreateFreeTypeFaceFromBytes(state.resolved_font_data.bytes(), state.point_size);
            Hold(m_owned.get());
        } else if (! state.resolved_font_path.empty()) {
            m_fit = state.resolved_font_fit;
            Hold(OpenFitted(state.resolved_font_path, state.resolved_font_face, m_fit));
        }
        if (primary() != nullptr) return;
        // Wallpaper Engine draws what it cannot load in Arial.
        for (const auto& key : { state.font_key, std::string(kDefaultSceneFontKey) }) {
            const auto font = ResolveSceneFont(key);
            m_fit           = font.fit;
            Hold(OpenFitted(font.path, font.postscript_name, m_fit));
            if (primary() != nullptr) return;
        }
        m_fit = {};
    }

    FT_Face primary() const { return m_held.empty() ? nullptr : m_held.front(); }
    // How the primary face stands in for the font the layer names, if it does.
    const SystemFontFit& primaryFit() const { return m_fit; }
    FT_Face              face(uint8_t index) const { return m_held[index]; }

    // The index of the face that draws `codepoint` -- the layer's font if it has the glyph,
    // else the first face of the chain that does, opened now if it has not been -- or -1 when
    // no face has it. A face is only looked for once the faces held lack the glyph.
    int FaceFor(uint32_t codepoint) {
        for (std::size_t index = 0; index < m_held.size(); ++index) {
            if (Declines(index, codepoint)) continue;
            if (FT_Get_Char_Index(m_held[index], codepoint) != 0u) return static_cast<int>(index);
        }
        while (m_next_in_chain < std::size(kFallbackChain)) {
#ifdef WESCENE_BUILD_TESTS
            if (m_next_in_chain == 0) ++g_fallback_requests;
#endif
            const auto& entry = kFallbackChain[m_next_in_chain++];
            const auto  font  = entry.scene_key ? ResolveSceneFont(entry.name)
                                                : ResolveInstalledFamily(entry.name);
            FT_Face     other = FaceCache::Get().Acquire(font.path, font.postscript_name);
            // A face that is held already has been asked for the glyph, and is sized for the
            // layer's font: the cache hands out one face per file, so it is left alone.
            if (other == nullptr || std::ranges::find(m_held, other) != m_held.end()) continue;
            if (! SetFaceSize(other, m_point_size * font.fit.size_adjust)) continue;
            Hold(other, entry.not_for_cjk_punctuation);
            if (Declines(m_held.size() - 1, codepoint)) continue;
            if (FT_Get_Char_Index(other, codepoint) != 0u) return static_cast<int>(m_held.size() - 1);
        }
        return -1;
    }

private:
    // The installed face, sized for the layout at the point size its fit gives it.
    FT_Face OpenFitted(const std::string& path, const std::string& postscript_name,
                       const SystemFontFit& fit) const {
        return OpenInstalledFace(path, postscript_name, m_point_size * fit.size_adjust);
    }

    void Hold(FT_Face face, bool not_for_cjk_punctuation = false) {
        if (face == nullptr) return;
        m_held.push_back(face);
        m_not_for_cjk_punctuation.push_back(not_for_cjk_punctuation);
    }

    // Whether the face held at `index` is one that is not asked for `codepoint`.
    bool Declines(std::size_t index, uint32_t codepoint) const {
        return m_not_for_cjk_punctuation[index] && IsCjkPunctuation(codepoint);
    }

    float                m_point_size { 12.0f };
    // The faces held, the layer's font first.
    std::vector<FT_Face> m_held;
    // For each face held: whether it is not asked for CJK punctuation.
    std::vector<bool>    m_not_for_cjk_punctuation;
    OwnedFace            m_owned;
    SystemFontFit        m_fit;
    std::size_t          m_next_in_chain { 0 };
};

std::vector<uint32_t> DecodeUtf8(std::string_view text) {
    std::vector<uint32_t> codepoints;
    codepoints.reserve(text.size());

    std::size_t index = 0;
    while (index < text.size()) {
        const auto  first     = static_cast<uint8_t>(text[index]);
        uint32_t    codepoint = 0;
        std::size_t extra     = 0;

        if (first < 0x80u) {
            codepoint = first;
        } else if ((first & 0xE0u) == 0xC0u) {
            codepoint = first & 0x1Fu;
            extra     = 1;
        } else if ((first & 0xF0u) == 0xE0u) {
            codepoint = first & 0x0Fu;
            extra     = 2;
        } else if ((first & 0xF8u) == 0xF0u) {
            codepoint = first & 0x07u;
            extra     = 3;
        } else {
            codepoints.push_back(0xFFFDu);
            ++index;
            continue;
        }

        if (index + extra >= text.size()) {
            codepoints.push_back(0xFFFDu);
            break;
        }

        bool valid = true;
        for (std::size_t offset = 1; offset <= extra; ++offset) {
            const auto next = static_cast<uint8_t>(text[index + offset]);
            if ((next & 0xC0u) != 0x80u) {
                valid = false;
                break;
            }
            codepoint = (codepoint << 6u) | (next & 0x3Fu);
        }
        if (! valid) {
            codepoints.push_back(0xFFFDu);
            ++index;
            continue;
        }

        codepoints.push_back(codepoint);
        index += extra + 1u;
    }
    return codepoints;
}

// Where a row's pen starts, from where the widest row's does: the rows of a block are
// set within the widest one, against its left edge, centred in it or against its right
// edge. A row has its own bearing from there and nothing of the other rows'.
float RowOffset(const TextLayerState& state, float widest_row, float row_width) {
    switch (ParseTextHorizontalAlign(state.horizontal_align)) {
    case TextHorizontalAlign::Right: return widest_row - row_width;
    case TextHorizontalAlign::Center: return (widest_row - row_width) * 0.5f;
    case TextHorizontalAlign::Left: break;
    }
    return 0.0f;
}

void AppendGlyphMetrics(LineRun& line, const GlyphRun& glyph) {
    const float pen    = line.advance_width;
    line.bounds_left   = std::min(line.bounds_left, pen + glyph.left);
    line.bounds_right  = std::max(line.bounds_right, pen + glyph.right);
    line.bounds_top    = std::max(line.bounds_top, glyph.top);
    line.bounds_bottom = std::min(line.bounds_bottom, glyph.bottom);
    line.advance_width += glyph.advance;
}

void AppendMeasuredGlyph(LineRun& line, const GlyphRun& glyph) {
    AppendGlyphMetrics(line, glyph);
    line.glyphs.push_back(glyph);
}

// What the layer adds to every glyph's advance (`spacing.x`) and to every
// line pitch (`spacing.y`), in pixels at the rasterised size.
float GlyphSpacing(const TextLayerState& state) {
    return std::isfinite(state.spacing.x()) ? state.spacing.x() : 0.0f;
}

float LineSpacing(const TextLayerState& state) {
    return std::isfinite(state.spacing.y()) ? state.spacing.y() : 0.0f;
}

// The card's margin on each axis. Wallpaper Engine caps it at 512 pixels and
// does not floor it: a negative padding takes the card in around the text.
Eigen::Vector2f CardPadding(const TextLayerState& state) {
    constexpr float kMaxCardPadding = 512.0f;
    const auto lane = [=](float value) {
        return std::isfinite(value) ? std::min(value, kMaxCardPadding) : 0.0f;
    };
    return { lane(state.padding.x()), lane(state.padding.y()) };
}

// A glyph's pen advance: its unhinted advance with its kerning, cut to whole
// pixels, plus `spacing` x.
float GlyphAdvance(const GlyphRun& glyph, float spacing_x) {
    return std::floor(static_cast<float>(glyph.advance_26_6 + glyph.kerning_26_6) / 64.0f) + spacing_x;
}

std::optional<GlyphRun> MeasureGlyph(FaceChain& faces, uint32_t codepoint, float spacing_x) {
    // Only a glyph the font lacks looks for another face, and a glyph no face has is skipped.
    const int face_index = faces.FaceFor(codepoint);
    if (face_index < 0) return std::nullopt;
    FT_Face face = faces.face(static_cast<uint8_t>(face_index));
    if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) return std::nullopt;

    const FT_GlyphSlot slot    = face->glyph;
    const bool         has_ink = slot->bitmap.width > 0u && slot->bitmap.rows > 0u;
    // Wallpaper Engine takes advances from its shaper, which reads them unhinted
    // and cuts them to whole pixels, then adds the layer's `spacing`.
    const FT_UInt glyph_index = FT_Get_Char_Index(face, codepoint);
    FT_Fixed      unhinted    = 0;
    int32_t       advance_26_6 = static_cast<int32_t>(slot->advance.x);
    if (FT_Get_Advance(face, glyph_index, FT_LOAD_NO_HINTING, &unhinted) == 0) {
        advance_26_6 = static_cast<int32_t>((unhinted + 512) >> 10); // 16.16 to 26.6
    }
    GlyphRun           glyph {
                  .codepoint = codepoint,
                  .face      = static_cast<uint8_t>(face_index),
                  .has_ink   = has_ink,
                  .glyph_index  = glyph_index,
                  .advance_26_6 = advance_26_6,
    };
    glyph.advance = GlyphAdvance(glyph, spacing_x);
    if (has_ink) {
        glyph.left   = static_cast<float>(slot->bitmap_left);
        glyph.right  = glyph.left + static_cast<float>(slot->bitmap.width);
        glyph.top    = static_cast<float>(slot->bitmap_top);
        glyph.bottom = glyph.top - static_cast<float>(slot->bitmap.rows);
    }
    return glyph;
}

// The width a row may fill: `maxwidth` as authored, with no allowance for the
// card's padding, and only when the layer limits its width.
float TextWidthLimit(const TextLayerState& state) {
    if (! state.limit_width || ! std::isfinite(state.max_width) || state.max_width <= 0.0f) return 0.0f;
    return state.max_width;
}

LineRun MakeLine(std::span<const GlyphRun> glyphs) {
    LineRun line;
    for (const auto& glyph : glyphs) AppendMeasuredGlyph(line, glyph);
    return line;
}

bool BreakSpace(const GlyphRun& glyph) { return glyph.codepoint == ' ' || glyph.codepoint == '\t'; }

// `blockalign`: a row that ended at a word wrap, with another row after it,
// is stretched to exactly `width_limit` by spreading the slack over its spaces
// and tabs. The last row of a paragraph, a row ended by a line break and a row
// the row limit cut are left as they are, and so is a row with no space.
void JustifyWrappedLines(std::vector<LineRun>& lines, float width_limit) {
    for (auto& line : lines) {
        if (! line.wrapped || line.glyphs.empty()) continue;
        const auto spaces = static_cast<std::size_t>(
            std::count_if(line.glyphs.begin(), line.glyphs.end(), BreakSpace));
        if (spaces == 0u) continue;
        const float extra = (width_limit - line.LayoutWidth()) / static_cast<float>(spaces);
        for (auto& glyph : line.glyphs) {
            if (BreakSpace(glyph)) glyph.advance += extra;
        }
        line               = MakeLine(std::span<const GlyphRun>(line.glyphs));
        line.wrapped       = true;
        line.bounds_right  = line.bounds_left + width_limit;
    }
}

// The glyph as it stands before a glyph that does not kern with it: the pen
// advance without the kerning its old neighbour asked for.
GlyphRun WithoutKerning(GlyphRun glyph, float spacing_x) {
    glyph.kerning_26_6 = 0;
    glyph.advance      = GlyphAdvance(glyph, spacing_x);
    return glyph;
}

// The last row `row_limit` allows ended in text that does not fit, and the
// layer asks for an ellipsis: the row keeps as many glyphs as leave room for the
// marker inside the width limit, dropping one glyph at a time from the end, and
// the marker follows the last glyph kept that is not a space or a tab.
// `trim_first` is the row of a line break that more text followed: its trailing
// white space goes before anything is measured, where a row cut at a glyph is
// measured with it and trimmed after.
template<typename Measure>
void EllipsizeLastRow(std::vector<LineRun>& lines, Measure measure, float width_limit,
                      float spacing_x, bool trim_first) {
    auto& line = lines.back();
    if (trim_first) {
        while (! line.glyphs.empty() && BreakSpace(line.glyphs.back())) line.glyphs.pop_back();
    }
    std::vector<GlyphRun> marker;
    if (auto glyph = measure(0x2026)) marker.push_back(*glyph);
    else if (auto dot = measure('.')) marker.assign(3, *dot);

    // Prefix metrics make fitting a suffix linear even for a long row. Entry `n`
    // holds the first `n` glyphs as they are laid out among their neighbours.
    std::vector<LineRun> prefix(1);
    for (const auto& glyph : line.glyphs) {
        auto metrics = prefix.back();
        AppendGlyphMetrics(metrics, glyph);
        prefix.push_back(std::move(metrics));
    }
    size_t count = line.glyphs.size();
    while (true) {
        // The marker does not kern with the glyph before it.
        LineRun candidate = prefix[count > 0 ? count - 1 : 0];
        if (count > 0) AppendGlyphMetrics(candidate, WithoutKerning(line.glyphs[count - 1], spacing_x));
        for (const auto& glyph : marker) AppendGlyphMetrics(candidate, glyph);
        if (width_limit == 0.0f || candidate.ExtentRight() <= width_limit) break;
        if (count == 0) { marker.clear(); break; }
        --count;
    }
    std::vector<GlyphRun> kept(line.glyphs.begin(), line.glyphs.begin() + static_cast<std::ptrdiff_t>(count));
    while (! kept.empty() && BreakSpace(kept.back())) kept.pop_back();
    // A row that already ends in the marker is not given another.
    if (! kept.empty() && kept.back().codepoint == 0x2026) marker.clear();
    if (! kept.empty() && ! marker.empty()) kept.back() = WithoutKerning(kept.back(), spacing_x);
    for (const auto& glyph : marker) kept.push_back(glyph);
    line = MakeLine(std::span<const GlyphRun>(kept));
}

// `measure(codepoint)` gives a glyph; `kerning(left, right)` the 26.6 kerning of two
// neighbouring glyphs of the same face, which narrows or widens the left one.
//
// Text is cut into paragraphs at line breaks, and a break with nothing after it
// ends the text without a row of its own. A row wraps before a glyph whose ink
// would end past the width limit. Where the row limit allows another row the
// wrap is at the last space or tab before that glyph (the row keeps everything
// up to it, the next row starts at the glyph with the white space before it
// dropped), or at the glyph itself when the row holds none. On the last row the
// limit allows, nothing wraps: the row keeps every glyph before the glyph that
// did not fit, and the layer's ellipsis, if it asks for one, replaces the end.
template<typename Measure, typename Kerning>
std::vector<LineRun> BuildLineRuns(const TextLayerState& state, Measure measure, Kerning kerning) {
    std::vector<LineRun> lines;
    lines.emplace_back();
    const float width_limit = TextWidthLimit(state);
    const float spacing_x   = GlyphSpacing(state);
    const size_t row_limit = state.limit_rows && state.max_rows != 0 ? state.max_rows : SIZE_MAX;
    bool omitted        = false;
    bool omitted_by_break = false;
    const auto codepoints = DecodeUtf8(state.text);
    for (std::size_t at = 0; at < codepoints.size(); ++at) {
        const uint32_t codepoint = codepoints[at];
        if (codepoint == '\n') {
            // Nothing after the break: the text ends with the row before it.
            if (at + 1 == codepoints.size()) break;
            if (lines.size() == row_limit) { omitted = omitted_by_break = true; break; }
            lines.emplace_back();
            continue;
        }
        if (codepoint == '\r') continue;
        auto glyph = measure(codepoint);
        if (! glyph) continue;
        if (! lines.back().glyphs.empty()) {
            auto&         previous = lines.back().glyphs.back();
            const int32_t kern     = kerning(previous, *glyph);
            if (kern != previous.kerning_26_6) {
                previous.kerning_26_6 = kern;
                const float advance   = GlyphAdvance(previous, spacing_x);
                lines.back().advance_width += advance - previous.advance;
                previous.advance = advance;
            }
        }
        // A row wraps before a glyph whose ink would end past the limit, once it
        // holds a glyph already; a space or tab never starts a wrap.
        const bool overflows = width_limit > 0.0f && ! lines.back().glyphs.empty() &&
                               ! BreakSpace(*glyph) &&
                               lines.back().advance_width + glyph->right > width_limit;
        AppendMeasuredGlyph(lines.back(), *glyph);
        if (! overflows) continue;

        auto& current = lines.back();
        if (lines.size() == row_limit) {
            // The last row: cut before the glyph that did not fit, no search for
            // a space.
            current.glyphs.pop_back();
            current = MakeLine(current.glyphs);
            omitted = true;
            break;
        }
        // Break at the last space or tab before the glyph, which stays out of the
        // next row along with the white space that follows it; a row with none is
        // cut at the glyph. Spaces before the break stay in the row.
        size_t split = current.glyphs.size() - 1;
        for (size_t index = split; index > 0; --index) {
            if (BreakSpace(current.glyphs[index - 1])) { split = index - 1; break; }
        }
        std::vector<GlyphRun> carry(current.glyphs.begin() + static_cast<std::ptrdiff_t>(split),
                                    current.glyphs.end());
        current.glyphs.resize(split);
        current         = MakeLine(current.glyphs);
        current.wrapped = true;
        while (! carry.empty() && BreakSpace(carry.front())) carry.erase(carry.begin());
        lines.push_back(MakeLine(carry));
    }
    if (omitted && state.use_ellipsis) {
        EllipsizeLastRow(lines, measure, width_limit, spacing_x, omitted_by_break);
    }
    if (state.block_align && width_limit > 0.0f) JustifyWrappedLines(lines, width_limit);
    return lines;
}

std::vector<LineRun> BuildFreeTypeLines(const TextLayerState& state, FaceChain& faces) {
    const float spacing_x = GlyphSpacing(state);
    return BuildLineRuns(
        state,
        [&](uint32_t codepoint) { return MeasureGlyph(faces, codepoint, spacing_x); },
        [&](const GlyphRun& left, const GlyphRun& right) -> int32_t {
            // Neighbours of one face only, as a shaper kerns a run of one font.
            FT_Face used = faces.face(left.face);
            if (left.face != right.face || used == nullptr || ! FT_HAS_KERNING(used)) return 0;
            FT_Vector kern {};
            if (FT_Get_Kerning(used, left.glyph_index, right.glyph_index, FT_KERNING_UNFITTED, &kern) != 0) {
                return 0;
            }
            return static_cast<int32_t>(kern.x);
        });
}

// The box of the rows, as Wallpaper Engine lays it out: from the first row's
// ascender line, or the tallest ink above it, down to one line pitch below that
// line for every row, or the lowest ink below it. The pitch is the face's line
// height plus the layer's `spacing.y`.
TextBlock MeasureTextBlock(const std::vector<LineRun>& lines, const FaceLayoutMetrics& metrics) {
    const auto rows  = static_cast<float>(lines.size());
    const float pitch = metrics.pitch;
    TextBlock  block {
         .top       = metrics.ascender,
         .bottom    = metrics.ascender - rows * pitch,
         .ascender  = metrics.ascender,
         .descender = metrics.descender,
         .pitch     = pitch,
         .rows      = static_cast<uint32_t>(lines.size()),
    };
    for (std::size_t index = 0; index < lines.size(); ++index) {
        const auto& line = lines[index];
        const float drop = static_cast<float>(index) * pitch;
        block.min_x      = std::min(block.min_x, line.bounds_left);
        block.max_x      = std::max(block.max_x, line.bounds_right);
        block.widest_row = std::max(block.widest_row, line.LayoutWidth());
        block.top        = std::max(block.top, line.bounds_top - drop);
        block.bottom     = std::min(block.bottom, line.bounds_bottom - drop);
    }
    return block;
}

// The size metrics of a scalable face of `units` at the layer's point size, as FreeType
// makes them (`FT_Request_Metrics`): the requested height at 300 dpi gives the scale from
// font units, and the ascender is rounded up, the descender down and the height to the
// nearest whole pixel.
FaceLayoutMetrics LineMetricsOf(const TextLayerState& state, const FontLineMetrics& units) {
    const FT_Pos   scaled = (static_cast<FT_Pos>(FreeTypeCharHeight(state.point_size)) *
                               static_cast<FT_Pos>(kTextDpi) + 36) / static_cast<FT_Pos>(kPointsPerInch);
    const FT_Fixed scale  = FT_DivFix(scaled, static_cast<FT_Long>(units.units_per_em));
    const auto     px_up  = [&](FT_Long font_units) {
        return static_cast<float>((FT_MulFix(font_units, scale) + 63) >> 6);
    };
    const auto px_near = [&](FT_Long font_units) {
        return static_cast<float>((FT_MulFix(font_units, scale) + 32) >> 6);
    };
    return {
        .ascender  = px_up(units.ascender),
        .descender = px_up(units.descender),
        .pitch     = px_near(static_cast<FT_Long>(units.ascender) + units.descender + units.line_gap),
    };
}

// Wallpaper Engine reads the size metrics FreeType has rounded (the ascender up, the
// descender down, the height to the nearest) and cuts them to whole pixels. A face that
// stands in for a font Wallpaper Engine has and this machine lacks is measured in that
// font's line metrics instead, so that the card and the place the text lies in it come out
// as they do there.
FaceLayoutMetrics FaceMetrics(const TextLayerState& state, const FaceChain& faces) {
    FaceLayoutMetrics metrics;
    const auto&       fit = faces.primaryFit();
    if (fit.line_metrics.has_value() && fit.line_metrics->units_per_em > 0) {
        metrics = LineMetricsOf(state, *fit.line_metrics);
    } else {
        const auto size = faces.primary()->size->metrics;
        metrics         = {
            .ascender  = static_cast<float>(size.ascender >> 6),
            .descender = static_cast<float>(-(size.descender >> 6)),
            .pitch     = static_cast<float>(size.height >> 6),
        };
    }
    metrics.pitch += LineSpacing(state);
    return metrics;
}

// Without a usable face the layout runs on boxes: 0.6 em advances, 0.9 em glyphs
// and a 1.2 em line.
constexpr float kFallbackAdvance = 0.6f;
constexpr float kFallbackInk     = 0.45f;
constexpr float kFallbackAscent  = 0.9f;
constexpr float kFallbackLine    = 1.2f;

std::vector<LineRun> BuildFallbackLines(const TextLayerState& state) {
    const float pixels    = PointSizeToPixels(state.point_size);
    const float spacing_x = GlyphSpacing(state);
    return BuildLineRuns(
        state,
        [=](uint32_t codepoint) -> std::optional<GlyphRun> {
            const float advance = std::max(1.0f, pixels * kFallbackAdvance);
            const float ink     = std::max(1.0f, pixels * kFallbackInk);
            const bool  has_ink = codepoint != ' ' && codepoint != '\t';
            GlyphRun    glyph {
                           .codepoint = codepoint,
                           .advance   = (codepoint == '\t' ? advance * 4.0f : advance) + spacing_x,
                           .has_ink   = has_ink,
            };
            if (has_ink) {
                glyph.right = ink;
                glyph.top   = pixels * kFallbackAscent;
            }
            return glyph;
        },
        [](const GlyphRun&, const GlyphRun&) -> int32_t { return 0; });
}

FaceLayoutMetrics FallbackMetrics(const TextLayerState& state) {
    const float pixels = PointSizeToPixels(state.point_size);
    return { .ascender  = pixels * kFallbackAscent,
             .descender = pixels * (kFallbackLine - kFallbackAscent),
             .pitch     = pixels * kFallbackLine + LineSpacing(state) };
}

// How far down from the first row's baseline the vertical alignment puts the layer's
// origin: the ascender line for `top`, the middle between that line and the last row's
// baseline for `center`, and for `bottom` the last row's descender line.
float ReferenceLine(TextVerticalAlign vertical, const TextBlock& block) {
    const float below = static_cast<float>(block.rows > 0 ? block.rows - 1u : 0u) * block.pitch;
    switch (vertical) {
    case TextVerticalAlign::Top: return block.ascender;
    case TextVerticalAlign::Bottom: return -block.descender - below;
    case TextVerticalAlign::Center: break;
    }
    return (block.ascender - below) * 0.5f;
}

// Where the card's centre lies from the layer's origin. Across, the origin is on the
// block's left edge, its middle or its right edge, so the card's centre is half the
// block's width to the right of it, on it, or half to the left; down, the origin is on the
// reference line, and the card's centre is where the block's is from it. The padding adds
// nothing to either: it grows the card outward from the block.
Eigen::Vector2f CardCentre(const TextLayerState& state, const TextBlock& block) {
    float across = 0.0f;
    switch (ParseTextHorizontalAlign(state.horizontal_align)) {
    case TextHorizontalAlign::Left: across = block.Width() * 0.5f; break;
    case TextHorizontalAlign::Right: across = -block.Width() * 0.5f; break;
    case TextHorizontalAlign::Center: break;
    }
    const float down = (block.top + block.bottom) * 0.5f -
                       ReferenceLine(ParseTextVerticalAlign(state.vertical_align), block);
    return { across, down };
}

// The layout of a block: the block, the face it was set in, and the card that holds
// it, which is the block plus the padding on both sides and 2 by 2 plus the padding
// when there is no text to lay out (Wallpaper Engine has no layout then, and sizes
// the card from 2 by 2).
TextLayerLayout LayoutOfBlock(const TextLayerState& state, const TextBlock& block) {
    const auto padding = CardPadding(state);
    TextLayerLayout layout {
        .ascender  = block.ascender,
        .descender = block.descender,
        .pitch     = block.pitch,
        .padding   = padding,
    };
    if (state.text.empty()) {
        layout.card = { std::max(1.0f, 2.0f + padding.x() * 2.0f),
                        std::max(1.0f, 2.0f + padding.y() * 2.0f) };
        return layout;
    }
    layout.min_x = block.min_x;
    layout.max_x = block.max_x;
    layout.top    = block.top;
    layout.bottom = block.bottom;
    layout.rows   = block.rows;
    layout.card   = { std::max(1.0f, block.Width() + padding.x() * 2.0f),
                      std::max(1.0f, block.Height() + padding.y() * 2.0f) };
    layout.centre = CardCentre(state, block);
    return layout;
}

// ---------------------------------------------------------------------------
// Outline, blur and drop shadow.
//
// Wallpaper Engine draws a glyph from a signed-distance atlas made at 32 pixels
// to the em, padded by 12 pixels and scaled up by `ppem / 32` on the way to
// the screen. The scene file's sizes are scaled into that atlas by
// `k = 32 / pointsize * 0.24`, capped there, and `0.24 * ppem / pointsize` is
// one: they are pixels of the finished text. The caps stay in atlas units, so
// they grow with the text. Everything below is in raster pixels.
// ---------------------------------------------------------------------------

constexpr float kAtlasEm        = 32.0f;
constexpr float kAtlasRange     = 12.0f; // atlas pixels of distance the field holds each way
constexpr float kAtlasUnitScale = 0.24f;
constexpr float kOutlineCap     = 5.1f;
constexpr float kBlurCap        = 6.0f;
constexpr float kShadowCap      = 6.0f;
constexpr float kShadowOffsetCap = 6.0f;

struct StyleMetrics {
    bool            outline { false };
    bool            blur { false };
    bool            shadow { false };
    // Outline width, and how far each edge softens either way.
    float           outline_px { 0.0f };
    float           edge_half_px { 0.5f };
    float           shadow_half_px { 0.5f };
    Eigen::Vector2f shadow_offset_px { Eigen::Vector2f::Zero() };
    float           shadow_opacity { 1.0f };
    // How far the field reaches from a glyph; farther is outside every edge.
    float           range_px { 0.0f };
    // Edges are smoothed over a width, not a pixel, when blur or a shadow is on.
    bool            smooth { false };
};

float FiniteOr(float value, float fallback) { return std::isfinite(value) ? value : fallback; }

StyleMetrics ResolveStyleMetrics(const TextStyle& style, float point_size) {
    StyleMetrics metrics;
    if (! TextStyleActive(style)) return metrics;

    const float points = ClampedPointSize(point_size);
    const float k      = (kAtlasEm / points) * kAtlasUnitScale;
    const float scale  = PointSizeToPixels(point_size) / kAtlasEm; // pixels per atlas pixel

    // The outline asks for at least one pixel; blur and shadow sizes for a hair.
    const float outline = style.outline ? std::max(FiniteOr(style.outline_thickness, 1.0f), 1.0f) : 0.0f;
    const float blur    = style.blur ? std::max(FiniteOr(style.blur_size, 0.01f), 0.01f) : 0.0f;
    const float shadow  = style.drop_shadow ? std::max(FiniteOr(style.shadow_size, 0.01f), 0.01f) : 0.0f;
    const Eigen::Vector2f offset = style.drop_shadow
        ? Eigen::Vector2f(FiniteOr(style.shadow_offset.x(), 0.0f), FiniteOr(style.shadow_offset.y(), 0.0f))
        : Eigen::Vector2f::Zero();

    float outline_atlas = std::min(outline * k, kOutlineCap);
    const float blur_atlas   = std::min(blur * k, kBlurCap);
    const float shadow_atlas = std::min(shadow * k, kShadowCap);
    const Eigen::Vector2f offset_atlas(std::min(offset.x() * k, kShadowOffsetCap),
                                       std::min(offset.y() * k, kShadowOffsetCap));
    if (outline_atlas + blur_atlas > kOutlineCap) {
        outline_atlas = std::max(kOutlineCap - blur_atlas, 0.0f);
    }

    metrics.outline          = style.outline && outline >= 1.0f;
    metrics.blur             = blur > 0.0f;
    metrics.shadow           = style.drop_shadow && (shadow > 0.0f || offset.squaredNorm() > 1.1920929e-07f);
    metrics.smooth           = metrics.blur || metrics.shadow;
    metrics.outline_px       = metrics.outline ? outline_atlas * scale : 0.0f;
    // Blur softens in atlas pixels; a shadow alone softens the glyph over half a
    // pixel of the screen.
    metrics.edge_half_px     = metrics.blur ? std::max(blur_atlas, 0.5f) * scale : 0.5f;
    metrics.shadow_half_px   = std::max(shadow_atlas, 0.5f) * scale;
    metrics.shadow_offset_px = offset_atlas * scale;
    metrics.shadow_opacity   = FiniteOr(style.shadow_opacity, 1.0f);
    metrics.range_px         = kAtlasRange * scale;
    return metrics;
}

float StyleReach(const StyleMetrics& metrics) {
    float reach = 0.0f;
    if (metrics.outline) reach = metrics.outline_px;
    reach += metrics.smooth || metrics.outline ? metrics.edge_half_px : 0.5f;
    if (metrics.shadow) {
        const float shadow_reach = std::max(std::abs(metrics.shadow_offset_px.x()),
                                            std::abs(metrics.shadow_offset_px.y())) +
                                   metrics.outline_px + metrics.shadow_half_px;
        reach = std::max(reach, shadow_reach);
    }
    return std::min(reach, metrics.range_px);
}

float Smoothstep(float low, float high, float value) {
    const float t = std::clamp((value - low) / (high - low), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// Felzenszwalb and Huttenlocher's squared distance transform along one line: the
// lower envelope of the parabolas rooted at each cell, `grid` read and rewritten
// in place.
void SquaredDistanceLine(float* grid, std::size_t offset, std::size_t stride, std::size_t length,
                         std::vector<float>& f, std::vector<std::size_t>& v, std::vector<float>& z) {
    constexpr float kInfinity = 1.0e20f;
    for (std::size_t q = 0; q < length; ++q) f[q] = grid[offset + q * stride];
    std::size_t k = 0;
    v[0]          = 0;
    z[0]          = -kInfinity;
    z[1]          = kInfinity;
    const auto intersection = [&](std::size_t q, std::size_t r) {
        return ((f[q] + static_cast<float>(q * q)) - (f[r] + static_cast<float>(r * r))) /
               (2.0f * static_cast<float>(q) - 2.0f * static_cast<float>(r));
    };
    for (std::size_t q = 1; q < length; ++q) {
        float s = intersection(q, v[k]);
        while (s <= z[k] && k > 0) {
            --k;
            s = intersection(q, v[k]);
        }
        ++k;
        v[k]     = q;
        z[k]     = s;
        z[k + 1] = kInfinity;
    }
    k = 0;
    for (std::size_t q = 0; q < length; ++q) {
        while (z[k + 1] < static_cast<float>(q)) ++k;
        const float delta = static_cast<float>(q) - static_cast<float>(v[k]);
        grid[offset + q * stride] = f[v[k]] + delta * delta;
    }
}

void SquaredDistanceTransform(std::vector<float>& grid, std::size_t width, std::size_t height) {
    const std::size_t longest = std::max(width, height);
    std::vector<float>       f(longest);
    std::vector<std::size_t> v(longest);
    std::vector<float>       z(longest + 1);
    for (std::size_t x = 0; x < width; ++x) SquaredDistanceLine(grid.data(), x, width, height, f, v, z);
    for (std::size_t y = 0; y < height; ++y) SquaredDistanceLine(grid.data(), y * width, 1, width, f, v, z);
}

// The signed distance, in pixels and positive inside, from each pixel's centre to
// the edge of the glyphs `coverage` holds, with the edge where coverage is half.
// A pixel only partly covered places the edge inside itself, so a straight edge
// comes out to the sub-pixel.
std::vector<float> SignedDistanceField(const std::vector<uint8_t>& coverage, std::size_t width,
                                       std::size_t height, float range) {
    constexpr float kInfinity = 1.0e20f;
    std::vector<float> outside(width * height), inside(width * height);
    for (std::size_t index = 0; index < coverage.size(); ++index) {
        const float a = static_cast<float>(coverage[index]) / 255.0f;
        if (a >= 1.0f) {
            outside[index] = 0.0f;
            inside[index]  = kInfinity;
        } else if (a <= 0.0f) {
            outside[index] = kInfinity;
            inside[index]  = 0.0f;
        } else {
            const float d  = 0.5f - a;
            outside[index] = d > 0.0f ? d * d : 0.0f;
            inside[index]  = d < 0.0f ? d * d : 0.0f;
        }
    }
    SquaredDistanceTransform(outside, width, height);
    SquaredDistanceTransform(inside, width, height);
    std::vector<float> field(width * height);
    for (std::size_t index = 0; index < field.size(); ++index) {
        field[index] = std::clamp(std::sqrt(inside[index]) - std::sqrt(outside[index]), -range, range);
    }
    return field;
}

float SampleField(const std::vector<float>& field, std::size_t width, std::size_t height, float x,
                  float y, float outside_value) {
    // Pixel centres sit at integers here; beyond the grid is far outside.
    const float fx = std::floor(x), fy = std::floor(y);
    const float tx = x - fx, ty = y - fy;
    const auto at = [&](float px, float py) {
        const long ix = static_cast<long>(px), iy = static_cast<long>(py);
        if (ix < 0 || iy < 0 || ix >= static_cast<long>(width) || iy >= static_cast<long>(height)) {
            return outside_value;
        }
        return field[static_cast<std::size_t>(iy) * width + static_cast<std::size_t>(ix)];
    };
    const float top    = at(fx, fy) * (1.0f - tx) + at(fx + 1.0f, fy) * tx;
    const float bottom = at(fx, fy + 1.0f) * (1.0f - tx) + at(fx + 1.0f, fy + 1.0f) * tx;
    return top * (1.0f - ty) + bottom * ty;
}

// Turns the coverage of the glyphs into the three masks the font shader mixes:
// red the glyph, green the glyph with its outline and blur, blue the shadow,
// already with its opacity. Alpha is whatever is drawn at all.
void ComposeStyledText(const StyleMetrics& style, const std::vector<uint8_t>& coverage,
                       uint32_t width, uint32_t height, std::vector<uint8_t>& rgba) {
    const std::size_t w = width, h = height;
    // The field is only needed where something could be drawn.
    std::size_t min_x = w, max_x = 0, min_y = h, max_y = 0;
    for (std::size_t y = 0; y < h; ++y) {
        for (std::size_t x = 0; x < w; ++x) {
            if (coverage[y * w + x] == 0u) continue;
            min_x = std::min(min_x, x);
            max_x = std::max(max_x, x);
            min_y = std::min(min_y, y);
            max_y = std::max(max_y, y);
        }
    }
    if (min_x > max_x) return;

    const auto  reach = static_cast<std::size_t>(std::ceil(StyleReach(style))) + 2u;
    const auto  shadow_x = static_cast<std::size_t>(std::ceil(std::abs(style.shadow_offset_px.x())));
    const auto  shadow_y = static_cast<std::size_t>(std::ceil(std::abs(style.shadow_offset_px.y())));
    const std::size_t pad_x = reach + (style.shadow ? shadow_x : 0u);
    const std::size_t pad_y = reach + (style.shadow ? shadow_y : 0u);
    const std::size_t x0 = min_x > pad_x ? min_x - pad_x : 0u;
    const std::size_t y0 = min_y > pad_y ? min_y - pad_y : 0u;
    const std::size_t x1 = std::min(w, max_x + pad_x + 1u);
    const std::size_t y1 = std::min(h, max_y + pad_y + 1u);
    const std::size_t rw = x1 - x0, rh = y1 - y0;

    std::vector<uint8_t> region(rw * rh);
    for (std::size_t y = 0; y < rh; ++y) {
        std::copy_n(coverage.begin() + static_cast<std::ptrdiff_t>((y0 + y) * w + x0), rw,
                    region.begin() + static_cast<std::ptrdiff_t>(y * rw));
    }
    const auto field = SignedDistanceField(region, rw, rh, style.range_px);

    const auto edge = [&](float distance, float extra) {
        if (style.smooth) {
            return Smoothstep(-style.edge_half_px, style.edge_half_px, distance + extra);
        }
        return std::clamp(distance + 0.5f + extra, 0.0f, 1.0f);
    };
    const auto byte = [](float value) {
        return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
    };
    for (std::size_t y = 0; y < rh; ++y) {
        for (std::size_t x = 0; x < rw; ++x) {
            const float distance = field[y * rw + x];
            const float fill     = edge(distance, 0.0f);
            const float outer    = style.outline ? edge(distance, style.outline_px) : fill;
            float       shadow   = 0.0f;
            if (style.shadow) {
                const float sampled =
                    SampleField(field, rw, rh, static_cast<float>(x) - style.shadow_offset_px.x(),
                                static_cast<float>(y) - style.shadow_offset_px.y(), -style.range_px);
                const float extra = style.outline ? style.outline_px : 0.0f;
                shadow = std::clamp(
                    style.shadow_opacity *
                        Smoothstep(-style.shadow_half_px, style.shadow_half_px, sampled + extra),
                    0.0f, 1.0f);
            }
            const std::size_t offset = ((y0 + y) * w + (x0 + x)) * 4u;
            rgba[offset + 0u] = byte(fill);
            rgba[offset + 1u] = byte(outer);
            rgba[offset + 2u] = byte(shadow);
            rgba[offset + 3u] = byte(std::max(outer, shadow));
        }
    }
}

TextLayerLayout MeasureFallbackText(const TextLayerState& state) {
    const auto lines = BuildFallbackLines(state);
    return LayoutOfBlock(state, MeasureTextBlock(lines, FallbackMetrics(state)));
}

// Paints the fallback's boxes, calling `plot(x, y, coverage)` for each pixel.
template<typename Plot>
void RasterizeFallbackText(const TextLayerState& state, uint32_t width, uint32_t height,
                           Plot&& plot) {
    const auto lines    = BuildFallbackLines(state);
    const auto metrics  = FallbackMetrics(state);
    const auto block    = MeasureTextBlock(lines, metrics);
    const Eigen::Vector2f padding =
        CardPadding(state) + Eigen::Vector2f::Constant(TextStyleMargin(state));
    const float glyph_height = std::max(1.0f, metrics.ascender);
    // The block sits under the padding, the first row's baseline its tallest ink down; a
    // row's pen starts where the rows are aligned in the widest, from the pen origin of
    // the block (the leftmost ink or the pen, whichever lies further left).
    float baseline = padding.y() + block.top;
    for (const auto& line : lines) {
        float pen = padding.x() - block.min_x + RowOffset(state, block.widest_row, line.LayoutWidth());
        for (const auto& glyph : line.glyphs) {
            if (glyph.has_ink) {
                const float top = baseline - glyph_height;
                for (int y = std::max(0, int(std::floor(top))); y < std::min(int(height), int(std::ceil(baseline))); ++y) {
                    for (int x = std::max(0, int(std::floor(pen))); x < std::min(int(width), int(std::ceil(pen + glyph.right))); ++x) {
                        plot(x, y, uint8_t { 255 });
                    }
                }
            }
            pen += glyph.advance;
        }
        baseline += block.pitch;
        if (block.pitch > 0.0f && baseline - glyph_height >= static_cast<float>(height)) break;
    }
}

// Paints the text with FreeType, calling `plot(x, y, coverage)` for each pixel a
// glyph covers; the caller decides what a pixel of coverage becomes. False when
// there is no face to paint with.
template<typename Plot>
bool RasterizeFreeTypeText(const TextLayerState& state, uint32_t width, uint32_t height,
                           Plot&& plot) {
    if (state.text.empty()) return true;

    FaceChain faces(state);
    if (faces.primary() == nullptr) return false;

    const auto lines = BuildFreeTypeLines(state, faces);

    const auto metrics = FaceMetrics(state, faces);
    const auto block   = MeasureTextBlock(lines, metrics);
    // The style's margin is clear room around the card the text is laid out in.
    const Eigen::Vector2f padding =
        CardPadding(state) + Eigen::Vector2f::Constant(TextStyleMargin(state));

    // The block sits under the padding, the first row's baseline its tallest ink down; a
    // row's pen starts where the rows are aligned in the widest, from the pen origin of
    // the block (the leftmost ink or the pen, whichever lies further left).
    float baseline_y = padding.y() + block.top;
    for (const auto& line : lines) {
        float pen_x = padding.x() - block.min_x + RowOffset(state, block.widest_row, line.LayoutWidth());
        for (const auto& glyph : line.glyphs) {
            FT_Face glyph_face = faces.face(glyph.face);
            if (FT_Load_Char(glyph_face, glyph.codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) !=
                0) {
                pen_x += glyph.advance;
                continue;
            }

            const FT_GlyphSlot slot   = glyph_face->glyph;
            const FT_Bitmap&   bitmap = slot->bitmap;
            const int          left   = static_cast<int>(std::lround(pen_x)) + slot->bitmap_left;
            const int          top   = static_cast<int>(std::lround(baseline_y)) - slot->bitmap_top;
            const auto         pitch = static_cast<std::size_t>(std::abs(bitmap.pitch));

            for (uint32_t row = 0; row < bitmap.rows; ++row) {
                const int dest_y = top + static_cast<int>(row);
                if (dest_y < 0 || dest_y >= static_cast<int>(height)) continue;
                const uint32_t source_row = bitmap.pitch >= 0 ? row : bitmap.rows - 1u - row;

                for (uint32_t column = 0; column < bitmap.width; ++column) {
                    const int dest_x = left + static_cast<int>(column);
                    if (dest_x < 0 || dest_x >= static_cast<int>(width)) continue;

                    const auto coverage =
                        bitmap.buffer[static_cast<std::size_t>(source_row) * pitch + column];
                    if (coverage == 0u) continue;
                    plot(dest_x, dest_y, coverage);
                }
            }

            pen_x += glyph.advance;
            if (pen_x >= static_cast<float>(width)) break;
        }
        baseline_y += block.pitch;
        if (block.pitch > 0.0f && baseline_y >= static_cast<float>(height) + block.pitch) break;
    }

    return true;
}

std::optional<TextLayerLayout> MeasureFreeTypeText(const TextLayerState& state) {
    FaceChain faces(state);
    if (faces.primary() == nullptr) return std::nullopt;

    const auto lines   = BuildFreeTypeLines(state, faces);
    const auto metrics = FaceMetrics(state, faces);
    return LayoutOfBlock(state, MeasureTextBlock(lines, metrics));
}

std::size_t LineCount(std::string_view text) {
    if (text.empty()) return 1;
    return static_cast<std::size_t>(std::count(text.begin(), text.end(), '\n')) + 1u;
}

std::size_t LongestLineCodepoints(std::string_view text) {
    std::size_t longest = 0;
    std::size_t current = 0;
    for (unsigned char ch : text) {
        if (ch == '\n') {
            longest = std::max(longest, current);
            current = 0;
            continue;
        }
        if ((ch & 0xC0u) != 0x80u) ++current;
    }
    return std::max(longest, current);
}

} // namespace

// The raster holds the card with the room its style reaches into on every side.
Eigen::Vector2f TextLayerRasterSizeForLayout(const TextLayerState& state,
                                             const TextLayerLayout& layout) {
    return layout.card + Eigen::Vector2f::Constant(2.0f * TextStyleMargin(state));
}

Eigen::Vector2f TextCardInsetInRaster(const TextLayerState& state, const TextLayerLayout& layout) {
    const auto raster = TextLayerRasterSizeForLayout(state, layout);
    const float margin = TextStyleMargin(state);
    return { raster.x() > 0.0f ? margin / raster.x() : 0.0f, raster.y() > 0.0f ? margin / raster.y() : 0.0f };
}

bool TextStyleActive(const TextStyle& style) { return style.outline || style.blur || style.drop_shadow; }

TextHorizontalAlign ParseTextHorizontalAlign(std::string_view word) {
    if (word == "center") return TextHorizontalAlign::Center;
    if (word == "right") return TextHorizontalAlign::Right;
    return TextHorizontalAlign::Left;
}

TextVerticalAlign ParseTextVerticalAlign(std::string_view word) {
    if (word == "top") return TextVerticalAlign::Top;
    if (word == "bottom") return TextVerticalAlign::Bottom;
    return TextVerticalAlign::Center;
}

std::string_view TextHorizontalAlignWord(TextHorizontalAlign align) {
    switch (align) {
    case TextHorizontalAlign::Center: return "center";
    case TextHorizontalAlign::Right: return "right";
    case TextHorizontalAlign::Left: break;
    }
    return "left";
}

std::string_view TextVerticalAlignWord(TextVerticalAlign align) {
    switch (align) {
    case TextVerticalAlign::Top: return "top";
    case TextVerticalAlign::Bottom: return "bottom";
    case TextVerticalAlign::Center: break;
    }
    return "center";
}

float TextStyleMargin(const TextLayerState& state) {
    if (! TextStyleActive(state.style)) return 0.0f;
    // One pixel more than the style reaches, for the edge's own antialiasing.
    return std::ceil(StyleReach(ResolveStyleMetrics(state.style, state.point_size))) + 1.0f;
}

Eigen::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding) {
    if (! std::isfinite(padding) || padding < 0.0f) padding = 0.0f;

    const float pixel_size  = PointSizeToPixels(point_size);
    const float glyph_width = std::max(1.0f, pixel_size * 0.6f);
    const float line_height = std::max(1.0f, pixel_size * 1.2f);
    const auto  columns     = std::max<std::size_t>(1u, LongestLineCodepoints(text));
    const auto  lines       = std::max<std::size_t>(1u, LineCount(text));

    return Eigen::Vector2f(static_cast<float>(columns) * glyph_width + padding * 2.0f,
                           static_cast<float>(lines) * line_height + padding * 2.0f);
}

TextLayerLayout MeasureTextLayerLayout(const TextLayerState& state) {
#ifdef WESCENE_BUILD_TESTS
    ++g_measurement_count;
#endif
    std::optional<TextLayerLayout> measured;
    {
        const std::lock_guard lock { g_freetype_mutex };
        measured = MeasureFreeTypeText(state);
    }
    if (measured.has_value()) {
        return *measured;
    }
    return MeasureFallbackText(state);
}

Eigen::Vector2f MeasureTextLayerSize(const TextLayerState& state) {
    return MeasureTextLayerLayout(state).card;
}

Eigen::Vector2f TextLayerRasterSize(const TextLayerState& state) {
    return TextLayerRasterSizeForLayout(state, MeasureTextLayerLayout(state));
}

TextScreenAnchor ParseTextScreenAnchor(std::string_view name) {
    constexpr std::pair<std::string_view, TextScreenAnchor> kAnchors[] = {
        { "center", TextScreenAnchor::Center },
        { "top", TextScreenAnchor::Top },
        { "topright", TextScreenAnchor::TopRight },
        { "right", TextScreenAnchor::Right },
        { "bottomright", TextScreenAnchor::BottomRight },
        { "bottom", TextScreenAnchor::Bottom },
        { "bottomleft", TextScreenAnchor::BottomLeft },
        { "left", TextScreenAnchor::Left },
        { "topleft", TextScreenAnchor::TopLeft },
    };
    for (const auto& [text, anchor] : kAnchors) {
        if (name == text) return anchor;
    }
    return TextScreenAnchor::None;
}

Eigen::Vector2f TextScreenAnchorOffset(TextScreenAnchor anchor, const PresentedMargins& margins) {
    const float centre_x = (margins.left - margins.right) * 0.5f;
    const float centre_y = (margins.bottom - margins.top) * 0.5f;
    switch (anchor) {
    case TextScreenAnchor::Center: return { centre_x, centre_y };
    case TextScreenAnchor::Top: return { centre_x, -margins.top };
    case TextScreenAnchor::Bottom: return { centre_x, margins.bottom };
    case TextScreenAnchor::Left: return { margins.left, centre_y };
    case TextScreenAnchor::Right: return { -margins.right, centre_y };
    case TextScreenAnchor::TopLeft: return { margins.left, -margins.top };
    case TextScreenAnchor::TopRight: return { -margins.right, -margins.top };
    case TextScreenAnchor::BottomLeft: return { margins.left, margins.bottom };
    case TextScreenAnchor::BottomRight: return { -margins.right, margins.bottom };
    case TextScreenAnchor::None: break;
    }
    return Eigen::Vector2f::Zero();
}

TextLayerRenderBounds TextLayerRenderBoundsForLayout(const TextLayerState& state,
                                                     const TextLayerLayout& layout) {
    // The card is centred on the layout's centre; the room the style needs lies outside
    // it on every side.
    const float margin = TextStyleMargin(state);
    const Eigen::Vector2f half = layout.card * 0.5f + Eigen::Vector2f::Constant(margin);
    return {
        .left   = layout.centre.x() - half.x(),
        .right  = layout.centre.x() + half.x(),
        .bottom = layout.centre.y() - half.y(),
        .top    = layout.centre.y() + half.y(),
    };
}

TextLayerRenderFrame TextLayerRenderFrameForLayout(const TextLayerState& state,
                                                   const TextLayerLayout& layout) {
    const auto bounds = TextLayerRenderBoundsForLayout(state, layout);
    return {
        .bounds = bounds,
        .size   = Eigen::Vector2f(bounds.right - bounds.left, bounds.top - bounds.bottom),
        .center = Eigen::Vector2f((bounds.left + bounds.right) * 0.5f,
                                  (bounds.bottom + bounds.top) * 0.5f),
    };
}

std::array<int32_t, 2> TextCardTexelExtent(Eigen::Vector2f card) {
    return {
        std::max(4, static_cast<int32_t>(std::max(1.0f, card.x()))),
        std::max(4, static_cast<int32_t>(std::max(1.0f, card.y()))),
    };
}

TextLayerRenderFrame TextLayerEffectFrame(const TextLayerRenderFrame& card) {
    const auto texels = TextCardTexelExtent(card.size);
    const Eigen::Vector2f size(static_cast<float>(std::min(texels[0], kTextEffectExtentLimit)),
                               static_cast<float>(std::min(texels[1], kTextEffectExtentLimit)));
    return {
        .bounds = {
            .left   = card.center.x() - size.x() * 0.5f,
            .right  = card.center.x() + size.x() * 0.5f,
            .bottom = card.center.y() - size.y() * 0.5f,
            .top    = card.center.y() + size.y() * 0.5f,
        },
        .size   = size,
        .center = card.center,
    };
}

std::string TextTextureName(std::string_view layer_key) {
    return "runtime/text/" + std::string(layer_key);
}

void RasterizeTextLayer(const TextLayerState& state, uint32_t width, uint32_t height,
                        std::vector<uint8_t>& rgba) {
    // Paints the text, FreeType's part under its lock, into `plot`.
    const auto paint = [&](auto&& plot) {
        bool rasterized = false;
        {
            const std::lock_guard lock { g_freetype_mutex };
            rasterized = RasterizeFreeTypeText(state, width, height, plot);
        }
        if (! rasterized) RasterizeFallbackText(state, width, height, plot);
    };

    if (TextStyleActive(state.style)) {
        // The style mixes the coverage of the glyphs into three masks; see
        // ComposeStyledText.
        std::vector<uint8_t> coverage(static_cast<std::size_t>(width) * height, 0u);
        paint([&](int x, int y, uint8_t value) {
            auto& pixel = coverage[static_cast<std::size_t>(y) * width + static_cast<std::size_t>(x)];
            pixel       = std::max(pixel, value);
        });
        ComposeStyledText(ResolveStyleMetrics(state.style, state.point_size), coverage, width,
                          height, rgba);
        return;
    }

    const auto  color       = TextColorBytes(state);
    const float alpha_scale = static_cast<float>(color[3]) / 255.0f;
    // The texture is straight alpha, sampled with linear filtering past its raster when the
    // layer is scaled up. An edge sample then mixes a glyph texel with a clear one, and it is
    // the text's colour at part of its alpha only if the clear texel holds the colour too: left
    // black it dims the colour of every edge toward black, on top of the alpha that already
    // fades it, and a dark ring runs round each stroke. Wallpaper Engine draws its glyphs in
    // one colour at the coverage as alpha, so every texel takes the colour.
    // A blend that looks at no alpha (colour blend 5 or 10) would show that colour in a clear
    // texel; the card's shader weighs it by the alpha for those (`BuildTextSceneShader`).
    const std::size_t texels = std::min(rgba.size() / 4u, static_cast<std::size_t>(width) * height);
    for (std::size_t texel = 0; texel < texels; ++texel) {
        rgba[texel * 4u + 0u] = color[0];
        rgba[texel * 4u + 1u] = color[1];
        rgba[texel * 4u + 2u] = color[2];
    }
    // The colour is already in every texel; the glyphs only raise the alpha.
    paint([&](int x, int y, uint8_t coverage) {
        const auto alpha =
            static_cast<uint8_t>(std::lround(static_cast<float>(coverage) * alpha_scale));
        const std::size_t offset =
            (static_cast<std::size_t>(y) * width + static_cast<std::size_t>(x)) * 4u;
        rgba[offset + 3u] = std::max(rgba[offset + 3u], alpha);
    });
}

#ifdef WESCENE_BUILD_TESTS
uint64_t TextLayerMeasurementCountForTests() {
    return g_measurement_count.load();
}

void ResetTextLayerMeasurementCountForTests() {
    g_measurement_count.store(0);
}

TextLayerLayout TextLayerBoxLayoutForTests(const TextLayerState& state) {
    return MeasureFallbackText(state);
}

void RasterizeTextLayerBoxesForTests(const TextLayerState& state, uint32_t width, uint32_t height,
                                     std::vector<uint8_t>& rgba) {
    RasterizeFallbackText(state, width, height, [&](int x, int y, uint8_t coverage) {
        const std::size_t offset =
            (static_cast<std::size_t>(y) * width + static_cast<std::size_t>(x)) * 4u;
        rgba[offset + 0u] = 255u;
        rgba[offset + 1u] = 255u;
        rgba[offset + 2u] = 255u;
        rgba[offset + 3u] = std::max(rgba[offset + 3u], coverage);
    });
}

uint64_t TextFontFilesOpenedForTests() {
    const std::lock_guard lock { g_freetype_mutex };
    return FaceCache::Get().FilesOpened();
}

uint64_t TextFallbackFaceRequestsForTests() {
    return g_fallback_requests.load();
}

std::size_t TextFontFacesCachedForTests() {
    const std::lock_guard lock { g_freetype_mutex };
    return FaceCache::Get().Size();
}

bool TextFontFacesAreReadFromFilesForTests() {
    const std::lock_guard lock { g_freetype_mutex };
    return FaceCache::Get().FromFiles();
}

void ResetTextFontCacheForTests() {
    const std::lock_guard lock { g_freetype_mutex };
    FaceCache::Get().Reset();
    g_fallback_requests.store(0);
}
#endif

namespace
{
// What a face's fit adds to the identity of the glyphs drawn with it.
std::string FontFitIdentity(const SystemFontFit& fit) {
    std::string identity = std::to_string(fit.size_adjust);
    if (fit.line_metrics.has_value()) {
        identity += ":" + std::to_string(fit.line_metrics->units_per_em) + "/" +
                    std::to_string(fit.line_metrics->ascender) + "/" +
                    std::to_string(fit.line_metrics->descender) + "/" +
                    std::to_string(fit.line_metrics->line_gap);
    }
    return identity;
}
} // namespace

TextLayer::TextLayer(TextLayerState state): m_state(std::move(state)) {
    if (m_state.resolved_font_identity.empty()) m_state.resolved_font_identity = m_state.font_key;
    if (m_state.resolved_font_kind.empty()) m_state.resolved_font_kind = "system";
    EnsureCacheIdentity();
    Relayout();
    MarkCacheDirty();
    m_state.dirty = false;
}

TextLayer::TextLayer(TextLayerState state, TextLayerLayout layout)
    : m_state(std::move(state)), m_layout(std::move(layout)) {
    if (m_state.resolved_font_identity.empty()) m_state.resolved_font_identity = m_state.font_key;
    if (m_state.resolved_font_kind.empty()) m_state.resolved_font_kind = "system";
    EnsureCacheIdentity();
    MarkCacheDirty();
    m_state.dirty = false;
}

void TextLayer::SetText(std::string text) {
    if (m_state.text == text) return;
    m_state.text           = std::move(text);
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::SetPointSize(float point_size) {
    if (! std::isfinite(point_size) || point_size <= 0.0f || m_state.point_size == point_size) return;
    m_state.point_size     = point_size;
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::SetFont(std::string font_key, std::string kind, std::string identity,
                        std::string path, std::string face, SystemFontFit fit,
                        SharedFontData data) {
    if (m_state.font_key == font_key && m_state.resolved_font_kind == kind &&
        m_state.resolved_font_identity == identity && m_state.resolved_font_path == path &&
        m_state.resolved_font_face == face && m_state.resolved_font_fit == fit) {
        return;
    }
    m_state.font_key               = std::move(font_key);
    m_state.resolved_font_kind     = std::move(kind);
    m_state.resolved_font_identity = std::move(identity);
    m_state.resolved_font_path     = std::move(path);
    m_state.resolved_font_face     = std::move(face);
    m_state.resolved_font_fit      = std::move(fit);
    m_state.resolved_font_data     = std::move(data);
    m_state.dirty                  = true;
    m_state.layout_pending         = true;
    MarkCacheDirty();
}

void TextLayer::SetAlignment(std::string horizontal, std::string vertical) {
    if (m_state.horizontal_align == horizontal && m_state.vertical_align == vertical) return;
    m_state.horizontal_align = std::move(horizontal);
    m_state.vertical_align   = std::move(vertical);
    m_state.dirty            = true;
    m_state.layout_pending   = true;
    MarkCacheDirty();
}

void TextLayer::SetPaddingApplies(bool applies) {
    if (m_state.padding_applies == applies) return;
    m_state.padding_applies = applies;
    m_state.padding         = applies ? m_state.authored_padding : Eigen::Vector2f::Zero();
    m_state.dirty           = true;
    m_state.layout_pending  = true;
    MarkCacheDirty();
}

bool TextLayer::ApplyPreparedLayout(uint64_t revision, TextLayerLayout layout) {
    if (revision <= m_prepared_revision || revision > m_state.cache_revision) return false;
    m_prepared_revision    = revision;
    m_layout               = std::move(layout);
    m_state.layout_pending = revision != m_state.cache_revision;
    return true;
}

void TextLayer::ClearDirty() {
    m_state.dirty       = false;
    m_state.cache_dirty = false;
    m_state.full_dirty  = false;
}

Eigen::Vector2f TextLayer::rasterSize() const {
    return TextLayerRasterSizeForLayout(m_state, m_layout);
}

TextLayerRenderBounds TextLayer::renderBounds() const {
    return TextLayerRenderBoundsForLayout(m_state, m_layout);
}

void TextLayer::Relayout() {
    m_layout               = MeasureTextLayerLayout(m_state);
    m_state.layout_pending = false;
}

void TextLayer::EnsureCacheIdentity() {
    if (! m_state.texture_cache_key.empty()) return;
    const std::string material = m_state.layer_key + "|" + m_state.text + "|" +
                                 m_state.resolved_font_kind + "|" + m_state.resolved_font_identity +
                                 "|" + m_state.resolved_font_path + "|" +
                                 m_state.resolved_font_face + "|" +
                                 FontFitIdentity(m_state.resolved_font_fit) + "|" +
                                 std::to_string(m_state.point_size) + "|" +
                                 std::to_string(m_state.max_width) + "|" +
                                 std::to_string(m_state.max_rows) + "|" +
                                 std::to_string(m_state.limit_width) + "|" +
                                 std::to_string(m_state.limit_rows) + "|" +
                                 std::to_string(m_state.use_ellipsis) + "|" +
                                 std::to_string(m_state.block_align) + "|" +
                                 std::to_string(m_state.padding.x()) + "|" +
                                 std::to_string(m_state.padding.y()) + "|" +
                                 std::to_string(m_state.spacing.x()) + "|" +
                                 std::to_string(m_state.spacing.y()) + "|" +
                                 std::to_string(m_state.style.outline) + "|" +
                                 std::to_string(m_state.style.outline_thickness) + "|" +
                                 std::to_string(m_state.style.blur) + "|" +
                                 std::to_string(m_state.style.blur_size) + "|" +
                                 std::to_string(m_state.style.drop_shadow) + "|" +
                                 std::to_string(m_state.style.shadow_size) + "|" +
                                 std::to_string(m_state.style.shadow_opacity) + "|" +
                                 std::to_string(m_state.style.shadow_offset.x()) + "|" +
                                 std::to_string(m_state.style.shadow_offset.y());
    m_state.texture_cache_key = "textcache:" + std::to_string(std::hash<std::string> {}(material));
}

void TextLayer::MarkCacheDirty() {
    ++m_state.cache_revision;
    m_state.cache_dirty = true;
    m_state.full_dirty  = true;
}

} // namespace wallpaper
