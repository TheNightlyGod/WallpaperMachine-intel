// The start of a VP9 frame (the uncompressed header of the VP9 bitstream
// specification): enough to learn the profile, bit depth, colour space, chroma
// subsampling and picture size from a key frame without decoding it. WebM does
// not carry a `vpcC` record, so whoever builds a decoder's format description
// needs these facts from the first key frame.
#pragma once

#include "Media/Error.hpp"

#include <cstddef>
#include <cstdint>

namespace wallpaper::media
{

struct Vp9FrameHeader {
    std::uint8_t  profile { 0 };       // 0 to 3
    bool          showExistingFrame { false };
    bool          keyFrame { false };
    bool          intraOnly { false };
    bool          showFrame { false };
    bool          errorResilient { false };
    /// True when the header carried a colour configuration (a key frame, or an
    /// intra-only frame of profile 1 or higher); the fields below are valid then.
    bool          hasColourConfig { false };
    std::uint8_t  bitDepth { 8 };      // 8, 10 or 12
    /// The VP9 color_space code: 0 unknown, 1 BT.601, 2 BT.709, 3 SMPTE-170,
    /// 4 SMPTE-240, 5 BT.2020, 6 reserved, 7 sRGB/RGB.
    std::uint8_t  colourSpace { 0 };
    bool          fullRange { false };
    std::uint8_t  subsamplingX { 1 };
    std::uint8_t  subsamplingY { 1 };
    /// The coded picture size; 0 unless the frame carried one (key and intra-only frames).
    std::uint32_t width { 0 };
    std::uint32_t height { 0 };
};

/// Parses the uncompressed header at the start of one VP9 frame (`data` is the
/// frame, or at least its first bytes: 24 are enough for every key frame). Fails
/// with `Corrupt` on a bad frame marker or sync code, a reserved bit that is set,
/// or an invalid combination, and with `Truncated` when `size` ends inside the
/// header. An inter frame succeeds with `hasColourConfig` false.
bool ParseVp9UncompressedHeader(const std::uint8_t* data, std::size_t size, Vp9FrameHeader* header,
                                Error* error);

} // namespace wallpaper::media
