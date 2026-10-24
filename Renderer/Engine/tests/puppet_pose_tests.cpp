// In-memory puppets: how a stack of animation layers is sampled, mixed and controlled.
#include <cmath>
#include <limits>
#include <memory>
#include <vector>

#include <gtest/gtest.h>

#include "WPPuppet.hpp"

using namespace wallpaper;
using linalg::Affine3f;
using linalg::Vector3f;
using PlayMode = WPPuppet::PlayMode;
using Layer    = WPPuppetLayer::AnimationLayer;

namespace
{

constexpr double kQuarterTurn = 1.5707963267948966;

WPPuppet::Animation makeAnimation(int32_t id, PlayMode mode, double fps, int32_t length,
                                  const std::vector<Vector3f>& positions) {
    WPPuppet::Animation anim {};
    anim.id     = id;
    anim.fps    = fps;
    anim.length = length;
    anim.mode   = mode;
    WPPuppet::Animation::BoneTrack track;
    track.bone_index = 0;
    for (const auto& pos : positions) {
        WPPuppet::BoneFrame frame {};
        frame.position = pos;
        frame.angle    = Vector3f(0, 0, 0);
        frame.scale    = Vector3f(1, 1, 1);
        track.frames.push_back(frame);
    }
    anim.bone_tracks.push_back(track);
    return anim;
}

// One root bone; animation id 1 whose frames only move along y.
std::shared_ptr<WPPuppet> heightPuppet(PlayMode mode, double fps, int32_t length,
                                       const std::vector<float>& ys) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back();
    puppet->bones[0].name = "bone";
    std::vector<Vector3f> positions;
    for (float y : ys) positions.emplace_back(0.0f, y, 0.0f);
    puppet->anims.push_back(makeAnimation(1, mode, fps, length, positions));
    puppet->prepared();
    return puppet;
}

// The common fixture: fps 1, one second long, two frames.
std::shared_ptr<WPPuppet> singleShot(float from, float to) {
    return heightPuppet(PlayMode::Single, 1, 1, { from, to });
}

Layer layerSpec(int32_t id = 1, bool additive = false, double blend = 1.0) {
    Layer l;
    l.id       = id;
    l.additive = additive;
    l.blend    = blend;
    return l;
}

WPPuppetLayer layerOf(std::shared_ptr<WPPuppet> puppet, std::vector<Layer> stack) {
    WPPuppetLayer layer(std::move(puppet));
    layer.prepared(stack);
    return layer;
}

WPPuppetLayer additive(std::shared_ptr<WPPuppet> puppet, double blend = 1.0) {
    return layerOf(std::move(puppet), { layerSpec(1, true, blend) });
}

Affine3f pose(WPPuppetLayer& layer, double t, size_t bone = 0) {
    const auto frame = layer.genFrame(t);
    EXPECT_GT(frame.size(), bone);
    return frame.size() > bone ? frame[bone] : Affine3f::Identity();
}

float y(WPPuppetLayer& layer, double t) { return pose(layer, t).translation().y(); }

