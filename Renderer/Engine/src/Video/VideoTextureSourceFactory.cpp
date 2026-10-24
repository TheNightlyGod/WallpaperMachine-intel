#include "Image.hpp"
#include "Video/ClockedVideoSource.hpp"
#include "Video/NativeVideoBackend.hpp"
#include "Video/VideoTextureSource.hpp"

#include <memory>
#include <string>
#include <utility>

namespace wallpaper::video
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

} // namespace

/// Every video plays with the native backend: the project's own container
/// readers and VideoToolbox. What it cannot play fails with its own reason, which
/// names the format, and nothing else is tried.
std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(std::shared_ptr<const Image> image,
                                                             std::string* error)
{
    if (image == nullptr) {
        SetError(error, "video texture has no image");
        return nullptr;
    }
    if (!image->header.isVideo) {
        SetError(error, "image is not marked as a video texture");
        return nullptr;
    }
    std::string label = image->key;
    return std::make_shared<ClockedVideoSource>(std::make_unique<NativeVideoBackend>(std::move(image)),
                                                std::move(label));
}

std::shared_ptr<VideoTextureSource> CreateVideoTextureSourceForFile(std::string media_path, std::string* error)
{
    if (media_path.empty()) {
        SetError(error, "video media path must not be empty");
        return nullptr;
    }
    std::string label = media_path;
    return std::make_shared<ClockedVideoSource>(std::make_unique<NativeVideoBackend>(std::move(media_path)),
                                                std::move(label));
}

} // namespace wallpaper::video
