#pragma once

#include "SceneNode.h"
#include "Utils/Linalg.hpp"

namespace wallpaper {

// Place a static camera's node from its eye and look-at point. This is shared by the scene
// loader and SceneScript so both produce the same orthonormal basis, including degenerate up.
inline void PlaceCameraNode(SceneNode& node, const linalg::Vector3d& eye,
                            const linalg::Vector3d& center, linalg::Vector3d up) {
    if (up.squaredNorm() < 1e-12) up = linalg::Vector3d::UnitY();
    linalg::Vector3d direction = center - eye;
    if (direction.squaredNorm() < 1e-12) direction = -linalg::Vector3d::UnitZ();
    const linalg::Vector3d z = -direction.normalized();
    linalg::Vector3d x = up.cross(z);
    if (x.squaredNorm() < 1e-12) {
        const linalg::Vector3d reference = std::abs(z.x()) < 0.9
            ? linalg::Vector3d::UnitX() : linalg::Vector3d::UnitY();
        x = reference - z * reference.dot(z);
    }
    x.normalize();
    linalg::Matrix3d rotation;
    rotation.col(0) = x;
    rotation.col(1) = z.cross(x).normalized();
    rotation.col(2) = z;
    const auto angles = rotation.eulerAngles(2, 1, 0);
    node.SetTranslate(eye.cast<float>());
    node.SetScale(linalg::Vector3f::Ones());
    node.SetRotation(linalg::Vector3f(angles[2], angles[1], angles[0]));
}

} // namespace wallpaper
