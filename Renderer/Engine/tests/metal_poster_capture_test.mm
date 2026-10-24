/// Proof for the Metal backend's desktop-poster readback.
///
/// The capture is driven with a stand-in composition that clears the
/// destination to a known colour, so every assertion is about the capture
/// itself: when it asks the host, when it refuses, how it coalesces concurrent
/// requests, and whether the bytes it delivers are the ones the renderer wrote,
/// in the channel order the flag claims.
///
/// Creates only a shared GPU texture. No window, no drawable, no desktop, no
/// screen capture.

#include "MetalPosterCapture.hpp"

#import <Metal/Metal.h>

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <vector>

using namespace wallpaper::metal;

namespace
{

struct Delivery
{
    std::mutex              mutex;
    std::condition_variable ready;
    int                     count { 0 };
    std::vector<uint8_t>    pixels;
    uint32_t                width { 0 };
    uint32_t                height { 0 };
    bool                    bgra { false };

    MetalPosterCapture::PosterReady callback()
    {
        return [this](std::span<const uint8_t> bytes, uint32_t w, uint32_t h, bool is_bgra) {
            std::lock_guard<std::mutex> guard(mutex);
            pixels.assign(bytes.begin(), bytes.end());
            width  = w;
            height = h;
            bgra   = is_bgra;
            ++count;
            ready.notify_all();
        };
    }

    /// Only the test waits; the capture itself never blocks a thread.
    bool wait(int expected, std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> guard(mutex);
        return ready.wait_for(guard, timeout, [&] { return count >= expected; });
    }

    int deliveries()
    {
        std::lock_guard<std::mutex> guard(mutex);
        return count;
    }
};

/// Stands in for the backend's final composition: a render pass whose only
/// content is the clear, which is enough to prove the capture reads back the
/// texture the renderer drew into.
MetalPosterCapture::EncodeComposition ClearTo(double r, double g, double b)
{
    return [r, g, b](id<MTLCommandBuffer> command, id<MTLTexture> destination) {
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture     = destination;
        pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor  = MTLClearColorMake(r, g, b, 1.0);
        id<MTLRenderCommandEncoder> encoder =
            [command renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) return false;
        [encoder endEncoding];
        return true;
    };
}

constexpr uint32_t kWidth  = 64;
constexpr uint32_t kHeight = 48;

/// Chosen so each channel lands on a distinct byte: red 0, green 128, blue 255.
/// Anything that swapped or converted channels shows up immediately.
constexpr double kClearRed   = 0.0;
constexpr double kClearGreen = 128.0 / 255.0;
constexpr double kClearBlue  = 1.0;

void ExpectPixel(const std::vector<uint8_t>& pixels, std::size_t index, uint8_t c0, uint8_t c1,
                 uint8_t c2)
{
    ASSERT_LT(index * 4 + 3, pixels.size());
    EXPECT_NEAR(pixels[index * 4 + 0], c0, 1);
    EXPECT_NEAR(pixels[index * 4 + 1], c1, 1);
    EXPECT_NEAR(pixels[index * 4 + 2], c2, 1);
    EXPECT_EQ(pixels[index * 4 + 3], 255);
}

class MetalPosterCaptureTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        device_ = MTLCreateSystemDefaultDevice();
        if (device_ == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the poster capture was not exercised";
        }
        queue_ = [device_ newCommandQueue];
        ASSERT_NE(queue_, nil);
    }

    id<MTLDevice>       device_ { nil };
    id<MTLCommandQueue> queue_ { nil };
};

} // namespace

