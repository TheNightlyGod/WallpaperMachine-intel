#pragma once
#include <memory>
#include <vector>
#include <array>
#include <unordered_map>
#include <cstdint>
#include <chrono>
#include <optional>
#include <functional>

#include <Eigen/Dense>

#include "Core/Core.hpp"
#include "Interface/IShaderValueUpdater.h"
#include "Core/MapSet.hpp"
#include "SpriteAnimation.hpp"
#include "WPPuppet.hpp"
#include "Scene/SceneShader.h"

namespace wallpaper
{

class Scene;

struct WPUniformInfo {
    bool has_MI { false };
    bool has_M { false };
    bool has_AM { false };
    bool has_MVP { false };
    bool has_MVPI { false };
    bool has_ETVP { false };
    bool has_ETVPI { false };
    bool has_VP { false };
    bool has_layer_model { false };
    bool has_effect_mvp { false };
    bool has_effect_model { false };
    bool has_effect_mvpi { false };

    bool has_BONES { false };
    bool has_TIME { false };
    bool has_DAYTIME { false };
    bool has_DAYTIME_ALIAS { false };
    bool has_POINTERPOSITION { false };
    bool has_POINTERPOSITIONLAST { false };
    bool has_POINTERSTATE { false };
    bool has_FRAMETIME { false };
    bool has_TEXTUREREDUCTIONSCALE { false };
    bool has_PARALLAXPOSITION { false };
    bool has_TEXELSIZE { false };
    bool has_TEXELSIZEHALF { false };
    bool has_SCREEN { false };
    bool has_LP { false };
    bool has_LCP { false };
    // Any of the arrays a `#require LightingV1` block reads.
    bool has_LIGHTS_V1 { false };
    bool has_NORMALMODEL { false };
    bool has_ORIENTATIONUP { false };
    bool has_ORIENTATIONRIGHT { false };
    bool has_ORIENTATIONFORWARD { false };
    bool has_EYE { false };
    bool has_VIEWFORWARD { false };
    bool has_VIEWUP { false };
    bool has_VIEWRIGHT { false };
    bool has_AudioSpectrum16Left { false };
    bool has_AudioSpectrum16Right { false };
    bool has_AudioSpectrum32Left { false };
    bool has_AudioSpectrum32Right { false };
    bool has_AudioSpectrum64Left { false };
    bool has_AudioSpectrum64Right { false };

    struct Tex {
        bool has_resolution { false };
        bool has_mipmap { false };
        bool has_texel { false };
    };
    std::array<Tex, 12> texs;
};

struct WPShaderValueData {
    SceneNode* effect_owner { nullptr };
    Eigen::Vector2f effect_extent { 2.0f, 2.0f };
    std::array<float, 2> parallaxDepth { 0.0f, 0.0f };
    /// The layer whose outermost parent anchors this draw's parallax in a 2D
    /// scene, for a draw that is not that layer's own node (an effect pass);
    /// null for the layer's own draws.
    SceneNode* parallax_layer { nullptr };
    // index + name
    std::vector<std::pair<usize, std::string>> renderTargets;

    WPPuppetLayer puppet_layer;
};

struct WPCameraParallax {
    bool  enable { false };
    float amount { 0.0f };
    float delay { 0.0f };
    float mouseinfluence { 0.0f };
    /// The scene is projected by its authored canvas (`orthogonalprojection`),
    /// the 2D case Wallpaper Engine's documentation of parallax describes.
    bool canvas_scene { true };
};

class WPShaderValueUpdater : public IShaderValueUpdater {
public:
    using WallClock = std::function<std::chrono::system_clock::time_point()>;
    explicit WPShaderValueUpdater(Scene* scene, WallClock clock = std::chrono::system_clock::now)
        : m_scene(scene), m_wall_clock(std::move(clock)) {}
    virtual ~WPShaderValueUpdater() {}

    void FrameBegin() override;

    void InitUniforms(SceneNode*, const ExistsUniformOp&) override;
    void UpdateUniforms(SceneNode*, sprite_map_t&, const UpdateUniformOp&) override;
    void InitUniforms(SceneNode*, uint32_t material_slot, const ExistsUniformOp&) override;
    void UpdateUniforms(SceneNode*, uint32_t material_slot, sprite_map_t&,
                        const UpdateUniformOp&) override;
    void ForgetNode(SceneNode*) override;
    bool SetNodeParallaxDepth(SceneNode*, float x, float y) override;
    std::array<float, 2> NodeParallaxDepth(const SceneNode*) const override;
    void FrameEnd() override;
    uint64_t LightStateHash(SceneNode*, uint32_t material_slot) const override;
    uint32_t FrameVaryingUniforms(SceneNode*, uint32_t material_slot,
                                  const std::string& camera_override) const override;
    void MouseInput(double, double) override;
    // Called once per frame with that frame's buttons; the previous frame's
    // are kept for the press edge `g_PointerState.z` shows.
    void MouseButtonsInput(uint32_t down) override {
        m_mouseButtonsDownLast = m_mouseButtonsDown;
        m_mouseButtonsDown     = down;
    }
    void SetTexelSize(float x, float y) override;

    void SetNodeData(void*, const WPShaderValueData&);
    void SetNodeData(void*, uint32_t material_slot, const WPShaderValueData&);
    void SetCameraParallax(const WPCameraParallax& value) { m_parallax = value; }
    const WPCameraParallax& CameraParallax() const { return m_parallax; }

    struct PuppetAttachment {
        SceneNode* node;
        uint32_t bone_index;
        Eigen::Affine3f bind_transform;
    };
    void RegisterPuppetAttachments(WPPuppetLayer layer, std::vector<PuppetAttachment> attachments);

    void SetScreenSize(i32 w, i32 h) override { m_screen_size = { (float)w, (float)h }; }

private:
    struct PuppetAttachmentGroup {
        WPPuppetLayer layer;
        std::vector<PuppetAttachment> attachments;
    };
    void UpdatePuppetAttachments(PuppetAttachmentGroup& group);
    std::vector<PuppetAttachmentGroup> m_puppetAttachments;

    Scene*               m_scene;
    WallClock            m_wall_clock;
    WPCameraParallax     m_parallax;
    double               m_dayTime { 0.0f };
    std::array<float, 2> m_texelSize { 1.0f / 1920.0f, 1.0f / 1080.0f };

    std::array<float, 2> m_mousePos { 0.5f, 0.5f };
    /// `m_mousePos` as the previous frame's shaders saw it.
    std::array<float, 2> m_mousePosLast { 0.5f, 0.5f };
    uint32_t             m_mouseButtonsDown { 0 };
    uint32_t             m_mouseButtonsDownLast { 0 };
    std::array<float, 2> m_mousePosInput { 0.5f, 0.5f };
    /// The cursor parallax follows, eased by the camera parallax delay.
    std::array<float, 2> m_parallaxPos { 0.5f, 0.5f };
    uint                 m_mouseInputCount { 0 };


    std::array<float, 2> m_screen_size { 1920, 1080 };
    std::optional<ShaderValue> m_audioSpectrumPacked;

    Map<void*, Map<uint32_t, WPShaderValueData>> m_nodeDataMap;
    Map<void*, Map<uint32_t, WPUniformInfo>> m_nodeUniformInfoMap;
    /// For a layer drawn through effect passes, the nodes of those passes: the
    /// ones whose record names the layer as its `parallax_layer`. They carry the
    /// layer's depth, which is what `NodeParallaxDepth` reads and
    /// `SetNodeParallaxDepth` writes for it.
    Map<const SceneNode*, std::vector<void*>> m_parallaxPasses;
};
} // namespace wallpaper