// Component-wise match, relative above one and absolute below it.
void expectClose(const Vector3f& got, const Vector3f& want, float eps = 1e-5f) {
    for (int i = 0; i < 3; ++i) {
        EXPECT_NEAR(got[i], want[i], eps * std::max(1.0f, std::fabs(want[i])))
            << "component " << i;
    }
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Sampling and holding
// ---------------------------------------------------------------------------------------------

TEST(PuppetPose, AdditiveSingleShotInterpolatesAndHoldsTheLastFrame) {
    auto layer = additive(singleShot(440, 0));
    EXPECT_FLOAT_EQ(y(layer, 0), 440);
    EXPECT_FLOAT_EQ(y(layer, 0.5), 220);
    EXPECT_FLOAT_EQ(y(layer, 1.0), 0);
    EXPECT_FLOAT_EQ(y(layer, 10.0), 0);

    struct Row {
        double t;
        float  want;
        float  slack;
    };
    const std::vector<float> ramp { 0, 10, 20, 30, 40 };
    {
        auto l = additive(heightPuppet(PlayMode::Single, 4, 4, ramp));
        const Row rows[] = { { 0, 0, 0 },     { 0.125, 5, 0 }, { 0.5, 20, 0 },
                             { 0.99, 39.6f, 1e-4f }, { 1.0, 40, 0 }, { 5.0, 40, 0 } };
        for (const auto& r : rows) {
            SCOPED_TRACE("single t " + std::to_string(r.t));
            if (r.slack > 0) EXPECT_NEAR(y(l, r.t), r.want, r.slack);
            else EXPECT_FLOAT_EQ(y(l, r.t), r.want);
        }
    }
    {
        auto l = additive(heightPuppet(PlayMode::Loop, 4, 4, ramp));
        const Row rows[] = { { 0, 0, 0 },     { 0.125, 5, 0 }, { 0.5, 20, 0 }, { 0.875, 35, 0 },
                             { 1.0, 0, 0 },   { 1.125, 5, 0 }, { 2.5, 20, 0 } };
        for (const auto& r : rows) {
            SCOPED_TRACE("loop t " + std::to_string(r.t));
            EXPECT_FLOAT_EQ(y(l, r.t), r.want);
        }
    }
    {
        auto l = additive(heightPuppet(PlayMode::Mirror, 4, 4, ramp));
        const Row rows[] = { { 0, 0, 0 },     { 0.5, 20, 0 },  { 1.0, 40, 0 },  { 1.25, 30, 0 },
                             { 1.5, 20, 0 },  { 1.99, 0.4f, 1e-4f }, { 2.0, 0, 0 }, { 2.25, 10, 0 } };
        for (const auto& r : rows) {
            SCOPED_TRACE("mirror t " + std::to_string(r.t));
            if (r.slack > 0) EXPECT_NEAR(y(l, r.t), r.want, r.slack);
            else EXPECT_FLOAT_EQ(y(l, r.t), r.want);
        }
    }
}

TEST(PuppetPose, CollapsedFirstPoseStaysFiniteAndWrapsAtOnePeriod) {
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 12, 16 });
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) frame.angle.z() = static_cast<float>(kQuarterTurn);
    puppet->anims[0].bone_tracks[0].frames[0].scale.y() = 0;
    puppet->prepared();
    auto layer = additive(puppet);
    const Vector3f v(2, 3, 0);

    const Vector3f start = pose(layer, 0) * v;
    expectClose(start, Vector3f(0, 14, 0));
    expectClose(pose(layer, 0.5) * v, Vector3f(-1.5f, 16, 0));
    expectClose(pose(layer, 1.0) * v, start);
}

TEST(PuppetPose, SeparateReferencePoseSurvivesAdditiveMixingAndWrap) {
    const auto build = [](float bindY, float refY) {
        auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 12, 16 });
        puppet->bones[0].local_bind = Affine3f::Identity();
        puppet->bones[0].local_bind.translate(Vector3f(0, bindY, 0));
        puppet->bones[0].local_reference = Affine3f::Identity();
        puppet->bones[0].local_reference.translate(Vector3f(0, refY, 0));
        puppet->bones[0].has_local_reference = true;
        puppet->prepared();
        return puppet;
    };
    const auto height = [](WPPuppetLayer& l, double t, float v) {
        return (pose(l, t) * Vector3f(0, v, 0)).y();
    };
    {
        auto puppet = build(100, 10);
        auto none   = layerOf(puppet, {});
        EXPECT_NEAR(height(none, 0, 103), 13, 1e-5);

        auto one = additive(puppet);
        EXPECT_NEAR(height(one, 0, 103), 15, 1e-5);
        EXPECT_NEAR(height(one, 0.5, 103), 17, 1e-5);
        EXPECT_NEAR(height(one, 1.0, 103), 15, 1e-5);
        EXPECT_NEAR(height(one, 1.0, 103), 15, 1e-5);

        auto halves = layerOf(puppet, { layerSpec(1, true, 0.5), layerSpec(1, true, 0.5) });
        EXPECT_NEAR(height(halves, 0, 103), 15, 1e-5);
    }
    {
        auto puppet = build(60, 5);
        auto none   = layerOf(puppet, {});
        EXPECT_NEAR(height(none, 0, 61), 6, 1e-5);
        auto one = additive(puppet);
        EXPECT_NEAR(height(one, 0, 61), 13, 1e-5);
        EXPECT_NEAR(height(one, 0.5, 61), 15, 1e-5);
    }
}

