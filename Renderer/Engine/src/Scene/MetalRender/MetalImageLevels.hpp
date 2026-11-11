#pragma once

#import <Metal/Metal.h>

#include "Image.hpp"

#include <cstddef>
#include <cstdint>

namespace wallpaper::metal
{

/// The texture for one parsed picture slot, sized by the slot and holding its levels as
/// `format`: the pixels, or the 4x4 blocks when `block_bytes` is non-zero (`bytes_per_pixel`
/// then means nothing). Shared storage, so the levels are written straight into it. nil when
/// the device refuses the texture or a level cannot be written safely.
id<MTLTexture> MakeImageTexture(id<MTLDevice> device, MTLPixelFormat format, const Image::Slot& slot,
                                uint32_t bytes_per_pixel, uint32_t block_bytes);

/// How many of a picture's `levels` a `width` x `height` texture holds: the file names the
/// levels, but a texture has no more than the halvings of its size down to 1x1.
NSUInteger ImageTextureLevels(std::size_t levels, NSUInteger width, NSUInteger height);

/// Whether `texture`'s level `level` holds all of `mipmap` as the file states it: the level lies
/// inside its extent and, block-compressed, ends on whole blocks or at the extent's edge. A level
/// that does not is written clipped, or not at all, so it cannot be read back at its own size.
bool LevelIsWrittenWhole(id<MTLTexture> texture, const ImageData& mipmap, NSUInteger level,
                         uint32_t block_bytes);

/// Writes the levels of `slot` that `texture` holds, each inside its own extent in the texture
/// whatever size the file gives it. A level with no data, or a block-compressed one that stops
/// inside a block short of its edge, is skipped; false when a level is shorter than the rows it
/// fills, which the copy would read past, and then no level is written.
bool UploadImageLevels(id<MTLTexture> texture, const Image::Slot& slot, uint32_t bytes_per_pixel,
                       uint32_t block_bytes);

} // namespace wallpaper::metal
