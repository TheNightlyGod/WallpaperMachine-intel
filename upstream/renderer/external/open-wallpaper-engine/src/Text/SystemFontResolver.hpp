#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace wallpaper
{

/// The vertical metrics of a font, in its own units: what a text layer's rows are set
/// in. Wallpaper Engine reads them from the font it draws with, which for a Windows
/// font this machine lacks is not the font that stands in for it here.
struct FontLineMetrics {
    int32_t units_per_em { 0 };
    int32_t ascender { 0 };
    /// A distance below the baseline, so not negative.
    int32_t descender { 0 };
    int32_t line_gap { 0 };

    bool operator==(const FontLineMetrics&) const = default;
};

/// How an installed face stands in for a font the machine does not have: the glyphs
/// are measured and drawn at the layer's point size times `size_adjust`, which gives
/// them the advances the real font has, and the rows are set in `line_metrics`
/// instead of the face's own, so a card and the place the text lies in it come out as
/// they do in the real font. The default is a face that is what it says it is.
struct SystemFontFit {
    float                          size_adjust { 1.0f };
    std::optional<FontLineMetrics> line_metrics;

    bool operator==(const SystemFontFit&) const = default;
};

/// An installed face: its file, and the name the system gives it. A font file can
/// hold several faces (`PingFang.ttc` holds the Hong Kong, Macau, Taiwan and
/// Simplified Chinese cuts of the font, `Songti.ttc` its four weights), and the
/// name is what tells them apart: the face to open is the one that has it.
struct SystemFontFace {
    std::string path;
    /// The PostScript name, empty where the platform does not say.
    std::string postscript_name;
    /// What sets the face apart from the font it stands for.
    SystemFontFit fit;
};

/// The font a text object without a `font` key has, and the one a font that cannot be
/// loaded is drawn in.
inline constexpr std::string_view kDefaultSceneFontKey = "systemfont_arial";

/// Whether `key` is one of the eight font keys Wallpaper Engine's text object honours:
/// `systemfont_arial`, `_calibri`, `_cambria`, `_comicsans`, `_consolas`, `_sansserif`,
/// `_segoe` and `_verdana`, each the whole string and in lower case. Every other string
/// is a path to a font file, which a wallpaper ships or does not have.
bool IsSceneFontKey(std::string_view key);

/// The face a scene font key draws with: the installed twin of a font Windows ships
/// (Arial, Comic Sans MS, Microsoft Sans Serif and Verdana are on every Mac) or the
/// closest installed face, fitted to the real font's advances and line metrics
/// (Consolas, Cambria, Segoe UI and Calibri are not). A key that is not one of the
/// eight, or whose font is not installed, is Arial, as a font Wallpaper Engine cannot
/// load is. Empty only where not even Arial is installed.
SystemFontFace ResolveSceneFont(std::string_view key);

/// The installed face of a font family, by the family's name as the system knows it
/// (`PingFang SC`, `Helvetica`), and nothing for a family that is not installed.
SystemFontFace ResolveInstalledFamily(std::string_view family);

#ifdef WESCENE_BUILD_TESTS
/// Replaces what finds a family for the tests (an empty function puts the system's back)
/// and forgets every family found so far.
void SetInstalledFamilyLookupForTests(std::function<SystemFontFace(std::string_view)> lookup);
/// Makes the families that were not found due to be asked for again, as if
/// the retry time had passed.
void ExpireMissingInstalledFamiliesForTests();
#endif

} // namespace wallpaper
