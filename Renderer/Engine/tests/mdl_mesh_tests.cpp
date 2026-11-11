// Mesh records of .mdl models (versions 13 to 23) and the geometry generated from them.
#include <gtest/gtest.h>

#include "mdl_fixtures.hpp"
#include "wpscene/WPMaterial.h"

using namespace wallpaper;
using namespace mdltest;

namespace
{

constexpr int kVersions[] = { 13, 14, 16, 17, 20, 21, 23 };

// Version 16 surface mesh used by the truncation rows.
Bytes surfaceFile(int version) {
    MeshSpec m;
    m.flag     = kPosition | kNormal | kTangent | kUv;
    m.material = "models/surface.json";
    Bytes f    = mdlFile(version, { m });
    f.u8(0);
    return f;
}

MeshSpec maskedMesh(std::vector<PartSpec> parts, std::vector<MaskSpec> masks) {
    MeshSpec m;
    m.flag  = kPosition | kUv;
    m.parts = std::move(parts);
    m.masks = std::move(masks);
    return m;
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Mesh records
// ---------------------------------------------------------------------------------------------

TEST(MdlMesh, SeveralMeshesAndPartsSectionsParseAheadOfTheSkeleton) {
    const auto p = parse(twoMeshFile());
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(p.mdl.mdlv, 21);
    EXPECT_EQ(p.mdl.mdl_header.mesh_count, 2u);
    ASSERT_EQ(p.mdl.meshes.size(), 2u);
    EXPECT_EQ(p.mesh(0).mat_json_file, "models/first.json");
    EXPECT_EQ(p.mesh(1).mat_json_file, "models/second.json");
    ASSERT_EQ(p.mesh(0).part_uv2.size(), 3u);
    for (size_t i = 0; i < 3; ++i) {
        EXPECT_EQ(p.mesh(0).part_uv2[i][0], 0.25f * static_cast<float>(i));
        EXPECT_EQ(p.mesh(0).part_uv2[i][1], 0.5f);
    }
    ASSERT_EQ(p.mesh(0).parts.size(), 1u);
    ASSERT_EQ(p.mesh(1).parts.size(), 1u);
    EXPECT_EQ(p.mesh(0).parts[0].id, 11u);
    EXPECT_EQ(p.mesh(1).parts[0].id, 22u);
    EXPECT_NE(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.mdls, 1);
    EXPECT_EQ(p.mdl.mdla, 0);
}

TEST(MdlMesh, SurfaceAttributesSurviveEveryFileVersion) {
    for (int version : kVersions) {
        SCOPED_TRACE("version " + std::to_string(version));
        const auto p = parse(surfaceFile(version));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.meshes.size(), 1u);
        const auto& m = p.mesh();
        ASSERT_EQ(m.positions.size(), 3u);
        ASSERT_EQ(m.normals.size(), 3u);
        ASSERT_EQ(m.tangents.size(), 3u);
        ASSERT_EQ(uvOf(m).size(), 3u);
        EXPECT_TRUE(m.blend_indices.empty());
        EXPECT_TRUE(m.blend_weights.empty());
        EXPECT_EQ(p.mdl.puppet, nullptr);
        for (int i = 0; i < 3; ++i) {
            EXPECT_EQ(m.positions[i], stdPosition(i));
            EXPECT_EQ(m.normals[i], stdNormal(i));
            EXPECT_EQ(m.tangents[i], stdTangent(i));
            EXPECT_EQ(uvOf(m)[i], stdUv(i));
        }
        EXPECT_EQ(m.indices, (std::vector<std::array<uint32_t, 3>> { { 0, 2, 1 } }));
        EXPECT_EQ(m.has_aabb, version >= 17);
        if (version >= 17) {
            EXPECT_EQ(m.aabb_min, (F3 { -1, -2, -3 }));
            EXPECT_EQ(m.aabb_max, (F3 { 4, 5, 6 }));
        }

        const auto mesh = generate(p.mdl, false);
        ASSERT_EQ(mesh->Submeshes().size(), 1u);
        const auto& va = mesh->GetVertexArray(0);
        EXPECT_EQ(va.VertexCount(), 3u);
        const auto map = va.GetAttrOffsetMap();
        EXPECT_TRUE(map.count("a_Position"));
        EXPECT_TRUE(map.count("a_Normal"));
        EXPECT_TRUE(map.count("a_Tangent4"));
        EXPECT_TRUE(map.count("a_TexCoord"));
        EXPECT_FALSE(map.count("a_BlendIndices"));
        const auto p0 = stdPosition(0);
        EXPECT_EQ(firstVertexAttr(va, "a_Position", 3), std::vector<float>(p0.begin(), p0.end()));
        EXPECT_EQ(firstVertexAttr(va, "a_Normal", 3), (std::vector<float> { 0, 0, 1 }));
        EXPECT_EQ(firstVertexAttr(va, "a_Tangent4", 4), (std::vector<float> { 1, 0, 0, 1 }));
        EXPECT_EQ(firstVertexAttr(va, "a_TexCoord", 2), (std::vector<float> { 0.1f, 0.9f }));
        const auto& ia = mesh->GetIndexArray(0);
        ASSERT_EQ(ia.DrawIndexCount(), 3u);
        const auto* idx = reinterpret_cast<const uint16_t*>(ia.Data());
        EXPECT_EQ(idx[0], 0);
        EXPECT_EQ(idx[1], 2);
        EXPECT_EQ(idx[2], 1);
        EXPECT_TRUE(mesh->Submeshes()[0].DrawRanges().empty());
    }
}

TEST(MdlMesh, SkinnedMeshesKeepBoneStreamsAndSkeletonForEveryVersion) {
    for (int version : kVersions) {
        for (bool surface : { false, true }) {
            SCOPED_TRACE("version " + std::to_string(version) + (surface ? " surface" : " plain"));
            MeshSpec m;
            m.flag = kSkinned | (surface ? (kNormal | kTangent) : 0u);
            Bytes f = mdlFile(version, { m });
            writeSkeleton(f, 1, { { "root", kNone }, { "child", 0 } });
            f.stamp("MDLA", 0).u8(0);
            const auto p = parse(f);
            ASSERT_TRUE(p.ok);
            ASSERT_EQ(p.mdl.meshes.size(), 1u);
            const auto& mm = p.mesh();
            ASSERT_EQ(mm.positions.size(), 3u);
            ASSERT_EQ(uvOf(mm).size(), 3u);
            ASSERT_EQ(mm.blend_indices.size(), 3u);
            ASSERT_EQ(mm.blend_weights.size(), 3u);
            for (int i = 0; i < 3; ++i) {
                EXPECT_EQ(mm.positions[i], stdPosition(i));
                EXPECT_EQ(uvOf(mm)[i], stdUv(i));
                EXPECT_EQ(mm.blend_indices[i], stdBoneIdx(i));
                EXPECT_EQ(mm.blend_weights[i], stdBoneWgt(i));
            }
            EXPECT_EQ(mm.normals.size(), surface ? 3u : 0u);
            EXPECT_EQ(mm.tangents.size(), surface ? 3u : 0u);
            ASSERT_NE(p.mdl.puppet, nullptr);
            ASSERT_EQ(p.mdl.puppet->bones.size(), 2u);
            EXPECT_EQ(p.mdl.puppet->bones[0].name, "root");
            EXPECT_EQ(p.mdl.puppet->bones[1].name, "child");
            EXPECT_EQ(p.mdl.puppet->bones[1].parent, 0u);
        }
    }
}

TEST(MdlMesh, SecondTexcoordLayoutYieldsBothCoordinateStreams) {
    MeshSpec m;
    m.flag = kPosition | kSkinIdx | kSkinWgt | kUvPair;
    ASSERT_EQ(strideOf(m.flag), 60u);
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.meshes.size(), 1u);
    const auto& mm = p.mesh();
    const auto uv  = uvOf(mm);
    const auto uv2 = uvOf(mm, 2);
    ASSERT_EQ(uv.size(), 3u);
    ASSERT_EQ(uv2.size(), 3u);
    EXPECT_EQ(uv[1], (F2 { 0.2f, 0.7f }));
    EXPECT_EQ(uv2[1], (F2 { 0.6f, 0.6f }));
    EXPECT_EQ(uv[2], (F2 { 0.3f, 0.5f }));
    EXPECT_EQ(uv2[2], (F2 { 0.9f, 0.6f }));
    EXPECT_EQ(mm.blend_indices.size(), 3u);
    EXPECT_EQ(mm.positions[2], stdPosition(2));
}