// ---------------------------------------------------------------------------------------------
// Blending
// ---------------------------------------------------------------------------------------------

TEST(PuppetPose, NonAdditiveLayersShareOneUnitOfPoseWeight) {
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 12, 16 });
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) {
        frame.angle = Vector3f(0, 0, 0.6f);
        frame.scale = Vector3f(2, 3, 1);
    }
    puppet->bones[0].local_bind = Affine3f::Identity();
    puppet->bones[0].local_bind.translate(Vector3f(0, 100, 0));
    puppet->bones[0].local_reference = Affine3f::Identity();
    puppet->bones[0].local_reference.translate(Vector3f(0, 10, 0));
    puppet->bones[0].has_local_reference = true;
    puppet->prepared();

    struct Setting {
        double b1, b2, total;
    };
    const Setting settings[] = { { 1, 1, 1 },     { 2, 1, 1 },       { 0.5, 0.5, 0.75 }, { 0.25, 0.5, 0.625 },
                                 { 0, 1, 1 },     { 1, 0, 1 },       { 0, 0, 0 } };
    for (const auto& s : settings) {
        SCOPED_TRACE("blends " + std::to_string(s.b1) + ", " + std::to_string(s.b2));
        auto layer = layerOf(puppet, { layerSpec(1, false, s.b1), layerSpec(1, false, s.b2) });
        const float W = static_cast<float>(s.total);
        for (double t : { 0.0, 0.5, 1.0, 1.0 }) {
            SCOPED_TRACE("t " + std::to_string(t));
            const float dy = t == 0.5 ? 4.0f : 2.0f;
            Affine3f expected = Affine3f::Identity();
            expected.translate(Vector3f(0, 10 + W * dy, 0));
            expected.rotate(linalg::AngleAxisf(0.6f * W, Vector3f::UnitZ()));
            expected.scale(Vector3f(1 + W, 1 + 2 * W, 1));
            expectClose(pose(layer, t) * Vector3f(2, 103, 0), expected * Vector3f(2, 3, 0));
        }
    }

    // Independent cross-checks of a few settings.
    {
        auto layer = layerOf(puppet, { layerSpec(1, false, 1), layerSpec(1, false, 1) });
        expectClose(pose(layer, 0) * Vector3f(2, 103, 0), Vector3f(-1.78044f, 21.68659f, 0), 1e-4f);
        expectClose(pose(layer, 0.5) * Vector3f(2, 103, 0), Vector3f(-1.78044f, 23.68659f, 0), 1e-4f);
    }
    {
        auto layer = layerOf(puppet, { layerSpec(1, false, 0.5), layerSpec(1, false, 0.5) });
        expectClose(pose(layer, 0) * Vector3f(2, 103, 0), Vector3f(-0.11068f, 19.77573f, 0), 1e-4f);
    }
    {
        auto layer = layerOf(puppet, { layerSpec(1, false, 0), layerSpec(1, false, 0) });
        for (double t : { 0.0, 0.5, 1.0 }) expectClose(pose(layer, t) * Vector3f(2, 103, 0), Vector3f(2, 13, 0));
    }

    // Three layers: weights 0.084, 0.18, 0.4 over an identity reference.
    {
        auto plain = heightPuppet(PlayMode::Loop, 1, 1, { 12, 16 });
        auto layer = layerOf(plain, { layerSpec(1, false, 0.2), layerSpec(1, false, 0.3), layerSpec(1, false, 0.4) });
        EXPECT_NEAR(y(layer, 0), 7.968, 1e-4);
        EXPECT_NEAR(y(layer, 0.5), 9.296, 1e-4);
    }
    // A single layer at a quarter weight.
    {
        auto layer = layerOf(heightPuppet(PlayMode::Loop, 1, 1, { 12, 16 }), { layerSpec(1, false, 0.25) });
        EXPECT_NEAR(y(layer, 0), 3, 1e-5);
        EXPECT_NEAR(y(layer, 0.5), 3.5, 1e-5);
    }
}

