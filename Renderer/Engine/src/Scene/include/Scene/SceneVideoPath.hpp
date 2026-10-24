#pragma once

#include <cstdint>

namespace wallpaper
{

/// How one scene's video textures reached the shaders that sample them.
///
/// A report, never a request. It lives here rather than beside the Metal
/// renderer because the wallpaper that publishes it and the host binding that
/// reads it both sit below that renderer, and two enumerations with the same
/// meaning would be two definitions that can drift.
enum class SceneVideoPath : uint8_t
{
    /// Nothing has been imported yet, the scene binds no video, or it is drawn
    /// by a backend with only one video path.
    None = 0,
    /// A BGRA frame, imported zero-copy and sampled as one image.
    Bgra,
    /// NV12 planes, sampled directly by every consumer. No colour conversion
    /// was encoded and no conversion destination exists.
    Nv12Direct,
    /// NV12 converted once into one BGRA image, which every consumer samples.
    Nv12Converted,
    /// NV12 with both: the planes for the consumers that can read them and one
    /// shared conversion for the consumers that cannot. Also what a scene whose
    /// video textures took different paths reports.
    Nv12Mixed,
    /// NV12 converted, exactly as `Nv12Converted`, while the optional direct
    /// program for this content is still being prepared.
    ///
    /// The frame took the converting path and the wallpaper is playing
    /// normally; the only extra thing this says is that something is still
    /// coming. A scene whose variant is refused, or for which none applies,
    /// reports `Nv12Converted` and stays there.
    Nv12ConvertedPreparing,
    /// 10-bit video (P010, `x420`) converted once into one BGRA image, which
    /// every consumer samples: an HDR picture tone mapped to SDR in linear light,
    /// or an SDR one carried over as it is. The planes are never sampled
    /// directly, so a layer whose shader could read them still reads the image.
    Yuv10Converted,
};

/// The name the diagnostics surface uses for one path.
[[nodiscard]] inline const char* SceneVideoPathName(SceneVideoPath path)
{
    switch (path) {
    case SceneVideoPath::Bgra: return "bgra";
    case SceneVideoPath::Nv12Direct: return "nv12_direct";
    case SceneVideoPath::Nv12Converted: return "nv12_converted";
    case SceneVideoPath::Nv12Mixed: return "nv12_mixed";
    case SceneVideoPath::Nv12ConvertedPreparing: return "nv12_converted_preparing";
    case SceneVideoPath::Yuv10Converted: return "yuv10_converted";
    case SceneVideoPath::None: break;
    }
    return "none";
}

} // namespace wallpaper
