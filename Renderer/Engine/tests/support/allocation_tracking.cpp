#include "support/allocation_tracking.hpp"

#include <atomic>
#include <cstdlib>
#include <new>

namespace
{

std::atomic<bool>        g_tracking { false };
std::atomic<std::size_t> g_largest { 0 };

void Note(std::size_t size)
{
    if (!g_tracking.load(std::memory_order_relaxed)) return;
    std::size_t seen = g_largest.load(std::memory_order_relaxed);
    while (seen < size && !g_largest.compare_exchange_weak(seen, size, std::memory_order_relaxed)) {
    }
}

void* Take(std::size_t size)
{
    Note(size);
    if (void* block = std::malloc(size)) return block;
    throw std::bad_alloc();
}

} // namespace

namespace we_test
{

AllocationTrackingScope::AllocationTrackingScope()
{
    g_largest.store(0, std::memory_order_relaxed);
    g_tracking.store(true, std::memory_order_relaxed);
}

AllocationTrackingScope::~AllocationTrackingScope()
{
    g_tracking.store(false, std::memory_order_relaxed);
}

std::size_t LargestTrackedAllocation()
{
    return g_largest.load(std::memory_order_relaxed);
}

} // namespace we_test

void* operator new(std::size_t size) { return Take(size); }
void* operator new[](std::size_t size) { return Take(size); }
void operator delete(void* block) noexcept { std::free(block); }
void operator delete[](void* block) noexcept { std::free(block); }
void operator delete(void* block, std::size_t) noexcept { std::free(block); }
void operator delete[](void* block, std::size_t) noexcept { std::free(block); }
