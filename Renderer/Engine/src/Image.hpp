#pragma once
#include <cstdint>
#include <vector>
#include <memory>
#include <unordered_map>
#include <functional>

#include "Core/Literals.hpp"
#include "Type.hpp"
#include "SpriteAnimation.hpp"
#include "Scene/SceneTexture.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{

union ImageExtra {
    int32_t val { 0 };
    char    str[125];
};

typedef std::unique_ptr<uint8_t, std::function<void(uint8_t*)>> ImageDataPtr;

struct ImageData {
    i32          width { 0 };
    i32          height { 0 };
    isize        size { 0 };
    ImageDataPtr data {};
    ImageData() = default;
};

struct ImageHeader {
    i32 width { 0 };
    i32 height { 0 };
    i32 mapWidth { 0 };
    i32 mapHeight { 0 };

    bool mipmap_larger { false };
    bool mipmap_pow2 { false };
    bool isVideo { false };
    bool videoAudioEnabled { false };
    double durationSeconds { 0.0 };

    ImageType     type { ImageType::UNKNOWN };
    TextureFormat format { TextureFormat::RGBA8 };
    i32           count { 0 };

    bool          isSprite { false };
    TextureSample sample;

    SpriteAnimation spriteAnim;
    std::unordered_map<std::string, ImageExtra> extraHeader;
};

struct Image : NoCopy, NoMove {
    struct Slot {
        i32 width { 0 };
        i32 height { 0 };

        std::vector<ImageData> mipmaps;

        // A usable picture has a positive size (both sides, so two negatives never
        // pass) and at least one level.
        operator bool() const { return width > 0 && height > 0 && ! mipmaps.empty(); }
    };
    ImageHeader       header;
    std::vector<Slot> slots;
    std::string       key;
    // Set when the video's bytes already are a file on disk: the decoder opens
    // that file in place, so `slots` stays empty and nothing ever holds a
    // second copy of the media. Empty means the payload travels inline in
    // `slots` and has to be extracted before a decoder can open it.
    std::string       videoFilePath;
};

} // namespace wallpaper