TEST(PuppetPose, DistinctMotionMixesAndAdditiveOffsetsRideOnTop) {
    auto puppet = singleShot(20, 40);
    {
        auto copy = puppet->anims[0];
        copy.id   = 2;
        for (auto& frame : copy.bone_tracks[0].frames) frame.position.y() += 40;
        puppet->anims.push_back(copy);
        puppet->prepared();
    }
    auto layer = layerOf(puppet, { layerSpec(1, false, 1), layerSpec(2, false, 3), layerSpec(1, true, 0.5) });
    EXPECT_FLOAT_EQ(y(layer, 0), 60);
    EXPECT_FLOAT_EQ(y(layer, 0.5), 75);
    EXPECT_TRUE(layer.setVisible(1, false));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 45);
    EXPECT_TRUE(layer.setVisible(1, true));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 75);
    EXPECT_TRUE(layer.setBlend(1, 1));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 65);

    auto big = additive(singleShot(20, 40), 2);
    EXPECT_FLOAT_EQ(y(big, 0), 40);
    EXPECT_FLOAT_EQ(y(big, 0.5), 60);
}

TEST(PuppetPose, FullWeightAnimationReplacesARotatedReferencePose) {
    const auto run = [](const Vector3f& axis, const Vector3f& angle, const Vector3f& vBindExpected,
                        const Vector3f& want) {
        auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
        puppet->bones[0].local_bind = Affine3f::Identity();
        puppet->bones[0].local_bind.rotate(linalg::AngleAxisf(static_cast<float>(kQuarterTurn), axis));
        for (auto& frame : puppet->anims[0].bone_tracks[0].frames) frame.angle = angle;
        puppet->prepared();
        const Vector3f vBind = puppet->bones[0].local_bind * Vector3f(1, 2, 3);
        expectClose(vBind, vBindExpected);
        auto layer = additive(puppet);
        expectClose(pose(layer, 0) * vBind, want);
    };
    const float q = static_cast<float>(kQuarterTurn);
    run(Vector3f::UnitX(), Vector3f(0, 0, q), Vector3f(1, -3, 2), Vector3f(-2, 1, 3));
    run(Vector3f::UnitY(), Vector3f(q, 0, 0), Vector3f(3, 2, -1), Vector3f(1, -3, 2));

    // Several axes at once: x first, then y, then z.
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) frame.angle = Vector3f(q, 0, q);
    puppet->prepared();
    auto layer = additive(puppet);
    expectClose(pose(layer, 0) * Vector3f(1, 2, 3), Vector3f(3, 1, 2));
}

TEST(PuppetPose, RotationInterpolatesAlongTheShortestArc) {
    // 10 degrees to 350 degrees is a 20 degree turn the short way round.
    const float deg = 3.14159265358979f / 180.0f;
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
    puppet->anims[0].bone_tracks[0].frames[0].angle = Vector3f(0, 0, 10 * deg);
    puppet->anims[0].bone_tracks[0].frames[1].angle = Vector3f(0, 0, 350 * deg);
    puppet->prepared();
    auto layer = additive(puppet);
    layer.genFrame(0);
    expectClose(pose(layer, 0.5) * Vector3f(1, 0, 0), Vector3f(1, 0, 0), 1e-4f);
}

