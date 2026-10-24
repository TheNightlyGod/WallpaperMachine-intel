#pragma once

#include <memory>

namespace wallpaper
{
struct Image;

namespace video
{

/// A private copy of what a video source reads from `image`: its key, its
/// video mark, the file it names and the bytes of its first mip.
///
/// For a caller that holds an image by reference and has no ownership to
/// share (a texture cache), so a source opened on the copy does not
/// depend on the caller's image staying alive. Anything that owns its image
/// through a `shared_ptr` passes that instead, which copies nothing.
std::shared_ptr<const Image> SnapshotVideoImage(const Image& image);

} // namespace video
} // namespace wallpaper
