// The skeleton block, the optional blocks behind it and the pose of a parsed model.
#include <cmath>
#include <limits>

#include <gtest/gtest.h>

#include "mdl_fixtures.hpp"

using namespace wallpaper;
using namespace mdltest;

namespace
{

constexpr float kPi = 3.14159265358979f;

// Standard skinned triangle, version 21, no parts, with nothing after the mesh yet.
Bytes meshPart(int version = 21) {
    MeshSpec m;
    m.flag = kSkinned;
    return mdlFile(version, { m });
}

Bytes withSkeleton(int skeletonVersion, const std::vector<BoneSpec>& bones, int meshVersion = 21,
                   IkTail ik = IkTail::None) {
    Bytes f = meshPart(meshVersion);
    writeSkeleton(f, skeletonVersion, bones, ik);
    return f;
}

// One root bone with an identity bind.
std::vector<BoneSpec> one() { return { { "root", kNone } }; }

void finish(Bytes& f) { f.stamp("MDLA", 0).u8(0); }

// Skeleton, empty MDLA, then a version 6 block built by `body`.
template <class Body>
Bytes withAnimBlock(const std::vector<BoneSpec>& bones, Body body) {
    Bytes f = withSkeleton(3, bones);
    const size_t end = beginBlock(f, "MDLA", 6);
    body(f);
    endBlock(f, end);
    f.u8(0);
    return f;
}

void expectNear(const linalg::Vector3f& got, float x, float y, float z, float eps = 1e-5f) {
    EXPECT_NEAR(got.x(), x, eps);
    EXPECT_NEAR(got.y(), y, eps);
    EXPECT_NEAR(got.z(), z, eps);
}

// Skeleton + MDLE file used by the file-world-bind rows.
Bytes fileWorldBindFile(uint32_t payloadBytes, int matrices) {
    Bytes f = withSkeleton(1, { { "root", kNone }, { "kid", 0 } });
    f.stamp("MDLA", 0).u8(0).u8(0);
    const size_t end = beginBlock(f, "MDLE", 1);
    f.u32(payloadBytes);
    if (matrices >= 1) f.matrix(2, 3, 4);
    if (matrices >= 2) f.matrix(5, 6, 7);
    endBlock(f, end);
    return f;
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Bone hierarchy
// ---------------------------------------------------------------------------------------------

TEST(MdlSkeleton, BoneWhoseParentDoesNotComeFirstBecomesARoot) {
    struct Row {
        const char*           what;
        std::vector<BoneSpec> bones;
    };
    const Row rows[] = {
        { "parent 99", { { "root", kNone }, { "kid", 99 } } },
        { "itself", { { "root", kNone }, { "kid", 1 } } },
        { "later bone", { { "root", kNone }, { "kid", 2 } } },
        { "single bone naming itself", { { "kid", 0 } } },
    };
    for (const auto& row : rows) {
        SCOPED_TRACE(row.what);
        Bytes f = withSkeleton(1, row.bones);
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        const auto& bone = p.mdl.puppet->bones.back();
        EXPECT_TRUE(bone.noParent());
        EXPECT_EQ(bone.parent, WPPuppet::Bone::NO_PARENT);
        EXPECT_EQ(bone.bind_parent, WPPuppet::Bone::NO_PARENT);
        EXPECT_EQ(bone.anim_parent, WPPuppet::Bone::NO_PARENT);
        EXPECT_EQ(bone.file_parent, WPPuppet::Bone::NO_PARENT);
        EXPECT_TRUE(p.logged(kInfo, "that is not before it"));
    }
}

TEST(MdlSkeleton, FirstLevelHierarchyOfAVersionOneSkeleton) {
    const auto p = parse(twoMeshFile());
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    const auto& bones = p.mdl.puppet->bones;
    ASSERT_EQ(bones.size(), 4u);
    EXPECT_TRUE(bones[0].noParent());
    const uint32_t parents[] = { 0, 0, 1 };
    for (size_t i = 1; i < 4; ++i) {
        SCOPED_TRACE("bone " + std::to_string(i));
        EXPECT_EQ(bones[i].parent, parents[i - 1]);
        EXPECT_EQ(bones[i].bind_parent, parents[i - 1]);
        EXPECT_EQ(bones[i].anim_parent, parents[i - 1]);
        EXPECT_EQ(bones[i].file_parent, parents[i - 1]);
    }
}

namespace
{
std::vector<BoneSpec> chain() {
    return { { "a", kNone, { 10, 0, 0 } }, { "b", 0, { 3, 0, 0 } }, { "c", 1, { 2, 0, 0 } } };
}
} // namespace

TEST(MdlSkeleton, VersionOneRestPoseIsTheBindPoseThroughAChain) {
    Bytes f = withSkeleton(1, chain());
    finish(f);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    WPPuppetLayer layer(p.mdl.puppet);
    layer.prepared({});
    const auto frame = layer.genFrame(0.0);
    ASSERT_EQ(frame.size(), 3u);
    for (size_t i = 0; i < 3; ++i) {
        SCOPED_TRACE("bone " + std::to_string(i));
        expectNear(frame[i].translation(), 0, 0, 0);
    }
    EXPECT_EQ(p.mdl.puppet->bones[2].bind_parent, 1u);
    EXPECT_NEAR(p.mdl.puppet->bones[2].world_bind.translation().x(), 15.0f, 1e-5f);
}

TEST(MdlSkeleton, VersionThreeSkeletonKeepsHierarchyAndPivotsForMeshVersions) {
    for (int meshVersion : { 21, 23 }) {
        SCOPED_TRACE("mesh version " + std::to_string(meshVersion));
        Bytes f = withSkeleton(3, chain(), meshVersion);
        finish(f);
        const auto parsed = parse(f);
        ASSERT_TRUE(parsed.ok);
        auto puppet = parsed.mdl.puppet;
        ASSERT_NE(puppet, nullptr);
        EXPECT_FALSE(puppet->world_anchored_bones);
        EXPECT_EQ(puppet->bones[2].bind_parent, 1u);
        EXPECT_EQ(puppet->bones[2].anim_parent, 1u);
        EXPECT_NEAR(puppet->bones[2].world_bind.translation().x(), 15.0f, 1e-5f);

        // One animation: bone 0 turned a quarter turn about z, bone 2 collapsed in y.
        WPPuppet::Animation anim {};
        anim.id     = 1;
        anim.fps    = 1;
        anim.length = 1;
        anim.mode   = WPPuppet::PlayMode::Loop;
        for (uint32_t b = 0; b < 3; ++b) {
            WPPuppet::Animation::BoneTrack track;
            track.bone_index = b;
            for (int k = 0; k < 2; ++k) {
                WPPuppet::BoneFrame frame {};
                frame.position = puppet->bones[b].local_bind.translation();
                frame.scale    = linalg::Vector3f(1, 1, 1);
                frame.angle    = linalg::Vector3f(0, 0, b == 0 ? kPi / 2 : 0.0f);
                if (b == 2) frame.scale = linalg::Vector3f(1, 0, 1);
                track.frames.push_back(frame);
            }
            anim.bone_tracks.push_back(track);
        }
        puppet->anims.push_back(anim);
        puppet->prepared();

        WPPuppetLayer layer(puppet);
        std::vector<WPPuppetLayer::AnimationLayer> stack(1);
        stack[0].id       = 1;
        stack[0].additive = true;
        layer.prepared(stack);
        for (double t : { 0.0, 0.5, 0.5, 1.0 }) {
            SCOPED_TRACE("t " + std::to_string(t));
            const auto frame = layer.genFrame(t);
            ASSERT_EQ(frame.size(), 3u);
            expectNear(frame[2] * linalg::Vector3f(17, 3, 0), 10, 7, 0);
        }
    }
}

TEST(MdlSkeleton, VersionTwentyThreeFileWithVersionThreeSkeletonKeepsTheChain) {
    Bytes f = withSkeleton(3, chain(), 23);
    finish(f);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    const auto& bones = p.mdl.puppet->bones;
    ASSERT_EQ(bones.size(), 3u);
    EXPECT_FALSE(p.mdl.puppet->world_anchored_bones);
    EXPECT_TRUE(bones[0].noParent());
    EXPECT_EQ(bones[1].bind_parent, 0u);
    EXPECT_EQ(bones[1].anim_parent, 0u);
    EXPECT_EQ(bones[1].file_parent, 0u);
    EXPECT_EQ(bones[2].bind_parent, 1u);
    EXPECT_EQ(bones[2].anim_parent, 1u);
    EXPECT_EQ(bones[2].file_parent, 1u);
    WPPuppetLayer layer(p.mdl.puppet);
    layer.prepared({});
    const auto frame = layer.genFrame(0.0);
    ASSERT_EQ(frame.size(), 3u);
    for (const auto& m : frame) expectNear(m.translation(), 0, 0, 0);
}

TEST(MdlSkeleton, VersionTwoReferencePoseMovesBindVerticesWhenNothingAnimates) {
    struct Row {
        F3 bind, reference, vertex, expected;
    };
    const Row rows[] = {
        { { 50, 60, 0 }, { 5, 7, 0 }, { 53, 64, 0 }, { 8, 11, 0 } },
        { { 100, 200, 0 }, { 10, 20, 0 }, { 103, 204, 0 }, { 13, 24, 0 } },
    };
    for (const auto& row : rows) {
        Bytes f = withSkeleton(2, { { "root", kNone, row.bind, row.reference } });
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_TRUE(p.mdl.puppet->bones[0].has_local_reference);
        WPPuppetLayer layer(p.mdl.puppet);
        layer.prepared({});
        const auto moved = layer.genFrame(0)[0] * linalg::Vector3f(row.vertex[0], row.vertex[1], row.vertex[2]);
        expectNear(moved, row.expected[0], row.expected[1], row.expected[2]);
    }
}

// ---------------------------------------------------------------------------------------------
// Attachments (MDAT)
// ---------------------------------------------------------------------------------------------

TEST(MdlSkeleton, KinematicsExtrasAndFollowingAttachmentBlockStayInSync) {
    // A: a flag-2 tail with an opaque blob, then one attachment.
    {
        Bytes f = withSkeleton(3, one(), 21, IkTail::Opaque);
        writeMdat(f, { { 0, "muzzle", { 4, 5, 6 } } });
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_EQ(p.mdl.mdls, 3);
        ASSERT_EQ(p.mdl.puppet->attachments.size(), 1u);
        const auto& a = p.mdl.puppet->attachments[0];
        EXPECT_EQ(a.bone_index, 0);
        EXPECT_EQ(a.name, "muzzle");
        EXPECT_FLOAT_EQ(a.local_xform.translation().x(), 4.0f);
        EXPECT_FLOAT_EQ(a.local_xform.translation().y(), 5.0f);
        EXPECT_FLOAT_EQ(a.local_xform.translation().z(), 6.0f);
    }
    // A': the blob is opaque even when it looks like a skin table.
    {
        Bytes f = withSkeleton(3, one(), 21, IkTail::Loud);
        writeMdat(f, { { 0, "muzzle", { 4, 5, 6 } } });
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_FALSE(p.mdl.puppet->bones[0].has_file_skin_pivot);
        ASSERT_EQ(p.mdl.puppet->attachments.size(), 1u);
        EXPECT_EQ(p.mdl.puppet->attachments[0].name, "muzzle");
    }
    // B: a well-formed tail and two attachments.
    {
        Bytes f = withSkeleton(3, one());
        writeMdat(f, { { 0, "a", { 1, 2, 3 } }, { 0, "bb", { 7, 8, 9 } } });
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.puppet->attachments.size(), 2u);
        EXPECT_EQ(p.mdl.puppet->attachments[1].name, "bb");
        EXPECT_FLOAT_EQ(p.mdl.puppet->attachments[1].local_xform.translation().z(), 9.0f);
        EXPECT_FLOAT_EQ(p.mdl.puppet->attachments[0].local_xform.translation().x(), 1.0f);
    }
}

TEST(MdlSkeleton, AttachmentBlockEndingBeyondTheFileIsRejected) {
    {
        Bytes f = withSkeleton(1, one());
        f.stamp("MDAT", 1).u32(999999).u16(0);
        const auto p = parse(f);
        EXPECT_FALSE(p.ok);
        EXPECT_TRUE(p.logged(kError, "invalid end offset"));
    }
    {
        // The end offset points at the end-offset field itself.
        Bytes f = withSkeleton(1, one());
        const uint32_t own = static_cast<uint32_t>(f.size() + 9);
        f.stamp("MDAT", 1).u32(own).u16(0);
        const auto p = parse(f);
        EXPECT_FALSE(p.ok);
        EXPECT_TRUE(p.logged(kError, "invalid end offset"));
    }
    {
        // Only version 1 exists.
        Bytes f = withSkeleton(1, one());
        const size_t end = beginBlock(f, "MDAT", 2);
        f.u16(0);
        endBlock(f, end);
        EXPECT_FALSE(parse(f).ok);
    }
    {
        // A count the block cannot hold.
        Bytes f = withSkeleton(1, one());
        const size_t end = beginBlock(f, "MDAT", 1);
        f.u16(2000);
        endBlock(f, end);
        EXPECT_FALSE(parse(f).ok);
    }
    {
        // Control: the same block, empty, is fine.
        Bytes f = withSkeleton(1, one());
        writeMdat(f, {});
        finish(f);
        EXPECT_TRUE(parse(f).ok);
    }
}

TEST(MdlSkeleton, AttachmentNameThatNeverEndsInsideItsBlockIsRejected) {
    for (size_t n : { size_t { 12 }, size_t { 80 } }) {
        SCOPED_TRACE("name bytes " + std::to_string(n));
        Bytes f = withSkeleton(1, one());
        const size_t end = beginBlock(f, "MDAT", 1);
        f.u16(1).u16(0).fill(n, 'x');
        endBlock(f, end);
        const auto p = parse(f);
        EXPECT_FALSE(p.ok);
        if (n == 80) EXPECT_TRUE(p.logged(kError, "attachment is cut short"));
    }
}

TEST(MdlSkeleton, AttachmentMatrixRunningPastTheBlockIsRejected) {
    const auto build = [](const std::string& name, auto writeTail) {
        Bytes f = withSkeleton(1, one());
        const size_t end = beginBlock(f, "MDAT", 1);
        f.u16(1).u16(0).cstr(name);
        writeTail(f);
        endBlock(f, end);
        f.stamp("MDLA", 0).u8(0);
        return f;
    };
    const std::string shortName(6, 'n');
    const std::string longName(30, 'n');
    EXPECT_FALSE(parse(build(shortName, [](Bytes& f) { f.f32(1.0f); })).ok);
    EXPECT_FALSE(parse(build(longName, [](Bytes& f) {
                     for (int i = 0; i < 10; ++i) f.f32(1.0f);
                 })).ok);
    EXPECT_FALSE(parse(build(longName, [](Bytes& f) {
                     f.matrixWithFirst(std::numeric_limits<float>::infinity(), 1, 2, 3);
                 })).ok);
    const auto control = parse(build(longName, [](Bytes& f) { f.matrix(1, 2, 3); }));
    ASSERT_TRUE(control.ok);
    ASSERT_EQ(control.mdl.puppet->attachments.size(), 1u);
    EXPECT_EQ(control.mdl.puppet->attachments[0].name.size(), 30u);
}

// ---------------------------------------------------------------------------------------------
// Animations (MDLA)
// ---------------------------------------------------------------------------------------------

TEST(MdlSkeleton, AnimationBlockVersionSixParsesFully) {
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(2);
        writeAnim6(b, { .id = 101, .name = "intro" });
        writeAnim6(b, { .id = 202, .name = "idle" });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.mdla, 6);
    auto& anims = p.mdl.puppet->anims;
    ASSERT_EQ(anims.size(), 2u);
    EXPECT_EQ(anims[0].id, 101);
    EXPECT_EQ(anims[0].name, "intro");
    EXPECT_EQ(anims[1].id, 202);
    EXPECT_EQ(anims[1].name, "idle");
    ASSERT_EQ(anims[1].bone_tracks.size(), 1u);
    ASSERT_EQ(anims[1].bone_tracks[0].frames.size(), 1u);
    EXPECT_FLOAT_EQ(anims[1].bone_tracks[0].frames[0].position.x(), 202.0f);
    ASSERT_EQ(anims[1].events.size(), 1u);
    EXPECT_EQ(anims[1].events[0].event_json, "{\"k\":\"v\"}");
    EXPECT_EQ(anims[0].fps, 30.0);
    EXPECT_EQ(anims[0].length, 1);
    EXPECT_EQ(anims[0].mode, WPPuppet::PlayMode::Loop);
    EXPECT_TRUE(anims[0].trans.has_value());
    EXPECT_EQ(anims[0].v4_events.size(), 1u);
    EXPECT_EQ(anims[0].blend_curves.size(), 1u);
    EXPECT_EQ(anims[0].scalar_curves.size(), 1u);
    EXPECT_TRUE(anims[0].has_aabb);
    p.mdl.puppet->prepared();
    EXPECT_NEAR(anims[0].max_time, 1.0 / 30.0, 1e-12);
}

