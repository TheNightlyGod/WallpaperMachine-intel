// Decoding with AudioToolbox: WAV, AIFF, CAF, MP3, FLAC, AAC and the other
// formats the system's AudioFile and ExtAudioFile know, read through a
// ByteSource (a file, or a sound embedded in a scene package) instead of a path.
// Not part of the pure readers: this one needs Apple's frameworks, so it is only
// built on macOS.
#pragma once

#include "Media/ByteSource.hpp"
#include "Sound/PcmDecoder.hpp"

#include <memory>
#include <string>

namespace wallpaper::sound
{

/// Opens the audio in `source` and returns a decoder over it, or null with the
/// reason in `*error` when the system cannot decode it. With `audioOptional`, a
/// container that is understood but has no audio at all returns null with
/// `*error` left empty: a silent video is not a failure.
///
/// The decoder reads `source` on demand, from whichever thread calls `read`, and
/// keeps it alive. One decoder is not safe to use from two threads at once.
std::unique_ptr<PcmDecoder> OpenAppleDecoder(std::shared_ptr<media::ByteSource> source,
                                             std::string*                       error,
                                             bool                               audioOptional = false);

} // namespace wallpaper::sound
