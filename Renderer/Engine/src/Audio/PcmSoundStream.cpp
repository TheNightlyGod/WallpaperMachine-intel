#include "Audio/PcmSoundStream.hpp"

#include "Utils/Logging.h"

#include <algorithm>

namespace wallpaper::audio
{

PcmSoundStream::PcmSoundStream(std::unique_ptr<sound::PcmDecoder> decoder, Options options, std::string what)
    : m_decoder(std::move(decoder)), m_options(options), m_what(std::move(what))
{
}

void PcmSoundStream::StartPipeline(const Desc& desc)
{
    if (m_pipeline) {
        m_decoder = m_pipeline->release();
        m_pipeline.reset();
        if (!m_decoder->rewind()) {
            LOG_ERROR("failed to restart sound \"%s\" for a new output layout", m_what.c_str());
            return;
        }
    }
    m_desc = desc;
    if (!sound::PcmPipeline::Supports(m_decoder->format(), sound::PcmFormat { desc.channels, desc.sampleRate })) {
        // The file's rate is too far above the device's to convert: silent, not enormous.
        LOG_ERROR("sound \"%s\" has a sample rate (%u Hz) that cannot be converted to the output's (%u Hz)",
                  m_what.c_str(), m_decoder->format().sampleRate, desc.sampleRate);
        return;
    }
    m_pipeline.emplace(std::move(m_decoder), sound::PcmFormat { desc.channels, desc.sampleRate }, m_options.loop);
}

void PcmSoundStream::PassDesc(const Desc& desc)
{
    if (desc.channels == 0 || desc.sampleRate == 0) return;
    if (m_pipeline && desc.channels == m_desc.channels && desc.sampleRate == m_desc.sampleRate) return;
    StartPipeline(desc);
}

uint64_t PcmSoundStream::NextPcmData(void* data, uint32_t frameCount)
{
    if (data == nullptr || frameCount == 0) return 0;
    auto* out = static_cast<float*>(data);
    std::fill(out, out + static_cast<std::size_t>(frameCount) * (m_pipeline ? m_desc.channels : 0), 0.0f);
    if (!m_pipeline) return 0;

    const auto frames = m_pipeline->read(out, frameCount);
    if (frames < frameCount && m_pipeline->decoder().failed() && !m_failure_logged) {
        m_failure_logged = true;
        LOG_ERROR("failed to decode sound \"%s\": %s", m_what.c_str(), m_pipeline->decoder().failure().c_str());
    }
    return frames;
}

} // namespace wallpaper::audio