TEST(MdlMesh, MoreThanSixtyFiveThousandVerticesKeepWideIndices) {
    MeshSpec m;
    m.flag          = kPosition;
    m.vertices      = 65537;
    m.linePositions = true;
    m.indices       = { 0, 1, 65536 };
    const auto p    = parse(mdlFile(23, { m }, 0));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.meshes.size(), 1u);
    EXPECT_EQ(p.mesh().positions.size(), 65537u);
    ASSERT_EQ(p.mesh().indices.size(), 1u);
    EXPECT_EQ(p.mesh().indices[0], (std::array<uint32_t, 3> { 0, 1, 65536 }));

    const auto mesh = generate(p.mdl, false);
    ASSERT_EQ(mesh->Submeshes().size(), 1u);
    EXPECT_EQ(mesh->Submeshes()[0].IndexCount(), 1u);
    const auto& ia = mesh->GetIndexArray(0);
    EXPECT_EQ(ia.Width(), SceneIndexWidth::UInt32);
    EXPECT_EQ(ia.DrawIndexCount(), 3u);
    EXPECT_EQ(ia.Data()[2], 65536u);

    // Boundary: 65 535 vertices still fit narrow indices.
    MeshSpec narrow  = m;
    narrow.vertices  = 65535;
    narrow.indices   = { 0, 1, 65534 };
    const auto q     = parse(mdlFile(23, { narrow }, 0));
    ASSERT_TRUE(q.ok);
    const auto narrowMesh = generate(q.mdl, false);
    EXPECT_EQ(narrowMesh->GetIndexArray(0).Width(), SceneIndexWidth::UInt16);
}

