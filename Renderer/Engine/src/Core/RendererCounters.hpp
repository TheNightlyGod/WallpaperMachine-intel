#pragma once

#include "Core/RendererCounters.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace wallpaper
{

/// Per-surface renderer work counters.
///
/// Counting is disabled by default and gated on one relaxed atomic load, so a
/// release build that never opens a diagnostic session performs no bookkeeping
/// at all. Nothing here starts a thread, a timer or an output stream: the
/// counters are written by the code that does the work and read by whoever asks
/// for a snapshot.
///
/// Every field is an independent atomic, so the decode thread, the render
/// thread and the frame clock can all write without a lock. A snapshot is
/// therefore not an instant of a single consistent state; that is acceptable
/// because the question these answer is "did this keep rising", not "were these
/// two numbers equal at one instant".
class RendererCounters {
public:
    static void SetEnabled(bool enabled) noexcept {
        s_enabled.store(enabled, std::memory_order_relaxed);
    }

    [[nodiscard]] static bool Enabled() noexcept {
        return s_enabled.load(std::memory_order_relaxed);
    }

    void Add(owe_renderer_counter counter, std::uint64_t amount = 1) noexcept {
        if (! Enabled() || amount == 0) return;
        Slot(counter).fetch_add(amount, std::memory_order_relaxed);
    }

    /// For values that are a state rather than an event: the newest wins.
    void Set(owe_renderer_counter counter, std::uint64_t value) noexcept {
        if (! Enabled()) return;
        Slot(counter).store(value, std::memory_order_relaxed);
    }

    [[nodiscard]] std::uint64_t Get(owe_renderer_counter counter) const noexcept {
        return Slot(counter).load(std::memory_order_relaxed);
    }

    /// Copies up to `len` values out. Returns how many were written, so a
    /// caller built against an older counter list stays correct.
    std::size_t Snapshot(std::uint64_t* out, std::size_t len) const noexcept {
        if (out == nullptr) return 0;
        const std::size_t written = len < kCount ? len : kCount;
        for (std::size_t i = 0; i < written; ++i) {
            out[i] = m_values[i].load(std::memory_order_relaxed);
        }
        return written;
    }

    void Reset() noexcept {
        for (auto& value : m_values) value.store(0, std::memory_order_relaxed);
    }

    static constexpr std::size_t kCount = static_cast<std::size_t>(OWE_RC_COUNT);

private:
    [[nodiscard]] std::atomic<std::uint64_t>& Slot(owe_renderer_counter counter) noexcept {
        const auto index = static_cast<std::size_t>(counter);
        return m_values[index < kCount ? index : 0];
    }

    [[nodiscard]] const std::atomic<std::uint64_t>&
    Slot(owe_renderer_counter counter) const noexcept {
        const auto index = static_cast<std::size_t>(counter);
        return m_values[index < kCount ? index : 0];
    }

    static inline std::atomic<bool>                  s_enabled { false };
    std::array<std::atomic<std::uint64_t>, kCount> m_values {};
};

} // namespace wallpaper
