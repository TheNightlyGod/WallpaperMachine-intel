#pragma once
#include <tuple>
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <vector>
#include <memory>
#include <optional>
#include <array>
#include "Utils/Linalg.hpp"
#include "SceneImageEffectLayer.h"

namespace wallpaper
{

class SceneNode;

class SceneCamera {
public:
    explicit SceneCamera(i32 width, i32 height, float near, float far)
        : m_aspect(AspectOf(width, height)),
          m_width(width),
          m_height(height),
          m_nearClip(near),
          m_farClip(far) {}

    explicit SceneCamera(float aspect, float near, float far, float fov)
        : m_perspective(true), m_aspect(aspect), m_fov(fov), m_nearClip(near), m_farClip(far) {}

    SceneCamera(const SceneCamera&);
    SceneCamera& operator=(const SceneCamera&);

    void Update();

    /// Parents the camera to a node (the spelling of the name is historical).
    void AttatchNode(std::shared_ptr<SceneNode>);

    bool IsPerspective() const { return m_perspective; }  // false: orthographic
    double Aspect() const { return m_aspect; }            // width over height
    double Width() const { return m_width; }              // orthographic extent
    double Height() const { return m_height; }
    double Fov() const { return m_fov; }                  // perspective only
    double NearClip() const { return m_nearClip; }        // depth range
    double FarClip() const { return m_farClip; }
    void SetWidth(double value) {
        m_width  = value;
        m_aspect = AspectOf(m_width, m_height);
    }
    void SetHeight(double value) {
        m_height = value;
        m_aspect = AspectOf(m_width, m_height);
    }
    void SetAspect(double aspect) { m_aspect = aspect; }
    void SetFov(double value) { m_fov = value; }
    /// The depth range a perspective projection keeps.
    void SetClip(double near_clip, double far_clip) {
        m_nearClip = near_clip;
        m_farClip  = far_clip;
    }
    /// A camera object's own zoom, separate from the scene-wide zoom that
    /// writes width and height. Larger zooms in; anything not positive and
    /// finite frames the full canvas.
    void   SetZoom(double value) { m_zoom = value; }
    double Zoom() const { return m_zoom; }
    /// The extent the orthographic projection actually shows. Pointer mapping
    /// reads this rather than the authored width and height: a click has to
    /// land where the zoomed image is, not where an unzoomed one would be.
    double VisibleWidth() const { return m_width / EffectiveZoom(); }
    double VisibleHeight() const { return m_height / EffectiveZoom(); }

    void  AttatchImgEffect(std::shared_ptr<SceneImageEffectLayer> eff) {
        m_imgEffect = std::move(eff);
    }
    bool  HasImgEffect() const { return m_imgEffect != nullptr; }
    auto& GetImgEffect() { return m_imgEffect; }
    void  SetComposeLayer(bool compose) { m_isComposeLayer = compose; }
    bool  IsComposeLayer() const { return m_isComposeLayer; }
    /// A camera that frames one layer's card in that layer's own texture space:
    /// the card fills the target and nothing about where the layer sits in the
    /// scene -- its transform, the scene camera, parallax -- reaches the image.
    /// This is what another layer samples as `_rt_imageLayerComposite_<id>`.
    void  SetLayerLocal(bool layer_local) { m_layerLocal = layer_local; }
    bool  IsLayerLocal() const { return m_layerLocal; }
    /// A compose layer whose children are drawn through the scene's camera
    /// rather than this one: a fullscreen layer, which Wallpaper Engine gives no
    /// camera of its own, so the layers below it are zoomed, shaken and framed
    /// with the rest of the scene and land in its picture where they would land
    /// on screen.
    void  SetChildrenUseSceneCamera(bool scene) { m_childrenUseSceneCamera = scene; }
    bool  ChildrenUseSceneCamera() const { return m_childrenUseSceneCamera; }

    linalg::Vector3d GetPosition() const;
    linalg::Vector3d GetDirection() const;
    linalg::Vector3d GetUp() const;
    linalg::Vector3d GetRight() const;

