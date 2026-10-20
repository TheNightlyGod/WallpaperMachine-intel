#pragma once

#include "Interface/IImageParser.h"
#include "Runtime/MediaArtwork.hpp"

#include <atomic>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

namespace wallpaper
{

class RuntimeImageSource final : public IImageParser {
public:
    explicit RuntimeImageSource(std::unique_ptr<IImageParser> fallback)
        : m_fallback(std::move(fallback)) {
        std::array<uint8_t, 4> transparent_pixel { 0, 0, 0, 0 };
        // Both cover slots exist before any track does: a layer that binds one
        // of them must find an image on the very first parse, and a wallpaper
        // with media integration off never gets a second chance to be told.
        SetRgbaImage("$mediaThumbnail", 1, 1, transparent_pixel.data(), transparent_pixel.size());
        SetRgbaImage(
            "$mediaPreviousThumbnail", 1, 1, transparent_pixel.data(), transparent_pixel.size());
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        std::string authored_name;
        {
            std::lock_guard lock(m_mutex);
            if (auto iterator = m_runtime_images.find(name); iterator != m_runtime_images.end()) {
                return iterator->second;
            }
            if (const auto slot = m_cover_slots.find(name); slot != m_cover_slots.end()) {
                if (auto cover = RealCoverLocked(slot->second); cover != nullptr) return cover;
                if (slot->second.authored != nullptr) return slot->second.authored;
                if (slot->second.authored_failed) return PlaceholderLocked(slot->second);
                authored_name = slot->second.authored_name;
            }
        }
        if (! authored_name.empty()) return ParseAuthoredForSlot(name, authored_name);
        return m_fallback != nullptr ? m_fallback->Parse(name) : nullptr;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        {
            std::lock_guard lock(m_mutex);
            if (auto iterator = m_runtime_images.find(name); iterator != m_runtime_images.end()) {
                return iterator->second->header;
            }
            // The authored picture's own header, whichever of the two the slot
            // shows: what a material reads from it while it loads is fixed then,
            // and must not depend on whether a track happens to be playing.
            if (const auto slot = m_cover_slots.find(name); slot != m_cover_slots.end()) {
                return slot->second.header;
            }
        }
        return m_fallback != nullptr ? m_fallback->ParseHeader(name) : ImageHeader {};
    }

    void SetTextureSurfaceSize(uint32_t width, uint32_t height) override {
        if (m_fallback != nullptr) m_fallback->SetTextureSurfaceSize(width, height);
    }

    bool IsRuntimeImage(const std::string& name) const {
        std::lock_guard lock(m_mutex);
        return m_runtime_images.find(name) != m_runtime_images.end() ||
               m_cover_slots.find(name) != m_cover_slots.end();
    }

    /// Whether `image`, what a cover name holds, is the empty texel the cover
    /// names start as and a clear leaves rather than a track's cover. A slot
    /// whose authored texture is a render target, another layer's composite,
    /// samples that target while its cover is empty
    /// (`SceneMaterial::texture_covers`): the target is not a picture this
    /// source can hold, so the renderer decides where it binds the pass's
    /// textures, from the very image it uploads.
    static bool IsEmptyCover(const Image& image) {
        if (image.header.width != 1 || image.header.height != 1 || image.slots.empty()) {
            return false;
        }
        const auto& mipmaps = image.slots.front().mipmaps;
        return ! mipmaps.empty() && mipmaps.front().data != nullptr &&
               mipmaps.front().size >= 4 &&
               IsEmptyCoverPixel(1, 1, mipmaps.front().data.get()[3]);
    }

    /// Changes whenever a name joins or leaves this source (`RemoveImage`,
    /// `BindCoverSlot`).
    ///
    /// Lock-free, so a renderer can keep its per-slot `IsRuntimeImage` answers
    /// and only ask again when this moves.
    uint64_t NamesGeneration() const { return m_names_generation.load(std::memory_order_acquire); }

    /// How many times this name has been given new pixels, or zero when it
    /// never has.
    ///
    /// Monotonic per name and readable without taking a copy of the image, so a
    /// renderer can ask "is what I uploaded still current?" every frame without
    /// hashing pixels. The same number is what `Image::key` carries, so the two
    /// can never disagree.
    uint64_t Version(const std::string& name) const {
        std::lock_guard lock(m_mutex);
        // A cover slot shows either its cover or the picture standing in for it,
        // and every publication and clear of the cover moves the cover's own
        // version, so the slot follows that number.
        const auto slot     = m_cover_slots.find(name);
        const auto iterator = m_versions.find(slot == m_cover_slots.end() ? name
                                                                          : slot->second.cover);
        return iterator == m_versions.end() ? 0 : iterator->second;
    }

