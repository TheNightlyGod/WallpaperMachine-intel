// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include "SceneCamera.h"
#include "SceneNode.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include <cmath>
#include <optional>
#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

SceneCamera::SceneCamera(const SceneCamera& other) { *this = other; }

SceneCamera& SceneCamera::operator=(const SceneCamera& other) {
	if (this == &other) return *this;
	std::tie(m_shake, m_perspective, m_aspect, m_fov, m_width, m_height,
	         m_nearClip, m_farClip, m_zoom, m_fovLocked, m_isComposeLayer,
	         m_node, m_imgEffect, m_cache, m_layerLocal, m_childrenUseSceneCamera,
	         m_viewProjectionOverride) =
	    std::tie(other.m_shake, other.m_perspective, other.m_aspect, other.m_fov,
	             other.m_width, other.m_height, other.m_nearClip, other.m_farClip,
	             other.m_zoom, other.m_fovLocked, other.m_isComposeLayer,
	             other.m_node, other.m_imgEffect, other.m_cache, other.m_layerLocal,
	             other.m_childrenUseSceneCamera, other.m_viewProjectionOverride);
	m_rasterProjection.reset();
	return *this;
}

Matrix4d SceneCamera::NodeModel() const {
	if (! m_node) return Matrix4d::Identity();
	m_node->UpdateTrans();
	return m_node->ModelTrans();
}

const SceneCamera::Cache& SceneCamera::Refresh() const {
	const Matrix4d model = NodeModel();
	const double   inputs[10] = {
		m_perspective ? 1.0 : 0.0, m_aspect, m_fov, m_nearClip, m_farClip, m_width, m_height, m_zoom,
		m_lookBack, m_lookDistance
	};
	bool same = m_cache.valid && m_cache.shake == m_shake;
	for (int i = 0; same && i < 10; ++i) same = m_cache.inputs[i] == inputs[i];
	for (int c = 0; same && c < 4; ++c) {
		for (int r = 0; same && r < 4; ++r) same = m_cache.model.coeff(r, c) == model.coeff(r, c);
	}
	if (same) return m_cache;
	if (m_rasterProjection) m_rasterProjection->valid = false;

	Matrix4d eye = Matrix4d::Identity();
	eye.block<3, 1>(0, 3) = m_shake;
	Matrix4d projection;
	if (m_perspective && m_lookBack > 0.0) {
		// The eye moved back along its axis to `m_lookBack` in front of the look-at point,
		// and the lens scaled by that distance (x, y) so the look-at point keeps its framing.
		const double back = m_lookBack - m_lookDistance;
		eye.block<3, 1>(0, 3) += model.block<3, 1>(0, 2).normalized() * back;
		const double far_padded = m_lookBack + std::max(m_farClip, 1.0);
		projection = Perspective(Radians(m_fov), m_aspect, m_nearClip, far_padded);
		projection.row(0) *= m_lookBack;
		projection.row(1) *= m_lookBack;
	} else if (m_perspective) {
		const double far_padded = m_farClip + std::max(1.0, std::abs(m_farClip) * 0.001);
		projection = Perspective(Radians(m_fov), m_aspect, m_nearClip, far_padded);
	} else {
		const double zoom = EffectiveZoom();
		const double half_w = std::max(std::max(m_width, 1.0) / zoom, 1e-6) * 0.5;
		const double half_h = std::max(std::max(m_height, 1.0) / zoom, 1e-6) * 0.5;
		projection = Ortho(-half_w, half_w, -half_h, half_h, m_nearClip, m_farClip);
	}
	m_cache.valid          = true;
	m_cache.model          = model;
	m_cache.shake          = m_shake;
	for (int i = 0; i < 10; ++i) m_cache.inputs[i] = inputs[i];
	m_cache.view           = Matrix4d(eye * model).inverse();
	m_cache.viewProjection = projection * m_cache.view;
	return m_cache;
}

Vector3d SceneCamera::GetPosition() const {
	const Matrix4d model = NodeModel();
	return Vector3d(model.block<3, 1>(0, 3) + m_shake);
}

Vector3d SceneCamera::GetDirection() const {
	if (! m_node) return Vector3d(0.0, 0.0, -1.0);
	return Vector3d(-NodeModel().block<3, 1>(0, 2));
}

Vector3d SceneCamera::GetUp() const {
	if (! m_node) return Vector3d(0.0, 1.0, 0.0);
	return Vector3d(NodeModel().block<3, 1>(0, 1));
}

Vector3d SceneCamera::GetRight() const {
	if (! m_node) return Vector3d(1.0, 0.0, 0.0);
	return Vector3d(NodeModel().block<3, 1>(0, 0));
}

Matrix4d SceneCamera::GetViewMatrix() const { return Refresh().view; }

Matrix4d SceneCamera::GetViewProjectionMatrix() const {
	if (m_viewProjectionOverride.has_value()) return *m_viewProjectionOverride;
	return Refresh().viewProjection;
}

Matrix4d SceneCamera::GetRasterViewProjectionMatrix(const std::array<double, 4>& clip,
                                                    uint64_t generation) const {
	// Explicit shadow views already describe their atlas viewport.
	if (m_viewProjectionOverride.has_value()) return *m_viewProjectionOverride;
	const auto& authored = Refresh().viewProjection;
	if (!m_rasterProjection) m_rasterProjection = std::make_unique<RasterProjection>();
	auto& raster = *m_rasterProjection;
	if (!raster.valid || raster.owner != &clip || raster.generation != generation) {
		raster.matrix = authored;
		raster.matrix.row(0) = clip[0] * authored.row(0) + clip[2] * authored.row(3);
		raster.matrix.row(1) = clip[1] * authored.row(1) + clip[3] * authored.row(3);
		raster.owner = &clip;
		raster.generation = generation;
		raster.valid = true;
	}
	return raster.matrix;
}

