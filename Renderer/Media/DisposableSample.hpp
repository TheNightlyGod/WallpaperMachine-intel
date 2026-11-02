// Whether a compressed picture is one no other picture refers to, read from the
// sample's own NAL unit headers without decoding anything. A player that has
// fallen behind its clock can leave such a picture undecoded: the pictures after
// it decode exactly as they would have, and only it is missing from the screen.
#pragma once

#include "Media/VideoTypes.hpp"

#include <cstddef>
#include <cstdint>

namespace wallpaper::media
{

/// True when `data` (one sample of the stream `info` describes, as length-prefixed
/// NAL units) is a picture nothing else refers to:
///
/// - H.264 (`avcC` record): every slice has `nal_ref_idc` 0 and is not an IDR
///   slice;
/// - HEVC (`hvcC` record): every slice is a sub-layer non-reference picture
///   (`TRAIL_N`, `TSA_N`, `STSA_N`, `RADL_N`, `RASL_N` or a reserved `_N` type)
///   of the stream's highest temporal sub-layer, which the record states. A
///   picture of a lower sub-layer may still be referred to by a higher one.
///
/// Besides its slices, such a sample may carry only access unit delimiters, SEI
/// and filler data: one carrying parameter sets, an end of sequence or anything
/// else is kept. Every other codec, a record that does not state the NAL length
/// size (or, for HEVC, the number of temporal sub-layers), a sample with no slice
/// and a sample whose lengths do not add up are false: when in doubt, decode.
bool IsDisposableSample(const VideoStreamInfo& info, const std::uint8_t* data, std::size_t size);

} // namespace wallpaper::media
