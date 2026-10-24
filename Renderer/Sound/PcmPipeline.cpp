#include "Sound/PcmPipeline.hpp"

#include <algorithm>
#include <cstring>

namespace wallpaper::sound
{
namespace
{
constexpr std::size_t kDecodeFrames = 4096;
}

bool PcmPipeline::Supports(PcmFormat source, PcmFormat device)
{
    if (source.channels == 0 || device.channels == 0) return false;
    return source.sampleRate == device.sampleRate || Resampler::Supports(source.sampleRate, device.sampleRate);
}

PcmPipeline::PcmPipeline(std::unique_ptr<PcmDecoder> decoder, PcmFormat device, bool loop)
    : m_decoder(std::move(decoder)), m_source(m_decoder->format()), m_device(device), m_loop(loop)
{
    if (m_source.channels != m_device.channels) m_remix.emplace(m_source.channels, m_device.channels);
    if (m_source.sampleRate != m_device.sampleRate) {
        // Resample at the smaller channel count: remix first when mixing down, after when mixing up.
        m_remix_first = m_device.channels <= m_source.channels;
        m_resampler.emplace(m_remix_first ? m_device.channels : m_source.channels, m_source.sampleRate,
                            m_device.sampleRate);
    }
    m_decoded.resize(kDecodeFrames * m_source.channels);
}

void PcmPipeline::mixResampled()
{
    // When mixing up, the resampler worked at the source channel count: mix what it made.
    if (!m_remix || m_remix_first) return;
    const std::size_t frames = m_pending.size() / m_source.channels;
    m_mixed.resize(frames * m_device.channels);
    m_remix->apply(m_pending.data(), m_mixed.data(), frames);
    m_pending.swap(m_mixed);
}

bool PcmPipeline::refill()
{
    while (!m_finished) {
        m_pending.clear();
        m_pending_offset = 0;

        std::size_t frames = 0;
        if (!m_input_ended) {
            frames = m_decoder->read(m_decoded.data(), kDecodeFrames);
            if (frames == 0) m_input_ended = true;
        }

        if (frames > 0) {
            const float* samples = m_decoded.data();
            std::size_t  count   = frames;
            if (m_remix && (m_remix_first || !m_resampler)) {
                m_remixed.resize(frames * m_device.channels);
                m_remix->apply(samples, m_remixed.data(), frames);
                samples = m_remixed.data();
            }
            if (m_resampler) {
                m_resampler->push(samples, count, m_pending);
                mixResampled();
            } else {
                m_pending.assign(samples, samples + count * m_device.channels);
            }
            if (!m_pending.empty()) {
                m_pass_produced = true;
                return true;
            }
            continue; // the filter has not produced anything yet
        }

        // The decoder is out of frames: finish the pass's tail.
        if (m_resampler) {
            m_resampler->flush(m_pending);
            mixResampled();
            if (!m_pending.empty()) {
                m_pass_produced = true;
                // The next refill sees an ended input again and starts the loop or finishes.
                return true;
            }
        }
        if (m_loop && m_pass_produced && !m_decoder->failed() && m_decoder->rewind()) {
            m_pass_produced = false;
            m_input_ended   = false;
            continue;
        }
        m_finished = true;
    }
    return false;
}

std::size_t PcmPipeline::read(float* out, std::size_t frames)
{
    const std::size_t channels = m_device.channels;
    std::size_t       written  = 0;
    while (written < frames) {
        const std::size_t pending = (m_pending.size() - m_pending_offset) / channels;
        if (pending == 0) {
            if (!refill()) break;
            continue;
        }
        const std::size_t take = std::min(frames - written, pending);
        std::memcpy(out + written * channels, m_pending.data() + m_pending_offset, take * channels * sizeof(float));
        m_pending_offset += take * channels;
        written += take;
    }
    return written;
}

} // namespace wallpaper::sound
