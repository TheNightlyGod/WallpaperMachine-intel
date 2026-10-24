// What an AV1 sequence header says about colour, read without decoding. The
// `av1C` record does not state the sample range (only bit depth and chroma),
// and a container may carry no `colr` box, so a decoder that must choose
// between video-range and full-range output reads it from the sequence header
// OBU the record (or the first temporal unit) carries. Written from the AV1
// bitstream specification (sequence_header_obu and color_config).
#pragma once

#include <cstddef>
#include <cstdint>

namespace wallpaper::media
{

struct Av1SequenceColour {
    std::uint8_t  profile { 0 };
    std::uint8_t  bitDepth { 8 };
    bool          monochrome { false };
    bool          fullRange { false };
    bool          hasColourDescription { false };
    std::uint8_t  primaries { 2 };
    std::uint8_t  transfer { 2 };
    std::uint8_t  matrix { 2 };
};

/// Scans `obus` (a run of OBUs with size fields, the layout of `av1C`'s
/// configOBUs and of a temporal unit) for the first sequence header and reads
/// its colour configuration into `*colour`. Returns false when there is no
/// sequence header in the bytes or it is truncated or malformed.
bool ReadAv1SequenceColour(const std::uint8_t* obus, std::size_t size, Av1SequenceColour* colour);

} // namespace wallpaper::media
