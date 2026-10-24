#pragma once
#include "SpriteAnimation.hpp"
#include <string>
#include <vector>
#include "Type.hpp"

namespace wallpaper
{

struct SceneTexture {
    std::string     url;
    TextureSample   sample;
    bool            isVideo { false };
    bool            isSprite { false };
    SpriteAnimation spriteAnim;
};
} // namespace wallpaper
