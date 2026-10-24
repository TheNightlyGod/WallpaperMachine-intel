// Waiting for the audio-response worker in tests: the worker publishes snapshots
// from its own thread, so a test polls the current snapshot until it looks the way
// the test needs, or gives up and looks at whatever is there.
//
// Written for this project's own tests.
#pragma once

#include "Audio/AudioResponseService.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <thread>

namespace wallpaper::audio::testing
{

/// Polls every 5 ms until `accept(snapshot)` holds or `timeout` has passed; returns the
/// accepted snapshot, or the current one when time ran out.
template<typename Accept>
AudioSpectrumSnapshot PollSnapshot(std::chrono::milliseconds timeout, Accept accept)
{
    const auto give_up = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        const AudioSpectrumSnapshot seen = CurrentAudioSpectrumSnapshot();
        if (accept(seen) || std::chrono::steady_clock::now() >= give_up) return seen;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

inline bool HasNonZeroAverage64Bin(const AudioSpectrumSnapshot& snapshot)
{
    return std::any_of(snapshot.average64.begin(), snapshot.average64.end(),
                       [](float level) { return level != 0.0f; });
}

/// The first snapshot with a generation above zero (waits up to 500 ms).
inline AudioSpectrumSnapshot WaitForGeneration()
{
    return PollSnapshot(std::chrono::milliseconds(500),
                        [](const AudioSpectrumSnapshot& s) { return s.generation > 0u; });
}

/// The first snapshot newer than `generation` (waits up to `timeout`).
inline AudioSpectrumSnapshot WaitForGenerationAfter(uint64_t generation,
                                                    std::chrono::milliseconds timeout)
{
    return PollSnapshot(timeout,
                        [generation](const AudioSpectrumSnapshot& s) { return s.generation > generation; });
}

/// The first snapshot newer than `generation` whose average64 is all zeros (waits up to 1 s).
inline AudioSpectrumSnapshot WaitForSilentGeneration(uint64_t generation)
{
    return PollSnapshot(std::chrono::milliseconds(1000), [generation](const AudioSpectrumSnapshot& s) {
        return s.generation > generation && !HasNonZeroAverage64Bin(s);
    });
}

/// The largest per-band difference between two 64-band spectra.
inline float MaxAbsDifference(const std::array<float, 64>& a, const std::array<float, 64>& b)
{
    float largest = 0.0f;
    for (std::size_t band = 0; band < a.size(); ++band) {
        largest = std::max(largest, std::fabs(a[band] - b[band]));
    }
    return largest;
}

} // namespace wallpaper::audio::testing