TEST(PuppetPose, ChildBindIsComposedOntoItsParent) {
    const auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(2);
    puppet->bones[0].local_bind = Affine3f::Identity();
    puppet->bones[0].local_bind.translate(Vector3f(10, 20, 0));
    puppet->bones[0].local_bind.rotate(linalg::AngleAxisf(static_cast<float>(kQuarterTurn), Vector3f::UnitZ()));
    auto& child = puppet->bones[1];
    child.parent = child.bind_parent = child.anim_parent = child.file_parent = 0;
    child.local_bind = Affine3f::Identity();
    child.local_bind.translate(Vector3f(3, 0, 0));
    puppet->prepared();
    // The child's offset is turned by the parent's rotation.
    expectClose(puppet->bones[1].world_bind.translation(), Vector3f(10, 23, 0));
    // At rest every skin matrix is the identity.
    auto layer = layerOf(puppet, {});
    for (const auto& m : layer.genFrame(0)) expectClose(m * Vector3f(4, 5, 6), Vector3f(4, 5, 6));
}

// ---------------------------------------------------------------------------------------------
// Clock, rate and shared playback state
// ---------------------------------------------------------------------------------------------

TEST(PuppetClock, ElapsedTimeIsCountedOncePerAbsoluteTime) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back();
    puppet->anims.push_back(makeAnimation(7, PlayMode::Loop, 1, 2,
                                          { Vector3f(0, 0, 0), Vector3f(10, 0, 0), Vector3f(20, 0, 0) }));
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec(7, false, 1) });
    layer.genFrame(0);
    EXPECT_NEAR(layer.genFrame(0.5)[0].translation().x(), 5, 1e-5);
    EXPECT_NEAR(layer.genFrame(0.5)[0].translation().x(), 5, 1e-5);
    EXPECT_NEAR(layer.genFrame(0.75)[0].translation().x(), 7.5, 1e-5);
    EXPECT_NEAR(layer.genFrame(0.75)[0].translation().x(), 7.5, 1e-5);
    // A rewind does not move the animation back.
    EXPECT_NEAR(layer.genFrame(0.25)[0].translation().x(), 7.5, 1e-5);
}

TEST(PuppetClock, CopiesSharingStateSeeTheSameTimeControls) {
    auto L = additive(singleShot(0, 100));
    auto C = L;
    EXPECT_FLOAT_EQ(y(L, 0), 0);
    EXPECT_FLOAT_EQ(y(C, 0.5), 50);
    EXPECT_TRUE(L.pause(0));
    EXPECT_FLOAT_EQ(y(C, 0.5), 50);
    EXPECT_TRUE(L.setFrame(0, 0.25));
    EXPECT_FLOAT_EQ(y(C, 0.5), 25);
    EXPECT_TRUE(C.stop(0));
    EXPECT_FLOAT_EQ(y(L, 0.5), 0);
    EXPECT_TRUE(L.setFrame(0, 0.75));
    EXPECT_TRUE(L.play(0));
    EXPECT_FLOAT_EQ(y(C, 0.5), 75);
    EXPECT_FLOAT_EQ(y(C, 0.75), 100);
    EXPECT_FALSE(L.isPlaying(0));
    EXPECT_TRUE(L.play(0));
    EXPECT_FLOAT_EQ(y(C, 0.75), 0);
    EXPECT_TRUE(C.isPlaying(0));
    EXPECT_FLOAT_EQ(y(L, 1), 25);
}

TEST(PuppetClock, RateChangesAndRewindsKeepTheElapsedHighWaterMark) {
    auto L = additive(singleShot(0, 100));
    auto C = L;
    EXPECT_FLOAT_EQ(y(L, 0), 0);
    EXPECT_FLOAT_EQ(y(C, 0.25), 25);
    EXPECT_TRUE(L.setRate(0, 2));
    EXPECT_FLOAT_EQ(y(C, 0.25), 25);
    EXPECT_FLOAT_EQ(y(C, 0.375), 50);
    EXPECT_FLOAT_EQ(y(L, 0.125), 50);
    EXPECT_TRUE(C.setRate(0, 0.5));
    EXPECT_FLOAT_EQ(y(L, 0.375), 50);
    EXPECT_FLOAT_EQ(y(C, 0.5), 56.25f);
    EXPECT_TRUE(L.pause(0));
    EXPECT_FLOAT_EQ(y(C, 0.75), 56.25f);
    EXPECT_TRUE(C.play(0));
    EXPECT_FLOAT_EQ(y(L, 0.75), 56.25f);
    EXPECT_FLOAT_EQ(y(C, 1), 68.75f);

    // A negative rate clamps a single animation at its start.
    auto back = additive(singleShot(0, 100));
    EXPECT_FLOAT_EQ(y(back, 0), 0);
    EXPECT_FLOAT_EQ(y(back, 0.5), 50);
    EXPECT_TRUE(back.setRate(0, -2));
    EXPECT_FLOAT_EQ(y(back, 0.75), 0);
    EXPECT_FLOAT_EQ(static_cast<float>(back.frame(0)), 0);
    EXPECT_FLOAT_EQ(y(back, 1.0), 0);
    EXPECT_FLOAT_EQ(static_cast<float>(back.frame(0)), 0);
}

