// In-memory puppets: how a stack of animation layers is sampled, mixed and controlled.
#include <bit>
#include <cmath>
#include <limits>
#include <memory>
#include <vector>

#include <gtest/gtest.h>

#include <nlohmann/json.hpp>

#include "WPPuppet.hpp"
#include "Scene/Parse/WPPuppetIk.hpp"
#include "wpscene/WPImageObject.h"

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

TEST(PuppetPose, AReadOnlyPaletteKeepsTheLastCompletedPoseWithoutEvaluating) {
    auto layer = layerOf(singleShot(10, 20), { layerSpec() });
    EXPECT_TRUE(layer.lastFrame().empty()) << "no pose has been evaluated yet";
    EXPECT_FLOAT_EQ(y(layer, 0), 10);
    ASSERT_EQ(layer.lastFrame().size(), 1u);
    EXPECT_FLOAT_EQ(layer.lastFrame()[0].translation().y(), 10);
    ASSERT_TRUE(layer.setFrame(0, 1));
    EXPECT_FLOAT_EQ(layer.lastFrame()[0].translation().y(), 10) << "a read must not run the pending frame change";
    EXPECT_FLOAT_EQ(y(layer, 0), 20);
    EXPECT_FLOAT_EQ(layer.lastFrame()[0].translation().y(), 20);
}

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

namespace
{
// The z turn left after nlerping, layer by layer, from no turn toward `angle`
// with each weight (Wallpaper Engine's rotation blend, 0x1401F9020).
float zTurnAfterNlerps(const std::vector<double>& weights, double angle) {
    double w = 1.0, z = 0.0;
    const double sw = std::cos(angle * 0.5), sz = std::sin(angle * 0.5);
    for (const double k : weights) {
        double nw = (1.0 - k) * w + k * sw, nz = (1.0 - k) * z + k * sz;
        const double n = std::sqrt(nw * nw + nz * nz);
        w = nw / n;
        z = nz / n;
    }
    return static_cast<float>(2.0 * std::atan2(z, w));
}
} // namespace

TEST(PuppetPose, NonAdditiveLayersLerpInOrder) {
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

    // Each layer lerps the running pose toward its sample; a whole layer
    // replaces it. W is the share of the sample left at the end.
    struct Setting {
        double b1, b2, total;
    };
    const Setting settings[] = { { 1, 1, 1 },     { 2, 1, 1 },       { 0.5, 0.5, 0.75 }, { 0.25, 0.5, 0.625 },
                                 { 0, 1, 1 },     { 1, 0, 1 },       { 0, 0, 0 } };
    for (const auto& s : settings) {
        SCOPED_TRACE("blends " + std::to_string(s.b1) + ", " + std::to_string(s.b2));
        auto layer = layerOf(puppet, { layerSpec(1, false, s.b1), layerSpec(1, false, s.b2) });
        const float W = static_cast<float>(s.total);
        // A whole second layer leaves nothing of the first.
        const float turn = s.b2 == 1 ? 0.6f
                         : zTurnAfterNlerps(s.b1 == 0 ? std::vector<double> { s.b2 }
                                                      : std::vector<double> { std::min(s.b1, 1.0), s.b2 },
                                            0.6);
        for (double t : { 0.0, 0.5, 1.0, 1.0 }) {
            SCOPED_TRACE("t " + std::to_string(t));
            const float dy = t == 0.5 ? 4.0f : 2.0f;
            Affine3f expected = Affine3f::Identity();
            expected.translate(Vector3f(0, 10 + W * dy, 0));
            expected.rotate(linalg::AngleAxisf(turn, Vector3f::UnitZ()));
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
        // Two half lerps bisect twice: 0.45 of the 0.6 turn.
        auto layer = layerOf(puppet, { layerSpec(1, false, 0.5), layerSpec(1, false, 0.5) });
        expectClose(pose(layer, 0) * Vector3f(2, 103, 0), Vector3f(-0.11068f, 19.77573f, 0), 1e-4f);
    }
    {
        auto layer = layerOf(puppet, { layerSpec(1, false, 0), layerSpec(1, false, 0) });
        for (double t : { 0.0, 0.5, 1.0 }) expectClose(pose(layer, t) * Vector3f(2, 103, 0), Vector3f(2, 13, 0));
    }

    // Three layers at 0.2, 0.3 and 0.4 over an identity reference.
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
    // 20 written whole, lerped by 3 toward 60 (extrapolated: 140), plus half of 20.
    auto layer = layerOf(puppet, { layerSpec(1, false, 1), layerSpec(2, false, 3), layerSpec(1, true, 0.5) });
    EXPECT_FLOAT_EQ(y(layer, 0), 150);
    EXPECT_FLOAT_EQ(y(layer, 0.5), 165);
    EXPECT_TRUE(layer.setVisible(1, false));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 45);
    EXPECT_TRUE(layer.setVisible(1, true));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 165);
    EXPECT_TRUE(layer.setBlend(1, 1));
    EXPECT_FLOAT_EQ(y(layer, 0.5), 85);

    auto big = additive(singleShot(20, 40), 2);
    EXPECT_FLOAT_EQ(y(big, 0), 40);
    EXPECT_FLOAT_EQ(y(big, 0.5), 60);
}

TEST(PuppetPose, AbsoluteLayersLerpInOrderWithoutNormalising) {
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 12, 12 });
    {
        auto second = makeAnimation(2, PlayMode::Loop, 1, 1, { Vector3f(0, 40, 0), Vector3f(0, 40, 0) });
        puppet->anims.push_back(second);
        puppet->prepared();
    }
    auto whole = layerOf(puppet, { layerSpec(1, false, 0.5), layerSpec(2, false, 1) });
    EXPECT_FLOAT_EQ(y(whole, 0), 40);
    auto part = layerOf(puppet, { layerSpec(1, false, 0.5), layerSpec(2, false, 0.5) });
    EXPECT_FLOAT_EQ(y(part, 0), 23); // 6, then halfway to 40
}

TEST(PuppetPose, ABoneOutsideALaterClipKeepsTheValueBelowIt) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(2);
    puppet->bones[0].name = "root";
    puppet->bones[1].name = "loose";
    // Clip 1 moves both bones; clip 2 holds only the first.
    auto first = makeAnimation(1, PlayMode::Loop, 1, 1, { Vector3f(0, 0, 0), Vector3f(0, 0, 0) });
    first.bone_tracks.push_back(first.bone_tracks[0]);
    first.bone_tracks[1].bone_index = 1;
    for (auto& frame : first.bone_tracks[1].frames) frame.position = Vector3f(0, 10, 0);
    puppet->anims.push_back(first);
    puppet->anims.push_back(makeAnimation(2, PlayMode::Loop, 1, 1, { Vector3f(5, 0, 0), Vector3f(5, 0, 0) }));
    puppet->prepared();

    auto layer = layerOf(puppet, { layerSpec(1, false, 1), layerSpec(2, false, 1) });
    expectClose(pose(layer, 0, 0).translation(), Vector3f(5, 0, 0));
    expectClose(pose(layer, 0, 1).translation(), Vector3f(0, 10, 0));

    // A track whose flag word has bit 0 set is masked out the same way (anim+112).
    puppet->anims[1].bone_tracks[0].unk = 1;
    auto masked = layerOf(puppet, { layerSpec(1, false, 1), layerSpec(2, false, 1) });
    expectClose(pose(masked, 0, 0).translation(), Vector3f(0, 0, 0));
}

TEST(PuppetPose, PartialWeightRotationIsANormalisedLerp) {
    // A quarter of a quarter turn: nlerp gives 0.37696 rad, a slerp would give 0.39270.
    const float q = static_cast<float>(kQuarterTurn);
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) frame.angle = Vector3f(0, 0, q);
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec(1, false, 0.25) });
    const Vector3f x = pose(layer, 0) * Vector3f(1, 0, 0);
    EXPECT_NEAR(std::atan2(x.y(), x.x()), 0.37696, 1e-4);

    // Between two key frames the same blend applies: a quarter of the way from 0 to 90 degrees.
    auto keyed = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
    keyed->anims[0].bone_tracks[0].frames[1].angle = Vector3f(0, 0, q);
    keyed->prepared();
    auto keyed_layer = additive(keyed);
    keyed_layer.genFrame(0);
    const Vector3f k = pose(keyed_layer, 0.25) * Vector3f(1, 0, 0);
    EXPECT_NEAR(std::atan2(k.y(), k.x()), 0.37696, 1e-4);
}

