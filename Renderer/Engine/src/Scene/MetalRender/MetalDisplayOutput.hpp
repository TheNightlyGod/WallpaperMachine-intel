#pragma once
#include "MetalRender/MetalRender.hpp"
#import <QuartzCore/CAMetalLayer.h>
#include <functional>
#include <memory>

namespace wallpaper::metal {
/// The layer's color contract and a notification-driven headroom snapshot.
/// There is no timer, frame polling or retained view/window here.
class MetalDisplayOutput {
public:
    MetalDisplayOutput(CAMetalLayer* layer,
                       std::function<MetalDisplayCharacteristics(uint32_t)> provider,
                       std::function<void()> changed, uint32_t display_id = 0);
    ~MetalDisplayOutput();
    void Request(bool display_hdr);
    void SetDisplayId(uint32_t identity);
    [[nodiscard]] float Headroom() const;
    [[nodiscard]] bool Extended() const;
private:
    struct State;
    std::shared_ptr<State> state_;
};
} // namespace wallpaper::metal
