// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace wallpaper::audio
{

inline float ClampVolume(float value) {
    if (! std::isfinite(value)) return 1.0f;
    return std::clamp(value, 0.0f, 1.0f);
}

inline void ClearInterleavedF32(void* output, std::size_t sample_count) {
    if (output == nullptr || sample_count == 0) return;
    float* out = static_cast<float*>(output);
    std::fill(out, out + sample_count, 0.0f);
}

inline void ApplyVolumeF32(void* data, std::size_t sample_count, float volume) {
    if (data == nullptr || sample_count == 0) return;
    const float gain = ClampVolume(volume);
    float*      samples = static_cast<float*>(data);
    for (std::size_t i = 0; i < sample_count; ++i) samples[i] *= gain;
}

inline void MixInterleavedF32(void* output, const void* input, std::size_t sample_count,
                              float volume) {
    if (output == nullptr || input == nullptr || sample_count == 0) return;
    const float  gain = ClampVolume(volume);
    float*       out  = static_cast<float*>(output);
    const float* in   = static_cast<const float*>(input);
    for (std::size_t i = 0; i < sample_count; ++i) out[i] += in[i] * gain;
}

} // namespace wallpaper::audio