// ---------------------------------------------------------------------------------------------
// Blend fades (we_AnimLayerEffectiveBlend 0x14026C8B0)
// ---------------------------------------------------------------------------------------------

namespace
{
// One root bone held at y 10 for `length` seconds (fps 1), reference 0.
std::shared_ptr<WPPuppet> heldAtTen(PlayMode mode, int32_t length) {
    return heightPuppet(mode, 1, length, std::vector<float>(static_cast<size_t>(length) + 1, 10.0f));
}

Layer fading(bool in, bool out, double blendtime = 0.5) {
    Layer l     = layerSpec(1, false, 1);
    l.blendin   = in;
    l.blendout  = out;
    l.blendtime = blendtime;
    return l;
}
} // namespace

TEST(PuppetBlend, BlendInRampsOverTheShorterOfHalfTheClipAndTheBlendTime) {
    auto layer = layerOf(heldAtTen(PlayMode::Single, 2), { fading(true, false) });
    EXPECT_FLOAT_EQ(y(layer, 0), 0);
    EXPECT_FLOAT_EQ(y(layer, 0.25), 5);
    EXPECT_FLOAT_EQ(y(layer, 0.6), 10);

    // A one-second clip with a two-second blend time ramps over half the clip.
    auto short_clip = layerOf(heldAtTen(PlayMode::Single, 1), { fading(true, false, 2.0) });
    EXPECT_FLOAT_EQ(y(short_clip, 0), 0);
    EXPECT_FLOAT_EQ(y(short_clip, 0.25), 5);
}

TEST(PuppetBlend, BlendOutFadesTheLastBlendTime) {
    auto layer = layerOf(heldAtTen(PlayMode::Single, 2), { fading(false, true) });
    EXPECT_FLOAT_EQ(y(layer, 0), 10);
    EXPECT_FLOAT_EQ(y(layer, 1.5), 10);
    EXPECT_FLOAT_EQ(y(layer, 1.75), 5);
    EXPECT_FLOAT_EQ(y(layer, 2.0), 0);

    // A zero blend time does not fade at all.
    auto none = layerOf(heldAtTen(PlayMode::Single, 2), { fading(true, true, 0.0) });
    EXPECT_FLOAT_EQ(y(none, 0), 10);
    EXPECT_FLOAT_EQ(y(none, 1.99), 10);
}

TEST(PuppetBlend, ALoopFadesInOnceASingleShotEachTimeItStarts) {
    auto loop = layerOf(heldAtTen(PlayMode::Loop, 1), { fading(true, false, 0.25) });
    EXPECT_FLOAT_EQ(y(loop, 0), 0);
    EXPECT_FLOAT_EQ(y(loop, 0.125), 5);
    EXPECT_FLOAT_EQ(y(loop, 0.5), 10);
    EXPECT_FALSE(loop.blendIn(0)) << "Wallpaper Engine clears the flag once the loop has faded in";
    EXPECT_FLOAT_EQ(y(loop, 1.125), 10);

    auto single = layerOf(heldAtTen(PlayMode::Single, 1), { fading(true, false, 0.25) });
    EXPECT_FLOAT_EQ(y(single, 0), 0);
    EXPECT_FLOAT_EQ(y(single, 0.5), 10);
    EXPECT_TRUE(single.blendIn(0));
    EXPECT_FLOAT_EQ(y(single, 1.5), 10);
    EXPECT_TRUE(single.play(0)); // ran out: plays again from the start
    EXPECT_FLOAT_EQ(y(single, 1.5), 0);
    EXPECT_FLOAT_EQ(y(single, 1.625), 5);
}

TEST(PuppetBlend, AMirroredClipFadesByOnePass) {
    // Wallpaper Engine's mirror clock bounces inside one pass of the clip; the fade
    // is measured on that pass. A script can enable it after the loader clears it.
    auto layer = layerOf(heldAtTen(PlayMode::Mirror, 1), { fading(false, false) });
    ASSERT_TRUE(layer.setBlendOut(0, true));
    EXPECT_FLOAT_EQ(y(layer, 0), 10);
    EXPECT_FLOAT_EQ(y(layer, 0.75), 5);
    EXPECT_FLOAT_EQ(y(layer, 1.25), 5);  // on the way back, 0.75 into the pass
    EXPECT_FLOAT_EQ(y(layer, 1.75), 10); // back near the start
}

TEST(PuppetBlend, AuthoredLoopsAndMirrorsDoNotFadeOutAtTheirTurn) {
    // sub_1401FCC20 clears blendout for a repeating clip on both authored and
    // script-created layers. A full-weight loop therefore keeps its pose at the turn.
    for (const auto mode : { PlayMode::Loop, PlayMode::Mirror }) {
        SCOPED_TRACE(mode == PlayMode::Loop ? "loop" : "mirror");
        auto layer = layerOf(heldAtTen(mode, 1), { fading(false, true) });
        EXPECT_FLOAT_EQ(y(layer, 0), 10);
        EXPECT_FLOAT_EQ(y(layer, 0.75), 10);
        EXPECT_FLOAT_EQ(y(layer, 0.99), 10);
        EXPECT_FLOAT_EQ(y(layer, 1.25), 10);
    }
}

TEST(PuppetPose, RemovingASinglePlayLayerKeepsItsCompletedPoseForTheCurrentFrame) {
    auto layer = layerOf(heldAtTen(PlayMode::Single, 1), {});
    ASSERT_EQ(layer.createLayer(fading(false, false), {}, true), 0);
    EXPECT_FLOAT_EQ(y(layer, 0.0), 10);
    EXPECT_FLOAT_EQ(y(layer, 1.0), 10);
    const auto finished = layer.takeFinishedLayers();
    ASSERT_EQ(finished.size(), 1u);
    ASSERT_TRUE(finished.front().removed);
    layer.removeEndedLayers();
    EXPECT_EQ(layer.layerCount(), 0u);
    // WE's composer samples the pose before calling listeners and deleting layers.
    // A render of that same frame therefore still sees the completed animation.
    EXPECT_FLOAT_EQ(y(layer, 1.0), 10);
    EXPECT_FLOAT_EQ(y(layer, 1.25), 0);
}

TEST(PuppetBlend, BlendTimeDefaultsToHalfASecond) {
    EXPECT_DOUBLE_EQ(Layer {}.blendtime, 0.5);
    std::vector<Layer>          layers;
    std::vector<nlohmann::json> settings;
    wpscene::ParsePuppetAnimationLayers(
        nlohmann::json::parse(R"([{"animation":1},{"animation":1,"blendtime":0.2}])"), layers, settings);
    ASSERT_EQ(layers.size(), 2u);
    EXPECT_DOUBLE_EQ(layers[0].blendtime, 0.5);
    EXPECT_DOUBLE_EQ(layers[1].blendtime, 0.2);
}

