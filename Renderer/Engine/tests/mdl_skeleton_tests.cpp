// The skeleton block, the optional blocks behind it and the pose of a parsed model.
#include <cmath>
#include <limits>
#include <utility>

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
                   const SkeletonTail& tail = {}, std::vector<uint32_t> boneFlags = {}) {
    Bytes f = meshPart(meshVersion);
    writeSkeleton(f, skeletonVersion, bones, tail, std::move(boneFlags));
    return f;
}

// One root bone with an identity bind.
std::vector<BoneSpec> one() { return { { "root", kNone } }; }

void finish(Bytes& f) { f.stamp("MDLA", 0).u8(0); }

// Skeleton, then a version 6 animation block built by `body`.
template <class Body>
Bytes withAnimBlock(const std::vector<BoneSpec>& bones, Body body, int skeletonVersion = 3,
                    const SkeletonTail& tail = {}, std::vector<uint32_t> boneFlags = {}) {
    Bytes f = withSkeleton(skeletonVersion, bones, 21, tail, std::move(boneFlags));
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

TEST(MdlSkeleton, IkTailFollowedByAnAttachmentBlockStaysInSync) {
    // A: two IK targets, groups, a chain and the skin table, then one attachment.
    {
        SkeletonTail tail;
        tail.targets = { { "goal", 0, 1, { 1, 2, 0 } }, { "pole", 0, 0, { 3, 4, 0 } } };
        tail.table   = { 0.5f };
        tail.groups  = { { { 0, { 0.25f, 0.75f, 0 } } } };
        tail.chains  = { { 0, { 1 }, { { 0, { { 7, 4, 0, 0, { 0 } } } } } } };
        tail.skin    = true;
        tail.boneTable = true;
        tail.secondBoneTable = true;
        Bytes f = withSkeleton(3, one(), 21, tail);
        writeMdat(f, { { 0, "muzzle", { 4, 5, 6 } } });
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        EXPECT_FALSE(p.logged(kInfo, "skeleton body ended at"));
        EXPECT_FALSE(p.logged(kInfo, "malformed"));
        const auto& puppet = *p.mdl.puppet;
        ASSERT_EQ(puppet.ik_targets.size(), 2u);
        EXPECT_EQ(puppet.ik_targets[0].name, "goal");
        EXPECT_EQ(puppet.ik_targets[0].type, 1u);
        EXPECT_FLOAT_EQ(puppet.ik_targets[1].matrix.translation().y(), 4.0f);
        ASSERT_EQ(puppet.bone_neighbours.size(), 1u);
        ASSERT_EQ(puppet.bone_neighbours[0].size(), 1u);
        EXPECT_FLOAT_EQ(puppet.bone_neighbours[0][0].values[1], 0.75f);
        ASSERT_EQ(puppet.ik_chains.size(), 1u);
        EXPECT_EQ(puppet.ik_chains[0].targets, std::vector<uint32_t> { 1 });
        ASSERT_EQ(puppet.ik_chains[0].segments.size(), 1u);
        ASSERT_EQ(puppet.ik_chains[0].segments[0].links.size(), 1u);
        EXPECT_EQ(puppet.ik_chains[0].segments[0].links[0].flags, 4u);
        // The skin table after the IK description is read, not skipped with it.
        EXPECT_TRUE(puppet.bones[0].has_file_skin_pivot);
        ASSERT_EQ(puppet.attachments.size(), 1u);
        const auto& a = puppet.attachments[0];
        EXPECT_EQ(a.name, "muzzle");
        EXPECT_FLOAT_EQ(a.local_xform.translation().z(), 6.0f);
    }
    // B: a well-formed empty tail and two attachments.
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

TEST(MdlSkeleton, IkTargetCountSetsTheExtraAnimationTracks) {
    for (uint32_t n : { 1u, 3u }) {
        SCOPED_TRACE("targets " + std::to_string(n));
        SkeletonTail tail;
        for (uint32_t k = 0; k < n; ++k) {
            tail.targets.push_back({ "t" + std::to_string(k), 0, k % 2, { static_cast<float>(k), 0, 0 } });
        }
        const Bytes f = withAnimBlock(
            one(), [n](Bytes& b) {
                b.u32(1);
                writeAnim6(b, { .id = 101, .name = "reach", .storedExtraTracks = n });
            },
            3, tail);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_NE(p.mdl.puppet, nullptr);
        ASSERT_EQ(p.mdl.puppet->ik_targets.size(), n);
        ASSERT_EQ(p.mdl.puppet->anims.size(), 1u);
        const auto& anim = p.mdl.puppet->anims[0];
        EXPECT_EQ(anim.bone_tracks.size(), 1u);
        ASSERT_EQ(anim.target_tracks.size(), n);
        EXPECT_FLOAT_EQ(anim.target_tracks[0].frames.at(0).position.x(), 1001.0f);
        EXPECT_FALSE(p.logged(kInfo, "do not end at the MDLA block's declared end"));
    }
}

TEST(MdlSkeleton, VersionThreeAndFourReadTheReferencePose) {
    for (int version : { 3, 4 }) {
        SCOPED_TRACE("MDLS " + std::to_string(version));
        SkeletonTail tail;
        tail.reference = true;
        tail.targets   = { { "goal", 0, 0, { 1, 1, 0 }, { 2, 2, 0 } } };
        Bytes f = withSkeleton(version, { { "root", kNone, { 0, 0, 0 }, { 0, 5, 0 } } }, 21, tail);
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        const auto& puppet = *p.mdl.puppet;
        EXPECT_TRUE(puppet.bones[0].has_local_reference);
        EXPECT_FLOAT_EQ(puppet.bones[0].reference_position.y(), 5.0f);
        ASSERT_EQ(puppet.ik_targets.size(), 1u);
        EXPECT_TRUE(puppet.ik_targets[0].has_reference);
        EXPECT_FLOAT_EQ(puppet.ik_targets[0].reference.translation().x(), 2.0f);
    }
}

// we_ParseBoneSimulationJson 0x140265C30 (B-D2.1): flags take a JSON true only, the settings
// are read only for a bone that simulates (or does IK), and the defaults are the bone
// constructor's (sub_14026B860: mass 1000, inertia factors 1, ikd 2, ikrd 50).
TEST(MdlSkeleton, BoneSimulationJsonSetsFlagsAndParameters) {
    using Sim = WPPuppet::BoneSimulation;
    std::vector<BoneSpec> bones { { "spring", kNone }, { "number", 0 }, { "ik", 0 }, { "plain", 0 } };
    bones[0].simulation = R"({"se":true,"r":true,"rs":300,"rf":10,"t":true,"ts":50,"ri":30,)"
                          R"("tp":"100 0 0","rax":false,"ray":false,"raz":true,"la":true,)"
                          R"("lamin":"0 0 -3","lamax":"0 0 3","tm":200,"ge":true,"gd":"0 -1 0"})";
    bones[1].simulation = R"({"r":1,"se":true,"rs":300})";
    bones[2].simulation = R"({"ik":true,"r":true,"tf":20,"ikd":0,"ikr":true,"ikrd":0.5,"rs":300})";
    bones[3].simulation = R"({"tm":100,"tp":"100 0 0"})";
    Bytes f = withSkeleton(1, bones);
    finish(f);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    const auto& puppet = *p.mdl.puppet;
    ASSERT_EQ(puppet.bones.size(), 4u);

    const auto& s = puppet.bones[0].simulation;
    EXPECT_EQ(s.flags, Sim::kSpring | Sim::kRotation | Sim::kTranslation | Sim::kAngleLimit | Sim::kGravity |
                           Sim::kHoldTurnX | Sim::kHoldTurnY);
    EXPECT_TRUE(s.simulates());
    EXPECT_FLOAT_EQ(s.rot_stiffness, 300.0f);
    EXPECT_FLOAT_EQ(s.rot_friction, 10.0f);
    EXPECT_FLOAT_EQ(s.trans_stiffness, 50.0f);
    EXPECT_FLOAT_EQ(s.rot_inertia, 0.7f);
    EXPECT_FLOAT_EQ(s.trans_inertia, 1.0f) << "ti absent: the constructor's 1";
    EXPECT_FLOAT_EQ(s.tip.x(), 100.0f);
    EXPECT_FLOAT_EQ(s.tip_length, 1.0f);
    EXPECT_FLOAT_EQ(s.trans_max, 200.0f);
    EXPECT_FLOAT_EQ(s.angle_min.z(), -3.0f);
    EXPECT_FLOAT_EQ(s.angle_max.z(), 3.0f);
    EXPECT_FLOAT_EQ(s.gravity.y(), -1.0f);
    EXPECT_FLOAT_EQ(s.mass, 1000.0f);

    const auto& number = puppet.bones[1].simulation;
    EXPECT_EQ(number.flags, 0u) << "a number is not a flag: no rotation, so nothing is kept";
    EXPECT_FLOAT_EQ(number.rot_stiffness, 0.0f);

    const auto& ik = puppet.bones[2].simulation;
    EXPECT_EQ(ik.flags, Sim::kIk | Sim::kRotation | Sim::kIkRope);
    EXPECT_FALSE(ik.simulates());
    EXPECT_FLOAT_EQ(ik.trans_friction, 0.04f) << "an IK-only bone squares tf / 100";
    EXPECT_EQ(ik.ik_depth, 1);
    EXPECT_FLOAT_EQ(ik.ik_rope_damping, 1.0f);
    EXPECT_FLOAT_EQ(ik.rot_stiffness, 0.0f) << "rs is read only for a simulating bone";

    const auto& plain = puppet.bones[3].simulation;
    EXPECT_EQ(plain.flags, 0u);
    EXPECT_FLOAT_EQ(plain.tip.x(), 0.0f);
    EXPECT_FLOAT_EQ(plain.trans_max, 0.0f);
    EXPECT_EQ(plain.ik_depth, 2);
    EXPECT_FLOAT_EQ(plain.ik_rope_damping, 50.0f);
    EXPECT_TRUE(puppet.has_simulation);
}

TEST(MdlSkeleton, LinkRecordsReadFlagsFromVersionFourAndClampTheirWeight) {
    {
        SkeletonTail tail;
        tail.links = { { 0, 1, 2, 2, 7, 0.0f }, { 0, 1, 2, 0, 0, 0 } };
        tail.table = { 5, 6 };
        const Bytes f = withAnimBlock(
            one(), [](Bytes& b) {
                b.u32(1);
                writeAnim6(b, { .id = 101, .name = "links", .storedLinkCurves = 2 });
            },
            4, tail);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        const auto& puppet = *p.mdl.puppet;
        ASSERT_EQ(puppet.bone_links.size(), 2u);
        EXPECT_EQ(puppet.bone_links[0].flags, 2u);
        EXPECT_EQ(puppet.bone_links[0].extra_u32, 7u);
        EXPECT_FLOAT_EQ(puppet.bone_links[0].extra_f32, std::numeric_limits<float>::epsilon());
        EXPECT_EQ(puppet.bone_links[1].flags, 0u);
        EXPECT_EQ(puppet.bone_table, (std::vector<float> { 5, 6 }));
        EXPECT_FALSE(p.logged(kInfo, "skeleton body ended at"));
        ASSERT_EQ(puppet.anims.size(), 1u);
        ASSERT_EQ(puppet.anims[0].link_curves.size(), 2u);
        EXPECT_EQ(puppet.anims[0].link_curves[1].flags, 0u);
        EXPECT_EQ(puppet.anims[0].link_curves[1].values, (std::vector<float> { 0.5f, 0.25f }));
        EXPECT_FALSE(p.logged(kInfo, "do not end at the MDLA block's declared end"));
    }
    {
        // Version 3 has no flags word.
        SkeletonTail tail;
        tail.links = { { 0, 1, 2, 0, 0, 0 } };
        Bytes f = withSkeleton(3, one(), 21, tail);
        finish(f);
        const auto p = parse(f);
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.puppet->bone_links.size(), 1u);
        EXPECT_EQ(p.mdl.puppet->bone_links[0].link_b, 2u);
        EXPECT_FALSE(p.logged(kInfo, "skeleton body ended at"));
    }
}

TEST(MdlSkeleton, LinkCurveHeadersKeepTheDisabledBit) {
    SkeletonTail tail;
    tail.links      = { { 0, 0, 0, 1, 0, 0 } };
    const auto file = withAnimBlock(
        one(),
        [](Bytes& b) {
            b.u32(1);
            writeAnim6(b, { .storedLinkCurves = 1, .linkCurveFlags = 1 });
        },
        4,
        tail);
    const auto loaded = parse(file);
    ASSERT_TRUE(loaded.ok);
    const auto& curves = loaded.mdl.puppet->anims[0].link_curves;
    ASSERT_EQ(curves.size(), 1u);
    EXPECT_EQ(curves[0].flags, 1u);
    EXPECT_EQ(curves[0].values, (std::vector<float> { .5f, .25f }));
}

TEST(MdlSkeleton, BonesAnIkChainDrivesTakeNoAnimation) {
    // 0x140263b2c: bones whose flag word has bit 2, except the one a chain starts at.
    const std::vector<BoneSpec> bones { { "root", kNone }, { "upper", 0 }, { "lower", 1 }, { "free", 0 } };
    SkeletonTail tail;
    tail.targets = { { "goal", 2, 0, { 1, 1, 0 } } };
    tail.chains  = { { 1, { 0 }, {} } };
    const Bytes f = withAnimBlock(
        bones, [](Bytes& b) {
            b.u32(1);
            writeAnim6(b, { .id = 101, .name = "walk", .trackCount = 4, .storedExtraTracks = 1, .skeletonBones = 4 });
        },
        4, tail, { 0, 3, 3, 1 });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    const auto& tracks = p.mdl.puppet->anims.at(0).bone_tracks;
    ASSERT_EQ(tracks.size(), 4u);
    EXPECT_EQ(tracks[0].unk, 0);
    EXPECT_EQ(tracks[1].unk, 0) << "the chain's own bone keeps its animation";
    EXPECT_EQ(tracks[2].unk, 3);
    EXPECT_EQ(tracks[3].unk, 0);
}

TEST(MdlSkeleton, AMalformedIkTailIsDroppedButItsReferencePoseKept) {
    SkeletonTail tail;
    tail.reference = true;
    tail.targets   = { { "goal", 0, 0, { 1, 1, 0 } } };
    tail.chains    = { { 9, { 0 }, {} } }; // bone 9 of one
    tail.skin      = true;
    Bytes f = withSkeleton(4, { { "root", kNone, { 0, 0, 0 }, { 0, 5, 0 } } }, 21, tail);
    finish(f);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    const auto& puppet = *p.mdl.puppet;
    EXPECT_TRUE(p.logged(kInfo, "the skeleton tail is malformed"));
    EXPECT_TRUE(puppet.ik_targets.empty());
    EXPECT_TRUE(puppet.ik_chains.empty());
    EXPECT_TRUE(puppet.bones[0].has_local_reference);
    EXPECT_FALSE(puppet.bones[0].has_file_skin_pivot);
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

namespace {
// MDLA v4 stores a morph channel block per mesh, after the bone-alpha curves.
// 0x140264A18..0x140264CEF: presence byte; for each mesh flags, then (when bit 0
// is set) a scale, u16 curve count and u16 shape index + length-prefixed values.
Bytes morphAnimationFile(bool first_disabled, bool truncated = false) {
    const unsigned meshes = first_disabled ? 2 : 1;
    Bytes f = mdlFile(23, std::vector<MeshSpec>(meshes));
    writeSkeleton(f, 1, one());
    const auto end = beginBlock(f, "MDLA", 4);
    f.u32(1).i32(17).u32(0).cstr("morph").cstr("loop").f32(10).i32(1).u32(0).u32(1);
    f.u32(0).u32(72);
    for (unsigned frame = 0; frame < 2; ++frame) {
        f.f32(float(frame)).f32(0).f32(0);
        f.f32(0).f32(0).f32(0).f32(1).f32(1).f32(1);
    }
    f.u32(0).u8(0); // no texture-channel translation or bone-alpha curves
    f.u8(1);
    if (first_disabled) f.u32(0); // no scale/count follows a disabled mesh
    f.u32(1).f32(0.75f).u16(2);
    f.u16(0).u32(8).f32(-0.25f).f32(1.5f);
    f.u16(1).u32(8).f32(0.5f);
    if (!truncated) f.f32(0.25f).u32(1).u32(7).cstr("{\"tail\":true}");
    endBlock(f, end);
    f.u8(0);
    return f;
}
} // namespace

TEST(MdlSkeleton, MorphAnimationCurvesKeepTheFollowingEventsAndBoneTracks) {
    const auto p = parse(morphAnimationFile(false));
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    ASSERT_EQ(p.mdl.puppet->anims.size(), 1u);
    const auto& a = p.mdl.puppet->anims[0];
    ASSERT_EQ(a.morph_tracks.size(), 1u);
    EXPECT_FLOAT_EQ(a.morph_tracks[0].scale, 0.75f);
    ASSERT_EQ(a.morph_tracks[0].curves.size(), 2u);
    EXPECT_EQ(a.morph_tracks[0].curves[1].shape, 1u);
    EXPECT_EQ(a.morph_tracks[0].curves[0].values, (std::vector<float>{-0.25f, 1.5f}));
    ASSERT_EQ(a.events.size(), 1u);
    EXPECT_EQ(a.events[0].event_json, "{\"tail\":true}");
    ASSERT_EQ(a.bone_tracks.size(), 1u);
    ASSERT_EQ(a.bone_tracks[0].frames.size(), 2u);
    EXPECT_FLOAT_EQ(a.bone_tracks[0].frames[1].position.x(), 1.0f);
}

TEST(MdlSkeleton, DisabledMorphAnimationMeshDoesNotConsumeTheNextMeshChannels) {
    const auto p = parse(morphAnimationFile(true));
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    ASSERT_EQ(p.mdl.puppet->anims.size(), 1u);
    ASSERT_EQ(p.mdl.puppet->anims[0].morph_tracks.size(), 2u);
    EXPECT_TRUE(p.mdl.puppet->anims[0].morph_tracks[0].curves.empty());
    EXPECT_EQ(p.mdl.puppet->anims[0].morph_tracks[1].curves.size(), 2u);
    ASSERT_EQ(p.mdl.puppet->anims[0].events.size(), 1u);
    EXPECT_EQ(p.mdl.puppet->anims[0].events[0].time_value, 7u);
}

TEST(MdlSkeleton, TruncatedMorphAnimationCurveDropsAnimationWithoutLosingSkeleton) {
    const auto p = parse(morphAnimationFile(false, true));
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    EXPECT_EQ(p.mdl.puppet->bones.size(), 1u);
    EXPECT_TRUE(p.mdl.puppet->anims.empty());
}

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
    EXPECT_EQ(anims[0].morph_tracks.size(), 1u);
    ASSERT_EQ(anims[0].texture_channels.size(), 1u);
    EXPECT_EQ(anims[0].texture_channels[0], (std::vector<float> { 0.0f, 1.0f }));
    EXPECT_EQ(anims[0].blend_curves.size(), 1u);
    EXPECT_EQ(anims[0].scalar_curves.size(), 1u);
    EXPECT_TRUE(anims[0].has_aabb);
    p.mdl.puppet->prepared();
    EXPECT_NEAR(anims[0].max_time, 1.0 / 30.0, 1e-12);
}

// B-D9.2 (loader 0x140261880): the header word after the frame count is the clip's flags
// (anim+80); with bit 0 a clip record (source, start, end, origin offset, root bone) follows the
// version-6 curves, before the event list. A source that is not an earlier animation is refused.
TEST(MdlSkeleton, AnimationFlagsAndTheClipRecordAreRead) {
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(2);
        writeAnim6(b, { .id = 101, .name = "walk" });
        writeAnim6(b, { .id = 202, .name = "walk_rm", .flags = 0x1u | 0x400u | 0x800u | 0x8000u,
                        .clip = { 0, 0, 1, 0, 0 } });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    const auto& anims = p.mdl.puppet->anims;
    ASSERT_EQ(anims.size(), 2u);
    EXPECT_EQ(anims[0].flags, 0u);
    EXPECT_FALSE(anims[0].clip.has_value());
    EXPECT_EQ(anims[1].flags, 0x8C01u);
    ASSERT_TRUE(anims[1].clip.has_value());
    EXPECT_EQ(anims[1].clip->source, 0u);
    EXPECT_EQ(anims[1].clip->end, 1u);
    EXPECT_EQ(anims[1].clip->bone, 0u);
    ASSERT_EQ(anims[1].events.size(), 1u);
    EXPECT_EQ(anims[1].events[0].event_json, "{\"k\":\"v\"}");
    EXPECT_FALSE(p.logged(kInfo, "do not end at the MDLA block's declared end"));

    const Bytes forward = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 202, .name = "ahead", .flags = 0x1u, .clip = { 0, 0, 1, 0, 0 } });
    });
    const auto refused = parse(forward);
    EXPECT_TRUE(refused.mdl.puppet == nullptr || refused.mdl.puppet->anims.empty());
    EXPECT_TRUE(refused.logged(kError, "is not an earlier animation"));
}

