#pragma once

// Faults a test arms to make the native backend fail where a real GPU, driver or
// scene almost never does, so the failure policy can be checked end to end
// without breaking anything.
//
// Compiled into tests only (`WESCENE_BUILD_TESTS`); the shipped renderer has no
// such switch. Every fault is one-shot unless armed with a count, and fires at
// the same point a real failure would, so everything after it is the production
// routine.

#ifdef WESCENE_BUILD_TESTS

#include <mutex>
#include <optional>
#include <string>

namespace wallpaper::testing
{

enum class SceneBackendFault
{
    /// The admission gate refuses the scene.
    Admission,
    /// Creating the native renderer on the surface fails.
    NativeCreate,
    /// Compiling the scene's graph for the native renderer fails.
    NativeCompile,
    /// A native frame fails after the scene is running.
    NativeDraw,
    /// The native renderer cannot take the replacement surface.
    NativeSurface,
};

class SceneBackendFaults {
public:
    static SceneBackendFaults& Instance()
    {
        static SceneBackendFaults faults;
        return faults;
    }

    /// Makes the next `count` visits to `fault`'s point fail with `reason`.
    void Arm(SceneBackendFault fault, std::string reason, int count = 1)
    {
        std::scoped_lock lock(m_mutex);
        Slot(fault) = Armed { std::move(reason), count };
    }

    /// The reason to fail with, when `fault` is armed; consumes one count.
    std::optional<std::string> Consume(SceneBackendFault fault)
    {
        std::scoped_lock lock(m_mutex);
        auto&            slot = Slot(fault);
        if (slot.count <= 0) return std::nullopt;
        --slot.count;
        return slot.reason;
    }

    /// Forgets every armed fault and zeroes the counters.
    void Reset()
    {
        std::scoped_lock lock(m_mutex);
        for (auto& slot : m_slots) slot = Armed {};
    }

private:
    struct Armed
    {
        std::string reason;
        int         count { 0 };
    };
    Armed& Slot(SceneBackendFault fault) { return m_slots[static_cast<std::size_t>(fault)]; }

    std::mutex m_mutex;
    Armed      m_slots[5];
};

} // namespace wallpaper::testing

#endif // WESCENE_BUILD_TESTS
