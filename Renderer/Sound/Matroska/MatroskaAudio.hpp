// The sound of a Matroska or WebM file's audio track as PCM, through the same
// `PcmDecoder` interface the scene sounds use: interleaved 32-bit float frames at
// the track's own channel count and sample rate, back to the first frame on
// `rewind()`.
//
// Opus, AAC and MP3 packets are decoded one at a time by an AudioToolbox converter.
// Vorbis has no system decoder, so its packets are put into an in-memory Ogg stream
// (`OggVorbisFraming`) that the project's stb_vorbis decoder reads. Nothing here plays
// or opens an audio device.
#pragma once

#include "Media/Matroska/MatroskaReader.hpp"
#include "Sound/PcmDecoder.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace wallpaper::sound
{

struct MatroskaAudioLimits {
    /// A Vorbis track is re-framed in memory; one whose packets add up to more than
    /// this is not decoded (its video plays silently), the same bound scene sounds have.
    std::uint64_t maxVorbisBytes { 64ULL << 20 };
};

/// Opens the audio track `trackIndex` (an index into `reader->tracks()`, an audio track
/// the reader indexed) and returns a decoder over it, or null with the reason in
/// `*error`: a codec the system cannot decode, a channel layout this does not handle
/// (Opus with a channel mapping above stereo), a damaged codec record, or a track with
/// no packets. The decoder keeps the reader alive and reads packets from its source on
/// demand, from whichever thread calls `read`; one decoder is not safe to use from two
/// threads at once.
///
/// Opus is trimmed to what a player shows: the pre-skip is dropped from the start and
/// a block's DiscardPadding from its end, and the header's output gain is applied.
std::unique_ptr<PcmDecoder> OpenMatroskaAudio(std::shared_ptr<media::MatroskaReader> reader, std::size_t trackIndex,
                                              std::string* error, const MatroskaAudioLimits& limits = {});

/// How many 48 kHz samples an Opus packet holds, from its table-of-contents byte
/// and, for a packet of several frames, its frame count (RFC 6716 section 3.1);
/// 0 for a packet that is empty or cannot be one.
std::uint32_t OpusPacketFrames(const std::uint8_t* packet, std::size_t size);

} // namespace wallpaper::sound
