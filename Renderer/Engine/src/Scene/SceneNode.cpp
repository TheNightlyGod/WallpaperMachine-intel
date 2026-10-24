// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include "SceneNode.h"

#include <cmath>
#include <vector>

#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

Matrix4d SceneNode::LocalTransOf(const Vector3f& translate, const Vector3f& scale,
                                 const Vector3f& rotation) {
    // T * Rz * Ry * Rx * S, written out column by column.
    const double cx = std::cos(static_cast<double>(rotation.x()));
    const double sx = std::sin(static_cast<double>(rotation.x()));
    const double cy = std::cos(static_cast<double>(rotation.y()));
    const double sy = std::sin(static_cast<double>(rotation.y()));
    const double cz = std::cos(static_cast<double>(rotation.z()));
    const double sz = std::sin(static_cast<double>(rotation.z()));

    const double axes[3][3] = {
        { cz * cy, sz * cy, -sy },
        { cz * sy * sx - sz * cx, sz * sy * sx + cz * cx, cy * sx },
        { cz * sy * cx + sz * sx, sz * sy * cx - cz * sx, cy * cx },
    };

    Matrix4d local = Matrix4d::Identity();
    for (int column = 0; column < 3; ++column) {
        const double factor = static_cast<double>(scale[column]);
        for (int row = 0; row < 3; ++row) local(row, column) = axes[column][row] * factor;
        local(column, 3) = static_cast<double>(translate[column]);
    }
    return local;
}

Matrix4d SceneNode::GetLocalTrans() const {
    const Matrix4d local = LocalTransOf(m_translate, m_scale, m_rotation);
    if (m_attachmentTransform) return *m_attachmentTransform * local;
    return local;
}

void SceneNode::UpdateTrans() {
    if (! m_dirty) return;
    if (m_parent != nullptr) m_parent->UpdateTrans();

    const Matrix4d local = GetLocalTrans();
    const bool     under = m_parent != nullptr;
    m_trans = (under && ! m_ignoreParentTransform) ? Matrix4d(m_parent->m_childTrans * local) : local;
    if (m_childLocal) {
        const Matrix4d base = under ? m_parent->m_childTrans : Matrix4d(Matrix4d::Identity());
        m_childTrans        = base * *m_childLocal;
    } else {
        m_childTrans = m_trans;
    }
    m_dirty = false;
}

void SceneNode::MarkTransDirty() {
    if (m_dirty) return;
    InvalidateSubtree();
}

void SceneNode::InvalidateSubtree() {
    m_dirty = true;
    if (m_children.empty()) return; // the common case: a leaf moves every frame, at no cost
    // Iterative, so a very deep tree cannot exhaust the stack; the work list is kept
    // between calls so a moving group does not allocate each frame.
    thread_local std::vector<SceneNode*> pending;
    pending.clear();
    pending.push_back(this);
    while (! pending.empty()) {
        SceneNode* node = pending.back();
        pending.pop_back();
        node->m_dirty = true;
        for (const auto& child : node->m_children) {
            if (child != nullptr) pending.push_back(child.get());
        }
    }
}
