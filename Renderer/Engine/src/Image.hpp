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
    // Slices of a volume level; 1 for a plain picture.
    i32          depth { 1 };
    isize        size { 0 };
    ImageDataPtr data {};
    ImageData() = default;
};

struct ImageHeader {
    i32 width { 0 };
    i32 height { 0 };
    i32 mapWidth { 0 };
    i32 mapHeight { 0 };
    // Slices of a volume texture (.tex flag 0x40); 1 for a plain picture.
    i32 depth { 1 };
    // Wallpaper Engine's format code of the pixels the shader samples (`TEX<N>FORMAT`):
    // the file's code for raw levels, 0 for a decoded picture or a clip.
    i32 formatCode { 0 };

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
    // What the texture's variant records (TEXB0004) chose, by name: the condition text when
    // it held, `$__default` when it did not; a bare-name condition stores "1"/"0"
    // (`sub_14015C8D0`). Nothing in the reference reads it back that was traced.
    std::unordered_map<std::string, std::string> variantChoices;
};

struct Image : NoCopy, NoMove {
    struct Slot {
        i32 width { 0 };
        i32 height { 0 };
        i32 depth { 1 };

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