TEST(MdlSkeleton, UnparseableAnimationBlockDropsAnimationsButKeepsMeshAndBones) {
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 303, .name = "bad", .badSecondCurve = true });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(p.mdl.meshes.size(), 1u);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.puppet->bones.size(), 1u);
    EXPECT_TRUE(p.mdl.puppet->anims.empty());
    EXPECT_EQ(p.mdl.mdla, 6);
    EXPECT_TRUE(p.logged(kError, "MDLA"));
}

TEST(MdlSkeleton, AnimationCountThatCannotFitIsReported) {
    // 100000 is over the global cap; 60000 is under it and only fails for want of bytes.
    for (uint32_t count : { 100000u, 60000u }) {
        SCOPED_TRACE("count " + std::to_string(count));
        const Bytes f = withAnimBlock(one(), [count](Bytes& b) { b.u32(count); });
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_TRUE(p.mdl.puppet->anims.empty());
        EXPECT_TRUE(p.logged(kError, "MDLA animation count"));
    }
}

TEST(MdlSkeleton, ParsingResumesAtTheEndOfARejectedAnimationBlock) {
    Bytes f = withSkeleton(1, { { "root", kNone }, { "kid", 0 } });
    {
        const size_t end = beginBlock(f, "MDLA", 6);
        f.u32(100000).raw({ 0xDD, 0xCC, 0xBB, 0xAA, 0x44, 0x33, 0x22, 0x11 });
        endBlock(f, end);
    }
    {
        const size_t end = beginBlock(f, "MDLE", 1);
        f.u32(128).matrix(2, 3, 4).matrix(5, 6, 7);
        endBlock(f, end);
    }
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_TRUE(p.mdl.puppet->anims.empty());
    EXPECT_TRUE(p.logged(kError, "MDLA animation count"));
    EXPECT_EQ(p.mdl.mdle, 1);
    ASSERT_EQ(p.mdl.puppet->bones.size(), 2u);
    EXPECT_TRUE(p.mdl.puppet->bones[0].has_file_world_bind);
    EXPECT_TRUE(p.mdl.puppet->bones[1].has_file_world_bind);
    EXPECT_FLOAT_EQ(p.mdl.puppet->bones[0].file_world_bind.translation().x(), 2.0f);
    EXPECT_FLOAT_EQ(p.mdl.puppet->bones[1].file_world_bind.translation().z(), 7.0f);
}

