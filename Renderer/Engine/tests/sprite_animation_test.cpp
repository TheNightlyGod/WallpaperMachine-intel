#include "SpriteAnimation.hpp"

#include <gtest/gtest.h>

#include <limits>

namespace wallpaper
{
namespace
{
SpriteAnimation Animation() {
    SpriteAnimation animation;
    for (int frame = 0; frame < 7; ++frame) {
        animation.AppendFrame(SpriteFrame { .imageId = frame, .frametime = 0.125f });
    }
    return animation;
}

TEST(SpriteAnimation, ElapsedTimeDoesNotDependOnRenderCadence) {
    auto fine = Animation();
    auto coarse = Animation();
    for (int tick = 0; tick < 128; ++tick) fine.GetAnimateFrame(1.0 / 128.0);
    for (int tick = 0; tick < 4; ++tick) coarse.GetAnimateFrame(0.25);
    EXPECT_EQ(fine.CurFrameIndex(), coarse.CurFrameIndex());
    EXPECT_EQ(fine.CurFrameIndex(), 1);
    fine.GetAnimateFrame(0.0625);
    coarse.GetAnimateFrame(0.0625);
    EXPECT_EQ(fine.CurFrameIndex(), coarse.CurFrameIndex());
}

TEST(SpriteAnimation, FirstPositiveTickStepsAndExplicitFrameKeepsItsDuration) {
    auto animation = Animation();
    EXPECT_EQ(animation.GetAnimateFrame(0.0).imageId, 0);
    EXPECT_EQ(animation.GetAnimateFrame(0.03125).imageId, 1);
    EXPECT_EQ(animation.GetAnimateFrame(0.09375).imageId, 1);
    EXPECT_EQ(animation.GetAnimateFrame(0.03125).imageId, 2);
    animation.SetFrame(5);
    EXPECT_EQ(animation.GetAnimateFrame(0.125).imageId, 5);
    EXPECT_EQ(animation.GetAnimateFrame(0.03125).imageId, 6);
}

TEST(SpriteAnimation, LongIntervalsSkipWholeCyclesAndUntimedFramesStayBounded) {
    auto short_interval = Animation();
    auto long_interval = Animation();
    short_interval.GetAnimateFrame(0.3125);
    long_interval.GetAnimateFrame(0.875 * 1000000.0 + 0.3125);
    EXPECT_EQ(short_interval.CurFrameIndex(), long_interval.CurFrameIndex());
    SpriteAnimation untimed;
    untimed.AppendFrame(SpriteFrame { .imageId = 0, .frametime = 0.0f });
    untimed.AppendFrame(SpriteFrame { .imageId = 1, .frametime = 0.0f });
    EXPECT_EQ(untimed.GetAnimateFrame(10.0).imageId, 1);
    EXPECT_EQ(untimed.GetAnimateFrame(std::numeric_limits<double>::infinity()).imageId, 1);
}
} // namespace
} // namespace wallpaper
