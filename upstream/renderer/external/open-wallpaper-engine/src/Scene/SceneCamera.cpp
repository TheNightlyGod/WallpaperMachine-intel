#include "SceneCamera.h"
#include "SceneNode.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include <cmath>
#include <iostream>
#include <optional>
#include "Utils/Eigen.h"
#include <Eigen/LU>

using namespace wallpaper;
using namespace Eigen;

Vector3d SceneCamera::GetPosition() const {
	if(m_node) {
		m_node->UpdateTrans();
		return Affine3d(m_node->ModelTrans()) * Vector3d::Zero() + m_shake;
	}
	return m_shake;
}

Vector3d SceneCamera::GetDirection() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(0.0f, 0.0f, -1.0f, 0.0f)).head<3>();
	}
	return -Vector3d::UnitZ();
}

Vector3d SceneCamera::GetUp() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(0.0f, 1.0f, 0.0f, 0.0f)).head<3>();
	}
	return Vector3d::UnitY();
}

Vector3d SceneCamera::GetRight() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(1.0f, 0.0f, 0.0f, 0.0f)).head<3>();
	}
	return Vector3d::UnitX();
}

Matrix4d SceneCamera::GetViewMatrix() const {
	const_cast<SceneCamera*>(this)->Update();
	return m_viewMat;
}

Matrix4d SceneCamera::GetViewProjectionMatrix() const {
	const_cast<SceneCamera*>(this)->Update();
	return m_viewProjectionMat;
}

void SceneCamera::CalculateViewProjectionMatrix() {
	// CalculateViewMatrix
	{
		const Matrix4d shake = Affine3d(Translation3d(m_shake)).matrix();
		if(m_node) {
			m_node->UpdateTrans();
			m_viewMat = (shake * m_node->ModelTrans()).inverse().eval();
		} else 
			m_viewMat = shake.inverse().eval();
	};

	if(m_perspective) {
		// Skyboxes are often scaled to exactly `far`. A camera that is not on
		// the shell's center puts that surface a little past the plane, and
		// the clipper drops the whole backdrop. The pad stays small next to
		// the authored range so near-plane precision is unchanged.
		const double abs_far = m_farClip < 0.0 ? -m_farClip : m_farClip;
		const double far_pad = abs_far * 1.0e-3 > 1.0 ? abs_far * 1.0e-3 : 1.0;
		m_viewProjectionMat = Perspective(Radians(m_fov), m_aspect, m_nearClip, m_farClip + far_pad) * m_viewMat;
	} else {
		// A camera object's zoom tightens the frustum around the same centre.
		// It is applied here rather than by writing width and height because
		// the fill mode rewrites those from the authored canvas on every
		// output resize, which would silently drop the zoom. Pointer mapping
		// reads the same VisibleWidth/VisibleHeight, so a click keeps landing
		// where the image is.
		const double half_width = VisibleWidth()/2.0;
		const double half_height = VisibleHeight()/2.0;
		m_viewProjectionMat = Ortho(-half_width, half_width, -half_height, half_height, m_nearClip, m_farClip) * m_viewMat;
	}
}

void SceneCamera::Update() {
	CalculateViewProjectionMatrix();
}


void SceneCamera::AttatchNode(std::shared_ptr<SceneNode> node) {
	if(!node) {
		LOG_ERROR("Attach a null node to camera");		
		return;
	}
	m_node = node;
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
	const Eigen::Matrix4d& model = m_node->ModelTrans();
	const Eigen::Vector3d right   = model.col(0).head<3>();
	const Eigen::Vector3d up      = model.col(1).head<3>();
	const Eigen::Vector3d forward = model.col(2).head<3>();
	if (right.squaredNorm() > 1e-20) axes.right = right.normalized();
	if (up.squaredNorm() > 1e-20) axes.up = up.normalized();
	if (forward.squaredNorm() > 1e-20) axes.forward = forward.normalized();
	return axes;
}

std::optional<Eigen::Vector3d> wallpaper::IntersectNdcWithNodePlane(
	const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y) {
	node.UpdateTrans();
	// The plane of the node where it is drawn: its world matrix, and the draw offset
	// a screen-anchored layer adds to where it is shown.
	Eigen::Matrix4d drawn = node.ModelTrans();
	drawn.block<3, 1>(0, 3) += node.DrawOffset().cast<double>();
	const Eigen::Matrix4d clip_from_local = camera.GetViewProjectionMatrix() * drawn;
	Eigen::FullPivLU<Eigen::Matrix4d> lu(clip_from_local);
	if (! lu.isInvertible()) return std::nullopt;
	const Eigen::Matrix4d local_from_clip = lu.inverse();

	const auto unproject = [&](double clip_z) -> std::optional<Eigen::Vector3d> {
		const Eigen::Vector4d local = local_from_clip * Eigen::Vector4d(ndc_x, ndc_y, clip_z, 1.0);
		if (local.w() == 0.0 || ! std::isfinite(local.w())) return std::nullopt;
		const Eigen::Vector3d point = local.head<3>() / local.w();
		if (! point.allFinite()) return std::nullopt;
		return point;
	};

	const auto near_p = unproject(0.0);
	const auto far_p  = unproject(1.0);
	if (! near_p || ! far_p) return std::nullopt;
	const Eigen::Vector3d delta = *far_p - *near_p;
	if (! delta.allFinite()) return std::nullopt;
	constexpr double kParallel = 1e-12;
	if (std::abs(delta.z()) < kParallel) {
		if (std::abs(near_p->z()) > 1e-6) return std::nullopt;
		return *near_p;
	}
	const double t = -near_p->z() / delta.z();
	if (t < 0.0 || t > 1.0) return std::nullopt;
	const Eigen::Vector3d hit = *near_p + t * delta;
	if (! hit.allFinite()) return std::nullopt;
	return hit;
}

std::optional<Eigen::Vector3d> wallpaper::UnprojectNdcAtDepth(
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
	Eigen::FullPivLU<Eigen::Matrix4d> lu(camera.GetViewMatrix());
	if (! lu.isInvertible()) return std::nullopt;
	// The projection divides view x and y by -z, the half extent at unit
	// distance and (for x) the aspect, so this is its inverse at one depth.
	const Eigen::Vector4d view_space(
		ndc_x * tan_half_fov * camera.Aspect() * depth, ndc_y * tan_half_fov * depth, -depth, 1.0);
	const Eigen::Vector4d world = lu.inverse() * view_space;
	if (! world.allFinite() || world.w() == 0.0) return std::nullopt;
	return Eigen::Vector3d(world.head<3>() / world.w());
}