// ---------------------------------------------------------------------------------------------
// Layer-list controls
// ---------------------------------------------------------------------------------------------

TEST(PuppetControls, SharedBlendAndVisibilityChangeAnAlreadySampledPose) {
    auto L = additive(singleShot(40, 80));
    auto C = L;
    EXPECT_FLOAT_EQ(y(L, 0), 40);
    EXPECT_FLOAT_EQ(y(C, 0.5), 60);
    EXPECT_TRUE(L.setBlend(0, 0.5));
    EXPECT_FLOAT_EQ(y(C, 0.5), 30);
    EXPECT_TRUE(C.setVisible(0, false));
    EXPECT_FLOAT_EQ(y(L, 0.5), 0);
    EXPECT_TRUE(L.setVisible(0, true));
    EXPECT_FLOAT_EQ(y(C, 0.5), 30);
    EXPECT_TRUE(C.setBlend(0, 1));
    EXPECT_FLOAT_EQ(y(L, 0.5), 60);
    EXPECT_TRUE(L.setBlend(0, 1));
    EXPECT_TRUE(L.setVisible(0, true));
    EXPECT_FLOAT_EQ(y(C, 0.5), 60);
}

TEST(PuppetControls, PreparingAgainResetsTheLayerListButNotTheSharedClock) {
    auto puppet = singleShot(0, 100);
    Layer a = layerSpec(1);
    auto L  = layerOf(puppet, { a });
    auto C  = L;
    EXPECT_FLOAT_EQ(y(L, 0), 0);
    EXPECT_FLOAT_EQ(y(C, 0.5), 50);

    a.blend    = 0.5;
    a.cur_time = 0.25;
    {
        std::vector<Layer> stack { a };
        L.prepared(stack);
    }
    EXPECT_FLOAT_EQ(y(C, 0.5), 12.5f);
    {
        std::vector<Layer> stack { a };
        C.prepared(stack);
    }
    EXPECT_FLOAT_EQ(y(L, 0.5), 12.5f);
    EXPECT_FLOAT_EQ(y(C, 0.25), 12.5f);
    EXPECT_FLOAT_EQ(y(L, 0.75), 25);

    const auto expectIdentity = [](const Affine3f& m) {
        const auto id = Affine3f::Identity().matrix();
        for (int r = 0; r < 4; ++r)
            for (int c = 0; c < 4; ++c) EXPECT_NEAR(m.matrix()(r, c), id(r, c), 1e-5) << r << "," << c;
    };
    {
        std::vector<Layer> none;
        C.prepared(none);
    }
    expectIdentity(L.genFrame(0.75)[0]);

    // Preparing again keeps the clock running: time that passes afterwards still counts.
    {
        Layer again = layerSpec(1, false, 0.5);
        again.cur_time = 0.25;
        std::vector<Layer> stack { again };
        L.prepared(stack);
        EXPECT_FLOAT_EQ(y(C, 1.0), 25);
    }

    a.id = 999;
    {
        std::vector<Layer> stack { a };
        L.prepared(stack);
    }
    expectIdentity(C.genFrame(0.75)[0]);
    EXPECT_FALSE(C.setFrame(0, 0.5));

    // A non-finite starting time counts as zero.
    Layer nan = layerSpec(1);
    nan.cur_time = std::numeric_limits<double>::quiet_NaN();
    auto fresh = layerOf(puppet, { nan });
    EXPECT_FLOAT_EQ(y(fresh, 0), 0);
}