TEST(MdlSkeleton, TextureChannelWeightsAreNumberedByRecordOrder) {
    // Each record after the bone tracks is one texture channel's weight a frame. Wallpaper
    // Engine numbers the channels by the records' order and ignores each record's leading
    // word: records led by 1 and then 0 are channels 0 and 1 (probe, 2026-10-25).
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 7, .name = "blink",
                        .channels = { { 1, { 0.5f, 0.5f } }, { 0, { 0.0f, 0.25f, 1.0f } }, { 9, {} } } });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    ASSERT_EQ(p.mdl.puppet->anims.size(), 1u);
    const auto& channels = p.mdl.puppet->anims[0].texture_channels;
    ASSERT_EQ(channels.size(), 3u);
    EXPECT_EQ(channels[0], (std::vector<float> { 0.5f, 0.5f }));
    EXPECT_EQ(channels[1], (std::vector<float> { 0.0f, 0.25f, 1.0f }));
    EXPECT_TRUE(channels[2].empty());
    EXPECT_FALSE(p.logged(kError, "MDLA"));
    EXPECT_FALSE(p.logged(kInfo, "do not end"));
}

TEST(MdlSkeleton, ATextureChannelWeightThatIsNotANumberPaintsNothing) {
    // Kept as 0 rather than failing the block, which would drop the bones' animation too.
    const Bytes f = withAnimBlock(one(), [](Bytes& b) {
        b.u32(1);
        writeAnim6(b, { .id = 7, .name = "blink",
                        .channels = { { 0, { std::numeric_limits<float>::infinity(),
                                             std::numeric_limits<float>::quiet_NaN(), 0.5f } } } });
    });
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_NE(p.mdl.puppet, nullptr);
    ASSERT_EQ(p.mdl.puppet->anims.size(), 1u);
    ASSERT_EQ(p.mdl.puppet->anims[0].texture_channels.size(), 1u);
    EXPECT_EQ(p.mdl.puppet->anims[0].texture_channels[0], (std::vector<float> { 0.0f, 0.0f, 0.5f }));
    EXPECT_EQ(p.mdl.puppet->anims[0].bone_tracks.size(), 1u);
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
Bytes countedMorphFile(uint32_t declared, uint32_t stored) {
    Bytes f = mdlFile(23, { MeshSpec {} });
    writeSkeleton(f, 1, one());
    finish(f);
    const size_t end = beginBlock(f, "MDMP", 1);
    f.u16(1).f32(12.5f).u32(declared);
    f.u32(9).u32(17).cstr("morph_a").u32(stored * 6);
    for (uint32_t i = 0; i < stored; ++i) f.u16(0x4900).u16(i & 0xFFFF).u16(0xBC00);
    endBlock(f, end);
    return f;
}

void writeMorphPosition(Bytes& f, uint32_t id, const char* name) {
    f.u32(id).u32(0).cstr(name).u32(6);
    // sub_14009C5C0: bytes follow the length directly, with no hash word.
    f.u16(0x4900).u16(0).u16(0xBC00);
}

Bytes flaggedMorphFile(uint32_t flags, uint32_t shape_id = 9, bool truncated = false) {
    MeshSpec mesh;
    mesh.flagA = flags;
    Bytes f = mdlFile(23, { mesh });
    writeSkeleton(f, 1, one());
    finish(f);
    const auto end = beginBlock(f, "MDMP", 1);
    f.u16(2).f32(1).u32(1);
    for (const char* name : { "first", "second" }) {
        writeMorphPosition(f, shape_id, name);
        if ((flags & 0x400) != 0) f.u32(6).u16(1).u16(2).u16(3);
        if ((flags & 0x800) != 0) f.u32(6).u16(4).u16(5).u16(6);
        if ((flags & 0x1000) != 0) {
            f.u32(2);
            if (truncated) { endBlock(f, end); return f; }
            f.u16(0x3C00);
        }
    }
    endBlock(f, end);
    return f;
}

Bytes modifierMorphFile(uint32_t bone) {
    MeshSpec mesh;
    mesh.flagA = 0x2000;
    Bytes f = mdlFile(23, { mesh });
    writeSkeleton(f, 1, one());
    finish(f);
    const auto end = beginBlock(f, "MDMP", 1);
    f.u16(1).f32(1).u32(1);
    writeMorphPosition(f, 9, "modified");
    f.u32(bone).u32(7).f32(-2.5f).f32(3.5f);
    endBlock(f, end);
    return f;
}
} // namespace

