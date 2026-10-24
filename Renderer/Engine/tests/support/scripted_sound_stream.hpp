// A sound stream that plays back a fixed list of samples, for tests of the code that
// drives streams (the scene sound layer). It decodes nothing and opens no device.
//
// Written for this project's own tests.
#pragma once

#include "Audio/SoundManager.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace wallpaper::audio::testing
{

class ScriptedSoundStream final : public SoundStream {
public:
    explicit ScriptedSoundStream(std::vector<float> samples): m_script(std::move(samples)) {}

    /// Copies as many whole frames as are left (at most `frames`), returns that count; 0 once
    /// the list is used up. The list is interleaved by the channel count last passed.
    uint64_t NextPcmData(void* out, uint32_t frames) override
    {
        ++reads;
        const std::size_t width = std::max<std::size_t>(1, m_format.channels);
        const std::size_t left  = (m_script.size() - std::min(m_cursor, m_script.size())) / width;
        const std::size_t whole = std::min<std::size_t>(frames, left);
        if (whole != 0) {
            std::memcpy(out, m_script.data() + m_cursor, whole * width * sizeof(float));
            m_cursor += whole * width;
        }
        return whole;
    }

    void PassDesc(const Desc& desc) override { m_format = desc; }

    /// Samples handed out so far.
    std::size_t consumed() const { return m_cursor; }

    /// How many times NextPcmData was called.
    int reads { 0 };

private:
    Desc               m_format { .channels = 2, .sampleRate = 48'000 };
    std::vector<float> m_script;
    std::size_t        m_cursor { 0 };
};

inline std::shared_ptr<ScriptedSoundStream> MakeFakeStream(std::vector<float> samples)
{
    return std::make_shared<ScriptedSoundStream>(std::move(samples));
}

} // namespace wallpaper::audio::testing