TEST_F(MetalPosterCaptureTest, NoRequestCostsOneAskAndNothingElse)
{
    @autoreleasepool {
        Delivery         delivery;
        std::atomic<int> asked { 0 };
        std::atomic<int> encoded { 0 };

        MetalPosterCapture capture;
        capture.configure(device_,
                          [&] {
                              ++asked;
                              return false;
                          },
                          delivery.callback());

        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        auto encode = [&](id<MTLCommandBuffer> buffer, id<MTLTexture> texture) {
            ++encoded;
            return ClearTo(kClearRed, kClearGreen, kClearBlue)(buffer, texture);
        };
        const auto outcome = capture.encodeIfRequested(
            command, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
            MetalPosterCapture::EncodeComposition(encode));
        EXPECT_EQ(outcome, MetalPosterCapture::Outcome::NotRequested);
        EXPECT_EQ(asked.load(), 1);
        EXPECT_EQ(encoded.load(), 0) << "an unrequested frame paid for a composition";

        [command commit];
        [command waitUntilCompleted];
        EXPECT_EQ(delivery.deliveries(), 0);
    }
}

TEST_F(MetalPosterCaptureTest, DeliversTheComposedPixelsAsBGRA)
{
    @autoreleasepool {
        Delivery           delivery;
        MetalPosterCapture capture;
        capture.configure(device_, [] { return true; }, delivery.callback());

        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        const auto outcome = capture.encodeIfRequested(command, kWidth, kHeight,
                                                       MTLPixelFormatBGRA8Unorm,
                                                       ClearTo(kClearRed, kClearGreen, kClearBlue));
        ASSERT_EQ(outcome, MetalPosterCapture::Outcome::Encoded) << capture.lastError();
        [command commit];

        ASSERT_TRUE(delivery.wait(1, std::chrono::seconds(5)));
        std::lock_guard<std::mutex> guard(delivery.mutex);
        EXPECT_TRUE(delivery.bgra);
        EXPECT_EQ(delivery.width, kWidth);
        EXPECT_EQ(delivery.height, kHeight);
        ASSERT_EQ(delivery.pixels.size(), std::size_t(kWidth) * kHeight * 4);
        ExpectPixel(delivery.pixels, 0, 255, 128, 0);
        ExpectPixel(delivery.pixels, std::size_t(kWidth) * kHeight / 2, 255, 128, 0);
        ExpectPixel(delivery.pixels, std::size_t(kWidth) * kHeight - 1, 255, 128, 0);
    }
}

TEST_F(MetalPosterCaptureTest, DeliversTheComposedPixelsAsRGBA)
{
    @autoreleasepool {
        Delivery           delivery;
        MetalPosterCapture capture;
        capture.configure(device_, [] { return true; }, delivery.callback());

        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        const auto outcome = capture.encodeIfRequested(command, kWidth, kHeight,
                                                       MTLPixelFormatRGBA8Unorm,
                                                       ClearTo(kClearRed, kClearGreen, kClearBlue));
        ASSERT_EQ(outcome, MetalPosterCapture::Outcome::Encoded) << capture.lastError();
        [command commit];

        ASSERT_TRUE(delivery.wait(1, std::chrono::seconds(5)));
        std::lock_guard<std::mutex> guard(delivery.mutex);
        EXPECT_FALSE(delivery.bgra) << "the flag has to describe the bytes, not a convention";
        ASSERT_EQ(delivery.pixels.size(), std::size_t(kWidth) * kHeight * 4);
        ExpectPixel(delivery.pixels, 0, 0, 128, 255);
        ExpectPixel(delivery.pixels, std::size_t(kWidth) * kHeight - 1, 0, 128, 255);
    }
}

