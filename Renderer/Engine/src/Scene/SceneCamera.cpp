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

Matrix4d SceneCamera::NodeModel() const {
	if (! m_node) return Matrix4d::Identity();
	m_node->UpdateTrans();
	return m_node->ModelTrans();
}

const SceneCamera::Cache& SceneCamera::Refresh() const {
	const Matrix4d model = NodeModel();
	const double   inputs[8] = {
		m_perspective ? 1.0 : 0.0, m_aspect, m_fov, m_nearClip, m_farClip, m_width, m_height, m_zoom
	};
	bool same = m_cache.valid && m_cache.shake == m_shake;
	for (int i = 0; same && i < 8; ++i) same = m_cache.inputs[i] == inputs[i];
	for (int c = 0; same && c < 4; ++c) {
		for (int r = 0; same && r < 4; ++r) same = m_cache.model.coeff(r, c) == model.coeff(r, c);
	}
	if (same) return m_cache;

	Matrix4d eye = Matrix4d::Identity();
	eye.block<3, 1>(0, 3) = m_shake;
	Matrix4d projection;
	if (m_perspective) {
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
	for (int i = 0; i < 8; ++i) m_cache.inputs[i] = inputs[i];
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

Matrix4d SceneCamera::GetViewProjectionMatrix() const { return Refresh().viewProjection; }

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
	node.UpdateTrans();
	// The plane of the node where it is drawn: its world matrix, and the draw offset
	// a screen-anchored layer adds to where it is shown.
	linalg::Matrix4d drawn = node.ModelTrans();
	drawn.block<3, 1>(0, 3) += node.DrawOffset().cast<double>();
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
