// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Text/TextLayer.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextShaper.hpp"

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
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>
#include <unordered_map>
#include <utility>

#include <ft2build.h>
#include FT_FREETYPE_H

#include "msdfgen/msdfgen.h"
#include "msdfgen/ext/import-font.h"

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
    // Created once, on first use, and destroyed after every face made from it (the faces live
    // in statics constructed after this one). Null when FreeType cannot start: every face
    // request then fails and the layout falls back to boxes.
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
    // The shaped glyph: its index in the face, the index in its paragraph of the first code
    // point it stands for (`codepoint` is that code point), and the shaper's offsets in whole
    // pixels (y up), which move its ink and not the pen.
    uint32_t glyph_index { 0 };
    uint32_t source { 0 };
    float    x_offset { 0.0f };
    float    y_offset { 0.0f };
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

// One colour channel as a byte; a channel that is not a number counts as full.
uint8_t ColorByte(float value) {
    if (! std::isfinite(value)) value = 1.0f;
    return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
}

// The colour every texel of a plain picture takes, and the alpha a fully covered one has. The
// alpha is the state's own and is not scaled by brightness.
std::array<uint8_t, 4> TextColorBytes(const TextLayerState& state) {
    const float brightness = std::isfinite(state.brightness) ? std::max(0.0f, state.brightness) : 1.0f;
    return {
        ColorByte(state.color.x() * brightness),
        ColorByte(state.color.y() * brightness),
        ColorByte(state.color.z() * brightness),
        ColorByte(state.alpha),
    };
}

using OwnedFace = std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter>;

// The pixels per em a point size asks for, in 26.6.
FT_Pos WantedPpem26(float point_size) {
    return (static_cast<FT_Pos>(FreeTypeCharHeight(point_size)) * static_cast<FT_Pos>(kTextDpi) + 36) /
           static_cast<FT_Pos>(kPointsPerInch);
}

// Sizes `face` as Wallpaper Engine does: `point_size` points at 300 dpi. A face of colour
// bitmaps only has no scalable size (Apple Color Emoji, which stands for the scalable Segoe UI
// Emoji); FreeType then takes the strike at or above the size, else the largest (the T.1 F7
// fallback, decompiles/G-F7.md: on Windows FreeType sizes the COLR face itself), and the glyphs
// are scaled by `FacePixelScale`.
bool SetFaceSize(FT_Face face, float point_size) {
    if (FT_Set_Char_Size(face, 0, FreeTypeCharHeight(point_size), static_cast<FT_UInt>(kTextDpi),
                         static_cast<FT_UInt>(kTextDpi)) == 0) {
        return true;
    }
    if (! FT_HAS_FIXED_SIZES(face) || face->num_fixed_sizes <= 0) return false;
    const FT_Pos wanted = WantedPpem26(point_size);
    int above = -1, largest = 0;
    for (int index = 0; index < face->num_fixed_sizes; ++index) {
        const FT_Pos ppem = face->available_sizes[index].y_ppem;
        if (ppem >= wanted && (above < 0 || ppem < face->available_sizes[above].y_ppem)) above = index;
        if (ppem > face->available_sizes[largest].y_ppem) largest = index;
    }
    const int best = above >= 0 ? above : largest;
    return best >= 0 && FT_Select_Size(face, best) == 0;
}

// How much a glyph of `face` is scaled to the layout's size: 1 for a scalable face, the wanted
// pixels per em over the strike's for a bitmap one.
float FacePixelScale(FT_Face face, float point_size) {
    if (FT_IS_SCALABLE(face) || face->size == nullptr || face->size->metrics.y_ppem == 0) return 1.0f;
    return static_cast<float>(WantedPpem26(point_size)) / 64.0f /
           static_cast<float>(face->size->metrics.y_ppem);
}

