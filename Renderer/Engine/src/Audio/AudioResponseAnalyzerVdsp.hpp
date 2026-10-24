#pragma once

#include "Audio/AudioResponseService.h"

#include <cstdint>

namespace wallpaper::audio
{

// Each analyses the first kAudioResponseWindowFrames of the block and replaces
// every band of the snapshot; nothing carries over from the previous block.
void AnalyzeAudioResponseMonoBlock(
    const float* mono_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot);

void AnalyzeAudioResponseStereoBlock(
    const float* left_pcm,
    const float* right_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot);

void ClearAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot);

} // namespace wallpaper::audio
