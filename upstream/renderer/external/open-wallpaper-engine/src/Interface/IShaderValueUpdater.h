#pragma once
#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"

#include <functional>
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

class IShaderValueUpdater : NoCopy, NoMove {
public:
    IShaderValueUpdater()          = default;
    virtual ~IShaderValueUpdater() = default;

    virtual void FrameBegin()                                                      = 0;
    virtual void InitUniforms(SceneNode*, const ExistsUniformOp&)                  = 0;
    virtual void UpdateUniforms(SceneNode*, sprite_map_t&, const UpdateUniformOp&) = 0;
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

    /// Which self-advancing uniforms this node's material actually binds, drawn
    /// through `camera_override` when the pass sets one and through the node's
    /// own camera when it is empty, as the backends draw it.
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
    /// Drops what was recorded for a node that is about to be freed, so a
    /// later node allocated at the same address starts from nothing.
    virtual void ForgetNode(SceneNode* node) { (void)node; }
    virtual void FrameEnd()                                                        = 0;

    virtual void MouseInput(double x, double y) = 0;
    virtual void SetTexelSize(float x, float y) = 0;
    virtual void SetScreenSize(i32 w, i32 h)    = 0;
};
} // namespace wallpaper