// A face of a font the wallpaper ships, which is in memory already.
OwnedFace CreateFreeTypeFaceFromBytes(const std::vector<uint8_t>& data, float point_size) {
    FT_Library library = FtLibrary::Get().handle();
    if (library == nullptr || data.empty()) return nullptr;
    FT_Face face = nullptr;
    // The face reads the bytes where they lie; the state that owns them outlives the layout.
    if (FT_New_Memory_Face(library, data.data(), static_cast<FT_Long>(data.size()), 0, &face) != 0) {
        return nullptr;
    }
    OwnedFace owned(face);
    return SetFaceSize(face, point_size) ? std::move(owned) : nullptr;
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
    static constexpr std::size_t kCapacity = 10;

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
// Twemoji, Segoe UI Symbol, Microsoft YaHei and Malgun Gothic (`sub_1401AD670`), each from the
// Windows Fonts folder (or, for Twemoji, its own assets). The faces here stand for them.
//
//  - Colour emoji: Apple Color Emoji stands for Segoe UI Emoji, and the assets' own
//    TwemojiMozilla.ttf is read from the wallpaper assets as Wallpaper Engine reads it. Their
//    glyphs are colour glyphs (`FT_LOAD_COLOR`), drawn from the colour atlas.
//  - Arial Unicode MS is last, not third: it ships with Microsoft Office and not with Windows,
//    so Wallpaper Engine on a stock install draws Chinese in Microsoft YaHei, and PingFang SC
//    is the face that sets Simplified Chinese punctuation as it does. The scripts no other face
//    has (Thai, Hebrew with points, ...) still draw from it.
//  - Apple Symbols stands for Segoe UI Symbol but is not asked for the CJK punctuation and
//    fullwidth forms (U+3000-303F, U+FF00-FFEF): it has some of them, set centred in the cell,
//    where Microsoft YaHei, whose stand-in is the next face, sets them as Simplified Chinese
//    does, so a string would otherwise mix the two (a centred fullwidth comma beside a
//    left-set ideographic one). That Segoe UI Symbol does not have them is inferred.
enum class ChainSource : uint8_t { SceneKey, Family, AssetEmoji };
struct ChainFace {
    // A scene font key (`ResolveSceneFont`), an installed family (`ResolveInstalledFamily`),
    // or the assets' Twemoji (`TextLayerState::asset_emoji_font`).
    std::string_view name;
    ChainSource      source;
    // The face is not asked for CJK punctuation and fullwidth forms (`IsCjkPunctuation`).
    bool             not_for_cjk_punctuation { false };
};
constexpr ChainFace kFallbackChain[] = {
    { "systemfont_arial", ChainSource::SceneKey },     // arial.ttf
    { "Apple Color Emoji", ChainSource::Family },      // seguiemj.ttf
    { "systemfont_segoe", ChainSource::SceneKey },     // segoeui.ttf
    { "TwemojiMozilla.ttf", ChainSource::AssetEmoji }, // assets/fonts/TwemojiMozilla.ttf
    { "Apple Symbols", ChainSource::Family, true },    // seguisym.ttf
    { "PingFang SC", ChainSource::Family },            // msyh.ttc
    { "Apple SD Gothic Neo", ChainSource::Family },    // Malgun.ttf
    { "Arial Unicode MS", ChainSource::Family },       // arialuni.ttf
};

// CJK Symbols and Punctuation, and Halfwidth and Fullwidth Forms.
constexpr bool IsCjkPunctuation(uint32_t codepoint) {
    return (codepoint >= 0x3000u && codepoint <= 0x303Fu) ||
           (codepoint >= 0xFF00u && codepoint <= 0xFFEFu);
}
// A layout holds its font, a face standing in for it when it cannot be opened, and the chain's
// installed faces, so none of what it holds is the face the cache drops.
static_assert(std::size(kFallbackChain) + 2 <= FaceCache::kCapacity);

// The faces one layout draws with: the layer's own font, and the fallback chain's, none of
// which is opened until a glyph needs it. All are sized for the layout and only good while the
// caller holds `g_freetype_mutex`.
class FaceChain {
public:
    explicit FaceChain(const TextLayerState& state)
        : m_point_size(ClampedPointSize(state.point_size)), m_emoji_bytes(state.asset_emoji_font) {
        FaceCache::Get().Refresh();
        // Keep an authored, usable font first. A package can also contain a broken
        // font, or a previously resolved file can disappear before rasterization.
        // Recover at the decoder boundary so measurement and rasterization choose
        // the same real face in all of these cases, not placeholder rectangles.
        if (! state.resolved_font_data.empty()) {
            m_owned = CreateFreeTypeFaceFromBytes(state.resolved_font_data.bytes(), state.point_size);
            Hold(m_owned.get(), "mem:" + std::to_string(reinterpret_cast<std::uintptr_t>(
                                             state.resolved_font_data.data())),
                 m_point_size);
        } else if (! state.resolved_font_path.empty()) {
            m_fit = state.resolved_font_fit;
            Hold(OpenFitted(state.resolved_font_path, state.resolved_font_face, m_fit),
                 state.resolved_font_path + "#" + state.resolved_font_face, m_point_size * m_fit.size_adjust);
        }
        if (primary() != nullptr) return;
        // Wallpaper Engine draws what it cannot load in Arial.
        for (const auto& key : { state.font_key, std::string(kDefaultSceneFontKey) }) {
            const auto font = ResolveSceneFont(key);
            m_fit           = font.fit;
            Hold(OpenFitted(font.path, font.postscript_name, m_fit), font.path + "#" + font.postscript_name,
                 m_point_size * m_fit.size_adjust);
            if (primary() != nullptr) return;
        }
        m_fit = {};
    }

    FT_Face primary() const { return m_held.empty() ? nullptr : m_held.front(); }
    // How the primary face stands in for the font the layer names, if it does.
    const SystemFontFit& primaryFit() const { return m_fit; }
    FT_Face              face(uint8_t index) const { return m_held[index]; }
    // What tells the face at `index` apart from every other in an atlas's glyph table.
    const std::string&   key(uint8_t index) const { return m_keys[index]; }
    // The point size the face at `index` is sized for (the layer's, times its fit).
    float                pointSize(uint8_t index) const { return m_sizes[index]; }
    // How much the face's glyphs are scaled to that size (`FacePixelScale`).
    float                scale(uint8_t index) const { return m_scales[index]; }
    // Whether the face draws colour glyphs (FT_FACE_FLAG_COLOR, G-F6).
    bool                 color(uint8_t index) const { return FT_HAS_COLOR(m_held[index]); }

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
            FT_Face     other = nullptr;
            std::string key;
            float       size  = m_point_size;
            if (entry.source == ChainSource::AssetEmoji) {
                if (m_emoji_bytes.empty() || m_emoji != nullptr) continue;
                m_emoji = CreateFreeTypeFaceFromBytes(m_emoji_bytes.bytes(), m_point_size);
                other   = m_emoji.get();
                key     = "asset:TwemojiMozilla.ttf";
                if (other == nullptr) continue;
            } else {
                const auto font = entry.source == ChainSource::SceneKey ? ResolveSceneFont(entry.name)
                                                                        : ResolveInstalledFamily(entry.name);
                other = FaceCache::Get().Acquire(font.path, font.postscript_name);
                // A face that is held already has been asked for the glyph, and is sized for the
                // layer's font: the cache hands out one face per file, so it is left alone.
                if (other == nullptr || std::ranges::find(m_held, other) != m_held.end()) continue;
                size = m_point_size * font.fit.size_adjust;
                if (! SetFaceSize(other, size)) continue;
                key = font.path + "#" + font.postscript_name;
            }
            Hold(other, std::move(key), size, entry.not_for_cjk_punctuation);
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

    void Hold(FT_Face face, std::string key, float size, bool not_for_cjk_punctuation = false) {
        if (face == nullptr) return;
        m_held.push_back(face);
        m_keys.push_back(std::move(key));
        m_sizes.push_back(size);
        m_scales.push_back(FacePixelScale(face, size));
        m_not_for_cjk_punctuation.push_back(not_for_cjk_punctuation);
    }

    // Whether the face held at `index` is one that is not asked for `codepoint`.
    bool Declines(std::size_t index, uint32_t codepoint) const {
        return m_not_for_cjk_punctuation[index] && IsCjkPunctuation(codepoint);
    }

    float                    m_point_size { 12.0f };
    // The faces held, the layer's font first.
    std::vector<FT_Face>     m_held;
    std::vector<std::string> m_keys;
    std::vector<float>       m_sizes;
    std::vector<float>       m_scales;
    // For each face held: whether it is not asked for CJK punctuation.
    std::vector<bool>        m_not_for_cjk_punctuation;
    OwnedFace                m_owned;
    SharedFontData           m_emoji_bytes;
    OwnedFace                m_emoji;
    SystemFontFit            m_fit;
    std::size_t              m_next_in_chain { 0 };
};

// The code points of UTF-8 text; never fails. Ill-formed input becomes U+FFFD: a stray
// continuation byte or a byte that cannot lead is one, a lead without the continuation bytes
// it announces is one and decoding goes on with the byte after the lead, and a sequence cut
// off by the end of the text is one and ends the text. Overlong and surrogate forms decode to
// the number they spell; no face has such a code point, so they are skipped later.
std::vector<uint32_t> DecodeUtf8(std::string_view text) {
    constexpr uint32_t kReplacement = 0xFFFD;
    const auto is_continuation = [](unsigned char byte) { return (byte & 0xC0u) == 0x80u; };
    std::vector<uint32_t> out;
    out.reserve(text.size());
    std::size_t at = 0;
    while (at < text.size()) {
        const auto lead = static_cast<unsigned char>(text[at]);
        if (lead < 0x80u) {
            out.push_back(lead);
            ++at;
            continue;
        }
        std::size_t length = 0;
        uint32_t    value  = 0;
        if (lead >= 0xC0u && lead <= 0xDFu) { length = 2; value = lead & 0x1Fu; }
        else if (lead >= 0xE0u && lead <= 0xEFu) { length = 3; value = lead & 0x0Fu; }
        else if (lead >= 0xF0u && lead <= 0xF7u) { length = 4; value = lead & 0x07u; }
        if (length == 0) { // a stray continuation byte, or one that cannot lead
            out.push_back(kReplacement);
            ++at;
            continue;
        }
        const std::size_t available = text.size() - at - 1;
        const std::size_t checked   = std::min(available, length - 1);
        bool              well_formed = true;
        for (std::size_t index = 1; index <= checked; ++index) {
            if (! is_continuation(static_cast<unsigned char>(text[at + index]))) {
                well_formed = false;
                break;
            }
        }
        if (! well_formed) {
            out.push_back(kReplacement);
            ++at;
            continue;
        }
        if (available < length - 1) { // cut off by the end of the text
            out.push_back(kReplacement);
            break;
        }
        for (std::size_t index = 1; index < length; ++index) {
            value = (value << 6) | (static_cast<unsigned char>(text[at + index]) & 0x3Fu);
        }
        out.push_back(value);
        at += length;
    }
    return out;
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
linalg::Vector2f CardPadding(const TextLayerState& state) {
    constexpr float kMaxCardPadding = 512.0f;
    const auto lane = [=](float value) {
        return std::isfinite(value) ? std::min(value, kMaxCardPadding) : 0.0f;
    };
    return { lane(state.padding.x()), lane(state.padding.y()) };
}

// Code points that stay in the run before them whatever face would draw them: tab, line
// feed, carriage return, space and the zero-width joiner (Wallpaper Engine's itemiser
// sub_1401AD670 at 0x1401ADA12, artifacts/we-parity/decompiles/G-F14.md).
constexpr bool JoinsPreviousRun(uint32_t codepoint) {
    return codepoint == 0x200Du || codepoint == ' ' || codepoint == '\t' || codepoint == '\n' ||
           codepoint == '\r';
}

// Shapes one paragraph as Wallpaper Engine does (sub_1401B0410, decompiles G-F1/F2/F3.md):
// the text is cut into runs of one face -- the first face that has a code point, the joiners
// above staying with their run -- and each run is shaped on its own, its glyphs placed in the
// order the shaper gives them; there is no reordering between runs. A glyph's pen advance is
// the shaper's advance cut to whole pixels plus `spacing` x, on every glyph. A code point no
// face has is left out.
std::vector<GlyphRun> ShapeParagraph(FaceChain& faces, TextShaper& shaper, std::span<const uint32_t> text,
                                     float spacing_x) {
    std::vector<GlyphRun> out;
    std::vector<uint32_t> run;
    std::vector<uint32_t> run_source;
    int                   run_face = -1;
    const auto flush = [&] {
        if (run.empty()) return;
        const auto index = static_cast<uint8_t>(run_face);
        FT_Face    face  = faces.face(index);
        // A bitmap face's strike is scaled to the layout's size, advances and ink alike.
        const float scale = faces.scale(index);
        const FT_Int32 load = faces.color(index) ? FT_LOAD_COLOR | FT_LOAD_RENDER
                                                 : FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL;
        for (const auto& shaped : shaper.ShapeRun(face, run)) {
            const uint32_t at = std::min<uint32_t>(shaped.cluster, static_cast<uint32_t>(run.size() - 1));
            const auto whole = [scale](int32_t value) {
                return scale == 1.0f ? static_cast<float>(value >> 6)
                                     : std::floor(static_cast<float>(value) * scale / 64.0f);
            };
            GlyphRun glyph {
                .codepoint   = run[at],
                .advance     = whole(shaped.x_advance) + spacing_x,
                .face        = index,
                .glyph_index = shaped.glyph_index,
                .source      = run_source[at],
                .x_offset    = whole(shaped.x_offset),
                .y_offset    = whole(shaped.y_offset),
            };
            if (FT_Load_Glyph(face, shaped.glyph_index, load) == 0) {
                const FT_GlyphSlot slot = face->glyph;
                glyph.has_ink = slot->bitmap.width > 0u && slot->bitmap.rows > 0u;
                if (glyph.has_ink) {
                    glyph.left   = static_cast<float>(slot->bitmap_left) * scale + glyph.x_offset;
                    glyph.right  = glyph.left + static_cast<float>(slot->bitmap.width) * scale;
                    glyph.top    = static_cast<float>(slot->bitmap_top) * scale + glyph.y_offset;
                    glyph.bottom = glyph.top - static_cast<float>(slot->bitmap.rows) * scale;
                }
            }
            out.push_back(glyph);
        }
        run.clear();
        run_source.clear();
    };
    for (std::size_t at = 0; at < text.size(); ++at) {
        const uint32_t codepoint = text[at];
        const int face = run_face >= 0 && JoinsPreviousRun(codepoint) ? run_face : faces.FaceFor(codepoint);
        if (face < 0) continue;
        if (face != run_face) {
            flush();
            run_face = face;
        }
        run.push_back(codepoint);
        run_source.push_back(static_cast<uint32_t>(at));
    }
    flush();
    return out;
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

// The last row `row_limit` allows ended in text that does not fit, and the layer asks for an
// ellipsis: the row keeps as much of its text as leaves room for the marker inside the width
// limit, dropping one glyph at a time from the end, and the marker follows the last code point
// kept that is not a space or a tab. Each candidate -- the kept text and U+2026 (three full
// stops when no face has it) -- is shaped again, so the marker kerns or joins as the shaper
// decides (Wallpaper Engine sub_1401B0410 with sub_1401B8900(.., 8230), G-F3.md). `text` is the
// row's paragraph and `row_start` the index in it of the row's first code point. `trim_first`
// is the row of a line break that more text followed: its trailing white space goes before
// anything is measured, where a row cut at a glyph is measured with it and trimmed after.
template<typename Shape>
void EllipsizeLastRow(std::vector<LineRun>& lines, Shape shape, std::span<const uint32_t> text,
                      uint32_t row_start, float width_limit, bool trim_first) {
    auto& line = lines.back();
    if (trim_first) {
        while (! line.glyphs.empty() && BreakSpace(line.glyphs.back())) line.glyphs.pop_back();
    }
    std::vector<uint32_t> marker { 0x2026u };
    if (shape(std::span<const uint32_t>(marker)).empty()) marker.assign(3, '.');

    // The end in `text` of the first `count` glyphs of the row, whichever way they run.
    const auto end_of = [&](std::size_t count) {
        uint32_t end = row_start;
        for (std::size_t index = 0; index < count; ++index) end = std::max(end, line.glyphs[index].source + 1u);
        return std::min<uint32_t>(end, static_cast<uint32_t>(text.size()));
    };
    const auto text_to = [&](uint32_t end) {
        return std::vector<uint32_t>(text.begin() + row_start, text.begin() + std::max(row_start, end));
    };
    std::size_t count       = line.glyphs.size();
    bool        keep_marker = true;
    while (true) {
        auto candidate = text_to(end_of(count));
        candidate.insert(candidate.end(), marker.begin(), marker.end());
        const LineRun measured = MakeLine(shape(std::span<const uint32_t>(candidate)));
        if (width_limit == 0.0f || measured.ExtentRight() <= width_limit) break;
        if (count == 0) { keep_marker = false; break; }
        --count;
    }
    auto kept = text_to(end_of(count));
    while (! kept.empty() && (kept.back() == ' ' || kept.back() == '\t')) kept.pop_back();
    // A row that already ends in the marker is not given another.
    if (! kept.empty() && kept.back() == 0x2026u) keep_marker = false;
    if (keep_marker) kept.insert(kept.end(), marker.begin(), marker.end());
    line = MakeLine(shape(std::span<const uint32_t>(kept)));
}

// `shape(paragraph)` gives a paragraph's glyphs (`ShapeParagraph`): a paragraph is shaped once
// and its rows are cut from the shaped glyphs (G-F3.md).
//
// Text is cut into paragraphs at line breaks, and a break with nothing after it
// ends the text without a row of its own. A row wraps before a glyph whose ink
// would end past the width limit. Where the row limit allows another row the
// wrap is at the last space or tab before that glyph (the row keeps everything
// up to it, the next row starts at the glyph with the white space before it
// dropped), or at the glyph itself when the row holds none. On the last row the
// limit allows, nothing wraps: the row keeps every glyph before the glyph that
// did not fit, and the layer's ellipsis, if it asks for one, replaces the end.
template<typename Shape>
std::vector<LineRun> BuildLineRuns(const TextLayerState& state, Shape shape) {
    std::vector<LineRun> lines;
    lines.emplace_back();
    const float width_limit = TextWidthLimit(state);
    const size_t row_limit = state.limit_rows && state.max_rows > 0 ? size_t(state.max_rows) : SIZE_MAX;
    bool omitted        = false;
    bool omitted_by_break = false;

    const auto codepoints = DecodeUtf8(state.text);
    std::vector<std::vector<uint32_t>> paragraphs(1);
    for (std::size_t at = 0; at < codepoints.size(); ++at) {
        const uint32_t codepoint = codepoints[at];
        if (codepoint == '\n') {
            // Nothing after the break: the text ends with the row before it.
            if (at + 1 == codepoints.size()) break;
            paragraphs.emplace_back();
            continue;
        }
        if (codepoint == '\r') continue;
        paragraphs.back().push_back(codepoint);
    }

    std::span<const uint32_t> row_text;
    uint32_t                  row_start = 0;
    for (std::size_t paragraph = 0; paragraph < paragraphs.size() && ! omitted; ++paragraph) {
        if (paragraph > 0) {
            if (lines.size() == row_limit) { omitted = omitted_by_break = true; break; }
            lines.emplace_back();
        }
        row_text  = paragraphs[paragraph];
        row_start = 0;
        for (const auto& glyph : shape(row_text)) {
            // A row wraps before a glyph whose ink would end past the limit, once it
            // holds a glyph already; a space or tab never starts a wrap.
            const bool overflows = width_limit > 0.0f && ! lines.back().glyphs.empty() &&
                                   ! BreakSpace(glyph) &&
                                   lines.back().advance_width + glyph.right > width_limit;
            AppendMeasuredGlyph(lines.back(), glyph);
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
            row_start = carry.empty() ? static_cast<uint32_t>(row_text.size()) : carry.front().source;
            lines.push_back(MakeLine(carry));
        }
    }
    if (omitted && state.use_ellipsis) {
        EllipsizeLastRow(lines, shape, row_text, row_start, width_limit, omitted_by_break);
    }
    if (state.block_align && width_limit > 0.0f) JustifyWrappedLines(lines, width_limit);
    return lines;
}

std::vector<LineRun> BuildFreeTypeLines(const TextLayerState& state, FaceChain& faces) {
    const float spacing_x = GlyphSpacing(state);
    TextShaper  shaper;
    return BuildLineRuns(state, [&](std::span<const uint32_t> text) {
        return ShapeParagraph(faces, shaper, text, spacing_x);
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
    return BuildLineRuns(state, [=](std::span<const uint32_t> text) {
        std::vector<GlyphRun> glyphs;
        glyphs.reserve(text.size());
        for (std::size_t at = 0; at < text.size(); ++at) {
            const uint32_t codepoint = text[at];
            const float advance = std::max(1.0f, pixels * kFallbackAdvance);
            const float ink     = std::max(1.0f, pixels * kFallbackInk);
            const bool  has_ink = codepoint != ' ' && codepoint != '\t';
            GlyphRun    glyph {
                           .codepoint = codepoint,
                           .advance   = (codepoint == '\t' ? advance * 4.0f : advance) + spacing_x,
                           .has_ink   = has_ink,
                           .source    = static_cast<uint32_t>(at),
            };
            if (has_ink) {
                glyph.right = ink;
                glyph.top   = pixels * kFallbackAscent;
            }
            glyphs.push_back(glyph);
        }
        return glyphs;
    });
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
linalg::Vector2f CardCentre(const TextLayerState& state, const TextBlock& block) {
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
// Outline, blur and drop shadow (the font shader's uniforms).
//
// Wallpaper Engine draws a glyph from a distance-field atlas made at 32 pixels to the em,
// padded by 12 pixels and scaled by `ppem / 32` on the way to the screen. The scene file's
// sizes are scaled into that atlas by `k = 32 / pointsize * 0.24` and capped there
// (`sub_1401B3B60`, decompiles/G-F5.md).
// ---------------------------------------------------------------------------

constexpr float kAtlasEm        = 32.0f;
constexpr float kAtlasMargin    = 12.0f; // atlas pixels around a distance-field cell
constexpr float kAtlasUnitScale = 0.24f;
constexpr float kOutlineCap     = 5.1000004f;
constexpr float kBlurCap        = 6.0f;
constexpr float kShadowCap      = 6.0f;
constexpr float kShadowOffsetCap = 6.0f;

float FiniteOr(float value, float fallback) { return std::isfinite(value) ? value : fallback; }

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

// ---------------------------------------------------------------------------
// Glyph atlases (`sub_1401AE080`, `sub_1401AC8D0`, decompiles/G-F6.md, G-F7.md, G-F16.md).
// ---------------------------------------------------------------------------

constexpr uint32_t kAtlasStartSide = 512;
constexpr uint32_t kAtlasLimitSide = 4096;
#ifdef WESCENE_BUILD_TESTS
std::atomic_uint64_t g_cells_made { 0 };
#endif

// One glyph in an atlas: its rectangle, where the pen and baseline lie in it (atlas pixels
// from its top-left, y down), and how many layer pixels one of its pixels covers.
struct GlyphCell {
    uint32_t x { 0 }, y { 0 }, w { 0 }, h { 0 };
    float    origin_x { 0.0f }, origin_y { 0.0f };
    float    px_scale { 1.0f };
    bool     color { false };
    // A colour glyph's own pixels (straight RGBA) and how many of the cell's pixels one
    // bitmap pixel spans; the colour atlas is laid out from these.
    std::vector<uint8_t> color_rgba;
    uint32_t             color_w { 0 }, color_h { 0 };
    float                color_step { 1.0f };
    float                color_margin { 0.0f };
};

// One persistent atlas of one font, size and kind: a single page that starts at 512 by 512
// and doubles up to 4096, packed in shelves with a pixel between cells.
class GlyphAtlas {
public:
    explicit GlyphAtlas(bool distance_field): m_distance_field(distance_field) { Reset(); }

    bool distanceField() const { return m_distance_field; }
    uint32_t side() const { return m_side; }

    void Reset() {
        m_side = kAtlasStartSide;
        m_pixels = std::make_shared<std::vector<uint8_t>>(std::size_t(m_side) * m_side * Bpp(), 0u);
        m_cells.clear();
        m_rows.clear();
        m_next_row_y   = 0;
        m_color_layout = nullptr;
        m_has_color    = false;
    }

    const GlyphCell* Find(const std::string& key) const {
        const auto found = m_cells.find(key);
        return found == m_cells.end() ? nullptr : &found->second;
    }

    // Room for a `w` by `h` cell; false when even a 4096 page is full.
    bool Place(uint32_t w, uint32_t h, uint32_t& x, uint32_t& y) {
        for (;;) {
            for (auto& row : m_rows) {
                if (h <= row.height && row.next_x + w <= m_side) {
                    x = row.next_x;
                    y = row.y;
                    row.next_x += w + 1u;
                    return true;
                }
            }
            if (w <= m_side && m_next_row_y + h <= m_side) {
                m_rows.push_back({ m_next_row_y, h, w + 1u });
                x = 0;
                y = m_next_row_y;
                m_next_row_y += h + 1u;
                return true;
            }
            if (m_side >= kAtlasLimitSide) return false;
            Grow();
        }
    }

    // The pixels to write into, copied first if a build still holds them.
    uint8_t* Writable() {
        if (m_pixels.use_count() > 1) m_pixels = std::make_shared<std::vector<uint8_t>>(*m_pixels);
        return m_pixels->data();
    }

    void Insert(std::string key, GlyphCell cell) {
        if (cell.color) {
            m_has_color    = true;
            m_color_layout = nullptr;
        }
        m_cells.insert_or_assign(std::move(key), std::move(cell));
    }

    std::size_t Bpp() const { return m_distance_field ? 4u : 1u; }

    TextAtlasPicture Picture() const { return { m_side, m_side, m_distance_field, m_pixels }; }

    // The colour atlas: the main atlas times `scale = max(1, ceil(max(w, h) / 32))` of its
    // colour glyphs in the distance-field kind, the main atlas's size in the plain one, with
    // each colour glyph in its cell's rectangle so that one UV addresses both (G-F7).
    TextAtlasPicture ColorPicture() {
        if (! m_has_color) return {};
        if (m_color_layout == nullptr) {
            uint32_t scale = 1;
            if (m_distance_field) {
                for (const auto& [key, cell] : m_cells) {
                    if (! cell.color) continue;
                    scale = std::max(scale, (std::max(cell.color_w, cell.color_h) + 31u) / 32u);
                }
            }
            const uint32_t side = m_side * scale;
            auto pixels = std::make_shared<std::vector<uint8_t>>(std::size_t(side) * side * 4u, 0u);
            for (const auto& [key, cell] : m_cells) {
                if (! cell.color || cell.color_rgba.empty()) continue;
                for (uint32_t py = 0; py < cell.h * scale; ++py) {
                    for (uint32_t px = 0; px < cell.w * scale; ++px) {
                        // The cell pixel, then the bitmap pixel under it.
                        const float cx = (static_cast<float>(px) + 0.5f) / static_cast<float>(scale);
                        const float cy = (static_cast<float>(py) + 0.5f) / static_cast<float>(scale);
                        const long  bx = static_cast<long>(std::floor((cx - cell.color_margin) / cell.color_step));
                        const long  by = static_cast<long>(std::floor((cy - cell.color_margin) / cell.color_step));
                        if (bx < 0 || by < 0 || bx >= long(cell.color_w) || by >= long(cell.color_h)) continue;
                        const auto* source = &cell.color_rgba[(std::size_t(by) * cell.color_w + std::size_t(bx)) * 4u];
                        auto* target = &(*pixels)[(std::size_t(cell.y * scale + py) * side +
                                                   std::size_t(cell.x * scale + px)) * 4u];
                        std::copy_n(source, 4, target);
                    }
                }
            }
            m_color_layout = std::move(pixels);
            m_color_side   = side;
        }
        return { m_color_side, m_color_side, true, m_color_layout };
    }

    uint64_t used { 0 };

private:
    struct Row {
        uint32_t y { 0 };
        uint32_t height { 0 };
        uint32_t next_x { 0 };
    };

    // Twice as wide and tall; every cell keeps its pixel position.
    void Grow() {
        const uint32_t side = m_side * 2u;
        auto pixels = std::make_shared<std::vector<uint8_t>>(std::size_t(side) * side * Bpp(), 0u);
        const std::size_t row_bytes = std::size_t(m_side) * Bpp();
        for (uint32_t y = 0; y < m_side; ++y) {
            std::copy_n(m_pixels->data() + y * row_bytes, row_bytes, pixels->data() + std::size_t(y) * side * Bpp());
        }
        m_pixels       = std::move(pixels);
        m_side         = side;
        m_color_layout = nullptr;
    }

    bool                                            m_distance_field { false };
    uint32_t                                        m_side { kAtlasStartSide };
    std::shared_ptr<std::vector<uint8_t>>           m_pixels;
    std::unordered_map<std::string, GlyphCell>      m_cells;
    std::vector<Row>                                m_rows;
    uint32_t                                        m_next_row_y { 0 };
    bool                                            m_has_color { false };
    std::shared_ptr<std::vector<uint8_t>>           m_color_layout;
    uint32_t                                        m_color_side { 0 };
};

// The atlases every layout shares, by font, size and kind; under `g_freetype_mutex`.
class AtlasCache {
public:
    static constexpr std::size_t kCapacity = 16;

    static AtlasCache& Get() {
        static AtlasCache instance;
        return instance;
    }

    GlyphAtlas& For(const std::string& key, bool distance_field) {
        auto found = m_atlases.find(key);
        if (found == m_atlases.end()) {
            if (m_atlases.size() >= kCapacity) {
                const auto oldest = std::ranges::min_element(
                    m_atlases, {}, [](const auto& entry) { return entry.second->used; });
                m_atlases.erase(oldest);
            }
            found = m_atlases.emplace(key, std::make_unique<GlyphAtlas>(distance_field)).first;
        }
        found->second->used = ++m_clock;
        return *found->second;
    }

    void Clear() { m_atlases.clear(); }

private:
    std::unordered_map<std::string, std::unique_ptr<GlyphAtlas>> m_atlases;
    uint64_t                                                     m_clock { 0 };
};

uint8_t DistanceByte(float value) {
    // Wallpaper Engine scales by 256, not 255, and clamps (G-F6).
    return static_cast<uint8_t>(std::clamp(static_cast<int>(value * 256.0f), 0, 255));
}

// The straight-alpha RGBA of a BGRA (premultiplied) FreeType bitmap.
std::vector<uint8_t> StraightRgba(const FT_Bitmap& bitmap) {
    std::vector<uint8_t> out(std::size_t(bitmap.width) * bitmap.rows * 4u, 0u);
    for (unsigned r = 0; r < bitmap.rows; ++r) {
        const unsigned char* source = bitmap.buffer + long(r) * bitmap.pitch;
        for (unsigned c = 0; c < bitmap.width; ++c) {
            const unsigned char* p = source + c * 4u;
            const unsigned       a = p[3];
            auto* o = &out[(std::size_t(r) * bitmap.width + c) * 4u];
            const auto unmul = [a](unsigned v) { return a == 0 ? 0u : std::min(255u, (v * 255u + a / 2u) / a); };
            o[0] = static_cast<uint8_t>(unmul(p[2]));
            o[1] = static_cast<uint8_t>(unmul(p[1]));
            o[2] = static_cast<uint8_t>(unmul(p[0]));
            o[3] = static_cast<uint8_t>(a);
        }
    }
    return out;
}

// Puts the glyph into the atlas; false when the atlas is full at 4096.
bool MakeCell(GlyphAtlas& atlas, FaceChain& faces, uint8_t face_index, uint32_t glyph_index,
              const std::string& key, bool& placed) {
    placed     = false;
    FT_Face face = faces.face(face_index);
    const float layer_ppem = faces.pointSize(face_index) * kTextDpi / kPointsPerInch;
    GlyphCell   cell;
    std::vector<uint8_t> main_pixels; // cell.w * cell.h * bpp
    const bool colour_face = faces.color(face_index);
    bool       colour_glyph = false;
    if (colour_face && FT_Load_Glyph(face, glyph_index, FT_LOAD_COLOR | FT_LOAD_RENDER) == 0 &&
        face->glyph->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA && face->glyph->bitmap.buffer != nullptr) {
        colour_glyph = true;
    }
    if (colour_glyph) {
        const FT_GlyphSlot slot  = face->glyph;
        const float        strike = faces.scale(face_index); // layer px per bitmap px
        cell.color      = true;
        cell.color_rgba = StraightRgba(slot->bitmap);
        cell.color_w    = slot->bitmap.width;
        cell.color_h    = slot->bitmap.rows;
        if (! atlas.distanceField()) {
            // Plain atlas: the bitmap as it is; the mono cell stays empty.
            cell.w = cell.color_w;
            cell.h = cell.color_h;
            cell.origin_x = -static_cast<float>(slot->bitmap_left);
            cell.origin_y = static_cast<float>(slot->bitmap_top);
            cell.px_scale = strike;
            main_pixels.assign(std::size_t(cell.w) * cell.h * atlas.Bpp(), 0u);
        } else {
            // Distance cell at 32 / strike ppem cell pixels per bitmap pixel, plus the margin,
            // its field from the bitmap's alpha (sub_1401AB9C0).
            const float step = kAtlasEm * strike / layer_ppem;
            cell.color_step   = step;
            cell.color_margin = kAtlasMargin;
            cell.w = static_cast<uint32_t>(static_cast<float>(cell.color_w) * step) + 2u * uint32_t(kAtlasMargin);
            cell.h = static_cast<uint32_t>(static_cast<float>(cell.color_h) * step) + 2u * uint32_t(kAtlasMargin);
            cell.origin_x = kAtlasMargin - static_cast<float>(slot->bitmap_left) * step;
            cell.origin_y = kAtlasMargin + static_cast<float>(slot->bitmap_top) * step;
            cell.px_scale = layer_ppem / kAtlasEm;
            std::vector<uint8_t> coverage(std::size_t(cell.w) * cell.h, 0u);
            for (uint32_t y = 0; y < cell.h; ++y) {
                for (uint32_t x = 0; x < cell.w; ++x) {
                    const long bx = long(std::floor((float(x) + 0.5f - kAtlasMargin) / step));
                    const long by = long(std::floor((float(y) + 0.5f - kAtlasMargin) / step));
                    if (bx < 0 || by < 0 || bx >= long(cell.color_w) || by >= long(cell.color_h)) continue;
                    coverage[std::size_t(y) * cell.w + x] = cell.color_rgba[(std::size_t(by) * cell.color_w + bx) * 4u + 3u];
                }
            }
            const auto field = SignedDistanceField(coverage, cell.w, cell.h, kAtlasMargin);
            main_pixels.assign(std::size_t(cell.w) * cell.h * 4u, 255u);
            for (std::size_t i = 0; i < field.size(); ++i) {
                const uint8_t value = DistanceByte(field[i] / kTextMsdfRange + 0.5f);
                main_pixels[i * 4u + 0u] = main_pixels[i * 4u + 1u] = main_pixels[i * 4u + 2u] = value;
            }
        }
    } else if (! atlas.distanceField()) {
        if (FT_Load_Glyph(face, glyph_index, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) return true;
        const FT_Bitmap& bitmap = face->glyph->bitmap;
        if (bitmap.pixel_mode != FT_PIXEL_MODE_GRAY || bitmap.buffer == nullptr || bitmap.width == 0 ||
            bitmap.rows == 0) {
            return true;
        }
        cell.w = bitmap.width;
        cell.h = bitmap.rows;
        cell.origin_x = -static_cast<float>(face->glyph->bitmap_left);
        cell.origin_y = static_cast<float>(face->glyph->bitmap_top);
        main_pixels.resize(std::size_t(cell.w) * cell.h);
        for (unsigned r = 0; r < bitmap.rows; ++r) {
            std::copy_n(bitmap.buffer + long(r) * bitmap.pitch, bitmap.width, main_pixels.data() + std::size_t(r) * cell.w);
        }
    } else {
        // The outline, 3-channel MSDF with msdfgen's defaults (G-F6).
        msdfgen::FontHandle* font = msdfgen::adoptFreetypeFont(face);
        if (font == nullptr) return true;
        msdfgen::Shape shape;
        const bool     loaded = msdfgen::loadGlyph(shape, font, msdfgen::GlyphIndex(glyph_index),
                                                   msdfgen::FONT_SCALING_EM_NORMALIZED);
        msdfgen::destroyFont(font);
        if (! loaded || shape.contours.empty()) return true;
        shape.normalize();
        // PostScript/CFF (.otf) outlines wind outer contours counter-clockwise, opposite to
        // TrueType; orientContours (sub_140281900 in sub_1401AE080, G-F6) normalises contour
        // winding before colouring and generating the distance field.
        shape.orientContours();
        msdfgen::edgeColoringSimple(shape, 3.0);
        const auto bounds = shape.getBounds();
        if (! (bounds.r > bounds.l) || ! (bounds.t > bounds.b)) return true;
        cell.w = static_cast<uint32_t>((bounds.r - bounds.l) * kAtlasEm) + 2u * uint32_t(kAtlasMargin);
        cell.h = static_cast<uint32_t>((bounds.t - bounds.b) * kAtlasEm) + 2u * uint32_t(kAtlasMargin);
        msdfgen::Bitmap<float, 3> field(int(cell.w), int(cell.h));
        const msdfgen::Vector2 translate(kAtlasMargin / kAtlasEm - bounds.l, kAtlasMargin / kAtlasEm - bounds.b);
        msdfgen::generateMSDF(field, shape, msdfgen::Projection(msdfgen::Vector2(kAtlasEm, kAtlasEm), translate),
                              msdfgen::Range(kTextMsdfRange / kAtlasEm));
        main_pixels.resize(std::size_t(cell.w) * cell.h * 4u);
        for (uint32_t r = 0; r < cell.h; ++r) {
            for (uint32_t c = 0; c < cell.w; ++c) {
                // msdfgen's rows run bottom up; the atlas's top down.
                const float* value = field(int(c), int(cell.h - 1u - r));
                auto*        out   = &main_pixels[(std::size_t(r) * cell.w + c) * 4u];
                out[0] = DistanceByte(value[0]);
                out[1] = DistanceByte(value[1]);
                out[2] = DistanceByte(value[2]);
                out[3] = 255u;
            }
        }
        cell.origin_x = kAtlasMargin - static_cast<float>(bounds.l) * kAtlasEm;
        cell.origin_y = static_cast<float>(cell.h) - (kAtlasMargin - static_cast<float>(bounds.b) * kAtlasEm);
        cell.px_scale = layer_ppem / kAtlasEm;
    }
    if (! atlas.Place(cell.w, cell.h, cell.x, cell.y)) return false;
    const std::size_t bpp  = atlas.Bpp();
    uint8_t*          into = atlas.Writable();
    for (uint32_t r = 0; r < cell.h; ++r) {
        std::copy_n(main_pixels.data() + std::size_t(r) * cell.w * bpp, std::size_t(cell.w) * bpp,
                    into + (std::size_t(cell.y + r) * atlas.side() + cell.x) * bpp);
    }
#ifdef WESCENE_BUILD_TESTS
    ++g_cells_made;
#endif
    atlas.Insert(key, std::move(cell));
    placed = true;
    return true;
}

// A cell of solid ink, for the boxes drawn where no font opens.
const GlyphCell* SolidCell(GlyphAtlas& atlas) {
    if (const auto* held = atlas.Find("box")) return held;
    GlyphCell cell;
    cell.w = cell.h = 3;
    if (! atlas.Place(cell.w, cell.h, cell.x, cell.y)) return nullptr;
    uint8_t* into = atlas.Writable();
    for (uint32_t r = 0; r < 3; ++r) {
        std::fill_n(into + (std::size_t(cell.y + r) * atlas.side() + cell.x) * atlas.Bpp(), 3 * atlas.Bpp(), 255u);
    }
    atlas.Insert("box", std::move(cell));
    return atlas.Find("box");
}

TextLayerLayout MeasureFallbackText(const TextLayerState& state) {
    const auto lines = BuildFallbackLines(state);
    return LayoutOfBlock(state, MeasureTextBlock(lines, FallbackMetrics(state)));
}

// A quad from a rectangle of the card (x right, y down from its top-left) to the layer's plane.
TextGlyphQuad QuadOf(const TextLayerRenderBounds& bounds, float x, float y, float w, float h, float u0,
                     float v0, float u1, float v1) {
    return { .left = bounds.left + x, .bottom = bounds.top - (y + h), .right = bounds.left + x + w,
             .top = bounds.top - y, .u0 = u0, .v0 = v0, .u1 = u1, .v1 = v1 };
}

// The boxes of a text no font opens for, as quads over a solid cell.
TextGlyphBuild BuildBoxGlyphs(const TextLayerState& state) {
    TextGlyphBuild build;
    build.distance_field = TextUsesDistanceField(state);
    build.layout         = MeasureFallbackText(state);
    auto& atlas = AtlasCache::Get().For(std::string(build.distance_field ? "df" : "mono") + "|boxes",
                                        build.distance_field);
    const GlyphCell* solid = SolidCell(atlas);
    build.atlas = atlas.Picture();
    if (state.text.empty() || solid == nullptr) return build;
    const auto  lines   = BuildFallbackLines(state);
    const auto  metrics = FallbackMetrics(state);
    const auto  block   = MeasureTextBlock(lines, metrics);
    const auto  bounds  = TextLayerRenderBoundsForLayout(state, build.layout);
    const auto  padding = CardPadding(state);
    const float side    = static_cast<float>(atlas.side());
    const float u = (static_cast<float>(solid->x) + 1.5f) / side, v = (static_cast<float>(solid->y) + 1.5f) / side;
    const float box_height = std::max(1.0f, metrics.ascender);
    for (std::size_t row = 0; row < lines.size(); ++row) {
        const auto& line     = lines[row];
        const float baseline = padding.y() + block.top + static_cast<float>(row) * block.pitch;
        float       pen      = padding.x() - block.min_x + RowOffset(state, block.widest_row, line.LayoutWidth());
        for (const auto& glyph : line.glyphs) {
            if (glyph.has_ink) {
                const float x0 = std::floor(pen), x1 = std::ceil(pen + glyph.right);
                const float y0 = std::floor(baseline - box_height), y1 = std::ceil(baseline);
                build.glyphs.push_back(QuadOf(bounds, x0, y0, x1 - x0, y1 - y0, u, v, u, v));
            }
            pen += glyph.advance;
        }
    }
    return build;
}

// The key of the atlas a layout's glyphs go into: one per font, size and kind (G-F16). A
// distance-field cell does not depend on the size (32 px to the em), a coverage cell does.
std::string AtlasKey(const TextLayerState& state, const FaceChain& faces, bool distance_field) {
    std::string key = distance_field ? "df|" : "mono|";
    key += faces.key(0);
    if (! distance_field) key += "|" + std::to_string(faces.pointSize(0));
    return key;
}

// Lays the text out and places its glyphs; the caller holds `g_freetype_mutex`.
TextGlyphBuild BuildFreeTypeGlyphs(const TextLayerState& state, FaceChain& faces) {
    TextGlyphBuild build;
    build.distance_field = TextUsesDistanceField(state);
    const auto lines   = BuildFreeTypeLines(state, faces);
    const auto metrics = FaceMetrics(state, faces);
    const auto block   = MeasureTextBlock(lines, metrics);
    build.layout       = LayoutOfBlock(state, block);
    auto& atlas = AtlasCache::Get().For(AtlasKey(state, faces, build.distance_field), build.distance_field);

    const auto key_of = [&](const GlyphRun& glyph) {
        return faces.key(glyph.face) + "#" + std::to_string(faces.pointSize(glyph.face)) + "#" +
               std::to_string(glyph.glyph_index);
    };
    // Every inked glyph gets its cell; an atlas full at 4096 is emptied and the text laid into it
    // once more (sub_1401B0410, G-F16).
    for (int attempt = 0; attempt < 2; ++attempt) {
        bool full = false;
        for (const auto& line : lines) {
            for (const auto& glyph : line.glyphs) {
                if (! glyph.has_ink) continue;
                const auto key = key_of(glyph);
                if (atlas.Find(key) != nullptr) continue;
                bool placed = false;
                if (! MakeCell(atlas, faces, glyph.face, glyph.glyph_index, key, placed)) full = true;
            }
        }
        if (! full || attempt == 1) break;
        atlas.Reset();
    }

    const auto  bounds  = TextLayerRenderBoundsForLayout(state, build.layout);
    const auto  padding = CardPadding(state);
    const float side    = static_cast<float>(atlas.side());
    for (std::size_t row = 0; row < lines.size(); ++row) {
        const auto& line     = lines[row];
        const float baseline = padding.y() + block.top + static_cast<float>(row) * block.pitch;
        float       pen      = padding.x() - block.min_x + RowOffset(state, block.widest_row, line.LayoutWidth());
        for (const auto& glyph : line.glyphs) {
            const GlyphCell* cell = glyph.has_ink ? atlas.Find(key_of(glyph)) : nullptr;
            if (cell != nullptr) {
                const float k = cell->px_scale;
                float x = 0.0f, y = 0.0f;
                if (build.distance_field) {
                    x = pen + glyph.x_offset - cell->origin_x * k;
                    y = baseline - glyph.y_offset - cell->origin_y * k;
                } else {
                    // A coverage glyph sits on whole pixels, as FreeType draws it.
                    x = std::round(pen) + glyph.x_offset - cell->origin_x * k;
                    y = std::round(baseline) - glyph.y_offset - cell->origin_y * k;
                }
                const auto quad = QuadOf(bounds, x, y, static_cast<float>(cell->w) * k, static_cast<float>(cell->h) * k,
                                         static_cast<float>(cell->x) / side, static_cast<float>(cell->y) / side,
                                         static_cast<float>(cell->x + cell->w) / side,
                                         static_cast<float>(cell->y + cell->h) / side);
                (cell->color ? build.color_glyphs : build.glyphs).push_back(quad);
            }
            pen += glyph.advance;
        }
    }
    build.atlas       = atlas.Picture();
    build.color_atlas = atlas.ColorPicture();
    return build;
}

// The font is opened once for both answers.
TextGlyphBuild BuildTextGlyphsLocked(const TextLayerState& state) {
    FaceChain faces(state);
    if (faces.primary() == nullptr) return BuildBoxGlyphs(state);
    return BuildFreeTypeGlyphs(state, faces);
}

std::optional<TextLayerLayout> MeasureFreeTypeText(const TextLayerState& state) {
    FaceChain faces(state);
    if (faces.primary() == nullptr) return std::nullopt;

    const auto lines   = BuildFreeTypeLines(state, faces);
    const auto metrics = FaceMetrics(state, faces);
    return LayoutOfBlock(state, MeasureTextBlock(lines, metrics));
}

} // namespace

bool TextStyleActive(const TextStyle& style) { return style.outline || style.blur || style.drop_shadow; }

bool TextUsesDistanceField(const TextLayerState& state) { return state.msdf || TextStyleActive(state.style); }

TextStyleUniforms TextStyleRenderVars(const TextStyle& style, float point_size) {
    TextStyleUniforms out;
    const float k = (kAtlasEm / ClampedPointSize(point_size)) * kAtlasUnitScale;
    // A switch that is off sends 0; one that is on floors its size (sub_140256F20, G-F4).
    const float outline = style.outline ? std::max(FiniteOr(style.outline_thickness, 1.0f), 1.0f) : 0.0f;
    const float blur    = style.blur ? std::max(FiniteOr(style.blur_size, 0.01f), 0.01f) : 0.0f;
    const float shadow  = style.drop_shadow ? std::max(FiniteOr(style.shadow_size, 0.01f), 0.01f) : 0.0f;
    const float ox = style.drop_shadow ? FiniteOr(style.shadow_offset.x(), 0.0f) : 0.0f;
    const float oy = style.drop_shadow ? FiniteOr(style.shadow_offset.y(), 0.0f) : 0.0f;
    out.outline = outline >= 1.0f;
    out.blur    = blur > 0.0f;
    out.shadow  = shadow > 0.0f || ox * ox + oy * oy > 1.1920929e-07f;
    float outline_atlas = std::min(k * outline, kOutlineCap);
    const float blur_atlas = std::min(k * blur, kBlurCap);
    if (outline_atlas + blur_atlas > kOutlineCap) outline_atlas = std::max(kOutlineCap - blur_atlas, 0.0f);
    out.rv0 = { kTextMsdfRange, outline_atlas, blur_atlas, std::min(k * shadow, kShadowCap) };
    out.rv1 = { FiniteOr(style.outline_color.x(), 0.0f), FiniteOr(style.outline_color.y(), 0.0f),
                FiniteOr(style.outline_color.z(), 0.0f), std::min(k * ox, kShadowOffsetCap) };
    out.rv2 = { FiniteOr(style.shadow_color.x(), 0.0f), FiniteOr(style.shadow_color.y(), 0.0f),
                FiniteOr(style.shadow_color.z(), 0.0f), std::min(k * oy, kShadowOffsetCap) };
    out.rv3 = { FiniteOr(style.shadow_opacity, 1.0f), 0.0f, 0.0f, 0.0f };
    return out;
}

TextGlyphBuild BuildTextGlyphs(const TextLayerState& state) {
#ifdef WESCENE_BUILD_TESTS
    ++g_measurement_count;
#endif
    const std::lock_guard lock { g_freetype_mutex };
    return BuildTextGlyphsLocked(state);
}

std::string TextAtlasName(std::string_view layer_key) {
    return "runtime/text/" + std::string(layer_key) + "/atlas";
}

std::string TextColorAtlasName(std::string_view layer_key) {
    return "runtime/text/" + std::string(layer_key) + "/atlas_color";
}

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

linalg::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding) {
    const float pixels = PointSizeToPixels(point_size);
    const float margin = std::isfinite(padding) && padding > 0.0f ? padding : 0.0f;
    std::size_t longest = 1, current = 0, lines = 1;
    for (const char byte : text) {
        if (byte == '\n') {
            longest = std::max(longest, current);
            current = 0;
            ++lines;
        } else if ((static_cast<unsigned char>(byte) & 0xC0u) != 0x80u) {
            ++current;
        }
    }
    longest = std::max(longest, current);
    return { static_cast<float>(longest) * std::max(1.0f, 0.6f * pixels) + 2.0f * margin,
             static_cast<float>(lines) * std::max(1.0f, 1.2f * pixels) + 2.0f * margin };
}

TextLayerLayout MeasureTextLayerLayout(const TextLayerState& state) {
#ifdef WESCENE_BUILD_TESTS
    ++g_measurement_count;
#endif
    {
        const std::lock_guard lock { g_freetype_mutex };
        if (auto layout = MeasureFreeTypeText(state)) return *layout;
    }
    // No face opens: boxes, laid out with the same rules and no font lock.
    return MeasureFallbackText(state);
}

linalg::Vector2f MeasureTextLayerSize(const TextLayerState& state) {
    return MeasureTextLayerLayout(state).card;
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

linalg::Vector2f TextScreenAnchorOffset(TextScreenAnchor anchor, const PresentedMargins& margins) {
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
    return linalg::Vector2f::Zero();
}

TextLayerRenderBounds TextLayerRenderBoundsForLayout(const TextLayerState& state,
                                                     const TextLayerLayout& layout) {
    // The card is centred on the layout's centre; there is no room around it for the style,
    // whose reach the distance-field cells' margin holds (G-F6).
    const linalg::Vector2f half = layout.card * 0.5f;
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
        .size   = linalg::Vector2f(bounds.right - bounds.left, bounds.top - bounds.bottom),
        .center = linalg::Vector2f((bounds.left + bounds.right) * 0.5f,
                                  (bounds.bottom + bounds.top) * 0.5f),
    };
}

std::array<int32_t, 2> TextCardTexelExtent(linalg::Vector2f card) {
    return {
        std::max(4, static_cast<int32_t>(std::max(1.0f, card.x()))),
        std::max(4, static_cast<int32_t>(std::max(1.0f, card.y()))),
    };
}

TextLayerRenderFrame TextLayerEffectFrame(const TextLayerRenderFrame& card) {
    const auto texels = TextCardTexelExtent(card.size);
    const linalg::Vector2f size(static_cast<float>(std::min(texels[0], kTextEffectExtentLimit)),
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

#ifdef WESCENE_BUILD_TESTS
namespace
{
// The quads of a build drawn on the CPU as the plain font shader draws them.
void ComposeGlyphsForTests(const TextLayerState& state, const TextGlyphBuild& build, uint32_t width,
                           uint32_t height, std::vector<uint8_t>& rgba, bool white) {
    const auto  color       = white ? std::array<uint8_t, 4> { 255, 255, 255, 255 } : TextColorBytes(state);
    const float alpha_scale = static_cast<float>(color[3]) / 255.0f;
    const std::size_t texels = std::min(rgba.size() / 4u, static_cast<std::size_t>(width) * height);
    for (std::size_t texel = 0; texel < texels; ++texel) {
        rgba[texel * 4u + 0u] = color[0];
        rgba[texel * 4u + 1u] = color[1];
        rgba[texel * 4u + 2u] = color[2];
    }
    const auto bounds = TextLayerRenderBoundsForLayout(state, build.layout);
    const auto draw = [&](const TextGlyphQuad& quad, const TextAtlasPicture& atlas, bool colour) {
        if (atlas.bytes == nullptr || atlas.width == 0) return;
        const long x0 = std::lround(quad.left - bounds.left), y0 = std::lround(bounds.top - quad.top);
        const long w  = std::lround(quad.right - quad.left), h = std::lround(quad.top - quad.bottom);
        const float au0 = quad.u0 * float(atlas.width), av0 = quad.v0 * float(atlas.height);
        const float aw = (quad.u1 - quad.u0) * float(atlas.width), ah = (quad.v1 - quad.v0) * float(atlas.height);
        const std::size_t bpp = atlas.rgba ? 4u : 1u;
        for (long y = 0; y < h; ++y) {
            for (long x = 0; x < w; ++x) {
                const long tx = x0 + x, ty = y0 + y;
                if (tx < 0 || ty < 0 || tx >= long(width) || ty >= long(height)) continue;
                const long ax = std::min<long>(long(atlas.width) - 1, long(au0 + (float(x) + 0.5f) * aw / float(w)));
                const long ay = std::min<long>(long(atlas.height) - 1, long(av0 + (float(y) + 0.5f) * ah / float(h)));
                const uint8_t* texel = atlas.bytes->data() + (std::size_t(ay) * atlas.width + std::size_t(ax)) * bpp;
                uint8_t* out = &rgba[(std::size_t(ty) * width + std::size_t(tx)) * 4u];
                if (colour) {
                    if (texel[3] == 0) continue;
                    std::copy_n(texel, 3, out);
                    out[3] = std::max(out[3], static_cast<uint8_t>(std::lround(texel[3] * alpha_scale)));
                    continue;
                }
                // A distance texel covers when its median is past the edge.
                const uint8_t coverage = ! atlas.rgba ? texel[0]
                                         : std::max(std::min(texel[0], texel[1]),
                                                    std::min(std::max(texel[0], texel[1]), texel[2])) >= 128 ? 255 : 0;
                out[3] = std::max(out[3], static_cast<uint8_t>(std::lround(float(coverage) * alpha_scale)));
            }
        }
    };
    for (const auto& quad : build.glyphs) draw(quad, build.atlas, false);
    for (const auto& quad : build.color_glyphs) draw(quad, build.color_atlas, true);
}
} // namespace

void RasterizeTextGlyphsForTests(const TextLayerState& state, uint32_t width, uint32_t height,
                                 std::vector<uint8_t>& rgba) {
    ComposeGlyphsForTests(state, BuildTextGlyphs(state), width, height, rgba, false);
}

void ResetTextAtlasesForTests() {
    const std::lock_guard lock { g_freetype_mutex };
    AtlasCache::Get().Clear();
    g_cells_made.store(0);
}

uint64_t TextGlyphCellsMadeForTests() {
    return g_cells_made.load();
}
#endif

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
    TextGlyphBuild build;
    {
        const std::lock_guard lock { g_freetype_mutex };
        build = BuildBoxGlyphs(state);
    }
    ComposeGlyphsForTests(state, build, width, height, rgba, true);
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

std::vector<TextGlyphPlacementForTests> TextLayerGlyphsForTests(const TextLayerState& state) {
    const std::lock_guard lock { g_freetype_mutex };
    std::vector<TextGlyphPlacementForTests> out;
    FaceChain faces(state);
    if (faces.primary() == nullptr) return out;
    const auto lines = BuildFreeTypeLines(state, faces);
    for (std::size_t row = 0; row < lines.size(); ++row) {
        float pen = 0.0f;
        for (const auto& glyph : lines[row].glyphs) {
            out.push_back({ .face = glyph.face, .glyph_index = glyph.glyph_index, .codepoint = glyph.codepoint,
                            .source = glyph.source, .row = static_cast<uint32_t>(row), .pen = pen });
            pen += glyph.advance;
        }
    }
    return out;
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
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::SetAlignment(std::string horizontal, std::string vertical) {
    if (m_state.horizontal_align == horizontal && m_state.vertical_align == vertical) return;
    m_state.horizontal_align = std::move(horizontal);
    m_state.vertical_align   = std::move(vertical);
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::SetPaddingApplies(bool applies) {
    if (m_state.padding_applies == applies) return;
    m_state.padding_applies = applies;
    m_state.padding         = applies ? m_state.authored_padding : linalg::Vector2f::Zero();
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::RequestLayout() {
    m_state.dirty = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

void TextLayer::SetPadding(linalg::Vector2f padding) {
    if (!padding.allFinite() || (m_state.authored_padding.array() == padding.array()).all()) return;
    m_state.authored_padding = padding;
    if (m_state.padding_applies) {
        m_state.padding = padding;
        RequestLayout();
    }
}

void TextLayer::SetSpacing(linalg::Vector2f spacing) {
    if (!spacing.allFinite() || (m_state.spacing.array() == spacing.array()).all()) return;
    m_state.spacing = spacing;
    RequestLayout();
}

void TextLayer::SetLimits(float width, int32_t rows, bool limit_width, bool limit_rows,
                          bool ellipsis, bool block_align) {
    if (!std::isfinite(width)) return;
    if (m_state.max_width == width && m_state.max_rows == rows && m_state.limit_width == limit_width &&
        m_state.limit_rows == limit_rows && m_state.use_ellipsis == ellipsis && m_state.block_align == block_align) return;
    m_state.max_width = width;
    m_state.max_rows = rows;
    m_state.limit_width = limit_width;
    m_state.limit_rows = limit_rows;
    m_state.use_ellipsis = ellipsis;
    m_state.block_align = block_align;
    RequestLayout();
}

void TextLayer::SetDistanceField(bool enabled) {
    if (m_state.msdf == enabled) return;
    const bool before = TextUsesDistanceField(m_state);
    m_state.msdf = enabled;
    if (before != TextUsesDistanceField(m_state)) RequestLayout();
}

void TextLayer::SetStyle(const TextStyle& style) {
    const bool before = TextUsesDistanceField(m_state);
    m_state.style = style;
    if (before != TextUsesDistanceField(m_state)) RequestLayout();
}

void TextLayer::SetBackground(bool opaque, linalg::Vector3f color, float brightness) {
    m_state.opaque_background = opaque;
    m_state.background_color = color;
    m_state.background_brightness = brightness;
}

void TextLayer::SetStyleUniformValues(const TextStyle& style) {
    TextStyle next   = style;
    next.outline     = m_state.style.outline;
    next.blur        = m_state.style.blur;
    next.drop_shadow = m_state.style.drop_shadow;
    m_state.style    = next;
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

TextLayerRenderBounds TextLayer::renderBounds() const {
    return TextLayerRenderBoundsForLayout(m_state, m_layout);
}

void TextLayer::Relayout() {
    m_layout               = MeasureTextLayerLayout(m_state);
    m_state.layout_pending = false;
}

void TextLayer::EnsureCacheIdentity() {
    if (! m_state.texture_cache_key.empty()) return;
    // Every field that changes the picture, joined so that no field runs into the next.
    // Alignment, colour and the style's values are left out: the shaders and placement take those.
    std::string identity;
    const auto  add = [&identity](const std::string& field) {
        identity += field;
        identity += '\x1f';
    };
    const auto number = [](double value) { return std::to_string(value); };
    const auto& style = m_state.style;
    add(m_state.layer_key);
    add(m_state.text);
    add(m_state.font_key);
    add(m_state.resolved_font_kind);
    add(m_state.resolved_font_identity);
    add(m_state.resolved_font_path);
    add(m_state.resolved_font_face);
    add(FontFitIdentity(m_state.resolved_font_fit));
    add(number(m_state.point_size));
    add(number(m_state.max_width));
    add(std::to_string(m_state.max_rows));
    add(std::string(m_state.limit_width ? "w" : "-") + (m_state.limit_rows ? "r" : "-") +
        (m_state.use_ellipsis ? "e" : "-") + (m_state.block_align ? "b" : "-") +
        (style.outline ? "o" : "-") + (style.blur ? "u" : "-") + (style.drop_shadow ? "s" : "-") +
        (m_state.msdf ? "m" : "-"));
    add(number(m_state.padding.x()) + "," + number(m_state.padding.y()));
    add(number(m_state.authored_padding.x()) + "," + number(m_state.authored_padding.y()));
    add(number(m_state.spacing.x()) + "," + number(m_state.spacing.y()));
    // The style's sizes, opacity and offset are the font shader's uniforms, not the glyphs'.
    m_state.texture_cache_key = "textcache:" + std::to_string(std::hash<std::string> {}(identity));
}

void TextLayer::MarkCacheDirty() {
    m_state.cache_dirty = true;
    m_state.full_dirty  = true;
    ++m_state.cache_revision;
}

} // namespace wallpaper