TEST(MdlMesh, MeshOnlyFileIsACompleteModel) {
    MeshSpec m;
    m.flag  = kSkinned;
    m.parts = { { 10, 0, 3 } };
    Bytes f = mdlFile(21, { m });
    auto p  = parse(f);
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(p.mdl.mdlv, 21);
    EXPECT_EQ(p.mdl.mdl_header.mesh_count, 1u);
    ASSERT_EQ(p.mdl.meshes.size(), 1u);
    EXPECT_EQ(p.mesh().mat_json_file, "models/surface.json");
    EXPECT_EQ(p.mesh().positions.size(), 3u);
    ASSERT_EQ(p.mesh().parts.size(), 1u);
    EXPECT_EQ(p.mesh().parts[0].id, 10u);
    EXPECT_EQ(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.mdls, 0);
    EXPECT_EQ(p.mdl.mdla, 0);

    f.u8(0).u8(0);
    const auto padded = parse(f);
    EXPECT_TRUE(padded.ok);
    EXPECT_EQ(padded.mdl.puppet, nullptr);
}

TEST(MdlMesh, VersionTwentyThreeMasksAreConsumedWithoutDesynchronising) {
    // A: one mask over part position 0.
    {
        const auto p = parse(mdlFile(23, { maskedMesh({ { 1, 0, 3 } }, { { 7, "masks/m.json", { 0 }, { 0 } } }) }, 0));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.meshes.size(), 1u);
        ASSERT_EQ(p.mesh().masks.size(), 1u);
        EXPECT_EQ(p.mesh().masks[0].leading_a, 7u);
        EXPECT_EQ(p.mesh().masks[0].mat_json_file, "masks/m.json");
        EXPECT_EQ(p.mesh().masks[0].part_ids_a, (std::vector<uint32_t> { 0 }));
        EXPECT_EQ(p.mesh().masks[0].part_ids_b, (std::vector<uint32_t> { 0 }));
        EXPECT_EQ(p.mdl.puppet, nullptr);
    }
    // B: three parts, two masks with different list shapes.
    const auto richer = [] {
        return maskedMesh({ { 1, 0, 3 }, { 2, 3, 3 }, { 3, 6, 3 } },
                          { { 7, "masks/a.json", { 0, 2 }, { 1 } },
                            { 9, "masks/b.json", {}, { 2, 1, 0 } } });
    };
    {
        const auto p = parse(mdlFile(23, { richer() }, 0));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mesh().masks.size(), 2u);
        const auto& k0 = p.mesh().masks[0];
        const auto& k1 = p.mesh().masks[1];
        EXPECT_EQ(k0.leading_a, 7u);
        EXPECT_EQ(k0.mat_json_file, "masks/a.json");
        EXPECT_EQ(k0.part_ids_a, (std::vector<uint32_t> { 0, 2 }));
        EXPECT_EQ(k0.part_ids_b, (std::vector<uint32_t> { 1 }));
        EXPECT_EQ(k1.leading_a, 9u);
        EXPECT_EQ(k1.mat_json_file, "masks/b.json");
        EXPECT_TRUE(k1.part_ids_a.empty());
        EXPECT_EQ(k1.part_ids_b, (std::vector<uint32_t> { 2, 1, 0 }));
    }
    // C: the skeleton behind the masks is still found.
    {
        Bytes f = mdlFile(23, { richer() }, 0);
        writeSkeleton(f, 1, { { "only", kNone } });
        f.stamp("MDLA", 0).u8(0);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_EQ(p.mdl.puppet->bones.size(), 1u);
        EXPECT_EQ(p.mesh().masks.size(), 2u);
    }
}

TEST(MdlMesh, VertexPayloadCutShortRejectsTheFile) {
    const Bytes whole = surfaceFile(16);
    ASSERT_TRUE(parse(whole).ok);
    for (size_t removed : { size_t { 40 }, size_t { 11 }, size_t { 5 }, size_t { 2 } }) {
        SCOPED_TRACE("removed " + std::to_string(removed));
        EXPECT_FALSE(parse(whole.without(removed)).ok);
    }
    // The trailing zero byte is not needed.
    EXPECT_TRUE(parse(whole.without(1)).ok);
}

TEST(MdlMesh, ImpossibleMeshCountIsRejectedBeforeAllocation) {
    // Count with no mesh bytes behind it.
    Bytes header;
    header.stamp("MDLV", 21).u32(0).i32(0).u32(100000);
    EXPECT_FALSE(parse(header).ok);

    // A valid one-mesh file with the count field patched.
    const size_t countAt = 9 + 4 + 4;
    MeshSpec m;
    m.flag = kSkinned;
    for (uint32_t count : { 0u, 4097u, 2u }) {
        SCOPED_TRACE("count " + std::to_string(count));
        Bytes f = mdlFile(21, { m });
        f.patchU32(countAt, count);
        EXPECT_FALSE(parse(f).ok);
    }
    Bytes control = mdlFile(21, { m });
    EXPECT_TRUE(parse(control).ok);
}

