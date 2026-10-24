// Records the largest single heap allocation made while a scope is open, for tests that
// assert a path does not stage a copy of its input.
//
// Written for this project's own tests. Linking allocation_tracking.cpp replaces the
// global operator new/delete of the whole test executable, once.
#pragma once

#include <cstddef>

namespace we_test
{

/// Resets the record and starts tracking; tracking stops when the scope ends. The largest
/// size stays readable afterwards, until the next scope starts.
class AllocationTrackingScope {
public:
    AllocationTrackingScope();
    ~AllocationTrackingScope();
    AllocationTrackingScope(const AllocationTrackingScope&)            = delete;
    AllocationTrackingScope& operator=(const AllocationTrackingScope&) = delete;
};

/// Bytes of the largest allocation requested through operator new / new[] since the last
/// scope began (0 when none).
std::size_t LargestTrackedAllocation();

} // namespace we_test
