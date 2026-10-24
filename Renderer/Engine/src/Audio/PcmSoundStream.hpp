// A SoundStream over one of the project's own decoders: the decoder's frames
// go through a PcmPipeline that remixes and resamples them to whatever the
// output device asks for in PassDesc, and loops when the options say so.
#pragma once

#include "Audio/SoundManager.h"
#include "Sound/PcmDecoder.hpp"
#include "Sound/PcmPipeline.hpp"

#include <memory>
#include <optional>
#include <string>

namespace wallpaper::audio
{

class PcmSoundStream final : public SoundStream {
public:
    /// `what` names the sound in log lines.
    PcmSoundStream(std::unique_ptr<sound::PcmDecoder> decoder, Options options, std::string what);

    /// Fills `data` with up to `frameCount` frames at the layout from PassDesc,
    /// zeroes the rest and returns how many frames are real. 0 is the end of a
    /// sound that does not loop (or one that failed, which is logged once).
    uint64_t NextPcmData(void* data, uint32_t frameCount) override;

    /// Sets the device layout. A different layout than before starts the sound
    /// again from its first frame.
    void PassDesc(const Desc& desc) override;

private:
    void StartPipeline(const Desc& desc);

    std::unique_ptr<sound::PcmDecoder>  m_decoder; // while no pipeline owns it
    std::optional<sound::PcmPipeline>   m_pipeline;
    Options                             m_options;
    std::string                         m_what;
    Desc                                m_desc {};
    bool                                m_failure_logged { false };
};

} // namespace wallpaper::audio