TEST(MdlMesh, IncompleteHeaderIsRejectedAndReportedAsAnError) {
    {
        Bytes f;
        f.stamp("MDLV", 21).i32(9);
        const auto p = parse(f);
        EXPECT_FALSE(p.ok);
        EXPECT_TRUE(p.logged(kError, "is not complete"));
    }
    {
        Bytes f;
        f.stamp("MDLV", 21);
        const auto p = parse(f);
        EXPECT_FALSE(p.ok);
        EXPECT_TRUE(p.logged(kError, "is not complete"));
    }
}

TEST(MdlMesh, HeaderFlagNineIsMeaninglessForNewVersions) {
    MeshSpec m;
    m.flag  = kSkinned;
    m.parts = { { 1, 0, 3 } };
    const auto p = parse(mdlFile(23, { m }, 9));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.meshes.size(), 1u);
    EXPECT_EQ(p.mesh().flag, kSkinned);
    EXPECT_EQ(p.mdl.puppet, nullptr);
    EXPECT_TRUE(p.logged(kInfo, "sample.mdl"));
    EXPECT_TRUE(p.logged(kInfo, "header flag value 9"));
    EXPECT_EQ(p.mdl.mdl_header.mdl_flag, 0u);
    EXPECT_EQ(p.mdl.mdlv, 23);
}

TEST(MdlMesh, UnsupportedPartsSectionIsRejectedAndLogged) {
    for (uint32_t extras : { 2u, 255u }) {
        SCOPED_TRACE("extras " + std::to_string(extras));
        MeshSpec m;
        m.flag   = kSkinned;
        m.extras = extras;
        const auto p = parse(mdlFile(21, { m }));
        EXPECT_FALSE(p.ok);
        if (extras == 2) EXPECT_TRUE(p.logged(kError, "sample.mdl"));
    }
}

TEST(MdlMesh, VertexBlockPastTheEndOfTheFileIsRejected) {
    MeshSpec m;
    m.flag = kSkinned;
    m.vertices = 1;
    ASSERT_EQ(strideOf(m.flag), 52u);

    // (a) The declared 52 bytes are cut after 4.
    {
        Marks marks;
        Bytes f = mdlFile(21, { m }, std::nullopt, &marks);
        auto cut = f.data();
        cut.resize(marks.vertexStart + 4);
        EXPECT_FALSE(parse(cut).ok);
    }
    // (b) Every strict prefix of a complete file.
    {
        MeshSpec full;
        full.flag    = kSkinned;
        full.extras  = 1;
        full.payload = true;
        full.parts   = { { 1, 0, 3 } };
        const Bytes f = mdlFile(21, { full });
        ASSERT_TRUE(parse(f).ok);
        for (size_t len = 0; len < f.size(); ++len) {
            const std::vector<uint8_t> prefix(f.data().begin(), f.data().begin() + static_cast<std::ptrdiff_t>(len));
            EXPECT_FALSE(parse(prefix).ok) << "prefix of " << len << " bytes";
        }
    }
    // (c) A declared length that is no multiple of the stride, with the byte present.
    {
        Marks marks;
        MeshSpec odd = m;
        odd.indices = { 0, 0, 0 };
        EXPECT_TRUE(parse(mdlFile(21, { odd })).ok); // control: the same mesh, honestly declared
        odd.vertexBytes = 53;
        Bytes f = mdlFile(21, { odd }, std::nullopt, &marks);
        f.data().insert(f.data().begin() + static_cast<std::ptrdiff_t>(marks.vertexStart + 52), 0);
        EXPECT_FALSE(parse(f).ok);
    }
}

TEST(MdlMesh, PartsSectionCutShortIsRejected) {
    MeshSpec m;
    m.flag    = kSkinned;
    m.extras  = 1;
    m.payload = true;
    m.parts   = { { 1, 0, 3 } };
    const Bytes whole = mdlFile(21, { m });
    ASSERT_TRUE(parse(whole).ok);
    // has_parts byte (1) + table length (4) + one record (16) = 21 bytes.
    struct Row {
        const char* what;
        size_t      removed;
    };
    const Row rows[] = {
        { "inside the payload", 21 + 6 }, { "inside the table", 6 }, { "no parts section", 21 },
        { "length word missing", 20 },    { "record missing", 16 },
    };
    for (const auto& row : rows) {
        SCOPED_TRACE(row.what);
        EXPECT_FALSE(parse(whole.without(row.removed)).ok);
    }
}

TEST(MdlMesh, PartsTableOfPartialRecordsIsRejected) {
    for (uint32_t bytes : { 15u, 17u, 4u }) {
        SCOPED_TRACE("table bytes " + std::to_string(bytes));
        MeshSpec m;
        m.flag       = kSkinned;
        m.hasParts   = true;
        m.tableBytes = bytes;
        EXPECT_FALSE(parse(mdlFile(21, { m })).ok);
    }
}

TEST(MdlMesh, MaskBlockCutShortIsRejected) {
    const Bytes whole = mdlFile(23, { maskedMesh({ { 1, 0, 3 } }, { { 7, "masks/m.json", { 0 }, { 0 } } }) }, 0);
    ASSERT_TRUE(parse(whole).ok);
    for (size_t removed : { size_t { 4 }, size_t { 1 }, size_t { 8 } }) {
        SCOPED_TRACE("removed " + std::to_string(removed));
        EXPECT_FALSE(parse(whole.without(removed)).ok);
    }
}

