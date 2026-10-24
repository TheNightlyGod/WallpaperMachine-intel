// What a sound decoder gives the rest of the audio path: interleaved 32-bit
// float frames at the file's own channel count and sample rate, from the first
// frame to the last, and back to the first for a loop. Everything after that
// (remixing to the device, resampling, looping, the end of the sound) is the
// pipeline's job, so every decoder behaves the same way there.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace wallpaper::sound
{

struct PcmFormat {
    std::uint32_t channels { 0 };
    std::uint32_t sampleRate { 0 };

    bool operator==(const PcmFormat& other) const
    {
        return channels == other.channels && sampleRate == other.sampleRate;
    }
    bool operator!=(const PcmFormat& other) const { return !(*this == other); }
};

class PcmDecoder {
public:
    virtual ~PcmDecoder() = default;

    /// The layout of the frames `read` returns. Fixed once the decoder is open.
    virtual PcmFormat format() const = 0;

    /// Decodes up to `frames` frames into `out` (`frames * channels` floats) and
    /// returns how many. 0 means the sound has ended, or decoding failed:
    /// `failed()` tells which. A decoder never returns 0 while frames remain.
    virtual std::size_t read(float* out, std::size_t frames) = 0;

    /// Goes back to the first frame so the next `read` starts the sound again.
    /// Returns false when it cannot, which ends a loop.
    virtual bool rewind() = 0;

    /// True once a read stopped early because the data was bad (as opposed to
    /// the sound ending), with the reason in `failure()`.
    virtual bool               failed() const { return false; }
    virtual const std::string& failure() const
    {
        static const std::string none;
        return none;
    }
};

} // namespace wallpaper::sound