    /// Whether `name` already holds exactly these pixels.
    ///
    /// Republishing an identical image is not free and not neutral: it retires
    /// the texture the GPU is sampling, allocates and uploads another, and —
    /// for a cover — moves the current image into `$mediaPreviousThumbnail`,
    /// which is what a wallpaper cross-fades *from*, so a replay would fade a
    /// cover into itself. Replays are normal: every new scene handle is sent
    /// the current cover again. One comparison against bytes already in memory
    /// is cheaper than any of that.
    bool MatchesRgba(const std::string& name, uint32_t width, uint32_t height,
                     const uint8_t* rgba, std::size_t rgba_len) const {
        if (rgba == nullptr) return false;
        std::lock_guard lock(m_mutex);
        const auto iterator = m_runtime_images.find(name);
        if (iterator == m_runtime_images.end() || iterator->second == nullptr) return false;
        const auto& image = *iterator->second;
        if (image.header.format != TextureFormat::RGBA8) return false;
        if (image.header.width != static_cast<int32_t>(width) ||
            image.header.height != static_cast<int32_t>(height)) {
            return false;
        }
        if (image.slots.empty() || image.slots.front().mipmaps.empty()) return false;
        const auto& mip = image.slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size < 0) return false;
        if (static_cast<std::size_t>(mip.size) != rgba_len) return false;
        return std::memcmp(mip.data.get(), rgba, rgba_len) == 0;
    }

    void SetRgbaImage(std::string name, uint32_t width, uint32_t height, const uint8_t* rgba,
                      std::size_t rgba_len) {
        if (name.empty() || width == 0 || height == 0 || rgba == nullptr) return;
        if (width > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
            height > static_cast<uint32_t>(std::numeric_limits<int32_t>::max())) {
            return;
        }

        const std::size_t pixel_count = static_cast<std::size_t>(width) * height;
        if (pixel_count > std::numeric_limits<std::size_t>::max() / 4) return;

        const std::size_t expected_len = pixel_count * 4;
        if (rgba_len != expected_len) return;

        const auto version             = m_next_version.fetch_add(1, std::memory_order_relaxed) + 1;
        auto       image               = std::make_shared<Image>();
        image->key                     = name + "#" + std::to_string(version);
        image->header.width            = static_cast<int32_t>(width);
        image->header.height           = static_cast<int32_t>(height);
        image->header.mapWidth         = static_cast<int32_t>(width);
        image->header.mapHeight        = static_cast<int32_t>(height);
        image->header.count            = 1;
        image->header.format           = TextureFormat::RGBA8;
        image->header.sample.wrapS     = TextureWrap::CLAMP_TO_EDGE;
        image->header.sample.wrapT     = TextureWrap::CLAMP_TO_EDGE;
        image->header.sample.minFilter = TextureFilter::LINEAR;
        image->header.sample.magFilter = TextureFilter::LINEAR;
        image->header.extraHeader["compo1"].val = 1;
        image->header.extraHeader["compo2"].val = 1;
        image->header.extraHeader["compo3"].val = 1;
        image->header.extraHeader["compo4"].val = 1;

        Image::Slot slot;
        slot.width  = static_cast<int32_t>(width);
        slot.height = static_cast<int32_t>(height);

        ImageData mip;
        mip.width  = slot.width;
        mip.height = slot.height;
        mip.size   = static_cast<isize>(expected_len);
        mip.data   = ImageDataPtr(new uint8_t[expected_len], [](uint8_t* data) {
            delete[] data;
        });
        std::memcpy(mip.data.get(), rgba, expected_len);
        slot.mipmaps.push_back(std::move(mip));
        image->slots.push_back(std::move(slot));

        std::lock_guard lock(m_mutex);
        const auto names_before = m_runtime_images.size();
        if (name == "$mediaThumbnail") {
            const auto previous = m_runtime_images.find(name);
            const bool cleared  = IsEmptyCoverPixel(width, height, rgba[3]);
            // Keep the outgoing cover's image and version together. The new
            // version belongs to the pixels being published now; stamping it
            // onto the previous slot made Version() disagree with Image::key.
            if (!cleared && previous != m_runtime_images.end()) {
                const auto old_version              = m_versions.find(name);
                m_runtime_images["$mediaPreviousThumbnail"] = previous->second;
                m_versions["$mediaPreviousThumbnail"] =
                    old_version == m_versions.end() ? 0 : old_version->second;
            } else {
                m_runtime_images["$mediaPreviousThumbnail"] = image;
                m_versions["$mediaPreviousThumbnail"]       = version;
            }
        }
        m_versions[name]                  = version;
        m_runtime_images[std::move(name)] = std::move(image);
        if (m_runtime_images.size() != names_before) {
            m_names_generation.fetch_add(1, std::memory_order_release);
        }
    }