TEST(MdlSkeleton, BoneTrackCountThatCannotFitIsReported) {
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 404, .name = "tracks", .trackCount = 100000, .headerOnly = true });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_TRUE(p.mdl.puppet->anims.empty());
    EXPECT_TRUE(p.logged(kError, "MDLA bone track count"));
}

TEST(MdlSkeleton, EventCountThatCannotFitIsReported) {
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 505, .name = "events", .jsonEventCount = 100000 });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_TRUE(p.mdl.puppet->anims.empty());
    EXPECT_TRUE(p.logged(kError, "MDLA event count"));
}

// ---------------------------------------------------------------------------------------------
// Extra matrices (MDLE), morph data (MDMP) and the trailing byte
// ---------------------------------------------------------------------------------------------

TEST(MdlSkeleton, ExtraMatricesSetTheFileWorldBindOfEveryBone) {
    {
        const auto p = parse(fileWorldBindFile(128, 2));
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_EQ(p.mdl.mdle, 1);
        ASSERT_EQ(p.mdl.puppet->bones.size(), 2u);
        EXPECT_TRUE(p.mdl.puppet->bones[0].has_file_world_bind);
        EXPECT_TRUE(p.mdl.puppet->bones[1].has_file_world_bind);
        EXPECT_FLOAT_EQ(p.mdl.puppet->bones[0].file_world_bind.translation().x(), 2.0f);
        EXPECT_FLOAT_EQ(p.mdl.puppet->bones[1].file_world_bind.translation().z(), 7.0f);
    }
    {
        // One matrix for two bones: the block is skipped.
        const auto p = parse(fileWorldBindFile(64, 1));
        ASSERT_TRUE(p.ok);
        EXPECT_EQ(p.mdl.mdle, 1);
        EXPECT_FALSE(p.mdl.puppet->bones[0].has_file_world_bind);
        EXPECT_FALSE(p.mdl.puppet->bones[1].has_file_world_bind);
        EXPECT_TRUE(p.logged(kInfo, "MDLE"));
    }
}

