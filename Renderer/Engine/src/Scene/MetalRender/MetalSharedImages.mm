#include "MetalSharedImages.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace wallpaper::metal
{

namespace
{

/// How much of a texture is read back at a time when a held picture is compared.
constexpr std::size_t kBandBytes = 1u << 20;

struct Key
{
    uint64_t             device { 0 };
    std::string          name;
    /// Slot index, pixel format, slot size, then for every level its size and its byte count.
    std::vector<int64_t> layout;

    friend bool operator==(const Key&, const Key&) = default;
};

struct KeyHash
{
    std::size_t operator()(const Key& key) const noexcept
    {
        std::size_t hash = std::hash<uint64_t> {}(key.device);
        const auto  fold = [&hash](std::size_t value) {
            hash ^= value + 0x9e3779b97f4a7c15ull + (hash << 6) + (hash >> 2);
        };
        fold(std::hash<std::string> {}(key.name));
        for (const int64_t value : key.layout) fold(std::hash<int64_t> {}(value));
        return hash;
    }
};

struct Entry
{
    __weak id<MTLTexture>       texture { nil };
    /// Taken for the whole of an import of this key, so displays loading together share.
    std::shared_ptr<std::mutex> gate { std::make_shared<std::mutex>() };
    uint64_t                    bytes { 0 };
};

struct State
{
    std::mutex                                 mutex;
    std::unordered_map<Key, Entry, KeyHash>    entries;
    std::atomic<uint64_t>                      uploads { 0 };
};

State& StateOf()
{
    static State state;
    return state;
}

Key KeyFor(const SharedImageRequest& request)
{
    Key key;
    key.device = request.device.registryID;
    key.name   = request.name;
    const Image::Slot& slot = *request.slot;
    key.layout.push_back(static_cast<int64_t>(request.slot_index));
    key.layout.push_back(static_cast<int64_t>(request.format));
    key.layout.push_back(slot.width);
    key.layout.push_back(slot.height);
    for (const auto& level : slot.mipmaps) {
        key.layout.push_back(level.width);
        key.layout.push_back(level.height);
        key.layout.push_back(level.data != nullptr ? static_cast<int64_t>(level.size) : -1);
    }
    return key;
}

uint64_t SourceBytes(const Image::Slot& slot)
{
    uint64_t bytes = 0;
    for (const auto& level : slot.mipmaps) {
        if (level.data != nullptr && level.size > 0) bytes += static_cast<uint64_t>(level.size);
    }
    return bytes;
}

/// Whether `texture` holds, level for level, the bytes `slot` holds. Read back from shared
/// storage in bands of about a megabyte, so a large picture costs no large allocation.
bool PixelsEqual(id<MTLTexture> texture, const Image::Slot& slot, uint32_t bytes_per_pixel,
                 uint32_t block_bytes)
{
    if (texture.storageMode != MTLStorageModeShared) return false;
    if (texture.mipmapLevelCount != slot.mipmaps.size()) return false;
    if (texture.width != static_cast<NSUInteger>(slot.width) ||
        texture.height != static_cast<NSUInteger>(slot.height)) {
        return false;
    }
    std::vector<uint8_t> band;
    for (std::size_t level = 0; level < slot.mipmaps.size(); ++level) {
        const auto& mipmap = slot.mipmaps[level];
        // A level with no data was never written, so there is nothing to compare.
        if (mipmap.data == nullptr || mipmap.width <= 0 || mipmap.height <= 0) continue;
        const std::size_t width = static_cast<std::size_t>(mipmap.width);
        const std::size_t height = static_cast<std::size_t>(mipmap.height);

        // A row is counted in pixels, or for a block-compressed format in blocks of 4x4 pixels.
        std::size_t bytes_per_row = width * bytes_per_pixel;
        std::size_t rows          = height;
        std::size_t rows_per_unit = 1;
        if (block_bytes > 0) {
            bytes_per_row = ((width + 3) / 4) * block_bytes;
            rows          = (height + 3) / 4;
            rows_per_unit = 4;
        }
        if (mipmap.size < 0 || static_cast<std::size_t>(mipmap.size) < bytes_per_row * rows) return false;
        if (bytes_per_row == 0) return false;

        const std::size_t band_rows = std::max<std::size_t>(1, kBandBytes / bytes_per_row);
        band.resize(std::min(rows, band_rows) * bytes_per_row);
        const uint8_t* source = mipmap.data.get();
        for (std::size_t row = 0; row < rows; row += band_rows) {
            const std::size_t count = std::min(band_rows, rows - row);
            const std::size_t first = row * rows_per_unit;
            const std::size_t high  = std::min(count * rows_per_unit, height - first);
            [texture getBytes:band.data()
                  bytesPerRow:bytes_per_row
                   fromRegion:MTLRegionMake2D(0, first, width, high)
                  mipmapLevel:level];
            if (std::memcmp(band.data(), source + row * bytes_per_row, count * bytes_per_row) != 0) {
                return false;
            }
        }
    }
    return true;
}

} // namespace

SharedImageCache& SharedImageCache::shared()
{
    static SharedImageCache cache;
    return cache;
}

id<MTLTexture> SharedImageCache::import(const SharedImageRequest& request, const Upload& upload)
{
    if (request.device == nil || request.slot == nullptr) return nil;
    State&    state = StateOf();
    const Key key   = KeyFor(request);

    std::shared_ptr<std::mutex> gate;
    {
        const std::lock_guard lock { state.mutex };
        // Keys whose texture is gone, and that no import is working on, are dropped now.
        for (auto it = state.entries.begin(); it != state.entries.end();) {
            if (it->second.texture == nil && it->second.gate.use_count() == 1) {
                it = state.entries.erase(it);
            } else {
                ++it;
            }
        }
        gate = state.entries[key].gate;
    }

    const std::lock_guard serialised { *gate };
    id<MTLTexture> held = nil;
    {
        const std::lock_guard lock { state.mutex };
        held = state.entries[key].texture;
    }
    if (held != nil && PixelsEqual(held, *request.slot, request.bytes_per_pixel, request.block_bytes)) {
        return held;
    }

    id<MTLTexture> made = upload();
    if (made == nil) return nil;
    state.uploads.fetch_add(1, std::memory_order_relaxed);
    {
        const std::lock_guard lock { state.mutex };
        auto& entry   = state.entries[key];
        entry.texture = made;
        entry.bytes   = SourceBytes(*request.slot);
    }
    return made;
}

#ifdef WESCENE_BUILD_TESTS
uint64_t SharedImageCache::liveBytes()
{
    State&                state = StateOf();
    const std::lock_guard lock { state.mutex };
    uint64_t              bytes = 0;
    for (const auto& [key, entry] : state.entries) {
        (void)key;
        if (entry.texture != nil) bytes += entry.bytes;
    }
    return bytes;
}

std::size_t SharedImageCache::liveEntries()
{
    State&                state = StateOf();
    const std::lock_guard lock { state.mutex };
    return static_cast<std::size_t>(std::count_if(state.entries.begin(), state.entries.end(), [](const auto& pair) {
        return pair.second.texture != nil;
    }));
}

std::size_t SharedImageCache::entries()
{
    State&                state = StateOf();
    const std::lock_guard lock { state.mutex };
    return state.entries.size();
}

uint64_t SharedImageCache::uploads()
{
    return StateOf().uploads.load(std::memory_order_relaxed);
}
#endif

} // namespace wallpaper::metal