    /// Forgets the pixels given to `name`, for an image whose owner is gone (the
    /// text layer a script made and destroyed), so images made and dropped over
    /// and over do not accumulate. Only a render graph built without the owner
    /// may call this: until then it still samples the image. The two cover slots
    /// (`$`-names) are the source's own and are never removed. Answers whether
    /// there was anything to remove.
    bool RemoveImage(const std::string& name) {
        if (name.empty() || name.front() == '$') return false;
        std::lock_guard lock(m_mutex);
        if (m_runtime_images.erase(name) == 0) return false;
        m_versions.erase(name);
        m_names_generation.fetch_add(1, std::memory_order_release);
        return true;
    }

    /// Publishes what `from` currently holds under `to`, without copying pixels.
    ///
    /// `SetRgbaImage` builds a fresh immutable `Image` every time, so two names
    /// may share one: replacing `from` afterwards leaves `to` holding exactly
    /// what `from` used to be. `to` inherits `from`'s version so the number and
    /// the `Image::key` it is taken from keep agreeing, and it still only ever
    /// rises because `from`'s own version does.
    ///
    /// Returns false when `from` has never been given pixels.
    bool AliasRuntimeImage(const std::string& from, const std::string& to) {
        std::lock_guard lock(m_mutex);
        const auto iterator = m_runtime_images.find(from);
        if (iterator == m_runtime_images.end()) return false;
        const auto names_before = m_runtime_images.size();
        m_runtime_images[to] = iterator->second;
        m_versions[to]       = m_versions[from];
        if (m_runtime_images.size() != names_before) {
            m_names_generation.fetch_add(1, std::memory_order_release);
        }
        return true;
    }

    /// Binds a texture slot that asks for a cover to the picture its author left
    /// in that slot, and returns the name the slot samples.
    ///
    /// A cover layer ships its own art in the slot (the wallpaper's default
    /// cover) and names `$mediaThumbnail` or `$mediaPreviousThumbnail` as what
    /// the runtime puts there. Wallpaper Engine keeps the authored picture
    /// until there is a cover to show, so a layer that has nothing playing shows
    /// its art rather than the 1x1 transparent texel those names start as. The
    /// returned name shows the cover while one is published and the authored
    /// picture while it is not -- before the first track, and again after the
    /// explicit clear. It is an ordinary runtime image to a renderer
    /// (`IsRuntimeImage`, `Version`, `Parse`), so a track change swaps it on the
    /// next frame without a graph rebuild and an idle slot costs the integer
    /// version check it already did.
    ///
    /// The cover's own name comes back unchanged when there is nothing to stand
    /// in: no authored name, a picture this source cannot read, one that is a
    /// video or a sprite sheet, or one whose format the cover does not share
    /// (a mask or a normal map: the shader a material is compiled with reads
    /// its channels differently from a cover's, `ApplyTextureFormatCombo`). The
    /// authored picture is decoded the first time a renderer asks for it, not
    /// here, so a texture budget set after the scene parsed still applies to
    /// it, and stays resident after that so a clear does not decode it again.
    std::string BindCoverSlot(const std::string& cover_name, const std::string& authored_name) {
        if (m_fallback == nullptr || authored_name.empty() || ! IsCoverName(cover_name)) {
            return cover_name;
        }
        std::string slot_name = cover_name + '|' + authored_name;
        {
            std::lock_guard lock(m_mutex);
            if (m_cover_slots.find(slot_name) != m_cover_slots.end()) return slot_name;
        }
        auto header = m_fallback->ParseHeader(authored_name);
        if (header.isVideo || header.isSprite || header.mapWidth <= 0 || header.mapHeight <= 0 ||
            ! IsColourPicture(header.format)) {
            return cover_name;
        }
        std::lock_guard lock(m_mutex);
        const auto inserted = m_cover_slots.try_emplace(slot_name);
        if (inserted.second) {
            auto& slot          = inserted.first->second;
            slot.cover          = cover_name;
            slot.authored_name  = authored_name;
            slot.header         = std::move(header);
            m_names_generation.fetch_add(1, std::memory_order_release);
        }
        return slot_name;
    }

private:
    /// One slot bound by `BindCoverSlot`.
    struct CoverSlot {
        /// The cover name whose image the slot shows once there is one.
        std::string            cover;
        std::string            authored_name;
        /// The authored picture's header, read when the slot was bound.
        ImageHeader            header;
        /// The authored picture, decoded on first need.
        std::shared_ptr<Image> authored;
        /// The picture could not be decoded: the slot shows the cover's own
        /// image, transparent while idle, as it did before slots existed.
        bool                   authored_failed { false };
    };

