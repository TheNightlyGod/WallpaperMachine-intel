#include <array>
#include <limits>
#include <memory>
#include <span>
#include <vector>

#include <gtest/gtest.h>

#include "Scene/SceneMesh.h"

namespace
{
using namespace wallpaper;


TEST(SceneIndexArray, PackedUInt16DrawCountUsesHalfUnits) {
    SceneIndexArray array(2);
    const std::array<uint16_t, 6> first { 0, 1, 3, 1, 2, 3 };
    array.AssignHalf(0, first);
    array.SetDrawIndexCount(6);

    EXPECT_EQ(array.Width(), SceneIndexWidth::UInt16);
    EXPECT_EQ(array.ElementSize(), 2u);
    EXPECT_EQ(array.QuadCapacity(), 2u);
    EXPECT_EQ(array.DrawIndexCount(), 6u);
    EXPECT_EQ(array.DrawIndexBytes(), 12u);
}

TEST(SceneIndexArray, UInt32DrawCountIsIndexCount) {
    SceneIndexArray array(2, SceneIndexWidth::UInt32);
    const std::array<uint32_t, 6> first { 0, 1, 3, 1, 2, 3 };
    array.Assign(0, first);
    array.SetDrawIndexCount(6);

    EXPECT_EQ(array.Width(), SceneIndexWidth::UInt32);
    EXPECT_EQ(array.ElementSize(), 4u);
    EXPECT_EQ(array.QuadCapacity(), 2u);
    EXPECT_EQ(array.DrawIndexCount(), 6u);
    EXPECT_EQ(array.DrawIndexBytes(), 24u);
}

TEST(SceneIndexArray, AppendingKeepsTheContentRevisionAndRewritingRenewsIt) {
    SceneIndexArray array(4);
    const std::array<uint16_t, 6> quad { 0, 1, 3, 1, 2, 3 };
    const auto made = array.ContentRevision();
    EXPECT_EQ(array.WrittenBytes(), 0u);
    array.AssignHalf(0, quad);
    EXPECT_EQ(array.ContentRevision(), made) << "the first write appends to nothing";
    EXPECT_EQ(array.WrittenBytes(), 12u);
    array.AssignHalf(6, quad);
    EXPECT_EQ(array.ContentRevision(), made) << "an extension keeps the bytes before it";
    EXPECT_EQ(array.WrittenBytes(), 24u);
    // A write over bytes already written (a text relayout, a model's applyData) is new content,
    // even with the same values.
    array.AssignHalf(0, quad);
    EXPECT_NE(array.ContentRevision(), made);
    const auto rewritten = array.ContentRevision();
    array.AssignHalf(11, std::array<uint16_t, 1> { 7 });
    EXPECT_NE(array.ContentRevision(), rewritten) << "the last element was written before";

    // Another array never shares a revision, a copy included; a moved array keeps its own.
    SceneIndexArray other(4);
    EXPECT_NE(other.ContentRevision(), array.ContentRevision());
    const auto copy = array.Copy();
    EXPECT_NE(copy.ContentRevision(), array.ContentRevision());
    EXPECT_EQ(copy.WrittenBytes(), array.WrittenBytes());
    const auto before_move = array.ContentRevision();
    SceneIndexArray moved(std::move(array));
    EXPECT_EQ(moved.ContentRevision(), before_move);
    EXPECT_EQ(moved.WrittenBytes(), 24u);
}

TEST(SceneVertexArray, TheDrawnSizeHoldsUntilTheNextWrite) {
    SceneVertexArray array({ { "a_Position", VertexType::FLOAT2, false } }, 8);
    const std::array<float, 8> four { 1, 2, 3, 4, 5, 6, 7, 8 };
    array.SetVertexs(0, four);
    array.SetVertexs(4, four);
    EXPECT_EQ(array.DataSizeOf(), 16 * sizeof(float));
    EXPECT_EQ(array.DrawnSizeOf(), array.DataSizeOf()) << "nobody said what is drawn";
    // A later frame writes two vertices from the start: the high-water mark stays.
    array.SetVertexs(0, std::span<const float>(four.data(), 4));
    array.SetDrawnSize(4);
    EXPECT_EQ(array.DataSizeOf(), 16 * sizeof(float));
    EXPECT_EQ(array.DrawnSizeOf(), 4 * sizeof(float));
    array.SetDrawnSize(64);
    EXPECT_EQ(array.DrawnSizeOf(), array.DataSizeOf()) << "never past what was filled";
    array.SetDrawnSize(0);
    EXPECT_EQ(array.DrawnSizeOf(), 0u);
    // Any write after it, by any writer, makes the whole filled size count again.
    array.SetVertex("a_Position", std::span<const float>(four.data(), 2));
    EXPECT_EQ(array.DrawnSizeOf(), array.DataSizeOf());
}

TEST(ParticleIndex, LayoutSelectsUInt16UntilLastVertexFits) {
    const auto at_limit = PlanParticleIndexLayout(kMaxPackedUInt16Quads);
    ASSERT_TRUE(at_limit.ok);
    EXPECT_EQ(at_limit.width, SceneIndexWidth::UInt16);
    EXPECT_EQ(at_limit.vertex_count, 65536u);
    EXPECT_EQ(at_limit.index_count, kMaxPackedUInt16Quads * 6);
    EXPECT_EQ(at_limit.index_bytes, kMaxPackedUInt16Quads * 6 * 2);

    const auto empty = PlanParticleIndexLayout(0);
    ASSERT_TRUE(empty.ok);
    EXPECT_EQ(empty.width, SceneIndexWidth::UInt16);
}

TEST(ParticleIndex, LayoutSelectsUInt32WhenVertexIndexExceeds16Bit) {
    const auto over = PlanParticleIndexLayout(kMaxPackedUInt16Quads + 1);
    ASSERT_TRUE(over.ok);
    EXPECT_EQ(over.width, SceneIndexWidth::UInt32);
    EXPECT_EQ(over.vertex_count, (kMaxPackedUInt16Quads + 1) * 4);
    EXPECT_EQ(over.index_bytes, (kMaxPackedUInt16Quads + 1) * 6 * 4);
}

TEST(ParticleIndex, LayoutRejectsOverflowingQuadCounts) {
    const auto overflow = PlanParticleIndexLayout(std::numeric_limits<uint64_t>::max());
    EXPECT_FALSE(overflow.ok);
}

TEST(ParticleIndex, GeometryBudgetRejectsOversizeMeshes) {
    uint64_t bytes = 0;
    EXPECT_TRUE(ParticleGeometryFits(kMaxPackedUInt16Quads + 1, 28, &bytes));
    EXPECT_GT(bytes, 0u);

    const uint64_t too_many = (kMaxParticleGeometryBytes / 12) + 1;
    EXPECT_FALSE(ParticleGeometryFits(too_many, 28));
    EXPECT_FALSE(ParticleGeometryFits(std::numeric_limits<uint64_t>::max(), 28));
}

TEST(ParticleIndex, OverflowIsDetectedBeforeWidening) {
    // A uint16 product wrapping to a small number would have looked like it
    // still fitted. The plan uses uint64 throughout.
    const auto layout = PlanParticleIndexLayout(40000);
    ASSERT_TRUE(layout.ok);
    EXPECT_EQ(layout.width, SceneIndexWidth::UInt32);
    EXPECT_EQ(layout.vertex_count, 160000u);
    EXPECT_NE(static_cast<uint16_t>(40000u * 4u), 160000u);
}
} // namespace
