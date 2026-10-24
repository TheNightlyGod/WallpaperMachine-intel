#include "Video/VideoMedia.hpp"

#include "Image.hpp"

#include <cstring>
#include <filesystem>
#include <utility>

namespace wallpaper::video
{
std::shared_ptr<const Image> SnapshotVideoImage(const Image& image)
{
    auto copy                = std::make_shared<Image>();
    copy->key                = image.key;
    copy->header.isVideo     = image.header.isVideo;
    copy->videoFilePath      = image.videoFilePath;
    if (image.slots.empty() || image.slots.front().mipmaps.empty()) return copy;

    const auto& mip = image.slots.front().mipmaps.front();
    Image::Slot slot;
    ImageData   data;
    data.size = mip.size;
    if (mip.data != nullptr && mip.size > 0) {
        const auto size = static_cast<size_t>(mip.size);
        data.data = ImageDataPtr(new uint8_t[size], [](uint8_t* bytes) { delete[] bytes; });
        std::memcpy(data.data.get(), mip.data.get(), size);
    }
    slot.mipmaps.push_back(std::move(data));
    copy->slots.push_back(std::move(slot));
    return copy;
}

} // namespace wallpaper::video
