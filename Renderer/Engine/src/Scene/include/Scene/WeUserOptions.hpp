#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <string>

namespace wallpaper
{

/// The per-wallpaper options Wallpaper Engine injects into every wallpaper's
/// properties (plan decision I2; wallpaper64.exe sub_140104B60 builds them,
/// sub_140115280 / sub_140181F30 apply them to a scene). Values are as stored:
/// sliders 0..100 with 50 unchanged, `lut_strength` 0..100, `playback_rate`
/// 10..200 percent. The defaults are Wallpaper Engine's
/// (artifacts/we-parity/decompiles/H-P0-2.md), which change nothing.
struct WeUserOptions {
    bool        color_enabled { false };  // wec_e
    float       brightness { 50.0f };     // wec_brs
    float       contrast { 50.0f };       // wec_con
    float       saturation { 50.0f };     // wec_sa
    float       hue { 50.0f };            // wec_hue
    std::string lut;                      // wcc_v: stem under materials/lut, "" = none
    float       lut_strength { 100.0f };  // wcc_amt
    bool        flip_horizontal { false }; // alignmentfliph
    bool        mouse_parallax { true };  // cameraparallax
    float       playback_rate { 100.0f }; // rate

    bool operator==(const WeUserOptions&) const = default;
};

/// What decides how the `ccsimple` pass is built: its combos and its LUT. A
/// change of shape loads the scene again; anything else is a live update.
struct CcsimpleShape {
    bool        col { false };
    bool        lut { false };
    std::string lut_name;

    bool operator==(const CcsimpleShape&) const = default;
};

/// `params` of `ccsimple`, Wallpaper Engine's sub_140181F30 (asm @0x140182d85):
/// (pow(brs/50, 2), pow(con/50, 0.5), pow(sa/50, 0.5), hue/100 - 0.5).
inline std::array<float, 4> CcsimpleParams(const WeUserOptions& options)
{
    const float brightness = options.brightness / 50.0f;
    const float contrast   = options.contrast / 50.0f;
    const float saturation = options.saturation / 50.0f;
    return { std::pow(brightness, 2.0f), std::pow(contrast, 0.5f), std::pow(saturation, 0.5f),
             options.hue / 100.0f - 0.5f };
}

/// `lutparams` of `ccsimple`: the filter strength as a fraction.
inline float CcsimpleLutParams(const WeUserOptions& options) { return options.lut_strength / 100.0f; }

/// sub_140181F30: COL is on when the colour options are on and any value moved
/// (exact float compares, so a slider at 50 is the identity); LUT is on when a
/// filter is named and its strength is above zero.
inline CcsimpleShape CcsimpleShapeOf(const WeUserOptions& options)
{
    CcsimpleShape shape;
    shape.col = options.color_enabled &&
                (options.contrast / 50.0f != 1.0f || options.brightness / 50.0f != 1.0f ||
                 options.saturation / 50.0f != 1.0f || options.hue / 100.0f - 0.5f != 0.0f);
    shape.lut = ! options.lut.empty() && CcsimpleLutParams(options) > 0.0f;
    if (shape.lut) shape.lut_name = options.lut;
    return shape;
}

/// The scene clock multiplier the `rate` option gives a scene: sub_140115280
/// stores fmaxf(rate / 100, 0.1), which the frame step scales the scene's time by.
inline float ScenePlaybackRate(const WeUserOptions& options)
{
    const float rate = options.playback_rate / 100.0f;
    return std::isfinite(rate) ? std::max(rate, 0.1f) : 1.0f;
}

} // namespace wallpaper