TEST(MdlSkeleton, OneNonZeroByteAfterTheLastBlockIsConsumedNotAnError) {
    Bytes f = fileWorldBindFile(128, 2);
    f.u8(0x7F);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.mdle, 1);
    EXPECT_TRUE(p.logged(kInfo, "sample.mdl"));
    EXPECT_TRUE(p.logged(kInfo, "byte after the last block"));
    EXPECT_TRUE(p.mdl.puppet->bones[0].has_file_world_bind);
}

namespace
{
Bytes morphFile(uint32_t shapeId, bool rawTrailer) {
    Bytes f = withSkeleton(1, one());
    finish(f);
    const size_t end = beginBlock(f, "MDMP", 1);
    f.u16(1).f32(12.5f).u16(42).u16(0);
    f.u32(shapeId).u32(0).cstr("morph_a").u32(6).u32(0x12345678);
    f.u16(0).u16(1).u16(2);
    if (rawTrailer) f.raw({ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 });
    else f.u16(0xBEEF);
    endBlock(f, end);
    return f;
}
} // namespace

TEST(MdlSkeleton, MorphBlockWithZeroIdShapeKeepsItsRawTrailer) {
    const auto p = parse(morphFile(0, true));
    ASSERT_TRUE(p.ok);
    EXPECT_EQ(p.mdl.mdmp, 1);
    ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
    const auto& sec = p.mdl.morph_sections[0];
    EXPECT_FLOAT_EQ(sec.event_time, 12.5f);
    EXPECT_EQ(sec.event_id, 42);
    ASSERT_EQ(sec.sections.size(), 1u);
    const auto& shape = sec.sections[0];
    EXPECT_EQ(shape.shape_id, 0u);
    EXPECT_EQ(shape.tag, "morph_a");
    EXPECT_EQ(shape.hash, 0x12345678u);
    ASSERT_EQ(shape.vertices.size(), 1u);
    EXPECT_EQ(shape.vertices[0][2], 2);
    ASSERT_EQ(shape.trailer.size(), 6u);
    EXPECT_EQ(shape.trailer[5], 0xA5);
    EXPECT_TRUE(shape.vertex_trailers.empty());
}

TEST(MdlSkeleton, MorphBlockWithNonZeroShapeIdCarriesPerVertexTrailers) {
    const auto p = parse(morphFile(9, false));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
    ASSERT_EQ(p.mdl.morph_sections[0].sections.size(), 1u);
    const auto& shape = p.mdl.morph_sections[0].sections[0];
    EXPECT_EQ(shape.shape_id, 9u);
    ASSERT_EQ(shape.vertex_trailers.size(), 1u);
    EXPECT_EQ(shape.vertex_trailers[0], 0xBEEF);
    EXPECT_TRUE(shape.trailer.empty());
}