// ---------------------------------------------------------------------------------------------
// Geometry generated from a parsed model
// ---------------------------------------------------------------------------------------------

TEST(MdlGeometry, EachMeshRecordBecomesASubmeshWithItsOwnSlotAndRange) {
    const auto p = parse(twoMeshFile());
    ASSERT_TRUE(p.ok);
    const auto mesh = generate(p.mdl);
    ASSERT_EQ(mesh->Submeshes().size(), 2u);
    for (size_t i = 0; i < 2; ++i) {
        const auto& s = mesh->Submeshes()[i];
        EXPECT_EQ(s.VertexCount(), 1u);
        EXPECT_EQ(s.IndexCount(), 1u);
        EXPECT_EQ(rangesOf(s), (std::vector<Range> { { 0, 3 } }));
        EXPECT_EQ(s.material_slot, i);
        EXPECT_TRUE(s.output_override.empty());
    }
    EXPECT_EQ(mesh->VertexCount(), 1u);
    EXPECT_EQ(mesh->IndexCount(), 1u);
    EXPECT_EQ(mesh->GetVertexArray(0).VertexCount(), 3u);
    // Three 16-bit indices round up to two 32-bit words.
    EXPECT_EQ(mesh->GetIndexArray(0).DataCount(), 2u);
    const auto* idx = reinterpret_cast<const uint16_t*>(mesh->GetIndexArray(0).Data());
    EXPECT_EQ(idx[0], 0);
    EXPECT_EQ(idx[1], 2);
    EXPECT_EQ(idx[2], 1);
}

namespace
{
std::vector<Range> rangesForPart(uint32_t start, uint32_t size) {
    MeshSpec m;
    m.flag  = kPosition | kUv;
    m.parts = { { 10, start, size } };
    const auto p = parse(mdlFile(21, { m }));
    EXPECT_TRUE(p.ok);
    const auto mesh = generate(p.mdl);
    EXPECT_EQ(mesh->Submeshes().size(), 1u);
    return mesh->Submeshes().empty() ? std::vector<Range> {} : rangesOf(mesh->Submeshes()[0]);
}
} // namespace

TEST(MdlGeometry, PartRangeBeyondTheEmittedIndicesDrawsNothing) {
    const std::vector<Range> nothing { { 0, 0 } };
    struct Row {
        uint32_t           start, size;
        std::vector<Range> expected;
    };
    const Row rows[] = {
        { 2, 2, nothing },       { 0, 4, nothing }, { 3, 1, nothing }, { 0, 0, nothing },
        { 3, 0, nothing },       { 1, 2, { { 1, 2 } } },               { 0, 3, { { 0, 3 } } },
    };
    for (const auto& row : rows) {
        SCOPED_TRACE("start " + std::to_string(row.start) + " size " + std::to_string(row.size));
        EXPECT_EQ(rangesForPart(row.start, row.size), row.expected);
    }

    // Several parts: the invalid middle one is dropped, the rest keep their order.
    MeshSpec m;
    m.flag    = kPosition | kUv;
    m.vertices = 4;
    m.indices = { 0, 1, 2, 1, 2, 3 };
    m.parts   = { { 1, 0, 3 }, { 2, 5, 3 }, { 3, 3, 3 } };
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    const auto mesh = generate(p.mdl);
    ASSERT_EQ(mesh->Submeshes().size(), 1u);
    EXPECT_EQ(rangesOf(mesh->Submeshes()[0]), (std::vector<Range> { { 0, 3 }, { 3, 3 } }));
}

TEST(MdlGeometry, PartRangeOverflowingThirtyTwoBitsIsOutOfRange) {
    EXPECT_EQ(rangesForPart(0xFFFFFFFFu, 1), (std::vector<Range> { { 0, 0 } }));
    EXPECT_EQ(rangesForPart(0xFFFFFFFEu, 3), (std::vector<Range> { { 0, 0 } }));
}

