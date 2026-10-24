#pragma once

#include <array>
#include <cstdint>
#include <string>

namespace wallpaper::audio
{

// Rate every submission must already be at: high enough that the top band
// (about 15 kHz) is real signal rather than a fold-back of everything above a
// lower rate's Nyquist frequency.
inline constexpr uint32_t kAudioResponseSampleRate = 48000;
// Frames one analysis reads, back to back: 30 spectra a second, the rate
// Wallpaper Engine publishes at.
inline constexpr uint32_t kAudioResponseWindowFrames = 1600;

struct AudioSpectrumSnapshot
{
    uint64_t generation { 0 };
    uint32_t sample_rate { kAudioResponseSampleRate };
    uint32_t last_submit_sample_rate { 0 };
    uint64_t accepted_frame_count { 0 };
    // True when the analysed block came from two independently submitted
    // channels. A mono submission, or a stereo tap that fell back to mono,
    // leaves this false and keeps left/right identical.
    bool stereo { false };
    // Band levels, lowest frequency first: 0 at -48 dB or below, 1 for a
    // full-scale tone, and above 1 for the rare band louder than that, as
    // Wallpaper Engine documents its own values. Each frame stands alone;
    // wallpapers smooth them themselves.
    std::array<float, 64> left64 {}, right64 {}, average64 {};
    std::array<float, 32> left32 {}, right32 {}, average32 {};
    std::array<float, 16> left16 {}, right16 {}, average16 {};
};

bool SubmitMonoAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error);

bool SubmitAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error);

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot();
bool CurrentAudioSpectrumIsStereo();
void ResetAudioResponseServiceForTesting();

} // namespace wallpaper::audio
