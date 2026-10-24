// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Audio/AudioResponseService.h"
#include "AudioResponseAnalyzerVdsp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iterator>
#include <mutex>
#include <stop_token>
#include <thread>
#include <utility>
#include <vector>

namespace wallpaper::audio
{
namespace
{

constexpr uint32_t kAnalysisSampleRate = kAudioResponseSampleRate;
constexpr uint32_t kWindowSize = kAudioResponseWindowFrames;
// Windows follow each other without overlap, so where one starts never
// depends on how the input happened to be chunked.
constexpr uint32_t kHopSize = kWindowSize;
constexpr size_t kInterleavedChannels = 2u;
constexpr size_t kMaxRetainedMonoFrames = static_cast<size_t>(kAnalysisSampleRate) * 2u;
constexpr auto kSnapshotStaleAfter = std::chrono::milliseconds(250);
constexpr float kSnapshotSignalFloor = 0.0001f;
constexpr float kPcmSignalFloor = 0.00005f;

struct AudioResponseState
{
    std::mutex mutex;
    std::condition_variable_any condition;
    // `fifo_right` is populated only while `fifo_stereo` holds; the two are
    // kept the same length so a block can always be taken from both at once.
    std::vector<float> fifo;
    std::vector<float> fifo_right;
    size_t fifo_read_offset { 0 };
    bool fifo_stereo { false };
    std::jthread worker;
    bool worker_started { false };
    AudioSpectrumSnapshot snapshot {};
    std::chrono::steady_clock::time_point last_submit_time {};
};

AudioResponseState g_state {};

bool ValidateSubmitInput(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    const auto fail = [error](const char* message) {
        if (error != nullptr) {
            *error = message;
        }
        return false;
    };
    if (sample_rate == 0u) {
        return fail("audio sample_rate must be greater than zero");
    }
    if (sample_rate != kAnalysisSampleRate) {
        return fail("audio response needs sample_rate 48000 Hz; resample before submitting");
    }
    if (frame_count == 0u) {
        return fail("audio frame_count must be greater than zero");
    }
    if (pcm_frames == nullptr) {
        return fail("audio pcm_frames must not be null");
    }
    return true;
}

size_t RetainedFramesLocked()
{
    return g_state.fifo.size() - g_state.fifo_read_offset;
}

void ClearFifosLocked()
{
    g_state.fifo.clear();
    g_state.fifo_right.clear();
    g_state.fifo_read_offset = 0;
}

void DropOldestFramesLocked(size_t frame_count)
{
    if (frame_count >= RetainedFramesLocked()) {
        ClearFifosLocked();
        return;
    }
    g_state.fifo_read_offset += frame_count;
}

void PrepareFifosForAppendLocked(size_t incoming_frames)
{
    const size_t retained_frames = RetainedFramesLocked();
    if (g_state.fifo_read_offset != 0 &&
        (g_state.fifo_read_offset >= retained_frames ||
         g_state.fifo.size() + incoming_frames > kMaxRetainedMonoFrames)) {
        const auto offset = static_cast<std::ptrdiff_t>(g_state.fifo_read_offset);
        std::move(g_state.fifo.begin() + offset, g_state.fifo.end(), g_state.fifo.begin());
        g_state.fifo.resize(retained_frames);
        if (g_state.fifo_stereo) {
            std::move(g_state.fifo_right.begin() + offset, g_state.fifo_right.end(), g_state.fifo_right.begin());
            g_state.fifo_right.resize(retained_frames);
        }
        g_state.fifo_read_offset = 0;
    }

    const size_t required_size = g_state.fifo.size() + incoming_frames;
    const auto reserve = [required_size](std::vector<float>& fifo) {
        if (required_size > fifo.capacity()) {
            fifo.reserve(std::min(
                kMaxRetainedMonoFrames,
                std::max(required_size, std::max(fifo.capacity() * 2u, static_cast<size_t>(kWindowSize)))));
        }
    };
    reserve(g_state.fifo);
    if (g_state.fifo_stereo) {
        reserve(g_state.fifo_right);
    }
}

float Sanitize(float sample)
{
    return std::isfinite(sample) ? std::clamp(sample, -1.0f, 1.0f) : 0.0f;
}

bool HasSnapshotSignalLocked()
{
    const auto& bands = g_state.snapshot.average64;
    return std::any_of(bands.begin(), bands.end(), [](float v) { return v > kSnapshotSignalFloor; });
}

bool NeverSubmittedLocked()
{
    return g_state.last_submit_time == std::chrono::steady_clock::time_point {};
}

bool BlockIsSilent(const float* pcm)
{
    return std::none_of(pcm, pcm + kWindowSize, [](float v) { return std::fabs(v) > kPcmSignalFloor; });
}

// Takes the oldest block out of the queue, analyses it outside the lock and
// publishes the result. Returns false when the service was reset meanwhile.
bool AnalyzeNextBlock(std::unique_lock<std::mutex>& lock, const std::stop_token& stop_token)
{
    std::array<float, kWindowSize> left {};
    std::array<float, kWindowSize> right {};
    const bool stereo = g_state.fifo_stereo;
    const auto begin = static_cast<std::ptrdiff_t>(g_state.fifo_read_offset);
    std::copy_n(g_state.fifo.begin() + begin, kWindowSize, left.begin());
    if (stereo) {
        std::copy_n(g_state.fifo_right.begin() + begin, kWindowSize, right.begin());
    }
    DropOldestFramesLocked(kHopSize);

    lock.unlock();
    AudioSpectrumSnapshot analysed {};
    const bool silent = BlockIsSilent(left.data()) && (!stereo || BlockIsSilent(right.data()));
    if (silent) {
        ClearAudioResponseSnapshot(&analysed);
        analysed.stereo = stereo;
    } else if (stereo) {
        AnalyzeAudioResponseStereoBlock(left.data(), right.data(), kWindowSize, &analysed);
    } else {
        AnalyzeAudioResponseMonoBlock(left.data(), kWindowSize, &analysed);
    }
    lock.lock();

    if (stop_token.stop_requested()) {
        return false;
    }
    // Counters come from the snapshot as it is now, so submissions that arrived
    // during the analysis are counted.
    analysed.generation = g_state.snapshot.generation + 1u;
    analysed.sample_rate = kAnalysisSampleRate;
    analysed.last_submit_sample_rate = g_state.snapshot.last_submit_sample_rate;
    analysed.accepted_frame_count = g_state.snapshot.accepted_frame_count;
    g_state.snapshot = analysed;
    return true;
}

void PublishSilenceLocked()
{
    AudioSpectrumSnapshot silent = g_state.snapshot;
    ClearAudioResponseSnapshot(&silent);
    silent.generation = g_state.snapshot.generation + 1u;
    silent.sample_rate = kAnalysisSampleRate;
    g_state.snapshot = silent;
}

void WorkerMain(std::stop_token stop_token)
{
    using Clock = std::chrono::steady_clock;
    std::unique_lock<std::mutex> lock(g_state.mutex);
    while (!stop_token.stop_requested()) {
        if (!NeverSubmittedLocked() &&
            Clock::now() - g_state.last_submit_time >= kSnapshotStaleAfter) {
            // Input stopped: nothing queued before the pause is analysed later,
            // and the spectrum falls to silence once.
            ClearFifosLocked();
            if (g_state.snapshot.generation > 0u && HasSnapshotSignalLocked()) {
                PublishSilenceLocked();
            }
            g_state.last_submit_time = Clock::time_point {};
            continue;
        }
        if (RetainedFramesLocked() >= kHopSize) {
            if (!AnalyzeNextBlock(lock, stop_token)) {
                return;
            }
            continue;
        }
        if (NeverSubmittedLocked()) {
            g_state.condition.wait(lock, stop_token, [] {
                return RetainedFramesLocked() >= kHopSize || !NeverSubmittedLocked();
            });
        } else {
            const auto seen = g_state.last_submit_time;
            g_state.condition.wait_until(
                lock, stop_token, seen + kSnapshotStaleAfter,
                [seen] { return RetainedFramesLocked() >= kHopSize || g_state.last_submit_time != seen; });
        }
    }
}

void EnsureWorkerStartedLocked()
{
    if (!g_state.worker_started) {
        g_state.worker = std::jthread(WorkerMain);
        g_state.worker_started = true;
    }
}

// Stops and joins the analysis thread without holding the state lock (the
// thread takes it), leaving queue and snapshot alone.
void StopWorker()
{
    std::jthread old;
    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        old = std::move(g_state.worker);
        g_state.worker_started = false;
    }
    old.request_stop();
    if (old.joinable()) {
        old.join();
    }
}

// Appends frames to the queue as one layout: other layout clears it first, an
// oversized submission keeps only its newest frames, overflow drops the oldest.
void AppendFramesLocked(const float* pcm_frames, size_t frame_count, bool stereo)
{
    if (g_state.fifo_stereo != stereo) {
        ClearFifosLocked();
    }
    g_state.fifo_stereo = stereo;

    const size_t channels = stereo ? kInterleavedChannels : 1u;
    if (frame_count > kMaxRetainedMonoFrames) {
        ClearFifosLocked();
        pcm_frames += (frame_count - kMaxRetainedMonoFrames) * channels;
        frame_count = kMaxRetainedMonoFrames;
    } else if (RetainedFramesLocked() + frame_count > kMaxRetainedMonoFrames) {
        DropOldestFramesLocked(RetainedFramesLocked() + frame_count - kMaxRetainedMonoFrames);
    }
    PrepareFifosForAppendLocked(frame_count);
    if (stereo) {
        for (size_t frame = 0; frame < frame_count; ++frame) {
            g_state.fifo.push_back(Sanitize(pcm_frames[frame * 2u]));
            g_state.fifo_right.push_back(Sanitize(pcm_frames[frame * 2u + 1u]));
        }
    } else {
        for (size_t frame = 0; frame < frame_count; ++frame) {
            g_state.fifo.push_back(Sanitize(pcm_frames[frame]));
        }
    }
}

bool SubmitValidatedFrames(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count,
    bool stereo)
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    EnsureWorkerStartedLocked();
    const auto now = std::chrono::steady_clock::now();
    if (!NeverSubmittedLocked() && now - g_state.last_submit_time >= kSnapshotStaleAfter) {
        ClearFifosLocked();
    }
    AppendFramesLocked(pcm_frames, frame_count, stereo);
    g_state.last_submit_time = now;
    g_state.snapshot.last_submit_sample_rate = sample_rate;
    g_state.snapshot.accepted_frame_count += accepted_frame_count;
    g_state.condition.notify_all();
    return true;
}

} // namespace