TEST(MdlGeometry, MasksProduceClippedBaseMaskPassAndClippedDraw) {
    // A: one part, one mask whose both lists name it.
    {
        const auto p = parse(mdlFile(23, { maskedMesh({ { 4, 0, 3 } }, { { 7, "masks/m.json", { 0 }, { 0 } } }) }, 0));
        ASSERT_TRUE(p.ok);
        const auto mesh = generate(p.mdl);
        ASSERT_EQ(mesh->Submeshes().size(), 3u);
        const auto& s = mesh->Submeshes();
        EXPECT_EQ(s[0].material_slot, 0u);
        EXPECT_EQ(rangesOf(s[0]), (std::vector<Range> { { 0, 0 } }));
        EXPECT_EQ(s[1].material_slot, 1u);
        EXPECT_EQ(s[1].output_override, "_rt_puppet_mask");
        EXPECT_EQ(rangesOf(s[1]), (std::vector<Range> { { 0, 3 } }));
        EXPECT_EQ(s[2].material_slot, 2u);
        EXPECT_TRUE(s[2].output_override.empty());
        EXPECT_EQ(rangesOf(s[2]), (std::vector<Range> { { 0, 3 } }));

        const auto bare = generate(p.mdl, false);
        ASSERT_EQ(bare->Submeshes().size(), 1u);
        EXPECT_EQ(rangesOf(bare->Submeshes()[0]), (std::vector<Range> { { 0, 3 } }));
    }
    // B: three triangles, lists A = {0, 2}, B = {1}.
    MeshSpec b = maskedMesh({ { 1, 0, 3 }, { 2, 3, 3 }, { 3, 6, 3 } },
                            { { 7, "masks/m.json", { 0, 2 }, { 1 } } });
    b.vertices = 4;
    b.indices  = { 0, 1, 2, 1, 2, 3, 0, 2, 3 };
    {
        const auto p = parse(mdlFile(23, { b }, 0));
        ASSERT_TRUE(p.ok);
        const auto mesh = generate(p.mdl);
        ASSERT_EQ(mesh->Submeshes().size(), 3u);
        EXPECT_EQ(rangesOf(mesh->Submeshes()[0]), (std::vector<Range> { { 3, 3 } }));
        EXPECT_EQ(mesh->Submeshes()[1].output_override, "_rt_puppet_mask");
        EXPECT_EQ(rangesOf(mesh->Submeshes()[1]), (std::vector<Range> { { 3, 3 } }));
        EXPECT_EQ(rangesOf(mesh->Submeshes()[2]), (std::vector<Range> { { 0, 3 }, { 6, 3 } }));
    }
    // C: two masked meshes take consecutive material slots.
    {
        const auto p = parse(mdlFile(23, { b, b }, 0));
        ASSERT_TRUE(p.ok);
        const auto mesh = generate(p.mdl);
        ASSERT_EQ(mesh->Submeshes().size(), 6u);
        for (size_t i = 0; i < 6; ++i) EXPECT_EQ(mesh->Submeshes()[i].material_slot, i);
    }
}

TEST(MdlGeometry, ANestedMaskIsMultipliedIntoTheMaskThatEnclosesIt) {
    // Wallpaper Engine links a mask to the first other mask that clips every piece it
    // is drawn from (sub_140261880 record +72), then draws the enclosing mask cleared
    // into the mask target, the nested one cleared into an intermediate, and
    // multiplies that in (sub_140208670, sub_14020D6A0).
    MeshSpec m = maskedMesh({ { 1, 0, 3 }, { 2, 3, 3 }, { 3, 6, 3 } },
                            { { 7, "masks/outer.json", { 1, 2 }, { 0 } },
                              { 7, "masks/inner.json", { 2 }, { 1 } } });
    m.vertices = 4;
    m.indices  = { 0, 1, 2, 1, 2, 3, 0, 2, 3 };
    const auto p = parse(mdlFile(23, { m }, 0));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mesh().masks.size(), 2u);
    EXPECT_EQ(p.mesh().masks[0].parent, -1);
    EXPECT_EQ(p.mesh().masks[1].parent, 0);
    EXPECT_EQ(wallpaper::WPMdlParser::MaskChain(p.mesh(), 1), (std::vector<uint32_t> { 0 }));

    const auto mesh = generate(p.mdl);
    const auto& s   = mesh->Submeshes();
    // base, outer mask, outer clipped, then for inner: outer mask, inner mask, multiply, clipped
    ASSERT_EQ(s.size(), 7u);
    for (size_t i = 0; i < s.size(); ++i) EXPECT_EQ(s[i].material_slot, i);
    EXPECT_EQ(s[1].output_override, "_rt_puppet_mask");
    EXPECT_TRUE(s[1].clear_output);
    EXPECT_EQ(s[3].output_override, "_rt_puppet_mask");
    EXPECT_TRUE(s[3].clear_output);
    EXPECT_EQ(rangesOf(s[3]), (std::vector<Range> { { 0, 3 } }));
    EXPECT_EQ(s[4].output_override, "_rt_puppet_mask_intermediate");
    EXPECT_TRUE(s[4].clear_output);
    EXPECT_EQ(rangesOf(s[4]), (std::vector<Range> { { 3, 3 } }));
    EXPECT_EQ(s[5].output_override, "_rt_puppet_mask");
    EXPECT_FALSE(s[5].clear_output) << "the multiply keeps what the enclosing mask drew";
    EXPECT_TRUE(s[6].output_override.empty());
    EXPECT_EQ(rangesOf(s[6]), (std::vector<Range> { { 6, 3 } }));
}

TEST(MdlGeometry, MasksThatEncloseEachOtherAreNotLinkedInALoop) {
    const auto p = parse(mdlFile(23, { maskedMesh({ { 1, 0, 3 }, { 2, 3, 3 } },
                                                  { { 7, "masks/a.json", { 1 }, { 0 } },
                                                    { 7, "masks/b.json", { 0 }, { 1 } } }) },
                                 0));
    ASSERT_TRUE(p.ok);
    for (std::size_t m = 0; m < 2; ++m) {
        const auto chain = wallpaper::WPMdlParser::MaskChain(p.mesh(), m);
        EXPECT_LT(chain.size(), 2u) << "mask " << m;
    }
}