TEST(MdlSkeleton, MorphPositionBytesHaveNoHashOrShapeIdSelectedTrailer) {
    for (uint32_t id : { 0u, 9u }) {
        SCOPED_TRACE(id);
        const auto p = parse(flaggedMorphFile(0, id));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
        const auto& shapes = p.mdl.morph_sections[0].sections;
        ASSERT_EQ(shapes.size(), 2u);
        EXPECT_EQ(shapes[1].tag, "second");
        for (const auto& shape : shapes) {
            ASSERT_EQ(shape.vertices.size(), 1u);
            EXPECT_EQ(shape.vertices[0], (std::array<uint16_t, 3> { 0x4900, 0, 0xBC00 }));
        }
    }
}

TEST(MdlSkeleton, AZeroShapeMeshDoesNotConsumeTheNextMorphHeader) {
    Bytes f = mdlFile(23, { MeshSpec {}, MeshSpec {} });
    writeSkeleton(f, 1, one());
    finish(f);
    const auto end = beginBlock(f, "MDMP", 1);
    f.u16(0); // A mesh with no shapes has no parameter or vertex-count header.
    f.u16(1).f32(1).u32(1);
    writeMorphPosition(f, 9, "second-mesh");
    endBlock(f, end);
    const auto p = parse(f);
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.morph_sections.size(), 2u);
    EXPECT_TRUE(p.mdl.morph_sections[0].sections.empty());
    ASSERT_EQ(p.mdl.morph_sections[1].sections.size(), 1u);
    EXPECT_EQ(p.mdl.morph_sections[1].sections[0].tag, "second-mesh");
}