TEST(PuppetBlend, FlagsAndBlendTimeReadBackAndChangeThePose) {
    auto layer = layerOf(heldAtTen(PlayMode::Single, 2), { layerSpec(1, false, 1) });
    EXPECT_FLOAT_EQ(y(layer, 0), 10);
    EXPECT_TRUE(layer.setBlendIn(0, true));
    EXPECT_TRUE(layer.blendIn(0));
    EXPECT_FLOAT_EQ(y(layer, 0), 0);
    EXPECT_TRUE(layer.setBlendTime(0, 1.0));
    EXPECT_DOUBLE_EQ(layer.blendTime(0), 1.0);
    EXPECT_FLOAT_EQ(y(layer, 0.5), 5);
    EXPECT_FALSE(layer.setBlendTime(0, -1));
    EXPECT_FALSE(layer.setBlendTime(0, std::numeric_limits<double>::quiet_NaN()));
    EXPECT_FALSE(layer.setBlendTime(1, 1));
    EXPECT_DOUBLE_EQ(layer.blendTime(0), 1.0);
    EXPECT_TRUE(layer.setBlendIn(0, false));
    EXPECT_TRUE(layer.setBlendOut(0, true));
    EXPECT_TRUE(layer.blendOut(0));
    EXPECT_FLOAT_EQ(y(layer, 1.5), 5);
    EXPECT_TRUE(layer.setAdditive(0, true));
    EXPECT_TRUE(layer.additive(0));
    EXPECT_FALSE(layer.setAdditive(2, true));
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

// D5.2 (0x1401FDF90): a SKINNING_ALPHA puppet's per-bone alpha starts at 1 and each layer pulls
// it toward its clip's curve value v by (v - 1) * weight, the curve sampled like the bone track.
namespace
{
std::shared_ptr<WPPuppet> fadingPuppet(bool flag_track_off = false) {
    auto puppet = singleShot(0.0f, 0.0f);
    puppet->bone_alpha = true;
    puppet->anims[0].blend_curves.push_back({ { 1.0f, 0.0f } });
    if (flag_track_off) puppet->anims[0].bone_tracks[0].unk = 1;
    return puppet;
}
} // namespace

TEST(PuppetPose, BoneAlphaCurveIsSampledPerFrame) {
    auto layer = layerOf(fadingPuppet(), { layerSpec() });
    pose(layer, 0.0);
    pose(layer, 0.5);
    ASSERT_EQ(layer.boneAlpha().size(), 1u);
    EXPECT_NEAR(layer.boneAlpha()[0], 0.5f, 1e-6f);
}

TEST(PuppetPose, APartialLayerPullsBoneAlphaByItsWeight) {
    auto layer = layerOf(fadingPuppet(), { layerSpec(1, false, 0.5) });
    pose(layer, 0.0);
    pose(layer, 1.0);
    ASSERT_EQ(layer.boneAlpha().size(), 1u);
    EXPECT_NEAR(layer.boneAlpha()[0], 0.5f, 1e-6f); // 1 + (0 - 1) * 0.5
}

TEST(PuppetPose, AFlaggedOffTrackKeepsItsBoneOpaque) {
    auto layer = layerOf(fadingPuppet(true), { layerSpec() });
    pose(layer, 0.0);
    pose(layer, 0.5);
    ASSERT_EQ(layer.boneAlpha().size(), 1u);
    EXPECT_EQ(layer.boneAlpha()[0], 1.0f);
}

TEST(PuppetPose, APuppetWithoutSkinningAlphaHasNoBoneAlpha) {
    auto puppet        = fadingPuppet();
    puppet->bone_alpha = false;
    auto layer         = layerOf(puppet, { layerSpec() });
    pose(layer, 0.0);
    EXPECT_TRUE(layer.boneAlpha().empty());
}

// B-D9: a model layer's rootmotion flag is shared by every copy of its puppet layer, and a clip
// without root-motion bits (anim+80 & 0x1F800) plays as it is with or without it.
TEST(PuppetPose, RootMotionIsSharedByCopiesAndLeavesAClipWithoutItsBitsAlone) {
    auto layer = layerOf(singleShot(0.0f, 10.0f), { layerSpec() });
    auto copy  = layer;
    EXPECT_FALSE(copy.rootMotion());
    pose(layer, 0.0);
    const float before = y(layer, 0.5);
    layer.setRootMotion(true);
    EXPECT_TRUE(copy.rootMotion());
    EXPECT_EQ(y(copy, 0.5), before);
    EXPECT_TRUE(copy.takeRootMotion().empty());
}

namespace
{
// One root bone and animation 1 (fps 1, two frames to a loop) whose frames step the root by
// `move` and turn it by `turn` radians about y per frame; its clip record names bone 0 and its
// own frames (B-D9.2: flags 0x1 | 0x400 plus the root-motion bits).
std::shared_ptr<WPPuppet> rootMotionPuppet(uint32_t bits, float move, float turn) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back();
    puppet->bones[0].name = "root";
    auto anim = makeAnimation(1, PlayMode::Loop, 1, 2,
                              { Vector3f(0, 0, 0), Vector3f(move, 0, 0), Vector3f(2 * move, 0, 0) });
    for (int k = 0; k < 3; k++) anim.bone_tracks[0].frames[static_cast<size_t>(k)].angle = Vector3f(0, turn * k, 0);
    anim.flags = WPPuppet::kAnimClip | WPPuppet::kAnimOwnFrames | bits;
    WPPuppet::Animation::Clip clip;
    clip.bone = 0;
    clip.end  = 2;
    anim.clip = clip;
    puppet->anims.push_back(anim);
    puppet->prepared();
    return puppet;
}

linalg::Vector3d movedBy(WPPuppetLayer& layer, double* yaw = nullptr) {
    linalg::Vector3d sum(0, 0, 0);
    if (yaw != nullptr) *yaw = 0.0;
    for (const auto& step : layer.takeRootMotion()) {
        sum = sum + step.translation;
        if (yaw != nullptr) *yaw += step.yaw;
    }
    return sum;
}
} // namespace

// sub_140225900: a locked axis keeps the root bone where the clip starts and hands the distance
// it would have moved to the layer; with `rootmotion` off the bone moves and nothing is handed on.
TEST(PuppetRootMotion, ALockedAxisKeepsTheRootAtTheClipsStartAndHandsTheMotionOn) {
    auto layer = layerOf(rootMotionPuppet(WPPuppet::kRootX | WPPuppet::kRootZ, 10.0f, 0.0f), { layerSpec() });
    layer.setRootMotion(true);
    pose(layer, 0.0);
    EXPECT_NEAR(movedBy(layer).x(), 0.0, 1e-9);
    EXPECT_NEAR(pose(layer, 0.5).translation().x(), 0.0f, 1e-5f);
    EXPECT_NEAR(movedBy(layer).x(), 5.0, 1e-9);
    EXPECT_NEAR(pose(layer, 1.5).translation().x(), 0.0f, 1e-5f);
    EXPECT_NEAR(movedBy(layer).x(), 10.0, 1e-9);
    // The clock loops from 1.5 to 0.5: the measure is carried past the end, so the layer keeps
    // going forward by the distance played (end - 1.5, then 0.5 from the start).
    EXPECT_NEAR(pose(layer, 2.5).translation().x(), 0.0f, 1e-5f);
    EXPECT_NEAR(movedBy(layer).x(), 10.0, 1e-9);
    // A second evaluation at the same time hands on nothing more.
    layer.setBlend(0, 1.0);
    pose(layer, 2.5);
    EXPECT_NEAR(movedBy(layer).norm(), 0.0, 1e-9);

    auto plain = layerOf(rootMotionPuppet(WPPuppet::kRootX | WPPuppet::kRootZ, 10.0f, 0.0f), { layerSpec() });
    pose(plain, 0.0);
    EXPECT_NEAR(pose(plain, 0.5).translation().x(), 5.0f, 1e-5f);
    EXPECT_TRUE(plain.takeRootMotion().empty());
}

// The yaw bit takes the clip's turn about y out of the root and hands it to the layer.
TEST(PuppetRootMotion, TheYawBitHandsTheTurnToTheLayer) {
    auto layer = layerOf(rootMotionPuppet(WPPuppet::kRootYaw, 0.0f, 0.2f), { layerSpec() });
    layer.setRootMotion(true);
    pose(layer, 0.0);
    const Affine3f root = pose(layer, 0.5);
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) EXPECT_NEAR(root(r, c), r == c ? 1.0f : 0.0f, 1e-5f) << r << "," << c;
    double yaw = 0.0;
    movedBy(layer, &yaw);
    EXPECT_NEAR(yaw, 0.1, 1e-6);
}