TEST(MdlGeometry, MaskListsNamingMissingPartsStillProduceRenderableSubmeshes) {
    const auto p = parse(mdlFile(23, { maskedMesh({ { 4, 0, 3 } }, { { 7, "masks/m.json", { 99 }, { 100 } } }) }, 0));
    ASSERT_TRUE(p.ok);
    const auto mesh = generate(p.mdl);
    ASSERT_EQ(mesh->Submeshes().size(), 3u);
    EXPECT_EQ(rangesOf(mesh->Submeshes()[0]), (std::vector<Range> { { 0, 3 } }));
    EXPECT_EQ(rangesOf(mesh->Submeshes()[1]), (std::vector<Range> { { 0, 0 } }));
    EXPECT_EQ(rangesOf(mesh->Submeshes()[2]), (std::vector<Range> { { 0, 0 } }));
}

// ---------------------------------------------------------------------------------------------
// Stamps and failures that apply to every file
// ---------------------------------------------------------------------------------------------

TEST(MdlMesh, UnsupportedStampsAreRejectedWithTheirReason) {
    MeshSpec m;
    m.flag = kSkinned;
    for (int version : { 12, 24, 0 }) {
        SCOPED_TRACE("version " + std::to_string(version));
        const auto p = parse(mdlFile(version, { m }));
        EXPECT_FALSE(p.ok);
        EXPECT_TRUE(p.logged(kError, "unsupported MDL version"));
    }
    Bytes wrongMagic = mdlFile(21, { m });
    wrongMagic.data()[0] = 'X';
    const auto magic = parse(wrongMagic);
    EXPECT_FALSE(magic.ok);
    EXPECT_TRUE(magic.logged(kError, "bad MDLV stamp"));

    Bytes nonDigit = mdlFile(21, { m });
    nonDigit.data()[5] = 'A';
    EXPECT_FALSE(parse(nonDigit).ok);

    Bytes noNul = mdlFile(21, { m });
    noNul.data()[8] = 'X';
    EXPECT_FALSE(parse(noNul).ok);
}

TEST(MdlMesh, FailedParseLeavesTheModelDefaultAndMissingPathsDoNotThrow) {
    MeshSpec m;
    m.flag = kSkinned;
    Bytes f = mdlFile(21, { m });
    f.patchU32(9 + 4 + 4, 0);
    const auto p = parse(f);
    ASSERT_FALSE(p.ok);
    EXPECT_TRUE(p.mdl.meshes.empty());
    EXPECT_EQ(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.mdlv, 13);

    wallpaper::fs::VFS vfs;
    vfs.Mount("/assets", std::make_unique<wallpaper::test::MapFs>(wallpaper::test::MapFs::Files {}));
    WPMdl untouched;
    EXPECT_FALSE(WPMdlParser::Parse("missing.mdl", vfs, untouched));
}

// B-D7.1: every bit of Wallpaper Engine's 26-entry vertex table adds its own size to the
// record, in the table's order (0x140484A20 / 0x1404849B0).
TEST(MdlMesh, EveryWeVertexBitHasItsSize) {
    const std::pair<uint32_t, uint32_t> sizes[] = {
        { 0x10000, 16 }, { 0x2000000, 12 }, { 0x2, 12 }, { 0x4, 16 }, { 0x800000, 16 },
        { 0x1000000, 16 }, { 0x8, 8 }, { 0x10, 12 }, { 0x20, 16 }, { 0x40, 8 }, { 0x80, 12 },
        { 0x100, 16 }, { 0x200, 8 }, { 0x400, 12 }, { 0x800, 16 }, { 0x1000, 8 }, { 0x2000, 12 },
        { 0x4000, 16 }, { 0x20000, 8 }, { 0x40000, 12 }, { 0x80000, 16 }, { 0x100000, 8 },
        { 0x200000, 12 }, { 0x400000, 16 }, { 0x8000, 16 },
    };
    for (const auto& [bit, size] : sizes) {
        SCOPED_TRACE("bit " + std::to_string(bit));
        MeshSpec m;
        m.flag        = kPosition | bit;
        m.vertexBytes = 3 * (12 + size);
        const auto p  = parse(mdlFile(21, { m }));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mesh().positions.size(), 3u);
        EXPECT_EQ(p.mesh().positions[2], stdPosition(2));
    }
}

// A bit outside the table adds nothing to the record and keeps the mesh readable.
TEST(MdlMesh, ABitOutsideTheTableAddsNothing) {
    MeshSpec m;
    m.flag        = kPosition | kUv | 0x4000000;
    m.vertexBytes = 3 * 20;
    const auto p  = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(uvOf(p.mesh())[1], stdUv(1));
}

