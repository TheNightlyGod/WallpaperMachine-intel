// ReorderDepth: how big a buffer turns decode order into display order.
#include "Media/SampleOrder.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <queue>
#include <random>
#include <vector>

namespace wallpaper::media
{
namespace
{

std::vector<Sample> SamplesWithPts(const std::vector<std::int64_t>& pts)
{
    std::vector<Sample> samples(pts.size());
    for (std::size_t index = 0; index < pts.size(); ++index) {
        samples[index].pts = pts[index];
        samples[index].dts = static_cast<std::int64_t>(index);
    }
    return samples;
}

/// What a buffer of `depth + 1` frames emits for frames arriving in `pts` order.
std::vector<std::int64_t> EmitThroughBuffer(const std::vector<std::int64_t>& pts, std::size_t depth)
{
    std::priority_queue<std::int64_t, std::vector<std::int64_t>, std::greater<>> held;
    std::vector<std::int64_t>                                                    out;
    for (const std::int64_t value : pts) {
        held.push(value);
        if (held.size() > depth) {
            out.push_back(held.top());
            held.pop();
        }
    }
    while (! held.empty()) {
        out.push_back(held.top());
        held.pop();
    }
    return out;
}

TEST(ReorderDepth, ZeroWhenDecodeOrderIsDisplayOrder)
{
    EXPECT_EQ(ReorderDepth({}), 0u);
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 5 })), 0u);
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 0, 1, 2, 3, 4 })), 0u);
    // Equal presentation times are not reordering.
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 0, 1, 1, 2 })), 0u);
}

TEST(ReorderDepth, OneBFrameBetweenAnchorsIsDepthOne)
{
    // I0 P3 B1 B2 P6 B4 B5
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 0, 3, 1, 2, 6, 4, 5 })), 1u);
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 0, 2, 1, 4, 3 })), 1u);
}

TEST(ReorderDepth, APyramidIsDeeperThanItsAnchors)
{
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 0, 4, 2, 1, 3, 8, 6, 5, 7 })), 2u);
    // Fully reversed: the last picture is later than every other one.
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ 4, 3, 2, 1, 0 })), 4u);
}

TEST(ReorderDepth, NegativePresentationTimesOrderLikeAnyOther)
{
    EXPECT_EQ(ReorderDepth(SamplesWithPts({ -2, 2, 0, 1, -1 })), 3u);
}

TEST(ReorderDepth, ABufferOfThatDepthEmitsDisplayOrderForAnyArrangement)
{
    std::mt19937 random(12345);
    for (int round = 0; round < 300; ++round) {
        // A stream whose pictures arrive at most `window` places from where they are shown.
        const std::size_t   count  = 5 + random() % 60;
        const std::size_t   window = 1 + random() % 6;
        std::vector<std::int64_t> pts(count);
        for (std::size_t index = 0; index < count; ++index) pts[index] = static_cast<std::int64_t>(index);
        for (std::size_t index = 0; index + 1 < count; ++index) {
            const std::size_t other = std::min(count - 1, index + random() % (window + 1));
            std::swap(pts[index], pts[other]);
        }
        const std::size_t depth = ReorderDepth(SamplesWithPts(pts));
        std::vector<std::int64_t> expected = pts;
        std::sort(expected.begin(), expected.end());
        EXPECT_EQ(EmitThroughBuffer(pts, depth), expected) << "round " << round << " depth " << depth;
    }
}

TEST(ReorderDepth, LargeTablesAreCountedWithoutQuadraticWork)
{
    std::vector<std::int64_t> pts(400000);
    for (std::size_t index = 0; index < pts.size(); ++index) pts[index] = static_cast<std::int64_t>(index);
    // Swap neighbouring pairs: depth 1.
    for (std::size_t index = 0; index + 1 < pts.size(); index += 2) std::swap(pts[index], pts[index + 1]);
    EXPECT_EQ(ReorderDepth(SamplesWithPts(pts)), 1u);
}

} // namespace
} // namespace wallpaper::media