// Root motion is weighted by the layer's weight and by what the absolute layers above leave of
// the pose; a layer above that covers it entirely leaves no motion and no lock.
TEST(PuppetRootMotion, TheLayersAboveAndTheWeightScaleTheMotion) {
    auto puppet = rootMotionPuppet(WPPuppet::kRootX, 10.0f, 0.0f);
    auto half   = layerOf(puppet, { layerSpec(1, false, 0.5) });
    half.setRootMotion(true);
    pose(half, 0.0);
    EXPECT_NEAR(pose(half, 0.5).translation().x(), 0.0f, 1e-5f);
    EXPECT_NEAR(movedBy(half).x(), 2.5, 1e-9);

    // Animation 2 has no root-motion bits; as a whole absolute layer above, it leaves 0.
    puppet->anims.push_back(makeAnimation(2, PlayMode::Loop, 1, 2,
                                          { Vector3f(5, 0, 0), Vector3f(5, 0, 0), Vector3f(5, 0, 0) }));
    puppet->prepared();
    auto covered = layerOf(puppet, { layerSpec(1), layerSpec(2) });
    covered.setRootMotion(true);
    pose(covered, 0.0);
    EXPECT_NEAR(pose(covered, 0.5).translation().x(), 5.0f, 1e-5f);
    EXPECT_TRUE(covered.takeRootMotion().empty());
}

// ---------------------------------------------------------------------------------------------
// Bone simulation (B-D2: the composer 0x1401FDF90, the impulse 0x140210990, the reset 0x140210E10)
// ---------------------------------------------------------------------------------------------

namespace
{
using Sim = WPPuppet::BoneSimulation;

// One bone resting at the origin (a static looping clip), simulated by `sim`.
std::shared_ptr<WPPuppet> simulatedPuppet(const Sim& sim) {
    auto puppet = heightPuppet(PlayMode::Loop, 1, 1, { 0, 0 });
    puppet->bones[0].simulation = sim;
    puppet->prepared();
    return puppet;
}

Sim translationSpring(float stiffness, float friction) {
    Sim sim;
    sim.flags           = Sim::kSpring | Sim::kTranslation;
    sim.trans_stiffness = stiffness;
    sim.trans_friction  = friction;
    return sim;
}

float originX(const WPPuppetLayer& layer, size_t bone = 0) { return layer.modelBones()[bone].translation().x(); }

// Evaluates at 1/60 s steps from `t` (exclusive) up to `until`.
void stepTo(WPPuppetLayer& layer, double& t, double until) {
    while (t < until - 1e-9) {
        t += 1.0 / 60.0;
        layer.genFrame(t);
    }
}

double turnOf(const Affine3f& m) { return std::atan2(m(1, 0), m(0, 0)); }
} // namespace

// 0x1402034a3: v1 = v - dt * ts * x0, x = x0 + dt * v1, then v1 loses min(dt * tf, 1) of itself;
// the impulse adds straight to the velocity.
TEST(PuppetPhysics, TranslationSpringSettlesBackAfterAnImpulse) {
    auto   layer = layerOf(simulatedPuppet(translationSpring(100.0f, 10.0f)), { layerSpec() });
    double t     = 0.0;
    layer.genFrame(t);
    stepTo(layer, t, 1.0 / 60.0);
    EXPECT_FLOAT_EQ(originX(layer), 0.0f) << "at rest nothing moves";
    ASSERT_TRUE(layer.applyBoneImpulse(0, linalg::Vector3d(100, 0, 0), linalg::Vector3d(0, 0, 0)));
    stepTo(layer, t, 2.0 / 60.0);
    EXPECT_NEAR(originX(layer), 100.0 / 60.0, 1e-4);
    stepTo(layer, t, 10.0);
    EXPECT_LT(std::fabs(originX(layer)), 1e-3f);
}

TEST(PuppetPhysics, ASecondEvaluationAtTheSameTimeDoesNotStep) {
    auto   layer = layerOf(simulatedPuppet(translationSpring(100.0f, 10.0f)), { layerSpec() });
    double t     = 0.0;
    layer.genFrame(t);
    stepTo(layer, t, 1.0 / 60.0);
    ASSERT_TRUE(layer.applyBoneImpulse(0, linalg::Vector3d(100, 0, 0), linalg::Vector3d(0, 0, 0)));
    stepTo(layer, t, 2.0 / 60.0);
    const Affine3f once = layer.genFrame(t)[0];
    ASSERT_TRUE(layer.setBlendIn(0, true));
    ASSERT_TRUE(layer.setBlendIn(0, false));
    const Affine3f again = layer.genFrame(t)[0];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++) EXPECT_EQ(once(r, c), again(r, c));
    // The next step continues from one step, not two.
    stepTo(layer, t, 3.0 / 60.0);
    const double v1 = 100.0 * (1.0 - 1.0 / 6.0);
    const double x0 = 100.0 / 60.0;
    const double v2 = v1 - (1.0 / 60.0) * 100.0 * x0;
    EXPECT_NEAR(originX(layer), x0 + v2 / 60.0, 1e-4);
}

TEST(PuppetPhysics, TwoLayersOfOnePuppetKeepSeparateState) {
    auto   puppet = simulatedPuppet(translationSpring(100.0f, 10.0f));
    auto   a      = layerOf(puppet, { layerSpec() });
    auto   b      = layerOf(puppet, { layerSpec() });
    double ta = 0.0, tb = 0.0;
    a.genFrame(0.0);
    b.genFrame(0.0);
    stepTo(a, ta, 1.0 / 60.0);
    stepTo(b, tb, 1.0 / 60.0);
    ASSERT_TRUE(a.applyBoneImpulse(0, linalg::Vector3d(100, 0, 0), linalg::Vector3d(0, 0, 0)));
    stepTo(a, ta, 0.5);
    stepTo(b, tb, 0.5);
    EXPECT_NE(originX(a), 0.0f);
    EXPECT_EQ(originX(b), 0.0f);
}

// 0x140210E10: the state goes back to rest. With no inertia (ti 100) the bone is at its animated
// pose at the next step; a bone that does not simulate takes neither an impulse nor a reset.
TEST(PuppetPhysics, ResetReturnsTheBoneToItsAnimatedPose) {
    Sim sim           = translationSpring(100.0f, 10.0f);
    sim.trans_inertia = 0.0f;
    auto   layer      = layerOf(simulatedPuppet(sim), { layerSpec() });
    double t          = 0.0;
    layer.genFrame(t);
    stepTo(layer, t, 1.0 / 60.0);
    ASSERT_TRUE(layer.applyBoneImpulse(0, linalg::Vector3d(100, 0, 0), linalg::Vector3d(0, 0, 0)));
    stepTo(layer, t, 0.1);
    EXPECT_GT(originX(layer), 1.0f);
    ASSERT_TRUE(layer.resetBoneSimulation(0));
    stepTo(layer, t, 0.1 + 1.0 / 60.0);
    EXPECT_FLOAT_EQ(originX(layer), 0.0f);

    auto still = layerOf(singleShot(0, 0), { layerSpec() });
    EXPECT_FALSE(still.applyBoneImpulse(0, linalg::Vector3d(100, 0, 0), linalg::Vector3d(0, 0, 0)));
    EXPECT_FALSE(still.resetBoneSimulation(0));
    EXPECT_FALSE(still.simulates());
}

// The offset and the velocity are world units (0x140210a48): a layer drawn at twice the size
// moves its bone half as far in its own units; tm caps the offset at tm times the layer's scale.
TEST(PuppetPhysics, TheSimulationRunsInTheLayersWorldSpace) {
    for (float cap : { 0.0f, 0.25f }) {
        SCOPED_TRACE(cap);
        Sim sim       = translationSpring(0.0f, 0.0f);
        sim.trans_max = cap;
        auto layer    = layerOf(simulatedPuppet(sim), { layerSpec() });
        linalg::Matrix4d world = linalg::Matrix4d::Identity();
        world(0, 0) = world(1, 1) = world(2, 2) = 2.0;
        layer.setLayerWorld(world);
        double t = 0.0;
        layer.genFrame(t);
        stepTo(layer, t, 1.0 / 60.0);
        ASSERT_TRUE(layer.applyBoneImpulse(0, linalg::Vector3d(60, 0, 0), linalg::Vector3d(0, 0, 0)));
        stepTo(layer, t, 2.0 / 60.0);
        EXPECT_NEAR(originX(layer), cap > 0.0f ? 0.25f : 0.5f, 1e-5f);
    }
}

