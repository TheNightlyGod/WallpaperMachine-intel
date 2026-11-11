// Pending Metal presentation callbacks must finish while their CAMetalLayer still exists.
// Uses an unhosted layer and an empty command buffer; no drawable or desktop is shown.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "MetalRender/MetalRender.hpp"
#include <gtest/gtest.h>

using namespace wallpaper::metal;

TEST(MetalSurfaceLifetime, ReleaseWaitsForPendingCommandsBeforeDroppingLayer)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) GTEST_SKIP() << "no Metal device";
        MetalRender renderer;
        __weak CAMetalLayer* released_layer;
        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = device;
            layer.drawableSize = CGSizeMake(16, 16);
            released_layer = layer;
            MetalRenderInitInfo info;
            info.metal_layer = (__bridge void*)layer;
            info.width = info.height = 16;
            info.display_hdr_output_allowed = false;
            info.display_characteristics = [](uint32_t) { return MetalDisplayCharacteristics {}; };
            ASSERT_TRUE(renderer.init(info));
        }
        @autoreleasepool { ASSERT_NE(released_layer, nil); }
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)renderer.CommandQueueForTests();
        id<MTLCommandBuffer> command = [queue commandBuffer];
        dispatch_semaphore_t scheduled = dispatch_semaphore_create(0);
        dispatch_semaphore_t proceed = dispatch_semaphore_create(0);
        __block bool layer_alive_at_schedule = false;
        [command addScheduledHandler:^(id<MTLCommandBuffer>) {
            dispatch_semaphore_signal(scheduled);
            dispatch_semaphore_wait(proceed, DISPATCH_TIME_FOREVER);
            @autoreleasepool { layer_alive_at_schedule = released_layer != nil; }
        }];
        [command commit];
        ASSERT_EQ(dispatch_semaphore_wait(scheduled, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
        // Hold scheduling briefly to model an outstanding present callback. The assertion is
        // about completed work and layer lifetime, not how long releaseSurface takes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_signal(proceed);
        });
        ASSERT_TRUE(renderer.releaseSurface());
        EXPECT_EQ(command.status, MTLCommandBufferStatusCompleted);
        [command waitUntilCompleted];
        EXPECT_TRUE(layer_alive_at_schedule);
        EXPECT_FALSE(renderer.inited());
        renderer.destroy();
    }
}
