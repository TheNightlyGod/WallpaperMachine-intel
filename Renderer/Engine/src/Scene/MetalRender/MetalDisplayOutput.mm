#include "MetalDisplayOutput.hpp"
#import <AppKit/AppKit.h>
#import <QuartzCore/CATransaction.h>
#import <objc/runtime.h>
#include <atomic>
#include <bit>
#include <cmath>
#include <algorithm>

// A new renderer can adopt the same layer before the old one's queued cleanup
// runs. Its lease inherits the original host contract; stale cleanup cannot
// overwrite the new owner's choice.
@interface WMSceneDisplayLease : NSObject {
@public
    MTLPixelFormat originalFormat;
    CGColorSpaceRef originalSpace;
    BOOL originalEDR;
    uint64_t generation;
    BOOL ownsSurface;
}
@end
@implementation WMSceneDisplayLease
- (void)dealloc { if (originalSpace != nullptr) CGColorSpaceRelease(originalSpace); }
@end

namespace wallpaper::metal {
namespace {
char kDisplayLease;
std::atomic<uint64_t> gDisplayOwnerGeneration {1};
uint64_t Pack(float headroom, bool extended) {
    return uint64_t(std::bit_cast<uint32_t>(headroom)) | (uint64_t(extended) << 32);
}
void OnMain(std::function<void()> work) {
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), ^{ work(); });
}
MetalDisplayCharacteristics ReadDisplay(uint32_t display_id) {
    NSScreen* screen = nil;
    if (display_id != 0) {
        for (NSScreen* candidate in [NSScreen screens]) {
            NSNumber* number = candidate.deviceDescription[@"NSScreenNumber"];
            if (number.unsignedIntValue == display_id) { screen = candidate; break; }
        }
    }
    if (screen == nil) return {};
    return {float(screen.maximumExtendedDynamicRangeColorComponentValue),
            float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)};
}
} // namespace

std::chrono::nanoseconds DisplayRefreshPeriod(uint32_t display_id) {
    if (display_id == 0) return {};
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display_id);
    if (mode == nullptr) return {};
    const double hertz = CGDisplayModeGetRefreshRate(mode);
    CGDisplayModeRelease(mode);
    // A panel with no fixed rate reports zero.
    if (!std::isfinite(hertz) || hertz < 1.0) return {};
    return std::chrono::nanoseconds(static_cast<int64_t>(std::ceil(1e9 / hertz)));
}

struct MetalDisplayOutput::State : std::enable_shared_from_this<State> {
    __weak CAMetalLayer* layer;
    WMSceneDisplayLease* lease {nil};
    id screen_observer {nil};
    std::function<MetalDisplayCharacteristics(uint32_t)> provider;
    const uint64_t owner_generation {gDisplayOwnerGeneration.fetch_add(1,std::memory_order_relaxed)};
    std::atomic<uint32_t> display_id {0};
    std::function<void()> changed;
    std::atomic<int> requested {-1}; // 0: linear SDR, 1: display HDR
    std::atomic<bool> active {true};
    std::atomic<uint64_t> snapshot {Pack(1.0f, false)};

    State(CAMetalLayer* target, std::function<MetalDisplayCharacteristics(uint32_t)> read,
          std::function<void()> wake, uint32_t identity)
        : layer(target), provider(std::move(read)), display_id(identity), changed(std::move(wake)) {}