// 0x140202a44: the tip keeps where it was (inertia) and the spring turns it back; the bone lags
// behind its parent's turn and catches up once the parent stops.
TEST(PuppetPhysics, RotationSpringLagsBehindItsParentsTurn) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(2);
    puppet->bones[0].name = "parent";
    puppet->bones[1].name = "child";
    puppet->bones[1].parent = puppet->bones[1].bind_parent = puppet->bones[1].anim_parent =
        puppet->bones[1].file_parent                       = 0;
    puppet->bones[1].local_bind.translation()              = Vector3f(10, 0, 0);
    Sim sim;
    sim.flags         = Sim::kSpring | Sim::kRotation | Sim::kHoldTurnX | Sim::kHoldTurnY;
    sim.rot_stiffness = 100.0f;
    sim.rot_friction  = 10.0f;
    sim.tip           = Vector3f(10, 0, 0);
    puppet->bones[1].simulation = sim;
    auto anim = makeAnimation(1, PlayMode::Single, 1, 1, { Vector3f(0, 0, 0), Vector3f(0, 0, 0) });
    anim.bone_tracks[0].frames[1].angle = Vector3f(0, 0, static_cast<float>(kQuarterTurn));
    puppet->anims.push_back(anim);
    puppet->prepared();
    ASSERT_TRUE(puppet->has_simulation);

    auto   layer = layerOf(puppet, { layerSpec() });
    double t     = 0.0;
    layer.genFrame(t);
    stepTo(layer, t, 0.25);
    const double parent = turnOf(layer.modelBones()[0]);
    EXPECT_GT(parent, 0.3) << "the parent is a quarter of the way through its turn";
    EXPECT_LT(turnOf(layer.modelBones()[1]), parent - 0.01);
    stepTo(layer, t, 5.0);
    EXPECT_NEAR(turnOf(layer.modelBones()[1]), kQuarterTurn, 0.01);
}

namespace
{
// MDLS's explicit chain starts at bone 1, under an anchor. The alternating reference
// directions keep a bend for the iterative solver; each stored segment length is 10.
std::shared_ptr<WPPuppet> ikPuppet(usize segments, const Vector3f& goal, bool rope = false) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(segments + 2);
    puppet->bone_table.assign(segments + 2, 10.0f);
    puppet->bone_neighbours.resize(segments + 2);
    std::vector<uint32_t> chain_bones;
    for (usize i = 0; i < puppet->bones.size(); ++i) {
        auto& bone = puppet->bones[i];
        bone.name = "joint" + std::to_string(i);
        bone.parent = bone.bind_parent = bone.anim_parent =
            i == 0 ? WPPuppet::NO_PARENT : static_cast<uint32_t>(i - 1);
        if (i > 1) {
            bone.local_bind.translation() = Vector3f(8, i % 2 == 0 ? 6 : -6, 0);
            puppet->bone_neighbours[i - 1].push_back(
                { static_cast<uint32_t>(i), { 0.8f, i % 2 == 0 ? 0.6f : -0.6f, 0 } });
        }
        if (i > 0) {
            bone.sim_type = 3;
            chain_bones.push_back(static_cast<uint32_t>(i));
        }
    }
    const auto end = static_cast<uint32_t>(puppet->bones.size() - 1);
    puppet->bones[end].simulation.flags = Sim::kIk | Sim::kRotation | (rope ? Sim::kIkRope : 0);
    puppet->bones[end].simulation.ik_depth = static_cast<int32_t>(segments);
    WPPuppet::IkTarget target;
    target.bone = end;
    target.matrix.translation() = goal;
    puppet->ik_targets.push_back(target);
    WPPuppet::IkChainLink link;
    link.a = end;
    link.flags = rope ? 5 : 1;
    link.b = std::bit_cast<uint32_t>(10.0f * static_cast<float>(segments));
    link.bones = std::move(chain_bones);
    puppet->ik_chains.push_back({ 1, { 0 }, { { 1, { link } } } });
    puppet->prepared();
    return puppet;
}

Vector3f ikOrigin(WPPuppetLayer& layer, double time, usize bone) {
    layer.genFrame(time);
    return layer.modelBones()[bone].translation();
}

void expectIkLengths(const WPPuppetLayer& layer, float length = 10.0f) {
    const auto bones = layer.modelBones();
    for (usize i = 2; i < bones.size(); ++i) {
        EXPECT_NEAR((bones[i].translation() - bones[i - 1].translation()).norm(), length, 1e-3f);
    }
}
} // namespace

TEST(PuppetIk, TwoBoneChainReachesItsTargetWithoutMovingItsParentedRoot) {
    auto layer = layerOf(ikPuppet(2, Vector3f(12, 5, 0)), {});
    const Vector3f end = ikOrigin(layer, 0, 3);
    EXPECT_LE((end - Vector3f(12, 5, 0)).squaredNorm(), 0.1f)
        << "WE's position solver stops below squared distance 0.1, or after ten iterations";
    expectClose(layer.modelBones()[1].translation(), Vector3f::Zero());
    expectIkLengths(layer);
}

TEST(PuppetIk, AnUnreachableTargetStraightensTheFixedLengthChain) {
    auto layer = layerOf(ikPuppet(2, Vector3f(40, 10, 0)), {});
    const Vector3f wanted = Vector3f(40, 10, 0).normalized() * 20.0f;
    expectClose(ikOrigin(layer, 0, 3), wanted, 1e-4f);
    expectIkLengths(layer);
}

TEST(PuppetIk, OrientationTargetChoosesTheBendSide) {
    for (float side : { -1.0f, 1.0f }) {
        auto puppet = ikPuppet(2, Vector3f(12, 0, 0));
        WPPuppet::IkTarget pole;
        pole.bone = 3;
        pole.type = 1;
        pole.matrix.translation() = Vector3f(6, side * 10, 0);
        puppet->ik_targets.push_back(pole);
        puppet->prepared();
        auto layer = layerOf(puppet, {});
        EXPECT_LE((ikOrigin(layer, 0, 3) - Vector3f(12, 0, 0)).squaredNorm(), 0.1f);
        EXPECT_GT(layer.modelBones()[2].translation().y() * side, 1.0f);
        expectIkLengths(layer);
    }
}

TEST(PuppetIk, ALongChainFollowsAnAnimatedTargetTrack) {
    auto puppet = ikPuppet(4, Vector3f(20, 5, 0));
    auto anim = makeAnimation(1, PlayMode::Single, 1, 1,
                               { Vector3f(20, 5, 0), Vector3f(12, 20, 0) });
    anim.target_tracks = std::move(anim.bone_tracks);
    puppet->anims.push_back(std::move(anim));
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    for (double time : { 0.0, 0.5, 1.0 }) {
        SCOPED_TRACE(time);
        const Vector3f goal(20.0f - 8.0f * static_cast<float>(time), 5.0f + 15.0f * static_cast<float>(time), 0);
        const Vector3f end = ikOrigin(layer, time, 5);
        if (time == 0) {
            // Independent double-precision evaluation of the ten backward/forward sweeps
            // in sub_140271910. This pose exhausts the iteration budget before tolerance.
            expectClose(end, Vector3f(19.397584f, 4.903290f, 0), 1e-5f);
        } else {
            EXPECT_LE((end - goal).squaredNorm(), 0.1f);
        }
        expectIkLengths(layer);
    }
}

TEST(PuppetIk, ChainEndLimitsConstrainThePlanarJointAngle) {
    auto puppet = ikPuppet(2, Vector3f(12, 5, 0));
    puppet->bones[2].simulation.flags = Sim::kIkChainEnd;
    puppet->bones[2].simulation.ik_rope_min_length = 0;
    puppet->bones[2].simulation.ik_rope_max_length = 0;
    puppet->prepared();
    auto layer = layerOf(puppet, {});
    layer.genFrame(0);
    const auto bones = layer.modelBones();
    const Vector3f a = bones[2].translation() - bones[1].translation();
    const Vector3f b = bones[3].translation() - bones[2].translation();
    EXPECT_NEAR(std::atan2(a.x() * b.y() - a.y() * b.x(), a.dot(b)), 0.0, 1e-4)
        << "sub_14026DF30 reads ikrminl/ikrmaxl as radians, not segment-length ratios";
    expectIkLengths(layer);
}