    /// A view `distance` units in front of the point the camera looks at, along its own
    /// axis, with the lens scaled by `distance`: the camera WE gives a `perspective`
    /// layer in a 3D scene (2000; probes pcam-a..f). 0 is the camera's own view.
    void   SetLookBack(double distance, double look_distance) {
        m_lookBack = distance;
        m_lookDistance = look_distance;
    }
    double LookBack() const { return m_lookBack; }

    void LockFov(bool lock) { m_fovLocked = lock; }
    bool FovLocked() const { return m_fovLocked; }

    linalg::Matrix4d GetViewMatrix() const;
    linalg::Matrix4d GetViewProjectionMatrix() const;
    /// Shader-only framing; the authored projection above remains the one
    /// scripts and pointer queries see. Allocated lazily for cameras used by
    /// a framed display draw or a projection sampling its scene framebuffer.
    linalg::Matrix4d GetRasterViewProjectionMatrix(const std::array<double, 4>& clip,
                                                  uint64_t generation) const;
    /// A view-projection the camera returns instead of the one its node and lens build: a
    /// shadow view, whose projection the scene computes every frame. `std::nullopt` returns
    /// the camera to its own.
    void SetViewProjectionOverride(std::optional<linalg::Matrix4d> matrix);

    /// World-space axes of the attached node, which is the basis the particle
    /// shaders read as `g_Orientation*`. Identity when no node is attached,
    /// matching the constants the parser writes for an unrotated camera.
    struct Axes {
        linalg::Vector3d right { 1.0, 0.0, 0.0 };
        linalg::Vector3d up { 0.0, 1.0, 0.0 };
        linalg::Vector3d forward { 0.0, 0.0, 1.0 };
    };
    Axes GetAxes() const;

    std::shared_ptr<SceneNode> GetAttachedNode() const { return m_node; }

    /// Camera shake: moves the eye and what it looks at together, on top of
    /// wherever the camera's node puts them.
    void SetShakeOffset(const linalg::Vector3d& offset) { m_shake = offset; }
    const linalg::Vector3d& ShakeOffset() const { return m_shake; }

    /// Takes over another camera's frame and lens; its node, shake and effect
    /// chain stay as they are. The caller updates.
    void Clone(const SceneCamera& cam) {
        if (&cam == this) return;
        // Lens first, in the order the members are declared, then the flags.
        std::tie(m_perspective, m_aspect, m_fov, m_width, m_height, m_nearClip, m_farClip, m_zoom,
                 m_lookBack, m_lookDistance) =
            std::tie(cam.m_perspective, cam.m_aspect, cam.m_fov, cam.m_width, cam.m_height,
                     cam.m_nearClip, cam.m_farClip, cam.m_zoom, cam.m_lookBack, cam.m_lookDistance);
        std::tie(m_fovLocked, m_isComposeLayer, m_layerLocal, m_childrenUseSceneCamera) =
            std::tie(cam.m_fovLocked, cam.m_isComposeLayer, cam.m_layerLocal,
                     cam.m_childrenUseSceneCamera);
    }

private:
    // A zoom of zero, a negative one or a NaN is not a frame anybody can see,
    // so it reads as the whole canvas rather than as a division.
    double EffectiveZoom() const {
        return (std::isfinite(m_zoom) && m_zoom > 0.0) ? m_zoom : 1.0;
    }

    // Width over height, each taken as at least one so an empty extent cannot divide by zero.
    static double AspectOf(double width, double height) {
        return std::max(width, 1.0) / std::max(height, 1.0);
    }

    /// The matrices the camera last built, with the inputs they were built from, so
    /// a read rebuilds only when one of those changed.
    struct Cache {
        bool             valid { false };
        linalg::Matrix4d model { linalg::Matrix4d::Identity() };
        linalg::Vector3d shake { linalg::Vector3d::Zero() };
        double           inputs[10] {};
        linalg::Matrix4d view { linalg::Matrix4d::Identity() };
        linalg::Matrix4d viewProjection { linalg::Matrix4d::Identity() };
    };
    const Cache& Refresh() const;
    // The node's world matrix as of now (identity without a node).
    linalg::Matrix4d NodeModel() const;

