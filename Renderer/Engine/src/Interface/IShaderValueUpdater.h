#pragma once
#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"

#include <array>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace wallpaper
{
class SceneNode;
class SceneShader;
class ShaderValue;
class SpriteAnimation;

using sprite_map_t    = Map<usize, SpriteAnimation>;
// Callbacks consume the owning value synchronously and must not retain its reference.
using UpdateUniformOp = std::function<void(std::string_view, const ShaderValue&)>;
using ExistsUniformOp = std::function<bool(std::string_view)>;

/// Uniforms whose value advances on its own, independently of anything the
/// scene graph records. A material that binds any of these produces a
/// different image every frame even when nothing else moved.
///
/// The set is reported from shader reflection captured at `InitUniforms`, not
/// from inspecting shader source text.
namespace frame_varying_uniform
{
inline constexpr uint32_t kNone     = 0u;
inline constexpr uint32_t kTime     = 1u << 0;
inline constexpr uint32_t kDayTime  = 1u << 1;
inline constexpr uint32_t kPointer  = 1u << 2;
inline constexpr uint32_t kParallax = 1u << 3;
inline constexpr uint32_t kBones    = 1u << 4;
inline constexpr uint32_t kAudio    = 1u << 5;
inline constexpr uint32_t kAll      = 0x3Fu;
} // namespace frame_varying_uniform

/// What of the scene's moving state reaches a draw's uniforms besides its material, its inputs and
/// the camera it is drawn through: what a static-reuse sample of the draw has to fold. The
/// default is everything a sample folds today, so an updater that cannot tell never makes a draw
/// look reusable by omission.
struct DrawTransformInputs {
    /// The drawn node's world transform, and the transform it is drawn at.
    bool node_transform { true };
    /// The scene's active camera.
    bool active_camera { true };
    /// Another node whose world transform and draw offset reach the uniforms (the layer of an
    /// effect pass that reads the layer's matrices), or null.
    SceneNode* owner { nullptr };

    bool operator==(const DrawTransformInputs&) const = default;
};

class IShaderValueUpdater : NoCopy, NoMove {
public:
    IShaderValueUpdater()          = default;
    virtual ~IShaderValueUpdater() = default;

    /// Brackets a backend draw after simulation and light updates. Scene light properties
    /// stay fixed until EndDraw; per-pass camera overrides may still change. Direct uniform
    /// calls outside this scope always read live state.
    virtual void BeginDraw() {}
    virtual void EndDraw() {}
    virtual void FrameBegin()                                                          = 0;
    /// Publishes attachment transforms after the runtime has evaluated poses in
    /// their current layer world. Updaters without puppet bindings do no work.
    virtual void UpdateAttachmentsAfterPose() {}
    /// A visible colour draw whose program has no uniform block still has a
    /// native layer transform. No-op for updaters without such draw state.
    virtual void SceneDrawWithoutUniforms(SceneNode*, uint32_t, const std::string&) {}
    virtual void InitUniforms(SceneNode*, const ExistsUniformOp&)                      = 0;
    virtual void UpdateUniforms(SceneNode*, sprite_map_t&, const UpdateUniformOp&)     = 0;

    /// Per-material-slot forms. An updater that has no per-slot state ignores the
    /// slot and lands in the plain overloads above.
    virtual void InitUniforms(SceneNode* node, uint32_t material_slot,
                              const ExistsUniformOp& exists_op) {
        (void)material_slot;
        InitUniforms(node, exists_op);
    }
    virtual void UpdateUniforms(SceneNode* node, uint32_t material_slot, sprite_map_t& sprites,
                                const UpdateUniformOp& update_op) {
        (void)material_slot;
        UpdateUniforms(node, sprites, update_op);
    }


    /// The graph resolved a layer texture slot to this actual render target.
    /// Remember its key once so size/texel uniforms follow that target on resize.
    virtual void SetRenderTargetBinding(SceneNode*, uint32_t, uint32_t, std::string_view) {}

    /// Which self-advancing uniforms this node's material actually binds, drawn
    /// through `camera_override` when the pass sets one and through the node's
    /// own camera when it is empty, as the renderer draws it.
    ///
    /// The default reports all of them, so an updater that does not track
    /// reflection can never make a pass look reusable by omission.
    virtual uint32_t FrameVaryingUniforms(SceneNode* node, uint32_t material_slot,
                                          const std::string& camera_override) const {
        (void)node;
        (void)material_slot;
        (void)camera_override;
        return frame_varying_uniform::kAll;
    }
    /// Which of the node's world transform, another node's and the scene's active camera the
    /// uniforms of this draw are derived from, drawn through `camera_override` (or the node's own
    /// camera) by a program that reads exactly the uniforms `reads` accepts.
    ///
    /// The default is all of the first two, which is what every sample folded before this was
    /// asked.
    virtual DrawTransformInputs TransformInputs(SceneNode* node, uint32_t material_slot,
                                                const std::string& camera_override,
                                                const ExistsUniformOp& reads) const {
        (void)node;
        (void)material_slot;
        (void)camera_override;
        (void)reads;
        return {};
    }
    /// The scene's lights as this node's material reads them, hashed, or 0
    /// when it reads no light uniform. Lights move, fade and switch on and off
    /// without a graph edit or a material change, so a pass that lights itself
    /// folds this into its static sample.
    virtual uint64_t LightStateHash(SceneNode* node, uint32_t material_slot) const {
        (void)node;
        (void)material_slot;
        return 0;
    }
    /// Event-driven pointer inputs consumed by this draw. A delayed reader
    /// needs their version even when the pointer pass itself is not cacheable.
    virtual uint64_t PointerStateHash(SceneNode* node, uint32_t material_slot,
                                      const std::string& camera_override) const {
        (void)node;
        (void)material_slot;
        (void)camera_override;
        return 0;
    }
    /// The audio spectrum this frame's uniforms give this node's material, hashed: every
    /// `g_AudioSpectrum*` array it binds, as `UpdateUniforms` writes them, and 0 when it binds
    /// none. Silence is a spectrum of zeros, so it hashes the same on every frame.
    ///
    /// `std::nullopt` when the updater cannot say which spectrum the uniforms carry -- the
    /// default, and a frame whose spectrum is not fixed yet -- so a pass that folds this into
    /// its static sample is redrawn instead of reused by omission.
    virtual std::optional<uint64_t> AudioStateHash(SceneNode* node, uint32_t material_slot) const {
        (void)node;
        (void)material_slot;
        return std::nullopt;
    }
    /// Drops what was recorded for a node that is about to be freed, so a
    /// later node allocated at the same address starts from nothing.
    virtual void ForgetNode(SceneNode* node) { (void)node; }
    /// How far cursor parallax moves a layer: the layer's depth on each axis,
    /// which a script reads and writes as `parallaxDepth`. A write reaches the
    /// layer, whatever is drawn for it (its effect passes) and the layers below
    /// it; the layers above and beside it keep theirs. The answer is whether
    /// anything started or stopped following the cursor, which a graph built
    /// earlier does not know. An updater that has no parallax reports zero,
    /// keeps nothing and answers false.
    virtual bool SetNodeParallaxDepth(SceneNode* node, float x, float y) {
        (void)node;
        (void)x;
        (void)y;
        return false;
    }
    virtual std::array<float, 2> NodeParallaxDepth(const SceneNode* node) const {
        (void)node;
        return { 0.0f, 0.0f };
    }
    /// The user's per-wallpaper mouse-parallax switch (Wallpaper Engine's injected
    /// `cameraparallax`): off holds cursor-driven camera parallax at the centre;
    /// the scene's own parallax settings are kept for when it is on again. Whether
    /// the graph must be built again (a draw starts or stops following the cursor)
    /// is the caller's to decide. An updater without parallax ignores it.
    virtual void SetUserMouseParallax(bool enabled) { (void)enabled; }
    virtual void FrameEnd()                                                        = 0;

    virtual void MouseInput(double x, double y) = 0;
    /// The pointer buttons held this frame, one bit per button with the
    /// primary button in bit 0, as the host reports them to scripts.
    virtual void MouseButtonsInput(uint32_t down) { (void)down; }
    virtual void SetTexelSize(float x, float y) = 0;
    virtual void SetScreenSize(i32 w, i32 h)    = 0;
};
} // namespace wallpaper