TEST(PuppetIk, RopePinsItsEndpointAndOnlyStretchesWhenEnabled) {
    for (bool stretch : { false, true }) {
        auto puppet = ikPuppet(2, Vector3f(40, 0, 0), true);
        if (stretch) puppet->bones[3].simulation.flags |= Sim::kIkStretch;
        puppet->prepared();
        auto layer = layerOf(puppet, {});
        EXPECT_NEAR(ikOrigin(layer, 0, 3).x(), stretch ? 40.0f : 20.0f, 1e-3f);
    }
}

TEST(PuppetIk, AFreeRopeEndpointIsNotPinnedToTheAnimatedGoal) {
    auto puppet = ikPuppet(2, Vector3f(40, 0, 0), true);
    puppet->bones[3].simulation.flags |= Sim::kIkFreeEnd;
    puppet->prepared();
    auto layer = layerOf(puppet, {});
    expectClose(ikOrigin(layer, 0, 3), Vector3f(16, 0, 0), 1e-4f);
    expectIkLengths(layer);
}

TEST(PuppetIk, TargetReferenceAndAdditiveWeightControlPositionAndOrientation) {
    auto puppet = ikPuppet(2, Vector3f(40, 0, 0));
    puppet->ik_targets[0].has_reference = true;
    puppet->ik_targets[0].reference.translation() = Vector3f(12, 5, 0);
    auto anim = makeAnimation(1, PlayMode::Single, 1, 1,
                               { Vector3f(14, 7, 0), Vector3f(14, 7, 0) });
    for (auto& frame : anim.bone_tracks[0].frames) frame.angle.z() = static_cast<float>(kQuarterTurn);
    anim.target_tracks = std::move(anim.bone_tracks);
    puppet->anims.push_back(std::move(anim));
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec(1, true, 0.5) });
    EXPECT_LE((ikOrigin(layer, 0, 3) - Vector3f(13, 6, 0)).squaredNorm(), 0.1f);
    EXPECT_NEAR(turnOf(layer.modelBones()[3]), kQuarterTurn * 0.5, 1e-5);
    ASSERT_TRUE(layer.setBlend(0, 0));
    EXPECT_LE((ikOrigin(layer, 0, 3) - Vector3f(12, 5, 0)).squaredNorm(), 0.1f);
    EXPECT_NEAR(turnOf(layer.modelBones()[3]), 0, 1e-5);
}

TEST(PuppetIk, AClipSamplesItsSourcesTargetTrackAtTheClipOffset) {
    auto puppet = ikPuppet(2, Vector3f(40, 0, 0));
    auto source = makeAnimation(1, PlayMode::Single, 1, 2,
                                 { Vector3f(12, 5, 0), Vector3f(8, 12, 0), Vector3f(10, 10, 0) });
    source.target_tracks = std::move(source.bone_tracks);
    puppet->anims.push_back(std::move(source));
    auto clip = makeAnimation(2, PlayMode::Single, 1, 1, {});
    clip.flags = WPPuppet::kAnimClip;
    clip.clip = WPPuppet::Animation::Clip { .source = 0, .start = 1, .end = 2 };
    puppet->anims.push_back(std::move(clip));
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec(2) });
    EXPECT_LE((ikOrigin(layer, 0, 3) - Vector3f(8, 12, 0)).squaredNorm(), 0.1f);
}

TEST(PuppetIk, TheLastTargetOfTheSameBoneAndTypeWins) {
    auto puppet = ikPuppet(2, Vector3f(40, 0, 0));
    auto target = puppet->ik_targets[0];
    target.matrix.translation() = Vector3f(8, 12, 0);
    puppet->ik_targets.push_back(target);
    puppet->prepared();
    auto layer = layerOf(puppet, {});
    EXPECT_LE((ikOrigin(layer, 0, 3) - Vector3f(8, 12, 0)).squaredNorm(), 0.1f);
}

TEST(PuppetIk, RotationRecoveryUsesTheStoredNeighbourDirection) {
    auto puppet = ikPuppet(2, Vector3f(16, 0, 0));
    // The MDLS K-group is solver input, independent of the position difference.
    // From stored +y to the solved (8,6) direction is a clockwise 53.1301-degree turn.
    puppet->bone_neighbours[1][0].values = { 0, 1, 0 };
    puppet->prepared();
    auto layer = layerOf(puppet, {});
    layer.genFrame(0);
    EXPECT_NEAR(layer.modelBones()[1](0, 0), 0.6f, 1e-5f);
    EXPECT_NEAR(layer.modelBones()[1](1, 0), -0.8f, 1e-5f);
    expectClose(layer.modelBones()[2].translation(), Vector3f(8, 6, 0));
}

TEST(PuppetIk, ADescendantOutsideTheChainFollowsTheSolvedEnd) {
    auto puppet = ikPuppet(2, Vector3f(12, 5, 0));
    puppet->ik_targets[0].matrix.rotate(linalg::AngleAxisf(static_cast<float>(kQuarterTurn), Vector3f(0, 0, 1)));
    WPPuppet::Bone child;
    child.parent = child.bind_parent = child.anim_parent = 3;
    child.local_bind.translation() = Vector3f(3, 0, 0);
    puppet->bones.push_back(child);
    puppet->prepared();
    auto layer = layerOf(puppet, {});
    layer.genFrame(0);
    expectClose(layer.modelBones()[4].translation(), layer.modelBones()[3].translation() + Vector3f(0, 3, 0));
}

TEST(PuppetIk, RopeStateBelongsToTheInstanceAndIsNotSteppedTwiceAtOneTime) {
    auto puppet = ikPuppet(2, Vector3f(16, 0, 0), true);
    puppet->bones[3].simulation.flags |= Sim::kIkFreeEnd;
    puppet->prepared();
    auto moving = layerOf(puppet, {}), still = layerOf(puppet, {});
    moving.genFrame(0);
    still.genFrame(0);
    linalg::Matrix4d shifted = linalg::Matrix4d::Identity();
    shifted(0, 3) = 4;
    moving.setLayerWorld(shifted);
    const Vector3f moved = ikOrigin(moving, 1.0 / 60.0, 3);
    const Vector3f held = ikOrigin(still, 1.0 / 60.0, 3);
    EXPECT_GT((moved - held).squaredNorm(), 0.01f) << "the free end lags its moving layer in world space";
    expectClose(held, Vector3f(16, 0, 0));
    expectClose(ikOrigin(moving, 1.0 / 60.0, 3), moved, 0);
}