bool SubmitMonoAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), false);
}

bool SubmitAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), true);
}

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot;
}

bool CurrentAudioSpectrumIsStereo()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot.stereo;
}

void ResetAudioResponseServiceForTesting()
{
    StopWorker();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    ClearFifosLocked();
    g_state.fifo_stereo = false;
    g_state.snapshot = AudioSpectrumSnapshot {};
    g_state.last_submit_time = std::chrono::steady_clock::time_point {};
}

#ifdef WESCENE_BUILD_TESTS
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot& snapshot)
{
    ResetAudioResponseServiceForTesting();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.snapshot = snapshot;
}

void StopAudioResponseWorkerAndMarkInputStaleForTesting()
{
    StopWorker();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (!NeverSubmittedLocked()) {
        g_state.last_submit_time =
            std::chrono::steady_clock::now() - kSnapshotStaleAfter - std::chrono::milliseconds(1);
    }
}

void SubmitStaleMonoAudioFramesToWorkerForTesting(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count)
{
    StopWorker();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (pcm_frames != nullptr && frame_count > 0u) {
        AppendFramesLocked(pcm_frames, frame_count, false);
    }
    g_state.last_submit_time =
        std::chrono::steady_clock::now() - kSnapshotStaleAfter - std::chrono::milliseconds(1);
    g_state.snapshot.last_submit_sample_rate = sample_rate;
    g_state.snapshot.accepted_frame_count += accepted_frame_count;
    EnsureWorkerStartedLocked();
    g_state.condition.notify_all();
}

size_t AudioResponseRetainedFrameCountForTesting()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return RetainedFramesLocked();
}
#endif

} // namespace wallpaper::audio