    void RemoveObservers() {
        auto* center = [NSNotificationCenter defaultCenter];
        if (screen_observer != nil) [center removeObserver:screen_observer];
        screen_observer = nil;
    }
    void Observe() {
        if (screen_observer != nil) return;
        const std::weak_ptr<State> weak = shared_from_this();
        auto callback = ^(NSNotification*) {
            if (auto self = weak.lock(); self && self->active.load(std::memory_order_acquire))
                self->Apply();
        };
        auto* center = [NSNotificationCenter defaultCenter];
        screen_observer = [center addObserverForName:NSApplicationDidChangeScreenParametersNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:callback];
    }
    void Apply() {
        if (!active.load(std::memory_order_acquire)) return;
        CAMetalLayer* target = layer;
        if (target == nil) return;
        if (lease == nil) {
            WMSceneDisplayLease* prior = objc_getAssociatedObject(target, &kDisplayLease);
            if (prior != nil && prior->generation > owner_generation) return;
            lease = [WMSceneDisplayLease new];
            const bool inheriting = prior != nil && prior->ownsSurface;
            lease->originalFormat = inheriting ? prior->originalFormat : target.pixelFormat;
            lease->originalEDR = inheriting ? prior->originalEDR : target.wantsExtendedDynamicRangeContent;
            lease->originalSpace = inheriting ? prior->originalSpace : target.colorspace;
            lease->generation = owner_generation;
            lease->ownsSurface = YES;
            if (lease->originalSpace != nullptr) CGColorSpaceRetain(lease->originalSpace);
            objc_setAssociatedObject(target, &kDisplayLease, lease, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (objc_getAssociatedObject(target, &kDisplayLease) != lease) {
            return; // A newer renderer owns this layer now.
        }
        const bool wants_hdr = requested.load(std::memory_order_acquire) == 1;
        if (wants_hdr) Observe(); else RemoveObservers();
        const uint32_t identity = display_id.load(std::memory_order_acquire);
        const auto info = wants_hdr ? (provider ? provider(identity) : ReadDisplay(identity)) : MetalDisplayCharacteristics{};
        const bool extended = wants_hdr && std::isfinite(info.potential_headroom) && info.potential_headroom > 1.0f;
        const float headroom = extended && std::isfinite(info.current_headroom)
            ? std::clamp(info.current_headroom, 1.0f, info.potential_headroom) : 1.0f;
        const auto format = extended ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(extended
            ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceSRGB);
        const bool surface_changed = target.pixelFormat != format ||
            target.wantsExtendedDynamicRangeContent != extended ||
            target.colorspace == nullptr || !CFEqual(target.colorspace, space);
        if (surface_changed) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.pixelFormat = format;
            target.colorspace = space;
            target.wantsExtendedDynamicRangeContent = extended;
            [CATransaction commit];
        }
        CGColorSpaceRelease(space);
        const uint64_t now = Pack(headroom, extended);
        const bool headroom_changed = snapshot.exchange(now, std::memory_order_acq_rel) != now;
        if ((surface_changed || headroom_changed) && changed) changed();
    }
    void Stop() {
        active.store(false, std::memory_order_release);
        auto self = shared_from_this();
        OnMain([self] {
            self->RemoveObservers();
            CAMetalLayer* target = self->layer;
            if (target != nil && self->lease != nil &&
                objc_getAssociatedObject(target, &kDisplayLease) == self->lease) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                target.pixelFormat = self->lease->originalFormat;
                target.colorspace = self->lease->originalSpace;
                target.wantsExtendedDynamicRangeContent = self->lease->originalEDR;
                [CATransaction commit];
                self->lease->ownsSurface = NO;
                // Keep one generation fence on this layer until its next owner
                // or destruction; delayed older first-acquires remain rejected.
            }
            self->lease = nil;
        });
    }
};

MetalDisplayOutput::MetalDisplayOutput(CAMetalLayer* layer,
    std::function<MetalDisplayCharacteristics(uint32_t)> provider, std::function<void()> changed, uint32_t display_id)
    : state_(std::make_shared<State>(layer, std::move(provider), std::move(changed),display_id)) {}
MetalDisplayOutput::~MetalDisplayOutput() { state_->Stop(); }
void MetalDisplayOutput::Request(bool hdr) {
    const int mode = hdr ? 1 : 0;
    if (state_->requested.exchange(mode, std::memory_order_acq_rel) == mode) return;
    auto state = state_;
    OnMain([state] { state->Apply(); });
}
void MetalDisplayOutput::SetDisplayId(uint32_t identity) {
    if (state_->display_id.exchange(identity,std::memory_order_acq_rel) == identity) return;
    auto state=state_;
    OnMain([state] { state->Apply(); });
}
float MetalDisplayOutput::Headroom() const {
    return std::bit_cast<float>(uint32_t(state_->snapshot.load(std::memory_order_acquire)));
}
bool MetalDisplayOutput::Extended() const {
    return (state_->snapshot.load(std::memory_order_acquire) >> 32) != 0;
}
} // namespace wallpaper::metal
