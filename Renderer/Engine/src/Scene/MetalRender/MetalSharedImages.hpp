#pragma once

#import <Metal/Metal.h>

#include "Image.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace wallpaper::metal
{

/// What identifies one imported picture slot, besides its pixels.
struct SharedImageRequest
{
    id<MTLDevice>      device { nil };
    /// The texture name the scene's materials use.
    std::string        name;
    /// Which picture of the file this is; a sprite sheet has several.
    std::size_t        slot_index { 0 };
    MTLPixelFormat     format { MTLPixelFormatInvalid };
    /// The kept levels, exactly as parsed.
    const Image::Slot* slot { nullptr };
    uint32_t           bytes_per_pixel { 0 };
    /// Non-zero for a block-compressed format.
    uint32_t           block_bytes { 0 };
};

/// The imported pictures every renderer in the process shares.
///
/// One wallpaper on several displays is parsed by each of them (every display reads and
/// decodes the pictures itself), but a picture another display of the same GPU already holds
/// is not uploaded again: the displays bind one texture between them.
///
/// The cache holds its textures weakly. A renderer keeps the strong handle for as long as it
/// shows the picture, and the texture is freed with the last one. Entries whose texture is
/// gone are dropped on the next import.
///
/// A held texture is trusted only after its pixels, read back in bounded bands, compare equal
/// to the bytes the importing display just parsed: a name and a layout can be shared by a
/// file that changed, or by another wallpaper's file of the same name.
class SharedImageCache
{
public:
    static SharedImageCache& shared();

    /// Called with no lock held, for a picture no live texture matches. Creates the texture,
    /// writes the slot into it and returns it; nil when that fails.
    using Upload = std::function<id<MTLTexture>()>;

    /// The texture holding `request`'s picture: one another display holds if its pixels
    /// equal the request's, else the one `upload` makes (which then becomes the one other
    /// displays find). Imports of one key run one after another.
    id<MTLTexture> import(const SharedImageRequest& request, const Upload& upload);

#ifdef WESCENE_BUILD_TESTS
    /// Source bytes of the pictures that are alive right now, each counted once however many
    /// displays show it.
    [[nodiscard]] uint64_t liveBytes();
    /// Pictures that are alive right now.
    [[nodiscard]] std::size_t liveEntries();
    /// Entries held, dead or alive: what pruning keeps bounded.
    [[nodiscard]] std::size_t entries();
    /// Uploads made through `import` since the process started.
    [[nodiscard]] uint64_t uploads();
#endif

private:
    SharedImageCache() = default;
    struct Impl;
};

} // namespace wallpaper::metal