namespace
{
std::shared_ptr<WPPuppet> linkedIkPuppet(uint32_t flags, std::vector<float> weights) {
    auto p = std::make_shared<WPPuppet>();
    p->bones.resize(5);
    p->bone_table = { 0, 0, 0, 10, 10 };
    p->bone_neighbours.resize(5);
    for (uint32_t i = 0; i < 5; ++i) {
        auto& b  = p->bones[i];
        b.name   = "link-bone" + std::to_string(i);
        b.parent = b.bind_parent = b.anim_parent = b.file_parent =
            i < 2 ? WPPuppet::NO_PARENT : i - 1;
        if (i >= 2) b.sim_type = 3;
    }
    // The source is evaluated before the independent limb, rather than moving
    // the limb's own parent as a side effect of moving its target.
    p->bones[0].local_bind.translation() = Vector3f(12, 5, 0);
    p->bones[3].local_bind.translation() = Vector3f(8, 6, 0);
    p->bones[4].local_bind.translation() = Vector3f(8, -6, 0);
    p->bone_neighbours[2].push_back({ 3, { .8f, .6f, 0 } });
    p->bone_neighbours[3].push_back({ 4, { .8f, -.6f, 0 } });
    p->bones[4].simulation.flags = Sim::kIk | Sim::kRotation;
    WPPuppet::IkTarget target;
    target.bone                 = 4;
    target.matrix.translation() = Vector3f(16, 0, 0);
    p->ik_targets.push_back(target);
    WPPuppet::IkChainLink chain;
    chain.a     = 4;
    chain.flags = 1;
    chain.b     = std::bit_cast<uint32_t>(20.0f);
    chain.bones = { 2, 3, 4 };
    p->ik_chains.push_back({ 2, { 0 }, { { 2, { chain } } } });
    p->bone_links.push_back({ .bone = 4, .link_a = 0, .link_b = 0, .flags = flags });
    auto anim = makeAnimation(1, PlayMode::Single, 1, int32_t(weights.size() - 1), {});
    anim.bone_tracks.clear();
    anim.link_curves.push_back({ .values = std::move(weights) });
    p->anims.push_back(std::move(anim));
    p->prepared();
    return p;
}

void expectLinkedGoal(WPPuppetLayer& layer, double time, const Vector3f& goal) {
    EXPECT_LE((ikOrigin(layer, time, 4) - goal).squaredNorm(), .1f);
    const auto pose = layer.modelBones();
    EXPECT_NEAR((pose[3].translation() - pose[2].translation()).norm(), 10, 1e-3);
    EXPECT_NEAR((pose[4].translation() - pose[3].translation()).norm(), 10, 1e-3);
}
} // namespace

TEST(PuppetIkLinks, APositionLinkSamplesItsWeightAndKeepsTheTargetsOrientation) {
    auto        puppet = linkedIkPuppet(1, { 0, .5f, 1 });
    const float c = std::cos(.8f), s = std::sin(.8f);
    auto&       source = puppet->bones[0].local_bind;
    source(0, 0) = source(1, 1) = c;
    source(1, 0)                = s;
    source(0, 1)                = -s;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
    expectLinkedGoal(layer, 1, Vector3f(14, 2.5f, 0));
    expectLinkedGoal(layer, 2, Vector3f(12, 5, 0));
    EXPECT_NEAR(turnOf(layer.modelBones()[4]), 0, 1e-5);
}

TEST(PuppetIkLinks, AFullTransformLinkAlsoBlendsTheTargetsRotation) {
    auto        puppet = linkedIkPuppet(0, { .5f, 1 });
    const float c = std::cos(.8f), s = std::sin(.8f);
    auto&       source = puppet->bones[0].local_bind;
    source(0, 0) = source(1, 1) = c;
    source(1, 0)                = s;
    source(0, 1)                = -s;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(14, 2.5f, 0));
    EXPECT_NEAR(turnOf(layer.modelBones()[4]), .4, 1e-5);
    expectLinkedGoal(layer, 1, Vector3f(12, 5, 0));
    EXPECT_NEAR(turnOf(layer.modelBones()[4]), .8, 1e-5);
}

TEST(PuppetIkLinks, LinkRecordsAddressTheirStoredCurveIndex) {
    auto puppet                  = linkedIkPuppet(1, { 0, 0 });
    puppet->bone_links[0].link_a = 1;
    // A zero-weight ordinary-bone link supplies the other format record without
    // moving either the source or the independent limb's parent.
    puppet->bone_links.push_back({ .bone = 1, .link_a = 0, .link_b = 0, .flags = 1 });
    puppet->anims[0].link_curves.push_back({ .values = { .8f, .8f } });
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(12.8f, 4, 0));
}

TEST(PuppetIkLinks, MultipleLinksApplyInStoredOrderWithoutWeightNormalization) {
    auto puppet = linkedIkPuppet(1, { .5f, .5f });
    puppet->bone_links.push_back({ .bone = 4, .link_a = 1, .link_b = 0, .flags = 1 });
    puppet->anims[0].link_curves.push_back({ .values = { .5f, .5f } });
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(13, 3.75f, 0));
}

TEST(PuppetIkLinks, ClipOffsetsAndAdditiveLayersReachTheLinkWeightConsumer) {
    auto puppet = linkedIkPuppet(1, { .2f, .2f });
    auto source = makeAnimation(2, PlayMode::Single, 1, 2, {});
    source.bone_tracks.clear();
    source.link_curves = { { .values = { 0, .8f, 1 } } };
    puppet->anims.push_back(std::move(source));
    auto clip = makeAnimation(3, PlayMode::Single, 1, 1, {});
    clip.bone_tracks.clear();
    clip.flags = WPPuppet::kAnimClip;
    clip.clip  = WPPuppet::Animation::Clip { .source = 1, .start = 1, .end = 2 };
    puppet->anims.push_back(std::move(clip));
    puppet->prepared();
    auto mixed = layerOf(puppet, { layerSpec(), layerSpec(3, false, .5) });
    auto added = layerOf(puppet, { layerSpec(), layerSpec(3, true, .5) });
    expectLinkedGoal(mixed, 0, Vector3f(14, 2.5f, 0));
    expectLinkedGoal(added, 0, Vector3f(13.6f, 3, 0));
}

TEST(PuppetIkLinks, TheLinkReadsTheEarlierBonesCurrentAnimatedPose) {
    auto puppet = linkedIkPuppet(1, { 1, 1 });
    puppet->anims[0].bone_tracks =
        makeAnimation(1, PlayMode::Single, 1, 1, { Vector3f(12, 5, 0), Vector3f(8, 12, 0) })
            .bone_tracks;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(12, 5, 0));
    expectLinkedGoal(layer, 1, Vector3f(8, 12, 0));
}

TEST(PuppetIkLinks, AZeroBlendClearsTheLinkWithoutAdvancingSceneTime) {
    auto puppet = linkedIkPuppet(1, { 1, 1 });
    auto layer  = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(12, 5, 0));
    ASSERT_TRUE(layer.setBlend(0, 0));
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
}

TEST(PuppetIkLinks, AMaskedUpperCurveLeavesTheLowerLayersWeight) {
    auto puppet = linkedIkPuppet(1, { .25f, .25f });
    auto upper  = makeAnimation(2, PlayMode::Single, 1, 1, {});
    upper.bone_tracks.clear();
    upper.link_curves = { { .flags = 1, .values = { 1, 1 } } };
    puppet->anims.push_back(std::move(upper));
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec(), layerSpec(2) });
    expectLinkedGoal(layer, 0, Vector3f(15, 1.25f, 0));
}

TEST(PuppetIkLinks, ANegativeAnimationFlagWordClearsTheFirstMaskedLayerBaseline) {
    auto puppet = linkedIkPuppet(1, { 1, 1 });
    auto masked = makeAnimation(2, PlayMode::Single, 1, 1, {});
    masked.bone_tracks.clear();
    masked.flags = 0x80000000u;
    masked.link_curves = { { .flags = 1, .values = { 1, 1 } } };
    puppet->anims.push_back(std::move(masked));
    puppet->prepared();
    auto second = layerSpec(2);
    second.visible = false;
    auto layer = layerOf(puppet, { layerSpec(), second });
    expectLinkedGoal(layer, 0, Vector3f(12, 5, 0));
    ASSERT_TRUE(layer.setVisible(0, false));
    ASSERT_TRUE(layer.setVisible(1, true));
    // The signed jge at 0x1401fee49 takes this full-weight first layer through
    // the same zero-baseline path as a partial/additive layer.
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
}

TEST(PuppetIkLinks, OnlyTheChainsStoredTargetsConsumeTheirLinks) {
    auto puppet = linkedIkPuppet(1, { 1, 1 });
    puppet->ik_chains[0].targets.clear();
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
}

TEST(PuppetIkLinks, DuplicateTargetsKeepTheLoadersFirstPositionTargetBinding) {
    auto puppet                    = linkedIkPuppet(1, { 1, 1 });
    auto duplicate                 = puppet->ik_targets[0];
    duplicate.matrix.translation() = Vector3f(8, 12, 0);
    puppet->ik_targets.push_back(duplicate);
    puppet->ik_chains[0].targets = { 1 };
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    // The solver's last-name map chooses target1, but the rule was attached to
    // target0 by the loader. It must not be silently rebound to the chosen goal.
    expectLinkedGoal(layer, 0, Vector3f(8, 12, 0));
}

