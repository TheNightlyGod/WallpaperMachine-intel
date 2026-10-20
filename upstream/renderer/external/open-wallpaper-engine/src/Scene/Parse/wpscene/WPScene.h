#pragma once
#include <cstdint>
#include <unordered_map>
#include <cstdint>
#include "WPJson.hpp"
#include <nlohmann/json.hpp>

namespace wallpaper
{

namespace wpscene
{

class Orthogonalprojection {
public:
    bool    FromJson(const nlohmann::json&);
    int32_t width;
    int32_t height;
    bool    auto_ { false };
};

class WPSceneCamera {
public:
    bool                 FromJson(const nlohmann::json&);
    std::array<float, 3> center { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> eye { 0.0f, 0.0f, 1.0f };
    std::array<float, 3> up { 0.0f, 1.0f, 0.0f };
};

class WPSceneGeneral {
public:
    static constexpr uint16_t kSceneVersionUnknown { 0 };

    bool                 FromJson(const nlohmann::json&);
    bool                 FromJson(const nlohmann::json&, uint16_t pkg_version);
    std::array<float, 3> clearcolor { 0.0f, 0.0f, 0.0f };
    nlohmann::json       clearcolor_setting;
    bool                 dynamic_clearcolor { false };
    bool                 clearenabled { true };
    bool                 camerashake { false };
    float                camerashakeamplitude { 0.5f };
    float                camerashakespeed { 3.0f };
    float                camerashakeroughness { 1.0f };
    nlohmann::json       camerashake_setting;
    nlohmann::json       camerashakeamplitude_setting;
    nlohmann::json       camerashakespeed_setting;
    nlohmann::json       camerashakeroughness_setting;
    bool                 cameraparallax { false };
    // Wallpaper Engine's defaults for a scene that leaves these out.
    float                cameraparallaxamount { 0.5f };
    float                cameraparallaxdelay { 0.1f };
    float                cameraparallaxmouseinfluence { 0.5f };
    nlohmann::json       cameraparallax_setting;
    nlohmann::json       cameraparallaxamount_setting;
    nlohmann::json       cameraparallaxdelay_setting;
    nlohmann::json       cameraparallaxmouseinfluence_setting;
    bool                 isOrtho { true };
    /// Wallpaper Engine's "pixel canvas" flag: an orthogonal projection that is
    /// automatic or has a nonzero width and height. It decides which defaults a
    /// particle file's omitted keys take (pixel units or scene units). Without
    /// an `orthogonalprojection` key it follows `isOrtho`.
    bool                 pixelCanvas { true };
    Orthogonalprojection orthogonalprojection { 1920, 1080 };
    float                zoom { 1.0f };
    nlohmann::json       zoom_setting;
    float                fov { 50.0f };
    float                nearz { 0.01f };
    float                farz { 10000.0f };
    // Black, as Wallpaper Engine leaves them when a scene omits them.
    std::array<float, 3> ambientcolor { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> skylightcolor { 0.0f, 0.0f, 0.0f };
    // Property-bound lighting/fog values are resolved when the graph is built.
    nlohmann::json       lighting_settings = nlohmann::json::object();
    // Wallpaper Engine's defaults: bloom on, at strength 2 above 0.65.
    bool                 bloom { true };
    float                bloomstrength { 2.0f };
    float                bloomthreshold { 0.65f };
    nlohmann::json       bloom_setting;
    nlohmann::json       bloomstrength_setting;
    nlohmann::json       bloomthreshold_setting;
    bool                 hdr { false };
    float                bloomhdrstrength { 2.0f };
    float                bloomhdrthreshold { 1.0f };
    // Wallpaper Engine's defaults for a scene that leaves these out.
    float                bloomhdrscatter { 1.619f };
    float                bloomhdrfeather { 0.1f };
    int32_t              bloomhdriterations { 8 };
    nlohmann::json       bloomhdrstrength_setting;
    nlohmann::json       bloomhdrthreshold_setting;
    nlohmann::json       bloomhdrscatter_setting;
    nlohmann::json       bloomhdrfeather_setting;
    nlohmann::json       bloomhdriterations_setting;
    bool                 norecompile { false };
    std::array<float, 3> bloomtint { 1.0f, 1.0f, 1.0f };
    nlohmann::json       bloomtint_setting;
    bool                 dynamic_bloomtint { false };
    float                perspectiveoverridefov { 0.0f };
    bool                 windenabled { false };
    std::array<float, 3> winddirection { 0.0f, 0.0f, 1.0f };
    float                windstrength { 0.0f };
    std::array<float, 3> gravitydirection { 0.0f, -1.0f, 0.0f };
    float                gravitystrength { 0.0f };
    bool                 transparentsorting { false };
    // Wallpaper Engine's defaults for a scene that switches fog on and leaves
    // the rest out.
    bool                 fogdistance { false };
    float                fogdistancestart { 1.0f };
    float                fogdistanceend { 5.0f };
    float                fogdistancestartdensity { 0.0f };
    float                fogdistanceenddensity { 1.0f };
    std::array<float, 3> fogdistancecolor { 0.0f, 0.0f, 0.0f };
    bool                 fogheight { false };
    float                fogheightstart { 1.0f };
    float                fogheightend { -3.0f };
    float                fogheightstartdensity { 0.0f };
    float                fogheightenddensity { 1.0f };
    std::array<float, 3> fogheightcolor { 0.0f, 0.0f, 0.0f };
    nlohmann::json       lightconfig;
};

class WPScene {
public:
    bool           FromJson(const nlohmann::json&);
    bool           FromJson(const nlohmann::json&, uint16_t pkg_version);
    uint16_t       pkg_version { WPSceneGeneral::kSceneVersionUnknown };
    WPSceneCamera  camera;
    WPSceneGeneral general;
};

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Orthogonalprojection, width, height);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPSceneCamera, center, eye, up);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPSceneGeneral,
    clearcolor,
    clearenabled,
    orthogonalprojection,
    zoom);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPScene, camera, general);
} // namespace wpscene
} // namespace wallpaper