    static bool IsCoverName(const std::string& name) {
        return name == "$mediaThumbnail" || name == "$mediaPreviousThumbnail";
    }

    /// What the cover names hold when no track does: one transparent texel,
    /// which is also what an explicit clear publishes.
    static bool IsEmptyCoverPixel(uint32_t width, uint32_t height, uint8_t alpha) {
        return width == 1 && height == 1 && alpha == 0;
    }

    /// The formats a cover can stand in for: colour pictures, which a shader
    /// reads the same way whether the slot holds the art or a track's RGBA.
    static bool IsColourPicture(TextureFormat format) {
        return format == TextureFormat::RGBA8 || format == TextureFormat::BC1 ||
               format == TextureFormat::BC2 || format == TextureFormat::BC3;
    }

    /// The image a cover name holds when it holds a track's cover, not the
    /// empty one. Caller holds the lock.
    std::shared_ptr<Image> RealCoverLocked(const CoverSlot& slot) const {
        const auto cover = m_runtime_images.find(slot.cover);
        if (cover == m_runtime_images.end() || cover->second == nullptr ||
            IsEmptyCover(*cover->second)) {
            return nullptr;
        }
        return cover->second;
    }

    std::shared_ptr<Image> PlaceholderLocked(const CoverSlot& slot) const {
        const auto cover = m_runtime_images.find(slot.cover);
        return cover == m_runtime_images.end() ? nullptr : cover->second;
    }

    /// Decodes a slot's authored picture the first time it is needed. Outside
    /// the lock: it reads a file, and a renderer asks about versions every
    /// frame. Two threads asking at once both decode and one result is kept.
    std::shared_ptr<Image> ParseAuthoredForSlot(const std::string& slot_name,
                                                const std::string& authored_name) {
        auto decoded = m_fallback != nullptr ? m_fallback->Parse(authored_name) : nullptr;
        if (decoded != nullptr &&
            (decoded->header.isVideo || decoded->slots.empty() ||
             decoded->slots.front().mipmaps.empty())) {
            decoded = nullptr;
        }
        std::lock_guard lock(m_mutex);
        const auto      slot = m_cover_slots.find(slot_name);
        if (slot == m_cover_slots.end()) return decoded;
        if (slot->second.authored == nullptr && decoded != nullptr) {
            slot->second.authored = std::move(decoded);
        }
        slot->second.authored_failed = slot->second.authored == nullptr;
        // What the slot shows now: a cover may have arrived while this decoded.
        if (auto cover = RealCoverLocked(slot->second); cover != nullptr) return cover;
        return slot->second.authored != nullptr ? slot->second.authored
                                                : PlaceholderLocked(slot->second);
    }

    mutable std::mutex                                      m_mutex;
    std::unique_ptr<IImageParser>                           m_fallback;
    std::unordered_map<std::string, std::shared_ptr<Image>> m_runtime_images;
    std::unordered_map<std::string, CoverSlot>              m_cover_slots;
    std::unordered_map<std::string, uint64_t>               m_versions;
    std::atomic<uint64_t>                                   m_next_version { 0 };
    std::atomic<uint64_t>                                   m_names_generation { 0 };
};

/// Publishes one now-playing cover, and reports whether anything changed.
///
/// The cover being replaced becomes `$mediaPreviousThumbnail`, which is what a
/// wallpaper cross-fades from, so it has to be captured before the new pixels
/// land. One definition, because the renderer and the offscreen probe must
/// publish covers the same way.
///
/// Returns false when the cover on screen is already exactly this one, so a
/// caller can skip the work a change would have needed.
inline bool PublishSystemMediaArtwork(RuntimeImageSource& source, uint32_t width, uint32_t height,
                                      const uint8_t* rgba, std::size_t rgba_len) {
    if (! IsValidSystemMediaArtwork(width, height, rgba, rgba_len)) return false;
    if (IsClearSystemMediaArtwork(width, height, rgba_len)) {
        constexpr std::array<uint8_t, 4> transparent {};
        if (source.MatchesRgba("$mediaThumbnail", 1, 1, transparent.data(), transparent.size()) &&
            source.MatchesRgba("$mediaPreviousThumbnail", 1, 1, transparent.data(), transparent.size())) return false;
        source.SetRgbaImage("$mediaThumbnail", 1, 1, transparent.data(), transparent.size());
        return true;
    }
    if (source.MatchesRgba("$mediaThumbnail", width, height, rgba, rgba_len)) return false;
    source.AliasRuntimeImage("$mediaThumbnail", "$mediaPreviousThumbnail");
    source.SetRgbaImage("$mediaThumbnail", width, height, rgba, rgba_len);
    return true;
}

} // namespace wallpaper
