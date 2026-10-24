#include "Scene/SceneMesh.h"

#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>
#include <utility>
#include <vector>

namespace wallpaper {
namespace {

SceneMaterial NamedMaterial(const char* name) {
    SceneMaterial material;
    material.name = name;
    return material;
}

void ExpectDrawRangeValues(std::span<const SceneMesh::DrawRange> actual,
                           std::span<const SceneMesh::DrawRange> expected) {
    ASSERT_EQ(actual.size(), expected.size());
    for (std::size_t i = 0; i < expected.size(); ++i) {
        SCOPED_TRACE(i);
        EXPECT_EQ(actual[i].indexOffset, expected[i].indexOffset);
        EXPECT_EQ(actual[i].indexCount, expected[i].indexCount);
    }
}

// M01: populated payload counts differ from capacity and enclosing array counts.
TEST(SceneMeshIndependentContract, GeometryAdditionExposesArrayAndPayloadCounts) {
    SceneMesh mesh;
    ASSERT_TRUE(mesh.Submeshes().empty());

    const std::vector<SceneVertexArray::SceneVertexAttribute> attributes{
        {"contract_position", VertexType::FLOAT2, true},
    };
    SceneVertexArray vertices(attributes, 2);
    const std::array<float, 2> position{0.375f, -0.625f};
    ASSERT_TRUE(vertices.AddVertex(position.data()));
    ASSERT_EQ(vertices.VertexCount(), 1u);

    const std::array<std::uint32_t, 3> indexValues{0u, 0u, 0u};
    SceneIndexArray indices{std::span<const std::uint32_t>{indexValues}};
    ASSERT_EQ(indices.DataCount(), 3u);

    mesh.AddVertexArray(std::move(vertices));
    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    mesh.AddIndexArray(std::move(indices));

    const SceneMesh& observed = mesh;
    ASSERT_EQ(observed.Submeshes().size(), 1u);
    ASSERT_EQ(observed.VertexCount(), 1u);
    ASSERT_EQ(observed.IndexCount(), 1u);

    const auto& submesh = observed.Submeshes().front();
    ASSERT_EQ(submesh.VertexCount(), 1u);
    ASSERT_EQ(submesh.IndexCount(), 1u);
    EXPECT_EQ(observed.GetVertexArray(0).VertexCount(), 1u);
    EXPECT_EQ(submesh.GetVertexArray(0).VertexCount(), 1u);
    EXPECT_EQ(observed.GetIndexArray(0).DataCount(), 3u);
    EXPECT_EQ(submesh.GetIndexArray(0).DataCount(), 3u);
}

// M02: appending a material preserves the first slot and the Material() alias.
TEST(SceneMeshIndependentContract, MaterialAppendPreservesOrderAndFirstIdentity) {
    SceneMesh mesh;
    mesh.AddMaterial(NamedMaterial("copper-base"));
    SceneMaterial* firstMaterial = mesh.Material();
    ASSERT_NE(firstMaterial, nullptr);

    mesh.AddMaterial(NamedMaterial("blue-detail"));

    const SceneMesh& observed = mesh;
    const auto& slots = observed.MaterialSlots();
    ASSERT_EQ(slots.size(), 2u);
    ASSERT_NE(slots[0].get(), nullptr);
    ASSERT_NE(slots[1].get(), nullptr);
    EXPECT_NE(slots[0].get(), slots[1].get());
    EXPECT_EQ(slots[0].get(), firstMaterial);
    EXPECT_EQ(slots[0]->name, "copper-base");
    EXPECT_EQ(slots[1]->name, "blue-detail");
    EXPECT_EQ(mesh.Material(), slots[0].get());
    EXPECT_EQ(observed.Material(), slots[0].get());
}

// M03: both overloads resolve occupied slots and reject the first missing slot.
TEST(SceneMeshIndependentContract, MaterialLookupHasMatchingConstBounds) {
    SceneMesh mesh;
    mesh.AddMaterial(NamedMaterial("foreground-ink"));
    mesh.AddMaterial(NamedMaterial("background-paper"));
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);