TEST(PuppetControls, RejectedControlsChangeNothing) {
    constexpr double nan = std::numeric_limits<double>::quiet_NaN();
    constexpr double inf = std::numeric_limits<double>::infinity();
    auto L = additive(singleShot(0, 100));
    auto C = L;
    EXPECT_FLOAT_EQ(y(L, 0), 0);
    EXPECT_FLOAT_EQ(y(C, 0.25), 25);

    EXPECT_FALSE(L.play(-1));
    EXPECT_FALSE(L.pause(1));
    EXPECT_FALSE(L.stop(1));
    EXPECT_FALSE(L.setFrame(1, 0));
    EXPECT_FALSE(L.setFrame(0, nan));
    EXPECT_FALSE(L.setFrame(0, inf));
    EXPECT_FALSE(L.setRate(1, 1));
    EXPECT_FALSE(L.setRate(0, nan));
    EXPECT_FALSE(L.setRate(0, inf));
    EXPECT_FALSE(L.setBlend(1, 1));
    EXPECT_FALSE(L.setBlend(0, nan));
    EXPECT_FALSE(L.setBlend(0, inf));
    EXPECT_FALSE(L.setVisible(1, false));

    EXPECT_FLOAT_EQ(y(C, 0.25), 25);
    EXPECT_FLOAT_EQ(y(C, 0.5), 50);

    // Frame requests are clamped to the animation.
    EXPECT_TRUE(L.setFrame(0, 5));
    EXPECT_FLOAT_EQ(static_cast<float>(L.frame(0)), 1);
    EXPECT_TRUE(L.setFrame(0, -3));
    EXPECT_FLOAT_EQ(static_cast<float>(L.frame(0)), 0);
    EXPECT_FLOAT_EQ(static_cast<float>(L.frameCount(0)), 1);
    EXPECT_FLOAT_EQ(static_cast<float>(L.fps(0)), 1);

    // On a looping animation the clamp shows: below the start pins frame 0, above the end
    // lands on the end, which wraps to the start.
    auto loop = additive(heightPuppet(PlayMode::Loop, 1, 4, { 0, 10, 20, 30, 40 }));
    loop.genFrame(0);
    EXPECT_TRUE(loop.setFrame(0, -3));
    EXPECT_FLOAT_EQ(static_cast<float>(loop.frame(0)), 0);
    EXPECT_TRUE(loop.setFrame(0, 2.5));
    EXPECT_FLOAT_EQ(static_cast<float>(loop.frame(0)), 2.5f);
    EXPECT_TRUE(loop.setFrame(0, 9));
    EXPECT_FLOAT_EQ(static_cast<float>(loop.frame(0)), 0);
}

// ---------------------------------------------------------------------------------------------
// State isolation and degenerate layers
// ---------------------------------------------------------------------------------------------

TEST(PuppetState, IndependentLayersNeverOverwriteAPoseAnotherCallerHolds) {
    auto puppet = singleShot(0, 100);
    auto A = additive(puppet);
    auto B = additive(puppet);
    auto S = A;
    A.genFrame(0);
    B.genFrame(0);
    const auto held = A.genFrame(0.25);
    ASSERT_EQ(held.size(), 1u);
    const Affine3f saved = held[0];
    EXPECT_FLOAT_EQ(y(B, 0.75), 75);
    const auto& m = held[0].matrix();
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) EXPECT_NEAR(m(r, c), saved.matrix()(r, c), 1e-5);

    EXPECT_TRUE(S.setFrame(0, 0.5));
    EXPECT_FLOAT_EQ(y(A, 0.25), 50);
    EXPECT_FLOAT_EQ(y(B, 0.75), 75);
    EXPECT_TRUE(B.stop(0));
    EXPECT_FLOAT_EQ(y(B, 0.75), 0);
    EXPECT_FLOAT_EQ(y(S, 0.25), 50);
}

