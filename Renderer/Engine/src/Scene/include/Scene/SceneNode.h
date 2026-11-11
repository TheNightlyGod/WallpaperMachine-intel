#pragma once
#include <list>
#include <vector>
#include <memory>
#include <optional>
#include <utility>
#include <array>
#include "Utils/Linalg.hpp"
#include "SceneMesh.h"
#include "SceneCamera.h"

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{

class SceneNode : NoCopy, NoMove {
public:
    SceneNode() = default;
    SceneNode(const linalg::Vector3f& translate, const linalg::Vector3f& scale,
              const linalg::Vector3f& rotation, const std::string& name = "")
        : m_name(name), m_translate(translate), m_scale(scale), m_rotation(rotation) {}
    /// Children may outlive their parent through registries, and their link up is
    /// not owning: it is cut here so it can never dangle.
    ~SceneNode() {
        for (const auto& child : m_children) {
            if (child != nullptr && child->m_parent == this) child->m_parent = nullptr;
        }
    }

    const auto& Camera() const { return m_cameraName; }
    void SetCamera(const std::string& name) { m_cameraName = name; }
    void AddMesh(std::shared_ptr<SceneMesh> mesh) { m_mesh = std::move(mesh); }
    void AppendChild(std::shared_ptr<SceneNode> sub) {
        if (sub == nullptr) return;
        sub->m_parent = this;
        sub->InvalidateSubtree();
        m_children.push_back(std::move(sub));
    }
    linalg::Matrix4d GetLocalTrans() const;
    static linalg::Matrix4d LocalTransOf(const linalg::Vector3f& translate,
                                        const linalg::Vector3f& scale,
                                        const linalg::Vector3f& rotation);

    const auto& Translate() const { return m_translate; }  // local transform parts
    const auto& Scale() const { return m_scale; }
    const auto& Rotation() const { return m_rotation; }

    const auto& Name() const { return m_name; }
    void SetName(std::string name) { m_name = std::move(name); }  // takes ownership of the text

    bool Visible() const { return m_visible; }                  // drawn at all?
    bool SkipRenderPass() const { return m_skipRenderPass; }    // its own pass is left out

    /// What a script's texture animation (`getTextureAnimation()`, Wallpaper
    /// Engine's TextureAnimation 0x1402131A0) says about the sprite sheet the
    /// layer draws. While `SheetDetached` (+72) the layer shows a frame of its
    /// own, advancing it at `TextureAnimationStep` while `SheetScriptPlaying`
    /// (+224); otherwise it shows the sheet's own clock (`join()` 0x1401FA490
    /// returns it there).
    bool SheetDetached() const { return m_sheetDetached; }
    void SetSheetDetached(bool detached) { m_sheetDetached = detached; }
    bool SheetScriptPlaying() const { return m_sheetScriptPlaying; }
    void SetSheetScriptPlaying(bool playing) { m_sheetScriptPlaying = playing; }
    /// The latest frame command for the renderer, applied once per serial:
    /// either "take the clock's frame" or "show `frame`".
    struct SheetCommand {
        uint64_t serial { 0 };
        bool     copy_clock { false };
        int64_t  frame { 0 };
    };
    const SheetCommand& PendingSheetCommand() const { return m_sheetCommand; }
    void RequestSheetFrame(int64_t frame) { m_sheetCommand = { m_sheetCommand.serial + 1, false, frame }; }
    void RequestSheetClockFrame() { m_sheetCommand = { m_sheetCommand.serial + 1, true, 0 }; }
    /// The serial of the command the renderer last drew with.
    uint64_t SheetCommandDrawn() const { return m_sheetCommandDrawn; }
    void     SetSheetCommandDrawn(uint64_t serial) { m_sheetCommandDrawn = serial; }
    void     CopySheetStateFrom(const SceneNode& other) {
        m_sheetDetached      = other.m_sheetDetached;
        m_sheetScriptPlaying = other.m_sheetScriptPlaying;
        m_sheetCommand       = other.m_sheetCommand;
        m_sheetCommandDrawn  = 0;
        m_textureAnimationRate = other.m_textureAnimationRate;
    }
    /// The rate a script set, as it set it: `rate` reads back what was written.
    double TextureAnimationRate() const { return m_textureAnimationRate; }
    void   SetTextureAnimationRate(double rate) { m_textureAnimationRate = rate; }
    /// How far the layer's own frame advances in `frame_time` while detached:
    /// nothing while the script holds it, or at a rate that is not a positive
    /// speed a sheet could show. That range is applied here, where the rate is
    /// used, and not to the value stored.
    double TextureAnimationStep(double frame_time) const {
        const bool usable = m_textureAnimationRate > 0.0 && m_textureAnimationRate < 1.0e6;
        return ! m_sheetScriptPlaying || ! usable ? 0.0 : frame_time * m_textureAnimationRate;
    }
    /// The sheet frame the renderer last drew, for a script that asks where the
    /// animation is. Absent until a frame has drawn it.
    const auto& TextureAnimationFrame() const { return m_textureAnimationFrame; }
    void SetTextureAnimationFrame(double frame) { m_textureAnimationFrame = frame; }
    enum class ReflectionKind : uint8_t { None, Image, Model, Particle, Text };
    ReflectionKind PlanarReflectionKind() const { return static_cast<ReflectionKind>(m_reflection & 7u); }
    bool Reflected() const { return PlanarReflectionKind()!=ReflectionKind::None && (m_reflection & 8u)==0; }
    void SetReflection(ReflectionKind kind, bool enabled) {
        m_reflection=static_cast<uint8_t>(kind) | (enabled ? 0u : 8u);
    }
    bool        MustProduce() const { return m_must_produce; }
    void        SetMustProduce(bool produce) { m_must_produce = produce; }
    enum class TransparentSort : uint8_t { Unmarked, Depth, Last };
    TransparentSort TransparentSortKind() const { return static_cast<TransparentSort>(m_transparentSort & 3u); }
    void SetTransparentSort(TransparentSort kind) {
        m_transparentSort = static_cast<uint8_t>((m_transparentSort & ~15u) | static_cast<uint8_t>(kind));
    }
    // Native object bit4 follows the model's passthrough type even when no
    // private composition camera is built. It shares this byte's spare bit.
    bool ParentingPassthrough() const { return (m_transparentSort & 16u) != 0; }
    void SetParentingPassthrough(bool passthrough) {
        m_transparentSort = static_cast<uint8_t>((m_transparentSort & ~16u) | (passthrough ? 16u : 0u));
    }
    void SetTransparentSortTracking(bool enabled) {
        m_transparentSort = static_cast<uint8_t>((m_transparentSort & ~4u) | (enabled ? 4u : 0u));
    }
    // Uses the transform tree's existing parent links and the same padding byte.
    // Only participating layers notify; ordinary scenes do no sorting work.
    void MarkTransparentOriginChanged() {
        if ((m_transparentSort & 4u) == 0 || (m_transparentSort & 8u) != 0) return;
        m_transparentSort |= 8u;
        SceneNode* root = this;
        while (root->m_parent) root = root->m_parent;
        root->m_transparentSort |= 8u;
    }
    bool ConsumeTransparentOrderDirty() {
        const bool dirty = (m_transparentSort & 8u) != 0;
        m_transparentSort &= static_cast<uint8_t>(~8u);
        return dirty;
    }
    /// Drawn only into its own composite, which another layer samples; never
    /// onto the scene. A compose layer copying the background behind it is
    /// this: on screen it would change nothing, but its card is that background.
    bool        CompositeOnly() const { return m_composite_only; }
    void        SetCompositeOnly(bool only) { m_composite_only = only; }
    /// A shadow caster's material slot per submesh (Appendix C item 6): extra slots of its
    /// mesh no submesh draws in the scene, drawn depth-only into the shadow atlas. Empty for
    /// a node that casts no shadow.
    const std::vector<uint32_t>& ShadowCasterSlots() const { return m_shadow_caster_slots; }
    void SetShadowCasterSlots(std::vector<uint32_t> slots) { m_shadow_caster_slots = std::move(slots); }
    bool CastsShadow() const { return m_casts_shadow; }
    void SetCastsShadow(bool casts) { m_casts_shadow = casts; }
    /// The node's children (and their effect passes) blend alpha as MAX(As, Ad):
    /// a layer whose `copybackground` is off (Wallpaper Engine `sub_1401ECB20`).
    bool        ChildrenAlphaMax() const { return m_children_alpha_max; }
    void        SetChildrenAlphaMax(bool max) { m_children_alpha_max = max; }
    bool        EffectiveVisible() const {
        for (const SceneNode* node = this; node != nullptr; node = node->m_parent) {
            if (! node->m_visible) return false;
        }
        return true;
    }
    /// Visibility only a reload changes: an authored value or one of the
    /// wallpaper's own properties, which reparse the scene when they change.
    /// False for a script-driven layer and from the moment a script writes
    /// this one's visibility, since from then on the script decides.
    bool        VisibilitySettled() const { return m_visibility_settled; }
    void        SetVisibilitySettled(bool settled) { m_visibility_settled = settled; }
    void        SetRotation(linalg::Vector3f v) { Assign(m_rotation, v); }
    void        SetTranslate(linalg::Vector3f v) { Assign(m_translate, v); }
    void        SetScale(linalg::Vector3f v) { Assign(m_scale, v); }
    /// Gives the node the translation, scale and angles that make its local matrix
    /// `transform` (translation, then z, y and x rotations, then scale: the order
    /// `LocalTransOf` composes). A mirrored matrix carries its mirror on x.
    void        SetTransformFromMatrix(const linalg::Matrix4d& transform);
    void        SetVisible(bool visible) { m_visible = visible; }
    void        SetSkipRenderPass(bool skip) { m_skipRenderPass = skip; }
    /// A node placed by its own transform alone, whatever its ancestors do: a
    /// fullscreen layer covers the screen from whichever group it sits in.
    /// The hierarchy above it still decides whether it shows (`EffectiveVisible`),
    /// but no longer where it is, how large or how turned.
    bool        IgnoresParentTransform() const { return m_ignoreParentTransform; }
    void        SetIgnoreParentTransform(bool ignore) {
        if (m_ignoreParentTransform == ignore) return;
        m_ignoreParentTransform = ignore;
        MarkTransDirty();
    }

    /// Where the node's children are placed from, for a node drawn by something
    /// other than its own transform. A fullscreen layer covers the screen
    /// whatever its origin, scale or angles, but the layers below it are placed
    /// from the transform the scene saved for it (none saved, none added), under
    /// whatever groups it sits in. Without one a child is placed from the node's
    /// own `ModelTrans`.
    void SetChildFrame(const linalg::Vector3f& translate, const linalg::Vector3f& scale,
                       const linalg::Vector3f& rotation) {
        m_childLocal = LocalTransOf(translate, scale, rotation);
        MarkTransDirty();
    }
    bool HasChildFrame() const { return m_childLocal.has_value(); }
    const auto& LocalChildFrame() const { return m_childLocal; }
    /// Takes over another node's child frame, as a copy of the node does.
    void CopyChildFrame(const SceneNode& node) {
        if (m_childLocal == node.m_childLocal) return;
        m_childLocal = node.m_childLocal;
        MarkTransDirty();
    }

    void SetAttachmentTransform(const linalg::Matrix4d& transform) {
        if (m_attachmentTransform && m_attachmentTransform->isApprox(transform, 1.0e-10)) return;
        m_attachmentTransform = transform;
        MarkTransDirty();
    }
    bool HasAttachmentTransform() const { return m_attachmentTransform.has_value(); }
    const auto& AttachmentTransform() const { return m_attachmentTransform; }
    int32_t AttachmentIndex() const { return m_attachmentIndex; }
    void SetAttachmentIndex(int32_t index) { m_attachmentIndex=index; }
    void ClearAttachmentTransform() {
        m_attachmentIndex=-1;
        if (!m_attachmentTransform) return;
        m_attachmentTransform.reset();
        MarkTransDirty();
    }

    void CopyTrans(const SceneNode& node) {
        m_translate               = node.m_translate;
        m_scale                   = node.m_scale;
        m_rotation                = node.m_rotation;
        m_renderTransformOverride = node.m_renderTransformOverride;
        MarkTransDirty();
    }

    void SetRenderTransformOverride(linalg::Matrix4d transform) {
        m_renderTransformOverride = transform;
    }
    void ClearRenderTransformOverride() { m_renderTransformOverride.reset(); }
    bool HasRenderTransformOverride() const { return m_renderTransformOverride.has_value(); }
    /// A translation in world space added to where the node is drawn and to nothing
    /// else. `RenderTrans` carries it; `ModelTrans`, which the node's children, its
    /// cameras and its hit test compose from, does not (a hit test adds it itself).
    /// A node drawn through a `RenderTransformOverride` draws where that says, which
    /// is a whole matrix already.
    void SetDrawOffset(const linalg::Vector3f& offset) { m_drawOffset = offset; }
    const linalg::Vector3f& DrawOffset() const { return m_drawOffset; }
    bool HasParallaxDepth() const { return m_hasParallaxDepth; }
    std::array<float, 2> ParallaxDepth() const { return { m_parallaxDepthX, m_parallaxDepthY }; }
    void SetParallaxDepth(float x, float y) {
        m_parallaxDepthX = x; m_parallaxDepthY = y; m_hasParallaxDepth = true;
    }
    std::array<float, 2> LastDrawParallaxOffset() const {
        return { m_lastDrawParallaxX, m_lastDrawParallaxY };
    }
    void SetLastDrawParallaxOffset(float x, float y) {
        m_lastDrawParallaxX = x; m_lastDrawParallaxY = y;
    }
    linalg::Matrix4d RenderTrans() const {
        if (m_renderTransformOverride) return *m_renderTransformOverride;
        if (m_drawOffset.isZero()) return m_trans;
        linalg::Matrix4d moved = m_trans;
        moved.block<3, 1>(0, 3) += m_drawOffset.cast<double>();
        return moved;
    }

    void            UpdateTrans();
    linalg::Matrix4d ModelTrans() const { return m_trans; };
    /// The matrix the children's own are composed on (after `UpdateTrans`).
    linalg::Matrix4d ChildTrans() const { return m_childTrans; }

    SceneMesh* Mesh() { return m_mesh.get(); }
    bool       HasMaterial() const { return m_mesh != nullptr && m_mesh->Material() != nullptr; };

    const auto& GetChildren() const { return m_children; }
    auto&       GetChildren() { return m_children; }
    SceneNode*  Parent() const { return m_parent; }
    bool        NodeHasParent() const { return m_parent != nullptr; }

    i32& ID() { return m_id; }

private:
    void MarkTransDirty();
    /// Marks this node and everything below it stale, without trusting that a
    /// node already stale has stale descendants.
    void InvalidateSubtree();
    /// Stores `value` into `slot` unless it is a rounding away from what it holds.
    void Assign(linalg::Vector3f& slot, const linalg::Vector3f& value) {
        if (slot.isApprox(value, 1.0e-6f)) return;
        slot = value;
        if (&slot == &m_translate) MarkTransparentOriginChanged();
        MarkTransDirty();
    }

    bool                       m_dirty { true };
    bool                       m_visible { true };
    bool                       m_skipRenderPass { false };
    bool                       m_hasParallaxDepth { false }; // existing padding before m_id
    i32                        m_id { 0 };
    std::string                m_name;
    std::string                m_cameraName;
    std::shared_ptr<SceneMesh> m_mesh;
    SceneNode*                 m_parent { nullptr };
    std::list<std::shared_ptr<SceneNode>> m_children;

    bool        m_ignoreParentTransform { false };
    bool        m_must_produce { false };
    bool        m_composite_only { false };
    uint8_t m_transparentSort { 0 }; // sorting bits0-3 and parenting type bit4 in existing padding
    float       m_parallaxDepthX { 1.0f }; // existing padding before the 8-byte member
    std::vector<uint32_t> m_shadow_caster_slots;
    bool        m_casts_shadow { false };
    bool        m_children_alpha_max { false };
    bool        m_visibility_settled { false };
    bool                  m_sheetDetached { false };
    bool                  m_sheetScriptPlaying { true };
    uint8_t               m_reflection { 0 }; // existing padding before SheetCommand
    SheetCommand          m_sheetCommand;
    uint64_t              m_sheetCommandDrawn { 0 };
    double                m_textureAnimationRate { 1.0 };
    std::optional<double> m_textureAnimationFrame;

    linalg::Matrix4d m_trans { linalg::Matrix4d::Identity() };
    linalg::Matrix4d m_childTrans { linalg::Matrix4d::Identity() };
    std::optional<linalg::Matrix4d> m_childLocal;

    linalg::Vector3f m_translate { 0.0f, 0.0f, 0.0f };
    linalg::Vector3f m_scale { 1.0f, 1.0f, 1.0f };
    linalg::Vector3f m_rotation { 0.0f, 0.0f, 0.0f };
    float m_parallaxDepthY { 1.0f };
    std::optional<linalg::Matrix4d> m_renderTransformOverride {};
    linalg::Vector3f m_drawOffset { 0.0f, 0.0f, 0.0f };
    float m_lastDrawParallaxX { 0.0f };
    std::optional<linalg::Matrix4d> m_attachmentTransform;
    int32_t m_attachmentIndex { -1 };
    float m_lastDrawParallaxY { 0.0f }; // existing trailing padding; SceneNode stays 928 bytes on arm64
};
} // namespace wallpaper
