// Turns a decoder's frames into frames for the output device: remixed to the
// device's channel count, resampled to its rate, looped when asked, and ended
// cleanly when not. One pass of the sound is its decoded frames, resampled with
// the tail finished, so a loop is that pass over and over with no gap and no
// overlap at the seam. A sound with no frames ends even when looping.
#pragma once

#include "Sound/ChannelRemix.hpp"
#include "Sound/PcmDecoder.hpp"
#include "Sound/Resampler.hpp"

#include <cstddef>
#include <memory>
#include <optional>
#include <vector>

namespace wallpaper::sound
{

class PcmPipeline {
public:
    /// False when the decoder's layout cannot be converted to the device's (a sample
    /// rate so far above the device's that the filter would be enormous). Callers
    /// check it first; the sound stays silent.
    static bool Supports(PcmFormat source, PcmFormat device);

    PcmPipeline(std::unique_ptr<PcmDecoder> decoder, PcmFormat device, bool loop);

    /// Fills `out` (`frames * device.channels` floats) with up to `frames` frames
    /// and returns how many. Fewer than asked, or 0, means the sound has ended;
    /// it keeps returning 0 after that. The unfilled part of `out` is left alone.
    std::size_t read(float* out, std::size_t frames);

    const PcmDecoder& decoder() const { return *m_decoder; }

    /// Gives the decoder back (to start a new pipeline over it); the pipeline is unusable after.
    std::unique_ptr<PcmDecoder> release() { return std::move(m_decoder); }

private:
    /// Decodes and converts the next piece of the sound into `m_pending`.
    /// Returns false when no more audio will come.
    bool refill();
    void mixResampled();

    std::unique_ptr<PcmDecoder> m_decoder;
    PcmFormat                   m_source;
    PcmFormat                   m_device;
    bool                        m_loop;

    std::optional<ChannelRemix> m_remix;     // when the channel counts differ
    std::optional<Resampler>    m_resampler; // when the rates differ
    bool                        m_remix_first { true };

    std::vector<float> m_decoded;   // decoder output scratch
    std::vector<float> m_remixed;   // remix scratch
    std::vector<float> m_mixed;     // remix-after-resample scratch
    std::vector<float> m_pending;   // converted frames not yet handed out
    std::size_t        m_pending_offset { 0 };
    bool               m_pass_produced { false }; // this pass has produced a frame
    bool               m_input_ended { false };
    bool               m_finished { false };
};

} // namespace wallpaper::sound