TEST(PuppetIkLinks, InvalidSourceAndCurveIndicesLeaveTheAnimatedGoalAlone) {
    for (bool invalid_source : { false, true }) {
        auto puppet = linkedIkPuppet(1, { 1, 1 });
        if (invalid_source)
            puppet->bone_links[0].link_b = 500;
        else
            puppet->bone_links[0].link_a = 500;
        puppet->prepared();
        auto layer = layerOf(puppet, { layerSpec() });
        expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
    }
}

TEST(PuppetIkLinks, FullTransformAnglesUseTheObservedOneSidedPiAdjustment) {
    const auto rotate = [](linalg::Affine3f& matrix, float angle) {
        const float c = std::cos(angle), s = std::sin(angle);
        matrix(0, 0) = matrix(1, 1) = c;
        matrix(1, 0)                = s;
        matrix(0, 1)                = -s;
    };
    for (bool reverse : { false, true }) {
        auto        puppet = linkedIkPuppet(0, { .5f, .5f });
        const float angle  = float(170 * M_PI / 180);
        rotate(puppet->ik_targets[0].matrix, reverse ? angle : -angle);
        rotate(puppet->bones[0].local_bind, reverse ? -angle : angle);
        puppet->prepared();
        auto layer = layerOf(puppet, { layerSpec() });
        expectLinkedGoal(layer, 0, Vector3f(14, 2.5f, 0));
        EXPECT_NEAR(turnOf(layer.modelBones()[4]), reverse ? 0 : -kQuarterTurn, 1e-5);
    }
}

TEST(PuppetIkLinks, AnAxisLinkPullsTheTargetToTheSourcesXLineByItsCurveWeight) {
    auto puppet = linkedIkPuppet(2, { 0, .5f, 1 });
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
    expectLinkedGoal(layer, 1, Vector3f(16, 2.5f, 0));
    expectLinkedGoal(layer, 2, Vector3f(16, 5, 0));
}

TEST(PuppetIkLinks, AnAxisLinkUsesTheRotatedSourceLineWithoutScalingTheDistance) {
    auto puppet = linkedIkPuppet(2, { 1, 1 });
    auto& source = puppet->bones[0].local_bind;
    source(0, 0) = 0; source(1, 0) = -3;
    source(0, 1) = 2; source(1, 1) = 0;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(12, 0, 0));
    EXPECT_NEAR(turnOf(layer.modelBones()[4]), 0, 1e-5);
}

TEST(PuppetIkLinks, AxisProjectionTakesPrecedenceOverThePositionOnlyBit) {
    auto puppet = linkedIkPuppet(3, { 1, 1 });
    puppet->bone_links[0].extra_u32 = 17;
    puppet->bone_links[0].extra_f32 = 100;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 5, 0));
}

TEST(PuppetIkLinks, AxisRulesKeepTheirOrderAndUnnormalizedWeights) {
    auto puppet = linkedIkPuppet(2, { .5f, .5f });
    puppet->bone_links.push_back({ .bone = 4, .link_a = 1, .link_b = 0, .flags = 2 });
    puppet->anims[0].link_curves.push_back({ .values = { .5f, .5f } });
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 3.75f, 0));
}

TEST(PuppetIkLinks, AnAxisRuleAppliesForEachStoredMatchingEndpoint) {
    auto puppet = linkedIkPuppet(2, { .5f, .5f });
    auto& links = puppet->ik_chains[0].segments[0].links;
    links.push_back(links.front());
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 3.75f, 0));
}

TEST(PuppetIkLinks, GroundingFlagTakesPrecedenceOverAxisProjection) {
    auto puppet = linkedIkPuppet(0x10002, { 1, 1 });
    puppet->ik_targets[0].matrix.translation() = Vector3f(22, 0, 0);
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    // 0x14026F5B3 selects grounding first: reach 20 minus source distance 13.
    expectLinkedGoal(layer, 0, Vector3f(19, 5, 0));
}

TEST(PuppetIkLinks, AnAxisTargetAlreadyOnTheLineKeepsItsFinitePose) {
    auto puppet = linkedIkPuppet(2, { 1, 1 });
    puppet->bones[0].local_bind.translation() = Vector3f(12, 0, 0);
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 0, 0));
    for (const auto& bone : layer.modelBones()) EXPECT_TRUE(bone.matrix().allFinite());
}

TEST(PuppetIkLinks, AnAxisRuleWithoutAMatchingEndpointLeavesItsTargetAlone) {
    auto puppet = linkedIkPuppet(2, { 1, 1 });
    auto target = puppet->ik_targets.front();
    target.bone = 3;
    puppet->ik_targets.push_back(target);
    puppet->ik_chains[0].targets.push_back(1);
    puppet->bone_links[0].bone = 3;
    puppet->prepared();
    const auto plan = PreparePuppetIk(*puppet);
    ASSERT_NE(plan, nullptr);
    PuppetIkState state(plan);
    state.targets[0] = puppet->ik_targets[0].matrix;
    state.targets[1] = puppet->ik_targets[1].matrix;
    std::fill(state.link_weights.begin(), state.link_weights.end(), 1);
    auto model = plan->reference;
    SolvePuppetIk(*puppet, state, 0, model);
    EXPECT_EQ(state.targets[1].translation(), Vector3f(16, 0, 0));
    EXPECT_TRUE(state.link_weights.empty());
}

TEST(PuppetIkLinks, AnAxisLinkKeepsTheTargetsRotationInsteadOfTheSourcesRotation) {
    auto puppet = linkedIkPuppet(2, { 1, 1 });
    auto& target = puppet->ik_targets[0].matrix;
    const float c = std::cos(.4f), s = std::sin(.4f);
    target(0, 0) = target(1, 1) = c;
    target(1, 0) = s; target(0, 1) = -s;
    puppet->prepared();
    auto layer = layerOf(puppet, { layerSpec() });
    expectLinkedGoal(layer, 0, Vector3f(16, 5, 0));
    EXPECT_NEAR(turnOf(layer.modelBones()[4]), .4f, 1e-5);
}

// From main (#93), on our D5.2 rule: a bone's opacity curve is sampled between the layer's two
// frames, a layer pulls by its blend toward the opaque rest pose, a bone without a curve and a
// hidden layer leave it opaque. The SKINNING_ALPHA gate is the mesh flag (puppet->bone_alpha).
TEST(PuppetBoneAlpha, CurvesAreSampledAndMixedWithTheOpaqueRestPose) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(2);
    puppet->bone_alpha = true;
    auto anim = makeAnimation(1, PlayMode::Loop, 1, 2, { Vector3f(0, 0, 0), Vector3f(0, 0, 0), Vector3f(0, 0, 0) });
    anim.blend_curves.resize(2);
    anim.blend_curves[0].values = { 1.0f, 0.5f, 0.0f };
    puppet->anims.push_back(anim);
    puppet->prepared();

    auto layer = layerOf(puppet, { layerSpec(1, false, 1.0) });
    pose(layer, 0.0);
    pose(layer, 1.0); // frame 1
    ASSERT_EQ(layer.boneAlpha().size(), 2u);
    EXPECT_NEAR(layer.boneAlpha()[0], 0.5f, 1e-5);
    EXPECT_NEAR(layer.boneAlpha()[1], 1.0f, 1e-5) << "no curve, opaque";
    pose(layer, 1.5); // halfway to frame 2
    EXPECT_NEAR(layer.boneAlpha()[0], 0.25f, 1e-5);

    auto half = layerOf(puppet, { layerSpec(1, false, 0.5) });
    pose(half, 0.0);
    pose(half, 1.0);
    EXPECT_NEAR(half.boneAlpha()[0], 0.75f, 1e-5) << "half the blend leaves half to the opaque rest pose";

    auto hidden = layerOf(puppet, { layerSpec(1, false, 1.0) });
    hidden.setVisible(0, false);
    pose(hidden, 0.0);
    pose(hidden, 1.0);
    EXPECT_NEAR(hidden.boneAlpha()[0], 1.0f, 1e-5) << "a hidden layer fades nothing";
}