    SceneMaterial* first = mesh.MaterialForSlot(0);
    SceneMaterial* second = mesh.MaterialForSlot(1);
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    EXPECT_EQ(first, mesh.MaterialSlots()[0].get());
    EXPECT_EQ(second, mesh.MaterialSlots()[1].get());
    EXPECT_EQ(first->name, "foreground-ink");
    EXPECT_EQ(second->name, "background-paper");
    EXPECT_EQ(mesh.MaterialForSlot(2), nullptr);

    const SceneMesh& observed = mesh;
    const SceneMaterial* constFirst = observed.MaterialForSlot(0);
    const SceneMaterial* constSecond = observed.MaterialForSlot(1);
    ASSERT_NE(constFirst, nullptr);
    ASSERT_NE(constSecond, nullptr);
    EXPECT_EQ(constFirst, first);
    EXPECT_EQ(constSecond, second);
    EXPECT_EQ(constFirst->name, "foreground-ink");
    EXPECT_EQ(constSecond->name, "background-paper");
    EXPECT_EQ(observed.MaterialForSlot(2), nullptr);
}

// M04: marking dirty advances a generation even when the flag is already raised.
TEST(SceneMeshIndependentContract, DirtyMarkRaisesFlagAndAdvancesGeneration) {
    SceneMesh mesh;
    mesh.Dirty().store(false);
    const SceneMesh& observed = mesh;
    ASSERT_FALSE(observed.Dirty().load());
    const auto before = observed.DirtyGeneration();

    mesh.SetDirty();

    EXPECT_TRUE(observed.Dirty().load());
    const auto firstMark = observed.DirtyGeneration();
    EXPECT_GT(firstMark, before);

    mesh.SetDirty();

    EXPECT_TRUE(observed.Dirty().load());
    EXPECT_GT(observed.DirtyGeneration(), firstMark);
}

// M05: real geometry and submesh metadata cross the sharing boundary, not materials.
TEST(SceneMeshIndependentContract, SharedGeometryRetainsIndependentMaterials) {
    const std::vector<SceneVertexArray::SceneVertexAttribute> attributes{
        {"shared_position", VertexType::FLOAT2, true},
    };
    SceneVertexArray originalVertices(attributes, 1);
    const std::array<float, 2> originalPosition{-0.25f, 0.75f};
    ASSERT_TRUE(originalVertices.AddVertex(originalPosition.data()));
    ASSERT_EQ(originalVertices.VertexCount(), 1u);

    const std::array<std::uint32_t, 3> originalIndexValues{0u, 0u, 0u};
    SceneIndexArray originalIndices{
        std::span<const std::uint32_t>{originalIndexValues}};
    ASSERT_EQ(originalIndices.DataCount(), 3u);

    SceneMesh source;
    source.AddVertexArray(std::move(originalVertices));
    source.AddIndexArray(std::move(originalIndices));
    source.AddMaterial(NamedMaterial("source-canvas"));
    SceneMaterial* sourceMaterial = source.Material();
    ASSERT_NE(sourceMaterial, nullptr);

    SceneMesh destination;
    destination.AddMaterial(NamedMaterial("destination-overlay"));
    SceneMaterial* destinationMaterial = destination.Material();
    ASSERT_NE(destinationMaterial, nullptr);
    ASSERT_NE(destinationMaterial, sourceMaterial);

    destination.ChangeMeshDataFrom(source);

    ASSERT_EQ(source.Submeshes().size(), 1u);
    ASSERT_EQ(destination.Submeshes().size(), 1u);
    ASSERT_EQ(destination.VertexCount(), 1u);
    ASSERT_EQ(destination.IndexCount(), 1u);
    EXPECT_EQ(destination.GetVertexArray(0).VertexCount(), 1u);
    EXPECT_EQ(destination.GetIndexArray(0).DataCount(), 3u);

    SceneVertexArray appendedVertices(attributes, 2);
    const std::array<float, 2> appendedPosition{0.875f, -0.125f};
    ASSERT_TRUE(appendedVertices.AddVertex(appendedPosition.data()));
    ASSERT_EQ(appendedVertices.VertexCount(), 1u);
    destination.AddVertexArray(std::move(appendedVertices));

    const SceneMesh& observedSource = source;
    const SceneMesh& observedDestination = destination;
    ASSERT_EQ(observedSource.VertexCount(), 2u);
    ASSERT_EQ(observedDestination.VertexCount(), 2u);
    ASSERT_EQ(observedSource.Submeshes().front().VertexCount(), 2u);
    ASSERT_EQ(observedDestination.Submeshes().front().VertexCount(), 2u);
    EXPECT_EQ(observedSource.GetVertexArray(1).VertexCount(), 1u);
    EXPECT_EQ(observedDestination.GetVertexArray(1).VertexCount(), 1u);
    EXPECT_EQ(&observedSource.GetVertexArray(1),
              &observedDestination.GetVertexArray(1));

    destination.Submeshes().front().material_slot = 3u;
    destination.Submeshes().front().output_override = "auxiliary-lighting";
    EXPECT_EQ(observedSource.Submeshes().front().material_slot, 3u);
    EXPECT_EQ(observedSource.Submeshes().front().output_override,
              "auxiliary-lighting");

    ASSERT_EQ(observedSource.MaterialSlots().size(), 1u);
    ASSERT_EQ(observedDestination.MaterialSlots().size(), 1u);
    ASSERT_NE(observedSource.Material(), nullptr);
    ASSERT_NE(observedDestination.Material(), nullptr);
    EXPECT_EQ(observedSource.MaterialSlots().front().get(), sourceMaterial);
    EXPECT_EQ(observedDestination.MaterialSlots().front().get(), destinationMaterial);
    EXPECT_EQ(observedSource.Material(), sourceMaterial);
    EXPECT_EQ(observedDestination.Material(), destinationMaterial);
    EXPECT_NE(observedSource.Material(), observedDestination.Material());
    EXPECT_EQ(observedSource.Material()->name, "source-canvas");
    EXPECT_EQ(observedDestination.Material()->name, "destination-overlay");
}

// M06: setting ranges creates submesh zero and copies both ordered range values.
TEST(SceneMeshIndependentContract, DrawRangeAssignmentCreatesAndCopies) {
    SceneMesh mesh;
    ASSERT_TRUE(mesh.Submeshes().empty());

    const std::array<SceneMesh::DrawRange, 2> expected{{{3u, 6u}, {17u, 4u}}};
    auto input = expected;
    mesh.SetDrawRanges(std::span<const SceneMesh::DrawRange>{input});

    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    ExpectDrawRangeValues(mesh.DrawRanges(), expected);
    ExpectDrawRangeValues(mesh.Submeshes().front().DrawRanges(), expected);

    input[0] = {99u, 1u};
    input[1] = {0u, 12u};

    const SceneMesh& observed = mesh;
    ASSERT_EQ(observed.Submeshes().size(), 1u);
    ExpectDrawRangeValues(observed.DrawRanges(), expected);
    ExpectDrawRangeValues(observed.Submeshes().front().DrawRanges(), expected);
}

// M07: a genuinely const empty mesh remains empty after observing its ranges.
TEST(SceneMeshIndependentContract, ConstEmptyDrawRangeReadDoesNotCreateSubmesh) {
    const SceneMesh mesh;
    ASSERT_TRUE(mesh.Submeshes().empty());

    const auto& ranges = mesh.DrawRanges();

    EXPECT_TRUE(ranges.empty());
    EXPECT_TRUE(mesh.Submeshes().empty());
}

}  // namespace
}  // namespace wallpaper
