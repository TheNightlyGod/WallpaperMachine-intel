// Standalone diagnostic measurement. Exit zero means collection/reporting
// completed; no delivered-frame count is a performance acceptance threshold.
#include "Timer/FrameTimer.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

namespace {
using Clock = std::chrono::steady_clock;
using wallpaper::FrameTimer;

constexpr std::uint16_t kRequestedFps = 60;
constexpr std::int64_t kBusyWorkNs = 18000000;
constexpr std::int64_t kRequestedWarmupNs = 200000000;
constexpr std::int64_t kRequestedWindowNs = 1000000000;

std::int64_t TimestampNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               Clock::now().time_since_epoch()).count();
}

struct Sample {
    std::int64_t window_start_ns;
    std::int64_t window_end_ns;
    std::uint64_t count_before;
    std::uint64_t count_after;
};

class DeliveryBenchmark {
public:
    DeliveryBenchmark() : timer_([this] { Notify(); }) {}
    ~DeliveryBenchmark() { StopAndJoin(); }
    DeliveryBenchmark(const DeliveryBenchmark&) = delete;
    DeliveryBenchmark& operator=(const DeliveryBenchmark&) = delete;

    Sample Collect() {
        timer_.SetRequiredFps(kRequestedFps);
        timer_.SetFrameDemand({FrameTimer::FrameDemand::Kind::Continuous,
                              std::chrono::microseconds::zero()});
        // Start only after construction: if thread creation or Run throws, this
        // fully constructed object's destructor still stops/joins its workers.
        consumer_ = std::thread([this] { Consume(); });
        timer_.Run();

        std::this_thread::sleep_for(std::chrono::nanoseconds(kRequestedWarmupNs));
        const auto window_start = TimestampNs();
        const auto count_before = completed_.load(std::memory_order_relaxed);
        std::this_thread::sleep_for(std::chrono::nanoseconds(kRequestedWindowNs));
        const auto count_after = completed_.load(std::memory_order_relaxed);
        const auto window_end = TimestampNs();

        // The raw counter observations lie inside the outer clock window, not
        // at simultaneous clock/counter snapshots. Later teardown work is not
        // included in either recorded count.
        StopAndJoin();
        if (failure_) std::rethrow_exception(failure_);
        if (window_end <= window_start || count_after < count_before) {
            throw std::runtime_error("inconsistent measurement window or counters");
        }
        return {window_start, window_end, count_before, count_after};
    }

private:
    void RememberFailure(std::exception_ptr failure) noexcept {
        // Only the first failing worker writes failure_. The controller reads
        // it only after stopping/joining both timer and consumer workers.
        if (!failure_claimed_.test_and_set(std::memory_order_relaxed)) {
            failure_ = std::move(failure);
        }
    }

    void Notify() noexcept {
        try {
            {
                std::lock_guard lock(handoff_mutex_);
                if (stopping_) return;
                // One bounded slot coalesces notifications; no queue/allocation.
                pending_ = true;
            }
            handoff_changed_.notify_one();
        } catch (...) {
            RememberFailure(std::current_exception());
        }
    }

    void Consume() noexcept {
        try {
            for (;;) {
                {
                    std::unique_lock lock(handoff_mutex_);
                    handoff_changed_.wait(lock, [this] { return pending_ || stopping_; });
                    if (!pending_) return; // stopped with no remaining handoff
                    pending_ = false;
                }
                // Exactly one consumer owns FrameBegin/work/FrameEnd. No handoff
                // mutex is held during timer calls or the steady-clock busy work.
                timer_.FrameBegin();
                const auto work_started = Clock::now();
                while (Clock::now() - work_started < std::chrono::nanoseconds(kBusyWorkNs)) {
                }
                completed_.fetch_add(1, std::memory_order_relaxed);
                timer_.FrameEnd();
            }
        } catch (...) {
            RememberFailure(std::current_exception());
        }
    }

    void StopAndJoin() {
        if (joined_) return;
        // Quiesce the producer first. Then let the consumer finish in-flight
        // work and drain the sole pending notification before exiting. Keeping
        // all callback-accessible members alive through both joins also covers
        // exceptions during collection/startup.
        timer_.Stop();
        {
            std::lock_guard lock(handoff_mutex_);
            stopping_ = true;
        }
        handoff_changed_.notify_one();
        if (consumer_.joinable()) consumer_.join();
        joined_ = true;
    }

    std::mutex handoff_mutex_;
    std::condition_variable handoff_changed_;
    bool pending_ = false;
    bool stopping_ = false;
    bool joined_ = false; // controller thread only
    std::atomic<std::uint64_t> completed_ {0};
    std::atomic_flag failure_claimed_ = ATOMIC_FLAG_INIT;
    std::exception_ptr failure_;
    FrameTimer timer_;
    std::thread consumer_;
};
} // namespace

int main() {
    try {
        DeliveryBenchmark benchmark;
        const auto sample = benchmark.Collect();
        // All owned workers have stopped/joined before this sole stdout report.
        std::cout << "TIMER_DELIVERY_BENCHMARK {\"schema\":1"
                  << ",\"requested_fps\":" << kRequestedFps
                  << ",\"busy_work_ns\":" << kBusyWorkNs
                  << ",\"requested_warmup_ns\":" << kRequestedWarmupNs
                  << ",\"requested_window_ns\":" << kRequestedWindowNs
                  << ",\"window_start_ns\":" << sample.window_start_ns
                  << ",\"window_end_ns\":" << sample.window_end_ns
                  << ",\"count_before\":" << sample.count_before
                  << ",\"count_after\":" << sample.count_after
                  << ",\"delivered\":" << sample.count_after - sample.count_before
                  << "}\n";
        std::cout.flush();
        if (!std::cout) throw std::runtime_error("unable to emit measurement report");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "timer_delivery_benchmark: " << error.what() << '\n';
    } catch (...) {
        std::cerr << "timer_delivery_benchmark: unknown operational failure\n";
    }
    return 1;
}