void SceneCamera::SetViewProjectionOverride(std::optional<Matrix4d> matrix) {
	m_viewProjectionOverride = std::move(matrix);
	if (m_rasterProjection) m_rasterProjection->valid = false;
}

void SceneCamera::Update() { (void)Refresh(); }

void SceneCamera::AttatchNode(std::shared_ptr<SceneNode> node) {
	if (node == nullptr) {
		LOG_ERROR("Attach a null node to camera");
		return;
	}
	m_node = std::move(node);
	Update();
}

void wallpaper::FitCanvasPerspective(SceneCamera& perspective, const SceneCamera& canvas) {
	if(perspective.FovLocked()) return;
	const double distance =
		algorism::CalculatePersperctiveDistance(perspective.Fov(), canvas.VisibleHeight());
	if(! std::isfinite(distance) || distance <= 0.0) return;
	if(const auto node = perspective.GetAttachedNode(); node != nullptr) {
		Vector3f translate = node->Translate();
		translate.z()      = static_cast<float>(distance);
		node->SetTranslate(translate);
	}
	perspective.SetClip(5.0, std::max(distance + 1000.0, 15000.0));
}

SceneCamera::Axes SceneCamera::GetAxes() const {
	Axes axes;
	if (! m_node) return axes;
	m_node->UpdateTrans();
	const linalg::Matrix4d& model = m_node->ModelTrans();
	const linalg::Vector3d right   = model.col(0).head<3>();
	const linalg::Vector3d up      = model.col(1).head<3>();
	const linalg::Vector3d forward = model.col(2).head<3>();
	if (right.squaredNorm() > 1e-20) axes.right = right.normalized();
	if (up.squaredNorm() > 1e-20) axes.up = up.normalized();
	if (forward.squaredNorm() > 1e-20) axes.forward = forward.normalized();
	return axes;
}

std::optional<linalg::Vector3d> wallpaper::IntersectNdcWithNodePlane(
	const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y) {
	return IntersectNdcWithNodePlane(camera,node,ndc_x,ndc_y,linalg::Vector2d::Zero());
}

std::optional<linalg::Vector3d> wallpaper::IntersectNdcWithNodePlane(
	const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y,
	const linalg::Vector2d& translation) {
	node.UpdateTrans();
	// The plane of the node where it is drawn: its world matrix, and the draw offset
	// a screen-anchored layer adds to where it is shown.
	linalg::Matrix4d drawn = node.ModelTrans();
	drawn.block<3, 1>(0, 3) += node.DrawOffset().cast<double>();
	drawn(0,3) += translation.x();
	drawn(1,3) += translation.y();
	const linalg::Matrix4d clip_from_local = camera.GetViewProjectionMatrix() * drawn;
	linalg::FullPivLU<linalg::Matrix4d> lu(clip_from_local);
	if (! lu.isInvertible()) return std::nullopt;
	const linalg::Matrix4d local_from_clip = lu.inverse();

	const auto unproject = [&](double clip_z) -> std::optional<linalg::Vector3d> {
		const linalg::Vector4d local = local_from_clip * linalg::Vector4d(ndc_x, ndc_y, clip_z, 1.0);
		if (local.w() == 0.0 || ! std::isfinite(local.w())) return std::nullopt;
		const linalg::Vector3d point = local.head<3>() / local.w();
		if (! point.allFinite()) return std::nullopt;
		return point;
	};

	const auto near_p = unproject(0.0);
	const auto far_p  = unproject(1.0);
	if (! near_p || ! far_p) return std::nullopt;
	const linalg::Vector3d delta = *far_p - *near_p;
	if (! delta.allFinite()) return std::nullopt;
	constexpr double kParallel = 1e-12;
	if (std::abs(delta.z()) < kParallel) {
		if (std::abs(near_p->z()) > 1e-6) return std::nullopt;
		return *near_p;
	}
	const double t = -near_p->z() / delta.z();
	if (t < 0.0 || t > 1.0) return std::nullopt;
	const linalg::Vector3d hit = *near_p + t * delta;
	if (! hit.allFinite()) return std::nullopt;
	return hit;
}

std::optional<linalg::Vector3d> wallpaper::UnprojectNdcAtDepth(
	const SceneCamera& camera, double ndc_x, double ndc_y, double depth) {
	if (! camera.IsPerspective() || ! std::isfinite(ndc_x) || ! std::isfinite(ndc_y) ||
		! std::isfinite(depth) || depth <= 0.0) {
		return std::nullopt;
	}
	const double tan_half_fov = std::tan(Radians(camera.Fov()) / 2.0);
	if (! std::isfinite(tan_half_fov) || tan_half_fov <= 0.0 || ! std::isfinite(camera.Aspect()) ||
		camera.Aspect() <= 0.0) {
		return std::nullopt;
	}
	linalg::FullPivLU<linalg::Matrix4d> lu(camera.GetViewMatrix());
	if (! lu.isInvertible()) return std::nullopt;
	// The projection divides view x and y by -z, the half extent at unit
	// distance and (for x) the aspect, so this is its inverse at one depth.
	const linalg::Vector4d view_space(
		ndc_x * tan_half_fov * camera.Aspect() * depth, ndc_y * tan_half_fov * depth, -depth, 1.0);
	const linalg::Vector4d world = lu.inverse() * view_space;
	if (! world.allFinite() || world.w() == 0.0) return std::nullopt;
	return linalg::Vector3d(world.head<3>() / world.w());
}
