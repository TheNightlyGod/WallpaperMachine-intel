// What a codec configuration record says about the stream, read without
// decoding anything: bit depth, and for VP9 the colour description. The records
// themselves stay raw bytes in VideoStreamInfo::codecConfig; these are only the
// few facts a reader surfaces beside them.
#pragma once

#include "Media/VideoTypes.hpp"

#include <cstddef>
#include <cstdint>

namespace wallpaper::media
{

/// Reads the facts out of `config`, the payload of a configuration record of
/// type `configFourcc` ('avcC', 'hvcC', 'av1C' or 'vpcC'; others are ignored and
/// succeed). Sets `*bitDepth` when the record states or implies it (left alone
/// otherwise) and `*colour` when the record carries colour codes (vpcC version 1).
/// Returns false when the record is too short to be of its type, so the caller
/// can refuse the file instead of passing a broken record to a decoder.
bool SummarizeCodecConfig(std::uint32_t configFourcc, const std::uint8_t* config, std::size_t size,
                          std::uint8_t* bitDepth, ColourDescription* colour);

} // namespace wallpaper::media