TEST(MdlSkeleton, OptionalMorphBlocksFollowMeshFlagsAndTheirOwnLengths) {
    for (uint32_t flags : { 0x400u, 0x800u, 0x1000u, 0x1C00u }) {
        SCOPED_TRACE(flags);
        const auto p = parse(flaggedMorphFile(flags));
        ASSERT_TRUE(p.ok);
        ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
        const auto& shapes = p.mdl.morph_sections[0].sections;
        ASSERT_EQ(shapes.size(), 2u);
        EXPECT_EQ(shapes[1].tag, "second") << "flagged blocks must not consume the next shape";
        ASSERT_EQ(shapes[1].vertices.size(), 1u);
        EXPECT_EQ(shapes[1].vertices[0], (std::array<uint16_t, 3> { 0x4900, 0, 0xBC00 }));
    }
}

TEST(MdlSkeleton, ATruncatedFlaggedMorphBlockIsNotAccepted) {
    const auto p = parse(flaggedMorphFile(0x1000, 9, true));
    ASSERT_TRUE(p.ok) << "bad optional metadata must not erase the skeleton";
    EXPECT_TRUE(p.mdl.morph_sections.empty());
}

TEST(MdlSkeleton, MorphMeshParametersAndClampedU32VertexCountsArePreserved) {
    for (const auto [declared, stored] : { std::pair { 70'000u, 1u }, std::pair { 65'537u, 65'537u } }) {
        SCOPED_TRACE(declared);
        const auto p = parse(countedMorphFile(declared, stored));
        ASSERT_TRUE(p.ok);
        EXPECT_EQ(p.mdl.mdmp, 1);
        ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
        const auto& section = p.mdl.morph_sections[0];
        EXPECT_FLOAT_EQ(section.mesh_parameter, 12.5f);
        EXPECT_EQ(section.vertex_count, stored);
        ASSERT_EQ(section.sections.size(), 1u);
        const auto& shape = section.sections[0];
        EXPECT_EQ(shape.shape_id, 9u);
        EXPECT_EQ(shape.unk_after_id, 17u);
        EXPECT_EQ(shape.tag, "morph_a");
        ASSERT_EQ(shape.vertices.size(), stored);
        EXPECT_EQ(shape.vertices.front(), (std::array<uint16_t, 3> { 0x4900, 0, 0xBC00 }));
        EXPECT_EQ(shape.vertices.back()[1], static_cast<uint16_t>((stored - 1) & 0xFFFF));
        EXPECT_TRUE(shape.data_400.empty());
        EXPECT_TRUE(shape.data_800.empty());
        EXPECT_TRUE(shape.data_1000.empty());
        EXPECT_FALSE(shape.modifier.has_value());
    }
}

TEST(MdlSkeleton, MorphBlocksRetainEveryMeshFlaggedPayload) {
    const auto p = parse(flaggedMorphFile(0x1C00));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
    ASSERT_EQ(p.mdl.morph_sections[0].sections.size(), 2u);
    for (const auto& shape : p.mdl.morph_sections[0].sections) {
        ASSERT_EQ(shape.data_400.size(), 1u);
        ASSERT_EQ(shape.data_800.size(), 1u);
        EXPECT_EQ(shape.data_400[0], (std::array<uint16_t, 3> { 1, 2, 3 }));
        EXPECT_EQ(shape.data_800[0], (std::array<uint16_t, 3> { 4, 5, 6 }));
        EXPECT_EQ(shape.data_1000, std::vector<uint16_t> { 0x3C00 });
    }
}

TEST(MdlSkeleton, MorphModifiersKeepTheirFieldsAndRejectAnUnknownBone) {
    const auto p = parse(modifierMorphFile(0));
    ASSERT_TRUE(p.ok);
    ASSERT_EQ(p.mdl.morph_sections.size(), 1u);
    ASSERT_EQ(p.mdl.morph_sections[0].sections.size(), 1u);
    const auto& modifier = p.mdl.morph_sections[0].sections[0].modifier;
    ASSERT_TRUE(modifier.has_value());
    EXPECT_EQ(modifier->bone, 0u);
    EXPECT_EQ(modifier->selector, 7u);
    EXPECT_EQ(modifier->parameters, (std::array<float, 2> { -2.5f, 3.5f }));
    const auto invalid = parse(modifierMorphFile(1));
    ASSERT_TRUE(invalid.ok);
    EXPECT_TRUE(invalid.mdl.morph_sections.empty());
}