TEST_F(MetalPosterCaptureTest, SecondRequestWhileOneIsInFlightIsRefusedWithoutAskingAgain)
{
    @autoreleasepool {
        Delivery         delivery;
        std::atomic<int> asked { 0 };

        MetalPosterCapture capture;
        capture.configure(device_,
                          [&] {
                              ++asked;
                              return true;
                          },
                          delivery.callback());

        id<MTLCommandBuffer> first = [queue_ commandBuffer];
        ASSERT_EQ(capture.encodeIfRequested(first, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Encoded)
            << capture.lastError();

        id<MTLCommandBuffer> second = [queue_ commandBuffer];
        EXPECT_EQ(capture.encodeIfRequested(second, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Busy);
        // The host's request is still pending: consuming it here would arm its
        // backoff for a capture that never happened.
        EXPECT_EQ(asked.load(), 1);

        [first commit];
        [second commit];
        ASSERT_TRUE(delivery.wait(1, std::chrono::seconds(5)));
        EXPECT_EQ(delivery.deliveries(), 1);
    }
}

TEST_F(MetalPosterCaptureTest, InvalidateDropsTheResultAndLeavesTheCaptureUsable)
{
    @autoreleasepool {
        Delivery           delivery;
        MetalPosterCapture capture;
        capture.configure(device_, [] { return true; }, delivery.callback());

        id<MTLCommandBuffer> dropped = [queue_ commandBuffer];
        ASSERT_EQ(capture.encodeIfRequested(dropped, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Encoded)
            << capture.lastError();

        capture.invalidate();
        [dropped commit];
        [dropped waitUntilCompleted];
        EXPECT_FALSE(delivery.wait(1, std::chrono::milliseconds(500)))
            << "a capture composed for a surface that is gone was still delivered";

        // A dropped capture must not leave the next request stuck on `Busy`.
        capture.configure(device_, [] { return true; }, delivery.callback());
        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        ASSERT_EQ(capture.encodeIfRequested(command, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Encoded)
            << capture.lastError();
        [command commit];
        ASSERT_TRUE(delivery.wait(1, std::chrono::seconds(5)));
        EXPECT_EQ(delivery.deliveries(), 1);
    }
}

TEST_F(MetalPosterCaptureTest, ImpossibleRequestsFailWithoutConsumingTheHostRequest)
{
    @autoreleasepool {
        Delivery         delivery;
        std::atomic<int> asked { 0 };

        MetalPosterCapture capture;
        capture.configure(device_,
                          [&] {
                              ++asked;
                              return true;
                          },
                          delivery.callback());

        id<MTLCommandBuffer> oversize = [queue_ commandBuffer];
        EXPECT_EQ(capture.encodeIfRequested(oversize, 20000, 20000, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Failed);
        EXPECT_FALSE(capture.lastError().empty());

        id<MTLCommandBuffer> unsupported = [queue_ commandBuffer];
        EXPECT_EQ(capture.encodeIfRequested(unsupported, kWidth, kHeight, MTLPixelFormatRGBA16Float,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Failed);
        EXPECT_FALSE(capture.lastError().empty());

        EXPECT_EQ(asked.load(), 0) << "a request that could never be served was taken anyway";
        EXPECT_EQ(delivery.deliveries(), 0);
    }
}

TEST_F(MetalPosterCaptureTest, AFailedCompositionDoesNotBlockTheNextPoster)
{
    @autoreleasepool {
        Delivery           delivery;
        MetalPosterCapture capture;
        capture.configure(device_, [] { return true; }, delivery.callback());

        id<MTLCommandBuffer> refused = [queue_ commandBuffer];
        EXPECT_EQ(capture.encodeIfRequested(
                      refused, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                      [](id<MTLCommandBuffer>, id<MTLTexture>) { return false; }),
                  MetalPosterCapture::Outcome::Failed);
        EXPECT_FALSE(capture.lastError().empty());
        [refused commit];

        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        ASSERT_EQ(capture.encodeIfRequested(command, kWidth, kHeight, MTLPixelFormatBGRA8Unorm,
                                            ClearTo(kClearRed, kClearGreen, kClearBlue)),
                  MetalPosterCapture::Outcome::Encoded)
            << capture.lastError();
        [command commit];
        ASSERT_TRUE(delivery.wait(1, std::chrono::seconds(5)));
        EXPECT_EQ(delivery.deliveries(), 1);
    }
}
