#include "MetalSharedImages.hpp"

#include "MetalImageLevels.hpp"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string_view>
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
    /// The GPU work that rearranges the texture for sampling (`OptimizeForSampling`), which a
    /// read-back of the texture waits for.
    id<MTLCommandBuffer>        optimizing { nil };
};

struct State
{
    std::mutex                                 mutex;
    std::unordered_map<Key, Entry, KeyHash>    entries;
    std::atomic<uint64_t>                      uploads { 0 };
    std::atomic<uint64_t>                      levels_read_back { 0 };
    std::atomic<uint64_t>                      optimized { 0 };
};

State& StateOf()
{
    static State state;
    return state;
}

/// Whether a new upload is rearranged for the GPU. On by default;
/// `WALLPAPER_MACHINE_OPTIMIZE_IMAGES=0` leaves every picture as the CPU wrote it, for an A/B.
/// A measurement switch only: both ways sample the same bytes. Read once.
std::atomic<bool>& OptimizeSwitch()
{
    static std::atomic<bool> enabled { [] {
        const char* value = std::getenv("WALLPAPER_MACHINE_OPTIMIZE_IMAGES");
        return value == nullptr || std::string_view(value) != "0";
    }() };
    return enabled;
}

/// A picture is written by the CPU into shared storage, in the layout the CPU writes, which
/// the GPU then reads uncompressed: on Apple GPUs only a texture the GPU itself lays out is
/// losslessly compressed. One blit, queued on `queue` ahead of any frame that samples the
/// picture, rearranges it once, and sampling it then reads a fraction of the memory (an
/// illustrated 4068x1979 layer drawn at three quarters of its size: 0.042 instead of 0.125 ms
/// of GPU time on an M5 Pro; random noise, which does not compress, unchanged). The values
/// sampled, and the bytes the CPU reads back, do not change. A block-compressed picture is
/// compressed already, and a volume is left as written.
id<MTLCommandBuffer> OptimizeForSampling(id<MTLTexture> texture, id<MTLCommandQueue> queue,
                                         uint32_t block_bytes)
{
    if (queue == nil || block_bytes > 0 || texture.textureType != MTLTextureType2D) return nil;
    if (! OptimizeSwitch().load(std::memory_order_relaxed)) return nil;
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (command_buffer == nil) return nil;
    command_buffer.label = @"picture: optimize for sampling";
    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    if (blit == nil) return nil;
    [blit optimizeContentsForGPUAccess:texture];
    [blit endEncoding];
    // Committed at once, so every frame on this queue that samples the picture comes after it.
    [command_buffer commit];
    return command_buffer;
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
    key.layout.push_back(request.depth);
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
        texture.height != static_cast<NSUInteger>(slot.height) ||
        texture.depth != static_cast<NSUInteger>(std::max(slot.depth, 1))) {
        return false;
    }
    std::vector<uint8_t> band;
    for (std::size_t level = 0; level < slot.mipmaps.size(); ++level) {
        const auto& mipmap = slot.mipmaps[level];
        // A level with no data was never written, so there is nothing to compare.
        if (mipmap.data == nullptr || mipmap.width <= 0 || mipmap.height <= 0) continue;
        // A level the upload clipped to its extent, or skipped, is not read back at the size
        // the file claims, which lies outside it: such a picture is uploaded afresh.
        if (! LevelIsWrittenWhole(texture, mipmap, level, block_bytes)) return false;
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
        const std::size_t depth = static_cast<std::size_t>(std::max(mipmap.depth, 1));
        if (mipmap.size < 0 || static_cast<std::size_t>(mipmap.size) < bytes_per_row * rows * depth) return false;
        if (bytes_per_row == 0) return false;

        StateOf().levels_read_back.fetch_add(1, std::memory_order_relaxed);
        const std::size_t band_rows = std::max<std::size_t>(1, kBandBytes / bytes_per_row);
        band.resize(std::min(rows, band_rows) * bytes_per_row);
        for (std::size_t z = 0; z < depth; ++z) {
            const uint8_t* source = mipmap.data.get() + z * rows * bytes_per_row;
            for (std::size_t row = 0; row < rows; row += band_rows) {
                const std::size_t count = std::min(band_rows, rows - row);
                const std::size_t first = row * rows_per_unit;
                const std::size_t high  = std::min(count * rows_per_unit, height - first);
                [texture getBytes:band.data()
                      bytesPerRow:bytes_per_row
                    bytesPerImage:depth > 1 ? count * bytes_per_row : 0
                       fromRegion:MTLRegionMake3D(0, first, z, width, high, 1)
                      mipmapLevel:level
                            slice:0];
                if (std::memcmp(band.data(), source + row * bytes_per_row, count * bytes_per_row) != 0) {
                    return false;
                }
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
    id<MTLTexture>       held       = nil;
    id<MTLCommandBuffer> optimizing = nil;
    {
        const std::lock_guard lock { state.mutex };
        const auto& entry = state.entries[key];
        held              = entry.texture;
        optimizing        = entry.optimizing;
    }
    // The CPU reads the texture back only once the GPU has rearranged it, which is long done by
    // the time another display loads, as a rule; the bytes read are the ones written.
    if (held != nil && optimizing != nil) [optimizing waitUntilCompleted];
    if (held != nil && PixelsEqual(held, *request.slot, request.bytes_per_pixel, request.block_bytes)) {
        return held;
    }

    id<MTLTexture> made = upload();
    if (made == nil) return nil;
    state.uploads.fetch_add(1, std::memory_order_relaxed);
    id<MTLCommandBuffer> optimized = OptimizeForSampling(made, request.queue, request.block_bytes);
    if (optimized != nil) state.optimized.fetch_add(1, std::memory_order_relaxed);
    {
        const std::lock_guard lock { state.mutex };
        auto& entry      = state.entries[key];
        entry.texture    = made;
        entry.bytes      = SourceBytes(*request.slot);
        entry.optimizing = optimized;
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

uint64_t SharedImageCache::levelsReadBack()
{
    return StateOf().levels_read_back.load(std::memory_order_relaxed);
}

uint64_t SharedImageCache::optimized()
{
    return StateOf().optimized.load(std::memory_order_relaxed);
}

void SharedImageCache::setOptimizationForTests(bool enabled)
{
    OptimizeSwitch().store(enabled, std::memory_order_relaxed);
}
#endif

} // namespace wallpaper::metal
