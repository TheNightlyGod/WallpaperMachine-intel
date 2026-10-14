#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <limits>

namespace wallpaper
{

/// Why a surface stopped drawing without anyone asking it to.
///
/// Mirrors `owe_surface_stop_reason` in the C header. `Running` is the absence
/// of a stop, not a promise that frames are arriving: a paused or idle scene
/// is also `Running`.
enum class SurfaceStopReason : std::uint32_t {
    Running      = 0,
    /// A frame failed after the graph was built: the swapchain, an acquire, a
    /// present or a submit. The render graph itself is intact.
    FrameFailed  = 1,
    /// The render graph or the backend under it could not be built or torn
    /// down, so there is nothing to draw with until a scene or surface is
    /// installed again.
    GraphFailed  = 2,
};

/// One reading of a surface's health. Plain data, safe to copy anywhere.
struct SurfaceHealthSnapshot {
    /// `last_present_age_ms` when nothing has ever been presented.
    static constexpr std::uint64_t kNeverPresented = std::numeric_limits<std::uint64_t>::max();

    /// Frames the render loop ran to completion, whether or not they reached
    /// the display. A frame that would repeat the picture completes without
    /// presenting, so this is the number that shows a clock is alive.
    std::uint64_t frames_completed { 0 };
    /// Frames that actually reached the surface.
    std::uint64_t frames_presented { 0 };
    /// Frames lost to a failure inside the draw itself. Never reset, so a
    /// host can tell a surface that failed once from one that never has even
    /// after the stop was cleared.
    std::uint64_t failed_frames { 0 };
    /// Milliseconds since the last present, or `kNeverPresented`. On a still
    /// scene this grows without anything being wrong; it is a diagnostic, not
    /// a liveness signal.
    std::uint64_t last_present_age_ms { kNeverPresented };
    SurfaceStopReason stop_reason { SurfaceStopReason::Running };
};

/// What a scene surface can say about itself at any moment, without anything
/// being enabled first.
///
/// `RendererCounters` answers "how much work was done" and is off unless a
/// diagnostic session switched it on, so a failure that stops a wallpaper is
/// invisible in a normal run. This is the other half: a handful of always-on
/// atomics, written once per frame, read by whoever asks. Nothing here starts a
/// thread, a timer or an output stream.
///
/// Every field is an independent atomic. A snapshot is therefore a set of live
/// readings rather than one instant, which is enough for the questions asked of
/// it: did the counters move, and is a stop latched.
///
/// The clock is a parameter on the two members that read it, so a test can
/// drive time by hand.
class SurfaceHealth {
public:
    /// Nanoseconds on the steady clock; the unit every `now_ns` here uses.
    [[nodiscard]] static std::uint64_t NowNs() noexcept {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch())
                .count());
    }

    /// A frame ran to the end. Counts frames the renderer skipped as
    /// unchanged too, which is the point: the picture repeating is a healthy
    /// scene, not a stalled one.
    void NoteFrameCompleted() noexcept {
        m_frames_completed.fetch_add(1, std::memory_order_relaxed);
    }

    /// A frame reached the surface.
    void NotePresented(std::uint64_t now_ns = NowNs()) noexcept {
        m_frames_presented.fetch_add(1, std::memory_order_relaxed);
        // Zero means "never", so a clock that really reads zero is nudged.
        m_last_present_ns.store(now_ns == 0 ? 1 : now_ns, std::memory_order_relaxed);
    }

    /// The draw itself failed. A graph failure noted earlier is more
    /// fundamental and is not downgraded to this.
    void NoteFrameFailed() noexcept {
        m_failed_frames.fetch_add(1, std::memory_order_relaxed);
        auto expected = static_cast<std::uint32_t>(SurfaceStopReason::Running);
        m_stop.compare_exchange_strong(expected,
                                       static_cast<std::uint32_t>(SurfaceStopReason::FrameFailed),
                                       std::memory_order_relaxed);
    }

    /// The graph or backend could not be built or released. Wins over a frame
    /// failure, because a frame cannot be retried without a graph.
    void NoteGraphFailed() noexcept {
        m_stop.store(static_cast<std::uint32_t>(SurfaceStopReason::GraphFailed),
                     std::memory_order_relaxed);
    }

    /// The surface can draw again. Clears the latch, never the counters.
    void ClearStop() noexcept {
        m_stop.store(static_cast<std::uint32_t>(SurfaceStopReason::Running),
                     std::memory_order_relaxed);
    }

    [[nodiscard]] SurfaceHealthSnapshot Snapshot(std::uint64_t now_ns = NowNs()) const noexcept {
        SurfaceHealthSnapshot out;
        out.frames_completed = m_frames_completed.load(std::memory_order_relaxed);
        out.frames_presented = m_frames_presented.load(std::memory_order_relaxed);
        out.failed_frames    = m_failed_frames.load(std::memory_order_relaxed);
        out.stop_reason      = StopFrom(m_stop.load(std::memory_order_relaxed));
        const auto last      = m_last_present_ns.load(std::memory_order_relaxed);
        if (last != 0) {
            out.last_present_age_ms = now_ns > last ? (now_ns - last) / 1'000'000 : 0;
        }
        return out;
    }

private:
    [[nodiscard]] static SurfaceStopReason StopFrom(std::uint32_t raw) noexcept {
        switch (static_cast<SurfaceStopReason>(raw)) {
        case SurfaceStopReason::FrameFailed: return SurfaceStopReason::FrameFailed;
        case SurfaceStopReason::GraphFailed: return SurfaceStopReason::GraphFailed;
        case SurfaceStopReason::Running: break;
        }
        return SurfaceStopReason::Running;
    }

    std::atomic<std::uint64_t> m_frames_completed { 0 };
    std::atomic<std::uint64_t> m_frames_presented { 0 };
    std::atomic<std::uint64_t> m_failed_frames { 0 };
    std::atomic<std::uint64_t> m_last_present_ns { 0 };
    std::atomic<std::uint32_t> m_stop { static_cast<std::uint32_t>(SurfaceStopReason::Running) };
};

} // namespace wallpaper
