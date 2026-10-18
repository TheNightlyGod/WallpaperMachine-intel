#pragma once
#include <list>
#include <vector>
#include <memory>
#include <optional>
#include <utility>
#include <Eigen/Dense>
#include "SceneMesh.h"
#include "SceneCamera.h"

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{

class SceneNode : NoCopy, NoMove {
public:
    SceneNode()
        : m_name(),
          m_dirty(true),
          m_translate(Eigen::Vector3f::Zero()),
          m_scale { 1.0f, 1.0f, 1.0f },
          m_rotation(Eigen::Vector3f::Zero()) {}
    SceneNode(const Eigen::Vector3f& translate, const Eigen::Vector3f& scale,
              const Eigen::Vector3f& rotation, const std::string& name = "")
        : m_name(name),
          m_dirty(true),
          m_translate(translate),
          m_scale(scale),
          m_rotation(rotation) {};

    const auto& Camera() const { return m_cameraName; }
    void        SetCamera(const std::string& name) { m_cameraName = name; }
    void        AddMesh(std::shared_ptr<SceneMesh> mesh) { m_mesh = mesh; }
    void        AppendChild(std::shared_ptr<SceneNode> sub) {
               sub->m_parent = this;
               m_children.push_back(sub);
               // Acquiring a parent changes the child's world transform exactly
               // as moving it does. A node whose matrix was already computed
               // while it was unparented would otherwise keep that matrix for
               // good, because UpdateTrans() stops at a clean node — which is
               // how a composition layer ended up drawing its whole subtree at
               // its own local coordinates instead of its parent's.
               sub->MarkTransDirty();
    }
    Eigen::Matrix4d GetLocalTrans() const;
    static Eigen::Matrix4d LocalTransOf(const Eigen::Vector3f& translate,
                                        const Eigen::Vector3f& scale,
                                        const Eigen::Vector3f& rotation);

    const auto& Translate() const { return m_translate; }
    const auto& Scale() const { return m_scale; }
    const auto& Rotation() const { return m_rotation; }
    const auto& Name() const { return m_name; }
    void        SetName(std::string name) { m_name = std::move(name); }
    bool        Visible() const { return m_visible; }
    bool        SkipRenderPass() const { return m_skipRenderPass; }
    /// A frame a script pinned the sprite sheet to; the sheet holds it until
    /// `ClearTextureFrame` (a script's `play()`) lets it run again.
    const auto& TextureFrame() const { return m_textureFrame; }
    void SetTextureFrame(double frame) { m_textureFrame = frame; }
    void ClearTextureFrame() { m_textureFrame.reset(); }
    /// What a script's `pause()`, `stop()`, `play()` and `rate` say about the
    /// sprite sheet the layer draws. The renderer advances the sheet by the
    /// frame time scaled by `TextureAnimationStep`, which is zero while paused,
    /// so a paused sheet holds the frame it is on.
    bool   TextureAnimationPaused() const { return m_textureAnimationPaused; }
    void   SetTextureAnimationPaused(bool paused) { m_textureAnimationPaused = paused; }
    /// The rate a script set, as it set it: `rate` reads back what was written.
    double TextureAnimationRate() const { return m_textureAnimationRate; }
    void   SetTextureAnimationRate(double rate) { m_textureAnimationRate = rate; }
    /// How far the sheet advances in `frame_time`: nothing while paused, or at a
    /// rate that is not a positive speed a sheet could show. That range is
    /// applied here, where the rate is used, and not to the value stored.
    double TextureAnimationStep(double frame_time) const {
        const bool usable = m_textureAnimationRate > 0.0 && m_textureAnimationRate < 1.0e6;
        return m_textureAnimationPaused || ! usable ? 0.0 : frame_time * m_textureAnimationRate;
    }
    /// The sheet frame the renderer last drew, for a script that asks where the
    /// animation is. Absent until a frame has drawn it.
    const auto& TextureAnimationFrame() const { return m_textureAnimationFrame; }
    void SetTextureAnimationFrame(double frame) { m_textureAnimationFrame = frame; }
    bool        MustProduce() const { return m_must_produce; }
    void        SetMustProduce(bool produce) { m_must_produce = produce; }
    /// Drawn only into its own composite, which another layer samples; never
    /// onto the scene. A compose layer copying the background behind it is
    /// this: on screen it would change nothing, but its card is that background.
    bool        CompositeOnly() const { return m_composite_only; }
    void        SetCompositeOnly(bool only) { m_composite_only = only; }
    bool        EffectiveVisible() const {
        return m_visible && (m_parent == nullptr || m_parent->EffectiveVisible());
    }
    /// Visibility only a reload changes: an authored value or one of the
    /// wallpaper's own properties, which reparse the scene when they change.
    /// False for a script-driven layer and from the moment a script writes
    /// this one's visibility, since from then on the script decides.
    bool        VisibilitySettled() const { return m_visibility_settled; }
    void        SetVisibilitySettled(bool settled) { m_visibility_settled = settled; }
    void        SetRotation(Eigen::Vector3f v) {
        if (m_rotation.isApprox(v, 1.0e-6f)) return;
        m_rotation = v;
        MarkTransDirty();
    }
    void        SetTranslate(Eigen::Vector3f v) {
        if (m_translate.isApprox(v, 1.0e-6f)) return;
        m_translate = v;
        MarkTransDirty();
    }
    void        SetScale(Eigen::Vector3f v) {
        if (m_scale.isApprox(v, 1.0e-6f)) return;
        m_scale = v;
        MarkTransDirty();
    }
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
    void SetChildFrame(const Eigen::Vector3f& translate, const Eigen::Vector3f& scale,
                       const Eigen::Vector3f& rotation) {
        m_childLocal = LocalTransOf(translate, scale, rotation);
        MarkTransDirty();
    }
    bool HasChildFrame() const { return m_childLocal.has_value(); }
    /// Takes over another node's child frame, as a copy of the node does.
    void CopyChildFrame(const SceneNode& node) {
        if (m_childLocal == node.m_childLocal) return;
        m_childLocal = node.m_childLocal;
        MarkTransDirty();
    }

    void SetAttachmentTransform(const Eigen::Matrix4d& transform) {
        if (m_attachmentTransform && m_attachmentTransform->isApprox(transform, 1.0e-10)) return;
        m_attachmentTransform = transform;
        MarkTransDirty();
    }

    void CopyTrans(const SceneNode& node) {
        m_translate = node.m_translate;
        m_scale     = node.m_scale;
        m_rotation  = node.m_rotation;
        m_renderTransformOverride = node.m_renderTransformOverride;
    }

    void SetRenderTransformOverride(Eigen::Matrix4d transform) {
        m_renderTransformOverride = std::move(transform);
    }
    void ClearRenderTransformOverride() { m_renderTransformOverride.reset(); }
    bool HasRenderTransformOverride() const { return m_renderTransformOverride.has_value(); }
    /// A translation in world space added to where the node is drawn and to nothing
    /// else. `RenderTrans` carries it; `ModelTrans`, which the node's children, its
    /// cameras and its hit test compose from, does not (a hit test adds it itself).
    /// A node drawn through a `RenderTransformOverride` draws where that says, which
    /// is a whole matrix already.
    void SetDrawOffset(const Eigen::Vector3f& offset) { m_drawOffset = offset; }
    const Eigen::Vector3f& DrawOffset() const { return m_drawOffset; }
    Eigen::Matrix4d RenderTrans() const {
        if (m_renderTransformOverride) return *m_renderTransformOverride;
        if (m_drawOffset.isZero()) return m_trans;
        Eigen::Matrix4d moved = m_trans;
        moved.block<3, 1>(0, 3) += m_drawOffset.cast<double>();
        return moved;
    }

    // update self modle trans (will update parent before)
    void            UpdateTrans();
    Eigen::Matrix4d ModelTrans() const { return m_trans; };
    /// The matrix the children's own are composed on (after `UpdateTrans`).
    Eigen::Matrix4d ChildTrans() const { return m_childTrans; }

    SceneMesh* Mesh() { return m_mesh.get(); }
    bool       HasMaterial() const { return m_mesh && m_mesh->Material() != nullptr; };

    const auto& GetChildren() const { return m_children; }
    auto&       GetChildren() { return m_children; }
    SceneNode*  Parent() const { return m_parent; }
    bool        NodeHasParent() const { return m_parent != nullptr; }

    i32& ID() { return m_id; }

private:
    // mark self and all children
    void MarkTransDirty();

    i32         m_id;
    std::string m_name;
    bool        m_visible { true };
    bool        m_skipRenderPass { false };
    bool        m_ignoreParentTransform { false };
    bool        m_must_produce { false };
    bool        m_composite_only { false };
    bool        m_visibility_settled { false };
    std::optional<double> m_textureFrame;
    bool                  m_textureAnimationPaused { false };
    double                m_textureAnimationRate { 1.0 };
    std::optional<double> m_textureAnimationFrame;

    bool            m_dirty;
    Eigen::Matrix4d m_trans { Eigen::Matrix4d::Identity() };
    Eigen::Matrix4d m_childTrans { Eigen::Matrix4d::Identity() };
    std::optional<Eigen::Matrix4d> m_childLocal;

    Eigen::Vector3f m_translate { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f m_scale { 1.0f, 1.0f, 1.0f };
    Eigen::Vector3f m_rotation { 0.0f, 0.0f, 0.0f };
    std::optional<Eigen::Matrix4d> m_renderTransformOverride {};
    Eigen::Vector3f m_drawOffset { 0.0f, 0.0f, 0.0f };
    std::optional<Eigen::Matrix4d> m_attachmentTransform;

    std::shared_ptr<SceneMesh> m_mesh;

    // specific a camera not active, used for image effect
    std::string m_cameraName;

    SceneNode* m_parent { nullptr };

    std::list<std::shared_ptr<SceneNode>> m_children;
};
} // namespace wallpaper