TEST(PuppetState, LayersWithoutAPuppetAreSafeAndZeroBonePuppetsKeepPlaying) {
    for (int variant = 0; variant < 2; ++variant) {
        SCOPED_TRACE(variant == 0 ? "default layer" : "null puppet");
        WPPuppetLayer layer = variant == 0 ? WPPuppetLayer() : WPPuppetLayer(nullptr);
        std::vector<Layer> stack { layerSpec(1) };
        layer.prepared(stack);
        EXPECT_FALSE(layer.hasPuppet());
        EXPECT_TRUE(layer.genFrame(0).empty());
        EXPECT_EQ(layer.layerCount(), 0u);
        EXPECT_FALSE(layer.play(0));
        EXPECT_FALSE(layer.setFrame(0, 0));
    }

    auto puppet = singleShot(0, 100);
    puppet->bones.clear();
    puppet->prepared();
    auto L = additive(puppet);
    auto C = L;
    EXPECT_TRUE(L.hasPuppet());
    EXPECT_TRUE(L.genFrame(0).empty());
    EXPECT_TRUE(C.genFrame(0.5).empty());
    EXPECT_DOUBLE_EQ(L.frame(0), 0.5);
    EXPECT_TRUE(L.genFrame(1).empty());
    EXPECT_FALSE(C.isPlaying(0));
    EXPECT_TRUE(C.play(0));
    EXPECT_TRUE(L.genFrame(1).empty());
    EXPECT_DOUBLE_EQ(L.frame(0), 0);
    EXPECT_FLOAT_EQ(static_cast<float>(L.frameCount(0)), 1);
    EXPECT_FLOAT_EQ(static_cast<float>(L.fps(0)), 1);
    EXPECT_EQ(L.layerCount(), 1u);
}

// ---------------------------------------------------------------------------------------------
// World-anchored roots
// ---------------------------------------------------------------------------------------------

TEST(PuppetAnchoring, CentroidOffsetAppliesOnlyToWorldAnchoredRoots) {
    for (bool anchored : { true, false }) {
        SCOPED_TRACE(anchored ? "anchored" : "free");
        auto puppet = std::make_shared<WPPuppet>();
        puppet->bones.emplace_back();
        puppet->bones[0].vertex_centroid_offset = Vector3f(2, 0, 0);
        puppet->world_anchored_bones            = anchored;
        auto anim = makeAnimation(9, PlayMode::Loop, 1, 2,
                                  { Vector3f(0, 0, 0), Vector3f(0, 0, 0), Vector3f(0, 0, 0) });
        const float scaleX[] = { 1, 2, 3 };
        for (int i = 0; i < 3; ++i) anim.bone_tracks[0].frames[i].scale = Vector3f(scaleX[i], 1, 1);
        puppet->anims.push_back(anim);
        puppet->prepared();
        auto layer = layerOf(puppet, { layerSpec(9, false, 1) });
        layer.genFrame(0);
        EXPECT_NEAR(layer.genFrame(0.5)[0].translation().x(), anchored ? -1.0f : 0.0f, 1e-5);
    }

    // A child bone's own offset is never applied.
    for (bool anchored : { true, false }) {
        SCOPED_TRACE(anchored ? "anchored child" : "free child");
        auto puppet = std::make_shared<WPPuppet>();
        puppet->bones.resize(2);
        puppet->bones[0].vertex_centroid_offset = Vector3f(2, 0, 0);
        auto& child = puppet->bones[1];
        child.parent = child.bind_parent = child.anim_parent = child.file_parent = 0;
        child.local_bind = Affine3f::Identity();
        child.local_bind.translate(Vector3f(3, 0, 0));
        child.vertex_centroid_offset = Vector3f(5, 0, 0);
        puppet->world_anchored_bones = anchored;
        puppet->prepared();
        auto layer = layerOf(puppet, {});
        const auto frame = layer.genFrame(0);
        ASSERT_EQ(frame.size(), 2u);
        EXPECT_NEAR(frame[0].translation().x(), 0, 1e-5);
        EXPECT_NEAR(frame[1].translation().x(), 0, 1e-5);
    }
}