    linalg::Vector3d m_shake { linalg::Vector3d::Zero() };
    bool   m_perspective { false };
    double m_aspect { 1.0 };
    double m_fov { 45.0 };
    double m_width { 1.0f };
    double m_height { 1.0f };
    double m_nearClip { 0.01f };
    double m_farClip { 1000.0f };
    double m_zoom { 1.0 };
    double m_lookBack { 0.0 };
    double m_lookDistance { 0.0 };
    bool   m_fovLocked { false };
    bool   m_isComposeLayer { false };

    std::shared_ptr<SceneNode>             m_node;
    std::shared_ptr<SceneImageEffectLayer> m_imgEffect;
    mutable Cache                          m_cache;
    struct RasterProjection {
        const void* owner {nullptr};
        uint64_t generation {0};
        bool valid {false};
        linalg::Matrix4d matrix {linalg::Matrix4d::Identity()};
    };
    mutable std::unique_ptr<RasterProjection> m_rasterProjection;
    bool                                   m_layerLocal { false };
    bool                                   m_childrenUseSceneCamera { false };
    std::optional<linalg::Matrix4d>        m_viewProjectionOverride;
};

/// Seats the perspective camera of a 2D scene -- the one particles, models and
/// layers with the `perspective` flag draw through -- on the view `canvas`
/// shows, as Wallpaper Engine does. The eye sits (visible height / 2) /
/// tan(fov / 2) in front of the canvas plane, the near plane 5 units from the
/// eye and the far plane 1000 units behind the canvas plane or 15000 from the
/// eye, whichever is further. The field of view is the scene's and never
/// moves, so the canvas plane maps exactly as the orthographic view maps it,
/// whatever frames it (a fill mode, a zoom, a camera layer), and what lies off
/// the plane is magnified by D / (D - z) and stays in view up to the eye. Only
/// the depth moves: the caller aims the camera. A camera with a locked field of
/// view belongs to a perspective scene and is left alone. Call `Update`
/// afterwards.
void FitCanvasPerspective(SceneCamera& perspective, const SceneCamera& canvas);

/// How far in front of the canvas plane the eye is that shaders read as
/// `g_EyePosition` in a 2D scene. It is a constant of the scene -- 2000 units out
/// over the centre of the view -- and not the distance the perspective camera
/// sits at, which follows its field of view and the visible canvas. Particle
/// trails turn their ribbons by the angle between a particle and this eye.
inline constexpr float kCanvasShaderEyeDepth = 2000.0f;

/// Intersects the camera ray through NDC `(ndc_x, ndc_y)` with `node`'s local
/// z = 0 plane, where the node is drawn (its draw offset included). NDC is the
/// shared clip space after the perspective divide, x/y in [-1, 1], with this
/// engine's near = 0 and far = 1. Returns local coordinates on the plane, or
/// nullopt if the inverse is degenerate, the ray is parallel to the plane, or the
/// hit lies outside the clip volume.
[[nodiscard]] std::optional<linalg::Vector3d> IntersectNdcWithNodePlane(
    const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y);
/// The same plane with an additional canvas translation, for cursor parallax.
[[nodiscard]] std::optional<linalg::Vector3d> IntersectNdcWithNodePlane(
    const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y,
    const linalg::Vector2d& translation);

/// The world-space point on the camera ray through NDC `(ndc_x, ndc_y)` that is
/// `depth` in front of the eye, measured along the view axis (the camera's view
/// space z is `-depth`), the way `glm::unProject` puts a pointer at one depth of
/// the frustum. NDC x/y span the frustum in [-1, 1] as the projection does.
/// Perspective cameras only: nullopt for an orthographic one, for a depth that
/// is not positive and finite, or when the camera has no usable view.
[[nodiscard]] std::optional<linalg::Vector3d> UnprojectNdcAtDepth(const SceneCamera& camera,
                                                                 double ndc_x, double ndc_y,
                                                                 double depth);
} // namespace wallpaper
