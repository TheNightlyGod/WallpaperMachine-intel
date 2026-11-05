#pragma once

// GPU time of every Metal command buffer a test process commits, whichever
// code made it: they are all command buffers of the one device. Counted from
// each buffer's own GPU start and end, so other processes' work on the GPU is
// not in it. Test-only: it wraps `commit` of the device's command buffer class
// for the rest of the process, so only harnesses that measure install it.
//
// Header-only, so a test binary that wants it needs no build change.

#import <Metal/Metal.h>
#import <objc/runtime.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace wallpaper::tests
{

struct CommandBufferGpuTime
{
    /// Per-buffer GPU durations in 0.1 ms buckets: 512 cover 0 to 51.2 ms, and
    /// the last one also holds everything longer.
    static constexpr std::size_t kBuckets  = 512;
    static constexpr uint64_t    kBucketNs = 100'000;

    std::atomic<uint64_t> gpu_ns { 0 };
    std::atomic<uint64_t> committed { 0 };
    std::atomic<uint64_t> completed { 0 };
    std::array<std::atomic<uint64_t>, kBuckets> histogram {};

    /// A buffer committed while `tag` is not negative is also charged to that
    /// tag (a draw's index), so back-to-back draws can be timed one by one.
    std::atomic<int64_t>  tag { -1 };
    std::mutex            tagged_mutex;
    std::vector<uint64_t> tagged_ns;
    std::vector<uint32_t> tagged_buffers;
    /// Each tagged buffer's tag and its GPU start and end (seconds), for the time the GPU
    /// was busy with any of them: buffers of consecutive draws can run at once, and then
    /// their own spans count the time they shared twice.
    struct Span
    {
        int64_t tag;
        double  start;
        double  end;
    };
    std::vector<Span> tagged_spans;

    using Histogram = std::array<uint64_t, kBuckets>;

    Histogram HistogramSnapshot() const
    {
        Histogram values {};
        for (std::size_t i = 0; i < kBuckets; ++i) values[i] = histogram[i].load();
        return values;
    }

    /// Waits until every buffer committed so far has completed, for at most `limit`.
    bool WaitForCompletion(std::chrono::milliseconds limit) const
    {
        const auto deadline = std::chrono::steady_clock::now() + limit;
        while (completed.load() < committed.load()) {
            if (std::chrono::steady_clock::now() >= deadline) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }
};

inline CommandBufferGpuTime& GpuTimeCounters()
{
    static CommandBufferGpuTime counters;
    return counters;
}

/// The `p` quantile (0..1) of the buffers counted between two histogram
/// snapshots, in ms: the upper edge of the 0.1 ms bucket it falls in, or 0
/// when no buffer completed.
inline double HistogramQuantileMs(const CommandBufferGpuTime::Histogram& before,
                                  const CommandBufferGpuTime::Histogram& after, double p)
{
    uint64_t total = 0;
    for (std::size_t i = 0; i < before.size(); ++i) total += after[i] - before[i];
    if (total == 0) return 0.0;
    const auto rank = std::max<uint64_t>(1, static_cast<uint64_t>(std::ceil(p * double(total))));
    uint64_t   seen = 0;
    for (std::size_t i = 0; i < before.size(); ++i) {
        seen += after[i] - before[i];
        if (seen >= rank) {
            return double((i + 1) * CommandBufferGpuTime::kBucketNs) / 1e6;
        }
    }
    return double(before.size() * CommandBufferGpuTime::kBucketNs) / 1e6;
}

namespace detail
{

inline IMP& OriginalCommit()
{
    static IMP original = nullptr;
    return original;
}

inline void CountedCommit(id self, SEL command)
{
    auto&         counters = GpuTimeCounters();
    const int64_t tag      = counters.tag.load(std::memory_order_relaxed);
    counters.committed.fetch_add(1);
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        const double   seconds = buffer.GPUEndTime - buffer.GPUStartTime;
        const uint64_t ns      = seconds > 0.0 ? static_cast<uint64_t>(seconds * 1e9) : 0;
        if (ns > 0) {
            counters.gpu_ns += ns;
            const auto bucket = std::min<uint64_t>(ns / CommandBufferGpuTime::kBucketNs,
                                                   CommandBufferGpuTime::kBuckets - 1);
            ++counters.histogram[bucket];
        }
        if (tag >= 0) {
            std::scoped_lock lock(counters.tagged_mutex);
            const auto       index = static_cast<std::size_t>(tag);
            if (counters.tagged_ns.size() <= index) {
                counters.tagged_ns.resize(index + 1, 0);
                counters.tagged_buffers.resize(index + 1, 0);
            }
            counters.tagged_ns[index] += ns;
            ++counters.tagged_buffers[index];
            if (ns > 0) counters.tagged_spans.push_back({ tag, buffer.GPUStartTime, buffer.GPUEndTime });
        }
        counters.completed.fetch_add(1);
    }];
    reinterpret_cast<void (*)(id, SEL)>(OriginalCommit())(self, command);
}

} // namespace detail

/// Wraps `commit` of the device's command buffer class once per process.
/// False when retained and unretained buffers do not share one `commit`: one
/// of the renderers would then go uncounted, so the caller says so instead.
inline bool CountCommandBufferGpuTime(id<MTLDevice> device)
{
    static std::mutex installing;
    std::scoped_lock  lock(installing);
    if (detail::OriginalCommit() != nullptr) return true;
    id<MTLCommandQueue> queue      = [device newCommandQueue];
    Class               retained   = [[queue commandBuffer] class];
    Class               unretained = [[queue commandBufferWithUnretainedReferences] class];
    Method              method     = class_getInstanceMethod(retained, @selector(commit));
    if (method == nullptr ||
        method != class_getInstanceMethod(unretained, @selector(commit))) {
        return false;
    }
    detail::OriginalCommit() =
        method_setImplementation(method, reinterpret_cast<IMP>(&detail::CountedCommit));
    return true;
}

} // namespace wallpaper::tests
