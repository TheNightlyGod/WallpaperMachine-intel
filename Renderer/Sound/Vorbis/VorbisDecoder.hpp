// Ogg Vorbis decoding with the vendored public-domain stb_vorbis (the system has
// no Vorbis decoder). The whole file is read into memory, which is fine for a
// scene's sounds, and decoded with the pull API.
#pragma once

#include "Media/ByteSource.hpp"
#include "Sound/PcmDecoder.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper::sound
{

/// Opens an Ogg Vorbis file and returns a decoder over it, or null with the
/// reason in `*error`: not Ogg, not Vorbis (an Opus or FLAC stream in Ogg), a
/// setup header that is cut off or damaged, or a file past the size limit.
/// The decoder returns exactly the frames the last Ogg page's granule position
/// promises, so a loop has no extra silence at the seam. A file cut off in its
/// audio plays what is there and ends.
std::unique_ptr<PcmDecoder> OpenVorbisDecoder(const std::shared_ptr<media::ByteSource>& source,
                                              std::string*                              error);

/// For each output channel of a file with `channels` Vorbis channels, the Vorbis
/// channel that goes there, so frames come out in the same order as WAV and the
/// rest of the pipeline expects (front left, front right, centre, low
/// frequency, then the surrounds). Vorbis orders 3 to 8 channels differently
/// (left, centre, right, ..., low frequency last). Empty when the order is
/// already the same (1, 2 and 4 channels) or unknown.
std::vector<int> VorbisToNativeOrder(std::uint32_t channels);

} // namespace wallpaper::sound
