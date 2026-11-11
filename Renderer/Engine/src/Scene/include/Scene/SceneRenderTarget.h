#pragma once
#include "SceneTexture.h"
#include "Core/Literals.hpp"
#include <array>

namespace wallpaper
{

struct SceneRenderTarget {
    struct Bind {
        enum class SizePolicy { Effect, NativeFramebuffer };
        bool        enable { false };
        std::string name {};
        bool        screen { false };
        double      scale { 1.0 };
        /// Authored effect buffers round to at least four pixels. Native
        /// framebuffer reductions truncate to at least two (WE 0x1400D2C60).
        SizePolicy  size_policy { SizePolicy::Effect };
    };

    i32           width;
    i32           height;
    /// The size this target has at render scale 1.0, i.e. the size the scene
    /// author's composition implies. Zero until the first size resolve, which
    /// latches whatever the parser produced; from then on the physical
    /// `width`/`height` above are derived from these by the internal render
    /// scale, so repeated scale changes never compound rounding.
    i32           authored_width { 0 };
    i32           authored_height { 0 };
    bool          allowReuse { false };
    bool          forceClear { false };
    bool          withDepth { false };
    bool          has_mipmap { false };
    uint          mipmap_level { 1 };
    TextureSample sample { TextureWrap::CLAMP_TO_EDGE,
                           TextureWrap::CLAMP_TO_EDGE,
                           TextureFilter::LINEAR,
                           TextureFilter::LINEAR };
    Bind          bind {};
    uint32_t      sample_count { 1 };
    /// Authored color intermediates may exceed one; masks/media keep RGBA8.
    TextureFormat format { TextureFormat::RGBA8 };
    /// Read in a frame before anything writes it, so it holds what the previous
    /// frame left there (an effect's history buffer). It owns its image: one
    /// shared with another target would hold that target's pixels instead.
    bool          carriesPreviousFrame { false };
    /// Kept at the size the scene gave it whatever the internal render scale is (the shadow
    /// atlas: its tiles are laid out in texels of the shadows quality).
    bool          unscaled { false };
    /// What the target is cleared to whenever it is made: an effect buffer's `clear` colour
    /// (`sub_1401EA500`); transparent black otherwise.
    std::array<float, 4> initial_clear { 0.0f, 0.0f, 0.0f, 0.0f };
};
} // namespace wallpaper