// A generic stream keeps its floats per vertex and reaches the shader under its attribute name.
TEST(MdlGeometry, EveryStoredStreamIsUploadedUnderItsAttribute) {
    MeshSpec m;
    m.flag       = kPosition | 0x2000000 | 0x8000 | 0x400;
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    const auto* color = p.mesh().FindStream(0x8000);
    ASSERT_NE(color, nullptr);
    EXPECT_EQ(color->width, 4u);
    EXPECT_FLOAT_EQ(color->values[4 + 2], streamValue(0x8000, 1, 2));
    const auto mesh = generate(p.mdl, false);
    const auto& va  = mesh->GetVertexArray(0);
    EXPECT_EQ(firstVertexAttr(va, "a_PositionC1", 3),
              (std::vector<float> { streamValue(0x2000000, 0, 0), streamValue(0x2000000, 0, 1),
                                    streamValue(0x2000000, 0, 2) }));
    EXPECT_EQ(firstVertexAttr(va, "a_Color", 1), (std::vector<float> { streamValue(0x8000, 0, 0) }));
    EXPECT_EQ(firstVertexAttr(va, "a_TexCoordVec3C2", 1), (std::vector<float> { streamValue(0x400, 0, 0) }));
    // The narrower name of that coordinate set reads the same bytes.
    const auto map = va.GetAttrOffsetMap();
    ASSERT_TRUE(map.count("a_TexCoordC2"));
    EXPECT_EQ(map.at("a_TexCoordC2").offset, map.at("a_TexCoordVec3C2").offset);
    EXPECT_FALSE(map.count("a_TexCoordVec4C2"));
}

// B-D7.2: a shader input binds by semantic, so `vec2 a_TexCoord` reads xy of a 0x20 stream.
TEST(MdlGeometry, LightmapUvReachesTexCoordVec4AndTexCoordStillReadsUv) {
    MeshSpec m;
    m.flag       = kPosition | kUvPair;
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    const auto mesh = generate(p.mdl, false);
    const auto& va  = mesh->GetVertexArray(0);
    const auto uv = stdUv(0), uv2 = stdUv2(0);
    EXPECT_EQ(firstVertexAttr(va, "a_TexCoordVec4", 4), (std::vector<float> { uv[0], uv[1], uv2[0], uv2[1] }));
    const auto map = va.GetAttrOffsetMap();
    ASSERT_TRUE(map.count("a_TexCoord"));
    EXPECT_EQ(map.at("a_TexCoord").offset, map.at("a_TexCoordVec4").offset);
    EXPECT_EQ(firstVertexAttr(va, "a_TexCoord", 2), (std::vector<float> { uv[0], uv[1] }));
}

// The morph layout stores only the four-wide position; a_Position reads its xyz.
TEST(MdlGeometry, AFourWidePositionAloneIsAlsoThePosition) {
    MeshSpec m;
    m.flag       = 0x10000;
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mesh().positions.size(), 3u);
    EXPECT_FLOAT_EQ(p.mesh().positions[1][2], streamValue(0x10000, 1, 2));
    const auto mesh = generate(p.mdl, false);
    const auto map  = mesh->GetVertexArray(0).GetAttrOffsetMap();
    ASSERT_TRUE(map.count("a_Position"));
    EXPECT_EQ(map.at("a_Position").offset, map.at("a_PositionVec4").offset);
}

TEST(SceneVertexArrayAlias, AnAliasReadsItsTargetAndNeverHidesARealAttribute) {
    SceneVertexArray va({ { "a_Position", VertexType::FLOAT3 }, { "a_TexCoordVec4", VertexType::FLOAT4 } }, 1);
    va.AddAlias("a_TexCoord", "a_TexCoordVec4");
    va.AddAlias("a_Position", "a_TexCoordVec4");
    va.AddAlias("a_Normal", "a_Missing");
    const auto map = va.GetAttrOffsetMap();
    EXPECT_EQ(map.at("a_TexCoord").offset, 16u);
    EXPECT_EQ(map.at("a_TexCoord").attr.name, "a_TexCoord");
    EXPECT_EQ(map.at("a_Position").offset, 0u);
    EXPECT_FALSE(map.count("a_Normal"));
    SceneVertexArray moved(std::move(va));
    EXPECT_TRUE(moved.GetAttrOffsetMap().count("a_TexCoord"));
}

// we_LoadMdlModel 0x140261880: bit 2 of the mesh flag word is followed by one more word,
// whatever the other bits.
TEST(MdlMesh, AMeshFlagWordWithBitTwoReadsOneMoreWord) {
    MeshSpec m;
    m.flag       = kSkinned;
    m.flagA      = 6;
    const auto p = parse(mdlFile(21, { m }));
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(p.mesh().flag_a, 6u);
    EXPECT_TRUE(p.mesh().has_flag_a2_one);
    EXPECT_EQ(p.mesh().positions[1], stdPosition(1));
}

// D5.1 (0x140206AE0): the first mesh's flag word bit 4 makes a skinned model SKINNING_ALPHA.
TEST(MdlGeometry, SkinningAlphaFlagAddsTheCombo) {
    for (const uint32_t flagA : { 0u, 4u }) {
        SCOPED_TRACE(flagA);
        MeshSpec m;
        m.flag  = kSkinned;
        m.flagA = flagA;
        Bytes f = mdlFile(21, { m });
        writeSkeleton(f, 1, { { "root", kNone } });
        f.stamp("MDLA", 0).u8(0);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_EQ(p.mdl.puppet->bone_alpha, flagA == 4);
        wpscene::WPMaterial mat;
        WPMdlParser::AddPuppetMatInfo(mat, p.mdl);
        EXPECT_EQ(mat.combos.count("SKINNING_ALPHA"), flagA == 4 ? 1u : 0u);
    }
}
